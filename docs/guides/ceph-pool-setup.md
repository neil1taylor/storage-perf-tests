# CephBlockPool Setup Guide

[Back to Index](../index.md)

This guide walks you through creating a custom CephBlockPool on a ROKS cluster with OpenShift Data Foundation (ODF). It starts with what you already have, walks through creating your first pool step by step, then explains why each setting matters and how the internals work. Each concept is introduced as it becomes relevant — you don't need to read anything else first.

For a deeper background on Ceph architecture, see [Ceph and ODF](../concepts/ceph-and-odf.md).

## What You Start With

A fresh ROKS cluster with ODF installed gives you two pre-configured storage pools:

| Pool | StorageClass | Type | Purpose |
|------|-------------|------|---------|
| `ocs-storagecluster-cephblockpool` | `ocs-storagecluster-ceph-rbd` | Replicated (size=3) | Block storage for PVCs |
| `ocs-storagecluster-cephfilesystem-data0` | `ocs-storagecluster-cephfs` | Replicated (size=3) | Shared filesystem storage |

A few terms to understand:

- **Pool** — A logical partition of your Ceph storage cluster. Each pool has its own data protection policy (how many copies of your data are kept) and its own performance characteristics. Think of it like a volume group that determines where and how data is stored.
- **StorageClass** — A Kubernetes resource that connects your PVCs (storage requests) to a specific pool. When a workload requests storage, the StorageClass tells Kubernetes which pool to provision it from and what features to enable.
- **Replicated (size=3)** — Every piece of data is stored as 3 copies across different disks. This protects against disk or node failures — if one copy is lost, the other two still exist.

These are the **out-of-box (OOB) pools**. ODF created them with carefully chosen settings that ensure good performance. The most important setting is one you can't see from the table: `targetSizeRatio: 0.49` on each pool. This will become important shortly — it controls how well I/O is distributed across your cluster's disks.

You'll also see a few internal pools (`.mgr`, `.nfs`, `cephfilesystem-metadata`) — you can ignore these.

To see your current pools, run:

```bash
TOOLS_POD=$(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name)
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd pool autoscale-status
```

This connects to the Ceph management tools running inside your cluster and shows the status of every pool, including how many **Placement Groups (PGs)** each one has. PGs are explained in the [Understanding PG Autoscaling](#understanding-pg-autoscaling) section — for now, just know that more PGs = better performance, and the OOB pools typically have 256+.

## Step 1: Check Your Cluster

Before creating a pool, you need to know a few things about your cluster's storage topology. The key concept here is **OSDs (Object Storage Daemons)** — these are the processes that manage your physical disks. Each NVMe drive on a bare metal worker runs one OSD, so a 3-node cluster with 8 NVMe drives per node has 24 OSDs.

```bash
# How many worker nodes have OSDs?
oc get pods -n openshift-storage -l app=rook-ceph-osd \
  -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l

# How many OSDs total? (one per NVMe drive)
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd tree | grep -c "up "

# What device class are the OSDs?
# On ROKS bare metal this is usually "ssd" (NVMe drives are classified as SSD)
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd crush class ls

# What failureDomain does the OOB pool use?
oc get cephblockpool ocs-storagecluster-cephblockpool -n openshift-storage \
  -o jsonpath='{.spec.failureDomain}'
```

The last two values need some explanation:

- **`deviceClass`** — Ceph classifies each OSD's underlying drive as `ssd` or `hdd`. When you create a pool, you specify which class to use. This ensures your pool's data lands on the right type of drive. On ROKS bare metal, all NVMe drives are classified as `ssd`.

- **`failureDomain`** — Controls how Ceph distributes copies of your data. With `failureDomain: host`, each copy must land on a different worker node. With `failureDomain: rack`, each copy lands on a different rack. The goal is to survive hardware failures — if one host/rack goes down, the other copies are still available. Your custom pool should use the same `failureDomain` as the OOB pool. See [Failure Domains and Topology](../concepts/failure-domains-and-topology.md) for a deep dive on failure domain options, CRUSH placement, and ROKS rack topology.

This information determines what pool configurations are possible:

- **Replicated pools** need at least N hosts (where N = replication size). A rep2 pool needs 2+ hosts, rep3 needs 3+.
- **Erasure-coded pools** need at least k+m hosts. An ec-2-1 pool needs 3+ hosts, ec-4-2 needs 6+. See [Erasure Coding Explained](../concepts/erasure-coding-explained.md) for details on EC pools.

## Step 2: Create the CephBlockPool

A **CephBlockPool** is a Kubernetes custom resource that tells the Rook operator to create a new Ceph pool. Here is a correctly configured replicated pool. Every setting is important — see [Why These Settings Matter](#why-these-settings-matter) for what goes wrong without each one.

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: my-custom-pool
  namespace: openshift-storage
spec:
  failureDomain: host            # Match your OOB pool (from Step 1)
  deviceClass: ssd               # Match your OSD device class (from Step 1)
  enableCrushUpdates: true       # Keep data distribution rules current on topology changes
  enableRBDStats: true           # Enable per-volume I/O monitoring
  replicated:
    size: 2                      # Replication factor (2 = two copies of every object)
    requireSafeReplicaSize: true # Refuse writes if replication can't be met
    targetSizeRatio: 0.1         # Tell Ceph this pool will use ~10% of cluster capacity
```

The `targetSizeRatio` is the most critical setting here. It controls how Ceph distributes I/O across your disks. Without it, your pool gets catastrophically bad performance — this is explained fully in [Understanding PG Autoscaling](#understanding-pg-autoscaling), but in short: 0.1 is the right value for a custom pool alongside the OOB pools.

**Naming convention:** This guide uses `my-custom-pool` as a placeholder name. The test suite uses a `perf-test-` prefix (e.g., `perf-test-rep2`, `perf-test-ec-2-1`). Choose whatever naming fits your project — just keep it consistent between pool and StorageClass names.

Apply it:

```bash
oc apply -f my-custom-pool.yaml
```

Wait for it to become Ready:

```bash
oc get cephblockpool my-custom-pool -n openshift-storage -w
# Wait for PHASE to show "Ready"
```

For an **erasure-coded (EC) pool**, the structure is slightly different. EC pools split data into chunks and add parity data for fault tolerance, using less raw storage than replication (see [Erasure Coding Explained](../concepts/erasure-coding-explained.md)). The `targetSizeRatio` goes in the `parameters` map because the `erasureCoded` CRD field doesn't support it directly:

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: my-ec-pool
  namespace: openshift-storage
spec:
  failureDomain: host
  deviceClass: ssd
  enableCrushUpdates: true
  enableRBDStats: true
  parameters:
    target_size_ratio: "0.1"     # Note: string value in parameters map
  erasureCoded:
    dataChunks: 2                # k data chunks
    codingChunks: 1              # m parity chunks (need k+m hosts)
```

## Step 3: Create the StorageClass

A CephBlockPool on its own isn't directly usable by workloads. In Kubernetes, storage is provisioned through **StorageClasses** — when a pod or VM requests a PVC (PersistentVolumeClaim), the StorageClass tells Kubernetes which pool to create the volume in and what features to enable.

You need to create a StorageClass that points to your new pool. The easiest way is to copy the settings from the OOB StorageClass and change the pool name.

First, get the `clusterID` from an existing SC (this identifies your Ceph cluster and is the same for all StorageClasses):

```bash
oc get sc ocs-storagecluster-ceph-rbd -o jsonpath='{.parameters.clusterID}'
```

Then create the StorageClass:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: my-custom-sc
provisioner: openshift-storage.rbd.csi.ceph.com
parameters:
  clusterID: <paste clusterID from above>
  pool: my-custom-pool
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

The `imageFeatures` and `mapOptions` lines are important for VM workloads — they enable write-back caching, fast cloning, and a correctness fix for kernel-space block devices. These are explained in [Why These Settings Matter](#imagefeatures-and-mapoptions-storageclass). The `csi.storage.k8s.io/*` parameters tell the CSI driver where to find the secrets it needs to communicate with Ceph — these are the same for all ODF StorageClasses on a ROKS cluster.

For **erasure-coded pools**, add `dataPool` and point `pool` to the OOB replicated pool. This is because RBD (the block storage layer) can't store image metadata on an EC pool — it needs a replicated pool for metadata and uses the EC pool only for the actual data blocks:

```yaml
parameters:
  pool: ocs-storagecluster-cephblockpool   # Replicated pool for metadata
  dataPool: my-ec-pool                      # EC pool for data blocks
```

Apply it:

```bash
oc apply -f my-custom-sc.yaml
```

## Step 4: Wait for PG Convergence

After creating the pool, Ceph needs a few minutes to set up **Placement Groups (PGs)** — the internal data structures that distribute I/O across your OSDs. A tool called the **PG autoscaler** runs inside Ceph and automatically determines how many PGs each pool needs. The more PGs, the more evenly I/O is spread across disks.

This is where `targetSizeRatio` pays off — it told the autoscaler to pre-allocate PGs proportional to the pool's expected size, rather than starting at the minimum of 1 PG. Don't create PVCs on the new pool until PGs have stabilized.

```bash
# Watch the PG count increase
watch -n5 "oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd pool autoscale-status | grep my-custom"
```

You should see `PG_NUM` climb from 1 through powers of 2 (1 → 2 → 4 → 8 → 16 → 32 → ...) until it stabilizes. When `PG_NUM` stops changing and `NEW PG_NUM` is empty, convergence is complete. This typically takes 2–5 minutes for small ratios.

## Step 5: Verify Everything

```bash
# 1. Pool is Ready
oc get cephblockpool my-custom-pool -n openshift-storage -o jsonpath='{.status.phase}'
# Expected output: Ready

# 2. PG count is reasonable (not stuck at 1)
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd pool autoscale-status | grep my-custom
# Expected: PG_NUM should be 32+ for a 0.1 ratio on a 24-OSD cluster.
# Example output (columns: POOL, SIZE, TARGET SIZE, RATE, RAW CAPACITY, RATIO, TARGET RATIO, EFFECTIVE RATIO, BIAS, PG_NUM, NEW PG_NUM, AUTOSCALE, BULK):
#   my-custom-pool   0       0.0   2.0   71577G  0.0000  0.1000  0.0926  1.0  64  -  on  False
# If PG_NUM shows 1, targetSizeRatio was not set correctly.

# 3. StorageClass exists
oc get sc my-custom-sc
# Expected: should list the SC with provisioner openshift-storage.rbd.csi.ceph.com

# 4. Test PVC creation
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-my-custom-pool
spec:
  storageClassName: my-custom-sc
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF

# Should reach Bound within ~30 seconds
oc get pvc test-my-custom-pool -w
# Expected: STATUS transitions from Pending → Bound

# Clean up
oc delete pvc test-my-custom-pool
```

At this point you have a working custom pool with a matching StorageClass. The rest of this guide explains why each setting matters and how the PG autoscaler works under the hood.

---

## Why These Settings Matter

If you followed the steps above, your pool already has all of these settings. This section explains *why* each one is needed and what goes wrong without it — useful for understanding, troubleshooting, or reviewing pools created by others.

### The OOB Pool Spec

For reference, here's what the OOB pool looks like (retrieved from the cluster). This is the "known good" configuration that ODF creates automatically:

```yaml
spec:
  failureDomain: host
  deviceClass: ssd
  enableCrushUpdates: true
  enableRBDStats: true
  replicated:
    size: 3
    replicasPerFailureDomain: 1
    targetSizeRatio: 0.49
```

A naive custom pool (e.g., from a tutorial or Rook quickstart) typically omits most of these:

| Setting | OOB | Naive Custom | Impact |
|---------|-----|-------------|--------|
| `targetSizeRatio` | `0.49` | *(missing)* | **1 PG instead of 256 — single OSD bottleneck (~6x slower)** |
| `deviceClass` | `ssd` | `""` | May place data on wrong device class in mixed clusters |
| `enableCrushUpdates` | `true` | *(missing)* | CRUSH rules not updated on topology changes |
| `enableRBDStats` | `true` | *(missing)* | No per-image I/O stats for monitoring |

### `targetSizeRatio` — Why It's Critical

As explained in [Understanding PG Autoscaling](#understanding-pg-autoscaling), this setting controls how many PGs the autoscaler allocates. Without it, a new empty pool gets 1 PG and all I/O bottlenecks on a single OSD (~6x slower than the OOB pool).

The OOB pools each use 0.49, expecting to be the only two significant pools (0.49 + 0.49 = 0.98). When you add custom pools, the ratios no longer need to sum to exactly 1.0 — the autoscaler normalizes them. What matters is having *something* set. Even 0.01 is vastly better than nothing.

**Choosing a value:** Use 0.1 for most custom pools. With up to 5 custom pools at 0.1 each plus the two OOB pools at 0.49, the total is ~1.5, which the autoscaler handles fine via normalization. See [PG Autoscaler Deep Dive](#pg-autoscaler-deep-dive) for the full math.

### `deviceClass: ssd`

Restricts the pool to OSDs on the `ssd` CRUSH class. On ROKS bare metal, NVMe drives are classified as `ssd`. With `deviceClass: ""` (empty string), the pool uses the default CRUSH root — on a single-class cluster this works by accident, but on a mixed-media cluster data could land on the wrong tier.

### `enableCrushUpdates: true`

**CRUSH** is the algorithm Ceph uses to determine which OSDs store which PGs. It uses a set of rules based on the cluster topology (which OSDs are on which hosts/racks). When nodes are added or removed, these rules may need updating.

`enableCrushUpdates: true` allows the Rook operator to update CRUSH rules automatically when the topology changes. Without this, CRUSH maps can become stale after scaling events, leading to uneven data distribution.

### `enableRBDStats: true`

**RBD (RADOS Block Device)** is the block storage layer that sits on top of Ceph pools. Each PVC backed by an ODF StorageClass is an RBD image inside a pool.

`enableRBDStats: true` enables per-image I/O statistics, allowing you to monitor individual volume performance:

```bash
oc exec -n openshift-storage ${TOOLS_POD} -- rbd perf image iostat --pool=my-custom-pool
```

Negligible overhead. No reason to leave it off.

### `requireSafeReplicaSize` and `min_size` — Availability vs Durability

Ceph pools have two related settings:

- **`size`** — The replication factor (how many copies are written)
- **`min_size`** — The minimum number of copies that must be acknowledged before I/O succeeds

When `requireSafeReplicaSize: true` is set (as in all our pools), Ceph enforces safe defaults for `min_size`:

| Pool | `size` | `min_size` | Behaviour When 1 OSD Is Down |
|------|--------|-----------|------------------------------|
| **rep3** | 3 | 2 | **I/O continues** — 2 of 3 copies still available, PGs stay `active+degraded` |
| **rep2** | 2 | 2 | **I/O blocks** — only 1 of 2 copies available, PGs go `peered` (inactive) until the OSD returns or recovery completes |

This is a critical operational difference: **rep2 has worse availability than rep3**. A single OSD failure (or even a single OSD restart during maintenance) blocks all I/O to PGs hosted on that OSD. The data is still durable (one copy survives), but the PG cannot serve reads or writes until both copies are available again.

With rep3, losing one OSD still leaves 2 copies — above `min_size=2` — so I/O continues in degraded mode while Ceph re-replicates the lost copy to another OSD.

**Why not set `min_size=1` on rep2?** You could override this manually:

```bash
ceph osd pool set <pool-name> min_size 1
```

This would allow rep2 to continue serving I/O with a single copy, but at the risk of **data loss**: if the one remaining OSD also fails before recovery completes, the data is gone. With `min_size=1`, Ceph acknowledges writes after storing just one copy — a power failure at that moment loses the write entirely. This is why `requireSafeReplicaSize: true` exists and why our pools use it.

**Impact on benchmarks:** During normal operation (all OSDs healthy), `min_size` has no effect on performance. It only matters during failures. However, the choice of `size` does affect write latency: rep2 waits for 2 OSD acknowledgements per write, rep3 waits for 3. This is why rep2 consistently shows better write IOPS than rep3 in benchmark results.

### `imageFeatures` and `mapOptions` (StorageClass)

The StorageClass `imageFeatures` parameter controls which RBD capabilities are enabled on volumes created from this StorageClass. These are set once at volume creation time. For VM workloads, the critical features are:

| Feature | Purpose | Impact |
|---------|---------|--------|
| `exclusive-lock` | Enables write-back caching and single-writer optimizations | **Major** — without it, write IOPS can be up to 7x worse |
| `object-map` | Bitmap tracking allocated objects for sparse images | Speeds up operations on thin-provisioned images |
| `fast-diff` | Accelerates snapshot diff and DataVolume clone operations | Faster VM boot from golden image clones |
| `deep-flatten` | Makes clones fully independent after flattening | Required for clean snapshot/clone lifecycle |
| `layering` | Enables copy-on-write cloning | Required for DataVolume cloning |

`mapOptions: krbd:rxbounce` is a correctness fix for kernel-space RBD — without it, guest OSes can encounter CRC errors on reads. Trivial overhead.

**StorageClass parameters are immutable in Kubernetes.** If you need to change these on an existing SC, you must delete and recreate it. Existing PVCs are unaffected — the parameters were baked in at provisioning time.

---

## Understanding PG Autoscaling

Now that you have a working pool, this section explains what's happening under the hood — how PGs work, why `targetSizeRatio` is so important, and what happens when you add multiple custom pools alongside the OOB ones.

For the exact formula and impact modelling, see [PG Autoscaler Deep Dive](#pg-autoscaler-deep-dive).

### What Are Placement Groups?

When data is written to a Ceph pool, it's split into objects. But Ceph doesn't map objects directly to individual disks (OSDs) — there are millions of objects and only a handful of OSDs. Instead, it uses an intermediate layer called **Placement Groups (PGs)**.

Each object is hashed to a PG, and each PG is assigned to a set of OSDs. For a rep2 pool, each PG maps to 2 OSDs (primary + one replica). The primary OSD handles all reads and writes for that PG's objects.

```
Object → hash → PG → [primary OSD, replica OSD]
```

The number of PGs determines how well I/O is parallelised:

- **1 PG** = all I/O through one OSD primary, other OSDs sit idle (bottleneck)
- **64 PGs** = I/O spread across many OSDs (good)
- **256 PGs** = I/O well distributed across all OSDs (what the OOB pools have)

This is why the PG count matters so much for performance — it's the difference between using one disk and using all of them.

### How the Autoscaler Decides PG Count

The PG autoscaler (a built-in Ceph module) automatically determines how many PGs each pool should have. It uses two signals:

1. **`target_size_ratio`** — A hint you set on the pool: "This pool will use X% of cluster capacity." The autoscaler pre-allocates PGs proportionally.
2. **Actual stored data** — How much data is currently in the pool. The autoscaler adjusts PGs as data grows.

For a newly created pool, signal 2 is zero — there's no data yet. If signal 1 is also missing (no `targetSizeRatio`), the autoscaler has no information to work with and assigns the minimum: **1 PG**. This is why a custom pool without `targetSizeRatio` performs ~6x worse than the OOB pool — all I/O is bottlenecked on a single OSD.

### How Ratios Work With Multiple Pools

The OOB pools claim 0.49 each (totalling 0.98). When you add a custom pool at 0.1, the total becomes 1.08. The autoscaler normalizes: each pool's effective share is its ratio divided by the total. With a total of 1.08:

- OOB RBD: 0.49 / 1.08 = 0.45 effective (was 0.50)
- OOB CephFS: 0.49 / 1.08 = 0.45 effective (was 0.50)
- Custom pool: 0.10 / 1.08 = 0.09 effective

The OOB pools lose a small fraction of their effective share, but their actual PG counts don't change — the autoscaler has a **threshold** (default 3.0) that prevents PG adjustments unless the ideal count differs from the current count by more than 3x. This means you can add many custom pools without affecting the OOB pools. See the [scenario modelling table](#impact-of-custom-pools-on-oob-pools) for the full analysis.

### Checking PG Status

```bash
TOOLS_POD=$(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name)

# PG autoscaler status — key columns are PG_NUM, NEW PG_NUM, TARGET RATIO, EFFECTIVE RATIO
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd pool autoscale-status

# Detailed pool info as JSON
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd pool ls detail --format json | \
  jq '.[] | select(.pool_name | test("my-custom|cephblockpool")) | {pool_name, pg_num, pg_num_target, options}'
```

In the `autoscale-status` output:
- `PG_NUM` is the current PG count
- `NEW PG_NUM` shows what the autoscaler wants to change it to (empty = no change planned)
- `TARGET RATIO` is the value you set
- `EFFECTIVE RATIO` is after normalization

---

## PG Autoscaler Deep Dive

This section covers the exact formula, threshold behaviour, and impact modelling. It builds on the concepts introduced in [Understanding PG Autoscaling](#understanding-pg-autoscaling) — you should read that section first if you haven't already.

### The Formula

Recall that each PG maps to a set of OSDs — for a rep3 pool, each PG creates 3 **PG instances** (one on the primary OSD, one on each replica OSD). The autoscaler's goal is that each OSD holds approximately `mon_target_pg_per_osd` PG instances across all pools.

Key cluster parameters (from `ceph config dump`):

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `mon_target_pg_per_osd` | 200 | Target PG instances per OSD across all pools |
| `mon_max_pg_per_osd` | 1000 | Hard ceiling — pool creation fails above this |
| Autoscaler threshold | 3.0 | Ratio between ideal and actual before autoscaler acts |

The calculation:

```
1. Total target PG instances = mon_target_pg_per_osd × num_osds
   Example: 200 × 24 = 4,800

2. Normalization (when sum of all target_size_ratios > 1.0):
   effective_ratio = pool.target_ratio / sum(all target_ratios)

3. Ideal PG count for each pool:
   ideal = (effective_ratio × num_osds × mon_target_pg_per_osd) / pool.replication_size

4. Decision (threshold = 3.0):
   if ideal > current × threshold  → scale UP (double per step)
   if ideal < current / threshold  → scale DOWN (halve per step)
   else                            → no change (within dead zone)
```

### The Threshold Dead Zone

The threshold (3.0) creates a wide band where the autoscaler accepts the current PG count as "close enough." This is deliberate — PG changes trigger data migration, so Ceph is conservative.

For example, a pool with 64 PGs and an ideal of 153:
- Scale up? 153 < 64 × 3 (192) → no
- Scale down? 153 > 64 / 3 (21) → no
- Result: 64 PGs stays, even though the "ideal" is 153

The autoscaler only acts when the gap exceeds 3x. Pools often stabilize at a PG count that's 1/2 to 1/3 of their ideal.

### How PGs Scale Up

The autoscaler doesn't jump directly to the ideal. It doubles the PG count in steps with a cooldown between each:

```
1 → 2 → 4 → 8 → 16 → 32 → 64 → ...
```

At each step, it re-evaluates whether ideal/current still exceeds the threshold. Once the ratio drops below 3.0, it stops. This means the final PG count depends on what other pools existed at the time (since they affect the effective ratio).

### Impact of Custom Pools on OOB Pools

**Will adding custom pools reduce OOB pool PG counts?**

For the OOB RBD pool (typically 256 PGs) to scale **down**, the autoscaler needs:

```
ideal < 256 / 3 = 85 PGs
```

Working backwards through the formula with 24 OSDs, that requires `effective_ratio < 0.053`, meaning `total_ratios > 0.49 / 0.053 = 9.2`. At 0.1 per custom pool, that's **~80 custom pools**. Not a realistic concern.

**Scenario modelling** (starting from OOB-only baseline of 0.98, 24 OSDs):

| Custom Pools Added | Total Ratio | OOB Effective | OOB Ideal PGs | Ratio to Current (256) | Action? |
|-------------------|-------------|---------------|---------------|----------------------|---------|
| 0 (OOB only) | 0.98 | 0.500 | 800 | 3.12 | Scale up to 512 |
| +1 pool (0.1) | 1.08 | 0.454 | 726 | 2.84 | No change |
| +5 pools (0.5) | 1.48 | 0.331 | 530 | 2.07 | No change |
| +10 pools (1.0) | 1.98 | 0.247 | 396 | 1.55 | No change |
| +30 pools (3.0) | 3.98 | 0.123 | 197 | 0.77 | No change |
| +80 pools (8.0) | 8.98 | 0.055 | 87 | 0.34 | **Scale down** |

Note the first row: with *only* OOB pools (total 0.98), the ideal is 800 and 800/256 = 3.12, which just crosses the threshold. This means a fresh ROKS cluster with no custom pools may see the OOB RBD pool scale up from 256 to 512 PGs over time. Adding even one custom pool at 0.1 (total 1.08) brings the ratio to 2.84, keeping the OOB pool stable at 256. This is benign in both cases — more PGs is better for performance.

### PG Instance Budget

Each PG instance consumes memory and CPU on the OSD that hosts it. The cluster has a hard limit of `mon_max_pg_per_osd` (1000) instances per OSD.

Example budget for a 24-OSD cluster with OOB pools + one custom pool:

| Pool | PGs | Size | PG Instances |
|------|-----|------|-------------|
| cephblockpool (OOB RBD) | 256 | 3 | 768 |
| cephfilesystem-data0 (OOB CephFS) | 512 | 3 | 1,536 |
| cephfilesystem-metadata | 16 | 3 | 48 |
| my-custom-pool | 64 | 2 | 128 |
| .nfs | 32 | 3 | 96 |
| .mgr | 32 | 3 | 96 |
| **Total** | | | **2,672** |

2,672 / 24 OSDs = **111 PG instances per OSD**. Target is 200, ceiling is 1,000. Substantial headroom for additional pools.

### What Happens When Custom Pools Are Deleted

When custom pools are removed, their target ratios leave the sum. The OOB pools' effective ratios increase and their ideal PG counts rise.

For example, deleting a custom pool with ratio 0.1:

```
Before: total_ratios = 1.08, OOB effective = 0.454, OOB ideal = 726
After:  total_ratios = 0.98, OOB effective = 0.500, OOB ideal = 800
```

800 / 256 = 3.12 — this just crosses the 3.0 threshold, so the autoscaler would scale the OOB RBD pool up to 512 PGs. This is benign (more PGs = better I/O distribution), but triggers data rebalancing.

### Scale-Down Behaviour

Even when the threshold is crossed downward, PG reduction is conservative:

1. The autoscaler evaluates every ~60 seconds
2. PG merging requires all PGs to be `active+clean` — any degraded PG blocks the merge
3. PG count halves per step (256 → 128 → 64), not jumped directly to target
4. Each halving step waits for rebalancing to complete before proceeding

In practice, PG reduction is rare on production clusters. The autoscaler is far more aggressive about increasing PGs than decreasing them.

### The `noautoscale` Escape Hatch

If you need to freeze PG counts (e.g., during a performance test where PG rebalancing would skew results):

```bash
# Freeze a specific pool
ceph osd pool set my-custom-pool pg_autoscale_mode off

# Freeze cluster-wide
ceph osd pool set noautoscale

# Re-enable
ceph osd pool set my-custom-pool pg_autoscale_mode on
```

---

## Common Pitfalls

### PG autoscaler shows convergence at 1 PG

The convergence check verifies `pg_num == new_pg_num` — that the autoscaler has *finished* adjusting. But if the autoscaler *decided* 1 PG is correct (no `targetSizeRatio`, no data), convergence completes instantly at 1 PG. Always check the actual PG count, not just convergence status.

### `requireSafeReplicaSize: true` with insufficient hosts

With `requireSafeReplicaSize: true` (recommended), Ceph refuses to write if the pool cannot achieve the requested replication factor. A rep3 pool on a 2-node cluster will never reach `Ready`. Always check host count first (see [Step 1](#step-1-check-your-cluster)).

### Rep2 I/O blocks on single OSD failure

With `requireSafeReplicaSize: true`, a rep2 pool has `min_size=2` — meaning I/O blocks whenever one of the two OSDs hosting a PG is unavailable. This can happen during OSD restarts, node maintenance, or hardware failures. The PG goes `peered` (data is safe but not serving I/O) rather than `active+degraded` (still serving I/O).

This is a key availability tradeoff: rep2 saves storage (2x vs 3x overhead) and has better write IOPS (2 acks vs 3), but any single OSD outage causes I/O stalls for affected PGs. Rep3 tolerates one OSD down because 2 remaining copies still meet `min_size=2`. See [requireSafeReplicaSize and min_size](#requiresafereplicasize-and-min_size--availability-vs-durability) for the full explanation.

### Pool created but StorageClass missing

Creating the CephBlockPool does not automatically create a StorageClass. You must create both. If the pool is `Ready` but there's no SC, PVCs referencing it will stay `Pending` with no useful error message.

### StorageClass parameters are immutable

If you made a mistake in the StorageClass (wrong `imageFeatures`, wrong pool name, etc.), you cannot edit it. You must delete and recreate:

```bash
oc delete sc my-custom-sc
# Fix the YAML and re-apply
oc apply -f my-custom-sc.yaml
```

Existing PVCs are unaffected — parameters were baked in at provisioning time.

### Changing CephBlockPool spec fields

Most CephBlockPool spec fields (including `replicated.size`, `failureDomain`, `deviceClass`) can be updated by editing the CR. However, some changes (like `failureDomain` from `host` to `rack`) trigger a CRUSH rule rebuild and PG remapping, which causes data migration. Plan for this during maintenance windows.

`targetSizeRatio` can be changed at any time — the autoscaler adjusts on the next evaluation cycle (within ~60 seconds).

---

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

- [Failure Domains and Topology](../concepts/failure-domains-and-topology.md) — CRUSH hierarchy, ROKS racks, failureDomain options, node placement
- [Ceph and ODF](../concepts/ceph-and-odf.md) — Pool architecture, CRUSH, RBD fundamentals
- [Erasure Coding Explained](../concepts/erasure-coding-explained.md) — EC pools in depth
- [Customization](customization.md) — Adding pools to the test suite
- [Configuration Reference](configuration-reference.md) — All `00-config.sh` parameters
