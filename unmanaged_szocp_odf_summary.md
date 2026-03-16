# ODF Cluster Description — unmanaged_sz (szocp)

## Cluster Overview

| Property | Value |
|---|---|
| OCP Cluster ID | `c2bd0316-c856-460b-8da5-72ec594de535` |
| Ceph Cluster ID | `07fc6293-842a-4467-b635-6a08122f4795` |
| Health | **HEALTH_OK** |
| OCP Version | 4.20.15 |
| Cluster Type | Compact (3-node control+worker), Bare Metal (NVMe-backed ODF) |
| Node Flavor | 96 vCPU, ~377 GiB RAM per node |
| Node Count | 3 (all control-plane + worker) |
| ODF Version | 4.20.7-rhodf (Rook/Ceph 8, rhceph-8-rhel9, Ceph 19.2.1) |
| Flexible Scaling | `true` |
| Failure Domain | `host` |
| Topology Labels | None (no zone/region labels on nodes) |

## Raw Capacity

| Class | Total | Available | Used | % Used |
|---|---|---|---|---|
| SSD (NVMe) | 70 TiB | 70 TiB | 49 GiB | 0.07% |

Storage device sets: **1 set** (`ocs-deviceset`), **count=24**, **replica=1** = **24 OSDs** backed by `localblock` PVs (2,980 Gi each).

> **Clarification on `replica: 1`:** The device set `replica: 1` controls how the ocs-operator provisions OSDs — each OSD is an independent entry (1 PV per device set). This is **not** the data replication factor. All Ceph pools on this cluster use `size: 3` (3 data copies across 3 hosts), providing full data redundancy. The `flexibleScaling: true` + `replica: 1` approach allows capacity to grow per-host (adding a single node increases ODF capacity), unlike `replica: 3` which scales in triples across failure domains.

| | **ROKS (MZ/SZ)** | **unmanaged_sz** |
|---|---|---|
| Device set replica | 3 (one OSD per failure domain per set) | 1 (each OSD independent) |
| Device set count | 8 (× 3 replicas = 24 OSDs) | 24 (× 1 replica = 24 OSDs) |
| CRUSH failure domain | zone (MZ) / rack (SZ) | host |
| **Pool replication** | **3 copies** | **3 copies** |
| **Data redundancy** | **Yes** | **Yes** |
| Capacity scaling | In triples (across failure domains) | Per-host (add 1 node → more OSDs) |

## Node Topology

| Node | OSDs | OSD IDs |
|---|---|---|
| `szocp-control-0-0` | 8 | 0, 2, 7, 10, 12, 15, 18, 22 |
| `szocp-control-0-1` | 8 | 3, 5, 8, 9, 13, 19, 20, 23 |
| `szocp-control-0-2` | 8 | 1, 4, 6, 11, 14, 16, 17, 21 |

### Topology Summary

The CRUSH tree is flat: `root default → host`. No rack or zone hierarchy exists. Each node has exactly 8 NVMe-backed OSDs (~2.91 TiB each, device class `ssd`). All 24 OSDs are **up** and **in**.

> **Note:** With `flexibleScaling: true` and `failureDomain: host`, losing any single node takes out 8 OSDs (1/3 of the cluster). Data remains available because all pools are replicated ×3 across 3 hosts.

## Ceph Daemons

### Monitors (MON)

| Daemon | Node | Status |
|---|---|---|
| mon.a | `szocp-control-0-2` | Running |
| mon.b | `szocp-control-0-0` | Running |
| mon.c | `szocp-control-0-1` | Running |

Quorum: a, b, c (leader: a). One mon per node for fault isolation.

### Managers (MGR)

| Daemon | Node | Role |
|---|---|---|
| mgr.a | `szocp-control-0-0` | **Active** |
| mgr.b | `szocp-control-0-2` | Standby |

### Metadata Servers (MDS)

| Daemon | Filesystem | Node | Status |
|---|---|---|---|
| cephfilesystem-b | ocs-storagecluster-cephfilesystem | `szocp-control-0-0` | Active |
| cephfilesystem-a | ocs-storagecluster-cephfilesystem | `szocp-control-0-2` | Standby-Replay |

### Rados Gateway (RGW)

1 daemon active (1 host, 1 zone).

## Ceph Pools

| Pool | ID | Type | Size | Min Size | CRUSH Failure Domain | PGs | Stored | Application |
|---|---|---|---|---|---|---|---|---|
| `.mgr` | 1 | Replicated | 3 | 2 | host | 1 | 1.1 MiB | mgr |
| `ocs-storagecluster-cephblockpool` | 2 | Replicated | 3 | 2 | host | 1024 | 14 GiB | rbd |
| `ocs-storagecluster-cephobjectstore.rgw.control` | 3 | Replicated | 3 | 2 | host | 8 | 0 B | rgw |
| `ocs-storagecluster-cephfilesystem-metadata` | 4 | Replicated | 3 | 2 | host | 16 | 49 KiB | cephfs |
| `ocs-storagecluster-cephobjectstore.rgw.meta` | 5 | Replicated | 3 | 2 | host | 8 | 3.2 KiB | rgw |
| `ocs-storagecluster-cephfilesystem-data0` | 6 | Replicated | 3 | 2 | host | 512 | 0 B | cephfs |
| `ocs-storagecluster-cephobjectstore.rgw.log` | 7 | Replicated | 3 | 2 | host | 8 | 30 KiB | rgw |
| `ocs-storagecluster-cephobjectstore.rgw.buckets.index` | 8 | Replicated | 3 | 2 | host | 8 | 6.9 KiB | rgw |
| `ocs-storagecluster-cephobjectstore.rgw.buckets.non-ec` | 9 | Replicated | 3 | 2 | host | 8 | 0 B | rgw |
| `ocs-storagecluster-cephobjectstore.rgw.otp` | 10 | Replicated | 3 | 2 | host | 8 | 0 B | rgw |
| `.rgw.root` | 11 | Replicated | 3 | 2 | host | 8 | 6.3 KiB | rgw |
| `ocs-storagecluster-cephobjectstore.rgw.buckets.data` | 12 | Replicated | 3 | 2 | host | 256 | 0 B | rgw |

**Total PGs:** 1,865 (all `active+clean`)

### Pool Notes

- All pools are OOB (out-of-box, managed by ODF). No custom perf-test pools have been created yet.
- All pools use `host` failure domain with 3-way replication.
- The RGW (object store) is deployed with its full set of pools (control, meta, log, buckets.index, buckets.non-ec, otp, .rgw.root, buckets.data).
- `ocs-storagecluster-cephblockpool` has `targetSizeRatio: 0.49` and 1024 PGs — the primary RBD pool.
- `ocs-storagecluster-cephfilesystem-data0` has `targetSizeRatio: 0.49` and 512 PGs.
- `ocs-storagecluster-cephobjectstore.rgw.buckets.data` has `targetSizeRatio: 0.49` and 256 PGs.

## StorageClasses

### ODF Ceph StorageClasses

| StorageClass | Provisioner | Pool | Type | Features |
|---|---|---|---|---|
| `ocs-storagecluster-ceph-rbd` | rbd.csi.ceph.com | ocs-storagecluster-cephblockpool | RBD | layering, deep-flatten, exclusive-lock, object-map, fast-diff |
| `ocs-storagecluster-ceph-rbd-virtualization` **(default)** | rbd.csi.ceph.com | ocs-storagecluster-cephblockpool | RBD (VM-optimized) | Same + `krbd:rxbounce` mapOptions |
| `ocs-storagecluster-cephfs` | cephfs.csi.ceph.com | cephfilesystem-data0 | CephFS | n/a |
| `ocs-storagecluster-ceph-rgw` | ceph.rook.io/bucket | n/a | Object (RGW) | n/a |

### Other StorageClasses

| StorageClass | Provisioner | Type |
|---|---|---|
| `localblock-sc` | kubernetes.io/no-provisioner | Local NVMe (WaitForFirstConsumer) |
| `openshift-storage.noobaa.io` | noobaa.io/obc | NooBaa Object Bucket |

> **Note:** No IBM Cloud File CSI, Block CSI, or custom perf-test StorageClasses exist on this cluster. This is a self-managed (non-ROKS) cluster without IBM Cloud CSI drivers.

## CRUSH Rules

| Rule | ID | Failure Domain | Used By |
|---|---|---|---|
| `replicated_rule` | 0 | host | Default (unused) |
| `ocs-storagecluster-cephblockpool` | 1 | host | OOB RBD pool |
| `ocs-storagecluster-cephobjectstore.rgw.control` | 2 | host | RGW control pool |
| `ocs-storagecluster-cephfilesystem-metadata` | 3 | host | CephFS metadata pool |
| `.mgr` | 4 | host | Manager pool |
| `ocs-storagecluster-cephobjectstore.rgw.meta` | 5 | host | RGW meta pool |
| `.mgr_host_ssd` | 6 | host | Manager pool (alt) |
| `ocs-storagecluster-cephfilesystem-data0` | 7 | host | CephFS data pool |
| `ocs-storagecluster-cephobjectstore.rgw.log` | 8 | host | RGW log pool |
| `ocs-storagecluster-cephobjectstore.rgw.buckets.index` | 9 | host | RGW buckets index |
| `ocs-storagecluster-cephobjectstore.rgw.buckets.non-ec` | 10 | host | RGW buckets non-EC |
| `ocs-storagecluster-cephobjectstore.rgw.otp` | 11 | host | RGW OTP pool |
| `.rgw.root` | 12 | host | RGW root pool |
| `ocs-storagecluster-cephobjectstore.rgw.buckets.data` | 13 | host | RGW buckets data |

All CRUSH rules use `chooseleaf_firstn` with `type: host` on `default~ssd`. The CRUSH tree has no rack or zone buckets — only `root → host`.

## CephBlockPool and CephFilesystem CRDs

### CephBlockPools

| Name | Status | Replication | Failure Domain |
|---|---|---|---|
| `ocs-storagecluster-cephblockpool` | Ready | size=3 | host |
| `builtin-mgr` | Ready | size=3 | host |

### CephFilesystems

| Name | Status | Data Replication | Metadata Replication |
|---|---|---|---|
| `ocs-storagecluster-cephfilesystem` | Ready | size=3 | size=3 |

## Topology Constraints for Test Pools

With 3 nodes and `failureDomain: host`, the cluster supports:

| Pool Type | Min Failure Domains | Supported? |
|---|---|---|
| rep2 (RBD/CephFS) | 2 hosts | Yes (3 hosts) |
| rep3 (RBD/CephFS) | 3 hosts | Yes (3 hosts) |
| EC 2+1 | 3 hosts | Yes (3 hosts) |
| EC 3+1 | 4 hosts | **No** (only 3 hosts) |
| EC 2+2 | 4 hosts | **No** (only 3 hosts) |
| EC 4+2 | 6 hosts | **No** (only 3 hosts) |

> With only 3 hosts, this cluster is limited to rep2, rep3, and EC 2+1 configurations. The benchmark suite (`01-setup-storage-pools.sh`) will auto-skip EC pools requiring more than 3 failure domains.

## Key Differences from 5-Node BM Cluster

| Property | 5-Node BM (eu-de-1) | szocp (3-Node Compact) |
|---|---|---|
| Cluster type | ROKS managed | Self-managed OCP |
| Nodes | 5 dedicated workers | 3 control+worker (compact) |
| CRUSH topology | root → region → zone → rack → host | root → host (flat) |
| Failure domain | rack (3 racks) | host (3 hosts) |
| Flexible scaling | not set | `true` |
| RGW deployed | No | Yes (1 daemon) |
| IBM Cloud CSI | File CSI available | Not available |
| Zone topology | Single-zone (eu-de-1) | No zone labels |
| EC pool support | Up to EC 2+2 (5 racks/hosts) | Up to EC 2+1 (3 hosts) |
