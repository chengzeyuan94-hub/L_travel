"""Local, deterministic harbor/ridge refinement; no world remeshing or RNG.

Called by build_planet.py, or Blender --python build_planet.py --
--detail-012-only. Existing attribute buffers are kept byte-for-byte; only the
selected ridge component's indices and the named local meshes are replaced.
"""
from __future__ import annotations
import copy
import hashlib
import json
import math
import struct
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector
from mathutils.bvhtree import BVHTree

REVISION = 'TASK-PLANET-DETAIL-012'
LON = math.tau / 6144
LAT = math.pi / 2400
R = 11.0
RIDGE_NAME = 'detail_012_kunlun'
HARBOR_NAME = 'detail_012_quanzhou_harbor'
WATER_SHA = '4a1ae95cef9e1d497976d8278c484f404ff807abb4cba66fe6e5819f18f317d3'


def normal(x, y):
    a, b = (x - 2048) * LON, (681.5 - y) * LAT
    return Vector((math.cos(b) * math.sin(a), math.sin(b), math.cos(b) * math.cos(a)))


def logical(p):
    p = Vector(p).normalized()
    return (2048 + math.atan2(p.x, p.z) / LON,
            681.5 - math.asin(max(-1, min(1, p.y))) / LAT)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class GLB:
    def __init__(self, path):
        blob = Path(path).read_bytes()
        assert blob[:4] == b'glTF'
        n = struct.unpack_from('<I', blob, 12)[0]
        self.doc = json.loads(blob[20:20 + n])
        start = 20 + n
        size = struct.unpack_from('<I', blob, start)[0]
        self.binary = bytearray(blob[start + 8:start + 8 + size])

    def accessor(self, index):
        a = self.doc['accessors'][index]
        view = self.doc['bufferViews'][a['bufferView']]
        dtype = np.dtype({5126: '<f4', 5125: '<u4', 5123: '<u2', 5121: 'u1'}[a['componentType']])
        width = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}[a['type']]
        offset = view.get('byteOffset', 0) + a.get('byteOffset', 0)
        values = np.ndarray((a['count'], width), dtype=dtype, buffer=self.binary,
                            offset=offset, strides=(view.get('byteStride', width * dtype.itemsize), dtype.itemsize)).copy()
        if a.get('normalized'):
            values = values.astype(float) / np.iinfo(dtype).max
        return values

    def add_accessor(self, values, index=False):
        values = np.asarray(values, dtype='<u4' if index else '<f4')
        if values.ndim == 1:
            values = values[:, None]
        while len(self.binary) % 4:
            self.binary.append(0)
        view = dict(buffer=0, byteOffset=len(self.binary), byteLength=values.nbytes,
                    target=34963 if index else 34962)
        vi = len(self.doc['bufferViews'])
        self.doc['bufferViews'].append(view)
        self.binary.extend(values.tobytes())
        a = dict(bufferView=vi, componentType=5125 if index else 5126,
                 count=len(values), type={1: 'SCALAR', 2: 'VEC2', 3: 'VEC3', 4: 'VEC4'}[values.shape[1]])
        if values.shape[1] == 3 and not index:
            a['min'], a['max'] = values.min(axis=0).tolist(), values.max(axis=0).tolist()
        ai = len(self.doc['accessors'])
        self.doc['accessors'].append(a)
        return ai

    @staticmethod
    def matrix(node):
        if 'matrix' in node:
            return Matrix(np.asarray(node['matrix']).reshape(4, 4, order='F').tolist())
        q = node.get('rotation', [0, 0, 0, 1])
        return Matrix.LocRotScale(Vector(node.get('translation', [0, 0, 0])),
                                  Quaternion((q[3], q[0], q[1], q[2])),
                                  Vector(node.get('scale', [1, 1, 1])))

    def node(self, name):
        return next(n for n in self.doc['nodes'] if n.get('name') == name)

    def primitives(self, name):
        return self.doc['meshes'][self.node(name)['mesh']]['primitives']

    def geometry(self, name):
        node = self.node(name)
        matrix = self.matrix(node)
        assert not node.get('children'), 'Detail source must remain a direct static mesh node.'
        result = []
        for primitive in self.primitives(name):
            points = [matrix @ Vector(p) for p in self.accessor(primitive['attributes']['POSITION'])]
            faces = self.accessor(primitive['indices']).reshape(-1, 3).tolist()
            result.append((primitive, points, faces))
        return result

    def save(self, path):
        while len(self.binary) % 4:
            self.binary.append(0)
        self.doc['buffers'][0]['byteLength'] = len(self.binary)
        text = json.dumps(self.doc, separators=(',', ':')).encode()
        text += b' ' * (-len(text) % 4)
        blob = (struct.pack('<4sII', b'glTF', 2, 28 + len(text) + len(self.binary))
                + struct.pack('<I4s', len(text), b'JSON') + text
                + struct.pack('<I4s', len(self.binary), b'BIN\0') + self.binary)
        Path(path).write_bytes(blob)

    def count(self):
        return sum(len(self.accessor(p['indices'])) // 3 for n in self.doc['nodes'] if 'mesh' in n
                   for p in self.doc['meshes'][n['mesh']]['primitives'])


class Ground:
    def __init__(self, glb):
        points, faces = [], []
        for _, ps, fs in glb.geometry('spherical_continents_and_biomes'):
            start = len(points)
            points.extend(ps)
            faces.extend(tuple(start + i for i in f) for f in fs)
        self.tree = BVHTree.FromPolygons(points, faces, all_triangles=True)

    def point(self, x, y, offset=0):
        n = normal(x, y)
        hit = self.tree.ray_cast(n * 15, -n, 9)[0]
        return None if hit is None else hit + n * offset


def remove_old_kunlun(glb, ground, config):
    """Select the welded connected component containing the exact central peak.

    A bounding box would also remove nearby original mountains. Edge welding
    across the stone/snow primitive is required because their colors split the
    exported vertices at the common snowline.
    """
    sources, points, faces = [], [], []
    ids, cells = [], {}
    for name in ('sphere_scenery_stone0', 'sphere_scenery_snow0'):
        for primitive, ps, fs in glb.geometry(name):
            local = []
            for p in ps:
                key = tuple(round(c / 1e-5) for c in p)
                found = None
                for dx in (-1, 0, 1):
                    for dy in (-1, 0, 1):
                        for dz in (-1, 0, 1):
                            for j in cells.get((key[0] + dx, key[1] + dy, key[2] + dz), []):
                                if (points[j] - p).length < 5e-6:
                                    found = j
                if found is None:
                    found = len(points)
                    points.append(p)
                    cells.setdefault(key, []).append(found)
                local.append(found)
            sources.append((name, primitive, fs))
            for fi, face in enumerate(fs):
                faces.append(tuple(local[i] for i in face))
                ids.append((len(sources) - 1, fi))
    parent = list(range(len(points)))
    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    def union(a, b):
        parent[find(a)] = find(b)
    for a, b, c in faces:
        union(a, b)
        union(b, c)
    x, y = config['points'][1]
    expected = ground.point(x, y, config['heights'][1])
    nearest = min(range(len(points)), key=lambda i: (points[i] - expected).length)
    assert (points[nearest] - expected).length < 2e-5, 'Could not locate original Kunlun peak.'
    component = find(nearest)
    chosen = [(si, fi) for face, (si, fi) in zip(faces, ids) if find(face[0]) == component]
    assert len(chosen) == config['triangles'] == 38, ('Unexpected original ridge component', len(chosen))
    removed = {}
    for si, (name, primitive, fs) in enumerate(sources):
        selected = {fi for s, fi in chosen if s == si}
        if not selected:
            continue
        primitive['indices'] = glb.add_accessor([v for i, f in enumerate(fs) if i not in selected for v in f], True)
        removed[name] = len(selected)
    return removed


def split_snow(points, faces, radius):
    vertices = list(points)
    intersections = {}
    groups = [[], []]
    def crossing(a, b):
        key = tuple(sorted((a, b)))
        if key not in intersections:
            p, q = points[key[0]], points[key[1]]
            above = p.length >= radius
            lo, hi = 0.0, 1.0
            for _ in range(42):
                t = (lo + hi) / 2
                if (p.lerp(q, t).length >= radius) == above:
                    lo = t
                else:
                    hi = t
            intersections[key] = len(vertices)
            vertices.append(p.lerp(q, (lo + hi) / 2))
        return intersections[key]
    for face in faces:
        for side in (0, 1):
            polygon = []
            for a, b in zip(face, face[1:] + face[:1]):
                aa, bb = points[a].length >= radius, points[b].length >= radius
                if aa == bool(side):
                    polygon.append(a)
                if aa != bb:
                    polygon.append(crossing(a, b))
            groups[side].extend((polygon[0], polygon[i], polygon[i + 1]) for i in range(1, len(polygon) - 1))
    return vertices, groups, len(intersections)


def build_kunlun(ground, config):
    sections, footprint = config['sections'], config['footprint']
    across = [-1, -.82, -.60, -.34, 0, .34, .60, .82, 1]
    rows, vertices, ground_contacts = [], [], []
    for si in range(6):
        for t in (0, .28, .69):
            rows.append((si, t))
    rows.append((5, 1.0))
    for si, t in rows:
        left = Vector(footprint[si * 3]).lerp(Vector(footprint[(si + 1) * 3]), t)
        right = Vector(footprint[si * 3 + 2]).lerp(Vector(footprint[(si + 1) * 3 + 2]), t)
        ease = .85 * t + .15 * t * t * (3 - 2 * t)
        station_heights = [station['height'] for station in sections]
        station_heights[2], station_heights[4] = .15, .16
        h = station_heights[si] * (1 - ease) + station_heights[si + 1] * ease
        for c in across:
            bend = .065 * math.sin((si + .5) * 1.9) * math.sin(t * math.pi)
            shifted = c + bend * (1 - abs(c))
            xy = left.lerp(right, (shifted + 1) / 2)
            p = ground.point(*xy)
            assert p is not None
            # A narrow crest, two readable saddles and opposing side gullies.
            # Unequal stations/bends avoid a regular gridded, barrel-like top;
            # all three original peak vertices and fourteen skirt points stay.
            a = abs(c)
            profile = max(0, 1 - a ** .90)
            along = si + t
            ravine = (math.exp(-((along - 1.8) / .52) ** 2) * (.15 if c > 0 else .045)
                      + math.exp(-((along - 4.15) / .52) ** 2) * (.045 if c > 0 else .15))
            ravine *= math.exp(-((a - .60) / .24) ** 2) * math.sin(a * math.pi) ** 2
            height = h * max(0, profile - ravine)
            if a == 1:
                height = -.025
                ground_contacts.append(dict(logical=list(xy), world=list(p + p.normalized() * height)))
            vertices.append(p + p.normalized() * height)
    faces = []
    width = len(across)
    for row in range(len(rows) - 1):
        for col in range(width - 1):
            a = row * width + col
            faces.extend([(a, a + 1, a + width + 1), (a, a + width + 1, a + width)])
    for row, reverse in ((0, False), (len(rows) - 1, True)):
        # The base of each end fan lies on the two skirt endpoints. No white
        # cap is ever placed on a second overlapping copy of the rock surface.
        start = row * width
        cap = [(start, start + j, start + j + 1) for j in range(1, width - 1)]
        faces.extend([tuple(reversed(f)) for f in cap] if reverse else cap)
    vertices, groups, seam = split_snow(vertices, faces, config['snowline_radius'])
    metadata = dict(logical_bounds=[min(p[0] for p in footprint), min(p[1] for p in footprint),
                                   max(p[0] for p in footprint), max(p[1] for p in footprint)],
                    row_count=len(rows), cross_section_vertices=width,
                    rock_triangles=len(groups[0]), snow_triangles=len(groups[1]),
                    snowline_radius=config['snowline_radius'], snowline_shared_vertices=seam,
                    shoulder_exponent=.90, saddle_heights=[.15, .16], longitudinal_linear_mix=.85,
                    skirt_contacts=ground_contacts, original_footprint=footprint,
                    peak_contacts=[dict(logical=xy, world=list(ground.point(*xy, height)))
                                   for xy, height in zip(config['points'], config['heights'])])
    return vertices, groups, metadata


def build_harbor(glb, ground, root, previous=None):
    """A real east-coast landing, connected by broad pale paving to Quanzhou.

    The paving is decorative geometry, with volume and a light stone palette;
    it deliberately does not imitate the thin brown rules-route ribbons.
    """
    vertices, faces, contacts = [], [], []
    edges = json.loads((Path(root) / 'data/rulesets/lshu_configurable_v1/board_edges.json').read_text())['items']
    segments = [(Vector(a), Vector(b)) for edge in edges
                for a, b in zip(edge['movement_polyline'], edge['movement_polyline'][1:])]
    def route_distance(xy):
        p = Vector(xy)
        return min((p - a.lerp(b, max(0, min(1, (p - a).dot(b - a) / (b - a).length_squared)))).length
                   for a, b in segments if (b - a).length_squared > 1e-12)
    def append_box(corners, tops, bottoms):
        start = len(vertices)
        vertices.extend(tops + bottoms)
        faces.extend(tuple(start + i for i in f) for f in
                     [(0, 1, 2), (0, 2, 3), (4, 6, 5), (4, 7, 6),
                      (0, 4, 5), (0, 5, 1), (1, 5, 6), (1, 6, 2),
                      (2, 6, 7), (2, 7, 3), (3, 7, 4), (3, 4, 0)])
    city = normal(3103.585, 529.114)
    lon = (3103.585 - 2048) * LON
    east = Vector((math.cos(lon), 0, -math.sin(lon)))
    edge = city * (R + .08 + .045 * (2.1 / 1.9)) + east * 1.05
    start = logical(edge)
    path = [start, (3234, 524), (3271, 509), (3318, 489), (3345, 482), (3362, 483)]
    samples = []
    for a, b in zip(path, path[1:]):
        count = max(1, math.ceil(math.dist(a, b) / 12))
        samples.extend((a[0] + (b[0] - a[0]) * i / count,
                        a[1] + (b[1] - a[1]) * i / count) for i in range(count))
    samples.append(path[-1])
    sides = []
    for i in range(len(samples)):
        a, b = samples[max(0, i - 1)], samples[min(len(samples) - 1, i + 1)]
        span = math.dist(a, b)
        sides.append((-(b[1] - a[1]) / span, (b[0] - a[0]) / span))
    length = 0
    for i, (a, b) in enumerate(zip(samples, samples[1:])):
        span = math.dist(a, b)
        corners = [(p[0] + sign * side[0] * 7, p[1] + sign * side[1] * 7)
                   for p, side, sign in ((a, sides[i], -1), (b, sides[i + 1], -1),
                                         (b, sides[i + 1], 1), (a, sides[i], 1))]
        tops, bottoms = [], []
        for j, xy in enumerate(corners):
            p = ground.point(*xy)
            assert p is not None, ('Paving must stay on actual land', xy)
            travel = length + (span if j in (1, 2) else 0)
            ramp = max(0, 1 - travel / 32)
            rise = .016 + max(0, edge.length - p.length - .016) * ramp
            tops.append(p + p.normalized() * rise)
            bottoms.append(p - p.normalized() * .006)
            contacts.append(dict(kind='paving', logical=list(xy), ground_world=list(p), bottom_world=list(bottoms[-1])))
        append_box(corners, tops, bottoms)
        length += span

    paving_face_count = len(faces)
    # Actual low faceted shoreline: retain the existing top-edge positions,
    # add a sloping stone shelf and a submerged toe. Only this short cliff
    # segment's index triangles change; the continental surface stays exact.
    primitive, points, old_faces = glb.geometry('radial_coastal_cliffs')[0]
    edge_groups = {}
    for fi, face in enumerate(old_faces):
        key = tuple(sorted(set(tuple(round(c * 100000) for c in points[v].normalized()) for v in face)))
        if len(key) == 2:
            edge_groups.setdefault(key, []).append(fi)
    replaced, bank_edges, bank_world, active_bank_points = set(), [], [], []
    selected_edges = []
    for key, group in edge_groups.items():
        ps = [points[i] for fi in group for i in old_faces[fi]]
        top = [max((p for p in ps if tuple(round(c * 100000) for c in p.normalized()) == d), key=lambda p: p.length)
               for d in key]
        xy = [logical(p) for p in top]
        mid = ((xy[0][0] + xy[1][0]) / 2, (xy[0][1] + xy[1][1]) / 2)
        if not (3348 <= mid[0] <= 3384 and 465 <= mid[1] <= 503):
            continue
        replaced.update(group)
        selected_edges.append(top)
    if not selected_edges and previous:
        selected_edges = [[Vector(p) for p in pair] for pair in previous['coastline_top_world_edges']]
    for top in selected_edges:
        xy = [logical(p) for p in top]
        mid = ((xy[0][0] + xy[1][0]) / 2, (xy[0][1] + xy[1][1]) / 2)
        bank_edges.append(xy)
        bank_world.append([list(p) for p in top])
        span = math.dist(*xy)
        perp = Vector((-(xy[1][1] - xy[0][1]) / span, (xy[1][0] - xy[0][0]) / span))
        if ground.point(mid[0] + perp.x * 24, mid[1] + perp.y * 24) is not None:
            perp = -perp
        count = max(3, math.ceil(span / 8))
        base = len(vertices)
        for i in range(count + 1):
            t = i / count
            p = top[0].lerp(top[1], t)
            x, y = logical(p)
            strength = max(0, min(1, (route_distance((x, y)) - 32) / 10))
            vertices.extend([p, normal(x + perp.x * 2.4 * strength, y + perp.y * 2.4 * strength) * (R + .043),
                             normal(x + perp.x * 5.0 * strength, y + perp.y * 5.0 * strength) * (R + .012)])
            if strength > .0001:
                active_bank_points.append(logical(vertices[-1]))
        for i in range(count):
            for j in range(2):
                a = base + i * 3 + j
                faces.extend([(a, a + 1, a + 4), (a, a + 4, a + 3)])
        for endpoint in (base, base + count * 3):
            extra = len(vertices)
            vertices.append(vertices[endpoint].normalized() * (R + .012))
            faces.extend([(endpoint, endpoint + 1, extra), (endpoint + 1, endpoint + 2, extra)])
    assert bank_edges, 'East-harbor candidate is not an actual coast.'
    if replaced:
        primitive['indices'] = glb.add_accessor([v for i, f in enumerate(old_faces) if i not in replaced for v in f], True)

    bank_face_count = len(faces) - paving_face_count
    # Short supported landing: landward footing is embedded into the actual
    # rock; seaward pile bases remain beneath the unchanged R11.03 ocean.
    deck_xy = [(3357, 476), (3388, 476), (3388, 491), (3357, 491)]
    deck_height = .133
    for i in range(4):
        x0, x1 = 3357 + 31 * i / 4, 3357 + 31 * (i + 1) / 4
        corners = [(x0, 476), (x1, 476), (x1, 491), (x0, 491)]
        tops = [normal(*p) * (R + deck_height) for p in corners]
        bottoms = [normal(*p) * (R + deck_height - .035) for p in corners]
        append_box(corners, tops, bottoms)
    for x, y in [(3359, 478), (3359, 489), (3386, 478), (3386, 489)]:
        p = ground.point(x, y)
        bottom = (p.length - R - .018) if p is not None else -.055
        corners = [(x + dx, y + dy) for dx, dy in [(-1.5, -1.5), (1.5, -1.5), (1.5, 1.5), (-1.5, 1.5)]]
        append_box(corners, [normal(*xy) * (R + deck_height + .022) for xy in corners],
                   [normal(*xy) * (R + bottom) for xy in corners])
        contacts.append(dict(kind='pile', logical=[x, y], ground_world=list(p) if p is not None else None,
                             bottom_radius=R + bottom, deck_radius=R + deck_height))
    bounds = [logical(p) for p in vertices]
    metadata = dict(city='quanzhou', city_visual_center=[3103.585, 529.114],
                    city_edge_world=list(edge), path_centerline=[list(p) for p in path],
                    paving_face_count=paving_face_count, bank_face_count=bank_face_count,
                    paving_width_logical=14, coastline_top_edges=bank_edges, coastline_top_world_edges=bank_world,
                    original_cliff_triangles_removed=len(replaced) or (previous or {}).get('original_cliff_triangles_removed', 0), dock_polygon=deck_xy,
                    dock_top_radius=R + deck_height, contacts=contacts,
                    dock_route_distance_min=min(route_distance(p) for p in deck_xy),
                    paving_route_distance_min=min(route_distance(c['logical']) for c in contacts if c['kind'] == 'paving'),
                    new_offshore_bank_route_distance_min=min(route_distance(p) for p in active_bank_points),
                    logical_bounds=[min(p[0] for p in bounds), min(p[1] for p in bounds),
                                    max(p[0] for p in bounds), max(p[1] for p in bounds)])
    return vertices, [faces], metadata


def harbor_color(p, _material, face_id, metadata):
    x, _y = logical(p)
    if metadata['paving_face_count'] <= face_id < metadata['paving_face_count'] + metadata['bank_face_count']:
        return (.66, .61, .51, 1)
    if face_id >= metadata['paving_face_count'] + metadata['bank_face_count']:
        shade = .95 + .025 * ((face_id - metadata['paving_face_count'] - metadata['bank_face_count']) // 12 % 4)
        return (.62 * shade, .47 * shade, .30 * shade, 1)
    shade = 1 + .018 * math.sin(x * .12)
    return (.76 * shade, .72 * shade, .61 * shade, 1)



def add_mesh(glb, name, vertices, groups, material_names, color_function):
    primitives = []
    for group, mat_name in zip(groups, material_names):
        ps, ns, colors = [], [], []
        for face_id, face in enumerate(group):
            a, b, c = (Vector(vertices[i]) for i in face)
            n = (b - a).cross(c - a)
            if n.length < 1e-11:
                continue
            center = (a + b + c) / 3
            # These terrain patches expose their outward radial side.
            if n.dot(center) < 0:
                b, c = c, b
                n = -n
            n.normalize()
            for p in (a, b, c):
                ps.append(tuple(p)); ns.append(tuple(n)); colors.append(color_function(p, mat_name, face_id))
        material = next(i for i, m in enumerate(glb.doc['materials']) if m['name'] == mat_name)
        primitives.append(dict(attributes=dict(POSITION=glb.add_accessor(ps), NORMAL=glb.add_accessor(ns),
                                               COLOR_0=glb.add_accessor(colors)),
                               indices=glb.add_accessor(list(range(len(ps))), True), material=material))
    mesh = dict(name=name, primitives=primitives)
    existing = next((n for n in glb.doc['nodes'] if n.get('name') == name), None)
    if existing is not None:
        glb.doc['meshes'][existing['mesh']] = mesh
    else:
        mi = len(glb.doc['meshes'])
        glb.doc['meshes'].append(mesh)
        ni = len(glb.doc['nodes'])
        glb.doc['nodes'].append(dict(name=name, mesh=mi))
        glb.doc['scenes'][glb.doc.get('scene', 0)]['nodes'].append(ni)


def ridge_color(p, material, _face_id=0):
    # Source COLOR_0 is sRGB; the runtime already enables vertex albedo.
    # Keep the old warm rock/snow palette. Fine variation follows geometry and
    # has no random draws or baked lighting shared with unrelated regions.
    x, y = logical(p)
    if material == 'snow0':
        return (.86, .86, .81, 1)
    grain = 1 + .025 * math.sin(x * .042 + y * .019)
    return (.595 * grain, .557 * grain, .473 * grain, 1)


def update_blend(path, target, changed):
    bpy.ops.wm.open_mainfile(filepath=str(path))
    scene = bpy.context.scene
    before = set(scene.objects)
    original_materials = {m.name: m for m in bpy.data.materials}
    destinations = {name: bpy.data.objects.get(name) or next(
        (o for o in before if o.type == 'MESH' and o.name.startswith(name + '.')), None)
        for name in changed}
    bpy.ops.import_scene.gltf(filepath=str(target))
    imported = set(scene.objects) - before
    for name in changed:
        source = next(o for o in imported if o.type == 'MESH' and (o.name == name or o.name.startswith(name + '.')))
        destination = destinations[name]
        if destination is None:
            destination = bpy.data.objects.new(name, bpy.data.meshes.new(name))
            scene.collection.objects.link(destination)
        destinations[name] = destination
        replacement = source.data.copy()
        replacement.transform(destination.matrix_world.inverted() @ source.matrix_world)
        for i, material in enumerate(replacement.materials):
            base_name = material.name.split('.')[0]
            if base_name in original_materials:
                replacement.materials[i] = original_materials[base_name]
        if replacement.color_attributes.active_color is not None:
            replacement.color_attributes.active_color.name = 'Col'
        destination.data = replacement
    for obj in imported:
        bpy.data.objects.remove(obj, do_unlink=True)
    for name, destination in destinations.items():
        destination.name = name
    # Keep the editable planet's radial city preview in sync with this batch's
    # separately exported Quanzhou. Its placement is preserved; no AO rebake.
    city_root = bpy.data.objects.get('PreviewCity_quanzhou')
    city_path = Path(path).parents[4] / 'assets/game/lowpoly/cities/quanzhou.glb'
    if city_root is not None and city_root.get('source_glb_sha256') != digest(city_path):
        for obj in list(city_root.children_recursive):
            bpy.data.objects.remove(obj, do_unlink=True)
        city_before = set(scene.objects)
        bpy.ops.import_scene.gltf(filepath=str(city_path))
        city_objects = set(scene.objects) - city_before
        for obj in city_objects:
            if obj.parent not in city_objects:
                obj.parent = city_root
        city_root['source_glb_sha256'] = digest(city_path)
    bpy.ops.wm.save_as_mainfile(filepath=str(path))


def apply_details(root, output=None, update_source=True):
    root = Path(root)
    target = root / 'assets/game/lowpoly/planet/terrain.glb'
    stats_path = root / 'assets/game/lowpoly/planet/planet-stats.json'
    water = target.with_name('water.glb')
    assert digest(water) == WATER_SHA
    glb = GLB(target)
    before_binary = bytes(glb.binary)
    before_json = copy.deepcopy(glb.doc)
    stats = json.loads(stats_path.read_text())
    if stats.get('detail_012', {}).get('helper_sha256') == digest(__file__) and stats['detail_012'].get('source_updated'):
        if output is not None:
            import shutil
            folder = Path(output); folder.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, folder / 'terrain.glb'); shutil.copy2(stats_path, folder / 'planet-stats.json')
        print('PLANET_DETAIL_012_ALREADY_CURRENT', digest(target), flush=True)
        return stats
    before_count = glb.count()
    ground = Ground(glb)
    config = next(r for r in stats['ranges'] if r['name'] == 'kunlun')
    already = any(n.get('name') == RIDGE_NAME for n in glb.doc['nodes'])
    removed = {} if already else remove_old_kunlun(glb, ground, config)
    vertices, groups, ridge_meta = build_kunlun(ground, config)
    add_mesh(glb, RIDGE_NAME, vertices, groups, ['stone0', 'snow0'], ridge_color)
    if any(n.get('name') == HARBOR_NAME for n in glb.doc['nodes']):
        harbor_meta = stats['detail_012']['quanzhou_harbor']
        changed = [RIDGE_NAME]
    else:
        harbor_vertices, harbor_groups, harbor_meta = build_harbor(glb, ground, root)
        add_mesh(glb, HARBOR_NAME, harbor_vertices, harbor_groups, ['stone0'],
                 lambda p, m, i: harbor_color(p, m, i, harbor_meta))
        changed = ['sphere_scenery_stone0', 'sphere_scenery_snow0', 'radial_coastal_cliffs', RIDGE_NAME, HARBOR_NAME]
    after_count = glb.count()
    assert bytes(glb.binary[:len(before_binary)]) == before_binary
    assert glb.doc['materials'] == before_json['materials']
    untouched = [n['name'] for n in before_json['nodes'] if n['name'] not in changed]
    for name in untouched:
        old_node = next(n for n in before_json['nodes'] if n['name'] == name)
        assert glb.node(name) == old_node
        assert glb.doc['meshes'][old_node['mesh']] == before_json['meshes'][old_node['mesh']]
    delta = after_count - (stats.get('detail_012', {}).get('baseline_triangles', before_count))
    assert 0 <= delta <= 3000, ('Terrain detail budget exceeded', delta)
    stats['terrain_triangles'] = after_count
    stats['terrain_objects'] = sum('mesh' in n for n in glb.doc['nodes'])
    config['base_triangles_before_detail'] = 38
    config['triangles'] = sum(len(g) for g in groups)
    config['rock_triangles'], config['snow_triangles'] = (len(g) for g in groups)
    config['detail_mesh_name'] = RIDGE_NAME
    stats['visual_revision'] = REVISION
    stats['detail_012'] = dict(helper_sha256=digest(__file__), source_updated=False, baseline_triangles=stats.get('detail_012', {}).get('baseline_triangles', before_count),
                               triangles_added=delta, changed_meshes=['sphere_scenery_stone0', 'sphere_scenery_snow0', 'radial_coastal_cliffs', RIDGE_NAME, HARBOR_NAME],
                               last_updated_meshes=changed,
                               original_attribute_buffer_prefix_preserved=True,
                               removed_original_ridge_triangles=removed or stats.get('detail_012', {}).get('removed_original_ridge_triangles'),
                               kunlun=ridge_meta, quanzhou_harbor=harbor_meta)
    if output is not None:
        folder = Path(output); folder.mkdir(parents=True, exist_ok=True)
        final = folder / 'terrain.glb'
        glb.save(final)
        (folder / 'planet-stats.json').write_text(json.dumps(stats, indent=2) + '\n')
    else:
        final = target
        glb.save(final)
        stats_path.write_text(json.dumps(stats, indent=2) + '\n')
        if update_source:
            update_blend(root / 'docs/design/planet-v2/source/planet.blend', target, changed)
            stats['detail_012']['source_updated'] = True
            stats_path.write_text(json.dumps(stats, indent=2) + '\n')
    assert digest(water) == WATER_SHA
    print('PLANET_DETAIL_012_COMPLETE', json.dumps(dict(path=str(final), sha256=digest(final), triangles=after_count,
                                                     added=delta, changed=changed)), flush=True)
    return stats
