# Latency Patterns and Storage Tradeoffs

[Back to Documentation Index](../index.md)

This guide explains the latency patterns observed across storage backends in the ranking benchmarks. It covers why different backends behave the way they do, what the numbers mean for real workloads, and how to use this understanding when choosing a StorageClass.

The patterns described here are based on random 4k I/O (the `random-rw` profile with 4k block size), which is the most latency-sensitive workload and the standard benchmark for storage comparison.

## The Big Picture

Four distinct latency profiles emerge from the benchmarks:

| Backend Type | Read Latency | Write Latency | Pattern |
|-------------|-------------|--------------|---------|
| **Ceph RBD (replicated, Block PVC)** | Sub-1ms | 36-87ms | Asymmetric (krbd synchronous writes) |
| **Ceph CephFS** | Sub-2ms | 13-377ms p99 | RBD-like asymmetry + MDS/indirection overhead |
| **IBM Cloud File/Pool CSI (NFS)** | 2-128ms | 5-130ms | Symmetric, tier-dependent |
| **Ceph RBD (erasure coded)** | 5-10ms | 100-170ms | Asymmetric with EC overhead |

Each pattern has a distinct cause rooted in the storage architecture.

## The volumeMode: Block Discovery

The single most impactful finding from the write latency investigation was the role of PVC `volumeMode`. With the default `volumeMode: Filesystem`, KubeVirt creates a `disk.img` file on the PVC mount and QEMU opens it as `driver: file` without `aio: native`. This causes a **48x write penalty** compared to `volumeMode: Block`, where QEMU gets direct block device passthrough (`driver: host_device`, `aio: native`).

All RBD pool benchmarks now use `volumeMode: Block`. CephFS and NFS pools use `volumeMode: Filesystem` (required by their storage backends). The latency numbers in this guide reflect the Block PVC configuration for RBD.

For the full layer-by-layer analysis, see the [ODF Write Latency Investigation Report](../../reports/odf-write-latency-investigation.md).

## Ceph RBD Replicated: Fast Reads, Expensive Writes

Replicated Ceph pools (rep2, rep3-virt, rep3-enc) show the most striking pattern — reads are fast but writes still carry overhead from synchronous krbd replication.

Typical numbers (with `volumeMode: Block`):

| Pool | Read Avg | Write Avg | Read p99 | Write p99 |
|------|----------|-----------|----------|-----------|
| rep3-virt | ~0.95ms | ~46ms | ~15ms | ~90ms |
| rep2 | ~1.1ms | ~37ms | ~16ms | ~104ms |
| rep3-enc | ~1.3ms | ~50ms | ~16ms | ~127ms |

### Why Reads Are Fast

A read only needs one OSD. The primary OSD for a placement group serves the read directly, often from its NVMe page cache. The path is:

```
VM → QEMU (host_device, aio=native) → krbd → primary OSD (NVMe cache hit) → response
```

One network hop, one disk access (often cached). Sub-millisecond latency is expected for cached 4k reads on NVMe-backed OSDs. With `volumeMode: Block`, QEMU uses direct block device passthrough, adding negligible overhead to the storage path.

### Why Writes Are Still Slower

Write latency is dominated by **synchronous krbd replication** — every 4k write must travel from the guest to the primary OSD, be replicated to all secondary OSDs, and receive acknowledgement before the guest sees completion:

```
VM → QEMU (host_device, aio=native) → krbd → primary OSD → replicate to N-1 secondaries → ack
```

Key factors:
1. **krbd has no write-back cache** — unlike librbd (which delivers 48K IOPS through its write-back cache), the kernel RBD module submits every 4k write as an individual synchronous RADOS operation.
2. **Ceph replication overhead** — each write must be acknowledged by all replicas (2 for rep2, 3 for rep3), with network round-trips to each OSD.
3. **Write merges help significantly** — with Block PVCs, QEMU enables 108K+ write merges per test (vs 5 with Filesystem PVCs), which partially compensates for the per-I/O krbd overhead.

Note: With `volumeMode: Filesystem` (the old default), these numbers were dramatically worse (~700 write IOPS, ~180ms latency) due to QEMU's `file` driver + no `aio=native` on the `disk.img` indirection layer. The Block PVC fix recovered ~48x write performance.

### rep2 vs rep3: Fewer Replicas = Lower Write Latency

rep2 writes to 2 OSDs instead of 3. Fewer replicas means fewer acks to wait for:

- **rep2 write avg:** ~37ms (2 replica acks)
- **rep3-virt write avg:** ~46ms (3 replica acks)

The ~24% difference is consistent with the additional replica round-trip. For reads, rep2 and rep3 perform identically — both serve from a single primary OSD.

## The rep3-virt Advantage: VM-Optimized StorageClass

The `rep3-virt` StorageClass uses the ODF virtualization SC with `exclusive-lock`, `object-map`, and `fast-diff` image features plus `rxbounce` map option. In the benchmarks, **rep3-virt is clearly the top performer**:

- **rep3-virt random IOPS:** 186,012
- **rep2 random IOPS:** 125,802

### Why rep3-virt Outperforms

With `volumeMode: Block`, the `exclusive-lock` feature enables write optimizations at the OSD level — single-writer guarantees allow the OSD to skip coordination overhead. The `object-map` feature speeds up sparse image operations. Combined with `rxbounce` (correctness fix for guest OS CRC errors), these features deliver measurable benefits even with O_DIRECT fio workloads.

### Practical Recommendation

Use `rep3-virt` with `volumeMode: Block` for production VMs. This combination delivers the best overall performance — 186K random IOPS and 21.7 GiB/s sequential throughput — while maintaining 3-way replication for data safety.

## CephFS Pools: Filesystem Indirection Is Unavoidable

CephFS pools (`cephfs-rep3`, `cephfs-rep2`) cannot use `volumeMode: Block` because CephFS provides a POSIX filesystem, not a block device. KubeVirt creates a `disk.img` on the CephFS mount, so CephFS VMs always use the slower file indirection path:

1. **File-on-filesystem indirection:** Each guest I/O passes through QEMU's file I/O layer and the CephFS POSIX stack before reaching Ceph.
2. **MDS overhead:** CephFS metadata operations (file open, stat, create) go through MDS daemons, adding latency that RBD doesn't have.

CephFS pools exhibit the same read/write asymmetry as RBD (reads from a single OSD, writes to multiple replicas) but with higher baseline latency and extreme write p99 tail latency. For VM workloads, RBD with Block PVCs is strongly preferred unless POSIX shared filesystem semantics are required.

## IBM Cloud File CSI: Consistent but Tier-Limited

NFS-based file storage shows a completely different pattern — **symmetric read/write latency**, bounded by the provisioned IOPS tier.

| Pool | Read Avg | Write Avg | Read p99 | Write p99 |
|------|----------|-----------|----------|-----------|
| ibmc-vpc-file-3000-iops | ~21ms | ~23ms | ~27ms | ~47ms |
| ibmc-vpc-file-1000-iops | ~64ms | ~65ms | ~87ms | ~78ms |
| ibmc-vpc-file-500-iops | ~128ms | ~129ms | ~179ms | ~172ms |

### Why Symmetric

Every I/O — read or write — travels the same path:

```
VM → kernel NFS client → network → IBM Cloud NFS server → response
```

There is no local replica shortcut for reads (unlike Ceph where the primary OSD may be on the same node). Both directions traverse the same network path to the same managed file server.

### Why Tier-Proportional

The latency roughly scales inversely with the IOPS tier:

- 3000-IOPS: ~22ms average → ~45 IOPS per outstanding I/O
- 1000-IOPS: ~65ms average → ~15 IOPS per outstanding I/O
- 500-IOPS: ~129ms average → ~8 IOPS per outstanding I/O

With `iodepth=32` and `numjobs=4`, there are 128 concurrent I/Os in flight. The managed NFS server throttles to the provisioned tier, and queuing theory dictates that latency rises as the server approaches its IOPS cap.

### Low Jitter

The p99/average ratio for file CSI is typically 1.5-2x, compared to larger ratios for Ceph RBD (where p99 is dominated by write tail latency). This means file CSI delivers **more predictable latency** — there are fewer extreme outliers. For workloads where worst-case latency matters more than average latency (e.g., real-time applications, SLA-bound services), this predictability can be valuable despite the higher baseline.

## Erasure Coded Pools: The Write Amplification Penalty

EC pools combine the worst of both worlds for latency:

| Pool | Read Avg | Write Avg | Read p99 | Write p99 |
|------|----------|-----------|----------|-----------|
| ec-2-1 | ~5.5ms | ~172ms | ~13ms | ~451ms |

### Why Reads Are Slower Than Replicated

EC reads must decode data from k chunks. For ec-2-1 (k=2, m=1), a read involves:

```
VM → krbd → replicated metadata pool (lookup) → EC data pool (read 2 chunks) → decode → response
```

The extra metadata pool lookup and multi-chunk read add ~4-5ms over a replicated read.

### Why Writes Are Much Slower

EC writes must:

1. Encode data into k data chunks + m coding chunks
2. Write to the **replicated metadata pool** (image headers, object-map)
3. Write all k+m chunks to the **EC data pool** across k+m OSDs
4. Wait for all chunks to be acknowledged

For ec-2-1, that's 3 OSDs to ack (vs 2 for rep2 or 3 for rep3), but with the added overhead of parity calculation and the metadata pool round-trip.

### The 451ms Write p99

The EC write p99 is the **single worst metric in the entire ranking**. This happens because:

- Parity computation adds CPU time in the critical path
- Writing to both a metadata pool and a data pool serializes some operations
- With 3 OSDs in the write path and parity overhead, the probability of at least one slow OSD response is higher
- The tail latency compounds across these serial stages

### When EC Still Makes Sense

EC trades latency for **storage efficiency**. ec-2-1 uses 1.5x raw capacity (vs 2x for rep2 or 3x for rep3). For workloads that are:

- **Read-heavy** — EC read latency (~5.5ms) is acceptable for many applications
- **Throughput-oriented** — Sequential 1M reads/writes are less latency-sensitive, and EC's bandwidth can be competitive
- **Capacity-constrained** — When you need to store more data than replication allows

EC is a poor choice for write-latency-sensitive workloads (databases, transactional systems).

## How the Latency Ranking Can Mislead

The ranking report sorts by **avg p99 = (read_p99 + write_p99) / 2**. This single-number summary can be misleading:

| Rank | Pool | Read p99 | Write p99 | Avg p99 |
|------|------|----------|-----------|---------|
| #1 | bench-pool | 8ms | 64ms | 36ms |
| #2 | ibmc-vpc-file-3000-iops | 27ms | 47ms | 37ms |
| #3 | rep3-virt | 15ms | 90ms | 52ms |

Bench-pool and File CSI "win" despite having worse read latency than Ceph because their consistent writes don't drag the average up as much. Ceph RBD delivers sub-1ms average reads but write p99 of 90-127ms dominates the averaged metric.

### Choosing the Right Metric for Your Workload

| Workload | Look At | Why |
|----------|---------|-----|
| Read-heavy database | Read avg, read p99 | Writes are WAL-only, reads dominate |
| Write-heavy logging/events | Write avg, write p99 | Ingestion rate matters most |
| Mixed OLTP | Both, weighted by R/W ratio | A 70/30 workload cares 70% about reads |
| Latency-SLA service | Max of (read p99, write p99) | SLA doesn't distinguish R vs W |
| Throughput pipeline | Sequential BW | Latency is less important for bulk I/O |

For most VM workloads (general-purpose, databases, web applications), **read latency dominates** because applications issue far more reads than writes. In this case, Ceph RBD's sub-1ms reads make it the clear winner despite the ranking table suggesting otherwise.

## IBM Cloud Pool CSI: Pre-Provisioned NFS

Pool CSI (`bench-pool`) uses the same underlying IBM Cloud VPC NFS infrastructure as File CSI but with a pre-provisioned pool of file shares. The latency characteristics are similar to File CSI at the equivalent IOPS tier — symmetric read/write with tier-proportional latency.

The key difference is **PVC bind time**: Pool CSI binds PVCs almost instantly from the pre-provisioned pool (no API call to create a new file share), making VM startup significantly faster. The steady-state I/O performance during fio benchmarks is determined by the pool's total provisioned IOPS.

## Summary of Key Findings

1. **`volumeMode: Block` is critical for RBD performance.** The default `volumeMode: Filesystem` causes KubeVirt to create a `disk.img` file, which QEMU opens as `driver: file` without `aio=native`. Switching to Block gives QEMU `host_device` + `aio=native` — a 48x write IOPS improvement (from ~700 to ~34,000 IOPS).

2. **Ceph RBD reads are sub-1ms with Block PVCs.** With direct block device passthrough, the QEMU overhead is negligible. Read latency is dominated by the krbd-to-OSD network hop.

3. **Write latency (36-87ms) is driven by synchronous krbd replication.** Every 4k write must round-trip to all replica OSDs. krbd has no write-back cache (unlike librbd). This is a fundamental architectural constraint, not a configuration issue.

4. **rep3-virt is the clear winner** with 186K random IOPS, 21.7 GiB/s sequential throughput, and sub-1ms read latency. The VM-optimized StorageClass features (`exclusive-lock`, `object-map`, `fast-diff`) provide measurable benefits with Block PVCs.

5. **File CSI has symmetric, tier-proportional latency** — no read/write asymmetry, IOPS scales with tier, and low jitter (p99 ~1.5-2x average). Good for predictability-sensitive workloads.

6. **EC pools have the worst write tail latency** (451ms p99) due to parity computation + metadata pool round-trip + multi-chunk writes. Use only for read-heavy or throughput-oriented workloads.

7. **CephFS cannot benefit from Block PVCs** and retains the file indirection overhead. Use RBD for VM workloads unless POSIX shared filesystem semantics are required.

## Next Steps

- [ODF Write Latency Investigation](../../reports/odf-write-latency-investigation.md) — Layer-by-layer analysis proving `disk.img` file indirection as the primary write latency bottleneck, and `volumeMode: Block` as the fix
- [Understanding Results](understanding-results.md) — How to read all report formats and analysis tips
- [fio Profiles Reference](../architecture/fio-profiles-reference.md) — What each benchmark profile measures
- [CephBlockPool Setup](ceph-pool-setup.md) — Image features, VM-optimized settings, and performance impact
- [Configuration Reference](configuration-reference.md) — The three rep3 variants and their differences
