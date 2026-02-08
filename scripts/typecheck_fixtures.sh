#!/bin/bash
# Verify or update typecheck diagnostic fixtures.
# Usage:
#   scripts/typecheck_fixtures.sh
#   scripts/typecheck_fixtures.sh --update

set -euo pipefail

moon run src/cmd/typecheck_fixture/main.mbt --target native -- "$@"
