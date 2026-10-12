"""Safely copy the five user-supplied camping FBX archives into the project."""
import hashlib
import json
import pathlib
import stat
import zipfile

ROOT=pathlib.Path(__file__).resolve().parents[3]
INPUT=pathlib.Path('/Users/chengzeyuan/Desktop/露营点位模型及概念图')
OUTPUT=ROOT/'assets/traveler/panti/camp/source'
REPORT=ROOT/'docs/reports/traveler-panti-001/assets/camp'
SOURCES={'tent':'teepee tent 3d model.zip','stump':'tree stump 3d model.zip',
         'firepit':'log pile 3d model.zip','lantern':'lantern 3d model.zip',
         'banner':'tattered banner 3d model.zip'}
REPORT.mkdir(parents=True,exist_ok=True)
report={}
for name,filename in SOURCES.items():
    archive=INPUT/filename
    destination=(OUTPUT/name).resolve()
    destination.mkdir(parents=True,exist_ok=True)
    records=[]
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            relative=pathlib.PurePosixPath(member.filename)
            if relative.is_absolute() or '..' in relative.parts or '\\' in member.filename:
                raise ValueError(f'Unsafe archive path: {member.filename}')
            if stat.S_ISLNK(member.external_attr>>16):
                raise ValueError(f'Symlink archive member: {member.filename}')
            target=(destination/pathlib.Path(*relative.parts)).resolve()
            if not target.is_relative_to(destination): raise ValueError(member.filename)
            if member.is_dir(): target.mkdir(parents=True,exist_ok=True);continue
            data=bundle.read(member)
            if target.exists() and target.read_bytes()!=data:
                raise FileExistsError(f'Refusing to overwrite changed source: {target}')
            target.parent.mkdir(parents=True,exist_ok=True)
            if not target.exists(): target.write_bytes(data)
            records.append({'member':member.filename,'bytes':len(data),
                            'sha256':hashlib.sha256(data).hexdigest(),
                            'extracted':str(target.relative_to(ROOT))})
    report[name]={'archive':str(archive),'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),
                  'files':records}
(REPORT/'source-manifest.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
print(json.dumps(report,indent=2,ensure_ascii=False))
