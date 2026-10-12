"""Inspect camping FBXs and render isolated source views in Blender CLI."""
import bpy
import hashlib
import json
import pathlib
from mathutils import Vector

ROOT=pathlib.Path(__file__).resolve().parents[3]
REPORT=ROOT/'docs/reports/traveler-panti-001/assets/camp'
REPORT.mkdir(parents=True,exist_ok=True)
NAMES=('tent','stump','firepit','lantern','banner')

def select(ob):
    for other in bpy.context.scene.objects: other.select_set(False)
    ob.select_set(True);bpy.context.view_layer.objects.active=ob

def stats(ob):
    mesh=ob.data;mesh.calc_loop_triangles()
    points=[ob.matrix_world@v.co for v in mesh.vertices]
    lo=[min(p[d] for p in points) for d in range(3)]
    hi=[max(p[d] for p in points) for d in range(3)]
    return {'triangles':len(mesh.loop_triangles),'vertices':len(mesh.vertices),
            'dimensions_godot_xyz':[hi[0]-lo[0],hi[2]-lo[2],hi[1]-lo[1]],
            'bounds_godot_xyz':[[lo[0],lo[2],-hi[1]],[hi[0],hi[2],-lo[1]]],
            'bottom_y':lo[2],'material_count':len(mesh.materials),'uv_layers':len(mesh.uv_layers)}

def clear_scene():
    for ob in list(bpy.data.objects): bpy.data.objects.remove(ob,do_unlink=True)

def import_asset(name):
    clear_scene()
    candidates=list((ROOT/'assets/traveler/panti/camp/source'/name).glob('*.fbx'))
    assert len(candidates)==1
    source=candidates[0]
    bpy.ops.import_scene.fbx(filepath=str(source),use_anim=False)
    meshes=[ob for ob in bpy.context.scene.objects if ob.type=='MESH']
    for ob in meshes:
        select(ob);bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    return source,meshes

def setup_render(height):
    scene=bpy.context.scene;scene.render.engine='BLENDER_EEVEE'
    scene.render.resolution_x=800;scene.render.resolution_y=800;scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG';scene.render.film_transparent=False
    scene.world.use_nodes=True
    bg=next(n for n in scene.world.node_tree.nodes if n.type=='BACKGROUND')
    bg.inputs['Color'].default_value=(.10,.14,.20,1);bg.inputs['Strength'].default_value=.6
    target=Vector((0,0,height*.45))
    for name,loc,power,size in [('Key',(-2,-3,4),220,3),('Fill',(3,1,3),90,3)]:
        data=bpy.data.lights.new(name,'AREA');light=bpy.data.objects.new(name,data)
        scene.collection.objects.link(light);light.location=loc;data.energy=power;data.size=size
        light.rotation_euler=(target-light.location).to_track_quat('-Z','Y').to_euler()
    data=bpy.data.cameras.new('Camp Evidence Camera');data.type='ORTHO';data.ortho_scale=1.40
    camera=bpy.data.objects.new('Camp Evidence Camera',data);scene.collection.objects.link(camera)
    scene.camera=camera
    return scene,camera,target

def render_views(name,stage,scene,camera,target,views=None):
    if views is None:
        views={'front':(1,-3,1.8),'rear':(-1,3,1.8),'left':(-3,-1,1.6),'right':(3,1,1.6)}
    for view,position in views.items():
        camera.location=Vector(position)
        camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
        scene.render.filepath=str(REPORT/f'{name}-{stage}-{view}.png')
        bpy.ops.render.render(write_still=True)

if __name__=='__main__':
    report={}
    for name in NAMES:
        source,meshes=import_asset(name)
        rows=[]
        for ob in meshes:
            row=stats(ob);row['object_name']=ob.name;row['materials']=[]
            for mat in ob.data.materials:
                nodes=mat.node_tree.nodes
                images=[]
                for node in nodes:
                    if node.type=='TEX_IMAGE' and node.image:
                        path=pathlib.Path(bpy.path.abspath(node.image.filepath))
                        images.append({'path':str(path.relative_to(ROOT)),'size':list(node.image.size),
                                       'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
                bsdf=next((n for n in nodes if n.type=='BSDF_PRINCIPLED'),None)
                row['materials'].append({'name':mat.name,'images':images,
                     'emission_color':list(bsdf.inputs['Emission Color'].default_value) if bsdf else None,
                     'emission_strength':bsdf.inputs['Emission Strength'].default_value if bsdf else None})
            rows.append(row)
        report[name]={'source':str(source.relative_to(ROOT)),
                     'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'meshes':rows}
        scene,camera,target=setup_render(max(r['bounds_godot_xyz'][1][1] for r in rows))
        render_views(name,'source',scene,camera,target)
        (REPORT/'source-inspection.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
