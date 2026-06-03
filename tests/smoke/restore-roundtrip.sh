#!/usr/bin/env bash
# tests/smoke/restore-roundtrip.sh — snapshot, mutate (apply 'big-osd'),
# restore, verify cluster matches snapshot.
#
# WARNING: this test mutates StorageCluster.spec.resources.osd. It restores
# at the end. If the test crashes mid-way, the operator must restore manually
# from the snapshot YAML printed at the top.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

source 00-config.sh
source lib/vm-helpers.sh
source lib/wait-helpers.sh
source lib/tune-helpers.sh

snap=/tmp/tune-restore-snap.yaml
snapshot_cluster_state "${snap}"
echo "--- snapshot taken ---"
cat "${snap}"

trap 'echo; echo "TRAP: restoring..."; restore_cluster_state "${snap}" || true' EXIT

echo
echo "--- applying big-osd ---"
apply_tuning_config big-osd > /tmp/tune-restore-applied.yaml
cat /tmp/tune-restore-applied.yaml

echo
echo "--- restoring ---"
restore_cluster_state "${snap}"

# Verify the round-trip
post=$(oc get storagecluster -n openshift-storage -o json \
  | jq -c '.items[0].spec.resources.osd // "inherit"')
pre=$(awk -F': ' '/^osd_resources:/{print $2}' "${snap}")
echo "pre=${pre}  post=${post}"
[[ "${pre}" == "${post}" ]] || { echo "FAIL: OSD resources not restored"; exit 1; }
trap - EXIT
echo "PASS: round-trip clean"
