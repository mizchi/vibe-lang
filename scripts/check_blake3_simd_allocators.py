#!/usr/bin/env python3
"""Run real SIMD digest regressions on every supported linear allocator."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {
    "__test_blake3 simd matches official vectors (small)",
    "__test_blake3 simd matches official vectors (block/chunk boundaries)",
    "__test_blake3 simd and scalar agree on odd sizes",
    "__test_blake3 simd hashes every byte across chunks",
}
EXPORTS = '''const fs = require("fs");
const module = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
process.stdout.write(JSON.stringify(WebAssembly.Module.exports(module).map(x => x.name)));'''


def checked(command, cwd, env, label, diagnostic=None, seconds=180):
    bounded = ["bash", "-c", '. "$1"; shift; run_bounded "$@"', "_",
               str(ROOT / "scripts/run_bounded.sh"), str(seconds), *command]
    result = subprocess.run(bounded, cwd=cwd, env=env, capture_output=True, text=True)
    if result.returncode:
        detail = ""
        if diagnostic is not None and diagnostic.is_file():
            detail = diagnostic.read_text(errors="replace")
        raise ValueError(f"{label} failed (exit {result.returncode}):\n"
                         + (result.stdout + result.stderr + detail)[-6000:])
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", type=Path, help="explicit current stage2.wasm")
    parser.add_argument("--library-root", type=Path, default=ROOT / "lib",
                        help="library tree to verify, including its real SIMD tests")
    args = parser.parse_args()
    compiler = args.compiler.resolve()
    library = args.library_root.resolve()
    source = library / "@vibe/blake3/simd_test.vibe"
    if not compiler.is_file() or not compiler.stat().st_size:
        raise ValueError("current compiler is missing; pass the selected stage2.wasm")
    if not source.is_file():
        raise ValueError("the selected library has no SIMD regression source")
    project = library.parent
    build = project / "_build"
    build.mkdir(exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
    checked(["bash", str(ROOT / "scripts/ensure_viberun.sh")], ROOT, env,
            "native runner preparation", seconds=1200)
    runner = ROOT / "runtime/viberun/target/release/viberun"
    print(f"blake3-simd-allocators: compiler={compiler} "
          f"sha256={hashlib.sha256(compiler.read_bytes()).hexdigest()} library={library}",
          flush=True)
    with tempfile.TemporaryDirectory(prefix="blake3_simd_allocators.", dir=build) as work:
        work = Path(work)
        for mode in ("0", "1", "shadow"):
            selected = dict(env, VIBE_RC=mode, VIBE_LIB=str(library),
                            VIBE_PREOPEN_DIR=str(project), VIBE_FS_COMPILE="1",
                            VIBE_IMPORT_ABI="raw", VIBE_WASM_NAMES="1",
                            VIBE_BUILD_CACHE_DIR=str(work / f"cache-{mode}"),
                            VIBE_CHECKED_MODULE_CACHE="off", VIBE_CODEGEN_BODY_CACHE="off",
                            VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE="1")
            output = work / f"tests-{mode}.wasm"
            wrapper = str(ROOT / "scripts/run_wasm_vibe_host_runner.sh")
            checked(["bash", wrapper, "--invoke", "cli_main", str(compiler),
                     str(source), str(output), "__no_entry__"], project, selected,
                    f"mode={mode} compilation", Path(str(output) + ".diag"))
            exports = set(json.loads(checked(["node", "-e", EXPORTS, str(output)],
                                            project, env, f"mode={mode} export inspection")))
            if not REQUIRED <= exports:
                raise ValueError("missing SIMD regression exports: "
                                 + ", ".join(sorted(REQUIRED - exports)))
            checked(["bash", wrapper, "--invoke", "_start", str(output)],
                    project, selected, f"mode={mode} Node execution")
            checked([str(runner), str(output)], project, selected,
                    f"mode={mode} native execution")
            print(f"blake3-simd-allocators: mode={mode} official vectors, scalar parity "
                  "and byte mutations pass on Node and native", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"blake3-simd-allocators: FAIL: {error}", file=sys.stderr)
        sys.exit(1)
