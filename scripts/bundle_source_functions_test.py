import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from bundle_source_functions import render_sources


class BundleSourceFunctionsTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="vibe-source-batch-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def record(self, filename, content, binding="source_0"):
        file = self.root / filename
        file.write_text(content, encoding="utf-8")
        return [binding, "lib/example.vibe", str(file)]

    def source(self, output):
        return [json.loads(line[:-1]) for line in output.splitlines()
                if line.startswith('"') and line.endswith(")")]

    def test_raw_source_preserves_comments_imports_unicode_quotes_and_backslashes(self):
        content = '// 日本語\nimport ./other { value }\nlet s = "a\\\\b\\\"c"\n'
        records = self.record("a space\nfile.vibe", content)
        output = "".join(render_sources("raw", records))
        self.assertEqual(self.source(output), [content])
        self.assertTrue(output.startswith('let source_0 = () -> (String, String) {\n  ("lib/example.vibe",\n'))
        self.assertTrue(output.endswith(")\n}\n\n"))

    def test_filtered_source_keeps_code_and_absolute_imports(self):
        content = ('// comment\nimport ./one { value }\nexport ../two {\n'
                   '  other,\n  nested { entry }\n}\n'
                   'import @vibe/core { foo }\nlet s = "// not a comment"\n')
        records = self.record("ordinary.vibe", content)
        output = "".join(render_sources("filtered", records))
        self.assertEqual(self.source(output), ['import @vibe/core { foo }\nlet s = "// not a comment"\n'])

    def test_contract_imports_and_comments_remain_verbatim(self):
        content = '// contract\nimport ./implementation.vibe {}\nexport fn answer() -> Int\n'
        for suffix in (".vpkg", ".vibei"):
            with self.subTest(suffix=suffix):
                records = self.record("index" + suffix, content)
                self.assertEqual(self.source("".join(render_sources("filtered", records))), [content])

    def test_order_empty_source_and_missing_final_newline(self):
        records = self.record("empty.vibe", "", "source_9")
        records += self.record("second.vibe", "let second = 2", "source_2")
        output = "".join(render_sources("raw", records))
        self.assertEqual(self.source(output), ["", "let second = 2"])
        self.assertEqual(re.findall(r"^let (source_\d+)", output, re.M), ["source_9", "source_2"])

    def test_crlf_reads_like_the_existing_text_reader(self):
        records = self.record("crlf.vibe", "")
        Path(records[-1]).write_bytes(b"let one = 1\r\nlet two = 2\r\n")
        self.assertEqual(self.source("".join(render_sources("raw", records))), ["let one = 1\nlet two = 2\n"])

    def test_cli_reads_nul_delimited_paths(self):
        records = self.record("a space\nfile.vibe", "let answer = 42\n")
        command = [sys.executable, str(Path(__file__).with_name("bundle_source_functions.py")), "raw"]
        result = subprocess.run(command, input=os_records(records), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.source(result.stdout.decode()), ["let answer = 42\n"])

    def test_bad_records_and_missing_files_refuse(self):
        with self.assertRaises(ValueError):
            list(render_sources("raw", ["incomplete"]))
        with self.assertRaises(FileNotFoundError):
            list(render_sources("raw", ["source_0", "lib/missing.vibe", str(self.root / "missing")]))

    def test_cli_refuses_malformed_or_missing_sources(self):
        command = [sys.executable, str(Path(__file__).with_name("bundle_source_functions.py")), "raw"]
        inputs = [b"incomplete\0", b"unterminated", os_records([
            "source_0", "lib/missing.vibe", str(self.root / "missing")])]
        for data in inputs:
            with self.subTest(data=data):
                result = subprocess.run(command, input=data, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")

    def test_helper_changes_invalidate_the_generated_stamp(self):
        project = self.root / "project"
        scripts = project / "scripts"
        scripts.mkdir(parents=True)
        source_scripts = Path(__file__).parent
        for name in ("ensure_generated.sh", "generate_bundle.sh", "bundle_source_functions.py"):
            shutil.copyfile(source_scripts / name, scripts / name)
        (scripts / "ensure_seed.sh").write_text("#!/bin/sh\nexit 0\n")
        compiler = project / "lib/@vibe/compiler"
        compiler.mkdir(parents=True)
        (project / "lib/@vibex").mkdir()
        seed = project / "bootstrap/seed"
        seed.mkdir(parents=True)
        (seed / "compiler.wasm").write_bytes(b"seed")
        (compiler / "compiler_sources_manifest.tsv").write_text("entry\tinput.vibe\n")
        (compiler / "input.vibe").write_text("fn main() -> Int { 42 }\n")
        for name in ("compiler_sources_bundle.vibe", "cli_adapter_bundle.vibe",
                     "selfbuild_runtime_entry_bundle.vibe", "_cli_adapter_module_source.vibe",
                     "cache/codegen_fingerprint.vibe"):
            file = compiler / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("generated fixture\n")
        command = ["bash", str(scripts / "ensure_generated.sh")]
        fingerprint = subprocess.check_output(command + ["--print-fingerprint"], text=True)
        (compiler / ".generated.stamp").write_text(fingerprint)
        self.assertEqual(subprocess.run(command + ["--check"], capture_output=True).returncode, 0)
        helper = scripts / "bundle_source_functions.py"
        helper.write_text(helper.read_text() + "\n# changed producer\n")
        result = subprocess.run(command + ["--check"], capture_output=True)
        self.assertNotEqual(result.returncode, 0, "stamped output hid an edited source producer")
        self.assertIn(b"STALE", result.stderr)


def os_records(records):
    return ("\0".join(records) + "\0").encode()


if __name__ == "__main__":
    unittest.main()
