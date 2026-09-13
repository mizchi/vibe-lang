#!/usr/bin/env python3
import importlib.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[4]
SCRIPT = ROOT / "scripts/check_host_runtime_contract.py"
spec = importlib.util.spec_from_file_location("host_contract", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(module)


class HostRuntimeContractTest(unittest.TestCase):
    def test_extracts_static_emitter_import_and_type(self):
        source = '''emit_name(import_content, "vibe")
emit_name(import_content, "env-get")
bytebuf_push(import_content, 0)
leb128_encode_u32(import_content, 3)'''
        self.assertEqual(module.emitter_imports(source), {"env-get": "3"})

    def test_empty_or_changed_emitter_shape_fails_closed(self):
        with self.assertRaises(SystemExit):
            module.emitter_imports('emit_name(import_content, "vibe")')

    def test_signature_reassignment_fails_contract(self):
        source = '''emit_name(import_content, "vibe")
emit_name(import_content, "env-get")
bytebuf_push(import_content, 0)
leb128_encode_u32(import_content, 5)'''
        manifest = {
            "importTypes": {"env-get": "3"},
            "componentAdapterPatterns": [],
        }
        with self.assertRaises(SystemExit):
            module.validate_emitter_contract(manifest, source)

    def test_extracts_dynamic_patterns_structurally(self):
        source = '''emit_name(import_content, "vibe")
emit_name(import_content, String::concat("host_future_get$", Array::get(hf_named_names, hf_emit_i)))
bytebuf_push(import_content, 0)
leb128_encode_u32(import_content, 5)'''
        self.assertEqual(
            module.emitter_dynamic_imports(source),
            {"host_future_get$": ("hf_named_names", "5")},
        )

    def test_dynamic_pattern_comment_only_or_removed_fails_contract(self):
        static = '''emit_name(import_content, "vibe")
emit_name(import_content, "env-get")
bytebuf_push(import_content, 0)
leb128_encode_u32(import_content, 3)'''
        manifest = {
            "importTypes": {"env-get": "3"},
            "componentAdapterPatterns": [{
                "pattern": "host_future_get$<name>",
                "prefix": "host_future_get$",
                "namesArray": "hf_named_names",
                "type": "5",
            }],
        }
        for source in (static, static + '\n// host_future_get$ comment only'):
            with self.subTest(source=source):
                with self.assertRaises(SystemExit):
                    module.validate_emitter_contract(manifest, source)

    def test_provider_extractors_do_not_infer_component_adapters(self):
        rust = 'linker.func_wrap("vibe", "env-get", handler)?;'
        node = '      ["env-get"](name) { return name; },\n      fs_exists(path) { return path; }'
        self.assertEqual(module.rust_imports(rust), {"env-get"})
        self.assertEqual(module.node_imports(node), {"env-get", "fs_exists"})

    def test_manifest_is_valid_json(self):
        manifest = ROOT / "docs/wasm/host-runtime-contract.json"
        self.assertEqual(json.loads(manifest.read_text())["schema"], 1)


class GcHostListTest(unittest.TestCase):
    """#2759: the wasm-gc backend hand-maintains FOUR parallel lists plus an
    import-vec header, and nothing read them -- this checker's EMITTER is the
    LINEAR lane. Each case below mutates ONE list in the real backend source
    and asserts the checker fails, because a gate means nothing until it is
    shown it can fail (#2248).
    """

    GC = ROOT / "lib/@vibe/compiler/codegen/gc/backend_body.vibe"

    def setUp(self):
        self.text = self.GC.read_text()
        manifest = json.loads((ROOT / "docs/wasm/host-runtime-contract.json").read_text())
        self.names = set()
        for band in ("portableCore", "nodeCoreOnly", "viberunDebugOnly", "componentAdapterOnly"):
            self.names |= set(manifest[band])

    def assert_mutation_fails(self, mutated):
        # A mutation that did not apply would make the case pass while proving
        # nothing -- the trap #2248 calls out by name.
        self.assertNotEqual(mutated, self.text, "mutation did not apply")
        with self.assertRaises(SystemExit):
            module.validate_gc_lists(self.names, mutated)

    def test_real_backend_satisfies_every_invariant(self):
        self.assertEqual(module.validate_gc_lists(self.names, self.text), 22)

    def test_use_host_losing_a_builtin_fails(self):
        self.assert_mutation_fails(
            self.text.replace(' || stmts_use_builtin(stmts, fn_names_list, "Fs::is_dir")', "", 1)
        )

    def test_host_defs_index_out_of_order_fails(self):
        self.assert_mutation_fails(self.text.replace('("Fs::exists", 1, 5, 1)', '("Fs::exists", 1, 9, 1)', 1))

    def test_host_imports_losing_an_entry_fails(self):
        self.assert_mutation_fails(self.text.replace('      ("fs_exists", 3),\n', "", 1))

    def test_hbo_desynced_from_host_defs_fails(self):
        # The sharpest case, and the one that needed a second look. hbo is an
        # OFFSET: corrupting it leaves every name present and simply shifts
        # every generated body index, so a name-set check stays green.
        #
        # Mutating hbo ALONE does not isolate its assertion -- the header check
        # (`header == hbo + 1`) catches that too, so the case passed against a
        # checker with the hbo assertion deleted. Measured, not assumed: I
        # removed that assertion and this file still reported OK.
        #
        # So mutate hbo AND the header together, consistently. That is also the
        # realistic desync -- someone decrements hbo and "helpfully" adjusts the
        # header to match -- and only `hbo == len(host_defs)` can catch it.
        desynced = re.sub(r"(let hbo = if use_host \{\s*\n\s*)22", r"\g<1>21", self.text, count=1)
        desynced = desynced.replace("bytebuf_push_vec_header(imp_content, 23)", "bytebuf_push_vec_header(imp_content, 22)", 1)
        self.assert_mutation_fails(desynced)

    def test_import_vector_header_off_by_one_fails(self):
        self.assert_mutation_fails(
            self.text.replace("bytebuf_push_vec_header(imp_content, 23)", "bytebuf_push_vec_header(imp_content, 22)", 1)
        )

    def test_host_import_name_absent_from_the_contract_fails(self):
        self.assert_mutation_fails(self.text.replace('("fs_exists", 3)', '("fs_exists_typo", 3)', 1))

    def test_lowered_alias_is_not_a_drift(self):
        # `use_host` lists what a USER can write; `host_defs` registers what it
        # lowers to. Measured: `vibe_fs_read_dir_raw` is `unknown name` from
        # user code, while `vibe_process_exit_raw` resolves and needs
        # { Process } -- which is why only one of the two appears in both lists.
        self.assertEqual(module.GC_LOWERED_ALIASES, {"Fs::readdir": "vibe_fs_read_dir_raw"})


if __name__ == "__main__":
    unittest.main()
