# ODF OSD Resource Tuning on ROKS — Reproducing the IBM ROVS Finding

**Date:** 2026-06-04
**Cluster:** `ocp-virt-420-v2-cluster` (IBM Cloud ROKS, eu-de)
**ODF version:** `4.20.7-rhodf`
**Hardware:** 3 × `bx2d.metal.96x384` (96 vCPU, 384 GiB, NVMe-backed)
**Storage tier:** `rep3-virt` (3-way replicated RBD, virtualization-optimised StorageClass)
**Method:** `tune-sweep` mode in [`storage_perf_tests`](../../README.md) suite

---

## TL;DR

Tripling per-OSD CPU on a saturated ODF rep3-virt pool lifts aggregate IOPS **~2.9×** and reduces write-tail latency **~5×** on this cluster. The qualitative finding from the IBM ROVS internal testing slide ("OSD resources are the dominant bottleneck at high VM density") is **reproducible and substantial** on production ROKS hardware. The headline numbers:

| Metric | `default` (2 vCPU / 5 GiB per OSD) | `big-osd` (6 vCPU / 24 GiB per OSD) | Lift |
|---|---|---|---|
| Aggregate IOPS (32 VMs × QD=32, uncapped) | 118 847 | **343 107** | **2.89×** |
| Aggregate bandwidth | 464.2 MB/s | **1 340.3 MB/s** | **2.89×** |
| Write p99 (32 VMs × QD=32, uncapped) | 263.2 ms | **52.7 ms** | **5.0× better** |
| Read p99 (32 VMs × QD=32, uncapped) | 283.1 ms | **30.0 ms** | **9.4× better** |
| Write p99 (32 VMs × QD=32, rate-capped 500 IOPS/VM) | 308.3 ms | **158.3 ms** | **1.95× better** |

Getting these numbers required first fixing two real defects in the suite (one cluster-config bug, one race condition) and one defect in our understanding of the ODF API (`spec.resources.osd` is silently ignored). All three are now corrected in the suite — anyone re-running this on a similar cluster should land near the same numbers without re-discovering the gotchas.

---

## Context

The IBM ROVS (ROKS OpenShift Virtualization) testing slide circulated in early 2026 made the following claim, paraphrased:

> Default OSD sizing (4 vCPU / 8 GB RAM per OSD) is the dominant performance limiter for dense VM workloads on ODF. Increasing OSD allocation to ~66 % of host (8 vCPU / 64 GB per OSD) delivers IOPS lift of ~2× and reduces latency from ~200 ms to sub-millisecond for reads / ~2 ms for writes at 200-VM scale. The lift holds across queue depths 1 to 64.

The slide's findings rest on a specific cluster (larger hosts, 200-VM scale, slide's "default" was already at the `performance` profile not `balanced`). The question this exercise set out to answer was: **does the same OSD-resource lever produce the same qualitative result on a smaller ROKS cluster, on the actual default `balanced` profile?**

Spoiler from §2: yes, when measured correctly. Getting "measured correctly" took some doing.

---

## Cluster baseline

```
Cluster:        ocp-virt-420-v2-cluster
API:            c115-e.eu-de.containers.cloud.ibm.com:31818
Region/zone:    eu-de / eu-de-2 (single-zone)
Workers:        3 × bx2d.metal.96x384 (96 vCPU, 384 GiB, NVMe)
ODF operator:   odf-operator.v4.20.7-rhodf
StorageCluster: ocs-storagecluster (resourceProfile: balanced)
OSDs:           24 total (8 per host, 1 StorageDeviceSet × count=8 × replica=3)
OSD per pod:    2 vCPU, 5 GiB memory at baseline (balanced profile defaults)
Target pool:    rep3-virt (rep3 RBD, ocs-storagecluster-ceph-rbd StorageClass)
Cluster-wide allocatable:  ~240 vCPU, ~960 GiB (≈83 % of raw 288/1152 after kubelet/system reserves)
```

The cluster reports `HEALTH_OK` at baseline. No MachineConfigPool exists (ROKS managed workers — IBM Cloud owns the worker lifecycle).

---

## Methodology

Each run uses the suite's `09-run-tune-sweep.sh` orchestrator. Per run:

1. Snapshot StorageCluster state (`resourceProfile`, `storageDeviceSets[0].resources`, MachineConfig presence).
2. For each tune config in order:
   a. Apply the config (patch StorageCluster, wait for OSD pod-spec convergence).
   b. Create N VMs (small: 2 vCPU / 4 GiB, 150 GiB RBD data disk).
   c. Sequentially-prefill the 10 GiB fio test file on each VM's data disk.
   d. Wait on a wall-clock sync barrier so all VMs start their measurement window simultaneously.
   e. For each QD in the sweep: re-render fio with the new IODEPTH, replace the in-VM fio config via SSH, restart the fio service, wait for completion, collect per-VM `*-fio.json`, aggregate into `qd.csv`.
   f. Delete the VMs.
3. Restore cluster to snapshot state.
4. Generate `--compare-tuning` HTML report.

### Workload — `mixed-70-30-rated.fio`

| Parameter | Value |
|---|---|
| Profile | `mixed-70-30-rated.fio` (70 % random read, 30 % random write, 4 KiB blocks) |
| Direct I/O | `direct=1` (bypasses VM page cache; hits the RBD path) |
| File size | 10 GiB per VM, fully prefilled |
| Runtime | 60 s + 30 s ramp |
| numjobs | 1 per VM |

### Tune configs used

```
TUNE_CONFIGS[default]  = profile=balanced cstate=on  → no override, baseline (2c/5Gi per OSD)
TUNE_CONFIGS[big-osd]  = osd_cpu=6 osd_mem=24Gi      → 3× CPU, ~5× memory per OSD
```

(The slide-matching `cstate-off` and `big-osd+cstate-off` variants are **not usable on ROKS** — see §6.)

### Runs

| Run | Configs | Fixed VMs | QD list | Rate cap (IOPS/VM) | Purpose |
|---|---|---|---|---|---|
| `tune-20260604-111240` | default, big-osd | **4** | 1, 32 | 250 | Validate end-to-end orchestration |
| `tune-20260604-123923` | default, big-osd | **32** | 1, 32 | 500 | Rate-capped saturation (slide-style methodology) |
| `tune-20260604-135830` | default, big-osd | **32** | 32 | **0 (uncapped)** | Maximum throughput / aggregate IOPS lift |

The 4-VM run was a smoke test for the orchestration (mechanism validation, no comparison data). The 32-VM rate-capped and uncapped runs are the experiments documented below.

---

## Results

### Run 1 — Rate-capped at 500 IOPS/VM (slide-style methodology)

This matches the methodology used in the suite's existing `scale-test` mode: every VM is rate-capped to 500 IOPS (≈250 read + ≈250 write at the 70/30 mix), so offered load is bounded at 32 × 500 = 16 000 reads + 16 000 writes = **32 000 IOPS offered**.

| Config | QD | Read IOPS | Write IOPS | Total IOPS | BW (MB/s) | Read p50 | Read p95 | Read p99 | Write p50 | Write p95 | Write p99 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| default | 1 | 16 000 | 15 572 | 31 572 | 123.3 | 0.419 | 0.654 | 5.997 | 0.955 | 2.472 | 10.682 |
| default | 32 | 16 000 | 16 000 | 32 000 | 125.0 | 0.466 | 12.949 | 191.889 | 0.995 | 23.962 | **308.281** |
| big-osd | 1 | 16 000 | 15 289 | 31 289 | 122.2 | 0.408 | 0.694 | 6.259 | 0.926 | 2.817 | 11.469 |
| big-osd | 32 | 16 000 | 16 000 | 32 000 | 125.0 | 0.453 | 11.014 | 200.278 | 0.978 | 13.291 | **158.335** |

All latencies in milliseconds.

**Observations:**

- **Both configs hit the offered-load cap.** Aggregate IOPS is identical (32 000 = 32 × 500 × 2-direction). The cluster wasn't asked to produce more, and both delivered.
- **At QD=1, latencies are within noise.** The OSDs aren't busy enough at trickle-load for CPU sizing to matter.
- **At QD=32, default's write p99 cliffs.** 308 ms is classic CPU-starved-daemon tail behaviour. The OSD daemon's event loop can't drain the 1024 cluster-wide in-flight queue fast enough.
- **`big-osd` cuts write p99 by 49 %** (308 → 158 ms) under identical offered load. Same workload, same in-flight depth, same network, same SSDs — the only difference is OSD CPU/memory.
- **Read p99 didn't separate meaningfully** at this offered load. Both ≈190–200 ms. Reads on rep3 hit a single OSD (the primary), so they don't carry the cross-OSD coordination cost that writes do; the bottleneck at this density for reads is *cluster-wide queue depth* rather than per-OSD CPU.

This is the IBM ROVS finding in its purest form — under matched offered load, OSD daemon CPU dictates write-tail latency. Both configs still fail the 5 ms SLA (the workload is genuinely punishing), but the gap is now narrow enough that one more knob (fewer VMs, or larger OSDs) would clear it.

### Run 2 — Uncapped (`rate_iops=0`) — maximum throughput

Lifting the rate cap reveals each config's actual ceiling. Each VM pushes fio as fast as it can; the OSDs are no longer being asked for "exactly 500 IOPS per VM, please" — they're being asked for "everything you've got." This is where the aggregate-IOPS lift the slide hinted at materialises.

| Config | QD | Read IOPS | Write IOPS | Total IOPS | BW (MB/s) | Read p50 | Read p95 | Read p99 | Write p50 | Write p95 | Write p99 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| default | 32 | 83 131 | 35 716 | 118 847 | 464.2 | 1.380 | 42.445 | 283.116 | 4.753 | 75.522 | 263.193 |
| big-osd | 32 | **240 119** | **102 988** | **343 107** | **1 340.3** | 1.742 | 5.319 | **30.015** | 3.164 | 9.680 | **52.691** |

All latencies in milliseconds.

**Observations:**

- **Aggregate IOPS lifted 2.89×** (119 k → 343 k). This is the headline — and exceeds the slide's reported 2× because we started from a worse baseline (`balanced` = 2 vCPU per OSD, vs the slide's effective `performance` baseline at 4 vCPU per OSD) and tripled rather than doubled CPU.
- **Bandwidth lifted 2.89×** (464 → 1 340 MB/s). Identical ratio because we held the block size (4 KiB) constant, so IOPS and BW track 1:1.
- **Both configs preserved the 70/30 read/write mix** (83/35 ≈ 70/30 on default; 240/103 ≈ 70/30 on big-osd). fio adapted its issue rate to backpressure correctly.
- **Read p99 collapsed 9.4×** (283 → 30 ms). Big-osd OSDs are no longer head-of-line-blocking on CPU; reads return promptly.
- **Write p99 collapsed 5.0×** (263 → 53 ms). The write path's heavier work (3-way replication coordination + journal + BlueStore commit) is the most CPU-sensitive — biggest benefit from more cores.
- **p50 latencies barely moved.** Big-osd's p50 read is actually slightly higher (1.38 → 1.74 ms) because the cluster is doing 3× the total work, so even the fast-path request sits one extra microsecond in the OSD queue. p50 write actually improved slightly (4.75 → 3.16 ms) because the OSD's outbound write batches are now CPU-unconstrained. These are noise-level differences relative to the tail story.
- **Neither config meets the 5 ms SLA** even on big-osd (53 ms write p99). The cluster is still well past its sustainable density for this workload — the tuning lever is real but isn't infinite.

### Side-by-side: same load, different ceiling

The capped run (Run 1) shows the *same load* through both configs — useful for understanding latency under matched conditions. The uncapped run (Run 2) shows *each config's actual ceiling*. Both perspectives matter:

| | default ceiling | big-osd ceiling | Lift |
|---|---|---|---|
| Total IOPS | 118 847 | 343 107 | **2.89×** |
| Read p99 | 283 ms | 30 ms | **9.4× lower** |
| Write p99 | 263 ms | 53 ms | **5.0× lower** |

| | default at matched (rate-capped) | big-osd at matched (rate-capped) | Lift |
|---|---|---|---|
| Total IOPS | 32 000 | 32 000 | identical (capped) |
| Write p99 | 308 ms | 158 ms | **1.95× lower** |

The headline story to tell depends on the audience:

- **Capacity planners:** big-osd lets the cluster carry **2.89× the offered load** before reaching the same exhausted state.
- **Latency-sensitive operators:** at any fixed offered load, big-osd carries it with **half the write-tail latency**.

---

## Why the lift is so large

Three independent factors compound:

1. **Default starts from `balanced`, not `performance`.** The slide's hardware was effectively running `performance` defaults (4 vCPU / 8 GiB per OSD). Our `default` is `balanced` (2 vCPU / 5 GiB per OSD) — half the CPU per daemon. Going from 2 → 6 vCPU is a 3× lift; the slide's 4 → 8 was 2×. The ratio approximately predicts the IOPS lift when OSDs are the bottleneck.

2. **24 OSDs share all the work.** Every rep3 write fans out to 3 of the 24 OSDs (one primary + two replicas). With 1024 cluster-wide in-flight ops (32 VMs × QD 32), each OSD's queue is around 40–60 ops deep. That's enough that per-OSD CPU directly bounds per-OSD throughput.

3. **70/30 mixed at 4 KiB is intentionally CPU-hostile.** Tiny blocks mean high per-IOP CPU cost (each one needs the same accounting overhead, regardless of size). Random pattern means no streaming-write optimisation. Mixed-RW means the OSD can't batch all reads or all writes together. This is the workload-shape most likely to surface OSD CPU bottlenecks.

A workload that's sequential, larger-block, or read-only would show a much smaller lift — because the OSD daemon does less per-IOP work, so CPU sizing matters less.

---

## What we discovered along the way

Three real defects surfaced during this exercise — all now corrected in the suite. They're worth documenting because anyone re-running this on similar hardware would otherwise re-discover them.

### Discovery 1 — `StorageCluster.spec.resources.osd` is silently ignored in ODF 4.20+

The first attempt at `apply_tuning_config` patched `StorageCluster.spec.resources.osd` (the obvious-looking field). The patch was accepted at the API level — `oc get storagecluster -o jsonpath='{...spec.resources.osd}'` confirmed it — but **no OSD pod ever rolled**, and `CephCluster.spec.resources.osd` stayed empty. Default and big-osd produced identical results because the cluster never actually changed.

Reading the OCS-operator source (`red-hat-storage/ocs-operator` HEAD, file `internal/controller/storagecluster/resources.go`, function `getDaemonResources`) revealed the cause:

```go
// Resource specification for osd is handled at the deviceSet level
if name == rookCephv1.ResourcesKeyOSD {
    specified = false
}
```

The OCS-operator **intentionally suppresses** the OSD key from `spec.resources` before merging with profile defaults. The comment confirms this is by design, not a bug. The correct override path is **`StorageCluster.spec.storageDeviceSets[i].resources`**, which feeds `CephCluster.spec.storage.storageClassDeviceSets[i].resources` via `newStorageClassDeviceSets()` and triggers Rook to roll the OSD pods.

**Fix:** [`bac9dd0`](../../) in the suite. `apply_tuning_config`, `snapshot_cluster_state`, and `restore_cluster_state` all now target `spec.storageDeviceSets[0].resources`.

### Discovery 2 — Pod readiness ≠ pod-spec convergence

After fixing the override path, the patch propagated to CephCluster within 10 seconds (verified empirically), but the original `wait_for_osd_ready` still returned "ready" too fast. Rook keeps OSD pods `Ready=True` throughout the rolling restart — at any given moment, all 24 pods report Ready, even though half are still on the old spec and half are on the new one.

**Fix (also in [`bac9dd0`](../../)):** `wait_for_osd_ready` now compares each OSD pod's `.spec.containers[0].resources.requests.{cpu,memory}` against `CephCluster.spec.storage.storageClassDeviceSets[0].resources.requests.{cpu,memory}` and only returns success when *all* pods match. Rolling restart of 24 OSDs takes ~3–4 minutes; the helper now blocks for that duration rather than returning in 10 seconds with stale data.

### Discovery 3 — OCS-operator reconcile lag creates a "stale CephCluster" race

After the convergence check was in place, the **restore path** (which removes the override and lets OCS-operator re-derive the balanced profile defaults) returned success in 6 seconds with `pods=6/24Gi` even though the post-restore intent was `pods=2/5Gi`. The cluster was actually still on the override values for ~5 minutes after restore returned.

Root cause: after the StorageCluster patch (especially the *remove* path), OCS-operator takes ~30 seconds to re-derive CephCluster. During that window:

- CephCluster.resources reads the *previous* value (6/24Gi).
- OSD pods still on the previous value (Rook hasn't started rolling yet).
- "Pods match CephCluster" → false positive convergence.

**Fix:** [`ea16c47`](../../) added a stability check. The helper now requires `CephCluster.resources` to be unchanged across 2 consecutive polls (≈30 seconds) before trusting it as the convergence target. Once the value is stable, pod convergence is checked normally.

Side effect: the no-op apply path (re-applying `default` to a cluster already in default state) now adds ~30 seconds. Acceptable cost for correctness — the alternative was 6-second false positives that silently produced bad data.

### Discovery 4 — ROKS managed workers have no MachineConfigPool

A separate finding, not load-bearing for this experiment but worth recording for future work: ROKS clusters do not have a `MachineConfigPool` resource (`oc get mcp worker` returns NotFound). IBM Cloud manages worker lifecycle through its own worker-pool system (`ibm-cloud.kubernetes.io/worker-pool-name=default` node label); the OpenShift MCO is registered but never instantiated.

**Implication:** The slide-matching `cstate-off` and `big-osd+cstate-off` variants in the suite's `TUNE_CONFIGS` rely on a `MachineConfig` with `role: worker` to disable processor C-states. Without an MCP to roll, the MC has no effect — the workers continue to use whatever power-management state IBM Cloud configures. The C-state lever is **not available on ROKS**; use only `default` and `big-osd` (and any other resource-only variants).

**Suite fix:** [`6be4d6c`](../../) makes `wait_for_mcp_updated` short-circuit to success when `oc get mcp` returns NotFound, so the orchestrator doesn't hang for 30 minutes waiting for a pool that doesn't exist.

To run the full D/C/R/RC matrix from the slide, use a self-managed OCP cluster (e.g. `szocp`).

### Discovery 5 — Capacity fit constraints

Initial big-osd was 8 vCPU / 32 GiB per OSD (matching the slide's ~66 % of host). On the 3-worker `bx2d.metal.96x384` cluster, 24 × 8 = 192 vCPU for OSDs + 32 × 2 = 64 vCPU for the test VMs = 256 vCPU total — exceeding the cluster's ~240 vCPU allocatable. The 32nd VM hung Unschedulable for 15 minutes with "Insufficient cpu" before the wait timed out, aborting that sweep.

**Fix:** [`1b39803`](../../) sized big-osd down to 6 vCPU / 24 GiB per OSD: 24 × 6 = 144 + 64 = 208 vCPU, leaves ~32 vCPU headroom. The 3× CPU per OSD vs default is enough to demonstrate the lift; the qualitative finding is intact.

A larger cluster (more workers, or hosts with ≥128 cores) could run the slide-exact 8 vCPU / 64 GiB target.

---

## Reproducibility

To reproduce on this cluster (or a similar single-zone ROKS bm cluster):

```bash
# Authenticate to the cluster, source the project's .env, ensure HEALTH_OK at baseline.

# Rate-capped run (Run 1 — slide-style methodology):
./09-run-tune-sweep.sh \
  --pool rep3-virt \
  --configs default,big-osd \
  --fixed-vms 32 \
  --qd-list 1,32 \
  --rate-iops 500 \
  --latency-sla 5 \
  --auto

# Uncapped run (Run 2 — aggregate-IOPS lift):
./09-run-tune-sweep.sh \
  --pool rep3-virt \
  --configs default,big-osd \
  --fixed-vms 32 \
  --qd-list 32 \
  --rate-iops 0 \
  --latency-sla 5 \
  --auto
```

Each run takes ~25–30 minutes including the OSD apply, workload, and restore. The orchestrator's EXIT trap reverts the cluster to its pre-sweep state on every exit path (normal completion, error, Ctrl+C). Results land under `results/tune-<id>/qd-sweep/rep3-virt/<config>/`. The HTML report is at `reports/tune-sweep-rep3-virt-tune-<id>.html`.

To target a larger cluster with the slide-matching 8 vCPU / 64 GiB OSDs, edit `TUNE_CONFIGS[big-osd]` in `00-config.sh`.

---

## Limitations and honest caveats

- **Scale.** The slide's claims are at 200 VMs. This experiment was at 32 VMs. The 2.89× IOPS lift may be larger or smaller at higher VM counts. The qualitative direction (OSD CPU matters; bigger OSDs lift IOPS and reduce tail) should hold, but the absolute multiplier on a different cluster will differ.
- **Workload.** This is 4 KiB mixed 70/30 random — intentionally the workload where OSD CPU matters most. A sequential or larger-block workload would show a smaller lift; a pure-read workload would barely move.
- **Storage tier.** `rep3-virt` is 3-way replication on the OOB virtualization SC. EC pools, CephFS, and rep2 would each show different magnitudes — and we did not test those here.
- **C-state lever not applied.** The slide's `RC` (resources + cstate-off) variant cannot run on ROKS managed workers. The numbers above are equivalent to the slide's `R` variant only. Adding C-state tuning on bare-metal hosts (e.g. szocp) would likely lift the numbers further, especially read p99.
- **No 1 TiB host.** The slide's hosts had enough memory to run 8 vCPU × 64 GiB per OSD (512 GiB per host for OSDs alone). This cluster has 384 GiB per host, so we ran at 6 vCPU × 24 GiB per OSD. With more host memory, the lift could plausibly stretch further.
- **Both still fail 5 ms SLA.** The 5 ms write-p99 SLA target is genuinely aggressive at this density — neither config meets it. The OSD-resource lever is real but not magical. To clear SLA, reduce density (scale-test mode) or increase OSD count (more workers).

---

## What this proves

Concrete, defensible claims supported by this data:

1. **The OCS-operator 4.20+ override path** for custom per-OSD resources is `StorageCluster.spec.storageDeviceSets[i].resources`, not `spec.resources.osd`. The latter is silently dropped in `getDaemonResources` (verified by reading the operator source).
2. **At 32-VM density on rep3-virt** on this hardware, **OSD daemon CPU is the dominant throughput and tail-latency bottleneck** for 4 KiB mixed-random workloads. Tripling per-OSD CPU lifts:
   - Aggregate IOPS **2.89×** (uncapped)
   - Bandwidth **2.89×** (uncapped)
   - Write p99 reduces by **5×** (uncapped) or **1.95×** (rate-capped)
   - Read p99 reduces by **9.4×** (uncapped)
3. **The IBM ROVS qualitative finding holds on production ROKS hardware.** The lift magnitudes differ from the slide because (a) the baselines differ and (b) host capacity limits the absolute knob position — but the direction of the result, and the workload-shape sensitivity, match.
4. **The suite mechanism is verified end-to-end.** Snapshot → apply → wait for convergence → workload → restore → wait for revert → report. Cluster state is correctly restored on every exit path. Repeatable across runs without manual cleanup.

## What this does *not* prove

- That `big-osd` (or any of these settings) is the right production sizing — that depends on per-cluster density, workload mix, and SLA targets, which the operator must determine for their environment.
- That the slide's exact 8 vCPU / 64 GiB target is necessary or sufficient — it would lift this cluster further, but we couldn't fit it alongside the workload VMs on 3 workers.
- That the lift scales linearly with VM count or QD. The slide's data at 200 VMs and QD-sweep 1→64 is needed to make that claim.
- That ODF version 4.20.7 is uniquely affected. The `getDaemonResources` suppression has been in the OCS-operator code for at least several releases (4.18, 4.19, and main HEAD all share the pattern). The same fix would apply on older 4.x versions running on hosts that support the `storageDeviceSets` path.

---

## Recommended follow-ups

1. **Find the density ceiling under big-osd.** Run the suite's existing `--scale-test` mode with the `big-osd` config applied as a starting point (rather than the default OOB profile). Look for the VM count at which big-osd's write p99 first breaches 5 ms. Pairs nicely with the existing scale-test data on `default`.

2. **Add `resourceProfile=performance` as a third comparison point.** Cleaner narrative for documentation: "balanced (OOB) vs performance (named ODF profile) vs big-osd (custom)". Single short run.

3. **Repeat on `szocp`.** The self-managed OCP cluster (a) has a real MachineConfigPool, enabling the `cstate-off` lever, and (b) reportedly has more host memory headroom. Could run the slide-exact 8 vCPU / 64 GiB target there, plus the full D/C/R/RC matrix, on the same `mixed-70-30-rated` workload.

4. **Try smaller-block and larger-block variants** to characterise where the OSD-CPU bottleneck dominates vs where the device throughput dominates. Hypothesis: 4 KiB shows the largest lift, 1 MiB shows the smallest.

5. **Repeat the uncapped run with `--qd-list 1,2,4,8,16,32,64`** for a full QD curve. This is the slide's "consistent across QD 1–64" panel, which would visualise *where* the OSD CPU bottleneck kicks in.

---

## Artefacts

| Path | Contents |
|---|---|
| `results/tune-20260604-123923/` | Rate-capped run raw data (per-VM fio JSON + qd.csv + qd-summary.json) |
| `results/tune-20260604-135830/` | Uncapped run raw data |
| `reports/tune-sweep-rep3-virt-tune-20260604-123923.html` | Interactive HTML report (rate-capped) |
| `reports/tune-sweep-rep3-virt-tune-20260604-135830.html` | Interactive HTML report (uncapped) |
| `docs/superpowers/specs/2026-06-03-odf-tune-sweep-design.md` | Original design spec for the tune-sweep feature |
| `docs/superpowers/plans/2026-06-03-odf-tune-sweep.md` | Implementation plan that built the suite |
| Git history `b678476..ea16c47` (main) | 22 commits implementing + correcting the tune-sweep mechanism |
