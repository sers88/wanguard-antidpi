#!/bin/sh
# scripts/dev-test.sh - the dev stand in one command, from zero to the full
# container test matrix (issue #63): kernel probe -> local build ->
# [1] install + smoke (tests/container-smoke.sh: layout, conffile contract,
#     DRYRUN forms, structural shape)
# [2] mihomo mark integration (tests/test-mark.sh, REAL pinned mihomo)
# [3] nft scope table (tests/test-nft.sh, live when the host kernel allows)
# [4] forward-source scope behind SNAT (tests/test-forward.sh, two
#     containers: client -> router -> WAN through the fw4 slot; issue #107
#     regression stand)
# [5] tunnel resolver updater (tests/test-tunnel.sh, stub DNS)
# [6] status surface (tests/test-status.sh, live engine part when allowed)
# [7] apply orchestration (tests/test-apply.sh, stub init + stub DNS)
# [8] luci menu + ACL matrix (tests/test-luci.sh, issue #78; the luci-base
#     dependency resolves from the image feed - the only step needing the
#     network beyond the build)
# [14] luci view tests (tests/luci/run-tests.js, issue #89: the REAL view +
#     core module with stubbed LuCI globals, node container; CI runs the
#     same command in the same image)
# Router not required; only Docker must be up. CI runs byte-identical scripts
# (same tests/*.sh, same mounts, same container image), so local and CI
# results are comparable by construction.
#
# Usage: dev-test.sh [version]   (default dev version: 0.0.0-r0)
set -eu

cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-openwrt/rootfs:x86_64-25.12.6}"

# see dev-build.sh: keep docker -v arguments intact under Git Bash
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
hostpath() {
	if uname -s | grep -qiE 'mingw|msys|cygwin'; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

echo "=== [1/14] kernel probe (NFQUEUE support in the container kernel)"
probe=$(sh scripts/kernel-probe.sh) || {
	printf '%s\n' "$probe"
	exit 1
}
printf '%s\n' "$probe"

echo "=== [2/14] local build"
sh scripts/dev-build.sh "$@"

ls out/wanguard-antidpi-*.apk >/dev/null 2>&1 || {
	echo "ERROR: dev-build produced no package in out/" >&2
	exit 1
}
pkg=$(ls out/wanguard-antidpi-*.apk | head -n 1)
ver=${pkg#*/wanguard-antidpi-}
ver=${ver%.apk}
ls out/luci-app-wanguard-antidpi-*.apk >/dev/null 2>&1 || {
	echo "ERROR: dev-build produced no luci package in out/ (issue #78)" >&2
	exit 1
}

echo "=== [3/14] install + smoke matrix (fresh container)"
docker run --rm \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/scripts"):/scripts:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/container-smoke.sh local "$ver"

echo "=== [4/14] mihomo mark integration (fresh container, NET_ADMIN)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-mark.sh

echo "=== [5/14] nft scope table (fresh container, NET_ADMIN)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-nft.sh

echo "=== [6/14] forward-source scope behind SNAT (two-container stand, NET_ADMIN; issue #107)"
# client container -> router container -> WAN, masquerade in the fw4 slot
# BEFORE the antidpi hook: the blind spot that let #102's render ship inert
# on the live router (test-nft.sh [7] covers LOCAL output only, which is
# never SNAT'ed). Topology + assertions live in tests/test-forward.sh.
docker rm -f antidpi-fw-router antidpi-fw-client >/dev/null 2>&1 || :
docker network rm lantest >/dev/null 2>&1 || :
docker network create --subnet 192.168.77.0/24 --gateway 192.168.77.1 lantest >/dev/null
docker run -d --name antidpi-fw-router --cap-add NET_ADMIN \
	--network bridge \
	--sysctl net.ipv4.ip_forward=1 \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" sleep 900 >/dev/null
docker network connect --ip 192.168.77.2 lantest antidpi-fw-router
docker run -d --name antidpi-fw-client --cap-add NET_ADMIN \
	--network lantest --ip 192.168.77.3 \
	"$IMAGE" sleep 900 >/dev/null
docker exec antidpi-fw-client ip route del default
docker exec antidpi-fw-client ip route add default via 192.168.77.2
# backgrounded probe loop: every curl is a fresh TLS connection forwarded
# through the router (the router polls the masquerade counter, so the cold
# client `apk add curl` is covered)
docker exec -d antidpi-fw-client sh -c \
	'apk add curl >/dev/null 2>&1; while true; do curl -s -m 20 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace; sleep 3; done'
rc=0
docker exec antidpi-fw-router sh /tests/test-forward.sh eth0 eth1 192.168.77.3 192.168.77.0/24 || rc=$?
docker rm -f antidpi-fw-router antidpi-fw-client >/dev/null 2>&1 || :
docker network rm lantest >/dev/null 2>&1 || :
[ "$rc" = "0" ] || exit 1

echo "=== [7/14] tunnel resolver updater (fresh container, NET_ADMIN)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-tunnel.sh

echo "=== [8/14] status surface (fresh container, NET_ADMIN)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-status.sh

echo "=== [9/14] apply orchestration (fresh container, NET_ADMIN)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-apply.sh

echo "=== [10/14] luci menu + ACL matrix (fresh container; needs the feed for luci-base)"
docker run --rm \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-luci.sh "$ver"

echo "=== [11/14] strategy profiles (fresh container, NET_ADMIN; live part probes NFQUEUE)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-profiles.sh

echo "=== [12/14] policies (fresh container, NET_ADMIN; live part probes NFQUEUE + send inventory)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-policies.sh

echo "=== [13/14] events surface (fresh container; logread stub on PATH)"
docker run --rm \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-events.sh

echo "=== [14/14] luci view tests (node container; the #89 view harness)"
docker run --rm \
	-v "$(hostpath "$PWD"):/repo:ro" \
	-w /repo \
	node:24-alpine \
	node tests/luci/run-tests.js

if printf '%s\n' "$probe" | grep -q '^NFQUEUE-OK'; then
	echo "DEV-TEST-OK (matrix green: $ver; NFQUEUE live scenarios testable here)"
else
	echo "DEV-TEST-OK (matrix green: $ver; NOTE: NFQUEUE unavailable on this host - live scenarios are router acceptance only)"
fi
