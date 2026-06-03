#!/usr/bin/env bash
# =============================================================================
# 09-run-tune-sweep.sh — config-level orchestrator for the ODF tuning sweep.
# Snapshots cluster state, applies each tune config in turn, runs the qd-sweep
# workload per config, and restores on every exit path.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Args
POOL=""
CONFIGS_CSV=""
FIXED_VMS=""
QD_LIST=""
RATE_IOPS=""
LATENCY_SLA=""
DRY_RUN=false
RESUME_RUN_ID=""
RESTORE_FROM=""
FORCE=false
AUTO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool)         POOL="$2"; shift 2 ;;
    --configs)      CONFIGS_CSV="$2"; shift 2 ;;
    --fixed-vms)    FIXED_VMS="$2"; shift 2 ;;
    --qd-list)      QD_LIST="$2"; shift 2 ;;
    --rate-iops)    RATE_IOPS="$2"; shift 2 ;;
    --latency-sla)  LATENCY_SLA="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --resume)       RESUME_RUN_ID="$2"; shift 2 ;;
    --restore-from) RESTORE_FROM="$2"; shift 2 ;;
    --force)        FORCE=true; shift ;;
    --auto|--yes)   AUTO=true; shift ;;
    --help|-h)
      cat <<USAGE
Usage: $0 --pool <name> [options]

Sweep tunings:
  --configs <csv>         Comma-separated TUNE_CONFIGS names (default: from TUNE_DEFAULT_CONFIGS)
  --fixed-vms <N>         VM population per config (default: TUNE_FIXED_VMS)
  --qd-list <csv>         Queue depths to sweep (default: TUNE_QD_LIST)
  --rate-iops <N>         Per-VM IOPS cap (default: TUNE_RATE_IOPS)
  --latency-sla <ms>      Write-p99 SLA threshold (default: TUNE_LATENCY_SLA_MS)

Lifecycle:
  --dry-run               Print the plan, exit without mutating anything
  --resume <run-id>       Resume a partial sweep
  --restore-from <run-id> Restore cluster from a saved snapshot (no workload)
  --force                 Override the .tune-sweep.lock file
  --auto, --yes           Skip interactive confirmations (multi-AZ proceed prompt)
USAGE
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Sources (config first, then helpers)
source 00-config.sh
source lib/vm-helpers.sh
source lib/wait-helpers.sh
source lib/tune-helpers.sh

# --restore-from short-circuit (no workload, no plan, just restore)
if [[ -n "${RESTORE_FROM}" ]]; then
  snap="${RESULTS_DIR}/${RESTORE_FROM}/cluster-snapshot.yaml"
  [[ -s "${snap}" ]] || { log_error "no snapshot at ${snap}"; exit 1; }
  restore_cluster_state "${snap}"
  exit $?
fi

# Pool required for non-restore invocations
[[ -z "${POOL}" ]] && { echo "Error: --pool is required" >&2; exit 1; }

# Defaults
: "${CONFIGS_CSV:=${TUNE_DEFAULT_CONFIGS}}"
: "${FIXED_VMS:=${TUNE_FIXED_VMS}}"
: "${QD_LIST:=${TUNE_QD_LIST}}"
: "${RATE_IOPS:=${TUNE_RATE_IOPS}}"
: "${LATENCY_SLA:=${TUNE_LATENCY_SLA_MS}}"

IFS=',' read -r -a CONFIGS <<< "${CONFIGS_CSV}"

# Pre-flight: every config must parse
for cfg in "${CONFIGS[@]}"; do
  parse_tune_config "${cfg}" >/dev/null || exit 1
done

# Pool feasibility (best-effort: skip if helper missing or unauthenticated)
if declare -f get_storage_class_for_pool >/dev/null \
   && [[ "${OC_SKIP_CLUSTER_CHECK:-false}" != "true" ]]; then
  get_storage_class_for_pool "${POOL}" >/dev/null 2>&1 \
    || { log_error "pool ${POOL} has no StorageClass; run 01-setup-storage-pools.sh"; exit 1; }
fi

# Plan
print_plan() {
  local n_cfg=${#CONFIGS[@]}
  local qd_count
  qd_count=$(echo "${QD_LIST}" | awk -F',' '{print NF}')
  cat <<EOF

==========================================
Tune-sweep plan
==========================================
  pool:        ${POOL}
  configs:     ${n_cfg} configs (${CONFIGS_CSV})
  fixed-vms:   ${FIXED_VMS}
  qd-list:     ${QD_LIST}  (${qd_count} steps)
  rate-iops:   ${RATE_IOPS} per VM
  latency-SLA: ${LATENCY_SLA} ms write-p99

  Cluster mutations per cfg:
    StorageCluster patch + OSD restart  ≈ 12 min
    MachineConfig + worker MCP reboot   ≈ 30 min (only when cstate flips)

  Per-cfg workload time:
    ${qd_count} QD × (~90s prefill + ~90s measure + ~30s collect) ≈ $((qd_count * 4)) min
==========================================
EOF
}

print_plan

if [[ "${DRY_RUN}" == true ]]; then
  exit 0
fi

# Cluster checks (skipped when sourcing in tests)
if [[ "${OC_SKIP_CLUSTER_CHECK:-false}" != "true" ]]; then
  oc cluster-info &>/dev/null || { log_error "oc not authenticated"; exit 1; }

  if [[ "${CLUSTER_MULTI_AZ:-false}" == "true" && "${AUTO}" != "true" ]]; then
    read -r -p "Multi-AZ cluster detected. Slide methodology was single-zone. Proceed? [y/N] " r
    [[ "${r,,}" == "y" ]] || exit 0
  fi
fi

# Lock
LOCK="${RESULTS_DIR}/.tune-sweep.lock"
if [[ -s "${LOCK}" && "${FORCE}" != "true" ]]; then
  log_error "Another tune-sweep appears to be running:"
  cat "${LOCK}" >&2
  log_error "Use --force to override."
  exit 1
fi
mkdir -p "${RESULTS_DIR}"
cat > "${LOCK}" <<EOF
{"pid": $$, "host": "$(hostname)", "started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF

# Run ID
if [[ -n "${RESUME_RUN_ID}" ]]; then
  RUN_ID="${RESUME_RUN_ID}"
else
  RUN_ID="tune-$(date +%Y%m%d-%H%M%S)"
fi
export RUN_ID

SNAPSHOT="${RESULTS_DIR}/${RUN_ID}/cluster-snapshot.yaml"
mkdir -p "$(dirname "${SNAPSHOT}")"
if [[ ! -s "${SNAPSHOT}" ]]; then
  snapshot_cluster_state "${SNAPSHOT}"
fi

RESTORE_DONE=false
_on_exit() {
  local rc=$?
  rm -f "${LOCK}"
  if [[ "${RESTORE_DONE}" != "true" ]]; then
    log_warn "Tune-sweep exiting (rc=${rc}); restoring cluster from snapshot..."
    restore_cluster_state "${SNAPSHOT}" || \
      log_error "Restore reported issues — verify manually: oc get storagecluster -o yaml"
    RESTORE_DONE=true
  fi
  return $rc
}
trap _on_exit EXIT INT TERM

# Per-cfg helper: is this cfg fully checkpointed?
cfg_complete_in_checkpoint() {
  local cfg="$1"
  local cp="${RESULTS_DIR}/${RUN_ID}.checkpoint"
  [[ -f "${cp}" ]] || return 1
  local qd
  for qd in ${QD_LIST//,/ }; do
    grep -qF "qd-sweep:${POOL}:${cfg}:${qd}" "${cp}" || return 1
  done
  return 0
}

# Sweep loop
for cfg in "${CONFIGS[@]}"; do
  log_info "===== Config: ${cfg} ====="

  if cfg_complete_in_checkpoint "${cfg}"; then
    log_info "  Already complete; skipping"
    continue
  fi

  cfg_dir="${RESULTS_DIR}/${RUN_ID}/qd-sweep/${POOL}/${cfg}"
  mkdir -p "${cfg_dir}"

  apply_tuning_config "${cfg}" > "${cfg_dir}/tuning-applied.yaml" \
    || { log_error "apply failed for ${cfg}"; exit 1; }

  RUN_ID="${RUN_ID}" ./04-run-tests.sh \
    --qd-sweep \
    --pool "${POOL}" \
    --fixed-vms "${FIXED_VMS}" \
    --qd-list "${QD_LIST}" \
    --rate-iops "${RATE_IOPS}" \
    --latency-sla "${LATENCY_SLA}" \
    --tune-cfg-name "${cfg}" \
    || { log_error "Workload failed for ${cfg}"; exit 1; }
done

log_info "All configs complete. Restoring initial cluster state..."
restore_cluster_state "${SNAPSHOT}"
RESTORE_DONE=true

./06-generate-report.sh --compare-tuning \
  --run "${RUN_ID}" \
  --pool "${POOL}" \
  || log_warn "Report generation failed; data preserved in ${RESULTS_DIR}/${RUN_ID}"
