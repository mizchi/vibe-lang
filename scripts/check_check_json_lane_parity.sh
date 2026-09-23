#!/usr/bin/env bash
# #2831 criterion 2: `vibe check --json` must answer the SAME contract on the
# filesystem lane and under `--single-file` -- diagnostics, exit code, and the
# byte -> LSP offset conversion.
#
# The two lanes have separate argument parsers (`parse_check_args_with_profile`
# accepts `--json` and ignores it; `parse_user_check_args` carries it), which
# is how they could drift without either side looking wrong on its own. They
# agree today, measured; this keeps them agreeing.
#
# WHAT IS ASSERTED, and why each part:
#
#   identical stdout   the whole contract in one comparison -- range, severity,
#                      source, message, and the null `data` field
#   identical exit     a caller scripting `vibe check` branches on this, and a
#                      lane that reported the same diagnostics with a different
#                      status would still be a broken contract
#   a JSON ARRAY       `[]` on a clean file, not empty output. "No diagnostics"
#                      and "the mode is not supported here" must not look alike
#   UTF-16 units       the multibyte case is the one that distinguishes a real
#                      conversion from a byte offset that happens to match.
#                      `let a: Int = "日本語ですよ"` spans 20 BYTES and 8 UTF-16
#                      code units; a lane emitting bytes would say 13-33
#
# AGENTS.md said `--json` was available in `--single-file` mode only. Measured
# 2026-09-19, that is false on both counts: the FS lane accepts it and answers
# identically. Corrected there in the same change as this gate.
set -euo pipefail
ROOT_DIR="${VIBE_CHECK_JSON_PARITY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 check-json-lane-parity "${CHECK_JSON_PARITY_STAGE2:-}")" || exit 1

WORK="$ROOT_DIR/_build/_check_json_parity"
rm -rf "$WORK"; mkdir -p "$WORK"

fails=0
bad() { echo "[check-json-parity] FAIL: $*" >&2; fails=1; }

# run_lane <out-file> <flags...> -- writes stdout, echoes the exit status.
#
# The invocation is deliberately ONE LINE. This gate's self-test mutates it to
# stand in for the compiler, and a line-oriented edit against a continuation
# would replace the first line and leave the rest dangling -- which is the
# "the slice grabbed only the first line and the red test passed while proving
# nothing" failure AGENTS.md records under #2248. It cost one round here too.
run_lane() {
  local out="$1"; shift
  local status=0
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main "$STAGE2" check "$@" --json "$SRC_REL" >"$out" 2>/dev/null || status=$?
  echo "$status"
}

probe() { # probe <name> <expect-exit> <source-bytes-written-by-caller>
  local name="$1" want_exit="$2"
  SRC_REL="_build/_check_json_parity/$name.vibe"
  local fs_out="$WORK/$name.fs.json" sf_out="$WORK/$name.sf.json"
  local fs_exit sf_exit
  fs_exit="$(run_lane "$fs_out")"
  sf_exit="$(run_lane "$sf_out" --single-file)"

  if [ "$fs_exit" != "$sf_exit" ]; then
    bad "$name: exit differs -- FS $fs_exit, --single-file $sf_exit"
  elif [ "$fs_exit" != "$want_exit" ]; then
    bad "$name: exit $fs_exit, expected $want_exit"
  fi
  if ! cmp -s "$fs_out" "$sf_out"; then
    bad "$name: the two lanes emitted different JSON"
    echo "  FS:          $(cat "$fs_out")" >&2
    echo "  single-file: $(cat "$sf_out")" >&2
  fi
  # "No diagnostics" must be an empty ARRAY, not empty output.
  case "$(cat "$fs_out")" in
    "["*) ;;
    *) bad "$name: FS lane did not emit a JSON array: $(cat "$fs_out")" ;;
  esac
}

printf 'fn f() -> Int {\n  1 + 2\n}\n' > "$WORK/clean.vibe"
probe clean 0

printf 'let a: Int = "not an int"\n' > "$WORK/mismatch.vibe"
probe mismatch 1

# The conversion case. 20 bytes, 8 UTF-16 code units.
printf 'let a: Int = "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe3\x81\xa7\xe3\x81\x99\xe3\x82\x88"\n' > "$WORK/multibyte.vibe"
probe multibyte 1
if ! grep -qF '"character":21' "$WORK/multibyte.fs.json" 2>/dev/null; then
  bad "multibyte: the range end is not in UTF-16 code units (want character 21; bytes would give 33)"
  echo "  got: $(cat "$WORK/multibyte.fs.json")" >&2
fi

# A LEXER error, which is the case the two lanes used to disagree about
# outright (#2831). `cli_support.vibe` lexed the entry file with the THROWING
# `lex_with_offsets`, so the FS lane lost the position: its text output was
# `unexpected character:` with no line, no column and not even a path, and its
# JSON answered `0:0` with `"data":{"synthetic":true}` -- an INVENTED location
# for a node the parser did see and whose offset `--single-file` printed
# correctly. Inventing one is what the source-range contract forbids, and the
# two lanes disagreeing is what this gate exists to catch.
#
# `\xe6\x97\xa5` is a 3-byte character at byte column 11 of line 2, which is
# UTF-16 unit 10 on 0-based line 1 -- so this probe also covers the conversion
# for a lex error, not only for a type error.
printf 'fn f() -> Int {\n  let s = \xe6\x97\xa5\n  1\n}\n' > "$WORK/lexerr.vibe"
probe lexerr 1
if ! grep -qF '"character":10' "$WORK/lexerr.fs.json" 2>/dev/null; then
  bad "lexerr: the FS lane does not carry the lexer error's position (want character 10)"
  echo "  got: $(cat "$WORK/lexerr.fs.json")" >&2
fi
if grep -qF 'synthetic' "$WORK/lexerr.fs.json" 2>/dev/null; then
  bad "lexerr: the FS lane still marks a REAL lexer position synthetic"
  echo "  got: $(cat "$WORK/lexerr.fs.json")" >&2
fi

# THREE diagnostics in one file (#2831 criterion 4). The checker collects every
# error and used to throw `frozen_errors[0]`, so a file with three broken
# bindings took three edit-and-rerun cycles. Reporting the rest is only half
# the change: the markers are per-diagnostic, so locating the JOINED string
# stamps the first `[@off=]` onto the whole report -- measured, line 1 came
# back carrying line 2's location. Each lane locates per line now, and this
# probe is what keeps them emitting the same THREE objects rather than one
# with embedded newlines.
printf 'fn f() -> Unit {\n  let a: Int = "not an int"\n  let b: String = 42\n  let c: Int = true\n  ()\n}\n' > "$WORK/multi.vibe"
probe multi 1
count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$WORK/multi.fs.json" 2>/dev/null || echo 0)"
if [ "$count" != "3" ]; then
  bad "multi: the FS lane emitted $count diagnostics, want 3"
  echo "  got: $(cat "$WORK/multi.fs.json")" >&2
fi
if grep -qF '\n' "$WORK/multi.fs.json" 2>/dev/null; then
  bad "multi: a diagnostic message carries an embedded newline -- the lines were not split"
  echo "  got: $(cat "$WORK/multi.fs.json")" >&2
fi

# An UNLOCATED diagnostic (#2992). A literal `if` condition carries no offset,
# so the diagnostic falls back to the synthetic range -- and the FS lane's
# message used to start with the file's path while `--single-file`'s did not.
printf 'fn f() -> Int {\n  if 1 { 2 } else { 3 }\n}\n' > "$WORK/unlocated.vibe"
probe unlocated 1
if grep -qF 'unlocated.vibe' "$WORK/unlocated.fs.json" 2>/dev/null; then
  bad "unlocated: the FS lane's message carries the file path"
  echo "  got: $(cat "$WORK/unlocated.fs.json")" >&2
fi

[ "$fails" -eq 0 ] || exit 1
echo "[check-json-parity] ok (6 probes: both lanes agree on diagnostics, exit code, and UTF-16 offsets)"
