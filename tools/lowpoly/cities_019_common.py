#!/usr/bin/env python3
"""Isolated city-library authoring. Never exports into the production city folder.

Blender --background --python tools/lowpoly/cities_019_common.py -- --group all
Each city retains the production generator's scale and origin, rather than
refitting a detailed model to a new bounding box and silently shrinking it.
"""
import argparse
import hashlib
import importlib
import json
import math
from pathlib import Path
import sys

import bpy
import bmesh

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_cities as legacy

ROOT = HERE.parents[1]
LIB = ROOT / 'docs/design/city-library-019'
GROUPS = {'east': 'cities_019_east', 'caravan': 'cities_019_caravan',
          'landmarks': 'cities_019_landmarks'}
CONCEPTS = {'east': 'east-asian.png', 'caravan': 'caravan-cities.png',
            'landmarks': 'landmark-cities.png'}


class Geometry019(legacy.Geometry):
    """Existing authoring API, with thick curved eaves available to every city."""
    def east_roof(self, x, y, z, w, d, h, mat='teal'):
        self.quanzhou_roof(x, y, z, w, d, h, mat)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def bounds(g):
    vertices = [v for vv, _ in g.buckets.values() for v in vv]
    return ([min(v[i] for v in vertices) for i in range(3)],
            [max(v[i] for v in vertices) for i in range(3)])


def original_frame(cid):
    g = legacy.Geometry(cid)
    legacy.BUILDERS[cid](g)
    lo, hi = bounds(g)
    factor = min(2.1 / max(hi[0]-lo[0], hi[1]-lo[1]), 1.4/(hi[2]-lo[2]))
    shift = [(lo[0]+hi[0])/2, (lo[1]+hi[1])/2, lo[2]]
    if cid == 'quanzhou':
        factor, shift = 2.1/1.9, [0,0,0]
    return {'factor': factor, 'shift': shift, 'source_bounds': {'min': lo, 'max': hi},
            'production_glb_sha256': sha(ROOT/f'assets/game/lowpoly/cities/{cid}.glb')}


def build(cid, builder, materials, scene):
    frame = original_frame(cid)
    g = Geometry019(cid)
    builder(g)
    assert len(g.buckets) <= 8, (cid, list(g.buckets))
    lo, hi = bounds(g)
    assert abs(lo[2]) < 1e-7, (cid, 'base Z must remain zero', lo)
    factor, shift = frame['factor'], frame['shift']
    collection = bpy.data.collections.new(cid)
    scene.collection.children.link(collection)
    objects = []
    for material, (vertices, faces) in sorted(g.buckets.items()):
        vertices = [tuple((v[i]-shift[i])*factor for i in range(3)) for v in vertices]
        mesh = bpy.data.meshes.new(f'{cid}_{material}')
        mesh.from_pydata(vertices, [], faces)
        bm = bmesh.new()
        bm.from_mesh(mesh)
        bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
        bm.to_mesh(mesh)
        bm.free()
        mesh.materials.append(materials[material])
        mesh.update()
        obj = bpy.data.objects.new(f'{cid}_{material}', mesh)
        collection.objects.link(obj)
        obj['city_id'] = cid
        obj['asset_kind'] = 'silkroad_city_library_019'
        obj['frame_factor'] = factor
        obj['frame_shift'] = shift
        for poly in mesh.polygons:
            poly.use_smooth = False
        objects.append(obj)
    info = {'id': cid, 'frame': frame, 'authoring_bounds': {'min':lo,'max':hi},
            'meshes': len(objects), 'materials': len(objects),
            'triangles': sum(len(p.vertices)-2 for obj in objects for p in obj.data.polygons)}
    return objects, info


def main():
    argv = sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument('--group', choices=['all', *GROUPS], default='all')
    args = p.parse_args(argv)
    for d in ('source','exports','validation'):
        (LIB/d).mkdir(parents=True, exist_ok=True)
    (LIB/'.gdignore').touch()
    cities = json.loads((ROOT/'data/rulesets/lshu_configurable_v1/cities.json').read_text())['items']
    names = {c['id']:c['display_name'] for c in cities}
    groups = list(GROUPS) if args.group == 'all' else [args.group]
    for group in groups:
        module = importlib.import_module(GROUPS[group])
        bpy.ops.object.select_all(action='SELECT')
        bpy.ops.object.delete(use_global=False)
        for c in list(bpy.data.collections):
            if c.users == 0 or not c.objects:
                bpy.data.collections.remove(c)
        mats = {n: legacy.material(n, color) for n,color in legacy.PALETTE.items()}
        records, models = [], {}
        for cid, builder in module.BUILDERS.items():
            assert cid in names
            objects, record = build(cid, builder, mats, bpy.context.scene)
            bpy.ops.object.select_all(action='DESELECT')
            for obj in objects: obj.select_set(True)
            bpy.context.view_layer.objects.active = objects[0]
            glb = LIB/f'exports/{cid}.glb'
            bpy.ops.export_scene.gltf(filepath=str(glb), export_format='GLB', use_selection=True,
                export_apply=True, export_yup=True, export_animations=False,
                export_materials='EXPORT', export_cameras=False, export_lights=False, export_extras=True)
            record.update(name=names[cid], group=group, glb=f'exports/{cid}.glb',
                bytes=glb.stat().st_size, sha256=sha(glb), blend=f'source/{group}.blend',
                concept=f'concepts/{CONCEPTS[group]}')
            records.append(record)
            models[cid] = objects
            print('CITY_019_EXPORTED', cid, record['triangles'], flush=True)
        # A labeled collection per city; positions are for the editable gallery
        # only. GLBs have already been exported with the frozen origin.
        for i,(cid,objects) in enumerate(models.items()):
            for obj in objects:
                obj.location.x = (i%3-1)*3.0
                obj.location.y = (i//3-.5)*3.0
        scene = bpy.context.scene
        scene['task'] = 'TASK-CITY-LIBRARY-019'
        scene['export_origin_note'] = 'Gallery translations are source-only; clear object location before manual re-export. Prefer the reproducible builder.'
        for area in bpy.context.screen.areas if bpy.context.screen else []:
            if area.type == 'VIEW_3D':
                area.spaces.active.shading.color_type = 'MATERIAL'
                area.spaces.active.region_3d.view_distance = 10
        bpy.context.preferences.filepaths.save_version = 0
        bpy.ops.wm.save_as_mainfile(filepath=str(LIB/f'source/{group}.blend'), compress=True)
        report = {'task': 'TASK-CITY-LIBRARY-019', 'group':group,
            'blender': bpy.app.version_string, 'assets':records,
            'source_sha256': {str(path.relative_to(ROOT)):sha(path) for path in
                [Path(__file__),Path(legacy.__file__),Path(module.__file__)]},
            'blend_sha256':sha(LIB/f'source/{group}.blend')}
        (LIB/f'{group}-catalog.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print('CITY_019_GROUP_COMPLETE', group, len(records), flush=True)


if __name__ == '__main__':
    main()
