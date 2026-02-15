# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VM storage performance benchmarking suite for IBM Cloud ROKS with OpenShift Virtualization. Tests ODF (Ceph) storage pools (replicated and erasure-coded), IBM Cloud File CSI, and IBM Cloud Block CSI against a matrix of VM sizes, PVC sizes, concurrency levels, fio profiles, and block sizes. Supports both bare metal (NVMe-backed ODF) and VSI (IBM Cloud Block-backed ODF) cluster topologies with auto-detection.

## Prerequisites

- `oc` CLI authenticated to an IBM Cloud ROKS cluster (bare metal with NVMe or VSI with IBM Cloud Block)
- OpenShift Virtualization (KubeVirt) and ODF (OpenShift Data Foundation) installed
- `virtctl` CLI for VM SSH access
- `jq` installed locally
- Python 3 with `openpyxl` (for XLSX reports)

## Key Commands

```bash
# Full pipeline (single command):
./run-all.sh                       # Full pipeline: setup → test → collect → report
./run-all.sh --quick               # Quick smoke test pipeline
./run-all.sh --quick --skip-setup  # Re-run tests (pools already exist)
./run-all.sh --quick --cleanup     # Quick test + clean up VMs/PVCs
./run-all.sh --overview --cleanup-all  # Overview + full cleanup

# Individual steps (sequential):
./01-setup-storage-pools.sh        # Create CephBlockPools + StorageClasses
./02-setup-file-storage.sh         # Discover IBM Cloud File CSI StorageClasses
./03-setup-block-storage.sh        # Discover IBM Cloud Block CSI StorageClasses (VSI clusters)
./04-run-tests.sh                  # Run full test matrix (12-24 hours)
./04-run-tests.sh --quick          # Smoke test (~1-2 hours)
./04-run-tests.sh --overview       # All-pool comparison (~2 hours)
./04-run-tests.sh --pool rep3      # Test single pool
./04-run-tests.sh --parallel       # Run pools in parallel (auto-scaled)
./04-run-tests.sh --parallel 3     # Run N pools in parallel
./05-collect-results.sh            # Aggregate fio JSON → CSV
./06-generate-report.sh            # Generate HTML/Markdown/XLSX reports
./07-cleanup.sh                    # Remove VMs and PVCs only
./07-cleanup.sh --all              # Full cleanup including pools/namespace
./07-cleanup.sh --all --dry-run    # Preview cleanup
```

## Architecture

### Execution Pipeline

Scripts are numbered `00-07` and run sequentially. Each script sources `00-config.sh` for shared configuration and sources helpers from `lib/`.

### Config-Driven Design

`00-config.sh` is the single source of truth for all tunables: VM sizes, PVC sizes, ODF pool definitions, fio settings, timeouts, and file paths. It also auto-detects the cluster type (BM vs VSI) from worker node labels and exports `CLUSTER_TYPE`, `WORKER_FLAVOR`, `WORKER_COUNT`, and `CLUSTER_DESCRIPTION`. All values are exported as environment variables or bash arrays. Other scripts consume these via `source 00-config.sh`.

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

### Shared Libraries (`lib/`)

- `vm-helpers.sh` — Logging functions (`log_info`, `log_warn`, etc.), SSH key management, StorageClass resolution, template rendering (`render_cloud_init`, `render_fio_profile`), VM CRUD (`create_test_vm`, `delete_test_vm`, `collect_vm_results`), VM reuse helpers (`replace_fio_job`, `restart_fio_service`), VM wait with DataVolume clone monitoring (`wait_for_vm_running`)
- `wait-helpers.sh` — Polling loops with timeouts: `wait_for_all_vms_running`, `wait_for_all_fio_complete` (handles `active`/`failed` states for oneshot services with `RemainAfterExit=yes`), `wait_for_pvc_bound`, `retry_with_backoff`
- `report-helpers.sh` — fio JSON parsing with `jq`, CSV aggregation, Markdown report generation, HTML dashboard with Chart.js

### Storage Pool Naming

ODF pools use a `perf-test-` prefix for CephBlockPools and `perf-test-sc-` for StorageClasses. The default rep3 pool reuses the existing ROKS out-of-box SC (`ocs-storagecluster-ceph-rbd`). IBM Cloud File and Block CSI SCs are used by their cluster names directly.

### Resource Labeling

All test resources are labeled `app=vm-perf-test` with additional labels for `run-id`, `storage-pool`, `vm-size`, and `pvc-size`. Cleanup scripts use these labels for safe targeted deletion.

## Cluster Topology Assumptions

This suite supports both **bare metal (BM)** and **VSI** single-zone ROKS clusters. Cluster type is auto-detected from worker node instance-type labels (`detect_cluster_type()` in `00-config.sh`), or can be overridden via `CLUSTER_TYPE=bm|vsi`.

- **BM clusters:** NVMe-backed ODF, no IBM Cloud Block CSI available. `03-setup-block-storage.sh` exits cleanly.
- **VSI clusters:** IBM Cloud Block-backed ODF, plus IBM Cloud Block CSI available for direct testing. All three backends (ODF, File CSI, Block CSI) are tested.
- **EC pool constraints:** EC pools require k+m unique hosts (using `failureDomain: host`). With 3 workers, only pools needing ≤3 failure domains work (rep2, rep3, ec-2-1). Pools requiring more hosts (ec-2-2 needs 4, ec-4-2 needs 6) are defined in `00-config.sh` for portability across cluster sizes but are automatically skipped when the cluster has insufficient hosts. Topology skips are logged as warnings and do not count as failures.
- **EC StorageClass setup:** RBD cannot store image metadata directly on an erasure-coded pool. EC StorageClasses use `pool` (replicated, for metadata) + `dataPool` (EC, for data blocks). `01-setup-storage-pools.sh` automatically sets `pool: ocs-storagecluster-cephblockpool` and `dataPool: perf-test-<ec-pool>` for EC pools.
- **File/Block CSI deduplication:** Auto-discovery finds many StorageClasses, but `-metro-`, `-retain-`, and `-regional*` variants are filtered out by default. Metro/retain produce identical I/O performance on a single-zone cluster; regional SCs use the `rfs` profile which requires IBM support allowlisting. `FILE_CSI_DEDUP=true` and `BLOCK_CSI_DEDUP=true` (both default) enable this filtering. Set to `false` for multi-zone clusters where metro topology may affect latency, or if `rfs` has been allowlisted.
- **PVC size minimums:** IBM Cloud File dp2 profile enforces a max ~25 IOPS/GB ratio. The 3000-IOPS SC requires ≥120Gi to provision, so the minimum PVC size in the test matrix is 150Gi.
- **Rep2 vs Rep3 on 3-node clusters:** On a 3-worker cluster, rep3 reads can outperform rep2 reads because (a) rep3 uses the pre-tuned OOB pool while rep2 uses a freshly created pool with potentially unconverged PG autoscaler, and (b) rep3 on exactly 3 nodes gives perfectly balanced PG distribution (every OSD holds all PGs) while rep2 creates uneven primary OSD pairing. Rep2 should outperform rep3 for writes (2 replica acks vs 3). The `01-setup-storage-pools.sh` script waits for PG autoscaler convergence to minimize the first factor.

## Conventions

- All scripts use `set -euo pipefail` and resolve `SCRIPT_DIR` relative to themselves
- K8s resource names are truncated to 63 characters and sanitized to lowercase alphanumeric + hyphens
- fio runs with `direct=1` (O_DIRECT) to bypass OS page cache
- Cleanup defaults to VMs/PVCs only; pool deletion requires explicit `--pools` or `--all` flag
- VM SSH access uses ed25519 keys auto-generated to `./ssh-keys/perf-test-key`
