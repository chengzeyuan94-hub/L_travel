#!/usr/bin/env python3
"""Bind final exported models, saved Blender sources and two rendering contexts."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/city-library-019'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p):return json.loads(Path(p).read_text())
def write(p,r):Path(p).write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n')

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--evidence',type=Path,required=True)
    p.add_argument('--studio',action='append',type=Path,required=True)
    args=p.parse_args();ev=args.evidence
    audit=read(LIB/'validation/geometry-audit.json')
    assert audit['model_count']==16 and not audit['errors']
    models={a['id']:a for a in audit['assets']}
    sources=[]
    for group in ['east','caravan','landmarks']:
        catalog=read(LIB/f'{group}-catalog.json')
        for path,digest in catalog['source_sha256'].items():assert sha(ROOT/path)==digest,path+' changed after build'
        assert sha(LIB/f'source/{group}.blend')==catalog['blend_sha256']
        sources.append({'group':group,'source_sha256':catalog['source_sha256'],'blend_sha256':catalog['blend_sha256']})
    captures={}
    for path in args.studio:
        r=read(path);assert not r['errors'] and r['renderer']=='forward_plus'
        assert r['capture_script_sha256']==sha(ROOT/'tools/lowpoly/cities_019_capture.gd')
        for a in r['assets']:captures[a['id']]=a
    before=read(ev/'studio-before/godot-capture-report.json')
    old={a['id']:a for a in before['assets']}
    assert set(captures)==set(models)==set(old)
    for cid,a in models.items():
        c=captures[cid];b=old[cid]
        assert sha(LIB/a['glb'])==a['sha256']==c['sha256']
        assert a['before']['sha256']==b['sha256']
        assert c['inputs_stable'] and b['inputs_stable']
        assert c['surfaces']==a['primitives'] and c['mesh_count']==a['meshes']
        assert {v['view'] for v in c['captures']}=={'three-quarter','side','top'}
        for shot in c['captures']+b['captures']:assert sha(shot['preview'])==shot['sha256']
        for view in ['three-quarter','side','top']:
            new=next(v for v in c['captures'] if v['view']==view)
            oldshot=next(v for v in b['captures'] if v['view']==view)
            assert new['camera_position']==oldshot['camera_position'] and new['camera_size']==oldshot['camera_size']
    maps=read(ev/'map/map-capture-report.json')
    assert not maps['errors'] and maps['inputs_stable'] and maps['renderer']=='gl_compatibility'
    assert maps['script_sha256']==sha(ROOT/'tools/lowpoly/cities_019_map_capture.gd')
    assert len(maps['captures'])==64 and set(maps['models'])==set(models)
    for cid,a in models.items():
        assert maps['models'][cid]['after_sha256']==a['sha256']
        assert maps['models'][cid]['before_sha256']==a['before']['sha256']
        for zoom in [2.6,4.2]:
            pair=[r for r in maps['captures'] if r['id']==cid and r['zoom']==zoom]
            assert len(pair)==2 and {r['phase'] for r in pair}=={'before','after'}
            for key in ['camera','camera_transform','camera_fov','crop','root_size','board_viewport_size']:
                assert pair[0][key]==pair[1][key],(cid,zoom,key)
            for r in pair:assert sha(r['preview'])==r['sha256']
    baseline=read(ev/'baseline/input-start.json')
    changed=[path for path,digest in baseline['source_sha256'].items() if not (ROOT/path).is_file() or sha(ROOT/path)!=digest]
    assert not changed,changed
    sourcecheck=read(LIB/'validation/blender-source-report.json')
    importcheck=read(LIB/'validation/godot-import-report.json')
    assert not sourcecheck['errors'] and sourcecheck['city_count']==16
    assert not importcheck['errors'] and importcheck['asset_count']==16
    for a in importcheck['assets']:assert a['sha256_start']==a['sha256_end']==models[a['id']]['sha256']
    write(LIB/'validation/production-input-freeze.json',{'baseline_file':str(ev/'baseline/input-start.json'),
        'baseline_sha256':sha(ev/'baseline/input-start.json'),'existing_input_count':len(baseline['source_sha256']),
        'changed_existing_inputs':changed,'note':'New independent city library and tool sources audited separately; no production replacement or new full game gate is claimed.'})
    write(LIB/'validation/studio-capture-report.json',{'task':'TASK-CITY-LIBRARY-019','assets':list(captures.values()),
        'before_source':str(ev/'studio-before/godot-capture-report.json'),'before_sha256':sha(ev/'studio-before/godot-capture-report.json'),
        'sources':[{'path':str(path),'sha256':sha(path)} for path in args.studio],
        'model_count':16,'images_before':48,'images_after':48,'fixed_camera_pairs':48,'source_frames':sources})
    write(LIB/'validation/map-capture-report.json',maps)
    summary={'task':'TASK-CITY-LIBRARY-019','models':16,'concept_sheets':3,'editable_sources':3,
        'triangles_before':audit['before_triangles'],'triangles_after':audit['total_triangles'],
        'surfaces_after':audit['total_surfaces'],'glb_bytes':audit['total_glb_bytes'],
        'studio_comparison_pairs':48,'map_comparison_pairs':32,'unchanged_existing_inputs':len(baseline['source_sha256']),
        'import_checks':{'passed':importcheck['passed'],'total':importcheck['total']},
        'production_integrated':False}
    write(LIB/'validation/summary.json',summary)
    print(json.dumps(summary,ensure_ascii=False))

if __name__=='__main__':main()
