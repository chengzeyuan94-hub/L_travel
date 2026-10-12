#!/usr/bin/env python3
"""Bind the final three-asset study, studio views and map comparisons."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib, json, shutil

ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/terrain-transition-022'
EV=Path('/Users/chengzeyuan/SilkRoadEvidence/terrain-transition-022')
def read(p): return json.loads(Path(p).read_text())
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,v): Path(p).write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def info(p): return {'sha256':sha(p),'bytes':Path(p).stat().st_size}

def main():
    catalog=read(LIB/'asset-catalog.json')
    assert sha(LIB/'source/transition-models.blend')==catalog['blend_sha256']
    reopened=read(EV/'source-reopen-validation.json')
    assert reopened['pass'] and reopened['blend_sha256']==catalog['blend_sha256']
    glb=read(EV/'glb-validation.json');assert glb['pass']
    for asset,check in zip(catalog['assets'],glb['checks']):
        assert asset['id']==check['id'] and sha(LIB/asset['glb'])==asset['sha256']==check['glb_sha256']
        assert sha(LIB/asset['fit_json'])==asset['fit_sha256']
    studio_path=EV/'studio-wide/godot-capture-report.json';studio=read(studio_path)
    assert studio['asset_count']==3 and not studio['errors']
    assert studio['capture_script_sha256']==sha(ROOT/'tools/lowpoly/transition_022_studio.gd')
    raw_files=[]
    for a in studio['assets']:
        assert a['inputs_stable'] and sha(a['glb'])==a['sha256'] and len(a['captures'])==3
        for c in a['captures']:
            assert sha(c['preview'])==c['sha256']
            raw_files.append(Path(c['raw']))
    map_path=EV/'wide-map/transition-capture-report.json';capture=read(map_path)
    assert capture['inputs_stable'] and len(capture['captures'])==16 and not capture['errors']
    for c in capture['captures']:
        assert sha(c['preview'])==c['sha256'] and sha(c['raw'])==c['raw_sha256']
        raw_files.append(Path(c['raw']))
    for src,dst in [('source-reopen-validation.json','source-reopen.json'),('glb-validation.json','glb.json'),
                    ('wide-closure-check.json','source-closure.json'),('wide-source-visual-review.json','source-visual-review.json'),
                    ('studio-wide/godot-capture-report.json','studio-report.json')]:
        shutil.copyfile(EV/src,LIB/'validation'/dst)
    existing=read(EV/'input-start.json')['source_sha256']
    assert all((ROOT/p).is_file() and sha(ROOT/p)==h for p,h in existing.items())
    local=list(LIB.rglob('*'))+list((ROOT/'tools/lowpoly').glob('transition_022*'))+[
        ROOT/'docs/reports/task-terrain-transition-022.md',ROOT/'docs/CURRENT-STATE.md']
    local=sorted({p for p in local if p.is_file() and p.name not in ['manifest.json','.DS_Store']})
    external=raw_files+[map_path,studio_path,EV/'input-start.json',EV/'reopen-022.py',EV/'verify-glb.py',EV/'gallery-viewport.png']
    write(LIB/'manifest.json',{
        'task':'TASK-TERRAIN-TRANSITION-022','created_at_utc':datetime.now(timezone.utc).isoformat(),
        'status':'three source variants; Everest/dunes source form usable; map blending and river ends unresolved',
        'production_integrated':False,'source_models':3,'other_assets_recipe_only':30,
        'studio_images':9,'map_images':16,'unchanged_existing_inputs':len(existing),
        'files':{str(p.relative_to(ROOT)):info(p) for p in local},
        'external_evidence':{str(p):info(p) for p in external},
        'limitations':['Source-model acceptance is separate from map blending acceptance.',
                       'No full gameplay, dynamic occlusion, performance or manual native input pass.',
                       'All earlier trial/pass evidence is superseded; trial2 had stale placement inputs.',
                       'The browser full-page stitch was not used as visual evidence; viewport screenshot and DOM checks are retained.']})
    print(json.dumps({'local_files':len(local),'external_files':len(external),'unchanged_inputs':len(existing),'raw_images':len(raw_files)}))

if __name__=='__main__': main()
