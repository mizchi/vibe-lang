#!/usr/bin/env bash
# Mutate real oracle inputs, using the real compiler and runner throughout.
# Green first prevents a broken compiler or harness from certifying red cases.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 imported-show-metadata-oracle-test "${VIBE_STAGE2_WASM:-}")"
case "$STAGE2" in /*) ;; *) STAGE2="$ROOT_DIR/$STAGE2" ;; esac
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_show_metadata_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export SHOW_METADATA_REAL_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
export SHOW_METADATA_MUTATION_RECEIPT="$WORK/applied"

cat > "$WORK/mutating-runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--invoke" ] && [ "${2:-}" = "cli_main" ]; then
  output=""
  for arg in "$@"; do case "$arg" in *.wasm) output="$arg" ;; esac; done
  label="$(basename "$output" .wasm)"
  if [ "$SHOW_METADATA_MUTATION" = "render" ] && [ "$label" = "cold" ]; then
    python3 - <<'PY'
from pathlib import Path
import os
p = Path('leaf.vibe')
s = p.read_text()
before = 'export fn render[T](value: T) -> String { __to_string(value) }'
after = 'export fn render[T](value: T) -> String { "wrong" }'
assert s.count(before) == 1
p.write_text(s.replace(before, after, 1))
assert p.read_text() != s and after in p.read_text()
Path(os.environ['SHOW_METADATA_MUTATION_RECEIPT']).write_text('render')
PY
  elif [ "$SHOW_METADATA_MUTATION" = "reuse" ] && [ "$label" = "warm" ]; then
    # A real warm compile with artifact reuse disabled must not certify reuse.
    export VIBE_CHECKED_MODULE_CACHE=off
    printf reuse > "$SHOW_METADATA_MUTATION_RECEIPT"
  elif [ "$SHOW_METADATA_MUTATION" = "body-edit" ] && [ "$label" = "body-edit" ]; then
    python3 - <<'PY'
from pathlib import Path
import os
p = Path('leaf.vibe')
s = p.read_text()
before = 'export fn mono(value: Bool) -> String { "plain" }'
after = 'export fn mono(value: Bool) -> String { __to_string(value) }'
assert s.count(before) == 1
p.write_text(s.replace(before, after, 1))
assert p.read_text() != s and after in p.read_text()
Path(os.environ['SHOW_METADATA_MUTATION_RECEIPT']).write_text('body-edit')
PY
  fi
fi
exec bash "$SHOW_METADATA_REAL_RUNNER" "$@"
RUNNER

node scripts/imported_show_wrapper_metadata_oracle.mjs "$STAGE2" > "$WORK/green.log" 2>&1 || {
  cat "$WORK/green.log" >&2; exit 1;
}
echo "ok   real compiler passes the unmutated rendering/reuse/body-edit oracle"

red() {
  local mutation="$1" expected="$2"
  rm -f "$SHOW_METADATA_MUTATION_RECEIPT"
  if SHOW_METADATA_MUTATION="$mutation" VIBE_SHOW_METADATA_ORACLE_RUNNER="$WORK/mutating-runner.sh" \
      node scripts/imported_show_wrapper_metadata_oracle.mjs "$STAGE2" > "$WORK/red.log" 2>&1; then
    echo "FAIL oracle accepted $mutation mutation" >&2; exit 1
  fi
  if [ "$(cat "$SHOW_METADATA_MUTATION_RECEIPT" 2>/dev/null || true)" != "$mutation" ] || \
      ! grep -qF "$expected" "$WORK/red.log"; then
    cat "$WORK/red.log" >&2
    echo "FAIL mutation did not land or failed on the wrong assertion: $mutation" >&2; exit 1
  fi
  echo "ok   real $mutation mutation is rejected by its assertion"
}
red render "compiled render assertions failed"
red reuse "warm compile did not reuse checked modules"
red body-edit "compiled render result"
echo "imported Show metadata oracle self-test: ok (real green + three real red cases)"
