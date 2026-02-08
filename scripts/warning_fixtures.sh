#!/bin/bash
# Verify or update warning diagnostic fixtures.
# Usage:
#   scripts/warning_fixtures.sh
#   scripts/warning_fixtures.sh --update

set -euo pipefail

moon run src/cmd/warning_fixture/main.mbt --target native -- "$@"
