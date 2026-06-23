#!/usr/bin/env bash
# Moon-free selfhost-only gate (#594 Stage 5): the post-`src/`-removal sign-off.
# Needs no MoonBit host — only the committed seed, the Rust runner, and the
# committed selfhost compiler source/bundles. Verifies:
#   1. committed bundles are in sync with the compiler source,
#   2. the committed flat module source is in sync (regenerated via the seed),
#   3. the selfhost compiler self-reproduces moon-free (seed -> stage1 -> stage2
#      -> stage3) with stage2 == stage3 (fixpoint) and each stage validates a
#      compiled sample (compile -> run smoke).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo "[selfhost-only-gate] 1/3 bundle sync"
bash scripts/check_selfhost_bundle_sync.sh

echo "[selfhost-only-gate] 2/3 module-source sync (via seed)"
bash scripts/check_selfhost_module_source_sync.sh

echo "[selfhost-only-gate] 3/3 moon-free selfbuild seed->stage1->stage2->stage3"
bash scripts/selfhost_generations.sh build --stage3

# Assert the stage2==stage3 fixpoint from the freshest generation manifest.
latest_gen="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1 || true)"
if [ -z "$latest_gen" ] || [ ! -f "${latest_gen}generation.json" ]; then
  echo "[selfhost-only-gate] FAIL: no generation manifest produced" >&2
  exit 1
fi
python3 - "${latest_gen}generation.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d.get("stages", {})
s2 = s.get("stage2", {}).get("sha256")
s3 = s.get("stage3", {}).get("sha256")
if not s2 or not s3:
    print("[selfhost-only-gate] FAIL: missing stage2/stage3 sha", file=sys.stderr); sys.exit(1)
if s2 != s3:
    print(f"[selfhost-only-gate] FAIL: stage2 != stage3 ({s2[:12]} != {s3[:12]})", file=sys.stderr); sys.exit(1)
print(f"[selfhost-only-gate] fixpoint ok: stage2==stage3 ({s2[:12]})")
PY

echo "[selfhost-only-gate] ok"
