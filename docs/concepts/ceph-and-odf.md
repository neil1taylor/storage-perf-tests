# Ceph and ODF

[Back to Index](../index.md)

This page explains the Ceph distributed storage system and how OpenShift Data Foundation (ODF) runs it on your cluster. Understanding Ceph architecture helps you interpret why different storage pools perform differently in benchmark results.

## What Is Ceph?

**Ceph** is an open-source distributed storage system that provides block, file, and object storage from a single unified cluster. It's designed for:

- **Scalability** — Scales from a few nodes to thousands
- **Self-healing** — Automatically recovers from hardware failures
- **No single point of failure** — Data is distributed across multiple nodes

Ceph is the storage engine behind ODF and is one of the most widely deployed software-defined storage systems in production.

## Ceph Architecture

### RADOS — The Foundation

**RADOS (Reliable Autonomic Distributed Object Store)** is Ceph's foundational layer. Everything in Ceph — block devices, filesystems, object storage — is ultimately stored as objects in RADOS.

```
┌─────────────────────────────────────────┐
│  Applications (VMs, Databases, etc.)    │
├──────────┬──────────┬───────────────────┤
│   RBD    │  CephFS  │   RADOS Gateway   │
│  (block) │  (file)  │   (object/S3)     │
├──────────┴──────────┴───────────────────┤
│              RADOS                      │
│     (distributed object storage)        │
├──────────┬──────────┬───────────────────┤
│   OSD    │   OSD    │    OSD   ...      │
│  (NVMe)  │  (NVMe)  │   (NVMe)          │
└──────────┴──────────┴───────────────────┘
```

### Key Ceph Daemons

| Daemon | Role |
|--------|------|
| **OSD (Object Storage Daemon)** | Stores data on a physical disk. Each NVMe drive on your bare metal workers runs one OSD. Handles replication, recovery, and rebalancing. |
| **MON (Monitor)** | Maintains the cluster map (which OSDs are alive, where data is). Requires a quorum (majority) of MONs to be healthy. Typically 3 MONs. |
| **MGR (Manager)** | Provides monitoring, dashboard, and metrics. Runs alongside MONs. |
| **MDS (Metadata Server)** | Only needed for CephFS (file storage). Not used for block storage in this project. |

### How Data Is Stored

When data is written to a Ceph RBD (block device):

1. Data is split into fixed-size objects (default 4MB)
2. Each object is mapped to a **Placement Group (PG)**
3. The PG is mapped to a set of OSDs using the **CRUSH** algorithm (Controlled Replication Under Scalable Hashing — Ceph's rule-based system for distributing data across disks while respecting failure domains like hosts and racks). See [Failure Domains and Topology](failure-domains-and-topology.md) for a deep dive on CRUSH and failure domains.
4. Data is written to the primary OSD, which replicates to secondary OSDs

The CRUSH algorithm ensures data is distributed evenly and can survive the failure of specific nodes or racks.

## Pools

A **pool** is a logical partition of RADOS storage. Each pool has its own:
- Data protection policy (replication factor or erasure coding profile)
- Placement group count
- CRUSH rules (which OSDs to use)

### Replicated Pools

A **replicated pool** stores N copies of every object:

```
           Write "Hello"
                │
                ▼
  ┌───────┐  ┌───────┐  ┌───────┐
  │ OSD.1 │  │ OSD.4 │  │ OSD.7 │
  │ Hello │  │ Hello │  │ Hello │
  │(copy1)│  │(copy2)│  │(copy3)│
  └───────┘  └───────┘  └───────┘
         replication size = 3
```

**Pros:**
- Simple and fast reads (read from any copy)
- Fast recovery (just copy from surviving replicas)
- Predictable latency

**Cons:**
- Storage overhead is high: rep3 uses 3x raw storage per byte of usable data

### Erasure-Coded Pools

See [Erasure Coding Explained](erasure-coding-explained.md) for a deep dive. In brief, EC splits data into k data chunks and m parity chunks, requiring only (k+m)/k times the raw storage instead of N times.

### Pools in This Project

| Pool Name | Type | Config | Raw Overhead | Fault Tolerance | Min Hosts |
|-----------|------|--------|-------------|-----------------|-----------|
| **rep3** | Replicated | size=3 | 3.0x | Survives 2 OSD failures | 3 |
| **rep2** | Replicated | size=2 | 2.0x | Survives 1 OSD failure | 2 |
| **ec-2-1** | Erasure Coded | k=2, m=1 | 1.5x | Survives 1 OSD failure | 3 |
| **ec-2-2** | Erasure Coded | k=2, m=2 | 2.0x | Survives 2 OSD failures | 4 |
| **ec-4-2** | Erasure Coded | k=4, m=2 | 1.5x | Survives 2 OSD failures | 6 |

### VMware vSAN Comparison

For teams migrating from VMware vSAN, these Ceph pool types map to familiar vSAN storage policies:

| Ceph Pool | vSAN Equivalent | Overhead | Fault Tolerance | Min Hosts (Ceph) | Min Hosts (vSAN) |
|-----------|----------------|----------|-----------------|-------------------|-------------------|
| **rep2** | RAID-1, FTT=1 | 2x | 1 failure | 2 | 3 (includes witness) |
| **rep3** | RAID-1, FTT=2 | 3x | 2 failures | 3 | 5 (2×FTT+1) |
| **ec-2-1** | RAID-5, FTT=1 | 1.5x | 1 failure | 3 | 4 (3+1) |
| **ec-3-1** | RAID-5, FTT=1 | 1.33x | 1 failure | 4 | 4 (3+1) |
| **ec-2-2** | RAID-6, FTT=2 | 2x | 2 failures | 4 | 6 (4+2) |
| **ec-4-2** | RAID-6, FTT=2 | 1.5x | 2 failures | 6 | 6 (4+2) |

Key differences:

- **Lower host minimums:** Ceph separates its cluster quorum (MON daemons) from data placement. A rep3 pool needs only 3 hosts because each host stores one full copy. vSAN RAID-1 FTT=2 needs 5 hosts because it embeds a witness requirement in the per-object placement formula (2×FTT+1).
- **rep2 is the closest match to standard vSAN RAID-1:** Most vSAN deployments use FTT=1 (RAID-1), which stores 2 copies. Ceph's rep2 is the direct equivalent — same 2x overhead, same single-failure tolerance.
- **EC performance tradeoffs are similar:** Both Ceph EC and vSAN RAID-5/6 show higher write latency than replication (parity computation + more I/Os per write), but competitive sequential read throughput. The benchmark results from this suite quantify the exact gap on ODF.
- **Capacity efficiency gains are identical:** EC-3-1 and vSAN RAID-5 FTT=1 both achieve 1.33x overhead — the most space-efficient option for single-failure tolerance. EC-2-1 achieves 1.5x overhead, still a 25% saving over rep2's 2x.

### vSAN Performance: RAID-1 vs Erasure Coding

Published vSAN benchmarks do not provide a clean apples-to-apples RAID-1 vs RAID-5 comparison with standardized fio workloads, which is one reason this test suite exists — to produce that data for ODF/Ceph. However, the qualitative trends from available sources are:

- **vSAN OSA (Original Storage Architecture):** RAID-1 significantly outperforms RAID-5/6, particularly for random writes. The parity computation and read-modify-write penalty on OSA is well documented. Community testing on 8-node clusters shows "marked difference" between RAID-1 and RAID-5/6 IOPS ([VMUG: vSAN Policies and Their Effects](https://www.vmug.com/vsan-policies-and-their-effects/)).
- **vSAN ESA (Express Storage Architecture, vSAN 8.0+):** VMware claims RAID-5/6 achieves near RAID-1 performance by eliminating the read-modify-write penalty through full-stripe writes and a single-tier NVMe architecture ([VMware Blog: RAID-5/6 with RAID-1 Performance on ESA](https://blogs.vmware.com/cloud-foundation/2022/09/02/raid-5-6-with-the-performance-of-raid-1-using-the-vsan-express-storage-architecture/)). A 2024 ESA benchmark on 6× Cisco UCS NVMe nodes achieved 721k IOPS at 32k random read with RAID-5, but no RAID-1 baseline was published for comparison ([VCDX200: vSAN ESA Performance Testing](http://vcdx200.uw.cz/2024/12/vmware-vsan-esa-storage-performance.html)).
- **Lenovo ThinkAgile paper:** Compared OSA (RAID-1, 3 disk groups, SAS SSD) vs ESA (RAID-5, 8× NVMe) on 4× VX650 V3 nodes with HCIBench. Found OSA outperformed ESA on 25 GbE, while ESA leveraged 100 GbE for up to 250% better throughput on mixed workloads — but the results conflate the RAID policy change with the hardware architecture change ([Lenovo Press: Scalable vSAN Architectures](https://lenovopress.lenovo.com/lp1872-scalable-vmware-vsan-storage-architectures-on-lenovo-thinkagile-vx)).
- **StorageReview HCIBench:** Tested vSAN OSA RAID-1 on 4× DL380 G9 (SAS SSD + HDD disk groups) achieving 227k IOPS 4k random read and 64k IOPS 4k random write, but only tested RAID-1 ([StorageReview: vSAN HCIBench Performance](https://www.storagereview.com/vmware_virtual_san_review_hcibench_synthetic_performance)).

The key takeaway for migration planning: vSAN customers moving from RAID-1 to ODF should compare against **rep2** (same protection model). Those considering erasure coding for capacity savings should compare vSAN RAID-5 FTT=1 against **ec-3-1** (exact equivalent: 3 data + 1 coding, 1.33x overhead, 4 hosts) or **ec-2-1** (same fault tolerance, fewer hosts but 1.5x overhead). The results from this suite provide the ODF side of that comparison with standardized fio workloads across multiple block sizes, concurrency levels, and VM configurations.

### Benchmark Methodology: HCIBench vs This Suite

VMware's [HCIBench](https://flings.vmware.com/hcibench) and this test suite use the same fundamental approach — running fio inside VMs to measure the full I/O path as experienced by workloads. Neither tests raw storage in isolation.

| Aspect | HCIBench (vSAN) | This Suite (ODF) |
|--------|-----------------|------------------|
| **I/O path** | fio → guest OS → pvscsi → ESXi → vSAN → disks | fio → guest OS → virtio → KubeVirt/qemu → Ceph RBD → disks |
| **VM platform** | ESXi worker VMs | KubeVirt VMs on OpenShift |
| **Storage under test** | VMDKs on vSAN datastore | PVCs on ODF StorageClasses |
| **Benchmark tool** | fio (or Vdbench) | fio |
| **Typical goal** | Saturate the cluster (many VMs × many disks) to find aggregate maximums | Measure per-pool performance at realistic concurrency levels (1, 5, 10 VMs) |

Both approaches test what VMs actually experience, not raw storage throughput. Tools like `rados bench` or `rbd bench` (Ceph-native) bypass the VM/hypervisor layer entirely and are not comparable to HCIBench results.

The key difference in methodology is the **goal**: HCIBench typically deploys many VMs with many VMDKs (e.g. 16 VMs × 8 disks = 128 concurrent I/O streams) to find the aggregate cluster ceiling. This suite tests individual pool performance at specific concurrency levels, answering "what will my workload get?" rather than "what is the cluster maximum?" This is more useful for capacity planning and migration sizing — a vSAN customer running 5 database VMs cares about the performance those 5 VMs will see, not the theoretical cluster peak.

Results from both tools are valid for comparison as long as the fio parameters align (block size, read/write ratio, queue depth, runtime). The fio profiles in this suite (`random-rw`, `mixed-70-30`, `db-oltp`) are designed to match common HCIBench workload scenarios.

## Placement Groups and Performance

### What Are Placement Groups?

**Placement Groups (PGs)** are the intermediate mapping layer between Ceph objects and OSDs. Every pool has a fixed number of PGs, and every RADOS object is assigned to exactly one PG via hashing. The PG is then mapped to a set of OSDs by the CRUSH algorithm.

```
Object → hash(object_name) mod pg_num → PG → CRUSH(PG) → [OSD.1, OSD.4, OSD.7]
```

PG count directly determines I/O parallelism: each PG has a single primary OSD that handles all writes and (by default) reads for objects in that PG. With too few PGs, I/O concentrates on a small number of primary OSDs, creating a bottleneck even if the cluster has many OSDs available.

### The PG Autoscaler

Ceph's **PG autoscaler** (`pg_autoscaler` module) automatically adjusts PG counts based on pool usage. It uses two signals:

- **`target_size_ratio`** — A hint telling the autoscaler what fraction of total cluster capacity this pool is expected to use
- **Actual data stored** — Scales PGs based on current pool size relative to the cluster

For a newly created empty pool with no `target_size_ratio`, the autoscaler sees zero data and assigns the minimum: **1 PG**. This is correct from a capacity perspective but catastrophic for performance — all I/O funnels through a single OSD. The OOB pools avoid this by setting `targetSizeRatio: 0.49`, which pre-allocates 256+ PGs.

Custom pools must set `targetSizeRatio` to avoid this bottleneck. For a complete explanation of the autoscaler formula, threshold behaviour, ratio normalization, and impact modelling, see the [CephBlockPool Setup Guide](../guides/ceph-pool-setup.md#understanding-pg-autoscaling).

## RBD (RADOS Block Device)

**RBD** is Ceph's block storage interface. It presents a virtual block device to the host, backed by RADOS objects. This is what ODF uses to fulfill PVCs for VMs.

Key characteristics:
- Thin-provisioned (allocates space on write, not on creation)
- Supports snapshots and clones
- Data is striped across multiple objects and distributed across OSDs
- Accessed via the `rbd` kernel module or `librbd` user-space library

When a VM writes to its data disk, the I/O path is:

```
VM fio → virtio block device → virt-launcher pod → RBD CSI driver → Ceph OSD(s)
```

## ODF (OpenShift Data Foundation)

**ODF** is Red Hat's distribution of Ceph for OpenShift. It uses the **Rook** operator to automate Ceph deployment and management.

### What ODF Provides

- Automatic Ceph cluster deployment on bare metal workers
- OSD provisioning on local NVMe drives
- StorageClasses for block (RBD) and file (CephFS) storage
- Monitoring integration with the OpenShift web console
- Automated recovery and rebalancing

### Default ROKS Configuration

When ODF is installed on a ROKS cluster with bare metal workers:

1. Rook discovers local NVMe drives and creates OSDs on each
2. A default CephBlockPool with replication factor 3 is created
3. A default StorageClass (`ocs-storagecluster-ceph-rbd`) is created
4. MONs and MGRs are deployed across multiple worker nodes

This default rep3 StorageClass is what most workloads use. Our test suite creates additional pools and StorageClasses to compare performance across different data protection strategies.

### Performance Profiles

The ODF operator supports three resource allocation profiles that control CPU and memory reserved for Ceph daemons (OSDs, MONs, MGR, MDS, RGW):

- **Lean** — Minimum resource allocation. Suitable for resource-constrained environments but not recommended for performance testing, as Ceph daemons may CPU-throttle under heavy I/O.
- **Balanced** — The default on ROKS. Adequate for general-purpose workloads.
- **Performance** — Recommended for this test suite. Allocates significantly more CPU and memory to Ceph daemons, reducing the risk of daemon-side bottlenecks during benchmarks.

The profile is selected during StorageSystem creation via the **Configure Performance** screen in the OpenShift web console. The resource requirements shown on that screen are dynamically computed based on your cluster's OSD count — clusters with more NVMe drives (and therefore more OSD daemons) require proportionally more resources.

Under-resourced Ceph daemons can become a hidden bottleneck: fio results may show lower IOPS or higher latency than the underlying storage hardware can deliver, because the OSD processes are CPU-throttled. Selecting the Performance profile eliminates this variable from benchmark results.

See the [VSI Storage Testing Guide — resourceProfile](../guides/vsi-storage-testing-guide.md#resourceprofile) for detailed sizing tables and bare metal scaling examples.

### CephBlockPool Custom Resource

The test suite creates custom CephBlockPools via `01-setup-storage-pools.sh`. Custom pools must match the OOB pool's settings (`deviceClass`, `enableCrushUpdates`, `enableRBDStats`, `targetSizeRatio`) to avoid performance pitfalls. Each pool gets a corresponding StorageClass with VM-optimized RBD image features (`exclusive-lock`, `object-map`, `fast-diff`, etc.).

For step-by-step pool creation instructions, correct YAML examples, and a detailed explanation of each setting, see the [CephBlockPool Setup Guide](../guides/ceph-pool-setup.md).

## Monitoring Ceph Health

Useful commands for checking ODF/Ceph status:

```bash
# Overall Ceph health
oc exec -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph status

# Pool statistics
oc exec -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph osd pool stats

# OSD tree (shows which OSDs are on which nodes)
oc exec -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph osd tree
```

## Next Steps

- [Failure Domains and Topology](failure-domains-and-topology.md) — CRUSH hierarchy, ROKS rack assignment, failureDomain options
- [CephBlockPool Setup Guide](../guides/ceph-pool-setup.md) — Step-by-step pool creation, correct settings, PG autoscaler deep dive
- [Erasure Coding Explained](erasure-coding-explained.md) — Deep dive into EC vs replication
- [Storage in Kubernetes](storage-in-kubernetes.md) — How PVCs connect to Ceph pools
- [Understanding Results](../guides/understanding-results.md) — How pool type affects benchmark numbers
