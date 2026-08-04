#!/usr/bin/env python3
"""#1262: splice a free-list head assertion into a compiled RC module's
`__rt_rc_alloc`, as a post-hoc binary patch.

Why a binary patch and not a source change: wasm code lives OUTSIDE linear
memory, so rewriting a function body cannot move the guest's heap. Editing
the compiler source instead changes what the compiler EMITS, which changes
its own allocation totals -- that is what kept making this layout-sensitive
crash disappear under instrumentation (see docs/perceus-reuse.md).

The prologue traps (`unreachable`, distinguishable from the natural
"memory access out of bounds") on the FIRST allocation after a bad pointer
reaches the free-list head, so the wasm stack trace names the function that
pushed it -- instead of the trap landing many allocations later inside the
walk, where the pusher is long gone.

  global.get 2                     ; legacy free-list head
  if head != 0:
    trap if head < heap_lo or head > global0
    sz = i32.load(head - 8)
    trap if sz < 16 or sz > 64MiB or (head - 8 + sz) > global0

Reads only; writes nothing; never moves the bump pointer.

  usage: rc_patch_freelist_assert.py <in.wasm> <out.wasm> [alloc_fn_name]
"""
import sys

ALLOC_FN = "__rt_rc_alloc"
MAX_BLOCK = 64 * 1024 * 1024


def uleb(b, i):
    r = 0
    s = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7f) << s
        if not x & 0x80:
            return r, i
        s += 7


def enc_u(n):
    out = bytearray()
    while True:
        x = n & 0x7f
        n >>= 7
        if n:
            out.append(x | 0x80)
        else:
            out.append(x)
            return bytes(out)


def enc_s(n):
    out = bytearray()
    while True:
        x = n & 0x7f
        n >>= 7
        if (n == 0 and not x & 0x40) or (n == -1 and x & 0x40):
            out.append(x)
            return bytes(out)
        out.append(x | 0x80)


def split_sections(d):
    """[(section_id, body_bytes)] in file order."""
    secs = []
    i = 8
    while i < len(d):
        sid = d[i]
        i += 1
        size, j = uleb(d, i)
        secs.append((sid, d[j:j + size]))
        i = j + size
    return secs


def parse_types(body):
    """type index -> param count."""
    cnt, k = uleb(body, 0)
    params = []
    for _ in range(cnt):
        assert body[k] == 0x60, "only function types expected"
        k += 1
        n, k = uleb(body, k)
        k += n
        params.append(n)
        m, k = uleb(body, k)
        k += m
    return params


def parse_func_names(body):
    """name section -> {func index: name}."""
    names = {}
    nlen, j = uleb(body, 0)
    if body[j:j + nlen] != b"name":
        return names
    j += nlen
    while j < len(body):
        sub = body[j]
        j += 1
        sz, j = uleb(body, j)
        end = j + sz
        if sub == 1:
            cnt, k = uleb(body, j)
            for _ in range(cnt):
                idx, k = uleb(body, k)
                ln, k = uleb(body, k)
                names[idx] = body[k:k + ln].decode("utf8", "replace")
                k += ln
        j = end
    return names


def count_imported_funcs(body):
    cnt, k = uleb(body, 0)
    n = 0
    for _ in range(cnt):
        for _field in range(2):
            ln, k = uleb(body, k)
            k += ln
        kind = body[k]
        k += 1
        if kind == 0:      # func
            _, k = uleb(body, k)
            n += 1
        elif kind == 1:    # table
            k += 1
            lim = body[k]
            k += 1
            _, k = uleb(body, k)
            if lim:
                _, k = uleb(body, k)
        elif kind == 2:    # memory
            lim = body[k]
            k += 1
            _, k = uleb(body, k)
            if lim:
                _, k = uleb(body, k)
        elif kind == 3:    # global
            k += 2
        else:
            raise SystemExit(f"unknown import kind {kind}")
    return n


def global0_init(body):
    cnt, _k = uleb(body, 0)
    assert cnt >= 1
    k = _k + 2                      # valtype, mut
    assert body[k] == 0x41, "global 0 is not i32.const-initialized"
    v, k = uleb(body, k + 1)
    return v


def poison_mask():
    """#1262 CORRECTION: a binary built from the size-word poison tree
    (stash "poison+hybrid instrumentation") ORs rc_poison_bit() == 0x40000000
    into the size word of every block it frees. Without masking that off, the
    size checks below trip on the FIRST legitimate free and the whole
    localization chases the marker instead of a bug. Set
    VIBE_RC_POISON_MASK=1073741824 when instrumenting such a binary."""
    import os
    return int(os.environ.get("VIBE_RC_POISON_MASK", "0"))


def load_size(l_ptr):
    b = bytearray()
    b += b"\x20" + enc_u(l_ptr) + b"\x41\x08\x6b"      # ptr - 8
    b += b"\x28\x02\x00"                               # i32.load
    m = poison_mask()
    if m:
        # i32.const takes a SIGNED LEB128; ~mask has the top bit set, so it
        # must be encoded as the negative i32 it is, not as a large unsigned.
        inv = (~m) & 0xffffffff
        if inv >= 0x80000000:
            inv -= 0x100000000
        b += b"\x41" + enc_s(inv)
        b += b"\x71"                                   # i32.and (mask off poison)
    return bytes(b)


def size_check(heap_lo, l_ptr, l_sz):
    """trap unless `l_ptr` looks like a live block's value pointer."""
    import os
    if os.environ.get("VIBE_RC_ASSERT_SIZE0_ONLY"):
        # Narrowed form: trap ONLY on alloc_size == 0, so a firing run proves
        # the header word was never written rather than merely "implausible".
        b = bytearray()
        b += b"\x20" + enc_u(l_ptr) + b"\x41" + enc_s(heap_lo) + b"\x4f"  # ptr >=u heap_lo
        b += b"\x20" + enc_u(l_ptr) + b"\x23\x00" + b"\x4d"               # ptr <=u global0
        b += b"\x71\x04\x40"                                              # and; if (in range)
        b += load_size(l_ptr)
        b += b"\x45\x04\x40\x00\x0b"                                      # eqz; if; unreachable; end
        b += b"\x0b"                                                      # end
        return bytes(b)
    b = bytearray()
    b += b"\x20" + enc_u(l_ptr) + b"\x41" + enc_s(heap_lo) + b"\x49"    # ptr <u heap_lo
    b += b"\x20" + enc_u(l_ptr) + b"\x23\x00" + b"\x4b"                 # ptr >u global0
    b += b"\x72\x04\x40\x00\x0b"                                        # or; if; unreachable; end
    b += load_size(l_ptr)
    b += b"\x22" + enc_u(l_sz)                                          # local.tee sz
    b += b"\x41\x10\x49"                                                # sz <u 16
    b += b"\x20" + enc_u(l_sz) + b"\x41" + enc_s(MAX_BLOCK) + b"\x4b"   # sz >u MAX
    b += b"\x72"
    b += b"\x20" + enc_u(l_ptr) + b"\x41\x08\x6b"
    b += b"\x20" + enc_u(l_sz) + b"\x6a"
    b += b"\x23\x00\x4b"                                                # (ptr-8+sz) >u global0
    b += b"\x72\x04\x40\x00\x0b"
    return bytes(b)


def prologue_drop(heap_lo, l_ptr, l_sz):
    """__rt_rc_drop(i64 v): if v is an odd value with a zero high word (a heap
    pointer, not a String/Bytes fat pointer), assert its block header is
    still intact BEFORE the rc decrement can free it. Firing here means the
    block was already clobbered while live; firing only in __rt_rc_alloc
    means it was clobbered after landing on the free list."""
    b = bytearray()
    b += b"\x20\x00\x42\x01\x83\xa7"          # (v & 1) as i32
    b += b"\x20\x00\x42\x20\x88\x50"          # (v >>u 32) == 0
    b += b"\x71"                              # i32.and
    b += b"\x04\x40"                          # if
    b += b"\x20\x00\x42\x01\x7d\xa7"          # vptr = wrap(v - 1)
    b += b"\x21" + enc_u(l_ptr)               # local.set vptr
    b += size_check(heap_lo, l_ptr, l_sz)
    b += b"\x0b"                              # end
    return bytes(b)


def prologue_watch_global2(_heap_lo, _l_head, _l_sz):
    """Free-list HEAD watchpoint: trap once global 2 holds VIBE_RC_WATCH_GLOBAL2.

    The memory watchpoint above finds who wrote a bad LINK; this finds when a
    bad pointer became the HEAD, which is the earlier event -- a link word only
    ever receives the previous head, so a corrupt link means the head was
    already corrupt (or the "link" is not a link at all, just live data that a
    walk mistook for one)."""
    import os
    val = int(os.environ["VIBE_RC_WATCH_GLOBAL2"])
    b = bytearray()
    b += b"\x23\x02"                                  # global.get 2
    b += b"\x41" + enc_s(val) + b"\x46"               # == val
    b += b"\x04\x40\x00\x0b"                          # if; unreachable; end
    return bytes(b)


def prologue_watch(_heap_lo, _l_head, _l_sz):
    """Fixed-address watchpoint: trap when the word at VIBE_RC_WATCH_ADDR
    already holds VIBE_RC_WATCH_VALUE. The corrupting store is bracketed by
    the last function whose entry saw the word intact and the first that
    saw it clobbered."""
    import os
    addr = int(os.environ["VIBE_RC_WATCH_ADDR"])
    val = int(os.environ["VIBE_RC_WATCH_VALUE"])
    b = bytearray()
    if os.environ.get("VIBE_RC_WATCH_MODE") == "neither":
        # trap once the word is neither 0 (untouched) nor the expected value
        b += b"\x41" + enc_s(addr) + b"\x28\x02\x00"
        b += b"\x41" + enc_s(val) + b"\x47"           # != val
        b += b"\x41" + enc_s(addr) + b"\x28\x02\x00"
        b += b"\x45\x45"                              # eqz; eqz  -> (v != 0)
        b += b"\x71"                                  # and
    else:
        b += b"\x41" + enc_s(addr) + b"\x28\x02\x00"
        b += b"\x41" + enc_s(val) + b"\x46"           # == val
    b += b"\x04\x40\x00\x0b"                          # if; unreachable; end
    return bytes(b)


def prologue(heap_lo, l_head, l_sz):
    b = bytearray()
    b += b"\x23\x02"                                  # global.get 2
    b += b"\x22" + enc_u(l_head)                      # local.tee head
    b += b"\x04\x40"                                  # if (head != 0)
    b += b"\x20" + enc_u(l_head) + b"\x41" + enc_s(heap_lo) + b"\x49"   # head <u heap_lo
    b += b"\x20" + enc_u(l_head) + b"\x23\x00" + b"\x4b"               # head >u global0
    b += b"\x72\x04\x40\x00\x0b"                      # or; if; unreachable; end
    b += load_size(l_head)
    b += b"\x22" + enc_u(l_sz)                        # local.tee sz
    b += b"\x41\x10\x49"                              # i32.const 16; sz <u 16
    b += b"\x20" + enc_u(l_sz) + b"\x41" + enc_s(MAX_BLOCK) + b"\x4b"  # sz >u MAX
    b += b"\x72"                                      # or
    b += b"\x20" + enc_u(l_head) + b"\x41\x08\x6b"    # head - 8
    b += b"\x20" + enc_u(l_sz) + b"\x6a"              # + sz
    b += b"\x23\x00\x4b"                              # >u global0
    b += b"\x72\x04\x40\x00\x0b"                      # or; if; unreachable; end
    b += b"\x0b"                                      # end (head != 0)
    return bytes(b)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    wants = (sys.argv[3] if len(sys.argv) > 3 else ALLOC_FN).split(",")
    d = open(src, "rb").read()
    for w in wants[:-1]:
        patch_one(d, w)
        d = PATCHED[0]
    patch_one(d, wants[-1], dst)


PATCHED = [None]


def patch_one(d, want, dst=None):
    mode = "drop" if want == "__rt_rc_drop" else "alloc"
    secs = split_sections(d)
    by_id = {}
    for sid, body in secs:
        if sid == 0:
            names = parse_func_names(body)
            if names:
                by_id["names"] = names
        else:
            by_id[sid] = body

    names = by_id.get("names", {})
    target = next((i for i, n in names.items() if n == want), None)
    if target is None:
        raise SystemExit(f"{want} not found in the name section")

    n_imported = count_imported_funcs(by_id[2]) if 2 in by_id else 0
    params = parse_types(by_id[1])
    heap_lo = global0_init(by_id[6])

    # function section: local func i -> type index
    fbody = by_id[3]
    fcnt, k = uleb(fbody, 0)
    ftypes = []
    for _ in range(fcnt):
        t, k = uleb(fbody, k)
        ftypes.append(t)

    ci = target - n_imported
    if ci < 0 or ci >= fcnt:
        raise SystemExit(f"{want} (index {target}) is an import, not a defined function")
    n_params = params[ftypes[ci]]

    # code section: rewrite entry ci
    code = by_id[10]
    ccnt, k = uleb(code, 0)
    assert ccnt == fcnt, f"code/function count mismatch {ccnt} != {fcnt}"
    entries = []
    for _ in range(ccnt):
        sz, k2 = uleb(code, k)
        entries.append(code[k2:k2 + sz])
        k = k2 + sz

    body = entries[ci]
    lcnt, j = uleb(body, 0)
    n_locals = 0
    groups = []
    for _ in range(lcnt):
        n, j = uleb(body, j)
        vt = body[j]
        j += 1
        n_locals += n
        groups.append((n, vt))
    l_head = n_params + n_locals
    l_sz = l_head + 1

    new_locals = bytearray(enc_u(lcnt + 1))
    for n, vt in groups:
        new_locals += enc_u(n) + bytes([vt])
    new_locals += enc_u(2) + b"\x7f"          # 2 fresh i32 locals

    import os
    if os.environ.get("VIBE_RC_WATCH_GLOBAL2"):
        pro = prologue_watch_global2
    elif os.environ.get("VIBE_RC_WATCH_ADDR"):
        pro = prologue_watch
    else:
        pro = prologue_drop if mode == "drop" else prologue
    entries[ci] = bytes(new_locals) + pro(heap_lo, l_head, l_sz) + body[j:]

    new_code = bytearray(enc_u(ccnt))
    for e in entries:
        new_code += enc_u(len(e)) + e

    out = bytearray(d[:8])
    for sid, sbody in secs:
        if sid == 10:
            sbody = bytes(new_code)
        out += bytes([sid]) + enc_u(len(sbody)) + sbody
    PATCHED[0] = bytes(out)
    if dst:
        open(dst, "wb").write(bytes(out))

    print(f"{want}: func {target} (code entry {ci}), {n_params} params + "
          f"{n_locals} locals -> assert locals {l_head},{l_sz}")
    print(f"heap_lo (global 0 init) = {heap_lo}")
    print(f"wrote {dst} ({len(out)} bytes, +{len(out) - len(d)})")


main()
