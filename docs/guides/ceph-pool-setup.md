# CephBlockPool Setup Guide

[Back to Index](../index.md)

This guide explains how to create a correctly configured CephBlockPool on ODF. It covers the settings that are critical for performance and why the ODF out-of-box (OOB) pool outperforms naive custom pools.

If you're unfamiliar with Ceph pools, PGs, or CRUSH, read [Ceph and ODF](../concepts/ceph-and-odf.md) first.

## The Problem: Custom Pools with 1 PG

A newly created CephBlockPool with default settings gets **1 Placement Group**. Every I/O operation for the entire pool funnels through a single OSD primary, regardless of how many OSDs exist in the cluster. This creates a ~6x bottleneck compared to the OOB pool's 256 PGs spread across all OSDs.

This happens because the PG autoscaler decides PG count based on:

1. **`target_size_ratio`** — a hint telling the autoscaler what fraction of cluster capacity the pool will use
2. **Actual stored data** — how much data is currently in the pool

With no `target_size_ratio` and no data (empty pool or data deleted after a test run), the autoscaler assigns the minimum: 1 PG.

The OOB rep3 pool (`ocs-storagecluster-cephblockpool`) has `targetSizeRatio: 0.49`, telling the autoscaler it will use ~49% of cluster capacity. The autoscaler pre-allocates 256 PGs, distributing I/O across all OSDs.

### How to Check PG Counts

```bash
TOOLS_POD=$(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name)

# PG autoscaler status — shows current and target PG counts
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd pool autoscale-status

# Example output:
# POOL                                 SIZE  TARGET SIZE  RATE  RAW CAPACITY   RATIO  TARGET RATIO  EFFECTIVE RATIO  BIAS  PG_NUM  NEW PG_NUM  AUTOSCALE  BULK
# ocs-storagecluster-cephblockpool      42G                3.0        17.4T  0.0072          0.49           0.6757   1.0     256         256  on         False
# perf-test-rep2                        12M                2.0        17.4T  0.0000                                  1.0       1           1  on         False
#                                                                                                    ^^^^^^^^^^^^^^                    ^^^
#                                                                                                    no target ratio               stuck at 1 PG

# Detailed pool info
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd pool ls detail --format json | \
  jq '.[] | select(.pool_name | test("perf-test|cephblockpool")) | {pool_name, pg_num, pg_num_target, options}'
```

## OOB Pool vs Naive Custom Pool

Here is the OOB CephBlockPool spec (retrieved from the cluster) compared to what a minimal custom pool looks like:

### OOB Pool (correct)

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: ocs-storagecluster-cephblockpool
  namespace: openshift-storage
spec:
  failureDomain: host
  deviceClass: ssd
  enableCrushUpdates: true
  enableRBDStats: true
  replicated:
    size: 3
    requireSafeReplicaSize: true
    targetSizeRatio: 0.49
```

### Naive Custom Pool (broken)

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: perf-test-rep2
  namespace: openshift-storage
spec:
  failureDomain: host
  replicated:
    size: 2
    requireSafeReplicaSize: true
  deviceClass: ""
```

The differences that matter:

| Setting | OOB | Naive Custom | Impact |
|---------|-----|-------------|--------|
| `targetSizeRatio` | `0.49` | *(missing)* | **1 PG instead of 256 — single OSD bottleneck** |
| `deviceClass` | `ssd` | `""` | May place data on wrong device class in mixed clusters |
| `enableCrushUpdates` | `true` | *(missing)* | CRUSH rules not updated on topology changes |
| `enableRBDStats` | `true` | *(missing)* | No per-image I/O stats for monitoring |

## Required Settings

### 1. `targetSizeRatio` — Critical

This is the single most important setting. Without it, the PG autoscaler has no basis for pre-allocating PGs to an empty pool.

**For replicated pools**, set it as a field under `replicated:`:

```yaml
spec:
  replicated:
    size: 2
    targetSizeRatio: 0.1
```

**For erasure-coded pools**, set it in the `parameters` map (the `erasureCoded` CRD field doesn't support it directly):

```yaml
spec:
  parameters:
    target_size_ratio: "0.1"
  erasureCoded:
    dataChunks: 2
    codingChunks: 1
```

**Choosing the value:** The ratios across all pools should sum to roughly 1.0. The OOB pool claims 0.49. With up to 5 custom pools at 0.1 each, the total is ~1.0. The autoscaler normalizes the ratios, so exact values are less important than having *something* set — even 0.01 is vastly better than nothing, as it moves the pool from 1 PG to a reasonable count based on cluster size.

| Scenario | OOB Pool | Custom Pools | Suggested Ratio |
|----------|----------|-------------|-----------------|
| 1 custom pool | 0.49 | 1 | 0.3–0.5 |
| 2–5 custom pools | 0.49 | 2–5 | 0.1 each |
| 6+ custom pools | 0.49 | 6+ | 0.05–0.08 each |

After setting `targetSizeRatio`, the autoscaler will scale PGs over the next few minutes. Typical results on a 3-node cluster:

| Ratio | Approximate PG Count |
|-------|---------------------|
| 0.49 | 256 |
| 0.1 | 32–64 |
| 0.05 | 16–32 |
| 0.01 | 4–8 |

### 2. `deviceClass: ssd`

Restricts the pool to OSDs on the `ssd` CRUSH class. On ODF bare metal clusters, NVMe drives are classified as `ssd`. Setting this explicitly ensures the pool targets the correct device class.

With `deviceClass: ""` (empty string), the pool uses the default CRUSH root. On a single-class cluster this works by accident, but on a mixed-media cluster (NVMe + HDD), data could land on the wrong tier.

```yaml
spec:
  deviceClass: ssd
```

To check available device classes:

```bash
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd crush class ls
# ["ssd"]
```

### 3. `enableCrushUpdates: true`

Allows the Rook operator to update CRUSH rules when the cluster topology changes (node add/remove, OSD replacement). Without this, CRUSH maps can become stale after scaling events, leading to uneven data distribution.

```yaml
spec:
  enableCrushUpdates: true
```

### 4. `enableRBDStats: true`

Enables per-RBD-image I/O statistics collection. This allows monitoring individual volume performance via:

```bash
oc exec -n openshift-storage ${TOOLS_POD} -- rbd perf image iostat --pool=perf-test-rep2
```

Negligible overhead. No reason to leave it off.

```yaml
spec:
  enableRBDStats: true
```

## Complete Correct Examples

### Replicated Pool

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: perf-test-rep2
  namespace: openshift-storage
spec:
  failureDomain: host
  deviceClass: ssd
  enableCrushUpdates: true
  enableRBDStats: true
  replicated:
    size: 2
    requireSafeReplicaSize: true
    targetSizeRatio: 0.1
```

### Erasure-Coded Pool

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: perf-test-ec-2-1
  namespace: openshift-storage
spec:
  failureDomain: host
  deviceClass: ssd
  enableCrushUpdates: true
  enableRBDStats: true
  parameters:
    target_size_ratio: "0.1"
  erasureCoded:
    dataChunks: 2
    codingChunks: 1
```

**EC host requirement:** EC pools need k+m unique failure domains. With `failureDomain: host`, ec-2-1 needs 3 hosts, ec-2-2 needs 4, ec-4-2 needs 6. Pools that exceed the available host count will fail to reach `Ready` status.

## StorageClass Configuration

Each CephBlockPool needs a matching StorageClass. The critical parameters for VM workloads are `imageFeatures` and `mapOptions`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: perf-test-sc-rep2
provisioner: openshift-storage.rbd.csi.ceph.com
parameters:
  clusterID: <from existing SC>
  pool: perf-test-rep2
  imageFormat: "2"
  imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff
  mapOptions: krbd:rxbounce
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
  csi.storage.k8s.io/fstype: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
```

### Image Features Explained

| Feature | Purpose | Performance Impact |
|---------|---------|-------------------|
| `exclusive-lock` | Enables write-back caching and single-writer optimizations | **Major** — without it, write IOPS can be up to 7x worse |
| `object-map` | Bitmap tracking allocated objects for sparse images | Speeds up operations on thin-provisioned images |
| `fast-diff` | Accelerates snapshot diff and DataVolume clone operations | Faster VM boot from golden image clones |
| `deep-flatten` | Makes clones fully independent after flattening | Required for clean snapshot/clone lifecycle |
| `layering` | Enables copy-on-write cloning | Required for DataVolume cloning |

### `mapOptions: krbd:rxbounce`

The `rxbounce` option is a correctness fix for kernel-space RBD (`krbd`). Without it, guest OSes can encounter CRC errors on reads from RBD-backed block devices. The overhead is trivial (extra memory copy on the receive path).

### EC StorageClass: `pool` vs `dataPool`

RBD cannot store image metadata on an erasure-coded pool. EC StorageClasses must use a replicated pool for metadata (`pool`) and the EC pool for data blocks (`dataPool`):

```yaml
parameters:
  pool: ocs-storagecluster-cephblockpool       # Replicated — stores image headers/metadata
  dataPool: perf-test-ec-2-1                    # Erasure-coded — stores data blocks
```

### StorageClass Immutability

StorageClass parameters are **immutable** in Kubernetes. If you need to change `imageFeatures`, `mapOptions`, or any other parameter on an existing SC, you must delete and recreate it:

```bash
oc delete sc perf-test-sc-rep2
# Then re-create with corrected parameters
```

Existing PVCs bound to the old SC are unaffected — the parameters were already baked in at provisioning time.

## Waiting for PG Convergence

After creating pools with `targetSizeRatio`, the PG autoscaler needs time to create and distribute PGs. Monitor progress:

```bash
# Watch PG autoscaler converge
watch -n5 "oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd pool autoscale-status | grep perf-test"

# Check for 'misplaced' or 'remapped' PGs during scaling
oc exec -n openshift-storage ${TOOLS_POD} -- ceph -s | grep -E 'pgs|misplaced|remapped'
```

The autoscaler doubles PG count in steps (1 → 2 → 4 → 8 → 16 → 32 ...) with a cooldown between each step. Going from 1 PG to 32 PGs takes several minutes. Going from 1 to 128+ can take 10–15 minutes.

**Do not run benchmarks until PG counts have stabilized.** The test suite's `01-setup-storage-pools.sh` calls `wait_for_pg_convergence()` to handle this automatically.

## Common Pitfalls

### PG autoscaler shows convergence at 1 PG

The convergence check verifies `pg_num == new_pg_num` — that the autoscaler has *finished* adjusting. But if the autoscaler *decided* 1 PG is correct (no size hint, no data), convergence completes instantly at 1 PG. Always verify the actual PG count, not just convergence status.

### `requireSafeReplicaSize: true` with insufficient hosts

With `requireSafeReplicaSize: true` (recommended), Ceph refuses to write if the pool cannot achieve the requested replication factor. A rep3 pool on a 2-node cluster will never reach `Ready`. Check OSD host count before creating pools:

```bash
oc get pods -n openshift-storage -l app=rook-ceph-osd \
  -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l
```

### Pool created but StorageClass missing

Creating the CephBlockPool does not automatically create a StorageClass. You must create both. If the pool is `Ready` but there's no SC, PVCs referencing it will stay `Pending`.

### Changing CephBlockPool spec fields

Most CephBlockPool spec fields (including `replicated.size`, `failureDomain`, `deviceClass`) can be updated by editing the CR. However, some changes (like changing `failureDomain` from `host` to `rack`) trigger a CRUSH rule rebuild and PG remapping, which causes data migration. Plan for this during maintenance windows.

`targetSizeRatio` can be changed at any time — the autoscaler will adjust PG count on the next evaluation cycle (typically within 60 seconds).

## Quick Reference

Minimum correct CephBlockPool spec for a replicated pool:

```yaml
spec:
  failureDomain: host          # or rack — match your OOB pool
  deviceClass: ssd             # match OSD device class
  enableCrushUpdates: true     # keep CRUSH rules current
  enableRBDStats: true         # enable per-image monitoring
  replicated:
    size: 2                    # replication factor
    requireSafeReplicaSize: true
    targetSizeRatio: 0.1       # CRITICAL — prevents 1-PG bottleneck
```

Minimum correct StorageClass `imageFeatures` for VM workloads:

```
imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff
mapOptions: krbd:rxbounce
```

## Next Steps

- [Ceph and ODF](../concepts/ceph-and-odf.md) — Pool architecture, CRUSH, RBD fundamentals
- [Erasure Coding Explained](../concepts/erasure-coding-explained.md) — EC pools in depth
- [Customization](customization.md) — Adding pools to the test suite
- [Configuration Reference](configuration-reference.md) — All `00-config.sh` parameters
