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

# `host_defs` spells a builtin the vibe way and `host_imports` spells the wasm
# import it binds to. The mapping is mechanical for 16 of the 22 -- `::` to `_`,
# lowercased -- and these six predate that convention. Declared rather than
# derived so a rename FAILS instead of being accepted: a `host_defs` name that
# is neither mechanically derivable nor listed here is rejected.
#
# This is a seventh hand-maintained list, which is what #2759 is about, so it
# earns its place only by being checked from both sides -- it exists to make a
# same-signature REORDER detectable, and nothing else pins that. Codex on
# #2765 (P2): swapping `fs_is_dir` and `fs_is_file`, both ABI type 3, passed
# every other assertion here while making the module call `is_file` for
# `Fs::is_dir` -- import order fixes the wasm function indices that
# `host_defs`'s absolute call indices then point into.
GC_IMPORT_NAME_EXCEPTIONS = {
    "Env::get": "env-get",
    "Env::args_len": "args-len",
    "Env::args_get": "args-get",
    "Profiler::now_us": "profile-now-us",
    "vibe_fs_read_dir_raw": "fs_read_dir",
    "vibe_process_exit_raw": "process_exit",
}


def gc_import_name_for(def_name: str) -> str:
    if def_name in GC_IMPORT_NAME_EXCEPTIONS:
        return GC_IMPORT_NAME_EXCEPTIONS[def_name]
    return def_name.replace("::", "_").lower()


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
        (name, int(index), int(params), int(ret))
        for name, params, index, ret in re.findall(
            r'\("([^"]+)",\s*(\d+),\s*(\d+),\s*(\d+)\)', block("let host_defs = [")
        )
    ]
    host_imports = [
        (name, type_id) for name, type_id in re.findall(r'\("([^"]+)",\s*(\d+)\)', block("let host_imports = ["))
    ]
    if not host_defs or not host_imports:
        die("gc host_defs or host_imports matched no entries")
    return use_host, host_defs, host_imports, hbo, int(header.group(1))


# `(i64, i64) -> ()` and `() -> i64`, and nothing else. Anchored on both ends so
# a partial match cannot pass.
_CORE_SIGNATURE = re.compile(
    r"^\(\s*(?:[a-z][a-z0-9]*(?:\s*,\s*[a-z][a-z0-9]*)*\s*)?\)\s*->\s*(?:\(\s*\)|[a-z][a-z0-9]*)$"
)


def core_signature_shape(signature: str) -> tuple[int, int]:
    """`(i64, i64) -> ()` becomes (2, 0): parameter count and whether it returns.

    Parsed from the manifest's own `coreTypeSignatures` rather than transcribed,
    so the arity check introduces no table of its own -- but parsed STRICTLY.

    The first version split on `->` with `partition` and inferred the rest, so
    every malformed form still produced a shape instead of an error: `()` and
    `""` both became (0, 1), `(i64)` became (1, 1), and neither a missing paren
    (`i64 -> i64`) nor a wrong arrow (`(i64) => i64`) was noticed. A contract
    entry that no longer describes an ABI signature would then silently agree
    with whatever host_defs claimed (Codex on #2768, P2 -- it named the `()`
    case; measured, all five behave the same way).
    """
    if not _CORE_SIGNATURE.match(signature.strip()):
        die(f"host-runtime contract coreTypeSignatures entry is not an ABI signature: {signature!r}")
    lhs, _, rhs = signature.partition("->")
    inner = lhs.strip()[1:-1].strip()
    params = len([part for part in inner.split(",") if part.strip()]) if inner else 0
    return params, 0 if rhs.strip() == "()" else 1


def validate_gc_lists(
    manifest_names: set[str],
    text: str,
    import_types: dict[str, str] | None = None,
    core_type_signatures: dict[str, str] | None = None,
) -> int:
    use_host, host_defs, host_imports, hbo, header = gc_lists(text)
    def_names = [name for name, _index, _params, _ret in host_defs]

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
    if [index for _name, index, _p, _r in host_defs] != expected:
        die(f"gc host_defs indices are not 1..{len(host_defs)} in order: {[i for _n, i, _p, _r in host_defs]}")

    if len(host_imports) != len(host_defs):
        die(f"gc host_imports has {len(host_imports)} entries for {len(host_defs)} host_defs")

    # POSITIONAL, not just equal-length. Import order fixes the wasm function
    # indices that host_defs's absolute call indices address, so reordering two
    # entries of the same ABI type produces a module that validates and calls
    # the wrong host function (Codex on #2765, P2).
    for position, ((def_name, _index, _params, _ret), (import_name, _type_id)) in enumerate(zip(host_defs, host_imports), start=1):
        expected = gc_import_name_for(def_name)
        if expected != import_name:
            die(
                f"gc host_imports[{position}] is {import_name!r}, expected {expected!r} for host_defs entry {def_name!r}"
                " (add a GC_IMPORT_NAME_EXCEPTIONS row if this rename is intended)"
            )

    # hbo is an OFFSET, not a name: corrupt it and nothing is missing, every
    # generated body index simply shifts. It gets its own assertion for that
    # reason -- a name-set check stays green on exactly this failure.
    if hbo != len(host_defs):
        die(f"gc hbo is {hbo} for {len(host_defs)} host imports")
    if header != hbo + 1:
        die(f"gc import vector header is {header}, expected hbo + 1 = {hbo + 1} (wasi fd_write is the extra entry)")

    unknown = sorted({name for name, _type_id in host_imports} - manifest_names)
    if unknown:
        die(f"gc host_imports names absent from the host-runtime contract: {unknown}")

    # The ABI type id decides the wasm signature the generated call is checked
    # against, so dropping it made a name-preserving type edit invisible: all 22
    # already agree with the manifest, which is the existing source of truth and
    # not another list to maintain (Codex on #2765, P2).
    if import_types is not None:
        for import_name, type_id in host_imports:
            declared = import_types.get(import_name)
            # Fail CLOSED on a missing entry. `declared is not None and ...`
            # skipped the check for any import the manifest's importTypes did
            # not carry, and band membership does not imply an importTypes row --
            # they are separate keys. Silence there is "unchecked", not "safe",
            # and the two are indistinguishable from the outside. Found by
            # auditing this extractor after three review rounds each found a
            # real gap in it; a duplicate name in `use_host` was the other
            # candidate and is deliberately NOT asserted, because that list is a
            # boolean OR chain where `A || A` is `A`.
            # ONE assertion, not two. A separate `declared is None` branch reads
            # like a second check but cannot be isolated by any mutation: the
            # comparison below already fails closed on None, so disabling the
            # None branch changes nothing. The sweep caught that -- an assertion
            # no test can distinguish is a branch, not a guarantee.
            if declared != type_id:
                detail = "the contract has no importTypes entry for it" if declared is None else f"the contract says {declared}"
                die(f"gc host_imports {import_name!r} declares ABI type {type_id}, but {detail}")

    # host_defs's `params` and `ret` are not derived from the import's type id --
    # they feed `fn_param_counts` and `fn_returns_list` independently, so either
    # can drift while the paired import still declares the old signature and the
    # generated call is emitted against the wrong shape. Checked against the
    # manifest's own coreTypeSignatures, so this adds no table: measured, all 22
    # already agree (Codex on #2765, P2, third round).
    if core_type_signatures is not None:
        for (def_name, _index, params, ret), (import_name, type_id) in zip(host_defs, host_imports):
            signature = core_type_signatures.get(type_id)
            if signature is None:
                die(f"gc host_imports {import_name!r} uses ABI type {type_id}, which the contract does not describe")
            want_params, want_ret = core_signature_shape(signature)
            if (params, ret) != (want_params, want_ret):
                die(
                    f"gc host_defs {def_name!r} declares {params} param(s)/ret={ret}, but its import"
                    f" {import_name!r} is ABI type {type_id} = {signature!r} ({want_params} param(s)/ret={want_ret})"
                )
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

    gc_count = validate_gc_lists(
        all_names, GC.read_text(), manifest.get("importTypes", {}), manifest.get("coreTypeSignatures", {})
    )

    print(f"host-runtime-contract: ok ({len(emitted)} static imports; {len(dynamic)} dynamic patterns; {len(portable)} portable; {gc_count} gc host imports)")


if __name__ == "__main__":
    main()
