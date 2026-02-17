# Comparing Runs

[Back to Documentation Index](../index.md)

This guide walks through the end-to-end workflow for comparing two test runs side-by-side using `06-generate-report.sh --compare`. The comparison report highlights performance improvements, regressions, and unchanged metrics across all common test configurations.

## When to Use Comparison Reports

Comparison reports are useful whenever you want to measure the impact of a change:

- **StorageClass parameter changes** — Measuring the effect of enabling `exclusive-lock` or `rxbounce` image features
- **Firmware or driver updates** — Before/after comparison on the same cluster hardware
- **Cluster scaling** — Comparing performance with 3 workers vs 6 workers
- **Topology changes** — Testing the same pools on a bare metal vs VSI cluster
- **Ceph tuning** — Evaluating PG count, `targetSizeRatio`, or pool parameter changes

## Prerequisites

Before generating a comparison report, ensure:

1. **Both runs have completed result collection.** Each run needs a CSV file at `reports/results-<run-id>.csv`. This is produced by `05-collect-results.sh` (or automatically by `run-all.sh`).

2. **Python 3 is installed.** The comparison uses Python's standard library only (`csv`, `json`) — no extra packages are needed.

3. **The runs have overlapping test configurations.** The comparison joins on the 6-field key `(pool, vm_size, pvc_size, concurrency, profile, block_size)`. Only tests present in both runs are compared. Tests unique to one run are counted but not included in the delta analysis.

### Verifying Your CSVs Exist

```bash
ls reports/results-*.csv
```

You should see entries like:

```
reports/results-perf-20260210-100000.csv
reports/results-perf-20260215-120000.csv
```

## Step 1: Generate the Comparison Report

```bash
./06-generate-report.sh --compare perf-20260210-100000 perf-20260215-120000
```

The first argument is the **baseline** run (the "before"), and the second is the **candidate** run (the "after"). Deltas are calculated as `(candidate - baseline) / baseline × 100%`.

Expected output:

```
[INFO] === Generating Comparison Report ===
[INFO] Generating comparison report: reports/compare-perf-20260210-100000-vs-perf-20260215-120000.html
[INFO] Comparison report generated: reports/compare-perf-20260210-100000-vs-perf-20260215-120000.html
[INFO]
[INFO] === Comparison Report Generated ===
[INFO]   HTML: reports/compare-perf-20260210-100000-vs-perf-20260215-120000.html
```

## Step 2: Open the Report

```bash
open reports/compare-perf-20260210-100000-vs-perf-20260215-120000.html
```

The report is a self-contained HTML file with no external dependencies — all CSS and JavaScript are inline. It can be shared, archived, or viewed offline.

## Reading the Comparison Report

### Summary Bar

The top of the report shows aggregate counts:

| Stat | Meaning |
|------|---------|
| **Common Tests** | Number of test configurations present in both runs |
| **Improvements** | Metric values that improved by more than 1% |
| **Regressions** | Metric values that regressed by more than 1% |
| **Unchanged** | Metric values within ±1% (considered noise) |
| **Only in \<baseline\>** | Tests in the baseline that have no matching candidate test |
| **Only in \<candidate\>** | Tests in the candidate that have no matching baseline test |

The 1% threshold for "unchanged" helps filter out normal run-to-run variance.

### Filter Dropdowns

Below the summary, interactive dropdowns let you filter the table by:
- Storage pool
- VM size
- PVC size
- fio profile
- Block size

Filters apply immediately — the table and summary counts update in real time.

### Delta Columns

For each metric, three columns are shown:

| Column | Content |
|--------|---------|
| Baseline value | The metric value from the first (baseline) run |
| Candidate value | The metric value from the second (candidate) run |
| Delta | Percentage change, color-coded |

Delta coloring is **direction-aware**:

- **Green** means the metric improved (higher IOPS/bandwidth, or lower latency)
- **Red** means the metric regressed (lower IOPS/bandwidth, or higher latency)
- **Gray** means unchanged (within ±1%)

### Tests Only in One Run

If the runs used different pool sets or test matrices, some tests will appear only in one run. These are counted in the summary bar but not shown in the comparison table. To include them, ensure both runs use the same flags (e.g., both `--quick` or both `--overview`).

## Metrics and Delta Calculation

The comparison evaluates 8 metrics per test:

| Metric | Unit | Better When | Delta Formula |
|--------|------|-------------|---------------|
| Read IOPS | ops/s | Higher | `(candidate - baseline) / baseline × 100` |
| Write IOPS | ops/s | Higher | same |
| Read Bandwidth | KiB/s | Higher | same |
| Write Bandwidth | KiB/s | Higher | same |
| Read Avg Latency | ms | Lower | same formula, but negative delta = improvement |
| Write Avg Latency | ms | Lower | same |
| Read p99 Latency | ms | Lower | same |
| Write p99 Latency | ms | Lower | same |

When multiple fio jobs exist for the same test key (e.g., concurrency > 1 producing multiple VM results), the values are averaged before comparison.

## Ensuring Comparable Runs

For meaningful comparisons, minimize uncontrolled variables:

### Matching Test Configurations

Use the same flags for both runs. Comparing a `--quick` run against a full matrix run will produce few or no matching test keys.

```bash
# Good: same flags, both quick
./04-run-tests.sh --quick    # Run 1
# ... make changes ...
./04-run-tests.sh --quick    # Run 2

# Bad: different modes
./04-run-tests.sh --quick    # Run 1
./04-run-tests.sh --rank     # Run 2 — different profiles, won't match
```

### Isolating Variables

Change only one thing between runs. If you change both the StorageClass parameters and add more worker nodes, you won't know which change caused the performance difference.

### Pool Name Consistency

The comparison joins on pool names. If you rename a pool between runs (e.g., `rep3` to `rep3-virt`), those tests won't match. Keep pool names stable across runs you intend to compare.

## Typical Workflows

### StorageClass Parameter Change

Test the impact of adding VM-optimized RBD image features:

```bash
# Baseline: run tests with current StorageClass
./run-all.sh --quick
# Note the run ID from output, e.g., perf-20260214-103000

# Make the change: recreate StorageClass with new imageFeatures
oc delete sc perf-test-sc-rep2
# ... apply updated SC YAML with exclusive-lock, object-map, fast-diff ...

# Candidate: re-run with the same flags
./run-all.sh --quick --skip-setup
# Note the run ID, e.g., perf-20260215-080000

# Compare
./06-generate-report.sh --compare perf-20260214-103000 perf-20260215-080000
```

### Firmware Update

Before/after comparison across a maintenance window:

```bash
# Before firmware update
./run-all.sh --rank
# Run ID: perf-20260210-100000

# ... apply firmware update, reboot nodes ...

# After firmware update
./run-all.sh --rank --skip-setup
# Run ID: perf-20260212-090000

# Compare
./06-generate-report.sh --compare perf-20260210-100000 perf-20260212-090000
```

### Cluster Topology Comparison

Compare the same pools on two different clusters by copying the CSV:

```bash
# On cluster A (3x bare metal):
./run-all.sh --quick
scp reports/results-perf-20260210-100000.csv user@workstation:/tmp/

# On cluster B (6x bare metal):
./run-all.sh --quick
scp reports/results-perf-20260215-120000.csv user@workstation:/tmp/

# On workstation: copy both CSVs into the same reports/ directory
cp /tmp/results-perf-2026021*.csv reports/
./06-generate-report.sh --compare perf-20260210-100000 perf-20260215-120000
```

## Limitations

- **Not integrated into `run-all.sh`** — Comparison is a manual step after two runs complete. There is no `--compare` flag on `run-all.sh`.
- **Pairwise only** — Compares exactly two runs. There is no multi-run aggregation or trend analysis.
- **No statistical significance** — The report shows raw deltas without confidence intervals. Run-to-run variance of ±1-3% is normal for storage benchmarks; treat small deltas with caution.
- **Averaged multi-job results** — When multiple fio jobs exist per test key, values are averaged. This may mask per-VM variance in high-concurrency tests.

## Next Steps

- [Understanding Results](understanding-results.md) — How to read the standard performance reports
- [Running Tests](running-tests.md) — Step-by-step test execution walkthrough
- [Troubleshooting](troubleshooting.md) — Common failures and how to fix them
