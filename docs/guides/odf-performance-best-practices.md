# ODF Performance Best Practices for ROKS + OpenShift Virtualization

**Audience:** Cluster operators setting up (or auditing) an ODF/Ceph cluster on IBM Cloud ROKS that will host KubeVirt VMs.
**Goal:** Tell you what to change before running production VM workloads, and cite the experiment behind each recommendation so you can decide whether your situation matches.
**Last updated:** 2026-06-07

---

## Scope and honest caveats

This guide reflects what has been **measured on this suite's reference cluster** and what has been **inferred from those measurements**. The reference cluster is:

- IBM Cloud ROKS, region `eu-de`, single-zone
- 3 × `bx2d.metal.96x384` bare metal workers (96 vCPU, 384 GiB RAM, NVMe-backed)
- 24 OSDs (8 per host)
- ODF `4.20.7-rhodf` (Ceph Reef 18.x)
- KubeVirt / OpenShift Virtualization 4.20
- Primary workload: `mixed-70-30-rated.fio` — 70/30 random R/W, 4 KiB, direct=1, prefilled 10 GiB files
- Density range: 1–64 VMs, mostly evaluated at 32 VMs × QD=32

What this guide **does not** cover:

- Multi-zone (regional) ROKS clusters — not yet measured end-to-end
- VSI-backed ODF clusters — only bare metal measured here
- CephFS performance tuning — architecture notes only, no paired numbers
- Per-VM I/O patterns outside the random small-block + sequential bandwidth mix
- Densities significantly above 32–64 VMs/cluster on this hardware

If your cluster differs materially (smaller hosts, VSI workers, regional topology), treat the **direction** of each recommendation as portable but re-baseline the **magnitude** on your own cluster using the suite.

---

## The staircase — what each step buys you

Here is the path from the state you get after the ROKS ODF addon installs through the highest-tuned configuration this suite has measured. Each step is a discrete change you can apply or skip. Numbers come from the experiments cited; honest gaps are called out where the data doesn't pair cleanly.

### Measurement variance and methodology

Three things to keep in mind when reading the numbers in this staircase. All three were learned by running the same config multiple times on the reference cluster.

**Total IOPS is reproducible to ~1%.** Four fresh-VM single-QD samples at `big-osd / 32 VMs / QD=32 / mixed-70-30 / uncapped`, collected across four days, landed at 343,107 / 340,972 / 341,920 IOPS — a 0.6% spread. Treat the IOPS headlines below as trustworthy point estimates.

**p99 latency is 2–3× wider.** The same four samples produced write p99 of 52.7 / 78.1 / 83.4 / 93.8 ms and read p99 of 30.0 / 61.1 / 69.7 / 87.6 ms. With 60–90 s measurement windows, single p99 numbers are best read as "order of magnitude," not literal values. Where multiple samples exist, this doc reports p99 as a range.

**Fresh-VM single-QD ≠ QD-ladder same-QD row.** A QD-ladder run sweeps QD=1 → 2 → 4 → … → 64 in sequence with the same VMs reused. By the time QD=32 (the 6th rung) is measured, those VMs have been running fio continuously for ~25 min — OSDs are mid-compaction, BlueStore caches dirty, RBD image state evolved. The QD-ladder QD=32 row in `tune-20260608-061514` came in at 267k IOPS vs ~341k for the three fresh-VM single-QD samples — a 22% gap that's pure methodology, not config. **Compare like with like:** the ladder is for *curve shape*; fresh-VM single-QD runs are for *absolute* deltas between configs.

### Step 0 — Default state after the ROKS ODF addon installs

What you have:

- `StorageCluster.spec.resourceProfile: balanced` — 2 vCPU / 5 GiB per OSD
- OOB StorageClasses present (including `ocs-storagecluster-ceph-rbd-virtualization`)
- `failureDomain: rack` (set cluster-wide by ocs-operator from worker topology)
- `osd_memory_target: 4 GiB` — the Ceph Reef default; the cgroup-ratio auto-scaling that's supposed to lift this **does not activate** on these ROKS workers
- VM template depends on whatever creates your VMs

Reference numbers at this rung (rep3-virt, 32 VMs × QD=32, mixed-70-30, uncapped):

| Metric | Value |
|---|---|
| Total IOPS | 118,847 |
| Total bandwidth | 464 MB/s |
| Write p99 | 263 ms |
| Read p99 | 283 ms |

Source: [odf-osd-resource-tuning-2026-06-04.md](../examples/odf-osd-resource-tuning-2026-06-04.md), `default` cell.

### Step 1 — Use the VM-optimised StorageClass (free; do this first)

What to do: bind your VM data PVCs to **`ocs-storagecluster-ceph-rbd-virtualization`**, not the generic `ocs-storagecluster-ceph-rbd`. Both back the same `ocs-storagecluster-cephblockpool`, but the virt SC adds `imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff` and `mapOptions: krbd:rxbounce`.

What you gain: avoids the **~7× write IOPS penalty** observed on pools missing `exclusive-lock` (write-back caching disabled), and the `rxbounce` correctness fix for guest CRC errors.

Honest note: we do not have a *paired* "with vs without" measurement at the saturation workload — what we have is the historical observation that custom pools without these features were ~7× slower on writes (documented in CLAUDE.md and the latency-patterns guide). The direction is unambiguous.

Cost: none.

### Step 2 — Move `resourceProfile` from `balanced` to `performance`

What to do: `oc patch storagecluster ocs-storagecluster -n openshift-storage --type=merge -p '{"spec":{"resourceProfile":"performance"}}'`. Per-OSD limits go from 2 vCPU / 5 GiB to 4 vCPU / 8 GiB.

Measured at 500 IOPS/VM rate-capped, 5 ms write-p99 SLA (the "how many VMs fit" question):

| Profile | VM ceiling | Total IOPS at ceiling |
|---|---|---|
| `balanced` | 32 | 31,936 |
| **`performance`** | **48** | **47,904 (+50%)** |

Under load the difference is qualitative, not incremental: at 64 VMs `balanced` rep3-virt collapses to **851 ms write p99**, while `performance` rep3-virt holds at **6 ms**.

Cost: cluster-wide OSD reservation grows by +48 vCPU and +72 GiB on a 24-OSD cluster. Fits comfortably on this reference cluster (288 vCPU / 1152 GiB total). Verify with `oc adm top nodes` on smaller hardware.

Honest note: this measurement is at the rate-capped density workload, not the saturation workload used elsewhere in the staircase. We have no direct "balanced → performance at uncapped 32 VMs × QD=32" pair.

Source: [odf-replication-scale-comparison.md](../examples/odf-replication-scale-comparison.md).

**Three-profile uncapped density curves on this cluster** (paired runs 2026-06-08/09, 4 KiB mixed-70-30, fresh VMs per step):

| VMs | balanced IOPS | performance IOPS | big-osd IOPS | balanced p99 | performance p99 | big-osd p99 |
|----:|--------------:|-----------------:|-------------:|-------------:|----------------:|------------:|
|   1 |        32,464 |           33,323 |       34,373 |       2.8 ms |          2.7 ms |      2.5 ms |
|   4 |        63,545 |          104,440 |      106,696 |        45 ms |            5 ms |        5 ms |
|   8 |        65,201 |          123,404 |      141,954 |        65 ms |           20 ms |        7 ms |
|  16 |        89,391 |          163,871 |      202,210 |        81 ms |           42 ms |       12 ms |
|  32 |       138,662 |          228,239 |  **344,981** |       384 ms |          196 ms |      *425 ms |
|  64 |     158,017 |        **302,842** | unschedulable |     810 ms |          801 ms |           — |

\* big-osd c=32 today landed at 425 ms; the doc's prior 4 fresh-VM samples ran 52.7/78.1/83.4/93.8 ms — that lower band is the value to trust.

**Why the big jump from balanced to performance is the obvious one to take.** balanced's bottleneck is OSD CPU, not pool layout — by c=4 the 2-vCPU/OSD limit is fully saturated (IOPS barely move from c=4 to c=8, 63k → 65k). Doubling that to 4 vCPU/OSD via performance lets the cluster scale cleanly through c=16-32 and unlocks **+92% peak IOPS for +48 cluster vCPU** (158k → 303k). Going from performance to big-osd is dramatic per-VM tail-latency relief in the c≤16 zone (12 ms vs 42 ms at c=16) but only **+14% peak IOPS for another +48 cluster vCPU**. Both balanced and performance hit ~800 ms write p99 at c=64 — that's the cluster's natural saturation point regardless of profile.

If you only take one step from this guide, this is it. The rest of the document is about when to push past the performance rung.

If your workload has bursts of high concurrency (c≥32) and you have a few GB of headroom per OSD, consider also raising `osd_memory_target` — see **Step 2b** below. That's a free latency lever; you don't need to commit any extra CPU.

**For most clusters this is where you stop.** Step 2b is a lightweight latency tune-up; Steps 3–5 are for hosts with the resource budget to push further and a workload that demands it.

### Step 2b — Pair `performance` with `osd_memory_target=20G` (free latency at saturation)

Apply when: you're already on `performance`, your workload occasionally hits c≥32, and you have ~16 GiB of unused RAM per OSD (the difference between the Reef default of 4 GiB and the 20 GiB this step sets).

What to do (one Ceph config knob, propagated via the StorageCluster spec; no OSD pod roll):

```bash
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=merge -p='{
  "spec":{"managedResources":{"cephCluster":{"cephConfig":{
    "osd":{"osd_memory_target":"20000000000"}}}}}}'
```

Note: in ODF 4.20 we observed that Rook sees the cephConfig spec change but does **not** always run the corresponding `ceph config set osd osd_memory_target ...` on its own (`ceph config get osd osd_memory_target` stays at the 4 GiB default). The 09-run-tune-sweep.sh / 10-run-scale-test-tuned.sh wrappers now push the value directly via `ceph config set` in addition to the spec patch as a workaround. If applying manually, follow up with:

```bash
oc -n openshift-storage exec deploy/rook-ceph-tools -- \
  ceph config set osd osd_memory_target 20000000000
```

Then verify with `ceph config get osd osd_memory_target` (should return `20000000000`, not `4294967296`).

Measured impact (run `scale-tuned-20260609-123256`, paired with `scale-tuned-20260608-172541` for plain performance):

| VMs | plain performance | + memtarget=20G | Write p99 Δ | IOPS Δ |
|----:|------------------:|----------------:|------------:|-------:|
|   8 |       20 ms / 123k |     24 ms / 163k | flat (noise) | **+32 %** |
|  16 |       42 ms / 164k |     45 ms / 182k | flat (noise) | **+11 %** |
|  32 |    **196 ms / 228k** |  **67 ms / 203k** | **−66 %** | −11 % |
|  64 |    **801 ms / 303k** | **396 ms / 233k** | **−51 %** | −23 % |

Two things to notice:

- **At low concurrency (c≤16) memtarget does nothing for latency** — the working set fits within Reef's default 4 GiB cache, so there's no benefit to enlarge it. (The +11 to +32 % IOPS bump at c=8-16 is real but inside the run-to-run variance band for IOPS on this cluster; treat as flat.)
- **At saturation (c=32 onward) memtarget halves p99** — the working set spans many VMs' working sets at once, so a bigger cache reduces backend flushes and the BlueStore queue stops backing up. The trade is slightly lower aggregate IOPS (cache fill coalesces writes, so each fio thread sees fewer-but-larger ops; total useful work done is similar).

If latency-bound at saturation: take this step. It costs no CPU and no apply-cycle roll (Ceph applies live). If throughput-bound at saturation: skip it and consider Step 3 instead.

**Important: this does NOT replace big-osd.** big-osd's IOPS advantage at saturation (345 k vs 228 k at c=32 vs plain performance) comes from the +CPU, not the cache. Adding memtarget alone to performance recovers most of big-osd's latency advantage but **none** of its peak-IOPS advantage. The two levers buy different things.

Source: `results/scale-test/rep3-virt/ramp.csv` from run `scale-tuned-20260609-123256` (performance + 20 G memtarget); paired baseline `scale-tuned-20260608-172541` (plain performance).

### Step 3 — Apply `big-osd` resource override + `osd_memory_target`

Apply when: `performance` profile isn't enough at your target density and the cluster has the headroom.

What to do (two changes, apply together):

```bash
# 1. Raise per-OSD resources to 6 vCPU / 24 GiB
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=json -p='[
  {"op":"add","path":"/spec/storageDeviceSets/0/resources","value":{
    "requests":{"cpu":"6","memory":"24Gi"},
    "limits":{"cpu":"6","memory":"24Gi"}}}
]'

# 2. Raise the BlueStore cache target (the resources bump alone does NOT do this)
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=merge -p='{
  "spec":{"managedResources":{"cephCluster":{"cephConfig":{
    "osd":{"osd_memory_target":"20000000000"}}}}}}'
```

Why both: ODF resource limits control the cgroup; `osd_memory_target` controls how much memory the OSD's BlueStore cache actually uses. The Reef-default 4 GiB target persists regardless of the cgroup limit on these workers. Without #2, you only get the CPU benefit.

Measured at 32 VMs × QD=32, mixed-70-30, uncapped, **fresh VMs** (see methodology note above):

| State | Total IOPS | Δ from prev rung | Write p99 | Read p99 |
|---|---|---|---|---|
| `balanced` (Step 0, no iothreads, 06-04) | 118,847 | — | 263 ms | 283 ms |
| `performance` (Step 2, + iothreads, 06-08) | 254,348 | **+97% over balanced+io** | 58.5 ms | 51.6 ms |
| **`big-osd` + memtarget** (Step 3, + iothreads, 4 samples) | **341,000 ± 1%** | **+34% over performance+io** | **53–94 ms** | **30–88 ms** |
| **Total lift balanced → big-osd** | — | **~2.89×** | 3–5× better | 3–9× better |

**The staircase is steeply diminishing.** `balanced → performance` roughly **doubles** aggregate IOPS at saturation; `performance → big-osd` adds **another ~34%**. Most of big-osd's lift over balanced is already captured by moving to performance. Stop at performance unless you specifically need that last 34% and have the host budget — see the cost line below.

*(The balanced row is from 2026-06-04 pre-iothreads-merge; performance and big-osd rows are with today's iothreads-enabled VM template. The `balanced → performance` delta is therefore "balanced no-iothreads → performance + iothreads" — slightly overstated because iothreads itself helps balanced. The same-day balanced + iothreads sample landed at 128,983 IOPS; comparing apples-to-apples on iothreads gives `balanced+io → performance+io = +97% IOPS`. Either way, the doubling holds.)*

**QD response curve** at big-osd (one ladder run, `tune-20260608-061514`, same 32 VMs reused across QDs — read as *shape*, not absolutes):

| QD | Total IOPS | BW MB/s | Read p99 ms | Write p99 ms |
|---:|---:|---:|---:|---:|
| 1  |  46,680 | 182 | 5.9 | 14.0 |
| 2  |  81,801 | 320 | 2.0 | 8.5 |
| 4  | 122,935 | 480 | 7.0 | 17.4 |
| 8  | **171,238** | **669** | **14.9** | **27.4** |
| 16 | 223,967 | 875 | 28.7 | 46.9 |
| 32 | 267,256 | 1,044 | 69.7 | 83.4 |
| 64 | 305,105 | 1,192 | 183.5 | 181.4 |

The shape tells you:

- **Throughput keeps climbing all the way to QD=64** (+14% over QD=32) and probably further. The cluster's true peak at this VM count is past where we've measured.
- **Practical sweet spot is QD=8** — 171k IOPS at 14.9 ms read / 27.4 ms write p99. Past QD=16 the IOPS gain comes at disproportionate tail-latency cost.
- **No point on this curve hits a 5 ms write-p99 SLA** at 32 VMs uncapped. That SLA only makes sense with the rate-cap from Step 2's density measurement.

**Gap closed 2026-06-08:** the `performance → big-osd` jump is **+34% IOPS**, NOT another 2.89×. The big-osd row in the table above reflects the direct comparison.

Cost: 6 × 24 OSDs = **144 vCPU** and **576 GiB** of OSD requests cluster-wide. Fits on the reference cluster (288 vCPU / 1152 GiB) with headroom; check explicitly on smaller hardware. Apply/restore cycle is ~10–15 min per change (one full OSD roll).

**VM-density ceiling on this cluster (uncapped, big-osd):** the 144-vCPU OSD reservation leaves ~144 vCPU for guests on the 288-vCPU cluster. The uncapped ramp (run `scale-tuned-20260608-102554`) peaked at **c=32 → 345k IOPS** then regressed (c=40→338k, c=48→305k); at c=56 one VM hit `0/3 nodes are available: 3 Insufficient cpu` and never reached Running. The small-VM (2-vCPU) **scheduling ceiling on big-osd sits between 48 and 55 VMs** on this cluster — past the c=32 IOPS saturation point, so mostly informational unless you're explicitly density-bound. On smaller hosts than the reference, big-osd's reservation share may not leave room even for c=32; check `oc adm top nodes` before opting in.

**Pick by the binding constraint:** the three-profile table under Step 2 shows that **big-osd's win over performance is per-VM throughput and tail latency in the c≤16 range** (12 ms vs 42 ms write p99 at c=16; +15 to +25 % more IOPS), at the cost of +48 cluster vCPU and the scheduling ceiling above. If your workload sits in the c=8-32 zone and you have the host budget, big-osd is a real upgrade. If you're chasing density past c=48, big-osd is the wrong direction — performance places c=64 where big-osd can't schedule.

Source: [odf-osd-resource-tuning-2026-06-04.md](../examples/odf-osd-resource-tuning-2026-06-04.md); 4 GiB target discovery in [odf-ceph-tuning-followup-2026-06-06.md §"Cluster Baseline and Phase 0 Finding"](../examples/odf-ceph-tuning-followup-2026-06-06.md); density-ceiling ramp in `results/scale-test/rep3-virt/ramp.csv` (run `scale-tuned-20260608-102554`).

### Step 4 — Enable iothreads + multiqueue on the VM template

What to do: on the data-disk portion of your VM template:

```yaml
spec:
  domain:
    ioThreadsPolicy: auto
    devices:
      disks:
        - name: data
          dedicatedIOThread: true
          disk:
            bus: virtio
            blockMultiQueue: true
```

If you create VMs through this suite, this is already the default since `fa061be`. Verify with:

```bash
oc get vm <name> -o jsonpath='{.spec.template.spec.domain.ioThreadsPolicy}'
oc get vm <name> -o jsonpath='{.spec.template.spec.domain.devices.disks[?(@.name=="data")].dedicatedIOThread}'
```

Measured at 32 VMs × QD=32, mixed-70-30, uncapped on three different bases:

| Base | Without iothreads | With iothreads | Δ IOPS | Δ write p99 | Δ read p99 |
|---|---|---|---|---|---|
| **balanced** | 118,847 IOPS / 263 ms write p99 / 283 ms read p99 (06-04) | 128,983 IOPS / 114.8 ms / 88.6 ms (06-08) | **+8.5%** | **−56%** | **−69%** |
| **performance** | not measured | 254,348 IOPS / 58.5 ms / 51.6 ms (06-08) | — | — | — |
| **big-osd** | 343,107 IOPS / 52.7 ms / 30.0 ms (06-04) | ~350,000 IOPS / 39.6 ms / 14.0 ms (06-06) | **+2%** | **−25%** | **−53%** |

**Read it as: iothreads helps more when the backend is constrained.** On balanced (2 vCPU per OSD), the OSDs are the bottleneck and reducing emulator-thread queueing on the client side has a larger relative effect on tail latency (−56 to −69%). On big-osd, the backend already has CPU headroom, so the client-side relief is smaller in proportion (−25 to −53%). The performance row has no paired no-iothreads sample, but its absolute numbers (58.5 / 51.6 ms p99) sit between the two — consistent with iothreads being a clean win on every rung tested.

**Variance caveat:** each row above is a single sample on its respective day. The variance band documented in the methodology note (p99 runs 2–3× wide across replicates; IOPS ±1%) means the *direction* of every delta here is well-established but precise percentages are not pinned. The balanced no-iothreads and balanced + iothreads measurements were on different days, so some of the +8.5% IOPS lift could be cluster-state drift rather than pure iothreads — the direction is solid, the magnitude is plus-or-minus.

The +2% IOPS gain on big-osd sits inside the IOPS reproducibility band (~1%) — at that rung, iothreads is essentially a pure tail-latency improvement. On balanced, the IOPS lift is large enough (+8.5%) to clear the band.

Cost: none observed. Clean win.

Sources: balanced baseline → [odf-osd-resource-tuning-2026-06-04.md](../examples/odf-osd-resource-tuning-2026-06-04.md); balanced + iothreads → `results/tune-20260608-074347/`; performance + iothreads → `results/tune-20260608-080358/`; big-osd cells → [odf-ceph-tuning-followup-2026-06-06.md](../examples/odf-ceph-tuning-followup-2026-06-06.md) cells A vs C.

### Step 5 (opt-in, conditional) — mclock + BlueStore throttle bundle

Apply ONLY when: (a) read tail latency is the specific user-visible complaint, AND (b) you are **not** using Step 4 iothreads.

What to do:

```bash
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=merge -p='{
  "spec":{"managedResources":{"cephCluster":{"cephConfig":{
    "osd":{
      "osd_mclock_profile":"high_client_ops",
      "bluestore_throttle_bytes":"268435456",
      "bluestore_throttle_deferred_bytes":"268435456"
    }}}}}}'
```

(`osd_memory_target` from Step 3 stays as-is.)

Measured vs `big-osd` base, 32 VMs × QD=32:

| Combination | IOPS Δ | Write p99 Δ | Read p99 Δ |
|---|---|---|---|
| + mclock bundle alone (Step 3 + Step 5) | **−4%** | flat | **−29%** |
| + mclock bundle stacked on iothreads (Step 3 + 4 + 5) | **−8.5%** | **+67%** | **+103%** |

**The stacking interaction is strongly negative.** iothreads feeds I/O in faster while the mclock bundle deliberately narrows the Ceph-side queue. Pick one path or the other, never both. The bundle is also an explicit recovery/backfill trade — `high_client_ops` slows rebuild after node loss.

**Variance caveat:** these deltas come from the same single 2×2 factorial as Step 4. With p99 reproducibility at ~2–3× spread across replicates (see methodology note above), the *direction* of every cell here is well-established but the precise percentages aren't pinned. The negative stacking interaction is large enough (+67% / +103% on the tail) that it sits well outside the variance band — the "don't stack" recommendation is robust even if the exact magnitude shifts on a re-run.

Source: [odf-ceph-tuning-followup-2026-06-06.md](../examples/odf-ceph-tuning-followup-2026-06-06.md), cells A/B/C/D.

### Where most operators should land

Updated 2026-06-09 after isolating memtarget from CPU and measuring all four rungs on the same uncapped methodology.

| Cluster size class | Recommended rungs | Why |
|---|---|---|
| **Most clusters, including reference-class** | Step 0 → 1 → 2 → 4 — `performance` profile + iothreads, stop there | The `balanced → performance` jump nearly **doubles** peak IOPS (+92%, 158k → 303k) for +48 cluster vCPU. The further `performance → big-osd` jump adds only **+14% peak IOPS** for another +48 vCPU / +384 GiB. |
| Latency-bound at saturation, no extra CPU | Step 0 → 1 → 2 → **2b** → 4 — add `osd_memory_target=20G` on `performance` | Halves write p99 at c≥32 (196 ms → 67 ms at c=32, 801 ms → 396 ms at c=64) for ~16 GiB of unused RAM per OSD. Slight IOPS cost (−11 to −23 % at saturation, cache-fill coalescing). No OSD pod roll. |
| Density-bound, host budget to spare | Step 0 → 1 → 2 → 3 → 4 — add `big-osd` + memtarget on top | When you've already saturated `performance` at your target VM count and have ≥6 vCPU / 24 GiB per OSD of cluster headroom. The +CPU is what unlocks higher peak IOPS; the memtarget is what keeps the tail down. Need both. |
| Read-tail-bound, not using iothreads | Step 0 → 1 → 2 → 3 → 5 — `big-osd` + memtarget + mclock bundle | Specifically when read tail latency is the user-visible problem and you choose mclock over iothreads. |

### Rungs we do NOT have evidence for

These would each be a single tune-sweep run away — if a particular gap matters for your decision, run it before deciding:

- **`lean` profile (1 vCPU / 2 GiB per OSD)** — never measured. Don't use for VM workloads on hardware that can support more.
- **`performance` without iothreads** — we have `performance + iothreads` (254k IOPS / 58.5 ms write p99) but no paired pre-iothreads measurement, so the iothreads delta at this rung is inferred from absolute numbers, not measured directly.
- **Anything on multi-zone / regional ROKS, VSI-backed ODF, or CephFS** — see the gap list further down.

---

## Knob reference

Lookup tables for every knob the staircase touches, plus the things to avoid. Useful when you know what you want to change and need the default / measured-impact / cost row at a glance.

| # | Knob | Default | Recommended | Measured impact | Cost / risk |
|---|---|---|---|---|---|
| 1 | Pool for VM data disks | n/a | **`ocs-storagecluster-ceph-rbd-virtualization`** (the OOB "virt" SC) | Custom pools without VM-optimized image features showed ~7× worse write IOPS | None — it's already there |
| 2 | If creating custom RBD pools | n/a | Match: `imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff`, `mapOptions: krbd:rxbounce`, `targetSizeRatio: 0.1`, `deviceClass: ssd` | Without `exclusive-lock` write caching is disabled (multi-× write penalty); without `rxbounce` guest OS sees CRC errors | StorageClass parameters are immutable — get them right at creation |
| 3 | `StorageCluster.spec.resourceProfile` | `balanced` (2 vCPU / 5 GiB per OSD) | **`performance`** (4 vCPU / 8 GiB per OSD) when the cluster has the headroom | rep3-virt 5 ms write-p99 ceiling: 32 → 48 VMs (+50%) | OSD CPU/memory commitment doubles |
| 4 | Pool replication | n/a | **rep3 for prod**, rep2 if your workload tolerates reduced fault domain, **rep1 is benchmarking only** | rep3→rep2: +25% density at balanced. rep2→rep1: +60% more (no redundancy) | Lower replication = fewer surviving copies on node failure |
| 5 | KubeVirt VM template | (suite already sets it) | `ioThreadsPolicy: auto`, `dedicatedIOThread: true`, `blockMultiQueue: true` on the VM disk | Write p99 −25%, read p99 −53%, IOPS +2% on rep3-virt big-osd | None observed — clean win, merged as default |
| 6 | `failureDomain` | Set by ocs-operator from cluster topology (usually `rack` on ROKS) | **Don't override per-pool.** Match the cluster-level value | Mismatched pool-level domains cause CRUSH PG distribution skew | Custom EC pools may not fit if cluster has too few failure domains |
| 7 | `osd_memory_target` | Reef default 4 GiB regardless of resource limits | Raise to 20 G via `cephConfig.osd.osd_memory_target` whenever workload hits c≥32, even without raising the OSD pod resource limit | The cgroup-ratio auto-scaling is **not active** on ROKS — request alone does not increase the BlueStore cache. Standalone (Step 2b) halves write p99 at saturation; paired with `big-osd` (Step 3) it also keeps tail latency low under +CPU. Note: Rook may silently skip propagating this key — the wrappers push it via `ceph config set` directly as a workaround | Without this, the BlueStore cache stays at 4 GiB regardless of pod resources or working-set size |

**Optional / opt-in knobs (don't apply blindly):**

| # | Knob | Apply when | Measured impact | Why it's optional |
|---|---|---|---|---|
| 8 | `big-osd` resource override (`storageDeviceSets[].resources` = 6 vCPU / 24 GiB) | `performance` profile isn't enough and you have host CPU/RAM to spare | 2.89× IOPS, 5× better write p99 vs `balanced` (at 32 VMs × QD=32 uncapped) | Doesn't fit on smaller hosts; needs `osd_memory_target` set to cash in (see #7) |
| 9 | mclock + BlueStore throttle + 20 GB memtarget bundle | Read tail latency is the specific complaint and you accept a small IOPS cost | Read p99 −29%, IOPS −4% on big-osd base | **Do not combine with #5 iothreads** — interaction is strongly negative (IOPS −8.5%, both p99s more than double) |

**Don't bother / don't do:**

| What | Why |
|---|---|
| C-state pinning / NIC ring tuning via MachineConfig on ROKS | ROKS managed workers expose no `MachineConfigPool` — MCs hang for 30 min and never apply. Use `szocp` (self-managed) for these. |
| Stack `iothreads` + `mclock` bundle | Negative interaction; both p99s more than double, IOPS −8.5% |
| Override `failureDomain` per pool on ROKS | ocs-operator owns the cluster-wide decision; pool-level overrides drift |
| Run rep1 in prod | No redundancy — designed only for establishing hardware ceiling |
| Plan "lighter VMs = linearly more VMs" | Per-VM tax (RBD image, krbd watch/notify, pod scheduling) is roughly fixed regardless of per-VM IOPS. Halving per-VM IOPS only ~doubled the density on rep3-virt, not 5× |

---

## Why each recommendation — the mechanism and the evidence

### 1. Use the OOB virtualization StorageClass

The default cluster ships two RBD StorageClasses pointing at the same `ocs-storagecluster-cephblockpool`:

- `ocs-storagecluster-ceph-rbd` — generic
- `ocs-storagecluster-ceph-rbd-virtualization` — adds `imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff` and `mapOptions: krbd:rxbounce`

For VM disks, **always pick the virtualization SC** (or replicate its parameters). The two critical knobs:

- **`exclusive-lock`** enables write-back caching and single-writer optimizations in the RBD client. Without it, every write is uncached. This was the dominant single cause of the "~7× worse write IOPS" we observed when custom pools omitted it, even though both pools sat on the same Ceph backend.
- **`krbd:rxbounce`** is a correctness fix — guest OSes (notably Windows but also some Linux kernels) see CRC errors with kernel-space RBD without it.

In the suite the convention `rep3-virt` references this SC.

Evidence: [latency-patterns.md §"rep3-virt advantage"](latency-patterns.md), [CLAUDE.md "VM-optimized StorageClass features"](../../CLAUDE.md).

### 2. If you must create a custom pool, match the OOB spec

A common failure mode: someone creates `my-rep2` to save space, omits `imageFeatures`, and reports that "rep2 is slower than rep3." The bottleneck is the missing image features, not the replication tier. Reproduce the OOB virt SC parameters one for one, then change only the field you actually want to vary.

Other settings that matter on creation:

- **`targetSizeRatio: 0.1`** (replicated) or `parameters.target_size_ratio: "0.1"` (EC) — without this the PG autoscaler starts the pool at 1 PG, funnelling all I/O through a single OSD primary. We've measured the resulting bottleneck at ~6× the OOB pool.
- **`deviceClass: ssd`** — explicit, even though autodetection often works. Mixed-device pools that fail to bind to `ssd` end up on slower devices.
- **`enableRBDStats: true`** — needed if you want pool-level performance counters in `ceph osd pool stats`.

Full template walk-through and the autoscaler deep-dive: [ceph-pool-setup.md](ceph-pool-setup.md).

### 3. Pick the right `resourceProfile`

`StorageCluster.spec.resourceProfile` controls per-OSD CPU/memory requests + limits:

| Profile | Per-OSD CPU | Per-OSD memory |
|---|---|---|
| `lean` | 1 vCPU | 2 GiB |
| `balanced` *(default)* | 2 vCPU | 5 GiB |
| `performance` | 4 vCPU | 8 GiB |

At low concurrency the OSDs are not CPU-bound and you won't see the difference. Under load (32 VMs × QD=32 mixed) the picture changes sharply: at 64 VMs on rep3-virt, `balanced` collapsed to 851 ms p99 while `performance` stayed at 6 ms.

Decision rule for the reference cluster's bare-metal size class:

- **3 × bx2d.metal.96x384 (96 vCPU / 384 GiB):** `performance` profile fits with headroom. Use it.
- **Smaller workers:** check `oc adm top nodes` before flipping — going from `balanced` to `performance` adds 2 vCPU × 24 OSDs = 48 vCPU and 3 GiB × 24 OSDs = 72 GiB of requests cluster-wide.

Evidence: [odf-replication-scale-comparison.md §"Scale-test"](../examples/odf-replication-scale-comparison.md) — rep3-virt sustained-VM ceiling 32 → 48 at the same 500 IOPS/VM, 5 ms p99 SLA.

### 4. Replication trade-off — measured, not folklore

Replication cost is real and **non-linear** at the tail:

| Pool | VM ceiling @ 500 IOPS/VM, 5 ms p99 | Total IOPS | Comment |
|---|---|---|---|
| rep3-virt, `balanced` | 32 | 31,936 | Safe prod default |
| rep3-virt, `performance` | 48 | 47,904 | Recommended where the host budget allows |
| rep2, `balanced` | 40 | 39,920 | +25% over rep3-balanced |
| rep1, `balanced` | 64 | 63,872 | +100% over rep3-balanced — **no redundancy, benchmarking only** |

The disproportionate jump from rep2 → rep1 (60% more density) is the "wait for the slowest of N OSDs" tail-latency effect collapsing entirely when N=1.

For typical production workloads on this hardware: **rep3-virt on the `performance` profile** is the sweet spot — full three-way durability with rep2-class capacity. Plain `balanced` rep3-virt is the safe fallback if cluster CPU is constrained.

Evidence: [odf-replication-scale-comparison.md §"Scale-test"](../examples/odf-replication-scale-comparison.md).

### 5. VM template — IOThread + multiqueue

KubeVirt domain settings on the data disk:

```yaml
spec:
  domain:
    ioThreadsPolicy: auto
    devices:
      disks:
        - name: data
          dedicatedIOThread: true
          disk:
            bus: virtio
            blockMultiQueue: true
```

This decouples the data-disk virtio submission ring from the rest of the VM's emulator thread and lets multi-vCPU guests issue I/O in parallel queues.

Measured impact (2026-06-06, on big-osd base, mixed-70-30, 32 VMs × QD=32):

- Write p99: 52.7 ms → 39.6 ms (−25%)
- Read p99: 30.0 ms → 14.0 ms (−53%)
- IOPS: +2%

This is already the default in this suite (`vm-templates/vm-template.yaml` since commit `fa061be`). If you're not using this suite's VM template, copy these fields onto your own.

Evidence: [odf-ceph-tuning-followup-2026-06-06.md](../examples/odf-ceph-tuning-followup-2026-06-06.md).

### 6. Leave `failureDomain` to ocs-operator

ODF computes `failureDomain` cluster-wide from worker node topology labels (`topology.kubernetes.io/zone`, `topology.rook.io/rack`) and writes it to `StorageCluster.status.failureDomain`. On ROKS single-zone this is typically `rack` (each worker gets a rack bucket). Pool-level overrides are ignored or, worse, cause CRUSH PG distribution skew.

The relevant constraint for **EC pool feasibility**: EC requires `k + m` unique failure domains.

| EC profile | Domains needed | Works on 3-rack ROKS? |
|---|---|---|
| ec-2-1 | 3 | Yes |
| ec-3-1 | 4 | No (skipped by suite) |
| ec-2-2 | 4 | No |
| ec-4-2 | 6 | No |

The suite defines all these for portability across cluster sizes and auto-skips when there isn't enough topology. Don't try to force them.

Evidence: [failure-domains-and-topology.md](../concepts/failure-domains-and-topology.md), [CLAUDE.md "Failure domain and CRUSH topology"](../../CLAUDE.md).

### 7. `osd_memory_target` — the trap nobody tells you about

ODF's `resourceProfile` and `storageDeviceSets[].resources` control the pod's **cgroup limits**. They don't control the BlueStore cache size. In Ceph Reef, `osd_memory_target` defaults to **4 GiB regardless of how much memory the pod is allowed**. There's a cgroup-ratio auto-scaling mechanism that's supposed to take ~¼ of the cgroup, but on these ROKS workers it doesn't activate.

The practical consequence: setting `storageDeviceSets[].resources.requests.memory = 24Gi` without also setting `osd_memory_target` leaves the OSD's cache at 4 GiB. You get the CPU bump from `big-osd` but not the read-tail improvement Ceph documentation implies you should.

The fix:

```yaml
spec:
  managedResources:
    cephCluster:
      cephConfig:
        osd:
          osd_memory_target: "20000000000"  # 20 GB, ~18.6 GiB — leaves ~5 GiB headroom under 24 Gi limit
```

This goes through Path A in `cephConfig` (survives operator reconciles, applied live, no pod restart for most settings).

Evidence: [odf-ceph-tuning-followup-2026-06-06.md §"Cluster Baseline and Phase 0 Finding"](../examples/odf-ceph-tuning-followup-2026-06-06.md).

---

## Optional knobs — apply only with a specific reason

### 8. `big-osd` resource override (6 vCPU / 24 GiB per OSD)

Apply when:

- You're already on `resourceProfile: performance` and still need more headroom for very dense VM placement.
- The cluster has the budget (on bx2d.metal.96x384, big-osd consumes 6 × 24 = 144 vCPU and 24 × 24 = 576 GiB of OSD requests, leaving comfortable headroom on the 3-host total of 288 vCPU / 1152 GiB).

How: applied via `StorageCluster.spec.storageDeviceSets[0].resources` (the documented `spec.resources.osd` path is **silently ignored** in ODF 4.20+).

Pair with #7 (`osd_memory_target`) — without it you only get the CPU benefit.

Measured impact (2026-06-04 baseline, 2026-06-07 rerun confirmed):

| Metric | `balanced` default | `big-osd` |
|---|---|---|
| Total IOPS (32 VMs × QD=32 uncapped) | 118,847 | 343,107 (2.89×) |
| Write p99 | 263 ms | 52.7 ms |
| Read p99 | 283 ms | 30.0 ms |

Cost: large OSD pod resource reservation, longer apply/restore cycle (~12 min OSD roll vs ~5 min for `resourceProfile` flips).

Evidence: [odf-osd-resource-tuning-2026-06-04.md](../examples/odf-osd-resource-tuning-2026-06-04.md).

### 9. mclock + BlueStore throttle + memtarget bundle

Apply when:

- Read tail latency is the specific user-visible complaint
- You're **not** also using iothreads (#5)

What it does:

```yaml
cephConfig:
  osd:
    osd_mclock_profile: high_client_ops
    bluestore_throttle_bytes: "268435456"          # 256 MiB
    bluestore_throttle_deferred_bytes: "268435456" # 256 MiB
    osd_memory_target: "20000000000"               # 20 GB
```

mclock with `high_client_ops` reduces the recovery/backfill queue share to leave more room for client I/O at the cost of slower rebuild after node loss. The BlueStore throttles cap the deferred-write batch so individual writes don't queue behind multi-MB flushes.

Measured impact (vs big-osd base, 32 VMs × QD=32):

- Read p99 −29%
- IOPS −4%
- Write p99 essentially unchanged

**Critical:** do not stack with iothreads (#5). The 2×2 factorial we ran in 2026-06-06 showed:

| Combination | IOPS Δ | Write p99 Δ | Read p99 Δ |
|---|---|---|---|
| iothreads alone (cell C) | +2% | −25% | −53% |
| mclock bundle alone (cell B) | −4% | flat | −29% |
| **Both stacked (cell D)** | **−8.5%** | **+67%** | **+103%** |

The interaction is strongly negative — iothreads feeds I/O in faster while the mclock bundle deliberately narrows the Ceph-side queue. Result: backlog. Pick one or the other based on the workload signature, not both.

Evidence: [odf-ceph-tuning-followup-2026-06-06.md](../examples/odf-ceph-tuning-followup-2026-06-06.md).

---

## What we do NOT have enough evidence to recommend

Being explicit about gaps so you can plan your own validation:

| Area | Status | Where to look |
|---|---|---|
| Multi-zone / regional ROKS topology | Suite supports it (auto-detects via `detect_cluster_zones()`), but no end-to-end perf comparison published | Run `./run-all.sh --rank` on the regional cluster and compare to the single-zone ranking |
| VSI-backed ODF | Suite handles VSI auto-detection; performance not characterised at depth in current writeups | Same — `--rank` mode plus a scale test |
| CephFS at production scale | Architectural notes only (MDS overhead + file-on-fs indirection in KubeVirt) | The suite tests it; reports are in `results/<run>/cephfs-rep3/` |
| C-state / NIC ring tuning on ROKS | Known +63% seq-read win on `szocp` (self-managed). Blocked on ROKS — no MCP. Use `szocp` for these experiments. | [`project_szocp_nic_rx_ring`](../../) memory record |
| Workloads beyond mixed-70-30 (write-heavy, large-block streaming) | Ranking trio tests them at single-VM scale; not part of the tune-sweep coverage | Use `--filter` to run targeted profiles, but expect numbers to be one-off rather than tuning-comparable |
| VM sizes other than `small` at high density | Tune-sweep fixed at small (2 vCPU / 4 GiB). Larger VMs change the per-VM tax | Re-run `--scale-test` with `VM_SIZES=medium` to validate |

---

## How to apply each setting

### Resource profile

```bash
oc patch storagecluster ocs-storagecluster -n openshift-storage \
  --type=merge -p '{"spec":{"resourceProfile":"performance"}}'
```

OSDs roll one at a time; expect ~5 min on 24 OSDs.

### `big-osd` override (only if `performance` is insufficient)

The override path that actually works on ODF 4.20+:

```bash
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=json -p='[
  {"op":"add","path":"/spec/storageDeviceSets/0/resources","value":{
    "requests":{"cpu":"6","memory":"24Gi"},
    "limits":{"cpu":"6","memory":"24Gi"}}}
]'
```

**Do not** use `spec.resources.osd` — that path is silently ignored in 4.20+.

### `osd_memory_target` (pair with any resources override)

```bash
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=merge -p='{
  "spec":{"managedResources":{"cephCluster":{"cephConfig":{
    "osd":{"osd_memory_target":"20000000000"}}}}}}'
```

Applied via Ceph config DB; no pod restart needed for this key.

### VM template iothreads + multiqueue

Already in `vm-templates/vm-template.yaml` since `fa061be`. To verify on your own VM:

```bash
oc get vm <name> -o jsonpath='{.spec.template.spec.domain.ioThreadsPolicy}'   # → auto
oc get vm <name> -o jsonpath='{.spec.template.spec.domain.devices.disks[?(@.name=="data")].dedicatedIOThread}'  # → true
```

---

## How to verify your cluster is actually using these settings

```bash
# Resource profile + OSD pod sizing
oc get storagecluster ocs-storagecluster -n openshift-storage -o jsonpath='{.spec.resourceProfile}{"\n"}'
oc get pod -n openshift-storage -l app=rook-ceph-osd \
  -o jsonpath='{.items[0].spec.containers[0].resources}'

# osd_memory_target actually applied in Ceph
oc rsh -n openshift-storage \
  $(oc get pod -n openshift-storage -l app=rook-ceph-tools -o name) \
  ceph config get osd osd_memory_target

# StorageClass parameters on the SC your VMs use
oc get sc ocs-storagecluster-ceph-rbd-virtualization -o jsonpath='{.parameters}{"\n"}'
oc get sc ocs-storagecluster-ceph-rbd-virtualization -o jsonpath='{.parameters.mapOptions}{"\n"}'

# Cluster-level failure domain (authoritative)
oc get storagecluster ocs-storagecluster -n openshift-storage \
  -o jsonpath='{.status.failureDomain}{"\n"}'

# Custom-pool failure domain (should match cluster level)
oc get cephblockpool -n openshift-storage <pool> -o jsonpath='{.spec.failureDomain}{"\n"}'

# Ceph health
oc rsh -n openshift-storage \
  $(oc get pod -n openshift-storage -l app=rook-ceph-tools -o name) \
  ceph status
```

---

## How to baseline on your own cluster before deciding to tune

If you're considering applying any of the optional knobs (#8 or #9), measure first:

```bash
# Quick ranking across all available StorageClasses (~1-1.5h)
./run-all.sh --rank --skip-setup

# Density at moderate load to find the rep3-virt ceiling
./04-run-tests.sh --scale-test --pool rep3-virt --rate-iops 500 --latency-sla 5

# Default vs big-osd head-to-head (~45 min, mutates cluster, auto-restores)
./09-run-tune-sweep.sh --pool rep3-virt --configs default,big-osd \
   --fixed-vms 32 --qd-list 32

# Compare two runs side-by-side
./06-generate-report.sh --compare <id1> <id2>
```

If your numbers come in close to the reference cluster's, you can lean on these recommendations. If they diverge more than ~20%, baseline before applying optional knobs.

---

## Related documents

- [latency-patterns.md](latency-patterns.md) — why each pool type has the latency shape it does
- [ceph-pool-setup.md](ceph-pool-setup.md) — full walkthrough for creating a custom CephBlockPool
- [odf-replication-scale-comparison.md](../examples/odf-replication-scale-comparison.md) — replication + resourceProfile data with full method
- [odf-osd-resource-tuning-2026-06-04.md](../examples/odf-osd-resource-tuning-2026-06-04.md) — `big-osd` discovery and the API gotcha
- [odf-ceph-tuning-candidates-2026-06-04.md](../examples/odf-ceph-tuning-candidates-2026-06-04.md) — full candidate list with the "don't bother" set
- [odf-ceph-tuning-followup-2026-06-06.md](../examples/odf-ceph-tuning-followup-2026-06-06.md) — iothreads × mclock 2×2 factorial
- [failure-domains-and-topology.md](../concepts/failure-domains-and-topology.md) — CRUSH and ROKS rack topology
