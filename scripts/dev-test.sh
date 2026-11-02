#!/bin/sh
# scripts/dev-test.sh - the dev stand in one command, from zero to smoke
# (issue #59): kernel probe -> local build -> fresh container install + smoke.
# Router not required; only Docker must be up. CI runs the same
# scripts/container-smoke.sh in feed mode, so results are comparable.
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

echo "=== [1/3] kernel probe (NFQUEUE support in the container kernel)"
probe=$(sh scripts/kernel-probe.sh) || {
	printf '%s\n' "$probe"
	exit 1
}
printf '%s\n' "$probe"

echo "=== [2/3] local build"
sh scripts/dev-build.sh "$@"

echo "=== [3/3] install + smoke (fresh container)"
ls out/wanguard-antidpi-*.apk >/dev/null 2>&1 || {
	echo "ERROR: dev-build produced no package in out/" >&2
	exit 1
}
pkg=$(ls out/wanguard-antidpi-*.apk | head -n 1)
ver=${pkg#*/wanguard-antidpi-}
ver=${ver%.apk}

docker run --rm \
	-v "$(hostpath "$PWD/out"):/out:ro" \
	-v "$(hostpath "$PWD/scripts"):/scripts:ro" \
	"$IMAGE" \
	sh /scripts/container-smoke.sh local "$ver"

if printf '%s\n' "$probe" | grep -q '^NFQUEUE-OK'; then
	echo "DEV-TEST-OK ($ver; NFQUEUE live scenarios testable here)"
else
	echo "DEV-TEST-OK ($ver; NOTE: NFQUEUE unavailable on this host - container tests stay structural, live scenarios are router acceptance only)"
fi
