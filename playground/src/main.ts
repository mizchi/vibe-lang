import * as monaco from "monaco-editor";
import { compileAndRun } from "./browser-runtime.js";
import { vibeLanguageConfig, vibeMonarchLanguage } from "./vibe-monarch.js";

type Preset = { id: string; source: string };

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

const presetSelect = document.getElementById("preset-select") as HTMLSelectElement;
const runButton = document.getElementById("btn-run") as HTMLButtonElement;
const shareButton = document.getElementById("btn-share") as HTMLButtonElement;
const status = document.getElementById("status") as HTMLSpanElement;
const output = document.getElementById("output") as HTMLPreElement;
const buildMeta = document.getElementById("build-meta") as HTMLSpanElement;

monaco.languages.register({ id: "vibe", extensions: [".vibe"] });
monaco.languages.setLanguageConfiguration("vibe", vibeLanguageConfig);
monaco.languages.setMonarchTokensProvider("vibe", vibeMonarchLanguage);

function decodeSharedCode(): string | null {
  const encoded = new URLSearchParams(location.hash.slice(1)).get("code");
  if (!encoded) return null;
  try {
    const binary = atob(encoded.replace(/-/g, "+").replace(/_/g, "/"));
    return new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
  } catch {
    return null;
  }
}

function shareCode(source: string) {
  const binary = Array.from(new TextEncoder().encode(source), (byte) => String.fromCharCode(byte)).join("");
  const encoded = btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
  const params = new URLSearchParams(location.hash.slice(1));
  params.set("code", encoded);
  history.replaceState(null, "", `#${params}`);
}

const editor = monaco.editor.create(document.getElementById("editor-container")!, {
  value: decodeSharedCode() ?? PRESETS[0].source,
  language: "vibe",
  theme: "vs-dark",
  automaticLayout: true,
  minimap: { enabled: false },
  fontSize: 14,
  scrollBeyondLastLine: false,
});

function syncPreset() {
  presetSelect.value = PRESETS.find((preset) => preset.source === editor.getValue())?.id ?? "custom";
}

syncPreset();
editor.onDidChangeModelContent(() => {
  syncPreset();
  shareCode(editor.getValue());
});

presetSelect.addEventListener("change", () => {
  const preset = PRESETS.find((item) => item.id === presetSelect.value);
  if (preset) editor.setValue(preset.source);
});

async function run() {
  runButton.disabled = true;
  status.textContent = "Running";
  output.className = "";
  output.textContent = "Compiling...";
  await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
  try {
    output.textContent = await compileAndRun(editor.getValue());
    status.textContent = "Ready";
  } catch (error) {
    output.className = "error";
    output.textContent = String(error);
    status.textContent = "Ready";
  } finally {
    runButton.disabled = false;
  }
}

runButton.addEventListener("click", () => void run());
editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, () => void run());

shareButton.addEventListener("click", async () => {
  shareCode(editor.getValue());
  try {
    await navigator.clipboard.writeText(location.href);
    shareButton.textContent = "Copied";
  } catch {
    shareButton.textContent = "URL updated";
  }
  setTimeout(() => { shareButton.textContent = "Share URL"; }, 1500);
});

buildMeta.textContent = `selfhost vibec · ${import.meta.env.VITE_VIBE_BUILD_LABEL ?? "local"}`;
status.textContent = "Ready";
runButton.disabled = false;
