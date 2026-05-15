#!/usr/bin/env bash
# PR-oriented contract checks — extracted from justfile `ci-contract-moon`.
set -euo pipefail

moon_warn_list="${VIBE_MOON_WARN_LIST:--1-6-7-9-20-24-29}"

scripts/check_lock_clean.sh
scripts/check_lock_clean_test.sh
bash scripts/generate_selfhost_bundle_test.sh
node --test scripts/coverage_selfhost_suite_next_branches.test.mjs scripts/coverage_wasm_source.test.mjs
moon check --deny-warn --warn-list "$moon_warn_list" --target js
bash scripts/test_codegen_contract.sh
VIBE_MOON_WARN_LIST="$moon_warn_list" bash scripts/test_contract_moon.sh
