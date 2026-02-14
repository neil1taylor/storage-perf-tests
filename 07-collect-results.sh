#!/usr/bin/env bash
# =============================================================================
# 07-collect-results.sh — Aggregate fio JSON results into CSV
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
  tail -n +2 "${csv_file}" | awk -F',' '
  {
    gsub(/"/, "")
    pool = $1
    count[pool]++
    riops[pool] += $8
    wiops[pool] += $12
    rbw[pool] += $9
    wbw[pool] += $13
    rlat[pool] += $10
    wlat[pool] += $14
    rp99[pool] += $11
    wp99[pool] += $15
  }
  END {
    for (p in count) {
      n = count[p]
      printf "\"%s\",%.0f,%.0f,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%d\n",
        p,
        riops[p]/n, wiops[p]/n,
        rbw[p]/n/1024, wbw[p]/n/1024,
        rlat[p]/n, wlat[p]/n,
        rp99[p]/n, wp99[p]/n,
        n
    }
  }' | sort -t',' -k2,2 -nr >> "${summary_file}"

  log_info "Summary written to: ${summary_file}"

  # Print a quick overview
  log_info ""
  log_info "=== Quick Overview ==="
  column -t -s',' "${summary_file}" 2>/dev/null || cat "${summary_file}"

  log_info ""
  log_info "Files generated:"
  log_info "  Raw CSV:     ${csv_file}"
  log_info "  Summary CSV: ${summary_file}"
  log_info ""
  log_info "Run ./08-generate-report.sh to create HTML/Markdown/XLSX reports"
}

main "$@"
