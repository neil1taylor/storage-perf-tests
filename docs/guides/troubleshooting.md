# Troubleshooting

[Back to Index](../index.md)

This page covers common issues and their solutions. Check the relevant section based on where the failure occurs.

## Storage Pool Issues

### CephBlockPool Not Ready

**Symptom:** `01-setup-storage-pools.sh` creates the pool but it never reaches `Ready` state, or `06-run-tests.sh` skips the pool.

**Check:**
```bash
oc get cephblockpool -n openshift-storage
oc describe cephblockpool perf-test-ec-4-2 -n openshift-storage
```

**Common causes:**
- **Not enough OSDs:** EC pools require at least k+m OSDs on separate failure domains. ec-4-2 needs 6 hosts with OSDs.
  - Fix: Reduce EC parameters or add more workers
- **Ceph cluster unhealthy:** Check overall Ceph health
  ```bash
  oc exec -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph status
  ```
- **ODF namespace wrong:** Verify `ODF_NAMESPACE` in `00-config.sh` matches your cluster

### StorageClass Not Found

**Symptom:** Test run logs `StorageClass <name> not found — skipping pool`

**Check:**
```bash
oc get sc | grep perf-test
oc get sc | grep vpc-file
```

**Fixes:**
- Run `./01-setup-storage-pools.sh` to create ODF StorageClasses
- Run `./02-setup-file-storage.sh` to discover File CSI StorageClasses
- Verify the StorageClass provisioner pods are running

## VM Boot Failures

### VM Stuck in Scheduling

**Symptom:** VM doesn't reach Running state; VMI shows `Scheduling` or `Pending`.

**Check:**
```bash
oc get vmi -n vm-perf-test
oc describe vmi <vm-name> -n vm-perf-test
oc get events -n vm-perf-test --sort-by='.lastTimestamp' | tail -20
```

**Common causes:**
- **Insufficient resources:** Not enough CPU or memory on the cluster. Check:
  ```bash
  oc describe nodes | grep -A5 "Allocated resources"
  ```
- **PVC not bound:** The data disk PVC is stuck in Pending. Check:
  ```bash
  oc get pvc -n vm-perf-test
  oc describe pvc <vm-name>-data -n vm-perf-test
  ```
- **Image clone slow:** DataVolume for root disk is still cloning. The test suite automatically monitors DV clone progress and logs status changes:
  ```
  [INFO] VM perf-rep3-small-50gi-c1-1: DV clone in progress (15.0%)
  [INFO] VM perf-rep3-small-50gi-c1-1: DV clone complete, waiting for VM boot...
  ```
  If progress stalls (unchanged for `DV_STALL_THRESHOLD` consecutive polls), a warning is logged. Set `DV_STALL_ACTION=fail` to abort immediately on stall. To check manually:
  ```bash
  oc get dv -n vm-perf-test
  ```
- **VM Failure condition:** If the VM object itself reports a failure (e.g., bad DataSource reference), `wait_for_vm_running` detects it on the first poll and fails immediately with the error message. Check:
  ```bash
  oc get vm <vm-name> -n vm-perf-test -o jsonpath='{.status.conditions}'
  ```

### VM Starts But fio Doesn't Run

**Symptom:** VM reaches Running state but the fio service never completes.

**Check (SSH into the VM):**
```bash
virtctl ssh --namespace=vm-perf-test --identity-file=./ssh-keys/perf-test-key fedora@<vm-name>

# Inside the VM:
systemctl status perf-test.service
journalctl -u perf-test.service
cat /opt/perf-test/fio-job.fio
ls -la /mnt/data/
```

**Common causes:**
- **Cloud-init failed:** fio was never installed
  ```bash
  # Check cloud-init status
  cloud-init status --long
  cat /var/log/cloud-init-output.log
  ```
- **fio job file empty or malformed:** Rendering error in the template pipeline
- **Data disk not mounted:** The PVC is bound but not mounted at `/mnt/data`
  ```bash
  lsblk
  mount | grep data
  ```

## SSH Issues

### Cannot SSH into VM

**Symptom:** `virtctl ssh` fails or times out.

**Check:**
```bash
# Verify VM is running
oc get vmi <vm-name> -n vm-perf-test

# Check the SSH key exists
ls -la ssh-keys/perf-test-key

# Try verbose SSH
virtctl ssh --namespace=vm-perf-test --identity-file=./ssh-keys/perf-test-key -v fedora@<vm-name>
```

**Common causes:**
- **VM not fully booted:** cloud-init is still running. Wait a minute and retry.
- **SSH key mismatch:** The SSH key was regenerated between pool setup and test run. Delete VMs and re-run.
- **Network issue:** Check the pod network:
  ```bash
  oc get pods -n vm-perf-test -l vm.kubevirt.io/name=<vm-name>
  ```

### SSH Key Not Found

**Symptom:** Error about missing SSH key file.

**Fix:** The key is generated automatically by `ensure_ssh_key()` on first run. If it was deleted:
```bash
# Regenerate
ssh-keygen -t ed25519 -f ./ssh-keys/perf-test-key -N "" -C "perf-test"
```

## fio Service Timeouts

### fio Exceeds Timeout

**Symptom:** Log shows `fio in VM <name> did not complete within 900s`

**Common causes:**
- **Large test file on slow storage:** 4G file creation takes time on File CSI
  - Fix: Increase `FIO_COMPLETION_TIMEOUT` or decrease `FIO_TEST_FILE_SIZE`
- **Storage is overwhelmed:** High concurrency with slow EC pools
  - Fix: Reduce concurrency levels or increase timeout
- **VM is under-resourced:** Small VMs with heavy workloads
  - Fix: Use larger VM sizes for demanding profiles

**Recommended formula:**
```
FIO_COMPLETION_TIMEOUT ≥ FIO_RUNTIME + FIO_RAMP_TIME + 180
```
The extra 180 seconds accounts for file creation, fio startup, and result writing.

### fio Exits With Error

**Symptom:** Service status shows non-zero exit code.

**Check:**
```bash
virtctl ssh ... fedora@<vm-name> -- journalctl -u perf-test.service
```

**Common causes:**
- **Disk full:** Test file size exceeds PVC size
  - Fix: Ensure `FIO_TEST_FILE_SIZE × FIO_NUMJOBS < PVC_SIZE`. For 4G × 4 = 16G, PVC must be at least 20Gi (with overhead).
- **Permission error:** Cannot write to `/mnt/data`
- **fio job syntax error:** Malformed `.fio` file. Test locally with `fio --parse-only <file.fio>`

## Report Generation Issues

### CSV Empty or Missing

**Symptom:** `07-collect-results.sh` produces a CSV with only the header.

**Check:**
```bash
# Are there any fio JSON files?
find results/ -name "*-fio.json" | head -5

# Check if they contain valid JSON
cat results/rep3/small/50Gi/1/random-rw/4k/*-fio.json | jq '.jobs | length'
```

**Fixes:**
- If no JSON files exist, the test run failed to collect results (check SSH issues above)
- If JSON files are empty or malformed, there was a collection error

### HTML Report Shows No Data

**Symptom:** Dashboard loads but charts are empty.

**Check:** Open the browser developer console (F12) for JavaScript errors. The most common cause is an empty or malformed CSV.

### XLSX Generation Fails

**Symptom:** Error from `08-generate-report.sh` about openpyxl.

**Fix:**
```bash
pip3 install openpyxl
```

## PVC Issues

### PVC Stuck in Pending

**Symptom:** PVC never reaches Bound state.

**Check:**
```bash
oc describe pvc <name> -n vm-perf-test
```

**Common causes:**
- **StorageClass doesn't exist:** Check `oc get sc`
- **Missing KMS token (encrypted pools):** Encrypted PVCs require the `ceph-csi-kms-token` secret in the test namespace. `01-setup-storage-pools.sh` creates this automatically when `rep3-enc` is in the pool list, but if you skipped that step or the source secret `ibm-kp-secret` was missing:
  ```bash
  oc get secret ceph-csi-kms-token -n vm-perf-test
  # If missing, re-run: ./01-setup-storage-pools.sh
  ```
  See [Encrypted Storage Setup](encrypted-storage-setup.md) for manual creation.
- **Storage capacity exhausted:** Ceph pools may be full
  ```bash
  oc exec -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph df
  ```
- **Provisioner pod not running:** Check CSI driver pods
  ```bash
  oc get pods -n openshift-storage | grep csi
  ```

### PVC Stuck Terminating

**Symptom:** PVCs remain in `Terminating` state after cleanup.

**Check:**
```bash
oc get pvc -n vm-perf-test
oc describe pvc <name> -n vm-perf-test
```

**Common causes:**
- **Finalizer preventing deletion:** A pod or VM is still using the PVC
  ```bash
  # Check for pods using the PVC
  oc get pods -n vm-perf-test | grep <vm-name>

  # Force-delete the pod if the VM is already gone
  oc delete pod <pod-name> -n vm-perf-test --force --grace-period=0
  ```
- **Ceph RBD volume locked:** The RBD image has a lock that prevents deletion
  - Usually resolves after a few minutes
  - Check Ceph for stuck operations

## General Debugging

### Enable Debug Logging

```bash
LOG_LEVEL=DEBUG ./06-run-tests.sh
```

This outputs detailed polling status, rendering steps, and timing information.

### Check Test Logs

```bash
# Real-time log following
tail -f results/perf-*.log

# Search for errors
grep -i error results/perf-*.log
grep -i warn results/perf-*.log
```

### Check ODF / Ceph Health

```bash
# Ceph status
oc exec -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph status

# OSD tree
oc exec -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph osd tree

# Pool stats
oc exec -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph osd pool stats

# Check for slow requests
oc exec -n openshift-storage $(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name) -- ceph health detail
```

### Check VM Status

```bash
# List all test VMs
oc get vmi -n vm-perf-test

# Detailed VM info
oc describe vmi <vm-name> -n vm-perf-test

# Check the virt-launcher pod
oc get pods -n vm-perf-test -l vm.kubevirt.io/name=<vm-name>
oc logs -n vm-perf-test <virt-launcher-pod> -c compute
```

### Check Events

```bash
# Recent events in the test namespace
oc get events -n vm-perf-test --sort-by='.lastTimestamp' | tail -30
```

### Manual Test Validation

To manually test the rendering pipeline:

```bash
source 00-config.sh
source lib/vm-helpers.sh
ensure_ssh_key

# Render a fio profile
render_fio_profile "05-fio-profiles/random-rw.fio" "4k"

# Render cloud-init
fio_content=$(render_fio_profile "05-fio-profiles/random-rw.fio" "4k")
render_cloud_init "03-cloud-init/fio-runner.yaml" "$fio_content" "test-vm" "/mnt/data"
```

See [Template Rendering](../architecture/template-rendering.md) for more debugging tips.

## Next Steps

- [Running Tests](running-tests.md) — Normal test execution flow
- [Configuration Reference](configuration-reference.md) — Adjust timeouts and parameters
- [Project Architecture](../architecture/project-architecture.md) — Understanding the script pipeline
