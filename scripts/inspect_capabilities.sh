#!/usr/bin/env bash
set -euo pipefail

# Inspect vibe.capabilities custom section from a compiled WASM file.
# Usage: scripts/inspect_capabilities.sh <file.wasm>
#
# Reads the vibe.capabilities custom section and prints the required
# capabilities. This enables CLI pre-flight checks:
#
#   caps=$(scripts/inspect_capabilities.sh app.wasm)
#   if echo "$caps" | grep -q "Fs"; then
#     echo "⚠ app.wasm requires Fs capability"
#     echo "  use --allow-read to grant filesystem access"
#   fi

WASM_FILE="${1:-}"
if [ -z "$WASM_FILE" ] || [ ! -f "$WASM_FILE" ]; then
  echo "Usage: $0 <file.wasm>" >&2
  exit 1
fi

# Extract vibe.capabilities section content using binary search
# The section format is: 0x00 (custom section id) + length + "vibe.capabilities" + content
python3 -c "
import sys
data = open('$WASM_FILE', 'rb').read()
marker = b'vibe.capabilities'
idx = data.find(marker)
if idx < 0:
    print('(no capabilities required)')
    sys.exit(0)
start = idx + len(marker)
# Read until next null byte or end of section
end = start
while end < len(data) and data[end] != 0:
    end += 1
content = data[start:end].decode('ascii', errors='ignore').strip()
for line in content.split('\n'):
    line = line.strip()
    if line:
        print(line)
" 2>/dev/null || {
  # Fallback without python: grep for readable text after marker
  strings "$WASM_FILE" | grep -A10 "vibe.capabilities" | tail -n +2 | head -20
}
