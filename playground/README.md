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

The browser host provides stdout through WASI `fd_write` and the compiler's
`vibe.stdout_write_stream` / `vibe.stdout_write_char` imports. Programs that
require other host capabilities need an appropriate browser host adapter.

## Slides

`slides.html` is the deck for the talk at "自作プログラミング言語を自慢する会"
(2026-10-22). It is built by the same Vite config and uses the same browser
compiler as the playground, so every live demo compiles in the tab. Open
`/slides.html` under `pnpm dev`, or after `pnpm build` with `pnpm exec vite preview`.

- `→` / `Space` / `PageDown` next, `←` / `PageUp` previous, `Home` / `End`.
- `r` compiles and runs the demo on the current slide; `⌘/Ctrl + Enter` does
  the same inside an editor, and `Esc` returns focus to the deck.
- `n` toggles the speaker notes (timed for a 12-minute slot), `f` toggles
  fullscreen. The URL hash is the slide number.

Slide content lives in `src/slides/content.ts`. `pnpm smoke:slides` runs every
live demo in Chromium and requires it to print the `expect` recorded next to
its source.

`pnpm build:slides-preview` builds the deck without the browser compiler, so it
needs no stage2. In that build, Run shows the output `smoke:slides` checks for
the unedited demo source and refuses edited source, since nothing can compile
it.
