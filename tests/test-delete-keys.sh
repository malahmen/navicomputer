#!/usr/bin/env bash
# `remove --delete-keys` deletes private keys, the one thing navicomputer does
# that no backup undoes (Kamino item 177). It deleted whatever the profile
# named: two profiles on ~/.ssh/id_ed25519, one removed with --delete-keys, and
# the main key was gone while the other profile still used it.
#
# The rules held here:
#   - never a key another IdentityFile still names - another profile, a hand-
#     written block, a file the config Includes - nor one of ssh's defaults,
#     --force or not;
#   - otherwise only what `add --gen-key` made for that profile
#     (id_<name>_<type>), unless --force;
#   - a refusal changes nothing, and a deletion names its exact paths.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$TEST_DIR/lib.sh"
nc_setup "$TEST_DIR"
sha() { cksum < "$1"; }
key() { printf 'PRIVATE %s\n' "$1" > "$SSH_DIR/$1"; printf 'PUBLIC %s\n' "$1" > "$SSH_DIR/$1.pub"; }
intact() { [[ -f "$SSH_DIR/$1" && -f "$SSH_DIR/$1.pub" ]]; }

echo "== the reproduction: two profiles on one key =="
key id_shared
run add --name gh --hostname github.com --key "$SSH_DIR/id_shared"
run add --name gl --hostname gitlab.com --key "$SSH_DIR/id_shared"
before="$(sha "$CONFIG")"
run remove --name gh --delete-keys
check "remove refuses, exit 1"             test "$RC" -eq 1
check "the shared key is still there"      intact id_shared
check "it names the key"                   in_err "not deleting $SSH_DIR/id_shared"
check "and where it is still used"         in_err "IdentityFile at $CONFIG:[0-9]+"
check "and how to go on"                   in_err 'without --delete-keys'
check "the config is unchanged"            test "$(sha "$CONFIG")" = "$before"
check "gh is still a profile"              profile_is gh .hostname github.com
run remove --name gh --delete-keys --force
check "--force does not lift it, exit 1"   test "$RC" -eq 1
check "the key is still there"             intact id_shared
check "the config is still unchanged"      test "$(sha "$CONFIG")" = "$before"
run remove --name gh
check "without --delete-keys it goes"      test "$RC" -eq 0
check "...keeping the key"                 intact id_shared
check "and gl still points at it"          profile_is gl .key "$SSH_DIR/id_shared"

echo
echo "== a key a hand-written block uses =="
rm -f "$CONFIG"; key id_work
cat > "$CONFIG" <<CFG
Host work
    HostName work.example
    IdentityFile = "$SSH_DIR/id_work"
CFG
run add --name w --hostname w.example --key "$SSH_DIR/id_work"
run remove --name w --delete-keys --force
check "refused, exit 1"                    test "$RC" -eq 1
check "the key is still there"             intact id_work
n=$(grep -n '^    IdentityFile = ' "$CONFIG" | cut -d: -f1)
check "the unmanaged line is named"        in_err "IdentityFile at $CONFIG:${n}\$"

echo
echo "== a key a file the config Includes uses =="
rm -f "$CONFIG"; key id_inc; mkdir -p "$SSH_DIR/conf.d"
printf 'Host inc\n    IdentityFile %s/id_inc\n' "$SSH_DIR" > "$SSH_DIR/conf.d/inc.conf"
printf 'Include %s/conf.d/*.conf\n' "$SSH_DIR" > "$CONFIG"
run add --name i --hostname i.example --key "$SSH_DIR/id_inc"
run remove --name i --delete-keys --force
check "refused, exit 1"                    test "$RC" -eq 1
check "the key is still there"             intact id_inc
check "the included file is named"         in_err "IdentityFile at $SSH_DIR/conf.d/inc.conf:2"
rm -rf "$SSH_DIR/conf.d"

echo
echo "== another name for the same key (a symlink) =="
rm -f "$CONFIG"; key id_real; ln -s "$SSH_DIR/id_real" "$SSH_DIR/id_link"
run add --name real --hostname r.example --key "$SSH_DIR/id_real"
run add --name link --hostname l.example --key "$SSH_DIR/id_link"
run remove --name link --delete-keys --force
check "refused, exit 1"                    test "$RC" -eq 1
check "the real key is still there"        intact id_real

echo
echo "== ssh's default identity =="
rm -f "$CONFIG"; key id_ed25519
run add --name def --hostname d.example --key "$SSH_DIR/id_ed25519"
run remove --name def --delete-keys --force
check "refused even alone, exit 1"         test "$RC" -eq 1
check "id_ed25519 is still there"          intact id_ed25519
check "it says why"                        in_err "default identity"

echo
echo "== a key navicomputer did not generate =="
rm -f "$CONFIG"; key id_custom
run add --name cus --hostname c.example --key "$SSH_DIR/id_custom"
before="$(sha "$CONFIG")"
run remove --name cus --delete-keys
check "refused without --force, exit 1"    test "$RC" -eq 1
check "the key is still there"             intact id_custom
check "it says how to go on"               in_err '[-][-]force'
check "the config is unchanged"            test "$(sha "$CONFIG")" = "$before"
run remove --name cus --delete-keys --force
check "with --force it goes, exit 0"       test "$RC" -eq 0
check "the private key is gone"            test ! -e "$SSH_DIR/id_custom"
check "the public key too"                 test ! -e "$SSH_DIR/id_custom.pub"
check "both paths were named"              in_err "Deleting key files: $SSH_DIR/id_custom $SSH_DIR/id_custom.pub"

echo
echo "== a key add --gen-key made for this profile =="
if command -v ssh-keygen >/dev/null; then
    rm -f "$CONFIG"; key id_other
    run add --name gen --hostname g.example --gen-key ed25519
    run add --name other --hostname o.example --key "$SSH_DIR/id_other"
    check "the key was generated"          test -f "$SSH_DIR/id_gen_ed25519"
    run remove --name gen --delete-keys
    check "remove exits 0"                 test "$RC" -eq 0
    check "the private key is gone"        test ! -e "$SSH_DIR/id_gen_ed25519"
    check "the public key too"             test ! -e "$SSH_DIR/id_gen_ed25519.pub"
    check "both paths named before"        in_err "Deleting key files: $SSH_DIR/id_gen_ed25519 $SSH_DIR/id_gen_ed25519.pub"
    check "the profile is gone"            no_managed_line '^Host gen$'
    check "the other profile's key stays"  intact id_other
    # Another profile's generated key is not this profile's to delete.
    run add --name gen2 --hostname g2.example --gen-key ed25519
    run add --name thief --hostname t.example --key "$SSH_DIR/id_gen2_ed25519"
    run remove --name thief --delete-keys
    check "gen2's key is not thief's, exit 1" test "$RC" -eq 1
    check "...and it survives"             test -f "$SSH_DIR/id_gen2_ed25519"
else
    echo "   note - ssh-keygen not installed: generated-key checks skipped"
fi

echo
echo "== a refused rewrite leaves the keys =="
# The config is rewritten first and the keys deleted after: a rewrite that is
# refused (here: ssh already cannot read the file) must not have taken the
# keys with it.
if command -v ssh >/dev/null; then
    rm -f "$CONFIG"; key id_first_ed25519
    run add --name first --hostname f.example --key "$SSH_DIR/id_first_ed25519"
    printf '\nHost broken\n    Bogus yes\n' >> "$CONFIG"
    run remove --name first --delete-keys
    check "the rewrite is refused"         test "$RC" -ne 0
    check "the private key is still there" intact id_first_ed25519
    rm -f "$CONFIG"
fi

echo
echo "== a profile whose key file is not there =="
rm -f "$CONFIG"
run add --name nofile --hostname n.example --key "$SSH_DIR/id_missing"
run remove --name nofile --delete-keys
check "remove exits 0"                     test "$RC" -eq 0
check "it says there was nothing to delete" in_err 'nothing to delete'
check "the profile is gone"                no_managed_line '^Host nofile$'

nc_report "delete-keys"
