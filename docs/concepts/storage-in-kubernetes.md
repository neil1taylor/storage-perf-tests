# Storage in Kubernetes

[Back to Index](../index.md)

This page explains how Kubernetes manages persistent storage — the foundation for everything this test suite measures. Understanding PVs, PVCs, StorageClasses, and CSI is essential for interpreting test results.

## The Problem: Containers Are Ephemeral

Containers (and pods) are designed to be disposable. When a pod restarts, its filesystem is wiped clean. But databases, VMs, and many applications need storage that persists across restarts. Kubernetes solves this with its persistent storage model.

## PersistentVolumes (PVs)

A **PersistentVolume (PV)** represents a piece of actual storage in the cluster. It could be:
- A Ceph RBD image (what ODF provides)
- An NFS share
- An IBM Cloud VPC file share
- A local disk on a node

PVs have a lifecycle independent of any pod. They exist until explicitly deleted.

## PersistentVolumeClaims (PVCs)

A **PersistentVolumeClaim (PVC)** is a *request* for storage. When you create a PVC, Kubernetes finds (or creates) a PV that satisfies the request and **binds** them together.

A PVC specifies:
- **Size** — How much storage is needed (e.g., `50Gi`)
- **Access mode** — How the storage can be mounted
- **StorageClass** — Which storage backend to use

### Access Modes

| Mode | Short | Meaning |
|------|-------|---------|
| ReadWriteOnce | RWO | Can be mounted read-write by a single node |
| ReadOnlyMany | ROX | Can be mounted read-only by many nodes |
| ReadWriteMany | RWX | Can be mounted read-write by many nodes |

This project uses **ReadWriteOnce (RWO)** for VM data disks — each VM needs exclusive read-write access to its storage. Root disk DataVolumes use the CDI `storage:` API, which lets CDI choose the optimal access mode from the StorageProfile (typically RWX Block for Ceph RBD, enabling fast CSI cloning).

### Volume Modes

In addition to access modes, PVCs declare a **volumeMode** that determines how the storage is presented to the pod:

| Mode | Meaning |
|------|---------|
| `Filesystem` (default) | The CSI driver provisions storage and the kubelet mounts it as a directory. Pods read and write files on that filesystem. For NFS-backed PVCs, the kubelet mounts the remote NFS share; for block-backed PVCs, the kubelet formats a block device with a filesystem first. |
| `Block` | The CSI driver provisions a raw block device and the pod gets direct access to it — no filesystem layer. The pod sees a device node (e.g., `/dev/xvda`) rather than a mounted directory. |

**Why this matters for VMs:**

- **Filesystem-mode PVCs:** KubeVirt stores the VM's virtual disk as a raw `disk.img` file inside the mounted directory. QEMU opens this file and presents it to the guest as a virtio block device. Every guest I/O passes through QEMU's file I/O layer and the host's filesystem (or NFS) stack — an indirection known as **file-on-filesystem**. See [How Storage Reaches the VM](openshift-virtualization.md#how-storage-reaches-the-vm).
- **Block-mode PVCs:** KubeVirt passes the raw block device directly to QEMU. No intermediate file or filesystem layer — guest I/O goes straight to the block device. This is the lower-overhead path and is what ODF (Ceph RBD) and IBM Cloud Block CSI use for VM disks.

IBM Cloud File CSI only supports `Filesystem` mode (NFS), while ODF (Ceph RBD) and IBM Cloud Block CSI support both modes. This is one reason block storage tends to have lower latency than NFS for VM workloads.

### PVC Lifecycle

```
PVC Created → Pending → Bound → In Use → Released → Deleted
```

1. **Pending** — Waiting for a matching PV to be provisioned
2. **Bound** — PV has been allocated and bound to this PVC
3. **In Use** — A pod or VM is actively using the PVC
4. **Released/Deleted** — The PVC is deleted, and the PV may be reclaimed

The test suite waits for PVCs to reach the **Bound** state before proceeding (see `wait_for_pvc_bound` in `lib/wait-helpers.sh`).

## StorageClasses

A **StorageClass** defines *how* storage should be provisioned. It's the link between a PVC request and the actual storage backend.

Key fields:
- **provisioner** — Which CSI driver creates the storage (e.g., `openshift-storage.rbd.csi.ceph.com` for ODF)
- **parameters** — Backend-specific settings (e.g., which Ceph pool to use, filesystem type)
- **reclaimPolicy** — What happens to the PV when the PVC is deleted (`Delete` or `Retain`)
- **volumeBindingMode** — When to provision: `Immediate` (right away) or `WaitForFirstConsumer` (when a pod needs it)

### StorageClasses in This Project

The test suite tests multiple StorageClasses to compare storage backends:

| StorageClass | Backend | Created By |
|-------------|---------|------------|
| `ocs-storagecluster-ceph-rbd` | ODF rep3 (default ROKS) | Pre-installed with ODF |
| `ocs-storagecluster-ceph-rbd-virtualization` | ODF rep3-virt (VM-optimized) | Pre-installed with ODF |
| `ocs-storagecluster-ceph-rbd-encrypted` | ODF rep3-enc (encrypted) | Pre-installed with ODF |
| `ocs-storagecluster-cephfs` | ODF CephFS rep3 | Pre-installed with ODF |
| `perf-test-sc-rep2` | ODF rep2 | `01-setup-storage-pools.sh` |
| `perf-test-sc-cephfs-rep2` | ODF CephFS rep2 | `01-setup-storage-pools.sh` |
| `perf-test-sc-ec-2-1` | ODF EC 2+1 | `01-setup-storage-pools.sh` |
| `perf-test-sc-ec-3-1` | ODF EC 3+1 | `01-setup-storage-pools.sh` |
| `perf-test-sc-ec-2-2` | ODF EC 2+2 | `01-setup-storage-pools.sh` |
| `perf-test-sc-ec-4-2` | ODF EC 4+2 | `01-setup-storage-pools.sh` |
| `ibmc-vpc-file-*` | IBM Cloud File (NFS) | Pre-installed with ROKS |
| `ibmc-vpc-block-*` | IBM Cloud Block (VSI only) | Pre-installed with ROKS |
| `bench-pool` | IBM Cloud Pool CSI (NFS pool) | `02-setup-file-storage.sh` |

### Dynamic Provisioning

When a PVC references a StorageClass, Kubernetes **dynamically provisions** a PV automatically — you don't need to create PVs manually. This is the standard pattern used throughout this project.

```
PVC (requests 50Gi from "perf-test-sc-rep2")
  ↓
StorageClass (provisioner: rbd.csi.ceph.com, pool: perf-test-rep2)
  ↓
CSI Driver (creates a 50Gi RBD image in the Ceph pool)
  ↓
PV (automatically created and bound to the PVC)
```

## CSI (Container Storage Interface)

**CSI** is a standardized API that allows storage vendors to write plugins ("drivers") for Kubernetes without modifying Kubernetes itself.

### How CSI Works

```
Kubernetes ←→ CSI Driver ←→ Storage Backend
```

1. Kubernetes tells the CSI driver: "Create a 50Gi volume with these parameters"
2. The CSI driver translates this into storage-specific operations (e.g., create a Ceph RBD image)
3. The CSI driver reports back to Kubernetes with volume details
4. Kubernetes mounts the volume into the pod/VM

### CSI Drivers in This Project

| Driver | Backend | Used For |
|--------|---------|----------|
| `openshift-storage.rbd.csi.ceph.com` | ODF / Ceph RBD | All RBD-backed PVCs (rep2, rep3, EC pools) |
| `openshift-storage.cephfs.csi.ceph.com` | ODF / CephFS | CephFS-backed PVCs (cephfs-rep3, cephfs-rep2) |
| `vpc.file.csi.ibm.io` | IBM Cloud VPC File | IBM Cloud File CSI PVCs and Pool CSI (FileSharePool) |
| `vpc.block.csi.ibm.io` | IBM Cloud VPC Block | IBM Cloud Block CSI PVCs (VSI clusters only) |

Each CSI driver registers itself with Kubernetes and becomes available as a provisioner in StorageClasses.

## Why Storage Configuration Matters for Performance

Different storage configurations have dramatically different performance characteristics:

| Factor | Impact |
|--------|--------|
| **Replication factor** | Rep3 writes 3 copies = 3x write amplification. Rep2 writes 2 copies. |
| **Erasure coding** | EC writes fewer total bytes but requires CPU for encoding/decoding. |
| **PVC size** | Larger PVCs may stripe across more OSDs, potentially increasing parallelism. |
| **Access mode** | RWO vs RWX can affect which nodes can host the storage. |
| **StorageClass parameters** | Filesystem type, encryption, compression, and RBD image features (`imageFeatures`, `mapOptions`) all affect performance. Features like `exclusive-lock` enable write-back caching and can improve write IOPS by up to 7x. |

This test suite systematically measures these differences by testing multiple StorageClasses, PVC sizes, and workload patterns.

## Next Steps

- [Ceph and ODF](ceph-and-odf.md) — Deep-dive into the Ceph storage backend
- [Erasure Coding Explained](erasure-coding-explained.md) — How EC pools differ from replicated pools
- [Configuration Reference](../guides/configuration-reference.md) — How StorageClasses are configured in this project
