"""Bind candidate images to the actual dirty-source overlay and generated inputs."""
import json, os, subprocess, sys
from pathlib import Path
sys.path.insert(0,str(Path.cwd()/'bench/perf'))
import selfbuild_baseline as base
repo=Path.cwd();lab=repo/'_build/function-worker-transfer-3483-20261018'
compiler=lab/'candidate-generation/stage2.wasm';images=lab/'candidate-images'
base.fixed_point(compiler.parent)
assert base.sha(compiler)==base.sha(compiler.parent/'stage3.wasm')
env=base.clean_env(repo)
subprocess.run(['bash','scripts/ensure_generated.sh'],cwd=repo,env=env,check=True)
paths=subprocess.check_output(['git','ls-files','-z','--','lib','scripts','runtime/viberun']).split(b'\0')
paths=[Path(os.fsdecode(p)) for p in paths if p]
paths += [Path(p) for p in ['lib/@vibe/compiler/compiler_sources_bundle.vibe','lib/@vibe/compiler/cli_adapter_bundle.vibe',
 'lib/@vibe/compiler/selfbuild_runtime_entry_bundle.vibe','lib/@vibe/compiler/_cli_adapter_module_source.vibe','lib/@vibe/compiler/cache/codegen_fingerprint.vibe']]
def sources():return {str(p):base.sha(repo/p) for p in paths if (repo/p).is_file()}
before=sources();patch=subprocess.check_output(['git','diff','--binary','HEAD'])
images.mkdir()
(images/'source-overlay.patch').write_bytes(patch)
subprocess.run(['bash','scripts/build_taskgroup_functions.sh',str(compiler),str(images)],cwd=repo,env=env,check=True)
assert before==sources() and patch==subprocess.check_output(['git','diff','--binary','HEAD']),'image-build source changed'
receipt=json.loads((images/'build.json').read_text())
assert receipt['context_format']==6 and receipt['compiler_sha256']==base.sha(compiler)
assert receipt['runner_sha256']==base.sha(lab/'baseline/engines/o0/viberun')
base.write(images/'source-authority.json',{'base_commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'patch_sha256':base.sha(images/'source-overlay.patch'),'sources':before,'compiler_generation':base.fixed_point(compiler.parent),
 'image_receipt':receipt,'qualification':'Exact dirty implementation source and generated library inputs held constant throughout image build. No claim that original baseline wire4/metadata3 receipts were corrected retroactively.'})
print('Candidate images source and receipts verified.',flush=True)
