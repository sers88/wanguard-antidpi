# Contributing to wanguard-antidpi

## Development flow

All development and testing runs in Docker containers - see the README,
"Development": `scripts/dev-test.sh` runs the full test matrix locally, and
the same scripts are the CI release gate (a red matrix blocks
publication). The router is only touched at final acceptance.

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
in `scripts/fetch-upstream.sh`.
