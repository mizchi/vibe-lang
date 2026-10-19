"""Losslessly retain selected evidence only after all timed/profile work ends."""
import gzip
import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile
from pathlib import Path

root = Path.cwd()
work = root / '_build/function-worker-parent-lifetime-3483-20261018-dff3/typed-module-preparation'
destination = root / 'bench/perf/experiments/function-parent-lifetime-2026-10-19'
assert json.loads((work / 'final-measurements-v1/result.json').read_text())['complete']
assert json.loads((work / 'post-measurement-audit-v1/result.json').read_text())['complete']
actual = json.loads((work / 'actual-bootstrap-comparison-v1/summary.json').read_text())
assert actual['compiler_fixpoints_checked'] == 12
assert actual['raw_process_records_checked'] == actual['monotonic_span_records_checked'] == 24
profile = json.loads((work / 'profile-analysis-v2/result.json').read_text())
assert profile['complete'] and profile['profiles'] == 66 and profile['groups'] == 10
authority = json.loads((work / 'phase-lifetime-comparison-v2/authority.json').read_text())
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == authority['head']

def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()

for name, expected in authority['candidate_source_sha256'].items():
    assert sha(root / name) == expected, ('measured source changed before curation', name)
destination.mkdir()
primary = ['phase-lifetime-comparison-v2', 'phase-lifetime-diagnostics-v2',
           'actual-bootstrap-comparison-v1', 'after-format-validation-v1',
           'oracles-after-format-v1', 'native-phases-integration-v5',
           'measurement-control-v1', 'profile-analysis-v2',
           'final-measurements-v1', 'post-measurement-audit-v1']
historical = ['phase-lifetime-comparison-v1', 'phase-lifetime-diagnostics-v1',
              'serial-observation-comparison-v1', 'profile-analysis-v1',
              'after-main-validation-v1', 'oracles-main8bed-v1',
              'oracles-fs-v1', 'format-apply-v1', 'format-check-v1',
              'main-8bed-integration', 'assembly-integration-v1',
              'filesystem-preparation', 'public-fs-v1', 'phases-preflight-v1']
historical += [p.name for p in work.iterdir() if p.is_dir() and (
    p.name.startswith('assembly-v') or p.name.startswith('native-phase-observation-v')
    or (p.name.startswith('native-phases-integration-v') and p.name not in primary))]
special = {'after-format-validation-v1/candidate-sources.tar.gz',
           'format-apply-v1/before.tar.gz', 'main-8bed-integration/owned-before-main.tar.gz'}
selected = {}
omitted = []

def keep(path):
    relative = path.relative_to(work).as_posix()
    if path.is_symlink():
        return False
    name = path.name
    return (relative in special or name.endswith(('.json', '.ndjson', '.cpuprofile',
        '.tsv', '.txt', '.patch', '.list', '.receipt', '.wasm.diag', '.mjs', '.py', '.vpkg'))
        or name.startswith('cpu') or name.endswith('.log') or '.log.' in name
        or (name.endswith('.vibe') and not name.startswith('cli_adapter_module_source')))

for group in dict.fromkeys(primary + historical):
    base = work / group
    assert base.is_dir(), group
    for directory, children, files in os.walk(base, followlinks=False):
        directory = Path(directory)
        for child in list(children):
            path = directory / child
            excluded = (path.is_symlink() or child in {
                'reference', 'reference-main', 'candidate', 'native-cache', 'cache',
                '__pycache__', '.selfhost_bundle', '.git', '.vibe', 'target'}
                or child.endswith('-cache') or child.startswith('cache-') or '-cache-' in child
                or (group == 'actual-bootstrap-comparison-v1' and directory == base and child in {'a0', 'b0'}))
            if excluded:
                children.remove(child)
                omitted.append({'path': str(path.relative_to(work)), 'kind': 'directory',
                                'reason': 'regenerable checkout/cache or duplicate symlink'})
        for name in files:
            path = directory / name
            relative = path.relative_to(work).as_posix()
            if keep(path):
                selected['records/' + relative] = path
            else:
                omitted.append({'path': relative, 'bytes': path.lstat().st_size,
                                'reason': 'regenerable binary/transport/source-snapshot payload; retain recorded hashes'})

for path in sorted(work.glob('*.py')):
    if path.name in {'generate_assembly_draft.py', 'draft_measurement_updates.py',
                     'finish_refactor.py', 'install_native_phase_hooks.py', 'prepare_fs_refactor.py'}:
        continue
    selected['drivers/' + path.name] = path
    shutil.copy2(path, destination / path.name)
for path in sorted(work.glob('*audit*.json')):
    selected['records/' + path.name] = path
selected['records/archival-plan-v1.json'] = work / 'archival-plan-v1.json'
entries = [{'member': name, 'bytes': path.stat().st_size, 'sha256': sha(path)}
           for name, path in sorted(selected.items())]
index = {'scope': 'Exact raw bytes. Primary final formatted-source evidence and explicitly separate historical trials. '
         'One original final full source snapshot, original formatting backup and owned main-integration backup retained. '
         'Other large regenerable payloads remain local; recorded authorities/receipts retain their identities.',
         'primary_groups': primary, 'historical_groups': historical, 'entries': entries, 'omitted': omitted,
         'archive_metadata': 'Tar owners and timestamps normalized; member bytes and file modes preserved.'}
index_bytes = (json.dumps(index, indent=2) + '\n').encode()
archive_path = destination / 'evidence.tar.xz'
with tarfile.open(archive_path, 'w:xz', preset=6) as archive:
    metadata = tarfile.TarInfo('manifest.json')
    metadata.size = len(index_bytes)
    metadata.mode = 0o644
    archive.addfile(metadata, io.BytesIO(index_bytes))
    for row in entries:
        path = selected[row['member']]
        metadata = archive.gettarinfo(str(path), arcname=row['member'])
        metadata.uid = metadata.gid = metadata.mtime = 0
        metadata.uname = metadata.gname = ''
        with path.open('rb') as stream:
            archive.addfile(metadata, stream)
with tarfile.open(archive_path, 'r:xz') as archive:
    assert archive.extractfile('manifest.json').read() == index_bytes
    assert len(archive.getmembers()) == len(entries) + 1
    for row in entries:
        stream = archive.extractfile(row['member'])
        digest = hashlib.sha256()
        count = 0
        for chunk in iter(lambda: stream.read(65536), b''):
            digest.update(chunk)
            count += len(chunk)
        assert count == row['bytes'] and digest.hexdigest() == row['sha256'], row['member']
(destination / 'evidence-index.json.gz').write_bytes(gzip.compress(index_bytes, mtime=0))
receipt = {'archive': 'evidence.tar.xz', 'archive_sha256': sha(archive_path),
           'archive_bytes': archive_path.stat().st_size, 'entries': len(entries),
           'index': 'evidence-index.json.gz', 'raw_index_sha256': hashlib.sha256(index_bytes).hexdigest(),
           'curator_sha256': sha(Path(__file__)), 'all_member_bytes_independently_verified': True,
           'baseline': authority['head'], 'scope': index['scope']}
assert receipt['archive_bytes'] < 90 * 1024 * 1024, 'preserve all bytes; split losslessly before publication'
(destination / 'archive.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2), flush=True)
