#!/usr/bin/env bash
# =============================================================================
# 04-run-tests.sh — Main orchestrator for VM storage performance tests
#
# Runs the full test matrix:
#   storage_pools × vm_sizes × pvc_sizes × concurrency × fio_profiles × block_sizes
#
# VMs are created once per (pool × vm_size × pvc_size × concurrency) group and
# reused across fio_profile × block_size permutations — fio job files are replaced
# via SSH and the benchmark service restarted, avoiding redundant VM lifecycle.
#
# Usage:
#   ./04-run-tests.sh                    # Full matrix
#   ./04-run-tests.sh --pool rep3        # Single pool
#   ./04-run-tests.sh --quick            # Quick smoke test (1 size, 1 concurrency)
#   ./04-run-tests.sh --overview         # All-pool comparison (~2 hours)
#   ./04-run-tests.sh --parallel         # Run pools in parallel (auto-scaled)
#   ./04-run-tests.sh --parallel 3       # Run 3 pools in parallel
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"
source "${SCRIPT_DIR}/lib/wait-helpers.sh"

# ---------------------------------------------------------------------------
# Parse CLI args
# ---------------------------------------------------------------------------
FILTER_POOL=""
QUICK_MODE=false
OVERVIEW_MODE=false
PARALLEL_POOLS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool)     FILTER_POOL="$2"; shift 2 ;;
    --quick)    QUICK_MODE=true; shift ;;
    --overview) OVERVIEW_MODE=true; shift ;;
    --parallel)
      if [[ $# -gt 1 ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
        PARALLEL_POOLS="$2"; shift 2
      else
        PARALLEL_POOLS="auto"; shift
      fi
      ;;
    --help)
      echo "Usage: $0 [--pool <name>] [--quick] [--overview] [--parallel [N]]"
      echo "  --pool <name>    Test only a specific storage pool"
      echo "  --quick          Quick mode: small VM, 150Gi PVC, concurrency=1 only"
      echo "  --overview       Overview mode: 2 tests/pool (random 4k + sequential 1M) across all pools"
      echo "  --parallel [N]   Run pools in parallel (auto-scale to cluster capacity, or specify N)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Mutual exclusivity guard
if [[ "${QUICK_MODE}" == true && "${OVERVIEW_MODE}" == true ]]; then
  echo "Error: --quick and --overview are mutually exclusive" >&2
  exit 1
fi

# Override for quick mode
if [[ "${QUICK_MODE}" == true ]]; then
  VM_SIZES=("small:2:4Gi")
  PVC_SIZES=("150Gi")
  CONCURRENCY_LEVELS=(1)
  FIO_BLOCK_SIZES=("4k" "1M")
  FIO_PROFILES=("random-rw" "sequential-rw")
  log_info "Quick mode enabled — reduced test matrix"
fi

# Override for overview mode
if [[ "${OVERVIEW_MODE}" == true ]]; then
  VM_SIZES=("small:2:4Gi")
  PVC_SIZES=("150Gi")
  CONCURRENCY_LEVELS=(1)
  FIO_BLOCK_SIZES=("4k" "1M")
  FIO_PROFILES=("random-rw" "sequential-rw")
  log_info "Overview mode enabled — 2 tests per pool (random-rw/4k + sequential-rw/1M)"
fi

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "${RESULTS_DIR}" "${REPORTS_DIR}"
ensure_ssh_key

# Get all storage pools
mapfile -t ALL_POOLS < <(get_all_storage_pools)

if [[ -n "${FILTER_POOL}" ]]; then
  ALL_POOLS=("${FILTER_POOL}")
  log_info "Filtering to pool: ${FILTER_POOL}"
fi

# ---------------------------------------------------------------------------
# Auto-scale parallel pools based on cluster capacity
# ---------------------------------------------------------------------------
calculate_max_parallel_pools() {
  local total_mem_gi total_cpu

  # Query total allocatable memory from worker nodes and convert to GiB.
  # Kubernetes quantities may use suffixes: m (milli), Ki, Mi, Gi, or bare bytes.
  total_mem_gi=$(oc get nodes -l node-role.kubernetes.io/worker= \
    -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' | \
    awk '{
      val=$1
      if (val ~ /m$/) { gsub(/m$/,"",val); bytes=val/1000 }
      else if (val ~ /Ki$/) { gsub(/Ki$/,"",val); bytes=val*1024 }
      else if (val ~ /Mi$/) { gsub(/Mi$/,"",val); bytes=val*1048576 }
      else if (val ~ /Gi$/) { gsub(/Gi$/,"",val); bytes=val*1073741824 }
      else { bytes=val+0 }
      s += bytes
    } END { printf "%.0f", s/1073741824 }')

  # Query total allocatable CPU from worker nodes and convert to whole cores.
  # Values may be in millicores (e.g. "95680m") or whole cores (e.g. "96").
  total_cpu=$(oc get nodes -l node-role.kubernetes.io/worker= \
    -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' | \
    awk '{
      val=$1
      if (val ~ /m$/) { gsub(/m$/,"",val); cores=val/1000 }
      else { cores=val+0 }
      s += cores
    } END { printf "%.0f", s }')

  # Reserve 40% for system pods, ODF, kubevirt, etc.
  local avail_mem_gi=$(( total_mem_gi * 60 / 100 ))
  local avail_cpu=$(( total_cpu * 60 / 100 ))

  # Calculate peak per pool: max(concurrency) × max(VM memory/cpu)
  local max_conc=0 max_vm_mem=0 max_vm_cpu=0
  for level in "${CONCURRENCY_LEVELS[@]}"; do
    [[ ${level} -gt ${max_conc} ]] && max_conc=${level}
  done
  for vm_def in "${VM_SIZES[@]}"; do
    IFS=':' read -r _ vcpu mem <<< "${vm_def}"
    local mem_val=${mem%Gi}
    [[ ${mem_val} -gt ${max_vm_mem} ]] && max_vm_mem=${mem_val}
    [[ ${vcpu} -gt ${max_vm_cpu} ]] && max_vm_cpu=${vcpu}
  done

  local peak_mem_per_pool=$(( max_conc * max_vm_mem ))
  local peak_cpu_per_pool=$(( max_conc * max_vm_cpu ))

  # Guard against division by zero
  [[ ${peak_mem_per_pool} -eq 0 ]] && peak_mem_per_pool=1
  [[ ${peak_cpu_per_pool} -eq 0 ]] && peak_cpu_per_pool=1

  # Max parallel = min(mem-limited, cpu-limited, pool-count)
  local max_by_mem=$(( avail_mem_gi / peak_mem_per_pool ))
  local max_by_cpu=$(( avail_cpu / peak_cpu_per_pool ))
  local result=$(( max_by_mem < max_by_cpu ? max_by_mem : max_by_cpu ))
  [[ ${result} -lt 1 ]] && result=1
  [[ ${result} -gt ${#ALL_POOLS[@]} ]] && result=${#ALL_POOLS[@]}

  log_info "Auto-parallel: ${avail_mem_gi}Gi mem, ${avail_cpu} CPU available → ${result} concurrent pools (peak/pool: ${peak_mem_per_pool}Gi, ${peak_cpu_per_pool} CPU)"
  echo "${result}"
}

# Resolve PARALLEL_POOLS if "auto"
if [[ "${PARALLEL_POOLS}" == "auto" ]]; then
  PARALLEL_POOLS=$(calculate_max_parallel_pools)
fi

log_info "=== VM Storage Performance Test Suite ==="
log_info "Run ID:        ${RUN_ID}"
log_info "Pools:         ${ALL_POOLS[*]}"
log_info "VM Sizes:      ${VM_SIZES[*]}"
log_info "PVC Sizes:     ${PVC_SIZES[*]}"
log_info "Concurrency:   ${CONCURRENCY_LEVELS[*]}"
log_info "fio Profiles:  ${FIO_PROFILES[*]}"
log_info "Block Sizes:   ${FIO_BLOCK_SIZES[*]}"
if [[ "${PARALLEL_POOLS}" -gt 1 ]]; then
  log_info "Parallel:      ${PARALLEL_POOLS} pools"
fi

# ---------------------------------------------------------------------------
# Trap handler — clean up running VMs on interruption
# ---------------------------------------------------------------------------
cleanup_on_exit() {
  trap - INT TERM   # Disarm — next Ctrl+C exits immediately
  log_warn "Interrupted — cleaning up running VMs..."
  # Kill any background pool jobs
  kill $(jobs -rp) 2>/dev/null || true
  wait 2>/dev/null || true
  oc delete vm -n "${TEST_NAMESPACE}" -l "perf-test/run-id=${RUN_ID}" --wait=false 2>/dev/null || true
  oc delete secret -n "${TEST_NAMESPACE}" -l "perf-test/run-id=${RUN_ID}" --wait=false 2>/dev/null || true
  oc delete pvc -n "${TEST_NAMESPACE}" -l "perf-test/run-id=${RUN_ID}" --wait=false 2>/dev/null || true
  exit 130
}
trap cleanup_on_exit INT TERM

# ---------------------------------------------------------------------------
# Helper: check if a profile defines its own block sizes
# ---------------------------------------------------------------------------
is_fixed_bs_profile() {
  local profile="$1"
  printf '%s\n' "${FIO_FIXED_BS_PROFILES[@]}" | grep -qx "${profile}"
}

# ---------------------------------------------------------------------------
# Calculate test count for a single pool (same matrix for all pools)
# ---------------------------------------------------------------------------
calculate_pool_tests() {
  local count=0
  for _ in "${VM_SIZES[@]}"; do
    for _ in "${PVC_SIZES[@]}"; do
      for _ in "${CONCURRENCY_LEVELS[@]}"; do
        for fio_profile in "${FIO_PROFILES[@]}"; do
          if is_fixed_bs_profile "${fio_profile}"; then
            ((count += 1))
          else
            for block_size in "${FIO_BLOCK_SIZES[@]}"; do
              if [[ "${OVERVIEW_MODE}" == true ]]; then
                [[ "${fio_profile}" == "random-rw" && "${block_size}" != "4k" ]] && continue
                [[ "${fio_profile}" == "sequential-rw" && "${block_size}" != "1M" ]] && continue
              fi
              ((count += 1))
            done
          fi
        done
      done
    done
  done
  echo "${count}"
}

pool_test_count=$(calculate_pool_tests)
total_tests=$(( pool_test_count * ${#ALL_POOLS[@]} ))
log_info "Total test permutations: ${total_tests}"

# ---------------------------------------------------------------------------
# Run all tests for a single storage pool
# ---------------------------------------------------------------------------
run_single_pool() {
  local pool_name="$1"

  # Per-pool tracking
  local pool_start_time pool_tests pool_passed pool_total_tests
  local test_num=0
  local failed_tests=0
  local skipped_tests=0

  pool_start_time=$(date +%s)
  pool_tests=0
  pool_passed=0
  pool_total_tests="${pool_test_count}"

  local local_sc
  local_sc=$(get_storage_class_for_pool "${pool_name}")

  # Verify StorageClass exists
  if ! oc get sc "${local_sc}" &>/dev/null; then
    log_warn "[${pool_name}] StorageClass ${local_sc} not found — skipping pool"
    mkdir -p "${RESULTS_DIR}/${pool_name}"
    echo "0 0 0 ${pool_total_tests}" > "${RESULTS_DIR}/${pool_name}/.pool-summary"
    return 0
  fi

  # Verify pool health for custom ODF pools (rep3 uses default cluster pool)
  local odf_pool_name="perf-test-${pool_name}"
  if oc get cephblockpool "${odf_pool_name}" -n "${ODF_NAMESPACE}" &>/dev/null; then
    local pool_phase
    pool_phase=$(oc get cephblockpool "${odf_pool_name}" -n "${ODF_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    if [[ "${pool_phase}" != "Ready" ]]; then
      log_warn "[${pool_name}] CephBlockPool ${odf_pool_name} is not Ready (phase=${pool_phase}) — skipping pool"
      mkdir -p "${RESULTS_DIR}/${pool_name}"
      echo "0 0 0 ${pool_total_tests}" > "${RESULTS_DIR}/${pool_name}/.pool-summary"
      return 0
    fi
  fi

  for vm_size_def in "${VM_SIZES[@]}"; do
    IFS=':' read -r size_label vcpu memory <<< "${vm_size_def}"

    for pvc_size in "${PVC_SIZES[@]}"; do

      for concurrency in "${CONCURRENCY_LEVELS[@]}"; do

        # -----------------------------------------------------------------
        # Build ordered list of (profile, block_size) permutations for group
        # -----------------------------------------------------------------
        local -a group_profiles=()
        local -a group_block_sizes=()

        for fio_profile in "${FIO_PROFILES[@]}"; do
          local profile_path="${SCRIPT_DIR}/fio-profiles/${fio_profile}.fio"

          if [[ ! -f "${profile_path}" ]]; then
            log_warn "[${pool_name}] fio profile not found: ${profile_path}"
            ((skipped_tests += 1))
            continue
          fi

          if is_fixed_bs_profile "${fio_profile}"; then
            group_profiles+=("${fio_profile}")
            group_block_sizes+=("native")
          else
            for block_size in "${FIO_BLOCK_SIZES[@]}"; do
              # Overview mode: only pair each profile with its most informative block size
              if [[ "${OVERVIEW_MODE}" == true ]]; then
                [[ "${fio_profile}" == "random-rw" && "${block_size}" != "4k" ]] && continue
                [[ "${fio_profile}" == "sequential-rw" && "${block_size}" != "1M" ]] && continue
              fi
              group_profiles+=("${fio_profile}")
              group_block_sizes+=("${block_size}")
            done
          fi
        done

        local group_size=${#group_profiles[@]}
        if [[ ${group_size} -eq 0 ]]; then
          continue
        fi

        # =================================================================
        # First permutation — create VMs with cloud-init baked fio job
        # =================================================================
        local first_profile="${group_profiles[0]}"
        local first_bs="${group_block_sizes[0]}"
        ((test_num += 1))

        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "[${pool_name}] Test ${test_num}/${pool_total_tests}: vm=${size_label} pvc=${pvc_size} conc=${concurrency} profile=${first_profile} bs=${first_bs}"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        local test_start_time
        test_start_time=$(date +%s)
        local test_failed=false
        ((pool_tests += 1))

        # Results directory for this specific test
        local test_results_dir="${RESULTS_DIR}/${pool_name}/${size_label}/${pvc_size}/${concurrency}/${first_profile}/${first_bs}"
        mkdir -p "${test_results_dir}"

        # Render fio profile with current block size
        local first_profile_path="${SCRIPT_DIR}/fio-profiles/${first_profile}.fio"
        local rendered_fio
        rendered_fio=$(render_fio_profile "${first_profile_path}" "${first_bs}")

        # Render cloud-init with the fio job
        local cloud_init_content
        cloud_init_content=$(render_cloud_init \
          "${SCRIPT_DIR}/cloud-init/fio-runner.yaml" \
          "${rendered_fio}" \
          "perf-vm" \
          "/mnt/data")

        # Create VMs (names shared across the group — no profile/bs suffix)
        local -a vm_names=()
        local vm_create_failed=false
        for ((i=1; i<=concurrency; i++)); do
          local vm_name="perf-${pool_name}-${size_label}-${pvc_size,,}-c${concurrency}-${i}"
          # Truncate to 63 chars (K8s name limit) and sanitize
          vm_name=$(echo "${vm_name}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | head -c 63 | sed 's/-$//')
          vm_names+=("${vm_name}")

          create_test_vm \
            "${vm_name}" \
            "${local_sc}" \
            "${pvc_size}" \
            "${vcpu}" \
            "${memory}" \
            "${cloud_init_content}" \
            "${pool_name}" \
            "${size_label}" \
            "${SCRIPT_DIR}/vm-templates/vm-template.yaml" || {
              log_error "[${pool_name}] Failed to create VM ${vm_name}"
              vm_create_failed=true
              break
            }
        done

        # On VM creation failure, skip the entire group
        if [[ "${vm_create_failed}" == "true" ]]; then
          local skip_count=$(( group_size - 1 ))
          ((failed_tests += 1))
          ((skipped_tests += skip_count))
          ((test_num += skip_count))
          for vm in "${vm_names[@]}"; do
            delete_test_vm "${vm}" &
          done
          wait
          local test_elapsed=$(( $(date +%s) - test_start_time ))
          log_info "[${pool_name}] Test ${test_num}/${pool_total_tests} FAILED in $(_format_duration ${test_elapsed}) — skipping ${skip_count} remaining permutations in group"
          continue
        fi

        # Wait for all VMs to be running
        if ! wait_for_all_vms_running "${vm_names[@]}"; then
          log_error "[${pool_name}] Not all VMs started — cleaning up and skipping group"
          for vm in "${vm_names[@]}"; do
            delete_test_vm "${vm}" &
          done
          wait
          local skip_count=$(( group_size - 1 ))
          ((failed_tests += 1))
          ((skipped_tests += skip_count))
          ((test_num += skip_count))
          test_failed=true
          local test_elapsed=$(( $(date +%s) - test_start_time ))
          log_info "[${pool_name}] Test ${test_num}/${pool_total_tests} FAILED in $(_format_duration ${test_elapsed}) — skipping ${skip_count} remaining permutations in group"
          continue
        fi

        # Wait for fio to complete in all VMs (first run via cloud-init)
        if ! wait_for_all_fio_complete "${vm_names[@]}"; then
          log_warn "[${pool_name}] Some fio tests did not complete successfully"
          test_failed=true
        fi

        # Collect results from all VMs (parallel — each VM writes to a unique file)
        local -a collect_pids=()
        for vm in "${vm_names[@]}"; do
          collect_vm_results "${vm}" "${test_results_dir}" &
          collect_pids+=($!)
        done
        for pid in "${collect_pids[@]}"; do
          wait "${pid}" || true
        done

        # Per-test timing for first permutation
        if [[ "${test_failed}" != "true" ]]; then
          ((pool_passed += 1))
        else
          ((failed_tests += 1))
        fi
        local test_elapsed=$(( $(date +%s) - test_start_time ))
        local pool_elapsed=$(( $(date +%s) - pool_start_time ))
        if [[ "${test_failed}" != "true" ]]; then
          log_info "[${pool_name}] Test ${test_num}/${pool_total_tests} completed in $(_format_duration ${test_elapsed})"
        else
          log_info "[${pool_name}] Test ${test_num}/${pool_total_tests} FAILED in $(_format_duration ${test_elapsed})"
        fi
        if [[ ${test_num} -lt ${pool_total_tests} ]]; then
          local tests_remaining=$(( pool_total_tests - test_num ))
          local avg_per_test=$(( pool_elapsed / test_num ))
          local eta=$(( avg_per_test * tests_remaining ))
          log_info "[${pool_name}] Progress: ${test_num}/${pool_total_tests} tests done, $(_format_duration ${pool_elapsed}) elapsed, ~$(_format_duration ${eta}) remaining"
        fi

        # =================================================================
        # Subsequent permutations — reuse VMs via SSH fio job replacement
        # =================================================================
        for ((perm_idx=1; perm_idx<group_size; perm_idx++)); do
          local fio_profile="${group_profiles[${perm_idx}]}"
          local block_size="${group_block_sizes[${perm_idx}]}"
          ((test_num += 1))

          log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          log_info "[${pool_name}] Test ${test_num}/${pool_total_tests}: vm=${size_label} pvc=${pvc_size} conc=${concurrency} profile=${fio_profile} bs=${block_size}"
          log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

          test_start_time=$(date +%s)
          test_failed=false
          ((pool_tests += 1))

          test_results_dir="${RESULTS_DIR}/${pool_name}/${size_label}/${pvc_size}/${concurrency}/${fio_profile}/${block_size}"
          mkdir -p "${test_results_dir}"

          local profile_path="${SCRIPT_DIR}/fio-profiles/${fio_profile}.fio"
          rendered_fio=$(render_fio_profile "${profile_path}" "${block_size}")

          # Replace fio job and restart service in all VMs (parallel)
          local reuse_failed=false
          local -a swap_pids=()
          local -A swap_pid_to_vm=()
          for vm in "${vm_names[@]}"; do
            (
              replace_fio_job "${vm}" "${rendered_fio}" && restart_fio_service "${vm}"
            ) &
            swap_pids+=($!)
            swap_pid_to_vm[$!]="${vm}"
          done
          for pid in "${swap_pids[@]}"; do
            if ! wait "${pid}"; then
              log_error "[${pool_name}] Failed to swap fio job in ${swap_pid_to_vm[${pid}]}"
              reuse_failed=true
            fi
          done

          if [[ "${reuse_failed}" == "true" ]]; then
            ((failed_tests += 1))
            test_failed=true
            test_elapsed=$(( $(date +%s) - test_start_time ))
            log_info "[${pool_name}] Test ${test_num}/${pool_total_tests} FAILED in $(_format_duration ${test_elapsed})"
            continue
          fi

          # Wait for fio to complete
          if ! wait_for_all_fio_complete "${vm_names[@]}"; then
            log_warn "[${pool_name}] Some fio tests did not complete successfully"
            test_failed=true
          fi

          # Collect results (parallel)
          collect_pids=()
          for vm in "${vm_names[@]}"; do
            collect_vm_results "${vm}" "${test_results_dir}" &
            collect_pids+=($!)
          done
          for pid in "${collect_pids[@]}"; do
            wait "${pid}" || true
          done

          # Per-test timing and progress
          if [[ "${test_failed}" != "true" ]]; then
            ((pool_passed += 1))
          else
            ((failed_tests += 1))
          fi
          test_elapsed=$(( $(date +%s) - test_start_time ))
          pool_elapsed=$(( $(date +%s) - pool_start_time ))
          if [[ "${test_failed}" != "true" ]]; then
            log_info "[${pool_name}] Test ${test_num}/${pool_total_tests} completed in $(_format_duration ${test_elapsed})"
          else
            log_info "[${pool_name}] Test ${test_num}/${pool_total_tests} FAILED in $(_format_duration ${test_elapsed})"
          fi
          if [[ ${test_num} -lt ${pool_total_tests} ]]; then
            local tests_remaining=$(( pool_total_tests - test_num ))
            local avg_per_test=$(( pool_elapsed / test_num ))
            local eta=$(( avg_per_test * tests_remaining ))
            log_info "[${pool_name}] Progress: ${test_num}/${pool_total_tests} tests done, $(_format_duration ${pool_elapsed}) elapsed, ~$(_format_duration ${eta}) remaining"
          fi

          # Brief pause between tests to let storage settle
          sleep 5

        done  # permutation loop

        # =================================================================
        # Cleanup VMs after all permutations in this group
        # =================================================================
        log_info "[${pool_name}] Cleaning up VMs for this group..."
        for vm in "${vm_names[@]}"; do
          delete_test_vm "${vm}" &
        done
        wait

        # Brief pause between groups to let storage settle
        sleep 5

      done  # concurrency
    done  # pvc_size
  done  # vm_size

  # Per-pool summary
  local pool_elapsed=$(( $(date +%s) - pool_start_time ))
  if [[ ${pool_tests} -gt 0 ]]; then
    log_info "[${pool_name}] Pool complete: ${pool_passed}/${pool_tests} passed in $(_format_duration ${pool_elapsed})"
  fi

  # Write summary file for aggregation
  mkdir -p "${RESULTS_DIR}/${pool_name}"
  echo "${pool_tests} ${pool_passed} ${failed_tests} ${skipped_tests}" \
    > "${RESULTS_DIR}/${pool_name}/.pool-summary"
}

# ---------------------------------------------------------------------------
# Main test execution
# ---------------------------------------------------------------------------
suite_start_time=$(date +%s)

if [[ "${PARALLEL_POOLS}" -gt 1 ]]; then
  log_info "Running up to ${PARALLEL_POOLS} pools in parallel"
  declare -a pool_pids=()
  for pool_name in "${ALL_POOLS[@]}"; do
    # Job queue: wait for a slot if at capacity
    while [[ $(jobs -rp | wc -l) -ge ${PARALLEL_POOLS} ]]; do
      sleep 2
    done
    mkdir -p "${RESULTS_DIR}/${pool_name}"
    run_single_pool "${pool_name}" > "${RESULTS_DIR}/${pool_name}/pool.log" 2>&1 &
    pool_pids+=($!)
    log_info "  Started pool ${pool_name} (pid $!)"
  done
  # Wait for all remaining
  for pid in "${pool_pids[@]}"; do
    wait "${pid}" || true
  done
else
  # Sequential (original behavior, preserves existing output)
  for pool_name in "${ALL_POOLS[@]}"; do
    run_single_pool "${pool_name}"
  done
fi

# ---------------------------------------------------------------------------
# Summary — aggregate from .pool-summary files
# ---------------------------------------------------------------------------
suite_elapsed=$(( $(date +%s) - suite_start_time ))

total_run=0
total_passed=0
total_failed=0
total_skipped=0

for pool_name in "${ALL_POOLS[@]}"; do
  summary_file="${RESULTS_DIR}/${pool_name}/.pool-summary"
  if [[ -f "${summary_file}" ]]; then
    read -r pt pp pf ps < "${summary_file}"
    (( total_run += pt )) || true
    (( total_passed += pp )) || true
    (( total_failed += pf )) || true
    (( total_skipped += ps )) || true
  fi
done

log_info "=== Test Suite Complete ==="
log_info "Total tests: ${total_tests}"
log_info "Passed: ${total_passed}, Failed: ${total_failed}, Skipped: ${total_skipped}"
if [[ ${total_run} -gt 0 ]]; then
  avg_per_test=$(( suite_elapsed / total_run ))
  log_info "Total time: $(_format_duration ${suite_elapsed}) (avg $(_format_duration ${avg_per_test})/test)"
else
  log_info "Total time: $(_format_duration ${suite_elapsed})"
fi
log_info "Results in: ${RESULTS_DIR}"

if [[ "${PARALLEL_POOLS}" -gt 1 ]]; then
  log_info ""
  log_info "Per-pool results:"
  for pool_name in "${ALL_POOLS[@]}"; do
    summary_file="${RESULTS_DIR}/${pool_name}/.pool-summary"
    if [[ -f "${summary_file}" ]]; then
      read -r pt pp pf ps < "${summary_file}"
      log_info "  ${pool_name}: ${pp}/${pt} passed, ${pf} failed, ${ps} skipped (log: ${RESULTS_DIR}/${pool_name}/pool.log)"
    fi
  done
fi

log_info ""
log_info "Next steps:"
log_info "  1. Run ./05-collect-results.sh to aggregate results"
log_info "  2. Run ./06-generate-report.sh to create reports"
log_info "  3. Run ./07-cleanup.sh to remove storage pools (optional)"
