#!/usr/bin/env python3
"""Read final GLB bytes independently of Blender. No image-derived QA claims."""
import argparse
import json
from pathlib import Path
import numpy as np
from library_018_audit import GLB, sha

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT/'docs/design/city-library-019'


def inspect(path):
    g = GLB(path)
    vertices, triangles, surfaces, mesh_count = [],0,0,0
    material_ids = set()
    minimum_area = float('inf')
    def visit(index,parent,ancestors):
        nonlocal triangles,surfaces,mesh_count,minimum_area
        assert index not in ancestors, 'Node cycle'
        node = g.doc['nodes'][index]
        m = parent @ g.transform(node)
        assert np.isfinite(m).all() and np.linalg.det(m[:3,:3]) > 0
        assert np.allclose(np.linalg.norm(m[:3,:3],axis=0),1,atol=1e-5), 'Scale not applied'
        if 'mesh' in node:
            mesh_count += 1
            assert not any(w in node.get('name','').lower() for w in ('camera','studio','light'))
            for p in g.doc['meshes'][node['mesh']]['primitives']:
                surfaces += 1
                assert p.get('mode',4)==4
                v = g.accessor(p['attributes']['POSITION'])
                normals = g.accessor(p['attributes']['NORMAL'])
                assert len(v)==len(normals) and np.allclose(np.linalg.norm(normals,axis=1),1,atol=.015)
                for a in p['attributes'].values(): g.accessor(a)
                idx = g.accessor(p['indices']).reshape(-1) if 'indices' in p else np.arange(len(v))
                assert len(idx)%3==0 and idx.min()>=0 and idx.max()<len(v)
                v = (np.column_stack((v,np.ones(len(v)))) @ m.T)[:,:3]
                t = v[idx.reshape(-1,3)]
                areas = np.linalg.norm(np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]),axis=1)
                assert (areas>1e-10).all(), f'{node.get("name")}: {int((areas<=1e-10).sum())} degenerate triangles'
                minimum_area = min(minimum_area,float(areas.min()))
                triangles += len(t)
                vertices.append(v)
                material_ids.add(p['material'])
        for child in node.get('children',[]): visit(child,m,ancestors|{index})
    for node in g.doc['scenes'][g.doc.get('scene',0)]['nodes']:
        visit(node,np.eye(4),set())
    vertices = np.concatenate(vertices)
    low,high = vertices.min(axis=0),vertices.max(axis=0)
    assert abs(low[1])<1e-5 and (high-low>.01).all(), f'Invalid ground/bounds {low} {high}'
    assert surfaces <= 8, f'{surfaces} surfaces'
    for i in material_ids:
        mat = g.doc['materials'][i]
        assert mat.get('alphaMode','OPAQUE')=='OPAQUE'
        color = mat.get('pbrMetallicRoughness',{}).get('baseColorFactor',[1,1,1,1])
        assert np.isfinite(color).all() and all(0<=v<=1 for v in color)
    assert not g.doc.get('textures'), 'Unexpected texture dependency'
    return {'triangles':triangles,'primitives':surfaces,'meshes':mesh_count,'materials':len(material_ids),
        'bounds':{'min':low.tolist(),'max':high.tolist(),'size':(high-low).tolist()},
        'minimum_triangle_area2':minimum_area}


def main():
    p=argparse.ArgumentParser();p.add_argument('--partial',action='store_true');args=p.parse_args()
    records = [a for f in LIB.glob('*-catalog.json') for a in json.loads(f.read_text())['assets']]
    assets,errors=[],[]
    for a in records:
        try:
            path=LIB/a['glb'];info=inspect(path)
            old_path=ROOT/f'assets/game/lowpoly/cities/{a["id"]}.glb'
            old=inspect(old_path)
            assert sha(path)==a['sha256'], 'Authoring manifest stale'
            assert sha(old_path)==a['frame']['production_glb_sha256'],'Production model changed'
            assert info['triangles']==a['triangles'],'Blender and GLB triangles differ'
            lo=np.array(info['bounds']['min']);hi=np.array(info['bounds']['max'])
            origlo=np.array(old['bounds']['min']);orighi=np.array(old['bounds']['max'])
            outward=np.maximum(np.maximum(origlo-lo,hi-orighi),0)[[0,2]]
            assert max(info['bounds']['size'][0],info['bounds']['size'][2])<=2.3,'City width exceeds library limit'
            assert info['bounds']['size'][1]<=1.5,'City height exceeds library limit'
            assets.append({**a,**info,'sha256':sha(path),'bytes':path.stat().st_size,
                'before':{'sha256':sha(old_path),**old},
                'horizontal_outward_expansion_xz':outward.tolist(),
                'requires_footprint_review_before_integration':bool((outward>.015).any()),
                'origin_contract':'Frozen production builder factor/shift, identity export transforms, Y bottom zero; not refitted to new bounds.'})
        except Exception as e: errors.append({'id':a['id'],'error':str(e)})
    if not args.partial and (len(assets)!=16 or len({a['id'] for a in assets})!=16): errors.append({'error':'Expected sixteen unique valid cities'})
    result={'task':'TASK-CITY-LIBRARY-019','auditor_sha256':sha(__file__),'glb_reader_sha256':sha(Path(__file__).with_name('library_018_audit.py')),
        'assets':assets,'errors':errors,'model_count':len(assets),'total_triangles':sum(a['triangles'] for a in assets),
        'before_triangles':sum(a['before']['triangles'] for a in assets),'total_surfaces':sum(a['primitives'] for a in assets),
        'total_glb_bytes':sum(a['bytes'] for a in assets)}
    (LIB/'validation/geometry-audit.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='assets'},ensure_ascii=False))
    return bool(errors)

if __name__=='__main__': raise SystemExit(main())
