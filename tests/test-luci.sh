#!/bin/sh
# tests/test-luci.sh - luci-app-wanguard-antidpi menu + ACL matrix (issue #78).
#
# ONE script for the local dev stand (scripts/dev-test.sh step 9) and CI
# (feed.yml luci-test job): mount /out (ro) with the built *.apk and /tests
# (ro) with this script + the harness + the fixture, then:
#
#   [1] install core + luci packages (the luci-base dependency resolves from
#       the image feeds - the only matrix step that needs the network)
#   [2] dispatcher fidelity guard: the harness replicates the installed
#       dispatcher's merge/ACL logic verbatim, the pinned lines must exist
#   [3] golden guards: parent node vs the luci-app-wanguard fixture,
#       child node completeness (per-field merge protection, #75)
#   [4] sort-order probes: the #75 A_fixed/A_default lessons, executable
#   [5] tree scenarios: merged / standalone / read-only / ACL-negative
#   [6] byte-identical-parent proof: a parent carrying the luci-app-wanguard
#       ACL group is HIDDEN in standalone mode (dispatcher apply_tree_acls)
#       - which is why the shipped parent carries OUR group (deviation from
#       the issue's literal byte-identity, documented in the issue comment)
#   [7] live menu.d shape with a simulated luci-app-wanguard installed
#   [8] the #80 page scaffold in the package: view/wanguard/antidpi.js +
#       wanguard-antidpi/core.js land at the /www LuCI paths with the
#       structural anchors (core require, status --json exec, the six
#       sub-tabs); the placeholder view stays luci-app-wanguard's file
#   [9] apk del removes the real tab AND the page files, keeps the simulated
#       luci-app-wanguard file and the core package - the Anti-DPI tab falls
#       back to the luci-app-wanguard placeholder (#79 fixture sync)
#
# Usage: test-luci.sh <version>
set -eu

VER="${1:?missing version}"

fail() {
	echo "LUCI-FAIL: $1"
	exit 1
}

expect() { # expect <what> <expected-line> <actual-output>
	printf '%s\n' "$3" | grep -Fqx "$2" \
		|| fail "$1: expected [$2], got: $(printf '%s\n' "$3" | head -n 5)"
}

MENU=/usr/share/luci/menu.d/wanguard-antidpi.json
ACL=/usr/share/rpcd/acl.d/luci-app-wanguard-antidpi.json
FIXT=/tests/fixtures/luci-app-wanguard.menu.json
UC=/tests/luci-menu-test.uc
DISP=/usr/share/ucode/luci/dispatcher.uc

mkdir -p /tmp/luci
printf '%s\n' '{ "access-group": { "luci-app-wanguard": { "read": {}, "write": {} }, "luci-app-wanguard-antidpi": { "read": {}, "write": {} } } }' > /tmp/luci/acl-both.json
printf '%s\n' '{ "access-group": { "luci-app-wanguard-antidpi": { "read": {}, "write": {} } } }' > /tmp/luci/acl-ours.json
printf '%s\n' '{ "access-group": { "luci-app-wanguard-antidpi": { "read": {} } } }' > /tmp/luci/acl-ours-ro.json
printf '%s\n' '{ "access-group": {} }' > /tmp/luci/acl-none.json

echo "== [1] install core + luci packages (luci-base resolves from the image feed)"
apk update >/dev/null
apk add --allow-untrusted /out/*.apk
apk list --installed 2>/dev/null | grep -q "^wanguard-antidpi-$VER " \
	|| fail "core package not registered as wanguard-antidpi-$VER"
apk list --installed 2>/dev/null | grep -q "^luci-app-wanguard-antidpi-$VER " \
	|| fail "luci package not registered as luci-app-wanguard-antidpi-$VER"
apk list --installed 2>/dev/null | grep -q "^luci-base-" \
	|| fail "luci-base dependency did not resolve"
[ -f "$MENU" ] || fail "menu file missing"
[ -f "$ACL" ] || fail "acl file missing"
ls -l "$MENU" | grep -q '^-rw-r--r--' || fail "menu file must be 0644"
ls -l "$ACL" | grep -q '^-rw-r--r--' || fail "acl file must be 0644"

echo "== [2] dispatcher fidelity guard"
[ -f "$DISP" ] || fail "dispatcher.uc not found - luci-base missing?"
while IFS= read -r line; do
	case "$line" in ''|'#'*) continue ;; esac
	grep -qF -- "$line" "$DISP" \
		|| fail "dispatcher line drifted - re-derive tests/luci-menu-test.uc: $line"
done < /tests/luci-dispatcher-lines.txt
echo "DISPATCHER-FIDELITY-OK"

echo "== [3] golden guards (fixture + child completeness)"
out=$(ucode "$UC" parentguard "$FIXT" "$MENU" luci-app-wanguard-antidpi) \
	|| fail "parentguard exited non-zero: $out"
printf '%s\n' "$out" | grep -q '^PARENT-GUARD-OK' || fail "parentguard: $out"
out=$(ucode "$UC" childguard "$MENU") || fail "childguard exited non-zero: $out"
printf '%s\n' "$out" | grep -q '^CHILD-GUARD-OK' || fail "childguard: $out"
echo "GUARDS-OK"

echo "== [4] sort-order probes (#75 A_fixed / A_default, executable)"
mkdir -p /tmp/luci/sort-ok /tmp/luci/sort-bad
# the fixture IS the shipped luci-app-wanguard.json (synced at #79, carries
# the placeholder child); correct name: ours sorts after luci-app-wanguard.json
# -> the real node wins
cp "$FIXT" /tmp/luci/sort-ok/luci-app-wanguard.json
cp "$MENU" /tmp/luci/sort-ok/wanguard-antidpi.json
out=$(ucode "$UC" tree /tmp/luci/sort-ok /tmp/luci/acl-both.json)
expect 'sort-order: wanguard-antidpi.json wins' \
	'wanguard.antidpi: satisfied=1 readonly=0 title=Anti-DPI acl=luci-app-wanguard-antidpi order=35 path=wanguard/antidpi' \
	"$out"
# the default name (luci-app-wanguard-antidpi.json) sorts BEFORE
# luci-app-wanguard.json ('-' < '.'), the placeholder wins - the filename is
# part of the contract
cp "$FIXT" /tmp/luci/sort-bad/luci-app-wanguard.json
cp "$MENU" /tmp/luci/sort-bad/luci-app-wanguard-antidpi.json
out=$(ucode "$UC" tree /tmp/luci/sort-bad /tmp/luci/acl-both.json)
expect 'sort-order: default filename loses to the placeholder' \
	'wanguard.antidpi: satisfied=1 readonly=0 title=Anti-DPI placeholder acl=luci-app-wanguard order=10 path=wanguard/antidpi-placeholder' \
	"$out"
echo "SORTORDER-OK"

echo "== [5] tree scenarios (merged / standalone / read-only / acl-negative)"
mkdir -p /tmp/luci/merged /tmp/luci/standalone /tmp/luci/byteparent
cp "$FIXT" /tmp/luci/merged/luci-app-wanguard.json
cp "$MENU" /tmp/luci/merged/wanguard-antidpi.json
out=$(ucode "$UC" tree /tmp/luci/merged /tmp/luci/acl-both.json)
expect 'merged: parent' \
	'wanguard.parent: satisfied=1 readonly=0 title=WAN Guard acl=luci-app-wanguard-antidpi children=antidpi,devices,diagnostics,groups,overview' \
	"$out"
expect 'merged: antidpi' \
	'wanguard.antidpi: satisfied=1 readonly=0 title=Anti-DPI acl=luci-app-wanguard-antidpi order=35 path=wanguard/antidpi' \
	"$out"

cp "$MENU" /tmp/luci/standalone/wanguard-antidpi.json
out=$(ucode "$UC" tree /tmp/luci/standalone /tmp/luci/acl-ours.json)
expect 'standalone: parent (one tab)' \
	'wanguard.parent: satisfied=1 readonly=0 title=WAN Guard acl=luci-app-wanguard-antidpi children=antidpi' \
	"$out"
expect 'standalone: antidpi' \
	'wanguard.antidpi: satisfied=1 readonly=0 title=Anti-DPI acl=luci-app-wanguard-antidpi order=35 path=wanguard/antidpi' \
	"$out"

out=$(ucode "$UC" tree /tmp/luci/standalone /tmp/luci/acl-ours-ro.json)
expect 'read-only session: readonly flag on antidpi' \
	'wanguard.antidpi: satisfied=1 readonly=1 title=Anti-DPI acl=luci-app-wanguard-antidpi order=35 path=wanguard/antidpi' \
	"$out"

out=$(ucode "$UC" tree /tmp/luci/standalone /tmp/luci/acl-none.json)
expect 'acl-negative: parent hidden' \
	'wanguard.parent: satisfied=0 readonly=0 title=WAN Guard acl=luci-app-wanguard-antidpi children=antidpi' \
	"$out"
expect 'acl-negative: antidpi hidden' \
	'wanguard.antidpi: satisfied=0 readonly=0 title=Anti-DPI acl=luci-app-wanguard-antidpi order=35 path=wanguard/antidpi' \
	"$out"
echo "TREE-OK"

echo "== [6] byte-identical parent would hide the standalone menu (deviation proof)"
# The issue's literal byte-identity (parent acl = luci-app-wanguard) cannot
# ship: in standalone mode that ACL group does not exist, apply_tree_acls()
# marks the parent unsatisfied and the WHOLE Wanguard menu disappears - the
# very scenario the parent duplication exists for. The shipped parent carries
# our own group instead (everything else identical); this scenario pins the
# proof. See the dispatcher apply_tree_acls/check_acl_depends verbatim
# functions in tests/luci-menu-test.uc.
printf '%s\n' \
	'{' \
	'	"admin/network/wanguard": { "title": "WAN Guard", "order": 60, "action": { "type": "firstchild" }, "depends": { "acl": [ "luci-app-wanguard" ] } },' \
	'	"admin/network/wanguard/antidpi": { "title": "Anti-DPI", "order": 35, "action": { "type": "view", "path": "wanguard/antidpi" }, "depends": { "acl": [ "luci-app-wanguard-antidpi" ] } }' \
	'}' > /tmp/luci/byteparent/wanguard-antidpi.json
out=$(ucode "$UC" tree /tmp/luci/byteparent /tmp/luci/acl-ours.json)
expect 'byte-identical parent hidden in standalone (deviation is load-bearing)' \
	'wanguard.parent: satisfied=0 readonly=0 title=WAN Guard acl=luci-app-wanguard children=antidpi' \
	"$out"
echo "BYTEPARENT-PROOF-OK"

echo "== [7] live menu.d shape (simulated luci-app-wanguard installed)"
cp "$FIXT" /usr/share/luci/menu.d/luci-app-wanguard.json
out=$(ucode "$UC" tree /usr/share/luci/menu.d /tmp/luci/acl-both.json)
expect 'live: parent' \
	'wanguard.parent: satisfied=1 readonly=0 title=WAN Guard acl=luci-app-wanguard-antidpi children=antidpi,devices,diagnostics,groups,overview' \
	"$out"
expect 'live: antidpi' \
	'wanguard.antidpi: satisfied=1 readonly=0 title=Anti-DPI acl=luci-app-wanguard-antidpi order=35 path=wanguard/antidpi' \
	"$out"
echo "LIVE-MENU-OK"

echo "== [8] page scaffold + overview + domains + tunnel tabs (issues #80-#83)"
VIEW=/www/luci-static/resources/view/wanguard/antidpi.js
CORE=/www/luci-static/resources/wanguard-antidpi/core.js
[ -f "$VIEW" ] || fail "view missing: $VIEW"
[ -f "$CORE" ] || fail "core module missing: $CORE"
[ ! -f /www/luci-static/resources/view/wanguard/antidpi-placeholder.js ] \
	|| fail "the placeholder view must stay in luci-app-wanguard (wanguard-public)"
ls -l "$VIEW" | grep -q '^-rw-r--r--' || fail "view must be 0644"
ls -l "$CORE" | grep -q '^-rw-r--r--' || fail "core module must be 0644"
grep -qF "'require wanguard-antidpi.core as" "$VIEW" \
	|| fail "view does not require the shared core module"
grep -qF "'require rpc'" "$CORE" || fail "core module lost the rpc dependency"
grep -qF "'require uci'" "$CORE" || fail "core module lost the uci dependency (pending bar)"
grep -qF "'require ui'" "$CORE" || fail "core module lost the ui dependency (notifications)"
grep -qF "'/usr/bin/wanguard-antidpi'" "$CORE" || fail "core module lost the CLI path"
grep -qF "'status', '--json'" "$CORE" \
	|| fail "core module must exec status --json (the #76 surface)"
grep -qF "L.Class.extend" "$CORE" \
	|| fail "core module must yield a LuCI class (module loader contract)"
for tab in overview profiles policies domains tunnel tests; do
	grep -qF "'$tab'" "$CORE" || fail "tab '$tab' missing from the core tab table"
done
# the #81 overview: the on-demand surfaces and the bar's verbs are pinned
# structurally - the strategy words come from engine-cmdline, validation
# from apply --check --json, Review & Apply drives the #77 apply, Discard
# reverts the staged UCI of THIS config only (rpcd uci revert)
grep -qF "'engine-cmdline'" "$CORE" \
	|| fail "overview strategy words must come from engine-cmdline"
grep -qF "'apply', '--check', '--json'" "$CORE" \
	|| fail "validation must run apply --check --json (the #77 preflight)"
grep -qF "'apply', '--json'" "$CORE" \
	|| fail "Review & Apply must run the #77 apply"
grep -qF "method: 'revert'" "$CORE" \
	|| fail "Discard must go through rpcd uci revert (config-scoped)"
grep -qF "'wanguard-antidpi'" "$CORE" \
	|| fail "uci verbs must target the wanguard-antidpi config only"
grep -qF "uci.apply(5)" "$CORE" \
	|| fail "Review & Apply must commit staged UCI (the CLI reads committed only)"
# the ACL carries the bar's uci verbs (read-side badge re-query + write-side
# revert/apply/confirm - rpcd checks method AND config against the ACL) plus
# the #82 editor's staging grants (uci save() sends add/set/delete/order)
grep -qF '"uci": [ "get", "changes" ]' /usr/share/rpcd/acl.d/luci-app-wanguard-antidpi.json \
	|| fail "ACL read class lost the uci get/changes grant"
grep -qF '"uci": [ "add", "apply", "confirm", "delete", "order", "revert", "set" ]' /usr/share/rpcd/acl.d/luci-app-wanguard-antidpi.json \
	|| fail "ACL write class lost the uci staging/apply grants (#82)"
# the #82 Domain lists tab: the section type and the strict-DNS guard are
# pinned structurally - the editor stages client-side and applies through
# the shared save -> apply(5) -> CLI apply pipeline
grep -qF "'domainlist'" "$CORE" \
	|| fail "the domains tab lost the domainlist section type"
grep -qF "domainsModel" "$CORE" \
	|| fail "the domains tab lost its view model (legacy + named lists)"
# the #83 Tunnel protection tab: the strict address validator (the exact
# valid_addr_entry mirror), the view model and the render entry point are
# pinned structurally - the editor stages client-side and applies through
# the shared save -> apply(5) -> CLI apply pipeline
grep -qF "validAddrEntry" "$CORE" \
	|| fail "the tunnel tab lost the strict IPv4/CIDR validator (#83)"
grep -qF "tunnelModel" "$CORE" \
	|| fail "the tunnel tab lost its view model (pins/hosts/status)"
grep -qF "renderTunnel" "$CORE" \
	|| fail "the tunnel tab lost its render entry point"
echo "VIEW-OK"

echo "== [9] apk del removes the real tab, keeps the simulated luci-app-wanguard + core"
apk del luci-app-wanguard-antidpi >/dev/null
[ ! -f "$MENU" ] || fail "apk del left the menu file"
[ ! -f "$ACL" ] || fail "apk del left the acl file"
[ ! -f "$VIEW" ] || fail "apk del left the view file (#80/#81)"
[ ! -f "$CORE" ] || fail "apk del left the core module (#80/#81)"
[ -f /usr/share/luci/menu.d/luci-app-wanguard.json ] \
	|| fail "apk del touched the simulated luci-app-wanguard menu file"
apk list --installed 2>/dev/null | grep -q "^wanguard-antidpi-$VER " \
	|| fail "apk del removed the core package (must stay)"
# #79: the fixture now carries the placeholder child, so the Anti-DPI tab
# FALLS BACK to the luci-app-wanguard stub instead of disappearing - the
# uninstall criterion of the placeholder issue
out=$(ucode "$UC" tree /usr/share/luci/menu.d /tmp/luci/acl-both.json)
expect 'uninstall: luci tabs remain (placeholder child included)' \
	'wanguard.parent: satisfied=1 readonly=0 title=WAN Guard acl=luci-app-wanguard children=antidpi,devices,diagnostics,groups,overview' \
	"$out"
expect 'uninstall: antidpi tab = the #79 placeholder' \
	'wanguard.antidpi: satisfied=1 readonly=0 title=Anti-DPI placeholder acl=luci-app-wanguard order=10 path=wanguard/antidpi-placeholder' \
	"$out"
echo "UNINSTALL-OK"

echo "LUCI-OK ($VER)"
