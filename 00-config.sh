#!/usr/bin/env bash
# =============================================================================
# 00-config.sh — Central configuration for VM storage performance tests
# IBM Cloud ROKS + OpenShift Virtualization + ODF + IBM Cloud File/Block
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Cluster connectivity check
# ---------------------------------------------------------------------------
if ! oc cluster-info &>/dev/null; then
  echo "[FATAL] oc CLI not authenticated or cluster unreachable. Run 'oc login' first." >&2
  exit 1
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

export CLUSTER_TYPE="${CLUSTER_TYPE:-$(detect_cluster_type)}"
export WORKER_FLAVOR="${WORKER_FLAVOR:-$(oc get nodes -l node-role.kubernetes.io/worker= \
  -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "unknown")}"
export WORKER_COUNT="${WORKER_COUNT:-$(oc get nodes -l node-role.kubernetes.io/worker= \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')}"

if [[ "${CLUSTER_TYPE}" == "bm" ]]; then
  export CLUSTER_DESCRIPTION="${CLUSTER_DESCRIPTION:-IBM Cloud ROKS (${WORKER_FLAVOR} bare metal, NVMe, ${WORKER_COUNT} workers)}"
else
  export CLUSTER_DESCRIPTION="${CLUSTER_DESCRIPTION:-IBM Cloud ROKS (${WORKER_FLAVOR} VSI, IBM Cloud Block-backed ODF, ${WORKER_COUNT} workers)}"
fi

# ---------------------------------------------------------------------------
# Cluster / namespace
# ---------------------------------------------------------------------------
export TEST_NAMESPACE="${TEST_NAMESPACE:-vm-perf-test}"
export ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"

# ---------------------------------------------------------------------------
# VM guest image (cloned from built-in OpenShift Virtualization DataSource)
# ---------------------------------------------------------------------------
export DATASOURCE_NAME="${DATASOURCE_NAME:-fedora}"
export DATASOURCE_NAMESPACE="${DATASOURCE_NAMESPACE:-openshift-virtualization-os-images}"
export VM_IMAGE_NAME="fedora-cloud"

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
#   replicated  → failureDomain=host,replicated.size=N
#   erasurecoded → failureDomain=host,erasureCoded.dataChunks=K,codingChunks=M
# ---------------------------------------------------------------------------
declare -a ODF_POOLS=(
  "rep3:replicated:3"
  "rep3-virt:replicated:3"
  "rep3-enc:replicated:3"
  "rep2:replicated:2"
  "ec-2-1:erasurecoded:2:1"
  "ec-3-1:erasurecoded:3:1"
  "ec-2-2:erasurecoded:2:2"
  "ec-4-2:erasurecoded:4:2"
)
export ODF_POOLS

# Default ODF StorageClass (ROKS out-of-box, rep=3)
export ODF_DEFAULT_SC="ocs-storagecluster-ceph-rbd"

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
# When auto-discovering, skip -metro- and -retain- variants (same I/O perf as base SC)
export FILE_CSI_DEDUP="${FILE_CSI_DEDUP:-true}"

# ---------------------------------------------------------------------------
# fio settings
# ---------------------------------------------------------------------------
export FIO_RUNTIME="${FIO_RUNTIME:-120}"          # seconds per test
export FIO_RAMP_TIME="${FIO_RAMP_TIME:-10}"       # warmup before measurement
export FIO_IODEPTH="${FIO_IODEPTH:-32}"
export FIO_NUMJOBS="${FIO_NUMJOBS:-4}"
export FIO_OUTPUT_FORMAT="json+"
export FIO_TEST_FILE_SIZE="${FIO_TEST_FILE_SIZE:-4G}"

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
export VM_READY_TIMEOUT=600       # seconds to wait for VM to become Ready
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
# When auto-discovering, skip -metro- and -retain- variants (same I/O perf as base SC)
export BLOCK_CSI_DEDUP="${BLOCK_CSI_DEDUP:-true}"
declare -a BLOCK_CSI_PROFILES=(
  "ibmc-vpc-block-5iops-tier"
  "ibmc-vpc-block-10iops-tier"
  "ibmc-vpc-block-custom"
)
export BLOCK_CSI_PROFILES

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
export LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR
export LOG_FILE="${RESULTS_DIR}/${RUN_ID}.log"

echo "[config] Run ID: ${RUN_ID}"
echo "[config] Cluster: ${CLUSTER_TYPE} (${WORKER_FLAVOR}, ${WORKER_COUNT} workers)"
echo "[config] Namespace: ${TEST_NAMESPACE}"
echo "[config] ODF pools: ${#ODF_POOLS[@]}"
echo "[config] File CSI profiles: ${FILE_CSI_DISCOVERY}"
echo "[config] Block CSI: ${BLOCK_CSI_ENABLED} (discovery=${BLOCK_CSI_DISCOVERY})"
echo "[config] VM sizes: ${#VM_SIZES[@]}, PVC sizes: ${#PVC_SIZES[@]}"
echo "[config] Concurrency levels: ${CONCURRENCY_LEVELS[*]}"
