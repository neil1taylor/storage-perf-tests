#!/usr/bin/env bash
# =============================================================================
# 07-cleanup.sh — Clean up test VMs, PVCs, storage pools, and StorageClasses
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"

# ---------------------------------------------------------------------------
# Parse CLI args
# ---------------------------------------------------------------------------
CLEANUP_VMS=true
CLEANUP_PVCS=true
CLEANUP_POOLS=false    # Off by default — pools are more dangerous to delete
CLEANUP_NAMESPACE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)         CLEANUP_POOLS=true; CLEANUP_NAMESPACE=true; shift ;;
    --pools)       CLEANUP_POOLS=true; shift ;;
    --namespace)   CLEANUP_NAMESPACE=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo "  --all         Clean up everything including storage pools and namespace"
      echo "  --pools       Also clean up CephBlockPools and StorageClasses"
      echo "  --namespace   Also delete the test namespace"
      echo "  --dry-run     Show what would be deleted without doing it"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

run_cmd() {
  if [[ "${DRY_RUN}" == true ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log_info "=== Cleanup ==="
  [[ "${DRY_RUN}" == true ]] && log_info "(DRY RUN — no changes will be made)"

  # 1. Delete test VMs
  if [[ "${CLEANUP_VMS}" == true ]]; then
    log_info "Deleting test VMs..."
    local vms
    vms=$(oc get vm -n "${TEST_NAMESPACE}" -l app=vm-perf-test \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "${vms}" ]]; then
      for vm in ${vms}; do
        log_info "  Deleting VM: ${vm}"
        run_cmd oc delete vm "${vm}" -n "${TEST_NAMESPACE}" --wait=false || true
      done
    else
      log_info "  No test VMs found"
    fi
  fi

  # 2. Delete cloud-init Secrets
  if [[ "${CLEANUP_VMS}" == true ]]; then
    log_info "Deleting cloud-init Secrets..."
    local secrets
    secrets=$(oc get secret -n "${TEST_NAMESPACE}" -l app=vm-perf-test \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${secrets}" ]]; then
      for secret in ${secrets}; do
        log_info "  Deleting Secret: ${secret}"
        run_cmd oc delete secret "${secret}" -n "${TEST_NAMESPACE}" --wait=false || true
      done
    else
      log_info "  No cloud-init Secrets found"
    fi
  fi

  # 3. Delete test PVCs and DataVolumes
  if [[ "${CLEANUP_PVCS}" == true ]]; then
    log_info "Deleting test PVCs..."
    local pvcs
    pvcs=$(oc get pvc -n "${TEST_NAMESPACE}" -l app=vm-perf-test \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "${pvcs}" ]]; then
      for pvc in ${pvcs}; do
        log_info "  Deleting PVC: ${pvc}"
        run_cmd oc delete pvc "${pvc}" -n "${TEST_NAMESPACE}" --wait=false || true
      done
    else
      log_info "  No test PVCs found"
    fi

    # Also clean up DataVolumes
    local dvs
    dvs=$(oc get dv -n "${TEST_NAMESPACE}" -l app=vm-perf-test \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    for dv in ${dvs}; do
      log_info "  Deleting DataVolume: ${dv}"
      run_cmd oc delete dv "${dv}" -n "${TEST_NAMESPACE}" --wait=false || true
    done

    # Clean up file-verify PVCs
    local verify_pvcs
    verify_pvcs=$(oc get pvc -n "${TEST_NAMESPACE}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
      grep "^file-verify-" || echo "")
    for pvc in ${verify_pvcs}; do
      log_info "  Deleting verification PVC: ${pvc}"
      run_cmd oc delete pvc "${pvc}" -n "${TEST_NAMESPACE}" --wait=false || true
    done
  fi

  # 3. Delete test CephBlockPools and StorageClasses
  if [[ "${CLEANUP_POOLS}" == true ]]; then
    log_info "Deleting test CephBlockPools and StorageClasses..."

    for pool_def in "${ODF_POOLS[@]}"; do
      local name
      name=$(echo "${pool_def}" | cut -d: -f1)

      # Skip the default rep3 pool — don't delete it
      if [[ "${name}" == "rep3" ]]; then
        log_info "  Skipping default rep3 pool"
        continue
      fi

      # Skip rep3-virt — uses existing ODF virtualization SC
      if [[ "${name}" == "rep3-virt" ]]; then
        log_info "  Skipping default rep3-virt pool"
        continue
      fi

      # Skip rep3-enc — uses existing ODF encrypted SC
      if [[ "${name}" == "rep3-enc" ]]; then
        log_info "  Skipping default rep3-enc pool"
        continue
      fi

      local pool_name="perf-test-${name}"
      local sc_name="perf-test-sc-${name}"

      log_info "  Deleting StorageClass: ${sc_name}"
      run_cmd oc delete sc "${sc_name}" || true

      log_info "  Deleting CephBlockPool: ${pool_name}"
      run_cmd oc delete cephblockpool "${pool_name}" -n "${ODF_NAMESPACE}" || true
    done
  fi

  # 4. Delete namespace
  if [[ "${CLEANUP_NAMESPACE}" == true ]]; then
    log_info "Deleting test namespace: ${TEST_NAMESPACE}"
    run_cmd oc delete namespace "${TEST_NAMESPACE}" --wait=false || true
  fi

  # 5. Clean up SSH keys
  if [[ -f "${SSH_KEY_PATH}" ]]; then
    log_info "Cleaning up SSH keys..."
    run_cmd rm -f "${SSH_KEY_PATH}" "${SSH_KEY_PATH}.pub"
  fi

  log_info "=== Cleanup Complete ==="
  if [[ "${DRY_RUN}" == true ]]; then
    log_info "(This was a dry run — run without --dry-run to execute)"
  fi
}

main "$@"
