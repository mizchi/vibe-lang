#!/usr/bin/env bash
# viberun one-shot vs --daemon output parity gate.
#
# Validates that running the same check command via the new daemon
# protocol produces byte-identical output to launching viberun
# fresh each invocation. This is the safety net for #400's daemon
# mode (warm-instance reuse): if daemon-mode `_start` calls don't
# behave identically to fresh-process ones, this catches it before
# users see stale-cache bugs.
#
# Usage:
#   scripts/test_moonrun_wt_daemon_parity.sh [case ...]
# Env:
#   VIBE_PARITY_WASM_PROFILE   debug | release | opt   (default: opt fallback debug)
#   VIBE_PARITY_CASES_FILE     case list (default: bench/perf/cases.txt)
#   VIBE_PARITY_KEEP_TMP=1     don't clean staged outputs (debug)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

WT_BIN="${MOONRUN_WT_BIN:-$PROJECT_ROOT/runtime/viberun/target/release/viberun}"
if [ ! -x "$WT_BIN" ]; then
  echo "[daemon-parity] building viberun..."
  (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >&2)
fi
if [ ! -x "$WT_BIN" ]; then
  echo "test-moonrun-wt-daemon-parity: viberun build did not produce $WT_BIN" >&2
  exit 1
fi

resolve_check_wasm() {
  local profile="$1"
  case "$profile" in
    opt)
      local p="$PROJECT_ROOT/_build/wasm/opt/vibe_check_wasi.wasm"
      [ -f "$p" ] && echo "$p" && return 0
      ;;
    release)
      echo "$PROJECT_ROOT/_build/wasm/release/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm"
      return 0
      ;;
    debug)
      echo "$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_check_wasi/vibe_check_wasi.wasm"
      return 0
      ;;
  esac
  return 1
}

PROFILE="${VIBE_PARITY_WASM_PROFILE:-opt}"
CHECK_WASM="$(resolve_check_wasm "$PROFILE" || true)"
if [ -z "${CHECK_WASM:-}" ] || [ ! -f "$CHECK_WASM" ]; then
  for p in opt release debug; do
    CHECK_WASM="$(resolve_check_wasm "$p" || true)"
    if [ -n "${CHECK_WASM:-}" ] && [ -f "$CHECK_WASM" ]; then
      PROFILE="$p"
      break
    fi
  done
fi
if [ -z "${CHECK_WASM:-}" ] || [ ! -f "$CHECK_WASM" ]; then
  echo "test-moonrun-wt-daemon-parity: no stage1 check wasm found" >&2
  exit 1
fi

# Use cwasm if available (daemon precompiles internally; one-shot path
# benefits too). Generate if missing.
CWASM="${CHECK_WASM%.wasm}.cwasm"
if [ ! -f "$CWASM" ] || [ "$CHECK_WASM" -nt "$CWASM" ]; then
  "$WT_BIN" --precompile "$CHECK_WASM" -o "$CWASM" >&2
fi

CASES_FILE="${VIBE_PARITY_CASES_FILE:-$PROJECT_ROOT/bench/perf/cases.txt}"
cases=()
if [ "$#" -gt 0 ]; then
  cases=("$@")
else
  while IFS= read -r row; do
    row="${row#"${row%%[![:space:]]*}"}"
    [ -z "$row" ] && continue
    case "$row" in
      \#*) continue ;;
    esac
    cases+=("$row")
  done < "$CASES_FILE"
fi

if [ "${#cases[@]}" -eq 0 ]; then
  echo "test-moonrun-wt-daemon-parity: no cases" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/viberun_daemon_parity.XXXXXX)"
cleanup() {
  [ -n "${VIBE_PARITY_KEEP_TMP:-}" ] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "[daemon-parity] profile=${PROFILE} wasm=${CWASM#${PROJECT_ROOT}/}"
echo "[daemon-parity] cases=${#cases[@]}"

# --- one-shot pass ---
echo "[daemon-parity] running one-shot..."
for case_rel in "${cases[@]}"; do
  case_path="$PROJECT_ROOT/$case_rel"
  if [ ! -f "$case_path" ]; then
    echo "[daemon-parity] SKIP $case_rel (not found)" >&2
    continue
  fi
  safe="$(echo "$case_rel" | tr '/: ' '___')"
  out="$TMP_DIR/${safe}.oneshot.out"
  if ! "$WT_BIN" "$CWASM" --check "$case_path" > "$out" 2>"$TMP_DIR/$safe.oneshot.stderr"; then
    echo "[daemon-parity] one-shot FAIL on $case_rel; see $TMP_DIR/$safe.oneshot.stderr" >&2
    exit 1
  fi
done

# --- daemon pass: feed all cases through one viberun process ---
echo "[daemon-parity] running daemon..."
REQ_FILE="$TMP_DIR/requests.jsonl"
: > "$REQ_FILE"
for case_rel in "${cases[@]}"; do
  case_path="$PROJECT_ROOT/$case_rel"
  [ ! -f "$case_path" ] && continue
  # Encode args as JSON array. Use python (always available) for safe quoting.
  python3 -c "import json,sys; print(json.dumps({'args':['--check', sys.argv[1]]}))" "$case_path" >> "$REQ_FILE"
done

RESP_FILE="$TMP_DIR/responses.jsonl"
if ! "$WT_BIN" --daemon "$CWASM" < "$REQ_FILE" > "$RESP_FILE" 2>"$TMP_DIR/daemon.stderr"; then
  echo "[daemon-parity] daemon FAIL; see $TMP_DIR/daemon.stderr" >&2
  cat "$TMP_DIR/daemon.stderr" >&2
  exit 1
fi

# Split each response's "stdout" field into per-case files.
python3 - <<PY
import json, os, sys
tmp = "$TMP_DIR"
cases = $(printf '"%s",' "${cases[@]}" | sed 's/,$//' | awk '{print "["$0"]"}')
with open(os.path.join(tmp, "responses.jsonl")) as f:
    for i, line in enumerate(f):
        if not line.strip(): continue
        d = json.loads(line)
        case_rel = cases[i]
        safe = case_rel.replace('/', '_').replace(':', '_').replace(' ', '_')
        out = os.path.join(tmp, f"{safe}.daemon.out")
        with open(out, 'w') as o:
            o.write(d.get('stdout', ''))
        if d.get('exit_code', 0) != 0 or 'error' in d:
            sys.stderr.write(f"[daemon-parity] req {i+1} ({case_rel}) error: exit={d.get('exit_code')} err={d.get('error','?')}\n")
            sys.exit(1)
PY

# --- compare ---
fail=0
for case_rel in "${cases[@]}"; do
  case_path="$PROJECT_ROOT/$case_rel"
  [ ! -f "$case_path" ] && continue
  safe="$(echo "$case_rel" | tr '/: ' '___')"
  a="$TMP_DIR/${safe}.oneshot.out"
  b="$TMP_DIR/${safe}.daemon.out"
  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    echo "[daemon-parity] MISSING output for $case_rel" >&2
    fail=1
    continue
  fi
  ha="$(sha256sum "$a" | cut -d' ' -f1)"
  hb="$(sha256sum "$b" | cut -d' ' -f1)"
  sa="$(stat -c%s "$a")"
  sb="$(stat -c%s "$b")"
  if [ "$ha" = "$hb" ]; then
    printf "[daemon-parity] OK   %s  %s bytes\n" "$case_rel" "$sa"
  else
    printf "[daemon-parity] DIFF %s  oneshot=%s (%s bytes)  daemon=%s (%s bytes)\n" "$case_rel" "${ha:0:16}" "$sa" "${hb:0:16}" "$sb" >&2
    diff "$a" "$b" | head -10 >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "[daemon-parity] FAILED" >&2
  exit 1
fi
echo "[daemon-parity] all ${#cases[@]} cases byte-identical between one-shot and daemon"
