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
const status = document.getElementById("status") as HTMLSpanElement;

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
editor.addEventListener("input", () => scheduleCheck());

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
    scheduleCheck();
  }
});

init();
