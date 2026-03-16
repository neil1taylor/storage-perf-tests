# ODF Cluster Comparison: Multi-Zone vs Single-Zone vs Unmanaged Single-Zone

**Date:** 2026-03-16
**Compared clusters:**
- **MZ:** `ocp-virt-mz-cluster` — ROKS managed, multi-zone, us-south (3 AZs)
- **SZ:** `ocp-virt-420-cluster` — ROKS managed, single-zone, eu-de-1
- **unmanaged_sz:** `szocp` — self-managed OCP, single-zone (no zone labels), 3-node compact

---

## Cluster Infrastructure

| Property | **MZ** (ocp-virt-mz-cluster) | **SZ** (ocp-virt-420-cluster) | **unmanaged_sz** (szocp) |
|---|---|---|---|
| Platform | ROKS managed | ROKS managed | Self-managed OCP |
| Region | us-south | eu-de | n/a (no topology labels) |
| Zones | 3 (us-south-1, -2, -3) | 1 (eu-de-1) | 0 (no zone labels) |
| Workers | 3 (1 per zone) | 3 (all same zone) | 3 (compact: control+worker) |
| Instance type | bx2d.metal.96x384 | bx2d.metal.96x384 | 96 vCPU, ~377 GiB RAM (BM/NVMe) |
| OCP version | v1.33.6 | v1.33.6 | 4.20.15 |
| ODF version | 4.19.10 | 4.19.10 | 4.20.7-rhodf |
| Ceph version | Squid 19.2.1-292 | Squid 19.2.1-292 | Squid 19.2.1-331 |

MZ and SZ use identical bare-metal hardware (96 vCPU, 384 GiB RAM per node) and identical ODF/Ceph software versions. unmanaged_sz is a self-managed OCP compact cluster with similar hardware but newer OCP/ODF versions and Ceph build.

---

## ODF / StorageCluster Configuration

| Property | **MZ** | **SZ** | **unmanaged_sz** |
|---|---|---|---|
| StorageCluster phase | Ready | Ready | Ready |
| Device set count | 8 | 8 | 24 |
| Device set replica | 3 | 3 | 1 |
| **Total OSDs** | **24** | **24** | **24** |
| OSDs per node | 8 | 8 | 8 |
| OSD size | 2980 GiB (NVMe) | 2980 GiB (NVMe) | 2980 GiB (NVMe) |
| Raw capacity | ~70 TiB | ~70 TiB | ~70 TiB |
| Device class | SSD | SSD | SSD |
| Resource profile | balanced | balanced | balanced |
| Flexible scaling | not set | not set | `true` |
| CRUSH failure domain | zone | rack | host |
| Pool replication | 3 copies | 3 copies | 3 copies |
| Capacity scaling | In triples (across failure domains) | In triples (across failure domains) | Per-host (add 1 node → more OSDs) |

> **Clarification on `replica` vs replication:** The device set `replica` field controls how the ocs-operator provisions OSDs — on ROKS, `replica: 3` means each device set spans 3 failure domains (zone or rack), so capacity grows in triples. On unmanaged_sz, `replica: 1` with `flexibleScaling: true` means each OSD is independent, allowing capacity to grow by adding a single host. In both cases, **data redundancy is identical** — all Ceph pools use `size: 3` (3 data copies across 3 hosts/racks/zones). The device set replica is an OSD provisioning model, not a data replication factor.

### Encryption

| Property | **MZ** | **SZ** | **unmanaged_sz** |
|---|---|---|---|
| Cluster-wide encryption | yes | yes | no |
| StorageClass encryption | yes | yes | no |
| Network encryption (msgr2) | yes | yes | no |
| KMS provider | IBM Key Protect (us-south) | IBM Key Protect (eu-de) | n/a |
| Key rotation | weekly | weekly | n/a |
| CephFS kernel mount | ms_mode=secure | ms_mode=secure | default |

### CSI Features

| Property | **MZ** | **SZ** | **unmanaged_sz** |
|---|---|---|---|
| Read affinity | enabled | enabled | not configured |
| Skip user creation | true | true | not configured |

---

## Failure Domain & CRUSH Topology

This is the **primary architectural difference** between the clusters.

| Property | **MZ** | **SZ** | **unmanaged_sz** |
|---|---|---|---|
| **failureDomain** | **zone** | **rack** | **host** |
| failureDomainKey | `topology.kubernetes.io/zone` | `topology.rook.io/rack` | n/a |
| failureDomainValues | us-south-1, us-south-2, us-south-3 | rack0, rack1, rack2 | szocp-control-0-{0,1,2} |
| **Failure domain count** | **3 zones** | **3 racks** | **3 hosts** |
| Replicas survive | Full AZ outage | Single rack/host outage | Single host outage |
| Mon anti-affinity | `topology.kubernetes.io/zone` | `topology.rook.io/rack` | host (implicit) |
| MDS anti-affinity | `topology.kubernetes.io/zone` | `topology.rook.io/rack` | host (implicit) |
| CRUSH hierarchy | root→region→zone→host | root→region→zone→rack→host | root→host (flat) |

### CRUSH Tree: MZ Cluster

```
root default (69.9 TiB)
└── region us-south
    ├── zone us-south-1
    │   └── host ...000006e5
    │       └── osd.1, osd.4, osd.6, osd.9, osd.13, osd.16, osd.18, osd.21
    ├── zone us-south-2
    │   └── host ...00000272
    │       └── osd.0, osd.5, osd.8, osd.11, osd.14, osd.17, osd.20, osd.23
    └── zone us-south-3
        └── host ...000004ef
            └── osd.2, osd.3, osd.7, osd.10, osd.12, osd.15, osd.19, osd.22
```

**Key:** No rack tier in the CRUSH hierarchy. Workers are directly under their zone. The ocs-operator omits the `rack` bucket when `failureDomain=zone`.

### CRUSH Tree: SZ Cluster

```
root default (69.9 TiB)
└── region eu-de
    └── zone eu-de-1
        ├── rack rack0
        │   └── host ...00000772
        │       └── osd.0, osd.4, osd.7, osd.9, osd.13, osd.15, osd.19, osd.21
        ├── rack rack1
        │   └── host ...000008f9
        │       └── osd.1, osd.3, osd.6, osd.10, osd.12, osd.16, osd.18, osd.22
        └── rack rack2
            └── host ...000009d9
                └── osd.2, osd.5, osd.8, osd.11, osd.14, osd.17, osd.20, osd.23
```

**Key:** Single zone with synthetic rack labels. Each worker gets its own rack bucket.

### CRUSH Tree: unmanaged_sz Cluster

```
root default (69.9 TiB)
├── host szocp-control-0-0
│   └── osd.0, osd.2, osd.7, osd.10, osd.12, osd.15, osd.18, osd.22
├── host szocp-control-0-1
│   └── osd.3, osd.5, osd.8, osd.9, osd.13, osd.19, osd.20, osd.23
└── host szocp-control-0-2
    └── osd.1, osd.4, osd.6, osd.11, osd.14, osd.16, osd.17, osd.21
```

**Key:** Flat CRUSH tree with no region, zone, or rack buckets. `flexibleScaling: true` with `failureDomain: host`. Each compact node (combined control-plane + worker) has 8 NVMe-backed OSDs.

---

## Ceph Pools

### MZ Cluster (5 pools, 848 PGs)

| Pool | Type | Size | Crush Rule | PGs | Target Ratio | Notes |
|---|---|---|---|---|---|---|
| .mgr | rep | 3 | 13 | 32 | — | Manager pool |
| .nfs | rep | 3 | 15 | 32 | — | NFS-Ganesha pool |
| cephfilesystem-metadata | rep | 3 | 12 | 16 | — | CephFS metadata, bias=4 |
| cephfilesystem-data0 | rep | 3 | 14 | 512 | 0.49 | CephFS data |
| cephblockpool | rep | 3 | 11 | 256 | 0.49 | OOB RBD block pool |

### SZ Cluster (9 pools, 768 PGs)

| Pool | Type | Size | Crush Rule | PGs | Target Ratio | Notes |
|---|---|---|---|---|---|---|
| .mgr | rep | 3 | 8 | 32 | — | Manager pool |
| .nfs | rep | 3 | 11 | 32 | — | NFS-Ganesha pool |
| cephfilesystem-metadata | rep | 3 | 2 | 16 | — | CephFS metadata, bias=4 |
| cephfilesystem-data0 | rep | 3 | 3 | 256 | 0.49 | CephFS data |
| cephblockpool | rep | 3 | 9 | 128 | 0.49 | OOB RBD block pool |
| perf-test-rep2 | rep | 2 | 7 | 128 | 0.10 | Custom (failureDomain=host) |
| perf-test-ec-2-1 | EC 2+1 | 3 | 13 | 32 | 0.10 | Custom (failureDomain=host) |
| perf-test-cephfs-rep2-metadata | rep | 3 | 5 | 16 | — | Custom CephFS metadata |
| perf-test-cephfs-rep2-data0 | rep | 2 | 6 | 128 | 0.10 | Custom CephFS data |

### unmanaged_sz Cluster (12 pools, 1865 PGs)

| Pool | Type | Size | Crush Rule | PGs | Target Ratio | Notes |
|---|---|---|---|---|---|---|
| .mgr | rep | 3 | 4/6 | 1 | — | Manager pool |
| cephblockpool | rep | 3 | 1 | 1024 | 0.49 | OOB RBD block pool |
| cephfilesystem-metadata | rep | 3 | 3 | 16 | — | CephFS metadata |
| cephfilesystem-data0 | rep | 3 | 7 | 512 | 0.49 | CephFS data |
| rgw.control | rep | 3 | 2 | 8 | — | RGW control pool |
| rgw.meta | rep | 3 | 5 | 8 | — | RGW meta pool |
| rgw.log | rep | 3 | 8 | 8 | — | RGW log pool |
| rgw.buckets.index | rep | 3 | 9 | 8 | — | RGW buckets index |
| rgw.buckets.non-ec | rep | 3 | 10 | 8 | — | RGW buckets non-EC |
| rgw.otp | rep | 3 | 11 | 8 | — | RGW OTP pool |
| .rgw.root | rep | 3 | 12 | 8 | — | RGW root pool |
| rgw.buckets.data | rep | 3 | 13 | 256 | 0.49 | RGW buckets data |

**Notes:**
- MZ and SZ have custom perf-test pools. unmanaged_sz has only OOB pools (no custom perf-test pools yet).
- unmanaged_sz has RGW (Rados Gateway) deployed with 7 pools, not present on MZ/SZ.
- unmanaged_sz has no `.nfs` pool.
- All unmanaged_sz pools use `failureDomain: host` with flat CRUSH (no rack/zone).

### PG Distribution Comparison (OOB pools only)

| Pool | **MZ PGs** | **SZ PGs** | **unmanaged_sz PGs** |
|---|---|---|---|
| Blockpool | **256** | 128 | **1024** |
| CephFS data0 | **512** | 256 | **512** |
| CephFS metadata | 16 | 16 | 16 |
| .mgr | 32 | 32 | 1 |
| .nfs | 32 | 32 | — |
| RGW pools (all) | — | — | 304 |
| **Total (OOB)** | **848** | **476** | **1857** |
| **Total (all)** | **848** | **768** | **1865** |

The MZ cluster's PG autoscaler has assigned more PGs to the OOB pools because there are no custom pools consuming `target_size_ratio`. On the SZ cluster, the custom pools with `target_size_ratio: 0.1` reduce the effective ratio for the OOB pools from 0.49 to ~0.38, resulting in fewer PGs. The unmanaged_sz cluster has the highest PG count due to the blockpool having 1024 PGs and the additional RGW pool PGs; no custom pools have been created to compete for PG allocation.

---

## CephBlockPool CRDs

### MZ Cluster

| Pool | failureDomain | Replica Size | EC Data/Code | Target Ratio |
|---|---|---|---|---|
| builtin-mgr | zone | 3 | 0/0 | — |
| ocs-storagecluster-cephblockpool | zone | 3 | 0/0 | 0.49 |
| ocs-storagecluster-cephnfs-builtin-pool | zone | 3 | 0/0 | — |

### SZ Cluster

| Pool | failureDomain | Replica Size | EC Data/Code | Target Ratio |
|---|---|---|---|---|
| builtin-mgr | rack | 3 | 0/0 | — |
| ocs-storagecluster-cephblockpool | rack | 3 | 0/0 | 0.49 |
| ocs-storagecluster-cephnfs-builtin-pool | rack | 3 | 0/0 | — |
| perf-test-rep2 | host | 2 | 0/0 | 0.10 |
| perf-test-ec-2-1 | host | 0 | 2/1 | — |

### unmanaged_sz Cluster

| Pool | failureDomain | Replica Size | EC Data/Code | Target Ratio |
|---|---|---|---|---|
| builtin-mgr | host | 3 | 0/0 | — |
| ocs-storagecluster-cephblockpool | host | 3 | 0/0 | 0.49 |

**Note:** Custom pools on SZ use `failureDomain: host` (finer-grained than the cluster-level `rack`). On MZ, custom pools use `failureDomain: zone` to match the cluster-level setting. unmanaged_sz uses `failureDomain: host` cluster-wide (flat CRUSH, no rack/zone). unmanaged_sz has no NFS builtin pool and no custom perf-test pools yet.

---

## CephFilesystems

| Filesystem | **MZ** | **SZ** | **unmanaged_sz** |
|---|---|---|---|
| OOB (ocs-storagecluster-cephfilesystem) | Ready | Ready | Ready |
| perf-test-cephfs-rep2 | — (not created) | Ready | — (not created) |
| MDS count | 1 active + 1 standby | 2 active + 2 standby | 1 active + 1 standby-replay |

---

## StorageClasses

### ODF StorageClasses

| StorageClass | Provisioner | **MZ** | **SZ** | **unmanaged_sz** |
|---|---|---|---|---|
| ocs-storagecluster-ceph-rbd | rbd.csi.ceph.com | yes | yes | yes |
| ocs-storagecluster-ceph-rbd-virtualization | rbd.csi.ceph.com | yes | yes | yes (default) |
| ocs-storagecluster-ceph-rbd-encrypted | rbd.csi.ceph.com | yes | yes | no |
| ocs-storagecluster-cephfs | cephfs.csi.ceph.com | yes | yes | yes |
| ocs-storagecluster-ceph-nfs | nfs.csi.ceph.com | yes | yes | no |
| ocs-storagecluster-ceph-rgw | ceph.rook.io/bucket | no | no | yes |
| localblock-sc | kubernetes.io/no-provisioner | no | no | yes |
| openshift-storage.noobaa.io | noobaa.io/obc | yes | yes | yes |

### StorageClass Parameters

**RBD (ocs-storagecluster-ceph-rbd):** Identical on all three clusters.
- `imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff`
- `imageFormat: 2`
- `pool: ocs-storagecluster-cephblockpool`
- No `mapOptions` or `mounter` set

**RBD Virtualization (ocs-storagecluster-ceph-rbd-virtualization):** Identical on all three clusters.
- Same as above, plus:
- `mapOptions: krbd:rxbounce`
- `mounter: rbd`

**CephFS (ocs-storagecluster-cephfs):** Identical on all three clusters.
- `fsName: ocs-storagecluster-cephfilesystem`

### IBM Cloud CSI StorageClasses (SZ only)

The SZ cluster also has IBM Cloud File CSI StorageClasses that are not present on the MZ or unmanaged_sz clusters:
- `ibmc-vpc-file-500-iops`, `ibmc-vpc-file-1000-iops`, `ibmc-vpc-file-3000-iops`
- `ibmc-vpc-file-eit`, `ibmc-vpc-file-min-iops`
- Metro/retain/regional variants
- Pool CSI: `bench-pool`, `ibm-vpc-file-pool`

The MZ cluster has **no IBM Cloud CSI StorageClasses** — `02-setup-file-storage.sh` and `03-setup-block-storage.sh` have not been run yet. The unmanaged_sz cluster is self-managed (non-ROKS) and has **no IBM Cloud CSI drivers** installed.

### Custom Perf-Test StorageClasses (SZ only)

| StorageClass | Provisioner |
|---|---|
| perf-test-sc-rep2 | rbd.csi.ceph.com |
| perf-test-sc-ec-2-1 | rbd.csi.ceph.com |
| perf-test-sc-cephfs-rep2 | cephfs.csi.ceph.com |

Present on SZ only. No custom perf-test StorageClasses exist on MZ or unmanaged_sz yet.

---

## Ceph Cluster Health

| Metric | **MZ** | **SZ** | **unmanaged_sz** |
|---|---|---|---|
| Health | HEALTH_OK | HEALTH_OK | HEALTH_OK |
| MON daemons | 3 (quorum a,b,c) | 3 (quorum a,c,b) | 3 (quorum a,b,c) |
| MGR daemons | 2 (a active, b standby) | 2 (b active, a standby) | 2 (a active, b standby) |
| MDS daemons | 1 active + 1 standby | 2 active + 2 standby | 1 active + 1 standby-replay |
| RGW daemons | — | — | 1 active |
| OSD count | 24 up, 24 in | 24 up, 24 in | 24 up, 24 in |
| OSD uptime | ~12 min (just scaled up) | 4 days | — |
| Total pools | 5 | 9 | 12 |
| Total PGs | 848 (all active+clean) | 768 (all active+clean) | 1865 (all active+clean) |
| Objects | 58 | 6,140 | — |
| Data stored | 613 KiB | 23 GiB | 14 GiB |
| Raw used | 1.4 GiB | 85 GiB | — |
| Raw available | ~70 TiB | ~70 TiB | ~70 TiB |
| CephFS volumes | 1/1 healthy | 2/2 healthy | 1/1 healthy |

---

## OSD Distribution

### MZ Cluster

| Zone | Host | OSDs | PGs/OSD range | Weight |
|---|---|---|---|---|
| us-south-1 | ...000006e5 | 8 (osd.1,4,6,9,13,16,18,21) | 100-114 | 23.3 TiB |
| us-south-2 | ...00000272 | 8 (osd.0,5,8,11,14,17,20,23) | 93-113 | 23.3 TiB |
| us-south-3 | ...000004ef | 8 (osd.2,3,7,10,12,15,19,22) | 99-116 | 23.3 TiB |
| **Total** | | **24** | MIN/MAX VAR: 0.68/2.46 | **69.9 TiB** |

### SZ Cluster

| Rack | Host | OSDs | PGs/OSD range | Weight |
|---|---|---|---|---|
| rack0 | ...00000772 | 8 (osd.0,4,7,9,13,15,19,21) | 79-95 | 23.3 TiB |
| rack1 | ...000008f9 | 8 (osd.1,3,6,10,12,16,18,22) | 77-91 | 23.3 TiB |
| rack2 | ...000009d9 | 8 (osd.2,5,8,11,14,17,20,23) | 76-93 | 23.3 TiB |
| **Total** | | **24** | MIN/MAX VAR: 0.77/1.16 | **69.9 TiB** |

### unmanaged_sz Cluster

| Host | OSDs | OSD IDs | Weight |
|---|---|---|---|
| szocp-control-0-0 | 8 | osd.0, 2, 7, 10, 12, 15, 18, 22 | 23.3 TiB |
| szocp-control-0-1 | 8 | osd.3, 5, 8, 9, 13, 19, 20, 23 | 23.3 TiB |
| szocp-control-0-2 | 8 | osd.1, 4, 6, 11, 14, 16, 17, 21 | 23.3 TiB |
| **Total** | **24** | | **69.9 TiB** |

**Note:** The MZ cluster shows higher VAR (0.68–2.46) because it was just scaled from 3→24 OSDs and the PG distribution hasn't fully rebalanced yet. The original 3 OSDs (0, 1, 2) still hold more metadata. This will equalize over time. The unmanaged_sz cluster has perfectly balanced OSD distribution (8 per node) with a flat CRUSH tree.

---

## Performance Implications

### Cross-AZ Latency (MZ)
- **Writes:** Each replicated write must wait for acknowledgment from replicas in different AZs. Inter-AZ latency within us-south is typically 0.5–2ms RTT, which directly adds to write latency compared to the SZ cluster where all replicas are on the same LAN segment.
- **Reads:** Read affinity (`csi.readAffinity.enabled: true`) means reads are served from the local-zone OSD replica, so read latency should be comparable to SZ.

### Compact Cluster Considerations (unmanaged_sz)
- **No rack isolation:** With `failureDomain: host` and a flat CRUSH tree (root→host), there is no rack-level fault isolation. Losing one node loses 1/3 of the cluster, but data remains available via the other 2 replicas.
- **Control-plane co-location:** All 3 nodes run both control-plane and worker workloads. API server, etcd, and scheduler compete with OSD and benchmark VMs for CPU/memory. This may introduce performance variability not seen on dedicated-worker clusters.
- **No encryption overhead:** Unlike MZ/SZ, unmanaged_sz has no data-at-rest or in-transit encryption, which should result in lower CPU overhead for I/O operations.
- **No read affinity:** CSI read affinity is not configured. Reads may be served from any OSD replica, though with only 3 hosts on the same LAN segment, the impact is minimal.
- **RGW overhead:** RGW daemon is active and its 7 pools consume 304 PGs. This adds a small background load not present on MZ/SZ, though all RGW pools are essentially empty.
- **Higher PG count:** The blockpool has 1024 PGs (vs 256 on MZ, 128 on SZ), which may provide better load distribution across OSDs for RBD workloads.

### EC Pool Constraints
- All three clusters have exactly 3 failure domains (3 zones on MZ, 3 racks on SZ, 3 hosts on unmanaged_sz).
- EC pools requiring ≤3 failure domains work (ec-2-1 needs 3). EC pools needing >3 (ec-3-1, ec-2-2, ec-4-2) will be automatically skipped.
- Custom pools on MZ must use `failureDomain: zone`, on SZ `failureDomain: host` (or `rack`), and on unmanaged_sz `failureDomain: host`.

### PG Rebalancing
- The MZ cluster was just scaled from 3→24 OSDs. PG rebalancing to the new OSDs completes rapidly since the cluster is nearly empty (603 KiB of data). All 848 PGs are already active+clean.
- The PG autoscaler has scaled up: blockpool 64→256 PGs, CephFS data 128→512 PGs, appropriate for 24 OSDs.

### Network Encryption Overhead
MZ and SZ have identical encryption settings (msgr2 secure mode, KMS-backed OSD encryption). The encryption overhead is the same, but on MZ the cross-AZ traffic traverses the IBM Cloud backbone which may have different bandwidth characteristics than the intra-rack NVMe-over-TCP fabric. unmanaged_sz has no encryption, eliminating this overhead entirely.

---

## Summary: What's Identical Across All Three

- OSD count: 24 (8 per node)
- Raw capacity: ~70 TiB
- NVMe-backed OSDs (~2980 GiB each)
- 3 failure domains (zone/rack/host)
- OOB RBD StorageClass parameters (imageFeatures, mapOptions)

## Summary: What's Identical Between MZ and SZ Only

- Hardware: bx2d.metal.96x384 x 3 nodes
- Software: OCP v1.33.6, ODF 4.19.10, Ceph Squid 19.2.1-292
- Encryption: Full (data-at-rest + in-transit + KMS)
- Resource profile: balanced
- ROKS managed platform

## Summary: What's Different

| Aspect | **MZ** | **SZ** | **unmanaged_sz** |
|---|---|---|---|
| Platform | ROKS managed | ROKS managed | Self-managed OCP |
| OCP/ODF version | v1.33.6 / 4.19.10 | v1.33.6 / 4.19.10 | 4.20.15 / 4.20.7-rhodf |
| Failure domain | **zone** (cross-AZ) | rack (intra-zone) | host (flat CRUSH) |
| CRUSH hierarchy | root→region→zone→host | root→region→zone→rack→host | root→host |
| Flexible scaling | not set | not set | `true` |
| Write latency | Higher (cross-AZ RTT) | Lower (local LAN) | Lowest (no encryption, local LAN) |
| Replica distribution | Across 3 AZs | Across 3 racks (same AZ) | Across 3 hosts (flat) |
| HA level | Survives full AZ outage | Survives single host outage | Survives single host outage |
| Encryption | Full (KMS) | Full (KMS) | None |
| Custom pools | rep2, ec-2-1, cephfs-rep2 | rep2, ec-2-1, cephfs-rep2 | None yet |
| IBM Cloud CSI | Not discovered | File CSI (15 SCs) + Pool CSI | Not available (non-ROKS) |
| RGW | No | No | Yes (1 daemon) |
| CephFS MDS count | 1+1 | 2+2 | 1+1 (standby-replay) |
| Node role | Dedicated workers | Dedicated workers | Compact (control+worker) |
| Topology labels | zone/region | zone/region/rack | None |

---

## Ranking Results: MZ vs SZ Performance Comparison

**MZ Run:** `perf-20260228-164717` (2026-02-28, ocp-virt-mz-cluster, us-south, 3 AZs)
**SZ Run:** `perf-20260227-203655` (2026-02-27, ocp-virt-420-cluster, eu-de-1, single zone)
**Test matrix:** 7 ODF pools x 3 tests (random-rw/4k, sequential-rw/1M, mixed-70-30/4k), medium VM, 150Gi PVC, 60s runtime.

**Reports:**
- [MZ Ranking](ranking-perf-20260228-164717.html)
- [MZ vs SZ Comparison](compare-perf-20260228-164717-vs-perf-20260227-203655.html)

> **Note:** No performance tests have been run on the unmanaged_sz cluster yet. Ranking data for unmanaged_sz is pending.

### MZ Composite Ranking

| Rank | Pool | Avg Read IOPS | Avg Write IOPS | Avg Read BW | Avg Write BW |
|------|------|---------------|----------------|-------------|--------------|
| 1 | rep2 | 20,182 | 5,236 | 1,227 MiB/s | 447 MiB/s |
| 2 | rep3-enc | 18,899 | 5,152 | 976 MiB/s | 511 MiB/s |
| 3 | rep3 | 18,810 | 4,864 | 1,129 MiB/s | 551 MiB/s |
| 4 | cephfs-rep2 | 18,011 | 3,652 | 934 MiB/s | 200 MiB/s |
| 5 | cephfs-rep3 | 16,491 | 3,019 | 930 MiB/s | 216 MiB/s |
| 6 | rep3-virt | 12,719 | 5,531 | 1,772 MiB/s | 829 MiB/s |
| 7 | ec-2-1 | 12,314 | 2,924 | 604 MiB/s | 295 MiB/s |

*Note: rep3-virt is missing random-rw/4k data (empty fio result), affecting its composite score.*

### Key Deltas: MZ vs SZ

| Pool | Read IOPS | Write IOPS | Read Lat | Write Lat | Read p99 | Write p99 |
|------|-----------|------------|----------|-----------|----------|-----------|
| rep3 | +0.2% | **-11.3%** | -2.2% | -0.2% | +7.9% | **+32.5%** |
| rep3-virt | -32.4%* | +3.9% | +54.4%* | +30.9%* | +50.9%* | -17.0% |
| rep3-enc | -1.5% | **-13.4%** | -6.7% | +7.7% | -3.2% | **+41.4%** |
| cephfs-rep3 | **+14.9%** | -7.8% | -11.6% | -0.9% | -10.0% | **+52.0%** |
| rep2 | -3.4% | **-10.8%** | +2.5% | +11.5% | +5.4% | **+27.3%** |
| cephfs-rep2 | -1.5% | -4.0% | +2.4% | -1.5% | +53.0% | **+30.8%** |
| ec-2-1 | -9.7% | **-19.0%** | +21.6% | **+51.0%** | +47.3% | **+182.3%** |

*For IOPS/BW: positive = MZ better. For latency: positive = MZ worse (higher latency).*
*rep3-virt results marked with * are unreliable due to missing random-rw/4k data.*

### Analysis vs Expected Outcomes

**Write IOPS/BW regression — CONFIRMED:**
All RBD pools show 10-19% write IOPS regression on MZ. This directly reflects cross-AZ replica acknowledgment latency: each write waits for replicas in different availability zones (~0.5-2ms inter-AZ RTT). ec-2-1 shows the largest write regression (-19.0%), consistent with EC encoding across zones.

**Read IOPS/BW roughly comparable — CONFIRMED:**
Read IOPS are within 3.5% for most pools (rep3, rep2, rep3-enc, cephfs-rep2). Read affinity successfully serves reads from the local-zone OSD. cephfs-rep3 actually improved +14.9% on MZ, possibly due to the MZ cluster's 512 PGs vs SZ's 256 PGs for the CephFS data pool providing better load distribution.

**p99 write latency increase — CONFIRMED:**
Write p99 latency increased 27-182% across all pools. The most dramatic impact is on ec-2-1 (+182.3%), where EC recovery and encoding traffic crosses AZ boundaries. RBD replicated pools show 27-41% increases, directly reflecting the inter-AZ RTT.

**Pool relative rankings shifted — PARTIALLY CONFIRMED:**
- rep2 moved from #2 (SZ) to #1 (MZ) by average read IOPS — with only 2 replicas needing cross-AZ acks, it suffers less write penalty
- ec-2-1 dropped to last place on MZ (was #7 on SZ) — EC encoding/recovery across zones is expensive
- cephfs-rep3 improved its relative position due to better PG distribution on MZ

### Unexpected Findings

1. **rep3-virt anomaly:** The MZ ranking shows dramatically lower read IOPS for rep3-virt (-32.4%), but this is likely due to the missing random-rw/4k result (0-byte fio JSON). The remaining 2 tests (sequential, mixed) still show rep3-virt having the best sequential throughput of all pools (1,772 MiB/s read, 829 MiB/s write).

2. **EC cross-zone penalty is severe:** ec-2-1 write p99 latency went from 117ms (SZ) to 332ms (MZ) — a 2.8x increase. The EC encoding step distributes data chunks across zones, meaning every write touches all 3 AZs.

3. **CephFS overhead stable across zones:** CephFS pools show similar read latency on both clusters (6.8-7.0ms MZ vs 6.7-7.9ms SZ), suggesting the MDS overhead dominates over the cross-AZ component for reads.
