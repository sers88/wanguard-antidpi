#!/bin/sh
# scripts/dev-test.sh - the dev stand in one command, from zero to the full
# container test matrix (issue #63): kernel probe -> local build ->
# [1] install + smoke (tests/container-smoke.sh: layout, conffile contract,
#     DRYRUN forms, structural shape)
# [2] mihomo mark integration (tests/test-mark.sh, REAL pinned mihomo)
# [3] nft scope table (tests/test-nft.sh, live when the host kernel allows)
# [4] tunnel resolver updater (tests/test-tunnel.sh, stub DNS)
# [5] status surface (tests/test-status.sh, live engine part when allowed)
# [6] apply orchestration (tests/test-apply.sh, stub init + stub DNS)
# [7] luci menu + ACL matrix (tests/test-luci.sh, issue #78; the luci-base
#     dependency resolves from the image feed - the only step needing the
#     network beyond the build)
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

echo "=== [1/10] kernel probe (NFQUEUE support in the container kernel)"
probe=$(sh scripts/kernel-probe.sh) || {
	printf '%s\n' "$probe"
	exit 1
}
printf '%s\n' "$probe"

echo "=== [2/10] local build"
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

echo "=== [3/10] install + smoke matrix (fresh container)"
docker run --rm \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/scripts"):/scripts:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/container-smoke.sh local "$ver"

echo "=== [4/10] mihomo mark integration (fresh container, NET_ADMIN)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-mark.sh

echo "=== [5/10] nft scope table (fresh container, NET_ADMIN)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-nft.sh

echo "=== [6/10] tunnel resolver updater (fresh container, NET_ADMIN)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-tunnel.sh

echo "=== [7/10] status surface (fresh container, NET_ADMIN)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-status.sh

echo "=== [8/10] apply orchestration (fresh container, NET_ADMIN)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-apply.sh

echo "=== [9/10] luci menu + ACL matrix (fresh container; needs the feed for luci-base)"
docker run --rm \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-luci.sh "$ver"

echo "=== [10/10] strategy profiles (fresh container, NET_ADMIN; live part probes NFQUEUE)"
docker run --rm --cap-add NET_ADMIN \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/tests"):/tests:ro" \
	"$IMAGE" \
	sh /tests/test-profiles.sh

if printf '%s\n' "$probe" | grep -q '^NFQUEUE-OK'; then
	echo "DEV-TEST-OK (matrix green: $ver; NFQUEUE live scenarios testable here)"
else
	echo "DEV-TEST-OK (matrix green: $ver; NOTE: NFQUEUE unavailable on this host - live scenarios are router acceptance only)"
fi
