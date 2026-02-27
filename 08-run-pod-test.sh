#!/usr/bin/env bash
# =============================================================================
# 08-run-pod-test.sh — Run fio directly in a pod (no QEMU) for krbd baseline
#
# Runs the same 3 rank-mode fio profiles (random-rw/4k, sequential-rw/1M,
# mixed-70-30/4k) in a pod with an RBD PVC, eliminating the QEMU/virtio layer
# to measure the pure krbd overhead. Results land in the standard results/ tree
# with vm_size="pod" so the existing collect/report pipeline works unchanged.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"

# ---------------------------------------------------------------------------
# Rank-mode fio settings (match 04-run-tests.sh --rank)
# ---------------------------------------------------------------------------
FIO_RUNTIME=60
FIO_RAMP_TIME=10
FIO_IODEPTH=32
FIO_NUMJOBS=4
FIO_TEST_FILE_SIZE=4G
PVC_SIZE=150Gi

# Profiles to run: profile:block_size
declare -a RANK_TESTS=(
  "random-rw:4k"
  "sequential-rw:1M"
  "mixed-70-30:4k"
)

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
POOL_NAME=""
CLEANUP_ONLY=false

usage() {
  echo "Usage: $0 --pool <name> [--cleanup]"
  echo ""
  echo "Run fio directly in a pod (no QEMU) to measure pure krbd overhead."
  echo "Uses the same 3 rank-mode profiles as ./04-run-tests.sh --rank."
  echo ""
  echo "Options:"
  echo "  --pool <name>   Storage pool to test (e.g. rep3-virt, rep3, rep2)"
  echo "  --cleanup       Only clean up leftover pod/PVC from a previous run"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool)    POOL_NAME="$2"; shift 2 ;;
    --cleanup) CLEANUP_ONLY=true; shift ;;
    -h|--help) usage ;;
    *)         echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -z "${POOL_NAME}" ]] && { echo "Error: --pool is required" >&2; usage; }

# ---------------------------------------------------------------------------
# Derived names
# ---------------------------------------------------------------------------
SC_NAME=$(get_storage_class_for_pool "${POOL_NAME}")
POD_NAME="perf-pod-${POOL_NAME}-test"
PVC_NAME="perf-pod-${POOL_NAME}-data"

# Sanitize names (lowercase, alphanumeric + hyphens, max 63 chars)
POD_NAME="${POD_NAME,,}"
POD_NAME="${POD_NAME//[^a-z0-9-]/-}"
POD_NAME="${POD_NAME:0:63}"
POD_NAME="${POD_NAME%-}"

PVC_NAME="${PVC_NAME,,}"
PVC_NAME="${PVC_NAME//[^a-z0-9-]/-}"
PVC_NAME="${PVC_NAME:0:63}"
PVC_NAME="${PVC_NAME%-}"

# ---------------------------------------------------------------------------
# Cleanup function
# ---------------------------------------------------------------------------
cleanup_pod() {
  log_info "Cleaning up pod and PVC..."
  oc delete pod "${POD_NAME}" -n "${TEST_NAMESPACE}" --wait=true --timeout=60s 2>/dev/null || true
  oc delete pvc "${PVC_NAME}" -n "${TEST_NAMESPACE}" --wait=false 2>/dev/null || true
}

trap cleanup_pod EXIT

if [[ "${CLEANUP_ONLY}" == true ]]; then
  cleanup_pod
  log_info "Cleanup complete"
  exit 0
fi

# ---------------------------------------------------------------------------
# Create PVC
# ---------------------------------------------------------------------------
log_info "Creating PVC ${PVC_NAME} (sc=${SC_NAME}, size=${PVC_SIZE})"
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app: pod-perf-test
    perf-test/run-id: ${RUN_ID}
    perf-test/storage-pool: ${POOL_NAME}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${SC_NAME}
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF

# ---------------------------------------------------------------------------
# Create Pod
# ---------------------------------------------------------------------------
log_info "Creating pod ${POD_NAME} (image=quay.io/cloud-bulldozer/fio:latest)"
oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app: pod-perf-test
    perf-test/run-id: ${RUN_ID}
    perf-test/storage-pool: ${POOL_NAME}
spec:
  containers:
    - name: fio
      image: quay.io/cloud-bulldozer/fio:latest
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: data
          mountPath: /mnt/data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
  terminationGracePeriodSeconds: 10
EOF

# ---------------------------------------------------------------------------
# Wait for pod to be Running
# ---------------------------------------------------------------------------
log_info "Waiting for pod ${POD_NAME} to be Running..."
start_time=$(date +%s)
pod_timeout=300

while true; do
  elapsed=$(( $(date +%s) - start_time ))
  if [[ ${elapsed} -ge ${pod_timeout} ]]; then
    log_error "Pod ${POD_NAME} did not reach Running state within ${pod_timeout}s"
    oc describe pod "${POD_NAME}" -n "${TEST_NAMESPACE}" 2>/dev/null | tail -20 >&2
    exit 1
  fi

  phase=$(oc get pod "${POD_NAME}" -n "${TEST_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

  if [[ "${phase}" == "Running" ]]; then
    log_info "Pod ${POD_NAME} is Running (took ${elapsed}s)"
    break
  fi

  log_debug "Pod phase: ${phase} (${elapsed}s elapsed)"
  sleep "${POLL_INTERVAL}"
done

# ---------------------------------------------------------------------------
# Run fio for each rank-mode profile
# ---------------------------------------------------------------------------
declare -a SUMMARY_LINES=()

log_info "Running ${#RANK_TESTS[@]} fio profiles on pool ${POOL_NAME} (sc=${SC_NAME})"
echo ""

for test_spec in "${RANK_TESTS[@]}"; do
  profile="${test_spec%%:*}"
  bs="${test_spec#*:}"

  profile_path="${SCRIPT_DIR}/fio-profiles/${profile}.fio"
  if [[ ! -f "${profile_path}" ]]; then
    log_error "Profile not found: ${profile_path}"
    continue
  fi

  # Render the fio profile
  fio_content=$(render_fio_profile "${profile_path}" "${bs}")

  # Results directory (matches existing tree structure: pool/vm_size/pvc_size/concurrency/profile/bs/)
  result_dir="${RESULTS_DIR}/${POOL_NAME}/pod/${PVC_SIZE}/1/${profile}/${bs}"
  mkdir -p "${result_dir}"

  # Write rendered fio job to a temp file and copy into pod
  tmp_fio=$(mktemp /tmp/fio-job-XXXXXX)
  echo "${fio_content}" > "${tmp_fio}"
  oc cp "${tmp_fio}" "${TEST_NAMESPACE}/${POD_NAME}:/tmp/fio-job.fio" 2>/dev/null || {
    log_error "Failed to copy fio job into pod for ${profile}/${bs}"
    rm -f "${tmp_fio}"
    continue
  }
  rm -f "${tmp_fio}"

  log_info "Running fio: ${profile}/${bs} (runtime=${FIO_RUNTIME}s, ramp=${FIO_RAMP_TIME}s, iodepth=${FIO_IODEPTH}, numjobs=${FIO_NUMJOBS})"

  # Run fio inside the pod
  test_start=$(date +%s)
  oc exec -n "${TEST_NAMESPACE}" "${POD_NAME}" -- \
    fio /tmp/fio-job.fio \
      --directory=/mnt/data \
      --output-format=json \
      --output=/mnt/data/results.json || {
    log_error "fio failed for ${profile}/${bs}"
    continue
  }

  test_elapsed=$(( $(date +%s) - test_start ))
  log_info "fio ${profile}/${bs} completed in $(_format_duration ${test_elapsed})"

  # Copy results out
  result_file="${result_dir}/${POD_NAME}-fio.json"
  oc cp "${TEST_NAMESPACE}/${POD_NAME}:/mnt/data/results.json" "${result_file}" 2>/dev/null || {
    log_warn "Failed to copy results for ${profile}/${bs}"
  }

  # Clean up test files in the pod for next run
  oc exec -n "${TEST_NAMESPACE}" "${POD_NAME}" -- \
    sh -c 'rm -f /mnt/data/results.json; find /mnt/data -maxdepth 1 -type f -name "*.0" -delete' 2>/dev/null || true

  # Parse and display inline summary
  if [[ -f "${result_file}" ]] && jq -e '.jobs | length > 0' "${result_file}" &>/dev/null; then
    # Extract metrics from each job
    while IFS= read -r job_json; do
      job_name=$(echo "${job_json}" | jq -r '.jobname')
      read_iops=$(echo "${job_json}" | jq -r '.read.iops // 0' | xargs printf '%.0f')
      read_bw=$(echo "${job_json}" | jq -r '.read.bw // 0')  # KiB/s
      read_lat=$(echo "${job_json}" | jq -r '.read.clat_ns.mean // 0')  # ns
      write_iops=$(echo "${job_json}" | jq -r '.write.iops // 0' | xargs printf '%.0f')
      write_bw=$(echo "${job_json}" | jq -r '.write.bw // 0')  # KiB/s
      write_lat=$(echo "${job_json}" | jq -r '.write.clat_ns.mean // 0')  # ns

      # Convert latency from ns to ms
      read_lat_ms=$(echo "${read_lat}" | awk '{printf "%.2f", $1/1000000}')
      write_lat_ms=$(echo "${write_lat}" | awk '{printf "%.2f", $1/1000000}')

      # Convert BW to MiB/s
      read_bw_mib=$(echo "${read_bw}" | awk '{printf "%.1f", $1/1024}')
      write_bw_mib=$(echo "${write_bw}" | awk '{printf "%.1f", $1/1024}')

      summary="  ${profile}/${bs} [${job_name}]: "
      if [[ "${read_iops}" != "0" ]]; then
        summary+="R: ${read_iops} IOPS (${read_bw_mib} MiB/s, ${read_lat_ms}ms) "
      fi
      if [[ "${write_iops}" != "0" ]]; then
        summary+="W: ${write_iops} IOPS (${write_bw_mib} MiB/s, ${write_lat_ms}ms)"
      fi
      SUMMARY_LINES+=("${summary}")
      echo "${summary}"
    done < <(jq -c '.jobs[]' "${result_file}")
  else
    log_warn "No valid results for ${profile}/${bs}"
  fi

  echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================================="
echo "Pod fio Results — ${POOL_NAME} (sc=${SC_NAME})"
echo "============================================================================="
echo "Run ID:    ${RUN_ID}"
echo "PVC Size:  ${PVC_SIZE}"
echo "Settings:  runtime=${FIO_RUNTIME}s, ramp=${FIO_RAMP_TIME}s, iodepth=${FIO_IODEPTH}, numjobs=${FIO_NUMJOBS}, size=${FIO_TEST_FILE_SIZE}"
echo ""
for line in "${SUMMARY_LINES[@]}"; do
  echo "${line}"
done
echo ""
echo "Results saved to: ${RESULTS_DIR}/${POOL_NAME}/pod/${PVC_SIZE}/1/"
echo "Run ./05-collect-results.sh to include pod results in the CSV."
echo "============================================================================="

# Cleanup handled by trap
log_info "Done. Pod and PVC will be cleaned up."
