# Template Rendering

[Back to Index](../index.md)

This page explains how the test suite assembles fio profiles, cloud-init user-data, and VM manifests through a chain of template renderings. Understanding this pipeline is essential for debugging test failures or customizing the test setup.

## The Rendering Chain

The test suite transforms templates through three stages before applying them to the cluster. For the first permutation in each VM group, all three stages run. For subsequent permutations (reusing the same VMs), only Stage 1 runs — the rendered fio job is then delivered to the VM via SSH rather than cloud-init:

```
Stage 1: fio Profile Rendering
  05-fio-profiles/<profile>.fio
        │
        │  render_fio_profile()
        │  substitutes ${VARIABLE} placeholders
        ▼
  Rendered fio job content (in memory)

Stage 2: Cloud-init Rendering
  03-cloud-init/fio-runner.yaml
        │
        │  render_cloud_init()
        │  substitutes __PLACEHOLDER__ patterns
        │  embeds rendered fio job content
        ▼
  Rendered cloud-init YAML (in memory)

Stage 3: VM Manifest Rendering
  04-vm-templates/vm-template.yaml
        │
        │  create_test_vm()
        │  substitutes __PLACEHOLDER__ patterns
        │  embeds rendered cloud-init content
        ▼
  Complete VM manifest (piped to oc apply -f -)

For reused VMs (subsequent permutations in the same group):
  Rendered fio job content (from Stage 1)
        │
        │  replace_fio_job()
        │  base64-encodes content, writes via SSH + sudo tee
        ▼
  /opt/perf-test/fio-job.fio updated in the running VM
        │
        │  restart_fio_service()
        │  cleans old test data, stops/resets/starts service (--no-block)
        ▼
  fio benchmark running with the new profile
```

## Stage 1: fio Profile Rendering

**Function:** `render_fio_profile()` in `lib/vm-helpers.sh`

**Input:** A `.fio` template file from `05-fio-profiles/`

**Placeholder style:** `${VARIABLE}` (shell-style)

### Substitutions

| Placeholder | Source | Default |
|------------|--------|---------|
| `${RUNTIME}` | `FIO_RUNTIME` | 120 |
| `${RAMP_TIME}` | `FIO_RAMP_TIME` | 10 |
| `${IODEPTH}` | `FIO_IODEPTH` | 32 |
| `${NUMJOBS}` | `FIO_NUMJOBS` | 4 |
| `${FILE_SIZE}` | `FIO_TEST_FILE_SIZE` | 4G |
| `${BLOCK_SIZE}` | Current block size from the loop | 4k, 64k, or 1M |

### Example

Input (`sequential-rw.fio`):
```ini
[global]
ioengine=libaio
direct=1
runtime=${RUNTIME}
ramp_time=${RAMP_TIME}
iodepth=${IODEPTH}
numjobs=${NUMJOBS}
size=${FILE_SIZE}
bs=${BLOCK_SIZE}

[seq-read]
rw=read
stonewall
```

Output (after rendering with `block_size=4k`):
```ini
[global]
ioengine=libaio
direct=1
runtime=120
ramp_time=10
iodepth=32
numjobs=4
size=4G
bs=4k

[seq-read]
rw=read
stonewall
```

### Fixed-BS Profiles

For profiles in `FIO_FIXED_BS_PROFILES` (db-oltp, app-server, data-pipeline), the `${BLOCK_SIZE}` placeholder is not present in the template. Each job defines its own `bs=` value. The block_size parameter passed to `render_fio_profile()` is "native" and has no effect.

## Stage 2: Cloud-init Rendering

**Function:** `render_cloud_init()` in `lib/vm-helpers.sh`

**Input:** The cloud-init template (`03-cloud-init/fio-runner.yaml`)

**Placeholder style:** `__PLACEHOLDER__` (double-underscore)

### Substitutions

| Placeholder | Source | Purpose |
|------------|--------|---------|
| `__VM_NAME__` | Function argument | VM hostname and result file naming |
| `__TEST_DIR__` | Function argument (default: `/mnt/data`) | Where fio writes test files |
| `__RUNTIME__` | `FIO_RUNTIME` | Passed through to the runner script |
| `__RAMP_TIME__` | `FIO_RAMP_TIME` | Passed through to the runner script |
| `__IODEPTH__` | `FIO_IODEPTH` | Passed through to the runner script |
| `__NUMJOBS__` | `FIO_NUMJOBS` | Passed through to the runner script |
| `__FILE_SIZE__` | `FIO_TEST_FILE_SIZE` | Passed through to the runner script |
| `__SSH_PUB_KEY__` | `SSH_PUB_KEY` (from `ensure_ssh_key()`) | Injected into authorized_keys |
| `__FIO_TIMEOUT__` | `FIO_COMPLETION_TIMEOUT` | systemd TimeoutStartSec |
| `__FIO_JOB_CONTENT__` | Rendered fio job from Stage 1 | The actual fio workload definition |

### Embedding fio Content

The rendered fio job content is indented (6 spaces) before being substituted into the cloud-init template. This is necessary because the fio content sits inside a YAML `content: |` block:

```yaml
write_files:
  - path: /opt/perf-test/fio-job.fio
    content: |
      [global]            # ← fio content is indented 6 spaces
      ioengine=libaio     #    to align with YAML block scalar
      direct=1
```

The indentation is applied by:
```bash
indented_fio=$(echo "${fio_job_content}" | sed 's/^/      /')
```

## Stage 3: VM Manifest Rendering

**Function:** `create_test_vm()` in `lib/vm-helpers.sh`

**Input:** The VM template (`04-vm-templates/vm-template.yaml`)

**Placeholder style:** `__PLACEHOLDER__` (double-underscore)

### Substitutions

| Placeholder | Source | Purpose |
|------------|--------|---------|
| `__VM_NAME__` | Generated name | Resource name and labels |
| `__NAMESPACE__` | `TEST_NAMESPACE` | Where to create the VM |
| `__VCPU__` | From VM size definition | CPU allocation |
| `__MEMORY__` | From VM size definition | Memory allocation |
| `__SC_NAME__` | `get_storage_class_for_pool()` | StorageClass for the data disk |
| `__PVC_SIZE__` | Current PVC size from loop | Size of the data disk |
| `__ROOT_SC__` | `ODF_DEFAULT_SC` | StorageClass for root disk (always rep3) |
| `__POOL_NAME__` | Current pool name | Label for tracking |
| `__VM_SIZE_LABEL__` | e.g., "small", "medium" | Label for tracking |
| `__RUN_ID__` | `RUN_ID` | Label for targeted cleanup |
| `__DATASOURCE_NAME__` | `DATASOURCE_NAME` | DataSource name for root disk cloning |
| `__DATASOURCE_NAMESPACE__` | `DATASOURCE_NAMESPACE` | Namespace containing the DataSource |
| `__CLOUD_INIT_CONTENT__` | Rendered cloud-init from Stage 2 | Full cloud-init user-data |

### Embedding Cloud-init Content

Cloud-init content is indented 14 spaces to align with the VM template's nested YAML structure:

```yaml
spec:
  template:
    spec:
      volumes:
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config      # ← cloud-init indented 14 spaces
              hostname: perf-vm  #    deep inside the YAML hierarchy
```

The indentation is applied by:
```bash
indented_ci=$(echo "${cloud_init_content}" | sed 's/^/              /')
```

### The Output

The final rendered manifest contains two resources separated by `---`:
1. A **VirtualMachine** resource with all fields filled in
2. A **PersistentVolumeClaim** for the data disk

This complete YAML is piped directly to `oc apply -f -`.

## Why Not Helm or Kustomize?

The project uses simple string substitution rather than Helm charts or Kustomize overlays for several reasons:

1. **Zero additional dependencies** — No need to install Helm or deal with chart repositories
2. **Transparency** — What you see in the template is almost exactly what gets applied
3. **Simple debugging** — Add `echo "${manifest}"` before `oc apply` to see the full rendered output
4. **Runtime values** — The templates need values computed at runtime (rendered fio content, SSH keys, generated names) that would require complex Helm template logic
5. **Single-use templates** — These templates aren't reused across projects or shared via registries

### Trade-offs

The main drawback is that string substitution doesn't validate YAML structure. A placeholder that isn't replaced or an indentation error can produce invalid YAML. The `oc apply` command catches these errors at apply time.

## Debugging the Pipeline

If a VM fails to create or behaves unexpectedly:

### Check fio profile rendering
```bash
source 00-config.sh
source lib/vm-helpers.sh
render_fio_profile "05-fio-profiles/random-rw.fio" "4k"
```

### Check cloud-init rendering
```bash
ensure_ssh_key
rendered_fio=$(render_fio_profile "05-fio-profiles/random-rw.fio" "4k")
render_cloud_init "03-cloud-init/fio-runner.yaml" "${rendered_fio}" "test-vm" "/mnt/data"
```

### Check the full VM manifest
Add a temporary `echo` before the `oc apply` line in `create_test_vm()`:
```bash
echo "${manifest}" > /tmp/debug-vm.yaml  # Add this line
echo "${manifest}" | oc apply -f -       # Existing line
```

Then inspect `/tmp/debug-vm.yaml` for correctness.

## Next Steps

- [Project Architecture](project-architecture.md) — Overall script design
- [OpenShift Virtualization](../concepts/openshift-virtualization.md) — VM and cloud-init concepts
- [Customization](../guides/customization.md) — Modifying templates and profiles
