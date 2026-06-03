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
test_tune_configs_parse

echo
echo "===== ${PASS} passed, ${FAIL} failed ====="
exit $(( FAIL > 0 ))
