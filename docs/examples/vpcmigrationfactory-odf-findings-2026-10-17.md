# ODF Findings from the VPCMigrationFactory Box Folder

[Back to Documentation Index](../index.md)

**Source:** IBM team Box folder VPCMigrationFactory (Storage and Scale and Performance), read on 17 Oct 2026.
**Status:** Not reproduced. This project did not run these tests. The numbers below come from the Box notes. Treat them as leads, not as results of this suite.

Source notes: "3-way Replica Pool v.s. EC Pool" (15 Oct 2026), "Perf Compare - ODF 4.20 v.s ODF 4.21" (13 Jul 2026), "Scale testing - ODF" (17 Sep 2026), "ROVE - Required Change Checklist" (9 Sep 2026), "MZR and SZR ODF Comparison on ROKS" (25 Mar 2026).

## EC vs 3-way replica on ODF 4.21

Source: "3-way Replica Pool v.s. EC Pool" (15 Oct 2026).

**Cluster:** 6 ODF storage nodes `mx3d.metal.192x2048`, 96 OSDs, OSD CPU request 2 / limit 4, RAM 24G. Both pools share the same OSDs:

- 3-way replica: StorageClass `ocs-storagecluster-ceph-rbd-virtualization`
- EC 4 data + 2 parity: StorageClass `odf-ec-block-k4p2`

**Tests:** 300 VMs per pool. Block sizes 4k/8k/16k/32k with IO depth 4/8/16/32/64, capped at 500 IOPS per VM and uncapped. Large blocks 512k/1m/2m.

**Results:**

- Small blocks with high concurrency (300 VMs, IO depth 16-64): EC has high latency. Replica keeps read under 5 ms and write under 10 ms.
- Example at 4k with the 500 IOPS cap:

| Pool | Read latency | Write latency |
|------|--------------|---------------|
| 3-way replica | 0.68-0.84 ms | 1.25-1.77 ms |
| EC 4+2 | 4.12-5.14 ms | 11.73-15.43 ms |

- At lower concurrency (150 VMs), EC meets the expected latency.
- With large blocks, EC gives better throughput.
- EC uses more OSD CPU for the same RAM.

## ODF 4.20 (rack-level replica) vs 4.21 (host-level replica, flexible scaling)

Source: "Perf Compare - ODF 4.20 v.s ODF 4.21" (13 Jul 2026).

**Setup:** Gen2 ROKS, 3 compute + 3 storage nodes `mx2d.metal.96x768`, OVN, MTU 1500, ring buffer 1024. 200 VMs (100G disk, 2 cores / 4G, multiple IO threads, StorageClass `openshift-virtualization-os-images`). fio 4k randrw 70/30, libaio, IO depth 64, capped at 100k IOPS total.

| OSD size | 4.20 IOPS | 4.21 IOPS | Read latency 4.20 / 4.21 | Write latency 4.20 / 4.21 |
|----------|-----------|-----------|--------------------------|---------------------------|
| 4 vCPU / 8G | 56,925 | 70,021 | 219.8 / 175.3 ms | not recorded |
| 4 vCPU / 24G | 89,641 | 85,461 | 108.9 / 129.5 ms | not recorded |
| 8 vCPU / 24G | about 99-100k | about 99-100k | 1.83 / 2.36 ms | 5.17 / 5.98 ms |
| 8 vCPU / 32G | not recorded | not recorded | 2.31 / 2.08 ms | 6.31 / 5.35 ms |
| 8 vCPU / 64G | not recorded | not recorded | 0.95 / 1.02 ms | 2.53 / 2.57 ms |

**Lesson from the note:** OSD CPU is the main lever. 4 vCPU OSDs saturate.

## Scale test: 303 VMs

Source: "Scale testing - ODF" (17 Sep 2026). Test date in the note: 11 Sep 2026.

- **Cluster:** ROKS `br-sao-1`, OCP 4.21.27, StorageClass `ocs-storagecluster-ceph-rbd-virtualization`. 4 compute + 6 ODF nodes.
- **VMs:** 200 CentOS + 100 Windows at 2 vCPU / 4 GiB. The note gives 303 VMs in total. Provisioned from a VolumeSnapshot source (no PVC clone). 4 namespaces on localnet VLANs through a ClusterUserDefinedNetwork.
- **State:** All 303 running, 0 paused, all live-migratable. 94.9 cores used of 600 vCPU allocated (about 16%). About 1,150 GiB memory in use.
- **fio** on 50 CentOS VMs (randrw 70/30, 8K, IO depth 8), per VM: read about 1,774 IOPS at 1.58 ms mean; write about 760 IOPS at 6.79 ms.

## Settings from the ROVE required change checklist (ODF and worker items)

Source: "ROVE - Required Change Checklist" (9 Sep 2026). These are workarounds for known issues.

**Workers:**

- Set network ring buffer TX/RX to 4K.
- Set kubelet `nodeStatusMaxImages` (compute nodes only).
- Optional: longer journalctl retention; PSI kernel parameters (needed by Kube Descheduler); QAT kernel parameters (needed by Intel Device Plugin).

**ODF:**

- Enable autoscale on `ocs-storagecluster-cephblockpool`.
- Remove the reclaimspace annotation from StorageClass `ocs-storagecluster-ceph-rbd-virtualization`:
  - Installed at 4.21.11 or later: nothing to do.
  - Upgraded to 4.21.11: patch the StorageClass.
  - Below 4.21.11: create a new StorageClass to replace it.
- Size OSD and RBD NodePlugin pod CPU and RAM to the drive count and workload.
- If VMs deploy from snapshot-based PVCs, patch the snapshot RBD images to include the features `exclusive-lock` and `fast-diff`.
- Enable host-assisted copy (DR only). Host network is optional.

**Operators:** `node-healthcheck-operator` and `self-node-remediation` are listed. `cluster-kube-descheduler-operator` is broken (on hold).

## MZR vs SZR ODF on ROKS (VSI clusters)

Source: "MZR and SZR ODF Comparison on ROKS" (25 Mar 2026). See also [ODF Cluster Comparison](../odf-cluster-comparison.md).

| Install | SZR | MZR |
|---------|-----|-----|
| ODF add-on (`bx2.16x64`, remote storage) | failureDomain `rack` (automatic), flexibleScaling not set, replica 3 | failureDomain `zone` |
| ODF operator, DIY (`cx3d.16x40`, local storage) | failureDomain `host`, flexibleScaling `true` (automatic), storageDeviceSets replica 1 | failureDomain `zone`, flexibleScaling set manually, replica 3 |

On the add-on, SZR nodes get the labels `topology.rook.io/rack=rack0|1|2`.
