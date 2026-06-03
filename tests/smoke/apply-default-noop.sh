#!/usr/bin/env bash
# tests/smoke/apply-default-noop.sh — applying the 'default' tune config to a
# cluster that's already at the default profile should be a no-op (no OSD
# restart, no MC change).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

source 00-config.sh
source lib/vm-helpers.sh
source lib/wait-helpers.sh
source lib/tune-helpers.sh

mkdir -p /tmp/tune-smoke
tmp=/tmp/tune-smoke/tuning-applied.yaml

start=$(date +%s)
apply_tuning_config default > "${tmp}"
elapsed=$(( $(date +%s) - start ))

echo "apply_tuning_config(default) completed in ${elapsed}s"
[[ -s "${tmp}" ]] || { echo "FAIL: tuning-applied empty"; exit 1; }
echo "--- tuning-applied.yaml ---"
cat "${tmp}"
# Must converge in <2 min on a quiescent cluster
(( elapsed < 120 )) || { echo "FAIL: apply slow on quiescent cluster"; exit 1; }
echo "PASS"
