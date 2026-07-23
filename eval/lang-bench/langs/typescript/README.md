# mini-vcs — typescript

This environment has `node` but not `deno`; use `node` + `tsc` (or run the
`.ts` directly with `node --experimental-strip-types` if the installed
node version supports it — check `node --version`) rather than assuming a
`deno`-specific API surface, so results are reproducible here.

## Build

```bash
cd eval/lang-bench/attempts/<round>/typescript
npx tsc                      # or your chosen build; emit to dist/
```

## Run

```bash
bash eval/lang-bench/acceptance_test.sh \
  "node eval/lang-bench/attempts/<round>/typescript/dist/minivcs.js"
```

## LOC / size

`find src -name '*.ts' | xargs wc -l` for LOC. TypeScript has no single
comparable "binary size" (it runs on the node runtime, not a standalone
binary) — record `dist/` bundle size if bundled, and note runtime startup
overhead separately rather than conflating it with the wasm/native
binary-size columns from the other languages.
