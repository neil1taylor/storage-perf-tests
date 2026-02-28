# ODF Cluster Comparison: Multi-Zone vs Single-Zone

**Date:** 2026-02-28
**Compared clusters:**
- **MZ:** `ocp-virt-mz-cluster` — multi-zone, us-south (3 AZs)
- **SZ:** `ocp-virt-420-cluster` — single-zone, eu-de-1

---

## Cluster Infrastructure

| Property | **MZ** (ocp-virt-mz-cluster) | **SZ** (ocp-virt-420-cluster) |
|---|---|---|
| Region | us-south | eu-de |
| Zones | 3 (us-south-1, -2, -3) | 1 (eu-de-1) |
| Workers | 3 (1 per zone) | 3 (all same zone) |
| Instance type | bx2d.metal.96x384 | bx2d.metal.96x384 |
| OCP version | v1.33.6 | v1.33.6 |
| ODF version | 4.19.10 | 4.19.10 |
| Ceph version | Squid 19.2.1-292 | Squid 19.2.1-292 |

Both clusters use identical bare-metal hardware (96 vCPU, 384 GiB RAM per node) and identical ODF/Ceph software versions.

---

## ODF / StorageCluster Configuration

| Property | **MZ** | **SZ** |
|---|---|---|
| StorageCluster phase | Ready | Ready |
| Device set count | 8 | 8 |
| Device set replica | 3 | 3 |
| **Total OSDs** | **24** | **24** |
| OSDs per node | 8 | 8 |
| OSD size | 2980 GiB (NVMe) | 2980 GiB (NVMe) |
| Raw capacity | ~70 TiB | ~70 TiB |
| Device class | SSD | SSD |
| Resource profile | balanced | balanced |

### Encryption

| Property | **MZ** | **SZ** |
|---|---|---|
| Cluster-wide encryption | yes | yes |
| StorageClass encryption | yes | yes |
| Network encryption (msgr2) | yes | yes |
| KMS provider | IBM Key Protect (us-south) | IBM Key Protect (eu-de) |
| Key rotation | weekly | weekly |
| CephFS kernel mount | ms_mode=secure | ms_mode=secure |

### CSI Features

| Property | **MZ** | **SZ** |
|---|---|---|
| Read affinity | enabled | enabled |
| Skip user creation | true | true |

---

## Failure Domain & CRUSH Topology

This is the **primary architectural difference** between the two clusters.

| Property | **MZ** | **SZ** |
|---|---|---|
| **failureDomain** | **zone** | **rack** |
| failureDomainKey | `topology.kubernetes.io/zone` | `topology.rook.io/rack` |
| failureDomainValues | us-south-1, us-south-2, us-south-3 | rack0, rack1, rack2 |
| **Failure domain count** | **3 zones** | **3 racks** |
| Replicas survive | Full AZ outage | Single rack/host outage |
| Mon anti-affinity | `topology.kubernetes.io/zone` | `topology.rook.io/rack` |
| MDS anti-affinity | `topology.kubernetes.io/zone` | `topology.rook.io/rack` |

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

**Note:** Both clusters have custom perf-test pools. The MZ cluster uses `failureDomain: zone` for custom pools; the SZ cluster uses `failureDomain: host`.

### PG Distribution Comparison (OOB pools only)

| Pool | **MZ PGs** | **SZ PGs** |
|---|---|---|
| Blockpool | **256** | 128 |
| CephFS data0 | **512** | 256 |
| CephFS metadata | 16 | 16 |
| .mgr | 32 | 32 |
| .nfs | 32 | 32 |
| **Total (OOB)** | **848** | **476** |
| **Total (all)** | **848** | **768** |

The MZ cluster's PG autoscaler has assigned more PGs to the OOB pools because there are no custom pools consuming `target_size_ratio`. On the SZ cluster, the custom pools with `target_size_ratio: 0.1` reduce the effective ratio for the OOB pools from 0.49 to ~0.38, resulting in fewer PGs.

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

**Note:** Custom pools on SZ use `failureDomain: host` (finer-grained than the cluster-level `rack`). On MZ, custom pools use `failureDomain: zone` to match the cluster-level setting.

---

## CephFilesystems

| Filesystem | **MZ** | **SZ** |
|---|---|---|
| OOB (ocs-storagecluster-cephfilesystem) | Ready | Ready |
| perf-test-cephfs-rep2 | — (not created) | Ready |
| MDS count | 1 active + 1 standby | 2 active + 2 standby |

---

## StorageClasses

### ODF StorageClasses (identical on both)

| StorageClass | Provisioner | Present on MZ | Present on SZ |
|---|---|---|---|
| ocs-storagecluster-ceph-rbd | rbd.csi.ceph.com | yes | yes |
| ocs-storagecluster-ceph-rbd-virtualization | rbd.csi.ceph.com | yes | yes |
| ocs-storagecluster-ceph-rbd-encrypted | rbd.csi.ceph.com | yes | yes |
| ocs-storagecluster-cephfs | cephfs.csi.ceph.com | yes | yes |
| ocs-storagecluster-ceph-nfs | nfs.csi.ceph.com | yes | yes |

### StorageClass Parameters

**RBD (ocs-storagecluster-ceph-rbd):** Identical on both clusters.
- `imageFeatures: layering,deep-flatten,exclusive-lock,object-map,fast-diff`
- `imageFormat: 2`
- `pool: ocs-storagecluster-cephblockpool`
- No `mapOptions` or `mounter` set

**RBD Virtualization (ocs-storagecluster-ceph-rbd-virtualization):** Identical on both clusters.
- Same as above, plus:
- `mapOptions: krbd:rxbounce`
- `mounter: rbd`

**CephFS (ocs-storagecluster-cephfs):** Identical on both clusters.
- `fsName: ocs-storagecluster-cephfilesystem`

### IBM Cloud CSI StorageClasses (SZ only)

The SZ cluster also has IBM Cloud File CSI StorageClasses that are not present on the MZ cluster:
- `ibmc-vpc-file-500-iops`, `ibmc-vpc-file-1000-iops`, `ibmc-vpc-file-3000-iops`
- `ibmc-vpc-file-eit`, `ibmc-vpc-file-min-iops`
- Metro/retain/regional variants
- Pool CSI: `bench-pool`, `ibm-vpc-file-pool`

The MZ cluster has **no IBM Cloud CSI StorageClasses** — `02-setup-file-storage.sh` and `03-setup-block-storage.sh` have not been run yet.

### Custom Perf-Test StorageClasses (SZ only)

| StorageClass | Provisioner |
|---|---|
| perf-test-sc-rep2 | rbd.csi.ceph.com |
| perf-test-sc-ec-2-1 | rbd.csi.ceph.com |
| perf-test-sc-cephfs-rep2 | cephfs.csi.ceph.com |

Present on both clusters (created by `01-setup-storage-pools.sh`).

---

## Ceph Cluster Health

| Metric | **MZ** | **SZ** |
|---|---|---|
| Health | HEALTH_OK | HEALTH_OK |
| MON daemons | 3 (quorum a,b,c) | 3 (quorum a,c,b) |
| MGR daemons | 2 (a active, b standby) | 2 (b active, a standby) |
| MDS daemons | 1 active + 1 standby | 2 active + 2 standby |
| OSD count | 24 up, 24 in | 24 up, 24 in |
| OSD uptime | ~12 min (just scaled up) | 4 days |
| Total pools | 5 | 9 |
| Total PGs | 848 (all active+clean) | 768 (all active+clean) |
| Objects | 58 | 6,140 |
| Data stored | 613 KiB | 23 GiB |
| Raw used | 1.4 GiB | 85 GiB |
| Raw available | ~70 TiB | ~70 TiB |
| CephFS volumes | 1/1 healthy | 2/2 healthy |

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

**Note:** The MZ cluster shows higher VAR (0.68–2.46) because it was just scaled from 3→24 OSDs and the PG distribution hasn't fully rebalanced yet. The original 3 OSDs (0, 1, 2) still hold more metadata. This will equalize over time.

---

## Performance Implications for Multi-Zone

### Cross-AZ Latency
- **Writes:** Each replicated write must wait for acknowledgment from replicas in different AZs. Inter-AZ latency within us-south is typically 0.5–2ms RTT, which directly adds to write latency compared to the SZ cluster where all replicas are on the same LAN segment.
- **Reads:** Read affinity (`csi.readAffinity.enabled: true`) means reads are served from the local-zone OSD replica, so read latency should be comparable to SZ.

### EC Pool Constraints
- Both clusters have exactly 3 failure domains (3 zones on MZ, 3 racks on SZ).
- EC pools requiring ≤3 failure domains work (ec-2-1 needs 3). EC pools needing >3 (ec-3-1, ec-2-2, ec-4-2) will be automatically skipped.
- Custom pools on MZ must use `failureDomain: zone` (matching the cluster-level setting), not `host` as used on SZ.

### PG Rebalancing
- The MZ cluster was just scaled from 3→24 OSDs. PG rebalancing to the new OSDs completes rapidly since the cluster is nearly empty (603 KiB of data). All 848 PGs are already active+clean.
- The PG autoscaler has scaled up: blockpool 64→256 PGs, CephFS data 128→512 PGs, appropriate for 24 OSDs.

### Network Encryption Overhead
Both clusters have identical encryption settings (msgr2 secure mode, KMS-backed OSD encryption). The encryption overhead is the same, but on MZ the cross-AZ traffic traverses the IBM Cloud backbone which may have different bandwidth characteristics than the intra-rack NVMe-over-TCP fabric.

---

## Summary: What's Identical

- Hardware: bx2d.metal.96x384 x 3 nodes
- Software: OCP v1.33.6, ODF 4.19.10, Ceph Squid 19.2.1
- OSD count: 24 (8 per node)
- Raw capacity: ~70 TiB
- Encryption: Full (data-at-rest + in-transit + KMS)
- Resource profile: balanced
- OOB StorageClass parameters: Identical (imageFeatures, mapOptions, etc.)

## Summary: What's Different

| Aspect | **MZ** | **SZ** |
|---|---|---|
| Failure domain | **zone** (cross-AZ) | rack (intra-zone) |
| CRUSH hierarchy | root→region→zone→host | root→region→zone→rack→host |
| Write latency | Higher (cross-AZ RTT) | Lower (local LAN) |
| Replica distribution | Across 3 AZs | Across 3 racks (same AZ) |
| HA level | Survives full AZ outage | Survives single host outage |
| Custom pools | rep2, ec-2-1, cephfs-rep2 | rep2, ec-2-1, cephfs-rep2 |
| IBM Cloud CSI | Not discovered | File CSI (15 SCs) + Pool CSI |
| CephFS MDS count | 1+1 | 2+2 |
| Cluster age | ~4 hours | ~22 days |
| Data on cluster | 603 KiB (empty) | 23 GiB |

---

## Ranking Results: MZ vs SZ Performance Comparison

**MZ Run:** `perf-20260228-164717` (2026-02-28, ocp-virt-mz-cluster, us-south, 3 AZs)
**SZ Run:** `perf-20260227-203655` (2026-02-27, ocp-virt-420-cluster, eu-de-1, single zone)
**Test matrix:** 7 ODF pools x 3 tests (random-rw/4k, sequential-rw/1M, mixed-70-30/4k), medium VM, 150Gi PVC, 60s runtime.

**Reports:**
- [MZ Ranking](ranking-perf-20260228-164717.html)
- [MZ vs SZ Comparison](compare-perf-20260228-164717-vs-perf-20260227-203655.html)

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
