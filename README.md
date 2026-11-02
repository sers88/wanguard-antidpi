# wanguard-antidpi

**Anti-DPI add-on for OpenWrt routers** - the nfqws2 (zapret2) desynchronization
engine applied only to mihomo DIRECT egress, as a companion to
[wanguard](https://github.com/sers88/wanguard). Traffic already leaving through
the encrypted proxy tunnel is out of scope (excluded by destination address);
the engine sees the packets a DPI middlebox can still inspect.

Status: **phase 1** - signed apk feed pipeline plus the real engine payload:
static nfqws2 (pinned upstream zapret2 release) + lua strategies + own procd
init + config. Scope integration (mihomo `routing-mark` install, the final
nft rule set, tunnel exclusion) lands in phase 2.

**Language policy: ucode-first** (issue #67) - all router-side logic lives in
a ucode CLI over a UCI config (`/etc/config/wanguard-antidpi`); POSIX sh
remains only for the thin init shim (rc.common contract) and host/CI
tooling. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); the migration
lands with the next package revision.

## Design constants

Published up front (they appear in nft rules and diagnostics; not secrets):

| Constant | Value | Meaning |
|---|---|---|
| Routing mark (mihomo scope) | `0x10000000` | set via mihomo `routing-mark`; only this traffic enters the add-on |
| DESYNC_MARK | `0x40000000` / `0x20000000` | nfqws per-packet strategy marks |
| NFQUEUE number | `300` | bypass queue for desynchronized packets |
| nft table | `inet wanguard_antidpi` | own table; never touches wanguard / fw4 tables |

## Installation

### Via the signed apk feed

The feed is published by CI to the [`feed`](https://github.com/sers88/wanguard-antidpi/tree/feed)
branch on a `vX.Y.Z` tag push (packages get version `X.Y.Z-r1`). The
`packages.adb` index is signed with an EC key; the public key is
[`keys/wanguard-antidpi.pem`](keys/wanguard-antidpi.pem).

On the router (OpenWrt 24.10+/25.x, apk 3.0.x):

```sh
# 1. trust the feed key
curl -o /etc/apk/keys/wanguard-antidpi.pem \
  https://raw.githubusercontent.com/sers88/wanguard-antidpi/feed/keys/wanguard-antidpi.pem

# 2. add the feed
echo "https://raw.githubusercontent.com/sers88/wanguard-antidpi/feed/packages/x86_64/packages.adb" \
  >> /etc/apk/repositories.d/customfeeds.list

# 3. install
apk update
apk add wanguard-antidpi
```

## Package contents

| Path | What |
|---|---|
| `/usr/bin/nfqws2` | static desync engine from the pinned upstream zapret2 release (shipped unmodified) |
| `/usr/bin/wanguard-antidpi` | control CLI (**ucode**, `router/wanguard-antidpi.uc`): version, engine command line, nft render/apply/flush (all state-changing commands are DRYRUN-aware) |
| `/usr/share/wanguard-antidpi/lua/zapret-lib.lua.gz` | upstream lua library (gzipped lua is supported natively by nfqws2) |
| `/usr/share/wanguard-antidpi/lua/zapret-antidpi.lua.gz` | upstream desync strategy functions |
| `/usr/share/wanguard-antidpi/wanguard-antidpi.nft` | scope table template (`@QNUM@` rendered from the config by `nft-render`) |
| `/usr/share/wanguard-antidpi/version` | package version stamp |
| `/etc/config/wanguard-antidpi` | UCI config template (source of truth; apk-protected: user edits survive upgrades) |
| `/etc/init.d/wanguard-antidpi` | procd init (thin sh shim - the rc.common contract): apply own nft table -> engine instance (respawn on crash); stop = kill -> flush table |

Upstream pinning (issue #57): the engine payload comes from the
`bol-van/zapret2` `openwrt-embedded` release artifact, downloaded at build
time by `scripts/fetch-upstream.sh` and verified against two pinned sha256
values - the artifact itself and the canonical
`binaries/linux-x86_64/nfqws2` hash from the upstream `sha256sum.txt`.
Nothing else from the artifact is packaged: the add-on owns the lifecycle
(its own init/nft/config); upstream's installer, init scripts and firewall
mechanics are not used. `ip2net`/`mdig` and `zapret-auto.lua.gz` are deferred
until the hostlist/autohostlist phase.

The package major version tracks the upstream engine version: release tag
`v1.0.6` produces package `1.0.6-r1` (CI fails a tag that does not equal the
pinned `ZAPRET2_VERSION_DEFAULT`). Package-only fixes (without an upstream
bump) ship as an explicit revision tag: `v1.0.6-r2` produces `1.0.6-r2`.
Engine lifecycle notes:

- graceful no-op: with the strategy list empty (`nfqws2_opt`, the default until
  blockcheck tuning) the engine starts, binds the queue and passes packets
  unmodified; without mihomo running, no packet carries the scope mark, the
  queue stays empty (`bypass`), and the init logs a hint to logread
- `bypass` queue semantics: if the engine dies, marked packets leave
  unprocessed instead of dropping (procd respawns it meanwhile)
- DRYRUN contract: `WANGUARD_ANTIDPI_DRYRUN=1` makes the init/CLI print
  actions without touching live state - this is what the container test
  matrix exercises

Note on licensing: this repository's own code is MIT. The upstream engine
zapret2 does not declare a license; its binary and lua strategies are
redistributed here unmodified, pinned by sha256.

## Development

All development and testing runs in Docker containers - the same
`openwrt/rootfs:x86_64-25.12.6` image CI uses; the router is only touched at
final acceptance. One command from zero to smoke:

```sh
sh scripts/dev-test.sh            # kernel probe -> local build -> install + smoke
sh scripts/dev-build.sh 0.1.2-r1  # build only -> out/*.apk
sh scripts/kernel-probe.sh        # NFQUEUE capability probe only
```

On Windows run these from the **Git Bash** shell (the scripts are POSIX sh;
outside Git Bash, `bash` may resolve to WSL and `sh` may not be on PATH - the
scripts handle Git Bash path-mangling quirks themselves).

What runs where:

- `scripts/dev-build.sh` - fetches the pinned upstream engine payload
  (`scripts/fetch-upstream.sh`, sha256-pinned) and the pinned `apk.static`
  (same pins as CI), then builds `out/*.apk` inside the container. Packages
  are intentionally unsigned; the feed index signature is what routers
  verify.
- `scripts/kernel-probe.sh` - tries an `nft ... queue num 300 bypass` rule in
  a container. Containers use the **host kernel** (on Windows: the Docker
  Desktop / WSL2 VM kernel), so the verdict describes the machine, not the
  image: `NFQUEUE-OK` means live packet scenarios are testable in containers
  here; `NFQUEUE-UNAVAILABLE` (never fatal) means container tests stay
  structural/dry-run and live desync scenarios are validated only at router
  acceptance.
- `scripts/container-smoke.sh` - install + smoke assertions inside the
  container, two modes: `local` (untrusted install of `out/*.apk`, used by
  `dev-test.sh`) and `feed` (signed feed install, used by CI `feed-test`).
  One script for both modes, so local and CI results are comparable by
  construction.
- `scripts/dev-test.sh` - probe, build, fresh-container install + smoke in one
  command; exits non-zero on failure.

The smoke set grows into the full container test matrix (mihomo integration,
nft idempotency, resolver updater) in later phases.

## Requirements

- OpenWrt with apk (24.10+/25.x) and mihomo as the proxy core (the add-on
  only ever processes traffic mihomo routes DIRECT)
- kernel NFQUEUE modules for the live engine phases (`kmod-nft-queue`,
  `kmod-nfnetlink-queue`) - declared as package dependencies, pulled from
  the upstream OpenWrt feed unpinned; the nftables userspace is declared too
  (present via fw4 on stock 25.x)
- ucode + `ucode-mod-fs` + `ucode-mod-uci` for the control CLI (from the
  ucode-first base revision onward, issue #67; preinstalled on stock 25.x,
  declared as dependencies like the wanguard core does)

## License

[MIT](LICENSE)
