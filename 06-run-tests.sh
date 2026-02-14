#!/usr/bin/env bash
# =============================================================================
# 06-run-tests.sh — Main orchestrator for VM storage performance tests
#
# Runs the full test matrix:
#   storage_pools × vm_sizes × pvc_sizes × concurrency × fio_profiles × block_sizes
#
# VMs are created once per (pool × vm_size × pvc_size × concurrency) group and
# reused across fio_profile × block_size permutations — fio job files are replaced
# via SSH and the benchmark service restarted, avoiding redundant VM lifecycle.
#
# Usage:
#   ./06-run-tests.sh                    # Full matrix
#   ./06-run-tests.sh --pool rep3        # Single pool
#   ./06-run-tests.sh --quick            # Quick smoke test (1 size, 1 concurrency)
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool)   FILTER_POOL="$2"; shift 2 ;;
    --quick)  QUICK_MODE=true; shift ;;
    --help)
      echo "Usage: $0 [--pool <name>] [--quick]"
      echo "  --pool <name>  Test only a specific storage pool"
      echo "  --quick        Quick mode: small VM, 50Gi PVC, concurrency=1 only"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Override for quick mode
if [[ "${QUICK_MODE}" == true ]]; then
  VM_SIZES=("small:2:4Gi")
  PVC_SIZES=("50Gi")
  CONCURRENCY_LEVELS=(1)
  FIO_BLOCK_SIZES=("4k" "1M")
  FIO_PROFILES=("random-rw" "sequential-rw")
  log_info "Quick mode enabled — reduced test matrix"
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

log_info "=== VM Storage Performance Test Suite ==="
log_info "Run ID:        ${RUN_ID}"
log_info "Pools:         ${ALL_POOLS[*]}"
log_info "VM Sizes:      ${VM_SIZES[*]}"
log_info "PVC Sizes:     ${PVC_SIZES[*]}"
log_info "Concurrency:   ${CONCURRENCY_LEVELS[*]}"
log_info "fio Profiles:  ${FIO_PROFILES[*]}"
log_info "Block Sizes:   ${FIO_BLOCK_SIZES[*]}"

# ---------------------------------------------------------------------------
# Trap handler — clean up running VMs on interruption
# ---------------------------------------------------------------------------
cleanup_on_exit() {
  trap - INT TERM   # Disarm — next Ctrl+C exits immediately
  log_warn "Interrupted — cleaning up running VMs..."
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
# Calculate total tests (accounting for fixed-blocksize profiles)
# ---------------------------------------------------------------------------
total_tests=0
for _ in "${ALL_POOLS[@]}"; do
  for _ in "${VM_SIZES[@]}"; do
    for _ in "${PVC_SIZES[@]}"; do
      for _ in "${CONCURRENCY_LEVELS[@]}"; do
        for fio_profile in "${FIO_PROFILES[@]}"; do
          if is_fixed_bs_profile "${fio_profile}"; then
            ((total_tests += 1))
          else
            for _ in "${FIO_BLOCK_SIZES[@]}"; do
              ((total_tests += 1))
            done
          fi
        done
      done
    done
  done
done
log_info "Total test permutations: ${total_tests}"

# ---------------------------------------------------------------------------
# Run test matrix
# ---------------------------------------------------------------------------
run_test_matrix() {
  local test_num=0
  local failed_tests=0
  local skipped_tests=0

  for pool_name in "${ALL_POOLS[@]}"; do
    # Per-pool tracking
    local pool_start_time pool_tests pool_passed
    pool_start_time=$(date +%s)
    pool_tests=0
    pool_passed=0

    local local_sc
    local_sc=$(get_storage_class_for_pool "${pool_name}")

    # Verify StorageClass exists
    if ! oc get sc "${local_sc}" &>/dev/null; then
      log_warn "StorageClass ${local_sc} not found — skipping pool ${pool_name}"
      continue
    fi

    # Verify pool health for custom ODF pools (rep3 uses default cluster pool)
    local odf_pool_name="perf-test-${pool_name}"
    if oc get cephblockpool "${odf_pool_name}" -n "${ODF_NAMESPACE}" &>/dev/null; then
      local pool_phase
      pool_phase=$(oc get cephblockpool "${odf_pool_name}" -n "${ODF_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
      if [[ "${pool_phase}" != "Ready" ]]; then
        log_warn "CephBlockPool ${odf_pool_name} is not Ready (phase=${pool_phase}) — skipping pool ${pool_name}"
        ((skipped_tests += 1))
        continue
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
            local profile_path="${SCRIPT_DIR}/05-fio-profiles/${fio_profile}.fio"

            if [[ ! -f "${profile_path}" ]]; then
              log_warn "fio profile not found: ${profile_path}"
              ((skipped_tests += 1))
              continue
            fi

            if is_fixed_bs_profile "${fio_profile}"; then
              group_profiles+=("${fio_profile}")
              group_block_sizes+=("native")
            else
              for block_size in "${FIO_BLOCK_SIZES[@]}"; do
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
          log_info "Test ${test_num}/${total_tests}: pool=${pool_name} vm=${size_label} pvc=${pvc_size} conc=${concurrency} profile=${first_profile} bs=${first_bs}"
          log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

          local test_start_time
          test_start_time=$(date +%s)
          local test_failed=false
          ((pool_tests += 1))

          # Results directory for this specific test
          local test_results_dir="${RESULTS_DIR}/${pool_name}/${size_label}/${pvc_size}/${concurrency}/${first_profile}/${first_bs}"
          mkdir -p "${test_results_dir}"

          # Render fio profile with current block size
          local first_profile_path="${SCRIPT_DIR}/05-fio-profiles/${first_profile}.fio"
          local rendered_fio
          rendered_fio=$(render_fio_profile "${first_profile_path}" "${first_bs}")

          # Render cloud-init with the fio job
          local cloud_init_content
          cloud_init_content=$(render_cloud_init \
            "${SCRIPT_DIR}/03-cloud-init/fio-runner.yaml" \
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
              "${SCRIPT_DIR}/04-vm-templates/vm-template.yaml" || {
                log_error "Failed to create VM ${vm_name}"
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
            log_info "Test ${test_num}/${total_tests} FAILED in $(_format_duration ${test_elapsed}) — skipping ${skip_count} remaining permutations in group"
            continue
          fi

          # Wait for all VMs to be running
          if ! wait_for_all_vms_running "${vm_names[@]}"; then
            log_error "Not all VMs started — cleaning up and skipping group"
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
            log_info "Test ${test_num}/${total_tests} FAILED in $(_format_duration ${test_elapsed}) — skipping ${skip_count} remaining permutations in group"
            continue
          fi

          # Wait for fio to complete in all VMs (first run via cloud-init)
          if ! wait_for_all_fio_complete "${vm_names[@]}"; then
            log_warn "Some fio tests did not complete successfully"
            test_failed=true
          fi

          # Collect results from all VMs
          for vm in "${vm_names[@]}"; do
            collect_vm_results "${vm}" "${test_results_dir}" || true
          done

          # Per-test timing for first permutation
          if [[ "${test_failed}" != "true" ]]; then
            ((pool_passed += 1))
          else
            ((failed_tests += 1))
          fi
          local test_elapsed=$(( $(date +%s) - test_start_time ))
          local suite_elapsed=$(( $(date +%s) - suite_start_time ))
          if [[ "${test_failed}" != "true" ]]; then
            log_info "Test ${test_num}/${total_tests} completed in $(_format_duration ${test_elapsed}) (pool=${pool_name} profile=${first_profile} bs=${first_bs})"
          else
            log_info "Test ${test_num}/${total_tests} FAILED in $(_format_duration ${test_elapsed}) (pool=${pool_name} profile=${first_profile} bs=${first_bs})"
          fi
          if [[ ${test_num} -lt ${total_tests} ]]; then
            local tests_remaining=$(( total_tests - test_num ))
            local avg_per_test=$(( suite_elapsed / test_num ))
            local eta=$(( avg_per_test * tests_remaining ))
            log_info "Progress: ${test_num}/${total_tests} tests done, $(_format_duration ${suite_elapsed}) elapsed, ~$(_format_duration ${eta}) remaining"
          fi

          # =================================================================
          # Subsequent permutations — reuse VMs via SSH fio job replacement
          # =================================================================
          for ((perm_idx=1; perm_idx<group_size; perm_idx++)); do
            local fio_profile="${group_profiles[${perm_idx}]}"
            local block_size="${group_block_sizes[${perm_idx}]}"
            ((test_num += 1))

            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_info "Test ${test_num}/${total_tests}: pool=${pool_name} vm=${size_label} pvc=${pvc_size} conc=${concurrency} profile=${fio_profile} bs=${block_size}"
            log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

            test_start_time=$(date +%s)
            test_failed=false
            ((pool_tests += 1))

            test_results_dir="${RESULTS_DIR}/${pool_name}/${size_label}/${pvc_size}/${concurrency}/${fio_profile}/${block_size}"
            mkdir -p "${test_results_dir}"

            local profile_path="${SCRIPT_DIR}/05-fio-profiles/${fio_profile}.fio"
            rendered_fio=$(render_fio_profile "${profile_path}" "${block_size}")

            # Replace fio job and restart service in all VMs
            local reuse_failed=false
            for vm in "${vm_names[@]}"; do
              if ! replace_fio_job "${vm}" "${rendered_fio}"; then
                log_error "Failed to replace fio job in ${vm}"
                reuse_failed=true
                break
              fi
              if ! restart_fio_service "${vm}"; then
                log_error "Failed to restart fio service in ${vm}"
                reuse_failed=true
                break
              fi
            done

            if [[ "${reuse_failed}" == "true" ]]; then
              ((failed_tests += 1))
              test_failed=true
              test_elapsed=$(( $(date +%s) - test_start_time ))
              log_info "Test ${test_num}/${total_tests} FAILED in $(_format_duration ${test_elapsed}) (pool=${pool_name} profile=${fio_profile} bs=${block_size})"
              continue
            fi

            # Wait for fio to complete
            if ! wait_for_all_fio_complete "${vm_names[@]}"; then
              log_warn "Some fio tests did not complete successfully"
              test_failed=true
            fi

            # Collect results
            for vm in "${vm_names[@]}"; do
              collect_vm_results "${vm}" "${test_results_dir}" || true
            done

            # Per-test timing and progress
            if [[ "${test_failed}" != "true" ]]; then
              ((pool_passed += 1))
            else
              ((failed_tests += 1))
            fi
            test_elapsed=$(( $(date +%s) - test_start_time ))
            suite_elapsed=$(( $(date +%s) - suite_start_time ))
            if [[ "${test_failed}" != "true" ]]; then
              log_info "Test ${test_num}/${total_tests} completed in $(_format_duration ${test_elapsed}) (pool=${pool_name} profile=${fio_profile} bs=${block_size})"
            else
              log_info "Test ${test_num}/${total_tests} FAILED in $(_format_duration ${test_elapsed}) (pool=${pool_name} profile=${fio_profile} bs=${block_size})"
            fi
            if [[ ${test_num} -lt ${total_tests} ]]; then
              local tests_remaining=$(( total_tests - test_num ))
              local avg_per_test=$(( suite_elapsed / test_num ))
              local eta=$(( avg_per_test * tests_remaining ))
              log_info "Progress: ${test_num}/${total_tests} tests done, $(_format_duration ${suite_elapsed}) elapsed, ~$(_format_duration ${eta}) remaining"
            fi

            # Brief pause between tests to let storage settle
            sleep 5

          done  # permutation loop

          # =================================================================
          # Cleanup VMs after all permutations in this group
          # =================================================================
          log_info "Cleaning up VMs for this group..."
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
    if [[ ${pool_tests} -gt 0 ]]; then
      local pool_elapsed=$(( $(date +%s) - pool_start_time ))
      log_info "Pool ${pool_name} complete: ${pool_passed}/${pool_tests} passed in $(_format_duration ${pool_elapsed})"
    fi
  done  # pool

  # ---------------------------------------------------------------------------
  # Summary
  # ---------------------------------------------------------------------------
  local suite_elapsed=$(( $(date +%s) - suite_start_time ))
  local passed_tests=$(( test_num - failed_tests - skipped_tests ))
  log_info "=== Test Suite Complete ==="
  log_info "Total tests: ${total_tests}"
  log_info "Passed: ${passed_tests}, Failed: ${failed_tests}, Skipped: ${skipped_tests}"
  if [[ ${test_num} -gt 0 ]]; then
    local avg_per_test=$(( suite_elapsed / test_num ))
    log_info "Total time: $(_format_duration ${suite_elapsed}) (avg $(_format_duration ${avg_per_test})/test)"
  else
    log_info "Total time: $(_format_duration ${suite_elapsed})"
  fi
  log_info "Results in: ${RESULTS_DIR}"
  log_info ""
  log_info "Next steps:"
  log_info "  1. Run ./07-collect-results.sh to aggregate results"
  log_info "  2. Run ./08-generate-report.sh to create reports"
  log_info "  3. Run ./09-cleanup.sh to remove storage pools (optional)"
}

suite_start_time=$(date +%s)
run_test_matrix
