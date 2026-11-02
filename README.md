# wanguard-antidpi

**Anti-DPI add-on for OpenWrt routers** - the nfqws2 (zapret2) desynchronization
engine applied only to mihomo DIRECT egress, as a companion to
[wanguard](https://github.com/sers88/wanguard). Traffic already leaving through
the encrypted proxy tunnel is out of scope (excluded by destination address);
the engine sees the packets a DPI middlebox can still inspect.

Status: **phase 1 bootstrap** - the signed apk feed pipeline only. The package
is a placeholder (a stub CLI + build stamp); the real engine integration
(kmods, nft rules, control CLI, init scripts) lands in later phases.

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

## Requirements

- OpenWrt with apk (24.10+/25.x) and mihomo as the proxy core (the add-on
  only ever processes traffic mihomo routes DIRECT)
- kernel NFQUEUE modules for the live engine phases (`kmod-nft-queue`,
  `kmod-nfnetlink-queue`; the feed declares them as dependencies when the
  engine lands)

## License

[MIT](LICENSE)
