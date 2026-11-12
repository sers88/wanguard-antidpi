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
| nftables (`table inet wanguard_antidpi`) | own table: output `predefrag` @ -401 (engine mark `notrack`, #68) + postrouting @ 101, `meta mark 0x10000000 queue flags bypass to <qnum>`; never touches wanguard / fw4 tables (final rule set: #61, notrack: #68) |
| nfqws2 (zapret2) | desync engine, single instance, `--qnum=<qnum>`, gzipped lua strategies loaded via `--lua-init=@`; graceful no-op when the strategy is empty |
| wanguard-antidpi (CLI) | single control surface: version, engine-version, engine-cmdline, nft-render/apply/flush, mark-install/ensure/remove/status, tunnel-update/status, cron-install/remove, whitelist-refresh/reload, profile/domainlist/policy rendering, status/events/apply (the LuCI page's surfaces); DRYRUN-aware |
| LuCI page (#75-#88) | `luci-app-wanguard-antidpi`: one view (six sub-tabs) over the CLI surfaces and staged UCI; menu.d + rpcd ACL + /www resources (section 7) |
| resolver updater (#62) | `tunnel-update`: nslookup per `tunnel_hosts` entry, maintains `tunnel.proxy_resolved` in UCI with per-IP expiry (state file), re-applies the table only when the set changed and the table lives |
| procd init | ensure the mihomo mark (non-fatal) -> refresh the tunnel set (non-fatal) -> apply table -> ensure cron line -> engine instance (respawn 3600 5 0, stdout/stderr to syslog); stop = kill -> drop cron line -> flush table |
| apk feed | signed index on the `feed` branch; package built by CI from the sha256-pinned upstream artifact |

## 3. Frozen contracts

- `WANGUARD_ANTIDPI_DRYRUN=1`: every state-changing command prints what it
  would do, touches nothing, exits 0 - this is the container test surface
- `engine-cmdline`: one argv word per line - exactly what the init shim starts
- nft table shape (issue #61, final): own `inet wanguard_antidpi` table,
  output `predefrag` @ `priority -401` - `meta mark & @fwmark@ != 0 notrack`
  untracks engine-generated packets BEFORE conntrack: without it a fake in a
  conntrack churn window (DPI RSTs, entry rotation) is confirm-dropped by the
  kernel (`insert_failed` clash -> NF_DROP -> rawsend sendto EPERM, issue #68;
  the same rule ships in upstream zapret2's own firewall setup) - plus the
  postrouting `priority 101` chain (post-NAT, right after fw4 srcnat), two queue
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

Contract checks live in `tests/container-smoke.sh` (file mechanics,
idempotency, conflict, DRYRUN, stamp) and `tests/test-mark.sh` (real
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

Verification contract: `tests/test-nft.sh` (live, NET_ADMIN container,
real pinned mihomo as the marked traffic source): apply shape, re-apply
byte-identical (idempotent), BYPASS (engine down -> traffic flows, rule
counter ticks), engine bind (traffic flows through the bound queue), scope
negatives (direct and unmarked-mihomo fetches never tick the counters),
flush + re-apply. When the host kernel lacks NFQUEUE the script stays
structural (`NFT-LIVE-SKIP`) and the live matrix is router-acceptance-only.
`tests/container-smoke.sh` asserts the rendered shape (priority, connbytes,
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

Defense in depth (implemented in r9, issue #64): once desync strategies are
enabled, their nfqws2 filters must match only non-tunnel traffic - the
nft-level destination exclusion is the primary control, not the only one.
`engine-cmdline` renders `--ipset-exclude-ip=<merged set>` (same validated,
deduped, sorted set as the nft render) whenever the tunnel lists are
populated, so desync never touches tunnel traffic even when a rotated daddr
reaches the queue before the nft set updates. Until the exclusion set is
populated, tunnel packets match the queue - safe only while the engine
strategy is empty (graceful no-op).

Verification contract: `tests/test-tunnel.sh` (NET_ADMIN container, stub
`nslookup` on PATH - ucode children spawn via /bin/sh, deterministic, no
network): multi-A resolution into the sorted UCI list, idempotency (config
bytes untouched), cross-host dedupe, partial failure, total failure
(exit 1, set kept), per-IP expiry, live apply with a populated set,
update-while-live re-apply, no-table guard, render-injection guard. Without
NFQUEUE in the host kernel the live apply part stays structural
(`TUNNEL-LIVE-SKIP`); the smoke asserts the structural surface (no-hosts
no-ops, DRYRUN forms, `tunnel-status`, cron mechanics with foreign-line
preservation).

## 3.4 SNI whitelist (#70)

Scope guarantee: desync is applied ONLY to whitelisted destinations -
everything else passes the queue unmodified. The control surface is the UCI
`whitelist` soft section (same contract as `tunnel`); the engine consumes a
rendered hostlist file.

Data model:

- input: `whitelist.enabled` (`1` = whitelist mode; only the literal `1`
  enables), `whitelist.domains` (strict DNS names, no wildcards - the engine
  matches by suffix with subdomains auto applying)
- output: `/usr/share/wanguard-antidpi/whitelist.hosts` (machine-managed:
  one domain per line, LF, deduped, canonical order, 0644 - the SIGHUP-time
  reload runs under the dropped engine user)
- blanket mode (`enabled=0` or no section): file removed, argv unchanged -
  byte-identical to the pre-#70 golden

Render algorithm (`whitelist-refresh`):

1. validate every domain (strict hostname check - the file is engine-parsed,
   render-injection safety); `enabled=1` with an empty list dies loudly (a
   half-enabled config must not silently fall back to blanket desync)
2. dedupe + sort, one host per line, single trailing LF
3. write + verify-after-write (ucode write failures are silent) + chmod 644
4. whitelist mode off or empty -> the file is removed (idempotent)

Engine argv (`engine-cmdline`): `--hostlist=<file>` is emitted per PROFILE -
before the first strategy word and after every `--new` separator - when
whitelist mode is on AND the strategy list is non-empty (an empty strategy
has nothing to constrain; the default golden stays untouched). The file is a
HARD engine dependency: nfqws2 refuses to start when it is missing, which is
why the init shim refreshes the file BEFORE the engine start - a failed
refresh that keeps the previous file is the soft direction, a truly absent
file fails the start loudly instead of silently desyncing everything.

Engine facts (verified in the container against the pinned binary):
the hostlist binds per profile ("profile N include hostlist"); a missing
hostlist file keeps the engine from starting; an empty file starts fine but
matches nothing (never produced here - see render step 1); there is no mtime
auto-reload, lists are re-read on SIGHUP ("Lists will be reloaded") without
dropping the queue or live connections.

Triggers:

- every service start (init shim, non-fatal, before the engine start)
- content changes: `whitelist-reload` = refresh + SIGHUP to a running
  engine; no running engine -> graceful no-op, applies on next start
- mode switches (enable/disable) require a service restart: the argv changes
  with the mode, and only a restart re-renders it

Verification contract: `tests/container-smoke.sh` asserts the structural
surface (fresh-host status, file render exactness + idempotency, DRYRUN
forms, per-profile argv emission, enabled+empty-strategy golden, garbage
domains dying loudly in both `whitelist-refresh` and `engine-cmdline` with
the file left intact, disable removing the file, pristine state after). The
end-to-end workflow (engine started via the exact shim recipe, then
`whitelist-reload` refreshing + reloading the list under the dropped user)
was verified in the container against the pinned engine.

## 3.5 Policies (#86)

Ordered **match -> action** rules (UCI `config policy`) rendered as the
FIRST engine profile blocks, ahead of the global strategy catch-all; the
first match wins (nfqws2 profile semantics, spike-75 §1.2):

- input: `policy` sections - `priority` (render order, ascending, ties keep
  the section file order), `domainlist` (ref by section name), `proto`
  (tcp/udp/quic tokens -> the block's `--filter-*` + canonical `--payload`),
  `action` (`strategy` | `bypass` | `none`), `profile` (ref for strategy),
  `enabled`; `device_group` is stored and ignored (no client identity in
  the queue)
- render: first block continues the BASE segment (the base words carry no
  filter/desync words - an empty leading segment would count as a
  filterless match-everything profile and win first-match over every
  policy); subsequent blocks and the catch-all join with `--new`
- bypass = filters + hostlist with NO desync words -> the engine passes the
  matched traffic unmodified (verified live: the ClientHello leaves in one
  segment); strategy = proto filters + the referenced profile's desync
  words (the profile's own `--filter-*`/`--payload` words excluded - one
  filter source per block)
- while any block renders, the whitelist binding (#70) is IGNORED (warned):
  the blocks own their per-list hostlists
- files: `/usr/share/wanguard-antidpi/lists/<list>.hosts` per REFERENCED
  list (whitelist-refresh, same dedupe/sort/LF/0644/verify conventions); a
  missing file keeps the engine from starting (#70 contract)
- validation is loud and named (unknown action, missing refs, empty/unknown
  proto); disabled policies skip validation (the profiles spare exit)
- tunnel/proxy exclusions stay above every policy (the nft set and the
  engine `--ipset-exclude-ip` fire first - only mihomo DIRECT eligible)
- no policy sections or all disabled = the pure profiles render (#84)
  byte-identical

Verification contract: `tests/test-policies.sh` - structural render matrix
(block shapes, priority order, none/validation/whitelist-ignored, status
surfaces) plus live NFQUEUE scenarios: the engine starts and serves traffic
on a 2-policy argv, and the send inventory (tcpdump against a local sink)
proves the bypass path passes the ClientHello unmodified while the
catch-all splits it.

## 4. Scope discipline

The add-on owns the lifecycle of its own table and engine; it never edits
wanguard or fw4 state. Traffic already leaving through the proxy tunnel is
out of scope once `proxy_servers` is populated by the updater (#62) - only
mihomo DIRECT egress (with the scope mark) enters the queue.

## 5. Compatibility contract (consolidated, issue #66)

Ownership and the never-touch list in one place (details in the sections
above):

| Artifact | Owner | This add-on |
|---|---|---|
| fwmark `0x10000000` | wanguard-antidpi | the scope mark - mihomo `routing-mark`; installed/removed idempotently (3.1) |
| fwmark `0x40000000` | wanguard-antidpi | nfqws2 strategy mark (`engine.fwmark`) |
| fwmark `0x20000000` | unassigned | reserved for blockcheck2 staging runs: its hardwired `DESYNC_MARK=0x10000000` MUST be patched to a free bit before running (README Tuning) |
| NFQUEUE `300` | wanguard-antidpi | owns (`engine.qnum`) |
| nft table `inet wanguard_antidpi` | wanguard-antidpi | own namespaced table, postrouting @ 101 |
| nft tables `inet wanguard`, `inet fw4` | wanguard core / fw4 | **never written or flushed** (acceptance uninstall audit, #65: both byte-identical before/after) |
| policy routing (`ip rule`) | wanguard core | never touched (audit: identical before/after) |
| `/etc/mihomo/config.yaml` | mihomo | the one foreign file edited: one root-level `routing-mark` line - idempotent, backed up, `mihomo -t`-validated, live-reloaded, restored on remove (3.1) |
| `/etc/crontabs/root` | system | one tagged cron line; foreign lines preserved; dropped on service stop (3.3) |
| `/usr/share/mihomo/config.yaml` | mihomo workdir | kept in sync as the SAFE_PATHS reload copy (3.1); restored in sync on remove |
| `/usr/share/wanguard-antidpi/whitelist.hosts` | wanguard-antidpi | machine-managed engine hostlist (3.4): rendered from UCI, removed when whitelist mode is off |
| `/usr/share/wanguard-antidpi/lists/<sid>.hosts` | wanguard-antidpi | per-policy hostlists (3.5): rendered for every referenced domainlist, same conventions as whitelist.hosts |
| `/usr/share/luci/menu.d/wanguard-antidpi.json` | wanguard-antidpi | own menu nodes (7.1); the file NAME carries the merge-order contract; `luci-app-wanguard.json` (foreign) is never edited - coexistence is by glob-order merge |
| `/usr/share/rpcd/acl.d/luci-app-wanguard-antidpi.json` | wanguard-antidpi | own ACL group `luci-app-wanguard-antidpi` (7.1) |
| `/www/luci-static/resources/{view/wanguard/antidpi.js,wanguard-antidpi/core.js}` | wanguard-antidpi | the page resources (7); the view path differs from the placeholder's on purpose - two apk packages cannot claim one file |

Conflict-safety notes: wanguard core policy marks live in `0x64..0x258` and
match by exact value, so the add-on's marks cannot disturb policy routing;
the add-on's postrouting hook (priority 101) sits between fw4 srcnat (100)
and fw4 mangle_postrouting (150) without altering either. The contract is
one-sided by design: the wanguard core needs no knowledge of this add-on.

## 6. Test matrix = release gate (#63)

Every frozen contract above is verified by `tests/*.sh` scripts that run
byte-identically on the local dev stand (`scripts/dev-test.sh`, Docker) and
in CI; the CI `publish` job (sign + push the `feed` branch) needs every
matrix job green (smoke, mark, nft, tunnel, status, apply, profiles,
policies, events, luci, view-test), so a red matrix means the release is
never published.
Live NFQUEUE scenarios self-gate on the host kernel (`NFT-LIVE-SKIP` /
`TUNNEL-LIVE-SKIP`); on such hosts they are covered by router acceptance
only. Slice map and the known-limitation note: README, "Test matrix =
release gate".

## 7. LuCI web interface (#75-#88)

One LuCI view (`view/wanguard/antidpi.js`) over one shared core module
(`wanguard-antidpi/core.js`; the luci-app-wanguard pattern: the module
factory yields a CLASS, the loader instantiates it, and the instance is a
stateless facade over a module-closure `state`). The page has six
sub-tabs - Overview / Profiles / Policies / Domain lists / Tunnel
protection / Tests & Logs. The browser never touches nft, logread or the
engine process: every router fact comes from the CLI surfaces, and the
core's only innerHTML payloads are static strings from its own tables
(CLI-derived fields ride `E()` text nodes).

### 7.1 Package surface and the menu merge contract (#78/#79)

| File | Content |
|---|---|
| `/usr/share/luci/menu.d/wanguard-antidpi.json` | the `admin/network/wanguard` parent (title/order/action byte-identical to luci-app-wanguard's node, `depends.acl` switched to THIS package's group) + the `admin/network/wanguard/antidpi` child (`action: view wanguard/antidpi`, order 35) |
| `/usr/share/rpcd/acl.d/luci-app-wanguard-antidpi.json` | ACL group `luci-app-wanguard-antidpi`: exec `/usr/bin/wanguard-antidpi`, uci read/write the `wanguard-antidpi` config (read: get/changes; write: add/set/delete/order/apply/confirm/revert), ubus `file` read/exec |
| `/www/luci-static/resources/view/wanguard/antidpi.js` | the view: header, tab bar, chips holder, poll wiring |
| `/www/luci-static/resources/wanguard-antidpi/core.js` | the core module (all logic) |

The menu.d FILE NAME is part of the contract. LuCI merges menu.d files in
glob order, per node and KEY-LEVEL (`node[k] = spec[k]`, no deep merge):
`wanguard-antidpi.json` sorts after `luci-app-wanguard.json`, so with both
packages installed our parent node wins every key it carries and our
child node (the real page) replaces the placeholder's child wholesale.
The placeholder package keeps a DISTINCT view path on purpose - two apk
packages cannot claim the same /www file. Standalone (core + this
package, no luci-app-wanguard): the replicated parent provides the WAN
Guard menu, and the ACL switch is not cosmetic - the dispatcher gates
EVERY node carrying `depends.acl` in a separate `apply_tree_acls()` pass
by the session's access groups (`check_depends()` during tree building
only evaluates fs/uci depends). A parent pinned to the foreign
`luci-app-wanguard` group would hide the whole subtree in standalone
mode, because that ACL group only exists when luci-app-wanguard is
installed - hence the own group on both nodes.

Guards (`tests/test-luci.sh`, harness `tests/luci-menu-test.uc`): the
harness replicates `build_pagetree` / `check_acl_depends` /
`apply_tree_acls` of the INSTALLED dispatcher verbatim, with pinned
dispatcher lines (`tests/luci-dispatcher-lines.txt`) guarding against
dispatcher drift; the parent node is compared against a byte-snapshot
fixture of luci-app-wanguard's menu (`tests/fixtures/`), child
completeness and sort order are probed for BOTH the winning name and the
losing default package-derived name, and the merged / standalone /
read-only / ACL-negative trees plus the live 3-combination install
matrix (antidpi-only -> both -> wanguard-only after `apk del`) are
exercised. `tests/luci/run-tests.js` covers the view code itself
(below).

### 7.2 UI <-> CLI contract (#76/#77)

Per poll tick (and on load) the page issues exactly ONE
`wanguard-antidpi status --json` exec, plus `engine-cmdline` for the
strategy words. The heavier surfaces run strictly on demand behind
buttons: `apply --check --json` (validation card), `apply --json`
(Review & Apply), `events --json` (log fetch). Router-side rules:

- the status document has stable keys - service, engine (pid, version,
  profiles, hostlists, policies, `profile_sections`, `policy_sections`),
  nft (table_present + counters), tunnel, whitelist, mihomo, pending
  (count + sections), events, degraded. Every unavailable surface
  degrades explicitly (null data + a `degraded` map entry) instead of
  failing, and the page renders its unavailable states from the same
  keys;
- an exec failure or a non-status document = the page's
  "unavailable - update the package" state with muted chips; recovery
  happens in the poll loop without a reload;
- the page never restarts or signals services itself: Review & Apply
  calls the idempotent `apply`, whose engine step decides
  restart-vs-SIGHUP from evidence - hostlist CONTENT changes re-read on
  SIGHUP (queue and live connections untouched, #70), argv drift
  (strategy words, policy blocks, filters, the debug flag) restarts
  through the init script. Exit codes 0 ok / 1 validation failure /
  2 partial (a non-fatal step kept a fallback) map to the ok / FAILED /
  PARTIAL notifications.

### 7.3 Staged-UCI editing model (#81-#85)

Editors never write committed config directly. Each tab stages changes
client-side through the uci client (add/set/delete/move scoped to the
`wanguard-antidpi` config); nothing reaches the router until the pending
bar (or a tab's Apply card) runs the pipeline

    uci.save()  ->  uci.apply(5)  ->  wanguard-antidpi apply --json

`uci.save()` is REQUIRED before the CLI call: the CLI renders committed
config only - a staged `/tmp/.uci` delta is invisible to the ucode
cursor (container-verified). `uci.apply(5)` is the luci-app-wanguard
idiom (rollback window + client-driven confirm). Discard = rpcd
`uci revert` scoped to THIS config (the ACL grants it; the LuCI uci
client has no revert wrapper). Inline validation mirrors the CLI render
rules (strict DNS hostnames, strict IPv4/CIDR pins, one strategy word
per line, whitespace never stages) - invalid input is rejected before
staging, so the render-loud-fail contracts (#61/#70) are unreachable
from the UI. A busy tick skips the poll rebuild entirely (an in-flight
apply must not race its own rebuild); after a config-change cycle the
next update() rebuilds the open editor tab once (its after-config render
would otherwise run on the stale status document).

Apply badges are honest per field: edits that change the engine argv
(strategy words, enabled flips, order, policy refs/actions/protocols,
the debug flag) are labelled "apply restarts the engine"; metadata-only
edits (profile name/color, policy name/device_group) say so;
domain-list content edits say "applies via reload - live connections
stay up".

### 7.4 UCI schema (#82/#84/#86)

Named sections in `/etc/config/wanguard-antidpi`; the section name is
the stable id referenced by the render and by other sections:

    config profile              # one engine --new block (#84)
        option name             # display name
        option proto            # tcp/udp/quic tokens (UI metadata)
        option enabled          # '0' skips the section on the render
        option color            # UI identity only
        list strategy_words     # ONE nfqws2 argv word per item

    config domainlist           # SNI list (#82)
        option name             # display name
        list domains            # strict DNS names; feeds the hostlist
                                # pipeline (merged with the legacy
                                # whitelist.domains; a policy-referenced
                                # list renders to lists/<sid>.hosts)

    config policy               # match -> action rule (#86)
        option priority         # ascending, step-10 convention (UI-owned)
        option domainlist       # ref by section name
        option proto            # the block's --filter-*/--payload source
        option action           # strategy | bypass | none
        option profile          # ref for strategy (by section name)
        option enabled
        option device_group     # STAGED-FUTURE (7.5): stored, ignored

Legacy coexistence: while NO profile section exists, the engine argv
renders verbatim from `engine.nfqws2_opt` (the pre-#84 golden); once
profile sections exist, the legacy list is IGNORED (warned on every
render) and the UI offers a one-click adopt. Whitelist (#70) merges into
the same hostlist pipeline as the named domainlists; while any policy
block renders, the whitelist binding is IGNORED (warned) - the blocks
carry their own per-list hostlists (3.5). Render algorithms and
validation contracts in 3.4/3.5 apply unchanged; profiles add the
`--new` block grammar (the FIRST block continues the base argv segment -
a leading empty segment would render a filterless match-everything
profile and win first-match over every policy).

### 7.5 device_group is staged-future

`policy.device_group` round-trips through the UI (badged "staged
future") but is ignored by the render: the NFQUEUE path carries no
client identity, so per-device desync targeting has no enforcement
point. Nothing in the pipeline depends on it, and per-device desync
should not be expected until the queue path learns client identity.

Verification contract: `tests/luci/run-tests.js` - the real view + core
evaluated in node with stubbed LuCI globals (`view` / `poll` / `rpc` /
`uci` / `ui` / `E` / `L` / `_`), covering every sub-tab (staging never
happens on invalid input, honest badges, poll ticks never rebuild editor
tabs, degraded surfaces stay alive; CI `view-test` = the same command in
the same node:24 container as dev-test step 13), plus the structural
pins in `tests/test-luci.sh` (menu/ACL blocks above) and the CLI-side
matrices for the surfaces the page consumes (status-test, apply-test,
profiles-test, policies-test, events-test).
