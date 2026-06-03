#!/usr/bin/env bash
# tests/smoke/mini-sweep.sh — end-to-end tune-sweep against a real cluster.
# Two configs × two QDs × 4 VMs. ~30 min on a working cluster. Restore is
# automatic via the orchestrator's EXIT trap.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

POOL="${MINI_SWEEP_POOL:-rep3-virt}"

./09-run-tune-sweep.sh \
  --pool "${POOL}" \
  --configs default,big-osd \
  --fixed-vms 4 \
  --qd-list 1,32 \
  --rate-iops 250 \
  --latency-sla 5 \
  --auto

# Validate outputs exist
latest=$(ls -1dt results/tune-* | head -1)
echo "Latest run: ${latest}"

for cfg in default big-osd; do
  for f in qd.csv qd-summary.json tuning-applied.yaml; do
    [[ -s "${latest}/qd-sweep/${POOL}/${cfg}/${f}" ]] || { echo "FAIL: missing ${cfg}/${f}"; exit 1; }
  done
done

ls reports/tune-sweep-${POOL}-*.html >/dev/null \
  || { echo "FAIL: no report HTML"; exit 1; }

echo "PASS: mini-sweep end-to-end"
