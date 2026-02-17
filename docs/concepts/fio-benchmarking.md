# fio Benchmarking

[Back to Index](../index.md)

This page explains fio (Flexible I/O Tester) — the tool at the heart of this benchmarking suite. Understanding fio's parameters, I/O patterns, and output metrics is essential for interpreting test results.

## What Is fio?

**fio** is the industry-standard open-source tool for benchmarking storage I/O performance. It can simulate virtually any I/O workload pattern and produces detailed statistics about throughput, IOPS, and latency.

fio is used by storage vendors, cloud providers, and engineers worldwide to:
- Benchmark new storage hardware
- Compare storage configurations
- Validate SLAs and performance requirements
- Reproduce and debug I/O performance issues

## Key fio Parameters

These are the parameters used throughout this project. All are configured in `00-config.sh` and rendered into fio job files at runtime.

### I/O Engine (`ioengine`)

The method fio uses to submit I/O operations. This project uses **libaio** (Linux native asynchronous I/O), which allows fio to submit multiple I/O requests without waiting for each to complete. This is the recommended engine for benchmarking modern storage.

### Block Size (`bs`)

The size of each I/O operation. Dramatically affects results:

| Block Size | Tests | Typical For |
|-----------|-------|-------------|
| **4k** | IOPS capability | Databases, random access, metadata operations |
| **64k** | Mid-range I/O | Mixed workloads, application servers |
| **1M** | Throughput capability | Backups, bulk data transfer, sequential processing |

The project tests all three block sizes with generic profiles (sequential-rw, random-rw, mixed-70-30). Workload-specific profiles (db-oltp, app-server, data-pipeline) use their own per-job block sizes.

### I/O Depth (`iodepth`)

How many I/O requests fio keeps in-flight at once. Default: **32**.

```
Low iodepth (1):   Request → Wait → Request → Wait → ...
                   (tests single-operation latency)

High iodepth (32): Request →  Request →  Request →  ...
                      Wait →     Wait →     Wait →  ...
                   (saturates the storage pipeline)
```

Higher iodepth utilizes the full parallelism of NVMe devices and Ceph clusters. An iodepth of 1 measures pure latency; iodepth of 32 reveals maximum throughput.

### Number of Jobs (`numjobs`)

How many parallel fio processes to run. Default: **4**. Each job independently runs the workload. Combined with iodepth, total I/O parallelism = numjobs x iodepth.

With 4 jobs and iodepth 32, fio maintains up to 128 concurrent I/O operations — enough to saturate most storage backends.

### Runtime (`runtime`)

How long each fio test runs in seconds. Default: **120 seconds**. Longer runtimes produce more stable, representative results by averaging out transient effects.

### Ramp Time (`ramp_time`)

Warmup period before fio starts recording metrics. Default: **10 seconds**. This lets caches, I/O schedulers, and storage queues reach a steady state before measurement begins.

### File Size (`size`)

The size of the test file fio creates. Default: **4G**. The file must be large enough to prevent the storage system from caching the entire dataset. 4G per job (with 4 jobs = 16G total) exceeds typical read-ahead buffers.

### Direct I/O (`direct=1`)

**Critical for benchmarking.** With `direct=1`, fio uses O_DIRECT to bypass the Linux page cache entirely. Every read goes to storage, every write goes to storage. Without this, you'd be benchmarking your RAM speed, not your storage speed.

### Group Reporting (`group_reporting`)

Aggregates metrics across all jobs into a single result. Without this, you'd get separate statistics for each of the 4 jobs. Group reporting provides a unified view.

### Time-Based (`time_based`)

Runs for the specified `runtime` regardless of how much data is transferred. Without this, fio would stop after writing `size` bytes, which could complete too quickly for some configurations.

## I/O Patterns

fio supports many I/O patterns. This project tests six:

### Sequential Read/Write (`rw=read` / `rw=write`)
Reads or writes data in order from beginning to end. Tests **throughput (bandwidth)**. Typical for backups, video streaming, log files, bulk data processing.

### Random Read/Write (`rw=randread` / `rw=randwrite`)
Reads or writes data at random positions. Tests **IOPS**. Typical for databases, VM disk activity, file servers.

### Mixed Random (`rw=randrw`)
Random reads and writes mixed together. The ratio is controlled by `rwmixread`/`rwmixwrite`. The mixed-70-30 profile uses 70% reads, 30% writes — a common application pattern.

### fsync Writes
The db-oltp profile's WAL job uses `fsync=1`, which forces every write to be flushed to the storage device. This is critical for database durability — a "successful" write must survive a power failure. fsync dramatically increases write latency but is required for realistic database benchmarking.

## Key Output Metrics

When fio completes, it produces JSON output with these metrics for each job:

### IOPS (I/O Operations Per Second)

How many read or write operations completed per second. Higher is better.

- **Random 4k IOPS** is the most common storage benchmark metric
- Storage vendors quote IOPS at specific block sizes and queue depths
- This project reports read IOPS and write IOPS separately

### Bandwidth (BW)

Data transfer rate in KiB/s. The CSV and reports also show MiB/s for readability.

- **Sequential 1M bandwidth** measures maximum throughput
- Bandwidth = IOPS x block_size
- Example: 50,000 IOPS at 4k = ~195 MiB/s; 500 IOPS at 1M = ~500 MiB/s

### Latency

Time for a single I/O operation to complete. Reported in the project as milliseconds.

| Metric | What It Tells You |
|--------|-------------------|
| **Average (mean)** | Overall I/O speed. Good for general comparison. |
| **p99 (99th percentile)** | 99% of operations complete within this time. Catches tail latency spikes. |

Low average latency with high p99 latency means occasional stalls — important for user-facing applications and databases. The test suite captures both average and p99 for reads and writes.

### Understanding the Relationship

```
          ┌───────────────────────────────────────────┐
          │        Performance Triangle               │
          │                                           │
          │   IOPS ←──── Block Size ────→ Bandwidth   │
          │    ↑                              ↑       │
          │    │         Latency              │       │
          │    │        (inverse)             │       │
          │    └──────────────────────────────┘       │
          └───────────────────────────────────────────┘

Small blocks (4k)  → High IOPS, low bandwidth
Large blocks (1M)  → Low IOPS, high bandwidth
Lower latency      → Higher IOPS (at fixed queue depth)
```

## fio Job File Format

fio uses INI-style job files. A `[global]` section sets defaults, and named sections define individual jobs:

```ini
[global]
ioengine=libaio
direct=1
runtime=120
iodepth=32

[seq-read]
rw=read
bs=1M

[seq-write]
rw=write
bs=1M
stonewall        # Wait for previous job to finish
```

The **stonewall** directive ensures jobs run sequentially, not in parallel. This project uses stonewall between all jobs to isolate measurements.

## fio JSON Output

fio outputs structured JSON (with `--output-format=json+`) that the test suite parses. The key fields extracted are:

```json
{
  "jobs": [
    {
      "jobname": "seq-read",
      "read": {
        "iops": 45230.5,
        "bw": 45230,
        "lat_ns": {
          "mean": 706523.0,
          "percentile": {
            "99.000000": 1187840
          }
        }
      },
      "write": {
        "iops": 0,
        "bw": 0,
        "lat_ns": { "mean": 0 }
      }
    }
  ]
}
```

The `05-collect-results.sh` and `lib/report-helpers.sh` scripts parse these JSON files into CSV rows for analysis.

## Next Steps

- [fio Profiles Reference](../architecture/fio-profiles-reference.md) — Detailed breakdown of all 6 profiles used in this project
- [Understanding Results](../guides/understanding-results.md) — How to read and analyze fio benchmark output
- [Configuration Reference](../guides/configuration-reference.md) — Adjusting fio parameters
