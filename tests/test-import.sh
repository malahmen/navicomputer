#!/usr/bin/env bash
# What `import` carries over from an unmanaged block, and which file it reads
# to find out.
#
# Both halves used to be wrong in a way that only showed up later, at the next
# `git push`: the identity came from `ssh -G`, which invents a default when the
# block sets none, and the lookup ignored $SSH_DIR entirely.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$TEST_DIR/lib.sh"
nc_setup "$TEST_DIR"
command -v ssh >/dev/null || { echo "SKIP - ssh not installed" >&2; exit 0; }

echo "== a block that sets no IdentityFile =="
# ssh -G answers with the whole default list here, headed by ~/.ssh/id_rsa.
# Importing that and adding `IdentitiesOnly yes` pins ssh to one key that
# probably does not exist and forbids every other — so a host that worked
# before the import stops authenticating, for anyone whose key is ed25519.
cat > "$CONFIG" <<'CFG'
Host plain
    HostName plain.example
    User alice
CFG
run import --host plain
check "import exits 0"                 test "$RC" -eq 0
check "hostname carried over"          profile_is plain .hostname plain.example
check "user carried over"              profile_is plain .user alice
check "the identity is EMPTY"          profile_is plain .key ""
check "no IdentityFile was written"    no_managed_line 'IdentityFile'
check "no IdentitiesOnly was written"  no_managed_line 'IdentitiesOnly'
check "id_rsa is nowhere in the file"  bash_not_grep 'id_rsa'

echo
echo "== a block that does set one =="
cat > "$CONFIG" <<'CFG'
Host keyed
    HostName keyed.example
    User bob
    IdentityFile ~/.ssh/id_keyed_ed25519
CFG
run import --host keyed
check "import exits 0"               test "$RC" -eq 0
check "the identity is carried over" profile_is keyed .key "$HOME/.ssh/id_keyed_ed25519"
check "~ was expanded"               no_managed_line 'IdentityFile ~'
check "IdentityFile is written"      in_managed 'IdentityFile .*id_keyed_ed25519'
check "and IdentitiesOnly with it"   in_managed 'IdentitiesOnly yes'
check "it is not reported as extra"  no_err 'IdentityFile'

echo
echo "== the second IdentityFile of a block is reported, not carried =="
cat > "$CONFIG" <<'CFG'
Host two
    HostName two.example
    IdentityFile ~/.ssh/id_first
    IdentityFile ~/.ssh/id_second
CFG
run import --host two
check "the first one is carried"   profile_is two .key "$HOME/.ssh/id_first"
check "the second is reported"     in_err 'IdentityFile ~/\.ssh/id_second'
check "and only the first written" bash -c 'test "$(grep -c id_second "$1")" = 1' _ "$CONFIG"

echo
echo "== IdentityFile=path, the = form ssh accepts =="
cat > "$CONFIG" <<'CFG'
Host eq
    HostName eq.example
    IdentityFile=/keys/id_eq
CFG
run import --host eq
check "the identity is carried over" profile_is eq .key /keys/id_eq
check "not reported as an extra"     no_err 'IdentityFile'

echo
echo "== IdentityFile = /path, and a quoted path with a space =="
cat > "$CONFIG" <<'CFG'
Host spaced
    HostName spaced.example
    IdentityFile = "/keys/my key"
CFG
run import --host spaced
check "the whole quoted path is kept" profile_is spaced .key "/keys/my key"
check "it is not reported as extra"   no_err 'IdentityFile'

echo
echo "== \$SSH_DIR is the file that gets read (N3) =="
# Without -F, `ssh -G` read ~/.ssh/config: the import stored whatever the real
# config said — or the alias itself — and then deleted the block it had just
# failed to read. The decoy exists so a stray read of a default path cannot
# look like success either.
mkdir -p "$T/decoy"
cat > "$T/decoy/config" <<'CFG'
Host elsewhere
    HostName decoy.invalid
    User nobody
CFG
cat > "$CONFIG" <<'CFG'
Host elsewhere
    HostName sshdir.example
    User carol
    Port 2222
CFG
run import --host elsewhere
check "hostname came from \$SSH_DIR" profile_is elsewhere .hostname sshdir.example
check "user came from \$SSH_DIR"     profile_is elsewhere .user carol
check "port came from \$SSH_DIR"     profile_is elsewhere .port 2222
check "the decoy was not read"       bash_not_grep 'decoy.invalid'
check "the decoy file is untouched"  grep -q 'decoy.invalid' "$T/decoy/config"

echo
echo "== import --all =="
cat > "$CONFIG" <<'CFG'
Host one
    HostName one.example

Host two
    HostName two.example

Host *
    ServerAliveInterval 60
CFG
run import --all
check "import exits 0"           test "$RC" -eq 0
check "one was imported"         profile_is one .hostname one.example
check "two was imported"         profile_is two .hostname two.example
check "the wildcard was skipped" bash -c '! bash "$1" view --name "*" --json >/dev/null 2>&1' _ "$NC"
check "it is still in the file"  in_unmanaged 'ServerAliveInterval 60'

echo
echo "== neither --host nor --all =="
run import
check "import refuses, exit 1" test "$RC" -eq 1
check "and says what to pass"  in_err '[-][-]host'

nc_report "import"
