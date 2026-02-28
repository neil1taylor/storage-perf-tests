# Multi-Zone ODF Ranking with Cross-Cluster Comparison

**Date:** 2026-02-28
**Status:** Approved
**Clusters:** ocp-virt-mz-cluster (us-south, 3 AZ) vs ocp-virt-420-cluster (eu-de-1, single AZ)

## Goal

Rank all eligible ODF StorageClasses on the multi-zone cluster and compare performance against the existing single-zone ranking to quantify the impact of cross-AZ replica placement on storage I/O.

## Cluster Parity

Both clusters are now matched on hardware and ODF configuration:
- 3x bx2d.metal.96x384 bare metal workers
- 24 OSDs (8 per node), ~70 TiB raw, SSD device class
- ODF 4.19.10, Ceph Squid 19.2.1
- Full encryption (data-at-rest + in-transit + KMS)
- Read affinity enabled

The only architectural difference is `failureDomain: zone` (MZ) vs `failureDomain: rack` (SZ).

## Steps

### Step 1: Create custom ODF pools on MZ (~5-10 min)

Run `./01-setup-storage-pools.sh` on `ocp-virt-mz-cluster`.

Pools created (with `failureDomain: zone`):
- `rep2` (2-replica RBD)
- `cephfs-rep2` (2-replica CephFS)
- `ec-2-1` (erasure coded 2+1)

Auto-skipped (need >3 failure domains):
- `ec-3-1` (needs 4)
- `ec-2-2` (needs 4)
- `ec-4-2` (needs 6)

### Step 2: Run ranking on MZ (~50-60 min)

`./04-run-tests.sh --rank`

7 ODF pools tested:
| Pool | Type | failureDomain |
|------|------|---------------|
| rep3 | Replicated 3 | zone (OOB) |
| rep3-virt | Replicated 3 + rxbounce | zone (OOB) |
| rep3-enc | Replicated 3 + SC encryption | zone (OOB) |
| cephfs-rep3 | CephFS rep 3 | zone (OOB) |
| rep2 | Replicated 2 | zone (custom) |
| cephfs-rep2 | CephFS rep 2 | zone (custom) |
| ec-2-1 | Erasure coded 2+1 | zone (custom) |

3 tests per pool:
| Test | fio Profile | Block Size |
|------|-------------|------------|
| Random I/O | random-rw | 4k |
| Sequential throughput | sequential-rw | 1M |
| Mixed workload | mixed-70-30 | 4k |

Settings: medium VM (4 vCPU, 8Gi), 150Gi PVC, concurrency=1, 60s runtime.

### Step 3: Generate MZ ranking report

`./06-generate-report.sh --rank`

Output: `reports/ranking-<mz-run-id>.html`

### Step 4: Generate cross-cluster comparison

Compare against existing SZ ranking run `perf-20260227-203655` (11 pools, same test matrix).

`./06-generate-report.sh --compare <mz-run-id> perf-20260227-203655`

Output: `reports/compare-<mz-run-id>-vs-perf-20260227-203655.html`

Joins on the 7 common ODF pools. Shows delta% for: read/write IOPS, read/write BW, read/write avg latency, read/write p99 latency.

## Expected Outcomes

- **Write IOPS/BW regression** on MZ due to cross-AZ replica acknowledgment latency
- **Read IOPS/BW roughly comparable** due to read affinity (reads served from local-zone OSD)
- **p99 write latency increase** reflecting inter-AZ RTT (0.5-2ms)
- **Pool relative rankings may shift** — rep2 (2 AZ acks) vs rep3 (3 AZ acks) performance gap may widen; ec-2-1 recovery traffic crosses AZs

## Outputs

1. `reports/ranking-<mz-run-id>.html` — MZ standalone ranking with composite scores
2. `reports/compare-<mz-run-id>-vs-perf-20260227-203655.html` — MZ vs SZ delta report

## No Code Changes Required

The existing pipeline handles multi-zone clusters natively:
- `detect_failure_domain()` reads `zone` from StorageCluster `.status.failureDomain`
- Pool feasibility checks count zone-level CRUSH buckets and skip ineligible EC pools
- `--rank` and `--compare` modes work as-is
