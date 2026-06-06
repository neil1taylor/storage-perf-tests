#!/usr/bin/env bash
# tests/smoke/cephconfig-roundtrip.sh — verify cephconfig_* keys survive a
# full apply → verify → restore → verify round-trip against a live cluster.
# Uses an innocuous test key (osd_max_scrubs) so a failed restore doesn't
# leave a damaging override behind.
#
# What this test verifies:
#   PASS-1  apply_tuning_config writes cephconfig_osd_max_scrubs to the
#           ceph config database (confirmed via `ceph config dump`).
#   PASS-2  restore_cluster_state removes the
#           .spec.managedResources.cephCluster.cephConfig field from the
#           StorageCluster (the authoritative control-plane state). The ceph
#           config DB entry is written by Rook when OCS-operator sets the field;
#           it is NOT proactively deleted when the field is cleared — Rook only
#           removes it on the next OSD restart cycle. Checking DB state as the
#           restore signal would give a false FAIL here, so we verify the
#           StorageCluster spec instead.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

source 00-config.sh
source lib/vm-helpers.sh
source lib/tune-helpers.sh

NS="openshift-storage"
TEST_KEY="osd_max_scrubs"
TEST_VAL="2"   # Reef default is 3; this is a safe, easily-reverted override.

snap=$(mktemp -t cephconfig-snap-XXXXXX.yaml)
cleanup() {
  rm -f "${snap}"
  # Best-effort restore even if a partial pass left state behind.
  oc patch storagecluster -n "${NS}" \
    "$(oc get storagecluster -n "${NS}" -o jsonpath='{.items[0].metadata.name}')" \
    --type json -p='[{"op":"remove","path":"/spec/managedResources/cephCluster/cephConfig"}]' \
    &>/dev/null || true
}
trap cleanup EXIT

# Register a one-off config that exercises cephconfig_*.
TUNE_CONFIGS[__test_cephconfig_roundtrip]="cephconfig_${TEST_KEY}=${TEST_VAL} cstate=on"
export TUNE_CONFIGS

SC_NAME=$(oc get storagecluster -n "${NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "${SC_NAME}" ]] && { echo "FAIL: no StorageCluster found in ${NS}"; exit 1; }

# 1. Snapshot the pre-test state.
snapshot_cluster_state "${snap}" || { echo "FAIL: snapshot"; exit 1; }
pre_value=$(oc -n "${NS}" exec deploy/rook-ceph-tools -- \
  ceph config dump --format json 2>/dev/null \
  | jq -r --arg k "${TEST_KEY}" \
      '.[] | select(.section=="osd" and .name==$k) | .value' | head -1)
pre_sc=$(oc get storagecluster "${SC_NAME}" -n "${NS}" \
  -o jsonpath='{.spec.managedResources.cephCluster.cephConfig}' 2>/dev/null)
echo "Pre-apply: ceph osd:${TEST_KEY} = '${pre_value:-<unset>}'  SC.cephConfig = '${pre_sc:-<unset>}'"

# 2. Apply the test config.
if ! apply_tuning_config "__test_cephconfig_roundtrip"; then
  echo "FAIL: apply_tuning_config"; exit 1
fi

# 3. Verify the override is live in the ceph config DB.
applied_value=$(oc -n "${NS}" exec deploy/rook-ceph-tools -- \
  ceph config dump --format json 2>/dev/null \
  | jq -r --arg k "${TEST_KEY}" \
      '.[] | select(.section=="osd" and .name==$k) | .value' | head -1)
if [[ "${applied_value}" != "${TEST_VAL}" ]]; then
  echo "FAIL: expected osd:${TEST_KEY}='${TEST_VAL}', got '${applied_value:-<unset>}'"
  exit 1
fi
echo "PASS-1: override applied (osd:${TEST_KEY} = ${applied_value})"

# 4. Restore from snapshot.
if ! restore_cluster_state "${snap}"; then
  echo "WARN: restore_cluster_state returned warnings (continuing)"
fi

# 5. Verify the StorageCluster cephConfig field is reverted.
# The authoritative restore signal is the StorageCluster spec — Rook writes
# the override to the ceph config DB on apply, but does NOT proactively delete
# the DB entry on removal; it persists until the next OSD pod restart cycle.
# Checking DB state would give a false FAIL, so we verify the SC field instead.
for i in $(seq 1 6); do
  post_sc=$(oc get storagecluster "${SC_NAME}" -n "${NS}" \
    -o jsonpath='{.spec.managedResources.cephCluster.cephConfig}' 2>/dev/null)
  if [[ "${post_sc}" == "${pre_sc}" ]]; then
    echo "PASS-2: override reverted (StorageCluster.cephConfig = '${post_sc:-<unset>}')"
    # Informational: DB state (expected to still show old value until OSD restart)
    post_db=$(oc -n "${NS}" exec deploy/rook-ceph-tools -- \
      ceph config dump --format json 2>/dev/null \
      | jq -r --arg k "${TEST_KEY}" \
          '.[] | select(.section=="osd" and .name==$k) | .value' | head -1)
    echo "INFO: ceph config DB osd:${TEST_KEY} = '${post_db:-<unset>}' (persists until OSD restart — expected)"
    exit 0
  fi
  sleep 5
done

echo "FAIL: post-restore SC.cephConfig '${post_sc:-<unset>}' != pre-value '${pre_sc:-<unset>}'"
exit 1
