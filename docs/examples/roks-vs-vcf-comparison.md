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
| Concurrency | 1 VM | 1 VM |

**Absolute values across platforms are directly comparable.**

**ROKS note:** RBD pools use `volumeMode: Block` PVCs, giving QEMU direct block device passthrough (`host_device` + `aio=native`). This eliminates the `disk.img` file indirection that previously caused a 48x write penalty with `volumeMode: Filesystem`. See the [ODF Write Latency Investigation](../../reports/odf-write-latency-investigation.md) for details.

## Storage Mapping

Equivalent storage types were paired across platforms based on architecture and intended use:

| Category | ROKS | VCF | Rationale |
|----------|------|-----|-----------|
| Best replicated | `rep3-virt` (3-way RBD, VM-optimized + Block) | `raid1-ftt1-thick` (RAID-1 thick) | Top replicated performer on each platform |
| Standard replicated | `rep2` (2-way RBD, Block) | `raid1-ftt1` (RAID-1 thin) | Default replicated tier |
| CephFS | `cephfs-rep2` (2-replica CephFS, Filesystem) | `raid1-ftt1` (RAID-1 thin) | POSIX filesystem vs thin replicated (both use filesystem indirection) |
| Erasure coded | `ec-2-1` (2+1 EC) | `raid5-ftt1` (RAID-5 3+1) | Parity-based space-efficient storage |
| NFS high tier | `bench-pool` (Pool CSI, dp2) | `workload-share-j7hfh` (10 IOPS/GB) | Highest NFS tier available |
| NFS mid tier | `ibmc-vpc-file-1000-iops` | `workload-share-3hq5c` (4 IOPS/GB) | Mid-range NFS |
| NFS low tier | `ibmc-vpc-file-500-iops` | `workload-share-x1ydq` (2 IOPS/GB) | Low-end NFS |

## Random 4k IOPS

| Category | ROKS | VCF | Delta |
|----------|-----:|----:|------:|
| Best replicated | 64,483 | 81,578 | -21.0% |
| Standard replicated | 71,966 | 80,851 | -11.0% |
| CephFS | 59,956 | 80,851 | -25.8% |
| Erasure coded | 49,058 | 69,361 | -29.3% |
| NFS high tier | 53,506 | 25,668 | +108.5% |
| NFS mid tier | 1,984 | 14,745 | -86.5% |
| NFS low tier | 989 | 7,671 | -87.1% |

## Sequential 1M Throughput (MiB/s)

| Category | ROKS | VCF | Delta |
|----------|-----:|----:|------:|
| Best replicated | 7,599.2 | 1,229.6 | +518.0% |
| Standard replicated | 8,306.0 | 1,223.0 | +579.1% |
| CephFS | 5,377.9 | 1,223.0 | +339.7% |
| Erasure coded | 5,814.1 | 1,688.3 | +244.4% |
| NFS high tier | 2,049.7 | 2,063.3 | -0.7% |
| NFS mid tier | 125.9 | 999.0 | -87.4% |
| NFS low tier | 63.3 | 502.4 | -87.4% |

## Mixed 70/30 4k IOPS

| Category | ROKS | VCF | Delta |
|----------|-----:|----:|------:|
| Best replicated | 48,641 | 22,515 | +116.0% |
| Standard replicated | 53,574 | 23,397 | +129.0% |
| CephFS | 45,126 | 23,397 | +92.9% |
| Erasure coded | 31,405 | 23,049 | +36.3% |
| NFS high tier | 34,502 | 10,963 | +214.7% |
| NFS mid tier | 997 | 8,181 | -87.8% |
| NFS low tier | 496 | 4,086 | -87.9% |

## Average p99 Latency (ms) -- lower is better

| Category | ROKS | VCF | Delta |
|----------|-----:|----:|------:|
| Best replicated | 50.02 | 10.25 | +388.0% (ROKS worse) |
| Standard replicated | 49.10 | 10.25 | +379.0% (ROKS worse) |
| CephFS | 123.21 | 10.25 | +1,102.0% (ROKS worse) |
| Erasure coded | 85.41 | 13.33 | +540.7% (ROKS worse) |
| NFS high tier | 53.05 | 15.17 | +249.7% (ROKS worse) |
| NFS mid tier | 768.19 | 18.45 | +4,063.6% (ROKS worse) |
| NFS low tier | 1,610.19 | 20.87 | +7,615.3% (ROKS worse) |

## Key Takeaways

1. **ROKS dominates sequential throughput.** ROKS delivered 6-7x the sequential bandwidth of VCF on replicated block storage, and 3.4x on erasure coded. Ceph's distributed architecture streams data across multiple OSDs in parallel, far exceeding what vSAN ESA can deliver from local SSDs on a single host. This is ROKS's strongest advantage.

2. **ROKS wins mixed workloads convincingly.** With 70/30 read/write 4k I/O, ROKS delivered 2.2x the IOPS of VCF on replicated storage and 1.4x on EC. The read-heavy mix plays to ROKS's strength since reads from Ceph are fast (sub-1ms), and the sequential throughput advantage lifts mixed results.

3. **VCF wins random IOPS on block storage.** VCF delivered 11-29% higher random 4k IOPS than ROKS across all block storage tiers. With single-VM concurrency, VCF's local-SSD write acknowledgement gives it lower per-I/O latency, which directly translates to higher IOPS. The gap is driven primarily by write latency: ROKS random writes require synchronous krbd round-trips to multiple Ceph OSDs, adding ~12-20ms per write vs VCF's local-commit path.

4. **VCF still wins on tail latency everywhere.** VCF delivered 4-5x lower avg p99 latency on block storage. ROKS read latency is competitive (2-3ms read p99), but write p99 (193-354ms) is the outlier. This is inherent to distributed storage with synchronous replication.

5. **CephFS: strong throughput despite filesystem indirection.** ROKS `cephfs-rep2` uses `volumeMode: Filesystem`, meaning KubeVirt creates a `disk.img` file on the CephFS mount — adding an extra indirection layer vs RBD Block. Despite this, CephFS still delivered 4.4x the sequential throughput of VCF RAID-1 thin and 1.9x the mixed IOPS. Random IOPS lagged VCF by 26%, and p99 latency was 12x worse (123ms vs 10ms) due to MDS overhead plus write amplification through the file layer. CephFS trades latency for POSIX compatibility and shared-filesystem semantics.

6. **Erasure coding: ROKS now competitive.** ROKS `ec-2-1` delivered +36% better mixed IOPS and +244% better throughput than VCF RAID-5, while VCF led on random IOPS by 29%. On a 3-node cluster, EC performance is constrained by single-primary PG funneling, but ROKS's throughput advantage still holds.

7. **NFS high tier: ROKS Pool CSI dominates.** The Pool CSI bench-pool delivered 2.1x the random IOPS and 3.1x the mixed IOPS of VCF's 10 IOPS/GB Endurance share, achieving near-block-storage performance. Sequential throughput was comparable (~2,050 vs 2,063 MiB/s). The Pool CSI's pre-provisioned share pool eliminates per-PVC provisioning latency.

8. **NFS mid/low tiers: VCF Endurance wins across the board.** IBM Cloud File CSI's 500-1000 IOPS tiers are provisioned-IOPS-limited. VCF's Endurance shares at 2-4 IOPS/GB scale with capacity, delivering 7-8x better IOPS and throughput at these tiers.

## Scorecard Summary

| Category | IOPS Winner | Throughput Winner | Latency Winner |
|----------|-------------|-------------------|----------------|
| Best replicated | VCF (random), ROKS (mixed) | ROKS | VCF |
| Standard replicated | VCF (random), ROKS (mixed) | ROKS | VCF |
| CephFS | VCF (random), ROKS (mixed) | ROKS | VCF |
| Erasure coded | VCF (random), ROKS (mixed) | ROKS | VCF |
| NFS high tier | ROKS | ~Tie | VCF |
| NFS mid tier | VCF | VCF | VCF |
| NFS low tier | VCF | VCF | VCF |

**ROKS** wins on sequential throughput (6x advantage) and mixed workloads (2x advantage) for block storage, plus NFS high tier. **VCF** wins on random IOPS, tail latency everywhere, and NFS mid/low tiers. The right choice depends on workload profile: throughput-heavy workloads (backups, ETL, streaming, bulk data) and mixed OLTP favor ROKS; latency-sensitive random I/O workloads (databases with small writes, real-time transactional) favor VCF.

---

*Data sources: ROKS ranking run `perf-20260227-203655` (medium VM, 150Gi, concurrency=1, volumeMode: Block for RBD, Filesystem for CephFS), VCF 150 GiB results from ranking run `20260225` (medium VM, 150Gi).*
