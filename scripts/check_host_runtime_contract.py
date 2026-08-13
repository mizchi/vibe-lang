#!/usr/bin/env python3
"""Fail-closed drift check for the documented `vibe.*` core import contract."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/wasm/host-runtime-contract.json"
EMITTER = ROOT / "lib/@vibe/compiler/codegen/wasi/linked_compile.vibe"
RUST = ROOT / "runtime/viberun/src/main.rs"
NODE = ROOT / "scripts/wasm_vibe_host_runner.js"


def die(message: str) -> None:
    print(f"host-runtime-contract: {message}", file=sys.stderr)
    raise SystemExit(1)


def emitter_imports(text: str) -> dict[str, str]:
    # Dynamic named component imports are checked separately below.
    pattern = re.compile(
        r'emit_name\(import_content, "vibe"\)\s*\n\s*'
        r'emit_name\(import_content, "([^"]+)"\)\s*\n\s*'
        r'bytebuf_push\(import_content, 0\)\s*\n\s*'
        r'leb128_encode_u32\(import_content, ([^)]+)\)'
    )
    found: dict[str, str] = {}
    for name, type_id in pattern.findall(text):
        if name in found:
            die(f"duplicate static emitter import: {name}")
        found[name] = type_id.strip()
    if not found:
        die("could not parse any compiler-emitted vibe imports")
    return found


def emitter_dynamic_imports(text: str) -> dict[str, tuple[str, str]]:
    """Extract generated `<prefix><Array::get(names, i)>` import descriptors."""
    pattern = re.compile(
        r'emit_name\(import_content, "vibe"\)\s*\n\s*'
        r'emit_name\(import_content, String::concat\("([^"]+)",\s*'
        r'Array::get\(([A-Za-z_][A-Za-z0-9_]*),\s*[A-Za-z_][A-Za-z0-9_]*\)\)\)\s*\n\s*'
        r'bytebuf_push\(import_content, 0\)\s*\n\s*'
        r'leb128_encode_u32\(import_content, ([^)]+)\)'
    )
    found: dict[str, tuple[str, str]] = {}
    for prefix, names_array, type_id in pattern.findall(text):
        if prefix in found:
            die(f"duplicate dynamic emitter import prefix: {prefix}")
        found[prefix] = (names_array, type_id.strip())
    return found


def validate_emitter_contract(manifest: dict, text: str) -> tuple[dict[str, str], dict[str, tuple[str, str]]]:
    emitted = emitter_imports(text)
    expected_types = manifest.get("importTypes")
    if not isinstance(expected_types, dict):
        die("manifest importTypes must map each static import to its type id")
    if emitted != expected_types:
        missing = sorted(set(expected_types) - set(emitted))
        extra = sorted(set(emitted) - set(expected_types))
        changed = sorted(name for name in set(emitted) & set(expected_types) if emitted[name] != expected_types[name])
        die(f"emitter signature drift: missing={missing} extra={extra} changed={changed}")

    patterns = manifest.get("componentAdapterPatterns")
    if not isinstance(patterns, list):
        die("manifest componentAdapterPatterns must be a list")
    expected_dynamic: dict[str, tuple[str, str]] = {}
    for item in patterns:
        if not isinstance(item, dict) or set(item) != {"pattern", "prefix", "namesArray", "type"}:
            die("each componentAdapterPatterns entry must contain pattern, prefix, namesArray, and type")
        if item["pattern"] != item["prefix"] + "<name>":
            die(f"dynamic manifest pattern disagrees with prefix: {item['pattern']}")
        prefix = item["prefix"]
        if prefix in expected_dynamic:
            die(f"duplicate manifest dynamic prefix: {prefix}")
        expected_dynamic[prefix] = (item["namesArray"], item["type"])
    dynamic = emitter_dynamic_imports(text)
    if dynamic != expected_dynamic:
        die(f"dynamic emitter drift: expected={expected_dynamic} actual={dynamic}")
    return emitted, dynamic


def rust_imports(text: str) -> set[str]:
    found = set(re.findall(r'linker\.func_wrap\(\s*"vibe",\s*"([^"]+)"', text))
    if not found:
        die("could not parse any viberun vibe providers")
    return found


def node_imports(text: str) -> set[str]:
    pairs = re.findall(r'^\s*(?:\["([^"]+)"\]|([A-Za-z_][\w-]*))\s*\([^\n]*\)\s*\{', text, re.M)
    found = {quoted or bare for quoted, bare in pairs}
    if not found:
        die("could not parse any node-runner methods")
    return found


def main() -> None:
    try:
        manifest = json.loads(MANIFEST.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        die(f"invalid manifest: {exc}")
    required = {"portableCore", "nodeCoreOnly", "viberunDebugOnly", "componentAdapterOnly"}
    if set(manifest) < required:
        die(f"manifest missing keys: {sorted(required - set(manifest))}")
    bands = {key: set(manifest[key]) for key in required}
    all_names: set[str] = set()
    for key, names in bands.items():
        overlap = all_names & names
        if overlap:
            die(f"imports occur in multiple bands ({key}): {sorted(overlap)}")
        all_names |= names

    emitted, dynamic = validate_emitter_contract(manifest, EMITTER.read_text())
    emitted_names = set(emitted)
    expected_emitted = all_names
    if emitted_names != expected_emitted:
        die(f"emitter bands drift: missing={sorted(expected_emitted-emitted_names)} extra={sorted(emitted_names-expected_emitted)}")

    types = manifest.get("coreTypeSignatures", {})
    unknown_types = sorted({type_id for type_id in emitted.values() if type_id not in types} | {type_id for _, type_id in dynamic.values() if type_id not in types})
    if unknown_types:
        die(f"emitter uses undocumented type indices: {unknown_types}")

    rust = rust_imports(RUST.read_text())
    node = node_imports(NODE.read_text())
    portable = bands["portableCore"]
    if not portable <= rust:
        die(f"viberun lacks portable imports: {sorted(portable-rust)}")
    if not portable <= node:
        die(f"node runner lacks portable imports: {sorted(portable-node)}")
    if bands["nodeCoreOnly"] - node:
        die(f"node runner lacks node-only imports: {sorted(bands['nodeCoreOnly']-node)}")
    if bands["viberunDebugOnly"] - rust:
        die(f"viberun lacks debug imports: {sorted(bands['viberunDebugOnly']-rust)}")
    if bands["componentAdapterOnly"] & (rust | node):
        die("component-adapter-only imports leaked into a standalone provider")

    print(f"host-runtime-contract: ok ({len(emitted)} static imports; {len(dynamic)} dynamic patterns; {len(portable)} portable)")


if __name__ == "__main__":
    main()
