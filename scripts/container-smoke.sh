#!/bin/sh
# scripts/container-smoke.sh - install + smoke test of the package inside an
# OpenWrt container (issue #59). ONE script, TWO modes, so the local dev stand
# and CI (feed.yml feed-test) run byte-identical checks and their results are
# comparable by construction:
#
#   local: /out mounted (ro) with the built *.apk   -> apk add --allow-untrusted
#   feed : /hostkeys mounted (ro) with the feed key -> apk add from signed feed
#
# Usage: container-smoke.sh <local|feed> <version>
# Later matrix slices (issue #63) extend the shared assertion section below.
set -eu

MODE="${1:?usage: container-smoke.sh <local|feed> <version>}"
VER="${2:?missing version}"

case "$MODE" in
local)
	[ -d /out ] || { echo "SMOKE-FAIL: /out not mounted"; exit 1; }
	set -- /out/*.apk
	[ -f "$1" ] || { echo "SMOKE-FAIL: no package in /out"; exit 1; }
	echo "== install (untrusted, local build): $1"
	apk add --allow-untrusted "$@"
	;;
feed)
	[ -f /hostkeys/wanguard-antidpi.pem ] || { echo "SMOKE-FAIL: /hostkeys not mounted"; exit 1; }
	echo "== install (signed feed)"
	cp /hostkeys/wanguard-antidpi.pem /etc/apk/keys/
	echo "https://raw.githubusercontent.com/sers88/wanguard-antidpi/feed/packages/x86_64/packages.adb" \
		>> /etc/apk/repositories.d/customfeeds.list
	apk update
	apk add wanguard-antidpi
	;;
*)
	echo "SMOKE-FAIL: unknown mode '$MODE'"
	exit 1
	;;
esac

fail() {
	echo "SMOKE-FAIL: $1"
	exit 1
}

# layout + build stamp (previously the CI feed-test assertions)
[ -x /usr/bin/wanguard-antidpi ] || fail "/usr/bin/wanguard-antidpi not executable"
[ -f /usr/share/wanguard-antidpi/version ] || fail "version stamp missing"
[ "$(cat /usr/share/wanguard-antidpi/version)" = "$VER" ] || fail "stamp does not equal $VER"
/usr/bin/wanguard-antidpi | grep -q "$VER" || fail "CLI does not report $VER"

# smoke set (extensible per issue #63)
sh -n /usr/bin/wanguard-antidpi || fail "syntax check failed"
out1=$(/usr/bin/wanguard-antidpi)
out2=$(/usr/bin/wanguard-antidpi)
[ "$out1" = "$out2" ] || fail "CLI output not deterministic"
apk list --installed 2>/dev/null | grep -q "^wanguard-antidpi-$VER " \
	|| fail "package not registered as wanguard-antidpi-$VER"

echo "SMOKE-OK ($MODE, $VER)"
