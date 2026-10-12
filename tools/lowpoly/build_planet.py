"""Build SilkRoad's genuinely spherical biome world in Blender.

Blender --background --factory-startup --python-exit-code 1 --python
tools/lowpoly/build_planet.py. Logical rule files are read only.
"""
import colorsys
import hashlib
import json
import math
import random
from collections import Counter, deque
from statistics import median
from pathlib import Path

import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

ROOT = Path(__file__).resolve().parents[2]
if '--detail-012-only' in __import__('sys').argv:
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from planet_detail_012 import apply_details
    output = None
    if '--detail-output' in sys.argv:
        output = sys.argv[sys.argv.index('--detail-output') + 1]
    apply_details(ROOT, output=output)
    raise SystemExit(0)
OUT = ROOT / 'assets/game/lowpoly/planet'
DOC = ROOT / 'docs/design/planet-v2'
R = 11.0
LON_SCALE = math.tau / 6144.0
LAT_SCALE = math.pi / 2400.0
RNG = random.Random(260908)
OASIS_RNG = random.Random(2609084)
RANGE_RNG = random.Random(2609085)
LONGITUDE_PERIOD = math.tau / LON_SCALE
# These named inland waters are deliberately retained even without a sea route.
LAKES = {'black_sea': (812, 1189, 206, 357),
         'caspian': (1386, 1552, 165, 423),
         'persian_gulf': (1358, 1525, 639, 801),
         'aral': (1673, 1787, 157, 251),
         'aegean': (411, 598, 228, 380)}
RIVERS = {'tianshan_caspian': [(1800, 205), (1700, 280), (1610, 320), (1560, 330)],
          'southeast_lowland': [(2180, 540), (2259, 572), (2296, 673), (2415, 726), (2510, 740)]}
# Local color fields do not create materials or change the original material order.
SUBCOLORS = {'gobi': 'BFA36A', 'red_rock': 'C98A55', 'oasis_bank': 'A6B35A',
             'oasis_water': '3BB8A8'}
OASES = [dict(name='iran_highland', x=1775, y=625, radius=80, water_radius=30, palms=5, rocks=3),
         dict(name='eastern_desert', x=2440, y=690, radius=60, water_radius=22, palms=4, rocks=2),
         dict(name='western_desert', x=1130, y=770, radius=55, water_radius=20, palms=3, rocks=2)]
RANGES = [dict(name='tianshan', points=[(2070, 80), (2180, 95), (2290, 130)], heights=[.55, .85, .60]),
          dict(name='kunlun', points=[(2320, 465), (2430, 487), (2540, 513)], heights=[.50, .80, .55]),
          dict(name='east_black_sea', points=[(1130, 100), (1240, 175), (1340, 245)], heights=[.50, .75, .50])]
coast_kd = None
for folder in (OUT, DOC / 'source', DOC / 'previews'):
    folder.mkdir(parents=True, exist_ok=True)
(DOC / '.gdignore').touch()
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)

DATA = ROOT / 'data/rulesets/lshu_configurable_v1'
NODES = json.loads((DATA / 'board_nodes.json').read_text())['items']
EDGES = json.loads((DATA / 'board_edges.json').read_text())['items']
CITIES = [n for n in NODES if n['node_type'] == 'CITY']


def normal(x, y):
    lon, lat = (x - 2048) * LON_SCALE, (681.5 - y) * LAT_SCALE
    # Blender Z is Godot Y, Blender -Y is Godot Z.
    return Vector((math.cos(lat) * math.sin(lon),
                   -math.cos(lat) * math.cos(lon), math.sin(lat)))


def logical(n):
    n = n.normalized()
    return 2048 + math.atan2(n.x, -n.y) / LON_SCALE, 681.5 - math.asin(max(-1, min(1, n.z))) / LAT_SCALE


def make_kd(points):
    kd = KDTree(len(points))
    for i, point in enumerate(points):
        kd.insert((point[0], point[1], 0), i)
    kd.balance()
    return kd


land_points, sea_points = [], []
for edge in EDGES:
    target = land_points if edge['route_type'] == 'LAND' else sea_points
    for a, b in zip(edge['movement_polyline'], edge['movement_polyline'][1:]):
        steps = max(1, math.ceil(math.dist(a, b) / 10))
        target.extend((a[0] + (b[0] - a[0]) * t / steps,
                       a[1] + (b[1] - a[1]) * t / steps) for t in range(steps + 1))
land_kd, sea_kd = make_kd(land_points), make_kd(sea_points)
route_kd = make_kd(land_points + sea_points)
city_positions = [(n['map_position'][0], n['map_position'][1] - 85) for n in CITIES]
city_kd = make_kd(city_positions)
river_samples = []
for points in RIVERS.values():
    for a, b in zip(points, points[1:]):
        steps = max(1, math.ceil(math.dist(a, b) / 3))
        river_samples.extend((a[0] + (b[0] - a[0]) * i / steps,
                              a[1] + (b[1] - a[1]) * i / steps) for i in range(steps + 1))
river_kd = make_kd(river_samples)


def distance(kd, x, y):
    return kd.find((x, y, 0))[2]


def clamp(value, low=0.0, high=1.0):
    return max(low, min(high, value))


def smoothstep(low, high, value):
    t = clamp((value - low) / (high - low))
    return t * t * (3 - 2 * t)


def coast_distance(x, y):
    return distance(coast_kd, x, y) if coast_kd is not None else 1e6


image_path = ROOT / 'assets/game/maps/world/world_map_v2_overscan.png'
source_image = bpy.data.images.load(str(image_path))
WIDTH, HEIGHT = source_image.size
PIXELS = list(source_image.pixels)


def source_land(x, y):
    if not (0 <= x <= 4095 and -165 <= y <= 1535):
        return False
    ix, iy = int(x), max(0, min(HEIGHT - 1, round(y + 184)))
    index = ((HEIGHT - 1 - iy) * WIDTH + ix) * 4
    r, g, b = PIXELS[index:index + 3]
    hue, sat, val = colorsys.rgb_to_hsv(r, g, b)
    return not (0.43 < hue < 0.68 and sat > 0.21 and b > r * 1.09)


def sphere_distance(lon, lat, cx, cy):
    dl = (lon - cx + math.pi) % math.tau - math.pi
    return math.sqrt((dl * math.cos((lat + cy) / 2)) ** 2 + (lat - cy) ** 2)


def land_at(x, y):
    lon, lat = (x - 2048) * LON_SCALE, (681.5 - y) * LAT_SCALE
    if abs(lat) > math.radians(76 + 2 * math.sin(lon * 5)):
        return True
    if distance(city_kd, x, y) < 93:
        return True
    if distance(sea_kd, x, y) < 16:
        return False
    if distance(land_kd, x, y) < 20:
        return True
    if source_land(x, y):
        return True
    # The previously uncharted rear hemisphere is a landscape-only archipelago.
    # These islands never create rule nodes, routes, cities, events or shortcuts.
    islands = [(math.radians(155), math.radians(20), .44),
               (math.radians(-156), math.radians(-28), .54),
               (math.radians(166), math.radians(-32), .24),
               (math.radians(-139), math.radians(46), .19)]
    for cx, cy, radius in islands:
        d = sphere_distance(lon, lat, cx, cy)
        edge = radius * (1 + .10 * math.sin(lon * 17 + lat * 13) + .05 * math.sin(lat * 31))
        if d < edge:
            return True
    return False


def biome_at(x, y):
    lon, lat = (x - 2048) * LON_SCALE, (681.5 - y) * LAT_SCALE
    if abs(lat) > math.radians(72):
        return 'ice'
    if x < 0 or x > 4096:
        if sphere_distance(lon, lat, math.radians(155), math.radians(20)) < .19:
            return 'volcanic'
        return 'tropical' if lat < .25 else 'forest'
    if y < 130 and x > 1550:
        return 'forest'
    if y > 900 and (x > 1850 or x < 600):
        return 'tropical'
    if (x > 2650 + 105 * math.sin(y * .008) and y > 130) or (x < 1080 and y < 300):
        return 'grass'
    if 1830 < x < 2330 and y > 700:
        return 'grass'
    return 'desert'


RIDGES = [(370, 50, 150, 85, .38), (1030, 210, 190, 100, .38),
          (1920, 115, 210, 110, .63), (2260, 130, 210, 110, .55),
          (2460, 445, 220, 80, .63), (2710, 515, 180, 85, .56),
          (850, 1040, 155, 230, .24)]


def ridge_field(x, y):
    return max(h * math.exp(-((x - cx) / wx) ** 2 - ((y - cy) / wy) ** 2)
               for cx, cy, wx, wy, h in RIDGES)


def elevation(x, y):
    road_d = distance(route_kd, x, y)
    city_d = distance(city_kd, x, y)
    protection = max(0, min(1, (road_d - 38) / 60, (city_d - 120) / 90))
    broad = ridge_field(x, y)
    biome = biome_at(x, y)
    rolling = .05 + .027 * (math.sin(x * .014 + y * .003) + math.cos(y * .016))
    if biome == 'desert':
        u = x * math.cos(.35) + y * math.sin(.35)
        v = -x * math.sin(.35) + y * math.cos(.35)
        rolling += .03 + .06 * math.sin(u * .019) * math.sin(v * .006 + .8)
        rolling += .015 * math.sin(u * .041 + v * .013)
        for oasis in OASES:
            d = math.hypot(x - oasis['x'], y - oasis['y'])
            rolling -= .012 * max(0, 1 - d / oasis['water_radius']) * protection
    if biome == 'ice':
        rolling += .07
    if biome == 'volcanic':
        lon, lat = (x - 2048) * LON_SCALE, (681.5 - y) * LAT_SCALE
        d = sphere_distance(lon, lat, math.radians(155), math.radians(20))
        broad = max(broad, .40 * math.exp(-(d / .13) ** 2))
    coast = clamp(coast_distance(x, y) / 45)
    shore = protection * (1 - coast)
    return .08 - .035 * shore + protection * max(0, broad + rolling) * coast


def linear(v):
    v = int(v, 16) / 255
    return v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4


MATS = {}


def material(name, color):
    mat = bpy.data.materials.new(name)
    rgba = tuple(linear(color[i:i + 2]) for i in (0, 2, 4)) + (1,)
    mat.diffuse_color = rgba
    mat.use_nodes = True
    p = mat.node_tree.nodes.get('Principled BSDF')
    p.inputs['Base Color'].default_value = rgba
    p.inputs['Roughness'].default_value = .9
    p.inputs['Metallic'].default_value = 0
    MATS[name] = mat
    return mat


COLORS = {
    'desert': ['D9AC5F', 'C99548', 'E2B86A'],
    'grass': ['9AA84E', '8A9A42', 'A6B35A'],
    'forest': ['556B33', '4A5F2C', '60773B'],
    'tropical': ['66A356', '5B9650', '72B060'],
    'ice': ['E0E7DD', 'E9EEE2', 'CCD9D5'],
    'volcanic': ['726C68', '7C736A', '6A6563'],
    'sand': ['E2C68C'], 'coast': ['E2C68C'],
    'ocean': ['286975', '2B6E79', '2D717B'],
    'shallow': ['438E91', '499799'],
    'pine': ['465D2D'], 'pine_tip': ['61783A'],
    'wood': ['786040'], 'palm': ['52945F'],
    'leaf': ['5E8D60'], 'stone': ['A69A83'],
    'snow': ['EFEFE1'], 'dark_stone': ['635B55'], 'lava': ['D87C49'],
}
for prefix, colors in COLORS.items():
    for i, color in enumerate(colors):
        material(prefix + str(i), color)


def mesh(name, vertices, faces, materials, indices=None):
    data = bpy.data.meshes.new(name)
    data.from_pydata(vertices, [], faces)
    for mat in materials:
        data.materials.append(mat)
    if indices is not None:
        for polygon, index in zip(data.polygons, indices):
            polygon.material_index = index
    data.update()
    obj = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(obj)
    return obj


bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=6, radius=1)
template = bpy.context.object
directions = [v.co.normalized().copy() for v in template.data.vertices]
triangles = [tuple(p.vertices) for p in template.data.polygons]
bpy.data.objects.remove(template, do_unlink=True)
logical_points = [logical(v) for v in directions]
face_centers = [sum((directions[i] for i in face), Vector()).normalized() for face in triangles]
face_points = [logical(center) for center in face_centers]
original_land = [land_at(x, y) for x, y in face_points]

# Consume the exact previous material RNG stream before changing classification.
# New geometry/color calculations must not reorder the existing scenery.
for is_land, (x, y) in zip(original_land, face_points):
    if not is_land:
        continue
    old_coastal = sum(not land_at(x + dx, y + dy) for dx, dy in
                     [(25, 0), (-25, 0), (0, 25), (0, -25)]) >= 2
    if not old_coastal or biome_at(x, y) in ('ice', 'volcanic'):
        RNG.randrange(3)
water_tiers = []
for is_land, (x, y) in zip(original_land, face_points):
    old_coast = not is_land and any(land_at(x + dx, y + dy) for dx, dy in
                                  [(50, 0), (-50, 0), (0, 45), (0, -45)])
    water_tiers.append(3 + RNG.randrange(2) if old_coast else RNG.randrange(3))

edge_faces = {}
neighbors = [set() for _ in triangles]
for fi, face in enumerate(triangles):
    for a, b in zip(face, face[1:] + face[:1]):
        key = tuple(sorted((a, b)))
        if key in edge_faces:
            other = edge_faces[key]
            neighbors[fi].add(other)
            neighbors[other].add(fi)
        else:
            edge_faces[key] = fi
assert all(len(n) == 3 for n in neighbors), 'Closed sphere must have three neighbors per triangle.'

# Sea-route seeds protect narrow water components regardless of ocean connectivity.
face_land = list(original_land)
unvisited = {i for i, value in enumerate(face_land) if not value}
water_components = []
water_component_members = []
filled_faces, lake_faces = set(), set()
while unvisited:
    seed = min(unvisited)
    unvisited.remove(seed)
    component, queue = [], deque([seed])
    while queue:
        fi = queue.popleft()
        component.append(fi)
        for other in neighbors[fi]:
            if other in unvisited:
                unvisited.remove(other)
                queue.append(other)
    mx = median(face_points[i][0] for i in component)
    my = median(face_points[i][1] for i in component)
    named = [name for name, (x0, x1, y0, y1) in LAKES.items() if x0 <= mx <= x1 and y0 <= my <= y1]
    has_route = any(distance(sea_kd, *face_points[i]) < 16 for i in component)
    # Large open oceans can have their median in a lake bounding box; only a
    # bounded component is classified as a named lake.
    if named and len(component) < 500:
        lake_faces.update(component)
    elif not has_route and len(component) <= 6:
        filled_faces.update(component)
        for fi in component:
            face_land[fi] = True
    status = 'filled_fragment' if component[0] in filled_faces else 'preserved'
    water_components.append({'faces': len(component), 'median_logical': [mx, my],
                             'lake': named if len(component) < 500 else [],
                             'sea_route_seed': has_route, 'status': status})
    water_component_members.append(component)
    if status == 'preserved' and not named and not has_route and 7 <= len(component) < 500:
        print('PRESERVED_UNREGISTERED_WATER', len(component), round(mx), round(my), flush=True)

# A bounding box is a locator, not permission for isolated pixels nearby to
# become extra lakes. Keep the principal component of each named water body;
# route-seeded fragments remain protected regardless of size.
principal_lakes = {name: max((i for i, c in enumerate(water_components) if name in c['lake']),
                            key=lambda i: water_components[i]['faces'], default=-1)
                   for name in LAKES}
for i, component in enumerate(water_components):
    names = component['lake']
    if (names and component['faces'] <= 6 and not component['sea_route_seed']
            and all(principal_lakes[name] != i for name in names)):
        members = water_component_members[i]
        filled_faces.update(members)
        lake_faces.difference_update(members)
        for fi in members:
            face_land[fi] = True
        component['status'] = 'filled_fragment'
        component['lake'] = []
        component['reason'] = 'detached fragment beside principal named water body'


def surface_rings(want_land):
    rings = [0] * len(triangles)
    queue = deque()
    for fi, value in enumerate(face_land):
        if value == want_land and any(face_land[n] != value for n in neighbors[fi]):
            rings[fi] = 1
            queue.append(fi)
    while queue:
        fi = queue.popleft()
        for other in neighbors[fi]:
            if face_land[other] == want_land and rings[other] == 0:
                rings[other] = rings[fi] + 1
                queue.append(other)
    return rings


land_ring, water_ring = surface_rings(True), surface_rings(False)
boundary_edges = set()
for fi, face in enumerate(triangles):
    if not face_land[fi]:
        continue
    for a, b in zip(face, face[1:] + face[:1]):
        key = tuple(sorted((a, b)))
        other = edge_faces[key]
        if other == fi:
            other = next(n for n in neighbors[fi] if a in triangles[n] and b in triangles[n])
        if not face_land[other]:
            boundary_edges.add(key)

# Boundary samples in the full logical longitude domain (6144, not the
# original map's 4096-pixel crop). This also covers the decorative rear islands.
coast_samples = []
for a, b in sorted(boundary_edges):
    for t in (0, .25, .5, .75, 1):
        x, y = logical(directions[a].lerp(directions[b], t))
        coast_samples.extend((x + offset, y) for offset in (-LONGITUDE_PERIOD, 0, LONGITUDE_PERIOD))
coast_kd = make_kd(coast_samples)
heights = [elevation(x, y) for x, y in logical_points]
land_vertices = [tuple(n * (R + h)) for n, h in zip(directions, heights)]
land_faces, land_indices, edge_counts = [], [], Counter()
material_names = list(MATS)
material_indices = {name: i for i, name in enumerate(material_names)}
biome_counts = Counter()
land_face_source = []
for fi, face in enumerate(triangles):
    x, y = face_points[fi]
    if not face_land[fi]:
        continue
    biome = biome_at(x, y)
    biome_counts[biome] += 1
    name = 'sand0' if land_ring[fi] == 1 and biome not in ('ice', 'volcanic') else biome + '0'
    land_faces.append(face)
    land_face_source.append(fi)
    land_indices.append(material_indices[name])
    for a, b in zip(face, face[1:] + face[:1]):
        edge_counts[tuple(sorted((a, b)))] += 1
land = mesh('spherical_continents_and_biomes', land_vertices, land_faces, list(MATS.values()), land_indices)
land_surface = BVHTree.FromPolygons(land_vertices, land_faces, all_triangles=True)


def surface_point(x, y, offset=0):
    """Read the exported triangle surface, rather than its analytic envelope."""
    n = normal(x, y)
    hit = land_surface.ray_cast(n * (R + 4), -n, 8)[0]
    return None if hit is None else hit + n * offset


def surface_height(x, y):
    hit = surface_point(x, y)
    return None if hit is None else hit.length - R

# Real radial cliffs close every coastline down to the ocean shell.
cliff_vertices, cliff_faces = [], []
for face in land_faces:
    for a, b in zip(face, face[1:] + face[:1]):
        if edge_counts[tuple(sorted((a, b)))] != 1:
            continue
        i = len(cliff_vertices)
        cliff_vertices += [land_vertices[a], tuple(directions[a] * (R + .012)),
                           tuple(directions[b] * (R + .012)), land_vertices[b]]
        cliff_faces.append((i, i + 1, i + 2, i + 3))
cliffs = mesh('radial_coastal_cliffs', cliff_vertices, cliff_faces, [MATS['coast0']])

water = mesh('complete_faceted_ocean_sphere', [tuple(n * (R + .03)) for n in directions], triangles, [MATS['ocean0']])
coast_data = water.data.color_attributes.new(name='coast', type='FLOAT_COLOR', domain='CORNER')
water.data.color_attributes.active_color = coast_data
for polygon, tier in zip(water.data.polygons, water_tiers):
    for li in polygon.loop_indices:
        vi = water.data.loops[li].vertex_index
        d = coast_distance(*logical_points[vi])
        coast_data.data[li].color = (clamp(d / 260), 1 - smoothstep(3, 22, d), tier / 4, 1)

props = []
tree_variants = Counter()


def orient(obj, x, y, height, spin=0, rng=RNG):
    n = normal(x, y)
    obj.location = n * (R + height)
    obj.rotation_mode = 'QUATERNION'
    obj.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(n)
    if spin:
        from mathutils import Quaternion
        obj.rotation_quaternion = obj.rotation_quaternion @ Quaternion(Vector((0, 0, 1)), spin)
    props.append(obj)
    return obj


def cone(name, x, y, bottom, height, radius, mat, sides=7, top=0, rng=RNG):
    bpy.ops.mesh.primitive_cone_add(vertices=sides, radius1=radius, radius2=top, depth=height)
    obj = bpy.context.object
    obj.name = name
    obj.data.materials.append(MATS[mat])
    return orient(obj, x, y, bottom + height / 2, rng.random() * math.tau, rng=rng)


def tree(x, y, h, tropical=False, rng=RNG):
    # Exactly the original draw count: one uniform, trunk spin, and two
    # crown spins for temperate trees (one crown spin for palms).
    scale = rng.uniform(.8, 1.35)
    trunk_h = (.42 if tropical else .20) * scale
    cone('radial_tree_trunk', x, y, h, trunk_h, .045 * scale, 'wood0', 5, .027 * scale, rng=rng)
    if tropical:
        # Five chunky fronds follow a small radial crown, each is actual geometry.
        verts = [(0, 0, trunk_h + .04)]
        faces = []
        for i in range(5):
            angle = i * math.tau / 5
            cx, cy = math.cos(angle), math.sin(angle)
            b = len(verts)
            verts += [(cx * .24 - cy * .09, cy * .24 + cx * .09, trunk_h + .10),
                      (cx * .49, cy * .49, trunk_h - .11),
                      (cx * .24 + cy * .09, cy * .24 - cx * .09, trunk_h + .10)]
            faces += [(0, b, b + 1), (0, b + 1, b + 2)]
        obj = mesh('five_leaf_palm_crown', verts, faces, [MATS['palm0']])
        orient(obj, x, y, h, rng.random() * math.tau, rng=rng)
        tree_variants['tropical:palm' if rng is RNG else 'oasis:palm'] += 1
    else:
        bucket = hash((round(x / 9), round(y / 9))) % 100
        biome = biome_at(x, y)
        kind = ('pine' if bucket < 50 else 'round' if bucket < 85 else 'broad') if biome == 'forest' else ('round' if bucket < 60 else 'broad')
        tree_variants[biome + ':' + kind] += 1
        lower, upper = ('pine_tip0', 'pine0') if bucket & 1 else ('pine0', 'pine_tip0')
        if kind == 'pine':
            cone('lower_pine_crown', x, y, h + .11, .48 * scale, .20 * scale, lower, 6, .025, rng=rng)
            cone('upper_pine_crown', x, y, h + .30, .42 * scale, .15 * scale, upper, 6, rng=rng)
        else:
            lower, upper = ('leaf0', 'pine_tip0') if bucket & 1 else ('pine_tip0', 'leaf0')
            # Two joined polygon rings give a rounded / spreading silhouette,
            # while preserving the two original cone RNG draws.
            width, lower_h, upper_h = (.24, .22, .27) if kind == 'round' else (.34, .15, .18)
            cone(kind + '_lower_crown', x, y, h + trunk_h * .70,
                 lower_h * scale, .13 * scale, lower, 8, width * scale, rng=rng)
            cone(kind + '_upper_crown', x, y, h + trunk_h * .70 + lower_h * scale,
                 upper_h * scale, width * scale, upper, 8, rng=rng)


# Distribute across the sphere by area, then form readable clusters per biome.
accepted = []
for _ in range(3000):
    lon = RNG.uniform(-math.pi, math.pi)
    lat = math.asin(RNG.uniform(-.97, .97))
    x, y = 2048 + lon / LON_SCALE, 681.5 - lat / LAT_SCALE
    if not land_at(x, y) or distance(route_kd, x, y) < 78 or distance(city_kd, x, y) < 150:
        continue
    biome = biome_at(x, y)
    cluster = .5 + .5 * math.sin(lon * 8 + math.cos(lat * 9)) * math.cos(lat * 13)
    probability = {'forest': .85, 'grass': .27, 'tropical': .58, 'desert': .07, 'ice': .04, 'volcanic': .12}[biome]
    if RNG.random() > probability * cluster:
        continue
    n = normal(x, y)
    if any((n - other).length < .032 for other in accepted):
        continue
    accepted.append(n)
    h = elevation(x, y)
    if biome in ('forest', 'grass', 'tropical'):
        tree(x, y, h, biome == 'tropical')
    else:
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=RNG.uniform(.10, .22))
        obj = bpy.context.object
        obj.name = 'radial_biome_boulder'
        obj.scale = (1.25, .8, .75)
        obj.data.materials.append(MATS['snow0' if biome == 'ice' else 'stone0'])
        orient(obj, x, y, h + .06)

def split_radial_snowline(vertices, faces, radius):
    """Partition real faces at one radial snowline, without layered white skins."""
    source = [Vector(v) for v in vertices]
    points = list(source)
    intersections = {}
    rock_faces, snow_faces = [], []

    def crossing(a, b):
        key = tuple(sorted((a, b)))
        if key not in intersections:
            # A shared original edge gets exactly one shared seam vertex.
            start, end = source[key[0]], source[key[1]]
            start_above = start.length >= radius
            lo, hi = 0.0, 1.0
            for _ in range(48):
                t = (lo + hi) / 2
                if (start.lerp(end, t).length >= radius) == start_above:
                    lo = t
                else:
                    hi = t
            point = start.lerp(end, (lo + hi) / 2)
            intersections[key] = len(points)
            points.append(point)
        return intersections[key]

    for face in faces:
        for above, target in ((False, rock_faces), (True, snow_faces)):
            polygon = []
            for a, b in zip(face, face[1:] + face[:1]):
                a_above, b_above = source[a].length >= radius, source[b].length >= radius
                if a_above == above:
                    polygon.append(a)
                if a_above != b_above:
                    polygon.append(crossing(a, b))
            for j in range(1, len(polygon) - 1):
                target.append((polygon[0], polygon[j], polygon[j + 1]))
    return [tuple(p) for p in points], rock_faces, snow_faces, len(intersections)


# Designed mountain silhouettes, with snow only at the summit.
original_mountains = []
for cx, cy, wx, wy, amplitude in RIDGES:
    for _ in range(9):
        x, y = cx + RNG.uniform(-wx, wx), cy + RNG.uniform(-wy, wy)
        if not land_at(x, y) or distance(route_kd, x, y) < 83 or distance(city_kd, x, y) < 175:
            continue
        h = elevation(x, y)
        peak = RNG.uniform(.78, 1.38)
        radius = RNG.uniform(.35, .58)
        rock = cone('radial_sculpted_mountain', x, y, h - .025, peak, radius, 'stone0', 7)
        mountain = {'logical': [x, y], 'base_height': h - .025, 'peak_height': peak,
                    'radius': radius, 'snowline_radius': None}
        if amplitude > .4:
            # Preserve the exact former snow-cone spin draw. Its independent
            # orientation and 0.025 apex overshoot caused the paper-fan slivers;
            # snow is now a partition of this rock, with no second silhouette.
            RNG.random()
            rock.data.calc_loop_triangles()
            vertices = [tuple(rock.location + rock.rotation_quaternion @ v.co) for v in rock.data.vertices]
            faces = [tuple(t.vertices) for t in rock.data.loop_triangles]
            snowline = R + h + peak * .59
            split_vertices, rock_faces, snow_faces, seam_vertices = split_radial_snowline(vertices, faces, snowline)
            replacement = mesh('radial_sculpted_mountain_partition', split_vertices, rock_faces, [MATS['stone0']])
            props.append(replacement)
            snow = mesh('ivory_snow_peak_partition', split_vertices, snow_faces, [MATS['snow0']])
            props.append(snow)
            props.remove(rock)
            bpy.data.objects.remove(rock, do_unlink=True)
            mountain.update(snowline_radius=snowline, rock_triangles=len(rock_faces),
                            snow_triangles=len(snow_faces), snowline_shared_vertices=seam_vertices)
        original_mountains.append(mountain)

# Broad asymmetric dunes make the desert read as relief rather than a color fill.
dunes = []
dune_grounding = []
for _ in range(180):
    x, y = RNG.uniform(600, 2740), RNG.uniform(160, 1070)
    if biome_at(x, y) != 'desert' or not land_at(x, y):
        continue
    if distance(route_kd, x, y) < 105 or distance(city_kd, x, y) < 190:
        continue
    if any(math.dist((x, y), p) < 110 for p in dunes):
        continue
    dunes.append((x, y))
    width, depth, height = RNG.uniform(.65, 1.1), RNG.uniform(.28, .52), RNG.uniform(.16, .28)
    verts = [(-width, -depth, 0), (width, -depth, 0), (width * .65, depth, 0),
             (-width * .65, depth, 0), (-width * .5, depth * .32, height),
             (width * .5, depth * .32, height * .9)]
    faces = [(0, 1, 5, 4), (4, 5, 2, 3), (0, 4, 3), (1, 2, 5), (0, 3, 2, 1)]
    dune = mesh('sculpted_desert_dune', verts, faces, [MATS['desert1']])
    orient(dune, x, y, elevation(x, y) - .02, .6)
    # The former single center height floated above ridge shoulders. A tangent
    # plane also rises radially toward its corners, so merely using the minimum
    # analytic corner height does not completely fix it. Embed the entire radial
    # skirt below the sampled *triangle* surface; preserve both crest directions.
    rotation = dune.rotation_quaternion
    footprint = [logical(dune.location + rotation @ Vector(v)) for v in verts[:4]]
    perimeter = []
    for a, b in zip(footprint, footprint[1:] + footprint[:1]):
        perimeter.extend((a[0] + (b[0] - a[0]) * t / 12,
                          a[1] + (b[1] - a[1]) * t / 12) for t in range(13))
    base_height = min(.012 if surface_height(*p) is None else surface_height(*p)
                      for p in perimeter) - .018
    for i, vertex in enumerate(dune.data.vertices):
        px, py = logical(dune.location + rotation @ Vector(verts[i]))
        h = base_height if i < 4 else (surface_height(px, py) or .012) + verts[i][2]
        target = normal(px, py) * (R + h)
        vertex.co = rotation.inverted() @ (target - dune.location)
    dune_grounding.append({'logical': [x, y], 'skirt_height': base_height,
                          'minimum_skirt_embed_depth': min((surface_height(*p) if surface_height(*p) is not None else .012) - base_height for p in perimeter),
                          'support_samples': len(perimeter)})
    if len(dunes) == 16:
        break

# Three deliberately composed oases. The old nominal Arabian / Taklamakan
# locations intersect frozen dune footprints; these sites were checked against
# the actual land triangles, route buffers, cities, and all sixteen dune anchors.
oasis_stats = []
pool_vertices, pool_faces, pool_colors = [], [], []


def clip_pool_polygon(polygon, a, b):
    """Clip (logical XY, world point) pairs against a CCW nonagon edge."""
    def side(v):
        return (b[0] - a[0]) * (v[0][1] - a[1]) - (b[1] - a[1]) * (v[0][0] - a[0])
    result = []
    for start, end in zip(polygon, polygon[1:] + polygon[:1]):
        ds, de = side(start), side(end)
        if ds >= -1e-8:
            result.append(start)
        if (ds >= 0) != (de >= 0):
            t = ds / (ds - de)
            xy = (start[0][0] + (end[0][0] - start[0][0]) * t,
                  start[0][1] + (end[0][1] - start[0][1]) * t)
            result.append((xy, start[1].lerp(end[1], t)))
    return result


def point_in_triangle(point, vertices):
    a, b, c = vertices
    u, v, w = b - a, c - a, point - a
    uv, uu, vv = u.dot(v), u.dot(u), v.dot(v)
    denominator = uu * vv - uv * uv
    s = (vv * w.dot(u) - uv * w.dot(v)) / denominator
    t = (uu * w.dot(v) - uv * w.dot(u)) / denominator
    plane_error = abs(u.cross(v).normalized().dot(w))
    return plane_error < 1e-5 and s >= -1e-6 and t >= -1e-6 and s + t <= 1 + 1e-6


for oasis in OASES:
    x, y, outer, rw = (oasis[k] for k in ('x', 'y', 'radius', 'water_radius'))
    assert biome_at(x, y) == 'desert' and land_at(x, y)
    assert distance(route_kd, x, y) >= 105 and distance(city_kd, x, y) >= 190
    dune_distance = min(math.dist((x, y), p) for p in dunes)
    assert dune_distance >= 130, (oasis['name'], 'dune collision', dune_distance)
    assert all(surface_point(x + outer * math.cos(i * math.tau / 72),
                             y + outer * math.sin(i * math.tau / 72)) is not None for i in range(72))
    plant_positions, rock_positions = [], []
    for i in range(oasis['palms']):
        for attempt in range(256):
            angle = (i / oasis['palms']) * math.tau + OASIS_RNG.uniform(-.35, .35) + attempt * .12
            radius = OASIS_RNG.uniform(max(rw + 12, outer * .54), outer * .84)
            tx, ty = x + math.cos(angle) * radius, y + math.sin(angle) * radius
            h = surface_height(tx, ty)
            if (h is None or distance(route_kd, tx, ty) < 78 or distance(city_kd, tx, ty) < 150
                    or any(math.dist((tx, ty), p) < 19 for p in plant_positions)):
                continue
            tree(tx, ty, h - .01, True, rng=OASIS_RNG)
            plant_positions.append((tx, ty))
            break
        else:
            raise AssertionError(('No safe palm site', oasis['name'], i))
    for i in range(oasis['rocks']):
        for attempt in range(256):
            angle = OASIS_RNG.uniform(0, math.tau)
            radius = OASIS_RNG.uniform(rw + 8, outer * .83)
            tx, ty = x + math.cos(angle) * radius, y + math.sin(angle) * radius
            h = surface_height(tx, ty)
            if h is None or distance(route_kd, tx, ty) < 78 or distance(city_kd, tx, ty) < 150:
                continue
            bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=OASIS_RNG.uniform(.10, .18))
            obj = bpy.context.object
            obj.name = 'oasis_bank_boulder'
            obj.scale = (1.1, .75, .65)
            obj.data.materials.append(MATS['stone0'])
            orient(obj, tx, ty, h + .035, OASIS_RNG.uniform(0, math.tau), rng=OASIS_RNG)
            rock_positions.append((tx, ty))
            break
        else:
            raise AssertionError(('No safe rock site', oasis['name'], i))

    # Clip the existing land triangles to the pool outline. This gives a radial
    # curved patch only 0.018 above the actual faceted ground, including triangle
    # edges; a single tangent disc can otherwise cut through its own bank.
    outline = [(x + rw * math.cos(i * math.tau / 9), y + rw * math.sin(i * math.tau / 9)) for i in range(9)]
    inner = [(x + rw * .65 * math.cos(i * math.tau / 9), y + rw * .65 * math.sin(i * math.tau / 9)) for i in range(9)]
    cells = [inner] + [[inner[i], outline[i], outline[(i + 1) % 9], inner[(i + 1) % 9]] for i in range(9)]
    water_center = surface_point(x, y)
    assert water_center is not None
    first_face = len(pool_faces)
    for face in land_faces:
        raw_xy = [logical_points[vi] for vi in face]
        # Unwrap each triangle as one continuous longitude branch, then move
        # the entire triangle by an integer period. Independently wrapping each
        # corner around the oasis only moves the cut to its opposite meridian.
        anchor = raw_xy[0][0]
        xy = [(anchor + (px - anchor + LONGITUDE_PERIOD / 2) % LONGITUDE_PERIOD - LONGITUDE_PERIOD / 2, py)
              for px, py in raw_xy]
        shift = round((x - sum(p[0] for p in xy) / 3) / LONGITUDE_PERIOD) * LONGITUDE_PERIOD
        xy = [(px + shift, py) for px, py in xy]
        if (max(p[0] for p in xy) < x - rw or min(p[0] for p in xy) > x + rw
                or max(p[1] for p in xy) < y - rw or min(p[1] for p in xy) > y + rw):
            continue
        source_triangle = [Vector(land_vertices[vi]) for vi in face]
        for cell_index, cell in enumerate(cells):
            polygon = list(zip(xy, source_triangle))
            for a, b in zip(cell, cell[1:] + cell[:1]):
                polygon = clip_pool_polygon(polygon, a, b)
                if len(polygon) < 3:
                    break
            if len(polygon) < 3:
                continue
            # A perimeter-only polygon makes all interpolated G values foam.
            # The inner ring holds calm water; the actual center becomes a
            # vertex of its own land triangle. Other fan points are affine
            # averages within that same original plane, never analytic heights.
            center = water_center if cell_index == 0 and point_in_triangle(water_center, source_triangle) else sum((p[1] for p in polygon), Vector()) / len(polygon)
            points = [center] + [p[1] for p in polygon]
            base_index = len(pool_vertices)
            variation = (len(pool_faces) % 5) / 4
            for world in points:
                actual_x, actual_y = logical(world)
                actual_dx = (actual_x - x + LONGITUDE_PERIOD / 2) % LONGITUDE_PERIOD - LONGITUDE_PERIOD / 2
                d = math.hypot(actual_dx, actual_y - y)
                assert d <= rw + 1.5, (oasis['name'], 'pool escaped its local surface', actual_x, actual_y)
                pool_vertices.append(tuple(world + world.normalized() * .018))
                pool_colors.append((0, 1 - smoothstep(1, 7, max(0, rw - d)), variation, 1))
            for j in range(len(polygon)):
                a, b = j + 1, (j + 1) % len(polygon) + 1
                if (points[a] - center).cross(points[b] - center).length > 1e-10:
                    pool_faces.append((base_index, base_index + a, base_index + b))
    oasis_stats.append(dict(oasis, route_distance=distance(route_kd, x, y),
                            city_distance=distance(city_kd, x, y), coast_distance=coast_distance(x, y),
                            nearest_dune_distance=dune_distance, palm_positions=plant_positions,
                            rock_positions=rock_positions, pool_triangles=len(pool_faces) - first_face,
                            pool_ground_offset=.018, pool_inner_radius=rw * .65))
oasis_pools = mesh('oasis_pools', pool_vertices, pool_faces, [MATS['shallow0']])
props.append(oasis_pools)
pool_data = oasis_pools.data.color_attributes.new(name='coast', type='FLOAT_COLOR', domain='CORNER')
oasis_pools.data.color_attributes.active_color = pool_data
for polygon in oasis_pools.data.polygons:
    for li in polygon.loop_indices:
        pool_data.data[li].color = pool_colors[oasis_pools.data.loops[li].vertex_index]

# Shared, curved mountain bodies. Alternating shoulder / saddle / main-peak
# sections make a genuinely connected ridge instead of three isolated cones.




range_stats = []
for config in RANGES:
    centers, peaks = config['points'], config['heights']
    start = (centers[0][0] + (centers[0][0] - centers[1][0]) * .17,
             centers[0][1] + (centers[0][1] - centers[1][1]) * .17)
    end = (centers[2][0] + (centers[2][0] - centers[1][0]) * .17,
           centers[2][1] + (centers[2][1] - centers[1][1]) * .17)
    sections = [(start, .035), (centers[0], peaks[0]),
                (((centers[0][0] + centers[1][0]) / 2, (centers[0][1] + centers[1][1]) / 2), .24),
                (centers[1], peaks[1]),
                (((centers[1][0] + centers[2][0]) / 2, (centers[1][1] + centers[2][1]) / 2), .25),
                (centers[2], peaks[2]), (end, .035)]
    vertices, faces, footprint = [], [], []
    for i, ((x, y), height) in enumerate(sections):
        a, b = sections[max(0, i - 1)][0], sections[min(len(sections) - 1, i + 1)][0]
        length = math.dist(a, b)
        cross = (-(b[1] - a[1]) / length, (b[0] - a[0]) / length)
        half_width = (13 if i in (0, len(sections) - 1) else 30) * RANGE_RNG.uniform(.94, 1.04)
        for side in (1, 0, -1):
            px, py = x + cross[0] * half_width * side, y + cross[1] * half_width * side
            ground = surface_point(px, py)
            assert ground is not None and land_at(px, py), (config['name'], 'off land', px, py)
            assert distance(route_kd, px, py) >= 83 and distance(city_kd, px, py) >= 175, (config['name'], 'protected footprint', px, py)
            footprint.append((px, py))
            vertices.append(tuple(ground + ground.normalized() * (height if side == 0 else -.025)))
    for i in range(len(sections) - 1):
        a, b = i * 3, (i + 1) * 3
        faces += [(a, b, b + 1), (a, b + 1, a + 1),
                  (a + 1, b + 1, b + 2), (a + 1, b + 2, a + 2)]
    faces += [(0, 1, 2), (18, 20, 19)]
    latitude = abs((681.5 - centers[1][1]) * LAT_SCALE)
    snow_fraction = .41 * smoothstep(math.radians(28), math.radians(55), latitude) + .1 * max(peaks) / .9
    snowline = max(Vector(vertices[i * 3 + 1]).length for i in (1, 3, 5)) - max(peaks) * snow_fraction
    split_vertices, rock_faces, snow_faces, seam_vertices = split_radial_snowline(vertices, faces, snowline)
    body = mesh('continuous_ridge_' + config['name'], split_vertices, rock_faces, [MATS['stone0']])
    props.append(body)
    if snow_faces:
        snow = mesh('continuous_ridge_snow_' + config['name'], split_vertices, snow_faces, [MATS['snow0']])
        props.append(snow)
    range_stats.append(dict(config, sections=[dict(logical=p, height=h) for p, h in sections],
                            triangles=len(rock_faces) + len(snow_faces), footprint=footprint,
                            rock_triangles=len(rock_faces), snow_triangles=len(snow_faces),
                            snowline_radius=snowline, snowline_shared_vertices=seam_vertices,
                            min_route_distance=min(distance(route_kd, *p) for p in footprint),
                            min_city_distance=min(distance(city_kd, *p) for p in footprint)))

# A distinctive volcanic rear island, radial caldera with a low lava pool.
vx = 2048 + math.radians(155) / LON_SCALE
vy = 681.5 - math.radians(20) / LAT_SCALE
vh = elevation(vx, vy)
crater_vertices = []
for radius, height in [(.66, 0), (.29, .72), (.245, .55)]:
    crater_vertices.extend((radius * math.cos(i * math.tau / 9),
                            radius * math.sin(i * math.tau / 9), height) for i in range(9))
crater_faces = [(ring * 9 + i, ring * 9 + (i + 1) % 9,
                 (ring + 1) * 9 + (i + 1) % 9, (ring + 1) * 9 + i)
                for ring in range(2) for i in range(9)]
caldera = mesh('open_volcanic_caldera', crater_vertices, crater_faces, [MATS['dark_stone0']])
orient(caldera, vx, vy, vh)
cone('warm_crater_pool', vx, vy, vh + .552, .015, .245, 'lava0', 9, .245)

# Static scenery is merged by material; city and actor meshes remain independent.
for mat in [m for name, m in MATS.items() if name.startswith(('pine', 'leaf', 'wood', 'palm', 'stone', 'snow', 'dark_stone', 'lava')) or name == 'desert1']:
    group = [obj for obj in props if obj.name in bpy.data.objects and obj.data.materials[0] == mat]
    if not group:
        continue
    bpy.ops.object.select_all(action='DESELECT')
    for obj in group:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = group[0]
    bpy.ops.object.join()
    group[0].name = 'sphere_scenery_' + mat.name
    props = [o for o in bpy.context.scene.objects if o.type == 'MESH' and o not in (land, cliffs, water)]

terrain_objects = [land, cliffs] + props


def export(objects, path):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(path), export_format='GLB', use_selection=True,
                              export_yup=True, export_apply=True, export_materials='EXPORT',
                              export_lights=False, export_cameras=False,
                              export_vertex_color='ACTIVE')


def update_oasis_pool_only():
    """Replace just pool buffers, preserving every other exported mesh and AO."""
    import copy
    import struct
    import tempfile

    def read_glb(path):
        blob = path.read_bytes()
        assert blob[:4] == b'glTF'
        json_size = struct.unpack_from('<I', blob, 12)[0]
        data = json.loads(blob[20:20 + json_size])
        binary_start = 20 + json_size
        binary_size = struct.unpack_from('<I', blob, binary_start)[0]
        return data, blob[binary_start + 8:binary_start + 8 + binary_size]

    def pool_node(data):
        return next(n for n in data['nodes'] if n.get('name') == 'oasis_pools')

    target = OUT / 'terrain.glb'
    old_blob = target.read_bytes()
    data, original_binary = read_glb(target)
    original_json = copy.deepcopy(data)
    old_node = pool_node(data)
    old_mesh_index = old_node['mesh']
    old_material = data['meshes'][old_mesh_index]['primitives'][0]['material']
    binary = bytearray(original_binary)
    with tempfile.TemporaryDirectory(prefix='silkroad-oasis-pool-') as folder:
        temporary = Path(folder) / 'oasis.glb'
        export([oasis_pools], temporary)
        new, new_binary = read_glb(temporary)
        new_node = pool_node(new)
        for key in ('matrix', 'translation', 'rotation', 'scale'):
            assert old_node.get(key) == new_node.get(key), ('Pool transform changed', key)
        view_map, accessor_map = {}, {}

        def append_accessor(index):
            if index not in accessor_map:
                accessor = copy.deepcopy(new['accessors'][index])
                old_view = accessor['bufferView']
                if old_view not in view_map:
                    view = copy.deepcopy(new['bufferViews'][old_view])
                    start = view.get('byteOffset', 0)
                    while len(binary) % 4:
                        binary.append(0)
                    view['byteOffset'] = len(binary)
                    binary.extend(new_binary[start:start + view['byteLength']])
                    view['buffer'] = 0
                    view_map[old_view] = len(data['bufferViews'])
                    data['bufferViews'].append(view)
                accessor['bufferView'] = view_map[old_view]
                accessor_map[index] = len(data['accessors'])
                data['accessors'].append(accessor)
            return accessor_map[index]

        primitives = copy.deepcopy(new['meshes'][new_node['mesh']]['primitives'])
        for primitive in primitives:
            primitive['attributes'] = {key: append_accessor(index) for key, index in primitive['attributes'].items()}
            primitive['indices'] = append_accessor(primitive['indices'])
            primitive['material'] = old_material
        data['meshes'][old_mesh_index]['primitives'] = primitives
        while len(binary) % 4:
            binary.append(0)
        data['buffers'][0]['byteLength'] = len(binary)
        assert binary[:len(original_binary)] == original_binary
        assert data['nodes'] == original_json['nodes'] and data['materials'] == original_json['materials']
        assert all(mesh == original_json['meshes'][i] for i, mesh in enumerate(data['meshes']) if i != old_mesh_index)
        json_bytes = json.dumps(data, separators=(',', ':')).encode()
        json_bytes += b' ' * (-len(json_bytes) % 4)
        packed = (struct.pack('<4sII', b'glTF', 2, 12 + 8 + len(json_bytes) + 8 + len(binary))
                  + struct.pack('<I4s', len(json_bytes), b'JSON') + json_bytes
                  + struct.pack('<I4s', len(binary), b'BIN\0') + binary)
        target.write_bytes(packed)
        stats_path = OUT / 'planet-stats.json'
        stats = json.loads(stats_path.read_text())
        old_count = sum(o['pool_triangles'] for o in stats['oases'])
        stats['terrain_triangles'] += len(pool_faces) - old_count
        stats['oases'] = oasis_stats
        assert stats['main_rng_state_sha256'] == hashlib.sha256(repr(RNG.getstate()).encode()).hexdigest()
        assert stats['water_glb_sha256'] == hashlib.sha256((OUT / 'water.glb').read_bytes()).hexdigest()
        stats_path.write_text(json.dumps(stats, indent=2) + '\n')

        # Keep the editable scene in sync without rebaking or touching its
        # cities, lighting, camera, or any other mesh's baked attributes.
        blend_path = DOC / 'source/planet.blend'
        bpy.ops.wm.open_mainfile(filepath=str(blend_path))
        destination = bpy.data.objects['oasis_pools']
        preview_material = destination.data.materials[0]
        before = set(bpy.context.scene.objects)
        bpy.ops.import_scene.gltf(filepath=str(temporary))
        imported = set(bpy.context.scene.objects) - before
        source = next(o for o in imported if o.type == 'MESH')
        replacement = source.data.copy()
        replacement.transform(destination.matrix_world.inverted() @ source.matrix_world)
        replacement.color_attributes.active_color.name = 'coast'
        replacement.materials.clear()
        replacement.materials.append(preview_material)
        destination.data = replacement
        for obj in imported:
            bpy.data.objects.remove(obj, do_unlink=True)
        bpy.ops.wm.save_as_mainfile(filepath=str(blend_path))
        proof = {'before_sha256': hashlib.sha256(old_blob).hexdigest(),
                 'after_sha256': hashlib.sha256(packed).hexdigest(),
                 'unchanged_original_binary_prefix_bytes': len(original_binary),
                 'non_pool_mesh_json_identical': True, 'node_and_material_json_identical': True,
                 'previous_pool_triangles': old_count, 'pool_triangles': len(pool_faces),
                 'terrain_triangles': stats['terrain_triangles'],
                 'water_sha256': stats['water_glb_sha256']}
        proof_path = DOC / 'validation/variation-007/pool-data-pass/update-proof.json'
        proof_path.parent.mkdir(parents=True, exist_ok=True)
        proof_path.write_text(json.dumps(proof, indent=2) + '\n')
        print('OASIS_POOL_ONLY_COMPLETE', json.dumps(proof), flush=True)


if '--oasis-pool-only' in __import__('sys').argv:
    update_oasis_pool_only()
    raise SystemExit(0)

# Actual city GLBs participate as AO occluders before terrain export; they are
# still exported separately and do not become duplicate runtime city meshes.
for city in CITIES:
    city_id = city['id']
    path = ROOT / 'assets/game/lowpoly/cities' / (city_id + '.glb')
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    imported = set(bpy.context.scene.objects) - before
    roots = [obj for obj in imported if obj.parent not in imported]
    x, y = city['map_position'][0], city['map_position'][1] - 85
    root = bpy.data.objects.new('PreviewCity_' + city_id, None)
    bpy.context.collection.objects.link(root)
    n = normal(x, y)
    lon = (x - 2048) * LON_SCALE
    east = Vector((math.cos(lon), math.sin(lon), 0))
    north = n.cross(east)
    from mathutils import Matrix
    root.matrix_world = Matrix((east, north, n)).transposed().to_4x4()
    root.location = n * (R + .08)
    for obj in roots:
        obj.parent = root


def srgb_to_linear(value):
    return value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4


def linear_to_srgb(value):
    return value * 12.92 if value <= .0031308 else 1.055 * value ** (1 / 2.4) - .055


def rgb(hex_value):
    return tuple(int(hex_value[i:i + 2], 16) / 255 for i in (0, 2, 4))


def mix_color(a, b, weight):
    return tuple(x + (y - x) * weight for x, y in zip(a, b))


def ground_color(x, y, biome, shore_distance):
    palette = [rgb(c) for c in COLORS[biome]]
    # A broad color field produces related neighboring facets, without using
    # the prop placement RNG or assigning unrelated colors to every triangle.
    variation = .5 + .5 * math.sin(x * .008 + math.cos(y * .011))
    base = mix_color(palette[1], palette[2], variation) if len(palette) > 2 else palette[0]
    if biome == 'desert':
        broad = ridge_field(x, y)
        gobi = smoothstep(.03, .10, broad) * (1 - smoothstep(.18, .30, broad))
        base = mix_color(base, rgb(SUBCOLORS['gobi']), gobi)
        ellipse = math.hypot((x - 2400) / 200, (y - 500) / 90)
        grass_edge = 2650 + 105 * math.sin(y * .008) - x
        red_rock = (1 - smoothstep(.55, 1, ellipse)) * smoothstep(0, 80, grass_edge)
        base = mix_color(base, rgb(SUBCOLORS['red_rock']), red_rock)
        for oasis in OASES:
            d = math.hypot(x - oasis['x'], y - oasis['y'])
            rw, outer = oasis['water_radius'], oasis['radius']
            base = mix_color(base, rgb(SUBCOLORS['oasis_bank']), .8 * (1 - smoothstep(rw, outer, d)))
            base = mix_color(base, rgb(SUBCOLORS['oasis_water']), 1 - smoothstep(rw * .45, rw, d))
    if biome not in ('ice', 'volcanic'):
        base = mix_color(rgb(COLORS['sand'][0]), base, smoothstep(18, 45, shore_distance))
        river_field = 1 - smoothstep(8, 26, distance(river_kd, x, y))
        base = mix_color(base, rgb(COLORS['shallow'][1]), .75 * river_field)
    return base


scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 16
scene.render.bake.target = 'VERTEX_COLORS'
scene.world.light_settings.distance = .8
bpy.context.view_layer.update()
ao_stats = {}
for obj in terrain_objects:
    # COLOR_0 on the three pooled water patches is shader data, never AO/albedo.
    if obj == oasis_pools:
        continue
    bases = [None] * len(obj.data.loops)
    for pi, polygon in enumerate(obj.data.polygons):
        center = obj.matrix_world @ polygon.center
        x, y = logical(center)
        noise = 1 + .07 * math.sin(x * .05 + y * .037) * math.cos(y * .021)
        mat = obj.data.materials[polygon.material_index]
        material_base = tuple(linear_to_srgb(c) for c in mat.diffuse_color[:3])
        for li in polygon.loop_indices:
            if obj == land:
                fi = land_face_source[pi]
                vi = obj.data.loops[li].vertex_index
                base = ground_color(*logical_points[vi], biome_at(*face_points[fi]),
                                    coast_distance(*logical_points[vi]))
            else:
                base = material_base
            bases[li] = tuple(clamp(c * noise) for c in base)
    attr = obj.data.color_attributes.new(name='Col', type='FLOAT_COLOR', domain='CORNER')
    obj.data.color_attributes.active_color = attr
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.bake(type='AO')
    samples = []
    for li, base in enumerate(bases):
        ao = clamp(sum(attr.data[li].color[:3]) / 3)
        samples.append(ao)
        color = tuple(linear_to_srgb(srgb_to_linear(c) * (.45 + .55 * ao)) for c in base)
        # Store sRGB values explicitly: Godot Compatibility consumes COLOR_0
        # without linearizing the glTF vertex attribute.
        attr.data[li].color = (*color, 1)
    ao_stats[obj.name] = {'loops': len(samples), 'min': min(samples),
                          'mean': sum(samples) / len(samples),
                          'fraction_below_0_8': sum(v < .8 for v in samples) / len(samples)}
    print('VERTEX_AO_COMPLETE', obj.name, ao_stats[obj.name], flush=True)

for mat in MATS.values():
    mat.diffuse_color = (1, 1, 1, 1)
    mat.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (1, 1, 1, 1)
export(terrain_objects, OUT / 'terrain.glb')
# Variation007 changes land only. In particular, exporting this unchanged ocean
# through a different scene/material list can still alter GLB container bytes.
water_sha = hashlib.sha256((OUT / 'water.glb').read_bytes()).hexdigest()
assert water_sha == '4a1ae95cef9e1d497976d8278c484f404ff807abb4cba66fe6e5819f18f317d3', 'Frozen ocean asset changed.'

cliff_tops = [(Vector(v).length - R - .03) for i, v in enumerate(cliff_vertices) if i % 4 in (0, 3)]
stats = {'shape': 'complete sphere', 'radius': R, 'longitude_scale': LON_SCALE,
         'latitude_scale': LAT_SCALE, 'logical_center': [2048, 681.5],
         'biome_faces': dict(biome_counts), 'scenery_clusters': len(accepted), 'sculpted_dunes': len(dunes),
         'scenery_direction_sha256': hashlib.sha256(json.dumps([list(n) for n in accepted]).encode()).hexdigest(),
         'dune_positions_sha256': hashlib.sha256(json.dumps(dunes).encode()).hexdigest(),
         'terrain_triangles': sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in terrain_objects),
         'water_triangles': len(triangles), 'terrain_objects': len(terrain_objects),
         'visual_revision': 'TASK-PLANET-VARIATION-007',
         'oases': oasis_stats, 'ranges': range_stats, 'tree_variants': dict(tree_variants),
         'original_mountains': original_mountains,
         'dune_grounding': dune_grounding, 'rivers': RIVERS,
         'oasis_pool_color_0': {'R': '0 shallow water', 'G': 'narrow shoreline foam band',
                               'B': 'stable polygon variation; no AO bake'},
         'water_glb_sha256': water_sha,
         'main_rng_state_sha256': hashlib.sha256(repr(RNG.getstate()).encode()).hexdigest(),
         'longitude_period': LONGITUDE_PERIOD,
         'filled_water_fragment_faces': len(filled_faces),
         'water_components_before_cleanup': water_components,
         'registered_lake_faces': len(lake_faces),
         'shoreline_edges': len(boundary_edges),
         'land_shore_faces': land_ring.count(1), 'water_shore_faces': water_ring.count(1),
         'cliff_height_above_water': {'min': min(cliff_tops), 'median': median(cliff_tops), 'max': max(cliff_tops)},
         'water_color_0': {'R': 'coast distance / 260 logical pixels, clamped',
                           'G': '1 - smoothstep(3, 22, coast distance)', 'B': 'original stable face tier / 4'},
         'ao_bake': {'samples': 16, 'distance': .8, 'city_occluders': len(CITIES),
                     'linear_strength': .55, 'objects': ao_stats},
         'rule_source_sha256': {n: hashlib.sha256((DATA / n).read_bytes()).hexdigest()
                                for n in ['cities.json', 'board_nodes.json', 'board_edges.json']},
         'coast_reference_sha256': hashlib.sha256(image_path.read_bytes()).hexdigest(),
         'rear_islands': 'scenery only; no additional rule nodes or routes'}
(OUT / 'planet-stats.json').write_text(json.dumps(stats, indent=2) + '\n')

# The .blend preview decodes the deliberately sRGB-encoded runtime attribute.
# These preview-only nodes are connected after export so the GLB stays white
# albedo times COLOR_0 and requires no textures or Blender shader nodes.
for mat in MATS.values():
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    attribute = nodes.new('ShaderNodeVertexColor')
    attribute.layer_name = 'Col'
    gamma = nodes.new('ShaderNodeGamma')
    gamma.inputs['Gamma'].default_value = 2.2
    links.new(attribute.outputs['Color'], gamma.inputs['Color'])
    links.new(gamma.outputs['Color'], nodes['Principled BSDF'].inputs['Base Color'])
water_preview = bpy.data.materials.new('PreviewOceanDistanceRamp')
water_preview.use_nodes = True
nodes, links = water_preview.node_tree.nodes, water_preview.node_tree.links
attribute = nodes.new('ShaderNodeVertexColor')
attribute.layer_name = 'coast'
separate = nodes.new('ShaderNodeSeparateColor')
ramp = nodes.new('ShaderNodeValToRGB')
ramp.color_ramp.elements[0].color = tuple(linear(c) for c in ('49', '97', '99')) + (1,)
ramp.color_ramp.elements[1].position = .7
ramp.color_ramp.elements[1].color = tuple(linear(c) for c in ('16', '49', '6E')) + (1,)
links.new(attribute.outputs['Color'], separate.inputs['Color'])
links.new(separate.outputs['Red'], ramp.inputs['Fac'])
links.new(ramp.outputs['Color'], nodes['Principled BSDF'].inputs['Base Color'])
nodes['Principled BSDF'].inputs['Roughness'].default_value = .3
water.data.materials[0] = water_preview
oasis_pools.data.materials[0] = water_preview

scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 32
scene.render.resolution_x = 1400
scene.render.resolution_y = 1400
scene.render.resolution_percentage = 100
scene.world.use_nodes = True
scene.world.node_tree.nodes['Background'].inputs[0].default_value = (.055, .105, .135, 1)
scene.world.node_tree.nodes['Background'].inputs[1].default_value = .4
bpy.ops.object.light_add(type='AREA', location=(-18, -22, 28))
light = bpy.context.object
light.data.energy = 6500
light.data.size = 20
light.data.color = (1, .90, .75)
light.rotation_euler = (-light.location).to_track_quat('-Z', 'Y').to_euler()
bpy.ops.object.light_add(type='AREA', location=(20, -8, 9))
light = bpy.context.object
light.data.energy = 3600
light.data.size = 15
light.data.color = (.62, .80, 1)
light.rotation_euler = (-light.location).to_track_quat('-Z', 'Y').to_euler()
bpy.ops.object.camera_add(location=(8, -33, 13))
camera = bpy.context.object
camera.data.type = 'PERSP'
camera.data.lens = 42
camera.rotation_euler = (-camera.location).to_track_quat('-Z', 'Y').to_euler()
scene.camera = camera
scene.view_settings.view_transform = 'AgX'
scene.render.image_settings.file_format = 'PNG'
scene.render.filepath = str(DOC / 'previews/planet-front.png')
bpy.ops.wm.save_as_mainfile(filepath=str(DOC / 'source/planet.blend'))
# The same local refinement is used by full rebuilds and by the surgical
# --detail-012-only path. It does not consume the world's random streams.
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from planet_detail_012 import apply_details
stats = apply_details(ROOT)
scene = bpy.context.scene
camera = scene.camera
bpy.ops.render.render(write_still=True)
camera.location = (-8, 33, 12)
camera.rotation_euler = (-camera.location).to_track_quat('-Z', 'Y').to_euler()
for light in [o for o in bpy.context.scene.objects if o.type == 'LIGHT']:
    light.location.x *= -1
    light.location.y *= -1
    light.rotation_euler = (-light.location).to_track_quat('-Z', 'Y').to_euler()
scene.render.filepath = str(DOC / 'previews/planet-rear.png')
bpy.ops.render.render(write_still=True)
print('SILKROAD_PLANET_COMPLETE', json.dumps(stats))
