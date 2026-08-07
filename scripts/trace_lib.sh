# Sourceable half of the step-0 tracing helpers (docs/tracing-design.md).
#
#   . scripts/trace_lib.sh
#   trace_begin "stage1 -> stage2"; tok="$TRACE_TOKEN"   # sets VIBE_TRACEPARENT
#   ...work...
#   trace_end "$tok" "$rc"
#
# Use this where the work is a shell FUNCTION (so it cannot be exec'd);
# scripts/trace_span.sh wraps it for the command-shaped call sites.
#
# DISABLED unless VIBE_TRACE_OUT is set: trace_begin then returns an empty
# token and trace_end returns immediately, so these are safe to leave on inner
# -loop paths.
#
# trace_begin saves the caller's VIBE_TRACEPARENT inside the token and
# trace_end restores it, so sibling spans at the same level stay siblings
# instead of chaining into each other.

trace_rand_hex() {
  local n="$1"
  if [ -r /dev/urandom ]; then
    od -An -tx1 -N "$(( (n + 1) / 2 ))" /dev/urandom | tr -d ' \n' | cut -c "1-$n"
  else
    printf '%0*x' "$n" "$(( (RANDOM << 15 | RANDOM) ^ $$ ))" | cut -c "1-$n"
  fi
}

trace_now_ns() {
  # date +%s%N is GNU; macOS date lacks %N and echoes a literal N.
  local t
  t="$(date +%s%N 2>/dev/null || true)"
  case "$t" in
    *N|'') python3 -c 'import time; print(time.time_ns())' ;;
    *) printf '%s' "$t" ;;
  esac
}

trace_json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Sets TRACE_TOKEN to "<trace_id> <span_id> <parent_span_id|.> <t0> <saved_traceparent|.> <name>"
# and exports VIBE_TRACEPARENT for children. Assigns rather than echoing on
# purpose: `tok=$(trace_begin ...)` would run the export inside a subshell, so
# the child process would inherit the PARENT's traceparent and the tree would
# come out flat.
trace_begin() {
  TRACE_TOKEN=""
  [ -n "${VIBE_TRACE_OUT:-}" ] || return 0
  local name="$1"
  local parent_tid="" parent_sid=""
  # A malformed inherited traceparent is treated as ABSENT, not propagated: a
  # wrong trace_id silently reparents everything under it, which is worse than
  # starting a new trace.
  case "${VIBE_TRACEPARENT:-}" in
    00-????????????????????????????????-????????????????-??)
      parent_tid="$(printf '%s' "$VIBE_TRACEPARENT" | cut -d- -f2)"
      parent_sid="$(printf '%s' "$VIBE_TRACEPARENT" | cut -d- -f3)"
      ;;
  esac
  local trace_id="$parent_tid"
  [ -n "$trace_id" ] || trace_id="$(trace_rand_hex 32)"
  local span_id
  span_id="$(trace_rand_hex 16)"
  local saved="${VIBE_TRACEPARENT:-}"
  export VIBE_TRACEPARENT="00-${trace_id}-${span_id}-01"
  TRACE_TOKEN="$trace_id $span_id ${parent_sid:-.} $(trace_now_ns) ${saved:-.} $name"
}

trace_end() {
  local token="$1"
  local rc="${2:-0}"
  [ -n "$token" ] || return 0
  local trace_id span_id parent_sid t0 saved name
  read -r trace_id span_id parent_sid t0 saved name <<< "$token"
  [ "$parent_sid" = "." ] && parent_sid=""
  if [ "$saved" = "." ]; then
    unset VIBE_TRACEPARENT
  else
    export VIBE_TRACEPARENT="$saved"
  fi
  printf '{"tid":"%s","sid":"%s","pid":"%s","name":"%s","t0":%s,"t1":%s,"rc":%s}\n' \
    "$trace_id" "$span_id" "$parent_sid" "$(trace_json_escape "$name")" "$t0" "$(trace_now_ns)" "$rc" \
    >> "$VIBE_TRACE_OUT"
}
