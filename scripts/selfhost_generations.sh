#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
DEFAULT_MANIFEST="$PROJECT_ROOT/bootstrap/selfhost/seed.json"
DEFAULT_OUT_ROOT="$PROJECT_ROOT/_build/selfhost/generations"
RUNNER="${VIBE_SELFHOST_GENERATION_RUNNER:-moonrun}"
COMPILE_FLAG="${VIBE_SELFHOST_GENERATION_COMPILE_FLAG:---wasm-mvp}"
VALIDATE_WASM="${VIBE_SELFHOST_GENERATION_VALIDATE_WASM:-1}"
VALIDATE_RUN="${VIBE_SELFHOST_GENERATION_VALIDATE_RUN:-1}"
ALLOW_UNPINNED_SEED="${VIBE_SELFHOST_GENERATION_ALLOW_UNPINNED_SEED:-0}"
CLI_INVOKE="${VIBE_SELFHOST_GENERATION_CLI_INVOKE:-auto}"
SELFBUILD_INVOKE="${VIBE_SELFHOST_GENERATION_SELFBUILD_INVOKE:-auto}"
FLAT_CLI_SOURCE="${VIBE_SELFHOST_GENERATION_FLAT_CLI_SOURCE:-auto}"
SELFBUILD_OUT="$PROJECT_ROOT/_build/bench/selfhost_wasi_selfbuild/index_stage2.wasm"
NODE_STACK_SIZE="${VIBE_SELFHOST_GENERATION_NODE_STACK_SIZE:-65536}"
GENERATION_INVOKE_MODE="runner"
GENERATION_ENTRY=""

usage() {
  cat >&2 <<'USAGE'
usage:
  scripts/selfhost_generations.sh seed-info [--manifest PATH]
  scripts/selfhost_generations.sh build [--manifest PATH] [--out-dir DIR] [--entry PATH] [--stage3]
  scripts/selfhost_generations.sh adopt --artifact PATH [--manifest PATH] [--name NAME] [--tag TAG] [--source-commit COMMIT]
  scripts/selfhost_generations.sh host-bootstrap-seed [--manifest PATH] [--entry PATH]

The build command implements the Rust-style compiler generation policy:
stage0 fixed seed -> stage1 current source -> stage2 current source.
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
  SEED_ARTIFACT_PATH="$(abs_path "$SEED_ARTIFACT_REL")"
}

verify_seed_artifact() {
  [ -f "$SEED_ARTIFACT_PATH" ] || die "seed artifact not found: $SEED_ARTIFACT_PATH"
  if [ -z "$SEED_ARTIFACT_SHA" ]; then
    if [ "$ALLOW_UNPINNED_SEED" != "1" ]; then
      die "seed artifact sha256 is empty in $MANIFEST_PATH (run adopt/host-bootstrap-seed or set VIBE_SELFHOST_GENERATION_ALLOW_UNPINNED_SEED=1)"
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

run_compile() {
  local label="$1"
  local compiler="$2"
  local entry="$3"
  local out="$4"
  mkdir -p "$(dirname "$out")"
  echo "[selfhost-gen] $label"
  "$RUNNER" "$compiler" "$COMPILE_FLAG" "$entry" -o "$out"
  [ -s "$out" ] || die "$label did not produce output: $out"
}

use_cli_invoke() {
  local entry="$1"
  if [ "$CLI_INVOKE" = "1" ]; then
    return 0
  fi
  if [ "$CLI_INVOKE" = "0" ]; then
    return 1
  fi
  [ "$(rel_path "$entry")" = "$SEED_ENTRY" ] && \
    [ "$SEED_ENTRY_NAME" = "cli_main" ] && \
    [ -f "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" ]
}

run_cli_compile() {
  local label="$1"
  local compiler="$2"
  local entry="$3"
  local out="$4"
  local compile_entry_name="${5:-$SEED_ENTRY_NAME}"
  local node_flags="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --stack-size=$NODE_STACK_SIZE}"
  local import_abi="${VIBE_SELFHOST_IMPORT_ABI:-}"
  if [ -z "$import_abi" ]; then
    case "$label" in
      stage0\(*|validate\ stage0\ *) import_abi="tagged" ;;
      *) import_abi="raw" ;;
    esac
  fi
  mkdir -p "$(dirname "$out")"
  echo "[selfhost-gen] $label (invoke cli_main)"
  (
    cd "$PROJECT_ROOT"
    VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
      VIBE_SELFHOST_IMPORT_ABI="$import_abi" \
      VIBE_NODE_WASM_FLAGS="$node_flags" \
      bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
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
  [ "$(rel_path "$entry")" = "$SEED_ENTRY" ] && [ -f "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" ]
}

use_flat_cli_source() {
  local entry="$1"
  case "$FLAT_CLI_SOURCE" in
    1) return 0 ;;
    0) return 1 ;;
    auto)
      [ "$(rel_path "$entry")" = "$SEED_ENTRY" ] && [ "$SEED_ENTRY_NAME" = "cli_main" ]
      ;;
    *) die "VIBE_SELFHOST_GENERATION_FLAT_CLI_SOURCE must be auto, 1, or 0" ;;
  esac
}

prepare_flat_cli_source() {
  local out_dir="$1"
  local out="$out_dir/selfhost_cli_adapter_module_source.vibe"
  local generator="$PROJECT_ROOT/scripts/generate_selfhost_bundle.sh"
  [ -f "$generator" ] || die "selfhost bundle generator not found: $generator"
  local bundle_tmp="$out_dir/.selfhost_bundle"
  mkdir -p "$bundle_tmp"
  echo "[selfhost-gen] prepare flat selfhost compiler source" >&2
  VIBE_SELFHOST_BUNDLE_OUT="$bundle_tmp/selfhost_sources_bundle.vibe" \
  VIBE_SELFHOST_ADAPTER_BUNDLE_OUT="$bundle_tmp/selfhost_cli_adapter_bundle.vibe" \
  VIBE_SELFHOST_RUNTIME_ENTRY_BUNDLE_OUT="$bundle_tmp/selfbuild_runtime_entry_bundle.vibe" \
  VIBE_SELFHOST_ADAPTER_MODULE_SOURCE_OUT="$out" \
    bash "$generator" >/dev/null
  [ -s "$out" ] || die "flat selfhost compiler source was not produced: $out"
  printf '%s\n' "$out"
}

select_generation_entry() {
  local out_dir="$1"
  local entry="$2"
  GENERATION_INVOKE_MODE="runner"
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
  fi
}

run_selfbuild_compile() {
  local label="$1"
  local compiler="$2"
  local out="$3"
  local node_flags="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref --stack-size=$NODE_STACK_SIZE}"
  local import_abi="${VIBE_SELFHOST_IMPORT_ABI:-raw}"
  mkdir -p "$(dirname "$out")" "$(dirname "$SELFBUILD_OUT")"
  echo "[selfhost-gen] $label (invoke selfbuild_compile_stage2)"
  rm -f "$SELFBUILD_OUT"
  (
    cd "$PROJECT_ROOT"
    VIBE_SELFHOST_IMPORT_ABI="$import_abi" \
      VIBE_NODE_WASM_FLAGS="$node_flags" \
      bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" --invoke selfbuild_compile_stage2 "$compiler"
  )
  [ -s "$SELFBUILD_OUT" ] || die "$label did not produce recursive output: $SELFBUILD_OUT"
  cp "$SELFBUILD_OUT" "$out"
  [ -s "$out" ] || die "$label did not produce output: $out"
}

run_generation_compile() {
  local label="$1"
  local compiler="$2"
  local entry="$3"
  local out="$4"
  case "$GENERATION_INVOKE_MODE" in
    cli) run_cli_compile "$label" "$compiler" "$entry" "$out" ;;
    selfbuild) run_selfbuild_compile "$label" "$compiler" "$out" ;;
    runner) run_compile "$label" "$compiler" "$entry" "$out" ;;
    *) die "unknown generation invoke mode: $GENERATION_INVOKE_MODE" ;;
  esac
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
  env VIBE_WASMTIME_WASM_FLAGS="${VIBE_SELFHOST_GENERATION_WASMTIME_FLAGS:-unknown-imports-default=y exceptions=y}" \
    "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke _start "$wasm" >"$out"
  local value
  value="$(rg -v '^warning' "$out" | tail -n 1)"
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
  env VIBE_WASMTIME_WASM_FLAGS="${VIBE_SELFHOST_GENERATION_WASMTIME_FLAGS:-exceptions=y}" \
    "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke _start "$sample_wasm" >"$sample_out"
  value="$(rg -v '^warning' "$sample_out" | tail -n 1)"
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

command_build() {
  local manifest="$DEFAULT_MANIFEST"
  local out_dir=""
  local entry=""
  local build_stage3=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest) manifest="$(abs_path "$2")"; shift 2 ;;
      --out-dir) out_dir="$(abs_path "$2")"; shift 2 ;;
      --entry) entry="$(abs_path "$2")"; shift 2 ;;
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
  select_generation_entry "$out_dir" "$requested_entry"
  entry="$GENERATION_ENTRY"
  local stage0="$out_dir/stage0_seed.wasm"
  local stage1="$out_dir/stage1.wasm"
  local stage2="$out_dir/stage2.wasm"
  local stage3="$out_dir/stage3.wasm"
  cp "$SEED_ARTIFACT_PATH" "$stage0"
  validate_wasm_if_available stage0 "$stage0"
  run_generation_compile "stage0(seed) -> stage1" "$stage0" "$entry" "$stage1"
  validate_wasm_if_available stage1 "$stage1"
  run_generation_compile "stage1 -> stage2" "$stage1" "$entry" "$stage2"
  validate_wasm_if_available stage2 "$stage2"
  if use_cli_invoke "$entry"; then
    validate_compiler_artifact_if_enabled stage1 "$stage1" "$out_dir"
    validate_compiler_artifact_if_enabled stage2 "$stage2" "$out_dir"
  else
    run_start_if_enabled stage1 "$stage1" "$out_dir/stage1_run.out"
    run_start_if_enabled stage2 "$stage2" "$out_dir/stage2_run.out"
  fi
  if [ "$build_stage3" -eq 1 ]; then
    run_generation_compile "stage2 -> stage3" "$stage2" "$entry" "$stage3"
    validate_wasm_if_available stage3 "$stage3"
    if use_cli_invoke "$entry"; then
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
data.seed.runtime.runner = data.seed.runtime.runner ?? "moonrun";
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

command_host_bootstrap_seed() {
  local manifest="$DEFAULT_MANIFEST"
  local entry=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest) manifest="$(abs_path "$2")"; shift 2 ;;
      --entry) entry="$(abs_path "$2")"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown host-bootstrap-seed arg: $1" ;;
    esac
  done
  load_seed "$manifest"
  if [ -z "$entry" ]; then
    entry="$(abs_path "$SEED_ENTRY")"
  fi
  local host_compiler_override="${VIBE_SELFHOST_GENERATION_HOST_COMPILER_WASM:-}"
  local host_compiler="${host_compiler_override:-$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm}"
  if [ -z "$host_compiler_override" ]; then
    echo "[selfhost-gen] building MoonBit-host WASI compiler"
    moon build --target wasm src/cmd/vibe_compile_wasi
  elif [ ! -f "$host_compiler" ]; then
    echo "[selfhost-gen] building MoonBit-host WASI compiler"
    moon build --target wasm src/cmd/vibe_compile_wasi
  fi
  [ -f "$host_compiler" ] || die "host compiler wasm not found: $host_compiler"
  local tmp_out
  tmp_out="$PROJECT_ROOT/_build/selfhost/seed/.host_bootstrap_seed.tmp.wasm"
  mkdir -p "$(dirname "$tmp_out")"
  run_compile "host bootstrap compiler -> fixed seed" "$host_compiler" "$entry" "$tmp_out"
  update_seed_manifest "$manifest" "$tmp_out" "$SEED_NAME" "$SEED_TAG" "$SEED_SOURCE_COMMIT" "$(rel_path "$entry")"
}

main() {
  local command="${1:-}"
  case "$command" in
    seed-info) shift; command_seed_info "$@" ;;
    build) shift; command_build "$@" ;;
    adopt) shift; command_adopt "$@" ;;
    host-bootstrap-seed) shift; command_host_bootstrap_seed "$@" ;;
    -h|--help|"") usage; exit 0 ;;
    *) usage; die "unknown command: $command" ;;
  esac
}

main "$@"
