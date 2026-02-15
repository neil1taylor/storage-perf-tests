# fio Profiles Reference

[Back to Index](../index.md)

This page documents all six fio workload profiles used by the test suite. Each profile simulates a different real-world I/O pattern. Understanding what each profile tests helps you interpret benchmark results.

## Profile Summary

| Profile | Jobs | Block Sizes | Fixed BS? | Primary Metric | Real-World Analogy |
|---------|------|-------------|-----------|---------------|-------------------|
| sequential-rw | 2 | Variable | No | Bandwidth (MiB/s) | Backups, video, bulk data |
| random-rw | 2 | Variable | No | IOPS | Database random access, VM disks |
| mixed-70-30 | 1 | Variable | No | IOPS + Latency | Web apps, file servers |
| db-oltp | 4 | 4k, 8k | Yes | IOPS + Latency | PostgreSQL, MySQL |
| app-server | 4 | 4k, 16k | Yes | Mixed metrics | Java/Node app servers |
| data-pipeline | 5 | 128k–1M | Yes | Bandwidth | ETL, ML training, analytics |

**Variable BS** means the profile uses `${BLOCK_SIZE}` and runs once per block size (4k, 64k, 1M).
**Fixed BS** means each job defines its own block size, and the profile runs once with block size set to "native".

---

## sequential-rw

**File:** `fio-profiles/sequential-rw.fio`

Measures **maximum throughput** by reading and writing data sequentially from beginning to end. This is the simplest I/O pattern and reveals the peak bandwidth of the storage backend.

### Jobs

| Job | Pattern | Description |
|-----|---------|-------------|
| `seq-read` | `rw=read` | Sequential read from start to end |
| `seq-write` | `rw=write` | Sequential write from start to end |

### Parameters

All from global: `bs=${BLOCK_SIZE}`, `iodepth=${IODEPTH}` (32), `numjobs=${NUMJOBS}` (4), `stonewall` between jobs.

### What to Look For

- **1M block size** results show peak throughput — this is the maximum the storage can deliver
- **4k sequential** shows how well the storage handles small sequential I/O
- Compare pools: EC pools should perform similarly to replicated pools for sequential reads
- Write throughput reveals the cost of replication (rep3 must write 3 copies)

### Real-World Analogies
- Backup/restore operations
- Video streaming and media files
- Large file downloads
- Database full table scans

---

## random-rw

**File:** `fio-profiles/random-rw.fio`

Measures **IOPS** by reading and writing data at random positions. This is the most demanding I/O pattern for storage systems because it eliminates sequential prefetch benefits.

### Jobs

| Job | Pattern | Description |
|-----|---------|-------------|
| `rand-read` | `rw=randread` | Random read at arbitrary offsets |
| `rand-write` | `rw=randwrite` | Random write at arbitrary offsets |

### Parameters

All from global: `bs=${BLOCK_SIZE}`, `iodepth=${IODEPTH}` (32), `numjobs=${NUMJOBS}` (4), `stonewall` between jobs.

### What to Look For

- **4k random IOPS** is the industry-standard storage benchmark metric
- Compare storage pools: this is where EC vs replication differences are most visible
- Random write IOPS shows the write penalty of different data protection strategies
- Concurrency levels (1, 5, 10 VMs) reveal contention behavior

### Real-World Analogies
- Database index lookups
- Virtual machine disk activity
- Desktop/laptop general use
- Mail servers

---

## mixed-70-30

**File:** `fio-profiles/mixed-70-30.fio`

Simulates a **typical application workload** with 70% random reads and 30% random writes happening simultaneously. Most real applications have more reads than writes.

### Jobs

| Job | Pattern | Description |
|-----|---------|-------------|
| `mixed-70-30` | `rw=randrw, rwmixread=70` | Mixed random read/write |

### Parameters

All from global: `bs=${BLOCK_SIZE}`, `iodepth=${IODEPTH}` (32), `numjobs=${NUMJOBS}` (4). Single job, no stonewall needed.

### What to Look For

- How the storage handles concurrent reads and writes
- Whether write operations slow down reads (or vice versa)
- This profile is most representative of general-purpose workloads
- p99 latency here indicates worst-case application response times

### Real-World Analogies
- Web application backends
- File servers
- General-purpose VM workloads
- Content management systems

---

## db-oltp

**File:** `fio-profiles/db-oltp.fio`

Simulates a **database (PostgreSQL/MySQL) OLTP workload** with four distinct I/O patterns that databases produce. This is a fixed-BS profile — each job has its own block size.

### Jobs

| Job | Pattern | Block Size | iodepth | numjobs | Key Feature |
|-----|---------|-----------|---------|---------|-------------|
| `db-data-read` | `randread` | 8k | 16 | 4 | Random data page reads |
| `db-wal-write` | `write` | 8k | 1 | 1 | Sequential WAL with `fsync=1` |
| `db-oltp-mixed` | `randrw` (80/20) | 8k | 32 | 4 | Mixed OLTP transactions |
| `db-point-query` | `randread` | 4k | 1 | 1 | Single-threaded point queries |

### What Makes This Profile Special

**fsync=1** on the WAL job is critical. Databases require that WAL writes are durable — data must be on persistent storage before the transaction is acknowledged. The `fsync=1` setting forces every write to be flushed, which dramatically increases latency but is required for a realistic database benchmark.

**Low iodepth (1)** on point queries simulates single-threaded latency-sensitive queries. This measures the minimum possible latency of the storage system.

### What to Look For

- **WAL write latency** — Directly impacts database transaction commit time. Lower is better.
- **Point query latency** — The minimum latency the storage can achieve. Critical for SLA evaluation.
- **Data page read IOPS** — Determines how fast the database can scan indexes and tables.
- Compare pools: rep3 may have lower WAL latency because write path is simpler than EC.

### Real-World Analogies
- PostgreSQL with pgbench workload
- MySQL InnoDB transactional workloads
- E-commerce order processing
- Financial transaction systems

---

## app-server

**File:** `fio-profiles/app-server.fio`

Simulates a **general application server** with mixed I/O patterns: log writing, config file reads, temp file operations, and session/cache writes. This is a fixed-BS profile.

### Jobs

| Job | Pattern | Block Size | iodepth | numjobs | Key Feature |
|-----|---------|-----------|---------|---------|-------------|
| `app-log-write` | `write` | 16k | 4 | 2 | Sequential log writes with `fsync=4` |
| `app-config-read` | `randread` | 4k | 4 | 2 | Small random config/file reads |
| `app-temp-io` | `randrw` (60/40) | 16k | 8 | 4 | Mixed temp file operations |
| `app-session-write` | `randwrite` | 4k | 8 | 2 | Random session/cache writes |

### What Makes This Profile Special

**fsync=4** on log writes means fsync is called every 4 writes (not every write like db-oltp). This is typical for application logs where some write buffering is acceptable.

**Varied iodepth and numjobs** across jobs simulates how different parts of an application generate different I/O loads simultaneously.

### What to Look For

- **Log write throughput** — Can the storage keep up with application logging?
- **Config read latency** — Affects application startup and config-driven operations.
- **Session write IOPS** — Critical for web applications with server-side sessions.
- Overall balance: no single job should dominate; this tests how the storage handles diverse concurrent I/O.

### Real-World Analogies
- Java application servers (Tomcat, Spring Boot)
- Node.js/Python web backends
- Microservices with local logging
- Container workloads with persistent state

---

## data-pipeline

**File:** `fio-profiles/data-pipeline.fio`

Simulates a **data/AI pipeline workload** with large sequential I/O, streaming patterns, and mixed ETL operations. This is a fixed-BS profile.

### Jobs

| Job | Pattern | Block Size | iodepth | numjobs | Key Feature |
|-----|---------|-----------|---------|---------|-------------|
| `pipeline-ingest` | `write` | 1M | 32 | 4 | Bulk data write (Parquet/CSV) |
| `pipeline-scan` | `read` | 1M | 32 | 4 | Full dataset scan |
| `pipeline-shuffle` | `randread` | 256k | 16 | 4 | Random data augmentation reads |
| `pipeline-checkpoint` | `write` | 512k | 8 | 2 | Model checkpoint writes |
| `pipeline-etl` | `randrw` (70/30) | 128k | 32 | 4 | Mixed read-source/write-transformed |

### What Makes This Profile Special

**Large block sizes** (128k–1M) across all jobs. Data pipeline workloads operate on large chunks of data, not small database pages. This tests the storage's maximum throughput capability.

**High iodepth (32)** on ingest and scan jobs ensures the storage pipeline is fully saturated.

### What to Look For

- **Ingest/scan bandwidth** — Maximum throughput for bulk data operations.
- **Shuffle random read** — Important for ML training where data is accessed in random order.
- **Checkpoint write** — How fast can you write a model checkpoint? Important for training recovery.
- EC pools may shine here — their higher storage efficiency matters for large datasets, and the large block sizes minimize EC's per-operation overhead.

### Real-World Analogies
- Spark/Hadoop ETL jobs
- ML model training (PyTorch, TensorFlow)
- Data lake ingestion pipelines
- Large-scale analytics (Presto, Trino)

## Next Steps

- [fio Benchmarking](../concepts/fio-benchmarking.md) — fio fundamentals and key metrics
- [Understanding Results](../guides/understanding-results.md) — How to read benchmark output
- [Customization](../guides/customization.md) — Creating your own fio profiles
