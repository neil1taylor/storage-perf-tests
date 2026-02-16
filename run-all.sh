#!/usr/bin/env bash
# =============================================================================
# run-all.sh — Run the full storage performance test pipeline
#
# Executes setup, tests, collection, and reporting in sequence.
# Passes through test flags (--quick, --pool, --overview, --parallel) to
# 04-run-tests.sh and supports pipeline-level options for skipping setup,
# skipping reports, and optional cleanup.
#
# Usage:
#   ./run-all.sh                         # Full pipeline, full test matrix
#   ./run-all.sh --quick                 # Quick smoke test
#   ./run-all.sh --quick --cleanup       # Quick test + clean up VMs/PVCs
#   ./run-all.sh --quick --skip-setup    # Re-run (pools already exist)
#   ./run-all.sh --overview --cleanup-all  # Overview + full cleanup
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"

# ---------------------------------------------------------------------------
# Parse CLI args — separate pipeline flags from passthrough flags
# ---------------------------------------------------------------------------
SKIP_SETUP=false
DO_CLEANUP=""
NO_REPORTS=false
NOTIFY_URL=""
RANK_MODE=false
PASSTHROUGH_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-setup)    SKIP_SETUP=true; shift ;;
    --cleanup)       DO_CLEANUP="--"; shift ;;
    --cleanup-all)   DO_CLEANUP="--all"; shift ;;
    --no-reports)    NO_REPORTS=true; shift ;;
    --notify)        NOTIFY_URL="$2"; shift 2 ;;
    --rank)          RANK_MODE=true; PASSTHROUGH_ARGS+=("$1"); shift ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options (passed through to 04-run-tests.sh):"
      echo "  --quick              Quick smoke test"
      echo "  --pool <name>        Test single pool"
      echo "  --overview           Overview mode"
      echo "  --rank               Rank mode: 3 tests/pool with ranking report"
      echo "  --parallel [N]       Run pools in parallel"
      echo "  --resume <run-id>    Resume an interrupted run"
      echo "  --dry-run            Preview test matrix without running"
      echo "  --filter <pattern>   Only run tests matching pattern"
      echo "  --exclude <pattern>  Skip tests matching pattern"
      echo ""
      echo "Pipeline options:"
      echo "  --skip-setup         Skip storage pool/file/block setup (steps 01-03)"
      echo "  --cleanup            Clean up VMs/PVCs after reports are generated"
      echo "  --cleanup-all        Full cleanup including pools and namespace"
      echo "  --no-reports         Stop after test run (skip collect + report)"
      echo "  --notify <url>       POST JSON summary to webhook on completion (Slack-compatible)"
      exit 0
      ;;
    *)               PASSTHROUGH_ARGS+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------
PIPELINE_START=$(date +%s)
log_info "=========================================="
log_info "Starting Full Pipeline (Run ID: ${RUN_ID})"
log_info "=========================================="

# Steps 01-03: Setup
# Setup scripts may exit non-zero for expected reasons (e.g. EC pools skipped
# due to insufficient hosts, Block CSI absent on bare metal). Log warnings and
# continue — if nothing usable was set up, 04-run-tests.sh will fail clearly.
if [[ "${SKIP_SETUP}" != true ]]; then
  log_info "--- Step 1/6: Setting up ODF storage pools ---"
  bash "${SCRIPT_DIR}/01-setup-storage-pools.sh" || log_warn "Pool setup exited non-zero (some pools may have been skipped) — continuing"

  log_info "--- Step 2/6: Discovering IBM Cloud File CSI ---"
  bash "${SCRIPT_DIR}/02-setup-file-storage.sh" || log_warn "File CSI discovery exited non-zero — continuing"

  log_info "--- Step 3/6: Discovering IBM Cloud Block CSI ---"
  bash "${SCRIPT_DIR}/03-setup-block-storage.sh" || log_warn "Block CSI discovery exited non-zero — continuing"
else
  log_info "Skipping setup steps 01-03 (--skip-setup)"
fi

# Step 04: Run tests
log_info "--- Step 4/6: Running tests ---"
if [[ ${#PASSTHROUGH_ARGS[@]} -gt 0 ]]; then
  bash "${SCRIPT_DIR}/04-run-tests.sh" "${PASSTHROUGH_ARGS[@]}"
else
  bash "${SCRIPT_DIR}/04-run-tests.sh"
fi

# Steps 05-06: Collect + Report
if [[ "${NO_REPORTS}" != true ]]; then
  log_info "--- Step 5/6: Collecting results ---"
  bash "${SCRIPT_DIR}/05-collect-results.sh"

  log_info "--- Step 6/6: Generating reports ---"
  if [[ "${RANK_MODE}" == true ]]; then
    bash "${SCRIPT_DIR}/06-generate-report.sh" --rank
  else
    bash "${SCRIPT_DIR}/06-generate-report.sh"
  fi
else
  log_info "Skipping collect/report steps 05-06 (--no-reports)"
fi

# Step 07: Optional cleanup
if [[ -n "${DO_CLEANUP}" ]]; then
  log_info "--- Cleanup ---"
  if [[ "${DO_CLEANUP}" == "--" ]]; then
    bash "${SCRIPT_DIR}/07-cleanup.sh"
  else
    bash "${SCRIPT_DIR}/07-cleanup.sh" ${DO_CLEANUP}
  fi
fi

PIPELINE_END=$(date +%s)
ELAPSED=$(( PIPELINE_END - PIPELINE_START ))
PIPELINE_STATUS="success"

log_info "=========================================="
log_info "Pipeline Complete (${ELAPSED}s / $(( ELAPSED / 60 ))m)"
log_info "=========================================="

# ---------------------------------------------------------------------------
# Completion notification (webhook)
# ---------------------------------------------------------------------------
if [[ -n "${NOTIFY_URL}" ]]; then
  log_info "Sending completion notification to webhook..."
  local_payload=$(cat <<NOTIFY_EOF
{
  "text": "Storage perf test pipeline complete",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Storage Performance Test Complete*\n*Run ID:* ${RUN_ID}\n*Status:* ${PIPELINE_STATUS}\n*Duration:* ${ELAPSED}s ($(( ELAPSED / 60 ))m)\n*Cluster:* ${CLUSTER_DESCRIPTION}"
      }
    }
  ]
}
NOTIFY_EOF
  )
  curl -s -X POST -H 'Content-Type: application/json' \
    -d "${local_payload}" \
    "${NOTIFY_URL}" >/dev/null 2>&1 || log_warn "Failed to send notification webhook"
fi
