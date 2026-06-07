# Phase 0 Cluster Verification — 2026-06-06

## Cluster

- **Name:** ocp-virt-420-v2-cluster (eu-de)
- **API endpoint:** https://c115-e.eu-de.containers.cloud.ibm.com:31818
- **Type:** bm (bx2d.metal.96x384, 3 workers)
- **Region:** eu-de, Zone: eu-de-2 (single-AZ)

## Ceph Health

```
cluster:
  health: HEALTH_OK

services:
  mon: 3 daemons, quorum a,b,c (age 47h)
  mgr: a(active, since 78s), standbys: b
  mds: 2/2 daemons up, 2 hot standby
  osd: 24 osds: 24 up (since 40h), 24 in (since 2w)

data:
  volumes: 2/2 healthy
  pools:   9 pools, 1808 pgs
  objects: 8.09k objects, 31 GiB
  usage:   92 GiB used, 70 TiB / 70 TiB avail
  pgs:     1808 active+clean
```

## OSD Tree Summary

- 3 workers, each with 8 OSDs (24 total), all ssd class, all up/in
- CRUSH topology: root → region eu-de → zone eu-de-2 → rack0/rack1/rack2 → host → osd
- Each host (rack) has 8 OSDs at 2.91 TiB each = ~70 TiB total raw

## StorageCluster Baseline State (Step 3)

```json
{
  "resourceProfile": "balanced",
  "storageDeviceSetsResources": [{}],
  "managedResourcesCephConfig": null
}
```

- **Assessment:** Clean OOB baseline. No leftover overrides from prior tune sweeps.

## OSD Pod Sizing (Step 5)

- All 24 OSD pods at `2 CPU / 5Gi` — consistent with `balanced` resourceProfile.
- **Assessment:** Clean. No prior run left pods at `6/24Gi`.

## Checkpoint Files (Step 5)

Most recent: `tune-20260604-135830.checkpoint` (2026-06-04, 2 days old)
Contents: completed entries only (qd-sweep:rep3-virt:default:32, qd-sweep:rep3-virt:big-osd:32)
**Assessment:** All checkpoint files are from the completed 2026-06-04 experiment. No open runs.

## osd_memory_target (Step 4)

```json
{"osd_memory_target": "4294967296"}
```

- **Value:** 4,294,967,296 bytes = ~4 GiB
- **Decision:** Below 5 GiB threshold → Reef default, cgroup-ratio mechanism NOT kicking in
- **Action:** Applied conditional edit — added `cephconfig_osd_memory_target=20000000000` to `TUNE_CONFIGS[big-osd+mclock]` in `00-config.sh`

## Conditional Edit Applied

**YES** — commit SHA: `6d1733a`

Before:
```bash
TUNE_CONFIGS[big-osd+mclock]='osd_cpu=6 osd_mem=24Gi cephconfig_osd_mclock_profile=high_client_ops cephconfig_bluestore_throttle_bytes=262144 cephconfig_bluestore_throttle_deferred_bytes=262144 cstate=on'
```

After:
```bash
TUNE_CONFIGS[big-osd+mclock]='osd_cpu=6 osd_mem=24Gi cephconfig_osd_mclock_profile=high_client_ops cephconfig_bluestore_throttle_bytes=262144 cephconfig_bluestore_throttle_deferred_bytes=262144 cephconfig_osd_memory_target=20000000000 cstate=on'
```

Offline tests: 13/13 passed after edit.

## Anomalies

- `osd_memory_target` at Reef default (4 GiB) despite hosts having 96 vCPU / 384 GiB RAM. The automatic cgroup-ratio mechanism (which should target ~1/4 of available RAM on high-memory hosts) is not activating. This means prior `big-osd+mclock` sweep data (2026-06-04) was collected with a 4 GiB memory target rather than the intended ~15–20 GiB — a significant confound. The explicit 20 GiB override in the new config corrects this for Sweep A.

## Verdict: READY FOR SWEEP A
