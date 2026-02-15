#!/usr/bin/env bash
# =============================================================================
# 06-generate-report.sh — Generate HTML, Markdown, and XLSX reports
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/00-config.sh"
source "${SCRIPT_DIR}/lib/vm-helpers.sh"
source "${SCRIPT_DIR}/lib/report-helpers.sh"

# ---------------------------------------------------------------------------
# Parse CLI args
# ---------------------------------------------------------------------------
COMPARE_RUN_1=""
COMPARE_RUN_2=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compare)
      COMPARE_RUN_1="$2"
      COMPARE_RUN_2="$3"
      shift 3
      ;;
    --help)
      echo "Usage: $0 [--compare <run-id-1> <run-id-2>]"
      echo "  --compare <id1> <id2>   Compare two runs side-by-side with delta analysis"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Generate comparison HTML report
# ---------------------------------------------------------------------------
generate_comparison_report() {
  local csv1="$1"
  local csv2="$2"
  local run1="$3"
  local run2="$4"
  local output_html="$5"

  log_info "Generating comparison report: ${output_html}"

  local compare_json
  compare_json=$(python3 << 'PYEOF2'
import csv, json, sys

def load_csv(path):
    data = {}
    with open(path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            key = "|".join([
                row.get('storage_pool', ''),
                row.get('vm_size', ''),
                row.get('pvc_size', ''),
                row.get('concurrency', ''),
                row.get('fio_profile', ''),
                row.get('block_size', '')
            ])
            if key not in data:
                data[key] = row
            else:
                for m in ['read_iops', 'write_iops', 'read_bw_kib', 'write_bw_kib',
                           'read_lat_avg_ms', 'write_lat_avg_ms', 'read_lat_p99_ms', 'write_lat_p99_ms']:
                    try:
                        old = float(data[key].get(m, 0))
                        new = float(row.get(m, 0))
                        data[key][m] = str((old + new) / 2)
                    except (ValueError, TypeError):
                        pass
    return data

csv1 = sys.argv[1]
csv2 = sys.argv[2]
run1 = sys.argv[3]
run2 = sys.argv[4]

data1 = load_csv(csv1)
data2 = load_csv(csv2)

metrics = [
    ('read_iops', 'Read IOPS', True),
    ('write_iops', 'Write IOPS', True),
    ('read_bw_kib', 'Read BW (KiB/s)', True),
    ('write_bw_kib', 'Write BW (KiB/s)', True),
    ('read_lat_avg_ms', 'Read Lat (ms)', False),
    ('write_lat_avg_ms', 'Write Lat (ms)', False),
    ('read_lat_p99_ms', 'Read p99 (ms)', False),
    ('write_lat_p99_ms', 'Write p99 (ms)', False),
]

common_keys = sorted(set(data1.keys()) & set(data2.keys()))
rows = []
for key in common_keys:
    r1, r2 = data1[key], data2[key]
    parts = key.split('|')
    row = {
        'pool': parts[0], 'vm_size': parts[1], 'pvc_size': parts[2],
        'concurrency': parts[3], 'profile': parts[4], 'block_size': parts[5],
    }
    for m, label, higher_better in metrics:
        v1 = float(r1.get(m, 0) or 0)
        v2 = float(r2.get(m, 0) or 0)
        delta_pct = ((v2 - v1) / v1 * 100) if v1 != 0 else 0
        row[m + '_run1'] = round(v1, 2)
        row[m + '_run2'] = round(v2, 2)
        row[m + '_delta'] = round(delta_pct, 1)
        row[m + '_improved'] = (delta_pct > 0) if higher_better else (delta_pct < 0)
    rows.append(row)

print(json.dumps({
    'run1': run1, 'run2': run2,
    'common': len(common_keys),
    'only_run1': len(set(data1.keys()) - set(data2.keys())),
    'only_run2': len(set(data2.keys()) - set(data1.keys())),
    'rows': rows,
    'metrics': [{'key': m, 'label': l, 'higher_better': h} for m, l, h in metrics]
}))
PYEOF2
  "${csv1}" "${csv2}" "${run1}" "${run2}")

  cat > "${output_html}" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Comparison: ${run1} vs ${run2}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f5f5f5; color: #333; }
    .header { background: #1a1a2e; color: white; padding: 2rem; }
    .header h1 { font-size: 1.5rem; margin-bottom: 0.5rem; }
    .header .meta { color: #aaa; font-size: 0.9rem; }
    .container { max-width: 1600px; margin: 0 auto; padding: 1rem; }
    .summary { background: white; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); display: flex; gap: 2rem; }
    .summary .stat { text-align: center; }
    .summary .stat .value { font-size: 2rem; font-weight: bold; }
    .summary .stat .label { font-size: 0.8rem; color: #666; }
    .filters { background: white; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; display: flex; flex-wrap: wrap; gap: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    .filter-group label { font-size: 0.75rem; font-weight: 600; text-transform: uppercase; color: #666; }
    .filter-group select { padding: 0.5rem; border: 1px solid #ddd; border-radius: 4px; }
    table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
    th, td { padding: 0.5rem; text-align: right; border-bottom: 1px solid #eee; }
    th { background: #f8f9fa; font-weight: 600; text-align: left; position: sticky; top: 0; }
    td:first-child { text-align: left; }
    .improved { color: #2d6a4f; background: #d8f3dc; }
    .regressed { color: #9d0208; background: #ffccd5; }
    .neutral { color: #666; }
    .delta { font-weight: bold; font-size: 0.8rem; }
    .table-card { background: white; border-radius: 8px; padding: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.1); overflow-x: auto; }
  </style>
</head>
<body>
  <div class="header">
    <h1>Performance Comparison Report</h1>
    <div class="meta">Baseline: ${run1} | Candidate: ${run2}</div>
  </div>
  <div class="container">
    <div class="summary" id="summary"></div>
    <div class="filters" id="filters"></div>
    <div class="table-card"><table id="compareTable"></table></div>
  </div>
  <script>
    const DATA = ${compare_json};
    const rows = DATA.rows;
    const metrics = DATA.metrics;

    // Summary
    const summaryDiv = document.getElementById('summary');
    let improved = 0, regressed = 0, unchanged = 0;
    rows.forEach(r => {
      metrics.forEach(m => {
        const d = r[m.key + '_delta'];
        if (Math.abs(d) < 1) unchanged++;
        else if (r[m.key + '_improved']) improved++;
        else regressed++;
      });
    });
    summaryDiv.innerHTML =
      '<div class="stat"><div class="value">' + DATA.common + '</div><div class="label">Common Tests</div></div>' +
      '<div class="stat"><div class="value" style="color:#2d6a4f">' + improved + '</div><div class="label">Improvements</div></div>' +
      '<div class="stat"><div class="value" style="color:#9d0208">' + regressed + '</div><div class="label">Regressions</div></div>' +
      '<div class="stat"><div class="value" style="color:#666">' + unchanged + '</div><div class="label">Unchanged (&lt;1%)</div></div>' +
      '<div class="stat"><div class="value">' + DATA.only_run1 + '</div><div class="label">Only in ' + DATA.run1 + '</div></div>' +
      '<div class="stat"><div class="value">' + DATA.only_run2 + '</div><div class="label">Only in ' + DATA.run2 + '</div></div>';

    // Filters
    const unique = (key) => [...new Set(rows.map(r => r[key]))].sort();
    const filtersDiv = document.getElementById('filters');
    ['pool', 'vm_size', 'pvc_size', 'profile', 'block_size'].forEach(key => {
      const group = document.createElement('div');
      group.className = 'filter-group';
      group.innerHTML = '<label>' + key + '</label><br><select id="f-' + key + '"><option value="all">All</option>' +
        unique(key).map(v => '<option value="' + v + '">' + v + '</option>').join('') + '</select>';
      filtersDiv.appendChild(group);
      group.querySelector('select').addEventListener('change', render);
    });

    function render() {
      const filters = {};
      ['pool', 'vm_size', 'pvc_size', 'profile', 'block_size'].forEach(k => {
        filters[k] = document.getElementById('f-' + k).value;
      });
      const filtered = rows.filter(r =>
        Object.entries(filters).every(([k, v]) => v === 'all' || r[k] === v)
      );

      let html = '<thead><tr><th>Pool</th><th>VM</th><th>PVC</th><th>Conc</th><th>Profile</th><th>BS</th>';
      metrics.forEach(m => {
        html += '<th colspan="3">' + m.label + '</th>';
      });
      html += '</tr><tr><th colspan="6"></th>';
      metrics.forEach(() => {
        html += '<th>' + DATA.run1.replace(/^perf-/, '') + '</th><th>' + DATA.run2.replace(/^perf-/, '') + '</th><th>Delta</th>';
      });
      html += '</tr></thead><tbody>';

      filtered.forEach(r => {
        html += '<tr><td>' + r.pool + '</td><td>' + r.vm_size + '</td><td>' + r.pvc_size +
          '</td><td>' + r.concurrency + '</td><td>' + r.profile + '</td><td>' + r.block_size + '</td>';
        metrics.forEach(m => {
          const v1 = r[m.key + '_run1'];
          const v2 = r[m.key + '_run2'];
          const delta = r[m.key + '_delta'];
          const imp = r[m.key + '_improved'];
          const cls = Math.abs(delta) < 1 ? 'neutral' : (imp ? 'improved' : 'regressed');
          const sign = delta > 0 ? '+' : '';
          html += '<td>' + v1 + '</td><td>' + v2 + '</td><td class="' + cls + ' delta">' + sign + delta + '%</td>';
        });
        html += '</tr>';
      });
      html += '</tbody>';
      document.getElementById('compareTable').innerHTML = html;
    }
    render();
  </script>
</body>
</html>
HTMLEOF

  log_info "Comparison report generated: ${output_html}"
}

# ---------------------------------------------------------------------------
# Generate XLSX from CSV using Python + openpyxl
# ---------------------------------------------------------------------------
generate_xlsx_report() {
  local csv_file="$1"
  local summary_csv="$2"
  local output_xlsx="$3"

  log_info "Generating XLSX report: ${output_xlsx}"

  python3 << PYEOF
import csv
import sys

try:
    from openpyxl import Workbook
    from openpyxl.chart import BarChart, Reference
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.utils import get_column_letter
except ImportError:
    print("ERROR: openpyxl not installed. Install with: pip install openpyxl", file=sys.stderr)
    sys.exit(1)

wb = Workbook()

# --- Summary sheet ---
ws_summary = wb.active
ws_summary.title = "Summary"

header_font = Font(bold=True, color="FFFFFF")
header_fill = PatternFill(start_color="1A1A2E", end_color="1A1A2E", fill_type="solid")
thin_border = Border(
    left=Side(style='thin'), right=Side(style='thin'),
    top=Side(style='thin'), bottom=Side(style='thin')
)

# Read summary CSV
summary_data = []
with open("${summary_csv}", "r") as f:
    reader = csv.reader(f)
    for row in reader:
        summary_data.append(row)

if len(summary_data) > 1:
    header = summary_data[0]
    data_rows = summary_data[1:]
    try:
        data_rows.sort(key=lambda r: float(r[1]), reverse=True)
    except (ValueError, IndexError):
        pass
    summary_data = [header] + data_rows

for r_idx, row in enumerate(summary_data, 1):
    for c_idx, val in enumerate(row, 1):
        cell = ws_summary.cell(row=r_idx, column=c_idx, value=val)
        cell.border = thin_border
        if r_idx == 1:
            cell.font = header_font
            cell.fill = header_fill
            cell.alignment = Alignment(horizontal='center')
        else:
            try:
                cell.value = float(val)
                cell.number_format = '#,##0.00' if '.' in val else '#,##0'
            except ValueError:
                pass

# Auto-width columns
for col in range(1, len(summary_data[0]) + 1 if summary_data else 1):
    ws_summary.column_dimensions[get_column_letter(col)].width = 18

# Add IOPS chart
if len(summary_data) > 1:
    chart = BarChart()
    chart.type = "col"
    chart.title = "Average IOPS by Storage Pool"
    chart.y_axis.title = "IOPS"
    chart.x_axis.title = "Storage Pool"
    chart.style = 10
    chart.width = 25
    chart.height = 15

    cats = Reference(ws_summary, min_col=1, min_row=2, max_row=len(summary_data))
    read_iops = Reference(ws_summary, min_col=2, min_row=1, max_row=len(summary_data))
    write_iops = Reference(ws_summary, min_col=3, min_row=1, max_row=len(summary_data))
    chart.add_data(read_iops, titles_from_data=True)
    chart.add_data(write_iops, titles_from_data=True)
    chart.set_categories(cats)
    ws_summary.add_chart(chart, "A" + str(len(summary_data) + 3))

# --- Raw Data sheet ---
ws_raw = wb.create_sheet("Raw Data")

raw_data = []
with open("${csv_file}", "r") as f:
    reader = csv.reader(f)
    for row in reader:
        raw_data.append(row)

for r_idx, row in enumerate(raw_data, 1):
    for c_idx, val in enumerate(row, 1):
        cell = ws_raw.cell(row=r_idx, column=c_idx, value=val)
        cell.border = thin_border
        if r_idx == 1:
            cell.font = header_font
            cell.fill = header_fill
        else:
            try:
                cell.value = float(val)
            except ValueError:
                pass

for col in range(1, len(raw_data[0]) + 1 if raw_data else 1):
    ws_raw.column_dimensions[get_column_letter(col)].width = 16

# --- Rankings sheet ---
ws_rank = wb.create_sheet("Rankings")
gold_fill = PatternFill(start_color="FFD700", end_color="FFD700", fill_type="solid")

# Summary CSV columns (0-indexed):
# 0=pool, 1=avg_read_iops, 2=avg_write_iops, 3=avg_read_bw_mib, 4=avg_write_bw_mib,
# 5=avg_read_lat_ms, 6=avg_write_lat_ms, 7=avg_read_p99_ms, 8=avg_write_p99_ms, 9=test_count
if len(summary_data) > 1:
    s_rows = summary_data[1:]  # already sorted by IOPS desc from above

    ranking_tables = [
        ("Random I/O (IOPS) — Higher is Better", 1, True, ["Storage Pool", "Read IOPS", "Write IOPS"], [0, 1, 2]),
        ("Sequential Throughput (MiB/s) — Higher is Better", 3, True, ["Storage Pool", "Read BW", "Write BW"], [0, 3, 4]),
        ("Average Latency (ms) — Lower is Better", 5, False, ["Storage Pool", "Read Lat", "Write Lat"], [0, 5, 6]),
        ("p99 Tail Latency (ms) — Lower is Better", 7, False, ["Storage Pool", "Read p99", "Write p99"], [0, 7, 8]),
    ]

    current_row = 1
    for title, sort_col, reverse_sort, headers, col_indices in ranking_tables:
        # Table title
        cell = ws_rank.cell(row=current_row, column=1, value=title)
        cell.font = Font(bold=True, size=12)
        current_row += 1

        # Header row
        for ci, h in enumerate(["Rank"] + headers, 1):
            cell = ws_rank.cell(row=current_row, column=ci, value=h)
            cell.font = header_font
            cell.fill = header_fill
            cell.alignment = Alignment(horizontal='center')
            cell.border = thin_border
        current_row += 1

        # Sort rows for this table
        try:
            sorted_rows = sorted(s_rows, key=lambda r: float(r[sort_col]), reverse=reverse_sort)
        except (ValueError, IndexError):
            sorted_rows = s_rows

        for rank, row in enumerate(sorted_rows, 1):
            ws_rank.cell(row=current_row, column=1, value=rank).border = thin_border
            for ci, idx in enumerate(col_indices, 2):
                cell = ws_rank.cell(row=current_row, column=ci)
                cell.border = thin_border
                try:
                    cell.value = float(row[idx])
                    cell.number_format = '#,##0.00' if '.' in row[idx] else '#,##0'
                except (ValueError, IndexError):
                    cell.value = row[idx]
            if rank == 1:
                for ci in range(1, len(headers) + 2):
                    ws_rank.cell(row=current_row, column=ci).fill = gold_fill
            current_row += 1

        current_row += 2  # gap between tables

    for col in range(1, 5):
        ws_rank.column_dimensions[get_column_letter(col)].width = 22

# --- Info sheet ---
ws_info = wb.create_sheet("Test Config")
info_rows = [
    ("Run ID", "${RUN_ID}"),
    ("Date", "$(date -u +%Y-%m-%dT%H:%M:%SZ)"),
    ("Cluster", "${CLUSTER_DESCRIPTION}"),
    ("VM Sizes", "${VM_SIZES[*]}"),
    ("PVC Sizes", "${PVC_SIZES[*]}"),
    ("Concurrency", "${CONCURRENCY_LEVELS[*]}"),
    ("fio Runtime", "${FIO_RUNTIME}s"),
    ("Block Sizes", "${FIO_BLOCK_SIZES[*]}"),
    ("I/O Depth", "${FIO_IODEPTH}"),
    ("Num Jobs", "${FIO_NUMJOBS}"),
]
for r_idx, (k, v) in enumerate(info_rows, 1):
    ws_info.cell(row=r_idx, column=1, value=k).font = Font(bold=True)
    ws_info.cell(row=r_idx, column=2, value=v)
ws_info.column_dimensions['A'].width = 20
ws_info.column_dimensions['B'].width = 60

wb.save("${output_xlsx}")
print(f"XLSX saved: ${output_xlsx}")
PYEOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  # Handle comparison mode
  if [[ -n "${COMPARE_RUN_1}" ]] && [[ -n "${COMPARE_RUN_2}" ]]; then
    log_info "=== Generating Comparison Report ==="
    local csv1="${REPORTS_DIR}/results-${COMPARE_RUN_1}.csv"
    local csv2="${REPORTS_DIR}/results-${COMPARE_RUN_2}.csv"

    if [[ ! -f "${csv1}" ]]; then
      log_error "CSV not found for run ${COMPARE_RUN_1}: ${csv1}"
      exit 1
    fi
    if [[ ! -f "${csv2}" ]]; then
      log_error "CSV not found for run ${COMPARE_RUN_2}: ${csv2}"
      exit 1
    fi

    local output="${REPORTS_DIR}/compare-${COMPARE_RUN_1}-vs-${COMPARE_RUN_2}.html"
    generate_comparison_report "${csv1}" "${csv2}" "${COMPARE_RUN_1}" "${COMPARE_RUN_2}" "${output}"

    log_info ""
    log_info "=== Comparison Report Generated ==="
    log_info "  HTML: ${output}"
    return 0
  fi

  log_info "=== Generating Performance Reports ==="

  local csv_file="${REPORTS_DIR}/results-${RUN_ID}.csv"
  local summary_csv="${REPORTS_DIR}/summary-${RUN_ID}.csv"

  if [[ ! -f "${csv_file}" ]]; then
    log_warn "CSV file not found: ${csv_file}"
    log_info "Running result collection first..."
    bash "${SCRIPT_DIR}/05-collect-results.sh"
  fi

  if [[ ! -f "${csv_file}" ]]; then
    log_error "CSV file still not found after collection: ${csv_file}"
    exit 1
  fi

  mkdir -p "${REPORTS_DIR}"

  # Generate Markdown report
  generate_markdown_report "${csv_file}" "${REPORTS_DIR}/report-${RUN_ID}.md"

  # Generate HTML dashboard
  generate_html_report "${csv_file}" "${REPORTS_DIR}/report-${RUN_ID}.html"

  # Generate XLSX workbook (requires summary CSV + openpyxl)
  if [[ ! -f "${summary_csv}" ]]; then
    log_warn "Summary CSV not found: ${summary_csv} — skipping XLSX generation"
  elif ! python3 -c "import openpyxl" 2>/dev/null; then
    log_warn "openpyxl not installed — skipping XLSX generation (install with: pip install openpyxl)"
  else
    generate_xlsx_report "${csv_file}" "${summary_csv}" "${REPORTS_DIR}/report-${RUN_ID}.xlsx"
  fi

  log_info ""
  log_info "=== Reports Generated ==="
  log_info "  Markdown: ${REPORTS_DIR}/report-${RUN_ID}.md"
  log_info "  HTML:     ${REPORTS_DIR}/report-${RUN_ID}.html"
  [[ -f "${REPORTS_DIR}/report-${RUN_ID}.xlsx" ]] && log_info "  XLSX:     ${REPORTS_DIR}/report-${RUN_ID}.xlsx"
  log_info "  Raw CSV:  ${csv_file}"
  log_info "  Summary:  ${summary_csv}"
}

main "$@"
