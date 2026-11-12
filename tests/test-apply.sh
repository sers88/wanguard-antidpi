#!/bin/sh
# tests/test-apply.sh - the idempotent apply orchestration (issue #77).
# Runs INSIDE an OpenWrt container with --cap-add NET_ADMIN:
#
#   docker run --rm --cap-add NET_ADMIN \
#     -v <out>:/out:ro -v <tests>:/tests:ro \
#     openwrt/rootfs:x86_64-25.12.6 sh /tests/test-apply.sh
#
# The container has no rc.common (procd shim paths are router-acceptance
# territory), so the engine-restart scenarios run against a minimal STUB
# init script that starts the engine straight from `engine-cmdline` - what
# is under test is the apply orchestration itself (the decision, the
# SIGHUP-vs-restart split, the exit codes), not the shim. Same live-skip
# convention as test-nft.sh: hosts without NFQUEUE support get the
# structural scenarios only.
#
# The tunnel PARTIAL scenario stubs `nslookup` on PATH (ucode children
# spawn via /bin/sh, so PATH stubs work - the test-tunnel pattern).
#
# Matrix:
#   [1]  default config: apply = ok, engine no-op (dead, no words), nft
#        table applied; second run identical (idempotent)
#   [2]  --check with the engine down -> FAILED (engine item), exit 1
#   [3]  live: whitelist + strategy words via the STUB init -> apply starts
#        the engine (restart path), pid A
#   [3b] no-change apply with a live engine -> no-op, pid unchanged
#   [4]  domain-list edit -> SIGHUP (reloaded), pid unchanged
#   [4b] DRYRUN of the next list edit -> "would reload", no writes
#   [5]  strategy edit -> restart, pid changed
#   [5b] whitelist mode flip off -> restart (SIGHUP cannot rebind --hostlist)
#   [5c] whitelist mode flip on -> restart again, hostlist back
#   [5d] tunnel pin add/remove -> set + --ipset-exclude-ip rebuilt (#83)
#   [6]  --check all green (+ --json ok:true, engine pid present)
#   [7]  --check catches a missing hostlist file
#   [8]  --check catches a foreign routing-mark
#   [9]  --check catches a flushed nft table
#   [10] unknown argument -> exit 1 (validation)
#   [11] tunnel resolution failure -> PARTIAL (exit 2), everything else ok
set -eu

CLI=/usr/bin/wanguard-antidpi
CONF=/etc/config/wanguard-antidpi
HOSTLIST=/usr/share/wanguard-antidpi/whitelist.hosts
MIHOMO_CONF=/etc/mihomo/config.yaml
INIT=/etc/init.d/wanguard-antidpi
JS=/tmp/apply-check.json

fail() {
	echo "APPLY-TEST-FAIL: $1"
	exit 1
}

assert_out() { # assert_out <grep-pattern> <output>
	printf '%s\n' "$2" | grep -q -- "$1" || fail "output missing '$1' (got: $2)"
}

epid() {
	pidof nfqws2 2>/dev/null | awk '{print $1}'
}

# run/apply capture safe under set -e
run() { # run <output-var> <rc-var> <cmd...>
	local _o _e _r=0
	_o="$1"; _e="$2"; shift 2
	{ "$@"; } > /tmp/apply.out 2>&1 || _r=$?
	eval "$_o=\$(cat /tmp/apply.out)"
	eval "$_e=$_r"
}

# mihomo config fixtures (the mark check is a root-level YAML text parse;
# no real mihomo binary needed)
fixture_mark() { # fixture_mark <mark-value>
	mkdir -p /etc/mihomo
	printf 'mixed-port: 7890\nrouting-mark: %s\nmode: rule\n' "$1" > "$MIHOMO_CONF"
}

# ---- setup ----
set -- /out/wanguard-antidpi-*.apk
[ -f "$1" ] || fail "no package in /out"
apk add --allow-untrusted "$@" >/dev/null
echo "== package installed: $("$CLI" version)"
cp "$CONF" /tmp/conf.default

# live probe (NFQUEUE host?) - same convention as test-nft.sh
LIVE=1
if ! nft add table inet devprobe77 2>/dev/null; then LIVE=0; fi
if [ "$LIVE" = 1 ] && ! nft add chain inet devprobe77 e '{ type filter hook postrouting priority 400; }' 2>/dev/null; then LIVE=0; fi
if [ "$LIVE" = 1 ] && ! nft add rule inet devprobe77 e ip daddr 192.0.2.1 counter queue num 302 bypass 2>/dev/null; then LIVE=0; fi
nft delete table inet devprobe77 2>/dev/null || true
if [ "$LIVE" != 1 ]; then
	echo "APPLY-LIVE-SKIP (host kernel lacks NFQUEUE - restart scenarios are router acceptance only)"
fi

# ---- [1] default config: idempotent no-op ----
echo "== [1] default config apply"
run OUT RC "$CLI" apply
[ "$RC" = 0 ] || fail "apply on the default config exited $RC: $(cat /tmp/apply.out)"
assert_out 'apply-result: ok' "$OUT"
assert_out 'engine: no-op' "$OUT"
assert_out 'apply: tunnel: skipped' "$OUT"
nft list table inet wanguard_antidpi >/dev/null 2>&1 || fail "apply did not leave the nft table in force"
run OUT2 RC2 "$CLI" apply
[ "$RC2" = 0 ] || fail "second apply exited $RC2 (idempotency broken)"
assert_out 'apply-result: ok' "$OUT2"
echo "NOOP-OK (default config: engine no-op, table applied, idempotent)"

# ---- [2] --check with the engine down ----
echo "== [2] --check, engine down"
fixture_mark 268435456
run OUT RC "$CLI" apply --check
[ "$RC" = 1 ] || fail "expected --check exit 1 with the engine down (got $RC)"
assert_out 'check: engine: FAILED' "$OUT"
assert_out 'check: mark: ok' "$OUT"
assert_out 'check: nft: ok' "$OUT"
assert_out 'check-result: FAILED' "$OUT"
"$CLI" apply --check --json > "$JS" || true
ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all')); if (s.ok != false) { warn('expected ok=false\n'); exit(1); } if (s.checks.engine.ok != false) { warn('expected engine fail\n'); exit(1); }" \
	|| fail "--check --json report shape wrong"
echo "CHECK-DOWN-OK (engine item fails, mark/nft/config green, exit 1)"

if [ "$LIVE" != 1 ]; then
	echo "APPLY-TEST-OK (structural)"
	exit 0
fi

# ---- stub init script (no rc.common in the container) ----
cat > "$INIT" <<'EOF'
#!/bin/sh
# test stub: minimal start/stop/restart without procd (no rc.common in the
# test container). Starts the engine straight from `engine-cmdline` - the
# real shim contract is covered by the structural smoke + router acceptance.
action=${1:-}
case "$action" in
restart|start)
	old=$(pidof nfqws2 2>/dev/null)
	[ -n "$old" ] && kill $old 2>/dev/null
	i=0
	while pidof nfqws2 >/dev/null 2>&1 && [ $i -lt 5 ]; do sleep 1; i=$((i+1)); done
	set -- $(/usr/bin/wanguard-antidpi engine-cmdline)
	prog=$1
	shift
	"$prog" "$@" >/tmp/apply-engine.log 2>&1 &
	i=0
	while ! pidof nfqws2 >/dev/null 2>&1 && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
	pidof nfqws2 >/dev/null 2>&1
	;;
stop)
	pid=$(pidof nfqws2 2>/dev/null)
	if [ -n "$pid" ]; then kill $pid 2>/dev/null || true; fi
	;;
*)
	:
	;;
esac
EOF
chmod 755 "$INIT"

# ---- [3] live start through apply ----
echo "== [3] apply starts the engine (restart path)"
uci set wanguard-antidpi.whitelist=whitelist
uci set wanguard-antidpi.whitelist.enabled=1
uci add_list wanguard-antidpi.whitelist.domains='alpha.example'
uci add_list wanguard-antidpi.whitelist.domains='beta.example'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--filter-tcp=443'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--payload=tls_client_hello'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--lua-desync=multisplit:pos=midsld'
uci commit wanguard-antidpi
run OUT RC "$CLI" apply
[ "$RC" = 0 ] || fail "apply (start path) exited $RC: $OUT"
assert_out 'apply: engine: restarted' "$OUT"
assert_out 'apply: nft: applied' "$OUT"
[ -f "$HOSTLIST" ] || fail "apply did not render the hostlist before starting the engine"
A=$(epid)
[ -n "$A" ] || fail "engine did not start (log: $(cat /tmp/apply-engine.log 2>/dev/null))"
echo "START-OK (engine started via the init path, pid $A)"

# ---- [3b] no-change apply with a live engine ----
echo "== [3b] no-change apply (live engine)"
run OUT RC "$CLI" apply
[ "$RC" = 0 ] || fail "no-change apply exited $RC"
assert_out 'engine: no-op' "$OUT"
[ "$(epid)" = "$A" ] || fail "no-change apply disturbed the engine pid"
echo "LIVE-NOOP-OK (idempotent with a live engine, pid unchanged)"

# ---- [4] domain-list edit -> SIGHUP ----
echo "== [4] domain edit -> SIGHUP, no restart"
uci add_list wanguard-antidpi.whitelist.domains='gamma.example'
uci commit wanguard-antidpi
run OUT RC "$CLI" apply
[ "$RC" = 0 ] || fail "list-edit apply exited $RC: $OUT"
assert_out 'engine: reloaded (SIGHUP' "$OUT"
[ "$(epid)" = "$A" ] || fail "list edit restarted the engine (pid changed) - SIGHUP contract broken"
grep -q 'gamma.example' "$HOSTLIST" || fail "hostlist file not refreshed"
echo "SIGHUP-OK (list edit reloaded via SIGHUP, pid unchanged, file refreshed)"

# ---- [4b] DRYRUN of the next list edit ----
echo "== [4b] DRYRUN plan"
uci add_list wanguard-antidpi.whitelist.domains='delta.example'
uci commit wanguard-antidpi
run OUT RC env WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" apply
[ "$RC" = 0 ] || fail "DRYRUN apply exited $RC: $OUT"
assert_out 'DRYRUN: engine: would reload' "$OUT"
assert_out 'DRYRUN: apply plan printed - no changes made' "$OUT"
[ "$(epid)" = "$A" ] || fail "DRYRUN disturbed the engine"
grep -q 'delta.example' "$HOSTLIST" && fail "DRYRUN wrote the hostlist file"
echo "DRYRUN-OK (plan printed, no writes)"

# ---- [5] strategy edit -> restart ----
echo "== [5] strategy edit -> restart"
uci add_list wanguard-antidpi.engine.nfqws2_opt='--new'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--filter-udp=443'
uci add_list wanguard-antidpi.engine.nfqws2_opt='--payload=quic_initial'
uci commit wanguard-antidpi
run OUT RC "$CLI" apply
[ "$RC" = 0 ] || fail "strategy-edit apply exited $RC: $OUT"
assert_out 'engine: restarted' "$OUT"
B=$(epid)
[ -n "$B" ] || fail "engine did not restart (log: $(cat /tmp/apply-engine.log 2>/dev/null))"
[ "$B" != "$A" ] || fail "strategy edit did not restart the engine (same pid)"
grep -q 'delta.example' "$HOSTLIST" || fail "the staged domain did not land with the restart apply"
echo "RESTART-OK (strategy drift restarted the engine, pid $A -> $B)"

# ---- [5b] whitelist mode flip off -> restart ----
# only the --hostlist words differ (the per-profile emission is all-or-none),
# but SIGHUP re-reads list file CONTENT - it cannot drop the binding of a
# live process. The flip MUST go through a restart (#82 decision fix: the
# old logic called this "hostlist words changed - reload").
echo "== [5b] whitelist mode off -> restart"
uci set wanguard-antidpi.whitelist.enabled='0'
uci commit wanguard-antidpi
run OUT RC "$CLI" apply
[ "$RC" = 0 ] || fail "mode-flip apply exited $RC: $OUT"
assert_out 'engine: restarted' "$OUT"
assert_out 'whitelist mode flipped' "$OUT"
[ -f "$HOSTLIST" ] && fail "blanket apply left the hostlist file in place"
C=$(epid)
[ -n "$C" ] || fail "engine did not restart (log: $(cat /tmp/apply-engine.log 2>/dev/null))"
[ "$C" != "$B" ] || fail "mode flip did not restart the engine (same pid)"
echo "MODEFLIP-OK (mode off restarted the engine, pid $B -> $C, hostlist removed)"

# ---- [5c] whitelist mode flip on -> restart again, hostlist back ----
echo "== [5c] whitelist mode on -> restart"
uci set wanguard-antidpi.whitelist.enabled='1'
uci commit wanguard-antidpi
run OUT RC "$CLI" apply
[ "$RC" = 0 ] || fail "mode-flip-on apply exited $RC: $OUT"
assert_out 'engine: restarted' "$OUT"
D=$(epid)
[ -n "$D" ] || fail "engine did not restart (log: $(cat /tmp/apply-engine.log 2>/dev/null))"
[ "$D" != "$C" ] || fail "mode flip on did not restart the engine (same pid)"
[ -f "$HOSTLIST" ] || fail "mode-on apply did not render the hostlist"
grep -q 'delta.example' "$HOSTLIST" || fail "the merged set lost a domain at the mode-on restart"
echo "MODEFLIP-ON-OK (mode on restarted the engine, pid $C -> $D, hostlist back)"

# ---- [5d] pin edit -> apply re-renders the set AND the engine argv ----
# the exclusion set rides in the engine argv (--ipset-exclude-ip, #64 r9):
# adding a pin drifts the live argv -> restart; removing it must rebuild both
# the nft set and the engine CSV (the #83 criterion).
echo "== [5d] pin add/remove -> exclude-ip rebuilt via apply"
uci add_list wanguard-antidpi.tunnel.proxy_servers='192.0.2.99'
uci commit wanguard-antidpi
run OUT RC "$CLI" apply
[ "$RC" = 0 ] || fail "pin-add apply exited $RC: $OUT"
assert_out 'engine: restarted' "$OUT"
E=$(epid)
[ -n "$E" ] || fail "pin-add apply did not restart the engine"
tr '\0' '\n' < "/proc/$E/cmdline" | grep -qx -- '--ipset-exclude-ip=192.0.2.99' \
	|| fail "live engine argv lost the pin after the pin-add restart: $(tr '\0' ' ' < /proc/$E/cmdline)"
nft list set inet wanguard_antidpi proxy_servers 2>/dev/null | grep -qF '192.0.2.99' \
	|| fail "nft set lost the pin after the pin-add apply"
uci del_list wanguard-antidpi.tunnel.proxy_servers='192.0.2.99'
uci commit wanguard-antidpi
run OUT RC "$CLI" apply
[ "$RC" = 0 ] || fail "pin-del apply exited $RC: $OUT"
assert_out 'engine: restarted' "$OUT"
F=$(epid)
[ -n "$F" ] || fail "pin-del apply did not restart the engine"
[ "$F" != "$E" ] || fail "pin removal did not restart the engine (same pid)"
tr '\0' '\n' < "/proc/$F/cmdline" | grep -qF '192.0.2.99' \
	&& fail "live engine argv still carries the removed pin" || :
nft list set inet wanguard_antidpi proxy_servers 2>/dev/null | grep -qF '192.0.2.99' \
	&& fail "nft set still carries the removed pin" || :
echo "PINDEL-OK (pin add/remove restarted the engine, set + --ipset-exclude-ip rebuilt, pid $E -> $F)"

# ---- [6] --check all green ----
echo "== [6] --check all green"
run OUT RC "$CLI" apply --check
[ "$RC" = 0 ] || fail "expected a green --check (exit 0, got $RC): $OUT"
for item in config nft mark engine hostlist; do
	assert_out "check: $item: ok" "$OUT"
done
assert_out 'check-result: ok' "$OUT"
"$CLI" apply --check --json > "$JS" || fail "--check --json exited nonzero on a green state"
ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all')); if (s.ok != true) { warn('expected ok=true\n'); exit(1); } if (s.checks.engine.pid == null) { warn('expected engine pid\n'); exit(1); } if (s.checks.hostlist.needed != true) { warn('expected hostlist needed\n'); exit(1); }" \
	|| fail "--check --json report shape wrong"
echo "CHECK-GREEN-OK (all five items, exit 0)"

# ---- [7] --check catches a missing hostlist ----
echo "== [7] --check, hostlist missing"
rm -f "$HOSTLIST"
run OUT RC "$CLI" apply --check
[ "$RC" = 1 ] || fail "expected exit 1 with the hostlist missing (got $RC)"
assert_out 'check: hostlist: FAILED' "$OUT"
"$CLI" whitelist-refresh >/dev/null
[ -f "$HOSTLIST" ] || fail "hostlist restore failed"
echo "CHECK-HOSTLIST-OK (missing hostlist caught)"

# ---- [8] --check catches a foreign mark ----
echo "== [8] --check, foreign mark"
fixture_mark 536870912
run OUT RC "$CLI" apply --check
[ "$RC" = 1 ] || fail "expected exit 1 with a foreign mark (got $RC)"
assert_out 'check: mark: FAILED' "$OUT"
assert_out 'foreign routing-mark' "$OUT"
fixture_mark 268435456
echo "CHECK-MARK-OK (foreign value caught, our value restored)"

# ---- [9] --check catches a flushed table ----
echo "== [9] --check, table flushed"
"$CLI" nft-flush >/dev/null
run OUT RC "$CLI" apply --check
[ "$RC" = 1 ] || fail "expected exit 1 with the table flushed (got $RC)"
assert_out 'check: nft: FAILED' "$OUT"
echo "CHECK-NFT-OK (absent table caught)"

# ---- [10] usage ----
echo "== [10] unknown argument"
run OUT RC "$CLI" apply --bogus
[ "$RC" = 1 ] || fail "expected exit 1 for an unknown argument (got $RC)"
assert_out 'unknown argument' "$OUT"
echo "USAGE-OK (bad flag = validation failure)"

# ---- [11] tunnel resolution failure -> PARTIAL ----
echo "== [11] tunnel failure -> PARTIAL (exit 2)"
uci set wanguard-antidpi.tunnel=tunnel
uci add_list wanguard-antidpi.tunnel.tunnel_hosts='unresolvable.invalid'
uci commit wanguard-antidpi
mkdir -p /tmp/fakebin
printf '#!/bin/sh\nexit 1\n' > /tmp/fakebin/nslookup
chmod 755 /tmp/fakebin/nslookup
run OUT RC env PATH=/tmp/fakebin:$PATH "$CLI" apply
[ "$RC" = 2 ] || fail "expected exit 2 (partial) on a total tunnel failure (got $RC): $OUT"
assert_out 'apply-result: PARTIAL' "$OUT"
assert_out 'keeping the last known set' "$OUT"
nft list table inet wanguard_antidpi >/dev/null 2>&1 || fail "PARTIAL run did not keep the nft table in force"
echo "PARTIAL-OK (tunnel fallback kept, table applied, exit 2)"

# ---- cleanup ----
"$INIT" stop
"$CLI" nft-flush >/dev/null
uci -q delete wanguard-antidpi.tunnel || true
uci -q delete wanguard-antidpi.whitelist || true
uci commit wanguard-antidpi
cp /tmp/conf.default "$CONF"
rm -f "$MIHOMO_CONF"

echo "APPLY-TEST-OK"
