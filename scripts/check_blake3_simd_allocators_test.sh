#!/usr/bin/env bash
# Mutate an isolated real library, never the working tree (#3507, #2248).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
python3 - "$ROOT_DIR" "${1:-${VIBE_STAGE2_WASM:-}}" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
if not sys.argv[2]:
    raise SystemExit("blake3-simd-allocators-test: pass an explicit current stage2.wasm")
compiler = Path(sys.argv[2]).resolve()
gate = root / "scripts/check_blake3_simd_allocators.py"
env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}

def run(library):
    return subprocess.run([sys.executable, str(gate), str(compiler), "--library-root",
                           str(library)], cwd=root, env=env, capture_output=True, text=True)

with tempfile.TemporaryDirectory(prefix="blake3_simd_allocator_test.",
                                 dir=root / "_build") as temporary:
    work = Path(temporary)
    library = work / "lib"
    shutil.copytree(root / "lib", library)
    result = run(library)
    assert result.returncode == 0, result.stdout + result.stderr
    print("blake3-simd-allocators-test: green: all three real allocator modes", flush=True)
    kernel = library / "@vibe/blake3/simd/simd.vibe"
    original = kernel.read_text()
    assert original.count("local.get $tag_shift") == 5, "mutation must hit five operands"
    mutant = original.replace("local.get $tag_shift", "i64.const 1")
    assert mutant != original and "local.get $tag_shift" not in mutant
    kernel.write_text(mutant)
    result = run(library)
    assert result.returncode != 0 and "mode=0 Node execution failed" in result.stderr, (
        result.stdout + result.stderr)
    print("blake3-simd-allocators-test: red: five fixed tag shifts fail on bump", flush=True)
    # The mutant is a valid RC implementation; reject it for the missing bump
    # semantics, not a compile error or an unrelated broken fixture.
    selected = dict(env, VIBE_RC="1", VIBE_LIB=str(library),
                    VIBE_PREOPEN_DIR=str(work), VIBE_FS_COMPILE="1", VIBE_IMPORT_ABI="raw",
                    VIBE_BUILD_CACHE_DIR=str(work / "rc-control-cache"))
    output = work / "rc-control.wasm"
    wrapper = str(root / "scripts/run_wasm_vibe_host_runner.sh")
    source = library / "@vibe/blake3/simd_test.vibe"
    subprocess.run(["bash", wrapper, "--invoke", "cli_main", str(compiler), str(source),
                    str(output), "__no_entry__"], cwd=work, env=selected,
                   capture_output=True, text=True, check=True)
    subprocess.run(["bash", wrapper, "--invoke", "_start", str(output)], cwd=work,
                   env=selected, capture_output=True, text=True, check=True)
    print("blake3-simd-allocators-test: RC control accepts the same mutant", flush=True)
    kernel.write_text(original)
    source.write_text('test "unrelated" { assert(true) }\n')
    result = run(library)
    assert result.returncode != 0 and "missing SIMD regression exports" in result.stderr
    print("blake3-simd-allocators-test: red: missing regression bodies are refused", flush=True)
    missing = subprocess.run([sys.executable, str(gate), str(work / "absent.wasm")],
                             cwd=root, env=dict(env, VIBE_STAGE2_WASM=str(compiler)),
                             capture_output=True, text=True)
    assert missing.returncode != 0 and "current compiler is missing" in missing.stderr
    print("blake3-simd-allocators-test: red: no compiler fallback", flush=True)
PY
