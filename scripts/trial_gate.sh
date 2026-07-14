#!/usr/bin/env bash
# selfhost-only (#594): the former trial gate ran host<->selfhost corpus parity
# and perf/RSS-vs-host benches (test_selfhost_corpus_gate.sh,
# bench_selfhost_perf.sh, bench_selfhost_rss.sh) plus the preview2/component
# release gates — all comparisons against the MoonBit host, retired with src/.
# The canonical moon-free gate is now scripts/compiler_gate.sh
# (bundle/module-source sync + seed->stage1->stage2->stage3 fixpoint +
# compile/run validation). Redirect here so existing entry points
# (gate.sh, the `full-gate` task) keep working. The old `selfhost-trial-gate`
# compat-alias task was removed in #850 Phase B (no live callers). The
# `--post-generation` flag is accepted and ignored (the gate runs its own
# staged generation).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/compiler_gate.sh"
