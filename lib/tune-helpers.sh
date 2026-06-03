#!/usr/bin/env bash
# =============================================================================
# lib/tune-helpers.sh — ODF tune-sweep cluster-mutation primitives
# =============================================================================
# All functions in this file are sourced; none should be invoked at source
# time. Functions return 0 on success, non-zero on failure, and log via the
# standard log_* helpers from lib/vm-helpers.sh (which must be sourced first
# by any consuming script).
# =============================================================================

# Recognised keys in TUNE_CONFIGS values.
TUNE_VALID_KEYS=(profile osd_cpu osd_mem cstate)

# ---------------------------------------------------------------------------
# parse_tune_config <name>
#   Resolves a name from TUNE_CONFIGS and emits its canonical key=value form
#   on stdout, one pair per line. Validates that every key is in
#   TUNE_VALID_KEYS and that cstate ∈ {on, off}.
# ---------------------------------------------------------------------------
parse_tune_config() {
  local name="$1"
  if ! [[ -v 'TUNE_CONFIGS[$name]' ]]; then
    {
      echo "ERROR: unknown tune config: '${name}'"
      echo "Available: ${!TUNE_CONFIGS[*]}"
    } >&2
    return 1
  fi

  local raw="${TUNE_CONFIGS[$name]}"
  local -a out=()
  local kv key value
  for kv in ${raw}; do
    if [[ "${kv}" != *=* ]]; then
      echo "ERROR: malformed key=value in TUNE_CONFIGS[${name}]: '${kv}'" >&2
      return 1
    fi
    key="${kv%%=*}"
    value="${kv#*=}"

    local valid=0
    local v
    for v in "${TUNE_VALID_KEYS[@]}"; do
      [[ "${v}" == "${key}" ]] && valid=1 && break
    done
    if (( valid == 0 )); then
      {
        echo "ERROR: unknown key '${key}' in TUNE_CONFIGS[${name}]"
        echo "Valid keys: ${TUNE_VALID_KEYS[*]}"
      } >&2
      return 1
    fi

    if [[ "${key}" == "cstate" && "${value}" != "on" && "${value}" != "off" ]]; then
      echo "ERROR: cstate must be 'on' or 'off' (got '${value}') in TUNE_CONFIGS[${name}]" >&2
      return 1
    fi

    out+=("${key}=${value}")
  done

  # Ensure cstate is always present (defaults to 'on' if omitted).
  local has_cstate=0
  local entry
  for entry in "${out[@]}"; do
    [[ "${entry}" == cstate=* ]] && has_cstate=1 && break
  done
  (( has_cstate == 0 )) && out+=("cstate=on")

  printf '%s\n' "${out[@]}"
}
