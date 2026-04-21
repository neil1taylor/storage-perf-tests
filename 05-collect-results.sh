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

  # ─── Scale-test aggregate summary ───
  if [[ -d "${RESULTS_DIR}/scale-test" ]]; then
    log_info ""
    log_info "=== Scale Test Aggregate Summary ==="
    log_info ""
    printf "%-35s %8s %12s %12s %14s %12s %12s %12s\n" \
      "Test" "VMs" "Read IOPS" "Write IOPS" "Total IOPS" "BW (MB/s)" "Avg Lat" "P95 Lat"
    printf "%-35s %8s %12s %12s %14s %12s %12s %12s\n" \
      "---" "---" "---" "---" "---" "---" "---" "---"

    while IFS= read -r test_dir; do
      # Extract test label from directory path: scale-test/<pool>/200vm-rateN/... or scale-test/single-vm/<label>/...
      local rel_path="${test_dir#"${RESULTS_DIR}"/scale-test/}"
      local test_label="${rel_path%%/mixed-70-30-rated/*}"

      local agg_read_iops=0 agg_write_iops=0
      local agg_read_bw=0 agg_write_bw=0
      local sum_read_lat=0 sum_write_lat=0
      local sum_read_p95=0 sum_write_p95=0
      local vm_count=0

      while IFS= read -r json_file; do
        # Validate JSON before parsing
        if ! jq empty "${json_file}" 2>/dev/null; then
          continue
        fi
        if [[ $(jq '.jobs | length' "${json_file}" 2>/dev/null || echo "0") -eq 0 ]]; then
          continue
        fi

        local riops wiops rbw wbw rlat wlat rp95 wp95
        riops=$(jq '[.jobs[].read.iops // 0] | add | floor' "${json_file}" 2>/dev/null || echo 0)
        wiops=$(jq '[.jobs[].write.iops // 0] | add | floor' "${json_file}" 2>/dev/null || echo 0)
        rbw=$(jq '[.jobs[].read.bw // 0] | add' "${json_file}" 2>/dev/null || echo 0)
        wbw=$(jq '[.jobs[].write.bw // 0] | add' "${json_file}" 2>/dev/null || echo 0)
        rlat=$(jq '[.jobs[].read.lat_ns.mean // 0] | add / length / 1000000' "${json_file}" 2>/dev/null || echo 0)
        wlat=$(jq '[.jobs[].write.lat_ns.mean // 0] | add / length / 1000000' "${json_file}" 2>/dev/null || echo 0)
        rp95=$(jq '[.jobs[].read.clat_ns.percentile["95.000000"] // 0] | add / length / 1000000' "${json_file}" 2>/dev/null || echo 0)
        wp95=$(jq '[.jobs[].write.clat_ns.percentile["95.000000"] // 0] | add / length / 1000000' "${json_file}" 2>/dev/null || echo 0)

        agg_read_iops=$(( agg_read_iops + riops ))
        agg_write_iops=$(( agg_write_iops + wiops ))
        agg_read_bw=$(awk "BEGIN{print ${agg_read_bw} + ${rbw}}")
        agg_write_bw=$(awk "BEGIN{print ${agg_write_bw} + ${wbw}}")
        sum_read_lat=$(awk "BEGIN{print ${sum_read_lat} + ${rlat}}")
        sum_write_lat=$(awk "BEGIN{print ${sum_write_lat} + ${wlat}}")
        sum_read_p95=$(awk "BEGIN{print ${sum_read_p95} + ${rp95}}")
        sum_write_p95=$(awk "BEGIN{print ${sum_write_p95} + ${wp95}}")
        ((vm_count += 1))
      done < <(find "${test_dir}" -name "*-fio.json" -type f)

      if [[ ${vm_count} -gt 0 ]]; then
        local total_iops=$(( agg_read_iops + agg_write_iops ))
        local total_bw
        total_bw=$(awk "BEGIN{printf \"%.1f\", (${agg_read_bw} + ${agg_write_bw}) / 1024}")
        local avg_lat
        avg_lat=$(awk "BEGIN{printf \"%.2f\", (${sum_read_lat} + ${sum_write_lat}) / (2 * ${vm_count})}")
        local avg_p95
        avg_p95=$(awk "BEGIN{printf \"%.2f\", (${sum_read_p95} + ${sum_write_p95}) / (2 * ${vm_count})}")

        printf "%-35s %8d %12d %12d %14d %12s %12s %12s\n" \
          "${test_label}" "${vm_count}" "${agg_read_iops}" "${agg_write_iops}" \
          "${total_iops}" "${total_bw}" "${avg_lat}ms" "${avg_p95}ms"
      fi
    done < <(find "${RESULTS_DIR}/scale-test" -mindepth 3 -maxdepth 3 -type d | sort)

    log_info ""
  fi

  # Check for scale-test ramp results (separate from normal matrix)
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
