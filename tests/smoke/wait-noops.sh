#!/usr/bin/env bash
# tests/smoke/wait-noops.sh — verify wait_for_* return ~immediately when
# the cluster is already in the target state (no patch pending).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

source 00-config.sh
source lib/vm-helpers.sh
source lib/wait-helpers.sh
source lib/tune-helpers.sh

start=$(date +%s)
wait_for_osd_ready 60
elapsed=$(( $(date +%s) - start ))
echo "wait_for_osd_ready completed in ${elapsed}s"
(( elapsed < 30 )) || { echo "FAIL: wait_for_osd_ready slow on quiescent cluster (${elapsed}s)"; exit 1; }

start=$(date +%s)
wait_for_mcp_updated worker 60
elapsed=$(( $(date +%s) - start ))
echo "wait_for_mcp_updated completed in ${elapsed}s"
(( elapsed < 30 )) || { echo "FAIL: wait_for_mcp_updated slow on quiescent cluster (${elapsed}s)"; exit 1; }
