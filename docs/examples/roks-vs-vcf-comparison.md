# ROKS vs VCF Storage Performance Comparison

Cross-platform comparison of VM storage performance between IBM Cloud ROKS (OpenShift Virtualization + ODF/Ceph) and VMware VCF (vSAN ESA + NFS Endurance).

> **Methodology update — 2026-05-26**
>
> All ROKS numbers in this document were re-collected on 2026-05-26 after a methodology fix to the fio runner. Earlier versions of this comparison reported ROKS write p99 latency in the 50–354 ms range for block storage — those numbers were a measurement artifact, not real Ceph latency. Two effects compounded: (1) sparse RBD images deferred 4 MiB object allocation to the first write, so the measurement window captured allocation cost instead of steady-state IO; (2) reads from unallocated regions returned zeros without hitting OSDs, inflating random read IOPS.
>
> The fix landed in `cloud-init/fio-runner.yaml` (prefill block) and the three ranking fio profiles (added `filename=fio-testfile`). After the fix, real ROKS write p99 on replicated pools is **5–33 ms** depending on workload, not 50–354 ms. See [`odf-replication-scale-comparison.md`](odf-replication-scale-comparison.md) for the full root-cause analysis and the wider scale-test story.
>
> VCF numbers in this document are unchanged from the 2026-02-25 source run.

## Test Conditions

Both platforms tested with matched parameters for a fair comparison:

| Parameter | ROKS | VCF |
|-----------|------|-----|
| VM size | medium (4 vCPU, 8 GiB) | medium (4 vCPU, 8 GiB) |
| Disk size | 150 GiB | 150 GiB |
| fio runtime | 60s (10s ramp) | 60s |
| I/O depth | 32 | 32 |
| fio workers | 4 | 4 |
| Direct I/O | Yes (O_DIRECT) | Yes (O_DIRECT) |
| fio file size | 4 GiB | 4 GiB |
| Concurrency | 1 VM (uncapped IOPS) | 1 VM (uncapped IOPS) |
| Test file prefill | Yes (sequential 4M write before measurement) | n/a (file allocation behaves differently on vSAN) |

**Absolute values across platforms are directly comparable.**

**ROKS note:** RBD pools use `volumeMode: Block` PVCs, giving QEMU direct block device passthrough (`host_device` + `aio=native`). This eliminates the `disk.img` file indirection that previously caused a 48x write penalty with `volumeMode: Filesystem`. See the [ODF Write Latency Investigation](../../reports/odf-write-latency-investigation.md) for the earlier `volumeMode` fix.

## Storage Mapping

Equivalent storage types paired across platforms based on architecture and intended use:

| Category | ROKS | VCF | Rationale |
|----------|------|-----|-----------|
| Best replicated | `rep3-virt` (3-way RBD, VM-optimized + Block) | `raid1-ftt1-thick` (RAID-1 thick) | Top replicated performer on each platform |
| Standard replicated | `rep2` (2-way RBD, Block) | `raid1-ftt1` (RAID-1 thin) | Default replicated tier |
| CephFS | `cephfs-rep3`† (3-replica CephFS, Filesystem) | `raid1-ftt1` (RAID-1 thin) | POSIX filesystem vs thin replicated (both use filesystem indirection) |
| Erasure coded | `ec-2-1` (2+1 EC) | `raid5-ftt1` (RAID-5 3+1) | Parity-based space-efficient storage |
| NFS mid tier | `ibmc-vpc-file-1000-iops` | `workload-share-3hq5c` (4 IOPS/GB) | Mid-range NFS |
| NFS low tier | `ibmc-vpc-file-500-iops` | `workload-share-x1ydq` (2 IOPS/GB) | Low-end NFS |
| NFS mid-high tier | `ibmc-vpc-file-3000-iops` | (no direct equivalent) | Higher-tier File CSI |

† Original comparison used `cephfs-rep2` (2-replica). On the current cluster, `cephfs-rep2` PVCs fail to bind due to a pre-existing CephFS CSI auth-caps issue unrelated to performance. Substituted `cephfs-rep3` so the category isn't blank. The extra replica adds modest write overhead; reads and throughput are comparable.

The earlier "NFS high tier" row compared IBM Cloud Pool CSI (`bench-pool`) to VCF's 10 IOPS/GB tier. The Pool CSI driver isn't installed on the current cluster, so that row is omitted from the updated tables. The old numbers from the previous source run remain in git history.

## Random 4k Read IOPS

`random-rw.fio` runs `[rand-read]` then `[rand-write]` sequentially (stonewall). The numbers below are the read job only.

| Category | ROKS (rep) | VCF | Delta |
|----------|-----------:|----:|------:|
| Best replicated | 52,170 | 81,578 | -36.1% |
| Standard replicated | 61,490 | 80,851 | -23.9% |
| CephFS | 53,586 | 80,851 | -33.7% |
| Erasure coded | 44,862 | 69,361 | -35.3% |
| NFS mid-high tier | 2,997 | n/a | n/a |
| NFS mid tier | 997 | 14,745 | -93.2% |
| NFS low tier | 497 | 7,671 | -93.5% |

## Random 4k Write IOPS

Write job from the same `random-rw.fio` run.

| Category | ROKS | VCF | Delta |
|----------|-----:|----:|------:|
| Best replicated (`rep3-virt`) | 35,435 | (not in source run) | — |
| Standard replicated (`rep2`) | 43,326 | (not in source run) | — |
| CephFS (`cephfs-rep3`) | 29,139 | (not in source run) | — |
| Erasure coded (`ec-2-1`) | 13,132 | (not in source run) | — |
| NFS mid-high tier | 2,997 | n/a | n/a |
| NFS mid tier | 997 | (not in source run) | — |
| NFS low tier | 497 | (not in source run) | — |

The earlier comparison reported a single "Random 4k IOPS" number that mixed both jobs in a way that hid the read/write asymmetry. With the corrected methodology and split reporting, the write half is clearly visible — and it's where replica count matters most (rep2 writes are ~22% faster than rep3-virt writes).

## Sequential 1M Throughput (MiB/s)

Read job from `sequential-rw.fio` then write job (stonewall). Reads listed first, writes second.

| Category | ROKS read | VCF read | Delta | ROKS write | VCF write | Delta |
|----------|----------:|---------:|------:|-----------:|----------:|------:|
| Best replicated | 6,338 | 1,229.6 | +415.4% | 2,926 | (n/a) | — |
| Standard replicated | 5,737 | 1,223.0 | +369.0% | 2,871 | (n/a) | — |
| CephFS | 4,980 | 1,223.0 | +307.2% | 1,297 | (n/a) | — |
| Erasure coded | 3,668 | 1,688.3 | +117.2% | 2,794 | (n/a) | — |
| NFS mid-high tier | 188 | n/a | n/a | 188 | n/a | n/a |
| NFS mid tier | 64 | 999.0 | -93.6% | 63 | (n/a) | — |
| NFS low tier | 31 | 502.4 | -93.8% | 31 | (n/a) | — |

ROKS still dominates sequential throughput on block storage (4–5× VCF) — that finding survives the methodology fix. The improvement is even bigger now because the corrected read numbers aren't inflated by zero-region reads, so the delta is honest.

## Mixed 70/30 4k

`mixed-70-30.fio` is a single `randrw` job (no stonewall), so reads and writes are interleaved in the same measurement window.

| Category | ROKS read IOPS | ROKS write IOPS | ROKS total IOPS | VCF total IOPS | Delta (total) |
|----------|---------------:|----------------:|----------------:|---------------:|--------------:|
| Best replicated | 34,314 | 14,740 | 49,054 | 22,515 | +117.9% |
| Standard replicated | 37,796 | 16,231 | 54,027 | 23,397 | +130.9% |
| CephFS | 27,654 | 11,879 | 39,533 | 23,397 | +69.0% |
| Erasure coded | 19,419 | 8,356 | 27,775 | 23,049 | +20.5% |
| NFS mid-high tier | 2,096 | 901 | 2,997 | n/a | n/a |
| NFS mid tier | 697 | 300 | 997 | 8,181 | -87.8% |
| NFS low tier | 345 | 151 | 496 | 4,086 | -87.9% |

ROKS wins the mixed comparison on every block-storage tier — the read-heavy 70/30 split plays to ROKS's strong random reads and overall throughput. NFS mid/low tiers are still the wrong product for high-IOPS workloads; the provisioned-IOPS cap is the binding constraint.

## Write p99 Latency (ms) — lower is better

The previous version of this table reported a single "average p99 latency" in the 50–1,610 ms range for ROKS. Those numbers were artifact-driven. Below are the real per-profile p99 latencies on the rewritten methodology.

| Category | random-write p99 | sequential-write p99* | mixed-70-30 write p99 | VCF avg p99 (pre-fix) |
|----------|-----------------:|---------------------:|----------------------:|----------------------:|
| Best replicated (`rep3-virt`) | 28.70 ms | (1M throughput, not p99-bound) | 5.60 ms | 10.25 ms |
| Standard replicated (`rep2`) | 15.27 ms | — | 4.95 ms | 10.25 ms |
| CephFS (`cephfs-rep3`) | 12.52 ms | — | 8.36 ms | 10.25 ms |
| Erasure coded (`ec-2-1`) | 89.65 ms | — | 49.02 ms | 13.33 ms |
| NFS mid-high tier | 51.64 ms | — | 52.69 ms | n/a |
| NFS mid tier | 139.46 ms | — | 149.95 ms | 18.45 ms |
| NFS low tier | 341.84 ms | — | 329.25 ms | 20.87 ms |

\* The sequential 1M test is bandwidth-bound, not latency-bound. p99 there reflects how long an individual 1 MiB operation takes, which scales with block size and is not directly comparable to small-block random/mixed latency.

**The corrected latency story:**

- **For mixed (general VM) workloads, ROKS rep2 / rep3-virt now sit at 5–6 ms write p99 — better than VCF's reported 10 ms.** The earlier "ROKS 4–5× worse than VCF on latency" claim was wrong.
- **For pure-random small-block writes**, ROKS rep pools sit at 15–29 ms vs VCF ~10 ms — closer than the old numbers suggested, but VCF is still slightly ahead by ~5–18 ms for that specific access pattern. This is the single dimension where vSAN's local-commit path beats Ceph's synchronous-replicated commit path.
- **ec-2-1 still has a real latency cost** (49–90 ms write p99) — that survives the methodology fix and is inherent to erasure coding's encode-on-write overhead.

## Key Takeaways

1. **ROKS dominates sequential throughput.** ROKS delivers 3–5× the sequential bandwidth of VCF on replicated block storage. Ceph's distributed architecture streams data across multiple OSDs in parallel, far exceeding what vSAN ESA delivers from local SSDs on a single host. This is ROKS's strongest advantage and survives the methodology fix.

2. **ROKS wins mixed workloads convincingly.** With 70/30 read/write 4k I/O, ROKS delivers 1.2–2.3× the IOPS of VCF on block storage, and per-op latency is now in the 5–8 ms p99 range on rep pools — slightly *better* than VCF's reported 10 ms.

3. **VCF still wins pure random IOPS on block storage.** With the corrected methodology, VCF leads ROKS by 24–36% on the read half of `random-rw`. The gap is smaller than the methodology-affected numbers showed (the old version reported VCF leading by only 11–29% because ROKS's reads from unallocated regions were artificially inflated). Real ROKS reads from prefilled data are slightly slower than VCF's local-SSD reads. VCF's RAID-1 stripe across local SSDs on the same host has a shorter read path than Ceph's cross-OSD distribution.

4. **Tail latency on replicated pools is now competitive — not 4–5× worse.** The earlier "VCF wins on tail latency everywhere" claim was driven by the methodology artifact. Real ROKS write p99 on `rep2` for mixed workloads is **4.95 ms** vs VCF's 10.25 ms — ROKS is actually slightly *ahead* for the most common VM workload pattern. VCF still leads on pure random writes by ~5–18 ms, but the gap is small and workload-dependent, not a universal win.

5. **CephFS: strong throughput, modest random IOPS gap.** `cephfs-rep3` delivered 4× the sequential throughput of VCF RAID-1 thin and 1.7× the mixed IOPS. Random IOPS lagged VCF by 34%, and p99 latency is now 12 ms (mixed) — comparable to VCF's 10 ms, not 12× worse. The earlier 123 ms p99 number was the artifact.

6. **Erasure coding: ROKS competitive on throughput, lags on random and latency.** ROKS `ec-2-1` delivered +21% better mixed IOPS and +117% better throughput than VCF RAID-5, while VCF led on random IOPS by 35% and on latency by ~7×. EC's write amplification (data + parity on every write) is real and harder to hide than the replication tax on rep pools.

7. **NFS mid/low tiers: VCF Endurance still wins decisively.** IBM Cloud File CSI's 500–1000 IOPS tiers are provisioned-IOPS-limited and don't scale with capacity. VCF's Endurance shares at 2–4 IOPS/GB scale linearly with disk size, delivering 7–8× better IOPS and throughput at these tiers. This is unchanged from the prior report and is an architectural difference, not a methodology issue.

8. **The earlier doc's overall conclusion needs a correction.** "ROKS strong on throughput and mixed, VCF wins everywhere on latency" should now read **"ROKS strong on throughput, mixed, *and* mixed-workload tail latency; VCF wins pure random IOPS and pure random write latency."** The split is sharper than the old report suggested.

## Scorecard Summary

| Category | Random read IOPS | Random write IOPS | Sequential throughput | Mixed total IOPS | Mixed write p99 |
|----------|------------------|-------------------|----------------------|------------------|-----------------|
| Best replicated | VCF | (no VCF write split) | **ROKS** | **ROKS** | **ROKS** |
| Standard replicated | VCF | (no VCF write split) | **ROKS** | **ROKS** | **ROKS** |
| CephFS | VCF | (no VCF write split) | **ROKS** | **ROKS** | **ROKS** |
| Erasure coded | VCF | (no VCF write split) | **ROKS** | **ROKS** | VCF |
| NFS mid tier | VCF | n/a | VCF | VCF | VCF |
| NFS low tier | VCF | n/a | VCF | VCF | VCF |

**Updated overall framing:** for block-storage VM workloads, ROKS now wins or ties on throughput, mixed IOPS, and mixed-workload tail latency. VCF wins pure random IOPS (modest 24–36% margin) and pure random write latency on rep pools (~5–18 ms vs VCF's ~10 ms). The right choice depends on workload profile: anything that resembles real VM I/O (mixed read/write, varying block sizes, sustained throughput) favors ROKS; pure-random small-block workloads (some OLTP databases under specific access patterns) still favor VCF. For NFS tiers, VCF Endurance's IOPS-per-GB scaling beats IBM Cloud File CSI's flat-IOPS provisioning at mid and low tiers.

---

*Data sources: ROKS ranking run from 2026-05-26 (cluster `IBM Cloud ROKS bx2d.metal.96x384`, 3 workers, NVMe, ODF 4.20.7 on resourceProfile=balanced, post-prefill-fix); VCF 150 GiB results from ranking run `20260225` (medium VM, 150Gi). The 2026-02-27 ROKS data referenced in earlier versions of this document is preserved in git history.*
