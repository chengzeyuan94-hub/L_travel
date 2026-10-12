"""Derive textured camping GLBs in an isolated Blender CLI process."""
import bpy
import hashlib
import json
import pathlib
import sys

ROOT=pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parent))
from inspect_camp import import_asset,stats,select,setup_render,render_views

REPORT=ROOT/'docs/reports/traveler-panti-001/assets/camp'
OUTPUT=ROOT/'assets/traveler/panti/camp/processed'
OUTPUT.mkdir(parents=True,exist_ok=True)
bpy.context.preferences.filepaths.save_version=0
TARGETS={'tent':6000,'stump':4000,'firepit':3000,'lantern':2000,'banner':2000}
ORIENTATION={
    'tent':'Entrance faces Godot +Z; longitudinal roof ridge runs along Z.',
    'stump':'No required facing; top seating disc faces +Y.',
    'firepit':'No required facing; stacked logs and stone ring, no flame geometry.',
    'lantern':'Front X-brace and base knob face Godot +Z; handle lies roughly in XY plane. Yellow interior geometry is textured, not emissive.',
    'banner':'White diamond on red cloth faces Godot +Z; pole is at negative X and cloth extends toward positive X.'}
report={'blender_version':bpy.app.version_string,
        'method':'Blender collapse decimation on the supplied meshes; retain UV layer and original basecolor bytes; flat face normals; translate lowest surviving vertex to y=0 without rescaling.',
        'assets':{}}

for name,target in TARGETS.items():
    source,meshes=import_asset(name)
    assert len(meshes)==1,'Inspect multiple mesh sources before merging.'
    ob=meshes[0];ob.name=name.title();ob.data.name=name.title()+'Mesh'
    before=stats(ob)
    assert before['material_count']==1 and before['uv_layers']==1,'Do not discard source materials.'
    mat=ob.data.materials[0]
    images=[n.image for n in mat.node_tree.nodes if n.type=='TEX_IMAGE' and n.image]
    assert len(images)==1 and tuple(images[0].size)==(2048,2048)
    image=images[0];texture=pathlib.Path(bpy.path.abspath(image.filepath))
    source_hash=hashlib.sha256(source.read_bytes()).hexdigest()
    texture_hash=hashlib.sha256(texture.read_bytes()).hexdigest();image.pack()
    select(ob)
    modifier=ob.modifiers.new('Camping asset triangle budget','DECIMATE')
    modifier.decimate_type='COLLAPSE';modifier.ratio=target/before['triangles']
    modifier.use_collapse_triangulate=True
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    minimum=min(v.co.z for v in ob.data.vertices)
    for v in ob.data.vertices: v.co.z-=minimum
    for polygon in ob.data.polygons: polygon.use_smooth=False
    after=stats(ob)
    assert target*.97<=after['triangles']<=target*1.03
    assert abs(after['bottom_y'])<1e-7
    assert after['uv_layers']==1 and after['material_count']==1
    # Camera aim uses the original height so the two stages share framing.
    scene,camera,aim=setup_render(before['bounds_godot_xyz'][1][1])
    render_views(name,'reduced',scene,camera,aim)
    select(ob)
    destination=OUTPUT/f'{name}.glb'
    bpy.ops.export_scene.gltf(filepath=str(destination),use_selection=True,export_animations=False,
                              export_cameras=False,export_lights=False,export_yup=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(REPORT/f'{name}-reduced.blend'),copy=True)
    assert hashlib.sha256(source.read_bytes()).hexdigest()==source_hash
    assert hashlib.sha256(texture.read_bytes()).hexdigest()==texture_hash
    report['assets'][name]={'source':str(source.relative_to(ROOT)),'source_sha256':source_hash,
        'basecolor':str(texture.relative_to(ROOT)),'basecolor_sha256':texture_hash,'basecolor_size':list(image.size),
        'before':before,'after':after,'triangle_target':target,'grounding_removed_blender_z':minimum,
        'orientation':ORIENTATION[name],'export':str(destination.relative_to(ROOT)),
        'export_sha256':hashlib.sha256(destination.read_bytes()).hexdigest(),'original_files_unchanged':True}
    (REPORT/'reduction-report.json').write_text(json.dumps(report,indent=2)+'\n')
    print('CAMP_EXPORT_READY',name,json.dumps(after),flush=True)
