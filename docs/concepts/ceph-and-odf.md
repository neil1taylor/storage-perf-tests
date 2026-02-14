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
│              RADOS                       │
│     (distributed object storage)         │
├──────────┬──────────┬───────────────────┤
│   OSD    │   OSD    │    OSD   ...      │
│  (NVMe)  │  (NVMe)  │   (NVMe)         │
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
3. The PG is mapped to a set of OSDs using the **CRUSH** algorithm
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
  ┌──────┐  ┌──────┐  ┌──────┐
  │ OSD.1│  │ OSD.4│  │ OSD.7│
  │Hello │  │Hello │  │Hello │
  │(copy1)│ │(copy2)│ │(copy3)│
  └──────┘  └──────┘  └──────┘
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

### CephBlockPool Custom Resource

The test suite creates custom CephBlockPools via `01-setup-storage-pools.sh`:

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
```

For erasure-coded pools:

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: perf-test-ec-4-2
  namespace: openshift-storage
spec:
  failureDomain: host
  erasureCoded:
    dataChunks: 4
    codingChunks: 2
```

Each pool gets a corresponding StorageClass with the `perf-test-sc-` prefix.

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

- [Erasure Coding Explained](erasure-coding-explained.md) — Deep dive into EC vs replication
- [Storage in Kubernetes](storage-in-kubernetes.md) — How PVCs connect to Ceph pools
- [Understanding Results](../guides/understanding-results.md) — How pool type affects benchmark numbers
