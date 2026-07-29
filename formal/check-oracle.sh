#!/usr/bin/env bash
set -euo pipefail

formal_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
call_actual="$(mktemp)"
taxonomy_actual="$(mktemp)"
trap 'rm -f "$call_actual" "$taxonomy_actual"' EXIT

cd "$formal_dir"
lake build --wfail
lake env lean --run OracleMain.lean > "$call_actual"
diff -u oracle/call-typing.tsv "$call_actual"
lake env lean --run TaxonomyOracleMain.lean > "$taxonomy_actual"
diff -u oracle/effect-taxonomy.tsv "$taxonomy_actual"
examples/selfhost-call-oracle-test.sh
