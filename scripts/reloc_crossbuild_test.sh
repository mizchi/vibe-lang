#!/usr/bin/env bash
# Exercise the real comparison on small, valid named modules. A deliberate
# source edit must not become evidence about relocation or satisfy its guards.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 reloc-crossbuild-test "${RELOC_CROSSBUILD_STAGE2:-${VIBE_STAGE2_WASM:-}}")"
mkdir -p _build
WORK="$(mktemp -d "$ROOT_DIR/_build/reloc_crossbuild_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

compile_rc=0
env -u VIBE_RC -u VIBE_BACKEND VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
  scripts/reloc_crossbuild.vibex "$WORK/tool.wasm" main >"$WORK/compile.log" 2>&1 || compile_rc=$?
if [ "$compile_rc" -ne 0 ] || [ ! -s "$WORK/tool.wasm" ]; then
  cat "$WORK/compile.log" >&2
  [ ! -f "$WORK/tool.wasm.diag" ] || cat "$WORK/tool.wasm.diag" >&2
  exit 1
fi

python3 - "$ROOT_DIR" "$WORK" "$STAGE2" <<'PY'
import os, pathlib, re, subprocess, sys

root, work = map(pathlib.Path, sys.argv[1:3])

def uleb(n):
    out = bytearray()
    while n >= 128:
        out.append((n & 127) | 128)
        n >>= 7
    return bytes(out + bytes([n]))

def blob(b):
    return uleb(len(b)) + b

def vec(items):
    return uleb(len(items)) + b''.join(items)

def section(kind, data):
    return bytes([kind]) + blob(data)

def module(tag, functions):
    # Every function has type () -> i32. Names are a standard name subsection.
    names = vec([uleb(i) + blob(name.encode()) for i, (name, _) in enumerate(functions)])
    data = (b'\0asm\x01\0\0\0' + section(1, vec([b'\x60\x00\x01\x7f']))
            + section(3, vec([b'\x00'] * len(functions)))
            + section(10, vec([blob(b'\x00' + body + b'\x0b') for _, body in functions]))
            + section(0, blob(b'name') + section(1, names)))
    path = work / (tag + '.wasm')
    path.write_bytes(data)
    # An independent validator proves that the fixture is a real module.
    subprocess.run(['node', '-e', 'new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))', str(path)], check=True)
    return str(path)

def const(n):
    return bytes([0x41, n])

def call(n):
    return b'\x10' + uleb(n)

env = dict(os.environ, VIBE_PREOPEN_DIR=str(root), VIBE_RUNNER_EXIT_WITH_RESULT='1',
           RELOC_CROSSBUILD_STAGE2=sys.argv[3])

def run(a, b, *args, error=None):
    p = subprocess.run(['bash', 'scripts/run_wasm_vibe_host_runner.sh', '--invoke', 'main',
                        str(work / 'tool.wasm'), a, b, *args], env=env, capture_output=True, text=True)
    output = p.stdout + p.stderr
    if error is not None:
        assert p.returncode != 0 and error in output, output
        return
    assert p.returncode == 0, output
    line = next(s for s in p.stdout.splitlines() if s.startswith('reloc-crossbuild compared='))
    return {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', line)}

def expect(rows, **wanted):
    for key, value in wanted.items():
        assert rows.get(key) == value, (key, value, rows)

# The edited body has no non-function/unresolved reference, so the old tool
# calls its added instruction encoding-blind. A separate opaque constant
# mismatch must still count after that source-edited body is excluded.
a = module('a', [('target', const(7)), ('unchanged', call(0)), ('edited', call(0)),
                 ('opaque', const(2)), ('caller', call(2))])
b = module('b', [('padding', const(0)), ('target', const(7)), ('unchanged', call(1)),
                 ('edited', call(1) + b'\x1a' + const(9)), ('opaque', const(3)), ('caller', call(3))])
raw = run(a, b)
expect(raw, compared=5, matched=3, mismatched=2, mismatch_encoding_blind=2,
       moved_index=5, rewritten=3, rewritten_matched=2, rewritten_mismatched=1)
print('reloc-crossbuild-test: control contains the source-change confound', flush=True)
excluded = run(a, b, 'edited')
expect(excluded, source_edited_excluded=1, compared=4, matched=3, mismatched=1,
       mismatch_encoding_blind=1, mismatch_ambiguous_cause=0, moved_index=4,
       rewritten=2, rewritten_matched=2, rewritten_mismatched=0,
       bodies_with_nonfunc_refs=0, bodies_with_unresolved_func=0)
print('reloc-crossbuild-test: source edits excluded; real mismatches and calls to excluded bodies retained', flush=True)

# A bare name must not exclude same-named functions in unrelated modules.
ma = module('modules-a', [('target', const(7)), ('unchanged', call(0)),
                         ('edited_exp_one', call(0)), ('edited_exp_two', call(0))])
mb = module('modules-b', [('padding', const(0)), ('target', const(7)), ('unchanged', call(1)),
                         ('edited_exp_one', call(1) + b'\x1a' + const(9)), ('edited_exp_two', call(1))])
run(ma, mb, 'edited', error='ambiguous')
expect(run(ma, mb, 'edited_exp_one'), source_edited_excluded=1, compared=3,
       matched=3, mismatched=0, rewritten_matched=2)

# Exclusions are exact names, validated on both sides, never silently ignored.
run(a, b, 'absent', error='shared defined function')
run(a, b, 'padding', error='shared defined function')
run(a, b, '', error='requires a function name')
run(a, b, 'edited,', error='requires a function name')
run(a, b, ',edited', error='requires a function name')
run(a, b, 'edited,edited', error='duplicate exclusion')
run(a, b, 'edited', 'unexpected', error='expected 2 or 3 arguments')
dup_a = module('dup-a', [('edited', const(1)), ('edited', const(2))])
dup_b = module('dup-b', [('padding', const(0)), ('edited', const(1)), ('edited', const(2))])
run(dup_a, b, 'edited', error='ambiguous')
run(a, dup_b, 'edited', error='ambiguous')

# Multiple explicit exclusions must each be counted once.
expect(run(a, b, 'edited,opaque'),
       source_edited_excluded=2, compared=3, matched=3, mismatched=0, mismatch_encoding_blind=0)

# The public wrapper must preserve even an empty third argument, so malformed
# exclusions reach validation instead of silently turning into an unfiltered run.
for args, wanted_error in [([a, b, 'edited'], None), ([a, b, ''], 'requires a function name'),
                           ([a, b, 'edited', 'extra'], 'usage:'),
                           ([a], 'usage:')]:
    p = subprocess.run(['bash', 'scripts/reloc_crossbuild.sh', *args], env=env,
                       capture_output=True, text=True)
    output = p.stdout + p.stderr
    if wanted_error:
        assert p.returncode != 0 and wanted_error in output, output
    else:
        assert p.returncode == 0 and 'source_edited_excluded=1' in output, output

# The only rewritten match is excluded: it cannot satisfy the rewrite guard.
ga = module('guard-a', [('stable', const(7)), ('edited', call(0))])
gb = module('guard-b', [('edited', call(1)), ('stable', const(7))])
run(ga, gb)
run(ga, gb, 'edited', error='no body was both rewritten and byte-identical')

# Nor may the excluded body's moved assignment satisfy the other guard.
gc = module('guard-c', [('stable', const(7)), ('padding', const(0)), ('edited', call(0))])
run(ga, gc, 'edited', error='no shared function changed index')
only_a = module('only-a', [('edited', const(1))])
only_b = module('only-b', [('padding', const(0)), ('edited', const(2))])
run(only_a, only_b, 'edited', error='nothing compared')
print('reloc-crossbuild-test: exclusions cannot satisfy non-vacuity guards', flush=True)
print('reloc-crossbuild-test: ok', flush=True)
PY
