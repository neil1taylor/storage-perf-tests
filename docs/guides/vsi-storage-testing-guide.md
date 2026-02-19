# VSI Storage Performance Testing Reference Guide

[Back to Documentation Index](../index.md)

This guide covers the hardware constraints, storage tier specifications, and sizing considerations specific to running storage performance benchmarks on **VSI-based** (Virtual Server Instance) ROKS clusters. On bare metal, ODF sits on local NVMe with dedicated I/O bandwidth. On VSI, all storage is network-attached via IBM Cloud Block volumes, and every I/O operation traverses the VPC network — introducing bandwidth ceilings, IOPS tiers, and replication multipliers that don't exist on bare metal.

Understanding these layers is essential for interpreting benchmark results and for sizing the cluster correctly so that you measure storage performance rather than infrastructure bottlenecks.

## VSI Worker Node Bandwidth

The single most important constraint on VSI storage performance is the worker node's total network bandwidth. Unlike bare metal nodes where storage I/O uses dedicated NVMe buses, VSI instances share a single network pipe for **both** pod-to-pod network traffic and all storage I/O (IBM Cloud Block volumes, IBM Cloud File shares, and ODF Ceph traffic).

### Bandwidth Profiles

#### bx2 (2nd generation Intel)

| Profile | vCPU | Memory (GiB) | Total Bandwidth (Gbps) |
|---------|------|--------------|------------------------|
| bx2-2x8 | 2 | 8 | 4 |
| bx2-4x16 | 4 | 16 | 8 |
| bx2-8x32 | 8 | 32 | 16 |
| bx2-16x64 | 16 | 64 | 32 |
| bx2-32x128 | 32 | 128 | 64 |
| bx2-48x192 | 48 | 192 | 80 |

#### bx3d (3rd generation Intel, dedicated host capable)

| Profile | vCPU | Memory (GiB) | Total Bandwidth (Gbps) |
|---------|------|--------------|------------------------|
| bx3d-2x10 | 2 | 10 | 4 |
| bx3d-4x20 | 4 | 20 | 8 |
| bx3d-8x40 | 8 | 40 | 16 |
| bx3d-16x80 | 16 | 80 | 32 |
| bx3d-24x120 | 24 | 120 | 48 |
| bx3d-32x160 | 32 | 160 | 64 |
| bx3d-48x240 | 48 | 240 | 96 |
| bx3d-64x320 | 64 | 320 | 128 |

### Bandwidth Allocation: Network vs Storage

By default, total bandwidth is split approximately **75% network / 25% storage**, with a minimum of **500 Mbps for each**. This split can be adjusted after provisioning via the IBM Cloud API or console, but both network and storage must maintain at least 500 Mbps.

**Example for bx2-32x128 (64 Gbps total):**

| Allocation | Network | Storage |
|------------|---------|---------|
| Default (75/25) | 48 Gbps | 16 Gbps |
| Adjusted (50/50) | 32 Gbps | 32 Gbps |
| Minimum storage | 63.5 Gbps | 0.5 Gbps |
| Minimum network | 0.5 Gbps | 63.5 Gbps |

For storage performance testing, consider adjusting the split toward storage. However, be aware of which backends use which allocation:
- **Storage allocation (25%):** IBM Cloud Block volumes — both direct Block CSI PVCs and ODF OSD backing volumes (iSCSI/NVMe-oF attach)
- **Network allocation (75%):** ODF Ceph replication traffic between OSDs, and **all NFS traffic** from IBM Cloud File CSI

Reducing network bandwidth below what Ceph needs for replication or what NFS needs for File CSI tests is counterproductive.

### The ODF Replication Bandwidth Multiplier

ODF with Ceph RBD multiplies the network impact of every write because replication traffic crosses the VPC network:

- **rep2 (2 replicas):** Each write generates 2x network traffic — the client write to the primary OSD, plus the primary OSD replicating to one secondary OSD.
- **rep3 (3 replicas):** Each write generates 3x network traffic — the client write plus replication to two secondary OSDs.
- **EC (erasure coding):** Each write generates (k+m)/k network traffic — less overhead than rep3 for the same fault tolerance.

This means that with rep3, the effective write throughput is roughly **one-third** of the raw storage bandwidth. On a bx2-32x128 with 16 Gbps storage bandwidth (~2 GB/s), the theoretical maximum sustained sequential write throughput through ODF rep3 is approximately **670 MB/s** — before accounting for Ceph protocol overhead, CPU scheduling, and the fact that reads from other VMs also consume bandwidth.

For reads, ODF typically serves from the primary OSD only (no replication multiplier), so read throughput is closer to the raw storage bandwidth. However, if Ceph recovery/rebalancing is in progress, background traffic competes with read I/O.

## IBM Cloud Block Storage IOPS Tiers

IBM Cloud Block Storage for VPC is the backing store for both ODF OSDs on VSI clusters and for direct Block CSI PVCs. Understanding the tier specifications is critical because they determine the IOPS ceiling for every storage path.

### Tiered Profiles

| Profile | IOPS/GiB | Max IOPS | Max Throughput | Volume Size Range | Throughput Multiplier |
|---------|----------|----------|----------------|-------------------|-----------------------|
| general-purpose (3 IOPS) | 3 | 48,000 | 670 MBps | 10–16,000 GiB | 16 KiB |
| 5iops-tier | 5 | 48,000 | 768 MBps | 10–9,600 GiB | 16 KiB |
| 10iops-tier | 10 | 48,000 | 1,024 MBps | 10–4,800 GiB | 256 KiB |
| custom | user-defined | 48,000 | 1,024 MBps | 10–16,000 GiB | 256 KiB |
| sdp (2nd gen) | user-defined | 64,000 | 1,024 MBps | 1–32,000 GiB | — |

The **throughput multiplier** is the I/O size at which throughput is calculated from IOPS. For example, on the 10iops-tier, a 512 GiB volume provides 5,120 IOPS × 256 KiB = 1,280 MBps — but capped at the 1,024 MBps maximum. On the general-purpose tier, 5,120 IOPS × 16 KiB = only 80 MBps for the same volume.

### PVC Size and IOPS Relationship

IOPS scales linearly with volume size up to the tier maximum:

- A **10 GiB** PVC on `5iops-tier` = 10 × 5 = 50 calculated IOPS
- A **100 GiB** PVC on `5iops-tier` = 100 × 5 = 500 calculated IOPS
- A **500 GiB** PVC on `10iops-tier` = 500 × 10 = 5,000 IOPS
- A **4,800 GiB** PVC on `10iops-tier` = 4,800 × 10 = 48,000 IOPS (max)

> **Minimum IOPS floor:** For tiered profiles (general-purpose, 5iops, 10iops), IBM Cloud enforces a minimum IOPS of **3,000** regardless of the calculated value from volume size. This means even a 10 GiB volume on the 5iops-tier gets 3,000 IOPS, not 50. **Note:** This 3,000 IOPS floor is based on IBM Cloud documentation — verify on your actual cluster, as behavior may vary by region or account type.

### Custom IOPS Ranges by Volume Size

For the `custom` profile, available IOPS ranges depend on volume size:

| Volume Size (GiB) | IOPS Range |
|--------------------|-----------|
| 10–39 | 100–1,000 |
| 40–79 | 100–2,000 |
| 80–99 | 100–4,000 |
| 100–499 | 100–6,000 |
| 500–999 | 100–10,000 |
| 1,000–1,999 | 100–20,000 |
| 2,000–3,999 | 200–40,000 |
| 4,000–7,999 | 300–40,000 |
| 8,000–9,999 | 500–48,000 |
| 10,000–16,000 | 1,000–48,000 |

### Implications for Benchmarking

When testing Block CSI directly (bypassing ODF), PVC size directly determines IOPS:
- A **50 GiB** PVC on `10iops-tier` = 500 IOPS (or 3,000 with the minimum floor) — this may bottleneck fio before the storage backend is saturated.
- A **500 GiB** PVC on `10iops-tier` = 5,000 IOPS — reasonable for benchmarking.
- A **2,000 GiB** PVC on `10iops-tier` = 20,000 IOPS — approaches the tier's useful range.

For ODF pools, the PVC size presented to the VM matters less because IOPS comes from the aggregate capacity of the OSD backing volumes (see [ODF Add-on Deployment Parameters](#odf-add-on-deployment-parameters-roks) below), not from the individual Ceph RBD volume.

## ODF Add-on Deployment Parameters (ROKS)

When deploying ODF on a VSI-based ROKS cluster, three OSD configuration parameters and one resource profile determine the performance envelope of the entire Ceph cluster.

### `osdStorageClassName`

**Default:** `ibmc-vpc-block-metro-10iops-tier`

The IBM Cloud Block CSI StorageClass used to provision the backing volumes for Ceph OSDs. This is the most impactful setting for ODF performance on VSI because it determines the IOPS tier of every OSD disk.

| Cluster Type | Recommended Value | Notes |
|-------------|-------------------|-------|
| Bare metal | `localblock` | Uses local NVMe directly — no network overhead |
| VSI | `ibmc-vpc-block-metro-10iops-tier` | Highest tiered IOPS per GiB |
| VSI (budget) | `ibmc-vpc-block-metro-5iops-tier` | Lower cost, 50% less IOPS per GiB |

The `-metro-` variants use `WaitForFirstConsumer` volume binding mode, which is required for multi-zone clusters and recommended even for single-zone. The non-metro variants use `Immediate` binding.

### `osdSize`

**Default:** `512Gi`

The size of each OSD backing volume. Minimum 250 GiB for production; 512 GiB recommended.

Since IOPS scales with volume size on tiered profiles, larger OSDs provide more IOPS per OSD:

| osdSize | 10iops-tier IOPS/OSD | 5iops-tier IOPS/OSD | general-purpose IOPS/OSD |
|---------|---------------------|---------------------|-------------------------|
| 250 GiB | 2,500 (or 3,000 floor) | 1,250 (or 3,000 floor) | 750 (or 3,000 floor) |
| 512 GiB | 5,120 | 2,560 (or 3,000 floor) | 1,536 (or 3,000 floor) |
| 1 TiB | 10,240 | 5,120 | 3,072 |
| 2 TiB | 20,480 | 10,240 | 6,144 |
| 4 TiB | 40,960 | 20,480 | 12,288 |

For performance testing, **1 TiB or larger** is recommended on the 10iops-tier to get 10,000+ IOPS per OSD.

### `numOfOsd`

**Default:** `1`

The number of OSD disks per worker node. More OSDs increase aggregate IOPS and throughput but consume more storage bandwidth per node and more IBM Cloud Block volume capacity.

| numOfOsd | OSDs Total (3 workers) | Aggregate IOPS (10iops, 1Ti each) | Aggregate Capacity (before replication) |
|----------|----------------------|-----------------------------------|-----------------------------------------|
| 1 | 3 | 30,720 | 3 TiB |
| 2 | 6 | 61,440 | 6 TiB |
| 3 | 9 | 92,160 | 9 TiB |

Usable capacity after replication: divide by the replication factor (3 for rep3, 2 for rep2). With rep3 and numOfOsd=1 at 1 TiB each, usable capacity is 1 TiB.

### Scaling ODF on VSI: More OSDs per Node vs More Nodes

When you need more aggregate IOPS or throughput from ODF, there are two scaling axes: increase `numOfOsd` (more OSD volumes per existing worker) or add more worker nodes. Each approach has different cost, bandwidth, and failure-domain implications.

#### More OSDs per node (increase `numOfOsd`)

Each additional OSD is a separate IBM Cloud Block volume with its own IOPS budget from the tier. Two 1 TiB OSDs on the 10iops-tier give 20,480 IOPS per node — double the single-OSD case. However, **all OSDs on a node share the same storage bandwidth allocation**. On a `bx2-32x128` with 16 Gbps (2 GB/s) storage bandwidth:

| numOfOsd | IOPS/Node | Bandwidth/OSD | Sequential Throughput/OSD |
|----------|-----------|---------------|--------------------------|
| 1 | 10,240 | 16 Gbps (2 GB/s) | Up to 1,024 MBps (tier cap) |
| 2 | 20,480 | 8 Gbps (1 GB/s) each | Up to ~1,000 MBps each, but 2 GB/s shared |
| 3 | 30,720 | ~5.3 Gbps (~670 MB/s) each | Bandwidth-constrained before IOPS ceiling |

For **random I/O workloads** (small block sizes, high iodepth), IOPS is the bottleneck and adding OSDs per node scales well — each OSD has its own IOPS budget and small I/Os don't saturate the node bandwidth.

For **sequential throughput workloads** (large block sizes), node bandwidth becomes the ceiling. Adding a second OSD provides more IOPS on paper, but the two OSDs compete for the same 16 Gbps pipe. You hit the node bandwidth wall before using the additional IOPS headroom.

**Pros:** Cheap (just an additional Block volume, not a full VSI), no additional node overhead, simple add-on parameter change.
**Cons:** Shared bandwidth ceiling, no additional failure domains, more OSD CPU/memory overhead on the same node.

#### More nodes (add worker nodes to the cluster)

Each additional worker brings its own independent bandwidth allocation, CPU, memory, and failure domain. Adding a 4th `bx2-32x128` node gives an additional 16 Gbps of storage bandwidth and 10,240 IOPS (with 1 TiB OSD on 10iops-tier):

| Workers | Total OSDs | Aggregate IOPS | Aggregate Storage BW | Aggregate Capacity (raw) |
|---------|-----------|----------------|---------------------|-------------------------|
| 3 | 3 | 30,720 | 48 Gbps (6 GB/s) | 3 TiB |
| 4 | 4 | 40,960 | 64 Gbps (8 GB/s) | 4 TiB |
| 6 | 6 | 61,440 | 96 Gbps (12 GB/s) | 6 TiB |

Both IOPS and bandwidth scale linearly with node count. More nodes also enable EC pools with higher k+m values (e.g., ec-4-2 requires 6 failure domains).

**Pros:** Linear scaling of both IOPS and bandwidth, additional failure domains, more CPU/memory for test VMs, enables larger EC pool configurations.
**Cons:** Significantly more expensive (full VSI instance cost per node), additional ODF daemon overhead per node, longer cluster provisioning time.

#### Decision Guide

| Workload | Recommendation | Why |
|----------|---------------|-----|
| Random 4K–16K IOPS (databases, OLTP) | More OSDs per node first | IOPS scales with OSD count; small I/Os don't saturate node bandwidth |
| Sequential throughput (streaming, backup) | More nodes | Node bandwidth is the ceiling; more OSDs don't help once the pipe is full |
| Mixed workloads (realistic benchmarks) | Balance both | Start with `numOfOsd=2`, add nodes if bandwidth-constrained |
| High concurrency (10+ VMs) | More nodes | Need CPU/memory headroom for VMs, not just storage bandwidth |
| EC pools (ec-2-2, ec-4-2) | More nodes (required) | EC requires k+m unique failure domains (host-level) |

**Practical example:** On 3× `bx2-32x128` with `numOfOsd=1` and 1 TiB OSDs on 10iops-tier, you have 30,720 aggregate IOPS and 48 Gbps total storage bandwidth. If your random I/O benchmarks show headroom (IOPS below 30K), increasing to `numOfOsd=2` doubles IOPS to 61,440 for the cost of 3 additional Block volumes (~$0.10/GiB/month). If your sequential benchmarks are hitting the 16 Gbps per-node ceiling, adding a 4th worker is the only way to increase throughput — more OSDs on the same node won't help.

### `resourceProfile`

**Default:** `balanced` (on ROKS), **recommended for perf testing:** `performance`

The ODF/Rook operator resource allocation profile controls CPU and memory reserved for Ceph daemons (OSDs, MONs, MGR, MDS, RGW):

| Profile | Total CPU (cluster) | Total Memory (cluster) | Per Node (3 workers) | Use Case |
|---------|--------------------|-----------------------|---------------------|----------|
| **lean** | 24 | 72 GiB | ~8 CPU, ~24 GiB | Resource-constrained environments; **not suitable for perf testing** |
| **balanced** | 30 | 72 GiB | ~10 CPU, ~24 GiB | General-purpose workloads; ROKS default |
| **performance** | 45 | 96 GiB | ~15 CPU, ~32 GiB | Performance testing and production with ample resources |

Source: [Red Hat ODF Planning Guide, Table 7.7](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.17/html/planning_your_deployment/infrastructure-requirements_rhodf)

**Scaling with OSD count:** The table above shows the **base resource requirements** from Red Hat's ODF Planning Guide (Table 7.7). Actual requirements scale with the number of OSD daemons on your cluster. The ODF "Configure Performance" screen in the OpenShift web console computes and displays the real values for your specific cluster configuration.

On bare metal clusters with multiple NVMe drives per node, the computed requirements are significantly higher than the baseline because each NVMe drive runs its own OSD daemon. For example, on a 3-node bare metal cluster with 8 NVMe drives per node (24 OSDs total, 96 CPUs per node):

| Profile | Table 7.7 baseline | BM cluster (24 OSDs) |
|---------|-------------------|----------------------|
| **lean** | 24 CPU, 72 GiB | 51 CPU, 126 GiB |
| **balanced** | 30 CPU, 72 GiB | 66 CPU, 162 GiB |
| **performance** | 45 CPU, 96 GiB | 117 CPU, 240 GiB |

On VSI clusters with `numOfOsd=1` (3 OSDs total), the values are close to the Table 7.7 baseline. With `numOfOsd=2` (6 OSDs), they increase modestly.

**Worker node sizing implication:** With the Performance profile, each of the 3 workers needs approximately 15 CPU and 32 GiB just for ODF daemons, before any VMs or system overhead. A `bx2-16x64` is marginal (the CPU doesn't fit); `bx2-32x128` or `bx3d-24x120` provides real headroom for concurrent test VMs. On bare metal clusters, performance mode can consume 39+ CPUs per node — ensure your workers have sufficient capacity.

### Other Notable Add-on Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `billingType` | `essentials` | `essentials` or `advanced`; advanced enables all ODF features |
| `clusterEncryption` | `false` | Encrypts OSD volumes at rest with dm-crypt (see [Encrypted Storage Setup](encrypted-storage-setup.md)) |
| `encryptionInTransit` | `false` | In-flight encryption between Ceph daemons; adds CPU overhead |
| `workerNodes` | (empty) | Comma-separated node names to target for ODF; optional, defaults to all workers |

## The Three Storage Backends on VSI

VSI clusters can test up to three distinct storage backends, each with a different I/O path and performance profile.

### ODF (Ceph RBD)

```
fio → VM virtio disk → virt-launcher pod → RBD CSI driver → Ceph client library
  → VPC network → primary OSD (IBM Cloud Block volume)
  → VPC network → replica OSD(s) (IBM Cloud Block volumes)
```

**Network hops:** 2–3 (client→primary, primary→replica(s))
**IOPS determined by:** `osdStorageClassName` tier × `osdSize` × `numOfOsd` (aggregate across OSDs)
**Throughput limited by:** Node storage bandwidth ÷ replication factor
**Latency:** Highest of the three backends — Ceph protocol overhead plus double/triple network traversal

### IBM Cloud Block CSI (Direct)

```
fio → VM virtio disk → virt-launcher pod → VPC Block CSI driver
  → IBM Cloud Block volume (direct iSCSI/NVMe-oF attach)
```

**Network hops:** 1 (pod→volume)
**IOPS determined by:** StorageClass tier × PVC size (subject to 3,000 minimum floor)
**Throughput limited by:** Node storage bandwidth (no replication multiplier)
**Latency:** Lowest on VSI — bypasses Ceph entirely

This is the best-case latency and throughput baseline on VSI. Comparing Block CSI results against ODF results on the same cluster isolates the overhead introduced by Ceph.

### IBM Cloud File CSI (NFS)

```
fio → VM virtio disk → QEMU (file I/O on disk.img)
  → virt-launcher pod mount namespace → kubelet NFS mount on node
  → NFS client (kernel) → VPC network → IBM Cloud File service (managed NFS)
```

Unlike the block-mode I/O paths above, File CSI PVCs use `volumeMode: Filesystem`. This introduces a **file-on-filesystem indirection** layer that block-mode PVCs don't have:

1. **NFS mount chain:** The CSI node plugin mounts the IBM Cloud NFS share onto the node's filesystem. CRI-O then bind-mounts that same mount point into the virt-launcher pod's namespace. There is **one NFS mount** on the node — the pod doesn't create a second independent mount.
2. **disk.img indirection:** Inside the NFS-mounted directory, KubeVirt stores the VM's virtual disk as a raw `disk.img` file. QEMU opens this file and presents it to the guest as a virtio block device. Every guest I/O traverses: QEMU (translates guest block offset to file offset in `disk.img`) → host VFS/NFS client → VPC network → IBM Cloud File service.
3. **No intermediate filesystem on block paths:** With ODF (Ceph RBD) and Block CSI, the PVC is a raw block device passed directly to QEMU — no `disk.img` file, no NFS, no host filesystem layer.

This extra indirection is one reason NFS-backed VMs tend to show higher latency than block-backed VMs, even at the same IOPS tier. See [How Storage Reaches the VM](../concepts/openshift-virtualization.md#how-storage-reaches-the-vm) for a detailed explanation of both paths.

**Network hops:** 1 (pod→NFS server)
**IOPS determined by:** StorageClass IOPS tier (500, 1,000, or 3,000 IOPS), independent of PVC size. Single-client cap is 48,000 IOPS regardless of provisioned IOPS.
**Throughput formula:** IOPS × 256 KB, capped at 8,192 Mbps (1,024 MB/s). A 3,000-IOPS share maxes out at 768 MB/s theoretical — but only achievable with I/O sizes ≥256 KB and sufficient parallelism (see NFS transfer limit below).
**Latency:** Moderate — NFS protocol + file-on-filesystem indirection add overhead vs block protocols

**Bandwidth path (VSI):** NFS traffic uses the worker node's **network bandwidth allocation (75% default)**, not the storage bandwidth allocation (25%) that VPC Block volumes use. This means File CSI I/O competes with pod networking and ODF Ceph replication traffic, but does not compete with IBM Cloud Block CSI I/O. On a `bx2-32x128` with the default 75/25 split, File CSI shares the 48 Gbps network slice while Block CSI and ODF OSD volumes use the 16 Gbps storage slice.

**64 KB per-session NFS I/O transfer limit:** Each NFS RPC can transfer at most 64 KB of data. Even with fio `bs=1M`, each I/O operation is broken into multiple NFS RPCs (1 MB ÷ 64 KB = 16 RPCs per fio I/O). This makes `numjobs` and `iodepth` critical for NFS throughput — a single sequential fio job cannot saturate the IOPS budget because it is limited by the round-trip time of sequential 64 KB RPCs. Multiple concurrent sessions (jobs) are needed to achieve the share's throughput cap.

**NFS version and mount options:** The IBM Cloud File CSI driver uses **NFSv4.1** with default mount options `hard,nfsvers=4.1,sec=sys`. No `rsize`/`wsize`/`nconnect` options are configured by default. The `nconnect` mount option (multiple TCP connections per NFS mount) could potentially improve throughput by parallelizing RPCs, but IBM does not document or support this configuration.

**`direct=1` (O_DIRECT) on NFS:** The Linux NFS client supports O_DIRECT on NFSv4.1 — fio's `direct=1` flag bypasses the **client-side** NFS page cache, so fio is measuring NFS transport + server-side performance, not cached I/O. However, O_DIRECT on NFS is not equivalent to O_DIRECT on a local block device: the I/O still traverses the NFS protocol layer, and server-side caching behavior is controlled by IBM's infrastructure and is not documented.

**Encryption in transit (EIT):** The `ibmc-vpc-file-eit` StorageClass enables IPsec encryption of NFS traffic. However, **EIT is not supported on RHCOS worker nodes** — since ROKS uses RHCOS, EIT StorageClasses will fail to mount. The test suite's auto-discovery filters these out.

**Account quota:** 300 file shares per account across all VPCs. Each File CSI PVC creates one share.

## Minimum Sizing for Realistic Benchmarks

### Worker Node Headroom Analysis

The following analysis assumes a 3-node cluster with the ODF **Performance** resource profile (~15 CPU, ~32 GiB per node) and an estimated OS/platform overhead of ~2 CPU, ~4 GiB per node (kubelet, CRI-O, OVN, monitoring agents).

| Worker Profile | vCPU | Mem (GiB) | BW (Gbps) | Storage BW (25%) | After ODF + OS | Max Test VMs/Node | Verdict |
|----------------|------|-----------|-----------|-------------------|----------------|-------------------|---------|
| bx2-8x32 | 8 | 32 | 16 | 4 Gbps | -9 CPU, -4 GiB | 0 | Cannot run ODF Performance profile |
| bx2-16x64 | 16 | 64 | 32 | 8 Gbps | -1 CPU, 28 GiB | 0 | Marginal — ODF barely fits, no room for VMs |
| bx3d-16x80 | 16 | 80 | 32 | 8 Gbps | -1 CPU, 44 GiB | 0 | Same CPU limitation, extra memory unused |
| **bx2-32x128** | **32** | **128** | **64** | **16 Gbps** | **15 CPU, 92 GiB** | **3** | **Recommended minimum** |
| bx3d-24x120 | 24 | 120 | 48 | 12 Gbps | 7 CPU, 84 GiB | 1 | Tight but viable for low concurrency |
| **bx3d-32x160** | **32** | **160** | **64** | **16 Gbps** | **15 CPU, 124 GiB** | **3** | **Recommended — extra memory headroom** |
| bx2-48x192 | 48 | 192 | 80 | 20 Gbps | 31 CPU, 156 GiB | 7 | High concurrency testing |
| bx3d-48x240 | 48 | 240 | 96 | 24 Gbps | 31 CPU, 204 GiB | 7 | Best for concurrency=10 tests |
| bx3d-64x320 | 64 | 320 | 128 | 32 Gbps | 47 CPU, 284 GiB | 11 | Maximum headroom |

**Notes:**
- "After ODF + OS" = total node resources minus ODF Performance profile (~15 CPU, ~32 GiB) minus OS overhead (~2 CPU, ~4 GiB).
- "Max Test VMs/Node" assumes medium VMs (4 vCPU, 8 GiB each), limited by whichever of CPU or memory runs out first.
- Storage bandwidth is the real constraint for sequential throughput workloads: 8 Gbps ≈ 1 GB/s theoretical max, minus ODF replication overhead.
- With the ODF **Balanced** profile (10 CPU, 24 GiB per node), `bx2-16x64` becomes viable for running VMs but remains bandwidth-constrained at 8 Gbps storage.

### Recommendations by Use Case

**Standard test matrix (concurrency up to 5):**
- Worker profile: `bx2-32x128` or `bx3d-32x160`
- ODF: `osdStorageClassName=ibmc-vpc-block-metro-10iops-tier`, `osdSize=1Ti`, `numOfOsd=1`, `resourceProfile=performance`
- Provides 15 CPU / 92+ GiB headroom per node for test VMs

**High concurrency testing (concurrency=10):**
- Worker profile: `bx2-48x192` or `bx3d-48x240`
- ODF: Same as above, consider `numOfOsd=2` for more aggregate IOPS
- Provides 31 CPU / 156+ GiB headroom per node

### Guest VM (fio Runner) Sizing

| VM Size | vCPU | Memory | Suitable For |
|---------|------|--------|-------------|
| small (2 vCPU, 4 GiB) | 2 | 4 GiB | Useful for showing CPU-bound effects, not a pure storage measurement |
| **medium (4 vCPU, 8 GiB)** | 4 | 8 GiB | **Recommended** — matches fio `numjobs=4, iodepth=32` |
| large (8 vCPU, 16 GiB) | 8 | 16 GiB | High-parallelism fio workloads (numjobs=8+) |

Memory requirements are modest because `direct=1` bypasses the OS page cache. 4–8 GiB is adequate for all standard fio profiles.

### PVC Sizing by Backend

| Backend | Recommended PVC Size | Why |
|---------|---------------------|-----|
| **ODF (Ceph RBD)** | 50 GiB+ (size matters less) | IOPS comes from the OSD backing volumes, not the individual RBD volume |
| **Block CSI (direct)** | 500 GiB+ for tiered profiles | PVC size × IOPS/GiB = volume IOPS; small PVCs hit the IOPS floor and don't test the tier's ceiling |
| **File CSI (NFS)** | Any size | IOPS is set by the SC tier (500/1,000/3,000 IOPS), independent of PVC size |

### ODF Deployment for Performance Testing

Recommended settings for the ODF add-on when the goal is to benchmark storage performance:

```
osdStorageClassName: ibmc-vpc-block-metro-10iops-tier   # Highest tiered IOPS
osdSize: 1Ti                                            # 10,240 IOPS per OSD at 10 IOPS/GiB
numOfOsd: 1                                             # Minimum; use 2 for throughput-heavy workloads
resourceProfile: performance                            # Full Ceph resource allocation
```

With these settings on a 3-worker cluster: 3 OSDs × 10,240 IOPS = 30,720 aggregate IOPS, 3 TiB raw capacity (1 TiB usable with rep3).

## Enterprise Deployment Recommendations

The sections above cover individual parameters and their tradeoffs. This section consolidates that into prescriptive configurations for enterprise clusters running ODF with OpenShift Virtualization on VSI.

### Recommended Configurations

| Tier | Workers | Profile | OSDs | OSD Size | Resource Profile | Aggregate IOPS | Storage BW | Pool Coverage |
|------|---------|---------|------|----------|-----------------|----------------|------------|---------------|
| **Standard** | 3 | `bx3d-32x160` | `numOfOsd=1` | 1 TiB | performance | 30,720 | 48 Gbps | rep2, rep3, ec-2-1, cephfs |
| **Full pool coverage** | 6 | `bx3d-32x160` | `numOfOsd=1` | 1 TiB | performance | 61,440 | 96 Gbps | All pools including ec-4-2 |
| **Maximum throughput** | 6 | `bx2-48x192` | `numOfOsd=2` | 2 TiB | performance | 245,760 | 120 Gbps | All pools, highest aggregate IOPS/BW |

**Standard** is sufficient for most production workloads and the full test matrix at concurrency ≤ 5. **Full pool coverage** adds the 3 extra workers needed for ec-2-2 (4 hosts) and ec-4-2 (6 hosts) while doubling aggregate performance. **Maximum throughput** uses 48-vCPU workers with 2 OSDs each for the highest per-node IOPS ceiling — suited for high-concurrency testing or large VM fleets.

### Worker Count and Pool Coverage

EC pools require k+m unique failure domains (`failureDomain: host`). The table below shows which pool configurations are available at each cluster size:

| Pool | Type | Min Workers | 3 Workers | 4 Workers | 6 Workers |
|------|------|-------------|-----------|-----------|-----------|
| rep2 | RBD replicated (2 replicas) | 2 | Yes | Yes | Yes |
| rep3 | RBD replicated (3 replicas) | 3 | Yes | Yes | Yes |
| ec-2-1 | RBD erasure-coded (k=2, m=1) | 3 | Yes | Yes | Yes |
| cephfs-rep2 | CephFS (2-replica data) | 2 | Yes | Yes | Yes |
| cephfs-rep3 | CephFS (3-replica data) | 3 | Yes | Yes | Yes |
| ec-3-1 | RBD erasure-coded (k=3, m=1) | 4 | No | Yes | Yes |
| ec-2-2 | RBD erasure-coded (k=2, m=2) | 4 | No | Yes | Yes |
| ec-4-2 | RBD erasure-coded (k=4, m=2) | 6 | No | No | Yes |

Pools that exceed the available failure domains are automatically skipped at runtime with a logged warning — no configuration changes are needed.

### ODF Add-on Settings

Recommended enterprise ODF configuration for the ROKS add-on:

```
osdStorageClassName: ibmc-vpc-block-metro-10iops-tier   # Highest tiered IOPS (10 IOPS/GiB)
osdSize: 1Ti                                            # 10,240 IOPS per OSD; use 2Ti for throughput-heavy workloads
numOfOsd: 1                                             # 1 OSD/node standard; 2 for higher IOPS (shared BW)
resourceProfile: performance                            # Full Ceph resource allocation (~15 CPU, ~32 GiB/node)
```

With `numOfOsd=1` and 1 TiB OSDs: each node contributes 10,240 IOPS and 16 Gbps storage bandwidth. Scaling to `numOfOsd=2` doubles IOPS per node but the two OSDs share the same node bandwidth — beneficial for random I/O, no gain for sequential throughput. See [Scaling ODF on VSI](#scaling-odf-on-vsi-more-osds-per-node-vs-more-nodes) for the full tradeoff analysis.

### Why bx3d over bx2

At 32 vCPU, `bx3d-32x160` and `bx2-32x128` have the same 64 Gbps network bandwidth and identical storage performance. The difference is memory: 160 GiB vs 128 GiB — a 25% increase that translates to 32 GiB more headroom per node for VMs after ODF overhead. On a 3-node cluster this means ~96 GiB additional cluster-wide memory for workloads at a marginal cost increase. For storage benchmarking the extra memory allows higher VM concurrency without hitting memory limits before CPU or bandwidth limits.

### Scaling Guidance

- **Need more random IOPS?** Increase `numOfOsd` first — cheaper than adding nodes and each OSD has its own IOPS budget from the block tier.
- **Need more sequential throughput?** Add worker nodes — each node brings independent bandwidth. More OSDs on the same node share the same pipe.
- **Need EC pool coverage?** Add nodes to meet the k+m failure domain requirement (see table above).
- **Need more VM capacity?** Add nodes for CPU/memory headroom, or move to 48-vCPU profiles for more resources per node.

For the full decision framework, see [Scaling ODF on VSI: More OSDs per Node vs More Nodes](#scaling-odf-on-vsi-more-osds-per-node-vs-more-nodes).

## IBM Cloud Block CSI StorageClasses Reference

ROKS clusters with the IBM Cloud Block CSI driver have approximately 33 StorageClasses. They follow a naming pattern with variants for binding mode, reclaim policy, and ODF usage:

### By IOPS Tier

**10 IOPS tier:**

| StorageClass | Binding Mode | Reclaim Policy | Purpose |
|-------------|-------------|---------------|---------|
| `ibmc-vpc-block-10iops-tier` | Immediate | Delete | Standard |
| `ibmc-vpc-block-retain-10iops-tier` | Immediate | Retain | Data preservation |
| `ibmc-vpc-block-metro-10iops-tier` | WaitForFirstConsumer | Delete | Multi-zone / recommended |
| `ibmc-vpc-block-metro-retain-10iops-tier` | WaitForFirstConsumer | Retain | Multi-zone + data preservation |
| `ibmc-vpcblock-odf-10iops` | WaitForFirstConsumer | Delete | ODF OSD backing volumes |
| `ibmc-vpcblock-odf-ret-10iops` | WaitForFirstConsumer | Retain | ODF OSD backing volumes (retain) |

**5 IOPS tier:** Same pattern with `5iops-tier` / `5iops` suffix.

**General-purpose (3 IOPS):** Same pattern with `general-purpose` suffix. This is the default tier.

**Custom:** Same pattern with `custom` suffix. Requires IOPS annotation on PVC.

**SDP (2nd generation):** `ibmc-vpc-block-sdp` and variants. User-defined IOPS with higher maximums.

### Deduplication for Performance Testing

Many of these StorageClasses are functionally identical for I/O performance:
- `-metro-` vs non-metro: Only differs in volume binding mode, not I/O behavior
- `-retain-` vs delete: Only differs in reclaim policy, not I/O behavior
- `-odf-` variants: Identical tier but tagged for ODF consumption

The test suite's `BLOCK_CSI_DEDUP=true` (default) filters out `-metro-` and `-retain-` variants, testing only the base SC per tier. Set `BLOCK_CSI_DEDUP=false` for multi-zone clusters where metro topology may affect latency.

## Summary: What Limits Performance on VSI

When interpreting benchmark results from VSI clusters, check these constraints in order:

### ODF and Block CSI

1. **Node storage bandwidth** — The 25% default allocation is often the ceiling for sequential throughput. Check `Total BW × 0.25` for your worker profile.
2. **IBM Cloud Block volume IOPS** — For Block CSI: `PVC size × IOPS/GiB` (with 3,000 minimum floor). For ODF: `osdSize × IOPS/GiB × numOfOsd × num_workers`.
3. **ODF replication overhead** — Write throughput is divided by the replication factor (3× for rep3). Read throughput is unaffected.
4. **ODF resource profile** — Lean/Balanced profiles may CPU-throttle Ceph daemons under heavy load.
5. **VM CPU** — At high iodepth with many numjobs, the guest VM CPU can saturate before storage does. Use 4+ vCPU.
6. **IBM Cloud Block volume throughput cap** — Even with sufficient IOPS, each tier has a throughput ceiling (670 MBps for general-purpose, 1,024 MBps for 10iops-tier).

### File CSI (NFS)

1. **StorageClass IOPS tier** — The per-share IOPS cap (500, 1,000, or 3,000) is the primary bottleneck. Unlike ODF, each PVC gets its own dedicated IOPS budget — no contention between VMs.
2. **64 KB NFS transfer limit** — Each NFS RPC transfers at most 64 KB. Large-block fio tests (bs=1M) require 16 RPCs per I/O. High `numjobs`/`iodepth` is essential to saturate the share.
3. **Throughput cap** — IOPS × 256 KB, max 8,192 Mbps. A 3,000-IOPS share tops out at 768 MB/s.
4. **Node network bandwidth** — NFS uses the network allocation (75% default), not the storage allocation. Competes with pod networking and ODF replication traffic.
5. **File-on-filesystem indirection** — QEMU → `disk.img` → NFS adds latency vs block-mode PVCs. See [How Storage Reaches the VM](../concepts/openshift-virtualization.md#how-storage-reaches-the-vm).

## References

- [IBM Cloud VSI Bandwidth Profiles](https://cloud.ibm.com/docs/vpc?topic=vpc-profiles)
- [IBM Cloud Bandwidth Allocation for VSI](https://cloud.ibm.com/docs/vpc?topic=vpc-bandwidth-allocation-profiles)
- [IBM Cloud Block Storage Profiles](https://cloud.ibm.com/docs/vpc?topic=vpc-block-storage-profiles)
- [IBM Cloud Block Storage Capacity and Performance](https://cloud.ibm.com/docs/vpc?topic=vpc-capacity-performance)
- [Deploying ODF on VPC Clusters (ROKS)](https://cloud.ibm.com/docs/openshift?topic=openshift-deploy-odf-vpc)
- [Red Hat ODF Planning Guide — Infrastructure Requirements](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.17/html/planning_your_deployment/infrastructure-requirements_rhodf)
- [IBM Cloud Block Storage SC Reference](https://github.com/ibm-cloud-docs/containers/blob/master/storage-block-vpc-sc-ref.md)
