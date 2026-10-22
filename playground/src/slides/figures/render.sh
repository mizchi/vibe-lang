#!/usr/bin/env bash
# Re-render the slide figures. Needs d2 with the TALA layout (`d2 layout`
# lists `tala (bundled)`); the SVGs are committed, so a build never needs d2.
set -euo pipefail
cd "$(dirname "$0")"
for source in *.d2; do
  case "$source" in _*) continue ;; esac
  "${D2:-d2}" --layout=tala "$source" "${source%.d2}.svg"
done
