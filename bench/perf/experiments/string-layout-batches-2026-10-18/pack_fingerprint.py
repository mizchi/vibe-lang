"""Pack exact raw evidence together so repeated profile tables compress once."""
import gzip,hashlib,io,json,shutil,tarfile
from pathlib import Path
root=Path.cwd();lab=Path(__file__).resolve().parent
experiment=root/'bench/perf/experiments/string-layout-batches-2026-10-18'
manifest=json.loads((experiment/'manifest.json').read_text());assert manifest['complete']
temporary=lab/'packed-evidence';temporary.mkdir()
index=[];seen=set()
archive=temporary/'evidence.tar.xz'
with tarfile.open(archive,'w:xz',preset=6) as tar:
 def add(name,data):
  assert not Path(name).is_absolute() and '..' not in Path(name).parts and name not in seen,name
  seen.add(name);info=tarfile.TarInfo(name);info.size=len(data);info.mtime=0;info.mode=0o644
  tar.addfile(info,io.BytesIO(data))
 for row in manifest['entries']:
  stored=(experiment/row['path']).read_bytes()
  assert hashlib.sha256(stored).hexdigest()==row['stored_sha256']
  compressed=row['path'].endswith('.gz');data=gzip.decompress(stored) if compressed else stored
  assert hashlib.sha256(data).hexdigest()==row['raw_sha256'] and len(data)==row['raw_bytes']
  name=row['path'][:-3] if compressed else row['path']
  add(name,data);index.append({'member':name,'bytes':len(data),'sha256':row['raw_sha256'],'source':row['source']})
 add('expanded-manifest.json',(experiment/'manifest.json').read_bytes())
 packed={'complete':True,'entries':index,'scope':'Exact original uncompressed bytes. Individual gzip envelopes are removed before solid XZ compression; no source, JSON, log or whitespace is normalized. expanded-manifest.json retains the earlier per-file gzip hashes.'}
 data=(json.dumps(packed,indent=2)+'\n').encode();add('manifest.json',data)
(temporary/'evidence-index.json.gz').write_bytes(gzip.compress(data,mtime=0))
with tarfile.open(archive,'r:xz') as tar:
 assert len(tar.getmembers())==len(index)+2
 for row in index:
  data=tar.extractfile(row['member']).read()
  assert len(data)==row['bytes'] and hashlib.sha256(data).hexdigest()==row['sha256']
 assert tar.extractfile('manifest.json').read()==gzip.decompress((temporary/'evidence-index.json.gz').read_bytes())
for source in experiment.glob('*.py'):shutil.copy2(source,temporary/source.name)
shutil.copy2(__file__,temporary/Path(__file__).name)
record={'complete':True,'archive':'evidence.tar.xz','archive_bytes':archive.stat().st_size,'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'index':'evidence-index.json.gz','raw_index_sha256':hashlib.sha256(gzip.decompress((temporary/'evidence-index.json.gz').read_bytes())).hexdigest(),'entries':len(index),'packaging_driver_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'scope':'Post-measurement packaging only. All1057 original raw entries verified after decoding archive. Executed measurement drivers remain individually readable; original expanded archive retained privately.'}
(temporary/'archive.json').write_text(json.dumps(record,indent=2)+'\n')
experiment.rename(lab/'expanded-evidence');temporary.rename(experiment)
print('Verified',len(index),'raw entries in',round(record['archive_bytes']/2**20,2),'MiB; original expanded evidence retained.',flush=True)
