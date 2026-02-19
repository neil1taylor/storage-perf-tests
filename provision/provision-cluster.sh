#!/usr/bin/env bash
# =============================================================================
# provision/provision-cluster.sh — Standalone IBM Cloud ROKS cluster provisioning
#
# Automates ROKS VPC Gen2 cluster creation with ODF and OpenShift Virtualization
# add-ons. Standalone — does NOT source 00-config.sh (which requires oc
# connectivity that doesn't exist during 'create').
#
# Subcommands:
#   create         Create ROKS VPC Gen2 cluster from env settings
#   enable-addons  Enable ODF and OpenShift Virtualization add-ons
#   status         Show cluster, worker, and add-on status
#   all            Full pipeline: create → wait → enable-addons → configure oc
#
# Usage:
#   ./provision-cluster.sh create --tier standard --yes
#   ./provision-cluster.sh enable-addons
#   ./provision-cluster.sh status
#   ./provision-cluster.sh all --tier full --env ./my-cluster.env
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Colour output (disabled when not a terminal or NO_COLOR is set)
# ---------------------------------------------------------------------------
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  _RED='\033[0;31m'
  _GREEN='\033[0;32m'
  _YELLOW='\033[0;33m'
  _BLUE='\033[0;34m'
  _CYAN='\033[0;36m'
  _BOLD='\033[1m'
  _RESET='\033[0m'
else
  _RED='' _GREEN='' _YELLOW='' _BLUE='' _CYAN='' _BOLD='' _RESET=''
fi

# ---------------------------------------------------------------------------
# Logging (replicates lib/vm-helpers.sh pattern with colour)
# ---------------------------------------------------------------------------
_log() {
  local level="$1" colour="$2"; shift 2
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo -e "${colour}[${ts}] [${level}]${_RESET} $*" >&2
}

log_info()  { _log "INFO"  "${_GREEN}"  "$@"; }
log_warn()  { _log "WARN"  "${_YELLOW}" "$@"; }
log_error() { _log "ERROR" "${_RED}"    "$@"; }
log_step()  { _log "STEP"  "${_CYAN}"   "$@"; }

_format_duration() {
  local seconds="$1"
  if [[ ${seconds} -ge 3600 ]]; then
    printf '%dh%02dm%02ds' $((seconds/3600)) $((seconds%3600/60)) $((seconds%60))
  elif [[ ${seconds} -ge 60 ]]; then
    printf '%dm%02ds' $((seconds/60)) $((seconds%60))
  else
    printf '%ds' "${seconds}"
  fi
}

# ---------------------------------------------------------------------------
# Tier presets (from docs/guides/vsi-storage-testing-guide.md)
# ---------------------------------------------------------------------------
declare -A TIER_FLAVOR=(
  [standard]="bx3d-32x160"
  [full]="bx3d-32x160"
  [max-throughput]="bx2-48x192"
)
declare -A TIER_WORKERS=(
  [standard]=3
  [full]=6
  [max-throughput]=6
)
declare -A TIER_OSD_SIZE=(
  [standard]="1Ti"
  [full]="1Ti"
  [max-throughput]="2Ti"
)
declare -A TIER_NUM_OSD=(
  [standard]=1
  [full]=1
  [max-throughput]=2
)
declare -A TIER_DESCRIPTION=(
  [standard]="3× bx3d-32x160, 1×1Ti OSD — rep2/3, ec-2-1, cephfs"
  [full]="6× bx3d-32x160, 1×1Ti OSD — all pools incl ec-4-2"
  [max-throughput]="6× bx2-48x192, 2×2Ti OSD — all pools, highest IOPS"
)
VALID_TIERS="standard full max-throughput"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/cluster.env"
SKIP_CONFIRM=false
TIER_OVERRIDE=""

# ---------------------------------------------------------------------------
# Signal handler
# ---------------------------------------------------------------------------
trap '_on_signal' INT TERM
_on_signal() {
  log_warn "Interrupted — cluster creation may still be in progress on IBM Cloud"
  log_warn "Run '$(basename "$0") status' to check, or delete via IBM Cloud console"
  exit 130
}

# ---------------------------------------------------------------------------
# Parse global flags + subcommand
# ---------------------------------------------------------------------------
SUBCOMMAND=""

usage() {
  cat <<'USAGE'
Usage: provision-cluster.sh [OPTIONS] <COMMAND>

Commands:
  create          Create ROKS VPC Gen2 cluster from env settings
  enable-addons   Enable ODF and OpenShift Virtualization add-ons
  status          Show cluster, worker, and add-on status
  all             Full pipeline: create → wait → enable-addons → configure oc

Options:
  --tier <name>   Deployment tier: standard, full, max-throughput
  --env <path>    Path to env file (default: provision/cluster.env)
  --yes, -y       Skip confirmation prompts
  --help, -h      Show this help

Tier presets:
  standard        3× bx3d-32x160, 1×1Ti OSD  (rep2/3, ec-2-1, cephfs)
  full            6× bx3d-32x160, 1×1Ti OSD  (all pools incl ec-4-2)
  max-throughput  6× bx2-48x192,  2×2Ti OSD  (all pools, highest IOPS)

Examples:
  ./provision-cluster.sh create --tier standard --yes
  ./provision-cluster.sh all --tier full --env ./my-cluster.env
  ./provision-cluster.sh status
USAGE
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)
      TIER_OVERRIDE="$2"
      if [[ ! " ${VALID_TIERS} " =~ [[:space:]]${TIER_OVERRIDE}[[:space:]] ]]; then
        log_error "Invalid tier '${TIER_OVERRIDE}'. Valid: ${VALID_TIERS}"
        exit 1
      fi
      shift 2
      ;;
    --env)       ENV_FILE="$2"; shift 2 ;;
    --yes|-y)    SKIP_CONFIRM=true; shift ;;
    --help|-h)   usage ;;
    -*)
      log_error "Unknown option: $1"
      exit 1
      ;;
    *)
      SUBCOMMAND="$1"; shift
      break
      ;;
  esac
done

if [[ -z "${SUBCOMMAND}" ]]; then
  log_error "No subcommand specified"
  usage
fi

# ---------------------------------------------------------------------------
# Prerequisites checks
# ---------------------------------------------------------------------------
check_ibmcloud() {
  if ! command -v ibmcloud &>/dev/null; then
    log_error "ibmcloud CLI not found — install from https://cloud.ibm.com/docs/cli"
    exit 1
  fi
  if ! command -v jq &>/dev/null; then
    log_error "jq not found — install with: brew install jq"
    exit 1
  fi
  # Check authentication
  if ! ibmcloud target --output json &>/dev/null; then
    log_error "ibmcloud CLI not authenticated — run 'ibmcloud login' first"
    exit 1
  fi
  # Check container-service plugin
  if ! ibmcloud plugin show container-service &>/dev/null; then
    log_error "container-service plugin not installed — run: ibmcloud plugin install container-service"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Load env file and resolve tier defaults
# ---------------------------------------------------------------------------
load_env() {
  if [[ -f "${ENV_FILE}" ]]; then
    log_info "Loading env from: ${ENV_FILE}"
    # Source in a subshell-safe way: only export non-comment, non-empty lines
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  else
    log_warn "Env file not found: ${ENV_FILE} — using defaults"
  fi

  # CLI --tier overrides env file
  if [[ -n "${TIER_OVERRIDE}" ]]; then
    DEPLOYMENT_TIER="${TIER_OVERRIDE}"
  fi

  : "${DEPLOYMENT_TIER:=standard}"

  if [[ ! " ${VALID_TIERS} " =~ [[:space:]]${DEPLOYMENT_TIER}[[:space:]] ]]; then
    log_error "Invalid DEPLOYMENT_TIER='${DEPLOYMENT_TIER}'. Valid: ${VALID_TIERS}"
    exit 1
  fi

  # Resolve: explicit env vars > tier defaults (only fill empty values)
  : "${WORKER_FLAVOR:=${TIER_FLAVOR[${DEPLOYMENT_TIER}]}}"
  : "${WORKER_COUNT:=${TIER_WORKERS[${DEPLOYMENT_TIER}]}}"
  : "${ODF_OSD_SIZE:=${TIER_OSD_SIZE[${DEPLOYMENT_TIER}]}}"
  : "${ODF_NUM_OF_OSD:=${TIER_NUM_OSD[${DEPLOYMENT_TIER}]}}"

  # Other defaults
  : "${WORKER_POOL_NAME:=default}"
  : "${ODF_OSD_STORAGE_CLASS:=ibmc-vpc-block-metro-10iops-tier}"
  : "${ODF_RESOURCE_PROFILE:=performance}"
  : "${ODF_BILLING_TYPE:=essentials}"
  : "${CNV_ENABLED:=true}"
  : "${CLUSTER_READY_TIMEOUT:=3600}"
  : "${CLUSTER_POLL_INTERVAL:=60}"
  : "${ADDON_READY_TIMEOUT:=1800}"
  : "${ADDON_POLL_INTERVAL:=30}"
}

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------
confirm() {
  local msg="$1"
  if [[ "${SKIP_CONFIRM}" == true ]]; then
    return 0
  fi
  echo -e "\n${_BOLD}${msg}${_RESET}" >&2
  read -rp "Continue? [y/N] " response
  case "${response}" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) log_info "Aborted by user"; exit 0 ;;
  esac
}

# =============================================================================
# SUBCOMMAND: create
# =============================================================================
cmd_create() {
  check_ibmcloud
  load_env

  log_step "Preparing to create ROKS cluster..."

  # Validate required fields
  local missing=()
  [[ -z "${CLUSTER_NAME:-}" ]]    && missing+=("CLUSTER_NAME")
  [[ -z "${ZONE:-}" ]]            && missing+=("ZONE")
  [[ -z "${VPC_ID:-}" ]]          && missing+=("VPC_ID")
  [[ -z "${SUBNET_ID:-}" ]]       && missing+=("SUBNET_ID")
  [[ -z "${COS_INSTANCE_ID:-}" ]] && missing+=("COS_INSTANCE_ID")

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required configuration: ${missing[*]}"
    log_error "Set these in ${ENV_FILE}"
    exit 1
  fi

  # Resolve OpenShift version if not set
  if [[ -z "${OPENSHIFT_VERSION:-}" ]]; then
    log_info "OPENSHIFT_VERSION not set — resolving latest stable..."
    OPENSHIFT_VERSION=$(ibmcloud oc versions --output json 2>/dev/null \
      | jq -r '.openshift[] | select(.default == true) | .major + "." + .minor + "_openshift"' 2>/dev/null \
      || echo "")
    if [[ -z "${OPENSHIFT_VERSION}" ]]; then
      # Fallback: pick the last version in the list
      OPENSHIFT_VERSION=$(ibmcloud oc versions --output json 2>/dev/null \
        | jq -r '.openshift[-1] | .major + "." + .minor + "_openshift"' 2>/dev/null \
        || echo "")
    fi
    if [[ -z "${OPENSHIFT_VERSION}" ]]; then
      log_error "Could not determine OpenShift version — set OPENSHIFT_VERSION in ${ENV_FILE}"
      exit 1
    fi
    log_info "Resolved OpenShift version: ${OPENSHIFT_VERSION}"
  fi

  # Print summary
  echo "" >&2
  echo -e "${_BOLD}Cluster creation summary:${_RESET}" >&2
  echo -e "  Tier:           ${DEPLOYMENT_TIER} — ${TIER_DESCRIPTION[${DEPLOYMENT_TIER}]}" >&2
  echo -e "  Name:           ${CLUSTER_NAME}" >&2
  echo -e "  Version:        ${OPENSHIFT_VERSION}" >&2
  echo -e "  VPC:            ${VPC_ID}" >&2
  echo -e "  Zone:           ${ZONE}" >&2
  echo -e "  Subnet:         ${SUBNET_ID}" >&2
  echo -e "  Workers:        ${WORKER_COUNT}× ${WORKER_FLAVOR}" >&2
  echo -e "  COS Instance:   ${COS_INSTANCE_ID}" >&2
  echo "" >&2

  confirm "This will create a ROKS cluster (may take 30-45 minutes)."

  # Create cluster
  log_step "Creating ROKS VPC Gen2 cluster '${CLUSTER_NAME}'..."
  ibmcloud oc cluster create vpc-gen2 \
    --name "${CLUSTER_NAME}" \
    --zone "${ZONE}" \
    --vpc-id "${VPC_ID}" \
    --subnet-id "${SUBNET_ID}" \
    --flavor "${WORKER_FLAVOR}" \
    --workers "${WORKER_COUNT}" \
    --version "${OPENSHIFT_VERSION}" \
    --cos-instance-id "${COS_INSTANCE_ID}" \
    --worker-pool-name "${WORKER_POOL_NAME}"

  log_info "Cluster creation initiated — waiting for state=normal..."

  # Poll until ready
  local start_time elapsed state
  start_time=$(date +%s)

  while true; do
    elapsed=$(( $(date +%s) - start_time ))
    if [[ ${elapsed} -ge ${CLUSTER_READY_TIMEOUT} ]]; then
      log_error "Timeout waiting for cluster (${CLUSTER_READY_TIMEOUT}s)"
      log_error "Run '$(basename "$0") status' to check progress"
      exit 1
    fi

    state=$(ibmcloud oc cluster get --cluster "${CLUSTER_NAME}" --output json 2>/dev/null \
      | jq -r '.state // empty' || echo "")

    case "${state}" in
      normal)
        log_info "Cluster '${CLUSTER_NAME}' is ready ($(_format_duration ${elapsed}))"
        break
        ;;
      critical|delete_failed)
        log_error "Cluster entered terminal state: ${state}"
        exit 1
        ;;
      *)
        log_info "State: ${state:-unknown} ($(_format_duration ${elapsed}) elapsed, polling every ${CLUSTER_POLL_INTERVAL}s)"
        sleep "${CLUSTER_POLL_INTERVAL}"
        ;;
    esac
  done

  # Configure oc
  log_step "Configuring oc CLI..."
  ibmcloud oc cluster config --cluster "${CLUSTER_NAME}" --admin
  log_info "oc configured — verify with: oc cluster-info"
}

# =============================================================================
# SUBCOMMAND: enable-addons
# =============================================================================
cmd_enable_addons() {
  check_ibmcloud
  load_env

  if [[ -z "${CLUSTER_NAME:-}" ]]; then
    log_error "CLUSTER_NAME not set in ${ENV_FILE}"
    exit 1
  fi

  # --- ODF ---
  log_step "Enabling ODF add-on..."
  local odf_state
  odf_state=$(ibmcloud oc cluster addon ls --cluster "${CLUSTER_NAME}" --output json 2>/dev/null \
    | jq -r '.[] | select(.name == "openshift-data-foundation") | .healthState // empty' || echo "")

  if [[ "${odf_state}" == "normal" ]]; then
    log_info "ODF add-on already enabled and healthy — skipping"
  else
    local odf_params=(
      --param "osdStorageClassName=${ODF_OSD_STORAGE_CLASS}"
      --param "osdSize=${ODF_OSD_SIZE}"
      --param "numOfOsd=${ODF_NUM_OF_OSD}"
      --param "resourceProfile=${ODF_RESOURCE_PROFILE}"
    )
    if [[ -n "${ODF_BILLING_TYPE:-}" ]]; then
      odf_params+=(--param "odfDeploy=${ODF_BILLING_TYPE}")
    fi

    ibmcloud oc cluster addon enable openshift-data-foundation \
      --cluster "${CLUSTER_NAME}" \
      "${odf_params[@]}"

    log_info "ODF add-on enable requested — waiting for healthy state..."
    _wait_addon "openshift-data-foundation"

    # Verify ODF health via oc if available
    if command -v oc &>/dev/null && oc cluster-info &>/dev/null; then
      log_info "Checking Ceph cluster health..."
      local ceph_health
      ceph_health=$(oc get cephcluster -n openshift-storage -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null || echo "unknown")
      log_info "Ceph cluster health: ${ceph_health}"
    fi
  fi

  # --- CNV ---
  if [[ "${CNV_ENABLED}" == "true" ]]; then
    log_step "Enabling OpenShift Virtualization add-on..."
    local cnv_state
    cnv_state=$(ibmcloud oc cluster addon ls --cluster "${CLUSTER_NAME}" --output json 2>/dev/null \
      | jq -r '.[] | select(.name == "openshift-virtualization") | .healthState // empty' || echo "")

    if [[ "${cnv_state}" == "normal" ]]; then
      log_info "OpenShift Virtualization add-on already enabled and healthy — skipping"
    else
      ibmcloud oc cluster addon enable openshift-virtualization \
        --cluster "${CLUSTER_NAME}"

      log_info "CNV add-on enable requested — waiting for healthy state..."
      _wait_addon "openshift-virtualization"
    fi
  else
    log_info "OpenShift Virtualization disabled (CNV_ENABLED=false) — skipping"
  fi

  echo "" >&2
  log_info "Add-ons configured. Next steps:"
  echo -e "  1. cd ${REPO_DIR}" >&2
  echo -e "  2. ./run-all.sh --quick          # Smoke test" >&2
  echo -e "  3. ./run-all.sh --rank            # Rank StorageClasses" >&2
}

_wait_addon() {
  local addon_name="$1"
  local start_time elapsed state
  start_time=$(date +%s)

  while true; do
    elapsed=$(( $(date +%s) - start_time ))
    if [[ ${elapsed} -ge ${ADDON_READY_TIMEOUT} ]]; then
      log_error "Timeout waiting for add-on '${addon_name}' (${ADDON_READY_TIMEOUT}s)"
      exit 1
    fi

    state=$(ibmcloud oc cluster addon ls --cluster "${CLUSTER_NAME}" --output json 2>/dev/null \
      | jq -r --arg name "${addon_name}" '.[] | select(.name == $name) | .healthState // empty' || echo "")

    case "${state}" in
      normal)
        log_info "Add-on '${addon_name}' is healthy ($(_format_duration ${elapsed}))"
        return 0
        ;;
      critical)
        log_error "Add-on '${addon_name}' entered critical state"
        exit 1
        ;;
      *)
        log_info "Add-on '${addon_name}': ${state:-pending} ($(_format_duration ${elapsed}) elapsed)"
        sleep "${ADDON_POLL_INTERVAL}"
        ;;
    esac
  done
}

# =============================================================================
# SUBCOMMAND: status
# =============================================================================
cmd_status() {
  check_ibmcloud
  load_env

  if [[ -z "${CLUSTER_NAME:-}" ]]; then
    log_error "CLUSTER_NAME not set in ${ENV_FILE}"
    exit 1
  fi

  echo -e "\n${_BOLD}=== Cluster Status ===${_RESET}" >&2

  # Cluster
  local cluster_json state version ingress
  cluster_json=$(ibmcloud oc cluster get --cluster "${CLUSTER_NAME}" --output json 2>/dev/null || echo "{}")
  state=$(echo "${cluster_json}" | jq -r '.state // "unknown"')
  version=$(echo "${cluster_json}" | jq -r '.masterKubeVersion // .openshiftVersion // "unknown"')
  ingress=$(echo "${cluster_json}" | jq -r '.ingressHostname // .ingress.hostname // "n/a"')

  local state_colour="${_GREEN}"
  [[ "${state}" == "deploying" || "${state}" == "pending" ]] && state_colour="${_YELLOW}"
  [[ "${state}" == "critical" || "${state}" == "delete_failed" ]] && state_colour="${_RED}"

  echo -e "\n${_BOLD}Cluster:${_RESET}  ${CLUSTER_NAME}" >&2
  echo -e "  State:      ${state_colour}${state}${_RESET}" >&2
  echo -e "  Version:    ${version}" >&2
  echo -e "  Ingress:    ${ingress}" >&2
  echo -e "  Tier:       ${DEPLOYMENT_TIER} — ${TIER_DESCRIPTION[${DEPLOYMENT_TIER}]}" >&2

  # Workers
  echo -e "\n${_BOLD}Workers:${_RESET}" >&2
  local workers_json
  workers_json=$(ibmcloud oc worker ls --cluster "${CLUSTER_NAME}" --output json 2>/dev/null || echo "[]")
  local total_workers ready_workers
  total_workers=$(echo "${workers_json}" | jq -r 'length')
  ready_workers=$(echo "${workers_json}" | jq -r '[.[] | select(.health.state == "normal" or .status == "Ready")] | length')

  echo -e "  Count:      ${ready_workers}/${total_workers} ready" >&2
  echo -e "  Flavor:     ${WORKER_FLAVOR}" >&2

  # Per-worker status
  echo "${workers_json}" | jq -r '.[] | "  \(.id[:12])  \(.machineType // .flavor)  \(.location)  \(.health.state // .status)"' 2>/dev/null >&2 || true

  # Add-ons
  echo -e "\n${_BOLD}Add-ons:${_RESET}" >&2
  local addons_json
  addons_json=$(ibmcloud oc cluster addon ls --cluster "${CLUSTER_NAME}" --output json 2>/dev/null || echo "[]")

  local addon_name addon_version addon_state addon_colour
  for addon in "openshift-data-foundation" "openshift-virtualization"; do
    addon_name="${addon}"
    addon_version=$(echo "${addons_json}" | jq -r --arg n "${addon}" '.[] | select(.name == $n) | .version // empty')
    addon_state=$(echo "${addons_json}" | jq -r --arg n "${addon}" '.[] | select(.name == $n) | .healthState // empty')

    if [[ -z "${addon_version}" ]]; then
      echo -e "  ${addon_name}: ${_YELLOW}not installed${_RESET}" >&2
    else
      addon_colour="${_GREEN}"
      [[ "${addon_state}" != "normal" ]] && addon_colour="${_YELLOW}"
      [[ "${addon_state}" == "critical" ]] && addon_colour="${_RED}"
      echo -e "  ${addon_name}: ${addon_colour}${addon_state}${_RESET} (v${addon_version})" >&2
    fi
  done

  echo "" >&2
}

# =============================================================================
# SUBCOMMAND: all
# =============================================================================
cmd_all() {
  local pipeline_start
  pipeline_start=$(date +%s)

  log_step "=== Full Provisioning Pipeline ==="

  # create
  cmd_create

  # enable-addons (reload env in case create updated it)
  cmd_enable_addons

  local elapsed
  elapsed=$(( $(date +%s) - pipeline_start ))
  echo "" >&2
  log_info "=== Pipeline complete ($(_format_duration ${elapsed})) ==="
  log_info "Cluster '${CLUSTER_NAME}' is ready with ODF and CNV"
  echo "" >&2
  echo -e "${_BOLD}Next steps:${_RESET}" >&2
  echo -e "  cd ${REPO_DIR}" >&2
  echo -e "  ./run-all.sh --quick          # Smoke test" >&2
  echo -e "  ./run-all.sh --rank            # Rank StorageClasses (~1-1.5h)" >&2
  echo -e "  ./run-all.sh                   # Full test matrix (12-24h)" >&2
}

# =============================================================================
# Dispatch subcommand
# =============================================================================
case "${SUBCOMMAND}" in
  create)        cmd_create ;;
  enable-addons) cmd_enable_addons ;;
  status)        cmd_status ;;
  all)           cmd_all ;;
  *)
    log_error "Unknown subcommand: ${SUBCOMMAND}"
    usage
    ;;
esac
