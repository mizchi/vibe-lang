import { createVibeService, type VibeService, type EvalResult } from "../../js/vibe/index.js";
import wasmUrl from "../../_build/wasm-gc/release/build/lib/lib.wasm?url";

const editor = document.getElementById("editor") as HTMLTextAreaElement;
const output = document.getElementById("output") as HTMLDivElement;
const btnRun = document.getElementById("btn-run") as HTMLButtonElement;
const btnReset = document.getElementById("btn-reset") as HTMLButtonElement;
const status = document.getElementById("status") as HTMLSpanElement;

let service: VibeService | null = null;

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
  } catch (e) {
    status.textContent = `Error: ${e}`;
    status.className = "error";
    console.error("Failed to init VibeService:", e);
  }
}

btnRun.addEventListener("click", runEval);
btnReset.addEventListener("click", resetSession);

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
  }
});

init();
