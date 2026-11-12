#!/bin/sh
# tests/test-profiles.sh - named strategy profiles (issue #84).
# Runs INSIDE an OpenWrt container (no NET_ADMIN needed for the structural
# part; the live engine scenario probes NFQUEUE first):
#
#   docker run --rm -v <out>:/out:ro -v <tests>:/tests:ro \
#     openwrt/rootfs:x86_64-25.12.6 sh /tests/test-profiles.sh
#
# The render contract under test (engine_argv):
#   - no profile sections -> engine.nfqws2_opt verbatim (the r9 byte-golden)
#   - one profile with the same words -> byte-equal argv to the legacy render
#   - N enabled profiles -> the words joined with --new separators, in
#     section file order; disabled sections skipped; empty-word enabled
#     sections skipped with a warn
#   - profile sections + legacy opt -> the legacy list IGNORED (warn)
#   - a whitespace-containing strategy word dies the render loudly (named
#     section), never reaches the engine
#   - --hostlist (whitelist mode) re-emits per profile block (#70 fact)
#
# Matrix:
#   [1]  golden legacy: pristine default -> 6 cmdline lines (binary + 5 base)
#   [2]  render-parity: 1 profile with words == legacy opt -> byte-equal
#   [3]  2 enabled + 1 default-on + disable -> --new separators, order,
#        skip semantics; uci reorder flips the render order
#   [4]  all disabled -> no-op strategy (6 lines), status profiles=0
#   [5]  legacy opt + profiles -> legacy IGNORED (warn named in stderr)
#   [6]  whitespace word -> engine-cmdline exits nonzero, section named
#   [7]  empty-word enabled profile -> skipped with a warn
#   [8]  whitelist + 2/3 profiles -> --hostlist count = profile block count
#   [9]  status --json: profile_sections (id/name/proto/enabled/words)
#   [10] live (NFQUEUE): engine starts on a 2-profile argv, fetch flows,
#        running_argv carries the profile separators
set -eu

CLI=/usr/bin/wanguard-antidpi
CONF=/etc/config/wanguard-antidpi
TABLE=wanguard_antidpi
JS=/tmp/profiles-status.json
MIHOMO_VERSION=1.19.33
MIHOMO_SHA256=132f6f3edf9a65e62f04853aed3358472e0b2b7666daa8419edfa2ddf5bb6323
MPORT=17890
PROBE=https://www.cloudflare.com/cdn-cgi/trace
ENG_PID=
M_PID=

fail() {
	echo "PROFILES-TEST-FAIL: $1"
	exit 1
}

cleanup() {
	[ -n "$ENG_PID" ] && kill "$ENG_PID" 2>/dev/null
	[ -n "$M_PID" ] && kill "$M_PID" 2>/dev/null
	return 0
}
trap cleanup EXIT

words() { # argv words without the binary line
	"$CLI" engine-cmdline 2>/tmp/profiles-err.log | tail -n +2
}

wc_lines() { words | grep -c . || true; }

has() { words | grep -qF -- "$1"; }

lacks() { words | grep -qF -- "$1" && fail "unexpected word: $1" || :; }

grab() {
	"$CLI" status --json > "$JS" || fail "status --json exited nonzero"
}

jp() { # jp '<ucode expr over s>'
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all')); printf('%J\n', ($1));"
}

jp_str() {
	ucode -e "import { open } from 'fs'; let s = json(open('$JS').read('all')); printf('%s\n', ($1));"
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

# ---- setup ----
set -- /out/wanguard-antidpi-*.apk
[ -f "$1" ] || fail "no package in /out"
apk add --allow-untrusted "$@" >/dev/null
apk add curl >/dev/null 2>&1 || true
echo "== package installed: $("$CLI" version)"
cp "$CONF" /tmp/profiles-conf.default

# ---- [1] golden legacy: pristine default ----
echo "== [1] golden legacy (no profile sections)"
[ "$(wc_lines)" = "5" ] || fail "pristine default must render the 5 base words (qnum/fwmark/user/2x lua-init), got $(wc_lines)"
words | grep -q '^--qnum=300$' || fail "qnum word missing from the golden"
words | grep -q '^--lua-init=@/usr/share/wanguard-antidpi/lua/zapret-antidpi.lua.gz$' || fail "lua-init word missing from the golden"
lacks '--new'
echo "GOLDEN-LEGACY-OK (the r9 byte-golden survives: no profiles -> verbatim opt)"

# ---- [2] render-parity: 1 profile == legacy opt ----
echo "== [2] render-parity (single profile vs legacy opt)"
uci add_list "$CONF.engine.nfqws2_opt=--filter-tcp=443"
uci add_list "$CONF.engine.nfqws2_opt=--payload=tls_client_hello"
uci commit "$CONF"
A=$($CLI engine-cmdline 2>/dev/null)
uci delete "$CONF.engine.nfqws2_opt"
add_prof prof_a 1 --filter-tcp=443 --payload=tls_client_hello
uci commit "$CONF"
B=$($CLI engine-cmdline 2>/dev/null)
[ "$A" = "$B" ] || fail "render-parity broken: the same words through a profile must render byte-equal"
echo "RENDER-PARITY-OK (profile words == legacy words -> identical argv)"

# ---- [3] multiple profiles: --new, order, skip semantics ----
echo "== [3] multiple profiles (order, --new, disabled skip)"
add_prof prof_b 1 --filter-udp=443 --payload=quic_initial
add_prof prof_c unset --filter-tcp=80
uci commit "$CONF"
words | grep -q '^--filter-tcp=80$' || fail "a section without the enabled option must render as enabled (default on)"
idx_a=$(words | grep -n '^--filter-tcp=443$' | head -n1 | cut -d: -f1)
idx_sep=$(words | grep -n '^--new$' | head -n1 | cut -d: -f1)
idx_b=$(words | grep -n '^--filter-udp=443$' | head -n1 | cut -d: -f1)
[ -n "$idx_a" ] && [ -n "$idx_sep" ] && [ -n "$idx_b" ] || fail "expected profile blocks separated by --new"
[ "$idx_a" -lt "$idx_sep" ] && [ "$idx_sep" -lt "$idx_b" ] \
	|| fail "render order must follow the section order (a, --new, b)"
echo "MULTI-ORDER-OK (section order = render order, default-on honored)"
uci set "$CONF.prof_c.enabled=0"
uci commit "$CONF"
lacks '--filter-tcp=80'
has '--filter-udp=443'
echo "DISABLED-SKIP-OK (disabled profile contributes no words)"
# reorder: section order drives the render - flip b before a
if uci reorder "$CONF.prof_b=0" >/dev/null 2>&1; then
	uci commit "$CONF"
	idx_a=$(words | grep -n '^--filter-tcp=443$' | head -n1 | cut -d: -f1)
	idx_sep=$(words | grep -n '^--new$' | head -n1 | cut -d: -f1)
	idx_b=$(words | grep -n '^--filter-udp=443$' | head -n1 | cut -d: -f1)
	[ "$idx_b" -lt "$idx_sep" ] && [ "$idx_sep" -lt "$idx_a" ] \
		|| fail "reordered sections must flip the render order"
	uci reorder "$CONF.prof_b=1" >/dev/null 2>&1
	uci commit "$CONF"
	echo "REORDER-OK (uci reorder flips the render order)"
else
	uci reorder "$CONF.prof_b" >/dev/null 2>&1 || true
	uci commit "$CONF"
	echo "REORDER-SKIP (this uci build lacks positional reorder)"
fi

# ---- [4] all disabled -> no-op strategy ----
echo "== [4] all profiles disabled"
uci set "$CONF.prof_a.enabled=0"
uci set "$CONF.prof_b.enabled=0"
uci commit "$CONF"
[ "$(wc_lines)" = "5" ] || fail "all-disabled profiles must render the bare base argv (5 base words), got $(wc_lines)"
lacks '--filter-tcp=443'
grab
[ "$(jp 's.engine.profiles')" = "0" ] || fail "all-disabled must report 0 rendered profiles"
[ "$(jp 'length(s.engine.profile_sections)')" = "3" ] || fail "sections must stay listed while they exist"
echo "ALL-DISABLED-OK (no-op strategy, sections still listed)"

# ---- [5] legacy opt + profiles -> legacy IGNORED ----
echo "== [5] legacy opt ignored while profiles exist"
uci add_list "$CONF.engine.nfqws2_opt=--legacy-marker=1"
uci set "$CONF.prof_a.enabled=1"
uci commit "$CONF"
words | grep -q '^--legacy-marker=1$' && fail "the legacy opt must be IGNORED while profile sections exist" || :
has '--filter-tcp=443'
grep -q 'IGNORED' /tmp/profiles-err.log || fail "the render must warn loudly when the legacy opt is shadowed by profiles"
echo "LEGACY-IGNORED-OK (profile words win, warn on stderr)"
uci delete "$CONF.engine.nfqws2_opt"
uci commit "$CONF"

# ---- [6] whitespace word -> loud render failure ----
# (the word rides in the engine argv: the render must die loudly, naming the
# section. Disabled profiles are skipped BEFORE validation - disabling is the
# escape hatch for a half-edited strategy, so the probe targets the enabled
# profile.)
echo "== [6] whitespace word rejected"
uci add_list "$CONF.prof_a.strategy_words=--filter-tcp= 443"
uci commit "$CONF"
RC=0
"$CLI" engine-cmdline >/dev/null 2>/tmp/profiles-err.log || RC=$?
[ "$RC" != 0 ] || fail "a whitespace strategy word must fail the render loudly"
grep -q 'prof_a' /tmp/profiles-err.log || fail "the render failure must name the offending section"
grep -q 'single argv word' /tmp/profiles-err.log || fail "the render failure must explain the contract"
uci del_list "$CONF.prof_a.strategy_words=--filter-tcp= 443"
uci commit "$CONF"
has '--filter-tcp=443'
echo "WHITESPACE-GUARD-OK (render dies with the section named)"

# ---- [7] empty-word enabled profile -> skipped with a warn ----
echo "== [7] empty profile skipped"
add_prof prof_empty 1
uci commit "$CONF"
N1=$(wc_lines)
grep -q 'no strategy words' /tmp/profiles-err.log || fail "an enabled empty profile must warn"
has '--filter-tcp=443'
# sole enabled + empty -> no-op strategy
uci set "$CONF.prof_a.enabled=0"
uci set "$CONF.prof_b.enabled=0"
uci commit "$CONF"
[ "$(wc_lines)" = "5" ] || fail "an empty-only enabled profile set must render the no-op argv (5 base words)"
grep -q 'no-op strategy' /tmp/profiles-err.log || fail "the empty-only set must warn no-op"
uci set "$CONF.prof_a.enabled=1"
uci set "$CONF.prof_b.enabled=1"
uci delete "$CONF.prof_empty"
uci commit "$CONF"
echo "EMPTY-SKIP-OK (empty enabled profile warns and contributes nothing)"

# ---- [8] --hostlist per profile block ----
echo "== [8] hostlist per-profile (whitelist mode)"
uci set "$CONF.whitelist=whitelist"
uci set "$CONF.whitelist.enabled=1"
uci add_list "$CONF.whitelist.domains=alpha.example"
uci commit "$CONF"
HL=$(words | grep -c -- '--hostlist=')
[ "$HL" = "2" ] || fail "whitelist + 2 profile blocks must emit 2 --hostlist words (got $HL)"
add_prof prof_c1 1 --filter-tcp=80
uci commit "$CONF"
HL=$(words | grep -c -- '--hostlist=')
[ "$HL" = "3" ] || fail "whitelist + 3 profile blocks must emit 3 --hostlist words (got $HL)"
# the whitelist-only legacy emission contract stays: no profiles -> 1
uci delete "$CONF.prof_a"
uci delete "$CONF.prof_b"
uci delete "$CONF.prof_c"
uci delete "$CONF.prof_c1"
uci add_list "$CONF.engine.nfqws2_opt=--filter-tcp=443"
uci commit "$CONF"
HL=$(words | grep -c -- '--hostlist=')
[ "$HL" = "1" ] || fail "whitelist + legacy opt must emit exactly 1 --hostlist (got $HL)"
uci delete "$CONF.whitelist"
uci delete "$CONF.engine.nfqws2_opt"
uci commit "$CONF"
echo "HOSTLIST-PER-PROFILE-OK (one --hostlist per profile block, legacy = 1)"

# ---- [9] status: profile_sections ----
echo "== [9] status profile_sections"
add_prof prof_a 1 --filter-tcp=443 --payload=tls_client_hello
uci set "$CONF.prof_a.proto=tcp quic"
add_prof prof_b 0 --filter-udp=443
uci commit "$CONF"
grab
[ "$(jp 'length(s.engine.profile_sections)')" = "2" ] || fail "expected 2 sections"
[ "$(jp_str 's.engine.profile_sections[0].id')" = "prof_a" ] || fail "section order broken"
[ "$(jp_str 's.engine.profile_sections[0].name')" = "prof_a label" ] || fail "label not surfaced"
[ "$(jp 'length(s.engine.profile_sections[0].proto)')" = "2" ] || fail "proto tokens not parsed"
[ "$(jp_str 's.engine.profile_sections[0].proto[0]')" = "tcp" ] || fail "proto token 0"
[ "$(jp_str 's.engine.profile_sections[0].proto[1]')" = "quic" ] || fail "proto token 1"
[ "$(jp 's.engine.profile_sections[0].enabled')" = "true" ] || fail "enabled must be boolean true"
[ "$(jp 's.engine.profile_sections[0].words')" = "2" ] || fail "word count"
[ "$(jp 's.engine.profile_sections[1].enabled')" = "false" ] || fail "disabled must be boolean false"
[ "$(jp 's.engine.profiles')" = "1" ] || fail "rendered profile count must count enabled-with-words only"
echo "STATUS-SECTIONS-OK (id/name/proto/enabled/words in the status document)"

# ---- [10] live engine on a 2-profile argv ----
echo "== [10] live engine (multi-profile health check)"
LIVE=1
nft add table inet devprobe84 2>/dev/null || LIVE=0
if [ "$LIVE" = 1 ]; then
	nft add chain inet devprobe84 e '{ type filter hook postrouting priority 400; }' 2>/dev/null || LIVE=0
	nft add rule inet devprobe84 e ip daddr 192.0.2.1 counter queue num 305 bypass 2>/dev/null || LIVE=0
	nft delete table inet devprobe84 2>/dev/null || true
fi
if [ "$LIVE" != 1 ]; then
	echo "PROFILES-LIVE-SKIP (host kernel lacks NFQUEUE - live matrix is router acceptance only)"
	echo "PROFILES-TEST-OK (structural)"
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
mihomo -f /etc/mihomo/config.yaml -d /usr/share/mihomo >/tmp/profiles-mihomo.log 2>&1 &
M_PID=$!
i=0
while [ $i -lt 30 ]; do
	netstat -lnt 2>/dev/null | grep -q ":$MPORT " && break
	i=$((i + 1))
	sleep 1
done
netstat -lnt 2>/dev/null | grep -q ":$MPORT " || fail "mihomo mixed-port did not come up (log: $(tail -2 /tmp/profiles-mihomo.log))"
# profile A: real TCP desync functions; profile B: UDP filter block - the
# engine must accept the whole multi-profile argv and keep serving.
# (busybox uci set on a list option DEMOTES it to a scalar - delete first,
# then add_list per word; AGENTS #82 gotcha.)
uci delete "$CONF.prof_a.strategy_words" 2>/dev/null || :
uci add_list "$CONF.prof_a.strategy_words=--filter-tcp=443"
uci add_list "$CONF.prof_a.strategy_words=--payload=tls_client_hello"
uci add_list "$CONF.prof_a.strategy_words=--lua-desync=multisplit:pos=midsld"
uci set "$CONF.prof_b.enabled=1"
uci delete "$CONF.prof_b.strategy_words" 2>/dev/null || :
uci add_list "$CONF.prof_b.strategy_words=--filter-udp=443"
uci commit "$CONF"
set -- $("$CLI" engine-cmdline)
prog=$1
shift
"$prog" "$@" >/tmp/profiles-engine.log 2>&1 &
ENG_PID=$!
sleep 3
kill -0 "$ENG_PID" 2>/dev/null || fail "engine died on the 2-profile argv (log: $(tail -3 /tmp/profiles-engine.log))"
code=""
for r in 1 2 3; do
	code=$(curl -s -m 20 -x "http://127.0.0.1:$MPORT" -o /dev/null -w '%{http_code}' "$PROBE" || true)
	[ "$code" = "200" ] && break
	sleep 2
done
[ "$code" = "200" ] || fail "traffic did not flow through the 2-profile engine (code=$code)"
grab
[ "$(jp 's.engine.profiles')" = "2" ] || fail "status must count 2 rendered profiles"
[ "$(jp 'length(s.engine.running_argv)')" = "11" ] || fail "expected 11 running-argv entries (binary + 5 base + 3 A + --new + 1 B), got $(jp 'length(s.engine.running_argv)')"
ucode -e "import { open } from 'fs'; let a = json(open('$JS').read('all')).engine.running_argv;
	let n = 0; for (let i = 0; i < length(a); i++) if (a[i] == '--new') n++;
	if (n != 1) { warn('expected exactly one --new in the running argv, got ' + n + '\n'); exit(1); }" \
	|| fail "the running argv must carry the profile separator"
echo "ENGINE-MULTI-PROFILE-OK (started, fetch 200, running argv carries both blocks)"

# ---- cleanup ----
kill "$ENG_PID" 2>/dev/null
kill "$M_PID" 2>/dev/null
ENG_PID=
M_PID=
"$CLI" nft-flush >/dev/null 2>&1 || true
cp /tmp/profiles-conf.default "$CONF"

echo "PROFILES-TEST-OK"
