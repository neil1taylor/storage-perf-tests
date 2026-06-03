# VM Storage Migration

Migrate OpenShift Virtualization VMs from one StorageClass to another. Built
alongside the `storage_perf_tests` perf-benchmarking suite so the same
operator who used the suite to **pick** a winning StorageClass can also use
this tool to **move** existing VMs onto that winner without rebuilding them.

The motivating case is **ODF rep3-virt (RBD, `volumeMode: Block`) → IBM
Cloud File CSI (NFS, `volumeMode: Filesystem`)** on a ROKS cluster, but any
source/target pair on the cluster is supported.

---

## Quick start

```bash
# Dry-run first (no resources created)
./migration/migrate-vm-storage.sh --vm myvm --target-sc ibmc-vpc-file-500-iops --dry-run

# Real migration (offline; source PVC preserved by default)
./migration/migrate-vm-storage.sh --vm myvm --target-sc ibmc-vpc-file-500-iops

# Migrate every VM in the namespace whose data PVCs are on ODF
./migration/migrate-vm-storage.sh --all --target-sc cephfs-rep3
```

Run from the repo root. `./migration/migrate-vm-storage.sh --help` prints
the full flag list.

---

## What it does

For each selected VM:

1. Enumerates volumes in `spec.template.spec.volumes[]` that resolve to a
   PVC, and skips any already on the target StorageClass.
2. (Default) Skips the root disk; pass `--include-rootdisk` to migrate it
   too.
3. (Default) Takes a `VolumeSnapshot` of each source PVC as a safety net.
4. Stops the VM.
5. Creates a CDI `DataVolume` cloning each source PVC to the target SC.
   - For same-`volumeMode`, same-SC-driver pairs CDI may use a smart-clone
     (CSI snapshot copy).
   - For cross-`volumeMode` or cross-driver pairs (e.g. RBD Block →
     Cloud File Filesystem) CDI falls back to **host-assisted clone**:
     a source pod reads the source PVC and streams the bytes to a target
     pod that writes them to the new PVC.
6. Patches the VM spec to point each affected volume at the new PVC. Any
   matching `dataVolumeTemplates` entry is stripped so deleting the VM
   later does not garbage-collect the migrated data.
7. Starts the VM and waits for `Running`.
8. Appends `vm:src_pvc:new_dv` to `results/<mig-run-id>.checkpoint` so
   the run can be `--resume`d.
9. (Optional with `--delete-source`) Deletes the source PVC and the
   pre-migration snapshot.

The script never deletes source PVCs unless `--delete-source` is passed,
and on any mid-flight failure it preserves both the source PVCs and the
partially-cloned target PVCs so you can diagnose by hand.

### Online (live) migration

`--mode online` uses KubeVirt Storage Live Migration
(`spec.updateVolumesStrategy: Migration`, GA in OpenShift Virtualization
4.17 / KubeVirt 1.3). Instead of stopping the VM, KubeVirt creates a blank
PVC on the target SC and uses libvirt `blockcopy` to mirror writes under
the running VMI.

**Requires identical `volumeMode` on source and target.** RBD Block →
Cloud File Filesystem is rejected at runtime — libvirt `blockcopy` cannot
bridge a raw block device to a Filesystem-backed `disk.img`. Use the
default offline mode for cross-`volumeMode` migrations.

---

## Prerequisites

- `oc` CLI authenticated to the target cluster.
- `virtctl` on PATH (the perf-tests repo ships a copy at the project root).
- `jq` for the JSON-patch helper in `migration-helpers.sh`.
- CDI (ships with OpenShift Virtualization) for DataVolume cloning.
- A `VolumeSnapshotClass` matching the source SC's driver if you want the
  snapshot safety net (`--no-snapshot` skips it).
- For online mode: OpenShift Virtualization >= 4.17.

---

## File layout

```
migration/
├── README.md              this file
├── migrate-vm-storage.sh  CLI orchestrator
└── migration-helpers.sh   shared helpers (sourced by the script)
```

The script sources `00-config.sh`, `lib/vm-helpers.sh`, and
`lib/wait-helpers.sh` from the repo root for cluster detection, logging,
and the existing wait-loop helpers. `migration-helpers.sh` adds six
migration-specific helpers (`stop_test_vm`, `start_test_vm`,
`wait_for_vm_stopped`, `snapshot_pvc`, `wait_for_dv_succeeded`,
`patch_vm_volume_ref`).

---

## CLI flags

| Flag | Default | Notes |
|---|---|---|
| `--vm <name>` | — | Migrate one VM. |
| `--vm-filter <glob>` | — | Migrate VMs whose name matches the glob. |
| `--all` | — | Migrate every VM in the namespace. |
| `--target-sc <name>` | (required) | Target StorageClass. |
| `--namespace <ns>` | `vm-perf-test` (from `00-config.sh`) | |
| `--mode online\|offline` | `offline` | `online` rejects cross-`volumeMode`. |
| `--no-snapshot` | (snapshots on) | Skip the pre-migration `VolumeSnapshot`. |
| `--delete-source` | off | Delete source PVC + snapshot after success. |
| `--include-rootdisk` | off | Also migrate the OS root disk. |
| `--parallel <N>` | `1` | Migrate up to N VMs concurrently. |
| `--dry-run` | off | Print the plan; create nothing. |
| `--resume <run-id>` | — | Resume from a prior migration checkpoint. |

Exactly one of `--vm`, `--vm-filter`, `--all` is required.

Environment overrides (for power users):

- `RBD_SNAPCLASS` — defaults to `ocs-storagecluster-rbdplugin-snapclass`.
- `CEPHFS_SNAPCLASS` — defaults to `ocs-storagecluster-cephfsplugin-snapclass`.
- `DV_TIMEOUT` — per-PVC clone timeout in seconds (default 3600).

---

## Output and audit trail

Each run identifies itself as `mig-<timestamp>`. Outputs:

- `results/mig-<run-id>/<vm>.before.yaml` — VM spec snapshot before patching.
- `results/mig-<run-id>/<vm>.after.yaml`  — VM spec after patching.
- `results/mig-<run-id>.checkpoint` — append-only `vm:src_pvc:new_pvc` lines.
  Used by `--resume` to skip already-completed migrations.

Labels applied to clones, snapshots, and (in online mode) the blank target
PVC:

- `app=vm-perf-test`
- `migration/run-id=<mig-run-id>`
- `migration/source-pvc=<source-pvc-name>` (where applicable)

---

## Verification (per VM)

```bash
# 1. New PVC bound on the target SC with the expected volumeMode
oc get pvc <new-pvc> -n <ns> \
  -o jsonpath='{.spec.storageClassName} {.status.phase} {.spec.volumeMode}'

# 2. VM running and pointing at the new PVC
oc get vm <vm> -n <ns> -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{": "}{.persistentVolumeClaim.claimName}{.dataVolume.name}{"\n"}{end}'
oc get vmi <vm> -n <ns> -o jsonpath='{.status.phase}'

# 3. Guest-side sanity (requires SSH set up)
virtctl ssh -n <ns> <vm> --command "lsblk -o NAME,SIZE,FSTYPE"
```

The guest still sees `/dev/vdb` after a Block → Filesystem migration —
KubeVirt presents both source raw-block PVCs and Filesystem-backed
`disk.img` files identically via virtio-blk. No in-guest fstab change is
required.

---

## Worked example: ODF rep3-virt → IBM Cloud File CSI

This is the migration we ran during initial validation.

```bash
# Source VM: 50Gi raw block PVC on ocs-storagecluster-ceph-rbd-virtualization
./migration/migrate-vm-storage.sh --vm migtest --target-sc ibmc-vpc-file-500-iops
```

Approximate timeline (3-node ROKS bare-metal cluster, single zone):

| Step | Wall time |
|---|---|
| `VolumeSnapshot` of source PVC (RBD CoW) | < 1 s |
| `virtctl stop` + wait for Stopped | 1 s |
| CDI host-assisted clone of 50Gi raw block → 53Gi `disk.img` on NFS | 178 s |
| `oc apply` of patched VM spec | 4 s |
| `virtctl start` + wait for Running | 22 s |
| **Total** | **~3.5 min** |

After: VM Running, `datadisk` volume references the new PVC on
`ibmc-vpc-file-500-iops`, source 50Gi PVC and both snapshots preserved.

---

## Known issues / gotchas

### 1. IBM Cloud File `dp2` profile size minimum

The `dp2` profile enforces a maximum ~25 IOPS/GB ratio. The 3000-IOPS SC
needs ≥120Gi, the 1000-IOPS SC needs ≥40Gi, the 500-IOPS SC needs ≥20Gi.
If the source PVC is smaller than the target SC's minimum, CDI cannot
provision the target PVC and the clone hangs in `CloneInProgress`. Either:

- Pick a target SC whose minimum the source PVC size satisfies, or
- Resize the source PVC up before migrating.

This is already documented in the project `CLAUDE.md` ("PVC size
minimums").

### 2. Slow failure when the target PVC can't provision

If the target PVC stays `Pending` because the storage backend rejects the
request (e.g. the `dp2` minimum violation above), CDI keeps the
DataVolume in `CloneInProgress` rather than transitioning to `Failed`.
The script's current stall-detection logs a warning every ~50 s but waits
the full `DV_TIMEOUT` (default 60 min) before giving up. Workarounds:

- Watch `oc describe dv <name>` for repeated
  `failed to provision volume with StorageClass` events.
- Lower `DV_TIMEOUT` for impatient interactive runs:
  `DV_TIMEOUT=600 ./migration/migrate-vm-storage.sh ...`.

A future enhancement should poll the target PVC's events for repeated
provisioner errors and abort early.

### 3. Cross-`volumeMode` online migration is not possible

`--mode online` requires identical `volumeMode` on source and target.
RBD Block → Cloud File Filesystem must use the default offline mode. The
script enforces this at runtime.

### 4. Cloud File rounds capacity up

A 50Gi source PVC becomes a 53Gi target PVC on Cloud File CSI. This is a
backend rounding decision, not a script bug.

### 5. Root-disk migration is opt-in

The default skips volumes named `rootdisk`, `root`, `os`, or `boot`.
Pass `--include-rootdisk` to migrate them. Be aware that root-disk
migration is materially riskier (VM cannot boot if the migration
silently corrupts the OS image), so always keep `--no-snapshot` off
when migrating root disks.

### 6. VM lifecycle binding

If a VM was created with `dataVolumeTemplates` that own a PVC the script
needs to migrate, the script strips that template entry from the patched
VM spec. The implication: after a successful migration, deleting the VM
no longer cascades to the migrated PVC. This is intentional (you'd lose
your data otherwise) but means cleanup with `--delete-source` off leaves
PVCs behind when you eventually delete the VM.

---

## Rollback / recovery

The script never deletes source data unless `--delete-source` is set.
After a failed run:

- **Mid-clone failure**: the script rolls back partial clones for VMs
  with multiple PVCs, restarts the VM against the original spec, and
  logs the manual recovery command for the audit dump.
- **Post-patch failure**: the audit file
  `results/<mig-run-id>/<vm>.before.yaml` is the pre-migration spec; you
  can `oc apply -f <file>` to revert.
- **Snapshots** (if not disabled with `--no-snapshot`) can be restored
  via `oc create -f - <<EOF` of a `PersistentVolumeClaim` whose
  `spec.dataSource` points at the snapshot.

---

## Cleanup

The migration leaves these resources behind by default (intentionally):

- The source PVC, still bound, on the original SC.
- The pre-migration `VolumeSnapshot`.
- The migrated PVC (now attached to the VM, do not delete this).
- Audit YAML files under `results/mig-<run-id>/`.
- Checkpoint file `results/mig-<run-id>.checkpoint`.

To prune everything except the migrated PVC after you have verified the
VM is healthy:

```bash
RUN_ID=mig-20260527-174311  # the run you want to prune
NS=vm-perf-test

# Source PVCs from the checkpoint
awk -F: '{print $2}' results/${RUN_ID}.checkpoint | xargs -n1 -I{} \
  oc delete pvc {} -n ${NS} --wait=false

# Snapshots
oc delete volumesnapshot -n ${NS} -l migration/run-id=${RUN_ID}

# Audit files
rm -rf results/${RUN_ID}/ results/${RUN_ID}.checkpoint
```

Or skip the manual step and pass `--delete-source` on the original
migration command if you trust the migration to succeed.

---

## Out of scope (deliberately)

- **Cross-namespace migration.** CDI clone supports it but adds RBAC
  complexity; revisit if needed.
- **Cross-cluster migration.** Use MTV (Migration Toolkit for
  Virtualization) for that.
- **Migrating PVCs not attached to a VM.** Use a standalone CDI
  `DataVolume` clone directly — no script needed.
- **Performance benchmarking the migration itself.** The perf suite is
  the right tool; this script just moves data.
- **Automatic post-migration re-benchmarking.** Run
  `./04-run-tests.sh --rank` after migration to see if the move paid
  off.
