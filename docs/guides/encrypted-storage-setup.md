# ODF Encryption on IBM Cloud ROKS

This guide covers how OpenShift Data Foundation (ODF) encrypts data at rest on IBM Cloud ROKS clusters, how it integrates with IBM Key Protect, and the setup required to use encrypted StorageClasses.

> **Prerequisite:** If you're creating custom CephBlockPools, read the [CephBlockPool Setup Guide](ceph-pool-setup.md) first for correct pool configuration (`targetSizeRatio`, `deviceClass`, etc.).

## Encryption Layers Overview

Data at rest on a ROKS bare metal cluster can be encrypted at multiple layers. These layers are independent and cumulative:

| Layer | What it protects | Managed by | Key location |
|-------|-----------------|------------|-------------|
| **IBM Cloud infrastructure** | Physical NVMe drives (full-disk) | IBM Cloud platform | IBM-managed or customer BYOK |
| **ODF cluster-wide encryption** | All data on Ceph OSDs (dm-crypt on `storageDeviceSet` disks) | Rook-Ceph operator | KMS (Key Protect) |
| **ODF per-volume (StorageClass) encryption** | Individual RBD volumes (LUKS2) | Ceph CSI driver | KMS (Key Protect), per-volume DEK |

This cluster has all three layers enabled:
- Infrastructure encryption is handled by IBM Cloud on the `bx3d` bare metal NVMe drives.
- ODF cluster-wide encryption is enabled (`encryption.clusterWide: true` on the StorageCluster CR), encrypting all OSD disks via dm-crypt.
- Per-volume encryption is available via the `-encrypted` StorageClasses, adding a LUKS2 layer on individual RBD images.

### Why Per-Volume Encryption on Top of Cluster-Wide?

Cluster-wide encryption protects against physical disk theft — data on a removed drive is unreadable. However, anyone with Ceph admin credentials can still read volume data through the Ceph cluster. Per-volume encryption adds a LUKS2 layer so that each volume has its own data encryption key (DEK), and the volume is only decrypted on the node where it's mounted. This provides:

- **Tenant isolation** — volumes from different namespaces use different DEKs
- **Granular key management** — individual volume keys can be revoked
- **Defense in depth** — compromised Ceph credentials alone cannot read volume data

## How Per-Volume Encryption Works

### Key Hierarchy

```
IBM Key Protect (KMS)
  └── Customer Root Key (CRK)       ← you create this in Key Protect
        └── Data Encryption Key (DEK)  ← generated per volume by Ceph CSI
              └── LUKS2 volume         ← RBD image encrypted on the node
```

1. When a PVC is created with an encrypted StorageClass, the Ceph CSI provisioner generates a random DEK for the volume.
2. The DEK is wrapped (encrypted) using the Customer Root Key via the Key Protect API.
3. The wrapped DEK is stored as metadata on the RBD image.
4. When the volume is attached to a node, the CSI node plugin unwraps the DEK via Key Protect and uses it to open the LUKS2 device.

### Encryption at the Block Level

Per-volume encryption uses **LUKS2** with **dm-crypt** on the worker node. The CSI node plugin:
1. Maps the RBD image to a block device on the node (`/dev/rbdX`)
2. Opens a LUKS2 container on that device using the unwrapped DEK
3. Exposes the decrypted device (`/dev/mapper/luks-*`) to the pod/VM

Encryption and decryption happen in the kernel via dm-crypt using AES-256-XTS. This adds CPU overhead on the worker node, which is why comparing `rep3` vs `rep3-enc` performance is useful.

## IBM Key Protect Integration

On ROKS, ODF uses [IBM Key Protect](https://cloud.ibm.com/docs/key-protect) as the external KMS. The integration involves three Kubernetes resources in the `openshift-storage` namespace:

### 1. KMS Connection ConfigMap

`csi-kms-connection-details` defines how the CSI driver reaches Key Protect:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: csi-kms-connection-details
  namespace: openshift-storage
data:
  <kms-id>: |
    {
      "KMS_PROVIDER": "ibmkeyprotect",
      "KMS_SERVICE_NAME": "<kms-id>",
      "IBM_KP_SERVICE_INSTANCE_ID": "<key-protect-instance-guid>",
      "IBM_KP_SECRET_NAME": "ibm-kp-secret",
      "IBM_KP_BASE_URL": "https://<region>.kms.cloud.ibm.com",
      "IBM_KP_TOKEN_URL": "https://iam.cloud.ibm.com/oidc/token"
    }
```

| Field | Description |
|-------|-------------|
| `KMS_PROVIDER` | Always `ibmkeyprotect` for Key Protect |
| `KMS_SERVICE_NAME` | Arbitrary identifier, referenced by `encryptionKMSID` in StorageClasses |
| `IBM_KP_SERVICE_INSTANCE_ID` | GUID of the Key Protect instance (from IBM Cloud console) |
| `IBM_KP_SECRET_NAME` | Name of the Secret containing the API key and root key |
| `IBM_KP_BASE_URL` | Regional Key Protect endpoint (must match the instance's region) |
| `IBM_KP_TOKEN_URL` | IAM token endpoint (always `https://iam.cloud.ibm.com/oidc/token`) |

This ConfigMap is created during ODF installation when encryption with KMS is enabled. On this cluster, the KMS ID is `ocp-virt-420-kp` and the Key Protect instance is in `eu-de`.

### 2. KMS Credentials Secret

`ibm-kp-secret` in `openshift-storage` contains the credentials the CSI provisioner uses to call the Key Protect API:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ibm-kp-secret
  namespace: openshift-storage
type: Opaque
data:
  IBM_KP_SERVICE_API_KEY: <base64-encoded IAM API key>
  IBM_KP_CUSTOMER_ROOT_KEY: <base64-encoded root key ID>
```

| Key | Description |
|-----|-------------|
| `IBM_KP_SERVICE_API_KEY` | IBM Cloud IAM API key with `KeyPurge`, `Manager` or equivalent role on the Key Protect instance |
| `IBM_KP_CUSTOMER_ROOT_KEY` | The ID (UUID) of the root key in Key Protect used to wrap per-volume DEKs |

To create this secret:

```bash
oc create secret generic ibm-kp-secret \
  --from-literal=IBM_KP_SERVICE_API_KEY="<iam-api-key>" \
  --from-literal=IBM_KP_CUSTOMER_ROOT_KEY="<root-key-id>" \
  -n openshift-storage
```

### 3. Per-Namespace Tenant Token

`ceph-csi-kms-token` must exist in **every namespace** where encrypted PVCs are created. This is the piece most commonly missed. Without it, PVCs stay `Pending` with the CSI provisioner waiting indefinitely.

The token value is the same IAM API key from `ibm-kp-secret`. For the test suite's namespace (`vm-perf-test`), **`01-setup-storage-pools.sh` creates this secret automatically** when `rep3-enc` is in the pool list. It copies the API key from `ibm-kp-secret` in the ODF namespace.

To create it manually for other namespaces:

```bash
oc create secret generic ceph-csi-kms-token \
  --from-literal=token="$(oc get secret ibm-kp-secret -n openshift-storage \
    -o jsonpath='{.data.IBM_KP_SERVICE_API_KEY}' | base64 -d)" \
  -n <NAMESPACE>
```

For this test suite, the secret must exist in:

| Namespace | Created by | Purpose |
|-----------|------------|---------|
| `vm-perf-test` | `01-setup-storage-pools.sh` (automatic) | Benchmark VMs created by `04-run-tests.sh` |
| `default` | Manual (see command above) | Ad-hoc VM testing |

**Why a separate per-namespace secret?** This is a security boundary. Cluster admins control which namespaces can provision encrypted volumes by choosing where to create this secret. A namespace without the secret cannot create encrypted PVCs.

## Encrypted StorageClasses

ODF creates encrypted StorageClasses automatically when `encryption.storageClass: true` is set on the StorageCluster CR. The encrypted SC mirrors its non-encrypted counterpart but adds two parameters:

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `encrypted` | `"true"` | Tells the CSI driver to create a LUKS2 volume |
| `encryptionKMSID` | KMS ID string | References an entry in `csi-kms-connection-details` |

### StorageClasses on This Cluster

| StorageClass | Pool | Encrypted | Notes |
|-------------|------|-----------|-------|
| `ocs-storagecluster-ceph-rbd` | `ocs-storagecluster-cephblockpool` | No | Default rep3 |
| `ocs-storagecluster-ceph-rbd-encrypted` | `ocs-storagecluster-cephblockpool` | Yes | Same pool, LUKS2 layer added |
| `ocs-storagecluster-ceph-rbd-virtualization` | `ocs-storagecluster-cephblockpool` | No | Default for VMs (Block mode, RWX) |

Note that the encrypted and non-encrypted variants use the **same underlying Ceph pool**. The LUKS2 layer is applied at the node level by the CSI driver, not within Ceph itself. This means pool-level metrics (IOPS, throughput from Ceph's perspective) are unaffected — the overhead shows up as CPU usage on the worker node.

### Encrypted vs Non-Encrypted SC Differences

The only difference in the StorageClass spec:

```diff
  parameters:
+   encrypted: "true"
+   encryptionKMSID: ocp-virt-420-kp
```

Additionally, the encrypted SC has `cdi.kubevirt.io/clone-strategy: copy` (rather than smart-clone/snapshot) because LUKS metadata makes snapshot-based cloning incompatible. See [Cloning from Unencrypted Sources](#cloning-from-unencrypted-sources) for a critical limitation this creates for VMs.

## Cluster-Wide Encryption

Independent of per-volume encryption, this cluster has ODF cluster-wide encryption enabled. This is configured on the StorageCluster CR:

```yaml
spec:
  encryption:
    clusterWide: true
    enable: true
    keyRotation:
      schedule: '@weekly'
    kms:
      enable: true
    storageClass: true
```

| Field | Value | Meaning |
|-------|-------|---------|
| `enable` | `true` | Master switch for encryption features |
| `clusterWide` | `true` | All OSD disks encrypted with dm-crypt at the device level |
| `kms.enable` | `true` | Use external KMS (Key Protect) rather than Kubernetes Secrets for key storage |
| `storageClass` | `true` | Auto-create `-encrypted` StorageClasses |
| `keyRotation.schedule` | `@weekly` | Automatic key rotation cadence for cluster-wide keys |

Cluster-wide encryption means the raw block devices backing Ceph OSDs are encrypted before Ceph writes to them. This is transparent to Ceph — the OSD process sees a normal block device, but the underlying physical data is encrypted.

## Key Rotation

Key rotation happens at two levels:

### Cluster-Wide Key Rotation

Configured via `encryption.keyRotation.schedule` on the StorageCluster CR (currently `@weekly`). The Rook operator rotates the dm-crypt keys for the OSD devices. This is automatic and requires no manual intervention.

### Per-Volume Key Rotation

Per-volume DEK rotation is not automatic. To rotate a volume's DEK:

1. Create a new root key in Key Protect
2. Update `IBM_KP_CUSTOMER_ROOT_KEY` in `ibm-kp-secret`
3. Newly created volumes will use the new root key
4. Existing volumes continue using their original wrapped DEK until re-encrypted

The root key in Key Protect can itself be rotated via the Key Protect API or console, which re-wraps all DEKs encrypted under it without changing the DEKs themselves.

## Performance Implications

Per-volume LUKS2 encryption adds overhead:

| Metric | Impact | Why |
|--------|--------|-----|
| **IOPS** | Moderate decrease | Each I/O requires AES encrypt/decrypt in the kernel |
| **Throughput** | Moderate decrease | Bounded by AES-NI throughput on the CPU |
| **Latency** | Slight increase | Extra dm-crypt layer in the I/O path |
| **CPU** | Increase on worker nodes | dm-crypt uses CPU cores for AES-256-XTS |

Modern bare metal CPUs (like the Sapphire Rapids in `bx3d` workers) have AES-NI hardware acceleration, which significantly reduces the overhead. The `rep3` vs `rep3-enc` comparison in this test suite quantifies the actual cost.

Cluster-wide encryption adds a second dm-crypt layer at the OSD device level. With both cluster-wide and per-volume encryption enabled, data is encrypted twice — once by the OSD dm-crypt (at the device layer) and once by the volume LUKS2 (at the RBD image layer). The combined overhead is roughly additive.

## Verification

```bash
# 1. Check cluster-wide encryption status
oc get storagecluster -n openshift-storage \
  -o jsonpath='{.items[0].spec.encryption}' | jq .

# 2. Check KMS connection
oc get configmap csi-kms-connection-details -n openshift-storage -o yaml

# 3. Check KMS credentials exist (do NOT print values)
oc get secret ibm-kp-secret -n openshift-storage \
  -o jsonpath='{.data}' | jq 'keys'

# 4. Check per-namespace token exists
oc get secret ceph-csi-kms-token -n default
oc get secret ceph-csi-kms-token -n vm-perf-test

# 5. Verify encrypted SC works end-to-end
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-encrypted-pvc
spec:
  storageClassName: ocs-storagecluster-ceph-rbd-encrypted
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF
oc get pvc test-encrypted-pvc -w   # Should reach Bound within ~30s
oc delete pvc test-encrypted-pvc
```

## Cloning from Unencrypted Sources

The Ceph CSI driver **cannot create an encrypted volume from a snapshot of an unencrypted volume**. This is a hard constraint in the RBD CSI plugin — it will reject the request with:

```
cannot create encrypted volume from unencrypted volume
"ocs-storagecluster-cephblockpool/csi-vol-..."
```

### Impact on VMs

This directly affects VM creation. OpenShift Virtualization boots VMs by cloning a root disk from a golden image DataSource (e.g., the Fedora image in `openshift-virtualization-os-images`). These golden images are stored as **unencrypted** RBD volumes. If you create a VM from the OpenShift console and select the encrypted StorageClass for the root disk, the DataVolume clone will fail silently — the VM stays in `Provisioning` with the PVC stuck in `Pending` indefinitely.

The CSI provisioner retries every few minutes but the error is permanent. The only indication is in the CSI controller pod logs (`openshift-storage.rbd.csi.ceph.com-ctrlplugin-*`), not in `oc get events`.

### What Works and What Doesn't

| Scenario | Works? | Why |
|----------|--------|-----|
| New empty encrypted PVC | Yes | No source volume involved |
| Clone encrypted volume to encrypted volume | Yes | Source and target are both encrypted |
| Clone unencrypted snapshot to encrypted volume | **No** | CSI refuses cross-encryption-boundary clones |
| VM root disk with encrypted SC (from console) | **No** | Golden image DataSources are unencrypted |
| VM data disk with encrypted SC | Yes | Created as an empty PVC, no clone |

### Workarounds

**For the OpenShift console:** Do not select the encrypted StorageClass for VM root disks. Use `ocs-storagecluster-ceph-rbd` or `ocs-storagecluster-ceph-rbd-virtualization` for the boot disk. If you need the data disk encrypted, add a second disk using the encrypted SC. Alternatively, use one of the YAML templates below.

### How the Test Suite Handles Encryption

The existing project template (`vm-templates/vm-template.yaml`) already handles encrypted pools correctly. It uses two separate StorageClass placeholders:

| Placeholder | Set To | Purpose |
|-------------|--------|---------|
| `__ROOT_SC__` | `ODF_DEFAULT_SC` (`ocs-storagecluster-ceph-rbd`) | Root disk — always non-encrypted so the golden image clone works |
| `__SC_NAME__` | Pool-specific SC (e.g., `ocs-storagecluster-ceph-rbd-encrypted` for `rep3-enc`) | Data disk — the PVC under test |

This separation is handled in `lib/vm-helpers.sh:create_test_vm()`:

```bash
# Root disk always uses the default (non-encrypted) SC
local root_sc="${ODF_DEFAULT_SC}"

# Data disk uses the pool-specific SC (encrypted for rep3-enc)
manifest="${manifest//__SC_NAME__/${sc_name}}"
manifest="${manifest//__ROOT_SC__/${root_sc}}"
```

So when you run `./04-run-tests.sh --pool rep3-enc`, it:
1. Resolves `rep3-enc` to `ocs-storagecluster-ceph-rbd-encrypted` via `get_storage_class_for_pool()`
2. Uses that SC for the data PVC (`__SC_NAME__`)
3. Uses the non-encrypted default for the root disk (`__ROOT_SC__`)
4. The data PVC is created empty (not cloned), so no cross-encryption-boundary issue

No template changes are needed to benchmark encrypted pools — just run:

```bash
./04-run-tests.sh --quick --pool rep3-enc
```

### Creating Custom VM Templates for Encrypted Pools

If you want to create your own VM templates for encrypted storage outside the test suite, the key rule is: **use the non-encrypted SC for the root disk, encrypted SC for additional disks only**.

You can copy the existing project template as a starting point:

```bash
cp vm-templates/vm-template.yaml vm-templates/vm-template-encrypted.yaml
```

The template is already structured correctly — the root disk DataVolume uses `__ROOT_SC__` (non-encrypted) and the data PVC uses `__SC_NAME__` (pool-specific). No modifications are needed. But if you want a self-contained template without placeholders (for use outside the test suite), see the standalone example below.

### Standalone VM Template with Encrypted Data Disk

The following creates a Fedora VM with a **non-encrypted root disk** (cloned from the golden image) and an **encrypted data disk**. No placeholder substitution needed — apply directly with `oc apply`.

Ensure the `ceph-csi-kms-token` secret exists in the target namespace before applying.

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fedora-encrypted-demo
  labels:
    app: fedora-encrypted-demo
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app: fedora-encrypted-demo
    spec:
      domain:
        cpu:
          cores: 2
          sockets: 1
          threads: 1
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: datadisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
          rng: {}
        resources:
          requests:
            memory: 4Gi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          dataVolume:
            name: fedora-encrypted-demo-rootdisk
        - name: datadisk
          persistentVolumeClaim:
            claimName: fedora-encrypted-demo-data
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              chpasswd:
                expire: false
              ssh_authorized_keys: []
  dataVolumeTemplates:
    - metadata:
        name: fedora-encrypted-demo-rootdisk
      spec:
        storage:
          resources:
            requests:
              storage: 30Gi
          # Root disk: MUST use non-encrypted SC (golden image is unencrypted)
          storageClassName: ocs-storagecluster-ceph-rbd
        sourceRef:
          kind: DataSource
          name: fedora
          namespace: openshift-virtualization-os-images
---
# Data disk: encrypted via LUKS2 + Key Protect
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fedora-encrypted-demo-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ocs-storagecluster-ceph-rbd-encrypted
  resources:
    requests:
      storage: 50Gi
```

To apply:

```bash
# Ensure the tenant token exists in the target namespace
oc get secret ceph-csi-kms-token -n default || \
  oc create secret generic ceph-csi-kms-token \
    --from-literal=token="$(oc get secret ibm-kp-secret -n openshift-storage \
      -o jsonpath='{.data.IBM_KP_SERVICE_API_KEY}' | base64 -d)" \
    -n default

# Create the VM
oc apply -f fedora-encrypted-vm.yaml -n default

# Watch it boot (root disk clones in ~20-30s, data PVC binds immediately)
oc get vm fedora-encrypted-demo -w
```

### Adapting the Standalone Template

To customise the template for different use cases:

| Change | What to modify |
|--------|---------------|
| Different OS | Change `sourceRef.name` in `dataVolumeTemplates` (see table below) |
| Larger root disk | Change `storage: 30Gi` in `dataVolumeTemplates` |
| Different VM size | Change `cores` and `memory` |
| Root disk also encrypted | Not possible with golden image cloning (see above) |
| Multiple encrypted data disks | Add more PVC resources and corresponding entries in `spec.template.spec.domain.devices.disks` and `spec.template.spec.volumes` |

Available DataSources for the root disk (replace `fedora` in `sourceRef.name`):

| DataSource | OS |
|------------|----|
| `fedora` | Fedora (latest) |
| `centos-stream9` | CentOS Stream 9 |
| `centos-stream10` | CentOS Stream 10 |
| `rhel8` | RHEL 8 |
| `rhel9` | RHEL 9 |
| `rhel10` | RHEL 10 |
| `win10` | Windows 10 |
| `win11` | Windows 11 |

### Why Cloning to Encrypted PVCs Fails

You might expect that CDI's host-assisted copy (`cdi.kubevirt.io/clone-strategy: copy`) would allow copying a non-encrypted golden image into an encrypted PVC — bypassing the CSI snapshot limitation. In practice, this also fails. The CDI source pod successfully reads and streams all the data, but the upload server returns `400 Bad Request` when finalizing the write to the encrypted target:

```
clone-source.go:127 Wrote 32212254720 bytes
clone-source.go:267 Unexpected status code 400
```

The CDI upload server cannot write to LUKS2-encrypted block devices because the encryption layer (dm-crypt) is managed by the CSI node plugin, not by CDI. The source pod restarts repeatedly, causing the progress to loop from 99% back to 0%.

**Both CDI clone strategies fail with encrypted targets:**

| Strategy | Mechanism | Failure Point |
|----------|-----------|---------------|
| CSI snapshot clone | `CreateVolume` from snapshot | CSI driver rejects: "cannot create encrypted volume from unencrypted volume" |
| Host-assisted copy | CDI pods read source, upload to target | Upload server returns 400 writing to LUKS2 device |

### Fully Encrypted Boot Disks via Direct Import

While **cloning** to encrypted PVCs fails, **importing** directly into one works. CDI's importer pod writes to the PVC after the CSI node plugin has already opened the LUKS2 container, so the importer sees a normal block device.

The OpenShift Virtualization golden images come from container disk registries (e.g., `quay.io/containerdisks/fedora:latest`). Instead of cloning from the pre-cached DataSource, you can import the same image directly into an encrypted PVC using `source: registry`:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: fedora-enc-import
spec:
  storage:
    resources:
      requests:
        storage: 30Gi
    storageClassName: ocs-storagecluster-ceph-rbd-encrypted
  source:
    registry:
      pullMethod: node
      url: "docker://quay.io/containerdisks/fedora:latest"
```

This imports in about 40 seconds. Once the DataVolume reaches `Succeeded`, create the VM using it as the boot disk:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fedora-fully-encrypted
  labels:
    app: fedora-fully-encrypted
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app: fedora-fully-encrypted
    spec:
      domain:
        cpu:
          cores: 2
          sockets: 1
          threads: 1
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
          rng: {}
        resources:
          requests:
            memory: 4Gi
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          persistentVolumeClaim:
            claimName: fedora-enc-import
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              user: fedora
              password: fedora
              chpasswd:
                expire: false
```

To apply both resources:

```bash
# Ensure KMS token exists
oc get secret ceph-csi-kms-token -n default || \
  oc create secret generic ceph-csi-kms-token \
    --from-literal=token="$(oc get secret ibm-kp-secret -n openshift-storage \
      -o jsonpath='{.data.IBM_KP_SERVICE_API_KEY}' | base64 -d)" \
    -n default

# Import the image into an encrypted PVC
oc apply -f fedora-enc-import-dv.yaml -n default

# Wait for import to complete (~40s)
oc get dv fedora-enc-import -w

# Create the VM once the DV shows Succeeded
oc apply -f fedora-fully-encrypted-vm.yaml -n default

# Watch it boot
oc get vm fedora-fully-encrypted -w
```

### Creating a Reusable Encrypted DataSource

To avoid re-importing the image for every new VM, snapshot the encrypted PVC and register it as a DataSource:

```bash
# Snapshot the encrypted root disk
cat <<EOF | oc apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: fedora-encrypted-snapshot
  namespace: default
spec:
  volumeSnapshotClassName: ocs-storagecluster-rbdplugin-snapclass
  source:
    persistentVolumeClaimName: fedora-enc-import
EOF

# Wait for snapshot to be ready
oc get volumesnapshot fedora-encrypted-snapshot -w

# Register it as a DataSource
cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: fedora-encrypted
  namespace: default
spec:
  source:
    snapshot:
      name: fedora-encrypted-snapshot
      namespace: default
EOF
```

New VMs can then clone from this encrypted DataSource using `sourceRef` — since both source and target are encrypted, the CSI snapshot clone works:

```yaml
dataVolumeTemplates:
  - metadata:
      name: my-vm-rootdisk
    spec:
      storage:
        resources:
          requests:
            storage: 30Gi
        storageClassName: ocs-storagecluster-ceph-rbd-encrypted
      sourceRef:
        kind: DataSource
        name: fedora-encrypted
        namespace: default
```

This gives you fast snapshot-based cloning for encrypted boot disks. The trade-off is that the encrypted DataSource is not auto-updated by the DataImportCron — you must re-import and re-snapshot when you want a newer Fedora image.

### Container Disk Registry URLs

To find the registry URL for other OS images, check the DataImportCron:

```bash
oc get dataimportcron -n openshift-virtualization-os-images \
  -o custom-columns='NAME:.metadata.name,URL:.spec.template.spec.source.registry.url'
```

Common images:

| OS | Registry URL |
|----|-------------|
| Fedora | `docker://quay.io/containerdisks/fedora:latest` |
| CentOS Stream 9 | `docker://quay.io/containerdisks/centos-stream:9` |
| RHEL 9 | `docker://registry.redhat.io/rhel9/rhel-guest-image:latest` |

### When to Use Each Approach

| Approach | Boot disk encrypted? | Clone speed | Auto-updates? | Complexity |
|----------|---------------------|-------------|--------------|------------|
| Non-encrypted root + encrypted data | No (cluster-wide still protects it) | Fast (snapshot clone) | Yes (DataImportCron) | Low |
| Direct import to encrypted PVC | Yes (LUKS2) | Slow (re-import each VM) | No | Low |
| Encrypted DataSource (snapshot) | Yes (LUKS2) | Fast (snapshot clone) | No (manual re-import) | Medium |

For most use cases, the first approach (non-encrypted root, encrypted data) is sufficient — cluster-wide encryption already protects boot disk data at the physical layer. Use the direct import or encrypted DataSource approaches only when compliance requires per-volume LUKS2 on all disks.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| PVC stuck in `Pending`, no provisioner errors | `ceph-csi-kms-token` missing in PVC namespace | Create the tenant token secret (see above) |
| PVC `Pending` + `ExternalProvisioning` event | CSI provisioner waiting on KMS authentication | Check `ibm-kp-secret` exists and API key is valid |
| PVC `Pending` + KMS connection error in CSI logs | Wrong `IBM_KP_BASE_URL` region or Key Protect instance unreachable | Verify endpoint matches Key Protect region |
| PVC `Pending` + `InvalidRootKey` | Root key ID in `ibm-kp-secret` doesn't exist in Key Protect | Verify the root key exists and is in `Active` state |
| DV `CloneFromSnapshotSourceInProgress` indefinitely | Clone waiting on PVC which is stuck due to missing token | Fix the PVC issue; the DV resumes automatically |
| VM stuck in `Provisioning`, PVC `Pending`, no events | Encrypted SC used for root disk cloned from unencrypted golden image | Check CSI controller logs; use non-encrypted SC for root disk (see [Cloning from Unencrypted Sources](#cloning-from-unencrypted-sources)) |
| Encrypted clone slower than non-encrypted | `cdi.kubevirt.io/clone-strategy: copy` forces full data copy | Expected — LUKS volumes cannot use CSI snapshot-based cloning |
| Encrypted PVC works but VM fails to boot | LUKS open fails on node (dm-crypt error) | Check `dmesg` on the worker node; may indicate kernel/dm-crypt issue |
| IAM authentication failures after key rotation | API key rotated in IBM Cloud but not updated in cluster | Update `ibm-kp-secret` and re-create `ceph-csi-kms-token` in all namespaces |

## References

- [ODF Encryption Documentation (Red Hat)](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.18/html/managing_and_allocating_storage_resources/configuring-storage-encryption_rhodf)
- [IBM Key Protect Documentation](https://cloud.ibm.com/docs/key-protect)
- [Ceph CSI Encryption (upstream)](https://github.com/ceph/ceph-csi/blob/devel/docs/deploy-rbd.md#encryption-for-rbd-volumes)
- [LUKS2 Specification](https://gitlab.com/cryptsetup/LUKS2-docs)
