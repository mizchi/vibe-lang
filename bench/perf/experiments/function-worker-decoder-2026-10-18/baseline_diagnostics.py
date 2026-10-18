"""Replay baseline diagnostics sequentially, then the archived phase probe."""
import json, subprocess, sys
from pathlib import Path
repo=Path.cwd(); lab=Path(sys.argv[1]).resolve(); archive=Path(sys.argv[2]).resolve()
for command in ['parents','workers','memory','summarize']:
    subprocess.run([sys.executable,'bench/perf/selfbuild_profiles.py',command,str(lab/'baseline')],check=True)
(lab/'native-diagnostics-stage.json').write_text(json.dumps({'stage':'summarize','status':'completed'})+'\n')
(lab/'native-diagnostics-pipeline.exit').write_text('0\n')
subprocess.run([sys.executable,str(archive/'diagnostic_controls.py'),str(lab)],check=True)
(lab/'diagnostic-controls.exit').write_text('0\n')
subprocess.run([sys.executable,str(archive/'parent_phase_probe_before.py'),str(lab)],check=True)
