#!/usr/bin/env bash
# =============================================================================
# 00-config.sh — Central configuration for VM storage performance tests
# IBM Cloud ROKS + OpenShift Virtualization + ODF + IBM Cloud File
# =============================================================================
set -euo pipefail

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
declare -a PVC_SIZES=( "10Gi" "50Gi" "100Gi" )
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
  # ec-2-2 and ec-4-2 removed: need 4 and 6 failure domains respectively,
  # but this cluster only has 3 worker nodes (failureDomain=host)
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
  "ibmc-vpc-file-2000-iops"
  "ibmc-vpc-file-4000-iops"
  "ibmc-vpc-file-dp2"
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
# fio workload profiles (filenames in 05-fio-profiles/)
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
export FIO_COMPLETION_TIMEOUT=900 # max wait for a single fio run
export POLL_INTERVAL=10           # seconds between status checks
export DV_STALL_THRESHOLD="${DV_STALL_THRESHOLD:-5}"   # polls with no progress change before warning
export DV_STALL_ACTION="${DV_STALL_ACTION:-warn}"       # "warn" = log warning; "fail" = abort immediately

# ---------------------------------------------------------------------------
# Results / reporting
# ---------------------------------------------------------------------------
export RESULTS_DIR="${RESULTS_DIR:-./results}"
export REPORTS_DIR="${REPORTS_DIR:-./reports}"
mkdir -p "${RESULTS_DIR}" "${REPORTS_DIR}"
export TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
export RUN_ID="perf-${TIMESTAMP}"

# ---------------------------------------------------------------------------
# SSH key for VM access (generated if not provided)
# ---------------------------------------------------------------------------
export SSH_KEY_PATH="${SSH_KEY_PATH:-./ssh-keys/perf-test-key}"

# ---------------------------------------------------------------------------
# Bare metal worker info (for report metadata)
# ---------------------------------------------------------------------------
export BM_FLAVOR="${BM_FLAVOR:-bx3d}"
export BM_DESCRIPTION="IBM Cloud ROKS bare metal with NVMe"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
export LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR
export LOG_FILE="${RESULTS_DIR}/${RUN_ID}.log"

echo "[config] Run ID: ${RUN_ID}"
echo "[config] Namespace: ${TEST_NAMESPACE}"
echo "[config] ODF pools: ${#ODF_POOLS[@]}"
echo "[config] File CSI profiles: ${FILE_CSI_DISCOVERY}"
echo "[config] VM sizes: ${#VM_SIZES[@]}, PVC sizes: ${#PVC_SIZES[@]}"
echo "[config] Concurrency levels: ${CONCURRENCY_LEVELS[*]}"
