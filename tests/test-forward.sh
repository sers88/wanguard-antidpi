#!/bin/sh
# tests/test-forward.sh - the forward-source scope behind SNAT (issue #107).
# tests/test-nft.sh [7] exercises the source match on LOCAL output, which is
# never SNAT'ed - exactly why the docker probes shipped with issue #102 could
# not see the #107 flaw: on a real router the egress chain runs at postrouting
# priority srcnat+1, AFTER fw4 masquerade, so a plain `ip saddr` match only
# ever saw the WAN address and the whole scope stayed inert.
#
# This stand rebuilds the real order inside two containers (orchestrated by
# the feed.yml forward-test job / scripts/dev-test.sh):
#
#   router container (this script): openwrt rootfs, NET_ADMIN, started on the
#     docker default bridge (eth0 = WAN, default route) with a second network
#     attach (eth1 = LAN, 192.168.77.2);
#   client container: openwrt rootfs, NET_ADMIN, 192.168.77.3 on the same
#     user-defined bridge, DEFAULT ROUTE REPLACED to point at the router
#     (192.168.77.2) and a curl loop probing https through the router.
#
# The router enables forwarding and installs a fwdprobe masquerade on the
# client subnet at postrouting priority srcnat - the same slot fw4 uses -
# so it runs BEFORE the wanguard_antidpi egress chain (srcnat+1). With that
# order in place a packet arriving at the egress hook always carries the WAN
# source, and the assertions become discriminating:
#
#   - the fwdprobe masquerade counter ticking proves client traffic crossed
#     the router and was SNAT'ed before the antidpi hook (arbitration);
#   - a source rule holding ONLY the client LAN address can then tick ONLY
#     via the conntrack original tuple (`ct original ip saddr`) - the #107
#     contract;
#   - an out-of-scope source CIDR (TEST-NET-2, never routed here) must stay
#     flat while the same traffic crosses, and the mihomo scope counters
#     must stay flat (forward traffic is unmarked).
#
# Usage (inside the router container):
#   sh /tests/test-forward.sh <wan_if> <lan_if> <client_ip> <lan_cidr>
set -eu

CLI=/usr/bin/wanguard-antidpi
TABLE=wanguard_antidpi

WAN_IF=${1:?usage: test-forward.sh <wan_if> <lan_if> <client_ip> <lan_cidr>}
LAN_IF=${2:?usage: test-forward.sh <wan_if> <lan_if> <client_ip> <lan_cidr>}
CLIENT_IP=${3:?usage: test-forward.sh <wan_if> <lan_if> <client_ip> <lan_cidr>}
LAN_CIDR=${4:?usage: test-forward.sh <wan_if> <lan_if> <client_ip> <lan_cidr>}

fail() {
	echo "FORWARD-TEST-FAIL: $1"
	exit 1
}

masq_packets() {
	# the fwdprobe masquerade counter - SNAT happened in the router at
	# priority srcnat, before the antidpi hook (chain order by priority)
	nft list chain inet fwdprobe srcnat 2>/dev/null \
		| sed -n 's/.*counter packets \([0-9]*\) bytes [0-9]* masquerade.*/\1/p' \
		| head -n 1
}

source_tcp_packets() {
	# the tcp leg of the src_fwlana rule pair (#102 render, #107 match)
	nft list chain inet $TABLE egress 2>/dev/null \
		| grep 'ct original ip saddr @src_fwlana' \
		| grep 'tcp dport 443' \
		| sed -n 's/.*counter packets \([0-9]*\).*/\1/p' \
		| head -n 1
}

mihomo_tcp_packets() {
	# rule #0 - the mihomo scope must not see unmarked forward traffic
	nft list chain inet $TABLE egress 2>/dev/null \
		| grep 'mark & 0x10000000' \
		| grep 'tcp dport 443' \
		| sed -n 's/.*counter packets \([0-9]*\).*/\1/p' \
		| head -n 1
}

num() {
	local v=${1:-}
	[ -n "$v" ] || v=0
	echo "$v"
}

wait_gt() {
	# wait_gt <getter> <baseline> - poll until the counter grows past the
	# baseline; echo the final value, exit 1 on timeout (45 loops x 2s
	# covers a cold client `apk add curl` before the first probe)
	local getter=$1 base=$2 i=0 v=0
	while [ "$i" -lt 45 ]; do
		v=$(num "$($getter)")
		[ "$v" -gt "$base" ] && { echo "$v"; return 0; }
		i=$((i + 1))
		sleep 2
	done
	echo "$v"
	return 1
}

cleanup_nft() {
	"$CLI" nft-flush >/dev/null 2>&1
	nft delete table inet fwdprobe >/dev/null 2>&1
	return 0
}

# ---- setup ----
set -- /out/wanguard-antidpi-*.apk
[ -f "$1" ] || fail "no package in /out"
apk add --allow-untrusted "$@" >/dev/null
echo "== package installed: $("$CLI" version)"

# forwarding must come from the container start (docker --sysctl
# net.ipv4.ip_forward=1): /proc/sys is read-only inside a stock container
fw=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
[ "$fw" = "1" ] || {
	echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null \
		|| fail "forwarding disabled and /proc/sys is read-only - start the router container with --sysctl net.ipv4.ip_forward=1"
}
ip addr show dev "$LAN_IF" >/dev/null 2>&1 || fail "LAN interface $LAN_IF missing (topology mismatch)"
ip addr show dev "$WAN_IF" >/dev/null 2>&1 || fail "WAN interface $WAN_IF missing (topology mismatch)"

# ---- fwdprobe masquerade: the fw4 slot, BEFORE the antidpi hook ----
nft add table inet fwdprobe
nft add chain inet fwdprobe srcnat '{ type nat hook postrouting priority srcnat; policy accept; }'
nft add rule inet fwdprobe srcnat ip saddr "$LAN_CIDR" oifname "$WAN_IF" counter masquerade

# ---- leg 1: out-of-scope source (TEST-NET-2 is never routed here) ----
uci set wanguard-antidpi.fwlana=source
uci set wanguard-antidpi.fwlana.enabled='1'
uci add_list wanguard-antidpi.fwlana.networks='198.51.100.0/24'
uci commit wanguard-antidpi
"$CLI" nft-apply >/dev/null
nft list set inet $TABLE src_fwlana >/dev/null || fail "source set not rendered"
nft list chain inet $TABLE egress | grep -q 'ct original ip saddr @src_fwlana' \
	|| fail "the source rule does not match the conntrack original tuple (issue #107 contract)"

m0=$(num "$(mihomo_tcp_packets)")
masq=$(wait_gt masq_packets 0) \
	|| fail "no client traffic crossed the router (masquerade counter flat) - is the client loop up with its default route via the router?"
s0=$(num "$(source_tcp_packets)")
[ "$s0" = "0" ] || fail "out-of-scope source counter already ticked without traffic: $s0"
sleep 5
s1=$(num "$(source_tcp_packets)")
[ "$s1" = "0" ] || fail "out-of-scope forward traffic ticked the source counter ($s0 -> $s1)"
echo "OUT-OF-SCOPE-OK (client traffic crosses + masquerades, TEST-NET-2 source counter flat)"

# ---- leg 2: the client address itself, behind masquerade ----
uci del_list wanguard-antidpi.fwlana.networks='198.51.100.0/24'
uci add_list wanguard-antidpi.fwlana.networks="${CLIENT_IP}/32"
uci commit wanguard-antidpi
"$CLI" nft-apply >/dev/null
nft list set inet $TABLE src_fwlana | grep -q "$CLIENT_IP" \
	|| fail "client address missing from the source set after the swap"
masq1=$(num "$(masq_packets)")
s1=$(num "$(source_tcp_packets)")
s2=$(wait_gt source_tcp_packets "$s1") \
	|| fail "in-scope forward traffic did NOT tick the source counter ($s1 -> $s2) while masq=$masq1: the source match must read the conntrack ORIGINAL tuple - a post-SNAT packet can never carry $CLIENT_IP in ip saddr (issue #107)"
masq2=$(num "$(masq_packets)")
[ "$masq2" -gt "$masq1" ] || fail "masquerade counter flat during the in-scope leg - arbitration lost (traffic did not cross the router)"
m1=$(num "$(mihomo_tcp_packets)")
[ "$m1" = "$m0" ] || fail "unmarked forward traffic leaked into the mihomo scope counter ($m0 -> $m1)"

echo "FORWARD-OK (masquerade $masq1 -> $masq2, source $s1 -> $s2 on a post-SNAT path whose set holds only $CLIENT_IP = ct original match, mihomo counters flat $m0)"

cleanup_nft
uci delete wanguard-antidpi.fwlana
uci commit wanguard-antidpi
echo "FORWARD-TEST-OK"
