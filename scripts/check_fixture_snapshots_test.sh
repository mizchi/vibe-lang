#!/usr/bin/env bash
# Red test for check_fixture_snapshots.vibex. The cases live in the vibex
# (--self-test) so the mutation and the verdict stay in one program; this
# wrapper is the companion check_gate_self_tests.sh executes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
exec bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/check_fixture_snapshots.vibex -- --self-test
