# Customization

[Back to Index](../index.md)

This page explains how to extend the test suite — adding storage pools, creating fio profiles, adjusting VM sizes, and modifying fio parameters.

## Adding a Storage Pool

### Adding an ODF Pool

1. Edit `00-config.sh` and add an entry to the `ODF_POOLS` array:

```bash
declare -a ODF_POOLS=(
  "rep3:replicated:3"
  "rep2:replicated:2"
  "ec-2-1:erasurecoded:2:1"
  "ec-8-3:erasurecoded:8:3"     # ← New pool
)
```

Format: `name:type:params`
- Replicated: `name:replicated:replication_size`
- Erasure coded: `name:erasurecoded:data_chunks:coding_chunks`
- CephFS: `name:cephfs:data_replica_count` (metadata pool is always size=3)

**Important:** Before adding an EC pool, verify your cluster has enough worker nodes. EC pools require k+m hosts when using `failureDomain: host`. For example, ec-8-3 needs 11 hosts. Check with `oc get nodes -l node-role.kubernetes.io/worker`.

**Important:** Custom pools require correct settings (`targetSizeRatio`, `deviceClass`, `enableCrushUpdates`) to avoid severe performance bottlenecks. See the [CephBlockPool Setup Guide](ceph-pool-setup.md) for the full explanation and correct configuration.

2. Run `./01-setup-storage-pools.sh` to create the new pool and StorageClass.

3. Verify:
```bash
oc get cephblockpool perf-test-ec-8-3 -n openshift-storage
oc get sc perf-test-sc-ec-8-3
```

**Requirements:** EC pools require at least k+m OSDs on separate failure domains (hosts). An ec-8-3 pool needs 11 hosts with OSDs.

### Adding a CephFS Pool

Add a CephFS entry to the `ODF_POOLS` array:

```bash
declare -a ODF_POOLS=(
  "rep3:replicated:3"
  "cephfs-rep3:cephfs:3"
  "cephfs-rep2:cephfs:2"
  "cephfs-custom:cephfs:3"      # ← New CephFS pool
)
```

CephFS pools create a `CephFilesystem` CRD with a dedicated data pool. The metadata pool is always 3-replica for MDS safety. Note that some ODF versions limit to one CephFilesystem per cluster — if creation fails, the error is caught and logged.

### Adding a File CSI Profile

If you want to test specific IBM Cloud File StorageClasses:

1. Set `FILE_CSI_DISCOVERY="manual"` in `00-config.sh`
2. Edit the `FILE_CSI_PROFILES` array:

```bash
declare -a FILE_CSI_PROFILES=(
  "ibmc-vpc-file-500-iops"
  "ibmc-vpc-file-dp2"
  "my-custom-file-sc"           # ← Custom StorageClass
)
```

Or keep `FILE_CSI_DISCOVERY="auto"` and the script will discover all `vpc-file` StorageClasses automatically.

## Creating fio Profiles

### Variable Block-Size Profile

For profiles where the block-size loop should apply (like sequential-rw or random-rw):

1. Create a new `.fio` file in `fio-profiles/`:

```ini
# my-workload.fio — Description of what this simulates
[global]
ioengine=libaio
direct=1
runtime=${RUNTIME}
ramp_time=${RAMP_TIME}
iodepth=${IODEPTH}
numjobs=${NUMJOBS}
group_reporting=1
time_based=1
size=${FILE_SIZE}
bs=${BLOCK_SIZE}

[my-read-job]
rw=randread
stonewall

[my-write-job]
rw=randwrite
stonewall
```

2. Add the profile name to `FIO_PROFILES` in `00-config.sh`:

```bash
declare -a FIO_PROFILES=(
  "sequential-rw"
  "random-rw"
  "mixed-70-30"
  "db-oltp"
  "app-server"
  "data-pipeline"
  "my-workload"                 # ← New profile
)
```

The `${VARIABLE}` placeholders will be substituted at runtime by `render_fio_profile()`.

### Fixed Block-Size Profile

For profiles with per-job block sizes (like db-oltp):

1. Create the `.fio` file with explicit `bs=` per job (no `${BLOCK_SIZE}` in global):

```ini
# my-database.fio — Custom database workload
[global]
ioengine=libaio
direct=1
runtime=${RUNTIME}
ramp_time=${RAMP_TIME}
time_based=1
size=${FILE_SIZE}
group_reporting=1

[index-scan]
rw=randread
bs=16k
iodepth=16
numjobs=${NUMJOBS}
stonewall

[log-write]
rw=write
bs=4k
iodepth=1
numjobs=1
fsync=1
stonewall
```

2. Add to both `FIO_PROFILES` and `FIO_FIXED_BS_PROFILES`:

```bash
declare -a FIO_PROFILES=(
  ...
  "my-database"
)

declare -a FIO_FIXED_BS_PROFILES=( "db-oltp" "app-server" "data-pipeline" "my-database" )
```

This ensures the block-size loop is skipped for this profile (it runs once with `block_size="native"`).

### Profile Design Tips

- Use **stonewall** between jobs to prevent them from running in parallel
- Set **group_reporting=1** so all numjobs workers aggregate into one result
- Use **time_based=1** with **runtime** to control test duration (rather than stopping after writing `size` bytes)
- For latency-sensitive jobs, use low iodepth (1 or 4) and few numjobs
- For throughput jobs, use high iodepth (32+) and multiple numjobs
- Use `fsync=N` only when simulating durability requirements (databases, journals)

## Changing VM Sizes

Edit the `VM_SIZES` array in `00-config.sh`:

```bash
declare -a VM_SIZES=(
  "small:2:4Gi"
  "medium:4:8Gi"
  "large:8:16Gi"
  "xlarge:16:32Gi"              # ← New size
)
```

Format: `label:vCPU_count:memory`

**Constraints:**
- Labels must be lowercase alphanumeric (used in K8s resource names)
- vCPU and memory must not exceed the bare metal worker's capacity
- KubeVirt assigns dedicated CPU cores; ensure the node has enough

## Changing the VM Image

VMs boot from a built-in OpenShift Virtualization DataSource (pre-cached via DataImportCrons). To use a different OS image, point to a different DataSource:

```bash
export DATASOURCE_NAME="centos-stream9"
export DATASOURCE_NAMESPACE="openshift-virtualization-os-images"
export VM_IMAGE_NAME="centos-stream-9"
```

List available DataSources:
```bash
oc get datasource -n openshift-virtualization-os-images
```

**Requirements:**
- The DataSource must exist in the specified namespace with a ready PVC
- The image must support cloud-init (most cloud images do)
- The image must support the `fedora` user or you need to update the cloud-init template

If the image uses a different default user (e.g., `centos`), update the `virtctl ssh` commands in `lib/vm-helpers.sh` to use the correct username.

## Adjusting fio Parameters

### Runtime and Ramp Time

For more stable results, increase runtime:
```bash
export FIO_RUNTIME=300      # 5 minutes instead of 2
export FIO_RAMP_TIME=30     # Longer warmup
```

Longer runtimes smooth out transient variations but increase total test duration proportionally.

### I/O Parallelism

To test higher parallelism:
```bash
export FIO_IODEPTH=64       # Deeper I/O queue
export FIO_NUMJOBS=8        # More worker processes
```

Higher parallelism is needed to saturate fast NVMe-backed storage. If IOPS seem low, try increasing these values.

### Test File Size

```bash
export FIO_TEST_FILE_SIZE=8G    # Larger test file
```

Larger files ensure the dataset exceeds any cache or read-ahead buffers. However, they take longer to create at the start of each test.

### Block Sizes

To test additional block sizes:
```bash
declare -a FIO_BLOCK_SIZES=( "4k" "8k" "16k" "64k" "256k" "1M" )
```

This increases the number of test permutations for variable-BS profiles. Each added block size multiplies the count of those tests.

## Adjusting Concurrency

```bash
declare -a CONCURRENCY_LEVELS=( 1 3 5 10 20 )
```

Higher concurrency levels test more extreme contention but require more cluster resources (each VM needs CPU, memory, and a data PVC).

**Resource planning:** At concurrency 10 with large VMs (8 vCPU/16Gi), you need 80 vCPU and 160Gi of memory available on the cluster — plus the PVC storage.

## Adjusting Timeouts

If VMs take a long time to boot or fio runs are long:

```bash
export VM_READY_TIMEOUT=900         # 15 minutes for slow image clones
export FIO_COMPLETION_TIMEOUT=2400  # 40 minutes for long fio runs
```

Rule of thumb: for multi-job profiles (db-oltp, app-server, data-pipeline) with `stonewall`, the timeout must cover all sequential jobs: `(FIO_RUNTIME + FIO_RAMP_TIME) × num_jobs + 180` seconds. The default 1800s (30 min) handles the standard configuration; increase if you raise `FIO_RUNTIME` significantly.

## Adjusting PVC Sizes

```bash
declare -a PVC_SIZES=( "150Gi" "500Gi" "1000Gi" "2000Gi" )
```

Larger PVCs may exhibit different performance characteristics (striping across more OSDs). Ensure your cluster has sufficient storage capacity. The minimum PVC size must be at least 120Gi to satisfy the IBM Cloud File dp2 profile's IOPS-per-GB ratio for the 3000-IOPS StorageClass.

## Next Steps

- [Configuration Reference](configuration-reference.md) — Full parameter documentation
- [fio Profiles Reference](../architecture/fio-profiles-reference.md) — Existing profile details
- [Template Rendering](../architecture/template-rendering.md) — How templates are assembled
