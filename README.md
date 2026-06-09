# VM Storage Performance Test Suite

Performance benchmarking for VMs on IBM Cloud ROKS with OpenShift Virtualization, testing ODF (Ceph) storage pools, IBM Cloud File CSI, IBM Cloud Block CSI, and IBM Cloud Pool CSI (FileSharePool).

Tested on a 3-node bare metal ROKS cluster (3x `bx2d.metal.96x384` with 8x 3200 NVMe, Frankfurt). Cross-platform comparison also available against VMware VCF on Classic (4x Dual Intel Xeon Gold 6248, 384 GB RAM, vSAN ESA).

## In Plain English: What To Configure

If you don't speak storage and just want to know which settings matter for VMs on this kind of cluster, this section is for you. The detailed evidence behind every claim is in [docs/guides/odf-performance-best-practices.md](docs/guides/odf-performance-best-practices.md).

A bit of vocabulary first, used once each:

- **OpenShift Data Foundation (ODF)** — the storage layer that backs your VM disks. Made up of many small storage worker processes (one per disk drive in the cluster). The configuration object that controls how it behaves is called `StorageCluster`.
- **Ceph** — the underlying storage engine inside ODF. When this guide says "Ceph setting", that's a config knob on the storage engine itself.
- **Worst-case slow operation** — when we say "worst-case" we mean the slowest 1% of disk operations. Average response times stay fast; the question is how slow the unlucky operations get under load.

### Step 1: change one setting on the storage layer (this is the big one)

Out of the box, the storage layer gives each storage worker only **2 CPUs**. That is enough for a quiet cluster, but it runs out of room very quickly. By the time **4 VMs** are doing real work at the same time, the storage workers have no CPU left — total work done across the cluster stops growing, and the slowest 1% of disk operations jump from about **5 ms to 45 ms** (a 9× slowdown).

There is a built-in setting that doubles each worker's CPU. Apply it like this:

```bash
oc patch storagecluster ocs-storagecluster -n openshift-storage \
  --type=merge -p='{"spec":{"resourceProfile":"performance"}}'
```

After the storage workers restart (about 5-10 minutes), each one has **4 CPUs and 8 GB of memory**.

**What you get** (measured on the reference cluster, 1 to 64 active VMs):

- Total work done roughly doubles. At full load: about **300,000 operations per second** instead of **158,000**.
- The cluster can keep up smoothly with **2-4× more active VMs** before slowing down.
- Slowest 1% of operations stay below 50 ms up to **16-32 active VMs**, instead of jumping to **hundreds of ms** at just 4 VMs.

**What it costs:** 48 more CPUs reserved cluster-wide for the storage layer. The reference cluster has 288 CPUs total, so there is plenty left for actual VMs. Check `oc adm top nodes` first on smaller hosts.

**If you only do one thing from this whole guide, do this.**

### Step 2: optional second tweak if you ever run lots of VMs at once

If you sometimes have **30 or more VMs** hitting storage at the same time, also tell the Ceph engine to use **20 GB of memory for caching** instead of the default 4 GB. No restart, no extra CPU.

```bash
# Record the setting in the StorageCluster (survives operator reconciles):
oc patch storagecluster ocs-storagecluster -n openshift-storage --type=merge \
  -p='{"spec":{"managedResources":{"cephCluster":{"cephConfig":{"osd":{"osd_memory_target":"20000000000"}}}}}}'

# Push it directly to Ceph as well — the ODF operator sometimes silently
# skips propagating this particular setting (observed on ODF 4.20):
oc -n openshift-storage exec deploy/rook-ceph-tools -- \
  ceph config set osd osd_memory_target 20000000000

# Verify (should return 20000000000, not 4294967296):
oc -n openshift-storage exec deploy/rook-ceph-tools -- \
  ceph config get osd osd_memory_target
```

**What you get** (on top of Step 1):

- At 32 active VMs: slowest 1% drops from about **200 ms to 67 ms** (3× better).
- At 64 active VMs: slowest 1% drops from about **800 ms to 400 ms** (2× better).
- Below ~16 active VMs there is no measurable improvement — the default 4 GB cache is enough.

**What it costs:** about 16 GB of memory per storage worker — memory you probably had spare.

**This is a complement to Step 1, not a replacement.** Step 1 buys throughput; Step 2 buys consistency at high load.

### When to consider the heavier "big-osd" option (usually not worth it)

There is a more aggressive setting where each storage worker gets **6 CPUs and 24 GB of memory**. We tested it. It delivers about **14% more peak throughput** at moderate VM counts, but it reserves so much cluster CPU (144 cores total) that VMs themselves start failing to start above ~50 active VMs — we hit `Insufficient CPU` scheduling errors at 56 VMs.

So big-osd is only worth it if **all three** are true:

1. Your hosts have plenty of spare CPU to give up (144 cores worth, cluster-wide).
2. Your workload specifically needs that extra 14% of peak speed.
3. You will never run more than about 50 simultaneous VMs.

Otherwise, stop at Step 1 (and optionally Step 2). The big-osd configuration is mostly useful as a research baseline — Step 2 above gives you most of its latency benefit at none of its CPU cost.

### Things that look tempting but aren't worth doing

- **Turning off CPU power-saving on worker nodes.** Only works on self-managed OpenShift. Managed Red Hat OpenShift on IBM Cloud (ROKS) blocks the required kernel-level changes — the configuration request just hangs.
- **Running data with only one copy ("rep1").** Twice as fast on writes, but if any one of the three hosts dies you permanently lose data. Useful only for measuring the hardware ceiling, never for production.
- **Stacking the "mclock" Ceph tuning bundle on top of VM IOThreads.** The two settings fight each other. Combined: both worst-case latencies more than double, throughput drops 9%. Pick one or the other, not both.
- **Manually changing the failure-domain setting per storage pool.** The storage operator computes it cluster-wide from your worker topology — overriding it per pool causes uneven data placement.

### The bottom line for most clusters

**Apply Step 1.** If you ever run 30+ active VMs and care about consistent response times, **also apply Step 2.** Those two settings deliver about 90% of the tuning value we measured across two weeks of experiments. Everything else covered in [the detailed guide](docs/guides/odf-performance-best-practices.md) is for specialised situations.

---

## Latest Ranking Results

Results from run `perf-20260227-203655` on a 3-node bare metal cluster (3x `bx2d.metal.96x384`, Frankfurt). Medium VM (4 vCPU, 8 GiB), 150 GiB PVC, concurrency=1, fio runtime 60s. RBD pools use `volumeMode: Block` for direct QEMU block device passthrough.

| Pool | Random 4k IOPS | Seq 1M (MiB/s) | Mixed 70/30 IOPS |
|------|---------------:|----------------:|-----------------:|
| rep2 | 71,966 | 8,306 | 53,574 |
| rep3 | 64,504 | 7,616 | 49,203 |
| rep3-virt | 64,483 | 7,599 | 48,641 |
| rep3-enc | 62,702 | 6,673 | 56,283 |
| cephfs-rep2 | 59,956 | 5,378 | 45,126 |
| bench-pool (Pool CSI) | 53,506 | 2,050 | 34,502 |
| ec-2-1 | 49,058 | 5,814 | 31,405 |
| cephfs-rep3 | 45,557 | 4,809 | 37,762 |
| ibmc-vpc-file-3000-iops | 5,839 | 375 | 2,996 |
| ibmc-vpc-file-1000-iops | 1,984 | 126 | 997 |
| ibmc-vpc-file-500-iops | 989 | 63 | 496 |

Key findings:
- **rep2 leads random IOPS** — 2-replica writes ack faster than 3-replica, giving 12% more random IOPS than rep3-virt
- **rep3-enc negligible encryption overhead** — encrypted SC within 3% of unencrypted rep3 across all workloads
- **cephfs-rep2 outperforms cephfs-rep3** — 32% more random IOPS and 12% more sequential throughput from 2-replica vs 3-replica data pool
- **ODF block storage dominates throughput** — RBD pools deliver 5,400-8,300 MiB/s sequential, 14-130x faster than IBM Cloud File CSI
- **Pool CSI near block-storage IOPS** — bench-pool delivers 53k random IOPS, comparable to RBD pools and 9x faster than ibmc-vpc-file-3000-iops
- **IBM Cloud File CSI is IOPS-bound** — performance scales linearly with provisioned IOPS tier (500/1000/3000)

See the [interactive ranking report](docs/examples/ranking-report-example.html) for detailed charts and composite scores, the [ROKS vs VCF comparison](docs/examples/roks-vs-vcf-comparison.html) for cross-platform analysis, or the [MZ vs SZ comparison](docs/examples/mz-vs-sz-comparison.html) for multi-zone vs single-zone ODF performance impact.

## Documentation

Comprehensive documentation is available in the [`docs/`](docs/index.md) folder, covering foundational concepts, practical guides, and architecture deep-dives.

| Section | Description |
|---------|-------------|
| [Concepts](docs/index.md#concepts) | Kubernetes, OpenShift, Ceph/ODF, erasure coding, KubeVirt, fio |
| [Guides](docs/index.md#guides) | Prerequisites, configuration, running tests, interpreting results |
| [Architecture](docs/index.md#architecture) | Script pipeline, test matrix, fio profiles, template rendering |
| [Glossary](docs/glossary.md) | Quick-reference for all technical terms |
| [Troubleshooting](docs/guides/troubleshooting.md) | Common failures and fixes |

New to this stack? Start with the [suggested reading path](docs/index.md#suggested-reading-path).

## Prerequisites

- IBM Cloud ROKS cluster (bare metal with NVMe, or VSI with IBM Cloud Block-backed ODF)
- OpenShift Virtualization (KubeVirt) installed and configured
- ODF (OpenShift Data Foundation) installed with Ceph healthy
- `oc` CLI authenticated to the cluster
- `virtctl` CLI installed (for VM SSH access)
- `jq` installed locally
- Python 3 with `openpyxl` (for XLSX report generation)

## Storage Pools Tested

### ODF (Ceph) Pools
| Pool | Type | Description |
|------|------|-------------|
| rep3 | Replicated (size=3) | Default ROKS OOB pool |
| rep3-virt | Replicated (size=3) | ODF virtualization-optimized SC |
| rep3-enc | Replicated (size=3) | ODF encrypted SC (Key Protect) |
| rep2 | Replicated (size=2) | Reduced replication |
| ec-2-1 | Erasure Coded (2+1) | Space-efficient, lower redundancy (needs 3 hosts) |
| ec-3-1 | Erasure Coded (3+1) | vSAN RAID-5 equivalent, best capacity efficiency (needs 4 hosts) |
| ec-2-2 | Erasure Coded (2+2) | Dual-parity EC (needs 4 hosts) |
| ec-4-2 | Erasure Coded (4+2) | Production-grade EC (needs 6 hosts) |

### ODF CephFS Pools
| Pool | Type | Description |
|------|------|-------------|
| cephfs-rep3 | CephFS (data replica=3) | Default ROKS OOB CephFS pool |
| cephfs-rep2 | CephFS (data replica=2) | Reduced replication CephFS |

### IBM Cloud File CSI (dp2 profile)
Auto-discovered at runtime. `-metro-`, `-retain-`, `-regional*`, and `-min-iops*` variants are filtered by default.

| StorageClass | Fixed IOPS | Min PVC Size |
|--------------|-----------|-------------|
| `ibmc-vpc-file-500-iops` | 500 | 10Gi |
| `ibmc-vpc-file-1000-iops` | 1000 | 40Gi |
| `ibmc-vpc-file-3000-iops` | 3000 | 120Gi |

### IBM Cloud Pool CSI (FileSharePool)
Auto-detected when the `filesharepools.storage.ibmcloud.io` CRD is present. Creates a pre-provisioned NFS file share pool for faster PVC binding. Configurable in `00-config.sh` (`POOL_CSI_*` vars, default: 4000Gi at 40,000 IOPS, dp2 profile).

### IBM Cloud Block CSI (VSI clusters only)
Auto-discovered at runtime. See [VSI Storage Testing Guide](docs/guides/vsi-storage-testing-guide.md).

## Test Matrix

| Dimension | Values |
|-----------|--------|
| VM Sizes | Small (2vCPU/4Gi), Medium (4vCPU/8Gi), Large (8vCPU/16Gi) |
| PVC Sizes | 150Gi, 500Gi, 1000Gi |
| Concurrency | 1, 5, 10 VMs |
| fio Profiles | sequential-rw, random-rw, mixed-70-30, db-oltp, app-server, data-pipeline |
| Block Sizes | 4k, 64k, 1M |

## Quick Start

```bash
# 1. Review and adjust configuration
vi 00-config.sh

# 2. Set up ODF storage pools
./01-setup-storage-pools.sh

# 3. Discover IBM Cloud File StorageClasses
./02-setup-file-storage.sh

# 3b. Discover IBM Cloud Block StorageClasses (VSI clusters)
./03-setup-block-storage.sh

# 4. Run the full test suite (this takes a long time!)
./04-run-tests.sh

# Or run a quick smoke test first:
./04-run-tests.sh --quick

# Or test a single pool:
./04-run-tests.sh --pool rep3

# 5. Aggregate results
./05-collect-results.sh

# 6. Generate reports
./06-generate-report.sh

# 7. Clean up (VMs and PVCs only by default)
./07-cleanup.sh

# Full cleanup including storage pools:
./07-cleanup.sh --all

# Preview cleanup without executing:
./07-cleanup.sh --all --dry-run
```

## File Structure

```
.
├── 00-config.sh                # Central configuration (all tunables)
├── 01-setup-storage-pools.sh   # Create CephBlockPools + StorageClasses
├── 02-setup-file-storage.sh    # Discover IBM Cloud File StorageClasses
├── 03-setup-block-storage.sh   # Discover IBM Cloud Block CSI StorageClasses
├── 04-run-tests.sh             # Main test orchestrator
├── 05-collect-results.sh       # Aggregate fio JSON → CSV
├── 06-generate-report.sh       # Generate HTML/Markdown/XLSX reports
├── 07-cleanup.sh               # Tear down VMs, PVCs, pools
├── cloud-init/
│   └── fio-runner.yaml         # Cloud-init template (installs fio, runs tests)
├── vm-templates/
│   └── vm-template.yaml        # OpenShift Virt VM manifest template
├── fio-profiles/
│   ├── sequential-rw.fio       # Sequential read/write (throughput)
│   ├── random-rw.fio           # Random read/write (IOPS)
│   ├── mixed-70-30.fio         # Mixed 70/30 read/write
│   ├── db-oltp.fio             # Database OLTP simulation
│   ├── app-server.fio          # Application server simulation
│   └── data-pipeline.fio       # Data/AI pipeline simulation
├── lib/
│   ├── vm-helpers.sh           # VM lifecycle, cloud-init rendering
│   ├── wait-helpers.sh         # Polling and wait utilities
│   └── report-helpers.sh       # CSV/Markdown/HTML generation
└── README.md
```

## Output Reports

After running the suite, reports are generated in the `reports/` directory:

- **HTML Dashboard** — Interactive charts (Chart.js) with filters for pool, VM size, PVC size, profile, and block size
- **Markdown Summary** — Text-based report with key metrics tables
- **XLSX Workbook** — Excel file with Summary sheet (charts), Raw Data sheet, and Test Config sheet
- **CSV Files** — Raw data and per-pool summary for custom analysis

## Customization

Edit `00-config.sh` to adjust:
- `FIO_RUNTIME` — Duration of each fio test (default: 120s)
- `FIO_IODEPTH` — I/O queue depth (default: 32)
- `FIO_NUMJOBS` — Parallel fio workers (default: 4)
- `FIO_TEST_FILE_SIZE` — Size of test file per job (default: 4G)
- `VM_SIZES` — Add/remove VM size configurations
- `ODF_POOLS` — Add/remove storage pool configurations
- `CONCURRENCY_LEVELS` — Adjust VM count for contention tests

## Estimated Runtime

The full matrix generates approximately 3,888 test permutations (7 ODF pools + ~5 File CSI profiles × 3 VM sizes × 3 PVC sizes × 3 concurrency levels × 6 fio profiles × 3 block sizes). EC pools requiring more hosts than available are automatically skipped. VMs are created once per (pool × vm_size × pvc_size × concurrency) group and reused across fio profile and block size permutations via SSH job replacement, significantly reducing VM lifecycle overhead.

Rough estimate: **24–48 hours** for the full matrix. Use `--quick` mode for initial validation (~2–4 hours).
