# Running Tests

[Back to Index](../index.md)

This page walks through running the test suite step by step, explaining what each script does and what to expect.

## Before You Start

1. Ensure all [prerequisites](prerequisites.md) are met
2. Review [configuration](configuration-reference.md) and adjust `00-config.sh` if needed
3. Verify cluster connectivity: `oc get nodes`

## Step 1: Set Up ODF Storage Pools

```bash
./01-setup-storage-pools.sh
```

**What it does:**
- Creates CephBlockPools in the `openshift-storage` namespace for each pool defined in `ODF_POOLS` (except rep3, which uses the default ROKS pool)
- Creates corresponding StorageClasses with the `perf-test-sc-` prefix
- Waits for each pool to reach `Ready` state
- If `rep3-enc` is in the pool list, creates the `ceph-csi-kms-token` secret in the test namespace (required for encrypted PVC provisioning). See [Encrypted Storage Setup](encrypted-storage-setup.md) for details.

**Expected output:**
```
[config] Run ID: perf-20260214-103000
[INFO] Creating CephBlockPool: perf-test-rep2 (replicated, size=2)
[INFO] Creating StorageClass: perf-test-sc-rep2
[INFO] Creating CephBlockPool: perf-test-ec-2-1 (erasurecoded, k=2, m=1)
...
[INFO] All storage pools created successfully
```

**Duration:** 2-5 minutes

**Verify:**
```bash
oc get cephblockpool -n openshift-storage | grep perf-test
oc get sc | grep perf-test
```

## Step 2: Discover File Storage

```bash
./02-setup-file-storage.sh
```

**What it does:**
- If `FILE_CSI_DISCOVERY=auto`, discovers all `vpc-file` StorageClasses on the cluster
- If `FILE_CSI_DEDUP=true` (the default), filters out `-metro-`, `-retain-`, and `-regional*` StorageClass variants (metro/retain produce identical I/O on single-zone clusters; regional SCs use the `rfs` profile which requires IBM support allowlisting)
- Writes the filtered list to `results/file-storage-classes.txt`
- Falls back to the `FILE_CSI_PROFILES` list if discovery finds nothing

**Expected output:**
```
[INFO] Discovering IBM Cloud File CSI StorageClasses...
[INFO] Found 17 vpc-file StorageClasses
[INFO] FILE_CSI_DEDUP=true — filtering -metro-, -retain-, and -regional* variants
[INFO] After dedup: 5 unique file storage classes:
[INFO]   ibmc-vpc-file-500-iops
[INFO]   ibmc-vpc-file-1000-iops
...
```

Set `FILE_CSI_DEDUP=false` to include all variants (useful for multi-zone clusters). See [Configuration Reference](configuration-reference.md#why-filter--metro--and--retain--variants) for the rationale.

**Duration:** A few seconds

## Step 3: Run Tests

This is the main step. Choose one of three modes:

### Full Test Matrix

```bash
./04-run-tests.sh
```

Runs every combination of pools, VM sizes, PVC sizes, concurrency levels, fio profiles, and block sizes. See [Test Matrix Explained](../architecture/test-matrix-explained.md) for details on what this covers.

**Duration:** 12-24 hours (depends on the number of pools and cluster performance)

### Quick Smoke Test

```bash
./04-run-tests.sh --quick
```

Runs a reduced matrix: small VM only, 150Gi PVC only, concurrency 1 only, 2 profiles (random-rw, sequential-rw), 2 block sizes (4k, 1M).

**Duration:** 2-4 hours

**When to use:** First run on a new cluster to validate everything works before committing to the full matrix.

### Single Pool Test

```bash
./04-run-tests.sh --pool rep3
```

Runs the full matrix but only for one storage pool. Useful for:
- Focused comparison after initial results
- Re-running a pool that had issues
- Testing a newly added pool

**Duration:** ~3-5 hours per pool

### What Happens During a Test Run

VMs are created once per (pool × vm_size × pvc_size × concurrency) group and reused across all fio profile and block size permutations:

1. **fio profile is rendered** — Block size and runtime variables substituted into the `.fio` template
2. **Cloud-init is rendered** — fio job, SSH key, and systemd service assembled into cloud-init YAML
3. **VMs are created** — N VMs (where N = concurrency level) are created via `oc apply`
4. **VMs boot and run fio** — The suite waits for VMs to reach Running state, then waits for the first fio run to complete
5. **Results are collected** — fio JSON output is copied from each VM via `virtctl ssh`
6. **For each remaining (profile × block_size) permutation:**
   - fio job file is replaced in each VM via SSH (`replace_fio_job`)
   - Benchmark service is restarted (`restart_fio_service`)
   - Suite waits for fio to complete, then collects results
7. **VMs are deleted** — All VMs and their PVCs are cleaned up after all permutations in the group

Progress is logged with test numbering:
```
[INFO] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[INFO] Test 42/480: pool=rep3 vm=small pvc=150Gi conc=1 profile=random-rw bs=4k
[INFO] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Monitoring a Running Test

While the test suite runs, you can monitor progress:

```bash
# Watch VMs in the test namespace
oc get vmi -n vm-perf-test -w

# Check test suite logs (in another terminal)
tail -f results/perf-*.log

# View PVCs being created and bound
oc get pvc -n vm-perf-test

# Check Ceph health during tests
oc exec -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph status
```

### Interrupting a Test

Press **Ctrl+C** to stop the test suite. The trap handler will:
1. Delete all VMs with the current run-id label
2. Delete all PVCs with the current run-id label
3. Exit

Results collected before the interruption are preserved. You can re-run with `--pool` to test only the pools you missed.

## Step 4: Aggregate Results

```bash
./05-collect-results.sh
```

**What it does:**
- Walks the `results/` directory tree
- Parses every fio JSON file using `jq`
- Extracts key metrics (IOPS, bandwidth, average latency, p99 latency) for reads and writes
- Produces an aggregated CSV file in `reports/`

**Expected output:**
```
[INFO] Aggregating results into reports/perf-20260214-103000-results.csv
[INFO] CSV generated: reports/perf-20260214-103000-results.csv (2847 rows)
```

**Duration:** A few seconds to a minute, depending on result count.

## Step 5: Generate Reports

```bash
./06-generate-report.sh
```

**What it does:**
- Reads the aggregated CSV
- Generates three report formats in `reports/`:
  1. **HTML Dashboard** — Interactive Chart.js charts with filter dropdowns
  2. **Markdown Summary** — Text tables with key metrics
  3. **XLSX Workbook** — Excel file with raw data and summary charts

**Expected output:**
```
[INFO] Generating Markdown report: reports/perf-20260214-103000-report.md
[INFO] Generating HTML dashboard: reports/perf-20260214-103000-dashboard.html
[INFO] Generating XLSX workbook: reports/perf-20260214-103000-report.xlsx
```

**Duration:** A few seconds.

Open the HTML dashboard in a browser for the best analysis experience. See [Understanding Results](understanding-results.md) for how to read the reports.

## Step 6: Cleanup

### VMs and PVCs Only (Default)

```bash
./07-cleanup.sh
```

Removes all VMs, PVCs, and DataVolumes labeled `app=vm-perf-test`. Preserves storage pools and StorageClasses for future test runs.

### Full Cleanup

```bash
./07-cleanup.sh --all
```

Removes everything: VMs, PVCs, custom CephBlockPools, custom StorageClasses, and the test namespace.

### Dry Run

```bash
./07-cleanup.sh --all --dry-run
```

Shows what would be deleted without actually deleting anything. Always run this first if you're unsure.

## Typical Workflows

### First-Time Validation

```bash
./01-setup-storage-pools.sh
./02-setup-file-storage.sh
./04-run-tests.sh --quick            # Quick smoke test first
./05-collect-results.sh
./06-generate-report.sh
# Review results, verify everything works
./07-cleanup.sh                      # Clean VMs only, keep pools
```

### Full Benchmark Run

```bash
./01-setup-storage-pools.sh          # Skip if pools already exist
./02-setup-file-storage.sh
./04-run-tests.sh                    # Full matrix (12-24 hours)
./05-collect-results.sh
./06-generate-report.sh
# Analyze reports
./07-cleanup.sh --all                # Full cleanup when done
```

### Focused Pool Comparison

```bash
./04-run-tests.sh --pool rep3
./04-run-tests.sh --pool ec-2-1
./05-collect-results.sh
./06-generate-report.sh
# Compare rep3 vs ec-2-1 in the dashboard
```

## Next Steps

- [Understanding Results](understanding-results.md) — How to read and analyze the output
- [Troubleshooting](troubleshooting.md) — What to do when things go wrong
- [Test Matrix Explained](../architecture/test-matrix-explained.md) — Deep dive into the test loop
