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
    --key ~/.ssh/id_ed25519 --additional $'IdentitiesOnly yes\nForwardAgent yes'

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
./navicomputer.sh import --all [--remove-original]   # or: --host <alias> ...
```

Helper commands `hosts` and `unmanaged` print the config's Host aliases (all /
outside-the-managed-section) — used by the front-end's pickers.

## Options reference

| Flag | Applies to | Meaning |
| ---- | ---------- | ------- |
| `--name ALIAS` | all | the Host alias / profile identity (**required**) |
| `--hostname H` | add, edit | real hostname (defaults to the alias; a pasted `user@host` is split) |
| `--user U` | add, edit | SSH user (default `git`) |
| `--port P` | add, edit | port (default `22`) |
| `--key PATH` | add, edit | existing private key to use |
| `--gen-key ed25519\|rsa` | add | generate a new key at `~/.ssh/id_<name>_<type>` |
| `--key-comment C` | add | comment for the generated key (default `user@alias`) |
| `--additional STR` | add, edit | extra `~/.ssh/config` lines for this Host |
| `--delete-keys` | remove | also delete the profile's key files |
| `--repo DIR` `--remote URL` `--init` `--git-name` `--git-email` | use | git wiring |
| `--all` | test, import | act on every host |
| `--host ALIAS` | import | a specific host to import (repeatable) |
| `--remove-original` | import | delete the original unmanaged entry after importing |
| `--json` | list, view | machine-readable output |

## Notes

- All output/status goes to **stderr**; data (`list --json`, `view --json`, the
  generated pubkey path from `add`) goes to **stdout**, so it composes in scripts.
- Never elevates privileges; only reads/writes under `~/.ssh`.

## License

Released under the [Unlicense](LICENSE).
