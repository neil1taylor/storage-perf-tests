# ROKS vs VCF Storage Performance Comparison

Cross-platform comparison of VM storage performance between IBM Cloud ROKS (OpenShift Virtualization + ODF/Ceph) and VMware VCF (vSAN ESA + NFS Endurance).

## Test Conditions

Both platforms were tested with matched parameters for a fair comparison:

| Parameter | ROKS | VCF |
|-----------|------|-----|
| VM size | medium (4 vCPU, 8 GiB) | medium (4 vCPU, 8 GiB) |
| Disk size | 150 GiB | 150 GiB |
| fio runtime | 60s (10s ramp) | 60s |
| I/O depth | 32 | 32 |
| fio workers | 4 | 4 |
| Direct I/O | Yes (O_DIRECT) | Yes (O_DIRECT) |
| fio file size | 4 GiB | 4 GiB |

**Absolute values across platforms are directly comparable.**

**ROKS note:** RBD pools use `volumeMode: Block` PVCs, giving QEMU direct block device passthrough (`host_device` + `aio=native`). This eliminates the `disk.img` file indirection that previously caused a 48x write penalty with `volumeMode: Filesystem`. See the [ODF Write Latency Investigation](../../reports/odf-write-latency-investigation.md) for details.

## Storage Mapping

Equivalent storage types were paired across platforms based on architecture and intended use:

| Category | ROKS | VCF | Rationale |
|----------|------|-----|-----------|
| Best replicated | `rep3-virt` (3-way RBD, VM-optimized + Block) | `raid1-ftt1-thick` (RAID-1 thick) | Top replicated performer on each platform |
| Standard replicated | `rep2` (2-way RBD, Block) | `raid1-ftt1` (RAID-1 thin) | Default replicated tier |
| Erasure coded | `ec-2-1` (2+1 EC) | `raid5-ftt1` (RAID-5 3+1) | Parity-based space-efficient storage |
| NFS high tier | `bench-pool` (Pool CSI, 40k IOPS) | `workload-share-j7hfh` (10 IOPS/GB) | Highest NFS tier available |
| NFS mid tier | `ibmc-vpc-file-1000-iops` | `workload-share-3hq5c` (4 IOPS/GB) | Mid-range NFS |
| NFS low tier | `ibmc-vpc-file-500-iops` | `workload-share-x1ydq` (2 IOPS/GB) | Low-end NFS |

## Random 4k IOPS

| Category | ROKS | VCF | Delta |
|----------|-----:|----:|------:|
| Best replicated | 186,012 | 81,578 | +128.0% |
| Standard replicated | 125,802 | 80,851 | +55.6% |
| Erasure coded | 61,210 | 69,361 | -11.8% |
| NFS high tier | 95,095 | 25,668 | +270.5% |
| NFS mid tier | 3,952 | 14,745 | -73.2% |
| NFS low tier | 1,980 | 7,671 | -74.2% |

## Sequential 1M Throughput (MiB/s)

| Category | ROKS | VCF | Delta |
|----------|-----:|----:|------:|
| Best replicated | 21,768.3 | 1,229.6 | +1,670.1% |
| Standard replicated | 14,596.5 | 1,223.0 | +1,093.5% |
| Erasure coded | 1,200.0 | 1,688.3 | -28.9% |
| NFS high tier | 4,099.7 | 2,063.3 | +98.7% |
| NFS mid tier | 251.9 | 999.0 | -74.8% |
| NFS low tier | 126.8 | 502.4 | -74.7% |

## Mixed 70/30 4k IOPS

| Category | ROKS | VCF | Delta |
|----------|-----:|----:|------:|
| Best replicated | 150,658 | 22,515 | +569.1% |
| Standard replicated | 96,907 | 23,397 | +314.2% |
| Erasure coded | 4,016 | 23,049 | -82.6% |
| NFS high tier | 60,053 | 10,963 | +447.8% |
| NFS mid tier | 1,994 | 8,181 | -75.6% |
| NFS low tier | 992 | 4,086 | -75.7% |

## Average p99 Latency (ms) -- lower is better

| Category | ROKS | VCF | Delta |
|----------|-----:|----:|------:|
| Best replicated | 52.40 | 10.25 | +411.1% (ROKS worse) |
| Standard replicated | 60.09 | 10.25 | +486.3% (ROKS worse) |
| Erasure coded | 231.93 | 13.33 | +1,639.6% (ROKS worse) |
| NFS high tier | 36.15 | 15.17 | +138.2% (ROKS worse) |
| NFS mid tier | 82.05 | 18.45 | +344.7% (ROKS worse) |
| NFS low tier | 175.64 | 20.87 | +741.5% (ROKS worse) |

## Key Takeaways

1. **ROKS block storage dominates on IOPS and throughput -- the gap widened with Block PVCs.** With `volumeMode: Block`, ROKS rep3-virt now delivers 2.3x the random IOPS, 6.7x the mixed IOPS, and 17.7x the sequential throughput of VCF's best replicated tier. The improvement over the previous comparison (which used `volumeMode: Filesystem`) is dramatic -- Block PVCs give QEMU direct `host_device` passthrough with `aio=native`, eliminating the `disk.img` file indirection that was the primary bottleneck.

2. **VCF still wins on latency, but the gap narrowed significantly.** VCF delivered 5x lower avg p99 tail latency vs ROKS on block storage (down from 7-17x in the previous comparison). ROKS read latency is now sub-1ms (0.95ms for rep3-virt), competitive with VCF. The remaining gap is driven by ROKS write latency (~46-87ms) which still requires synchronous krbd round-trips to Ceph OSDs, whereas vSAN ESA benefits from local-SSD write acknowledgement.

3. **VCF thick vs thin provisioning: negligible gap at 150 GiB.** At 150 GiB, `raid1-ftt1` (thin) achieved 80,851 random IOPS -- within 1% of thick provisioning's 81,578. The dramatic 7.3x gap seen at 50 GiB was a first-write zeroing artifact on fresh thin disks. For production workloads with reasonably sized disks, thin provisioning is not a performance concern on vSAN ESA.

4. **Erasure coding: VCF leads on mixed and throughput.** VCF's RAID-5 delivered 5.7x the mixed IOPS and 1.4x the sequential throughput of ROKS `ec-2-1`, while ROKS had a slight 11.8% edge on random IOPS. ROKS EC pools are constrained by single-primary PG funneling on small (3-node) clusters; VCF RAID-5 (3+1 across 4 hosts) distributes writes more evenly.

5. **NFS high tier: ROKS Pool CSI dominates.** The 40,000 IOPS provisioned Pool CSI delivered 3.7x the random IOPS and 2x the throughput of VCF's 10 IOPS/GB Endurance share, achieving near-block-storage performance levels. The Pool CSI's pre-provisioned share pool eliminates per-PVC provisioning latency.

6. **NFS mid/low tiers: VCF Endurance wins across the board.** IBM Cloud File CSI's 500-1000 IOPS tiers are provisioned-IOPS-limited. VCF's Endurance shares at 2-4 IOPS/GB scale with capacity, delivering 3-4x better IOPS and throughput at these tiers.

## Scorecard Summary

| Category | IOPS Winner | Throughput Winner | Latency Winner |
|----------|-------------|-------------------|----------------|
| Best replicated | ROKS | ROKS | VCF |
| Standard replicated | ROKS | ROKS | VCF |
| Erasure coded | ~Tie | VCF | VCF |
| NFS high tier | ROKS | ROKS | VCF |
| NFS mid tier | VCF | VCF | VCF |
| NFS low tier | VCF | VCF | VCF |

**ROKS** wins on raw IOPS and throughput for block storage and high-tier NFS -- and the margin increased substantially with Block PVCs. **VCF** wins on tail latency everywhere and on NFS mid/low tiers. The right choice depends on workload profile: throughput-heavy workloads (backups, ETL, bulk data) favor ROKS; latency-sensitive workloads (databases, real-time) favor VCF.

---

*Data sources: ROKS ranking run `perf-20260227-153135` (medium VM, 150Gi, volumeMode: Block for RBD), VCF 150 GiB results from ranking run `20260225` (medium VM, 150Gi).*
