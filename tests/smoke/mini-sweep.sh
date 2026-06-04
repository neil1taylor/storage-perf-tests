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

# Validate outputs exist. Trailing slash on the glob restricts the match to
# directories — without it, `results/tune-<id>.checkpoint` files also match
# and may sort newer than the run directory itself.
latest=$(ls -1dt -- results/tune-*/ 2>/dev/null | head -1 | sed 's:/$::')
echo "Latest run: ${latest}"
[[ -d "${latest}" ]] || { echo "FAIL: no tune-* run directory under results/"; exit 1; }

for cfg in default big-osd; do
  for f in qd.csv qd-summary.json tuning-applied.yaml; do
    [[ -s "${latest}/qd-sweep/${POOL}/${cfg}/${f}" ]] || { echo "FAIL: missing ${cfg}/${f}"; exit 1; }
  done
done

ls reports/tune-sweep-${POOL}-*.html >/dev/null \
  || { echo "FAIL: no report HTML"; exit 1; }

echo "PASS: mini-sweep end-to-end"
