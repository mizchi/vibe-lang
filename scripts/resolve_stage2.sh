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

# The fallback a script runs when its caller named no compiler, for a script
# that keeps its own override handling and its own message for "none found"
# (#3866). It replaces `ls -t _build/selfhost/generations/*/stage2.wasm |
# head -1`, which answered with whichever generation was built last, silently.
#
# Order: the generation built from <root>'s HEAD > the newest one on disk,
# announced on stderr > nothing (status 1, no message). It does not fall back
# to the seed; `resolve_stage2_generation_or_seed` does, for the scripts that
# always did. Paths are absolute under <root>, so a script that changes
# directory afterwards still holds a path that resolves.
#
#   COMPILER="$(resolve_stage2_generation async-gate "$PROJECT_ROOT")" || COMPILER=""
resolve_stage2_generation() { # <label> <root>
  local label="$1" root="$2" gen sha
  sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)"
  if [ -n "$sha" ]; then
    for gen in "$root"/_build/selfhost/generations/*_"$sha"/; do
      [ -s "${gen}stage2.wasm" ] || continue
      printf '%s\n' "${gen}stage2.wasm"
      return 0
    done
  fi
  # The one place besides `resolve_stage2` that still asks "which is newest?",
  # and it says so.
  for gen in $(ls -td "$root"/_build/selfhost/generations/*/ 2>/dev/null); do
    [ -s "${gen}stage2.wasm" ] || continue
    echo "$label: NOTE no generation for HEAD (${sha:-unknown}); using the newest one, ${gen}" >&2
    printf '%s\n' "${gen}stage2.wasm"
    return 0
  done
  return 1
}

# `resolve_stage2_generation`, then the committed seed under <root>, announced.
#
#   COMPILER="$(resolve_stage2_generation_or_seed async-gate "$PROJECT_ROOT")" || COMPILER=""
resolve_stage2_generation_or_seed() { # <label> <root>
  local label="$1" root="$2"
  resolve_stage2_generation "$label" "$root" && return 0
  if [ -s "$root/bootstrap/seed/compiler.wasm" ]; then
    echo "$label: NOTE no generation at all; falling back to the committed SEED." >&2
    echo "$label:   A change under lib/@vibe is NOT in that compiler -- build one with" >&2
    echo "$label:   'pkf run generation' if this run is meant to see it." >&2
    printf '%s\n' "$root/bootstrap/seed/compiler.wasm"
    return 0
  fi
  return 1
}

# The same question with no fallback, for a MEASUREMENT.
#
# A gate that answers from the wrong compiler is wrong; a measurement that does
# is worse, because its output is a number nobody can tell apart from a right
# one. `resolve_stage2` degrades on purpose -- a check is usually better run
# against something than not run -- and it says so on stderr. A promotion
# report is not: "wall 0.44x" carries no NOTE with it into the issue thread it
# gets pasted in (#2836 §1).
#
# So this one accepts exactly two answers: the artifact the caller named, or
# the generation built from HEAD. Nothing else, and no stderr note in place of
# a refusal. The pkfire task that runs such a script carries
# `deps { selfhostGeneration }`, which is what makes the second answer exist;
# without it this refuses rather than measuring whatever was lying around.
#
# What it does NOT promise: generation directories are named for HEAD's short
# sha, not for a hash of the sources, so a generation built before an
# uncommitted edit still matches. Going through `pkf run` closes that -- the
# generation task is `cache = false` and rebuilds from the working tree -- and
# running the script by hand after editing does not. Same gap as the lenient
# resolver has; naming it here so the refusals above are not read as more than
# they are.
#
#   STAGE2="$(resolve_stage2_strict incremental-kpi "${VIBE_STAGE2_WASM:-}")" || exit 1
resolve_stage2_strict() { # <label> <override>
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
  echo "$label: no generation for HEAD (${sha:-not a git checkout})." >&2
  echo "$label:   Build one with 'pkf run generation', or name the artifact to" >&2
  echo "$label:   measure with VIBE_STAGE2_WASM=<path>." >&2
  echo "$label:   Refusing the newest generation on disk and the committed seed:" >&2
  echo "$label:   measuring another compiler is not a weaker measurement, it is a" >&2
  echo "$label:   number about something else, and the report cannot say so." >&2
  return 1
}
