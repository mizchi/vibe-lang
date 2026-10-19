"""Aggregate complete raw guest epoch counters after all unprofiled timings."""
import collections
import hashlib
import json
from pathlib import Path

root = Path.cwd()
work = root / '_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation'
control = json.loads((work / 'final-measurements-v1/result.json').read_text())
assert control['complete'] and all(step['exit'] == 0 for step in control['steps'])
actual = json.loads((work / 'actual-bootstrap-comparison-v1/measurement.json').read_text())
assert actual['verified_complete'] and len(actual['samples']) == 24
assert (work / 'actual-bootstrap-comparison-v1/summary.json').is_file()
diagnostics = work / 'phase-lifetime-diagnostics-v2'
raw = (diagnostics / 'result.json').read_bytes()
record = json.loads(raw)
assert record['complete'] and record['source_unchanged']
requests = []
for row in record['parent_runs']:
    if not row['index']:
        continue
    for relative, digest in row['profiles'].items():
        role = 'prepare' if relative.endswith('.function_phase_prepare') else (
            'finish' if relative.endswith('.function_phase_finish') else 'parent_callback')
        requests.append((relative, digest, row['subject'], row['lane'], role, row['index'], None))
for row in record['worker_runs']:
    if row['index']:
        requests.append((row['profile']['path'], row['profile']['sha256'], row['subject'],
                         row['lane'], 'worker', row['index'], row['slot']))
assert len(requests) == len({r[0] for r in requests}) == 66
out = work / 'profile-analysis-v2'
out.mkdir()
profiles = {}
groups = {}
scope = ('Warm diagnostics only: pooled guest epoch sample counts, host work excluded. '
         'Inclusive ancestors overlap. Preparation, finisher and callback profiles have '
         'different denominators; never compare their percentages as walltime improvements. '
         'All function rows are retained, with no top-list truncation before aggregation.')

def table(counter, total):
    return [{'name': name, 'weight': count, 'percent': count * 100 / total}
            for name, count in counter.most_common()]

for relative, digest, subject, lane, role, replay, slot in requests:
    data = (diagnostics / relative).read_bytes()
    assert hashlib.sha256(data).hexdigest() == digest, relative
    profile = json.loads(data)
    own = collections.Counter()
    inclusive = collections.Counter()
    for thread in profile['threads']:
        stacks = thread['stackTable']
        frames = thread['frameTable']
        functions = thread['funcTable']
        names = thread['stringArray']
        name = [names[functions['name'][frames['func'][frame]]] for frame in stacks['frame']]
        counts = collections.Counter(stack for stack in thread['samples']['stack'] if stack is not None)
        for stack, count in counts.items():
            own[name[stack]] += count
            ancestors = set()
            visited = set()
            while stack is not None:
                assert stack not in visited, 'cyclic profile stack'
                visited.add(stack)
                ancestors.add(name[stack])
                stack = stacks['prefix'][stack]
            inclusive.update({function: count for function in ancestors})
    total = sum(own.values())
    assert total > 0 and all(0 < count <= total for count in inclusive.values())
    key = '/'.join((subject, lane, role))
    group = groups.setdefault(key, {'self': collections.Counter(), 'inclusive': collections.Counter(),
                                    'profiles': [], 'replays': set(), 'slots': set()})
    group['self'].update(own)
    group['inclusive'].update(inclusive)
    group['profiles'].append(relative)
    group['replays'].add(replay)
    if slot is not None:
        group['slots'].add(slot)
    profiles[relative] = {'unit': 'guest epoch samples; host work excluded', 'total_weight': total,
                         'self': table(own, total), 'inclusive': table(inclusive, total),
                         'profile_sha256': digest, 'group': key, 'interpretation': scope}
    print(relative, total, 'samples', flush=True)

pooled = {}
for key, group in groups.items():
    assert group['replays'] == {1, 2, 3}
    worker = key.endswith('/worker')
    assert len(group['profiles']) == (12 if worker else 3)
    assert group['slots'] == ({0, 1, 2, 3} if worker else set())
    total = sum(group['self'].values())
    assert total == sum(profiles[p]['total_weight'] for p in group['profiles'])
    pooled[key] = {'total_weight': total, 'profile_count': len(group['profiles']),
                   'profiles': group['profiles'], 'replays': sorted(group['replays']),
                   'worker_slots': sorted(group['slots']), 'self': table(group['self'], total),
                   'inclusive': table(group['inclusive'], total), 'interpretation': scope}
assert len(profiles) == 66 and len(pooled) == 10
(out / 'profile-summary.json').write_text(json.dumps(profiles, indent=2) + '\n')
(out / 'group-summary.json').write_text(json.dumps(pooled, indent=2) + '\n')
(out / 'result.json').write_text(json.dumps({'complete': True, 'profiles': 66, 'groups': 10,
    'diagnostic_result_sha256': hashlib.sha256(raw).hexdigest(),
    'driver_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'scope': scope}, indent=2) + '\n')
print('All66raw profiles authenticated; full per-profile and pooled counters retained.', flush=True)
