#!/usr/bin/env bash
# =============================================================================
# 05-collect-results.sh — Aggregate fio JSON results into CSV
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"
source "${SCRIPT_DIR}/lib/report-helpers.sh"

main() {
  log_info "=== Collecting and Aggregating Results ==="

  if [[ ! -d "${RESULTS_DIR}" ]]; then
    log_error "Results directory not found: ${RESULTS_DIR}"
    exit 1
  fi

  local json_count
  json_count=$(find "${RESULTS_DIR}" -name "*-fio.json" -type f | wc -l)
  log_info "Found ${json_count} fio JSON result files"

  if [[ "${json_count}" -eq 0 ]]; then
    log_error "No fio results found. Did the tests run?"
    exit 1
  fi

  # Pre-validate all fio JSON files and report summary
  local valid_count=0 invalid_count=0 empty_count=0
  while read -r json_file; do
    if ! jq empty "${json_file}" 2>/dev/null; then
      ((invalid_count += 1))
      log_warn "Invalid JSON (syntax): ${json_file}"
    elif [[ $(jq '.jobs | length' "${json_file}" 2>/dev/null || echo "0") -eq 0 ]]; then
      ((empty_count += 1))
      log_warn "Empty jobs array: ${json_file}"
    else
      ((valid_count += 1))
    fi
  done < <(find "${RESULTS_DIR}" -name "*-fio.json" -type f)
  log_info "Validation: ${valid_count} valid, ${invalid_count} invalid syntax, ${empty_count} empty jobs"

  # Generate aggregated CSV
  local csv_file="${REPORTS_DIR}/results-${RUN_ID}.csv"
  mkdir -p "${REPORTS_DIR}"
  aggregate_results_csv "${RESULTS_DIR}" "${csv_file}"

  # Also generate a summary with averages per pool
  log_info "Generating pool summary..."
  local summary_file="${REPORTS_DIR}/summary-${RUN_ID}.csv"

  echo '"storage_pool","avg_read_iops","avg_write_iops","avg_read_bw_mib","avg_write_bw_mib","avg_read_lat_ms","avg_write_lat_ms","avg_read_p99_ms","avg_write_p99_ms","test_count"' > "${summary_file}"

  # Column mapping from csv_header() in lib/report-helpers.sh:
  # $1=storage_pool $2=vm_size $3=pvc_size $4=concurrency $5=fio_profile
  # $6=block_size $7=job_name $8=read_iops $9=read_bw_kib
  # $10=read_lat_avg_ms $11=read_lat_p99_ms $12=write_iops $13=write_bw_kib
  # $14=write_lat_avg_ms $15=write_lat_p99_ms
  #
  # Aggregation note: profiles with multiple [job] sections joined by `stonewall`
  # (random-rw, sequential-rw) emit ONE row per job, so a single test produces
  # 2 rows — one with reads only, one with writes only. Aggregating by row would
  # halve every metric for those profiles. Group by test instead, sum within
  # the test (the non-active job contributes 0 to the sum), then average
  # across tests per pool. Latency is taken as MAX within a test so we keep
  # the meaningful value from the job that actually did that op type.
  tail -n +2 "${csv_file}" | awk -F',' '
  {
    gsub(/"/, "")
    pool = $1
    test_key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4 SUBSEP $5 SUBSEP $6
    if (!(test_key in test_seen)) {
      test_seen[test_key] = 1
      test_pool[test_key] = pool
      test_count[pool]++
    }
    riops[test_key] += $8
    wiops[test_key] += $12
    rbw[test_key]   += $9
    wbw[test_key]   += $13
    if ($10+0 > rlat[test_key]+0) rlat[test_key] = $10
    if ($14+0 > wlat[test_key]+0) wlat[test_key] = $14
    if ($11+0 > rp99[test_key]+0) rp99[test_key] = $11
    if ($15+0 > wp99[test_key]+0) wp99[test_key] = $15
  }
  END {
    for (tk in test_seen) {
      p = test_pool[tk]
      sum_riops[p] += riops[tk]
      sum_wiops[p] += wiops[tk]
      sum_rbw[p]   += rbw[tk]
      sum_wbw[p]   += wbw[tk]
      sum_rlat[p]  += rlat[tk]
      sum_wlat[p]  += wlat[tk]
      sum_rp99[p]  += rp99[tk]
      sum_wp99[p]  += wp99[tk]
    }
    for (p in test_count) {
      n = test_count[p]
      printf "\"%s\",%.0f,%.0f,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%d\n",
        p,
        sum_riops[p]/n, sum_wiops[p]/n,
        sum_rbw[p]/n/1024, sum_wbw[p]/n/1024,
        sum_rlat[p]/n, sum_wlat[p]/n,
        sum_rp99[p]/n, sum_wp99[p]/n,
        n
    }
  }' | sort -t',' -k2,2 -nr >> "${summary_file}"

  log_info "Summary written to: ${summary_file}"

  # Print a quick overview
  log_info ""
  log_info "=== Quick Overview ==="
  column -t -s',' "${summary_file}" 2>/dev/null || cat "${summary_file}"

  # Check for scale-test ramp results
  local scale_test_dir="${RESULTS_DIR}/scale-test"
  if [[ -d "${scale_test_dir}" ]]; then
    log_info ""
    log_info "=== Scale-test ramp results detected ==="
    while read -r ramp_csv; do
      local pool_dir
      pool_dir=$(dirname "${ramp_csv}")
      local pool_name
      pool_name=$(basename "${pool_dir}")
      local step_count
      step_count=$(( $(wc -l < "${ramp_csv}") - 1 ))
      log_info "  Pool: ${pool_name} — ${step_count} ramp steps"
      if [[ -f "${pool_dir}/ramp-summary.json" ]]; then
        local capacity
        capacity=$(jq -r '.capacity_vms' "${pool_dir}/ramp-summary.json")
        local rate
        rate=$(jq -r '.rate_iops' "${pool_dir}/ramp-summary.json")
        log_info "    Capacity: ${capacity} VMs at ${rate} IOPS/VM"
      fi
    done < <(find "${scale_test_dir}" -name "ramp.csv" -type f)
  fi

  log_info ""
  log_info "Files generated:"
  log_info "  Raw CSV:     ${csv_file}"
  log_info "  Summary CSV: ${summary_file}"
  log_info ""
  log_info "Run ./06-generate-report.sh to create HTML/Markdown/XLSX reports"
}

main "$@"
