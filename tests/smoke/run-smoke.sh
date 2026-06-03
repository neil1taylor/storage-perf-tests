#!/usr/bin/env bash
# tests/smoke/run-smoke.sh — cluster smoke test runner.
# Requires `oc` authenticated to a ROKS cluster with ODF installed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

if ! oc cluster-info &>/dev/null; then
  echo "ERROR: oc is not authenticated. Source .env and re-run."
  exit 2
fi

PASS=0; FAIL=0; SKIP=0
_pass() { PASS=$((PASS+1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
_skip() { SKIP=$((SKIP+1)); echo "  SKIP  $1"; }

# Run all test scripts in tests/smoke/ named *.sh except this one.
for t in tests/smoke/*.sh; do
  [[ "${t}" == "tests/smoke/run-smoke.sh" ]] && continue
  echo "=== ${t} ==="
  if bash "${t}"; then
    _pass "${t}"
  else
    _fail "${t}"
  fi
done

echo
echo "===== ${PASS} passed, ${FAIL} failed, ${SKIP} skipped ====="
exit $(( FAIL > 0 ))
