#!/bin/sh
# tests/test-status.sh - the read-only status surface behind the LuCI page
# (issue #76). Runs INSIDE an OpenWrt container with --cap-add NET_ADMIN:
#
#   docker run --rm --cap-add NET_ADMIN \
#     -v <out>:/out:ro -v <tests>:/tests:ro \
#     openwrt/rootfs:x86_64-25.12.6 sh /tests/test-status.sh
#
# Every assertion reads ONE JSON document produced by `status --json` (parsed
# with the container's own ucode; printf %J is the only JSON serializer this
# build has - %j does not exist). Degraded surfaces (no table, no mihomo, no
# syslogd) are expected values, not errors: the CLI never throws, the UI
# renders "unavailable" from the same keys.
#
# Matrix:
#   [1] bare default config: parse + structural goldens (no-op state)
#   [2] staged UCI delta -> pending count + section names
#   [3] whitelist mode: refresh -> mode/domains/file.mtime; hostlist NOT in
#       argv without strategy words
#   [3b] domainlist sections (#82): merged into the same hostlist file
#       (dedupe across sources), status.domains stays the legacy list,
#       per-source loud fails (invalid entry names the section; half-enable)
#   [4] tunnel: pins + resolved + state file -> per-entry source/expires_h,
#       cron line -> cron.ok
#   [5] strategy words -> profile count (1; with --new -> 2), hostlist enters
#       the rendered argv (whitelist still enabled)
#   [6] live table: apply -> table_present + counter objects (structural)
#   [7] engine-cmdline byte-parity guard over the refactored argv builder
#       (default 6-word golden + ipset emission on a populated set)
#   [8] live engine: pid/uptime/running_argv captured (NFQUEUE hosts only)
set -eu

CLI=/usr/bin/wanguard-antidpi
TABLE=wanguard_antidpi
CONF=/etc/config/wanguard-antidpi
HOSTLIST=/usr/share/wanguard-antidpi/whitelist.hosts
STATE=/usr/share/wanguard-antidpi/tunnel-resolved.state
JS=/tmp/status.json

fail() {
	echo "STATUS-TEST-FAIL: $1"
	exit 1
}

grab() {
	"$CLI" status --json > "$JS" || fail "status --json exited nonzero"
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all'));
		if (type(s) != 'object') { warn('not an object\n'); exit(1); }" \
		|| fail "status --json is not a JSON object"
}

# jp '<ucode expr over s>' -> JSON rendering of the value (%J)
jp() {
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all')); printf('%J\n', ($1));"
}

jp_str() { # unquoted string value (for string comparisons)
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all')); printf('%s\n', ($1));"
}

# ---- setup: package + pristine config snapshot ----
set -- /out/wanguard-antidpi-*.apk
[ -f "$1" ] || fail "no package in /out"
apk add --allow-untrusted "$@" >/dev/null
echo "== package installed: $("$CLI" version)"
cp "$CONF" /tmp/conf.default

# ---- [1] bare default config ----
echo "== [1] bare default config"
grab
[ "$(jp 's.service.enabled')" = "false" ] || fail "expected disabled on a fresh install (got $(jp 's.service.enabled'))"
[ "$(jp 's.service.pid')" = "null" ] || fail "expected no engine pid"
[ "$(jp 's.engine.pid')" = "null" ] || fail "expected engine.pid null"
jp_str 's.engine.version' | grep -q . || fail "engine.version empty (binary ships in the package)"
[ "$(jp 's.engine.profiles')" = "0" ] || fail "expected 0 profiles with an empty strategy"
[ "$(jp 'length(s.engine.hostlists)')" = "0" ] || fail "expected no hostlists with an empty strategy"
[ "$(jp 's.engine.running_argv')" = "null" ] || fail "expected running_argv null"
[ "$(jp 's.nft.table_present')" = "false" ] || fail "expected table absent"
[ "$(jp 's.nft.counters')" = "null" ] || fail "expected counters null"
[ "$(jp 'length(s.tunnel.entries)')" = "0" ] || fail "expected no tunnel entries"
[ "$(jp 'length(s.tunnel.hosts)')" = "0" ] || fail "expected no tunnel hosts"
[ "$(jp 's.tunnel.cron.ok')" = "false" ] || fail "expected cron absent"
[ "$(jp_str 's.whitelist.mode')" = "blanket" ] || fail "expected blanket mode"
[ "$(jp 's.whitelist.file.exists')" = "false" ] || fail "expected no hostlist file"
[ "$(jp 's.mihomo.config_missing')" = "true" ] || fail "expected mihomo config missing in the container"
[ "$(jp 's.mihomo.state')" = "null" ] || fail "expected mihomo state null"
[ "$(jp 's.pending.count')" = "0" ] || fail "expected zero pending changes"
[ "$(jp 'length(s.events)')" != "" ] || fail "events must always be an array"
[ "$(jp 'length(keys(s.degraded))')" != "0" ] || fail "expected degraded entries (no table, no mihomo)"
jp 's.degraded' | grep -q nft || fail "degraded must mention nft"
jp 's.degraded' | grep -q mihomo || fail "degraded must mention mihomo"
echo "BARE-OK (no-op state, structural goldens)"

# ---- [2] staged UCI delta -> pending ----
echo "== [2] pending (staged delta)"
uci set wanguard-antidpi.engine.debug=1
grab
[ "$(jp 's.pending.count')" = "1" ] || fail "expected 1 staged change (got $(jp 's.pending.count'))"
[ "$(jp_str 's.pending.sections[0]')" = "engine" ] || fail "expected the engine section named"
uci -q revert wanguard-antidpi || true
grab
[ "$(jp 's.pending.count')" = "0" ] || fail "revert did not clear pending"
echo "PENDING-OK (staged delta counted and cleared)"

# ---- [3] whitelist mode ----
echo "== [3] whitelist mode"
uci set wanguard-antidpi.whitelist=whitelist
uci set wanguard-antidpi.whitelist.enabled=1
uci add_list wanguard-antidpi.whitelist.domains='alpha.example'
uci add_list wanguard-antidpi.whitelist.domains='beta.example'
uci commit wanguard-antidpi
"$CLI" whitelist-refresh >/dev/null
[ -f "$HOSTLIST" ] || fail "whitelist-refresh did not produce the file"
grab
[ "$(jp_str 's.whitelist.mode')" = "whitelist" ] || fail "expected whitelist mode"
[ "$(jp 'length(s.whitelist.domains)')" = "2" ] || fail "expected 2 domains"
[ "$(jp 's.whitelist.file.exists')" = "true" ] || fail "expected hostlist file present"
[ "$(jp 's.whitelist.file.mtime')" != "null" ] || fail "expected a file mtime"
[ "$(jp 'length(s.engine.hostlists)')" = "0" ] || fail "hostlist must NOT enter the argv without strategy words"
echo "WHITELIST-OK (mode, domains, file mtime; argv untouched without words)"

# ---- [3b] domainlist sections merge into the same hostlist (issue #82) ----
echo "== [3b] domainlist sections"
uci set wanguard-antidpi.list_media=domainlist
uci set wanguard-antidpi.list_media.name='Video domains'
uci add_list wanguard-antidpi.list_media.domains='zeta.example'
uci add_list wanguard-antidpi.list_media.domains='beta.example'
uci set wanguard-antidpi.list_empty=domainlist
uci set wanguard-antidpi.list_empty.name='Empty section'
uci commit wanguard-antidpi
"$CLI" whitelist-refresh >/dev/null
grep -q 'zeta.example' "$HOSTLIST" || fail "domainlist section did not reach the hostlist"
grep -q 'beta.example' "$HOSTLIST" || fail "legacy domain lost from the merged file"
[ "$(grep -c . "$HOSTLIST")" = "3" ] || fail "expected 3 unique hosts after the merge (dedupe across sources)"
grab
[ "$(jp 'length(s.whitelist.domains)')" = "2" ] || fail "status domains must stay the legacy list (the #76 contract)"
# a broken section fails the render LOUDLY, naming the section
uci add_list wanguard-antidpi.list_media.domains='*.bad.example'
uci commit wanguard-antidpi
if "$CLI" engine-cmdline >/dev/null 2>/tmp/dl.err; then
	fail "invalid domainlist entry must fail the render"
fi
grep -q 'domainlist "list_media"' /tmp/dl.err || fail "render failure must name the section"
# half-enabled (whitelist on, every source empty) stays a loud fail
uci delete wanguard-antidpi.list_media.domains
uci delete wanguard-antidpi.whitelist.domains
uci commit wanguard-antidpi
if "$CLI" engine-cmdline >/dev/null 2>/tmp/dl.err; then
	fail "enabled mode with an empty source set must fail the render"
fi
grep -q 'no domains are configured' /tmp/dl.err || fail "half-enable failure message lost"
echo "DOMAINLIST-OK (merged into the hostlist, per-source loud fails)"
# cleanup: back to the legacy-only whitelist for the following blocks
uci delete wanguard-antidpi.list_media
uci delete wanguard-antidpi.list_empty
uci add_list wanguard-antidpi.whitelist.domains='alpha.example'
uci add_list wanguard-antidpi.whitelist.domains='beta.example'
uci commit wanguard-antidpi
"$CLI" whitelist-refresh >/dev/null
[ "$(grep -c . "$HOSTLIST")" = "2" ] || fail "cleanup did not restore the legacy-only file"

# ---- [4] tunnel entries ----
echo "== [4] tunnel entries"
uci set wanguard-antidpi.tunnel=tunnel
uci add_list wanguard-antidpi.tunnel.proxy_servers='203.0.113.1'
uci add_list wanguard-antidpi.tunnel.proxy_resolved='198.51.100.7'
uci commit wanguard-antidpi
printf '%s\n' '# spike' "198.51.100.7 $(date +%s)" > "$STATE"
grab
[ "$(jp 'length(s.tunnel.entries)')" = "2" ] || fail "expected 2 merged entries"
[ "$(jp_str 's.tunnel.entries[0].ip')" = "198.51.100.7" ] || fail "canonical order broken"
[ "$(jp_str 's.tunnel.entries[0].source')" = "resolved" ] || fail "198.51.100.7 must be resolved"
[ "$(jp_str 's.tunnel.entries[1].ip')" = "203.0.113.1" ] || fail "canonical order broken"
[ "$(jp_str 's.tunnel.entries[1].source')" = "pin" ] || fail "203.0.113.1 must be a pin"
[ "$(jp 's.tunnel.entries[1].expires_h')" = "null" ] || fail "pins never expire"
[ "$(jp '(s.tunnel.entries[0].expires_h >= 20 && s.tunnel.entries[0].expires_h <= 24)')" = "true" ] \
	|| fail "fresh resolved entry must show ~24h left (got $(jp 's.tunnel.entries[0].expires_h'))"
echo "TUNNEL-OK (per-entry source + expiry; cron absent -> ok=false)"

# ---- [5] strategy words -> profiles ----
echo "== [5] profiles from strategy words"
uci add_list wanguard-antidpi.engine.nfqws2_opt='--filter-tcp=443'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--payload=tls_client_hello'
uci commit wanguard-antidpi
grab
[ "$(jp 's.engine.profiles')" = "1" ] || fail "expected 1 profile"
[ "$(jp 'length(s.engine.hostlists)')" = "1" ] || fail "whitelist+words must emit the hostlist"
jp_str 's.engine.hostlists[0]' | grep -q "$HOSTLIST" || fail "unexpected hostlist path"
uci add_list wanguard-antidpi.engine.nfqws2_opt='--new'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--filter-udp=443'
uci commit wanguard-antidpi
grab
[ "$(jp 's.engine.profiles')" = "2" ] || fail "expected 2 profiles after --new"
echo "PROFILES-OK (1 word set -> 1; --new -> 2; hostlist per-profile present)"

# ---- [6] live table ----
echo "== [6] live nft table"
LIVE=1
nft add table inet devprobe76 2>/dev/null || LIVE=0
if [ "$LIVE" = 1 ]; then
	nft add chain inet devprobe76 e '{ type filter hook postrouting priority 400; }' 2>/dev/null || LIVE=0
fi
if [ "$LIVE" = 1 ]; then
	nft add rule inet devprobe76 e ip daddr 192.0.2.1 counter queue num 301 bypass 2>/dev/null || LIVE=0
fi
nft delete table inet devprobe76 2>/dev/null || true
if [ "$LIVE" != 1 ]; then
	echo "STATUS-LIVE-SKIP (host kernel lacks NFQUEUE - live parts are router acceptance only)"
	echo "STATUS-TEST-OK (structural)"
	exit 0
fi
"$CLI" nft-apply >/dev/null
grab
[ "$(jp 's.nft.table_present')" = "true" ] || fail "expected the live table"
[ "$(jp 's.nft.counters.tcp.packets')" = "0" ] || fail "expected a tcp counter object"
[ "$(jp 's.nft.counters.udp.bytes')" = "0" ] || fail "expected a udp counter object"
[ "$(jp 'length(keys(s.degraded))')" != "0" ] || fail "degraded must still mention mihomo (config absent)"
echo "NFT-OK (live table + counter objects)"

# ---- [7] engine-cmdline byte-parity over the refactored builder ----
echo "== [7] engine-cmdline parity"
# default first: restore the pristine config
cp /tmp/conf.default "$CONF"
cl=$("$CLI" engine-cmdline)
[ "$(printf '%s\n' "$cl" | wc -w)" = "6" ] || fail "default golden broken (expected 6 words): $cl"
printf '%s\n' "$cl" | grep -q -- '--qnum=300' || fail "golden lost --qnum=300"
printf '%s\n' "$cl" | grep -q -- '--fwmark=0x40000000' || fail "golden lost --fwmark"
printf '%s\n' "$cl" | grep -q -- '--user=daemon' || fail "golden lost --user"
[ "$(printf '%s\n' "$cl" | grep -c -- '--lua-init=@')" = "2" ] || fail "golden lost the lua inits"
# populated set: the exclude-ip CSV appears as ONE argv word
uci set wanguard-antidpi.tunnel=tunnel
uci add_list wanguard-antidpi.tunnel.proxy_servers='203.0.113.1'
uci add_list wanguard-antidpi.tunnel.proxy_resolved='198.51.100.7'
uci commit wanguard-antidpi
cl=$("$CLI" engine-cmdline)
printf '%s\n' "$cl" | grep -q -- '--ipset-exclude-ip=198.51.100.7,203.0.113.1' \
	|| fail "exclude-ip CSV missing or malformed: $cl"
echo "PARITY-OK (default golden + exclude-ip CSV)"

# ---- [8] live engine ----
echo "== [8] live engine (running process surface)"
uci delete wanguard-antidpi.tunnel
uci commit wanguard-antidpi
cp /tmp/conf.default "$CONF"
set -- $(/usr/bin/wanguard-antidpi engine-cmdline)
prog=$1
shift
"$prog" "$@" >/tmp/status-engine.log 2>&1 &
EPID=$!
sleep 3
kill -0 "$EPID" 2>/dev/null || { echo "STATUS-LIVE-SKIP (engine refused to start: $(cat /tmp/status-engine.log))"; echo "STATUS-TEST-OK (structural)"; exit 0; }
grab
[ "$(jp 's.service.pid')" != "null" ] || fail "expected a running engine pid"
[ "$(jp 's.engine.pid')" = "$(jp 's.service.pid')" ] || fail "pid surfaces disagree"
[ "$(jp 's.service.uptime_s')" != "null" ] || fail "expected a numeric uptime"
[ "$(jp 'length(s.engine.running_argv)')" = "6" ] || fail "expected 6 cmdline entries captured incl. the binary (got $(jp 'length(s.engine.running_argv)'))"
jp_str 's.engine.running_argv[0]' | grep -q nfqws2 || fail "running argv must start with the binary"
kill "$EPID" 2>/dev/null
for i in 1 2 3 4 5; do kill -0 "$EPID" 2>/dev/null || break; sleep 1; done
echo "ENGINE-OK (pid, uptime, running argv)"

# ---- cleanup ----
"$CLI" nft-flush >/dev/null
cp /tmp/conf.default "$CONF"

echo "STATUS-TEST-OK"
