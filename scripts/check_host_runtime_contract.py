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
GC = ROOT / "lib/@vibe/compiler/codegen/gc/backend_body.vibe"

# `use_host` names the builtin a USER can write; `host_defs` registers the
# name codegen lowers it to. Measured: `vibe_fs_read_dir_raw` is `unknown
# name` from user code while `vibe_process_exit_raw` resolves (it needs
# { Process }), which is why only one of the two raw names appears in both.
GC_LOWERED_ALIASES = {"Fs::readdir": "vibe_fs_read_dir_raw"}


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


def gc_lists(text: str) -> tuple[list[str], list[tuple[str, int]], list[str], int, int]:
    """The FOUR parallel lists the wasm-gc backend hand-maintains, plus its import-vec header.

    The backend's own comment says moving one without the others is silently
    wrong, and nothing read them until now: this checker's EMITTER is the
    linear lane's `linked_compile.vibe`.
    """
    chain = re.search(r"let use_host = (.+)", text)
    if not chain:
        die("could not find the gc backend's use_host chain")
    use_host = re.findall(r'stmts_use_builtin\(stmts, fn_names_list, "([^"]+)"\)', chain.group(1))
    if not use_host:
        die("gc use_host chain matched no builtin names")

    hbo_match = re.search(r"let hbo = if use_host \{\s*\n\s*(\d+)", text)
    if not hbo_match:
        die("could not find the gc backend's hbo base offset")
    hbo = int(hbo_match.group(1))

    header = re.search(r"bytebuf_push_vec_header\(imp_content, (\d+)\)", text)
    if not header:
        die("could not find the gc backend's import vector header")

    def block(marker: str) -> str:
        try:
            start = text.index(marker)
        except ValueError:
            die(f"could not find the gc backend's {marker.strip()}")
        rest = text[start:]
        return rest[: rest.index("\n    ]")]

    host_defs = [
        (name, int(index))
        for name, _params, index, _ret in re.findall(
            r'\("([^"]+)",\s*(\d+),\s*(\d+),\s*(\d+)\)', block("let host_defs = [")
        )
    ]
    host_imports = [name for name, _type in re.findall(r'\("([^"]+)",\s*(\d+)\)', block("let host_imports = ["))]
    if not host_defs or not host_imports:
        die("gc host_defs or host_imports matched no entries")
    return use_host, host_defs, host_imports, hbo, int(header.group(1))


def validate_gc_lists(manifest_names: set[str], text: str) -> int:
    use_host, host_defs, host_imports, hbo, header = gc_lists(text)
    def_names = [name for name, _index in host_defs]

    # Compared as SETS: `host_defs` is append-only by its own rule while
    # `use_host` is a boolean OR chain, so the two orders legitimately diverge
    # (a positional check reports ten differences on a correct tree).
    lowered = {GC_LOWERED_ALIASES.get(name, name) for name in use_host}
    if lowered != set(def_names):
        die(
            "gc use_host/host_defs drift: "
            f"missing={sorted(set(def_names) - lowered)} extra={sorted(lowered - set(def_names))}"
        )

    # `host_defs` indices ARE the call indices, so they must be 1..n in order.
    expected = list(range(1, len(host_defs) + 1))
    if [index for _name, index in host_defs] != expected:
        die(f"gc host_defs indices are not 1..{len(host_defs)} in order: {[i for _n, i in host_defs]}")

    if len(host_imports) != len(host_defs):
        die(f"gc host_imports has {len(host_imports)} entries for {len(host_defs)} host_defs")

    # hbo is an OFFSET, not a name: corrupt it and nothing is missing, every
    # generated body index simply shifts. It gets its own assertion for that
    # reason -- a name-set check stays green on exactly this failure.
    if hbo != len(host_defs):
        die(f"gc hbo is {hbo} for {len(host_defs)} host imports")
    if header != hbo + 1:
        die(f"gc import vector header is {header}, expected hbo + 1 = {hbo + 1} (wasi fd_write is the extra entry)")

    unknown = sorted(set(host_imports) - manifest_names)
    if unknown:
        die(f"gc host_imports names absent from the host-runtime contract: {unknown}")
    return len(host_defs)


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

    gc_count = validate_gc_lists(all_names, GC.read_text())

    print(f"host-runtime-contract: ok ({len(emitted)} static imports; {len(dynamic)} dynamic patterns; {len(portable)} portable; {gc_count} gc host imports)")


if __name__ == "__main__":
    main()
