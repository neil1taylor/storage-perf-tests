#!/usr/bin/env bash
# tests/run-offline.sh — off-cluster test runner for the tune-sweep feature.
# Exits non-zero on any failed assertion. Safe to run without `oc` auth.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PASS=0; FAIL=0
_pass() { PASS=$((PASS+1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# -----------------------------------------------------------------------------
test_tune_configs_parse() {
  echo "test_tune_configs_parse:"
  # Skip live cluster validation: set OC_SKIP_CLUSTER_CHECK so 00-config.sh
  # does not call `oc cluster-info`.
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1

  (( ${#TUNE_CONFIGS[@]} >= 4 )) || { _fail "expected >=4 named configs, got ${#TUNE_CONFIGS[@]}"; return; }
  for name in default cstate-off big-osd big-osd+cstate-off; do
    [[ -v 'TUNE_CONFIGS[$name]' ]] || { _fail "TUNE_CONFIGS[$name] missing"; return; }
  done
  [[ -n "${TUNE_DEFAULT_CONFIGS:-}" ]] || { _fail "TUNE_DEFAULT_CONFIGS unset"; return; }
  [[ -n "${TUNE_QD_LIST:-}" ]]         || { _fail "TUNE_QD_LIST unset"; return; }
  [[ -n "${TUNE_FIXED_VMS:-}" ]]       || { _fail "TUNE_FIXED_VMS unset"; return; }
  [[ -n "${TUNE_MC_NAME:-}" ]]         || { _fail "TUNE_MC_NAME unset"; return; }
  _pass "TUNE_CONFIGS and TUNE_* defaults are declared"
}

# -----------------------------------------------------------------------------
test_parse_tune_config_valid() {
  echo "test_parse_tune_config_valid:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh

  # Each named config parses without error and emits non-empty key=value lines.
  for name in default cstate-off big-osd big-osd+cstate-off; do
    local out
    if ! out=$(parse_tune_config "${name}" 2>&1); then
      _fail "parse_tune_config(${name}) returned non-zero: ${out}"
      return
    fi
    [[ -n "${out}" ]] || { _fail "parse_tune_config(${name}) emitted nothing"; return; }
    echo "${out}" | grep -qE '^cstate=(on|off)$' || { _fail "(${name}) missing cstate"; return; }
  done
  _pass "all named configs parse cleanly"
}

test_parse_tune_config_unknown_name() {
  echo "test_parse_tune_config_unknown_name:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh
  if parse_tune_config "this-name-does-not-exist" >/dev/null 2>&1; then
    _fail "expected non-zero exit on unknown name"
    return
  fi
  _pass "unknown name rejected"
}

test_parse_tune_config_unknown_key() {
  echo "test_parse_tune_config_unknown_key:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh
  # Inject a one-off bad config and confirm it's rejected.
  TUNE_CONFIGS[bad-cfg]='osd_mem_gb=64 cstate=on'
  if parse_tune_config "bad-cfg" >/dev/null 2>&1; then
    _fail "expected non-zero exit on unknown key osd_mem_gb"
    return
  fi
  unset 'TUNE_CONFIGS[bad-cfg]'
  _pass "unknown key rejected"
}

# -----------------------------------------------------------------------------
test_render_cstate_machineconfig() {
  echo "test_render_cstate_machineconfig:"
  OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1
  source lib/tune-helpers.sh

  local tmp
  tmp=$(mktemp -t tune-mc-XXXXXX.yaml)

  if ! render_cstate_machineconfig "${tmp}"; then
    _fail "render_cstate_machineconfig returned non-zero"
    rm -f "${tmp}"
    return
  fi

  # File must exist and be non-empty
  if [[ ! -s "${tmp}" ]]; then
    _fail "rendered MC is empty"
    rm -f "${tmp}"
    return
  fi

  # Must contain expected kernel args and target role=worker
  if ! grep -q "intel_idle.max_cstate=0" "${tmp}"; then
    _fail "missing intel_idle kernel arg"
    rm -f "${tmp}"
    return
  fi
  if ! grep -q "processor.max_cstate=0" "${tmp}"; then
    _fail "missing processor kernel arg"
    rm -f "${tmp}"
    return
  fi
  if ! grep -q "machineconfiguration.openshift.io/role: worker" "${tmp}"; then
    _fail "missing role=worker label"
    rm -f "${tmp}"
    return
  fi
  if ! grep -q "name: ${TUNE_MC_NAME}" "${tmp}"; then
    _fail "missing MC name ${TUNE_MC_NAME}"
    rm -f "${tmp}"
    return
  fi

  # If oc is present, sanity-check the YAML structure with client-side dry-run.
  # NOTE: this errors with "no matches for kind" when the local oc client cache
  # doesn't know about the MachineConfig CRD (common offline). Treat that case
  # as "can't validate" and proceed; only fail on other oc errors.
  if command -v oc &>/dev/null; then
    local oc_out
    if ! oc_out=$(oc apply --dry-run=client -f "${tmp}" 2>&1); then
      if ! echo "${oc_out}" | grep -q "no matches for kind"; then
        _fail "oc client-side validation failed: ${oc_out}"
        rm -f "${tmp}"
        return
      fi
    fi
  fi

  rm -f "${tmp}"
  _pass "rendered MC has expected kernel args and labels"
}

# -----------------------------------------------------------------------------
test_qd_sweep_dry_run() {
  echo "test_qd_sweep_dry_run:"
  local out
  out=$(OC_SKIP_CLUSTER_CHECK=true ./04-run-tests.sh --qd-sweep \
    --pool rep3-virt --fixed-vms 4 --qd-list 1,4 --rate-iops 250 \
    --latency-sla 5 --dry-run 2>&1) || true

  echo "${out}" | grep -q "qd-sweep" || { _fail "no qd-sweep mention in dry-run"; return; }
  echo "${out}" | grep -q "fixed-vms:   4" || { _fail "missing fixed-vms in plan"; return; }
  echo "${out}" | grep -q "qd-list:     1,4" || { _fail "missing qd-list in plan"; return; }
  _pass "qd-sweep dry-run prints expected plan"
}

# -----------------------------------------------------------------------------
test_tune_configs_parse
test_parse_tune_config_valid
test_parse_tune_config_unknown_name
test_parse_tune_config_unknown_key
test_render_cstate_machineconfig
test_qd_sweep_dry_run

echo
echo "===== ${PASS} passed, ${FAIL} failed ====="
exit $(( FAIL > 0 ))
