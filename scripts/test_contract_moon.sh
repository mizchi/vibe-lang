#!/usr/bin/env bash
set -euo pipefail

warn_list="${VIBE_MOON_WARN_LIST:--1-6-7-9-20-24-29}"
contract_js_packages=(
  src/core
  src/frontend
  src/runtime_compile
)

if [ "${VIBE_CONTRACT_MOON_SKIP_JS_PACKAGE_TESTS:-0}" != "1" ]; then
  NODE_OPTIONS=--max-old-space-size=8192 moon test --target js --warn-list "$warn_list" "${contract_js_packages[@]}"
fi

moon build \
  src/cmd/warning_fixture/main.mbt \
  src/cmd/typecheck_fixture/main.mbt \
  src/cmd/parser_contract/main.mbt \
  --target js \
  --warn-list "$warn_list"

warning_fixture_js="_build/js/debug/build/cmd/warning_fixture/warning_fixture.js"
typecheck_fixture_js="_build/js/debug/build/cmd/typecheck_fixture/typecheck_fixture.js"
parser_contract_js="_build/js/debug/build/cmd/parser_contract/parser_contract.js"

typecheck_contract_files=(
  fixtures/typecheck/duplicate_enum_ctor.vibe
  fixtures/typecheck/duplicate_value_decl.vibe
  fixtures/typecheck/if_condition_non_bool.vibe
  fixtures/typecheck/let_annotation_type_mismatch.vibe
  fixtures/typecheck/missing_label_call_argument.vibe
  fixtures/typecheck/non_exhaustive_match.vibe
  fixtures/typecheck/ok_add.vibe
  fixtures/typecheck/parse_int_min_literal_boundary.vibe
  fixtures/typecheck/parse_loop_expr.vibe
  fixtures/typecheck/property_access_ambiguous_function_vs_field.vibe
  fixtures/typecheck/type_mismatch_argument.vibe
  fixtures/typecheck/while_condition_non_bool.vibe
)

NODE_OPTIONS=--max-old-space-size=4096 node "$warning_fixture_js"
node "$parser_contract_js"
typecheck_fixture_args=()
for f in "${typecheck_contract_files[@]}"; do
  typecheck_fixture_args+=(--file "$f")
done
node "$typecheck_fixture_js" "${typecheck_fixture_args[@]}"
