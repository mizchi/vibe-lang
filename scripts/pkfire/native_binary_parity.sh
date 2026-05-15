#!/usr/bin/env bash
# Push-only native artifact parity checks — extracted from justfile
# `ci-native-binary-parity`.
set -euo pipefail

source scripts/ensure_native_cli.sh
scripts/test_build_parity.sh
scripts/test_linked_debug_build.sh
