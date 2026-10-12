"""Ground023: independently authored mainland sample, from the actual017 GLB.

Run Blender --background --factory-startup --python this_file. Never modifies
the production planet. Shared-edge refinement starts on the original triangle
planes; only inland, unprotected heights are reshaped. Runtime COLOR_0 is sRGB
by the existing planet contract, with white material factors.
"""
from __future__ import annotations
import copy
import heapq
import json
import math
import sys
from collections import Counter
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/lowpoly'))
from planet_detail_012 import GLB, logical, normal, digest
from density_017 import route_samples, city_distance

OUT = ROOT / 'docs/design/ground-detail-023'
INPUT = ROOT / 'assets/game/lowpoly/planet/terrain.glb'
SOURCE_SHA = '2382600b2a0e56760ff9f772c678f065a1531852b92292e5582793a11975cdf7'
LAND = 'spherical_continents_and_biomes'
R = 11.0
CORE = (1900., 2730., 300., 800.)
OUTER = (1750., 2860., 220., 960.)


def unit(a):
    return a / np.maximum(np.linalg.norm(a, axis=-1, keepdims=True), 1e-20)


def smooth(a, b, x):
    t = np.clip((x-a)/(b-a), 0, 1)
    return t*t*(3-2*t)


def region(xy):
    x, y = xy.T
    return (smooth(OUTER[0], CORE[0], x)*(1-smooth(CORE[1], OUTER[1], x))
            * smooth(OUTER[2], CORE[2], y)*(1-smooth(CORE[3], OUTER[3], y)))


def visual_region(xy):
    """Visual collar extends beyond the sculpted height field, so an old
    horizontal biome boundary does not reveal the sample's rectangular edge.
    No city/route heights are affected by this shading-only collar.
    """
    x,y=xy.T
    yy=y+18*np.sin((x-2210)/180)
    return (smooth(1710,1880,x)*(1-smooth(2780,2930,x))
            *smooth(175,290,yy)*(1-smooth(925,1090,yy)))


def kd(points):
    tree = KDTree(len(points))
    for i, p in enumerate(points):
        tree.insert(Vector(p), i)
    tree.balance()
    return tree


def load_land(src):
    points, faces, colors, normals, materials, parents = [], [], [], [], [], []
    lookup = {}
    for primitive, positions, source_faces in src.geometry(LAND):
        cc = src.accessor(primitive['attributes']['COLOR_0'])
        nn = src.accessor(primitive['attributes']['NORMAL'])
        remap = []
        for p in positions:
            key = tuple(np.asarray(p, dtype=np.float32))
            if key not in lookup:
                lookup[key] = len(points)
                points.append(tuple(p))
            remap.append(lookup[key])
        for f in source_faces:
            faces.append([remap[i] for i in f])
            colors.append(cc[f]); normals.append(nn[f])
            materials.append(primitive['material']); parents.append(len(parents))
    return (np.asarray(points), np.asarray(faces), np.asarray(colors),
            np.asarray(normals), np.asarray(materials), np.asarray(parents))


def refine(points, faces, colors, normals, materials, parents, selection=None):
    """Red/green refinement: 4 core triangles, conforming 2/3 triangle collar."""
    xy = np.asarray([logical(p) for p in points])
    weights = region(xy)
    selected = (weights[faces].max(axis=1) > 0) if selection is None else selection
    edges = set()
    for f in faces[selected]:
        for a, b in zip(f, np.roll(f, -1)):
            edges.add(tuple(sorted((int(a), int(b)))))
    new_points = list(points)
    mids = {}
    for edge in sorted(edges):
        mids[edge] = len(new_points)
        new_points.append((points[edge[0]]+points[edge[1]])*.5)
    fs, cs, ns, ms, ps = [], [], [], [], []
    eye = np.eye(3)
    for f, color, normal0, mat, parent in zip(faces, colors, normals, materials, parents):
        nodes = list(f)
        bary = [eye[i] for i in range(3)]
        active = []
        for i in range(3):
            edge = tuple(sorted((int(f[i]), int(f[(i+1)%3]))))
            active.append(edge in mids)
            nodes.append(mids.get(edge, -1))
            bary.append((eye[i]+eye[(i+1)%3])*.5)
        count = sum(active)
        if count == 0:
            pieces = [(0, 1, 2)]
        elif count == 3:
            pieces = [(0, 3, 5), (3, 1, 4), (5, 4, 2), (3, 4, 5)]
        elif count == 1:
            i = active.index(True); j = (i+1)%3; k = (i+2)%3
            pieces = [(i, i+3, k), (i+3, j, k)]
        else:
            # Rotate so the two split edges are i->j and j->k.
            i = next(a for a in range(3) if active[a] and active[(a+1)%3])
            j, k = (i+1)%3, (i+2)%3
            pieces = [(j, j+3, i+3), (i, i+3, k), (i+3, j+3, k)]
        for piece in pieces:
            weights0 = np.asarray([bary[i] for i in piece])
            fs.append([nodes[i] for i in piece])
            cs.append(weights0 @ color); ns.append(unit(weights0 @ normal0))
            ms.append(mat); ps.append(parent)
    return (np.asarray(new_points), np.asarray(fs), np.asarray(cs), np.asarray(ns),
            np.asarray(ms), np.asarray(ps), dict(source_faces_selected=int(selected.sum()),
                                              shared_edges_split=len(edges)))


def cities():
    data = json.loads((ROOT/'data/rulesets/lshu_configurable_v1/board_nodes.json').read_text())['items']
    plan = json.loads((ROOT/'docs/design/map-layout-021/placements.json').read_text())
    scale = float(plan.get('city_scale', 1))
    result = []
    for c in data:
        if c['node_type'] != 'CITY':
            continue
        path = ROOT/'docs/design/city-library-019/exports'/f"{c['id']}.glb"
        g = GLB(path)
        positions = np.asarray([p for n in g.doc['nodes'] if 'mesh' in n
                                for _, vv, _ in g.geometry(n['name']) for p in vv])*scale
        xy = [c['map_position'][0], c['map_position'][1]-85]
        n = np.asarray(normal(*xy)); lon = (xy[0]-2048)*math.tau/6144
        east = np.asarray([math.cos(lon), 0, -math.sin(lon)])
        result.append(dict(id=c['id'], logical=xy, origin=n*(R+.08), east=east,
                           south=np.cross(east, n), low=positions[:,[0,2]].min(axis=0),
                           high=positions[:,[0,2]].max(axis=0), scale=scale))
    return result


def river_footprint():
    """Actual021-layout Yamuna ground and water footprint, not every old prop."""
    plan=json.loads((ROOT/'docs/design/map-layout-021/placements.json').read_text())
    item=next(a for a in plan['landmarks'] if a['id']=='yamuna_floodplain')
    path=ROOT/'docs/design/landmark-library-020/exports/yamuna_floodplain.glb'
    g=GLB(path);points=[]
    for node in g.doc['nodes']:
        if 'mesh' not in node:continue
        for primitive,vv,_ in g.geometry(node['name']):
            mat=g.doc['materials'][primitive['material']]['name']
            if mat not in ('earth','grass','grass_light','sand','water_shallow'):continue
            points.extend(np.asarray(vv)[:,[0,2]]*item['scale'])
    ordered=sorted(set(tuple(p) for p in points))
    def cross(o,a,b):return (a[0]-o[0])*(b[1]-o[1])-(a[1]-o[1])*(b[0]-o[0])
    lower=[];upper=[]
    for p in ordered:
        while len(lower)>=2 and cross(lower[-2],lower[-1],p)<=0:lower.pop()
        lower.append(p)
    for p in reversed(ordered):
        while len(upper)>=2 and cross(upper[-2],upper[-1],p)<=0:upper.pop()
        upper.append(p)
    polygon=np.asarray(lower[:-1]+upper[:-1])
    xy=item['logical'];n=np.asarray(normal(*xy));lon=(xy[0]-2048)*math.tau/6144
    east=np.asarray([math.cos(lon),0,-math.sin(lon)]);south=np.cross(east,n)
    angle=math.radians(item['yaw_deg']);e=east*math.cos(angle)-south*math.sin(angle)
    s=east*math.sin(angle)+south*math.cos(angle)
    return dict(origin=n*(R+item['ground_height']),east=e,south=s,polygon=polygon,
                logical=xy,path=str(path.relative_to(ROOT)),sha256=digest(path))


def polygon_distance(points, footprint):
    relative=points-footprint['origin']
    pp=np.stack((relative@footprint['east'],relative@footprint['south']),axis=1)
    polygon=footprint['polygon'];inside=np.ones(len(pp),dtype=bool);distance=np.full(len(pp),np.inf)
    for a,b in zip(polygon,np.roll(polygon,-1,axis=0)):
        edge=b-a;rel=pp-a
        inside &= edge[0]*rel[:,1]-edge[1]*rel[:,0]>=-1e-8
        t=np.clip((rel@edge)/np.dot(edge,edge),0,1)
        distance=np.minimum(distance,np.linalg.norm(rel-t[:,None]*edge,axis=1))
    distance[inside]=0
    return distance


def adjacency(points, faces):
    neighbors = [dict() for _ in points]
    projection = unit(points)*R
    edge_counts = Counter()
    for a, b, c in faces:
        for x, y in ((a,b),(b,c),(c,a)):
            x, y = int(x), int(y)
            edge_counts[tuple(sorted((x,y)))] += 1
            if y not in neighbors[x]:
                d = float(np.linalg.norm(projection[x]-projection[y]))
                neighbors[x][y] = d; neighbors[y][x] = d
    return neighbors, edge_counts


def coast_weight(xy):
    x,y=xy.T
    west=(smooth(1780,1840,x)*(1-smooth(2070,2130,x))
          *smooth(725,755,y)*(1-smooth(905,945,y)))
    east=(smooth(2500,2540,x)*(1-smooth(2720,2770,x))
          *smooth(785,825,y)*(1-smooth(905,940,y)))
    return np.maximum(west,east)


def round_local_coast(points, faces, source_edges):
    """Move one shared boundary curve, not disconnected triangle corners.

    The low coast is rounded in two bounded windows. Roads/cities get an
    additional maximum-displacement margin. A short interior collar follows
    the curve, with global amplitude fallback if any triangle would fold.
    """
    neighbors, edge_counts=adjacency(points,faces)
    boundary=[e for e,n in edge_counts.items() if n==1]
    shore_neighbors={}
    for a,b in boundary:
        shore_neighbors.setdefault(a,[]).append(b)
        shore_neighbors.setdefault(b,[]).append(a)
    xy=np.asarray([logical(p) for p in points]); cw=coast_weight(xy)
    tri=unit(points[faces])*R; centers=unit(tri.mean(axis=1))*R
    radii=np.linalg.norm(tri-centers[:,None,:],axis=2).max(axis=1)
    tree=kd(route_samples(ROOT)[0])
    blocked=np.asarray([tree.find(Vector(c))[2] <= r+.34+.014+.35
                        for c,r in zip(centers,radii)])
    for city in cities():
        near=np.linalg.norm(centers-unit(city['origin'])*R,axis=1)<3
        blocked |= near & (city_distance(centers,city)<=radii+.12+.35)
    fixed=np.zeros(len(points),dtype=bool);fixed[faces[blocked].ravel()]=True
    original_projection=unit(points)*R; projection=original_projection.copy()
    movable=np.zeros(len(points),dtype=bool)
    for i,row in shore_neighbors.items():
        movable[i]=len(row)==2 and cw[i]>0 and not fixed[i]
    for _ in range(32):
        proposed=projection.copy()
        for i in np.flatnonzero(movable):
            average=projection[shore_neighbors[i]].mean(axis=0)
            value=projection[i]+.62*cw[i]*(average-projection[i])
            proposed[i]=unit(value)*R
        displacement=proposed-original_projection
        lengths=np.linalg.norm(displacement,axis=1)
        displacement*=np.minimum(1,.35/np.maximum(lengths,1e-20))[:,None]
        projection=unit(original_projection+displacement)*R
    displacement=projection-original_projection
    # The changed low shoreline is retriangulated with a constrained interior
    # collar below; it no longer relies on retaining the old skinny diagonals.
    coast_ids=set(shore_neighbors)
    for _ in range(0):
        candidate=displacement.copy()
        for i,row in enumerate(neighbors):
            if i in coast_ids or fixed[i] or cw[i]<=0:
                continue
            candidate[i]=np.mean(displacement[list(row)],axis=0)*.88*cw[i]
        displacement=candidate
    displacement[fixed]=0
    factor=1.0
    proposed=unit(original_projection+displacement)*np.linalg.norm(points,axis=1)[:,None]
    unchanged=np.linalg.norm(displacement,axis=1)<1e-12
    proposed[unchanged]=points[unchanged]
    moved=np.linalg.norm(proposed-points,axis=1)>1e-7
    # Rebuild every original cliff edge that has either moved points or a
    # newly curved midpoint; retain all source cliff triangles elsewhere.
    lookup={tuple(np.asarray(p,dtype=np.float32)):i for i,p in enumerate(points)}
    touched=[]
    for (a,b),count in source_edges.items():
        if count!=1:continue
        # All subdivision vertices on an old segment are identifiable before
        # the curve moves; include quarter points from the coastal pass.
        chain=[]
        for t in (0,.25,.5,.75,1):
            p=points[a]*(1-t)+points[b]*t
            i=lookup.get(tuple(np.asarray(p,dtype=np.float32)))
            if i is not None:chain.append(i)
        if any(moved[i] for i in chain):
            touched.append(dict(edge=[int(a),int(b)],chain=chain))
    shore_changed=[int(i) for i in shore_neighbors if moved[i]]
    assert shore_changed, 'Coastal pass did not change any coastline.'
    return proposed, touched, dict(
        west_window=[1780,2130,725,945],east_window=[2500,2770,785,940],
        changed_boundary_vertices=len(shore_changed), changed_collar_vertices=int(moved.sum())-len(shore_changed),
        maximum_world_shift=float(np.linalg.norm(proposed-points,axis=1).max()),
        actual_changed_logical_bounds=[xy[shore_changed].min(axis=0).tolist(),xy[shore_changed].max(axis=0).tolist()],
        replaced_source_coast_edges=len(touched),global_amplitude_factor=factor,
        source_boundaries_outside_windows_unchanged=True,
        route_and_city_protection_extra_displacement_margin=.35,
        method='Shared shoreline curve rounding followed by constrained local retriangulation; exact corresponding radial cliffs replaced. No new islands or boundary loops.')


def coast_retriangulate(before, points, faces, colors, normals, materials, parents):
    """Constrained local CDT permits meaningful shoreline corner cuts.

    Outer patch edges remain exact/shared. Old interior vertices cut off by the
    new shoreline are excluded, instead of folding their triangles or globally
    reducing the entire two-window deformation.
    """
    from mathutils.geometry import delaunay_2d_cdt
    changed=np.linalg.norm(points-before,axis=1)>1e-7
    changed_ids=np.flatnonzero(changed)
    tree=kd(unit(before[changed_ids])*R)
    old_tri=unit(before[faces])*R;center=unit(old_tri.mean(axis=1))*R
    radius=np.linalg.norm(old_tri-center[:,None,:],axis=2).max(axis=1)
    selected=np.asarray([tree.find(Vector(c))[2] < .43+r for c,r in zip(center,radius)])
    # All faces meeting a moved point must be inside the reconstructed patch.
    selected |= changed[faces].any(axis=1)
    _,mask,_,=protect(GLB(INPUT),before,faces,adjacency(before,faces)[1])
    protected=mask['full_route_lane']|mask['actual_019_city_base']|mask['existing_oasis_water_only']
    assert not (protected&changed[faces].any(axis=1)).any(),'Moving coastline entered a fixed route/city face.'
    selected &= ~protected
    counts=Counter(tuple(sorted((int(a),int(b)))) for f in faces[selected]
                   for a,b in zip(f,np.roll(f,-1)))
    boundary=[e for e,n in counts.items() if n==1]
    boundary_ids={i for e in boundary for i in e}
    xy=np.asarray([logical(p) for p in points])
    segments=np.asarray([[xy[a],xy[b]] for a,b in boundary])
    def inside(q):
        x,y=q;aa,bb=segments[:,0],segments[:,1]
        cross=(aa[:,1]>y)!=(bb[:,1]>y)
        x_at=aa[:,0]+(y-aa[:,1])*(bb[:,0]-aa[:,0])/np.where(abs(bb[:,1]-aa[:,1])>1e-14,bb[:,1]-aa[:,1],1e-14)
        return bool(np.count_nonzero(cross&(x<x_at))%2)
    all_ids=sorted(set(faces[selected].ravel()))
    used=[i for i in all_ids if i in boundary_ids or inside(xy[i])]
    local={int(i):j for j,i in enumerate(used)}
    constrained=[(local[a],local[b]) for a,b in boundary]
    coords,_,cdt_faces,origins,_,_=delaunay_2d_cdt([Vector(xy[i]) for i in used],constrained,[],0,1e-5,True)
    pp=list(points); remap=[]
    for coord, origin in zip(coords,origins):
        assert origin, 'Unexpected inserted CDT intersection: coastline constraints cross.'
        # Original coordinates keep float32-exact shared patch boundary points.
        remap.append(int(used[origin[0]]))
    new_faces=[]
    for f in cdt_faces:
        center2=np.asarray([coords[i] for i in f]).mean(axis=0)
        if not inside(center2):continue
        assert len(f)==3
        ids=[remap[i] for i in f]
        t=points[ids]
        if np.dot(np.cross(t[1]-t[0],t[2]-t[0]),t.mean(axis=0))<0:ids.reverse()
        new_faces.append(ids)
    new_faces=np.asarray(new_faces)
    # Projected CDT must preserve every exact patch boundary segment.
    new_counts=Counter(tuple(sorted((int(a),int(b)))) for f in new_faces
                       for a,b in zip(f,np.roll(f,-1)))
    assert {e for e,n in new_counts.items() if n==1}==set(boundary),'CDT patch boundary mismatch.'
    shared_c=np.zeros((len(points),4));num=np.zeros(len(points))
    np.add.at(shared_c,faces.ravel(),colors.reshape(-1,4));np.add.at(num,faces.ravel(),1)
    shared_c/=np.maximum(num[:,None],1)
    source_ids=np.flatnonzero(selected)
    original_centers=before[faces[selected]].mean(axis=1)
    ctree=kd(original_centers)
    mat_ids=np.asarray([source_ids[ctree.find(Vector(points[f].mean(axis=0)))[1]] for f in new_faces])
    t=points[new_faces];n=unit(np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]))
    output=(points,np.concatenate((faces[~selected],new_faces)),
            np.concatenate((colors[~selected],shared_c[new_faces])),
            np.concatenate((normals[~selected],np.repeat(n[:,None,:],3,axis=1))),
            np.concatenate((materials[~selected],materials[mat_ids])),
            np.concatenate((parents[~selected],parents[mat_ids])))
    return (*output,dict(old_patch_triangles=int(selected.sum()),new_patch_triangles=len(new_faces),
                         boundary_segments=len(boundary),exact_shared_boundary=True,
                         old_interior_vertices_discarded=len(all_ids)-len(used),
                         method='Constrained 2D triangulation of shifted spherical coastal patch; exact unchanged inner rim.'))


def protect(src, points, faces, edges):
    tri = unit(points[faces])*R
    centers = unit(tri.mean(axis=1))*R
    radii = np.linalg.norm(tri-centers[:,None,:], axis=2).max(axis=1)
    routes, _ = route_samples(ROOT)
    tree = kd(routes)
    masks = {'full_route_lane': np.asarray([tree.find(Vector(c))[2] <= r+.34+.014
                                          for c,r in zip(centers,radii)])}
    city_mask = np.zeros(len(faces), dtype=bool)
    city_data = cities()
    for city in city_data:
        near = np.linalg.norm(centers-unit(city['origin'])*R, axis=1) < 3
        city_mask |= near & (city_distance(centers, city) <= radii+.12)
    masks['actual_019_city_base'] = city_mask
    coast = {i for edge, count in edges.items() if count == 1 for i in edge}
    masks['coast_adjacent'] = np.asarray([any(int(i) in coast for i in f) for f in faces])
    poolmask = np.zeros(len(faces), dtype=bool)
    for _, vv, ff in src.geometry('oasis_pools'):
        pp = unit(np.asarray(vv))*R
        t = pp[np.asarray(ff)]; cc = unit(t.mean(axis=1))*R
        rr = np.linalg.norm(t-cc[:,None,:], axis=2).max(axis=1)
        for center, radius in zip(cc,rr):
            poolmask |= np.linalg.norm(centers-center,axis=1) <= radii+radius+.025
    masks['existing_oasis_water_only'] = poolmask
    river=river_footprint()
    near=np.linalg.norm(centers-unit(river['origin'])*R,axis=1)<3
    masks['yamuna_actual_ground_and_water_footprint']=near&(polygon_distance(centers,river)<=radii+.035)
    frozen_faces = np.logical_or.reduce(list(masks.values()))
    frozen = np.zeros(len(points), dtype=bool)
    frozen[faces[frozen_faces].ravel()] = True
    return frozen, masks, frozen_faces


def distances(neighbors, frozen):
    d = np.full(len(neighbors), np.inf)
    queue = []
    for i in np.flatnonzero(frozen):
        d[i] = 0; heapq.heappush(queue, (0, int(i)))
    while queue:
        dd, i = heapq.heappop(queue)
        if dd != d[i]:
            continue
        for j, length in neighbors[i].items():
            value = dd+length
            if value < d[j]:
                d[j] = value; heapq.heappush(queue, (value,j))
    return d


def relax(values, neighbors, iterations, amount=.45):
    out = values.copy()
    for _ in range(iterations):
        new = out.copy()
        for i, row in enumerate(neighbors):
            if row:
                ids = list(row); weights = 1/np.maximum(list(row.values()), .03)
                average = np.average(out[ids], axis=0, weights=weights)
                new[i] = out[i]*(1-amount)+average*amount
        out = new
    return out


def bounded_sculpt_field(points, neighbors, raw, editable, maximum_grade=.32):
    """Project only the added erosion field onto a shared-edge slope bound.

    This limits secondary relief to an extra ~18 degrees. It never changes a
    protected point and does not Laplacian-smooth the final carved geometry.
    """
    values=raw.copy();values[~editable]=0
    edges=[(i,j,d) for i,row in enumerate(neighbors) for j,d in row.items() if i<j]
    for iteration in range(48):
        greatest=0.
        for i,j,length in edges:
            difference=values[i]-values[j];excess=abs(difference)-maximum_grade*length
            if excess<=1e-7:continue
            greatest=max(greatest,excess);sign=1 if difference>0 else -1
            if editable[i] and editable[j]:
                values[i]-=sign*excess*.5;values[j]+=sign*excess*.5
            elif editable[i]:values[i]-=sign*excess
            elif editable[j]:values[j]+=sign*excess
        if greatest<1e-6:break
    assert np.max(np.abs(values[~editable]))==0
    max_grade=max(abs(values[i]-values[j])/max(length,1e-20) for i,j,length in edges)
    return values,dict(maximum_additional_edge_grade=float(max_grade),
                       maximum_additional_edge_angle_degrees=math.degrees(math.atan(max_grade)),
                       slope_projection_iterations=iteration+1)


def sculpt_relief(points, faces, materials, src, neighbors, xy, curve, nearest, end, amplitude, current_height):
    """Directional medium-scale cuts, following the existing macro valley.

    A few winding transverse channels cut across a broad shoulder. Their crest
    profiles are asymmetric polygons with wide tops, not per-vertex noise or
    repeated pointed bumps. All inputs are deterministic geometry coordinates.
    """
    curve_world=np.asarray([normal(*q)*R for q in curve])
    arc=np.r_[0.,np.cumsum(np.linalg.norm(np.diff(curve_world,axis=0),axis=1))]
    tangent=unit(np.gradient(curve_world,axis=0))
    right=unit(np.cross(unit(curve_world),tangent))
    s=arc[nearest]
    d=np.sum((unit(points)*R-curve_world[nearest])*right[nearest],axis=1)
    wavelength=1.10+.12*np.sin(s*math.tau/5.4)
    phase=(s+.27*d+.11*np.sin(d*math.tau/2.7))/wavelength
    # Wide inclined cap, a cut shoulder, then a shallow concave trough. The
    # phase itself bends slowly across the slope, preventing parallel combs.
    fraction=np.mod(phase,1.)
    profile=np.interp(fraction,[0,.18,.40,.59,.79,1],[-.80,-.58,.62,.74,.18,-.80])
    flank=np.exp(-((d+.73)/1.12)**4)*end
    # A small separate northern band reads as eroded dry ridges near the
    # Taklamakan; it has the same scale, with the prevailing direction changed.
    x,y=xy.T
    northern=np.exp(-((x-2320)/330)**4-((y-415)/95)**4)*.66
    north_u=(x-2200)*.0114+.31*(y-410)*.0144
    north_v=(y-410)*.0144
    nphase=np.mod((north_u+.11*np.sin(north_v*math.tau/3.2))/1.17,1)
    nprofile=np.interp(nphase,[0,.18,.40,.59,.79,1],[-.80,-.58,.62,.74,.18,-.80])
    incident=np.zeros(len(points));dry=np.zeros(len(points));soil=np.zeros(len(points))
    dry_face=np.asarray([src.doc['materials'][int(i)].get('name') in ('desert0','sand0') for i in materials],float)
    soil_face=np.asarray([src.doc['materials'][int(i)].get('name') in ('desert0','sand0','grass0','forest0','tropical0') for i in materials],float)
    for corner in range(3):
        np.add.at(incident,faces[:,corner],1)
        np.add.at(dry,faces[:,corner],dry_face);np.add.at(soil,faces[:,corner],soil_face)
    dry/=np.maximum(incident,1);soil/=np.maximum(incident,1)
    magnitude=.035+.075*dry
    envelope=np.maximum(flank,northern)*soil
    authored=np.where(flank>=northern,profile*flank,nprofile*northern)
    raw=authored*magnitude*amplitude*soil
    editable=(amplitude>1e-8)&(envelope>.003)&(incident>0)
    added,slope_report=bounded_sculpt_field(points,neighbors,raw,editable)
    added[editable]=np.maximum(added[editable],.052-current_height[editable])
    added[~editable]=0
    # Re-enforce the grade bound if the sea-height floor clipped a trough.
    added,slope_report=bounded_sculpt_field(points,neighbors,added,editable)
    trough=np.clip((-.05-profile)/.75,0,1)*flank
    report=dict(method='Deterministic curved transverse erosion cuts with broad polygonal caps; additional shared-edge grade constrained; no random noise.',
                local_new_triangle_edge_median_world=.22,
                wavelength_world=[.98,1.22],northern_wavelength_world=1.17,
                length_along_valley_world=float(arc[-1]),
                authored_magnitude_desert_world=.110,authored_magnitude_grass_world=.035,
                actual_added_height_min=float(added.min()),actual_added_height_max=float(added.max()),
                changed_vertices=int((np.abs(added)>1e-6).sum()),
                crest_profile_phase=[0,.18,.40,.59,.79,1],crest_profile_height=[-.80,-.58,.62,.74,.18,-.80],
                protected_and_nonsoil_points_unchanged=True,**slope_report)
    return added,envelope,trough,dry,report


def dephase_free_vertices(changed, points, faces, xy, neighbors, frozen, clearance,
                          river_distance, materials, src):
    """Break inherited midpoint rows without authoring another height field.

    The small deterministic offsets lie in each point's tangent plane. Their
    final radii are sampled from the already sculpted, unchanged input surface.
    A single shared-point array and fixed topology keep every common edge shut.
    """
    x,y=xy.T
    def window(bounds, inner):
        return (smooth(bounds[0],inner[0],x)*(1-smooth(inner[1],bounds[1],x))
                *smooth(bounds[2],inner[2],y)*(1-smooth(inner[3],bounds[3],y)))
    north=window((1960,2600,270,550),(2040,2520,325,495))
    plain=window((2150,2460,500,775),(2200,2410,560,705))
    weight=np.maximum(north,plain)*smooth(.08,.45,clearance)*smooth(.30,.85,river_distance)
    soil_face=np.asarray([src.doc['materials'][int(i)].get('name')
                          in ('desert0','sand0','grass0','forest0','tropical0')
                          for i in materials])
    valid=np.zeros(len(points),dtype=bool);valid[faces[soil_face].ravel()]=True
    valid[faces[~soil_face].ravel()]=False
    valid &= ~frozen
    weight[~valid]=0
    q=unit(points)*R
    # Two noncommensurate spatial phases supply bounded tangent directions;
    # there is no RNG state and no phase is applied to the radial height.
    u=np.sin(q@np.asarray([12.9898,7.233,3.117]))+.53*np.sin(q@np.asarray([5.173,17.71,11.127])+1.37)
    v=np.sin(q@np.asarray([7.139,3.173,16.713])+2.41)+.47*np.sin(q@np.asarray([19.271,11.337,4.119]))
    uv=np.stack((u,v),axis=1)/np.maximum(np.linalg.norm(np.stack((u,v),axis=1),axis=1)[:,None],1.)
    lon=(x-2048)*math.tau/6144
    east=np.stack((np.cos(lon),np.zeros(len(x)),-np.sin(lon)),axis=1)
    south=np.cross(east,unit(points))
    shortest=np.asarray([min(row.values()) if row else 0. for row in neighbors])
    distance=np.minimum(.030,.13*shortest)*weight
    offset=(east*uv[:,0,None]+south*uv[:,1,None])*distance[:,None]
    editable=np.linalg.norm(offset,axis=1)>1e-7
    tree=BVHTree.FromPolygons(changed.tolist(),faces.tolist(),all_triangles=True)
    before=changed[faces]
    old_cross=np.cross(before[:,1]-before[:,0],before[:,2]-before[:,0])
    old_areas=np.linalg.norm(old_cross,axis=1)
    factor=1.
    for attempt in range(6):
        candidate=changed.copy()
        for i in np.flatnonzero(editable):
            ray=unit(changed[i]+offset[i]*factor)
            hit,_,_,_=tree.ray_cast(Vector((0,0,0)),Vector(ray),R+3.)
            assert hit is not None, 'Free inland point missed the existing sculpted surface.'
            candidate[i]=hit
        tri=candidate[faces]
        cross=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0])
        area_ratio=np.linalg.norm(cross,axis=1)/np.maximum(old_areas,1e-20)
        outward=np.sum(cross*tri.mean(axis=1),axis=1)>0
        if outward.all() and area_ratio.min()>.72:break
        factor*=.5
    else:raise AssertionError('Small tangent dephasing failed the triangle conditioning bound.')
    assert np.array_equal(candidate[frozen],changed[frozen])
    tangent_shift=np.linalg.norm(unit(candidate)*R-unit(changed)*R,axis=1)
    radial_change=np.linalg.norm(candidate,axis=1)-np.linalg.norm(changed,axis=1)
    moved=tangent_shift>1e-7
    return candidate,dict(
        method='Small deterministic tangent offsets; each moved point ray-samples the pre-offset actual sculpted triangles. No new radial field, colors, vertices or triangles.',
        logical_windows=[[1960,2600,270,550],[2150,2460,500,775]],
        changed_unique_vertices=int((np.linalg.norm(candidate-changed,axis=1)>1e-7).sum()),
        tangential_unique_vertices=int(moved.sum()),maximum_authored_tangent_world=.030,
        maximum_shortest_edge_fraction=.13,global_amplitude_factor=factor,
        actual_tangent_world_min_median_max=[float(tangent_shift[moved].min()),
                                            float(np.median(tangent_shift[moved])),float(tangent_shift.max())],
        resampled_radius_difference_minmax=[float(radial_change.min()),float(radial_change.max())],
        minimum_triangle_area_ratio=float(area_ratio.min()),protected_positions_exact=True,
        shared_position_transform_consistent=True,topology_and_color_arrays_unchanged=True)


def reshape(points, faces, colors, original_normals, materials, src):
    neighbors, edge_counts = adjacency(points, faces)
    frozen, masks, frozen_faces = protect(src, points, faces, edge_counts)
    xy = np.asarray([logical(p) for p in points]); x, y = xy.T
    rw = region(xy)
    vw = visual_region(xy)
    clearance = distances(neighbors, frozen)
    amplitude = rw*smooth(0, .42, clearance)
    river_fixed=np.zeros(len(points),dtype=bool)
    river_fixed[faces[masks['yamuna_actual_ground_and_water_footprint']].ravel()]=True
    river_distance=distances(neighbors,river_fixed)
    amplitude*=smooth(0,.80,river_distance)
    h = np.linalg.norm(points, axis=1)-R
    gentle = relax(h, neighbors, 5, .48)
    # One continuous mountain-foot valley, from the Everest outlet towards
    # Delhi's northeast plain. Its northwest shoulder is intentionally much
    # steeper on the valley side; this is actual relief, not a pair of bumps.
    ts=np.linspace(0,1,161)
    a,b,cc,d=np.asarray([[2460,510],[2450,575],[2290,595],[2250,735]],dtype=float)
    curve=(1-ts[:,None])**3*a+3*(1-ts[:,None])**2*ts[:,None]*b+3*(1-ts[:,None])*ts[:,None]**2*cc+ts[:,None]**3*d
    tangent=3*(1-ts[:,None])**2*(b-a)+6*(1-ts[:,None])*ts[:,None]*(cc-b)+3*ts[:,None]**2*(d-cc)
    right=unit(np.stack((tangent[:,1],-tangent[:,0]),axis=1))
    nearest=np.argmin(np.sum((xy[:,None,:]-curve[None,:,:])**2,axis=2),axis=1)
    signed=np.sum((xy-curve[nearest])*right[nearest],axis=1)
    along=ts[nearest];end=smooth(0,.12,along)*(1-smooth(.80,1,along))
    # The river scene occupies the southeast bank. Put the high shoulder on
    # the northwest side so it runs beside that floodplain, not through it.
    across=signed+54
    width=np.where(across>0,42.,67.)
    shoulder=.46*np.exp(-np.abs(across/width)**1.6)*end
    valley=-.115*np.exp(-(signed/31)**2)*end
    basin=-.025*np.exp(-((x-2185)/210)**2-((y-676)/140)**2)
    sand_weight = np.exp(-((x-2330)/440)**4-((y-395)/175)**4)
    sand = sand_weight*(.052*np.sin((x+.45*y)*math.tau/265)+.024*np.cos((y-.25*x)*math.tau/205))
    field = shoulder+basin+valley+sand
    delta = amplitude*np.clip((gentle-h)*.38+field, -.17, .48)
    delta = np.maximum(delta, (.052-h)*amplitude)
    delta[frozen] = 0
    carved,envelope,trough,dry_fraction,sculpt_report=sculpt_relief(
        points,faces,materials,src,neighbors,xy,curve,nearest,end,amplitude,h+delta)
    delta+=carved
    delta[frozen]=0
    changed = points+unit(points)*delta[:,None]
    changed[frozen] = points[frozen]
    changed = changed.astype(np.float32)
    before_layout=changed
    changed, layout_report=dephase_free_vertices(changed,points,faces,xy,neighbors,
        frozen,clearance,river_distance,materials,src)
    layout_moved_faces=np.max(np.linalg.norm(changed[faces]-before_layout[faces],axis=2),axis=1)>1e-9
    # One averaged color per real point removes same-biome triangle seams.
    color_sum = np.zeros((len(points), 4)); color_count = np.zeros(len(points))
    np.add.at(color_sum, faces.ravel(), colors.reshape(-1,4))
    np.add.at(color_count, faces.ravel(), 1)
    averaged = color_sum/np.maximum(color_count[:,None],1)
    softened = relax(averaged, neighbors, 2, .42)
    # Attenuate small inherited baked-AO dark spots without brightening a whole
    # forest biome or inventing a new lighting pass. Real shadows remain live.
    luminance=softened[:,:3]@np.asarray([.2126,.7152,.0722])
    neighborhood_luminance=relax(luminance,neighbors,3,.48)
    lift=np.clip((neighborhood_luminance-luminance)*.40,0,.022)
    softened[:,:3]=np.clip(softened[:,:3]+lift[:,None],0,1)
    # Soil changes follow the very same valley/shoulder geometry, with modest
    # color influence; the volume must remain readable under neutral shading.
    wet=end*np.exp(-(signed/42)**2)*.24
    dry=end*np.exp(-(across/47)**2)*.18
    softened[:,:3]=softened[:,:3]*(1-wet[:,None])+np.asarray([.56,.62,.31])*wet[:,None]
    softened[:,:3]=softened[:,:3]*(1-dry[:,None])+np.asarray([.75,.61,.34])*dry[:,None]
    cw = vw[faces][...,None]
    new_colors = colors*(1-cw)+softened[faces]*cw
    new_colors[:,:,3] = 1
    triangles = changed[faces]
    face_cross = np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0])
    outward = np.sum(face_cross*triangles.mean(axis=1),axis=1) >= 0
    assert outward.all(), 'Land has inverted triangles.'
    sums = np.zeros_like(points)
    for corner in range(3):
        np.add.at(sums, faces[:,corner], face_cross)
    shared_normals = unit(sums)
    # Real geometric facet normals return on carved crests and dry shoulders.
    # Grass receives less faceting; the trough stays softer for a deliberate
    # contrast. The transition follows the sculpted landform, not face IDs.
    slope = np.sum(unit(face_cross)*unit(triangles.mean(axis=1)),axis=1)
    hardness = np.clip((slope-math.cos(math.radians(54)))/.2,0,1)
    soft_ground=np.asarray([src.doc['materials'][int(mi)].get('name') in ('desert0','grass0','sand0') for mi in materials])
    hardness[soft_ground]=1.
    normal_weight = vw[faces]*hardness[:,None]
    recomputed_flat = unit(face_cross)[:,None,:]
    # Outside the field, exact old corner normals; moved faces start with their
    # actual geometric normal before blending into the shared smooth field.
    base_normals = original_normals.copy()
    moved_faces = (np.max(np.abs(delta[faces]),axis=1)>1e-9)|layout_moved_faces
    base_normals[moved_faces] = np.repeat(recomputed_flat[moved_faces],3,axis=1)
    smooth_result=unit(base_normals*(1-normal_weight[:,:,None])
                       +shared_normals[faces]*normal_weight[:,:,None])
    dry_face=dry_fraction[faces].mean(axis=1)
    carved_face=np.clip(envelope[faces].mean(axis=1),0,1)
    trough_face=np.clip(trough[faces].mean(axis=1),0,1)
    # 0.85–0.95 on strong dry cuts, roughly0.55–0.65 on their grass equivalents.
    facet=(.34+.22*dry_face)+carved_face*(.29+.10*dry_face)
    facet=facet*(1-trough_face)+.30*trough_face
    facet*=vw[faces].mean(axis=1)
    new_normals=unit(smooth_result*(1-facet[:,None,None])
                     +recomputed_flat*facet[:,None,None])
    core_vertices = rw>.999
    report = dict(core_bounds=list(CORE), falloff_bounds=list(OUTER),
                  unique_vertices=len(points), triangles=len(faces),
                  core_vertices=int(core_vertices.sum()),
                  changed_unique_vertices=int((np.abs(delta)>1e-6).sum()),
                  changed_core_vertices=int(((np.abs(delta)>1e-6)&core_vertices).sum()),
                  changed_core_fraction=float(((np.abs(delta)>1e-6)&core_vertices).sum()/max(1,core_vertices.sum())),
                  delta_min=float(delta.min()), delta_max=float(delta.max()),
                  delta_abs_median_changed=float(np.median(np.abs(delta[np.abs(delta)>1e-6]))),
                  fixed_route_clearance_world=.34, fixed_city_clearance_world=.12,
                  protection_fade_world=.42,
                  protection_faces={k:int(v.sum()) for k,v in masks.items()},
                  protected_faces=int(frozen_faces.sum()), protected_vertices=int(frozen.sum()),
                  protected_vertex_position_max_error=float(np.max(np.abs(changed[frozen]-points[frozen]))),
                  edge_incidence=dict(Counter(edge_counts.values())),
                  shared_position_transform_consistent=True,
                  continuous_core_normals=False, continuous_core_colors=True,
                  existing_props_not_height_protected=True,
                  coastline_geometry='Original shoreline positions/planes preserved; compatible coplanar split vertices allowed.',
                  height_model='Inherited017 relief + one curved mountain-foot valley with asymmetric northwest shoulder, a Delhi basin and broad northern wind saddles. The southeast Yamuna ground/water footprint retains its original height with a broad soft collar.',
                  color_model='Spatially filtered inherited sRGB COLOR_0; white materials. No new AO bake.',
                  normal_model='Geometry-derived facet normals weighted by carved crest/grass slope/trough identity; dry cuts strongly faceted, grass moderate and troughs softer. No random per-face normals or colors.')
    report['visual_collar']='Shading/color only: x1710..2930, y175..1090, sinusoidal south taper; height bounds unchanged.'
    report['valley_curve_logical']=[a.tolist(),b.tolist(),cc.tolist(),d.tolist()]
    report['valley_shoulder_model']=dict(shoulder_world=.46,shoulder_offset_logical=54,
                                        inner_width_logical=42,outer_width_logical=67,valley_depth_world=.115,
                                        side='northwest; southeast river bank remains at its original ground height',
                                        method='Cubic curve distance field, continuous end taper, one asymmetric shoulder.')
    river=river_footprint()
    report['yamuna_protection']=dict(asset=river['path'],asset_sha256=river['sha256'],logical=river['logical'],
                                     actual_ground_water_convex_hull_xz=river['polygon'].tolist(),
                                     geometric_clearance_world=.035,soft_collar_world=.80,
                                     protected_triangles=int(masks['yamuna_actual_ground_and_water_footprint'].sum()),
                                     method='Full terrain triangles overlapping the actual ground/water hull remain at old height; an independent broad collar fades the new shoulder.')
    report['sculpted_facets']=sculpt_report
    report['sculpted_facets']['normal_facet_weight_minmax']=[float(facet.min()),float(facet.max())]
    report['free_vertex_layout']=layout_report
    return changed, new_colors, new_normals, report


def revised_cliffs(src, old_points, points, faces, colors, touched):
    target={tuple(row['edge']) for row in touched}
    tree=kd(unit(old_points)*R)
    positions=[]; cc=[]; nn=[]; removed=0; source_count=0
    reference_colors={}
    for primitive, vv, ff in src.geometry('radial_coastal_cliffs'):
        source_colors=src.accessor(primitive['attributes']['COLOR_0'])
        source_normals=src.accessor(primitive['attributes']['NORMAL'])
        material=primitive['material']
        nearest=[tree.find(Vector(unit(np.asarray(p))*R)) for p in vv]
        for face in ff:
            source_count+=1
            ids=tuple(sorted(set(nearest[i][1] for i in face)))
            exact=max(nearest[i][2] for i in face)<1e-4
            if exact and ids in target:
                removed+=1;reference_colors[ids]=source_colors[face].mean(axis=0)
                continue
            positions.extend(np.asarray(vv)[face]);cc.extend(source_colors[face]);nn.extend(source_normals[face])
    assert removed==len(target)*2,(removed,len(target),'Original selected cliffs must match the exact coastline.')
    shared_colors=np.zeros((len(points),4));count=np.zeros(len(points))
    np.add.at(shared_colors,faces.ravel(),colors.reshape(-1,4));np.add.at(count,faces.ravel(),1)
    shared_colors/=np.maximum(count[:,None],1)
    added=0
    for row in touched:
        fallback=reference_colors[tuple(row['edge'])]
        for a,b in zip(row['chain'],row['chain'][1:]):
            pa,pb=points[a],points[b]; ba=unit(pa)*(R+.012);bb=unit(pb)*(R+.012)
            # Determine outward coastal side from its actual adjacent land face.
            adjacent=next(f for f in faces if a in f and b in f)
            land_center=points[adjacent].mean(axis=0)
            quad=[pa,ba,bb,pb]
            face_normal=np.cross(ba-pa,bb-pa)
            if np.dot(face_normal,land_center-(pa+pb)*.5)>0:
                quad.reverse()
                cols=[shared_colors[b],fallback,fallback,shared_colors[a]]
            else:cols=[shared_colors[a],fallback,fallback,shared_colors[b]]
            for face in ((0,1,2),(0,2,3)):
                pp=np.asarray([quad[i] for i in face]);normal0=unit(np.cross(pp[1]-pp[0],pp[2]-pp[0]))
                positions.extend(pp);cc.extend([cols[i] for i in face]);nn.extend([normal0]*3);added+=1
    return dict(name='radial_coastal_cliffs',points=np.asarray(positions,dtype=np.float32),
                colors=np.asarray(cc,dtype=np.float32),normals=np.asarray(nn,dtype=np.float32),
                faces=np.arange(len(positions)).reshape(-1,3),material=int(material),
                report=dict(source_triangles=source_count,kept_source_triangles=source_count-removed,
                            removed_local_triangles=removed,added_local_triangles=added,
                            final_triangles=len(positions)//3,
                            unchanged_cliff_triangle_attributes_preserved=True))


def export_glb(src, points, faces, colors, normals, materials, path, cliff=None):
    result = object.__new__(GLB)
    result.binary = bytearray()
    result.doc = dict(asset={'version':'2.0','generator':'Ground023 actual017 land refinement'},
                      scenes=[{'nodes':[0]}],scene=0,nodes=[{'name':LAND,'mesh':0}],
                      meshes=[{'name':LAND,'primitives':[]}], materials=[],accessors=[],
                      bufferViews=[],buffers=[{'byteLength':0}])
    for material in np.unique(materials):
        selected = materials==material
        mat = copy.deepcopy(src.doc['materials'][int(material)])
        mat['pbrMetallicRoughness']['baseColorFactor'] = [1,1,1,1]
        mat['pbrMetallicRoughness']['metallicFactor'] = 0
        mi = len(result.doc['materials']); result.doc['materials'].append(mat)
        p = points[faces[selected]].reshape(-1,3)
        primitive = {'attributes':{'POSITION':result.add_accessor(p),
                                   'NORMAL':result.add_accessor(normals[selected].reshape(-1,3)),
                                   'COLOR_0':result.add_accessor(colors[selected].reshape(-1,4))},
                     'indices':result.add_accessor(np.arange(len(p)),index=True),
                     'material':mi,'mode':4}
        result.doc['meshes'][0]['primitives'].append(primitive)
    if cliff is not None:
        mi=len(result.doc['materials']);mat=copy.deepcopy(src.doc['materials'][cliff['material']])
        mat['pbrMetallicRoughness']['baseColorFactor']=[1,1,1,1]
        result.doc['materials'].append(mat)
        primitive=dict(attributes={'POSITION':result.add_accessor(cliff['points']),
                                   'NORMAL':result.add_accessor(cliff['normals']),
                                   'COLOR_0':result.add_accessor(cliff['colors'])},
                       indices=result.add_accessor(cliff['faces'].ravel(),index=True),material=mi,mode=4)
        result.doc['nodes'].append(dict(name=cliff['name'],mesh=1))
        result.doc['meshes'].append(dict(name=cliff['name'],primitives=[primitive]))
        result.doc['scenes'][0]['nodes'].append(1)
    result.save(path)


def source_blend(src, points, faces, colors, normals, materials, path, cliff=None):
    bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
    p = points[:,[0,2,1]].copy(); p[:,1] *= -1
    n = normals[:,:,[0,2,1]].copy(); n[:,:,1] *= -1
    mesh = bpy.data.meshes.new(LAND)
    mesh.from_pydata(p.tolist(), [], faces.tolist()); mesh.update()
    mesh.validate(verbose=True)
    assert len(mesh.polygons)==len(faces)
    obj = bpy.data.objects.new(LAND,mesh); bpy.context.collection.objects.link(obj)
    col = mesh.color_attributes.new(name='Col',type='FLOAT_COLOR',domain='CORNER')
    col.data.foreach_set('color', colors.astype(np.float32).ravel())
    material_map = {}
    for material in np.unique(materials):
        name = src.doc['materials'][int(material)]['name']
        mat = bpy.data.materials.new(name); mat.use_nodes=True
        nodes = mat.node_tree.nodes; bsdf = nodes.get('Principled BSDF')
        vc = nodes.new('ShaderNodeVertexColor'); vc.layer_name='Col'
        gamma = nodes.new('ShaderNodeGamma'); gamma.inputs['Gamma'].default_value=2.2
        mat.node_tree.links.new(vc.outputs['Color'],gamma.inputs['Color'])
        mat.node_tree.links.new(gamma.outputs['Color'],bsdf.inputs['Base Color'])
        bsdf.inputs['Roughness'].default_value=src.doc['materials'][int(material)].get('pbrMetallicRoughness',{}).get('roughnessFactor',1.)
        mat['runtime_color_contract']='GLB COLOR_0 deliberately sRGB; white albedo; this preview converts to linear.'
        material_map[int(material)] = len(mesh.materials); mesh.materials.append(mat)
    for poly, mi in zip(mesh.polygons,materials):
        poly.material_index=material_map[int(mi)]; poly.use_smooth=True
    # Explicit normal fans preserve the authored corner normals in the source
    # rather than letting Blender average them across implicit smooth fans.
    for edge in mesh.edges:edge.use_edge_sharp=True
    mesh.normals_split_custom_set(n.reshape(-1,3).tolist())
    obj['source_terrain_sha256']=SOURCE_SHA
    obj['stage']='TASK-GROUND-DETAIL-023; isolated sample asset, not production'
    obj['projection']='GodotYup=(BlenderX,BlenderZ,-BlenderY), R11'
    obj['generated_glb']=str(OUT/'exports/ground.glb')
    bpy.context.view_layer.objects.active=obj; obj.select_set(True)
    if cliff is not None:
        cp=cliff['points'][:,[0,2,1]].copy();cp[:,1]*=-1
        cn=cliff['normals'][:,[0,2,1]].copy();cn[:,1]*=-1
        cm=bpy.data.meshes.new(cliff['name']);cm.from_pydata(cp.tolist(),[],cliff['faces'].tolist());cm.update()
        co=bpy.data.objects.new(cliff['name'],cm);bpy.context.collection.objects.link(co)
        ca=cm.color_attributes.new(name='Col',type='FLOAT_COLOR',domain='CORNER')
        ca.data.foreach_set('color',cliff['colors'].ravel())
        # Same sRGB preview conversion as the mainland, in one coast material.
        cm.materials.append(mesh.materials[0].copy());cm.materials[0].name='coast0'
        for poly in cm.polygons:poly.use_smooth=True
        cm.normals_split_custom_set(cn.tolist())
        co['local_coast_revision']='Two023 windows; other012 coastal geometry retained.'
    bpy.ops.wm.save_as_mainfile(filepath=str(path))


def main():
    assert digest(INPUT)==SOURCE_SHA, 'Source changed. Rebase deliberately; never stack deformations.'
    for sub in ('exports','source'):
        (OUT/sub).mkdir(parents=True,exist_ok=True)
    src = GLB(INPUT)
    p, f, c, n, m, parent = load_land(src)
    original_count = len(f)
    original_edge_counts = adjacency(p,f)[1]
    original_core = int((region(np.asarray([logical(v) for v in p[f].mean(axis=1)]))>.999).sum())
    p,f,c,n,m,parent, refinement = refine(p,f,c,n,m,parent)
    # Only the natural shore receives another subdivision level. This produces
    # short rounded segments without uniformly densifying the whole sample.
    boundary_edges=adjacency(p,f)[1]
    shore_ids={i for e,count in boundary_edges.items() if count==1 for i in e}
    weights=coast_weight(np.asarray([logical(v) for v in p]))
    coastal_faces=np.asarray([any(i in shore_ids and weights[i]>0 for i in face) for face in f])
    p,f,c,n,m,parent, coastal_refinement = refine(p,f,c,n,m,parent,coastal_faces)
    new_edge_counts=adjacency(p,f)[1]
    assert max(new_edge_counts.values())<=2, 'Refinement produced non-manifold edges.'
    before_coast=p.copy()
    p,touched,coast_report=round_local_coast(p,f,original_edge_counts)
    p,f,c,n,m,parent,coast_cdt=coast_retriangulate(before_coast,p,f,c,n,m,parent)
    p,c,n,report=reshape(p,f,c,n,m,src)
    cliff=revised_cliffs(src,before_coast,p,f,c,touched)
    glb_path=OUT/'exports/ground.glb'; blend_path=OUT/'source/ground.blend'
    export_glb(src,p,f,c,n,m,glb_path,cliff)
    source_blend(src,p,f,c,n,m,blend_path,cliff)
    report.update(schema='silkroad.ground-detail023.v1', status='coastal_renderable_candidate',
                  source_path=str(INPUT.relative_to(ROOT)),source_sha256=SOURCE_SHA,
                  source_land_triangles=original_count, source_core_triangles=original_core,
                  added_triangles=len(f)-original_count, surfaces=len(np.unique(m))+1,
                  total_export_triangles=len(f)+cliff['report']['final_triangles'],
                  refinement=refinement, coastal_refinement=coastal_refinement,
                  coast=coast_report,cliffs=cliff['report'],
                  coastal_retriangulation=coast_cdt,
                  coastline_geometry='Two bounded coastline windows rounded with compatible fine triangles and exact corresponding radial cliff replacement; other shores unchanged.',
                  source_edge_incidence=dict(Counter(original_edge_counts.values())),
                  glb=str(glb_path.relative_to(ROOT)),glb_sha256=digest(glb_path),
                  blend=str(blend_path.relative_to(ROOT)),blend_sha256=digest(blend_path),
                  dependencies={str(path.relative_to(ROOT)):digest(path) for path in
                                (Path(__file__),ROOT/'tools/lowpoly/planet_detail_012.py',ROOT/'tools/lowpoly/density_017.py')},
                  notes=['Complete mainland and coastal-cliff replacement meshes exported; production water and all production assets unchanged.',
                         'Current019 city footprints at layout scale .82 and full route corridors keep old height.',
                         'Existing props and landmarks must be grounded to this new mesh by the023 preview.',
                         'No claim of final visual acceptance or performance validation.'])
    (OUT/'terrain-report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2),flush=True)


if __name__=='__main__':
    main()
