#!/usr/bin/env bash
# Shared harness for navicomputer's suites.
#
# Every suite runs the engine against a THROWAWAY $SSH_DIR. That is the whole
# safety story here: navicomputer rewrites ~/.ssh/config, so a suite that
# leaked would be worse than no suite at all. nc_setup refuses to run if
# $SSH_DIR still points inside the real $HOME/.ssh.
set -uo pipefail

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
# Assert on a whole line, so a substring of a longer option cannot pass for it.
line_in() { grep -qxF "$1" "$2"; }

NC=""
T=""

# nc_setup <tests-dir> — the suite passes the directory it computed to source
# this file; deriving it from BASH_SOURCE in here works but reads as a puzzle.
nc_setup() {
    NC="${NAVICOMPUTER:-${1}/../navicomputer.sh}"
    [[ -f "$NC" ]] || { echo "navicomputer.sh not found at $NC" >&2; exit 1; }
    T=$(mktemp -d); T="$(cd "$T" && pwd)"
    # shellcheck disable=SC2064
    # Expanded now on purpose: $T must be captured while it is still set.
    trap "rm -rf '$T'" EXIT

    export SSH_DIR="$T/ssh"
    case "$SSH_DIR" in
        "$HOME"/*) echo "refusing to run: SSH_DIR is under \$HOME ($SSH_DIR)" >&2; exit 1 ;;
    esac
    mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
    CONFIG="$SSH_DIR/config"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL="$T/gitconfig"; : > "$GIT_CONFIG_GLOBAL"
}

# run <args...> — $OUT / $ERR / $RC from one engine invocation. stdin is closed
# so a regression that starts prompting hangs the suite for a moment and then
# fails, rather than waiting for a terminal that is not there.
OUT=""; ERR=""; RC=0
# shellcheck disable=SC2034
# OUT/ERR/RC are read by the suites that source this file, not in here.
run() { OUT="$(bash "$NC" "$@" 2>"$T/err" </dev/null)"; RC=$?; ERR="$(cat "$T/err")"; }

BEGIN_MARK="# === BEGIN sshger ==="
END_MARK="# === END sshger ==="

nc_report() {
    echo
    if (( FAILS )); then echo "$1: ${FAILS} check(s) failed"; exit 1; fi
    echo "$1: all checks passed"
}

# The config with the managed section cut out. Most of the removal checks have
# to look here: after an import the alias exists again INSIDE the managed
# section, so a plain grep of the whole file passes whether the original block
# was deleted or not.
unmanaged_only() { sed "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$CONFIG"; }
# The newest backup. Sorted under C collation for the same reason
# _backup_config does it: the default collation ignores punctuation and puts
# config.<ts>_01.bak before config.<ts>.bak.
newest_backup() { printf '%s\n' "$CONFIG".[0-9]*.bak | LC_ALL=C sort | tail -1; }

# Predicates for `check`, which runs its argument IN THIS SHELL. A `bash -c
# '! ...'` would run in a child, where none of these functions exist: the
# child would exit 127 and the negation would make every such check pass.
in_unmanaged()  { unmanaged_only | grep -qE "$1"; }
no_unmanaged()  { ! unmanaged_only | grep -qE "$1"; }
in_err()        { grep -qE -- "$1" <<<"$ERR"; }
no_line()       { ! grep -qxF "$1" "$2"; }
mode_is()       { [[ "$(stat -c %a "$2")" == "$1" ]]; }

# profile_is <alias> <jq-path> <value> — read back through the engine, not by
# grepping the file, so the parse half of the round trip is covered too.
profile_is() {
    local got
    got=$(bash "$NC" view --name "$1" --json 2>/dev/null | jq -r "$2") || return 1
    [[ "$got" == "$3" ]]
}
markers_balanced() {
    local b e
    b=$(grep -c "^${BEGIN_MARK}\$" "$CONFIG" || true)
    e=$(grep -c "^${END_MARK}\$" "$CONFIG" || true)
    [[ "$b" == "$e" ]] && (( b <= 1 ))
}

# Just the managed section — the half of the file navicomputer generates.
managed_only() { sed -n "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/p" "$CONFIG"; }
in_managed()     { managed_only | grep -qE "$1"; }
no_managed_line(){ ! managed_only | grep -qE "$1"; }
no_err()         { ! grep -qE -- "$1" <<<"$ERR"; }
bash_not_grep()  { ! grep -qE "$1" "$CONFIG"; }
