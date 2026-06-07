#!/usr/bin/env bash
# tests/smoke/snapshot.sh — verify snapshot_cluster_state captures expected fields.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

source 00-config.sh
source lib/vm-helpers.sh
source lib/tune-helpers.sh

tmp=$(mktemp -t tune-snap-XXXXXX.yaml)
trap "rm -f '${tmp}'" EXIT

snapshot_cluster_state "${tmp}"

[[ -s "${tmp}" ]] || { echo "snapshot is empty"; exit 1; }
grep -q "^resourceProfile:" "${tmp}" || { echo "missing resourceProfile"; exit 1; }
grep -q "^deviceset_resources:" "${tmp}" || { echo "missing deviceset_resources"; exit 1; }
grep -q "^cstate_mc_present:" "${tmp}" || { echo "missing cstate_mc_present"; exit 1; }
grep -q "^mcp_worker_updated:" "${tmp}" || { echo "missing mcp_worker_updated"; exit 1; }
grep -q "^cephconfig:" "${tmp}" || { echo "missing cephconfig"; exit 1; }

echo "snapshot contents:"
cat "${tmp}"
