#!/usr/bin/env python3
"""Inventory the final layout proposal, with external evidence kept outside Git."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from urllib.request import Request, urlopen
import hashlib, json

ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/map-layout-021'
EV=Path('/Users/chengzeyuan/SilkRoadEvidence/map-layout-021')
def read(p):return json.loads(p.read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def main():
    capture=read(EV/'final-metadata/layout-capture-report.json')
    assert capture['placements_sha256']==sha(LIB/'placements.json')
    assert capture['script_sha256']==sha(ROOT/'tools/lowpoly/layout_021_preview.gd')
    assert len(capture['captures'])==44 and capture['inputs_stable'] and not capture['errors']
    for row in capture['captures']:
        assert sha(Path(row['preview']))==row['sha256']
        assert sha(Path(row['raw']))==row['raw_sha256']
    baseline=read(EV/'baseline/input-start.json')['source_sha256']
    assert all((ROOT/p).is_file() and sha(ROOT/p)==h for p,h in baseline.items())
    # Recheck final resources, keeping actual browser observations separate.
    qa=read(LIB/'validation/gallery-qa.json')
    def check(row):
        with urlopen(Request('http://127.0.0.1:8879/map-layout-021/'+row['path'],method='HEAD'),timeout=8) as r:
            return {'path':row['path'],'status':r.status,'bytes':int(r.headers.get('Content-Length',0))}
    qa['resources']=list(ThreadPoolExecutor(max_workers=8).map(check,qa['resources']))
    assert all(r['status']==200 and r['bytes']>0 for r in qa['resources'])
    qa['final_browser_observed']={'viewport':[1280,720],'horizontal_overflow':False,'selected_view':'central','full_size_link_matches_selected_image':True,'screenshot':str(EV/'gallery-qa/final-page.png')}
    qa['page_sha256']=sha(LIB/'index.html')
    qa['final_capture_report_sha256']=sha(EV/'final-metadata/layout-capture-report.json')
    write(LIB/'validation/gallery-qa.json',qa)
    files=sorted(p for p in LIB.rglob('*') if p.is_file() and p.name!='evidence-manifest.json')
    files+=sorted((ROOT/'tools/lowpoly').glob('layout_021*'))
    files+=[ROOT/'docs/reports/task-map-layout-021.md',ROOT/'docs/CURRENT-STATE.md']
    records=[{'path':str(p.relative_to(ROOT)),'bytes':p.stat().st_size,'sha256':sha(p)} for p in files]
    external=[EV/'baseline/input-start.json',EV/'geography-candidates.json',EV/'final-metadata/layout-capture-report.json',EV/'final-metadata-capture.log',EV/'interactive.log']
    external+=sorted((EV/'final-metadata/captures').glob('*.png'))
    external+=sorted((EV/'gallery-qa').glob('*.png'))
    external+=[EV/'final-city-contact-1.jpg',EV/'final-city-contact-2.jpg',EV/'final/layout-capture-report.json']
    ext=[{'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)} for p in external]
    assert len(records)==len({r['path'] for r in records})
    manifest={'task':'TASK-MAP-LAYOUT-021','status':'reviewable-layout-study','repository_files':records,'external_evidence':ext,'repository_bytes':sum(r['bytes'] for r in records),'existing_files_unchanged':len(baseline),'production_integrated':False,'scope_limits':['4 explicit coast reservations remain','Some landmark base edges need continuous terrain blending','Static visibility only; no full dynamic/performance pass','Native interaction manually untested: Mac locked; engine startup succeeded'],'note':'Final 44 images bind final-metadata capture. Earlier city contact sheets are historical visual checks; recapture-image-delta.json records differences. Manifest excludes itself.'}
    out=LIB/'validation/evidence-manifest.json';write(out,manifest)
    for r in records:assert sha(ROOT/r['path'])==r['sha256']
    for r in ext:assert sha(Path(r['path']))==r['sha256']
    print(json.dumps({'repository_files':len(records),'repository_MB':round(manifest['repository_bytes']/1e6,2),'external_files':len(ext),'unchanged_inputs':len(baseline),'manifest_sha256':sha(out)}))
if __name__=='__main__':main()
