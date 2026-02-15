# Test Matrix Explained

[Back to Index](../index.md)

This page explains the 6-dimensional test matrix at the core of `04-run-tests.sh` — what it iterates, how VMs are reused, how permutations are counted, and how quick mode reduces the matrix.

## The Six Dimensions

The test suite iterates across six dimensions. VMs are created once per outer-loop group (dimensions 1-4) and **reused** across the inner dimensions (5-6) via SSH fio job replacement:

```
for pool in storage_pools:                    # Dimension 1 ─┐
  for vm_size in vm_sizes:                    # Dimension 2  │ Outer loop:
    for pvc_size in pvc_sizes:                # Dimension 3  │ VMs created once
      for concurrency in concurrency_levels:  # Dimension 4 ─┘
        create VMs, wait for Running
        for profile in fio_profiles:          # Dimension 5 ─┐ Inner loop:
          for block_size in block_sizes:      # Dimension 6 ─┘ VMs reused
            replace fio job via SSH, restart service, wait, collect
        delete VMs
```

The first (profile × block_size) permutation in each group runs via cloud-init (baked into the VM at creation). Subsequent permutations replace the fio job file via `replace_fio_job()` and restart the benchmark service via `restart_fio_service()`, avoiding redundant VM provisioning, boot, and package installation.

### Dimension Details

| # | Dimension | Default Values | Count | Purpose |
|---|-----------|---------------|-------|---------|
| 1 | **Storage Pool** | rep3, rep3-virt, rep3-enc, rep2, ec-2-1, ec-2-2, ec-4-2, + File CSI profiles | ~12 | Compare storage backends |
| 2 | **VM Size** | small (2/4Gi), medium (4/8Gi), large (8/16Gi) | 3 | Measure CPU/memory impact on I/O |
| 3 | **PVC Size** | 150Gi, 500Gi, 1000Gi | 3 | Measure volume size impact on I/O |
| 4 | **Concurrency** | 1, 5, 10 VMs | 3 | Measure contention and scalability |
| 5 | **fio Profile** | sequential-rw, random-rw, mixed-70-30, db-oltp, app-server, data-pipeline | 6 | Different workload patterns |
| 6 | **Block Size** | 4k, 64k, 1M | 3 | Different I/O operation sizes |

## Fixed Block-Size Profiles

Not all profiles use the block-size loop. Three profiles — `db-oltp`, `app-server`, and `data-pipeline` — define per-job block sizes within their fio files (e.g., db-oltp uses 8k for data pages and 4k for point queries).

For these profiles:
- The block-size dimension is set to `"native"` (a single iteration)
- The block sizes in the .fio file are used as-is
- The `${BLOCK_SIZE}` placeholder is not used

This is tracked in the `FIO_FIXED_BS_PROFILES` array in `00-config.sh`.

### Impact on Permutation Count

The total test count is not simply the product of all dimensions. It accounts for fixed-BS profiles:

```
Total = pools × vm_sizes × pvc_sizes × concurrency × (
  variable_bs_profiles × block_sizes + fixed_bs_profiles × 1
)
```

With default values (7 ODF + 5 File CSI = 12 pools):

```
Variable-BS: 3 profiles × 3 block sizes = 9
Fixed-BS:    3 profiles × 1              = 3
Per combo:   9 + 3 = 12

Total = 12 pools × 3 vm_sizes × 3 pvc_sizes × 3 concurrency × 12
      = 12 × 3 × 3 × 3 × 12
      = 3,888 test permutations
```

With 7 ODF pools only: 7 × 3 × 3 × 3 × 12 = 2,268 permutations.

**Note:** ec-2-2 (needs 4 hosts) and ec-4-2 (needs 6 hosts) are included in the config but automatically skipped on clusters with fewer OSD hosts. The actual pool count depends on your cluster topology.

## Quick Mode

The `--quick` flag reduces the matrix for fast validation:

| Dimension | Full | Quick |
|-----------|------|-------|
| VM Sizes | small, medium, large | small only |
| PVC Sizes | 150Gi, 500Gi, 1000Gi | 150Gi only |
| Concurrency | 1, 5, 10 | 1 only |
| Block Sizes | 4k, 64k, 1M | 4k, 1M only |
| fio Profiles | all 6 | random-rw, sequential-rw only |

Quick mode with 12 pools:

```
Variable-BS: 2 profiles × 2 block sizes = 4
Fixed-BS:    0 profiles × 1              = 0
Per combo:   4

Total = 12 × 1 × 1 × 1 × 4 = 48 permutations
```

This reduces runtime from days to hours while still testing the key dimensions (pool comparison, IOPS vs throughput).

## Single-Pool Mode

The `--pool <name>` flag tests only one storage pool:

```bash
./04-run-tests.sh --pool rep3
```

With full matrix: 1 × 3 × 3 × 3 × 12 = 324 permutations.
With quick mode: 1 × 1 × 1 × 1 × 4 = 4 permutations.

## Group Lifecycle (VM Reuse)

VMs are created once per outer-loop group and reused across all (profile × block_size) permutations:

```
Group start (pool × vm_size × pvc_size × concurrency):
  Step 1: Render fio profile (first permutation)
    ├── Read fio-profiles/<profile>.fio
    ├── Substitute ${RUNTIME}, ${RAMP_TIME}, ${IODEPTH}, etc.
    └── If variable-BS profile, substitute ${BLOCK_SIZE}

  Step 2: Render cloud-init
    ├── Read cloud-init/fio-runner.yaml
    ├── Substitute __VM_NAME__, __TEST_DIR__, __SSH_PUB_KEY__, etc.
    └── Embed rendered fio job content (indented for YAML)

  Step 3: Create VMs (N = concurrency level)
    ├── Names: perf-<pool>-<size>-<pvc>-c<conc>-<i> (no profile/bs)
    ├── Render VM template, create cloud-init Secret, oc apply
    └── All VMs created before waiting

  Step 4: Wait for VMs to start
    ├── Poll each VMI for Running state
    ├── Timeout: VM_READY_TIMEOUT (default 600s)
    └── On timeout: log error, clean up, skip entire group

  Step 5: Wait for fio to complete (first run via cloud-init)
    ├── Poll perf-test.service status via virtctl ssh
    ├── Handles active/inactive/failed states (RemainAfterExit=yes)
    ├── Timeout: FIO_COMPLETION_TIMEOUT (default 900s)
    └── Uses associative array to track per-VM completion

  Step 6: Collect results
    ├── virtctl ssh → cat /opt/perf-test/results/*.json
    ├── Saved to results/<pool>/<vmsize>/<pvcsize>/<concurrency>/<profile>/<blocksize>/
    └── Also collects system info (lscpu, free, lsblk)

  For each subsequent (profile × block_size) permutation:
    Step 7: Render fio profile (same as Step 1)
    Step 8: Replace fio job in each VM via SSH
      ├── replace_fio_job() encodes content as base64
      └── Writes to /opt/perf-test/fio-job.fio via sudo tee
    Step 9: Restart fio service in each VM
      ├── restart_fio_service() cleans old test data and results
      └── Stops service, resets failed state, starts with --no-block
    Step 10: Wait for fio to complete (same as Step 5)
    Step 11: Collect results (same as Step 6)

  Step 12: Cleanup (once, after all permutations)
    ├── Delete all VMs (parallel, in background)
    ├── Delete data PVCs, root disk PVCs, DataVolumes
    ├── Wait for all deletions to complete
    └── 5-second pause to let storage settle
```

## Result Directory Structure

Results are organized hierarchically matching the test dimensions:

```
results/
├── rep3/
│   ├── small/
│   │   ├── 150Gi/
│   │   │   ├── 1/
│   │   │   │   ├── sequential-rw/
│   │   │   │   │   ├── 4k/
│   │   │   │   │   │   └── perf-rep3-small-150gi-c1-1-fio.json
│   │   │   │   │   ├── 64k/
│   │   │   │   │   └── 1M/
│   │   │   │   ├── random-rw/
│   │   │   │   ├── mixed-70-30/
│   │   │   │   ├── db-oltp/
│   │   │   │   │   └── native/
│   │   │   │   │       └── perf-rep3-small-150gi-c1-1-fio.json
│   │   │   │   ├── app-server/
│   │   │   │   └── data-pipeline/
│   │   │   ├── 5/
│   │   │   │   └── ...  (5 JSON files per test — one per VM)
│   │   │   └── 10/
│   │   ├── 500Gi/
│   │   └── 1000Gi/
│   ├── medium/
│   └── large/
├── rep2/
├── ec-2-1/
└── ...
```

## Interruption Handling

If the test suite is interrupted (Ctrl+C or SIGTERM):

1. The trap handler fires (`cleanup_on_exit`)
2. All VMs with the current run-id label are deleted (`--wait=false` for speed)
3. All PVCs with the current run-id label are deleted
4. The script exits

Results collected before the interruption are preserved in the `results/` directory.

## Next Steps

- [fio Profiles Reference](fio-profiles-reference.md) — What each profile tests
- [Project Architecture](project-architecture.md) — Overall design and libraries
- [Running Tests](../guides/running-tests.md) — Practical guide to execution
