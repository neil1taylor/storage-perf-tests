# ODF Tuning Sweep — Design Spec

**Date:** 2026-06-03
**Status:** Approved (brainstorming) — awaiting implementation plan
**Author:** Neil Taylor (via Claude Code brainstorming)

## Motivation

The IBM ROVS internal testing slide ("ODF Support for ROVS", 2026 Q2) documents that **default OSD sizing (4 vCPU / 8 GB RAM) is the dominant performance limiter** on ODF/Ceph for dense VM workloads. Increasing OSD allocation to ~66 % of host (8 vCPU / 64 GB per OSD), with optional host C-state disabling, delivers:

- IOPS: ~50 k → ~100 k (+2×)
- Latency: ~200 ms → < 1 ms (reads), ~2 ms (writes)
- Consistent performance across QD 1–64

Our existing scale-test work (`docs/examples/odf-replication-scale-comparison.md`) confirms a smaller version of this finding on the `balanced` → `performance` profile axis (each OSD 2 vCPU / 5 GiB → 4 vCPU / 8 GiB, +50 % capacity lift). This spec extends that work to:

1. Test arbitrary OSD CPU/memory settings beyond the named `resourceProfile` values, including the slide's 8 vCPU / 64 GiB tier.
2. Pin VM count at the slide's 200-VM density target and **sweep queue depth 1 → 64** to characterise the storage tier's behaviour under varying in-flight depth (rather than ramping VM count at a fixed QD as today's scale-test does).
3. Add a host-side dimension — disable processor C-states via MachineConfig — matching the slide's `C`/`RC` variants.
4. Drive the cluster-tuning changes from the harness, with snapshot-and-restore safety so the cluster ends each sweep in its pre-sweep state.
5. Produce a multi-config comparison report mirroring the slide's right-hand panel (IOPS / throughput / read-latency / write-latency bar charts plus a QD-axis line chart).

## Goals

- Reproduce the slide's `D` / `C` / `R` / `RC` test variants end-to-end inside the existing benchmark suite.
- Make OSD CPU/memory a controlled, measurable dimension of the test matrix — not just a documentation footnote.
- Keep the cluster operator out of manual `oc patch` loops: the harness performs every mutation and restores cluster state on every exit path.
- Produce reports comparable to the slide's by reusing the same metrics (aggregate IOPS, aggregate throughput, read p99, write p99 split out separately).

## Non-goals

- Per-step OSD utilisation introspection (cpu/memory usage per OSD pod during the workload). Useful future work; out of this scope.
- Tuning beyond OSD resources and C-states (cache, buffer, IO threading, BlueStore knobs, network stack). The slide lists these as next steps; this spec lays the orchestration foundation so they can be added as additional `TUNE_CONFIGS` entries later.
- Cross-pool overlay in the same report. Reports are per-pool. Operators run the report once per pool.
- GPU / NUMA / hugepages tuning. Not relevant to Ceph OSDs on this hardware.
- Cstate state verification by reading worker `/sys` files. Best-effort via MCP convergence only; manual verification documented in the README.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ 09-run-tune-sweep.sh   config-level orchestrator (new)          │
│   • snapshot → for cfg: apply → wait → invoke 04 → next         │
│   • trap EXIT/INT/TERM → restore                                │
└──────────┬──────────────────────────────────────┬───────────────┘
           │ uses                                  │ invokes per cfg
           ▼                                      ▼
┌──────────────────────────┐    ┌────────────────────────────────┐
│ lib/tune-helpers.sh (new)│    │ 04-run-tests.sh --qd-sweep     │
│   • snapshot_cluster     │    │   (new workload mode)          │
│   • apply_tuning_config  │    │   • pin N VMs, sweep QD list    │
│   • wait_for_osd_ready   │    │   • reuses VMs across QD steps │
│   • wait_for_mcp_updated │    │   • writes results/qd-sweep/   │
│   • restore_cluster      │    │     <pool>/<tune-cfg>/qd.csv   │
└──────────────────────────┘    └────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ 00-config.sh                                                    │
│   declare -A TUNE_CONFIGS                                       │
│   TUNE_CONFIGS[default]='profile=balanced cstate=on'            │
│   TUNE_CONFIGS[cstate-off]='profile=balanced cstate=off'        │
│   TUNE_CONFIGS[big-osd]='osd_cpu=8 osd_mem=64Gi cstate=on'      │
│   TUNE_CONFIGS[big-osd+cstate-off]='osd_cpu=8 osd_mem=64Gi cstate=off' │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ 06-generate-report.sh --compare-tuning (new mode)               │
│   • joins results/qd-sweep/<pool>/<tune-cfg>/qd.csv across cfgs │
│   • emits reports/tune-sweep-<pool>-<run-id>.html               │
│     – QD-axis line chart per config                             │
│     – bar charts: IOPS/BW/read-lat/write-lat per cfg at QD=64   │
│     – capacity scorecard with absolute deltas vs `default`      │
└─────────────────────────────────────────────────────────────────┘
```

### Why three units instead of one big script

- `lib/tune-helpers.sh` is the **only** thing that mutates the cluster — easier to audit, easier to extend when the next ODF tuning surface (cache, buffer, IO threading) lands.
- `04 --qd-sweep` is **cluster-agnostic** — can be run standalone to characterise a pool at fixed N across QDs without any cluster mutation.
- `09` is the only unit needing `EXIT`-trap restore semantics; `04` stays purely about workload.

### Results layout (per run-id)

```
results/<run-id>/
  cluster-snapshot.yaml              ← pre-sweep state for restore
  sweep-plan.txt                     ← printed during pre-flight
  qd-sweep/<pool>/
    <tune-cfg>/
      tuning-applied.yaml            ← what was actually patched
      qd.csv                         ← qd, iops_r, iops_w, bw_mbs,
                                       p50/p95/p99 R+W, sla_pass
      qd-summary.json                ← per-config aggregate
      raw/qd<N>/                     ← per-VM fio JSON, per QD step
```

## Components

### 1. `00-config.sh` additions

```bash
# Tuning-sweep config matrix. Each value is space-separated key=value pairs.
# Recognised keys:
#   profile   → balanced | performance (StorageCluster.spec.resourceProfile)
#   osd_cpu   → integer CPU cores (overrides profile defaults)
#   osd_mem   → memory quantity e.g. 64Gi
#   cstate    → on | off
#                 on  = remove tune-sweep MachineConfig if present
#                 off = apply MC with kernelArgs
#                       intel_idle.max_cstate=0 processor.max_cstate=0
declare -A TUNE_CONFIGS=(
  [default]='profile=balanced cstate=on'
  [cstate-off]='profile=balanced cstate=off'
  [big-osd]='osd_cpu=8 osd_mem=64Gi cstate=on'
  [big-osd+cstate-off]='osd_cpu=8 osd_mem=64Gi cstate=off'
)

# Sweep defaults
TUNE_DEFAULT_CONFIGS="${TUNE_DEFAULT_CONFIGS:-default,cstate-off,big-osd,big-osd+cstate-off}"
TUNE_QD_LIST="${TUNE_QD_LIST:-1,2,4,8,16,32,64}"
TUNE_FIXED_VMS="${TUNE_FIXED_VMS:-200}"
TUNE_MC_NAME="${TUNE_MC_NAME:-99-perf-test-cstate-off}"
TUNE_MCP_TIMEOUT="${TUNE_MCP_TIMEOUT:-1800}"   # 30 min for full MCP rollout
TUNE_OSD_TIMEOUT="${TUNE_OSD_TIMEOUT:-1200}"   # 20 min for OSD restart
```

### 2. `lib/tune-helpers.sh`

Public interface (each documented in-file):

```bash
# Snapshot the cluster's current OSD-resource + host-tuning state.
snapshot_cluster_state <out_yaml>
#   Captures:
#     • StorageCluster .spec.resourceProfile
#     • StorageCluster .spec.resources.osd  (if set; else `inherit`)
#     • Presence of MachineConfig named ${TUNE_MC_NAME}
#     • MCP worker .status.{updated,degraded,ready} counts

# Restore cluster to a previously captured snapshot.
restore_cluster_state <snapshot_yaml>
#   Returns:
#     0 — clean restore, all sub-steps converged
#     2 — best-effort, one or more warnings (snapshot still on disk)
#     1 — failed to read/parse snapshot

# Parse and validate a named config from TUNE_CONFIGS.
parse_tune_config <name>      # → emits key=value lines on stdout
#   Errors on unknown name or unknown key.

# Apply a named config to the cluster (idempotent).
apply_tuning_config <name>
#   Mutations:
#     profile=…              → oc patch StorageCluster (merge)
#     osd_cpu= / osd_mem=    → oc patch StorageCluster spec.resources.osd
#     cstate=on              → oc delete MC ${TUNE_MC_NAME} --ignore-not-found
#     cstate=off             → oc apply -f <rendered MC>
#   Writes: <results-dir>/qd-sweep/<pool>/<name>/tuning-applied.yaml
#   Returns 0 only after wait_for_* succeed.

# Block until all rook-ceph-osd-* pods are Ready and Ceph health is OK.
wait_for_osd_ready <timeout-secs>
#   Detects HEALTH_ERR and fails fast.

# Block until MCP worker has converged (updatedMachineCount == machineCount).
wait_for_mcp_updated <pool=worker> <timeout-secs>
#   No-op (return 0) if no MC change is pending.

# Render the cstate-off MachineConfig YAML.
render_cstate_machineconfig <out_yaml>
#   role=worker, kernelArguments:
#     - intel_idle.max_cstate=0
#     - processor.max_cstate=0
```

### Key design decisions in the lib

- **Snapshot is the source of truth for restore**, not a "what I patched" log. Restore works even if the sweep crashed mid-mutation.
- **`apply_tuning_config` is idempotent**: re-applying `default` reverts OSD overrides; `cstate=on` deletes the MC if present. The sweep loop itself never tracks "what was the previous config".
- **`tuning-applied.yaml` per config** records the *realised* state post-merge (resolved values from Rook coercion, etc.), not the input intent. Decouples sweep input (`big-osd`) from realised state for the report.
- **Wait loops are explicit and tunable.** OSD restart and MCP rollout have very different timescales; folding them together would hide problems.

### 3. `04-run-tests.sh --qd-sweep`

New workload mode. Invocation:

```bash
./04-run-tests.sh --qd-sweep \
  --pool rep3-virt \
  --fixed-vms 200 \
  --qd-list 1,2,4,8,16,32,64 \
  --rate-iops 500 \
  --latency-sla 5 \
  --tune-cfg-name big-osd          # optional; result tagging only
```

Mutually exclusive with `--quick`, `--overview`, `--rank`, `--scale-test`. Requires `--pool`. Standalone-usable without any cluster mutation (operator can characterise QD at whatever the current tuning is).

#### Workload

Identical to scale-test methodology:

- Profile: `mixed-70-30-rated.fio` (70 R / 30 W, 4k random)
- numjobs: 1 per VM
- runtime: `FIO_RUNTIME` (default 60 s) + `FIO_RAMP_TIME` (30 s)
- rate cap: `--rate-iops` (default 500 / VM)
- VM size: small (2 vCPU / 4 GiB), 150 GiB PVC, 10 GiB test file
- Prefill: sequential 4M write across full test file before measurement
- Sync barrier: shared epoch — all VMs wait, then start measurement simultaneously

#### Execution loop

```
phase 1: bring up the population once
  render fio profile with iodepth=__QD__ placeholder
  create_test_vm × fixed_vms in parallel batches (size = VM_BATCH_SIZE)
  wait_for_all_vms_running
  wait_for_all_prefill_complete

phase 2: for qd in qd_list:
  for each VM:
    replace_fio_job() via SSH  →  sets iodepth=$qd
  emit fresh sync-barrier epoch (now + SCALE_SYNC_BARRIER_SECS)
  restart_fio_service() across all VMs
  wait_for_all_fio_complete
  collect_vm_results → results/<run>/qd-sweep/<pool>/<cfg>/raw/qd<qd>/<vm>-fio.json
  aggregate → one row appended to results/<run>/qd-sweep/<pool>/<cfg>/qd.csv
  append checkpoint key  qd-sweep:<pool>:<cfg>:<qd>  to results/<run>.checkpoint
  log step result; continue regardless of SLA pass/fail

phase 3: cleanup
  delete_test_vm × fixed_vms
  emit qd-summary.json (best/worst QD, SLA crossing point, run metadata)
```

**No SLA-driven early termination.** Unlike scale-test (which exists to find a ceiling), the QD sweep characterises a config across all QDs — every QD point runs so the comparison plot has complete data.

#### qd.csv schema (one row per QD step)

```
vm_count,qd,rate_iops,total_read_iops,total_write_iops,total_bw_mbs,
avg_p50_read_ms,avg_p95_read_ms,max_p99_read_ms,
avg_p50_write_ms,avg_p95_write_ms,max_p99_write_ms,sla_pass
```

The split between read p99 and write p99 matters — the slide's headline finding ("sub-ms reads, ~2 ms writes") and its right-side chart panel both keep them separate. The existing scale-test only tracks `max_p99_ms` (write side) since its SLA is write-dominated.

#### qd-summary.json schema

```json
{
  "pool": "rep3-virt",
  "tune_cfg_name": "big-osd",
  "vm_count": 200,
  "rate_iops_per_vm": 500,
  "qd_list": [1, 2, 4, 8, 16, 32, 64],
  "latency_sla_ms": 5,
  "highest_qd_within_sla": 32,
  "iops_at_highest_qd_within_sla": 78420,
  "qd_with_peak_iops": 64,
  "peak_total_iops": 99100,
  "p99_write_at_peak_qd_ms": 1.92,
  "p99_read_at_peak_qd_ms": 0.71,
  "resource_ceiling": false,
  "ocs_version": "4.18.0",
  "cluster_description": "...",
  "run_id": "tune-20260603-...",
  "timestamp": "2026-06-03T..."
}
```

#### Reuse-vs-rebuild for VMs

The existing reuse pattern (`replace_fio_job` + `restart_fio_service`) is preserved. At 200 VMs, rebuilding for every QD step would add hours and serves no methodological purpose: QD is an in-guest fio parameter, not a storage-side concept.

#### Resume / checkpoint

Checkpoint key format: `qd-sweep:<pool>:<cfg>:<qd>`. `--resume <run-id>` skips already-checkpointed QD points; if all QDs for a (pool, cfg) are done, the entire phase-1 VM bringup is skipped too.

#### Workload failure modes

| Condition | Behaviour |
|---|---|
| VM creation count below `fixed-vms` after retries | Mode exits with `resource_ceiling=true`, partial qd.csv preserved, no further QD steps attempted, returns 0 to caller. |
| `fio` fails on any VM at a given QD | Step recorded; failed VM excluded from aggregation; logged. If > 10 % of VMs fail, step marked `sla_pass=false` regardless of latency. |
| 0-byte fio JSON | Existing handler: NaN row, `sla_pass=false`. |
| SLA breach at any QD | Recorded; sweep continues. |
| User Ctrl+C mid-sweep | Existing signal-trap pattern cleans up VMs; checkpoint preserved. |

### 4. `09-run-tune-sweep.sh`

Config-level orchestrator. Invocations:

```bash
./09-run-tune-sweep.sh \
  --pool rep3-virt \
  --configs default,cstate-off,big-osd,big-osd+cstate-off \
  --fixed-vms 200 \
  --qd-list 1,2,4,8,16,32,64 \
  --rate-iops 500 \
  --latency-sla 5

./09-run-tune-sweep.sh --pool rep3-virt --configs big-osd         # subset
./09-run-tune-sweep.sh --pool rep3-virt --dry-run                  # preview plan
./09-run-tune-sweep.sh --restore-from <run-id>                    # restore-only
./09-run-tune-sweep.sh --pool rep3-virt --resume <run-id>          # resume mid-sweep
```

#### Pre-flight (before any mutation)

1. Source `00-config.sh`; resolve each `--configs` name against `TUNE_CONFIGS`; fail fast on unknown names or unknown keys.
2. Verify cluster reachable (`oc cluster-info`).
3. Verify pool's StorageClass exists.
4. Run feasibility checks against the pool — skip the sweep if the pool wouldn't provision at all.
5. Print the ramp plan with time estimates:

   ```
   Tune-sweep plan: 4 configs × 7 QDs on pool rep3-virt @ 200 VMs
   Est. cluster mutation time:
     2 × StorageCluster patch + OSD restart       ≈ 24 min
     2 × MachineConfig + worker MCP reboot         ≈ 60 min
   Est. workload time per config:                  ≈ 25 min
   Total est.                                      ≈ 3 h
   ```

6. Under `--dry-run`, exit here.

#### Sweep loop

```bash
RUN_ID="tune-${TIMESTAMP}"
SNAPSHOT="${RESULTS_DIR}/${RUN_ID}/cluster-snapshot.yaml"

mkdir -p "$(dirname "${SNAPSHOT}")"
snapshot_cluster_state "${SNAPSHOT}"

# Trap registered AFTER snapshot exists, so we never restore from /dev/null.
trap '_on_exit' EXIT INT TERM
_on_exit() {
  local rc=$?
  [[ "${RESTORE_DONE:-false}" == true ]] && return $rc
  log_warn "Tune-sweep exiting (rc=${rc}); restoring cluster from snapshot..."
  restore_cluster_state "${SNAPSHOT}" || \
    log_error "Restore reported issues — verify manually with: oc get storagecluster -o yaml"
  RESTORE_DONE=true
  return $rc
}

for cfg in "${CONFIGS[@]}"; do
  log_info "===== Config: ${cfg} ====="

  if cfg_complete_in_checkpoint "${RUN_ID}" "${POOL}" "${cfg}"; then
    log_info "  Already complete; skipping"
    continue
  fi

  apply_tuning_config "${cfg}" \
    > "${RESULTS_DIR}/${RUN_ID}/qd-sweep/${POOL}/${cfg}/tuning-applied.yaml" \
    || { log_error "apply failed for ${cfg}; aborting sweep"; exit 1; }

  wait_for_osd_ready "${TUNE_OSD_TIMEOUT}" \
    || { log_error "OSDs not ready for ${cfg}; aborting"; exit 1; }
  wait_for_mcp_updated worker "${TUNE_MCP_TIMEOUT}" \
    || { log_error "MCP not ready for ${cfg}; aborting"; exit 1; }

  RUN_ID="${RUN_ID}" ./04-run-tests.sh \
    --qd-sweep \
    --pool "${POOL}" \
    --fixed-vms "${FIXED_VMS}" \
    --qd-list "${QD_LIST}" \
    --rate-iops "${RATE_IOPS}" \
    --latency-sla "${LATENCY_SLA}" \
    --tune-cfg-name "${cfg}" \
    || { log_error "Workload failed for ${cfg}; aborting"; exit 1; }
done

log_info "All configs complete. Restoring initial cluster state..."
restore_cluster_state "${SNAPSHOT}"
RESTORE_DONE=true

./06-generate-report.sh --compare-tuning \
  --run "${RUN_ID}" \
  --pool "${POOL}"
```

#### Key decisions

- **`apply` is called even for `default`.** Guarantees the first config starts from a known canonical state.
- **One snapshot, taken before any mutation, used for restore on every exit path.** Not per-config snapshots — restore is "back to where you started."
- **Restore on success too.** After the last config completes, restore runs explicitly so the cluster ends in the same state it began.
- **Restore-on-trap is idempotent.** `RESTORE_DONE` flag prevents double-restore.
- **Hard abort on apply/wait failure.** Continuing with degraded cluster state risks compounding damage and makes results meaningless.
- **`09` passes `RUN_ID` down to `04`** so all results land in the same `results/<run-id>/` tree.

#### `--restore-from <run-id>`

For when a sweep died without the trap firing (`kill -9`, terminal close mid-trap). Reads `results/<run-id>/cluster-snapshot.yaml` and calls `restore_cluster_state` against it. Safe to re-run.

#### Concurrent-run safety

- Sweep writes lock file: `results/.tune-sweep.lock` containing `{run_id, pid, host, timestamp}`.
- Other invocations exit with the holder's metadata + "use `--force` to override".
- Lock removed on normal exit and by the trap.
- Stale-lock detection: if `pid` no longer exists on local host, warn and proceed.

### 5. `06-generate-report.sh --compare-tuning`

Invocation:

```bash
./06-generate-report.sh --compare-tuning \
  --run tune-20260603-141200 \
  --pool rep3-virt \
  [--baseline default] \
  [--headline-qd 64] \
  [--output reports/tune-sweep-<pool>-<run>.html]
```

`--baseline` is the config whose row in the scorecard reads "—" for deltas; default: a config literally named `default` if present, else the lexically-first config name.

`--headline-qd` selects the QD step the bar-chart panel uses; default: highest QD in the data set.

#### Inputs (auto-discovered)

```
results/<run-id>/qd-sweep/<pool>/<cfg>/qd.csv          (per cfg)
results/<run-id>/qd-sweep/<pool>/<cfg>/qd-summary.json (per cfg)
results/<run-id>/qd-sweep/<pool>/<cfg>/tuning-applied.yaml (per cfg)
```

Configs missing either CSV or summary are skipped with a warning; the report still generates for the rest, with a banner noting which configs are missing.

#### Comparability banner

Same green/amber pattern as `--compare-scale`:

| Check | Banner |
|---|---|
| All configs share `vm_count`, `qd_list`, `rate_iops`, `latency_sla_ms` | green: apples-to-apples. |
| Any differ across configs | amber: lists the differing fields. |

#### Report layout

- Comparability banner
- Intro + "How to read" + "Methodology" (collapsed by default, same pattern as `--compare-scale`)
- **Capacity scorecard** — one row per config:
  Config / Peak IOPS / Δ IOPS vs baseline / Peak BW MB/s / Δ BW / p99 R @ peak ms / p99 W @ peak ms / SLA at headline QD / Resource ceiling / Tuning-applied summary (compact: `profile=balanced, osd=4/8Gi, cstate=on`)
- **Headline @ headline-QD** — four side-by-side bar charts (IOPS / BW / read p99 / write p99), one bar per config, same color palette across panels so the eye tracks the same config across charts. Mirrors the slide's right-hand panel.
- **QD-axis chart** — dual-axis line chart:
  - Solid lines (left axis): aggregate IOPS by QD, one per config.
  - Dashed lines (right axis): write p99 by QD, one per config (same color as its solid pair).
  - Dashed red horizontal line: SLA threshold (only drawn if all configs share one).
  - Points colored green/red per `sla_pass`.
- **Per-config details** — each in `<details>`:
  - `tuning-applied.yaml` rendered as a compact summary.
  - Full qd.csv as a table (QD × all metrics × sla_pass).

#### Single-pool focus

Report is per-pool. Cross-pool overlay is out of scope (separate report mode, future work if needed).

#### Output path

```
reports/tune-sweep-<pool>-<run-id>.html
```

#### Implementation

- New function `generate_tune_sweep_report()` in `lib/report-helpers.sh` — same pattern as `generate_scale_test_comparison_report()`: embedded Python heredoc, Chart.js + chartjs-plugin-annotation CDN, Carbon-ish styling.
- New CLI handler in `06-generate-report.sh` for `--compare-tuning` (~50 lines, same pattern as `--compare-scale`).
- Reuses the `roks_palette` + comparability-banner helpers from `--compare-scale`.

## Error handling

### Pre-flight

| Condition | Behaviour |
|---|---|
| `oc cluster-info` fails | Exit immediately (existing `00-config.sh` behaviour). No mutation. |
| Pool's StorageClass missing | Exit with instruction to run `./01-setup-storage-pools.sh` first. |
| Unknown config name in `--configs` | Exit with available names from `TUNE_CONFIGS`. |
| Config spec has unknown keys | Exit listing the unrecognised keys. |
| `oc auth can-i patch storagecluster -n openshift-storage` returns no | Exit with "needs cluster-admin". |
| EC pool feasibility check fails | Exit before snapshot; no point sweeping a pool that won't provision. |
| Pool is `cephfs-*` and any cfg sets `osd_cpu` | Allowed — OSD resources apply at cluster level; note logged. |
| No `StorageCluster` CRD (non-ODF cluster) | Exit. |
| Multi-AZ cluster (`CLUSTER_MULTI_AZ=true`) | Warn; prompt before proceeding (skipped under `--auto`/`--yes`): cross-AZ latency variance may dominate OSD-resource effects. |
| Existing PerformanceProfile / TunedProfile owns kernelArgs | Warn before `cstate-off`: NodeTuningOperator may conflict with or revert our MC. |

### Mutation

`apply_tuning_config` returns non-zero on any of:

- `oc patch storagecluster` rejected by webhook.
- `oc apply` of MachineConfig rejected.
- StorageCluster stuck `Progressing` for > `TUNE_OSD_TIMEOUT` without converging.
- Rook reports `HEALTH_ERR` after the wait window (PG inactive, MON down).
- MachineConfigPool worker becomes `Degraded`.

Sweep aborts on apply failure → trap fires → restore runs. Restore is best-effort and never deletes existing results.

### Workload (delegated to `04`)

See workload failure modes table above. `04` returns 0 even on `resource_ceiling=true` (the sweep continues to the next cfg); returns non-zero only on infrastructural failure (Ctrl+C, fatal `oc` errors).

### Restore

| Result | Behaviour |
|---|---|
| 0 — clean | Logged: "Cluster restored to pre-sweep state." |
| 2 — best-effort | Sweep keeps its prior exit code, but `_on_exit` prints a prominent banner with snapshot path, remediation commands, and current-vs-snapshot diff. |
| 1 — failed (unreadable snapshot) | Diagnostic plus current observed state for manual diff. |

`--restore-from <run-id>` is a thin re-entry point that just calls `restore_cluster_state`.

### Determinism / repeatability

- Each config records `tuning-applied.yaml` post-mutation (realised state, not intent).
- `qd-summary.json` includes `run_id`, `timestamp`, `ocs_version`, `cluster_description` so cross-run comparisons detect ODF-version drift.

### Deliberately not handled

| Decision | Rationale |
|---|---|
| Auto-rollback on mid-workload Ceph degradation | Out of scope — that's the test result. Restore runs at end of sweep as usual. |
| Mid-workload OSD utilisation introspection | Out of scope; future "deep diagnostics" feature. |
| Cstate verification per worker by reading /sys | Best-effort via MCP convergence; manual verification step documented in README. |
| GPU / NUMA / hugepages tuning | Not relevant to Ceph OSDs. |

## Testing approach

The suite is bash + heredoc'd Python; no unit-test framework today. Tests follow CLAUDE.md's pattern: "Define the target state check before applying changes; confirm it fails, apply changes, confirm it passes."

### Off-cluster tests (`tests/run-offline.sh`)

Fast — runs without `oc`:

| Test | Asserts |
|---|---|
| `parse_tune_config` round-trip | Each `TUNE_CONFIGS[name]` parses without error; canonical form is stable. |
| Unknown-key validation | Hand-crafted spec with `osd_mem_gb=64` (wrong key) exits non-zero with offending key. |
| `render_cstate_machineconfig` | Output is valid YAML; passes `oc apply --dry-run=client`. |
| `09 --dry-run` plan output | For a fixed config set, plan matches golden file. |
| `06 --compare-tuning` against fixture | `tests/fixtures/tune-sweep-3cfg/` mirrors the on-disk schema; HTML contains all expected canvases and sections. |
| Comparability-banner logic | Mismatched fixtures → amber; matched → green. |

### Cluster smoke tests (`tests/smoke/run-smoke.sh`)

Need a live ROKS cluster; not run on every commit:

| Test | Asserts |
|---|---|
| `snapshot_cluster_state` on real cluster | Output is non-empty and contains all expected keys. No mutation. |
| `apply_tuning_config default` on already-default cluster | No-op; convergence wait completes immediately. |
| `apply_tuning_config big-osd` | StorageCluster reaches requested `osd.resources`; one OSD pod restarts within wait window; post-apply health = HEALTH_OK. |
| `wait_for_mcp_updated` no-op path | Called after `default` (no MC pending) returns 0 in < 10 s; no node reboot. |
| `restore_cluster_state` against fresh snapshot | After `big-osd`, restore brings StorageCluster back to snapshotted state exactly; no residual MC. |
| End-to-end mini sweep | `--configs default,big-osd --fixed-vms 4 --qd-list 1,32`; ~30 min; verifies the full loop, checkpoint, results layout, report generation. |

### Manual verification before declaring done

Per CLAUDE.md "evidence before assertions":

1. Run the full 4-config sweep against `rep3-virt` at 200 VMs.
2. Open `reports/tune-sweep-rep3-virt-<run>.html`.
3. QD-axis chart shows the slide's pattern: `default` bends hard at high QD, `big-osd` stays flat across 1–64.
4. Confirm `restore_cluster_state` left the cluster on the operator's original `resourceProfile` (`oc get storagecluster -o jsonpath='{.spec.resourceProfile}'`).
5. Confirm no stray `${TUNE_MC_NAME}` MachineConfig (`oc get mc | grep perf-test-cstate`).

### Fixture data

`tests/fixtures/tune-sweep-3cfg/` mirrors:

```
qd-sweep/rep3-virt/
  default/{qd.csv, qd-summary.json, tuning-applied.yaml}
  cstate-off/{qd.csv, qd-summary.json, tuning-applied.yaml}
  big-osd/{qd.csv, qd-summary.json, tuning-applied.yaml}
```

Numbers synthesised to mirror the slide: `default` peaks ~57 k IOPS with 200+ ms p99; `big-osd` peaks at 100 k with sub-2 ms p99. Both validates the report and serves as a self-documenting schema example.

## Risks and open questions

| Risk / question | Mitigation / plan |
|---|---|
| MCP rollout (cstate flip) is ~30–60 min on a 3-worker cluster. A 4-config sweep with two cstate flips adds ~2 hours of pure reboot time. | Documented in the plan output; operator can subset `--configs` to drop cstate variants for faster runs. |
| `cstate-off` MachineConfig may conflict with an existing PerformanceProfile / TunedProfile on the cluster. | Pre-flight warning; manual override required to proceed. |
| Restore may not fully converge if cluster was already in a partially-degraded state when the sweep started. | Snapshot captures pre-sweep state including MCP health; restore reports a best-effort warning and the operator gets explicit remediation commands. |
| ODF version drift across runs makes long-term comparison apples-to-oranges. | `ocs_version` recorded per run; report banner can flag mismatches (future enhancement). |
| Slide's findings come from a specific hardware profile (64-vCPU worker); 8 vCPU / 64 GiB per OSD may be infeasible on smaller workers. | Pre-flight check should warn if requested OSD CPU > 50 % of smallest worker's allocatable. (Stretch goal; not blocking initial implementation.) |
| Multi-AZ clusters are not the slide's test environment. | Pre-flight warning; operator confirms before proceeding. |
| The slide's "default OSD sizing 4 vCPU / 8 GB" corresponds to ODF `resourceProfile: performance`, not `balanced` (per our existing docs `balanced` is 2 vCPU / 5 GiB). | The `TUNE_CONFIGS[default]` value above uses `profile=balanced` which is *our* observed default. The slide's "D" baseline is one rung above ours — worth confirming with the operator before publishing comparative numbers. Documented in the methodology section of the report. |

## Out of scope (future work)

- BlueStore cache / IO threading tunables as additional `TUNE_CONFIGS` entries.
- Per-step OSD pod CPU/memory utilisation capture (would inform whether the OSDs are actually CPU-bound at peak).
- Cross-pool overlay in the comparison report.
- Multi-pool sweep in a single invocation (currently one-pool-at-a-time; operator runs `09` per pool).
- Validation of cstate state by sshing into worker debug pods.

## Implementation order (sketch — final plan via `writing-plans` skill)

1. `00-config.sh` additions + `lib/tune-helpers.sh` primitives (snapshot, parse, render). Off-cluster tests for each.
2. `lib/tune-helpers.sh` cluster-mutating primitives (apply, wait, restore). Cluster smoke tests.
3. `04 --qd-sweep` workload mode. Smoke test: minimum-N mini sweep (4 VMs × 2 QDs) at the cluster's current tuning.
4. `09-run-tune-sweep.sh` orchestrator. Smoke test: full mini sweep across 2 configs.
5. `06 --compare-tuning` report. Off-cluster test against fixture.
6. End-to-end full sweep + manual verification.
7. Documentation: update CLAUDE.md "Key Commands" + a new "Tune sweep" section; add `docs/examples/odf-tune-sweep-<pool>.md` once a real sweep has been run with publishable results.
