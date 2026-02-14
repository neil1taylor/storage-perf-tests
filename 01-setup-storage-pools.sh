#!/usr/bin/env bash
# =============================================================================
# 01-setup-storage-pools.sh — Create ODF CephBlockPools + StorageClasses
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"

# ---------------------------------------------------------------------------
# Create a CephBlockPool + StorageClass for each ODF pool configuration
# ---------------------------------------------------------------------------
create_ceph_block_pool() {
  local pool_name="$1"
  local pool_type="$2"
  shift 2
  local full_pool_name="perf-test-${pool_name}"
  local sc_name="perf-test-sc-${pool_name}"

  log_info "Creating CephBlockPool: ${full_pool_name} (type=${pool_type})"

  if [[ "${pool_type}" == "replicated" ]]; then
    local rep_size="$1"
    cat <<EOF | oc apply -f -
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: ${full_pool_name}
  namespace: ${ODF_NAMESPACE}
spec:
  failureDomain: host
  replicated:
    size: ${rep_size}
    requireSafeReplicaSize: true
  deviceClass: ""
EOF

  elif [[ "${pool_type}" == "erasurecoded" ]]; then
    local data_chunks="$1"
    local coding_chunks="$2"
    cat <<EOF | oc apply -f -
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: ${full_pool_name}
  namespace: ${ODF_NAMESPACE}
spec:
  failureDomain: host
  erasureCoded:
    dataChunks: ${data_chunks}
    codingChunks: ${coding_chunks}
  deviceClass: ""
EOF
  fi

  # Wait for pool to be ready
  log_info "Waiting for pool ${full_pool_name} to become ready..."
  local retries=30
  for ((i=1; i<=retries; i++)); do
    local phase
    phase=$(oc get cephblockpool "${full_pool_name}" -n "${ODF_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    if [[ "${phase}" == "Ready" ]]; then
      log_info "Pool ${full_pool_name} is Ready"
      break
    fi
    if [[ "${phase}" == "Failure" ]]; then
      log_error "Pool ${full_pool_name} entered Failure state — check cluster topology (EC pools need one host per chunk)"
      return 1
    fi
    if [[ $i -eq $retries ]]; then
      log_error "Pool ${full_pool_name} did not become Ready within timeout (last phase: ${phase})"
      return 1
    fi
    sleep 10
  done

  # Create matching StorageClass (skip if it already exists — SC parameters are immutable)
  if oc get sc "${sc_name}" &>/dev/null; then
    log_info "StorageClass ${sc_name} already exists — skipping"
    return 0
  fi

  log_info "Creating StorageClass: ${sc_name}"
  local cluster_id
  cluster_id=$(oc get cephblockpool "${ODF_DEFAULT_SC##*-}" -n "${ODF_NAMESPACE}" \
    -o jsonpath='{.status.info.clusterID}' 2>/dev/null || \
    oc get storagecluster -n "${ODF_NAMESPACE}" -o jsonpath='{.items[0].status.storageProviderEndpoint}' 2>/dev/null || \
    echo "")

  # Retrieve the cluster ID from the existing default StorageClass
  if [[ -z "${cluster_id}" ]]; then
    cluster_id=$(oc get sc "${ODF_DEFAULT_SC}" -o jsonpath='{.parameters.clusterID}' 2>/dev/null || echo "openshift-storage")
  fi

  cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc_name}
provisioner: openshift-storage.rbd.csi.ceph.com
parameters:
  clusterID: ${cluster_id}
  pool: ${full_pool_name}
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${ODF_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: ${ODF_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${ODF_NAMESPACE}
  csi.storage.k8s.io/fstype: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF

  log_info "StorageClass ${sc_name} created"
}

# ---------------------------------------------------------------------------
# Ensure the per-namespace KMS token secret exists for encrypted PVC creation.
# The encrypted StorageClass uses IBM Key Protect via the ceph-csi-kms-token
# secret, which must exist in the test namespace.
# ---------------------------------------------------------------------------
ensure_kms_token() {
  if oc get secret ceph-csi-kms-token -n "${TEST_NAMESPACE}" &>/dev/null; then
    log_info "KMS token secret already exists in ${TEST_NAMESPACE}"
    return 0
  fi

  log_info "Creating ceph-csi-kms-token secret in ${TEST_NAMESPACE}..."

  # Retrieve the IBM Key Protect API key from the ODF namespace
  local api_key
  api_key=$(oc get secret ibm-kp-secret -n "${ODF_NAMESPACE}" \
    -o jsonpath='{.data.IBM_KP_SERVICE_API_KEY}' 2>/dev/null || echo "")

  if [[ -z "${api_key}" ]]; then
    log_warn "ibm-kp-secret not found in ${ODF_NAMESPACE} — encrypted pool tests will fail"
    log_warn "Create it manually: oc create secret generic ceph-csi-kms-token --from-literal=token=<API_KEY> -n ${TEST_NAMESPACE}"
    return 0
  fi

  local decoded_key
  decoded_key=$(printf '%s' "${api_key}" | base64 -d)

  oc create secret generic ceph-csi-kms-token \
    --from-literal=token="${decoded_key}" \
    -n "${TEST_NAMESPACE}"

  log_info "KMS token secret created in ${TEST_NAMESPACE}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log_info "=== Setting up ODF storage pools ==="

  # Ensure namespace exists
  oc get namespace "${TEST_NAMESPACE}" &>/dev/null || \
    oc create namespace "${TEST_NAMESPACE}"

  # Verify ODF is healthy
  log_info "Checking ODF cluster health..."
  local odf_health
  odf_health=$(oc get cephcluster -n "${ODF_NAMESPACE}" \
    -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo "UNKNOWN")
  log_info "ODF Ceph health: ${odf_health}"

  if [[ "${odf_health}" != "HEALTH_OK" && "${odf_health}" != "HEALTH_WARN" ]]; then
    log_warn "ODF health is ${odf_health} — proceeding with caution"
  fi

  # Discover OSD topology
  log_info "Discovering OSD host topology..."
  local osd_hosts
  osd_hosts=$(oc get pods -n "${ODF_NAMESPACE}" -l app=rook-ceph-osd \
    -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -c . || echo "0")
  log_info "OSD hosts detected: ${osd_hosts}"

  if [[ "${osd_hosts}" -eq 0 ]]; then
    log_error "No OSD pods found in ${ODF_NAMESPACE} — cannot create pools"
    return 1
  fi

  # Create each pool
  local pool_failures=0

  for pool_def in "${ODF_POOLS[@]}"; do
    IFS=':' read -r name type param1 param2 <<< "${pool_def}"

    # Skip rep3 if the default OOB pool already exists
    if [[ "${name}" == "rep3" ]]; then
      if oc get sc "${ODF_DEFAULT_SC}" &>/dev/null; then
        log_info "Skipping rep3 — using existing default SC: ${ODF_DEFAULT_SC}"
        continue
      fi
    fi

    # Skip rep3-virt — uses existing ODF virtualization SC
    if [[ "${name}" == "rep3-virt" ]]; then
      if oc get sc "ocs-storagecluster-ceph-rbd-virtualization" &>/dev/null; then
        log_info "Skipping rep3-virt — using existing SC: ocs-storagecluster-ceph-rbd-virtualization"
        continue
      fi
    fi

    # Skip rep3-enc — uses existing ODF encrypted SC
    if [[ "${name}" == "rep3-enc" ]]; then
      if oc get sc "ocs-storagecluster-ceph-rbd-encrypted" &>/dev/null; then
        log_info "Skipping rep3-enc — using existing SC: ocs-storagecluster-ceph-rbd-encrypted"
        # Ensure the per-namespace KMS token secret exists for encrypted PVC creation
        ensure_kms_token
        continue
      fi
    fi

    # Calculate minimum failure domains required
    local required_hosts=0
    if [[ "${type}" == "replicated" ]]; then
      required_hosts="${param1}"
    elif [[ "${type}" == "erasurecoded" ]]; then
      required_hosts=$(( param1 + param2 ))
    fi

    if [[ "${required_hosts}" -gt "${osd_hosts}" ]]; then
      log_warn "Pool ${name} requires ${required_hosts} hosts (failureDomain=host) but only ${osd_hosts} available — skipping"
      pool_failures=$((pool_failures + 1))
      continue
    fi

    if [[ "${type}" == "replicated" ]]; then
      create_ceph_block_pool "${name}" "${type}" "${param1}" || { log_warn "Pool ${name} failed — continuing"; pool_failures=$((pool_failures + 1)); continue; }
    elif [[ "${type}" == "erasurecoded" ]]; then
      create_ceph_block_pool "${name}" "${type}" "${param1}" "${param2}" || { log_warn "Pool ${name} failed — continuing"; pool_failures=$((pool_failures + 1)); continue; }
    fi
  done

  log_info "=== ODF storage pool setup complete ==="
  log_info "StorageClasses available:"
  oc get sc | grep -E "(perf-test-sc|${ODF_DEFAULT_SC})" || true

  if [[ ${pool_failures} -gt 0 ]]; then
    log_warn "${pool_failures} pool(s) failed to create — check logs above"
    return 1
  fi
}

main "$@"
