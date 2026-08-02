#!/usr/bin/env bash
# Regenerate the bounded Incremental.lean corpus and reject snapshot drift.
# This validates only the relational model corpus; it never claims current
# compiler decisions are formal conformance.
set -euo pipefail

formal_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
actual="$(mktemp)"
trap 'rm -f "$actual"' EXIT

cd "$formal_dir"
lake build --wfail VibeFormal.Proofs.IncrementalCorrect
lake env lean --run IncrementalOracleMain.lean > "$actual"
diff -u oracle/incremental-invalidation.tsv "$actual"
node ../scripts/incremental_invalidation_oracle.mjs --check-oracle oracle/incremental-invalidation.tsv
echo "[incremental-oracle] corpus current"
