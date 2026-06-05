# ODF/Ceph Tuning Follow-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `lib/tune-helpers.sh` with a `cephconfig_*` key family, add a `big-osd+mclock` tune config, and run a 2×2 factorial sweep (VM-template {baseline, iothreads} × Ceph {big-osd, big-osd+mclock}) to measure each knob's delta over the existing big-osd baseline, the interaction term, and the combined stack.

**Architecture:** The tune-sweep mechanism already snapshots + restores cluster state on every exit path via an EXIT trap. We add one more mutation step in `apply_tuning_config` that patches `StorageCluster.spec.managedResources.cephCluster.cephConfig.osd` (a live Ceph config-database field that does not require an OSD pod roll), with symmetric snapshot/restore. The VM-template change is a single additive edit to `vm-templates/vm-template.yaml`, committed on a branch and merge-gated on results.

**Tech Stack:** bash 5.x, `oc` CLI, `jq`, OCS-operator 4.20.7 (ODF), Rook 1.16, Ceph Reef 18.x, KubeVirt VM CRDs, fio 3.x.

**Spec:** [`docs/superpowers/specs/2026-06-05-odf-ceph-tuning-followup-design.md`](../specs/2026-06-05-odf-ceph-tuning-followup-design.md)

---

## File structure

| File | Change | Responsibility |
|---|---|---|
| `lib/tune-helpers.sh` | Modify | Add `cephconfig_*` prefix validation in `parse_tune_config`; add `cephconfig` field to `snapshot_cluster_state`; new `wait_for_ceph_config_applied` helper; new cephConfig mutation step in `apply_tuning_config`; new cephConfig restore branch in `restore_cluster_state` |
| `00-config.sh` | Modify | Add `TUNE_CONFIGS[big-osd+mclock]` entry |
| `tests/run-offline.sh` | Modify | Add three offline tests covering `cephconfig_*` parsing |
| `tests/smoke/snapshot.sh` | Modify | Assert snapshot YAML contains `cephconfig:` field |
| `tests/smoke/cephconfig-roundtrip.sh` | Create | New smoke test: apply a `cephconfig_*`-bearing config to cluster, read back `ceph config dump`, restore, re-read |
| `vm-templates/vm-template.yaml` | Modify (on branch) | Add `ioThreadsPolicy: auto` + `blockMultiQueue: true` |
| `docs/examples/odf-ceph-tuning-followup-2026-06-05.md` | Create | Companion writeup with 4-cell results, deltas, interaction term, merge decision |

The Memory note refresh (Task 15) is a `.md` write under `~/.claude/projects/.../memory/`, not in the repo.

---

## Phase 1 — Suite extension (Tasks 1–7)

Each task is TDD red → green → refactor → commit. Tasks 1, 2, 6 are exercised by offline tests; Tasks 3, 4, 5 are validated by the cluster smoke (Task 7).

---

### Task 1: `cephconfig_*` prefix validation in `parse_tune_config`

**Files:**
- Modify: `lib/tune-helpers.sh:20-71` (the `parse_tune_config` function)
- Modify: `tests/run-offline.sh` (add three test functions)

- [ ] **Step 1: Write the three failing tests in `tests/run-offline.sh`**

Add these test functions in `tests/run-offline.sh` just before the existing `test_parse_tune_config_unknown_name` function (around line 75), and add their names to the runner block at the bottom of the file:

```bash
test_parse_tune_config_cephconfig() {
  echo "test_parse_tune_config_cephconfig:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh

  TUNE_CONFIGS[__test_ceph_mixed]='osd_cpu=6 cephconfig_osd_mclock_profile=high_client_ops cstate=on'
  local out
  if ! out=$(parse_tune_config "__test_ceph_mixed" 2>&1); then
    _fail "parse_tune_config __test_ceph_mixed returned non-zero: ${out}"
    unset 'TUNE_CONFIGS[__test_ceph_mixed]'
    return
  fi
  unset 'TUNE_CONFIGS[__test_ceph_mixed]'
  echo "${out}" | grep -qx 'osd_cpu=6' || { _fail "missing osd_cpu=6 in output"; return; }
  echo "${out}" | grep -qx 'cephconfig_osd_mclock_profile=high_client_ops' || \
    { _fail "missing cephconfig_osd_mclock_profile=high_client_ops in output"; return; }
  echo "${out}" | grep -qx 'cstate=on' || { _fail "missing cstate=on in output"; return; }
  _pass "cephconfig_* keys parse alongside explicit keys"
}

test_parse_tune_config_cephconfig_empty_value() {
  echo "test_parse_tune_config_cephconfig_empty_value:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh

  TUNE_CONFIGS[__test_ceph_empty]='cephconfig_foo= cstate=on'
  if parse_tune_config "__test_ceph_empty" >/dev/null 2>&1; then
    _fail "expected non-zero exit on empty cephconfig_* value"
    unset 'TUNE_CONFIGS[__test_ceph_empty]'
    return
  fi
  unset 'TUNE_CONFIGS[__test_ceph_empty]'
  _pass "empty cephconfig_* values rejected"
}

test_parse_tune_config_bigosd_mclock() {
  echo "test_parse_tune_config_bigosd_mclock:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh

  [[ -v 'TUNE_CONFIGS[big-osd+mclock]' ]] || { _fail "TUNE_CONFIGS[big-osd+mclock] not declared"; return; }
  local out
  if ! out=$(parse_tune_config 'big-osd+mclock' 2>&1); then
    _fail "parse_tune_config big-osd+mclock returned non-zero: ${out}"
    return
  fi
  echo "${out}" | grep -qx 'osd_cpu=6' || { _fail "missing osd_cpu=6"; return; }
  echo "${out}" | grep -qx 'osd_mem=24Gi' || { _fail "missing osd_mem=24Gi"; return; }
  echo "${out}" | grep -qx 'cephconfig_osd_mclock_profile=high_client_ops' || \
    { _fail "missing cephconfig_osd_mclock_profile=high_client_ops"; return; }
  echo "${out}" | grep -qx 'cephconfig_bluestore_throttle_bytes=262144' || \
    { _fail "missing cephconfig_bluestore_throttle_bytes=262144"; return; }
  echo "${out}" | grep -qx 'cephconfig_bluestore_throttle_deferred_bytes=262144' || \
    { _fail "missing cephconfig_bluestore_throttle_deferred_bytes=262144"; return; }
  echo "${out}" | grep -qx 'cstate=on' || { _fail "missing cstate=on"; return; }
  _pass "big-osd+mclock parses with all expected keys"
}
```

And add these three names to the runner list at the bottom of the file (after `test_parse_tune_config_unknown_key` and before `test_render_cstate_machineconfig`):

```bash
test_parse_tune_config_cephconfig
test_parse_tune_config_cephconfig_empty_value
test_parse_tune_config_bigosd_mclock
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `OC_SKIP_CLUSTER_CHECK=true bash tests/run-offline.sh 2>&1 | tail -30`

Expected: First two new tests FAIL at `parse_tune_config` (rejecting `cephconfig_*` as unknown key). Third FAILs because `TUNE_CONFIGS[big-osd+mclock]` is not yet declared (Task 6).

- [ ] **Step 3: Modify `parse_tune_config` in `lib/tune-helpers.sh` to accept `cephconfig_*` prefix and enforce non-empty value**

In `lib/tune-helpers.sh`, replace the block at lines 41–52 (the key-validation block inside the `for kv in ${raw}` loop) with:

```bash
    local valid=0
    local v
    for v in "${TUNE_VALID_KEYS[@]}"; do
      [[ "${v}" == "${key}" ]] && valid=1 && break
    done
    # cephconfig_* keys map directly to ceph config-database keys under the
    # 'osd' section. They are validated by prefix, not membership, so the
    # tune system does not need to know every valid ceph key. They must have
    # a non-empty value (an empty cephconfig_foo= is almost certainly a typo).
    if [[ "${key}" == cephconfig_* ]]; then
      if [[ -z "${value}" ]]; then
        echo "ERROR: cephconfig_* key '${key}' requires a non-empty value in TUNE_CONFIGS[${name}]" >&2
        return 1
      fi
      valid=1
    fi
    if (( valid == 0 )); then
      {
        echo "ERROR: unknown key '${key}' in TUNE_CONFIGS[${name}]"
        echo "Valid keys: ${TUNE_VALID_KEYS[*]} (or cephconfig_* prefix)"
      } >&2
      return 1
    fi
```

- [ ] **Step 4: Re-run tests, verify first two pass; third still fails (expected — config not declared yet)**

Run: `OC_SKIP_CLUSTER_CHECK=true bash tests/run-offline.sh 2>&1 | grep -E "cephconfig|big-osd\+mclock|FAIL|PASS"`

Expected:
- `PASS  cephconfig_* keys parse alongside explicit keys`
- `PASS  empty cephconfig_* values rejected`
- `FAIL  big-osd+mclock` (still — Task 6 adds it)

- [ ] **Step 5: Commit**

```bash
git add lib/tune-helpers.sh tests/run-offline.sh
git commit -m "feat(tune): accept cephconfig_* prefix keys in parse_tune_config

cephconfig_<key>=<value> entries in TUNE_CONFIGS map directly to ceph
config-database keys under the 'osd' section. Validated by prefix (not
membership) so the tune system does not need to know every valid ceph
key. Empty values rejected to catch typos."
```

---

### Task 2: `cephconfig` field in `snapshot_cluster_state`

**Files:**
- Modify: `lib/tune-helpers.sh:113-165` (the `snapshot_cluster_state` function)
- Modify: `tests/smoke/snapshot.sh` (one new assertion)

- [ ] **Step 1: Add a failing assertion in `tests/smoke/snapshot.sh`**

Append after the existing `grep -q "^mcp_worker_updated:"` check (before the `echo "snapshot contents:"` line):

```bash
grep -q "^cephconfig:" "${tmp}" || { echo "missing cephconfig"; exit 1; }
```

- [ ] **Step 2: Run the smoke (requires `oc` auth), verify the new assertion fails**

Run: `bash tests/smoke/snapshot.sh`

Expected: `missing cephconfig` and exit code 1.

- [ ] **Step 3: Modify `snapshot_cluster_state` in `lib/tune-helpers.sh`**

Insert this block after the existing `ds_resources` capture (after line ~141, just before the `local mc_present="false"` line):

```bash
  # Capture .spec.managedResources.cephCluster.cephConfig — the live-config
  # path used by cephconfig_* tune keys. Format matches deviceset_resources:
  # 'inherit' when the field is empty/missing, otherwise a compact jq -c JSON
  # blob that round-trips cleanly through `oc patch --type merge`.
  local cephconfig
  cephconfig=$(oc get storagecluster "${sc_name}" -n "${ns}" \
    -o jsonpath='{.spec.managedResources.cephCluster.cephConfig}' 2>/dev/null)
  if [[ -z "${cephconfig}" || "${cephconfig}" == "{}" ]]; then
    cephconfig="inherit"
  else
    cephconfig=$(oc get storagecluster "${sc_name}" -n "${ns}" \
      -o json | jq -c '.spec.managedResources.cephCluster.cephConfig // "inherit"')
  fi
```

Then add one line inside the `cat > "${out}" <<EOF` heredoc, after `deviceset_resources: ${ds_resources}`:

```
cephconfig: ${cephconfig}
```

- [ ] **Step 4: Re-run smoke, verify pass**

Run: `bash tests/smoke/snapshot.sh`

Expected: prints snapshot contents (including a `cephconfig: inherit` line on a clean OOB cluster) and exits 0.

- [ ] **Step 5: Commit**

```bash
git add lib/tune-helpers.sh tests/smoke/snapshot.sh
git commit -m "feat(tune): capture cephConfig in snapshot_cluster_state

Adds .spec.managedResources.cephCluster.cephConfig to the snapshot YAML
(format: 'inherit' or compact jq JSON). Required for snapshot/restore
round-trip of cephconfig_* tune keys."
```

---

### Task 3: `wait_for_ceph_config_applied` helper

**Files:**
- Modify: `lib/tune-helpers.sh` (add new function after `wait_for_mcp_updated`, around line 305)

No offline test — the helper requires a live Ceph cluster. It is exercised end-to-end by the smoke test in Task 7.

- [ ] **Step 1: Add the helper function**

Insert into `lib/tune-helpers.sh` just before the `apply_tuning_config` function (around line 306):

```bash
# ---------------------------------------------------------------------------
# wait_for_ceph_config_applied <key> <expected-value> [timeout-secs]
#   Polls `ceph config dump --format json` until an entry with
#   section='osd' and name='<key>' has value='<expected-value>'. Used after
#   patching .spec.managedResources.cephCluster.cephConfig.osd.<key> to
#   confirm the override has propagated to the Ceph config database (no
#   OSD pod roll required for live-config keys).
#   Returns 0 on observed propagation, 1 on timeout.
# ---------------------------------------------------------------------------
wait_for_ceph_config_applied() {
  local key="$1"
  local expected="$2"
  local timeout="${3:-120}"
  local ns="openshift-storage"
  local deadline=$(( $(date +%s) + timeout ))
  local interval=5

  if [[ -z "${key}" || -z "${expected}" ]]; then
    echo "ERROR: wait_for_ceph_config_applied requires <key> <expected-value>" >&2
    return 1
  fi

  log_info "Waiting for ceph config osd:${key}='${expected}' (timeout=${timeout}s)"
  while (( $(date +%s) < deadline )); do
    local actual
    actual=$(oc -n "${ns}" exec deploy/rook-ceph-tools -- \
      ceph config dump --format json 2>/dev/null \
      | jq -r --arg k "${key}" \
          '.[] | select(.section=="osd" and .name==$k) | .value' 2>/dev/null \
      | head -1)
    if [[ "${actual}" == "${expected}" ]]; then
      log_info "  ceph config osd:${key} = ${actual}"
      return 0
    fi
    log_debug "  ceph config osd:${key} actual='${actual:-<unset>}' expected='${expected}'; sleep ${interval}s"
    sleep "${interval}"
  done

  log_error "wait_for_ceph_config_applied: osd:${key} did not reach '${expected}' within ${timeout}s"
  return 1
}
```

- [ ] **Step 2: Sanity-check the function is defined**

Run:
```bash
OC_SKIP_CLUSTER_CHECK=true bash -c '
  source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh
  declare -F wait_for_ceph_config_applied
'
```

Expected: `wait_for_ceph_config_applied`

- [ ] **Step 3: Commit**

```bash
git add lib/tune-helpers.sh
git commit -m "feat(tune): add wait_for_ceph_config_applied helper

Polls 'ceph config dump' until an osd-section key matches the expected
value. Required guard after cephConfig patches — confirms live-config
propagation (no OSD pod roll for these keys, so wait_for_osd_ready does
not gate them)."
```

---

### Task 4: cephConfig mutation step in `apply_tuning_config`

**Files:**
- Modify: `lib/tune-helpers.sh:320-428` (the `apply_tuning_config` function)

The cephConfig mutation step goes between the existing OSD resource override (step 2) and the cstate MachineConfig (step 3). Smoke test in Task 7 validates end-to-end.

- [ ] **Step 1: Insert cephConfig mutation step**

In `lib/tune-helpers.sh`, find the `# --- 3. cstate MachineConfig` comment (around line 387). Insert this block immediately before it:

```bash
  # --- 2b. cephConfig (live, no pod restart) ----------------------------------
  # cephconfig_<key>=<value> pairs are merged into
  # .spec.managedResources.cephCluster.cephConfig.osd. OCS-operator merges
  # this map on top of its derived base ceph config, so the override is
  # additive (other daemon sections, mon/mgr, are not disturbed). Propagation
  # is via the Ceph config database — live, no OSD pod roll.
  local -a cephconfig_keys=()
  local ck
  for ck in "${!cfg[@]}"; do
    [[ "${ck}" == cephconfig_* ]] && cephconfig_keys+=("${ck}")
  done

  if (( ${#cephconfig_keys[@]} > 0 )); then
    # Build the osd-section JSON object: {"<short_key1>":"<val1>",...}.
    # Values are quoted as strings — ceph config accepts string-form for all
    # numeric settings (e.g. throttle bytes, memory targets).
    local osd_json='{'
    local short_key
    for ck in "${cephconfig_keys[@]}"; do
      short_key="${ck#cephconfig_}"
      osd_json+="\"${short_key}\":\"${cfg[$ck]}\","
    done
    osd_json="${osd_json%,}"
    osd_json+='}'

    log_info "Patching managedResources.cephCluster.cephConfig.osd: ${osd_json}"
    oc patch storagecluster "${sc_name}" -n "${ns}" --type merge \
      -p "{\"spec\":{\"managedResources\":{\"cephCluster\":{\"cephConfig\":{\"osd\":${osd_json}}}}}}" >/dev/null \
      || { log_error "cephConfig patch failed"; return 1; }

    # Sentinel verification: if one key propagated, all keys in the same
    # patch did. Picking the first deterministically (sorted) for the check.
    local first_key
    first_key=$(printf '%s\n' "${cephconfig_keys[@]}" | sort | head -1)
    local first_short="${first_key#cephconfig_}"
    wait_for_ceph_config_applied "${first_short}" "${cfg[$first_key]}" 120 || return 1
  else
    # No cephconfig_* in this config: if the cluster currently has any
    # override at .spec.managedResources.cephCluster.cephConfig, remove it
    # so the cluster returns to OOB cephConfig state.
    local cur_cc
    cur_cc=$(oc get storagecluster "${sc_name}" -n "${ns}" \
      -o jsonpath='{.spec.managedResources.cephCluster.cephConfig}' 2>/dev/null)
    if [[ -n "${cur_cc}" && "${cur_cc}" != "{}" ]]; then
      log_info "Removing .spec.managedResources.cephCluster.cephConfig (back to OOB)"
      oc patch storagecluster "${sc_name}" -n "${ns}" --type json \
        -p='[{"op":"remove","path":"/spec/managedResources/cephCluster/cephConfig"}]' >/dev/null \
        || { log_error "cephConfig removal failed"; return 1; }
    fi
  fi
```

- [ ] **Step 2: Extend the realised-state output at end of function**

Find the `cat <<EOF` block at the end of `apply_tuning_config` (around line 420). Add one line inside it, after the existing `realised_cephcluster_osd_resources:` line:

```
realised_cephconfig_osd: $(oc get storagecluster "${sc_name}" -n "${ns}" -o json | jq -c '.spec.managedResources.cephCluster.cephConfig.osd // {}')
```

- [ ] **Step 3: Verify offline tests still pass**

Run: `OC_SKIP_CLUSTER_CHECK=true bash tests/run-offline.sh 2>&1 | tail -5`

Expected: all previous tests still pass (this change does not affect parsing).

- [ ] **Step 4: Commit**

```bash
git add lib/tune-helpers.sh
git commit -m "feat(tune): apply cephconfig_* keys via managedResources.cephCluster

Builds an osd-section JSON object from cephconfig_<key>=<value> pairs,
merges it into .spec.managedResources.cephCluster.cephConfig.osd, and
waits for propagation via wait_for_ceph_config_applied. Reverse path
removes the field when no cephconfig_* keys are present, returning the
cluster to OOB cephConfig state."
```

---

### Task 5: cephConfig restore branch in `restore_cluster_state`

**Files:**
- Modify: `lib/tune-helpers.sh:442-523` (the `restore_cluster_state` function)

- [ ] **Step 1: Add field extraction + restore branch**

In `lib/tune-helpers.sh`, find the field-extraction block at lines ~450–454 inside `restore_cluster_state`. Add one more extraction line after `cstate_mc_present=$(...)`:

```bash
  local cephconfig
  cephconfig=$(awk -F': ' '/^cephconfig:/{print $2}' "${snap}")
```

Then find the `# --- cstate MachineConfig` comment block inside the same function (around line 494). Insert this block immediately before it (between the OSD resources restore and the cstate restore):

```bash
  # --- cephConfig (managedResources.cephCluster.cephConfig) ------------------
  if [[ "${cephconfig}" == "inherit" || -z "${cephconfig}" ]]; then
    local cc_now
    cc_now=$(oc get storagecluster "${sc_name}" -n "${ns}" \
      -o jsonpath='{.spec.managedResources.cephCluster.cephConfig}' 2>/dev/null)
    if [[ -n "${cc_now}" && "${cc_now}" != "{}" ]]; then
      log_info "Restoring: removing .spec.managedResources.cephCluster.cephConfig"
      oc patch storagecluster "${sc_name}" -n "${ns}" --type json \
        -p='[{"op":"remove","path":"/spec/managedResources/cephCluster/cephConfig"}]' &>/dev/null \
        || { log_warn "restore: cephConfig removal warning"; warnings=$((warnings+1)); }
    fi
  else
    log_info "Restoring: .spec.managedResources.cephCluster.cephConfig = ${cephconfig}"
    oc patch storagecluster "${sc_name}" -n "${ns}" --type merge \
      -p "{\"spec\":{\"managedResources\":{\"cephCluster\":{\"cephConfig\":${cephconfig}}}}}" >/dev/null \
      || { log_warn "restore: cephConfig patch warning"; warnings=$((warnings+1)); }
  fi
```

- [ ] **Step 2: Confirm offline tests still pass**

Run: `OC_SKIP_CLUSTER_CHECK=true bash tests/run-offline.sh 2>&1 | tail -5`

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/tune-helpers.sh
git commit -m "feat(tune): restore cephConfig from snapshot in restore_cluster_state

Symmetric to the snapshot/apply path: if snapshot recorded 'inherit',
remove the field; otherwise patch-merge the recorded JSON back. Logged
as a warning (not a hard fail) per the existing best-effort restore
discipline."
```

---

### Task 6: Declare `big-osd+mclock` in `TUNE_CONFIGS`

**Files:**
- Modify: `00-config.sh:316-320` (the `TUNE_CONFIGS` declarations)

- [ ] **Step 1: Add the new TUNE_CONFIGS entry**

In `00-config.sh`, add this line after `TUNE_CONFIGS[big-osd+cstate-off]=...` (line 320):

```bash
TUNE_CONFIGS[big-osd+mclock]='osd_cpu=6 osd_mem=24Gi cephconfig_osd_mclock_profile=high_client_ops cephconfig_bluestore_throttle_bytes=262144 cephconfig_bluestore_throttle_deferred_bytes=262144 cstate=on'
```

Also update the comment block above (around lines 286–315) by appending after the existing key-list documentation (around line 304, after the `cstate    → on | off` block, before the `big-osd sizing:` paragraph):

```bash
#
#   cephconfig_<ceph_key> → any string
#                 Maps to ceph config-database key 'osd:<ceph_key>'. Merged
#                 into .spec.managedResources.cephCluster.cephConfig.osd via
#                 OCS-operator's additive merge. Live propagation (no OSD pod
#                 roll). Common candidates: osd_mclock_profile,
#                 bluestore_throttle_bytes, bluestore_throttle_deferred_bytes,
#                 osd_memory_target.
```

- [ ] **Step 2: Run the offline tests, verify `test_parse_tune_config_bigosd_mclock` now passes**

Run: `OC_SKIP_CLUSTER_CHECK=true bash tests/run-offline.sh 2>&1 | grep -E "big-osd\+mclock|PASS|FAIL"`

Expected: `PASS  big-osd+mclock parses with all expected keys` and no FAILs in any of the new tests.

- [ ] **Step 3: Verify ALL offline tests pass (regression guard)**

Run: `OC_SKIP_CLUSTER_CHECK=true bash tests/run-offline.sh`

Expected: trailing line reads `===== N passed, 0 failed =====` (N = previous count + 3 new tests added in Task 1).

- [ ] **Step 4: Commit**

```bash
git add 00-config.sh
git commit -m "feat(config): add big-osd+mclock tune config

Pairs the existing big-osd resource sizing (6c/24Gi per OSD) with three
live cephConfig overrides:
  - osd_mclock_profile=high_client_ops  (Reef default is balanced)
  - bluestore_throttle_bytes=262144     (NVMe-tuned vs ~40 MiB default)
  - bluestore_throttle_deferred_bytes=262144

Used by the 2026-06-05 tuning follow-up sweep to measure mClock+throttle
delta on top of the existing big-osd baseline."
```

---

### Task 7: Cluster-side cephConfig round-trip smoke test

**Files:**
- Create: `tests/smoke/cephconfig-roundtrip.sh`

A standalone smoke test (separate from `mini-sweep.sh` so it runs in ~2 min instead of ~30 min). Validates apply → `ceph config dump` → restore → `ceph config dump` of a single test key, with full cluster-state restore on every exit path.

- [ ] **Step 1: Write the smoke test**

```bash
#!/usr/bin/env bash
# tests/smoke/cephconfig-roundtrip.sh — verify cephconfig_* keys survive a
# full apply → verify → restore → verify round-trip against a live cluster.
# Uses an innocuous test key (osd_max_scrubs) so a failed restore doesn't
# leave a damaging override behind.
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

# 1. Snapshot the pre-test state.
snapshot_cluster_state "${snap}" || { echo "FAIL: snapshot"; exit 1; }
pre_value=$(oc -n "${NS}" exec deploy/rook-ceph-tools -- \
  ceph config dump --format json 2>/dev/null \
  | jq -r --arg k "${TEST_KEY}" \
      '.[] | select(.section=="osd" and .name==$k) | .value' | head -1)
echo "Pre-apply: ceph osd:${TEST_KEY} = '${pre_value:-<unset>}'"

# 2. Apply the test config.
if ! apply_tuning_config "__test_cephconfig_roundtrip"; then
  echo "FAIL: apply_tuning_config"; exit 1
fi

# 3. Verify the override is live.
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

# 5. Verify the override is gone. Allow up to 30s for restore propagation.
for i in $(seq 1 6); do
  post_value=$(oc -n "${NS}" exec deploy/rook-ceph-tools -- \
    ceph config dump --format json 2>/dev/null \
    | jq -r --arg k "${TEST_KEY}" \
        '.[] | select(.section=="osd" and .name==$k) | .value' | head -1)
  if [[ "${post_value}" == "${pre_value}" ]]; then
    echo "PASS-2: override reverted (osd:${TEST_KEY} = ${post_value:-<unset>})"
    exit 0
  fi
  sleep 5
done

echo "FAIL: post-restore value '${post_value:-<unset>}' != pre-value '${pre_value:-<unset>}'"
exit 1
```

- [ ] **Step 2: Make it executable and run against the cluster**

```bash
chmod +x tests/smoke/cephconfig-roundtrip.sh
bash tests/smoke/cephconfig-roundtrip.sh
```

Expected output (final two lines):
```
PASS-1: override applied (osd:osd_max_scrubs = 2)
PASS-2: override reverted (osd:osd_max_scrubs = <unset>)
```

If `PASS-2` fails, the restore path has a bug — debug before proceeding to Task 8. Common symptoms: snapshot YAML parse error (trace with `cat "${snap}"`), or the patch path being wrong (trace with `oc get storagecluster -n openshift-storage -o yaml | grep -A5 cephConfig`).

- [ ] **Step 3: Run the full smoke suite to confirm no regressions**

```bash
bash tests/smoke/run-smoke.sh
```

Expected: existing smoke tests (`snapshot.sh`, `restore-roundtrip.sh`, etc.) still pass, plus the new `cephconfig-roundtrip.sh`. No FAILs in the trailing summary.

- [ ] **Step 4: Commit**

```bash
git add tests/smoke/cephconfig-roundtrip.sh
git commit -m "test(tune): smoke test for cephconfig_* apply/restore round-trip

Exercises the full path: snapshot → apply_tuning_config with a
cephconfig_osd_max_scrubs key → verify ceph config dump shows override →
restore_cluster_state → verify override reverted. ~2 min cluster time;
uses osd_max_scrubs (Reef default 3 → test 2) so a partial-pass
fallback leaves a safe value behind."
```

---

## Phase 2 — Phase 0 verification + Sweep A (Tasks 8–9)

---

### Task 8: Phase 0 cluster verification

**Files:** none — this is a runbook task, no code changes.

- [ ] **Step 1: Source environment, confirm cluster reach**

```bash
cd /Users/neiltaylor/Projects/storage_perf_tests
source .env
oc cluster-info
```

Expected: API server URL `c115-e.eu-de.containers.cloud.ibm.com:31818` (matches the 2026-06-04 doc's recorded cluster).

- [ ] **Step 2: Confirm Ceph baseline health**

```bash
oc -n openshift-storage exec deploy/rook-ceph-tools -- ceph status
oc -n openshift-storage exec deploy/rook-ceph-tools -- ceph osd tree | head -30
```

Expected: `health: HEALTH_OK`, 24 OSDs `up` and `in`, `rep3-virt` referenced by `ocs-storagecluster-cephblockpool` (or via the OOB virtualization SC).

- [ ] **Step 3: Confirm StorageCluster is at OOB baseline**

```bash
oc -n openshift-storage get storagecluster -o json \
  | jq '.items[0].spec | {resourceProfile, storageDeviceSetsResources: [.storageDeviceSets[]?.resources], managedResources: .managedResources}'
```

Expected:
- `resourceProfile` either `"balanced"` or absent (null).
- `storageDeviceSetsResources` is `[null]` or `[{}]` (no override).
- `managedResources.cephCluster.cephConfig` is absent (or jq prints `null`).

If any of these are non-default, run `./09-run-tune-sweep.sh --restore-from <last-tune-run-id>` first to clean up.

- [ ] **Step 4: Record current `osd_memory_target` and decide on the conditional override**

```bash
oc -n openshift-storage exec deploy/rook-ceph-tools -- \
  ceph tell osd.0 config get osd_memory_target
```

Decision rule:
- If output ≥ `15000000000` (15 GiB) — `osd_memory_target` is already realised via the OOB cgroup-ratio mechanism. **No change needed.** Record the actual value in the writeup.
- If output ≤ `5000000000` (5 GiB, ~Reef default) — add an explicit override. Edit `00-config.sh` to append `cephconfig_osd_memory_target=20000000000` to the `TUNE_CONFIGS[big-osd+mclock]` value, and commit:

```bash
git add 00-config.sh
git commit -m "fix(config): explicit osd_memory_target on big-osd+mclock

Phase-0 verification showed osd_memory_target at Reef default rather
than the ~19 GiB the cgroup ratio should produce. Setting explicitly
to 20 GiB so mClock+throttle is measured against a realised memory
target rather than an unaddressed memory bottleneck."
```

Either way, record the observed value in a scratch note for the writeup.

- [ ] **Step 5: Confirm no other in-progress tune sweep is running**

```bash
ls -lt results/tune-*.checkpoint 2>/dev/null | head -5
oc -n openshift-storage get pods -l app=rook-ceph-osd \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[0].resources.requests.cpu}{"/"}{.spec.containers[0].resources.requests.memory}{"\n"}{end}' | head -5
```

Expected: any open `.checkpoint` files belong to completed runs (no orchestrator currently running). OSD pods at OOB sizing (`2/5Gi` for balanced) — if they show `6/24Gi`, the previous run did not restore cleanly and Phase 0 step 3 should have caught this. Stop and remediate.

---

### Task 9: Run Sweep A (VM-template baseline + 2 Ceph configs)

**Files:** none — invokes the existing orchestrator.

- [ ] **Step 1: Confirm `vm-templates/vm-template.yaml` is at HEAD**

```bash
git diff HEAD -- vm-templates/vm-template.yaml
git log -1 --oneline -- vm-templates/vm-template.yaml
```

Expected: empty diff, last touch is an unrelated commit (not Task 10's iothreads edit).

- [ ] **Step 2: Dry-run to validate the plan**

```bash
./09-run-tune-sweep.sh \
  --pool rep3-virt \
  --configs big-osd,big-osd+mclock \
  --fixed-vms 32 \
  --qd-list 32 \
  --rate-iops 0 \
  --latency-sla 5 \
  --dry-run
```

Expected: plan banner showing 2 configs (`big-osd`, `big-osd+mclock`), 32 VMs, QD list `32`, uncapped rate. No FAILs.

- [ ] **Step 3: Execute Sweep A**

```bash
./09-run-tune-sweep.sh \
  --pool rep3-virt \
  --configs big-osd,big-osd+mclock \
  --fixed-vms 32 \
  --qd-list 32 \
  --rate-iops 0 \
  --latency-sla 5 \
  --auto 2>&1 | tee /tmp/sweep-a.log
```

Expected runtime: ~50 min. On success, the trailing log line reports a `tune-<id>` run-id and the HTML report path.

If interrupted: `./09-run-tune-sweep.sh --restore-from <tune-id-from-trailing-log>` to recover, then re-run.

- [ ] **Step 4: Capture the run-id for later cross-run report**

```bash
RUN_A=$(ls -1dt results/tune-*/ 2>/dev/null | head -1 | sed 's:.*/results/::;s:/$::')
echo "Sweep A run-id: ${RUN_A}"
echo "${RUN_A}" > /tmp/run-a.id
```

- [ ] **Step 5: Sanity-check the cluster restored cleanly**

```bash
oc -n openshift-storage get pods -l app=rook-ceph-osd \
  -o jsonpath='{range .items[*]}{.spec.containers[0].resources.requests.cpu}{"/"}{.spec.containers[0].resources.requests.memory}{"\n"}{end}' | sort -u
oc -n openshift-storage get storagecluster -o json \
  | jq '.items[0].spec | {resourceProfile, storageDeviceSets: [.storageDeviceSets[]?.resources], cephConfig: .managedResources.cephCluster.cephConfig}'
```

Expected: OSD pods back at OOB (`2/5Gi`), `storageDeviceSets` resources empty/absent, `cephConfig` empty/absent. If not, the EXIT trap did not complete — investigate before proceeding to Sweep B.

- [ ] **Step 6: Sanity-check cell (A) against `tune-20260604-135830`**

```bash
RUN_A=$(cat /tmp/run-a.id)
echo "Cell (A) — big-osd, VM-template baseline (this run):"
cat "results/${RUN_A}/qd-sweep/rep3-virt/big-osd/qd-summary.json" | jq '{iops_total, write_p99_ms, read_p99_ms}'
echo "Reference — tune-20260604-135830 (prior big-osd baseline):"
cat "results/tune-20260604-135830/qd-sweep/rep3-virt/big-osd/qd-summary.json" | jq '{iops_total, write_p99_ms, read_p99_ms}'
```

Decision: if `iops_total` deviates >5 %, the cluster has drifted. Document in scratch notes and proceed but flag the comparison as needing baseline-drift caveat.

---

## Phase 3 — VM-template edit + Sweep B (Tasks 10–11)

---

### Task 10: Apply VM-template change on a feature branch

**Files:**
- Modify: `vm-templates/vm-template.yaml:26-45`

- [ ] **Step 1: Create the feature branch**

```bash
git checkout -b feat/vm-iothreads
```

- [ ] **Step 2: Edit `vm-templates/vm-template.yaml`**

In `vm-templates/vm-template.yaml`, modify the `spec.template.spec.domain` block. The current shape (lines 26–45) is:

```yaml
      domain:
        cpu:
          cores: __VCPU__
          sockets: 1
          threads: 1
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: datadisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
          rng: {}
```

Change to:

```yaml
      domain:
        ioThreadsPolicy: auto
        cpu:
          cores: __VCPU__
          sockets: 1
          threads: 1
        devices:
          blockMultiQueue: true
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: datadisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
          rng: {}
```

Two changes: `ioThreadsPolicy: auto` added at `domain` level (before `cpu`), `blockMultiQueue: true` added at `domain.devices` level (before `disks`).

- [ ] **Step 3: Verify the YAML is still valid**

```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('vm-templates/vm-template.yaml')))"
```

Expected: no traceback, exits 0.

- [ ] **Step 4: Commit on the branch**

```bash
git add vm-templates/vm-template.yaml
git commit -m "feat(vm): enable virtio-blk IOThread and multiqueue for data disk

ioThreadsPolicy: auto gives each VM an IOThread per disk (2 for our
2-vCPU small VMs), pinned off the vCPU threads. blockMultiQueue: true
enables per-CPU virtqueues for virtio-blk. Both reduce the in-guest
serialisation of fio's submitted I/O before it reaches Ceph.

On a feature branch until Sweep B confirms a measurable lift. Will be
merged to main if cell (C) > cell (A) by >=5% aggregate IOPS or >=20%
write p99 reduction; otherwise this commit stays on the branch."
```

---

### Task 11: Run Sweep B (VM-template + iothreads, same 2 Ceph configs)

**Files:** none.

- [ ] **Step 1: Confirm the branch is current**

```bash
git branch --show-current
grep -E "ioThreadsPolicy|blockMultiQueue" vm-templates/vm-template.yaml
```

Expected: `feat/vm-iothreads`, both lines present in template.

- [ ] **Step 2: Execute Sweep B with the same parameters as Sweep A**

```bash
./09-run-tune-sweep.sh \
  --pool rep3-virt \
  --configs big-osd,big-osd+mclock \
  --fixed-vms 32 \
  --qd-list 32 \
  --rate-iops 0 \
  --latency-sla 5 \
  --auto 2>&1 | tee /tmp/sweep-b.log
```

Expected runtime: ~50 min.

- [ ] **Step 3: Capture Sweep B run-id**

```bash
RUN_B=$(ls -1dt results/tune-*/ 2>/dev/null | head -1 | sed 's:.*/results/::;s:/$::')
echo "Sweep B run-id: ${RUN_B}"
echo "${RUN_B}" > /tmp/run-b.id
```

- [ ] **Step 4: Sanity-check cluster restored to OOB**

Same checks as Task 9 step 5. OSDs back at `2/5Gi`, no `cephConfig`, no `storageDeviceSets` override.

- [ ] **Step 5: Sanity-check that the iothreads change actually reached the VMs**

Pick one VM dir from the run's checkpoint and inspect the recorded VM YAML if logged. Otherwise run a one-off command-line check:

```bash
# The orchestrator deleted VMs after the sweep. Re-render the template to
# confirm the live file would produce the right YAML.
grep -E "ioThreadsPolicy|blockMultiQueue" vm-templates/vm-template.yaml
```

Expected: both lines present. If they're missing the branch was wrong — re-check git status and re-run.

---

## Phase 4 — Cross-run report, writeup, decision (Tasks 12–15)

---

### Task 12: Cross-run comparison and delta computation

**Files:**
- Output: `reports/compare-<run-a>-vs-<run-b>.html` (generated)
- Output: scratch notes for the writeup

- [ ] **Step 1: Generate the cross-run comparison report**

```bash
RUN_A=$(cat /tmp/run-a.id)
RUN_B=$(cat /tmp/run-b.id)
./06-generate-report.sh --compare "${RUN_A}" "${RUN_B}"
```

Expected: writes `reports/compare-${RUN_A}-vs-${RUN_B}.html`. Open in a browser and confirm the four cells are present with all metrics populated.

- [ ] **Step 2: Extract the four cells' headline numbers**

```bash
RUN_A=$(cat /tmp/run-a.id); RUN_B=$(cat /tmp/run-b.id)
extract() {
  local run="$1" cfg="$2"
  jq -r --arg cfg "${cfg}" --arg run "${run}" \
    '{run: $run, config: $cfg, iops_total, bw_mbps, write_p99_ms, read_p99_ms}' \
    "results/${run}/qd-sweep/rep3-virt/${cfg}/qd-summary.json"
}
echo "Cell (A): ${RUN_A} big-osd"
extract "${RUN_A}" "big-osd"
echo "Cell (B): ${RUN_A} big-osd+mclock"
extract "${RUN_A}" "big-osd+mclock"
echo "Cell (C): ${RUN_B} big-osd"
extract "${RUN_B}" "big-osd"
echo "Cell (D): ${RUN_B} big-osd+mclock"
extract "${RUN_B}" "big-osd+mclock"
```

Copy the four blocks into `/tmp/cells.json` for the writeup.

- [ ] **Step 3: Compute deltas and interaction term**

Save this Python snippet as `/tmp/deltas.py` and run it:

```python
import json
cells = {}
for line in open("/tmp/cells.json"):
    line = line.strip()
    if line.startswith("Cell ("):
        cur = line[6]
    elif line.startswith("{"):
        cells[cur] = json.loads(line.split("}", 1)[0] + "}") if False else None
# Simpler: just parse manually. Replace this stub with the four dicts you
# pasted; here's an example skeleton.
A = {"iops_total": 343107, "write_p99_ms": 52.7, "read_p99_ms": 30.0}  # paste real
B = {"iops_total": 0, "write_p99_ms": 0, "read_p99_ms": 0}             # paste real
C = {"iops_total": 0, "write_p99_ms": 0, "read_p99_ms": 0}             # paste real
D = {"iops_total": 0, "write_p99_ms": 0, "read_p99_ms": 0}             # paste real

def pct(after, before):
    return (after - before) / before * 100.0

for metric in ("iops_total", "write_p99_ms", "read_p99_ms"):
    iot   = pct(C[metric], A[metric])
    mclk  = pct(B[metric], A[metric])
    comb  = pct(D[metric], A[metric])
    inter = (D[metric] - C[metric] - B[metric] + A[metric])
    print(f"{metric}:")
    print(f"  iothreads delta (C vs A): {iot:+.1f}%")
    print(f"  mclock delta (B vs A):    {mclk:+.1f}%")
    print(f"  combined (D vs A):        {comb:+.1f}%")
    print(f"  interaction term (D-C-B+A in raw units): {inter:+.2f}")
```

Edit the four dict literals with the values from Step 2, then `python3 /tmp/deltas.py`. Save the output for the writeup.

- [ ] **Step 4: Classify the outcome per the spec's headline categories**

Apply the rules from `docs/superpowers/specs/2026-06-05-odf-ceph-tuning-followup-design.md` "Headline outcome categories":
- **Big win** → ≥15 % aggregate IOPS lift OR ≥30 % write p99 reduction (either knob individually)
- **Modest win** → 5–15 % aggregate IOPS OR 10–30 % write p99 reduction
- **Null** → <5 % IOPS movement AND <10 % p99 movement
- **Regression** → IOPS worse by >5 % OR p99 worse by >10 %

Record the classification per knob (iothreads and mclock) and for the combined stack for use in Task 14.

---

### Task 13: Companion writeup

**Files:**
- Create: `docs/examples/odf-ceph-tuning-followup-2026-06-05.md`

- [ ] **Step 1: Write the companion doc**

Use the structure of the existing `docs/examples/odf-osd-resource-tuning-2026-06-04.md` as a template. The doc must contain:

1. **Header** — date, cluster, ODF version, source workload, link to the candidate doc and prior 2026-06-04 writeup.
2. **TL;DR** — one paragraph stating the headline finding (which knobs win, by how much, combined-stack outcome, interaction effect).
3. **Cluster baseline** — copy from the 2026-06-04 writeup (same cluster). Add the Phase 0 `osd_memory_target` reading.
4. **Methodology** — 2×2 factorial design, two sweeps, Sweep A and Sweep B parameters, run-ids.
5. **Results** — four-row table for all four cells with all metrics (IOPS, BW, write p50/p95/p99, read p50/p95/p99). Plus delta tables: iothreads-only, mclock-only, combined, interaction.
6. **Observations** — narrative on what each knob did, interaction sign + interpretation.
7. **Outcome classification** — which of the four spec categories applies. Justify.
8. **Reproducibility** — exact orchestrator invocations (already in the spec; copy them here).
9. **Limitations** — single QD point, single workload shape, single PVC size, single VM count, no rate-cap measurements. Link forward to candidate ideas not actioned.
10. **Artefacts** — table of file paths (run dirs, reports).
11. **Cross-references** — links to the 2026-06-04 doc, the candidate doc, the spec, this plan, the relevant commits.

- [ ] **Step 2: Commit (on main, not the feature branch)**

```bash
git checkout main
git add docs/examples/odf-ceph-tuning-followup-2026-06-05.md
git commit -m "docs(perf): 2026-06-05 ODF/Ceph tuning follow-up writeup

2x2 factorial measuring KubeVirt ioThreadsPolicy/blockMultiQueue and
Ceph mclock_profile + 256 KiB BlueStore throttles, both stacked on
big-osd. Reports the deltas, the interaction term, and the outcome
classification per the spec's headline categories."
```

---

### Task 14: VM-template merge decision

**Files:**
- Possibly merge: `feat/vm-iothreads` branch into `main`
- Possibly modify: `CLAUDE.md` if VM-template behaviour shifts in a way that affects documented prerequisites

- [ ] **Step 1: Apply the merge gate from the spec**

Decision:
- If cell (C) shows ≥5 % aggregate IOPS lift over cell (A) OR ≥20 % write p99 reduction → proceed to Step 2 (merge).
- Otherwise → Step 3 (defer or abandon the branch).

- [ ] **Step 2 (merge path): merge the feature branch**

```bash
git checkout main
git merge --no-ff feat/vm-iothreads -m "Merge feat/vm-iothreads: enable IOThread+multiqueue for VM data disks"
```

Then check whether `CLAUDE.md` documents anything about VM-template fields. If yes, add a note about the new fields. If not, no further change needed.

```bash
git push origin main
git branch -d feat/vm-iothreads
```

- [ ] **Step 3 (defer path): leave the branch and document the decision**

```bash
git push origin feat/vm-iothreads
```

Add to the writeup's "Outcome classification" section: "The VM-template change is kept on branch `feat/vm-iothreads` pending [reason — e.g. retest at higher VM count, retest with different workload]; not merged because [exact result that did not clear the bar]."

---

### Task 15: Refresh stale memory note

**Files:**
- Modify: `/Users/neiltaylor/.claude/projects/-Users-neiltaylor-Projects-storage-perf-tests/memory/project_ocs_resources_osd_ignored.md`
- Modify: `/Users/neiltaylor/.claude/projects/-Users-neiltaylor-Projects-storage-perf-tests/memory/MEMORY.md`

- [ ] **Step 1: Update the memory file**

The existing note claims `spec.resources.osd` is ignored and that the big-osd mechanism is a silent no-op. This was true before commits `bac9dd0` and `ea16c47`. As of the 2026-06-04 measurement (and re-confirmed in cell A here), big-osd delivers a real 2.89× lift on this cluster via the correct `storageDeviceSets[0].resources` path.

Overwrite the file with:

```markdown
---
name: ocs-osd-resource-override-path
description: Correct ODF 4.20+ override path for per-OSD resources is storageDeviceSets[i].resources, not spec.resources.osd. Mechanism verified working (2.89x IOPS lift confirmed 2026-06-04 and re-confirmed 2026-06-05).
metadata:
  type: project
---

On ODF 4.20+ (Ceph Reef 18.x), the OCS-operator intentionally suppresses
the `osd` key from `StorageCluster.spec.resources` (see `getDaemonResources`
in `internal/controller/storagecluster/resources.go`). Per-OSD resource
overrides must be set at `StorageCluster.spec.storageDeviceSets[i].resources`
instead. The suite's `apply_tuning_config` was fixed to target this path in
commits `bac9dd0` + `ea16c47`; `wait_for_osd_ready` was extended with a
CephCluster-target stability check to avoid a 30-second reconcile-lag race.

**Why:** Earlier note (now overwritten) said the mechanism was a silent
no-op. That was the symptom of a code defect, not an ODF limitation.

**How to apply:** Trust the existing `big-osd` config in `TUNE_CONFIGS`
on ROKS. The 2026-06-04 baseline measurement on cluster
`ocp-virt-420-v2-cluster` showed 2.89x aggregate IOPS and 5x write p99
improvement vs OOB (recorded in
`docs/examples/odf-osd-resource-tuning-2026-06-04.md`). Re-confirmed
2026-06-05 by cell (A) of the follow-up sweep (see
`docs/examples/odf-ceph-tuning-followup-2026-06-05.md`).
```

- [ ] **Step 2: Update the MEMORY.md index entry**

In `MEMORY.md`, find the line:

```
- [ODF 4.20.7 ignores StorageCluster.spec.resources.osd](project_ocs_resources_osd_ignored.md) — ...
```

Replace with:

```
- [ODF 4.20+ OSD resource override path](project_ocs_resources_osd_ignored.md) — storageDeviceSets[i].resources is the correct path; big-osd mechanism verified working
```

- [ ] **Step 3: Verify the memory files load cleanly**

```bash
ls -la /Users/neiltaylor/.claude/projects/-Users-neiltaylor-Projects-storage-perf-tests/memory/project_ocs_resources_osd_ignored.md \
       /Users/neiltaylor/.claude/projects/-Users-neiltaylor-Projects-storage-perf-tests/memory/MEMORY.md
```

Expected: both files exist, recent mtime. Memory updates do not require a git commit (memory lives outside the repo).

---

## Done. Final verification

- [ ] All commits pushed (or local-only by choice).
- [ ] `./09-run-tune-sweep.sh --pool rep3-virt --configs big-osd,big-osd+mclock --dry-run` shows two configs, no parse errors.
- [ ] Cluster at OOB baseline (Task 9 step 5 check passes).
- [ ] HTML report at `reports/compare-<run-a>-vs-<run-b>.html` opens, all four cells populated.
- [ ] Companion writeup committed.
- [ ] Memory note refreshed.

Total expected wall-clock: ~4–5 h (suite extension + 2 sweeps + writeup + decision).
