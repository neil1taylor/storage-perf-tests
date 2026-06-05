# ODF/Ceph Tuning Follow-Up on ROKS — Design Spec

**Date:** 2026-06-05
**Cluster:** `ocp-virt-420-v2-cluster` (IBM Cloud ROKS, eu-de)
**ODF version:** `4.20.7-rhodf` (Ceph Reef 18.x)
**Source workload:** `mixed-70-30-rated.fio` (4 KiB random, 70/30 R/W) on `rep3-virt`
**Inputs:**
- [`docs/examples/odf-ceph-tuning-candidates-2026-06-04.md`](../../examples/odf-ceph-tuning-candidates-2026-06-04.md) — candidate doc this spec actions.
- [`docs/examples/odf-osd-resource-tuning-2026-06-04.md`](../../examples/odf-osd-resource-tuning-2026-06-04.md) — prior `big-osd` measurement (the baseline cell A re-validates).
- [`docs/superpowers/specs/2026-06-03-odf-tune-sweep-design.md`](2026-06-03-odf-tune-sweep-design.md) — tune-sweep mechanism this spec extends.

---

## Goal

Action the candidate doc's top two tuning levers (KubeVirt `ioThreadsPolicy: auto` + `blockMultiQueue`, and the Ceph `mclock_profile: high_client_ops` + 256 KiB BlueStore throttle pair) on top of the already-tuned `big-osd` resource configuration. Produce a 2×2 factorial measurement that reveals each knob's individual delta, the interaction term, and the combined stack relative to `big-osd` alone.

Success means we know — with data — whether either or both knobs are worth defaulting on for the `mixed-70-30` workload at 32 VMs × QD=32 on this cluster.

---

## Experimental design — 2×2 factorial

|  | VM-template baseline (no iothreads) | VM-template + iothreads/blockMultiQueue |
|---|---|---|
| **Ceph: big-osd** | **(A)** baseline cell — re-measures `tune-20260604-135830`'s big-osd point. Sanity check against cluster drift. | **(C)** Phase 1 outcome — iothreads-only delta vs (A). |
| **Ceph: big-osd + mclock-highclient + 256 KiB BlueStore throttles** | **(B)** Phase 2 outcome — mClock/throttle delta vs (A). | **(D)** Phase 3 outcome — combined stack. |

Sweep A → cells (A) and (B). Sweep B → cells (C) and (D). All cells: `--fixed-vms 32 --qd-list 32 --rate-iops 0 --latency-sla 5`, pool `rep3-virt`, profile `mixed-70-30-rated.fio`.

Cell (A) is the experimental sanity check. If it deviates from `tune-20260604-135830`'s big-osd numbers by more than ±5 % on aggregate IOPS, the cluster has drifted (background workload, new pods, autoscaler changes); we re-baseline before reading deltas.

### Reading the deltas

- **iothreads on big-osd:** (C) − (A)
- **mClock+throttle on big-osd:** (B) − (A)
- **combined stack:** (D) − (A)
- **interaction:** (D) − (C) − (B) + (A)
  - positive → super-additive (knobs reinforce each other)
  - negative → sub-additive (knobs overlap; gains stack with diminishing returns)
  - near-zero → independent

The interaction term is the most informative single number this experiment produces.

---

## Suite changes

### `lib/tune-helpers.sh` — `cephconfig_*` key family

**Validation:** `TUNE_VALID_KEYS` stays fixed for the explicit keys (`profile`, `osd_cpu`, `osd_mem`, `cstate`); `parse_tune_config` additionally accepts any key matching the `cephconfig_*` prefix. Empty values rejected with a clear error.

**Apply step** in `apply_tuning_config`, inserted between the existing OSD resource override (step 2) and the cstate MachineConfig (step 3):

```
# --- 2b. cephConfig (live, no pod restart) ----------------------------------
# For each cephconfig_<key>=<value> pair, JSON-patch
# StorageCluster.spec.managedResources.cephCluster.cephConfig.osd.<key> = <value>.
# JSON merge (not replace) so other daemon sections are not disturbed.
# Verify propagation via wait_for_ceph_config_applied; abort on timeout.
```

Patch target: `.spec.managedResources.cephCluster.cephConfig.osd`. No OSD pod roll required — confirmed by the OCS-operator design that this field flows through Ceph's live config database.

**Snapshot** — `snapshot_cluster_state` adds one field:

```
cephconfig: <inline-json of .spec.managedResources.cephCluster.cephConfig | inherit>
```

captured with the same `jq -c` pattern as `deviceset_resources`.

**Restore** — `restore_cluster_state` adds a symmetric branch:
- snapshot `cephconfig: inherit` → JSON `remove` op against `.spec.managedResources.cephCluster.cephConfig`
- snapshot `cephconfig: <json>` → JSON `replace` op back to the snapshotted value

Followed by `wait_for_ceph_config_applied` against one sentinel key from the snapshot (propagation is mon-wide; if it works for one, it works for all).

**New helper** `wait_for_ceph_config_applied <key> <expected-value> [timeout=120]`:

```bash
oc -n openshift-storage exec deploy/rook-ceph-tools -- \
  ceph config dump --format json \
  | jq -r '.[] | select(.section=="osd" and .name=="<key>") | .value'
```

Polls every 5 s. Expected propagation ~10 s; timeout 120 s. Hard fail on timeout (orchestrator's EXIT trap then restores).

### `00-config.sh` — new tune config

```bash
TUNE_CONFIGS[big-osd+mclock]='osd_cpu=6 osd_mem=24Gi \
  cephconfig_osd_mclock_profile=high_client_ops \
  cephconfig_bluestore_throttle_bytes=262144 \
  cephconfig_bluestore_throttle_deferred_bytes=262144 \
  cstate=on'
```

Existing `big-osd` entry unchanged. Approach B does not require `default+mclock` etc.

If Phase 0 finds `osd_memory_target` at Reef default (~4 GiB) rather than the ~19 GiB the `balanced` profile cgroup ratio would produce, also add `cephconfig_osd_memory_target=20000000000` to the `big-osd+mclock` config so mClock and throttle are not measured against an unaddressed memory bottleneck.

### `vm-templates/vm-template.yaml` — additive edit

Add inside `spec.template.spec.domain`:

```yaml
ioThreadsPolicy: auto
devices:
  blockMultiQueue: true       # added inside the existing devices block
```

Committed to a feature branch between Sweep A and Sweep B. Kept on the branch until cell (C) results justify merging to main.

### Tests

`tests/test-cephconfig-parsing.bash` covers:
- `cephconfig_<anything>=<value>` parses and emits a canonical pair.
- Mixed `osd_cpu=6 osd_mem=24Gi cephconfig_*=...` in one config parses correctly.
- Empty value (`cephconfig_foo=`) rejected with clear error.

The existing `tests/test-tune-sweep-mini.bash` is extended with one extra mini-config that includes a single `cephconfig_*` key, validating apply → `ceph config dump` shows value → revert → dump no longer shows value. Mini-sweep at `--fixed-vms 1 --qd-list 1 --rate-iops 250`, total ~5–8 min cluster time.

A new fixture `tests/fixtures/tune-cephconfig-snapshot.yaml` covers the snapshot/restore round-trip for the `cephconfig` field in isolation (no cluster I/O).

---

## Execution sequence

### Phase 0 — Verify and instrument (~10 min, no mutation)

1. Source `.env`. Confirm `oc cluster-info` reaches `ocp-virt-420-v2-cluster`.
2. `ceph status` → `HEALTH_OK`, 24 OSDs in/up.
3. Verify cluster baseline is OOB (no `storageDeviceSets[0].resources` override, no `cephConfig` overrides under `osd`):
   ```bash
   oc -n openshift-storage get storagecluster -o json | \
     jq '.items[0].spec | {resourceProfile, storageDeviceSets, managedResources}'
   ```
4. **Resolve candidate-doc open question 1** — current `osd_memory_target`:
   ```bash
   oc -n openshift-storage exec deploy/rook-ceph-tools -- \
     ceph tell osd.0 config get osd_memory_target
   ```
   Result decides whether `cephconfig_osd_memory_target=20000000000` is added to `big-osd+mclock`. Either way, record the observed value in the writeup.

### Phase 1 — Suite extension (~1–1.5 h, no cluster mutation)

5. TDD per helper: `cephconfig_*` parsing → snapshot field → restore branch → `wait_for_ceph_config_applied` → `apply_tuning_config` mutation step. Red, green, refactor; integration with the existing mini-sweep last.
6. Run extended mini-sweep smoke. Aborts hard if `wait_for_ceph_config_applied` doesn't see the value within 120 s.

### Phase 2 — Sweep A (~50 min)

7. Confirm `vm-templates/vm-template.yaml` is at git HEAD (no iothreads).
8. Run:
   ```bash
   ./09-run-tune-sweep.sh \
     --pool rep3-virt \
     --configs big-osd,big-osd+mclock \
     --fixed-vms 32 \
     --qd-list 32 \
     --rate-iops 0 \
     --latency-sla 5 \
     --auto
   ```
9. Report — `reports/tune-sweep-rep3-virt-<run-id-A>.html` is cells (A) and (B).

### Phase 3 — VM-template edit + Sweep B (~55 min total)

10. Edit `vm-templates/vm-template.yaml` per §"Suite changes". Commit on a branch: `feat(vm): enable virtio-blk IOThread and multiqueue for data disk`.
11. Same `09-run-tune-sweep.sh` invocation as step 8. New run-id.
12. Report — cells (C) and (D).

### Phase 4 — Cross-run comparison + writeup (~30 min)

13. `./06-generate-report.sh --compare <run-id-A> <run-id-B>` for the 4-cell view.
14. Compute deltas + interaction term per §"Reading the deltas".
15. VM-template merge decision (see §"Headline outcome categories"). If merge, update CLAUDE.md if any documented behaviour shifts.
16. Write `docs/examples/odf-ceph-tuning-followup-2026-06-05.md` companion to the existing 2026-06-04 OSD-resource writeup.

**Total cluster contact:** ~2 h. **Total session work** including suite extension + writeup: ~4–5 h elapsed.

---

## Risks and reversibility

### Risks

1. **mClock + 256 KiB throttle may regress aggregate throughput.** The throttle compresses BlueStore's batching window; bursty traffic may see lower aggregate IOPS in exchange for tighter tail. Mitigation: read aggregate IOPS *and* write p99 together. If IOPS drops >10 % with no material p99 improvement, mark `big-osd+mclock` a regression on this workload and document.

2. **`cephConfig` patch with unknown-to-OCS-operator key.** Admission may reject. `mclock_profile` and `bluestore_throttle_*` are in the merged path per the OCS-operator source confirmed in the candidate doc (HEAD on 2026-06-04, `cephcluster.go::getCephClusterCephConfig` lines 1574, 1648–1656); risk is low but real. Guard: `wait_for_ceph_config_applied` must see the value within 120 s or the sweep aborts and restore runs.

3. **`ioThreadsPolicy: auto` interacts badly with 2-vCPU small VMs.** The IOThread may compete with vCPU threads on the same physical core, presenting as lower aggregate IOPS or higher p50 in cell (C) vs (A). The 4-cell data shows this directly; no special instrumentation.

4. **Cluster drift on cell (A).** If cell (A) diverges >5 % aggregate IOPS from `tune-20260604-135830`'s big-osd value, something else changed (autoscaler, new pod load, ODF minor upgrade). Phase 0 step 3 catches most of this; cell (A) is the final check. If drift detected, re-baseline before reading deltas.

### Reversibility

- **Suite extension:** pure git revert; no cluster state from code edits.
- **Sweep A and B:** `09-run-tune-sweep.sh`'s EXIT trap restores `storageDeviceSets[0].resources` *and* the new `cephConfig` field on every exit path (normal, error, Ctrl+C). Manual recovery via `--restore-from <run-id>` documented in CLAUDE.md.
- **VM-template edit:** on a feature branch until results justify merge.

---

## Success criteria

The session succeeds if all of:

1. All four cells measured to completion. No aborted runs from suite defects.
2. Cell (A) within ±5 % aggregate IOPS of `tune-20260604-135830`'s big-osd value.
3. 4-cell HTML comparison report renders with all metrics populated.
4. Cluster returned to OOB baseline at session end: `HEALTH_OK`, no `storageDeviceSets[0].resources` override, no `cephConfig` under `osd`, profile=balanced.
5. Companion writeup committed.

### Headline outcome categories

| Category | Threshold | Action |
|---|---|---|
| **Big win** | Either knob individually ≥15 % aggregate IOPS lift *or* ≥30 % write p99 reduction over big-osd alone | Merge VM-template branch and/or recommend default `cephConfig` overlay |
| **Modest win** | 5–15 % aggregate IOPS *or* 10–30 % p99 reduction | Document; retain knob as optional; no default change |
| **Null** | <5 % aggregate IOPS movement, <10 % p99 movement | Document the negative result (negative results matter — they shorten future tuning searches) |
| **Regression** | Either knob worsens aggregate IOPS >5 % *or* p99 >10 % | Revert (template stays on branch, `big-osd+mclock` removed from `TUNE_CONFIGS` or marked deprecated); document why |

---

## Out of scope

- **Path C (new StorageClass with `queue_depth=1024` `mapOptions`).** Separate experiment with its own provisioning cost.
- **Adding a 4th worker node.** Operator decision, not a tuning sweep.
- **C-state lever and `RC` slide-matching config.** Not feasible on ROKS managed workers (no MachineConfigPool); available on `szocp`.
- **Anything from the candidate doc's "Don't bother" list.**
- **Full QD curve.** Single QD=32 matches the `tune-20260604-135830` baseline cleanly. The QD curve is a separate follow-up if cells suggest scheduling-window-shape effects worth characterising further.

---

## Artefacts produced

| Path | Contents |
|---|---|
| `lib/tune-helpers.sh` | Extended with `cephconfig_*` key family + `wait_for_ceph_config_applied` helper |
| `00-config.sh` | New `TUNE_CONFIGS[big-osd+mclock]` entry |
| `vm-templates/vm-template.yaml` | `ioThreadsPolicy: auto` + `blockMultiQueue: true` (on a branch; merge gated on cell C results) |
| `tests/test-cephconfig-parsing.bash` | Parser unit tests for `cephconfig_*` keys |
| `tests/fixtures/tune-cephconfig-snapshot.yaml` | Snapshot/restore round-trip fixture |
| `tests/test-tune-sweep-mini.bash` | Extended to validate live cephConfig apply/revert |
| `results/tune-<run-id-A>/` | Sweep A raw data (cells A and B) |
| `results/tune-<run-id-B>/` | Sweep B raw data (cells C and D) |
| `reports/tune-sweep-rep3-virt-<run-id-A>.html` | Per-sweep tune-sweep report |
| `reports/tune-sweep-rep3-virt-<run-id-B>.html` | Per-sweep tune-sweep report |
| `reports/compare-<run-id-A>-vs-<run-id-B>.html` | Cross-run 4-cell comparison |
| `docs/examples/odf-ceph-tuning-followup-2026-06-05.md` | Companion writeup with 4-cell results, interaction term, merge decision |
