# Kubernetes Basics

[Back to Index](../index.md)

This page covers the fundamental Kubernetes concepts you need to understand before working with this test suite. If you're already comfortable with Kubernetes, skip ahead to [OpenShift Overview](openshift-overview.md) or [Storage in Kubernetes](storage-in-kubernetes.md).

## What Is Kubernetes?

Kubernetes (often abbreviated as K8s) is an open-source platform for automating the deployment, scaling, and management of containerized applications. Think of it as an operating system for a cluster of machines — you tell Kubernetes what you want to run, and it figures out where and how to run it.

## Key Concepts

### Clusters and Nodes

A **cluster** is a set of machines (called **nodes**) that Kubernetes manages as a single unit.

- **Control plane nodes** run the Kubernetes API server, scheduler, and controllers. They make decisions about where workloads run.
- **Worker nodes** run the actual workloads (your applications, databases, VMs, etc.).

In this project, the cluster is an IBM Cloud ROKS cluster with **bare metal worker nodes** (bx3d flavor). Bare metal is important because:
- The NVMe drives on each worker are used directly by Ceph (ODF) for storage
- Virtualization requires hardware support (Intel VT-x) that bare metal provides
- There's no hypervisor overhead eating into performance measurements

### Pods

A **pod** is the smallest deployable unit in Kubernetes. A pod runs one or more containers and has its own IP address. In the context of this project, each KubeVirt VM runs inside a pod (specifically, a `virt-launcher` pod).

### Namespaces

**Namespaces** provide isolation within a cluster. They're like folders for Kubernetes resources — resources in different namespaces can have the same name without conflict.

This project uses two namespaces:
- `vm-perf-test` — where test VMs and PVCs are created (configurable via `TEST_NAMESPACE`)
- `openshift-storage` — where ODF/Ceph components run (configurable via `ODF_NAMESPACE`)

### Labels and Selectors

**Labels** are key-value pairs attached to Kubernetes resources. They're used to organize, filter, and select resources.

This project labels all test resources for easy identification and cleanup:

```yaml
labels:
  app: vm-perf-test
  perf-test/run-id: perf-20260214-103000
  perf-test/storage-pool: rep3
  perf-test/vm-size: small
  perf-test/pvc-size: 50Gi
```

The cleanup script (`09-cleanup.sh`) uses label selectors to find and delete only the resources created by the test suite:

```bash
oc delete vm -n vm-perf-test -l app=vm-perf-test
```

### YAML Manifests

Kubernetes resources are defined in YAML files called **manifests**. You apply them to the cluster using `oc apply -f <file.yaml>` (or `kubectl apply`). A manifest describes the desired state of a resource, and Kubernetes works to make reality match that description.

Example: a simplified PVC manifest:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data-disk
  namespace: vm-perf-test
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ocs-storagecluster-ceph-rbd
  resources:
    requests:
      storage: 50Gi
```

This says: "I want a 50Gi block of storage, accessible by one node at a time, backed by the `ocs-storagecluster-ceph-rbd` StorageClass."

### The `oc` CLI

`oc` is the OpenShift command-line tool. It's a superset of `kubectl` (the standard Kubernetes CLI) with additional OpenShift-specific commands. Common commands used in this project:

| Command | What It Does |
|---------|-------------|
| `oc apply -f file.yaml` | Create or update a resource from a YAML file |
| `oc get vm -n vm-perf-test` | List VMs in the test namespace |
| `oc get pvc -n vm-perf-test` | List PVCs (storage claims) |
| `oc get sc` | List StorageClasses in the cluster |
| `oc delete vm <name>` | Delete a VM |
| `oc get pods -l app=vm-perf-test` | List pods matching a label selector |
| `oc describe <resource> <name>` | Show detailed info (useful for debugging) |

## How This Project Uses Kubernetes

The test suite creates and manages Kubernetes resources programmatically:

1. **StorageClasses** and **CephBlockPools** are created to define different storage backends
2. **PVCs** are created to provision storage volumes of various sizes
3. **VMs** (KubeVirt VirtualMachine resources) are created to run fio benchmarks
4. **Labels** on all resources enable targeted cleanup
5. **Namespaces** keep test resources isolated from other cluster workloads

All of this happens through shell scripts that render YAML templates and apply them with `oc apply`.

## Next Steps

- [OpenShift Overview](openshift-overview.md) — How OpenShift extends Kubernetes
- [Storage in Kubernetes](storage-in-kubernetes.md) — PVs, PVCs, and StorageClasses in detail
