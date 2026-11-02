#!/bin/sh
# scripts/kernel-probe.sh - probe whether the kernel running the dev containers
# supports nftables + NFQUEUE (issue #59, first step of the dev stand). The
# container uses the HOST kernel (on Windows: the Docker Desktop / WSL2 VM
# kernel), so the verdict is a property of the machine, not of the image.
#
# Prints NFQUEUE-OK or NFQUEUE-UNAVAILABLE and exits 0 on either verdict;
# only docker/infra failures exit non-zero. If unavailable, live packet
# scenarios stay router-acceptance-only and container tests stay structural.
set -eu

IMAGE="${IMAGE:-openwrt/rootfs:x86_64-25.12.6}"

docker version >/dev/null 2>&1 || {
	echo "ERROR: docker is not reachable (start Docker Desktop first)" >&2
	exit 1
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if ! docker run --rm -i --cap-add NET_ADMIN "$IMAGE" sh -s >"$tmp" 2>&1 <<'PROBE'
set -u
echo "== kernel: $(uname -r)"
echo "== installing nftables"
apk -q add nftables || { echo "PROBE-ERROR: apk add nftables failed"; exit 0; }
command -v nft >/dev/null || { echo "PROBE-ERROR: nft missing after install"; exit 0; }
if ! nft add table inet devprobe 2>&1; then
	echo "NFQUEUE-UNAVAILABLE (nft table rejected - kernel lacks nftables)"
	exit 0
fi
nft add chain inet devprobe prerouting '{ type filter hook prerouting priority -140; }' 2>&1
if nft add rule inet devprobe prerouting ip daddr 1.1.1.1 counter queue num 300 bypass 2>&1; then
	echo "NFQUEUE-OK"
else
	echo "NFQUEUE-UNAVAILABLE (queue rule rejected - kernel lacks nfnetlink_queue)"
fi
nft delete table inet devprobe 2>/dev/null || true
PROBE
then
	cat "$tmp"
	echo "PROBE-ERROR: docker run failed" >&2
	exit 1
fi
cat "$tmp"

if grep -q '^NFQUEUE-OK' "$tmp"; then
	echo "VERDICT: NFQUEUE-OK (live packet scenarios testable in containers here)"
	exit 0
fi
if grep -q '^NFQUEUE-UNAVAILABLE' "$tmp"; then
	echo "VERDICT: NFQUEUE-UNAVAILABLE (container tests stay structural/dry-run; live NFQUEUE scenarios are router acceptance only)"
	exit 0
fi
echo "PROBE-ERROR: no verdict line produced" >&2
exit 1
