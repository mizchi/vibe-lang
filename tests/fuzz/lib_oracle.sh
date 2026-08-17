#!/usr/bin/env bash
# Shared compile/run/classify helpers for the fuzz harness.
#
# Both tests/fuzz/run_fuzz.sh (the seed-sweeping differential fuzzer) and
# tests/fuzz/classify.sh (a single-candidate CLI used by tests/fuzz/reduce.py) source
# this file so the "what counts as a finding" logic lives in exactly one
# place. Factored out of run_fuzz.sh in #765 so the delta-debugging
# reducer can replay the identical oracle per candidate instead of
# re-implementing it.
#
# Callers must set ROOT and CLI before sourcing this file. RUNNER/
# CTIMEOUT/RTIMEOUT have defaults but may be overridden first.
: "${ROOT:?lib_oracle.sh: ROOT must be set before sourcing}"
: "${CLI:?lib_oracle.sh: CLI must be set before sourcing}"
RUNNER="${RUNNER:-bash scripts/run_wasm_vibe_host_runner.sh}"
CTIMEOUT="${CTIMEOUT:-90}"
RTIMEOUT="${RTIMEOUT:-20}"

compile() { # src out extra-env...
  local src="$1" out="$2"; shift 2
  rm -f "$out" "$out.diag"
  timeout "$CTIMEOUT" env VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw "$@" \
    $RUNNER --invoke cli_main "$CLI" "$src" "$out" _start \
    > "$out.log" 2>&1
  local rc=$?
  if [ $rc -eq 124 ]; then echo "COMPILE_HANG"; return; fi
  if [ -s "$out" ]; then echo "OK"; return; fi
  if [ -s "$out.diag" ]; then echo "COMPILE_DIAG"; return; fi
  echo "COMPILE_CRASH"
}

run_linear() { # wasm -> prints result or RUN_TRAP/RUN_HANG
  local wasm="$1"
  local out
  out=$(timeout "$RTIMEOUT" env VIBE_PREOPEN_DIR="$ROOT" \
    $RUNNER --invoke _start "$wasm" 2>/dev/null)
  local rc=$?
  if [ $rc -eq 124 ]; then echo "RUN_HANG"; return; fi
  if [ $rc -ne 0 ]; then echo "RUN_TRAP"; return; fi
  echo "$out" | tail -1 | tr -d '[:space:]'
}

run_gc() {
  local wasm="$1"
  local out
  out=$(timeout "$RTIMEOUT" wasmtime run -W gc=y,function-references=y,exceptions=y \
    --invoke _start "$wasm" 2>/dev/null)
  local rc=$?
  if [ $rc -eq 124 ]; then echo "RUN_HANG"; return; fi
  if [ $rc -ne 0 ]; then echo "RUN_TRAP"; return; fi
  echo "$out" | tail -1 | tr -d '[:space:]'
}

# classify DIR
#   DIR must contain single.vibe. If DIR also contains main.vibe (which
#   imports ./defs.vibe), the FS-linked lane is included too; otherwise it
#   is skipped (folded into the bump result so it can't spuriously mismatch).
#   Prints one line: "CLASS detail..." where CLASS is one of
#   OK / COMPILE_DIAG / COMPILE_CRASH / COMPILE_HANG / RUN_TRAP / RUN_HANG /
#   MISMATCH.
classify() {
  local dir="$1"
  local st_bump st_rc st_gc st_fs
  st_bump=$(compile "$dir/single.vibe" "$dir/bump.wasm" VIBE_RC=0)
  st_rc=$(compile "$dir/single.vibe" "$dir/rc.wasm" VIBE_RC=1)
  st_gc=$(compile "$dir/single.vibe" "$dir/gc.wasm" VIBE_RC=0 VIBE_BACKEND=gc)
  st_fs="OK"
  if [ -f "$dir/main.vibe" ]; then
    # FS compilation populates persistent source-list and source-group cache
    # files. Isolate them per candidate: deleting repository-global files
    # races when run_fuzz.sh runs multiple seeds concurrently.
    st_fs=$(compile "$dir/main.vibe" "$dir/fs.wasm" VIBE_RC=0 VIBE_FS_COMPILE=1 VIBE_BUILD_CACHE_DIR="$dir/cache")
  fi

  local bad="" pair lane st
  for pair in "bump:$st_bump" "rc:$st_rc" "gc:$st_gc" "fs:$st_fs"; do
    lane="${pair%%:*}"; st="${pair##*:}"
    if [ "$st" != "OK" ]; then bad="$bad $lane=$st"; fi
  done
  if [ -n "$bad" ]; then
    local cls
    cls=$(echo "$bad" | grep -oE "COMPILE_[A-Z]+" | sort -u | head -1)
    echo "$cls$bad"
    return
  fi

  local r_bump r_rc r_gc r_fs
  r_bump=$(run_linear "$dir/bump.wasm")
  r_rc=$(run_linear "$dir/rc.wasm")
  r_gc=$(run_gc "$dir/gc.wasm")
  r_fs="$r_bump"
  [ -f "$dir/main.vibe" ] && r_fs=$(run_linear "$dir/fs.wasm")

  case "$r_bump$r_rc$r_gc$r_fs" in
    *RUN_TRAP*) echo "RUN_TRAP bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"; return ;;
    *RUN_HANG*) echo "RUN_HANG bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"; return ;;
  esac
  if [ "$r_bump" != "$r_rc" ] || [ "$r_bump" != "$r_gc" ] || [ "$r_bump" != "$r_fs" ]; then
    echo "MISMATCH bump=$r_bump rc=$r_rc gc=$r_gc fs=$r_fs"
    return
  fi
  echo "OK bump=$r_bump"
}
