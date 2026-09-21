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
  local listf chunkf jsonbody
  listf="$(mktemp -t vibe-grep-list-XXXXXX)"
  chunkf="$(mktemp -t vibe-grep-chunk-XXXXXX)"
  jsonbody="$(mktemp -t vibe-grep-json-XXXXXX)"
  trap 'rm -f "$out" "$out.diag" "$out.warn" "$err" "$listf" "$chunkf" "$jsonbody"' RETURN

  # #2914: a single wasm32 process tops out at 4 GiB and the sweep's cost
  # ACCUMULATES across files, so a tree-wide typed sweep cannot finish in one
  # process however cheap each file is made. Measured: dropping the 46 MB of
  # generated bundles moved it from file 70 to 118 of 1224, and building the
  # compiler on the RC lane -- which frees -- moved it from 70 to 71. Only a
  # fresh process resets the frontier. Same shape lint_review_regressions.sh
  # already uses in a shell loop for this exact defect.
  local chunk_files="${VIBE_GREP_CHUNK_FILES:-40}"
  case "$chunk_files" in
    ''|*[!0-9]*) die "VIBE_GREP_CHUNK_FILES must be a positive whole number: $chunk_files" ;;
  esac
  [ "$chunk_files" -gt 0 ] || die "VIBE_GREP_CHUNK_FILES must be a positive whole number: $chunk_files"

  # One `env` shape for every invocation below, so a chunked run and a
  # list-files run cannot drift apart in which switches they clear.
  # Non-fatal: returns the status instead of dying, for the support probe.
  try_cli() { # <input_path> <extra-env-assignments...>
    local in_path="$1"; shift
    rm -f "$out" "$out.diag" "$out.warn" "$err"
    status=0
    env -u VIBE_FS_COMPILE -u VIBE_DIAGNOSTICS -u VIBE_NORMALIZE -u VIBE_TYPE_AT -u VIBE_DOC_AT \
        -u VIBE_BINDING_AT -u VIBE_SYMBOLS -u VIBE_ESCAPES -u VIBE_ESCAPES_STRICT -u VIBE_ALLOCS -u VIBE_DEPS \
        -u VIBE_RC_CLASSIFY -u VIBE_RC_PLAN -u VIBE_RC_PLAN_FN \
        -u VIBE_COVERAGE -u VIBE_DEBUG -u VIBE_DEBUG_BREAK -u VIBE_EMIT_MODULE_SOURCE \
        -u VIBE_GREP -u VIBE_GREP_LIST_FILES -u VIBE_GREP_FILE_LIST \
        VIBE_GREP_PATTERN="$g_pattern" \
        VIBE_GREP_WHERE="$g_where" \
        VIBE_GREP_WHERE_ROW="$g_where_row" \
        VIBE_GREP_ONLY="$g_only" \
        VIBE_GREP_JSON="$g_json" \
        VIBE_IMPORT_ABI=raw \
        VIBE_PREOPEN_DIR="${VIBE_PREOPEN_DIR:-$ROOT_DIR}" \
        "$@" \
        bash "$runner" --invoke cli_main "$cli" "$in_path" "$out" >/dev/null 2>"$err" || status=$?
    return "$status"
  }

  invoke_cli() { # <input_path> <extra-env-assignments...>
    local in_path="$1"; shift
    rm -f "$out" "$out.diag" "$out.warn" "$err"
    status=0
    # `cmd || status=$?`, NOT `if ! cmd; then status=$?; fi`. Inside `if !`,
    # `$?` is the status of the INVERTED pipeline -- 0 exactly when the command
    # failed -- so the branch whose only job was to record a failure recorded
    # success, and a wasm trap left this script with status=0 and no output:
    # byte-for-byte what a legitimate no-match sweep looks like (#2914).
    env -u VIBE_FS_COMPILE -u VIBE_DIAGNOSTICS -u VIBE_NORMALIZE -u VIBE_TYPE_AT -u VIBE_DOC_AT \
        -u VIBE_BINDING_AT -u VIBE_SYMBOLS -u VIBE_ESCAPES -u VIBE_ESCAPES_STRICT -u VIBE_ALLOCS -u VIBE_DEPS \
        -u VIBE_RC_CLASSIFY -u VIBE_RC_PLAN -u VIBE_RC_PLAN_FN \
        -u VIBE_COVERAGE -u VIBE_DEBUG -u VIBE_DEBUG_BREAK -u VIBE_EMIT_MODULE_SOURCE \
        -u VIBE_GREP -u VIBE_GREP_LIST_FILES -u VIBE_GREP_FILE_LIST \
        VIBE_GREP_PATTERN="$g_pattern" \
        VIBE_GREP_WHERE="$g_where" \
        VIBE_GREP_WHERE_ROW="$g_where_row" \
        VIBE_GREP_ONLY="$g_only" \
        VIBE_GREP_JSON="$g_json" \
        VIBE_IMPORT_ABI=raw \
        VIBE_PREOPEN_DIR="${VIBE_PREOPEN_DIR:-$ROOT_DIR}" \
        "$@" \
        bash "$runner" --invoke cli_main "$cli" "$in_path" "$out" >/dev/null 2>"$err" || status=$?
    # A diagnostic is fatal wherever it comes from: a chunk that refused must
    # not be swallowed by the chunks around it that happened to succeed.
    if [ -s "$out.diag" ]; then
      echo "error: $(cat "$out.diag")" >&2
      die "grep failed"
    fi
    # Non-zero is fatal WHETHER OR NOT `$out` holds anything. The old guard
    # also required empty output, so a sweep that trapped part-way printed the
    # files it had reached as though it had finished -- a partial answer
    # presented as a complete one. Chunking makes that worse, not better:
    # earlier chunks have already produced real output by then.
    if [ "$status" -ne 0 ]; then
      [ -s "$err" ] && cat "$err" >&2
      die "grep could not run (cli=$cli status=$status)"
    fi
    if [ ! -e "$out" ]; then
      [ -s "$err" ] && cat "$err" >&2
      die "grep produced no result file (cli=$cli)"
    fi
  }

  : > "$jsonbody"
  for g_path in "${g_paths[@]}"; do
    [ -e "$g_path" ] || die "not found: $g_path"

    # Ask the SWEEP which files it would visit rather than globbing here: the
    # skip policy (`deps/`, `_build/`, dotted dirs) is a user-visible answer
    # that source_walk.vibe keeps in one place, and a driver that re-derived it
    # would disagree with the sweep and nothing would say so.
    #
    # PROBED, not assumed. This script runs against whatever compiler is on
    # hand -- a generation, a CI artifact, the committed seed -- and the mode
    # only exists in compilers built after #2914. An older one sees no mode set
    # at all and tries to COMPILE the input, which for a directory root fails
    # as `EISDIR`. Falling back to the single call is not a regression: it is
    # exactly today's behaviour, trap and all, and the budget diagnostic still
    # says so when it stops.
    if ! try_cli "$g_path" VIBE_GREP_LIST_FILES=1 || [ -s "$out.diag" ] || [ ! -s "$out" ]; then
      invoke_cli "$g_path" VIBE_GREP=1
      if [ -s "$out.warn" ]; then
        cat "$out.warn" >&2
      fi
      if [ -s "$out" ]; then
        if [ "$g_json" = "1" ]; then
          sed -e '1d' -e '$d' "$out" | sed -e 's/,[[:space:]]*$//' >> "$jsonbody"
        else
          cat "$out"
        fi
      fi
      continue
    fi
    cp "$out" "$listf"

    local total done_n
    total="$(grep -c . "$listf" 2>/dev/null || echo 0)"
    [ "$total" -gt 0 ] || continue
    done_n=0
    while [ "$done_n" -lt "$total" ]; do
      grep . "$listf" | tail -n +"$((done_n + 1))" | head -n "$chunk_files" > "$chunkf"
      [ -s "$chunkf" ] || break
      invoke_cli "$g_path" VIBE_GREP=1 VIBE_GREP_FILE_LIST="$chunkf"
      if [ -s "$out.warn" ]; then
        cat "$out.warn" >&2
      fi
      if [ -s "$out" ]; then
        if [ "$g_json" = "1" ]; then
          # `[` / one object per line / `]`. Drop the brackets and keep the
          # objects; commas are re-added once at the end so a chunk boundary
          # cannot leave a trailing or doubled comma.
          sed -e '1d' -e '$d' "$out" | sed -e 's/,[[:space:]]*$//' >> "$jsonbody"
        else
          cat "$out"
        fi
      fi
      done_n=$((done_n + $(grep -c . "$chunkf")))
    done
  done

  if [ "$g_json" = "1" ]; then
    # One array for the whole sweep, whatever it was split into: the chunking
    # is an implementation detail and must not be visible in the answer.
    echo "["
    if [ -s "$jsonbody" ]; then
      sed -e '$!s/$/,/' "$jsonbody"
    fi
    echo "]"
  fi
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
