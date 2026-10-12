"""T7 orthographic-reference mountain, authored through live Blender MCP.
No existing scene/objects are deleted. Run in Blender's Python context.
"""
import bpy, math, json, random, os
import numpy as np
from pathlib import Path
from mathutils import Vector
from mathutils.geometry import delaunay_2d_cdt

ROOT=Path('/Users/chengzeyuan/Developer/SilkRoad')
OUT=Path(os.environ.get('SILKROAD_MOUNTAIN_OUTPUT', str(ROOT/'docs/design/shanhe-luren/mountain-rework/blender')))
OUT.mkdir(parents=True,exist_ok=True)
# x, y, height, skirt radius, phase: deliberate front silhouette, not random cones.
PEAKS=np.array([
 [1.0,1.0,14.0,6.9,.4],
 [-3.0,.3,8.8,4.2,1.5],
 [-5.8,-.1,6.1,3.2,2.1],
 [-7.5,.4,4.3,2.8,.7],
 [-4.7,-2.1,4.5,2.7,3.4],
 [4.8,.5,8.3,3.9,2.7],
 [6.3,-1.0,4.4,3.3,4.1],
 [.7,-3.1,5.3,3.5,1.8],
],dtype=float)

# Authored buttress spines: crest -> projecting shoulder -> lower spur.
# These are geometric elevations, not color noise or a normal map.
RIDGES=np.array([
 [1,1,14, -.2,-1.8,9.2, .1,1.2],
 [-.2,-1.8,9.2, -1.4,-3.8,5.8, 1.2,1.6],
 [-1.4,-3.8,5.8, -2.8,-6.2,0, 1.6,.8],
 [1,1,14, 3.1,-1.5,8.7, .1,1.1],
 [3.1,-1.5,8.7, 4.5,-3.5,4.6, 1.1,1.5],
 [4.5,-3.5,4.6, 6.6,-5.2,0, 1.5,.6],
 [-3,.3,8.8, -4.6,-2.3,5.0, .1,1.2],
 [-4.6,-2.3,5.0, -6.3,-4.8,0, 1.2,.8],
 [1,1,14, 2.3,3.2,8.3, .1,1.3],
 [2.3,3.2,8.3, 4.4,6.1,0, 1.3,.8],
],dtype=float)

def field(points):
 p=np.asarray(points,dtype=float).reshape(-1,2)
 delta=p[:,None,:]-PEAKS[None,:,:2]
 radius=np.linalg.norm(delta,axis=2)/PEAKS[None,:,3]
 angle=np.arctan2(delta[:,:,1],delta[:,:,0])
 phase=PEAKS[None,:,4]
 low=1+.16*np.sin(3*angle+phase)+.055*np.sin(7*angle+phase*.7)
 detail=.045*np.sin(16*angle+phase*1.3)
 def inverse(q):
  q=np.clip(q,0,1)
  return np.where(q>=.74,.34*(1-q)/.26,.34+.66*(1-(q/.74)**(1/.92)))
 t=inverse(radius/low)
 for _ in range(3):
  env=1-np.clip(t,0,1)**2*(3-2*np.clip(t,0,1))
  t=inverse((radius-detail*env)/low)
 heights=PEAKS[None,:,2]*t**1.20
 # Broad buttresses break up the smooth cone while preserving directional flow.
 heights += PEAKS[None,:,2]*.022*np.sin(9*angle+phase+t*7)*np.sin(np.pi*t)**2
 owner=heights.argmax(axis=1);ix=np.arange(len(p))
 base=heights[ix,owner]
 starts=RIDGES[None,:,:2];ends=RIDGES[None,:,3:5];direction=ends-starts
 fractions=np.clip(np.sum((p[:,None,:]-starts)*direction,axis=2)/np.sum(direction**2,axis=2),0,1)
 distance=np.linalg.norm(p[:,None,:]-(starts+fractions[:,:,None]*direction),axis=2)
 crest=RIDGES[None,:,2]*(1-fractions)+RIDGES[None,:,5]*fractions
 width=RIDGES[None,:,6]*(1-fractions)+RIDGES[None,:,7]*fractions
 buttress=crest*np.maximum(0,1-distance/np.maximum(width,.1))
 raised=buttress.max(axis=1)
 # Raised shoulders below the main summit remain rock rather than gaining tiny caps.
 owner=np.where(raised>base+1e-5,0,owner)
 return np.maximum(base,raised),owner,(low+detail)[ix,owner],angle[ix,owner]

# Star-shaped union footprint; all 8 peaks share one continuous triangulated skin.
rim=[]
for a in np.arange(128)*2*math.pi/128:
 direction=np.array([math.cos(a),math.sin(a)])
 rr=np.linspace(0,24,481);hh=field(rr[:,None]*direction)[0]
 lo=rr[np.flatnonzero(hh>1e-6)[-1]];hi=lo+.06
 for _ in range(16):
  mid=(lo+hi)*.5
  if field([direction*mid])[0][0]>1e-7:lo=mid
  else:hi=mid
 rim.append(direction*lo)
points=list(rim)
for peak in PEAKS:points.append(peak[:2].copy())
ridge_edges=[]
for ridge in RIDGES:
 length=np.linalg.norm(ridge[3:5]-ridge[:2]);prev=None
 for t in np.linspace(0,1,max(3,int(length/.6))):
  q=ridge[:2]*(1-t)+ridge[3:5]*t
  nearest=int(np.argmin(np.linalg.norm(np.asarray(points)-q,axis=1)))
  if np.linalg.norm(points[nearest]-q)<1e-5:idx=nearest
  else:idx=len(points);points.append(q)
  if prev is not None and prev!=idx:ridge_edges.append((prev,idx))
  prev=idx
rng=np.random.default_rng(20260918)
# Variable density favors summits and ridges; no rows, latitude rings or texture.
for attempt in range(23000):
 p=rng.uniform([-10.8,-7.5],[10.0,8.5]);height,owner,ridge,ang=field([p])
 if height[0]<.25:continue
 rel=height[0]/PEAKS[owner[0],2]
 spacing=.46*(1-.40*rel)*(.95-.12*np.clip((ridge[0]-.8)/.4,0,1))
 if np.min(np.linalg.norm(np.asarray(points)-p,axis=1))>=spacing:points.append(p)
uv,_,faces,_,_,_=delaunay_2d_cdt([Vector(p) for p in points],ridge_edges,[list(range(128))],1,1e-7,False)
xy=np.array(uv,dtype=float);heights,owners,ridges,angles=field(xy)
# The footprint constraints are the sole boundary, lying exactly on the base.
for i in range(len(xy)):
 if min(np.linalg.norm(np.array(rim)-xy[i],axis=1))<1e-5:heights[i]=0
verts=np.column_stack((xy[:,0],xy[:,1]*.86,heights)).tolist()
scene=bpy.data.scenes.new('T7 Snow Mountain - Orthographic Study')
bpy.context.window.scene=scene
collection=bpy.data.collections.new('T7 Authored Mountain');scene.collection.children.link(collection)
mesh=bpy.data.meshes.new('T7 continuous faceted massif');mesh.from_pydata(verts,[],faces);mesh.update()
obj=bpy.data.objects.new('T7 Snowcap Massif',mesh);collection.objects.link(obj)

def lin(v):return v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4
for name,rgb in [('T7 Neutral Rock #696B6B',(105/255,107/255,107/255)),('T7 Ivory Snow',(.94,.95,.96))]:
 mat=bpy.data.materials.new(name);mat.use_nodes=True
 node=next(n for n in mat.node_tree.nodes if n.type=='BSDF_PRINCIPLED')
 node.inputs[0].default_value=tuple(lin(v) for v in rgb)+(1,)
 node.inputs[1].default_value=0;node.inputs[2].default_value=1;node.inputs[14].default_value=0
 mat.diffuse_color=tuple(rgb)+(1,);mesh.materials.append(mat)
face_labels=[];body_ids=[]
for poly in mesh.polygons:
 mid=np.mean(np.asarray(verts)[list(poly.vertices)],axis=0)
 h,owner,ridge,angle=field([[mid[0],mid[1]/.86]])
 start=.64+.25*(ridge[0]-1)
 snow=mid[2]/PEAKS[owner[0],2]>=start
 poly.material_index=int(snow);poly.use_smooth=False
 face_labels.append('snow' if snow else 'rock');body_ids.append(int(owner[0]))
obj['reference']='T7-mountain-four-views.png';obj['construction']='One shared triangulated height envelope, variable-density sampling, continuous radial gullies'
obj['snow_boundary']='0.64 + 0.25*(shared ridge - 1); higher on ridges, lower in gullies'
obj['seed']=20260918
# Pack the exact image-generation reference into the editable source.
ref=bpy.data.images.load(str(ROOT/'docs/design/shanhe-luren/mountain-rework/reference/T7-mountain-four-views.png'),check_existing=True);ref.pack()
empty=bpy.data.objects.new('Orthographic modeling reference',None);collection.objects.link(empty)
empty.empty_display_type='IMAGE';empty.data=ref;empty.empty_display_size=21;empty.location=(22,3,8);empty.rotation_euler=(math.pi/2,0,0);empty.hide_render=True
cam_data=bpy.data.cameras.new('T7 Orthographic Camera');cam=bpy.data.objects.new('T7 Orthographic Camera',cam_data);collection.objects.link(cam)
cam.location=(0,-40,14.5);target=Vector((0,0,6.5));cam.rotation_euler=(target-cam.location).to_track_quat('-Z','Y').to_euler();cam_data.type='ORTHO';cam_data.ortho_scale=31.5;scene.camera=cam

def sun(name,location,energy,color):
 data=bpy.data.lights.new(name,'SUN');data.energy=energy;data.color=color;data.angle=.08
 light=bpy.data.objects.new(name,data);collection.objects.link(light);light.location=location;light.rotation_euler=(Vector((0,0,6))-light.location).to_track_quat('-Z','Y').to_euler()
sun('Warm sculpting key',(-24,-8,18),3.6,(1,.93,.82));sun('Cool soft fill',(12,-8,16),.75,(.38,.59,1.0))
world=bpy.data.worlds.new('Reference paper background');world.use_nodes=True
bg=next(n for n in world.node_tree.nodes if n.type=='BACKGROUND');bg.inputs[0].default_value=(.82,.80,.76,1);bg.inputs[1].default_value=.8;scene.world=world
scene.render.engine='BLENDER_EEVEE';scene.render.resolution_x=1920;scene.render.resolution_y=1080;scene.render.resolution_percentage=100;scene.render.image_settings.file_format='PNG'
scene.render.film_transparent=True
scene.render.filepath=str(OUT/'t7-model-orthographic.png')
bpy.context.view_layer.objects.active=obj;obj.select_set(True)
for area in bpy.context.screen.areas:
 if area.type=='VIEW_3D':
  area.spaces.active.region_3d.view_perspective='CAMERA';area.spaces.active.shading.type='MATERIAL'
  area.spaces.active.overlay.show_overlays=False
OUT.mkdir(exist_ok=True,parents=True)
(OUT/'construction.json').write_text(json.dumps({'vertices':len(verts),'triangles':sum(len(f)-2 for f in faces),'snow_face_fraction':face_labels.count('snow')/len(faces),'peaks':PEAKS.tolist(),'seed':20260918,'reference':'T7-mountain-orthographic.png'},indent=2))
print(json.dumps({'scene':scene.name,'mesh':obj.name,'vertices':len(verts),'faces':len(faces),'snow_fraction':face_labels.count('snow')/len(faces)}))
