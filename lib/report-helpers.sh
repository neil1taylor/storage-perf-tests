#!/usr/bin/env bash
# =============================================================================
# lib/report-helpers.sh — Report generation utilities
# =============================================================================

# ---------------------------------------------------------------------------
# Parse fio JSON and extract key metrics into a CSV row
# ---------------------------------------------------------------------------
parse_fio_json_to_csv() {
  local json_file="$1"
  local pool_name="$2"
  local vm_size="$3"
  local pvc_size="$4"
  local concurrency="$5"
  local fio_profile="$6"
  local block_size="$7"

  if [[ ! -f "${json_file}" ]]; then
    log_warn "Missing fio JSON: ${json_file}"
    return 0
  fi

  # Validate JSON syntax — fio may prepend error text (e.g. ENOSPC)
  if ! jq empty "${json_file}" 2>/dev/null; then
    log_warn "Skipping invalid JSON (syntax error): ${json_file}"
    return 0
  fi

  # Validate fio JSON structure — must have non-empty jobs array with expected fields
  local job_count
  job_count=$(jq '.jobs | length' "${json_file}" 2>/dev/null || echo "0")
  if [[ "${job_count}" -eq 0 ]]; then
    log_warn "Skipping fio JSON with no jobs: ${json_file}"
    return 0
  fi
  if ! jq -e '.jobs[0] | has("read") and has("write")' "${json_file}" &>/dev/null; then
    log_warn "Skipping fio JSON missing read/write fields: ${json_file}"
    return 0
  fi

  jq -r --arg pool "${pool_name}" \
         --arg vmsz "${vm_size}" \
         --arg pvcsz "${pvc_size}" \
         --arg conc "${concurrency}" \
         --arg prof "${fio_profile}" \
         --arg bs "${block_size}" '
    .jobs[] |
    [
      $pool, $vmsz, $pvcsz, $conc, $prof, $bs,
      .jobname,
      (.read.iops // 0 | floor),
      (.read.bw // 0),
      (.read.lat_ns.mean // 0 | . / 1000000 | . * 100 | floor | . / 100),
      (.read.clat_ns.percentile["99.000000"] // 0 | . / 1000000 | . * 100 | floor | . / 100),
      (.write.iops // 0 | floor),
      (.write.bw // 0),
      (.write.lat_ns.mean // 0 | . / 1000000 | . * 100 | floor | . / 100),
      (.write.clat_ns.percentile["99.000000"] // 0 | . / 1000000 | . * 100 | floor | . / 100)
    ] | @csv
  ' "${json_file}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# CSV header
# ---------------------------------------------------------------------------
csv_header() {
  echo '"storage_pool","vm_size","pvc_size","concurrency","fio_profile","block_size","job_name","read_iops","read_bw_kib","read_lat_avg_ms","read_lat_p99_ms","write_iops","write_bw_kib","write_lat_avg_ms","write_lat_p99_ms"'
}

# ---------------------------------------------------------------------------
# Aggregate all fio results into a single CSV
# ---------------------------------------------------------------------------
aggregate_results_csv() {
  local results_dir="$1"
  local output_csv="$2"

  log_info "Aggregating results into ${output_csv}..."
  csv_header > "${output_csv}"

  # Each result directory is named: pool/vmsize/pvcsize/concurrency/profile/blocksize/
  while read -r json_file; do
    local rel_path="${json_file#${results_dir}/}"
    # Parse path components
    IFS='/' read -r pool vmsize pvcsize concurrency profile blocksize _filename <<< "${rel_path}"

    if [[ -z "${pool}" || -z "${vmsize}" || -z "${profile}" || -z "${blocksize}" ]]; then
      log_warn "Skipping file with unexpected path structure: ${rel_path}"
      continue
    fi

    parse_fio_json_to_csv "${json_file}" \
      "${pool}" "${vmsize}" "${pvcsize}" "${concurrency}" "${profile}" "${blocksize}" || true
  done < <(find "${results_dir}" -name "*-fio.json" -type f | sort) >> "${output_csv}"

  local lines
  lines=$(wc -l < "${output_csv}")
  log_info "CSV generated: ${output_csv} (${lines} rows)"
}

# ---------------------------------------------------------------------------
# Generate Markdown summary report
# ---------------------------------------------------------------------------
generate_markdown_report() {
  local csv_file="$1"
  local output_md="$2"
  local run_id="${RUN_ID}"

  log_info "Generating Markdown report: ${output_md}"

  cat > "${output_md}" <<MDEOF
# VM Storage Performance Test Report

**Run ID:** ${run_id}
**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Cluster:** ${CLUSTER_DESCRIPTION}
**ODF Version:** $(oc get csv -n ${ODF_NAMESPACE} -o jsonpath='{.items[0].spec.version}' 2>/dev/null || echo "N/A")

## Test Configuration

| Parameter | Value |
|-----------|-------|
| VM Sizes | Small (2vCPU/4Gi), Medium (4vCPU/8Gi), Large (8vCPU/16Gi) |
| PVC Sizes | ${PVC_SIZES[*]} |
| Concurrency | ${CONCURRENCY_LEVELS[*]} VMs |
| fio Runtime | ${FIO_RUNTIME}s (ramp: ${FIO_RAMP_TIME}s) |
| Block Sizes | ${FIO_BLOCK_SIZES[*]} |
| I/O Depth | ${FIO_IODEPTH} |
| Num Jobs | ${FIO_NUMJOBS} |

## Storage Pools Tested

### ODF (Ceph) Pools
| Pool | Type | Config |
|------|------|--------|
MDEOF

  for pool_def in "${ODF_POOLS[@]}"; do
    IFS=':' read -r name type p1 p2 <<< "${pool_def}"
    if [[ "${type}" == "replicated" ]]; then
      echo "| ${name} | Replicated | size=${p1} |" >> "${output_md}"
    elif [[ "${type}" == "cephfs" ]]; then
      echo "| ${name} | CephFS Replicated | data_size=${p1}, metadata_size=3 |" >> "${output_md}"
    else
      echo "| ${name} | Erasure Coded | k=${p1}, m=${p2} |" >> "${output_md}"
    fi
  done

  cat >> "${output_md}" <<'MDEOF'

### IBM Cloud File CSI Profiles
MDEOF

  if [[ -f "${RESULTS_DIR}/file-storage-classes.txt" ]]; then
    while IFS= read -r sc; do
      echo "- ${sc}" >> "${output_md}"
    done < "${RESULTS_DIR}/file-storage-classes.txt"
  fi

  if [[ -f "${RESULTS_DIR}/block-storage-classes.txt" ]]; then
    cat >> "${output_md}" <<'MDEOF'

### IBM Cloud Block CSI Profiles
MDEOF
    while IFS= read -r sc; do
      echo "- ${sc}" >> "${output_md}"
    done < "${RESULTS_DIR}/block-storage-classes.txt"
  fi

  cat >> "${output_md}" <<'MDEOF'

## Results Summary

### Random 4k IOPS (Higher is Better)
MDEOF

  # Generate summary tables from CSV using awk
  if [[ -f "${csv_file}" ]]; then
    echo '| Storage Pool | VM Size | Read IOPS | Write IOPS | Read Lat (ms) | Write Lat (ms) |' >> "${output_md}"
    echo '|-------------|---------|-----------|------------|---------------|----------------|' >> "${output_md}"

    # Extract random 4k results for the summary
    tail -n +2 "${csv_file}" | grep -i "rand" | grep '"4k"' | \
      sort -t',' -k8,8 -nr | \
      awk -F',' '{gsub(/"/, ""); printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $8, $12, $10, $14}' \
      >> "${output_md}" 2>/dev/null || echo "No random 4k data available" >> "${output_md}"

    cat >> "${output_md}" <<'MDEOF'

### Sequential 1M Throughput (Higher is Better)

| Storage Pool | VM Size | Read BW (MiB/s) | Write BW (MiB/s) |
|-------------|---------|-----------------|-------------------|
MDEOF

    tail -n +2 "${csv_file}" | grep -i "seq" | grep '"1M"' | \
      sort -t',' -k9,9 -nr | \
      awk -F',' '{gsub(/"/, ""); printf "| %s | %s | %.1f | %.1f |\n", $1, $2, $9/1024, $13/1024}' \
      >> "${output_md}" 2>/dev/null || echo "No sequential 1M data available" >> "${output_md}"
  fi

  # Performance Rankings from summary CSV
  local summary_csv="${REPORTS_DIR}/summary-${RUN_ID}.csv"
  if [[ -f "${summary_csv}" ]] && [[ $(wc -l < "${summary_csv}") -gt 1 ]]; then
    cat >> "${output_md}" <<'MDEOF'

## Performance Rankings

### Random I/O (IOPS) — Higher is Better

| Rank | Storage Pool | Read IOPS | Write IOPS |
|------|-------------|-----------|------------|
MDEOF
    tail -n +2 "${summary_csv}" | sort -t',' -k2,2 -nr | \
      awk -F',' 'BEGIN{rank=1} {gsub(/"/, ""); printf "| #%d | %s | %s | %s |\n", rank++, $1, $2, $3}' \
      >> "${output_md}"

    cat >> "${output_md}" <<'MDEOF'

### Sequential Throughput (MiB/s) — Higher is Better

| Rank | Storage Pool | Read BW (MiB/s) | Write BW (MiB/s) |
|------|-------------|-----------------|-------------------|
MDEOF
    tail -n +2 "${summary_csv}" | sort -t',' -k4,4 -nr | \
      awk -F',' 'BEGIN{rank=1} {gsub(/"/, ""); printf "| #%d | %s | %s | %s |\n", rank++, $1, $4, $5}' \
      >> "${output_md}"

    cat >> "${output_md}" <<'MDEOF'

### Average Latency (ms) — Lower is Better

| Rank | Storage Pool | Read Lat (ms) | Write Lat (ms) |
|------|-------------|---------------|----------------|
MDEOF
    tail -n +2 "${summary_csv}" | sort -t',' -k6,6 -n | \
      awk -F',' 'BEGIN{rank=1} {gsub(/"/, ""); printf "| #%d | %s | %s | %s |\n", rank++, $1, $6, $7}' \
      >> "${output_md}"

    cat >> "${output_md}" <<'MDEOF'

### p99 Tail Latency (ms) — Lower is Better

| Rank | Storage Pool | Read p99 (ms) | Write p99 (ms) |
|------|-------------|---------------|----------------|
MDEOF
    tail -n +2 "${summary_csv}" | sort -t',' -k8,8 -n | \
      awk -F',' 'BEGIN{rank=1} {gsub(/"/, ""); printf "| #%d | %s | %s | %s |\n", rank++, $1, $8, $9}' \
      >> "${output_md}"
  fi

  cat >> "${output_md}" <<'MDEOF'

## Detailed Results

See the full CSV file for all test permutations and metrics.

## Notes

- All tests used `direct=1` (O_DIRECT) to bypass OS page cache
- Latency values are in milliseconds
- Bandwidth values in the CSV are in KiB/s; summary tables show MiB/s
- p99 latency represents the 99th percentile tail latency
MDEOF

  log_info "Markdown report generated: ${output_md}"
}

# ---------------------------------------------------------------------------
# Generate HTML dashboard with Chart.js
# ---------------------------------------------------------------------------
generate_html_report() {
  local csv_file="$1"
  local output_html="$2"

  log_info "Generating HTML dashboard: ${output_html}"

  # Read CSV data and convert to JSON for Chart.js
  local json_data
  json_data=$(python3 -c "
import csv, json, sys

data = []
with open('${csv_file}', 'r') as f:
    reader = csv.DictReader(f)
    for row in reader:
        for key in ['read_iops', 'write_iops', 'read_bw_kib', 'write_bw_kib']:
            try:
                row[key] = float(row[key])
            except (ValueError, KeyError):
                row[key] = 0
        for key in ['read_lat_avg_ms', 'read_lat_p99_ms', 'write_lat_avg_ms', 'write_lat_p99_ms']:
            try:
                row[key] = float(row[key])
            except (ValueError, KeyError):
                row[key] = 0
        data.append(row)
print(json.dumps(data))
" 2>/dev/null || echo "[]")

  cat > "${output_html}" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>VM Storage Performance Report — ${RUN_ID}</title>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.js"></script>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f5f5; color: #333; }
    .header { background: #1a1a2e; color: white; padding: 2rem; }
    .header h1 { font-size: 1.5rem; margin-bottom: 0.5rem; }
    .header .meta { color: #aaa; font-size: 0.9rem; }
    .container { max-width: 1400px; margin: 0 auto; padding: 1rem; }
    .filters { background: white; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; display: flex; flex-wrap: wrap; gap: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    .filter-group { display: flex; flex-direction: column; }
    .filter-group label { font-size: 0.75rem; font-weight: 600; text-transform: uppercase; color: #666; margin-bottom: 0.25rem; }
    .filter-group select { padding: 0.5rem; border: 1px solid #ddd; border-radius: 4px; }
    .charts { display: grid; grid-template-columns: repeat(auto-fit, minmax(600px, 1fr)); gap: 1rem; }
    .chart-card { background: white; border-radius: 8px; padding: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    .chart-card h3 { font-size: 1rem; margin-bottom: 0.5rem; color: #1a1a2e; }
    .data-table { width: 100%; border-collapse: collapse; margin-top: 1rem; font-size: 0.85rem; }
    .data-table th, .data-table td { padding: 0.5rem; text-align: right; border-bottom: 1px solid #eee; }
    .data-table th { background: #f8f9fa; font-weight: 600; text-align: left; position: sticky; top: 0; }
    .data-table td:first-child { text-align: left; }
    .table-wrapper { max-height: 500px; overflow-y: auto; }
  </style>
</head>
<body>
  <div class="header">
    <h1>VM Storage Performance Report</h1>
    <div class="meta">
      Run: ${RUN_ID} | ${CLUSTER_DESCRIPTION} | ODF + IBM Cloud File/Block
    </div>
  </div>

  <div class="container">
    <div class="filters" id="filters"></div>
    <div class="charts" id="charts"></div>
    <div class="chart-card" style="margin-top:1rem">
      <h3>Raw Data</h3>
      <div class="table-wrapper" id="rawTable"></div>
    </div>
  </div>

  <script>
    const DATA = ${json_data};

    // Extract unique values for filters
    const unique = (arr, key) => [...new Set(arr.map(r => r[key]))].sort();
    const pools = unique(DATA, 'storage_pool');
    const vmSizes = unique(DATA, 'vm_size');
    const pvcSizes = unique(DATA, 'pvc_size');
    const profiles = unique(DATA, 'fio_profile');
    const blockSizes = unique(DATA, 'block_size');

    const filtersDiv = document.getElementById('filters');
    function addFilter(id, label, options) {
      const group = document.createElement('div');
      group.className = 'filter-group';
      group.innerHTML = '<label>' + label + '</label><select id="' + id + '"><option value="all">All</option>' +
        options.map(o => '<option value="' + o + '">' + o + '</option>').join('') + '</select>';
      filtersDiv.appendChild(group);
      group.querySelector('select').addEventListener('change', updateCharts);
    }

    addFilter('f-pool', 'Storage Pool', pools);
    addFilter('f-vmsize', 'VM Size', vmSizes);
    addFilter('f-pvcsize', 'PVC Size', pvcSizes);
    addFilter('f-profile', 'fio Profile', profiles);
    addFilter('f-bs', 'Block Size', blockSizes);

    let charts = {};
    function getFiltered() {
      const f = {
        pool: document.getElementById('f-pool').value,
        vmsize: document.getElementById('f-vmsize').value,
        pvcsize: document.getElementById('f-pvcsize').value,
        profile: document.getElementById('f-profile').value,
        bs: document.getElementById('f-bs').value
      };
      return DATA.filter(r =>
        (f.pool === 'all' || r.storage_pool === f.pool) &&
        (f.vmsize === 'all' || r.vm_size === f.vmsize) &&
        (f.pvcsize === 'all' || r.pvc_size === f.pvcsize) &&
        (f.profile === 'all' || r.fio_profile === f.profile) &&
        (f.bs === 'all' || r.block_size === f.bs)
      );
    }

    const COLORS = ['#e63946','#457b9d','#2a9d8f','#e9c46a','#f4a261','#264653','#a8dadc','#d62828','#023e8a','#780000'];

    function makeChart(canvasId, title, dataFn) {
      const card = document.createElement('div');
      card.className = 'chart-card';
      card.innerHTML = '<h3>' + title + '</h3><canvas id="' + canvasId + '"></canvas>';
      document.getElementById('charts').appendChild(card);
    }

    makeChart('iopsChart', 'IOPS by Storage Pool');
    makeChart('bwChart', 'Throughput (MiB/s) by Storage Pool');
    makeChart('latChart', 'Average Latency (ms) by Storage Pool');
    makeChart('p99Chart', 'p99 Latency (ms) by Storage Pool');

    function updateCharts() {
      const filtered = getFiltered();
      // Group by storage pool
      const grouped = {};
      filtered.forEach(r => {
        if (!grouped[r.storage_pool]) grouped[r.storage_pool] = [];
        grouped[r.storage_pool].push(r);
      });

      function avgMetric(rows, key) {
        const vals = rows.map(r => parseFloat(r[key]) || 0).filter(v => v > 0);
        return vals.length ? vals.reduce((a,b) => a+b, 0) / vals.length : 0;
      }

      // Sort pools by a metric; asc=true for latency (lower=better), false for IOPS/BW (higher=better)
      function sortedPools(grouped, metric, asc) {
        return Object.keys(grouped).sort((a, b) => {
          const va = avgMetric(grouped[a], metric);
          const vb = avgMetric(grouped[b], metric);
          return asc ? va - vb : vb - va;
        });
      }

      function updateBarChart(canvasId, labels, readData, writeData, yLabel) {
        if (charts[canvasId]) charts[canvasId].destroy();
        charts[canvasId] = new Chart(document.getElementById(canvasId), {
          type: 'bar',
          data: {
            labels: labels,
            datasets: [
              { label: 'Read', data: readData, backgroundColor: '#457b9d' },
              { label: 'Write', data: writeData, backgroundColor: '#e63946' }
            ]
          },
          options: { responsive: true, scales: { y: { beginAtZero: true, title: { display: true, text: yLabel } } } }
        });
      }

      const iopsPools = sortedPools(grouped, 'read_iops', false);
      updateBarChart('iopsChart', iopsPools,
        iopsPools.map(p => Math.round(avgMetric(grouped[p], 'read_iops'))),
        iopsPools.map(p => Math.round(avgMetric(grouped[p], 'write_iops'))),
        'IOPS');

      const bwPools = sortedPools(grouped, 'read_bw_kib', false);
      updateBarChart('bwChart', bwPools,
        bwPools.map(p => (avgMetric(grouped[p], 'read_bw_kib') / 1024).toFixed(1)),
        bwPools.map(p => (avgMetric(grouped[p], 'write_bw_kib') / 1024).toFixed(1)),
        'MiB/s');

      const latPools = sortedPools(grouped, 'read_lat_avg_ms', true);
      updateBarChart('latChart', latPools,
        latPools.map(p => avgMetric(grouped[p], 'read_lat_avg_ms').toFixed(2)),
        latPools.map(p => avgMetric(grouped[p], 'write_lat_avg_ms').toFixed(2)),
        'ms');

      const p99Pools = sortedPools(grouped, 'read_lat_p99_ms', true);
      updateBarChart('p99Chart', p99Pools,
        p99Pools.map(p => avgMetric(grouped[p], 'read_lat_p99_ms').toFixed(2)),
        p99Pools.map(p => avgMetric(grouped[p], 'write_lat_p99_ms').toFixed(2)),
        'ms');

      // Update raw data table
      const wrapper = document.getElementById('rawTable');
      if (filtered.length === 0) { wrapper.innerHTML = '<p>No data matching filters</p>'; return; }
      const cols = Object.keys(filtered[0]);
      let html = '<table class="data-table"><thead><tr>' + cols.map(c => '<th>' + c + '</th>').join('') + '</tr></thead><tbody>';
      filtered.slice(0, 500).forEach(r => {
        html += '<tr>' + cols.map(c => '<td>' + (r[c] || '') + '</td>').join('') + '</tr>';
      });
      html += '</tbody></table>';
      wrapper.innerHTML = html;
    }

    updateCharts();
  </script>
</body>
</html>
HTMLEOF

  log_info "HTML dashboard generated: ${output_html}"
}

# ---------------------------------------------------------------------------
# Generate StorageClass ranking HTML report (rank mode)
# ---------------------------------------------------------------------------
generate_ranking_html_report() {
  local csv_file="$1"
  local output_html="$2"
  local run_id="$3"

  log_info "Generating ranking report: ${output_html}"

  local ranking_json
  ranking_json=$(RANKING_CSV_FILE="${csv_file}" POOL_CSI_NAME="${POOL_CSI_NAME}" python3 << 'PYEOF_RANK'
import csv, json, sys, os

csv_file = os.environ['RANKING_CSV_FILE']
pool_csi_name = os.environ.get('POOL_CSI_NAME', 'bench-pool')

# Read CSV and aggregate by (pool, profile, block_size)
# Sum IOPS/BW across fio jobs per test, average latency
groups = {}
first_row = None
with open(csv_file, 'r') as f:
    reader = csv.DictReader(f)
    for row in reader:
        if first_row is None:
            first_row = dict(row)
        pool = row.get('storage_pool', '')
        profile = row.get('fio_profile', '')
        bs = row.get('block_size', '')
        key = f"{pool}|{profile}|{bs}"

        if key not in groups:
            groups[key] = {
                'pool': pool, 'profile': profile, 'block_size': bs,
                'read_iops': 0, 'write_iops': 0,
                'read_bw_kib': 0, 'write_bw_kib': 0,
                'read_lat_avg_ms': 0, 'write_lat_avg_ms': 0,
                'read_lat_p99_ms': 0, 'write_lat_p99_ms': 0,
                'job_count': 0
            }

        g = groups[key]
        g['read_iops'] += float(row.get('read_iops', 0) or 0)
        g['write_iops'] += float(row.get('write_iops', 0) or 0)
        g['read_bw_kib'] += float(row.get('read_bw_kib', 0) or 0)
        g['write_bw_kib'] += float(row.get('write_bw_kib', 0) or 0)
        g['read_lat_avg_ms'] += float(row.get('read_lat_avg_ms', 0) or 0)
        g['write_lat_avg_ms'] += float(row.get('write_lat_avg_ms', 0) or 0)
        g['read_lat_p99_ms'] += float(row.get('read_lat_p99_ms', 0) or 0)
        g['write_lat_p99_ms'] += float(row.get('write_lat_p99_ms', 0) or 0)
        g['job_count'] += 1

# Average latencies across jobs (IOPS/BW are already summed correctly)
for g in groups.values():
    n = g['job_count']
    if n > 0:
        g['read_lat_avg_ms'] /= n
        g['write_lat_avg_ms'] /= n
        g['read_lat_p99_ms'] /= n
        g['write_lat_p99_ms'] /= n

# Build per-pool metrics from the 3 expected workloads
pools = {}
for g in groups.values():
    pool = g['pool']
    if pool not in pools:
        pools[pool] = {}
    wk = f"{g['profile']}/{g['block_size']}"
    pools[pool][wk] = g

# Per-workload rankings
workloads = [
    {
        'id': 'random_iops',
        'title': 'Random 4k IOPS',
        'key': 'random-rw/4k',
        'metric': lambda g: g['read_iops'] + g['write_iops'],
        'display': lambda g: {
            'total_iops': round(g['read_iops'] + g['write_iops']),
            'read_iops': round(g['read_iops']),
            'write_iops': round(g['write_iops']),
        },
        'higher_better': True,
    },
    {
        'id': 'seq_bw',
        'title': 'Sequential 1M Throughput',
        'key': 'sequential-rw/1M',
        'metric': lambda g: (g['read_bw_kib'] + g['write_bw_kib']) / 1024,
        'display': lambda g: {
            'total_mib': round((g['read_bw_kib'] + g['write_bw_kib']) / 1024, 1),
            'read_mib': round(g['read_bw_kib'] / 1024, 1),
            'write_mib': round(g['write_bw_kib'] / 1024, 1),
        },
        'higher_better': True,
    },
    {
        'id': 'mixed_iops',
        'title': 'Mixed 70/30 4k IOPS',
        'key': 'mixed-70-30/4k',
        'metric': lambda g: g['read_iops'] + g['write_iops'],
        'display': lambda g: {
            'total_iops': round(g['read_iops'] + g['write_iops']),
            'read_iops': round(g['read_iops']),
            'write_iops': round(g['write_iops']),
        },
        'higher_better': True,
    },
]

# Build workload rankings
workload_rankings = []
for wl in workloads:
    ranking = []
    for pool_name, wks in pools.items():
        if wl['key'] in wks:
            g = wks[wl['key']]
            val = wl['metric'](g)
            entry = {'pool': pool_name, 'value': round(val, 2)}
            entry.update(wl['display'](g))
            ranking.append(entry)
    ranking.sort(key=lambda x: x['value'], reverse=wl['higher_better'])
    workload_rankings.append({
        'id': wl['id'],
        'title': wl['title'],
        'higher_better': wl['higher_better'],
        'ranking': ranking,
    })

# Latency ranking (from random-rw/4k — most latency-sensitive)
latency_ranking = []
for pool_name, wks in pools.items():
    if 'random-rw/4k' in wks:
        g = wks['random-rw/4k']
        latency_ranking.append({
            'pool': pool_name,
            'read_lat_avg': round(g['read_lat_avg_ms'], 3),
            'write_lat_avg': round(g['write_lat_avg_ms'], 3),
            'read_p99': round(g['read_lat_p99_ms'], 3),
            'write_p99': round(g['write_lat_p99_ms'], 3),
            'avg_p99': round((g['read_lat_p99_ms'] + g['write_lat_p99_ms']) / 2, 3),
        })
latency_ranking.sort(key=lambda x: x['avg_p99'])

# Composite score: normalize each dimension to 0-100 (best=100)
# Weights: random IOPS 40%, sequential BW 30%, mixed IOPS 20%, p99 latency 10%
dimensions = [
    ('random_iops', 'random-rw/4k', lambda g: g['read_iops'] + g['write_iops'], True, 0.40),
    ('seq_bw', 'sequential-rw/1M', lambda g: (g['read_bw_kib'] + g['write_bw_kib']) / 1024, True, 0.30),
    ('mixed_iops', 'mixed-70-30/4k', lambda g: g['read_iops'] + g['write_iops'], True, 0.20),
    ('p99_lat', 'random-rw/4k', lambda g: (g['read_lat_p99_ms'] + g['write_lat_p99_ms']) / 2, False, 0.10),
]

# Collect raw values per pool for each dimension
pool_names = sorted(pools.keys())
raw_scores = {p: {} for p in pool_names}
for dim_id, wk_key, metric_fn, higher_better, weight in dimensions:
    vals = {}
    for p in pool_names:
        if wk_key in pools[p]:
            vals[p] = metric_fn(pools[p][wk_key])
    if not vals:
        continue
    best = max(vals.values()) if higher_better else min(vals.values())
    if best == 0:
        continue
    for p, v in vals.items():
        if higher_better:
            normalized = (v / best) * 100
        else:
            normalized = (best / v) * 100 if v > 0 else 0
        raw_scores[p][dim_id] = round(normalized, 1)

# Adjust p99_lat scores by IOPS ratio to prevent low-throughput pools
# from getting an unfair latency advantage
iops_key = 'random-rw/4k'
iops_fn = lambda g: g['read_iops'] + g['write_iops']
iops_vals = {}
for p in pool_names:
    if iops_key in pools[p]:
        iops_vals[p] = iops_fn(pools[p][iops_key])
if iops_vals:
    best_iops = max(iops_vals.values())
    if best_iops > 0:
        for p in pool_names:
            if 'p99_lat' in raw_scores[p] and p in iops_vals:
                iops_ratio = iops_vals[p] / best_iops
                raw_scores[p]['p99_lat'] = round(raw_scores[p]['p99_lat'] * iops_ratio, 1)

composite = []
for p in pool_names:
    scores = raw_scores[p]
    weighted = 0
    total_weight = 0
    breakdown = {}
    for dim_id, _, _, _, weight in dimensions:
        if dim_id in scores:
            weighted += scores[dim_id] * weight
            total_weight += weight
            breakdown[dim_id] = scores[dim_id]
    final = round(weighted / total_weight, 1) if total_weight > 0 else 0
    composite.append({
        'pool': p,
        'score': final,
        'breakdown': breakdown,
    })
composite.sort(key=lambda x: x['score'], reverse=True)

# Classify pools by type/description for context
import re
def classify_pool(name):
    # Returns (type, description, vsan_equivalent, storage_overhead)
    if re.match(r'^rep(\d+)(-.*)?$', name):
        m = re.match(r'^rep(\d+)(-.*)?$', name)
        n = int(m.group(1))
        suffix = m.group(2) or ''
        variant = ''
        if suffix == '-virt':
            variant = ' (VM-optimized SC with write-back caching features)'
        elif suffix == '-enc':
            variant = ' (encrypted at-rest via LUKS)'
        ftt = n - 1
        vsan = 'RAID-1, FTT=' + str(ftt)
        overhead = str(n) + 'x'
        return ('ODF Replicated ' + str(n) + '-way', 'Ceph RBD block storage with ' + str(n) + 'x replication across failure domains.' + variant, vsan, overhead)
    if re.match(r'^ec-(\d+)-(\d+)', name):
        m = re.match(r'^ec-(\d+)-(\d+)', name)
        k, c = int(m.group(1)), int(m.group(2))
        ratio = '{:.2f}'.format((k + c) / k).rstrip('0').rstrip('.') + 'x'
        if c == 1:
            vsan = 'RAID-5, FTT=1'
        elif c == 2:
            vsan = 'RAID-6, FTT=2'
        else:
            vsan = 'No direct equivalent (FTT=' + str(c) + ')'
        return ('ODF Erasure Coded ' + str(k) + '+' + str(c), 'Ceph RBD with erasure coding (' + str(k) + ' data + ' + str(c) + ' coding chunks). Better space efficiency than replication.', vsan, ratio)
    if re.match(r'^cephfs-rep(\d+)$', name):
        n = int(re.match(r'^cephfs-rep(\d+)$', name).group(1))
        return ('ODF CephFS Replicated ' + str(n) + '-way', 'Ceph Filesystem with ' + str(n) + 'x replicated data pool. Uses file-on-filesystem indirection in KubeVirt.', 'vSAN File Service (RAID-1, FTT=' + str(n-1) + ')', str(n) + 'x (data) + 3x (metadata)')
    if 'vpc-file' in name:
        tier = re.search(r'(\d+)-iops', name)
        tier_str = tier.group(1) + ' IOPS tier' if tier else 'min-IOPS (auto-scaled)'
        return ('IBM Cloud File CSI', 'NFS-based file storage via VPC File CSI driver. ' + tier_str + '.', 'N/A (managed service)', '1x (managed)')
    if 'vpc-block' in name:
        tier = re.search(r'(\d+)-iops', name)
        tier_str = tier.group(1) + ' IOPS tier' if tier else 'auto-scaled IOPS'
        return ('IBM Cloud Block CSI', 'iSCSI-based block storage via VPC Block CSI driver. ' + tier_str + '.', 'N/A (managed service)', '1x (managed)')
    if name == pool_csi_name:
        return ('IBM Cloud Pool CSI', 'Pre-provisioned NFS file share pool via Pool CSI driver. Aggregated IOPS from a shared pool of NFS file shares.', 'N/A (managed service)', '1x (managed)')
    return ('Unknown', name, 'Unknown', 'Unknown')

pool_info = []
for p in pool_names:
    ptype, desc, vsan, overhead = classify_pool(p)
    pool_info.append({'name': p, 'type': ptype, 'description': desc, 'vsan': vsan, 'overhead': overhead})

# Extract test config from CSV data
test_config = {}
if first_row:
    test_config['vm_size'] = first_row.get('vm_size', 'N/A')
    test_config['pvc_size'] = first_row.get('pvc_size', 'N/A')
    test_config['concurrency'] = first_row.get('concurrency', '1')

print(json.dumps({
    'pools': pool_names,
    'workload_rankings': workload_rankings,
    'latency_ranking': latency_ranking,
    'composite': composite,
    'weights': {d[0]: d[4] for d in dimensions},
    'pool_info': pool_info,
    'test_config': test_config,
}))
PYEOF_RANK
  )

  cat > "${output_html}" << 'RANK_HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>StorageClass Ranking</title>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.js"></script>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f5f5; color: #333; }
    .header { background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); color: white; padding: 2rem; }
    .header h1 { font-size: 1.8rem; margin-bottom: 0.3rem; }
    .header .meta { color: #aaa; font-size: 0.85rem; }
    .methodology { background: white; border-radius: 8px; padding: 1.5rem 2rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 1.5rem; line-height: 1.6; font-size: 0.92rem; color: #444; }
    .methodology h2 { font-size: 1.15rem; color: #1a1a2e; margin: 0 0 0.8rem 0; padding: 0; border: none; }
    .methodology p { margin: 0 0 0.7rem 0; }
    .methodology p:last-child { margin-bottom: 0; }
    .methodology .detail-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0.3rem 2rem; margin: 0.5rem 0; font-size: 0.88rem; }
    .methodology .detail-grid dt { color: #777; }
    .methodology .detail-grid dd { font-weight: 500; margin: 0; }
    .container { max-width: 1400px; margin: 0 auto; padding: 1.5rem; }
    .section { margin-bottom: 2rem; }
    .section h2 { font-size: 1.3rem; color: #1a1a2e; margin-bottom: 1rem; padding-bottom: 0.5rem; border-bottom: 2px solid #e0e0e0; }
    .card { background: white; border-radius: 8px; padding: 1.5rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 1rem; }
    table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
    th, td { padding: 0.6rem 0.8rem; text-align: left; border-bottom: 1px solid #eee; }
    th { background: #f8f9fa; font-weight: 600; position: sticky; top: 0; }
    .num { text-align: right; }
    .rank-1 td { background: #fff9e6; }
    .rank-2 td { background: #f5f5f5; }
    .rank-3 td { background: #fdf0ed; }
    .score-bar { display: inline-block; height: 20px; border-radius: 3px; vertical-align: middle; min-width: 2px; }
    .chart-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(500px, 1fr)); gap: 1rem; }
    .collapsible { cursor: pointer; user-select: none; }
    .collapsible::after { content: ' [+]'; font-size: 0.8rem; color: #999; }
    .collapsible.open::after { content: ' [-]'; }
    .collapse-content { display: none; }
    .collapse-content.open { display: block; }
    .weight-badge { display: inline-block; background: #e0e0e0; color: #555; font-size: 0.7rem; padding: 0.15rem 0.4rem; border-radius: 3px; margin-left: 0.5rem; }
  </style>
</head>
<body>
  <div class="header">
    <h1>StorageClass Performance Ranking</h1>
    <div class="meta" id="meta"></div>
  </div>
  <div class="container">
    <div class="methodology" id="methodology"></div>
  </div>
  <div class="container">
    <div class="section">
      <h2 class="collapsible open" onclick="toggleCollapse(this)">About the StorageClasses</h2>
      <div class="collapse-content open">
        <div class="card"><table id="poolInfoTable"></table></div>
      </div>
    </div>
    <div class="section">
      <h2 class="collapsible open" onclick="toggleCollapse(this)">About the Workloads</h2>
      <div class="collapse-content open">
        <div class="card"><table id="workloadInfoTable"></table></div>
      </div>
    </div>
    <div class="section">
      <h2>Overall Composite Ranking</h2>
      <div class="card">
        <table id="compositeTable"></table>
      </div>
      <div class="card"><canvas id="compositeChart" height="80"></canvas></div>
    </div>
    <div class="section">
      <h2>Per-Workload Rankings</h2>
      <div class="chart-grid" id="workloadCharts"></div>
    </div>
    <div class="section">
      <h2>Latency Ranking (Random 4k)</h2>
      <div class="card">
        <table id="latencyTable"></table>
      </div>
    </div>
    <div class="section">
      <h2 class="collapsible" onclick="toggleCollapse(this)">Raw Data</h2>
      <div class="collapse-content">
        <div class="card"><table id="rawTable"></table></div>
      </div>
    </div>
  </div>
  <script>
RANK_HTML_EOF

  # Inject the JSON data and run_id into the HTML
  printf '    const DATA = %s;\n' "${ranking_json}" >> "${output_html}"
  printf '    const RUN_ID = "%s";\n' "${run_id}" >> "${output_html}"

  cat >> "${output_html}" << 'RANK_HTML_EOF2'
    const COLORS = ['#e63946','#457b9d','#2a9d8f','#e9c46a','#f4a261','#264653',
                    '#a8dadc','#d62828','#023e8a','#780000','#6a4c93','#1982c4',
                    '#8ac926','#ff595e','#ffca3a'];
    // Header meta (run ID only)
    document.getElementById('meta').innerHTML = 'Run: ' + RUN_ID;

    // Methodology write-up
    (function() {
      const cfg = DATA.test_config || {};
      const pools = (DATA.pool_info || []).length;
      let html = '<h2>How This Report Works</h2>';
      html += '<p>This report ranks <strong>' + pools + ' StorageClasses</strong> by running the same set of I/O benchmarks against each one under identical conditions, then combining the results into a single composite score. The goal is to answer: <em>which StorageClass gives the best overall performance for VM workloads on this cluster?</em></p>';
      html += '<p><strong>What was tested:</strong> Each StorageClass was provisioned as a ' + (cfg.pvc_size || '150Gi') + ' data disk attached to a ' + (cfg.vm_size || 'small') + ' VM (2 vCPU, 4 GiB RAM). Three fio benchmarks were run on each disk:</p>';
      html += '<ul style="margin:0.3rem 0 0.7rem 1.5rem">';
      html += '<li><strong>Random 4k IOPS</strong> — measures how many small I/O operations per second the storage can handle (IOPS). This is what matters for databases and general VM activity.</li>';
      html += '<li><strong>Sequential 1M Throughput</strong> — measures raw data transfer speed (throughput in MiB/s). This is what matters for backups, large file copies, and data pipelines.</li>';
      html += '<li><strong>Mixed 70/30 4k IOPS</strong> — a realistic blend of 70% reads and 30% writes that simulates everyday application workloads like web servers and file shares.</li>';
      html += '</ul>';
      html += '<p><strong>How scoring works:</strong> Each StorageClass is scored 0-100 on each workload (100 = best performer). These are combined into a weighted composite score:</p>';
      html += '<dl class="detail-grid">';
      html += '<dt>Random 4k IOPS</dt><dd>40% weight — most impactful for general VM performance</dd>';
      html += '<dt>Sequential 1M throughput</dt><dd>30% weight — important for data-heavy workloads</dd>';
      html += '<dt>Mixed 70/30 IOPS</dt><dd>20% weight — reflects real-world application patterns</dd>';
      html += '<dt>p99 latency (lower is better)</dt><dd>10% weight — tail latency from random 4k I/O, weighted by throughput so pools doing fewer IOPS don\'t get an unfair advantage</dd>';
      html += '</dl>';
      html += '<p style="margin-top:0.5rem"><strong>Test parameters:</strong> Each benchmark ran for 60 seconds with a 10-second warmup, using direct I/O (O_DIRECT, bypassing OS cache), I/O depth of 32, and 4 parallel worker threads per job. All tests used a single VM with concurrency of ' + (cfg.concurrency || '1') + '.</p>';
      document.getElementById('methodology').innerHTML = html;
    })();

    // Pool info table
    (function() {
      const info = DATA.pool_info || [];
      if (!info.length) return;
      let html = '<thead><tr><th>StorageClass</th><th>Type</th><th>vSAN Equivalent</th><th>Storage Overhead</th><th>Description</th></tr></thead><tbody>';
      info.forEach(p => {
        html += '<tr><td><strong>' + p.name + '</strong></td><td>' + p.type + '</td><td>' + p.vsan + '</td><td>' + p.overhead + '</td><td>' + p.description + '</td></tr>';
      });
      html += '</tbody>';
      document.getElementById('poolInfoTable').innerHTML = html;
    })();

    // Workload info table
    (function() {
      const workloads = [
        { name: 'Random 4k IOPS', bs: '4k', desc: 'Small-block random I/O — measures IOPS capacity. Typical of databases and VM disk activity.' },
        { name: 'Sequential 1M Throughput', bs: '1M', desc: 'Large-block sequential I/O — measures bandwidth/throughput. Typical of backups and bulk data transfer.' },
        { name: 'Mixed 70/30 4k IOPS', bs: '4k', desc: '70% reads / 30% writes — simulates typical application workloads like web apps and file servers.' },
        { name: 'p99 Tail Latency', bs: '4k', desc: 'Derived from the Random 4k test. The 99th percentile I/O response time — 99% of operations complete faster than this. Lower is better. Measures worst-case storage responsiveness.' },
      ];
      let html = '<thead><tr><th>Workload</th><th>Block Size</th><th>What It Measures</th></tr></thead><tbody>';
      workloads.forEach(w => {
        html += '<tr><td><strong>' + w.name + '</strong></td><td>' + w.bs + '</td><td>' + w.desc + '</td></tr>';
      });
      html += '</tbody>';
      document.getElementById('workloadInfoTable').innerHTML = html;
    })();

    // Composite table
    (function() {
      const comp = DATA.composite;
      let html = '<thead><tr><th>Rank</th><th>StorageClass</th><th class="num">Composite Score</th>';
      html += '<th class="num">Random 4k IOPS<span class="weight-badge">40%</span></th>';
      html += '<th class="num">Sequential 1M BW<span class="weight-badge">30%</span></th>';
      html += '<th class="num">Mixed 70/30 IOPS<span class="weight-badge">20%</span></th>';
      html += '<th class="num">p99 Latency<span class="weight-badge">10%</span></th>';
      html += '</tr></thead><tbody>';
      comp.forEach((c, i) => {
        const cls = i < 3 ? ' class="rank-' + (i+1) + '"' : '';
        html += '<tr' + cls + '><td>#' + (i+1) + '</td>';
        html += '<td><strong>' + c.pool + '</strong></td>';
        html += '<td class="num">' + c.score + '</td>';
        const dims = ['random_iops', 'seq_bw', 'mixed_iops', 'p99_lat'];
        dims.forEach(d => {
          const v = c.breakdown[d] !== undefined ? c.breakdown[d] : '-';
          html += '<td class="num">' + v + '</td>';
        });
        html += '</tr>';
      });
      html += '</tbody>';
      document.getElementById('compositeTable').innerHTML = html;
    })();

    // Composite bar chart
    (function() {
      const comp = DATA.composite;
      new Chart(document.getElementById('compositeChart'), {
        type: 'bar',
        data: {
          labels: comp.map(c => c.pool),
          datasets: [{
            label: 'Composite Score',
            data: comp.map(c => c.score),
            backgroundColor: comp.map((_, i) => COLORS[i % COLORS.length]),
          }]
        },
        options: {
          indexAxis: 'y',
          responsive: true,
          plugins: { legend: { display: false } },
          scales: {
            x: { beginAtZero: true, max: 105, title: { display: true, text: 'Score (best = 100)' } },
          }
        }
      });
    })();

    // Per-workload charts and tables
    (function() {
      const container = document.getElementById('workloadCharts');
      DATA.workload_rankings.forEach((wl, wi) => {
        const card = document.createElement('div');
        card.className = 'card';
        const unit = wl.id === 'seq_bw' ? 'MiB/s' : 'IOPS';
        const valKey = wl.id === 'seq_bw' ? 'total_mib' : 'total_iops';
        const readKey = wl.id === 'seq_bw' ? 'read_mib' : 'read_iops';
        const writeKey = wl.id === 'seq_bw' ? 'write_mib' : 'write_iops';

        let html = '<h3 style="margin-bottom:0.5rem">' + wl.title + '</h3>';
        html += '<table><thead><tr><th>Rank</th><th>StorageClass</th><th class="num">Total ' + unit + '</th>';
        html += '<th class="num">Read</th><th class="num">Write</th></tr></thead><tbody>';
        wl.ranking.forEach((r, i) => {
          const cls = i < 3 ? ' class="rank-' + (i+1) + '"' : '';
          html += '<tr' + cls + '><td>#' + (i+1) + '</td>';
          html += '<td>' + r.pool + '</td>';
          html += '<td class="num"><strong>' + (r[valKey] !== undefined ? r[valKey].toLocaleString() : r.value) + '</strong></td>';
          html += '<td class="num">' + (r[readKey] !== undefined ? r[readKey].toLocaleString() : '-') + '</td>';
          html += '<td class="num">' + (r[writeKey] !== undefined ? r[writeKey].toLocaleString() : '-') + '</td>';
          html += '</tr>';
        });
        html += '</tbody></table>';

        const canvasId = 'wlChart' + wi;
        html += '<canvas id="' + canvasId + '" height="60" style="margin-top:0.5rem"></canvas>';
        card.innerHTML = html;
        container.appendChild(card);

        new Chart(document.getElementById(canvasId), {
          type: 'bar',
          data: {
            labels: wl.ranking.map(r => r.pool),
            datasets: [
              { label: 'Read', data: wl.ranking.map(r => r[readKey] || 0), backgroundColor: '#457b9d' },
              { label: 'Write', data: wl.ranking.map(r => r[writeKey] || 0), backgroundColor: '#e63946' },
            ]
          },
          options: {
            indexAxis: 'y',
            responsive: true,
            plugins: { legend: { position: 'top' } },
            scales: { x: { beginAtZero: true, stacked: true, title: { display: true, text: unit } }, y: { stacked: true } }
          }
        });
      });
    })();

    // Latency table
    (function() {
      const lat = DATA.latency_ranking;
      let html = '<thead><tr><th>Rank</th><th>StorageClass</th><th class="num">Read Avg (ms)</th>';
      html += '<th class="num">Write Avg (ms)</th><th class="num">Read p99 (ms)</th><th class="num">Write p99 (ms)</th>';
      html += '<th class="num">Avg p99 (ms)</th></tr></thead><tbody>';
      lat.forEach((r, i) => {
        const cls = i < 3 ? ' class="rank-' + (i+1) + '"' : '';
        html += '<tr' + cls + '><td>#' + (i+1) + '</td>';
        html += '<td>' + r.pool + '</td>';
        html += '<td class="num">' + r.read_lat_avg + '</td><td class="num">' + r.write_lat_avg + '</td>';
        html += '<td class="num">' + r.read_p99 + '</td><td class="num">' + r.write_p99 + '</td>';
        html += '<td class="num"><strong>' + r.avg_p99 + '</strong></td></tr>';
      });
      html += '</tbody>';
      document.getElementById('latencyTable').innerHTML = html;
    })();

    // Raw data table (from composite + workload data)
    (function() {
      const comp = DATA.composite;
      const wls = DATA.workload_rankings;
      let html = '<thead><tr><th>StorageClass</th><th class="num">Composite</th>';
      wls.forEach(wl => { html += '<th class="num">' + wl.title + '</th>'; });
      html += '<th class="num">Avg p99 (ms)</th></tr></thead><tbody>';
      comp.forEach(c => {
        html += '<tr><td>' + c.pool + '</td><td class="num">' + c.score + '</td>';
        wls.forEach(wl => {
          const entry = wl.ranking.find(r => r.pool === c.pool);
          html += '<td class="num">' + (entry ? entry.value : '-') + '</td>';
        });
        const latEntry = DATA.latency_ranking.find(r => r.pool === c.pool);
        html += '<td class="num">' + (latEntry ? latEntry.avg_p99 : '-') + '</td>';
        html += '</tr>';
      });
      html += '</tbody>';
      document.getElementById('rawTable').innerHTML = html;
    })();

    function toggleCollapse(el) {
      el.classList.toggle('open');
      el.nextElementSibling.classList.toggle('open');
    }
  </script>
</body>
</html>
RANK_HTML_EOF2

  log_info "Ranking report generated: ${output_html}"
}
