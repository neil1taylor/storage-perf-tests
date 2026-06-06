#!/usr/bin/env bash
# =============================================================================
# 00-config.sh — Central configuration for VM storage performance tests
# IBM Cloud ROKS + OpenShift Virtualization + ODF + IBM Cloud File/Block
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Ensure local project binaries (virtctl, timeout wrapper) are on PATH
# ---------------------------------------------------------------------------
SCRIPT_DIR_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${SCRIPT_DIR_CONFIG}:${PATH}"

# ---------------------------------------------------------------------------
# Cluster connectivity check
# ---------------------------------------------------------------------------
if [[ "${OC_SKIP_CLUSTER_CHECK:-false}" != "true" ]]; then
  if ! oc cluster-info &>/dev/null; then
    echo "[FATAL] oc CLI not authenticated or cluster unreachable. Run 'oc login' first." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Cluster type detection (BM vs VSI)
# ---------------------------------------------------------------------------
detect_cluster_type() {
  local flavors
  flavors=$(oc get nodes -l node-role.kubernetes.io/worker= \
    -o jsonpath='{.items[*].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "")
  if [[ "${flavors}" == *".metal."* ]] || [[ "${flavors}" == *"metal"* ]]; then
    echo "bm"
  else
    echo "vsi"
  fi
}

# ---------------------------------------------------------------------------
# Cluster zone topology detection
# ---------------------------------------------------------------------------
detect_cluster_zones() {
  local zone_list
  zone_list=$(oc get nodes -l node-role.kubernetes.io/worker= \
    -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "")
  if [[ -z "${zone_list}" ]]; then
    echo "0"
    return
  fi
  echo "${zone_list}" | tr ' ' '\n' | sort -u | grep -c . || echo "0"
}

detect_cluster_region() {
  oc get nodes -l node-role.kubernetes.io/worker= \
    -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}' 2>/dev/null || echo "unknown"
}

export CLUSTER_TYPE="${CLUSTER_TYPE:-$(detect_cluster_type)}"
export WORKER_FLAVOR="${WORKER_FLAVOR:-$(oc get nodes -l node-role.kubernetes.io/worker= \
  -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")}"
export WORKER_COUNT="${WORKER_COUNT:-$(oc get nodes -l node-role.kubernetes.io/worker= \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')}"

export CLUSTER_ZONE_COUNT="${CLUSTER_ZONE_COUNT:-$(detect_cluster_zones)}"
export CLUSTER_REGION="${CLUSTER_REGION:-$(detect_cluster_region)}"
export CLUSTER_ZONES="${CLUSTER_ZONES:-$(oc get nodes -l node-role.kubernetes.io/worker= \
  -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null | \
  tr ' ' '\n' | sort -u | paste -sd ',' - || echo "unknown")}"
export CLUSTER_MULTI_AZ="false"
if [[ "${CLUSTER_ZONE_COUNT}" -gt 1 ]]; then
  export CLUSTER_MULTI_AZ="true"
fi

if [[ "${CLUSTER_TYPE}" == "bm" ]]; then
  if [[ "${CLUSTER_MULTI_AZ}" == "true" ]]; then
    export CLUSTER_DESCRIPTION="${CLUSTER_DESCRIPTION:-IBM Cloud ROKS (${WORKER_FLAVOR} bare metal, NVMe, ${WORKER_COUNT} workers, ${CLUSTER_ZONE_COUNT} AZs in ${CLUSTER_REGION})}"
  else
    export CLUSTER_DESCRIPTION="${CLUSTER_DESCRIPTION:-IBM Cloud ROKS (${WORKER_FLAVOR} bare metal, NVMe, ${WORKER_COUNT} workers)}"
  fi
else
  if [[ "${CLUSTER_MULTI_AZ}" == "true" ]]; then
    export CLUSTER_DESCRIPTION="${CLUSTER_DESCRIPTION:-IBM Cloud ROKS (${WORKER_FLAVOR} VSI, IBM Cloud Block-backed ODF, ${WORKER_COUNT} workers, ${CLUSTER_ZONE_COUNT} AZs in ${CLUSTER_REGION})}"
  else
    export CLUSTER_DESCRIPTION="${CLUSTER_DESCRIPTION:-IBM Cloud ROKS (${WORKER_FLAVOR} VSI, IBM Cloud Block-backed ODF, ${WORKER_COUNT} workers)}"
  fi
fi

# ---------------------------------------------------------------------------
# Cluster / namespace
# ---------------------------------------------------------------------------
export TEST_NAMESPACE="${TEST_NAMESPACE:-vm-perf-test}"
export ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"

# ---------------------------------------------------------------------------
# VM guest image (cloned from built-in OpenShift Virtualization DataSource)
# ---------------------------------------------------------------------------
export DATASOURCE_NAME="${DATASOURCE_NAME:-centos-stream9}"
export DATASOURCE_NAMESPACE="${DATASOURCE_NAMESPACE:-openshift-virtualization-os-images}"
export VM_IMAGE_NAME="centos-cloud"
export VM_SSH_USER="${VM_SSH_USER:-cloud-user}"

# ---------------------------------------------------------------------------
# VM sizes  (name  vCPU  memory)
# ---------------------------------------------------------------------------
declare -a VM_SIZES=(
  "small:2:4Gi"
  "medium:4:8Gi"
  "large:8:16Gi"
)
export VM_SIZES

# ---------------------------------------------------------------------------
# PVC sizes to test
# ---------------------------------------------------------------------------
# Minimum 150Gi: IBM Cloud File dp2 profile enforces max ~25 IOPS/GB,
# so the 3000-IOPS SC requires ≥120Gi to provision.
declare -a PVC_SIZES=( "150Gi" "500Gi" "1000Gi" )
export PVC_SIZES

# ---------------------------------------------------------------------------
# Concurrency levels (number of VMs per storage pool)
# ---------------------------------------------------------------------------
declare -a CONCURRENCY_LEVELS=( 1 5 10 )
export CONCURRENCY_LEVELS

# ---------------------------------------------------------------------------
# ODF storage pools — name:type:params
# failureDomain is set cluster-wide by ocs-operator (StorageCluster .status.failureDomain,
# typically "rack" on ROKS) and auto-detected by 01-setup-storage-pools.sh.
#   replicated    → replicated.size=N
#   erasurecoded  → erasureCoded.dataChunks=K,codingChunks=M
#   cephfs        → CephFilesystem with data_replica_count=N (metadata pool always size=3)
# ---------------------------------------------------------------------------
declare -a ODF_POOLS=(
  "rep3:replicated:3"
  "rep3-virt:replicated:3"
  "rep3-enc:replicated:3"
  "cephfs-rep3:cephfs:3"
  "rep2:replicated:2"
  "rep1:replicated:1"
  "cephfs-rep2:cephfs:2"
  "ec-2-1:erasurecoded:2:1"
  "ec-3-1:erasurecoded:3:1"
  "ec-2-2:erasurecoded:2:2"
  "ec-4-2:erasurecoded:4:2"
)
export ODF_POOLS

# Default ODF StorageClass (ROKS out-of-box, rep=3)
export ODF_DEFAULT_SC="ocs-storagecluster-ceph-rbd"

# Default ODF CephFS StorageClass (ROKS out-of-box)
export ODF_DEFAULT_CEPHFS_SC="ocs-storagecluster-cephfs"

# MDS readiness timeout for custom CephFilesystem creation (seconds)
export MDS_READY_TIMEOUT="${MDS_READY_TIMEOUT:-300}"

# ---------------------------------------------------------------------------
# IBM Cloud File CSI — StorageClass profiles to test
# Discover dynamically via: oc get sc | grep vpc-file
# Fallback list (common ROKS profiles):
# ---------------------------------------------------------------------------
declare -a FILE_CSI_PROFILES=(
  "ibmc-vpc-file-500-iops"
  "ibmc-vpc-file-1000-iops"
  "ibmc-vpc-file-3000-iops"
  # "ibmc-vpc-file-eit"  # EIT not supported on RHCOS (ROKS worker nodes)
  "ibmc-vpc-file-min-iops"
)
export FILE_CSI_PROFILES

# Set to "auto" to discover all vpc-file StorageClasses at runtime
export FILE_CSI_DISCOVERY="auto"
# When auto-discovering, skip -metro- and -retain- variants on single-zone clusters.
# On multi-zone clusters, metro SCs may have different performance characteristics
# (cross-AZ NFS access), so include them by default.
if [[ "${CLUSTER_MULTI_AZ}" == "true" ]]; then
  export FILE_CSI_DEDUP="${FILE_CSI_DEDUP:-false}"
else
  export FILE_CSI_DEDUP="${FILE_CSI_DEDUP:-true}"
fi

# ---------------------------------------------------------------------------
# fio settings
# ---------------------------------------------------------------------------
export FIO_RUNTIME="${FIO_RUNTIME:-120}"          # seconds per test
export FIO_RAMP_TIME="${FIO_RAMP_TIME:-10}"       # warmup before measurement
export FIO_IODEPTH="${FIO_IODEPTH:-32}"
export FIO_NUMJOBS="${FIO_NUMJOBS:-4}"
export FIO_OUTPUT_FORMAT="json+"
export FIO_TEST_FILE_SIZE="${FIO_TEST_FILE_SIZE:-4G}"
export FIO_RATE_IOPS="${FIO_RATE_IOPS:-0}"               # 0 = unlimited; >0 = per-job IOPS cap (scale-test)

# Scale-test mode settings
export SCALE_VM_BATCH_SIZE="${SCALE_VM_BATCH_SIZE:-20}"   # VMs created per batch (avoids API server overload)
export SCALE_RATE_IOPS="${SCALE_RATE_IOPS:-500}"          # Default per-VM IOPS cap for scale-test ramp
export SCALE_LATENCY_SLA_MS="${SCALE_LATENCY_SLA_MS:-5}"  # p99 latency threshold (ms) — ramp stops on breach
export SCALE_MAX_VMS="${SCALE_MAX_VMS:-256}"               # Hard ceiling for ramp (prevents runaway)
export SCALE_SYNC_BARRIER_SECS="${SCALE_SYNC_BARRIER_SECS:-180}"  # Per-VM headroom (boot+prefill+buffer) before synchronized fio measurement start

# Block sizes to test
declare -a FIO_BLOCK_SIZES=( "4k" "64k" "1M" )
export FIO_BLOCK_SIZES

# Profiles that define their own per-job block sizes (skip the block-size loop)
declare -a FIO_FIXED_BS_PROFILES=( "db-oltp" "app-server" "data-pipeline" )
export FIO_FIXED_BS_PROFILES

# ---------------------------------------------------------------------------
# fio workload profiles (filenames in fio-profiles/)
# ---------------------------------------------------------------------------
declare -a FIO_PROFILES=(
  "sequential-rw"
  "random-rw"
  "mixed-70-30"
  "db-oltp"
  "app-server"
  "data-pipeline"
)
export FIO_PROFILES

# ---------------------------------------------------------------------------
# Timeouts / polling
# ---------------------------------------------------------------------------
export VM_READY_TIMEOUT="${VM_READY_TIMEOUT:-900}"  # seconds to wait for VM to become Ready
export VM_SSH_TIMEOUT=300         # seconds to wait for SSH inside VM
export FIO_COMPLETION_TIMEOUT=1800 # max wait for a single fio run (30min; multi-job profiles with stonewall can exceed 15min at high concurrency on slow pools)
export POLL_INTERVAL=10           # seconds between status checks
export DV_STALL_THRESHOLD="${DV_STALL_THRESHOLD:-5}"   # polls with no progress change before warning
export DV_STALL_ACTION="${DV_STALL_ACTION:-warn}"       # "warn" = log warning; "fail" = abort immediately
export PG_CONVERGENCE_TIMEOUT="${PG_CONVERGENCE_TIMEOUT:-300}"  # max wait for PG autoscaler convergence
export PG_CONVERGENCE_INTERVAL="${PG_CONVERGENCE_INTERVAL:-30}" # seconds between PG convergence checks

# ---------------------------------------------------------------------------
# Results / reporting
# ---------------------------------------------------------------------------
export RESULTS_DIR="${RESULTS_DIR:-./results}"
export REPORTS_DIR="${REPORTS_DIR:-./reports}"
mkdir -p "${RESULTS_DIR}" "${REPORTS_DIR}"
export TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"
export RUN_ID="${RUN_ID:-perf-${TIMESTAMP}}"

# ---------------------------------------------------------------------------
# SSH key for VM access (generated if not provided)
# ---------------------------------------------------------------------------
export SSH_KEY_PATH="${SSH_KEY_PATH:-./ssh-keys/perf-test-key}"

# ---------------------------------------------------------------------------
# IBM Cloud Block CSI — StorageClass profiles to test (VSI clusters only)
# Discover dynamically via: oc get sc | grep vpc-block
# Fallback list (common ROKS profiles):
# ---------------------------------------------------------------------------
export BLOCK_CSI_ENABLED="${BLOCK_CSI_ENABLED:-true}"
export BLOCK_CSI_DISCOVERY="auto"
# When auto-discovering, skip -metro- and -retain- variants on single-zone clusters.
# On multi-zone clusters, metro SCs may have different performance characteristics
# (cross-AZ block access), so include them by default.
if [[ "${CLUSTER_MULTI_AZ}" == "true" ]]; then
  export BLOCK_CSI_DEDUP="${BLOCK_CSI_DEDUP:-false}"
else
  export BLOCK_CSI_DEDUP="${BLOCK_CSI_DEDUP:-true}"
fi
declare -a BLOCK_CSI_PROFILES=(
  "ibmc-vpc-block-5iops-tier"
  "ibmc-vpc-block-10iops-tier"
  "ibmc-vpc-block-custom"
)
export BLOCK_CSI_PROFILES

# ---------------------------------------------------------------------------
# IBM Cloud Pool CSI — FileSharePool-backed StorageClass
# The Pool CSI driver pre-provisions a pool of NFS file shares for faster
# PVC binding. When the CRD exists, 02-setup-file-storage.sh auto-creates
# the FileSharePool and waits for the driver to create the StorageClass.
# ---------------------------------------------------------------------------
export POOL_CSI_NAME="${POOL_CSI_NAME:-bench-pool}"
export POOL_CSI_PROFILE="${POOL_CSI_PROFILE:-dp2}"
export POOL_CSI_IOPS="${POOL_CSI_IOPS:-40000}"
export POOL_CSI_SHARE_SIZE="${POOL_CSI_SHARE_SIZE:-4000Gi}"
export POOL_CSI_MAX_SHARES="${POOL_CSI_MAX_SHARES:-1}"
export POOL_CSI_ALLOCATION_STRATEGY="${POOL_CSI_ALLOCATION_STRATEGY:-spread}"
export POOL_CSI_DEFAULT_UID="${POOL_CSI_DEFAULT_UID:-107}"
export POOL_CSI_DEFAULT_GID="${POOL_CSI_DEFAULT_GID:-107}"
export POOL_CSI_DEFAULT_PERMISSIONS="${POOL_CSI_DEFAULT_PERMISSIONS:-0777}"
export POOL_RESOURCE_GROUP="${POOL_RESOURCE_GROUP:-}"

# ---------------------------------------------------------------------------
# Extra StorageClasses to test (pre-existing SCs, not managed by setup scripts)
# Can also be added at runtime via --extra-sc flag on 04-run-tests.sh / run-all.sh
# ---------------------------------------------------------------------------
declare -a EXTRA_STORAGE_CLASSES=()
export EXTRA_STORAGE_CLASSES

# =============================================================================
# Tune-sweep configuration matrix (ODF OSD resources + host C-state)
# =============================================================================
# Each value is a space-separated list of key=value pairs. Recognised keys:
#   profile   → balanced | performance (StorageCluster.spec.resourceProfile)
#   osd_cpu   → integer CPU cores; sets storageDeviceSets[i].resources requests+limits
#   osd_mem   → memory quantity, e.g. 32Gi; same field as osd_cpu
#   cstate    → on | off
#                 on  = remove the tune-sweep MachineConfig if present
#                 off = apply MC with kernelArgs
#                       intel_idle.max_cstate=0 processor.max_cstate=0
#
#   cephconfig_<ceph_key> → any string
#                 Maps to ceph config-database key 'osd:<ceph_key>'. Merged
#                 into .spec.managedResources.cephCluster.cephConfig.osd via
#                 OCS-operator's additive merge. Live propagation (no OSD pod
#                 roll). Common candidates: osd_mclock_profile,
#                 bluestore_throttle_bytes, bluestore_throttle_deferred_bytes,
#                 osd_memory_target.
#
# big-osd sizing: must leave room for the test workload's VMs to schedule
# alongside the OSDs. Per-host arithmetic for bx2d.metal.96x384 (96c/384Gi,
# 8 OSDs/host, ~83% allocatable after kubelet/system reservations ≈ 80c/320Gi):
#   • 8 OSDs × 6 vCPU = 48c per host (~60% of allocatable)
#   • Leaves ~32c per host (~96c cluster-wide) for the workload and system pods
#   • 32 test VMs × 2 vCPU = 64c cluster-wide, fits comfortably
# At 8 vCPU per OSD (the slide's value), 8 × 8 = 64c/host would consume all
# allocatable CPU and starve workload VMs (observed 2026-06-04: VM #32 hung
# with "Insufficient cpu" for 15 min). On hosts with ≥128 cores or more workers,
# scale osd_cpu/osd_mem back up to match the slide's 8c/32-64Gi target.
# =============================================================================
declare -A TUNE_CONFIGS
TUNE_CONFIGS[default]='profile=balanced cstate=on'
TUNE_CONFIGS[cstate-off]='profile=balanced cstate=off'
TUNE_CONFIGS[big-osd]='osd_cpu=6 osd_mem=24Gi cstate=on'
TUNE_CONFIGS[big-osd+cstate-off]='osd_cpu=6 osd_mem=24Gi cstate=off'
TUNE_CONFIGS[big-osd+mclock]='osd_cpu=6 osd_mem=24Gi cephconfig_osd_mclock_profile=high_client_ops cephconfig_bluestore_throttle_bytes=262144 cephconfig_bluestore_throttle_deferred_bytes=262144 cephconfig_osd_memory_target=20000000000 cstate=on'
export TUNE_CONFIGS

TUNE_DEFAULT_CONFIGS="${TUNE_DEFAULT_CONFIGS:-default,cstate-off,big-osd,big-osd+cstate-off}"
TUNE_QD_LIST="${TUNE_QD_LIST:-1,2,4,8,16,32,64}"
TUNE_FIXED_VMS="${TUNE_FIXED_VMS:-200}"
TUNE_MC_NAME="${TUNE_MC_NAME:-99-perf-test-cstate-off}"
TUNE_MCP_TIMEOUT="${TUNE_MCP_TIMEOUT:-1800}"   # 30 min for full MCP rollout
TUNE_OSD_TIMEOUT="${TUNE_OSD_TIMEOUT:-1200}"   # 20 min for OSD restart
TUNE_RATE_IOPS="${TUNE_RATE_IOPS:-500}"
TUNE_LATENCY_SLA_MS="${TUNE_LATENCY_SLA_MS:-5}"

export TUNE_DEFAULT_CONFIGS TUNE_QD_LIST TUNE_FIXED_VMS TUNE_MC_NAME
export TUNE_MCP_TIMEOUT TUNE_OSD_TIMEOUT TUNE_RATE_IOPS TUNE_LATENCY_SLA_MS

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
export LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR
export LOG_FILE="${RESULTS_DIR}/${RUN_ID}.log"

echo "[config] Run ID: ${RUN_ID}"
echo "[config] Cluster: ${CLUSTER_TYPE} (${WORKER_FLAVOR}, ${WORKER_COUNT} workers)"
echo "[config] Region: ${CLUSTER_REGION}, Zones: ${CLUSTER_ZONES} (multi-AZ=${CLUSTER_MULTI_AZ})"
echo "[config] CSI dedup: file=${FILE_CSI_DEDUP}, block=${BLOCK_CSI_DEDUP}"
echo "[config] Namespace: ${TEST_NAMESPACE}"
echo "[config] ODF pools: ${#ODF_POOLS[@]}"
echo "[config] File CSI profiles: ${FILE_CSI_DISCOVERY}"
echo "[config] Block CSI: ${BLOCK_CSI_ENABLED} (discovery=${BLOCK_CSI_DISCOVERY})"
echo "[config] Pool CSI: auto-detect (name=${POOL_CSI_NAME})"
echo "[config] VM sizes: ${#VM_SIZES[@]}, PVC sizes: ${#PVC_SIZES[@]}"
echo "[config] Concurrency levels: ${CONCURRENCY_LEVELS[*]}"
if [[ ${#EXTRA_STORAGE_CLASSES[@]} -gt 0 ]]; then
  echo "[config] Extra StorageClasses: ${EXTRA_STORAGE_CLASSES[*]}"
fi
