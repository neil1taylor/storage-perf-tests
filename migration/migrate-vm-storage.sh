#!/usr/bin/env bash
# =============================================================================
# migration/migrate-vm-storage.sh — Migrate OpenShift Virtualization VMs
# between StorageClasses via CDI host-assisted DataVolume clone (offline) or
# KubeVirt Storage Live Migration (online, same volumeMode only).
#
# The motivating case is ODF rep3-virt (RBD Block) → IBM Cloud File CSI
# (NFS Filesystem), but any source/target pair on the cluster is supported.
#
# Usage (run from the repo root):
#   ./migration/migrate-vm-storage.sh --vm myvm --target-sc ibmc-vpc-file-3000-iops
#   ./migration/migrate-vm-storage.sh --all --target-sc cephfs-rep3 --dry-run
#   ./migration/migrate-vm-storage.sh --vm-filter 'perf-*' --target-sc rep2 --mode online
#   ./migration/migrate-vm-storage.sh --resume mig-20260527-104500
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/00-config.sh"
source "${REPO_ROOT}/lib/vm-helpers.sh"
source "${REPO_ROOT}/lib/wait-helpers.sh"
source "${SCRIPT_DIR}/migration-helpers.sh"

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------
VM_NAME=""
VM_FILTER=""
ALL_VMS=false
NAMESPACE="${TEST_NAMESPACE}"
TARGET_SC=""
MODE="offline"
TAKE_SNAPSHOT=true
DELETE_SOURCE=false
INCLUDE_ROOTDISK=false
PARALLEL_VMS=1
DRY_RUN=false
RESUME_RUN_ID=""
RBD_SNAPCLASS="${RBD_SNAPCLASS:-ocs-storagecluster-rbdplugin-snapclass}"
CEPHFS_SNAPCLASS="${CEPHFS_SNAPCLASS:-ocs-storagecluster-cephfsplugin-snapclass}"
DV_TIMEOUT="${DV_TIMEOUT:-3600}"

usage() {
  cat <<USAGE
Usage: $0 [--vm <name> | --vm-filter <glob> | --all] --target-sc <sc> [options]

VM selection (exactly one required):
  --vm <name>            Migrate one VM
  --vm-filter <glob>     Migrate VMs whose name matches the glob (e.g. 'perf-*')
  --all                  Migrate every VM in the namespace

Required:
  --target-sc <name>     Target StorageClass

Options:
  --namespace <ns>       Default: ${TEST_NAMESPACE}
  --mode online|offline  Default: offline
                         online requires OpenShift Virt >= 4.17 and matching volumeMode
  --no-snapshot          Skip pre-migration VolumeSnapshot
  --delete-source        Delete source PVC (and snapshot) after VM is verified
  --include-rootdisk     Also migrate the OS root PVC (default: data PVCs only)
  --parallel <N>         Migrate up to N VMs concurrently (default: 1)
  --dry-run              Print plan; create nothing
  --resume <run-id>      Resume from a prior migration checkpoint
  --help                 Show this help

Environment overrides:
  RBD_SNAPCLASS          Default: ${RBD_SNAPCLASS}
  CEPHFS_SNAPCLASS       Default: ${CEPHFS_SNAPCLASS}
  DV_TIMEOUT             Per-PVC clone timeout in seconds (default: ${DV_TIMEOUT})
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)             VM_NAME="$2"; shift 2 ;;
    --vm-filter)      VM_FILTER="$2"; shift 2 ;;
    --all)            ALL_VMS=true; shift ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --target-sc)      TARGET_SC="$2"; shift 2 ;;
    --mode)           MODE="$2"; shift 2 ;;
    --no-snapshot)    TAKE_SNAPSHOT=false; shift ;;
    --delete-source)  DELETE_SOURCE=true; shift ;;
    --include-rootdisk) INCLUDE_ROOTDISK=true; shift ;;
    --parallel)       PARALLEL_VMS="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --resume)         RESUME_RUN_ID="$2"; shift 2 ;;
    --help|-h)        usage; exit 0 ;;
    *)                echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Arg validation
# ---------------------------------------------------------------------------
_selectors=0
[[ -n "${VM_NAME}" ]]   && ((_selectors += 1))
[[ -n "${VM_FILTER}" ]] && ((_selectors += 1))
[[ "${ALL_VMS}" == true ]] && ((_selectors += 1))
if [[ ${_selectors} -ne 1 ]]; then
  echo "Error: choose exactly one of --vm, --vm-filter, --all" >&2
  exit 2
fi
if [[ -z "${TARGET_SC}" ]]; then
  echo "Error: --target-sc is required" >&2
  exit 2
fi
if [[ "${MODE}" != "offline" && "${MODE}" != "online" ]]; then
  echo "Error: --mode must be 'offline' or 'online'" >&2
  exit 2
fi
if ! [[ "${PARALLEL_VMS}" =~ ^[0-9]+$ ]] || [[ "${PARALLEL_VMS}" -lt 1 ]]; then
  echo "Error: --parallel N must be a positive integer" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Run identity, audit dir, checkpoint
# ---------------------------------------------------------------------------
MIG_RUN_ID="mig-${TIMESTAMP}"
if [[ -n "${RESUME_RUN_ID}" ]]; then
  MIG_RUN_ID="${RESUME_RUN_ID}"
fi
export MIGRATION_AUDIT_DIR="${RESULTS_DIR}/${MIG_RUN_ID}"
mkdir -p "${MIGRATION_AUDIT_DIR}"
CHECKPOINT_FILE="${RESULTS_DIR}/${MIG_RUN_ID}.checkpoint"

declare -A COMPLETED=()
if [[ -n "${RESUME_RUN_ID}" ]]; then
  if [[ -f "${CHECKPOINT_FILE}" ]]; then
    while IFS= read -r line; do COMPLETED["${line}"]=1; done < "${CHECKPOINT_FILE}"
    log_info "Resuming ${MIG_RUN_ID}: ${#COMPLETED[@]} VM/PVC migrations already completed"
  else
    log_error "Checkpoint not found: ${CHECKPOINT_FILE}"
    exit 1
  fi
fi

record_checkpoint() { echo "$1" >> "${CHECKPOINT_FILE}"; }
is_completed()      { [[ -n "${COMPLETED[$1]+x}" ]]; }

# ---------------------------------------------------------------------------
# Resolve target SC: must exist and we need to know its volumeMode
# ---------------------------------------------------------------------------
if ! oc get sc "${TARGET_SC}" &>/dev/null; then
  log_error "Target StorageClass '${TARGET_SC}' does not exist"
  exit 1
fi
TARGET_VOLUME_MODE="$(get_volume_mode_for_pool "${TARGET_SC}")"
TARGET_ACCESS_MODE="ReadWriteOnce"
[[ "${TARGET_VOLUME_MODE}" == "Filesystem" ]] && TARGET_ACCESS_MODE="ReadWriteMany"

log_info "Migration run: ${MIG_RUN_ID}"
log_info "Target SC: ${TARGET_SC} (volumeMode=${TARGET_VOLUME_MODE}, accessMode=${TARGET_ACCESS_MODE})"
log_info "Mode: ${MODE}    Snapshot: ${TAKE_SNAPSHOT}    Delete source: ${DELETE_SOURCE}"
log_info "Audit dir: ${MIGRATION_AUDIT_DIR}"

# ---------------------------------------------------------------------------
# Discover VMs to migrate
# ---------------------------------------------------------------------------
discover_vms() {
  local -a names=()
  if [[ -n "${VM_NAME}" ]]; then
    names=("${VM_NAME}")
  else
    mapfile -t names < <(oc get vm -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' \
      2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)
  fi
  if [[ -n "${VM_FILTER}" ]]; then
    local -a filtered=()
    for n in "${names[@]}"; do
      # shellcheck disable=SC2053
      [[ "${n}" == ${VM_FILTER} ]] && filtered+=("${n}")
    done
    names=("${filtered[@]}")
  fi
  printf '%s\n' "${names[@]}"
}

# ---------------------------------------------------------------------------
# Enumerate volumes on a VM that live on a StorageClass != target.
# Output lines: volume_name|pvc_name|current_sc|kind
#   kind ∈ { persistentVolumeClaim, dataVolume }
# Skips rootdisk-named volumes unless --include-rootdisk.
# ---------------------------------------------------------------------------
list_migration_candidates() {
  local vm="$1"
  local ns="$2"
  local vm_json
  vm_json=$(oc get vm "${vm}" -n "${ns}" -o json 2>/dev/null) || return 1

  # Build name → (kind, pvc-or-dv-name) from spec.template.spec.volumes
  echo "${vm_json}" | jq -r '
    .spec.template.spec.volumes[]?
    | select(.dataVolume or .persistentVolumeClaim)
    | if .dataVolume then
        "\(.name)|\(.dataVolume.name)|dataVolume"
      else
        "\(.name)|\(.persistentVolumeClaim.claimName)|persistentVolumeClaim"
      end' | \
  while IFS='|' read -r vol_name claim_name kind; do
    # Filter root disks unless requested
    if [[ "${INCLUDE_ROOTDISK}" != "true" ]]; then
      case "${vol_name}" in
        rootdisk|root|os|boot) continue ;;
      esac
    fi
    # Resolve the backing PVC's StorageClass.
    # For dataVolume-typed volumes, KubeVirt creates a PVC of the same name.
    local sc
    sc=$(oc get pvc "${claim_name}" -n "${ns}" \
      -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
    if [[ -z "${sc}" ]]; then
      log_warn "VM ${vm}: volume ${vol_name} backed by ${claim_name} — PVC not found, skipping" >&2
      continue
    fi
    [[ "${sc}" == "${TARGET_SC}" ]] && continue   # already migrated
    echo "${vol_name}|${claim_name}|${sc}|${kind}"
  done
}

# ---------------------------------------------------------------------------
# Pick the right VolumeSnapshotClass for a given source SC. Best-effort:
# RBD-style sources → RBD snap class; CephFS-style → CephFS snap class.
# Returns empty string if no obvious match — caller decides to skip the snap.
# ---------------------------------------------------------------------------
pick_snapclass_for_sc() {
  local src_sc="$1"
  case "${src_sc}" in
    *ceph-rbd*|*rep[0-9]*|*ec-*) echo "${RBD_SNAPCLASS}" ;;
    *cephfs*)                     echo "${CEPHFS_SNAPCLASS}" ;;
    *)                            echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# Clone a single source PVC to the target SC via a CDI DataVolume.
# Prints the new PVC name on stdout on success.
# ---------------------------------------------------------------------------
clone_pvc_to_target_sc() {
  local vm="$1"
  local ns="$2"
  local src_pvc="$3"
  local dv_name
  dv_name="${vm}-${src_pvc}-mig-${MIG_RUN_ID}"
  dv_name="${dv_name//[^a-z0-9-]/-}"
  dv_name="${dv_name:0:63}"
  dv_name="${dv_name%-}"

  # Idempotency: if DV already exists and Succeeded, reuse it
  local existing
  existing=$(oc get dv "${dv_name}" -n "${ns}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "${existing}" == "Succeeded" ]]; then
    log_info "Reusing existing successful clone DV ${dv_name}" >&2
    echo "${dv_name}"
    return 0
  fi
  if [[ -n "${existing}" && "${existing}" != "Failed" ]]; then
    log_info "Clone DV ${dv_name} exists in phase ${existing} — waiting" >&2
    if wait_for_dv_succeeded "${dv_name}" "${ns}" "${DV_TIMEOUT}" >&2; then
      echo "${dv_name}"
      return 0
    fi
    return 1
  fi
  # Failed DV from a prior run — delete so we can retry cleanly
  if [[ "${existing}" == "Failed" ]]; then
    log_warn "Deleting failed prior DV ${dv_name} before retry" >&2
    oc delete dv "${dv_name}" -n "${ns}" --wait=true --timeout=60s >&2 2>/dev/null || true
  fi

  local src_size src_volmode
  src_size=$(oc get pvc "${src_pvc}" -n "${ns}" \
    -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
  src_volmode=$(oc get pvc "${src_pvc}" -n "${ns}" \
    -o jsonpath='{.spec.volumeMode}' 2>/dev/null)
  if [[ -z "${src_size}" ]]; then
    log_error "Could not read source PVC ${src_pvc} size" >&2
    return 1
  fi

  log_info "Cloning PVC ${src_pvc} (${src_size}, ${src_volmode}) → DV ${dv_name} on ${TARGET_SC} (${TARGET_VOLUME_MODE})" >&2

  oc create -f - >&2 <<EOF || { log_error "Failed to create DataVolume ${dv_name}" >&2; return 1; }
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${dv_name}
  namespace: ${ns}
  labels:
    app: vm-perf-test
    migration/run-id: ${MIG_RUN_ID}
    migration/source-pvc: ${src_pvc}
spec:
  source:
    pvc:
      namespace: ${ns}
      name: ${src_pvc}
  storage:
    storageClassName: ${TARGET_SC}
    accessModes:
      - ${TARGET_ACCESS_MODE}
    volumeMode: ${TARGET_VOLUME_MODE}
    resources:
      requests:
        storage: ${src_size}
EOF

  wait_for_dv_succeeded "${dv_name}" "${ns}" "${DV_TIMEOUT}" >&2 || return 1
  wait_for_pvc_bound    "${dv_name}" "${ns}" 120              >&2 || return 1
  echo "${dv_name}"
}

# ---------------------------------------------------------------------------
# Best-effort rollback: delete clone DVs/PVCs from a failed multi-PVC migration
# ---------------------------------------------------------------------------
rollback_clone_dvs() {
  local ns="$1"; shift
  for dv in "$@"; do
    [[ -z "${dv}" ]] && continue
    log_warn "Rolling back partial clone DV ${dv}"
    oc delete dv "${dv}" -n "${ns}" --wait=false 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# Migrate one VM (offline path)
# ---------------------------------------------------------------------------
migrate_vm_offline() {
  local vm="$1"; local ns="$2"
  local -a candidates=()
  mapfile -t candidates < <(list_migration_candidates "${vm}" "${ns}")
  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_info "VM ${vm}: no PVCs to migrate (already on ${TARGET_SC} or only rootdisk filtered)"
    return 0
  fi

  log_info "VM ${vm}: ${#candidates[@]} volume(s) to migrate"
  for c in "${candidates[@]}"; do log_info "  - ${c}"; done

  if [[ "${DRY_RUN}" == true ]]; then
    log_info "VM ${vm}: dry-run — skipping actual migration"
    return 0
  fi

  # Audit: snapshot the VM spec before any change
  oc get vm "${vm}" -n "${ns}" -o yaml \
    > "${MIGRATION_AUDIT_DIR}/${vm}.before.yaml" 2>/dev/null || true

  # Stage 1: snapshots
  local -a snap_names=()
  if [[ "${TAKE_SNAPSHOT}" == true ]]; then
    for line in "${candidates[@]}"; do
      IFS='|' read -r _ src_pvc src_sc _ <<< "${line}"
      local snapclass
      snapclass="$(pick_snapclass_for_sc "${src_sc}")"
      if [[ -z "${snapclass}" ]]; then
        log_warn "VM ${vm}: no snapshot class match for SC ${src_sc} — skipping snapshot of ${src_pvc}"
        continue
      fi
      local sname
      sname=$(snapshot_pvc "${src_pvc}" "${ns}" "${snapclass}" "${MIG_RUN_ID}") || {
        log_error "Snapshot failed for ${src_pvc} — aborting VM ${vm}"
        return 1
      }
      snap_names+=("${sname}")
    done
  fi

  # Stage 2: stop the VM
  stop_test_vm "${vm}" false "${ns}"
  if ! wait_for_vm_stopped "${vm}" 300 "${ns}"; then
    log_warn "VM ${vm} did not stop gracefully — forcing"
    stop_test_vm "${vm}" true "${ns}"
    wait_for_vm_stopped "${vm}" 120 "${ns}" || {
      log_error "VM ${vm} would not stop; aborting"
      return 1
    }
  fi

  # Stage 3: clone every candidate PVC. Track the new DV names so we can
  # roll back if any single clone fails.
  local -a new_dvs=()
  local -a swap_specs=()
  local clone_failed=false
  for line in "${candidates[@]}"; do
    IFS='|' read -r vol_name src_pvc src_sc kind <<< "${line}"
    local new_dv
    new_dv=$(clone_pvc_to_target_sc "${vm}" "${ns}" "${src_pvc}")
    if [[ -z "${new_dv}" ]]; then
      clone_failed=true
      break
    fi
    new_dvs+=("${new_dv}")
    swap_specs+=("${vol_name}|${src_pvc}|${new_dv}|${kind}")
  done

  if [[ "${clone_failed}" == true ]]; then
    log_error "VM ${vm}: clone failed — rolling back partial DVs and restarting source VM"
    rollback_clone_dvs "${ns}" "${new_dvs[@]}"
    start_test_vm "${vm}" "${ns}"
    return 1
  fi

  # Stage 4: patch VM volumes to point at new PVCs (one per candidate)
  for s in "${swap_specs[@]}"; do
    IFS='|' read -r vol_name src_pvc new_dv _ <<< "${s}"
    if ! patch_vm_volume_ref "${vm}" "${ns}" "${vol_name}" "persistentVolumeClaim" "${new_dv}"; then
      log_error "VM ${vm}: failed to patch volume ${vol_name} — VM left stopped, original PVCs intact"
      log_error "  manual recovery: 'oc apply -f ${MIGRATION_AUDIT_DIR}/${vm}.before.yaml'"
      return 1
    fi
  done

  # Stage 5: start the VM on the new PVCs
  start_test_vm "${vm}" "${ns}"
  if ! wait_for_vm_running "${vm}" "${VM_READY_TIMEOUT}"; then
    log_error "VM ${vm} did not come up on migrated storage — leaving everything in place for forensics"
    return 1
  fi

  # Stage 6: record success per-PVC + optional source cleanup
  for s in "${swap_specs[@]}"; do
    IFS='|' read -r _ src_pvc new_dv _ <<< "${s}"
    record_checkpoint "${vm}:${src_pvc}:${new_dv}"
    if [[ "${DELETE_SOURCE}" == true ]]; then
      log_info "Deleting source PVC ${src_pvc}"
      oc delete pvc "${src_pvc}" -n "${ns}" --wait=false 2>/dev/null || true
    fi
  done
  if [[ "${DELETE_SOURCE}" == true && "${TAKE_SNAPSHOT}" == true ]]; then
    for sname in "${snap_names[@]}"; do
      log_info "Deleting snapshot ${sname}"
      oc delete volumesnapshot "${sname}" -n "${ns}" --wait=false 2>/dev/null || true
    done
  fi

  log_info "VM ${vm}: migration complete"
}

# ---------------------------------------------------------------------------
# Migrate one VM (online path — KubeVirt Storage Live Migration)
# ---------------------------------------------------------------------------
migrate_vm_online() {
  local vm="$1"; local ns="$2"
  local -a candidates=()
  mapfile -t candidates < <(list_migration_candidates "${vm}" "${ns}")
  if [[ ${#candidates[@]} -eq 0 ]]; then
    log_info "VM ${vm}: nothing to migrate"
    return 0
  fi

  # Cross-volumeMode rejection
  for line in "${candidates[@]}"; do
    IFS='|' read -r vol_name src_pvc _ _ <<< "${line}"
    local src_mode
    src_mode=$(oc get pvc "${src_pvc}" -n "${ns}" \
      -o jsonpath='{.spec.volumeMode}' 2>/dev/null || echo "")
    if [[ "${src_mode}" != "${TARGET_VOLUME_MODE}" ]]; then
      log_error "VM ${vm}: online migration not supported across volumeMode (${src_mode} → ${TARGET_VOLUME_MODE})"
      log_error "  Re-run with --mode offline for ${vol_name} (PVC ${src_pvc})"
      return 1
    fi
  done

  log_info "VM ${vm}: ${#candidates[@]} volume(s) to live-migrate"
  for c in "${candidates[@]}"; do log_info "  - ${c}"; done

  if [[ "${DRY_RUN}" == true ]]; then
    log_info "VM ${vm}: dry-run — skipping actual migration"
    return 0
  fi

  oc get vm "${vm}" -n "${ns}" -o yaml \
    > "${MIGRATION_AUDIT_DIR}/${vm}.before.yaml" 2>/dev/null || true

  # Build a JSON patch: set updateVolumesStrategy=Migration and swap each
  # volume to a freshly-provisioned blank PVC on the target SC. KubeVirt
  # mirrors writes via libvirt blockcopy under the running VMI.
  local -a swap_specs=()
  for line in "${candidates[@]}"; do
    IFS='|' read -r vol_name src_pvc _ _ <<< "${line}"
    local src_size new_pvc
    src_size=$(oc get pvc "${src_pvc}" -n "${ns}" \
      -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
    new_pvc="${vm}-${vol_name}-mig-${MIG_RUN_ID}"
    new_pvc="${new_pvc//[^a-z0-9-]/-}"
    new_pvc="${new_pvc:0:63}"; new_pvc="${new_pvc%-}"

    oc create -f - >&2 <<EOF || { log_error "Failed to create target PVC ${new_pvc}"; return 1; }
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${new_pvc}
  namespace: ${ns}
  labels:
    app: vm-perf-test
    migration/run-id: ${MIG_RUN_ID}
spec:
  storageClassName: ${TARGET_SC}
  accessModes:
    - ${TARGET_ACCESS_MODE}
  volumeMode: ${TARGET_VOLUME_MODE}
  resources:
    requests:
      storage: ${src_size}
EOF
    swap_specs+=("${vol_name}|${src_pvc}|${new_pvc}")
  done

  # Set updateVolumesStrategy + patch each volume reference
  oc patch vm "${vm}" -n "${ns}" --type=merge \
    -p '{"spec":{"updateVolumesStrategy":"Migration"}}' >&2 || {
    log_error "Failed to set updateVolumesStrategy=Migration on VM ${vm}"
    return 1
  }
  for s in "${swap_specs[@]}"; do
    IFS='|' read -r vol_name _ new_pvc <<< "${s}"
    if ! patch_vm_volume_ref "${vm}" "${ns}" "${vol_name}" "persistentVolumeClaim" "${new_pvc}"; then
      log_error "VM ${vm}: online patch failed for ${vol_name}"
      return 1
    fi
  done

  # Wait for VolumeMigration to complete on the VMI
  log_info "VM ${vm}: waiting for live volume migration to complete"
  local start_t
  start_t=$(date +%s)
  while true; do
    local elapsed=$(( $(date +%s) - start_t ))
    if [[ ${elapsed} -ge ${DV_TIMEOUT} ]]; then
      log_error "VM ${vm}: online migration did not complete in ${DV_TIMEOUT}s"
      return 1
    fi
    local mig_state
    mig_state=$(oc get vmi "${vm}" -n "${ns}" \
      -o jsonpath='{.status.migrationState.completed}' 2>/dev/null || echo "")
    local pending
    pending=$(oc get vm "${vm}" -n "${ns}" \
      -o jsonpath='{.status.volumeUpdateState.volumeMigrationState.migratedVolumes}' 2>/dev/null || echo "")
    if [[ "${mig_state}" == "true" || -z "${pending}" ]]; then
      log_info "VM ${vm}: live volume migration complete (${elapsed}s)"
      break
    fi
    log_debug "VM ${vm}: migration in progress (${elapsed}s)"
    sleep "${POLL_INTERVAL}"
  done

  for s in "${swap_specs[@]}"; do
    IFS='|' read -r _ src_pvc new_pvc <<< "${s}"
    record_checkpoint "${vm}:${src_pvc}:${new_pvc}"
    if [[ "${DELETE_SOURCE}" == true ]]; then
      oc delete pvc "${src_pvc}" -n "${ns}" --wait=false 2>/dev/null || true
    fi
  done

  log_info "VM ${vm}: online migration complete"
}

# ---------------------------------------------------------------------------
# Per-VM driver: skip if already checkpointed, dispatch by mode
# ---------------------------------------------------------------------------
migrate_one_vm() {
  local vm="$1"; local ns="$2"
  ensure_oc_auth 2>/dev/null || true

  # Confirm VM exists
  if ! oc get vm "${vm}" -n "${ns}" &>/dev/null; then
    log_error "VM ${vm} not found in namespace ${ns}"
    return 1
  fi

  if [[ "${MODE}" == "online" ]]; then
    migrate_vm_online "${vm}" "${ns}"
  else
    migrate_vm_offline "${vm}" "${ns}"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mapfile -t VMS < <(discover_vms)
VMS=("${VMS[@]/#}")  # squash empty entries
if [[ ${#VMS[@]} -eq 0 || -z "${VMS[0]}" ]]; then
  log_warn "No VMs matched the selection"
  exit 0
fi

log_info "Will migrate ${#VMS[@]} VM(s) in namespace ${NAMESPACE}: ${VMS[*]}"

failed=0
if [[ "${PARALLEL_VMS}" -eq 1 ]]; then
  for vm in "${VMS[@]}"; do
    if ! migrate_one_vm "${vm}" "${NAMESPACE}"; then
      ((failed += 1))
      log_error "VM ${vm}: migration FAILED"
    fi
  done
else
  log_info "Parallelism: ${PARALLEL_VMS}"
  pending=()
  for vm in "${VMS[@]}"; do pending+=("${vm}"); done
  declare -A pid_to_vm=()
  while [[ ${#pending[@]} -gt 0 ]]; do
    running_pids=()
    pid_to_vm=()
    slot=0
    while [[ ${slot} -lt ${PARALLEL_VMS} && ${#pending[@]} -gt 0 ]]; do
      vm="${pending[0]}"; pending=("${pending[@]:1}")
      ( migrate_one_vm "${vm}" "${NAMESPACE}" ) &
      pid=$!
      running_pids+=("${pid}"); pid_to_vm[${pid}]="${vm}"
      ((slot += 1))
    done
    for pid in "${running_pids[@]}"; do
      if ! wait "${pid}"; then
        ((failed += 1))
        log_error "VM ${pid_to_vm[${pid}]}: migration FAILED"
      fi
    done
  done
fi

if [[ ${failed} -gt 0 ]]; then
  log_error "${failed} of ${#VMS[@]} VM migrations failed"
  exit 1
fi
log_info "All ${#VMS[@]} VM migrations completed"
