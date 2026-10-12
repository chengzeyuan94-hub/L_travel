#!/usr/bin/env python3
"""Independent geographic scenery authoring; never writes the production map.

Blender --background --python-exit-code 1 --python tools/lowpoly/landmarks_020_common.py -- --group all
Group modules expose BUILDERS: id -> function(g), plus optional FEATURES.
All coordinates are Blender Z-up. Scene-sized models, usually 2.5–3.6 units
wide, retain their authored scale. Export applies only a centering translation.
"""
import argparse
import hashlib
import importlib
import json
from pathlib import Path
import sys

import bpy
import bmesh

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from cities_019_common import Geometry019
import build_cities as legacy
import library_landforms_018 as landforms
from cities_019_landmarks import beam, dome, palm

ROOT=HERE.parents[1]
LIB=ROOT/'docs/design/landmark-library-020'
GROUPS={'east':'landmarks_020_east','south':'landmarks_020_south','west':'landmarks_020_west'}
PALETTE={**legacy.PALETTE,
    'rock':'A69B86','rock_light':'C4B79D','rock_dark':'786F65',
    'slate':'737E89','snow':'E8EDE8','ice':'AACEDA',
    'grass':'85975B','grass_light':'A4B575','grass_dark':'61774C',
    'earth':'A98B60','sand':'D8BA7F','sand_light':'E8D09F','sand_dark':'BE995E',
    'water_deep':'327D89','water_shallow':'70B6B4','water_light':'A3D2CD',
    'lava':'595654','lava_light':'80766C','coral':'C99079','coral_light':'DFBDA0',
    'mud':'8D8662','reed':'93A45E','granite':'B6B3A6'}


class Geometry020(Geometry019):
    def land(self,boundary,height,appearance,base='earth',spacing=.12,features=None,feature_edges=None):
        """Constrained triangulated terrain, closed underside at Z=0.

        appearance is a material name or fn((x,y,z))->name; it can also return
        (signed_distance_fn, lower_mat, upper_mat) for exact split snow lines.
        Features and feature_edges can force ridges, banks and terrace edges.
        """
        surface=landforms.Surface(self.city_id)
        landforms.triangulated_land(surface,boundary,height,appearance,base,
            spacing=spacing,features=features,feature_edges=feature_edges)
        by_material={}
        for face,mat in zip(surface.faces,surface.materials):
            by_material.setdefault(mat,[]).append(face)
        for mat,faces in by_material.items():
            self.mesh(surface.vertices,faces,mat)

    @staticmethod
    def outline(rx,ry,count=48,phase=0.,lopsided=0.):
        return landforms.outline(rx,ry,count,phase,lopsided)

    @staticmethod
    def taper(x,y,boundary):
        return landforms.taper_to_outline(x,y,boundary)

    def beam(self,a,b,radius=.025,mat='dark_wood',sides=7):
        beam(self,a,b,radius,mat,sides)

    def dome(self,x,y,z,r,h,mat='cream',sides=16,steps=5):
        dome(self,x,y,z,r,h,mat,sides,steps)

    def palm(self,x,y,z=0,h=.65,r=.25):
        palm(self,x,y,z,h,r)

    def tree(self,x,y,h=.65,r=.25,z=0):
        self.beam((x,y,z),(x+.025,y,z+h*.63),.034,'dark_wood')
        for dx,dy,dz,scale in [(-.42,-.1,.63,.76),(.41,.08,.71,.77),(.04,.31,.80,.86)]:
            self.beam((x+.018,y,z+h*.36),(x+dx*r,y+dy*r,z+h*dz),.020,'dark_wood')
            self.dome(x+dx*r,y+dy*r,z+h*dz-r*.35,r*scale,r*.80,'foliage',10,3)
            self.ring(x+dx*r,y+dy*r,z+h*dz-r*.60,r*scale*.56,r*.26,'foliage',10,top=r*scale)


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(aid,fn,materials):
    g=Geometry020(aid);fn(g)
    assert 1<=len(g.buckets)<=10,(aid,'too many material buckets',list(g.buckets))
    used=[v for vv,ff in g.buckets.values() for face in ff for i in face for v in [vv[i]]]
    lo=[min(v[i] for v in used) for i in range(3)];hi=[max(v[i] for v in used) for i in range(3)]
    assert hi[2]-lo[2]>.025 and max(hi[0]-lo[0],hi[1]-lo[1])<=5.5,(aid,lo,hi)
    shift=[(lo[0]+hi[0])/2,(lo[1]+hi[1])/2,lo[2]]
    collection=bpy.data.collections.new(aid);bpy.context.scene.collection.children.link(collection)
    # Restore the whole surface before orienting it. A material patch can be
    # open and almost planar: recalc on that isolated patch may choose its
    # underside as the front. Weld across material boundaries, orient complete
    # connected shells, then split into draw surfaces without another recalc.
    material_names=sorted(g.buckets)
    vertices_all=[];faces_all=[];face_materials=[]
    for material_index,mat in enumerate(material_names):
        vertices,faces=g.buckets[mat]
        assert mat in materials,(aid,mat)
        indices=sorted({i for f in faces for i in f})
        mapping={old:len(vertices_all)+i for i,old in enumerate(indices)}
        vertices_all.extend(tuple(vertices[index][i]-shift[i] for i in range(3)) for index in indices)
        faces_all.extend(tuple(mapping[i] for i in f) for f in faces)
        face_materials.extend([material_index]*len(faces))
    combined=bpy.data.meshes.new(f'{aid}_orientation_work')
    combined.from_pydata(vertices_all,[],faces_all)
    for mat in material_names:combined.materials.append(materials[mat])
    for poly,mi in zip(combined.polygons,face_materials):poly.material_index=mi
    bm=bmesh.new();bm.from_mesh(combined)
    bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=1e-6)
    bmesh.ops.dissolve_degenerate(bm,edges=list(bm.edges),dist=1e-7)
    bmesh.ops.triangulate(bm,faces=list(bm.faces))
    bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces))
    bm.to_mesh(combined);bm.free();combined.update()
    objects=[];validated_repairs=[]
    for material_index,mat in enumerate(material_names):
        faces=[list(p.vertices) for p in combined.polygons if p.material_index==material_index]
        if not faces:continue
        indices=sorted({i for f in faces for i in f});mapping={old:i for i,old in enumerate(indices)}
        vv=[tuple(combined.vertices[index].co) for index in indices]
        ff=[tuple(mapping[i] for i in f) for f in faces]
        mesh=bpy.data.meshes.new(f'{aid}_{mat}');mesh.from_pydata(vv,[],ff)
        mesh.materials.append(materials[mat]);mesh.update()
        # The exporter may validate its input in place. Clean duplicate mesh
        # records now, before counting/exporting, so the saved editable source
        # and the GLB are built from the same validated geometry.
        if mesh.validate(verbose=False):validated_repairs.append(mat)
        mesh.update()
        assert not mesh.validate(verbose=False),(aid,mat,'mesh validation did not converge')
        obj=bpy.data.objects.new(f'{aid}_{mat}',mesh);collection.objects.link(obj)
        obj['asset_id']=aid;obj['authoring_shift']=shift;obj['asset_kind']='silkroad_scenery_020'
        for poly in mesh.polygons:poly.use_smooth=False
        objects.append(obj)
    bpy.data.meshes.remove(combined)
    info={'id':aid,'meshes':len(objects),'materials':len(objects),
        'triangles':sum(len(o.data.polygons) for o in objects),'authoring_bounds':{'min':lo,'max':hi},
        'export_shift_xyz':shift,'scale_applied':1.0,'validated_material_repairs':validated_repairs}
    return objects,info


def main():
    args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
    p=argparse.ArgumentParser();p.add_argument('--group',choices=['all',*GROUPS],default='all');opt=p.parse_args(args)
    for d in ['exports','source','validation']:(LIB/d).mkdir(parents=True,exist_ok=True)
    (LIB/'.gdignore').touch()
    brief=json.loads((LIB/'geography-plan.json').read_text());metadata={a['id']:a for a in brief['assets']}
    for group in (list(GROUPS) if opt.group=='all' else [opt.group]):
        module=importlib.import_module(GROUPS[group])
        bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
        for collection in list(bpy.data.collections):
            if not collection.objects:bpy.data.collections.remove(collection)
        for mesh in list(bpy.data.meshes):
            if mesh.users==0:bpy.data.meshes.remove(mesh)
        for material in list(bpy.data.materials):
            if material.users==0:bpy.data.materials.remove(material)
        mats={name:legacy.material(name,color) for name,color in PALETTE.items()}
        records=[];models={}
        for aid,fn in module.BUILDERS.items():
            assert aid in metadata and metadata[aid]['group']==group,aid
            objects,record=build(aid,fn,mats);models[aid]=objects
            bpy.ops.object.select_all(action='DESELECT')
            for obj in objects:obj.select_set(True)
            bpy.context.view_layer.objects.active=objects[0]
            path=LIB/f'exports/{aid}.glb'
            bpy.ops.export_scene.gltf(filepath=str(path),export_format='GLB',use_selection=True,export_apply=True,
                export_yup=True,export_animations=False,export_materials='EXPORT',export_cameras=False,
                export_lights=False,export_extras=True)
            assert sum(len(o.data.polygons) for o in objects)==record['triangles'],(aid,'exporter changed author geometry')
            record.update(**{k:v for k,v in metadata[aid].items() if k!='id'},
                features=getattr(module,'FEATURES',{}).get(aid,[]),glb=f'exports/{aid}.glb',
                blend=f'source/{group}.blend',sha256=sha(path),bytes=path.stat().st_size)
            records.append(record);print('LANDMARK_020_EXPORTED',aid,record['triangles'],flush=True)
        for i,(aid,objects) in enumerate(models.items()):
            for o in objects:o.location.x=(i%4-1.5)*5.6;o.location.y=(i//4-1)*5.6
        bpy.context.scene['task']='TASK-LANDMARK-LIBRARY-020'
        bpy.context.scene['export_note']='Source-only gallery translations. Clear location for manual export; prefer reproducible builder.'
        bpy.context.preferences.filepaths.save_version=0
        source=LIB/f'source/{group}.blend'
        bpy.ops.wm.save_as_mainfile(filepath=str(source),compress=True)
        deps=[Path(__file__),Path(module.__file__),Path(legacy.__file__),Path(landforms.__file__),
            HERE/'cities_019_common.py',HERE/'cities_019_landmarks.py']
        report={'task':'TASK-LANDMARK-LIBRARY-020','group':group,'blender':bpy.app.version_string,
            'assets':records,'blend_sha256':sha(source),'source_sha256':{str(p.relative_to(ROOT)):sha(p) for p in deps},
            'geography_plan_sha256':sha(LIB/'geography-plan.json')}
        (LIB/f'{group}-catalog.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print('LANDMARK_020_GROUP_COMPLETE',group,len(records),flush=True)


if __name__=='__main__':main()
