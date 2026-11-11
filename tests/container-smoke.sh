#!/bin/sh
# tests/container-smoke.sh - install + smoke test of the package inside an
# OpenWrt container. ONE script, TWO modes, so the local dev stand and CI
# (feed.yml smoke-test / feed-test jobs) run byte-identical checks and their
# results are comparable by construction:
#
#   local: /out mounted (ro) with the built *.apk   -> apk add --allow-untrusted
#   feed : /hostkeys mounted (ro) with the feed key -> apk add from signed feed
#
# Mounts: /tests (this script) AND /scripts (the upstream engine version pin
# is read from fetch-upstream.sh so the engine-version assertion is
# independent of the package version - dev snapshots are 0.0.0-rN).
#
# Usage: container-smoke.sh <local|feed> <version>
# Structural checks only: no live nft/queue state is touched - live NFQUEUE
# scenarios live in tests/test-nft.sh and tests/test-tunnel.sh (self-gated by
# the host-kernel probe; matrix overview: README, issue #63).
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
# strategy words pass through verbatim (issue #64): one UCI list item =
# one argv word. Generic example here - the productive strategy is
# provider-specific and lives outside this repository.
uci add_list wanguard-antidpi.engine.nfqws2_opt='--filter-tcp=443'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--payload=tls_client_hello'
uci commit wanguard-antidpi
cl=$("$CLI" engine-cmdline)
printf '%s\n' "$cl" | grep -Fqx -- '--filter-tcp=443' \
	|| fail "engine-cmdline: strategy word --filter-tcp=443 not rendered verbatim"
printf '%s\n' "$cl" | grep -Fqx -- '--payload=tls_client_hello' \
	|| fail "engine-cmdline: strategy word --payload=tls_client_hello not rendered verbatim"
uci delete wanguard-antidpi.engine.nfqws2_opt
uci commit wanguard-antidpi
[ "$(printf '%s\n' "$("$CLI" engine-cmdline)" | grep -c .)" = "6" ] \
	|| fail "engine-cmdline: default 6-word golden broken after strategy removal"

# ---- nft render + DRYRUN contract (no live state touched) ----
out=$("$CLI" nft-render)
case "$out" in
	*"queue num 300 bypass"*) ;;
	*) fail "nft-render: queue rules not rendered with qnum from config" ;;
esac
case "$out" in
	*"table inet wanguard_antidpi"*) ;;
	*) fail "nft-render: own table missing" ;;
esac
out=$(WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" nft-apply)
case "$out" in
	*"DRYRUN"*"queue num 300 bypass"*) ;;
	*) fail "nft-apply DRYRUN: wrong output" ;;
esac
out=$(WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" nft-flush)
case "$out" in
	*"DRYRUN"*"wanguard_antidpi"*) ;;
	*) fail "nft-flush DRYRUN: wrong output" ;;
esac
# init DRYRUN paths are exercised on hosts with rc.common; here only the CLI
# surface they call is proven (rc.common does not exist in the container)

# ---- final table shape (issue #61) ----
out=$("$CLI" nft-render)
case "$out" in
	*"priority 101"*) ;;
	*) fail "nft-render: postrouting priority 101 missing" ;;
esac
[ "$(printf '%s\n' "$out" | grep -c 'queue num 300 bypass')" = "2" ] \
	|| fail "nft-render: expected exactly 2 queue rules (tcp + udp 443)"
case "$out" in
	*"tcp dport 443 ct original packets 1-20"*) ;;
	*) fail "nft-render: tcp connbytes rule missing" ;;
esac
case "$out" in
	*"udp dport 443 ct original packets 1-5"*) ;;
	*) fail "nft-render: udp connbytes rule missing" ;;
esac
[ "$(printf '%s\n' "$out" | grep -c 'meta mark & 0x10000000 == 0x10000000')" = "2" ] \
	|| fail "nft-render: scope mark match missing on some rules"
[ "$(printf '%s\n' "$out" | grep -c 'meta mark & 0x40000000 == 0')" = "2" ] \
	|| fail "nft-render: desync anti-loop match missing on some rules"
[ "$(printf '%s\n' "$out" | grep -c 'ip daddr != @proxy_servers')" = "2" ] \
	|| fail "nft-render: proxy_servers exclusion missing on some rules"
[ "$(printf '%s\n' "$out" | grep -c 'ip daddr != @local_v4')" = "2" ] \
	|| fail "nft-render: local_v4 exclusion missing on some rules"
case "$out" in
	*"counter"*"queue num 300"*) ;;
	*) fail "nft-render: no counter before queue" ;;
esac
# notrack predefrag (issue #68): engine-generated packets are untracked before
# conntrack - without it a fake that hits a conntrack churn window is
# confirm-dropped by the kernel (rawsend sendto EPERM, insert_failed race)
case "$out" in
	*"priority -401"*"notrack"*) ;;
	*) fail "nft-render: predefrag notrack chain missing (issue #68)" ;;
esac
[ "$(printf '%s\n' "$out" | grep -c 'meta mark & 0x40000000 != 0 notrack')" = "1" ] \
	|| fail "nft-render: expected exactly 1 engine notrack rule"
case "$out" in
	*"set local_v4"*"192.168.0.0/16"*) ;;
	*) fail "nft-render: local_v4 set missing/incomplete" ;;
esac
printf '%s\n' "$out" | grep -qE '@[A-Z_]+@' \
	&& fail "nft-render: unsubstituted placeholder leaked"
# proxy_servers ships EMPTY (issue #62 fills the UCI list; render maps it)
[ "$(printf '%s\n' "$out" | grep -c 'elements = ')" = "1" ] \
	|| fail "nft-render: expected elements only on local_v4 with an empty proxy_servers"
# determinism: same config -> byte-identical render
[ "$out" = "$("$CLI" nft-render)" ] || fail "nft-render not deterministic"
# filled UCI lists -> sorted merged render (issue #62: manual pins UNION
# resolver-managed answers, dedupe, canonical order)
uci set wanguard-antidpi.tunnel=tunnel
uci add_list wanguard-antidpi.tunnel.proxy_servers='192.0.2.7'
uci add_list wanguard-antidpi.tunnel.proxy_servers='192.0.2.0/24'
uci add_list wanguard-antidpi.tunnel.proxy_resolved='192.0.2.7'
uci add_list wanguard-antidpi.tunnel.proxy_resolved='198.51.100.5'
uci commit wanguard-antidpi
out=$("$CLI" nft-render)
case "$out" in
	*"elements = { 192.0.2.0/24, 192.0.2.7, 198.51.100.5 }"*) ;;
	*) fail "nft-render: proxy set merge (manual UNION resolved, dedupe, sorted) broken" ;;
esac
[ "$(printf '%s\n' "$out" | grep -c 'elements = ')" = "2" ] \
	|| fail "nft-render: both sets must carry elements once the lists are filled"
# defense in depth (issue #64): the engine argv carries the SAME merged set
# as one --ipset-exclude-ip word - desync never touches tunnel destinations
# even when a rotated daddr reaches the queue before the nft set updates
cl=$("$CLI" engine-cmdline)
case "$cl" in
	*--ipset-exclude-ip=192.0.2.0/24,192.0.2.7,198.51.100.5*) ;;
	*) fail "engine-cmdline: ipset-exclude-ip (merged tunnel set) missing" ;;
esac
# malformed entries are rejected at render time (render-injection safety) -
# in BOTH lists, manual and resolver-managed
uci delete wanguard-antidpi.tunnel
uci set wanguard-antidpi.tunnel=tunnel
uci add_list wanguard-antidpi.tunnel.proxy_servers='300.1.1.1'
uci commit wanguard-antidpi
"$CLI" nft-render >/dev/null 2>&1 \
	&& fail "nft-render accepted a malformed proxy_servers entry (octet > 255)"
uci delete wanguard-antidpi.tunnel
uci set wanguard-antidpi.tunnel=tunnel
uci add_list wanguard-antidpi.tunnel.proxy_resolved='192.0.2.0/33'
uci commit wanguard-antidpi
"$CLI" nft-render >/dev/null 2>&1 \
	&& fail "nft-render accepted a malformed proxy_resolved entry (mask > 32)"
uci delete wanguard-antidpi.tunnel
uci commit wanguard-antidpi
out=$("$CLI" nft-render)
[ "$(printf '%s\n' "$out" | grep -c 'elements = ')" = "1" ] \
	|| fail "nft-render: config not pristine after the tunnel-section test"

# ---- tunnel resolver updater (issue #62): structural here; the live matrix
# ---- (stub DNS answers + real table state) is tests/test-tunnel.sh
out=$("$CLI" tunnel-update)
case "$out" in
	*"no tunnel hosts"*) ;;
	*) fail "tunnel-update without hosts must be a no-op, got: $out" ;;
esac
out=$(WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" tunnel-update)
case "$out" in
	*"no tunnel hosts"*) ;;
	*) fail "tunnel-update DRYRUN without hosts must be a no-op, got: $out" ;;
esac
out=$("$CLI" tunnel-status)
case "$out" in
	*"hosts: none"*"resolved: none"*"cron: absent"*"table: absent"*"state entries: 0"*) ;;
	*) fail "tunnel-status unexpected on a fresh host: $out" ;;
esac

# cron mechanics (issue #62): one tagged line, foreign lines untouched,
# interval changes update it in place, remove is idempotent
mkdir -p /etc/crontabs
printf '13 5 * * * /usr/bin/foreign-job # keep-me\n' > /etc/crontabs/root
cp /etc/crontabs/root /tmp/smoke-crontab-orig
uci set wanguard-antidpi.tunnel=tunnel
uci add_list wanguard-antidpi.tunnel.tunnel_hosts='tunnel.example.net'
uci commit wanguard-antidpi
"$CLI" cron-install >/dev/null || fail "cron-install failed"
[ "$(grep -c 'wanguard-antidpi-tunnel-update' /etc/crontabs/root)" = "1" ] \
	|| fail "cron-install did not ensure exactly one tagged line"
grep -q 'keep-me' /etc/crontabs/root || fail "cron-install lost a foreign line"
cp /etc/crontabs/root /tmp/smoke-crontab-1
"$CLI" cron-install >/dev/null || fail "cron-install rerun failed"
cmp -s /etc/crontabs/root /tmp/smoke-crontab-1 || fail "cron-install is not idempotent"
uci set wanguard-antidpi.tunnel.update_interval='2'
uci commit wanguard-antidpi
"$CLI" cron-install >/dev/null || fail "cron-install (interval change) failed"
[ "$(grep -c 'wanguard-antidpi-tunnel-update' /etc/crontabs/root)" = "1" ] \
	|| fail "interval change duplicated the cron line"
grep -q '0 \*/2 \* \* \*' /etc/crontabs/root || fail "interval change not applied to the line"
cp /etc/crontabs/root /tmp/smoke-crontab-2
out=$(WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" cron-install)
case "$out" in
	*"DRYRUN"*"cron line"*) ;;
	*) fail "cron-install DRYRUN: wrong output" ;;
esac
cmp -s /etc/crontabs/root /tmp/smoke-crontab-2 || fail "cron-install DRYRUN touched the crontab"
"$CLI" cron-remove >/dev/null || fail "cron-remove failed"
grep -q 'wanguard-antidpi-tunnel-update' /etc/crontabs/root \
	&& fail "cron-remove left the tagged line"
grep -q 'keep-me' /etc/crontabs/root || fail "cron-remove lost a foreign line"
"$CLI" cron-remove >/dev/null || fail "cron-remove rerun (idempotent) failed"
# disabled / empty modes keep the crontab clean
uci set wanguard-antidpi.tunnel.update_interval='0'
uci commit wanguard-antidpi
"$CLI" cron-install >/dev/null || fail "cron-install (disabled) failed"
grep -q 'wanguard-antidpi-tunnel-update' /etc/crontabs/root \
	&& fail "cron-install scheduled despite update_interval=0"
uci delete wanguard-antidpi.tunnel
uci commit wanguard-antidpi
out=$("$CLI" cron-install)
case "$out" in
	*"no tunnel hosts"*) ;;
	*) fail "cron-install without hosts must be a no-op, got: $out" ;;
esac
cmp -s /etc/crontabs/root /tmp/smoke-crontab-orig || fail "crontab not restored"
rm -f /tmp/smoke-crontab-orig /tmp/smoke-crontab-1 /tmp/smoke-crontab-2

# ---- SNI whitelist (issue #70): structural here. The pinned-binary facts
# ---- (per-profile hostlist binding, SIGHUP list reload, missing-file start
# ---- refusal, no mtime auto-reload) are proven in the container against the
# ---- engine itself and documented in the CLI header.
out=$("$CLI" whitelist-status)
case "$out" in
	*"enabled: 0"*"file: absent"*"engine argv: not included"*) ;;
	*) fail "whitelist-status unexpected on a fresh host: $out" ;;
esac
# enabled + domains -> the file is rendered (dedupe + canonical order)
uci set wanguard-antidpi.whitelist=whitelist
uci set wanguard-antidpi.whitelist.enabled='1'
uci add_list wanguard-antidpi.whitelist.domains='rutracker.org'
uci add_list wanguard-antidpi.whitelist.domains='ej.ru'
uci add_list wanguard-antidpi.whitelist.domains='bbc.com'
uci add_list wanguard-antidpi.whitelist.domains='ej.ru'
uci commit wanguard-antidpi
"$CLI" whitelist-refresh >/dev/null || fail "whitelist-refresh failed"
printf 'bbc.com\nej.ru\nrutracker.org\n' > /tmp/smoke-wl-expected
cmp -s "$PKGDIR/whitelist.hosts" /tmp/smoke-wl-expected \
	|| fail "whitelist-refresh: file is not the sorted deduped domain list"
cp "$PKGDIR/whitelist.hosts" /tmp/smoke-wl-1
"$CLI" whitelist-refresh >/dev/null || fail "whitelist-refresh rerun failed"
cmp -s "$PKGDIR/whitelist.hosts" /tmp/smoke-wl-1 || fail "whitelist-refresh is not idempotent"
out=$(WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" whitelist-refresh)
case "$out" in
	*DRYRUN*"whitelist.hosts"*) ;;
	*) fail "whitelist-refresh DRYRUN: wrong output" ;;
esac
cmp -s "$PKGDIR/whitelist.hosts" /tmp/smoke-wl-1 || fail "whitelist-refresh DRYRUN touched the file"
# engine argv: the hostlist directly precedes the strategy words (same
# profile) and is re-emitted after every --new (per-profile binding)
uci add_list wanguard-antidpi.engine.nfqws2_opt='--filter-tcp=443'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--payload=tls_client_hello'
uci commit wanguard-antidpi
cl=$("$CLI" engine-cmdline)
[ "$(printf '%s\n' "$cl" | grep -c .)" = "9" ] \
	|| fail "engine-cmdline: expected 6 golden + hostlist + 2 strategy words"
[ "$(printf '%s\n' "$cl" | grep -c -- '--hostlist=')" = "1" ] \
	|| fail "engine-cmdline: expected exactly one --hostlist for a single profile"
printf '%s\n' "$cl" | tail -n 3 > /tmp/smoke-wl-tail
printf '%s\n' "--hostlist=$PKGDIR/whitelist.hosts" '--filter-tcp=443' '--payload=tls_client_hello' \
	> /tmp/smoke-wl-tail-expected
cmp -s /tmp/smoke-wl-tail /tmp/smoke-wl-tail-expected \
	|| fail "engine-cmdline: --hostlist must directly precede the strategy words"
uci delete wanguard-antidpi.engine.nfqws2_opt
uci add_list wanguard-antidpi.engine.nfqws2_opt='--filter-tcp=443'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--new'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--filter-udp=443'
uci commit wanguard-antidpi
[ "$(printf '%s\n' "$("$CLI" engine-cmdline)" | grep -c -- '--hostlist=')" = "2" ] \
	|| fail "engine-cmdline: hostlist not re-emitted after --new (per-profile binding)"
# whitelist-reload: DRYRUN touches nothing; no running engine -> graceful no-op
out=$(WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" whitelist-reload)
case "$out" in
	*DRYRUN*"HUP"*) ;;
	*) fail "whitelist-reload DRYRUN: wrong output" ;;
esac
out=$("$CLI" whitelist-reload)
case "$out" in
	*"engine not running"*) ;;
	*) fail "whitelist-reload without a running engine must be a graceful no-op, got: $out" ;;
esac
out=$("$CLI" whitelist-status)
case "$out" in
	*"enabled: 1"*"file: present (3 hosts)"*"engine argv: --hostlist included"*) ;;
	*) fail "whitelist-status: wrong state in whitelist mode: $out" ;;
esac
# enabled + EMPTY strategy -> nothing to constrain, default golden untouched
uci delete wanguard-antidpi.engine.nfqws2_opt
uci commit wanguard-antidpi
[ "$(printf '%s\n' "$("$CLI" engine-cmdline)" | grep -c -- '--hostlist=')" = "0" ] \
	|| fail "engine-cmdline: --hostlist leaked with an empty strategy"
# validation negatives: garbage domains die loudly at render time, file intact
for bad in 'bad,comma' '*.wildcard.example' 'localhost' 'bad space.example' '.leadingdot.example'; do
	uci delete wanguard-antidpi.whitelist.domains
	uci add_list wanguard-antidpi.whitelist.domains="$bad"
	uci commit wanguard-antidpi
	"$CLI" whitelist-refresh >/dev/null 2>&1 \
		&& fail "whitelist-refresh accepted a garbage domain: $bad"
	"$CLI" engine-cmdline >/dev/null 2>&1 \
		&& fail "engine-cmdline accepted a garbage domain: $bad"
done
cmp -s "$PKGDIR/whitelist.hosts" /tmp/smoke-wl-1 \
	|| fail "garbage domains damaged the rendered file"
# disabled mode removes the file (blanket mode), argv loses the hostlist
uci set wanguard-antidpi.whitelist.enabled='0'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--filter-tcp=443'
uci commit wanguard-antidpi
"$CLI" whitelist-refresh >/dev/null || fail "whitelist-refresh (disable) failed"
[ ! -f "$PKGDIR/whitelist.hosts" ] || fail "whitelist-refresh (disable) left the hostlist file"
[ "$(printf '%s\n' "$("$CLI" engine-cmdline)" | grep -c -- '--hostlist=')" = "0" ] \
	|| fail "engine-cmdline: --hostlist leaked with whitelist disabled"
# pristine state for the rest of the smoke
uci delete wanguard-antidpi.whitelist
uci delete wanguard-antidpi.engine.nfqws2_opt
uci commit wanguard-antidpi
[ ! -f "$PKGDIR/whitelist.hosts" ] || fail "pristine: hostlist file left behind"
[ "$(printf '%s\n' "$("$CLI" engine-cmdline)" | grep -c .)" = "6" ] \
	|| fail "engine-cmdline: default 6-word golden broken after the whitelist tests"
rm -f /tmp/smoke-wl-expected /tmp/smoke-wl-1 /tmp/smoke-wl-tail /tmp/smoke-wl-tail-expected

# ---- mihomo routing-mark integration (issue #60; no mihomo binary/process
# ---- in this container - the graceful paths plus the file mechanics) ----
out=$("$CLI" mark-status)
case "$out" in
	*"install-on-start: enabled"*) ;;
	*) fail "mark-status: install-on-start not enabled on a fresh host" ;;
esac
case "$out" in
	*"mark: no-config"*) ;;
	*) fail "mark-status: expected no-config on a fresh host" ;;
esac
mkdir -p /etc/mihomo
printf 'mixed-port: 17890\nmode: rule\nlog-level: warning\nexternal-controller: 127.0.0.1:19090\nsecret: marktest\n' > /etc/mihomo/config.yaml
cp /etc/mihomo/config.yaml /tmp/smoke-mihomo-orig.yaml
out=$(WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" mark-install)
case "$out" in
	*DRYRUN*) ;;
	*) fail "mark-install DRYRUN: no DRYRUN marker" ;;
esac
cmp -s /etc/mihomo/config.yaml /tmp/smoke-mihomo-orig.yaml || fail "mark-install DRYRUN touched the config"
[ ! -f /etc/mihomo/config.yaml.bak-wanguard-antidpi ] || fail "mark-install DRYRUN created a backup"
"$CLI" mark-install >/dev/null || fail "mark-install failed"
[ "$(head -n 1 /etc/mihomo/config.yaml)" = "routing-mark: 268435456" ] \
	|| fail "mark-install: routing-mark line not prepended"
l1=$(wc -l < /tmp/smoke-mihomo-orig.yaml)
l2=$(wc -l < /etc/mihomo/config.yaml)
[ "$((l1 + 1))" = "$l2" ] || fail "mark-install: diff is not exactly one line ($l1 -> $l2)"
[ -f /etc/mihomo/config.yaml.bak-wanguard-antidpi ] || fail "mark-install: backup missing"
out=$("$CLI" mark-install)
case "$out" in
	*"already installed"*) ;;
	*) fail "mark-install is not idempotent" ;;
esac
out=$("$CLI" mark-status)
case "$out" in
	*"mark: installed"*) ;;
	*) fail "mark-status: not installed after install" ;;
esac
case "$out" in
	*"api: 127.0.0.1:19090"*) ;;
	*) fail "mark-status: api endpoint not parsed from the config" ;;
esac
"$CLI" mark-remove >/dev/null || fail "mark-remove failed"
cmp -s /etc/mihomo/config.yaml /tmp/smoke-mihomo-orig.yaml \
	|| fail "mark-remove did not restore the original bytes"
out=$("$CLI" mark-status)
case "$out" in
	*"install-on-start: disabled"*) ;;
	*) fail "mark-remove: install-on-start not disarmed" ;;
esac
out=$("$CLI" mark-ensure)
case "$out" in
	*"disabled"*) ;;
	*) fail "mark-ensure did not honor the disarm stamp" ;;
esac
cmp -s /etc/mihomo/config.yaml /tmp/smoke-mihomo-orig.yaml \
	|| fail "mark-ensure injected despite the disarm stamp"
# surgical fallback (no backup): byte-faithful single-line removal
"$CLI" mark-install >/dev/null || fail "mark-install (for surgical) failed"
rm -f /etc/mihomo/config.yaml.bak-wanguard-antidpi
"$CLI" mark-remove >/dev/null || fail "surgical mark-remove failed"
cmp -s /etc/mihomo/config.yaml /tmp/smoke-mihomo-orig.yaml \
	|| fail "surgical removal did not reproduce the original bytes"
# conflict: a foreign routing-mark value is never touched
printf 'routing-mark: 12345\nmode: rule\n' > /etc/mihomo/config.yaml
cp /etc/mihomo/config.yaml /tmp/smoke-mihomo-conflict.yaml
"$CLI" mark-install >/dev/null 2>&1 && fail "mark-install did not fail on a foreign routing-mark"
cmp -s /etc/mihomo/config.yaml /tmp/smoke-mihomo-conflict.yaml \
	|| fail "conflict: config was modified"
out=$("$CLI" mark-status)
case "$out" in
	*"mark: conflict (12345)"*) ;;
	*) fail "mark-status: conflict not reported" ;;
esac
rm -rf /etc/mihomo /tmp/smoke-mihomo-orig.yaml /tmp/smoke-mihomo-conflict.yaml

# ---- conffile contract (issue #63 matrix slice 1): apk3 protects /etc -
# ---- a user-modified config must survive a reinstall of the SAME version,
# ---- and the incoming default must land next to it as *.apk-new (verified
# ---- empirically on the image's apk-tools 3.0.5). Runs last: the probe
# ---- option stays in the config afterwards (the container is ephemeral).
echo "== conffile: modified config survives a reinstall"
uci set wanguard-antidpi.engine.conffile_probe='1'
uci commit wanguard-antidpi
case "$MODE" in
local)
	apk add --allow-untrusted --force-reinstall /out/*.apk >/dev/null
	;;
feed)
	apk add --force-reinstall wanguard-antidpi >/dev/null
	;;
esac
[ "$(uci -q get wanguard-antidpi.engine.conffile_probe)" = "1" ] \
	|| fail "conffile: user modification did not survive the reinstall"
[ -f /etc/config/wanguard-antidpi.apk-new ] \
	|| fail "conffile: incoming default did not land as *.apk-new"
grep -q conffile_probe /etc/config/wanguard-antidpi \
	|| fail "conffile: probe option lost from the config file"
echo "CONFFILE-OK (modification survived, default next to it as .apk-new)"

# ---- smoke set: CLI determinism (bootstrap contract, kept from #56) ----
out1=$("$CLI")
out2=$("$CLI")
[ "$out1" = "$out2" ] || fail "CLI output not deterministic"

echo "SMOKE-OK ($MODE, $VER)"
