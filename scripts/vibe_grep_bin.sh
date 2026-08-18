#!/usr/bin/env bash
# `vibe grep` invoker for checkouts that have no native `runtime/vibe` runner.
#
# review_lint.vibex calls `$GREP_BIN grep --json --pattern '<pat>' <root>`.
# This script speaks that CLI and drives `cli_main` through the same host
# runner the unit/gate scripts use (`scripts/run_wasm_vibe_host_runner.sh`),
# not `bin/viberun`. Exit non-zero if grep cannot run. Do not print `ok`.
#
# Used as VIBE_REVIEW_LINT_GREP_BIN from the SessionStart hook (#1988).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  echo "vibe-grep-bin: $*" >&2
  exit 1
}

print_help() {
  cat <<'EOF'
vibe grep [flags] --pattern '<pattern>' [paths...]

Structural AST search. Metavariables are `$(name:kind)`, kind = exp / id / const / arg / args / pat / type.
Unlike moongrep / ast-grep, the filters run on the CHECKER's answers, not on the grammar alone:
  --where '$x : Array[Int]'    the capture's INFERRED type (`_` wildcard)
  --where '$f = Iterator::map' the capture's RESOLVED name
  --where-row '$f with Async' / '$f without Async'
                               the capture's effect ROW
  --only-ill-typed / --only-well-typed
                               keep matches in declarations that do (not) type-check
  --json                       emit matches as a JSON array

Empty output = no match. A report, not a failure: only a bad pattern or a
bad filter is an error. This invoker fails closed if the compiler wasm or
host runner cannot run grep at all.
EOF
}

pick_cli_wasm() {
  if [ -n "${VIBE_CLI_WASM:-}" ]; then
    if [ -f "$VIBE_CLI_WASM" ]; then
      printf '%s' "$VIBE_CLI_WASM"
      return 0
    fi
    die "compiler wasm not found: $VIBE_CLI_WASM"
  fi
  local candidate
  candidate="$(ls -t "$ROOT_DIR"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  candidate="$(ls -t "$ROOT_DIR"/_build/selfhost/generations/*/stage1.wasm 2>/dev/null | head -1 || true)"
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  if [ -f "$ROOT_DIR/_build/ci-artifacts/stage2.wasm" ]; then
    printf '%s' "$ROOT_DIR/_build/ci-artifacts/stage2.wasm"
    return 0
  fi
  if [ -f "$ROOT_DIR/bootstrap/seed/compiler.wasm" ]; then
    printf '%s' "$ROOT_DIR/bootstrap/seed/compiler.wasm"
    return 0
  fi
  die "no compiler wasm (set VIBE_CLI_WASM, build a stage, or run scripts/ensure_seed.sh)"
}

run_grep() {
  local g_pattern="" g_json=0 g_only="" g_where="" g_where_row=""
  local g_paths=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        print_help
        exit 0
        ;;
      --pattern)
        [ "$#" -ge 2 ] || die "vibe grep: --pattern needs an argument"
        g_pattern="$2"
        shift 2
        ;;
      --pattern=*)
        g_pattern="${1#--pattern=}"
        shift
        ;;
      --json|--output-json)
        g_json=1
        shift
        ;;
      --where)
        [ "$#" -ge 2 ] || die "vibe grep: --where needs an argument"
        g_where="$g_where$2"$'\n'
        shift 2
        ;;
      --where=*)
        g_where="$g_where${1#--where=}"$'\n'
        shift
        ;;
      --where-row)
        [ "$#" -ge 2 ] || die "vibe grep: --where-row needs an argument"
        g_where_row="$g_where_row$2"$'\n'
        shift 2
        ;;
      --where-row=*)
        g_where_row="$g_where_row${1#--where-row=}"$'\n'
        shift
        ;;
      --only-ill-typed)
        g_only="ill"
        shift
        ;;
      --only-well-typed)
        g_only="well"
        shift
        ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do
          g_paths+=("$1")
          shift
        done
        ;;
      -*)
        die "vibe grep: unknown flag: $1"
        ;;
      *)
        g_paths+=("$1")
        shift
        ;;
    esac
  done

  [ -n "$g_pattern" ] || die "usage: vibe grep --pattern '<pattern>' [--where '\$x : T'] [--where-row '\$f with E'] [--only-ill-typed|--only-well-typed] [--json] [paths...]"
  [ "${#g_paths[@]}" -gt 0 ] || g_paths=(".")
  if [ "$g_json" = "1" ] && [ "${#g_paths[@]}" -gt 1 ]; then
    die "vibe grep --json: one path at a time (JSON output is a single array)"
  fi

  local runner="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
  [ -f "$runner" ] || die "missing host runner: $runner"

  local cli
  cli="$(pick_cli_wasm)"

  local out err status g_path
  out="$(mktemp -t vibe-grep-XXXXXX)"
  err="$(mktemp -t vibe-grep-err-XXXXXX)"
  trap 'rm -f "$out" "$out.diag" "$out.warn" "$err"' RETURN

  for g_path in "${g_paths[@]}"; do
    [ -e "$g_path" ] || die "not found: $g_path"
    : >"$out"
    : >"$out.diag"
    : >"$out.warn"
    : >"$err"
    status=0
    # Same adapter-mode contract as runtime/vibe's `grep)` case: VIBE_GREP=1
    # plus the pattern/filter env vars, then cli_main(input, output).
    if ! env -u VIBE_FS_COMPILE -u VIBE_DIAGNOSTICS -u VIBE_NORMALIZE -u VIBE_TYPE_AT -u VIBE_DOC_AT \
        -u VIBE_BINDING_AT -u VIBE_SYMBOLS -u VIBE_ESCAPES -u VIBE_ESCAPES_STRICT -u VIBE_ALLOCS -u VIBE_DEPS \
        -u VIBE_RC_CLASSIFY -u VIBE_RC_PLAN -u VIBE_RC_PLAN_FN \
        -u VIBE_COVERAGE -u VIBE_DEBUG -u VIBE_DEBUG_BREAK -u VIBE_EMIT_MODULE_SOURCE \
        VIBE_GREP=1 \
        VIBE_GREP_PATTERN="$g_pattern" \
        VIBE_GREP_WHERE="$g_where" \
        VIBE_GREP_WHERE_ROW="$g_where_row" \
        VIBE_GREP_ONLY="$g_only" \
        VIBE_GREP_JSON="$g_json" \
        VIBE_IMPORT_ABI=raw \
        VIBE_PREOPEN_DIR="${VIBE_PREOPEN_DIR:-$ROOT_DIR}" \
        bash "$runner" --invoke cli_main "$cli" "$g_path" "$out" >/dev/null 2>"$err"; then
      status=$?
    fi
    if [ -s "$out.diag" ]; then
      echo "error: $(cat "$out.diag")" >&2
      die "grep failed"
    fi
    if [ "$status" -ne 0 ] && [ ! -s "$out" ]; then
      if [ -s "$err" ]; then
        cat "$err" >&2
      fi
      die "grep could not run (cli=$cli status=$status)"
    fi
    if [ -s "$out.warn" ]; then
      cat "$out.warn" >&2
    fi
    if [ -s "$out" ]; then
      cat "$out"
    fi
  done
}

run_probe() {
  local probe_dir probe_file output trimmed
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibe-grep-probe.XXXXXX")"
  probe_file="$probe_dir/probe.vibe"
  # A call site, not a `fn ($(x:exp))` shape: `fn` is a declaration keyword
  # and that pattern is a parse error. The gate uses this same call pattern.
  cat > "$probe_file" <<'EOF'
fn probe(x: Int) -> Int {
  x
}

fn run() -> Int {
  probe(1)
}
EOF
  # A real pattern against a tiny file: --help only proves the shell parsed.
  # JSON so a compiler that ignored VIBE_GREP and emitted wasm is rejected.
  if ! output="$(run_grep --json --pattern '$(f:id)($(a:args))' "$probe_file")"; then
    rm -rf "$probe_dir"
    return 1
  fi
  rm -rf "$probe_dir"
  trimmed="$(printf '%s' "$output" | tr -d '[:space:]')"
  case "$trimmed" in
    \[*)
      # Require a real hit so a stub that always writes `[]` cannot pass.
      if printf '%s' "$output" | grep -q 'probe(1)'; then
        return 0
      fi
      echo "vibe-grep-bin: probe did not find probe(1)" >&2
      return 1
      ;;
    *)
      echo "vibe-grep-bin: probe output is not a grep JSON result" >&2
      return 1
      ;;
  esac
}

if [ "${1:-}" = "grep" ]; then
  shift
fi

case "${1:-}" in
  --probe)
    run_probe
    ;;
  --help|-h)
    print_help
    ;;
  *)
    run_grep "$@"
    ;;
esac
