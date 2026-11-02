#!/bin/sh
# tests/test-tunnel.sh - the tunnel exclusion resolver updater, live
# (issue #62). Runs INSIDE an OpenWrt container with --cap-add NET_ADMIN:
#
#   docker run --rm --cap-add NET_ADMIN \
#     -v <out>:/out:ro -v <tests>:/tests:ro \
#     openwrt/rootfs:x86_64-25.12.6 sh /tests/test-tunnel.sh
#
# DNS answers come from a stub `nslookup` on PATH (ucode children spawn via
# /bin/sh, so PATH stubs work - the wanguard-core test pattern): the matrix
# is deterministic and needs no network. The LIVE part exercises real nft
# state (table apply with a populated set). When the host kernel rejects the
# queue statement the script exits 0 with TUNNEL-LIVE-SKIP - live verification
# is then router-acceptance-only (same convention as test-nft.sh).
#
# Matrix:
#   [1] multi-A stub answers -> sorted resolver list in UCI + state file
#   [2] idempotency: same answers -> unchanged, config bytes untouched
#   [3] cross-host dedupe
#   [4] per-host failure tolerated (partial success keeps updating)
#   [5] total failure -> exit 1, last known set kept byte-for-byte
#   [6] expiry: backdated state timestamps -> stale entries dropped
#   [7] live: apply with a populated set -> all elements in the live table
#   [8] re-apply idempotency with a populated set (stateless ruleset bytes)
#   [9] update while the table lives -> fresh answer lands in the live set
#  [10] no-table guard: flushed table -> list saved, table not recreated
#  [11] render/apply refuse garbage in proxy_resolved (injection safety)
set -eu

CLI=/usr/bin/wanguard-antidpi
TABLE=wanguard_antidpi
CONF=/etc/config/wanguard-antidpi
STUB=/tmp/stub-dns
STATE=/usr/share/wanguard-antidpi/tunnel-resolved.state

fail() {
	echo "TUNNEL-TEST-FAIL: $1"
	exit 1
}

stub_set() {
	# stub_set <host> <ip> [<ip>...]   (no ip = host fails to resolve)
	h="$1"
	shift
	if [ "$#" -eq 0 ]; then
		rm -f "$STUB/answers/$h.out"
		return 0
	fi
	{
		echo "Server:    127.0.0.1"
		echo "Address:   127.0.0.1:53"
		echo ""
		echo "Name:      $h"
		i=1
		for ip in "$@"; do
			echo "Address $i: $ip"
			i=$((i + 1))
		done
	} > "$STUB/answers/$h.out"
}

resolved_list() {
	# canonical (sorted) view of the resolver-managed UCI list
	uci -q get wanguard-antidpi.tunnel.proxy_resolved | tr ' ' '\n' | sort | tr '\n' ' '
}

# ---- setup: package + stub ----
set -- /out/wanguard-antidpi-*.apk
[ -f "$1" ] || fail "no package in /out"
apk add --allow-untrusted "$@" >/dev/null
echo "== package installed: $("$CLI" version)"

mkdir -p "$STUB/answers" "$STUB/bin"
cat > "$STUB/bin/nslookup" <<'EOF'
#!/bin/sh
# stub: canned per-host answers; a missing answer file = resolution failure
[ -f "/tmp/stub-dns/answers/$1.out" ] || exit 1
cat "/tmp/stub-dns/answers/$1.out"
exit 0
EOF
chmod 755 "$STUB/bin/nslookup"
PATH="$STUB/bin:$PATH"
export PATH

# ---- config: two hosts + one manual pin ----
uci set wanguard-antidpi.tunnel=tunnel
uci add_list wanguard-antidpi.tunnel.tunnel_hosts='host1.test'
uci add_list wanguard-antidpi.tunnel.tunnel_hosts='host2.test'
uci add_list wanguard-antidpi.tunnel.proxy_servers='203.0.113.1'
uci commit wanguard-antidpi

# ---- [1] multi-A answers -> sorted UCI list + state ----
echo "== [1] multi-A resolution"
stub_set host1.test 192.0.2.11 192.0.2.10
stub_set host2.test 198.51.100.7
out=$("$CLI" tunnel-update)
case "$out" in
	*"tunnel set updated"*) ;;
	*) fail "update did not report a change: $out" ;;
esac
got=$(resolved_list)
[ "$got" = "192.0.2.10 192.0.2.11 198.51.100.7 " ] || fail "proxy_resolved wrong: [$got]"
[ -f "$STATE" ] || fail "state file missing"
[ "$(grep -c . "$STATE")" = "3" ] || fail "state entries != 3"
echo "RESOLVE-OK (sorted into UCI: $got)"

# ---- [2] idempotency ----
echo "== [2] idempotency (same answers)"
md5sum "$CONF" > /tmp/tt-conf.md5
out=$("$CLI" tunnel-update)
case "$out" in
	*"unchanged"*) ;;
	*) fail "rerun not idempotent: $out" ;;
esac
md5sum -c /tmp/tt-conf.md5 >/dev/null || fail "unchanged run touched the config"
echo "IDEMPOTENT-OK (config bytes untouched)"

# ---- [3] cross-host dedupe ----
echo "== [3] cross-host dedupe"
stub_set host2.test 198.51.100.7 192.0.2.10
out=$("$CLI" tunnel-update)
case "$out" in
	*"unchanged"*) ;;
	*) fail "dedupe broke idempotency: $out" ;;
esac
echo "DEDUPE-OK"

# ---- [4] partial failure tolerated ----
echo "== [4] partial failure (host2 down, host1 answers)"
rm -f "$STUB/answers/host2.test.out"
stub_set host1.test 192.0.2.10 192.0.2.11 192.0.2.12
out=$("$CLI" tunnel-update)
case "$out" in
	*"tunnel set updated"*) ;;
	*) fail "partial-failure update did not proceed: $out" ;;
esac
got=$(resolved_list)
[ "$got" = "192.0.2.10 192.0.2.11 192.0.2.12 198.51.100.7 " ] \
	|| fail "post-failure set wrong (fresh + unexpired survivor expected): [$got]"
echo "PARTIAL-FAIL-OK"

# ---- [5] total failure keeps the last known set ----
echo "== [5] total failure (both hosts down)"
rm -f "$STUB/answers/host1.test.out"
md5sum "$CONF" > /tmp/tt-conf.md5
"$CLI" tunnel-update >/tmp/tt-out 2>&1 && fail "total failure must exit 1"
grep -q "keeping the last known set" /tmp/tt-out || fail "no keep-set message"
md5sum -c /tmp/tt-conf.md5 >/dev/null || fail "total failure touched the config"
echo "TOTAL-FAIL-OK (exit 1, config bytes untouched)"

# ---- [6] expiry of backdated state entries ----
echo "== [6] expiry (24h window)"
stub_set host1.test 192.0.2.11
stub_set host2.test 198.51.100.7
sed -i -E 's/^(192\.0\.2\.10|192\.0\.2\.12) [0-9]+$/\1 1000000000/' "$STATE"
out=$("$CLI" tunnel-update)
case "$out" in
	*"tunnel set updated"*) ;;
	*) fail "expiry did not trigger an update: $out" ;;
esac
got=$(resolved_list)
[ "$got" = "192.0.2.11 198.51.100.7 " ] || fail "expired entries not dropped: [$got]"
grep -qE '^(192\.0\.2\.10|192\.0\.2\.12) ' "$STATE" \
	&& fail "expired entries still in the state file (must not accumulate)"
[ "$(grep -c . "$STATE")" = "2" ] || fail "state entries != 2 after expiry"
echo "EXPIRE-OK (stale dropped from UCI, live set and state file)"

# ---- [7] live apply with a populated set ----
echo "== [7] live table apply (populated set)"
LIVE=1
nft add table inet devprobe62 2>/dev/null || LIVE=0
if [ "$LIVE" = 1 ]; then
	nft add chain inet devprobe62 e '{ type filter hook postrouting priority 400; }' 2>/dev/null || LIVE=0
fi
if [ "$LIVE" = 1 ]; then
	nft add rule inet devprobe62 e ip daddr 192.0.2.1 counter queue num 301 bypass 2>/dev/null || LIVE=0
fi
nft delete table inet devprobe62 2>/dev/null || true
if [ "$LIVE" != 1 ]; then
	echo "TUNNEL-LIVE-SKIP (host kernel lacks NFQUEUE - live apply is router acceptance only)"
	echo "TUNNEL-TEST-OK (structural)"
	exit 0
fi
"$CLI" nft-apply >/dev/null
nft list table inet "$TABLE" >/dev/null || fail "table not applied"
els=$(nft list set inet "$TABLE" proxy_servers)
for ip in 203.0.113.1 192.0.2.11 198.51.100.7; do
	printf '%s\n' "$els" | grep -qF "$ip" || fail "live set missing $ip"
done
echo "LIVE-SET-OK (manual pin + resolved answers in the live table)"

# ---- [8] re-apply idempotency (populated set) ----
echo "== [8] re-apply idempotency (populated set)"
nft -s list table inet "$TABLE" > /tmp/tt-nft-before.txt
"$CLI" nft-apply >/dev/null
nft -s list table inet "$TABLE" > /tmp/tt-nft-after.txt
cmp -s /tmp/tt-nft-before.txt /tmp/tt-nft-after.txt \
	|| fail "re-apply changed the stateless ruleset (populated set)"
echo "REAPPLY-IDEMPOTENT-OK"

# ---- [9] update with the table live re-applies it ----
echo "== [9] update while the table lives"
stub_set host1.test 192.0.2.11 192.0.2.14
out=$("$CLI" tunnel-update)
case "$out" in
	*"table re-applied"*) ;;
	*) fail "live update did not re-apply: $out" ;;
esac
nft list set inet "$TABLE" proxy_servers | grep -qF "192.0.2.14" \
	|| fail "fresh answer missing from the live set after re-apply"
echo "LIVE-REAPPLY-OK"

# ---- [10] no-table guard ----
echo "== [10] no-table guard (flushed table must not be recreated)"
"$CLI" nft-flush >/dev/null
nft list table inet "$TABLE" >/dev/null 2>&1 && fail "table should be flushed"
stub_set host1.test 192.0.2.11 192.0.2.13
out=$("$CLI" tunnel-update)
case "$out" in
	*"table absent"*) ;;
	*) fail "no-table guard message missing: $out" ;;
esac
nft list table inet "$TABLE" >/dev/null 2>&1 && fail "update created the table (guard broken)"
got=$(resolved_list)
[ "$got" = "192.0.2.11 192.0.2.13 192.0.2.14 198.51.100.7 " ] || fail "no-table update wrong: [$got]"
echo "NO-TABLE-GUARD-OK"

# ---- [11] render/apply refuse garbage in proxy_resolved ----
echo "== [11] render-injection guard (resolver-managed list)"
uci add_list wanguard-antidpi.tunnel.proxy_resolved='999.999.1.1'
uci commit wanguard-antidpi
"$CLI" nft-render >/dev/null 2>&1 && fail "render accepted garbage in proxy_resolved"
"$CLI" nft-apply >/dev/null 2>&1 && fail "apply accepted garbage in proxy_resolved"
uci del_list wanguard-antidpi.tunnel.proxy_resolved='999.999.1.1'
uci commit wanguard-antidpi
echo "RENDER-GUARD-OK"

# ---- cleanup ----
"$CLI" nft-flush >/dev/null
uci delete wanguard-antidpi.tunnel
uci commit wanguard-antidpi

echo "TUNNEL-TEST-OK"
