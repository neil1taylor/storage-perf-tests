# vSAN reference data

Scale-test reference data from the sister project that runs the same benchmark methodology on VMware Cloud Foundation (vSAN ESA).

This directory holds verbatim copies of the sister project's outputs so the cross-platform comparison artefacts in this repo can be regenerated without depending on a sibling path.

## Source

- Sister project: `/Users/neiltaylor/Projects/vcs_storage_test`
- Source directory: `example/scale-test/<pool>/`

The sister project deliberately writes `ramp.csv` and `ramp-summary.json` in the same schema as `results/scale-test/<pool>/` in this repo, so the files can be consumed by the comparison generator without transformation.

## Pools

### `raid5-ftt1/`

vSAN ESA RAID-5 storage policy, fault-tolerance method = RAID-5/6, FTT = 1.

- Fetched: 2026-05-28
- Source run_id: `odf-parity-20260528-101735`
- Source timestamp: 2026-05-28T10:06:19Z
- Rate cap: **500 IOPS/VM** (matching ODF scale-test methodology)
- SLA: **5 ms** write p99 (matching ODF scale-test methodology)
- Workload: `mixed-70-30-rated.fio` — 70% read / 30% write, 4k, QD32, numjobs=1
- Methodology: doubling 1→2→4→8→16→32, backfill at 21 and 26
- Includes: prefill (sequential 4M write across test file) + wall-clock sync barrier before measurement start (matches the methodology fix landed in this repo on 2026-05-24)
- Headline: 21 VMs / 20,958 IOPS / 4.29 ms write p99 (capacity); 26 VMs / 36.96 ms (breach); 32 VMs / 200.28 ms (full saturation)

> **Apples-to-apples.** These files are the colleague's re-run at 500 IOPS/VM × 5 ms SLA, matching the current ODF scale-test methodology used in this repo (rep3-virt, rep2, rep1). Comparison artefacts in `docs/examples/scale-test-roks-vs-vcf-raid5-ftt1.html` use these inputs.
>
> A prior 1,000 IOPS/VM × 8 ms SLA run (`cap-20260527-165021`) was the original sister-project capture and is preserved in git history.

Files:

- `ramp.csv` — 9-column ramp data (`vm_count,rate_iops,total_read_iops,total_write_iops,total_bw_mbs,avg_p50_ms,avg_p95_ms,max_p99_ms,sla_pass`).
- `ramp-summary.json` — 12-key summary (`pool, rate_iops, latency_sla_ms, capacity_vms, total_iops_at_capacity, p99_at_capacity_ms, breach_vms, p99_at_breach_ms, resource_ceiling, steps, run_id, timestamp`). Note: lacks `storage_class` and `cluster_description` that the in-repo schema carries. The comparison generator tolerates these missing keys.
- `scale-test-report.html` — the sister project's own self-contained Chart.js report. Kept here for reference; not consumed by this repo's tooling.

## Regenerating the comparison artefact

```bash
./06-generate-report.sh --compare-scale \
  --roks rep3-virt,rep2 \
  --vsan-ref docs/examples/vsan-reference/raid5-ftt1 \
  --output docs/examples/scale-test-roks-vs-vcf-raid5-ftt1.html
```

(`--roks` resolves each pool name against `results/scale-test/<pool>/{ramp.csv,ramp-summary.json}`.)
