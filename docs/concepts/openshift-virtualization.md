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

## Next Steps

- [fio Benchmarking](fio-benchmarking.md) — What fio does inside the VM
- [Template Rendering](../architecture/template-rendering.md) — How VM manifests and cloud-init are assembled
- [Running Tests](../guides/running-tests.md) — Walking through the full test flow
