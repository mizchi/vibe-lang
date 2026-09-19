#!/usr/bin/env bash
# Companion for check_host_runtime_contract.py (#2248).
#
# The mutation suite itself is Python and predates this rule, living at
# tests/gates/tooling-accounting/host-runtime/host_runtime_contract_test.py --
# where Taskfile.pkl and tests/gates/mid/run.sh already run it. This is the
# `_test.sh` spelling check_gate_self_tests.sh discovers, and it RUNS that
# suite rather than standing in for it: the gate's rule is that a companion is
# executed, not that a file with the right name exists.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
exec python3 tests/gates/tooling-accounting/host-runtime/host_runtime_contract_test.py
