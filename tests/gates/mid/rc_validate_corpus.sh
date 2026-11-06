#!/usr/bin/env bash
# Sourced by this lane's run.sh; shares its resolved compiler and gate state.

# 40rcv. `vibe rc-validate` over the RC fixture corpus (#3718 slice 1): no plan
#        in fixtures/rc_*.vibe may release a reference it does not hold. The
#        gate is scripts/check_rc_validate_corpus.sh; its self-test
#        (scripts/check_rc_validate_corpus_test.sh) mutates a real plan and
#        shows the gate fails. This lane runs it on the lane's compiler.
echo "[compiler-gate] 40rcv/40 rc-validate RC fixture corpus (#3718)"
RC_VALIDATE_CORPUS_STAGE2="$stage2_wasm" bash scripts/check_rc_validate_corpus.sh
