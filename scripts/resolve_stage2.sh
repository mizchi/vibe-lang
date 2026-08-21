#!/usr/bin/env bash
# Which compiler should a gate ask? -- shared resolution for the checks that
# probe the compiler (AGENTS.md, "Which compiler answered?").
#
# `ls -td` picks the newest generation by MTIME, which is not the same question
# as "the compiler built from this checkout". On a reused workspace an
# unrelated generation can be newer, and a concurrent build touches
# directories; either way the gate certifies a compiler that does not contain
# the change, and is green about it (#2138 review).
#
# Order: explicit override > the generation whose directory carries HEAD's
# short sha (what generations.sh encodes) > newest > committed seed. Every step
# past the first says on stderr what it settled for, so a fallback is never
# silent.
#
#   STAGE2="$(resolve_stage2 rc-default "${RC_DEFAULT_STAGE2:-}")"
resolve_stage2() { # <label> <override>
  local label="$1" override="${2:-}" gen sha
  if [ -n "$override" ]; then
    [ -f "$override" ] || { echo "$label: override does not exist: $override" >&2; return 1; }
    printf '%s\n' "$override"
    return 0
  fi
  sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
  if [ -n "$sha" ]; then
    for gen in _build/selfhost/generations/*_"$sha"/; do
      [ -s "${gen}stage2.wasm" ] || continue
      printf '%s\n' "${gen}stage2.wasm"
      return 0
    done
  fi
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    [ -s "${gen}stage2.wasm" ] || continue
    echo "$label: NOTE no generation for HEAD (${sha:-unknown}); using the newest one, ${gen}" >&2
    printf '%s\n' "${gen}stage2.wasm"
    return 0
  done
  if [ -s "bootstrap/seed/compiler.wasm" ]; then
    echo "$label: NOTE no generation at all; falling back to the committed SEED." >&2
    echo "$label:   A change under lib/@vibe is NOT in that compiler -- build one with" >&2
    echo "$label:   'pkf run generation' if this gate is meant to see it." >&2
    printf '%s\n' "bootstrap/seed/compiler.wasm"
    return 0
  fi
  echo "$label: no compiler available" >&2
  return 1
}
