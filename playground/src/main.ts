import * as monaco from "monaco-editor";
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
const btnRun = document.getElementById("btn-run") as HTMLButtonElement;
const btnReset = document.getElementById("btn-reset") as HTMLButtonElement;
const btnShare = document.getElementById("btn-share") as HTMLButtonElement;
const presetSelect = document.getElementById(
  "preset-select",
) as HTMLSelectElement;
const statusEl = document.getElementById("status") as HTMLSpanElement;

// ── Presets / URL ─────────────────────────────────────────────

type Preset = { id: string; source: string };

const HASH_CODE_KEY = "code";
const PRESETS: Preset[] = [
  {
    id: "fib",
    source: `let rec fib = (n: Int) -> Int {
  match n {
    0 => 0,
    1 => 1,
    _ => fib(n - 1) + fib(n - 2),
  }
}
fib(10)`,
  },
  {
    id: "map-filter",
    source: `let values = [1, 2, 3, 4, 5]
let doubled = array_map(values, (x: Int) -> Int { x * 2 })
let evens = array_filter(doubled, (x: Int) -> Bool { x % 2 == 0 })
array_fold(evens, 0, (acc: Int, x: Int) -> Int { acc + x })`,
  },
  {
    id: "parse-double",
    source: `double_to_int(parse_double("1.5") + parse_double("2.5"))`,
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

let service: any = null;
let checkTimer: number | null = null;
let checkSeq = 0;

function renderResult(result: any) {
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
        .map((d: any) => `[${d.stage}] ${d.message}`)
        .join("\n");
      output.appendChild(document.createTextNode("\n" + warnings));
    }
  } else {
    const errSpan = document.createElement("span");
    errSpan.className = "result-error";
    errSpan.textContent = result.diagnostics
      .map((d: any) => {
        let msg = `[${d.stage}] ${d.message}`;
        if (d.hint) msg += `\n  hint: ${d.hint}`;
        if (d.note) msg += `\n  note: ${d.note}`;
        return msg;
      })
      .join("\n");
    output.appendChild(errSpan);
  }
}

function renderDiagnostics(
  result: any | null,
  runtimeError?: string,
) {
  diagnostics.textContent = "";

  if (runtimeError) {
    const line = document.createElement("div");
    line.className = "diag-item error";
    line.textContent = runtimeError;
    diagnostics.appendChild(line);
    return;
  }

  if (!result) {
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

  result.diagnostics.forEach((diag: any, index: number) => {
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
  const model = editor.getModel();
  if (model && result) {
    const markers: monaco.editor.IMarkerData[] = result.diagnostics.map(
      (diag: any, index: number) => ({
        severity:
          index < result.error_count
            ? monaco.MarkerSeverity.Error
            : monaco.MarkerSeverity.Warning,
        message: diag.message + (diag.note ? `\n${diag.note}` : ""),
        startLineNumber: 1,
        startColumn: 1,
        endLineNumber: 1,
        endColumn: 1,
      }),
    );
    monaco.editor.setModelMarkers(model, "vibe", markers);
  }
}

async function runCheck(seq: number) {
  if (!service) return;
  const source = editor.getValue();
  if (!source.trim()) {
    if (seq === checkSeq) renderDiagnostics(null);
    return;
  }
  try {
    const result = await service.check(source);
    if (seq === checkSeq) {
      renderDiagnostics(result);
    }
  } catch (e) {
    if (seq === checkSeq) {
      renderDiagnostics(null, `Check error: ${e}`);
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
    void runCheck(seq);
  }, delayMs);
}

async function runEval() {
  if (!service) return;
  const source = editor.getValue();
  if (!source.trim()) return;

  btnRun.disabled = true;
  try {
    const result = await service.eval({ source });
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

async function resetSession() {
  if (!service) return;
  await service.evalReset();
  output.textContent = "";
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

// ── Event handlers ────────────────────────────────────────────

btnRun.addEventListener("click", runEval);
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

  try {
    const { createVibeService } = await import("../../js/vibe/index.js");
    const wasmModule = await loadWasmModule(`${import.meta.env.BASE_URL}vibe-runtime.wasm`);
    service = await createVibeService({ wasmModule });
    statusEl.textContent = "Ready";
    statusEl.className = "ready";
    btnRun.disabled = false;
    btnReset.disabled = false;
    scheduleCheck(0);
  } catch (e) {
    console.warn("Vibe runtime not available:", e);
    statusEl.textContent = "Editor only (no runtime)";
    statusEl.className = "ready";
  }

  await tsPromise;
}

init();
