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

  local osd_yaml
  osd_yaml=$(oc get storagecluster "${sc_name}" -n "${ns}" \
    -o jsonpath='{.spec.resources.osd}' 2>/dev/null)
  if [[ -z "${osd_yaml}" || "${osd_yaml}" == "{}" ]]; then
    osd_yaml="inherit"
  else
    # Re-emit as JSON one-liner for stable round-trip
    osd_yaml=$(oc get storagecluster "${sc_name}" -n "${ns}" \
      -o json | jq -c '.spec.resources.osd // "inherit"')
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
osd_resources: ${osd_yaml}
cstate_mc_present: ${mc_present}
mcp_worker_updated: ${mcp_updated}
mcp_worker_machines: ${mcp_machines}
mcp_worker_degraded: ${mcp_degraded}
snapshot_timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}
