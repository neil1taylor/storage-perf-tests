# szocp Cluster Baseline — Storage Performance Testing

**Date:** 2026-04-18
**Cluster:** `szocp.demosz.cloud`
**Kubeconfig:** `/Users/neiltaylor/Projects/vpc_unmanaged_ocp/MZR/szocp/kubeconfig`
**Purpose:** Establish baseline cluster state before running ODF performance tests to determine optimal throughput of a 3-node, 24-OSD Ceph cluster.

---

## Cluster Infrastructure

| Property | Value |
|----------|-------|
| Platform | Self-managed OCP (compact: control-plane + worker) |
| OCP version | 4.20.17 |
| Region / Zone | eu-gb / eu-gb-1 (single-zone) |
| Nodes | 3 |
| Node role | control-plane, master, worker (combined) |
| CPU per node | 96 vCPU (Cascadelake-Server) |
| Memory per node | ~384 GiB (393,669 MiB allocatable) |
| VPC instance type | IBM Cloud VPC VSI (`ibm-cloud.kubernetes.io/vpc-instance-id` present) |
| OS | RHCOS 9.6 (kernel 5.14.0-570.99.1.el9_6) |
| Container runtime | CRI-O 1.33.10 |
| KubeVirt | Installed (cpu-model labels present) |

### Nodes

| Node | Internal IP | Status |
|------|-------------|--------|
| szocp-control-0-0.szocp.demosz.cloud | 10.68.1.4 | Ready |
| szocp-control-0-1.szocp.demosz.cloud | 10.68.1.6 | Ready |
| szocp-control-0-2.szocp.demosz.cloud | 10.68.1.5 | Ready |

---

## ODF / Ceph Configuration

| Property | Value |
|----------|-------|
| ODF version | 4.20.7-rhodf |
| Ceph version | Squid 19.2.1-331 |
| StorageCluster | `ocs-storagecluster` |
| Resource profile | **Balanced** (default — `resourceProfile` not set) |
| Flexible scaling | `true` |
| Failure domain | `host` (`kubernetes.io/hostname`) |
| Total OSDs | 24 (8 per node) |
| OSD device class | SSD |
| OSD backing storage | `localblock-sc` (local block devices) |
| OSD weight | 2.911 TiB each |
| Total raw capacity | ~70 TiB |
| Total used | 161 GiB (0.2%) |
| MONs | 3 (a, b, c) |
| MGRs | 2 (b active, a standby) |
| MDS | 2 (1 active, 1 hot standby) |
| RGW | 1 |

### ODF Resource Profiles

| Profile | OSD CPU request | OSD CPU limit | OSD Memory request | OSD Memory limit |
|---------|----------------|---------------|-------------------|-----------------|
| Lean | 1 | 1 | 2Gi | 2Gi |
| **Balanced** (current) | **1** | **2** | **5Gi** | **5Gi** |
| Performance | 4 | 4 | 8Gi | 8Gi |

Current per-node OSD resource consumption (8 OSDs):
- CPU requested: 8 cores out of 95.5 allocatable (8%)
- Memory requested: 40 GiB out of ~375 GiB allocatable (11%)

**Decision:** Keeping `Balanced` for initial tests to reflect a realistic customer deployment. Performance profile can be tested later as a comparison point to quantify the impact of additional OSD CPU/memory.

---

## Node Resource Utilisation (at rest)

| Node | CPU used | CPU % | Memory used | Memory % |
|------|----------|-------|-------------|----------|
| control-0-0 | 2,314m | 2% | 19,745 MiB | 5% |
| control-0-1 | 2,521m | 2% | 50,184 MiB | 13% |
| control-0-2 | 3,431m | 3% | 50,731 MiB | 13% |

All nodes are lightly loaded. Significant headroom exists for both ODF performance profile upgrade and VM workloads.

---

## CRUSH Topology

```
root default (69.86 TiB)
├── host szocp-control-0-0 (23.29 TiB)
│   └── osd.0, osd.2, osd.7, osd.10, osd.12, osd.15, osd.18, osd.22  (all SSD, 2.91 TiB each)
├── host szocp-control-0-1 (23.29 TiB)
│   └── osd.3, osd.5, osd.8, osd.9, osd.13, osd.19, osd.20, osd.23
└── host szocp-control-0-2 (23.29 TiB)
    └── osd.1, osd.4, osd.6, osd.11, osd.14, osd.16, osd.17, osd.21
```

- CRUSH rule: `chooseleaf_firstn` by `host` on `default~ssd`
- Perfectly balanced: 8 OSDs per host, equal weight
- 3 failure domains (hosts) — supports rep2, rep3, and ec-2-1

---

## Ceph Pools

| Pool | Type | Size | PG count | target_size_ratio | Notes |
|------|------|------|----------|-------------------|-------|
| ocs-storagecluster-cephblockpool | replicated | 3 | 1024 | 0.49 | Main RBD pool |
| ocs-storagecluster-cephfilesystem-metadata | replicated | 3 | 16 | — | CephFS metadata |
| ocs-storagecluster-cephfilesystem-data0 | replicated | 3 | 512 | 0.49 | CephFS data |
| ocs-storagecluster-cephobjectstore.rgw.buckets.data | replicated | 3 | 256 | 0.49 | RGW data |
| .mgr | replicated | 3 | 1 | — | MGR |
| (7 other rgw pools) | replicated | 3 | 8 each | — | RGW metadata |

**Total PGs:** 1,865 across 12 pools, all `active+clean`.
**PGs per OSD:** ~78 average (1,865 PGs x 3 replicas / 24 OSDs = ~233 PG instances / 3 ≈ 78 primary+replica per OSD). Well-distributed.

---

## StorageClasses Available

| StorageClass | Provisioner | Notes |
|--------------|-------------|-------|
| ocs-storagecluster-ceph-rbd | openshift-storage.rbd.csi.ceph.com | Standard RBD |
| ocs-storagecluster-ceph-rbd-virtualization | openshift-storage.rbd.csi.ceph.com | VM-optimized (imageFeatures, rxbounce) |
| ocs-storagecluster-cephfs | openshift-storage.cephfs.csi.ceph.com | CephFS |
| ibmc-vpc-file-500-iops | vpc.file.csi.ibm.io | NFS dp2, 500 IOPS |
| ibmc-vpc-file-1000-iops | vpc.file.csi.ibm.io | NFS dp2, 1000 IOPS |
| ibmc-vpc-file-3000-iops | vpc.file.csi.ibm.io | NFS dp2, 3000 IOPS |
| localblock-sc | kubernetes.io/no-provisioner | OSD backing (local NVMe) |
| ocs-storagecluster-ceph-rgw | openshift-storage.ceph.rook.io/bucket | Object (bucket) |
| openshift-storage.noobaa.io | openshift-storage.noobaa.io/obc | Object (NooBaa) |

---

## Health Warnings at Time of Inspection

```
HEALTH_WARN Slow OSD heartbeats on back (longest 9951ms); Slow OSD heartbeats on front (longest 9951ms)
  osd.5 → osd.9:  9951 ms (both on node szocp-control-0-1)
  osd.9 → osd.10: 2406 ms (node-1 → node-0, possibly improving)
```

**StorageCluster status:** `Progressing` (not Ready — nodes had recently rebooted, OSDs were 12-23 minutes old at time of inspection).

**Action required:** Wait for heartbeat warnings to clear and StorageCluster status to reach `Ready` before running any performance tests. Slow heartbeats will cause latency spikes and invalidate results.

---

## Post-Install Issue: File CSI Caused Kubelet Stale State

The IBM VPC File CSI driver installation (`vpc.file.csi.ibm.io`, installed 2026-04-18) triggered node restarts. The kubelets came back with stale `volumesInUse` entries — volumes listed as in-use that had no corresponding VolumeAttachment. This blocked the attach/detach controller from processing any new volume mount requests cluster-wide.

**Symptoms:** Pods with RBD PVCs stuck in `ContainerCreating`/`Pending` indefinitely. No VolumeAttachment objects created. No mount-related events from kubelet. 4 pre-existing VMs (vm-05, vm-15a, vm-19a, vm-20a) stuck in `Init:0/1`, compounding the stale state.

**Root cause:** Kubelet `volumesInUse` list contained ghost entries from pre-reboot volumes that were no longer attached.

**Fix:** Restart all 3 kubelets via `oc debug node/<name> -- chroot /host systemctl restart kubelet`. This cleared the stale state and restored volume attachment functionality.

**Also observed:** KCM (kube-controller-manager) was overwhelmed by a `storageclient-status-reporter` cronjob and `ocs-metrics-exporter` deployment sync error loop (every-minute cronjob + continuous conflict retries). This was not the root cause but may have delayed recovery. The `kubemacpool` webhook was also timing out, preventing `virtctl stop` commands.

---

## Test Results

### Test 1: Pod-Level Baseline (krbd, no QEMU)

**Date:** 2026-04-18
**Pool:** rep3-virt (`ocs-storagecluster-ceph-rbd-virtualization`)
**Run ID:** perf-20260418-130100
**Settings:** runtime=60s, ramp=10s, iodepth=32, numjobs=4, size=4G, PVC=150Gi

| Test | Read IOPS | Read BW | Read Latency | Write IOPS | Write BW | Write Latency |
|------|-----------|---------|--------------|------------|----------|---------------|
| Random 4k | 116,196 | 454 MiB/s | 1.07 ms | 36,413 | 142 MiB/s | 3.45 ms |
| Sequential 1M | 10,127 | 10.1 GB/s | 12.56 ms | 3,594 | 3.6 GB/s | 35.23 ms |
| Mixed 70/30 4k | 47,185 | 184 MiB/s | 1.64 ms | 20,254 | 79 MiB/s | 2.37 ms |

**Key observations:**
- 116k random read IOPS at ~1ms — strong single-client ceiling for 24 OSDs
- 10 GB/s sequential read likely saturates the inter-node network
- Write latency ~3x read latency — expected with 3-replica synchronous ack
- Mixed workload shows 67k total IOPS (47k read + 20k write) — reads dominate as expected at 70/30 ratio

This is the **raw Ceph + krbd baseline** without QEMU/virtio overhead. The delta between these numbers and the VM-level results (Test 2) will quantify the virtualisation cost.

---

## Context: Previous NFS vs ODF Test Results

Previous tests on a different cluster (200 VMs, rate-limited, 70/30 random r/w) showed:

| Metric | NFS Zonal (dp2) | ODF 3-replica | NFS Regional (rfs) |
|--------|-----------------|---------------|---------------------|
| Latency @ 100k IOPS | 0.90 ms | 4.90 ms | 55.79 ms |
| Latency @ 200k IOPS | 1.34 ms | 22.80 ms | 79.13 ms |
| Latency std dev | 2.60 ms | 115.91 ms | 9.60 ms |

ODF latency increased ~5x when load doubled (100k → 200k IOPS), while NFS Zonal increased only ~1.5x. Key factors:
- **Shared contention:** 200 VMs sharing a small number of OSDs vs isolated NFS shares
- **Write amplification:** 3-replica writes = 3x backend I/O
- **OSD saturation:** At ~22k IOPS/OSD, Ceph software overhead (PG locking, replication acks) dominates

The szocp cluster's 24 OSDs should spread load much better (~8.3k IOPS/OSD at 200k total), but the previous cluster had far fewer OSDs.

---

## Proposed Performance Test Plan

### Objective
Determine the maximum sustainable IOPS and throughput of this 24-OSD cluster, and identify where the performance ceiling is (NVMe, Ceph software, network, QEMU).

### Pre-requisites
- [ ] StorageCluster status is `Ready` (no `Progressing`)
- [ ] No `HEALTH_WARN` for slow OSD heartbeats
- [ ] Consider switching to `performance` resource profile
- [ ] Confirm KubeVirt / OpenShift Virtualization operator is healthy

### Test 1: Layer isolation (establish baselines)

Run the same fio workload at different points in the I/O stack:

| Layer | Method | Measures |
|-------|--------|----------|
| Raw Ceph (krbd) | fio in a Pod with RBD PVC (pod-level test) | Ceph + kernel RBD, no QEMU |
| KubeVirt VM | fio in VM (standard test) | Full stack including QEMU/virtio |

Compare results to quantify QEMU/virtio overhead.

### Test 2: Single VM ceiling (uncapped)

One VM, no IOPS rate limit, sweep queue depth to find the knee of the latency curve:

```
iodepth: 1, 4, 8, 16, 32, 64, 128
rw: randread, randwrite, randrw(70/30)
bs: 4k
direct=1, numjobs=1
```

### Test 3: Sequential throughput ceiling

Large block sequential I/O to measure raw bandwidth:

```
VMs: 1, then scale
bs: 1M
rw: read, write
iodepth: 16-32
```

24 NVMe OSDs should deliver multiple GB/s aggregate.

### Test 4: VM scaling curve

Add VMs incrementally to find where IOPS plateau and latency degrades:

```
VMs: 1, 5, 10, 25, 50, 100, 150, 200
rate_iops: uncapped
bs: 4k, 128k, 1M
rw: randrw(70/30)
```

The inflection point is the cluster's practical capacity.

### Test 5: Replication impact (uncapped)

Compare rep2 vs rep3 to quantify replication cost:

```
pools: rep2, rep3
VMs: 1
rw: randwrite
bs: 4k
iodepth: 1, 4, 16, 32
```

### Test 6: PG count tuning

Test with explicitly set PG counts on a custom pool:

```
pgCount: 32, 64, 128, 256
Same fio params as Test 2
```

### Recommended execution order

1. **Test 1** — layer baselines (Pod vs VM)
2. **Test 2** — single-VM ceiling
3. **Test 5** — rep2 vs rep3 (tuning insight)
4. **Test 3** — sequential throughput
5. **Test 4** — VM scaling curve (longest, run last)
6. **Test 6** — PG tuning (optional, if bottleneck suspected)

### Key output

A **latency vs IOPS curve** for the cluster, showing exactly what the 3-node / 24-OSD cluster can deliver and where the limits are.
