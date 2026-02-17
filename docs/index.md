# VM Storage Performance Test Suite

[Back to README](../README.md)

This documentation covers everything you need to understand, run, and interpret the VM storage performance benchmarking suite for IBM Cloud ROKS with OpenShift Virtualization.

## Who Is This For?

- **New to Kubernetes/OpenShift?** Start with the [Concepts](#concepts) section.
- **Want to create a custom Ceph pool?** See the [CephBlockPool Setup Guide](guides/ceph-pool-setup.md).
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
6. [Failure Domains and Topology](concepts/failure-domains-and-topology.md) — CRUSH, racks, node placement
7. [OpenShift Virtualization](concepts/openshift-virtualization.md) — Running VMs on Kubernetes
8. [fio Benchmarking](concepts/fio-benchmarking.md) — The I/O testing tool
9. [CephBlockPool Setup](guides/ceph-pool-setup.md) — Creating custom pools (practical, hands-on)
10. [Prerequisites](guides/prerequisites.md) — Setting up your environment
11. [Running Tests](guides/running-tests.md) — Step-by-step walkthrough
12. [Understanding Results](guides/understanding-results.md) — Reading the output

## Concepts

Foundational knowledge for understanding the technology stack.

| Document | What You'll Learn |
|----------|-------------------|
| [Kubernetes Basics](concepts/kubernetes-basics.md) | Clusters, nodes, pods, namespaces, labels, YAML manifests |
| [OpenShift Overview](concepts/openshift-overview.md) | OpenShift vs Kubernetes, operators, IBM Cloud ROKS, bare metal workers |
| [Storage in Kubernetes](concepts/storage-in-kubernetes.md) | PersistentVolumes, PVCs, StorageClasses, CSI, dynamic provisioning |
| [Ceph and ODF](concepts/ceph-and-odf.md) | Ceph architecture, ODF/Rook-Ceph, replicated and erasure-coded pools |
| [Erasure Coding Explained](concepts/erasure-coding-explained.md) | How EC works, storage efficiency, fault tolerance, performance trade-offs |
| [Failure Domains and Topology](concepts/failure-domains-and-topology.md) | CRUSH hierarchy, ROKS rack assignment, node placement, failureDomain options |
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
| [CephBlockPool Setup](guides/ceph-pool-setup.md) | Correct pool configuration, PG autoscaler, OOB-aligned settings |
| [Latency Patterns](guides/latency-patterns.md) | Read/write asymmetry, Ceph vs NFS vs EC tradeoffs, ranking interpretation |
| [Comparing Runs](guides/comparing-runs.md) | End-to-end comparison workflow, delta calculation, A/B testing patterns |
| [Customization](guides/customization.md) | Adding pools, profiles, VM sizes, adjusting parameters |
| [Troubleshooting](guides/troubleshooting.md) | Common failures and how to fix them |
| [VSI Storage Testing Guide](guides/vsi-storage-testing-guide.md) | VSI bandwidth constraints, IOPS tiers, ODF sizing for realistic benchmarks |

## Architecture

Deep-dive into how the test suite works internally.

| Document | What You'll Learn |
|----------|-------------------|
| [Project Architecture](architecture/project-architecture.md) | Design philosophy, script pipeline, library functions, error handling |
| [Test Matrix Explained](architecture/test-matrix-explained.md) | The test matrix dimensions, VM reuse optimization, permutation counting, quick mode |
| [fio Profiles Reference](architecture/fio-profiles-reference.md) | All 6 fio profiles with per-job details and real-world analogies |
| [Parallel Execution](architecture/parallel-execution.md) | Pool-level dispatch, auto-scaling, per-pool isolation, signal handling |
| [Template Rendering](architecture/template-rendering.md) | The fio profile → cloud-init → VM template → oc apply pipeline |
