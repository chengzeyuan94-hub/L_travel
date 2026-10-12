"""Repair skinny triangles in the authored mountain without changing peak heights.
Run after constructing the mesh through Blender MCP; reports actual remaining angles.
"""
import bpy, math, json
import numpy as np
from mathutils import Vector
from mathutils.geometry import delaunay_2d_cdt

obj=next(o for o in bpy.context.scene.objects if o.type=='MESH' and o.name.startswith('T7 Snowcap Massif'))
positions=np.array([v.co[:] for v in obj.data.vertices])
boundary=np.abs(positions[:,2])<1e-5
protected=np.zeros(len(positions),dtype=bool)
for peak in PEAKS:
    target=np.array([peak[0],peak[1]*.86,peak[2]])
    protected[np.argmin(np.linalg.norm(positions-target,axis=1))]=True
history=[]
for iteration in range(100):
    rimids=np.flatnonzero(boundary)
    rimids=rimids[np.argsort(np.arctan2(positions[rimids,1],positions[rimids,0]))]
    uv,_,triangles,orig,_,_=delaunay_2d_cdt([Vector(p[:2]) for p in positions],[],[rimids.tolist()],1,1e-7,True)
    # No intersecting constraints; preserve the exact authored Z of each retained vertex.
    positions=np.array([[p[0],p[1],positions[orig[i][0],2]] for i,p in enumerate(uv)])
    boundary=np.array([boundary[x[0]] for x in orig]);protected=np.array([protected[x[0]] for x in orig])
    tri=np.asarray(triangles,dtype=int);v=positions[tri]
    angles=[]
    for j in range(3):
        a=v[:,(j+1)%3]-v[:,j];b=v[:,(j+2)%3]-v[:,j]
        angles.append(np.degrees(np.arccos(np.clip(np.sum(a*b,axis=1)/(np.linalg.norm(a,axis=1)*np.linalg.norm(b,axis=1)),-1,1))))
    mins=np.min(angles,axis=0);bad=np.flatnonzero(mins<12.05)
    history.append({'iteration':iteration,'faces':len(tri),'minimum_angle':float(mins.min()),'bad_faces':len(bad)})
    if not len(bad):break
    removed=set();touched=set()
    for face_index in bad[np.argsort(mins[bad])]:
        ids=tri[face_index]
        if any(int(x) in touched for x in ids):continue
        pairs=[(np.linalg.norm(positions[ids[a]]-positions[ids[b]]),int(ids[a]),int(ids[b])) for a,b in [(0,1),(1,2),(2,0)]]
        _,a,b=min(pairs)
        eligible=[i for i in (a,b) if not protected[i]]
        if not eligible:eligible=[int(i) for i in ids if not protected[i]]
        if not eligible:continue
        # Prefer removing an interior sample; the perimeter can simplify only if both ends lie on it.
        chosen=min(eligible,key=lambda i:(bool(boundary[i]),i))
        removed.add(chosen);touched.update(int(i) for i in ids)
    if not removed:break
    keep=np.array([i not in removed for i in range(len(positions))]);positions=positions[keep];boundary=boundary[keep];protected=protected[keep]

mesh=obj.data;mesh.clear_geometry();mesh.from_pydata(positions.tolist(),[],triangles);mesh.update()
for poly in mesh.polygons:
    mid=np.mean(positions[list(poly.vertices)],axis=0)
    h,owner,ridge,angle=field([[mid[0],mid[1]/.86]])
    poly.material_index=int(mid[2]/PEAKS[owner[0],2]>=.64+.25*(ridge[0]-1))
    poly.use_smooth=False
(OUT/'topology-repair.json').write_text(json.dumps(history,indent=2))
print(history[-1])
