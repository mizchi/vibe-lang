# RC live bytes and fragmentation of an RC-built compiler — 2026-11-09

Part of #2509. The reserved-page KPI (#3647) measures pages and the bump
frontier. This report splits an RC-built compiler's frontier into bytes on its
free lists and bytes never returned to them, for the same probes.

## Instrument

`VIBE_WASM_RC_CENSUS=1` (node runner, `scripts/wasm_rc_census.js`) prints one
`[rc-census]` line at every `[profile-memory]` mark and at the end of the run.
Each line walks the 32 exact-size bins and the legacy list in guest memory.

- `free` is exact.
- `unfreed = frontier - free` is an upper bound on live RC bytes.
- `VIBE_WASM_RC_CENSUS=detail` adds a heuristic scan of the unfreed bytes. It
  counts plausible RC headers as `est_rc_live_bytes`, by drop class and by size
  (and constructor tag for class 1), and counts the rest as `est_raw_bytes`.
  The rest is headerless string/bytes payloads and host buffers.

The census only reads guest memory. The one change it makes to the module is an
added export of the legacy free-list head. The guest's code, data and memory
are unchanged.

`wasm_rc_census.test.cjs` builds a known-good heap and mutates it into each
corruption shape. It asserts that every shape is reported in `bad=` and not
counted as free. The shapes are:

- a stale link past the frontier;
- a double free;
- overlapping free blocks;
- a size word that no longer matches its bin;
- an unaligned link;
- an oversized block.

The test also checks the module rewrite: only the export section changes.

## Setup

- **Compilers.** Main `be778cd`. Both stage2s were built with
  `scripts/generations.sh build` from the same tree:
  - the bump-built one with the default `VIBE_RC=0`, sha256 `6c72bc23…`;
  - the RC-built one with `VIBE_RC=1`, sha256 `9bc2d71e…`, 8,746,902 bytes.
- **Runs.** Each run is one cold compile through `selfcompile_kpi.sh`'s
  command (`--invoke cli_main … __no_entry__`). Every run gets a fresh, empty
  `VIBE_BUILD_CACHE_DIR`. Every run also sets `VIBE_PROFILE_MEMORY_MARKS=1`
  and `VIBE_WASM_MEMORY_STATS=1`.
- **Outputs.** Both compilers produced byte-identical wasm for every input.

## Results at the end of the compile

The end mark comes after `cli_main` returns, so nothing on the guest stack
holds a reference.

| Input | Bump pages / heap | RC pages / frontier | free (%) | est. RC-headered unfreed | est. raw |
|---|---:|---:|---:|---:|---:|
| json probe | 252 / 15.6 MB | 318 / 19.5 MB | 1.70 MB (8.7%) | 15.4 MB (79%) | 2.4 MB |
| optimizer probe | 544 / 34.3 MB | 454 / 29.4 MB | 3.00 MB (10.2%) | 20.2 MB (69%) | 6.2 MB |
| parser probe | 1,922 / 125.1 MB | 1,703 / 108.0 MB | 7.35 MB (6.8%) | 85.4 MB (79%) | 15.2 MB |
| self-compile KPI input (`codegen_lexer_test.vibe`) | 20,376 / 1.29 GB | 18,050 / 1.12 GB | 81.8 MB (7.3%) | 827 MB (74%) | 212 MB |

From the `prepared_db` mark on, the free share stays between 6% and 15%. It
does not rise as phases end.

## Reading

**Fragmentation is not the cost.** At the end, at most 10.2% of the frontier
sits on a free list. The bins are nearly empty: 38 KB on the parser probe and
158 KB on the self-compile. The legacy list is mostly array-growth buffers of
2^k·8 + 8 bytes, which the bounded walk cannot always match exactly.

**The cost is bytes never released.** Roughly three quarters of the frontier
is RC-headered blocks with a non-zero count, even after the compile returns.

On the json probe, 106,895 of the 216,250 remaining blocks have a count above
the number of references to them in the whole heap. They are leaked
references, not live data.

**One structure stands out.** The default-capacity array block is 84 bytes:
an 8-byte header, `[capacity][length][data_ptr]`, and 8 inline slots.

| Input | 84-byte arrays left at the end | Share of frontier |
|---|---:|---:|
| json probe | 113,307 | 49% |
| parser probe | 371,538 | 30% |
| self-compile | 3,500,942 (308 MB) | 27% |

On the parser probe, 47% of those arrays are empty and 23% hold one element.

**`CompileCtx` leaks once per compiled function.** It has 106 fields
(`codegen/common_base/common_base_compilectx.vibe`). On the json probe:

- 1,043 instances remain, most with a count of 77;
- only one reference to any of them exists in the heap;
- their subtree is 6.4 MB, a third of the frontier.

## Leak shapes measured

The compilers below produced each probe program, which then ran on the RC lane
with the census on. "Leaks" means the record and its arrays are still there at
the end.

| Shape | main | #3988 head (`2d51dd1`) |
|---|---|---|
| parameter consumed in one `if` arm, `0` in the other | leaks | released |
| parameter consumed in one `match` arm; the other arm returns `ctx.n` (an `Int` field) | leaks | leaks |
| `if c { return keep(ctx) }` followed by `ctx.n` | leaks | leaks |
| recursion with `return keep(ctx)` at the leaf | leaks | leaks |
| consume inside a `while` loop; `if`/`else` recursion with a leaf consume | released | released |

The #3988 compiler does not change the json probe's numbers: 19.52 MB
frontier and 1,043 `CompileCtx` left. The shapes it still leaks are the ones
its `pe_split_release_ok` declines on purpose:

- a body with an early exit (`exit_ord != 0`);
- a tail that `pe_tail_may_view` treats as a possible view (a field
  projection, even of an `Int` field).

## Cost of the census

| Input | Census | Runs | Wall | Time in marks | Pages, `heap_ptr`, output |
|---|---|---:|---:|---:|---|
| json probe | off | 3 | 650–744 ms | — | identical to `=1` |
| json probe | `=1` | 3 | 769–856 ms | 0.2–3.9 ms per mark | identical to off |
| self-compile input | off | 1 | 19.3 s | — | identical to `=1` |
| self-compile input | `=1` | 1 | 21.3 s | 0.23 s over 8 marks | identical to off |

The json runs alternated off and on.

`detail` walks the whole frontier. That took 30 ms per mark at 20 MB and
4.5 s per mark at 1.1 GB.
