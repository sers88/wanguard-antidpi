#!/bin/sh
# tests/test-mark.sh - mihomo routing-mark integration test (issue #60).
# Runs INSIDE an OpenWrt container (network for the pinned mihomo fetch,
# NET_ADMIN for the real SO_MARK socket path):
#
#   docker run --rm --cap-add NET_ADMIN \
#     -v <out>:/out:ro -v <tests>:/tests:ro \
#     openwrt/rootfs:x86_64-25.12.6 sh /tests/test-mark.sh
#
# Covers what container-smoke.sh cannot (smoke has no mihomo binary):
#   - real `mihomo -t` validation after the inject
#   - mihomo STARTS with the injected mark and reports it via GET /configs
#   - LIVE REST reload both directions (install/remove while mihomo is up)
#   - idempotency, conflict, DRYRUN with the real binary present
set -eu

MIHOMO_VERSION=1.19.33
MIHOMO_SHA256=132f6f3edf9a65e62f04853aed3358472e0b2b7666daa8419edfa2ddf5bb6323

CLI=/usr/bin/wanguard-antidpi
CONF=/etc/mihomo/config.yaml
API=http://127.0.0.1:19090
AUTH='Authorization: Bearer marktest'
PID=

fail() {
	echo "MARK-TEST-FAIL: $1"
	exit 1
}

cleanup() {
	[ -n "$PID" ] && kill "$PID" 2>/dev/null
	return 0
}
trap cleanup EXIT

api() {
	curl -s -m 5 -H "$AUTH" "$@"
}

getmark() {
	api "$API/configs" | grep -o '"routing-mark":[0-9]*' | head -n 1
}

start_mihomo() {
	mihomo -f "$CONF" -d /usr/share/mihomo >/tmp/mihomo.log 2>&1 &
	PID=$!
	i=0
	while [ $i -lt 30 ]; do
		if api "$API/version" >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	fail "mihomo API did not come up (log: $(tail -3 /tmp/mihomo.log))"
}

# ---- setup: package + real pinned mihomo ----
set -- /out/wanguard-antidpi-*.apk
[ -f "$1" ] || fail "no package in /out"
apk add --allow-untrusted "$@" >/dev/null
apk add curl >/dev/null 2>&1 || true
cd /tmp
curl -sSL --retry 5 --retry-all-errors --retry-delay 3 -o mihomo.gz "https://github.com/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-amd64-v${MIHOMO_VERSION}.gz"
echo "${MIHOMO_SHA256}  mihomo.gz" | sha256sum -c - >/dev/null || fail "mihomo.gz sha256 mismatch"
gzip -dc mihomo.gz > /usr/bin/mihomo
chmod 755 /usr/bin/mihomo
echo "== mihomo: $(mihomo -v | head -n 1)"
mkdir -p /etc/mihomo /usr/share/mihomo

cat > "$CONF" <<'EOF'
mixed-port: 17890
external-controller: 127.0.0.1:19090
secret: marktest
mode: rule
log-level: warning
EOF
cp "$CONF" /tmp/orig.yaml

# ---- A: offline install - real validation, start with the mark ----
echo "== A: offline install + start"
out=$("$CLI" mark-install) || fail "A: install rc"
case "$out" in *"mihomo -t ok"*) ;; *) fail "A: no real validation in log: $out" ;; esac
case "$out" in *"mihomo not running"*) ;; *) fail "A: expected not-running note: $out" ;; esac
[ "$(head -n 1 "$CONF")" = "routing-mark: 268435456" ] || fail "A: inject line"
start_mihomo
[ "$(getmark)" = '"routing-mark":268435456' ] \
	|| fail "A: live mihomo does not report the mark (got: $(getmark))"
grep -qiE 'fatal|error while routing|operation not permitted' /tmp/mihomo.log \
	&& fail "A: mark errors in the mihomo log"
echo "A-OK (mihomo started with the mark, GET /configs proves it)"

# ---- B: remove while running - live reload down ----
echo "== B: live remove (reload while running)"
cp "$CONF" /tmp/marked.yaml
out=$("$CLI" mark-remove) || fail "B: remove rc"
case "$out" in *"mihomo reloaded via REST"*) ;; *) fail "B: no live reload in log: $out" ;; esac
cmp -s "$CONF" /tmp/orig.yaml || fail "B: config not restored byte-for-byte"
gm=$(getmark)
case "$gm" in
	'"routing-mark":0' | "") ;;
	*) fail "B: mark still live after remove+reload (got: $gm)" ;;
esac
echo "B-OK (restore + live reload, mark gone from the running process)"

# ---- C: install while running - live reload up; idempotent ----
echo "== C: live install (reload while running) + idempotency"
out=$("$CLI" mark-install) || fail "C: install rc"
case "$out" in *"injected"*) ;; *) fail "C: expected a fresh install: $out" ;; esac
case "$out" in *"mihomo reloaded via REST"*) ;; *) fail "C: no live reload in log: $out" ;; esac
[ "$(getmark)" = '"routing-mark":268435456' ] || fail "C: mark not live after reload"
cp "$CONF" /tmp/pre-c2.yaml
out=$("$CLI" mark-install) || fail "C: second install rc"
case "$out" in *"already installed"*) ;; *) fail "C: not idempotent: $out" ;; esac
cmp -s "$CONF" /tmp/pre-c2.yaml || fail "C: idempotent run changed the config"
echo "C-OK (live reload up + idempotent no-op)"

# ---- D: conflict + DRYRUN with the real binary ----
echo "== D: conflict + DRYRUN"
"$CLI" mark-remove >/dev/null || fail "D: remove rc"
printf 'routing-mark: 12345\nmode: rule\n' > "$CONF"
cp "$CONF" /tmp/conflict.yaml
"$CLI" mark-install >/tmp/d.log 2>&1 && fail "D: conflict install rc=0"
grep -q "conflict" /tmp/d.log || fail "D: no conflict message"
cmp -s "$CONF" /tmp/conflict.yaml || fail "D: conflict touched the config"
out=$(WANGUARD_ANTIDPI_DRYRUN=1 "$CLI" mark-install)
case "$out" in *DRYRUN*) ;; *) fail "D: no DRYRUN marker" ;; esac
cmp -s "$CONF" /tmp/conflict.yaml || fail "D: DRYRUN touched the config"
out=$("$CLI" mark-status)
case "$out" in
	*"mark: conflict (12345)"*) ;;
	*) fail "D: status conflict format" ;;
esac
out=$("$CLI" mark-ensure)
case "$out" in *"disabled"*) ;; *) fail "D: ensure did not honor the stamp" ;; esac
echo "D-OK (conflict fatal + untouched, DRYRUN inert, stamp honored)"

# ---- E: graceful no-config ----
echo "== E: graceful no-config"
rm -rf /etc/mihomo
out=$("$CLI" mark-install) || fail "E: install rc"
case "$out" in *"config missing"*) ;; *) fail "E: expected graceful skip: $out" ;; esac
echo "E-OK (graceful no-op without mihomo config)"

echo "MARK-TEST-OK ($MIHOMO_VERSION)"
