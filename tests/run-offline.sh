#!/usr/bin/env bash
# tests/run-offline.sh — off-cluster test runner for the tune-sweep feature.
# Exits non-zero on any failed assertion. Safe to run without `oc` auth.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PASS=0; FAIL=0
_pass() { PASS=$((PASS+1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# Skip live cluster validation: set OC_SKIP_CLUSTER_CHECK so 00-config.sh
# does not call `oc cluster-info`.
OC_SKIP_CLUSTER_CHECK=true source 00-config.sh >/dev/null 2>&1

# Test 1: Parse TUNE_CONFIGS and defaults
test_tune_configs_parse() {
  echo "test_tune_configs_parse:"

  # Check array length (more reliable than [[ -v ]] for associative arrays)
  (( ${#TUNE_CONFIGS[@]} >= 4 )) || { _fail "expected >=4 named configs, got ${#TUNE_CONFIGS[@]}"; return 1; }

  for name in default cstate-off big-osd big-osd+cstate-off; do
    [[ -n "${TUNE_CONFIGS[$name]:-}" ]] || { _fail "TUNE_CONFIGS[$name] missing"; return 1; }
  done

  [[ -n "${TUNE_DEFAULT_CONFIGS:-}" ]] || { _fail "TUNE_DEFAULT_CONFIGS unset"; return 1; }
  [[ -n "${TUNE_QD_LIST:-}" ]]         || { _fail "TUNE_QD_LIST unset"; return 1; }
  [[ -n "${TUNE_FIXED_VMS:-}" ]]       || { _fail "TUNE_FIXED_VMS unset"; return 1; }
  [[ -n "${TUNE_MC_NAME:-}" ]]         || { _fail "TUNE_MC_NAME unset"; return 1; }

  _pass "TUNE_CONFIGS and TUNE_* defaults are declared"
}

# Run tests
test_tune_configs_parse

echo
echo "===== ${PASS} passed, ${FAIL} failed ====="
exit $(( FAIL > 0 ))
