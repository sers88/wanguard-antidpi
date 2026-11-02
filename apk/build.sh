#!/bin/sh
# apk/build.sh - build the wanguard-antidpi apk package (file packaging,
# no compilation).
#
# Usage: build.sh <repo-root> <apk.static> <version> <outdir>
#   repo-root   checkout of sers88/wanguard-antidpi (this repo, main branch)
#   apk.static  pinned apk-tools 3.0.7 binary (has the mkpkg applet; the
#               router's 3.0.5 build does not)
#   version     package version, e.g. 0.1.0-r1 (release) or 0.0.0-rN (dev)
#   outdir      where the *.apk files land
#
# Phase 1 (issue #57): the package now carries the real engine payload -
# static nfqws2 (zapret2 v1.0.6, pinned by sha256 via scripts/fetch-upstream.sh)
# + gzipped lua strategies + own procd init + config template + nft table
# template. The bootstrap stamp (issue #56) remains as the version file.
#
# Index generation and signing (packages.adb via mkndx --sign) happen in CI,
# not here. Packages are intentionally unsigned; the feed index signature is
# what the router verifies against /etc/apk/keys/wanguard-antidpi.pem.
set -eu

ROOT="${1:?usage: build.sh <repo-root> <apk.static> <version> <outdir>}"
APK="${2:?missing apk.static path}"
VER="${3:?missing version}"
OUT="${4:?missing outdir}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$OUT"

# ---- upstream engine payload (issue #57) ----
# Produced by scripts/fetch-upstream.sh (pins: tarball sha256 + canonical
# nfqws2 sha256 from the upstream sha256sum.txt). This script only packages;
# it does not download.
UP="$ROOT/out/upstream"
for f in nfqws2 zapret-lib.lua.gz zapret-antidpi.lua.gz; do
	[ -f "$UP/$f" ] || {
		echo "build.sh: missing upstream payload $UP/$f - run scripts/fetch-upstream.sh first" >&2
		exit 1
	}
done

# NB: cp+chmod, not install(1) - the OpenWrt container busybox has no
# install(1), and this script is smoke-tested there.
W="$work/wanguard-antidpi"
mkdir -p "$W/usr/bin" "$W/usr/share/wanguard-antidpi/lua" "$W/etc/wanguard-antidpi" "$W/etc/init.d"
# engine payload (static nfqws2 + gzipped lua strategies, unmodified)
cp "$UP/nfqws2" "$W/usr/bin/nfqws2"
chmod 755 "$W/usr/bin/nfqws2"
cp "$UP/zapret-lib.lua.gz" "$UP/zapret-antidpi.lua.gz" "$W/usr/share/wanguard-antidpi/lua/"
chmod 644 "$W/usr/share/wanguard-antidpi/lua/"*.gz
# own lifecycle (upstream installer/init/nft mechanics are NOT used)
cp "$ROOT/router/wanguard-antidpi" "$W/usr/bin/wanguard-antidpi"
chmod 755 "$W/usr/bin/wanguard-antidpi"
cp "$ROOT/router/wanguard-antidpi.nft" "$W/usr/share/wanguard-antidpi/wanguard-antidpi.nft"
chmod 644 "$W/usr/share/wanguard-antidpi/wanguard-antidpi.nft"
cp "$ROOT/router/init.d/wanguard-antidpi" "$W/etc/init.d/wanguard-antidpi"
chmod 755 "$W/etc/init.d/wanguard-antidpi"
# config template shipped as the live conffile: apk protects /etc, so a
# user-modified config survives upgrades (new default arrives as
# config.apk-new next to it)
cp "$ROOT/router/etc.wanguard-antidpi.config" "$W/etc/wanguard-antidpi/config"
chmod 644 "$W/etc/wanguard-antidpi/config"
# build stamp: the CI install test asserts it equals the package version
# (and the CLI reports it); later phases surface it in status.
printf '%s\n' "$VER" > "$W/usr/share/wanguard-antidpi/version"

# kmods from the upstream OpenWrt feed, unpinned (apk resolves the kernel
# version); nftables = the userspace nft binary (present via fw4, declared
# as the contract)
DEPS="kmod-nft-queue kmod-nfnetlink-queue nftables"

"$APK" mkpkg -F "$W" \
	-I "name:wanguard-antidpi" \
	-I "version:$VER" \
	-I "arch:x86_64" \
	-I "description:Anti-DPI add-on for OpenWrt: nfqws2 (zapret2) engine scoped to mihomo DIRECT egress" \
	-I "license:MIT" \
	-I "maintainer:sers88" \
	-I "url:https://github.com/sers88/wanguard-antidpi" \
	-I "depends:$DEPS" \
	--compat 3.0.5 \
	-o "$OUT/wanguard-antidpi-$VER.apk"
echo "built $OUT/wanguard-antidpi-$VER.apk"
