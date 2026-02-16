#!/usr/bin/env bash
# =============================================================================
# lib/vm-helpers.sh — VM lifecycle helper functions
# =============================================================================

# ---------------------------------------------------------------------------
# macOS compatibility: use gtimeout if timeout is not available
# ---------------------------------------------------------------------------
if ! command -v timeout &>/dev/null; then
  if command -v gtimeout &>/dev/null; then
    timeout() { gtimeout "$@"; }
  else
    # Fallback: run without timeout (best effort)
    timeout() { shift; "$@"; }
  fi
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log() {
  local level="$1"; shift
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[${ts}] [${level}] $*" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "[${ts}] [${level}] $*" >> "${LOG_FILE}" 2>/dev/null || true
  fi
}

log_debug() { [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]] && _log "DEBUG" "$@" || true; }
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Format a duration in seconds to human-readable (e.g. 3m42s, 1h05m30s)
# ---------------------------------------------------------------------------
_format_duration() {
  local seconds="$1"
  if [[ ${seconds} -ge 3600 ]]; then
    printf '%dh%02dm%02ds' $((seconds/3600)) $((seconds%3600/60)) $((seconds%60))
  elif [[ ${seconds} -ge 60 ]]; then
    printf '%dm%02ds' $((seconds/60)) $((seconds%60))
  else
    printf '%ds' "${seconds}"
  fi
}

# ---------------------------------------------------------------------------
# SSH key management
# ---------------------------------------------------------------------------
ensure_ssh_key() {
  local key_path="${SSH_KEY_PATH:-./ssh-keys/perf-test-key}"
  local key_dir
  key_dir="$(dirname "${key_path}")"

  if [[ ! -f "${key_path}" ]]; then
    log_info "Generating SSH key pair: ${key_path}"
    mkdir -p "${key_dir}"
    ssh-keygen -t ed25519 -f "${key_path}" -N "" -C "perf-test" -q
  fi

  export SSH_PUB_KEY
  SSH_PUB_KEY="$(cat "${key_path}.pub")"
}

# ---------------------------------------------------------------------------
# Resolve StorageClass name from pool definition
# ---------------------------------------------------------------------------
get_storage_class_for_pool() {
  local pool_name="$1"

  if [[ "${pool_name}" == "rep3" ]]; then
    echo "${ODF_DEFAULT_SC}"
  elif [[ "${pool_name}" == "rep3-virt" ]]; then
    echo "ocs-storagecluster-ceph-rbd-virtualization"
  elif [[ "${pool_name}" == "rep3-enc" ]]; then
    echo "ocs-storagecluster-ceph-rbd-encrypted"
  elif [[ "${pool_name}" == *vpc-block* ]]; then
    # IBM Cloud Block — SC name is the pool name itself
    echo "${pool_name}"
  elif [[ "${pool_name}" == ibmc-* ]] || [[ "${pool_name}" == *vpc-file* ]]; then
    # IBM Cloud File — SC name is the pool name itself
    echo "${pool_name}"
  else
    echo "perf-test-sc-${pool_name}"
  fi
}

# ---------------------------------------------------------------------------
# Build all storage pool names to test (ODF + File)
# ---------------------------------------------------------------------------
get_all_storage_pools() {
  local -a pools=()

  # ODF pools
  for pool_def in "${ODF_POOLS[@]}"; do
    local name
    name=$(echo "${pool_def}" | cut -d: -f1)
    pools+=("${name}")
  done

  # IBM Cloud File pools (from discovery file or config)
  local file_sc_list="${RESULTS_DIR}/file-storage-classes.txt"
  if [[ -f "${file_sc_list}" ]]; then
    while IFS= read -r sc; do
      [[ -n "${sc}" ]] && pools+=("${sc}")
    done < "${file_sc_list}"
  else
    for sc in "${FILE_CSI_PROFILES[@]}"; do
      pools+=("${sc}")
    done
  fi

  # IBM Cloud Block pools (from discovery file)
  local block_sc_list="${RESULTS_DIR}/block-storage-classes.txt"
  if [[ -f "${block_sc_list}" ]]; then
    while IFS= read -r sc; do
      [[ -n "${sc}" ]] && pools+=("${sc}")
    done < "${block_sc_list}"
  fi

  printf '%s\n' "${pools[@]}"
}

# ---------------------------------------------------------------------------
# Generate cloud-init YAML from template with variable substitution
# ---------------------------------------------------------------------------
render_cloud_init() {
  local template_path="$1"
  local fio_job_content="$2"
  local vm_name="$3"
  local test_dir="${4:-/mnt/data}"

  local rendered
  rendered=$(cat "${template_path}")

  rendered="${rendered//__VM_NAME__/${vm_name}}"
  rendered="${rendered//__TEST_DIR__/${test_dir}}"
  rendered="${rendered//__RUNTIME__/${FIO_RUNTIME}}"
  rendered="${rendered//__RAMP_TIME__/${FIO_RAMP_TIME}}"
  rendered="${rendered//__IODEPTH__/${FIO_IODEPTH}}"
  rendered="${rendered//__NUMJOBS__/${FIO_NUMJOBS}}"
  rendered="${rendered//__FILE_SIZE__/${FIO_TEST_FILE_SIZE}}"
  rendered="${rendered//__SSH_PUB_KEY__/${SSH_PUB_KEY}}"
  rendered="${rendered//__FIO_TIMEOUT__/${FIO_COMPLETION_TIMEOUT}}"

  # Indent fio job content for YAML embedding (skip first line — it inherits
  # the placeholder's indentation from the template)
  local indented_fio
  indented_fio=$(echo "${fio_job_content}" | sed '2,$s/^/      /')
  rendered="${rendered//__FIO_JOB_CONTENT__/${indented_fio}}"

  echo "${rendered}"
}

# ---------------------------------------------------------------------------
# Render a fio profile with runtime variables
# ---------------------------------------------------------------------------
render_fio_profile() {
  local profile_path="$1"
  local block_size="$2"

  local content
  content=$(cat "${profile_path}")

  content="${content//\$\{RUNTIME\}/${FIO_RUNTIME}}"
  content="${content//\$\{RAMP_TIME\}/${FIO_RAMP_TIME}}"
  content="${content//\$\{IODEPTH\}/${FIO_IODEPTH}}"
  content="${content//\$\{NUMJOBS\}/${FIO_NUMJOBS}}"
  content="${content//\$\{FILE_SIZE\}/${FIO_TEST_FILE_SIZE}}"
  content="${content//\$\{BLOCK_SIZE\}/${block_size}}"

  echo "${content}"
}

# ---------------------------------------------------------------------------
# Create a VM from template with all substitutions
# ---------------------------------------------------------------------------
create_test_vm() {
  local vm_name="$1"
  local sc_name="$2"
  local pvc_size="$3"
  local vcpu="$4"
  local memory="$5"
  local cloud_init_content="$6"
  local pool_name="$7"
  local vm_size_label="$8"
  local template_path="${9:-./vm-templates/vm-template.yaml}"

  log_info "Creating VM: ${vm_name} (sc=${sc_name}, pvc=${pvc_size}, cpu=${vcpu}, mem=${memory})"

  if [[ ! -f "${template_path}" ]]; then
    log_error "Template file not found: ${template_path}"
    return 1
  fi

  local manifest
  manifest=$(cat "${template_path}")

  # Choose root disk SC (use default ODF for all VMs' root disks)
  local root_sc="${ODF_DEFAULT_SC}"

  manifest="${manifest//__VM_NAME__/${vm_name}}"
  manifest="${manifest//__NAMESPACE__/${TEST_NAMESPACE}}"
  manifest="${manifest//__VCPU__/${vcpu}}"
  manifest="${manifest//__MEMORY__/${memory}}"
  manifest="${manifest//__SC_NAME__/${sc_name}}"
  manifest="${manifest//__PVC_SIZE__/${pvc_size}}"
  manifest="${manifest//__ROOT_SC__/${root_sc}}"
  manifest="${manifest//__POOL_NAME__/${pool_name}}"
  manifest="${manifest//__VM_SIZE_LABEL__/${vm_size_label}}"
  manifest="${manifest//__RUN_ID__/${RUN_ID}}"
  manifest="${manifest//__DATASOURCE_NAME__/${DATASOURCE_NAME}}"
  manifest="${manifest//__DATASOURCE_NAMESPACE__/${DATASOURCE_NAMESPACE}}"

  # Create a Secret for cloud-init userdata (avoids KubeVirt's 2KiB inline limit)
  local ci_secret_name="${vm_name}-cloudinit"
  local ci_b64
  ci_b64=$(echo "${cloud_init_content}" | base64 | tr -d '\n')

  # Clean up any stale resources from a previous interrupted run
  oc delete secret "${ci_secret_name}" -n "${TEST_NAMESPACE}" --wait=false 2>/dev/null || true
  oc delete pvc "${vm_name}-data" -n "${TEST_NAMESPACE}" --wait=false 2>/dev/null || true
  oc delete vm "${vm_name}" -n "${TEST_NAMESPACE}" --wait=false 2>/dev/null || true

  oc create -f - <<EOF || { log_error "Failed to create cloud-init Secret ${ci_secret_name}"; return 1; }
apiVersion: v1
kind: Secret
metadata:
  name: ${ci_secret_name}
  namespace: ${TEST_NAMESPACE}
  labels:
    app: vm-perf-test
    perf-test/run-id: ${RUN_ID}
type: Opaque
data:
  userdata: ${ci_b64}
EOF

  echo "${manifest}" | oc create -f -
}

# ---------------------------------------------------------------------------
# Get DataVolume phase and progress (internal helper)
# ---------------------------------------------------------------------------
_get_dv_status() {
  local dv_name="$1"
  local namespace="${2:-${TEST_NAMESPACE}}"
  local dv_phase dv_progress
  dv_phase=$(oc get dv "${dv_name}" -n "${namespace}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  dv_progress=$(oc get dv "${dv_name}" -n "${namespace}" \
    -o jsonpath='{.status.progress}' 2>/dev/null || echo "N/A")
  [[ -z "${dv_progress}" ]] && dv_progress="N/A"
  echo "${dv_phase}:${dv_progress}"
}

# ---------------------------------------------------------------------------
# Dump VM + DV + PVC diagnostics on failure (replaces bare vmi YAML dump)
# ---------------------------------------------------------------------------
_dump_vm_diagnostics() {
  local vm_name="$1"
  local namespace="${2:-${TEST_NAMESPACE}}"
  local dv_name="${vm_name}-rootdisk"

  log_error "=== Diagnostics for VM ${vm_name} ==="

  # VMI YAML (existing behavior)
  log_error "--- VMI status ---"
  oc get vmi "${vm_name}" -n "${namespace}" -o yaml 2>/dev/null | \
    while IFS= read -r line; do log_error "  ${line}"; done || true

  # DataVolume status
  log_error "--- DataVolume ${dv_name} status ---"
  oc get dv "${dv_name}" -n "${namespace}" -o json 2>/dev/null | \
    jq '.status' 2>/dev/null | \
    while IFS= read -r line; do log_error "  ${line}"; done || \
    log_error "  (DataVolume not found or jq unavailable)"

  # Root disk PVC
  log_error "--- Root disk PVC ${dv_name} ---"
  oc get pvc "${dv_name}" -n "${namespace}" \
    -o jsonpath='phase={.status.phase} capacity={.status.capacity.storage}' 2>/dev/null | \
    { read -r line; log_error "  ${line}"; } || \
    log_error "  (PVC not found)"

  # Data disk PVC
  log_error "--- Data disk PVC ${vm_name}-data ---"
  oc get pvc "${vm_name}-data" -n "${namespace}" \
    -o jsonpath='phase={.status.phase}' 2>/dev/null | \
    { read -r line; log_error "  ${line}"; } || \
    log_error "  (PVC not found)"

  # Recent events for the VM and DV
  log_error "--- Recent events (VM ${vm_name}) ---"
  oc get events -n "${namespace}" --sort-by='.lastTimestamp' \
    --field-selector "involvedObject.name=${vm_name}" 2>/dev/null | \
    tail -10 | while IFS= read -r line; do log_error "  ${line}"; done || true

  log_error "--- Recent events (DV ${dv_name}) ---"
  oc get events -n "${namespace}" --sort-by='.lastTimestamp' \
    --field-selector "involvedObject.name=${dv_name}" 2>/dev/null | \
    tail -10 | while IFS= read -r line; do log_error "  ${line}"; done || true

  log_error "=== End diagnostics ==="
}

# ---------------------------------------------------------------------------
# Wait for VM to be in Running state
# ---------------------------------------------------------------------------
wait_for_vm_running() {
  local vm_name="$1"
  local timeout="${2:-${VM_READY_TIMEOUT}}"
  local dv_name="${vm_name}-rootdisk"

  log_info "Waiting for VM ${vm_name} to reach Running state (timeout=${timeout}s)..."

  local start_time
  start_time=$(date +%s)

  local last_logged_dv_status=""
  local stall_counter=0
  local last_dv_progress=""
  local dv_done=false

  while true; do
    local elapsed=$(( $(date +%s) - start_time ))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      log_error "VM ${vm_name} did not reach Running state within ${timeout}s"
      _dump_vm_diagnostics "${vm_name}"
      return 1
    fi

    local phase
    phase=$(oc get vmi "${vm_name}" -n "${TEST_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    if [[ "${phase}" == "Running" ]]; then
      log_info "VM ${vm_name} is Running (took ${elapsed}s)"
      return 0
    fi

    # --- Check for VM-level failure (e.g. bad DataSource, failed DV creation) ---
    local vm_failure
    vm_failure=$(oc get vm "${vm_name}" -n "${TEST_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Failure")].message}' 2>/dev/null || echo "")
    if [[ -n "${vm_failure}" ]]; then
      log_error "VM ${vm_name} has a Failure condition: ${vm_failure}"
      _dump_vm_diagnostics "${vm_name}"
      return 1
    fi

    # --- DataVolume clone monitoring (only while VM is not yet Running) ---
    if [[ "${dv_done}" != "true" ]]; then
      local dv_status
      dv_status=$(_get_dv_status "${dv_name}")
      local dv_phase="${dv_status%%:*}"
      local dv_progress="${dv_status#*:}"

      # Log on status change only
      if [[ "${dv_status}" != "${last_logged_dv_status}" ]]; then
        if [[ "${dv_phase}" == "Succeeded" ]]; then
          log_info "VM ${vm_name}: DV clone complete, waiting for VM boot..."
          dv_done=true
        elif [[ "${dv_phase}" == "CloneInProgress" ]] || [[ "${dv_phase}" == "ImportInProgress" ]]; then
          log_info "VM ${vm_name}: DV clone in progress (${dv_progress})"
        elif [[ "${dv_phase}" != "Unknown" ]]; then
          log_info "VM ${vm_name}: DV phase=${dv_phase} progress=${dv_progress}"
        fi
        last_logged_dv_status="${dv_status}"
      fi

      # Stall detection (only while DV is not Succeeded)
      if [[ "${dv_phase}" != "Succeeded" ]]; then
        if [[ "${dv_progress}" == "${last_dv_progress}" ]]; then
          (( stall_counter++ )) || true
        else
          stall_counter=0
          last_dv_progress="${dv_progress}"
        fi

        if [[ ${stall_counter} -ge ${DV_STALL_THRESHOLD} ]]; then
          if [[ "${DV_STALL_ACTION}" == "fail" ]]; then
            log_error "VM ${vm_name}: DV clone stalled at ${dv_phase}/${dv_progress} for ${stall_counter} polls — aborting"
            _dump_vm_diagnostics "${vm_name}"
            return 1
          else
            log_warn "VM ${vm_name}: DV clone may be stalled at ${dv_phase}/${dv_progress} (unchanged for ${stall_counter} polls)"
            stall_counter=0
          fi
        fi
      fi
    fi

    if [[ "${phase}" == "Unknown" ]]; then
      local printable_status
      printable_status=$(oc get vm "${vm_name}" -n "${TEST_NAMESPACE}" \
        -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
      log_debug "VM ${vm_name} status: ${printable_status} (VMI not yet created, ${elapsed}s elapsed)"
    else
      log_debug "VM ${vm_name} phase: ${phase} (${elapsed}s elapsed)"
    fi
    sleep "${POLL_INTERVAL}"
  done
}

# ---------------------------------------------------------------------------
# Wait for fio test to complete inside VM (polls via virtctl console / SSH)
# ---------------------------------------------------------------------------
wait_for_fio_completion() {
  local vm_name="$1"
  local timeout="${2:-${FIO_COMPLETION_TIMEOUT}}"
  local marker="${3:-PERF_TEST_COMPLETE}"

  log_info "Waiting for fio to complete in VM ${vm_name} (timeout=${timeout}s)..."

  local start_time
  start_time=$(date +%s)

  while true; do
    local elapsed=$(( $(date +%s) - start_time ))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      log_error "fio in VM ${vm_name} did not complete within ${timeout}s"
      return 1
    fi

    # Check via virtctl SSH or serial console for the completion marker
    local status
    status=$(oc exec -n "${TEST_NAMESPACE}" "virt-launcher-${vm_name}"* -- \
      cat /opt/perf-test/results/*.json 2>/dev/null | jq -r '.jobs | length' 2>/dev/null || echo "0")

    if [[ "${status}" -gt 0 ]]; then
      # Also check the systemd service status
      local svc_state
      svc_state=$(timeout 30 virtctl ssh --namespace="${TEST_NAMESPACE}" \
        --identity-file="${SSH_KEY_PATH}" -t "-o StrictHostKeyChecking=no" -t "-o IdentitiesOnly=yes" \
        --username=fedora --command="systemctl is-active perf-test.service" \
        "vm/${vm_name}" 2>/dev/null || echo "unknown")

      if [[ "${svc_state}" == "inactive" ]] || [[ "${svc_state}" == "active" ]]; then
        # inactive means completed (oneshot), active means still running
        local exit_status
        exit_status=$(timeout 30 virtctl ssh --namespace="${TEST_NAMESPACE}" \
          --identity-file="${SSH_KEY_PATH}" -t "-o StrictHostKeyChecking=no" -t "-o IdentitiesOnly=yes" \
          --username=fedora --command="systemctl show perf-test.service -p ExecMainStatus --value" \
          "vm/${vm_name}" 2>/dev/null || echo "unknown")

        if [[ "${exit_status}" == "0" ]]; then
          log_info "fio completed successfully in VM ${vm_name} (took ${elapsed}s)"
          return 0
        fi
      fi
    fi

    sleep "${POLL_INTERVAL}"
  done
}

# ---------------------------------------------------------------------------
# Collect fio results from a VM via virtctl SSH
# ---------------------------------------------------------------------------
collect_vm_results() {
  local vm_name="$1"
  local output_dir="$2"

  log_info "Collecting results from VM ${vm_name}..."
  mkdir -p "${output_dir}"

  # Copy fio JSON results
  timeout 60 virtctl ssh --namespace="${TEST_NAMESPACE}" \
    --identity-file="${SSH_KEY_PATH}" -t "-o StrictHostKeyChecking=no" -t "-o IdentitiesOnly=yes" \
    --username=fedora --command="cat /opt/perf-test/results/*.json" \
    "vm/${vm_name}" > "${output_dir}/${vm_name}-fio.json" 2>/dev/null || {
    log_warn "Could not collect fio JSON from ${vm_name}, trying alternative method..."
    # Fallback: try via oc exec on the virt-launcher pod
    local pod
    pod=$(oc get pods -n "${TEST_NAMESPACE}" -l "vm.kubevirt.io/name=${vm_name}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${pod}" ]]; then
      oc exec -n "${TEST_NAMESPACE}" "${pod}" -c compute -- \
        cat /opt/perf-test/results/*.json \
        > "${output_dir}/${vm_name}-fio.json" 2>/dev/null || true
    fi
  }

  # Collect system info
  timeout 60 virtctl ssh --namespace="${TEST_NAMESPACE}" \
    --identity-file="${SSH_KEY_PATH}" -t "-o StrictHostKeyChecking=no" -t "-o IdentitiesOnly=yes" \
    --username=fedora --command="lscpu && echo '---' && free -h && echo '---' && lsblk" \
    "vm/${vm_name}" > "${output_dir}/${vm_name}-sysinfo.txt" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Replace fio job file in a running VM via SSH
# ---------------------------------------------------------------------------
replace_fio_job() {
  local vm_name="$1"
  local fio_content="$2"

  log_info "Replacing fio job in VM ${vm_name}"
  # Encode via base64 to avoid stdin piping issues with virtctl ssh.
  # Use sudo tee — cloud-init wrote the file as root.
  local encoded
  encoded=$(printf '%s' "${fio_content}" | base64 | tr -d '\n')

  timeout 30 virtctl ssh --namespace="${TEST_NAMESPACE}" \
    --identity-file="${SSH_KEY_PATH}" -t "-o StrictHostKeyChecking=no" -t "-o IdentitiesOnly=yes" \
    --username=fedora \
    --command="printf '%s' '${encoded}' | base64 -d | sudo tee /opt/perf-test/fio-job.fio > /dev/null" \
    "vm/${vm_name}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Restart the fio benchmark service in a VM (non-blocking)
#   - Clears previous results so collect_vm_results picks up fresh output
#   - Stops the service (may be active due to RemainAfterExit=yes)
#   - Resets any failed state
#   - Starts the service asynchronously (--no-block avoids blocking on oneshot)
# ---------------------------------------------------------------------------
restart_fio_service() {
  local vm_name="$1"

  log_info "Restarting fio service in VM ${vm_name}"
  timeout 30 virtctl ssh --namespace="${TEST_NAMESPACE}" \
    --identity-file="${SSH_KEY_PATH}" -t "-o StrictHostKeyChecking=no" -t "-o IdentitiesOnly=yes" \
    --username=fedora \
    --command="sudo rm -f /opt/perf-test/results/*.json /mnt/data/* && sudo systemctl stop perf-test.service 2>/dev/null; sudo systemctl reset-failed perf-test.service 2>/dev/null; sudo systemctl start --no-block perf-test.service" \
    "vm/${vm_name}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Delete a test VM and its PVCs
# ---------------------------------------------------------------------------
delete_test_vm() {
  local vm_name="$1"

  log_info "Deleting VM: ${vm_name}"
  oc delete vm "${vm_name}" -n "${TEST_NAMESPACE}" --wait=true --timeout=120s 2>/dev/null || true
  oc delete secret "${vm_name}-cloudinit" -n "${TEST_NAMESPACE}" --wait=false 2>/dev/null || true
  oc delete pvc "${vm_name}-data" -n "${TEST_NAMESPACE}" --wait=false 2>/dev/null || true
  oc delete pvc "${vm_name}-rootdisk" -n "${TEST_NAMESPACE}" --wait=false 2>/dev/null || true
  oc delete dv "${vm_name}-rootdisk" -n "${TEST_NAMESPACE}" --wait=false 2>/dev/null || true
}
