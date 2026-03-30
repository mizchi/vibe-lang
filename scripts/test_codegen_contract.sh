#!/usr/bin/env bash
set -euo pipefail

warn_list="${VIBE_MOON_WARN_LIST:--1-6-7-9-24-29}"

if rg -n '@checker|mizchi/vibe/checker' src/codegen/moon.pkg src/codegen >/dev/null; then
  echo "codegen contract violation: src/codegen must not depend on checker" >&2
  exit 1
fi

moon check --target js --deny-warn --warn-list "${warn_list}" src/codegen
