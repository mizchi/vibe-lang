import * as monaco from "monaco-editor";
import { compileAndRun } from "../browser-runtime.js";
import { vibeLanguageConfig, vibeMonarchLanguage } from "../vibe-monarch.js";
import { CODE, DEMOS, SLIDES, type Demo } from "./content.js";

monaco.languages.register({ id: "vibe", extensions: [".vibe"] });
monaco.languages.setLanguageConfiguration("vibe", vibeLanguageConfig);
monaco.languages.setMonarchTokensProvider("vibe", vibeMonarchLanguage);
// Token colours follow lib/@vibex/book/theme.vibe so the deck reads like the book.
monaco.editor.defineTheme("vibe-book", {
  base: "vs-dark",
  inherit: true,
  rules: [
    { token: "keyword", foreground: "e8a35a", fontStyle: "bold" },
    { token: "type.identifier", foreground: "7eb6d6" },
    { token: "string", foreground: "8fbf8a" },
    { token: "string.char", foreground: "8fbf8a" },
    { token: "string.escape", foreground: "c3a6e0" },
    { token: "comment", foreground: "8a8376", fontStyle: "italic" },
    { token: "number", foreground: "d4a574" },
    { token: "constant.language", foreground: "d4a574" },
    { token: "namespace", foreground: "c3a6e0" },
    { token: "annotation", foreground: "c792ea" },
    { token: "operator", foreground: "e07a3c" },
  ],
  colors: {
    "editor.background": "#1e1c19",
    "editor.foreground": "#f4efe4",
    "editorLineNumber.foreground": "#5c564c",
    "editor.lineHighlightBackground": "#26231f",
  },
});
monaco.editor.setTheme("vibe-book");

const PREVIEW = import.meta.env.VITE_SLIDES_PREVIEW === "1";
const deck = document.getElementById("deck")!;
const counter = document.getElementById("counter")!;
const progress = document.querySelector<HTMLSpanElement>("#progress span")!;
const compilerState = document.getElementById("compiler-state")!;
const notesEl = document.getElementById("notes")!;

const slideEls = SLIDES.map((slide, index) => {
  const el = document.createElement("section");
  el.className = `slide ${slide.className ?? ""}`.trim();
  el.dataset.index = String(index);
  el.innerHTML = slide.html;
  deck.appendChild(el);
  return el;
});

// Static code blocks: colourised once, never editable.
for (const pre of deck.querySelectorAll<HTMLPreElement>("pre.code[data-src]")) {
  const source = CODE[pre.dataset.src!];
  if (source === undefined) throw new Error(`slides: unknown code block ${pre.dataset.src}`);
  void monaco.editor.colorize(source.trim(), "vibe", { tabSize: 2 }).then((html) => {
    pre.innerHTML = html;
  });
}

type LiveDemo = { editor: monaco.editor.IStandaloneCodeEditor; run: () => Promise<void> };
const liveDemos = new Map<HTMLElement, LiveDemo>();

function demoFontSize(): number {
  const width = document.body.classList.contains("view-all") ? 1280 : deck.clientWidth;
  return Math.max(11, Math.round(width * 0.0138));
}

function mountDemo(host: HTMLElement): LiveDemo {
  const existing = liveDemos.get(host);
  if (existing) return existing;
  const found: Demo | undefined = DEMOS[host.dataset.demo!];
  if (!found) throw new Error(`slides: unknown demo ${host.dataset.demo}`);
  const demo: Demo = found;
  host.innerHTML = `
    <div class="editor-wrap"><div class="editor"></div></div>
    <div class="side">
      <div class="toolbar">
        <button class="run" type="button">▶ Run</button>
        <button class="reset" type="button">Reset</button>
        <span class="timing"></span>
      </div>
      <pre class="output idle">⌘/Ctrl + Enter で実行</pre>
      ${demo.hint ? `<div class="hint">${demo.hint}</div>` : ""}
    </div>`;
  const editor = monaco.editor.create(host.querySelector<HTMLElement>(".editor")!, {
    value: demo.source.trim(),
    language: "vibe",
    theme: "vibe-book",
    automaticLayout: true,
    minimap: { enabled: false },
    fontSize: demoFontSize(),
    lineNumbers: "off",
    glyphMargin: false,
    folding: false,
    scrollBeyondLastLine: false,
    renderLineHighlight: "none",
    overviewRulerLanes: 0,
    tabSize: 2,
    padding: { top: 6 },
    bracketPairColorization: { enabled: false },
    wordWrap: "on",
    guides: { indentation: false },
  });
  const runButton = host.querySelector<HTMLButtonElement>("button.run")!;
  const output = host.querySelector<HTMLPreElement>(".output")!;
  const timing = host.querySelector<HTMLSpanElement>(".timing")!;
  async function run() {
    runButton.disabled = true;
    output.className = "output idle";
    output.textContent = "compiling in this tab…";
    await new Promise<void>((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
    const started = performance.now();
    if (PREVIEW) {
      // A build without the browser compiler (VITE_SLIDES_PREVIEW=1): the only
      // honest answer is the output the smoke test checks for the unedited source.
      if (editor.getValue().trim() !== demo.source.trim()) {
        output.className = "output error";
        output.textContent = "プレビュー版にはコンパイラが入っていないので、編集したコードは実行できません。Reset で元のコードに戻すと、CI で確認済みの出力を表示します。";
      } else {
        output.className = "output";
        output.textContent = `${demo.expect}\n(プレビュー: 元のコードについて CI で確認済みの出力)`;
      }
      timing.textContent = "";
      runButton.disabled = false;
      return;
    }
    try {
      const stdout = await compileAndRun(editor.getValue(), demo.entry ?? "main");
      output.className = "output";
      output.textContent = stdout === "" ? "(no output)" : stdout;
    } catch (error) {
      output.className = "output error";
      output.textContent = String(error instanceof Error ? error.message : error);
    } finally {
      timing.textContent = `compile+run ${Math.round(performance.now() - started)} ms`;
      runButton.disabled = false;
    }
  }
  runButton.addEventListener("click", () => void run());
  host.querySelector<HTMLButtonElement>("button.reset")!.addEventListener("click", () => {
    editor.setValue(demo.source.trim());
    output.className = "output idle";
    output.textContent = "⌘/Ctrl + Enter で実行";
    timing.textContent = "";
  });
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, () => void run());
  editor.addCommand(monaco.KeyCode.Escape, () => (document.activeElement as HTMLElement | null)?.blur());
  const live = { editor, run };
  liveDemos.set(host, live);
  return live;
}

let current = 0;

function show(index: number) {
  current = Math.max(0, Math.min(SLIDES.length - 1, index));
  slideEls.forEach((el, i) => el.classList.toggle("active", i === current));
  for (const host of slideEls[current].querySelectorAll<HTMLElement>(".demo[data-demo]")) {
    mountDemo(host).editor.layout();
  }
  counter.textContent = `${current + 1} / ${SLIDES.length}`;
  progress.style.width = `${((current + 1) / SLIDES.length) * 100}%`;
  if (location.hash !== `#${current + 1}`) history.replaceState(null, "", `#${current + 1}`);
  notesEl.textContent = SLIDES[current].notes ?? "";
}

function editorHasFocus(): boolean {
  const active = document.activeElement;
  return active instanceof HTMLElement && active.closest(".editor-wrap") !== null;
}

document.addEventListener("keydown", (event) => {
  if (document.body.classList.contains("view-all")) return;
  if (editorHasFocus() || event.metaKey || event.ctrlKey || event.altKey) return;
  switch (event.key) {
    case "ArrowRight":
    case "ArrowDown":
    case "PageDown":
    case " ":
      show(current + 1);
      break;
    case "ArrowLeft":
    case "ArrowUp":
    case "PageUp":
      show(current - 1);
      break;
    case "Home":
      show(0);
      break;
    case "End":
      show(SLIDES.length - 1);
      break;
    case "r": {
      // Run the demo on the current slide without reaching for the mouse.
      const host = slideEls[current].querySelector<HTMLElement>(".demo[data-demo]");
      if (host) void mountDemo(host).run();
      break;
    }
    case "n":
      notesEl.hidden = !notesEl.hidden;
      break;
    case "f":
      if (document.fullscreenElement) void document.exitFullscreen();
      else void document.documentElement.requestFullscreen();
      break;
    default:
      return;
  }
  event.preventDefault();
});

// Printing shows every slide, so every demo needs its editor, not just the visited ones.
window.addEventListener("beforeprint", () => {
  for (const host of deck.querySelectorAll<HTMLElement>(".demo[data-demo]")) mountDemo(host);
});

window.addEventListener("resize", () => {
  for (const { editor } of liveDemos.values()) editor.updateOptions({ fontSize: demoFontSize() });
});
window.addEventListener("hashchange", () => {
  if (!document.body.classList.contains("view-all")) show(Number(location.hash.slice(1)) - 1 || 0);
});

// Test hook for tests/slides-smoke.mjs: which slide holds which demo, and
// what its unedited source must print.
(window as unknown as { __slideDemos: unknown }).__slideDemos = slideEls.flatMap((el, index) =>
  Array.from(el.querySelectorAll<HTMLElement>(".demo[data-demo]"), (host) => ({
    slide: index + 1,
    id: host.dataset.demo!,
    expect: DEMOS[host.dataset.demo!].expect,
  })),
);

// `?view=all` stacks every slide at a fixed 1280x720 frame: the print view,
// and the only form in which a page gate (vlmkit) can read the whole deck.
if (new URLSearchParams(location.search).get("view") === "all") {
  document.body.classList.add("view-all");
  slideEls.forEach((el) => el.classList.add("active"));
  for (const host of deck.querySelectorAll<HTMLElement>(".demo[data-demo]")) mountDemo(host);
} else {
  show(Number(location.hash.slice(1)) - 1 || 0);
}
compilerState.textContent = PREVIEW
  ? "preview: compiler not bundled"
  : `selfhost vibec (wasm) · ${import.meta.env.VITE_VIBE_BUILD_LABEL ?? "local"}`;
compilerState.classList.add("ready");
