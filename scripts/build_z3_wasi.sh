#!/usr/bin/env bash
# Build z3 as a single-threaded WASI core module with wasm exceptions and NO
# imports, for `vibe check --prove --solver=wasm` (#3719, ADR-0121): the
# prover and the solver then run in one wasm process, z3 linked through the
# typed `.wasm` import (lib/@vibex/z3_wasi).
#
#   bash scripts/build_z3_wasi.sh [dest]   # default lib/@vibex/z3_wasi/z3_wasi.wasm
#
# The npm z3-solver build (scripts/fetch_z3_wasm.sh) cannot be linked: it is
# an emscripten module that imports its JS runtime. This one is built from
# the pinned sources below:
#
#   - z3 at Z3_TAG, patched by scripts/z3_wasi/z3.patch (no pthread.h on
#     WASI; a rounding mode wasm lacks is UNREACHABLE, never computed at
#     round-to-nearest);
#   - libc++abi + libunwind from LLVM at LLVM_TAG, compiled with
#     -fwasm-exceptions (the distribution's wasm32 libc++abi is a
#     -fno-exceptions build), patched by scripts/z3_wasi/libcxxabi.patch;
#   - scripts/z3_wasi/wasi_compat.h, force-included: single-threaded stand-ins
#     for <thread> / <mutex> / <condition_variable> (starting a thread
#     aborts) and file streams that never open (no filesystem);
#   - scripts/z3_wasi/wasi_stubs.c: the WASI calls answered inside the
#     module, so it imports nothing. It has no clock, so a z3 `timeout` never
#     fires; the prover bounds each query with `rlimit` instead.
#
# clang 18 emits the legacy exception instructions; binaryen's
# --translate-to-exnref turns them into the exnref form wasmtime (viberun)
# runs. The result is checked before it is installed: no imports, and every
# export the binding needs.
#
# Needs: clang / clang++ 18 with wasm-ld, llvm-ar, a wasm32-wasi sysroot with
# libc++ (Debian/Ubuntu: wasi-libc libc++-18-dev-wasm32
# libclang-rt-18-dev-wasm32), cmake, ninja, git, python3 (z3's code
# generators), node and npm (binaryen). About 25 minutes on 4 cores and 1 GB
# of disk under Z3_WASI_WORK (default _build/z3_wasi), removed afterwards
# unless Z3_WASI_KEEP_WORK=1.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$ROOT_DIR/lib/@vibex/z3_wasi/z3_wasi.wasm}"
SUPPORT="$ROOT_DIR/scripts/z3_wasi"
WORK="${Z3_WASI_WORK:-$ROOT_DIR/_build/z3_wasi}"
JOBS="${Z3_WASI_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

Z3_TAG="z3-4.15.8"
Z3_COMMIT="f80414f4bbd6e367f759655469fb384751fa2d20"
LLVM_TAG="llvmorg-18.1.3"
LLVM_COMMIT="c13b7485b87909fcf739f62cfa382b55407433c0"
BINARYEN_VERSION="125.0.0"

# What the binding (lib/@vibex/z3_wasi/z3_wasi.vibe) imports.
EXPORTS="malloc free Z3_mk_config Z3_del_config Z3_mk_context Z3_del_context
  Z3_set_error_handler Z3_eval_smtlib2_string Z3_get_full_version"

fail() { echo "[z3-wasi] FAIL $*" >&2; exit 1; }
for tool in clang clang++ wasm-ld llvm-ar cmake ninja git python3 node npm; do
  command -v "$tool" >/dev/null 2>&1 || fail "\`$tool\` is not on PATH (see the header for what this build needs)"
done
echo 'int main(void){return 0;}' | clang --target=wasm32-wasi -x c - -o /dev/null 2>/dev/null \
  || fail "clang cannot link for wasm32-wasi: install a WASI sysroot (Debian/Ubuntu: wasi-libc libc++-18-dev-wasm32 libclang-rt-18-dev-wasm32)"

mkdir -p "$WORK"
[ "${Z3_WASI_KEEP_WORK:-0}" = 1 ] || trap 'rm -rf "$WORK"' EXIT

checkout() {
  local url="$1" tag="$2" commit="$3" dir="$4"; shift 4
  if [ ! -d "$dir/.git" ]; then
    if [ "$#" -gt 0 ]; then
      git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" --filter=blob:none --sparse "$url" "$dir"
      git -C "$dir" sparse-checkout set "$@"
    else
      git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$url" "$dir"
    fi
  fi
  local got
  got="$(git -C "$dir" rev-parse HEAD)"
  [ "$got" = "$commit" ] || fail "$url $tag is commit $got, want $commit"
  git -C "$dir" checkout --quiet -- .
}

echo "[z3-wasi] sources: $Z3_TAG, $LLVM_TAG (libc++abi, libunwind)"
checkout https://github.com/Z3Prover/z3 "$Z3_TAG" "$Z3_COMMIT" "$WORK/z3"
checkout https://github.com/llvm/llvm-project "$LLVM_TAG" "$LLVM_COMMIT" "$WORK/llvm" \
  libcxxabi libunwind libcxx/include libcxx/src/include
git -C "$WORK/z3" apply "$SUPPORT/z3.patch"
git -C "$WORK/llvm" apply "$SUPPORT/libcxxabi.patch"

echo "[z3-wasi] exception runtime (libc++abi + libunwind, -fwasm-exceptions)"
rt="$WORK/ehrt"; rm -rf "$rt"; mkdir -p "$rt"
L="$WORK/llvm"
eh_flags=(--target=wasm32-wasi -O2 -DNDEBUG -fwasm-exceptions -D__USING_WASM_EXCEPTIONS__)
for f in "$L"/libcxxabi/src/*.cpp; do
  b="$(basename "$f" .cpp)"
  # The no-exceptions stand-ins, and thread_atexit (no threads).
  case "$b" in cxa_noexception|cxa_thread_atexit) continue ;; esac
  clang++ "${eh_flags[@]}" -std=c++20 -D_LIBCXXABI_BUILDING_LIBRARY -D_LIBCPP_BUILDING_LIBRARY \
    -D_LIBCXXABI_HAS_NO_THREADS -D_LIBCPP_HAS_NO_THREADS -DLIBCXXABI_USE_LLVM_UNWINDER \
    -I"$L/libcxxabi/include" -I"$L/libunwind/include" -I"$L/libcxx/src" -c "$f" -o "$rt/$b.o"
done
clang "${eh_flags[@]}" -D_LIBUNWIND_HIDE_SYMBOLS -D_LIBUNWIND_HAS_NO_THREADS -I"$L/libunwind/include" \
  -c "$L/libunwind/src/Unwind-wasm.c" -o "$rt/Unwind-wasm.o"
llvm-ar rcs "$rt/libwasmeh.a" "$rt"/*.o

echo "[z3-wasi] z3 ($JOBS jobs)"
cat > "$WORK/wasi.cmake" <<'EOF'
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR wasm32)
set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_C_COMPILER_TARGET wasm32-wasi)
set(CMAKE_CXX_COMPILER_TARGET wasm32-wasi)
set(CMAKE_AR llvm-ar)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
cflags="-fwasm-exceptions -include $SUPPORT/wasi_compat.h -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -DNO_Z3_DEBUGGER"
cmake -S "$WORK/z3" -B "$WORK/z3-build" -G Ninja -Wno-dev \
  -DCMAKE_TOOLCHAIN_FILE="$WORK/wasi.cmake" -DCMAKE_BUILD_TYPE=Release \
  "-DCMAKE_CXX_FLAGS=$cflags" -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
  -DZ3_SINGLE_THREADED=ON -DZ3_POLLING_TIMER=ON -DZ3_BUILD_LIBZ3_SHARED=OFF \
  -DZ3_BUILD_EXECUTABLE=OFF -DZ3_BUILD_TEST_EXECUTABLES=OFF -DZ3_ENABLE_EXAMPLE_TARGETS=OFF \
  -DZ3_BUILD_PYTHON_BINDINGS=OFF -DZ3_USE_LIB_GMP=OFF -DZ3_LINK_TIME_OPTIMIZATION=OFF \
  -DZ3_BUILD_DOCUMENTATION=OFF -DZ3_INCLUDE_GIT_HASH=OFF -DZ3_INCLUDE_GIT_DESCRIBE=OFF >"$WORK/cmake.log" \
  || { tail -20 "$WORK/cmake.log" >&2; fail "cmake"; }
ninja -C "$WORK/z3-build" -j "$JOBS" libz3.a >"$WORK/ninja.log" 2>&1 \
  || { grep -E "error:|FAILED" "$WORK/ninja.log" | head -20 >&2; fail "compiling z3"; }

echo "[z3-wasi] link"
clang --target=wasm32-wasi -O2 -c "$SUPPORT/wasi_stubs.c" -o "$WORK/wasi_stubs.o"
link=(clang++ --target=wasm32-wasi -fwasm-exceptions -mexec-model=reactor -nostdlib++
  "$WORK/wasi_stubs.o" "$WORK/z3-build/libz3.a" "$rt/libwasmeh.a" -lc++
  -lwasi-emulated-signal -lwasi-emulated-process-clocks
  -Wl,-z,stack-size=16777216 -Wl,--max-memory=4294967296 -Wl,--strip-debug
  -o "$WORK/z3_legacy_eh.wasm")
# The exception runtime comes before -lc++: the distribution's libc++.a
# carries libc++abi's no-exceptions objects, which would otherwise be linked.
for e in $EXPORTS; do link+=("-Wl,--export=$e"); done
"${link[@]}"

if [ -n "${WASM_OPT:-}" ]; then
  wasm_opt=("$WASM_OPT")
else
  [ -x "$WORK/binaryen/node_modules/binaryen/bin/wasm-opt" ] \
    || npm install --silent --no-audit --no-fund --prefix "$WORK/binaryen" "binaryen@$BINARYEN_VERSION" >/dev/null
  wasm_opt=(node "$WORK/binaryen/node_modules/binaryen/bin/wasm-opt")
fi
"${wasm_opt[@]}" --enable-exception-handling --enable-reference-types --enable-bulk-memory \
  --enable-multivalue --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int \
  --translate-to-exnref -O2 "$WORK/z3_legacy_eh.wasm" -o "$WORK/z3_wasi.wasm"

node - "$WORK/z3_wasi.wasm" $EXPORTS <<'JS' || fail "the linked module is not what the binding needs"
const fs = require("node:fs");
const [path, ...want] = process.argv.slice(2);
const mod = new WebAssembly.Module(fs.readFileSync(path));
const imports = WebAssembly.Module.imports(mod);
if (imports.length) throw new Error(`imports ${imports.map((i) => i.module + "." + i.name).join(" ")}; a vibe runner links only a module that imports nothing`);
const exports = new Set(WebAssembly.Module.exports(mod).map((e) => e.name));
for (const e of [...want, "memory", "_initialize"]) if (!exports.has(e)) throw new Error(`no export ${e}`);
JS
mkdir -p "$(dirname "$DEST")"
cp "$WORK/z3_wasi.wasm" "$DEST"
if command -v sha256sum >/dev/null 2>&1; then sum="$(sha256sum "$DEST" | cut -d' ' -f1)"; else sum="$(shasum -a 256 "$DEST" | cut -d' ' -f1)"; fi
echo "[z3-wasi] installed: $DEST ($(wc -c <"$DEST" | tr -d ' ') bytes, sha256 $sum)"
