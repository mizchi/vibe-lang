#!/usr/bin/env bash
# #415 B-3: builtin parity gate (selfhost re-implementation of the retired
# check_codegen_parity.sh idea).
#
# The registry (core/builtin_registry.vibe) already hard-verifies the two
# FUNC-TABLE lanes at compile time (verify_lane_builtins runs inside every
# linear compile and every gc compile, incl. the gate's 40h gc smoke). What it
# cannot see are the CALLSITE lowerings -- the `fname == "..."` dispatch arms
# in expr/compile_call.vibe (linear) and gc/backend_call.vibe (gc). That is
# exactly where the wasm-gc HOF-gap class of regression lived: a builtin wired
# into one lane's dispatch with the other lane silently left behind.
#
# This gate extracts the full served-name set per lane (callsite arms +
# registry lane flags) and requires every SINGLE-LANE name to be classified in
# scripts/builtin_parity_classification.tsv -- and every classified row to
# still be a real divergence. Adding a builtin to one lane without either
# porting it or classifying it fails the build; so does leaving a stale row
# behind after porting. Divergence is therefore always an explicit, reviewed
# decision, never drift.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

python3 - <<'PY'
import re, sys

LIN_CALLSITE = "lib/@vibe/compiler/codegen/expr/compile_call.vibe"
GC_CALLSITE = "lib/@vibe/compiler/codegen/gc/backend_call.vibe"
REGISTRY = "lib/@vibe/compiler/core/builtin_registry.vibe"
LINKED = "lib/@vibe/compiler/codegen/wasi/linked_compile.vibe"
CLASSIFICATION = "scripts/builtin_parity_classification.tsv"

def callsite_names(path):
    return set(re.findall(r'fname == "([^"]+)"', open(path).read()))

lin_cs = callsite_names(LIN_CALLSITE)
gc_cs = callsite_names(GC_CALLSITE)

# A loud rejection is not an implementation. Keep this subtraction narrow and
# mutation-checked: these public rows deliberately appear in one GC condition
# whose body only throws the component-only diagnostic. If that shape moves,
# fail instead of silently counting (or excluding) the wrong names.
gc_text = open(GC_CALLSITE).read()
gc_throw_only_expected = {
    "Stdin::read_via_stream", "StdinStream::next", "StdinStream::close",
    "StdinStream::chunks"
}
throw_only_match = re.search(
    r'if\s+((?:fname == "(?:Stdin::read_via_stream|StdinStream::next|StdinStream::close|StdinStream::chunks)"(?:\s*\|\|\s*)?)+)\s*\{\s*throw\("StdinStream is unsupported on gc backend;',
    gc_text)
throw_only_found = (set(re.findall(r'fname == "([^"]+)"', throw_only_match.group(1)))
                    if throw_only_match else set())
if throw_only_found != gc_throw_only_expected:
    print("[builtin-parity] FAIL: GC StdinStream rejection shape changed; "
          "update the throw-only extraction without counting rejection as "
          f"implementation (found {sorted(throw_only_found)})", file=sys.stderr)
    sys.exit(1)
gc_cs -= throw_only_found
if not lin_cs or not gc_cs:
    print(f"[builtin-parity] FAIL: extracted no dispatch arms "
          f"(linear {len(lin_cs)}, gc {len(gc_cs)}) -- did the dispatch "
          f"pattern move away from `fname == \"...\"`? Update "
          f"scripts/check_builtin_parity.sh alongside it.", file=sys.stderr)
    sys.exit(1)

rows = re.findall(
    r'\(\s*"([^"]+)"\s*,\s*CtFn.*?,\s*(true|false)\s*,\s*(true|false)\s*,\s*(true|false)\s*\)',
    open(REGISTRY).read())
if len(rows) < 90:
    print(f"[builtin-parity] FAIL: parsed only {len(rows)} registry rows "
          f"(expected 90+) -- registry row shape changed? Update "
          f"scripts/check_builtin_parity.sh alongside it.", file=sys.stderr)
    sys.exit(1)
reg_lin = {n for n, l, g, v in rows if l == "true"}
reg_gc = {n for n, l, g, v in rows if g == "true"}
# Compiler-owned wrappers can implement a checker-visible builtin without a
# func-table row. Keep this exception exact and mutation-checked: chunks must
# still be retargeted to its injected linear/RC source factory.
wrapper_only_expected = {"StdinStream::chunks"}
linked_text = open(LINKED).read()
wrapper_only_found = {
    n for n in wrapper_only_expected
    if f'"{n}"' in linked_text and "__stdin_provider_chunks_surface" in linked_text
}
if wrapper_only_found != wrapper_only_expected:
    print("[builtin-parity] FAIL: compiler-owned StdinStream wrapper shape "
          f"changed (found {sorted(wrapper_only_found)})", file=sys.stderr)
    sys.exit(1)
neither = sorted(n for n, l, g, v in rows
                 if l == "false" and g == "false" and n not in wrapper_only_expected)
if neither:
    print(f"[builtin-parity] FAIL: registry rows claiming NEITHER lane "
          f"(dead rows?): {', '.join(neither)}", file=sys.stderr)
    sys.exit(1)

served_lin = lin_cs | reg_lin | wrapper_only_expected
served_gc = gc_cs | reg_gc
actual = ({(n, "linear-only") for n in served_lin - served_gc}
          | {(n, "gc-only") for n in served_gc - served_lin})

classified = set()
for ln, line in enumerate(open(CLASSIFICATION), 1):
    if not line.strip() or line.startswith("#"):
        continue
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 4 or parts[1] not in ("linear-only", "gc-only"):
        print(f"[builtin-parity] FAIL: malformed classification row at "
              f"{CLASSIFICATION}:{ln}: {line.rstrip()}", file=sys.stderr)
        sys.exit(1)
    key = (parts[0], parts[1])
    if key in classified:
        print(f"[builtin-parity] FAIL: duplicate classification row for "
              f"{parts[0]} ({CLASSIFICATION}:{ln})", file=sys.stderr)
        sys.exit(1)
    classified.add(key)

unclassified = sorted(actual - classified)
stale = sorted(classified - actual)
ok = True
if unclassified:
    ok = False
    print("[builtin-parity] FAIL: unclassified single-lane builtins "
          "(port them to the other lane, or add a classified row to "
          f"{CLASSIFICATION}):", file=sys.stderr)
    for n, lane in unclassified:
        print(f"  {n}  ({lane})", file=sys.stderr)
if stale:
    ok = False
    print("[builtin-parity] FAIL: stale classification rows (no longer a "
          f"single-lane divergence -- remove them from {CLASSIFICATION}):",
          file=sys.stderr)
    for n, lane in stale:
        print(f"  {n}  ({lane})", file=sys.stderr)
if not ok:
    sys.exit(1)
print(f"[builtin-parity] ok: linear serves {len(served_lin)}, gc serves "
      f"{len(served_gc)}, both {len(served_lin & served_gc)}, classified "
      f"divergence {len(actual)} (linear-only "
      f"{len(served_lin - served_gc)}, gc-only {len(served_gc - served_lin)})")
PY
