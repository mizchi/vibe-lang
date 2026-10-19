"""Source gates must follow relocated implementations without scanning decoys."""
from pathlib import Path
import tempfile
import unittest

from source_files import read_source_group


class ImplementationGroupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.group = self.root / "wasi"
        self.group.mkdir()
        self.entry = self.put("linked_compile.vibe",
            "// Compatibility exports; implementations are grouped by their dependencies.\n"
            "export ./linked_compile_api.vibe { compile }\n")
        self.put("linked_compile_api.vibe", "import ./linked_module_preparation.vibe { finish }\n")
        self.put("linked_module_preparation.vibe",
            "import ./linked_compile_module_sections.vibe { emit }\n"
            "import ./linked_compile.vibe { compile }\n")
        self.section = self.put("linked_compile_module_sections.vibe",
            'fn emit() { emit_name(import_content, "fs_publish_immutable_text") }\n')

    def put(self, name, text):
        path = self.group / name
        path.write_text(text)
        return path

    def test_relocated_section_is_reachable_once_through_cycle(self):
        self.put("linked_compile_unreachable.vibe", "UNREACHABLE_DECOY\n")
        text = read_source_group(self.entry)
        self.assertEqual(text.count('emit_name(import_content, "fs_publish_immutable_text")'), 1)
        self.assertNotIn("UNREACHABLE_DECOY", text)

    def test_mutated_reachable_section_cannot_be_replaced_by_decoy(self):
        self.put("linked_compile_decoy.vibe", self.section.read_text())
        self.section.write_text("fn emit() { () }\n")
        self.assertNotIn('emit_name(import_content, "fs_publish_immutable_text")',
                         read_source_group(self.entry))

    def test_explicit_import_outside_group_is_not_scanned(self):
        (self.root / "outside.vibe").write_text("OUTSIDE_DECOY\n")
        with self.section.open("a") as stream:
            stream.write("import ../outside.vibe { outside }\n")
        self.assertNotIn("OUTSIDE_DECOY", read_source_group(self.entry))

    def test_missing_explicit_local_module_fails_closed(self):
        self.section.unlink()
        with self.assertRaises(FileNotFoundError):
            read_source_group(self.entry)

    def test_default_group_keeps_unowned_dependencies_outside_its_boundary(self):
        entry = self.put("user_dispatch.vibe",
            "// Compatibility exports; implementations are grouped by their dependencies.\n"
            "export ./user_dispatch_impl.vibe { dispatch }\n")
        self.put("user_dispatch_impl.vibe", "import ./cli_support.vibe { support }\nOWNED_DISPATCH\n")
        for present in [False, True]:
            with self.subTest(unowned_file_present=present):
                if present:
                    self.put("cli_support.vibe", "UNOWNED_DISPATCH_DEPENDENCY\n")
                text = read_source_group(entry)
                self.assertIn("OWNED_DISPATCH", text)
                self.assertNotIn("UNOWNED_DISPATCH_DEPENDENCY", text)

    def test_ordinary_entry_is_not_implicitly_flattened(self):
        text = "import ./linked_module_preparation.vibe { finish }\nfn ordinary() { () }\n"
        ordinary = self.put("ordinary.vibe", text)
        self.assertEqual(read_source_group(ordinary).strip(), text.strip())


if __name__ == "__main__":
    unittest.main()
