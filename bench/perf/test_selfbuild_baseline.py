"""Refusal probes for measurements that would otherwise look successful."""
import importlib.util
import json
import subprocess
from unittest import mock
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("baseline", Path(__file__).with_name("selfbuild_baseline.py"))
baseline = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(baseline)


class ReceiptRefusalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def generation(self):
        stages = {}
        for name in ["stage0", "stage1", "stage2", "stage3"]:
            path = self.root / ("stage0_seed.wasm" if name == "stage0" else name + ".wasm")
            path.write_bytes(b"identical artifact")
            stages[name] = {"sha256": baseline.sha(path)}
        data = {"stages": stages, "result": {"stage3_equal_stage2": True}}
        baseline.write(self.root / "generation.json", data)
        return data

    def test_marker_without_actual_fixpoint_is_refused(self):
        data = self.generation()
        baseline.fixed_point(self.root)
        (self.root / "stage3.wasm").write_bytes(b"different valid artifact")
        data["stages"]["stage3"]["sha256"] = baseline.sha(self.root / "stage3.wasm")
        baseline.write(self.root / "generation.json", data)
        with self.assertRaisesRegex(ValueError, "stage2 and stage3 bytes differ"):
            baseline.fixed_point(self.root)

    def test_stale_successful_manifest_is_refused(self):
        self.generation()
        (self.root / "stage1.wasm").write_bytes(b"changed after generation")
        with self.assertRaisesRegex(ValueError, "artifact differs: stage1"):
            baseline.fixed_point(self.root)

    def test_absent_fixpoint_claim_is_refused_even_for_equal_files(self):
        data = self.generation()
        data["result"]["stage3_equal_stage2"] = None
        baseline.write(self.root / "generation.json", data)
        with self.assertRaisesRegex(ValueError, "did not prove"):
            baseline.fixed_point(self.root)

    def source(self):
        (self.root / "source.vibe").write_text("fn main() -> Int { 4 }")
        seed = self.root / "bootstrap/seed/compiler.wasm"
        seed.parent.mkdir(parents=True)
        seed.write_bytes(b"pinned seed")
        return {"tracked_files": {"source.vibe": {"sha256": baseline.sha(self.root / "source.vibe")}},
                "seed": {"artifact": {"sha256": baseline.sha(seed)}}}

    def test_changed_source_is_not_relabelled_as_frozen_input(self):
        meta = self.source()
        baseline.verify_source(self.root, meta)
        (self.root / "source.vibe").write_text("fn main() -> Int { 5 }")
        with self.assertRaisesRegex(ValueError, "frozen source changed"):
            baseline.verify_source(self.root, meta)

    def test_changed_seed_is_refused(self):
        meta = self.source()
        (self.root / "bootstrap/seed/compiler.wasm").write_bytes(b"another compiler")
        with self.assertRaisesRegex(ValueError, "frozen seed changed"):
            baseline.verify_source(self.root, meta)

    def test_current_trace_helper_needs_no_source_patch(self):
        corpus = self.root / "corpus"
        (corpus / "scripts").mkdir(parents=True)
        helper = (baseline.REPO / "scripts/trace_lib.sh").read_text()
        (corpus / "scripts/trace_lib.sh").write_text(helper)
        seed = corpus / "bootstrap/seed/compiler.wasm"
        seed.parent.mkdir(parents=True)
        seed.write_bytes(b"seed")
        meta = {"tracked_files": {"scripts/trace_lib.sh": {"sha256": baseline.sha(corpus / "scripts/trace_lib.sh")}},
                "seed": {"artifact": {"sha256": baseline.sha(seed)}}}
        baseline.write(self.root / "workspace.json", meta)
        baseline.monotonic_spans(self.root)
        result = json.loads((self.root / "workspace.json").read_text())
        instrumentation = result["host_instrumentation"]
        self.assertEqual(instrumentation["original_sha256"], instrumentation["measured_sha256"])
        self.assertEqual((self.root / "host-clock.patch").read_text(), "")
        baseline.verify_source(corpus, result)

    def image_set(self):
        engines = self.root / "engines"
        for lane in ["o0", "a0"]:
            (engines / lane).mkdir(parents=True)
            (engines / lane / "compiler.wasm").write_bytes(b"current compiler")
            (engines / lane / "viberun").write_bytes(b"current runner")
        images = engines / "images"
        images.mkdir()
        artifacts = {}
        for name in ["worker.wasm", "compile.wasm", "coordinator.component.wasm"]:
            (images / name).write_bytes(name.encode())
            artifacts[name] = baseline.sha(images / name)
        digest = baseline.sha(engines / "o0/compiler.wasm")
        baseline.write(images / "build.json", {"version": 1, "kind": "vibe-taskgroup-functions", "compiler_sha256": digest,
                       "runner_sha256": baseline.sha(engines / "o0/viberun"), "artifacts": artifacts,
                       "function_abi": "bump-core-tagged-callbacks-2", "context_format": 7, "job_format": 2,
                       "compile_engine_rc": 0, "worker_engine_rc": 0, "coordinator_engine_rc": 1})
        producer = {"result": {"stage3_equal_stage2": True}, "stages": {
            "stage2": {"sha256": digest}, "stage3": {"sha256": digest}}}
        baseline.write(engines / "compiler-generation.json", producer)
        (self.root / "bootstrap").mkdir()
        baseline.write(self.root / "bootstrap/measurement.json", {"verified_complete": True, "artifacts": {"compiler": digest}})
        return producer

    def test_consistent_images_must_belong_to_measured_producer(self):
        producer = self.image_set()
        baseline.image_receipts(self.root)
        producer["stages"]["stage2"]["sha256"] = "stale producer"
        baseline.write(self.root / "engines/compiler-generation.json", producer)
        with self.assertRaisesRegex(ValueError, "measured producer"):
            baseline.image_receipts(self.root)

    def test_consistent_images_must_belong_to_completed_bootstrap(self):
        self.image_set()
        baseline.image_receipts(self.root)
        baseline.write(self.root / "bootstrap/measurement.json", {"verified_complete": True, "artifacts": {"compiler": "another run"}})
        with self.assertRaisesRegex(ValueError, "measured producer"):
            baseline.image_receipts(self.root)

    def test_measurement_refuses_unknown_abi_or_phase_formats_before_launch(self):
        self.image_set()
        path = self.root / "engines/images/build.json"
        original = json.loads(path.read_text())
        for changes in ({"function_abi": "unknown"},
                        {"function_abi": "bump-core-returning-phases-3"},
                        {"function_abi": "bump-core-returning-phases-3", "phase_format": 1, "assembly_format": 2},
                        {"function_abi": "bump-core-returning-phases-3", "phase_format": True, "assembly_format": 1},
                        {"compile_engine_rc": 1}, {"compile_engine_rc": False},
                        {"version": True}, {"job_format": 1}, {"context_format": 6}):
            with self.subTest(changes=changes):
                baseline.write(path, original | changes)
                with self.assertRaises(ValueError):
                    baseline.matrix_command(self.root, "s0", "main.vibe", self.root / "out.wasm",
                                            "main", self.root / "cache", self.root / "trace.json")
                with self.assertRaises(ValueError):
                    baseline.image_receipts(self.root)
                self.assertFalse((self.root / "out.wasm").exists())

    def test_freeze_creates_ignored_seed_directory(self):
        repo = self.root / "repo"
        (repo / "bootstrap/seed").mkdir(parents=True)
        seed = repo / "bootstrap/seed/compiler.wasm"
        seed.write_bytes(b"seed")
        (repo / ".gitignore").write_text("bootstrap/seed/\n")
        baseline.write(repo / "bootstrap/seed.json", {"seed": {"artifact": {"sha256": baseline.sha(seed)}}})
        subprocess.run(["git", "init", "--quiet", str(repo)], check=True)
        subprocess.run(["git", "add", "."], cwd=repo, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "--quiet", "-m", "fixture"], cwd=repo, check=True)
        workspace = self.root / "frozen"
        with mock.patch.object(baseline, "REPO", repo):
            baseline.freeze(workspace, "HEAD")
        self.assertEqual((workspace / "corpus/bootstrap/seed/compiler.wasm").read_bytes(), b"seed")
        meta = json.loads((workspace / "workspace.json").read_text())
        baseline.verify_source(workspace / "corpus", meta)

    def test_guest_memory_distinguishes_frontier_volume_and_reserved_pages(self):
        memory = baseline.guest_memory("vibe::mem heap_base=64 heap_peak=128 allocated=64 committed=65536 grow_events=0\n")
        self.assertEqual(memory, {"heap_base": 64, "heap_peak": 128, "allocated": 64, "committed": 65536, "pages": 1})

    def test_missing_or_impossible_guest_memory_is_refused(self):
        for text in ["no counters", "vibe::mem heap_base=64 allocated=64 committed=65536",
                     "vibe::mem heap_base=64 heap_peak=128 allocated=64 committed=100",
                     "vibe::mem heap_base=64 heap_peak=128 allocated=99 committed=65536"]:
            with self.assertRaises(ValueError):
                baseline.guest_memory(text)


if __name__ == "__main__":
    unittest.main()
