#!/usr/bin/env bash
#
# Scale-test wrapper that applies a TUNE_CONFIG before ramping VM count,
# then restores cluster state on every exit path. Mirrors 09-run-tune-sweep.sh's
# snapshot → apply → run → restore harness, but invokes --scale-test instead of
# --qd-sweep.
#
# Usage:
#   ./10-run-scale-test-tuned.sh --pool <name> --tune-cfg <cfg>
#         [--rate-iops N] [--latency-sla N] [--max-vms N] [--auto]
#         [--resume <run-id>]
#
# Defaults: --rate-iops 0 (uncapped), --latency-sla 9999 (SLA-disabled, ramp
# walks the full VM ladder until VM creation fails or SCALE_MAX_VMS hit).
#
# --resume <run-id>: pick up an interrupted run. Reuses the original snapshot
# (the tune patch stays applied; we do NOT re-apply or re-snapshot), runs
# 04-run-tests.sh against the same scale-results dir, then stitches the
# partial ramp.csv together with the prior step dirs so the final CSV /
# summary / HTML cover the full ladder. Pair with SCALE_PHASE1_START=<N>
# (env) to skip already-completed Phase 1 steps.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

POOL=""
TUNE_CFG=""
RATE_IOPS=0
LATENCY_SLA=9999
MAX_VMS=""
AUTO=false
RESUME_RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool)        POOL="$2"; shift 2 ;;
    --tune-cfg)    TUNE_CFG="$2"; shift 2 ;;
    --rate-iops)   RATE_IOPS="$2"; shift 2 ;;
    --latency-sla) LATENCY_SLA="$2"; shift 2 ;;
    --max-vms)     MAX_VMS="$2"; shift 2 ;;
    --auto)        AUTO=true; shift ;;
    --resume)      RESUME_RUN_ID="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,21p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "${POOL}" ]]     && { echo "ERROR: --pool required" >&2; exit 1; }
[[ -z "${TUNE_CFG}" ]] && { echo "ERROR: --tune-cfg required" >&2; exit 1; }

source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"
source "${SCRIPT_DIR}/lib/tune-helpers.sh"
source "${SCRIPT_DIR}/lib/report-helpers.sh"

if [[ -z "${TUNE_CONFIGS[$TUNE_CFG]+x}" ]]; then
  echo "ERROR: unknown tune config '${TUNE_CFG}'. Known: ${!TUNE_CONFIGS[@]}" >&2
  exit 1
fi

if [[ -n "${RESUME_RUN_ID}" ]]; then
  RUN_ID="${RESUME_RUN_ID}"
  SNAPSHOT="${RESULTS_DIR}/${RUN_ID}/cluster-snapshot.yaml"
  [[ -f "${SNAPSHOT}" ]] || { echo "ERROR: snapshot not found at ${SNAPSHOT}" >&2; exit 1; }
  log_info "===== Resuming run ${RUN_ID}; reusing existing snapshot, skipping tuning apply ====="
else
  RUN_ID="scale-tuned-$(date +%Y%m%d-%H%M%S)"
  SNAPSHOT="${RESULTS_DIR}/${RUN_ID}/cluster-snapshot.yaml"
  mkdir -p "$(dirname "${SNAPSHOT}")"
  snapshot_cluster_state "${SNAPSHOT}"
fi
export RUN_ID

RESTORE_DONE=false
_on_exit() {
  local rc=$?
  if [[ "${RESTORE_DONE}" != "true" ]]; then
    log_warn "Exit (rc=${rc}); restoring cluster from snapshot..."
    restore_cluster_state "${SNAPSHOT}" || log_error "Restore reported issues; verify manually"
    RESTORE_DONE=true
  fi
  return $rc
}
trap _on_exit EXIT INT TERM

if [[ -z "${RESUME_RUN_ID}" ]]; then
  log_info "===== Applying tune config: ${TUNE_CFG} ====="
  cfg_dir="${RESULTS_DIR}/${RUN_ID}"
  apply_tuning_config "${TUNE_CFG}" > "${cfg_dir}/tuning-applied.yaml" \
    || { log_error "apply failed for ${TUNE_CFG}"; exit 1; }
fi

log_info "===== Running scale-test on pool=${POOL} tune=${TUNE_CFG} rate=${RATE_IOPS} sla=${LATENCY_SLA}ms ====="
[[ -n "${MAX_VMS}" ]] && export SCALE_MAX_VMS="${MAX_VMS}"

RUN_ID="${RUN_ID}" ./04-run-tests.sh \
  --scale-test \
  --pool "${POOL}" \
  --rate-iops "${RATE_IOPS}" \
  --latency-sla "${LATENCY_SLA}" \
  || { log_error "scale-test failed"; exit 1; }

# ─── Stitch the full ramp when resuming a partial run ───
# 04-run-tests.sh only writes rows for the steps it actually executes. When
# resuming, the prior steps' per-VM fio JSONs are still on disk; rebuild the
# unified CSV / summary / HTML before letting the EXIT trap restore the cluster.
if [[ -n "${RESUME_RUN_ID}" ]]; then
  log_info "===== Stitching full ramp from prior step dirs ====="
  scale_results_dir="${RESULTS_DIR}/scale-test/${POOL}"
  ramp_csv="${scale_results_dir}/ramp.csv"
  ramp_summary="${scale_results_dir}/ramp-summary.json"

  if [[ ! -d "${scale_results_dir}" ]]; then
    log_error "Scale results dir not found: ${scale_results_dir} — skipping stitch"
  else
    # Anchor: only step dirs touched at or after the original snapshot file
    # belong to this run.
    snapshot_mtime_epoch=$(stat -f '%m' "${SNAPSHOT}" 2>/dev/null || stat -c '%Y' "${SNAPSHOT}")

    declare -a step_dirs=()
    while IFS= read -r d; do
      newest_json=$(find "${d}" -maxdepth 1 -name '*-fio.json' -type f \
        -exec stat -f '%m %N' {} \; 2>/dev/null \
        | sort -nr | head -1 | awk '{print $1}')
      if [[ -z "${newest_json}" ]]; then
        # Fall back to GNU stat (Linux) syntax — harmless on macOS if first form
        # succeeded. The `|| true` keeps the substitution clean when BSD find
        # (macOS) rejects `-printf`; with pipefail+set -e the unswallowed
        # non-zero exit would propagate out of the assignment.
        newest_json=$( (find "${d}" -maxdepth 1 -name '*-fio.json' -type f \
          -printf '%T@ %p\n' 2>/dev/null || true) | sort -nr | head -1 | awk '{print $1}')
      fi
      [[ -z "${newest_json}" ]] && continue
      # Note: avoid bare `(( ... ))` here — with `set -e` an expression that
      # evaluates to 0 (i.e. false) exits 1 and kills the wrapper. Use `if`
      # so the truthiness is consumed properly.
      if [[ "${newest_json%.*}" -ge "${snapshot_mtime_epoch}" ]]; then
        step_dirs+=("${d}")
      fi
    done < <(find "${scale_results_dir}" -mindepth 1 -maxdepth 1 -type d -name 'step-*-vms' | sort)

    if [[ "${#step_dirs[@]}" -eq 0 ]]; then
      log_error "No step dirs match this run's snapshot mtime — nothing to stitch"
    else
      log_info "Stitching ${#step_dirs[@]} step dirs into ${ramp_csv}"

      _extract_step_metrics() {
        local step_dir="$1" vm_count="$2" rate="$3" sla="$4"
        local total_r=0 total_w=0 total_bw_kib=0
        local max_p99_ns=0 sum_p50_ns=0 sum_p95_ns=0 n=0
        while read -r f; do
          local stats
          stats=$(jq -r '[
            (.jobs[0].read.iops // 0 | floor),
            (.jobs[0].write.iops // 0 | floor),
            ((.jobs[0].read.bw_bytes // 0) + (.jobs[0].write.bw_bytes // 0) | floor),
            (.jobs[0].write.clat_ns.percentile["50.000000"] // 0 | floor),
            (.jobs[0].write.clat_ns.percentile["95.000000"] // 0 | floor),
            (.jobs[0].write.clat_ns.percentile["99.000000"] // 0 | floor)
          ] | @tsv' "${f}" 2>/dev/null || echo $'0\t0\t0\t0\t0\t0')
          [[ -z "${stats}" ]] && stats=$'0\t0\t0\t0\t0\t0'
          IFS=$'\t' read -r r_iops w_iops bw_bytes p50_ns p95_ns p99_ns <<< "${stats}"
          total_r=$(( total_r + ${r_iops%.*} ))
          total_w=$(( total_w + ${w_iops%.*} ))
          total_bw_kib=$(( total_bw_kib + ${bw_bytes%.*} / 1024 ))
          sum_p50_ns=$(( sum_p50_ns + ${p50_ns%.*} ))
          sum_p95_ns=$(( sum_p95_ns + ${p95_ns%.*} ))
          [[ "${p99_ns%.*}" -gt "${max_p99_ns}" ]] && max_p99_ns="${p99_ns%.*}"
          n=$(( n + 1 ))
        done < <(find "${step_dir}" -maxdepth 1 -name '*-fio.json' -type f)

        if [[ "${n}" -eq 0 ]]; then
          echo "${vm_count},${rate},0,0,0,0,0,0,false"
          return
        fi

        local avg_p50_ms avg_p95_ms max_p99_ms bw_mbs pass="true"
        avg_p50_ms=$(echo "${sum_p50_ns} ${n}" | awk '{printf "%.2f", $1/$2/1000000}')
        avg_p95_ms=$(echo "${sum_p95_ns} ${n}" | awk '{printf "%.2f", $1/$2/1000000}')
        max_p99_ms=$(echo "${max_p99_ns}"     | awk '{printf "%.2f", $1/1000000}')
        bw_mbs=$(echo "${total_bw_kib}"       | awk '{printf "%.2f", $1/1024}')
        [[ "$(echo "${max_p99_ms} ${sla}" | awk '{print ($1 > $2)}')" == "1" ]] && pass="false"
        echo "${vm_count},${rate},${total_r},${total_w},${bw_mbs},${avg_p50_ms},${avg_p95_ms},${max_p99_ms},${pass}"
      }

      tmp_csv=$(mktemp)
      echo "vm_count,rate_iops,total_read_iops,total_write_iops,total_bw_mbs,avg_p50_ms,avg_p95_ms,max_p99_ms,sla_pass" > "${tmp_csv}"

      last_pass=0
      first_fail=0
      step_count=0
      # Sort numerically by VM count
      mapfile -t sorted_steps < <(
        for d in "${step_dirs[@]}"; do
          vc=$(basename "${d}" | sed -E 's/^step-0*([0-9]+)-vms$/\1/')
          printf '%010d\t%s\t%s\n' "${vc}" "${vc}" "${d}"
        done | sort -n | cut -f2-
      )
      for entry in "${sorted_steps[@]}"; do
        vc="${entry%%	*}"
        d="${entry#*	}"
        line=$(_extract_step_metrics "${d}" "${vc}" "${RATE_IOPS}" "${LATENCY_SLA}")
        echo "${line}" >> "${tmp_csv}"
        pass=$(echo "${line}" | awk -F',' '{print $9}')
        if [[ "${pass}" == "true" ]]; then
          last_pass="${vc}"
        elif [[ "${first_fail}" -eq 0 ]]; then
          first_fail="${vc}"
        fi
        step_count=$(( step_count + 1 ))
      done

      mv "${tmp_csv}" "${ramp_csv}"
      log_info "Wrote ${step_count}-row ramp.csv (last_pass=${last_pass}, first_fail=${first_fail})"

      # Recompute summary
      cap_line=""
      brk_line=""
      [[ "${last_pass}" -gt 0 ]] && cap_line=$(grep "^${last_pass}," "${ramp_csv}" | tail -1 || true)
      [[ "${first_fail}" -gt 0 ]] && brk_line=$(grep "^${first_fail}," "${ramp_csv}" | tail -1 || true)
      cap_iops=0; cap_p99=0; brk_p99=0
      if [[ -n "${cap_line}" ]]; then
        cap_iops=$(echo "${cap_line}" | awk -F',' '{print $3 + $4}')
        cap_p99=$(echo "${cap_line}"  | awk -F',' '{print $8}')
      fi
      [[ -n "${brk_line}" ]] && brk_p99=$(echo "${brk_line}" | awk -F',' '{print $8}')

      stitched_sc=$(get_storage_class_for_pool "${POOL}" 2>/dev/null || echo "${POOL}")
      cat > "${ramp_summary}" <<JSONEOF
{
  "pool": "${POOL}",
  "storage_class": "${stitched_sc}",
  "rate_iops": ${RATE_IOPS},
  "latency_sla_ms": ${LATENCY_SLA},
  "capacity_vms": ${last_pass},
  "total_iops_at_capacity": ${cap_iops},
  "p99_at_capacity_ms": ${cap_p99},
  "breach_vms": ${first_fail},
  "p99_at_breach_ms": ${brk_p99},
  "resource_ceiling": false,
  "steps": ${step_count},
  "cluster_description": "${CLUSTER_DESCRIPTION}",
  "run_id": "${RUN_ID}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSONEOF
      log_info "Wrote ${ramp_summary}"

      report_html="${REPORTS_DIR}/scale-test-${POOL}-${RATE_IOPS}iops-${RUN_ID}.html"
      generate_scale_test_report "${ramp_csv}" "${ramp_summary}" "${report_html}"
      log_info "Wrote ${report_html}"
    fi
  fi
fi

log_info "===== Scale-test complete. Restoring initial cluster state... ====="
restore_cluster_state "${SNAPSHOT}"
RESTORE_DONE=true
log_info "Done. Results in ${RESULTS_DIR}/${RUN_ID}/scale-test/"
