#!/usr/bin/env bash
# Emit one tracing span around a command, and propagate W3C trace context to
# it. Step 0 of docs/tracing-design.md: the build is already a multi-process
# tree (generations.sh runs seed -> stage1 -> stage2 -> stage3 as separate
# compiles, unit_test_runner.sh fans out to hundreds of compile+run processes,
# doctest fans out again) and nothing today can see that tree as one thing --
# docs/ci-speed.md was assembled by summing per-shard wall_ms by hand.
#
#   scripts/trace_span.sh <name> <command> [args...]
#
# DISABLED BY DEFAULT. With VIBE_TRACE_OUT unset this is one string test and an
# exec, so it is safe to leave on call paths that run in the inner loop.
#
#   VIBE_TRACE_OUT=/tmp/build.ndjson pkf run test
#   node scripts/trace_report.mjs /tmp/build.ndjson
#
# Env:
#   VIBE_TRACE_OUT     NDJSON sink. Unset (or empty) disables tracing entirely.
#   VIBE_TRACEPARENT   W3C traceparent of the PARENT span, if any:
#                      00-<32hex trace_id>-<16hex span_id>-<2hex flags>.
#                      Absent at the root, where a fresh trace_id is minted.
#                      Exported to the child so nesting works across processes.
#
# One line per span, appended after the command exits:
#
#   {"tid":"<32hex>","sid":"<16hex>","pid":"<16hex>","name":"stage2",
#    "t0":<ns>,"t1":<ns>,"rc":0}
#
# `pid` is "" at the root. Concurrency: each line is a single short write to an
# O_APPEND fd, so parallel fan-out interleaves whole lines rather than
# splitting them -- which is why the record is written once at the end instead
# of as a begin/end pair.

set -uo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: scripts/trace_span.sh <name> <command> [args...]" >&2
  exit 2
fi

span_name="$1"
shift

# Fast path: tracing off. exec so this wrapper leaves no process behind.
if [ -z "${VIBE_TRACE_OUT:-}" ]; then
  exec "$@"
fi

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trace_lib.sh"

trace_begin "$span_name"
tok="$TRACE_TOKEN"
"$@"
rc=$?
trace_end "$tok" "$rc"
exit "$rc"
