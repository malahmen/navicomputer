# navicomputer

**`navicomputer.sh` — an SSH profile manager, as a gum-free, flag-driven CLI.**

navicomputer keeps a set of SSH profiles in the managed section of your
`~/.ssh/config`, so `ssh <alias>`, `git clone <alias>:…`, and friends just work.
It has no prompts — every action is a flag — which makes it scriptable and lets a
separate TUI (scomp-link) drive it. It's the CLI half of the engine/front-end
split, like [holo-convert](https://github.com/malahmen/holo-convert) and
[younglings-key](https://github.com/malahmen/younglings-key).

## What it manages

Each **profile** is a `Host` alias in `~/.ssh/config` with its `HostName`,
`User`, `Port`, `IdentityFile`, and any extra options. Profiles live between the
markers:

```
# === BEGIN sshger ===
...profiles...
# === END sshger ===
```

The `sshger` marker is kept for backward compatibility with the former `sshger`
tool — existing profiles are picked up unchanged.

Only the text between the markers is ever rewritten; everything else in the file
is left as is. A few rules keep that rewrite safe:

- **Placement.** When the managed section is first created it is inserted
  *before* the first `Host`/`Match` block of an existing config (after any
  leading comments), because ssh applies the first matching value: a `Host *`
  above it would otherwise override a profile's `User` or `IdentityFile`. An
  existing section that sits below other blocks is left where it is, with a
  warning suggesting you move it to the top.
- **`IdentitiesOnly yes`.** Every profile with a key is written with
  `IdentitiesOnly yes`, so ssh offers only that key regardless of what a
  `Host *` adds. Set it yourself in `--additional` to override the value.
- **Backups.** Before a command's first rewrite the whole file is copied to
  `~/.ssh/config.<YYYYmmddTHHMMSS>.bak` (mode 600) - once per command, so the
  backup is the file as it was before it, however many hosts an `import`
  removes. The five newest backups are kept; set `BACKUP_KEEP=<n>` to change
  that.
- **A symlinked config** (stow, chezmoi, home-manager) is written through: the
  file the link points to is updated, and the link stays.
- **Quoting.** A key path with a space is written double-quoted, the only form
  ssh accepts for it.
- **Windows line endings** (CRLF) are refused before anything is written:
  convert the file first.
- **Marker check.** If the markers are inconsistent (a `BEGIN` without an `END`,
  or several of either) the tool refuses to touch the file and asks you to fix
  it by hand — a lone `BEGIN` would otherwise swallow everything below it.

## Requirements

- **`jq`** — always (parsing/writing profiles).
- **`ssh-keygen`** — for `--gen-key`.
- **`ssh`** — for `test` and `import`.
- **`git`** — for `use`.

## Install

```sh
git clone git@github.com:malahmen/navicomputer.git
cd navicomputer
chmod +x navicomputer.sh
./navicomputer.sh --help
```

## Identity

`--name` is the **SSH Host alias** — the thing you type after `ssh` — and it is
the profile's identity (the key everything is stored and looked up by). To rename
a profile, `remove` it and `add` it again.

## Commands

```sh
# Add a profile and generate a fresh key
./navicomputer.sh add --name github-work --hostname github.com --user git \
    --gen-key ed25519 --key-comment "me@work"

# Add using an existing key, a custom port, and extra options
./navicomputer.sh add --name box --hostname 10.0.0.5 --user ubuntu --port 2222 \
    --key ~/.ssh/id_ed25519 --additional $'ForwardAgent yes\nServerAliveInterval 30'

./navicomputer.sh list [--json]                 # list profiles
./navicomputer.sh view --name github-work       # show one (add --json for JSON)
./navicomputer.sh edit --name box --user root   # change fields (keeps the rest)
./navicomputer.sh remove --name box [--delete-keys]

# Wire a profile to a git repo (sets core.sshCommand to use its key)
./navicomputer.sh use --name github-work --repo ~/code/proj \
    [--remote git@github-work:me/proj.git] [--init] [--git-name X] [--git-email Y]

# Verify SSH auth
./navicomputer.sh test --name github-work        # or: --all

# Adopt hosts you added to ~/.ssh/config by hand
./navicomputer.sh import --all [--remove-original [--force]]   # or: --host <alias> ...
```

### Generated keys

`--gen-key` accepts `ed25519`, `rsa` and `rsa-4096` (the last two are the same:
a 4096-bit RSA key). The key is written to `~/.ssh/id_<alias>_ed25519` or
`~/.ssh/id_<alias>_rsa` with no passphrase, and its `.pub` path is printed on
stdout. If that file already exists it is **reused** (with an info message)
rather than regenerated — nothing ever prompts to overwrite.

### Extra options (`--additional`)

`--additional` takes the extra `ssh_config` lines for the Host, separated by
newlines (`$'...\n...'` in bash). Indentation is optional: lines are trimmed,
blank lines dropped, and everything is written back indented by four spaces so
it survives later `edit`s unchanged. `IdentitiesOnly yes` is added
automatically unless you set `IdentitiesOnly` here yourself.

### Importing hand-written hosts

`import` carries over exactly four things: `HostName`, `User`, `Port` and the
**first** `IdentityFile`. Everything else is **not** imported — additional
aliases on the same `Host` line, further `IdentityFile`s, and any other option
(`ForwardAgent`, `ProxyJump`, …). Whatever is left out is listed in a warning.

`HostName` is read with `ssh -G`. `User`, `Port` and the `IdentityFile` are
read from the **host's own block** instead: a block that sets no `User` is
imported with none, so ssh keeps applying your defaults (a `Host *` block, or
the login name) rather than having them frozen into the profile. A host whose
block sets no key is imported with no key at all. An `Include` inside a host's
block belongs to that block: it is reported as not carried over, and with
`--remove-original --force` it goes with the block. `ssh -G`
cannot answer that question: asked about a host with no `IdentityFile`, it
replies with the whole built-in default list, headed by `~/.ssh/id_rsa`.
Importing that first entry — and writing `IdentitiesOnly yes` beside it — would
pin ssh to a key that probably does not exist and forbid every other, so a host
that worked before the import would stop authenticating.

Both lookups are resolved against the file navicomputer manages (`ssh -G -F`),
not against ssh's default path, so `SSH_DIR` is honoured.

- Without `--remove-original` the original entry stays in place, so those
  settings keep working; you just end up with the alias defined twice, and for
  the four imported fields whichever block comes first in the file wins (the
  managed section, when navicomputer created it).
- With `--remove-original` the original block is deleted after importing. If
  that would lose anything, the whole import is **refused** before any file is
  touched, with the list of what would be lost. Add `--force` to delete the
  block anyway, or re-add the missing options with `edit --additional`.

  The block being deleted runs from its `Host` line to the next `Host`, `Match`
  or `Include` — all three, since `ssh_config` lets any of them end a block.
  The alias is matched against **every** name on the `Host` line, so
  `Host prod web` is removed whether you import `prod` or `web`. The keyword
  itself is matched the way ssh reads it: any capitalisation, and a tab after
  it is fine.

Helper commands `hosts` and `unmanaged` print the config's Host aliases (all /
outside-the-managed-section) — used by the front-end's pickers.

## Tests

```sh
tests/run-all.sh            # every suite
bash tests/test-import.sh   # or one of them
```

No network, no credentials, no services. Each suite points `SSH_DIR` at a
temporary directory and **refuses to start** if that path is under `$HOME`,
because the file under test is the one that gates every ssh session on the
machine. `NAVICOMPUTER=/path/to/navicomputer.sh` runs them against another
copy, which is how a fix is checked for actually fixing something.

| Suite | Covers |
| ----- | ------ |
| `test-profiles.sh` | the `add`/`list`/`view`/`edit`/`remove` round trip, every refusal, and where the managed section is placed |
| `test-import.sh` | what `import` carries over, and which file it reads to find out |
| `test-remove-unmanaged.sh` | `--remove-original`: what is deleted, and everything that has to survive it |
| `test-use.sh` | `core.sshCommand` — asserted on the argument vector a shell would split it into, not on the string |

## Options reference

| Flag | Applies to | Meaning |
| ---- | ---------- | ------- |
| `--name ALIAS` | all | the Host alias / profile identity (**required**; no whitespace) |
| `--hostname H` | add, edit | real hostname (defaults to the alias; a pasted `user@host` is split) |
| `--user U` | add, edit | SSH user (default `git`) |
| `--port P` | add, edit | port, an integer in `1..65535` (default `22`) |
| `--key PATH` | add, edit | existing private key to use |
| `--gen-key ed25519\|rsa\|rsa-4096` | add | generate a new key at `~/.ssh/id_<name>_<type>` (reused if it exists) |
| `--key-comment C` | add | comment for the generated key (default `user@alias`) |
| `--additional STR` | add, edit | extra `~/.ssh/config` lines for this Host (newline-separated, indentation optional) |
| `--delete-keys` | remove | also delete the profile's key files |
| `--repo DIR` `--remote URL` `--init` `--git-name` `--git-email` | use | git wiring |
| `--all` | test, import | act on every host |
| `--host ALIAS` | import | a specific host to import (repeatable) |
| `--remove-original` | import | delete the original unmanaged entry after importing (refused if settings would be lost) |
| `--force` | import | with `--remove-original`: delete the original even if settings are lost |
| `--json` | list, view | machine-readable output |

## Notes

- All output/status goes to **stderr**; data (`list --json`, `view --json`, the
  generated pubkey path from `add`) goes to **stdout**, so it composes in scripts.
- `--name` must not contain whitespace and `--port` must be a number in
  `1..65535`; both are rejected with a clear error.
- Never elevates privileges; only reads/writes under `~/.ssh` (the config, its
  `.bak` copies, and generated keys). `SSH_DIR=<dir>` moves all of that
  somewhere else — the suites use it, and it is how you can try a change
  against a throwaway config.

## License

[MIT](LICENSE) © 2026 malahmen.
