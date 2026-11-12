#!/bin/sh
# apk/build.sh - build the wanguard-antidpi apk packages (file packaging,
# no compilation).
#
# Usage: build.sh <repo-root> <apk.static> <version> <outdir>
#   repo-root   checkout of sers88/wanguard-antidpi (this repo, main branch)
#   apk.static  pinned apk-tools 3.0.7 binary (has the mkpkg applet; the
#               router's 3.0.5 build does not)
#   version     package version, e.g. 0.1.0-r1 (release) or 0.0.0-rN (dev)
#   outdir      where the *.apk files land
#
# Packages (one tag = both packages at the same version, issue #78):
#   wanguard-antidpi            core: static nfqws2 engine + ucode CLI +
#                               procd init + nft template + UCI config
#   luci-app-wanguard-antidpi   LuCI app: menu.d + rpcd ACL + the page
#                               (issue #80). depends are independent both
#                               ways: NOT luci-app-wanguard - the packages
#                               work standalone and together.
#
# The bootstrap stamp (issue #56) remains as the core version file.
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
inst() { cp "$1" "$2"; chmod "$3" "$2"; }

pkg() { # pkg <name> <description> <depends> <stage-dir>
	name="$1"; desc="$2"; deps="$3"; stage="$4"
	"$APK" mkpkg -F "$stage" \
		-I "name:$name" \
		-I "version:$VER" \
		-I "arch:x86_64" \
		-I "description:$desc" \
		-I "license:MIT" \
		-I "maintainer:sers88" \
		-I "url:https://github.com/sers88/wanguard-antidpi" \
		-I "depends:$deps" \
		--compat 3.0.5 \
		-o "$OUT/$name-$VER.apk"
	echo "built $OUT/$name-$VER.apk"
}

# ---- wanguard-antidpi (core) ----
W="$work/wanguard-antidpi"
mkdir -p "$W/usr/bin" "$W/usr/share/wanguard-antidpi/lua" "$W/etc/config" "$W/etc/init.d"
# engine payload (static nfqws2 + gzipped lua strategies, unmodified)
inst "$UP/nfqws2" "$W/usr/bin/nfqws2" 755
inst "$UP/zapret-lib.lua.gz" "$W/usr/share/wanguard-antidpi/lua/zapret-lib.lua.gz" 644
inst "$UP/zapret-antidpi.lua.gz" "$W/usr/share/wanguard-antidpi/lua/zapret-antidpi.lua.gz" 644
# control CLI - ucode, single file (ucode-first base, issue #67; the POSIX sh
# CLI is retired: docs/ARCHITECTURE.md language policy)
inst "$ROOT/router/wanguard-antidpi.uc" "$W/usr/bin/wanguard-antidpi" 755
inst "$ROOT/router/wanguard-antidpi.nft" "$W/usr/share/wanguard-antidpi/wanguard-antidpi.nft" 644
inst "$ROOT/router/init.d/wanguard-antidpi" "$W/etc/init.d/wanguard-antidpi" 755
# UCI config template shipped as the live conffile: apk protects /etc, so a
# user-modified config survives upgrades (new default arrives as
# wanguard-antidpi.apk-new next to it)
inst "$ROOT/router/etc.config.wanguard-antidpi.example" "$W/etc/config/wanguard-antidpi" 644
# build stamp: the CI install test asserts it equals the package version
# (and the CLI reports it); later phases surface it in status.
printf '%s\n' "$VER" > "$W/usr/share/wanguard-antidpi/version"

# kmods from the upstream OpenWrt feed, unpinned (apk resolves the kernel
# version); nftables = the userspace nft binary (present via fw4, declared
# as the contract); ucode interpreter + fs/uci modules for the CLI - declared
# explicitly like the wanguard core does (preinstalled on stock 25.x);
# curl = the REST reload client for the mihomo routing-mark integration (#60)
DEPS="kmod-nft-queue kmod-nfnetlink-queue nftables ucode ucode-mod-fs ucode-mod-uci curl"

pkg wanguard-antidpi \
	"Anti-DPI add-on for OpenWrt: nfqws2 (zapret2) engine scoped to mihomo DIRECT egress" \
	"$DEPS" "$W"

# ---- luci-app-wanguard-antidpi (issues #78/#80) ----
# Menu + ACL + page scaffold. Two menu.d contract
# points proven by tests/test-luci.sh (and spike-75):
#   - the file is named wanguard-antidpi.json so menu.d glob order processes
#     it AFTER luci-app-wanguard.json (the default luci-app-wanguard-antidpi
#     .json name sorts BEFORE it and the placeholder would win, #75 A_default)
#   - the parent node replicates luci-app-wanguard's admin/network/wanguard
#     byte-for-byte EXCEPT depends.acl: it carries OUR group, because the
#     luci-app-wanguard group does not exist when luci-app-wanguard is not
#     installed (standalone mode) and dispatcher apply_tree_acls() would
#     hide the whole menu
L="$work/luci-app-wanguard-antidpi"
mkdir -p "$L/usr/share/luci/menu.d" "$L/usr/share/rpcd/acl.d" \
	"$L/www/luci-static/resources/view/wanguard" \
	"$L/www/luci-static/resources/wanguard-antidpi"
inst "$ROOT/luci-app-wanguard-antidpi/usr/share/luci/menu.d/wanguard-antidpi.json" \
	"$L/usr/share/luci/menu.d/wanguard-antidpi.json" 644
inst "$ROOT/luci-app-wanguard-antidpi/usr/share/rpcd/acl.d/luci-app-wanguard-antidpi.json" \
	"$L/usr/share/rpcd/acl.d/luci-app-wanguard-antidpi.json" 644
# the page (issue #80): view + shared core module. The LuCI loader resolves
# 'require wanguard-antidpi.core' to /www/luci-static/resources/wanguard-antidpi/core.js
inst "$ROOT/luci-app-wanguard-antidpi/htdocs/luci-static/resources/view/wanguard/antidpi.js" \
	"$L/www/luci-static/resources/view/wanguard/antidpi.js" 644
inst "$ROOT/luci-app-wanguard-antidpi/htdocs/luci-static/resources/wanguard-antidpi/core.js" \
	"$L/www/luci-static/resources/wanguard-antidpi/core.js" 644
pkg luci-app-wanguard-antidpi \
	"LuCI app for wanguard-antidpi anti-DPI strategies (WAN Guard > Anti-DPI tab)" \
	"wanguard-antidpi luci-base" "$L"

# tag-guard companion (issue #78): one tag = both packages at the same
# version; CI and the dev stand fail loudly if either is missing.
[ -f "$OUT/wanguard-antidpi-$VER.apk" ] || {
	echo "build.sh: core package missing after build" >&2
	exit 1
}
[ -f "$OUT/luci-app-wanguard-antidpi-$VER.apk" ] || {
	echo "build.sh: luci package missing after build" >&2
	exit 1
}
