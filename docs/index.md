# VM Storage Performance Test Suite

[Back to README](../README.md)

This documentation covers everything you need to understand, run, and interpret the VM storage performance benchmarking suite for IBM Cloud ROKS with OpenShift Virtualization.

## Who Is This For?

- **New to Kubernetes/OpenShift?** Start with the [Concepts](#concepts) section.
- **Ready to run tests?** Jump to the [Guides](#guides) section.
- **Want to understand the code?** See the [Architecture](#architecture) section.
- **Looking up a term?** Check the [Glossary](glossary.md).

## Suggested Reading Path

If you're new to the technology stack, we recommend reading in this order:

1. [Kubernetes Basics](concepts/kubernetes-basics.md) — Clusters, pods, namespaces
2. [OpenShift Overview](concepts/openshift-overview.md) — OpenShift vs Kubernetes, ROKS
3. [Storage in Kubernetes](concepts/storage-in-kubernetes.md) — PVs, PVCs, StorageClasses
4. [Ceph and ODF](concepts/ceph-and-odf.md) — The storage backend
5. [Erasure Coding Explained](concepts/erasure-coding-explained.md) — EC vs replication
6. [OpenShift Virtualization](concepts/openshift-virtualization.md) — Running VMs on Kubernetes
7. [fio Benchmarking](concepts/fio-benchmarking.md) — The I/O testing tool
8. [Prerequisites](guides/prerequisites.md) — Setting up your environment
9. [Running Tests](guides/running-tests.md) — Step-by-step walkthrough
10. [Understanding Results](guides/understanding-results.md) — Reading the output

## Concepts

Foundational knowledge for understanding the technology stack.

| Document | What You'll Learn |
|----------|-------------------|
| [Kubernetes Basics](concepts/kubernetes-basics.md) | Clusters, nodes, pods, namespaces, labels, YAML manifests |
| [OpenShift Overview](concepts/openshift-overview.md) | OpenShift vs Kubernetes, operators, IBM Cloud ROKS, bare metal workers |
| [Storage in Kubernetes](concepts/storage-in-kubernetes.md) | PersistentVolumes, PVCs, StorageClasses, CSI, dynamic provisioning |
| [Ceph and ODF](concepts/ceph-and-odf.md) | Ceph architecture, ODF/Rook-Ceph, replicated and erasure-coded pools |
| [Erasure Coding Explained](concepts/erasure-coding-explained.md) | How EC works, storage efficiency, fault tolerance, performance trade-offs |
| [OpenShift Virtualization](concepts/openshift-virtualization.md) | KubeVirt, VMs on Kubernetes, DataVolumes, cloud-init, virtctl |
| [fio Benchmarking](concepts/fio-benchmarking.md) | fio parameters, I/O patterns, IOPS, bandwidth, latency metrics |

## Guides

Practical how-to documentation for running and customizing the test suite.

| Document | What You'll Learn |
|----------|-------------------|
| [Prerequisites](guides/prerequisites.md) | Cluster setup, CLI tools, operator installation, verification |
| [Configuration Reference](guides/configuration-reference.md) | Every parameter in `00-config.sh` fully documented |
| [Running Tests](guides/running-tests.md) | Step-by-step test execution walkthrough |
| [Understanding Results](guides/understanding-results.md) | Reading fio JSON, CSV columns, HTML dashboard, analysis tips |
| [Customization](guides/customization.md) | Adding pools, profiles, VM sizes, adjusting parameters |
| [Troubleshooting](guides/troubleshooting.md) | Common failures and how to fix them |

## Architecture

Deep-dive into how the test suite works internally.

| Document | What You'll Learn |
|----------|-------------------|
| [Project Architecture](architecture/project-architecture.md) | Design philosophy, script pipeline, library functions, error handling |
| [Test Matrix Explained](architecture/test-matrix-explained.md) | The test matrix dimensions, VM reuse optimization, permutation counting, quick mode |
| [fio Profiles Reference](architecture/fio-profiles-reference.md) | All 6 fio profiles with per-job details and real-world analogies |
| [Template Rendering](architecture/template-rendering.md) | The fio profile → cloud-init → VM template → oc apply pipeline |
