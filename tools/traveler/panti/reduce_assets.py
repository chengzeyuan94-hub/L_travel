"""Derive textured, single-primitive assets from the untouched Panti FBXs.

Run in an independent factory-startup Blender process; never changes a user's
open Blender document. Textures and UVs are retained, not recolored or rebaked.
"""
import bpy
import hashlib
import json
import math
import pathlib
import sys
from mathutils import Vector

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT / 'assets/traveler/panti/processed'
REPORT = ROOT / 'docs/reports/traveler-panti-001/assets'
TARGETS = {'fortress': 45000, 'pine': 1450}
OUT.mkdir(parents=True, exist_ok=True)
REPORT.mkdir(parents=True, exist_ok=True)

def enum_value(owner, prop, wanted):
    allowed = [item.identifier for item in owner.bl_rna.properties[prop].enum_items]
    if wanted not in allowed:
        raise ValueError((prop, wanted, allowed))
    return wanted

def operator_enum(op, prop, wanted):
    allowed = [item.identifier for item in op.get_rna_type().properties[prop].enum_items]
    if wanted not in allowed:
        raise ValueError((prop, wanted, allowed))
    return wanted

def stats(ob):
    ob.data.calc_loop_triangles()
    points = [ob.matrix_world @ v.co for v in ob.data.vertices]
    lo = [min(p[i] for p in points) for i in range(3)]
    hi = [max(p[i] for p in points) for i in range(3)]
    # Blender Z-up -> glTF / Godot Y-up.
    return {'triangles':len(ob.data.loop_triangles), 'vertices':len(ob.data.vertices),
            'dimensions_godot_xyz':[hi[0]-lo[0], hi[2]-lo[2], hi[1]-lo[1]],
            'bottom_y':lo[2], 'materials':len(ob.data.materials),
            'uv_layers':len(ob.data.uv_layers)}

def deselect():
    for ob in bpy.context.scene.objects: ob.select_set(False)

def select(ob):
    deselect()
    ob.select_set(True)
    bpy.context.view_layer.objects.active=ob

def render_setup(asset):
    scene=bpy.context.scene
    scene.render.resolution_x=900
    scene.render.resolution_y=900
    scene.render.resolution_percentage=100
    scene.render.image_settings.file_format=enum_value(scene.render.image_settings,'file_format','PNG')
    scene.render.film_transparent=False
    scene.world.use_nodes=True
    bg=next(n for n in scene.world.node_tree.nodes if n.type=='BACKGROUND')
    bg.inputs['Color'].default_value=(0.10,0.14,0.19,1)
    bg.inputs['Strength'].default_value=0.65
    for name,loc,energy,size in [('Key',(-2,-3,5),220,4),('Fill',(3,1,3),100,3)]:
        ld=bpy.data.lights.new(name, type=operator_enum(bpy.ops.object.light_add,'type','AREA'))
        lo=bpy.data.objects.new(name,ld);scene.collection.objects.link(lo)
        lo.location=loc;ld.energy=energy;ld.shape=enum_value(ld,'shape','DISK');ld.size=size
        lo.rotation_euler=(Vector((0,0,.4))-lo.location).to_track_quat('-Z','Y').to_euler()
    cd=bpy.data.cameras.new('Evidence Camera')
    cam=bpy.data.objects.new('Evidence Camera',cd);scene.collection.objects.link(cam)
    cd.type=enum_value(cd,'type','ORTHO');cd.ortho_scale=1.45 if asset=='fortress' else 1.2
    scene.camera=cam
    return scene,cam

def render(ob,asset,stage,scene,cam):
    # Front (Blender -Y, Godot +Z) and rear check also establish orientation.
    for direction,location in [('front',(1.2,-2.8,1.5)),('rear',(-1.2,2.8,1.5))]:
        cam.location=location
        target=Vector((0,0,.27 if asset=='fortress' else .50))
        cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler()
        scene.render.filepath=str(REPORT/f'{asset}-{stage}-{direction}.png')
        bpy.ops.render.render(write_still=True)

report={'blender_version':bpy.app.version_string,'method':'Blender collapse decimation with retained UVs and original 4096px basecolor; no texture recolor; source transforms applied before export', 'assets':{}}
for asset,target in TARGETS.items():
    for ob in list(bpy.data.objects): bpy.data.objects.remove(ob,do_unlink=True)
    source=ROOT/'assets/traveler/panti'/f'{asset}-raw.fbx'
    bpy.ops.import_scene.fbx(filepath=str(source), use_anim=False)
    meshes=[ob for ob in bpy.context.scene.objects if ob.type=='MESH']
    if len(meshes)!=1: raise RuntimeError(f'{asset}: expected one source mesh, got {len(meshes)}')
    ob=meshes[0]
    select(ob)
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    ob.name=asset.title()
    before=stats(ob)
    if before['materials']!=1 or before['uv_layers']!=1: raise RuntimeError(before)
    material=ob.data.materials[0]
    images=[n.image for n in material.node_tree.nodes if n.type=='TEX_IMAGE' and n.image]
    if len(images)!=1 or tuple(images[0].size)!=(4096,4096): raise RuntimeError('Missing original basecolor')
    texture_path=pathlib.Path(bpy.path.abspath(images[0].filepath))
    images[0].pack()
    scene,cam=render_setup(asset)
    render(ob,asset,'before',scene,cam)
    select(ob)
    mod=ob.modifiers.new('Panti budget reduction',type=operator_enum(bpy.ops.object.modifier_add,'type','DECIMATE'))
    mod.decimate_type=enum_value(mod,'decimate_type','COLLAPSE')
    mod.ratio=target/before['triangles']
    mod.use_collapse_triangulate=True
    bpy.ops.object.modifier_apply(modifier=mod.name)
    # Keep placement on the floor. Reduction is not normalized or rescaled.
    min_z=min(v.co.z for v in ob.data.vertices)
    for v in ob.data.vertices: v.co.z-=min_z
    after=stats(ob)
    render(ob,asset,'after',scene,cam)
    select(ob)
    export=OUT/f'{asset}.glb'
    # The glTF export-format enum is dynamic in Blender 5.2; its operator
    # default is GLB, and filepath also has the .glb extension.
    bpy.ops.export_scene.gltf(filepath=str(export),use_selection=True,export_animations=False,export_cameras=False,export_lights=False,export_yup=True)
    # Editable derivative remains available beside the budget report.
    bpy.ops.wm.save_as_mainfile(filepath=str(REPORT/f'{asset}-reduced.blend'),copy=True)
    report['assets'][asset]={'source':str(source.relative_to(ROOT)), 'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
        'target_triangles':target,'before':before,'after':after,'reduction_ratio':after['triangles']/before['triangles'],
        'basecolor':str(texture_path.relative_to(ROOT)),'basecolor_sha256':hashlib.sha256(texture_path.read_bytes()).hexdigest(),
        'export':str(export.relative_to(ROOT)),'export_sha256':hashlib.sha256(export.read_bytes()).hexdigest(),
        'godot_front_direction':'+Z (front evidence camera = Blender -Y)',
        'note':'All sizes are local asset units; apply size-tier scaling in scene data.'}
    (REPORT/'reduction-report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(asset, json.dumps(report['assets'][asset]),flush=True)
