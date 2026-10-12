"""Prepare the supplied sitting animation as a Panti-only asset in Blender."""
import bpy, json, pathlib, math, hashlib
import numpy as np
from mathutils import Vector, Matrix

ROOT=pathlib.Path(__file__).resolve().parents[3]
OUT=ROOT/'assets/traveler/panti/camp/character'
REPORT=ROOT/'docs/reports/traveler-panti-001/assets/camp-character'
SOURCE=pathlib.Path('/Users/chengzeyuan/Desktop/露营点位模型及概念图/L叔坐下-Sitting.fbx')
OUT.mkdir(parents=True,exist_ok=True);REPORT.mkdir(parents=True,exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=str(SOURCE), use_anim=True)
scene=bpy.context.scene
rig=next(o for o in scene.objects if o.type=='ARMATURE')
body=next(o for o in scene.objects if o.type=='MESH')
action=rig.animation_data.action

def posed_points():
    scene.view_layers[0].update()
    ob=body.evaluated_get(bpy.context.evaluated_depsgraph_get())
    mesh=ob.to_mesh()
    points=np.array([list(ob.matrix_world @ v.co) for v in mesh.vertices])
    ob.to_mesh_clear()
    return points

def vec(v):return [float(x) for x in v]

def bnd(points):return {'min':vec(points.min(0)),'max':vec(points.max(0)),'size':vec(np.ptp(points,axis=0))}

samples=[]
for frame in [1,30,60,90,120,150,180,210,240,269]:
    scene.frame_set(frame)
    samples.append({'frame':frame,'bounds':bnd(posed_points()),'bones':{n:vec(rig.matrix_world @ rig.pose.bones['mixamorig:'+n].head) for n in ['Hips','Head','LeftFoot','RightFoot','LeftLeg','RightLeg']}})
report={'samples':samples,'mesh_local_bounds':bnd(np.array([list(v.co) for v in body.data.vertices])),'rig_matrix':list(map(list,rig.matrix_world)),'mesh_matrix':list(map(list,body.matrix_world)),'bone_rest':{n:vec(rig.matrix_world @ rig.data.bones['mixamorig:'+n].head_local) for n in ['Hips','Head','LeftFoot','RightFoot','LeftLeg','RightLeg']}}
(REPORT/'pose-inspection.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))

# The FBX stores centimetres in mesh-local Y. Its animated world pose is Blender
# Z-up; do not infer standing height from the importer's temporary rest rotation.
standing_height=float(np.ptp(np.array([list(v.co) for v in body.data.vertices]),axis=0)[1])*float(rig.scale.x)
normalization=1.0/standing_height
rig.scale*=normalization
action.name='seated_idle'
scene.frame_start=1;scene.frame_end=269
body.data.calc_loop_triangles()
triangles=np.array([list(t.vertices) for t in body.data.loop_triangles],dtype=int)
edges=np.unique(np.sort(np.concatenate([triangles[:,[0,1]],triangles[:,[1,2]],triangles[:,[2,0]]]),axis=1),axis=0)
rest=np.array([list(v.co) for v in body.data.vertices])*.01*normalization
rest_lengths=np.linalg.norm(rest[edges[:,0]]-rest[edges[:,1]],axis=1)
rows=[];previous=None;velocities=[];all_points=[]
for frame in np.arange(1,269.01,.5):
    integer=math.floor(frame);scene.frame_set(integer,subframe=float(frame-integer))
    points=posed_points()
    lengths=np.linalg.norm(points[edges[:,0]]-points[edges[:,1]],axis=1)
    delta=np.linalg.norm(points-previous,axis=1) if previous is not None else np.zeros(len(points))
    rows.append({'frame':float(frame),'seconds':float((frame-1)/30),'bounds':bnd(points),'max_edge_u':float(lengths.max()),'max_vertex_step_u':float(delta.max()),'rms_vertex_step_u':float(np.sqrt((delta*delta).mean())),'finite':bool(np.isfinite(points).all())})
    previous=points;all_points.append(points)
    velocities.append(rows[-1]['rms_vertex_step_u'])
# Pick the middle of the quietest contiguous 1-second window, excluding the
# first frame's undefined velocity. Source starts seated; no stand-to-sit exists.
window=60
scores=np.convolve(np.array(velocities[1:]),np.ones(window)/window,mode='valid')
best_start=int(np.argmin(scores))+1
chosen_index=best_start+window//2
chosen_frame=rows[chosen_index]['frame']
scene.frame_set(math.floor(chosen_frame),subframe=chosen_frame%1)
points=posed_points()
floor=float(points[:,2].min())
rig.location.z-=floor
scene.view_layers[0].update()
points=posed_points()

# Preserve source RGBA texture; no rebake, recolor or substitute image.
material=body.data.materials[0]
for node in material.node_tree.nodes:
    if node.type=='TEX_IMAGE' and node.image:node.image.pack()
for node in material.node_tree.nodes:
    if node.type=='BSDF_PRINCIPLED':
        node.inputs['Metallic'].default_value=0
        node.inputs['Roughness'].default_value=.5
        if 'Specular IOR Level' in node.inputs:node.inputs['Specular IOR Level'].default_value=0

def select_only(objects):
    for ob in scene.objects:ob.select_set(False)
    for ob in objects:ob.select_set(True)
    bpy.context.view_layer.objects.active=objects[0]

select_only([rig,body])
for image in list(bpy.data.images):
    if image.users==0:bpy.data.images.remove(image)
bpy.context.preferences.filepaths.save_version=0
bpy.ops.wm.save_as_mainfile(filepath=str(REPORT/'sitting-source.blend'))
bpy.ops.export_scene.gltf(filepath=str(OUT/'sitting-rigged.glb'),export_format='GLB',use_selection=True,export_animations=True,export_frame_range=True,export_force_sampling=True,export_animation_mode='ACTIONS',export_yup=True)
scene.frame_set(math.floor(chosen_frame),subframe=chosen_frame%1)
scene.view_layers[0].update() # glTF animation sampling resets the subframe.
points=posed_points()

# Bake only the chosen pose to separate render and outline meshes. The supplied
# rig stays editable in .blend and in the animation GLB; production pose needs no
# animation mixer or skin bindings and therefore cannot accumulate skin spikes.
evaluated=body.evaluated_get(bpy.context.evaluated_depsgraph_get())
baked=bpy.data.meshes.new_from_object(evaluated,preserve_all_data_layers=True,depsgraph=bpy.context.evaluated_depsgraph_get())
baked.transform(evaluated.matrix_world)
baked.update()
pose=bpy.data.objects.new('PantiSeatedBody',baked);scene.collection.objects.link(pose)
select_only([pose])
bpy.ops.export_scene.gltf(filepath=str(OUT/'sitting-pose.glb'),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)

# Match the previously accepted glasses exclusion by connected component in
# untouched rest coordinates, not the deformed pose or imported split vertices.
parents=list(range(len(body.data.vertices)))
def root(i):
    while parents[i]!=i:parents[i]=parents[parents[i]];i=parents[i]
    return i
for edge in body.data.edges:parents[root(edge.vertices[1])]=root(edge.vertices[0])
weld={}
for i,p in enumerate(rest):
    key=tuple(np.round(p/normalization,5))
    if key in weld:parents[root(i)]=root(weld[key])
    else:weld[key]=i
components={}
for i in range(len(parents)):components.setdefault(root(i),[]).append(i)
expected_min=np.array([-.16333,.67969,.01343]);expected_max=np.array([.16382,.76709,.16919])
matches=[]
for key,indices in components.items():
    p=rest[indices]/normalization
    if np.linalg.norm(p.min(0)-expected_min)<.00003 and np.linalg.norm(p.max(0)-expected_max)<.00003:matches.append(key)
assert len(matches)==1, ('Could not uniquely identify original glasses',[(len(v),bnd(rest[v])) for v in components.values()])
glasses=set(components[matches[0]])
outline_mesh=baked.copy()
import bmesh
bm=bmesh.new();bm.from_mesh(outline_mesh);bm.verts.ensure_lookup_table()
bmesh.ops.delete(bm,geom=[bm.verts[i] for i in glasses],context='VERTS')
bm.to_mesh(outline_mesh);bm.free();outline_mesh.update()
outline_mesh.materials.clear() # Unshaded runtime outline needs no 4K albedo copy.
outline=bpy.data.objects.new('PantiSeatedOutline',outline_mesh);scene.collection.objects.link(outline)
select_only([outline])
bpy.ops.export_scene.gltf(filepath=str(OUT/'sitting-outline.glb'),export_format='GLB',use_selection=True,export_animations=False,export_yup=True)

def godot(p):return [float(p[0]),float(p[2]),float(-p[1])]
hips=rig.matrix_world @ rig.pose.bones['mixamorig:Hips'].head
# Underside around the seated pelvis, excluding the knee and dangling legs.
pelvis=(np.abs(points[:,0]-hips.x)<.105)&(points[:,1]>hips.y-.025)&(points[:,1]<hips.y+.105)&(points[:,2]>hips.z-.13)&(points[:,2]<hips.z+.04)
seat_vertices=points[pelvis]
seat_height=float(np.percentile(seat_vertices[:,2],3))
seat_near=seat_vertices[seat_vertices[:,2]<seat_height+.008]
seat=np.array([float(np.median(seat_near[:,0])),seat_near[:,1].mean(),float(seat_near[:,2].min())])
left_sole=points[(points[:,0]>0)&(points[:,2]<.025)]
right_sole=points[(points[:,0]<0)&(points[:,2]<.025)]
landmarks={'coordinate_system':'Godot +Y up, +Z forward; pose origin is current feet floor, standing rest height normalized to 1.0', 'front_direction':[0,0,1],'seat_contact_local':godot(seat),'hips_bone_local':godot(hips),'left_sole_local':godot(left_sole[np.argmin(left_sole[:,2])]),'right_sole_local':godot(right_sole[np.argmin(right_sole[:,2])]),'head_top_local':godot(points[np.argmax(points[:,2])]),'bounds_godot':{'min':vec(np.column_stack([points[:,0],points[:,2],-points[:,1]]).min(0)),'max':vec(np.column_stack([points[:,0],points[:,2],-points[:,1]]).max(0))},'seat_contact_method':'Lower surface of rear pelvis, x within 0.105u and depth within [-0.025,+0.105]u of Hips in Blender coordinates, excluding knees; check stump fit visually.'}
weights=np.array([sum(g.weight for g in v.groups) for v in body.data.vertices])
audit={'schema':'silkroad.panti-camp-character.v1','source':str(SOURCE),'source_sha256':hashlib.sha256(SOURCE.read_bytes()).hexdigest(),'bones':len(rig.data.bones),'source_vertices':len(body.data.vertices),'triangles':len(triangles),'source_clip_length_s':268/30,'source_clip_kind':'Seated idle from the first frame; no stand-to-sit transition in supplied file','standing_rest_height_before_normalization_u':standing_height,'normalization_scale':normalization,'standing_rest_height_after_normalization_u':1.0,'intended_world_scale':.6375,'chosen_frame':chosen_frame,'chosen_seconds':(chosen_frame-1)/30,'quiet_window_seconds':[(rows[best_start]['frame']-1)/30,(rows[best_start+window]['frame']-1)/30],'quiet_window_rms_step_mean_u':float(scores.min()),'landmarks':landmarks,'outline_excluded_vertices':len(glasses),'outline_excluded_part':'same glasses component as approved character style','audit':{'sample_hz':60,'pose_samples':len(rows),'all_finite':all(r['finite'] for r in rows),'max_triangle_edge_u':max(r['max_edge_u'] for r in rows),'rest_max_triangle_edge_u':float(rest_lengths.max()),'max_frame_vertex_step_u':max(r['max_vertex_step_u'] for r in rows),'weight_sum_min':float(weights.min()),'weight_sum_max':float(weights.max()),'weight_sum_max_error':float(np.abs(weights-1).max()),'max_pose_bounds_size_u':vec(np.max([r['bounds']['size'] for r in rows],axis=0))},'production_spike_prevention':'Static evaluated mesh, no skeleton, no animation mixer, no run or walk clips','samples':rows}
(REPORT/'character-report.json').write_text(json.dumps(audit,indent=2))
(OUT/'seated-landmarks.json').write_text(json.dumps({k:v for k,v in audit.items() if k!='samples'},indent=2))

# Neutral reference renders of the actual baked pose, before Godot styling.
rig.hide_render=True;body.hide_render=True;outline.hide_render=True
scene.render.engine='CYCLES';scene.cycles.samples=24
scene.render.resolution_x=900;scene.render.resolution_y=900;scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG'
scene.world=bpy.data.worlds.new('CampCharacterEvidenceWorld');scene.world.use_nodes=True
scene.world.node_tree.nodes['Background'].inputs[0].default_value=(.13,.16,.2,1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value=.7
for name,pos,energy,size in [('Key',(-2,-3,4),300,3),('Fill',(2,1,3),100,3)]:
    light_data=bpy.data.lights.new(name,'AREA');light_data.energy=energy;light_data.shape='DISK';light_data.size=size
    light=bpy.data.objects.new(name,light_data);scene.collection.objects.link(light);light.location=pos;light.rotation_euler=(Vector((0,0,.4))-light.location).to_track_quat('-Z','Y').to_euler()
cam_data=bpy.data.cameras.new('EvidenceCamera');cam_data.type='ORTHO';cam_data.ortho_scale=1.05
cam=bpy.data.objects.new('EvidenceCamera',cam_data);scene.collection.objects.link(cam);scene.camera=cam
for label,position in [('front',(0,-3,.42)),('side',(3,0,.42)),('three-quarter',(2,-3,1.5))]:
    cam.location=position;cam.rotation_euler=(Vector((0,-.05,.42))-cam.location).to_track_quat('-Z','Y').to_euler()
    scene.render.filepath=str(REPORT/f'pose-{label}.png');bpy.ops.render.render(write_still=True)
print('CAMP_CHARACTER_COMPLETE',json.dumps({k:v for k,v in audit.items() if k!='samples'}))
