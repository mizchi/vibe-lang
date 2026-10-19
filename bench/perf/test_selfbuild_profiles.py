"""Diagnostic integrity: names-only artifacts, exact captures and attribution."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import selfbuild_profiles as profiles


class ProfileIntegrityTests(unittest.TestCase):
    def test_validation_refuses_a_different_entry_producer(self):
        for wrong_entry in [False, True]:
            with self.subTest(wrong_entry=wrong_entry), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                corpus = root / "corpus"
                generation = corpus / "_build/measured-generation"
                generation.mkdir(parents=True)
                (generation / "cli_adapter_module_source.vibe").write_bytes(b"flat source")
                seed = corpus / "bootstrap/seed/compiler.wasm"
                seed.parent.mkdir(parents=True)
                seed.write_bytes(b"seed")
                producer = corpus / "_build/selfhost/generations/portable"
                producer.mkdir(parents=True)
                (producer / "cli_adapter_module_source.vibe").write_bytes(b"flat source")
                digest = lambda value: profiles.hashlib.sha256(value).hexdigest()
                manifest = {"stages": {"stage1": {"sha256": digest(b"cli_main")}}}
                profiles.base.write(producer / "generation.json", {"stages": {"stage1": {"sha256": digest(b"main")}}})

                def compile_probe(command, cwd, env, logs):
                    entry = command[-1]
                    output = corpus / command[-2]
                    output.write_bytes(b"cli_main" if wrong_entry else entry.encode())

                with mock.patch.object(profiles.base, "fixed_point", return_value=manifest), mock.patch.object(profiles, "run", side_effect=compile_probe):
                    if wrong_entry:
                        with self.assertRaisesRegex(ValueError, "differs from measured stage1 for entry main"):
                            profiles.validation(root)
                        self.assertFalse((root / "validation-probe/receipt.json").exists())
                    else:
                        profiles.validation(root)
                        result = json.loads((root / "validation-probe/receipt.json").read_text())
                        self.assertTrue(all(row["stage1_byte_identity"] for row in result["entries"]))
                        self.assertEqual([row["requires_entry_plumbing"] for row in result["entries"]], [False, True])

    def test_context_pool_counts_wire_and_payload_without_literal_text(self):
        for version in [3, 4, 6, 7]:
            with self.subTest(version=version):
                magic = f"vibe-function-context-{version}".encode()
                data = bytes([len(magic)]) + magic + b"\x02\x03abc\x02xy\x00"
                result = profiles.context_pool(data)
                self.assertEqual(result["context_format"], version)
                self.assertEqual(result["pool_entries"], 2)
                self.assertEqual(result["pool_payload_bytes"], 5)
                self.assertEqual(result["pool_wire_bytes"], 8)
                self.assertEqual(result["context_bytes"], len(data))
                self.assertNotIn("abc", json.dumps(result))
                with self.assertRaisesRegex(ValueError, "truncated"):
                    profiles.context_pool(data[:-3])

    def test_context_pool_refuses_unknown_versions(self):
        magic = b"vibe-function-context-999"
        with self.assertRaisesRegex(ValueError, "unsupported context prefix"):
            profiles.context_pool(bytes([len(magic)]) + magic + b"\x00")

    def test_removes_only_name_sections(self):
        header = b"\0asm\x01\0\0\0"
        ordinary = header + b"\0\x06\x04keep!"
        named = ordinary + b"\0\x06\x04name\0"
        self.assertEqual(profiles.without_names(named), ordinary)
        changed = header + b"\0\x06\x04keep?" + b"\0\x06\x04name\0"
        self.assertNotEqual(profiles.without_names(changed), ordinary)

    def test_recursion_is_not_double_counted_and_cpuprofile_is_discovered(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "ordinary-profiles/flat-1"
            folder.mkdir(parents=True)
            nodes = [{"id": 1, "callFrame": {"functionName": "root"}, "children": [2]},
                     {"id": 2, "callFrame": {"functionName": "emit"}, "children": [3]},
                     {"id": 3, "callFrame": {"functionName": "emit"}, "children": [4]},
                     {"id": 4, "callFrame": {"functionName": "encode"}}]
            (folder / "cpu.cpuprofile").write_text(json.dumps({"nodes": nodes, "samples": [3, 4], "timeDeltas": [70, 30]}))
            profiles.summarize(root)
            rows = json.loads((root / "profile-summary.json").read_text())
            result = rows["ordinary-profiles/flat-1/cpu.cpuprofile"]
            self.assertEqual(result["total_weight"], 100)
            inclusive = {r["name"]: r["percent"] for r in result["inclusive"]}
            self.assertEqual(inclusive["emit"], 100)
            self.assertEqual(inclusive["encode"], 30)

    def test_phase_memory_keeps_preparation_and_finish_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            images = root / "engines/images"
            images.mkdir(parents=True)
            profiles.base.write(images / "build.json", {
                "version": 1, "kind": "vibe-taskgroup-functions", "function_abi": "bump-core-returning-phases-3",
                "phase_format": 1, "assembly_format": 1, "context_format": 7, "job_format": 2,
                "compile_engine_rc": 0, "worker_engine_rc": 0, "coordinator_engine_rc": 1})
            parent = root / "parent-profiles/compiler-0/logs/stderr.log"
            parent.parent.mkdir(parents=True)
            prepare = "vibe::mem heap_base=64 heap_peak=192 allocated=128 committed=65536"
            finish = "vibe::mem heap_base=64 heap_peak=128 allocated=64 committed=65536"
            parent.write_text(prepare + "\n" + finish + "\n")
            worker = root / "worker-profiles/capture-compiler-slot/0/stderr.log"
            worker.parent.mkdir(parents=True)
            worker.write_text(finish + "\n")
            context = root / "parent-profiles/capture-compiler/phase-wave/shared.context"
            context.parent.mkdir(parents=True)
            magic = b"vibe-function-context-7"
            context.write_bytes(bytes([len(magic)]) + magic + b"\x00")
            profiles.memory(root)
            result = json.loads((root / "memory-summary.json").read_text())
            phases = result["parent_guest"][str(parent.relative_to(root))]
            self.assertEqual(phases["prepare"]["allocated"], 128)
            self.assertEqual(phases["finish"]["allocated"], 64)
            parent.write_text(finish + "\n")
            with self.assertRaisesRegex(ValueError, "missing preparation/finisher"):
                profiles.memory(root)

    def test_capture_records_real_job_and_product_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / "capture.py"
            wrapper.write_text(profiles.CAPTURE)
            (root / "context").write_bytes(b"shared")
            job = root / "0.job"
            job.write_bytes(b"normalized job")
            Path(str(job) + ".product").write_bytes(b"emitted body")
            plan = root / "wave-0.json"
            plan.write_text(json.dumps({"context": str(root / "context"), "queues": [[str(job)], [], [], []]}))
            env = dict(os.environ, SELFBUILD_NATIVE_RUNNER=sys.executable, SELFBUILD_CAPTURE=str(root / "capture"), VIBE_LOWERING_WORKERS=str(plan))
            subprocess.run([sys.executable, str(wrapper), "-c", "pass"], env=env, check=True)
            result = json.loads((root / "capture/wave-0/capture.json").read_text())
            self.assertEqual(result["context_bytes"], 6)
            self.assertEqual(result["queues"][0][0]["input_bytes"], len(b"normalized job"))
            self.assertEqual(result["queues"][0][0]["product_bytes"], len(b"emitted body"))
            self.assertEqual((root / "capture/wave-0/0.job").read_bytes(), job.read_bytes())


if __name__ == "__main__":
    unittest.main()
