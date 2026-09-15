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
        manifest = ROOT / "docs/generated/host-runtime-contract.json"
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
        manifest = json.loads((ROOT / "docs/generated/host-runtime-contract.json").read_text())
        self.names = set()
        for band in ("portableCore", "nodeCoreOnly", "viberunDebugOnly", "componentAdapterOnly"):
            self.names |= set(manifest[band])
        self.import_types = manifest.get("importTypes", {})
        self.core_sigs = manifest.get("coreTypeSignatures", {})

    def assert_mutation_fails(self, mutated):
        # A mutation that did not apply would make the case pass while proving
        # nothing -- the trap #2248 calls out by name.
        self.assertNotEqual(mutated, self.text, "mutation did not apply")
        with self.assertRaises(SystemExit):
            module.validate_gc_lists(self.names, mutated, self.import_types, self.core_sigs)

    def test_real_backend_satisfies_every_invariant(self):
        # A PIN, deliberately a literal: it moves only when a host import is
        # really added or removed, and then whoever moves it has to look at
        # this file. 22 -> 23 when #2758 appended fs_remove_tree.
        self.assertEqual(
            module.validate_gc_lists(self.names, self.text, self.import_types, self.core_sigs), 23
        )

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
        # The literals are READ, not written: hard-coding them meant appending
        # one host import (#2758) made both substitutions match nothing, and
        # the case then failed on its own "mutation did not apply" guard --
        # which is the guard working, but it is cheaper to not need it here.
        desynced = re.sub(
            r"(let hbo = if use_host \{\s*\n\s*)(\d+)",
            lambda m: m.group(1) + str(int(m.group(2)) - 1),
            self.text,
            count=1,
        )
        desynced = re.sub(
            r"(bytebuf_push_vec_header\(imp_content,\s*)(\d+)",
            lambda m: m.group(1) + str(int(m.group(2)) - 1),
            desynced,
            count=1,
        )
        self.assert_mutation_fails(desynced)

    def test_import_vector_header_off_by_one_fails(self):
        self.assert_mutation_fails(
            re.sub(
                r"(bytebuf_push_vec_header\(imp_content,\s*)(\d+)",
                lambda m: m.group(1) + str(int(m.group(2)) - 1),
                self.text,
                count=1,
            )
        )

    def test_host_import_name_absent_from_the_contract_fails(self):
        self.assert_mutation_fails(self.text.replace('("fs_exists", 3)', '("fs_exists_typo", 3)', 1))

    def test_same_abi_type_import_reorder_fails(self):
        # Codex on #2765 (P2). Import ORDER fixes the wasm function indices that
        # host_defs's absolute call indices address, so swapping two entries of
        # the same ABI type yields a module that validates and calls the wrong
        # host function -- `Fs::is_dir` running `is_file`. Length and name
        # membership both survive that swap, which is why it needs its own case.
        self.assert_mutation_fails(
            self.text.replace(
                '      ("fs_is_dir", 3),\n      ("fs_is_file", 3),',
                '      ("fs_is_file", 3),\n      ("fs_is_dir", 3),',
                1,
            )
        )

    def test_import_abi_type_disagreeing_with_the_manifest_fails(self):
        # Codex on #2765 (P2). The extractor dropped the type id, so a
        # name-preserving type edit was invisible.
        #
        # Mutating the BACKEND's type id no longer isolates this assertion: the
        # arity check added in the third round catches that too, because no two
        # coreTypeSignatures entries share a (params, ret) shape. Found by the
        # same disable-each-assertion sweep that caught the hbo and count cases.
        #
        # The two assertions guard different PAIRINGS -- this one is backend
        # against the manifest's importTypes, the arity one is the backend's two
        # lists against coreTypeSignatures. So mutate the MANIFEST side: the
        # backend stays at type 3 and keeps its matching shape, and only the
        # contract disagrees.
        drifted = dict(self.import_types)
        drifted["fs_exists"] = "5"
        self.assertNotEqual(drifted, self.import_types, "mutation did not apply")
        with self.assertRaises(SystemExit):
            module.validate_gc_lists(self.names, self.text, drifted, self.core_sigs)

    def test_host_imports_gaining_an_entry_fails(self):
        # The DROP case above is now caught by the positional name check, which
        # made the count assertion pass for the wrong reason -- found by
        # disabling each assertion in turn and seeing which test noticed. An
        # APPEND is the mutation only the count can catch: `zip` truncates, so
        # all 23 pairs still line up. The appended name must be one the manifest
        # ALREADY knows -- an invented name is caught by the membership check
        # instead, which is how the first attempt at this test passed while
        # proving nothing about the count.
        # Anchored on the END of the host_imports list rather than on whichever
        # name is last -- it was `fs_remove_file` until #2758 appended
        # `fs_remove_tree` after it, and the mutation then matched nothing.
        self.assert_mutation_fails(
            re.sub(
                r"(let host_imports = \[.*?)(\n    \])",
                r'\1,\n      ("fs_exists", 3)\2',
                self.text,
                count=1,
                flags=re.S,
            )
        )

    def test_import_absent_from_the_manifest_bands_fails(self):
        # Renaming ONE side trips the positional check, so it never exercised
        # band membership. Rename all three gc lists consistently -- "added a
        # builtin everywhere in the gc backend and forgot the contract".
        #
        # That alone is now caught by the importTypes check instead, so the
        # mutation also GIVES the new name an importTypes row with a matching
        # type. The backend is then fully self-consistent and typed, and the
        # only thing left that can see it is band membership. Found by the
        # disable-each-assertion sweep, which reported this assertion as
        # uncovered once the type check started failing closed.
        mutated = self.text.replace('stmts_use_builtin(stmts, fn_names_list, "Fs::exists")',
                                    'stmts_use_builtin(stmts, fn_names_list, "Fs::invented")', 1)
        mutated = mutated.replace('("Fs::exists", 1, 5, 1)', '("Fs::invented", 1, 5, 1)', 1)
        mutated = mutated.replace('("fs_exists", 3)', '("fs_invented", 3)', 1)
        typed = dict(self.import_types)
        typed["fs_invented"] = "3"
        with self.assertRaises(SystemExit):
            module.validate_gc_lists(self.names, mutated, typed, self.core_sigs)

    def test_import_missing_from_importTypes_fails_closed(self):
        # The type comparison must fail closed on an absent entry: band
        # membership and an importTypes row are separate keys, so one does not
        # imply the other, and silence there is "unchecked" rather than "safe".
        dropped = dict(self.import_types)
        del dropped["fs_exists"]
        self.assertNotEqual(dropped, self.import_types, "mutation did not apply")
        with self.assertRaises(SystemExit):
            module.validate_gc_lists(self.names, self.text, dropped, self.core_sigs)

    def test_host_def_arity_drifting_from_its_import_signature_fails(self):
        # Codex on #2765 (P2, third round). host_defs's `params`/`ret` feed
        # fn_param_counts and fn_returns_list independently of the import's type
        # id, so either can drift while the import still declares the old
        # signature and the call is emitted against the wrong shape. Checked
        # against the manifest's own coreTypeSignatures -- measured, all 23
        # already agree, so no table is introduced.
        self.assert_mutation_fails(self.text.replace('("Fs::exists", 1, 5, 1)', '("Fs::exists", 0, 5, 1)', 1))

    def test_host_def_return_drifting_from_its_import_signature_fails(self):
        self.assert_mutation_fails(self.text.replace('("Fs::exists", 1, 5, 1)', '("Fs::exists", 1, 5, 0)', 1))

    def test_core_signature_shape_parses_the_manifest_forms(self):
        for signature, shape in (
            ("(i64) -> i64", (1, 1)),
            ("() -> ()", (0, 0)),
            ("(i64, i64) -> ()", (2, 0)),
            ("() -> i64", (0, 1)),
            ("(i32, i32) -> ()", (2, 0)),                    # dbg_line_type_idx
            ("(i64, i64, i64, i64) -> i64", (4, 1)),         # http_request_type_idx
            ("(f64) -> f32", (1, 1)),                        # no entry uses these yet
        ):
            with self.subTest(signature=signature):
                self.assertEqual(module.core_signature_shape(signature), shape)

    def test_core_signature_value_types_are_the_four_numeric_ones(self):
        # Pinning the SET, not just the parse: this is the knob that decides
        # whether a typo is a rejection or a certification, so widening it
        # (back to an identifier class, or to reference types the boundary
        # cannot carry) has to be a visible edit rather than a silent one.
        self.assertEqual(module._CORE_VALUE_TYPES, ("i32", "i64", "f32", "f64"))

    def test_core_signature_shape_rejects_anything_that_is_not_a_signature(self):
        # Codex on #2768 (P2). The first parser split on `->` and inferred the
        # rest, so EVERY malformed form still produced a shape rather than an
        # error -- it named `()` becoming (0, 1); measured, all of these did the
        # same, including a missing paren and a wrong arrow. A contract entry
        # that no longer describes an ABI signature would then silently agree
        # with whatever host_defs claimed.
        #
        # Codex on #2770 (P2) found the same hole one level in: the repaired
        # regex still spelled a value type as `[a-z][a-z0-9]*`, so a TYPE typo
        # parsed and handed back an arity. It named `(i65) -> i64` and
        # `(string) -> bool`; measured, any lowercase identifier did it.
        for signature in (
            "()", "(i64)", "i64 -> i64", "", "(i64) => i64", "(i64) -> ",
            "(,) -> i64", "(i64 i64) -> i64",
            "(i65) -> i64", "(string) -> bool", "(zzz) -> qqq",
            "(i64) -> i65", "(I64) -> i64", "(i64, i65) -> ()",
        ):
            with self.subTest(signature=signature):
                with self.assertRaises(SystemExit):
                    module.core_signature_shape(signature)

    def test_every_manifest_signature_parses(self):
        # The strict parser must accept the contract as it actually stands --
        # a rejection battery that also rejected the real entries would fail
        # closed on everything and prove nothing.
        manifest = json.loads((ROOT / "docs/generated/host-runtime-contract.json").read_text())
        for type_id, signature in manifest["coreTypeSignatures"].items():
            with self.subTest(type_id=type_id):
                module.core_signature_shape(signature)

    def test_every_gc_import_name_is_derivable_or_declared(self):
        # The exception table is a seventh hand-maintained list, which is what
        # #2759 is about; it earns its place by being checked from both sides.
        self.assertEqual(module.gc_import_name_for("Fs::read_file"), "fs_read_file")
        self.assertEqual(module.gc_import_name_for("Env::get"), "env-get")
        self.assertEqual(set(module.GC_IMPORT_NAME_EXCEPTIONS), {
            "Env::get", "Env::args_len", "Env::args_get",
            "Profiler::now_us", "vibe_fs_read_dir_raw", "vibe_process_exit_raw",
        })

    def test_lowered_alias_is_not_a_drift(self):
        # `use_host` lists what a USER can write; `host_defs` registers what it
        # lowers to. Measured: `vibe_fs_read_dir_raw` is `unknown name` from
        # user code, while `vibe_process_exit_raw` resolves and needs
        # { Process } -- which is why only one of the two appears in both lists.
        self.assertEqual(module.GC_LOWERED_ALIASES, {"Fs::readdir": "vibe_fs_read_dir_raw"})


if __name__ == "__main__":
    unittest.main()
