#!/usr/bin/env bash
# A profile edit must not be able to break unrelated hosts (Kamino item 181).
#
# ssh rejects the WHOLE config over one bad line, so a HostName with a space,
# a User with one, or an unknown option in --additional did not break one
# profile: it broke every `ssh` on the machine, while navicomputer exited 0.
# Each case here is held to the same three things: a non-zero exit, the
# config byte-for-byte as it was, and no backup written or pruned - and the
# proof is ssh itself still reading an unmanaged host.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$TEST_DIR/lib.sh"
nc_setup "$TEST_DIR"
command -v ssh >/dev/null || { echo "SKIP - ssh not installed" >&2; exit 0; }
sha() { cksum < "$1"; }
baks() { printf '%s\n' "$CONFIG".[0-9]*.bak | LC_ALL=C sort | xargs cksum 2>/dev/null; }
other_reads() { ssh -F "$CONFIG" -G other >/dev/null 2>&1; }

cat > "$CONFIG" <<'CFG'
Host other
    HostName other.example
    User olga
CFG
: > "$SSH_DIR/id_p"
run add --name p --hostname p.example --user pat --key "$SSH_DIR/id_p"
check "setup: the profile is added"     test "$RC" -eq 0
check "setup: ssh reads the file"       other_reads

# refused <description> <engine args...>
refused() {
    local d="$1"; shift
    local before b4baks; before="$(sha "$CONFIG")"; b4baks="$(baks)"
    run "$@"
    check "$d: exit non-zero"               test "$RC" -ne 0
    check "$d: the config is unchanged"     test "$(sha "$CONFIG")" = "$before"
    check "$d: no backup written or pruned" test "$(baks)" = "$b4baks"
    check "$d: ssh still reads other"       other_reads
    check "$d: no temp file left behind"    bash -c '! ls -A "$1" | grep -q "^\.config\."' _ "$SSH_DIR"
}

echo "== the three reproductions =="
refused "add --hostname 'evil host'" add --name evil --hostname "evil host" --key "$SSH_DIR/id_p"
check "...it says why"                  in_err 'hostname must not contain whitespace'
refused "edit --user 'a b'"          edit --name p --user "a b"
check "...it says why"                  in_err 'user must not contain whitespace'
refused "edit --additional 'Bogus yes'" edit --name p --additional "Bogus yes"
check "...ssh's own complaint is shown" in_err '[Bb]ad configuration option'
check "...against the new file, not a temp path" in_err '<new config>'
check "p keeps its user"                profile_is p .user pat
check "p has no extra option"           profile_is p .additional ""

echo
echo "== the same class, other shapes =="
refused "a newline in --hostname"      edit --name p --hostname $'p.example\nUser root'
refused "a tab in --user"              add --name tab --hostname t.example --user $'a\tb' --key "$SSH_DIR/id_p"
refused "a Host line in --additional"  edit --name p --additional $'Host *\nUser root'
check "...it says why"                  in_err 'Host or Match'
refused "a Match line in --additional" edit --name p --additional "Match all"
refused "a bad value in --additional"  edit --name p --additional "ServerAliveInterval soon"
refused "a newline in --key"           edit --name p --key $'/k\nUser root'

echo
echo "== what is valid still goes through =="
run edit --name p --additional $'ForwardAgent no\nServerAliveInterval 30'
check "valid extra options, exit 0"     test "$RC" -eq 0
check "they are written"                in_managed '^ +ServerAliveInterval 30$'
check "ssh still reads other"           other_reads

echo
echo "== a config ssh already cannot read =="
printf '\nHost broken\n    Bogus yes\n' >> "$CONFIG"
before="$(sha "$CONFIG")"
run edit --name p --user pam
check "a rewrite is refused, exit 1"    test "$RC" -ne 0
check "it says the file was already broken" in_err 'already fails'
check "the config is unchanged"         test "$(sha "$CONFIG")" = "$before"

nc_report "field-validation"
