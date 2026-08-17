#!/usr/bin/env bash
# Fail-closed compiler-gate registry (#2001 Phase 0 / #1849).
#
# THE INVARIANT: every independently runnable lane has a registry row for
# every section it announces, and every registry row names a live lane
# script. There is no third state in which a gate exists only as a comment
# or a lane script exists without an owner.
#
# Rejects:
#   - duplicate ids
#   - unknown / missing lanes
#   - missing lane entrypoints
#   - section banners in a lane script with no registry row
#   - registry rows whose title is not announced by that lane
#   - fixture paths the lane names that do not exist
#
# Usage:
#   bash scripts/check_gate_registry.sh
#   bash scripts/check_gate_registry.sh --list
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/gates/lib.sh"

REGISTRY="tests/gates/registry.tsv"
mode="check"
case "${1:-}" in
  --list) mode="list" ;;
  "") ;;
  *) echo "unknown argument: $1 (expected --list)" >&2; exit 2 ;;
esac

if [ ! -f "$REGISTRY" ]; then
  echo "[gate-registry] FAIL: missing $REGISTRY" >&2
  exit 1
fi

ids=""
fail=0

known_lane() {
  local want="$1"
  local lane
  for lane in $GATE_LANES; do
    if [ "$lane" = "$want" ]; then
      return 0
    fi
  done
  return 1
}

is_success_banner() {
  local rest="$1"
  case "$rest" in
    ok|FAIL:*) return 0 ;;
    *" ok "*|*" ok"|*" ok:"*|*" ok ("*) return 0 ;;
  esac
  return 1
}

while IFS=$'\t' read -r id lane title; do
  case "$id" in
    ""|\#*|id) continue ;;
  esac
  if [ -z "$lane" ] || [ -z "$title" ]; then
    echo "[gate-registry] FAIL: malformed row: id='$id' lane='$lane'" >&2
    fail=1
    continue
  fi
  case $'\n'"$ids"$'\n' in
    *$'\n'"$id"$'\n'*)
      echo "[gate-registry] FAIL: duplicate id '$id'" >&2
      fail=1
      continue
      ;;
  esac
  ids="$ids$id"$'\n'
  if [ "$mode" = "list" ]; then
    printf '%s\t%s\t%s\n' "$id" "$lane" "$title"
  fi
  if ! known_lane "$lane"; then
    echo "[gate-registry] FAIL: id '$id' names unknown lane '$lane'" >&2
    fail=1
  fi
  script="$(gate_lane_script "$lane")"
  if [ ! -f "$script" ]; then
    echo "[gate-registry] FAIL: missing lane entrypoint $script" >&2
    fail=1
  elif ! grep -F -q "$title" "$script"; then
    echo "[gate-registry] FAIL: id '$id' title not found in $script" >&2
    fail=1
  fi
done < "$REGISTRY"

if [ "$mode" = "list" ]; then
  if [ "$fail" -ne 0 ]; then
    exit 1
  fi
  exit 0
fi

if [ -z "$ids" ]; then
  echo "[gate-registry] FAIL: registry has no rows" >&2
  exit 1
fi

for lane in $GATE_LANES; do
  script="$(gate_lane_script "$lane")"
  if [ ! -f "$script" ]; then
    echo "[gate-registry] FAIL: missing lane entrypoint $script" >&2
    fail=1
    continue
  fi
  while IFS= read -r rest; do
    [ -n "$rest" ] || continue
    if is_success_banner "$rest"; then
      continue
    fi
    if ! grep -F -q "$rest" "$REGISTRY"; then
      echo "[gate-registry] FAIL: $script announces unregistered section: $rest" >&2
      fail=1
    fi
  done < <(sed -n 's/^echo "\[compiler-gate\] \(.*\)"$/\1/p' "$script")

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      *'{'*|*'${'*|*'*'*) continue ;;
      lib/@vibe/compiler/_cli_adapter_module_source.vibe|\
      lib/@vibe/compiler/compiler_sources_bundle.vibe|\
      lib/@vibe/compiler/cli_adapter_bundle.vibe|\
      lib/@vibe/compiler/selfbuild_runtime_entry_bundle.vibe|\
      lib/@vibe/compiler/cache/codegen_fingerprint.vibe)
        continue
        ;;
      fixtures/*)
        if [ ! -e "$path" ]; then
          echo "[gate-registry] FAIL: $script names missing fixture $path" >&2
          fail=1
        fi
        ;;
    esac
  done < <(grep -oE '"(fixtures|lib|docs|scripts|tests)/[^"$]+"' "$script" | tr -d '"' || true)
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "[gate-registry] ok"
