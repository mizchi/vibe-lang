#!/usr/bin/env bash
# Real task/lane execution ownership; compiler payloads are instrumented fixtures.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 "$ROOT_DIR/tests/gates/release_selftests_test.py"
