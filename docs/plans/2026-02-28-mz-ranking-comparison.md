# MZ ODF Ranking + Cross-Cluster Comparison — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rank ODF StorageClasses on the multi-zone cluster and compare against the single-zone ranking to measure the performance impact of cross-AZ replica placement.

**Architecture:** Run existing pipeline scripts (no code changes) on `ocp-virt-mz-cluster`: setup pools → rank → report → compare with SZ run `perf-20260227-203655`.

**Tech Stack:** Bash pipeline (01/04/05/06 scripts), KubeVirt VMs, fio, Ceph ODF, `oc` CLI.

---

### Task 1: Verify MZ Cluster Readiness

**Step 1: Confirm cluster context**

```bash
oc config current-context
# Expected: ocp-virt-mz-cluster/d6hbqsbd0famjrol5ukg/admin
```

**Step 2: Verify all 24 OSDs are healthy**

```bash
oc -n openshift-storage get pods -l app=rook-ceph-osd --no-headers | grep -c Running
# Expected: 24
```

```bash
oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph.health}'
# Expected: HEALTH_OK
```

**Step 3: Verify OpenShift Virtualization is ready**

```bash
oc get csv -n openshift-cnv --no-headers | grep kubevirt-hyperconverged | awk '{print $NF}'
# Expected: Succeeded
```

**Step 4: Verify no stale perf-test resources**

```bash
oc get vm -l app=vm-perf-test --all-namespaces --no-headers 2>/dev/null | wc -l
# Expected: 0
```

---

### Task 2: Create Custom ODF Pools on MZ (~5-10 min)

**Step 1: Run the setup script**

```bash
cd /Users/neiltaylor/Projects/storage_perf_tests
./01-setup-storage-pools.sh
```

**Expected output:**
- Detects `failureDomain: zone` from StorageCluster status
- Creates CephBlockPool `perf-test-rep2` (rep size 2, failureDomain=zone)
- Creates CephBlockPool `perf-test-ec-2-1` (EC 2+1, failureDomain=zone)
- Creates CephFilesystem `perf-test-cephfs-rep2` (rep size 2 data, failureDomain=zone)
- Creates StorageClasses: `perf-test-sc-rep2`, `perf-test-sc-ec-2-1`, `perf-test-sc-cephfs-rep2`
- Skips ec-3-1, ec-2-2, ec-4-2 with topology warnings (only 3 zones)
- Waits for PG autoscaler convergence

**Step 2: Verify pools were created**

```bash
oc get cephblockpool -n openshift-storage --no-headers | grep perf-test
# Expected: perf-test-rep2, perf-test-ec-2-1 both Ready
```

```bash
oc get cephfilesystem -n openshift-storage --no-headers | grep perf-test
# Expected: perf-test-cephfs-rep2 Ready
```

```bash
oc get sc | grep perf-test
# Expected: perf-test-sc-rep2, perf-test-sc-ec-2-1, perf-test-sc-cephfs-rep2
```

---

### Task 3: Run Ranking on MZ (~50-60 min)

**Step 1: Dry run to preview the test matrix**

```bash
./04-run-tests.sh --rank --dry-run
```

**Expected:** 7 pools x 3 tests = 21 permutations. Pools: rep3, rep3-virt, rep3-enc, cephfs-rep3, rep2, cephfs-rep2, ec-2-1. No IBM Cloud File CSI pools (02/03 setup scripts not run).

**Step 2: Run the ranking**

```bash
./04-run-tests.sh --rank
```

**Expected runtime:** ~50-60 min (~8.5 min per pool x 7 pools).

**What happens per pool:**
1. Creates a KubeVirt VM with 150Gi data PVC on the pool's StorageClass
2. Waits for VM to boot and DataVolume clone to complete
3. Runs `random-rw/4k` (60s + 10s ramp), collects fio JSON
4. Replaces fio job via SSH, runs `sequential-rw/1M`, collects
5. Replaces fio job via SSH, runs `mixed-70-30/4k`, collects
6. Deletes VM
7. Checkpoints and moves to next pool

**Step 3: Verify the run completed**

```bash
ls results/perf-*.checkpoint | tail -1
# Note the RUN_ID from the filename
```

```bash
find results/ -name "*-fio.json" -newer results/perf-*.checkpoint | head -5
# Expected: fio JSON files for each pool/profile/blocksize combination
```

---

### Task 4: Collect Results and Generate Reports

**Step 1: Collect and aggregate results**

```bash
./05-collect-results.sh
```

**Expected:** Creates `reports/results-<RUN_ID>.csv` with 21+ rows (7 pools x 3 tests, possibly multiple jobs per test).

**Step 2: Verify the CSV**

```bash
ls -la reports/results-perf-*.csv | tail -1
# Note the MZ RUN_ID
```

```bash
awk -F, '{print $1}' reports/results-<MZ_RUN_ID>.csv | sort -u
# Expected: 7 ODF pool names + header
```

**Step 3: Generate the MZ ranking report**

```bash
./06-generate-report.sh --rank
```

**Expected output:** `reports/ranking-<MZ_RUN_ID>.html`
- Composite score leaderboard
- Per-workload rankings (random IOPS, sequential BW, mixed IOPS)
- Latency ranking table

---

### Task 5: Generate Cross-Cluster Comparison

**Step 1: Verify the SZ CSV is in place**

```bash
ls -la reports/results-perf-20260227-203655.csv
# Expected: exists, 56 lines, contains 11 pools including the 7 ODF pools
```

**Step 2: Generate the comparison report**

```bash
./06-generate-report.sh --compare <MZ_RUN_ID> perf-20260227-203655
```

Replace `<MZ_RUN_ID>` with the actual run ID from Task 4.

**Expected output:** `reports/compare-<MZ_RUN_ID>-vs-perf-20260227-203655.html`
- Joins on 7 common ODF pools (File CSI pools only in SZ, shown as "only in run 2")
- Per-metric deltas: green = MZ better, red = MZ worse
- Summary: improvement/regression/unchanged counts

**Step 3: Verify the comparison has data**

```bash
ls -la reports/compare-*-vs-perf-20260227-203655.html
# Expected: file exists, non-empty
```

---

### Task 6: Record Results in docs/

**Step 1: Copy reports to docs for reference**

```bash
cp reports/ranking-<MZ_RUN_ID>.html docs/
cp reports/compare-<MZ_RUN_ID>-vs-perf-20260227-203655.html docs/
```

**Step 2: Update the cluster comparison doc with ranking results**

Append a "Ranking Results" section to `docs/odf-cluster-comparison.md` summarizing:
- MZ composite scores and pool rankings
- Key deltas vs SZ (write IOPS regression %, read latency delta, p99 impact)
- Whether the expected outcomes from the design doc matched reality

---

### Task 7: Cleanup Test VMs (if not auto-cleaned)

**Step 1: Check for leftover VMs**

```bash
oc get vm -l app=vm-perf-test --all-namespaces --no-headers 2>/dev/null
# Expected: empty (04-run-tests.sh cleans up after each pool)
```

**Step 2: If VMs remain, clean up**

```bash
./07-cleanup.sh
# Only needed if Task 3 was interrupted
```

---

## Failure Scenarios

**Pool creation fails (Task 2):**
- EC pool needs more failure domains → automatic skip, not a failure
- CephFS CSI auth caps issue → script handles via `update_cephfs_csi_caps()`
- KMS secret issue (seen during OSD scale-up) → check `ibm-kp-secret` in openshift-storage

**VM fails to boot (Task 3):**
- DataVolume clone timeout → cross-AZ clone may be slower; check `oc get dv -n <ns>`
- SSH timeout → check VM console via `virtctl console`
- Use `--resume <RUN_ID>` to continue from where it stopped

**Comparison has no common tests (Task 5):**
- Pool names must match exactly between CSVs
- Check `awk -F, '{print $1}' reports/results-*.csv | sort -u` on both
