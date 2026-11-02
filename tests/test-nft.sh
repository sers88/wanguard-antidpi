#!/bin/sh
# tests/test-nft.sh - the FINAL wanguard_antidpi table, live (issue #61).
# Runs INSIDE an OpenWrt container with --cap-add NET_ADMIN (network for the
# pinned mihomo fetch):
#
#   docker run --rm --cap-add NET_ADMIN \
#     -v <out>:/out:ro -v <tests>:/tests:ro \
#     openwrt/rootfs:x86_64-25.12.6 sh /tests/test-nft.sh
#
# Structural checks always run; the LIVE packet matrix runs only when the
# host kernel supports NFQUEUE (same probe as kernel-probe.sh, inline). On a
# kernel without queue support the script exits 0 with NFT-LIVE-SKIP - live
# verification is then router-acceptance-only (issue #61 task list).
#
# Live matrix (real pinned mihomo as the marked traffic source):
#   - apply -> table shape (priority 101, 2 queue rules, both sets)
#   - apply idempotency: re-apply reproduces the stateless ruleset byte-for-byte
#   - BYPASS: table applied, engine DOWN -> marked tcp/443 traffic flows,
#     the rule counter ticks (packets reached the queue point, bypass released)
#   - engine bind: nfqws2 on the queue -> traffic still flows (no-op strategy)
#   - scope negatives: unmarked traffic (direct curl, mihomo without the mark)
#     never ticks the counters
set -eu

MIHOMO_VERSION=1.19.33
MIHOMO_SHA256=132f6f3edf9a65e62f04853aed3358472e0b2b7666daa8419edfa2ddf5bb6323

CLI=/usr/bin/wanguard-antidpi
TABLE=wanguard_antidpi
CONF=/etc/mihomo/config.yaml
MPORT=17890
PROBE=https://www.cloudflare.com/cdn-cgi/trace
ENG_PID=
M_PID=

fail() {
	echo "NFT-TEST-FAIL: $1"
	exit 1
}

cleanup() {
	[ -n "$ENG_PID" ] && kill "$ENG_PID" 2>/dev/null
	[ -n "$M_PID" ] && kill "$M_PID" 2>/dev/null
	return 0
}
trap cleanup EXIT

tcp_packets() {
	nft list chain inet $TABLE egress 2>/dev/null \
		| sed -n 's/.*counter packets \([0-9]*\) bytes [0-9]* queue.*/\1/p' \
		| head -n 1
}

udp_packets() {
	nft list chain inet $TABLE egress 2>/dev/null \
		| sed -n 's/.*counter packets \([0-9]*\) bytes [0-9]* queue.*/\1/p' \
		| tail -n 1
}

proxied_code() {
	# `|| true` on purpose: curl rc must not trip set -e (AGENTS gotcha) -
	# failures surface as http_code 000 and fail the assert with a message.
	# Network intermittents are a fact of life on this stand: retry, first
	# 200 wins (a partial attempt still ticks the counters, so the counter
	# asserts stay strict)
	local c=""
	for r in 1 2 3; do
		c=$(curl -s -m 20 -x "http://127.0.0.1:$MPORT" -o /dev/null -w '%{http_code}' "$PROBE" || true)
		[ "$c" = "200" ] && { printf '%s' "$c"; return 0; }
		sleep 2
	done
	printf '%s' "$c"
}

direct_code() {
	local c=""
	for r in 1 2 3; do
		c=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$PROBE" || true)
		[ "$c" = "200" ] && { printf '%s' "$c"; return 0; }
		sleep 2
	done
	printf '%s' "$c"
}

# ---- setup: package ----
set -- /out/wanguard-antidpi-*.apk
[ -f "$1" ] || fail "no package in /out"
apk add --allow-untrusted "$@" >/dev/null
apk add curl >/dev/null 2>&1 || true
echo "== package installed: $("$CLI" version)"

# ---- structural (always) ----
r1=$("$CLI" nft-render)
[ "$r1" = "$("$CLI" nft-render)" ] || fail "render not deterministic"
printf '%s\n' "$r1" | grep -qE '@[A-Z_]+@' && fail "unsubstituted placeholder in render"
case "$r1" in *"priority 101"*) ;; *) fail "no priority 101" ;; esac
[ "$(printf '%s\n' "$r1" | grep -c 'queue num 300 bypass')" = "2" ] \
	|| fail "expected exactly 2 queue rules in the render"

# ---- kernel probe (NFQUEUE support) ----
LIVE=1
nft add table inet devprobe61 2>/dev/null || LIVE=0
if [ "$LIVE" = 1 ]; then
	nft add chain inet devprobe61 e '{ type filter hook postrouting priority 400; }' 2>/dev/null || LIVE=0
	nft add rule inet devprobe61 e ip daddr 192.0.2.1 counter queue num 301 bypass 2>/dev/null || LIVE=0
	nft delete table inet devprobe61 2>/dev/null || true
fi
if [ "$LIVE" != 1 ]; then
	echo "NFT-LIVE-SKIP (host kernel lacks NFQUEUE - live matrix is router acceptance only)"
	echo "NFT-TEST-OK (structural)"
	exit 0
fi
echo "== kernel probe: NFQUEUE live scenarios available"

# ---- live setup: pinned mihomo as the marked traffic source ----
cd /tmp
curl -sSL --retry 5 --retry-all-errors --retry-delay 3 -o mihomo.gz "https://github.com/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-amd64-v${MIHOMO_VERSION}.gz"
echo "${MIHOMO_SHA256}  mihomo.gz" | sha256sum -c - >/dev/null || fail "mihomo.gz sha256 mismatch"
gzip -dc mihomo.gz > /usr/bin/mihomo
chmod 755 /usr/bin/mihomo
mkdir -p /etc/mihomo /usr/share/mihomo
cat > "$CONF" <<'EOF'
mixed-port: 17890
routing-mark: 268435456
mode: rule
log-level: warning
rules:
  - MATCH,DIRECT
EOF
mihomo -f "$CONF" -d /usr/share/mihomo >/tmp/mihomo.log 2>&1 &
M_PID=$!
i=0
while [ $i -lt 30 ]; do
	netstat -lnt 2>/dev/null | grep -q ":$MPORT " && break
	i=$((i + 1))
	sleep 1
done
netstat -lnt 2>/dev/null | grep -q ":$MPORT " || fail "mihomo mixed-port did not come up (log: $(tail -2 /tmp/mihomo.log))"
echo "== mihomo up ($(mihomo -v | head -n 1))"

# ---- [1] apply + shape ----
echo "== [1] apply + table shape"
"$CLI" nft-flush >/dev/null
"$CLI" nft-apply >/dev/null
nft list table inet $TABLE >/dev/null || fail "table not applied"
case "$(nft list chain inet $TABLE egress)" in
	*"priority 101"*|*"priority srcnat + 1"*) ;;
	*) fail "applied chain: postrouting priority 101 not in effect" ;;
esac
# nft canonicalizes the queue statement on listing: `queue num 300 bypass`
# (input form) prints as `queue flags bypass to 300`
[ "$(nft list chain inet $TABLE egress | grep -c 'queue flags bypass to 300')" = "2" ] \
	|| fail "applied chain: expected 2 queue rules"
nft list set inet $TABLE local_v4 >/dev/null || fail "local_v4 set missing"
nft list set inet $TABLE proxy_servers >/dev/null || fail "proxy_servers set missing"
[ "$(nft list set inet $TABLE proxy_servers | grep -c 'elements = ')" = "0" ] \
	|| fail "proxy_servers must ship EMPTY (issue #62 fills it)"

# ---- [2] apply idempotency (byte-identical stateless ruleset) ----
echo "== [2] apply idempotency"
nft -s list table inet $TABLE > /tmp/nft-before.txt
"$CLI" nft-apply >/dev/null
nft -s list table inet $TABLE > /tmp/nft-after.txt
cmp -s /tmp/nft-before.txt /tmp/nft-after.txt || fail "re-apply changed the stateless ruleset (duplicate rules?)"
echo "IDEMPOTENT-OK"

# ---- [3] bypass: table applied, engine DOWN, marked traffic flows ----
echo "== [3] bypass (no engine on the queue)"
b1=$(tcp_packets)
code=$(proxied_code)
[ "$code" = "200" ] || fail "marked traffic did NOT flow with the engine down (bypass broken): code=$code"
b2=$(tcp_packets)
[ "$b2" -gt "$b1" ] || fail "bypass fetch did not tick the tcp rule counter ($b1 -> $b2)"
[ "$(udp_packets)" = "0" ] || fail "udp rule ticked without udp traffic"
echo "BYPASS-OK (fetch 200, tcp counter $b1 -> $b2, udp 0)"

# ---- [4] engine binds the queue; traffic still flows ----
echo "== [4] engine bound to the queue"
set -- $("$CLI" engine-cmdline)
prog=$1
shift
"$prog" "$@" >/tmp/nfqws2.log 2>&1 &
ENG_PID=$!
sleep 2
kill -0 "$ENG_PID" 2>/dev/null || fail "engine died on start (log: $(tail -3 /tmp/nfqws2.log))"
e1=$(tcp_packets)
code=$(proxied_code)
[ "$code" = "200" ] || fail "traffic did not flow with the engine bound: code=$code"
e2=$(tcp_packets)
[ "$e2" -gt "$e1" ] || fail "bound-engine fetch did not tick the tcp rule counter ($e1 -> $e2)"
kill "$ENG_PID" 2>/dev/null
ENG_PID=
echo "ENGINE-BIND-OK (fetch 200 through the bound queue, counter $e1 -> $e2)"

# ---- [5] scope negative: unmarked traffic never ticks ----
# (the MARKED mihomo is killed FIRST: its background retries would otherwise
# race the counters - seen once on CI)
echo "== [5] scope negatives (unmarked)"
kill "$M_PID" 2>/dev/null
M_PID=
i=0
while [ $i -lt 15 ]; do
	kill -0 "$M_PID" 2>/dev/null || break
	i=$((i + 1))
	sleep 1
done
n1=$(tcp_packets)
code=$(direct_code)
[ "$code" = "200" ] || fail "direct fetch failed (container egress): code=$code"
sleep 1
[ "$(tcp_packets)" = "$n1" ] || fail "direct (unmarked) fetch ticked the tcp rule counter"
grep -q '^routing-mark' "$CONF" && sed -i '/^routing-mark/d' "$CONF"
mihomo -f "$CONF" -d /usr/share/mihomo >/tmp/mihomo2.log 2>&1 &
M_PID=$!
i=0
while [ $i -lt 30 ]; do
	netstat -lnt 2>/dev/null | grep -q ":$MPORT " && break
	i=$((i + 1))
	sleep 1
done
netstat -lnt 2>/dev/null | grep -q ":$MPORT " || fail "unmarked mihomo did not come up"
n2=$(tcp_packets)
code=$(proxied_code)
[ "$code" = "200" ] || fail "unmarked mihomo fetch failed: $code"
sleep 1
[ "$(tcp_packets)" = "$n2" ] || fail "unmarked mihomo egress ticked the tcp rule counter (scope leak)"
echo "SCOPE-OK (direct + unmarked-mihomo fetches left the counters flat)"

# ---- [6] flush + idempotency ----
echo "== [6] flush"
"$CLI" nft-flush >/dev/null
nft list table inet $TABLE >/dev/null 2>&1 && fail "table survived flush"
"$CLI" nft-flush >/dev/null  # idempotent: second flush must not error
"$CLI" nft-apply >/dev/null  # and apply must come back cleanly
nft list table inet $TABLE >/dev/null || fail "re-apply after flush failed"

echo "NFT-TEST-OK ($MIHOMO_VERSION)"
