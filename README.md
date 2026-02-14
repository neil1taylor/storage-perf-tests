# VM Storage Performance Test Suite

Performance benchmarking for VMs on IBM Cloud ROKS with OpenShift Virtualization, testing ODF (Ceph) storage pools and IBM Cloud File CSI.

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

- IBM Cloud ROKS cluster with bare metal workers (bx3d with NVMe)
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
| rep2 | Replicated (size=2) | Reduced replication |
| ec-2-1 | Erasure Coded (2+1) | Space-efficient, lower redundancy |
| ec-2-2 | Erasure Coded (2+2) | Balanced EC |
| ec-4-2 | Erasure Coded (4+2) | Production-grade EC |

### IBM Cloud File CSI
All available `vpc-file` StorageClass profiles are auto-discovered at runtime.

## Test Matrix

| Dimension | Values |
|-----------|--------|
| VM Sizes | Small (2vCPU/4Gi), Medium (4vCPU/8Gi), Large (8vCPU/16Gi) |
| PVC Sizes | 10Gi, 50Gi, 100Gi |
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

# 4. Run the full test suite (this takes a long time!)
./06-run-tests.sh

# Or run a quick smoke test first:
./06-run-tests.sh --quick

# Or test a single pool:
./06-run-tests.sh --pool rep3

# 5. Aggregate results
./07-collect-results.sh

# 6. Generate reports
./08-generate-report.sh

# 7. Clean up (VMs and PVCs only by default)
./09-cleanup.sh

# Full cleanup including storage pools:
./09-cleanup.sh --all

# Preview cleanup without executing:
./09-cleanup.sh --all --dry-run
```

## File Structure

```
.
├── 00-config.sh                # Central configuration (all tunables)
├── 01-setup-storage-pools.sh   # Create CephBlockPools + StorageClasses
├── 02-setup-file-storage.sh    # Discover IBM Cloud File StorageClasses
├── 03-cloud-init/
│   └── fio-runner.yaml         # Cloud-init template (installs fio, runs tests)
├── 04-vm-templates/
│   └── vm-template.yaml        # OpenShift Virt VM manifest template
├── 05-fio-profiles/
│   ├── sequential-rw.fio       # Sequential read/write (throughput)
│   ├── random-rw.fio           # Random read/write (IOPS)
│   ├── mixed-70-30.fio         # Mixed 70/30 read/write
│   ├── db-oltp.fio             # Database OLTP simulation
│   ├── app-server.fio          # Application server simulation
│   └── data-pipeline.fio       # Data/AI pipeline simulation
├── 06-run-tests.sh             # Main test orchestrator
├── 07-collect-results.sh       # Aggregate fio JSON → CSV
├── 08-generate-report.sh       # Generate HTML/Markdown/XLSX reports
├── 09-cleanup.sh               # Tear down VMs, PVCs, pools
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

The full matrix generates approximately 810 test permutations (5 ODF pools + ~5 File CSI profiles × 3 VM sizes × 3 PVC sizes × 3 concurrency levels × 6 fio profiles × 3 block sizes). VMs are created once per (pool × vm_size × pvc_size × concurrency) group and reused across fio profile and block size permutations via SSH job replacement, significantly reducing VM lifecycle overhead.

Rough estimate: **12–24 hours** for the full matrix. Use `--quick` mode for initial validation (~1–2 hours).
