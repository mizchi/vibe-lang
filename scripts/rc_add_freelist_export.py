#!/usr/bin/env python3
"""#1262: append `__rc_freelist` -> global 2 to a compiled RC module's export
section. A pure binary edit: no code, data, or global initializer changes, so
the guest's heap layout and execution are byte-identical to the unpatched
module. This is how the fragile OOB repro keeps reproducing while becoming
inspectable from the host.

This is deliberately NOT a codegen feature. Emitting the export from
linked_compile.vibe costs every RC module 16 bytes forever for something only
a debugging session reads -- enough to blow the +2% output-size ratchet
(scripts/size_ratchet.sh) on the small samples. Adding it here instead is also
strictly better for the use case: it can be applied to an ALREADY-BUILT
compiler, so the layout-sensitive repro under investigation is preserved
exactly."""
import sys

def uleb(b, i):
    r = 0; s = 0
    while True:
        x = b[i]; i += 1; r |= (x & 0x7f) << s
        if not x & 0x80:
            return r, i
        s += 7

def enc(n):
    out = bytearray()
    while True:
        x = n & 0x7f; n >>= 7
        if n:
            out.append(x | 0x80)
        else:
            out.append(x); return bytes(out)

src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
out = bytearray(d[:8])
i = 8
patched = False
globals_desc = []
while i < len(d):
    sid = d[i]; i += 1
    size, j = uleb(d, i)
    body = d[j:j + size]
    i = j + size
    if sid == 6:  # global section: sanity-check global 2
        cnt, k = uleb(body, 0)
        for gi in range(min(cnt, 4)):
            vt = body[k]; mut = body[k + 1]; k += 2
            op = body[k]
            # skip the init expr: one const instruction, then `end` (0x0b)
            while body[k] != 0x0b:
                k += 1
            k += 1
            globals_desc.append((gi, hex(vt), mut, hex(op)))
    if sid == 7:  # export section
        cnt, k = uleb(body, 0)
        name = b"__rc_freelist"
        if name in body:
            print("already exported", file=sys.stderr); sys.exit(2)
        newbody = enc(cnt + 1) + body[k:] + enc(len(name)) + name + bytes([3]) + enc(2)
        body = newbody
        patched = True
    out += bytes([sid]) + enc(len(body)) + body
if not patched:
    print("no export section", file=sys.stderr); sys.exit(1)
open(dst, 'wb').write(bytes(out))
print(f"globals[0..3] (idx, valtype, mut, init-op): {globals_desc}")
print(f"wrote {dst} ({len(out)} bytes, +{len(out) - len(d)})")
