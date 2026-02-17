# Parallel Execution

[Back to Documentation Index](../index.md)

This document explains how the `--parallel` flag in `04-run-tests.sh` dispatches multiple storage pools concurrently, how auto-scaling calculates the concurrency level, and how isolation, signal handling, and checkpointing work in parallel mode.

## Overview

By default, `04-run-tests.sh` runs pools sequentially — one pool finishes all its VM groups before the next pool starts. With `--parallel`, pools run simultaneously in background subshells, reducing total wall-clock time roughly proportional to the parallelism level.

```
Sequential (default):
  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
  │   rep2   │ │   rep3   │ │  ec-2-1  │ │ file-dp2 │
  └──────────┘ └──────────┘ └──────────┘ └──────────┘
  ├─────────────────── total time ──────────────────┤

Parallel (--parallel 2):
  ┌──────────┐ ┌──────────┐
  │   rep2   │ │   rep3   │
  └──────────┘ └──────────┘
               ┌──────────┐ ┌──────────┐
               │  ec-2-1  │ │  file-dp2│
               └──────────┘ └──────────┘
  ├───────── ~half total time ─────────┤
```

Usage:

```bash
# Auto-scale based on cluster capacity
./04-run-tests.sh --parallel

# Explicitly run 3 pools at a time
./04-run-tests.sh --parallel 3
```

The unit of parallelism is the **pool** — all VM groups within a single pool still run sequentially (see [Intra-Pool Execution](#intra-pool-execution) below).

## Auto-Scaling

When you pass `--parallel` without a number, the `calculate_max_parallel_pools()` function queries the cluster and calculates how many pools can run simultaneously without overcommitting resources.

### Algorithm

1. **Query cluster resources** — Reads `status.allocatable.memory` and `status.allocatable.cpu` from all worker nodes via `oc get nodes`. Handles Kubernetes quantity suffixes (`m`, `Ki`, `Mi`, `Gi`, bare bytes) and millicores.

2. **Apply system reserve** — Reserves 40% of total capacity for system pods (ODF daemons, KubeVirt, monitoring, etc.). Only 60% is considered available for test VMs.

3. **Calculate average demand per pool** — Iterates all `VM_SIZES × CONCURRENCY_LEVELS` combinations and averages their resource requirements. Using the average (rather than peak) allows slightly more parallelism — when two pools occasionally hit their largest VM group simultaneously, Kubernetes queues VMs as Pending until resources free up, which is safe and self-correcting.

4. **Cap at the limiting resource** — `max_parallel = min(available_mem / avg_mem_per_pool, available_cpu / avg_cpu_per_pool, pool_count)`.

### Example: 3-Node Bare Metal Cluster

For a cluster with 3 workers, each with 96 CPU and 512 GiB RAM, running in `--quick` mode (small VMs: 2 vCPU, 4 GiB, concurrency=1):

| Step | Memory | CPU |
|------|--------|-----|
| Total allocatable | 1536 GiB | 288 cores |
| After 40% reserve | 921 GiB | 172 cores |
| Avg per pool | 4 GiB | 2 cores |
| Max parallel | 230 | 86 |
| Capped at pool count | 9 | 9 |
| **Result** | **9 concurrent pools** | |

In practice the auto-scaler almost always caps at the pool count for `--quick`/`--rank` modes (small VMs), and produces meaningful limits only for the full matrix with large VMs and high concurrency.

## Dispatch Loop

The main execution block uses a bash job queue pattern:

```bash
pool_pids=()
for pool_name in "${ALL_POOLS[@]}"; do
  # Wait for a slot if at capacity
  while [[ $(jobs -rp | wc -l) -ge ${PARALLEL_POOLS} ]]; do
    sleep 2
  done

  run_single_pool "${pool_name}" > "${RESULTS_DIR}/${pool_name}/pool.log" 2>&1 &
  pool_pids+=($!)
  log_info "  Started pool ${pool_name} (pid $!)"
done

# Wait for all remaining
for pid in "${pool_pids[@]}"; do
  wait "${pid}" || true
done
```

Key details:

- **Job queue** — `jobs -rp` counts currently running background jobs. The `while` loop sleeps 2 seconds between checks, keeping the dispatch responsive without busy-waiting.
- **PID tracking** — Every background PID is appended to the `pool_pids` array for the signal handler and final `wait`.
- **Graceful completion** — `wait "${pid}" || true` prevents `set -e` from aborting if one pool fails. Per-pool errors are isolated (see below).

## Per-Pool Isolation

Each pool runs in a background subshell with stdout/stderr redirected:

```
results/<run-id>/<pool-name>/pool.log
```

This keeps the main terminal clean — only the dispatch log messages appear on the console. To follow a specific pool's progress during a run:

```bash
tail -f results/perf-20260215-120000/rep3/pool.log
```

### Error Isolation

Each pool's `wait` is wrapped with `|| true`, so a failure in one pool (VM creation failure, timeout, etc.) does not abort other pools. The `run_single_pool()` function writes a `.pool-summary` file at the end:

```
<tests_run> <passed> <failed> <skipped>
```

After all pools complete, the main script aggregates these summaries and prints per-pool results:

```
Per-pool results:
  rep2:      4/4 passed, 0 failed, 0 skipped (log: results/.../rep2/pool.log)
  rep3:      4/4 passed, 0 failed, 0 skipped (log: results/.../rep3/pool.log)
  ec-2-1:    0/0 passed, 0 failed, 4 skipped (log: results/.../ec-2-1/pool.log)
```

## Signal Handling

The script installs a trap on `INT` and `TERM`:

```bash
cleanup_on_exit() {
  trap 'exit 130' INT TERM   # Second Ctrl+C exits immediately
  log_warn "Interrupted — cleaning up running VMs..."

  # Kill tracked pool PIDs
  for pid in "${pool_pids[@]:-}"; do
    [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
  done
  # Fallback: kill any remaining background jobs
  kill $(jobs -rp) 2>/dev/null || true
  wait 2>/dev/null || true

  # Label-based bulk K8s resource cleanup
  oc delete vm  -n "${TEST_NAMESPACE}" -l "perf-test/run-id=${RUN_ID}" --wait=false
  oc delete secret -n "${TEST_NAMESPACE}" -l "perf-test/run-id=${RUN_ID}" --wait=false
  oc delete pvc -n "${TEST_NAMESPACE}" -l "perf-test/run-id=${RUN_ID}" --wait=false
  exit 130
}
```

The cleanup works in two layers:

1. **Process cleanup** — Kills all tracked PIDs and any remaining background jobs. This stops pool subshells from creating new VMs.
2. **K8s resource cleanup** — Uses label selectors to bulk-delete all VMs, secrets, and PVCs from the current run, regardless of which pool created them.

A **second Ctrl+C** during cleanup exits immediately (the inner trap replaces the handler with a simple exit).

## Checkpoint and Resume

Parallel pools share a single append-only checkpoint file:

```
results/<run-id>.checkpoint
```

Each line records a completed test key (`pool:size:pvc:conc:profile:bs`). Since checkpoint writes are short appends and each pool writes different keys, the risk of interleaving or corruption is low in practice — file appends under the OS buffer size (typically 4 KiB) are atomic on Linux.

When resuming a parallel run:

```bash
./04-run-tests.sh --parallel --resume perf-20260215-120000
```

The checkpoint file is loaded before pool dispatch. Each pool's `run_single_pool()` checks `is_test_completed()` before every test and skips completed ones. Entire VM groups are skipped when all their permutations are already checkpointed, avoiding unnecessary VM creation.

For more on the checkpoint format and resume semantics, see [Test Matrix Explained — Checkpoint and Resume](test-matrix-explained.md#checkpoint--resume).

## Feature Compatibility

All flags work with `--parallel`:

| Flag | Behavior in Parallel Mode |
|------|--------------------------|
| `--quick` | Each pool runs the quick matrix in its subshell |
| `--overview` | Each pool runs 2 tests |
| `--rank` | Each pool runs 3 tests |
| `--filter` | Filter applied per-pool before test execution |
| `--exclude` | Exclusions applied per-pool |
| `--resume` | Shared checkpoint file, loaded before dispatch |
| `--dry-run` | Runs in the main process (no parallel dispatch) |
| `--pool` | Limits to one pool (parallelism has no effect) |

Note: `--dry-run` previews the full matrix in the main process and exits before the parallel dispatch loop, so it always runs sequentially regardless of `--parallel`.

## Intra-Pool Execution

Within each pool, execution is sequential. The `run_single_pool()` function processes VM groups one at a time:

1. **VM group creation** — Creates `N` VMs (where N = concurrency level) with the first fio profile baked into cloud-init
2. **Boot wait** — `wait_for_all_vms_running()` polls until all VMs are Running
3. **First test** — Waits for fio completion, collects results from all VMs in parallel
4. **Subsequent permutations** — For each remaining (profile, block_size) pair: replaces the fio job file via SSH (`replace_fio_job`), restarts the benchmark service (`restart_fio_service`), waits for completion, and collects results
5. **Group cleanup** — Deletes VMs after all permutations complete
6. **Next group** — Moves to the next (vm_size, pvc_size, concurrency) combination

Result collection within a VM group is parallelized (each VM writes to a unique file), and fio job replacement across VMs is also parallelized. The sequential constraint is between VM groups — one group's VMs must be deleted before the next group's are created.

For the full breakdown of how VM groups and permutations work, see [Test Matrix Explained](test-matrix-explained.md).

## Next Steps

- [Test Matrix Explained](test-matrix-explained.md) — VM groups, permutations, and the checkpoint system
- [Project Architecture](project-architecture.md) — Overall design, script pipeline, and library functions
- [Running Tests](../guides/running-tests.md) — Practical guide to executing tests
- [Configuration Reference](../guides/configuration-reference.md) — All tunables in `00-config.sh`
