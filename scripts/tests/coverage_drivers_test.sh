#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
VIBE_COVERAGE_DRIVERS_LIB_ONLY=1 source scripts/coverage_drivers.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
DRIVER_DIR="$TMP/driver"
mkdir -p "$DRIVER_DIR"
: > "$DRIVER_DIR/src.vibe"

# Every driver goes through exact-path exposure (#1633), so every driver must
# name the compiler values it uses with `import <exact file> { .. }`. A driver
# with no imports only ever worked under the deleted raw-concatenation lane,
# where it inherited whatever names the concatenation happened to expose; on the
# exposure lane it compiles against nothing and dies with `unknown name`.
driver_rows="$(grep -E '^run_driver ' scripts/coverage_drivers.sh | awk '{ print $2, $3, $4 }')"
[ -n "$driver_rows" ] || { echo "coverage_drivers_test: no run_driver rows found" >&2; exit 1; }
while read -r entry file label; do
  [ -f "$file" ] || { echo "coverage_drivers_test: $label driver missing: $file" >&2; exit 1; }
  grep -qE '^import [^ ]+\.vibe \{' "$file" || {
    echo "coverage_drivers_test: $label ($file) has no exact-file import" >&2
    exit 1
  }
  grep -qE "^export let $entry:" "$file" || {
    echo "coverage_drivers_test: $label ($file) does not export its entry $entry" >&2
    exit 1
  }
done <<< "$driver_rows"

# The one way a driver can still bind a compiler value WITHOUT asking for it:
# the production merge leaves the ENTRY file's own top-level names unrenamed
# (`transformed_file_stmts` returns the entry's statements as-is), so a bare
# call in a driver silently resolves to cli_adapter.vibe's copy. That is how
# `parse_int_or` -- which also exists, differently, in coverage_suite_lib.vibe
# -- was measured without anyone naming it. Every such reference must be an
# explicit import, so the driver says which copy it measures.
python3 - "$driver_rows" <<'PY' || exit 1
import re, sys

entry_path = "lib/@vibe/compiler/cli_adapter.vibe"
entry_names = set()
for line in open(entry_path, encoding="utf-8"):
    m = re.match(r'(?:export\s+)?(?:fn|let\s+rec|let\s+mut|let)\s+([A-Za-z_][A-Za-z0-9_]*)', line)
    if m:
        entry_names.add(m.group(1))

bad = []
for row in sys.argv[1].splitlines():
    if not row.strip():
        continue
    _entry, path, label = row.split()
    src = open(path, encoding="utf-8").read()
    imported = set()
    for m in re.finditer(r'^import [^\{]*\{([^\}]*)\}', src, re.M):
        for item in m.group(1).split(","):
            parts = item.split()
            if parts:
                imported.add(parts[0])
                if len(parts) == 3:
                    imported.add(parts[2])
    body = re.sub(r'^import [^\{]*\{[^\}]*\}', '', src, flags=re.M)
    body = re.sub(r'//[^\n]*', '', body)
    local = set(re.findall(r'\b(?:let|fn)\s+(?:rec\s+|mut\s+)?([A-Za-z_][A-Za-z0-9_]*)', body))
    for name in sorted(set(re.findall(r'(?<![:.\w])([A-Za-z_][A-Za-z0-9_]*)\s*\(', body))):
        if name in entry_names and name not in imported and name not in local:
            bad.append(f"{label} ({path}): bare `{name}` binds to {entry_path}'s copy; import it explicitly")
for line in bad:
    print("coverage_drivers_test: " + line, file=sys.stderr)
sys.exit(1 if bad else 0)
PY

# The raw-concatenation lane and its truncated walk are gone; nothing may bring
# a `merged_nodce` base back without also revisiting this test.
if grep -q 'merged_nodce' scripts/coverage_drivers.sh; then
  echo "coverage_drivers_test: legacy merged_nodce base reintroduced" >&2
  exit 1
fi
if grep -Eq 'VIBE_COV_FLAT|cat .*FLAT' scripts/coverage_driver.sh scripts/coverage_unittests.sh; then
  echo "coverage_drivers_test: legacy raw flat concatenation remains" >&2
  exit 1
fi
grep -q 'VIBE_COV_DRIVER_FILTER=driver' scripts/coverage_driver.sh || {
  echo "coverage_drivers_test: singular compatibility wrapper does not select driver" >&2
  exit 1
}

# A sidecar diagnostic is deterministic: one attempt and a nonzero status.
deterministic_attempts=0
coverage_driver_compile_once() {
  deterministic_attempts=$((deterministic_attempts + 1))
  printf 'unknown name: db_new\n' > "$1/m.wasm.diag"
  return 1
}
status=0
coverage_driver_compile_with_retries "$DRIVER_DIR" main || status=$?
[ "$status" = 2 ]
[ "$deterministic_attempts" = 1 ]
[ "$COVERAGE_DRIVER_COMPILE_ATTEMPTS" = 1 ]

# A diagnostic-free transient failure remains retryable and may succeed on the
# sixth and final attempt.
transient_attempts=0
coverage_driver_compile_once() {
  transient_attempts=$((transient_attempts + 1))
  if [ "$transient_attempts" = 6 ]; then
    printf 'wasm' > "$1/m.wasm"
    return 0
  fi
  return 1
}
coverage_driver_compile_with_retries "$DRIVER_DIR" main
[ "$transient_attempts" = 6 ]
[ "$COVERAGE_DRIVER_COMPILE_ATTEMPTS" = 6 ]

# A persistent diagnostic-free host failure stops after exactly six attempts.
host_attempts=0
coverage_driver_compile_once() {
  host_attempts=$((host_attempts + 1))
  return 1
}
status=0
coverage_driver_compile_with_retries "$DRIVER_DIR" main || status=$?
[ "$status" = 1 ]
[ "$host_attempts" = 6 ]
[ "$COVERAGE_DRIVER_COMPILE_ATTEMPTS" = 6 ]

echo 'coverage_drivers_test: ok'
