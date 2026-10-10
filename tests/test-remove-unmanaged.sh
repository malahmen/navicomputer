#!/usr/bin/env bash
# `import --remove-original` deletes a Host block from outside the managed
# section. It is the most destructive thing navicomputer does, in the file that
# gates every ssh session on the machine, so the checks here are about what has
# to SURVIVE the deletion as much as about what has to go.
#
# Almost every one of them looks at unmanaged_only rather than the whole file:
# after an import the alias exists again INSIDE the managed section, so a plain
# grep passes whether the original block was deleted or not.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$TEST_DIR/lib.sh"
nc_setup "$TEST_DIR"

echo "== Match / Include blocks that follow the removed host =="
cat > "$CONFIG" <<'CFG'
Host victim
    HostName victim.example
    User alice

Match host bastion.example
    ProxyJump none
    ForwardAgent yes

Host keeper
    HostName keeper.example
    User bob

Include ~/.ssh/conf.d/*.conf

Host trailer
    HostName trailer.example
CFG
run import --host victim --remove-original --force
check "import exits 0"                  test "$RC" -eq 0
check "the victim block is gone"        no_unmanaged '^Host victim$'
check "the Match line survives"         line_in "Match host bastion.example" "$CONFIG"
check "options under the Match survive" line_in "    ProxyJump none" "$CONFIG"
check "    ForwardAgent too"            line_in "    ForwardAgent yes" "$CONFIG"
check "the Include line survives"       line_in "Include ~/.ssh/conf.d/*.conf" "$CONFIG"
check "the keeper block survives"       line_in "Host keeper" "$CONFIG"
check "its options survive"             line_in "    User bob" "$CONFIG"
check "the trailer block survives"      line_in "Host trailer" "$CONFIG"
check "victim became a profile"         profile_is victim .hostname victim.example
check "with the user it had"            profile_is victim .user alice
check "the managed section is there"    line_in "$BEGIN_MARK" "$CONFIG"
check "markers are balanced"            markers_balanced

echo
echo "== the removed host is not the first alias on its Host line =="
# `Host prod web` names two aliases. Matching only $2 removed nothing while the
# caller still printed "Unmanaged entry removed", so the import duplicated the
# host instead of adopting it — and the duplicate sat ABOVE the managed
# section, where first-match-wins means the stale copy keeps winning.
cat > "$CONFIG" <<'CFG'
Host prod web
    HostName web.example
    User deploy

Host after
    HostName after.example
CFG
run import --host web --remove-original --force
check "import exits 0"                    test "$RC" -eq 0
check "the whole block is gone"           no_unmanaged '^Host prod web$'
check "web.example is not left unmanaged" no_unmanaged 'web\.example'
check "the following block survives"      line_in "Host after" "$CONFIG"
check "the extra alias was reported"      in_err 'Host aliases:.*prod'

echo
echo "== a tab after the keyword, and a case ssh accepts =="
printf 'Host\tvictim\n\tHostName victim.example\n\nhost keeper\n\tHostName keeper.example\n' > "$CONFIG"
run import --host victim --remove-original --force
check "import exits 0"                 test "$RC" -eq 0
check "the tab-indented block is gone" no_unmanaged 'victim\.example'
check "the lowercase block survives"   in_unmanaged 'keeper\.example'

echo
echo "== without --force, an original holding extras is kept =="
cat > "$CONFIG" <<'CFG'
Host victim
    HostName victim.example
    ProxyJump jump.example
CFG
run import --host victim --remove-original
check "import refuses, exit 1"             test "$RC" -eq 1
check "ProxyJump named in the refusal"     in_err 'ProxyJump jump\.example'
check "it says how to proceed"             in_err '[-][-]force'
check "the original block was NOT removed" in_unmanaged '^Host victim$'
check "and nothing was imported"           no_line "$BEGIN_MARK" "$CONFIG"

echo
echo "== without --remove-original the block is left alone =="
run import --host victim
check "import exits 0"                test "$RC" -eq 0
check "the original block is intact"  in_unmanaged '^Host victim$'
check "ProxyJump is still in it"      in_unmanaged 'ProxyJump jump\.example'
check "it was reported as not carried" in_err 'left in the unmanaged entry'
check "the profile exists as well"    profile_is victim .hostname victim.example

echo
echo "== every rewrite leaves a backup =="
cat > "$CONFIG" <<'CFG'
Host victim
    HostName victim.example
CFG
run import --host victim --remove-original --force
bak=$(newest_backup)
check "a backup was written"       test -f "$bak"
check "the backup is mode 600"     mode_is 600 "$bak"
check "it holds the deleted block" grep -q "^Host victim$" "$bak"
check "the config is mode 600"     mode_is 600 "$CONFIG"

echo
echo "== an alias that is not in the config at all =="
# import does not refuse this: ssh -G answers for any name, so a profile is
# created from the defaults. Pinned as the documented behaviour, and with the
# part that matters either way — nothing outside the managed section moves.
cat > "$CONFIG" <<'CFG'
Host keeper
    HostName keeper.example
CFG
run import --host ghost --remove-original --force
check "import exits 0"                 test "$RC" -eq 0
check "a profile is made from defaults" profile_is ghost .hostname ghost
check "with no identity carried over"   profile_is ghost .key ""
check "the keeper block is untouched"   in_unmanaged '^Host keeper$'
check "and keeps its HostName"          in_unmanaged '^ *HostName keeper\.example$'
check "markers stay balanced"           markers_balanced

nc_report "remove-unmanaged"
