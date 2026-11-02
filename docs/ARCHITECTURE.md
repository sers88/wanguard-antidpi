# wanguard-antidpi architecture

## 1. Language policy: ucode-first (adopted 2026-11-02, issue #67)

All logic-bearing router-side code is **ucode**. POSIX sh remains only where a
contract forces it or where the code does not run on the router. The
migration lands with the ucode-first base revision (`v1.0.6-r3`); from that
revision on, the package must not carry a POSIX sh CLI.

| Component | Language | Why |
|---|---|---|
| `/usr/bin/wanguard-antidpi` (control CLI) | **ucode** (`router/wanguard-antidpi.uc`) | all logic: engine cmdline render, nft render/apply/flush, mihomo routing-mark installer, tunnel resolver updater + its cron schedule, status/diagnostics |
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

Section `tunnel` (soft - missing section/options fall back to defaults; all
options live in this section, issue #62):

| Option | Default | Meaning |
|---|---|---|
| `proxy_servers` (list) | empty | MANUAL static pins: canonical IPv4/CIDR, rendered into the `proxy_servers` set on every apply; never touched by the updater |
| `tunnel_hosts` (list) | empty | tunnel hostnames for the resolver updater (strict DNS names, at least two labels); empty = updater and cron schedule stay no-ops |
| `update_interval` | `6` | hours between periodic updates (cron); `0` = manual updates only |
| `expire_hours` | `24` | hours an IP survives without being seen in DNS answers (`0` = never expire) |
| `proxy_resolved` (list) | empty | MACHINE-MANAGED by `tunnel-update`: current resolver answers plus entries not yet expired; do not edit - static pins go to `proxy_servers` |

## 2. Components

| Component | Role |
|---|---|
| mihomo | proxy core; with `routing-mark 0x10000000` its own DIRECT egress is the add-on's scope (the CLI installs the mark idempotently, #60) |
| nftables (`table inet wanguard_antidpi`) | own table: postrouting @ mangle+10, `meta mark 0x10000000 queue flags bypass to <qnum>`; never touches wanguard / fw4 tables (final rule set: #61) |
| nfqws2 (zapret2) | desync engine, single instance, `--qnum=<qnum>`, gzipped lua strategies loaded via `--lua-init=@`; graceful no-op when the strategy is empty |
| wanguard-antidpi (CLI) | single control surface: version, engine-version, engine-cmdline, nft-render/apply/flush, mark-install/ensure/remove/status, tunnel-update/status, cron-install/remove; DRYRUN-aware |
| resolver updater (#62) | `tunnel-update`: nslookup per `tunnel_hosts` entry, maintains `tunnel.proxy_resolved` in UCI with per-IP expiry (state file), re-applies the table only when the set changed and the table lives |
| procd init | ensure the mihomo mark (non-fatal) -> refresh the tunnel set (non-fatal) -> apply table -> ensure cron line -> engine instance (respawn 3600 5 0, stdout/stderr to syslog); stop = kill -> drop cron line -> flush table |
| apk feed | signed index on the `feed` branch; package built by CI from the sha256-pinned upstream artifact |

## 3. Frozen contracts

- `WANGUARD_ANTIDPI_DRYRUN=1`: every state-changing command prints what it
  would do, touches nothing, exits 0 - this is the container test surface
- `engine-cmdline`: one argv word per line - exactly what the init shim starts
- nft table shape (issue #61, final): own `inet wanguard_antidpi` table,
  postrouting `priority 101` (post-NAT, right after fw4 srcnat), two queue
  rules - `tcp dport 443 ct original packets 1-20` and
  `udp dport 443 ct original packets 1-5` (zapret2 config.default connbytes) -
  each scoped by `meta mark & 0x10000000 == 0x10000000` AND
  `meta mark & @fwmark@ == 0` (desync anti-loop) AND
  `ip daddr != @proxy_servers` AND `ip daddr != @local_v4`, ending in
  `counter` + `queue num <qnum> bypass` (fails open if the engine dies). No
  `oifname` filter: the mark IS the scope. IPv4 only.
- the `proxy_servers` set is RENDERED from the UCI lists on every apply:
  `tunnel.proxy_servers` (manual pins) UNION `tunnel.proxy_resolved`
  (resolver-managed, issue #62), deduped, canonically sorted, every entry
  validated as canonical IPv4/CIDR - never populate the live set with
  `nft add element`: an apply rebuilds the whole table and would wipe
  dynamically added elements (#62 maintains the UCI lists, not the set)
- marks: `0x10000000` (mihomo scope) and `0x40000000` (nfqws desync)
- versioning: package major = pinned upstream version (`vX.Y.Z` -> `X.Y.Z-r1`);
  package-only fixes ship as explicit revision tags (`vX.Y.Z-rN` -> `X.Y.Z-rN`)

## 3.1 mihomo routing-mark integration (#60)

The scope mark `0x10000000` is the add-on's property: nothing else on the
system may claim it (wanguard policy marks live in `0x64..0x258` and match by
exact value, so a new mark cannot disturb policy routing).

Install (`mark-install`, also run by the init shim as the non-fatal
`mark-ensure` on every service start):

1. `/etc/mihomo/config.yaml` missing -> graceful no-op (the whole add-on
   stays inert without mihomo)
2. `routing-mark` root-level line present -> idempotent skip when it equals
   `268435456`; a FOREIGN value is never touched (strict `mark-install`
   exits 1, the init hook only warns)
3. backup -> `config.yaml.bak-wanguard-antidpi` (taken once, never
   overwritten), inject ONE root-level line `routing-mark: 268435456`
   (prepended - root-level key order is free in YAML; the config is never
   rewritten as a whole)
4. validate with the real binary (`mihomo -t`); on failure the inject is
   rolled back from the in-memory pre-inject content
5. mihomo running -> live reload via its REST API: `PUT /configs` with the
   config path under the mihomo workdir (SAFE_PATHS convention - the edited
   config is copied to `<workdir>/config.yaml` first and the copy is kept
   in sync); a plain PUT applies the config and does NOT disturb live
   connections (verified live: connections survive, mihomo logs
   "Initial configuration complete"); `?force=true` is only the fallback
   for cores refusing a plain path reload. `external-controller` and
   `secret` are parsed from the mihomo config itself, the secret travels
   to curl via a temporary header FILE, never through argv. mihomo not
   running -> nothing to reload, it starts with the mark when it comes up

Removal (`mark-remove`): restore the backup (spec default - reverts any
edits made between install and remove; documented) or, without a backup,
surgically drop the injected line; validate + live reload; then arm the
disarm stamp (`/usr/share/wanguard-antidpi/no-mark`) so the init hook stops
re-injecting. apk has no uninstall scripts (verified: apk3 mkpkg rejects
pre/post-uninstall), so `mark-remove` is the documented rollback step.
`mark-status` prints one `key: value` line per fact (mark / install-on-start
/ backup / mihomo / config / api) for tests and future LuCI.

Contract checks live in `scripts/container-smoke.sh` (file mechanics,
idempotency, conflict, DRYRUN, stamp) and `scripts/test-mark.sh` (real
pinned mihomo: `mihomo -t`, start with the mark, live REST reload both
directions).

## 3.2 the scope table (#61)

`table inet wanguard_antidpi` is the add-on's own namespaced table; it never
touches `inet fw4` or `inet wanguard` (its postrouting hook at priority 101
sits between fw4 srcnat (100) and fw4 mangle_postrouting (150), and wanguard
hooks only prerouting). Sets:

- `local_v4` - same membership as the wanguard core's set (RFC1918 +
  broadcast): local/LAN destinations are never desynchronized
- `proxy_servers` - upstream tunnel endpoints; populated by the resolver
  updater (#62) from `tunnel.tunnel_hosts` DNS answers plus manual pins.
  Until the updater has populated the UCI lists, tunnel packets match the
  queue - which is safe only while the engine strategy is empty (graceful
  no-op). Do not enable desync strategies before the exclusion set is
  populated.

Verification contract: `scripts/test-nft.sh` (live, NET_ADMIN container,
real pinned mihomo as the marked traffic source): apply shape, re-apply
byte-identical (idempotent), BYPASS (engine down -> traffic flows, rule
counter ticks), engine bind (traffic flows through the bound queue), scope
negatives (direct and unmarked-mihomo fetches never tick the counters),
flush + re-apply. When the host kernel lacks NFQUEUE the script stays
structural (`NFT-LIVE-SKIP`) and the live matrix is router-acceptance-only.
`scripts/container-smoke.sh` asserts the rendered shape (priority, connbytes,
both exclusions, counters, empty `proxy_servers`, filled-UCI render, merged
manual+resolved render, render-injection rejection) without live state.

Contract changes are frozen with golden fixtures byte-for-byte (the wanguard
core pattern); the container smoke and the CI gate assert the CLI stays ucode.

## 3.3 tunnel exclusion resolver updater (#62)

Scope guarantee: the proxy tunnel is never desynchronized - its destinations
bypass the queue via the `proxy_servers` set. The set is pure render output;
the updater maintains the UCI lists.

Data model:

- input: `tunnel.tunnel_hosts` (hostnames, strict DNS validation - at least
  two labels, 253-octet limit; hostnames go through `sh_quote` before the
  `nslookup` exec and are validated before that, defense in depth)
- output: `tunnel.proxy_resolved` (UCI list, machine-managed) - the union of
  current DNS answers and entries not yet expired
- state: `/usr/share/wanguard-antidpi/tunnel-resolved.state`, one
  `<ip> <epoch>` line per IP (unowned file, survives upgrades; removed
  together with the package on uninstall)

Update algorithm (`tunnel-update`):

1. resolve every host with busybox `nslookup` (both answer shapes parse:
   `Address: ip` and numbered `Address N: ip cname`; the server header line
   is rejected by the strict IPv4 check, CNAME tails are split off; plain A
   answers only - a CIDR cannot come out of DNS)
2. a fresh answer REFRESHES the per-IP timestamp in the state file; the
   tunnel daddr ROTATES (issue #61 router finding: one hostname, different
   answers over time), so accumulation with expiry is the safe semantics -
   per-run replacement would flap the set
3. entries not re-observed within `expire_hours` (`0` = never) drop out of
   both the state file and the UCI list
4. UCI entries missing from the state file are adopted with a fresh
   timestamp (first run after manual UCI edits or state loss)
5. total resolution failure (no host answered) -> exit 1, last known set
   kept byte-for-byte (resilience: a DNS outage must never empty the
   exclusion); per-host failures are tolerated when at least one host
   answers
6. UCI list written only when it really changed (sorted, deduped; native
   `uci.cursor().set` with array value + save/commit; empty result ->
   option deleted; verify-after-write, because ucode uci failures are
   silent; a deleted tunnel section is recreated through the `uci` CLI
   binary - the ucode `cursor.add()` of this build cannot create NAMED
   sections, verified 2026-11-02)
7. the table is re-applied only when the set changed AND the table
   currently lives (no-table guard: a cron run against a stopped service
   saves the fresh list but never recreates the table; a boot-time update
   runs before the init apply, so the first apply already carries the
   fresh answers)

Triggers:

- every service start (init shim, non-fatal: boot-time DNS outages keep the
  persisted list and the cron run heals later)
- periodic: `cron-install` maintains one tagged line
  (`0 */N * * * ... tunnel-update`) in `/etc/crontabs/root` - the only
  foreign-owned file the add-on edits; foreign lines are never touched,
  exactly one tagged line exists, interval changes update it in place,
  `cron-remove` (service stop) drops it. busybox crond reloads changed
  crontab files itself; `update_interval=0` or no hosts -> the line stays
  absent.

Defense in depth (documented for #64): once desync strategies are enabled,
their nfqws2 filters must match only non-tunnel traffic - the nft-level
destination exclusion is the primary control, not the only one. Until the
exclusion set is populated, tunnel packets match the queue - safe only while
the engine strategy is empty (graceful no-op).

Verification contract: `scripts/test-tunnel.sh` (NET_ADMIN container, stub
`nslookup` on PATH - ucode children spawn via /bin/sh, deterministic, no
network): multi-A resolution into the sorted UCI list, idempotency (config
bytes untouched), cross-host dedupe, partial failure, total failure
(exit 1, set kept), per-IP expiry, live apply with a populated set,
update-while-live re-apply, no-table guard, render-injection guard. Without
NFQUEUE in the host kernel the live apply part stays structural
(`TUNNEL-LIVE-SKIP`); the smoke asserts the structural surface (no-hosts
no-ops, DRYRUN forms, `tunnel-status`, cron mechanics with foreign-line
preservation).

## 4. Scope discipline

The add-on owns the lifecycle of its own table and engine; it never edits
wanguard or fw4 state. Traffic already leaving through the proxy tunnel is
out of scope once `proxy_servers` is populated by the updater (#62) - only
mihomo DIRECT egress (with the scope mark) enters the queue.
