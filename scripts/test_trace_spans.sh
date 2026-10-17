#!/usr/bin/env bash
# Regression lock for the step-0 tracing helpers (docs/internal/compiler/tracing-design.md):
# scripts/trace_lib.sh, scripts/trace_span.sh, scripts/trace_report.mjs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
bad() { echo "[trace-spans] FAIL: $*" >&2; fails=$((fails + 1)); }

# 1. Disabled by default: no sink, no file, and the command still runs.
out="$(bash scripts/trace_span.sh noop echo hello 2>&1)"
[ "$out" = "hello" ] || bad "disabled: expected the command's own output, got: $out"
[ -z "$(ls -A "$work")" ] || bad "disabled: wrote something into the work dir"

# 2. Exit code passes through, and a failure is RECORDED rather than dropped --
#    a tracer that only logs successes makes a red build look like a short one.
T="$work/rc.ndjson"
VIBE_TRACE_OUT="$T" bash scripts/trace_span.sh boom sh -c 'exit 3'
rc=$?
[ "$rc" = "3" ] || bad "exit code not propagated: got $rc, want 3"
grep -q '"name":"boom"' "$T" || bad "failing span not recorded"
grep -q '"rc":3' "$T" || bad "failing span did not record rc=3"

# 3. Nesting: a child span parents to its enclosing span, and two children of
#    the same parent stay SIBLINGS. This is the part that breaks if
#    trace_begin's export happens in a subshell -- the tree comes out flat.
T="$work/tree.ndjson"
VIBE_TRACE_OUT="$T" bash scripts/trace_span.sh outer bash -c "
  VIBE_TRACE_OUT='$T' bash scripts/trace_span.sh inner1 true
  VIBE_TRACE_OUT='$T' bash scripts/trace_span.sh inner2 true
" || bad "nested run failed"
span_count="$(wc -l < "$T" | tr -d '[:space:]')"
[ "$span_count" = "3" ] || bad "expected 3 spans, got $span_count"
outer_sid="$(sed -n 's/.*"sid":"\([0-9a-f]*\)","pid":"","name":"outer".*/\1/p' "$T")"
[ -n "$outer_sid" ] || bad "outer span is not a root (empty pid)"
for child in inner1 inner2; do
  pid="$(sed -n "s/.*\"pid\":\"\([0-9a-f]*\)\",\"name\":\"$child\".*/\1/p" "$T")"
  [ "$pid" = "$outer_sid" ] || bad "$child parented to '$pid', want outer '$outer_sid'"
done
trace_count="$(cut -d'"' -f4 < "$T" | sort -u | wc -l | tr -d '[:space:]')"
[ "$trace_count" = "1" ] || bad "spans span more than one trace id"

# 4. A malformed inherited traceparent starts a NEW trace instead of
#    propagating a bogus id -- reparenting everything under a wrong trace is
#    worse than an honest split.
T="$work/bad.ndjson"
VIBE_TRACEPARENT="garbage" VIBE_TRACE_OUT="$T" bash scripts/trace_span.sh solo true
grep -q '"pid":""' "$T" || bad "malformed traceparent did not produce a root span"

# 5. The report renders the tree and finds the critical path.
T="$work/rep.ndjson"
VIBE_TRACE_OUT="$T" bash scripts/trace_span.sh top bash -c "
  VIBE_TRACE_OUT='$T' bash scripts/trace_span.sh slow sleep 0.3
  VIBE_TRACE_OUT='$T' bash scripts/trace_span.sh fast true
" || bad "report fixture run failed"
rep="$(node scripts/trace_report.mjs "$T" 2>&1)"
grep -q "critical path" <<<"$rep" || bad "report has no critical path section"
grep -q "slow" <<<"$rep" || bad "report does not mention the slow span"

# 6. Measurement mode uses a monotonic clock even when date goes backwards.
# Only the tracer's timestamp call is poisoned; unrelated date uses keep their
# ordinary behavior. Removing the monotonic branch must redden this probe.
mkdir "$work/bin"
real_date="$(command -v date)"
cat > "$work/bin/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = '+%s%N' ]; then
  if [ -f "$TRACE_DATE_SEEN" ]; then echo 100; else echo 200; fi
  : > "$TRACE_DATE_SEEN"
else
  exec "$TRACE_REAL_DATE" "$@"
fi
SH
chmod +x "$work/bin/date"
T="$work/monotonic.ndjson"
PATH="$work/bin:$PATH" TRACE_REAL_DATE="$real_date" TRACE_DATE_SEEN="$work/date-seen" \
  VIBE_TRACE_MONOTONIC=1 VIBE_TRACE_OUT="$T" \
  bash scripts/trace_span.sh measured sleep 0.05 || bad "monotonic run failed"
[ ! -f "$work/date-seen" ] || bad "monotonic tracing consulted realtime date"
python3 - "$T" <<'PY' || bad "monotonic span was not labelled or bounded"
import json, sys
r = json.loads(open(sys.argv[1]).read())
assert r['clock'] == 'monotonic'
assert 0.04 <= (r['t1'] - r['t0']) / 1e9 < 10
PY

# 7. A tree with incompatible clock origins has no honest duration report.
cat > "$work/mixed.ndjson" <<'JSON'
{"tid":"x","sid":"a","pid":"","name":"outer","t0":100000000000,"t1":110000000000,"rc":0}
{"tid":"x","sid":"b","pid":"a","name":"inner","t0":1000,"t1":2000,"rc":0,"clock":"monotonic"}
JSON
if node scripts/trace_report.mjs "$work/mixed.ndjson" >"$work/mixed.out" 2>&1; then
  bad "a report with mixed clocks was accepted"
fi
grep -q 'incompatible clocks' "$work/mixed.out" || bad "mixed-clock refusal did not explain the cause"

if [ "$fails" -gt 0 ]; then
  echo "[trace-spans] $fails check(s) failed" >&2
  exit 1
fi
echo "[trace-spans] ok"
