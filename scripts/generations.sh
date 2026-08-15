#!/usr/bin/env bash
set -euo pipefail
: "${VIBE_RC:=0}"; export VIBE_RC  # cutover: pin the compiler self-build / gate baseline to bump (RC only when explicitly VIBE_RC=1)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/trace_lib.sh"
PROJECT_ROOT="${VIBE_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
DEFAULT_MANIFEST="$PROJECT_ROOT/bootstrap/seed.json"
DEFAULT_OUT_ROOT="$PROJECT_ROOT/_build/selfhost/generations"
RUNNER_SCRIPT="${VIBE_GENERATION_RUNNER_SCRIPT:-$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh}"
SEED_ARTIFACT_OVERRIDE="${VIBE_GENERATION_SEED_ARTIFACT:-}"
if [ -n "${VIBE_POLICY_RAW_FS_ROOT:-}" ]; then
  [ "${VIBE_POLICY_RAW_FS_ROOT}" = "/workspace/repo" ] || {
    echo "selfhost generations: invalid policy root" >&2
    exit 1
  }
  [ "$RUNNER_SCRIPT" = "/opt/policy/scripts/run_wasm_vibe_host_runner.sh" ] || {
    echo "selfhost generations: invalid immutable policy runner hook" >&2
    exit 1
  }
  [ -f "$RUNNER_SCRIPT" ] && [ ! -L "$RUNNER_SCRIPT" ] || {
    echo "selfhost generations: immutable policy runner hook missing or redirected" >&2
    exit 1
  }
fi
if [ -n "$SEED_ARTIFACT_OVERRIDE" ]; then
  [ "$SEED_ARTIFACT_OVERRIDE" = "/opt/policy/bootstrap/seed/compiler.wasm" ] || {
    echo "selfhost generations: invalid immutable policy seed hook" >&2
    exit 1
  }
  [ -f "$SEED_ARTIFACT_OVERRIDE" ] && [ ! -L "$SEED_ARTIFACT_OVERRIDE" ] || {
    echo "selfhost generations: immutable policy seed hook missing or redirected" >&2
    exit 1
  }
fi
VALIDATE_WASM="${VIBE_GENERATION_VALIDATE_WASM:-1}"
VALIDATE_RUN="${VIBE_GENERATION_VALIDATE_RUN:-1}"
ALLOW_UNPINNED_SEED="${VIBE_GENERATION_ALLOW_UNPINNED_SEED:-0}"
CLI_INVOKE="${VIBE_GENERATION_CLI_INVOKE:-auto}"
SELFBUILD_INVOKE="${VIBE_GENERATION_SELFBUILD_INVOKE:-auto}"
FLAT_CLI_SOURCE="${VIBE_GENERATION_FLAT_CLI_SOURCE:-auto}"
SELFBUILD_OUT="$PROJECT_ROOT/_build/bench/wasi_selfbuild/index_stage2.wasm"
NODE_STACK_SIZE="${VIBE_GENERATION_NODE_STACK_SIZE:-131072}"
# Selfhost-generated wasm now emits guest-side memory.grow checks after heap
# bumps, so raw ABI runs do not need a fixed host pre-grow. Keep the env knob as
# an emergency rollback for old artifacts that still require a large upfront
# memory.
WASM_PRE_GROW_PAGES="${VIBE_GENERATION_WASM_PRE_GROW_PAGES:-0}"
DISABLE_PERSISTENT_ARTIFACT_CACHE="${VIBE_GENERATION_DISABLE_PERSISTENT_ARTIFACT_CACHE:-1}"
SKIP_RUN_INIT="${VIBE_GENERATION_SKIP_RUN_INIT:-1}"
GENERATION_INVOKE_MODE=""
GENERATION_ENTRY=""

usage() {
  cat >&2 <<'USAGE'
usage:
  scripts/generations.sh seed-info [--manifest PATH]
  scripts/generations.sh status [--manifest PATH] [--out-dir DIR]
  scripts/generations.sh build [--manifest PATH] [--out-dir DIR] [--entry PATH] [--entry-name NAME] [--stage3]
  scripts/generations.sh adopt --artifact PATH [--manifest PATH] [--name NAME] [--tag TAG] [--source-commit COMMIT]

The build command implements the Rust-style compiler generation policy:
stage0 fixed seed -> stage1 current source -> stage2 current source.

The status command is read-only: it reports the pinned seed (with sha
verification), the current source commit, and the latest generation manifest
(stage shas + stage3==stage2) so the stage0 -> stage1 -> stage2 -> bump flow is
traceable without rebuilding.
USAGE
}

die() {
  echo "selfhost generations: $*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$PROJECT_ROOT/$1" ;;
  esac
}

rel_path() {
  local path="$1"
  case "$path" in
    "$PROJECT_ROOT"/*) printf '%s\n' "${path#$PROJECT_ROOT/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

manifest_value() {
  local manifest="$1"
  local key_path="$2"
  node - "$manifest" "$key_path" <<'NODE'
const fs = require("node:fs");
const [manifestPath, keyPath] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
let value = data;
for (const key of keyPath.split(".")) {
  if (value == null || typeof value !== "object" || !(key in value)) {
    process.exit(2);
  }
  value = value[key];
}
if (value == null) process.exit(2);
process.stdout.write(String(value));
NODE
}

git_commit() {
  git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown'
}

git_dirty() {
  if ! git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'unknown'
    return
  fi
  if git -C "$PROJECT_ROOT" diff --quiet --ignore-submodules -- && \
    git -C "$PROJECT_ROOT" diff --cached --quiet --ignore-submodules --; then
    printf 'false'
  else
    printf 'true'
  fi
}

sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

load_seed() {
  MANIFEST_PATH="$1"
  [ -f "$MANIFEST_PATH" ] || die "seed manifest not found: $MANIFEST_PATH"
  SEED_NAME="$(manifest_value "$MANIFEST_PATH" seed.name || true)"
  SEED_TAG="$(manifest_value "$MANIFEST_PATH" seed.tag || true)"
  SEED_SOURCE_COMMIT="$(manifest_value "$MANIFEST_PATH" seed.source_commit || true)"
  SEED_ENTRY="$(manifest_value "$MANIFEST_PATH" seed.entry || true)"
  SEED_ENTRY_NAME="$(manifest_value "$MANIFEST_PATH" seed.entry_name || true)"
  SEED_ARTIFACT_REL="$(manifest_value "$MANIFEST_PATH" seed.artifact.path || true)"
  SEED_ARTIFACT_SHA="$(manifest_value "$MANIFEST_PATH" seed.artifact.sha256 || true)"
  [ -n "$SEED_NAME" ] || die "seed.name is required in $MANIFEST_PATH"
  [ -n "$SEED_ENTRY" ] || die "seed.entry is required in $MANIFEST_PATH"
  if [ -z "$SEED_ENTRY_NAME" ]; then
    SEED_ENTRY_NAME="cli_main"
  fi
  [ -n "$SEED_ARTIFACT_REL" ] || die "seed.artifact.path is required in $MANIFEST_PATH"
  if [ -n "$SEED_ARTIFACT_OVERRIDE" ]; then
    SEED_ARTIFACT_PATH="$SEED_ARTIFACT_OVERRIDE"
  else
    SEED_ARTIFACT_PATH="$(abs_path "$SEED_ARTIFACT_REL")"
  fi
}

verify_seed_artifact() {
  if [ -n "$SEED_ARTIFACT_SHA" ] && [ "${VIBE_GENERATION_AUTO_FETCH_SEED:-1}" = "1" ]; then
    local needs_fetch=0
    if [ ! -f "$SEED_ARTIFACT_PATH" ]; then
      needs_fetch=1
    else
      local on_disk
      on_disk="$(sha256_file "$SEED_ARTIFACT_PATH")"
      [ "$on_disk" = "$SEED_ARTIFACT_SHA" ] || needs_fetch=1
    fi
    if [ "$needs_fetch" = "1" ]; then
      # bootstrap/seed/*.wasm is a local build cache (gitignored), not
      # git-tracked — missing or stale is the expected steady state after
      # a fresh checkout or a seed.json bump. Fetch it from its pinned
      # release tag; this fails fast (no silent fallback) if unreachable.
      bash "$PROJECT_ROOT/scripts/ensure_seed.sh" --manifest "$MANIFEST_PATH"
    fi
  fi
  [ -f "$SEED_ARTIFACT_PATH" ] || die "seed artifact not found: $SEED_ARTIFACT_PATH"
  if [ -z "$SEED_ARTIFACT_SHA" ]; then
    if [ "$ALLOW_UNPINNED_SEED" != "1" ]; then
      die "seed artifact sha256 is empty in $MANIFEST_PATH (run adopt or set VIBE_GENERATION_ALLOW_UNPINNED_SEED=1)"
    fi
    echo "[selfhost-gen] warning: seed artifact is not sha-pinned" >&2
    return
  fi
  local actual
  actual="$(sha256_file "$SEED_ARTIFACT_PATH")"
  if [ "$actual" != "$SEED_ARTIFACT_SHA" ]; then
    die "seed artifact sha256 mismatch: expected=$SEED_ARTIFACT_SHA actual=$actual path=$SEED_ARTIFACT_PATH"
  fi
}

detect_wasm_host_import_abi() {
  local wasm="$1"
  [ -f "$wasm" ] || return 0
  node - "$wasm" <<'NODE'
const fs = require("node:fs");
const wasmPath = process.argv[2];
const buf = fs.readFileSync(wasmPath);

function readUleb(pos, end) {
  let value = 0;
  let shift = 0;
  let cursor = pos;
  while (cursor < end) {
    const byte = buf[cursor++];
    value += (byte & 0x7f) * (2 ** shift);
    if ((byte & 0x80) === 0) {
      return { value, next: cursor };
    }
    shift += 7;
    if (shift > 35) process.exit(0);
  }
  process.exit(0);
}

if (
  buf.length < 8 ||
  buf[0] !== 0x00 ||
  buf[1] !== 0x61 ||
  buf[2] !== 0x73 ||
  buf[3] !== 0x6d
) {
  process.exit(0);
}

let pos = 8;
while (pos < buf.length) {
  const sectionId = buf[pos++];
  const sectionLen = readUleb(pos, buf.length);
  pos = sectionLen.next;
  const sectionEnd = pos + sectionLen.value;
  if (sectionEnd > buf.length) process.exit(0);
  if (sectionId === 0) {
    const nameLen = readUleb(pos, sectionEnd);
    const nameStart = nameLen.next;
    const nameEnd = nameStart + nameLen.value;
    if (nameEnd > sectionEnd) process.exit(0);
    const name = buf.slice(nameStart, nameEnd).toString("utf8");
    if (name === "vibe.abi") {
      const payload = buf.slice(nameEnd, sectionEnd).toString("utf8");
      const match = payload.match(/(?:^|\n)host_import_abi=(raw|tagged)(?:\n|$)/);
      if (match) {
        process.stdout.write(match[1]);
      }
      process.exit(0);
    }
  }
  pos = sectionEnd;
}
NODE
}

use_cli_invoke() {
  local entry="$1"
  if [ "$CLI_INVOKE" = "1" ]; then
    return 0
  fi
  if [ "$CLI_INVOKE" = "0" ]; then
    return 1
  fi
  local entry_rel
  entry_rel="$(rel_path "$entry")"
  [ "$entry_rel" = "$SEED_ENTRY" ] && \
    [ "$SEED_ENTRY_NAME" = "cli_main" ] && \
    [ -f "$RUNNER_SCRIPT" ]
}

run_cli_compile() {
  local label="$1"
  local compiler="$2"
  local entry="$3"
  local out="$4"
  local compile_entry_name="${5:-$SEED_ENTRY_NAME}"
  local node_flags="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --stack-size=$NODE_STACK_SIZE}"
  local import_abi="${VIBE_IMPORT_ABI:-}"
  if [ -z "$import_abi" ]; then
    import_abi="$(detect_wasm_host_import_abi "$compiler")"
  fi
  if [ -z "$import_abi" ]; then
    case "$label" in
      stage0\(*|validate\ stage0\ *) import_abi="tagged" ;;
      *) import_abi="raw" ;;
    esac
  fi
  local skip_run_init="${VIBE_SKIP_RUN_INIT:-}"
  if [ -z "$skip_run_init" ]; then
    if [ "$import_abi" = "raw" ]; then
      skip_run_init="$SKIP_RUN_INIT"
    else
      skip_run_init=0
    fi
  fi
  mkdir -p "$(dirname "$out")"
  echo "[selfhost-gen] $label (invoke cli_main)"
  (
    cd "$PROJECT_ROOT"
    VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
      VIBE_IMPORT_ABI="$import_abi" \
      VIBE_WASM_PRE_GROW_PAGES="${VIBE_WASM_PRE_GROW_PAGES:-$WASM_PRE_GROW_PAGES}" \
      VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE="${VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE:-$DISABLE_PERSISTENT_ARTIFACT_CACHE}" \
      VIBE_SKIP_RUN_INIT="$skip_run_init" \
      VIBE_NODE_WASM_FLAGS="$node_flags" \
      bash "$RUNNER_SCRIPT" \
        --invoke cli_main \
        "$(rel_path "$compiler")" \
        "$(rel_path "$entry")" \
        "$(rel_path "$out")" \
        "$compile_entry_name"
  )
  [ -s "$out" ] || die "$label did not produce output: $out"
}

use_selfbuild_invoke() {
  local entry="$1"
  if [ "$SELFBUILD_INVOKE" = "1" ]; then
    return 0
  fi
  if [ "$SELFBUILD_INVOKE" = "0" ]; then
    return 1
  fi
  [ "$(rel_path "$entry")" = "$SEED_ENTRY" ] && [ -f "$RUNNER_SCRIPT" ]
}

use_flat_cli_source() {
  local entry="$1"
  case "$FLAT_CLI_SOURCE" in
    1) return 0 ;;
    0) return 1 ;;
    auto)
      local entry_rel
      entry_rel="$(rel_path "$entry")"
      [ "$SEED_ENTRY_NAME" = "cli_main" ] && \
        [ "$SEED_ENTRY" = "lib/@vibe/compiler/cli_support.vibe" ] && \
        [ "$entry_rel" = "$SEED_ENTRY" ]
      ;;
    *) die "VIBE_GENERATION_FLAT_CLI_SOURCE must be auto, 1, or 0" ;;
  esac
}

prepare_flat_cli_source() {
  local out_dir="$1"
  local out="$out_dir/cli_adapter_module_source.vibe"
  # Decoupling hook (#533 follow-up / selfhost release-asset bootstrap):
  # the flat module source is a deterministic function of the committed
  # compiler source. It is regenerated via scripts/generate_bundle.sh
  # (seed-compiler based). In a constrained environment the prebuilt flat
  # source can instead be PULLED from a release asset (see
  # scripts/fetch_compiler.sh) and supplied here, skipping regeneration.
  #
  #   VIBE_PREBUILT_MODULE_SOURCE         path to prebuilt source
  #   VIBE_PREBUILT_MODULE_SOURCE_SHA256  optional integrity check
  #
  # The caller is responsible for matching the prebuilt source to the
  # configured seed's source commit; a mismatch is a stale-artifact error,
  # surfaced as a stage1/stage2 parity failure downstream.
  local prebuilt="${VIBE_PREBUILT_MODULE_SOURCE:-}"
  if [ -n "$prebuilt" ]; then
    [ -s "$prebuilt" ] || die "prebuilt module source not found or empty: $prebuilt"
    local want_sha="${VIBE_PREBUILT_MODULE_SOURCE_SHA256:-}"
    if [ -n "$want_sha" ]; then
      local got_sha
      got_sha="$(sha256_file "$prebuilt")"
      [ "$got_sha" = "$want_sha" ] || \
        die "prebuilt module source sha256 mismatch: got=$got_sha want=$want_sha"
    fi
    mkdir -p "$out_dir"
    cp "$prebuilt" "$out"
    echo "[selfhost-gen] use prebuilt flat selfhost compiler source: $prebuilt" >&2
    printf '%s\n' "$out"
    return 0
  fi
  local generator="$PROJECT_ROOT/scripts/generate_bundle.sh"
  [ -f "$generator" ] || die "selfhost bundle generator not found: $generator"
  local bundle_tmp="$out_dir/.selfhost_bundle"
  local bundle_log="$out_dir/selfhost_bundle_generation.log"
  mkdir -p "$bundle_tmp"
  echo "[selfhost-gen] prepare flat selfhost compiler source" >&2
  # Both step-0 traces put roughly half the wall clock outside every stage
  # compile (docs/tracing-design.md §5.6 48%, §5.7 65%). This generator call is
  # the main suspect, so it gets its own span instead of being guessed at.
  trace_begin "prepare flat source"
  local prep_tok="$TRACE_TOKEN"
  if ! VIBE_BUNDLE_OUT="$bundle_tmp/compiler_sources_bundle.vibe" \
    VIBE_ADAPTER_BUNDLE_OUT="$bundle_tmp/cli_adapter_bundle.vibe" \
    VIBE_RUNTIME_ENTRY_BUNDLE_OUT="$bundle_tmp/selfbuild_runtime_entry_bundle.vibe" \
    VIBE_ADAPTER_MODULE_SOURCE_OUT="$out" \
    bash "$generator" >"$bundle_log" 2>&1; then
    trace_end "$prep_tok" 1
    cat "$bundle_log" >&2
    die "flat selfhost compiler source generation failed"
  fi
  trace_end "$prep_tok" 0
  [ -s "$out" ] || die "flat selfhost compiler source was not produced: $out"
  printf '%s\n' "$out"
}

select_generation_entry() {
  local out_dir="$1"
  local entry="$2"
  GENERATION_ENTRY="$entry"
  if use_cli_invoke "$entry"; then
    GENERATION_INVOKE_MODE="cli"
    if use_flat_cli_source "$entry"; then
      GENERATION_ENTRY="$(prepare_flat_cli_source "$out_dir")"
    else
      GENERATION_ENTRY="$entry"
    fi
  elif use_selfbuild_invoke "$entry"; then
    GENERATION_INVOKE_MODE="selfbuild"
  else
    die "no viable compile invocation for entry $(rel_path "$entry"): neither cli_invoke nor selfbuild_invoke applies (expected seed.entry_name=cli_main matching seed.entry, or an explicit VIBE_GENERATION_CLI_INVOKE=1 override)"
  fi
}

run_selfbuild_compile() {
  local label="$1"
  local compiler="$2"
  local out="$3"
  local node_flags="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --stack-size=$NODE_STACK_SIZE}"
  local import_abi="${VIBE_IMPORT_ABI:-raw}"
  mkdir -p "$(dirname "$out")" "$(dirname "$SELFBUILD_OUT")"
  echo "[selfhost-gen] $label (invoke selfbuild_compile_stage2)"
  rm -f "$SELFBUILD_OUT"
  (
    cd "$PROJECT_ROOT"
    VIBE_IMPORT_ABI="$import_abi" \
      VIBE_WASM_PRE_GROW_PAGES="${VIBE_WASM_PRE_GROW_PAGES:-$WASM_PRE_GROW_PAGES}" \
      VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE="${VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE:-$DISABLE_PERSISTENT_ARTIFACT_CACHE}" \
      VIBE_NODE_WASM_FLAGS="$node_flags" \
      bash "$RUNNER_SCRIPT" --invoke selfbuild_compile_stage2 "$compiler"
  )
  [ -s "$SELFBUILD_OUT" ] || die "$label did not produce recursive output: $SELFBUILD_OUT"
  cp "$SELFBUILD_OUT" "$out"
  [ -s "$out" ] || die "$label did not produce output: $out"
}

# Each stage hop is one span (docs/tracing-design.md step 0). This is the
# smallest place that makes the bootstrap chain legible as a tree:
# seed -> stage1 -> stage2 -> stage3 is four full compiles in four processes,
# and until now the only way to see where the time went was to read timestamps
# out of the log by eye.
#
# trace_begin/trace_end rather than the trace_span.sh wrapper because the work
# here is a shell FUNCTION, which cannot be exec'd. No-op unless
# VIBE_TRACE_OUT is set.
run_generation_compile() {
  local label="$1"
  local compiler="$2"
  local entry="$3"
  local out="$4"
  local compile_entry_name="${5:-}"
  trace_begin "$label"
  local tok="$TRACE_TOKEN"
  local rc=0
  case "$GENERATION_INVOKE_MODE" in
    cli) run_cli_compile "$label" "$compiler" "$entry" "$out" "$compile_entry_name" || rc=$? ;;
    selfbuild) run_selfbuild_compile "$label" "$compiler" "$out" || rc=$? ;;
    *) trace_end "$tok" 2; die "unknown generation invoke mode: $GENERATION_INVOKE_MODE" ;;
  esac
  trace_end "$tok" "$rc"
  return "$rc"
}

validate_wasm_if_available() {
  local label="$1"
  local wasm="$2"
  if [ "$VALIDATE_WASM" != "1" ]; then
    return
  fi
  if command -v wasm-tools >/dev/null 2>&1; then
    echo "[selfhost-gen] validate $label"
    wasm-tools validate --features all "$wasm"
  fi
}

run_start_if_enabled() {
  local label="$1"
  local wasm="$2"
  local out="$3"
  if [ "$VALIDATE_RUN" != "1" ]; then
    return
  fi
  if [ ! -x "$PROJECT_ROOT/scripts/wasmtime_run.sh" ]; then
    echo "[selfhost-gen] warning: wasmtime runner missing, skipping run validation" >&2
    return
  fi
  echo "[selfhost-gen] run $label"
  env VIBE_WASMTIME_WASM_FLAGS="${VIBE_GENERATION_WASMTIME_FLAGS:-unknown-imports-default=y exceptions=y}" \
    "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke _start "$wasm" >"$out"
  local value
  value="$(grep -v '^warning' "$out" | tail -n 1)"
  if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
    die "$label did not return numeric value: $value"
  fi
  if [ "$value" != "0" ]; then
    die "$label returned $value, expected 0"
  fi
}

validate_compiler_artifact_if_enabled() {
  local label="$1"
  local compiler="$2"
  local out_dir="$3"
  if [ "$VALIDATE_RUN" != "1" ]; then
    return
  fi
  local safe_label sample_src sample_wasm sample_out magic value
  safe_label="$(sanitize_name "$label")"
  sample_src="$out_dir/${safe_label}_sample.vibe"
  sample_wasm="$out_dir/${safe_label}_sample.wasm"
  sample_out="$out_dir/${safe_label}_sample.out"
  cat >"$sample_src" <<'VIBE'
export let answer = () -> Int { 40 + 2 }
VIBE
  run_cli_compile "validate $label compiler -> sample" "$compiler" "$sample_src" "$sample_wasm" answer
  magic="$(od -An -t x1 -N 4 "$sample_wasm" | tr -d ' \n')"
  if [ "$magic" != "0061736d" ]; then
    die "$label sample artifact is not wasm (magic=$magic)"
  fi
  env VIBE_WASMTIME_WASM_FLAGS="${VIBE_GENERATION_WASMTIME_FLAGS:-exceptions=y}" \
    "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke _start "$sample_wasm" >"$sample_out"
  value="$(grep -v '^warning' "$sample_out" | tail -n 1)"
  if [ "$value" != "42" ]; then
    die "$label sample returned $value, expected 42"
  fi
}

write_generation_manifest() {
  local manifest="$1"
  local out_dir="$2"
  local entry="$3"
  local stage0="$4"
  local stage1="$5"
  local stage2="$6"
  local stage3="${7:-}"
  local generation_json="$out_dir/generation.json"
  node - "$PROJECT_ROOT" "$manifest" "$generation_json" "$entry" "$stage0" "$stage1" "$stage2" "$stage3" "$(git_commit)" "$(git_dirty)" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const [
  root,
  seedManifestPath,
  generationManifestPath,
  entry,
  stage0Path,
  stage1Path,
  stage2Path,
  stage3Path,
  sourceCommit,
  dirty,
] = process.argv.slice(2);

const seedManifest = JSON.parse(fs.readFileSync(seedManifestPath, "utf8"));
const rel = (p) => path.isAbsolute(p) ? path.relative(root, p) : p;
const sha256 = (p) => crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex");
const artifact = (p, builtBy) => ({
  path: rel(p),
  sha256: sha256(p),
  size: fs.statSync(p).size,
  built_by: builtBy,
});

const stages = {
  stage0: artifact(stage0Path, "fixed-seed"),
  stage1: artifact(stage1Path, "stage0"),
  stage2: artifact(stage2Path, "stage1"),
};

let stage3EqualStage2 = null;
if (stage3Path && fs.existsSync(stage3Path)) {
  stages.stage3 = artifact(stage3Path, "stage2");
  stage3EqualStage2 = stages.stage2.sha256 === stages.stage3.sha256;
}

const out = {
  schema: 1,
  policy: "rust-style-stage0-stage1-stage2",
  generated_at: new Date().toISOString(),
  seed: seedManifest.seed,
  source: {
    commit: sourceCommit,
    dirty: dirty === "true",
    entry: rel(entry),
  },
  stages,
  result: {
    stage2_distribution_candidate: true,
    stage3_equal_stage2: stage3EqualStage2,
  },
};

fs.mkdirSync(path.dirname(generationManifestPath), { recursive: true });
fs.writeFileSync(generationManifestPath, `${JSON.stringify(out, null, 2)}\n`);
NODE
  echo "[selfhost-gen] wrote $(rel_path "$generation_json")"
}

command_seed_info() {
  local manifest="$DEFAULT_MANIFEST"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest) manifest="$(abs_path "$2")"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown seed-info arg: $1" ;;
    esac
  done
  load_seed "$manifest"
  echo "seed.name=$SEED_NAME"
  echo "seed.tag=$SEED_TAG"
  echo "seed.source_commit=$SEED_SOURCE_COMMIT"
  echo "seed.entry=$SEED_ENTRY"
  echo "seed.entry_name=$SEED_ENTRY_NAME"
  echo "seed.artifact.path=$(rel_path "$SEED_ARTIFACT_PATH")"
  echo "seed.artifact.sha256=${SEED_ARTIFACT_SHA:-<uninitialized>}"
  if [ -f "$SEED_ARTIFACT_PATH" ]; then
    echo "seed.artifact.actual_sha256=$(sha256_file "$SEED_ARTIFACT_PATH")"
  else
    echo "seed.artifact.status=missing"
  fi
}

default_generation_out_dir() {
  printf '%s\n' "$DEFAULT_OUT_ROOT/$(sanitize_name "$SEED_NAME")_$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
}

command_status() {
  local manifest="$DEFAULT_MANIFEST"
  local out_dir=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest) manifest="$(abs_path "$2")"; shift 2 ;;
      --out-dir) out_dir="$(abs_path "$2")"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown status arg: $1" ;;
    esac
  done
  load_seed "$manifest"
  echo "# seed"
  echo "seed.name=$SEED_NAME"
  echo "seed.tag=$SEED_TAG"
  echo "seed.source_commit=$SEED_SOURCE_COMMIT"
  echo "seed.entry=$SEED_ENTRY ($SEED_ENTRY_NAME)"
  echo "seed.artifact.path=$(rel_path "$SEED_ARTIFACT_PATH")"
  if [ ! -f "$SEED_ARTIFACT_PATH" ]; then
    echo "seed.artifact.pin=missing"
  else
    local actual
    actual="$(sha256_file "$SEED_ARTIFACT_PATH")"
    if [ -z "$SEED_ARTIFACT_SHA" ]; then
      echo "seed.artifact.pin=unpinned (actual=$actual)"
    elif [ "$actual" = "$SEED_ARTIFACT_SHA" ]; then
      echo "seed.artifact.pin=ok ($actual)"
    else
      echo "seed.artifact.pin=MISMATCH expected=$SEED_ARTIFACT_SHA actual=$actual"
    fi
  fi
  echo ""
  echo "# source"
  echo "head_commit=$(git_commit)"
  echo "dirty=$(git_dirty)"
  echo ""
  echo "# latest generation"
  if [ -z "$out_dir" ]; then
    out_dir="$(default_generation_out_dir)"
  fi
  local gen_json="$out_dir/generation.json"
  if [ ! -f "$gen_json" ]; then
    echo "generation.status=not-built"
    echo "generation.expected_out_dir=$(rel_path "$out_dir")"
    echo "hint: run 'bash scripts/generations.sh build --stage3'"
    return 0
  fi
  echo "generation.manifest=$(rel_path "$gen_json")"
  echo "generated_at=$(manifest_value "$gen_json" generated_at || echo unknown)"
  echo "source.commit=$(manifest_value "$gen_json" source.commit || echo unknown)"
  echo "source.dirty=$(manifest_value "$gen_json" source.dirty || echo unknown)"
  local stage
  for stage in stage0 stage1 stage2 stage3; do
    local sha
    sha="$(manifest_value "$gen_json" "stages.$stage.sha256" 2>/dev/null || true)"
    if [ -n "$sha" ]; then
      echo "$stage.sha256=${sha:0:16}"
    fi
  done
  echo "stage2_distribution_candidate=$(manifest_value "$gen_json" result.stage2_distribution_candidate || echo unknown)"
  echo "stage3_equal_stage2=$(manifest_value "$gen_json" result.stage3_equal_stage2 || echo n/a)"
}

command_build() {
  local manifest="$DEFAULT_MANIFEST"
  local out_dir=""
  local entry=""
  local entry_name=""
  local build_stage3=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest) manifest="$(abs_path "$2")"; shift 2 ;;
      --out-dir) out_dir="$(abs_path "$2")"; shift 2 ;;
      --entry) entry="$(abs_path "$2")"; shift 2 ;;
      # Override the compiled artifact's exported entry_name (default:
      # seed.entry_name, "cli_main") for every stage compile in THIS
      # invocation only -- the persisted seed manifest is untouched, and
      # `--invoke cli_main` (the self-hosting bootstrap's own build-tool
      # ABI) still targets each stage's compiler by that fixed name
      # regardless, since strip_executable_wasm (cli_support.vibe)
      # unconditionally preserves a "cli_main" export no matter what
      # entry_name a build asked for (#1137).
      --entry-name) entry_name="$2"; shift 2 ;;
      --stage3) build_stage3=1; shift ;;
      --skip-run-validation) VALIDATE_RUN=0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown build arg: $1" ;;
    esac
  done
  load_seed "$manifest"
  verify_seed_artifact
  if [ -z "$entry" ]; then
    entry="$(abs_path "$SEED_ENTRY")"
  fi
  if [ -z "$out_dir" ]; then
    out_dir="$DEFAULT_OUT_ROOT/$(sanitize_name "$SEED_NAME")_$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
  fi
  mkdir -p "$out_dir"
  local requested_entry="$entry"
  if [ "$(rel_path "$requested_entry")" = "lib/@vibe/cli/entry.vibe" ] && \
    [ "$SEED_ENTRY" = "lib/@vibe/compiler/cli_support.vibe" ]; then
    die "split CLI generation requires a bootstrap bump first; current fixed seed uses legacy cli_support.vibe"
  fi
  select_generation_entry "$out_dir" "$requested_entry"
  entry="$GENERATION_ENTRY"
  # Codex review on #1225: run_selfbuild_compile has no entry_name parameter
  # (selfbuild_entry is a single fixed export) and would otherwise silently
  # ignore --entry-name, succeeding with an artifact that doesn't use the
  # requested entry. Reject rather than mis-build.
  if [ -n "$entry_name" ] && [ "$GENERATION_INVOKE_MODE" != "cli" ]; then
    die "--entry-name is only supported in cli invoke mode (got: $GENERATION_INVOKE_MODE)"
  fi
  local stage0="$out_dir/stage0_seed.wasm"
  local stage1="$out_dir/stage1.wasm"
  local stage2="$out_dir/stage2.wasm"
  local stage3="$out_dir/stage3.wasm"
  cp "$SEED_ARTIFACT_PATH" "$stage0"
  validate_wasm_if_available stage0 "$stage0"
  run_generation_compile "stage0(seed) -> stage1" "$stage0" "$entry" "$stage1" "$entry_name"
  validate_wasm_if_available stage1 "$stage1"
  run_generation_compile "stage1 -> stage2" "$stage1" "$entry" "$stage2" "$entry_name"
  validate_wasm_if_available stage2 "$stage2"
  if [ "$GENERATION_INVOKE_MODE" = "cli" ]; then
    validate_compiler_artifact_if_enabled stage1 "$stage1" "$out_dir"
    validate_compiler_artifact_if_enabled stage2 "$stage2" "$out_dir"
  else
    run_start_if_enabled stage1 "$stage1" "$out_dir/stage1_run.out"
    run_start_if_enabled stage2 "$stage2" "$out_dir/stage2_run.out"
  fi
  if [ "$build_stage3" -eq 1 ]; then
    run_generation_compile "stage2 -> stage3" "$stage2" "$entry" "$stage3" "$entry_name"
    validate_wasm_if_available stage3 "$stage3"
    if [ "$GENERATION_INVOKE_MODE" = "cli" ]; then
      validate_compiler_artifact_if_enabled stage3 "$stage3" "$out_dir"
    else
      run_start_if_enabled stage3 "$stage3" "$out_dir/stage3_run.out"
    fi
    write_generation_manifest "$manifest" "$out_dir" "$entry" "$stage0" "$stage1" "$stage2" "$stage3"
  else
    write_generation_manifest "$manifest" "$out_dir" "$entry" "$stage0" "$stage1" "$stage2"
  fi
  echo "[selfhost-gen] stage2 candidate: $(rel_path "$stage2")"
}

update_seed_manifest() {
  local manifest="$1"
  local artifact="$2"
  local name="$3"
  local tag="$4"
  local source_commit="$5"
  local entry="$6"
  load_seed "$manifest"
  local target
  target="$SEED_ARTIFACT_PATH"
  mkdir -p "$(dirname "$target")"
  cp "$artifact" "$target"
  local sha
  sha="$(sha256_file "$target")"
  node - "$manifest" "$name" "$tag" "$source_commit" "$entry" "$(rel_path "$target")" "$sha" <<'NODE'
const fs = require("node:fs");
const [manifestPath, name, tag, sourceCommit, entry, artifactPath, sha] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
data.schema = data.schema ?? 1;
data.policy = data.policy ?? "rust-style-stage0-stage1-stage2";
data.seed = data.seed ?? {};
if (name) data.seed.name = name;
if (tag) data.seed.tag = tag;
if (sourceCommit) data.seed.source_commit = sourceCommit;
if (entry) data.seed.entry = entry;
data.seed.artifact = data.seed.artifact ?? {};
data.seed.artifact.path = artifactPath;
data.seed.artifact.sha256 = sha;
data.seed.runtime = data.seed.runtime ?? {};
data.seed.runtime.runner = data.seed.runtime.runner ?? "node";
data.seed.runtime.compile_flag = data.seed.runtime.compile_flag ?? "--wasm-mvp";
data.seed.runtime.wasmtime_flags = data.seed.runtime.wasmtime_flags ?? "unknown-imports-default=y exceptions=y";
fs.writeFileSync(manifestPath, `${JSON.stringify(data, null, 2)}\n`);
NODE
  echo "[selfhost-gen] adopted seed artifact: $(rel_path "$target")"
  echo "[selfhost-gen] sha256=$sha"
}

command_adopt() {
  local manifest="$DEFAULT_MANIFEST"
  local artifact=""
  local name=""
  local tag=""
  local source_commit=""
  local entry=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest) manifest="$(abs_path "$2")"; shift 2 ;;
      --artifact) artifact="$(abs_path "$2")"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --tag) tag="$2"; shift 2 ;;
      --source-commit) source_commit="$2"; shift 2 ;;
      --entry) entry="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown adopt arg: $1" ;;
    esac
  done
  [ -n "$artifact" ] || die "adopt requires --artifact"
  [ -f "$artifact" ] || die "artifact not found: $artifact"
  update_seed_manifest "$manifest" "$artifact" "$name" "$tag" "$source_commit" "$entry"
}

main() {
  local command="${1:-}"
  case "$command" in
    seed-info) shift; command_seed_info "$@" ;;
    status) shift; command_status "$@" ;;
    build) shift; command_build "$@" ;;
    adopt) shift; command_adopt "$@" ;;
    -h|--help|"") usage; exit 0 ;;
    *) usage; die "unknown command: $command" ;;
  esac
}

main "$@"
