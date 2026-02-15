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
    print("Installing openpyxl...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "openpyxl", "--quiet", "--break-system-packages"])
    from openpyxl import Workbook
    from openpyxl.chart import BarChart, Reference
    from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
    from openpyxl.utils import get_column_letter

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
    ("Cluster", "IBM Cloud ROKS (${BM_FLAVOR} bare metal, NVMe)"),
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

  # Generate XLSX workbook (requires summary CSV)
  if [[ ! -f "${summary_csv}" ]]; then
    log_warn "Summary CSV not found: ${summary_csv} — skipping XLSX generation"
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
