#!/bin/sh
# scripts/fetch-upstream.sh - fetch the pinned upstream engine payload for
# packaging (issue #57). HOST-side script: dev stand runs it under Git Bash,
# CI runs it on the ubuntu runner; it never runs inside the OpenWrt container.
#
# Downloads the zapret2 release artifact, verifies BOTH pins (the tarball
# sha256 computed from the release artifact, and the canonical
# linux-x86_64/nfqws2 hash from the upstream sha256sum.txt), then extracts
# ONLY the packaged members into out/upstream/:
#
#   nfqws2                  binaries/linux-x86_64/nfqws2  (static engine)
#   zapret-lib.lua.gz       lua/                          (required)
#   zapret-antidpi.lua.gz   lua/                          (required)
#
# Everything else in the artifact (install_easy.sh, upstream init.d/openwrt,
# its nft mechanics, blockcheck, ip2net/mdig) is intentionally NOT packaged:
# the add-on owns the lifecycle; upstream's installer is not used.
# zapret-auto.lua.gz is deferred until the autohostlist decision.
#
# Local fast path: if out/upstream/nfqws2 already matches the binary pin,
# the download is skipped (CI always downloads fresh).
set -eu
cd "$(dirname "$0")/.."

# Default pins; override via environment for local experiments only.
# ZAPRET2_VERSION_DEFAULT is the machine-readable pin: the CI tag guard and
# the container smoke read it to assert the shipped engine matches.
ZAPRET2_VERSION_DEFAULT=1.0.7
ZAPRET2_VERSION="${ZAPRET2_VERSION:-$ZAPRET2_VERSION_DEFAULT}"
ZAPRET2_TARBALL_SHA256="${ZAPRET2_TARBALL_SHA256:-d2799bc8dffc03a21f977d3a0e2d8a8626105db630c03d9b99d5164980d5db16}"
NFQWS2_SHA256="${NFQWS2_SHA256:-4bb2634f0266bcc3cbe5988f4fc8c5e824649dd11edc418e71a415096c2505b0}"
URL="https://github.com/bol-van/zapret2/releases/download/v$ZAPRET2_VERSION/zapret2-v$ZAPRET2_VERSION-openwrt-embedded.tar.gz"

if [ -f out/upstream/nfqws2 ]; then
	if printf '%s  %s\n' "$NFQWS2_SHA256" out/upstream/nfqws2 | sha256sum -c - >/dev/null 2>&1; then
		echo "== upstream payload already pinned ($ZAPRET2_VERSION): out/upstream/nfqws2"
		exit 0
	fi
	echo "== out/upstream/nfqws2 present but stale, re-fetching" >&2
	rm -rf out/upstream
fi

mkdir -p out/upstream out/upstream.unpack
trap 'rm -rf out/upstream.unpack' EXIT
tarball="out/zapret2-v$ZAPRET2_VERSION-openwrt-embedded.tar.gz"

if [ -f "$tarball" ] && printf '%s  %s\n' "$ZAPRET2_TARBALL_SHA256" "$tarball" | sha256sum -c - >/dev/null 2>&1; then
	echo "== tarball cached: $tarball"
else
	echo "== downloading zapret2 v$ZAPRET2_VERSION (openwrt-embedded artifact)"
	curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 -o "$tarball" "$URL"
fi

printf '%s  %s\n' "$ZAPRET2_TARBALL_SHA256" "$tarball" | sha256sum -c -

echo "== extracting packaged members"
base="zapret2-v$ZAPRET2_VERSION"
tar -xzf "$tarball" -C out/upstream.unpack \
	"$base/binaries/linux-x86_64/nfqws2" \
	"$base/lua/zapret-lib.lua.gz" \
	"$base/lua/zapret-antidpi.lua.gz"
mv "out/upstream.unpack/$base/binaries/linux-x86_64/nfqws2" out/upstream/nfqws2
mv "out/upstream.unpack/$base/lua/zapret-lib.lua.gz" out/upstream/zapret-lib.lua.gz
mv "out/upstream.unpack/$base/lua/zapret-antidpi.lua.gz" out/upstream/zapret-antidpi.lua.gz

printf '%s  %s\n' "$NFQWS2_SHA256" out/upstream/nfqws2 | sha256sum -c -
chmod 755 out/upstream/nfqws2
echo "== upstream payload ready: out/upstream/"
