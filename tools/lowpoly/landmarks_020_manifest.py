#!/usr/bin/env python3
"""Inventory final deliverables and externally stored source-bound evidence."""
from pathlib import Path
import argparse,hashlib,json
ROOT=Path(__file__).resolve().parents[2];LIB=ROOT/'docs/design/landmark-library-020'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--evidence',type=Path,required=True);args=parser.parse_args();ev=args.evidence
    own=LIB/'validation/evidence-manifest.json';storage=LIB/'validation/storage-report.json'
    repository=[p for p in LIB.rglob('*') if p.is_file() and p not in [own,storage] and '.DS_Store' not in p.name]
    repository+=list((ROOT/'tools/lowpoly').glob('landmarks_020*.py'))+list((ROOT/'tools/lowpoly').glob('landmarks_020*.gd'))
    repository.append(ROOT/'docs/reports/task-landmark-library-020.md')
    repository.append(ROOT/'docs/CURRENT-STATE.md')
    assert all(p.stat().st_size<10*1024**2 for p in repository),'A final repository file exceeds 10 MiB'
    validation_bytes=sum(p.stat().st_size for p in (LIB/'validation').rglob('*') if p.is_file() and p not in [own,storage])
    assert validation_bytes<20*1024**2,'Validation exceeds task storage cap'
    report={'task':'TASK-LANDMARK-LIBRARY-020','single_file_limit_bytes':10*1024**2,'validation_limit_bytes':20*1024**2,
            'largest_repository_file':{'path':str(max(repository,key=lambda p:p.stat().st_size).relative_to(ROOT)),'bytes':max(p.stat().st_size for p in repository)},
            'library_bytes_before_inventory':sum(p.stat().st_size for p in LIB.rglob('*') if p.is_file() and p not in [own,storage]),
            'validation_bytes_before_inventory':validation_bytes,'raw_frames_external':True,'passed':True}
    storage.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');repository.append(storage)
    studio=json.loads((LIB/'validation/studio-capture-report.json').read_text())
    external=[ev/'baseline/input-start.json',Path(studio['source_report']['path'])]
    external+=[Path(c['raw']) for a in studio['assets'] for c in a['captures']]
    external+=list((ev/'gallery-qa').glob('*.png'))+list((ev/'contact-sheets').glob('*.jpg'))
    for name in ['east-geography.md','south-geography.md','geography-review.md','east-sources.json','south-sources.json','west-sources.json','verification-review.md','studio-lighting-decision.json','normals-after-fix.log','south-final-visual-review.md','south-final-visual-review.json','west-final-visual-closure.md','west-final-visual-closure.json','west-canal-support-audit.json','west-canal-revision-handoff.json']:
        if (ev/name).exists():external.append(ev/name)
    rows=[]
    for scope,paths in [('repository',repository),('external',external)]:
        for p in sorted(set(paths)):
            assert p.is_file(),p
            rows.append({'scope':scope,'path':str(p.relative_to(ROOT)) if scope=='repository' else str(p),'bytes':p.stat().st_size,'sha256':sha(p)})
    own.write_text(json.dumps({'task':'TASK-LANDMARK-LIBRARY-020','method':'Final deliverable inventory; this manifest excludes itself. Preliminary render experiments are retained externally and are not claimed as final captures. No source hash is inferred from a filename.','files':rows,'file_count':len(rows),'repository_files':len(set(repository)),'external_files':len(set(external))},ensure_ascii=False,indent=2)+'\n')
    assert sum(p.stat().st_size for p in (LIB/'validation').rglob('*') if p.is_file())<20*1024**2
    for row in rows:
        p=ROOT/row['path'] if row['scope']=='repository' else Path(row['path']);assert sha(p)==row['sha256']
    print(json.dumps({'files':len(rows),'repository_files':len(set(repository)),'largest_file_bytes':report['largest_repository_file']['bytes'],'validation_bytes':sum(p.stat().st_size for p in (LIB/'validation').rglob('*') if p.is_file())}))
if __name__=='__main__':main()
