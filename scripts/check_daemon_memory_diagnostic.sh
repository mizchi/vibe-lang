#!/usr/bin/env bash
# #2876: a daemon that has exhausted its wasm address space must say so.
#
# Several compiler-sized compiles in one `--daemon` walk the never-freed bump
# allocator into the wasm32 ceiling. Before this gate's subject landed, the
# next request answered `{"exit_code":1,"elapsed_us":1,"error":"unreachable"}`
# with no `.diag` -- the shape a caller reserves for "the compiler died"
# (checked_module_cache_parity.mjs: `neither output nor diagnostic`).
#
# The real repro costs two compiler-sized compiles (~35s, 4 GB). This gate
# asks the same question of the same code with a hand-encoded module: the
# classification is arithmetic over `__heap_ptr` and the memory's declared
# maximum, so a 60-byte module with its heap parked near a 2-page limit
# reaches it exactly as a 4 GiB compiler does.
#
# Two directions, because only one of them is the silent-wrong one:
#   A  heap parked under a page from the limit -> MUST report out of memory
#   B  heap at 0, ordinary trap               -> MUST NOT claim out of memory
# B is the one that matters most: mislabelling a compiler bug as "out of
# memory" sends the reader to recycle their process instead of filing it.
set -euo pipefail

# #2252: a gate does not inherit its own configuration. Anything a session
# hook or a caller exported that would change what the runner does is cleared
# here, so a case that means to set one sets it itself.
unset VIBE_CRASH_DIAG_OUT VIBE_OUTPUT VIBE_WASM_PRE_GROW_PAGES VIBE_IMPORT_ABI
unset VIBE_DEBUG VIBE_CRASH_DEBUG VIBE_DEBUG708_MEMDUMP VIBE_COV_OUT

cd "$(dirname "$0")/.."
RUNNER_JS="${VIBE_DAEMON_DIAG_RUNNER_JS:-scripts/wasm_vibe_host_runner.js}"
[ -f "$RUNNER_JS" ] || { echo "daemon-memory-diagnostic FAIL: no runner at $RUNNER_JS"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
note() { echo "daemon-memory-diagnostic FAIL: $*"; fail=1; }

# A module with exactly what the classification reads: an exported `memory`
# whose DECLARED MAXIMUM is 2 pages, an exported mutable `__heap_ptr` parked
# where the case wants it, and one exported function that traps. The declared
# maximum is deliberate -- the committed compiler declares no maximum and so
# only ever exercises the wasm32 fallback; this covers the other arm.
emit_module() { # <heap_ptr init> <out path>
  node -e '
    // The body bumps __heap_ptr by 8 and THEN traps, so a caller can see
    // whether a request ran at all: an answered-without-running request
    // reports the same heap_ptr as the one before it.
    const fs = require("fs");
    const heapInit = Number(process.argv[1]);
    const out = process.argv[2];
    const uleb = n => { const b = []; do { let x = n & 0x7f; n >>>= 7; if (n) x |= 0x80; b.push(x); } while (n); return b; };
    const sleb = n => { const b = []; let more = true; while (more) { let x = n & 0x7f; n >>= 7; if ((n === 0 && !(x & 0x40)) || (n === -1 && (x & 0x40))) more = false; else x |= 0x80; b.push(x); } return b; };
    const str = s => [...uleb(s.length), ...Buffer.from(s, "utf8")];
    const section = (id, body) => [id, ...uleb(body.length), ...body];
    const bytes = [
      0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
      ...section(1, [0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f]),
      ...section(3, [0x01, 0x00]),
      ...section(5, [0x01, 0x01, ...uleb(1), ...uleb(2)]),
      ...section(6, [0x01, 0x7f, 0x01, 0x41, ...sleb(heapInit), 0x0b]),
      ...section(7, [0x03,
        ...str("memory"), 0x02, 0x00,
        ...str("__heap_ptr"), 0x03, 0x00,
        ...str("probe"), 0x00, 0x00]),
      ...section(10, [0x01, ...uleb(10),
        0x00,
        0x23, 0x00, 0x41, 0x08, 0x6a, 0x24, 0x00,
        0x00, 0x0b]),
    ];
    fs.writeFileSync(out, Buffer.from(bytes));
  ' "$1" "$2"
}

# One daemon, one module, the requests on stdin; stdout is the response lines.
run_daemon() { # <module> <out prefix> <request count>
  local module="$1" prefix="$2" count="$3" i=1
  : > "$work/requests"
  while [ "$i" -le "$count" ]; do
    printf '{"args":["probe.vibe","%s%s.wasm","__no_entry__"]}\n' "$prefix" "$i" >> "$work/requests"
    i=$((i + 1))
  done
  node "$RUNNER_JS" --daemon --invoke probe "$module" < "$work/requests" 2> "$work/stderr.log"
}

# --- Case A: the address space really is gone -------------------------------
# 131072-byte limit, heap at 131000 -> 72 bytes left, under one 65536 page.
emit_module 131000 "$work/exhausted.wasm"
if ! run_daemon "$work/exhausted.wasm" "$work/a" 2 > "$work/a.out"; then
  note "case A: the daemon exited non-zero; see $work/stderr.log"
fi
if [ "$(grep -c . "$work/a.out")" != "2" ]; then
  note "case A: expected 2 response lines, got $(grep -c . "$work/a.out")"
fi
if ! grep -q '"memory_exhausted":true' "$work/a.out"; then
  note "case A: no memory_exhausted flag -- a caller cannot tell OOM from a crash"
fi
if ! grep -q 'out of memory' "$work/a.out"; then
  note "case A: the error does not say out of memory"
fi
# The message has to LEAD WITH THE EDIT, not merely report a number.
if ! grep -q 'recycle the --daemon process' "$work/a.out"; then
  note "case A: the message does not name the remedy"
fi
if ! grep -q '"heap_limit":131072' "$work/a.out"; then
  note "case A: heap_limit is not the module's DECLARED maximum (131072)"
fi
if grep -q '"error":"unreachable"' "$work/a.out"; then
  note "case A: a bare trap still reached the caller"
fi
for i in 1 2; do
  if [ ! -f "$work/a$i.wasm.diag" ]; then
    note "case A: request $i wrote no .diag sidecar"
  elif ! grep -q 'out of memory' "$work/a$i.wasm.diag"; then
    note "case A: request $i .diag does not say out of memory"
  fi
done
# The second request must be ANSWERED, not re-run into the same trap.
if [ "$(grep -c '"memory_exhausted":true' "$work/a.out")" != "2" ]; then
  note "case A: the second request was not answered with the diagnosis"
fi
# ...and answered WITHOUT running: the probe bumps __heap_ptr by 8 whenever it
# executes, so an instance that keeps accepting work reports a heap that moved.
# Classifying the trap a second time would look identical without this.
a_heap_1="$(sed -n '1p' "$work/a.out" | sed -e 's/.*"heap_ptr"://' -e 's/[^0-9].*//')"
a_heap_2="$(sed -n '2p' "$work/a.out" | sed -e 's/.*"heap_ptr"://' -e 's/[^0-9].*//')"
if [ -z "$a_heap_1" ] || [ -z "$a_heap_2" ]; then
  note "case A: no heap_ptr in the responses ($a_heap_1 / $a_heap_2)"
elif [ "$a_heap_1" != "$a_heap_2" ]; then
  note "case A: the exhausted daemon RAN the second request (heap $a_heap_1 -> $a_heap_2)"
fi

# --- Case B: an ordinary trap with the whole address space free -------------
emit_module 0 "$work/healthy.wasm"
if ! run_daemon "$work/healthy.wasm" "$work/b" 1 > "$work/b.out"; then
  note "case B: the daemon exited non-zero; see $work/stderr.log"
fi
if grep -q 'memory_exhausted' "$work/b.out"; then
  note "case B: an ordinary trap was labelled out of memory (sends the reader to recycle, not to file the bug)"
fi
if grep -q 'out of memory' "$work/b.out"; then
  note "case B: an ordinary trap was reported as out of memory"
fi
if ! grep -q '"error":"unreachable"' "$work/b.out"; then
  note "case B: the raw trap was not reported; got $(cat "$work/b.out")"
fi
if [ -f "$work/b1.wasm.diag" ]; then
  note "case B: an ordinary trap wrote an out-of-memory .diag"
fi

if [ "$fail" -ne 0 ]; then
  cp "$work/a.out" "$work/b.out" /tmp/ 2>/dev/null || true
  exit 1
fi
echo "daemon-memory-diagnostic ok (exhausted heap diagnosed and .diag written; ordinary trap left alone)"
