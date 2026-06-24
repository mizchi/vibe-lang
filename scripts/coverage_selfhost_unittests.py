#!/usr/bin/env python3
# Run the compiler's own *_test.vibe unit tests against the FLAT module source
# (which has no cyclic re-export), bypassing the cyclic-import blocker that stops
# them from FS-compiling. We strip imports from the *_support.vibe helpers (their
# deps are all top-level in the flat source) and append them + every test block's
# body + assert helpers, then compile+run under coverage.
import re, sys, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def strip_module(src):
    # drop `import <path> { names }` and re-export `export <path> { names }` /
    # `export { names }` blocks (multiline), but NOT `export let f: T with { Error } = ...`.
    src = re.sub(r'\bimport\s+[^\n{]*\{[^{}]*\}', '', src, flags=re.S)
    src = re.sub(r'\bexport\s+[./@~][^\n{]*\{[^{}]*\}', '', src, flags=re.S)   # export ./path { ... }
    src = re.sub(r'\bexport\s*\{[^{}]*\}', '', src, flags=re.S)                  # export { names }
    src = re.sub(r'^//#.*$', '', src, flags=re.M)
    src = re.sub(r'^export let', 'let', src, flags=re.M)
    return src

def extract_tests(src):
    out, i = [], 0
    while True:
        m = re.search(r'(?:test|bench)\s+"([^"]*)"\s*\{', src[i:])
        if not m: break
        start = i + m.end(); depth = 1; j = start
        while j < len(src) and depth > 0:
            c = src[j]
            if c == '{': depth += 1
            elif c == '}': depth -= 1
            j += 1
        out.append(src[start:j-1]); i = j
    return out

support_files = sys.argv[1].split(',') if sys.argv[1] else []
test_files = sys.argv[2:]
helpers = []
seen_names = set()
for sf in support_files:
    p = os.path.join(ROOT, 'vibe/compiler', sf)
    if not os.path.exists(p): continue
    body = strip_module(open(p).read())
    # dedup top-level let names to avoid collisions across supports
    for m in re.finditer(r'^let\s+(rec\s+)?([a-z_][a-z_0-9]*)', body, flags=re.M):
        seen_names.add(m.group(2))
    helpers.append(body)

asserts = '''
let assert: (Bool) -> Int with { Error } = (b) -> { if b { 1 } else { throw("assert failed") } }
let assert_eq: (Int, Int) -> Int with { Error } = (a, b) -> { if a == b { 1 } else { throw("assert_eq failed") } }
'''
fns, calls, n = [], [], 0
for tf in test_files:
    p = os.path.join(ROOT, 'vibe/compiler', tf)
    if not os.path.exists(p): continue
    for body in extract_tests(open(p).read()):
        n += 1
        fns.append(f'let cov_ut_{n}: () -> Int with {{ Error }} = () -> {{\n{body}\n  0\n}}')
        calls.append(f'  let _ = handle {{ cov_ut_{n}() }} with Error {{ Throw(_) => 0 }}')
main = 'let cov_driver_main: () -> Int = () -> {\n' + '\n'.join(calls) + '\n  0\n}\n'
out = '\n'.join(helpers) + asserts + '\n'.join(fns) + '\n' + main
open('/tmp/ut_driver.vibe','w').write(out)
print(f"{n} tests, {len(support_files)} supports")
