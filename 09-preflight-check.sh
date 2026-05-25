#!/usr/bin/env bash
# =============================================================================
# 09-preflight-check.sh — Pre-flight cluster health checks before perf testing
#
# Validates that the cluster is in a healthy state for storage performance
# testing. Checks Ceph health, volume state consistency, CSI plugins, kernel
# RBD connections, and optionally runs a smoke test with a block-mode PVC.
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed (do not run perf tests)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
SMOKE_TEST=false
FIX_MODE=false

usage() {
  echo "Usage: $0 [--smoke-test] [--fix]"
  echo ""
  echo "Run pre-flight checks before storage performance testing."
  echo ""
  echo "Options:"
  echo "  --smoke-test   Run a PVC mount smoke test (creates/deletes a pod + PVC)"
  echo "  --fix          Attempt to fix issues automatically where possible"
  echo "  -h, --help     Show this help"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --smoke-test) SMOKE_TEST=true; shift ;;
    --fix)        FIX_MODE=true; shift ;;
    -h|--help)    usage ;;
    *)            echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# State tracking
# ---------------------------------------------------------------------------
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

pass() { CHECKS_PASSED=$((CHECKS_PASSED + 1)); log_info "  PASS: $*"; }
fail() { CHECKS_FAILED=$((CHECKS_FAILED + 1)); log_error "  FAIL: $*"; }
warn() { CHECKS_WARNED=$((CHECKS_WARNED + 1)); log_warn "  WARN: $*"; }

# ==========================================================================
# Check 1: Ceph cluster health
# ==========================================================================
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Check 1: Ceph cluster health"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CEPH_TOOLBOX=$(oc get pods -n "${ODF_NAMESPACE}" -l app=rook-ceph-tools -o name 2>/dev/null | head -1)
if [[ -z "${CEPH_TOOLBOX}" ]]; then
  CEPH_TOOLBOX="deploy/rook-ceph-tools"
fi

ceph_cmd() {
  oc exec -n "${ODF_NAMESPACE}" "${CEPH_TOOLBOX}" -- "$@" 2>/dev/null
}

# 1a: Overall health
ceph_health=$(ceph_cmd ceph health 2>&1 || echo "UNREACHABLE")
if [[ "${ceph_health}" == "HEALTH_OK" ]]; then
  pass "Ceph health: HEALTH_OK"
elif [[ "${ceph_health}" == *"HEALTH_WARN"* ]]; then
  if [[ "${ceph_health}" == *"Slow OSD heartbeats"* ]]; then
    fail "Ceph health: slow OSD heartbeats detected — rbd map will hang"
    ceph_cmd ceph health detail 2>&1 | grep "Slow OSD" | head -3 | while read -r line; do
      log_error "    ${line}"
    done
  else
    warn "Ceph health: ${ceph_health}"
  fi
elif [[ "${ceph_health}" == *"HEALTH_ERR"* ]]; then
  fail "Ceph health: ${ceph_health}"
else
  fail "Cannot reach Ceph cluster: ${ceph_health}"
fi

# 1b: All OSDs up
osd_json=$(ceph_cmd ceph osd stat -f json 2>&1 || echo '{}')
osd_total=$(echo "${osd_json}" | jq '.num_osds // 0' 2>/dev/null || echo "0")
osd_up=$(echo "${osd_json}" | jq '.num_up_osds // 0' 2>/dev/null || echo "0")
osd_in=$(echo "${osd_json}" | jq '.num_in_osds // 0' 2>/dev/null || echo "0")

if [[ "${osd_total}" == "${osd_up}" ]] && [[ "${osd_total}" == "${osd_in}" ]] && [[ "${osd_total}" -gt 0 ]]; then
  pass "All ${osd_total} OSDs are up and in"
else
  fail "OSD status: ${osd_up}/${osd_total} up, ${osd_in}/${osd_total} in"
fi

# 1c: PG health — count PGs not in active+clean from json (shape is .pg_summary.*)
pg_states_json=$(ceph_cmd ceph pg stat -f json 2>&1 || echo '{}')
pg_total=$(echo "${pg_states_json}" | jq -r '.pg_summary.num_pgs // 0' 2>/dev/null || echo "0")
pg_clean=$(echo "${pg_states_json}" | jq -r '[.pg_summary.num_pg_by_state[]? | select(.name == "active+clean") | .num] | add // 0' 2>/dev/null || echo "0")
if [[ "${pg_total}" == "${pg_clean}" ]] && [[ "${pg_total}" -gt 0 ]]; then
  pass "All ${pg_total} PGs are active+clean"
else
  fail "PG state: ${pg_clean}/${pg_total} active+clean"
  echo "${pg_states_json}" | jq -r '.pg_summary.num_pg_by_state[]? | select(.name != "active+clean") | "    \(.num) \(.name)"' 2>/dev/null | while read -r line; do
    log_error "${line}"
  done
fi

# 1d: No recovery/backfill in progress
ceph_status_json=$(ceph_cmd ceph status -f json 2>&1 || echo '{}')
recovering=$(echo "${ceph_status_json}" | jq '.pgmap.recovering_objects_per_sec // 0' 2>/dev/null || echo "0")
if [[ "${recovering}" == "0" ]] || [[ "${recovering}" == "null" ]]; then
  pass "No recovery/backfill in progress"
else
  warn "Recovery in progress: ${recovering} objects/sec — results may be affected"
fi

echo ""

# ==========================================================================
# Check 2: Node volume state consistency
# ==========================================================================
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Check 2: Node volume state consistency"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

volume_mismatch=false
while IFS= read -r node_json; do
  node_name=$(echo "${node_json}" | jq -r '.name')
  attached=$(echo "${node_json}" | jq -r '.attached')
  in_use=$(echo "${node_json}" | jq -r '.inUse')

  if [[ "${attached}" != "${in_use}" ]]; then
    fail "${node_name}: volumesAttached=${attached} != volumesInUse=${in_use} (stale state)"
    volume_mismatch=true
    if [[ "${FIX_MODE}" == true ]]; then
      log_info "  FIX: Restarting kubelet on ${node_name}..."
      if oc debug "node/${node_name}" -- chroot /host systemctl restart kubelet 2>/dev/null; then
        log_info "  FIX: Kubelet restarted on ${node_name}"
      else
        log_error "  FIX: Failed to restart kubelet on ${node_name}"
      fi
    fi
  else
    pass "${node_name}: volumesAttached=${attached}, volumesInUse=${in_use} (consistent)"
  fi
done < <(oc get nodes -o json | jq -c '.items[] | {name: .metadata.name, attached: (.status.volumesAttached | length), inUse: (.status.volumesInUse | length)}')

if [[ "${volume_mismatch}" == true ]] && [[ "${FIX_MODE}" != true ]]; then
  log_error "  Stale volume state detected. Run with --fix to restart affected kubelets."
fi

echo ""

# ==========================================================================
# Check 3: No stuck VMs or pods
# ==========================================================================
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Check 3: Stuck VMs and pods"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 3a: Failed/Scheduling VMIs (grep -c exits 1 on zero matches; suppress with || true)
stuck_vmis=$(oc get vmi -A --no-headers 2>/dev/null | grep -cE "Failed|Scheduling|Pending" || true)
stuck_vmis="${stuck_vmis:-0}"
if [[ "${stuck_vmis}" -gt 0 ]]; then
  fail "${stuck_vmis} stuck VMI(s) (Failed/Scheduling/Pending)"
  oc get vmi -A --no-headers 2>/dev/null | grep -E "Failed|Scheduling|Pending" | head -5 | while read -r line; do
    log_error "    ${line}"
  done
  if [[ "${FIX_MODE}" == true ]]; then
    log_info "  FIX: Removing finalizers from stuck VMIs..."
    while IFS=' ' read -r ns name; do
      oc patch vmi "${name}" -n "${ns}" --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done < <(oc get vmi -A --no-headers 2>/dev/null | grep -E "Failed|Scheduling|Pending" | awk '{print $1, $2}')
    log_info "  FIX: Done"
  fi
else
  pass "No stuck VMIs"
fi

# 3b: Stuck pods in test namespace
stuck_pods=$(oc get pods -n "${TEST_NAMESPACE}" --no-headers 2>/dev/null | grep -cE "Init:|ContainerCreating|Pending|Error" || true)
stuck_pods="${stuck_pods:-0}"
if [[ "${stuck_pods}" -gt 0 ]]; then
  warn "${stuck_pods} stuck pod(s) in ${TEST_NAMESPACE}"
  if [[ "${FIX_MODE}" == true ]]; then
    log_info "  FIX: Deleting stuck pods in ${TEST_NAMESPACE}..."
    oc get pods -n "${TEST_NAMESPACE}" --no-headers 2>/dev/null | grep -E "Init:|ContainerCreating|Pending|Error" | awk '{print $1}' | while read -r pod; do
      oc delete pod "${pod}" -n "${TEST_NAMESPACE}" --grace-period=0 --force 2>/dev/null || true
    done
  fi
else
  pass "No stuck pods in ${TEST_NAMESPACE}"
fi

echo ""

# ==========================================================================
# Check 4: RBD CSI node plugins healthy
# ==========================================================================
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Check 4: RBD CSI node plugins"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

while IFS= read -r pod_json; do
  pod_name=$(echo "${pod_json}" | jq -r '.name')
  node=$(echo "${pod_json}" | jq -r '.node')
  ready=$(echo "${pod_json}" | jq -r '.ready')
  restarts=$(echo "${pod_json}" | jq -r '.restarts')

  if [[ "${ready}" != "true" ]]; then
    fail "CSI node plugin ${pod_name} on ${node}: NOT READY"
  elif [[ "${restarts}" -gt 5 ]]; then
    warn "CSI node plugin on ${node}: ${restarts} restarts"
  else
    pass "CSI node plugin on ${node}: ready, ${restarts} restarts"
  fi
done < <(oc get pods -n "${ODF_NAMESPACE}" -l app=openshift-storage.rbd.csi.ceph.com-nodeplugin -o json | \
  jq -c '.items[] | {name: .metadata.name, node: .spec.nodeName, ready: (.status.containerStatuses | all(.ready)), restarts: ([.status.containerStatuses[].restartCount] | add)}')

echo ""

# ==========================================================================
# Check 5: Kernel libceph connections (per node)
# ==========================================================================
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Check 5: Kernel RBD (libceph) connections"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

while IFS= read -r node_name; do
  # grep -c exits 1 on no match and still prints "0"; `|| true` keeps that
  # single line and avoids the outer `|| echo 0` appending a second one.
  # `tail -1 | tr -dc '0-9'` strips any oc-debug preamble and trailing whitespace.
  recent_drops=$(oc debug "node/${node_name}" -- chroot /host bash -c \
    'dmesg 2>/dev/null | grep -c "libceph.*socket closed" || true' 2>/dev/null \
    | tail -1 | tr -dc '0-9' || echo "unknown")
  [[ -z "${recent_drops}" ]] && recent_drops="unknown"

  if [[ "${recent_drops}" == "unknown" ]]; then
    warn "${node_name}: could not check dmesg"
  elif [[ "${recent_drops}" -gt 0 ]]; then
    last_drop=$(oc debug "node/${node_name}" -- chroot /host bash -c \
      'dmesg | grep "libceph.*socket closed" | tail -1' 2>/dev/null || echo "")
    warn "${node_name}: ${recent_drops} libceph socket drops in dmesg — may affect rbd map"
    [[ -n "${last_drop}" ]] && log_warn "    Last: ${last_drop}"
  else
    pass "${node_name}: no libceph socket drops in dmesg"
  fi
done < <(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

echo ""

# ==========================================================================
# Check 6: KCM (kube-controller-manager) health
# ==========================================================================
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Check 6: Kube-controller-manager health"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Find KCM leader
kcm_leader=$(oc get lease kube-controller-manager -n kube-system \
  -o jsonpath='{.spec.holderIdentity}' 2>/dev/null | cut -d'_' -f1 || echo "unknown")
if [[ "${kcm_leader}" != "unknown" ]]; then
  pass "KCM leader: ${kcm_leader}"
else
  warn "Could not determine KCM leader"
fi

# Check for error spam in KCM logs
kcm_pod=$(oc get pods -n openshift-kube-controller-manager -l app=kube-controller-manager \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "${kcm_pod}" ]]; then
  error_count=$(oc logs -n openshift-kube-controller-manager "${kcm_pod}" \
    -c kube-controller-manager --since=60s 2>/dev/null | grep -c "Error syncing" || true)
  error_count="${error_count:-0}"
  if [[ "${error_count}" -gt 20 ]]; then
    warn "KCM has ${error_count} sync errors in last 60s — may starve attach/detach controller"
  else
    pass "KCM error rate: ${error_count} sync errors in last 60s"
  fi
fi

echo ""

# ==========================================================================
# Check 7: Webhook responsiveness (kubemacpool)
# ==========================================================================
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Check 7: KubeVirt webhooks"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

kmp_pod=$(oc get pods -n openshift-cnv -l app=kubemacpool \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "${kmp_pod}" ]]; then
  kmp_restarts=$(oc get pod "${kmp_pod}" -n openshift-cnv \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "unknown")
  kmp_ready=$(oc get pod "${kmp_pod}" -n openshift-cnv \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")

  if [[ "${kmp_ready}" == "true" ]] && [[ "${kmp_restarts}" -lt 5 ]]; then
    pass "kubemacpool: ready, ${kmp_restarts} restarts"
  elif [[ "${kmp_ready}" != "true" ]]; then
    fail "kubemacpool: NOT READY — VM operations will fail"
    if [[ "${FIX_MODE}" == true ]]; then
      log_info "  FIX: Restarting kubemacpool..."
      if oc delete pod "${kmp_pod}" -n openshift-cnv 2>/dev/null; then
        log_info "  FIX: Restarted"
      else
        log_error "  FIX: Failed"
      fi
    fi
  else
    warn "kubemacpool: ${kmp_restarts} restarts — may be unstable"
  fi
else
  warn "kubemacpool pod not found"
fi

# 7b: virt-template-validator
vtv_ready=$(oc get pods -n openshift-cnv -l name=virt-template-validator -o json 2>/dev/null | \
  jq '[.items[] | .status.containerStatuses[]?.ready] | all' 2>/dev/null || echo "false")
if [[ "${vtv_ready}" == "true" ]]; then
  pass "virt-template-validator: ready"
else
  fail "virt-template-validator: NOT READY — VM creation will fail"
  if [[ "${FIX_MODE}" == true ]]; then
    log_info "  FIX: Restarting virt-template-validator..."
    oc delete pod -n openshift-cnv -l name=virt-template-validator 2>/dev/null || true
    log_info "  FIX: Restarted"
  fi
fi

echo ""

# ==========================================================================
# Check 8: Smoke test — block-mode PVC mount (optional)
# ==========================================================================
if [[ "${SMOKE_TEST}" == true ]]; then
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "Check 8: Block-mode PVC smoke test"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  SMOKE_PVC="preflight-smoke-pvc"
  SMOKE_POD="preflight-smoke-pod"
  SMOKE_SC="ocs-storagecluster-ceph-rbd-virtualization"
  SMOKE_TIMEOUT=120

  # Ensure test namespace exists (preflight runs before 01-setup-*).
  # Track whether we created it so we can leave it intact if it was already there.
  SMOKE_NS_CREATED=false
  if ! oc get ns "${TEST_NAMESPACE}" >/dev/null 2>&1; then
    if oc create ns "${TEST_NAMESPACE}" >/dev/null 2>&1; then
      SMOKE_NS_CREATED=true
      log_info "  Created namespace ${TEST_NAMESPACE} for smoke test"
    else
      fail "Could not create namespace ${TEST_NAMESPACE} for smoke test"
    fi
  fi

  # Cleanup any leftovers
  oc delete pod "${SMOKE_POD}" -n "${TEST_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
  oc delete pvc "${SMOKE_PVC}" -n "${TEST_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
  sleep 3

  # Create PVC + Pod with block volume
  oc apply -f - <<EOF 2>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${SMOKE_PVC}
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${SMOKE_SC}
  volumeMode: Block
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: ${SMOKE_POD}
  namespace: ${TEST_NAMESPACE}
spec:
  containers:
    - name: smoke
      image: quay.io/cloud-bulldozer/fio:latest
      command: ["sleep", "30"]
      volumeDevices:
        - name: data
          devicePath: /dev/xvda
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${SMOKE_PVC}
  terminationGracePeriodSeconds: 5
  restartPolicy: Never
EOF

  # Wait for pod to reach Running
  smoke_start=$(date +%s)
  smoke_result="timeout"
  while true; do
    elapsed=$(( $(date +%s) - smoke_start ))
    if [[ ${elapsed} -ge ${SMOKE_TIMEOUT} ]]; then
      break
    fi

    phase=$(oc get pod "${SMOKE_POD}" -n "${TEST_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    if [[ "${phase}" == "Running" ]] || [[ "${phase}" == "Succeeded" ]]; then
      smoke_result="pass"
      break
    fi

    sleep 5
  done

  if [[ "${smoke_result}" == "pass" ]]; then
    elapsed=$(( $(date +%s) - smoke_start ))
    pass "Block-mode PVC smoke test passed (pod Running in ${elapsed}s)"
  else
    fail "Block-mode PVC smoke test FAILED — pod did not reach Running within ${SMOKE_TIMEOUT}s"
    log_error "  Pod events:"
    oc describe pod "${SMOKE_POD}" -n "${TEST_NAMESPACE}" 2>/dev/null | grep -A10 "Events:" | while read -r line; do
      log_error "    ${line}"
    done
  fi

  # Cleanup
  oc delete pod "${SMOKE_POD}" -n "${TEST_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
  oc delete pvc "${SMOKE_PVC}" -n "${TEST_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

  # Only delete the namespace if we created it for the smoke test
  if [[ "${SMOKE_NS_CREATED}" == true ]]; then
    oc delete ns "${TEST_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true
  fi

  echo ""
fi

# ==========================================================================
# Summary
# ==========================================================================
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Pre-flight Summary"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Passed:  ${CHECKS_PASSED}"
[[ ${CHECKS_WARNED} -gt 0 ]] && log_warn "  Warnings: ${CHECKS_WARNED}"
[[ ${CHECKS_FAILED} -gt 0 ]] && log_error "  Failed:  ${CHECKS_FAILED}"

echo ""

if [[ ${CHECKS_FAILED} -gt 0 ]]; then
  log_error "PRE-FLIGHT FAILED — do not run performance tests until issues are resolved"
  exit 1
else
  if [[ ${CHECKS_WARNED} -gt 0 ]]; then
    log_warn "PRE-FLIGHT PASSED WITH WARNINGS — results may be affected"
  else
    log_info "PRE-FLIGHT PASSED — cluster is ready for performance testing"
  fi
  exit 0
fi
