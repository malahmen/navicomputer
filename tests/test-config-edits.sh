#!/usr/bin/env bash
# review-2026-10-23's findings on how navicomputer edits ~/.ssh/config
# (Kamino items 122-125), each checked against what ssh itself then reads:
#   - an Include inside a Host block belongs to that block (122);
#   - a key path with a space is written so ssh still parses the file (123);
#   - the pre-command file survives as a backup, and a symlinked config
#     keeps its link (124);
#   - the rest (125): the skip resets at the markers, a block with no User is
#     not given one, CRLF is refused, `test` connects with -F, and
#     core.sshCommand is POSIX-quoted;
#   - 125's gaps (199): the backup prune, the lock, "removed" only when true,
#     Port from the block, and a config linked into a read-only tree.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$TEST_DIR/lib.sh"
nc_setup "$TEST_DIR"
command -v ssh >/dev/null || { echo "SKIP - ssh not installed" >&2; exit 0; }
sshG() { ssh -F "$CONFIG" -G "$1" 2>/dev/null | awk -v k="$2" '$1==k { $1=""; sub(/^ /, ""); print; exit }'; }
sha() { cksum < "$1"; }

echo "== 122: an Include inside a Host block belongs to it =="
printf 'User carol\n' > "$SSH_DIR/prod-extra.conf"
cat > "$CONFIG" <<CFG
Host a
    HostName a.example
    User joao

Host prod
    HostName prod.example
    Include $SSH_DIR/prod-extra.conf
    User bob
CFG
before="$(sha "$CONFIG")"
run import --host prod --remove-original
check "--remove-original stops: the Include is not carried over" test "$RC" -ne 0
check "...and names it"                       in_err 'Include .*prod-extra.conf'
check "...and changes nothing"                test "$(sha "$CONFIG")" = "$before"
run import --host prod --remove-original --force
check "with --force it goes ahead"            test "$RC" -eq 0
check "the Include went with prod"            no_unmanaged 'Include'
check "and so did User bob"                   no_unmanaged 'User bob'
check "host a is still joao, as ssh reads it" test "$(sshG a user)" = joao

echo
echo "== 123: a key path with a space =="
cat > "$CONFIG" <<'CFG'
Host spaced
    HostName spaced.example
    User dave
    IdentityFile "/keys/my key"
CFG
run import --host spaced --remove-original
check "import exits 0"                        test "$RC" -eq 0
check "ssh still parses the file"             bash -c 'ssh -F "$1" -G spaced >/dev/null 2>&1' _ "$CONFIG"
check "...and reads the whole path"           test "$(sshG spaced identityfile)" = "/keys/my key"
check "the profile holds it unquoted"         profile_is spaced .key "/keys/my key"
run add --name added --hostname added.example --user erin --key "$SSH_DIR/my key"
check "add exits 0"                           test "$RC" -eq 0
check "ssh parses the file after add"         bash -c 'ssh -F "$1" -G added >/dev/null 2>&1' _ "$CONFIG"
check "...with the whole path"                test "$(sshG added identityfile)" = "$SSH_DIR/my key"

echo
echo "== 124: one backup per command, and a symlinked config keeps its link =="
rm -f "$CONFIG" "$CONFIG".[0-9]*.bak
for i in 1 2 3 4 5 6 7; do printf 'Host h%s\n    HostName h%s.example\n    User u%s\n\n' "$i" "$i" "$i"; done > "$CONFIG"
orig="$(sha "$CONFIG")"
run import --all --remove-original
check "import --all exits 0"                  test "$RC" -eq 0
n=$(printf '%s\n' "$CONFIG".[0-9]*.bak | grep -c .)
check "one backup for the whole command"      test "$n" -eq 1
check "...and it is the file before import"   test "$(sha "$(newest_backup)")" = "$orig"
mkdir -p "$T/dotfiles"; mv "$CONFIG" "$T/dotfiles/ssh_config"; ln -s "$T/dotfiles/ssh_config" "$CONFIG"
: > "$SSH_DIR/id_linked"
run add --name linked --hostname linked.example --user fred --key "$SSH_DIR/id_linked"
check "add exits 0 on a symlinked config"     test "$RC" -eq 0
check "the config is still a symlink"         test -L "$CONFIG"
check "the dotfile it points to has the profile" grep -q '^Host linked$' "$T/dotfiles/ssh_config"

echo
echo "== 125: the rest =="
rm -f "$CONFIG"
cat > "$CONFIG" <<CFG
Host above
    HostName above.example
    User gina
$BEGIN_MARK
$END_MARK
# a comment after the managed section
Host below
    HostName below.example
CFG
run import --host above --remove-original
check "removing the block above the section exits 0" test "$RC" -eq 0
check "the comment after END survives"        grep -qx '# a comment after the managed section' "$CONFIG"
check "...and so does Host below"             grep -qx 'Host below' "$CONFIG"
cat > "$CONFIG" <<'CFG'
Host nouser
    HostName nouser.example
CFG
run import --host nouser
check "a block with no User imports"          test "$RC" -eq 0
check "...with no user frozen into it"        profile_is nouser .user ""
check "...and no User line written"           no_managed_line '^[[:space:]]+User '
printf 'Host crlf\r\n    HostName crlf.example\r\n' > "$CONFIG"
before="$(sha "$CONFIG")"
: > "$SSH_DIR/id_x"
run add --name x --hostname x.example --user y --key "$SSH_DIR/id_x"
check "a CRLF config is refused"              test "$RC" -ne 0
check "...saying why"                         in_err 'CRLF'
check "...and left as it was"                 test "$(sha "$CONFIG")" = "$before"

# `test` connects with -F: an ssh that records its arguments.
rm -f "$CONFIG"; : > "$SSH_DIR/id_tgt"
run add --name tgt --hostname tgt.example --user hal --key "$SSH_DIR/id_tgt"
check "the profile to test exists"            profile_is tgt .hostname tgt.example
mkdir -p "$T/bin"; REAL_SSH="$(command -v ssh)"
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/ssh-calls"
case " \$* " in *" -G "*) exec "$REAL_SSH" "\$@" ;; esac
echo "Welcome"; exit 0
EOF
chmod +x "$T/bin/ssh"
PATH="$T/bin:$PATH" run test --name tgt
check "test connects with -F, not only resolves with it" grep -q -- "-F $CONFIG -T" "$T/ssh-calls"

key="$SSH_DIR/clé"; : > "$key"
run add --name accent --hostname a.example --user ivy --key "$key"
repo="$T/repo"; mkdir -p "$repo"; git init -q "$repo"
LC_ALL=C run use --name accent --repo "$repo"
cmd="$(git -C "$repo" config --get core.sshCommand)"
check "core.sshCommand has no \$'...' quoting"   bash -c 'case "$1" in *"\$'"'"'"*) exit 1 ;; esac' _ "$cmd"
check "sh reads the key path back whole"        test "$(sh -c "set -- $cmd; echo \"\$3\"")" = "$key"

echo
echo "== 199: the prune keeps the newest, and never the pre-command backup =="
rm -f "$CONFIG" "$CONFIG".[0-9]*.bak
printf 'Host pr\n    HostName pr.example\n' > "$CONFIG"
for i in 1 2 3 4 5; do printf 'old %s\n' "$i" > "$CONFIG.2000010${i}T000000.bak"; done
pre="$(sha "$CONFIG")"
run import --host pr
check "import exits 0"                          test "$RC" -eq 0
check "five backups are kept"                   test "$(printf '%s\n' "$CONFIG".[0-9]*.bak | grep -c .)" -eq 5
check "the oldest is the one pruned"            test ! -e "$CONFIG.20000101T000000.bak"
check "the next oldest is kept"                 test -e "$CONFIG.20000102T000000.bak"
check "the pre-command backup is kept"          test "$(sha "$(newest_backup)")" = "$pre"

# Two backups in one second: config.<ts>.bak, then config.<ts>_01.bak. Under
# a locale's collation, which ignores punctuation, _01 sorted FIRST and the
# prune deleted the newer one - here, the pre-command backup. `date` is pinned
# so the second backup lands in the same second, and the run is under a real
# locale where there is one, because under C the mistake does not show.
mkdir -p "$T/datebin"; printf '#!/bin/sh\necho 20300101T000000\n' > "$T/datebin/date"; chmod +x "$T/datebin/date"
loc="$(locale -a 2>/dev/null | grep -iE '^en_US\.utf-?8$' | head -1)"
[[ -n "$loc" ]] || echo "   note - no en_US.UTF-8 locale here: the collation case runs under the default one"
rm -f "$CONFIG".[0-9]*.bak
printf 'earlier, same second\n' > "$CONFIG.20300101T000000.bak"
pre="$(sha "$CONFIG")"
PATH="$T/datebin:$PATH" LC_ALL="${loc:-${LC_ALL:-}}" BACKUP_KEEP=1 run edit --name pr --user ursula
check "edit exits 0"                            test "$RC" -eq 0
check "the same-second backup is _01"           test -e "$CONFIG.20300101T000000_01.bak"
check "...and it is the one kept"               test "$(printf '%s\n' "$CONFIG".[0-9]*.bak | grep -c .)" -eq 1
check "...holding the file before the edit"     test "$(sha "$CONFIG.20300101T000000_01.bak")" = "$pre"

echo
echo "== 199: one rewrite at a time (the lock) =="
if command -v flock >/dev/null; then
    before="$(sha "$CONFIG")"
    # The holder IS the sleep (exec), so killing it closes the fd and frees
    # the lock; `flock FILE sleep` would leave the sleep holding it.
    ( flock 8; exec sleep 30 ) 8>"$SSH_DIR/.navicomputer.lock" & holder=$!
    for _ in $(seq 50); do flock -n "$SSH_DIR/.navicomputer.lock" true || break; sleep 0.1; done
    : > "$SSH_DIR/id_lk"
    run add --name lk --hostname lk.example --key "$SSH_DIR/id_lk"
    check "a second run is refused"             test "$RC" -ne 0
    check "...saying why"                       in_err 'another navicomputer'
    check "...having changed nothing"           test "$(sha "$CONFIG")" = "$before"
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    run add --name lk --hostname lk.example --key "$SSH_DIR/id_lk"
    check "once it is released, the run goes"   test "$RC" -eq 0
else
    echo "   note - no flock here (stock macOS): the engine runs unlocked, lock checks skipped"
fi

echo
echo "== 199: \"removed\" is said only when it is true =="
cat > "$CONFIG" <<'CFG'
Host keeper
    HostName keeper.example
CFG
run import --host ghost --remove-original --force
check "import exits 0"                          test "$RC" -eq 0
check "no block, so no \"removed\""             no_err 'Unmanaged entry removed: ghost'
check "it says nothing was removed"             in_err "No unmanaged entry for 'ghost'"
cat > "$CONFIG" <<'CFG'
Host prod web
    HostName web.example
CFG
run import --host web --remove-original --force
check "a second alias on the line is removed"   no_unmanaged '^Host prod web$'
check "...and said to be"                       in_err 'Unmanaged entry removed: web'

echo
echo "== 199: Port comes from the block, not from ssh -G =="
cat > "$CONFIG" <<'CFG'
Host ported
    HostName ported.example

Host fixed
    HostName fixed.example
    Port 2022

Host *
    Port 2200
CFG
run import --host ported --host fixed
check "import exits 0"                          test "$RC" -eq 0
check "a block with no Port keeps the default"  profile_is ported .port 22
check "...so no Port line is frozen in"         no_managed_line '^ +Port 2200$'
check "...and Host * still applies, as before"  test "$(sshG ported port)" = 2200
check "a block's own Port is carried"           profile_is fixed .port 2022

echo
echo "== 199: a config linked into a read-only tree =="
rm -f "$CONFIG" "$CONFIG".[0-9]*.bak
mkdir -p "$T/store"; printf 'Host st\n    HostName st.example\n' > "$T/store/ssh_config"
ln -s "$T/store/ssh_config" "$CONFIG"; chmod 555 "$T/store"
if [[ -w "$T/store" ]]; then
    echo "   note - running as root: a read-only directory is writable, check skipped"
else
    before="$(sha "$CONFIG")"
    : > "$SSH_DIR/id_st"
    run add --name st2 --hostname st2.example --key "$SSH_DIR/id_st"
    check "add refuses, exit 1"                 test "$RC" -eq 1
    check "...naming the link's target"         in_err "symlink to .*/store/ssh_config"
    check "...and why"                          in_err 'not writable'
    check "...not a bare mktemp error"          no_err 'mktemp'
    check "the config is unchanged"             test "$(sha "$CONFIG")" = "$before"
    check "it is still a symlink"               test -L "$CONFIG"
    check "and no backup was written"           bash -c '! ls "$1".[0-9]*.bak >/dev/null 2>&1' _ "$CONFIG"
fi
chmod 755 "$T/store"

nc_report test-config-edits
