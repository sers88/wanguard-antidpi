#!/bin/sh
# scripts/container-smoke.sh - install + smoke test of the package inside an
# OpenWrt container. ONE script, TWO modes, so the local dev stand and CI
# (feed.yml feed-test) run byte-identical checks and their results are
# comparable by construction:
#
#   local: /out mounted (ro) with the built *.apk   -> apk add --allow-untrusted
#   feed : /hostkeys mounted (ro) with the feed key -> apk add from signed feed
#
# /scripts must be mounted (ro) too: the upstream engine version pin is read
# from fetch-upstream.sh so the engine-version assertion is independent of
# the package version (dev snapshots are 0.0.0-rN).
#
# Usage: container-smoke.sh <local|feed> <version>
# Structural checks only: no live nft/queue state is touched - live NFQUEUE
# scenarios are gated by the host-kernel probe (kernel-probe.sh) and land
# with the test matrix (issue #63).
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
	[ -f /scripts/fetch-upstream.sh ] || { echo "SMOKE-FAIL: /scripts not mounted"; exit 1; }
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

CLI=/usr/bin/wanguard-antidpi
PKGDIR=/usr/share/wanguard-antidpi

# ---- package registration + stamp ----
apk list --installed 2>/dev/null | grep -q "^wanguard-antidpi-$VER " \
	|| fail "package not registered as wanguard-antidpi-$VER"
[ -f "$PKGDIR/version" ] || fail "version stamp missing"
[ "$(cat "$PKGDIR/version")" = "$VER" ] || fail "stamp does not equal $VER"
"$CLI" | grep -q "$VER" || fail "CLI does not report $VER"

# ---- engine payload (issue #57) ----
[ -x /usr/bin/nfqws2 ] || fail "nfqws2 binary missing"
PIN=$(grep -m1 '^ZAPRET2_VERSION_DEFAULT=' /scripts/fetch-upstream.sh | cut -d= -f2)
[ -n "$PIN" ] || fail "cannot read upstream version pin from /scripts/fetch-upstream.sh"
nfver=$(/usr/bin/nfqws2 --version 2>/dev/null | head -n 1)
case "$nfver" in
	"github version v$PIN "*) ;;
	*) fail "nfqws2 --version ('$nfver') does not match the pinned upstream v$PIN" ;;
esac
for l in zapret-lib zapret-antidpi; do
	f="$PKGDIR/lua/$l.lua.gz"
	[ -f "$f" ] || fail "$f missing"
	# gzip magic 1f 8b (container busybox may lack gunzip/od)
	head -c 2 "$f" | grep -q "$(printf '\037\213')" || fail "$f is not gzip"
done
# gzipped lua is supported natively by nfqws2 (--lua-init=@<file>), verified
# in the container: LuaJIT banner prints, no parse errors (#57 spike)

# ---- ucode control CLI (issue #67; language policy: sh must never return) ----
[ "$(head -n 1 "$CLI")" = "#!/usr/bin/ucode" ] || fail "CLI is not ucode (POSIX sh CLI is retired, docs/ARCHITECTURE.md)"
"$CLI" version >/dev/null 2>&1 || fail "ucode CLI does not execute"
command -v uci >/dev/null || fail "uci binary missing"

# ---- UCI config (issue #67: source of truth is /etc/config/wanguard-antidpi) ----
[ -f /etc/config/wanguard-antidpi ] || fail "uci config missing"
[ "$(uci -q get wanguard-antidpi.engine.qnum)" = "300" ] || fail "config qnum != 300"
[ "$(uci -q get wanguard-antidpi.engine.fwmark)" = "0x40000000" ] || fail "config fwmark != 0x40000000"
[ "$(uci -q get wanguard-antidpi.engine.user)" = "daemon" ] || fail "config user != daemon"
[ "$(uci -q get wanguard-antidpi.engine.debug)" = "0" ] || fail "config debug != 0"
uci -q get wanguard-antidpi.engine.nfqws2_opt >/dev/null 2>&1 \
	&& fail "default strategy not empty (graceful no-op default)"

# ---- own lifecycle scripts ----
sh -n /etc/init.d/wanguard-antidpi || fail "init script syntax"
grep -q '^USE_PROCD=1' /etc/init.d/wanguard-antidpi || fail "init is not procd"
grep -q '^START=25' /etc/init.d/wanguard-antidpi || fail "init START=25 missing"
[ -f "$PKGDIR/wanguard-antidpi.nft" ] || fail "nft template missing"

# ---- engine command line (what the init starts; default no-op golden) ----
cl=$("$CLI" engine-cmdline)
[ "$(printf '%s\n' "$cl" | grep -c .)" = "6" ] \
	|| fail "engine-cmdline: expected exactly 6 argv words with the default config"
case "$cl" in
	*--qnum=300*) ;;
	*) fail "engine-cmdline: no --qnum=300" ;;
esac
case "$cl" in
	*--fwmark=0x40000000*) ;;
	*) fail "engine-cmdline: no --fwmark=0x40000000" ;;
esac
case "$cl" in
	*--user=daemon*) ;;
	*) fail "engine-cmdline: no --user=daemon" ;;
esac
case "$cl" in
	*--debug=1*) fail "engine-cmdline: --debug leaked into default (debug=0)" ;;
esac
[ "$(printf '%s\n' "$cl" | grep -c -- '--lua-init=@')" = "2" ] \
	|| fail "engine-cmdline: expected exactly 2 --lua-init args"
case "$cl" in
	*"$PKGDIR/lua/zapret-lib.lua.gz"*) ;;
	*) fail "engine-cmdline: zapret-lib.lua.gz missing" ;;
esac
case "$cl" in
	*"$PKGDIR/lua/zapret-antidpi.lua.gz"*) ;;
	*) fail "engine-cmdline: zapret-antidpi.lua.gz missing" ;;
esac

# ---- nft render + DRYRUN contract (no live state touched) ----
out=$("$CLI" nft-render)
case "$out" in
	*"queue flags bypass to 300"*) ;;
	*) fail "nft-render: queue rule not rendered with qnum from config" ;;
esac
case "$out" in
	*"table inet wanguard_antidpi"*) ;;
	*) fail "nft-render: own table missing" ;;
esac
out=$(WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" nft-apply)
case "$out" in
	*"DRYRUN"*"queue flags bypass to 300"*) ;;
	*) fail "nft-apply DRYRUN: wrong output" ;;
esac
out=$(WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" nft-flush)
case "$out" in
	*"DRYRUN"*"wanguard_antidpi"*) ;;
	*) fail "nft-flush DRYRUN: wrong output" ;;
esac
# init DRYRUN paths are exercised on hosts with rc.common; here only the CLI
# surface they call is proven (rc.common does not exist in the container)

# ---- smoke set: CLI determinism (bootstrap contract, kept from #56) ----
out1=$("$CLI")
out2=$("$CLI")
[ "$out1" = "$out2" ] || fail "CLI output not deterministic"

echo "SMOKE-OK ($MODE, $VER)"
