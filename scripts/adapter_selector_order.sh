#!/usr/bin/env bash
# Print VIBE_* adapter-selector names in cli_adapter.vibe source order.
# Compile-only builds `env -u` this list so an inherited selector cannot
# hijack cli_main. The launcher no longer embeds VIBE_SELECTOR_ORDER;
# this file is the derivation, from the adapter itself.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="${1:-$ROOT/lib/@vibe/compiler/cli_adapter.vibe}"
grep -oE 'if Env::get\("VIBE_[A-Z_]+"\) == "1"' "$ADAPTER" \
  | sed 's/if Env::get("//;s/") == "1"//' \
  | awk '!seen[$0]++ && $0 != "VIBE_RC"'
