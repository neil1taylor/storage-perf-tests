#!/usr/bin/env bash
# =============================================================================
# 03-setup-block-storage.sh — Discover / verify IBM Cloud Block CSI StorageClasses
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"

# ---------------------------------------------------------------------------
# Discover all vpc-block StorageClasses on the cluster
# ---------------------------------------------------------------------------
discover_block_storage_classes() {
  log_info "Discovering IBM Cloud Block CSI StorageClasses..."

  local sc_list
  sc_list=$(oc get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.provisioner}{"\n"}{end}' | \
    grep -i "vpc.block.csi" | awk '{print $1}') || true

  if [[ -z "${sc_list}" ]]; then
    log_warn "No vpc-block CSI StorageClasses found. Checking for ibmc-vpc-block..."
    sc_list=$(oc get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.provisioner}{"\n"}{end}' | \
      grep -iE "ibmc-vpc-block" | awk '{print $1}') || true
  fi

  if [[ -z "${sc_list}" ]]; then
    return 1
  fi

  echo "${sc_list}"
}

# ---------------------------------------------------------------------------
# Verify a StorageClass can provision a PVC (ReadWriteOnce for block)
# ---------------------------------------------------------------------------
verify_storage_class() {
  local sc_name="$1"
  local test_pvc_name="block-verify-${sc_name}"

  # Truncate PVC name to 63 chars (K8s limit)
  test_pvc_name="${test_pvc_name:0:63}"

  log_info "Verifying StorageClass ${sc_name} can provision a PVC..."

  cat <<EOF | oc apply -n "${TEST_NAMESPACE}" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${test_pvc_name}
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${sc_name}
  resources:
    requests:
      storage: 1Gi
EOF

  # Wait for PVC to bind
  local retries=30
  for ((i=1; i<=retries; i++)); do
    local phase
    phase=$(oc get pvc "${test_pvc_name}" -n "${TEST_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [[ "${phase}" == "Bound" ]]; then
      log_info "  ${sc_name} — PVC bound successfully"
      # Cleanup verification PVC
      oc delete pvc "${test_pvc_name}" -n "${TEST_NAMESPACE}" --wait=false &>/dev/null || true
      return 0
    fi
    if [[ $i -eq $retries ]]; then
      log_warn "  ${sc_name} — PVC did not bind within timeout"
      oc delete pvc "${test_pvc_name}" -n "${TEST_NAMESPACE}" --wait=false &>/dev/null || true
      return 1
    fi
    sleep 10
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log_info "=== Setting up IBM Cloud Block storage for testing ==="

  # Skip if explicitly disabled
  if [[ "${BLOCK_CSI_ENABLED}" == "false" ]]; then
    log_info "Block CSI testing is disabled (BLOCK_CSI_ENABLED=false) — skipping"
    exit 0
  fi

  # Ensure namespace exists
  oc get namespace "${TEST_NAMESPACE}" &>/dev/null || \
    oc create namespace "${TEST_NAMESPACE}"

  # Determine which StorageClasses to test
  local -a block_scs=()

  if [[ "${BLOCK_CSI_DISCOVERY}" == "auto" ]]; then
    log_info "Auto-discovering Block CSI StorageClasses..."
    while IFS= read -r sc; do
      [[ -n "${sc}" ]] && block_scs+=("${sc}")
    done < <(discover_block_storage_classes) || true
  else
    block_scs=("${BLOCK_CSI_PROFILES[@]}")
  fi

  if [[ ${#block_scs[@]} -eq 0 ]]; then
    log_info "No Block CSI StorageClasses found — skipping (expected on bare metal clusters)"
    exit 0
  fi

  # Filter out -metro- and -retain- variants when auto-discovering.
  # These differ only in topology constraints or PV reclaim policy —
  # I/O performance is identical on single-zone. On multi-zone clusters,
  # metro SCs are included since cross-AZ topology may affect performance.
  if [[ "${BLOCK_CSI_DISCOVERY}" == "auto" && "${BLOCK_CSI_DEDUP}" == "true" ]]; then
    local pre_filter=${#block_scs[@]}
    local -a deduped_scs=()
    for sc in "${block_scs[@]}"; do
      if [[ "${sc}" == *-metro-* || "${sc}" == *-retain-* ]]; then
        log_info "  Skipping variant: ${sc}"
      else
        deduped_scs+=("${sc}")
      fi
    done
    if [[ ${#deduped_scs[@]} -gt 0 ]]; then
      block_scs=("${deduped_scs[@]}")
      log_info "Filtered ${pre_filter} → ${#block_scs[@]} StorageClasses (excluded metro/retain variants)"
    else
      log_warn "All SCs were metro/retain variants — keeping original list"
    fi
  fi

  log_info "Block CSI StorageClasses to test:"
  for sc in "${block_scs[@]}"; do
    log_info "  - ${sc}"
  done

  # Write discovered SCs to a file for other scripts to consume
  local sc_file="${RESULTS_DIR}/block-storage-classes.txt"
  mkdir -p "${RESULTS_DIR}"
  printf '%s\n' "${block_scs[@]}" > "${sc_file}"
  log_info "StorageClass list written to ${sc_file}"

  # Verify the Block CSI provisioner can provision a PVC.
  # All SCs use the same provisioner (differing only in IOPS tier), so
  # verifying the first one is sufficient.  If it fails, fall back to
  # checking the rest individually.
  if [[ "${VERIFY_BLOCK_SC:-true}" == "true" ]]; then
    log_info "Verifying Block CSI provisioner with ${block_scs[0]}..."
    if verify_storage_class "${block_scs[0]}"; then
      log_info "Provisioner OK — accepting all ${#block_scs[@]} StorageClasses"
    else
      log_warn "${block_scs[0]} failed — verifying remaining StorageClasses individually..."
      local -a verified_scs=()
      for sc in "${block_scs[@]:1}"; do
        if verify_storage_class "${sc}"; then
          verified_scs+=("${sc}")
        else
          log_warn "Excluding ${sc} from tests — could not provision PVC"
        fi
      done
      block_scs=("${verified_scs[@]}")
      if [[ ${#block_scs[@]} -eq 0 ]]; then
        log_warn "No Block CSI StorageClasses could provision a PVC — skipping block tests"
        rm -f "${sc_file}"
        exit 0
      fi
      printf '%s\n' "${block_scs[@]}" > "${sc_file}"
      log_info "Verified ${#block_scs[@]} Block StorageClasses"
    fi
  fi

  log_info "=== IBM Cloud Block storage setup complete ==="
}

main "$@"
