#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BIN_DIR="${SCRIPT_DIR}/.bin"
PROBE_SRC="${SCRIPT_DIR}/focus_probe.swift"
PROBE_BIN="${BIN_DIR}/focus_probe"

TIER="all"
ALLOW_UNBUILT=0
STRICT=0
JSON_OUT=""
PATTERN=""
VERBOSITY=2
NO_BATON=0

usage() {
  cat <<'EOF'
Usage: run_e2e.sh [options]

Options:
  --tier <0|1|2|3|4|5|all> Select tier(s) to run (default: all)
  --allow-unbuilt          Exit 0 when SKIP_UNBUILT > 0 and FAIL == 0
  --strict                 Treat SKIP_UNBUILT as FAIL (same as HELM_E2E_STRICT=1)
  --json-out <path>        Write JSON summary report to <path> (default: e2e/.reports/latest.json)
  --no-baton               Run swiftc/python3 directly without wrapping in baton
  -k, --pattern <substr>   Filter test IDs by substring
  -v, --verbose            Increase verbosity
  -h, --help               Show this help message

Exit codes:
  0  All tests PASS (or FAIL == 0 with --allow-unbuilt)
  1  One or more tests FAIL or ERROR
  2  FAIL == 0 but SKIP_UNBUILT > 0 (without --allow-unbuilt)
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --tier)
      (( $# >= 2 )) || { echo "Missing value for --tier" >&2; exit 1; }
      TIER="$2"
      shift 2
      ;;
    --allow-unbuilt)
      ALLOW_UNBUILT=1
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --json-out)
      (( $# >= 2 )) || { echo "Missing value for --json-out" >&2; exit 1; }
      JSON_OUT="$2"
      shift 2
      ;;
    --no-baton)
      NO_BATON=1
      shift
      ;;
    -k|--pattern)
      (( $# >= 2 )) || { echo "Missing value for $1" >&2; exit 1; }
      PATTERN="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSITY=$((VERBOSITY + 1))
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

run_with_baton() {
  if (( NO_BATON == 0 )) \
    && [[ "${BATON:-on}" != "off" ]] \
    && [[ "${HELM_IN_BATON:-0}" != "1" ]] \
    && [[ -z "${_BATON_LANES:-}" ]] \
    && command -v baton >/dev/null 2>&1; then
    HELM_IN_BATON=1 baton run --lane auto -- "$@"
  else
    "$@"
  fi
}

mkdir -p "${BIN_DIR}" "${SCRIPT_DIR}/.reports"

if [[ ! -x "${PROBE_BIN}" || "${PROBE_SRC}" -nt "${PROBE_BIN}" ]]; then
  echo "Compiling focus_probe.swift -> ${PROBE_BIN}..."
  run_with_baton swiftc -O "${PROBE_SRC}" -o "${PROBE_BIN}"
fi

typeset -a PY_ARGS
PY_ARGS=("${SCRIPT_DIR}/e2e_common.py" --tier "${TIER}")
if (( ALLOW_UNBUILT == 1 )); then
  PY_ARGS+=(--allow-unbuilt)
fi
if (( STRICT == 1 )); then
  PY_ARGS+=(--strict)
fi
if [[ -n "${JSON_OUT}" ]]; then
  PY_ARGS+=(--json-out "${JSON_OUT}")
fi
if [[ -n "${PATTERN}" ]]; then
  PY_ARGS+=(--pattern "${PATTERN}")
fi

export PYTHONPATH="${SCRIPT_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
set +e
run_with_baton python3 "${PY_ARGS[@]}"
RC=$?
set -e
exit "${RC}"
