"""Save the current authored mountain and only its mesh to the game asset path."""
import bpy, json, math
from pathlib import Path
from collections import Counter

ROOT=Path('/Users/chengzeyuan/Developer/SilkRoad')
OUT=ROOT/'docs/design/shanhe-luren/mountain-rework/blender'
obj=next(o for o in bpy.context.scene.objects if o.type=='MESH' and o.name.startswith('T7 Snowcap Massif'));mesh=obj.data
angles=[];edges=Counter()
for face in mesh.polygons:
    ids=list(face.vertices);vs=[mesh.vertices[i].co for i in ids]
    for j in range(len(ids)):
        edges[tuple(sorted((ids[j],ids[(j+1)%len(ids)])))]+=1
        angles.append(math.degrees((vs[(j-1)%len(ids)]-vs[j]).angle(vs[(j+1)%len(ids)]-vs[j])))
report={'vertices':len(mesh.vertices),'triangles':len(mesh.polygons),
    'snow_face_fraction':sum(p.material_index for p in mesh.polygons)/len(mesh.polygons),
    'normal_z_min':min(p.normal.z for p in mesh.polygons),
    'minimum_angle_degrees':min(angles),'minimum_angle_threshold':12,
    'degenerate_faces':sum(f.area<1e-10 for f in mesh.polygons),
    'nonmanifold_edges':sum(v>2 for v in edges.values()),
    'open_boundary_edges':sum(v==1 for v in edges.values()),
    'mesh_role':'open-bottom distant background mountain',
    'reference':'T7-mountain-four-views.png','buttress_spines':10,
    'not_full_game_acceptance':True,'blender_version':bpy.app.version_string}
(OUT/'model-check.json').write_text(json.dumps(report,indent=2))
for x in bpy.context.scene.objects:x.select_set(False)
obj.select_set(True);bpy.context.view_layer.objects.active=obj
bpy.ops.export_scene.gltf(filepath=str(ROOT/'assets/traveler/mountains/t7-snow-massif.glb'),
    export_format='GLB',use_selection=True,use_active_scene=True,
    export_materials='EXPORT',export_animations=False,export_cameras=False,export_lights=False,export_yup=True)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'t7-snow-massif.blend'),check_existing=False)
bpy.ops.render.render(write_still=True)
(OUT/'t7-model-orthographic.json').write_text(json.dumps({
    'image_size':[1920,1080], 'viewport_size':None,
    'renderer':'Blender EEVEE','projection':'orthographic',
    'scope':'native Blender model preview; Godot measurements use separate SubViewport images',
    'blend':'t7-snow-massif.blend','reference':'../reference/T7-mountain-four-views.png'},indent=2))
print(report)
