#!/usr/bin/env bash
# =============================================================================
# migration/migration-helpers.sh — Helpers for VM storage migration
#
# Depends on ../lib/vm-helpers.sh for log_*, ensure_oc_auth, _get_dv_status,
# and on ../00-config.sh for TEST_NAMESPACE, POLL_INTERVAL, DV_STALL_THRESHOLD,
# RUN_ID. Source those before sourcing this file.
# =============================================================================

# ---------------------------------------------------------------------------
# Stop a VM via virtctl (graceful). Set force=true only after a graceful
# stop has timed out — force is roughly equivalent to pulling the plug.
# ---------------------------------------------------------------------------
stop_test_vm() {
  local vm_name="$1"
  local force="${2:-false}"
  local namespace="${3:-${TEST_NAMESPACE}}"

  local force_arg=()
  [[ "${force}" == "true" ]] && force_arg=(--force --grace-period=0)

  log_info "Stopping VM: ${vm_name}${force_arg[*]:+ (force)}"
  timeout 60 virtctl stop "${vm_name}" --namespace="${namespace}" "${force_arg[@]}" \
    2>/dev/null || {
    log_warn "virtctl stop returned non-zero for ${vm_name} (may already be stopped)"
  }
}

# ---------------------------------------------------------------------------
# Start a VM via virtctl. Caller should follow with wait_for_vm_running.
# ---------------------------------------------------------------------------
start_test_vm() {
  local vm_name="$1"
  local namespace="${2:-${TEST_NAMESPACE}}"

  log_info "Starting VM: ${vm_name}"
  timeout 60 virtctl start "${vm_name}" --namespace="${namespace}" 2>/dev/null || {
    log_warn "virtctl start returned non-zero for ${vm_name} (may already be running)"
  }
}

# ---------------------------------------------------------------------------
# Wait until a VM reports printableStatus == Stopped and its VMI is gone.
# Symmetric to wait_for_vm_running.
# ---------------------------------------------------------------------------
wait_for_vm_stopped() {
  local vm_name="$1"
  local timeout="${2:-300}"
  local namespace="${3:-${TEST_NAMESPACE}}"

  log_info "Waiting for VM ${vm_name} to stop (timeout=${timeout}s)..."
  local start_time
  start_time=$(date +%s)

  while true; do
    ensure_oc_auth 2>/dev/null || true
    local elapsed=$(( $(date +%s) - start_time ))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      log_error "VM ${vm_name} did not stop within ${timeout}s"
      return 1
    fi

    local printable
    printable=$(oc get vm "${vm_name}" -n "${namespace}" \
      -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
    local vmi_phase
    vmi_phase=$(oc get vmi "${vm_name}" -n "${namespace}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [[ "${printable}" == "Stopped" ]] && [[ -z "${vmi_phase}" ]]; then
      log_info "VM ${vm_name} is Stopped (took ${elapsed}s)"
      return 0
    fi
    log_debug "VM ${vm_name} status=${printable} vmi=${vmi_phase:-gone} (${elapsed}s elapsed)"
    sleep "${POLL_INTERVAL}"
  done
}

# ---------------------------------------------------------------------------
# Create a VolumeSnapshot of a PVC. Prints the snapshot name on stdout so
# callers can capture it for later rollback / pruning.
# ---------------------------------------------------------------------------
snapshot_pvc() {
  local pvc_name="$1"
  local namespace="$2"
  local snapclass="$3"
  local run_id="${4:-${RUN_ID}}"

  local snap_name
  snap_name="${pvc_name}-snap-${run_id}"
  snap_name="${snap_name:0:63}"
  snap_name="${snap_name%-}"

  log_info "Snapshotting PVC ${pvc_name} → ${snap_name} (class=${snapclass})" >&2

  oc create -f - >&2 <<EOF || { log_error "Failed to create VolumeSnapshot ${snap_name}" >&2; return 1; }
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${snap_name}
  namespace: ${namespace}
  labels:
    app: vm-perf-test
    migration/run-id: ${run_id}
    migration/source-pvc: ${pvc_name}
spec:
  volumeSnapshotClassName: ${snapclass}
  source:
    persistentVolumeClaimName: ${pvc_name}
EOF

  echo "${snap_name}"
}

# ---------------------------------------------------------------------------
# Wait for a DataVolume to reach Succeeded phase. Surfaces progress and
# applies the same stall-detection pattern as wait_for_vm_running.
# ---------------------------------------------------------------------------
wait_for_dv_succeeded() {
  local dv_name="$1"
  local namespace="${2:-${TEST_NAMESPACE}}"
  local timeout="${3:-3600}"

  log_info "Waiting for DataVolume ${dv_name} to clone (timeout=${timeout}s)..."
  local start_time
  start_time=$(date +%s)

  local last_logged_status=""
  local last_progress=""
  local stall_counter=0

  while true; do
    ensure_oc_auth 2>/dev/null || true
    local elapsed=$(( $(date +%s) - start_time ))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      log_error "DataVolume ${dv_name} did not finish within ${timeout}s"
      oc get dv "${dv_name}" -n "${namespace}" -o yaml 2>/dev/null | \
        while IFS= read -r line; do log_error "  ${line}"; done || true
      return 1
    fi

    local status
    status=$(_get_dv_status "${dv_name}" "${namespace}")
    local phase="${status%%:*}"
    local progress="${status#*:}"

    if [[ "${phase}" == "Succeeded" ]]; then
      log_info "DataVolume ${dv_name} clone complete (${elapsed}s)"
      return 0
    fi

    if [[ "${phase}" == "Failed" ]]; then
      log_error "DataVolume ${dv_name} failed"
      oc get dv "${dv_name}" -n "${namespace}" -o yaml 2>/dev/null | \
        while IFS= read -r line; do log_error "  ${line}"; done || true
      return 1
    fi

    if [[ "${status}" != "${last_logged_status}" ]]; then
      log_info "DataVolume ${dv_name}: phase=${phase} progress=${progress}"
      last_logged_status="${status}"
    fi

    if [[ "${progress}" == "${last_progress}" ]]; then
      (( stall_counter++ )) || true
    else
      stall_counter=0
      last_progress="${progress}"
    fi
    if [[ ${stall_counter} -ge ${DV_STALL_THRESHOLD} ]]; then
      log_warn "DataVolume ${dv_name}: stalled at ${phase}/${progress} for ${stall_counter} polls"
      stall_counter=0
    fi

    sleep "${POLL_INTERVAL}"
  done
}

# ---------------------------------------------------------------------------
# Patch a VM spec to repoint a volume from one PVC/DV to another.
#
# Args:
#   vm_name        — VM name
#   namespace      — namespace
#   volume_name    — the .spec.template.spec.volumes[].name to repoint
#                    (e.g. "datadisk", "rootdisk")
#   new_kind       — "persistentVolumeClaim" | "dataVolume"
#   new_target     — name of the new PVC or DataVolume to point at
#
# Also strips any matching entry from spec.dataVolumeTemplates so that
# deleting the VM later won't garbage-collect the migrated DataVolume.
# Dumps before/after specs to ${MIGRATION_AUDIT_DIR}/<vm>.{before,after}.yaml
# if that variable is set.
# ---------------------------------------------------------------------------
patch_vm_volume_ref() {
  local vm_name="$1"
  local namespace="$2"
  local volume_name="$3"
  local new_kind="$4"
  local new_target="$5"

  log_info "Patching VM ${vm_name}: volume ${volume_name} → ${new_kind}/${new_target}"

  if [[ -n "${MIGRATION_AUDIT_DIR:-}" ]]; then
    mkdir -p "${MIGRATION_AUDIT_DIR}"
    oc get vm "${vm_name}" -n "${namespace}" -o yaml \
      > "${MIGRATION_AUDIT_DIR}/${vm_name}.before.yaml" 2>/dev/null || true
  fi

  local vm_json
  vm_json=$(oc get vm "${vm_name}" -n "${namespace}" -o json 2>/dev/null) || {
    log_error "Could not read VM ${vm_name}"
    return 1
  }

  local new_spec
  new_spec=$(echo "${vm_json}" | jq \
    --arg vol "${volume_name}" \
    --arg kind "${new_kind}" \
    --arg target "${new_target}" '
    .spec.template.spec.volumes = (
      .spec.template.spec.volumes | map(
        if .name == $vol then
          {name: .name} + (
            if $kind == "dataVolume" then {dataVolume: {name: $target}}
            else {persistentVolumeClaim: {claimName: $target}}
            end
          )
        else . end
      )
    )
    | (.spec.dataVolumeTemplates // []) as $tmpls
    | .spec.dataVolumeTemplates = ($tmpls | map(select(.metadata.name != $vol)))
    ')

  echo "${new_spec}" | oc apply -f - >/dev/null || {
    log_error "Failed to apply patched VM ${vm_name}"
    return 1
  }

  if [[ -n "${MIGRATION_AUDIT_DIR:-}" ]]; then
    oc get vm "${vm_name}" -n "${namespace}" -o yaml \
      > "${MIGRATION_AUDIT_DIR}/${vm_name}.after.yaml" 2>/dev/null || true
  fi
}
