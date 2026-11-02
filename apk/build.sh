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
# Phase 1 bootstrap (issue #56): one package carrying a placeholder CLI and
# a build stamp - the point is the signed-feed pipeline (build -> sign ->
# publish -> container install test), not the payload yet. The real engine
# integration (nfqws2/zapret2 control, kmods, nft rules, init scripts)
# lands in later phases.
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

# NB: cp+chmod, not install(1) - the OpenWrt container busybox has no
# install(1), and this script is smoke-tested there.
W="$work/wanguard-antidpi"
mkdir -p "$W/usr/bin" "$W/usr/share/wanguard-antidpi"
cp "$ROOT/router/wanguard-antidpi" "$W/usr/bin/wanguard-antidpi"
chmod 755 "$W/usr/bin/wanguard-antidpi"
# build stamp: the CI install test asserts it equals the package version
# (and the placeholder CLI reports it); later phases surface it in status.
printf '%s\n' "$VER" > "$W/usr/share/wanguard-antidpi/version"

"$APK" mkpkg -F "$W" \
	-I "name:wanguard-antidpi" \
	-I "version:$VER" \
	-I "arch:x86_64" \
	-I "description:Anti-DPI add-on for OpenWrt: nfqws2 (zapret2) engine scoped to mihomo DIRECT egress" \
	-I "license:MIT" \
	-I "maintainer:sers88" \
	-I "url:https://github.com/sers88/wanguard-antidpi" \
	--compat 3.0.5 \
	-o "$OUT/wanguard-antidpi-$VER.apk"
echo "built $OUT/wanguard-antidpi-$VER.apk"
