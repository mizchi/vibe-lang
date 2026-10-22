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

The `book-pages` workflow publishes the deck next to The Vibe Book, at
`/slides/` of the Pages site (https://mizchi.github.io/vibe-lang/slides/), with
its compiler built from the same stage2 as the book.

- `→` / `Space` / `PageDown` next, `←` / `PageUp` previous, `Home` / `End`.
- `r` compiles and runs the demo on the current slide; `⌘/Ctrl + Enter` does
  the same inside an editor, and `Esc` returns focus to the deck.
- A demo slide is a gallery of samples: `1`–`9` (and `0` for the tenth) or the
  numbered tabs pick one. Tabs in red are samples the compiler refuses.
- `n` toggles the speaker notes (timed for a 12-minute slot), `f` toggles
  fullscreen. The URL hash is the slide number.

Slide content lives in `src/slides/content.ts`. Each sample is a real `.vibe`
file under `src/slides/samples/<gallery>/`, listed in `content.ts` with the
stdout it must print (`expect`) or a substring of the compile error it must be
refused with (`refuse`). `pnpm smoke:slides` runs every sample in Chromium and
holds it to that.

The figures are D2 sources under `src/slides/figures/`, laid out by TALA.
`pnpm figures` re-renders them (it needs `d2` with `tala (bundled)` in
`d2 layout`); the SVGs are committed, so building the deck never needs `d2`.

`pnpm build:slides-preview` builds the deck without the browser compiler, so it
needs no stage2. In that build, Run shows the result `smoke:slides` checks for
the unedited sample and refuses edited source, since nothing can compile it.
