#!/usr/bin/env python3
"""Reconcile final GLBs, editable sources, geography and real engine images."""
import argparse,hashlib,json
from collections import Counter
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/landmark-library-020'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p):return json.loads(Path(p).read_text())
def write(p,r):Path(p).write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n')

def main():
    p=argparse.ArgumentParser();p.add_argument('--evidence',type=Path,required=True);p.add_argument('--studio',type=Path,required=True);args=p.parse_args();ev=args.evidence
    audit=read(LIB/'validation/geometry-audit.json');assert audit['model_count']==33 and not audit['errors'] and not audit['partial']
    assert audit['auditor_sha256']==sha(ROOT/'tools/lowpoly/landmarks_020_audit.py')
    geo=read(LIB/'geography-plan.json');meta={a['id']:a for a in geo['assets']}
    counts=Counter(a['city_id'] for a in geo['assets']);assert counts.pop('himalaya')==1 and len(counts)==16 and set(counts.values())=={2}
    assert meta['everest']['scope']=='cross-regional' and meta['mount_fuji']['scope']=='regional'
    assert geo['status']=='geography-verified' and all(a['sources'] and a['geography_note'] for a in meta.values())
    assert audit['geography_plan_sha256']==sha(LIB/'geography-plan.json')
    models={a['id']:a for a in audit['assets']};assert set(meta)==set(models)
    frames=[];authored={}
    for group in ['east','south','west']:
        c=read(LIB/f'{group}-catalog.json')
        assert sha(LIB/'geography-plan.json')==c['geography_plan_sha256']
        for path,digest in c['source_sha256'].items():assert sha(ROOT/path)==digest,path+' changed after build'
        assert sha(LIB/f'source/{group}.blend')==c['blend_sha256']
        frames.append({'group':group,'source_sha256':c['source_sha256'],'blend_sha256':c['blend_sha256']})
        for a in c['assets']:
            assert a['id'] not in authored;authored[a['id']]=a
    assert set(authored)==set(models)
    studio=read(args.studio);assert not studio['errors'] and studio['renderer']=='forward_plus' and studio['asset_count']==33 and not studio['partial']
    assert studio['capture_script_sha256']==sha(ROOT/'tools/lowpoly/landmarks_020_capture.gd')
    captures={a['id']:a for a in studio['assets']};assert set(captures)==set(models) and len(studio['assets'])==33
    for aid,a in models.items():
        c=captures[aid];author=authored[aid]
        assert sha(LIB/a['glb'])==a['sha256']==c['sha256']==author['sha256']
        assert author['triangles']==a['triangles'] and author['meshes']==a['meshes']
        assert c['inputs_stable'] and c['surfaces']==a['primitives'] and c['mesh_count']==a['meshes']
        assert {v['view'] for v in c['captures']}=={'three-quarter','side','top'} and len(c['captures'])==3
        for shot in c['captures']:assert sha(shot['preview'])==shot['sha256'] and Path(shot['raw']).is_file()
    baseline=read(ev/'baseline/input-start.json')
    changed=[path for path,digest in baseline['source_sha256'].items() if not (ROOT/path).is_file() or sha(ROOT/path)!=digest]
    assert not changed,changed
    source=read(LIB/'validation/blender-source-report.json');imp=read(LIB/'validation/godot-import-report.json')
    assert source['checker_sha256']==sha(ROOT/'tools/lowpoly/landmarks_020_source_check.py')
    assert imp['script_sha256']==sha(ROOT/'tools/lowpoly/landmarks_020_import_check.gd') and imp['geometry_audit_sha256']==sha(LIB/'validation/geometry-audit.json')
    assert not source['errors'] and source['asset_count']==33 and not imp['errors'] and imp['asset_count']==33
    for a in imp['assets']:assert a['sha256_start']==a['sha256_end']==models[a['id']]['sha256']
    for a in source['assets']:assert a['sha256']==sha(a['source']) and a['triangles']==models[a['id']]['triangles']
    concepts=sorted((LIB/'concepts').glob('*.png'));assert len(concepts)==9
    assert {str(p.relative_to(LIB)) for p in concepts}=={a['concept'] for a in meta.values()}
    write(LIB/'validation/production-input-freeze.json',{'baseline_file':str(ev/'baseline/input-start.json'),'baseline_sha256':sha(ev/'baseline/input-start.json'),'existing_input_count':len(baseline['source_sha256']),'changed_existing_inputs':changed,'note':'New independent scenery and tool files are audited separately. Existing 018/019 tooling and production assets are unchanged. No production replacement or new full game gate is claimed.'})
    studio['source_report']={'path':str(args.studio),'sha256':sha(args.studio)};studio['source_frames']=frames
    write(LIB/'validation/studio-capture-report.json',studio)
    summary={'task':'TASK-LANDMARK-LIBRARY-020','models':33,'city_nodes':16,'per_node':2,'cross_regional_extra':1,'concept_sheets':9,'editable_sources':3,'triangles':audit['total_triangles'],'surfaces':audit['total_surfaces'],'glb_bytes':audit['total_glb_bytes'],'engine_images':99,'unchanged_existing_inputs':len(baseline['source_sha256']),'import_checks':{'passed':imp['passed'],'total':imp['total']},'production_integrated':False}
    write(LIB/'validation/summary.json',summary);print(json.dumps(summary,ensure_ascii=False))

if __name__=='__main__':main()
