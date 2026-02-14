# OpenShift Overview

[Back to Index](../index.md)

This page explains what OpenShift is, how it relates to Kubernetes, and why this project runs on IBM Cloud ROKS with bare metal workers.

## OpenShift vs Kubernetes

**OpenShift** is Red Hat's enterprise Kubernetes distribution. It takes upstream Kubernetes and adds:

- **Operators** — Automated lifecycle management for complex applications (install, upgrade, configure)
- **Enhanced security** — Security Context Constraints (SCCs), built-in OAuth, role-based access
- **Developer tooling** — Web console, Source-to-Image builds, integrated CI/CD
- **Enterprise support** — Red Hat subscription with long-term support and certifications

Think of it like the difference between Linux (the kernel) and Red Hat Enterprise Linux (a supported distribution). Kubernetes is the foundation; OpenShift is the production-ready platform built on top.

### What Does This Mean for the Test Suite?

The main differences you'll encounter:

| Kubernetes | OpenShift |
|-----------|-----------|
| `kubectl` CLI | `oc` CLI (superset of kubectl) |
| Manually install add-ons | Install via Operator Hub |
| Self-managed | ROKS = IBM-managed control plane |

## Operators

**Operators** are a Kubernetes pattern for automating the management of complex applications. An Operator watches for custom resources and takes actions to maintain the desired state.

This project relies on two operators:

### OpenShift Data Foundation (ODF)
- Installs and manages Ceph storage on the cluster
- Creates CephBlockPools, StorageClasses, and manages OSDs
- Deployed in the `openshift-storage` namespace
- See [Ceph and ODF](ceph-and-odf.md) for details

### OpenShift Virtualization
- Installs and manages KubeVirt for running VMs
- Handles VM lifecycle, live migration, and device management
- Enables running traditional VMs alongside containers
- See [OpenShift Virtualization](openshift-virtualization.md) for details

Both are installed via the **OperatorHub** in the OpenShift web console or via CLI.

## IBM Cloud ROKS

**ROKS** (Red Hat OpenShift on IBM Cloud) is IBM's managed OpenShift service. "Managed" means:

- IBM manages the **control plane** (API server, etcd, controllers) — you don't need to worry about upgrading or maintaining it
- You manage the **worker nodes** — choosing machine types, scaling, and configuring workloads
- Automatic integration with IBM Cloud services (VPC networking, IAM, logging)

### Why Bare Metal Workers?

This project requires **bare metal** worker nodes specifically. The bx3d flavor provides:

| Feature | Why It Matters |
|---------|---------------|
| **Local NVMe SSDs** | Ceph/ODF uses these as OSDs for high-performance storage. NVMe is orders of magnitude faster than network-attached storage. |
| **Hardware virtualization (VT-x)** | Required by KubeVirt to run VMs with near-native performance. Virtual workers lack nested virtualization support. |
| **No hypervisor overhead** | Performance measurements reflect actual storage capabilities, not virtualization artifacts. |
| **Consistent performance** | No "noisy neighbor" effects from co-tenant workloads on the same physical host. |

### bx3d Worker Flavor

The `bx3d` is an IBM Cloud bare metal profile optimized for data-intensive workloads:

- Intel Xeon processors with high core counts
- Large memory capacity
- Multiple local NVMe drives (used by ODF as Ceph OSDs)
- High-bandwidth VPC networking

The project stores the flavor in `BM_FLAVOR` for inclusion in report metadata, so results can be correlated with the hardware they ran on.

## OpenShift Concepts Used in This Project

### Projects vs Namespaces
In OpenShift, a **project** is a namespace with additional annotations. For this project, we use the term "namespace" — they're functionally equivalent for our purposes. The test namespace (`vm-perf-test`) is created as a standard Kubernetes namespace.

### Security Context Constraints (SCCs)
OpenShift SCCs control what pods can do. KubeVirt's `virt-launcher` pods require elevated privileges to run VMs. The OpenShift Virtualization operator configures the necessary SCCs automatically.

### Routes and Services
While this project doesn't create routes or services (the VMs are accessed via `virtctl ssh`, not via network services), you may encounter them when accessing the OpenShift web console to monitor cluster health.

## Next Steps

- [Storage in Kubernetes](storage-in-kubernetes.md) — How Kubernetes manages persistent storage
- [Ceph and ODF](ceph-and-odf.md) — The storage backend running on these bare metal workers
- [Prerequisites](../guides/prerequisites.md) — Setting up your ROKS cluster
