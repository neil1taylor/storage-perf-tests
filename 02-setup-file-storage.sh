#!/usr/bin/env bash
# =============================================================================
# 02-setup-file-storage.sh — Discover / verify IBM Cloud File CSI StorageClasses
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"

# ---------------------------------------------------------------------------
# Discover all vpc-file StorageClasses on the cluster
# ---------------------------------------------------------------------------
discover_file_storage_classes() {
  log_info "Discovering IBM Cloud File CSI StorageClasses..."

  local sc_list
  sc_list=$(oc get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.provisioner}{"\n"}{end}' | \
    grep -i "vpc.file.csi" | awk '{print $1}') || true

  if [[ -z "${sc_list}" ]]; then
    log_warn "No vpc-file CSI StorageClasses found. Checking for ibm-file-csi..."
    sc_list=$(oc get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.provisioner}{"\n"}{end}' | \
      grep -iE "(ibmc-file|ibm-vpc-block-file|file-gold|file-silver|file-bronze)" | awk '{print $1}') || true
  fi

  if [[ -z "${sc_list}" ]]; then
    log_error "No IBM Cloud File StorageClasses found on this cluster"
    log_info "Available StorageClasses:"
    oc get sc -o name >&2
    return 1
  fi

  echo "${sc_list}"
}

# ---------------------------------------------------------------------------
# Verify a StorageClass can provision a PVC
# ---------------------------------------------------------------------------
verify_storage_class() {
  local sc_name="$1"
  local test_pvc_name="file-verify-${sc_name}"

  log_info "Verifying StorageClass ${sc_name} can provision a PVC..."

  cat <<EOF | oc apply -n "${TEST_NAMESPACE}" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${test_pvc_name}
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
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
      log_info "  ✓ ${sc_name} — PVC bound successfully"
      # Cleanup verification PVC
      oc delete pvc "${test_pvc_name}" -n "${TEST_NAMESPACE}" --wait=false &>/dev/null || true
      return 0
    fi
    if [[ $i -eq $retries ]]; then
      log_warn "  ✗ ${sc_name} — PVC did not bind within timeout"
      oc delete pvc "${test_pvc_name}" -n "${TEST_NAMESPACE}" --wait=false &>/dev/null || true
      return 1
    fi
    sleep 10
  done
}

# ---------------------------------------------------------------------------
# Pool CSI — detect CRD, topology, resource group, create FileSharePool
# ---------------------------------------------------------------------------
detect_pool_csi() {
  oc get crd filesharepools.storage.ibmcloud.io &>/dev/null
}

detect_pool_csi_topology() {
  local region zone
  region=$(oc get nodes -l node-role.kubernetes.io/worker= \
    -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}' 2>/dev/null || echo "")
  zone=$(oc get nodes -l node-role.kubernetes.io/worker= \
    -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "")

  if [[ -z "${region}" || -z "${zone}" ]]; then
    log_error "Could not detect region/zone from worker node topology labels"
    return 1
  fi

  echo "${region}:${zone}"
}

detect_resource_group() {
  local rg=""

  # Strategy 1: ConfigMap cluster-info
  rg=$(oc get configmap cluster-info -n kube-system \
    -o jsonpath='{.data.resource-group-id}' 2>/dev/null || echo "")
  if [[ -n "${rg}" ]]; then
    echo "${rg}"
    return 0
  fi

  # Strategy 2: ConfigMap ibm-cloud-provider-data
  rg=$(oc get configmap ibm-cloud-provider-data -n kube-system \
    -o jsonpath='{.data.resourceGroupID}' 2>/dev/null || echo "")
  if [[ -n "${rg}" ]]; then
    echo "${rg}"
    return 0
  fi

  # Strategy 3: Secret storage-secret-store
  rg=$(oc get secret storage-secret-store -n kube-system \
    -o jsonpath='{.data.resource_group_id}' 2>/dev/null || echo "")
  if [[ -n "${rg}" ]]; then
    echo "${rg}" | base64 -d 2>/dev/null
    return 0
  fi

  # Strategy 4: Env var fallback
  if [[ -n "${POOL_RESOURCE_GROUP}" ]]; then
    echo "${POOL_RESOURCE_GROUP}"
    return 0
  fi

  log_error "Could not detect resource group from cluster ConfigMaps/Secrets"
  log_error "Set POOL_RESOURCE_GROUP env var to provide it manually"
  return 1
}

setup_pool_csi() {
  log_info "Checking for IBM Cloud Pool CSI driver..."

  if ! detect_pool_csi; then
    log_info "Pool CSI driver not detected — skipping FileSharePool setup"
    return 0
  fi

  log_info "Pool CSI driver detected (filesharepools.storage.ibmcloud.io CRD exists)"

  # Skip if FileSharePool already exists
  if oc get filesharepools.storage.ibmcloud.io "${POOL_CSI_NAME}" &>/dev/null; then
    log_info "FileSharePool ${POOL_CSI_NAME} already exists — skipping creation"
  else
    # Detect topology
    local topo
    topo=$(detect_pool_csi_topology)
    local region="${topo%%:*}"
    local zone="${topo#*:}"
    log_info "Detected topology: region=${region}, zone=${zone}"

    # Detect resource group
    local resource_group
    resource_group=$(detect_resource_group)
    log_info "Detected resource group: ${resource_group}"

    log_info "Creating FileSharePool: ${POOL_CSI_NAME}"
    cat <<EOF | oc apply -f -
apiVersion: storage.ibmcloud.io/v1alpha1
kind: FileSharePool
metadata:
  name: ${POOL_CSI_NAME}
spec:
  region: ${region}
  zone: ${zone}
  resourceGroup: ${resource_group}
  profile: ${POOL_CSI_PROFILE}
  iops: ${POOL_CSI_IOPS}
  sizeGiB: ${POOL_CSI_SHARE_SIZE%Gi}
  maxShares: ${POOL_CSI_MAX_SHARES}
  allocationStrategy: ${POOL_CSI_ALLOCATION_STRATEGY}
  defaultPermissions:
    uid: ${POOL_CSI_DEFAULT_UID}
    gid: ${POOL_CSI_DEFAULT_GID}
    permissions: "${POOL_CSI_DEFAULT_PERMISSIONS}"
EOF
  fi

  # Wait for the driver to auto-create the StorageClass
  log_info "Waiting for StorageClass ${POOL_CSI_NAME} to be created by the driver..."
  local elapsed=0
  local timeout=300
  while [[ ${elapsed} -lt ${timeout} ]]; do
    if oc get sc "${POOL_CSI_NAME}" &>/dev/null; then
      log_info "StorageClass ${POOL_CSI_NAME} is available"
      break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done

  if [[ ${elapsed} -ge ${timeout} ]]; then
    log_error "StorageClass ${POOL_CSI_NAME} was not created within ${timeout}s"
    return 1
  fi

  # Append to file-storage-classes.txt (deduplicated)
  local sc_file="${RESULTS_DIR}/file-storage-classes.txt"
  mkdir -p "${RESULTS_DIR}"
  if [[ ! -f "${sc_file}" ]] || ! grep -qx "${POOL_CSI_NAME}" "${sc_file}"; then
    echo "${POOL_CSI_NAME}" >> "${sc_file}"
    log_info "Added ${POOL_CSI_NAME} to ${sc_file}"
  else
    log_info "${POOL_CSI_NAME} already in ${sc_file}"
  fi

  log_info "Pool CSI FileSharePool setup complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log_info "=== Setting up IBM Cloud File storage for testing ==="

  # Ensure namespace exists
  oc get namespace "${TEST_NAMESPACE}" &>/dev/null || \
    oc create namespace "${TEST_NAMESPACE}"

  # Determine which StorageClasses to test
  local -a file_scs=()

  if [[ "${FILE_CSI_DISCOVERY}" == "auto" ]]; then
    log_info "Auto-discovering File CSI StorageClasses..."
    while IFS= read -r sc; do
      [[ -n "${sc}" ]] && file_scs+=("${sc}")
    done < <(discover_file_storage_classes)
  else
    file_scs=("${FILE_CSI_PROFILES[@]}")
  fi

  if [[ ${#file_scs[@]} -eq 0 ]]; then
    log_error "No File CSI StorageClasses available for testing"
    exit 1
  fi

  # Filter out variants that duplicate I/O behaviour or are inaccessible:
  #   -metro- / -retain-  — same I/O perf as base SC (topology/reclaim only)
  #   -regional*           — use 'rfs' profile which requires IBM support allowlisting
  #   -eit                 — encryption-in-transit not supported on RHCOS (ROKS worker nodes)
  if [[ "${FILE_CSI_DISCOVERY}" == "auto" && "${FILE_CSI_DEDUP:-true}" == "true" ]]; then
    local pre_filter=${#file_scs[@]}
    local -a deduped_scs=()
    for sc in "${file_scs[@]}"; do
      if [[ "${sc}" == *-metro-* || "${sc}" == *-retain-* ]]; then
        log_info "  Skipping variant: ${sc}"
      elif [[ "${sc}" == *-regional* ]]; then
        log_info "  Skipping regional: ${sc} (rfs profile requires allowlisting)"
      elif [[ "${sc}" == *-eit* ]]; then
        log_info "  Skipping EIT: ${sc} (encryption-in-transit not supported on RHCOS)"
      else
        deduped_scs+=("${sc}")
      fi
    done
    if [[ ${#deduped_scs[@]} -gt 0 ]]; then
      file_scs=("${deduped_scs[@]}")
      log_info "Filtered ${pre_filter} → ${#file_scs[@]} StorageClasses (excluded metro/retain/regional variants)"
    else
      log_warn "All SCs were metro/retain/regional variants — keeping original list"
    fi
  fi

  log_info "File CSI StorageClasses to test:"
  for sc in "${file_scs[@]}"; do
    log_info "  - ${sc}"
  done

  # Write discovered SCs to a file for other scripts to consume
  local sc_file="${RESULTS_DIR}/file-storage-classes.txt"
  mkdir -p "${RESULTS_DIR}"
  printf '%s\n' "${file_scs[@]}" > "${sc_file}"
  log_info "StorageClass list written to ${sc_file}"

  # Optionally verify the File CSI provisioner can provision a PVC.
  # All SCs use the same provisioner (differing only in IOPS tier), so
  # verifying the first one is sufficient.  If it fails, fall back to
  # checking the rest individually in case the first SC is misconfigured.
  if [[ "${VERIFY_FILE_SC:-true}" == "true" ]]; then
    log_info "Verifying File CSI provisioner with ${file_scs[0]}..."
    if verify_storage_class "${file_scs[0]}"; then
      log_info "Provisioner OK — accepting all ${#file_scs[@]} StorageClasses"
    else
      log_warn "${file_scs[0]} failed — verifying remaining StorageClasses individually..."
      local -a verified_scs=()
      for sc in "${file_scs[@]:1}"; do
        if verify_storage_class "${sc}"; then
          verified_scs+=("${sc}")
        else
          log_warn "Excluding ${sc} from tests — could not provision PVC"
        fi
      done
      file_scs=("${verified_scs[@]}")
      if [[ ${#file_scs[@]} -eq 0 ]]; then
        log_error "No File CSI StorageClasses could provision a PVC"
        exit 1
      fi
      printf '%s\n' "${file_scs[@]}" > "${sc_file}"
      log_info "Verified ${#file_scs[@]} File StorageClasses"
    fi
  fi

  # Pool CSI FileSharePool (optional — skipped silently if driver not present)
  setup_pool_csi || log_warn "Pool CSI setup failed — continuing without it"

  log_info "=== IBM Cloud File storage setup complete ==="
}

main "$@"
