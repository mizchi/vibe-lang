#!/usr/bin/env bash
# RC bootstrap gate (#556).
#
# History / why this looks different from the issue:
#   The original gate compared the whole-compiler self-compile under the RC
#   (Perceus, ADR-0055) backend against the legacy non-RC "default" backend and
#   required both to fail with the SAME signature (parity HOLDS). The RC path
#   trapped in `analyze_calls` (deep recursive-descent exhausting the wasm stack)
#   before reaching the default path's `EnvCached` ceiling, so the signatures
#   diverged and the gate failed.
#
#   After the selfhost-only / RC-canonical cutover (#594) there is no separate
#   non-RC backend, and the entire pre-cutover RC tooling (this script plus
#   rc_cutover_readiness.sh / verify_selfhost_rc.sh) was removed. The
#   RC-vs-default parity premise is therefore obsolete.
#
# What this modern replacement asserts:
#   The whole compiler still compiles AS ONE MERGED UNIT under RC -- exactly the
#   scenario where #556's `analyze_calls` recursion blew the stack -- and the
#   result is a byte-exact self-build fixpoint (stage2 == stage3). The
#   `analyze_calls` pass is now iterative over the let/seq spine (#681), so the
#   deep-recursion trap can no longer occur; this gate guards that.
#
# Cheap mode: point VIBE_SELFHOST_RC_BOOTSTRAP_REUSE_GEN at an existing
# generation.json (e.g. one the release gate just produced) to assert on it
# without rebuilding.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

OUT_DIR="${VIBE_SELFHOST_RC_BOOTSTRAP_OUT_DIR:-_build/rc_bootstrap_gate}"
reuse="${VIBE_SELFHOST_RC_BOOTSTRAP_REUSE_GEN:-}"

if [ -n "$reuse" ] && [ -f "$reuse" ]; then
  gen_json="$reuse"
  echo "[rc-bootstrap] reusing existing generation manifest: $gen_json"
else
  gen_json="$OUT_DIR/generation.json"
  echo "[rc-bootstrap] building whole compiler under RC (stage0 seed -> stage1 -> stage2 -> stage3)"
  rm -f _build/vibe_selfhost_*.tsv
  bash scripts/selfhost_generations.sh build --stage3 --out-dir "$OUT_DIR"
fi

[ -f "$gen_json" ] || {
  echo "[rc-bootstrap] FAIL: no generation manifest at $gen_json (whole-compiler RC compile did not complete -- a deep-recursion / stack trap in this stage is the #556 failure mode)" >&2
  exit 1
}

fixpoint="$(python3 - "$gen_json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# Two manifest shapes are in use: an explicit result flag, and a stage sha pair.
r = d.get("result", {}).get("stage3_equal_stage2")
if r is None:
    s = d.get("stages", {})
    s2 = s.get("stage2", {}).get("sha256")
    s3 = s.get("stage3", {}).get("sha256")
    r = bool(s2) and bool(s3) and s2 == s3
print("True" if r is True else ("True" if r == "True" else "False"))
PY
)"
if [ "$fixpoint" != "True" ]; then
  echo "[rc-bootstrap] FAIL: whole-compiler-under-RC did not reach a stage2==stage3 fixpoint (got: $fixpoint)" >&2
  exit 1
fi

echo "[rc-bootstrap] OK: whole compiler compiles as one unit under RC; stage2==stage3 fixpoint holds"
