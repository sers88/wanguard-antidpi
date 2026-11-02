#!/bin/sh
# scripts/dev-build.sh - build the apk package locally inside the same OpenWrt
# container image CI uses (issue #59). Produces out/*.apk; no router, no feed.
#
# Usage: dev-build.sh [version]   (default dev version: 0.0.0-r0)
#
# The package is intentionally unsigned (like CI); the feed index signature is
# what routers verify, and the local smoke installs with --allow-untrusted.
set -eu

cd "$(dirname "$0")/.."
IMAGE="${IMAGE:-openwrt/rootfs:x86_64-25.12.6}"
VER="${1:-${VER:-0.0.0-r0}}"
APK_STATIC_URL="https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v3.0.7/x86_64/apk.static"
APK_STATIC_SHA256="c07bf5356eacc9dd7a8c56bc537f46702f007170287403299d52a04264e74b3c"

# Git Bash mangles "-v /e/...:/work" style docker arguments unless conversion
# is off; harmless on Linux (unknown env vars are ignored)
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
hostpath() {
	if uname -s | grep -qiE 'mingw|msys|cygwin'; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

docker version >/dev/null 2>&1 || {
	echo "ERROR: docker is not reachable (start Docker Desktop first)" >&2
	exit 1
}

mkdir -p out
if [ ! -f out/apk.static ]; then
	echo "== downloading pinned apk.static 3.0.7 (same pin as CI)"
	curl -fsSL --retry 3 --connect-timeout 20 -o out/apk.static "$APK_STATIC_URL" \
		|| curl -fsSL --retry 3 --connect-timeout 20 -o out/apk.static \
			"https://github.com/sers88/wanguard/releases/download/ci-tools/apk.static"
	echo "$APK_STATIC_SHA256  out/apk.static" | sha256sum -c -
	chmod +x out/apk.static
fi

echo "== building wanguard-antidpi $VER in $IMAGE"
sh scripts/fetch-upstream.sh
docker run --rm \
	-v "$(hostpath "$PWD"):/work" -w /work \
	"$IMAGE" \
	sh apk/build.sh /work ./out/apk.static "$VER" out

echo "== build done:"
ls -l out/
