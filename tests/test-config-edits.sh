#!/usr/bin/env bash
# review-2026-10-23's findings on how navicomputer edits ~/.ssh/config
# (Kamino items 122-125), each checked against what ssh itself then reads:
#   - an Include inside a Host block belongs to that block (122);
#   - a key path with a space is written so ssh still parses the file (123);
#   - the pre-command file survives as a backup, and a symlinked config
#     keeps its link (124);
#   - the rest (125): the skip resets at the markers, a block with no User is
#     not given one, CRLF is refused, `test` connects with -F, and
#     core.sshCommand is POSIX-quoted.
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

nc_report test-config-edits
