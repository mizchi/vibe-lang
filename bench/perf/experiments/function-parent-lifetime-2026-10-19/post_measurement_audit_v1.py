"""Wait for the exact measurement controller to exit, then audit without builds."""
import hashlib
import json
import subprocess
import time
from pathlib import Path

root = Path.cwd()
work = root / '_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation'
parent_pid, parent_ticks = 1380568, '30593977'
parent_name = 'run_final_measurements_v1.py'

def parent_live():
    try:
        proc = Path('/proc') / str(parent_pid)
        stat = (proc / 'stat').read_text().split()
        command = (proc / 'cmdline').read_bytes()
        return stat[21] == parent_ticks and stat[2] != 'Z' and parent_name.encode() in command
    except FileNotFoundError:
        return False

assert parent_live(), 'expected exact existing measurement controller to be live at startup'
steps = ['summarize_actual_bootstrap_v1.py', 'aggregate_final_profiles_v1.py']
hashes = {name: hashlib.sha256((work / name).read_bytes()).hexdigest() for name in steps}
out = work / 'post-measurement-audit-v1'
out.mkdir()
report = {'complete': False, 'waiting_for': {'pid': parent_pid, 'start_ticks': parent_ticks,
    'command': parent_name}, 'step_driver_sha256': hashes, 'steps': [],
    'scope': 'No builds/tests/profiles or source/index edits. Wait for the exact old controller to exit successfully; only then audit24raw actual controls and aggregate66existing CPUprofiles.'}

def write():
    temporary = out / 'result.json.tmp'
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    temporary.replace(out / 'result.json')

write()
print('Waiting for existing measurement controller1380568; no measurements restarted.', flush=True)
while parent_live():
    time.sleep(15)
control = json.loads((work / 'final-measurements-v1/result.json').read_text())
actual = json.loads((work / 'actual-bootstrap-comparison-v1/measurement.json').read_text())
assert control['complete'] and len(control['steps']) == 4 and all(s['exit'] == 0 for s in control['steps'])
assert actual['verified_complete'] and len(actual['samples']) == 24
report.pop('waiting_for')
report['timing_controller_terminal_success'] = True
write()
for name in steps:
    assert hashlib.sha256((work / name).read_bytes()).hexdigest() == hashes[name]
    with (out / (name + '.log')).open('w') as log:
        child = subprocess.Popen(['python3', '-u', str(work / name)], cwd=root,
                                 stdout=log, stderr=subprocess.STDOUT)
        report['live_step'] = {'name': name, 'pid': child.pid,
            'start_ticks': (Path('/proc') / str(child.pid) / 'stat').read_text().split()[21]}
        write()
        code = child.wait()
    report.pop('live_step')
    report['steps'].append({'name': name, 'exit': code,
        'log_sha256': hashlib.sha256((out / (name + '.log')).read_bytes()).hexdigest()})
    write()
    if code:
        print((out / (name + '.log')).read_text()[-5000:], flush=True)
        raise SystemExit(code)
    print(name, code, flush=True)
report['complete'] = True
write()
print('Actual24raw controls/fixpoints and66complete CPUprofiles audited.', flush=True)
