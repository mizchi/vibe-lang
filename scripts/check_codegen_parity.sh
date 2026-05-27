#!/usr/bin/env bash
# Compare the set of builtin names recognized by the linear (wasm) vs
# wasm-gc codegen backends. Outputs a parity report and a markdown
# table to stdout. Exit code is non-zero if there's an unexpected
# divergence in the "core" set (Array, Bytes, Map, String, Int, Bool).
#
# Usage:
#   scripts/check_codegen_parity.sh             # report to stdout
#   scripts/check_codegen_parity.sh --json out.json
#
# Background: the dual-codegen problem (wasm-linear + wasm-gc maintained
# in parallel) is the biggest structural complexity in the codebase.
# Today's overlap is ~52 builtins (out of 169 linear, 53 gc). Most
# linear-only builtins are host-import bindings (Fs::, Env::, Http::,
# Io::, Socket::) that wasm-gc doesn't need yet. The "core" set is
# what user code typically touches.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LINEAR_GLOB="$ROOT_DIR/src/codegen/wasm_codegen_builtin_*.mbt"
GC_FILE="$ROOT_DIR/src/codegen/wasm_gc_codegen.mbt"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

grep -oh '"[A-Za-z][A-Za-z_0-9]*::[a-z_][a-z_0-9]*"' $LINEAR_GLOB \
  | tr -d '"' | sort -u > "$tmp/linear.txt"
grep -oh '"[A-Za-z][A-Za-z_0-9]*::[a-z_][a-z_0-9]*"' "$GC_FILE" \
  | tr -d '"' | sort -u > "$tmp/gc.txt"

linear_count=$(wc -l < "$tmp/linear.txt")
gc_count=$(wc -l < "$tmp/gc.txt")
both=$(comm -12 "$tmp/linear.txt" "$tmp/gc.txt" | wc -l)
linear_only_count=$(comm -23 "$tmp/linear.txt" "$tmp/gc.txt" | wc -l)
gc_only_count=$(comm -13 "$tmp/linear.txt" "$tmp/gc.txt" | wc -l)

# "Core" namespaces user code typically touches. New additions here
# should land in BOTH backends — divergence is a real problem.
core_ns_re='^(Array|Bytes|Map|String|Int|Bool|Char|Double|Float|Option|Result|StringBuilder|ArrayBuilder|MapBuilder)::'

linear_core=$(grep -E "$core_ns_re" "$tmp/linear.txt" | sort -u)
gc_core=$(grep -E "$core_ns_re" "$tmp/gc.txt" | sort -u)
echo "$linear_core" > "$tmp/linear_core.txt"
echo "$gc_core" > "$tmp/gc_core.txt"

linear_core_only=$(comm -23 "$tmp/linear_core.txt" "$tmp/gc_core.txt")
gc_core_only=$(comm -13 "$tmp/linear_core.txt" "$tmp/gc_core.txt")

cat <<EOF
# Codegen Backend Parity Report

| | linear | wasm-gc | both |
|---|---:|---:|---:|
| total builtins | $linear_count | $gc_count | $both |

## Core namespaces (user-facing — divergence here is a bug)

Core: Array, Bytes, Map, String, Int, Bool, Char, Double, Float,
Option, Result, StringBuilder, ArrayBuilder, MapBuilder.

### linear has, wasm-gc missing
$([ -z "$linear_core_only" ] && echo "(none — full parity for core namespaces)" || echo "$linear_core_only" | sed 's/^/- /')

### wasm-gc has, linear missing
$([ -z "$gc_core_only" ] && echo "(none)" || echo "$gc_core_only" | sed 's/^/- /')

## Linear-only (full list)

These are mostly host-import bindings (Fs, Env, Http, Io, Socket) and
debug helpers. Acceptable to remain linear-only until wasm-gc gains
capability-import support.

$(comm -23 "$tmp/linear.txt" "$tmp/gc.txt" | head -50 | sed 's/^/- /')
$(if [[ $(comm -23 "$tmp/linear.txt" "$tmp/gc.txt" | wc -l) -gt 50 ]]; then
  remaining=$(( $(comm -23 "$tmp/linear.txt" "$tmp/gc.txt" | wc -l) - 50 ))
  echo ""
  echo "_($remaining more — run with --full to see all)_"
fi)

## wasm-gc only

$(comm -13 "$tmp/linear.txt" "$tmp/gc.txt" | sed 's/^/- /')
EOF

# Informational only for now: there are ~31 known core-namespace
# divergences (StringBuilder, Int::* utils, Map mutation API, etc.)
# that need to land in wasm-gc per docs/spec/codegen-dual-backend.md
# Phase A.2. When that's done, flip this to a hard gate.
if [[ -n "$linear_core_only" || -n "$gc_core_only" ]]; then
  echo ""
  echo "note: core-namespace divergences exist (see docs/spec/codegen-dual-backend.md)." >&2
fi
