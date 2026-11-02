# wanguard-antidpi architecture

## 1. Language policy: ucode-first (adopted 2026-11-02, issue #67)

All logic-bearing router-side code is **ucode**. POSIX sh remains only where a
contract forces it or where the code does not run on the router. The
migration lands with the ucode-first base revision (`v1.0.6-r3`); from that
revision on, the package must not carry a POSIX sh CLI.

| Component | Language | Why |
|---|---|---|
| `/usr/bin/wanguard-antidpi` (control CLI) | **ucode** (`router/wanguard-antidpi.uc`) | all logic: engine cmdline render, nft render/apply/flush; future: routing-mark installer (#60), status/diagnostics, ubus/json consumers |
| config | **UCI** (`/etc/config/wanguard-antidpi`) | native `uci.so` bindings (zero forks), real lists (no shell word-split gotchas), LuCI-ready, `uci get/set` for automation |
| `/etc/init.d/wanguard-antidpi` | sh (rc.common contract) | OpenWrt init scripts are sourced by `/etc/rc.common` - sh only; kept as a thin shim, all logic lives in the CLI |
| nft table template | data (`router/wanguard-antidpi.nft`) | rendered by the CLI (`@QNUM@` substitution from UCI) |
| host/CI scripts (`scripts/*.sh`, `apk/build.sh`) | sh | run on the CI runner / dev host, not on the router |
| engine `nfqws2` | upstream binary | never modified; pinned by sha256 |

This mirrors the wanguard core, which completed its full ucode migration
(v1.1.0; evidence: `docs/spike-ucode/VERDICT.md` in the wanguard repo) and
retired sh from its package. Porting traps documented there apply here too
(`export function` broken in the ucode 2026.01.16 module compiler - trailing
`export{}` instead; `popen close()` exit-code form; ucode children spawn via
/bin/sh so PATH stubs keep working in tests; uci stays real on /etc/config).

UCI layout (`/etc/config/wanguard-antidpi`, section `engine`):

| Option | Default | Meaning |
|---|---|---|
| `qnum` | `300` | NFQUEUE number the engine binds (substituted into the nft template) |
| `fwmark` | `0x40000000` | mark nfqws2 stamps on its generated packets |
| `user` | `daemon` | privilege-drop user after queue setup |
| `debug` | `0` | `1` appends `--debug=1` (blockcheck sessions only) |
| `nfqws2_opt` (list) | empty | desync strategy, one argv word per list item (`--new` starts the next profile set); empty = graceful no-op |

## 2. Components

| Component | Role |
|---|---|
| mihomo | proxy core; with `routing-mark 0x10000000` its own DIRECT egress is the add-on's scope (phase 2, issue #60) |
| nftables (`table inet wanguard_antidpi`) | own table: postrouting @ mangle+10, `meta mark 0x10000000 queue flags bypass to <qnum>`; never touches wanguard / fw4 tables (final rule set: #61) |
| nfqws2 (zapret2) | desync engine, single instance, `--qnum=<qnum>`, gzipped lua strategies loaded via `--lua-init=@`; graceful no-op when the strategy is empty |
| wanguard-antidpi (CLI) | single control surface: version, engine-version, engine-cmdline, nft-render/apply/flush; DRYRUN-aware |
| procd init | apply table -> engine instance (respawn 3600 5 0, stdout/stderr to syslog); stop = kill -> flush table |
| apk feed | signed index on the `feed` branch; package built by CI from the sha256-pinned upstream artifact |

## 3. Frozen contracts

- `WANGUARD_ANTIDPI_DRYRUN=1`: every state-changing command prints what it
  would do, touches nothing, exits 0 - this is the container test surface
- `engine-cmdline`: one argv word per line - exactly what the init shim starts
- nft table shape: own `inet wanguard_antidpi` table, postrouting priority
  `mangle + 10`, `queue flags bypass` (fails open if the engine dies)
- marks: `0x10000000` (mihomo scope) and `0x40000000` (nfqws desync)
- versioning: package major = pinned upstream version (`vX.Y.Z` -> `X.Y.Z-r1`);
  package-only fixes ship as explicit revision tags (`vX.Y.Z-rN` -> `X.Y.Z-rN`)

Contract changes are frozen with golden fixtures byte-for-byte (the wanguard
core pattern); the container smoke and the CI gate assert the CLI stays ucode.

## 4. Scope discipline

The add-on owns the lifecycle of its own table and engine; it never edits
wanguard or fw4 state. Traffic already leaving through the proxy tunnel is out
of scope (excluded by destination address, #62); only mihomo DIRECT egress
(with the scope mark) enters the queue.
