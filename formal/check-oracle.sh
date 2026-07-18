#!/usr/bin/env bash
set -euo pipefail

formal_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
actual="$(mktemp)"
trap 'rm -f "$actual"' EXIT

cd "$formal_dir"
lake build --wfail
lake env lean --run OracleMain.lean > "$actual"
diff -u oracle/call-typing.tsv "$actual"
examples/selfhost-call-oracle-test.sh
