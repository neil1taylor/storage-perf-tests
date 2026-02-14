# Erasure Coding Explained

[Back to Index](../index.md)

This page provides a deep dive into erasure coding (EC) — what it is, how it works, and how it compares to replication. Understanding EC is key to interpreting why some storage pools in the benchmark results behave differently from others.

## The Problem: Protecting Data Efficiently

Storage systems must protect against disk and node failures. The simplest approach is **replication** — store N copies of every piece of data. But replication is expensive:

| Strategy | Raw Storage per 1 TB Usable | Data Protected Against |
|----------|----------------------------|----------------------|
| Rep2 (2 copies) | 2 TB | 1 failure |
| Rep3 (3 copies) | 3 TB | 2 failures |

For large datasets, the overhead is significant. Erasure coding offers the same (or better) fault tolerance with much less storage overhead.

## How Erasure Coding Works

Erasure coding is based on the same mathematics used in RAID, CDs, QR codes, and deep-space communication. The core idea:

1. **Split** the original data into **k** equal-sized data chunks
2. **Compute** **m** parity chunks from the data chunks using mathematical formulas
3. **Distribute** all k+m chunks across different storage devices
4. **Recover** the original data from any k of the k+m chunks

### A Concrete Example: EC 4+2

With k=4 data chunks and m=2 parity chunks:

```
Original Data: [A][B][C][D]
                │  │  │  │
                ▼  ▼  ▼  ▼
Encoding:    [A][B][C][D][P1][P2]     ← 6 chunks total
              │  │  │  │   │   │
              ▼  ▼  ▼  ▼   ▼   ▼
Stored on:  OSD1 OSD2 OSD3 OSD4 OSD5 OSD6
```

- **Normal reads:** Read chunks A, B, C, D from OSDs 1-4 (parity chunks are not read)
- **One failure (say OSD3 dies):** Read A, B, D, P1 → reconstruct C mathematically
- **Two failures (OSD3 and OSD5 die):** Read A, B, D, P2 → reconstruct C and verify

The storage overhead is (k+m)/k = 6/4 = **1.5x** — compared to 3x for rep3, with the same 2-failure tolerance.

## Comparison: Replication vs Erasure Coding

| Property | Rep2 | Rep3 | EC 2+1 | EC 2+2 | EC 4+2 |
|----------|------|------|--------|--------|--------|
| **Usable storage per 1 TB raw** | 500 GB | 333 GB | 667 GB | 500 GB | 667 GB |
| **Storage overhead** | 2.0x | 3.0x | 1.5x | 2.0x | 1.5x |
| **Max failures survived** | 1 | 2 | 1 | 2 | 2 |
| **Min OSDs required** | 2 | 3 | 3 | 4 | 6 |
| **Read performance** | Fast | Fast | Good | Good | Good |
| **Write performance** | Fast | Moderate | Slower | Slower | Moderate |
| **Write amplification** | 2x | 3x | 1.5x | 2x | 1.5x |
| **CPU overhead** | None | None | Moderate | Moderate | Moderate |
| **Recovery speed** | Fast | Fast | Slower | Slower | Moderate |

## Performance Implications

### Why EC Writes Are Slower

With replication, a write is simple: send the same data to N OSDs. With erasure coding:

1. The client must accumulate a full stripe (k chunks worth of data)
2. Compute m parity chunks (CPU-intensive math)
3. Send k+m chunks to different OSDs
4. Wait for all k+m OSDs to acknowledge

For small random writes (e.g., 4k database operations), this overhead is particularly noticeable because:
- A 4k write may trigger a read-modify-write cycle on the full stripe
- The parity computation adds latency
- More OSDs must participate in each I/O operation

### Why EC Reads Can Be Competitive

For reads, EC can perform similarly to replication:
- Normal reads only access k OSDs (no parity involvement)
- Large sequential reads can pipeline across multiple stripes
- The CPU overhead is on writes, not reads

### The Chunk Count Matters

More data chunks (higher k) means:
- Better storage efficiency
- More OSDs involved in each operation (more parallelism, but more coordination)
- Larger minimum stripe size

The EC 4+2 profile (k=4, m=2) tends to outperform EC 2+1 (k=2, m=1) for large sequential workloads because it can utilize more OSDs in parallel. But for small random I/O, the coordination overhead of 6 OSDs vs 3 OSDs may hurt.

## When to Use What

### Use Replication (rep3) When:
- Workload is IOPS-sensitive (databases, OLTP)
- Low latency is critical
- Write performance matters more than storage efficiency
- Simplicity and predictability are valued

### Use Replication (rep2) When:
- Single-failure tolerance is acceptable
- Write performance needs to be maximized
- Cost savings on storage overhead vs rep3

### Use Erasure Coding When:
- Storage capacity is the primary concern
- Workload is throughput-oriented (large sequential I/O)
- Data is mostly read (archival, analytics, AI/ML datasets)
- The CPU overhead is acceptable

### EC in This Test Suite

This is exactly what the test suite measures — for your specific hardware and workloads:
- How much IOPS penalty does EC incur vs replication?
- Does EC throughput match replication for large-block sequential I/O?
- How does p99 latency compare?
- What happens under concurrency (multiple VMs)?

The benchmark results give you data-driven answers to these questions rather than relying on general rules of thumb.

## Failure Domains and Node Requirements

An often-overlooked constraint: EC pools require enough **failure domains** (typically hosts) to place each chunk on a separate domain. With `failureDomain: host` (the default in this project), you need at least k+m hosts.

### What Works With N Bare Metal Nodes?

| Nodes | rep2 | rep3 | EC 2+1 | EC 2+2 | EC 4+2 |
|-------|------|------|--------|--------|--------|
| 3 | Yes | Yes | Yes | No (needs 4) | No (needs 6) |
| 4 | Yes | Yes | Yes | Yes | No (needs 6) |
| 6+ | Yes | Yes | Yes | Yes | Yes |

### Why EC 4+2 Won't Work on 3 Nodes

EC 4+2 produces 6 chunks total. With `failureDomain: host`, Ceph must place each chunk on a different host. Even switching to `failureDomain: rack` doesn't help — you'd need 6 racks (one per chunk). With only 3 racks, Ceph cannot distribute 6 chunks across 3 failure domains while guaranteeing that no single domain failure loses more than one chunk.

### Workaround: Per-OSD Failure Domain

You can change `failureDomain: osd` to distribute chunks across individual OSDs rather than hosts. This allows EC 4+2 on fewer nodes (as long as you have 6+ OSDs), but **reduces fault tolerance** — multiple chunks could live on the same host, so a host failure could lose multiple chunks simultaneously.

```yaml
# Not recommended for production, but works for testing
spec:
  failureDomain: osd    # Instead of 'host'
  erasureCoded:
    dataChunks: 4
    codingChunks: 2
```

**Recommendation:** Match your `ODF_POOLS` configuration to your actual node count. If you have 3 bare metal workers, stick with rep2, rep3, and ec-2-1. Add ec-2-2 at 4+ nodes and ec-4-2 at 6+ nodes.

## Erasure Coding Profiles in This Project

| Profile | k (data) | m (parity) | Total Chunks | Efficiency | Min Hosts |
|---------|----------|------------|-------------|-----------|----------|
| ec-2-1 | 2 | 1 | 3 | 66.7% | 3 |
| ec-2-2 | 2 | 2 | 4 | 50.0% | 4 |
| ec-4-2 | 4 | 2 | 6 | 66.7% | 6 |

**ec-2-1** is the most space-efficient with minimal redundancy. **ec-2-2** matches rep2's overhead but with a mathematically different protection model. **ec-4-2** is considered production-grade — good efficiency with strong protection.

## Next Steps

- [Ceph and ODF](ceph-and-odf.md) — How Ceph pools are configured and managed
- [Understanding Results](../guides/understanding-results.md) — Comparing pool performance in benchmark output
- [Test Matrix Explained](../architecture/test-matrix-explained.md) — How pools fit into the test matrix
