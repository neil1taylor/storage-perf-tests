# Prerequisites

[Back to Index](../index.md)

This page provides detailed setup instructions for everything you need before running the test suite. Follow each section in order and use the verification checklist at the end to confirm everything is ready.

## 1. IBM Cloud ROKS Cluster

You need an OpenShift cluster on IBM Cloud with **bare metal workers**.

### Create the Cluster

1. Log in to [IBM Cloud](https://cloud.ibm.com)
2. Navigate to **OpenShift** > **Clusters** > **Create**
3. Key settings:
   - **Infrastructure:** VPC
   - **OpenShift version:** 4.14+ (latest stable recommended)
   - **Worker pool machine type:** `bx3d` (bare metal with NVMe)
   - **Workers per zone:** Minimum 3 (for Ceph quorum)
   - **Zones:** **Single zone recommended.** This test suite is designed for single-zone clusters. With 3 workers and `failureDomain: host`, only ODF pools needing ≤3 failure domains will work (rep2, rep3, ec-2-1). EC pools like ec-2-2 (needs 4 hosts) and ec-4-2 (needs 6 hosts) are excluded by default. Additionally, the `FILE_CSI_DEDUP` setting filters out File CSI `-metro-` and `-retain-` variants that are redundant on single-zone clusters. For multi-zone testing, set `FILE_CSI_DEDUP=false` and add EC pools matching your host count.

### Why Bare Metal?

- **Local NVMe drives:** ODF (Ceph) uses these directly as OSDs. This is what you're benchmarking.
- **Hardware virtualization:** KubeVirt requires CPU VT-x support that bare metal provides.
- **No hypervisor overhead:** Performance measurements reflect real hardware capability.

See [OpenShift Overview](../concepts/openshift-overview.md) for more details.

### Verify Cluster Access

```bash
# Log in to IBM Cloud
ibmcloud login

# Set the cluster context
ibmcloud oc cluster config --cluster <cluster-name> --admin

# Verify access
oc get nodes
```

You should see your bare metal worker nodes listed with status `Ready`.

## 2. OpenShift Data Foundation (ODF)

ODF provides the Ceph storage backend.

### Install ODF Operator

1. In the OpenShift web console, go to **Operators** > **OperatorHub**
2. Search for "OpenShift Data Foundation"
3. Click **Install**
4. Accept default settings (automatic updates, all namespaces)
5. Wait for the operator to be in `Succeeded` state

### Create Storage System

1. Go to **Operators** > **Installed Operators** > **OpenShift Data Foundation**
2. Click **Create StorageSystem**
3. Select **Internal** mode
4. Choose the local NVMe devices on your bare metal workers
5. On the **Configure Performance** screen, select the performance profile:
   - **Lean** — Minimum resources; not recommended for performance testing
   - **Balanced** — Default; suitable for general workloads
   - **Performance** — Recommended for this test suite; allocates more CPU/memory to Ceph daemons

   The resource requirements shown scale with the number of OSDs (NVMe drives) on your workers. See [VSI Storage Testing Guide — resourceProfile](vsi-storage-testing-guide.md#resourceprofile) for detailed sizing tables.
6. Accept remaining defaults and create

### Verify ODF Health

```bash
# Check ODF operator status
oc get csv -n openshift-storage | grep odf

# Check Ceph cluster health
oc get cephcluster -n openshift-storage

# Verify the default StorageClass exists
oc get sc ocs-storagecluster-ceph-rbd
```

The Ceph cluster should show `HEALTH_OK` and the StorageClass should exist.

See [Ceph and ODF](../concepts/ceph-and-odf.md) for background on how ODF works.

## 3. OpenShift Virtualization

OpenShift Virtualization (KubeVirt) enables running VMs on the cluster.

### Install OpenShift Virtualization Operator

1. In the OpenShift web console, go to **Operators** > **OperatorHub**
2. Search for "OpenShift Virtualization"
3. Click **Install**
4. Accept default settings
5. Wait for the operator to be in `Succeeded` state

### Create HyperConverged Resource

1. Go to **Operators** > **Installed Operators** > **OpenShift Virtualization**
2. Click **Create HyperConverged**
3. Accept defaults and create

### Verify

```bash
# Check the HyperConverged resource
oc get hyperconverged -n openshift-cnv

# Check that kubevirt is running
oc get kubevirt -n openshift-cnv

# Verify virt-operator pods are running
oc get pods -n openshift-cnv | grep virt-operator
```

See [OpenShift Virtualization](../concepts/openshift-virtualization.md) for KubeVirt concepts.

## 4. CLI Tools

Install these tools on your local machine.

### oc (OpenShift CLI)

The OpenShift command-line tool. Download from the OpenShift web console (click the **?** icon > **Command line tools**) or:

```bash
# macOS with Homebrew
brew install openshift-cli

# Verify
oc version
```

### virtctl (KubeVirt CLI)

Required for SSH access to VMs.

```bash
# macOS with Homebrew
brew install virtctl

# Or download from the OpenShift web console:
# Operators > Installed Operators > OpenShift Virtualization > virtctl download

# Verify
virtctl version
```

### jq (JSON Processor)

Used to parse fio JSON results.

```bash
# macOS with Homebrew
brew install jq

# Linux
sudo apt-get install jq   # Debian/Ubuntu
sudo yum install jq        # RHEL/CentOS

# Verify
jq --version
```

### Python 3 with openpyxl (Optional)

Required for XLSX report generation. If not installed, the report script generates HTML and Markdown reports only and logs a warning.

```bash
# Check Python version
python3 --version

# Install openpyxl (optional)
pip3 install openpyxl

# Verify
python3 -c "import openpyxl; print(openpyxl.__version__)"
```

## 5. Environment Verification Checklist

Run these commands to verify everything is ready:

```bash
# 1. Cluster access
oc whoami                    # Should show your username
oc get nodes                 # Should list bare metal workers

# 2. ODF
oc get sc ocs-storagecluster-ceph-rbd    # Should exist
oc get cephcluster -n openshift-storage  # Should show HEALTH_OK

# 3. OpenShift Virtualization
oc get kubevirt -n openshift-cnv         # Should show phase: Deployed
virtctl version                          # Should show client version

# 4. CLI tools
oc version                               # Should show client + server
jq --version                             # Should show version
python3 -c "import openpyxl"             # Optional — XLSX reports skipped if missing

# 5. Namespace (create if it doesn't exist)
oc get ns vm-perf-test || oc create ns vm-perf-test
```

### Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `oc get nodes` shows no bare metal | Wrong cluster context | `ibmcloud oc cluster config --cluster <name>` |
| ODF StorageClass missing | ODF not fully deployed | Wait for ODF operator to finish, check events |
| `virtctl: command not found` | Not installed | Install via brew or download from console |
| `cephcluster` shows `HEALTH_WARN` | OSDs may be recovering | Wait for Ceph to settle; check `ceph status` |

## 6. Optional: Adjust Configuration

Before running tests, review `00-config.sh` to ensure settings match your cluster:

```bash
# Open config file
vi 00-config.sh

# Key settings to verify:
# - TEST_NAMESPACE (default: vm-perf-test)
# - VM_SIZES, PVC_SIZES, CONCURRENCY_LEVELS
# - FIO_RUNTIME (increase for more stable results)
# - ODF_POOLS (adjust if your cluster has fewer OSDs)
```

See [Configuration Reference](configuration-reference.md) for a complete guide to all parameters.

## Next Steps

- [Configuration Reference](configuration-reference.md) — Understand every configurable parameter
- [Running Tests](running-tests.md) — Step-by-step guide to running the test suite
