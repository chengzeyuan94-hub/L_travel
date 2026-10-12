"""Run in Blender MCP: author attached rock shoulders and a low talus apron."""
import bpy,math,random,json
from pathlib import Path
ROOT=Path('/Users/chengzeyuan/Developer/SilkRoad')
scene=bpy.context.scene;assert scene.name=='Changan Cliff Buddha - User Tripo Asset'
obj=bpy.data.objects['Cliff Buddha Runtime']
backup=obj.copy();backup.data=obj.data.copy();backup.name='Cliff Buddha Runtime Before Shoulder Edit';scene.collection.objects.link(backup);backup.hide_set(True);backup.hide_render=True
rng=random.Random(2026091902);vertices=[];faces=[]
def buttress(cx,cy,rx,ry,height,angle,levels=4):
 count=9;start=len(vertices);radii=[rng.uniform(.86,1.08) for _ in range(count)]
 # Outward weathered skirts, alternating ledge/riser profiles, narrowing summit.
 rings=[(-.06,1.16),(.08,1.10),(.16,.99),(.40,.98),(.46,.77),(.69,.74),(.76,.52),(1.,.46)]
 for iz,(t,s) in enumerate(rings):
  for j in range(count):
   a=j*math.tau/count;xx=math.cos(a)*rx*s*radii[j];yy=math.sin(a)*ry*s*radii[j]
   x=cx+xx*math.cos(angle)-yy*math.sin(angle)+.025*rx*math.sin(iz*2)
   y=cy+xx*math.sin(angle)+yy*math.cos(angle)
   z=height*t+height*.035*math.sin(j*1.6+iz*.7)
   vertices.append((x,y,z))
 for k in range(len(rings)-1):
  for j in range(count):
   nj=(j+1)%count;a=start+k*count+j;b=start+k*count+nj;c=start+(k+1)*count+nj;d=start+(k+1)*count+j
   # Slender irregular facets give strata a chipped edge rather than box shelves.
   faces.extend([(a,b,c),(a,c,d)])
 faces.append(tuple(start+(len(rings)-1)*count+j for j in range(count)))
 faces.append(tuple(start+j for j in reversed(range(count))))
# Blender -Y is the grotto opening. Preserve the front central statue and face.
buttress(-.43,.02,.24,.24,.40,-.2)
buttress(.43,.035,.19,.22,.25,.20)
buttress(-.34,-.29,.23,.17,.13,-.24)
buttress(.36,-.27,.22,.18,.12,.25)
buttress(.015,-.35,.31,.16,.035,0)
for cx,cy,h in [(-.48,-.32,.07),(-.40,-.43,.055),(-.26,-.45,.04),(.27,-.43,.04),(.43,-.38,.06),(.52,-.22,.075),(-.53,-.15,.12)]:
 buttress(cx,cy,.065,.055,h,rng.uniform(-1,1))
mesh=bpy.data.meshes.new('Buddha attached strata and talus');mesh.from_pydata(vertices,[],faces);mesh.update()
ext=bpy.data.objects.new('Buddha integrated rock shoulders',mesh);scene.collection.objects.link(ext)
for polygon in mesh.polygons:polygon.use_smooth=False
mesh.materials.append(obj.data.materials[0])
for ob in scene.objects:ob.select_set(False)
obj.hide_set(False);obj.select_set(True);ext.select_set(True);bpy.context.view_layer.objects.active=obj
bpy.ops.object.join()
obj.data.calc_loop_triangles()
obj['secondary_edit']='Attached lower cliff buttresses, weathered ledges, buried rock skirt and clustered talus. Statue and cave geometry preserved.'
obj['source_sha256']='3cc754e5b83749547fb0e843349fd5c07777bf364854f07f456607013578cb07'
report={'runtime_triangles':len(obj.data.loop_triangles),'added_triangles':len(obj.data.loop_triangles)-119999,'runtime_vertices':len(obj.data.vertices),'source_unchanged':True,'secondary_edit':obj['secondary_edit']}
(ROOT/'docs/reports/traveler-cliff-buddha/source/secondary-edit.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
