# Installing IBM VPC File CSI Driver on Self-Managed OpenShift

This guide covers installing the IBM Cloud VPC File CSI driver (`vpc.file.csi.ibm.io`) on a self-managed OpenShift cluster running on IBM Cloud VPC infrastructure (not ROKS/IKS).

**Source repo:** https://github.com/IBM/ibm-vpc-file-csi-driver

---

## Prerequisites

### Cluster Requirements

- OpenShift cluster running on **IBM Cloud VPC** infrastructure (not Classic)
- For managed ROKS/IKS clusters, use the IBM Cloud addon instead — do NOT use this manual method

### Tools

- `oc` / `kubectl` CLI authenticated to the cluster
- `ibmcloud` CLI with `is` (Infrastructure Services) plugin
- `docker` or `podman` (for building the driver image)
- `go` (for building from source)
- `kustomize` v5.0.1+ (the deploy script installs it if missing)

### IAM API Key

An IBM Cloud IAM API key with VPC infrastructure permissions:

```bash
ibmcloud iam api-key-create vpc-file-csi-key --output json
```

Required permissions: create/delete/manage VPC File Shares (`is.share.*`), read VPC infrastructure (subnets, security groups, instances).

### VPC Security Group

Worker node security groups **must allow TCP port 2049** (NFS) inbound and outbound:

```bash
# Find the security group attached to your worker VSIs
ibmcloud is instance <instance-id> --output json | jq '.network_interfaces[].security_groups[].name'

# Add NFS rules
ibmcloud is security-group-rule-add <sg-id> inbound tcp --port-min 2049 --port-max 2049
ibmcloud is security-group-rule-add <sg-id> outbound tcp --port-min 2049 --port-max 2049
```

---

## Step 1: Gather Required Information

Collect these values before proceeding:

```bash
# IBM Cloud Account ID
ibmcloud account show --output json | jq -r .account_id

# Resource Group ID
ibmcloud resource group <your-rg-name> --output json | jq -r '.[0].id'

# VPC ID
ibmcloud is vpcs --output json | jq -r '.[] | [.name, .id] | @tsv'

# VPC Subnet IDs (one per zone, comma-separated)
ibmcloud is subnets --vpc-id <vpc-id> --output json | jq -r '.[] | [.name, .id, .zone.name] | @tsv'

# VPC Instance IDs for each node
ibmcloud is instances --output json | jq -r '.[] | [.name, .id, .zone.name] | @tsv'

# Region
ibmcloud is vpc <vpc-id> --output json | jq -r '.region'

# Cluster infrastructure ID (for self-managed OCP)
oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}'
```

Record these — you'll need them in Steps 3 and 4.

---

## Step 2: Build the Container Image

Pre-built images are available on IBM Cloud Container Registry. No build step needed.

The latest release image is:

```
icr.io/ibm/ibm-vpc-file-csi-driver:v2.0.28
```

To find the latest version:

```bash
ibmcloud cr region-set global
ibmcloud cr images --include-ibm 2>&1 | grep "icr.io/ibm/ibm-vpc-file-csi-driver" | grep -E 'v2\.0\.[0-9]+\s' | sort -V | tail -5
```

The image requires an authenticated pull from `icr.io`. Your cluster will need an image pull secret (created in Step 6) using your IAM API key.

> **Building from source** (only if you need a custom build):
> ```bash
> git clone https://github.com/IBM/ibm-vpc-file-csi-driver.git
> cd ibm-vpc-file-csi-driver
> make buildimage
> # Produces ibm-vpc-file-csi-driver:latest-amd64
> # Push to your own registry and update the kustomize overlay accordingly
> ```

---

## Step 3: Label Nodes

Every node that will mount file shares needs topology and instance labels. The repo provides a helper script:

```bash
# Usage: ./scripts/apply-required-setup.sh <node-name> <instance-id> <region> <zone>

# Example for a 3-node cluster:
./scripts/apply-required-setup.sh node-0 <instance-id-0> us-south us-south-1
./scripts/apply-required-setup.sh node-1 <instance-id-1> us-south us-south-1
./scripts/apply-required-setup.sh node-2 <instance-id-2> us-south us-south-1
```

This applies the following labels per node:

| Label | Example Value |
|-------|---------------|
| `failure-domain.beta.kubernetes.io/region` | `us-south` |
| `failure-domain.beta.kubernetes.io/zone` | `us-south-1` |
| `topology.kubernetes.io/region` | `us-south` |
| `topology.kubernetes.io/zone` | `us-south-1` |
| `ibm-cloud.kubernetes.io/vpc-instance-id` | `0717_abc123...` |
| `ibm-cloud.kubernetes.io/worker-id` | (can be blank for self-managed) |

**Verify:**

```bash
oc get nodes --show-labels | grep "ibm-cloud.kubernetes.io/vpc-instance-id"
```

### 3.1 Set Node providerID (critical)

The File CSI driver parses the node `spec.providerID` to extract the VPC instance ID. It splits by `/` and expects **exactly 7 segments**. On self-managed OCP (platform: None), nodes have no providerID by default — you must set it **before** deploying the driver, because Kubernetes forbids changing providerID once set.

The required format is:

```
ibm://<account-id>///<cluster-infra-name>/<instance-id>
```

Example: `ibm://3cfdf229dfeb4afb8bf3f1067a9003e3///szocp-vsmz2/0787-624a7cb5-235a-44ac-849d-7789859f6e5c`

Get the values:

```bash
# Account ID
ibmcloud account show --output json | jq -r '.account_id'

# Cluster infrastructure name
oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}'

# Instance IDs (from Step 1)
ibmcloud is bare-metal-servers --output json | jq -r '.[] | [.name, .id] | @tsv'
# or for VSIs:
ibmcloud is instances --output json | jq -r '.[] | [.name, .id] | @tsv'
```

Set the providerID on each node:

```bash
ACCOUNT_ID="<account-id>"
CLUSTER_ID="<infra-name>"

oc patch node <node-name> --type merge \
  -p "{\"spec\":{\"providerID\":\"ibm://${ACCOUNT_ID}///${CLUSTER_ID}/<instance-id>\"}}"
```

**Warning:** If you set the wrong format (e.g. `ibmcloud:///`), the only way to fix it is to delete the node object and recreate it with the correct value:

```bash
# Delete node object (the machine keeps running — kubelet will use the recreated object)
oc delete node <node-name> --wait=false

# Immediately recreate with correct providerID
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Node
metadata:
  name: <node-name>
  labels:
    kubernetes.io/hostname: <node-name>
    node-role.kubernetes.io/worker: ""
    node-role.kubernetes.io/master: ""
    node-role.kubernetes.io/control-plane: ""
    failure-domain.beta.kubernetes.io/region: <region>
    failure-domain.beta.kubernetes.io/zone: <zone>
    topology.kubernetes.io/region: <region>
    topology.kubernetes.io/zone: <zone>
    ibm-cloud.kubernetes.io/vpc-instance-id: "<instance-id>"
spec:
  providerID: "ibm://${ACCOUNT_ID}///${CLUSTER_ID}/<instance-id>"
EOF
```

On a converged cluster (control plane + worker on same nodes), do this **one node at a time** to avoid disrupting etcd quorum.

---

## Step 4: Configure the Kustomize Overlay

Edit the files in `deploy/kubernetes/overlays/dev/`:

### 4.1 `slclient_gen2.toml` — API key and VPC endpoint

```toml
[server]
debug_trace = false

[vpc]
iam_client_id = "bx"
iam_client_secret = "bx"
provider_type = "g2"
g2_token_exchange_endpoint_url = "https://iam.cloud.ibm.com"
g2_riaas_endpoint_url = "https://<region>.iaas.cloud.ibm.com/v1"
g2_resource_group_id = "<resource-group-id>"
g2_api_key = "<iam-api-key>"
```

VPC API endpoints by region:

| Region | Endpoint |
|--------|----------|
| us-south | `https://us-south.iaas.cloud.ibm.com/v1` |
| us-east | `https://us-east.iaas.cloud.ibm.com/v1` |
| eu-de | `https://eu-de.iaas.cloud.ibm.com/v1` |
| eu-gb | `https://eu-gb.iaas.cloud.ibm.com/v1` |
| jp-tok | `https://jp-tok.iaas.cloud.ibm.com/v1` |
| au-syd | `https://au-syd.iaas.cloud.ibm.com/v1` |

### 4.2 `cm-clusterInfo-data.yaml` — Cluster identity

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-info
data:
  cluster-config.json: |
    {
      "cluster_id": "<infrastructure-name-or-cluster-id>",
      "account_id": "<ibm-cloud-account-id>"
    }
```

### 4.3 `cm-providerData-data.yaml` — VPC details

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ibm-cloud-provider-data
data:
  vpc_id: "<vpc-id>"
  vpc_subnet_ids: "<subnet-id-1>,<subnet-id-2>,<subnet-id-3>"
```

### 4.4 `controller-server-images.yaml` — Controller image references

```yaml
kind: Deployment
apiVersion: apps/v1
metadata:
  name: ibm-vpc-file-csi-controller
spec:
  template:
    spec:
      containers:
        - name: csi-provisioner
          image: registry.k8s.io/sig-storage/csi-provisioner:v5.2.0
        - name: csi-resizer
          image: registry.k8s.io/sig-storage/csi-resizer:v1.13.2
        - name: csi-snapshotter
          image: registry.k8s.io/sig-storage/csi-snapshotter:v8.2.0
        - name: liveness-probe
          image: registry.k8s.io/sig-storage/livenessprobe:v2.15.0
        - name: iks-vpc-file-driver
          image: icr.io/ibm/ibm-vpc-file-csi-driver:v2.0.28
```

### 4.5 `node-server-images.yaml` — Node image references

```yaml
kind: DaemonSet
apiVersion: apps/v1
metadata:
  name: ibm-vpc-file-csi-node
spec:
  template:
    spec:
      containers:
        - name: csi-driver-registrar
          image: registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.13.0
        - name: liveness-probe
          image: registry.k8s.io/sig-storage/livenessprobe:v2.15.0
        - name: iks-vpc-file-node-driver
          image: icr.io/ibm/ibm-vpc-file-csi-driver:v2.0.28
```

### 4.6 `sa-controller-secrets.yaml` and `sa-node-secrets.yaml` — Image pull secret

```yaml
# sa-controller-secrets.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ibm-vpc-file-controller-sa
imagePullSecrets:
  - name: icr-io-secret

# sa-node-secrets.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ibm-vpc-file-node-sa
imagePullSecrets:
  - name: icr-io-secret
```

### 4.7 `kustomization.yaml` — Set namespace

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kube-system
resources:
- ../../manifests
patches:
- path: controller-server-images.yaml
- path: node-server-images.yaml
- path: cm-providerData-data.yaml
- path: cm-clusterInfo-data.yaml
- path: sa-controller-secrets.yaml
- path: sa-node-secrets.yaml
```

---

## Step 5: Apply OpenShift SCC

The node DaemonSet runs privileged containers. Apply the SecurityContextConstraints **before** deploying:

```bash
oc apply -f deploy/openshift/scc.yaml
```

> **Important**: The SCC `users` list references namespace `openshift-cluster-csi-drivers`. If deploying to `kube-system`, edit the SCC first:
>
> ```yaml
> users:
>   - system:serviceaccount:kube-system:ibm-vpc-file-controller-sa
>   - system:serviceaccount:kube-system:ibm-vpc-file-node-sa
> ```

---

## Step 6: Create Image Pull Secret

If using a private registry:

```bash
oc create secret docker-registry icr-io-secret \
  --docker-username=iamapikey \
  --docker-email=iamapikey \
  --docker-server=icr.io \
  --docker-password=<iam-api-key> \
  -n kube-system
```

---

## Step 7: Deploy

```bash
bash ./deploy/kubernetes/deploy-vpc-file-csi-driver.sh
```

This runs `kustomize build` on the overlay and applies all resources plus StorageClasses.

> **Note:** If `kustomize build` fails with YAML parsing errors on `setup-vpc-file-sa.yaml` (multi-document separator issues in the upstream repo), apply manifests individually instead:
> ```bash
> for f in deploy/kubernetes/manifests/*.yaml; do
>   [[ "$(basename $f)" == "kustomization.yaml" ]] && continue
>   sed 's/<KUSTOMIZE>/kube-system/g' "$f" | oc apply -f -
> done
> oc apply -f deploy/kubernetes/storageclass/
> ```
> Then patch ConfigMaps, images, and ServiceAccounts manually per Steps 4.2-4.7.

### 7.1 Fix Missing RBAC (required)

The base manifests are missing RBAC rules for leader election leases and the snapshotter role. Without these, the provisioner cannot elect a leader and PVC provisioning hangs.

```bash
# Add leases permission to provisioner and resizer roles
oc patch clusterrole ibm-vpc-file-provisioner-role --type json -p '[
  {"op": "add", "path": "/rules/-", "value": {
    "apiGroups": ["coordination.k8s.io"],
    "resources": ["leases"],
    "verbs": ["get", "create", "update", "delete", "list", "watch"]
  }}
]'

oc patch clusterrole ibm-vpc-file-external-resizer-role --type json -p '[
  {"op": "add", "path": "/rules/-", "value": {
    "apiGroups": ["coordination.k8s.io"],
    "resources": ["leases"],
    "verbs": ["get", "create", "update", "delete", "list", "watch"]
  }}
]'

# Create the missing snapshotter ClusterRole
cat <<'EOF' | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ibm-vpc-file-snapshotter-role
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshotclasses", "volumesnapshots", "volumesnapshotcontents"]
    verbs: ["get", "list", "watch", "create", "delete", "update", "patch"]
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshotcontents/status"]
    verbs: ["update", "patch"]
EOF

# Restart the controller to pick up new RBAC
oc rollout restart deployment ibm-vpc-file-csi-controller -n kube-system
```

---

## Step 8: Verify

```bash
# CSIDriver object
oc get csidriver vpc.file.csi.ibm.io

# Controller pods (2 replicas, Running)
oc get pods -n kube-system -l app=ibm-vpc-file-csi-controller

# Node pods (1 per node, Running)
oc get pods -n kube-system -l app=ibm-vpc-file-csi-node

# StorageClasses
oc get sc | grep ibmc-vpc-file

# Controller logs
oc logs -n kube-system deploy/ibm-vpc-file-csi-controller -c iks-vpc-file-driver --tail=50

# Node logs
oc logs -n kube-system daemonset/ibm-vpc-file-csi-node -c iks-vpc-file-node-driver --tail=50
```

### Functional Test

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-vpc-file-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ibmc-vpc-file-500-iops
  resources:
    requests:
      storage: 20Gi
EOF

# File share provisioning takes 1-3 minutes
oc get pvc test-vpc-file-pvc -w

# Clean up
oc delete pvc test-vpc-file-pvc
```

---

## StorageClasses for Performance Testing

The deploy script creates 14 StorageClasses. For dp2 performance testing on a single-zone cluster, you need these 3:

| StorageClass | IOPS | Min PVC Size |
|---|---|---|
| `ibmc-vpc-file-500-iops` | 500 | 20Gi |
| `ibmc-vpc-file-1000-iops` | 1000 | 40Gi |
| `ibmc-vpc-file-3000-iops` | 3000 | 120Gi |

The dp2 profile enforces a max ~25 IOPS/GB ratio — PVC creation fails if the size is too small for the requested IOPS.

**Skip these on single-zone clusters** (identical performance or unsupported):
- `-metro-` variants — same I/O path on single-zone
- `-retain-` variants — identical performance, different reclaim policy
- `-min-iops` — ~100 IOPS at 150Gi, too slow for benchmarks
- `-eit` — encryption-in-transit, not supported on RHCOS

---

## Troubleshooting

```bash
# Pod events
oc describe pod -n kube-system -l app=ibm-vpc-file-csi-controller | grep -A 20 Events

# Provisioner sidecar logs (handles PVC create/delete)
oc logs -n kube-system deploy/ibm-vpc-file-csi-controller -c csi-provisioner --tail=100

# Verify node labels
oc get nodes -o custom-columns='NAME:.metadata.name,INSTANCE-ID:.metadata.labels.ibm-cloud\.kubernetes\.io/vpc-instance-id,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'

# Verify ConfigMaps
oc get cm -n kube-system ibm-cloud-provider-data -o yaml
oc get cm -n kube-system cluster-info -o yaml

# Verify Secret exists (don't print content)
oc get secret -n kube-system storage-secret-store
```

---

## Uninstall

```bash
bash ./deploy/kubernetes/delete-vpc-file-csi-driver.sh
oc delete scc ibm-vpc-file-scc
```
