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
**Zones:** ${CLUSTER_ZONES} (multi-AZ=${CLUSTER_MULTI_AZ})
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
      Run: ${RUN_ID} | ${CLUSTER_DESCRIPTION} | Zones: ${CLUSTER_ZONES} (multi-AZ=${CLUSTER_MULTI_AZ}) | ODF + IBM Cloud File/Block
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
  ranking_json=$(RANKING_CSV_FILE="${csv_file}" POOL_CSI_NAME="${POOL_CSI_NAME}" POOL_CSI_PROFILE="${POOL_CSI_PROFILE}" POOL_CSI_IOPS="${POOL_CSI_IOPS}" POOL_CSI_SHARE_SIZE="${POOL_CSI_SHARE_SIZE}" python3 << 'PYEOF_RANK'
import csv, json, sys, os

csv_file = os.environ['RANKING_CSV_FILE']
pool_csi_name = os.environ.get('POOL_CSI_NAME', 'bench-pool')
pool_csi_profile = os.environ.get('POOL_CSI_PROFILE', 'dp2')
pool_csi_iops = os.environ.get('POOL_CSI_IOPS', '40000')
pool_csi_share_size = os.environ.get('POOL_CSI_SHARE_SIZE', '4000Gi')

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
        return ('IBM Cloud Pool CSI', 'Pre-provisioned NFS file share pool via Pool CSI driver (' + pool_csi_share_size + ' at ' + pool_csi_iops + ' IOPS, ' + pool_csi_profile + ' profile).', 'N/A (managed service)', '1x (managed)')
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
  printf '    const CLUSTER_DESC = "%s";\n' "${CLUSTER_DESCRIPTION}" >> "${output_html}"
  printf '    const CLUSTER_ZONES_STR = "%s (multi-AZ=%s)";\n' "${CLUSTER_ZONES}" "${CLUSTER_MULTI_AZ}" >> "${output_html}"

  cat >> "${output_html}" << 'RANK_HTML_EOF2'
    const COLORS = ['#e63946','#457b9d','#2a9d8f','#e9c46a','#f4a261','#264653',
                    '#a8dadc','#d62828','#023e8a','#780000','#6a4c93','#1982c4',
                    '#8ac926','#ff595e','#ffca3a'];
    // Header meta (run ID only)
    document.getElementById('meta').textContent = 'Run: ' + RUN_ID + ' | ' + CLUSTER_DESC + ' | Zones: ' + CLUSTER_ZONES_STR;

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

# ---------------------------------------------------------------------------
# Generate scale-test auto-ramp HTML report
# ---------------------------------------------------------------------------
generate_scale_test_report() {
  local ramp_csv="$1"
  local ramp_summary="$2"
  local output_html="$3"

  log_info "Generating scale-test report: ${output_html}"

  (RAMP_CSV="${ramp_csv}" RAMP_SUMMARY="${ramp_summary}" \
  CLUSTER_DESC="${CLUSTER_DESCRIPTION}" \
  python3 << 'PYEOF_SCALE'
import csv, json, sys, os

csv_file = os.environ['RAMP_CSV']
summary_file = os.environ['RAMP_SUMMARY']
cluster_desc = os.environ.get('CLUSTER_DESC', '')

with open(summary_file, 'r') as f:
    summary = json.load(f)

rows = []
with open(csv_file, 'r') as f:
    reader = csv.DictReader(f)
    for row in reader:
        rows.append(row)

# Sort by vm_count for chart ordering
rows.sort(key=lambda r: int(r['vm_count']))

pool = summary['pool']
sc = summary['storage_class']
rate = summary['rate_iops']
sla = summary['latency_sla_ms']
capacity = summary['capacity_vms']
total_iops = summary['total_iops_at_capacity']
cap_p99 = summary['p99_at_capacity_ms']
breach_vms = summary['breach_vms']
breach_p99 = summary['p99_at_breach_ms']
run_id = summary['run_id']
timestamp = summary['timestamp']
resource_ceiling = summary.get('resource_ceiling', False)

# Chart data
vm_counts = [int(r['vm_count']) for r in rows]
total_iops_series = [float(r['total_read_iops']) + float(r['total_write_iops']) for r in rows]
p99_series = [float(r['max_p99_ms']) for r in rows]
pass_fail = [r['sla_pass'] for r in rows]
point_colors = ['#198038' if p == 'true' else '#da1e28' for p in pass_fail]

# Capacity description
if capacity == 0:
    cap_text = f"Pool <b>{pool}</b> cannot meet p99 &lt; {sla}ms SLA at {rate} IOPS/VM (single VM breached)"
elif breach_vms == 0:
    cap_text = f"Pool <b>{pool}</b> sustains <b>{capacity} VMs</b> at {rate} IOPS/VM without SLA breach (not saturated)"
else:
    cap_text = f"Pool <b>{pool}</b> supports <b>{capacity} VMs</b> at {rate} IOPS/VM ({total_iops:,.0f} aggregate IOPS) before p99 exceeds {sla}ms"

if resource_ceiling:
    cap_text += " <em>(resource ceiling hit)</em>"

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Scale Test: {pool} @ {rate} IOPS/VM</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation@3"></script>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 1100px; margin: 0 auto; padding: 20px; background: #f4f4f4; }}
  h1 {{ color: #161616; }}
  .meta {{ color: #525252; font-size: 0.9em; margin-bottom: 20px; }}
  .capacity-box {{ background: #defbe6; border-left: 4px solid #198038; padding: 16px 20px; margin: 20px 0; font-size: 1.1em; border-radius: 4px; }}
  .capacity-box.warn {{ background: #fff8e1; border-left-color: #f1c21b; }}
  .capacity-box.fail {{ background: #fff1f1; border-left-color: #da1e28; }}
  .chart-container {{ background: white; padding: 20px; border-radius: 8px; margin: 20px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
  table {{ width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
  th {{ background: #161616; color: white; padding: 10px 12px; text-align: right; font-size: 0.85em; }}
  th:first-child {{ text-align: left; }}
  td {{ padding: 8px 12px; text-align: right; border-bottom: 1px solid #e0e0e0; font-size: 0.9em; }}
  td:first-child {{ text-align: left; }}
  tr:hover {{ background: #f4f4f4; }}
  .pass {{ color: #198038; font-weight: 600; }}
  .fail {{ color: #da1e28; font-weight: 600; }}
  .footer {{ color: #525252; font-size: 0.8em; margin-top: 30px; }}
</style>
</head>
<body>
<h1>Scale Test: {pool}</h1>
<div class="meta">
  <b>Storage Class:</b> {sc} &nbsp;|&nbsp;
  <b>Rate:</b> {rate} IOPS/VM &nbsp;|&nbsp;
  <b>SLA:</b> p99 &lt; {sla}ms<br>
  <b>Cluster:</b> {cluster_desc}<br>
  <b>Run:</b> {run_id} &nbsp;|&nbsp; <b>Date:</b> {timestamp}
</div>

<div class="capacity-box {'fail' if capacity == 0 else 'warn' if breach_vms == 0 else ''}">
  {cap_text}
</div>

<div class="chart-container">
  <canvas id="rampChart" height="100"></canvas>
</div>

<h2>Ramp Data</h2>
<table>
<tr>
  <th>VMs</th><th>Target IOPS</th><th>Read IOPS</th><th>Write IOPS</th>
  <th>BW (MB/s)</th><th>p50 (ms)</th><th>p95 (ms)</th><th>p99 (ms)</th><th>SLA</th>
</tr>
"""

for r in rows:
    sla_class = 'pass' if r['sla_pass'] == 'true' else 'fail'
    sla_label = 'PASS' if r['sla_pass'] == 'true' else 'FAIL'
    html += f"""<tr>
  <td>{r['vm_count']}</td><td>{r['rate_iops']}</td>
  <td>{float(r['total_read_iops']):,.0f}</td><td>{float(r['total_write_iops']):,.0f}</td>
  <td>{float(r['total_bw_mbs']):,.1f}</td><td>{r['avg_p50_ms']}</td>
  <td>{r['avg_p95_ms']}</td><td>{r['max_p99_ms']}</td>
  <td class="{sla_class}">{sla_label}</td>
</tr>
"""

html += f"""</table>

<div class="footer">
  CSV: {csv_file} &nbsp;|&nbsp; Summary: {summary_file}
</div>

<script>
const ctx = document.getElementById('rampChart').getContext('2d');
new Chart(ctx, {{
  type: 'line',
  data: {{
    labels: {json.dumps(vm_counts)},
    datasets: [
      {{
        label: 'Aggregate IOPS',
        data: {json.dumps(total_iops_series)},
        borderColor: '#0f62fe',
        backgroundColor: 'rgba(15, 98, 254, 0.1)',
        yAxisID: 'y-iops',
        tension: 0.2,
        pointBackgroundColor: {json.dumps(point_colors)},
        pointRadius: 6,
        pointHoverRadius: 8
      }},
      {{
        label: 'p99 Latency (ms)',
        data: {json.dumps(p99_series)},
        borderColor: '#da1e28',
        borderDash: [5, 5],
        yAxisID: 'y-lat',
        tension: 0.2,
        pointBackgroundColor: {json.dumps(point_colors)},
        pointRadius: 6,
        pointHoverRadius: 8
      }}
    ]
  }},
  options: {{
    responsive: true,
    interaction: {{ mode: 'index', intersect: false }},
    scales: {{
      x: {{ title: {{ display: true, text: 'VM Count' }} }},
      'y-iops': {{
        type: 'linear', position: 'left',
        title: {{ display: true, text: 'Aggregate IOPS' }},
        beginAtZero: true
      }},
      'y-lat': {{
        type: 'linear', position: 'right',
        title: {{ display: true, text: 'p99 Latency (ms)' }},
        beginAtZero: true,
        grid: {{ drawOnChartArea: false }}
      }}
    }},
    plugins: {{
      annotation: {{
        annotations: {{
          slaLine: {{
            type: 'line', yMin: {sla}, yMax: {sla},
            yScaleID: 'y-lat',
            borderColor: '#da1e28', borderWidth: 2, borderDash: [10, 5],
            label: {{ content: 'SLA: {sla}ms', display: true, position: 'start' }}
          }},
          capacityLine: {{
            type: 'line', xMin: {json.dumps(str(capacity)) if capacity > 0 else 'null'}, xMax: {json.dumps(str(capacity)) if capacity > 0 else 'null'},
            display: {'true' if capacity > 0 else 'false'},
            borderColor: '#198038', borderWidth: 2, borderDash: [10, 5],
            label: {{ content: '{capacity} VMs', display: {'true' if capacity > 0 else 'false'}, position: 'start', backgroundColor: '#198038' }}
          }}
        }}
      }}
    }}
  }}
}});
</script>
</body>
</html>"""

print(html)
PYEOF_SCALE
) > "${output_html}"

  log_info "Scale-test report generated: ${output_html}"
}

# ---------------------------------------------------------------------------
# generate_scale_test_comparison_report
#   Overlay N scale-test ramps (one or more ROKS pools + one vSAN pool) on a
#   single dual-axis Chart.js chart. Emits a capacity scorecard, a parameter-
#   comparability banner, and per-ramp step tables.
#
#   ramps_spec  newline-separated "label|ramp_csv|ramp_summary" lines (ROKS)
#   vsan_csv    path to vSAN ramp.csv (from sister project)
#   vsan_summary path to vSAN ramp-summary.json
#   output_html path to write the HTML report
#
#   Tolerates summary JSON missing 'storage_class' / 'cluster_description'
#   (sister-project summaries do not include them).
# ---------------------------------------------------------------------------
generate_scale_test_comparison_report() {
  local ramps_spec="$1"
  local vsan_csv="$2"
  local vsan_summary="$3"
  local output_html="$4"

  log_info "Generating scale-test comparison report: ${output_html}"

  (RAMPS_SPEC="${ramps_spec}" \
   VSAN_CSV="${vsan_csv}" VSAN_SUMMARY="${vsan_summary}" \
   CLUSTER_DESC="${CLUSTER_DESCRIPTION:-}" \
   python3 << 'PYEOF_SCALE_COMPARE'
import csv, json, os, datetime

ramps_spec = os.environ['RAMPS_SPEC'].strip()
vsan_csv = os.environ['VSAN_CSV']
vsan_summary_path = os.environ['VSAN_SUMMARY']
cluster_desc = os.environ.get('CLUSTER_DESC', '')

def load_ramp(label, csv_path, summary_path, source):
    with open(summary_path, 'r') as f:
        summary = json.load(f)
    rows = []
    with open(csv_path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    rows.sort(key=lambda r: int(r['vm_count']))
    return {
        'label': label,
        'source': source,
        'pool': summary.get('pool', label),
        'storage_class': summary.get('storage_class', ''),
        'cluster_description': summary.get('cluster_description', ''),
        'rate_iops': int(summary.get('rate_iops', 0) or 0),
        'latency_sla_ms': float(summary.get('latency_sla_ms', 0) or 0),
        'capacity_vms': int(summary.get('capacity_vms', 0) or 0),
        'total_iops_at_capacity': int(summary.get('total_iops_at_capacity', 0) or 0),
        'p99_at_capacity_ms': float(summary.get('p99_at_capacity_ms', 0) or 0),
        'breach_vms': int(summary.get('breach_vms', 0) or 0),
        'p99_at_breach_ms': float(summary.get('p99_at_breach_ms', 0) or 0),
        'resource_ceiling': bool(summary.get('resource_ceiling', False)),
        'run_id': summary.get('run_id', ''),
        'timestamp': summary.get('timestamp', ''),
        'rows': rows,
    }

ramps = []
for line in ramps_spec.splitlines():
    line = line.strip()
    if not line:
        continue
    parts = line.split('|', 2)
    if len(parts) != 3:
        continue
    label, csv_path, summary_path = parts
    ramps.append(load_ramp(label, csv_path, summary_path, 'ROKS'))

vsan_summary_obj = json.load(open(vsan_summary_path))
vsan_label = 'vSAN ' + vsan_summary_obj.get('pool', 'vsan-pool')
ramps.append(load_ramp(vsan_label, vsan_csv, vsan_summary_path, 'vSAN'))

# Comparability check
rates = sorted({r['rate_iops'] for r in ramps})
slas = sorted({r['latency_sla_ms'] for r in ramps})
rates_differ = len(rates) > 1
slas_differ = len(slas) > 1
params_mismatch = rates_differ or slas_differ

# Per-pool single-hue palette: IOPS solid, p99 dashed, same color so a pool reads as one family.
roks_palette = [
    '#0f62fe',  # blue
    '#007d79',  # teal
    '#6929c4',  # purple
    '#1192e8',  # cyan
]
vsan_color = '#161616'  # near-black, clearly distinct from ROKS hues

# Build Chart.js datasets (one IOPS + one p99 per ramp)
datasets = []
roks_idx = 0
ramp_colors = {}  # pool -> hex (used later by capacity annotations and per-ramp summary)
for r in ramps:
    if r['source'] == 'vSAN':
        color = vsan_color
    else:
        color = roks_palette[roks_idx % len(roks_palette)]
        roks_idx += 1
    ramp_colors[r['pool']] = color
    iops_points = [{'x': int(row['vm_count']),
                    'y': float(row['total_read_iops']) + float(row['total_write_iops'])}
                   for row in r['rows']]
    p99_points = [{'x': int(row['vm_count']),
                   'y': float(row['max_p99_ms'])}
                  for row in r['rows']]
    point_colors = ['#198038' if row['sla_pass'] == 'true' else '#da1e28' for row in r['rows']]
    datasets.append({
        'label': f"{r['label']} — Aggregate IOPS",
        'data': iops_points,
        'borderColor': color,
        'backgroundColor': color + '20',
        'yAxisID': 'y-iops',
        'tension': 0.2,
        'pointBackgroundColor': point_colors,
        'pointBorderColor': color,
        'pointRadius': 5,
        'pointHoverRadius': 7,
        'borderWidth': 2.5,
    })
    datasets.append({
        'label': f"{r['label']} — Write p99 (ms)",
        'data': p99_points,
        'borderColor': color,
        'borderDash': [6, 4],
        'yAxisID': 'y-lat',
        'tension': 0.2,
        'pointBackgroundColor': point_colors,
        'pointBorderColor': color,
        'pointRadius': 5,
        'pointHoverRadius': 7,
        'borderWidth': 2,
    })

# Shared SLA annotation only when all SLAs agree
sla_annotation = ''
if not slas_differ and slas:
    sla = slas[0]
    sla_annotation = (
        "slaLine: { type: 'line', yMin: %s, yMax: %s, yScaleID: 'y-lat', "
        "borderColor: '#da1e28', borderWidth: 2, borderDash: [10, 5], "
        "label: { content: 'SLA: %sms', display: true, position: 'start' } },"
    ) % (sla, sla, sla)

# Capacity verticals: one per ramp (drawn only when capacity > 0)
cap_annotations = []
for r in ramps:
    c = ramp_colors[r['pool']]
    if r['capacity_vms'] > 0:
        cap_annotations.append(
            "cap_%s: { type: 'line', xMin: %s, xMax: %s, "
            "borderColor: '%s', borderWidth: 1.5, borderDash: [4, 4], "
            "label: { content: '%s cap: %s VMs', display: true, position: 'start', "
            "backgroundColor: '%s', color: 'white', font: { size: 10 } } }" % (
                r['pool'].replace('-', '_'),
                r['capacity_vms'], r['capacity_vms'], c,
                r['label'].replace("'", "\\'"), r['capacity_vms'], c,
            )
        )

annotations_block = sla_annotation + ',\n          '.join(cap_annotations)

# Comparability banner
if params_mismatch:
    banner_class = 'warn'
    banner_lines = []
    if rates_differ:
        banner_lines.append(f"Rate caps differ across ramps: {', '.join(f'{r} IOPS/VM' for r in rates)}.")
    if slas_differ:
        banner_lines.append(f"SLA thresholds differ across ramps: {', '.join(f'{s} ms' for s in slas)}.")
    banner_lines.append(
        "Direct comparison of capacity and aggregate IOPS should account for the difference in offered load and breach threshold."
    )
    banner_html = '<br>'.join(f'<b>{line}</b>' if i == 0 else line for i, line in enumerate(banner_lines))
else:
    banner_class = 'ok'
    banner_html = (
        f"All ramps tested at the same offered load (<b>{rates[0]} IOPS/VM</b>) "
        f"and the same SLA threshold (<b>p99 &lt; {slas[0]}ms</b>). "
        "Comparison is apples-to-apples."
    )

# Scorecard row HTML
def fmt_int(n):
    return f"{int(n):,}"

scorecard_rows = []
for r in ramps:
    res_ceil = 'yes' if r['resource_ceiling'] else 'no'
    cap_cell = fmt_int(r['capacity_vms']) if r['capacity_vms'] else '<span class="muted">none</span>'
    cap_iops_cell = fmt_int(r['total_iops_at_capacity']) if r['capacity_vms'] else '<span class="muted">—</span>'
    cap_p99_cell = f"{r['p99_at_capacity_ms']:.2f}" if r['capacity_vms'] else '<span class="muted">—</span>'
    breach_cell = fmt_int(r['breach_vms']) if r['breach_vms'] else '<span class="muted">none</span>'
    breach_p99_cell = f"{r['p99_at_breach_ms']:.2f}" if r['breach_vms'] else '<span class="muted">—</span>'
    src_badge = '<span class="src vsan">vSAN</span>' if r['source'] == 'vSAN' else '<span class="src roks">ROKS</span>'
    scorecard_rows.append(
        f"<tr><td>{src_badge}</td><td><b>{r['pool']}</b></td>"
        f"<td>{r['rate_iops']}</td><td>{r['latency_sla_ms']:g}</td>"
        f"<td>{cap_cell}</td><td>{cap_iops_cell}</td><td>{cap_p99_cell}</td>"
        f"<td>{breach_cell}</td><td>{breach_p99_cell}</td><td>{res_ceil}</td></tr>"
    )

# Per-ramp step tables
step_tables = []
for r in ramps:
    body_rows = []
    for row in r['rows']:
        sla_class = 'pass' if row['sla_pass'] == 'true' else 'fail'
        sla_label = 'PASS' if row['sla_pass'] == 'true' else 'FAIL'
        body_rows.append(
            f"<tr><td>{row['vm_count']}</td><td>{row['rate_iops']}</td>"
            f"<td>{float(row['total_read_iops']):,.0f}</td>"
            f"<td>{float(row['total_write_iops']):,.0f}</td>"
            f"<td>{float(row['total_bw_mbs']):,.1f}</td>"
            f"<td>{row['avg_p50_ms']}</td><td>{row['avg_p95_ms']}</td>"
            f"<td>{row['max_p99_ms']}</td>"
            f"<td class=\"{sla_class}\">{sla_label}</td></tr>"
        )
    meta_bits = []
    if r['storage_class']:
        meta_bits.append(f"SC: <code>{r['storage_class']}</code>")
    meta_bits.append(f"Rate: {r['rate_iops']} IOPS/VM")
    meta_bits.append(f"SLA: p99 &lt; {r['latency_sla_ms']:g}ms")
    if r['run_id']:
        meta_bits.append(f"Run: <code>{r['run_id']}</code>")
    if r['timestamp']:
        meta_bits.append(r['timestamp'])
    step_tables.append(
        f"<details><summary><b>{r['label']}</b> &nbsp;—&nbsp; {' &nbsp;|&nbsp; '.join(meta_bits)}</summary>"
        f"<table><tr><th>VMs</th><th>Target IOPS</th><th>Read IOPS</th><th>Write IOPS</th>"
        f"<th>BW (MB/s)</th><th>p50 (ms)</th><th>p95 (ms)</th><th>p99 (ms)</th><th>SLA</th></tr>"
        + ''.join(body_rows) + "</table></details>"
    )

generated_at = datetime.datetime.now().isoformat(timespec='seconds')

# Intro descriptors
n_ramps = len(ramps)
n_sources = len({r['source'] for r in ramps})
pool_list_html = ', '.join(
    f"<span class=\"src {r['source'].lower()}\">{r['source']}</span>&nbsp;<b>{r['pool']}</b>"
    for r in ramps
)
if rates_differ:
    rate_phrase = 'its ramp\'s configured rate (see the scorecard)'
else:
    rate_phrase = f'<b>{rates[0]} IOPS</b>'
if slas_differ:
    sla_phrase = 'each configuration\'s own threshold (see the scorecard)'
else:
    sla_phrase = f'<b>{slas[0]:g} ms</b>'

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Scale Test Comparison: ROKS vs vSAN</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation@3"></script>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; background: #f4f4f4; color: #161616; }}
  h1 {{ color: #161616; margin-bottom: 4px; }}
  h2 {{ color: #161616; margin-top: 32px; }}
  .meta {{ color: #525252; font-size: 0.9em; margin-bottom: 20px; }}
  .banner {{ padding: 14px 18px; margin: 18px 0; border-radius: 4px; font-size: 0.95em; line-height: 1.5; }}
  .banner.ok {{ background: #defbe6; border-left: 4px solid #198038; }}
  .banner.warn {{ background: #fff8e1; border-left: 4px solid #f1c21b; }}
  .intro {{ background: #edf5ff; border-left: 4px solid #0f62fe; padding: 14px 18px; margin: 18px 0; border-radius: 4px; line-height: 1.55; }}
  .intro p {{ margin: 0 0 10px 0; }}
  .intro p:last-child {{ margin-bottom: 0; }}
  .howto, .methodology {{ background: white; padding: 12px 18px; border-radius: 8px; margin: 14px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }}
  .howto > summary, .methodology > summary {{ cursor: pointer; font-size: 1em; padding: 4px 0; }}
  .howto[open] > summary, .methodology[open] > summary {{ margin-bottom: 10px; }}
  .howto ol, .howto ul, .methodology ol, .methodology ul {{ margin: 8px 0 8px 22px; padding: 0; line-height: 1.55; }}
  .howto li, .methodology li {{ margin-bottom: 6px; }}
  .methodology h3 {{ margin: 14px 0 4px 0; font-size: 1em; color: #161616; }}
  .methodology p {{ margin: 4px 0 8px 0; line-height: 1.55; }}
  .chart-container {{ background: white; padding: 20px; border-radius: 8px; margin: 20px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
  table {{ width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-top: 8px; }}
  th {{ background: #161616; color: white; padding: 10px 12px; text-align: right; font-size: 0.85em; }}
  th:first-child, th:nth-child(2) {{ text-align: left; }}
  td {{ padding: 8px 12px; text-align: right; border-bottom: 1px solid #e0e0e0; font-size: 0.9em; }}
  td:first-child, td:nth-child(2) {{ text-align: left; }}
  tr:hover {{ background: #f4f4f4; }}
  .pass {{ color: #198038; font-weight: 600; }}
  .fail {{ color: #da1e28; font-weight: 600; }}
  .muted {{ color: #8d8d8d; }}
  .src {{ display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 0.75em; font-weight: 600; color: white; }}
  .src.roks {{ background: #0f62fe; }}
  .src.vsan {{ background: #525252; }}
  details {{ background: white; padding: 12px 16px; border-radius: 8px; margin: 10px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }}
  details > summary {{ cursor: pointer; padding: 4px 0; font-size: 0.95em; }}
  details[open] > summary {{ margin-bottom: 8px; }}
  details table {{ box-shadow: none; }}
  code {{ background: #f4f4f4; padding: 1px 5px; border-radius: 3px; font-size: 0.9em; }}
  .footer {{ color: #525252; font-size: 0.8em; margin-top: 30px; }}
</style>
</head>
<body>
<h1>Scale Test Comparison: ROKS vs vSAN</h1>
<div class="meta">
  <b>ROKS cluster:</b> {cluster_desc or 'n/a'}<br>
  <b>Generated:</b> {generated_at}
</div>

<div class="intro">
  <p><b>What this report shows.</b> How many virtual machines each storage configuration can host before its writes get too slow.</p>
  <p>Each VM runs an identical workload — a steady stream of small random reads and writes, with each VM driving {rate_phrase}. We add more VMs in steps; at each step we measure write latency across every VM and check the <b>p99 write latency</b>: the time taken by the <em>slowest 1 %</em> of writes (a number much more sensitive to real-world slowdowns than an average, because the slow tail is what users actually notice).</p>
  <p>The <b>capacity ceiling</b> is the largest VM count where that p99 still stays under {sla_phrase}. Push past it and some writes start taking many milliseconds longer than they should — which in production shows up as application slowdowns and timeouts.</p>
  <p><b>{n_ramps} configurations across {n_sources} platforms:</b> {pool_list_html}.</p>
</div>

<div class="banner {banner_class}">{banner_html}</div>

<details class="howto" open>
  <summary><b>How to read this report</b></summary>
  <ol>
    <li><b>Comparability banner</b> (above) — green when all ramps used the same offered load and SLA threshold (apples-to-apples); amber when any disagree (numbers may not be directly comparable).</li>
    <li><b>Capacity scorecard</b> — one row per tier. <em>Capacity</em> is the last VM count that stayed under SLA. <em>Breach</em> is the first VM count that didn't. <em>Resource ceiling</em> = yes means the ramp stopped because the platform ran out of room to schedule more VMs, not because storage saturated.</li>
    <li><b>Ramp overlay chart</b> — each pool has one color. <b>Solid</b> lines are aggregate IOPS (left axis); <b>dashed</b> lines are write-p99 latency (right axis). Dots are <span style="color:#198038;font-weight:600">green</span> when the step passed SLA, <span style="color:#da1e28;font-weight:600">red</span> when it failed. The horizontal red dashed line marks the SLA threshold (drawn only when all ramps share one); thin vertical dashed lines mark each pool's capacity ceiling.</li>
    <li><b>Per-ramp data</b> — full step-by-step data for each ramp, collapsed by default. Click to expand.</li>
  </ol>
</details>

<details class="methodology">
  <summary><b>Methodology</b></summary>
  <h3>Workload</h3>
  <p><code>mixed-70-30-rated.fio</code> — 70 % random read / 30 % random write, 4 KiB blocks, queue depth 32, one fio job per VM, rate-capped to the offered IOPS shown in the scorecard. Each VM runs against a 10 GiB test file on its own dedicated PVC/VMDK.</p>
  <h3>Ramp strategy</h3>
  <ul>
    <li><b>Phase 1 (doubling):</b> 1 &rarr; 2 &rarr; 4 &rarr; 8 &rarr; ... VMs until write-p99 breaches the SLA, or the platform runs out of capacity to schedule more VMs.</li>
    <li><b>Phase 2 (backfill):</b> linear steps between the last passing and first failing VM counts to pin the capacity ceiling precisely.</li>
  </ul>
  <h3>Per-step methodology fixes</h3>
  <ul>
    <li><b>Prefill:</b> every VM sequentially writes the full test file before measurement starts, allocating all RBD / VMDK / NFS-share objects up front. Without this, first-write allocation cost (4 MiB object allocation on thin RBD; block allocation on vSAN) gets counted as steady-state IO latency.</li>
    <li><b>Wall-clock sync barrier:</b> all VMs in a step wait on a shared epoch before launching their measurement window. Eliminates first-mover penalty where an early-starting VM measures alone for tens of seconds during other VMs' boot/prefill.</li>
  </ul>
  <p>Both ROKS and vSAN use the same workload, ramp strategy, and methodology fixes. The only intentional difference is the storage backend under test.</p>
</details>

<h2>Capacity scorecard</h2>
<table>
<tr>
  <th>Source</th><th>Pool</th><th>Rate (IOPS/VM)</th><th>SLA (ms)</th>
  <th>Capacity (VMs)</th><th>IOPS @ Cap</th><th>p99 @ Cap (ms)</th>
  <th>Breach (VMs)</th><th>p99 @ Breach (ms)</th><th>Resource ceiling</th>
</tr>
{''.join(scorecard_rows)}
</table>

<h2>Ramp overlay</h2>
<div class="chart-container">
  <canvas id="rampChart" height="110"></canvas>
</div>

<h2>Per-ramp data</h2>
{''.join(step_tables)}

<div class="footer">
  vSAN reference: <code>{vsan_csv}</code> / <code>{vsan_summary_path}</code>
</div>

<script>
const ctx = document.getElementById('rampChart').getContext('2d');
new Chart(ctx, {{
  type: 'line',
  data: {{
    datasets: {json.dumps(datasets)}
  }},
  options: {{
    responsive: true,
    parsing: false,
    interaction: {{ mode: 'nearest', intersect: false }},
    scales: {{
      x: {{ type: 'linear', title: {{ display: true, text: 'VM Count' }}, beginAtZero: true }},
      'y-iops': {{
        type: 'linear', position: 'left',
        title: {{ display: true, text: 'Aggregate IOPS' }},
        beginAtZero: true
      }},
      'y-lat': {{
        type: 'linear', position: 'right',
        title: {{ display: true, text: 'p99 Latency (ms)' }},
        beginAtZero: true,
        grid: {{ drawOnChartArea: false }}
      }}
    }},
    plugins: {{
      legend: {{ position: 'top' }},
      annotation: {{
        annotations: {{
          {annotations_block}
        }}
      }}
    }}
  }}
}});
</script>
</body>
</html>"""

print(html)
PYEOF_SCALE_COMPARE
  ) > "${output_html}"

  log_info "Scale-test comparison report generated: ${output_html}"
}

# ---------------------------------------------------------------------------
# aggregate_qd_step <raw_dir> <vm_count> <qd> <rate_iops> <sla_ms>
#   Reads all *-fio.json files in raw_dir and emits one CSV row matching the
#   qd.csv schema. Skips empty/malformed JSON; if all VMs failed, emits a NaN
#   row with sla_pass=false.
# ---------------------------------------------------------------------------
aggregate_qd_step() {
  local raw_dir="$1" vm_count="$2" qd="$3" rate="$4" sla="$5"

  python3 - "${raw_dir}" "${vm_count}" "${qd}" "${rate}" "${sla}" <<'PYEOF'
import json, os, sys, glob

raw_dir, vm_count, qd, rate, sla = sys.argv[1:]
vm_count, qd, rate = int(vm_count), int(qd), int(rate)
sla = float(sla)

read_iops_sum = write_iops_sum = bw_mbs_sum = 0.0
p50_r=[]; p95_r=[]; p99_r=[]
p50_w=[]; p95_w=[]; p99_w=[]
ok = 0
for path in glob.glob(os.path.join(raw_dir, "*-fio.json")):
    try:
        with open(path) as f:
            d = json.load(f)
        jobs = d.get("jobs") or []
        if not jobs: continue
        j = jobs[0]
        r = j.get("read", {})
        w = j.get("write", {})
        read_iops_sum  += r.get("iops", 0.0)
        write_iops_sum += w.get("iops", 0.0)
        bw_mbs_sum += (r.get("bw", 0.0) + w.get("bw", 0.0)) / 1024.0
        rcl = r.get("clat_ns", {}).get("percentile", {})
        wcl = w.get("clat_ns", {}).get("percentile", {})
        if rcl:
            p50_r.append(rcl.get("50.000000", 0) / 1e6)
            p95_r.append(rcl.get("95.000000", 0) / 1e6)
            p99_r.append(rcl.get("99.000000", 0) / 1e6)
        if wcl:
            p50_w.append(wcl.get("50.000000", 0) / 1e6)
            p95_w.append(wcl.get("95.000000", 0) / 1e6)
            p99_w.append(wcl.get("99.000000", 0) / 1e6)
        ok += 1
    except Exception:
        continue

def avg(xs): return sum(xs)/len(xs) if xs else float("nan")
def mx(xs):  return max(xs) if xs else float("nan")

if ok == 0:
    print(f"{vm_count},{qd},{rate},nan,nan,nan,nan,nan,nan,nan,nan,nan,false")
    sys.exit(0)

avg_p50_r = avg(p50_r); avg_p95_r = avg(p95_r); max_p99_r = mx(p99_r)
avg_p50_w = avg(p50_w); avg_p95_w = avg(p95_w); max_p99_w = mx(p99_w)
sla_pass = "true" if (max_p99_w == max_p99_w and max_p99_w < sla) else "false"
fail_pct = (vm_count - ok) / vm_count * 100
if fail_pct > 10:
    sla_pass = "false"

print(f"{vm_count},{qd},{rate},"
      f"{read_iops_sum:.0f},{write_iops_sum:.0f},{bw_mbs_sum:.1f},"
      f"{avg_p50_r:.3f},{avg_p95_r:.3f},{max_p99_r:.3f},"
      f"{avg_p50_w:.3f},{avg_p95_w:.3f},{max_p99_w:.3f},"
      f"{sla_pass}")
PYEOF
}

# ---------------------------------------------------------------------------
# generate_qd_summary <qd_csv> <out_json> <pool> <cfg> <vm_count> <rate> <sla>
# ---------------------------------------------------------------------------
generate_qd_summary() {
  local csv="$1" out="$2" pool="$3" cfg="$4" vm_count="$5" rate="$6" sla="$7"

  python3 - "${csv}" "${out}" "${pool}" "${cfg}" "${vm_count}" "${rate}" "${sla}" \
           "${RUN_ID}" "${CLUSTER_DESCRIPTION:-}" <<'PYEOF'
import csv, json, sys, datetime, subprocess

csv_path, out_path, pool, cfg, vm_count, rate, sla, run_id, cluster_desc = sys.argv[1:]
vm_count, rate, sla = int(vm_count), int(rate), float(sla)

rows = []
with open(csv_path) as f:
    for row in csv.DictReader(f):
        try:
            rows.append({
                "qd": int(row["qd"]),
                "total_iops": float(row["total_read_iops"]) + float(row["total_write_iops"]),
                "p99_r": float(row["max_p99_read_ms"]),
                "p99_w": float(row["max_p99_write_ms"]),
                "sla_pass": row["sla_pass"] == "true",
            })
        except (ValueError, KeyError):
            continue

if not rows:
    open(out_path, "w").write(json.dumps({"error": "no qd rows"}))
    sys.exit(0)

passing = [r for r in rows if r["sla_pass"]]
hi = max((r["qd"] for r in passing), default=0)
iops_at_hi = next((r["total_iops"] for r in rows if r["qd"] == hi), 0) if hi else 0
peak = max(rows, key=lambda r: r["total_iops"])

ocs_version = ""
try:
    ocs_version = subprocess.run(
        ["oc", "get", "csv", "-n", "openshift-storage",
         "-o", "jsonpath={.items[?(@.spec.displayName==\"OpenShift Data Foundation\")].spec.version}"],
        capture_output=True, text=True, timeout=10).stdout.strip()
except Exception:
    pass

summary = {
    "pool": pool, "tune_cfg_name": cfg,
    "vm_count": vm_count, "rate_iops_per_vm": rate,
    "qd_list": [r["qd"] for r in rows],
    "latency_sla_ms": sla,
    "highest_qd_within_sla": hi,
    "iops_at_highest_qd_within_sla": int(iops_at_hi),
    "qd_with_peak_iops": peak["qd"],
    "peak_total_iops": int(peak["total_iops"]),
    "p99_write_at_peak_qd_ms": peak["p99_w"],
    "p99_read_at_peak_qd_ms": peak["p99_r"],
    "resource_ceiling": False,
    "ocs_version": ocs_version,
    "cluster_description": cluster_desc,
    "run_id": run_id,
    "timestamp": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}
open(out_path, "w").write(json.dumps(summary, indent=2))
PYEOF
}

# ---------------------------------------------------------------------------
# generate_tune_sweep_report <cfg_root> <pool> <baseline> <headline_qd> <out_html>
#   Generates an HTML comparison report for an ODF tune sweep.
#   cfg_root:     results/.../qd-sweep/<pool>  (directory with per-config subdirs)
#   pool:         storage pool name (display)
#   baseline:     name of the baseline config (e.g. "default")
#   headline_qd:  QD value to use for the headline bar charts
#   out_html:     output HTML file path
# ---------------------------------------------------------------------------
generate_tune_sweep_report() {
  local cfg_root="$1"      # results/.../qd-sweep/<pool>
  local pool="$2"
  local baseline="$3"
  local headline_qd="$4"
  local out_html="$5"

  log_info "Generating tune-sweep report: ${out_html}"

  CFG_ROOT="${cfg_root}" POOL="${pool}" BASELINE="${baseline}" \
   HEADLINE_QD="${headline_qd}" \
   CLUSTER_DESC="${CLUSTER_DESCRIPTION:-}" \
   python3 << 'PYEOF_TUNE_REPORT' > "${out_html}"
import csv, json, os, datetime
cfg_root  = os.environ['CFG_ROOT']
pool      = os.environ['POOL']
baseline  = os.environ['BASELINE']
headline_qd_raw = os.environ.get('HEADLINE_QD', '0').strip()
headline_qd = int(headline_qd_raw) if headline_qd_raw else 0
cluster_desc = os.environ.get('CLUSTER_DESC', '')

# Auto-discover configs under cfg_root
configs = []
for d in sorted(os.listdir(cfg_root)):
    cdir = os.path.join(cfg_root, d)
    csv_path = os.path.join(cdir, 'qd.csv')
    sum_path = os.path.join(cdir, 'qd-summary.json')
    if not (os.path.isfile(csv_path) and os.path.isfile(sum_path)):
        continue
    rows = []
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            try:
                rows.append({
                    'qd': int(row['qd']),
                    'iops_r': float(row['total_read_iops']),
                    'iops_w': float(row['total_write_iops']),
                    'bw':    float(row['total_bw_mbs']),
                    'p99_r': float(row['max_p99_read_ms']),
                    'p99_w': float(row['max_p99_write_ms']),
                    'sla_pass': row['sla_pass'] == 'true',
                })
            except ValueError:
                continue
    summary = json.load(open(sum_path))
    configs.append({'name': d, 'rows': rows, 'summary': summary})

# Resolve baseline
baseline_cfg = next((c for c in configs if c['name'] == baseline), configs[0] if configs else None)
baseline_peak = baseline_cfg['summary'].get('peak_total_iops', 0) if baseline_cfg else 0

# Comparability check
slas    = {c['summary'].get('latency_sla_ms', 0) for c in configs}
rates   = {c['summary'].get('rate_iops_per_vm', 0) for c in configs}
nvms    = {c['summary'].get('vm_count', 0) for c in configs}
qdsets  = {tuple(c['summary'].get('qd_list', [])) for c in configs}
mismatch = (len(slas) > 1 or len(rates) > 1 or len(nvms) > 1 or len(qdsets) > 1)

# Carbon-ish palette, deterministic by config order
palette = ['#0f62fe', '#007d79', '#6929c4', '#1192e8', '#fa4d56', '#161616']

# QD-axis chart datasets
datasets = []
for i, c in enumerate(configs):
    color = palette[i % len(palette)]
    iops = [{'x': r['qd'], 'y': r['iops_r'] + r['iops_w']} for r in c['rows']]
    p99w = [{'x': r['qd'], 'y': r['p99_w']} for r in c['rows']]
    pt_colors = ['#198038' if r['sla_pass'] else '#da1e28' for r in c['rows']]
    datasets.append({
        'label': f"{c['name']} — Total IOPS",
        'data': iops, 'borderColor': color, 'backgroundColor': color + '20',
        'yAxisID': 'y-iops', 'tension': 0.2,
        'pointBackgroundColor': pt_colors, 'pointBorderColor': color,
        'pointRadius': 5, 'borderWidth': 2.5,
    })
    datasets.append({
        'label': f"{c['name']} — Write p99 (ms)",
        'data': p99w, 'borderColor': color, 'borderDash': [6, 4],
        'yAxisID': 'y-lat', 'tension': 0.2,
        'pointBackgroundColor': pt_colors, 'pointBorderColor': color,
        'pointRadius': 5, 'borderWidth': 2,
    })

sla_value = list(slas)[0] if len(slas) == 1 else None
sla_annot = ''
if sla_value is not None:
    sla_annot = (f"slaLine:{{type:'line',yMin:{sla_value},yMax:{sla_value},"
                 f"yScaleID:'y-lat',borderColor:'#da1e28',borderWidth:2,"
                 f"borderDash:[10,5],label:{{content:'SLA: {sla_value}ms',"
                 f"display:true,position:'start'}}}}")

# Headline-QD bar charts (4 metrics × N configs)
def row_at(c, qd):
    return next((r for r in c['rows'] if r['qd'] == qd), None)
labels = [c['name'] for c in configs]
def bar_dataset(metric, color_arr):
    data = []
    for c in configs:
        r = row_at(c, headline_qd)
        if not r:
            data.append(None); continue
        if metric == 'iops':  data.append(r['iops_r'] + r['iops_w'])
        elif metric == 'bw':  data.append(r['bw'])
        elif metric == 'p99_r': data.append(r['p99_r'])
        elif metric == 'p99_w': data.append(r['p99_w'])
    return {'data': data, 'backgroundColor': color_arr, 'borderColor': color_arr, 'borderWidth': 1}
colors = [palette[i % len(palette)] for i in range(len(configs))]

# Scorecard
def fmt_int(n): return f"{int(n):,}"
def fmt_pct(x): return f"{x:+.1f}%" if x is not None else "—"
scorecard_rows = []
for c in configs:
    s = c['summary']
    peak = s.get('peak_total_iops', 0)
    delta = (peak - baseline_peak) / baseline_peak * 100 if baseline_peak else None
    delta_cell = '<span class="muted">—</span>' if c['name'] == baseline_cfg['name'] else fmt_pct(delta)
    row_h = row_at(c, headline_qd)
    sla_hdq = 'PASS' if (row_h and row_h['sla_pass']) else 'FAIL'
    sla_class = 'pass' if sla_hdq == 'PASS' else 'fail'
    res_ceiling = 'yes' if s.get('resource_ceiling') else 'no'
    cstate_yaml = ''
    try:
        ta_path = os.path.join(cfg_root, c['name'], 'tuning-applied.yaml')
        cstate_yaml = open(ta_path).read()
    except Exception:
        pass
    osd_summary = 'inherit'
    for line in cstate_yaml.splitlines():
        if line.startswith('realised_osd_resources:'):
            osd_summary = line.split(': ', 1)[1].strip().strip('"')
    scorecard_rows.append(
        f"<tr><td><b>{c['name']}</b></td>"
        f"<td>{fmt_int(peak)}</td><td>{delta_cell}</td>"
        f"<td>{s.get('p99_read_at_peak_qd_ms', 0):.2f}</td>"
        f"<td>{s.get('p99_write_at_peak_qd_ms', 0):.2f}</td>"
        f"<td class='{sla_class}'>{sla_hdq}</td>"
        f"<td>{res_ceiling}</td>"
        f"<td><code>{osd_summary[:60]}</code></td></tr>"
    )

# Per-config detail tables
detail_blocks = []
for c in configs:
    rows_html = []
    for r in c['rows']:
        sla_cls = 'pass' if r['sla_pass'] else 'fail'
        rows_html.append(
            f"<tr><td>{r['qd']}</td>"
            f"<td>{int(r['iops_r']):,}</td><td>{int(r['iops_w']):,}</td>"
            f"<td>{r['bw']:,.1f}</td>"
            f"<td>{r['p99_r']:.3f}</td><td>{r['p99_w']:.3f}</td>"
            f"<td class='{sla_cls}'>{'PASS' if r['sla_pass'] else 'FAIL'}</td></tr>"
        )
    detail_blocks.append(
        f"<details><summary><b>{c['name']}</b></summary>"
        f"<table><tr><th>QD</th><th>Read IOPS</th><th>Write IOPS</th><th>BW MB/s</th>"
        f"<th>p99 R (ms)</th><th>p99 W (ms)</th><th>SLA</th></tr>"
        + ''.join(rows_html) + "</table></details>"
    )

banner_class = 'warn' if mismatch else 'ok'
banner_text = ('Workload params differ across configs — comparison is approximate.'
               if mismatch else
               f'All configs tested at {list(rates)[0]} IOPS/VM × {list(nvms)[0]} VMs '
               f'× SLA={sla_value}ms. Apples-to-apples.')

generated_at = datetime.datetime.utcnow().isoformat(timespec='seconds')

print(f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>ODF Tune Sweep: {pool}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation@3"></script>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; background: #f4f4f4; color: #161616; }}
  h1 {{ margin-bottom: 4px; }}
  .meta {{ color: #525252; font-size: 0.9em; margin-bottom: 20px; }}
  .banner {{ padding: 14px 18px; margin: 18px 0; border-radius: 4px; }}
  .banner.ok {{ background: #defbe6; border-left: 4px solid #198038; }}
  .banner.warn {{ background: #fff8e1; border-left: 4px solid #f1c21b; }}
  .chart-container {{ background: white; padding: 20px; border-radius: 8px; margin: 20px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }}
  .bar-row {{ display: grid; grid-template-columns: 1fr 1fr 1fr 1fr; gap: 16px; }}
  table {{ width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-top: 8px; }}
  th {{ background: #161616; color: white; padding: 10px 12px; text-align: right; font-size: 0.85em; }}
  th:first-child, th:nth-child(2) {{ text-align: left; }}
  td {{ padding: 8px 12px; text-align: right; border-bottom: 1px solid #e0e0e0; font-size: 0.9em; }}
  td:first-child, td:nth-child(8) {{ text-align: left; }}
  .pass {{ color: #198038; font-weight: 600; }}
  .fail {{ color: #da1e28; font-weight: 600; }}
  .muted {{ color: #8d8d8d; }}
  details {{ background: white; padding: 12px 16px; border-radius: 8px; margin: 10px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }}
  details summary {{ cursor: pointer; padding: 4px 0; }}
  code {{ background: #f4f4f4; padding: 1px 5px; border-radius: 3px; font-size: 0.9em; }}
</style>
</head>
<body>
<h1>ODF Tune Sweep: {pool}</h1>
<div class="meta">
  <b>Cluster:</b> {cluster_desc or 'n/a'}<br>
  <b>Baseline:</b> {baseline_cfg['name']}<br>
  <b>Headline QD:</b> {headline_qd}<br>
  <b>Generated:</b> {generated_at}
</div>

<div class="banner {banner_class}">{banner_text}</div>

<h2>Capacity scorecard</h2>
<table>
<tr>
  <th>Config</th><th>Peak IOPS</th><th>Δ vs baseline</th>
  <th>p99 R @ peak (ms)</th><th>p99 W @ peak (ms)</th>
  <th>SLA @ QD={headline_qd}</th><th>Resource ceiling</th><th>Tuning</th>
</tr>
{''.join(scorecard_rows)}
</table>

<h2>Headline @ QD={headline_qd}</h2>
<div class="bar-row">
  <div class="chart-container"><canvas id="headlineIops"></canvas></div>
  <div class="chart-container"><canvas id="headlineBw"></canvas></div>
  <div class="chart-container"><canvas id="headlineP99R"></canvas></div>
  <div class="chart-container"><canvas id="headlineP99W"></canvas></div>
</div>

<h2>QD-axis behaviour</h2>
<div class="chart-container">
  <canvas id="qdChart" height="100"></canvas>
</div>

<h2>Per-config data</h2>
{''.join(detail_blocks)}

<script>
const ctx = document.getElementById('qdChart').getContext('2d');
new Chart(ctx, {{
  type: 'line',
  data: {{ datasets: {json.dumps(datasets)} }},
  options: {{
    responsive: true, parsing: false,
    interaction: {{ mode: 'nearest', intersect: false }},
    scales: {{
      x: {{ type: 'linear', title: {{ display: true, text: 'Queue depth' }} }},
      'y-iops': {{ type: 'linear', position: 'left', title: {{ display: true, text: 'Aggregate IOPS' }}, beginAtZero: true }},
      'y-lat':  {{ type: 'linear', position: 'right', title: {{ display: true, text: 'Write p99 (ms)' }}, beginAtZero: true, grid: {{ drawOnChartArea: false }} }}
    }},
    plugins: {{ legend: {{ position: 'top' }},
      annotation: {{ annotations: {{ {sla_annot} }} }} }}
  }}
}});

const labels = {json.dumps(labels)};
const colors = {json.dumps(colors)};
const bar = (id, data, label, lowerBetter) => new Chart(document.getElementById(id), {{
  type: 'bar',
  data: {{ labels, datasets: [{{ label, data, backgroundColor: colors, borderColor: colors, borderWidth: 1 }}] }},
  options: {{ plugins: {{ legend: {{ display: false }}, title: {{ display: true, text: label + (lowerBetter ? ' (lower is better)' : ' (higher is better)') }} }}, scales: {{ y: {{ beginAtZero: true }} }} }}
}});

bar('headlineIops',  {json.dumps(bar_dataset('iops', colors)['data'])}, 'IOPS @ QD={headline_qd}', false);
bar('headlineBw',    {json.dumps(bar_dataset('bw', colors)['data'])},   'Throughput MB/s @ QD={headline_qd}', false);
bar('headlineP99R',  {json.dumps(bar_dataset('p99_r', colors)['data'])},'Read p99 ms @ QD={headline_qd}', true);
bar('headlineP99W',  {json.dumps(bar_dataset('p99_w', colors)['data'])},'Write p99 ms @ QD={headline_qd}', true);
</script>
</body>
</html>""")
PYEOF_TUNE_REPORT

  log_info "Tune-sweep report generated: ${out_html}"
}
