"""Execute inside the live Blender MCP session after concept and four-view delivery."""
import bpy, math, json, random
from mathutils import Vector
from pathlib import Path
ROOT=Path('/Users/chengzeyuan/Developer/SilkRoad')
layout=json.loads((ROOT/'assets/traveler/terrain/changan-near-patch-layout.json').read_text())
scene=bpy.context.scene
assert scene.name.startswith('Changan Layered Foothill')
for name in ['Changan Layered Near Mountain','Near Mountain Four View Reference']:
 old=bpy.data.objects.get(name)
 if old and old.name in scene.objects:bpy.data.objects.remove(old,do_unlink=True)
# All coordinates below use Godot Y-up; convert only when writing Blender vertices.
source=layout['triangles'];segments=layout['boundary_segments'];rng=random.Random(20260919)
def smooth(a,b,x):
 t=max(0.,min(1.,(x-a)/(b-a)));return t*t*(3-2*t)
def boundary_distance(x,z):
 best=1e6
 for a,b in segments:
  dx,dz=b[0]-a[0],b[2]-a[2];den=dx*dx+dz*dz
  t=max(0.,min(1.,((x-a[0])*dx+(z-a[2])*dz)/den)) if den>1e-12 else 0
  best=min(best,math.hypot(x-a[0]-t*dx,z-a[2]-t*dz))
 return best
def sculpt(x,h,z):
 fade=smooth(0,.6,boundary_distance(x,z))*smooth(.95,1.9,h)
 # Broad attached buttresses, eroded channels and terrace risers share one field.
 phase=z*2.45+.32*x+.35*math.sin(.8*x)
 ridge=.25*math.sin(phase)+.075*math.sin(phase*2+.5)
 level=(h+.10*math.sin(.85*z+.3*x))/.74
 fraction=level-math.floor(level)
 terrace=.74*(smooth(.42,.82,fraction)-fraction)
 return h+fade*(ridge+terrace*.72)
def sample(x,z):
 best=None
 for tr in source:
  a,b,c=tr['v'];den=(b[2]-c[2])*(a[0]-c[0])+(c[0]-b[0])*(a[2]-c[2])
  if abs(den)<1e-10:continue
  u=((b[2]-c[2])*(x-c[0])+(c[0]-b[0])*(z-c[2]))/den
  v=((c[2]-a[2])*(x-c[0])+(a[0]-c[0])*(z-c[2]))/den
  if min(u,v,1-u-v)<-1e-6:continue
  h=u*a[1]+v*b[1]+(1-u-v)*c[1]
  if best is None or h>best:best=h
 return None if best is None else sculpt(x,best,z)
verts=[];faces=[];cols=[];types=[]
def face(points,color,kind):
 i=len(verts);ps=[(p[0],-p[2],p[1]) for p in points]
 # Height-field top faces point upward in Blender.
 if kind=='terrain' and (Vector(ps[1])-Vector(ps[0])).cross(Vector(ps[2])-Vector(ps[0])).z<0:ps.reverse()
 verts.extend(ps);faces.append(tuple(range(i,i+len(ps))));cols.append(tuple(color[:3])+(1.,));types.append(kind)
N=5
for tr in source:
 a,b,c=map(Vector,tr['v']);ca,cb,cc=map(Vector,tr['colors']);pts={};colors={}
 for i in range(N+1):
  for j in range(N+1-i):
   p=a+(b-a)*(i/N)+(c-a)*(j/N);co=ca+(cb-ca)*(i/N)+(cc-ca)*(j/N)
   p.y=sculpt(p.x,p.y,p.z);pts[i,j]=p;colors[i,j]=co
 for i in range(N):
  for j in range(N-i):
   keys=[(i,j),(i+1,j),(i,j+1)];face([pts[k] for k in keys],sum((colors[k] for k in keys),Vector((0,0,0,0)))/3,'terrain')
   if j<N-i-1:
    keys=[(i+1,j),(i+1,j+1),(i,j+1)];face([pts[k] for k in keys],sum((colors[k] for k in keys),Vector((0,0,0,0)))/3,'terrain')
terrain_faces=len(faces)
# Broad, partly buried strata. Grouped ledges cross the slope; quiet spaces remain.
ledges=[(13.6,4.5,1.05,.52,.40),(14.8,5.1,1.12,.50,.46),(16.,5.5,.95,.48,.48),
 (17.3,5.9,1.2,.55,.44),(18.4,6.4,1.12,.54,.46),(19.5,6.9,.96,.47,.42),
 (20.6,7.3,1.10,.58,.47),(21.4,8.,.95,.48,.40),(22.1,8.7,.9,.52,.38),
 (15.0,7.1,1.1,.56,.42),(16.2,7.6,1.15,.59,.48),(17.5,8.2,1.05,.56,.45),
 (18.7,8.8,1.00,.58,.48),(19.8,9.3,.92,.52,.4),(21.0,9.8,1.08,.6,.40),
 (14.4,3.0,.85,.4,.36),(16.0,3.7,1.0,.48,.42),(17.4,4.2,.95,.44,.4),
 (18.8,4.8,1.02,.48,.44),(20.0,5.4,.85,.45,.38),
 (15.2,10.7,.95,.46,.45),(16.5,11.2,1.2,.50,.48),(18.0,11.8,.95,.52,.42)]
rock_groups=[]
def rock(cx,cz,rx,rz,hh,kind='ledge'):
 h=sample(cx,cz)
 if h is None or boundary_distance(cx,cz)<.45:return False
 rot=rng.uniform(-.35,.35);count=7;angles=[2*math.pi*k/count for k in range(count)];rad=[rng.uniform(.88,1.10) for _ in angles]
 rings=[]
 for level,scale,offset in [(-.25,1.06,0),(.25,1.,.04),(.72,.96,-.045),(1.0,.77,.035)]:
  ring=[]
  for k,a in enumerate(angles):
   xx=math.cos(a)*rx*scale*rad[k];zz=math.sin(a)*rz*scale*rad[k]
   x=cx+xx*math.cos(rot)-zz*math.sin(rot)+offset;z=cz+xx*math.sin(rot)+zz*math.cos(rot)
   ground=sample(x,z)
   if ground is None:ground=h-.4
   top=h+hh*.65+hh*.12*math.sin(a*2+rot)
   ground=min(ground,top-.04)
   t=max(0.,min(1.,(level+.25)/1.25))
   ring.append((x,(ground-.16)*(1-t)+top*t,z))
  rings.append(ring)
 stone=(.30,.267,.215) # linear warm neutral rock, lit by the scene only
 for ri in range(3):
  for j in range(count):
   k=(j+1)%count;shade=1+(.025 if ri==1 else -.02)+.035*math.sin(j*1.4)
   # Godot-space XZ ring becomes clockwise in Blender, so reverse side winding.
   face([rings[ri][k],rings[ri][j],rings[ri+1][j],rings[ri+1][k]],[q*shade for q in stone],kind)
 face(list(reversed(rings[-1])),[q*1.10 for q in stone],kind)
 rock_groups.append({'x':cx,'z':cz,'y':h,'height':hh,'type':kind})
 return True
for x,z,rx,rz,h in ledges:rock(x,z,rx,rz,h)
# Sparse larger talus clustered under ledges, rather than evenly scattered noise.
for anchor in [(21.8,8.2),(20.6,6.3),(19.2,5.5),(22.,9.5),(17.4,4.2)]:
 for j in range(4):rock(anchor[0]+rng.uniform(-.5,.5),anchor[1]+rng.uniform(-.5,.5),rng.uniform(.10,.23),rng.uniform(.08,.18),rng.uniform(.14,.28),'talus')
mesh=bpy.data.meshes.new('Changan foothill attached strata mesh');mesh.from_pydata(verts,[],faces);mesh.update()
attr=mesh.color_attributes.new(name='TerrainAlbedo',type='FLOAT_COLOR',domain='CORNER')
for poly,color in zip(mesh.polygons,cols):
 poly.use_smooth=False
 for li in poly.loop_indices:attr.data[li].color=color
mat=bpy.data.materials.new('Changan warm stone and terrain - scene lit');mat.use_nodes=True
bsdf=next(n for n in mat.node_tree.nodes if n.type=='BSDF_PRINCIPLED');bsdf.inputs['Roughness'].default_value=.94
node=mat.node_tree.nodes.new('ShaderNodeVertexColor');node.layer_name=attr.name;mat.node_tree.links.new(node.outputs['Color'],bsdf.inputs['Base Color'])
obj=bpy.data.objects.new('Changan Layered Near Mountain',mesh);scene.collection.objects.link(obj);mesh.materials.append(mat)
obj['concept']=layout['concept'];obj['four_views']=layout['four_views'];obj['source_faces']=len(source);obj['method']='Attached buttress ridges, terrace risers, grouped stratified ledges; exact source boundary seam'
bpy.context.view_layer.objects.active=obj;obj.select_set(True)
# Reference image remains in the authoring scene but is excluded from GLB selection.
ref=bpy.data.objects.new('Near Mountain Four View Reference',None);ref.empty_display_type='IMAGE';ref.data=bpy.data.images.load(str(ROOT/layout['four_views']));ref.empty_display_size=16;ref.location=(35,-7,8);scene.collection.objects.link(ref)
for screen in bpy.data.screens:
 for area in screen.areas:
  if area.type=='VIEW_3D':
   area.spaces.active.region_3d.view_location=(18,-7,3)
   area.spaces.active.region_3d.view_distance=22
   area.spaces.active.region_3d.view_rotation=(.820,.425,.176,.340)
mesh.calc_loop_triangles()
report={'source_faces':len(source),'surface_polygons':terrain_faces,'rock_groups':rock_groups,'vertices':len(mesh.vertices),'polygons':len(mesh.polygons),'triangles':len(mesh.loop_triangles),'concept':layout['concept'],'four_views':layout['four_views'],'authoring':'Blender MCP live execution','boundary_segments':len(segments)}
(ROOT/'docs/reports/traveler-near-mountain-001/evidence/blender-build.json').write_text(json.dumps(report,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='rock_groups'}))
