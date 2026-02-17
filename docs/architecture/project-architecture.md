# Project Architecture

[Back to Index](../index.md)

This page explains the design philosophy, execution pipeline, and internal structure of the test suite. It's intended for contributors or anyone who wants to understand or modify the codebase.

## Design Philosophy

### Numbered Scripts

Scripts are numbered `00-07` and run sequentially. This provides:
- **Clear execution order** — you can see the pipeline at a glance
- **Incremental execution** — run only the steps you need
- **Failure isolation** — if step 04 fails, steps 01-02 don't need to be re-run

### Config-Driven

`00-config.sh` is the single source of truth for all tunables. Other scripts never hardcode values — they `source 00-config.sh` and read environment variables. This means:
- Changing a VM size, PVC size, or fio parameter requires editing only one file
- You can override any value with environment variables (e.g., `FIO_RUNTIME=60 ./04-run-tests.sh`)
- New storage pools or fio profiles just need to be added to the arrays in config

### Bash-Native

The entire orchestration layer is written in Bash (with Python only for XLSX generation). This was a deliberate choice:
- No additional dependencies beyond standard CLI tools (`oc`, `virtctl`, `jq`)
- Easy to read, modify, and debug for infrastructure engineers
- Direct shell access to Kubernetes CLI tools without wrapper libraries
- Templates use simple string substitution rather than a complex templating engine

### Template Rendering

Rather than using Helm, Kustomize, or other Kubernetes templating tools, this project uses straightforward string substitution with `__PLACEHOLDER__` patterns. This keeps the codebase dependency-free and makes templates easy to understand. See [Template Rendering](template-rendering.md) for details.

## Execution Pipeline

```bash
┌──────────────────────────────────────────────────┐
│                    00-config.sh                  │
│            (sourced by every other script)       │
└──────────────────────┬───────────────────────────┘
                       │
    ┌──────────────────┼──────────────────┐
    ▼                  ▼                  ▼
┌──────────┐    ┌──────────────┐    ┌──────────────┐
│01-setup  │    │02-setup-file │    │03-setup-block│
│-storage  │    │  -storage.sh │    │  -storage.sh │
│-pools.sh │    │              │    │  (VSI only)  │
└────┬─────┘    └──────┬───────┘    └──────┬───────┘
     │                 │                   │
     └────────┬────────┴───────────────────┘
              ▼
     ┌────────────────┐     ┌──────────────────────────┐
     │ 04-run-tests.sh│────▶│ lib/vm-helpers.sh        │
     │                │     │ lib/wait-helpers.sh      │
     │ (main loop)    │     │ cloud-init/fio-runner    │
     │                │     │ vm-templates/vm-template │
     │                │     │ fio-profiles/*.fio       │
     └───────┬────────┘     └──────────────────────────┘
             │
             ▼
     ┌────────────────┐
     │05-collect      │
     │  -results.sh   │
     └───────┬────────┘
             │
             ▼
     ┌────────────────┐
     │06-generate     │
     │  -report.sh    │
     └───────┬────────┘
             │
             ▼
     ┌────────────────┐
     │07-cleanup.sh   │
     └────────────────┘
```

### Script Responsibilities

| Script | Purpose |
|--------|---------|
| `00-config.sh` | Defines all configuration variables. Validates cluster connectivity on load. Sourced by other scripts, never run directly. |
| `01-setup-storage-pools.sh` | Creates CephBlockPools and StorageClasses for each ODF pool defined in config. |
| `02-setup-file-storage.sh` | Discovers IBM Cloud File CSI StorageClasses on the cluster (or uses the fallback list). |
| `03-setup-block-storage.sh` | Discovers IBM Cloud Block CSI StorageClasses (VSI clusters only). |
| `04-run-tests.sh` | Main orchestrator. Iterates the test matrix, creates VMs once per group, reuses across fio permutations via SSH. Supports `--resume`, `--dry-run`, `--filter`, and `--exclude`. |
| `05-collect-results.sh` | Walks the results directory tree, validates and parses fio JSON files, and produces aggregated CSV. |
| `06-generate-report.sh` | Generates HTML dashboard (Chart.js), Markdown summary, and XLSX workbook from CSV. Supports `--compare` for multi-run comparison reports. |
| `07-cleanup.sh` | Deletes test resources. Default: VMs/PVCs only. `--all`: also pools and namespace. |
| `run-all.sh` | Full pipeline runner (01→07). Passes through test flags to `04-run-tests.sh`. Supports `--notify` for webhook completion notifications. |

## Shared Libraries

### `lib/vm-helpers.sh`

The largest library file, providing:

| Function | Purpose |
|----------|---------|
| `log_debug/info/warn/error` | Logging with timestamps and log levels |
| `ensure_ssh_key` | Generate ed25519 SSH key pair if not present |
| `get_storage_class_for_pool` | Map pool name to StorageClass name |
| `get_all_storage_pools` | Build list of all pools to test (ODF + File CSI) |
| `render_fio_profile` | Substitute `${VARIABLE}` placeholders in .fio files |
| `render_cloud_init` | Substitute `__PLACEHOLDER__` patterns in cloud-init template |
| `create_test_vm` | Render VM manifest and `oc apply`. Fails early if cloud-init Secret creation fails. |
| `wait_for_vm_running` | Poll VMI status until Running, with DV clone progress monitoring, stall detection, and VM failure condition checking |
| `wait_for_fio_completion` | Poll systemd service status via `virtctl ssh` |
| `collect_vm_results` | Copy fio JSON from VM via `virtctl ssh` (60s timeout) |
| `replace_fio_job` | Write new fio job file to a running VM via SSH (base64-encoded, sudo tee, 30s timeout) |
| `restart_fio_service` | Clear old test data/results, stop/reset/start the benchmark service (non-blocking, 30s timeout) |
| `delete_test_vm` | Delete VM, data PVC, root disk PVC, and DataVolume |

All `virtctl ssh` calls are wrapped with `timeout 30` (or `timeout 60` for data transfers) to prevent indefinite hangs on unresponsive VMs.

### `lib/wait-helpers.sh`

Polling and retry utilities:

| Function | Purpose |
|----------|---------|
| `retry_with_backoff` | Generic retry with exponential backoff (2x delay per attempt, configurable max) |
| `wait_for_all_vms_running` | Wait for a list of VMs to all reach Running state |
| `wait_for_all_fio_complete` | Poll-based multi-VM fio completion check; handles `active`/`failed` states for oneshot services with `RemainAfterExit=yes` |
| `wait_for_pvc_bound` | Wait for a PVC to reach Bound state |

### `lib/report-helpers.sh`

Report generation:

| Function | Purpose |
|----------|---------|
| `parse_fio_json_to_csv` | Extract metrics from one fio JSON file into CSV rows via `jq`. Validates JSON structure (non-empty jobs, read/write fields) before parsing. |
| `csv_header` | Output the CSV header row |
| `aggregate_results_csv` | Walk results tree and call `parse_fio_json_to_csv` for each file. Uses process substitution to avoid subshell variable loss. |
| `generate_markdown_report` | Create Markdown with config tables and summary metrics |
| `generate_html_report` | Create HTML dashboard with Chart.js (CSV → JSON → interactive charts) |
| `generate_comparison_report` | Create comparison HTML dashboard from two run CSVs, showing percentage deltas with direction-aware color coding |

## Resource Labeling Strategy

All test resources carry a consistent set of labels:

```yaml
labels:
  app: vm-perf-test                         # Identifies all test resources
  perf-test/run-id: perf-20260214-103000    # Unique per execution
  perf-test/storage-pool: rep3              # Which pool this test used
  perf-test/vm-size: small                  # VM size category
  perf-test/pvc-size: 150Gi                 # PVC size
```

This enables:
- **Targeted cleanup:** `oc delete vm -l app=vm-perf-test` deletes all test VMs
- **Run-specific cleanup:** `-l perf-test/run-id=perf-...` targets a single run
- **Monitoring:** Filter resources by pool, size, or run in the OpenShift console
- **Debugging:** Quickly find resources related to a specific test configuration

## Error Handling

The test suite uses several error-handling strategies:

### Script-Level
- `set -euo pipefail` — Exit on error, undefined variable, or pipe failure
- Trap handler on `INT`/`TERM` to clean up running VMs on interruption. A second signal exits immediately.
- Cluster connectivity check on startup (`oc cluster-info`) prevents confusing failures from unauthenticated sessions

### Per-Test
- Failed VM creation skips the entire group (all profile × block_size permutations)
- Failed cloud-init Secret creation aborts the group immediately (early error check)
- Failed VM startup skips the group and cleans up VMs
- Failed fio replacement/restart for a single permutation skips that permutation but continues to the next
- Failed fio completion logs a warning but still attempts result collection
- Missing fio JSON triggers a fallback collection method via `oc exec`

### Checkpoint / Resume
- After each successful test, the test key is appended to `results/<run-id>.checkpoint`
- `--resume <run-id>` loads the checkpoint and skips completed tests
- If all permutations in a VM group are complete, the entire group is skipped (no VM creation)

### Test Filtering
- `--filter <pattern>` and `--exclude <pattern>` use 6-field colon-separated patterns with `*` wildcards
- `--exclude` takes precedence over `--filter`
- `--dry-run` previews the filtered matrix without creating resources

### Polling
- All wait functions have configurable timeouts (defaults in `00-config.sh`)
- All `virtctl ssh` calls are wrapped with `timeout 30` (60s for data transfers) to prevent hangs
- Timeouts produce error logs with full diagnostic dumps (VMI YAML, DataVolume status, PVC phases, and recent events for both the VM and DV)
- `retry_with_backoff` uses exponential backoff with a configurable max delay

### K8s Resource Names
- Names are truncated to 63 characters (Kubernetes limit) using bash substring (`${var:0:63}`)
- Sanitized to lowercase alphanumeric + hyphens (pure bash, no external commands)
- Trailing hyphens are stripped

## Next Steps

- [Test Matrix Explained](test-matrix-explained.md) — How the main loop works
- [Parallel Execution](parallel-execution.md) — Pool-level dispatch, auto-scaling, and isolation
- [Template Rendering](template-rendering.md) — The rendering pipeline
- [Configuration Reference](../guides/configuration-reference.md) — All config parameters
