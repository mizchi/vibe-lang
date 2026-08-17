# #725 — RC lane miscompilation repro set

Programs that misbehave ONLY when compiled with `VIBE_RC=1` (the production
default lane); `VIBE_RC=0` (bump) produces correct results. See issue #725 for
the full investigation log.

- `full_repro.vibe` — imports the real `import_alias_rewrite.vibe` plan builder;
  bump returns 3111, RC returns 2000 and later traps (`memory access out of
  bounds`) once the poisoned free list is walked.
- `broken_pair_q10.vibe` / `clean_pair_q14.vibe` — self-contained inlined pair
  differing in a SINGLE LINE inside a match arm that never executes on this
  input: `Array::push(edge_tpath, resolve_known_import_path(...))` (broken)
  vs `Array::push(edge_tpath, raw_path)` (clean). The never-taken arm's
  plan-time consumption is enough to corrupt the RC free list at runtime.

Run (repo root):

```bash
env VIBE_RC=1 VIBE_PREOPEN_DIR="$PWD" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main <CLI.wasm> \
  tests/fuzz/findings/issue725/broken_pair_q10.vibe /tmp/out.wasm main
bash scripts/run_wasm_vibe_host_runner.sh --invoke main /tmp/out.wasm   # RC: OOB / wrong result
```

Disproven so far (see issue): a `pe_use` remaining==0 unprotected-move guard
does not fix it; per-pattern let-binding workarounds don't generalize (multiple
same-shaped triggers exist in the plan builder). Next step needs a Perceus plan
dump (per-binding uses/remaining/action trace) to diff the pair.
