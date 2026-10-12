"""Inspect geometric islands in untouched rocks; run with isolated Blender."""
import bpy
import json
import pathlib
from collections import defaultdict
from mathutils import Vector
from mathutils.kdtree import KDTree

ROOT = pathlib.Path(__file__).resolve().parents[3]
REPORT = ROOT / 'docs/reports/traveler-panti-001/assets/rocks'
REPORT.mkdir(parents=True, exist_ok=True)

def geometric_islands(mesh, tolerance=1e-6):
    # FBX UV seams duplicate vertex IDs. Match coincident positions for analysis
    # only; never weld or change UVs on the delivered mesh.
    parent = list(range(len(mesh.vertices)))
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    def union(a,b):
        a,b=find(a),find(b)
        if a != b: parent[b]=a
    tree=KDTree(len(mesh.vertices))
    for v in mesh.vertices: tree.insert(v.co,v.index)
    tree.balance()
    for v in mesh.vertices:
        for _co,other,_distance in tree.find_range(v.co,tolerance):
            if other<v.index: union(v.index,other)
    position_ids=[find(v.index) for v in mesh.vertices]
    for e in mesh.edges: union(*e.vertices)
    groups=defaultdict(list)
    for v in mesh.vertices: groups[find(v.index)].append(v.index)
    mesh.calc_loop_triangles()
    result=[]
    for ids in groups.values():
        idset=set(ids)
        triangles=[tri for tri in mesh.loop_triangles if tri.vertices[0] in idset]
        lo=[min(mesh.vertices[v].co[d] for v in ids) for d in range(3)]
        hi=[max(mesh.vertices[v].co[d] for v in ids) for d in range(3)]
        # Signed-volume integral; exact for a consistently oriented closed shell.
        center=Vector([(lo[d]+hi[d])*.5 for d in range(3)])
        volume=0.0
        edge_counts=defaultdict(int)
        for tri in triangles:
            p=[mesh.vertices[v].co-center for v in tri.vertices]
            volume+=p[0].dot(p[1].cross(p[2]))/6
            keys=[position_ids[v] for v in tri.vertices]
            for j in range(3): edge_counts[tuple(sorted((keys[j],keys[(j+1)%3])))]+=1
        result.append({'vertex_ids':ids,'vertices':len(ids),'triangles':len(triangles),
                       'bounds_blender_xyz':[lo,hi],
                       'signed_volume':volume,'absolute_volume':abs(volume),
                       'boundary_edges':sum(n==1 for n in edge_counts.values()),
                       'nonmanifold_edges':sum(n>2 for n in edge_counts.values())})
    return sorted(result,key=lambda x:x['triangles'],reverse=True)

if __name__=='__main__':
    report={}
    for asset in ('rock01','rock02'):
        for ob in list(bpy.data.objects): bpy.data.objects.remove(ob,do_unlink=True)
        bpy.ops.import_scene.fbx(filepath=str(ROOT/'assets/traveler/panti'/f'{asset}-raw.fbx'),use_anim=False)
        meshes=[ob for ob in bpy.context.scene.objects if ob.type=='MESH']
        assert len(meshes)==1
        ob=meshes[0]
        bpy.context.view_layer.objects.active=ob
        ob.select_set(True)
        bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
        islands=geometric_islands(ob.data)
        report[asset]=[{k:v for k,v in row.items() if k!='vertex_ids'} for row in islands]
    (REPORT/'source-islands.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
