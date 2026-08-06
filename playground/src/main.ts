import * as monaco from "monaco-editor";
import type {
  CheckResult,
  EvalResult,
  FormatResult,
  IdeOutlineResult,
  VibeService,
} from "../../clients/js/index.js";
import { vibeLanguageConfig, vibeMonarchLanguage } from "./vibe-monarch.js";
import {
  initTreeSitter,
  computeSemanticTokens,
  getSemanticTokensLegend,
} from "./vibe-treesitter.js";

// ── Monaco setup ──────────────────────────────────────────────

// Register Vibe language
monaco.languages.register({ id: "vibe", extensions: [".vibe"] });
monaco.languages.setLanguageConfiguration("vibe", vibeLanguageConfig);
monaco.languages.setMonarchTokensProvider("vibe", vibeMonarchLanguage);

// Theme
monaco.editor.defineTheme("vibe-dark", {
  base: "vs-dark",
  inherit: true,
  rules: [
    { token: "keyword.vibe", foreground: "C586C0" },
    { token: "type.identifier.vibe", foreground: "4EC9B0" },
    { token: "constant.language.vibe", foreground: "569CD6" },
    { token: "string.vibe", foreground: "CE9178" },
    { token: "string.escape.vibe", foreground: "D7BA7D" },
    { token: "string.char.vibe", foreground: "CE9178" },
    { token: "number.vibe", foreground: "B5CEA8" },
    { token: "number.float.vibe", foreground: "B5CEA8" },
    { token: "number.hex.vibe", foreground: "B5CEA8" },
    { token: "comment.vibe", foreground: "6A9955" },
    { token: "operator.vibe", foreground: "D4D4D4" },
    { token: "namespace.vibe", foreground: "4FC1FF" },
    { token: "delimiter.vibe", foreground: "808080" },
  ],
  colors: {
    "editor.background": "#0d1117",
    "editor.foreground": "#e0e0e0",
  },
});

// ── DOM elements ──────────────────────────────────────────────

const editorContainer = document.getElementById("editor-container")!;
const output = document.getElementById("output") as HTMLDivElement;
const diagnostics = document.getElementById("diagnostics") as HTMLDivElement;
const outlineEl = document.getElementById("outline") as HTMLDivElement;
const btnRun = document.getElementById("btn-run") as HTMLButtonElement;
const btnFormat = document.getElementById("btn-format") as HTMLButtonElement;
const btnReset = document.getElementById("btn-reset") as HTMLButtonElement;
const btnShare = document.getElementById("btn-share") as HTMLButtonElement;
const presetSelect = document.getElementById(
  "preset-select",
) as HTMLSelectElement;
const statusEl = document.getElementById("status") as HTMLSpanElement;
const buildMetaEl = document.getElementById("build-meta") as HTMLSpanElement;

const BUILD_LABEL = import.meta.env.VITE_VIBE_BUILD_LABEL ?? "local";
const BUILD_TARGET = "src/lib wasm-gc";

// ── Presets / URL ─────────────────────────────────────────────

type Preset = { id: string; source: string };

const HASH_CODE_KEY = "code";
const PRESETS: Preset[] = [
  {
    id: "effects-error",
    source: `let safe_div = (a: Int, b: Int) -> Int with Exception {
  if eq(b, 0) { throw("division by zero") } else { a / b }
}

export let _start = () -> Int {
  let ok = handle { safe_div(12, 3) } with Exception { Throw(_) => -1 }
  let err = handle { safe_div(12, 0) } with Exception { Throw(_) => -1 }
  ok + err
}`,
  },
  {
    id: "enum-match",
    source: `enum Shape {
  Circle(Int);
  Rect(Int, Int)
}

let area = (shape: Shape) -> Int {
  match shape {
    Circle(r) => r * r * 3,
    Rect(w, h) => w * h,
  }
}

export let _start = () -> Int {
  area(Circle(5)) + area(Rect(3, 4))
}`,
  },
  {
    id: "collections",
    source: `let values = [1, 2, 3, 4, 5]

let squared_evens = () -> Array[Int] {
  let squared = Array::map(values, (x: Int) -> Int { x * x })
  Array::filter(squared, (x: Int) -> Bool { x % 2 == 0 })
}

export let _start = () -> Int {
  Array::fold(squared_evens(), 0, (acc: Int, x: Int) -> Int { acc + x })
}`,
  },
  {
    id: "suberror",
    source: `suberror AppError {
  NotFound(String);
  InvalidInput(Int)
}

let risky = () -> Int with Exception {
  throw(NotFound("missing"))
}

export let _start = () -> Int {
  handle { risky() } with Exception { Throw(_) => -1 }
}`,
  },
];

function encodeBase64Url(source: string): string {
  const bytes = new TextEncoder().encode(source);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function decodeBase64Url(encoded: string): string | null {
  if (!encoded) return null;
  const normalized = encoded.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) {
      bytes[i] = binary.charCodeAt(i);
    }
    return new TextDecoder().decode(bytes);
  } catch {
    return null;
  }
}

function readCodeFromHash(): string | null {
  const params = new URLSearchParams(
    window.location.hash.replace(/^#/, ""),
  );
  const encoded = params.get(HASH_CODE_KEY);
  if (!encoded) return null;
  return decodeBase64Url(encoded);
}

function writeCodeToHash(source: string) {
  const params = new URLSearchParams(
    window.location.hash.replace(/^#/, ""),
  );
  const encoded = encodeBase64Url(source);
  params.set(HASH_CODE_KEY, encoded);
  const nextHash = params.toString();
  const nextUrl =
    nextHash.length > 0
      ? `#${nextHash}`
      : `${window.location.pathname}${window.location.search}`;
  history.replaceState(null, "", nextUrl);
}

function syncPresetSelection(source: string) {
  const preset = PRESETS.find((item) => item.source === source);
  presetSelect.value = preset ? preset.id : "custom";
}

// ── Create Monaco editor ──────────────────────────────────────

const defaultSource = readCodeFromHash() ?? PRESETS[0].source;

const editor = monaco.editor.create(editorContainer, {
  value: defaultSource,
  language: "vibe",
  theme: "vibe-dark",
  fontSize: 14,
  fontFamily: '"SF Mono", "Fira Code", "Cascadia Code", monospace',
  lineNumbers: "on",
  minimap: { enabled: false },
  scrollBeyondLastLine: false,
  automaticLayout: true,
  tabSize: 2,
  insertSpaces: true,
  padding: { top: 8 },
  overviewRulerLanes: 0,
  renderLineHighlight: "line",
  "semanticHighlighting.enabled": true,
});

syncPresetSelection(defaultSource);

// ── Vibe service ──────────────────────────────────────────────

type OutlineSymbol = {
  name: string;
  kind: string;
  signature: string;
  line: number;
  column: number;
};

let service: VibeService | null = null;
let checkTimer: number | null = null;
let checkSeq = 0;

function renderResult(result: EvalResult) {
  output.textContent = "";
  if (result.ok) {
    if (result.value !== null) {
      const valueSpan = document.createElement("span");
      valueSpan.className = "result-ok";
      valueSpan.textContent = result.value;
      output.appendChild(valueSpan);

      const typeSpan = document.createElement("span");
      typeSpan.className = "result-type";
      typeSpan.textContent = ` : ${result.value_type}`;
      output.appendChild(typeSpan);
    } else {
      const span = document.createElement("span");
      span.className = "result-type";
      span.textContent = "(no value)";
      output.appendChild(span);
    }
    if (result.diagnostics.length > 0) {
      const warnings = result.diagnostics
        .map((d) => `[${d.stage}] ${d.message}`)
        .join("\n");
      output.appendChild(document.createTextNode("\n" + warnings));
    }
  } else {
    const errSpan = document.createElement("span");
    errSpan.className = "result-error";
    errSpan.textContent = result.diagnostics
      .map((d) => {
        let msg = `[${d.stage}] ${d.message}`;
        if (d.hint) msg += `\n  hint: ${d.hint}`;
        if (d.note) msg += `\n  note: ${d.note}`;
        return msg;
      })
      .join("\n");
    output.appendChild(errSpan);
  }
}

function offsetToPosition(
  source: string,
  offset: number,
): { line: number; column: number } {
  let line = 1;
  let column = 1;
  for (let i = 0; i < offset && i < source.length; i++) {
    if (source[i] === "\n") {
      line++;
      column = 1;
    } else {
      column++;
    }
  }
  return { line, column };
}

function renderDiagnostics(
  result: CheckResult | null,
  runtimeError?: string,
) {
  diagnostics.textContent = "";
  const model = editor.getModel();

  if (runtimeError) {
    if (model) {
      monaco.editor.setModelMarkers(model, "vibe", []);
    }
    const line = document.createElement("div");
    line.className = "diag-item error";
    line.textContent = runtimeError;
    diagnostics.appendChild(line);
    return;
  }

  if (!result) {
    if (model) {
      monaco.editor.setModelMarkers(model, "vibe", []);
    }
    const line = document.createElement("div");
    line.className = "diag-empty";
    line.textContent = "Edit code to see diagnostics.";
    diagnostics.appendChild(line);
    return;
  }

  const summary = document.createElement("div");
  summary.className = "diag-summary";
  summary.textContent = `errors: ${result.error_count}, warnings: ${result.warning_count}`;
  diagnostics.appendChild(summary);

  if (result.diagnostics.length === 0) {
    const line = document.createElement("div");
    line.className = "diag-empty";
    line.textContent = "No diagnostics.";
    diagnostics.appendChild(line);
    return;
  }

  result.diagnostics.forEach((diag, index) => {
    const isError = index < result.error_count;
    const line = document.createElement("div");
    line.className = isError ? "diag-item error" : "diag-item warning";
    let text = `[${diag.stage}] ${diag.message}`;
    if (diag.hint) text += `\n  hint: ${diag.hint}`;
    if (diag.note) text += `\n  note: ${diag.note}`;
    line.textContent = text;
    diagnostics.appendChild(line);
  });

  // Push diagnostics to Monaco markers
  if (model && result) {
    const source = model.getValue();
    const markers: monaco.editor.IMarkerData[] = result.diagnostics
      .flatMap((diag, index) => {
        if (!diag.span) {
          return [];
        }
        const start = offsetToPosition(source, diag.span.start);
        const end = offsetToPosition(source, diag.span.end);
        return [{
          severity:
            index < result.error_count
              ? monaco.MarkerSeverity.Error
              : monaco.MarkerSeverity.Warning,
          message:
            diag.message +
            (diag.hint ? `\nhint: ${diag.hint}` : "") +
            (diag.note ? `\nnote: ${diag.note}` : ""),
          startLineNumber: start.line,
          startColumn: start.column,
          endLineNumber: end.line,
          endColumn: end.column,
        }];
      });
    monaco.editor.setModelMarkers(model, "vibe", markers);
  }
}

function renderOutline(symbols: OutlineSymbol[], runtimeError?: string) {
  outlineEl.textContent = "";

  if (runtimeError) {
    const line = document.createElement("div");
    line.className = "outline-empty";
    line.textContent = runtimeError;
    outlineEl.appendChild(line);
    return;
  }

  if (symbols.length === 0) {
    const line = document.createElement("div");
    line.className = "outline-empty";
    line.textContent = "No symbols.";
    outlineEl.appendChild(line);
    return;
  }

  symbols.forEach((symbol) => {
    const row = document.createElement("button");
    row.type = "button";
    row.className = "outline-item";
    row.addEventListener("click", () => {
      editor.revealLineInCenter(symbol.line);
      editor.setPosition({ lineNumber: symbol.line, column: symbol.column });
      editor.focus();
    });

    const name = document.createElement("span");
    name.className = "outline-name";
    name.textContent = symbol.name;
    row.appendChild(name);

    const meta = document.createElement("span");
    meta.className = "outline-meta";
    meta.textContent = `${symbol.kind} · L${symbol.line}`;
    row.appendChild(meta);

    const signature = document.createElement("span");
    signature.className = "outline-signature";
    signature.textContent = symbol.signature;
    row.appendChild(signature);

    outlineEl.appendChild(row);
  });
}

async function runAnalysis(seq: number) {
  if (!service) return;
  const source = editor.getValue();
  if (!source.trim()) {
    if (seq === checkSeq) {
      renderDiagnostics(null);
      renderOutline([]);
    }
    return;
  }
  try {
    const [result, outline]: [CheckResult, IdeOutlineResult] = await Promise.all([
      service.check(source),
      service.ideOutline({ source }),
    ]);
    if (seq === checkSeq) {
      renderDiagnostics(result);
      if (outline.ok) {
        renderOutline(
          outline.symbols.map((symbol) => ({
            name: symbol.name,
            kind: symbol.kind,
            signature: symbol.signature,
            line: symbol.line,
            column: symbol.column,
          })),
        );
      } else {
        renderOutline([], outline.error);
      }
    }
  } catch (e) {
    if (seq === checkSeq) {
      renderDiagnostics(null, `Check error: ${e}`);
      renderOutline([], `Outline error: ${e}`);
    }
  }
}

function scheduleCheck(delayMs = 180) {
  if (!service) return;
  checkSeq += 1;
  const seq = checkSeq;
  if (checkTimer !== null) {
    window.clearTimeout(checkTimer);
  }
  checkTimer = window.setTimeout(() => {
    void runAnalysis(seq);
  }, delayMs);
}

async function runEval() {
  if (!service) return;
  const source = editor.getValue();
  if (!source.trim()) return;

  btnRun.disabled = true;
  try {
    await service.evalReset();
    const evalSource = source + "\n_start()";
    const result = await service.eval({ source: evalSource });
    renderResult(result);
  } catch (e) {
    output.textContent = "";
    const span = document.createElement("span");
    span.className = "result-error";
    span.textContent = `Runtime error: ${e}`;
    output.appendChild(span);
  } finally {
    btnRun.disabled = false;
  }
}

async function formatSource() {
  if (!service) return;
  const source = editor.getValue();
  if (!source.trim()) return;

  btnFormat.disabled = true;
  try {
    const result: FormatResult = await service.format(source);
    if (result.ok && result.changed) {
      editor.setValue(result.formatted);
    }
    scheduleCheck(0);
  } catch (e) {
    renderDiagnostics(null, `Format error: ${e}`);
  } finally {
    btnFormat.disabled = false;
  }
}

async function resetSession() {
  if (!service) return;
  await service.evalReset();
  output.textContent = "";
  replOutput.textContent = "";
  const span = document.createElement("span");
  span.className = "result-type";
  span.textContent = "Session reset.";
  output.appendChild(span);
  scheduleCheck(0);
}

function flashShareButton(label: string) {
  const original = btnShare.textContent || "Share URL";
  btnShare.textContent = label;
  window.setTimeout(() => {
    btnShare.textContent = original;
  }, 1200);
}

async function shareCurrentUrl() {
  writeCodeToHash(editor.getValue());
  const url = window.location.href;
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(url);
      flashShareButton("Copied!");
      return;
    } catch {
      // fallback below
    }
  }
  window.prompt("Copy this URL:", url);
  flashShareButton("URL Ready");
}

// ── REPL ──────────────────────────────────────────────────────

const replOutput = document.getElementById("repl-output") as HTMLDivElement;
const replInput = document.getElementById("repl-input") as HTMLInputElement;
const replHistory: string[] = [];
let replHistoryIndex = -1;

function appendReplLine(cls: string, text: string) {
  const div = document.createElement("div");
  div.className = "repl-line";
  const span = document.createElement("span");
  span.className = cls;
  span.textContent = text;
  div.appendChild(span);
  replOutput.appendChild(div);
  replOutput.scrollTop = replOutput.scrollHeight;
}

async function replEval(input: string) {
  if (!service) return;
  const trimmed = input.trim();
  if (!trimmed) return;

  replHistory.push(trimmed);
  replHistoryIndex = replHistory.length;
  appendReplLine("repl-prompt", "> " + trimmed);

  try {
    const result = await service.eval({ source: trimmed });
    if (result.ok) {
      if (result.value !== null) {
        appendReplLine("repl-value", result.value + " : " + result.value_type);
      }
    } else {
      for (const d of result.diagnostics) {
        appendReplLine("repl-error", d.message);
      }
    }
  } catch (e) {
    appendReplLine("repl-error", `Error: ${e}`);
  }
}

replInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    e.preventDefault();
    const value = replInput.value;
    replInput.value = "";
    void replEval(value);
  } else if (e.key === "ArrowUp") {
    e.preventDefault();
    if (replHistoryIndex > 0) {
      replHistoryIndex--;
      replInput.value = replHistory[replHistoryIndex];
    }
  } else if (e.key === "ArrowDown") {
    e.preventDefault();
    if (replHistoryIndex < replHistory.length - 1) {
      replHistoryIndex++;
      replInput.value = replHistory[replHistoryIndex];
    } else {
      replHistoryIndex = replHistory.length;
      replInput.value = "";
    }
  }
});

// ── Event handlers ────────────────────────────────────────────

btnRun.addEventListener("click", runEval);
btnFormat.addEventListener("click", () => void formatSource());
btnReset.addEventListener("click", resetSession);
btnShare.addEventListener("click", () => void shareCurrentUrl());

presetSelect.addEventListener("change", () => {
  const preset = PRESETS.find((p) => p.id === presetSelect.value);
  if (!preset) return;
  editor.setValue(preset.source);
  writeCodeToHash(preset.source);
  syncPresetSelection(preset.source);
  scheduleCheck(0);
});

editor.onDidChangeModelContent(() => {
  const source = editor.getValue();
  syncPresetSelection(source);
  writeCodeToHash(source);
  scheduleCheck();
});

// Ctrl+Enter to run
editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, () => {
  void runEval();
});

// ── Tree-sitter semantic tokens ───────────────────────────────

async function setupSemanticTokens() {
  try {
    await initTreeSitter(`${import.meta.env.BASE_URL}tree-sitter-vibe.wasm`);

    const legend = getSemanticTokensLegend();
    monaco.languages.registerDocumentSemanticTokensProvider("vibe", {
      getLegend: () => legend,
      provideDocumentSemanticTokens: (model) => {
        const code = model.getValue();
        const result = computeSemanticTokens(code);
        if (!result) return { data: new Uint32Array() };
        return { data: new Uint32Array(result.data) };
      },
      releaseDocumentSemanticTokens: () => {},
    });
  } catch (e) {
    console.warn("Tree-sitter semantic tokens unavailable:", e);
  }
}

// ── Init ──────────────────────────────────────────────────────

async function loadWasmModule(url: string): Promise<WebAssembly.Module> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Failed to fetch wasm: ${res.status}`);
  const bytes = await res.arrayBuffer();
  return WebAssembly.compile(bytes);
}

async function init() {
  // Start tree-sitter init in parallel
  const tsPromise = setupSemanticTokens();
  buildMetaEl.textContent = `${BUILD_TARGET} · ${BUILD_LABEL}`;

  try {
    const { createVibeService } = await import("../../clients/js/index.js");
    const wasmModule = await loadWasmModule(`${import.meta.env.BASE_URL}vibe-runtime.wasm`);
    service = await createVibeService({ wasmModule });
    statusEl.textContent = "Ready";
    statusEl.className = "ready";
    btnRun.disabled = false;
    btnFormat.disabled = false;
    btnReset.disabled = false;
    replInput.disabled = false;
    scheduleCheck(0);
  } catch (e) {
    console.warn("Vibe runtime not available:", e);
    statusEl.textContent = "Editor only (no runtime)";
    statusEl.className = "ready";
    renderOutline([], "Runtime unavailable.");
  }

  await tsPromise;
}

init();
