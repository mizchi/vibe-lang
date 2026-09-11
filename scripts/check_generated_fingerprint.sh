#!/usr/bin/env bash
# The generated-artifact fingerprint must not depend on HOW the script was
# called, or on where the checkout lives.
#
# scripts/ensure_generated.sh keys the five generated compiler artifacts on a
# fingerprint of its inputs, and CI keys the `gen-v1-<fp>` cache on the same
# value. `sha256sum FILE` prints "<hash>  <FILE>", so a fingerprint line built
# from "${BASH_SOURCE[0]}" recorded the CALLER'S SPELLING: the workflow's
# `bash scripts/ensure_generated.sh` and build_compile_only.sh's
# `bash "$ROOT_DIR/scripts/ensure_generated.sh"` hashed identical bytes and
# disagreed.
#
# Measured on CI run 34590373673: compiler-contracts and compiler-stage2-oracles
# each downloaded the artifacts from compiler-build, passed the "up to date"
# assertion in .github/actions/use-compiler-build, and then regenerated all five
# anyway -- 128s and 131s, 187s of the contracts job's 202s. `.generated.inputs`
# named the cause exactly: one differing line whose hash was IDENTICAL on both
# sides, differing only in the path spelling.
#
# This is the cheap, decidable form of that question: compute the fingerprint
# both ways and require the same answer. ~2.5s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# Overridable so the companion self-test can point this at a mutated copy.
TARGET="${VIBE_GENERATED_FINGERPRINT_SCRIPT:-$SCRIPT_DIR/ensure_generated.sh}"

if [ ! -f "$TARGET" ]; then
  echo "[generated-fingerprint] FAIL: no such script: $TARGET" >&2
  exit 1
fi

rel="$(cd "$ROOT_DIR" && printf '%s' "${TARGET#"$ROOT_DIR/"}")"
if [ "$rel" = "$TARGET" ]; then
  # Not under the repo root, so a relative spelling is not available and the
  # comparison this gate exists to make cannot be made. Silence would be
  # indistinguishable from a pass, so it is an error.
  echo "[generated-fingerprint] FAIL: $TARGET is not under $ROOT_DIR -- the" >&2
  echo "  relative-spelling half of the comparison cannot be computed." >&2
  exit 1
fi

as_relative="$(cd "$ROOT_DIR" && bash "$rel" --print-fingerprint)" || {
  echo "[generated-fingerprint] FAIL: --print-fingerprint failed via '$rel'" >&2
  exit 1
}
as_absolute="$(cd "$ROOT_DIR" && bash "$ROOT_DIR/$rel" --print-fingerprint)" || {
  echo "[generated-fingerprint] FAIL: --print-fingerprint failed via '$ROOT_DIR/$rel'" >&2
  exit 1
}

if [ -z "$as_relative" ]; then
  echo "[generated-fingerprint] FAIL: --print-fingerprint produced nothing -- an" >&2
  echo "  empty answer would compare equal to itself and pass vacuously." >&2
  exit 1
fi

if [ "$as_relative" != "$as_absolute" ]; then
  echo "[generated-fingerprint] FAIL: the fingerprint depends on how the script was called." >&2
  echo "  bash $rel                 -> $as_relative" >&2
  echo "  bash \$PWD/$rel -> $as_absolute" >&2
  echo "  Every job that reaches ensure_generated.sh by the other spelling misses" >&2
  echo "  the gen-v1 cache and regenerates all five artifacts (~130s), even after" >&2
  echo "  downloading them from compiler-build." >&2
  echo "  Record each hashed file under a FIXED name instead of the path it was" >&2
  echo "  reached by -- see hash_as() in scripts/ensure_generated.sh." >&2
  exit 1
fi

echo "[generated-fingerprint] ok (invocation-independent: $as_relative)"
