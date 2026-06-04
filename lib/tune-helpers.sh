#!/usr/bin/env bash
# =============================================================================
# lib/tune-helpers.sh — ODF tune-sweep cluster-mutation primitives
# =============================================================================
# All functions in this file are sourced; none should be invoked at source
# time. Functions return 0 on success, non-zero on failure, and log via the
# standard log_* helpers from lib/vm-helpers.sh (which must be sourced first
# by any consuming script).
# =============================================================================

# Recognised keys in TUNE_CONFIGS values.
TUNE_VALID_KEYS=(profile osd_cpu osd_mem cstate)

# ---------------------------------------------------------------------------
# parse_tune_config <name>
#   Resolves a name from TUNE_CONFIGS and emits its canonical key=value form
#   on stdout, one pair per line. Validates that every key is in
#   TUNE_VALID_KEYS and that cstate ∈ {on, off}.
# ---------------------------------------------------------------------------
parse_tune_config() {
  local name="$1"
  if ! [[ -v 'TUNE_CONFIGS[$name]' ]]; then
    {
      echo "ERROR: unknown tune config: '${name}'"
      echo "Available: ${!TUNE_CONFIGS[*]}"
    } >&2
    return 1
  fi

  local raw="${TUNE_CONFIGS[$name]}"
  local -a out=()
  local kv key value
  for kv in ${raw}; do
    if [[ "${kv}" != *=* ]]; then
      echo "ERROR: malformed key=value in TUNE_CONFIGS[${name}]: '${kv}'" >&2
      return 1
    fi
    key="${kv%%=*}"
    value="${kv#*=}"

    local valid=0
    local v
    for v in "${TUNE_VALID_KEYS[@]}"; do
      [[ "${v}" == "${key}" ]] && valid=1 && break
    done
    if (( valid == 0 )); then
      {
        echo "ERROR: unknown key '${key}' in TUNE_CONFIGS[${name}]"
        echo "Valid keys: ${TUNE_VALID_KEYS[*]}"
      } >&2
      return 1
    fi

    if [[ "${key}" == "cstate" && "${value}" != "on" && "${value}" != "off" ]]; then
      echo "ERROR: cstate must be 'on' or 'off' (got '${value}') in TUNE_CONFIGS[${name}]" >&2
      return 1
    fi

    out+=("${key}=${value}")
  done

  # Ensure cstate is always present (defaults to 'on' if omitted).
  local has_cstate=0
  local entry
  for entry in "${out[@]}"; do
    [[ "${entry}" == cstate=* ]] && has_cstate=1 && break
  done
  (( has_cstate == 0 )) && out+=("cstate=on")

  printf '%s\n' "${out[@]}"
}

# ---------------------------------------------------------------------------
# render_cstate_machineconfig <out_yaml>
#   Emits a MachineConfig that disables processor C-states 1+ via kernel args
#   on all worker nodes. Idempotent: same content every call. The named
#   resource is ${TUNE_MC_NAME} so apply/delete on the same file is safe.
# ---------------------------------------------------------------------------
render_cstate_machineconfig() {
  local out="$1"
  [[ -z "${out}" ]] && { echo "ERROR: render_cstate_machineconfig requires output path" >&2; return 1; }

  cat > "${out}" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: ${TUNE_MC_NAME}
  labels:
    machineconfiguration.openshift.io/role: worker
    app: vm-perf-test
spec:
  kernelArguments:
    - intel_idle.max_cstate=0
    - processor.max_cstate=0
  config:
    ignition:
      version: 3.2.0
EOF
}

# ---------------------------------------------------------------------------
# snapshot_cluster_state <out_yaml>
#   Captures the cluster's current tunable state to a YAML file. Fields:
#     resourceProfile:     <balanced|performance|null>
#     osd_resources:       <inherit|inline-yaml>
#     cstate_mc_present:   <true|false>
#     mcp_worker_updated:  <int>
#     mcp_worker_machines: <int>
#     mcp_worker_degraded: <int>
#   The snapshot YAML is consumed only by restore_cluster_state; it is not a
#   Kubernetes manifest.
# ---------------------------------------------------------------------------
snapshot_cluster_state() {
  local out="$1"
  [[ -z "${out}" ]] && { echo "ERROR: snapshot_cluster_state requires output path" >&2; return 1; }

  local ns="openshift-storage"
  local sc_name
  sc_name=$(oc get storagecluster -n "${ns}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -z "${sc_name}" ]]; then
    echo "ERROR: no StorageCluster found in namespace ${ns}" >&2
    return 1
  fi

  local resource_profile
  resource_profile=$(oc get storagecluster "${sc_name}" -n "${ns}" \
    -o jsonpath='{.spec.resourceProfile}' 2>/dev/null)
  [[ -z "${resource_profile}" ]] && resource_profile="null"

  # Capture per-deviceSet OSD resource override (the correct ODF 4.20+ path).
  # spec.resources.osd is no longer captured — it's silently dropped by the
  # OCS-operator reconciler regardless of value (see project_ocs_resources_osd_ignored).
  local ds_resources
  ds_resources=$(oc get storagecluster "${sc_name}" -n "${ns}" \
    -o jsonpath='{.spec.storageDeviceSets[0].resources}' 2>/dev/null)
  if [[ -z "${ds_resources}" || "${ds_resources}" == "{}" ]]; then
    ds_resources="inherit"
  else
    ds_resources=$(oc get storagecluster "${sc_name}" -n "${ns}" \
      -o json | jq -c '.spec.storageDeviceSets[0].resources // "inherit"')
  fi

  local mc_present="false"
  if oc get machineconfig "${TUNE_MC_NAME}" &>/dev/null; then
    mc_present="true"
  fi

  local mcp_updated mcp_machines mcp_degraded
  mcp_updated=$(oc get mcp worker -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo 0)
  mcp_machines=$(oc get mcp worker -o jsonpath='{.status.machineCount}' 2>/dev/null || echo 0)
  mcp_degraded=$(oc get mcp worker -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null || echo 0)

  cat > "${out}" <<EOF
# Tune-sweep cluster snapshot (consumed by restore_cluster_state)
storagecluster_name: ${sc_name}
storagecluster_namespace: ${ns}
resourceProfile: ${resource_profile}
deviceset_resources: ${ds_resources}
cstate_mc_present: ${mc_present}
mcp_worker_updated: ${mcp_updated}
mcp_worker_machines: ${mcp_machines}
mcp_worker_degraded: ${mcp_degraded}
snapshot_timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

# ---------------------------------------------------------------------------
# wait_for_osd_ready <timeout-secs>
#   Polls until:
#     • All rook-ceph-osd-* pods are Ready
#     • OSD count in `ceph status` matches StorageCluster expected total
#     • Ceph health is HEALTH_OK or HEALTH_WARN (not HEALTH_ERR)
#   Returns 0 on convergence, 1 on timeout or HEALTH_ERR.
# ---------------------------------------------------------------------------
wait_for_osd_ready() {
  local timeout="${1:-1200}"
  local ns="openshift-storage"
  local deadline=$(( $(date +%s) + timeout ))
  local interval=15

  log_info "Waiting for OSDs ready + pod-spec converged (timeout=${timeout}s)"

  # CephCluster.spec.storage.storageClassDeviceSets[0].resources is the
  # post-reconcile target for OSD pod resources. After a StorageCluster patch,
  # OCS-operator takes ~30s to re-derive this value. Until reconcile catches
  # up, the field reads the *previous* value — and if Rook hasn't yet rolled
  # the pods, pods will match the stale CephCluster value and trigger a false
  # "converged" verdict. To avoid the race we require the CephCluster target
  # to be stable across `${stable_required}` consecutive polls (≈ 30 s) before
  # we trust it as the convergence target.
  local prev_target=""
  local stable_count=0
  local stable_required=2

  while (( $(date +%s) < deadline )); do
    # Pod readiness
    local not_ready
    not_ready=$(oc get pods -n "${ns}" -l app=rook-ceph-osd \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null \
      | grep -cE '^(false|$)' || true)

    local health
    health=$(oc -n "${ns}" exec deploy/rook-ceph-tools -- ceph health 2>/dev/null | awk '{print $1}')

    if [[ "${health}" == "HEALTH_ERR" ]]; then
      log_error "Ceph HEALTH_ERR detected; aborting wait"
      return 1
    fi

    # Read the CephCluster target and track stability across iterations.
    local target_cpu target_mem cur_target
    target_cpu=$(oc get cephcluster -n "${ns}" \
      -o jsonpath='{.items[0].spec.storage.storageClassDeviceSets[0].resources.requests.cpu}' 2>/dev/null)
    target_mem=$(oc get cephcluster -n "${ns}" \
      -o jsonpath='{.items[0].spec.storage.storageClassDeviceSets[0].resources.requests.memory}' 2>/dev/null)
    cur_target="${target_cpu}/${target_mem}"

    if [[ "${cur_target}" == "${prev_target}" && -n "${target_cpu}" ]]; then
      stable_count=$((stable_count + 1))
    else
      stable_count=0
      prev_target="${cur_target}"
    fi

    # Pod-spec convergence: every OSD pod must match the (stable) target
    # cpu/memory. Rook keeps OSDs Ready during rolling restart, so readiness
    # alone is not enough — we must wait until the new resource spec is
    # actually rolled out AND the target itself is no longer in motion.
    local converged=false
    if (( stable_count >= stable_required )) && [[ -n "${target_cpu}" && -n "${target_mem}" ]]; then
      local non_converged
      non_converged=$(oc get pods -n "${ns}" -l app=rook-ceph-osd \
        -o jsonpath='{range .items[*]}{.spec.containers[0].resources.requests.cpu}{"/"}{.spec.containers[0].resources.requests.memory}{"\n"}{end}' 2>/dev/null \
        | grep -vcE "^${target_cpu}/${target_mem}$" || true)
      if (( non_converged == 0 )); then
        converged=true
      fi
    fi

    # HEALTH_WARN is accepted only AFTER pod-spec convergence. During a rolling
    # restart we expect transient warns (recovering PGs, peering). If health
    # stayed WARN even after convergence, that's signalled in the success log
    # and the operator can investigate. HEALTH_ERR is treated as fatal above.
    if (( not_ready == 0 )) \
       && [[ "${health}" == "HEALTH_OK" || "${health}" == "HEALTH_WARN" ]] \
       && [[ "${converged}" == "true" ]]; then
      log_info "  OSDs ready, ceph=${health}, pods=${target_cpu:-?}/${target_mem:-?}"
      return 0
    fi

    log_debug "  osd-not-ready=${not_ready} ceph=${health:-?} converged=${converged} target=${cur_target} stable=${stable_count}/${stable_required}; sleep ${interval}s"
    sleep "${interval}"
  done

  log_error "wait_for_osd_ready timed out after ${timeout}s"
  return 1
}

# ---------------------------------------------------------------------------
# wait_for_mcp_updated <pool=worker> <timeout-secs>
#   Polls until MachineConfigPool/<pool>:
#     .status.updatedMachineCount == .status.machineCount
#     .status.degradedMachineCount == 0
#   Returns 0 immediately if no MC change is pending.
# ---------------------------------------------------------------------------
wait_for_mcp_updated() {
  local pool="${1:-worker}"
  local timeout="${2:-1800}"
  local deadline=$(( $(date +%s) + timeout ))
  local interval=20

  # On IBM Cloud ROKS managed clusters, no MachineConfigPool exists — workers
  # are managed by the IBM Cloud worker-pool system, not MCO. If the MCP is
  # absent, there is nothing to wait for; any MachineConfig with role=worker
  # has no pool to roll out through. Treat as success.
  if ! oc get mcp "${pool}" &>/dev/null; then
    log_info "MCP/${pool} not present — managed-worker cluster (ROKS); skipping wait"
    return 0
  fi

  log_info "Waiting for MCP/${pool} updated (timeout=${timeout}s)"
  while (( $(date +%s) < deadline )); do
    local updated machines degraded
    updated=$(oc get mcp "${pool}" -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo 0)
    machines=$(oc get mcp "${pool}" -o jsonpath='{.status.machineCount}' 2>/dev/null || echo 0)
    degraded=$(oc get mcp "${pool}" -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null || echo 0)

    if (( degraded > 0 )); then
      log_error "MCP/${pool} degraded (${degraded} machines); aborting wait"
      return 1
    fi

    if (( machines > 0 )) && (( updated == machines )); then
      log_info "  MCP/${pool} updated=${updated}/${machines}"
      return 0
    fi

    log_debug "  mcp=${updated}/${machines} degraded=${degraded}; sleeping ${interval}s"
    sleep "${interval}"
  done

  log_error "wait_for_mcp_updated timed out after ${timeout}s"
  return 1
}

# ---------------------------------------------------------------------------
# apply_tuning_config <name>
#   Mutates the cluster to match the named TUNE_CONFIGS entry. Idempotent.
#   Emits a tuning-applied.yaml summary on stdout describing the realised
#   state after mutation.
#
#   Steps:
#     1. Parse + validate the named config.
#     2. Patch StorageCluster: resourceProfile, .spec.resources.osd.
#     3. Apply or delete the cstate MachineConfig as required.
#     4. Wait for OSDs ready (always).
#     5. Wait for MCP worker updated (only if cstate flipped).
#   Returns 0 on success, 1 on any failure (caller's trap should restore).
# ---------------------------------------------------------------------------
apply_tuning_config() {
  local name="$1"
  local ns="openshift-storage"

  local -A cfg=()
  local line key value
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    cfg["${key}"]="${value}"
  done < <(parse_tune_config "${name}") || return 1

  local sc_name
  sc_name=$(oc get storagecluster -n "${ns}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -z "${sc_name}" ]] && { log_error "no StorageCluster found"; return 1; }

  # Track whether we touched the MC (so we know whether to wait for MCP).
  local mc_changed=false

  # --- 1. resourceProfile patch -----------------------------------------------
  local current_profile
  current_profile=$(oc get storagecluster "${sc_name}" -n "${ns}" \
    -o jsonpath='{.spec.resourceProfile}' 2>/dev/null)
  if [[ -n "${cfg[profile]:-}" && "${cfg[profile]}" != "${current_profile}" ]]; then
    log_info "Patching StorageCluster.spec.resourceProfile: ${current_profile:-<unset>} → ${cfg[profile]}"
    oc patch storagecluster "${sc_name}" -n "${ns}" --type merge \
      -p "{\"spec\":{\"resourceProfile\":\"${cfg[profile]}\"}}" >/dev/null \
      || { log_error "resourceProfile patch failed"; return 1; }
  fi

  # --- 2. OSD resource override -----------------------------------------------
  # NOTE: in ODF 4.20+, StorageCluster.spec.resources.osd is intentionally
  # ignored by the OCS-operator (suppressed in getDaemonResources; comment:
  # "Resource specification for osd is handled at the deviceSet level"). The
  # correct override path is StorageCluster.spec.storageDeviceSets[i].resources,
  # which feeds CephCluster.spec.storage.storageClassDeviceSets[i].resources
  # and triggers Rook to roll the OSD pods.
  if [[ -n "${cfg[osd_cpu]:-}" || -n "${cfg[osd_mem]:-}" ]]; then
    local cpu="${cfg[osd_cpu]:-}"
    local mem="${cfg[osd_mem]:-}"
    local req='{'
    [[ -n "${cpu}" ]] && req+="\"cpu\":\"${cpu}\","
    [[ -n "${mem}" ]] && req+="\"memory\":\"${mem}\","
    req="${req%,}"
    req+='}'
    local current_res op
    current_res=$(oc get storagecluster "${sc_name}" -n "${ns}" \
      -o jsonpath='{.spec.storageDeviceSets[0].resources}' 2>/dev/null)
    op="replace"
    [[ -z "${current_res}" || "${current_res}" == "{}" ]] && op="add"
    log_info "Patching storageDeviceSets[0].resources: cpu=${cpu} memory=${mem} (op=${op})"
    oc patch storagecluster "${sc_name}" -n "${ns}" --type json \
      -p="[{\"op\":\"${op}\",\"path\":\"/spec/storageDeviceSets/0/resources\",\"value\":{\"requests\":${req},\"limits\":${req}}}]" >/dev/null \
      || { log_error "storageDeviceSets resources patch failed"; return 1; }
  else
    # Remove override if present (revert to profile defaults).
    local ds_present
    ds_present=$(oc get storagecluster "${sc_name}" -n "${ns}" \
      -o jsonpath='{.spec.storageDeviceSets[0].resources}' 2>/dev/null)
    if [[ -n "${ds_present}" && "${ds_present}" != "{}" ]]; then
      log_info "Removing storageDeviceSets[0].resources override (back to profile defaults)"
      oc patch storagecluster "${sc_name}" -n "${ns}" --type json \
        -p='[{"op":"remove","path":"/spec/storageDeviceSets/0/resources"}]' >/dev/null \
        || { log_error "storageDeviceSets resources removal failed"; return 1; }
    fi
  fi

  # --- 3. cstate MachineConfig ------------------------------------------------
  local mc_present="false"
  oc get machineconfig "${TUNE_MC_NAME}" &>/dev/null && mc_present="true"

  if [[ "${cfg[cstate]}" == "off" && "${mc_present}" == "false" ]]; then
    log_info "Applying cstate-off MachineConfig (${TUNE_MC_NAME})"
    local mc_tmp
    mc_tmp=$(mktemp -t tune-mc-XXXXXX.yaml)
    render_cstate_machineconfig "${mc_tmp}"
    oc apply -f "${mc_tmp}" >/dev/null || { rm -f "${mc_tmp}"; log_error "MC apply failed"; return 1; }
    rm -f "${mc_tmp}"
    mc_changed=true
  elif [[ "${cfg[cstate]}" == "on" && "${mc_present}" == "true" ]]; then
    log_info "Deleting cstate-off MachineConfig (${TUNE_MC_NAME})"
    oc delete machineconfig "${TUNE_MC_NAME}" --ignore-not-found >/dev/null \
      || { log_error "MC delete failed"; return 1; }
    mc_changed=true
  fi

  # --- 4. Wait for convergence ------------------------------------------------
  wait_for_osd_ready "${TUNE_OSD_TIMEOUT}" || return 1
  if [[ "${mc_changed}" == "true" ]]; then
    wait_for_mcp_updated worker "${TUNE_MCP_TIMEOUT}" || return 1
  fi

  # --- 5. Emit realised state -------------------------------------------------
  local realised_profile realised_ds realised_cc_osd
  realised_profile=$(oc get storagecluster "${sc_name}" -n "${ns}" \
    -o jsonpath='{.spec.resourceProfile}' 2>/dev/null)
  realised_ds=$(oc get storagecluster "${sc_name}" -n "${ns}" \
    -o json | jq -c '.spec.storageDeviceSets[0].resources // "inherit"')
  realised_cc_osd=$(oc get cephcluster -n "${ns}" \
    -o json | jq -c '.items[0].spec.storage.storageClassDeviceSets[0].resources // {}')
  cat <<EOF
config_name: ${name}
realised_profile: ${realised_profile:-null}
realised_deviceset_resources: ${realised_ds}
realised_cephcluster_osd_resources: ${realised_cc_osd}
cstate_mc_present: $(oc get machineconfig "${TUNE_MC_NAME}" &>/dev/null && echo true || echo false)
applied_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

# ---------------------------------------------------------------------------
# restore_cluster_state <snapshot_yaml>
#   Returns the cluster to the state captured in the snapshot:
#     • resourceProfile (patch or remove)
#     • .spec.resources.osd (apply or remove)
#     • cstate MachineConfig (apply or delete)
#   Always called from the orchestrator's EXIT trap. Best-effort: logs but
#   does not abort on sub-step failure; reports overall via return code:
#     0 — clean
#     1 — snapshot unreadable
#     2 — best-effort, one or more sub-steps had warnings
# ---------------------------------------------------------------------------
restore_cluster_state() {
  local snap="$1"
  if [[ ! -s "${snap}" ]]; then
    log_error "restore_cluster_state: snapshot not found or empty: ${snap}"
    return 1
  fi

  local sc_name ns resource_profile deviceset_resources cstate_mc_present
  sc_name=$(awk -F': ' '/^storagecluster_name:/{print $2}' "${snap}")
  ns=$(awk -F': ' '/^storagecluster_namespace:/{print $2}' "${snap}")
  resource_profile=$(awk -F': ' '/^resourceProfile:/{print $2}' "${snap}")
  deviceset_resources=$(awk -F': ' '/^deviceset_resources:/{print $2}' "${snap}")
  cstate_mc_present=$(awk -F': ' '/^cstate_mc_present:/{print $2}' "${snap}")

  local warnings=0

  # --- resourceProfile -------------------------------------------------------
  if [[ "${resource_profile}" == "null" || -z "${resource_profile}" ]]; then
    log_info "Restoring: removing .spec.resourceProfile"
    oc patch storagecluster "${sc_name}" -n "${ns}" --type json \
      -p='[{"op":"remove","path":"/spec/resourceProfile"}]' &>/dev/null || true
  else
    log_info "Restoring: .spec.resourceProfile = ${resource_profile}"
    oc patch storagecluster "${sc_name}" -n "${ns}" --type merge \
      -p "{\"spec\":{\"resourceProfile\":\"${resource_profile}\"}}" \
      || { log_warn "restore: resourceProfile patch warning"; warnings=$((warnings+1)); }
  fi

  # --- per-deviceSet OSD resources ------------------------------------------
  # NOTE: targets storageDeviceSets[0] (the canonical ODF 4.20+ override path).
  # spec.resources.osd is no longer restored — it had no effect on the cluster.
  if [[ "${deviceset_resources}" == "inherit" ]]; then
    local ds_now
    ds_now=$(oc get storagecluster "${sc_name}" -n "${ns}" \
      -o jsonpath='{.spec.storageDeviceSets[0].resources}' 2>/dev/null)
    if [[ -n "${ds_now}" && "${ds_now}" != "{}" ]]; then
      log_info "Restoring: removing .spec.storageDeviceSets[0].resources override"
      oc patch storagecluster "${sc_name}" -n "${ns}" --type json \
        -p='[{"op":"remove","path":"/spec/storageDeviceSets/0/resources"}]' &>/dev/null || true
    fi
  else
    log_info "Restoring: .spec.storageDeviceSets[0].resources = ${deviceset_resources}"
    local current_ds op
    current_ds=$(oc get storagecluster "${sc_name}" -n "${ns}" \
      -o jsonpath='{.spec.storageDeviceSets[0].resources}' 2>/dev/null)
    op="replace"
    [[ -z "${current_ds}" || "${current_ds}" == "{}" ]] && op="add"
    oc patch storagecluster "${sc_name}" -n "${ns}" --type json \
      -p="[{\"op\":\"${op}\",\"path\":\"/spec/storageDeviceSets/0/resources\",\"value\":${deviceset_resources}}]" \
      || { log_warn "restore: deviceset resources patch warning"; warnings=$((warnings+1)); }
  fi

  # --- cstate MachineConfig --------------------------------------------------
  local mc_now="false"
  oc get machineconfig "${TUNE_MC_NAME}" &>/dev/null && mc_now="true"

  if [[ "${cstate_mc_present}" == "true" && "${mc_now}" == "false" ]]; then
    log_info "Restoring: re-applying cstate-off MachineConfig"
    local mc_tmp
    mc_tmp=$(mktemp -t tune-mc-XXXXXX.yaml)
    render_cstate_machineconfig "${mc_tmp}"
    oc apply -f "${mc_tmp}" || { log_warn "restore: MC apply warning"; warnings=$((warnings+1)); }
    rm -f "${mc_tmp}"
  elif [[ "${cstate_mc_present}" == "false" && "${mc_now}" == "true" ]]; then
    log_info "Restoring: deleting cstate-off MachineConfig"
    oc delete machineconfig "${TUNE_MC_NAME}" --ignore-not-found \
      || { log_warn "restore: MC delete warning"; warnings=$((warnings+1)); }
  fi

  # --- Wait for convergence (best-effort, reduced timeout) -------------------
  wait_for_osd_ready 600 || { log_warn "restore: OSDs not converged within 10 min"; warnings=$((warnings+1)); }
  wait_for_mcp_updated worker 1200 || { log_warn "restore: MCP not converged within 20 min"; warnings=$((warnings+1)); }

  if (( warnings > 0 )); then
    log_warn "restore_cluster_state completed with ${warnings} warning(s). Verify manually:"
    log_warn "  oc get storagecluster -n ${ns} -o yaml"
    log_warn "  oc get machineconfig | grep ${TUNE_MC_NAME}"
    return 2
  fi
  log_info "Cluster restored to pre-sweep state."
  return 0
}
