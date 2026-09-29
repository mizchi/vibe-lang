# Browser playground

The playground compiles and runs a single source file in the browser. Programs
export `_start`; the four presets are examples. The compiler component is built
from the checkout's stage2, so the page uses the same language as the release
candidate.

```bash
pnpm install --frozen-lockfile
PLAYGROUND_STAGE2=/absolute/path/to/stage2.wasm pnpm build
pnpm smoke
```

Run these commands in `playground/`. `pnpm dev` also generates the browser
compiler, using the newest local stage2 when `PLAYGROUND_STAGE2` is unset.
`pnpm smoke` serves the production build and runs all presets in Chromium with
Playwright. The compiler binding under `src/generated/` is generated and ignored
by Git; the build and CI recreate it from stage2.

The browser host currently provides stdout through WASI `fd_write`. Programs
that require other host capabilities need an appropriate browser host adapter.
