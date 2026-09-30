#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.


# 4. multi-file compile regression (#594): the selfhost compiler must resolve
#    imports from the filesystem. collect_import_path once built import paths via
#    string interpolation, which a selfhost codegen bug rendered as garbage (only
#    hit by real `import` statements, which the merged/bundle selfbuild source
#    strips — so the fixpoint above does not exercise it). Compile a 2-file
#    program via the fresh stage2 (VIBE_FS_COMPILE) and assert it runs to 42.
echo "[compiler-gate] 4/4 multi-file FS-compile regression"
fsdir="_build/_gate_fscompile"
rm -rf "$fsdir"; mkdir -p "$fsdir"
printf 'export let add = (a: Int, b: Int) -> Int { a + b }\n' > "$fsdir/helper.vibe"
printf 'import ./helper.vibe { add }\nexport let _start = () -> Int { add(40, 2) }\n' > "$fsdir/main.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fsdir/main.vibe" "$fsdir/main.wasm" _start || true
if [ ! -s "$fsdir/main.wasm" ]; then
  echo "[compiler-gate] FAIL: multi-file FS-compile produced no wasm" >&2
  exit 1
fi
fsres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$fsdir/main.wasm" 2>/dev/null | tr -dc '0-9')"
rm -rf "$fsdir"
if [ "$fsres" != "42" ]; then
  echo "[compiler-gate] FAIL: multi-file FS-compile sample returned '$fsres' (expected 42)" >&2
  exit 1
fi
echo "[compiler-gate] multi-file FS-compile ok (42)"

# #3213: the byte-indexed char lexer rejects a multi-byte character. Both
# checker lanes must locate the opening quote and name the usable syntax.
for char_lane in fs single-file; do
  if [ "$char_lane" = single-file ]; then set -- --single-file; else set --; fi
  char_diag="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_nonascii_char_literal.vibe 2>&1 || true)"
  case "$char_diag" in
    *'line 2:11: use a String for text or an Int code point for non-ASCII'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane non-ASCII char diagnostic lacks its location or edit: $char_diag" >&2; exit 1 ;;
  esac
  missing_quote="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_unclosed_char_literal.vibe 2>&1 || true)"
  case "$missing_quote" in
    *'line 2:11: add a closing quote to the char literal'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane missing char quote diagnostic suggests the wrong edit: $missing_quote" >&2; exit 1 ;;
  esac
  crlf_quote="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_unclosed_char_crlf.vibe 2>&1 || true)"
  case "$crlf_quote" in
    *'line 2:11: add a closing quote to the char literal'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane CRLF missing quote diagnostic differs from LF: $crlf_quote" >&2; exit 1 ;;
  esac
  unclosed_multichar="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_multichar_unclosed_char_literal.vibe 2>&1 || true)"
  case "$unclosed_multichar" in
    *'line 2:11: use a String for text or an Int code point for non-ASCII'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane unclosed multi-character literal suggests a quote that cannot fix it: $unclosed_multichar" >&2; exit 1 ;;
  esac
  unclosed_nonascii="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_nonascii_unclosed_char_literal.vibe 2>&1 || true)"
  case "$unclosed_nonascii" in
    *'line 2:11: use a String for text or an Int code point for non-ASCII'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane unclosed non-ASCII char suggests a quote that cannot fix it: $unclosed_nonascii" >&2; exit 1 ;;
  esac
  comment_quote="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_unclosed_char_comment.vibe 2>&1 || true)"
  case "$comment_quote" in
    *'line 2:11: add a closing quote to the char literal'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane apostrophe in a comment changed the char edit: $comment_quote" >&2; exit 1 ;;
  esac
  compact_comment_quote="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_unclosed_char_compact_comment.vibe 2>&1 || true)"
  case "$compact_comment_quote" in
    *'line 2:11: add a closing quote to the char literal'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane apostrophe in a compact comment changed the char edit: $compact_comment_quote" >&2; exit 1 ;;
  esac
  next_literal="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_unclosed_char_next_literal.vibe 2>&1 || true)"
  case "$next_literal" in
    *'line 2:11: add a closing quote to the char literal'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane next literal changed the missing-quote edit: $next_literal" >&2; exit 1 ;;
  esac
  next_escaped_literal="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_unclosed_char_next_escaped_literal.vibe 2>&1 || true)"
  case "$next_escaped_literal" in
    *'line 2:11: add a closing quote to the char literal'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane escaped next literal changed the missing-quote edit: $next_escaped_literal" >&2; exit 1 ;;
  esac
  next_operator_literal="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_unclosed_char_next_literal_operator.vibe 2>&1 || true)"
  case "$next_operator_literal" in
    *'line 2:14: add a closing quote to the char literal'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane operator-separated literal changed the missing-quote edit: $next_operator_literal" >&2; exit 1 ;;
  esac
  next_space_literal="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_unclosed_char_next_space_literal.vibe 2>&1 || true)"
  case "$next_space_literal" in
    *'line 2:11: add a closing quote to the char literal'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane whitespace-valued next literal changed the missing-quote edit: $next_space_literal" >&2; exit 1 ;;
  esac
  following_string="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_unclosed_char_following_string.vibe 2>&1 || true)"
  case "$following_string" in
    *'line 2:15: add a closing quote to the char literal'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane apostrophe inside a later string changed the char edit: $following_string" >&2; exit 1 ;;
  esac
  block_string="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke cli_main "$stage2_wasm" check "$@" fixtures/err_unclosed_char_following_block_string.vibe 2>&1 || true)"
  case "$block_string" in
    *'line 3:11: add a closing quote to the char literal'*) ;;
    *) echo "[compiler-gate] FAIL: $char_lane apostrophe inside a later block string changed the char edit: $block_string" >&2; exit 1 ;;
  esac
  for closed_delimiter in comma semicolon followed_literal slashes adjacent_literal; do
    closed_column=11
    if [ "$closed_delimiter" = adjacent_literal ]; then
      closed_column=15
    fi
    closed_diag="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke cli_main "$stage2_wasm" check "$@" "fixtures/err_multichar_char_${closed_delimiter}.vibe" 2>&1 || true)"
    case "$closed_diag" in
      *"line 2:${closed_column}: use a String for text or an Int code point for non-ASCII"*) ;;
      *) echo "[compiler-gate] FAIL: $char_lane closed literal containing $closed_delimiter suggests a missing quote: $closed_diag" >&2; exit 1 ;;
    esac
  done
done
echo "[compiler-gate] char diagnostics locate invalid width and missing quotes with distinct edits (#3213)"

# Keep complete checked-module transport aligned with the real FS output and
# diagnostics corpus, including compiler-sized input and hostile cache repair.
echo "[compiler-gate] checked-module cache parity (#2505)"
VIBE_STAGE2_WASM="$stage2_wasm" bash scripts/checked_module_cache_parity.sh

# 4b. deep-recursion effect resume regression (#737): a perform issued from a
#     RECURSIVE frame, handled by an in-language handler OUTSIDE the recursion
#     that bridges to a host builtin, used to deliver the FIRST resume's value
#     as the SECOND op's argument (deep-continuation resume corruption). The
#     merge lane works around nothing anymore (merge_sources is back on
#     `perform Fs::ReadFile`), so this program is the canary.
echo "[compiler-gate] 4b deep-recursion effect resume regression (#737)"
drdir="_build/_gate_deepresume"
rm -rf "$drdir"; mkdir -p "$drdir/d"
printf 'AAA' > "$drdir/a.txt"
printf 'BBB' > "$drdir/d/b.txt"
printf 'CCC' > "$drdir/d/c.txt"
cat > "$drdir/main.vibe" <<'VEOF'
effect FileIo {
  ReadFile(String) -> String
}

let rec walk = (path: String, depth: Int) -> String with FileIo {
  let source = perform FileIo::ReadFile(path)
  if depth <= 0 {
    source
  } else {
    let s1 = walk("_build/_gate_deepresume/d/b.txt", depth - 1)
    let s2 = walk("_build/_gate_deepresume/d/c.txt", depth - 1)
    "\{source}|\{s1}|\{s2}"
  }
}

export let _start: () -> Int with Fs = () -> {
  let out = handle {
    walk("_build/_gate_deepresume/a.txt", 1)
  } with FileIo {
    ReadFile(p) => resume(Fs::read_file(p))
  }
  if out == "AAA|BBB|CCC" {
    42
  } else {
    1
  }
}
VEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$drdir/main.vibe" "$drdir/main.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$drdir/main.wasm" ]; then
  echo "[compiler-gate] FAIL: deep-resume regression program did not compile" >&2
  cat "$drdir/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
drres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$drdir/main.wasm" 2>/dev/null | tr -dc '0-9')"
rm -rf "$drdir"
if [ "$drres" != "42" ]; then
  echo "[compiler-gate] FAIL: deep-resume regression returned '$drres' (expected 42) — #737-class resume corruption" >&2
  exit 1
fi
echo "[compiler-gate] deep-recursion effect resume ok (42)"

# 4c. missing-import diagnostic regression (#831): a file that imports a path
#     which does not exist on disk used to crash raw -- `collect_sources_rec`
#     called the host `Fs::read_file` primitive unguarded on the (silently
#     best-effort-resolved) missing path, and a host-level ENOENT there is a
#     JS exception that crosses the wasm/JS boundary uncaught (not a guest
#     `Error` effect), printing a "[crash debug]" memory dump and aborting
#     instead of reporting a diagnostic. Assert the compile now fails
#     gracefully with a located "cannot resolve import" diagnostic and never
#     reaches the raw crash dump / host exception text.
echo "[compiler-gate] 4c missing-import diagnostic regression (#831)"
midir="_build/_gate_missing_import"
rm -rf "$midir"; mkdir -p "$midir"
cat > "$midir/main.vibe" <<'VEOF'
import ./does_not_exist.vibe { helper }

export let _start = () -> Int { helper(1) }
VEOF
# VIBE_CRASH_DEBUG=1 on purpose (#2199). The dump is now OFF by default, and
# the "no crash debug" assertion below would then hold no matter what happened
# -- it would stop telling a graceful diagnostic apart from the raw host
# exception it exists to catch. Asking for the dump keeps that check able to
# fail; the located-diagnostic assertion further down carries the rest.
mi_out="$(VIBE_CRASH_DEBUG=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$midir/main.vibe" "$midir/main.wasm" _start 2>&1)" || true
mi_wasm_produced=0
if [ -s "$midir/main.wasm" ]; then
  mi_wasm_produced=1
fi
mi_diag="$(cat "$midir/main.wasm.diag" 2>/dev/null || true)"
rm -rf "$midir"
if [ "$mi_wasm_produced" = "1" ]; then
  echo "[compiler-gate] FAIL: missing-import program compiled successfully (expected a diagnostic failure)" >&2
  exit 1
fi
if echo "$mi_out" | grep -q "crash debug"; then
  echo "[compiler-gate] FAIL: missing-import compile hit the raw crash-debug dump instead of a diagnostic" >&2
  echo "$mi_out" >&2
  exit 1
fi
if echo "$mi_out" | grep -qi "fs_read_file failed"; then
  echo "[compiler-gate] FAIL: missing-import compile leaked the raw fs_read_file host error instead of a diagnostic" >&2
  echo "$mi_out" >&2
  exit 1
fi
if ! echo "$mi_diag" | grep -qE '^line [0-9]+:[0-9]+: cannot resolve import .*does_not_exist\.vibe'; then
  echo "[compiler-gate] FAIL: missing-import diagnostic did not look like a located 'cannot resolve import' message: '$mi_diag'" >&2
  exit 1
fi
echo "[compiler-gate] missing-import diagnostic ok: $mi_diag"

# 4d. derive(Show) source-name rendering across the merge rename (#2205): a
#     PRIVATE struct/enum in an imported module is renamed by the merge
#     (`Point` -> `Point_dep_<path>`), and derive(Show) expands after that
#     rename -- so the rendered string leaked the compiler-internal name into
#     user output (`Point_dep_... { x: 3, y: 4 }`), silently diverging from
#     the single-file lane. The rename side table (namespace_rename_original)
#     must recover the source spelling for struct names and enum constructors
#     (both payload and nullary), while the generated fn's own name stays
#     mangled.
echo "[compiler-gate] 4d derive(Show) source-name rendering across merge rename (#2205)"
dsdir="_build/_gate_derive_show_rename"
rm -rf "$dsdir"; mkdir -p "$dsdir"
cat > "$dsdir/dep.vibe" <<'VEOF'
struct Point {
  x: Int;
  y: Int
} derive (Show)

enum Color {
  Lone;
  Mix(Int, Int)
} derive (Show)

export fn render() -> String {
  let p = Point::{ x: 3, y: 4 }
  let c = Mix(1, 2)
  let l = Lone
  "\{p}|\{c}|\{l}"
}
VEOF
cat > "$dsdir/main.vibe" <<'VEOF'
import ./dep.vibe { render }

fn main allows Console {
  println(render())
}
VEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dsdir/main.vibe" "$dsdir/main.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$dsdir/main.wasm" ]; then
  echo "[compiler-gate] FAIL: derive(Show) rename sample did not compile" >&2
  cat "$dsdir/main.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
dsout="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$dsdir/main.wasm" 2>/dev/null)"
rm -rf "$dsdir"
if [ "$dsout" != "Point { x: 3, y: 4 }|Mix(1, 2)|Lone" ]; then
  echo "[compiler-gate] FAIL: derive(Show) rendered '$dsout' (expected 'Point { x: 3, y: 4 }|Mix(1, 2)|Lone') — #2205 merge-renamed name leaking" >&2
  exit 1
fi
echo "[compiler-gate] derive(Show) source-name rendering ok"

# 4e. OOB abort names the operation, index, and length, and reports an
#     editable path:line for the access (#2199). A production-style compile
#     (no VIBE_DEBUG_BREAK) emits compact LEB vibe.linemap; missing/stripped
#     mapping degrades to the wasm frame, never a fabricated location.
#     `vibe build` strips the section with `name`; this compile keeps it via
#     VIBE_WASM_NAMES=1 (the same knob `vibe run` uses).
#     This gate is the linear/RC production lane (`vibe run` / `vibe test`).
#     The rest of early pins VIBE_RC=0 (bump); 4e's compile unsets that so
#     it asks the lane users actually hit. wasm-gc Array OOB is the engine's
#     native trap (no __rt_oob_abort, no production linemap).
echo "[compiler-gate] 4e OOB abort names the operation, index, length, and path:line (#2199)"
oobdir="_build/_gate_arr_oob"
rm -rf "$oobdir"; mkdir -p "$oobdir"
# Access is on line 4 of each file (1=fn, 2=let, 3=println before, 4=access).
cat > "$oobdir/arr_get.vibe" <<'VEOF'
fn main allows Console {
  let xs = [1, 2, 3]
  println("before")
  println("\{Array::get(xs, 10)}")
}
VEOF
cat > "$oobdir/arr_set.vibe" <<'VEOF'
fn main allows Console {
  let xs = [1, 2, 3]
  println("before")
  Array::set(xs, 10, 0)
}
VEOF
cat > "$oobdir/bytes_get.vibe" <<'VEOF'
fn main allows Console {
  let b = Bytes::from_array([1, 2, 3])
  println("before")
  println("\{Bytes::get(b, 9)}")
}
VEOF
cat > "$oobdir/bytes_set.vibe" <<'VEOF'
fn main allows Console {
  let b = Bytes::from_array([1, 2, 3])
  println("before")
  Bytes::set(b, 9, 0)
}
VEOF
cat > "$oobdir/str_byte_at.vibe" <<'VEOF'
fn main allows Console {
  let s = "abc"
  println("before")
  println("\{String::byte_at(s, 5)}")
}
VEOF
oob_compile_one() {
  local src="$1" out="$2"
  # Production RC: this lane's VIBE_RC=0 pin would compile bump, which has
  # no production linemap.
  # VIBE_WASM_NAMES=1 keeps vibe.linemap (release strip drops it with `name`).
  env -u VIBE_RC VIBE_WASM_NAMES=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$src" "$out" main >/dev/null 2>&1 || true
  if [ ! -s "$out" ]; then
    echo "[compiler-gate] FAIL: OOB sample did not compile: $src" >&2
    cat "$out.diag" >&2 2>/dev/null || true
    exit 1
  fi
}
oob_compile_one "$oobdir/arr_get.vibe" "$oobdir/arr_get.wasm"
oob_compile_one "$oobdir/arr_set.vibe" "$oobdir/arr_set.wasm"
oob_compile_one "$oobdir/bytes_get.vibe" "$oobdir/bytes_get.wasm"
oob_compile_one "$oobdir/bytes_set.vibe" "$oobdir/bytes_set.wasm"
oob_compile_one "$oobdir/str_byte_at.vibe" "$oobdir/str_byte_at.wasm"
oob_run_one() {
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$1" 2>&1
}
oob_check() {
  local label="$1" msg="$2" loc="$3" out="$4" rc="$5"
  if [ "$rc" -eq 0 ]; then
    echo "[compiler-gate] FAIL: $label OOB access did not trap (exit 0)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -qF "$msg"; then
    echo "[compiler-gate] FAIL: $label OOB trap did not report operation + index + length (#2199)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -qF "$loc"; then
    echo "[compiler-gate] FAIL: $label OOB trap did not report editable path:line $loc (#2199)" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
set +e
oob_arr_get_out="$(oob_run_one "$oobdir/arr_get.wasm")"
oob_arr_get_rc=$?
oob_arr_set_out="$(oob_run_one "$oobdir/arr_set.wasm")"
oob_arr_set_rc=$?
oob_bytes_get_out="$(oob_run_one "$oobdir/bytes_get.wasm")"
oob_bytes_get_rc=$?
oob_bytes_set_out="$(oob_run_one "$oobdir/bytes_set.wasm")"
oob_bytes_set_rc=$?
oob_str_out="$(oob_run_one "$oobdir/str_byte_at.wasm")"
oob_str_rc=$?
set -e
# The expected location carries the DIRECTORY the source was compiled from,
# not just its file name: `vibe.dbgfiles` holds the path the compiler opened
# so the location is openable from the project root and still names one file
# when a program pulls in two packages that each have an `index.vibe`
# (#2199, PR #2867).
oob_check "Array::get" "Array::get: index 10 out of bounds for length 3" "$oobdir/arr_get.vibe:4" "$oob_arr_get_out" "$oob_arr_get_rc"
oob_check "Array::set" "Array::set: index 10 out of bounds for length 3" "$oobdir/arr_set.vibe:4" "$oob_arr_set_out" "$oob_arr_set_rc"
oob_check "Bytes::get" "Bytes::get: index 9 out of bounds for length 3" "$oobdir/bytes_get.vibe:4" "$oob_bytes_get_out" "$oob_bytes_get_rc"
oob_check "Bytes::set" "Bytes::set: index 9 out of bounds for length 3" "$oobdir/bytes_set.vibe:4" "$oob_bytes_set_out" "$oob_bytes_set_rc"
oob_check "String::byte_at" "String::byte_at: index 5 out of bounds for length 3" "$oobdir/str_byte_at.vibe:4" "$oob_str_out" "$oob_str_rc"
# Stripped mapping: OOB line and wasm frame remain; no fabricated path:line.
node scripts/wasm_custom_section.js strip "$oobdir/arr_get.wasm" "$oobdir/arr_get.stripped.wasm" vibe.linemap vibe.dbgfiles
set +e
oob_stripped_out="$(oob_run_one "$oobdir/arr_get.stripped.wasm")"
oob_stripped_rc=$?
set -e
if [ "$oob_stripped_rc" -eq 0 ]; then
  echo "[compiler-gate] FAIL: stripped-mapping OOB access did not trap" >&2
  printf '%s\n' "$oob_stripped_out" >&2
  exit 1
fi
if ! printf '%s\n' "$oob_stripped_out" | grep -qF "Array::get: index 10 out of bounds for length 3"; then
  echo "[compiler-gate] FAIL: stripped-mapping OOB lost the operation/index/length line" >&2
  printf '%s\n' "$oob_stripped_out" >&2
  exit 1
fi
if printf '%s\n' "$oob_stripped_out" | grep -qE '[A-Za-z0-9_.-]+\.vibe:[0-9]+'; then
  echo "[compiler-gate] FAIL: stripped-mapping OOB fabricated a path:line (#2199)" >&2
  printf '%s\n' "$oob_stripped_out" >&2
  exit 1
fi
if ! printf '%s\n' "$oob_stripped_out" | grep -qE 'wasm-function\[|RuntimeError:'; then
  echo "[compiler-gate] FAIL: stripped-mapping OOB lost the wasm frame" >&2
  printf '%s\n' "$oob_stripped_out" >&2
  exit 1
fi
echo "[compiler-gate] OOB abort messages + path:line ok (five ops; stripped mapping degrades)"

# 4f. #2362: `insert_raw`'s probe walk is BOUNDED. `find_index` has carried a
#     step guard since it was written; the insert path walking the same chain
#     under the same invariant did not, so a table with no empty slot spun
#     forever -- the least diagnosable way to fail. The state is unreachable
#     through `MutMap::set`, which grows before every insert, so the probe
#     below reaches it the way an accounting bug would: by under-counting
#     `m.tombs`, which is exactly what the growth check reads.
#
#     The assertion is TERMINATION, timed: before the guard this program ran
#     until something killed it, so a plain "did it fail?" check passes either
#     way -- a hang and a trap are both non-zero once a timeout is involved.
#     `timeout` reports 124 when it had to intervene, and that is the value
#     this pins against.
echo "[compiler-gate] 4f insert_raw's probe walk is bounded (#2362)"
hmdir="_build/_gate_hashmap_bound"
rm -rf "$hmdir"; mkdir -p "$hmdir"
cat > "$hmdir/fill.vibe" <<'VEOF'
import @vibe/core { struct MutMap }

fn main allows Console {
  let m: MutMap[String, Int] = MutMap::with_capacity_string(8)
  println("filling")
  let mut i = 0
  while i < 40 {
    let k = "k\{i}"
    MutMap::set(m, k, i)
    let _ = MutMap::delete(m, k)
    m.tombs = m.tombs - 1
    i = i + 1
  }
  println("returned")
}
VEOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hmdir/fill.vibe" "$hmdir/fill.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$hmdir/fill.wasm" ]; then
  echo "[compiler-gate] FAIL: #2362 probe did not compile" >&2
  cat "$hmdir/fill.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
set +e
hm_out="$(run_bounded 60 env VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$hmdir/fill.wasm" 2>&1)"
hm_rc=$?
set -e
rm -rf "$hmdir"
if [ "$hm_rc" -eq 124 ]; then
  echo "[compiler-gate] FAIL: a full table made insert_raw spin -- the probe had to be killed at the time limit (#2362)" >&2
  printf '%s\n' "$hm_out" >&2
  exit 1
fi
if [ "$hm_rc" -eq 0 ]; then
  echo "[compiler-gate] FAIL: insert_raw accepted an insert into a table with no free slot (#2362)" >&2
  printf '%s\n' "$hm_out" >&2
  exit 1
fi
if ! printf '%s\n' "$hm_out" | grep -qF "filling"; then
  echo "[compiler-gate] FAIL: the #2362 probe failed before it reached the fill loop, so it proves nothing" >&2
  printf '%s\n' "$hm_out" >&2
  exit 1
fi
echo "[compiler-gate] insert_raw bounded probe ok (terminated, rc=$hm_rc)"

# 4g. #2343: `declarations.vibe` declares ~50 low-level wasm opcodes that user
#     code cannot spell. The file called itself "Single Source of Truth for all
#     builtin function signatures" and recorded nothing about reachability, so
#     a reader looking for a ctz found `declare int_ctz(Int) -> Int`, wrote it,
#     and got `unknown name`. The block now says it is codegen-internal; this
#     checks the claim rather than trusting the comment.
#
#     The oracle is the CHECKER, one probe per name -- not a lookup in
#     `core/builtin_registry.vibe`, which decides only some names (the rest go
#     through per-namespace checker lookups), so a registry cross-reference
#     would answer a different question than the one the comment makes.
#
#     Each name is probed in BOTH the value form (`let _x = n`) and the call
#     form (`n(a0, ...)` at the declared arity). They are not the same question:
#     the checker's `ECall` arm resolves the callee through `direct_call_return`
#     and does not re-check the callee `EIdent`, so a name reached only by that
#     fast path type-checks as a call while the value form still reports
#     `unknown name`. Measured on `__len`, which is in `direct_builtin_return`:
#     `let _x = __len` gives `unknown name: __len`, `__len(a)` gives no
#     diagnostic at all. A value-only probe therefore certifies as unreachable
#     a name user code can call -- exactly the state this section exists to
#     catch (Codex review). A name counts as unreachable only when BOTH forms
#     report it unknown.
#
#     The call probe spells each declared parameter type verbatim as an
#     annotation. If that spelling is ever wrong (a parameter type containing a
#     top-level comma would split badly), the checker answers with some OTHER
#     diagnostic, not `unknown name`, and the name is reported reachable -- the
#     section fails loudly rather than passing on a probe that never compiled.
#
#     Controls run alongside: `simd_skip_ws`, declared in the same file two
#     blocks down, MUST resolve in both forms. Without them, a probe harness
#     that silently failed to compile anything would report all-unreachable and
#     pass.
#
#     #2433 changed what "resolves" looks like in the VALUE form, and the
#     control had to follow: a builtin used as a value became a checker error
#     on every lane, so `let _x = simd_skip_ws` reported "`simd_skip_ws` is a
#     builtin operation, not a value" where it used to report nothing. That
#     expectation was then doing two jobs at once -- proving the name resolves,
#     and proving the harness emits diagnostics at all.
#
#     #2442 took the first job back. Bare builtin names have value forms now,
#     and `simd_skip_ws` is a pure, fully concrete arity-3 row, so
#     `let _x = simd_skip_ws` compiles and reports NOTHING again. The two jobs
#     are therefore split, because one control can no longer do both:
#
#       * REACHABILITY stays on simd_skip_ws, in both forms, and is what the
#         classifier actually uses -- the name is not `unknown name`. With a
#         value form that is again "no diagnostic at all", the same assertion
#         the call form makes.
#       * LIVENESS moves to a name that is STILL refused in value position. An
#         effectful builtin is the permanent case (`builtin_value_form_arity`
#         refuses an effect row by design, not as a gap), so `let _x =
#         Fs::read_file` must report "not a value" NAMING Fs::read_file. That
#         is what an empty `.diag` from a dead runner cannot satisfy, which is
#         the property #2433 added here.
#
#     The CLASSIFIER above is unaffected either way: it counts a name
#     unreachable only when both forms say `unknown name: <n>`, and neither
#     "not a value" nor an empty diagnostic is that string.
echo "[compiler-gate] 4g the WASM-intrinsics block is codegen-internal, as it claims (#2343)"
dcldir="_build/_gate_declarations_reach"
rm -rf "$dcldir"; mkdir -p "$dcldir"
decl_src="lib/@vibe/compiler/builtins/declarations.vibe"
# The block runs from its own banner to the next one. `name|T0,T1,...`.
intrinsic_decls="$(awk '
  /^\/\/# WASM intrinsics/ { inblock = 1; next }
  inblock && /^\/\/#/ { inblock = 0; next }
  inblock && /^declare / {
    line = $0
    sub(/^declare /, "", line)
    name = line; sub(/\(.*$/, "", name)
    params = line; sub(/^[^(]*\(/, "", params); sub(/\).*$/, "", params)
    gsub(/ /, "", params)
    print name "|" params
  }
' "$decl_src")"
intrinsic_names="$(printf '%s\n' "$intrinsic_decls" | sed 's/|.*$//' | grep . || true)"
intrinsic_count="$(printf '%s\n' "$intrinsic_names" | grep -c . || true)"
if [ "$intrinsic_count" -lt 40 ]; then
  echo "[compiler-gate] FAIL: found only $intrinsic_count names under the WASM-intrinsics banner in $decl_src -- the block moved or the scan broke, and an empty scan would pass this section vacuously (#2343)" >&2
  exit 1
fi
# A floor catches an empty scan; it does not catch one that runs PAST the block
# and swallows the reachable names below it (which is what the first version of
# this scan did, reporting Fs:: and Env:: as unreachable intrinsics). The
# control name lives two blocks down, so its presence here means exactly that.
if printf '%s\n' "$intrinsic_names" | grep -qx "simd_skip_ws"; then
  echo "[compiler-gate] FAIL: the #2343 scan ran past the WASM-intrinsics block -- it collected simd_skip_ws, which is declared under a later banner" >&2
  exit 1
fi
# The CHECK lane, and the diagnostic itself -- not "was a wasm produced?".
# Those differ: a name that becomes checker-visible but has no linear
# function-table entry RESOLVES and still emits no wasm, so an
# artifact-existence test would file it under "unreachable" -- a false pass on
# exactly the state this section exists to catch (Codex review). `unknown
# name: <n>` is the checker saying it, and nothing else produces that line.
decl_probe_reports_unknown() { # <probe-source> <name>
  local src="$1" name="$2"
  rm -f "$dcldir/p.vibe" "$dcldir/p.out" "$dcldir/p.out.diag"
  cp "$src" "$dcldir/p.vibe"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$dcldir/p.vibe" "$dcldir/p.out" __no_entry__ check >/dev/null 2>&1 || true
  grep -qF "unknown name: $name" "$dcldir/p.out.diag" 2>/dev/null
}
reachable=""
while IFS='|' read -r n params; do
  [ -n "$n" ] || continue
  printf 'fn probe() -> Int {\n  let _x = %s\n  0\n}\n' "$n" > "$dcldir/value.vibe"
  sig=""; args=""; argno=0
  if [ -n "$params" ]; then
    saved_ifs="$IFS"
    IFS=','
    for pty in $params; do
      if [ -n "$sig" ]; then sig="$sig, "; args="$args, "; fi
      sig="${sig}a${argno}: ${pty}"
      args="${args}a${argno}"
      argno=$((argno + 1))
    done
    IFS="$saved_ifs"
  fi
  printf 'fn probe(%s) -> Int {\n  let _r = %s(%s)\n  0\n}\n' "$sig" "$n" "$args" > "$dcldir/call.vibe"
  if decl_probe_reports_unknown "$dcldir/value.vibe" "$n" \
     && decl_probe_reports_unknown "$dcldir/call.vibe" "$n"; then
    :
  else
    reachable="$reachable $n"
  fi
done <<DECLS
$intrinsic_decls
DECLS
# The controls: a name from the same file that IS reachable -- both forms must
# produce NO diagnostic. Without them, a harness whose probes all failed to run
# would report every name unreachable and pass.
for ctl_form in value call; do
  if [ "$ctl_form" = "value" ]; then
    printf 'fn probe() -> Int {\n  let _x = simd_skip_ws\n  0\n}\n' > "$dcldir/ctl.vibe"
  else
    printf 'fn probe(b: Bytes) -> Int {\n  simd_skip_ws(b, 0, 1)\n}\n' > "$dcldir/ctl.vibe"
  fi
  rm -f "$dcldir/ctl.out" "$dcldir/ctl.out.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$dcldir/ctl.vibe" "$dcldir/ctl.out" __no_entry__ check >/dev/null 2>&1 || true
  if grep -qF "unknown name: simd_skip_ws" "$dcldir/ctl.out.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: the #2343 $ctl_form-form control reported simd_skip_ws unknown -- it is declared in $decl_src and must resolve, so this harness is calling everything unreachable" >&2
    cat "$dcldir/ctl.out.diag" >&2 2>/dev/null || true
    rm -rf "$dcldir"
    exit 1
  fi
  if [ -s "$dcldir/ctl.out.diag" ]; then
    echo "[compiler-gate] FAIL: the #2343 $ctl_form-form control reported a diagnostic -- simd_skip_ws is declared in $decl_src and must resolve, so this harness is calling everything unreachable" >&2
    cat "$dcldir/ctl.out.diag" >&2 2>/dev/null || true
    rm -rf "$dcldir"
    exit 1
  fi
done
# LIVENESS (#2433's property, re-homed by #2442). The reachability control
# above now expects an EMPTY diagnostic in both forms, and an empty `.diag` is
# exactly what a dead runner produces -- so on its own it would pass while
# compiling nothing, which is the failure mode #2433 closed here.
#
# This probe must therefore still be REFUSED. An effectful builtin is the case
# that cannot quietly gain a value form the way `simd_skip_ws` did: an effect
# row is refused by `builtin_value_form_arity` by design (a value form would
# carry authority to an indirect call site where the row is not checked --
# ADR-0075/0084/0088), not as a gap someone may close.
printf 'fn probe() -> Int {\n  let _x = Fs::read_file\n  0\n}\n' > "$dcldir/ctl.vibe"
rm -f "$dcldir/ctl.out" "$dcldir/ctl.out.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$dcldir/ctl.vibe" "$dcldir/ctl.out" __no_entry__ check >/dev/null 2>&1 || true
if ! grep -qF "not a value" "$dcldir/ctl.out.diag" 2>/dev/null \
   || ! grep -qF "Fs::read_file" "$dcldir/ctl.out.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the #2343 liveness control did not produce the expected \"not a value\" diagnostic naming Fs::read_file -- the probe did not compile, or the diagnostic changed, so this harness is not measuring reachability (#2433/#2442)" >&2
  cat "$dcldir/ctl.out.diag" >&2 2>/dev/null || true
  rm -rf "$dcldir"
  exit 1
fi
rm -rf "$dcldir"
if [ -n "$reachable" ]; then
  echo "[compiler-gate] FAIL: these names are under the codegen-internal WASM-intrinsics banner in $decl_src but the checker resolved them in the value form, the call form, or both:$reachable" >&2
  echo "    Either move them out of that block, or drop the claim. The banner says the block is unreachable (#2343)." >&2
  exit 1
fi
echo "[compiler-gate] declarations.vibe reachability claim ok ($intrinsic_count intrinsics unreachable in both value and call form, controls resolve)"

# 5. test-block regression (#594): a file with only `test {}` blocks (no entry)
#    must compile to a valid module whose `_start` runs every test; a passing
#    file exits clean and a failing assert traps. Guards the codegen fix that
#    stopped exporting a nonexistent entry function (call/export index -1).
echo "[compiler-gate] 5/5 test-block compile+run regression"
tdir="_build/_gate_testblock"
rm -rf "$tdir"; mkdir -p "$tdir"
printf 'test "ok" {\n  assert_eq(2 + 2, 4)\n}\n' > "$tdir/pass_test.vibe"
printf 'test "bad" {\n  assert_eq(2 + 2, 5)\n}\n' > "$tdir/fail_test.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/pass_test.vibe" "$tdir/pass_test.wasm" __no_entry__ >/dev/null 2>&1
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tdir/fail_test.vibe" "$tdir/fail_test.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$tdir/pass_test.wasm" ] || [ ! -s "$tdir/fail_test.wasm" ]; then
  echo "[compiler-gate] FAIL: test-block compile produced no wasm" >&2; exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$tdir/pass_test.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: passing test file did not run clean" >&2; exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$tdir/fail_test.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: failing test file did not trap" >&2; exit 1
fi
rm -rf "$tdir"
echo "[compiler-gate] test-block regression ok"

# 6. normalize regression (#594): `vibe normalize` (VIBE_NORMALIZE=1) canonicalizes
#    a source file — DCE from exported roots + section layout — via the
#    in-compiler engine. Guards that a future seed keeps it working and
#    idempotent. The flat selfbuild source strips imports, so the fixpoint
#    above does not exercise the normalize entry; assert it directly.
#    (Module blocks were removed in #728; flatten coverage retired with them.)
echo "[compiler-gate] 6/6 normalize compile+run regression"
ndir="_build/_gate_normalize"
rm -rf "$ndir"; mkdir -p "$ndir"
printf 'let dead: () -> Int = () -> { 0 }\nlet helper: () -> Int = () -> { 1 }\nexport let run: () -> Int = () -> { helper() }\n' > "$ndir/in.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/in.vibe" "$ndir/out.vibe" >/dev/null 2>&1 || true
if [ ! -s "$ndir/out.vibe" ]; then
  echo "[compiler-gate] FAIL: normalize produced no output" >&2; exit 1
fi
# `dead` must be eliminated; `helper` (reached from the exported `run`) kept.
if grep -q "dead" "$ndir/out.vibe" || ! grep -q "helper" "$ndir/out.vibe"; then
  echo "[compiler-gate] FAIL: normalize DCE incorrect" >&2
  cat "$ndir/out.vibe" >&2; exit 1
fi
# Removed/guarded syntax must be refused by the CURRENT stage2 (the committed
# seed lags until the next bump, so these checks live here, not in the
# seed-driven normalize smoke): module blocks are removed (#728).
printf 'module m {\n  export let run: () -> Int = () -> { 1 }\n}\n' > "$ndir/reject_module.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/reject_module.vibe" "$ndir/reject_module.out.vibe" >/dev/null 2>&1 \
  && [ -s "$ndir/reject_module.out.vibe" ]; then
  echo "[compiler-gate] FAIL: module-block source was not rejected (#728)" >&2; exit 1
fi
# fn round-trip (ADR-0064 #727): normalize must KEEP `fn` declarations —
# including the `where` contract — in fn form (SFnDecl + printer support),
# not rewrite them to `let rec` + inlined asserts; and stay idempotent.
printf 'fn checked_inc(x: Int) -> Int where { requires: x >= 0, ensures: result > x } { x + 1 }\nexport fn run() -> Int { checked_inc(41) }\nexport { run }\n' > "$ndir/keep_fn.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/keep_fn.vibe" "$ndir/keep_fn.out.vibe" >/dev/null 2>&1 || true
if [ ! -s "$ndir/keep_fn.out.vibe" ]; then
  echo "[compiler-gate] FAIL: fn-bearing source was not normalized (#727)" >&2; exit 1
fi
if ! grep -q "fn checked_inc" "$ndir/keep_fn.out.vibe" \
  || ! grep -q "fn run" "$ndir/keep_fn.out.vibe" \
  || ! grep -q "where { requires:" "$ndir/keep_fn.out.vibe" \
  || ! grep -q "ensures:" "$ndir/keep_fn.out.vibe" \
  || grep -q "let rec checked_inc" "$ndir/keep_fn.out.vibe"; then
  echo "[compiler-gate] FAIL: normalize did not keep the fn + where form (#727)" >&2
  cat "$ndir/keep_fn.out.vibe" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/keep_fn.out.vibe" "$ndir/keep_fn.out2.vibe" >/dev/null 2>&1
if ! cmp -s "$ndir/keep_fn.out.vibe" "$ndir/keep_fn.out2.vibe"; then
  echo "[compiler-gate] FAIL: fn normalize not idempotent (#727)" >&2
  diff "$ndir/keep_fn.out.vibe" "$ndir/keep_fn.out2.vibe" >&2 || true; exit 1
fi
# Idempotency: normalize(normalize(x)) == normalize(x).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/out.vibe" "$ndir/out2.vibe" >/dev/null 2>&1
if ! cmp -s "$ndir/out.vibe" "$ndir/out2.vibe"; then
  echo "[compiler-gate] FAIL: normalize not idempotent" >&2; exit 1
fi
# Normalized output must still typecheck: compiling a copy with an entry
# must succeed.
cp "$ndir/out.vibe" "$ndir/compile.vibe"
printf '\nexport let _start: () -> Int = () -> { run() }\n' >> "$ndir/compile.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/compile.vibe" "$ndir/out.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ndir/out.wasm" ]; then
  echo "[compiler-gate] FAIL: normalized output does not compile" >&2
  cat "$ndir/compile.vibe" >&2; exit 1
fi
rm -rf "$ndir"
echo "[compiler-gate] normalize regression ok"

# 6b. contract package regression (#729): an index.vibei contract package must
#     resolve via a bare directory import (conformance-check + facade desugar,
#     end to end through the current stage2), and its internals must NOT be
#     importable from a different nearest-owner package (#897 / ADR-0070).
echo "[compiler-gate] 6b contract package + boundary regression (#729)"
cdir="_build/_gate_contract"
rm -rf "$cdir"; mkdir -p "$cdir/pkg"
printf 'import ./impl.vibe {}\nfn add(x: Int, y: Int) -> Int\n' > "$cdir/pkg/index.vpkg"
printf 'export fn add(x: Int, y: Int) -> Int { x + y }\n' > "$cdir/pkg/impl.vibe"
printf 'import ./pkg { add }\nexport let _start: () -> Int = () -> { add(40, 2) }\n' > "$cdir/ok.vibe"
# #749 canary: run this compile with a COLD persistent cache. The runner's
# module-init _start executes the same pipeline once before the real cli_main
# invoke; a first-pass failure is masked in the exit code but leaves a .diag
# beside the (valid) wasm the second pass writes. Cold-only ingestion rot
# (#740/#749 class) surfaces exactly there, so assert "no sidecar" too.
find "$ROOT_DIR/_build" -maxdepth 1 -type f -name "vibe_*" -delete 2>/dev/null || true
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/ok.vibe" "$cdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: contract package import did not compile (#729)" >&2
  cat "$cdir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
if [ -s "$cdir/ok.wasm.diag" ]; then
  echo "[compiler-gate] FAIL: cold contract compile left a stale .diag beside a valid wasm (#749 first-pass ingestion failure)" >&2
  cat "$cdir/ok.wasm.diag" >&2; exit 1
fi
printf 'import ./pkg/impl.vibe { add }\nexport let _start: () -> Int = () -> { add(40, 2) }\n' > "$cdir/bad.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/bad.vibe" "$cdir/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$cdir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: package-internal import crossed the boundary (#729)" >&2; exit 1
fi
if ! grep -q "package boundary" "$cdir/bad.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: boundary rejection lacks the expected diagnostic (#729)" >&2
  cat "$cdir/bad.wasm.diag" >&2 2>/dev/null; exit 1
fi
rm -rf "$cdir"
echo "[compiler-gate] contract package + boundary regression ok"

# 6b2. generic-struct contract arity regression (#829/#841 follow-up):
#      collect_impl_type_defs used to hardcode a struct's type-parameter
#      arity as 0 regardless of its actual `[T]` header, so a package
#      exporting `struct Box[T] { ... }` had no arity-correct way to declare
#      `type Box[T]` in its own contract (multiple #841 packages worked
#      around this by writing a nullary `type Box`, which is now WRONG and
#      must itself be rejected — the under-declared arity 0 no longer
#      matches the impl's real arity 1).
echo "[compiler-gate] 6b2 generic-struct contract arity regression (#829/#841)"
gsdir="_build/_gate_genstruct_contract"
rm -rf "$gsdir"; mkdir -p "$gsdir/pkg"
printf 'export struct Box[T] {\n  v: T\n}\n\nexport fn Box::wrap[T](v: T) -> Box[T] {\n  Box::{ v: v }\n}\n' > "$gsdir/pkg/box.vibe"
printf 'version 0.0.1\nimport ./box.vibe {}\ntype Box[T]\nfn Box::wrap[T](v: T) -> Box[T]\n' > "$gsdir/pkg/index.vibei"
printf 'import ./pkg { Box::wrap }\nexport let _start: () -> Int = () -> { 0 }\n' > "$gsdir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gsdir/ok.vibe" "$gsdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$gsdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: contract-correct 'type Box[T]' arity was rejected (over-reject)" >&2
  cat "$gsdir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
printf 'version 0.0.1\nimport ./box.vibe {}\ntype Box\nfn Box::wrap[T](v: T) -> Box[T]\n' > "$gsdir/pkg/index.vibei"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gsdir/ok.vibe" "$gsdir/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$gsdir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: nullary 'type Box' contract for a struct Box[T] impl compiled (arity under-declaration not caught)" >&2; exit 1
fi
if ! grep -q "arity mismatch" "$gsdir/bad.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: struct arity mismatch rejection lacks the expected diagnostic" >&2
  cat "$gsdir/bad.wasm.diag" >&2 2>/dev/null; exit 1
fi
rm -rf "$gsdir"
echo "[compiler-gate] generic-struct contract arity regression ok"

# 6b2b. explicit struct type arguments (#886): `Pair[Int]::{ .. }` pins the
#      instantiation (parse + arity check + checker pinning). Positive: the
#      explicit form compiles and runs, including a field inference alone
#      cannot decide (empty array). Negatives: a type-argument arity mismatch
#      and a field value conflicting with the pinned argument must both be
#      rejected with their dedicated diagnostics (not a generic parse error).
echo "[compiler-gate] 6b2b explicit struct type args (#886)"
stdir="_build/_gate_struct_targs"
rm -rf "$stdir"; mkdir -p "$stdir"
printf 'struct Pair[T] {\n  a: T;\n  b: T\n}\n\nstruct Bag[T] {\n  xs: Array[T]\n}\n\nexport let _start: () -> Unit with Console = () -> {\n  let p = Pair[Int]::{ a: 1, b: 2 }\n  assert_eq(p.a + p.b, 3)\n  let g = Bag[Int]::{ xs: [] }\n  Array::push(g.xs, 42)\n  assert_eq(Array::get(g.xs, 0), 42)\n  let n = Pair[Array[Int]]::{ a: [1, 2], b: [] }\n  assert_eq(Array::length(n.a), 2)\n}\n' > "$stdir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$stdir/ok.vibe" "$stdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$stdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: explicit struct type args (#886) did not compile" >&2
  cat "$stdir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$stdir/ok.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: explicit struct type args (#886) compiled but trapped at runtime" >&2; exit 1
fi
printf 'struct Pair[T] {\n  a: T;\n  b: T\n}\n\nexport let _start: () -> Unit with Console = () -> {\n  let p = Pair[Int, String]::{ a: 1, b: 2 }\n  assert_eq(p.a, 1)\n}\n' > "$stdir/arity.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$stdir/arity.vibe" "$stdir/arity.wasm" _start >/dev/null 2>&1 \
  && [ -s "$stdir/arity.wasm" ]; then
  echo "[compiler-gate] FAIL: struct type-arg arity mismatch (#886) was not rejected" >&2; exit 1
fi
if ! grep -q "expects 1 type argument(s), got 2" "$stdir/arity.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: type-arg arity rejection lacks the expected diagnostic (#886)" >&2
  cat "$stdir/arity.wasm.diag" >&2 2>/dev/null; exit 1
fi
printf 'struct Pair[T] {\n  a: T;\n  b: T\n}\n\nexport let _start: () -> Unit with Console = () -> {\n  let p = Pair[String]::{ a: 1, b: 2 }\n  assert_eq(p.a, "x")\n}\n' > "$stdir/pin.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$stdir/pin.vibe" "$stdir/pin.wasm" _start >/dev/null 2>&1 \
  && [ -s "$stdir/pin.wasm" ]; then
  echo "[compiler-gate] FAIL: field value conflicting with pinned type arg (#886) was not rejected" >&2; exit 1
fi
if ! grep -q "struct field type mismatch for a" "$stdir/pin.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: pinned-arg field mismatch rejection lacks the expected diagnostic (#886)" >&2
  cat "$stdir/pin.wasm.diag" >&2 2>/dev/null; exit 1
fi
rm -rf "$stdir"
echo "[compiler-gate] explicit struct type args (#886) ok"

# 6b3. cross-package contract import resolution regression (#842): a bare
#      directory-style import inside an index.vibei CONTRACT (not just an
#      implementation .vibe file) must resolve to the sibling package's own
#      index.vibei/index.vibe, the same directory-first order the regular
#      loader uses -- desugar_contract_source_fs used to skip straight to the
#      single-file form (`../pkgb.vibe`) and ENOENT. package A's contract
#      references package B's opaque type by NAME (`import ../pkgb { type X }`)
#      instead of the #841-era workaround (referencing the bare name with no
#      import at all); the cross-package .vibei target must also be routed
#      through the normal facade desugar (not parsed as raw contract grammar).
echo "[compiler-gate] 6b3 cross-package contract import resolution regression (#842)"
xpdir="_build/_gate_contract_crosspkg"
rm -rf "$xpdir"; mkdir -p "$xpdir/pkgb" "$xpdir/pkga"
printf 'import ./impl.vibe {}\nopaque type X\nfn make(v: Int) -> X\nfn value(x: X) -> Int\n' > "$xpdir/pkgb/index.vibei"
printf 'export struct X {\n  v: Int\n}\n\nexport fn make(v: Int) -> X {\n  X::{ v: v }\n}\n\nexport fn value(x: X) -> Int {\n  x.v\n}\n' > "$xpdir/pkgb/impl.vibe"
printf 'import ./impl.vibe {}\nimport ../pkgb { type X }\nfn wrap(v: Int) -> X\n' > "$xpdir/pkga/index.vibei"
printf 'import ../pkgb { X, make }\nexport fn wrap(v: Int) -> X {\n  make(v)\n}\n' > "$xpdir/pkga/impl.vibe"
printf 'import ./pkga { wrap }\nimport ./pkgb { value }\nexport let _start: () -> Int = () -> { value(wrap(42)) }\n' > "$xpdir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xpdir/ok.vibe" "$xpdir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xpdir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: .vibei contract's cross-package directory import (../pkgb) did not resolve (#842)" >&2
  cat "$xpdir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
xpres="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$xpdir/ok.wasm" 2>/dev/null | tr -dc '0-9')"
rm -rf "$xpdir"
if [ "$xpres" != "42" ]; then
  echo "[compiler-gate] FAIL: cross-package contract import sample returned '$xpres' (expected 42)" >&2
  exit 1
fi
echo "[compiler-gate] cross-package contract import resolution regression ok"

# 6c. content-addressed store regression (#730 D-2): `vibe hash` prints a
#     store package's pin; a require-pinned `import @scope/name` resolves
#     through .vibe/store/ with hash verification; a wrong pin is rejected.
echo "[compiler-gate] 6c content-addressed store regression (#730)"
sdir=".vibe/store/@gate/d2pkg"
rm -rf ".vibe/store/@gate"; mkdir -p "$sdir"
# The store copy declares its version (the vibe_pkg.sh publish contract
# requires the directive) -- the fill verifies it against the require
# constraint before pinning, and a versionless copy never fills (#2260).
printf 'version 1.0.0\nimport ./impl.vibe {}\nfn triple(x: Int) -> Int\n' > "$sdir/index.vibei"
printf 'export fn triple(x: Int) -> Int { x * 3 }\n' > "$sdir/impl.vibe"
cdir2="_build/_gate_store"
rm -rf "$cdir2"; mkdir -p "$cdir2"
VIBE_HASH=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$sdir/index.vibei" "$cdir2/hash.out" __no_entry__ >/dev/null 2>&1 || true
pin="$(grep '^package ' "$cdir2/hash.out" 2>/dev/null | cut -d' ' -f2)"
if [ -z "$pin" ]; then
  echo "[compiler-gate] FAIL: vibe hash produced no package pin (#730)" >&2
  cat "$cdir2/hash.out.diag" >&2 2>/dev/null; exit 1
fi
if ! printf '%s' "$pin" | grep -qE '^#pkg:b3:[0-9a-f]{64}$'; then
  echo "[compiler-gate] FAIL: vibe hash new write is not #pkg:b3:<64hex> (#2829)" >&2
  echo "$pin" >&2; exit 1
fi
printf 'require @gate/d2pkg 1.0.0 = %s\n\nimport @gate/d2pkg { triple }\nexport let _start: () -> Int = () -> { triple(14) }\n' "$pin" > "$cdir2/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/ok.vibe" "$cdir2/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir2/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: pinned store import did not compile (#730)" >&2
  cat "$cdir2/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
# #2227: check must agree with the build lane it just exercised -- the same
# require-pin head used to be a parse error on the check lane. A clean check
# writes no .diag sidecar.
rm -f "$cdir2/ok.checkout" "$cdir2/ok.checkout.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/ok.vibe" "$cdir2/ok.checkout" main >/dev/null 2>&1 || true
if [ -s "$cdir2/ok.checkout.diag" ]; then
  echo "[compiler-gate] FAIL: vibe check rejected the require-pin head the build lane accepts (#2227)" >&2
  cat "$cdir2/ok.checkout.diag" >&2; exit 1
fi
# #2227: same pin head in a .vibex -- the script-head directive scan used to
# read the pin's #pkg:sha1: as an unknown # directive before pin extraction.
printf 'require @gate/d2pkg 1.0.0 = %s\n\nimport @gate/d2pkg { triple }\n\nfn main allows () {\n  let _ = triple(14)\n}\n' "$pin" > "$cdir2/ok_pin.vibex"
rm -f "$cdir2/ok_pin.wasm" "$cdir2/ok_pin.wasm.diag"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/ok_pin.vibex" "$cdir2/ok_pin.wasm" main >/dev/null 2>&1 || true
if [ ! -s "$cdir2/ok_pin.wasm" ]; then
  echo "[compiler-gate] FAIL: a .vibex with a require-pin head did not compile (#2227)" >&2
  cat "$cdir2/ok_pin.wasm.diag" >&2 2>/dev/null; exit 1
fi
printf 'require @gate/d2pkg 1.0.0 = #pkg:sha1:0000000000000000000000000000000000000000\n\nimport @gate/d2pkg { triple }\nexport let _start: () -> Int = () -> { triple(14) }\n' > "$cdir2/bad.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/bad.vibe" "$cdir2/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$cdir2/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: wrong pin was not rejected (#730)" >&2; exit 1
fi
if ! grep -q "pin mismatch" "$cdir2/bad.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: pin rejection lacks the expected diagnostic (#730)" >&2
  cat "$cdir2/bad.wasm.diag" >&2 2>/dev/null; exit 1
fi
# D-3: an unpinned require refuses to build; VIBE_FILL_PINS completes it
# offline from the store; the filled source builds; the fill is idempotent.
printf 'require @gate/d2pkg 1.0.0\n\nimport @gate/d2pkg { triple }\nexport let _start: () -> Int = () -> { triple(14) }\n' > "$cdir2/unpinned.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/unpinned.vibe" "$cdir2/unpinned.wasm" _start >/dev/null 2>&1 \
  && [ -s "$cdir2/unpinned.wasm" ]; then
  echo "[compiler-gate] FAIL: unpinned require was not rejected (#730 D-3)" >&2; exit 1
fi
VIBE_FILL_PINS=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/unpinned.vibe" "$cdir2/filled.vibe" __no_entry__ >/dev/null 2>&1 || true
if ! grep -qE "= #pkg:b3:[0-9a-f]{64}" "$cdir2/filled.vibe" 2>/dev/null; then
  echo "[compiler-gate] FAIL: VIBE_FILL_PINS did not insert the pin (#730 D-3 / #2829)" >&2
  cat "$cdir2/filled.vibe.diag" >&2 2>/dev/null; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/filled.vibe" "$cdir2/filled.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir2/filled.wasm" ]; then
  echo "[compiler-gate] FAIL: pin-filled source did not compile (#730 D-3)" >&2
  cat "$cdir2/filled.wasm.diag" >&2 2>/dev/null; exit 1
fi
VIBE_NORMALIZE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir2/filled.vibe" "$cdir2/norm.vibe" >/dev/null 2>&1 || true
if ! head -1 "$cdir2/norm.vibe" 2>/dev/null | grep -qE "^require @gate/d2pkg 1.0.0 = #pkg:b3:[0-9a-f]{64}"; then
  echo "[compiler-gate] FAIL: normalize did not re-emit the require pin line (#730 D-3 / #2829)" >&2
  head -3 "$cdir2/norm.vibe" >&2 2>/dev/null; exit 1
fi
rm -rf ".vibe/store/@gate" "$cdir2"
echo "[compiler-gate] content-addressed store regression ok"

# 6h. workspace lib/ package resolution (#751, ADR-0065): `@scope/name`
#     resolves through lib/@scope/name/index.vibei WITHOUT a require pin
#     (dev-mode lane; the pinned store stays first in candidate order). A pin,
#     when present, is still the truth: a wrong pin against the lib/ copy is
#     rejected. The package below declares no impl imports, so this also
#     exercises sibling auto-discovery (#730) through the lib/ path.
echo "[compiler-gate] 6h workspace lib/ package resolution (#751)"
lpkg="lib/@gate751/greet"
rm -rf "lib/@gate751"; mkdir -p "$lpkg"
printf 'fn greet_n(x: Int) -> Int\n' > "$lpkg/index.vibei"
printf 'export fn greet_n(x: Int) -> Int { x + 2 }\n' > "$lpkg/impl.vibe"
ldir="_build/_gate_lib751"
rm -rf "$ldir"; mkdir -p "$ldir"
printf 'import @gate751/greet { greet_n }\nexport let _start: () -> Int = () -> { greet_n(40) }\n' > "$ldir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/ok.vibe" "$ldir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ldir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: unpinned lib/ package import did not compile (#751)" >&2
  cat "$ldir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
printf 'require @gate751/greet 1.0.0 = #pkg:sha1:0000000000000000000000000000000000000000\n\nimport @gate751/greet { greet_n }\nexport let _start: () -> Int = () -> { greet_n(40) }\n' > "$ldir/bad.vibe"
if VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/bad.vibe" "$ldir/bad.wasm" _start >/dev/null 2>&1 \
  && [ -s "$ldir/bad.wasm" ]; then
  echo "[compiler-gate] FAIL: wrong pin against a lib/ copy was not rejected (#751)" >&2; exit 1
fi
if ! grep -q "pin mismatch" "$ldir/bad.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: lib/ pin rejection lacks the expected diagnostic (#751)" >&2
  cat "$ldir/bad.wasm.diag" >&2 2>/dev/null; exit 1
fi
rm -rf "lib/@gate751" "$ldir"
echo "[compiler-gate] workspace lib/ package resolution ok"

# 6i. VIBE_LIB external roots + freeze (#751, ADR-0065): an @scope/name
#     package living OUTSIDE the workspace resolves through a VIBE_LIB root
#     (":"-separated list; missing roots are skipped in order). The
#     workspace lib/ copy wins over an external root when both exist, and
#     VIBE_REQUIRE_PINS=1 (the release/publish freeze switch) rejects any
#     pin-less dev-mode lib resolution. Each step uses a distinct consumer
#     file: the persistent header/dep caches key on content, and the SAME
#     content under a different VIBE_LIB would replay the previous
#     resolution.
echo "[compiler-gate] 6i VIBE_LIB external roots + freeze (#751)"
xroot="$(mktemp -d)"
xpkg="$xroot/@gate751x/echo"
mkdir -p "$xpkg"
printf 'fn echo_n(x: Int) -> Int\n' > "$xpkg/index.vibei"
printf 'export fn echo_n(x: Int) -> Int { x + 2 }\n' > "$xpkg/impl.vibe"
xdir="_build/_gate_lib751x"
rm -rf "$xdir" "lib/@gate751x"; mkdir -p "$xdir"
# (1) without a usable root the name must NOT resolve
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) }\n' > "$xdir/miss.vibe"
if VIBE_LIB="$xroot/does-not-exist" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/miss.vibe" "$xdir/miss.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/miss.wasm" ]; then
  echo "[compiler-gate] FAIL: external package resolved without a VIBE_LIB root (#751)" >&2; exit 1
fi
# (2) a ":"-separated VIBE_LIB resolves through the first root that has the
#     package (missing roots skipped); the compiled program runs.
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) + 0 }\n' > "$xdir/ext.vibe"
VIBE_LIB="$xroot/does-not-exist:$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/ext.vibe" "$xdir/ext.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/ext.wasm" ]; then
  echo "[compiler-gate] FAIL: VIBE_LIB root resolution did not compile (#751)" >&2
  cat "$xdir/ext.wasm.diag" >&2 2>/dev/null; exit 1
fi
ext_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$xdir/ext.wasm" 2>/dev/null | tail -1)"
if [ "$ext_out" != "42" ]; then
  echo "[compiler-gate] FAIL: VIBE_LIB-resolved package returned '$ext_out' (want 42) (#751)" >&2; exit 1
fi
# (3) the workspace lib/ copy wins over the external root
mkdir -p "lib/@gate751x/echo"
printf 'fn echo_n(x: Int) -> Int\n' > "lib/@gate751x/echo/index.vibei"
printf 'export fn echo_n(x: Int) -> Int { x + 3 }\n' > "lib/@gate751x/echo/impl.vibe"
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) + 0 + 0 }\n' > "$xdir/ws.vibe"
VIBE_LIB="$xroot/does-not-exist:$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/ws.vibe" "$xdir/ws.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/ws.wasm" ]; then
  echo "[compiler-gate] FAIL: workspace-precedence consumer did not compile (#751)" >&2
  cat "$xdir/ws.wasm.diag" >&2 2>/dev/null; exit 1
fi
ws_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$xdir/ws.wasm" 2>/dev/null | tail -1)"
if [ "$ws_out" != "43" ]; then
  echo "[compiler-gate] FAIL: workspace lib/ did not win over VIBE_LIB root (got '$ws_out', want 43) (#751)" >&2; exit 1
fi
# (4) freeze: VIBE_REQUIRE_PINS=1 demands a pin for any dev-mode lib lane
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(40) + 0 + 0 + 0 }\n' > "$xdir/frz.vibe"
if VIBE_REQUIRE_PINS=1 VIBE_LIB="$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/frz.vibe" "$xdir/frz.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/frz.wasm" ]; then
  echo "[compiler-gate] FAIL: pin-less lib resolution was allowed under VIBE_REQUIRE_PINS=1 (#751)" >&2; exit 1
fi
if ! grep -q "pin required" "$xdir/frz.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: freeze rejection lacks the expected diagnostic (#751)" >&2
  cat "$xdir/frz.wasm.diag" >&2 2>/dev/null; exit 1
fi
# (5) #758 review (P1): a resolved graph cached under one environment must
#     NOT replay under another — the SAME consumer content is compiled
#     across env changes (previously the persistent source/header caches
#     keyed on content only, so a pin-less graph warmed without freeze was
#     replayed under VIBE_REQUIRE_PINS=1, and a removed VIBE_LIB root kept
#     resolving).
rm -rf "lib/@gate751x"
printf 'import @gate751x/echo { echo_n }\nexport let _start: () -> Int = () -> { echo_n(38) }\n' > "$xdir/replay.vibe"
VIBE_LIB="$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/replay.vibe" "$xdir/replay1.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xdir/replay1.wasm" ]; then
  echo "[compiler-gate] FAIL: replay warm-up compile failed (#758)" >&2
  cat "$xdir/replay1.wasm.diag" >&2 2>/dev/null; exit 1
fi
if VIBE_LIB="$xroot/does-not-exist" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/replay.vibe" "$xdir/replay2.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/replay2.wasm" ]; then
  echo "[compiler-gate] FAIL: warm cache replayed a removed VIBE_LIB root (#758)" >&2; exit 1
fi
if VIBE_REQUIRE_PINS=1 VIBE_LIB="$xroot" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xdir/replay.vibe" "$xdir/replay3.wasm" _start >/dev/null 2>&1 \
  && [ -s "$xdir/replay3.wasm" ]; then
  echo "[compiler-gate] FAIL: warm cache bypassed VIBE_REQUIRE_PINS=1 (#758)" >&2; exit 1
fi
if ! grep -q "pin required" "$xdir/replay3.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: freeze-under-warm-cache rejection lacks the expected diagnostic (#758)" >&2
  cat "$xdir/replay3.wasm.diag" >&2 2>/dev/null; exit 1
fi
rm -rf "$xdir" "$xroot"
echo "[compiler-gate] VIBE_LIB external roots + freeze ok"

# 6j. distribution pipeline (#754, ADR-0065 Phase 4): publish (version
#     directive + semver gate) -> fetch cache (CAS keyed by package hash +
#     versions.tsv) -> materialize into $VIBE_HOME/lib (the default VIBE_LIB
#     root) -> name resolution -> build&run; then the pinned store lane
#     under freeze; then the two rejections that make version->hash an
#     immutable mapping (same-version republish; dishonest semver claim).
echo "[compiler-gate] 6j distribution pipeline: publish/cache/materialize (#754)"
jhome="$(mktemp -d)"
jsrc="$jhome/src/@gate754/mathx"
mkdir -p "$jsrc"
printf 'name = @gate754/mathx\nversion = 1.0.0\n\nfn quad(x: Int) -> Int\n' > "$jsrc/index.vpkg"
printf 'export fn quad(x: Int) -> Int { x * 4 }\n' > "$jsrc/impl.vibe"
jdir="_build/_gate_pkg754"
rm -rf "$jdir" ".vibe/store/@gate754"; mkdir -p "$jdir"
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub1.log" 2>&1; then
  echo "[compiler-gate] FAIL: publish of @gate754/mathx@1.0.0 failed (#754)" >&2
  cat "$jdir/pub1.log" >&2; exit 1
fi
if ! grep -q "@gate754/mathx@1.0.0" "$jhome/cache/versions.tsv" 2>/dev/null; then
  echo "[compiler-gate] FAIL: publish did not record the version mapping (#754)" >&2; exit 1
fi
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate754/mathx@1.0.0" > "$jdir/inst1.log" 2>&1; then
  echo "[compiler-gate] FAIL: install/materialize into VIBE_HOME/lib failed (#754)" >&2
  cat "$jdir/inst1.log" >&2; exit 1
fi
printf 'import @gate754/mathx { quad }\nexport let _start: () -> Int = () -> { quad(11) }\n' > "$jdir/use.vibe"
VIBE_HOME="$jhome" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$jdir/use.vibe" "$jdir/use.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$jdir/use.wasm" ]; then
  echo "[compiler-gate] FAIL: materialized package did not resolve via VIBE_HOME default root (#754)" >&2
  cat "$jdir/use.wasm.diag" >&2 2>/dev/null; exit 1
fi
juse_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$jdir/use.wasm" 2>/dev/null | tail -1)"
if [ "$juse_out" != "44" ]; then
  echo "[compiler-gate] FAIL: materialized package returned '$juse_out' (want 44) (#754)" >&2; exit 1
fi
# pinned store lane under freeze: install --store, consumer carries the pin
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate754/mathx@1.0.0" --store > "$jdir/inst2.log" 2>&1; then
  echo "[compiler-gate] FAIL: install --store failed (#754)" >&2
  cat "$jdir/inst2.log" >&2; exit 1
fi
jhash="$(awk -F'\t' '$1 == "@gate754/mathx@1.0.0" { print $2 }' "$jhome/cache/versions.tsv")"
printf 'require @gate754/mathx 1.0.0 = #%s\n\nimport @gate754/mathx { quad }\nexport let _start: () -> Int = () -> { quad(11) + 0 }\n' "$jhash" > "$jdir/pinned.vibe"
VIBE_REQUIRE_PINS=1 VIBE_HOME="$jhome" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$jdir/pinned.vibe" "$jdir/pinned.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$jdir/pinned.wasm" ]; then
  echo "[compiler-gate] FAIL: pinned store build under VIBE_REQUIRE_PINS=1 failed (#754)" >&2
  cat "$jdir/pinned.wasm.diag" >&2 2>/dev/null; exit 1
fi
# same-version republish with different content must be rejected
printf 'export fn quad(x: Int) -> Int { x * 5 }\n' > "$jsrc/impl.vibe"
if VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub2.log" 2>&1; then
  echo "[compiler-gate] FAIL: same-version republish was accepted (#754)" >&2; exit 1
fi
if ! grep -q "same-version republish rejected" "$jdir/pub2.log"; then
  echo "[compiler-gate] FAIL: republish rejection lacks the expected message (#754)" >&2
  cat "$jdir/pub2.log" >&2; exit 1
fi
# dishonest bump: surface grows but only the patch level is bumped
printf 'name = @gate754/mathx\nversion = 1.0.1\n\nfn quad(x: Int) -> Int\nfn oct(x: Int) -> Int\n' > "$jsrc/index.vpkg"
printf 'export fn quad(x: Int) -> Int { x * 4 }\nexport fn oct(x: Int) -> Int { x * 8 }\n' > "$jsrc/impl.vibe"
if VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub3.log" 2>&1; then
  echo "[compiler-gate] FAIL: dishonest patch bump was accepted by publish (#754)" >&2; exit 1
fi
# honest minor bump passes (versions come from the directives, no env)
printf 'name = @gate754/mathx\nversion = 1.1.0\n\nfn quad(x: Int) -> Int\nfn oct(x: Int) -> Int\n' > "$jsrc/index.vpkg"
if ! VIBE_HOME="$jhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$jsrc" > "$jdir/pub4.log" 2>&1; then
  echo "[compiler-gate] FAIL: honest minor bump was rejected by publish (#754)" >&2
  cat "$jdir/pub4.log" >&2; exit 1
fi
rm -rf ".vibe/store/@gate754" "$jdir" "$jhome"
echo "[compiler-gate] distribution pipeline ok"

# 6j2. `vibe pkg update` must recognise an installed copy whose versions.tsv
#      row is a historical SHA-1 identity (#2829). Default writes are b3, so
#      a string match against the recorded pin misses and used to treat the
#      install as untracked, then die looking for a SHA-1 CAS entry.
echo "[compiler-gate] 6j2 update matches an installed SHA-1 identity (#2829)"
uhome="$(mktemp -d)"
usrc="$uhome/src/@gate2829/upx"
mkdir -p "$usrc"
printf 'name = @gate2829/upx\nversion = 1.0.0\n\nfn twice(x: Int) -> Int\n' > "$usrc/index.vpkg"
printf 'export fn twice(x: Int) -> Int { x * 2 }\n' > "$usrc/impl.vibe"
udir="_build/_gate_pkg2829"
rm -rf "$udir"; mkdir -p "$udir"
if ! VIBE_HOME="$uhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$usrc" > "$udir/pub.log" 2>&1; then
  echo "[compiler-gate] FAIL: publish of @gate2829/upx@1.0.0 failed (#2829)" >&2
  cat "$udir/pub.log" >&2; exit 1
fi
if ! VIBE_HOME="$uhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate2829/upx@1.0.0" > "$udir/inst.log" 2>&1; then
  echo "[compiler-gate] FAIL: install of @gate2829/upx@1.0.0 failed (#2829)" >&2
  cat "$udir/inst.log" >&2; exit 1
fi
VIBE_HASH=1 VIBE_HASH_ALGO=sha1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$uhome/lib/@gate2829/upx/index.vpkg" "$udir/sha1.out" __no_entry__ >/dev/null 2>&1 || true
uhash_sha1="$(grep '^package ' "$udir/sha1.out" 2>/dev/null | cut -d' ' -f2)"
uhash_sha1="${uhash_sha1#\#}"
if ! printf '%s' "$uhash_sha1" | grep -qE '^pkg:sha1:[0-9a-f]{40}$'; then
  echo "[compiler-gate] FAIL: VIBE_HASH_ALGO=sha1 did not emit a SHA-1 identity for update (#2829)" >&2
  cat "$udir/sha1.out" >&2 2>/dev/null
  cat "$udir/sha1.out.diag" >&2 2>/dev/null
  exit 1
fi
awk -F'\t' -v n="@gate2829/upx@1.0.0" -v h="$uhash_sha1" 'BEGIN { OFS="\t" } $1 == n { $2 = h } { print }' \
  "$uhome/cache/versions.tsv" > "$uhome/cache/versions.tsv.new"
mv "$uhome/cache/versions.tsv.new" "$uhome/cache/versions.tsv"
rm -rf "$uhome/cache/pkg/b3"
if ! VIBE_HOME="$uhome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh update "@gate2829/upx" > "$udir/upd.log" 2>&1; then
  echo "[compiler-gate] FAIL: update of a SHA-1-recorded install failed (#2829)" >&2
  cat "$udir/upd.log" >&2; exit 1
fi
if ! grep -q "is up to date" "$udir/upd.log"; then
  echo "[compiler-gate] FAIL: update did not treat the SHA-1-recorded install as current (#2829)" >&2
  cat "$udir/upd.log" >&2; exit 1
fi
if grep -q "untracked" "$udir/upd.log"; then
  echo "[compiler-gate] FAIL: update treated a SHA-1-recorded install as untracked (#2829)" >&2
  cat "$udir/upd.log" >&2; exit 1
fi
rm -rf "$udir" "$uhome"
echo "[compiler-gate] update matches an installed SHA-1 identity ok"

# 6k. registry-less git resolution (#755 Phase 0): `vibe_pkg.sh add` fetches
#     a package from a git source (github: is sugar over the same path),
#     resolves the ref to a COMMIT (provenance), hashes the fetched sources
#     LOCALLY, and installs only when the hash agrees with the expected pin
#     (or records it trust-on-first-use). A hermetic file:// repo stands in
#     for GitHub; the tamper step re-serves the same version with different
#     content and must be rejected by the version->hash record.
echo "[compiler-gate] 6k registry-less git resolution (#755 Phase 0)"
khome="$(mktemp -d)"
krepo="$(mktemp -d)"
kdir="_build/_gate_pkg755"
rm -rf "$kdir"; mkdir -p "$kdir"
mkdir -p "$krepo/packages/@gate755/hex"
printf 'name = @gate755/hex\nversion = 1.0.0\n\nfn hex_n(x: Int) -> Int\n' > "$krepo/packages/@gate755/hex/index.vpkg"
printf 'export fn hex_n(x: Int) -> Int { x + 6 }\n' > "$krepo/packages/@gate755/hex/impl.vibe"
git -C "$krepo" init -q
git -C "$krepo" add -A
git -C "$krepo" -c user.email=gate@vibe -c user.name=gate commit -qm pkg
git -C "$krepo" branch -m main
kspec="git:file://$krepo@main#packages/@gate755/hex"
# (1) TOFU add: fetch, record, materialize into $VIBE_HOME/lib; consumer runs
if ! VIBE_HOME="$khome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" > "$kdir/add1.log" 2>&1; then
  echo "[compiler-gate] FAIL: git add (TOFU) failed (#755)" >&2
  cat "$kdir/add1.log" >&2; exit 1
fi
khash="$(awk -F'\t' '$1 == "@gate755/hex@1.0.0" { print $2 }' "$khome/cache/versions.tsv")"
if [ -z "$khash" ]; then
  echo "[compiler-gate] FAIL: git add did not record the version mapping (#755)" >&2; exit 1
fi
if ! printf '%s' "$khash" | grep -qE '^pkg:b3:[0-9a-f]{64}$'; then
  echo "[compiler-gate] FAIL: TOFU add did not record a BLAKE3 identity (#2829)" >&2
  echo "$khash" >&2; exit 1
fi
if ! grep -q "@gate755/hex@1.0.0" "$khome/cache/provenance.tsv" 2>/dev/null; then
  echo "[compiler-gate] FAIL: git add did not record provenance (#755)" >&2; exit 1
fi
printf 'import @gate755/hex { hex_n }\nexport let _start: () -> Int = () -> { hex_n(36) }\n' > "$kdir/use.vibe"
VIBE_HOME="$khome" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$kdir/use.vibe" "$kdir/use.wasm" _start >/dev/null 2>&1 || true
kuse_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$kdir/use.wasm" 2>/dev/null | tail -1)"
if [ "$kuse_out" != "42" ]; then
  echo "[compiler-gate] FAIL: git-added package returned '$kuse_out' (want 42) (#755)" >&2; exit 1
fi
# (2) wrong expected pin rejects BEFORE any side effect (fresh home)
khome2="$(mktemp -d)"
if VIBE_HOME="$khome2" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" "#pkg:sha1:0000000000000000000000000000000000000000" > "$kdir/add2.log" 2>&1; then
  echo "[compiler-gate] FAIL: wrong expected pin was accepted (#755)" >&2; exit 1
fi
if ! grep -q "hash mismatch" "$kdir/add2.log" || [ -f "$khome2/cache/versions.tsv" ]; then
  echo "[compiler-gate] FAIL: pin rejection is wrong or left side effects (#755)" >&2
  cat "$kdir/add2.log" >&2; exit 1
fi
# (2b) a correct SHA-1 expected pin still verifies under SHA-1 of the same
#      payload, records pkg:sha1:, and lands in cache/pkg/sha1/. fetch-pins
#      can restore it from the recorded source when that CAS entry is absent.
mkdir -p "$kdir/sha1src"
cp -R "$khome/lib/@gate755/hex/." "$kdir/sha1src/"
VIBE_HASH=1 VIBE_HASH_ALGO=sha1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$kdir/sha1src/index.vpkg" "$kdir/sha1.out" __no_entry__ >/dev/null 2>&1 || true
khash_sha1="$(grep '^package ' "$kdir/sha1.out" 2>/dev/null | cut -d' ' -f2)"
khash_sha1="${khash_sha1#\#}"
if ! printf '%s' "$khash_sha1" | grep -qE '^pkg:sha1:[0-9a-f]{40}$'; then
  echo "[compiler-gate] FAIL: VIBE_HASH_ALGO=sha1 did not emit a SHA-1 identity (#2829)" >&2
  cat "$kdir/sha1.out" >&2 2>/dev/null
  cat "$kdir/sha1.out.diag" >&2 2>/dev/null
  exit 1
fi
khome_sha1="$(mktemp -d)"
if ! VIBE_HOME="$khome_sha1" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" "#$khash_sha1" > "$kdir/add_sha1.log" 2>&1; then
  echo "[compiler-gate] FAIL: correct SHA-1 expected pin was rejected (#2829)" >&2
  cat "$kdir/add_sha1.log" >&2; exit 1
fi
if ! awk -F'\t' '$1 == "@gate755/hex@1.0.0"' "$khome_sha1/cache/versions.tsv" | grep -qE 'pkg:sha1:[0-9a-f]{40}'; then
  echo "[compiler-gate] FAIL: SHA-1 pin was not recorded under its algorithm (#2829)" >&2
  cat "$khome_sha1/cache/versions.tsv" >&2; exit 1
fi
khex_sha1="${khash_sha1#pkg:sha1:}"
if [ ! -f "$khome_sha1/cache/pkg/sha1/$khex_sha1/index.vpkg" ]; then
  echo "[compiler-gate] FAIL: SHA-1 pin did not land in cache/pkg/sha1/ (#2829)" >&2
  exit 1
fi
printf 'name = @local/app\nversion = 0.1.0\nrequire @gate755/hex 1.0.0 = #%s from %s\n\ngenerated_hash =\n' "$khash_sha1" "$kspec" > "$kdir/app_sha1.vpkg"
rm -rf "$khome_sha1/cache/pkg" "$khome_sha1/lib/@gate755"
if ! VIBE_HOME="$khome_sha1" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh fetch-pins "$kdir/app_sha1.vpkg" > "$kdir/fetch_sha1.log" 2>&1; then
  echo "[compiler-gate] FAIL: fetch-pins could not restore a SHA-1 pin from source (#2829)" >&2
  cat "$kdir/fetch_sha1.log" >&2; exit 1
fi
if [ ! -f "$khome_sha1/lib/@gate755/hex/index.vpkg" ]; then
  echo "[compiler-gate] FAIL: fetch-pins did not materialize the SHA-1 pin (#2829)" >&2
  cat "$kdir/fetch_sha1.log" >&2; exit 1
fi
rm -rf "$khome_sha1"
# (3) correct expected pin verifies a fresh fetch
if ! VIBE_HOME="$khome2" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" "#$khash" > "$kdir/add3.log" 2>&1; then
  echo "[compiler-gate] FAIL: correct expected pin was rejected (#755)" >&2
  cat "$kdir/add3.log" >&2; exit 1
fi
# (4) upstream tampers: same version, different content -> rejected by the
#     local version->hash record
printf 'export fn hex_n(x: Int) -> Int { x + 7 }\n' > "$krepo/packages/@gate755/hex/impl.vibe"
git -C "$krepo" add -A
git -C "$krepo" -c user.email=gate@vibe -c user.name=gate commit -qm tamper
if VIBE_HOME="$khome" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh add "$kspec" > "$kdir/add4.log" 2>&1; then
  echo "[compiler-gate] FAIL: tampered same-version fetch was accepted (#755)" >&2; exit 1
fi
if ! grep -q "version->hash is immutable" "$kdir/add4.log"; then
  echo "[compiler-gate] FAIL: tamper rejection lacks the expected message (#755)" >&2
  cat "$kdir/add4.log" >&2; exit 1
fi
rm -rf "$kdir" "$khome" "$khome2" "$krepo"
echo "[compiler-gate] registry-less git resolution ok"

# 6l. registry transparency log + yank (#805, ADR-0065 Phase 5 minimal
#     slice): publish appends an ordinal record to $VIBE_HOME/log/records.tsv
#     and maintains a Merkle head; install verifies (a) the served head
#     commits to the served records (tamper check), (b) prefix consistency
#     against the last head this client saw (the log may only ever extend),
#     and (c) an inclusion proof for the claimed name@version -> hash record
#     against the head root. yank is an append-only marking that install
#     refuses without --allow-yanked while versions.tsv (the immutable
#     version->hash mapping) stays untouched. The log dir is static files:
#     VIBE_REGISTRY_LOG_DIR points a client at a served copy.
echo "[compiler-gate] 6l registry transparency log + yank (#805)"
lhome805="$(mktemp -d)"
lsrc805="$lhome805/src/@gate805/logx"
mkdir -p "$lsrc805"
printf 'name = @gate805/logx\nversion = 1.0.0\n\nfn triple(x: Int) -> Int\n' > "$lsrc805/index.vpkg"
printf 'export fn triple(x: Int) -> Int { x * 3 }\n' > "$lsrc805/impl.vibe"
ldir805="_build/_gate_pkg805"
rm -rf "$ldir805"; mkdir -p "$ldir805"
# (1) publish appends a publish record and writes a merkle head
if ! VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$lsrc805" > "$ldir805/pub1.log" 2>&1; then
  echo "[compiler-gate] FAIL: publish of @gate805/logx@1.0.0 failed (#805)" >&2
  cat "$ldir805/pub1.log" >&2; exit 1
fi
if ! awk -F'\t' '$1 == "0" && $2 == "publish" && $3 == "@gate805/logx@1.0.0"' "$lhome805/log/records.tsv" 2>/dev/null | grep -q .; then
  echo "[compiler-gate] FAIL: publish did not append a transparency-log record (#805)" >&2
  cat "$lhome805/log/records.tsv" >&2 2>/dev/null; exit 1
fi
if [ ! -s "$lhome805/log/head" ]; then
  echo "[compiler-gate] FAIL: publish did not write a merkle head (#805)" >&2; exit 1
fi
cp "$lhome805/log/records.tsv" "$ldir805/log1.records"
cp "$lhome805/log/head" "$ldir805/log1.head"
# (2) a second publish extends the log; install verifies an inclusion proof
printf 'name = @gate805/logx\nversion = 1.1.0\n\nfn triple(x: Int) -> Int\nfn nona(x: Int) -> Int\n' > "$lsrc805/index.vpkg"
printf 'export fn triple(x: Int) -> Int { x * 3 }\nexport fn nona(x: Int) -> Int { x * 9 }\n' > "$lsrc805/impl.vibe"
if ! VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$lsrc805" > "$ldir805/pub2.log" 2>&1; then
  echo "[compiler-gate] FAIL: publish of @gate805/logx@1.1.0 failed (#805)" >&2
  cat "$ldir805/pub2.log" >&2; exit 1
fi
if [ "$(wc -l < "$lhome805/log/records.tsv" | tr -d '[:space:]')" != "2" ]; then
  echo "[compiler-gate] FAIL: second publish did not extend the log to 2 records (#805)" >&2
  cat "$lhome805/log/records.tsv" >&2; exit 1
fi
if ! VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate805/logx@1.0.0" > "$ldir805/inst1.log" 2>&1; then
  echo "[compiler-gate] FAIL: install of a logged version failed (#805)" >&2
  cat "$ldir805/inst1.log" >&2; exit 1
fi
if ! grep -q "inclusion verified for @gate805/logx@1.0.0" "$ldir805/inst1.log"; then
  echo "[compiler-gate] FAIL: install did not verify the log inclusion proof (#805)" >&2
  cat "$ldir805/inst1.log" >&2; exit 1
fi
cp "$lhome805/log/records.tsv" "$ldir805/log2.records"
cp "$lhome805/log/head" "$ldir805/log2.head"
# (3) same-version republish with different content is still rejected — and
#     the rejected publish must NOT grow the log
printf 'export fn triple(x: Int) -> Int { x * 3 + 1 }\nexport fn nona(x: Int) -> Int { x * 9 }\n' > "$lsrc805/impl.vibe"
if VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh publish "$lsrc805" > "$ldir805/pub3.log" 2>&1; then
  echo "[compiler-gate] FAIL: same-version republish was accepted (#805)" >&2; exit 1
fi
if ! grep -q "same-version republish rejected" "$ldir805/pub3.log"; then
  echo "[compiler-gate] FAIL: republish rejection lacks the expected message (#805)" >&2
  cat "$ldir805/pub3.log" >&2; exit 1
fi
if [ "$(wc -l < "$lhome805/log/records.tsv" | tr -d '[:space:]')" != "2" ]; then
  echo "[compiler-gate] FAIL: a rejected republish grew the transparency log (#805)" >&2; exit 1
fi
# (4) a tampered log head is detected before anything installs
sed 's/\t/\tf00dfeed/' "$ldir805/log2.head" > "$lhome805/log/head"
if VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate805/logx@1.1.0" > "$ldir805/inst2.log" 2>&1; then
  echo "[compiler-gate] FAIL: install accepted a tampered log head (#805)" >&2; exit 1
fi
if ! grep -q "tampered log head" "$ldir805/inst2.log"; then
  echo "[compiler-gate] FAIL: tampered-head rejection lacks the expected message (#805)" >&2
  cat "$ldir805/inst2.log" >&2; exit 1
fi
cp "$ldir805/log2.head" "$lhome805/log/head"
# (5) append-only consistency: rolling the log back to its (self-consistent)
#     1-record state must be refused by a client that already saw 2 records
cp "$ldir805/log1.records" "$lhome805/log/records.tsv"
cp "$ldir805/log1.head" "$lhome805/log/head"
if VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate805/logx@1.0.0" > "$ldir805/inst3.log" 2>&1; then
  echo "[compiler-gate] FAIL: install accepted a truncated (rolled-back) log (#805)" >&2; exit 1
fi
if ! grep -q "log consistency violation" "$ldir805/inst3.log"; then
  echo "[compiler-gate] FAIL: truncation rejection lacks the expected message (#805)" >&2
  cat "$ldir805/inst3.log" >&2; exit 1
fi
cp "$ldir805/log2.records" "$lhome805/log/records.tsv"
cp "$ldir805/log2.head" "$lhome805/log/head"
# (6) yank: an append-only marking; install refuses it without --allow-yanked;
#     the version->hash mapping stays immutable
if ! VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh yank "@gate805/logx@1.1.0" > "$ldir805/yank.log" 2>&1; then
  echo "[compiler-gate] FAIL: yank failed (#805)" >&2
  cat "$ldir805/yank.log" >&2; exit 1
fi
if [ "$(wc -l < "$lhome805/log/records.tsv" | tr -d '[:space:]')" != "3" ]; then
  echo "[compiler-gate] FAIL: yank did not append a log record (#805)" >&2; exit 1
fi
if VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate805/logx@1.1.0" > "$ldir805/inst4.log" 2>&1; then
  echo "[compiler-gate] FAIL: install accepted a yanked version without --allow-yanked (#805)" >&2; exit 1
fi
if ! grep -q "yanked in the registry log" "$ldir805/inst4.log"; then
  echo "[compiler-gate] FAIL: yank rejection lacks the expected message (#805)" >&2
  cat "$ldir805/inst4.log" >&2; exit 1
fi
if ! VIBE_HOME="$lhome805" VIBE_PKG_CLI_WASM="$stage2_wasm" bash scripts/vibe_pkg.sh install "@gate805/logx@1.1.0" --allow-yanked > "$ldir805/inst5.log" 2>&1; then
  echo "[compiler-gate] FAIL: --allow-yanked did not override the yank refusal (#805)" >&2
  cat "$ldir805/inst5.log" >&2; exit 1
fi
if ! awk -F'\t' '$1 == "@gate805/logx@1.1.0"' "$lhome805/cache/versions.tsv" | grep -qE "pkg:b3:[0-9a-f]{64}"; then
  echo "[compiler-gate] FAIL: yank disturbed the immutable version->hash mapping (#805 / #2829)" >&2; exit 1
fi
# (7) the log dir is a servable static artifact: a copied dir passed via
#     VIBE_REGISTRY_LOG_DIR verifies the same way
rm -rf "$ldir805/served"
cp -R "$lhome805/log" "$ldir805/served"
if ! VIBE_HOME="$lhome805" VIBE_REGISTRY_LOG_DIR="$ldir805/served" VIBE_PKG_CLI_WASM="$stage2_wasm" \
  bash scripts/vibe_pkg.sh install "@gate805/logx@1.0.0" > "$ldir805/inst6.log" 2>&1; then
  echo "[compiler-gate] FAIL: install against a served log copy failed (#805)" >&2
  cat "$ldir805/inst6.log" >&2; exit 1
fi
if ! grep -q "inclusion verified for @gate805/logx@1.0.0" "$ldir805/inst6.log"; then
  echo "[compiler-gate] FAIL: served-copy install did not verify inclusion (#805)" >&2
  cat "$ldir805/inst6.log" >&2; exit 1
fi
rm -rf "$ldir805" "$lhome805"
echo "[compiler-gate] registry transparency log + yank ok"

# 6d. where-contract + publish-gate regression (#731 / #732): a violated
#     requires clause traps at runtime; the publish semver gate accepts an
#     honest bump and rejects a dishonest one.
echo "[compiler-gate] 6d where-contract + publish gate regression (#731/#732)"
edir="_build/_gate_ef"
rm -rf "$edir"; mkdir -p "$edir"
# (a) satisfied contract: requires + ensures hold, the call returns 42.
printf 'fn checked_add(x: Int, y: Int) -> Int where { requires: x >= 0, requires: y >= 0, ensures: result >= x } { x + y }\nexport let _start: () -> Int = () -> { checked_add(40, 2) }\n' > "$edir/ok.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/ok.vibe" "$edir/ok.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$edir/ok.wasm" ]; then
  echo "[compiler-gate] FAIL: satisfied where-contract program did not compile (#731)" >&2
  cat "$edir/ok.wasm.diag" >&2 2>/dev/null; exit 1
fi
ok_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/ok.wasm" 2>/dev/null | tail -1)"
if [ "$ok_out" != "42" ]; then
  echo "[compiler-gate] FAIL: satisfied where-contract returned '$ok_out' (want 42) (#731)" >&2; exit 1
fi
# (b) violated requires: entry assert traps.
printf 'fn half_pos(x: Int) -> Int where { requires: x > 0 } { x / 2 }\nexport let _start: () -> Int = () -> { half_pos(0 - 4) }\n' > "$edir/viol.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/viol.vibe" "$edir/viol.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$edir/viol.wasm" ]; then
  echo "[compiler-gate] FAIL: where-contract program did not compile (#731)" >&2
  cat "$edir/viol.wasm.diag" >&2 2>/dev/null; exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/viol.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: violated requires clause did not trap (#731)" >&2; exit 1
fi
# (c) violated ensures: exit assert (over the `result` binding) traps.
printf 'fn bad_dec(x: Int) -> Int where { ensures: result > x } { x - 1 }\nexport let _start: () -> Int = () -> { bad_dec(7) }\n' > "$edir/viol_ens.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/viol_ens.vibe" "$edir/viol_ens.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$edir/viol_ens.wasm" ]; then
  echo "[compiler-gate] FAIL: ensures-contract program did not compile (#731)" >&2
  cat "$edir/viol_ens.wasm.diag" >&2 2>/dev/null; exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$edir/viol_ens.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: violated ensures clause did not trap (#731)" >&2; exit 1
fi
printf 'fn a(x: Int) -> Int\n' > "$edir/prev.vibei"
printf 'fn a(x: Int) -> Int\nfn b(x: Int) -> Int\n' > "$edir/next.vibei"
VIBE_PUBLISH_CHECK=1 VIBE_PUBLISH_PREV="$edir/prev.vibei" VIBE_PUBLISH_PREV_VERSION=1.0.0 VIBE_PUBLISH_VERSION=1.1.0 \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/next.vibei" "$edir/pub.out" __no_entry__ >/dev/null 2>&1 || true
if ! grep -q "^ok" "$edir/pub.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: honest minor bump was rejected (#732)" >&2
  cat "$edir/pub.out.diag" >&2 2>/dev/null; exit 1
fi
VIBE_PUBLISH_CHECK=1 VIBE_PUBLISH_PREV="$edir/prev.vibei" VIBE_PUBLISH_PREV_VERSION=1.0.0 VIBE_PUBLISH_VERSION=1.0.1 \
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$edir/next.vibei" "$edir/pub2.out" __no_entry__ >/dev/null 2>&1 || true
if ! grep -q "requires minor" "$edir/pub2.out.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: dishonest patch claim was not rejected (#732)" >&2
  cat "$edir/pub2.out" "$edir/pub2.out.diag" >&2 2>/dev/null; exit 1
fi
rm -rf "$edir"
echo "[compiler-gate] where-contract + publish gate regression ok"

# (6e retired by #741: the vendored lib/@vibe/compiler/cache/sha1.vibe twin was
# deleted — the compiler consumes lib/@vibe/core through the contract import,
# so there is nothing left to drift-check.)

# 6f. @vibe/core store-install E2E: install the REAL in-repo package into
#     .vibe/store via scripts/vibe_core_install.sh, then compile AND RUN a
#     require-pinned consumer against it. The pin is taken from the install
#     output, so core source changes never stale this step. Complements 6c
#     (synthetic packages) with the shipped package: 82-decl contract,
#     bodyless `type` re-exports, multi-impl any-match conformance.
echo "[compiler-gate] 6f @vibe/core store-install E2E"
cdir6f="_build/_gate_core_store"
rm -rf "$cdir6f" ".vibe/store/@vibe/core"; mkdir -p "$cdir6f"
if ! VIBE_CORE_CLI_WASM="$stage2_wasm" bash scripts/vibe_core_install.sh > "$cdir6f/install.out" 2>&1; then
  echo "[compiler-gate] FAIL: vibe_core_install.sh failed" >&2
  cat "$cdir6f/install.out" >&2; exit 1
fi
core_pin="$(grep '^package ' "$cdir6f/install.out" | cut -d' ' -f2)"
if [ -z "$core_pin" ]; then
  echo "[compiler-gate] FAIL: install printed no package pin" >&2
  cat "$cdir6f/install.out" >&2; exit 1
fi
cat > "$cdir6f/consumer.vibe" <<EOF
require @vibe/core 0.2.0 = $core_pin

import @vibe/core {
  sha1, encode_uleb128, read_uleb128, enum List, from_array, contains
}
export let _start: () -> Int = () -> {
  assert(sha1("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
  let buf = encode_uleb128(624485)
  let (v, _) = read_uleb128(buf, 0)
  assert(eq(v, 624485))
  assert(eq(List::sum(List::of3(1, 2, 3)), 6))
  let s = from_array(["a", "b"])
  assert(contains(s, "a"))
  assert(not(contains(s, "z")))
  0
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir6f/consumer.vibe" "$cdir6f/consumer.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$cdir6f/consumer.wasm" ]; then
  echo "[compiler-gate] FAIL: pinned @vibe/core consumer did not compile" >&2
  cat "$cdir6f/consumer.wasm.diag" >&2 2>/dev/null; exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$cdir6f/consumer.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: @vibe/core consumer trapped at runtime" >&2; exit 1
fi
rm -rf "$cdir6f" ".vibe/store/@vibe/core"
echo "[compiler-gate] @vibe/core store-install E2E ok"

# 7. literal sub-pattern regression (#603): a literal (PInt/PString) argument of a
#    constructor pattern must be tested, not just the tag — `I("x")` must not
#    match `I("y")`, `I(1)` must not match `I(2)`. Guards the match-codegen fix.
echo "[compiler-gate] 7/7 literal sub-pattern regression"
pdir="_build/_gate_litpat"
rm -rf "$pdir"; mkdir -p "$pdir"
cat > "$pdir/litpat.vibe" <<'EOF'
enum E { I(Int); S(String); N }
let classify: (E) -> Int = (e) -> {
  match e {
    I(7) => 10,
    I(_) => 11,
    S("perform") => 20,
    S(_) => 21,
    N => 30
  }
}
export let _start: () -> Int = () -> {
  classify(I(5)) + classify(S("foo")) + classify(I(7)) + classify(S("perform"))
}
EOF
# Expected: 11 + 21 + 10 + 20 = 62
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pdir/litpat.vibe" "$pdir/litpat.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pdir/litpat.wasm" ]; then
  echo "[compiler-gate] FAIL: literal sub-pattern program did not compile" >&2; exit 1
fi
litpat_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$pdir/litpat.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$litpat_out" != "62" ]; then
  echo "[compiler-gate] FAIL: literal sub-pattern mismatch (got '$litpat_out', want 62 -> #603 regressed)" >&2
  exit 1
fi
rm -rf "$pdir"
echo "[compiler-gate] literal sub-pattern regression ok"

# 8. labeled-param round-trip regression (#604/#606): normalizing a function
#    with labeled (`x~`) / optional (`x?`) parameters must preserve the parameter
#    names. `parse_one_param` builds the names with string interpolation
#    (`"\{name}~"`); before the #606 `__to_string` root fix this leaked a heap
#    pointer (`(1285664100319233~)`), and the #604 mitigation routed around it
#    with `String::concat`. With the root fix the interpolation form is correct,
#    so this guards the root fix directly. The result must still compile + run.
echo "[compiler-gate] 8/8 labeled-param round-trip regression"
ldir="_build/_gate_labeled"
rm -rf "$ldir"; mkdir -p "$ldir"
printf 'let sum: (x~: Int, y~: Int) -> Int = (x~, y~) -> { x + y }\nexport let run: () -> Int = () -> { sum(x=1, y=2) }\nexport { run }\n' > "$ldir/in.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/in.vibe" "$ldir/out.vibe" >/dev/null 2>&1 || true
if [ ! -s "$ldir/out.vibe" ]; then
  echo "[compiler-gate] FAIL: labeled-param normalize produced no output" >&2; exit 1
fi
# Param names must survive verbatim; a digit before `~` means the gensym bug is back.
if ! grep -q "(x~, y~)" "$ldir/out.vibe" || grep -Eq "[0-9]+~" "$ldir/out.vibe"; then
  echo "[compiler-gate] FAIL: labeled param names mangled (#604 regressed)" >&2
  cat "$ldir/out.vibe" >&2; exit 1
fi
# The normalized output must still compile + run.
cp "$ldir/out.vibe" "$ldir/compile.vibe"
printf '\nexport let _start: () -> Int = () -> { run() }\n' >> "$ldir/compile.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ldir/compile.vibe" "$ldir/out.wasm" _start >/dev/null 2>&1
labeled_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$ldir/out.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$labeled_out" != "3" ]; then
  echo "[compiler-gate] FAIL: normalized labeled-param output did not compile/run to 3 (got '$labeled_out')" >&2
  cat "$ldir/compile.vibe" >&2; exit 1
fi
rm -rf "$ldir"
echo "[compiler-gate] labeled-param round-trip regression ok"

# 9. constant-folding regression (#594): `vibe normalize` folds `+ - *` over int
#    literals. The folded value must replace the expression and the result must
#    compile + run unchanged.
echo "[compiler-gate] 9/9 constant-folding regression"
fdir="_build/_gate_fold"
rm -rf "$fdir"; mkdir -p "$fdir"
printf 'let x = 40 + 2 * 10\nexport let run: () -> Int = () -> { x }\nexport { run }\n' > "$fdir/in.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fdir/in.vibe" "$fdir/out.vibe" >/dev/null 2>&1
# 40 + 2*10 = 60; the arithmetic must be gone and `60` present.
if ! grep -q "let x: Int = 60" "$fdir/out.vibe" || grep -q "40 + 2" "$fdir/out.vibe"; then
  echo "[compiler-gate] FAIL: constant folding incorrect" >&2
  cat "$fdir/out.vibe" >&2; exit 1
fi
cp "$fdir/out.vibe" "$fdir/compile.vibe"
printf '\nexport let _start: () -> Int = () -> { run() }\n' >> "$fdir/compile.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fdir/compile.vibe" "$fdir/out.wasm" _start >/dev/null 2>&1
fold_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$fdir/out.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$fold_out" != "60" ]; then
  echo "[compiler-gate] FAIL: folded program did not run to 60 (got '$fold_out')" >&2; exit 1
fi
rm -rf "$fdir"
echo "[compiler-gate] constant-folding regression ok"

# 10. nested constructor sub-pattern regression (#608): a constructor pattern
#     whose argument is itself a constructor (`SL(_, None, _)` vs
#     `SL(_, Some(x), _)`) must (a) discriminate on the nested tag — arms sharing
#     the outer tag must route distinctly — and (b) bind the nested fields, so
#     using `x` in the arm body compiles instead of trapping codegen. Adjacent to
#     #603 (literal sub-patterns); both live in the single-condition PCtor path.
echo "[compiler-gate] 10/10 nested ctor sub-pattern regression"
ndir="_build/_gate_nestedctor"
rm -rf "$ndir"; mkdir -p "$ndir"
cat > "$ndir/nested.vibe" <<'EOF'
enum Stmt { SL(Int, Option[Int], Int) }
let classify: (Stmt) -> Int = (stmt) -> {
  match stmt {
    SL(a, None, c) => a + c,
    SL(a, Some(x), c) => a + x + c,
    _ => 0
  }
}
export let _start: () -> Int = () -> {
  classify(SL(4, None, 6)) + classify(SL(4, Some(7), 6))
}
EOF
# Expected: (4+6) + (4+7+6) = 10 + 17 = 27.
# The bound `x` in Some(x) must compile (no trap), and Some must not route to None.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$ndir/nested.vibe" "$ndir/nested.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$ndir/nested.wasm" ]; then
  echo "[compiler-gate] FAIL: nested ctor sub-pattern program did not compile (#608 regressed: codegen trap)" >&2; exit 1
fi
nested_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$ndir/nested.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$nested_out" != "27" ]; then
  echo "[compiler-gate] FAIL: nested ctor sub-pattern mismatch (got '$nested_out', want 27 -> #608 regressed)" >&2
  exit 1
fi
rm -rf "$ndir"
echo "[compiler-gate] nested ctor sub-pattern regression ok"

# 11. forward-reference regression (#602): a top-level `let` may reference another
#     top-level `let` defined later in the same file. The checker now hoists
#     top-level binding signatures, so this compiles instead of aborting with an
#     opaque trap. A genuinely-undefined name must still error (no over-permit).
echo "[compiler-gate] 11/11 forward-reference regression"
wdir="_build/_gate_fwdref"
rm -rf "$wdir"; mkdir -p "$wdir"
cat > "$wdir/fwd.vibe" <<'EOF'
let early: () -> Int = () -> { late() }
let late: () -> Int = () -> { 41 }
export let _start: () -> Int = () -> { early() + 1 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$wdir/fwd.vibe" "$wdir/fwd.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$wdir/fwd.wasm" ]; then
  echo "[compiler-gate] FAIL: forward-reference program did not compile (#602 regressed: checker trap)" >&2; exit 1
fi
fwd_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$wdir/fwd.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$fwd_out" != "42" ]; then
  echo "[compiler-gate] FAIL: forward-reference mismatch (got '$fwd_out', want 42 -> #602 regressed)" >&2
  exit 1
fi
# Guard: a genuinely-undefined name must still be rejected (hoist only adds names
# that are actually defined later).
printf 'export let _start: () -> Int = () -> { genuinely_undefined_name() }\n' > "$wdir/undef.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$wdir/undef.vibe" "$wdir/undef.wasm" _start >/dev/null 2>&1 || true
if [ -s "$wdir/undef.wasm" ]; then
  echo "[compiler-gate] FAIL: undefined name compiled (#602 hoist over-permitted)" >&2; exit 1
fi
rm -rf "$wdir"
echo "[compiler-gate] forward-reference regression ok"

# 12. string-interpolation conversion regression (#606): `"\{e}"` lowers to
#     `__to_string(e)`, which was an `identity` stub (so interpolating an int
#     yielded garbage) reachable only via a dead inline path. The root fix makes
#     `__to_string` always use the real conversion (int -> decimal, string ->
#     passthrough with an in-bounds pointer check). Assert an int interpolates to
#     its digits and a string interpolates verbatim.
echo "[compiler-gate] 12/12 string-interpolation conversion regression"
idir="_build/_gate_interp"
rm -rf "$idir"; mkdir -p "$idir"
cat > "$idir/interp.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let n = 42
  let s = "v\{n}"
  let name = "ab"
  let t = "\{name}!"
  // s = "v42" (length 3, s[1]='4'=52), t = "ab!" (length 3, t[0]='a'=97).
  String::length(s) * 1000 + String::char_code_at(s, 1) * 100 + String::length(t) * 10 + (String::char_code_at(t, 0) - 97)
}
EOF
# 3*1000 + 52*100 + 3*10 + 0 = 3000 + 5200 + 30 = 8230
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$idir/interp.vibe" "$idir/interp.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$idir/interp.wasm" ]; then
  echo "[compiler-gate] FAIL: interpolation program did not compile" >&2; exit 1
fi
interp_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$idir/interp.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$interp_out" != "8230" ]; then
  echo "[compiler-gate] FAIL: interpolation mismatch (got '$interp_out', want 8230 -> #606 regressed)" >&2
  exit 1
fi
rm -rf "$idir"
echo "[compiler-gate] string-interpolation conversion regression ok"

# 13. coverage instrumentation regression (#cov): VIBE_COVERAGE=1 must produce an
#     instrumented build whose vibe_cov / vibe_cov_branch sections the runner can
#     read. A test that exercises only the then-branch of an `if` must report
#     both functions hit and exactly one of the two branches taken — the signal
#     that powers `vibe test --coverage`.
echo "[compiler-gate] 13/13 coverage instrumentation regression"
cdir="_build/_gate_cov"
rm -rf "$cdir"; mkdir -p "$cdir"
cat > "$cdir/cov_test.vibe" <<'EOF'
let pick: (Int) -> Int = (n) -> {
  if n > 0 {
    1
  } else {
    2
  }
}
test "pos" {
  assert(pick(5) == 1)
}
EOF
VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$cdir/cov_test.vibe" "$cdir/cov_test.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$cdir/cov_test.wasm" ]; then
  echo "[compiler-gate] FAIL: coverage build produced no wasm (#cov regressed)" >&2; exit 1
fi
VIBE_COV_OUT="$cdir/cov.json" VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$cdir/cov_test.wasm" >/dev/null 2>&1 || true
if [ ! -s "$cdir/cov.json" ]; then
  echo "[compiler-gate] FAIL: no coverage report produced (vibe_cov section missing?)" >&2; exit 1
fi
cov_check="$(python3 - "$cdir/cov.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
b = r.get("branch") or {}
# pick + __test_pos both run -> all functions hit; only the then-branch of `if`
# is taken -> 1 of 2 branches. `pick` must appear hit and with a branch gap.
ok = (r.get("hit") == r.get("total") and r.get("total", 0) >= 2
      and b.get("total") == 2 and b.get("hit") == 1
      and "pick" in r.get("hit_fns", []))
print("ok" if ok else f"bad fn={r.get('hit')}/{r.get('total')} br={b.get('hit')}/{b.get('total')}")
PY
)"
if [ "$cov_check" != "ok" ]; then
  echo "[compiler-gate] FAIL: coverage report wrong ($cov_check -> #cov regressed)" >&2; exit 1
fi
rm -rf "$cdir"
echo "[compiler-gate] coverage instrumentation regression ok"

# 13b. #2469: an INSTRUMENTED build must lower a render the way the production
#      build does. The coverage entry parsed with plain `lex`/`parse_program`,
#      which leaves every node at offset -1, so the checker's offset-keyed
#      typed-lowering tables came out empty BY CONSTRUCTION and only the
#      syntactic classifiers answered.
#
#      NO `VIBE_FS_COMPILE=1` here, and that is the whole reason this step can
#      fail: the entries #2469 fixes are the DIRECT-SOURCE ones
#      (`compile_source_wasi_only_coverage_impl` /
#      `_rc_shadow_impl`, reached from cli_adapter's non-FS_COMPILE branch).
#      With FS_COMPILE set, the compile takes the module lane instead and this
#      probe answers 4116 on a compiler that has none of the fix -- measured
#      against origin/main, which is how the first cut of this step passed
#      while proving nothing.
#
#      The program below is the #2462 shape --
#      a lambda bound by a `let` INSIDE a function body, which
#      `collect_fn_returns` (a STATEMENT walk) cannot see -- so nothing
#      syntactic classifies it and the table is the whole mechanism.
#
#      Encoded as an Int rather than compared as text so the failure names the
#      wrong value: "true" -> 4*1000 + 't'(116) = 4116, "1" -> 1*1000 +
#      '1'(49) = 1049. Red-tested by reverting the entry to the unlocated
#      parse: 1049.
echo "[compiler-gate] 13b/13 instrumented build typed-lowering tables (#2469)"
tldir="_build/_gate_typed_instrumented"
rm -rf "$tldir"; mkdir -p "$tldir"
cat > "$tldir/bool_render.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let l = () -> Bool { 1 < 2 }
  let s = __to_string(l())
  String::length(s) * 1000 + String::char_code_at(s, 0)
}
EOF
VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tldir/bool_render.vibe" "$tldir/cov.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$tldir/cov.wasm" ]; then
  echo "[compiler-gate] FAIL: coverage build of the #2469 probe produced no wasm" >&2
  cat "$tldir/cov.wasm.diag" >&2 2>/dev/null || true
  exit 1
fi
tl_cov_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$tldir/cov.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$tl_cov_out" != "4116" ]; then
  echo "[compiler-gate] FAIL: VIBE_COVERAGE=1 rendered a Bool as '$tl_cov_out' (want 4116 = \"true\"; 1049 = \"1\" means the coverage entry is back on the unlocated parse and its typed-lowering tables are empty -- #2469)" >&2
  exit 1
fi
# The control: the SAME program through the ordinary entry. Both must agree --
# that agreement, not the constant, is what #2469 is about.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$tldir/bool_render.vibe" "$tldir/plain.wasm" _start >/dev/null 2>&1 || true
tl_plain_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$tldir/plain.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$tl_plain_out" != "$tl_cov_out" ]; then
  echo "[compiler-gate] FAIL: the coverage build ($tl_cov_out) and the ordinary build ($tl_plain_out) rendered the same Bool differently (#2469)" >&2
  exit 1
fi
rm -rf "$tldir"
echo "[compiler-gate] instrumented build typed-lowering tables ok (#2469)"

# 14. method-bearing-trait dictionary passing regression (#641 PR-3): a
#     `[T: Trait]` generic calling `T::method(x)` must dispatch to the concrete
#     impl via a synthesized witness dictionary (desugar_trait_dict.vibe). Covers
#     a primitive impl, a struct impl, multiple methods (incl. `Self`-returning
#     `scale`), literal and let-bound receivers, generic->generic dict
#     forwarding, and supertrait method inheritance (flattened witness).
echo "[compiler-gate] 14/14 method-bearing-trait dict-passing regression"
mbtdir="_build/_gate_mbtrait"
rm -rf "$mbtdir"; mkdir -p "$mbtdir"
cat > "$mbtdir/mbt.vibe" <<'EOF'
trait Measurable { measure(Self) -> Int; scale(Self, Int) -> Self }
trait Sized: Measurable { bump(Self) -> Int }
struct Point { x: Int; y: Int }
impl Measurable for Int {
  measure(self) -> Int { self }
  scale(self, k) -> Int { self * k }
}
impl Measurable for Point {
  measure(self) -> Int { self.x + self.y }
  scale(self, k) -> Point { Point::{ x: self.x * k, y: self.y * k } }
}
impl Sized for Int { bump(self) -> Int { self + 1 } }
impl Sized for Point { bump(self) -> Int { self.x + self.y + 1 } }
let measure_one = [T: Measurable](x: T) -> Int { T::measure(x) }
let twice = [T: Measurable](x: T) -> Int { T::measure(T::scale(x, 2)) }
let forward = [T: Measurable](x: T) -> Int { measure_one(x) + twice(x) }
let sized_sum = [T: Sized](x: T) -> Int { T::measure(x) + T::bump(x) }
export let _start: () -> Int = () -> {
  let p = Point::{ x: 40, y: 2 }
  measure_one(42) + twice(21) + measure_one(p) + twice(p)
  + forward(10) + sized_sum(7) + sized_sum(p)
}
EOF
# Expected: 42 + 42 + 42 + 84 + (10+20) + (7+8) + (42+43) = 340
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mbtdir/mbt.vibe" "$mbtdir/mbt.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mbtdir/mbt.wasm" ]; then
  echo "[compiler-gate] FAIL: trait dict-passing program did not compile" >&2
  cat "$mbtdir/mbt.wasm.diag" >&2 2>/dev/null; exit 1
fi
mbt_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$mbtdir/mbt.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$mbt_out" != "340" ]; then
  echo "[compiler-gate] FAIL: trait dict-passing mismatch (got '$mbt_out', want 340 -> #641 PR-3 regressed)" >&2
  exit 1
fi
rm -rf "$mbtdir"
echo "[compiler-gate] method-bearing-trait dict-passing regression ok"

# 14b. rank-1 method-level generics on trait methods (#684): a trait method may
#      declare its OWN bounded type parameter `m: [X: Show](Self, X) -> R`. The
#      binder lives on the TRAIT method only; the impl does NOT repeat it. At a
#      qualified call `C::m(recv, arg)` the `Show` witness for `X = type(arg)`
#      must be resolved/threaded so the body's `X::show(arg)` dispatches to the
#      concrete impl. Covers an Int and a String argument (witness per type).
echo "[compiler-gate] 14b/14 rank-1 trait-method generics regression (#684)"
mgdir="_build/_gate_methodgen"
rm -rf "$mgdir"; mkdir -p "$mgdir"
cat > "$mgdir/mg.vibe" <<'EOF'
trait Show { show(Self) -> String }
trait Logger { write_object: [X: Show](Self, X) -> String }
struct SB { prefix: String }
impl Show for Int { show(self) -> String { __to_string(self) } }
impl Show for String { show(self) -> String { self } }
impl Logger for SB {
  write_object(self, x) -> String { String::concat(self.prefix, X::show(x)) }
}
export let _start: () -> Int = () -> {
  let sb = SB::{ prefix: "n=" }
  let a = SB::write_object(sb, 42)
  let sb2 = SB::{ prefix: "s=" }
  let b = SB::write_object(sb2, "hi")
  if a == "n=42" && b == "s=hi" { 84 } else { 0 }
}
EOF
# Expected: 84 (both Int and String witnesses resolved -> correct shown strings)
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mgdir/mg.vibe" "$mgdir/mg.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$mgdir/mg.wasm" ]; then
  echo "[compiler-gate] FAIL: rank-1 trait-method generic program did not compile" >&2
  cat "$mgdir/mg.wasm.diag" >&2 2>/dev/null; exit 1
fi
mg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$mgdir/mg.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$mg_out" != "84" ]; then
  echo "[compiler-gate] FAIL: rank-1 trait-method generic mismatch (got '$mg_out', want 84 -> #684 regressed)" >&2
  exit 1
fi
rm -rf "$mgdir"
echo "[compiler-gate] rank-1 trait-method generics regression ok"

# 14c. UFCS method call on a trait-bounded type parameter (#931): inside a
#      `[K: Hash]` generic, the UFCS spelling `k.probe_key()` must dispatch
#      through the SAME threaded witness dict as the qualified spelling
#      `K::probe_key(k)`. Before the fix the UFCS call stayed a bare EDot,
#      which codegen compiled as a struct-field read — a silent null-function
#      call at runtime. Uses the committed fixture (expected value pinned in
#      its __DATA__ block: 97097 = qualified 97 * 1000 + UFCS 97); the
#      fixture's top-level `_start()` echo line and __DATA__ tail are stripped
#      for the ADR-0069 entry-based compile.
echo "[compiler-gate] 14c/14 UFCS-on-bounded-tparam dict dispatch (#931)"
ufcsdir="_build/_gate_ufcs_tparam"
rm -rf "$ufcsdir"; mkdir -p "$ufcsdir"
# #1571: the expected value lives in the fixture now (an `inspect` test
# block), so this compiles it AS-IS -- no `__DATA__` strip, no temp copy,
# and no expected value in shell. A mismatch prints inspect's own
# actual/expected and fails the run.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/trait_bound_ufcs_method.vibe "$ufcsdir/ufcs.wasm" __no_entry__ >/dev/null 2>&1 || true
if [ ! -s "$ufcsdir/ufcs.wasm" ]; then
  echo "[compiler-gate] FAIL: UFCS-on-bounded-tparam program did not compile" >&2
  cat "$ufcsdir/ufcs.wasm.diag" >&2 2>/dev/null; exit 1
fi
if ! ufcs_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$ufcsdir/ufcs.wasm" 2>&1)"; then
  echo "[compiler-gate] FAIL: UFCS-on-bounded-tparam mismatch (want 97097 -> #931 regressed)" >&2
  echo "$ufcs_out" >&2
  exit 1
fi
rm -rf "$ufcsdir"
echo "[compiler-gate] UFCS-on-bounded-tparam dict dispatch ok (97097)"

# 15. derive(...) structural generation regression (#638): `derive(Ord)` and
#     `derive(Show)` on a struct must generate working `Type::compare`
#     (lexicographic over fields, answering the prelude `Ordering`, #3042) and
#     `Type::to_string` free functions. Also covers multiple-derive and `Eq`
#     accepted as a no-op marker. Each comparison is its own decimal digit, so
#     two wrong answers cannot cancel out.
echo "[compiler-gate] 15/15 derive(Ord/Show) structural-generation regression"
drvdir="_build/_gate_derive"
rm -rf "$drvdir"; mkdir -p "$drvdir"
cat > "$drvdir/drv.vibe" <<'EOF'
struct P { x: Int; y: Int } derive(Eq, Ord, Show)
fn digit(o: Ordering) -> Int {
  match o {
    Less => 1,
    Equal => 2,
    Greater => 3
  }
}
export let _start: () -> Int = () -> {
  digit(P::compare(P::{ x: 1, y: 1 }, P::{ x: 1, y: 2 })) * 100000
  + digit(P::compare(P::{ x: 2, y: 0 }, P::{ x: 1, y: 9 })) * 10000
  + digit(P::compare(P::{ x: 5, y: 5 }, P::{ x: 5, y: 5 })) * 1000
  + String::length(P::to_string(P::{ x: 7, y: 9 }))
}
EOF
# Expected: Less=1, Greater=3, Equal=2, then len("P { x: 7, y: 9 }")=16
# -> 132016
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$drvdir/drv.vibe" "$drvdir/drv.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$drvdir/drv.wasm" ]; then
  echo "[compiler-gate] FAIL: derive program did not compile" >&2
  cat "$drvdir/drv.wasm.diag" >&2 2>/dev/null; exit 1
fi
drv_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$drvdir/drv.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$drv_out" != "132016" ]; then
  echo "[compiler-gate] FAIL: derive mismatch (got '$drv_out', want 132016 -> #638 / #3042 regressed)" >&2
  exit 1
fi
rm -rf "$drvdir"
echo "[compiler-gate] derive(Ord/Show) structural-generation regression ok"

# Runs each given fixture as a test-block suite through the fresh stage2:
# compile with the `__no_entry__` sentinel (ADR-0069 — these files have no
# `_start` of their own, and the test-runner `_start` synthesis needs the
# explicit sentinel now that an unknown entry name is a compile error), then
# run `_start`. Every `assert` traps on failure, so a clean run == all blocks
# in the file passed.
#
# #1587: callers pass a GLOB, never a hand-written list. Three sections below
# used to carry byte-identical copies of this loop over enumerations that every
# fixture-adding PR appended to — so queued PRs collided on the same line, and
# a fixture committed without the gate edit was silently never executed. With a
# glob, a fixture that matches the convention runs the moment it lands, and
# scripts/check_fixture_execution.sh fails the gate if some test-block fixture
# is picked up by no lane at all.
run_test_block_fixtures() {
  local label="$1"; shift
  local fx fxout
  [ "$#" -gt 0 ] || { echo "[compiler-gate] FAIL: $label matched no fixtures" >&2; exit 1; }
  for fx in "$@"; do
    # An unmatched glob comes through literally (nullglob is off); catch that
    # here rather than reporting it as a compile failure of a missing file.
    [ -f "$fx" ] || { echo "[compiler-gate] FAIL: $label: no such fixture '$fx'" >&2; exit 1; }
    fxout="_build/_gate_tbf_$(basename "${fx%.vibe}").wasm"
    rm -f "$fxout" "$fxout.diag"
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$fx" "$fxout" __no_entry__ >/dev/null 2>&1 || true
    if [ ! -s "$fxout" ]; then
      echo "[compiler-gate] FAIL: $fx did not compile ($label)" >&2
      cat "$fxout.diag" >&2 2>/dev/null; exit 1
    fi
    if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
        --invoke _start "$fxout" >/dev/null 2>&1; then
      echo "[compiler-gate] FAIL: $fx has a failing test (assert trapped) ($label)" >&2
      exit 1
    fi
    rm -f "$fxout" "$fxout.diag" "$fxout.funcmap"
  done
}
