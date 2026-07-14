#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BOOTSTRAP_OUT_DIR="${VIBE_BOOTSTRAP_OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_bootstrap}"
CACHE_PATH="${VIBE_BOOTSTRAP_BATCH_WEIGHT_CACHE:-${VIBE_BATCH_WEIGHT_CACHE:-$BOOTSTRAP_OUT_DIR/selfhost_test_batch_weights.json}}"
SEED_PATH="${VIBE_BOOTSTRAP_BATCH_WEIGHT_SEED:-${VIBE_BATCH_WEIGHT_SEED:-$PROJECT_ROOT/scripts/selfhost_test_batch_weights.seed.json}}"

if [ ! -f "$CACHE_PATH" ]; then
  echo "missing batch weight cache: $CACHE_PATH" >&2
  exit 1
fi

node - "$PROJECT_ROOT" "$CACHE_PATH" "$SEED_PATH" <<'EOF'
const fs = require("node:fs")
const path = require("node:path")

const [projectRootArg, cachePath, seedPath] = process.argv.slice(2)
const projectRoot = path.resolve(projectRootArg)

function loadMap(filePath) {
  if (!fs.existsSync(filePath)) {
    return {}
  }
  try {
    const parsed = JSON.parse(fs.readFileSync(filePath, "utf8"))
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed
    }
  } catch (_) {
    return {}
  }
  return {}
}

function normalizeKey(input) {
  const raw = String(input).replaceAll("\\", "/")
  if (!path.isAbsolute(raw)) {
    return path.posix.normalize(raw).replace(/^\/+/, "")
  }
  const relative = path.relative(projectRoot, raw).replaceAll("\\", "/")
  if (relative.startsWith("..")) {
    return path.posix.normalize(raw)
  }
  return path.posix.normalize(relative).replace(/^\/+/, "")
}

function normalizeWeight(value) {
  const weight = Number(value)
  if (!Number.isFinite(weight) || weight <= 0) {
    return null
  }
  return Math.trunc(weight)
}

function shouldIncludeSeedEntry(key) {
  if (!/^vibe\/compiler\/.+_test\.vibe$/.test(key)) {
    return false
  }
  const base = path.posix.basename(key)
  if (base === "selfhost_s5_test.vibe") {
    return false
  }
  if (base.startsWith("selfhost_s5_")) {
    return false
  }
  if (base === "codegen_parser_test.vibe") {
    return false
  }
  return true
}

const merged = new Map()
for (const [key, value] of Object.entries(loadMap(seedPath))) {
  const normalizedWeight = normalizeWeight(value)
  if (normalizedWeight === null) {
    continue
  }
  merged.set(normalizeKey(key), normalizedWeight)
}
for (const [key, value] of Object.entries(loadMap(cachePath))) {
  const normalizedWeight = normalizeWeight(value)
  if (normalizedWeight === null) {
    continue
  }
  merged.set(normalizeKey(key), normalizedWeight)
}

const entries = []
for (const [key, weight] of merged.entries()) {
  if (!shouldIncludeSeedEntry(key)) {
    continue
  }
  if (!fs.existsSync(path.join(projectRoot, key))) {
    continue
  }
  entries.push([key, weight])
}
entries.sort((a, b) => {
  if (a[1] !== b[1]) {
    return b[1] - a[1]
  }
  return a[0].localeCompare(b[0])
})

fs.writeFileSync(seedPath, `${JSON.stringify(Object.fromEntries(entries), null, 2)}\n`)
console.log(`refreshed selfhost batch weight seed: ${entries.length} entries`)
EOF
