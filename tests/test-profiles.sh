#!/usr/bin/env bash
# The add / list / view / edit / remove round trip, and what the rewrite does
# to the rest of the file.
#
# ~/.ssh/config is both the store and a file the user edits by hand, so the
# parse and the write have to be each other's inverse: anything load_profiles
# cannot read, update_ssh_config silently drops on the next command.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$TEST_DIR/lib.sh"
nc_setup "$TEST_DIR"

echo "== add, into a config that does not exist yet =="
run add --name gh --hostname github.com --user git --key "$SSH_DIR/id_gh"
check "add exits 0"            test "$RC" -eq 0
check "the config was created" test -f "$CONFIG"
check "it is mode 600"         mode_is 600 "$CONFIG"
check "markers are balanced"   markers_balanced
check "the Host line is there" in_managed '^Host gh$'
check "HostName"               in_managed '^ +HostName github\.com$'
check "User"                   in_managed '^ +User git$'
check "IdentityFile"           in_managed 'IdentityFile .*id_gh$'
check "IdentitiesOnly yes"     in_managed '^ +IdentitiesOnly yes$'
check "Port 22 is NOT written" no_managed_line '^ +Port '
check "list shows it"          bash -c 'bash "$1" list | grep -q "^  gh$"' _ "$NC"
check "add prints no pubkey path" test -z "$OUT"

echo
echo "== a second add, and the round trip through the file =="
run add --name gl --hostname gitlab.com --user git --port 2222 --key "$SSH_DIR/id_gl" \
        --additional "ForwardAgent no"
check "add exits 0"              test "$RC" -eq 0
check "Port is written"          in_managed '^ +Port 2222$'
check "the extra option is kept" in_managed '^ +ForwardAgent no$'
check "gh survived the rewrite"  profile_is gh .hostname github.com
check "and so did its key"       profile_is gh .key "$SSH_DIR/id_gh"
check "gl reads back"            profile_is gl .port 2222
check "with its extra option"    profile_is gl .additional "ForwardAgent no"
check "two profiles in --json"   bash -c 'test "$(bash "$1" list --json | jq ".profiles | length")" = 2' _ "$NC"

echo
echo "== add refusals =="
run add --name gh --hostname other.example --key "$SSH_DIR/id_x"
check "a duplicate profile, exit 1" test "$RC" -eq 1
check "and it points at edit"       in_err 'edit'
run add --name "two words" --key "$SSH_DIR/id_x"
check "whitespace in the alias, exit 1" test "$RC" -eq 1
check "and it says why"                 in_err 'whitespace'
run add --name noport --hostname x.example --port 99999 --key "$SSH_DIR/id_x"
check "an out-of-range port, exit 1" test "$RC" -eq 1
check "and it gives the range"       in_err '65535'
run add --name nokey --hostname x.example
check "no key at all, exit 1" test "$RC" -eq 1
check "and it names both flags" in_err '[-][-]gen-key'
check "none of them were stored" bash -c 'test "$(bash "$1" list --json | jq ".profiles | length")" = 2' _ "$NC"

echo
echo "== an alias that already exists OUTSIDE the managed section =="
printf '\nHost manual\n    HostName manual.example\n' >> "$CONFIG"
run add --name manual --hostname other.example --key "$SSH_DIR/id_x"
check "add refuses, exit 1"       test "$RC" -eq 1
check "and says where it is"      in_err 'already exists'
check "the manual block is intact" in_unmanaged '^ +HostName manual\.example$'

echo
echo "== edit changes one field and leaves the rest =="
run edit --name gl --user deploy
check "edit exits 0"           test "$RC" -eq 0
check "the user changed"       profile_is gl .user deploy
check "the hostname did not"   profile_is gl .hostname gitlab.com
check "the port did not"       profile_is gl .port 2222
check "the key did not"        profile_is gl .key "$SSH_DIR/id_gl"
check "the extra option did not" profile_is gl .additional "ForwardAgent no"
run edit --name gl --additional ""
check "an extra option can be cleared" profile_is gl .additional ""
check "and the line is gone"           no_managed_line 'ForwardAgent'
run edit --name ghost --user x
check "an unknown profile, exit 1" test "$RC" -eq 1

echo
echo "== remove =="
run remove --name gl
check "remove exits 0"          test "$RC" -eq 0
check "the profile is gone"     bash -c '! bash "$1" view --name gl --json >/dev/null 2>&1' _ "$NC"
check "its Host line is gone"   no_managed_line '^Host gl$'
check "gh is still there"       profile_is gh .hostname github.com
check "the manual block is too" in_unmanaged '^Host manual$'
run remove --name gl
check "removing it twice, exit 1" test "$RC" -eq 1

echo
echo "== --delete-keys only deletes the profile's own key =="
: > "$SSH_DIR/id_gh"; : > "$SSH_DIR/id_gh.pub"; : > "$SSH_DIR/id_keep"
run remove --name gh --delete-keys
check "remove exits 0"        test "$RC" -eq 0
check "the key was deleted"   test ! -e "$SSH_DIR/id_gh"
check "the pubkey too"        test ! -e "$SSH_DIR/id_gh.pub"
check "the other key is kept" test -f "$SSH_DIR/id_keep"

echo
echo "== the managed section goes ABOVE an existing Host * =="
# First match wins in ssh_config: a `Host *` placed before the section would
# override the options in it.
cat > "$CONFIG" <<'CFG'
# a leading comment
Host *
    ServerAliveInterval 60
CFG
run add --name below --hostname below.example --key "$SSH_DIR/id_b"
check "add exits 0"                   test "$RC" -eq 0
check "the comment is still first"    bash -c 'test "$(head -1 "$1")" = "# a leading comment"' _ "$CONFIG"
check "the section precedes Host *"   bash -c 'b=$(grep -n "BEGIN sshger" "$1" | cut -d: -f1); h=$(grep -n "^Host \*" "$1" | cut -d: -f1); test "$b" -lt "$h"' _ "$CONFIG"
check "Host * survived"               in_unmanaged '^ +ServerAliveInterval 60$'
check "no warning was printed"        no_err 'below other Host'

echo
echo "== and warns when the user has moved it below one =="
cat > "$CONFIG" <<CFG
Host *
    ServerAliveInterval 60

$BEGIN_MARK
$END_MARK
CFG
run add --name warned --hostname warned.example --key "$SSH_DIR/id_w"
check "add still exits 0"  test "$RC" -eq 0
check "it warns"           in_err 'below other Host'
check "and the profile is written" profile_is warned .hostname warned.example

echo
echo "== an inconsistent pair of markers is refused, not guessed =="
printf '%s\nHost x\n' "$BEGIN_MARK" > "$CONFIG"
run add --name any --hostname any.example --key "$SSH_DIR/id_a"
check "add refuses, exit 1"     test "$RC" -eq 1
check "and says to fix by hand" in_err 'by hand'
check "the file is unchanged"   bash -c 'test "$(wc -l < "$1")" = 2' _ "$CONFIG"

nc_report "profiles"
