# Scale Test Auto-Ramp Mode

**Date:** 2026-04-21
**Status:** Approved

## Problem

The current `--scale-test` mode runs a fixed number of VMs (default 200) at fixed IOPS rate tiers (500, 1000). This answers "what happens at 200 VMs?" but not the capacity planning question: **"how many VMs can this storage backend sustain at a given IOPS rate before latency degrades?"**

HCIBench (VMware's vSAN benchmark tool) answers this by ramping VM count upward until a latency SLA is breached. We need the same capability for ODF/File CSI/Block CSI on ROKS.

## Goals

- Automatically find the VM density ceiling for a given storage pool at a target per-VM IOPS rate
- Stop when p99 latency crosses a configurable SLA threshold
- Produce a ramp curve (VM count vs latency/IOPS) as CSV and interactive HTML report
- Reuse existing VM lifecycle, fio rendering, and result collection infrastructure

## Non-Goals

- Multi-pool sweeps in a single run (run separately per pool)
- Multiple fio profiles per ramp (use mixed-70-30-rated only)
- NFS tier sweep (dropped from scale-test, can be a separate mode later)
- Cumulative VM addition (each step is a clean measurement)

## CLI Interface

```bash
# Basic usage — ramp rep3 at 500 IOPS/VM, stop at p99 > 5ms
./04-run-tests.sh --scale-test --pool rep3

# Custom rate and SLA
./04-run-tests.sh --scale-test --pool rep3 --rate-iops 1000 --latency-sla 10

# Preview ramp plan
./04-run-tests.sh --scale-test --pool rep3 --dry-run
```

### Flags

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--scale-test` | Yes | — | Enable auto-ramp mode |
| `--pool <name>` | Yes (with --scale-test) | — | Storage pool to ramp |
| `--rate-iops <N>` | No | 500 | Per-VM IOPS cap (fio `rate_iops`) |
| `--latency-sla <ms>` | No | 5 | p99 latency threshold in ms |
| `--dry-run` | No | false | Preview ramp plan without creating resources |

Removed flags: `--vms` (ramp determines count automatically).

Mutual exclusivity: `--scale-test` is mutually exclusive with `--quick`, `--overview`, `--rank`.

## Ramp Algorithm

### Phase 1 — Doubling

Start at 1 VM and double each step until p99 breaches the SLA or VM creation fails (cluster resource exhaustion).

```
Step 1:  1 VM   → run fio → collect p99 → pass
Step 2:  2 VMs  → run fio → collect p99 → pass
Step 3:  4 VMs  → run fio → collect p99 → pass
Step 4:  8 VMs  → run fio → collect p99 → pass
Step 5: 16 VMs  → run fio → collect p99 → BREACH (p99 > 5ms)
```

### Phase 2 — Linear Backfill

Between last passing count and first failing count, step linearly with `step = max(1, gap / 4)`.

Example: gap = 16 - 8 = 8, step = 2:

```
Step 6: 10 VMs → pass
Step 7: 12 VMs → pass
Step 8: 14 VMs → BREACH
```

Result: **12 VMs is the capacity** at 500 IOPS/VM with p99 < 5ms.

### Termination Conditions

- **SLA breach**: p99 exceeds threshold. Phase 1 → enter Phase 2. Phase 2 → stop, report last passing count.
- **Resource exhaustion**: VM creation fails. Treat the failed count as the ceiling, backfill below it.
- **Step 1 breach**: Single VM already exceeds SLA. Stop immediately, report that the backend can't meet the SLA at this rate.
- **No breach through Phase 1**: If doubling reaches 256 VMs without breach, stop and report that the backend hasn't saturated at this rate. No backfill needed. The 256 hard cap prevents runaway resource consumption.

### VM Lifecycle Per Step

- Each step creates all VMs fresh (not cumulative on top of previous step's VMs)
- All VMs from the previous step are deleted before the next step starts
- This ensures each step is a clean, independent measurement without cross-step interference
- VM spec: `small:2:4Gi`, 150Gi PVC, QD32, numjobs=1, 10G fio file
- VM batching with `SCALE_VM_BATCH_SIZE` (default 20) for API server protection
- fio profile: `mixed-70-30-rated.fio` with `rate_iops=<configured value>`

### p99 Extraction

- Extract from each VM's fio JSON: `.jobs[0].write.clat_ns.percentile["99.000000"]`
- Convert nanoseconds to milliseconds
- Step p99 = **max** p99 across all VMs (worst-case, not average)
- A single VM with bad latency means the SLA is breached for the step

## Results Structure

```
results/<run-id>/scale-test/<pool>/
  step-001-vms/              # fio JSON from 1 VM
    scale-<pool>-c1-1-fio.json
  step-002-vms/              # fio JSON from 2 VMs
    scale-<pool>-c2-1-fio.json
    scale-<pool>-c2-2-fio.json
  step-004-vms/              # fio JSON from 4 VMs
    ...
  step-012-vms/              # backfill step
    ...
  ramp.csv                   # aggregated ramp data
  ramp-summary.json          # capacity result + metadata
```

### ramp.csv

```
vm_count,rate_iops,total_read_iops,total_write_iops,total_bw_mbs,avg_p50_ms,avg_p95_ms,max_p99_ms,sla_pass
1,500,350,150,1.95,0.8,2.1,2.3,true
2,500,700,300,3.91,0.9,2.3,2.5,true
4,500,1400,600,7.81,0.9,2.5,2.8,true
8,500,2800,1200,15.6,1.0,3.2,3.5,true
16,500,5500,2300,30.5,1.5,5.8,6.2,false
10,500,3500,1500,19.5,1.1,3.8,4.1,true
12,500,4200,1800,23.4,1.2,4.2,4.6,true
14,500,4900,2100,27.3,1.4,4.8,5.2,false
```

### ramp-summary.json

```json
{
  "pool": "rep3",
  "storage_class": "ocs-storagecluster-ceph-rbd-virtualization",
  "rate_iops": 500,
  "latency_sla_ms": 5,
  "capacity_vms": 12,
  "total_iops_at_capacity": 6000,
  "p99_at_capacity_ms": 4.6,
  "breach_vms": 14,
  "p99_at_breach_ms": 5.2,
  "steps": 8,
  "cluster_description": "IBM Cloud ROKS (...)",
  "run_id": "perf-20260421-...",
  "timestamp": "2026-04-21T..."
}
```

## HTML Report

Generated by `generate_scale_test_report()` in `lib/report-helpers.sh`. Same embedded-Python + Chart.js pattern as the ranking report.

**Output file:** `reports/scale-test-<pool>-<rate>iops-<run-id>.html`

### Content

1. **Header**: pool name, storage class, cluster description, rate_iops, SLA threshold, run timestamp
2. **Capacity summary box**: "Pool **rep3** supports **12 VMs** at 500 IOPS/VM (6,000 aggregate IOPS) before p99 latency exceeds 5ms"
3. **Ramp chart** (dual Y-axis Chart.js line chart):
   - X-axis: VM count
   - Left Y-axis: aggregate IOPS (read + write combined)
   - Right Y-axis: p99 latency (ms)
   - Horizontal dashed red line at the SLA threshold
   - Green dots for passing steps, red dots for breaching steps
   - Vertical dashed line at the capacity point (last passing count)
4. **Data table**: all steps with vm_count, target IOPS, achieved read/write IOPS, bandwidth, p50/p95/p99, pass/fail
5. **Footer**: link to CSV, run metadata

## Changes to Existing Code

### Modified Files

| File | Change |
|------|--------|
| `04-run-tests.sh` | Replace `SCALE_TEST_MODE` block (~lines 135-588) with auto-ramp logic. Remove `--vms` flag. Add `--rate-iops` and `--latency-sla` flags. Enforce `--pool` requirement. |
| `00-config.sh` | Add `SCALE_RATE_IOPS` (default 500), `SCALE_LATENCY_SLA_MS` (default 5). Remove `SCALE_TEST_VMS`. |
| `lib/report-helpers.sh` | Add `generate_scale_test_report()` function. |
| `05-collect-results.sh` | Add handling for `results/*/scale-test/` directory structure. |
| `run-all.sh` | Pass through `--rate-iops` and `--latency-sla`. Remove `--vms`. |
| `CLAUDE.md` | Update `--scale-test` documentation. |

### Unchanged

- `mixed-70-30-rated.fio` — no changes
- `render_fio_profile()`, `render_cloud_init()`, `create_test_vm()`, `collect_vm_results()` — reused as-is
- `SCALE_VM_BATCH_SIZE` — still used for batching VM creation at larger steps
- SSH timeout wrapping, signal handler cleanup — inherited

### Dropped

- `discover_scale_test_pools()` — pool is now explicit via `--pool`
- `run_scale_test_single_vm()` / Test #3 NFS tier sweep — separate concern
- `discover_dp2_tiers()` — goes with Test #3
- `--vms` flag and `SCALE_TEST_VMS` config
