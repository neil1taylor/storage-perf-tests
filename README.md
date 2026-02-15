# VM Storage Performance Test Suite

Performance benchmarking for VMs on IBM Cloud ROKS with OpenShift Virtualization, testing ODF (Ceph) storage pools, IBM Cloud File CSI, and IBM Cloud Block CSI.

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
| ec-2-2 | Erasure Coded (2+2) | Balanced EC (needs 4 hosts) |
| ec-4-2 | Erasure Coded (4+2) | Production-grade EC (needs 6 hosts) |

### IBM Cloud File CSI (dp2 profile)
Auto-discovered at runtime. `-metro-`, `-retain-`, and `-regional*` variants are filtered by default.

| StorageClass | Fixed IOPS | Min PVC Size |
|--------------|-----------|-------------|
| `ibmc-vpc-file-min-iops` | auto | 10Gi |
| `ibmc-vpc-file-500-iops` | 500 | 10Gi |
| `ibmc-vpc-file-eit` | 1000 | 40Gi |
| `ibmc-vpc-file-1000-iops` | 1000 | 40Gi |
| `ibmc-vpc-file-3000-iops` | 3000 | 120Gi |

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
