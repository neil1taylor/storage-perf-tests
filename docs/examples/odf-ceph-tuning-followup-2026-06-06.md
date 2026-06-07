# ODF/Ceph Tuning Follow-Up — 2×2 Factorial on VM-Template + Ceph-Side Knobs

**Date:** 2026-06-06
**Cluster:** `ocp-virt-420-v2-cluster` (IBM Cloud ROKS, eu-de)
**ODF version:** `4.20.7-rhodf` (Ceph Reef 18.x)
**Hardware:** 3 × `bx2d.metal.96x384` (96 vCPU, 384 GiB, NVMe-backed), 24 OSDs
**Storage tier:** `rep3-virt` (3-way replicated RBD, virtualization-optimised StorageClass)
**Workload:** `mixed-70-30-rated.fio` — 70 % random read, 30 % random write, 4 KiB, uncapped, 32 VMs × QD=32
**Method:** `tune-sweep` mode in [`storage_perf_tests`](../../README.md) suite

**Related docs:**
- [Candidate tuning list](odf-ceph-tuning-candidates-2026-06-04.md) — the prior-run analysis that identified these knobs
- [2026-06-04 OSD-resource tuning writeup](odf-osd-resource-tuning-2026-06-04.md) — foundational experiment this builds on
- [Design spec](../superpowers/specs/2026-06-03-odf-tune-sweep-design.md) — 09-run-tune-sweep.sh architecture

---

## TL;DR

This experiment crossed two independent tuning axes — KubeVirt `ioThreadsPolicy=auto` + `blockMultiQueue=true` on the VM template, and a Ceph-side bundle of `mclock_profile=high_client_ops` + 256 KiB BlueStore throttles + 20 GB (~18.6 GiB) `osd_memory_target` — in a 2×2 factorial design, both stacked on the `big-osd` resource floor established on 2026-06-04.

The bottom line: **iothreads alone is a strong tail-latency win** — write p99 fell 25 %, read p99 fell 53 %, with a 2 % IOPS uptick. That change is merged. **The Ceph-side bundle alone gives a modest read-tail reduction** (29 %, close to the 30 % threshold) at a small IOPS cost (−3.8 %), with an important attribution caveat explained in §6. **The combined stack is a material regression across all three metrics**: IOPS −8.5 %, write p99 +67 %, read p99 +103 %. The interaction between the two knob sets is strongly negative — combining them produces worse outcomes than either alone, not additive improvement. The Ceph-side config is retained as an opt-in but is not being made default, and the combined stack is explicitly not recommended at this density.

---

## Cluster Baseline and Phase 0 Finding

Cluster was verified clean before Sweep A: all 24 OSD pods at `2 CPU / 5Gi` (balanced profile defaults), `HEALTH_OK`, and no leftover patches from the 2026-06-04 sweeps.

Phase 0 uncovered a meaningful anomaly: `osd_memory_target` was at the Reef default of **4 GiB** (`4294967296` bytes). On 384 GiB hosts, Reef's cgroup-ratio mechanism should dynamically target approximately ¼ of the OSD cgroup's available RAM — but that mechanism is not activating on these ROKS workers. The result is that prior `big-osd` data (the 2026-06-04 run) was collected with OSD memory effectively at the balanced-profile default (5 GiB), not the intended 24 GiB ceiling that the `osd_mem=24Gi` resource request enforced. The request provides headroom; the Ceph memory allocator still respects its own target.

To correct this, `TUNE_CONFIGS[big-osd+mclock]` was updated before Sweep A to add `cephconfig_osd_memory_target=20000000000` (20 GB, ~18.6 GiB — within the 24 GiB resource ceiling, leaving ~5.4 GiB for non-heap overhead). This change is bundled into the Ceph-side treatment (cells B and D) and is not independently isolated. The attribution caveat is discussed in §6 and §9.

The baseline drift check (cell A vs the 2026-06-04 big-osd baseline) came in at +3.5 %, well within the ±5 % sanity band, confirming measurement consistency across sweeps.

---

## Methodology

### Experimental design

A 2×2 full factorial crossing two binary factors:

| Factor | Level 0 | Level 1 |
|---|---|---|
| **VM template** | Baseline (`ioThreadsPolicy` absent, `blockMultiQueue` false) | iothreads (`ioThreadsPolicy=auto`, `blockMultiQueue=true`) |
| **Ceph-side** | big-osd only | big-osd + `mclock_profile=high_client_ops` + 256 KiB BlueStore throttles + 20 GB (~18.6 GiB) `osd_memory_target` |

This yields four cells:

| | big-osd | big-osd+mclock+memtarget |
|---|---|---|
| **VM base** | **(A)** | **(B)** |
| **VM iothreads** | **(C)** | **(D)** |

Both factors were built on the `big-osd` resource floor (6 vCPU / 24 GiB per OSD) established in the 2026-06-04 experiment. There is no `default`-profile leg here — the goal was to evaluate incremental knobs above the already-confirmed big-osd base, not re-measure the default/big-osd split.

### Execution

Two sweep runs, each covering two Ceph configs:

| Sweep | VM template | Configs covered | Cells |
|---|---|---|---|
| **Sweep A** (`tune-20260606-075823`) | Baseline (pre-iothreads commit) | big-osd, big-osd+mclock | A, B |
| **Sweep B** (`tune-20260606-082906`) | iothreads (post-commit) | big-osd, big-osd+mclock | C, D |

Per sweep: 32 small VMs (2 vCPU / 4 GiB, 150 GiB RBD data disk on rep3-virt), `mixed-70-30-rated.fio`, QD=32, uncapped, 60 s runtime + 30 s ramp. Each Ceph config triggers: apply → wait for all 24 OSD pods to converge → workload → collect → next config → restore.

---

## Results

### 4-cell matrix (32 VMs × QD=32, uncapped, rep3-virt)

| Cell | VM template | Ceph config | Total IOPS | Bandwidth (MB/s) | Write p99 (ms) | Read p99 (ms) |
|---|---|---|---|---|---|---|
| **A** | Baseline | big-osd | 355 169 | 1 387.4 | 50.594 | 39.059 |
| **B** | Baseline | big-osd+mclock+memtarget | 341 554 | 1 334.2 (−3.8 %) | 52.691 | 27.656 |
| **C** | iothreads | big-osd | 362 303 | 1 415.2 (+2.0 %) | 38.011 | 18.481 |
| **D** | iothreads | big-osd+mclock+memtarget | 324 995 | 1 269.5 (−8.5 %) | 84.410 | 79.167 |

Reference: 2026-06-04 big-osd baseline = 343 107 IOPS, write p99 = 52.691 ms, read p99 = 30.015 ms.

### Per-knob deltas (all vs cell A)

| Comparison | Description | IOPS delta | Write p99 delta | Read p99 delta |
|---|---|---|---|---|
| **C vs A** | iothreads alone | +7 134 (+2.0 %) | −12.583 ms (−24.9 %) | −20.578 ms (−52.7 %) |
| **B vs A** | Ceph-side alone | −13 615 (−3.8 %) | +2.097 ms (+4.1 %) | −11.403 ms (−29.2 %) |
| **D vs A** | Combined stack | −30 174 (−8.5 %) | +33.816 ms (+66.8 %) | +40.108 ms (+102.7 %) |

### Interaction term (D − C − B + A)

The interaction quantifies how much the combined stack deviates from the sum of the individual effects. A value of zero means the knobs are independent; positive means they interfere.

| Metric | Additive prediction (C+B−A) | Observed D | Interaction term |
|---|---|---|---|
| Total IOPS | 348 688 | 324 995 | **−23 693** (knobs fight each other) |
| Write p99 (ms) | 40.108 | 84.410 | **+44.302** (anti-additive) |
| Read p99 (ms) | 7.078 | 79.167 | **+72.089** (anti-additive) |

The interaction is uniformly negative. The combined stack does not combine the benefits — it produces a net regression on every metric.

---

## Observations

### iothreads alone (C vs A): the clear win

`ioThreadsPolicy=auto` on a 2-vCPU VM allocates one I/O thread per vCPU (2 total). Each I/O thread owns a virtio-blk queue; with `blockMultiQueue=true`, the QEMU device maps N queues on the guest block device, one per CPU core. The effect is that I/O is no longer serialised through a single QEMU event-loop thread — each vCPU can issue in parallel into its own virtio-blk queue.

At 32 VMs × QD=32, this reduces the latency added in the guest-to-host I/O path. The IOPS uptick (+2 %) is small because the cluster was already the bottleneck, not the QEMU path; the tail-latency improvements are where the benefit concentrates. Write p99 fell 25 % and read p99 fell 53 % — both substantially above the 20 % and 30 % significance thresholds used in the candidate evaluation. The asymmetry (reads improve more than writes) is consistent with iothreads reducing QEMU serialisation latency: reads are latency-bound by the full round trip (guest issue → host deliver → OSD → return), while writes get completion after replication so they already have higher inherent latency that dilutes the QEMU contribution.

### Ceph-side alone (B vs A): a modest read-tail improvement with caveats

`mclock_profile=high_client_ops` de-prioritises background work (scrubs, recovery, snap-trim) and biases QoS scheduling toward client I/O. The 256 KiB BlueStore throttle (`bluestore_throttle_bytes` and `bluestore_throttle_deferred_bytes`) tightens the maximum in-flight write payload queued inside each OSD's BlueStore layer — from the Reef default (~128 MiB) to 256 KiB — limiting how far a burst can run ahead of the journal commit.

The read p99 fell 29 % (cell B vs A: 39.059 → 27.656 ms). Read latency on a write-biased tightened-throttle config can improve because the OSD's BlueStore reader is no longer competing for the same byte budget with deep write queues. The write p99 rose 4 % (50.594 → 52.691 ms) — this is indistinguishable from noise at the ±5 % band.

**Attribution caveat:** the `osd_memory_target=20 GB (~18.6 GiB)` lift is bundled into the B/D treatment. The 2026-06-04 big-osd run had an effective 4 GiB memory target (Ceph default, cgroup-ratio inactive). Cell A (Sweep A big-osd) also had a 4 GiB target — the Phase 0 edit applied only to `big-osd+mclock`. So cells A and C are clean: big-osd at 4 GiB target. Cells B and D include the 20 GB (~18.6 GiB) lift alongside mclock and BlueStore throttle. The read p99 improvement in B could partially reflect the memory target — a larger OSD cache reduces read amplification — not mclock or the throttle alone. Separating the three Ceph-side changes would require an additional sweep.

### Combined stack (D vs A): the interesting regression

Cell D combines cells B and C: iothreads on the VM plus mclock + 256 KiB throttle + 20 GB (~18.6 GiB) memory on the Ceph side. The result is worse than either knob alone on every metric.

The most likely mechanism: iothreads raises the effective concurrency fan-in to the OSD. With the baseline VM template (single I/O thread), each VM's 32 in-flight ops are queued behind a single QEMU event-loop thread — they arrive at the OSD in bursts, but with implicit serialisation in the guest path. With `ioThreadsPolicy=auto` and 2 I/O threads, the same 32 in-flight ops arrive at the OSD more uniformly and more concurrently from each VM. Across 32 VMs, the OSD sees a higher sustained arrival rate with fewer natural pauses.

At `bluestore_throttle_bytes=262144` (256 KiB), the BlueStore write buffer allows approximately 64 × 4 KiB ops at any moment before throttling the next write submission. With the default throttle (~128 MiB), a multi-IOThread burst from 32 VMs can absorb into the buffer easily; with the 256 KiB throttle, those same bursts immediately hit back-pressure and queue in the OSD's message queue rather than the BlueStore buffer. The result is increased queueing latency at the OSD layer for writes, which then bleeds into reads because the OSD thread pool is spending more time processing queued writes.

In short: iothreads increases the offered-load concurrency per VM, and the tightened throttle becomes the binding constraint precisely because of that increased concurrency. The `high_client_ops` mclock profile does not compensate — at 32-VM uncapped load, client I/O is already the dominant traffic class, so the mclock bias has nothing to de-prioritise that would help.

This is a canonical example of two individually-sensible knobs conflicting at their operating point. The iothreads improvement comes from removing a serialisation bottleneck in the guest path; the BlueStore throttle improvement comes from bounding OSD buffer depth — and increasing guest concurrency is exactly what makes the buffer bound active.

---

## Outcome Classification

Using the four-category framework from the candidate evaluation:

| Knob set | IOPS | Write p99 | Read p99 | Classification |
|---|---|---|---|---|
| iothreads alone (C vs A) | +2.0 % (null) | −24.9 % (**big win** ≥20 %) | −52.7 % (**big win** ≥30 %) | **Tail-latency big win** |
| Ceph-side alone (B vs A) | −3.8 % (null) | +4.1 % (noise/null) | −29.2 % (modest win, near 30 %) | **Mixed** — modest read-tail win, bundled attribution |
| Combined stack (D vs A) | −8.5 % (**regression** >5 %) | +66.8 % (**regression**) | +102.7 % (**regression**) | **Regression** |

### Decisions

- **iothreads change is merged.** The VM-template commit (`ioThreadsPolicy=auto`, `blockMultiQueue=true`) is in the integration branch. The tail-latency improvement is clear and consistent.
- **`TUNE_CONFIGS[big-osd+mclock]` is retained as an opt-in config** in `00-config.sh`, but is **not made default**. The read-tail improvement is real but carries bundled attribution (mclock + throttle + memory target), and the small IOPS regression means it is not obviously better than big-osd alone for all workloads.
- **The combined stack (`big-osd+mclock` with iothreads VM template) is explicitly not recommended** at 32 VMs × QD=32 on rep3-virt. The interaction is anti-additive on every measured metric.
- **A follow-up sweep** (§11) that separates `osd_memory_target` from the mclock/throttle bundle would clarify attribution in the Ceph-side treatment. This is unfinished work.

---

## Reproducibility

```bash
# Authenticate to ocp-virt-420-v2-cluster, source .env, verify HEALTH_OK.

# Sweep A — VM baseline (pre-iothreads commit), Ceph configs: big-osd and big-osd+mclock
./09-run-tune-sweep.sh \
  --pool rep3-virt \
  --configs big-osd,big-osd+mclock \
  --fixed-vms 32 \
  --qd-list 32 \
  --rate-iops 0 \
  --auto
# Run ID: tune-20260606-075823

# Sweep B — VM iothreads (post-commit), same Ceph configs
./09-run-tune-sweep.sh \
  --pool rep3-virt \
  --configs big-osd,big-osd+mclock \
  --fixed-vms 32 \
  --qd-list 32 \
  --rate-iops 0 \
  --auto
# Run ID: tune-20260606-082906
```

Each sweep takes approximately 35–45 minutes including OSD apply (both configs), workload, OSD restore, and report generation. The EXIT trap reverts the cluster on every exit path. Cell A and C data are collected in separate sweep runs (not from the same orchestrator invocation), which means there is inherent cross-run noise; the ±5 % drift check (§3) confirms the noise is within an acceptable band.

---

## Limitations

- **Single QD point.** All data is at QD=32. The interaction term could differ at lower queue depths where BlueStore throttle pressure is less. A QD sweep would reveal whether the regression is specific to high fan-in or structural.
- **Single workload shape.** `mixed-70-30-rated.fio` at 4 KiB is chosen to be CPU-hostile and tail-sensitive, but results will differ for sequential, larger-block, or read-dominated workloads.
- **Single PVC size and VM count.** 150 GiB PVCs, 32 VMs. The iothreads benefit could scale or diminish with VM count; 32 VMs at 2 vCPU each is a mid-density point.
- **Small VMs only.** `ioThreadsPolicy=auto` on a 2-vCPU VM gives 2 IOThreads. On a 4- or 8-vCPU VM the thread count would increase; the interaction with the BlueStore throttle could be stronger or weaker, and the iothreads benefit could differ.
- **Bundled Ceph-side attribution (cells B and D).** The three Ceph-side changes (mclock profile, BlueStore throttle, osd_memory_target) are not independently isolated. The read p99 improvement in cell B could be partially or predominantly driven by the memory target lift rather than mclock or throttle. A follow-up splitting `osd_memory_target` into its own cell would clarify.

---

## Artefacts

The canonical sweep result directories (`results/tune-20260606-075823/` and `results/tune-20260606-082906/`) and the per-sweep HTML reports were written into a git worktree that was removed after the merge, before being copied to the main checkout. The headline numbers in this writeup were extracted from `qd-summary.json` and `qd.csv` before the cleanup; the orchestrator logs and the per-cell delta computation survived in scratch and are preserved here:

```
docs/examples/artefacts/odf-ceph-tuning-followup-2026-06-06/
  sweep-a.log               ← full Sweep A orchestrator log (run-id tune-20260606-075823)
  sweep-b.log               ← full Sweep B orchestrator log (run-id tune-20260606-082906)
  deltas.txt                ← /tmp/deltas.txt — 4-cell matrix + per-knob deltas + interaction term
  phase0-observations.md    ← Phase 0 cluster verification notes (osd_memory_target=4 GiB finding)

docs/examples/odf-ceph-tuning-candidates-2026-06-04.md  ← candidate shortlist
docs/examples/odf-osd-resource-tuning-2026-06-04.md     ← prior big-osd baseline writeup
docs/superpowers/specs/2026-06-05-odf-ceph-tuning-followup-design.md  ← spec
docs/superpowers/plans/2026-06-05-odf-ceph-tuning-followup.md         ← implementation plan
```

The lost artefacts are reproducible by re-running the sweeps per the §Reproducibility commands above (~1 h cluster contact for both sweeps combined).

---

## Cross-references

**Backward:**
- [2026-06-04 OSD-resource tuning writeup](odf-osd-resource-tuning-2026-06-04.md) — establishes the big-osd base that this experiment builds on; documents the five discoveries (spec.resources.osd ignored, pod-readiness vs spec-convergence race, OCS-operator reconcile lag, ROKS no-MCP, capacity fit).
- [Candidate tuning list](odf-ceph-tuning-candidates-2026-06-04.md) — identifies iothreads and mclock+throttle as the highest-priority candidates coming out of the 2026-06-04 data; provides the outcome-classification framework used in §7.

**Forward (hypothetical follow-up work):**
- A three-way factorial separating `osd_memory_target` from `mclock_profile + bluestore_throttle` would resolve the attribution ambiguity in cell B, and would answer whether the memory target alone explains the read p99 improvement.
- A QD sweep (QD = 1, 2, 4, 8, 16, 32, 64) with the iothreads-enabled VM template would characterise whether the iothreads benefit scales with queue depth — specifically whether the BlueStore throttle interaction is depth-sensitive.
- Testing on larger VMs (4 or 8 vCPU) would determine whether `ioThreadsPolicy=auto` provides proportionally more benefit or whether the BlueStore throttle conflict intensifies at higher thread counts.
