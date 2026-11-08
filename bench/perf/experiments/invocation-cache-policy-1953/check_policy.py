"""Check scoped persistent-cache behavior across fresh processes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("candidate_root", type=Path)
parser.add_argument("candidate_wasm", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
root, compiler, work = (p.resolve() for p in (args.candidate_root, args.candidate_wasm, args.output))
work.mkdir(exist_ok=False)
source = Path(__file__).with_name("cache_probe.vibe").resolve()
image = work / "probe.wasm"
env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
env.update(VIBE_PREOPEN_DIR=str(root), VIBE_FS_COMPILE="1", VIBE_RC="0", VIBE_IMPORT_ABI="raw", VIBE_BUILD_CACHE_DIR=str(work / "compile-cache"))
runner = root / "scripts/run_wasm_vibe_host_runner.sh"
p = subprocess.run(["bash", str(runner), "--invoke", "cli_main", str(compiler), str(source.relative_to(root)), str(image), "main"], cwd=root, env=env, capture_output=True, text=True, timeout=900)
(work / "compile.log").write_text(p.stdout + p.stderr)
diag = Path(str(image) + ".diag")
assert p.returncode == 0 and p.stdout.strip() == "0" and image.exists(), (p.stdout, diag.read_text() if diag.exists() else p.stderr)
subprocess.run(["wasm-tools", "validate", str(image)], check=True)
program = work / "source.vibe"
text = "#cfg(alpha)\nexport let a = 11\n#cfg(beta)\nexport let b = 22\n#cfg(beta)\nexport let c = 33\n"
program.write_text(text)
receipt = {"compiler_sha256": hashlib.sha256(compiler.read_bytes()).hexdigest(), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "image_sha256": hashlib.sha256(image.read_bytes()).hexdigest(), "runs": []}

def run(label, ast, stamp, flags, count, ran, **telemetry):
    run_env = dict(env, VIBE_BUILD_CACHE_DIR=str(work / "cache"), CACHE_POLICY_SOURCE=str(program), CACHE_POLICY_FLAGS=flags, CACHE_POLICY_AST=str(ast), CACHE_POLICY_STAMP=str(stamp))
    p = subprocess.run(["bash", str(runner), "--invoke", "_start", str(image)], cwd=root, env=run_env, capture_output=True, text=True, timeout=180)
    (work / (label + ".log")).write_text(p.stdout + p.stderr)
    assert p.returncode == 0, (label, p.stdout, p.stderr)
    f = p.stdout.strip().split("\t")
    assert len(f) == 7 and f[0] == "cache-policy", (label, f)
    row = {"label": label, "ast": ast, "stamp": stamp, "flags": flags, "fingerprint": f[1], "stmt_count": int(f[2]), "ran_parser": int(f[3]), "telemetry": json.loads(f[4]), "ast_path": f[5], "stamp_path": f[6]}
    assert (row["stmt_count"], row["ran_parser"]) == (count, ran), row
    for key, value in telemetry.items():
        assert row["telemetry"][key] == value, (label, key, row)
    receipt["runs"].append(row)
    (work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS " + label, flush=True)
    return row

cold = run("cold", 1, 1, "alpha", 1, 1, source_read_calls=1, stamp_hits=0, stamp_publications=1)
warm = run("warm", 1, 1, "alpha", 1, 0, source_read_calls=0, stamp_hits=1, stamp_publications=0)
off = run("off-with-warm-files", 0, 0, "alpha", 1, 1, source_read_calls=1, stamp_probes=0, stamp_publications=0)
assert cold["fingerprint"] == warm["fingerprint"] == off["fingerprint"]
Path(cold["ast_path"]).write_bytes(b"\xff")
Path(cold["stamp_path"]).write_text("malformed")
bad = run("malformed", 1, 1, "alpha", 1, 1, source_read_calls=1, stamp_malformed=1, stamp_publications=1)
assert bad["fingerprint"] == cold["fingerprint"]
program.write_text(text + "#cfg(alpha)\nexport let after_edit = 777\n")
edited = run("edited", 1, 1, "alpha", 2, 1, source_read_calls=1, stamp_hits=0, stamp_publications=1)
assert edited["fingerprint"] != cold["fingerprint"]
run("edited-warm", 1, 1, "alpha", 2, 0, source_read_calls=0, stamp_hits=1, stamp_publications=0)
beta = run("other-namespace", 1, 1, "beta", 2, 1, source_read_calls=1, stamp_hits=0, stamp_publications=1)
assert beta["ast_path"] != edited["ast_path"] and beta["stamp_path"] != edited["stamp_path"]
run("other-namespace-warm", 1, 1, "beta", 2, 0, source_read_calls=0, stamp_hits=1, stamp_publications=0)
