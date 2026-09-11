#!/usr/bin/env bash
# The pkfire pin is one value, declared once, and honoured (#2645 follow-up).
#
# `uses: mizchi/pkfire@vX` names the ACTION's ref, not the pkf release it
# installs. The action resolves the release from an input, and with none passed
# it falls through to "latest" -- so CI ran `pkfire@0.16.0` under a ref that
# said v0.14.2, on every job, silently (measured on run 34567587111). Three
# places declared a version and none of them matched what ran.
#
# .github/pkfire-version is now the single value. This gate checks, lexically,
# that every declaration agrees with it:
#
#   - each `uses: mizchi/pkfire@vX` ref
#   - each `version:` input passed to that action
#   - .claude/hooks/session-start.sh, which must READ the file rather than
#     hardcode a number (a hardcoded one drifts exactly the way this bug did)
#
# What it cannot check is what the action actually installs -- only CI can see
# that, which is why each workflow also asserts `pkf version` after installing.
#
# The `uses:` scan is ANCHORED to the start of a line so this gate cannot read
# its own prose: the first draft matched the example inside the comment above
# and reported a call site pinned at "vX". That is the #2138 shape -- a checker
# counting its own text as evidence -- and a comment is exactly where it hides.
set -euo pipefail

ROOT_DIR="${VIBE_PKFIRE_PIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT_DIR"

PIN_FILE=".github/pkfire-version"
if [ ! -s "$PIN_FILE" ]; then
  echo "[pkfire-pin] FAIL: no $PIN_FILE -- it is the single source of the pin" >&2
  exit 1
fi
want="$(tr -d '[:space:]' < "$PIN_FILE")"
case "$want" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "[pkfire-pin] FAIL: $PIN_FILE is not a version: '$want'" >&2; exit 1 ;;
esac

rc=0
refs=0
withs=0

# ASK THE YAML, DO NOT APPROXIMATE IT (Codex, 4th round on this gate).
#
# Three rounds of lexical refinement each fixed one case and left the next:
#   aggregate counts  -> a neighbouring step's input satisfied the total
#   per-step window   -> `env: { version: ... }` satisfied the window
#   with: + indent    -> a BLOCK SCALAR containing the text `version: 0.14.2`
#                        satisfied the indent check, because YAML reads it as
#                        string content and a scanner cannot tell the difference
#
# Each round was the same mistake at a finer grain: writing a lexical
# approximation of a structural question. So this parses the file and asks
# whether `with.version` is a real mapping entry of the step that carries the
# `uses:`. Comments, block scalars, env:, and neighbouring steps all stop being
# special cases -- the parser already knows.
#
# A missing PyYAML is FATAL, not a pass: a gate that degrades quietly when its
# dependency is absent is the failure mode this whole file exists to prevent.
scan="$(python3 - "$want" <<'PYEOF' || echo "__PYFAIL__"
import os, sys
try:
    import yaml
except ImportError:
    sys.stderr.write(
        "[pkfire-pin] FAIL: PyYAML is required to parse the workflows.\n"
        "  Install it with: python3 -m pip install pyyaml\n"
        "  CI provisions it in the structural-lint job. This gate parses the\n"
        "  workflows rather than scanning them, because four rounds of lexical\n"
        "  approximation each missed a different case.\n"
    )
    sys.exit(1)

want = sys.argv[1]

def steps_of(node):
    """Every `steps:` list anywhere in the document (jobs.*.steps, runs.steps)."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "steps" and isinstance(v, list):
                yield v
            else:
                yield from steps_of(v)
    elif isinstance(node, list):
        for v in node:
            yield from steps_of(v)

for root, _, files in os.walk(".github"):
    for name in sorted(files):
        if not name.endswith((".yml", ".yaml")):
            continue
        path = os.path.join(root, name)
        try:
            with open(path, encoding="utf-8") as fh:
                doc = yaml.safe_load(fh)
        except Exception as exc:                      # noqa: BLE001
            sys.stderr.write(f"[pkfire-pin] FAIL: cannot parse {path}: {exc}\n")
            sys.exit(1)
        for steps in steps_of(doc):
            for step in steps:
                if not isinstance(step, dict):
                    continue
                uses = step.get("uses")
                if not isinstance(uses, str) or not uses.startswith("mizchi/pkfire@"):
                    continue
                ref = uses.split("@", 1)[1].strip()
                with_map = step.get("with")
                # A real mapping entry: not block-scalar text, not env:, not a
                # neighbour's input. `is` a dict is the whole check.
                if isinstance(with_map, dict) and str(with_map.get("version", "")).strip() == want:
                    verdict = "ok"
                else:
                    verdict = "missing"
                print(f"{path}:{ref}:{verdict}")
PYEOF
)"
if [ "$scan" = "__PYFAIL__" ]; then
  echo "[pkfire-pin] FAIL: the workflow scan could not run (see above)" >&2
  exit 1
fi

while IFS=: read -r file ref verdict; do
  [ -n "${file:-}" ] || continue
  refs=$((refs + 1))
  if [ "$ref" != "v$want" ]; then
    echo "[pkfire-pin] FAIL: $file pins the action at '$ref', $PIN_FILE says v$want" >&2
    rc=1
  fi
  if [ "$verdict" = "ok" ]; then
    withs=$((withs + 1))
  else
    echo "[pkfire-pin] FAIL: $file passes no 'with.version: $want' to mizchi/pkfire" >&2
    rc=1
  fi
done <<EOF
$scan
EOF

if [ "$refs" -eq 0 ]; then
  echo "[pkfire-pin] FAIL: found no 'uses: mizchi/pkfire@' at all -- the scan did not run" >&2
  exit 1
fi
if [ "$withs" -lt "$refs" ]; then
  echo "  Without the input the action installs 'latest' and the ref decides nothing." >&2
  rc=1
fi

# The hook must READ the pin, not restate it.
HOOK=".claude/hooks/session-start.sh"
if [ -f "$HOOK" ]; then
  if ! grep -q "pkfire-version" "$HOOK"; then
    echo "[pkfire-pin] FAIL: $HOOK does not read $PIN_FILE" >&2
    echo "  A second hardcoded version is how CI and local dev drifted apart." >&2
    rc=1
  fi
  if grep -qE '^PKF_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "$HOOK"; then
    echo "[pkfire-pin] FAIL: $HOOK hardcodes PKF_VERSION instead of reading $PIN_FILE" >&2
    rc=1
  fi
fi

[ "$rc" -eq 0 ] || exit 1
echo "[pkfire-pin] ok ($want; $refs call site(s), $withs pinned input(s))"
