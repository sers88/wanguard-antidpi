#!/bin/sh
# tests/test-events.sh - the Tests & Logs events surface (#88): the
# `events` command behind the LuCI log viewer. Runs INSIDE an OpenWrt
# container (no NET_ADMIN - the surface is pure userspace):
#
#   docker run --rm \
#     -v <out>:/out:ro -v <tests>:/tests:ro \
#     openwrt/rootfs:x86_64-25.12.6 sh /tests/test-events.sh
#
# logread is a PATH stub (ucode children spawn through /bin/sh, so the
# test shell's PATH is inherited): a deterministic 30-line ring dump
# (10 nfqws2 + 10 wanguard-antidpi + 10 mihomo). The degraded scenario
# runs against the bare container PATH (no syslogd).
#
# Matrix:
#   [1] default: filter=engine, tail=50 -> only nfqws2|wanguard-antidpi
#       lines (the status events contract)
#   [2] explicit filters: nfqws2 / antidpi / mihomo each return only their
#       own lines
#   [3] tail: --tail=5 honored; --tail=5000 clamped to 200 (documented)
#   [4] usage errors: unknown filter, non-numeric tail, unknown option
#       (exit 2 + named stderr)
#   [5] degraded: no logread on PATH -> available=false, lines=[]
#   [6] status parity: status --json events == events --filter=engine
#       --tail=20 (the refactored log_tail_info must not drift the #76
#       byte contract)
#   [7] human view: header line + the tail lines
set -eu

CLI=/usr/bin/wanguard-antidpi
JS=/tmp/events.json

fail() {
	echo "EVENTS-TEST-FAIL: $1"
	exit 1
}

# jp '<ucode expr over s>' -> JSON rendering of the value (%J)
jp() {
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all')); printf('%J\n', ($1));"
}

jp_str() {
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all')); printf('%s\n', ($1));"
}

run() { # run <output-var> <rc-var> <cmd...> (stdout+stderr merged; set -e safe)
	local _o _e _r=0
	_o="$1"; _e="$2"; shift 2
	{ "$@"; } > /tmp/events.out 2>&1 || _r=$?
	eval "$_o=\$(cat /tmp/events.out)"
	eval "$_e=$_r"
}

grab() { # grab <cli args...>
	"$CLI" "$@" > "$JS" || fail "events $* exited nonzero"
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all'));
		if (type(s) != 'object') { warn('not an object\n'); exit(1); }" \
		|| fail "events $* is not a JSON object"
}

# ---- setup: package + logread stub ----
set -- /out/wanguard-antidpi-*.apk
[ -f "$1" ] || fail "no package in /out"
apk add --allow-untrusted "$@" >/dev/null
echo "== package installed: $("$CLI" version)"

STUB=/tmp/stub-bin
mkdir -p "$STUB"
cat > "$STUB/logread" <<'EOF'
#!/bin/sh
# deterministic 30-line ring: 10 nfqws2 + 10 wanguard-antidpi + 10 mihomo
i=1
while [ $i -le 10 ]; do
	echo "Thu Nov 12 10:00:0$((i % 10)) 2026 kern.warn kernel: nfqws2 verdict drop line $i"
	echo "Thu Nov 12 10:01:0$((i % 10)) 2026 daemon.info wanguard-antidpi: init step $i done"
	echo "Thu Nov 12 10:02:0$((i % 10)) 2026 user.warn mihomo: dial DIRECT failed warning $i"
	i=$((i + 1))
done
EOF
chmod +x "$STUB/logread"

export PATH="$STUB:$PATH"

# ---- [1] default: the engine filter, status-events parity of content ----
echo "== [1] default (engine filter, tail 50)"
grab events --json
[ "$(jp_str 's.filter')" = "engine" ] || fail "expected filter=engine (got $(jp_str 's.filter'))"
[ "$(jp 's.tail')" = "50" ] || fail "expected tail=50 (got $(jp 's.tail'))"
[ "$(jp 's.available')" = "true" ] || fail "expected available"
[ "$(jp 'length(s.lines)')" = "20" ] || fail "expected 20 engine lines (got $(jp 'length(s.lines)'))"
ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all'));
	for (let i = 0; i < length(s.lines); i++)
		if (index(s.lines[i], 'mihomo') >= 0) { warn('mihomo line leaked into the engine filter\n'); exit(1); }" \
	|| fail "engine filter leaked mihomo lines"
echo "DEFAULT-OK (engine filter = nfqws2 + wanguard-antidpi only)"

# ---- [2] explicit filters ----
echo "== [2] explicit filters"
for f in nfqws2 antidpi mihomo; do
	grab events --json --filter=$f
	[ "$(jp_str 's.filter')" = "$f" ] || fail "expected filter=$f"
	[ "$(jp 'length(s.lines)')" = "10" ] || fail "expected 10 $f lines (got $(jp 'length(s.lines)'))"
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all'));
		for (let i = 0; i < length(s.lines); i++)
			if (index(s.lines[i], '$f') < 0) { warn('line without $f\n'); exit(1); }" \
		|| fail "$f filter returned foreign lines"
done
echo "FILTERS-OK (nfqws2 / antidpi / mihomo each scoped)"

# ---- [3] tail honoring + clamp ----
echo "== [3] tail"
grab events --json --filter=mihomo --tail=5
[ "$(jp 'length(s.lines)')" = "5" ] || fail "--tail=5 not honored (got $(jp 'length(s.lines)'))"
[ "$(jp 's.tail')" = "5" ] || fail "tail echo wrong"
# the tail keeps the LAST lines: the ring numbers lines 1..10 per source
LAST=$(jp_str 's.lines[4]')
printf '%s' "$LAST" | grep -q "warning 10" || fail "expected the last ring line (warning 10), got: $LAST"
grab events --json --filter=mihomo --tail=5000
[ "$(jp 's.tail')" = "200" ] || fail "--tail=5000 must clamp to 200 (got $(jp 's.tail'))"
[ "$(jp 'length(s.lines)')" = "10" ] || fail "clamp must not change the content (got $(jp 'length(s.lines)'))"
echo "TAIL-OK (honored, clamped to 200)"

# ---- [4] usage errors (exit 2) ----
echo "== [4] usage errors"
run OUT RC "$CLI" events --json --filter=bogus
[ "$RC" = 2 ] || fail "unknown filter must exit 2 (got $RC)"
printf '%s' "$OUT" | grep -q "unknown filter" || fail "stderr must name the filter error"
run OUT RC "$CLI" events --json --tail=abc
[ "$RC" = 2 ] || fail "non-numeric tail must exit 2 (got $RC)"
printf '%s' "$OUT" | grep -q "positive number" || fail "stderr must name the tail error"
run OUT RC "$CLI" events --json --bogus
[ "$RC" = 2 ] || fail "unknown option must exit 2 (got $RC)"
printf '%s' "$OUT" | grep -q "unknown option" || fail "stderr must name the option error"
echo "USAGE-OK (bad flags exit 2 with named errors)"

# ---- [5] degraded: no syslogd ----
echo "== [5] degraded (bare container PATH: no logread)"
PATH="/usr/bin:/bin" "$CLI" events --json > "$JS" || fail "degraded events must not fail"
[ "$(jp 's.available')" = "false" ] || fail "expected available=false"
[ "$(jp 'length(s.lines)')" = "0" ] || fail "expected an empty array"
echo "DEGRADED-OK (available=false, lines=[])"

# ---- [6] status parity (the #76 contract must not drift) ----
echo "== [6] status parity"
PATH="$STUB:$PATH" "$CLI" status --json > /tmp/status.json
PATH="$STUB:$PATH" "$CLI" events --json --filter=engine --tail=20 > "$JS"
ucode -e "import { open } from 'fs';
	let st = json(open('/tmp/status.json').read('all'));
	let ev = json(open('$JS').read('all'));
	// ucode arrays have NO .length property (it silently reads null) -
	// only the global length() function
	if (length(st.events) != length(ev.lines)) { warn('count drift: ' + length(st.events) + ' vs ' + length(ev.lines) + '\n'); exit(1); }
	for (let i = 0; i < length(ev.lines); i++)
		if (st.events[i] != ev.lines[i]) { warn('line drift at ' + i + '\n'); exit(1); }" \
	|| fail "status events drifted from the events surface"
echo "PARITY-OK (status events == events --filter=engine --tail=20)"

# ---- [7] human view ----
echo "== [7] human view"
PATH="$STUB:$PATH" "$CLI" events --filter=mihomo --tail=2 > /tmp/human.txt
head -n 1 /tmp/human.txt | grep -q "events: filter=mihomo tail=2" || fail "human header wrong"
[ "$(wc -l < /tmp/human.txt)" = "3" ] || fail "human view = header + 2 lines"
PATH="/usr/bin:/bin" "$CLI" events > /tmp/human.txt
grep -q "unavailable" /tmp/human.txt || fail "degraded human view must say unavailable"
echo "HUMAN-OK (header + tail lines, degraded message)"

echo "EVENTS-TEST-OK"
