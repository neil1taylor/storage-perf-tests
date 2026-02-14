# Glossary

[Back to Index](index.md)

Quick-reference for terms used throughout this project and its documentation.

---

**Access Mode** — Defines how a PVC can be mounted. `ReadWriteOnce` (RWO) allows one node; `ReadWriteMany` (RWX) allows multiple nodes. This project uses RWO for VM data disks. See [Storage in Kubernetes](concepts/storage-in-kubernetes.md).

**Bandwidth (BW)** — The rate of data transfer, typically measured in KiB/s or MiB/s. Large-block sequential workloads are bandwidth-sensitive. See [fio Benchmarking](concepts/fio-benchmarking.md).

**Block Size (bs)** — The size of each I/O operation in fio. Small block sizes (4k) test IOPS; large block sizes (1M) test throughput. See [fio Benchmarking](concepts/fio-benchmarking.md).

**CDI (Containerized Data Importer)** — A Kubernetes controller that provisions VM disk images into PVCs. Used by DataVolumes to clone root disks from pre-cached DataSources. See [OpenShift Virtualization](concepts/openshift-virtualization.md).

**CephBlockPool** — A Ceph storage pool definition in ODF. Each pool has a replication or erasure coding policy. The test suite creates custom pools with the `perf-test-` prefix. See [Ceph and ODF](concepts/ceph-and-odf.md).

**Cloud-init** — An industry-standard tool for VM instance initialization. This project uses cloud-init to install fio, write a benchmark script, and create a systemd service that runs the test automatically on boot. See [OpenShift Virtualization](concepts/openshift-virtualization.md).

**Concurrency** — In this project, the number of VMs running the same fio test simultaneously against the same storage pool. Tests contention and scalability. Default levels: 1, 5, 10.

**CSI (Container Storage Interface)** — A standard API that allows storage vendors to provide plugins for Kubernetes. ODF uses a CSI driver for Ceph RBD; IBM Cloud provides a CSI driver for VPC file storage. See [Storage in Kubernetes](concepts/storage-in-kubernetes.md).

**DataVolume** — A KubeVirt/CDI custom resource that combines a PVC with a source reference (e.g., a DataSource pointing to a pre-cached golden image). Used for VM root disks. This project uses the CDI `storage:` API (rather than `pvc:`) so CDI can determine the optimal access mode and volume mode from the StorageProfile, enabling fast CSI cloning on Ceph RBD. See [OpenShift Virtualization](concepts/openshift-virtualization.md).

**direct=1 (O_DIRECT)** — A fio flag that bypasses the OS page cache, sending I/O directly to the storage device. Required for accurate storage benchmarking. See [fio Benchmarking](concepts/fio-benchmarking.md).

**Erasure Coding (EC)** — A data protection method that splits data into k data chunks and m parity chunks. More storage-efficient than replication but has higher CPU overhead. See [Erasure Coding Explained](concepts/erasure-coding-explained.md).

**fio (Flexible I/O Tester)** — An open-source tool for benchmarking and stress-testing I/O subsystems. The core measurement tool in this project. See [fio Benchmarking](concepts/fio-benchmarking.md).

**fsync** — A system call that forces data to be flushed from OS buffers to the underlying storage device. Critical for database workloads where durability matters. The `db-oltp` profile uses `fsync=1` for WAL writes.

**I/O Depth (iodepth)** — The number of I/O requests fio keeps in-flight simultaneously. Higher iodepth saturates the storage subsystem, revealing maximum throughput. Default: 32. See [fio Benchmarking](concepts/fio-benchmarking.md).

**IOPS (I/O Operations Per Second)** — A measure of how many read or write operations a storage system can handle per second. Small-block random workloads are IOPS-sensitive. See [fio Benchmarking](concepts/fio-benchmarking.md).

**KubeVirt** — The Kubernetes operator that enables running traditional VMs alongside containers. OpenShift Virtualization is Red Hat's distribution of KubeVirt. See [OpenShift Virtualization](concepts/openshift-virtualization.md).

**Latency** — The time for a single I/O operation to complete. Measured as average (mean) and percentiles (p99 = 99th percentile). Lower is better. Reported in milliseconds in this project.

**libaio** — The Linux asynchronous I/O engine used by fio in this project. Allows multiple I/O operations to be submitted without waiting for each to complete, enabling high iodepth.

**MON (Monitor)** — A Ceph daemon that maintains the cluster map and consensus. Requires a quorum (majority). See [Ceph and ODF](concepts/ceph-and-odf.md).

**Namespace** — A Kubernetes mechanism for isolating groups of resources. This project creates resources in the `vm-perf-test` namespace. See [Kubernetes Basics](concepts/kubernetes-basics.md).

**numjobs** — The number of parallel fio worker processes. Each job runs the workload independently. Default: 4. Combined with iodepth, determines total I/O parallelism.

**O_DIRECT** — A Linux open flag that bypasses the kernel page cache. See **direct=1**.

**ODF (OpenShift Data Foundation)** — Red Hat's storage solution for OpenShift, built on Ceph (via Rook). Provides block, file, and object storage. See [Ceph and ODF](concepts/ceph-and-odf.md).

**Operator** — A Kubernetes pattern for automating application lifecycle management. ODF and OpenShift Virtualization are both installed as operators. See [OpenShift Overview](concepts/openshift-overview.md).

**OSD (Object Storage Daemon)** — The Ceph daemon responsible for storing data on a physical disk. Each NVMe drive in the cluster typically runs one OSD. See [Ceph and ODF](concepts/ceph-and-odf.md).

**p99 Latency** — The 99th percentile latency: 99% of operations complete within this time. Captures tail latency spikes that averages hide. Critical for SLA evaluation.

**PV (PersistentVolume)** — A piece of storage in a Kubernetes cluster, provisioned by an administrator or dynamically via a StorageClass. See [Storage in Kubernetes](concepts/storage-in-kubernetes.md).

**PVC (PersistentVolumeClaim)** — A request for storage by a pod or VM. Binds to a PV. This project tests PVC sizes of 10Gi, 50Gi, and 100Gi. See [Storage in Kubernetes](concepts/storage-in-kubernetes.md).

**RADOS (Reliable Autonomic Distributed Object Store)** — The foundational layer of Ceph that provides distributed object storage. All higher-level Ceph interfaces (RBD, CephFS, RGW) are built on top of RADOS. See [Ceph and ODF](concepts/ceph-and-odf.md).

**Ramp Time** — A warmup period before fio starts recording metrics. Allows caches and I/O queues to reach steady state. Default: 10 seconds.

**RBD (RADOS Block Device)** — Ceph's block storage interface. Provides virtual block devices backed by RADOS objects. Used by ODF to fulfill PVCs. See [Ceph and ODF](concepts/ceph-and-odf.md).

**ROKS (Red Hat OpenShift on IBM Cloud)** — IBM's managed OpenShift service. This project runs on ROKS with bare metal bx3d workers that have local NVMe drives for ODF. See [OpenShift Overview](concepts/openshift-overview.md).

**Rook** — A Kubernetes operator that automates Ceph deployment and management. ODF uses Rook internally. See [Ceph and ODF](concepts/ceph-and-odf.md).

**Run ID** — A unique identifier for each test execution, formatted as `perf-YYYYMMDD-HHMMSS`. Used to label resources and organize results.

**StorageClass** — A Kubernetes resource that defines *how* storage is provisioned. Maps to a CSI driver and configuration parameters. See [Storage in Kubernetes](concepts/storage-in-kubernetes.md).

**stonewall** — A fio directive that ensures the previous job completes before the next one starts. Prevents jobs from running in parallel within a single profile.

**virtctl** — The KubeVirt CLI tool for managing VMs. Used in this project for SSH access to running VMs to collect fio results. See [OpenShift Virtualization](concepts/openshift-virtualization.md).

**VM (VirtualMachine)** — In KubeVirt, a custom resource that defines a persistent virtual machine. The VM resource manages the lifecycle of VMI (VirtualMachineInstance) objects. See [OpenShift Virtualization](concepts/openshift-virtualization.md).

**VMI (VirtualMachineInstance)** — The running instance of a KubeVirt VM. Analogous to a pod for containers. See [OpenShift Virtualization](concepts/openshift-virtualization.md).

**WAL (Write-Ahead Log)** — A sequential log used by databases to ensure durability. Writes are first recorded in the WAL before being applied to data pages. The `db-oltp` profile simulates WAL behavior with sequential 8k writes and `fsync=1`.
