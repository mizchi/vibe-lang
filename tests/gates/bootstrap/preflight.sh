#!/usr/bin/env bash
# Fast, stage-independent bootstrap checks. CI runs this in parallel with the
# selfbuild; the local bootstrap lane invokes it before building.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

echo "[compiler-gate] 0/3 builtin parity (#415 B-3)"
bash scripts/check_builtin_parity.sh
bash scripts/check_gate_registry.sh
bash scripts/check_inline_builtin_capture.sh
node scripts/generate_runtime_fixture_tests.test.mjs
bash scripts/check_fixture_execution.sh
bash scripts/vibe_fmt_parse_guard_test.sh

echo "[compiler-gate] parser binder-context spine"
node --test scripts/parser_binder_context_spine.test.mjs
node scripts/test_immutable_publish_plumbing.js

echo "[compiler-gate] 1-2/3 generated compiler artifacts"
bash scripts/ensure_generated.sh

echo "[compiler-gate] 2a/3 FS heap measurement protocol"
bash scripts/measure_fs_heap_test.sh

echo "[compiler-gate] bootstrap preflight ok"
