# Scale Test Auto-Ramp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed-count scale test with an auto-ramping mode that doubles VM count until p99 latency breaches a configurable SLA, then backfills linearly to find the precise capacity ceiling.

**Architecture:** The ramp loop lives entirely in `04-run-tests.sh` inside the existing `SCALE_TEST_MODE` block. Each ramp step creates N VMs, runs rated fio, extracts p99 from JSON results, decides pass/fail, deletes VMs, and proceeds. A new `generate_scale_test_report()` in `lib/report-helpers.sh` produces the HTML report from the ramp CSV.

**Tech Stack:** Bash, jq, Python 3 (embedded), Chart.js (CDN)

**Spec:** `docs/plans/2026-04-21-scale-test-auto-ramp-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `00-config.sh` | Modify | Add `SCALE_RATE_IOPS`, `SCALE_LATENCY_SLA_MS`, `SCALE_MAX_VMS`. Remove `SCALE_TEST_VMS`. |
| `04-run-tests.sh` | Modify | Replace `--vms` with `--rate-iops`/`--latency-sla`. Replace scale-test block with ramp algorithm. |
| `lib/report-helpers.sh` | Modify | Add `generate_scale_test_report()` function. |
| `05-collect-results.sh` | Modify | Handle `scale-test/` subdirectory in results. |
| `run-all.sh` | Modify | Update help text and passthrough for new flags. |

---

### Task 1: Update config defaults in `00-config.sh`

**Files:**
- Modify: `00-config.sh:181-184`

- [ ] **Step 1: Replace `SCALE_TEST_VMS` with new scale-test config vars**

In `00-config.sh`, find the scale-test settings block (around line 181-184) and replace:

```bash
# OLD:
export FIO_RATE_IOPS="${FIO_RATE_IOPS:-0}"               # 0 = unlimited; >0 = per-job IOPS cap (scale-test)

# Scale-test mode settings
export SCALE_VM_BATCH_SIZE="${SCALE_VM_BATCH_SIZE:-20}"   # VMs created per batch (avoids API server overload)
```

With:

```bash
export FIO_RATE_IOPS="${FIO_RATE_IOPS:-0}"               # 0 = unlimited; >0 = per-job IOPS cap (scale-test)

# Scale-test mode settings
export SCALE_VM_BATCH_SIZE="${SCALE_VM_BATCH_SIZE:-20}"   # VMs created per batch (avoids API server overload)
export SCALE_RATE_IOPS="${SCALE_RATE_IOPS:-500}"          # Default per-VM IOPS cap for scale-test ramp
export SCALE_LATENCY_SLA_MS="${SCALE_LATENCY_SLA_MS:-5}"  # p99 latency threshold (ms) — ramp stops on breach
export SCALE_MAX_VMS="${SCALE_MAX_VMS:-256}"               # Hard ceiling for ramp (prevents runaway)
```

- [ ] **Step 2: Verify config loads without errors**

Run: `bash -c 'source ./00-config.sh && echo "SCALE_RATE_IOPS=${SCALE_RATE_IOPS} SCALE_LATENCY_SLA_MS=${SCALE_LATENCY_SLA_MS} SCALE_MAX_VMS=${SCALE_MAX_VMS}"'`

Expected output includes: `SCALE_RATE_IOPS=500 SCALE_LATENCY_SLA_MS=5 SCALE_MAX_VMS=256`

- [ ] **Step 3: Commit**

```bash
git add 00-config.sh
git commit -m "feat(config): add scale-test auto-ramp defaults (rate, SLA, max VMs)"
```

---

### Task 2: Update CLI flag parsing in `04-run-tests.sh`

**Files:**
- Modify: `04-run-tests.sh:29-80`

- [ ] **Step 1: Replace `--vms` with `--rate-iops` and `--latency-sla` flags**

In the variable declarations (around line 29-39), change:

```bash
# OLD:
SCALE_TEST_MODE=false
SCALE_TEST_VMS=200
```

To:

```bash
SCALE_TEST_MODE=false
SCALE_RATE_IOPS_CLI=""
SCALE_LATENCY_SLA_CLI=""
```

In the `while` loop (around line 41-80), replace the `--vms` case and update `--scale-test`:

```bash
# OLD:
    --scale-test) SCALE_TEST_MODE=true; shift ;;
    --vms)        SCALE_TEST_VMS="$2"; shift 2 ;;
```

With:

```bash
    --scale-test)    SCALE_TEST_MODE=true; shift ;;
    --rate-iops)     SCALE_RATE_IOPS_CLI="$2"; shift 2 ;;
    --latency-sla)   SCALE_LATENCY_SLA_CLI="$2"; shift 2 ;;
```

- [ ] **Step 2: Add --pool requirement enforcement after the mode guard**

After the mutual exclusivity guard (line ~92), add:

```bash
if [[ "${SCALE_TEST_MODE}" == true ]]; then
  if [[ -z "${FILTER_POOL}" ]]; then
    echo "Error: --scale-test requires --pool <name>" >&2
    exit 1
  fi
  # Apply CLI overrides to config defaults
  [[ -n "${SCALE_RATE_IOPS_CLI}" ]] && SCALE_RATE_IOPS="${SCALE_RATE_IOPS_CLI}"
  [[ -n "${SCALE_LATENCY_SLA_CLI}" ]] && SCALE_LATENCY_SLA_MS="${SCALE_LATENCY_SLA_CLI}"
fi
```

- [ ] **Step 3: Update help text**

Replace the `--scale-test` and `--vms` help lines:

```bash
# OLD:
      echo "  --scale-test     Scale test: multi-VM tests (NFS dp2, ODF rep3, NFS rfs)"
      echo "  --vms <N>        Number of VMs for scale test (default: 200, use with --scale-test)"
```

With:

```bash
      echo "  --scale-test     Auto-ramp: double VMs until p99 latency breaches SLA (requires --pool)"
      echo "  --rate-iops <N>  Per-VM IOPS cap for scale-test (default: ${SCALE_RATE_IOPS})"
      echo "  --latency-sla <ms>  p99 latency SLA in ms for scale-test (default: ${SCALE_LATENCY_SLA_MS})"
```

Also update the `Usage:` line:

```bash
      echo "Usage: $0 [--pool <name>] [--quick] [--overview] [--rank] [--scale-test --pool <name> [--rate-iops N] [--latency-sla N]] [--parallel [N]]"
```

- [ ] **Step 4: Verify flag parsing**

Run: `./04-run-tests.sh --scale-test --help`

Expected: updated help text shows `--rate-iops` and `--latency-sla`, no mention of `--vms`.

Run: `./04-run-tests.sh --scale-test --dry-run 2>&1 | head -5`

Expected: error message `Error: --scale-test requires --pool <name>`

- [ ] **Step 5: Commit**

```bash
git add 04-run-tests.sh
git commit -m "feat(cli): replace --vms with --rate-iops/--latency-sla, require --pool for --scale-test"
```

---

### Task 3: Implement the ramp algorithm in `04-run-tests.sh`

This is the core task. Replace the entire `if [[ "${SCALE_TEST_MODE}" == true ]]` block (lines 135-588) with the auto-ramp logic.

**Files:**
- Modify: `04-run-tests.sh:125-588`

- [ ] **Step 1: Write the `extract_step_metrics()` helper**

This function extracts all metrics for a step and outputs a single CSV line. Insert inside the `SCALE_TEST_MODE` block, before the ramp loop.

```bash
  # ─── Extract aggregated metrics from a step's results → CSV line ───
  extract_step_metrics() {
    local step_dir="$1"
    local vm_count="$2"
    local rate_iops="$3"
    local sla_ms="$4"

    local total_read_iops=0 total_write_iops=0 total_bw_kib=0
    local max_p99_ns=0 sum_p50_ns=0 sum_p95_ns=0
    local file_count=0

    while read -r json_file; do
      local stats
      stats=$(jq -r '[
        (.jobs[0].read.iops // 0),
        (.jobs[0].write.iops // 0),
        (.jobs[0].read.bw_bytes // 0) + (.jobs[0].write.bw_bytes // 0),
        (.jobs[0].write.clat_ns.percentile["50.000000"] // 0),
        (.jobs[0].write.clat_ns.percentile["95.000000"] // 0),
        (.jobs[0].write.clat_ns.percentile["99.000000"] // 0)
      ] | @tsv' "${json_file}" 2>/dev/null || echo "0	0	0	0	0	0")

      IFS=$'\t' read -r r_iops w_iops bw_bytes p50_ns p95_ns p99_ns <<< "${stats}"
      total_read_iops=$(( total_read_iops + ${r_iops%.*} ))
      total_write_iops=$(( total_write_iops + ${w_iops%.*} ))
      total_bw_kib=$(( total_bw_kib + ${bw_bytes%.*} / 1024 ))
      sum_p50_ns=$(( sum_p50_ns + ${p50_ns%.*} ))
      sum_p95_ns=$(( sum_p95_ns + ${p95_ns%.*} ))
      if [[ "${p99_ns%.*}" -gt "${max_p99_ns}" ]]; then
        max_p99_ns="${p99_ns%.*}"
      fi
      ((file_count += 1))
    done < <(find "${step_dir}" -name "*-fio.json" -type f)

    if [[ "${file_count}" -eq 0 ]]; then
      echo "${vm_count},${rate_iops},0,0,0,0,0,0,false"
      return
    fi

    local avg_p50_ms avg_p95_ms max_p99_ms total_bw_mbs sla_pass
    avg_p50_ms=$(echo "${sum_p50_ns} ${file_count}" | awk '{printf "%.2f", $1 / $2 / 1000000}')
    avg_p95_ms=$(echo "${sum_p95_ns} ${file_count}" | awk '{printf "%.2f", $1 / $2 / 1000000}')
    max_p99_ms=$(echo "${max_p99_ns}" | awk '{printf "%.2f", $1 / 1000000}')
    total_bw_mbs=$(echo "${total_bw_kib}" | awk '{printf "%.2f", $1 / 1024}')

    sla_pass="true"
    if (( $(echo "${max_p99_ms} ${sla_ms}" | awk '{print ($1 > $2)}') )); then
      sla_pass="false"
    fi

    echo "${vm_count},${rate_iops},${total_read_iops},${total_write_iops},${total_bw_mbs},${avg_p50_ms},${avg_p95_ms},${max_p99_ms},${sla_pass}"
  }
```

- [ ] **Step 2: Write the `run_ramp_step()` helper**

This function runs a single ramp step: create N VMs, wait for fio, collect results, delete VMs. Returns 0 on success, 1 on VM creation failure.

```bash
  # ─── Run one ramp step: create N VMs, run fio, collect, delete ───
  run_ramp_step() {
    local pool_name="$1"
    local sc_name="$2"
    local vm_count="$3"
    local rate_iops="$4"
    local step_results_dir="$5"

    mkdir -p "${step_results_dir}"

    # Save and override fio params
    local saved_iodepth="${FIO_IODEPTH}" saved_numjobs="${FIO_NUMJOBS}"
    local saved_filesize="${FIO_TEST_FILE_SIZE}" saved_rate_iops="${FIO_RATE_IOPS}"
    FIO_IODEPTH=32
    FIO_NUMJOBS=1
    FIO_TEST_FILE_SIZE=10G
    FIO_RATE_IOPS="${rate_iops}"

    local profile_path="${SCRIPT_DIR}/fio-profiles/mixed-70-30-rated.fio"
    local rendered_fio
    rendered_fio=$(render_fio_profile "${profile_path}" "4k")

    local cloud_init_content
    cloud_init_content=$(render_cloud_init \
      "${SCRIPT_DIR}/cloud-init/fio-runner.yaml" \
      "${rendered_fio}" \
      "scale-vm" \
      "/mnt/data")

    # Create VMs in batches
    local -a vm_names=()
    local vm_create_failed=false
    local batch_count=0

    for ((i=1; i<=vm_count; i++)); do
      local vm_name="scale-${pool_name}-c${vm_count}-${i}"
      vm_name="${vm_name,,}"
      vm_name="${vm_name//[^a-z0-9-]/-}"
      vm_name="${vm_name:0:63}"
      vm_name="${vm_name%-}"
      vm_names+=("${vm_name}")

      create_test_vm \
        "${vm_name}" "${sc_name}" "150Gi" "2" "4Gi" \
        "${cloud_init_content}" "${pool_name}" "small" \
        "${SCRIPT_DIR}/vm-templates/vm-template.yaml" || {
          log_error "[ramp] Failed to create VM ${vm_name}"
          vm_create_failed=true
          break
        }

      ((batch_count += 1))
      if (( batch_count >= SCALE_VM_BATCH_SIZE )); then
        log_info "[ramp] Batch ${i}/${vm_count} submitted, pausing..."
        sleep 5
        batch_count=0
      fi
    done

    # On create failure, clean up and signal caller
    if [[ "${vm_create_failed}" == "true" ]]; then
      log_error "[ramp] VM creation failed at ${#vm_names[@]}/${vm_count} — cleaning up"
      for vm in "${vm_names[@]}"; do delete_test_vm "${vm}" & done
      wait
      FIO_IODEPTH="${saved_iodepth}"; FIO_NUMJOBS="${saved_numjobs}"
      FIO_TEST_FILE_SIZE="${saved_filesize}"; FIO_RATE_IOPS="${saved_rate_iops}"
      return 1
    fi

    log_info "[ramp] All ${vm_count} VMs submitted, waiting for Running..."
    if ! wait_for_all_vms_running "${vm_names[@]}"; then
      log_error "[ramp] Not all VMs started — cleaning up"
      for vm in "${vm_names[@]}"; do delete_test_vm "${vm}" & done
      wait
      FIO_IODEPTH="${saved_iodepth}"; FIO_NUMJOBS="${saved_numjobs}"
      FIO_TEST_FILE_SIZE="${saved_filesize}"; FIO_RATE_IOPS="${saved_rate_iops}"
      return 1
    fi

    # Wait for fio
    if ! wait_for_all_fio_complete "${vm_names[@]}"; then
      log_warn "[ramp] Some fio tests did not complete"
    fi

    # Collect results
    log_info "[ramp] Collecting results from ${vm_count} VMs..."
    local -a collect_pids=()
    for vm in "${vm_names[@]}"; do
      collect_vm_results "${vm}" "${step_results_dir}" &
      collect_pids+=($!)
    done
    for pid in "${collect_pids[@]}"; do wait "${pid}" || true; done

    # Cleanup VMs
    log_info "[ramp] Cleaning up ${vm_count} VMs..."
    for vm in "${vm_names[@]}"; do delete_test_vm "${vm}" & done
    wait

    # Restore fio params
    FIO_IODEPTH="${saved_iodepth}"; FIO_NUMJOBS="${saved_numjobs}"
    FIO_TEST_FILE_SIZE="${saved_filesize}"; FIO_RATE_IOPS="${saved_rate_iops}"
    return 0
  }
```

- [ ] **Step 3: Write the main ramp loop (Phase 1 doubling + Phase 2 backfill)**

Replace the entire block from `if [[ "${SCALE_TEST_MODE}" == true ]]; then` (line 135) through `exit 0` / `fi` (line 588) with:

```bash
if [[ "${SCALE_TEST_MODE}" == true ]]; then
  mkdir -p "${RESULTS_DIR}" "${REPORTS_DIR}"
  ensure_ssh_key
  source "${SCRIPT_DIR}/lib/report-helpers.sh"

  local pool_name="${FILTER_POOL}"
  local sc_name
  sc_name=$(get_storage_class_for_pool "${pool_name}")
  local rate_iops="${SCALE_RATE_IOPS}"
  local sla_ms="${SCALE_LATENCY_SLA_MS}"
  local max_vms="${SCALE_MAX_VMS}"

  local scale_results_dir="${RESULTS_DIR}/scale-test/${pool_name}"
  local ramp_csv="${scale_results_dir}/ramp.csv"
  local ramp_summary="${scale_results_dir}/ramp-summary.json"
  mkdir -p "${scale_results_dir}"

  # --- Helper functions (extract_step_metrics, run_ramp_step) ---
  # [Inserted above in Steps 1-2]

  # ─── Dry-run ───
  if [[ "${DRY_RUN}" == true ]]; then
    log_info ""
    log_info "=== DRY RUN — Scale Test Auto-Ramp Preview ==="
    log_info ""
    log_info "Pool:          ${pool_name} (sc: ${sc_name})"
    log_info "Rate IOPS:     ${rate_iops} per VM"
    log_info "Latency SLA:   p99 < ${sla_ms}ms"
    log_info "Max VMs:       ${max_vms}"
    log_info "fio profile:   mixed-70-30-rated, 4k, QD32, numjobs=1, 10G"
    log_info "VM spec:       small (2 vCPU, 4Gi), 150Gi PVC"
    log_info "VM batch size: ${SCALE_VM_BATCH_SIZE}"
    log_info ""
    log_info "Phase 1 (doubling): 1, 2, 4, 8, 16, 32, 64, 128, 256 VMs"
    log_info "Phase 2 (backfill): linear steps between last pass and first fail"
    log_info ""
    log_info "Each step: create VMs → run fio (${FIO_RUNTIME}s + ${FIO_RAMP_TIME}s ramp) → collect p99 → delete VMs"
    log_info "Estimated time per step: ~$(( FIO_RUNTIME + FIO_RAMP_TIME + 120 ))s + VM boot/clone time"
    log_info ""
    log_info "No resources will be created (dry run)."
    exit 0
  fi

  # ─── Phase 1: Doubling ───
  log_info ""
  log_info "=========================================="
  log_info "Scale Test Auto-Ramp: ${pool_name}"
  log_info "Rate: ${rate_iops} IOPS/VM | SLA: p99 < ${sla_ms}ms"
  log_info "=========================================="

  suite_start_time=$(date +%s)

  # CSV header
  echo "vm_count,rate_iops,total_read_iops,total_write_iops,total_bw_mbs,avg_p50_ms,avg_p95_ms,max_p99_ms,sla_pass" > "${ramp_csv}"

  local last_pass_count=0
  local first_fail_count=0
  local resource_ceiling=false
  local vm_count=1

  log_info ""
  log_info "--- Phase 1: Doubling ---"

  while [[ ${vm_count} -le ${max_vms} ]]; do
    local step_start_time
    step_start_time=$(date +%s)
    local step_dir="${scale_results_dir}/step-$(printf '%03d' ${vm_count})-vms"

    log_info ""
    log_info "=== Ramp Step: ${vm_count} VMs (rate_iops=${rate_iops}) ==="

    if ! run_ramp_step "${pool_name}" "${sc_name}" "${vm_count}" "${rate_iops}" "${step_dir}"; then
      log_warn "[ramp] Resource ceiling hit at ${vm_count} VMs"
      first_fail_count="${vm_count}"
      resource_ceiling=true
      break
    fi

    # Extract metrics and append to CSV
    local metrics_line
    metrics_line=$(extract_step_metrics "${step_dir}" "${vm_count}" "${rate_iops}" "${sla_ms}")
    echo "${metrics_line}" >> "${ramp_csv}"

    local step_p99_ms
    step_p99_ms=$(echo "${metrics_line}" | awk -F',' '{print $8}')
    local sla_pass
    sla_pass=$(echo "${metrics_line}" | awk -F',' '{print $9}')

    local step_elapsed=$(( $(date +%s) - step_start_time ))
    log_info "[ramp] ${vm_count} VMs: p99=${step_p99_ms}ms (SLA=${sla_ms}ms) → ${sla_pass} [$(_format_duration ${step_elapsed})]"

    if [[ "${sla_pass}" == "false" ]]; then
      first_fail_count="${vm_count}"
      break
    fi

    last_pass_count="${vm_count}"
    vm_count=$(( vm_count * 2 ))
  done

  # Handle no-breach case
  if [[ ${first_fail_count} -eq 0 ]]; then
    log_info ""
    log_info "[ramp] No SLA breach through ${last_pass_count} VMs — backend not saturated at ${rate_iops} IOPS/VM"
  fi

  # ─── Phase 2: Linear Backfill ───
  if [[ ${first_fail_count} -gt 0 && ${last_pass_count} -gt 0 ]]; then
    local gap=$(( first_fail_count - last_pass_count ))
    local step_size=$(( gap / 4 ))
    [[ ${step_size} -lt 1 ]] && step_size=1

    if [[ ${gap} -gt 1 ]]; then
      log_info ""
      log_info "--- Phase 2: Backfill (${last_pass_count}..${first_fail_count}, step=${step_size}) ---"

      vm_count=$(( last_pass_count + step_size ))
      while [[ ${vm_count} -lt ${first_fail_count} ]]; do
        local step_start_time
        step_start_time=$(date +%s)
        local step_dir="${scale_results_dir}/step-$(printf '%03d' ${vm_count})-vms"

        log_info ""
        log_info "=== Backfill Step: ${vm_count} VMs (rate_iops=${rate_iops}) ==="

        if ! run_ramp_step "${pool_name}" "${sc_name}" "${vm_count}" "${rate_iops}" "${step_dir}"; then
          log_warn "[ramp] Resource ceiling hit at ${vm_count} VMs during backfill"
          break
        fi

        local metrics_line
        metrics_line=$(extract_step_metrics "${step_dir}" "${vm_count}" "${rate_iops}" "${sla_ms}")
        echo "${metrics_line}" >> "${ramp_csv}"

        local step_p99_ms
        step_p99_ms=$(echo "${metrics_line}" | awk -F',' '{print $8}')
        local sla_pass
        sla_pass=$(echo "${metrics_line}" | awk -F',' '{print $9}')

        local step_elapsed=$(( $(date +%s) - step_start_time ))
        log_info "[ramp] ${vm_count} VMs: p99=${step_p99_ms}ms (SLA=${sla_ms}ms) → ${sla_pass} [$(_format_duration ${step_elapsed})]"

        if [[ "${sla_pass}" == "false" ]]; then
          break
        fi

        last_pass_count="${vm_count}"
        vm_count=$(( vm_count + step_size ))
      done
    fi
  fi

  # ─── Generate summary JSON ───
  local capacity_vms="${last_pass_count}"
  local capacity_line=""
  local breach_line=""

  if [[ ${capacity_vms} -gt 0 ]]; then
    capacity_line=$(grep "^${capacity_vms}," "${ramp_csv}" | tail -1)
  fi
  if [[ ${first_fail_count} -gt 0 ]]; then
    breach_line=$(grep "^${first_fail_count}," "${ramp_csv}" | tail -1)
  fi

  local capacity_iops=0 capacity_p99="0"
  if [[ -n "${capacity_line}" ]]; then
    capacity_iops=$(echo "${capacity_line}" | awk -F',' '{print $3 + $4}')
    capacity_p99=$(echo "${capacity_line}" | awk -F',' '{print $8}')
  fi

  local breach_p99="0"
  if [[ -n "${breach_line}" ]]; then
    breach_p99=$(echo "${breach_line}" | awk -F',' '{print $8}')
  fi

  local step_count
  step_count=$(( $(wc -l < "${ramp_csv}") - 1 ))

  cat > "${ramp_summary}" <<JSONEOF
{
  "pool": "${pool_name}",
  "storage_class": "${sc_name}",
  "rate_iops": ${rate_iops},
  "latency_sla_ms": ${sla_ms},
  "capacity_vms": ${capacity_vms},
  "total_iops_at_capacity": ${capacity_iops},
  "p99_at_capacity_ms": ${capacity_p99},
  "breach_vms": ${first_fail_count},
  "p99_at_breach_ms": ${breach_p99},
  "resource_ceiling": ${resource_ceiling},
  "steps": ${step_count},
  "cluster_description": "${CLUSTER_DESCRIPTION}",
  "run_id": "${RUN_ID}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSONEOF

  # ─── Generate reports ───
  local report_html="${REPORTS_DIR}/scale-test-${pool_name}-${rate_iops}iops-${RUN_ID}.html"
  generate_scale_test_report "${ramp_csv}" "${ramp_summary}" "${report_html}"

  suite_elapsed=$(( $(date +%s) - suite_start_time ))
  log_info ""
  log_info "=========================================="
  log_info "Scale Test Complete"
  log_info "=========================================="
  log_info "Pool:     ${pool_name} (${sc_name})"
  log_info "Capacity: ${capacity_vms} VMs at ${rate_iops} IOPS/VM (p99 < ${sla_ms}ms)"
  if [[ ${first_fail_count} -gt 0 ]]; then
    log_info "Breach:   ${first_fail_count} VMs (p99=${breach_p99}ms)"
  fi
  log_info "Steps:    ${step_count}"
  log_info "Time:     $(_format_duration ${suite_elapsed})"
  log_info "CSV:      ${ramp_csv}"
  log_info "Report:   ${report_html}"
  log_info "Summary:  ${ramp_summary}"
  exit 0
fi
```

- [ ] **Step 4: Verify syntax**

Run: `bash -n 04-run-tests.sh`

Expected: no output (clean parse).

- [ ] **Step 5: Verify dry-run works**

Run: `./04-run-tests.sh --scale-test --pool rep3 --dry-run`

Expected: preview output showing pool, rate, SLA, phase descriptions.

- [ ] **Step 6: Commit**

```bash
git add 04-run-tests.sh
git commit -m "feat(scale-test): replace fixed-count with auto-ramp (doubling + backfill)"
```

---

### Task 4: Add `generate_scale_test_report()` to `lib/report-helpers.sh`

**Files:**
- Modify: `lib/report-helpers.sh` (append after `generate_ranking_html_report()`)

- [ ] **Step 1: Add the report generation function**

Append to `lib/report-helpers.sh`:

```bash
# ---------------------------------------------------------------------------
# Generate scale-test auto-ramp HTML report
# ---------------------------------------------------------------------------
generate_scale_test_report() {
  local ramp_csv="$1"
  local ramp_summary="$2"
  local output_html="$3"

  log_info "Generating scale-test report: ${output_html}"

  RAMP_CSV="${ramp_csv}" RAMP_SUMMARY="${ramp_summary}" \
  CLUSTER_DESC="${CLUSTER_DESCRIPTION}" \
  python3 << 'PYEOF_SCALE'
import csv, json, sys, os

csv_file = os.environ['RAMP_CSV']
summary_file = os.environ['RAMP_SUMMARY']
cluster_desc = os.environ.get('CLUSTER_DESC', '')

with open(summary_file, 'r') as f:
    summary = json.load(f)

rows = []
with open(csv_file, 'r') as f:
    reader = csv.DictReader(f)
    for row in reader:
        rows.append(row)

# Sort by vm_count for chart ordering
rows.sort(key=lambda r: int(r['vm_count']))

pool = summary['pool']
sc = summary['storage_class']
rate = summary['rate_iops']
sla = summary['latency_sla_ms']
capacity = summary['capacity_vms']
total_iops = summary['total_iops_at_capacity']
cap_p99 = summary['p99_at_capacity_ms']
breach_vms = summary['breach_vms']
breach_p99 = summary['p99_at_breach_ms']
run_id = summary['run_id']
timestamp = summary['timestamp']
resource_ceiling = summary.get('resource_ceiling', False)

# Chart data
vm_counts = [int(r['vm_count']) for r in rows]
total_iops_series = [float(r['total_read_iops']) + float(r['total_write_iops']) for r in rows]
p99_series = [float(r['max_p99_ms']) for r in rows]
pass_fail = [r['sla_pass'] for r in rows]
point_colors = ['#198038' if p == 'true' else '#da1e28' for p in pass_fail]

# Capacity description
if capacity == 0:
    cap_text = f"Pool <b>{pool}</b> cannot meet p99 &lt; {sla}ms SLA at {rate} IOPS/VM (single VM breached)"
elif breach_vms == 0:
    cap_text = f"Pool <b>{pool}</b> sustains <b>{capacity} VMs</b> at {rate} IOPS/VM without SLA breach (not saturated)"
else:
    cap_text = f"Pool <b>{pool}</b> supports <b>{capacity} VMs</b> at {rate} IOPS/VM ({total_iops:,.0f} aggregate IOPS) before p99 exceeds {sla}ms"

if resource_ceiling:
    cap_text += " <em>(resource ceiling hit)</em>"

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Scale Test: {pool} @ {rate} IOPS/VM</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 1100px; margin: 0 auto; padding: 20px; background: #f4f4f4; }}
  h1 {{ color: #161616; }}
  .meta {{ color: #525252; font-size: 0.9em; margin-bottom: 20px; }}
  .capacity-box {{ background: #defbe6; border-left: 4px solid #198038; padding: 16px 20px; margin: 20px 0; font-size: 1.1em; border-radius: 4px; }}
  .capacity-box.warn {{ background: #fff8e1; border-left-color: #f1c21b; }}
  .capacity-box.fail {{ background: #fff1f1; border-left-color: #da1e28; }}
  .chart-container {{ background: white; padding: 20px; border-radius: 8px; margin: 20px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
  table {{ width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
  th {{ background: #161616; color: white; padding: 10px 12px; text-align: right; font-size: 0.85em; }}
  th:first-child {{ text-align: left; }}
  td {{ padding: 8px 12px; text-align: right; border-bottom: 1px solid #e0e0e0; font-size: 0.9em; }}
  td:first-child {{ text-align: left; }}
  tr:hover {{ background: #f4f4f4; }}
  .pass {{ color: #198038; font-weight: 600; }}
  .fail {{ color: #da1e28; font-weight: 600; }}
  .footer {{ color: #525252; font-size: 0.8em; margin-top: 30px; }}
</style>
</head>
<body>
<h1>Scale Test: {pool}</h1>
<div class="meta">
  <b>Storage Class:</b> {sc} &nbsp;|&nbsp;
  <b>Rate:</b> {rate} IOPS/VM &nbsp;|&nbsp;
  <b>SLA:</b> p99 &lt; {sla}ms<br>
  <b>Cluster:</b> {cluster_desc}<br>
  <b>Run:</b> {run_id} &nbsp;|&nbsp; <b>Date:</b> {timestamp}
</div>

<div class="capacity-box {'fail' if capacity == 0 else 'warn' if breach_vms == 0 else ''}">
  {cap_text}
</div>

<div class="chart-container">
  <canvas id="rampChart" height="100"></canvas>
</div>

<h2>Ramp Data</h2>
<table>
<tr>
  <th>VMs</th><th>Target IOPS</th><th>Read IOPS</th><th>Write IOPS</th>
  <th>BW (MB/s)</th><th>p50 (ms)</th><th>p95 (ms)</th><th>p99 (ms)</th><th>SLA</th>
</tr>
"""

for r in rows:
    sla_class = 'pass' if r['sla_pass'] == 'true' else 'fail'
    sla_label = 'PASS' if r['sla_pass'] == 'true' else 'FAIL'
    html += f"""<tr>
  <td>{r['vm_count']}</td><td>{r['rate_iops']}</td>
  <td>{float(r['total_read_iops']):,.0f}</td><td>{float(r['total_write_iops']):,.0f}</td>
  <td>{float(r['total_bw_mbs']):,.1f}</td><td>{r['avg_p50_ms']}</td>
  <td>{r['avg_p95_ms']}</td><td>{r['max_p99_ms']}</td>
  <td class="{sla_class}">{sla_label}</td>
</tr>
"""

html += f"""</table>

<div class="footer">
  CSV: {csv_file} &nbsp;|&nbsp; Summary: {summary_file}
</div>

<script>
const ctx = document.getElementById('rampChart').getContext('2d');
new Chart(ctx, {{
  type: 'line',
  data: {{
    labels: {json.dumps(vm_counts)},
    datasets: [
      {{
        label: 'Aggregate IOPS',
        data: {json.dumps(total_iops_series)},
        borderColor: '#0f62fe',
        backgroundColor: 'rgba(15, 98, 254, 0.1)',
        yAxisID: 'y-iops',
        tension: 0.2,
        pointBackgroundColor: {json.dumps(point_colors)},
        pointRadius: 6,
        pointHoverRadius: 8
      }},
      {{
        label: 'p99 Latency (ms)',
        data: {json.dumps(p99_series)},
        borderColor: '#da1e28',
        borderDash: [5, 5],
        yAxisID: 'y-lat',
        tension: 0.2,
        pointBackgroundColor: {json.dumps(point_colors)},
        pointRadius: 6,
        pointHoverRadius: 8
      }}
    ]
  }},
  options: {{
    responsive: true,
    interaction: {{ mode: 'index', intersect: false }},
    scales: {{
      x: {{ title: {{ display: true, text: 'VM Count' }} }},
      'y-iops': {{
        type: 'linear', position: 'left',
        title: {{ display: true, text: 'Aggregate IOPS' }},
        beginAtZero: true
      }},
      'y-lat': {{
        type: 'linear', position: 'right',
        title: {{ display: true, text: 'p99 Latency (ms)' }},
        beginAtZero: true,
        grid: {{ drawOnChartArea: false }}
      }}
    }},
    plugins: {{
      annotation: {{
        annotations: {{
          slaLine: {{
            type: 'line', yMin: {sla}, yMax: {sla},
            yScaleID: 'y-lat',
            borderColor: '#da1e28', borderWidth: 2, borderDash: [10, 5],
            label: {{ content: 'SLA: {sla}ms', display: true, position: 'start' }}
          }}
        }}
      }}
    }}
  }}
}});
</script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation@3"></script>
</body>
</html>"""

print(html)
PYEOF_SCALE
) > "${output_html}"

  log_info "Scale-test report generated: ${output_html}"
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n lib/report-helpers.sh`

Expected: no output (clean parse).

- [ ] **Step 3: Commit**

```bash
git add lib/report-helpers.sh
git commit -m "feat(report): add scale-test auto-ramp HTML report with Chart.js ramp curve"
```

---

### Task 5: Update `05-collect-results.sh` for scale-test results

**Files:**
- Modify: `05-collect-results.sh`

- [ ] **Step 1: Add scale-test results detection**

The scale-test ramp generates its own `ramp.csv` per-step, so `05-collect-results.sh` doesn't need to aggregate it the same way as the normal matrix. Add a check after the existing aggregation that detects and logs scale-test results.

After the existing `aggregate_results_csv` call and summary generation (around line 75), add:

```bash
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n 05-collect-results.sh`

Expected: no output (clean parse).

- [ ] **Step 3: Commit**

```bash
git add 05-collect-results.sh
git commit -m "feat(collect): detect and summarise scale-test ramp results"
```

---

### Task 6: Update `run-all.sh` passthrough and help text

**Files:**
- Modify: `run-all.sh:32-65`

- [ ] **Step 1: Update help text**

Replace the `--scale-test` help line:

```bash
# OLD:
      echo "  --scale-test         Scale test: 200-VM tests (NFS dp2, ODF rep3, NFS rfs)"
```

With:

```bash
      echo "  --scale-test         Auto-ramp: double VMs until p99 breaches SLA (requires --pool)"
      echo "  --rate-iops <N>      Per-VM IOPS cap for scale-test (default: 500)"
      echo "  --latency-sla <ms>   p99 latency SLA in ms for scale-test (default: 5)"
```

- [ ] **Step 2: Verify passthrough works**

The `run-all.sh` already passes unknown flags through via `PASSTHROUGH_ARGS`. Verify:

Run: `./run-all.sh --scale-test --pool rep3 --rate-iops 1000 --dry-run --no-reports`

Expected: the dry-run preview from `04-run-tests.sh` with rate_iops=1000.

- [ ] **Step 3: Commit**

```bash
git add run-all.sh
git commit -m "feat(run-all): update help text for scale-test auto-ramp flags"
```

---

### Task 7: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Key Commands section**

In the `04-run-tests.sh` command listing, replace the scale-test line and add the new variants:

```bash
# OLD:
./04-run-tests.sh --scale-test  # (remove any existing scale-test lines)
```

With:

```bash
./04-run-tests.sh --scale-test --pool rep3           # Auto-ramp: find VM ceiling at 500 IOPS/VM, p99 < 5ms
./04-run-tests.sh --scale-test --pool rep3 --rate-iops 1000 --latency-sla 10  # Custom rate/SLA
./04-run-tests.sh --scale-test --pool rep3 --dry-run  # Preview ramp plan
```

- [ ] **Step 2: Add a Scale Test section after the StorageClass Ranking section**

```markdown
### Scale Test Auto-Ramp (`--scale-test`)

A capacity planning mode that progressively increases VM count to find the density ceiling for a storage pool. Requires `--pool`.

**Phase 1 (Doubling):** Starts at 1 VM, doubles each step (1 → 2 → 4 → 8 → ...) until p99 write latency exceeds the SLA threshold or VM creation fails (resource exhaustion).

**Phase 2 (Backfill):** Between the last passing count and first failing count, steps linearly (`step = max(1, gap/4)`) to find the precise tipping point.

Each step creates all VMs fresh, runs `mixed-70-30-rated.fio` at the configured `rate_iops`, collects results, extracts the worst-case p99 across all VMs, and deletes VMs before proceeding.

| Flag | Default | Description |
|------|---------|-------------|
| `--pool <name>` | required | Storage pool to ramp |
| `--rate-iops <N>` | 500 | Per-VM IOPS cap |
| `--latency-sla <ms>` | 5 | p99 latency threshold (ms) |

Settings: small VM (2 vCPU, 4Gi), 150Gi PVC, QD32, numjobs=1, 10G file, mixed 70/30 read/write at 4k. Hard ceiling at 256 VMs (`SCALE_MAX_VMS`).

Results: `results/<run-id>/scale-test/<pool>/ramp.csv` + `ramp-summary.json`. HTML report: `reports/scale-test-<pool>-<rate>iops-<run-id>.html` with dual-axis ramp chart (IOPS + p99 latency vs VM count).
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add scale-test auto-ramp documentation to CLAUDE.md"
```
