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
  trap 'rm -f "$out" "$out.diag" "$out.warn" "$err" "$listf" "$listf.nonblank" "$chunkf" "$chunkf.paths" "$jsonbody" "$out.resume"' RETURN

  # #2914: a single wasm32 process tops out at 4 GiB and the sweep's cost
  # ACCUMULATES across files, so a tree-wide typed sweep cannot finish in one
  # process however cheap each file is made. Measured: dropping the 46 MB of
  # generated bundles moved it from file 70 to 118 of 1224, and building the
  # compiler on the RC lane -- which frees -- moved it from 70 to 71. Only a
  # fresh process resets the frontier. Same shape lint_review_regressions.sh
  # already uses in a shell loop for this exact defect.
  # 8 is a PERFORMANCE hint, not a correctness constant -- that is the whole
  # point of the resume hand-off. The sweep stops on its own memory guard and
  # says where to continue, so a cap that is too large for a corpus costs time
  # and nothing else. Measured on `lib`, every row byte-identical at 15
  # matches:
  #
  #   cap      before resume            with resume
  #   8        ok,  246s                ok,  262s
  #   16       (untried)                ok,  252s
  #   40       FAILED at file 30 of 40  ok,  446s
  #   none     (not selectable)         ok,  455s
  #
  # Two things that reading only the last column would miss. The cap used to
  # decide whether the sweep finished AT ALL; now it does not. And dropping it
  # entirely -- the obvious "no constant" design -- is the SLOWEST option, 74%
  # over cap=8, because each process then runs until the guard fires near the
  # ceiling. So the constant stays, demoted: it buys speed, and being wrong
  # about it is no longer fatal.
  local chunk_cap="${VIBE_GREP_CHUNK_FILES:-8}"
  if [ -n "$chunk_cap" ]; then
    case "$chunk_cap" in
      *[!0-9]*) die "VIBE_GREP_CHUNK_FILES must be a positive whole number: $chunk_cap" ;;
    esac
    [ "$chunk_cap" -gt 0 ] || die "VIBE_GREP_CHUNK_FILES must be a positive whole number: $chunk_cap"
  fi

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
    # The banner is the POSITIVE half of the probe. "It printed something" is
    # not evidence of support: a compiler that ignored the mode and swept
    # instead also prints something, and `path:line:col: text` chunks just
    # fine -- into a list of things that are not files. Here that shape is
    # ruled out twice over (an older compiler sees no mode at all and tries to
    # COMPILE a directory, which fails as EISDIR), but the argv driver in
    # runtime/vibe has only the banner, and one format means one check.
    if ! try_cli "$g_path" VIBE_GREP_LIST_FILES=1 || [ -s "$out.diag" ] || [ ! -s "$out" ] ||
       [ "$(sed -n '1p' "$out")" != "vibe-grep-file-list-v1" ]; then
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
    sed '1d' "$out" > "$listf"

    local total done_n
    # `|| true`, NOT `|| echo 0`. `grep -c` PRINTS `0` and THEN exits 1 when
    # it matches nothing, so the fallback appends a second zero and `$total`
    # becomes `0\n0` -- `[ "$total" -gt 0 ]` then writes `integer expression
    # expected` to stderr on a sweep that succeeded and simply found no files.
    # An empty directory is the ordinary way to reach it, and it became
    # reachable here only once the compiler learned to answer a listing with
    # just the banner, which the `sed '1d'` above then strips to nothing
    # (Codex on #2956, P2). The runtime/vibe driver already spells it `|| true`.
    total="$(grep -c . "$listf" 2>/dev/null || true)"
    [ -n "$total" ] || total=0
    [ "$total" -gt 0 ] || continue
    # `sed -n 'A,Bp'` and NOT `grep . | tail -n +A | head -n N`: under
    # `set -o pipefail`, `head` closing the pipe early kills the upstream
    # `grep` with SIGPIPE and the whole run exits 141 with no output and no
    # message -- which is what the first version of this loop did.
    local blanks
    blanks="$listf.nonblank"
    grep . "$listf" > "$blanks" || true
    done_n=0
    while [ "$done_n" -lt "$total" ]; do
      # ADAPTIVE by default: hand over everything that is left and let the
      # sweep stop where its own memory guard says to. The guard already
      # measures headroom and the largest per-file cost; a constant chunk size
      # was a stand-in for a quantity that varies ~50x across the corpus, and
      # 40 failed on this repo while 8 worked -- neither number is a property
      # of `vibe grep`. `VIBE_GREP_CHUNK_FILES` still caps the slice, because
      # the chunked-sweep gate needs to force boundaries at chosen places.
      if [ -n "$chunk_cap" ]; then
        sed -n "$((done_n + 1)),$((done_n + chunk_cap))p" "$blanks" > "$chunkf.paths"
      else
        sed -n "$((done_n + 1)),$ p" "$blanks" > "$chunkf.paths"
      fi
      [ -s "$chunkf.paths" ] || break
      # THE CHUNK KEEPS THE BANNER. `grep_read_file_list` decodes escapes only
      # when the banner says the file is in the encoded format -- so a chunk
      # built by stripping it is read literally, and a path the listing escaped
      # (a backslash or a newline in a filename) names a file that does not
      # exist (Codex on #2956, P2). The paths are cut into their own file so the
      # slice count below stays a count of PATHS, not of lines.
      printf 'vibe-grep-file-list-v1\n' > "$chunkf"
      cat "$chunkf.paths" >> "$chunkf"
      rm -f "$out.resume"
      invoke_cli "$g_path" VIBE_GREP=1 VIBE_GREP_FILE_LIST="$chunkf" VIBE_GREP_RESUME=1
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
      local slice advance
      slice="$(grep -c . "$chunkf.paths" || true)"
      if [ -s "$out.resume" ]; then
        # The sweep stopped on its own budget and says where. That index is
        # how many of THIS slice it swept.
        advance="$(tr -d '[:space:]' < "$out.resume")"
        case "$advance" in
          ''|*[!0-9]*) die "grep: unreadable resume index from the sweep: '$advance'" ;;
        esac
        # A hand-off that advanced nothing would loop forever, printing the
        # same results on every pass -- worse than the trap this replaces. The
        # guard cannot fire before one file has been typed, so this is
        # unreachable; it is asserted because "unreachable" and "untested"
        # look the same from a hang.
        [ "$advance" -gt 0 ] ||
          die "grep: the sweep handed back without advancing (index 0 of $slice files); refusing to loop"
        [ "$advance" -le "$slice" ] ||
          die "grep: the sweep reports $advance files swept of a $slice-file slice"
      else
        advance="$slice"
      fi
      done_n=$((done_n + advance))
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
