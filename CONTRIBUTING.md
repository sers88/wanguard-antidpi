# Contributing to wanguard-antidpi

## Development flow

All development and testing runs in Docker containers - see the README,
"Development": `scripts/dev-test.sh` runs the full test matrix locally, and
the same scripts are the CI release gate (a red matrix blocks
publication). The router is only touched at final acceptance.

CI triggers are `v*` tags and manual dispatch only - a docs-only push
runs no CI. To validate a docs (or any non-tag) branch, dispatch the
workflow on the ref: `gh workflow run feed.yml --ref <branch>`; the
publish job stays gated behind the tag check and never touches the live
feed from a branch run.

## View tests (LuCI pages, issue #89)

`tests/luci/run-tests.js` (plain `node`, no router, no LuCI) evaluates the
REAL page code - the shared core module and the view from the package -
with stubbed LuCI globals (`view` / `poll` / `rpc` / `uci` / `ui` / `E` /
`L` / `_`). CI's `view-test` job runs the same file in the same
`node:24` container as `scripts/dev-test.sh` step 13, so local and CI
results match by construction. Conventions that keep the harness
faithful to the real page:

- the status-document stub is built DYNAMICALLY from the committed UCI
  store of the stub server - a hand-built mutable document breaks the
  apply-cycle timing (the page rebuilds editor tabs from the fresh
  document after each apply);
- the `uci` stub mirrors the LuCI client semantics the editors rely on:
  staged creates/changes/deletes/reorders, `save()` flush, `apply()`
  commit, plus per-suite instrumentation (`_saves`, `_applyCalls`,
  an `_applyImpl` hook for rollback scenarios);
- the `E()` stub skips `null`/`false` children exactly like the real
  LuCI dom (views rely on it);
- suites find buttons by EXACT rendered text and re-query the DOM after
  every action - re-renders replace the nodes.

### Adding a sub-tab

1. **CLI first**: if the tab needs new router data, extend the CLI
   surfaces (`status` / `apply` / `events`) and their container matrices
   before the UI - the browser never invents values; every element shows
   CLI data or an explicit unavailable / not-tested state.
2. **Core**: a `renderX` / `buildXView` pair, the tab id in `TABS` and
   `tabLabel`, the facade export, and an `xAfterConfigChange` reset hook
   wired into the apply/discard cycle. Remember the ucode rule if you
   touch the CLI: helpers must be declared before use across the whole
   file (no cross-file hoisting).
3. **Tests**: a suite in `tests/luci/run-tests.js` (happy path, staging
   validation, honest badges, degradation), structural pins in
   `tests/test-luci.sh` block [8] when new file surfaces appear.
4. **Docs**: the tab row + behavior in the README, the contract in
   `docs/ARCHITECTURE.md` section 7.

## Commit convention

Commit messages follow the convention shared across the wanguard projects:

- `impl(N): <summary>` - a new capability for planning issue N
- `fix(N): <summary>` - a defect fix for planning issue N

N references the planning tracker's issue for the change; releases are git
tags: `vX.Y.Z` (upstream engine bump) or `vX.Y.Z-rN` (package-only fix).
A tag push triggers the CI matrix and, on green, the signed feed
publication - see README, "Updating the upstream engine".

## Issues

This repository's issue tracker is for **external reports only**:
installation problems, packaging defects, engine crashes. Roadmap and
feature planning live in the maintainer's private tracker. Please open an
issue that describes the observable problem (what you ran, what happened,
what you expected) rather than a proposed design.

## Diagnostics hygiene

When attaching logs, configs or `nft list` output to an issue:

- scope nft dumps to the `wanguard_antidpi` table (it carries no private
  data - CIDR sets and counters); do not post full `nft list ruleset` from
  a production router;
- redact public IP addresses, tunnel hostnames/endpoints, provider names
  and your `nfqws2_opt` strategy before posting - a working strategy
  fingerprints your provider setup;
- a mihomo config contains the proxy secret and server credentials - post
  only the single `routing-mark:` line if the integration is relevant;
- the same secrets-free rules the wanguard core applies to its
  diagnostic-report artifacts.

## License

By contributing you agree that your contributions are licensed under this
repository's MIT license. Upstream engine artifacts (the nfqws2 binary and
lua strategies) are never modified by hand - they are pinned byte-for-byte
in `scripts/fetch-upstream.sh`, and pin bumps arrive as automated
upstream-watch PRs (a scheduled workflow compares the pin with the latest
upstream release; humans review, merge and tag).
