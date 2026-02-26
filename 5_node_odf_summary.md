# ODF Cluster Description

## Cluster Overview

| Property | Value |
|---|---|
| Cluster ID | `5983315f-83e9-4995-965f-eceea627fe11` |
| Health | **HEALTH_OK** |
| Region / Zone | `eu-de` / `eu-de-1` |
| Cluster Type | Bare Metal (NVMe-backed ODF) |
| Worker Flavor | `bx2d.metal.96x384` (96 vCPU, 384 GiB RAM) |
| Worker Count | 5 |
| ODF Version | Rook/Ceph 8 (RHEL 9 based) |

## Raw Capacity

| Class | Total | Available | Used | % Used |
|---|---|---|---|---|
| SSD (NVMe) | 70 TiB | 70 TiB | 9.0 GiB | 0.01% |

Storage device sets: **1 set** (`ocs-deviceset`), **count=8**, **replica=3** = **24 OSDs** backed by `localblock` PVs (2,980 Gi each).

## Node Topology

| Node (short ID) | Rack | OSDs | OSD IDs |
|---|---|---|---|
| `...00000772` | rack0 | 4 | 0, 9, 15, 21 |
| `...00000b33` | rack0 | 4 | 4, 7, 13, 19 |
| `...000008f9` | rack1 | 4 | 1, 10, 16, 22 |
| `...00000c25` | rack1 | 4 | 3, 6, 12, 18 |
| `...000009d9` | rack2 | 8 | 2, 5, 8, 11, 14, 17, 20, 23 |

### Rack Summary

| Rack | Nodes | OSDs | Weight (TiB) |
|---|---|---|---|
| rack0 | 2 | 8 | 23.3 |
| rack1 | 2 | 8 | 23.3 |
| rack2 | 1 | 8 | 23.3 |

Each OSD is ~2.91 TiB (NVMe, device class `ssd`). All 24 OSDs are **up** and **in**.

> **Note:** rack2 has all 8 OSDs on a single node (`...000009d9`). Losing that node takes out an entire rack/failure domain. Rack0 and rack1 each have 2 nodes, so losing one node in those racks only loses 4 OSDs.

## Ceph Daemons

### Monitors (MON)

| Daemon | Node | Rack | Status |
|---|---|---|---|
| mon.a | `...00000772` | rack0 | Running |
| mon.b | `...000008f9` | rack1 | Running |
| mon.c | `...000009d9` | rack2 | Running |

Quorum: a, c, b. One mon per rack for fault isolation. Mon data stored on hostPath (`/var/lib/rook/mon-<id>/data`).

### Managers (MGR)

| Daemon | Node | Rack | Role |
|---|---|---|---|
| mgr.b | `...00000772` | rack0 | **Active** |
| mgr.a | `...000008f9` | rack1 | Standby |

### Metadata Servers (MDS)

| Daemon | Filesystem | Node | Rack | Status |
|---|---|---|---|---|
| cephfilesystem-a | ocs-storagecluster | `...00000772` | rack0 | Active |
| cephfilesystem-b | ocs-storagecluster | `...000008f9` | rack1 | Hot Standby |
| cephfs-rep2-a | perf-test-cephfs-rep2 | `...000009d9` | rack2 | Active |
| cephfs-rep2-b | perf-test-cephfs-rep2 | `...000009d9` | rack2 | Hot Standby |

## Ceph Pools

| Pool | ID | Type | Size | Min Size | CRUSH Failure Domain | PGs | Stored | Application |
|---|---|---|---|---|---|---|---|---|
| `.nfs` | 2 | Replicated | 3 | 2 | rack | 32 | 16 B | nfs |
| `ocs-storagecluster-cephfilesystem-metadata` | 3 | Replicated | 3 | 2 | rack | 16 | 89 KiB | cephfs |
| `ocs-storagecluster-cephfilesystem-data0` | 4 | Replicated | 3 | 2 | rack | 256 | 0 B | cephfs |
| `perf-test-cephfs-rep2-metadata` | 6 | Replicated | 3 | 2 | host | 16 | 63 KiB | cephfs |
| `perf-test-cephfs-rep2-data0` | 7 | Replicated | 2 | 1 | host | 128 | 0 B | cephfs |
| `perf-test-rep2` | 8 | Replicated | 2 | 1 | host | 128 | 19 B | rbd |
| `.mgr` | 9 | Replicated | 3 | 2 | rack | 32 | 577 KiB | mgr |
| `ocs-storagecluster-cephblockpool` | 10 | Replicated | 3 | 2 | rack | 128 | 2.6 GiB | rbd |

**Total PGs:** 736 (all `active+clean`)

### Pool Notes

- **OOB pools** (out-of-box, managed by ODF): pools 2-4, 9-10. Use `rack` failure domain with 3-way replication.
- **perf-test pools** (created by benchmark suite): pools 6-8. `rep2` uses 2-way replication with `host` failure domain; `cephfs-rep2` metadata pool is still 3-way for safety.
- **Deleted pools**: `perf-test-ec-3-1` (EC 3+1), `perf-test-ec-4-2` (EC 4+2), `perf-test-ec-2-2` (EC 2+2) were removed during cluster recovery. `perf-test-ec-2-1` CRD was also removed. These can be recreated by running `01-setup-storage-pools.sh`.

## StorageClasses

### ODF Ceph StorageClasses

| StorageClass | Provisioner | Pool | Type | Features |
|---|---|---|---|---|
| `ocs-storagecluster-ceph-rbd` | rbd.csi.ceph.com | ocs-storagecluster-cephblockpool | RBD | layering, deep-flatten, exclusive-lock, object-map, fast-diff |
| `ocs-storagecluster-ceph-rbd-virtualization` | rbd.csi.ceph.com | ocs-storagecluster-cephblockpool | RBD (VM-optimized) | Same + `krbd:rxbounce` mapOptions |
| `ocs-storagecluster-ceph-rbd-encrypted` | rbd.csi.ceph.com | ocs-storagecluster-cephblockpool | RBD (encrypted) | layering, deep-flatten, exclusive-lock, object-map, fast-diff |
| `ocs-storagecluster-cephfs` | cephfs.csi.ceph.com | cephfilesystem-data0 | CephFS | n/a |
| `ocs-storagecluster-ceph-nfs` | nfs.csi.ceph.com | n/a | NFS | n/a |

> **Note:** The perf-test custom StorageClasses (`perf-test-sc-rep2`, `perf-test-sc-cephfs-rep2`, EC pool SCs) do not currently exist. They will be recreated by `01-setup-storage-pools.sh`.

### IBM Cloud File CSI StorageClasses

| StorageClass | Profile | IOPS | Binding |
|---|---|---|---|
| `ibmc-vpc-file-500-iops` | dp2 | 500 | Immediate |
| `ibmc-vpc-file-1000-iops` | dp2 | 1,000 | Immediate |
| `ibmc-vpc-file-3000-iops` | dp2 | 3,000 | Immediate |
| `ibmc-vpc-file-min-iops` | dp2 | min | Immediate |
| `ibmc-vpc-file-eit` | dp2 | eit | Immediate |
| `ibmc-vpc-file-metro-*` | dp2 | various | WaitForFirstConsumer |
| `ibmc-vpc-file-retain-*` | dp2 | various | Immediate (Retain) |
| `ibmc-vpc-file-regional*` | rfs | max-bw | Immediate |

> Metro/retain variants produce identical performance on single-zone clusters and are filtered by default in the test suite. Regional (`rfs`) profile requires IBM support allowlisting.

## CRUSH Rules

| Rule | Failure Domain | Used By |
|---|---|---|
| `ocs-storagecluster-cephblockpool` | rack | OOB RBD pool (rep3) |
| `ocs-storagecluster-cephfilesystem-metadata` | rack | OOB CephFS metadata |
| `ocs-storagecluster-cephfilesystem-data0` | rack | OOB CephFS data |
| `.mgr` | rack | Manager pool |
| `.nfs` / `.nfs_rack_ssd` | rack | NFS pool |
| `perf-test-rep2` | host | Custom rep2 RBD pool |
| `perf-test-cephfs-rep2-metadata` | host | Custom CephFS rep2 metadata |
| `perf-test-cephfs-rep2-data0` | host | Custom CephFS rep2 data |
| `replicated_rule` | host | Default (unused) |

Stale CRUSH rules for deleted EC pools (`perf-test-ec-3-1`, `perf-test-ec-4-2`, `perf-test-ec-2-2`) still exist but are unused.

## CephBlockPool and CephFilesystem CRDs

### CephBlockPools

| Name | Status | Replication | Failure Domain |
|---|---|---|---|
| `ocs-storagecluster-cephblockpool` | Ready | size=3 | rack |
| `perf-test-rep2` | Ready | size=2 | host |
| `builtin-mgr` | Ready | size=3 | rack |
| `ocs-storagecluster-cephnfs-builtin-pool` | Ready | size=3 | rack |

### CephFilesystems

| Name | Status | Data Replication | Metadata Replication |
|---|---|---|---|
| `ocs-storagecluster-cephfilesystem` | Ready | size=3 | size=3 |
| `perf-test-cephfs-rep2` | Ready | size=2 | size=3 |

## Topology Constraints for Test Pools

With 5 nodes across 3 racks, the cluster supports:

| Pool Type | Min Failure Domains | Supported? |
|---|---|---|
| rep2 (RBD/CephFS) | 2 hosts | Yes (5 hosts) |
| rep3 (RBD/CephFS) | 3 racks | Yes (3 racks) |
| EC 2+1 | 3 hosts | Yes (5 hosts) |
| EC 3+1 | 4 hosts | Yes (5 hosts) |
| EC 2+2 | 4 hosts | Yes (5 hosts) |
| EC 4+2 | 6 hosts | **No** (only 5 hosts) |

> EC pool CRDs and StorageClasses need to be recreated by running `01-setup-storage-pools.sh`. The script will auto-skip `ec-4-2` due to insufficient hosts.
