#!/usr/bin/env bash
# `use` writes core.sshCommand into a repo. The value is a command line git
# re-splits on whitespace, so an unquoted key path with a space in it became
# two arguments and every push from that repo failed with a message about the
# wrong file.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$TEST_DIR/lib.sh"
nc_setup "$TEST_DIR"

# ssh_cmd_argv — core.sshCommand split the way git splits it, one argument per
# line. This is the assertion that matters: not what the string looks like, but
# what ssh would actually receive.
ssh_cmd_argv() {
    local cmd; cmd=$(git -C "$1" config --get core.sshCommand) || return 1
    # git uses a shell for core.sshCommand, so a shell is the right splitter.
    bash -c 'eval "set -- $1"; printf "%s\n" "$@"' _ "$cmd"
}
argv_is() {
    local repo="$1"; shift
    [[ "$(ssh_cmd_argv "$repo")" == "$(printf '%s\n' "$@")" ]]
}

echo "== a key path with a space in it =="
key="$SSH_DIR/my keys/id_spaced"
mkdir -p "$SSH_DIR/my keys"; : > "$key"
run add --name spaced --hostname spaced.example --key "$key"
check "add exits 0" test "$RC" -eq 0

repo="$T/repo-spaced"; mkdir -p "$repo"; git init -q "$repo"
run use --name spaced --repo "$repo"
check "use exits 0"                   test "$RC" -eq 0
check "argv is exactly what ssh needs" argv_is "$repo" ssh -i "$key" -o IdentitiesOnly=yes
check "the key argument still exists"  test -f "$(ssh_cmd_argv "$repo" | sed -n 3p)"

echo
echo "== an ordinary key path is untouched =="
plain="$SSH_DIR/id_plain"; : > "$plain"
run add --name plain --hostname plain.example --key "$plain"
repo2="$T/repo-plain"; mkdir -p "$repo2"; git init -q "$repo2"
run use --name plain --repo "$repo2"
check "use exits 0"              test "$RC" -eq 0
check "argv as expected"         argv_is "$repo2" ssh -i "$plain" -o IdentitiesOnly=yes
check "no quoting was added"     bash -c 'case "$(git -C "$1" config --get core.sshCommand)" in *\'\''*|*\"*) return 1 ;; esac' _ "$repo2"

echo
echo "== --init, --remote and the identity fields =="
repo3="$T/repo-init"; mkdir -p "$repo3"
run use --name plain --repo "$repo3" --init --remote ssh://plain.example/x.git \
        --git-name Tester --git-email t@example
check "use exits 0"        test "$RC" -eq 0
check "the repo was made"  test -d "$repo3/.git"
check "origin was set"     bash -c 'test "$(git -C "$1" config --get remote.origin.url)" = ssh://plain.example/x.git' _ "$repo3"
check "user.name was set"  bash -c 'test "$(git -C "$1" config --get user.name)" = Tester' _ "$repo3"
check "user.email was set" bash -c 'test "$(git -C "$1" config --get user.email)" = t@example' _ "$repo3"

echo
echo "== an existing origin is not overwritten =="
git -C "$repo3" remote set-url origin ssh://kept.example/y.git
run use --name plain --repo "$repo3" --remote ssh://other.example/z.git
check "use exits 0"            test "$RC" -eq 0
check "origin was left alone"  bash -c 'test "$(git -C "$1" config --get remote.origin.url)" = ssh://kept.example/y.git' _ "$repo3"

echo
echo "== refusals =="
run use --name plain --repo "$T/nowhere"
check "a missing directory, exit 1" test "$RC" -eq 1
check "and it says which"           in_err 'Directory not found'
notgit="$T/notgit"; mkdir -p "$notgit"
run use --name plain --repo "$notgit"
check "a non-repo without --init, exit 1" test "$RC" -eq 1
check "and it names --init"                in_err '[-][-]init'
check "no config was written"              bash -c '! test -e "$1/.git"' _ "$notgit"
run use --name ghost --repo "$repo2"
check "an unknown profile, exit 1" test "$RC" -eq 1
check "and it says so"             in_err 'No such profile'

nc_report "use"
