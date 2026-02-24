# OpenShift Virtualization

[Back to Index](../index.md)

This page explains how OpenShift Virtualization (KubeVirt) runs traditional virtual machines on Kubernetes, and how this project uses VMs as the test harness for storage benchmarking.

## Why VMs on Kubernetes?

Many enterprise workloads still run in virtual machines — legacy applications, databases, Windows workloads, and anything that can't easily be containerized. OpenShift Virtualization lets you run VMs alongside containers on the same infrastructure, managed with the same tools.

For this test suite, VMs are the natural test unit because:
- VMs are a primary consumer of persistent block storage on OpenShift
- VM I/O goes through the full storage stack (virtio → CSI → Ceph)
- Testing with VMs gives results that directly predict real VM workload performance
- Each VM has its own isolated filesystem and kernel, preventing test interference

## KubeVirt Concepts

### VM vs VMI

KubeVirt introduces two key custom resources:

| Resource | Purpose | Lifecycle |
|----------|---------|-----------|
| **VirtualMachine (VM)** | Defines the VM configuration and desired state. Persistent — survives reboots. | Created once, exists until deleted |
| **VirtualMachineInstance (VMI)** | The running instance of a VM. Like a pod for containers. | Created when VM starts, deleted when VM stops |

Think of it this way: the **VM** is like a VM definition in VMware vCenter (it persists). The **VMI** is like the running state of that VM (it exists only while running).

In this project, VMs are set to `running: true` so the VMI is created automatically:

```yaml
spec:
  running: true   # Start the VM immediately after creation
```

### virt-launcher Pod

Each running VMI is backed by a **virt-launcher pod**. This pod contains:
- The QEMU/KVM process that runs the VM
- A `libvirt` daemon managing the VM lifecycle
- Mounted volumes (root disk, data disk, cloud-init disk)

You can see these pods with:
```bash
oc get pods -n vm-perf-test -l app=vm-perf-test
```

## VM Disks in This Project

Each test VM has three disks:

### 1. Root Disk (via DataVolume)

The operating system disk. Uses a Fedora Cloud 40 qcow2 image cloned from a built-in DataSource.

```yaml
volumes:
  - name: rootdisk
    dataVolume:
      name: __VM_NAME__-rootdisk
```

**DataVolume** is a CDI (Containerized Data Importer) resource that combines:
- A PVC (where the disk data is stored)
- A `sourceRef` pointing at a built-in DataSource (a pre-cached golden image managed by the cluster)

CDI clones the image from the pre-cached DataSource into a new PVC. The root disk DataVolume uses the CDI `storage:` API (rather than `pvc:`), which lets CDI consult the StorageProfile to determine the optimal access mode and volume mode. For `ocs-storagecluster-ceph-rbd`, this enables CSI cloning (snapshot-based, near-instant) instead of host-assisted cloning. The root disk always uses the default ODF StorageClass (`ocs-storagecluster-ceph-rbd`) regardless of which storage pool is being tested.

### 2. Data Disk (the disk under test)

This is the PVC that fio benchmarks run against. It uses whichever StorageClass corresponds to the current test's storage pool.

```yaml
volumes:
  - name: datadisk
    persistentVolumeClaim:
      claimName: __VM_NAME__-data
```

The data disk's StorageClass and size vary per test — this is the variable being measured.

### How Storage Reaches the VM

The path from physical storage to the guest VM's `/dev/vda` differs depending on whether the PVC uses **block mode** or **filesystem mode**. Understanding this path explains why different storage backends have different latency characteristics.

#### Block-mode PVCs (ODF/Ceph RBD, IBM Cloud Block CSI)

```
Guest I/O → virtio-blk → QEMU/KVM → raw block device → CSI driver → storage backend
```

- The PVC's block device is passed directly into the virt-launcher pod
- QEMU/KVM maps it as a virtio-blk device — the guest sees `/dev/vda`
- No filesystem layer between QEMU and the storage; I/O goes directly to the block device
- This is the lower-overhead path and is used by ODF (Ceph RBD) and IBM Cloud Block CSI

#### Filesystem-mode PVCs (IBM Cloud File CSI / NFS)

```
Guest I/O → virtio-blk → QEMU (file I/O on disk.img)
  → virt-launcher pod mount namespace
  → kubelet NFS mount on node
  → NFS client (kernel) → network → NFS server
```

- The CSI node plugin mounts the NFS share onto the node's filesystem
- The container runtime (CRI-O) bind-mounts that same mount point into the virt-launcher pod — there is **one NFS mount** (on the node), not separate mounts on the node and in the pod
- Inside the PV mount directory, KubeVirt stores the virtual disk as a raw `disk.img` file
- QEMU opens `disk.img` and presents it to the guest via virtio — the guest still sees `/dev/vda`
- Every guest I/O traverses: QEMU (translates guest block offset to file offset in `disk.img`) → host VFS/NFS client → network → NFS server

#### File-on-filesystem indirection

This is the extra abstraction layer with filesystem-mode PVCs. A file is pretending to be a disk: the guest thinks it's writing to a raw block device, but each write passes through QEMU's file I/O layer and the host's VFS/NFS stack before reaching the actual storage. Block-mode PVCs skip this layer entirely, which is one reason they tend to have lower latency.

See also [Volume Modes](storage-in-kubernetes.md#volume-modes) for how Kubernetes exposes these two modes.

#### Raw vs qcow2 image format

CDI (Containerized Data Importer) converts qcow2 source images to **raw format** during import. This is documented in the [KubeVirt CDI README](https://github.com/kubevirt/containerized-data-importer) and the [KubeVirt.io blog](https://kubevirt.io). You can verify this by watching importer pod logs during a DataVolume import — they show "Doing streaming qcow2 to raw conversion".

- **Raw format:** Block N in the guest maps directly to byte offset N in the file. Zero translation overhead.
- **qcow2 format:** Requires L1/L2 metadata table lookups on every I/O operation. Stacking this on top of NFS would add even more indirection to an already indirect path.

Raw is the right choice for performance: for block-mode PVCs, the raw image maps 1:1 to the block device. For filesystem-mode PVCs, raw eliminates the qcow2 metadata overhead, leaving only the file-on-filesystem indirection.

### 3. Cloud-init Disk

Contains the cloud-init user-data that configures the VM on first boot.

```yaml
volumes:
  - name: cloudinitdisk
    cloudInitNoCloud:
      userData: |
        #cloud-config
        ...
```

## Cloud-init

**Cloud-init** is the industry-standard tool for initializing cloud VM instances. When the VM boots, cloud-init reads the user-data from the cloud-init disk and executes it.

In this project, cloud-init performs several tasks:

### 1. User Setup
Creates the `fedora` user with sudo access and injects the test suite's SSH public key:
```yaml
users:
  - name: fedora
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...
```

### 2. Package Installation
Installs the tools needed for benchmarking:
```yaml
packages:
  - fio       # The benchmark tool
  - jq        # JSON parsing for results
  - sysstat   # System statistics
  - nvme-cli  # NVMe device info
```

### 3. File Injection
Writes the fio job file and benchmark runner script into the VM:
```yaml
write_files:
  - path: /opt/perf-test/fio-job.fio
    content: |
      [global]
      ioengine=libaio
      ...
  - path: /opt/perf-test/run-benchmark.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      ...
```

### 4. Systemd Service
Creates a oneshot systemd service that runs the benchmark automatically:
```yaml
write_files:
  - path: /etc/systemd/system/perf-test.service
    content: |
      [Unit]
      Description=VM Storage Performance Test
      After=multi-user.target cloud-final.service
      [Service]
      Type=oneshot
      ExecStart=/opt/perf-test/run-benchmark.sh
      RemainAfterExit=yes
```

The **Type=oneshot** with **RemainAfterExit=yes** means the service runs once and then reports "active" with SubState=exited (completed). The test suite polls for this transition to know when fio is done. For reused VMs, the service is stopped and restarted with `--no-block` to run subsequent fio jobs asynchronously.

### 5. Service Activation
Starts the benchmark service via runcmd:
```yaml
runcmd:
  - systemctl daemon-reload
  - systemctl enable perf-test.service
  - systemctl start perf-test.service
```

## VM Sizes

The test suite defines three VM sizes to measure how CPU and memory allocation affect storage performance:

| Size | vCPUs | Memory | Use Case |
|------|-------|--------|----------|
| small | 2 | 4Gi | Lightweight workloads, micro-services |
| medium | 4 | 8Gi | Standard application servers |
| large | 8 | 16Gi | Database servers, heavy workloads |

More vCPUs can drive more parallel I/O (via fio's `numjobs`), and more memory provides better page cache performance (though fio uses `direct=1` to bypass the cache for measurement accuracy).

## virtctl CLI

**virtctl** is the KubeVirt CLI tool. This project uses it primarily for SSH access to running VMs:

```bash
# SSH into a running VM
virtctl ssh --namespace=vm-perf-test \
  --identity-file=./ssh-keys/perf-test-key \
  fedora@<vm-name>
```

The test suite uses `virtctl ssh` to:
1. Poll the systemd service status (check if fio is done)
2. Copy fio JSON results out of the VM
3. Collect system info (CPU, memory, disk layout)
4. Replace fio job files in reused VMs (via base64-encoded content + `sudo tee`)
5. Restart the benchmark service for subsequent fio runs

## The VM Lifecycle in a Test

VMs are created once per (pool × vm_size × pvc_size × concurrency) group and reused across all fio profile and block size permutations:

1. **Renders** the fio profile and cloud-init for the first permutation
2. **Creates** N VMs (N = concurrency level) via `oc apply`
3. **Waits** for all VMs to reach Running state (VMI ready)
4. **Waits** for the `perf-test.service` to complete in each VM
5. **Collects** fio JSON results via `virtctl ssh`
6. For each subsequent (profile × block_size) permutation:
   - **Replaces** the fio job file in each VM via SSH (`replace_fio_job`)
   - **Restarts** the benchmark service (`restart_fio_service`)
   - **Waits** for fio to complete, then **collects** results
7. **Deletes** all VMs and their PVCs after all permutations complete

This reuse model avoids redundant VM provisioning, boot, and package installation for each fio profile and block size combination.

## VM Snapshots and Quiesce

### VolumeSnapshot

Kubernetes supports point-in-time snapshots of PVCs via the **VolumeSnapshot** CRD. For ODF-backed PVCs, the Ceph CSI driver creates an RBD snapshot — a copy-on-write reference to the image's state at that moment. Snapshots are fast (metadata-only initially) and space-efficient (only divergent blocks consume additional storage).

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-vm-snapshot
spec:
  volumeSnapshotClassName: ocs-storagecluster-rbdplugin-snapclass
  source:
    persistentVolumeClaimName: my-vm-data
```

### The Consistency Problem

A snapshot captures the **storage layer's view** of the disk at that instant, but the VM's guest OS may have dirty data that hasn't been flushed yet:

- **Filesystem buffers** — writes the guest kernel has accepted but not yet flushed to disk
- **Application-level buffers** — databases with write-ahead logs or in-memory transaction state
- **I/O in flight** — operations between the guest's block layer and the storage backend

A snapshot taken without coordination captures a **crash-consistent** image — equivalent to pulling the power cord. The VM will boot from this snapshot, but applications may need to replay journals or recover from unclean shutdown. For databases, this can mean transaction loss or corruption.

### Guest Quiesce with QEMU Guest Agent

To get an **application-consistent** snapshot, the guest OS must be quiesced before the snapshot is taken. OpenShift Virtualization supports this via the **QEMU Guest Agent (qemu-ga)**:

1. **Install the guest agent** inside the VM (included by default in Fedora/RHEL cloud images, or install via `qemu-guest-agent` package)
2. **Verify it's running**: `systemctl status qemu-guest-agent` inside the guest, or check from the host:
   ```bash
   oc get vmi my-vm -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}'
   ```
3. **Freeze the filesystem** — when a snapshot is requested with quiesce enabled, the platform sends a `guest-fsfreeze-freeze` command via the guest agent. This:
   - Flushes all dirty buffers to disk (`sync`)
   - Freezes all mounted filesystems (no new writes accepted)
   - Returns control to the snapshot workflow
4. **Take the snapshot** — with filesystems frozen, the storage-layer snapshot captures a clean, consistent state
5. **Thaw the filesystem** — after the snapshot completes, `guest-fsfreeze-thaw` unfreezes the filesystems and I/O resumes

### VirtualMachineSnapshot

OpenShift Virtualization provides a higher-level **VirtualMachineSnapshot** CRD that orchestrates the full workflow — quiesce, snapshot all disks, thaw — in a single operation:

```yaml
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineSnapshot
metadata:
  name: my-vm-snap
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: my-vm
```

If the guest agent is running, `VirtualMachineSnapshot` automatically freezes the guest filesystems before snapshotting and thaws them afterward. If the agent is not available, it falls back to a crash-consistent snapshot and reports this in the status conditions.

### Quiesce Hooks for Applications

The guest agent handles filesystem-level consistency, but application-level consistency (e.g., flushing a database WAL, pausing replication) requires additional coordination. Common patterns:

- **Pre-freeze/post-thaw hooks** — scripts that the guest agent runs before freezing and after thawing (`/etc/qemu-ga/fsfreeze-hook.d/`). For example, a hook that runs `pg_backup_start()` before freeze and `pg_backup_stop()` after thaw for PostgreSQL.
- **Application-aware backup agents** — tools like Velero with application-specific plugins that coordinate quiesce at the application layer before triggering the volume snapshot.

### Storage Backend Considerations

Not all storage backends support snapshots equally:

| Backend | Snapshot Support | Quiesce Support | Notes |
|---------|-----------------|-----------------|-------|
| ODF (Ceph RBD) | Native RBD snapshots (COW, fast) | Yes (via guest agent) | Best support; snapshots are metadata-only initially |
| ODF (CephFS) | CephFS snapshots via CSI | Yes (via guest agent) | Snapshot granularity is at the subvolume level |
| IBM Cloud Block CSI | VolumeSnapshot supported | Yes (via guest agent) | Backend snapshot implementation varies by tier |
| IBM Cloud File CSI | No VolumeSnapshot support | N/A | NFS-based; use file-level backup tools instead |

For encrypted volumes (LUKS), snapshots work at the RBD layer (below encryption), so the snapshot itself is encrypted. Restoring from a snapshot produces an encrypted volume that requires the same encryption key.

## Next Steps

- [fio Benchmarking](fio-benchmarking.md) — What fio does inside the VM
- [Template Rendering](../architecture/template-rendering.md) — How VM manifests and cloud-init are assembled
- [Running Tests](../guides/running-tests.md) — Walking through the full test flow
