"""Original low-poly authoring via Blender MCP, after concept and orthographic sheet."""
import bpy,math,random,json,bmesh
from mathutils import Vector
from mathutils.geometry import delaunay_2d_cdt
from pathlib import Path
ROOT=Path('/Users/chengzeyuan/Developer/SilkRoad');rng=random.Random(2026091911)
name='Changan Low Polygon Cliff Buddha'
scene=bpy.data.scenes.get(name) or bpy.data.scenes.new(name);bpy.context.window.scene=scene
for ob in list(scene.objects):bpy.data.objects.remove(ob,do_unlink=True)
verts=[];faces=[];mats=[];groups=[]
def face(points,material=0,group='rock',hint=None):
 p=[Vector(q) for q in points]
 if hint and (p[1]-p[0]).cross(p[2]-p[0]).dot(Vector(hint))<0:p.reverse()
 k=len(verts);verts.extend(tuple(q) for q in p);faces.append(tuple(range(k,k+len(p))));mats.append(material);groups.append(group)
def inside(p,poly):
 x,y=p;hit=False
 for a,b in zip(poly,poly[1:]+poly[:1]):
  if (a[1]>y)!=(b[1]>y) and x<(b[0]-a[0])*(y-a[1])/(b[1]-a[1])+a[0]:hit=not hit
 return hit
outer=[(-.69,0),(-.60,.16),(-.56,.31),(-.48,.34),(-.48,.48),(-.39,.51),(-.38,.68),(-.27,.72),(-.22,.82),(-.10,.76),(-.055,.69),(.09,.66),(.15,.59),(.28,.53),(.30,.38),(.42,.33),(.48,.17),(.61,.12),(.70,0)]
inner=[(-.23,.105),(.23,.105),(.224,.38),(.19,.51),(.13,.60),(.04,.634),(-.06,.63),(-.15,.59),(-.218,.49),(-.25,.31)]
points=outer+inner;edges=[]
for off,poly in [(0,outer),(len(outer),inner)]:
 edges.extend((off+i,off+(i+1)%len(poly)) for i in range(len(poly)))
for _ in range(250):
 p=(rng.uniform(-.66,.68),rng.uniform(.01,.80))
 if inside(p,outer) and not inside(p,inner) and min(math.dist(p,q) for q in points)>.065:points.append(p)
rv,re,rf,*_=delaunay_2d_cdt([Vector(p) for p in points],edges,[],0,1e-6)
def front(x,z):
 return -.115-.065*math.sin(7*x+3*z)-.025*math.cos(19*x-5*z)
for f in rf:
 p=[rv[i] for i in f];mid=sum(p,Vector((0,0)))/len(p)
 if inside(mid,outer) and not inside(mid,inner):face([(q.x,front(q.x,q.y),q.y) for q in p],0,'cliff',(0,-1,0))
# Rear slope and outer sidewalls form one thick natural upthrust mass.
back=[(x*.88,.28+.035*math.sin(i*1.4),z*.90) for i,(x,z) in enumerate(outer)]
for i,(x,z) in enumerate(outer):
 j=(i+1)%len(outer);a=(x,front(x,z),z);b=(outer[j][0],front(*outer[j]),outer[j][1]);face([a,back[i],back[j],b],0,'rock perimeter')
for i in range(len(back)):
 face([(.0,.32,.32),back[i],back[(i+1)%len(back)]],0,'rear',(0,1,0))
# The opening leads to a recessed rock wall, not a through-hole or separate arch.
recess=[(x*.88,.045,(z-.34)*.90+.34) for x,z in inner]
for i,(x,z) in enumerate(inner):
 j=(i+1)%len(inner);face([(x,front(x,z),z),(inner[j][0],front(*inner[j]),inner[j][1]),recess[j],recess[i]],0,'cave wall')
for i in range(len(recess)):face([(0,.065,.34),recess[i],recess[(i+1)%len(recess)]],0,'cave back',(0,-1,0))
def rings_mesh(rings,count,mat=1,group='Buddha',phase=0):
 rings3=[]
 for cx,cy,z,rx,ry in rings:
  rings3.append([(cx+rx*math.cos(phase+math.tau*j/count),cy+ry*math.sin(phase+math.tau*j/count),z) for j in range(count)])
 for a,b in zip(rings3,rings3[1:]):
  for j in range(count):face([a[j],a[(j+1)%count],b[(j+1)%count],b[j]],mat,group)
 face(list(reversed(rings3[0])),mat,group,(0,0,-1));face(rings3[-1],mat,group,(0,0,1))
def ellipsoid(center,radii,mat=1,group='Buddha',segments=10,lat=5):
 cx,cy,cz=center;rx,ry,rz=radii
 rr=[]
 for k in range(lat+1):
  a=-math.pi/2+math.pi*k/lat;rr.append((cx,cy,cz+rz*math.sin(a),max(.0001,rx*math.cos(a)),max(.0001,ry*math.cos(a))))
 rings_mesh(rr,segments,mat,group,math.pi/segments)
# Integral irregular seat and rock shoulders use a small number of large planes.
def crag(cx,cy,h,rx,ry,mat=0):
 rr=[]
 for t,s in [(0,1.15),(.32,1.0),(.58,.86),(.72,.72),(1,.52)]:rr.append((cx+.025*rx*math.sin(t*8),cy,h*t-.012,rx*s,ry*s))
 rings_mesh(rr,7,mat,'rock buttress',rng.uniform(0,.4))
crag(0,-.17,.125,.25,.16)
crag(-.43,-.16,.32,.16,.14);crag(.40,-.12,.22,.15,.13)
crag(-.54,-.055,.20,.15,.17);crag(.52,.02,.13,.14,.15)
# Body, robe, cross-legged seat: broad faceted volumes, no inherited Tripo geometry.
rings_mesh([(0,-.045,.19,.10,.06),(0,-.045,.25,.105,.068),(0,-.02,.33,.12,.066),(0,-.008,.386,.13,.061),(0,.0,.41,.085,.045)],10,1,'torso',math.pi/10)
ellipsoid((-.105,-.116,.175),(.119,.081,.060),1,'crossed left leg',10,4)
ellipsoid((.105,-.117,.171),(.119,.084,.057),1,'crossed right leg',10,4)
ellipsoid((.055,-.174,.152),(.10,.045,.03),1,'crossed foot',8,3)
ellipsoid((-.055,-.183,.162),(.09,.034,.028),1,'crossed foot',8,3)
# Angular bent sleeves join shoulder to lap, leaving triangular gaps at elbows.
for side in [-1,1]:
 rings_mesh([(side*.105,-.008,.386,.052,.05),(side*.139,-.035,.31,.043,.048),(side*.13,-.10,.257,.037,.032),(side*.07,-.137,.242,.034,.024)],8,1,'sleeve',math.pi/8)
ellipsoid((-.021,-.143,.247),(.045,.030,.014),1,'hands in lap',8,3)
ellipsoid((.025,-.147,.253),(.038,.027,.013),1,'hands in lap',8,3)
rings_mesh([(0,-.012,.396,.034,.031),(0,-.01,.445,.035,.029)],8,1,'neck')
# Deliberately sparse facial topology: chin, jaw, cheeks, temple, forehead.
rings_mesh([(0,-.022,.437,.030,.029),(0,-.024,.451,.046,.042),(0,-.017,.477,.059,.054),(0,-.011,.514,.061,.050),(0,-.004,.539,.053,.044),(0,.001,.551,.038,.035)],12,1,'face',math.pi/12)
for side in [-1,1]:ellipsoid((side*.064,-.011,.485),(.012,.017,.039),1,'elongated ear',6,4)
rings_mesh([(0,.004,.533,.058,.045),(0,.006,.552,.053,.042),(0,.007,.57,.027,.025)],10,2,'polygon hair cap',math.pi/10)
ellipsoid((0,.008,.580),(.024,.022,.021),2,'ushnisha',8,3)
# Wedge nose and closed eye cuts, readable at game-view scale.
face([(-.009,-.063,.508),(.009,-.063,.508),(0,-.091,.478)],1,'nose',(0,-1,0))
face([(-.009,-.063,.508),(0,-.091,.478),(-.012,-.07,.473)],1,'nose',(0,-1,0))
face([(.009,-.063,.508),(.012,-.07,.473),(0,-.091,.478)],1,'nose',(0,-1,0))
for side in [-1,1]:
 x=side*.029
 face([(x-.018,-.065,.497),(x,-.070,.494),(x+.018,-.065,.497),(x+.017,-.065,.494),(x,-.071,.491),(x-.017,-.065,.494)],3,'closed eyelid',(0,-1,0))
face([(-.016,-.063,.459),(0,-.072,.458),(.016,-.063,.459),(.009,-.065,.455),(-.009,-.065,.455)],3,'closed mouth',(0,-1,0))
# Four broad robe fold ridges instead of texture or dozens of fine incisions.
for a,b,c in [((.072,-.065,.398),(.018,-.092,.335),(-.081,-.107,.252)),((.088,-.063,.378),(.037,-.092,.311),(-.045,-.113,.233)),((.094,-.061,.348),(.064,-.096,.287),(.025,-.117,.226))]:
 face([a,(b[0]+.013,b[1]-.010,b[2]),c,b],1,'robe fold',(0,-1,0))
# The fringe is conformed to actual map terrain on import; not a flat display plinth.
N=22;inner_ground=[];outer_ground=[]
for j in range(N):
 a=j*math.tau/N;r=1+.07*math.sin(j*2.1)
 inner_ground.append((.55*math.cos(a),.30*math.sin(a)-.05,.014))
 outer_ground.append((.82*r*math.cos(a),.60*r*math.sin(a)-.04,-.014))
for j in range(N):
 k=(j+1)%N;face([inner_ground[j],outer_ground[j],outer_ground[k]],4,'ground skirt',(0,0,1));face([inner_ground[j],outer_ground[k],inner_ground[k]],4,'ground skirt',(0,0,1))
for x,y,h,r in [(-.5,-.36,.09,.085),(-.34,-.43,.055,.058),(.31,-.39,.07,.073),(.57,-.25,.08,.072),(-.64,.11,.095,.072),(.64,.08,.06,.06)]:crag(x,y,h,r,r*.8)
mesh=bpy.data.meshes.new('Original broad facet cliff and carved Buddha');mesh.from_pydata(verts,[],faces);mesh.update()
obj=bpy.data.objects.new('Lowpoly Cliff Buddha',mesh);scene.collection.objects.link(obj)
def linear(s):return s/12.92 if s<=.04045 else ((s+.055)/1.055)**2.4
for label,hexvalue in [('Rock','8d8779'),('Carved Stone','aaa18e'),('Hair Stone','898273'),('Carved Creases','777064'),('Ground Apron','a18f63')]:
 mat=bpy.data.materials.new('LP Buddha '+label);mat.use_nodes=True;bsdf=next(n for n in mat.node_tree.nodes if n.type=='BSDF_PRINCIPLED');rgb=[int(hexvalue[i:i+2],16)/255 for i in (0,2,4)];bsdf.inputs['Base Color'].default_value=tuple(linear(c) for c in rgb)+(1,);bsdf.inputs['Roughness'].default_value=.94;mat.diffuse_color=tuple(rgb)+(1,);mesh.materials.append(mat)
for p,mi in zip(mesh.polygons,mats):p.material_index=mi;p.use_smooth=False
obj['original_authoring']=True;obj['source']='Concept and four views, authored via Blender MCP; no Tripo geometry'
obj['concept']='docs/reports/traveler-cliff-buddha-lowpoly/concept/lowpoly-cliff-buddha-concept.png'
bpy.context.view_layer.objects.active=obj;obj.select_set(True)
for screen in bpy.data.screens:
 for area in screen.areas:
  if area.type=='VIEW_3D':
   area.spaces.active.region_3d.view_location=(0,0,.38);area.spaces.active.region_3d.view_distance=1.8;area.spaces.active.region_3d.view_rotation=(.7071068,.7071068,0,0)
mesh.calc_loop_triangles();counts={}
for g in groups:counts[g]=counts.get(g,0)+1
report={'triangles':len(mesh.loop_triangles),'polygons':len(mesh.polygons),'vertices':len(mesh.vertices),'materials':len(mesh.materials),'groups':counts,'original_authoring':True,'flat_shaded':True}
(ROOT/'docs/reports/traveler-cliff-buddha-lowpoly/evidence/blender-build.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
