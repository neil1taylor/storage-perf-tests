# Further ODF/Ceph Tuning Candidates for ROKS — Planning Doc

**Date:** 2026-06-04
**Cluster:** `ocp-virt-420-v2-cluster` (IBM Cloud ROKS, eu-de)
**ODF version:** `4.20.7-rhodf` (Ceph Reef 18.x)
**Source workload:** `mixed-70-30-rated.fio` (4 KiB random, 70/30 R/W) on `rep3-virt`
**Companion doc:** [`odf-osd-resource-tuning-2026-06-04.md`](odf-osd-resource-tuning-2026-06-04.md) — what we already proved (2.89× IOPS lift from OSD resources).

---

## Why this doc exists

The 2026-06-04 OSD-resource sweep on this cluster lifted aggregate IOPS 2.89× and write p99 5× by tripling per-OSD CPU. Big win, but write p99 still sits at 53 ms at 32 VMs / QD=32 — well above the 5 ms SLA target. This document records the next set of tuning candidates worth testing in a follow-up session, the safe injection paths for each on a managed ODF cluster, and the "don't bother" list so we don't waste cluster time on changes that won't move the needle.

Research conducted 2026-06-04 against ODF 4.20.7-rhodf, Ceph Reef 18.x, Rook 1.16 (the version line ODF 4.20 ships).

---

## The safe injection paths on managed ODF

Three mechanisms reach the cluster without being reverted by OCS-operator reconciles:

### Path A — `StorageCluster.spec.managedResources.cephCluster.cephConfig` *(preferred for Ceph daemon settings)*

This field is a map[string]map[string]string keyed by Ceph daemon section (`osd`, `mon`, `mgr`, …). The OCS-operator builds its base Ceph config, then **merges** user-supplied keys on top — last-writer-wins per key. Confirmed by reading `internal/controller/storagecluster/cephcluster.go::getCephClusterCephConfig` (lines 1574, 1648–1656 in HEAD on 2026-06-04).

Properties:

- **Survives operator reconciles** unconditionally. Don't need `reconcileStrategy: ignore`.
- **Applied live** via Ceph config database — no OSD pod restart required for most settings.
- **Reversible** — remove the key from StorageCluster, operator re-derives defaults.
- **Snapshot-friendly** — our `tune-helpers.sh` snapshot pattern can capture and restore this field the same way it does `storageDeviceSets[i].resources`.

Prefer this path over the legacy `rook-config-override` ConfigMap (which requires `managedResources.cephConfig.reconcileStrategy: ignore` AND daemon pod restarts).

### Path B — `vm-templates/vm-template.yaml` *(KubeVirt domain spec)*

Changes here take effect on next VM creation. No coordination with ODF needed; this is purely virt-side.

### Path C — New StorageClass with revised `parameters` / `mapOptions`

StorageClass parameters are immutable after creation. Tuning here means creating a sibling SC (e.g. `ocs-storagecluster-ceph-rbd-tuned`), provisioning new PVCs against it, and re-running. More invasive than A or B; treat as a separate experiment.

---

## Top 3 candidates, ranked by expected lift on this workload

### 1. KubeVirt `ioThreadsPolicy: auto` + `blockMultiQueue: true` *(client-side, biggest hidden cost)*

**Where:** Path B (VM template edit).

**The mechanism:** the current VM template uses `bus: virtio` for the data disk but does not set `ioThreadsPolicy` or `blockMultiQueue`. By default, KubeVirt runs a single shared QEMU IOThread for all disks per VM, with one virtio-blk queue per device. At 32 VMs × QD=32 that funnels 1024 in-flight requests through 32 single-threaded dispatch paths *before they even reach Ceph*. Red Hat Developer benchmarks (Sep 2024) showed virtio-blk IOPS scaling linearly with IOThread count up to 4. For our 2-vCPU small VMs, `ioThreadsPolicy: auto` gives 2 IOThreads — instant 2× parallelism on the VM-side dispatch.

**Change:**

```yaml
spec:
  template:
    spec:
      domain:
        ioThreadsPolicy: auto          # add at domain level
        devices:
          blockMultiQueue: true        # add at devices level
          disks:
            - name: datadisk
              disk:
                bus: virtio            # unchanged — required for blockMultiQueue
```

**Risk:** Low. `auto` pins IOThread away from vCPU threads; with 2 vCPU small VMs, confirm scheduling on the worker.

**Expected effect:** Reduces VM-side queueing serialization. Should compress the write tail before any Ceph change is even visible.

**Reversibility:** Trivial — remove the two fields, rebuild VMs.

### 2. mClock `high_client_ops` profile + NVMe-tuned BlueStore throttle *(operator-aware)*

**Where:** Path A (cephConfig under `osd:`).

**The mechanism:** Reef defaults to the mClock scheduler with the `balanced` profile (50/50 reservation between client ops and recovery/scrub). At high client QD, this lets background work cut in front of client I/O — visible as periodic tail-latency spikes. `high_client_ops` shifts the reservation to 60/40 in favor of client ops with weight 2. Paired with `bluestore_throttle_bytes` and `bluestore_throttle_deferred_bytes` at the NVMe-recommended 256 KiB (vs the HDD-shaped Reef default of ~40 MiB), mClock's scheduling window stays shallow enough to actually exert prioritisation.

**Change:**

```yaml
# StorageCluster.spec.managedResources.cephCluster.cephConfig:
osd:
  osd_mclock_profile: "high_client_ops"
  bluestore_throttle_bytes: "262144"
  bluestore_throttle_deferred_bytes: "262144"
```

**Risk:** Medium. Throttle tightening creates back-pressure; bursty workloads may see aggregate throughput dip slightly in exchange for tighter tail. Apply to 1 OSD first via `ceph config set osd.0 ...` to sanity-check.

**Expected effect:** Targets the *specific* remaining write-p99 symptom. Mild aggregate-throughput effect, meaningful tail compression.

**Reversibility:** Trivial — `ceph config rm` or remove from `cephConfig`. Reef re-derives defaults.

### 3. `osd_memory_target` — verify before changing *(may already be in effect)*

**Where:** Path A (cephConfig under `osd:`).

**The mechanism:** OCS-operator auto-derives `osd_memory_target` from the OSD pod cgroup limit × `osd_memory_target_cgroup_limit_ratio` (0.8 for `balanced`, 0.6 for `performance`). For our `big-osd` at 24 GiB pod limit, the effective target *should* already be ~19 GiB (vs Reef's 4 GiB default for stock pods). Before adding an explicit override, **verify** it's not already at 19 GiB:

```bash
oc -n openshift-storage exec deploy/rook-ceph-tools -- \
  ceph tell osd.0 config get osd_memory_target
```

If the result is near `20000000000`, no action needed — we're already getting the headroom via the cgroup-ratio mechanism. If it's at the Reef default (4 GiB) or otherwise low, set explicitly:

```yaml
# StorageCluster.spec.managedResources.cephCluster.cephConfig:
osd:
  osd_memory_target: "20000000000"   # 20 GiB; stays under 24 GiB cgroup limit
```

**Risk:** Low if the value stays at least 15–20 % under the pod memory limit (avoids OOM under recovery).

**Expected effect:** Documented as the single most impactful BlueStore parameter for NVMe (ceph.io blog, Reef benchmarks). If we're already there via cgroup ratio, no further lift; if not, expect read-tail compression and IOPS lift on cache-hot data.

---

## Adjacent levers worth knowing about

### `mapOptions: "krbd:rxbounce,queue_depth=1024"` — StorageClass change

**Where:** Path C (new StorageClass).

The kernel RBD driver's default per-device queue depth is 128. At 32 VMs × QD=32, if multiple VMs land on the same RBD client queue, the kernel limit clips before Ceph even sees the depth. Raising to 1024 in `mapOptions` removes that ceiling. StorageClasses are immutable, so this requires a sibling SC + new PVCs + re-test. Treat as a separate experiment, not a flip-the-knob change.

### Add a 4th worker node *(scale-out, not tuning)*

Adding 8 more OSDs (32 total) reduces per-OSD queue depth at any given density by 25 %. Single biggest non-tuning lever for the write-tail bottleneck. Worth doing if config sweeps plateau.

### Disk partitioning — 2 OSDs per NVMe

Reef-specific finding (ceph.io 2023): on high-density NVMe with sufficient CPU per OSD, partitioning each NVMe into 2 OSDs improves p99 because the per-OSD queue stays shallower. Invasive (re-creates OSDs); only worth it on a dedicated test cluster, not on a production-ish ROKS that's also serving other workloads.

---

## Not feasible on ROKS

### Multus dual-network (split public + cluster Ceph nets)

The OCS-operator schema fully supports `StorageCluster.spec.network` with Multus selectors. **But IBM Cloud ROKS workers do not expose secondary NICs to OCP** — the worker's bonded management/data interface is the only one visible. Provisioning a dedicated cluster-internal NIC on `bx2d.metal` requires an IBM support ticket; it is not a cluster-config knob. **Skip this lever on ROKS.**

### MachineConfig kernelArguments (cstate disable, governor=performance)

No MachineConfigPool exists on ROKS managed workers (worker lifecycle is owned by IBM Cloud, not by MCO). The MachineConfig CRD is registered but no MCP instances are created. `cstate-off` and `big-osd+cstate-off` variants in `TUNE_CONFIGS` are silently inert on ROKS. **Skip on ROKS; available on szocp self-managed clusters.**

---

## Don't bother list (saves the next session time)

| Knob | Reason |
|---|---|
| `bluestore_cache_size_ssd`, `bluestore_cache_kv_ratio`, `bluestore_cache_meta_ratio` | Overridden by `bluestore_cache_autotune` (default on). Tune via `osd_memory_target` instead. |
| `osd_op_num_shards_ssd`, `osd_op_num_threads_per_shard_ssd` | Already at Reef SSD defaults (8 × 2). Increasing burns CPU without measurable benefit; Ceph mClock docs note fewer shards actually *improve* scheduling accuracy. |
| `osd_async_recovery_min_cost` | Applies to PG recovery, not client I/O. No evidence of benefit for write-tail. |
| `rocksdb_cache_size` | Managed by autotune. Tune `osd_memory_target`. |
| `compressionMode: ...` on `rep3-virt` | 4 KiB random VM data has near-zero entropy headroom; CPU overhead exceeds benefit, hurts p99. |
| `rbd_cache=true` | librbd user-space setting. Has no effect on our krbd mounter. |
| `disk.cache: writeback` in KubeVirt | Would hide write latency via host page cache; misleading for benchmarking, no real-world durability improvement. |
| CephFS-specific tuning (mds heap, mds_cache_memory_limit) | Irrelevant — we benchmark RBD. |
| `bluestore_prefer_deferred_size_hdd` | HDD-only; OCS-operator already sets to 0 on this cluster. |

---

## Proposed test plan for the follow-up session

This is a brief for the **next** session to execute, not for this one. The next session should re-validate cluster baseline, then run the experiments below in order:

### Phase 0 — Verify and instrument

1. Confirm cluster is at clean baseline (HEALTH_OK, profile=balanced, no `storageDeviceSets[0].resources` override, 24 OSDs on 2/5Gi).
2. Run the `osd_memory_target` verification (`ceph tell osd.0 config get osd_memory_target`) and record the actual current value. Decides whether candidate #3 is worth pursuing.

### Phase 1 — VM-template change (no Ceph mutation)

Single experiment, fastest payback:

1. Edit `vm-templates/vm-template.yaml` to add `ioThreadsPolicy: auto` and `devices.blockMultiQueue: true`.
2. Run baseline comparison (same 32 VMs × QD=32 uncapped methodology) against the existing `default` baseline data — should land in a fresh run-id and compare via `06 --compare-tuning`.
3. Expected: lift on aggregate IOPS and reduction in write p99 *without changing any Ceph config*. If the lift is large, that becomes the new default.

### Phase 2 — mClock + throttle (Path A, no VM-template change)

Build a new tune config that uses `cephConfig` overrides instead of `storageDeviceSets[i].resources`. The mechanism needs an extension to `apply_tuning_config` (or a separate apply function) since the current code only patches deviceSets:

1. Extend `lib/tune-helpers.sh` with a `cephconfig_*` key family in `TUNE_CONFIGS`:
   ```bash
   TUNE_CONFIGS[mclock-highclient]='cephconfig_osd_mclock_profile=high_client_ops cephconfig_bluestore_throttle_bytes=262144 cephconfig_bluestore_throttle_deferred_bytes=262144 cstate=on'
   ```
2. `apply_tuning_config` patches `StorageCluster.spec.managedResources.cephCluster.cephConfig`; `snapshot_cluster_state` captures it; `restore_cluster_state` reverts.
3. Verify with `ceph config dump` that the override applied live (no OSD restart should be needed).
4. Run on top of the existing `big-osd` resources: configs become `default`, `big-osd`, `big-osd+mclock-highclient`. Three data points reveal whether mClock+throttle adds anything over big-osd alone.

### Phase 3 — Combine and stack-rank

Once phases 1 and 2 are characterised individually, optionally test the combined stack: VM-template change + big-osd resources + mClock profile + throttle. If the lift is sub-additive, document that; if super-additive (interaction effect), that's the headline.

### Out of scope for the next session

- New StorageClass with `queue_depth=1024` (Path C) — separate experiment with its own provisioning cost.
- Adding a 4th worker — operator decision, not a tuning sweep.
- Anything from the "Not feasible on ROKS" or "Don't bother" lists.

---

## Suite changes the next session will need

### Minor

- Extend `lib/tune-helpers.sh` to handle a `cephconfig_*` key family in `TUNE_CONFIGS` parsing.
- `apply_tuning_config`: add a 4th mutation step that patches `StorageCluster.spec.managedResources.cephCluster.cephConfig` based on parsed cephconfig keys.
- `snapshot_cluster_state`: capture `StorageCluster.spec.managedResources.cephCluster.cephConfig` (jq one-liner, same pattern as `deviceset_resources`).
- `restore_cluster_state`: restore from snapshot; if the snapshot's field was empty, remove the path; if populated, set it back.
- New `wait_for_ceph_config_applied <key> <expected>` helper — polls `ceph config dump` until the override propagates (~10 s expected).

### Trivial

- VM-template edit (Path B) is a one-time edit, not a sweep-time mutation. The new defaults stay in the file; revert via git if needed.

---

## Open questions for the next session

These need resolution at the start of the next session, not during this one:

1. **What's the current `osd_memory_target` on this cluster?** Determines if candidate #3 is already realised via cgroup ratio.
2. **Do we want to test on top of `big-osd` (3-config matrix) or on the OOB `default` baseline (2-config matrix)?** Stacking on `big-osd` is more interesting (shows whether knobs add to the already-tuned config); on `default` is cleaner per-knob isolation.
3. **What's the budget for cluster time?** Each 32-VM sweep is ~25 min for 2 configs / ~38 min for 3. The full plan (Phase 1 + Phase 2 + Phase 3 combined) is ~2-3 hours.

---

## Artefacts referenced

- [`odf-osd-resource-tuning-2026-06-04.md`](odf-osd-resource-tuning-2026-06-04.md) — the prior experiment's results.
- [`docs/superpowers/specs/2026-06-03-odf-tune-sweep-design.md`](../superpowers/specs/2026-06-03-odf-tune-sweep-design.md) — original tune-sweep design spec.
- [`docs/superpowers/plans/2026-06-03-odf-tune-sweep.md`](../superpowers/plans/2026-06-03-odf-tune-sweep.md) — implementation plan.
- [`lib/tune-helpers.sh`](../../lib/tune-helpers.sh) — what to extend for Phase 2.
- [`vm-templates/vm-template.yaml`](../../vm-templates/vm-template.yaml) — what to edit for Phase 1.

External (cite when re-running):

- [Ceph mClock Config Reference (Reef)](https://docs.ceph.com/en/reef/rados/configuration/mclock-config-ref/)
- [Ceph BlueStore Configuration Reference (Reef)](https://docs.ceph.com/en/reef/rados/configuration/bluestore-config-ref/)
- [Ceph Reef: 1 or 2 OSDs per NVMe? (ceph.io blog)](https://ceph.io/en/news/blog/2023/reef-osds-per-nvme/)
- [Scaling virtio-blk disk I/O with IOThread Virtqueue Mapping (Red Hat Developer)](https://developers.redhat.com/articles/2024/09/05/scaling-virtio-blk-disk-io-iothread-virtqueue-mapping)
- [OCS-operator `cephcluster.go` source](https://github.com/red-hat-storage/ocs-operator/blob/main/controllers/storagecluster/cephcluster.go) (lines 1560–1666 — confirmed managedResources merge behaviour)
