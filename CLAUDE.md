# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VM storage performance benchmarking suite for IBM Cloud ROKS with OpenShift Virtualization. Tests ODF (Ceph) storage pools (RBD replicated, RBD erasure-coded, and CephFS), IBM Cloud File CSI, IBM Cloud Block CSI, and IBM Cloud Pool CSI (FileSharePool) against a matrix of VM sizes, PVC sizes, concurrency levels, fio profiles, and block sizes. Supports both bare metal (NVMe-backed ODF) and VSI (IBM Cloud Block-backed ODF) cluster topologies with auto-detection.

## Prerequisites

- `oc` CLI authenticated to an IBM Cloud ROKS cluster (bare metal with NVMe or VSI with IBM Cloud Block)
- OpenShift Virtualization (KubeVirt) and ODF (OpenShift Data Foundation) installed
- `virtctl` CLI for VM SSH access
- `jq` installed locally
- Python 3 with `openpyxl` (optional — for XLSX reports; HTML/Markdown/CSV generated without it)

## Key Commands

```bash
# Full pipeline (single command):
./run-all.sh                       # Full pipeline: setup → test → collect → report
./run-all.sh --quick               # Quick smoke test pipeline
./run-all.sh --quick --skip-setup  # Re-run tests (pools already exist)
./run-all.sh --quick --cleanup     # Quick test + clean up VMs/PVCs
./run-all.sh --overview --cleanup-all  # Overview + full cleanup
./run-all.sh --rank --skip-setup       # Rank StorageClasses (~1-1.5h)
./run-all.sh --quick --notify https://hooks.slack.com/...  # Notify on completion

# Individual steps (sequential):
./01-setup-storage-pools.sh        # Create CephBlockPools, CephFilesystems + StorageClasses
./02-setup-file-storage.sh         # Discover IBM Cloud File CSI StorageClasses
./03-setup-block-storage.sh        # Discover IBM Cloud Block CSI StorageClasses (VSI clusters)
./04-run-tests.sh                  # Run full test matrix (12-24 hours)
./04-run-tests.sh --quick          # Smoke test (~1-2 hours)
./04-run-tests.sh --overview       # All-pool comparison (~2 hours)
./04-run-tests.sh --rank           # Rank all pools (3 tests/pool, ~1-1.5h)
./04-run-tests.sh --pool rep3      # Test single pool
./04-run-tests.sh --parallel       # Run pools in parallel (auto-scaled)
./04-run-tests.sh --parallel 3     # Run N pools in parallel
./04-run-tests.sh --dry-run        # Preview test matrix without running
./04-run-tests.sh --resume <id>    # Resume an interrupted run
./04-run-tests.sh --filter "rep2:*:*:*:random-rw:4k"  # Test selection
./04-run-tests.sh --exclude "ec-*:*:*:*:*:*"          # Skip matching tests
./05-collect-results.sh            # Aggregate fio JSON → CSV
./06-generate-report.sh            # Generate HTML/Markdown/XLSX reports
./06-generate-report.sh --compare <id1> <id2>  # Compare two runs
./06-generate-report.sh --rank                 # Generate ranking report from last run
./07-cleanup.sh                    # Remove VMs and PVCs only
./07-cleanup.sh --all              # Full cleanup including pools/namespace
./07-cleanup.sh --all --dry-run    # Preview cleanup
```

## Architecture

### Execution Pipeline

Scripts are numbered `00-07` and run sequentially. Each script sources `00-config.sh` for shared configuration and sources helpers from `lib/`.

### Config-Driven Design

`00-config.sh` is the single source of truth for all tunables: VM sizes, PVC sizes, ODF pool definitions (RBD replicated, RBD erasure-coded, CephFS), Pool CSI settings (`POOL_CSI_NAME`, `POOL_CSI_PROFILE`, `POOL_CSI_IOPS`, etc.), fio settings, timeouts, and file paths. ODF_POOLS entries use the format `name:type:params` where type is `replicated` (RBD), `erasurecoded` (RBD EC), or `cephfs` (CephFilesystem with `name:cephfs:data_replica_count`, metadata pool is always size=3). It validates cluster connectivity on load (`oc cluster-info`) and fails with a clear error if the CLI is not authenticated. It also auto-detects the cluster type (BM vs VSI) from worker node labels and exports `CLUSTER_TYPE`, `WORKER_FLAVOR`, `WORKER_COUNT`, and `CLUSTER_DESCRIPTION`. All values are exported as environment variables or bash arrays. Other scripts consume these via `source 00-config.sh`.

### Template Rendering

VM creation uses string substitution (`__PLACEHOLDER__` patterns) rather than Helm/Kustomize:
- `vm-templates/vm-template.yaml` — KubeVirt VM manifest with DataVolume for root disk + PVC for data disk
- `cloud-init/fio-runner.yaml` — cloud-init that installs fio, writes a systemd oneshot service, and runs the benchmark on boot
- `fio-profiles/*.fio` — fio job files using `${VARIABLE}` placeholders (rendered by `render_fio_profile()` in `lib/vm-helpers.sh`)

The rendering chain for the first permutation is: fio profile → cloud-init template → VM template → `oc apply`. For subsequent permutations reusing the same VMs: fio profile → `replace_fio_job()` via SSH → `restart_fio_service()`.

### Test Orchestration (`04-run-tests.sh`)

VMs are created once per outer-loop group (`pool × vm_size × pvc_size × concurrency`) and reused across all `fio_profile × block_size` permutations via SSH fio job replacement. For each group:
1. Builds an ordered list of (profile, block_size) permutations
2. First permutation: renders fio profile → cloud-init → creates N VMs → waits for Running → waits for fio complete → collects results
3. Subsequent permutations: renders fio profile → replaces job file in each VM via SSH (`replace_fio_job`) → restarts the benchmark service (`restart_fio_service`) → waits for fio complete → collects results
4. Deletes VMs after all permutations in the group are done

VM names do not include profile/blocksize (since they're reused): `perf-<pool>-<size>-<pvc>-c<conc>-<i>`. Results are stored hierarchically: `results/<pool>/<vmsize>/<pvcsize>/<concurrency>/<profile>/<blocksize>/<vm>-fio.json`

### Resume / Checkpoint (`--resume`)

After each successful test, the key `pool:size:pvc:conc:profile:bs` is appended to `results/<run-id>.checkpoint`. The `--resume <run-id>` flag loads this file and skips completed tests:

- **Entire VM groups** are skipped when all permutations in the group are already checkpointed (no VMs created).
- **Individual subsequent permutations** within a partially-complete group are skipped (VM is still created for the remaining tests).
- The resumed run reuses the original `RUN_ID`, so results accumulate in the same directory.

```bash
./04-run-tests.sh --quick                       # Starts run perf-20260215-120000
# ... interrupted with Ctrl+C ...
./04-run-tests.sh --quick --resume perf-20260215-120000  # Resumes from checkpoint
```

### Dry-Run / Preview (`--dry-run`)

Prints the full test matrix dimensions, resource requirements, and estimated runtime without creating any K8s resources:

```bash
./04-run-tests.sh --dry-run
./04-run-tests.sh --quick --dry-run
./04-run-tests.sh --filter "rep3:*:*:*:*:*" --dry-run
```

Output includes: total permutations, VM group count, max concurrent VMs, max PVC storage per group, and estimated wall-clock time (based on `FIO_RUNTIME + FIO_RAMP_TIME + ~60s` overhead per test).

### Test Filtering (`--filter`, `--exclude`)

Filters use a 6-field colon-separated pattern: `pool:vm_size:pvc_size:concurrency:fio_profile:block_size`. Use `*` as a wildcard for any field.

```bash
# Only random-rw 4k tests on rep2
./04-run-tests.sh --filter "rep2:*:*:*:random-rw:4k"

# All tests except erasure-coded pools
./04-run-tests.sh --exclude "ec-*:*:*:*:*:*"

# Combine with dry-run to preview
./04-run-tests.sh --filter "*:small:150Gi:1:*:*" --dry-run
```

Filters apply at two levels: entire VM groups are skipped when all their permutations are filtered out, and individual permutations within a group are skipped when they don't match. `--filter` and `--exclude` can be combined (both must pass for a test to run).

### Comparative Reporting (`--compare`)

Generates an interactive HTML comparison dashboard from two completed runs:

```bash
./06-generate-report.sh --compare perf-20260210-100000 perf-20260215-120000
```

The comparison joins both CSV result sets on `(pool, vm_size, pvc_size, concurrency, profile, block_size)`, calculates percentage deltas for all metrics (IOPS, bandwidth, latency, p99), and generates `reports/compare-<id1>-vs-<id2>.html` with:
- Summary counts of improvements, regressions, and unchanged metrics
- Color-coded delta columns (green = improved, red = regressed)
- Interactive filters by pool, VM size, PVC size, profile, and block size

### StorageClass Ranking (`--rank`)

A purpose-built fast mode for ranking StorageClasses by performance. Runs 3 tests per pool with a dedicated ranking HTML report:

| Test | Profile | Block Size |
|------|---------|------------|
| Random I/O | random-rw | 4k |
| Sequential throughput | sequential-rw | 1M |
| Mixed workload | mixed-70-30 | 4k |

Settings: small VM (2 vCPU, 4Gi), 150Gi PVC, concurrency=1, 60s runtime. ~8.5 min/pool, ~1h for BM (9 pools), ~1.5h for VSI (14 pools).

The ranking report (`reports/ranking-{RUN_ID}.html`) includes:
- **Composite score** with weighted normalization (best=100): random IOPS 40%, sequential BW 30%, mixed IOPS 20%, p99 latency 10%
- Per-workload ranking tables with horizontal bar charts
- Latency ranking table (from random-rw/4k results)
- Gold/silver/bronze highlighting for top 3

`--rank` is mutually exclusive with `--quick` and `--overview`. The report is generated by `generate_ranking_html_report()` in `lib/report-helpers.sh` using embedded Python (same pattern as `generate_comparison_report()`).

### Completion Notification (`--notify`)

Posts a Slack-compatible JSON webhook on pipeline completion:

```bash
./run-all.sh --quick --notify https://hooks.slack.com/services/T.../B.../xxx
```

The payload includes run ID, status, duration, and cluster description. Compatible with any webhook that accepts Slack block format.

### Shared Libraries (`lib/`)

- `vm-helpers.sh` — Logging functions (`log_info`, `log_warn`, etc.), SSH key management, StorageClass resolution, template rendering (`render_cloud_init`, `render_fio_profile`), VM CRUD (`create_test_vm`, `delete_test_vm`, `collect_vm_results`), VM reuse helpers (`replace_fio_job`, `restart_fio_service`), VM wait with DataVolume clone monitoring (`wait_for_vm_running`). All `virtctl ssh` calls are wrapped with `timeout 30` (or `timeout 60` for data transfers like result collection) to prevent indefinite hangs on unresponsive VMs. Secret creation failure during `create_test_vm` is caught immediately with `return 1` rather than falling through to a long boot timeout.
- `wait-helpers.sh` — Polling loops with timeouts: `wait_for_all_vms_running`, `wait_for_all_fio_complete` (handles `active`/`failed` states for oneshot services with `RemainAfterExit=yes`), `wait_for_pvc_bound`, `retry_with_backoff`. SSH polling calls use `timeout 30` to prevent hangs.
- `report-helpers.sh` — fio JSON parsing with `jq`, CSV aggregation, Markdown report generation, HTML dashboard with Chart.js, and StorageClass ranking report (`generate_ranking_html_report()`). Validates fio JSON structure before parsing (checks `.jobs | length > 0` and presence of `read`/`write` fields). Uses process substitution (`< <(find ...)`) instead of pipe to avoid subshell variable scoping issues.

### Storage Pool Naming

ODF pools use a `perf-test-` prefix for CephBlockPools/CephFilesystems and `perf-test-sc-` for StorageClasses. The default rep3 pool reuses the existing ROKS out-of-box SC (`ocs-storagecluster-ceph-rbd`). The default CephFS pool (`cephfs-rep3`) reuses the OOB SC (`ocs-storagecluster-cephfs`). Custom CephFS pools (e.g. `cephfs-rep2`) create a `CephFilesystem` CRD named `perf-test-cephfs-rep2` with a CephFS-specific StorageClass using the `cephfs.csi.ceph.com` provisioner. IBM Cloud File and Block CSI SCs are used by their cluster names directly. Pool CSI creates a `FileSharePool` CRD named `$POOL_CSI_NAME` (default `bench-pool`); the driver auto-creates a StorageClass with the same name, which is appended to `file-storage-classes.txt`.

### Resource Labeling

All test resources are labeled `app=vm-perf-test` with additional labels for `run-id`, `storage-pool`, `vm-size`, and `pvc-size`. Cleanup scripts use these labels for safe targeted deletion.

## Cluster Topology Assumptions

This suite supports both **bare metal (BM)** and **VSI** single-zone ROKS clusters. Cluster type is auto-detected from worker node instance-type labels (`detect_cluster_type()` in `00-config.sh`), or can be overridden via `CLUSTER_TYPE=bm|vsi`.

- **BM clusters:** NVMe-backed ODF, no IBM Cloud Block CSI available. `03-setup-block-storage.sh` exits cleanly.
- **VSI clusters:** IBM Cloud Block-backed ODF, plus IBM Cloud Block CSI available for direct testing. All three backends (ODF, File CSI, Block CSI) are tested.
- **EC pool constraints:** EC pools require k+m unique hosts (using `failureDomain: host`). With 3 workers, only pools needing ≤3 failure domains work (rep2, rep3, ec-2-1). Pools requiring more hosts (ec-3-1 and ec-2-2 need 4, ec-4-2 needs 6) are defined in `00-config.sh` for portability across cluster sizes but are automatically skipped when the cluster has insufficient hosts. Topology skips are logged as warnings and do not count as failures.
- **EC StorageClass setup:** RBD cannot store image metadata directly on an erasure-coded pool. EC StorageClasses use `pool` (replicated, for metadata) + `dataPool` (EC, for data blocks). `01-setup-storage-pools.sh` automatically sets `pool: ocs-storagecluster-cephblockpool` and `dataPool: perf-test-<ec-pool>` for EC pools.
- **VM-optimized StorageClass features:** All custom StorageClasses (rep2, ec-2-1, ec-3-1, ec-2-2, ec-4-2) use the same VM-optimized RBD image features as the ODF out-of-box virtualization SC: `imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff` and `mapOptions: krbd:rxbounce`. The critical features are `exclusive-lock` (enables write-back caching and single-writer optimizations — major write performance impact), `object-map` + `fast-diff` (speeds up sparse image and DataVolume clone operations), and `rxbounce` (correctness fix for guest OS CRC errors with kernel-space RBD). Without these, custom pools can show up to 7x worse write IOPS than `rep3-virt` even when backed by the same Ceph pool. StorageClass parameters are immutable — changing these requires deleting and recreating the SC.
- **File/Block CSI deduplication:** Auto-discovery finds many StorageClasses, but `-metro-`, `-retain-`, and `-regional*` variants are filtered out by default. Metro/retain produce identical I/O performance on a single-zone cluster; regional SCs use the `rfs` profile which requires IBM support allowlisting. `FILE_CSI_DEDUP=true` and `BLOCK_CSI_DEDUP=true` (both default) enable this filtering. Set to `false` for multi-zone clusters where metro topology may affect latency, or if `rfs` has been allowlisted.
- **PVC size minimums:** IBM Cloud File dp2 profile enforces a max ~25 IOPS/GB ratio. The 3000-IOPS SC requires ≥120Gi to provision, so the minimum PVC size in the test matrix is 150Gi.
- **Rep2 vs Rep3 on 3-node clusters:** On a 3-worker cluster, rep3 reads can outperform rep2 reads because (a) rep3 uses the pre-tuned OOB pool while rep2 uses a freshly created pool with potentially unconverged PG autoscaler, and (b) rep3 on exactly 3 nodes gives perfectly balanced PG distribution (every OSD holds all PGs) while rep2 creates uneven primary OSD pairing. Rep2 should outperform rep3 for writes (2 replica acks vs 3). The `01-setup-storage-pools.sh` script waits for PG autoscaler convergence to minimize the first factor.
- **CephFS pools:** CephFS provides POSIX-compatible shared filesystem storage backed by Ceph. `cephfs-rep3` uses the OOB `ocs-storagecluster-cephfs` SC; `cephfs-rep2` creates a custom `CephFilesystem` CRD with a 2-replica data pool (metadata pool is always 3-replica for safety). CephFS PVCs use `volumeMode: Filesystem`; in KubeVirt this means file-on-filesystem indirection (KubeVirt creates a `disk.img` on the CephFS mount), so CephFS performance is expected to be lower than RBD due to MDS overhead and the extra indirection layer. Custom CephFilesystem creation requires MDS pod initialization (up to `MDS_READY_TIMEOUT=300s`). Some ODF versions limit to one CephFilesystem per cluster — if `cephfs-rep2` creation fails, it's caught and logged; `cephfs-rep3` OOB still works. CephFS StorageClasses use different secrets (`rook-csi-cephfs-provisioner`/`rook-csi-cephfs-node`) and do not use RBD-specific parameters (`imageFeatures`, `mapOptions`).
- **Pool CSI (FileSharePool):** The IBM Cloud Pool CSI driver provides a `FileSharePool` CRD (`storage.ibmcloud.io/v1alpha1`) that pre-provisions a pool of NFS file shares for faster PVC binding. When the CRD `filesharepools.storage.ibmcloud.io` exists on the cluster, `02-setup-file-storage.sh` auto-detects it, creates a `FileSharePool` resource using config from `00-config.sh` (`POOL_CSI_*` vars), and waits for the driver to auto-create the StorageClass. Region/zone are detected from worker node topology labels; the resource group is resolved from cluster ConfigMaps/Secrets (with `POOL_RESOURCE_GROUP` env var fallback). If the Pool CSI driver is not installed, setup is silently skipped. Cleanup (`07-cleanup.sh --all`) deletes the `FileSharePool` CRD instance and any residual StorageClass.
- **PG autoscaler and `targetSizeRatio`:** Custom pools now set `targetSizeRatio: 0.1` (replicated) or `parameters.target_size_ratio: "0.1"` (EC) to ensure the PG autoscaler allocates a proper PG count. Without this, a newly created empty pool gets 1 PG, funneling all I/O through a single OSD primary (~6x bottleneck vs the OOB pool's 256 PGs). The OOB pool's `targetSizeRatio: 0.49` is too aggressive for multiple custom pools, so 0.1 is used (sum of all pools stays ≤1.0). Custom pools also now set `deviceClass: ssd`, `enableCrushUpdates: true`, and `enableRBDStats: true` to match OOB pool settings.

## Conventions

- All scripts use `set -euo pipefail` and resolve `SCRIPT_DIR` relative to themselves
- K8s resource names are truncated to 63 characters and sanitized to lowercase alphanumeric + hyphens (pure bash: `${var,,}`, `${var//[^a-z0-9-]/-}`, `${var:0:63}`, `${var%-}`)
- fio runs with `direct=1` (O_DIRECT) to bypass OS page cache
- Cleanup defaults to VMs/PVCs only; pool deletion requires explicit `--pools` or `--all` flag
- VM SSH access uses ed25519 keys auto-generated to `./ssh-keys/perf-test-key`
- All `virtctl ssh` calls are wrapped with `timeout` (30s for commands, 60s for data transfers) to prevent indefinite hangs
- Checkpoint files (`results/<run-id>.checkpoint`) are append-only text files with one `pool:size:pvc:conc:profile:bs` key per line
- XLSX report generation gracefully degrades: if `openpyxl` is not installed, the report is skipped with a warning (HTML/Markdown/CSV are always generated)
- Signal handler uses tracked PID arrays for reliable cleanup; second Ctrl+C exits immediately
