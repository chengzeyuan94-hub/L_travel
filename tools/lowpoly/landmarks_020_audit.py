#!/usr/bin/env python3
"""Independent audit of the exported library (no Blender dependency).

Reads final GLB bytes, not authoring-side geometry counters. Requires numpy.
Run after authoring finishes; evidence goes outside the repository by default.
"""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / 'docs/design/landmark-library-020'
EXPECTED = {'trees': 5, 'rocks': 3, 'greenery': 4, 'clouds': 3,
            'mountains': 3, 'snow-mountains': 3, 'hills': 3}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class GLB:
    def __init__(self, path):
        raw = Path(path).read_bytes()
        magic, version, length = struct.unpack_from('<4sII', raw)
        assert magic == b'glTF' and version == 2 and length == len(raw)
        chunks, offset = {}, 12
        while offset < len(raw):
            size, kind = struct.unpack_from('<I4s', raw, offset)
            offset += 8
            assert offset + size <= len(raw)
            chunks[kind] = raw[offset:offset+size]
            offset += size
        self.doc = json.loads(chunks[b'JSON'])
        self.bin = chunks[b'BIN\0']
        assert not any('uri' in b for b in self.doc.get('buffers', [])), 'External buffer'
        assert not any('uri' in b for b in self.doc.get('images', [])), 'External image'
        assert not self.doc.get('cameras'), 'Camera in model export'
        assert not self.doc.get('animations'), 'Unexpected animation'
        assert not self.doc.get('extensions', {}).get('KHR_lights_punctual'), 'Light in model export'

    def accessor(self, index):
        a = self.doc['accessors'][index]
        assert 'sparse' not in a
        v = self.doc['bufferViews'][a['bufferView']]
        width = {'SCALAR':1, 'VEC2':2, 'VEC3':3, 'VEC4':4}[a['type']]
        dtype = np.dtype({5120:'i1', 5121:'u1', 5122:'<i2', 5123:'<u2', 5125:'<u4', 5126:'<f4'}[a['componentType']])
        offset = v.get('byteOffset', 0)+a.get('byteOffset', 0)
        stride = v.get('byteStride', width*dtype.itemsize)
        assert offset+(a['count']-1)*stride+width*dtype.itemsize <= len(self.bin)
        values = np.ndarray((a['count'], width), dtype=dtype, buffer=self.bin,
                            offset=offset, strides=(stride, dtype.itemsize)).copy()
        if a.get('normalized'):
            values = np.maximum(-1, values.astype(float)/np.iinfo(dtype).max)
        assert np.isfinite(values).all(), 'Non-finite attribute'
        return values

    @staticmethod
    def transform(n):
        if 'matrix' in n:
            return np.array(n['matrix'], dtype=float).reshape(4, 4, order='F')
        x,y,z,w = n.get('rotation', [0,0,0,1])
        r = np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
                      [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                      [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])
        m = np.eye(4)
        m[:3,:3] = r @ np.diag(n.get('scale',[1,1,1]))
        m[:3,3] = n.get('translation',[0,0,0])
        return m

    def audit(self):
        points, triangle_count, primitives, mesh_count = [], 0, 0, 0
        materials, names = set(), []
        def visit(index, parent, ancestors):
            nonlocal triangle_count, primitives, mesh_count
            assert index not in ancestors, 'Node cycle'
            n = self.doc['nodes'][index]
            m = parent @ self.transform(n)
            assert np.isfinite(m).all() and np.linalg.det(m[:3,:3]) > 0
            assert np.allclose(np.linalg.norm(m[:3,:3], axis=0),1,atol=1e-5), 'Unapplied scale'
            name = n.get('name','')
            assert not any(word in name.lower() for word in ['studio','camera']), name
            if 'mesh' in n:
                mesh_count += 1
                names.append(name)
                for p in self.doc['meshes'][n['mesh']]['primitives']:
                    assert p.get('mode',4) == 4, 'Not triangles'
                    pos = self.accessor(p['attributes']['POSITION']).astype(float)
                    normal = self.accessor(p['attributes']['NORMAL'])
                    assert len(pos) == len(normal) and np.allclose(np.linalg.norm(normal,axis=1),1,atol=.015)
                    for attr in p['attributes'].values():
                        self.accessor(attr)
                    idx = self.accessor(p['indices']).reshape(-1) if 'indices' in p else np.arange(len(pos))
                    assert len(idx)%3 == 0 and idx.min() >= 0 and idx.max() < len(pos)
                    idx = idx.reshape(-1,3)
                    world = (np.column_stack((pos,np.ones(len(pos)))) @ m.T)[:,:3]
                    tri = world[idx]
                    area2 = np.linalg.norm(np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]),axis=1)
                    assert (area2 > 1e-10).all(), f'Degenerate triangles in {name}: {int((area2 <= 1e-10).sum())}'
                    points.append(world)
                    triangle_count += len(idx)
                    primitives += 1
                    materials.add(p.get('material',-1))
            for child in n.get('children',[]):
                visit(child,m,ancestors|{index})
        for node in self.doc['scenes'][self.doc.get('scene',0)]['nodes']:
            visit(node,np.eye(4),set())
        all_points = np.concatenate(points)
        low, high = all_points.min(axis=0), all_points.max(axis=0)
        assert abs(low[1]) < 1e-5, f'Bottom Y {low[1]}'
        full_center = (low[[0,2]]+high[[0,2]])/2
        feet = all_points[all_points[:,1] <= low[1]+1e-6][:,[0,2]]
        foot_center = (feet.min(axis=0)+feet.max(axis=0))/2
        # A natural leaning tree may intentionally be centered on its root,
        # while another model uses the full horizontal bounds. Both are valid
        # independent asset origins; studio translations satisfy neither.
        if np.allclose(full_center,0,atol=1e-5):
            origin_mode = 'full-horizontal-bounds-center'
        else:
            assert np.allclose(foot_center,0,atol=1e-5), 'Origin matches neither full bounds nor actual ground-contact bounds'
            origin_mode = 'ground-contact-bounds-center'
        assert (high-low > .01).all(), 'Flat or empty model'
        return dict(triangles=triangle_count, primitives=primitives, meshes=mesh_count,
                    materials=len(materials), bounds={'min':low.tolist(),'max':high.tolist(),'size':(high-low).tolist()},
                    mesh_names=names, origin_mode=origin_mode,
                    ground_contact_center=foot_center.tolist())


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--partial',action='store_true')
    args=parser.parse_args()
    metadata=json.loads((LIBRARY/'geography-plan.json').read_text())
    expected={a['id'] for a in metadata['assets']}
    assets,errors=[],[]
    orientation_checks=[]
    for path in sorted((LIBRARY/'exports').glob('*.glb')):
        try:
            glb=GLB(path)
            info=glb.audit()
            assert path.stem in expected,'Unexpected asset'
            assert info['materials']==info['primitives']==info['meshes'] and 1<=info['materials']<=10
            assert info['origin_mode']=='full-horizontal-bounds-center'
            assert max(info['bounds']['size'][0],info['bounds']['size'][2])<=5.5001
            # Regression for real material patches that previously flipped
            # during per-bucket Blender normal recalculation. These specific
            # materials contain upper terrain only, with bases in other slots.
            upward_materials={'lake_albano':{'rock','grass'},
                              'shamsan_crater':{'lava_light','lava'}}.get(path.stem,set())
            counts={name:[0,0] for name in upward_materials}
            def inspect_orientation(index,parent):
                node=glb.doc['nodes'][index];m=parent@glb.transform(node)
                if 'mesh' in node:
                    for primitive in glb.doc['meshes'][node['mesh']]['primitives']:
                        mat=glb.doc['materials'][primitive['material']].get('name','')
                        if mat not in counts:continue
                        positions=glb.accessor(primitive['attributes']['POSITION']).astype(float)
                        world=(np.column_stack((positions,np.ones(len(positions))))@m.T)[:,:3]
                        indices=glb.accessor(primitive['indices']).reshape(-1,3)
                        t=world[indices];area=np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0])[:,1]
                        counts[mat][0]+=int((area>1e-10).sum());counts[mat][1]+=int((area < -1e-10).sum())
                for child in node.get('children',[]):inspect_orientation(child,m)
            if counts:
                for node in glb.doc['scenes'][glb.doc.get('scene',0)]['nodes']:inspect_orientation(node,np.eye(4))
                for mat,(up,down) in counts.items():
                    assert up>100 and down==0,(path.stem,mat,'upper surface normal reversal',up,down)
                    orientation_checks.append({'id':path.stem,'material':mat,'upward_triangles':up,'downward_triangles':down,'passed':True})
            assets.append(dict(id=path.stem,glb=str(path.relative_to(LIBRARY)),sha256=sha(path),bytes=path.stat().st_size,**info))
        except Exception as error:errors.append({'id':path.stem,'error':str(error)})
    if not args.partial and {a['id'] for a in assets}!=expected:errors.append({'error':'Missing or unexpected assets','valid':len(assets),'expected':33})
    result={'task':'TASK-LANDMARK-LIBRARY-020','auditor_sha256':sha(__file__),'geography_plan_sha256':sha(LIBRARY/'geography-plan.json'),
            'assets':assets,'errors':errors,'terrain_orientation_checks':orientation_checks,'partial':args.partial,'model_count':len(assets),
            'total_triangles':sum(a['triangles'] for a in assets),'total_surfaces':sum(a['primitives'] for a in assets),'total_glb_bytes':sum(a['bytes'] for a in assets)}
    (LIBRARY/'validation/geometry-audit.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='assets'},ensure_ascii=False))
    return bool(errors)

if __name__=='__main__':raise SystemExit(main())
