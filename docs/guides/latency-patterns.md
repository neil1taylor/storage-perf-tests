# Latency Patterns and Storage Tradeoffs

[Back to Documentation Index](../index.md)

This guide explains the latency patterns observed across storage backends in the ranking benchmarks. It covers why different backends behave the way they do, what the numbers mean for real workloads, and how to use this understanding when choosing a StorageClass.

The patterns described here are based on random 4k I/O (the `random-rw` profile with 4k block size), which is the most latency-sensitive workload and the standard benchmark for storage comparison.

## The Big Picture

Three distinct latency profiles emerge from the benchmarks:

| Backend Type | Read Latency | Write Latency | Pattern |
|-------------|-------------|--------------|---------|
| **Ceph RBD (replicated)** | Sub-2ms | 60-80ms | Extreme asymmetry |
| **IBM Cloud File CSI (NFS)** | 20-130ms | 20-130ms | Symmetric, tier-dependent |
| **Ceph RBD (erasure coded)** | 5-10ms | 100-120ms | Asymmetric with EC overhead |

Each pattern has a distinct cause rooted in the storage architecture.

## Ceph RBD Replicated: Fast Reads, Expensive Writes

Replicated Ceph pools (rep2, rep3, rep3-virt) show the most striking pattern — **reads are ~55x faster than writes**.

Typical numbers:

| Pool | Read Avg | Write Avg | Read p99 | Write p99 |
|------|----------|-----------|----------|-----------|
| rep2 | ~1.2ms | ~67ms | ~30ms | ~109ms |
| rep3 | ~1.3ms | ~73ms | ~30ms | ~112ms |
| rep3-virt | ~1.3ms | ~75ms | ~29ms | ~118ms |

### Why Reads Are Fast

A read only needs one OSD. The primary OSD for a placement group serves the read directly, often from its NVMe page cache. The path is:

```
VM → krbd → primary OSD (NVMe cache hit) → response
```

One network hop, one disk access (often cached). Sub-millisecond latency is expected for cached 4k reads on NVMe-backed OSDs.

### Why Writes Are Slow

A write must be acknowledged by **all replicas** before returning to the client. For rep3, that means:

```
VM → krbd → primary OSD → [parallel] replica OSD 1 + replica OSD 2 → all ack → response
```

Each replica involves a network round-trip and an NVMe flush. The write latency is dominated by the slowest replica's response time. With 3 workers and NVMe, each replica flush takes ~20-25ms, and the serial overhead of coordinating acknowledgments adds up.

### rep2 vs rep3: Fewer Replicas = Lower Write Latency

rep2 writes to 2 OSDs instead of 3. Fewer replicas means fewer acks to wait for:

- **rep2 write avg:** ~67ms (2 replica acks)
- **rep3 write avg:** ~73ms (3 replica acks)

The ~8% difference is smaller than you might expect (2/3 = 33% fewer replicas) because the primary OSD's local write and network overhead are fixed costs that don't scale with replica count.

For reads, rep2 and rep3 perform identically — both serve from a single primary OSD.

## The rep3-virt Paradox: VM-Optimized but Not Faster with O_DIRECT

The `rep3-virt` StorageClass uses the ODF virtualization SC with `exclusive-lock`, which enables write-back caching. Elsewhere in the docs (and in Ceph documentation generally), this is cited as providing up to 7x write IOPS improvement. Yet in the benchmarks, **rep3-virt is marginally slower than rep3**:

- **rep3 write avg:** ~73ms
- **rep3-virt write avg:** ~75ms

This is not a bug — it's a direct consequence of how the benchmarks run.

### The O_DIRECT Factor

All fio profiles use `direct=1`, which issues I/O with the `O_DIRECT` flag. This bypasses the kernel page cache entirely and submits I/O directly to the block device.

The `exclusive-lock` feature enables a write-back cache in the **librbd user-space library**, but KubeVirt VMs use the **krbd kernel client** (`/dev/rbd*` block devices). The krbd driver does not implement a write-back cache — it relies on the kernel's page cache for caching, which `O_DIRECT` bypasses.

So the path with rep3-virt is:

```
fio (O_DIRECT) → krbd → Ceph (exclusive-lock state maintained but cache unused) → response
```

The small extra overhead (~2ms) likely comes from maintaining the exclusive-lock state (lock heartbeats, object-map updates) without any caching benefit.

### When Does rep3-virt Actually Help?

The `exclusive-lock` feature provides its full benefit when:

1. **The application uses buffered I/O** (no O_DIRECT) — the kernel page cache can batch and coalesce writes before flushing to the block device
2. **Single-writer guarantees** are needed — exclusive-lock prevents split-brain scenarios with concurrent writers
3. **Clone and snapshot operations** — `object-map` + `fast-diff` (which depend on `exclusive-lock`) dramatically speed up DataVolume cloning and snapshot creation

For real VM workloads (databases with WAL, OS disk activity, application logging), most I/O goes through the page cache and benefits from exclusive-lock. The fio benchmarks with `direct=1` specifically measure the *storage backend* performance and intentionally bypass caching — this is the correct methodology for comparing storage backends, but it doesn't reflect typical application behavior.

### Practical Recommendation

Use `rep3-virt` for production VMs. The benchmark numbers with `direct=1` show the raw storage floor, but real workloads will see better write performance through page cache coalescing and the exclusive-lock optimizations. The `rxbounce` map option is also a correctness requirement (prevents CRC errors) regardless of caching behavior.

## IBM Cloud File CSI: Consistent but Tier-Limited

NFS-based file storage shows a completely different pattern — **symmetric read/write latency**, bounded by the provisioned IOPS tier.

| Pool | Read Avg | Write Avg | Read p99 | Write p99 |
|------|----------|-----------|----------|-----------|
| ibmc-vpc-file-3000-iops | ~21ms | ~23ms | ~31ms | ~51ms |
| ibmc-vpc-file-1000-iops | ~64ms | ~65ms | ~85ms | ~76ms |
| ibmc-vpc-file-500-iops | ~128ms | ~130ms | ~173ms | ~171ms |

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

The p99/average ratio for file CSI is typically 1.5-2x, compared to 25-50x for Ceph RBD (where p99 is dominated by write tail latency). This means file CSI delivers **more predictable latency** — there are fewer extreme outliers. For workloads where worst-case latency matters more than average latency (e.g., real-time applications, SLA-bound services), this predictability can be valuable despite the higher baseline.

## Erasure Coded Pools: The Write Amplification Penalty

EC pools combine the worst of both worlds for latency:

| Pool | Read Avg | Write Avg | Read p99 | Write p99 |
|------|----------|-----------|----------|-----------|
| ec-2-1 | ~10ms | ~119ms | ~12ms | ~367ms |

### Why Reads Are Slower Than Replicated

EC reads must decode data from k chunks. For ec-2-1 (k=2, m=1), a read involves:

```
VM → krbd → replicated metadata pool (lookup) → EC data pool (read 2 chunks) → decode → response
```

The extra metadata pool lookup and multi-chunk read add ~8-9ms over a replicated read.

### Why Writes Are Much Slower

EC writes must:

1. Encode data into k data chunks + m coding chunks
2. Write to the **replicated metadata pool** (image headers, object-map)
3. Write all k+m chunks to the **EC data pool** across k+m OSDs
4. Wait for all chunks to be acknowledged

For ec-2-1, that's 3 OSDs to ack (vs 2 for rep2 or 3 for rep3), but with the added overhead of parity calculation and the metadata pool round-trip.

### The 367ms Write p99

The EC write p99 (367ms) is **3x worse than any replicated pool** and the single worst metric in the entire ranking. This happens because:

- Parity computation adds CPU time in the critical path
- Writing to both a metadata pool and a data pool serializes some operations
- With 3 OSDs in the write path and parity overhead, the probability of at least one slow OSD response is higher
- The tail latency compounds across these serial stages

### When EC Still Makes Sense

EC trades latency for **storage efficiency**. ec-2-1 uses 1.5x raw capacity (vs 2x for rep2 or 3x for rep3). For workloads that are:

- **Read-heavy** — EC read latency (~10ms) is acceptable for many applications
- **Throughput-oriented** — Sequential 1M reads/writes are less latency-sensitive, and EC's bandwidth can be competitive
- **Capacity-constrained** — When you need to store more data than replication allows

EC is a poor choice for write-latency-sensitive workloads (databases, transactional systems).

## How the Latency Ranking Can Mislead

The ranking report sorts by **avg p99 = (read_p99 + write_p99) / 2**. This single-number summary can be misleading:

| Rank | Pool | Read p99 | Write p99 | Avg p99 |
|------|------|----------|-----------|---------|
| #1 | ibmc-vpc-file-3000-iops | 31ms | 51ms | 41ms |
| #2 | rep2 | 30ms | 109ms | 69ms |
| #3 | rep3 | 30ms | 112ms | 71ms |

File CSI 3000-iops "wins" despite having **10x worse read latency** than Ceph because its consistent writes don't drag the average up. Ceph pools deliver sub-1.3ms reads but their 100ms+ write p99 dominates the averaged metric.

### Choosing the Right Metric for Your Workload

| Workload | Look At | Why |
|----------|---------|-----|
| Read-heavy database | Read avg, read p99 | Writes are WAL-only, reads dominate |
| Write-heavy logging/events | Write avg, write p99 | Ingestion rate matters most |
| Mixed OLTP | Both, weighted by R/W ratio | A 70/30 workload cares 70% about reads |
| Latency-SLA service | Max of (read p99, write p99) | SLA doesn't distinguish R vs W |
| Throughput pipeline | Sequential BW | Latency is less important for bulk I/O |

For most VM workloads (general-purpose, databases, web applications), **read latency dominates** because applications issue far more reads than writes. In this case, Ceph RBD's sub-2ms reads make it the clear winner despite the ranking table suggesting otherwise.

## Summary of Key Findings

1. **Ceph RBD reads are ~55x faster than writes** due to single-OSD reads vs multi-replica write acks. This asymmetry is fundamental to Ceph's replication architecture.

2. **rep2 has ~8% lower write latency than rep3** — consistent with fewer replicas but less of a gap than the 2-vs-3 replica count suggests, because primary OSD overhead is fixed.

3. **rep3-virt's exclusive-lock caching doesn't help with O_DIRECT** — the krbd kernel driver doesn't implement write-back caching, so direct I/O benchmarks bypass the feature. Real (buffered) workloads will see better write performance.

4. **File CSI has symmetric, tier-proportional latency** — no read/write asymmetry, IOPS scales with tier, and low jitter (p99 ~1.5-2x average). Good for predictability-sensitive workloads.

5. **EC pools have the worst write tail latency** (367ms p99) due to parity computation + metadata pool round-trip + multi-chunk writes. Use only for read-heavy or throughput-oriented workloads.

6. **The avg p99 ranking metric favors consistency over raw speed** — it can rank a 21ms-read NFS backend above a 1.2ms-read Ceph backend. Always consider your workload's read/write ratio.

## Next Steps

- [Understanding Results](understanding-results.md) — How to read all report formats and analysis tips
- [fio Profiles Reference](../architecture/fio-profiles-reference.md) — What each benchmark profile measures
- [CephBlockPool Setup](ceph-pool-setup.md) — Image features, VM-optimized settings, and performance impact
- [Configuration Reference](configuration-reference.md) — The three rep3 variants and their differences
