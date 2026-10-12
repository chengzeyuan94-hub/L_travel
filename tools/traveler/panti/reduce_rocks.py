"""Delete the detached rock02 plinth and derive single-material Panti rocks.

Run only in an independent factory-startup Blender process. Source FBXs, source
textures and the user's open Blender document are never modified.
"""
import bpy
import bmesh
import hashlib
import json
import pathlib
import sys
from mathutils import Vector

ROOT=pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parent))
from inspect_rocks import geometric_islands

OUT=ROOT/'assets/traveler/panti/processed'
REPORT=ROOT/'docs/reports/traveler-panti-001/assets/rocks'
OUT.mkdir(parents=True,exist_ok=True)
REPORT.mkdir(parents=True,exist_ok=True)
bpy.context.preferences.filepaths.save_version=0

def select(ob):
    for other in bpy.context.scene.objects: other.select_set(False)
    ob.select_set(True)
    bpy.context.view_layer.objects.active=ob

def stats(ob):
    ob.data.calc_loop_triangles()
    lo=[min(v.co[i] for v in ob.data.vertices) for i in range(3)]
    hi=[max(v.co[i] for v in ob.data.vertices) for i in range(3)]
    return {'triangles':len(ob.data.loop_triangles),'vertices':len(ob.data.vertices),
            'dimensions_godot_xyz':[hi[0]-lo[0],hi[2]-lo[2],hi[1]-lo[1]],
            'bounds_godot_xyz':[[lo[0],lo[2],-hi[1]],[hi[0],hi[2],-lo[1]]],
            'bottom_y':lo[2],'material_count':len(ob.data.materials),
            'uv_layers':len(ob.data.uv_layers),
            'flat_face_count':sum(not p.use_smooth for p in ob.data.polygons)}

def setup_scene():
    s=bpy.context.scene
    s.render.engine='BLENDER_EEVEE'
    s.render.resolution_x=900;s.render.resolution_y=900;s.render.resolution_percentage=100
    s.render.image_settings.file_format='PNG'
    s.render.film_transparent=False
    s.world.use_nodes=True
    bg=next(n for n in s.world.node_tree.nodes if n.type=='BACKGROUND')
    bg.inputs['Color'].default_value=(.10,.14,.20,1)
    bg.inputs['Strength'].default_value=.50
    for name,loc,energy,size in [('Key',(-2,-3,4),230,2),('Fill',(3,1,2),60,3)]:
        data=bpy.data.lights.new(name,'AREA')
        light=bpy.data.objects.new(name,data);s.collection.objects.link(light)
        light.location=loc;data.energy=energy;data.shape='DISK';data.size=size
        light.rotation_euler=(Vector((0,0,.35))-light.location).to_track_quat('-Z','Y').to_euler()
    data=bpy.data.cameras.new('Rock Evidence Camera');data.type='ORTHO';data.ortho_scale=1.40
    camera=bpy.data.objects.new('Rock Evidence Camera',data);s.collection.objects.link(camera)
    s.camera=camera
    return s,camera

def render(asset,stage,s,camera):
    for view,location in [('front',(1.0,-2.8,1.6)),('rear',(-1.0,2.8,1.6))]:
        camera.location=location
        camera.rotation_euler=(Vector((0,0,.35))-camera.location).to_track_quat('-Z','Y').to_euler()
        s.render.filepath=str(REPORT/f'{asset}-{stage}-{view}.png')
        bpy.ops.render.render(write_still=True)

def compact_islands(islands):
    return [{k:v for k,v in island.items() if k!='vertex_ids'} for island in islands]

report={'blender_version':bpy.app.version_string,
        'method':'Delete verified disconnected lower islands on rock02; collapse decimation; original UV layer and exact packed source basecolor retained; flat face normals; translate remaining bottom to y=0.',
        'assets':{}}

for asset in ('rock01','rock02'):
    for ob in list(bpy.data.objects): bpy.data.objects.remove(ob,do_unlink=True)
    source=ROOT/'assets/traveler/panti'/f'{asset}-raw.fbx'
    original_hash=hashlib.sha256(source.read_bytes()).hexdigest()
    bpy.ops.import_scene.fbx(filepath=str(source),use_anim=False)
    meshes=[o for o in bpy.context.scene.objects if o.type=='MESH']
    assert len(meshes)==1
    ob=meshes[0];select(ob)
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    ob.name=asset.title();ob.data.name=asset.title()+'Mesh'
    before=stats(ob)
    assert before['material_count']==1 and before['uv_layers']==1
    mat=ob.data.materials[0]
    images=[n.image for n in mat.node_tree.nodes if n.type=='TEX_IMAGE' and n.image]
    expected_texture_size=(4096,4096) if asset=='rock01' else (2048,2048)
    assert len(images)==1 and tuple(images[0].size)==expected_texture_size
    texture=pathlib.Path(bpy.path.abspath(images[0].filepath))
    texture_hash=hashlib.sha256(texture.read_bytes()).hexdigest()
    images[0].pack()
    scene,camera=setup_scene()
    render(asset,'source',scene,camera)
    islands=geometric_islands(ob.data)
    deletion={'removed_islands':0,'removed_triangles':0,'removed_vertex_ids':[],
              'reason':'rock01 has no detached plinth; no explicit island deletion.'}
    if asset=='rock02':
        assert len(islands)==3, 'Reinspect topology before changing removal criteria.'
        main=islands[0]
        base=[row for row in islands[1:] if row['bounds_blender_xyz'][1][2]<main['bounds_blender_xyz'][0][2]]
        assert len(base)==2 and sum(row['triangles'] for row in base)==1968
        ids=set(v for row in base for v in row['vertex_ids'])
        total_volume=sum(row['absolute_volume'] for row in islands)
        removed_volume=sum(row['absolute_volume'] for row in base)
        deletion={'removed_islands':len(base),'removed_triangles':sum(row['triangles'] for row in base),
                  'removed_vertices':len(ids),'removed_vertex_ids':sorted(ids),
                  'source_islands':compact_islands(islands),'removed_island_stats':compact_islands(base),
                  'vertical_gap_to_main':main['bounds_blender_xyz'][0][2]-max(row['bounds_blender_xyz'][1][2] for row in base),
                  'removed_volume_u3':removed_volume,'sum_absolute_island_volume_u3':total_volume,
                  'removed_volume_fraction_estimate':removed_volume/total_volume,
                  'volume_method':'Absolute signed tetrahedral volume per geometric island. Removed islands are closed manifold; main has 18 boundary and 18 nonmanifold geometric edges, so denominator/fraction is an estimate, not a watertight solid measurement.',
                  'reason':'Two components sit fully below the main rock, with a visible air gap. They form the detached lettered plinth and a tiny island within that plinth region. Delete their vertices/faces; do not bury or reposition the plinth.'}
        bm=bmesh.new();bm.from_mesh(ob.data);bm.verts.ensure_lookup_table()
        bmesh.ops.delete(bm,geom=[bm.verts[i] for i in sorted(ids)],context='VERTS')
        bm.to_mesh(ob.data);bm.free();ob.data.update()
        assert stats(ob)['triangles']==7548
        render(asset,'cleaned-unshifted',scene,camera)
    pre_reduction=stats(ob)
    # Move only the retained rock after deletion; the removed plinth no longer
    # exists in the mesh. This establishes an explicit placement bottom of zero.
    removed_z=min(v.co.z for v in ob.data.vertices)
    for v in ob.data.vertices: v.co.z-=removed_z
    render(asset,'cleaned-grounded',scene,camera)
    select(ob)
    mod=ob.modifiers.new('Panti rock budget','DECIMATE');mod.decimate_type='COLLAPSE'
    mod.ratio=350/pre_reduction['triangles'];mod.use_collapse_triangulate=True
    bpy.ops.object.modifier_apply(modifier=mod.name)
    reduced_z=min(v.co.z for v in ob.data.vertices)
    for v in ob.data.vertices: v.co.z-=reduced_z
    for polygon in ob.data.polygons: polygon.use_smooth=False
    after=stats(ob)
    assert 150<=after['triangles']<=400, after
    assert after['uv_layers']==1 and after['material_count']==1
    render(asset,'reduced',scene,camera)
    select(ob)
    export=OUT/f'{asset}.glb'
    bpy.ops.export_scene.gltf(filepath=str(export),use_selection=True,export_animations=False,
                              export_cameras=False,export_lights=False,export_yup=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(REPORT/f'{asset}-reduced.blend'),copy=True)
    assert hashlib.sha256(source.read_bytes()).hexdigest()==original_hash
    assert hashlib.sha256(texture.read_bytes()).hexdigest()==texture_hash
    report['assets'][asset]={'source':str(source.relative_to(ROOT)),'source_sha256':original_hash,
        'basecolor':str(texture.relative_to(ROOT)),'basecolor_sha256':texture_hash,
        'basecolor_size':list(images[0].size),
        'before':before,'pre_reduction':pre_reduction,'after':after,
        'deletion':deletion,'grounding_removed_z_before_reduction':removed_z,
        'grounding_removed_z_after_reduction':reduced_z,'target_triangles':350,
        'export':str(export.relative_to(ROOT)),'export_sha256':hashlib.sha256(export.read_bytes()).hexdigest(),
        'source_files_unchanged':True}
    (REPORT/'reduction-report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(asset,json.dumps({k:v for k,v in report['assets'][asset].items() if k!='deletion'}),flush=True)
