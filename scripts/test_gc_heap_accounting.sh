#!/usr/bin/env bash
# Verify non-escaping Wasm-GC local array literals do not churn the guest
# linear bump heap. This intentionally does not claim tracing-GC liveness;
# it only proves the private typed local never touches exported __heap_ptr.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLI_WASM="${1:-${VIBE_GC_HEAP_ACCOUNTING_CLI_WASM:-}}"
if [ -z "$CLI_WASM" ]; then
  CLI_WASM="$(ls -t "$ROOT_DIR"/_build/selfhost/generations/*/stage2.wasm 2>/dev/null | head -1 || true)"
fi
[ -n "$CLI_WASM" ] && [ -s "$CLI_WASM" ] || {
  echo "[gc-heap-accounting] FAIL: pass a stage2.wasm or build a selfhost generation" >&2
  exit 1
}

RUNNER="$ROOT_DIR/runtime/viberun/target/release/viberun"
if [ ! -x "$RUNNER" ] || find runtime/viberun/src runtime/viberun/Cargo.toml runtime/viberun/Cargo.lock -newer "$RUNNER" -print -quit | grep -q .; then
  cargo build --release --manifest-path runtime/viberun/Cargo.toml >/dev/null
fi

WORK="$(mktemp -d "$ROOT_DIR/_build/gc_heap_accounting.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/churn.wasm"
OUT_REL="${OUT#"$ROOT_DIR"/}"

VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  fixtures/gc_heap_churn_test.vibe "$OUT_REL" __no_entry__ >/dev/null
[ -s "$OUT" ] || {
  echo "[gc-heap-accounting] FAIL: gc backend emitted no test module" >&2
  exit 1
}

# Churn, the if branch, the match branch, the #1332 nested-lambda sites, the
# #1541 plain local alias, and the #1541 returned local each have one eligible
# literal -- seven in total.
#
# The returned one is the newest: this mixed fixture used to disable the direct
# ABI island outright, because `Array::push` on a local made the whole component
# fail closed. Acceptance now asks the escape gate whether a binding can hold a
# reference at all before treating it as one, so the pushed local is simply an
# ordinary i64 local and stops poisoning its neighbours -- and the returned one
# takes the reference lane. `Array::push` itself is still not a reference-lane
# operation; a deeper lambda capture and an initializer-frame binding likewise
# retain the linear fallback.
python3 - "$OUT" <<'PY'
import sys
wasm = open(sys.argv[1], "rb").read()
count = wasm.count(b"\xfb\x07\x0c")
if count != 7:
    raise SystemExit(
        "[gc-heap-accounting] FAIL: expected seven eligible native "
        f"array.new_default type 12 instructions, found {count}"
    )
PY

# The fixture must also pass independent Wasm-GC validation: since #1332 lambda
# records DO describe typed native-array locals, so this is the check that the
# lambda code section declares (ref null $array) for exactly those slots.
wasm-tools validate --features all "$OUT" >/dev/null

# #1541 direct-call ABI pair. The positive fixture has one native literal that
# crosses a typed Array[Int] parameter/result/alias chain. The fallback fixture
# contains the same candidate signature plus a generic crossing; its complete
# component must retain the tagged-i64 ABI, so no native literal is emitted.
DIRECT_OUT="$WORK/direct_array_abi.wasm"
DIRECT_OUT_REL="${DIRECT_OUT#"$ROOT_DIR"/}"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  fixtures/gc_direct_array_abi_test.vibe "$DIRECT_OUT_REL" __no_entry__ >/dev/null
wasm-tools validate --features all "$DIRECT_OUT" >/dev/null
"$RUNNER" "$DIRECT_OUT" >/dev/null

# #1541 Phase B characterization: one private concrete Array[Int] literal
# crosses exactly one immutable local alias. Mutating through that alias and
# reading through the original proves that lowering preserves object identity.
ALIAS_OUT="$WORK/direct_array_alias_identity.wasm"
ALIAS_OUT_REL="${ALIAS_OUT#"$ROOT_DIR"/}"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  fixtures/gc_direct_array_alias_identity_test.vibe "$ALIAS_OUT_REL" __no_entry__ >/dev/null
wasm-tools validate --features all "$ALIAS_OUT" >/dev/null
"$RUNNER" "$ALIAS_OUT" >/dev/null

compile_direct_abi_fallback() {
  local fixture="$1"
  local output="$2"
  local output_rel="${output#"$ROOT_DIR"/}"
  VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
    "$fixture" "$output_rel" __no_entry__ >/dev/null
  wasm-tools validate --features all "$output" >/dev/null
  "$RUNNER" "$output" >/dev/null
}

FALLBACK_OUT="$WORK/direct_array_abi_fallback.wasm"
SHADOW_FALLBACK_OUT="$WORK/direct_array_abi_shadow_fallback.wasm"
EXPORT_FALLBACK_OUT="$WORK/direct_array_abi_export_fallback.wasm"
compile_direct_abi_fallback fixtures/gc_direct_array_abi_fallback_test.vibe "$FALLBACK_OUT"
compile_direct_abi_fallback fixtures/gc_direct_array_abi_shadow_fallback_test.vibe "$SHADOW_FALLBACK_OUT"
compile_direct_abi_fallback fixtures/gc_direct_array_abi_export_fallback_test.vibe "$EXPORT_FALLBACK_OUT"

# #1541 isolated direct-argument characterization. The native fixture crosses
# exactly one private concrete Array[Int] parameter boundary; the generic pair
# must retain the component-wide tagged-i64 fallback.
ARGUMENT_OUT="$WORK/direct_array_argument_identity.wasm"
ARGUMENT_FALLBACK_OUT="$WORK/direct_array_argument_fallback.wasm"
compile_direct_abi_fallback fixtures/gc_direct_array_argument_identity_test.vibe "$ARGUMENT_OUT"
compile_direct_abi_fallback fixtures/gc_direct_array_argument_fallback_test.vibe "$ARGUMENT_FALLBACK_OUT"

# #1541 generic coexistence. The island used to be cleared component-wide by
# the mere PRESENCE of any source-level generic, which is every real program.
# A generic that never carries a reference-lane value now stays on the
# tagged-i64 lane beside a live island; its fallback pair (the generic that
# does carry the Array[Int]) is ARGUMENT_FALLBACK_OUT above.
COEXIST_OUT="$WORK/direct_array_generic_coexist.wasm"
compile_direct_abi_fallback fixtures/gc_direct_array_generic_coexist_test.vibe "$COEXIST_OUT"

# #1541 recursion / SCC characterization. Self-recursion and a two-function
# cycle (one call site precedes its callee's definition) both keep the single
# native allocation: the reference is threaded through every frame instead of
# being materialized per call.
RECURSION_OUT="$WORK/direct_array_recursion.wasm"
compile_direct_abi_fallback fixtures/gc_direct_array_recursion_test.vibe "$RECURSION_OUT"

# #1541 element types. The native array's cells are `(mut i64)` holding tagged
# values, so `Array[String]` and `Array[Bool]` cross the same lane as
# `Array[Int]` with no representation change -- two literals here. The element
# allowlist exists because erased generic binders are spelled like concrete type
# names, not because other element types would not fit.
ELEMENT_TYPES_OUT="$WORK/direct_array_element_types.wasm"
compile_direct_abi_fallback fixtures/gc_direct_array_element_types_test.vibe "$ELEMENT_TYPES_OUT"

# #1541 mutating transform. A callee that mutates its array parameter AND
# returns the same reference is the shape where passing a reference rather than
# a copy is what makes the call mean anything -- and it used to clear the island
# component-wide, because acceptance had no ESeq arm and the tail yielding the
# reference read as a violation. One literal, crossing two such boundaries.
MUTATING_TRANSFORM_OUT="$WORK/direct_array_mutating_transform.wasm"
compile_direct_abi_fallback fixtures/gc_direct_array_mutating_transform_test.vibe "$MUTATING_TRANSFORM_OUT"
# #1702 (Phase C, no conversion point): a record literal bound to a local that
# never leaves field-read position lives in a real `(struct (mut i64) x N)`.
# Cells stay tagged i64, so this moves where the record LIVES, not how its
# fields are represented -- and no boundary is crossed, so nothing has to
# convert between the reference lane and tagged i64.
NATIVE_STRUCT_OUT="$WORK/native_struct_local.wasm"
NATIVE_STRUCT_FALLBACK_OUT="$WORK/native_struct_fallback.wasm"
compile_direct_abi_fallback fixtures/gc_native_struct_local_test.vibe "$NATIVE_STRUCT_OUT"
compile_direct_abi_fallback fixtures/gc_native_struct_fallback_test.vibe "$NATIVE_STRUCT_FALLBACK_OUT"

NATIVE_STRUCT_WAT="$WORK/native_struct_local.wat"
NATIVE_STRUCT_FALLBACK_WAT="$WORK/native_struct_fallback.wat"
wasm-tools print "$NATIVE_STRUCT_OUT" > "$NATIVE_STRUCT_WAT"
wasm-tools print "$NATIVE_STRUCT_FALLBACK_OUT" > "$NATIVE_STRUCT_FALLBACK_WAT"

# User struct types start above the fixed base types (0-13), so `struct.new 1N`
# with N >= 4 is a #1702 record and never the RC cell or the alloc probe.
native_struct_new="$(grep -cE '^[[:space:]]+struct\.new 1[4-9]' "$NATIVE_STRUCT_WAT" || true)"
native_struct_get="$(grep -cE '^[[:space:]]+struct\.get 1[4-9]' "$NATIVE_STRUCT_WAT" || true)"
if [ "$native_struct_new" -ne 3 ] || [ "$native_struct_get" -ne 7 ]; then
  echo "[gc-heap-accounting] FAIL: expected three #1702 struct.new and seven struct.get, found $native_struct_new/$native_struct_get" >&2
  exit 1
fi
# The representation claim: those locals are declared as typed references, not
# i64. Without this a passing run could just mean the fixture got constant
# folded away.
native_struct_locals="$(grep -cE '^[[:space:]]+\(local \(ref null 1[4-9]\)\)' "$NATIVE_STRUCT_WAT" || true)"
if [ "$native_struct_locals" -lt 3 ]; then
  echo "[gc-heap-accounting] FAIL: expected three typed struct locals, found $native_struct_locals" >&2
  exit 1
fi
# The fallback pair covers returning, passing, storing through a `mut` field,
# and closure capture -- every one of which would need the ctor tag a native
# struct does not carry.
fallback_struct_new="$(grep -cE '^[[:space:]]+struct\.new 1[4-9]' "$NATIVE_STRUCT_FALLBACK_WAT" || true)"
if [ "$fallback_struct_new" -ne 0 ]; then
  echo "[gc-heap-accounting] FAIL: expected no #1702 struct.new in the fallback fixture, found $fallback_struct_new" >&2
  exit 1
fi

# #1541 export coexistence. A public declaration crosses a host boundary whose
# ABI is tagged i64 and so cannot carry a reference -- but it no longer takes
# the component down with it. Its fallback pair is EXPORT_FALLBACK_OUT above,
# where a private reference is piped THROUGH the exported declaration: that is a
# real unsupported crossing and still clears everything.
EXPORT_COEXIST_OUT="$WORK/direct_array_export_coexist.wasm"
compile_direct_abi_fallback fixtures/gc_direct_array_export_coexist_test.vibe "$EXPORT_COEXIST_OUT"

# #1541 control-flow join pair. An `if` whose arms are BOTH already
# reference-lane values produces a typed reference itself, in the tail of a
# reference-result function and in a proven reference argument alike; two
# caller literals cross it. The fallback keeps a bare array literal in one arm:
# a literal has no representation of its own until a consumer picks one, and an
# `if` has no consumer proof to lean on, so that still clears the whole island.
JOIN_OUT="$WORK/direct_array_join.wasm"
JOIN_FALLBACK_OUT="$WORK/direct_array_join_fallback.wasm"
compile_direct_abi_fallback fixtures/gc_direct_array_join_test.vibe "$JOIN_OUT"
compile_direct_abi_fallback fixtures/gc_direct_array_join_fallback_test.vibe "$JOIN_FALLBACK_OUT"

# Count decoded instructions rather than byte patterns: raw scanning can match
# non-code sections and also couples this gate to an incidental numeric type
# index. `wasm-tools print` parses the module and renders instructions with the
# actual type reference, which we deliberately ignore here.
count_decoded_instruction() {
  local wasm="$1"
  local instruction="$2"
  wasm-tools print "$wasm" | awk -v instruction="$instruction" '$1 == instruction { count += 1 } END { print count + 0 }'
}

count_native_array_allocs() {
  count_decoded_instruction "$1" "array.new_default"
}

assert_direct_argument_structure() {
  local wasm="$1"
  local printed="$WORK/$(basename "$wasm").wat"
  wasm-tools print "$wasm" > "$printed"

  # The only native allocation is the caller literal. Its two initializer
  # writes plus the callee mutation are the complete decoded array.set set.
  local allocs sets indirect_calls
  allocs="$(awk '$1 == "array.new_default" { count += 1 } END { print count + 0 }' "$printed")"
  sets="$(awk '$1 == "array.set" { count += 1 } END { print count + 0 }' "$printed")"
  indirect_calls="$(awk '$1 == "call_indirect" { count += 1 } END { print count + 0 }' "$printed")"
  [ "$allocs" -eq 1 ] || {
    echo "[gc-heap-accounting] FAIL: expected one direct-argument native literal, found $allocs" >&2
    exit 1
  }
  [ "$sets" -eq 3 ] || {
    echo "[gc-heap-accounting] FAIL: expected two literal initializers plus one callee array.set, found $sets" >&2
    exit 1
  }
  [ "$indirect_calls" -eq 0 ] || {
    echo "[gc-heap-accounting] FAIL: direct-argument fixture emitted $indirect_calls call_indirect instructions" >&2
    exit 1
  }

  # Tie a decoded direct call to the function that both has the native-array
  # parameter type and performs the callee mutation. Discover all indices from
  # wasm-tools output; numeric type/function indices are deliberately not
  # fixed because they are an encoding detail.
  python3 - "$printed" <<'PY'
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
typed_types = set()
for line in lines:
    match = re.match(
        r"^  \(type \(;(\d+);\) \(func \(param \(ref null [^)]+\) i64\) \(result i64\)\)\)$",
        line,
    )
    if match:
        typed_types.add(match.group(1))
if not typed_types:
    raise SystemExit(
        "[gc-heap-accounting] FAIL: missing typed array-ref direct-argument signature"
    )

functions = []
current = None
for line in lines:
    declaration = re.match(r"^  \(func \(;(\d+);\) \(type (\d+)\)", line)
    if declaration:
        if current is not None:
            functions.append(current)
        current = {
            "index": declaration.group(1),
            "type": declaration.group(2),
            "lines": [],
        }
    elif current is not None:
        current["lines"].append(line)
if current is not None:
    functions.append(current)

# The characterized callee is identified structurally: typed native-array
# parameter plus the decoded array.set mutation in its body.
typed_mutators = {
    function["index"]
    for function in functions
    if function["type"] in typed_types
    and any(re.match(r"^\s+array\.set\b", line) for line in function["lines"])
}
if not typed_mutators:
    raise SystemExit(
        "[gc-heap-accounting] FAIL: no typed array-ref callee performs array.set"
    )

direct_targets = {
    match.group(1)
    for line in lines
    if (match := re.match(r"^\s+call (\d+)\s*$", line))
}
called_mutators = typed_mutators & direct_targets
if not called_mutators:
    raise SystemExit(
        "[gc-heap-accounting] FAIL: typed array-ref mutator has no decoded direct call"
    )
PY
}

positive="$(count_native_array_allocs "$DIRECT_OUT")"
alias="$(count_native_array_allocs "$ALIAS_OUT")"
declare -a fallback_labels=("generic" "spelling shadow" "export" "control-flow join")
declare -a fallback_outputs=("$FALLBACK_OUT" "$SHADOW_FALLBACK_OUT" "$EXPORT_FALLBACK_OUT" "$JOIN_FALLBACK_OUT")
if [ "$positive" -ne 1 ]; then
  echo "[gc-heap-accounting] FAIL: expected one #1541 direct-ABI native literal, found $positive" >&2
  exit 1
fi
if [ "$alias" -ne 1 ]; then
  echo "[gc-heap-accounting] FAIL: expected one #1541 local-alias native literal, found $alias" >&2
  exit 1
fi
coexist="$(count_native_array_allocs "$COEXIST_OUT")"
if [ "$coexist" -ne 1 ]; then
  echo "[gc-heap-accounting] FAIL: expected one #1541 native literal beside an unrelated generic, found $coexist" >&2
  exit 1
fi
recursion="$(count_native_array_allocs "$RECURSION_OUT")"
if [ "$recursion" -ne 1 ]; then
  echo "[gc-heap-accounting] FAIL: expected one #1541 native literal across recursive crossings, found $recursion" >&2
  exit 1
fi
mutating_transform="$(count_native_array_allocs "$MUTATING_TRANSFORM_OUT")"
if [ "$mutating_transform" -ne 1 ]; then
  echo "[gc-heap-accounting] FAIL: expected one native literal across a mutating transform, found $mutating_transform" >&2
  exit 1
fi
export_coexist="$(count_native_array_allocs "$EXPORT_COEXIST_OUT")"
if [ "$export_coexist" -ne 1 ]; then
  echo "[gc-heap-accounting] FAIL: expected one #1541 native literal beside an exported declaration, found $export_coexist" >&2
  exit 1
fi
# The safety claim is not "it compiled" but "the PUBLIC declaration kept the
# tagged-i64 ABI". Count function signatures that carry a typed reference: the
# private mutator is the only one allowed to. The reserved blocktype
# `(func (result (ref null ...)))` takes no parameter and is excluded by the
# `param` requirement -- it is a base type present in every gc module.
EXPORT_COEXIST_WAT="$WORK/direct_array_export_coexist.wat"
wasm-tools print "$EXPORT_COEXIST_OUT" > "$EXPORT_COEXIST_WAT"
export_ref_signatures="$(grep -cE '^  \(type \(;[0-9]+;\) \(func \(param [^)]*\(ref null' "$EXPORT_COEXIST_WAT" || true)"
if [ "$export_ref_signatures" -ne 1 ]; then
  echo "[gc-heap-accounting] FAIL: expected exactly one reference-carrying signature (the private mutator) beside an export, found $export_ref_signatures" >&2
  exit 1
fi

element_types="$(count_native_array_allocs "$ELEMENT_TYPES_OUT")"
if [ "$element_types" -ne 2 ]; then
  echo "[gc-heap-accounting] FAIL: expected two #1541 native literals for String/Bool elements, found $element_types" >&2
  exit 1
fi
join="$(count_native_array_allocs "$JOIN_OUT")"
if [ "$join" -ne 2 ]; then
  echo "[gc-heap-accounting] FAIL: expected two #1541 native literals crossing a reference-lane join, found $join" >&2
  exit 1
fi
# The join must actually be a typed-reference `if`, not two arms that happen to
# agree: assert the reserved `(func (result (ref null ...)))` blocktype is both
# declared and named by an `if` in the emitted code.
JOIN_WAT="$WORK/direct_array_join.wat"
wasm-tools print "$JOIN_OUT" > "$JOIN_WAT"
join_block_type="$(grep -oE '^  \(type \(;[0-9]+;\) \(func \(result \(ref null [^)]+\)\)\)\)$' "$JOIN_WAT" | head -1 | sed -E 's/^  \(type \(;([0-9]+);\).*/\1/')"
if [ -z "$join_block_type" ]; then
  echo "[gc-heap-accounting] FAIL: no reserved typed-reference blocktype in the join module" >&2
  exit 1
fi
join_typed_ifs="$(awk -v t="(type $join_block_type)" '$1 == "if" && index($0, t) { count += 1 } END { print count + 0 }' "$JOIN_WAT")"
if [ "$join_typed_ifs" -lt 2 ]; then
  echo "[gc-heap-accounting] FAIL: expected the tail and argument joins to name the typed blocktype, found $join_typed_ifs" >&2
  exit 1
fi
for i in "${!fallback_outputs[@]}"; do
  count="$(count_native_array_allocs "${fallback_outputs[$i]}")"
  if [ "$count" -ne 0 ]; then
    echo "[gc-heap-accounting] FAIL: ${fallback_labels[$i]} boundary mixed a typed reference into the fallback component ($count native literals)" >&2
    exit 1
  fi
done
assert_direct_argument_structure "$ARGUMENT_OUT"

# #1541 acceptance, linear side: "linear backend output remains unchanged".
# A committed byte baseline would be the literal reading, but it would also
# fail on every unrelated linear codegen change, so it would be deleted the
# first week. The durable property is the one the acceptance criterion is
# actually protecting: the reference lane must not leak out of the gc lane.
# Compile the very fixtures that DO take the typed reference lane under gc
# with the linear backend and assert the result carries no wasm-gc construct
# at all, and still runs. Semantic parity for the same files is covered by
# scripts/unit_test_runner.sh, which globs them on the linear lane.
assert_linear_lane_has_no_gc_construct() {
  local fixture="$1"
  local output="$WORK/$(basename "$fixture" .vibe)_linear.wasm"
  local output_rel="${output#"$ROOT_DIR"/}"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
    "$fixture" "$output_rel" __no_entry__ >/dev/null
  wasm-tools validate --features all "$output" >/dev/null
  "$RUNNER" "$output" >/dev/null
  local printed="$output.wat"
  wasm-tools print "$output" > "$printed"
  local gc_instructions
  gc_instructions="$(awk '
    $1 == "array.new_default" || $1 == "array.new" || $1 == "array.get" ||
    $1 == "array.set" || $1 == "struct.new" || $1 == "struct.get" ||
    $1 == "struct.set" || $1 == "ref.cast" { count += 1 }
    END { print count + 0 }
  ' "$printed")"
  if [ "$gc_instructions" -ne 0 ]; then
    echo "[gc-heap-accounting] FAIL: linear lane emitted $gc_instructions wasm-gc instructions for $fixture" >&2
    exit 1
  fi
  if grep -q '(ref null' "$printed"; then
    echo "[gc-heap-accounting] FAIL: linear lane declared a typed reference for $fixture" >&2
    exit 1
  fi
}

assert_linear_lane_has_no_gc_construct fixtures/gc_direct_array_argument_identity_test.vibe
assert_linear_lane_has_no_gc_construct fixtures/gc_direct_array_generic_coexist_test.vibe
echo "[gc-heap-accounting] ok: linear lane keeps the reference-lane fixtures free of wasm-gc constructs"

# #1541 asks for deterministic generated-size evidence per reference-lane
# boundary. A pinned byte count would be the strongest form and the first to be
# deleted -- it moves on every unrelated codegen change. What is reported here
# is each boundary fixture's gc-lane module size next to its linear-lane size,
# every run, so drift is visible in the log; the assertion is only a gross
# trip wire. The reference lane REPLACES linear-memory allocation rather than
# adding to it, so a gc module that has run away to several times its linear
# counterpart means the lane is emitting conversions or duplicate bodies, not
# that codegen grew a little.
report_boundary_size() {
  local label="$1"
  local gc_wasm="$2"
  local linear_wasm="$WORK/$(basename "$gc_wasm" .wasm)_size_linear.wasm"
  local linear_rel="${linear_wasm#"$ROOT_DIR"/}"
  local fixture="$3"
  VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
    "$fixture" "$linear_rel" __no_entry__ >/dev/null
  local gc_size linear_size
  gc_size="$(wc -c < "$gc_wasm")"
  linear_size="$(wc -c < "$linear_wasm")"
  echo "[gc-heap-accounting] size: $label gc=${gc_size}B linear=${linear_size}B"
  if [ "$gc_size" -gt $((linear_size * 3)) ]; then
    echo "[gc-heap-accounting] FAIL: $label gc module ${gc_size}B is more than 3x its linear counterpart ${linear_size}B" >&2
    exit 1
  fi
}

report_boundary_size "direct-argument" "$ARGUMENT_OUT" fixtures/gc_direct_array_argument_identity_test.vibe
report_boundary_size "generic-coexist" "$COEXIST_OUT" fixtures/gc_direct_array_generic_coexist_test.vibe
report_boundary_size "recursion" "$RECURSION_OUT" fixtures/gc_direct_array_recursion_test.vibe
report_boundary_size "control-flow-join" "$JOIN_OUT" fixtures/gc_direct_array_join_test.vibe
report_boundary_size "element-types" "$ELEMENT_TYPES_OUT" fixtures/gc_direct_array_element_types_test.vibe
report_boundary_size "export-coexist" "$EXPORT_COEXIST_OUT" fixtures/gc_direct_array_export_coexist_test.vibe

argument_fallback="$(count_native_array_allocs "$ARGUMENT_FALLBACK_OUT")"
if [ "$argument_fallback" -ne 0 ]; then
  echo "[gc-heap-accounting] FAIL: generic argument boundary emitted $argument_fallback native literals" >&2
  exit 1
fi
ARGUMENT_REPORT="$(VIBE_MEM=1 "$RUNNER" "$ARGUMENT_OUT" 2>&1 >/dev/null)" || {
  printf '%s\n' "$ARGUMENT_REPORT" >&2
  echo "[gc-heap-accounting] FAIL: direct-argument fixture trapped under heap accounting" >&2
  exit 1
}
ARGUMENT_ALLOCATED="$(printf '%s\n' "$ARGUMENT_REPORT" | sed -n 's/.*allocated=\([0-9][0-9]*\).*/\1/p' | head -1)"
case "$ARGUMENT_ALLOCATED" in
  ''|*[!0-9]*)
    echo "[gc-heap-accounting] FAIL: missing direct-argument numeric vibe::mem allocated field" >&2
    exit 1
    ;;
esac
if [ "$ARGUMENT_ALLOCATED" -gt 4096 ]; then
  echo "[gc-heap-accounting] FAIL: direct-argument allocated=$ARGUMENT_ALLOCATED, expected <=4096" >&2
  exit 1
fi
echo "[gc-heap-accounting] ok: direct Array[Int] ABI, isolated argument identity, local alias identity, generic coexistence, export coexistence, mutating transforms, control-flow joins, String/Bool elements, non-escaping local records (#1702), and fail-closed component fallbacks"

REPORT="$(VIBE_MEM=1 "$RUNNER" "$OUT" 2>&1 >/dev/null)" || {
  printf '%s\n' "$REPORT" >&2
  echo "[gc-heap-accounting] FAIL: churn fixture trapped" >&2
  exit 1
}
printf '%s\n' "$REPORT"

# SIMD lane parity (#1331 調査の派生). `simd_*` は linear 専用として登録されて
# おり、`Bytes::blit`/`fill` は gc にあるのに SIMD だけ無い、という不整合だった。
# `Bytes` は両レーンとも linear memory 上にあり SIMD はまさにそこで成立する
# (`v128.load` はメモリアドレスを取る命令で、wasm-gc の配列はアドレス可能では
# ないため GC 側へ移す道は無い) ので、gc で動かない理由が無かった。
#
# ここに置くのは #125 の教訓 — CI に無い検証は腐る。登録を落とすと gc での
# コンパイルが失敗し、このステップで落ちる。
SIMD_OUT="$ROOT_DIR/_build/_gc_gate_simd.wasm"
SIMD_OUT_REL="${SIMD_OUT#"$ROOT_DIR"/}"
VIBE_BACKEND=gc VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI_WASM" \
  fixtures/simd_skip_ws_test.vibe "$SIMD_OUT_REL" __no_entry__ >/dev/null || {
  echo "[gc-heap-accounting] FAIL: simd fixture did not compile on the gc lane" >&2
  exit 1
}
wasm-tools validate --features all "$SIMD_OUT" >/dev/null
"$RUNNER" "$SIMD_OUT" >/dev/null || {
  echo "[gc-heap-accounting] FAIL: simd fixture trapped on the gc lane" >&2
  exit 1
}
echo "[gc-heap-accounting] ok: simd_skip_ws fixture passes on the gc lane"

ALLOCATED="$(printf '%s\n' "$REPORT" | sed -n 's/.*allocated=\([0-9][0-9]*\).*/\1/p' | head -1)"
case "$ALLOCATED" in
  ''|*[!0-9]*)
    echo "[gc-heap-accounting] FAIL: missing numeric vibe::mem allocated field" >&2
    exit 1
    ;;
esac

# The fixture's 8192 churn literals are native GC arrays. It also deliberately
# executes several linear fallback examples (push, return, a module-level
# initializer, and a deeper-lambda capture). The alias is native since #1541.
# Do not assert that exact value: startup/layout and fallback
# fixture changes may move it. The old linear churn lowering was hundreds of
# KiB, therefore this bounded allowance remains the regression property.
if [ "$ALLOCATED" -gt 8192 ]; then
  echo "[gc-heap-accounting] FAIL: allocated=$ALLOCATED, expected <=8192 bytes (native local arrays must not bump __heap_ptr per iteration)" >&2
  exit 1
fi

echo "[gc-heap-accounting] ok: native local array churn kept guest bump allocation at $ALLOCATED bytes"
