#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.
# #2404/#2405/#2407: the same fixtures, compiled through the WASM-GC backend.
# A divergence between the two lanes is invisible to a single-lane run by
# construction, and all three of those issues were exactly that: a program that
# compiled and answered correctly on linear and trapped, refused to compile, or
# answered wrongly on gc. VIBE_BACKEND=gc selects gc codegen for the final
# stage only -- module loading is unchanged (#2376).
run_test_block_fixtures_gc() {
  local label="$1"; shift
  local fx fxout
  [ "$#" -gt 0 ] || { echo "[compiler-gate] FAIL: $label matched no fixtures" >&2; exit 1; }
  for fx in "$@"; do
    [ -f "$fx" ] || { echo "[compiler-gate] FAIL: $label: no such fixture '$fx'" >&2; exit 1; }
    fxout="_build/_gate_tbfgc_$(basename "${fx%.vibe}").wasm"
    rm -f "$fxout" "$fxout.diag"
    VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$fx" "$fxout" __no_entry__ >/dev/null 2>&1 || true
    if [ ! -s "$fxout" ]; then
      echo "[compiler-gate] FAIL: $fx did not compile on the gc lane ($label)" >&2
      cat "$fxout.diag" >&2 2>/dev/null; exit 1
    fi
    if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
        --invoke _start "$fxout" >/dev/null 2>&1; then
      echo "[compiler-gate] FAIL: $fx has a failing test on the gc lane (assert trapped) ($label)" >&2
      exit 1
    fi
    rm -f "$fxout" "$fxout.diag" "$fxout.funcmap"
  done
}

# #2426: the same fixtures on the RC lane, which this gate never reached.
# `tests/gates/lib.sh` pins `VIBE_RC=0` for every lane, so the plain
# `run_test_block_fixtures` above compiles on the BUMP allocator despite its
# "linear" label -- and RC, the production default, was not exercised here at
# all. Adding a second bump invocation would have run the identical
# configuration twice (Codex review on #2430 caught exactly that). Selecting RC
# inline in the command, per the #2248 rule that a selector is never routed
# through a variable.
run_test_block_fixtures_rc() {
  local label="$1"; shift
  local fx fxout
  [ "$#" -gt 0 ] || { echo "[compiler-gate] FAIL: $label matched no fixtures" >&2; exit 1; }
  for fx in "$@"; do
    [ -f "$fx" ] || { echo "[compiler-gate] FAIL: $label: no such fixture '$fx'" >&2; exit 1; }
    fxout="_build/_gate_tbfrc_$(basename "${fx%.vibe}").wasm"
    rm -f "$fxout" "$fxout.diag"
    VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$fx" "$fxout" __no_entry__ >/dev/null 2>&1 || true
    if [ ! -s "$fxout" ]; then
      echo "[compiler-gate] FAIL: $fx did not compile on the RC lane ($label)" >&2
      cat "$fxout.diag" >&2 2>/dev/null; exit 1
    fi
    if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
        --invoke _start "$fxout" >/dev/null 2>&1; then
      echo "[compiler-gate] FAIL: $fx has a failing test on the RC lane (assert trapped) ($label)" >&2
      exit 1
    fi
    rm -f "$fxout" "$fxout.diag" "$fxout.funcmap"
  done
}

# #3069: the FLAT single-source linear lane -- `cli_main` with no
# VIBE_FS_COMPILE, the lane the compiler's own stage build and the fuzz
# harness's bump / rc columns use. Every other runner above selects the FS
# lane, so a construct this lane alone refuses went unseen here: it ran the
# trait-dictionary desugar before the checker and rejected every trait impl.
# Both allocators, each selected inline (#2248).
run_test_block_fixtures_flat() {
  local label="$1"; shift
  local fx fxout
  [ "$#" -gt 0 ] || { echo "[compiler-gate] FAIL: $label matched no fixtures" >&2; exit 1; }
  for fx in "$@"; do
    [ -f "$fx" ] || { echo "[compiler-gate] FAIL: $label: no such fixture '$fx'" >&2; exit 1; }
    fxout="_build/_gate_tbfflat_bump_$(basename "${fx%.vibe}").wasm"
    rm -f "$fxout" "$fxout.diag"
    env -u VIBE_FS_COMPILE VIBE_RC=0 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$fx" "$fxout" __no_entry__ >/dev/null 2>&1 || true
    if [ ! -s "$fxout" ]; then
      echo "[compiler-gate] FAIL: $fx did not compile on the flat single-source lane, bump ($label)" >&2
      cat "$fxout.diag" >&2 2>/dev/null; exit 1
    fi
    if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
        --invoke _start "$fxout" >/dev/null 2>&1; then
      echo "[compiler-gate] FAIL: $fx has a failing test on the flat single-source lane, bump ($label)" >&2
      exit 1
    fi
    rm -f "$fxout" "$fxout.diag" "$fxout.funcmap"
    fxout="_build/_gate_tbfflat_rc_$(basename "${fx%.vibe}").wasm"
    rm -f "$fxout" "$fxout.diag"
    env -u VIBE_FS_COMPILE VIBE_RC=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$fx" "$fxout" __no_entry__ >/dev/null 2>&1 || true
    if [ ! -s "$fxout" ]; then
      echo "[compiler-gate] FAIL: $fx did not compile on the flat single-source lane, RC ($label)" >&2
      cat "$fxout.diag" >&2 2>/dev/null; exit 1
    fi
    if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
        --invoke _start "$fxout" >/dev/null 2>&1; then
      echo "[compiler-gate] FAIL: $fx has a failing test on the flat single-source lane, RC ($label)" >&2
      exit 1
    fi
    rm -f "$fxout" "$fxout.diag" "$fxout.funcmap"
  done
}

# 15b. extended derive(...) regression (#638 / #694): enum `derive(Ord/Show)`,
#      struct + enum `derive(Default)`, `derive(Eq)`, and `derive(Hash)`
#      including transparent Map keys — `map_key_to_string = [K: Hash](key) ->
#      K::hash_key(key)` threads the witness dict (#684) through the `[K: Hash]`
#      `get_by`/`has_by`/`get_or_by` chain, with a nested-aggregate key proving
#      Layer-2 recursion. Covers multiple-derive (`derive(Eq, Ord, Show, Hash)`).
#
#      The set is `fixtures/derive_*_test.vibe`, not a list: a new derive
#      fixture that follows the convention is covered without touching this
#      file. (Three fixtures unrelated to derive — eq_array_option_fields,
#      bool_interp_test, shadow_scope_test — used to ride along here because
#      this list was the nearest place to append; they are `*_test.vibe` under
#      fixtures/, so scripts/unit_test_runner.sh runs them through this exact
#      same harness and nothing is lost by dropping them from the gate copy.)
echo "[compiler-gate] 15b/15 extended derive (enum Ord/Show, Default, Eq, Hash + Map keys)"
run_test_block_fixtures "extended derive" fixtures/derive_*_test.vibe
# Unknown-derive negative check: `derive(Foo)` for an unknown trait must error
# (`unknown trait: Foo`, no wasm emitted), keeping genuinely-unknown derive names
# rejected while Eq/Ord/Show/Hash/Default are accepted.
undir="_build/_gate_derive_unknown"
rm -rf "$undir"; mkdir -p "$undir"
cat > "$undir/u.vibe" <<'EOF'
struct P { x: Int } derive(Foo)
export let _start: () -> Int = () -> { P::{ x: 1 }.x }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$undir/u.vibe" "$undir/u.wasm" _start >/dev/null 2>&1 || true
if [ -s "$undir/u.wasm" ]; then
  echo "[compiler-gate] FAIL: derive(Foo) unknown trait was accepted (should error)" >&2
  exit 1
fi
rm -rf "$undir"
echo "[compiler-gate] extended derive (enum Ord/Show, Default, Eq, Hash + Map keys) ok"

# #1681 / ADR-0097, narrowed by #2157: an unannotated empty-array binding takes
# its element type from the `Array::push` calls in its own scope, so the
# ordinary `let xs = []` / `let mut xs = []` spellings now ANSWER after a push
# (pinned in fixtures/structural_eq_contexts_test.vibe, which the unit lane
# runs). What is left here is the residual: an element type the syntactic scan
# cannot read (a pushed NAME, or pushes that all happen inside a function the
# array is merely passed to) AND that the typed-`==` channel (#2391, after
# #2447) does not admit -- a declared element whose field allow-list fails
# (a closure field, an opaque nominal field). Once BOTH sides are non-empty
# that must fail closed at runtime rather than silently falling back to
# reference or length equality.
echo "[compiler-gate] structural equality untyped-empty mutation fail-closed (#1681/#2157)"
eqtrapdir="_build/_gate_eq_untyped_empty"
rm -rf "$eqtrapdir"; mkdir -p "$eqtrapdir"
# `structural_eq_generic_enum_*_trap.vibe` joins the loop: a source-owned
# generic ENUM compared directly. Since #2467 a concrete instantiation answers
# through a specialized comparator; what still fails closed here is a
# non-regular recursion whose specializations never close.
# `structural_eq_untyped_empty_owned_int_typed.vibe` is gone with them, and
# for the same reason -- its whole subject was "a source-owned scalar spelling
# takes its declared comparator" (#2456 round 17), which a program can no
# longer set up. What it ALSO exercised is still covered:
# `..._named_value_typed` pins a pushed identifier answering by content and
# `..._observed_struct_arg_typed` pins a pushed STRUCT doing so, neither
# needing a builtin spelling. Checked before deleting rather than assumed.
#
# The `structural_eq_owned_scalar_*` fixtures are GONE (#2475, decided): a
# program can no longer declare `struct Int` at all, so the ambiguity they
# fail closed on is unreachable. One `err_type_builtin_spelling_*` fixture
# refuses the declaration instead, and the `struct Foo` control
# (`structural_eq_owned_scalar_control_test.vibe`) keeps asserting that the
# same five shapes ANSWER once the spelling is not a builtin's.
# #2475: the refusals that are decided about a comparison the program WRITES
# are compile errors now, not runtime traps. They used to emit a bare
# `assert_true(false)`, so the program compiled clean and died with
# `trap: RuntimeError: unreachable` -- no message, no position, nothing to act
# on. There is no way to attach a message at run time (`assert_eq` lowers to
# `println` and so requires `Console` on the containing function, #2107), so
# earlier is the only place a message can go, and no guard is emitted for them.
#
# The MESSAGE is asserted, not just the refusal: "did not compile" is what the
# old loop checked for, and it is satisfied by any unrelated breakage.
for eqrefuse_src in fixtures/structural_eq_untyped_empty_*_refused.vibe; do
  eqrefuse_name="$(basename "${eqrefuse_src%.vibe}")"
  eqrefuse_wasm="$eqtrapdir/$eqrefuse_name.wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$eqrefuse_src" "$eqrefuse_wasm" _start >/dev/null 2>&1 || true
  if [ -s "$eqrefuse_wasm" ]; then
    echo "[compiler-gate] FAIL: $eqrefuse_src compiled; expected a compile-time refusal (#2475)" >&2
    exit 1
  fi
  if ! grep -qF 'structural `==` cannot be decided here' "$eqrefuse_wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $eqrefuse_src was refused without the #2475 message" >&2
    cat "$eqrefuse_wasm.diag" >&2 2>/dev/null
    exit 1
  fi
  if ! grep -qE 'Annotate|rename the declared type' "$eqrefuse_wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $eqrefuse_src refusal does not name an edit" >&2
    cat "$eqrefuse_wasm.diag" >&2 2>/dev/null
    exit 1
  fi
done
# #2912: rendering an array whose element type does not resolve is REFUSED at
# build time. It used to fall through to `compile_call`'s general `__to_string`
# arm -- a runtime heuristic that guesses string-pointer vs integer from the
# bit pattern -- so an array pointer took the integer branch and printed a heap
# address: `__to_string(Array::map(xs, (v) -> v * 2))` printed `296`, moving
# with whatever allocated before it, while `vibe check` stayed silent.
#
# Asserted on the MESSAGE and on the EDIT it names, not merely on the refusal,
# for the same reason the #2475 loop above does: a refusal with no actionable
# text is a different (and worse) product than the one this contract promises.
#
# The GREEN controls are what keep the refusal honest -- they are the three
# spellings that DO resolve, so a predicate that over-refused would fail here
# rather than passing quietly by rejecting everything.
echo "[compiler-gate] an unrenderable array is refused, not printed as an address (#2912)"
amrdir="_build/_gate_array_map_render"
rm -rf "$amrdir"; mkdir -p "$amrdir"
amr_src="fixtures/err_array_map_render_refused.vibe"
amr_wasm="$amrdir/refused.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$amr_src" "$amr_wasm" _start >/dev/null 2>&1 || true
if [ -s "$amr_wasm" ]; then
  echo "[compiler-gate] FAIL: $amr_src compiled; expected a compile-time refusal (#2912)" >&2
  exit 1
fi
if ! grep -qF 'cannot render the result of' "$amr_wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: $amr_src was refused without the #2912 message" >&2
  cat "$amr_wasm.diag" >&2 2>/dev/null; exit 1
fi
if ! grep -qE 'Annotate the binding|declared return type' "$amr_wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: $amr_src refusal does not name an edit" >&2
  cat "$amr_wasm.diag" >&2 2>/dev/null; exit 1
fi
# The three spellings that resolve must still COMPILE and still RENDER. A
# predicate that refused these would pass the rows above while breaking every
# correct program, which is the failure a refusal-only assertion cannot see.
amr_i=0
for amr_ok in \
  'let xs = [1, 2, 3]; __to_string(Array::map(xs, (v: Int) -> Int { v * 2 }))' \
  'let xs = [1, 2, 3]; __to_string(Array::filter(xs, (v) -> v > 1))' \
  'let xs: Array[Int] = [1, 2, 3]; let ys: Array[Int] = Array::map(xs, (v) -> v * 2); __to_string(ys)'; do
  amr_i=$((amr_i + 1))
  printf 'export let _start: () -> Int = () -> {\n  %s\n  0\n}\n' "$amr_ok" > "$amrdir/ok$amr_i.vibe"
  rm -f "$amrdir/ok$amr_i.wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$amrdir/ok$amr_i.vibe" "$amrdir/ok$amr_i.wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$amrdir/ok$amr_i.wasm" ]; then
    echo "[compiler-gate] FAIL: a RESOLVABLE array render was refused (#2912 over-refuses): $amr_ok" >&2
    cat "$amrdir/ok$amr_i.wasm.diag" >&2 2>/dev/null; exit 1
  fi
done
rm -rf "$amrdir"
echo "[compiler-gate] unrenderable array refusal ok (message names the edit; 3 resolvable spellings still compile)"

# #2987 (and #2986, #2970, #2998): a render argument the CHECKER typed as an
# Option / Array / tuple / Bytes / record, but whose shape normalize could not
# resolve, used to reach the same runtime heuristic as #2912 and print its
# address. The checker now files those arguments (typed-lowering tag 6) and the
# `__to_string` lowering refuses them; a `Bytes` is refused by the checker
# itself, since nothing can ever render it. Asserted on the message and the
# edit, with green controls that must still compile AND render by content.
echo "[compiler-gate] an unrenderable render argument is refused, not printed as an address (#2987)"
urdir="_build/_gate_unrenderable_render"
rm -rf "$urdir"; mkdir -p "$urdir"
# An optional fourth argument `gc` compiles through the wasm-gc backend
# (#3068: that lane printed the address where linear refused). The selector is
# written inline in each command, never routed through a variable (#2248).
# An optional fifth argument is the site the refusal must name, as the
# `<path>: line L:C` prefix of the diagnostic (#3090: the refusals raised after
# the merge -- in normalize or in codegen -- used to carry no position on either
# lane, so the build said what to edit but not where).
ur_refused() {
  local ur_src="$1" ur_msg="$2" ur_edit="$3" ur_lane="${4:-linear}" ur_at="${5:-}"
  local ur_wasm="$urdir/$(basename "${ur_src%.vibe}")_$ur_lane.wasm"
  if [ "$ur_lane" = gc ]; then
    VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$ur_src" "$ur_wasm" _start >/dev/null 2>&1 || true
  else
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$ur_src" "$ur_wasm" _start >/dev/null 2>&1 || true
  fi
  if [ -s "$ur_wasm" ]; then
    echo "[compiler-gate] FAIL: $ur_src compiled on $ur_lane; expected a compile-time refusal (#2987)" >&2
    exit 1
  fi
  if ! grep -qF "$ur_msg" "$ur_wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $ur_src was refused without the #2987 message ($ur_msg)" >&2
    cat "$ur_wasm.diag" >&2 2>/dev/null; exit 1
  fi
  if ! grep -qF "$ur_edit" "$ur_wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $ur_src refusal does not name the edit ($ur_edit)" >&2
    cat "$ur_wasm.diag" >&2 2>/dev/null; exit 1
  fi
  # The site must START the diagnostic: a position quoted inside the message
  # text is not the diagnostic's location.
  if [ -n "$ur_at" ] && [ "$(head -1 "$ur_wasm.diag" | cut -c1-${#ur_at})" != "$ur_at" ]; then
    echo "[compiler-gate] FAIL: $ur_src refusal on $ur_lane does not lead with its site ($ur_at) (#3090)" >&2
    cat "$ur_wasm.diag" >&2 2>/dev/null; exit 1
  fi
}
ur_refused fixtures/err_interp_unrenderable_bytes_refused.vibe 'cannot interpolate a `Bytes` value' 'Bytes::to_array(b)' linear 'fixtures/err_interp_unrenderable_bytes_refused.vibe: line 7:17'
ur_refused fixtures/err_interp_unrenderable_field_refused.vibe 'cannot interpolate field `tags`' 'bind it with a type annotation' linear 'fixtures/err_interp_unrenderable_field_refused.vibe: line 10:17'
ur_refused fixtures/err_interp_unrenderable_shadow_refused.vibe 'cannot interpolate `shadowed`' 'bind it with a type annotation' linear 'fixtures/err_interp_unrenderable_shadow_refused.vibe: line 14:23'
ur_refused fixtures/err_interp_iterator_map_refused.vibe 'cannot interpolate `mapped`' 'bind it with a type annotation' linear 'fixtures/err_interp_iterator_map_refused.vibe: line 11:30'
ur_refused fixtures/err_interp_iterator_filter_refused.vibe 'cannot interpolate `filtered`' 'bind it with a type annotation' linear 'fixtures/err_interp_iterator_filter_refused.vibe: line 10:30'
# #3068: an `Option[Int]` from `Int::parse`, inline and through a name.
ur_refused fixtures/err_interp_unrenderable_parse_call_refused.vibe 'cannot interpolate the result of `Int::parse`' 'bind it with a type annotation' linear 'fixtures/err_interp_unrenderable_parse_call_refused.vibe: line 7:14'
ur_refused fixtures/err_interp_unrenderable_parse_bound_refused.vibe 'cannot interpolate `p`' 'bind it with a type annotation' linear 'fixtures/err_interp_unrenderable_parse_bound_refused.vibe: line 6:14'
# #3068: the gc lane refuses every one of these with the same message. It had
# none of the codegen refusals and printed the address (`809`, `177`, `224`).
ur_refused fixtures/err_interp_unrenderable_bytes_refused.vibe 'cannot interpolate a `Bytes` value' 'Bytes::to_array(b)' gc 'fixtures/err_interp_unrenderable_bytes_refused.vibe: line 7:17'
ur_refused fixtures/err_interp_unrenderable_field_refused.vibe 'cannot interpolate field `tags`' 'bind it with a type annotation' gc 'fixtures/err_interp_unrenderable_field_refused.vibe: line 10:17'
ur_refused fixtures/err_interp_unrenderable_shadow_refused.vibe 'cannot interpolate `shadowed`' 'bind it with a type annotation' gc 'fixtures/err_interp_unrenderable_shadow_refused.vibe: line 14:23'
ur_refused fixtures/err_interp_unrenderable_parse_call_refused.vibe 'cannot interpolate the result of `Int::parse`' 'bind it with a type annotation' gc 'fixtures/err_interp_unrenderable_parse_call_refused.vibe: line 7:14'
ur_refused fixtures/err_interp_unrenderable_parse_bound_refused.vibe 'cannot interpolate `p`' 'bind it with a type annotation' gc 'fixtures/err_interp_unrenderable_parse_bound_refused.vibe: line 6:14'
# #3080: an index-form slice whose subject's shape is unresolved. The slice call
# had no source offset, so no row reached codegen and both lanes printed an
# address. The message names the syntax, not the internal `__slice`.
ur_refused fixtures/err_interp_unrenderable_slice_field_refused.vibe 'cannot interpolate this slice (`xs[a:b]`)' 'bind it with a type annotation' linear 'fixtures/err_interp_unrenderable_slice_field_refused.vibe: line 13:21'
ur_refused fixtures/err_interp_unrenderable_slice_field_refused.vibe 'cannot interpolate this slice (`xs[a:b]`)' 'bind it with a type annotation' gc 'fixtures/err_interp_unrenderable_slice_field_refused.vibe: line 13:21'
# #3075: a function value, bare or inside a container, has no text form.
ur_refused fixtures/err_interp_function_payload_refused.vibe 'cannot interpolate a function value' 'interpolate what it returns' linear 'fixtures/err_interp_function_payload_refused.vibe: line 6:14'
ur_refused fixtures/err_interp_function_value_refused.vibe 'cannot interpolate a function value' 'interpolate what it returns' linear 'fixtures/err_interp_function_value_refused.vibe: line 5:14'
# #3133: an index whose receiver the checker never typed may be a Map at run
# time; array indexing on a Map reads its backing store positionally, so the
# build refuses it and names the site (its `[`). The green side -- every Map
# spelling lowering to `Map::get`, and arrays still indexing -- is
# fixtures/map_index_test.vibe in the unit lane. (The ur_ helper's FAIL text
# names #2987; the assertion is the message, the edit and the site.)
ur_refused fixtures/err_map_index_open_receiver_refused.vibe 'cannot tell whether this index reads a Map or an Array' 'annotate it' linear 'fixtures/err_map_index_open_receiver_refused.vibe: line 9:4'
ur_refused fixtures/err_map_index_open_receiver_refused.vibe 'cannot tell whether this index reads a Map or an Array' 'annotate it' gc 'fixtures/err_map_index_open_receiver_refused.vibe: line 9:4'
# #3139: the WRITE side -- `xs[i] = v` (sited at its `[`) and a written
# `Array::set(..)` (sited at its name) on a receiver the checker never typed.
ur_refused fixtures/err_index_write_open_receiver_refused.vibe 'cannot tell whether this index write targets an Array' 'Map::set(m, k, v)' linear 'fixtures/err_index_write_open_receiver_refused.vibe: line 10:6'
ur_refused fixtures/err_index_write_open_receiver_refused.vibe 'cannot tell whether this index write targets an Array' 'Map::set(m, k, v)' gc 'fixtures/err_index_write_open_receiver_refused.vibe: line 10:6'
ur_refused fixtures/err_array_set_open_receiver_refused.vibe 'cannot tell whether this index write targets an Array' 'annotate it' linear 'fixtures/err_array_set_open_receiver_refused.vibe: line 7:3'
ur_refused fixtures/err_array_set_open_receiver_refused.vibe 'cannot tell whether this index write targets an Array' 'annotate it' gc 'fixtures/err_array_set_open_receiver_refused.vibe: line 7:3'
# #3145: the builtin `Array::*` readers (`array_receiver_reads`) on an erased
# formal -- `Array::get` (a special checker arm) and `Array::length` (the
# direct fast path, which binds the formal in the body without the binding
# reaching callers; it answered 0 for a one-entry map). An unannotated lambda
# parameter is now bound to `Array[_]` instead, so a Map argument is a type
# error at the call (fixtures/typecheck/array_reader_lambda_param_binds_reject).
# #3149: since the declaration's scheme carries that binding, a caller BELOW
# the declaration is a type error too (array_reader_formal_scheme_reject); the
# refusal remains for what the scheme cannot reach -- a caller ABOVE the
# declaration, checked against its hoisted signature, as in these fixtures,
# and an exported declaration, callable through its contract.
ur_refused fixtures/err_array_get_open_receiver_refused.vibe 'cannot tell whether this call reads an Array: `Array::get`' 'annotate it' linear 'fixtures/err_array_get_open_receiver_refused.vibe: line 16:3'
ur_refused fixtures/err_array_get_open_receiver_refused.vibe 'cannot tell whether this call reads an Array: `Array::get`' 'annotate it' gc 'fixtures/err_array_get_open_receiver_refused.vibe: line 16:3'
ur_refused fixtures/err_array_length_formal_refused.vibe 'cannot tell whether this call reads an Array: `Array::length`' 'annotate it' linear 'fixtures/err_array_length_formal_refused.vibe: line 14:3'
# #3145 review: a two-array reader refuses naming the operand that is
# actually unresolved -- here the second, `ys`, not the resolved `xs`.
ur_refused fixtures/err_array_concat_second_formal_refused.vibe 'treats `ys` as an Array' 'annotate it' linear 'fixtures/err_array_concat_second_formal_refused.vibe: line 15:3'
ur_refused fixtures/err_array_concat_second_formal_refused.vibe 'treats `ys` as an Array' 'annotate it' gc 'fixtures/err_array_concat_second_formal_refused.vibe: line 15:3'
# #3133 review: an unannotated lambda parameter shadowing an outer Map binding
# of the same name is not a Map by spelling; its index is refused as open.
ur_refused fixtures/err_map_index_shadowed_param_refused.vibe 'cannot tell whether this index reads a Map or an Array' 'annotate it' linear 'fixtures/err_map_index_shadowed_param_refused.vibe: line 10:21'
ur_refused fixtures/err_map_index_shadowed_param_refused.vibe 'cannot tell whether this index reads a Map or an Array' 'annotate it' gc 'fixtures/err_map_index_shadowed_param_refused.vibe: line 10:21'
# #3148: a `for` over an iterand whose type never resolves (an erased formal
# holding a map ran zero times). The green side -- a Map iterates its keys,
# Arrays and Strings keep their loops -- is fixtures/for_in_map_keys_test.vibe.
ur_refused fixtures/err_for_in_open_iterand_refused.vibe 'cannot tell whether this `for` iterates an Array or a Map' 'Map::keys(m)' linear 'fixtures/err_for_in_open_iterand_refused.vibe: line 15:12'
ur_refused fixtures/err_for_in_open_iterand_refused.vibe 'cannot tell whether this `for` iterates an Array or a Map' 'Map::keys(m)' gc 'fixtures/err_for_in_open_iterand_refused.vibe: line 15:12'
ur_refused fixtures/err_array_length_formal_refused.vibe 'cannot tell whether this call reads an Array: `Array::length`' 'annotate it' gc 'fixtures/err_array_length_formal_refused.vibe: line 14:3'
# #3156 review: a formal the body has ALREADY unified with an Array (through
# an ordinary function) is a settled Array to the substitution, but not to a
# caller the scheme cannot reach -- one above the declaration, or one through
# an exported declaration's contract. An index or a `for` on it read a Map's
# backing store by position; the site is refused as the formal it is. Declared
# first, the call is a type error instead
# (fixtures/typecheck/index_formal_bound_array_scheme_reject).
ur_refused fixtures/err_index_formal_bound_array_refused.vibe 'cannot tell whether this index reads a Map or an Array' 'annotate it' linear 'fixtures/err_index_formal_bound_array_refused.vibe: line 22:4'
ur_refused fixtures/err_index_formal_bound_array_refused.vibe 'cannot tell whether this index reads a Map or an Array' 'annotate it' gc 'fixtures/err_index_formal_bound_array_refused.vibe: line 22:4'
ur_refused fixtures/err_index_formal_bound_array_exported_refused.vibe 'cannot tell whether this index reads a Map or an Array' 'annotate it' linear 'fixtures/err_index_formal_bound_array_exported_refused.vibe: line 13:4'
ur_refused fixtures/err_for_in_formal_bound_array_refused.vibe 'cannot tell whether this `for` iterates an Array or a Map' 'Map::keys(m)' linear 'fixtures/err_for_in_formal_bound_array_refused.vibe: line 19:13'
ur_refused fixtures/err_for_in_formal_bound_array_refused.vibe 'cannot tell whether this `for` iterates an Array or a Map' 'Map::keys(m)' gc 'fixtures/err_for_in_formal_bound_array_refused.vibe: line 19:13'
# #3074: a generic enum whose instantiation cannot be recovered would render
# its payload through the erased formal (`GA(1)` for `GA(true)`).
ur_refused fixtures/err_interp_generic_enum_unknown_refused.vibe 'its type arguments are not known here' 'bind it with a type annotation' linear 'fixtures/err_interp_generic_enum_unknown_refused.vibe: line 12:4'
# #3082: a recursive generic struct at an argument its erased renderer cannot
# print (that one used to overflow the compiler's stack). The unknown-
# instantiation struct program this row used to refuse renders by content
# since #3088 (generic_field_projection_render_test.vibe).
ur_refused fixtures/err_interp_generic_struct_recursive_refused.vibe 'cannot interpolate a recursive `L`' 'render the value with a function you write' linear 'fixtures/err_interp_generic_struct_recursive_refused.vibe: line 12:14'
ur_refused fixtures/err_derive_show_recursive_generic_field_refused.vibe 'a derived renderer contains a recursive `L`' 'write the containing type'
# #3092: a function or `Bytes` inside a derived renderer, declared or reached
# through a type argument, printed a table index or an address.
ur_refused fixtures/err_derive_show_fn_field_refused.vibe 'a derived renderer contains a function value' 'write the type'
ur_refused fixtures/err_derive_show_bytes_field_refused.vibe 'a derived renderer contains a `Bytes` value' 'write the type'
ur_refused fixtures/err_derive_show_generic_fn_arg_refused.vibe 'cannot interpolate a function value' 'interpolate what it returns' linear 'fixtures/err_derive_show_generic_fn_arg_refused.vibe: line 14:14'
ur_refused fixtures/err_derive_show_fn_field_refused.vibe 'a derived renderer contains a function value' 'write the type' gc
ur_refused fixtures/err_derive_show_generic_fn_arg_refused.vibe 'cannot interpolate a function value' 'interpolate what it returns' gc 'fixtures/err_derive_show_generic_fn_arg_refused.vibe: line 14:14'
# #3084: a generic function's result typed, at the call site, as a struct with
# no renderer printed its address; the checker's row names the struct.
ur_refused fixtures/err_interp_generic_call_missing_show_refused.vibe 'cannot interpolate a value of type `Hidden`' 'add `derive(Show)` to `Hidden`' linear 'fixtures/err_interp_generic_call_missing_show_refused.vibe: line 14:14'
# #3090: the gc lane names the same site as linear for the refusals above that
# had a linear row only. Those raised after the merge (normalize and codegen)
# carried no position on EITHER lane; the merge's offset space now locates
# them (core/merged_offset_space.vibe).
ur_refused fixtures/err_interp_function_payload_refused.vibe 'cannot interpolate a function value' 'interpolate what it returns' gc 'fixtures/err_interp_function_payload_refused.vibe: line 6:14'
ur_refused fixtures/err_interp_function_value_refused.vibe 'cannot interpolate a function value' 'interpolate what it returns' gc 'fixtures/err_interp_function_value_refused.vibe: line 5:14'
ur_refused fixtures/err_interp_generic_enum_unknown_refused.vibe 'its type arguments are not known here' 'bind it with a type annotation' gc 'fixtures/err_interp_generic_enum_unknown_refused.vibe: line 12:4'
ur_refused fixtures/err_interp_generic_struct_recursive_refused.vibe 'cannot interpolate a recursive `L`' 'render the value with a function you write' gc 'fixtures/err_interp_generic_struct_recursive_refused.vibe: line 12:14'
ur_refused fixtures/err_interp_generic_call_missing_show_refused.vibe 'cannot interpolate a value of type `Hidden`' 'add `derive(Show)` to `Hidden`' gc 'fixtures/err_interp_generic_call_missing_show_refused.vibe: line 14:14'
# A generic whose bound is passed as a witness at each call, named as a value:
# the reference carries no witness, and the module failed wasm validation.
ur_refused fixtures/err_threaded_generic_value_refused.vibe 'its `[T: Eq]` bound is supplied at each call, so it cannot be passed as a value' 'wrap `same` in a lambda that takes concrete parameter types and calls it'
ur_refused fixtures/err_threaded_generic_qualified_value_refused.vibe 'its `[T: Eq]` bound is supplied at each call, so it cannot be passed as a value' 'wrap `Util::same` in a lambda that takes concrete parameter types and calls it'
ur_refused fixtures/err_threaded_generic_local_value_refused.vibe 'its `[T: Eq]` bound is supplied at each call, so it cannot be passed as a value' 'wrap `same` in a lambda that takes concrete parameter types and calls it'
# #3019 rides the same helper: a lowering-time refusal asserted on its message
# and its edit, not on the bare fact that the build failed.
ur_refused fixtures/err_handle_resume_capture_loop_break_refused.vibe 'leaves a loop outside it' 'set a flag inside the handle'
# #3042: an `Ordering` of another shape that reached a module only through an
# imported signature. The module's checker never saw the declaration, so the
# merged program is refused instead of stopping with an internal error.
ur_refused fixtures/err_ordering_derive_imported_foreign_type_refused.vibe 'but a module in this program declares its own `Ordering`' 'rename that declaration'
# An `Ordering` spelled like the prelude carries its derives; a hand-written
# operation beside it could disagree with what an importer was checked against.
ur_refused fixtures/err_ordering_exact_shape_hand_written_refused.vibe 'is spelled exactly like the prelude' 'remove it and derive it, or rename the type'
ur_refused fixtures/err_ordering_exact_shape_derive_and_hand_refused.vibe 'is spelled exactly like the prelude' 'remove it and derive it, or rename the type'
# #3176: a program's own row-variable function spelled like an audited pure
# builtin (`Future::ready`) is refused exactly as the same function spelled
# `relay` is. It used to be taken for the builtin: the suspend-class program
# answered 389 instead of 111, the evidence one trapped at run time. The
# concrete-row answers are fixtures/pure_builtin_spelling_user_fn_test.vibe.
ur_refused fixtures/err_pure_builtin_spelling_rowvar_suspend_refused.vibe 'a handler arm captures `resume` as a value' "(here: the call to 'Future::ready')"
ur_refused fixtures/err_pure_builtin_spelling_rowvar_evidence_refused.vibe 'the pass cannot see through `Future::ready`, whose declared row has a row variable' 'give it a concrete row'
# #2994: `vibe check` reports the handle-eligibility refusal AT the handled
# body's first call; it used to carry no position at all.
hi_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  check fixtures/typecheck/handle_invisible_perform_located_reject.vibe 2>&1 || true)"
if ! printf '%s\n' "$hi_out" | grep -qF "line 9:20-27: handle of effect 'Counter' cannot be compiled here"; then
  echo "[compiler-gate] FAIL: the handle-eligibility refusal is not located at 9:20-27 (#2994)" >&2
  printf '%s\n' "$hi_out" >&2; exit 1
fi
# The spellings the refusal message recommends, and the shapes normalize
# already resolves, must still compile and still render BY CONTENT -- the
# answer is written to stdout and compared, so a control that compiled but
# printed an address would fail here too.
ur_i=0
for ur_ok in \
  'struct Bx { tags: Array[Int] }|let bx = Bx::{ tags: [1, 2] }; let t: Array[Int] = bx.tags; println("\{t}")|[1, 2]' \
  '|let v: Option[Int] = Int::parse("42"); println("\{v}")|Some(42)' \
  '|let xs = [1, 2, 3]; let o: Option[Int] = Some(3); println("\{xs} \{o} \{Array::length(xs)}")|[1, 2, 3] Some(3) 3' \
  'fn k2(b?: Int) -> String { "o=\{b}" }|println("\{k2(1)} \{k2()}")|o=Some(1) o=None' \
  'fn f(t: (Int, String)) -> String { "\{t}" }|println(f((1, "a")))|(1, a)'; do
  ur_i=$((ur_i + 1))
  ur_decl="${ur_ok%%|*}"; ur_rest="${ur_ok#*|}"
  ur_body="${ur_rest%%|*}"; ur_want="${ur_rest#*|}"
  printf '%s\nfn main allows Console {\n  %s\n}\n' "$ur_decl" "$ur_body" > "$urdir/ok$ur_i.vibe"
  # #3068: the controls run on the gc lane too, so its refusal cannot
  # over-refuse a spelling the message recommends.
  for ur_lane in linear gc; do
    ur_okw="$urdir/ok${ur_i}_$ur_lane.wasm"
    rm -f "$ur_okw"
    if [ "$ur_lane" = gc ]; then
      VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
        bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
        "$urdir/ok$ur_i.vibe" "$ur_okw" main >/dev/null 2>&1 || true
    else
      VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
        bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
        "$urdir/ok$ur_i.vibe" "$ur_okw" main >/dev/null 2>&1 || true
    fi
    if [ ! -s "$ur_okw" ]; then
      echo "[compiler-gate] FAIL: a RESOLVABLE render was refused on $ur_lane (#2987 over-refuses): $ur_body" >&2
      cat "$ur_okw.diag" >&2 2>/dev/null; exit 1
    fi
    ur_got="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$ur_okw" 2>/dev/null | head -1)"
    if [ "$ur_got" != "$ur_want" ]; then
      echo "[compiler-gate] FAIL: control $ur_i rendered '$ur_got' on $ur_lane, expected '$ur_want' (#2987)" >&2
      exit 1
    fi
  done
done
rm -rf "$urdir"
echo "[compiler-gate] unrenderable render refusal ok (message names the edit; 5 resolvable spellings still render on linear and gc)"

# #2990: `Map::get` on a missing key TRAPS on both lanes. It used to answer the
# zero bit pattern typed as the value type (`0`, `""`, an Array at address 0).
# The program prints the present key's value first, so a run that dies before
# the lookup (or a build that fails) cannot satisfy this row.
echo "[compiler-gate] Map::get on a missing key traps instead of answering zero (#2990)"
mgdir="_build/_gate_map_get_miss"
rm -rf "$mgdir"; mkdir -p "$mgdir"
for mg_backend in linear gc; do
  mg_wasm="$mgdir/miss_$mg_backend.wasm"
  if [ "$mg_backend" = gc ]; then
    VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      fixtures/map_get_missing_key_trap.vibe "$mg_wasm" main >/dev/null 2>&1 || true
  else
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      fixtures/map_get_missing_key_trap.vibe "$mg_wasm" main >/dev/null 2>&1 || true
  fi
  if [ ! -s "$mg_wasm" ]; then
    echo "[compiler-gate] FAIL: fixtures/map_get_missing_key_trap.vibe did not compile on $mg_backend (#2990)" >&2
    cat "$mg_wasm.diag" >&2 2>/dev/null; exit 1
  fi
  mg_status=0
  mg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_RUNNER_EXIT_WITH_RESULT=1 bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$mg_wasm" 2>&1)" || mg_status=$?
  if ! printf '%s\n' "$mg_out" | grep -qF 'present: 1'; then
    echo "[compiler-gate] FAIL: the present key did not answer on $mg_backend (#2990): $mg_out" >&2
    exit 1
  fi
  if [ "$mg_status" -eq 0 ] || printf '%s\n' "$mg_out" | grep -qF 'missing:'; then
    echo "[compiler-gate] FAIL: a missing key answered instead of trapping on $mg_backend (#2990): $mg_out" >&2
    exit 1
  fi
done
rm -rf "$mgdir"
echo "[compiler-gate] Map::get missing-key trap ok (linear and gc)"

# #3126: an `Int` `/` or `%` whose divisor is zero names the operation and the
# operator's `path:line:col` before it traps, on both lanes. It used to trap
# with the engine's bare `divide by zero` and no position at all -- the linear
# lane's frame annotation pointed at the enclosing statement's line, gc at
# nothing. Each fixture prints a line first, so a build or run that dies before
# the division cannot satisfy the row, and the division still TRAPS: this adds
# a message, not a checked operator. The mixed fixture also divides Doubles:
# the site pass skips a `/` whose operand is a Double by its own syntax, and
# must still place the Int division beside them.
echo "[compiler-gate] Int / and % by zero name the operation and path:line:col (#3126)"
dzdir="_build/_gate_div_zero"
rm -rf "$dzdir"; mkdir -p "$dzdir"
for dz_case in "int_div_zero_trap|/|7|5" "int_rem_zero_trap|%|7|5" "int_div_assign_zero_trap|/|7|8" "int_div_zero_vibe_comment_trap|/|7|5" "int_div_zero_mixed_double_trap|/|14|5"; do
  IFS='|' read -r dz_name dz_op dz_line dz_col <<<"$dz_case"
  dz_src="fixtures/$dz_name.vibe"
  dz_want="Int \`$dz_op\` by zero at $dz_src:$dz_line:$dz_col"
  for dz_backend in linear gc; do
    dz_wasm="$dzdir/${dz_name}_$dz_backend.wasm"
    if [ "$dz_backend" = gc ]; then
      VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
        bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
        "$dz_src" "$dz_wasm" main >/dev/null 2>&1 || true
    else
      VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
        bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
        "$dz_src" "$dz_wasm" main >/dev/null 2>&1 || true
    fi
    if [ ! -s "$dz_wasm" ]; then
      echo "[compiler-gate] FAIL: $dz_src did not compile on $dz_backend (#3126)" >&2
      cat "$dz_wasm.diag" >&2 2>/dev/null; exit 1
    fi
    dz_status=0
    dz_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_RUNNER_EXIT_WITH_RESULT=1 bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$dz_wasm" 2>&1)" || dz_status=$?
    if ! printf '%s\n' "$dz_out" | grep -qF 'before'; then
      echo "[compiler-gate] FAIL: $dz_src died before the division on $dz_backend (#3126): $dz_out" >&2
      exit 1
    fi
    if [ "$dz_status" -eq 0 ] || printf '%s\n' "$dz_out" | grep -qF 'after'; then
      echo "[compiler-gate] FAIL: a zero divisor answered instead of trapping on $dz_backend (#3126): $dz_out" >&2
      exit 1
    fi
    if ! printf '%s\n' "$dz_out" | grep -qxF "$dz_want"; then
      echo "[compiler-gate] FAIL: $dz_src did not report '$dz_want' on $dz_backend (#3126): $dz_out" >&2
      exit 1
    fi
  done
done
rm -rf "$dzdir"
echo "[compiler-gate] Int division-by-zero trap message ok (/, %, /=; linear and gc)"

# #3126 + #3158: on wasm-gc the division-by-zero abort and the erased-generic
# `__generic_rel_diff` / `__generic_add` pair are conditionally pushed builtin
# bodies, both after the optional integer renderer, and their indices are
# POSITIONAL. With both present, an index that does not count the other's body
# calls the wrong function (or fails validation). The fixture has both, plus
# the capacity allocator ahead of them: its `before` line must carry the right
# generic answers, and the division must still report its location and trap.
echo "[compiler-gate] Int / by zero and erased-generic + / < in one program (#3126 / #3158)"
dgdir="_build/_gate_div_zero_generic"
rm -rf "$dgdir"; mkdir -p "$dgdir"
dg_src="fixtures/int_div_zero_generic_dispatch_trap.vibe"
dg_before="before add=42 neg=-2 cat=abcd lt=true gt=false lts=false"
dg_want="Int \`/\` by zero at $dg_src:31:5"
for dg_backend in linear gc; do
  dg_wasm="$dgdir/int_div_zero_generic_dispatch_trap_$dg_backend.wasm"
  if [ "$dg_backend" = gc ]; then
    VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$dg_src" "$dg_wasm" main >/dev/null 2>&1 || true
  else
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
      "$dg_src" "$dg_wasm" main >/dev/null 2>&1 || true
  fi
  if [ ! -s "$dg_wasm" ]; then
    echo "[compiler-gate] FAIL: $dg_src did not compile on $dg_backend (#3126 / #3158)" >&2
    cat "$dg_wasm.diag" >&2 2>/dev/null; exit 1
  fi
  dg_status=0
  dg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_RUNNER_EXIT_WITH_RESULT=1 bash scripts/run_wasm_vibe_host_runner.sh --invoke main "$dg_wasm" 2>&1)" || dg_status=$?
  if ! printf '%s\n' "$dg_out" | grep -qxF "$dg_before"; then
    echo "[compiler-gate] FAIL: $dg_src generic answers wrong on $dg_backend, want '$dg_before' (#3158): $dg_out" >&2
    exit 1
  fi
  if [ "$dg_status" -eq 0 ] || printf '%s\n' "$dg_out" | grep -qF 'after'; then
    echo "[compiler-gate] FAIL: a zero divisor answered instead of trapping on $dg_backend (#3126): $dg_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$dg_out" | grep -qxF "$dg_want"; then
    echo "[compiler-gate] FAIL: $dg_src did not report '$dg_want' on $dg_backend (#3126): $dg_out" >&2
    exit 1
  fi
done
rm -rf "$dgdir"
echo "[compiler-gate] Int / by zero beside erased-generic dispatch ok (linear and gc)"

# #2737: a witness dispatch on a bound declared by a LAMBDA binder is refused,
# with a message that names the edit. The checks, the measurements behind them,
# and the red test that proves they can fail live in the gate script and its
# self-test (scripts/check_lambda_bound_refusal{,_test}.sh); this lane hands it
# the compiler rather than letting it pick one.
echo "[compiler-gate] a witness dispatch on a lambda binder's bound is refused (#2737)"
LAMBDA_BOUND_REFUSAL_STAGE2="$stage2_wasm" bash scripts/check_lambda_bound_refusal.sh

# #2762: an aggregate `export { }` naming a name the module neither declares nor
# imports is refused, with a message that LEADS with the edit. The checks, the
# measurements behind them, and the red test that proves they can fail live in
# the gate script and its self-test (scripts/check_export_refusal{,_test}.sh);
# this lane hands it the compiler rather than letting it pick one. The GREEN
# side -- the six shapes such an export MAY name -- rides the
# fixtures/typecheck lane's `export_aggregate_*_ok` rows.
echo "[compiler-gate] an aggregate export naming an undeclared name is refused (#2762)"
EXPORT_REFUSAL_STAGE2="$stage2_wasm" bash scripts/check_export_refusal.sh

# #2872: a bodyless `impl` of a method-bearing trait whose method has no
# `<Type>::<method>` to fall back to is refused at BUILD time, with a message
# that LEADS with the edit. It used to pass `vibe check` clean and emit a
# module the wasm VALIDATOR rejected -- the witness dictionary carried a hole,
# so the call site was one argument short. The checks, the measurements behind
# them, and the red test that proves they can fail live in the gate script and
# its self-test (scripts/check_bodyless_impl_refusal{,_test}.sh); this lane
# hands it the compiler rather than letting it pick one. The GREEN side -- a
# bodyless impl whose fallback DOES resolve, to a builtin or to a
# `derive (Eq)`-generated user function -- rides the unit lane
# (fixtures/bodyless_impl_witness_test.vibe).
echo "[compiler-gate] a bodyless impl with no fallback method is refused (#2872)"
BODYLESS_IMPL_REFUSAL_STAGE2="$stage2_wasm" bash scripts/check_bodyless_impl_refusal.sh

# #2378: `vibe check` reports a qualified `fn` definition of a builtin name.
#
# The leak is narrow and so is the rule. Measured on the seed: a BARE `fn eq` in
# a dependency does NOT leak (export namespacing renames every non-entry value
# def to `name_exp_<path>`), while `fn String::index_of` DOES -- a caller that
# imports only an unrelated name from that file gets the override, silently.
# `append_export_def_name` excludes a name containing `::` from the rename on
# purpose ("ordinary `Type::method` lets remain global receiver dispatch"), so
# this shape, and only this shape, is program-wide.
#
# Three cases, not one. A gate that only asserts the warning fires would pass on
# a rule that warns about everything; the two clean cases are what make it mean
# something. The VALUE ALIAS case is the sharp one: `lib/@vibe/fs/fs.vibe`
# records that a bare alias does not participate in the name-to-fn-def
# resolution the lowering uses, while a real fn def does -- so an alias
# re-exports the builtin and must stay silent.
echo "[compiler-gate] a qualified fn definition of a builtin name is reported (#2378)"
bsdir="_build/_gate_builtin_shadow_warn"
rm -rf "$bsdir"; mkdir -p "$bsdir"
printf 'export fn String::index_of(s: String, sub: String) -> Int {\n  0 - 999\n}\n' > "$bsdir/shadow_fn.vibe"
printf 'fn my_index_of(s: String, sub: String) -> Int {\n  0 - 999\n}\n\nexport let String::index_of = my_index_of\n' > "$bsdir/alias.vibe"
printf 'export fn eq(a: Int, b: Int) -> Bool {\n  false\n}\n' > "$bsdir/bare.vibe"
bs_check() { # <src> <tag>
  rm -f "$bsdir/$2.out" "$bsdir/$2.out.diag"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_CHECK_ONLY=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$1" "$bsdir/$2.out" "" >/dev/null 2>&1 || true
}
bs_check "$bsdir/shadow_fn.vibe" shadow_fn
if ! grep -qF 'rename `String::index_of`' "$bsdir/shadow_fn.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a qualified fn definition of a builtin name was not reported (#2378)" >&2
  cat "$bsdir/shadow_fn.out" "$bsdir/shadow_fn.out.diag" >&2 2>/dev/null; exit 1
fi
if ! grep -qE 'never import it' "$bsdir/shadow_fn.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the #2378 report does not say why the name is program-wide" >&2
  cat "$bsdir/shadow_fn.out" >&2; exit 1
fi
bs_check "$bsdir/alias.vibe" alias
if grep -qF 'rename `' "$bsdir/alias.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a VALUE ALIAS at a builtin name was reported; it re-exports the builtin (#2378)" >&2
  cat "$bsdir/alias.out" >&2; exit 1
fi
bs_check "$bsdir/bare.vibe" bare
if grep -qF 'rename `' "$bsdir/bare.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: a BARE definition was reported; export namespacing already scopes it (#2378)" >&2
  cat "$bsdir/bare.out" >&2; exit 1
fi
# The CROSS-FILE case, which is the one #2378 is actually about: the caller
# imports only an unrelated name and still gets the override. Checking the
# ENTRY has to report it, naming the dependency that has to be edited --
# scanning the entry alone left `vibe check main.vibe` saying `ok` while
# `main.vibe` was the program getting the wrong builtin (#2628 review).
printf 'export fn String::index_of(s: String, sub: String) -> Int {\n  0 - 999\n}\n\nexport fn unrelated_helper(n: Int) -> Int {\n  n + 1\n}\n' > "$bsdir/xdep.vibe"
printf 'import ./xdep.vibe { unrelated_helper }\n\nexport fn run() -> Int {\n  unrelated_helper(1) + String::index_of("hello world", "world")\n}\n' > "$bsdir/xmain.vibe"
# Since the importer-side rule landed, the cross-file case is a REFUSAL, not a
# warning: the module that links the dependency is the one surprised, so it is
# the one refused, and it must never come back `ok`. The definer's own file
# (shadow_fn above) keeps the warning -- an entry's own shadow is explicit and
# legal (fixtures/to_string_shadowed_builtin_test.vibe).
bs_check "$bsdir/xmain.vibe" xmain
if grep -qx 'ok' "$bsdir/xmain.out" 2>/dev/null; then
  echo "[compiler-gate] FAIL: checking the ENTRY accepted a dependency's builtin override (#2378)" >&2
  cat "$bsdir/xmain.out" "$bsdir/xmain.out.diag" >&2 2>/dev/null; exit 1
fi
if ! grep -qF 'rename `String::index_of` in ' "$bsdir/xmain.out.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: checking the ENTRY did not refuse a dependency's builtin override with the edit first (#2378)" >&2
  cat "$bsdir/xmain.out" "$bsdir/xmain.out.diag" >&2 2>/dev/null; exit 1
fi
if ! grep -qF 'xdep.vibe' "$bsdir/xmain.out.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: the cross-file refusal does not name the file to edit (#2378)" >&2
  cat "$bsdir/xmain.out.diag" >&2; exit 1
fi
echo "[compiler-gate] qualified fn reported (own file and through an import); value alias and bare name stay silent ok (#2378)"

# The rungs that stay a RUNTIME trap. These fire while GENERATING a comparator
# for a generic shape, not at a comparison the program performs -- the
# compiler's own sources reach two of them (`List` and `AvlTree` at a formal
# argument) and the emitted trap is never executed, so reporting them at
# compile time would reject the compiler itself. Measured on #2475.
for eqtrap_src in fixtures/structural_eq_generic_enum_*_trap.vibe; do
  eqtrap_name="$(basename "${eqtrap_src%.vibe}")"
  eqtrap_wasm="$eqtrapdir/$eqtrap_name.wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$eqtrap_src" "$eqtrap_wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$eqtrap_wasm" ]; then
    echo "[compiler-gate] FAIL: $eqtrap_src did not compile" >&2
    cat "$eqtrap_wasm.diag" >&2 2>/dev/null
    exit 1
  fi
  if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$eqtrap_wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $eqtrap_src returned normally; expected fail-closed trap" >&2
    exit 1
  fi
done
rm -rf "$eqtrapdir"
echo "[compiler-gate] structural equality untyped-empty mutation fail-closed ok (== + !=)"

# #2474 (a): the lexical-formal spelling of the same scenario is refused one
# phase earlier. `fn same[T]` comparing two untyped-empty arrays filled with
# `T` values has no comparator its single lowering could reach, so the checker
# rejects the `==` and names the `Eq` bound as the edit -- before codegen,
# on both lanes. This used to be the `_lexical_formal_trap` fixture in the
# loop above; a compile-time refusal is the same fail-closed contract, so the
# gate asserts the refusal AND its message (an unrelated compile failure must
# not pass as this one).
echo "[compiler-gate] untyped-empty equality on an unbounded formal is rejected at check time (#2474)"
eqrejdir="_build/_gate_eq_unbounded_formal"
rm -rf "$eqrejdir"; mkdir -p "$eqrejdir"
eqrej_src="fixtures/structural_eq_untyped_empty_lexical_formal_rejected.vibe"
eqrej_wasm="$eqrejdir/lexical_formal_rejected.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eqrej_src" "$eqrej_wasm" _start >/dev/null 2>&1 || true
if [ -s "$eqrej_wasm" ]; then
  echo "[compiler-gate] FAIL: $eqrej_src compiled; expected the checker to reject == on an unbounded formal (#2474)" >&2
  exit 1
fi
if ! grep -qF 'compares two values of type `Array[T]`, but the type parameter `T` has no `Eq` bound' "$eqrej_wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: $eqrej_src was refused for another reason than the missing Eq bound (#2474)" >&2
  cat "$eqrej_wasm.diag" >&2 2>/dev/null
  exit 1
fi
rm -rf "$eqrejdir"
echo "[compiler-gate] untyped-empty equality on an unbounded formal is rejected at check time ok (#2474)"

# #2391 (after #2447): the other side of the same residual. The three shapes
# that used to sit in the loop above as traps -- a pushed NAME, pushes made
# inside a function the array is passed to, and the `!=` / `let mut` spelling
# of that -- now ANSWER on this lane: the checker types the binding (an empty
# literal carries a real element slot since #2447), the per-module carrier
# records the `==` site's operand type, and the untyped-empty arm dispatches
# through it where the declared-field allow-list admits the element. Each
# fixture asserts a content answer against a distinct allocation (identity
# would say false) and against a same-length different-content array (a
# length-only answer would say true), so a wrong answer traps and a regression
# to the old trap fails the same way.
echo "[compiler-gate] untyped-empty equality answers through the typed channel (#2391)"
eqtypeddir="_build/_gate_eq_untyped_empty_typed"
rm -rf "$eqtypeddir"; mkdir -p "$eqtypeddir"
# `structural_eq_generic_enum_*_typed.vibe` joins (#2467): a source-owned
# generic enum compared directly now answers through a comparator specialized
# per instantiation, exact for an `Int` payload and by content for an
# aggregate one.
for eqtyped_src in fixtures/structural_eq_untyped_empty_*_typed.vibe fixtures/structural_eq_generic_enum_*_typed.vibe; do
  eqtyped_name="$(basename "${eqtyped_src%.vibe}")"
  eqtyped_wasm="$eqtypeddir/$eqtyped_name.wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$eqtyped_src" "$eqtyped_wasm" _start >/dev/null 2>&1 || true
  if [ ! -s "$eqtyped_wasm" ]; then
    echo "[compiler-gate] FAIL: $eqtyped_src did not compile" >&2
    cat "$eqtyped_wasm.diag" >&2 2>/dev/null
    exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$eqtyped_wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $eqtyped_src trapped or answered wrongly; expected a content answer through the typed channel (#2391)" >&2
    exit 1
  fi
done
rm -rf "$eqtypeddir"
echo "[compiler-gate] untyped-empty equality answers through the typed channel ok"

# #2447: one mutable binding used at two element types must be REJECTED at
# check time ON THIS LANE. The single-source lane's builtin `Array::push` arm
# already rejected these; the import-resolving lane resolved `Array::push`
# through the registry signature, where the empty literal's `CtArray(CtUnknown)`
# absorbed both uses -- two lanes, two answers. The empty literal now carries
# a real element slot (the #938 builder fix applied to `Array`), so the first
# use binds it and the second must fail to unify.
echo "[compiler-gate] empty-array heterogeneous use is rejected on the import lane (#2447)"
heterodir="_build/_gate_empty_array_hetero"
rm -rf "$heterodir"; mkdir -p "$heterodir"
for hetero_src in fixtures/empty_array_hetero_*_reject.vibe; do
  hetero_name="$(basename "${hetero_src%.vibe}")"
  hetero_wasm="$heterodir/$hetero_name.wasm"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$hetero_src" "$hetero_wasm" _start >/dev/null 2>&1 || true
  if [ -s "$hetero_wasm" ]; then
    echo "[compiler-gate] FAIL: $hetero_src compiled; expected a check rejection" >&2
    exit 1
  fi
  # Not any failure: the rejection must be the ELEMENT-TYPE mismatch, so a
  # fixture broken some other way (syntax, missing name) cannot green this.
  if ! grep -q "type mismatch" "$hetero_wasm.diag" 2>/dev/null; then
    echo "[compiler-gate] FAIL: $hetero_src was rejected without the expected type mismatch diagnostic" >&2
    cat "$hetero_wasm.diag" >&2 2>/dev/null
    exit 1
  fi
done
rm -rf "$heterodir"
echo "[compiler-gate] empty-array heterogeneous use rejected ok"

# A non-regular recursive generic can transform its own argument on every
# recursive edge (`Loop[T]` -> `Loop[Array[T]]`). Comparator generation must
# terminate and retain the fail-closed boundary instead of exhausting compiler
# memory while growing an infinite specialization worklist.
echo "[compiler-gate] non-regular generic equality specialization is bounded"
nonregular_dir="_build/_gate_eq_nonregular_generic"
rm -rf "$nonregular_dir"; mkdir -p "$nonregular_dir"
nonregular_wasm="$nonregular_dir/out.wasm"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  fixtures/structural_eq_nonregular_generic_trap.vibe "$nonregular_wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$nonregular_wasm" ]; then
  echo "[compiler-gate] FAIL: non-regular generic equality did not compile" >&2
  cat "$nonregular_wasm.diag" >&2 2>/dev/null
  exit 1
fi
if VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$nonregular_wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: non-regular generic equality returned normally; expected fail-closed trap" >&2
  exit 1
fi
rm -rf "$nonregular_dir"
echo "[compiler-gate] non-regular generic equality specialization is bounded ok"

# #2157: the other half of the same contract. The four fixtures that used to
# live above pinned `let` / `let mut` x `==` / `!=` as traps; those spellings
# answer now, and a lane that only checks the residual would pass just as well
# if the fix were reverted. So assert the ANSWERS here too, in the same lane
# that owns the fail-closed side.
echo "[compiler-gate] untyped-empty equality answers after a push (#2157)"
eqansdir="_build/_gate_eq_untyped_empty_answers"
rm -rf "$eqansdir"; mkdir -p "$eqansdir"
cat > "$eqansdir/a.vibe" <<'EOF'
export fn _start() -> Int {
  let left = []
  let right = []
  Array::push(left, 1)
  Array::push(right, 2)
  // Same length, different elements: only a CONTENT comparison says false.
  // A length-only answer would say true and a trap would not get here.
  assert(left != right)
  Array::push(right, 3)
  assert(left != right)
  let mut ml = []
  let mut mr = []
  Array::push(ml, "a")
  Array::push(mr, "a")
  assert(ml == mr)
  Array::push(mr, "b")
  assert(ml != mr)
  0
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eqansdir/a.vibe" "$eqansdir/a.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$eqansdir/a.wasm" ]; then
  echo "[compiler-gate] FAIL: untyped-empty answer probe did not compile" >&2
  cat "$eqansdir/a.wasm.diag" >&2 2>/dev/null
  exit 1
fi
if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
    --invoke _start "$eqansdir/a.wasm" >/dev/null 2>&1; then
  echo "[compiler-gate] FAIL: untyped-empty equality did not answer by content (#2157)" >&2
  exit 1
fi
rm -rf "$eqansdir"
echo "[compiler-gate] untyped-empty equality answers after a push ok"

# 15b-2. `~` (bit-not), #2344 slice C. The lowering is `x ^ -1` with a
#        LANE-DEPENDENT constant (tagged -2 under RC, raw -1 untagged), and `~`
#        also has to be registered in every "is this expression an Int?"
#        classifier -- `expr_is_intish` / `gc_expr_is_intish` for `==`,
#        `ts_known_int` for `__to_string`, `cc_arg_is_scalarish` for an explicit
#        `eq(a, b)`. Each classifier is separate, so each one missing `~`
#        produced a different silent-wrong answer on the same values.
#        `fixtures/bitwise_test.vibe` joins it here for the same reason it was
#        found: it was referenced by no gate either, and carried a "~ is not
#        supported, use x ^ mask" test that had been false since slice C landed.
#        This step was LINEAR-ONLY while #2407 stood (the gc `eq` arm had no
#        scalar guard and trapped on any distinct large-Int pair, with no `~`
#        involved). That is fixed, so the `eq` assertions now run on both lanes,
#        which is what #2407 asked for.
echo '[compiler-gate] 15b-2/15 bit-not ~ (#2344)'
run_test_block_fixtures "bit-not" fixtures/bit_not_test.vibe fixtures/bitwise_test.vibe fixtures/bit_not_trait_witness_test.vibe
run_test_block_fixtures_gc "bit-not (gc)" fixtures/bit_not_test.vibe fixtures/bitwise_test.vibe
echo '[compiler-gate] bit-not ~ ok'

# 15b-3. gc-lane scalar parity (#2404 / #2405 / #2407). One fixture, run on
#        BOTH lanes: every assertion in it held on linear and failed on gc --
#        a labeled parameter reported an internal compiler error, a large Int
#        rendered as the empty string, and `eq` on two distinct large Ints
#        trapped. A single-lane run cannot see any of them.
echo '[compiler-gate] 15b-3/15 gc-lane scalar parity (#2404/#2405/#2407)'
run_test_block_fixtures "gc-lane scalar parity (linear, bump)" fixtures/gc_lane_scalar_parity_test.vibe
run_test_block_fixtures_gc "gc-lane scalar parity (gc)" fixtures/gc_lane_scalar_parity_test.vibe
run_test_block_fixtures_rc "gc-lane scalar parity (linear, RC)" fixtures/gc_lane_scalar_parity_test.vibe
echo '[compiler-gate] gc-lane scalar parity ok'

# #3074 / #3075 (and #3065 / #3066 before them): renders that printed a
# representation instead of the value -- a generic enum's payload through its
# erased formal (`GA(1)`), a `Char` as its code point, a `Unit` as `0`. The
# interpolation rewrite and the derived renderers are shared by every backend,
# so each fixture runs on all three lanes.
echo '[compiler-gate] 15b-3a/15 render by content: generic enum/struct, Char, Unit, tuple parameter, generic call, scalar payload (#3065/#3066/#3074/#3075/#3082-#3085/#3087)'
for render_fx in fixtures/generic_enum_derive_show_render_test.vibe fixtures/char_unit_leaf_render_test.vibe \
    fixtures/exception_kinded_binder_render_test.vibe fixtures/interp_nested_literal_render_test.vibe \
    fixtures/generic_struct_derive_show_nested_test.vibe fixtures/tuple_param_render_test.vibe \
    fixtures/imported_generic_show_test.vibe fixtures/generic_call_result_render_test.vibe \
    fixtures/derive_show_scalar_payload_test.vibe fixtures/generic_field_projection_render_test.vibe; do
  run_test_block_fixtures "render by content (linear, bump)" "$render_fx"
  run_test_block_fixtures_gc "render by content (gc)" "$render_fx"
  run_test_block_fixtures_rc "render by content (linear, RC)" "$render_fx"
done
echo '[compiler-gate] render by content ok'

# 15b-3b. #2442: a pure builtin bound to a name and called through the binding
#         must answer exactly as the direct call does. The lowering is an
#         eta-expanded lambda emitted independently by each backend, so the
#         three lanes are three separate implementations of the same contract.
echo '[compiler-gate] 15b-3b/15 builtin value form (#2442)'
# #2392: the value-sharing and aliasing rules stable-surface.md §2.2a freezes.
# All three lanes, because "the lanes agree" is one of the claims -- an
# aggregate is a handle on every backend, not a property of the one the reader
# built with.
run_test_block_fixtures "value sharing (linear, bump)" fixtures/value_sharing_test.vibe
run_test_block_fixtures_gc "value sharing (gc)" fixtures/value_sharing_test.vibe
run_test_block_fixtures_rc "value sharing (linear, RC)" fixtures/value_sharing_test.vibe
run_test_block_fixtures "builtin value form (linear, bump)" fixtures/builtin_value_form_test.vibe
run_test_block_fixtures_gc "builtin value form (gc)" fixtures/builtin_value_form_test.vibe
run_test_block_fixtures_rc "builtin value form (linear, RC)" fixtures/builtin_value_form_test.vibe
# #2442: the two MODULE-LEVEL shadows of a bare builtin name, each in its own
# file because the name shadows the builtin module-wide. They pin codegen's
# resolution ORDER -- `locals -> consts -> constructors -> value form -> func
# table` -- which the value-form arm had to move down into once bare names
# gained a value form. Measured against a stage2 with the arm back where it
# was, both fail with `lambda plan over-count: planned through 0, walk stopped
# at 2`.
run_test_block_fixtures "builtin value form const shadow (linear, bump)" fixtures/builtin_value_form_shadow_const_test.vibe
run_test_block_fixtures_gc "builtin value form const shadow (gc)" fixtures/builtin_value_form_shadow_const_test.vibe
run_test_block_fixtures_rc "builtin value form const shadow (linear, RC)" fixtures/builtin_value_form_shadow_const_test.vibe
run_test_block_fixtures "builtin value form ctor shadow (linear, bump)" fixtures/builtin_value_form_shadow_ctor_test.vibe
run_test_block_fixtures_gc "builtin value form ctor shadow (gc)" fixtures/builtin_value_form_shadow_ctor_test.vibe
run_test_block_fixtures_rc "builtin value form ctor shadow (linear, RC)" fixtures/builtin_value_form_shadow_ctor_test.vibe
echo '[compiler-gate] builtin value form ok'

# 15b-3c. #2630: the three length views of a byte string (`unicode_length` /
#         `utf16_length` / `utf8_length`) are served by a callsite lowering on
#         each lane -- a shared synthesis, but two `ce` dispatchers -- and were
#         declared and published for a long time with no lowering at all. The
#         fixture also pins that a view is an Int at every consumer (`==`,
#         `+`, interpolation), which is a per-lane classifier question.
echo '[compiler-gate] 15b-3c/15 string length views (#2630)'
run_test_block_fixtures "string length views (linear, bump)" fixtures/string_length_intrinsics_test.vibe
run_test_block_fixtures_gc "string length views (gc)" fixtures/string_length_intrinsics_test.vibe
run_test_block_fixtures_rc "string length views (linear, RC)" fixtures/string_length_intrinsics_test.vibe
echo '[compiler-gate] string length views ok'

# 15b-3c2. #3069: trait impls and bounded generics on the flat single-source
#          linear lane, with the FS lanes answering the same fixture.
echo '[compiler-gate] 15b-3c2/15 trait dictionaries on the flat single-source lane (#3069)'
run_test_block_fixtures "trait dict (linear, bump)" fixtures/trait_dict_flat_lane_test.vibe
run_test_block_fixtures_gc "trait dict (gc)" fixtures/trait_dict_flat_lane_test.vibe
run_test_block_fixtures_flat "trait dict (flat single-source)" fixtures/trait_dict_flat_lane_test.vibe
echo '[compiler-gate] trait dictionaries on the flat lane ok'

# 15b-3c2'. #3098: the same order on the linked-library lane. `vibe build
#           --debug` compiles each linked dependency alone through
#           `compile_file_wasi_library`, which desugared trait dictionaries
#           BEFORE the check: a library with an impl and a `[T: Tr]` generic
#           was refused (``no impl `Measured` for `Self` ``, `__dict_` prefix,
#           `EqDict::equals` at arity 3). Build it, then run the entry with the
#           library preloaded: 70 + 100 + 1 + 0 + 1.
echo '[compiler-gate] 15b-3c2'"'"' trait dictionaries in a linked debug library (#3098)'
lldir="_build/_gate_linked_library_trait_dict"
rm -rf "$lldir"; mkdir -p "$lldir"
ll_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  build --debug fixtures/linked_library_trait_dict/main.vibe -o "$lldir/main.wasm" --entry _start 2>&1 || true)"
if [ ! -s "$lldir/main.wasm" ] || [ ! -s "$lldir/main.debug/lib.wasm" ]; then
  echo "[compiler-gate] FAIL: build --debug of a trait library produced no main/lib wasm (#3098)" >&2
  printf '%s\n' "$ll_out" >&2; exit 1
fi
if bash scripts/wasmtime_run.sh --version >/dev/null 2>&1; then
  ll_res="$(run_bounded 60 bash scripts/wasmtime_run.sh run --preload lib="$lldir/main.debug/lib.wasm" \
    --invoke _start "$lldir/main.wasm" 2>&1 | tr -dc '0-9-' || true)"
  if [ "$ll_res" != "172" ]; then
    echo "[compiler-gate] FAIL: linked debug trait library answered '$ll_res' (expected 172) (#3098)" >&2; exit 1
  fi
  echo '[compiler-gate] linked debug trait library ok (172)'
else
  echo '[compiler-gate] linked debug trait library compiled; SKIP run: wasmtime not available'
fi
# #3105: the SAME program as an ordinary (non-debug) build, where lib.vibe is
# merged and its private `Pt` renamed to `Pt_dep_<path>`. Its impl method was
# renamed `Pt::measure_dep_<path>`, which no `<Type>::<method>` lookup asks
# for, so the build failed: "add a body for `measure` to `impl Measured for
# Pt_dep_...`". The shapes beyond this one (enum, several methods, UFCS) are
# pinned by fixtures/private_type_impl_import_test.vibe.
# #3111: both lanes. VIBE_RC=1 is the production lane `vibe build` takes by
# default; VIBE_RC=0 (this gate's default, lib.sh) is the bump lane, whose
# `mvp` mode prunes with DCE BEFORE the dictionary desugar. That prune dropped
# every impl method only a dictionary reaches, and the build failed with the
# same "add a body for `measure`" even with `export struct Pt`.
for ll_rc in 1 0; do
  rm -f "$lldir/release.wasm"
  ll_rel_out="$(VIBE_RC="$ll_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    build fixtures/linked_library_trait_dict/main.vibe -o "$lldir/release.wasm" --entry _start 2>&1 || true)"
  if [ ! -s "$lldir/release.wasm" ]; then
    echo "[compiler-gate] FAIL: VIBE_RC=$ll_rc non-debug build of a library with a trait impl produced no wasm (#3105, #3111)" >&2
    printf '%s\n' "$ll_rel_out" >&2; exit 1
  fi
  if bash scripts/wasmtime_run.sh --version >/dev/null 2>&1; then
    ll_rel_res="$(run_bounded 60 bash scripts/wasmtime_run.sh run --invoke _start "$lldir/release.wasm" 2>&1 | tr -dc '0-9-' || true)"
    if [ "$ll_rel_res" != "172" ]; then
      echo "[compiler-gate] FAIL: VIBE_RC=$ll_rc non-debug trait library build answered '$ll_rel_res' (expected 172) (#3105, #3111)" >&2; exit 1
    fi
    echo "[compiler-gate] VIBE_RC=$ll_rc non-debug trait library build ok (172)"
  else
    echo "[compiler-gate] VIBE_RC=$ll_rc non-debug trait library compiled; SKIP run: wasmtime not available"
  fi
done
# #3111: a single-file executable whose impl methods -- on a struct, on `Int`
# and on an applied `Array[Int]` target -- are reached only through trait
# dictionaries: 70 + 100 + 600 + 2.
for ll_rc in 1 0; do
  rm -f "$lldir/early_dce.wasm"
  ll_ed_out="$(VIBE_RC="$ll_rc" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    build fixtures/trait_dict_early_dce_build.vibe -o "$lldir/early_dce.wasm" --entry _start 2>&1 || true)"
  if [ ! -s "$lldir/early_dce.wasm" ]; then
    echo "[compiler-gate] FAIL: VIBE_RC=$ll_rc build of impl methods reached only through dictionaries produced no wasm (#3111)" >&2
    printf '%s\n' "$ll_ed_out" >&2; exit 1
  fi
  if bash scripts/wasmtime_run.sh --version >/dev/null 2>&1; then
    ll_ed_res="$(run_bounded 60 bash scripts/wasmtime_run.sh run --invoke _start "$lldir/early_dce.wasm" 2>&1 | tr -dc '0-9-' || true)"
    if [ "$ll_ed_res" != "772" ]; then
      echo "[compiler-gate] FAIL: VIBE_RC=$ll_rc dictionary-only impl build answered '$ll_ed_res' (expected 772) (#3111)" >&2; exit 1
    fi
    echo "[compiler-gate] VIBE_RC=$ll_rc dictionary-only impl build ok (772)"
  else
    echo "[compiler-gate] VIBE_RC=$ll_rc dictionary-only impl build compiled; SKIP run: wasmtime not available"
  fi
done
rm -rf "$lldir"

# 15b-3c'. #3067: `String::substring` clamps its indices on every lane. The gc
#          lane used its own body with no bounds checks and read the bytes
#          around the string (`("beta", 0, 5)` answered `beta]`).
echo '[compiler-gate] 15b-3c'"'"' String::substring clamps on every lane (#3067)'
run_test_block_fixtures "substring clamp (linear, bump)" fixtures/string_substring_clamp_test.vibe
run_test_block_fixtures_gc "substring clamp (gc)" fixtures/string_substring_clamp_test.vibe
run_test_block_fixtures_rc "substring clamp (linear, RC)" fixtures/string_substring_clamp_test.vibe
echo '[compiler-gate] substring clamp ok'

# 15b-3c''. #3078: `Array::slice` clamps its bounds on every lane. The gc body
#           copied from `start` with no bounds checks, so
#           `Array::slice([3, 1, 2], -1, 2)` read index -1 (`[, 3, 1]`). The
#           linear lanes already run this file through the unit runner.
echo '[compiler-gate] 15b-3c'"''"' Array::slice clamps on the gc lane (#3078)'
run_test_block_fixtures_gc "slice clamp (gc)" fixtures/slice_clamp_test.vibe
echo '[compiler-gate] slice clamp (gc) ok'

# 15b-3c'''. #3080: the index-form slice `xs[a:b]` renders by content on every
#            lane, like `Array::slice(xs, a, b)`. It printed a heap address on
#            both lanes; its refusal side is the slice_field ur_refused row.
echo '[compiler-gate] 15b-3c'"'''"' index-form slice renders by content (#3080)'
run_test_block_fixtures "slice render (linear, bump)" fixtures/interp_slice_render_test.vibe
run_test_block_fixtures_gc "slice render (gc)" fixtures/interp_slice_render_test.vibe
run_test_block_fixtures_rc "slice render (linear, RC)" fixtures/interp_slice_render_test.vibe
echo '[compiler-gate] slice render ok'

# 15b-3d. #2652: `Double::to_string` is shortest-round-trip and `Double::parse`
#         is correctly rounded. Both are ONE runtime prelude in vibe source
#         (codegen/common_base/double_runtime.vibe) appended to the program by
#         each lane's own hook and compiled by each lane's own codegen without
#         checker offsets, so three lanes are three separate compilations of
#         the same contract. The fixture's 230 expected strings are
#         JavaScript's, taken for exact bit patterns, and the parse table
#         expects `Number(s)`'s bits.
echo '[compiler-gate] 15b-3d/15 Double to_string / parse round trip (#2652)'
run_test_block_fixtures "double to_string (linear, bump)" fixtures/double_to_string_test.vibe
run_test_block_fixtures_gc "double to_string (gc)" fixtures/double_to_string_test.vibe
run_test_block_fixtures_rc "double to_string (linear, RC)" fixtures/double_to_string_test.vibe
echo '[compiler-gate] double to_string / parse ok'

# 15b-4. A Double inside an aggregate reached through a NAME (#2431). Three
#        lanes for the same reason as 15b-3, and here every lane was wrong in a
#        DIFFERENT place: `let x = (0.0, 1); let y = (-0.0, 1); x == y` was
#        false on all three, while `let x = (1.5, 1); let y = (1.5, 1); x == y`
#        was false ONLY under RC -- a Double field is a boxed value there, so
#        the generic `eq` compared two distinct boxes and two structurally
#        equal tuples came out unequal on the production default lane. A
#        single-lane run sees at most one of those.
echo '[compiler-gate] 15b-4/15 Double inside an aggregate through a name (#2431)'
run_test_block_fixtures "aggregate Double equality (linear, bump)" fixtures/tuple_double_eq_test.vibe
run_test_block_fixtures_gc "aggregate Double equality (gc)" fixtures/tuple_double_eq_test.vibe
run_test_block_fixtures_rc "aggregate Double equality (linear, RC)" fixtures/tuple_double_eq_test.vibe
echo '[compiler-gate] aggregate Double equality ok'

# #3201/#3202: a named Double field must select f64 ordering, and a Double
# compound assignment must reuse f64 arithmetic and the ordinary RC store.
echo "[compiler-gate] 133/133 Double field ordering and compound assignment (#3201/#3202)"
run_test_block_fixtures "Double field and assignment (linear, bump)" fixtures/double_field_compare_test.vibe fixtures/double_compound_assignop_test.vibe
run_test_block_fixtures_gc "Double field and assignment (gc)" fixtures/double_field_compare_test.vibe fixtures/double_compound_assignop_test.vibe
run_test_block_fixtures_rc "Double field and assignment (linear, RC)" fixtures/double_field_compare_test.vibe fixtures/double_compound_assignop_test.vibe
echo '[compiler-gate] Double field and assignment ok'

# 15b-5. #3071: a function that performs a user effect with no handler reaching
#        it keeps its raw `perform` -- a function nobody calls, or an exported
#        callee whose every call site took the suspend-lowered clone. The linear
#        lane lowers it to an unhandled-effect trap; the gc lane refused the
#        whole program (`unsupported perform (no builtin mapping)`).
echo '[compiler-gate] 15b-5/15 an uncalled user-effect perform compiles on every lane (#3071)'
run_test_block_fixtures "uncalled user-effect perform (linear, bump)" fixtures/uncalled_user_effect_perform_test.vibe
run_test_block_fixtures_gc "uncalled user-effect perform (gc)" fixtures/uncalled_user_effect_perform_test.vibe
run_test_block_fixtures_rc "uncalled user-effect perform (linear, RC)" fixtures/uncalled_user_effect_perform_test.vibe
echo '[compiler-gate] uncalled user-effect perform ok'

# 15c. railway `let*` / `?` generalized to Option (#635): the parser emits a
#      type-directed sentinel that the pre-check desugar lowers by the operand's
#      head type — `Option` (Some/None) or `Result` (Ok/Err, the default). The
#      fixtures are `test "..."`-block suites; compile each through the fresh
#      stage2 and run `_start` (a failing `assert` traps, so a clean run == all
#      blocks passed). Covers Option `let*`, Result `let*` unchanged, Option `?`
#      early-return-None, Result `?` early-return-Err, and the mixed-type type
#      error (a negative file that must NOT compile).
echo "[compiler-gate] 15c/15 railway let*/? Option generalization (#635)"
run_test_block_fixtures "railway let*/?" fixtures/try_*_option_test.vibe
# Mixed Result/Option in one `let*` chain must be a type error (NO implicit
# conversion): a block returns one type, so a `Result` rest under an `Option`
# `let*` (or vice-versa) fails the checker. The file must NOT compile.
mixdir="_build/_gate_railway_mixed"
rm -rf "$mixdir"; mkdir -p "$mixdir"
cat > "$mixdir/m.vibe" <<'EOF'
enum Result[T, E] { Ok(T); Err(E) }
let opt = (n: Int) -> Option[Int] { if n > 0 { Some(n) } else { None } }
let res = (n: Int) -> Result[Int, String] { if n > 0 { Ok(n) } else { Err("x") } }
// `let* x = opt(..)` lowers the block to Option; returning a Result `rest`
// (and an `Err` ctor as the None/short-circuit value) is a type clash.
export let _start: () -> Int = () -> {
  let r = (a: Int) -> Option[Int] {
    let* x = opt(a)
    res(x)
  }
  match r(1) { Some(v) => v, None => 0 }
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$mixdir/m.vibe" "$mixdir/m.wasm" _start >/dev/null 2>&1 || true
if [ -s "$mixdir/m.wasm" ]; then
  echo "[compiler-gate] FAIL: mixed Result/Option let* chain compiled (should be a type error)" >&2
  exit 1
fi
rm -rf "$mixdir"
echo "[compiler-gate] railway let*/? Option generalization ok"

# 15d was a third byte-identical copy of the test-block-suite loop, for the
# single fixture `fixtures/derive_hash_map_key_test.vibe` (#694). That name
# matches 15b's `fixtures/derive_*_test.vibe` glob, so it runs there now and
# the standalone copy is gone (#1587); 15b's comment carries the #694 rationale.

# 16. trait type parameters / Iterator regression (#636): a method-bearing trait
#     with a type parameter (`Iterator[T] { next(Self) -> Option[T] }`) must be
#     declarable, and a `[I: Iterator]` generic must dispatch `I::next` through
#     the witness dictionary — driving a stateful, functional iterator
#     (`next(Self) -> Option[(T, Self)]`) to completion.
echo "[compiler-gate] 16/16 trait-type-parameter / Iterator regression"
itdir="_build/_gate_iter"
rm -rf "$itdir"; mkdir -p "$itdir"
cat > "$itdir/iter.vibe" <<'EOF'
trait Iter[T] { next(Self) -> Option[(T, Self)] }
trait Iterable[T] { iter(Self) -> Range }
struct Range { lo: Int; hi: Int }
struct Span { from: Int; to: Int }
impl Iterable for Span { iter(self) -> Range { Range::{ lo: self.from, hi: self.to } } }
impl Iter for Range {
  next(self) -> Option[(Int, Range)] {
    if self.lo < self.hi {
      Some((self.lo, Range::{ lo: self.lo + 1, hi: self.hi }))
    } else {
      None
    }
  }
}
let iter_sum = [I: Iter](it: I) -> Int {
  let mut acc = 0
  let mut cur = it
  let mut go = true
  while go {
    match I::next(cur) {
      Some(pair) => { let (v, rest) = pair; acc = acc + v; cur = rest },
      None => { go = false }
    }
  }
  acc
}
export let _start: () -> Int = () -> {
  // `for x in <iterator>` desugars to a next-driven loop (10);
  // `for x in <iterable>` calls iter() then drives next (10);
  // iter_sum dispatches I::next through the witness dict (10).
  let mut acc = 0
  for x in Range::{ lo: 1, hi: 5 } { acc = acc + x }
  for y in Span::{ from: 1, to: 5 } { acc = acc + y }
  acc + iter_sum(Range::{ lo: 1, hi: 5 })
}
EOF
# Expected: (1+2+3+4) + (1+2+3+4) + (1+2+3+4) = 30
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$itdir/iter.vibe" "$itdir/iter.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$itdir/iter.wasm" ]; then
  echo "[compiler-gate] FAIL: Iterator trait program did not compile" >&2
  cat "$itdir/iter.wasm.diag" >&2 2>/dev/null; exit 1
fi
it_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$itdir/iter.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$it_out" != "30" ]; then
  echo "[compiler-gate] FAIL: Iterator dispatch mismatch (got '$it_out', want 30 -> #636 regressed)" >&2
  exit 1
fi
rm -rf "$itdir"
echo "[compiler-gate] trait-type-parameter / Iterator regression ok"

# 17. lazy iterator combinators regression (#636): a lazy `Stream` (a struct
#     holding a `pull` closure) with `impl Iter for Stream` supports lazy
#     `map`/`filter` and eager `fold`/`sum`/`count` consumers (driven by the
#     `for` desugar) — the trait-based replacement for prelude/lazy_iter.vibe's
#     `() -> Option[T]` function iterator. All library code, no compiler support
#     beyond the trait machinery.
echo "[compiler-gate] 17/17 lazy iterator combinators regression"
lcdir="_build/_gate_lazyiter"
rm -rf "$lcdir"; mkdir -p "$lcdir"
cat > "$lcdir/lc.vibe" <<'EOF'
trait Iter[T] { next(Self) -> Option[(T, Self)] }
struct Stream { pull: (Int) -> Option[(Int, Int)]; state: Int }
impl Iter for Stream {
  next(self) -> Option[(Int, Stream)] {
    match (self.pull)(self.state) {
      Some(p) => { let (v, ns) = p; Some((v, Stream::{ pull: self.pull, state: ns })) },
      None => None
    }
  }
}
let range = (lo: Int, hi: Int) -> Stream {
  Stream::{ pull: (s) -> { if s < hi { Some((s, s + 1)) } else { None } }, state: lo }
}
let smap = (s: Stream, f: (Int) -> Int) -> Stream {
  Stream::{ pull: (st) -> { match (s.pull)(st) { Some(p) => { let (v, ns) = p; Some((f(v), ns)) }, None => None } }, state: s.state }
}
let sfilter = (s: Stream, pred: (Int) -> Bool) -> Stream {
  Stream::{ pull: (st) -> {
    let mut cur = st
    let mut result = None
    let mut go = true
    while go {
      match (s.pull)(cur) {
        Some(p) => { let (v, ns) = p; if pred(v) { result = Some((v, ns)); go = false } else { cur = ns } },
        None => { go = false }
      }
    }
    result
  }, state: s.state }
}
let sfold = (s: Stream, init: Int, f: (Int, Int) -> Int) -> Int {
  let mut acc = init
  for x in s { acc = f(acc, x) }
  acc
}
let ssum = (s: Stream) -> Int { sfold(s, 0, (a, b) -> { a + b }) }
let scount = (s: Stream) -> Int { sfold(s, 0, (a, _) -> { a + 1 }) }
let is_even = (x: Int) -> Bool { x - (x / 2) * 2 == 0 }
export let _start: () -> Int = () -> {
  ssum(smap(range(1, 5), (x) -> { x * 2 }))   // 2+4+6+8 = 20
  + ssum(sfilter(range(1, 10), is_even))       // 2+4+6+8 = 20
  + scount(range(0, 7))                        // 7
}
EOF
# Expected: 20 + 20 + 7 = 47
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$lcdir/lc.vibe" "$lcdir/lc.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$lcdir/lc.wasm" ]; then
  echo "[compiler-gate] FAIL: lazy combinators program did not compile" >&2
  cat "$lcdir/lc.wasm.diag" >&2 2>/dev/null; exit 1
fi
lc_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$lcdir/lc.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$lc_out" != "47" ]; then
  echo "[compiler-gate] FAIL: lazy combinators mismatch (got '$lc_out', want 47 -> #636 regressed)" >&2
  exit 1
fi
rm -rf "$lcdir"
echo "[compiler-gate] lazy iterator combinators regression ok"

# 18. cross-import trait-iterator regression (#636): the iterator type + its
#     `impl ::next` + a `for x in <iter>` driver live in an IMPORTED module
#     (the prelude shape — lazy_iter.vibe is always imported). A qualified impl
#     method `LazyIter::next` is a non-exported `let`, so the import namespacer
#     used to path-suffix it (`LazyIter::next$path`), orphaning it from the
#     `LazyIter` type and making the `for` desugar's `Type::next` lookup miss —
#     the loop silently fell back to array iteration and trapped. Qualified
#     `Type::method` names must follow the *type's* namespacing, not get an
#     independent value suffix. Guards import_alias_rewrite + the generic-struct
#     `for`-iterator desugar across the import boundary.
echo "[compiler-gate] 18/18 cross-import trait-iterator regression"
xidir="_build/_gate_import_iter"
rm -rf "$xidir"; mkdir -p "$xidir"
cat > "$xidir/li.vibe" <<'EOF'
export trait Iterator[T] { next(Self) -> Option[(T, Self)] }
export struct LazyIter[T] { pull: (Int) -> Option[(T, Int)]; state: Int }
impl Iterator for LazyIter {
  next(self) -> Option[(T, LazyIter)] {
    match (self.pull)(self.state) {
      Some(p) => { let (v, ns) = p; Some((v, LazyIter::{ pull: self.pull, state: ns })) },
      None => None
    }
  }
}
export let lazy_iter_arr = [T](xs: Array[T]) -> LazyIter[T] {
  LazyIter::{ pull: (i) -> Option[(T, Int)] {
    if i < Array::length(xs) { Some((Array::get(xs, i), i + 1)) } else { None }
  }, state: 0 }
}
export let lazy_iter_count = [T](src: LazyIter[T]) -> Int {
  let mut n = 0
  for x in src { n = n + 1 }
  n
}
EOF
cat > "$xidir/main.vibe" <<'EOF'
import ./li.vibe { lazy_iter_arr, lazy_iter_count }
export let _start: () -> Int = () -> { lazy_iter_count(lazy_iter_arr([10, 20, 30, 40, 50])) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$xidir/main.vibe" "$xidir/main.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$xidir/main.wasm" ]; then
  echo "[compiler-gate] FAIL: cross-import trait-iterator program did not compile" >&2
  exit 1
fi
xi_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$xidir/main.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$xi_out" != "5" ]; then
  echo "[compiler-gate] FAIL: cross-import trait-iterator mismatch (got '$xi_out', want 5 -> import method namespacing regressed)" >&2
  exit 1
fi
rm -rf "$xidir"
echo "[compiler-gate] cross-import trait-iterator regression ok"

# 19. async for-loop unification regression (#636 / #1350): `for x in s` is ONE
#     type-directed desugar covering the sync and async shapes. #1350 removed
#     the `for await` spelling and its `__await_iter` marker; the loop shape is
#     picked from the iterand's TYPE alone:
#       - a struct `C` with `C::next -> Future[Option[..]]` (an AsyncIterator /
#         `Stream[T]`) drives an `await`-wrapped next loop (`await` unwraps the
#         ready future on the synchronous backend), and
#       - any other iterable (a pull closure `() -> Option[T]`, the pre-existing
#         M2c-3 model) drives the pull-to-`None` loop.
#     Guards that the async shapes still classify with no syntax marker and with
#     no declared trait (the always-run desugar pass).
echo "[compiler-gate] 19/19 async for-loop unification regression"
fadir="_build/_gate_forawait"
rm -rf "$fadir"; mkdir -p "$fadir"
cat > "$fadir/fa.vibe" <<'EOF'
trait AsyncIterator[T] { next(Self) -> Future[Option[(T, Self)]] }
struct AStream { pull: (Int) -> Option[(Int, Int)]; state: Int }
impl AsyncIterator for AStream {
  next(self) -> Future[Option[(Int, AStream)]] {
    Future::ready(match (self.pull)(self.state) {
      Some(p) => { let (v, ns) = p; Some((v, AStream::{ pull: self.pull, state: ns })) },
      None => None
    })
  }
}
let mkstream = (xs: Array[Int]) -> AStream {
  AStream::{ pull: (i) -> Option[(Int, Int)] { if i < Array::length(xs) { Some((Array::get(xs, i), i + 1)) } else { None } }, state: 0 }
}
let counter_stream = () -> (() -> Option[Int]) {
  let mut n = 0
  () -> Option[Int] { if n < 4 { n = n + 1; Some(n) } else { None } }
}
export let _start: () -> Int with Async = () -> {
  let mut t = 0
  for x in mkstream([10, 20, 30]) { t = t + x }
  for y in counter_stream() { t = t + y }
  t
}
EOF
# Expected: async iterator 10+20+30 = 60, pull closure 1+2+3+4 = 10 -> 70.
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$fadir/fa.vibe" "$fadir/fa.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$fadir/fa.wasm" ]; then
  echo "[compiler-gate] FAIL: async for-loop program did not compile" >&2
  cat "$fadir/fa.wasm.diag" >&2 2>/dev/null; exit 1
fi
fa_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$fadir/fa.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$fa_out" != "70" ]; then
  echo "[compiler-gate] FAIL: async for-loop unification mismatch (got '$fa_out', want 70 -> #636/#1350 regressed)" >&2
  exit 1
fi
rm -rf "$fadir"
echo "[compiler-gate] async for-loop unification regression ok"

# 20. cross-import trait-iterator ELEMENT-TYPE inference: `for x in <C[T]>` binds
#     `x` to the iterator's element type `T`, recovered from the iterable's type
#     `C[T]` (the `next(Self) -> Option[(T, Self)]` convention puts the element
#     first) — even though the `impl Iterator for C` lives in the imported module
#     and is NOT in this file's import env. Two assertions:
#       (a) POSITIVE: a `LazyIter[Int]` loop body uses `x` directly in element
#           arithmetic (`total + x`) and runs to the right sum.
#       (b) NEGATIVE: a `LazyIter[String]` loop with an `Int` accumulator
#           (`total + x`, total : Int, x : String) MUST be rejected by the
#           checker — proving the element is typed `String`, not `CtUnknown`
#           (which silently accepted any use and dropped element-type safety).
echo "[compiler-gate] 20/20 cross-import trait-iterator element-type regression"
eidir="_build/_gate_import_iter_elem"
rm -rf "$eidir"; mkdir -p "$eidir"
cat > "$eidir/li.vibe" <<'EOF'
export trait Iterator[T] { next(Self) -> Option[(T, Self)] }
export struct LazyIter[T] { pull: (Int) -> Option[(T, Int)]; state: Int }
impl Iterator for LazyIter {
  next(self) -> Option[(T, LazyIter)] {
    match (self.pull)(self.state) {
      Some(p) => { let (v, ns) = p; Some((v, LazyIter::{ pull: self.pull, state: ns })) },
      None => None
    }
  }
}
export let lazy_iter_arr = [T](xs: Array[T]) -> LazyIter[T] {
  LazyIter::{ pull: (i) -> Option[(T, Int)] {
    if i < Array::length(xs) { Some((Array::get(xs, i), i + 1)) } else { None }
  }, state: 0 }
}
EOF
# (a) positive: direct element arithmetic compiles + runs (10+20+30+40 = 100).
cat > "$eidir/pos.vibe" <<'EOF'
import ./li.vibe { LazyIter, lazy_iter_arr }
let sum_direct = (src: LazyIter[Int]) -> Int {
  let mut total = 0
  for x in src { total = total + x }
  total
}
export let _start: () -> Int = () -> { sum_direct(lazy_iter_arr([10, 20, 30, 40])) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eidir/pos.vibe" "$eidir/pos.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$eidir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: element-type positive program did not compile" >&2
  cat "$eidir/pos.wasm.diag" >&2 2>/dev/null; exit 1
fi
ei_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$eidir/pos.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$ei_out" != "100" ]; then
  echo "[compiler-gate] FAIL: element-type positive mismatch (got '$ei_out', want 100)" >&2
  exit 1
fi
# (b) negative: Int accumulator + String element must be a type error.
cat > "$eidir/neg.vibe" <<'EOF'
import ./li.vibe { LazyIter, lazy_iter_arr }
let bad = (src: LazyIter[String]) -> Int {
  let mut total = 0
  for x in src { total = total + x }
  total
}
export let _start: () -> Int = () -> { bad(lazy_iter_arr(["a", "b"])) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$eidir/neg.vibe" "$eidir/neg.wasm" _start >/dev/null 2>&1 || true
if [ -s "$eidir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: element-type negative program compiled (element typed CtUnknown, not String -> element-type safety regressed)" >&2
  exit 1
fi
if ! grep -q "type mismatch in '+'" "$eidir/neg.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: element-type negative rejected for the wrong reason" >&2
  cat "$eidir/neg.wasm.diag" >&2 2>/dev/null; exit 1
fi
rm -rf "$eidir"
echo "[compiler-gate] cross-import trait-iterator element-type regression ok"

# 21. prelude iterator combinator suites: compile + run the real prelude test
#     files through the fresh stage2 and assert every `test "..."` block passes
#     (each `assert` traps on failure, so a clean `_start` run == all passed).
#     Covers the sync `lazy_iter` and async `async_iter` combinator libraries
#     (take / drop / take_while / enumerate / zip / flat_map / find / any / all,
#     and the async `for`-driven terminals) — these prelude tests are not
#     otherwise exercised by the gate.
echo "[compiler-gate] 21/21 prelude iterator combinator suites"
for suite in lib/@vibe/builtin/lazy_iter_test.vibe lib/@vibe/builtin/async_iter_test.vibe; do
  out="_build/_gate_prelude_iter_$(basename "${suite%.vibe}").wasm"
  # ADR-0069: test-block suites need the explicit `__no_entry__` sentinel for
  # the test-runner `_start` synthesis (unknown entry names are compile errors).
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$suite" "$out" __no_entry__ >/dev/null 2>&1 || true
  if [ ! -s "$out" ]; then
    echo "[compiler-gate] FAIL: $suite did not compile" >&2
    cat "$out.diag" >&2 2>/dev/null; exit 1
  fi
  if ! VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
      --invoke _start "$out" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $suite has a failing test (assert trapped)" >&2
    exit 1
  fi
  rm -f "$out" "$out.diag" "$out.funcmap"
done
echo "[compiler-gate] prelude iterator combinator suites ok"

# 22. generic trait impls — Increment A (#5): an UNbounded, method-bearing
#     `impl [T] Trait for C` makes `C[K]` satisfy a `[U: Trait]` bound for any K,
#     and the witness dict (`{ method: C::method }`) dispatches through the
#     existing dict-passing desugar — so a generic function called with an array
#     runs the array impl. Two assertions:
#       (a) POSITIVE: `impl [T] Len2 for Array` + `[U: Len2] total(x)` runs.
#       (b) SOUNDNESS: a marker-trait generic impl (`impl [T: Eq] Eq for
#           Option[T]`, Eq has no methods) must STILL be rejected — matching it
#           would let `==` (which is not structural on Option) silently misbehave.
echo "[compiler-gate] 22/22 generic trait impl (Increment A)"
gidir="_build/_gate_generic_impl"
rm -rf "$gidir"; mkdir -p "$gidir"
cat > "$gidir/pos.vibe" <<'EOF'
trait Len2[T] { len2(Self) -> Int }
struct Box[T] { v: T }
impl Len2 for Box { len2(self) -> Int { 1 } }
impl [T] Len2 for Array { len2(self) -> Int { Array::length(self) } }
let total = [U: Len2](x: U) -> Int { U::len2(x) }
export let _start: () -> Int = () -> { total([10, 20, 30, 40]) + total(Box::{ v: 99 }) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gidir/pos.vibe" "$gidir/pos.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$gidir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: generic-impl positive program did not compile" >&2
  cat "$gidir/pos.wasm.diag" >&2 2>/dev/null; exit 1
fi
gi_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$gidir/pos.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$gi_out" != "5" ]; then
  echo "[compiler-gate] FAIL: generic-impl positive mismatch (got '$gi_out', want 5)" >&2
  exit 1
fi
# Soundness: a marker-trait generic impl must NOT satisfy the bound.
cat > "$gidir/neg.vibe" <<'EOF'
trait Marky[T]
impl [T] Marky for Array
let needs = [U: Marky](x: U) -> Int { 1 }
export let _start: () -> Int = () -> { needs([1, 2, 3]) }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gidir/neg.vibe" "$gidir/neg.wasm" _start >/dev/null 2>&1 || true
if [ -s "$gidir/neg.wasm" ]; then
  echo "[compiler-gate] FAIL: marker-trait generic impl was accepted (unsound — should be rejected)" >&2
  exit 1
fi
rm -rf "$gidir"
echo "[compiler-gate] generic trait impl (Increment A) ok"

# 23. generic trait impls — Increment B (#5): a BOUNDED generic impl
#     `impl [T: Bound] Trait for C` whose body dispatches `T`'s methods on the
#     elements. The witness for `C[K]` is a nested dictionary-of-dictionaries:
#     `{ method: (w) -> C::method(<K's Bound dict>, w) }`. Assertions:
#       (a) `impl [T: Show2] Show2 for Array` summing `T::show2` over elements
#           runs for `Array[Box]` (→60) and nests for `Array[Array[Box]]` (→6).
#       (b) SOUNDNESS: an element type with no impl must NOT silently dispatch —
#           the witness refuses to build, so the program fails to produce a
#           runnable module (never returns a wrong number).
echo "[compiler-gate] 23/23 generic trait impl (Increment B, dict-of-dict)"
gjdir="_build/_gate_generic_impl_b"
rm -rf "$gjdir"; mkdir -p "$gjdir"
gj_prelude='trait Show2[T] { show2(Self) -> Int }
struct Box[T] { v: T }
impl Show2 for Box { show2(self) -> Int { self.v } }
impl [T: Show2] Show2 for Array { show2(self) -> Int {
  let mut s = 0
  for x in self { s = s + T::show2(x) }
  s
} }
let use_it = [U: Show2](x: U) -> Int { U::show2(x) }'
{ printf '%s\n' "$gj_prelude"
  printf 'export let _start: () -> Int = () -> { use_it([Box::{ v: 10 }, Box::{ v: 20 }, Box::{ v: 30 }]) + use_it([[Box::{ v: 1 }, Box::{ v: 2 }], [Box::{ v: 3 }]]) }\n'
} > "$gjdir/pos.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gjdir/pos.vibe" "$gjdir/pos.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$gjdir/pos.wasm" ]; then
  echo "[compiler-gate] FAIL: dict-of-dict positive program did not compile" >&2
  cat "$gjdir/pos.wasm.diag" >&2 2>/dev/null; exit 1
fi
gj_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$gjdir/pos.wasm" 2>/dev/null | tr -dc '0-9-')"
if [ "$gj_out" != "66" ]; then
  echo "[compiler-gate] FAIL: dict-of-dict mismatch (got '$gj_out', want 66 = 60 + 6)" >&2
  exit 1
fi
# Soundness: an element type with no Show2 impl must not silently dispatch.
{ printf '%s\n' "$gj_prelude"
  printf 'struct Qux[T] { w: T }\n'
  printf 'export let _start: () -> Int = () -> { use_it([Qux::{ w: 5 }]) }\n'
} > "$gjdir/neg.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$gjdir/neg.vibe" "$gjdir/neg.wasm" _start >/dev/null 2>&1 || true
neg_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$gjdir/neg.wasm" 2>/dev/null | tr -dc '0-9-' || true)"
if [ "$neg_out" = "5" ]; then
  echo "[compiler-gate] FAIL: element without an impl silently dispatched (miscompile — returned 5)" >&2
  exit 1
fi
rm -rf "$gjdir"
echo "[compiler-gate] generic trait impl (Increment B, dict-of-dict) ok"

# 24. async-lifted component EXECUTION on wasmtime (docs/internal/design/wasi-p3-async.md
#     §3.1). The async-lift codegen (`comp_emit_component_wasm_async*` — task.return
#     canon + async functype + async lift) is byte-tested on node, but the emitted
#     component had no EXECUTION check (the only runner was the retired
#     host `vibe.exe`). `fixtures/async_lift_run42.component.wasm` is a committed
#     async component (its `run()` returns 42) emitted by the selfhost codegen;
#     here wasmtime runs it with the async-stackful flags and we assert 42 — so
#     the async runtime path is proven to EXECUTE on wasmtime 45 (no wasmtime 46
#     needed). SKIPs cleanly when wasmtime / the async flags are unavailable.
#     Regenerate the fixture with: scripts/emit_async_lift_fixture.sh
echo "[compiler-gate] 24/24 async-lifted component execution (wasmtime)"
WT_BIN="$(command -v wasmtime || "$ROOT_DIR/scripts/wasmtime_bin.sh" 2>/dev/null || true)"
ac_fixture="$ROOT_DIR/fixtures/async_lift_run42.component.wasm"
if [ -z "${WT_BIN:-}" ] || ! "$WT_BIN" --version >/dev/null 2>&1; then
  echo "[compiler-gate] SKIP: wasmtime not available"
elif ! "$WT_BIN" -W help 2>&1 | grep -q "component-model-async-stackful"; then
  echo "[compiler-gate] SKIP: wasmtime lacks component-model-async-stackful"
elif [ ! -s "$ac_fixture" ]; then
  echo "[compiler-gate] SKIP: async-lift fixture missing (run scripts/emit_async_lift_fixture.sh)"
else
  ac_out="$(VIBE_WASMTIME_WASM_FLAGS="component-model-async=y concurrency-support=y component-model-async-stackful=y" \
    bash scripts/wasmtime_run.sh --invoke 'run()' "$ac_fixture" 2>/dev/null | tr -dc '0-9-' || true)"
  if [ "$ac_out" != "42" ]; then
    echo "[compiler-gate] FAIL: async component did not execute to 42 (got '$ac_out')" >&2; exit 1
  fi
  echo "[compiler-gate] async-lifted component execution (wasmtime $("$WT_BIN" --version | awk '{print $2}')) -> 42 ok"
fi

# 25. nested literal sub-pattern discrimination (#613 follow-up): a boolean (or
#     any) literal nested INSIDE a constructor argument that is itself a
#     constructor (`N(W(false), n)`) or a tuple (`T((false, n))`) must be
#     discriminated — the prior codegen only tag-tested nested ctors and did not
#     test tuple sub-patterns at all, silently routing `W(true)`/`(true, _)` to
#     the `false` arm (wrong result, not a trap). compile_match now emits the
#     literal test recursively at every nesting level.
echo "[compiler-gate] 25/25 nested literal sub-pattern discrimination"
nldir="_build/_gate_nestedlit"
rm -rf "$nldir"; mkdir -p "$nldir"
cat > "$nldir/nestedlit.vibe" <<'EOF'
enum W { W(Bool) }
enum N { N(W, Int) }
enum T { T((Bool, Int)) }
enum I { I(Int) }
let cn: (N) -> Int = (e) -> {
  match e {
    N(W(false), n) => n,
    N(W(true), n) => n + 1000
  }
}
let ct: (T) -> Int = (e) -> {
  match e {
    T((false, n)) => n,
    T((true, n)) => n + 1000
  }
}
// Bare top-level tuple pattern with a literal element: previously the cond was
// unconditionally true (matched any tuple) AND the binding of `n` was dropped
// (codegen trap). `cb` exercises both over a local tuple; discrimination must
// route by the bool. (Written with a local `let` tuple rather than a tuple
// function parameter, since `((Bool, Int)) -> Int` annotations are mis-parsed
// as two-parameter, a separate type-annotation bug.)
let cb: (Bool, Int) -> Int = (flag, v) -> {
  let e = (flag, v)
  match e {
    (false, n) => n,
    (true, n) => n + 1000
  }
}
export let _start: () -> Int = () -> {
  // Or-pattern discrimination: a string / tuple branch of `a | b` previously
  // fell through to an always-true test, so a non-matching scrutinee silently
  // took the first arm (`"z"` matched `"a" | "b"`, `(9, 0)` matched
  // `(1, _) | (2, _)`). Both must route to the catch-all here.
  let s = "z"
  let sor = match s { "a" | "b" => 100, _ => 7 }
  let t = (9, 0)
  let tor = match t { (1, _) | (2, _) => 100, (_, _) => 11 }
  // Or-pattern nested inside a constructor arg / tuple element (`W(1 | 2)`,
  // `(1 | 2, _)`): emit_sub_tests previously had no POr case, so the literal
  // test was skipped and any value matched. `W(9)` / `(9, _)` must miss here.
  let nor = match I(9) { I(1 | 2) => 100, I(_) => 13 }
  let ntor = match (9, 0) { (1 | 2, _) => 100, (_, _) => 17 }
  cn(N(W(true), 7)) + cn(N(W(false), 3)) + ct(T((true, 5))) + ct(T((false, 1)))
    + cb(true, 9) + cb(false, 2) + sor + tor + nor + ntor
}
EOF
# Expected: 1007+3+1005+1+1009+2 + 7+11 + 13+17 = 3075. A regressed compiler
# ignores the nested/bare-tuple/or literal tests and returns a smaller sum (or
# fails to compile the bare-tuple binding).
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$nldir/nestedlit.vibe" "$nldir/nestedlit.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$nldir/nestedlit.wasm" ]; then
  echo "[compiler-gate] FAIL: nested literal sub-pattern program did not compile" >&2; exit 1
fi
nestedlit_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$nldir/nestedlit.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$nestedlit_out" != "3075" ]; then
  echo "[compiler-gate] FAIL: nested literal sub-pattern mismatch (got '$nestedlit_out', want 3075 -> #613 regressed)" >&2
  exit 1
fi
rm -rf "$nldir"
echo "[compiler-gate] nested literal sub-pattern discrimination ok"

# 26. effect-call discipline (#626 criteria 1 & 3-builtin-slice): both
#     `perform EffName::Op` and a call to an effectful BUILTIN (`Fs::read_file`,
#     ...) are type errors unless the enclosing function declares that effect in
#     a `with` row (or it is inside a `handle`). Declared variants must
#     compile; undeclared variants must be REJECTED. (`Error`/`Async` are out of
#     this slice; pure builtins like `Array::length` are never flagged.)
echo "[compiler-gate] 26/26 effect-call discipline (perform + builtin)"
pfdir="_build/_gate_perform"
rm -rf "$pfdir"; mkdir -p "$pfdir"
cat > "$pfdir/good.vibe" <<'EOF'
let emit: () -> Unit with Stdout = () -> {
  perform Stdout::WriteStream("hi")
}
let load: (String) -> String with Fs = (p) -> {
  Fs::read_file(p)
}
let pure_use: (Array[Int]) -> Int = (xs) -> {
  Array::length(xs)
}
export let _start: () -> Int with Stdout = () -> {
  emit()
  pure_use([1, 2, 3]) + 39
}
EOF
cat > "$pfdir/bad_perform.vibe" <<'EOF'
let emit: () -> Unit = () -> {
  perform Stdout::WriteStream("hi")
}
export let _start: () -> Int = () -> {
  emit()
  42
}
EOF
cat > "$pfdir/bad_builtin.vibe" <<'EOF'
let load: (String) -> String = (p) -> {
  Fs::read_file(p)
}
export let _start: () -> Int = () -> {
  42
}
EOF
# Transitive (#626): a function calling an Fs-declaring helper must itself
# declare Fs (or handle it). `mid` leaks Fs from `leaf` without declaring it.
cat > "$pfdir/bad_transitive.vibe" <<'EOF'
let leaf: (String) -> String with Fs = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String = (p) -> {
  leaf(p)
}
export let _start: () -> Int with Fs = () -> {
  let _ = mid("x")
  42
}
EOF
# The same chain with `mid` correctly declaring Fs must compile.
cat > "$pfdir/good_transitive.vibe" <<'EOF'
let leaf: (String) -> String with Fs = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String with Fs = (p) -> {
  leaf(p)
}
export let _start: () -> Int with Fs = () -> {
  let _ = mid("x")
  42
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/good.vibe" "$pfdir/good.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pfdir/good.wasm" ]; then
  echo "[compiler-gate] FAIL: declared effect calls did not compile (#626 over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_perform.vibe" "$pfdir/bad_perform.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_perform.wasm" ]; then
  echo "[compiler-gate] FAIL: undeclared perform compiled (#626 criterion 1 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_builtin.vibe" "$pfdir/bad_builtin.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_builtin.wasm" ]; then
  echo "[compiler-gate] FAIL: undeclared effectful builtin call compiled (#626 builtin slice regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_transitive.vibe" "$pfdir/bad_transitive.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_transitive.wasm" ]; then
  echo "[compiler-gate] FAIL: undeclared transitive effect call compiled (#626 transitive enforcement regressed)" >&2; exit 1
fi
# #639: effect-row diagnostics — the transitive reject above must print the
# EXPECTED vs ACTUAL rows as a set difference, and (since `mid` has no `with`
# clause at all) a declare-form fix-it hint that blames the CALLER `mid`,
# not the callee `leaf`.
if ! grep -qF "effect row mismatch for 'mid': missing { Fs }" "$pfdir/bad_transitive.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: transitive reject lacks the effect-row set-difference diagnostic (#639)" >&2
  cat "$pfdir/bad_transitive.wasm.diag" >&2 2>/dev/null; exit 1
fi
if ! grep -qF "hint: declare 'fn mid(...) -> T with Fs'" "$pfdir/bad_transitive.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: no-row reject lacks the declare-form fix-it hint (#639)" >&2
  cat "$pfdir/bad_transitive.wasm.diag" >&2 2>/dev/null; exit 1
fi
# #639: a caller that already declares a row gets the add-form hint carrying
# the sorted union (existing row preserved, missing effect appended).
cat > "$pfdir/bad_row_single.vibe" <<'EOF'
let leaf: (String) -> String with Fs = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String with Exception = (p) -> {
  leaf(p)
}
export let _start: () -> Int = () -> { 42 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_row_single.vibe" "$pfdir/bad_row_single.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_row_single.wasm" ]; then
  echo "[compiler-gate] FAIL: partially-declared transitive effect call compiled (#639)" >&2; exit 1
fi
# #1461: the fixture used to DECLARE `with Error` while the diagnostic reported
# the canonical `Exception` -- an asymmetry that was the point of Step 1's flip,
# and what this assertion pinned. The final stage retired the alias as a
# spelling, so the fixture now declares `Exception` too and the asymmetry is
# gone. The assertion text is unchanged: it always read `declared { Exception }`,
# because the canonical name is what gets printed either way.
if ! grep -qF "effect row mismatch for 'mid': missing { Fs } (declared { Exception }, requires { Exception, Fs })" "$pfdir/bad_row_single.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: partial-row reject lacks the declared-vs-required diff (#639)" >&2
  cat "$pfdir/bad_row_single.wasm.diag" >&2 2>/dev/null; exit 1
fi
if ! grep -qF "hint: add 'with Exception + Fs' to 'mid'" "$pfdir/bad_row_single.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: partial-row reject lacks the add-form fix-it hint (#639)" >&2
  cat "$pfdir/bad_row_single.wasm.diag" >&2 2>/dev/null; exit 1
fi
# #639: multiple missing effects at one call site aggregate into ONE sorted
# set difference (leaf declares "Fs, Env" in reversed order; the diagnostic
# must render "{ Env, Fs }").
cat > "$pfdir/bad_row_multi.vibe" <<'EOF'
let leaf: (String) -> String with Fs + Env = (p) -> {
  Fs::read_file(p)
}
let mid: (String) -> String = (p) -> {
  leaf(p)
}
export let _start: () -> Int = () -> { 42 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_row_multi.vibe" "$pfdir/bad_row_multi.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_row_multi.wasm" ]; then
  echo "[compiler-gate] FAIL: multi-effect transitive call compiled (#639)" >&2; exit 1
fi
if ! grep -qF "effect row mismatch for 'mid': missing { Env, Fs }" "$pfdir/bad_row_multi.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: multi-effect reject is not an aggregated sorted set difference (#639)" >&2
  cat "$pfdir/bad_row_multi.wasm.diag" >&2 2>/dev/null; exit 1
fi
if ! grep -qF "hint: declare 'fn mid(...) -> T with Env + Fs'" "$pfdir/bad_row_multi.wasm.diag" 2>/dev/null; then
  echo "[compiler-gate] FAIL: multi-effect reject lacks the sorted fix-it hint (#639)" >&2
  cat "$pfdir/bad_row_multi.wasm.diag" >&2 2>/dev/null; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/good_transitive.vibe" "$pfdir/good_transitive.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pfdir/good_transitive.wasm" ]; then
  echo "[compiler-gate] FAIL: correctly-declared transitive effect chain did not compile (#626 over-rejects)" >&2; exit 1
fi
# #812: the transitive map must also cover IMPORTED effectful functions — a
# caller invoking an imported `with Fs` function without declaring Fs used
# to compile (and reach the filesystem at runtime) while the same shape with a
# local callee was rejected. The env-seeded row closes the module boundary.
mkdir -p "$pfdir/sub"
cat > "$pfdir/sub/helper.vibe" <<'EOF'
export let read_it: (String) -> String with Exception + Fs = (p) -> {
  Fs::read_file(p)
}
EOF
cat > "$pfdir/bad_import_transitive.vibe" <<'EOF'
import ./sub/helper.vibe { read_it }

let f: (Int) -> Int = (n) -> {
  let _ = read_it("x")
  n
}
export let _start: () -> Int = () -> { f(1) }
EOF
cat > "$pfdir/good_import_transitive.vibe" <<'EOF'
import ./sub/helper.vibe { read_it }

let g: (String) -> String with Exception + Fs = (p) -> {
  read_it(p)
}
export let _start: () -> Int = () -> { 42 }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/bad_import_transitive.vibe" "$pfdir/bad_import_transitive.wasm" _start >/dev/null 2>&1 || true
if [ -s "$pfdir/bad_import_transitive.wasm" ]; then
  echo "[compiler-gate] FAIL: undeclared call of IMPORTED effectful function compiled (#812 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$pfdir/good_import_transitive.vibe" "$pfdir/good_import_transitive.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$pfdir/good_import_transitive.wasm" ]; then
  echo "[compiler-gate] FAIL: correctly-declared imported effect call did not compile (#812 over-rejects)" >&2; exit 1
fi
rm -rf "$pfdir"
echo "[compiler-gate] effect-call discipline ok"

# 27. handle effect discharge (#626 criterion 2): `handle ... with E` discharges
#     E for its body (a perform of E inside need not be declared), but ONLY E —
#     a perform of a DIFFERENT undeclared effect inside the same handle still
#     leaks and is a type error. The parser qualifies arm patterns as `E::Op`, so
#     the discharged effect is recovered from the handler arms.
echo "[compiler-gate] 27/27 handle effect discharge"
hdir="_build/_gate_handle"
rm -rf "$hdir"; mkdir -p "$hdir"
cat > "$hdir/discharge.vibe" <<'EOF'
effect Console { Print(String) -> Unit }
let greet: () -> Int = () -> {
  handle {
    perform Console::Print("hi")
    7
  } with Console {
    Print(s) => resume(0)
  }
}
export let _start: () -> Int = () -> { greet() }
EOF
cat > "$hdir/leak.vibe" <<'EOF'
effect Console { Print(String) -> Unit }
effect Logger { Log(String) -> Unit }
let greet: () -> Int = () -> {
  handle {
    perform Logger::Log("hi")
    7
  } with Console {
    Print(s) => resume(0)
  }
}
export let _start: () -> Int = () -> { greet() }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/discharge.vibe" "$hdir/discharge.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$hdir/discharge.wasm" ]; then
  echo "[compiler-gate] FAIL: handle did not discharge its own effect (#626 criterion 2 over-rejects)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/leak.vibe" "$hdir/leak.wasm" _start >/dev/null 2>&1 || true
if [ -s "$hdir/leak.wasm" ]; then
  echo "[compiler-gate] FAIL: a different undeclared effect leaked through a handle (#626 criterion 2 regressed)" >&2; exit 1
fi
# Multi-operation handler dispatch (#665): the perform/handler ABI records the
# operation index (g_op_index) so a handler over a multi-operation effect routes
# each performed operation to the matching arm (previously every operation
# silently ran arms[0]). Verify correct routing AND that the original positional
# bug (perform order != arm order) and cross-handler corruption are gone.
cat > "$hdir/multiop.vibe" <<'EOF'
effect Calc {
  Add(Int) -> Int
  Mul(Int) -> Int
}
export let _start: () -> Int = () -> {
  let a = handle { perform Calc::Mul(3) } with Calc {
    Add(n) => resume(n + 100);
    Mul(n) => resume(n * 1000)
  }
  let b = handle {
    let x = perform Calc::Mul(3)
    let y = perform Calc::Add(5)
    x + y
  } with Calc {
    Add(n) => resume(n + 10);
    Mul(n) => resume(n * 10)
  }
  a + b
}
EOF
cat > "$hdir/singleop.vibe" <<'EOF'
effect Logger { Log(String) -> Unit }
export let _start: () -> Int = () -> {
  handle { perform Logger::Log("hi"); 42 } with Logger {
    Log(s) => resume(())
  }
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/multiop.vibe" "$hdir/multiop.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$hdir/multiop.wasm" ]; then
  echo "[compiler-gate] FAIL: multi-operation effect handler did not compile (#665 dispatch regressed)" >&2; exit 1
fi
# a = Mul(3)*1000 = 3000 ; b = Mul(3)*10 + Add(5)+10 = 30+15 = 45 ; total 3045
multiop_out="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/run_wasm_vibe_host_runner.sh \
  --invoke _start "$hdir/multiop.wasm" 2>/dev/null | tr -dc '0-9')"
if [ "$multiop_out" != "3045" ]; then
  echo "[compiler-gate] FAIL: multi-operation dispatch wrong (got '$multiop_out', want 3045 -> #665 regressed)" >&2; exit 1
fi
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$hdir/singleop.vibe" "$hdir/singleop.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$hdir/singleop.wasm" ]; then
  echo "[compiler-gate] FAIL: single-operation effect handler did not compile (#665 over-rejects)" >&2; exit 1
fi
rm -rf "$hdir"
echo "[compiler-gate] handle effect discharge ok"

# 27b. effect op signatures (#813): perform arguments, handler arm names and
#      payload types, and resume values are validated against the DECLARED
#      effect's op signatures. Each was previously unchecked (silent garbage).
echo "[compiler-gate] 27b/27 effect op signature checking (#813)"
odir="_build/_gate_effopsig"
rm -rf "$odir"; mkdir -p "$odir"
cat > "$odir/ok_op.vibe" <<'EOF'
effect R { Take(Int) -> Int }
export let _start: () -> Int = () -> {
  handle {
    perform R::Take(41)
  } with R {
    Take(n) => resume(n + 1)
  }
}
EOF
cat > "$odir/bad_performarg.vibe" <<'EOF'
effect R { Take(Int) -> Int }
export let _start: () -> Int = () -> {
  handle { perform R::Take("str") } with R { Take(n) => resume(n + 1) }
}
EOF
cat > "$odir/bad_performarity.vibe" <<'EOF'
effect R { Take(Int) -> Int }
export let _start: () -> Int = () -> {
  handle { perform R::Take(1, 2) } with R { Take(n) => resume(n + 1) }
}
EOF
cat > "$odir/bad_armname.vibe" <<'EOF'
effect Ask { Get() -> Int }
export let _start: () -> Int = () -> {
  handle { perform Ask::Get() } with Ask { Wrong(x) => resume(1) }
}
EOF
cat > "$odir/bad_armpayload.vibe" <<'EOF'
effect G { Give(Int) -> Int }
export let _start: () -> Int = () -> {
  handle { perform G::Give(7) } with G { Give(s) => resume(String::length(s)) }
}
EOF
cat > "$odir/bad_resumeval.vibe" <<'EOF'
effect Q { Get() -> Int }
export let _start: () -> Int = () -> {
  handle { perform Q::Get() } with Q { Get() => resume("oops") }
}
EOF
cat > "$odir/bad_kconv.vibe" <<'EOF'
effect E { Emit(Int) -> Int }
export let _start: () -> Int = () -> {
  handle { perform E::Emit(20) } with E { Emit(v, k) => v + k(0) }
}
EOF
cat > "$odir/bad_missingarm.vibe" <<'EOF'
effect Duo { A() -> Int; B() -> Int }
export let _start: () -> Int = () -> {
  handle { perform Duo::B() } with Duo { A() => resume(1) }
}
EOF
cat > "$odir/bad_resume0.vibe" <<'EOF'
effect Q { Get() -> Int }
export let _start: () -> Int = () -> {
  handle { perform Q::Get() } with Q { Get() => resume() }
}
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$odir/ok_op.vibe" "$odir/ok_op.wasm" _start >/dev/null 2>&1 || true
if [ ! -s "$odir/ok_op.wasm" ]; then
  echo "[compiler-gate] FAIL: well-typed effect op program did not compile (#813 over-rejects)" >&2; exit 1
fi
op_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$odir/ok_op.wasm" 2>/dev/null | tail -n 1)"
if [ "$op_out" != "42" ]; then
  echo "[compiler-gate] FAIL: effect op control returned '$op_out' (expected 42)" >&2; exit 1
fi
for bad in bad_performarg bad_performarity bad_armname bad_armpayload bad_resumeval bad_kconv bad_missingarm bad_resume0; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$odir/$bad.vibe" "$odir/$bad.wasm" _start >/dev/null 2>&1 || true
  if [ -s "$odir/$bad.wasm" ]; then
    echo "[compiler-gate] FAIL: ill-typed $bad compiled (#813 regressed)" >&2; exit 1
  fi
done
rm -rf "$odir"
echo "[compiler-gate] effect op signature checking ok"

# 27c. index bounds checks (#811): OOB / negative Array and Bytes access must
#      TRAP (unreachable) instead of silently reading/writing adjacent memory;
#      in-bounds access is unchanged.
echo "[compiler-gate] 27c/27 index bounds checks (#811)"
bdir="_build/_gate_bounds"
rm -rf "$bdir"; mkdir -p "$bdir"
cat > "$bdir/inbounds.vibe" <<'EOF'
export let _start: () -> Int = () -> {
  let a = [40, 2, 7]
  // Bytes::new(n) is a length-n zero-filled buffer (MoonBit semantics);
  // exercise in-len set/get plus push growth past the initial length.
  let b = Bytes::new(3)
  Bytes::set(b, 0, 2)
  Bytes::push(b, 9)
  let s = "abc"
  Array::get(a, 0) + Bytes::get(b, 0) + Bytes::get(b, 3) - 9 + s[1] - String::char_code_at(s, 1)
}
EOF
cat > "$bdir/oob_get.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get([1, 2, 3], 5) }
EOF
cat > "$bdir/oob_neg.vibe" <<'EOF'
export let _start: () -> Int = () -> { Array::get([1, 2, 3], -1) }
EOF
cat > "$bdir/oob_bytes.vibe" <<'EOF'
export let _start: () -> Int = () -> { let b = Bytes::new(2); Bytes::get(b, 9) }
EOF
cat > "$bdir/oob_str.vibe" <<'EOF'
export let _start: () -> Int = () -> { String::char_code_at("abc", 7) }
EOF
cat > "$bdir/oob_str_neg.vibe" <<'EOF'
export let _start: () -> Int = () -> { let s = "abc"; s[-1] }
EOF
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
  "$bdir/inbounds.vibe" "$bdir/inbounds.wasm" _start >/dev/null 2>&1 || true
bounds_out="$(bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$bdir/inbounds.wasm" 2>/dev/null | tail -n 1 || true)"
if [ "$bounds_out" != "42" ]; then
  echo "[compiler-gate] FAIL: in-bounds access returned '$bounds_out' (expected 42; #811 over-traps)" >&2; exit 1
fi
for oob in oob_get oob_neg oob_bytes oob_str oob_str_neg; do
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$stage2_wasm" \
    "$bdir/$oob.vibe" "$bdir/$oob.wasm" _start >/dev/null 2>&1 || true
  if bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$bdir/$oob.wasm" >/dev/null 2>&1; then
    echo "[compiler-gate] FAIL: $oob ran without trapping (#811 regressed)" >&2; exit 1
  fi
done
rm -rf "$bdir"
echo "[compiler-gate] index bounds checks ok"
