# ODF Tuning Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an in-suite tuning sweep that varies ODF OSD CPU/memory and host C-state across a fixed-N VM × QD-sweep workload, snapshot-and-restore safe, producing a multi-config comparison report — extending this benchmark suite to reproduce the IBM ROVS internal-testing methodology.

**Architecture:** Three new units — `lib/tune-helpers.sh` (cluster-mutation primitives), `09-run-tune-sweep.sh` (config-level orchestrator with snapshot/restore), and a new `--qd-sweep` workload mode inside the existing `04-run-tests.sh` — plus a `--compare-tuning` report mode in `06-generate-report.sh` and additions to `00-config.sh` for named tuning profiles. See `docs/superpowers/specs/2026-06-03-odf-tune-sweep-design.md` for the full design.

**Tech Stack:** Bash 5 (existing convention: `set -euo pipefail`, `lib/*.sh` sourced from each script), `oc`/`kubectl`, `virtctl`, fio, Python 3 (embedded via heredoc for report HTML/Chart.js generation), `jq`, `openpyxl` (optional).

---

## File structure

| File | Purpose | Action |
|---|---|---|
| `00-config.sh` | Add `TUNE_CONFIGS` associative array + `TUNE_*` sweep defaults | Modify |
| `lib/tune-helpers.sh` | Cluster-mutation primitives (parse/apply/wait/snapshot/restore) | Create |
| `04-run-tests.sh` | Add `--qd-sweep` workload mode (cluster-agnostic, standalone-usable) | Modify |
| `09-run-tune-sweep.sh` | Config-level orchestrator with trap-based restore | Create |
| `06-generate-report.sh` | Add `--compare-tuning` handler | Modify |
| `lib/report-helpers.sh` | Add `generate_tune_sweep_report()` function | Modify |
| `tests/run-offline.sh` | Bundled off-cluster test runner (no `oc` calls) | Create |
| `tests/fixtures/tune-sweep-3cfg/` | Synthetic qd-sweep results for report testing | Create |
| `tests/smoke/run-smoke.sh` | Cluster smoke test runner (requires `oc` auth) | Create |
| `tests/smoke/mini-sweep.sh` | End-to-end 2-config × 2-QD × 4-VM smoke sweep | Create |
| `CLAUDE.md` | Add `--qd-sweep` and `09-run-tune-sweep.sh` to Key Commands | Modify |

---

## Task 1: Add `TUNE_CONFIGS` schema + sweep defaults to `00-config.sh`

**Files:**
- Modify: `00-config.sh` (append at end before any final `export`)
- Test: `tests/run-offline.sh::test_tune_configs_parse`

- [ ] **Step 1.1: Write the failing test**

Create `tests/run-offline.sh` with the first test case:

```bash
#!/usr/bin/env bash
# tests/run-offline.sh — off-cluster test runner for the tune-sweep feature.
# Exits non-zero on any failed assertion. Safe to run without `oc` auth.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PASS=0; FAIL=0
_pass() { PASS=$((PASS+1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# -----------------------------------------------------------------------------
test_tune_configs_parse() {
  echo "test_tune_configs_parse:"
  # Skip live cluster validation: set OC_SKIP_CLUSTER_CHECK so 00-config.sh
  # does not call `oc cluster-info`.
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1

  # NOTE: `[[ -v TUNE_CONFIGS ]]` is intentionally NOT used here — bash's -v on
  # the bare name of an associative array tests NAME[0], which is unset for
  # string-keyed arrays. The array-length check below is the canonical check.
  (( ${#TUNE_CONFIGS[@]} >= 4 )) || { _fail "expected >=4 named configs, got ${#TUNE_CONFIGS[@]}"; return; }
  for name in default cstate-off big-osd big-osd+cstate-off; do
    [[ -v 'TUNE_CONFIGS[$name]' ]] || { _fail "TUNE_CONFIGS[$name] missing"; return; }
  done
  [[ -n "${TUNE_DEFAULT_CONFIGS:-}" ]] || { _fail "TUNE_DEFAULT_CONFIGS unset"; return; }
  [[ -n "${TUNE_QD_LIST:-}" ]]         || { _fail "TUNE_QD_LIST unset"; return; }
  [[ -n "${TUNE_FIXED_VMS:-}" ]]       || { _fail "TUNE_FIXED_VMS unset"; return; }
  [[ -n "${TUNE_MC_NAME:-}" ]]         || { _fail "TUNE_MC_NAME unset"; return; }
  _pass "TUNE_CONFIGS and TUNE_* defaults are declared"
}

# -----------------------------------------------------------------------------
test_tune_configs_parse

echo
echo "===== ${PASS} passed, ${FAIL} failed ====="
exit $(( FAIL > 0 ))
```

Make it executable:
```bash
chmod +x tests/run-offline.sh
```

- [ ] **Step 1.2: Run the test, verify it fails**

Run: `./tests/run-offline.sh`
Expected: `FAIL  TUNE_CONFIGS is not declared` (00-config.sh doesn't define it yet), exit code 1.

- [ ] **Step 1.3: Add `OC_SKIP_CLUSTER_CHECK` guard to `00-config.sh`**

Locate the existing `oc cluster-info` validation in `00-config.sh` and gate it:

```bash
# Around the existing cluster-info check (search for "cluster-info"):
if [[ "${OC_SKIP_CLUSTER_CHECK:-false}" != "true" ]]; then
  if ! oc cluster-info &>/dev/null; then
    echo "ERROR: oc not authenticated to a cluster (run 'oc login …' first)" >&2
    return 1 2>/dev/null || exit 1
  fi
fi
```

This lets the off-cluster test harness source the config without needing `oc` auth.

- [ ] **Step 1.4: Add `TUNE_CONFIGS` and sweep defaults to `00-config.sh`**

Append (before any closing `export` block, near the existing scale-test defaults):

```bash
# =============================================================================
# Tune-sweep configuration matrix (ODF OSD resources + host C-state)
# -----------------------------------------------------------------------------
# Each value is a space-separated list of key=value pairs. Recognised keys:
#   profile   → balanced | performance (StorageCluster.spec.resourceProfile)
#   osd_cpu   → integer CPU cores (overrides profile defaults)
#   osd_mem   → memory quantity, e.g. 64Gi
#   cstate    → on | off
#                 on  = remove the tune-sweep MachineConfig if present
#                 off = apply MC with kernelArgs
#                       intel_idle.max_cstate=0 processor.max_cstate=0
# =============================================================================
declare -A TUNE_CONFIGS=(
  [default]='profile=balanced cstate=on'
  [cstate-off]='profile=balanced cstate=off'
  [big-osd]='osd_cpu=8 osd_mem=64Gi cstate=on'
  [big-osd+cstate-off]='osd_cpu=8 osd_mem=64Gi cstate=off'
)
export TUNE_CONFIGS

TUNE_DEFAULT_CONFIGS="${TUNE_DEFAULT_CONFIGS:-default,cstate-off,big-osd,big-osd+cstate-off}"
TUNE_QD_LIST="${TUNE_QD_LIST:-1,2,4,8,16,32,64}"
TUNE_FIXED_VMS="${TUNE_FIXED_VMS:-200}"
TUNE_MC_NAME="${TUNE_MC_NAME:-99-perf-test-cstate-off}"
TUNE_MCP_TIMEOUT="${TUNE_MCP_TIMEOUT:-1800}"   # 30 min for full MCP rollout
TUNE_OSD_TIMEOUT="${TUNE_OSD_TIMEOUT:-1200}"   # 20 min for OSD restart
TUNE_RATE_IOPS="${TUNE_RATE_IOPS:-500}"
TUNE_LATENCY_SLA_MS="${TUNE_LATENCY_SLA_MS:-5}"

export TUNE_DEFAULT_CONFIGS TUNE_QD_LIST TUNE_FIXED_VMS TUNE_MC_NAME
export TUNE_MCP_TIMEOUT TUNE_OSD_TIMEOUT TUNE_RATE_IOPS TUNE_LATENCY_SLA_MS
```

- [ ] **Step 1.5: Run the test, verify it passes**

Run: `./tests/run-offline.sh`
Expected: `PASS  TUNE_CONFIGS and TUNE_* defaults are declared`, exit code 0.

- [ ] **Step 1.6: Commit**

```bash
git add 00-config.sh tests/run-offline.sh
git commit -m "feat(config): add TUNE_CONFIGS schema and sweep defaults"
```

---

## Task 2: `lib/tune-helpers.sh` — `parse_tune_config` and validation

**Files:**
- Create: `lib/tune-helpers.sh`
- Test: `tests/run-offline.sh::test_parse_tune_config*`

- [ ] **Step 2.1: Add the failing tests to `tests/run-offline.sh`**

Append before the `test_tune_configs_parse` invocation line:

```bash
# -----------------------------------------------------------------------------
test_parse_tune_config_valid() {
  echo "test_parse_tune_config_valid:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh

  # Each named config parses without error and emits non-empty key=value lines.
  for name in default cstate-off big-osd big-osd+cstate-off; do
    local out
    if ! out=$(parse_tune_config "${name}" 2>&1); then
      _fail "parse_tune_config(${name}) returned non-zero: ${out}"
      return
    fi
    [[ -n "${out}" ]] || { _fail "parse_tune_config(${name}) emitted nothing"; return; }
    echo "${out}" | grep -qE '^cstate=(on|off)$' || { _fail "(${name}) missing cstate"; return; }
  done
  _pass "all named configs parse cleanly"
}

test_parse_tune_config_unknown_name() {
  echo "test_parse_tune_config_unknown_name:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh
  if parse_tune_config "this-name-does-not-exist" >/dev/null 2>&1; then
    _fail "expected non-zero exit on unknown name"
    return
  fi
  _pass "unknown name rejected"
}

test_parse_tune_config_unknown_key() {
  echo "test_parse_tune_config_unknown_key:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh
  # Inject a one-off bad config and confirm it's rejected.
  TUNE_CONFIGS[bad-cfg]='osd_mem_gb=64 cstate=on'
  if parse_tune_config "bad-cfg" >/dev/null 2>&1; then
    _fail "expected non-zero exit on unknown key osd_mem_gb"
    return
  fi
  unset 'TUNE_CONFIGS[bad-cfg]'
  _pass "unknown key rejected"
}
```

And add the new invocations alongside the existing one:

```bash
test_tune_configs_parse
test_parse_tune_config_valid
test_parse_tune_config_unknown_name
test_parse_tune_config_unknown_key
```

- [ ] **Step 2.2: Run tests, confirm new ones fail**

Run: `./tests/run-offline.sh`
Expected: existing test passes; the three new tests fail with `lib/tune-helpers.sh: No such file or directory`.

- [ ] **Step 2.3: Create `lib/tune-helpers.sh` with `parse_tune_config`**

```bash
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
```

- [ ] **Step 2.4: Run tests, confirm pass**

Run: `./tests/run-offline.sh`
Expected: all four tests PASS.

- [ ] **Step 2.5: Commit**

```bash
git add lib/tune-helpers.sh tests/run-offline.sh
git commit -m "feat(tune): add parse_tune_config validator in lib/tune-helpers.sh"
```

---

## Task 3: `lib/tune-helpers.sh` — `render_cstate_machineconfig`

**Files:**
- Modify: `lib/tune-helpers.sh` (append function)
- Test: `tests/run-offline.sh::test_render_cstate_machineconfig`

- [ ] **Step 3.1: Add the failing test**

Append to `tests/run-offline.sh` before the invocation block:

```bash
# -----------------------------------------------------------------------------
test_render_cstate_machineconfig() {
  echo "test_render_cstate_machineconfig:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh

  local tmp
  tmp=$(mktemp -t tune-mc-XXXXXX.yaml)
  trap "rm -f '${tmp}'" RETURN

  if ! render_cstate_machineconfig "${tmp}"; then
    _fail "render_cstate_machineconfig returned non-zero"
    return
  fi

  # File must exist and be non-empty
  [[ -s "${tmp}" ]] || { _fail "rendered MC is empty"; return; }

  # Must contain expected kernel args and target role=worker
  grep -q "intel_idle.max_cstate=0" "${tmp}" || { _fail "missing intel_idle kernel arg"; return; }
  grep -q "processor.max_cstate=0" "${tmp}"  || { _fail "missing processor kernel arg"; return; }
  grep -q "machineconfiguration.openshift.io/role: worker" "${tmp}" || { _fail "missing role=worker label"; return; }
  grep -q "name: ${TUNE_MC_NAME}" "${tmp}" || { _fail "missing MC name ${TUNE_MC_NAME}"; return; }

  # If oc is present, validate client-side
  if command -v oc &>/dev/null; then
    if ! oc apply --dry-run=client -f "${tmp}" >/dev/null 2>&1; then
      _fail "oc client-side validation failed"
      return
    fi
  fi
  _pass "rendered MC has expected kernel args and labels"
}
```

Add to the invocation list:
```bash
test_render_cstate_machineconfig
```

- [ ] **Step 3.2: Run, confirm new test fails**

Run: `./tests/run-offline.sh`
Expected: new test fails with `render_cstate_machineconfig: command not found` (function not yet defined).

- [ ] **Step 3.3: Implement `render_cstate_machineconfig`**

Append to `lib/tune-helpers.sh`:

```bash
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
```

- [ ] **Step 3.4: Run, confirm pass**

Run: `./tests/run-offline.sh`
Expected: all tests PASS, including `test_render_cstate_machineconfig`.

- [ ] **Step 3.5: Commit**

```bash
git add lib/tune-helpers.sh tests/run-offline.sh
git commit -m "feat(tune): add render_cstate_machineconfig"
```

---

## Task 4: `lib/tune-helpers.sh` — `snapshot_cluster_state` (cluster-side primitive)

**Files:**
- Modify: `lib/tune-helpers.sh`
- Test: `tests/smoke/snapshot.sh` (new smoke test — needs `oc` auth)

- [ ] **Step 4.1: Create the smoke test harness**

Create `tests/smoke/run-smoke.sh`:

```bash
#!/usr/bin/env bash
# tests/smoke/run-smoke.sh — cluster smoke test runner.
# Requires `oc` authenticated to a ROKS cluster with ODF installed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if ! oc cluster-info &>/dev/null; then
  echo "ERROR: oc is not authenticated. Source .env and re-run."
  exit 2
fi

PASS=0; FAIL=0; SKIP=0
_pass() { PASS=$((PASS+1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
_skip() { SKIP=$((SKIP+1)); echo "  SKIP  $1"; }

# Run all test scripts in tests/smoke/ named *.sh except this one.
for t in tests/smoke/*.sh; do
  [[ "${t}" == "tests/smoke/run-smoke.sh" ]] && continue
  echo "=== ${t} ==="
  if bash "${t}"; then
    _pass "${t}"
  else
    _fail "${t}"
  fi
done

echo
echo "===== ${PASS} passed, ${FAIL} failed, ${SKIP} skipped ====="
exit $(( FAIL > 0 ))
```

Make executable:
```bash
chmod +x tests/smoke/run-smoke.sh
```

Create `tests/smoke/snapshot.sh`:

```bash
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
grep -q "^osd_resources:"  "${tmp}" || { echo "missing osd_resources"; exit 1; }
grep -q "^cstate_mc_present:" "${tmp}" || { echo "missing cstate_mc_present"; exit 1; }
grep -q "^mcp_worker_updated:" "${tmp}" || { echo "missing mcp_worker_updated"; exit 1; }

echo "snapshot contents:"
cat "${tmp}"
```

Make executable:
```bash
chmod +x tests/smoke/snapshot.sh
```

- [ ] **Step 4.2: Run smoke test, expect failure**

Run: `./tests/smoke/snapshot.sh`
Expected: fails with `snapshot_cluster_state: command not found`.

- [ ] **Step 4.3: Implement `snapshot_cluster_state` in `lib/tune-helpers.sh`**

Append:

```bash
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
```

- [ ] **Step 4.4: Run smoke test, expect pass**

Run: `./tests/smoke/snapshot.sh`
Expected: snapshot YAML printed with all expected fields. Exit 0.

- [ ] **Step 4.5: Commit**

```bash
git add lib/tune-helpers.sh tests/smoke/snapshot.sh tests/smoke/run-smoke.sh
git commit -m "feat(tune): add snapshot_cluster_state primitive + smoke runner"
```

---

## Task 5: `lib/tune-helpers.sh` — `wait_for_osd_ready` and `wait_for_mcp_updated`

**Files:**
- Modify: `lib/tune-helpers.sh`
- Test: `tests/smoke/wait-noops.sh`

- [ ] **Step 5.1: Create smoke test**

Create `tests/smoke/wait-noops.sh`:

```bash
#!/usr/bin/env bash
# tests/smoke/wait-noops.sh — verify wait_for_* return ~immediately when
# the cluster is already in the target state (no patch pending).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

source 00-config.sh
source lib/vm-helpers.sh
source lib/wait-helpers.sh
source lib/tune-helpers.sh

start=$(date +%s)
wait_for_osd_ready 60
elapsed=$(( $(date +%s) - start ))
echo "wait_for_osd_ready completed in ${elapsed}s"
(( elapsed < 30 )) || { echo "FAIL: wait_for_osd_ready slow on quiescent cluster (${elapsed}s)"; exit 1; }

start=$(date +%s)
wait_for_mcp_updated worker 60
elapsed=$(( $(date +%s) - start ))
echo "wait_for_mcp_updated completed in ${elapsed}s"
(( elapsed < 30 )) || { echo "FAIL: wait_for_mcp_updated slow on quiescent cluster (${elapsed}s)"; exit 1; }
```

Make executable.

- [ ] **Step 5.2: Run, expect failure**

Run: `./tests/smoke/wait-noops.sh`
Expected: `wait_for_osd_ready: command not found`.

- [ ] **Step 5.3: Implement both wait helpers**

Append to `lib/tune-helpers.sh`:

```bash
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

  log_info "Waiting for OSDs ready (timeout=${timeout}s)"
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

    if (( not_ready == 0 )) && [[ "${health}" == "HEALTH_OK" || "${health}" == "HEALTH_WARN" ]]; then
      log_info "  OSDs ready, ceph=${health}"
      return 0
    fi

    log_debug "  osd-not-ready=${not_ready} ceph=${health:-unknown}; sleeping ${interval}s"
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
```

- [ ] **Step 5.4: Run smoke test, expect pass**

Run: `./tests/smoke/wait-noops.sh`
Expected: both helpers return within ~30 s on a quiescent cluster.

- [ ] **Step 5.5: Commit**

```bash
git add lib/tune-helpers.sh tests/smoke/wait-noops.sh
git commit -m "feat(tune): add wait_for_osd_ready and wait_for_mcp_updated"
```

---

## Task 6: `lib/tune-helpers.sh` — `apply_tuning_config`

**Files:**
- Modify: `lib/tune-helpers.sh`
- Test: `tests/smoke/apply-default-noop.sh`

- [ ] **Step 6.1: Create smoke test**

Create `tests/smoke/apply-default-noop.sh`:

```bash
#!/usr/bin/env bash
# tests/smoke/apply-default-noop.sh — applying the 'default' tune config to a
# cluster that's already at the default profile should be a no-op (no OSD
# restart, no MC change).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

source 00-config.sh
source lib/vm-helpers.sh
source lib/wait-helpers.sh
source lib/tune-helpers.sh

mkdir -p /tmp/tune-smoke
tmp=/tmp/tune-smoke/tuning-applied.yaml

start=$(date +%s)
apply_tuning_config default > "${tmp}"
elapsed=$(( $(date +%s) - start ))

echo "apply_tuning_config(default) completed in ${elapsed}s"
[[ -s "${tmp}" ]] || { echo "FAIL: tuning-applied empty"; exit 1; }
echo "--- tuning-applied.yaml ---"
cat "${tmp}"
# Must converge in <2 min on a quiescent cluster
(( elapsed < 120 )) || { echo "FAIL: apply slow on quiescent cluster"; exit 1; }
echo "PASS"
```

- [ ] **Step 6.2: Run, expect failure**

Run: `./tests/smoke/apply-default-noop.sh`
Expected: `apply_tuning_config: command not found`.

- [ ] **Step 6.3: Implement `apply_tuning_config`**

Append to `lib/tune-helpers.sh`:

```bash
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
      -p "{\"spec\":{\"resourceProfile\":\"${cfg[profile]}\"}}" \
      || { log_error "resourceProfile patch failed"; return 1; }
  fi

  # --- 2. OSD resource override -----------------------------------------------
  local osd_patch
  if [[ -n "${cfg[osd_cpu]:-}" || -n "${cfg[osd_mem]:-}" ]]; then
    local cpu="${cfg[osd_cpu]:-}"
    local mem="${cfg[osd_mem]:-}"
    local req='{'
    [[ -n "${cpu}" ]] && req+="\"cpu\":\"${cpu}\","
    [[ -n "${mem}" ]] && req+="\"memory\":\"${mem}\","
    req="${req%,}"
    req+='}'
    osd_patch="{\"spec\":{\"resources\":{\"osd\":{\"requests\":${req},\"limits\":${req}}}}}"
    log_info "Patching StorageCluster.spec.resources.osd: cpu=${cpu} memory=${mem}"
    oc patch storagecluster "${sc_name}" -n "${ns}" --type merge -p "${osd_patch}" \
      || { log_error "osd resources patch failed"; return 1; }
  else
    # Restore to inherit if no override requested.
    local osd_present
    osd_present=$(oc get storagecluster "${sc_name}" -n "${ns}" \
      -o jsonpath='{.spec.resources.osd}' 2>/dev/null)
    if [[ -n "${osd_present}" && "${osd_present}" != "{}" ]]; then
      log_info "Removing StorageCluster.spec.resources.osd override (back to profile defaults)"
      oc patch storagecluster "${sc_name}" -n "${ns}" --type json \
        -p='[{"op":"remove","path":"/spec/resources/osd"}]' \
        || { log_error "osd resources removal failed"; return 1; }
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
    oc apply -f "${mc_tmp}" || { rm -f "${mc_tmp}"; log_error "MC apply failed"; return 1; }
    rm -f "${mc_tmp}"
    mc_changed=true
  elif [[ "${cfg[cstate]}" == "on" && "${mc_present}" == "true" ]]; then
    log_info "Deleting cstate-off MachineConfig (${TUNE_MC_NAME})"
    oc delete machineconfig "${TUNE_MC_NAME}" --ignore-not-found \
      || { log_error "MC delete failed"; return 1; }
    mc_changed=true
  fi

  # --- 4. Wait for convergence ------------------------------------------------
  wait_for_osd_ready "${TUNE_OSD_TIMEOUT}" || return 1
  if [[ "${mc_changed}" == "true" ]]; then
    wait_for_mcp_updated worker "${TUNE_MCP_TIMEOUT}" || return 1
  fi

  # --- 5. Emit realised state -------------------------------------------------
  local realised_profile realised_osd
  realised_profile=$(oc get storagecluster "${sc_name}" -n "${ns}" \
    -o jsonpath='{.spec.resourceProfile}' 2>/dev/null)
  realised_osd=$(oc get storagecluster "${sc_name}" -n "${ns}" \
    -o json | jq -c '.spec.resources.osd // "inherit"')
  cat <<EOF
config_name: ${name}
realised_profile: ${realised_profile:-null}
realised_osd_resources: ${realised_osd}
cstate_mc_present: $(oc get machineconfig "${TUNE_MC_NAME}" &>/dev/null && echo true || echo false)
applied_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}
```

- [ ] **Step 6.4: Run smoke test, expect pass**

Run: `./tests/smoke/apply-default-noop.sh`
Expected: completes in <2 min, tuning-applied.yaml printed with `config_name: default` and matching profile.

- [ ] **Step 6.5: Commit**

```bash
git add lib/tune-helpers.sh tests/smoke/apply-default-noop.sh
git commit -m "feat(tune): add apply_tuning_config idempotent mutator"
```

---

## Task 7: `lib/tune-helpers.sh` — `restore_cluster_state`

**Files:**
- Modify: `lib/tune-helpers.sh`
- Test: `tests/smoke/restore-roundtrip.sh`

- [ ] **Step 7.1: Create roundtrip smoke test**

Create `tests/smoke/restore-roundtrip.sh`:

```bash
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
```

- [ ] **Step 7.2: Run, expect failure**

Run: `./tests/smoke/restore-roundtrip.sh`
Expected: `restore_cluster_state: command not found` (after EXIT trap fires harmlessly).

- [ ] **Step 7.3: Implement `restore_cluster_state`**

Append to `lib/tune-helpers.sh`:

```bash
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

  local sc_name ns resource_profile osd_resources cstate_mc_present
  sc_name=$(awk -F': ' '/^storagecluster_name:/{print $2}' "${snap}")
  ns=$(awk -F': ' '/^storagecluster_namespace:/{print $2}' "${snap}")
  resource_profile=$(awk -F': ' '/^resourceProfile:/{print $2}' "${snap}")
  osd_resources=$(awk -F': ' '/^osd_resources:/{print $2}' "${snap}")
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

  # --- OSD resources ---------------------------------------------------------
  if [[ "${osd_resources}" == "inherit" ]]; then
    log_info "Restoring: removing .spec.resources.osd override"
    oc patch storagecluster "${sc_name}" -n "${ns}" --type json \
      -p='[{"op":"remove","path":"/spec/resources/osd"}]' &>/dev/null || true
  else
    log_info "Restoring: .spec.resources.osd = ${osd_resources}"
    oc patch storagecluster "${sc_name}" -n "${ns}" --type merge \
      -p "{\"spec\":{\"resources\":{\"osd\":${osd_resources}}}}" \
      || { log_warn "restore: osd resources patch warning"; warnings=$((warnings+1)); }
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
```

- [ ] **Step 7.4: Run smoke test, expect pass**

Run: `./tests/smoke/restore-roundtrip.sh`
Expected: `PASS: round-trip clean`. Total time ~15-25 min (one OSD restart cycle on apply, one on restore).

- [ ] **Step 7.5: Commit**

```bash
git add lib/tune-helpers.sh tests/smoke/restore-roundtrip.sh
git commit -m "feat(tune): add restore_cluster_state primitive with snapshot round-trip"
```

---

## Task 8: `04-run-tests.sh` — `--qd-sweep` workload mode

**Files:**
- Modify: `04-run-tests.sh`
- Modify: `fio-profiles/mixed-70-30-rated.fio` (introduce `__QD__` placeholder if not present)
- Test: `tests/run-offline.sh::test_qd_sweep_dry_run`

- [ ] **Step 8.1: Inspect existing fio profile**

Run: `grep -n "iodepth" fio-profiles/mixed-70-30-rated.fio`

If `iodepth=32` is hard-coded, change it to `iodepth=__QD__`. Existing scale-test invocation needs to pass `QD=32` when rendering this profile — verify by running `grep -n "QD=" 04-run-tests.sh lib/*.sh` and make sure the renderer interpolates it. (If the profile already uses `${QD}` or `__QD__`, just confirm; no change.)

- [ ] **Step 8.2: Add the failing dry-run test**

Append to `tests/run-offline.sh`:

```bash
# -----------------------------------------------------------------------------
test_qd_sweep_dry_run() {
  echo "test_qd_sweep_dry_run:"
  OC_SKIP_CLUSTER_CHECK=true

  local out
  out=$(OC_SKIP_CLUSTER_CHECK=true ./04-run-tests.sh --qd-sweep \
    --pool rep3-virt --fixed-vms 4 --qd-list 1,4 --rate-iops 250 \
    --latency-sla 5 --dry-run 2>&1) || true

  echo "${out}" | grep -q "qd-sweep" || { _fail "no qd-sweep mention in dry-run"; return; }
  echo "${out}" | grep -q "fixed-vms: 4" || { _fail "missing fixed-vms in plan"; return; }
  echo "${out}" | grep -q "qd-list: 1,4" || { _fail "missing qd-list in plan"; return; }
  _pass "qd-sweep dry-run prints expected plan"
}
```

Add to invocation list: `test_qd_sweep_dry_run`.

- [ ] **Step 8.3: Run, expect failure**

Run: `./tests/run-offline.sh`
Expected: failure — 04 doesn't recognise `--qd-sweep`.

- [ ] **Step 8.4: Add `--qd-sweep` flag parsing to `04-run-tests.sh`**

Near the existing mode flags (around line 30-40 of `04-run-tests.sh`), add:

```bash
QD_SWEEP_MODE=false
FIXED_VMS=""
QD_LIST=""
TUNE_CFG_NAME="untagged"
```

In the argument-parsing case statement (around line 60), add:

```bash
    --qd-sweep)      QD_SWEEP_MODE=true; shift ;;
    --fixed-vms)     FIXED_VMS="$2"; shift 2 ;;
    --qd-list)       QD_LIST="$2"; shift 2 ;;
    --tune-cfg-name) TUNE_CFG_NAME="$2"; shift 2 ;;
```

In the mutual-exclusivity check (the existing `_mode_count` block), append:

```bash
[[ "${QD_SWEEP_MODE}" == true ]] && ((_mode_count += 1))
```

And update the error message to mention `--qd-sweep`.

Below the existing `if [[ "${SCALE_TEST_MODE}" == true ]]; then` requires-pool check, add the parallel block:

```bash
if [[ "${QD_SWEEP_MODE}" == true ]]; then
  if [[ -z "${POOL:-}" ]]; then
    echo "Error: --qd-sweep requires --pool <name>" >&2
    exit 1
  fi
  : "${FIXED_VMS:=${TUNE_FIXED_VMS}}"
  : "${QD_LIST:=${TUNE_QD_LIST}}"
fi
```

Update help text in the `--help` case to list the new flags.

- [ ] **Step 8.5: Add the dry-run plan output**

Find the existing `if [[ "${DRY_RUN}" == true ]]; then` block. Just before it, or in a parallel branch keyed off `QD_SWEEP_MODE`, add:

```bash
if [[ "${QD_SWEEP_MODE}" == true && "${DRY_RUN}" == true ]]; then
  log_info "=== qd-sweep dry-run plan ==="
  log_info "pool:        ${POOL}"
  log_info "fixed-vms:   ${FIXED_VMS}"
  log_info "qd-list:     ${QD_LIST}"
  log_info "rate-iops:   ${RATE_IOPS:-${TUNE_RATE_IOPS}}"
  log_info "latency-sla: ${LATENCY_SLA:-${TUNE_LATENCY_SLA_MS}}"
  log_info "tune-cfg:    ${TUNE_CFG_NAME}"
  local _qd_count
  _qd_count=$(echo "${QD_LIST}" | awk -F',' '{print NF}')
  log_info "permutations: 1 (population reused across QDs) × ${_qd_count} QD steps"
  exit 0
fi
```

- [ ] **Step 8.6: Run, confirm dry-run test passes**

Run: `./tests/run-offline.sh`
Expected: `test_qd_sweep_dry_run` PASSES.

- [ ] **Step 8.7: Implement the qd-sweep execution loop**

Find the scale-test entry point (search for `if [[ "${SCALE_TEST_MODE}" == true ]]; then` near line 146) and add a parallel block for `QD_SWEEP_MODE`. Wrap the existing scale-test handler in an if/elif chain so qd-sweep is mutually exclusive.

Add a new function near the scale-test functions:

```bash
# ---------------------------------------------------------------------------
# qd_sweep_main — fixed-N VM population, sweep QD list.
# Uses the existing VM reuse pattern: create VMs once, swap fio config via
# SSH between QD steps. Writes results to:
#   ${RESULTS_DIR}/${RUN_ID}/qd-sweep/${POOL}/${TUNE_CFG_NAME}/
# ---------------------------------------------------------------------------
qd_sweep_main() {
  local pool="${POOL}"
  local cfg="${TUNE_CFG_NAME}"
  local n="${FIXED_VMS}"
  local rate_iops="${RATE_IOPS:-${TUNE_RATE_IOPS}}"
  local sla="${LATENCY_SLA:-${TUNE_LATENCY_SLA_MS}}"
  local IFS_save="${IFS}"
  IFS=','; read -r -a qd_arr <<< "${QD_LIST}"; IFS="${IFS_save}"

  local out_dir="${RESULTS_DIR}/${RUN_ID}/qd-sweep/${pool}/${cfg}"
  local raw_dir="${out_dir}/raw"
  local qd_csv="${out_dir}/qd.csv"
  local qd_summary="${out_dir}/qd-summary.json"
  mkdir -p "${raw_dir}"

  log_info "=== qd-sweep: pool=${pool} cfg=${cfg} n=${n} qds=${QD_LIST} ==="

  # qd.csv header
  if [[ ! -f "${qd_csv}" ]]; then
    cat > "${qd_csv}" <<'CSVHEAD'
vm_count,qd,rate_iops,total_read_iops,total_write_iops,total_bw_mbs,avg_p50_read_ms,avg_p95_read_ms,max_p99_read_ms,avg_p50_write_ms,avg_p95_write_ms,max_p99_write_ms,sla_pass
CSVHEAD
  fi

  # ---- Phase 1: bring up the VM population ---------------------------------
  local sc_name
  sc_name=$(get_storage_class_for_pool "${pool}") || return 1
  local volume_mode
  volume_mode=$(get_volume_mode_for_pool "${pool}")

  local first_qd="${qd_arr[0]}"
  local profile_path="${SCRIPT_DIR}/fio-profiles/mixed-70-30-rated.fio"
  local rendered_fio
  rendered_fio=$(QD="${first_qd}" RATE_IOPS="${rate_iops}" \
    render_fio_profile "${profile_path}")

  local -a vm_names=()
  local i
  for (( i=1; i<=n; i++ )); do
    vm_names+=("perf-qd-${pool}-${cfg}-$(printf '%03d' "${i}")")
  done

  # Batch-create VMs using the existing parallel-create helper.
  local created
  created=$(create_test_vms_batch "${pool}" "${sc_name}" "${volume_mode}" \
    "${rendered_fio}" "${vm_names[@]}") || true
  if (( created < n )); then
    log_warn "Only ${created}/${n} VMs created (resource ceiling). Recording and exiting."
    cat > "${qd_summary}" <<EOF
{
  "pool": "${pool}",
  "tune_cfg_name": "${cfg}",
  "vm_count_requested": ${n},
  "vm_count_created": ${created},
  "resource_ceiling": true,
  "qd_list": [${QD_LIST}],
  "run_id": "${RUN_ID}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    return 0
  fi

  wait_for_all_vms_running "${vm_names[@]}" || { log_error "VM ready wait failed"; return 1; }
  wait_for_all_prefill_complete "${vm_names[@]}" || { log_error "Prefill wait failed"; return 1; }

  # ---- Phase 2: sweep QD ---------------------------------------------------
  local qd
  for qd in "${qd_arr[@]}"; do
    local cp_key="qd-sweep:${pool}:${cfg}:${qd}"
    if grep -qF "${cp_key}" "${RESULTS_DIR}/${RUN_ID}.checkpoint" 2>/dev/null; then
      log_info "  QD=${qd}: already checkpointed, skipping"
      continue
    fi

    log_info "--- QD=${qd} ---"
    local fio_for_qd
    fio_for_qd=$(QD="${qd}" RATE_IOPS="${rate_iops}" render_fio_profile "${profile_path}")

    local vm
    for vm in "${vm_names[@]}"; do
      replace_fio_job "${vm}" "${fio_for_qd}" \
        || { log_warn "  replace_fio_job failed on ${vm}; continuing"; }
    done

    # Wall-clock sync barrier
    local epoch=$(( $(date +%s) + SCALE_SYNC_BARRIER_SECS ))
    for vm in "${vm_names[@]}"; do
      restart_fio_service "${vm}" "${epoch}" \
        || { log_warn "  restart_fio_service failed on ${vm}; continuing"; }
    done

    wait_for_all_fio_complete "${vm_names[@]}" || true

    # Collect per-VM JSON for this QD
    local qd_raw="${raw_dir}/qd${qd}"
    mkdir -p "${qd_raw}"
    for vm in "${vm_names[@]}"; do
      collect_vm_results "${vm}" "${qd_raw}/${vm}-fio.json" || true
    done

    # Aggregate one CSV row
    aggregate_qd_step "${qd_raw}" "${n}" "${qd}" "${rate_iops}" "${sla}" >> "${qd_csv}"

    echo "${cp_key}" >> "${RESULTS_DIR}/${RUN_ID}.checkpoint"
  done

  # ---- Phase 3: cleanup ----------------------------------------------------
  for vm in "${vm_names[@]}"; do
    delete_test_vm "${vm}" || true
  done

  # ---- qd-summary.json -----------------------------------------------------
  generate_qd_summary "${qd_csv}" "${qd_summary}" \
    "${pool}" "${cfg}" "${n}" "${rate_iops}" "${sla}"

  log_info "=== qd-sweep complete: ${qd_csv} ==="
}
```

Wire it up in the main dispatch:

```bash
if [[ "${QD_SWEEP_MODE}" == true ]]; then
  qd_sweep_main
  exit $?
fi
```

- [ ] **Step 8.8: Add `aggregate_qd_step` and `generate_qd_summary` to `lib/report-helpers.sh`**

Append to `lib/report-helpers.sh`:

```bash
# ---------------------------------------------------------------------------
# aggregate_qd_step <raw_dir> <vm_count> <qd> <rate_iops> <sla_ms>
#   Reads all *-fio.json files in raw_dir and emits one CSV row matching the
#   qd.csv schema. Skips empty / malformed JSON; if all VMs failed, emits a
#   NaN row with sla_pass=false.
# ---------------------------------------------------------------------------
aggregate_qd_step() {
  local raw_dir="$1" vm_count="$2" qd="$3" rate="$4" sla="$5"

  python3 - "${raw_dir}" "${vm_count}" "${qd}" "${rate}" "${sla}" <<'PYEOF'
import json, os, sys, glob, math

raw_dir, vm_count, qd, rate, sla = sys.argv[1:]
vm_count, qd, rate = int(vm_count), int(qd), int(rate)
sla = float(sla)

read_iops_sum = write_iops_sum = bw_mbs_sum = 0.0
p50_r=[]; p95_r=[]; p99_r=[]
p50_w=[]; p95_w=[]; p99_w=[]
ok = 0
for path in glob.glob(os.path.join(raw_dir, "*-fio.json")):
    try:
        with open(path) as f:
            d = json.load(f)
        jobs = d.get("jobs") or []
        if not jobs: continue
        # mixed-70-30-rated has one job with both read+write
        j = jobs[0]
        r = j.get("read", {})
        w = j.get("write", {})
        read_iops_sum += r.get("iops", 0.0)
        write_iops_sum += w.get("iops", 0.0)
        bw_mbs_sum += (r.get("bw", 0.0) + w.get("bw", 0.0)) / 1024.0  # KB/s → MB/s
        # Latency percentiles are in clat_ns.percentile, in nanoseconds
        rcl = r.get("clat_ns", {}).get("percentile", {})
        wcl = w.get("clat_ns", {}).get("percentile", {})
        if rcl:
            p50_r.append(rcl.get("50.000000", 0) / 1e6)
            p95_r.append(rcl.get("95.000000", 0) / 1e6)
            p99_r.append(rcl.get("99.000000", 0) / 1e6)
        if wcl:
            p50_w.append(wcl.get("50.000000", 0) / 1e6)
            p95_w.append(wcl.get("95.000000", 0) / 1e6)
            p99_w.append(wcl.get("99.000000", 0) / 1e6)
        ok += 1
    except Exception:
        continue

def avg(xs): return sum(xs)/len(xs) if xs else float("nan")
def mx(xs):  return max(xs) if xs else float("nan")

if ok == 0:
    print(f"{vm_count},{qd},{rate},nan,nan,nan,nan,nan,nan,nan,nan,nan,false")
    sys.exit(0)

avg_p50_r = avg(p50_r); avg_p95_r = avg(p95_r); max_p99_r = mx(p99_r)
avg_p50_w = avg(p50_w); avg_p95_w = avg(p95_w); max_p99_w = mx(p99_w)
sla_pass = "true" if (max_p99_w == max_p99_w and max_p99_w < sla) else "false"
fail_pct = (vm_count - ok) / vm_count * 100
if fail_pct > 10:
    sla_pass = "false"

print(f"{vm_count},{qd},{rate},"
      f"{read_iops_sum:.0f},{write_iops_sum:.0f},{bw_mbs_sum:.1f},"
      f"{avg_p50_r:.3f},{avg_p95_r:.3f},{max_p99_r:.3f},"
      f"{avg_p50_w:.3f},{avg_p95_w:.3f},{max_p99_w:.3f},"
      f"{sla_pass}")
PYEOF
}

# ---------------------------------------------------------------------------
# generate_qd_summary <qd_csv> <out_json> <pool> <cfg> <vm_count> <rate> <sla>
#   Reads the per-QD CSV and emits the qd-summary.json document.
# ---------------------------------------------------------------------------
generate_qd_summary() {
  local csv="$1" out="$2" pool="$3" cfg="$4" vm_count="$5" rate="$6" sla="$7"

  python3 - "${csv}" "${out}" "${pool}" "${cfg}" "${vm_count}" "${rate}" "${sla}" \
           "${RUN_ID}" "${CLUSTER_DESCRIPTION:-}" <<'PYEOF'
import csv, json, sys, datetime, os, subprocess

csv_path, out_path, pool, cfg, vm_count, rate, sla, run_id, cluster_desc = sys.argv[1:]
vm_count, rate, sla = int(vm_count), int(rate), float(sla)

rows = []
with open(csv_path) as f:
    for row in csv.DictReader(f):
        try:
            rows.append({
                "qd": int(row["qd"]),
                "total_iops": float(row["total_read_iops"]) + float(row["total_write_iops"]),
                "p99_r": float(row["max_p99_read_ms"]),
                "p99_w": float(row["max_p99_write_ms"]),
                "sla_pass": row["sla_pass"] == "true",
            })
        except (ValueError, KeyError):
            continue

if not rows:
    print(json.dumps({"error": "no qd rows", "pool": pool, "tune_cfg_name": cfg}, indent=2))
    open(out_path, "w").write(json.dumps({"error": "no qd rows"}))
    sys.exit(0)

# Highest QD with sla_pass
passing = [r for r in rows if r["sla_pass"]]
hi = max((r["qd"] for r in passing), default=0)
iops_at_hi = next((r["total_iops"] for r in rows if r["qd"] == hi), 0) if hi else 0

# Peak IOPS row
peak = max(rows, key=lambda r: r["total_iops"])

# Best-effort OCS version
ocs_version = ""
try:
    ocs_version = subprocess.run(
        ["oc", "get", "csv", "-n", "openshift-storage",
         "-o", "jsonpath={.items[?(@.spec.displayName==\"OpenShift Data Foundation\")].spec.version}"],
        capture_output=True, text=True, timeout=10).stdout.strip()
except Exception:
    pass

summary = {
    "pool": pool,
    "tune_cfg_name": cfg,
    "vm_count": vm_count,
    "rate_iops_per_vm": rate,
    "qd_list": [r["qd"] for r in rows],
    "latency_sla_ms": sla,
    "highest_qd_within_sla": hi,
    "iops_at_highest_qd_within_sla": int(iops_at_hi),
    "qd_with_peak_iops": peak["qd"],
    "peak_total_iops": int(peak["total_iops"]),
    "p99_write_at_peak_qd_ms": peak["p99_w"],
    "p99_read_at_peak_qd_ms": peak["p99_r"],
    "resource_ceiling": False,
    "ocs_version": ocs_version,
    "cluster_description": cluster_desc,
    "run_id": run_id,
    "timestamp": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}
open(out_path, "w").write(json.dumps(summary, indent=2))
PYEOF
}
```

- [ ] **Step 8.9: Manual smoke test of `--qd-sweep`**

Run the actual workload mode against a small population at the cluster's current tuning:
```bash
./04-run-tests.sh --qd-sweep --pool rep3-virt \
  --fixed-vms 4 --qd-list 1,32 --rate-iops 250
```
Expected: ~10-15 min, produces `results/<run-id>/qd-sweep/rep3-virt/untagged/qd.csv` with 2 rows.

- [ ] **Step 8.10: Commit**

```bash
git add 04-run-tests.sh lib/report-helpers.sh fio-profiles/mixed-70-30-rated.fio tests/run-offline.sh
git commit -m "feat(qd-sweep): add fixed-N + QD-sweep workload mode to 04-run-tests"
```

---

## Task 9: `09-run-tune-sweep.sh` — config-level orchestrator

**Files:**
- Create: `09-run-tune-sweep.sh`
- Test: `tests/run-offline.sh::test_tune_sweep_dry_run`

- [ ] **Step 9.1: Add the failing dry-run test**

Append to `tests/run-offline.sh`:

```bash
# -----------------------------------------------------------------------------
test_tune_sweep_dry_run() {
  echo "test_tune_sweep_dry_run:"
  local out
  out=$(OC_SKIP_CLUSTER_CHECK=true ./09-run-tune-sweep.sh --pool rep3-virt \
    --configs default,big-osd --fixed-vms 4 --qd-list 1,32 --dry-run 2>&1) || true
  echo "${out}" | grep -q "Tune-sweep plan" || { _fail "missing plan banner"; return; }
  echo "${out}" | grep -q "2 configs" || { _fail "missing config count"; return; }
  echo "${out}" | grep -q "default" || { _fail "missing default cfg"; return; }
  echo "${out}" | grep -q "big-osd" || { _fail "missing big-osd cfg"; return; }
  _pass "tune-sweep --dry-run prints plan"
}

test_tune_sweep_unknown_config() {
  echo "test_tune_sweep_unknown_config:"
  if OC_SKIP_CLUSTER_CHECK=true ./09-run-tune-sweep.sh --pool rep3-virt \
    --configs nonexistent --dry-run >/dev/null 2>&1; then
    _fail "expected non-zero exit on unknown config"
    return
  fi
  _pass "unknown config rejected at preflight"
}
```

Add to invocation list: `test_tune_sweep_dry_run` and `test_tune_sweep_unknown_config`.

- [ ] **Step 9.2: Run, expect failure**

Run: `./tests/run-offline.sh`
Expected: both new tests fail (script doesn't exist).

- [ ] **Step 9.3: Create `09-run-tune-sweep.sh`**

```bash
#!/usr/bin/env bash
# =============================================================================
# 09-run-tune-sweep.sh — config-level orchestrator for the ODF tuning sweep.
# Snapshots cluster state, applies each tune config in turn, runs the qd-sweep
# workload per config, and restores on every exit path.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Args
POOL=""
CONFIGS_CSV=""
FIXED_VMS=""
QD_LIST=""
RATE_IOPS=""
LATENCY_SLA=""
DRY_RUN=false
RESUME_RUN_ID=""
RESTORE_FROM=""
FORCE=false
AUTO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool)         POOL="$2"; shift 2 ;;
    --configs)      CONFIGS_CSV="$2"; shift 2 ;;
    --fixed-vms)    FIXED_VMS="$2"; shift 2 ;;
    --qd-list)      QD_LIST="$2"; shift 2 ;;
    --rate-iops)    RATE_IOPS="$2"; shift 2 ;;
    --latency-sla)  LATENCY_SLA="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --resume)       RESUME_RUN_ID="$2"; shift 2 ;;
    --restore-from) RESTORE_FROM="$2"; shift 2 ;;
    --force)        FORCE=true; shift ;;
    --auto|--yes)   AUTO=true; shift ;;
    --help|-h)
      cat <<USAGE
Usage: $0 --pool <name> [options]

Sweep tunings:
  --configs <csv>         Comma-separated TUNE_CONFIGS names (default: ${TUNE_DEFAULT_CONFIGS:-...})
  --fixed-vms <N>         VM population per config (default: ${TUNE_FIXED_VMS:-200})
  --qd-list <csv>         Queue depths to sweep (default: ${TUNE_QD_LIST:-1,2,4,8,16,32,64})
  --rate-iops <N>         Per-VM IOPS cap (default: ${TUNE_RATE_IOPS:-500})
  --latency-sla <ms>      Write-p99 SLA threshold (default: ${TUNE_LATENCY_SLA_MS:-5})

Lifecycle:
  --dry-run               Print the plan, exit without mutating anything
  --resume <run-id>       Resume a partial sweep
  --restore-from <run-id> Restore cluster from a saved snapshot (no workload)
  --force                 Override the .tune-sweep.lock file
  --auto, --yes           Skip interactive confirmations (multi-AZ, NTO conflict)
USAGE
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Sources (config first, then helpers)
source 00-config.sh
source lib/vm-helpers.sh
source lib/wait-helpers.sh
source lib/tune-helpers.sh

# --restore-from short-circuit
if [[ -n "${RESTORE_FROM}" ]]; then
  snap="${RESULTS_DIR}/${RESTORE_FROM}/cluster-snapshot.yaml"
  [[ -s "${snap}" ]] || { log_error "no snapshot at ${snap}"; exit 1; }
  restore_cluster_state "${snap}"
  exit $?
fi

# Pool required for non-restore invocations
[[ -z "${POOL}" ]] && { echo "Error: --pool is required" >&2; exit 1; }

# Defaults
: "${CONFIGS_CSV:=${TUNE_DEFAULT_CONFIGS}}"
: "${FIXED_VMS:=${TUNE_FIXED_VMS}}"
: "${QD_LIST:=${TUNE_QD_LIST}}"
: "${RATE_IOPS:=${TUNE_RATE_IOPS}}"
: "${LATENCY_SLA:=${TUNE_LATENCY_SLA_MS}}"

IFS=',' read -r -a CONFIGS <<< "${CONFIGS_CSV}"

# Pre-flight: every config must parse
for cfg in "${CONFIGS[@]}"; do
  parse_tune_config "${cfg}" >/dev/null || exit 1
done

# Pool feasibility (defer to existing helpers in vm-helpers.sh if present)
if declare -f get_storage_class_for_pool >/dev/null; then
  get_storage_class_for_pool "${POOL}" >/dev/null \
    || { log_error "pool ${POOL} has no StorageClass; run 01-setup-storage-pools.sh"; exit 1; }
fi

# Plan
print_plan() {
  local n_cfg=${#CONFIGS[@]}
  local qd_count
  qd_count=$(echo "${QD_LIST}" | awk -F',' '{print NF}')
  cat <<EOF

==========================================
Tune-sweep plan
==========================================
  pool:        ${POOL}
  configs:     ${n_cfg} configs (${CONFIGS_CSV})
  fixed-vms:   ${FIXED_VMS}
  qd-list:     ${QD_LIST}  (${qd_count} steps)
  rate-iops:   ${RATE_IOPS} per VM
  latency-SLA: ${LATENCY_SLA} ms write-p99

  Cluster mutations per cfg:
    StorageCluster patch + OSD restart  ≈ 12 min
    MachineConfig + worker MCP reboot   ≈ 30 min (only when cstate flips)

  Per-cfg workload time:
    ${qd_count} QD × (~90s prefill + ~90s measure + ~30s collect) ≈ $((qd_count * 4)) min
==========================================
EOF
}

print_plan

if [[ "${DRY_RUN}" == true ]]; then
  exit 0
fi

# Optional cluster checks (skipped under OC_SKIP_CLUSTER_CHECK for offline tests)
if [[ "${OC_SKIP_CLUSTER_CHECK:-false}" != "true" ]]; then
  oc cluster-info &>/dev/null || { log_error "oc not authenticated"; exit 1; }

  if [[ "${CLUSTER_MULTI_AZ:-false}" == "true" && "${AUTO}" != "true" ]]; then
    read -r -p "Multi-AZ cluster detected. Slide methodology was single-zone. Proceed? [y/N] " r
    [[ "${r,,}" == "y" ]] || exit 0
  fi
fi

# Lock
LOCK="${RESULTS_DIR}/.tune-sweep.lock"
if [[ -s "${LOCK}" && "${FORCE}" != "true" ]]; then
  log_error "Another tune-sweep appears to be running:"
  cat "${LOCK}" >&2
  log_error "Use --force to override."
  exit 1
fi
mkdir -p "${RESULTS_DIR}"
cat > "${LOCK}" <<EOF
{"pid": $$, "host": "$(hostname)", "started": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF

# Run ID
if [[ -n "${RESUME_RUN_ID}" ]]; then
  RUN_ID="${RESUME_RUN_ID}"
else
  RUN_ID="tune-$(date +%Y%m%d-%H%M%S)"
fi
export RUN_ID

SNAPSHOT="${RESULTS_DIR}/${RUN_ID}/cluster-snapshot.yaml"
mkdir -p "$(dirname "${SNAPSHOT}")"
if [[ ! -s "${SNAPSHOT}" ]]; then
  snapshot_cluster_state "${SNAPSHOT}"
fi

RESTORE_DONE=false
_on_exit() {
  local rc=$?
  rm -f "${LOCK}"
  if [[ "${RESTORE_DONE}" != "true" ]]; then
    log_warn "Tune-sweep exiting (rc=${rc}); restoring cluster from snapshot..."
    restore_cluster_state "${SNAPSHOT}" || \
      log_error "Restore reported issues — verify manually: oc get storagecluster -o yaml"
    RESTORE_DONE=true
  fi
  return $rc
}
trap _on_exit EXIT INT TERM

# Per-cfg helper: is this cfg fully checkpointed?
cfg_complete_in_checkpoint() {
  local cfg="$1"
  local cp="${RESULTS_DIR}/${RUN_ID}.checkpoint"
  [[ -f "${cp}" ]] || return 1
  local qd
  for qd in ${QD_LIST//,/ }; do
    grep -qF "qd-sweep:${POOL}:${cfg}:${qd}" "${cp}" || return 1
  done
  return 0
}

# Sweep loop
for cfg in "${CONFIGS[@]}"; do
  log_info "===== Config: ${cfg} ====="

  if cfg_complete_in_checkpoint "${cfg}"; then
    log_info "  Already complete; skipping"
    continue
  fi

  cfg_dir="${RESULTS_DIR}/${RUN_ID}/qd-sweep/${POOL}/${cfg}"
  mkdir -p "${cfg_dir}"

  apply_tuning_config "${cfg}" > "${cfg_dir}/tuning-applied.yaml" \
    || { log_error "apply failed for ${cfg}"; exit 1; }

  RUN_ID="${RUN_ID}" ./04-run-tests.sh \
    --qd-sweep \
    --pool "${POOL}" \
    --fixed-vms "${FIXED_VMS}" \
    --qd-list "${QD_LIST}" \
    --rate-iops "${RATE_IOPS}" \
    --latency-sla "${LATENCY_SLA}" \
    --tune-cfg-name "${cfg}" \
    || { log_error "Workload failed for ${cfg}"; exit 1; }
done

log_info "All configs complete. Restoring initial cluster state..."
restore_cluster_state "${SNAPSHOT}"
RESTORE_DONE=true

./06-generate-report.sh --compare-tuning \
  --run "${RUN_ID}" \
  --pool "${POOL}" \
  || log_warn "Report generation failed; data preserved in ${RESULTS_DIR}/${RUN_ID}"
```

Make executable:
```bash
chmod +x 09-run-tune-sweep.sh
```

- [ ] **Step 9.4: Run dry-run test, expect pass**

Run: `./tests/run-offline.sh`
Expected: `test_tune_sweep_dry_run` and `test_tune_sweep_unknown_config` PASS.

- [ ] **Step 9.5: Commit**

```bash
git add 09-run-tune-sweep.sh tests/run-offline.sh
git commit -m "feat(tune): add 09-run-tune-sweep.sh orchestrator with snapshot/restore"
```

---

## Task 10: Test fixture `tests/fixtures/tune-sweep-3cfg/`

**Files:**
- Create: `tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/{default,cstate-off,big-osd}/{qd.csv,qd-summary.json,tuning-applied.yaml}`

- [ ] **Step 10.1: Create the fixture directory structure**

```bash
mkdir -p tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/{default,cstate-off,big-osd}
```

- [ ] **Step 10.2: Write `default` config fixtures**

`tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/default/qd.csv`:
```csv
vm_count,qd,rate_iops,total_read_iops,total_write_iops,total_bw_mbs,avg_p50_read_ms,avg_p95_read_ms,max_p99_read_ms,avg_p50_write_ms,avg_p95_write_ms,max_p99_write_ms,sla_pass
200,1,500,8500,3600,47.3,2.1,15.2,42.5,4.8,38.6,89.1,false
200,2,500,15800,6750,88.5,4.6,32.1,82.0,9.7,76.4,178.5,false
200,4,500,28400,12100,158.8,8.9,58.7,153.6,18.3,142.8,331.2,false
200,8,500,38900,16700,217.7,17.3,108.5,278.1,33.6,256.7,594.0,false
200,16,500,46100,19800,257.9,32.5,180.3,461.5,61.2,432.1,981.7,false
200,32,500,52300,22500,292.7,58.4,304.6,765.2,107.5,732.9,1640.0,false
200,64,500,56862,24385,316.7,99.8,512.3,1227.5,179.4,1242.8,2604.0,false
```

`tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/default/qd-summary.json`:
```json
{
  "pool": "rep3-virt",
  "tune_cfg_name": "default",
  "vm_count": 200,
  "rate_iops_per_vm": 500,
  "qd_list": [1, 2, 4, 8, 16, 32, 64],
  "latency_sla_ms": 5,
  "highest_qd_within_sla": 0,
  "iops_at_highest_qd_within_sla": 0,
  "qd_with_peak_iops": 64,
  "peak_total_iops": 81247,
  "p99_write_at_peak_qd_ms": 2604.0,
  "p99_read_at_peak_qd_ms": 1227.5,
  "resource_ceiling": false,
  "ocs_version": "4.18.0",
  "cluster_description": "test-fixture-3wkr",
  "run_id": "tune-fixture",
  "timestamp": "2026-06-01T00:00:00Z"
}
```

`tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/default/tuning-applied.yaml`:
```yaml
config_name: default
realised_profile: balanced
realised_osd_resources: "inherit"
cstate_mc_present: false
applied_at: 2026-06-01T00:00:00Z
```

- [ ] **Step 10.3: Write `cstate-off` fixtures**

`tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/cstate-off/qd.csv`:
```csv
vm_count,qd,rate_iops,total_read_iops,total_write_iops,total_bw_mbs,avg_p50_read_ms,avg_p95_read_ms,max_p99_read_ms,avg_p50_write_ms,avg_p95_write_ms,max_p99_write_ms,sla_pass
200,1,500,9100,3900,50.7,1.9,13.6,38.4,4.3,34.8,80.2,false
200,2,500,16900,7250,94.8,4.1,28.5,73.8,8.7,68.7,160.7,false
200,4,500,30500,13050,170.3,8.0,52.4,138.4,16.5,128.2,298.1,false
200,8,500,41700,17900,233.0,15.6,97.6,250.3,30.2,231.0,534.6,false
200,16,500,49500,21250,276.9,29.3,162.3,415.4,55.1,388.9,883.5,false
200,32,500,56250,24160,313.9,52.6,274.1,688.7,96.8,659.6,1476.0,false
200,64,500,61214,26240,341.7,89.8,461.1,1104.8,161.4,1118.5,2343.6,false
```

`tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/cstate-off/qd-summary.json`:
```json
{
  "pool": "rep3-virt",
  "tune_cfg_name": "cstate-off",
  "vm_count": 200,
  "rate_iops_per_vm": 500,
  "qd_list": [1, 2, 4, 8, 16, 32, 64],
  "latency_sla_ms": 5,
  "highest_qd_within_sla": 0,
  "iops_at_highest_qd_within_sla": 0,
  "qd_with_peak_iops": 64,
  "peak_total_iops": 87454,
  "p99_write_at_peak_qd_ms": 2343.6,
  "p99_read_at_peak_qd_ms": 1104.8,
  "resource_ceiling": false,
  "ocs_version": "4.18.0",
  "cluster_description": "test-fixture-3wkr",
  "run_id": "tune-fixture",
  "timestamp": "2026-06-01T00:30:00Z"
}
```

`tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/cstate-off/tuning-applied.yaml`:
```yaml
config_name: cstate-off
realised_profile: balanced
realised_osd_resources: "inherit"
cstate_mc_present: true
applied_at: 2026-06-01T00:30:00Z
```

- [ ] **Step 10.4: Write `big-osd` fixtures**

`tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/big-osd/qd.csv`:
```csv
vm_count,qd,rate_iops,total_read_iops,total_write_iops,total_bw_mbs,avg_p50_read_ms,avg_p95_read_ms,max_p99_read_ms,avg_p50_write_ms,avg_p95_write_ms,max_p99_write_ms,sla_pass
200,1,500,14000,6000,78.0,0.31,0.51,0.62,0.78,1.05,1.71,true
200,2,500,28000,12000,156.0,0.32,0.53,0.64,0.79,1.06,1.74,true
200,4,500,56000,24000,312.0,0.34,0.55,0.66,0.81,1.09,1.78,true
200,8,500,70000,30000,390.2,0.39,0.58,0.68,0.84,1.13,1.82,true
200,16,500,70000,30000,390.2,0.48,0.61,0.69,0.92,1.18,1.85,true
200,32,500,70000,30000,390.2,0.58,0.65,0.69,1.05,1.22,1.88,true
200,64,500,70000,30000,390.2,0.69,0.70,0.71,1.21,1.30,1.92,true
```

`tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/big-osd/qd-summary.json`:
```json
{
  "pool": "rep3-virt",
  "tune_cfg_name": "big-osd",
  "vm_count": 200,
  "rate_iops_per_vm": 500,
  "qd_list": [1, 2, 4, 8, 16, 32, 64],
  "latency_sla_ms": 5,
  "highest_qd_within_sla": 64,
  "iops_at_highest_qd_within_sla": 100000,
  "qd_with_peak_iops": 64,
  "peak_total_iops": 100000,
  "p99_write_at_peak_qd_ms": 1.92,
  "p99_read_at_peak_qd_ms": 0.71,
  "resource_ceiling": false,
  "ocs_version": "4.18.0",
  "cluster_description": "test-fixture-3wkr",
  "run_id": "tune-fixture",
  "timestamp": "2026-06-01T01:00:00Z"
}
```

`tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt/big-osd/tuning-applied.yaml`:
```yaml
config_name: big-osd
realised_profile: balanced
realised_osd_resources: '{"requests":{"cpu":"8","memory":"64Gi"},"limits":{"cpu":"8","memory":"64Gi"}}'
cstate_mc_present: false
applied_at: 2026-06-01T01:00:00Z
```

- [ ] **Step 10.5: Commit fixtures**

```bash
git add tests/fixtures/tune-sweep-3cfg/
git commit -m "test(tune): add 3-config fixture for tune-sweep report tests"
```

---

## Task 11: `lib/report-helpers.sh` — `generate_tune_sweep_report()`

**Files:**
- Modify: `lib/report-helpers.sh` (append function)
- Test: `tests/run-offline.sh::test_tune_sweep_report_html`

- [ ] **Step 11.1: Add the failing test**

Append to `tests/run-offline.sh`:

```bash
# -----------------------------------------------------------------------------
test_tune_sweep_report_html() {
  echo "test_tune_sweep_report_html:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/report-helpers.sh

  local tmp
  tmp=$(mktemp -t tune-report-XXXXXX.html)
  trap "rm -f '${tmp}'" RETURN

  if ! generate_tune_sweep_report \
       "tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt" \
       "rep3-virt" "default" "64" "${tmp}"; then
    _fail "generate_tune_sweep_report returned non-zero"
    return
  fi

  [[ -s "${tmp}" ]] || { _fail "report HTML empty"; return; }
  grep -q "<title>" "${tmp}" || { _fail "missing <title>"; return; }
  grep -q "rampChart" "${tmp}" || grep -q "qdChart" "${tmp}" || { _fail "missing QD chart canvas"; return; }
  grep -q "headlineIops" "${tmp}" || { _fail "missing headline IOPS canvas"; return; }
  grep -q "default" "${tmp}"   || { _fail "missing default config"; return; }
  grep -q "big-osd" "${tmp}"   || { _fail "missing big-osd config"; return; }
  _pass "tune-sweep report HTML generated"
}
```

Add to invocation list: `test_tune_sweep_report_html`.

- [ ] **Step 11.2: Run, expect failure**

Run: `./tests/run-offline.sh`
Expected: `generate_tune_sweep_report: command not found`.

- [ ] **Step 11.3: Implement `generate_tune_sweep_report()`**

Append to `lib/report-helpers.sh`. Use the same heredoc-Python pattern as `generate_scale_test_comparison_report()`. The function signature is:

```bash
generate_tune_sweep_report() {
  local cfg_root="$1"      # results/.../qd-sweep/<pool>
  local pool="$2"
  local baseline="$3"
  local headline_qd="$4"
  local out_html="$5"

  log_info "Generating tune-sweep report: ${out_html}"

  CFG_ROOT="${cfg_root}" POOL="${pool}" BASELINE="${baseline}" \
   HEADLINE_QD="${headline_qd}" \
   CLUSTER_DESC="${CLUSTER_DESCRIPTION:-}" \
   python3 << 'PYEOF_TUNE_REPORT' > "${out_html}"
import csv, json, os, glob, datetime
cfg_root  = os.environ['CFG_ROOT']
pool      = os.environ['POOL']
baseline  = os.environ['BASELINE']
headline_qd = int(os.environ['HEADLINE_QD'])
cluster_desc = os.environ.get('CLUSTER_DESC', '')

# Auto-discover configs under cfg_root
configs = []
for d in sorted(os.listdir(cfg_root)):
    cdir = os.path.join(cfg_root, d)
    csv_path = os.path.join(cdir, 'qd.csv')
    sum_path = os.path.join(cdir, 'qd-summary.json')
    if not (os.path.isfile(csv_path) and os.path.isfile(sum_path)):
        continue
    rows = []
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            try:
                rows.append({
                    'qd': int(row['qd']),
                    'iops_r': float(row['total_read_iops']),
                    'iops_w': float(row['total_write_iops']),
                    'bw':    float(row['total_bw_mbs']),
                    'p99_r': float(row['max_p99_read_ms']),
                    'p99_w': float(row['max_p99_write_ms']),
                    'sla_pass': row['sla_pass'] == 'true',
                })
            except ValueError:
                continue
    summary = json.load(open(sum_path))
    configs.append({'name': d, 'rows': rows, 'summary': summary})

# Resolve baseline
baseline_cfg = next((c for c in configs if c['name'] == baseline), configs[0] if configs else None)
baseline_peak = baseline_cfg['summary'].get('peak_total_iops', 0) if baseline_cfg else 0

# Comparability check
slas    = {c['summary'].get('latency_sla_ms', 0) for c in configs}
rates   = {c['summary'].get('rate_iops_per_vm', 0) for c in configs}
nvms    = {c['summary'].get('vm_count', 0) for c in configs}
qdsets  = {tuple(c['summary'].get('qd_list', [])) for c in configs}
mismatch = (len(slas) > 1 or len(rates) > 1 or len(nvms) > 1 or len(qdsets) > 1)

# Carbon-ish palette, deterministic by config order
palette = ['#0f62fe', '#007d79', '#6929c4', '#1192e8', '#fa4d56', '#161616']

# QD-axis chart datasets
datasets = []
for i, c in enumerate(configs):
    color = palette[i % len(palette)]
    iops = [{'x': r['qd'], 'y': r['iops_r'] + r['iops_w']} for r in c['rows']]
    p99w = [{'x': r['qd'], 'y': r['p99_w']} for r in c['rows']]
    pt_colors = ['#198038' if r['sla_pass'] else '#da1e28' for r in c['rows']]
    datasets.append({
        'label': f"{c['name']} — Total IOPS",
        'data': iops, 'borderColor': color, 'backgroundColor': color + '20',
        'yAxisID': 'y-iops', 'tension': 0.2,
        'pointBackgroundColor': pt_colors, 'pointBorderColor': color,
        'pointRadius': 5, 'borderWidth': 2.5,
    })
    datasets.append({
        'label': f"{c['name']} — Write p99 (ms)",
        'data': p99w, 'borderColor': color, 'borderDash': [6, 4],
        'yAxisID': 'y-lat', 'tension': 0.2,
        'pointBackgroundColor': pt_colors, 'pointBorderColor': color,
        'pointRadius': 5, 'borderWidth': 2,
    })

sla_value = list(slas)[0] if len(slas) == 1 else None
sla_annot = ''
if sla_value is not None:
    sla_annot = (f"slaLine:{{type:'line',yMin:{sla_value},yMax:{sla_value},"
                 f"yScaleID:'y-lat',borderColor:'#da1e28',borderWidth:2,"
                 f"borderDash:[10,5],label:{{content:'SLA: {sla_value}ms',"
                 f"display:true,position:'start'}}}}")

# Headline-QD bar charts (4 metrics × N configs)
def row_at(c, qd):
    return next((r for r in c['rows'] if r['qd'] == qd), None)
labels = [c['name'] for c in configs]
def bar_dataset(metric, color_arr):
    data = []
    for c in configs:
        r = row_at(c, headline_qd)
        if not r:
            data.append(None); continue
        if metric == 'iops':  data.append(r['iops_r'] + r['iops_w'])
        elif metric == 'bw':  data.append(r['bw'])
        elif metric == 'p99_r': data.append(r['p99_r'])
        elif metric == 'p99_w': data.append(r['p99_w'])
    return {'data': data, 'backgroundColor': color_arr, 'borderColor': color_arr, 'borderWidth': 1}
colors = [palette[i % len(palette)] for i in range(len(configs))]

# Scorecard
def fmt_int(n): return f"{int(n):,}"
def fmt_pct(x): return f"{x:+.1f}%" if x is not None else "—"
scorecard_rows = []
for c in configs:
    s = c['summary']
    peak = s.get('peak_total_iops', 0)
    delta = (peak - baseline_peak) / baseline_peak * 100 if baseline_peak else None
    delta_cell = '<span class="muted">—</span>' if c['name'] == baseline_cfg['name'] else fmt_pct(delta)
    row_h = row_at(c, headline_qd)
    sla_hdq = 'PASS' if (row_h and row_h['sla_pass']) else 'FAIL'
    sla_class = 'pass' if sla_hdq == 'PASS' else 'fail'
    res_ceiling = 'yes' if s.get('resource_ceiling') else 'no'
    cstate_yaml = ''
    try:
        ta_path = os.path.join(cfg_root, c['name'], 'tuning-applied.yaml')
        cstate_yaml = open(ta_path).read()
    except Exception:
        pass
    osd_summary = 'inherit'
    for line in cstate_yaml.splitlines():
        if line.startswith('realised_osd_resources:'):
            osd_summary = line.split(': ', 1)[1].strip().strip('"')
    scorecard_rows.append(
        f"<tr><td><b>{c['name']}</b></td>"
        f"<td>{fmt_int(peak)}</td><td>{delta_cell}</td>"
        f"<td>{s.get('p99_read_at_peak_qd_ms', 0):.2f}</td>"
        f"<td>{s.get('p99_write_at_peak_qd_ms', 0):.2f}</td>"
        f"<td class='{sla_class}'>{sla_hdq}</td>"
        f"<td>{res_ceiling}</td>"
        f"<td><code>{osd_summary[:60]}</code></td></tr>"
    )

# Per-config detail tables
detail_blocks = []
for c in configs:
    rows_html = []
    for r in c['rows']:
        sla_cls = 'pass' if r['sla_pass'] else 'fail'
        rows_html.append(
            f"<tr><td>{r['qd']}</td>"
            f"<td>{int(r['iops_r']):,}</td><td>{int(r['iops_w']):,}</td>"
            f"<td>{r['bw']:,.1f}</td>"
            f"<td>{r['p99_r']:.3f}</td><td>{r['p99_w']:.3f}</td>"
            f"<td class='{sla_cls}'>{'PASS' if r['sla_pass'] else 'FAIL'}</td></tr>"
        )
    detail_blocks.append(
        f"<details><summary><b>{c['name']}</b></summary>"
        f"<table><tr><th>QD</th><th>Read IOPS</th><th>Write IOPS</th><th>BW MB/s</th>"
        f"<th>p99 R (ms)</th><th>p99 W (ms)</th><th>SLA</th></tr>"
        + ''.join(rows_html) + "</table></details>"
    )

banner_class = 'warn' if mismatch else 'ok'
banner_text = ('Workload params differ across configs — comparison is approximate.'
               if mismatch else
               f'All configs tested at {list(rates)[0]} IOPS/VM × {list(nvms)[0]} VMs '
               f'× SLA={sla_value}ms. Apples-to-apples.')

generated_at = datetime.datetime.utcnow().isoformat(timespec='seconds')

print(f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>ODF Tune Sweep: {pool}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation@3"></script>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; background: #f4f4f4; color: #161616; }}
  h1 {{ margin-bottom: 4px; }}
  .meta {{ color: #525252; font-size: 0.9em; margin-bottom: 20px; }}
  .banner {{ padding: 14px 18px; margin: 18px 0; border-radius: 4px; }}
  .banner.ok {{ background: #defbe6; border-left: 4px solid #198038; }}
  .banner.warn {{ background: #fff8e1; border-left: 4px solid #f1c21b; }}
  .chart-container {{ background: white; padding: 20px; border-radius: 8px; margin: 20px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
  .bar-row {{ display: grid; grid-template-columns: 1fr 1fr 1fr 1fr; gap: 16px; }}
  table {{ width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-top: 8px; }}
  th {{ background: #161616; color: white; padding: 10px 12px; text-align: right; font-size: 0.85em; }}
  th:first-child, th:nth-child(2) {{ text-align: left; }}
  td {{ padding: 8px 12px; text-align: right; border-bottom: 1px solid #e0e0e0; font-size: 0.9em; }}
  td:first-child, td:nth-child(8) {{ text-align: left; }}
  .pass {{ color: #198038; font-weight: 600; }}
  .fail {{ color: #da1e28; font-weight: 600; }}
  .muted {{ color: #8d8d8d; }}
  details {{ background: white; padding: 12px 16px; border-radius: 8px; margin: 10px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }}
  details summary {{ cursor: pointer; padding: 4px 0; }}
  code {{ background: #f4f4f4; padding: 1px 5px; border-radius: 3px; font-size: 0.9em; }}
</style>
</head>
<body>
<h1>ODF Tune Sweep: {pool}</h1>
<div class="meta">
  <b>Cluster:</b> {cluster_desc or 'n/a'}<br>
  <b>Baseline:</b> {baseline_cfg['name']}<br>
  <b>Headline QD:</b> {headline_qd}<br>
  <b>Generated:</b> {generated_at}
</div>

<div class="banner {banner_class}">{banner_text}</div>

<h2>Capacity scorecard</h2>
<table>
<tr>
  <th>Config</th><th>Peak IOPS</th><th>Δ vs baseline</th>
  <th>p99 R @ peak (ms)</th><th>p99 W @ peak (ms)</th>
  <th>SLA @ QD={headline_qd}</th><th>Resource ceiling</th><th>Tuning</th>
</tr>
{''.join(scorecard_rows)}
</table>

<h2>Headline @ QD={headline_qd}</h2>
<div class="bar-row">
  <div class="chart-container"><canvas id="headlineIops"></canvas></div>
  <div class="chart-container"><canvas id="headlineBw"></canvas></div>
  <div class="chart-container"><canvas id="headlineP99R"></canvas></div>
  <div class="chart-container"><canvas id="headlineP99W"></canvas></div>
</div>

<h2>QD-axis behaviour</h2>
<div class="chart-container">
  <canvas id="qdChart" height="100"></canvas>
</div>

<h2>Per-config data</h2>
{''.join(detail_blocks)}

<script>
const ctx = document.getElementById('qdChart').getContext('2d');
new Chart(ctx, {{
  type: 'line',
  data: {{ datasets: {json.dumps(datasets)} }},
  options: {{
    responsive: true, parsing: false,
    interaction: {{ mode: 'nearest', intersect: false }},
    scales: {{
      x: {{ type: 'linear', title: {{ display: true, text: 'Queue depth' }} }},
      'y-iops': {{ type: 'linear', position: 'left', title: {{ display: true, text: 'Aggregate IOPS' }}, beginAtZero: true }},
      'y-lat':  {{ type: 'linear', position: 'right', title: {{ display: true, text: 'Write p99 (ms)' }}, beginAtZero: true, grid: {{ drawOnChartArea: false }} }}
    }},
    plugins: {{ legend: {{ position: 'top' }},
      annotation: {{ annotations: {{ {sla_annot} }} }} }}
  }}
}});

const labels = {json.dumps(labels)};
const colors = {json.dumps(colors)};
const bar = (id, data, label, lowerBetter) => new Chart(document.getElementById(id), {{
  type: 'bar',
  data: {{ labels, datasets: [{{ label, data, backgroundColor: colors, borderColor: colors, borderWidth: 1 }}] }},
  options: {{ plugins: {{ legend: {{ display: false }}, title: {{ display: true, text: label + (lowerBetter ? ' (lower is better)' : ' (higher is better)') }} }}, scales: {{ y: {{ beginAtZero: true }} }} }}
}});

bar('headlineIops',  {json.dumps(bar_dataset('iops', colors)['data'])}, 'IOPS @ QD={headline_qd}', false);
bar('headlineBw',    {json.dumps(bar_dataset('bw', colors)['data'])},   'Throughput MB/s @ QD={headline_qd}', false);
bar('headlineP99R',  {json.dumps(bar_dataset('p99_r', colors)['data'])},'Read p99 ms @ QD={headline_qd}', true);
bar('headlineP99W',  {json.dumps(bar_dataset('p99_w', colors)['data'])},'Write p99 ms @ QD={headline_qd}', true);
</script>
</body>
</html>""")
PYEOF_TUNE_REPORT

  log_info "Tune-sweep report generated: ${out_html}"
}
```

- [ ] **Step 11.4: Run report test, expect pass**

Run: `./tests/run-offline.sh`
Expected: `test_tune_sweep_report_html` PASSES.

- [ ] **Step 11.5: Visually verify the generated HTML**

```bash
out=$(mktemp -t tune-vis-XXXXXX.html)
source 00-config.sh >/dev/null 2>&1
source lib/report-helpers.sh
generate_tune_sweep_report \
  tests/fixtures/tune-sweep-3cfg/qd-sweep/rep3-virt \
  rep3-virt default 64 "${out}"
open "${out}"
```
Confirm: 4 bar charts visible at top, QD-line chart shows `default` curve bending hard, `big-osd` flat. Per-config details collapse open.

- [ ] **Step 11.6: Commit**

```bash
git add lib/report-helpers.sh tests/run-offline.sh
git commit -m "feat(report): add generate_tune_sweep_report() for tune-sweep HTML"
```

---

## Task 12: `06-generate-report.sh --compare-tuning` handler

**Files:**
- Modify: `06-generate-report.sh`
- Test: `tests/run-offline.sh::test_compare_tuning_cli`

- [ ] **Step 12.1: Add the failing test**

Append to `tests/run-offline.sh`:

```bash
# -----------------------------------------------------------------------------
test_compare_tuning_cli() {
  echo "test_compare_tuning_cli:"
  # Build a fake results tree under a tmpdir pointing at the fixture.
  local tmp
  tmp=$(mktemp -d -t tune-compare-XXXXXX)
  trap "rm -rf '${tmp}'" RETURN
  mkdir -p "${tmp}/results/tune-fixture"
  ln -s "$(pwd)/tests/fixtures/tune-sweep-3cfg/qd-sweep" "${tmp}/results/tune-fixture/qd-sweep"
  mkdir -p "${tmp}/reports"

  if ! OC_SKIP_CLUSTER_CHECK=true \
       RESULTS_DIR="${tmp}/results" REPORTS_DIR="${tmp}/reports" \
       ./06-generate-report.sh --compare-tuning \
       --run tune-fixture --pool rep3-virt 2>&1 \
       | tee /tmp/tune-cli.log; then
    _fail "06 --compare-tuning exited non-zero"
    return
  fi

  ls "${tmp}/reports"/tune-sweep-rep3-virt-*.html >/dev/null 2>&1 \
    || { _fail "no tune-sweep HTML produced"; return; }
  _pass "06 --compare-tuning produces a report"
}
```

Add to invocation list.

- [ ] **Step 12.2: Run, expect failure**

Run: `./tests/run-offline.sh`
Expected: `06 --compare-tuning` is not recognised.

- [ ] **Step 12.3: Add flag parsing and handler**

In `06-generate-report.sh`, near the existing `--compare-scale` block, add:

```bash
COMPARE_TUNING_MODE=false
COMPARE_TUNING_RUN=""
COMPARE_TUNING_POOL=""
COMPARE_TUNING_BASELINE=""
COMPARE_TUNING_HEADLINE_QD=""
COMPARE_TUNING_OUTPUT=""
```

In the argument parser:

```bash
    --compare-tuning) COMPARE_TUNING_MODE=true; shift ;;
    --run)            COMPARE_TUNING_RUN="$2"; shift 2 ;;
    --pool)           COMPARE_TUNING_POOL="$2"; shift 2 ;;
    --baseline)       COMPARE_TUNING_BASELINE="$2"; shift 2 ;;
    --headline-qd)    COMPARE_TUNING_HEADLINE_QD="$2"; shift 2 ;;
```

Update `--help` text.

In `main()`, after the `--compare-scale` block, add:

```bash
if [[ "${COMPARE_TUNING_MODE}" == true ]]; then
  log_info "=== Generating Tune-Sweep Report ==="

  [[ -z "${COMPARE_TUNING_RUN}" ]]  && { log_error "--compare-tuning requires --run <run-id>"; exit 1; }
  [[ -z "${COMPARE_TUNING_POOL}" ]] && { log_error "--compare-tuning requires --pool <name>"; exit 1; }

  local cfg_root="${RESULTS_DIR}/${COMPARE_TUNING_RUN}/qd-sweep/${COMPARE_TUNING_POOL}"
  [[ -d "${cfg_root}" ]] || { log_error "no qd-sweep results at ${cfg_root}"; exit 1; }

  # Resolve baseline
  local baseline="${COMPARE_TUNING_BASELINE}"
  if [[ -z "${baseline}" ]]; then
    if [[ -d "${cfg_root}/default" ]]; then
      baseline="default"
    else
      baseline=$(ls -1 "${cfg_root}" | head -1)
    fi
  fi

  # Resolve headline QD
  local headline_qd="${COMPARE_TUNING_HEADLINE_QD}"
  if [[ -z "${headline_qd}" ]]; then
    headline_qd=$(awk -F',' 'NR>1{print $2}' \
      "${cfg_root}/${baseline}/qd.csv" | sort -n | tail -1)
  fi

  local output="${COMPARE_TUNING_OUTPUT}"
  [[ -z "${output}" ]] && output="${REPORTS_DIR}/tune-sweep-${COMPARE_TUNING_POOL}-${COMPARE_TUNING_RUN}.html"
  mkdir -p "$(dirname "${output}")"

  generate_tune_sweep_report "${cfg_root}" "${COMPARE_TUNING_POOL}" \
    "${baseline}" "${headline_qd}" "${output}"

  log_info "Tune-sweep report: ${output}"
  return 0
fi
```

- [ ] **Step 12.4: Run, expect pass**

Run: `./tests/run-offline.sh`
Expected: `test_compare_tuning_cli` PASSES.

- [ ] **Step 12.5: Commit**

```bash
git add 06-generate-report.sh tests/run-offline.sh
git commit -m "feat(report): add --compare-tuning handler to 06-generate-report.sh"
```

---

## Task 13: End-to-end smoke test — mini sweep

**Files:**
- Create: `tests/smoke/mini-sweep.sh`

- [ ] **Step 13.1: Create the mini-sweep script**

```bash
#!/usr/bin/env bash
# tests/smoke/mini-sweep.sh — end-to-end tune-sweep against a real cluster.
# Two configs × two QDs × 4 VMs. ~30 min on a working cluster. Restore is
# automatic via the orchestrator's EXIT trap.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

POOL="${MINI_SWEEP_POOL:-rep3-virt}"

./09-run-tune-sweep.sh \
  --pool "${POOL}" \
  --configs default,big-osd \
  --fixed-vms 4 \
  --qd-list 1,32 \
  --rate-iops 250 \
  --latency-sla 5 \
  --auto

# Validate outputs exist
latest=$(ls -1dt results/tune-* | head -1)
echo "Latest run: ${latest}"

for cfg in default big-osd; do
  for f in qd.csv qd-summary.json tuning-applied.yaml; do
    [[ -s "${latest}/qd-sweep/${POOL}/${cfg}/${f}" ]] || { echo "FAIL: missing ${cfg}/${f}"; exit 1; }
  done
done

ls reports/tune-sweep-${POOL}-*.html >/dev/null \
  || { echo "FAIL: no report HTML"; exit 1; }

echo "PASS: mini-sweep end-to-end"
```

Make executable.

- [ ] **Step 13.2: Run the mini-sweep**

Run: `./tests/smoke/mini-sweep.sh`
Expected: ~30 min. Final line `PASS: mini-sweep end-to-end`. Inspect the generated HTML.

- [ ] **Step 13.3: Verify cluster state was restored**

Run:
```bash
oc get storagecluster -n openshift-storage -o jsonpath='{.items[0].spec.resourceProfile}'
oc get machineconfig | grep "${TUNE_MC_NAME}" || echo "(no leftover MC)"
```
Expected: profile matches the pre-sweep state; no `99-perf-test-cstate-off` MC present.

- [ ] **Step 13.4: Commit the smoke script**

```bash
git add tests/smoke/mini-sweep.sh
git commit -m "test(tune): add end-to-end mini-sweep smoke script"
```

---

## Task 14: Documentation — CLAUDE.md and `--help` polish

**Files:**
- Modify: `CLAUDE.md`
- Modify: `09-run-tune-sweep.sh` (`--help` accuracy)
- Modify: `04-run-tests.sh` (`--help` accuracy)

- [ ] **Step 14.1: Update `CLAUDE.md` Key Commands**

In the `## Key Commands` block, append after the scale-test examples:

```bash
# Tune sweep (OSD resource overrides + cstate × QD-sweep, multi-config report):
./09-run-tune-sweep.sh --pool rep3-virt \
   --configs default,big-osd --fixed-vms 200 --qd-list 1,2,4,8,16,32,64
./09-run-tune-sweep.sh --pool rep3-virt --dry-run     # preview plan
./09-run-tune-sweep.sh --restore-from <run-id>        # rerun restore only
./09-run-tune-sweep.sh --pool rep3-virt --resume <run-id>

# Standalone QD sweep (no cluster mutation; characterise pool at fixed N):
./04-run-tests.sh --qd-sweep --pool rep3-virt \
   --fixed-vms 200 --qd-list 1,2,4,8,16,32,64

# Multi-config tune-sweep report:
./06-generate-report.sh --compare-tuning --run <run-id> --pool rep3-virt
```

- [ ] **Step 14.2: Add an Architecture-section subsection in `CLAUDE.md`**

Append a new subsection `### Tune Sweep Auto-Orchestration` after the existing `### Scale Test Auto-Ramp` subsection. Summarise:

- Three new files: `lib/tune-helpers.sh`, `09-run-tune-sweep.sh`, `04-run-tests.sh --qd-sweep` mode
- Variants defined in `TUNE_CONFIGS` array in `00-config.sh`
- Snapshot-and-restore safety semantics
- Results layout under `results/<run>/qd-sweep/<pool>/<cfg>/`
- The companion `--compare-tuning` report mode in `06-generate-report.sh`

Keep it to ~10-15 lines, matching the prose style of the existing subsection.

- [ ] **Step 14.3: Verify `--help` output**

Run:
```bash
./09-run-tune-sweep.sh --help
./04-run-tests.sh --help
./06-generate-report.sh --help
```
Confirm all three list the new flags accurately.

- [ ] **Step 14.4: Commit**

```bash
git add CLAUDE.md 09-run-tune-sweep.sh 04-run-tests.sh 06-generate-report.sh
git commit -m "docs(tune): document tune-sweep in CLAUDE.md and polish --help text"
```

---

## Task 15: Run the full real-world sweep + final manual verification

**Files:**
- (No code changes — this is the verification gate per CLAUDE.md "evidence before assertions")

- [ ] **Step 15.1: Run the full 4-config sweep**

```bash
./09-run-tune-sweep.sh --pool rep3-virt \
  --configs default,cstate-off,big-osd,big-osd+cstate-off \
  --fixed-vms 200 \
  --qd-list 1,2,4,8,16,32,64 \
  --rate-iops 500 \
  --latency-sla 5
```
Expected runtime ≈ 3-4 h on a 3-worker BM cluster. The orchestrator restores cluster state at the end.

- [ ] **Step 15.2: Open the generated report**

```bash
open reports/tune-sweep-rep3-virt-tune-*.html
```
Verify visually:
- QD-axis chart shows `default` bending hard at QD=8+ (write p99 > SLA); `big-osd` flat across the whole range.
- Headline-QD bar charts show `big-osd` ~2× the IOPS of `default` with sub-2 ms write p99.
- Scorecard "Δ vs baseline" column shows positive percentages for all non-default configs.

- [ ] **Step 15.3: Verify cluster restored**

```bash
oc get storagecluster -n openshift-storage \
  -o jsonpath='{.items[0].spec.resourceProfile}{"\n"}'
oc get storagecluster -n openshift-storage \
  -o json | jq '.items[0].spec.resources.osd // "inherit"'
oc get machineconfig | grep perf-test-cstate || echo "(no leftover MC) ✓"
```
All three must match the cluster state before the sweep started (compare against `results/tune-<run-id>/cluster-snapshot.yaml`).

- [ ] **Step 15.4: Final off-cluster test sweep**

```bash
./tests/run-offline.sh
```
Expected: all tests PASS, exit 0.

- [ ] **Step 15.5: Commit a real-data docs/examples entry (optional)**

If the sweep produced publishable numbers, add a short summary alongside the existing `docs/examples/odf-replication-scale-comparison.md`:

```bash
git add docs/examples/odf-tune-sweep-rep3-virt.md  # if you wrote one
git commit -m "docs(perf): record first full tune-sweep on rep3-virt"
```

---

## Final review checklist

Before opening a PR / merging:

- [ ] All off-cluster tests pass: `./tests/run-offline.sh` exit 0.
- [ ] All smoke tests pass against a real cluster: `./tests/smoke/run-smoke.sh` exit 0.
- [ ] End-to-end mini sweep passed: `./tests/smoke/mini-sweep.sh` exit 0.
- [ ] Full 4-config sweep produced a valid report (Task 15).
- [ ] Cluster state restored after every test (Task 15.3).
- [ ] `CLAUDE.md` documents the new commands and architecture subsection.
- [ ] `--help` text on `04`, `06`, `09` lists the new flags.
- [ ] No leftover `tests/.*.lock`, `/tmp/tune-*` files.
- [ ] Git log shows ~15 cleanly-scoped commits, one per task.
