#!/usr/bin/env bash
# Print VIBE_* adapter-selector names in cli_adapter.vibe source order.
# Compile-only builds `env -u` this list so an inherited selector cannot
# hijack cli_main. The launcher no longer embeds VIBE_SELECTOR_ORDER;
# this file is the derivation, from the adapter itself.
#
# Every `Env::get("VIBE_X") == "1"` / `== "gc"` comparison counts, wherever it
# stands: the statement-position `if` arms AND the lane choices made inside
# assignments and compound conditions (`VIBE_DEBUG`, `VIBE_DEBUG_BREAK`,
# `VIBE_BACKEND=gc`). A first draft matched only the `if ... == "1"` shape and
# missed those three, so an inherited `VIBE_DEBUG=1` could still select a lane
# the compile-only artifact does not carry (Codex review of #2858). Same
# alternation as scripts/check_selector_precedence.sh. VIBE_RC is a lane
# parameter the callers set themselves, not a selector, and stays out.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="${1:-$ROOT/lib/@vibe/compiler/cli_adapter.vibe}"
python3 "$ROOT/scripts/source_files.py" "$ADAPTER" \
  | grep -oE 'Env::get\("VIBE_[A-Z_]+"\) == "(1|gc)"' \
  | sed -E 's/^Env::get\("([A-Z_]+)"\) == "(1|gc)"$/\1/' \
  | awk '!seen[$0]++ && $0 != "VIBE_RC"'
