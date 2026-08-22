#!/usr/bin/env bash
set -euo pipefail

ROOT="${VIBE_GUEST_PROFILE_LINT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
runner="$ROOT/runtime/viberun/src/main.rs"
launcher="$ROOT/runtime/vibe"
profiling_doc="$ROOT/docs/spec/profiling.md"
failed=0

if [ ! -e "$runner" ] && [ ! -e "$launcher" ] && [ ! -e "$profiling_doc" ]; then
  echo "guest-profile contract: skipped (profile surfaces are absent)"
  exit 0
fi
for required_file in "$runner" "$launcher" "$profiling_doc"; do
  if [ ! -f "$required_file" ]; then
    echo "guest-profile contract: required surface is missing: $required_file" >&2
    exit 1
  fi
done

require() {
  local pattern="$1" file="$2" message="$3"
  if ! rg -q -- "$pattern" "$file"; then
    echo "guest-profile contract: $message" >&2
    failed=1
  fi
}

forbid() {
  local pattern="$1" file="$2" message="$3"
  if rg -q -- "$pattern" "$file"; then
    echo "guest-profile contract: $message" >&2
    failed=1
  fi
}

# Timing is a state machine, not a wall-clock delta duplicated between normal
# and benchmark paths. The state preserves short guest bursts across host calls.
require 'struct GuestCpuClock' "$runner" "missing shared GuestCpuClock state machine"
require 'accumulated_guest' "$runner" "guest CPU accumulation across host calls is missing"
require 'CallHook::CallingHost' "$runner" "host entry is not tracked"
require 'CallHook::ReturningFromHost' "$runner" "host return is not tracked"
require 'CallHook::CallingWasm' "$runner" "outer harness-to-guest entry is not tracked"
require 'CallHook::ReturningFromWasm' "$runner" "outer guest-to-harness return is not tracked"
forbid 'last_guest|guest_profiler_last_sample' "$runner" "wall-clock/reset sampling state reintroduced"

# CLI values must distinguish omission from an explicitly empty value, preserve
# the argv separator, and reject destructive source/output aliasing.
require 'after_separator=1' "$launcher" "run parser does not preserve arguments after --"
require '\-ef.*profile_out' "$launcher" "profile source/output alias guard is missing"
require 'guest_profile_requested=1' "$launcher" "bench cannot distinguish omitted and empty --guest-profile"
require 'bench_keep_names' "$launcher" "profiled benchmarks do not request Wasm names"

# Serialization and generated filenames must fail closed at their boundaries.
forbid 'finish\(io::BufWriter::new' "$runner" "profile writer can hide final flush errors"
require '\.take\(200\)' "$runner" "profile filename component bound is missing"

# This short standalone document is English-only under the repository policy.
if LC_ALL=C rg -q '[ぁ-んァ-ヶ一-龠]' "$profiling_doc"; then
  echo "guest-profile contract: docs/spec/profiling.md mixes Japanese into an English short document" >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "guest-profile contract: ok"
