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
    return 1
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
  find "${results_dir}" -name "*-fio.json" -type f | sort | while read -r json_file; do
    local rel_path="${json_file#${results_dir}/}"
    # Parse path components
    IFS='/' read -r pool vmsize pvcsize concurrency profile blocksize _filename <<< "${rel_path}"

    if [[ -z "${pool}" || -z "${vmsize}" || -z "${profile}" || -z "${blocksize}" ]]; then
      log_warn "Skipping file with unexpected path structure: ${rel_path}"
      continue
    fi

    parse_fio_json_to_csv "${json_file}" \
      "${pool}" "${vmsize}" "${pvcsize}" "${concurrency}" "${profile}" "${blocksize}"
  done >> "${output_csv}"

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
