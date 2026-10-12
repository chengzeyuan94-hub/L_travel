#!/usr/bin/env python3
"""Bind final model bytes to their engine renders and preserve the game baseline."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'docs/design/terrain-library-018'

def read(path): return json.loads(Path(path).read_text())
def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def write(path,data): Path(path).write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--audit',type=Path,required=True)
    p.add_argument('--capture',type=Path,action='append',required=True)
    p.add_argument('--baseline',type=Path,required=True)
    args=p.parse_args()
    validation=LIB/'validation';validation.mkdir(exist_ok=True)
    geometry=read(args.audit)
    assert not geometry['errors'] and geometry['model_count']==24
    captures={}
    for path in args.capture:
        r=read(path)
        assert not r['errors'] and r['renderer']=='forward_plus'
        for a in r['assets']:
            captures[a['id']]=a
    assert set(captures)=={a['id'] for a in geometry['assets']}
    for a in geometry['assets']:
        c=captures[a['id']]
        assert sha(LIB/a['glb'])==a['sha256']==c['sha256'],a['id']+' stale render'
        assert c['inputs_stable'] and c['mesh_count']==a['meshes'] and c['surfaces']==a['primitives']
        assert {v['view'] for v in c['captures']}=={'three-quarter','side','top'}
        for v in c['captures']:
            assert sha(v['preview'])==v['sha256'],v['preview']+' stale image'
    before=read(args.baseline)['source_sha256']
    changed=[path for path,digest in before.items() if not (ROOT/path).is_file() or sha(ROOT/path)!=digest]
    assert not changed,changed
    baseline={'baseline_file':str(args.baseline),'baseline_sha256':sha(args.baseline),
              'existing_input_count':len(before),'changed_existing_inputs':changed,
              'note':'Compares existing game/gate inputs at start of this task; new library/tools are audited separately. No new full game gate is claimed.'}
    combined={'task':'TASK-TERRAIN-LIBRARY-018','renderer':'forward_plus','asset_count':len(captures),
              'image_count':sum(len(a['captures']) for a in captures.values()),
              'source_reports':[{'path':str(path),'sha256':sha(path)} for path in args.capture],
              'all_current_glb_hashes_match_captured_inputs':True,
              'assets':[captures[k] for k in sorted(captures)]}
    write(validation/'geometry-audit.json',geometry)
    write(validation/'godot-capture-report.json',combined)
    write(validation/'production-input-freeze.json',baseline)
    print(json.dumps({'models':len(captures),'rendered_views':combined['image_count'],
                      'triangles':geometry['total_triangles'],'glb_bytes':geometry['total_glb_bytes'],
                      'unchanged_existing_inputs':len(before)}))

if __name__=='__main__': main()
