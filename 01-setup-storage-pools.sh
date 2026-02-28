#!/usr/bin/env bash
# =============================================================================
# 01-setup-storage-pools.sh — Create ODF CephBlockPools + StorageClasses
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"
source "${SCRIPT_DIR}/lib/wait-helpers.sh"

# ---------------------------------------------------------------------------
# Detect the failure domain from the ODF StorageCluster status.
# The ocs-operator auto-computes this from node topology labels and
# propagates it to OOB CephBlockPools. Custom pools must match.
# Fallback chain: StorageCluster status → OOB CephBlockPool spec → "rack"
# ---------------------------------------------------------------------------
detect_failure_domain() {
  local fd

  # Primary: StorageCluster status (authoritative source)
  fd=$(oc get storagecluster -n "${ODF_NAMESPACE}" \
    -o jsonpath='{.items[0].status.failureDomain}' 2>/dev/null || echo "")

  # Fallback: OOB CephBlockPool spec (set by ocs-operator from StorageCluster)
  if [[ -z "${fd}" ]]; then
    fd=$(oc get cephblockpool -n "${ODF_NAMESPACE}" ocs-storagecluster-cephblockpool \
      -o jsonpath='{.spec.failureDomain}' 2>/dev/null || echo "")
  fi

  if [[ -z "${fd}" ]]; then
    log_warn "Could not detect failure domain from StorageCluster or OOB pool — defaulting to 'rack'"
    fd="rack"
  fi
  echo "${fd}"
}

# ---------------------------------------------------------------------------
# Create (or verify) a StorageClass for a given ODF pool
# Idempotent: skips if the SC already exists (SC parameters are immutable).
# ---------------------------------------------------------------------------
ensure_storage_class() {
  local pool_name="$1"
  local pool_type="$2"
  local full_pool_name="perf-test-${pool_name}"
  local sc_name="perf-test-sc-${pool_name}"

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

  # EC pools need a replicated metadata pool; the default ODF pool serves this role.
  # RBD stores image headers/metadata in "pool" and actual data blocks in "dataPool".
  local ec_data_pool_line=""
  local metadata_pool="${full_pool_name}"
  if [[ "${pool_type}" == "erasurecoded" ]]; then
    metadata_pool="ocs-storagecluster-cephblockpool"
    ec_data_pool_line="  dataPool: ${full_pool_name}"
  fi

  cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc_name}
provisioner: openshift-storage.rbd.csi.ceph.com
parameters:
  clusterID: ${cluster_id}
  pool: ${metadata_pool}
${ec_data_pool_line}
  imageFormat: "2"
  imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff
  mapOptions: krbd:rxbounce
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
# Create (or verify) a CephFS StorageClass for a given CephFilesystem
# Idempotent: skips if the SC already exists (SC parameters are immutable).
# ---------------------------------------------------------------------------
ensure_cephfs_storage_class() {
  local pool_name="$1"
  local fs_name="perf-test-${pool_name}"
  local sc_name="perf-test-sc-${pool_name}"

  if oc get sc "${sc_name}" &>/dev/null; then
    log_info "StorageClass ${sc_name} already exists — skipping"
    return 0
  fi

  log_info "Creating CephFS StorageClass: ${sc_name}"

  # Get clusterID from existing OOB CephFS SC, falling back to RBD SC
  local cluster_id
  cluster_id=$(oc get sc "${ODF_DEFAULT_CEPHFS_SC}" -o jsonpath='{.parameters.clusterID}' 2>/dev/null || \
    oc get sc "${ODF_DEFAULT_SC}" -o jsonpath='{.parameters.clusterID}' 2>/dev/null || echo "openshift-storage")

  cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc_name}
provisioner: openshift-storage.cephfs.csi.ceph.com
parameters:
  clusterID: ${cluster_id}
  fsName: ${fs_name}
  pool: ${fs_name}-data0
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${ODF_NAMESPACE}
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: ${ODF_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${ODF_NAMESPACE}
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF

  log_info "StorageClass ${sc_name} created"
}

# ---------------------------------------------------------------------------
# Execute a ceph CLI command, trying toolbox first, then falling back to an
# OSD pod with the admin keyring. Encrypted clusters (e.g. IBM KP) may not
# have a toolbox; OSD pods lack the admin keyring by default, so we inject
# it from the rook-ceph-admin-keyring secret + a temp ceph.conf with
# ms_client_mode=secure for encrypted messenger.
# ---------------------------------------------------------------------------
CEPH_EXEC_OSD_POD=""
CEPH_EXEC_INITIALIZED=""

_init_ceph_exec_osd() {
  [[ -n "${CEPH_EXEC_INITIALIZED}" ]] && return 0

  local osd_pod
  osd_pod=$(oc get pod -n "${ODF_NAMESPACE}" -l app=rook-ceph-osd --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [[ -z "${osd_pod}" ]] && return 1

  # Extract admin keyring from K8s secret
  local admin_key
  admin_key=$(oc get secret rook-ceph-admin-keyring -n "${ODF_NAMESPACE}" \
    -o jsonpath='{.data.keyring}' 2>/dev/null | base64 -d | grep key | awk '{print $3}')
  [[ -z "${admin_key}" ]] && return 1

  # Get mon endpoints (v2 addresses)
  local mon_hosts
  mon_hosts=$(oc get configmap rook-ceph-mon-endpoints -n "${ODF_NAMESPACE}" \
    -o jsonpath='{.data.mapping}' 2>/dev/null | \
    jq -r '.node | to_entries[] | .value.Address' | \
    while read -r ip; do echo -n "[v2:${ip}:3300],"; done | sed 's/,$//')
  [[ -z "${mon_hosts}" ]] && return 1

  # Write temp ceph.conf and admin keyring to OSD pod
  oc exec -n "${ODF_NAMESPACE}" "${osd_pod}" -- bash -c "
    cat > /tmp/ceph.conf << 'CONF'
[global]
mon_host = ${mon_hosts}
ms_client_mode = secure
CONF
    cat > /tmp/admin.keyring << KEY
[client.admin]
key = ${admin_key}
KEY" 2>/dev/null || return 1

  CEPH_EXEC_OSD_POD="${osd_pod}"
  CEPH_EXEC_INITIALIZED="true"
  return 0
}

ceph_exec() {
  # Try toolbox deployment first
  local output
  if output=$(oc -n "${ODF_NAMESPACE}" exec deploy/rook-ceph-tools -- "$@" 2>/dev/null); then
    echo "${output}"
    return 0
  fi

  # Fallback: OSD pod with injected admin keyring
  if _init_ceph_exec_osd; then
    if output=$(oc exec -n "${ODF_NAMESPACE}" "${CEPH_EXEC_OSD_POD}" -- \
      bash -c "$(printf '%q ' "$@") --conf /tmp/ceph.conf --keyring /tmp/admin.keyring" 2>/dev/null); then
      echo "${output}"
      return 0
    fi
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Update CephFS CSI provisioner/node auth caps to include a new filesystem.
# Rook only authorizes the OOB CephFilesystem; custom ones need caps added.
# ---------------------------------------------------------------------------
update_cephfs_csi_caps() {
  local fs_name="$1"

  # Verify ceph CLI access (via toolbox or OSD pod)
  if ! ceph_exec ceph status &>/dev/null; then
    log_warn "Cannot access Ceph CLI — cannot update CephFS CSI auth caps"
    log_warn "PVC provisioning for ${fs_name} may fail with 'Operation not permitted'"
    return 0
  fi

  # Get provisioner and node user IDs from the K8s secrets
  local prov_user node_user
  prov_user=$(oc get secret rook-csi-cephfs-provisioner -n "${ODF_NAMESPACE}" \
    -o jsonpath='{.data.adminID}' 2>/dev/null | base64 -d)
  node_user=$(oc get secret rook-csi-cephfs-node -n "${ODF_NAMESPACE}" \
    -o jsonpath='{.data.adminID}' 2>/dev/null | base64 -d)

  if [[ -z "${prov_user}" || -z "${node_user}" ]]; then
    log_warn "CephFS CSI secrets not found — cannot update auth caps"
    return 0
  fi

  # Check if the provisioner already has caps for this filesystem
  local current_prov_caps
  current_prov_caps=$(ceph_exec ceph auth get "client.${prov_user}" 2>/dev/null | grep "caps osd" || echo "")

  if echo "${current_prov_caps}" | grep -q "${fs_name}"; then
    log_info "CephFS CSI caps already include ${fs_name} — skipping"
    return 0
  fi

  log_info "Updating CephFS CSI auth caps to include ${fs_name}..."

  # Extract existing OSD caps to preserve them, then append the new filesystem
  local prov_osd_caps node_osd_caps
  prov_osd_caps=$(ceph_exec ceph auth get "client.${prov_user}" 2>/dev/null | \
    sed -n 's/.*caps osd = "\(.*\)"/\1/p')
  node_osd_caps=$(ceph_exec ceph auth get "client.${node_user}" 2>/dev/null | \
    sed -n 's/.*caps osd = "\(.*\)"/\1/p')

  # Append caps for the new filesystem
  local new_prov_osd="${prov_osd_caps}, allow rw tag cephfs metadata=${fs_name}"
  local new_node_osd="${node_osd_caps}, allow rw tag cephfs *=${fs_name}"

  ceph_exec ceph auth caps "client.${prov_user}" \
    mds "allow rw path=/volumes/csi" \
    mgr "allow rw" \
    mon "allow r, allow command 'osd blocklist'" \
    osd "${new_prov_osd}" 2>&1 | head -1

  ceph_exec ceph auth caps "client.${node_user}" \
    mds "allow rw path=/volumes/csi" \
    mgr "allow rw" \
    mon "allow r" \
    osd "${new_node_osd}" 2>&1 | head -1

  log_info "CephFS CSI auth caps updated for ${fs_name}"

  # Restart CephFS CSI controller pods to pick up new auth
  log_info "Restarting CephFS CSI controller pods..."
  oc delete pod -n "${ODF_NAMESPACE}" \
    -l app=openshift-storage.cephfs.csi.ceph.com-ctrlplugin --wait=false 2>/dev/null || true
  oc rollout status deployment/openshift-storage.cephfs.csi.ceph.com-ctrlplugin \
    -n "${ODF_NAMESPACE}" --timeout=120s 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Create a CephFilesystem + StorageClass for a CephFS pool configuration
# ---------------------------------------------------------------------------
create_ceph_filesystem() {
  local pool_name="$1"
  local data_replica_size="$2"
  local failure_domain="$3"
  local fs_name="perf-test-${pool_name}"

  log_info "Creating CephFilesystem: ${fs_name} (data replicas=${data_replica_size}, metadata replicas=3, failureDomain=${failure_domain})"

  cat <<EOF | oc apply -f -
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: ${fs_name}
  namespace: ${ODF_NAMESPACE}
spec:
  metadataPool:
    replicated:
      size: 3
      requireSafeReplicaSize: true
    deviceClass: ssd
  dataPools:
    - name: data0
      failureDomain: ${failure_domain}
      deviceClass: ssd
      replicated:
        size: ${data_replica_size}
        requireSafeReplicaSize: true
        targetSizeRatio: 0.1
  preserveFilesystemOnDelete: false
  metadataServer:
    activeCount: 1
    activeStandby: true
    resources:
      requests:
        cpu: "1"
        memory: 4Gi
      limits:
        memory: 4Gi
EOF

  # Wait for CephFilesystem to become Ready (MDS initialization)
  log_info "Waiting for CephFilesystem ${fs_name} to become Ready (timeout=${MDS_READY_TIMEOUT}s)..."
  local retries=$(( MDS_READY_TIMEOUT / 10 ))
  for ((i=1; i<=retries; i++)); do
    local phase
    phase=$(oc get cephfilesystem "${fs_name}" -n "${ODF_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    if [[ "${phase}" == "Ready" ]]; then
      log_info "CephFilesystem ${fs_name} is Ready"
      break
    fi
    if [[ "${phase}" == "Failure" ]]; then
      log_error "CephFilesystem ${fs_name} entered Failure state — some ODF versions limit to one CephFilesystem"
      return 1
    fi
    if [[ $i -eq $retries ]]; then
      log_error "CephFilesystem ${fs_name} did not become Ready within ${MDS_READY_TIMEOUT}s (last phase: ${phase})"
      return 1
    fi
    sleep 10
  done

  # Update CephFS CSI auth caps to include the new filesystem
  update_cephfs_csi_caps "${fs_name}"

  # Create matching CephFS StorageClass
  ensure_cephfs_storage_class "${pool_name}"
}

# ---------------------------------------------------------------------------
# Create a CephBlockPool + StorageClass for each ODF pool configuration
# ---------------------------------------------------------------------------
create_ceph_block_pool() {
  local pool_name="$1"
  local pool_type="$2"
  local failure_domain="$3"
  shift 3
  local full_pool_name="perf-test-${pool_name}"

  log_info "Creating CephBlockPool: ${full_pool_name} (type=${pool_type}, failureDomain=${failure_domain})"

  if [[ "${pool_type}" == "replicated" ]]; then
    local rep_size="$1"
    cat <<EOF | oc apply -f -
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: ${full_pool_name}
  namespace: ${ODF_NAMESPACE}
spec:
  failureDomain: ${failure_domain}
  deviceClass: ssd
  enableCrushUpdates: true
  enableRBDStats: true
  replicated:
    size: ${rep_size}
    requireSafeReplicaSize: true
    targetSizeRatio: 0.1
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
  failureDomain: ${failure_domain}
  deviceClass: ssd
  enableCrushUpdates: true
  enableRBDStats: true
  parameters:
    target_size_ratio: "0.1"
  erasureCoded:
    dataChunks: ${data_chunks}
    codingChunks: ${coding_chunks}
EOF
  fi

  # Wait for pool to be ready (EC pools need longer — PG init across multiple OSDs)
  log_info "Waiting for pool ${full_pool_name} to become ready..."
  local retries=30
  if [[ "${pool_type}" == "erasurecoded" ]]; then
    retries=60
  fi
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

  # Create matching StorageClass
  ensure_storage_class "${pool_name}" "${pool_type}"
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

  # Discover OSD topology — count unique failure domains (racks on ROKS)
  local failure_domain
  failure_domain=$(detect_failure_domain)
  log_info "Using failureDomain: ${failure_domain}"

  local failure_domain_count
  if [[ "${failure_domain}" == "host" ]]; then
    failure_domain_count=$(oc get pods -n "${ODF_NAMESPACE}" -l app=rook-ceph-osd \
      -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -c . || echo "0")
  elif [[ "${failure_domain}" == "zone" ]]; then
    # For zone, count unique zones from worker node topology labels (no Ceph CLI needed)
    failure_domain_count=$(oc get nodes -l node-role.kubernetes.io/worker \
      -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' 2>/dev/null | \
      sort -u | grep -c . || echo "0")
  else
    # For rack or other CRUSH types, try toolbox first, fall back to OSD pod
    failure_domain_count=$(oc -n "${ODF_NAMESPACE}" exec deploy/rook-ceph-tools -- \
      ceph osd crush tree --format json 2>/dev/null | \
      jq --arg fd "${failure_domain}" '[.. | objects | select(.type == $fd)] | length' 2>/dev/null || echo "0")
    if [[ "${failure_domain_count}" -eq 0 ]]; then
      # Toolbox unavailable — try via OSD pod (handles encrypted clusters)
      local osd_pod
      osd_pod=$(oc get pod -n "${ODF_NAMESPACE}" -l app=rook-ceph-osd \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [[ -n "${osd_pod}" ]]; then
        failure_domain_count=$(oc exec -n "${ODF_NAMESPACE}" "${osd_pod}" -- \
          ceph osd crush tree --format json 2>/dev/null | \
          jq --arg fd "${failure_domain}" '[.. | objects | select(.type == $fd)] | length' 2>/dev/null || echo "0")
      fi
    fi
  fi
  log_info "Failure domains (${failure_domain}): ${failure_domain_count}"

  if [[ "${failure_domain_count}" -eq 0 ]]; then
    log_error "No failure domains found in ${ODF_NAMESPACE} — cannot create pools"
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

    # Skip cephfs-rep3 — uses existing OOB CephFS SC
    if [[ "${name}" == "cephfs-rep3" ]]; then
      if oc get sc "${ODF_DEFAULT_CEPHFS_SC}" &>/dev/null; then
        log_info "Skipping cephfs-rep3 — using existing default SC: ${ODF_DEFAULT_CEPHFS_SC}"
        continue
      fi
    fi

    # Calculate minimum failure domains required
    local required_domains=0
    if [[ "${type}" == "replicated" ]]; then
      required_domains="${param1}"
    elif [[ "${type}" == "erasurecoded" ]]; then
      required_domains=$(( param1 + param2 ))
    elif [[ "${type}" == "cephfs" ]]; then
      required_domains="${param1}"
    fi

    if [[ "${required_domains}" -gt "${failure_domain_count}" ]]; then
      log_warn "Pool ${name} requires ${required_domains} ${failure_domain}s but only ${failure_domain_count} available — skipping"
      continue
    fi

    if [[ "${type}" == "replicated" ]]; then
      create_ceph_block_pool "${name}" "${type}" "${failure_domain}" "${param1}" || { log_warn "Pool ${name} failed — continuing"; pool_failures=$((pool_failures + 1)); continue; }
    elif [[ "${type}" == "erasurecoded" ]]; then
      create_ceph_block_pool "${name}" "${type}" "${failure_domain}" "${param1}" "${param2}" || { log_warn "Pool ${name} failed — continuing"; pool_failures=$((pool_failures + 1)); continue; }
    elif [[ "${type}" == "cephfs" ]]; then
      create_ceph_filesystem "${name}" "${param1}" "${failure_domain}" || { log_warn "CephFilesystem ${name} failed — continuing"; pool_failures=$((pool_failures + 1)); continue; }
    fi
  done

  # Reconciliation pass: create SCs for pools that became Ready after their
  # initial timeout expired (common with slow EC PG initialization).
  log_info "Reconciling StorageClasses for any late-Ready pools..."
  for pool_def in "${ODF_POOLS[@]}"; do
    IFS=':' read -r name type param1 param2 <<< "${pool_def}"

    # Skip pools that use existing out-of-box StorageClasses
    case "${name}" in rep3|rep3-virt|rep3-enc|cephfs-rep3) continue ;; esac

    local full_pool_name="perf-test-${name}"
    local sc_name="perf-test-sc-${name}"

    # Only act if SC is missing and pool is now Ready
    if oc get sc "${sc_name}" &>/dev/null; then
      continue
    fi
    local phase
    if [[ "${type}" == "cephfs" ]]; then
      phase=$(oc get cephfilesystem "${full_pool_name}" -n "${ODF_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    else
      phase=$(oc get cephblockpool "${full_pool_name}" -n "${ODF_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    fi
    if [[ "${phase}" == "Ready" ]]; then
      log_info "Pool ${full_pool_name} is Ready but SC ${sc_name} is missing — creating now"
      if [[ "${type}" == "cephfs" ]]; then
        ensure_cephfs_storage_class "${name}" || {
          log_warn "Failed to create StorageClass ${sc_name} during reconciliation"
          pool_failures=$((pool_failures + 1))
        }
      else
        ensure_storage_class "${name}" "${type}" || {
          log_warn "Failed to create StorageClass ${sc_name} during reconciliation"
          pool_failures=$((pool_failures + 1))
        }
      fi
    fi
  done

  # Wait for PG autoscaler to converge before benchmarks begin
  wait_for_pg_convergence "${PG_CONVERGENCE_TIMEOUT}" || true

  log_info "=== ODF storage pool setup complete ==="
  log_info "StorageClasses available:"
  oc get sc | grep -E "(perf-test-sc|${ODF_DEFAULT_SC}|${ODF_DEFAULT_CEPHFS_SC})" || true

  if [[ ${pool_failures} -gt 0 ]]; then
    log_warn "${pool_failures} pool(s) failed to create — check logs above"
    return 1
  fi
}

main "$@"
