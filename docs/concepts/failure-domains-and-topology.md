# Failure Domains and Topology

[Back to Index](../index.md)

This page explains failure domains — the core concept that determines how Ceph distributes data to survive hardware failures. It covers the CRUSH algorithm, how ROKS assigns nodes to racks, why cluster sizing in multiples of 3 matters, and how failure domain choices affect which storage pools are possible. This is the most ROKS-specific content in the documentation — most of this information is not available in upstream Ceph or ODF docs.

## What Are Failure Domains?

A **failure domain** is a group of components that can fail together. When a power supply dies, it takes down one server. When a rack loses its top-of-rack switch, every server in that rack goes offline. When an availability zone floods, every rack in that zone is lost.

Distributed storage systems like Ceph use failure domains to decide where to place copies of data. The rule is simple: **no two copies of the same data should share a failure domain**. If one domain fails, at least one copy survives elsewhere.

### Failure Domain Levels

From smallest to largest:

| Level | What Fails Together | Real-World Scenario | Blast Radius |
|-------|--------------------|--------------------|-------------|
| **OSD** (disk) | One NVMe drive | Drive firmware bug, media failure, bad sector accumulation | One disk's data is unavailable until Ceph recovers it from replicas |
| **Host** (node) | All disks on one server | Kernel panic, memory failure, motherboard death, power supply failure | 8 OSDs lost simultaneously on a typical BM worker (all NVMe drives on that node) |
| **Rack** | All servers in one rack | Top-of-rack switch failure, rack PDU failure, cabling fault | All nodes and their OSDs in that rack — could be 1-3 nodes on a ROKS cluster |
| **Zone** (AZ) | All racks in one datacenter zone | Power grid failure, cooling failure, network partition between zones | Every node in the zone — potentially a third or more of the cluster |

The choice of failure domain level determines two things:

1. **What you can survive** — A rep3 pool with `failureDomain: host` survives any 2 hosts dying. The same pool with `failureDomain: rack` survives any 2 racks dying (a much stronger guarantee, since a rack may contain multiple hosts).

2. **How many failure domains you need** — Each copy (or EC chunk) must land in a separate domain. A rep3 pool needs at least 3 domains. An ec-4-2 pool needs 6 domains. If you don't have enough domains at the chosen level, the pool cannot be created.

### Why Not Always Use the Largest Domain?

Larger failure domains provide stronger protection but require more infrastructure. With `failureDomain: rack` on a ROKS cluster with 3 racks, you have exactly 3 failure domains — enough for rep3 and ec-2-1, but not enough for ec-2-2 (needs 4) or ec-4-2 (needs 6). Switching to `failureDomain: zone` on a single-AZ cluster gives you only 1 failure domain, which is useless.

The right choice depends on your cluster topology and what pool configurations you need.

## The CRUSH Hierarchy

### What Is CRUSH?

**CRUSH (Controlled Replication Under Scalable Hashing)** is Ceph's algorithm for determining where to place data. Unlike traditional storage systems that use a central metadata server to track "file X is on disk Y," CRUSH is **algorithmic** — any node in the cluster can independently calculate where any piece of data lives using the same rules.

CRUSH works with a **hierarchy** (called a "CRUSH map") that describes the physical topology of the storage cluster. This hierarchy has a tree structure:

```
                         root (default)
                        /      |      \
                    rack0    rack1    rack2
                      |        |        |
                   host-1   host-2   host-3
                  /| ... |\  /| ... |\  /| ... |\
               osd osd  osd osd osd osd osd osd osd ...
               .0  .1   .7  .8  .9  .15 .16 .17 .23
```

This diagram shows a 3-node ROKS bare metal cluster. Each worker has 8 NVMe drives, giving 24 OSDs total. The hierarchy encodes the physical topology: which disks are in which servers, and which servers are in which racks.

### How CRUSH Uses the Hierarchy

When Ceph needs to place a replica, CRUSH walks down the tree following a **CRUSH rule**. For a rep3 pool with `failureDomain: host`, the rule says:

1. Start at `root`
2. Choose 3 different items at the `host` level (descend to 3 different hosts)
3. Within each chosen host, choose 1 OSD

This guarantees each replica lands on a different host. If host-2 dies, the copies on host-1 and host-3 are still available.

For `failureDomain: rack`, the rule changes step 2 to "choose 3 different items at the `rack` level." On a 3-rack cluster, this forces one replica per rack.

### CRUSH Rules and Device Classes

Each pool has a CRUSH rule that encodes its placement constraints. CRUSH rules also support **device class filtering** — when a pool specifies `deviceClass: ssd`, the CRUSH rule only considers OSDs backed by SSDs (on ROKS bare metal, all NVMe drives are classified as `ssd`).

You can inspect the CRUSH rules on your cluster:

```bash
TOOLS_POD=$(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name)

# List all CRUSH rules
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd crush rule ls

# Show details of a specific rule (the OOB pool's rule)
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd crush rule dump replicated_rule
```

The OOB pool typically uses a rule that selects from `host` buckets under `root`, filtered to the `ssd` device class. Custom pools created by this project use the same pattern.

### A Concrete CRUSH Hierarchy: 3-Node BM Cluster

Here is what `ceph osd tree` looks like on a typical 3-node ROKS bare metal cluster with 8 NVMe drives per node:

```
ID   CLASS  WEIGHT    TYPE NAME          STATUS  REWEIGHT  PRI-AFF
 -1         69.96758  root default
 -5         23.32253      rack rack0
 -3         23.32253          host worker-1
  0    ssd   2.91532              osd.0      up   1.00000  1.00000
  1    ssd   2.91532              osd.1      up   1.00000  1.00000
  2    ssd   2.91532              osd.2      up   1.00000  1.00000
  3    ssd   2.91532              osd.3      up   1.00000  1.00000
  4    ssd   2.91532              osd.4      up   1.00000  1.00000
  5    ssd   2.91532              osd.5      up   1.00000  1.00000
  6    ssd   2.91532              osd.6      up   1.00000  1.00000
  7    ssd   2.91532              osd.7      up   1.00000  1.00000
 -7         23.32253      rack rack1
 -9         23.32253          host worker-2
  8    ssd   2.91532              osd.8      up   1.00000  1.00000
  9    ssd   2.91532              osd.9      up   1.00000  1.00000
 10    ssd   2.91532              osd.10     up   1.00000  1.00000
 11    ssd   2.91532              osd.11     up   1.00000  1.00000
 12    ssd   2.91532              osd.12     up   1.00000  1.00000
 13    ssd   2.91532              osd.13     up   1.00000  1.00000
 14    ssd   2.91532              osd.14     up   1.00000  1.00000
 15    ssd   2.91532              osd.15     up   1.00000  1.00000
-11         23.32253      rack rack2
-13         23.32253          host worker-3
 16    ssd   2.91532              osd.16     up   1.00000  1.00000
 17    ssd   2.91532              osd.17     up   1.00000  1.00000
 18    ssd   2.91532              osd.18     up   1.00000  1.00000
 19    ssd   2.91532              osd.19     up   1.00000  1.00000
 20    ssd   2.91532              osd.20     up   1.00000  1.00000
 21    ssd   2.91532              osd.21     up   1.00000  1.00000
 22    ssd   2.91532              osd.22     up   1.00000  1.00000
 23    ssd   2.91532              osd.23     up   1.00000  1.00000
```

Key observations:
- **WEIGHT** — Proportional to disk capacity. Each 2.9 TB NVMe drive has weight ~2.91. Host weights are the sum of their OSDs. The root weight is the total.
- **CLASS** — All drives show `ssd` because ROKS bare metal uses NVMe.
- **Hierarchy** — `root default → rack rack0 → host worker-1 → osd.0-7`. The rack layer exists because ROKS assigns a rack label to each worker node.
- **1:1:1 balance** — With one host per rack, each rack has equal weight. This is the ideal topology for a 3-node cluster.

## Failure Domain Options in Detail

### `osd` — Per-Disk Failure Domain

With `failureDomain: osd`, each replica or EC chunk is placed on a different OSD (disk), regardless of which host the disk is on.

**Protection:** Survives individual disk failures only. Multiple replicas can share the same host, so a host failure can lose multiple copies simultaneously.

**Use case:** Testing or development environments where you need pool configurations that require more failure domains than you have hosts. For example, ec-4-2 on a 3-node cluster (6 chunks need 6 domains — 3 hosts aren't enough, but 24 OSDs are).

```yaml
# Not recommended for production
spec:
  failureDomain: osd
  erasureCoded:
    dataChunks: 4
    codingChunks: 2
```

**Why this project doesn't use it:** The benchmarks aim to measure realistic production configurations. With `failureDomain: osd`, Ceph may place multiple replicas on the same host, meaning I/O for those replicas competes for the same NVMe drives and PCIe bus. This distorts performance measurements compared to a production deployment where replicas are guaranteed to be on separate hosts.

### `host` — Per-Node Failure Domain

With `failureDomain: host`, each replica or EC chunk is placed on a different host (node). This is the **default for ODF** and what this project uses for all pools.

**Protection:** Survives one or more node failures (depending on replication factor or EC m value). On a 3-node cluster, rep3 with `failureDomain: host` can survive any 2 nodes dying — each node holds exactly one copy.

**Constraint:** You need at least as many hosts as chunks. Rep3 needs 3 hosts, ec-2-1 needs 3 hosts, ec-4-2 needs 6 hosts.

**Why it's the right default for ROKS:** ROKS bare metal clusters typically have 3 worker nodes in a single AZ. With `failureDomain: host`:
- Each of the 3 hosts is in a separate rack (ROKS round-robin assignment)
- `host` and `rack` are equivalent on a 3-node cluster (one host per rack)
- You get the maximum pool variety (rep2, rep3, ec-2-1) without needing more nodes
- The OOB pools use `host`, so custom pools should match

### `rack` — Per-Rack Failure Domain

With `failureDomain: rack`, each replica or EC chunk is placed in a different rack. On a ROKS cluster, racks are logical groups named `rack0`, `rack1`, `rack2`.

**Protection:** Survives one or more rack failures. Stronger than `host` when racks contain multiple nodes — a rack failure takes down multiple hosts, and `failureDomain: rack` guarantees no data loss.

**Constraint:** ROKS single-AZ clusters have exactly 3 racks. This means:
- Rep3 is the maximum replication (needs 3 racks) — possible
- ec-2-1 needs 3 racks — possible
- ec-2-2 needs 4 racks — **not possible**
- ec-4-2 needs 6 racks — **not possible**

**When to consider `rack`:** On a 6+ node cluster (2+ nodes per rack), you might want `rack`-level failure domain for production workloads that must survive a full rack outage. The tradeoff is that you're limited to 3 failure domains, which restricts your pool options.

**Why this project doesn't use it:** On a 3-node cluster, `rack` and `host` are functionally identical (one host per rack). Using `rack` would limit pool options on larger clusters without providing additional benefit in the benchmarking context.

### `zone` — Per-Zone Failure Domain

With `failureDomain: zone`, each replica or EC chunk is placed in a different availability zone. This is for multi-AZ clusters spanning multiple datacenters.

**Protection:** Survives an entire AZ outage (datacenter failure). The strongest possible protection.

**Constraints:**
- Multi-AZ ROKS clusters typically have 3 zones
- Cross-zone writes have higher latency (network round-trip between datacenters)
- Only 3 failure domains, limiting pool options to those needing ≤3 domains

**Impact on performance:** Every write must replicate across AZ boundaries. Depending on the distance between zones, this adds 0.5–2ms per write operation. Read performance is unaffected when reading from the local zone.

**When it's used:** The OOB pool on a multi-AZ ROKS cluster may use `failureDomain: zone` to ensure data survives zone-level failures. Single-AZ clusters (which this project targets) have only one zone, making `zone` unusable.

### Comparison Table

| Failure Domain | Protection Level | Max Pools on 3-Rack ROKS | Write Latency Impact | Best Use Case |
|---------------|-----------------|--------------------------|---------------------|---------------|
| `osd` | Disk-level only | All pools possible (24 OSDs) | None | Testing only |
| `host` | Node-level | rep2, rep3, ec-2-1 (3 hosts) | None (same-rack) | **Default for single-AZ ROKS** |
| `rack` | Rack-level | rep2, rep3, ec-2-1 (3 racks) | None (same-AZ) | 6+ node production clusters |
| `zone` | AZ-level | rep2, rep3, ec-2-1 (3 zones) | +0.5–2ms cross-zone | Multi-AZ clusters |

## ROKS Topology: How Racks Work

This section covers ROKS-specific behaviour that isn't documented in upstream Ceph, ODF, or IBM Cloud docs. Understanding rack assignment is essential for planning cluster scaling and predicting storage pool behaviour.

### Round-Robin Rack Assignment

When worker nodes are added to a ROKS cluster, ROKS assigns them to racks in a **round-robin** pattern across 3 racks (`rack0`, `rack1`, `rack2`):

```
Node 1  →  rack0
Node 2  →  rack1
Node 3  →  rack2
Node 4  →  rack0     ← wraps around
Node 5  →  rack1
Node 6  →  rack2
Node 7  →  rack0
Node 8  →  rack1
Node 9  →  rack2
```

This is a fixed assignment — nodes don't move between racks. The rack assignment is encoded in the node's topology labels and propagated to ODF, which uses it to build the CRUSH hierarchy.

You can check rack assignments on your cluster:

```bash
# Show each worker's rack assignment
oc get nodes -l node-role.kubernetes.io/worker= \
  -o custom-columns='NAME:.metadata.name,RACK:.metadata.labels.topology\.kubernetes\.io/rack'
```

### 3-Node Cluster: Perfectly Balanced

With exactly 3 worker nodes, each rack gets one node:

```
rack0: [worker-1]  ← 8 OSDs
rack1: [worker-2]  ← 8 OSDs
rack2: [worker-3]  ← 8 OSDs
```

This is the ideal topology:
- Each rack has equal weight (same number of OSDs)
- `failureDomain: host` and `failureDomain: rack` are equivalent
- PG distribution is perfectly balanced across racks
- Every OSD carries an equal share of primary PGs

**CRUSH tree:**

```
root default (24 OSDs, 69.97 TiB)
├── rack0 (8 OSDs, 23.32 TiB)
│   └── worker-1: osd.0 – osd.7
├── rack1 (8 OSDs, 23.32 TiB)
│   └── worker-2: osd.8 – osd.15
└── rack2 (8 OSDs, 23.32 TiB)
    └── worker-3: osd.16 – osd.23
```

### 6-Node Cluster: Still Balanced

With 6 nodes (2 per rack), the topology remains balanced:

```
rack0: [worker-1, worker-4]  ← 16 OSDs
rack1: [worker-2, worker-5]  ← 16 OSDs
rack2: [worker-3, worker-6]  ← 16 OSDs
```

**CRUSH tree:**

```
root default (48 OSDs, 139.94 TiB)
├── rack0 (16 OSDs, 46.64 TiB)
│   ├── worker-1: osd.0 – osd.7
│   └── worker-4: osd.24 – osd.31
├── rack1 (16 OSDs, 46.64 TiB)
│   ├── worker-2: osd.8 – osd.15
│   └── worker-5: osd.32 – osd.39
└── rack2 (16 OSDs, 46.64 TiB)
    ├── worker-3: osd.16 – osd.23
    └── worker-6: osd.40 – osd.47
```

With 6 hosts and 3 racks, all pool types are possible:
- `failureDomain: host` gives 6 failure domains → rep2, rep3, ec-2-1, ec-2-2, ec-4-2 all work
- `failureDomain: rack` gives 3 failure domains → rep2, rep3, ec-2-1 work

### 4-Node Cluster: The Imbalance Problem

Adding a 4th node breaks the balance. Round-robin puts it in `rack0`:

```
rack0: [worker-1, worker-4]  ← 16 OSDs  (2 nodes)
rack1: [worker-2]            ←  8 OSDs  (1 node)
rack2: [worker-3]            ←  8 OSDs  (1 node)
```

**CRUSH tree:**

```
root default (32 OSDs, 93.29 TiB)
├── rack0 (16 OSDs, 46.64 TiB)  ← 50% of cluster weight
│   ├── worker-1: osd.0 – osd.7
│   └── worker-4: osd.24 – osd.31
├── rack1 (8 OSDs, 23.32 TiB)   ← 25% of cluster weight
│   └── worker-2: osd.8 – osd.15
└── rack2 (8 OSDs, 23.32 TiB)   ← 25% of cluster weight
    └── worker-3: osd.16 – osd.23
```

This imbalance affects CRUSH placement:

**With `failureDomain: host` (what this project uses):**
- PGs are distributed across 4 hosts. CRUSH still ensures each replica lands on a different host.
- rack0 has 2 hosts, so it handles more PG primaries than the other racks. However, within rack0 the load is split across 2 hosts with 8 OSDs each, so no single host is overloaded.
- Performance impact is minimal — the extra capacity in rack0 simply absorbs more PGs proportionally.

**With `failureDomain: rack`:**
- PGs are distributed across 3 racks. CRUSH tries to distribute evenly, but rack0 has double the weight.
- For a rep3 pool, each PG needs one replica per rack. rack0 handles the same number of primary PGs as rack1 or rack2, but has twice the OSD capacity to serve them — the extra OSDs in rack0 sit partially idle.
- This is a capacity imbalance, not a performance disaster, but it means you're paying for OSDs that aren't fully utilized.

### Why Add Nodes in Multiples of 3

Because of the round-robin 3-rack assignment, adding nodes in multiples of 3 keeps the topology balanced:

| Nodes | rack0 | rack1 | rack2 | Balanced? | Available Pools (failureDomain: host) |
|-------|-------|-------|-------|-----------|---------------------------------------|
| 3 | 1 | 1 | 1 | Yes | rep2, rep3, ec-2-1 |
| 4 | 2 | 1 | 1 | **No** | rep2, rep3, ec-2-1, ec-2-2 |
| 5 | 2 | 2 | 1 | **No** | rep2, rep3, ec-2-1, ec-2-2 |
| 6 | 2 | 2 | 2 | Yes | rep2, rep3, ec-2-1, ec-2-2, ec-4-2 |
| 7 | 3 | 2 | 2 | **No** | rep2, rep3, ec-2-1, ec-2-2, ec-4-2 |
| 8 | 3 | 3 | 2 | **No** | rep2, rep3, ec-2-1, ec-2-2, ec-4-2 |
| 9 | 3 | 3 | 3 | Yes | rep2, rep3, ec-2-1, ec-2-2, ec-4-2 |

Key takeaways:
- **3 nodes** is the minimum for ODF (rep3 needs 3 hosts) and gives a balanced topology
- **4-5 nodes** unlock ec-2-2 (needs 4 hosts) but create rack imbalance
- **6 nodes** is the sweet spot for maximum pool variety with balanced racks
- **9 nodes** is the next balanced step up, providing additional capacity and resilience

### Impact of Rack Imbalance on PG Distribution

With `failureDomain: host`, rack imbalance affects where CRUSH places PGs but doesn't cause a bottleneck. CRUSH distributes PGs based on OSD weight, so hosts with more weight get proportionally more PGs. Since all OSDs have the same individual weight, each OSD ends up with roughly the same number of PG primaries regardless of rack distribution.

The real issue is **capacity utilization**: if rack0 has twice the capacity but the pool's replication policy distributes data equally across hosts (not racks), rack0's extra capacity goes partially unused. This matters more for storage planning than for benchmark performance.

With `failureDomain: rack`, the impact is more visible. CRUSH must place one replica in each rack, but rack0 has twice the OSD capacity as the others. The extra OSDs in rack0 carry fewer PGs per OSD than the OSDs in rack1/rack2, leading to uneven utilization. In extreme cases (e.g., rack0 with 4 nodes, rack1/rack2 with 1 each), the single-node racks become hotspots.

## Single AZ vs Multi-AZ

### Single-AZ ROKS Clusters

This project targets single-AZ ROKS clusters, where all worker nodes are in the same availability zone. In the CRUSH hierarchy, there is only one zone — meaning `failureDomain: zone` would provide only 1 failure domain (useless for any replicated or EC pool).

On single-AZ clusters:
- The meaningful failure domain levels are `osd`, `host`, and `rack`
- ROKS assigns 3 racks within the AZ, giving up to 3 rack-level failure domains
- Network latency between nodes is minimal (all within the same datacenter)
- Write latency is dominated by Ceph replication to remote OSDs, not network distance

### Multi-AZ ROKS Clusters

Multi-AZ clusters span 2-3 availability zones. Each zone is a separate datacenter (or datacenter room) with independent power and cooling. Nodes in different zones are connected via high-bandwidth, low-latency links, but inter-zone latency is measurably higher than intra-zone.

In a multi-AZ CRUSH hierarchy:

```
root default
├── zone-dal10-a
│   ├── rack0
│   │   └── host worker-1
│   └── rack1
│       └── host worker-2
├── zone-dal10-b
│   ├── rack2
│   │   └── host worker-3
│   └── rack3
│       └── host worker-4
└── zone-dal10-c
    ├── rack4
    │   └── host worker-5
    └── rack5
        └── host worker-6
```

With `failureDomain: zone`:
- Each replica lands in a separate AZ — maximum protection
- Only 3 failure domains (with 3 AZs), limiting pools to those needing ≤3 domains
- Every write must cross at least one AZ boundary, adding 0.5–2ms latency

With `failureDomain: host` on a multi-AZ cluster:
- Replicas may end up in the same AZ (CRUSH doesn't consider zones)
- More failure domains available (6 hosts = 6 domains)
- No cross-zone write latency penalty (replicas may all be intra-zone)

### Impact on the OOB Pool

The OOB `ocs-storagecluster-cephblockpool` pool's failure domain depends on the cluster type:
- **Single-AZ:** Typically uses `failureDomain: host`
- **Multi-AZ:** May use `failureDomain: zone` for zone-level fault tolerance

Check your OOB pool's failure domain:

```bash
oc get cephblockpool ocs-storagecluster-cephblockpool -n openshift-storage \
  -o jsonpath='{.spec.failureDomain}'
```

Custom pools should generally match the OOB pool's failure domain to ensure consistent behaviour.

## How Failure Domains Affect Pool Configuration

### Decision Tree

Use this decision tree to choose the right `failureDomain` for your pools:

```
Is this a multi-AZ cluster?
├── Yes → Do you need zone-level fault tolerance?
│         ├── Yes → failureDomain: zone  (limited to ≤3 failure domains)
│         └── No  → failureDomain: host  (more pool options, same-zone latency)
└── No  → Single-AZ cluster
          ├── How many worker nodes?
          │   ├── 3 nodes → failureDomain: host  (host = rack on 3-node clusters)
          │   ├── 4-5 nodes → failureDomain: host  (more failure domains than racks)
          │   └── 6+ nodes → failureDomain: host  (most pool options)
          │                  or failureDomain: rack  (rack-level fault tolerance)
          └── Need pools requiring >3 failure domains (e.g., ec-4-2)?
              ├── Yes → failureDomain: host  (need 6+ hosts for ec-4-2)
              └── No  → Either host or rack works
```

### Why `host` Is the Right Default for ROKS Single-AZ

For this project's benchmarking context, `failureDomain: host` is the correct choice:

1. **Matches the OOB pool** — The default ROKS pool uses `failureDomain: host`. Custom pools should match for apples-to-apples comparison.

2. **Maximum pool variety** — With 6 hosts and `failureDomain: host`, all pool types work (rep2, rep3, ec-2-1, ec-2-2, ec-4-2). Switching to `rack` would limit to pools needing ≤3 domains.

3. **Equivalent to rack on 3 nodes** — On the most common ROKS configuration (3 BM workers), each rack has exactly one host. `failureDomain: host` and `failureDomain: rack` produce identical CRUSH placement.

4. **Production-realistic** — Most single-AZ ODF deployments use `failureDomain: host`. Benchmarking with this setting produces results that directly predict production workload performance.

### When `rack` Might Be Appropriate

Consider `failureDomain: rack` when:
- You have 6+ nodes (at least 2 per rack) and need rack-level fault tolerance guarantees
- You're willing to accept that only pools needing ≤3 failure domains are available
- Your workloads can tolerate being limited to rep2, rep3, and ec-2-1

Even in these cases, `failureDomain: host` may be preferred if you need ec-2-2 or ec-4-2 pools for capacity efficiency.

## Interaction with Replication and EC

### Minimum Failure Domains Per Pool Type

Each pool type requires a minimum number of failure domains. The requirement is:
- **Replicated:** N domains (where N = replication size)
- **Erasure-coded:** k+m domains (one per chunk)

This table shows the minimum domains required at each failure domain level, and whether the pool is possible on common ROKS topologies:

| Pool | Domains Needed | 3-Host Cluster | 4-Host Cluster | 6-Host Cluster | 3-Rack Single-AZ | 3-Zone Multi-AZ |
|------|---------------|---------------|---------------|---------------|-------------------|-----------------|
| **rep2** | 2 | Yes | Yes | Yes | Yes | Yes |
| **rep3** | 3 | Yes | Yes | Yes | Yes | Yes |
| **ec-2-1** | 3 | Yes | Yes | Yes | Yes | Yes |
| **ec-3-1** | 4 | No | Yes | Yes | No | No |
| **ec-2-2** | 4 | No | Yes | Yes | No | No |
| **ec-4-2** | 6 | No | No | Yes | No | No |

Reading this table:
- A **3-host cluster** with `failureDomain: host` has 3 failure domains → rep2, rep3, and ec-2-1 are possible
- A **6-host cluster** with `failureDomain: host` has 6 failure domains → all pools are possible
- A **3-rack single-AZ** with `failureDomain: rack` always has exactly 3 failure domains → same as 3-host
- A **3-zone multi-AZ** with `failureDomain: zone` has 3 failure domains → same as 3-host

### How CRUSH Places Replicas

For a rep3 pool with `failureDomain: host` on a 3-node cluster, CRUSH places one replica on each host. The placement is deterministic — for each PG, CRUSH calculates which 3 hosts (out of 3 available) receive the data. With exactly 3 hosts and 3 replicas, every host gets every PG:

```
PG 0.0  →  [osd.2 (host-1), osd.10 (host-2), osd.19 (host-3)]
PG 0.1  →  [osd.5 (host-1), osd.14 (host-2), osd.16 (host-3)]
PG 0.2  →  [osd.7 (host-1), osd.8 (host-2),  osd.22 (host-3)]
...
```

Each PG picks different OSDs within each host, spreading I/O across all 8 NVMe drives per node.

### How CRUSH Places EC Chunks

For an ec-2-1 pool (3 chunks total) with `failureDomain: host` on a 3-node cluster:

```
PG 0.0  →  [osd.3 (host-1, data0), osd.11 (host-2, data1), osd.20 (host-3, coding0)]
PG 0.1  →  [osd.1 (host-1, data0), osd.9 (host-2, data1),  osd.17 (host-3, coding0)]
...
```

Each chunk (data or coding) lands on a different host. The primary OSD (first in the list) handles the encoding/decoding computation.

### The Rep3 Advantage on 3-Node Clusters

On exactly 3 nodes with `failureDomain: host`, rep3 has a unique property: every host holds **every** PG. This means:
- All 3 hosts are equally loaded (perfect balance)
- Reads can be served by any of the 3 hosts (load-balanced reads)
- The OOB pool with 256 PGs distributes evenly: each OSD is primary for ~32 PGs

Rep2 on 3 nodes doesn't have this property — each PG only needs 2 hosts, so CRUSH creates combinations: (host-1, host-2), (host-1, host-3), (host-2, host-3). The pairing distribution depends on the PG count and hash distribution, which can lead to slight imbalances in primary OSD assignments.

This is one reason rep3 reads can outperform rep2 reads on 3-node clusters, beyond the OOB pool's pre-tuned PG count advantage. See [Ceph and ODF — Pools in This Project](ceph-and-odf.md#pools-in-this-project) for more context.

For a detailed explanation of EC vs replication tradeoffs, see [Erasure Coding Explained](erasure-coding-explained.md).

## Practical Diagnostics

This section provides commands for inspecting failure domains and diagnosing placement issues. All commands use the Ceph toolbox pod in the `openshift-storage` namespace.

### Set Up the Tools Pod Variable

Most commands need the toolbox pod reference:

```bash
TOOLS_POD=$(oc get pods -n openshift-storage -l app=rook-ceph-tools -o name)
```

### View the CRUSH Topology

The most important diagnostic command — shows the full hierarchy of racks, hosts, and OSDs:

```bash
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd tree
```

**What to look for:**
- Each host should be under a `rack` bucket (not directly under `root`)
- All OSDs should show `up` status
- OSD weights should be consistent within each host (same disk sizes)
- Rack weights should be roughly equal (balanced topology)

### Check a Pool's CRUSH Rule

Each pool has a CRUSH rule that defines its placement constraints:

```bash
# Find the CRUSH rule for a pool
oc exec -n openshift-storage ${TOOLS_POD} -- \
  ceph osd pool get ocs-storagecluster-cephblockpool crush_rule

# Dump the full rule details
oc exec -n openshift-storage ${TOOLS_POD} -- \
  ceph osd crush rule dump replicated_rule
```

The rule output shows the `type` field which corresponds to the failure domain level (1=host, 2=rack, etc.) and the `class` field for device class filtering.

### Verify Data Placement

Check which OSDs hold PGs for a specific pool:

```bash
# List PGs and their OSD mappings for a pool
oc exec -n openshift-storage ${TOOLS_POD} -- \
  ceph pg ls-by-pool ocs-storagecluster-cephblockpool

# Count PG primaries per OSD (shows I/O distribution)
oc exec -n openshift-storage ${TOOLS_POD} -- \
  ceph pg ls-by-pool ocs-storagecluster-cephblockpool -f json | \
  jq '[.pg_stats[].acting_primary] | group_by(.) | map({osd: .[0], count: length}) | sort_by(.osd)'
```

**What to look for:**
- PG primaries should be roughly evenly distributed across OSDs
- No single OSD should have a disproportionate number of primaries
- With `failureDomain: host`, the acting set for each PG should span different hosts

### Count OSD Hosts

This is what `01-setup-storage-pools.sh` does before creating pools — count the unique hosts running OSD pods:

```bash
# Count unique OSD hosts
oc get pods -n openshift-storage -l app=rook-ceph-osd \
  -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l

# List OSD hosts with their rack assignments
oc get pods -n openshift-storage -l app=rook-ceph-osd \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | \
  while read node; do
    rack=$(oc get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/rack}' 2>/dev/null)
    echo "$node → $rack"
  done
```

The setup script uses this count to determine which pools can be created. A pool requiring more failure domains than available hosts is skipped with a warning.

### Check Rack Assignments

View the rack label for all worker nodes:

```bash
oc get nodes -l node-role.kubernetes.io/worker= \
  -o custom-columns='NAME:.metadata.name,RACK:.metadata.labels.topology\.kubernetes\.io/rack'
```

**Expected output on a 3-node cluster:**

```
NAME        RACK
worker-1    rack0
worker-2    rack1
worker-3    rack2
```

### Common Diagnostic Scenarios

#### EC Pool Won't Become Ready

**Symptom:** CephBlockPool for an EC pool stays in `Progressing` or `Failed` phase.

**Likely cause:** Not enough failure domains. For example, ec-2-2 needs 4 hosts but you have 3.

**Diagnosis:**

```bash
# Check the pool status
oc get cephblockpool perf-test-ec-2-2 -n openshift-storage -o yaml

# Look for CRUSH placement errors in the OSD logs
oc exec -n openshift-storage ${TOOLS_POD} -- ceph health detail

# Verify host count vs pool requirements
echo "Hosts: $(oc get pods -n openshift-storage -l app=rook-ceph-osd \
  -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | wc -l)"
echo "ec-2-2 needs: 4 hosts"
```

**Fix:** Either add more worker nodes or remove the pool definition from `ODF_POOLS`. The test suite handles this automatically — pools requiring more hosts than available are skipped.

#### Uneven PG Distribution

**Symptom:** Some OSDs show significantly more PG primaries than others.

**Likely cause:** Rack imbalance (e.g., 4 nodes with 2-1-1 rack distribution) or stale CRUSH rules.

**Diagnosis:**

```bash
# PG primaries per OSD
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd df tree

# Check for stale CRUSH rules
oc exec -n openshift-storage ${TOOLS_POD} -- ceph osd crush tree
```

**Fix:** If CRUSH rules are stale, ensure `enableCrushUpdates: true` on the pool. If the imbalance is from rack topology, it's expected — see [Impact of Rack Imbalance on PG Distribution](#impact-of-rack-imbalance-on-pg-distribution).

#### Performance Differences Between Pools Using Same failureDomain

**Symptom:** Two pools with the same `failureDomain: host` show different performance, even though they use the same disks.

**Likely causes:**
1. **PG count difference** — Check `ceph osd pool autoscale-status`. A pool with 1 PG vs 256 PGs will show ~6x worse performance. See [CephBlockPool Setup — Understanding PG Autoscaling](../guides/ceph-pool-setup.md#understanding-pg-autoscaling).
2. **StorageClass imageFeatures** — Missing `exclusive-lock` can cause up to 7x worse write IOPS. Check the StorageClass parameters.
3. **Different CRUSH rules** — Custom pools may use a different CRUSH rule than the OOB pool. Verify with `ceph osd pool get <pool> crush_rule`.

## How This Project Uses Failure Domains

### All Pools Use `failureDomain: host`

Every pool created by `01-setup-storage-pools.sh` uses `failureDomain: host`, hardcoded in the CephBlockPool YAML:

**Replicated pools** (`01-setup-storage-pools.sh:95`):

```yaml
spec:
  failureDomain: host
  deviceClass: ssd
  replicated:
    size: ${rep_size}
```

**EC pools** (`01-setup-storage-pools.sh:116`):

```yaml
spec:
  failureDomain: host
  deviceClass: ssd
  erasureCoded:
    dataChunks: ${data_chunks}
    codingChunks: ${coding_chunks}
```

This matches the OOB pool's failure domain, ensuring benchmark results are directly comparable.

### OSD Host Counting and Auto-Skip

Before creating pools, the setup script counts available OSD hosts (`01-setup-storage-pools.sh:212-216`):

```bash
osd_hosts=$(oc get pods -n openshift-storage -l app=rook-ceph-osd \
  -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | grep -c . || echo "0")
```

For each pool, it calculates the required failure domains:
- Replicated: `required_hosts = replication_size` (rep2 needs 2, rep3 needs 3)
- EC: `required_hosts = data_chunks + coding_chunks` (ec-2-1 needs 3, ec-4-2 needs 6)

If the cluster doesn't have enough hosts, the pool is skipped with a warning:

```
[WARN] Pool ec-4-2 requires 6 hosts (failureDomain=host) but only 3 available — skipping
```

This is logged as a warning, not an error — missing pools don't cause the script to fail. The test matrix automatically adjusts to only include pools that were successfully created.

### `enableCrushUpdates: true`

All custom pools set `enableCrushUpdates: true` so that CRUSH rules are automatically updated when nodes are added or removed. This is particularly important for benchmark reproducibility — if you scale the cluster between test runs, CRUSH rules must reflect the new topology for PG placement to be correct.

### Why Not `rack` or `osd`

**Why not `failureDomain: rack`:** On a 3-node cluster, `rack` and `host` are identical (one host per rack). On larger clusters, using `rack` would limit testing to pools needing ≤3 domains, preventing ec-2-2 and ec-4-2 benchmarks. Since the project aims to test all pool types, `host` is the better choice.

**Why not `failureDomain: osd`:** While `osd` allows all pool types on any cluster size, it doesn't match production configurations. Multiple replicas could share a host, distorting I/O patterns and making results non-representative. The benchmarks would show artificially different latency characteristics because replicas share the same NVMe bus.

### Impact on Benchmark Results

The choice of `failureDomain: host` has a measurable effect on benchmark results:

**Rep2 vs Rep3 on 3-node clusters:** With 3 hosts and `failureDomain: host`, rep3 places one replica on every host, giving perfectly balanced PG distribution. Rep2 only uses 2 of 3 hosts per PG, creating pairing combinations that can lead to slight primary OSD imbalances. Combined with the OOB pool's pre-tuned PG count (256 vs a custom pool's ~64), this means rep3 reads can outperform rep2 reads on 3-node clusters — counterintuitive, since rep2 has fewer replicas to write. For writes, rep2 consistently outperforms rep3 because it waits for only 2 OSD acknowledgements vs 3.

**EC pools on 3-node clusters:** ec-2-1 is the only EC pool possible with 3 hosts. Its 3 chunks (2 data + 1 coding) map one per host, similar to rep3. The write path is slower due to parity computation and the need to write all 3 chunks before acknowledging (same as rep3's 3 replicas, plus encoding overhead).

## Next Steps

- [Ceph and ODF](ceph-and-odf.md) — Ceph architecture, pools, RBD, ODF configuration
- [Erasure Coding Explained](erasure-coding-explained.md) — EC vs replication deep dive, chunk mechanics
- [CephBlockPool Setup Guide](../guides/ceph-pool-setup.md) — Step-by-step pool creation, PG autoscaler
- [Configuration Reference](../guides/configuration-reference.md) — All `00-config.sh` parameters including `ODF_POOLS`
- [Troubleshooting](../guides/troubleshooting.md) — Pool creation failures, PG issues, performance problems
