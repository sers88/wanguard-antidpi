#!/bin/sh
# tests/test-policies.sh - ordered match -> action policies (issue #86).
# Runs INSIDE an OpenWrt container (no NET_ADMIN for the structural part;
# the live scenarios probe NFQUEUE first):
#
#   docker run --rm -v <out>:/out:ro -v <tests>:/tests:ro \
#     openwrt/rootfs:x86_64-25.12.6 sh /tests/test-policies.sh
#
# The render contract under test (engine_argv, design §3):
#   - no policy sections / all disabled -> the pure #84 profiles render
#     (byte-identical criterion)
#   - policies render as FIRST profile blocks, catch-all (the global
#     strategy) last, joined with --new; first match wins
#   - order = `option priority` ascending, ties keep the section file order
#   - action=bypass: proto filters + payload + hostlist, NO desync words
#     (spike-75 §1.2: pass unmodified)
#   - action=strategy: proto filters + payload + hostlist + the profile's
#     desync words (the profile's own --filter-*/--payload words excluded)
#   - action=none: no block, but the policy stays validated loudly
#   - validations die named: domainlist/profile refs, action value, proto
#     tokens, empty proto; disabled policies skip validation (#84 precedent)
#   - policies + whitelist mode: the whitelist binding is IGNORED (warn),
#     each block carries its own per-list hostlist file
#   - whitelist-refresh writes lists/<sid>.hosts per referenced list
#     (dedupe + sort + LF, 0644, verify-after-write)
#
# Matrix:
#   [1]  no policies -> byte-identical golden + profiles render
#   [2]  all policies disabled -> byte-identical
#   [3]  bypass policy: block shape, list file render (content/0644),
#        catch-all position; priority default (missing -> 100)
#   [4]  strategy policy: proto filters + profile desync words, filter
#        words excluded, catch-all = the profiles render
#   [5]  priority ordering: out-of-file-order 20/10 renders by priority;
#        equal priorities keep the file order
#   [6]  action=none: no block; enabled none-policy still validated
#   [7]  validations: bad list ref / bad profile ref / bad action / empty
#        proto / unknown token die named; disabled bad policy is skipped
#   [8]  policies + whitelist mode -> binding IGNORED (warn), argv carries
#        the policy hostlists only
#   [9]  status --json: policies count, policy_sections fields, hostlists
#   [10] live (NFQUEUE): 2 policies (bypass + strategy) -> engine starts,
#        fetch flows, running argv carries both blocks
#   [11] live send inventory (spike-75 §1.2 against the CLI-rendered argv):
#        bypass-listed SNI passes the ClientHello UNMODIFIED (single
#        segment), non-listed SNI is split by the catch-all desync
# set -eu

CLI=/usr/bin/wanguard-antidpi
CONF=/etc/config/wanguard-antidpi
BASE=/usr/share/wanguard-antidpi
JS=/tmp/policies-status.json
MIHOMO_VERSION=1.19.33
MIHOMO_SHA256=132f6f3edf9a65e62f04853aed3358472e0b2b7666daa8419edfa2ddf5bb6323
MPORT=17890
PROBE=https://www.cloudflare.com/cdn-cgi/trace
ENG_PID=
M_PID=

fail() {
	echo "POLICIES-TEST-FAIL: $1"
	exit 1
}

cleanup() {
	[ -n "$ENG_PID" ] && kill "$ENG_PID" 2>/dev/null
	[ -n "$M_PID" ] && kill "$M_PID" 2>/dev/null
	nft delete table inet policies86 2>/dev/null
	return 0
}
trap cleanup EXIT

words() { # argv words without the binary line
	"$CLI" engine-cmdline 2>/tmp/policies-err.log | tail -n +2
}

wc_lines() { words | grep -c . || true; }

has() { words | grep -qF -- "$1"; }

lacks() { words | grep -qF -- "$1" && fail "unexpected word: $1" || :; }

nth() { words | sed -n "$1p"; }

grab() {
	"$CLI" status --json > "$JS" || fail "status --json exited nonzero"
}

jp() { # jp '<ucode expr over s>'
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all')); printf('%J\n', ($1));"
}

jp_str() {
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all')); printf('%s\n', ($1));"
}

add_list_sec() { # add_list_sec <sid> <domain>...
	local sid=$1
	shift
	uci set "$CONF.$sid=domainlist"
	uci set "$CONF.$sid.name=$sid label"
	local d
	for d in "$@"; do
		uci add_list "$CONF.$sid.domains=$d"
	done
}

add_prof() { # add_prof <sid> <enabled:1|0|unset> <word>...
	local sid=$1 en=$2
	shift 2
	uci set "$CONF.$sid=profile"
	uci set "$CONF.$sid.name=$sid label"
	case "$en" in
		0) uci set "$CONF.$sid.enabled=0" ;;
		1) uci set "$CONF.$sid.enabled=1" ;;
	esac
	local w
	for w in "$@"; do
		uci add_list "$CONF.$sid.strategy_words=$w"
	done
}

add_pol() { # add_pol <sid> <priority> <action> <list> <proto> <profile> [enabled]
	local sid=$1 pri=$2 act=$3 lst=$4 proto=$5 prof=$6 en=${7:-1}
	uci set "$CONF.$sid=policy"
	uci set "$CONF.$sid.name=$sid label"
	uci set "$CONF.$sid.priority=$pri"
	uci set "$CONF.$sid.action=$act"
	uci set "$CONF.$sid.domainlist=$lst"
	uci set "$CONF.$sid.proto=$proto"
	[ -z "$prof" ] || uci set "$CONF.$sid.profile=$prof"
	[ "$en" = "1" ] || uci set "$CONF.$sid.enabled=$en"
}

# ---- setup ----
set -- /out/wanguard-antidpi-*.apk
[ -f "$1" ] || fail "no package in /out"
apk add --allow-untrusted "$@" >/dev/null
apk add curl >/dev/null 2>&1 || true
echo "== package installed: $("$CLI" version)"

# ---- [1] no policies -> byte-identical ----
echo "== [1] no policy sections (byte-identical criterion)"
[ "$(wc_lines)" = "5" ] || fail "pristine default must render the 5 base words, got $(wc_lines)"
lacks '--new'
# with a profile configured the render must equal the #84 profiles render
# (policies absent) - render twice with/without a disabled policy section
uci add_list "$CONF.engine.nfqws2_opt=--filter-tcp=443"
uci add_list "$CONF.engine.nfqws2_opt=--payload=tls_client_hello"
uci commit "$CONF"
uci delete "$CONF.engine.nfqws2_opt"
add_list_sec list_media media.example.org video.example.net
add_prof prof_a 1 --filter-tcp=443 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld
add_pol pol_off 10 strategy list_media tcp prof_a 0
uci commit "$CONF"
B=$("$CLI" engine-cmdline 2>/dev/null)
uci delete "$CONF.pol_off"
uci commit "$CONF"
C=$("$CLI" engine-cmdline 2>/dev/null)
[ "$B" = "$C" ] || fail "a disabled policy section changed the render (byte-identical criterion broken)"
echo "NO-POLICIES-OK (absent and all-disabled policies keep the #84 render byte-identical)"

# ---- [3] bypass policy: block shape + list file ----
echo "== [3] bypass policy (block shape, list file, catch-all position)"
add_pol pol_bypass 10 bypass list_media tcp ''
uci commit "$CONF"
"$CLI" whitelist-refresh >/dev/null || fail "whitelist-refresh exited nonzero"
# the list file: referenced list's domains only, canonical order, 0644
LF="$BASE/lists/list_media.hosts"
[ -f "$LF" ] || fail "policy list file missing: $LF"
[ "$(cat "$LF")" = "media.example.org
video.example.net" ] || fail "policy list content wrong: $(cat "$LF")"
[ "$(ls -l "$LF" | awk '{print $1}')" = "-rw-r--r--" ] || fail "policy list must be 0644, got $(ls -l "$LF" | awk '{print $1}')"
# argv: base(5) + bypass block(3: filter/payload/hostlist) + --new + catch-all(3).
# The FIRST block continues the base segment (an empty leading --new-less
# segment would count as a filterless match-everything profile)
[ "$(wc_lines)" = "12" ] || fail "expected 12 argv lines (5 base + 3 bypass + --new + 3 catch-all), got $(wc_lines)"
[ "$(nth 6)" = "--filter-tcp=443" ] || fail "bypass block must start with the proto filter, got: $(nth 6)"
[ "$(nth 7)" = "--payload=tls_client_hello" ] || fail "bypass block payload word wrong: $(nth 7)"
[ "$(nth 8)" = "--hostlist=$LF" ] || fail "bypass block hostlist wrong: $(nth 8)"
[ "$(nth 9)" = "--new" ] || fail "expected --new before the catch-all, got: $(nth 9)"
[ "$(nth 10)" = "--filter-tcp=443" ] || fail "catch-all (profiles render) misplaced: $(nth 10)"
has '--lua-desync=multisplit:pos=midsld'
# the bypass block must carry NO desync words: the only lua-desync lives in the catch-all
[ "$(words | grep -c 'lua-desync')" = "1" ] || fail "bypass block must not carry desync words"
echo "BYPASS-BLOCK-OK (filters+payload+hostlist, no desync words; list file rendered 0644)"

# ---- [4] strategy policy: profile desync words ride, filter words excluded ----
echo "== [4] strategy policy"
uci delete "$CONF.pol_bypass"
add_prof prof_b 1 --filter-tcp=8443 --payload=tls_client_hello --lua-desync=fake:repeats=2
add_pol pol_strat 10 strategy list_media tcp prof_b
uci commit "$CONF"
# layout: base(5) + strat block(4) + --new + prof_a(3) + --new + prof_b(3)
[ "$(nth 6)" = "--filter-tcp=443" ] || fail "strategy block filters must come from the policy proto (443), got: $(nth 6)"
[ "$(nth 7)" = "--payload=tls_client_hello" ] || fail "strategy block payload wrong: $(nth 7)"
[ "$(nth 8)" = "--hostlist=$LF" ] || fail "strategy block hostlist wrong: $(nth 8)"
[ "$(nth 9)" = "--lua-desync=fake:repeats=2" ] || fail "profile desync word must ride verbatim, got: $(nth 9)"
# (the profile's --filter-tcp=8443 stays excluded from the BLOCK - covered
# by the exact positions above; the word legitimately reappears later when
# prof_b renders its own catch-all block)
# catch-all = the FULL profiles render (prof_a --new prof_b), catch-all last
[ "$(nth 10)" = "--new" ] || fail "expected --new before the catch-all, got: $(nth 10)"
[ "$(nth 11)" = "--filter-tcp=443" ] || fail "catch-all prof_a misplaced: $(nth 11)"
[ "$(nth 13)" = "--lua-desync=multisplit:pos=midsld" ] || fail "catch-all prof_a last word wrong: $(nth 13)"
[ "$(nth 14)" = "--new" ] || fail "catch-all profiles need their own separator: $(nth 14)"
[ "$(nth 15)" = "--filter-tcp=8443" ] || fail "catch-all prof_b keeps its own filters: $(nth 15)"
echo "STRATEGY-BLOCK-OK (proto filters + profile desync words; profile filters excluded from the block)"

# ---- [5] priority ordering ----
echo "== [5] priority order (20/10 out of file order; tie keeps file order)"
uci delete "$CONF.prof_b.strategy_words" 2>/dev/null || :
add_prof prof_b 1 --filter-tcp=8443 --payload=tls_client_hello --lua-desync=fake:repeats=2
uci set "$CONF.pol_strat.priority=20"
add_list_sec list_second second.example.org
add_pol pol_first 10 bypass list_second tcp ''
uci commit "$CONF"
"$CLI" whitelist-refresh >/dev/null
# pol_first (10) renders BEFORE pol_strat (20) even though pol_strat is
# earlier in the file; hostlist paths name their lists.
# Layout: base(5) pol_first(3) --new pol_strat(4) --new catch-all
[ "$(nth 8)" = "--hostlist=$BASE/lists/list_second.hosts" ] || fail "priority 10 must render first: $(nth 8)"
[ "$(nth 9)" = "--new" ] || fail "expected --new between the policy blocks, got: $(nth 9)"
[ "$(nth 12)" = "--hostlist=$LF" ] || fail "priority 20 must render second: $(nth 12)"
# tie: same priority -> section file order (pol_strat is first in the file)
uci set "$CONF.pol_first.priority=20"
uci commit "$CONF"
[ "$(nth 8)" = "--hostlist=$LF" ] || fail "equal priorities must keep the section file order (pol_strat first): $(nth 8)"
echo "PRIORITY-ORDER-OK (ascending priority, ties keep the file order)"

# ---- [6] action=none ----
echo "== [6] action=none renders no block"
uci set "$CONF.pol_strat.action=none"
uci commit "$CONF"
N0=$(wc_lines)
lacks "--hostlist=$LF"
has "--hostlist=$BASE/lists/list_second.hosts"
# an enabled none-policy is still validated: break the surviving bypass
# policy's ref -> the render must die with the policy named
uci set "$CONF.pol_first.domainlist=list_nope"
uci commit "$CONF"
RC=0
"$CLI" engine-cmdline >/dev/null 2>/tmp/policies-err.log || RC=$?
[ "$RC" != 0 ] || fail "an enabled none-order policy with a broken ref must fail the render"
grep -q 'pol_first' /tmp/policies-err.log || fail "the die must name the broken policy"
uci set "$CONF.pol_first.domainlist=list_second"
uci set "$CONF.pol_strat.action=strategy"
uci commit "$CONF"
echo "NONE-ACTION-OK (no block, refs still validated loudly)"

# ---- [7] validations die named; disabled skips ----
echo "== [7] validations"
chk_die() { # chk_die <name> <needle>
	local RC=0
	"$CLI" engine-cmdline >/dev/null 2>/tmp/policies-err.log || RC=$?
	[ "$RC" != 0 ] || fail "$1: expected a loud render failure"
	grep -q "$2" /tmp/policies-err.log || fail "$1: die must name '$2' (got: $(cat /tmp/policies-err.log))"
}
uci set "$CONF.pol_strat.profile=prof_nope"
uci commit "$CONF"
chk_die "bad profile ref" "prof_nope"
uci set "$CONF.pol_strat.profile=prof_b"
uci set "$CONF.pol_strat.action=destroy"
uci commit "$CONF"
chk_die "bad action" "destroy"
uci set "$CONF.pol_strat.action=strategy"
uci set "$CONF.pol_strat.proto=smtp"
uci commit "$CONF"
chk_die "unknown proto token" "smtp"
uci set "$CONF.pol_strat.proto="
uci commit "$CONF"
chk_die "empty proto" "proto is empty"
uci set "$CONF.pol_strat.proto=tcp quic"
uci commit "$CONF"
has '--filter-udp=443'
has '--payload=quic_initial'
# a disabled policy skips validation entirely (the #84 spare-exit precedent)
uci set "$CONF.pol_strat.action=destroy"
uci set "$CONF.pol_strat.enabled=0"
uci commit "$CONF"
RC=0
"$CLI" engine-cmdline >/dev/null 2>&1 || RC=$?
[ "$RC" = "0" ] || fail "a disabled broken policy must be skipped, not die"
uci delete "$CONF.pol_strat"
uci delete "$CONF.pol_first"
uci delete "$CONF.list_second"
uci commit "$CONF"
echo "VALIDATION-OK (refs/action/proto die named; disabled skips)"

# ---- [8] policies + whitelist mode -> binding IGNORED ----
echo "== [8] whitelist binding ignored under policy blocks"
add_pol pol_bypass 10 bypass list_media tcp ''
uci set "$CONF.whitelist.enabled=1" 2>/dev/null || {
	uci set "$CONF.whitelist=whitelist"
	uci set "$CONF.whitelist.enabled=1"
}
uci add_list "$CONF.whitelist.domains=legacy.example.org"
uci commit "$CONF"
"$CLI" whitelist-refresh >/dev/null
RC=0
MSG=$("$CLI" engine-cmdline 2>&1 >/dev/null) || RC=$?
[ "$RC" = "0" ] || fail "policies + whitelist must render (ignored binding), got rc=$RC"
printf '%s\n' "$MSG" | grep -q "IGNORED" || fail "the ignored whitelist binding must warn"
has "--hostlist=$BASE/lists/list_media.hosts"
lacks "--hostlist=$BASE/whitelist.hosts"
# back to blanket
uci set "$CONF.whitelist.enabled=0"
uci commit "$CONF"
echo "WHITELIST-IGNORED-OK (policy blocks own their hostlists, the binding warns and skips)"

# ---- [9] status surfaces ----
echo "== [9] status --json policy surfaces"
grab
[ "$(jp 's.engine.policies')" = "1" ] || fail "expected 1 rendered policy block, got $(jp 's.engine.policies')"
[ "$(jp 'length(s.engine.policy_sections)')" = "1" ] || fail "expected 1 policy section, got $(jp 'length(s.engine.policy_sections)')"
[ "$(jp_str 's.engine.policy_sections[0].id')" = "pol_bypass" ] || fail "policy_sections id wrong"
[ "$(jp_str 's.engine.policy_sections[0].action')" = "bypass" ] || fail "policy_sections action wrong"
[ "$(jp_str 's.engine.policy_sections[0].domainlist')" = "list_media" ] || fail "policy_sections domainlist wrong"
[ "$(jp_str 's.engine.policy_sections[0].priority')" = "10" ] || fail "policy_sections priority wrong"
[ "$(jp 's.engine.policy_sections[0].enabled')" = "true" ] || fail "policy_sections enabled wrong"
[ "$(jp_str 's.engine.hostlists[0]')" = "$BASE/lists/list_media.hosts" ] || fail "status hostlists must name the policy list"
# DRYRUN apply mentions the policy list render
WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" apply 2>&1 | grep -q "1 policy list file(s)" || fail "apply DRYRUN must mention the policy list render"
echo "STATUS-POLICIES-OK (policies count, policy_sections fields, hostlists, DRYRUN line)"

# cleanup the policy config for the live parts
uci delete "$CONF.whitelist.domains"
uci set "$CONF.whitelist.enabled=0"
uci commit "$CONF"

# ---- [10] live engine on a 2-policy argv ----
echo "== [10] live engine (2 policies: bypass + strategy, fetch health)"
LIVE=1
nft add table inet devprobe86 2>/dev/null || LIVE=0
if [ "$LIVE" = 1 ]; then
	nft add chain inet devprobe86 e '{ type filter hook postrouting priority 400; }' 2>/dev/null || LIVE=0
	nft add rule inet devprobe86 e ip daddr 192.0.2.1 counter queue num 305 bypass 2>/dev/null || LIVE=0
	nft delete table inet devprobe86 2>/dev/null || true
fi
if [ "$LIVE" != 1 ]; then
	echo "POLICIES-LIVE-SKIP (host kernel lacks NFQUEUE - live matrix is router acceptance only)"
	echo "POLICIES-TEST-OK (structural)"
	exit 0
fi
"$CLI" nft-apply >/dev/null
cd /tmp
curl -sSL --retry 5 --retry-all-errors --retry-delay 3 -o mihomo.gz "https://github.com/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-amd64-v${MIHOMO_VERSION}.gz" >/dev/null
echo "${MIHOMO_SHA256}  mihomo.gz" | sha256sum -c - >/dev/null || fail "mihomo.gz sha256 mismatch"
gzip -dc mihomo.gz > /usr/bin/mihomo
chmod 755 /usr/bin/mihomo
mkdir -p /etc/mihomo /usr/share/mihomo
cat > /etc/mihomo/config.yaml <<'EOF'
mixed-port: 17890
routing-mark: 268435456
mode: rule
log-level: warning
rules:
  - MATCH,DIRECT
EOF
mihomo -f /etc/mihomo/config.yaml -d /usr/share/mihomo >/tmp/policies-mihomo.log 2>&1 &
M_PID=$!
i=0
while [ $i -lt 30 ]; do
	netstat -lnt 2>/dev/null | grep -q ":$MPORT " && break
	i=$((i + 1))
	sleep 1
done
netstat -lnt 2>/dev/null | grep -q ":$MPORT " || fail "mihomo mixed-port did not come up (log: $(tail -2 /tmp/policies-mihomo.log))"
# the second policy: action=strategy over the TLS-preset desync words.
# prof_a is removed; the surviving catch-all = prof_b --new prof_split
# (file order): the engine runs exactly 4 segments (base+bypass policy,
# strategy policy, prof_b, prof_split).
uci delete "$CONF.prof_a"
add_list_sec list_split split.example.org split2.example.org
add_prof prof_split 1 --filter-tcp=443 --payload=tls_client_hello --lua-desync=multisplit:pos=midsld
add_pol pol_strategy 20 strategy list_split tcp prof_split
uci commit "$CONF"
"$CLI" whitelist-refresh >/dev/null
set -- $("$CLI" engine-cmdline)
prog=$1
shift
"$prog" "$@" >/tmp/policies-engine.log 2>&1 &
ENG_PID=$!
sleep 3
kill -0 "$ENG_PID" 2>/dev/null || fail "engine died on the 2-policy argv (log: $(tail -3 /tmp/policies-engine.log))"
code=""
for r in 1 2 3; do
	code=$(curl -s -m 20 -x "http://127.0.0.1:$MPORT" -o /dev/null -w '%{http_code}' "$PROBE" || true)
	[ "$code" = "200" ] && break
	sleep 2
done
[ "$code" = "200" ] || fail "traffic did not flow through the 2-policy engine (code=$code)"
grab
[ "$(jp 's.engine.policies')" = "2" ] || fail "status must count 2 rendered policy blocks, got $(jp 's.engine.policies')"
grep -q "4 user defined desync profile" /tmp/policies-engine.log || fail "engine must report 4 profiles (bypass + strategy + 2 catch-all profiles), log: $(grep -m2 'profile' /tmp/policies-engine.log)"
echo "ENGINE-2-POLICY-OK (started, fetch 200, engine reports the policy blocks)"

# ---- [11] live send inventory: bypass-listed SNI passes UNMODIFIED ----
echo "== [11] send inventory (spike-75 §1.2 against the CLI-rendered argv)"
kill "$ENG_PID" 2>/dev/null
wait "$ENG_PID" 2>/dev/null
ENG_PID=
nft delete table inet wanguard_antidpi 2>/dev/null || true
apk add tcpdump openssl-util >/dev/null 2>&1
ip addr add 8.8.100.10/32 dev lo 2>/dev/null || true
openssl req -x509 -newkey rsa:2048 -keyout /tmp/sink.key -out /tmp/sink.crt \
	-days 2 -nodes -subj "/CN=sink" >/dev/null 2>&1 || fail "sink certs"
openssl s_server -accept 8.8.100.10:443 -cert /tmp/sink.crt -key /tmp/sink.key \
	-www -quiet >/tmp/policies-sink.log 2>&1 &
SINK_PID=$!
sleep 1
kill -0 "$SINK_PID" 2>/dev/null || fail "s_server died"
nft -f - <<'NFT'
table inet policies86 {
	chain out {
		type filter hook output priority mangle; policy accept;
		meta mark & 0x40000000 == 0 ip daddr 8.8.100.0/24 tcp dport 443 meta mark set 0x10000000
	}
	chain post {
		type filter hook postrouting priority srcnat; policy accept;
		meta mark & 0x10000000 != 0 meta mark & 0x40000000 == 0 tcp dport 443 counter queue num 300 bypass
	}
}
NFT
# the policy list for the inventory: bypass.example passes, the catch-all
# profile (prof_a via the profiles render) splits everything else
uci delete "$CONF.list_media.domains" 2>/dev/null || :
uci add_list "$CONF.list_media.domains=bypass.example"
uci commit "$CONF"
"$CLI" whitelist-refresh >/dev/null
grep -qx 'bypass.example' "$LF" || fail "inventory list must hold bypass.example only: $(cat "$LF")"
set -- $("$CLI" engine-cmdline)
prog=$1
shift
"$prog" "$@" >/tmp/policies-engine2.log 2>&1 &
ENG_PID=$!
sleep 3
kill -0 "$ENG_PID" 2>/dev/null || fail "engine died on the inventory argv (log: $(tail -3 /tmp/policies-engine2.log))"
grep -q "Loaded 1 hosts" /tmp/policies-engine2.log || fail "engine must load the inventory hostlist"
inv_probe() { # inv_probe <sni> - CH data-packet lengths client->sink
	tcpdump -i lo -nn -l 'tcp dst port 443' > "/tmp/cap-$1.txt" 2>&1 &
	TPID=$!
	sleep 1
	echo Q | openssl s_client -connect 8.8.100.10:443 -servername "$1" \
		>/tmp/sc-"$1".out 2>&1
	sleep 1
	kill "$TPID" 2>/dev/null
	wait "$TPID" 2>/dev/null
	# data packets only: lines starting with a timestamp
	grep -E '^[0-9]{2}:[0-9]{2}:' "/tmp/cap-$1.txt" | grep -oE 'length [0-9]+' | grep -oE '[0-9]+$'
}
BYPASS_LEN=$(inv_probe bypass.example | grep -v '^0$' | head -1)
DESYNC_LEN=$(inv_probe desync.example | grep -v '^0$' | head -1)
BYPASS_N=$(inv_probe bypass.example | grep -vc '^0$' || true)
DESYNC_N=$(inv_probe desync.example | grep -vc '^0$' || true)
echo "first data packet: bypass=$BYPASS_LEN desync=$DESYNC_LEN; data packets: bypass=$BYPASS_N desync=$DESYNC_N"
grep -q "Cipher is" /tmp/sc-bypass.example.out || fail "bypass session did not complete the TLS handshake"
grep -q "Cipher is" /tmp/sc-desync.example.out || fail "desync session did not complete the TLS handshake"
[ -n "$BYPASS_LEN" ] && [ "$BYPASS_LEN" -gt 500 ] || fail "bypass CH must pass unmodified (one large segment), got: $BYPASS_LEN"
[ -n "$DESYNC_LEN" ] && [ "$DESYNC_LEN" -lt "$BYPASS_LEN" ] || fail "catch-all CH must be split (first piece smaller than the full CH), got: $DESYNC_LEN vs $BYPASS_LEN"
[ "$DESYNC_N" -gt "$BYPASS_N" ] || fail "the catch-all must split (more data packets than the bypass path)"
kill "$ENG_PID" 2>/dev/null
wait "$ENG_PID" 2>/dev/null
ENG_PID=
kill "$SINK_PID" 2>/dev/null
echo "INVENTORY-OK (bypass SNI passed the CH in one segment, catch-all split it; both handshakes green)"

echo "POLICIES-TEST-OK"
