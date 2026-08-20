#!/usr/bin/env bash
# Regression lock for the step-0 tracing helpers (docs/tracing-design.md):
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

if [ "$fails" -gt 0 ]; then
  echo "[trace-spans] $fails check(s) failed" >&2
  exit 1
fi
echo "[trace-spans] ok"
