# Understanding Results

[Back to Index](../index.md)

This page explains how to read and analyze the test suite output — from raw fio JSON to the HTML dashboard. After running `05-collect-results.sh` and `06-generate-report.sh`, you'll have several report formats to work with.

## Result Directory Structure

Raw fio JSON results are stored in a hierarchical directory tree:

```
results/
└── <pool>/
    └── <vm-size>/
        └── <pvc-size>/
            └── <concurrency>/
                └── <profile>/
                    └── <block-size>/
                        ├── <vm-name>-fio.json      # fio output
                        └── <vm-name>-sysinfo.txt   # CPU/memory/disk info
```

For concurrency > 1, there are multiple JSON files per test (one per VM). Each captures the same workload running simultaneously, revealing contention effects.

## Raw fio JSON

Each `-fio.json` file contains the full fio output. The key fields:

```json
{
  "jobs": [
    {
      "jobname": "rand-read",
      "read": {
        "iops": 45230.5,
        "bw": 180922,
        "lat_ns": {
          "mean": 706523.0,
          "percentile": {
            "99.000000": 1187840
          }
        }
      },
      "write": {
        "iops": 0,
        "bw": 0
      }
    }
  ]
}
```

| Field | Unit | Description |
|-------|------|-------------|
| `iops` | ops/sec | I/O operations per second |
| `bw` | KiB/s | Bandwidth (divide by 1024 for MiB/s) |
| `lat_ns.mean` | nanoseconds | Average latency (divide by 1,000,000 for ms) |
| `lat_ns.percentile["99.000000"]` | nanoseconds | 99th percentile latency |

For read-only jobs, write fields are 0 (and vice versa). Mixed jobs have both populated.

## fio JSON Validation

Before aggregation, each fio JSON file is validated for:
1. **Syntax** — valid JSON (via `jq empty`)
2. **Structure** — `.jobs` array is non-empty
3. **Fields** — each job contains both `read` and `write` stat objects

Invalid or empty files are logged as warnings and skipped. The collection summary reports counts of valid, invalid-syntax, and empty-jobs files so you can identify and re-run failed tests.

## Aggregated CSV

`05-collect-results.sh` parses all JSON files into a single CSV. The columns are:

| Column | Description |
|--------|-------------|
| `storage_pool` | Pool name (e.g., rep3, ec-2-1, ibmc-vpc-file-1000-iops) |
| `vm_size` | VM size label (small, medium, large) |
| `pvc_size` | PVC size (150Gi, 500Gi, 1000Gi) |
| `concurrency` | Number of VMs in this test |
| `fio_profile` | Profile name (sequential-rw, random-rw, etc.) |
| `block_size` | Block size (4k, 64k, 1M, or native) |
| `job_name` | Name of the fio job within the profile |
| `read_iops` | Read IOPS |
| `read_bw_kib` | Read bandwidth in KiB/s |
| `read_lat_avg_ms` | Average read latency in milliseconds |
| `read_lat_p99_ms` | 99th percentile read latency in milliseconds |
| `write_iops` | Write IOPS |
| `write_bw_kib` | Write bandwidth in KiB/s |
| `write_lat_avg_ms` | Average write latency in milliseconds |
| `write_lat_p99_ms` | 99th percentile write latency in milliseconds |

The CSV can be imported into any spreadsheet, database, or analysis tool.

## HTML Dashboard

The HTML dashboard is an interactive Chart.js-based report. Open it in a browser:

```bash
open reports/perf-*-dashboard.html
```

### Filters

The top of the dashboard has dropdown filters:
- **Storage Pool** — Filter to one pool or view all
- **VM Size** — Filter by VM size
- **PVC Size** — Filter by PVC size
- **fio Profile** — Filter by workload profile
- **Block Size** — Filter by block size

Filters apply to all four charts and the raw data table simultaneously.

### Charts

| Chart | Metric | What to Look For |
|-------|--------|------------------|
| **IOPS by Storage Pool** | Average read/write IOPS | Pool comparison — which backend delivers the most IOPS? |
| **Throughput by Storage Pool** | Average read/write bandwidth (MiB/s) | Maximum data transfer rate per pool |
| **Average Latency by Storage Pool** | Mean read/write latency (ms) | Typical I/O completion time |
| **p99 Latency by Storage Pool** | 99th percentile read/write latency (ms) | Tail latency — worst-case for 99% of operations |

Charts show averages across the filtered data. For the most meaningful comparison, filter to a specific profile and block size.

### Raw Data Table

Below the charts, a table shows up to 500 rows of the filtered data. Scroll through to see individual test results.

## Markdown Report

The Markdown report contains:
- Test configuration (VM sizes, PVC sizes, fio settings)
- Storage pools tested (ODF and File CSI)
- Summary tables for key metrics:
  - **Random 4k IOPS** — IOPS by pool and VM size
  - **Sequential 1M throughput** — Bandwidth by pool and VM size

This format is useful for embedding in documentation, wikis, or issue trackers.

## XLSX Workbook

The Excel workbook contains multiple sheets:
- **Summary** — Charts and summary statistics
- **Raw Data** — Full CSV data in spreadsheet format
- **Test Config** — Configuration parameters for reference

Use this for custom analysis with pivot tables, custom charts, and formulas.

## Analysis Tips

### Pool Comparison

Filter the dashboard to a specific profile and block size, then compare IOPS/latency across pools:

- **Random 4k IOPS** (profile=random-rw, bs=4k): The gold standard for storage comparison
- **Sequential 1M throughput** (profile=sequential-rw, bs=1M): Maximum bandwidth capability

Key questions:
- How much IOPS do EC pools lose vs rep3?
- Does EC throughput match replication for large sequential I/O?
- How does IBM Cloud File compare to ODF?

### PVC Size Impact

Filter to a single pool and profile, then compare across PVC sizes:
- Do larger PVCs perform better? (They may stripe across more OSDs)
- Is there a sweet spot beyond which adding PVC size doesn't help?

### Concurrency Effects

Filter to a single pool, profile, and PVC size, then compare concurrency levels:
- Does performance scale linearly from 1 to 5 to 10 VMs?
- At what concurrency does contention become visible?
- Which pool handles contention best?

### VM Size Impact

Filter to a single pool and compare VM sizes:
- Do larger VMs (more vCPUs) achieve higher IOPS?
- Is the storage or the VM the bottleneck?

### Block Size Effects

For variable-BS profiles, compare across block sizes:
- 4k → IOPS-focused (storage latency dominates)
- 64k → Balanced (both IOPS and throughput matter)
- 1M → Throughput-focused (bandwidth dominates)

### Latency Analysis

Pay attention to the gap between average and p99 latency:
- **Small gap:** Consistent performance
- **Large gap:** Tail latency spikes — some operations are much slower than average
- This is especially important for database workloads where p99 affects user experience

### Comparing db-oltp Results

The db-oltp profile has four distinct jobs. Look at them individually:
- `db-wal-write` — WAL write latency (lower = faster commits)
- `db-point-query` — Minimum achievable latency
- `db-data-read` — Index scan IOPS
- `db-oltp-mixed` — Overall OLTP capability

## Why File CSI Tests Take Longer

When running the test matrix, you'll notice that IBM Cloud File CSI pools take significantly longer per test than ODF (Ceph RBD) pools. This is expected behavior with two distinct causes.

### Slower VM startup: data PVC provisioning

All VMs use the same ODF-backed boot disk (DataVolume clone), so the actual VM boot time is consistent (~12-13s). However, the reported "boot time" includes waiting for the **data PVC** to bind — and for File CSI, this requires an IBM Cloud VPC API call to provision an NFS file share, adding 30-45 seconds. Observed first-boot times:

| Storage Backend | Reported Boot Time | Actual Boot | Data PVC Provisioning |
|----------------|-------------------|-------------|----------------------|
| ODF (rep3, rep2) | 12-13s | ~12s | <1s (local Ceph image) |
| ODF (ec-2-1, rep3-enc) | 24-25s | ~12s | ~12s (EC parity / encryption setup) |
| File CSI (500-IOPS) | 46s | ~12s | ~34s (IBM Cloud API) |
| File CSI (1000-IOPS) | 57s | ~12s | ~45s (IBM Cloud API) |

This is a one-time cost per VM group — VMs are reused across all fio profile and block size permutations within a group, so the provisioning latency is amortized over 18 tests.

### Slower fio runtime: IOPS-capped NFS shares

The fio profiles use `time_based=1` with `runtime=120s` + `ramp_time=10s`, running 2 job sections sequentially (`stonewall`). The minimum wall time per test is **(120s + 10s) x 2 = 4m20s**. ODF pools on NVMe finish close to this floor (~5 min) because test file creation (`size=4G`) is near-instant.

For File CSI, fio must write the 4G test file before each job section begins. At 500 IOPS with 4k blocks, sequential file creation runs at ~2 MB/s, adding several minutes of overhead per section. Combined with the timed runtime, File CSI tests take 9-14 minutes each vs 3-5 minutes for ODF.

This difference is a real measurement — it reflects the actual performance gap between NFS file shares (IOPS-capped by the provisioned tier) and Ceph RBD on NVMe (100k+ IOPS). The slower runtime is not a test artifact.

## Comparison Reports

When you have two runs to compare (e.g., before and after a tuning change), use:

```bash
./06-generate-report.sh --compare perf-20260214-103000 perf-20260215-080000
```

This generates a comparison HTML dashboard in `reports/` that shows:
- **Side-by-side metrics** — IOPS, bandwidth, and latency from both runs
- **Percentage delta** — Color-coded change for each metric (green = improvement, red = regression)
- **Direction-aware coloring** — Higher IOPS/bandwidth is green; higher latency is red

The comparison joins results on the 6-field test key (`pool:vm_size:pvc_size:concurrency:profile:block_size`). Tests present in only one run are shown but not compared.

This is useful for:
- **A/B testing** — Measuring the impact of StorageClass parameter changes (e.g., imageFeatures)
- **Firmware updates** — Before/after comparison on the same cluster
- **Cluster scaling** — Comparing performance with 3 vs 6 worker nodes
- **Configuration tuning** — Testing fio parameter changes or Ceph tuning

For the complete step-by-step workflow including prerequisites and tips for ensuring comparable runs, see [Comparing Runs](comparing-runs.md).

## Export and Further Analysis

### Custom CSV Analysis

```bash
# Load CSV in Python
import pandas as pd
df = pd.read_csv("reports/perf-*-results.csv")

# Filter to random 4k results
rand4k = df[(df.fio_profile == "random-rw") & (df.block_size == "4k")]

# Compare pools
rand4k.groupby("storage_pool")[["read_iops", "write_iops"]].mean()
```

### Import to Grafana

The CSV can be imported into Grafana using the CSV data source plugin for long-term tracking across multiple test runs.

## Comparing with VMware vSAN HCIBench Results

Both this test suite and VMware's [HCIBench](https://flings.vmware.com/hcibench) use the same approach — running fio inside VMs to measure the full I/O path from guest OS through the hypervisor to storage. This means results are directly comparable, provided the fio parameters match. See [Benchmark Methodology: HCIBench vs This Suite](../concepts/ceph-and-odf.md#benchmark-methodology-hcibench-vs-this-suite) for background on the two approaches.

### HCIBench Settings to Match This Suite

To produce comparable results on vSAN, configure HCIBench with these parameters:

#### For `random-rw` profile comparison (4k random IOPS)

| HCIBench Parameter | Value | Notes |
|---------------------|-------|-------|
| Block Size | 4K | Also test 64K and 1M for the full matrix |
| IO Depth (Outstanding IOs) | 32 | Matches `FIO_IODEPTH` |
| Threads per VMDK | 4 | Matches `FIO_NUMJOBS` |
| Read/Write % | 100/0, then 0/100 | Run separate read and write tests (our `rand-read` and `rand-write` jobs run sequentially) |
| Working Set Size | 4G per VMDK | Matches `FIO_TEST_FILE_SIZE`. HCIBench default is the full VMDK; use a smaller working set for a closer match |
| Duration | 120 seconds | Matches `FIO_RUNTIME` |
| Warm-Up Time | 10 seconds | Matches `FIO_RAMP_TIME`. HCIBench default is 300s; shorter is fine for NVMe-backed storage |
| Number of VMs | 1, 5, or 10 | Match the concurrency level you want to compare |
| VMDKs per VM | 1 | Our VMs have a single data PVC |
| IO Pattern | Random | |

#### For `mixed-70-30` profile comparison

| HCIBench Parameter | Value |
|---------------------|-------|
| Block Size | 4K (also 64K, 1M) |
| IO Depth | 32 |
| Threads per VMDK | 4 |
| Read/Write % | 70/30 |
| IO Pattern | Random |
| Other settings | Same as above |

#### For `db-oltp` profile comparison

The db-oltp profile uses fixed block sizes per job section, so compare each section individually:

| Job Section | HCIBench Block Size | Read/Write % | IO Depth | Threads | Notes |
|-------------|---------------------|-------------|----------|---------|-------|
| `db-data-read` | 8K | 100/0 | 16 | 4 | Random read |
| `db-wal-write` | 8K | 0/100 | 1 | 1 | Sequential write with fsync=1 |
| `db-oltp-mixed` | 8K | 80/20 | 32 | 4 | Random mixed |
| `db-point-query` | 4K | 100/0 | 1 | 1 | Random read, single-threaded latency |

### Parameters That Affect Comparability

| Parameter | Impact | Recommendation |
|-----------|--------|----------------|
| **IO depth** | Higher depth = higher IOPS but higher latency. Must match exactly. | Use 32 (our default) |
| **Threads (numjobs)** | More threads = more parallel I/O. Must match. | Use 4 (our default) |
| **Block size** | Determines whether you're measuring IOPS (4k) or throughput (1M). Must match. | Test all three: 4k, 64k, 1M |
| **Read/write ratio** | Must match the specific profile being compared. | See profile tables above |
| **Working set size** | Larger working set may exceed storage cache, lowering performance. Our default is 4G per VM. | Use 4G for apples-to-apples. HCIBench's default (full VMDK) exercises more address space but may show lower numbers if data spills out of cache |
| **Warm-up / ramp time** | HCIBench defaults to 300s; ours is 10s. Longer warm-up ensures steady state but shouldn't change results much on NVMe/SSD storage. | 10-30s is sufficient for flash; use 300s if testing hybrid (SSD + HDD) vSAN |
| **Number of VMs** | HCIBench often uses many VMs to saturate the cluster. Our suite uses 1, 5, or 10 to measure per-workload performance. | Match the concurrency level, not the total VM count |
| **`direct=1`** | Bypasses OS page cache. Both tools default to this. | Ensure "Use O_DIRECT" is enabled in HCIBench |

### Reading the Comparison

When comparing results:

- **Compare per-VM numbers, not aggregates.** If HCIBench ran 16 VMs and reports 200k aggregate IOPS, that's 12.5k IOPS per VM. Compare that to our concurrency=1 result for the equivalent profile and block size.
- **Match the RAID policy to the Ceph pool.** vSAN RAID-1 FTT=1 → compare with `rep2`. vSAN RAID-5 FTT=1 → compare with `ec-2-1`. See the [vSAN comparison table](../concepts/ceph-and-odf.md#vmware-vsan-comparison).
- **Account for hardware differences.** vSAN on NVMe bare metal vs ODF on NVMe bare metal is the fairest comparison. If the vSAN cluster uses SAS SSD or hybrid (SSD cache + HDD capacity), performance will differ regardless of the software layer.
- **Use the same metrics.** Compare read IOPS to read IOPS, p99 latency to p99 latency. Both tools report all standard fio metrics.

## Next Steps

- [fio Profiles Reference](../architecture/fio-profiles-reference.md) — What each profile measures
- [fio Benchmarking](../concepts/fio-benchmarking.md) — Understanding the metrics
- [Ceph Pool / vSAN Policy Mapping](../concepts/ceph-and-odf.md#vmware-vsan-comparison) — Which pool to compare against which vSAN policy
- [Troubleshooting](troubleshooting.md) — When results look wrong
