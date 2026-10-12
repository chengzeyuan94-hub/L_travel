"""Deterministic Density017 relief and corridor props, preserving source topology.

Blender --background --factory-startup --python tools/lowpoly/density_017.py --
--output /tmp/silkroad-density-017/candidate [--apply]
Default writes candidates only. --apply deploys terrain/placements and updates
just the land object in planet.blend. Old 007/012 audits and snapshots are not
rewritten. All original non-land buffers, material values, indices and RNG
fingerprints remain unchanged.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import heapq
import json
import math
import random
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector, Matrix
from mathutils.kdtree import KDTree
from mathutils.bvhtree import BVHTree

ROOT = Path(__file__).resolve().parents[2]
if not (ROOT / 'project.godot').exists():
    ROOT = Path.cwd()
sys.path.insert(0, str(ROOT / 'tools/lowpoly'))
from planet_detail_012 import GLB, logical, normal, digest, R, WATER_SHA

LAND = 'spherical_continents_and_biomes'
ROUTE_CLEARANCE = .34
CITY_CLEARANCE = .12
OLD_PROP_CLEARANCE = .025
BLEND_DISTANCE = .95
SEED = 260909017
SCHEMA = 'silkroad.corridor-props.v1'


def normalize(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-20)


def kdtree(points):
    result = KDTree(len(points))
    for i, p in enumerate(points):
        result.insert(Vector(p), i)
    result.balance()
    return result


def route_samples(root, spacing=.025):
    data = json.loads((root / 'data/rulesets/lshu_configurable_v1/board_edges.json').read_text())['items']
    points, land_stations = [], []
    for edge in data:
        poly = edge['movement_polyline']
        carried = 0.0
        for a, b in zip(poly, poly[1:]):
            size = math.dist(a, b)
            count = max(1, math.ceil(size * .016 / spacing))
            for i in range(count + 1):
                t = i / count
                xy = [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
                points.append(tuple(normal(*xy) * R))
                if edge['route_type'] == 'LAND' and (i == 0 or carried >= 42):
                    land_stations.append({'logical': xy, 'edge': edge['id']})
                    carried = 0
                carried += size / count
    return np.asarray(points), land_stations


def city_footprints(root):
    nodes = json.loads((root / 'data/rulesets/lshu_configurable_v1/board_nodes.json').read_text())['items']
    result = []
    for city in nodes:
        if city['node_type'] != 'CITY':
            continue
        g = GLB(root / ('assets/game/lowpoly/cities/' + city['id'] + '.glb'))
        ps = np.asarray([p for n in g.doc['nodes'] if 'mesh' in n for _, vv, _ in g.geometry(n['name']) for p in vv])
        xy = [city['map_position'][0], city['map_position'][1] - 85]
        n = np.asarray(normal(*xy)); lon = (xy[0] - 2048) * math.tau / 6144
        east = np.asarray([math.cos(lon), 0, -math.sin(lon)])
        south = np.cross(east, n)
        result.append(dict(id=city['id'], logical=xy, origin=n * (R + .08), east=east, south=south,
                           low=ps[:, [0, 2]].min(axis=0), high=ps[:, [0, 2]].max(axis=0)))
    return result


def city_distance(points, city):
    relative = np.asarray(points) - city['origin']
    xy = np.stack((relative @ city['east'], relative @ city['south']), axis=-1)
    delta = np.maximum(np.maximum(city['low'] - xy, xy - city['high']), 0)
    return np.linalg.norm(delta, axis=-1)


def flatten_land(glb):
    positions, faces, records = [], [], []
    for primitive, ps, fs in glb.geometry(LAND):
        start = len(positions)
        positions.extend(tuple(p) for p in ps)
        faces.extend([i + start for i in f] for f in fs)
        records.append((primitive, start, len(ps), np.asarray(fs)))
    return np.asarray(positions), np.asarray(faces), records


def projected_triangle_circles(glb, names):
    centers, radii = [], []
    for name in names:
        for _, ps, fs in glb.geometry(name):
            p = normalize(np.asarray(ps)) * R
            tri = p[np.asarray(fs)]
            c = normalize(tri.mean(axis=1)) * R
            radius = np.linalg.norm(tri - c[:, None, :], axis=-1).max(axis=1)
            centers.extend(c); radii.extend(radius)
    return np.asarray(centers), np.asarray(radii)


def runtime_contacts(root):
    p = json.loads((root / 'scripts/ui/ambient/placements.json').read_text())
    result = [(xy, .40, 'sheep') for xy in p['sheep']]
    result += [(p['windmill'], .40, 'windmill')]
    result += [(xy, .12, 'flag_base') for xy in p['flags']]
    return [(np.asarray(normal(*xy)) * R, radius, name) for xy, radius, name in result]


def protection(glb, positions, faces, inverse, unique_count, routes, cities):
    tri = normalize(positions[faces]) * R
    center = normalize(tri.mean(axis=1)) * R
    radius = np.linalg.norm(tri - center[:, None, :], axis=-1).max(axis=1)
    masks = {}
    # Nearest .025 world samples plus half the sample spacing, triangle containing
    # circle and .001 world numeric pad are conservative for the continuous lane.
    route_tree = kdtree(routes)
    masks['route_lane'] = np.asarray([route_tree.find(Vector(c))[2] <= r + ROUTE_CLEARANCE + .014 for c, r in zip(center, radius)])
    city_mask = np.zeros(len(faces), dtype=bool)
    for city in cities:
        # Reject the far hemisphere before tangent-AABB distance, whose plane
        # alone otherwise falsely identifies antipodal city neighborhoods.
        near = np.linalg.norm(center - normalize(city['origin']) * R, axis=1) < 3.0
        city_mask |= near & (city_distance(center, city) <= radius + CITY_CLEARANCE)
    masks['city_footprint'] = city_mask
    names = [n['name'] for n in glb.doc['nodes'] if n.get('name') not in (LAND, 'radial_coastal_cliffs')]
    prop_center, prop_radius = projected_triangle_circles(glb, names)
    tree = kdtree(prop_center)
    max_radius = max(prop_radius)
    mask = np.zeros(len(faces), dtype=bool)
    for i, (c, r) in enumerate(zip(center, radius)):
        for _, j, d in tree.find_range(Vector(c), r + max_radius + OLD_PROP_CLEARANCE):
            if d <= r + prop_radius[j] + OLD_PROP_CLEARANCE:
                mask[i] = True
                break
    masks['old_geometry_contacts'] = mask
    dynamic_mask = np.zeros(len(faces), dtype=bool)
    for point, envelope, _ in runtime_contacts(ROOT):
        dynamic_mask |= np.linalg.norm(center - point, axis=1) <= radius + envelope + OLD_PROP_CLEARANCE
    masks['runtime_ground_contacts'] = dynamic_mask
    counts = {}
    for a, b, c in inverse[faces]:
        for x, y in ((a, b), (b, c), (c, a)):
            edge = tuple(sorted((int(x), int(y))))
            counts[edge] = counts.get(edge, 0) + 1
    shore_ids = {i for edge, count in counts.items() if count == 1 for i in edge}
    # Every face touching a true coastline vertex is fixed, including its
    # non-coastal vertices: no interpolation can lift the old coast triangle.
    masks['coast_adjacent'] = np.asarray([any(int(i) in shore_ids for i in f) for f in inverse[faces]])
    frozen_faces = np.logical_or.reduce(list(masks.values()))
    frozen = np.zeros(unique_count, dtype=bool)
    frozen[inverse[faces[frozen_faces]].ravel()] = True
    return frozen, masks, frozen_faces


def graph_distances(unique, faces, inverse, frozen):
    neighbors = [dict() for _ in unique]
    projected = normalize(unique) * R
    for a, b, c in inverse[faces]:
        for x, y in ((a, b), (b, c), (c, a)):
            x, y = int(x), int(y)
            if y not in neighbors[x]:
                distance = float(np.linalg.norm(projected[x] - projected[y]))
                neighbors[x][y] = distance; neighbors[y][x] = distance
    distance = np.full(len(unique), np.inf)
    queue = []
    for i in np.flatnonzero(frozen):
        distance[i] = 0
        heapq.heappush(queue, (0, int(i)))
    while queue:
        d, i = heapq.heappop(queue)
        if d != distance[i]:
            continue
        for j, length in neighbors[i].items():
            if d + length < distance[j]:
                distance[j] = d + length
                heapq.heappush(queue, (d + length, j))
    return distance


def write_accessor(glb, index, values):
    a = glb.doc['accessors'][index]; view = glb.doc['bufferViews'][a['bufferView']]
    dtype = np.dtype({5126:'<f4', 5123:'<u2', 5121:'u1'}[a['componentType']])
    if a.get('normalized'):
        values = np.rint(np.clip(values, 0, 1) * np.iinfo(dtype).max)
    values = np.asarray(values, dtype=dtype)
    arr = np.ndarray(values.shape, dtype=dtype, buffer=glb.binary,
                     offset=view.get('byteOffset', 0) + a.get('byteOffset', 0),
                     strides=(view.get('byteStride', values.shape[1] * dtype.itemsize), dtype.itemsize))
    arr[:] = values
    if 'min' in a or 'max' in a:
        a['min'], a['max'] = values.min(axis=0).tolist(), values.max(axis=0).tolist()


def apply_relief(glb, root):
    positions, faces, records = flatten_land(glb)
    # All corner copies of a source position receive exactly the same update.
    keys = np.round(positions * 100000).astype(np.int64)
    _, first, inverse = np.unique(keys, axis=0, return_index=True, return_inverse=True)
    unique = positions[first]
    routes, stations = route_samples(root)
    cities = city_footprints(root)
    frozen, masks, frozen_faces = protection(glb, positions, faces, inverse, len(unique), routes, cities)
    distances = graph_distances(unique, faces, inverse, frozen)
    weight = np.clip(distances / BLEND_DISTANCE, 0, 1)
    weight = weight * weight * (3 - 2 * weight)
    xy = np.asarray([logical(p) for p in unique])
    x, y = xy[:, 0], xy[:, 1]
    broad = .170 + .110 * np.sin((x + .33 * y) * math.tau / 650) + .055 * np.cos((y - .25 * x) * math.tau / 420)
    delta = broad * weight
    delta[frozen] = 0
    updated = unique + normalize(unique) * delta[:, None]
    updated[frozen] = unique[frozen]
    new_positions = updated[inverse]
    changed_corner = delta[inverse] > 1e-8
    color_field = (1 + weight * (.037 * np.sin((x + .24 * y) * math.tau / 570)
                                 + .016 * np.cos((y - .31 * x) * math.tau / 440)))
    for primitive, start, count, fs in records:
        ids = np.arange(start, start + count)
        original_p = glb.accessor(primitive['attributes']['POSITION'])
        p = new_positions[ids].astype(np.float32)
        p[~changed_corner[ids]] = original_p[~changed_corner[ids]]
        normals = glb.accessor(primitive['attributes']['NORMAL'])
        colors = glb.accessor(primitive['attributes']['COLOR_0'])
        for face in fs:
            if not changed_corner[ids[face]].any():
                continue
            a, b, c = p[face]
            n = np.cross(b - a, c - a); n /= max(np.linalg.norm(n), 1e-20)
            if np.dot(n, normals[face].mean(axis=0)) < 0:
                n = -n
            normals[face] = n
        change = changed_corner[ids]
        colors[change, :3] = np.clip(colors[change, :3] * color_field[inverse[ids[change]], None], 0, 1)
        write_accessor(glb, primitive['attributes']['POSITION'], p)
        write_accessor(glb, primitive['attributes']['NORMAL'], normals)
        write_accessor(glb, primitive['attributes']['COLOR_0'], colors)
    actual_changed_faces = np.any(changed_corner[faces], axis=1)
    report = dict(unique_land_vertices=len(unique), land_corners=len(positions), land_triangles=len(faces),
                  frozen_faces=int(frozen_faces.sum()), frozen_vertices=int(frozen.sum()),
                  protection_faces={k: int(v.sum()) for k, v in masks.items()},
                  changed_unique_vertices=int((delta > 1e-8).sum()), changed_corner_fraction=float(changed_corner.mean()),
                  changed_triangle_fraction=float(actual_changed_faces.mean()),
                  raw_field_max=.335, blend_distance_world=BLEND_DISTANCE,
                  route_clearance_world=ROUTE_CLEARANCE, city_clearance_world=CITY_CLEARANCE,
                  old_geometry_clearance_world=OLD_PROP_CLEARANCE, wavelengths_logical=[420, 650],
                  height_delta_world=dict(min=float(delta.min()), median_nonzero=float(np.median(delta[delta > 1e-8])),
                                          max=float(delta.max()), above_0_1=int((delta >= .1).sum())),
                  protected_face_indices=np.flatnonzero(frozen_faces).tolist(),
                  modified_face_indices=np.flatnonzero(actual_changed_faces).tolist(),
                  normals='flat per changed triangle; unchanged triangles keep bytes',
                  colors='broad 440/570 logical modulation of existing sRGB COLOR_0, unchanged inside protected zones')
    return report, routes, stations, cities


class Prototype:
    def __init__(self, name):
        self.data = dict(id=name, vertices=[], normals=[], indices=[], colors=[], foot_points=[], instances=[])

    def tri(self, a, b, c, color):
        a, b, c = np.asarray(a), np.asarray(b), np.asarray(c)
        n = normalize(np.cross(b-a, c-a))
        base = len(self.data['vertices'])
        self.data['vertices'].extend([a.tolist(), b.tolist(), c.tolist()])
        self.data['normals'].extend([n.tolist()] * 3)
        # Godot front faces use clockwise winding; normals are explicit.
        self.data['indices'].extend([base, base+2, base+1])
        shade = .91 + .09 * max(0, n[1])
        self.data['colors'].extend([[v*shade for v in color]+[1.0]] * 3)

    def mound(self, x, z, rx, rz, height, color, sides=6, phase=0):
        lower = [(x+math.cos(phase+i*math.tau/sides)*rx*.82, 0, z+math.sin(phase+i*math.tau/sides)*rz*.82) for i in range(sides)]
        shoulder = [(x+math.cos(phase+i*math.tau/sides)*rx, height*.53, z+math.sin(phase+i*math.tau/sides)*rz) for i in range(sides)]
        crown = [(x+math.cos(phase+i*math.tau/sides)*rx*.53, height*.94, z+math.sin(phase+i*math.tau/sides)*rz*.53) for i in range(sides)]
        for ring_a, ring_b in ((lower,shoulder),(shoulder,crown)):
            for i in range(sides):
                j=(i+1)%sides
                self.tri(ring_a[i],ring_b[i],ring_a[j],color)
                self.tri(ring_a[j],ring_b[i],ring_b[j],color)
        for i in range(sides):
            self.tri(crown[i],(x,height,z),crown[(i+1)%sides],color)
            self.tri(lower[i],lower[(i+1)%sides],(x,0,z),color)

    def finish(self):
        self.data['foot_points'] = [list(v) for v in sorted({tuple(v) for v in self.data['vertices'] if abs(v[1])<1e-8})]
        return self.data


def prototypes():
    rock=Prototype('sandstone_cluster')
    rock.mound(-.095,0,.145,.13,.18,(1,1,.95),5,.24)
    rock.mound(.13,.07,.105,.092,.115,(1,.96,.84),5,.61)
    rock.mound(.09,-.135,.080,.090,.085,(1,.99,.93),5,.1)
    bush=Prototype('broad_bushes')
    bush.mound(-.095,0,.14,.125,.205,(1,1,.93),6,.2)
    bush.mound(.13,.04,.095,.105,.15,(.92,1,.88),6,.5)
    grass=Prototype('folded_grass')
    for i,(x,z,h,angle) in enumerate([(-.10,-.02,.19,.4),(.07,-.08,.22,1.4),(.11,.09,.17,2.6),(-.07,.12,.15,3.7)]):
        direction=np.asarray([math.cos(angle),0,math.sin(angle)])
        across=np.asarray([-direction[2],0,direction[0]])
        root=np.asarray([x,0,z]); a=root-across*.046; b=root+across*.046
        tip=root+direction*.10+np.asarray([0,h,0]); ridge=root+direction*.055+np.asarray([0,h*.58,0])
        grass.tri(a,ridge,tip,(.96,1,.87));grass.tri(b,tip,ridge,(1,1,.91))
        grass.tri(a,b,ridge,(1,1,.90))
    palm=Prototype('short_palm')
    # A broad, planted trunk plus thick folded fronds. One prototype = one batch.
    sides=6; bottom=[]; top=[]
    for i in range(sides):
        a=i*math.tau/sides
        bottom.append((math.cos(a)*.052,0,math.sin(a)*.052))
        top.append((math.cos(a)*.035,.31,math.sin(a)*.035))
    for i in range(sides):
        j=(i+1)%sides
        palm.tri(bottom[i],top[i],bottom[j],(.77,.60,.35));palm.tri(bottom[j],top[i],top[j],(.77,.60,.35))
        palm.tri(bottom[i],bottom[j],(0,0,0),(.77,.60,.35))
    for i in range(6):
        a=i*math.tau/6+.1; d=np.asarray([math.cos(a),0,math.sin(a)]); s=np.asarray([-d[2],0,d[0]])
        root=np.asarray([0,.31,0]);mid=d*.12+np.asarray([0,.395,0]);tip=d*.255+np.asarray([0,.27,0])
        palm.tri(root,mid+s*.056,mid+np.asarray([0,.025,0]),(.72,.93,.45))
        palm.tri(root,mid+np.asarray([0,.025,0]),mid-s*.056,(.80,1,.52))
        palm.tri(mid+s*.056,tip,mid+np.asarray([0,.025,0]),(.78,.98,.48))
        palm.tri(mid+np.asarray([0,.025,0]),tip,mid-s*.056,(.90,1,.60))
    return [p.finish() for p in (rock,bush,grass,palm)]


class Ground:
    def __init__(self, glb):
        positions, faces, _ = flatten_land(glb)
        self.tree = BVHTree.FromPolygons([Vector(p) for p in positions], faces.tolist(), all_triangles=True)

    def hit(self, p):
        n=Vector(p).normalized()
        q, norm, index, _=self.tree.ray_cast(n*15,-n,9)
        if q is None: return None
        if norm.dot(n)<0: norm=-norm
        return np.asarray(q),np.asarray(norm),index


def generate_props(glb, root, routes, stations, cities, terrain_sha):
    import ast
    source=(root/'tools/lowpoly/build_planet.py').read_text()
    fn=next(n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef) and n.name=='biome_at')
    namespace=dict(math=math,LON_SCALE=math.tau/6144,LAT_SCALE=math.pi/2400)
    exec(compile(ast.Module(body=[fn],type_ignores=[]),'frozen_biome','exec'),namespace)
    biome_at=namespace['biome_at']
    groups=prototypes(); group_by_id={p['id']:p for p in groups}
    for group in groups:
        v=np.asarray(group['vertices'])
        group['_radius']=float(np.linalg.norm(v[:,[0,2]],axis=1).max())
    rng=random.Random(SEED); ground=Ground(glb); route_tree=kdtree(routes)
    oldnames=[n['name'] for n in glb.doc['nodes'] if n.get('name') not in (LAND,'radial_coastal_cliffs')]
    oldc, oldr=projected_triangle_circles(glb,oldnames); oldtree=kdtree(oldc); oldmax=max(oldr)
    taken=[]; counts={c['id']:0 for c in cities}; rejected={}; sequence=0
    dynamic=runtime_contacts(root)

    def reject(reason): rejected[reason]=rejected.get(reason,0)+1;return False
    def attempt(xy, quota):
        nonlocal sequence
        if not (0<xy[0]<4096 and 100<xy[1]<1300): return reject('outside_playable')
        biome=biome_at(*xy)
        choices={'desert':['sandstone_cluster']*5+['short_palm'], 'grass':['broad_bushes']*3+['folded_grass']*2+['sandstone_cluster'], 'forest':['broad_bushes']*4+['sandstone_cluster'], 'tropical':['short_palm']*3+['broad_bushes']}
        name=rng.choice(choices.get(biome,['sandstone_cluster']))
        group=group_by_id[name]; scale=rng.uniform(.94,1.14); footprint=group['_radius']*scale+.035
        n=np.asarray(normal(*xy)); center=n*R
        if route_tree.find(Vector(center))[2] < ROUTE_CLEARANCE+footprint+.014: return reject('route')
        for city in cities:
            if np.linalg.norm(center-normalize(city['origin'])*R)<3 and city_distance(center,city)<CITY_CLEARANCE+footprint: return reject('city')
        for _,j,d in oldtree.find_range(Vector(center),footprint+oldmax+.035):
            if d<footprint+oldr[j]+.035: return reject('old_geometry')
        for p,envelope,kind in dynamic:
            # Sheep motion and windmill sails should not collide with new shrubs.
            if np.linalg.norm(center-p)<footprint+max(envelope,.45): return reject('runtime')
        if any(np.linalg.norm(center-p)<footprint+r+.09 for p,r in taken): return reject('cluster_spacing')
        hit=ground.hit(center)
        if hit is None: return reject('ocean')
        pos,up,_=hit
        if np.dot(up,n)<.9:return reject('steep')
        lon=(xy[0]-2048)*math.tau/6144;east=np.asarray([math.cos(lon),0,-math.sin(lon)])
        east=normalize(east-up*np.dot(east,up));south=np.cross(east,up)
        angle=rng.uniform(0,math.tau);east2=east*math.cos(angle)+south*math.sin(angle);south2=-east*math.sin(angle)+south*math.cos(angle)
        basis=np.stack((east2,up,south2),axis=1)*scale
        feet=np.asarray(group['foot_points']); original_feet=feet@basis.T+pos
        radial_gaps=[]
        for foot in original_feet:
            h=ground.hit(foot)
            if h is None:return reject('shore_foot')
            radial_gaps.append(np.linalg.norm(foot)-np.linalg.norm(h[0]))
        # Move the highest potentially floating foot .006 world into real ground.
        pos=pos-up*(max(radial_gaps)+.006)/max(np.dot(up,n),.9)
        samples=[]
        for local in feet:
            foot=basis@local+pos;h=ground.hit(foot)
            if h is None:return reject('shore_foot')
            gap=np.linalg.norm(foot)-np.linalg.norm(h[0])
            if gap>.0015 or gap<-.055:return reject('uneven_contact')
            samples.append(dict(local=local.tolist(),world=foot.tolist(),surface=h[0].tolist()))
        tint={'sandstone_cluster':([1,.87,.64] if biome=='desert' else [.96,.94,.76]),'broad_bushes':[.66,.85,.47],'folded_grass':[.83,.90,.50],'short_palm':[.94,1,.83]}[name]
        inst=dict(id='corridor_%03d'%sequence,logical=list(xy),position=pos.tolist(),basis=basis.flatten(order='F').tolist(),color=tint+[1],ground_samples=samples,quota=quota,biome=biome)
        group['instances'].append(inst);sequence+=1;taken.append((center,footprint))
        return True

    # Search around the real exported city rectangle, not a blanket150px disc.
    for city in cities:
        angles=[i*math.tau/48 for i in range(48)];rng.shuffle(angles)
        for extra in (.34,.53,.77,1.0):
            for angle in angles:
                direction=np.asarray([math.cos(angle),math.sin(angle)])
                extent=np.where(direction>=0,city['high'],-city['low'])
                t=min(extent[i]/abs(direction[i]) for i in range(2) if abs(direction[i])>1e-8)
                local=direction*(t+extra)
                p=city['origin']+city['east']*local[0]+city['south']*local[1]
                xy=logical(p)
                if attempt(xy,dict(kind='city',id=city['id'])):
                    counts[city['id']]+=1
                    if counts[city['id']]>=4:break
            if counts[city['id']]>=4:break
    city_total=sequence
    rng.shuffle(stations)
    # Broad stepping around land-route stations leaves the widened route and
    # legal markers free. It adds grouped silhouettes to the play corridors.
    for offset in (56,72,92):
        for station in stations:
            angle=rng.uniform(0,math.tau)
            for side in (0,math.pi):
                xy=[station['logical'][0]+math.cos(angle+side)*offset,station['logical'][1]+math.sin(angle+side)*offset]
                attempt(xy,dict(kind='corridor',id=station['edge']))
                if sequence>=114:break
            if sequence>=114:break
        if sequence>=114:break
    for group in groups:group.pop('_radius')
    return dict(schema=SCHEMA,revision='TASK-PLANET-DENSITY-017',seed=SEED,terrain_sha256=terrain_sha,instance_count=sequence,
                group_count=len([g for g in groups if g['instances']]),groups=groups,
                contracts=dict(route_clearance_world=.34,city_clearance_world=.12,old_geometry_clearance_world=.035,
                               foot_embed_target_world=.006,foot_max_embed_world=.055,foot_max_float_world=.0015,
                               basis_layout='column-major; scale already applied',winding='clockwise; explicit outward normals',
                               render_layer='Godot static MultiMesh, not included in planet.blend'),
                quotas=dict(initial_target=114,initial_city=64,actual_city=city_total,actual_corridor=sequence-city_total,by_city=counts),
                generation_rejections=rejected)


def update_source(root, target):
    path = root / 'docs/design/planet-v2/source/planet.blend'
    bpy.ops.wm.open_mainfile(filepath=str(path))
    destination = bpy.data.objects[LAND]
    before = set(bpy.context.scene.objects)
    materials = list(destination.data.materials)
    bpy.ops.import_scene.gltf(filepath=str(target))
    imported = set(bpy.context.scene.objects) - before
    source = next(o for o in imported if o.type == 'MESH' and o.name.startswith(LAND))
    replacement = source.data.copy()
    replacement.transform(destination.matrix_world.inverted() @ source.matrix_world)
    replacement.color_attributes.active_color.name = 'Col'
    replacement.materials.clear()
    for material in materials:
        replacement.materials.append(material)
    destination.data = replacement
    for o in imported:
        bpy.data.objects.remove(o, do_unlink=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(path))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=Path('/tmp/silkroad-density-017/candidate'))
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--props', action='store_true', help='Generate the static corridor layer alongside relief.')
    parser.add_argument('--baseline-root', type=Path, help='Pre-017 repository-layout snapshot; avoids cumulative relief.')
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
    root = ROOT
    target = root / 'assets/game/lowpoly/planet/terrain.glb'
    stats_path = target.with_name('planet-stats.json')
    source = (args.baseline_root / target.relative_to(root)) if args.baseline_root else target
    source_stats = source.with_name('planet-stats.json')
    stats = json.loads(source_stats.read_text())
    if stats.get('density_017'):
        raise RuntimeError('Use the recorded pre-017 terrain/stats to rebuild; never stack relief on a relief result.')
    assert digest(target.with_name('water.glb')) == WATER_SHA
    before = GLB(source); old_doc = copy.deepcopy(before.doc)
    before_sha = digest(source)
    report, routes, stations, cities = apply_relief(before, root)
    assert len(before.doc['meshes']) == len(old_doc['meshes'])
    assert len(before.doc['accessors']) == len(old_doc['accessors'])
    assert before.doc['materials'] == old_doc['materials']
    args.output.mkdir(parents=True, exist_ok=True)
    candidate = args.output / 'terrain.glb'
    before.save(candidate)
    report.update(source_terrain_sha256=before_sha, terrain_sha256=digest(candidate),
                  helper_sha256=digest(__file__), source_updated=False,
                  seed=SEED, revision='TASK-PLANET-DENSITY-017')
    if args.props:
        props = generate_props(before, root, routes, stations, cities, digest(candidate))
        (args.output / 'corridor_017_placements.json').write_text(json.dumps(props, separators=(',', ':')) + '\n')
        report['corridor_props'] = {k: v for k, v in props.items() if k != 'groups'}
        report['corridor_props']['groups'] = {g['id']: dict(instances=len(g['instances']), triangles=len(g['indices'])//3) for g in props['groups']}
    stats['density_017'] = report
    stats['visual_revision'] = 'TASK-PLANET-DENSITY-017'
    (args.output / 'planet-stats.json').write_text(json.dumps(stats, indent=2) + '\n')
    summary = {k: v for k, v in report.items() if not k.endswith('_indices')}
    (args.output / 'relief-report.json').write_text(json.dumps(report, indent=2) + '\n')
    if args.apply:
        import shutil
        shutil.copy2(candidate, target)
        update_source(root, target)
        if args.props:
            shutil.copy2(args.output / 'corridor_017_placements.json', root / 'scripts/ui/ambient/corridor_017_placements.json')
        report['source_updated'] = True
        stats_path.write_text(json.dumps(stats, indent=2) + '\n')
    print('DENSITY_017_RELIEF', json.dumps(summary), flush=True)


if __name__ == '__main__':
    main()
