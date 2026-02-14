#!/usr/bin/env bash
# =============================================================================
# lib/wait-helpers.sh — Polling and waiting utilities
# =============================================================================

# ---------------------------------------------------------------------------
# Generic retry with backoff
# ---------------------------------------------------------------------------
retry_with_backoff() {
  local max_retries="$1"
  local initial_delay="$2"
  local max_delay="${3:-60}"
  shift 3
  local cmd=("$@")

  local delay="${initial_delay}"
  for ((i=1; i<=max_retries; i++)); do
    if "${cmd[@]}"; then
      return 0
    fi
    if [[ $i -lt $max_retries ]]; then
      log_debug "Attempt ${i}/${max_retries} failed, retrying in ${delay}s..."
      sleep "${delay}"
      delay=$(( delay * 2 ))
      [[ ${delay} -gt ${max_delay} ]] && delay=${max_delay}
    fi
  done

  log_error "Command failed after ${max_retries} attempts: ${cmd[*]}"
  return 1
}

# ---------------------------------------------------------------------------
# Wait for a set of VMs to all reach Running state
# ---------------------------------------------------------------------------
wait_for_all_vms_running() {
  local -a vm_names=("$@")
  local timeout="${VM_READY_TIMEOUT:-600}"
  local failed=0

  log_info "Waiting for ${#vm_names[@]} VMs to reach Running state..."

  for vm_name in "${vm_names[@]}"; do
    if ! wait_for_vm_running "${vm_name}" "${timeout}"; then
      log_error "VM ${vm_name} did not reach Running state"
      ((failed += 1))
    fi
  done

  if [[ ${failed} -gt 0 ]]; then
    log_error "${failed} of ${#vm_names[@]} VMs failed to start"
    return 1
  fi

  log_info "All ${#vm_names[@]} VMs are Running"
  return 0
}

# ---------------------------------------------------------------------------
# Wait for all fio tests to complete across a set of VMs
# ---------------------------------------------------------------------------
wait_for_all_fio_complete() {
  local -a vm_names=("$@")
  local timeout="${FIO_COMPLETION_TIMEOUT:-900}"
  local failed=0

  log_info "Waiting for fio to complete in ${#vm_names[@]} VMs..."

  # Poll all VMs in parallel-ish fashion
  local -A vm_done
  local -A vm_last_state
  for vm_name in "${vm_names[@]}"; do
    vm_done["${vm_name}"]=0
    vm_last_state["${vm_name}"]=""
  done

  local start_time
  start_time=$(date +%s)
  local last_tick_time=${start_time}
  local fio_tick_interval=30

  while true; do
    local now
    now=$(date +%s)
    local elapsed=$(( now - start_time ))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      log_error "Timeout waiting for fio completion (${elapsed}s)"
      break
    fi

    local all_done=1
    local pending_count=0
    local ssh_waiting=0
    local svc_starting=0
    local fio_active=0
    for vm_name in "${vm_names[@]}"; do
      if [[ "${vm_done[${vm_name}]}" -eq 1 ]]; then
        continue
      fi

      local svc_state
      svc_state=$(virtctl ssh --namespace="${TEST_NAMESPACE}" \
        --identity-file="${SSH_KEY_PATH}" -t "-o StrictHostKeyChecking=no" \
        --username=fedora --command="systemctl show perf-test.service -p ActiveState --value" \
        "vm/${vm_name}" 2>/dev/null || echo "unknown")

      # Log state transitions (one-time per transition)
      if [[ "${svc_state}" != "${vm_last_state[${vm_name}]}" ]]; then
        case "${svc_state}" in
          unknown)
            log_info "VM ${vm_name}: waiting for SSH access..."
            ;;
          activating)
            log_info "VM ${vm_name}: fio service is running"
            ;;
        esac
        vm_last_state["${vm_name}"]="${svc_state}"
      fi

      # "inactive" = completed (RemainAfterExit=no) or never started
      # "active"   = completed (RemainAfterExit=yes, oneshot exited)
      # "failed"   = service exited with non-zero status
      if [[ "${svc_state}" == "inactive" ]] || [[ "${svc_state}" == "active" ]] || [[ "${svc_state}" == "failed" ]]; then
        # Query both exit code and PID to distinguish "never started" from "completed"
        local svc_info
        svc_info=$(virtctl ssh --namespace="${TEST_NAMESPACE}" \
          --identity-file="${SSH_KEY_PATH}" -t "-o StrictHostKeyChecking=no" \
          --username=fedora --command="systemctl show perf-test.service -p ExecMainPID,ExecMainStatus --value" \
          "vm/${vm_name}" 2>/dev/null || echo "0
1")
        local exec_pid exec_exit
        exec_pid=$(echo "${svc_info}" | head -1 | tr -d '[:space:]')
        exec_exit=$(echo "${svc_info}" | tail -1 | tr -d '[:space:]')

        if [[ "${exec_pid}" == "0" ]]; then
          # Service was never started — still waiting for cloud-init runcmd
          all_done=0
          ((pending_count += 1))
          ((svc_starting += 1))
          if [[ "${vm_last_state[${vm_name}]}" != "waiting-start" ]]; then
            log_info "VM ${vm_name}: waiting for service to start..."
            vm_last_state["${vm_name}"]="waiting-start"
          fi
        elif [[ "${exec_exit}" == "0" ]]; then
          log_info "fio completed in VM ${vm_name} ($(_format_duration "${elapsed}"))"
          vm_done["${vm_name}"]=1
        else
          log_error "fio failed in VM ${vm_name} (exit code: ${exec_exit})"
          vm_done["${vm_name}"]=1
          ((failed += 1))
        fi
      else
        all_done=0
        ((pending_count += 1))
        if [[ "${svc_state}" == "unknown" ]]; then
          ((ssh_waiting += 1))
        else
          ((fio_active += 1))
        fi
      fi
    done

    if [[ ${all_done} -eq 1 ]]; then
      break
    fi

    # Periodic progress tick
    if [[ pending_count -gt 0 ]] && [[ $(( now - last_tick_time )) -ge ${fio_tick_interval} ]]; then
      local parts=()
      [[ ssh_waiting -gt 0 ]] && parts+=("${ssh_waiting} waiting for SSH")
      [[ svc_starting -gt 0 ]] && parts+=("${svc_starting} waiting for service")
      [[ fio_active -gt 0 ]] && parts+=("${fio_active} running")
      local detail=""
      if [[ ${#parts[@]} -gt 0 ]]; then
        detail=" ($(IFS=', '; echo "${parts[*]}"))"
      fi
      local label="fio"
      if [[ fio_active -eq 0 ]]; then
        label="waiting"
      fi
      log_info "${label}: ${pending_count}/${#vm_names[@]} VMs still in progress${detail} ($(_format_duration "${elapsed}") elapsed)"
      last_tick_time=${now}
    fi

    sleep "${POLL_INTERVAL}"
  done

  if [[ ${failed} -gt 0 ]]; then
    log_warn "${failed} of ${#vm_names[@]} fio tests failed"
    return 1
  fi

  log_info "All fio tests completed successfully"
  return 0
}

# ---------------------------------------------------------------------------
# Wait for PVC to be Bound
# ---------------------------------------------------------------------------
wait_for_pvc_bound() {
  local pvc_name="$1"
  local namespace="${2:-${TEST_NAMESPACE}}"
  local timeout="${3:-300}"

  log_debug "Waiting for PVC ${pvc_name} to bind..."
  local start_time
  start_time=$(date +%s)

  while true; do
    local elapsed=$(( $(date +%s) - start_time ))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      log_error "PVC ${pvc_name} did not bind within ${timeout}s"
      return 1
    fi

    local phase
    phase=$(oc get pvc "${pvc_name}" -n "${namespace}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")

    if [[ "${phase}" == "Bound" ]]; then
      log_debug "PVC ${pvc_name} is Bound"
      return 0
    fi

    sleep 5
  done
}
