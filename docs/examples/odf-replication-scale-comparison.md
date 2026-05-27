# ODF Storage Performance — Replication, Resource Profile, and Per-VM Throughput

**Date:** 2026-05-26
**Cluster:** IBM Cloud ROKS, `bx2d.metal.96x384` bare metal, 3 workers, NVMe-backed ODF, OpenShift Virtualization 4.20

## TL;DR

Two complementary tests on the same cluster, both rerun with the corrected fio methodology (prefill + synchronized start). They answer different questions and the winner flips depending on which question you ask:

- **"How many VMs at moderate intensity?"** (scale-test, 500 IOPS/VM rate-capped, p99 SLA) → IBM Cloud File CSI wins by a wide margin in VM density and per-op latency.
- **"How fast can a single heavy-hitter VM go?"** (ranking, uncapped, one VM driving as hard as possible) → ODF wins by 14–34× in throughput and per-op latency.

The reversal comes from the IOPS cap on each File CSI share (3000 IOPS hard limit at the 3000-iops profile) and the off-host async replication architecture (great per-op latency, bad single-VM throughput). ODF's per-VM throughput is much higher because the in-cluster Ceph stack lets one client saturate many OSDs simultaneously — but that throughput comes at a synchronous-replication-coordination cost that hurts under multi-VM contention.

### Scale-test: VM density at 500 IOPS/VM, 5 ms write-p99 SLA, mixed-70-30-rated.fio

| Storage backend | VMs sustained | Total IOPS | p99 write latency | Notes |
|-----------------|--------------:|-----------:|------------------:|-------|
| ODF rep3-virt (balanced profile, default) | 32 | 31,936 | 3.49 ms | Three-replica RBD, the safe production default |
| **ODF rep3-virt (performance profile)** | **48** | **47,904** | **4.55 ms** | Same rep3 redundancy, +50% capacity from doubling OSD CPU/memory |
| ODF rep2 (balanced) | 40 | 39,920 | 4.23 ms | Two-replica RBD, +25% capacity over rep3-balanced |
| ODF rep1 (balanced) | 64 | 63,872 | 2.54 ms | Single replica, +100% capacity over rep3-balanced — **no redundancy** |
| IBM Cloud File CSI (3000 IOPS profile) | 96+ | 47,904+ | 0.63 ms | Network-attached NFS, never reaches a storage ceiling — capped by provisioning quota |

The ODF rows tell a clean story:

1. **Replica count is a real, measurable cost.** Going from rep3 to rep2 buys ~25% more capacity at the balanced profile. Going from rep2 to rep1 buys *another* ~60% — disproportionately large because removing the *last* replica eliminates the "wait for the slowest of N OSDs" tail-latency contributor entirely.
2. **OSD resource budget is just as important as replica count.** Switching ODF's `resourceProfile` from `balanced` to `performance` (each OSD goes from 2 vCPU / 5 GiB → 4 vCPU / 8 GiB) lifts the rep3-virt ceiling from 32 → 48 VMs (+50%) — matching what rep2-balanced delivers without sacrificing redundancy. The lift is largely invisible at low load (OSDs aren't CPU-bound) but enormous under load: at 64 VMs, balanced rep3 collapses to 851 ms p99 while performance rep3 stays at 6.06 ms.

For redundancy-required workloads, **rep3-virt on the `performance` profile** is the sweet spot — full three-way durability with rep2-class capacity. Plain rep3-virt on `balanced` remains the safe default if cluster CPU is constrained. rep2 is a viable trade-off if you accept reduced fault tolerance during a node-out window. rep1 is **benchmarking-only** — useful for establishing the hardware/software ceiling without replication overhead, but unsafe for any real data.

### Ranking: per-VM throughput at uncapped IOPS, single VM, mixed fio profiles

| Pool | Random read IOPS | Random write IOPS | Random read p99 | Random write p99 | Seq read | Seq write |
|------|-----------------:|------------------:|----------------:|-----------------:|---------:|----------:|
| **rep2** | **61,490** | **43,326** | **3.39 ms** | 15.27 ms | 5,737 MiB/s | 2,871 MiB/s |
| rep3 | 52,347 | 34,544 | 3.56 ms | 33.16 ms | **6,312 MiB/s** | **2,983 MiB/s** |
| rep3-virt | 52,170 | 35,435 | 3.59 ms | 28.70 ms | 6,338 MiB/s | 2,926 MiB/s |
| cephfs-rep3 | 53,586 | 29,139 | 5.01 ms | 12.52 ms | 4,980 MiB/s | 1,297 MiB/s |
| ec-2-1 | 44,862 | 13,132 | 5.08 ms | 89.65 ms | 3,668 MiB/s | 2,794 MiB/s |
| ibmc-vpc-file-3000-iops | 2,997 | 2,997 | 62.13 ms | 51.64 ms | 188 MiB/s | 188 MiB/s |
| ibmc-vpc-file-1000-iops | 997 | 997 | 170.92 ms | 139.46 ms | 64 MiB/s | 63 MiB/s |
| ibmc-vpc-file-500-iops | 497 | 497 | 350.22 ms | 341.84 ms | 31 MiB/s | 31 MiB/s |

For a single VM driving as hard as it can:

- **rep2 wins random IOPS.** 61k random read / 43k random write at 3.4 / 15.3 ms p99. One fewer replica ack than rep3 buys ~18% more random read IOPS and ~25% more random write IOPS.
- **rep3 wins sequential throughput** (by a tiny margin over rep3-virt). 6.3 GiB/s sequential reads, ~3 GiB/s sequential writes. Effectively saturates the NVMe stack from one client.
- **CephFS-rep3 is competitive for random reads** (53k IOPS) but worse for sequential and write workloads — the extra MDS coordination layer adds latency.
- **EC-2-1 is the slowest replicated/EC pool for writes** (90 ms write p99) because every write requires re-encoding all data and coding chunks.
- **IBM Cloud File CSI hits its provisioned IOPS cap exactly.** The 3000-iops profile sustains 2,997 / 2,997 IOPS — no more. Latency is high (52–62 ms p99) because the workload is rate-limited at the storage backend.
- **The "ODF write p99 of 193–354 ms" reported in earlier comparisons was the prefill artifact.** Real uncapped single-VM write p99 on rep pools is 13–33 ms.

---

## Background — why the original numbers were wrong

This investigation started from a finding that looked alarming: `--scale-test --pool rep3-virt` reported the pool "capacity ceiling" at **6 VMs / ~6,000 IOPS** with a p99 latency cliff from <3 ms at ≤5 VMs to 50–150 ms at 7–8 VMs. That made ODF look an order of magnitude worse than IBM Cloud File CSI and far below what the hardware could deliver.

It turned out the ceiling number was a **methodology artifact**, not a Ceph saturation event. Two effects compounded:

1. **Sparse RBD allocation cost.** RBD images are thinly provisioned. The first write to a 4 MB object incurs an allocation round-trip (read-modify-write of object metadata, OSD-side object creation). When the fio measurement window started immediately, the first-mover VMs were measuring allocation cost, not steady-state IO.
2. **Per-VM fio start stagger.** The runner started fio when each VM finished booting, so VMs in the same batch could be up to ~30 seconds apart. The first VM to start ran *alone* for those 30s, then saw a latency cliff as the others piled on. A bimodal per-VM p99 distribution (some VMs at 2 ms, others at 150 ms) was reported as the worst-case-VM p99 — a single saturating outlier dragging the whole step into "fail."

The fix landed in commit `5420335`:

- **Prefill** the fio test file with a sequential `bs=4M, direct=1` pass before measurement, so every RBD object is allocated up-front. Gated on `filename=fio-testfile` in the fio profile.
- **Synchronized fio start** via a wall-clock barrier. Each ramp step computes `FIO_START_EPOCH = now + SCALE_SYNC_BARRIER_SECS` and the cloud-init runner sleeps until that epoch before starting fio. Every VM begins the measurement window at the same wall-clock moment.

Both fixes are required. Prefill alone still produces the artifact because lone-VM measurements happen during *other VMs' prefill bursts*. With both in place, per-VM p99 is uniform across the cohort, and the reported step p99 reflects true cluster saturation rather than first-mover penalty.

After the fix, rep3-virt's real capacity at 5 ms p99 turned out to be **32 VMs / 32k IOPS / 3.49 ms** — 5× the original bogus figure. Everything in this comparison was measured with the fixed methodology.

The same prefill change also applies to the suite's standard `--rank` mode. Three fio profiles (`random-rw`, `sequential-rw`, `mixed-70-30`) had `filename=fio-testfile` added to their `[global]` block on 2026-05-26. Ranking results published before that date underreported every RBD pool's write performance — particularly write p99 latency, which was inflated by sparse-RBD allocation cost during the first ~10 seconds of the 60-second measurement window. The corrected ranking numbers in the TL;DR are from a fresh `--rank` run after that change.

---

## Two tests, two different questions

This suite has two modes that measure storage from different angles. They are complementary, not redundant — the winner depends on which question you care about.

| Aspect | `--scale-test` | `--rank` |
|---|---|---|
| Question answered | "How many VMs can this pool sustain at moderate intensity?" | "How fast can one VM go all-out?" |
| VM count | Ramped: 1 → 2 → 4 → … → ceiling | Always 1 |
| Per-VM IOPS | Rate-capped (default 500 IOPS/VM) | Uncapped — fio runs at the storage's max |
| fio profile | `mixed-70-30-rated` (single job, randrw) | `random-rw`, `sequential-rw`, `mixed-70-30` (three runs per pool) |
| Pass/fail criterion | p99 write latency vs SLA (default 5 ms) | Always passes — pure measurement |
| What it favors | Backends with low per-op latency at moderate load | Backends with high single-client throughput |
| Typical winner | IBM Cloud File CSI (off-host async replication) | ODF (in-cluster Ceph saturates many OSDs from one client) |

**Concrete example of the flip:**

- Scale-test rep3-virt @ 32 VMs (rate-capped 500 IOPS/VM): 32k total IOPS at 3.49 ms p99 — File CSI 3000 at the same VM count delivers similar IOPS at sub-millisecond p99 because each NFS share has a hardware-enforced async-replicated path.
- Rank rep3-virt single-VM uncapped: 52k random read IOPS at 3.59 ms p99 — File CSI 3000 at single-VM uncapped delivers ~3k IOPS at 62 ms p99 because the 3000-IOPS cap is now the binding constraint, not the storage stack.

Same hardware, same pool, different question, opposite winner. **Use the test that matches your workload's actual usage pattern.**

---

## Test setup

Same parameters across every backend, every step:

| Parameter | Value |
|-----------|-------|
| VM size | small (2 vCPU, 4 GiB RAM) |
| PVC size | 150 GiB |
| fio profile | `mixed-70-30-rated.fio` (70% read / 30% write, 4 KiB, randrw, direct=1, time_based) |
| Per-VM IOPS cap | 500 (rate-limited) |
| Queue depth | 32, numjobs=1 |
| File size | 10 GiB |
| Measurement runtime | 60 s (after 60 s ramp) |
| Latency SLA | 5 ms write-p99 |
| Sync barrier | 500 s (large enough that even slow batches all hit the barrier before fio starts) |
| Prefill | Sequential `bs=4M, direct=1` write across the 10 GiB test file before measurement |

The ramp logic doubles VM count (1, 2, 4, 8, 16, 32, 64, ...) until either the SLA is breached *or* the Kubernetes layer fails to schedule the VMs. On breach, it backfills linearly between the last passing count and the first failing count to pin the ceiling more precisely.

---

## Per-pool ramp data

### ODF rep3-virt (OOB `ocs-storagecluster-ceph-rbd-virtualization`)

| VMs | Total IOPS | avg p50 | avg p95 | max p99 | SLA pass |
|----:|-----------:|--------:|--------:|--------:|:--------:|
| 1   | 499        | 1.47 ms | 1.96 ms | 2.77 ms | ✅ |
| 2   | 998        | 1.24 ms | 1.68 ms | 2.54 ms | ✅ |
| 4   | 1,996      | 1.09 ms | 1.40 ms | 2.31 ms | ✅ |
| 8   | 3,992      | 0.95 ms | 1.24 ms | 2.21 ms | ✅ |
| 16  | 7,984      | 0.91 ms | 1.14 ms | 2.31 ms | ✅ |
| **32** | **31,936** | **1.04 ms** | **1.56 ms** | **3.49 ms** | ✅ |
| 40  | 19,960     | 1.16 ms | 5.67 ms | 15.14 ms | ❌ |
| 64  | 54,369     | 52.44 ms | 115.21 ms | 851.44 ms | ❌ (collapse) |

Ceiling: **32 VMs / 31,936 IOPS / 3.49 ms**. The jump from 32 to 40 already pushes p95 above 5 ms; by 64 VMs the cluster is fully queue-collapsed.

### ODF rep2 (custom `perf-test-sc-rep2`)

| VMs | Total IOPS | avg p50 | avg p95 | max p99 | SLA pass |
|----:|-----------:|--------:|--------:|--------:|:--------:|
| 32  | 31,936     | 0.90 ms | 1.20 ms | 2.51 ms | ✅ |
| **40** | **39,920** | **0.95 ms** | **1.71 ms** | **4.23 ms** | ✅ |
| 48  | 47,904     | 1.05 ms | 5.06 ms | 9.90 ms | ❌ (5 ms SLA) |
| 56  | 54,890     | 1.28 ms | 9.90 ms | 38.54 ms | ❌ |
| 64  | 63,872     | 5.20 ms | 15.91 ms | 80.22 ms | ❌ |

Ceiling at 5 ms SLA: **40 VMs / 39,920 IOPS / 4.23 ms**. (Under a looser 15 ms SLA, rep2 sustains 48 VMs / 48k IOPS / 9.90 ms — that's the figure used in some earlier analysis.)

### ODF rep1 (custom `perf-test-sc-rep1`, no redundancy)

| VMs | Total IOPS | avg p50 | avg p95 | max p99 | SLA pass |
|----:|-----------:|--------:|--------:|--------:|:--------:|
| 32  | 31,936     | 0.59 ms | 0.81 ms | 1.65 ms | ✅ |
| **64** | **63,872** | **0.66 ms** | **0.97 ms** | **2.54 ms** | ✅ |
| 80  | 39,920     | 0.73 ms | 2.79 ms | 32.37 ms | ❌ |
| (128) | n/a | n/a | n/a | n/a | ❌ (Kubernetes resource ceiling — VMs failed to schedule on 3 workers) |

Ceiling: **64 VMs / 63,872 IOPS / 2.54 ms** (`resource_ceiling: false` → true Ceph saturation at 80 VMs, not Kubernetes exhaustion). The exact knee is somewhere in (64, 80); a 72-VM step would pin it tighter, but it's clear the cluster scales cleanly to at least 64 VMs.

### ODF rep3-virt re-run with `resourceProfile: performance`

Same pool, same fio profile, same SLA — only difference is the `StorageCluster.spec.resourceProfile` flipped from `balanced` to `performance` (each OSD: 2 vCPU/5 GiB → 4 vCPU/8 GiB). Re-ran with `SCALE_SYNC_BARRIER_SECS=500 SCALE_PHASE1_START=32`.

| VMs | Total IOPS | avg p50 | avg p95 | max p99 | SLA pass |
|----:|-----------:|--------:|--------:|--------:|:--------:|
| 32  | 31,936     | 1.03 ms | 1.49 ms | 3.16 ms | ✅ |
| 40  | 19,960     | 1.11 ms | 1.90 ms | 3.78 ms | ✅ |
| **48** | **47,904** | **1.20 ms** | **2.33 ms** | **4.55 ms** | ✅ |
| 56  | 27,944     | 1.32 ms | 2.99 ms | 5.41 ms | ❌ (just over) |
| 64  | 31,936     | 1.44 ms | 3.77 ms | 6.06 ms | ❌ |

Ceiling: **48 VMs / 47,904 IOPS / 4.55 ms** — a +50% lift over `balanced`.

Side-by-side at the same VM counts:

| VMs | balanced p99 | performance p99 | improvement |
|----:|-------------:|----------------:|------------:|
| 32  | 3.49 ms | 3.16 ms | -9% |
| 40  | 15.14 ms | 3.78 ms | **-75% (4×)** |
| 48  | (not measured, would have failed)  | **4.55 ms ✅** | ceiling at performance |
| 56  | (not measured) | 5.41 ms | just over SLA |
| 64  | 851 ms (collapse) | 6.06 ms | **-99% (140×)** |

The dramatic gap only appears past 32 VMs. At low load, OSDs are not CPU-bound, so the extra cores don't help much. Once load is high enough that OSDs spend meaningful time on serialization, replication coordination, and BlueStore bookkeeping, the extra CPU budget prevents the queue collapse that hits balanced rep3 between 40 and 64 VMs.

### Ranking re-run — single-VM uncapped IOPS

Run `2026-05-26` with `./04-run-tests.sh --rank`. Three tests per pool: `random-rw` @ 4 KiB, `sequential-rw` @ 1 MiB, `mixed-70-30` @ 4 KiB. One medium VM (4 vCPU, 8 GiB), 150 GiB PVC, concurrency 1, 60 s runtime + 10 s ramp.

Random read/write (4 KiB, randread then randwrite via stonewall, both jobs use the prefilled `fio-testfile`):

| Pool | Random read IOPS | Random write IOPS | Random read p99 | Random write p99 |
|------|-----------------:|------------------:|----------------:|-----------------:|
| rep2 | 61,490 | 43,326 | 3.39 ms | 15.27 ms |
| cephfs-rep3 | 53,586 | 29,139 | 5.01 ms | 12.52 ms |
| rep3 | 52,347 | 34,544 | 3.56 ms | 33.16 ms |
| rep3-virt | 52,170 | 35,435 | 3.59 ms | 28.70 ms |
| ec-2-1 | 44,862 | 13,132 | 5.08 ms | 89.65 ms |
| ibmc-vpc-file-3000-iops | 2,997 | 2,997 | 62.13 ms | 51.64 ms |
| ibmc-vpc-file-1000-iops | 997 | 997 | 170.92 ms | 139.46 ms |
| ibmc-vpc-file-500-iops | 497 | 497 | 350.22 ms | 341.84 ms |

Sequential read/write (1 MiB, seqread then seqwrite via stonewall):

| Pool | Read IOPS | Write IOPS | Read BW | Write BW |
|------|----------:|-----------:|--------:|---------:|
| rep3-virt | 6,338 | 2,926 | 6,338 MiB/s | 2,926 MiB/s |
| rep3 | 6,310 | 2,981 | 6,312 MiB/s | 2,983 MiB/s |
| rep2 | 5,735 | 2,868 | 5,737 MiB/s | 2,871 MiB/s |
| cephfs-rep3 | 4,978 | 1,294 | 4,980 MiB/s | 1,297 MiB/s |
| ec-2-1 | 3,666 | 2,791 | 3,668 MiB/s | 2,794 MiB/s |
| ibmc-vpc-file-3000-iops | 185 | 185 | 188 MiB/s | 188 MiB/s |
| ibmc-vpc-file-1000-iops | 62 | 60 | 64 MiB/s | 63 MiB/s |
| ibmc-vpc-file-500-iops | 29 | 29 | 31 MiB/s | 31 MiB/s |

Notes:

- `rep3-enc` and `cephfs-rep2` are not in the table — both failed all tests due to pre-existing cluster issues (`rep3-enc` needs an IBM Key Protect secret that isn't installed; `cephfs-rep2` PVCs can't bind because the custom CephFilesystem isn't in the CephFS CSI auth caps). Neither is caused by the methodology change.
- `rep1` is not in the table — the pool was deleted between the scale-test and the ranking re-run so that Rook's `ok-to-stop` check would allow OSD restarts during a `resourceProfile` change (rep1 has size=1 so stopping any OSD would risk data loss). Rep1's scale-test results above are still valid.
- `random-rw` and `sequential-rw` profiles have two `[job]` sections joined with `stonewall`. fio runs them sequentially, so the per-job results live in `jobs[0]` (read) and `jobs[1]` (write) in the output JSON. The aggregator script's default of reading only `jobs[0]` understates write performance in these profiles — the numbers above are extracted from both job slots.

### IBM Cloud File CSI 3000-IOPS profile (`ibmc-vpc-file-3000-iops`)

| VMs | Total IOPS | avg p50 | avg p95 | max p99 | SLA pass |
|----:|-----------:|--------:|--------:|--------:|:--------:|
| 1   | 499        | 0.51 ms | 0.68 ms | 0.77 ms | ✅ |
| 8   | 3,992      | 0.40 ms | 0.56 ms | 0.68 ms | ✅ |
| 32  | 15,968     | 0.38 ms | 0.52 ms | 0.69 ms | ✅ |
| 64  | 31,936     | 0.36 ms | 0.49 ms | 0.65 ms | ✅ |
| **96** | **47,904** | **0.35 ms** | **0.47 ms** | **0.63 ms** | ✅ |

The File CSI ramp never breaches the SLA. It stops at 96 VMs because of IBM Cloud File provisioning quota, not because of storage performance. The latency *improves* with VM count (less impact from per-VM overhead amortized over a larger queue) and stays sub-millisecond throughout.

---

## Why the numbers look the way they do

### OSD CPU budget caps the high-load ceiling

The `resourceProfile: balanced` default gives each OSD `cpu=2, mem=5Gi` (request = limit, so guaranteed but capped at 2 cores). Under saturating load, each OSD is doing a lot of synchronous work: RADOS request handling, replication coordination with peer OSDs, BlueStore write batching, and journal sync. With only 2 cores per OSD, the saturation knee comes earlier and the collapse past the knee is sharper.

The `performance` profile doubles the per-OSD budget to `cpu=4, mem=8Gi`. The extra CPU lets OSDs absorb more concurrent IO before queueing, and the extra memory raises BlueStore cache hit rates. The result is a higher ceiling *and* a much more graceful saturation curve — at 64 VMs, balanced collapses to 851 ms while performance stays under 7 ms.

This pattern is consistent with general advice for Ceph at scale: NVMe is fast enough that OSD CPU is usually the bottleneck, not the underlying disk. Giving OSDs more CPU is often higher-leverage than adding nodes.

### Each replica is a synchronous ack on the write path

A Ceph RBD write is acknowledged to the client only after **every replica OSD has committed it to its journal**. In a 3-replica pool, the primary OSD sends the write to two secondaries in parallel and waits for both to reply. The acknowledged latency is therefore the *maximum* of three OSD commit times — and OSD commit times have a long tail (NVMe GC, CPU scheduling, brief network jitter). Even if the typical commit is 0.5 ms, the worst of three is reliably 2–4 ms under moderate load and worse under contention.

Going from rep3 to rep2 removes one of those waits. The "max of 3" becomes "max of 2." Tail latency shrinks, and under load the savings compound — because cross-OSD variance grows with load, the slowest-of-N gap widens as the cluster gets busier.

Going from rep2 to rep1 removes the *last* sync wait. There is no secondary OSD to coordinate with — the primary writes its own journal and acknowledges. The "max of N" term vanishes and the latency floor drops to a single OSD's commit time.

This is why the per-replica gains are not linear:

- rep3 → rep2: **+25% VMs**, p99 1.65 → 2.51 ms at 32 VMs (-25% latency improvement)
- rep2 → rep1: **+60% VMs**, p99 2.51 → 1.65 ms at 32 VMs (-34% latency improvement)

The rep2-to-rep1 step is the bigger one because *some* synchronous coordination remains in rep2 (one ack), but rep1 has *none*.

### Why IBM Cloud File CSI looks unbeatable in this test

File CSI numbers are not comparable to ODF on architecture grounds. ODF runs *inside* the cluster on the worker nodes' NVMe drives — every IO traverses the Ceph stack (RADOS, OSD, replication, BlueStore). IBM Cloud File is a managed NFS service running on dedicated storage backends; the worker only sees a network-attached NFS mount with a hardware-enforced IOPS cap.

Two architectural advantages explain the sub-millisecond p99:

1. **Async replication, off-host.** The NFS server backend replicates internally, and *does not block the client ack* on cross-replica coordination. Durability is achieved without paying the synchronous "max of N OSDs" cost on the write path.
2. **No in-host storage stack cost.** The worker CPU is not running OSD daemons, BlueStore, or RBD client code. The whole storage stack is offloaded to dedicated infrastructure.

This is the same reason a SAN or a dedicated all-flash array always wins per-op latency comparisons against a hyperconverged software-defined storage layer — different architecture, different tradeoffs.

The File CSI 96-VM ceiling is also **not a storage limit**. The cluster ran out of provisioning quota (NFS shares per account) before File CSI showed any sign of saturation. The actual capacity could be considerably higher; we just can't measure it on this account.

---

## Durability trade-offs

| Pool | Replicas | Tolerates loss of | Recovery during double-failure | Production-suitable? |
|------|---------:|-------------------|--------------------------------|----------------------|
| rep3 | 3 | 2 OSDs / 2 nodes  | Yes (degraded but available)   | ✅ Default for any real data |
| rep2 | 2 | 1 OSD / 1 node    | One more failure = data unavailable | ⚠️ Risky on a 3-node cluster — a node failure during recovery risks data loss |
| rep1 | 1 | 0                 | Any single OSD failure = data loss | ❌ Benchmark / scratch only |

On a 3-node cluster like this one, rep2 is more dangerous than it sounds. If a worker node goes down, the cluster has only 2 healthy copies of every object and recovery is starting from scratch. A second failure during the recovery window — common during planned maintenance or upgrades — loses data.

If the workload can tolerate "data loss on any disk failure" (e.g., reproducible test data, ephemeral caches), rep1 has the highest performance ceiling. For anything else, rep3 remains the right default.

---

## Reproducibility

All ramps were collected on the same cluster within a short window using the post-fix `04-run-tests.sh`. To reproduce on a similar 3-worker bare-metal ROKS cluster:

```bash
# One-time setup — creates the custom CephBlockPools + StorageClasses
./01-setup-storage-pools.sh

# Per-pool ramp (run sequentially, each takes ~1–2 h)
SCALE_SYNC_BARRIER_SECS=500 ./04-run-tests.sh --scale-test --pool rep3-virt
SCALE_SYNC_BARRIER_SECS=500 ./04-run-tests.sh --scale-test --pool rep2
SCALE_SYNC_BARRIER_SECS=500 ./04-run-tests.sh --scale-test --pool rep1
SCALE_SYNC_BARRIER_SECS=500 ./04-run-tests.sh --scale-test --pool ibmc-vpc-file-3000-iops
```

If a pool is already known to clear early steps, skip ahead with `SCALE_PHASE1_START`:

```bash
# Start the doubling phase at 32 VMs instead of 1
SCALE_SYNC_BARRIER_SECS=500 SCALE_PHASE1_START=32 \
  ./04-run-tests.sh --scale-test --pool rep1
```

Per-step output lives in `results/scale-test/<pool>/step-NNN-vms/` (per-VM fio JSON + diagnostics dump) and the aggregated ramp is in `results/scale-test/<pool>/ramp.csv`.

The rep1 pool requires `requireSafeReplicaSize: false` because Ceph refuses size=1 with the safety flag enabled — handled in `01-setup-storage-pools.sh` since 2026-05-26.

### Switching the OSD resource profile

To switch ODF from `balanced` to `performance` (or back):

```bash
# Patch the StorageCluster
oc patch storagecluster ocs-storagecluster -n openshift-storage \
  --type=merge -p '{"spec":{"resourceProfile":"performance"}}'

# Wait for all 24 OSDs to roll (~15–25 min, one host at a time)
watch "oc get pod -n openshift-storage -l app=rook-ceph-osd \
  -o json | jq -r '[.items[].spec.containers[] | select(.name==\"osd\") \
  | .resources.requests.cpu] | unique'"
```

**Caveat learned the hard way:** Rook's `ok-to-stop` safety check will refuse to roll *any* OSD if a rep1 (size=1) pool exists, because stopping any OSD could lose data. Delete any rep1 CephBlockPools before changing `resourceProfile` or doing other operations that trigger OSD restarts:

```bash
oc delete sc perf-test-sc-rep1
oc delete cephblockpool perf-test-rep1 -n openshift-storage
```

---

## Caveats and limitations

- **3-worker cluster.** The ODF ceilings reflect this hardware. A 6- or 9-worker cluster with the same per-node spec would scale roughly linearly for rep1, less than linearly for rep3 (cross-rack replication traffic grows with cluster size).
- **No multi-zone validation.** All tests ran in a single zone. Multi-AZ ODF adds cross-zone replication latency to every write and would shift the rep3 ceiling down.
- **Scale-test uses a single fio profile.** `mixed-70-30-rated.fio` at 4 KiB / QD32 is one of many possible workloads. Sequential or write-heavy profiles would show different ratios — RBD's write path is the one most affected by replica count. The ranking section covers three additional profiles (random-rw, sequential-rw, mixed-70-30) at single-VM uncapped.
- **The 64→80 rep1 gap is not pinned.** The exact storage knee is somewhere between 64 and 80 VMs. A 72-VM backfill step would refine the number; the conclusion ("rep1 ≥ 2× rep3 capacity") holds either way.
- **File CSI scale-test ceiling is a provisioning limit, not a performance limit.** We couldn't measure where File CSI actually saturates because we ran out of NFS-share quota first. The ranking results, by contrast, *do* hit File CSI's true per-VM ceiling because each share is hardware-capped at its provisioned IOPS rating (497 / 997 / 2,997 IOPS).
- **rep3 vs rep2 numbers depend on PG autoscaler state.** The OOB rep3 pool has a long-converged PG count; the custom rep2 / rep1 pools were tuned with `targetSizeRatio: 0.1` to ensure their PG count converges similarly. Without that tuning, custom pools start with 1 PG and look ~6× worse than the OOB pool — purely an artifact of PG distribution, not replica count.
- **Ranking is single-VM and uncapped — extrapolate carefully.** A 50k IOPS / 3.6 ms p99 reading does not imply 50 VMs would each get the same. Per-op latency degrades sharply with concurrent clients (that's exactly what the scale-test measures). The ranking number is the *headroom* of a single client, not a per-VM SLA at scale.
- **The ranking results assume the cluster is in steady state.** The first attempt at this rerun produced widespread `exit code 127` failures on RBD pools that turned out to be transient — the OSDs were rolling back from `performance` to `balanced` profile at the time. After the cluster settled, the same rerun succeeded for every pool that has a working StorageClass.

---

## Conclusions

1. **The ODF "6-VM ceiling" reported in earlier runs was a measurement artifact.** Both the sparse-RBD allocation cost and the per-VM fio start stagger were measured as if they were Ceph saturation. The fix (prefill + synchronized fio start for scale-test, plus `filename=fio-testfile` in the three ranking fio profiles) is now the default behavior in `04-run-tests.sh`, `cloud-init/fio-runner.yaml`, and the affected `fio-profiles/*.fio` files.
2. **The real ODF rep3-balanced ceiling on this cluster is 32 VMs / 32k IOPS / 3.49 ms p99** — 5× the original bogus figure, and competitive with any in-cluster hyperconverged storage stack.
3. **OSD resource budget is a first-class lever.** Switching `resourceProfile` from `balanced` to `performance` (2→4 vCPU and 5→8 GiB per OSD) lifts the rep3-virt ceiling by 50% (32 → 48 VMs) without touching replica count, and drastically softens the post-saturation collapse (851 ms → 6 ms at 64 VMs). On NVMe hardware where OSD CPU is usually the bottleneck, this is the single highest-leverage tuning change for VM density.
4. **Replica count is the other major lever.** At balanced profile: rep3 → rep2 buys +25% capacity; rep3 → rep1 buys +100%. The biggest jump is removing the last sync ack (rep2 → rep1) because it eliminates the "wait for slowest replica" tail-latency contributor entirely.
5. **rep3-virt on `performance` profile delivers rep2-class capacity without sacrificing redundancy.** This is likely the right default for production VM workloads on a CPU-rich cluster.
6. **For single-VM uncapped workloads, ODF outperforms IBM Cloud File CSI by 14–34×.** rep2 delivers 61k random read IOPS vs File CSI 3000's 3k IOPS at the same VM count of 1. The "ODF write p99 of 193–354 ms" cited in earlier reports was the prefill artifact — real uncapped single-VM write p99 on replicated pools is 13–33 ms.
7. **The scale-test ↔ ranking flip is architectural, not a bug.** File CSI's off-host async replication wins per-op latency at moderate per-VM load; ODF's in-cluster Ceph stack wins per-VM throughput because one client can saturate many OSDs. Pick the test that matches the workload's actual concurrency and intensity profile — neither pool is universally faster.
8. **Recommended defaults for a 3-node bare-metal ROKS cluster running VMs on RBD:**
   - If cluster CPU headroom allows: rep3-virt with `resourceProfile: performance` (48 VMs / 48k IOPS / 4.55 ms p99 ceiling at scale; 52k single-VM random read IOPS uncapped)
   - If CPU-constrained: rep3-virt with `resourceProfile: balanced` (32 VMs / 32k IOPS / 3.49 ms ceiling)
   - For benchmarking the hardware ceiling only: rep1 (64 VMs / 64k IOPS / 2.54 ms — no redundancy)
   - For VM workloads that want lowest per-op latency at moderate concurrency: IBM Cloud File CSI 3000 (96+ VMs / 96k+ IOPS / 0.63 ms in scale-test). Trade-off: single heavy-hitter VMs are capped at 3000 IOPS.

## Related documents

- [Scale Test Auto-Ramp Design](../plans/2026-04-21-scale-test-auto-ramp-design.md) — original design for `--scale-test`
- [Scale Test Auto-Ramp Implementation](../plans/2026-04-21-scale-test-auto-ramp.md) — implementation reference
- [ROKS vs VCF Storage Performance Comparison](roks-vs-vcf-comparison.md) — note: any RBD numbers in this older comparison were measured before the prefill/sync-barrier fix and may overstate ODF latency.
