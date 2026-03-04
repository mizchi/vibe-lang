import {
  createVibeService,
  type VibeService,
  type EvalResult,
  type CheckResult,
} from "../../js/vibe/index.js";
import wasmUrl from "../../_build/wasm-gc/release/build/lib/lib.wasm?url";

const editor = document.getElementById("editor") as HTMLTextAreaElement;
const output = document.getElementById("output") as HTMLDivElement;
const diagnostics = document.getElementById("diagnostics") as HTMLDivElement;
const btnRun = document.getElementById("btn-run") as HTMLButtonElement;
const btnReset = document.getElementById("btn-reset") as HTMLButtonElement;
const btnShare = document.getElementById("btn-share") as HTMLButtonElement;
const presetSelect = document.getElementById("preset-select") as HTMLSelectElement;
const status = document.getElementById("status") as HTMLSpanElement;

type Preset = {
  id: string;
  source: string;
};

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

let service: VibeService | null = null;
let checkTimer: number | null = null;
let checkSeq = 0;

function encodeBase64Url(source: string): string {
  const bytes = new TextEncoder().encode(source);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
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
  const params = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  const encoded = params.get(HASH_CODE_KEY);
  if (!encoded) return null;
  return decodeBase64Url(encoded);
}

function writeCodeToHash(source: string) {
  const params = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  const encoded = encodeBase64Url(source);
  params.set(HASH_CODE_KEY, encoded);
  const nextHash = params.toString();
  const nextUrl = nextHash.length > 0
    ? `#${nextHash}`
    : `${window.location.pathname}${window.location.search}`;
  history.replaceState(null, "", nextUrl);
}

function getPresetById(id: string): Preset | null {
  const preset = PRESETS.find((item) => item.id === id);
  return preset ?? null;
}

function syncPresetSelection(source: string) {
  const preset = PRESETS.find((item) => item.source === source);
  presetSelect.value = preset ? preset.id : "custom";
}

function setEditorSource(source: string, syncHash = true) {
  editor.value = source;
  syncPresetSelection(source);
  if (syncHash) {
    writeCodeToHash(source);
  }
}

function flashShareButton(label: string) {
  const original = btnShare.textContent || "Share URL";
  btnShare.textContent = label;
  window.setTimeout(() => {
    btnShare.textContent = original;
  }, 1200);
}

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

function renderDiagnostics(result: CheckResult | null, runtimeError?: string) {
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
}

async function runCheck(seq: number) {
  if (!service) return;
  const source = editor.value;
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
  const source = editor.value;
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

async function shareCurrentUrl() {
  writeCodeToHash(editor.value);
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

async function loadWasmModule(url: string): Promise<WebAssembly.Module> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Failed to fetch wasm: ${res.status}`);
  const bytes = await res.arrayBuffer();
  return WebAssembly.compile(bytes);
}

async function init() {
  try {
    const wasmModule = await loadWasmModule(wasmUrl);
    service = await createVibeService({ wasmModule });
    status.textContent = "Ready";
    status.className = "ready";
    btnRun.disabled = false;
    btnReset.disabled = false;
    scheduleCheck(0);
  } catch (e) {
    status.textContent = `Error: ${e}`;
    status.className = "error";
    console.error("Failed to init VibeService:", e);
  }
}

btnRun.addEventListener("click", runEval);
btnReset.addEventListener("click", resetSession);
btnShare.addEventListener("click", () => {
  void shareCurrentUrl();
});
presetSelect.addEventListener("change", () => {
  const preset = getPresetById(presetSelect.value);
  if (!preset) return;
  setEditorSource(preset.source);
  scheduleCheck(0);
});
editor.addEventListener("input", () => {
  syncPresetSelection(editor.value);
  writeCodeToHash(editor.value);
  scheduleCheck();
});

document.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
    e.preventDefault();
    runEval();
  }
});

// Tab key inserts spaces in editor
editor.addEventListener("keydown", (e) => {
  if (e.key === "Tab") {
    e.preventDefault();
    const start = editor.selectionStart;
    const end = editor.selectionEnd;
    editor.value = editor.value.substring(0, start) + "  " + editor.value.substring(end);
    editor.selectionStart = editor.selectionEnd = start + 2;
    syncPresetSelection(editor.value);
    writeCodeToHash(editor.value);
    scheduleCheck();
  }
});

const sourceFromHash = readCodeFromHash();
if (sourceFromHash !== null) {
  setEditorSource(sourceFromHash, false);
} else {
  syncPresetSelection(editor.value);
}

init();
