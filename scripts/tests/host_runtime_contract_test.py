#!/usr/bin/env python3
import importlib.util
import json
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "check_host_runtime_contract.py"
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
        manifest = Path(__file__).parents[2] / "docs/wasm/host-runtime-contract.json"
        self.assertEqual(json.loads(manifest.read_text())["schema"], 1)


if __name__ == "__main__":
    unittest.main()
