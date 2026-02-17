# Configuration Reference

[Back to Index](../index.md)

This page documents every parameter in `00-config.sh` — the single source of truth for the test suite. All values are exported as environment variables or Bash arrays, and any can be overridden with environment variables before running the scripts.

> **Note:** `00-config.sh` validates cluster connectivity (`oc cluster-info`) on load. If the `oc` CLI is not authenticated or the cluster is unreachable, sourcing the config will fail with `[FATAL] oc CLI not authenticated or cluster unreachable`. Run `oc login` first.

## Cluster / Namespace

```bash
export TEST_NAMESPACE="${TEST_NAMESPACE:-vm-perf-test}"
export ODF_NAMESPACE="${ODF_NAMESPACE:-openshift-storage}"
```

| Variable | Default | Description |
|----------|---------|-------------|
| `TEST_NAMESPACE` | `vm-perf-test` | Namespace where test VMs, PVCs, and related resources are created. The namespace is assumed to exist. |
| `ODF_NAMESPACE` | `openshift-storage` | Namespace where ODF/Ceph components run. Used for creating CephBlockPools and checking pool health. |

## VM Guest Image

```bash
export DATASOURCE_NAME="${DATASOURCE_NAME:-fedora}"
export DATASOURCE_NAMESPACE="${DATASOURCE_NAMESPACE:-openshift-virtualization-os-images}"
export VM_IMAGE_NAME="fedora-cloud"
```

| Variable | Default | Description |
|----------|---------|-------------|
| `DATASOURCE_NAME` | `fedora` | Name of the OpenShift Virtualization DataSource to clone for each VM's root disk. Must exist in `DATASOURCE_NAMESPACE`. |
| `DATASOURCE_NAMESPACE` | `openshift-virtualization-os-images` | Namespace containing the DataSource. OpenShift Virtualization pre-caches boot images here via DataImportCrons. |
| `VM_IMAGE_NAME` | `fedora-cloud` | Human-readable name for report metadata. Not used in resource creation. |

## VM Sizes

```bash
declare -a VM_SIZES=(
  "small:2:4Gi"
  "medium:4:8Gi"
  "large:8:16Gi"
)
```

Each entry is formatted as `label:vCPU:memory`. These define the VM resource allocations tested.

| Size | vCPUs | Memory | Purpose |
|------|-------|--------|---------|
| small | 2 | 4Gi | Lightweight workloads, minimum viable |
| medium | 4 | 8Gi | Standard applications |
| large | 8 | 16Gi | Heavy workloads, databases |

**To customize:** Add or remove entries. The label must be lowercase alphanumeric (it's used in resource names).

## PVC Sizes

```bash
# Minimum 150Gi: IBM Cloud File dp2 profile enforces max ~25 IOPS/GB,
# so the 3000-IOPS SC requires ≥120Gi to provision.
declare -a PVC_SIZES=( "150Gi" "500Gi" "1000Gi" )
```

Sizes of the data disk PVCs being benchmarked. Larger PVCs may stripe across more Ceph OSDs, affecting performance.

**Minimum size constraint:** IBM Cloud VPC File shares use the `dp2` profile, which enforces a maximum IOPS-per-GB ratio of ~25. StorageClasses with higher fixed IOPS (e.g. `ibmc-vpc-file-3000-iops`) require a proportionally larger PVC. At 3000 IOPS the minimum is ~120Gi, so the smallest test PVC is set to 150Gi.

## Concurrency Levels

```bash
declare -a CONCURRENCY_LEVELS=( 1 5 10 )
```

Number of VMs running the same fio test simultaneously for each permutation. Tests storage contention and scalability.

| Level | Purpose |
|-------|---------|
| 1 | Baseline single-VM performance (no contention) |
| 5 | Moderate load |
| 10 | High contention scenario |

## ODF Storage Pools

```bash
declare -a ODF_POOLS=(
  "rep3:replicated:3"
  "rep3-virt:replicated:3"
  "rep3-enc:replicated:3"
  "rep2:replicated:2"
  "ec-2-1:erasurecoded:2:1"
  "ec-2-2:erasurecoded:2:2"
  "ec-4-2:erasurecoded:4:2"
)
```

Each entry is formatted as `name:type:params`:
- **Replicated:** `name:replicated:replication_size`
- **Erasure coded:** `name:erasurecoded:data_chunks:coding_chunks`

| Pool | Type | Config | Storage Overhead | Fault Tolerance | Min Hosts |
|------|------|--------|-----------------|-----------------|-----------|
| rep3 | Replicated | size=3 | 3.0x | 2 failures | 3 |
| rep3-virt | Replicated | size=3 | 3.0x | 2 failures | 3 |
| rep3-enc | Replicated | size=3 | 3.0x | 2 failures | 3 |
| rep2 | Replicated | size=2 | 2.0x | 1 failure | 2 |
| ec-2-1 | Erasure Coded | k=2, m=1 | 1.5x | 1 failure | 3 |
| ec-2-2 | Erasure Coded | k=2, m=2 | 2.0x | 2 failures | 4 |
| ec-4-2 | Erasure Coded | k=4, m=2 | 1.5x | 2 failures | 6 |

Pools requiring more OSD hosts than the cluster has are automatically skipped by `01-setup-storage-pools.sh`.

### The Three rep3 Variants

`rep3`, `rep3-virt`, and `rep3-enc` all use the **same underlying CephBlockPool** (`ocs-storagecluster-cephblockpool`) — no custom pool is created for any of them. They differ only in which OOB **StorageClass** they use:

| Pool Name | StorageClass | What's Different |
|-----------|-------------|-----------------|
| `rep3` | `ocs-storagecluster-ceph-rbd` | Default ODF SC. Uses basic RBD image features. |
| `rep3-virt` | `ocs-storagecluster-ceph-rbd-virtualization` | VM-optimized SC. Adds `exclusive-lock`, `object-map`, `fast-diff`, and `krbd:rxbounce` for better write performance and faster cloning. |
| `rep3-enc` | `ocs-storagecluster-ceph-rbd-encrypted` | Encrypted SC. Adds a LUKS2 encryption layer via IBM Key Protect. Same pool, but each volume is encrypted at the node level. See [Encrypted Storage Setup](encrypted-storage-setup.md). |

This mapping is handled by `get_storage_class_for_pool()` in `lib/vm-helpers.sh`.

**Why test all three?** They isolate the performance impact of StorageClass-level features while holding the pool constant:
- **rep3 vs rep3-virt** quantifies the benefit of `exclusive-lock` and other VM-optimized image features (up to 7x write IOPS difference)
- **rep3 vs rep3-enc** quantifies the CPU overhead of per-volume LUKS2 encryption

```bash
export ODF_DEFAULT_SC="ocs-storagecluster-ceph-rbd"
```

The **default StorageClass** used by the `rep3` pool. This is the ROKS out-of-box ODF SC, so no custom CephBlockPool is created for rep3. Also used for all VMs' root disks.

### VM-Optimized StorageClass Parameters

All custom StorageClasses created by `01-setup-storage-pools.sh` use VM-optimized RBD settings:

```yaml
imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff
mapOptions: krbd:rxbounce
```

These match the ODF out-of-box virtualization SC (`ocs-storagecluster-ceph-rbd-virtualization` / `rep3-virt`). The most impactful feature is `exclusive-lock`, which enables write-back caching and single-writer optimizations — without it, custom pools can show up to 7x worse write IOPS than `rep3-virt` even when backed by the same Ceph pool. See [Ceph and ODF — StorageClass Features](../concepts/ceph-and-odf.md#cephblockpool-custom-resource) for details on each feature.

> **Note:** StorageClass parameters are immutable. To apply updated features to existing SCs, delete them (`oc delete sc perf-test-sc-rep2 ...`) and re-run `01-setup-storage-pools.sh`.

See [Ceph and ODF](../concepts/ceph-and-odf.md) and [Erasure Coding Explained](../concepts/erasure-coding-explained.md) for background.

**Important:** EC pools require a minimum number of **hosts** (not just OSDs) when using `failureDomain: host` (the default). Each chunk must be placed on a separate host:
- ec-2-1 needs at least 3 hosts
- ec-3-1 needs at least 4 hosts
- ec-2-2 needs at least 4 hosts
- ec-4-2 needs at least 6 hosts

If your cluster has only 3 bare metal workers, only rep2, rep3, and ec-2-1 will work. Pools requiring more hosts (ec-3-1, ec-2-2, ec-4-2) are automatically skipped when the cluster has insufficient hosts. See [Erasure Coding Explained](../concepts/erasure-coding-explained.md#failure-domains-and-node-requirements) for details.

## IBM Cloud File CSI

```bash
declare -a FILE_CSI_PROFILES=(
  "ibmc-vpc-file-500-iops"
  "ibmc-vpc-file-1000-iops"
  "ibmc-vpc-file-3000-iops"
  "ibmc-vpc-file-eit"
  "ibmc-vpc-file-min-iops"
)
export FILE_CSI_DISCOVERY="auto"
```

```bash
export FILE_CSI_DEDUP="${FILE_CSI_DEDUP:-true}"
```

| Variable | Default | Description |
|----------|---------|-------------|
| `FILE_CSI_PROFILES` | 5 common profiles | Fallback list of IBM Cloud VPC File StorageClasses. Used if auto-discovery fails. |
| `FILE_CSI_DISCOVERY` | `auto` | Set to `auto` to discover all `vpc-file` StorageClasses at runtime. Set to `manual` to use only the fallback list. |
| `FILE_CSI_DEDUP` | `true` | When auto-discovering, skip `-metro-`, `-retain-`, and `-regional*` StorageClass variants. Set to `false` for multi-zone clusters with `rfs` allowlisting. |

The `02-setup-file-storage.sh` script handles discovery and writes the result to `results/file-storage-classes.txt`.

### IBM Cloud VPC File Share StorageClasses

All VPC File SCs use one of two underlying VPC file share profiles:

| StorageClass | Profile | Fixed IOPS | Min PVC Size | Notes |
|--------------|---------|-----------|-------------|-------|
| `ibmc-vpc-file-min-iops` | dp2 | auto (capacity-based) | 10Gi | IOPS scales with size (~1 IOPS/GB) |
| `ibmc-vpc-file-eit` | dp2 | 1000 | 40Gi | Encryption in transit enabled |
| `ibmc-vpc-file-500-iops` | dp2 | 500 | 10Gi | |
| `ibmc-vpc-file-1000-iops` | dp2 | 1000 | 40Gi | |
| `ibmc-vpc-file-3000-iops` | dp2 | 3000 | 120Gi | Requires ≥120Gi (25 IOPS/GB max ratio) |
| `ibmc-vpc-file-regional` | rfs | auto | N/A | Requires IBM support allowlisting |
| `ibmc-vpc-file-regional-max-bandwidth` | rfs | auto | N/A | Requires IBM support allowlisting |
| `ibmc-vpc-file-regional-max-bandwidth-sds` | rfs | auto | N/A | Requires IBM support allowlisting |

**dp2 profile:** Standard VPC file shares. IOPS can be set as a fixed value in the StorageClass or left to scale with capacity. The dp2 profile enforces a max ratio of ~25 IOPS per GB — if the requested capacity is too small for the fixed IOPS, provisioning fails with `shares_profile_capacity_iops_invalid`.

**rfs profile:** Regional file shares with cross-zone replication. Not available by default — requires opening an IBM support ticket for VPC allowlisting. Provisioning fails with `'rfs' profile is not accessible` until allowlisted.

Each base SC also has `-metro-`, `-retain-`, and `-metro-retain-` variants (see filtering below).

### Why Filter Variants?

IBM Cloud VPC File CSI creates up to 4 variants of each IOPS tier (e.g., for the 500-iops tier: `ibmc-vpc-file-500-iops`, `ibmc-vpc-file-metro-500-iops`, `ibmc-vpc-file-retain-500-iops`, `ibmc-vpc-file-metro-retain-500-iops`). On a **single-zone cluster**, these produce statistically identical fio results because:

- **`-retain-` variants:** The only difference is the PV reclaim policy (`Retain` instead of `Delete`). This has zero impact on I/O performance.
- **`-metro-` variants:** These add a volume topology constraint for multi-zone scheduling. On a single-zone cluster, the NFS share lands on the same infrastructure either way, so there is no measurable latency difference.
- **`-regional*` variants:** These use the `rfs` profile which requires IBM support allowlisting. Without it, PVC provisioning fails immediately.

With `FILE_CSI_DEDUP=true`, auto-discovery filters these out, reducing the number of File CSI StorageClasses from ~17 to 5 and avoiding redundant test permutations.

Set `FILE_CSI_DEDUP=false` if you are running on a **multi-zone cluster** where the metro topology constraint may affect latency, or if `rfs` has been allowlisted on your account.

## fio Settings

```bash
export FIO_RUNTIME="${FIO_RUNTIME:-120}"
export FIO_RAMP_TIME="${FIO_RAMP_TIME:-10}"
export FIO_IODEPTH="${FIO_IODEPTH:-32}"
export FIO_NUMJOBS="${FIO_NUMJOBS:-4}"
export FIO_OUTPUT_FORMAT="json+"
export FIO_TEST_FILE_SIZE="${FIO_TEST_FILE_SIZE:-4G}"
```

| Variable | Default | Description |
|----------|---------|-------------|
| `FIO_RUNTIME` | 120 | Duration of each fio test in seconds. Longer = more stable results. |
| `FIO_RAMP_TIME` | 10 | Warmup period before metrics are recorded. Lets I/O queues reach steady state. |
| `FIO_IODEPTH` | 32 | Number of in-flight I/O operations per job. Higher saturates the storage pipeline. |
| `FIO_NUMJOBS` | 4 | Number of parallel fio worker processes. Total parallelism = numjobs × iodepth. |
| `FIO_OUTPUT_FORMAT` | `json+` | fio output format. `json+` includes terse summary plus full JSON. |
| `FIO_TEST_FILE_SIZE` | 4G | Size of the test file per job. Must exceed OS read-ahead buffers. |

See [fio Benchmarking](../concepts/fio-benchmarking.md) for details on what these parameters mean.

### Block Sizes

```bash
declare -a FIO_BLOCK_SIZES=( "4k" "64k" "1M" )
```

Block sizes tested with variable-BS profiles (sequential-rw, random-rw, mixed-70-30).

| Size | Tests | Typical Workload |
|------|-------|-----------------|
| 4k | IOPS capability | Databases, random access |
| 64k | Mid-range | Application servers, mixed I/O |
| 1M | Throughput capability | Bulk data, backups, streaming |

### Fixed Block-Size Profiles

```bash
declare -a FIO_FIXED_BS_PROFILES=( "db-oltp" "app-server" "data-pipeline" )
```

Profiles listed here define per-job block sizes in their `.fio` files and skip the block-size loop. They run once per permutation with block_size set to "native".

### fio Profiles

```bash
declare -a FIO_PROFILES=(
  "sequential-rw"
  "random-rw"
  "mixed-70-30"
  "db-oltp"
  "app-server"
  "data-pipeline"
)
```

Names of fio job files in `fio-profiles/`. See [fio Profiles Reference](../architecture/fio-profiles-reference.md) for detailed documentation of each profile.

## Timeouts / Polling

```bash
export VM_READY_TIMEOUT=600
export VM_SSH_TIMEOUT=300
export FIO_COMPLETION_TIMEOUT=1800
export POLL_INTERVAL=10
export DV_STALL_THRESHOLD="${DV_STALL_THRESHOLD:-5}"
export DV_STALL_ACTION="${DV_STALL_ACTION:-warn}"
```

| Variable | Default | Description |
|----------|---------|-------------|
| `VM_READY_TIMEOUT` | 600s (10 min) | Maximum wait for a VM to reach Running state. Includes image clone and boot time. |
| `VM_SSH_TIMEOUT` | 300s (5 min) | Maximum wait for SSH to become available inside the VM. |
| `FIO_COMPLETION_TIMEOUT` | 1800s (30 min) | Maximum wait for a single fio run to complete. Must cover all sequential stonewall'd jobs in multi-job profiles. |
| `POLL_INTERVAL` | 10s | Seconds between status checks during polling loops. |
| `DV_STALL_THRESHOLD` | 5 polls | Number of consecutive polls with no DataVolume progress change before triggering a stall action. At the default `POLL_INTERVAL=10`, this fires after 50s of no progress. |
| `DV_STALL_ACTION` | `warn` | What to do when a DV clone stall is detected. `warn` = log a warning and keep waiting (warns again after the next threshold). `fail` = log error, dump diagnostics, and abort immediately. |

**Tuning guidance:**
- If VMs take a long time to boot (large image, slow storage), increase `VM_READY_TIMEOUT`
- If fio tests are long (high `FIO_RUNTIME`), increase `FIO_COMPLETION_TIMEOUT` accordingly
- For multi-job profiles (db-oltp, app-server, data-pipeline) with `stonewall`: `FIO_COMPLETION_TIMEOUT ≥ (FIO_RUNTIME + FIO_RAMP_TIME) × num_jobs + 180`
- For single-job profiles: `FIO_COMPLETION_TIMEOUT ≥ FIO_RUNTIME + FIO_RAMP_TIME + 180`
- If DataVolume clones frequently stall, set `DV_STALL_ACTION=fail` to abort early instead of waiting for the full `VM_READY_TIMEOUT`

## Results / Reporting

```bash
export RESULTS_DIR="${RESULTS_DIR:-./results}"
export REPORTS_DIR="${REPORTS_DIR:-./reports}"
export TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
export RUN_ID="perf-${TIMESTAMP}"
```

| Variable | Default | Description |
|----------|---------|-------------|
| `RESULTS_DIR` | `./results` | Where fio JSON results are stored (hierarchical tree). |
| `REPORTS_DIR` | `./reports` | Where generated reports (HTML, Markdown, XLSX, CSV) are written. |
| `TIMESTAMP` | Generated at runtime | Format: `YYYYMMDD-HHMMSS`. Used to construct the Run ID. |
| `RUN_ID` | `perf-<TIMESTAMP>` | Unique identifier for each test execution. Used in resource labels and log files. |

## SSH Key

```bash
export SSH_KEY_PATH="${SSH_KEY_PATH:-./ssh-keys/perf-test-key}"
```

Path to the ed25519 SSH private key used for VM access. If the key doesn't exist, `ensure_ssh_key()` generates one automatically. The public key (`.pub`) is injected into VMs via cloud-init.

## Bare Metal Worker Info

```bash
export BM_FLAVOR="${BM_FLAVOR:-bx3d}"
export BM_DESCRIPTION="IBM Cloud ROKS bare metal with NVMe"
```

Metadata included in reports for context. These don't affect test behavior.

## Logging

```bash
export LOG_LEVEL="${LOG_LEVEL:-INFO}"
export LOG_FILE="${RESULTS_DIR}/${RUN_ID}.log"
```

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_LEVEL` | `INFO` | Minimum log level. Options: `DEBUG`, `INFO`, `WARN`, `ERROR`. |
| `LOG_FILE` | `results/<run-id>.log` | All log output is also written to this file. |

Set `LOG_LEVEL=DEBUG` for verbose output during troubleshooting.

## Overriding Configuration

Any variable that uses the `${VAR:-default}` pattern can be overridden with environment variables:

```bash
# Run with shorter fio tests
FIO_RUNTIME=60 ./04-run-tests.sh

# Run with more I/O parallelism
FIO_IODEPTH=64 FIO_NUMJOBS=8 ./04-run-tests.sh

# Save results in a different directory
RESULTS_DIR=/data/test-results ./04-run-tests.sh

# Enable debug logging
LOG_LEVEL=DEBUG ./04-run-tests.sh
```

Arrays (`VM_SIZES`, `PVC_SIZES`, etc.) can only be overridden by editing `00-config.sh` directly.

## Next Steps

- [Running Tests](running-tests.md) — Execute the test suite with these settings
- [Customization](customization.md) — Adding pools, profiles, and sizes
- [Test Matrix Explained](../architecture/test-matrix-explained.md) — How config maps to test permutations
