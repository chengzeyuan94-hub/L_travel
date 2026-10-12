"""Build the isolated Heijokyo terrain sample using the existing Atlas mesh.

Run in a separate Blender background process, never in the live artist session:
  Blender --background --factory-startup --python tools/merchant_terrain_remodel_20260923.py

Only exports tile 62. Original world-space X/Z, indices and all shared seam
vertices are preserved; a local grass palette fades into untouched edges.
The .blend contains an editable shape key and original color attribute
and read-only original city/context. No project scene or input asset is saved.
"""
import collections
import hashlib
import json
import math
from pathlib import Path
import struct

import bpy
from mathutils import Vector


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "generated/traveler/atlas/assets"
OUT = ROOT / "docs/design/merchant-map-remodel-20260923"
TILE = 62
CENTER = (53.82, 5.724)


def read_glb(path):
    data = path.read_bytes()
    assert data[:4] == b"glTF"
    size = struct.unpack_from("<I", data, 12)[0]
    doc = json.loads(data[20:20 + size])
    binary_start = 20 + size + 8
    return doc, bytearray(data[binary_start:])


def accessor(doc, binary, number):
    a = doc["accessors"][number]
    view = doc["bufferViews"][a["bufferView"]]
    components = {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[a["type"]]
    fmt = {5126: "f", 5125: "I", 5123: "H"}[a["componentType"]]
    size = struct.calcsize("<" + fmt * components)
    start = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = view.get("byteStride", size)
    return [struct.unpack_from("<" + fmt * components, binary, start + i * stride)
            for i in range(a["count"])]


def patch_accessor(doc, binary, number, values):
    a = doc["accessors"][number]
    view = doc["bufferViews"][a["bufferView"]]
    start = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = view.get("byteStride", 12)
    for i, value in enumerate(values):
        struct.pack_into("<3f", binary, start + i * stride, *value)
    a["min"] = [min(v[axis] for v in values) for axis in range(3)]
    a["max"] = [max(v[axis] for v in values) for axis in range(3)]


def write_glb(path, doc, binary):
    encoded = json.dumps(doc, separators=(",", ":")).encode()
    encoded += b" " * ((-len(encoded)) % 4)
    binary += b"\0" * ((-len(binary)) % 4)
    size = 12 + 8 + len(encoded) + 8 + len(binary)
    path.write_bytes(struct.pack("<4sII", b"glTF", 2, size)
                     + struct.pack("<I4s", len(encoded), b"JSON") + encoded
                     + struct.pack("<I4s", len(binary), b"BIN\0") + binary)


def key(v):
    return (round(v[0], 5), round(v[2], 5))


def segment_distance(p, a, b):
    dx, dz = b[0] - a[0], b[1] - a[1]
    length = dx * dx + dz * dz
    t = max(0, min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dz) / length)) if length else 0
    return math.hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dz)


def smoothstep(a, b, v):
    t = max(0, min(1, (v - a) / (b - a)))
    return t * t * (3 - 2 * t)


def point_in_triangle(p, tri):
    signs = [(tri[(i + 1) % 3][0] - tri[i][0]) * (p[1] - tri[i][1])
             - (tri[(i + 1) % 3][1] - tri[i][1]) * (p[0] - tri[i][0]) for i in range(3)]
    return min(signs) >= -1e-8 or max(signs) <= 1e-8


def cross2(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def intersects(a, b, c, d):
    if max(a[0], b[0]) < min(c[0], d[0]) or max(c[0], d[0]) < min(a[0], b[0]):
        return False
    if max(a[1], b[1]) < min(c[1], d[1]) or max(c[1], d[1]) < min(a[1], b[1]):
        return False
    return cross2(a, b, c) * cross2(a, b, d) <= 0 and cross2(c, d, a) * cross2(c, d, b) <= 0


def triangle_near_segment(tri, a, b, margin):
    if point_in_triangle(a, tri) or point_in_triangle(b, tri):
        return True
    for i in range(3):
        c, d = tri[i], tri[(i + 1) % 3]
        if intersects(a, b, c, d):
            return True
        if min(segment_distance(a, c, d), segment_distance(b, c, d),
               segment_distance(c, a, b), segment_distance(d, a, b)) <= margin:
            return True
    return False


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


for folder in ["source", "exports/terrain", "review"]:
    (OUT / folder).mkdir(parents=True, exist_ok=True)

inputs = list((ASSETS / "terrain").glob("*.glb")) + list((ASSETS / "cities").glob("*.glb"))
inputs += [ROOT / "data/traveler/atlas/cities.json", ROOT / "data/traveler/formal-routes.json",
           ROOT / "generated/traveler/atlas/atlas_world.tscn"]
hashes = {str(p.relative_to(ROOT)): sha(p) for p in inputs}
tiles, owners, edge_counts = {}, collections.defaultdict(set), collections.Counter()
for index in range(1, 65):
    doc, binary = read_glb(ASSETS / "terrain" / f"{index:02d}.glb")
    primitive = doc["meshes"][0]["primitives"][0]
    positions = accessor(doc, binary, primitive["attributes"]["POSITION"])
    indices = [x[0] for x in accessor(doc, binary, primitive["indices"])]
    tiles[index] = (doc, binary, primitive, positions, indices)
    for p in positions:
        owners[key(p)].add(index)
    for offset in range(0, len(indices), 3):
        corners = [key(positions[i]) for i in indices[offset:offset + 3]]
        for j in range(3):
            edge_counts[tuple(sorted((corners[j], corners[(j + 1) % 3])))] += 1

shore = [e for e, count in edge_counts.items() if count == 1
         and min(p[0] for p in e) < 61 and max(p[0] for p in e) > 49
         and min(p[1] for p in e) < 10 and max(p[1] for p in e) > -6]
doc, binary, primitive, positions, indices = tiles[TILE]
colors = accessor(doc, binary, primitive["attributes"]["COLOR_0"])
original_normals = accessor(doc, binary, primitive["attributes"]["NORMAL"])

city = next(c for c in json.loads((ROOT / "data/traveler/atlas/cities.json").read_text()) if c["id"] == "heijokyo")
city_doc, city_bin = read_glb(ASSETS / "cities/heijokyo.glb")
city_bounds = []
for mesh in city_doc["meshes"]:
    for p in mesh["primitives"]:
        a = city_doc["accessors"][p["attributes"]["POSITION"]]
        city_bounds.extend([a["min"], a["max"]])
pad = .22
xmin = city["x"] + min(p[0] for p in city_bounds) * city["scale"] - pad
xmax = city["x"] + max(p[0] for p in city_bounds) * city["scale"] + pad
zmin = city["z"] + min(p[2] for p in city_bounds) * city["scale"] - pad
zmax = city["z"] + max(p[2] for p in city_bounds) * city["scale"] + pad
city_rectangle = [(xmin, zmin), (xmax, zmin), (xmax, zmax), (xmin, zmax)]

route_segments = []
for route in json.loads((ROOT / "data/traveler/formal-routes.json").read_text())["routes"]:
    for segment in route["segments"]:
        if segment["kind"] == "sea":
            continue
        points = segment["curve"]
        for a, b in zip(points, points[1:]):
            if max(a[0], b[0]) > 49 and min(a[0], b[0]) < 61 and min(a[2], b[2]) < 10 and max(a[2], b[2]) > -6:
                route_segments.append(((a[0], a[2]), (b[0], b[2])))

protected = set()
for offset in range(0, len(indices), 3):
    tri = [key(positions[i]) for i in indices[offset:offset + 3]]
    hits_city = any(xmin <= x <= xmax and zmin <= z <= zmax for x, z in tri)
    hits_city |= any(triangle_near_segment(tri, city_rectangle[i], city_rectangle[(i + 1) % 4], 0) for i in range(4))
    hits_route = any(triangle_near_segment(tri, a, b, .20) for a, b in route_segments)
    if hits_city or hits_route:
        protected.update(tri)

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
editable = bpy.data.collections.new("EDIT — Heijokyo T62 only")
context = bpy.data.collections.new("REFERENCE — original neighbors and city (locked)")
scene.collection.children.link(editable)
scene.collection.children.link(context)
context.hide_select = True

material = bpy.data.materials.new("Atlas original linear vertex colors")
material.use_nodes = True
shader = material.node_tree.nodes.get("Principled BSDF")
shader.inputs["Roughness"].default_value = .95
color_node = material.node_tree.nodes.new("ShaderNodeVertexColor")
color_node.layer_name = "AtlasLinearColor"
material.node_tree.links.new(color_node.outputs["Color"], shader.inputs["Base Color"])


def make_mesh(name, source_positions, source_indices, source_colors, collection):
    unique, lookup, corner_map = [], {}, []
    for p in source_positions:
        k = key(p)
        if k not in lookup:
            lookup[k] = len(unique)
            unique.append((p[0], -p[2], p[1]))
        corner_map.append(lookup[k])
    faces = [tuple(corner_map[i] for i in source_indices[o:o + 3]) for o in range(0, len(source_indices), 3)]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(unique, [], faces)
    mesh.update()
    attribute = mesh.color_attributes.new(name="AtlasLinearColor", type="FLOAT_COLOR", domain="CORNER")
    for polygon, offset in zip(mesh.polygons, range(0, len(source_indices), 3)):
        for li, i in zip(polygon.loop_indices, source_indices[offset:offset + 3]):
            attribute.data[li].color = (*source_colors[i][:3], 1.0)
        polygon.use_smooth = False
    obj = bpy.data.objects.new(name, mesh)
    collection.objects.link(obj)
    obj.data.materials.append(material)
    return obj, corner_map


terrain, corner_map = make_mesh("T62 — existing topology / local hillside sculpt", positions, indices, colors, editable)
terrain.shape_key_add(name="Basis — original Atlas")
sculpt = terrain.shape_key_add(name="Sample 01 — gentle Japanese foothills")
modified = []
for vertex in terrain.data.vertices:
    x, z, old_y = vertex.co.x, -vertex.co.y, vertex.co.z
    k = (round(x, 5), round(z, 5))
    if len(owners[k]) > 1 or k in protected:
        continue
    distance_to_shore = min(segment_distance((x, z), *edge) for edge in shore)
    shoreline_weight = smoothstep(.24, .72, distance_to_shore)
    # Two connected, restrained shoulders along the existing island spine.
    # Height change only; no land expansion or invented island/route position.
    south = .61 * math.exp(-((x - 56.6) / 1.32) ** 2 - ((z - 3.15) / 1.40) ** 2)
    north = .45 * math.exp(-((x - 58.05) / 1.05) ** 2 - ((z - .05) / 1.25) ** 2)
    delta = (south + north) * shoreline_weight * (1 - smoothstep(7.2, 8.0, math.hypot(x - CENTER[0], z - CENTER[1])))
    if delta < .002:
        continue
    sculpt.data[vertex.index].co.z = old_y + delta
    modified.append({"x": x, "z": z, "before_y": old_y, "after_y": old_y + delta,
                     "delta_y": delta, "shore_distance": distance_to_shore})
sculpt.value = 1.0
original_color_attribute = terrain.data.color_attributes.new(name="OriginalAtlasColor", type="FLOAT_COLOR", domain="CORNER")
revised_colors = []
seam_points = [k for k, o in owners.items() if TILE in o and len(o) > 1]
for p, color in zip(positions, colors):
    x, z = p[0], p[2]
    seam_distance = min(math.hypot(x - a, z - b) for a, b in seam_points)
    shore_distance = min(segment_distance((x, z), *edge) for edge in shore)
    radial = 1 - smoothstep(6.8, 8.0, math.hypot(x - CENTER[0], z - CENTER[1]))
    weight = radial * smoothstep(0, 1.4, seam_distance) * (.30 + .70 * smoothstep(0, .9, shore_distance))
    if len(owners[key(p)]) > 1:
        weight = 0
    target_color = (color[0] * .80 + .025, min(.85, color[1] * 1.50), color[2] * 1.05 + .025)
    revised_colors.append(tuple(color[c] * (1 - weight) + target_color[c] * weight for c in range(3)))
for polygon, offset in zip(terrain.data.polygons, range(0, len(indices), 3)):
    for li, i in zip(polygon.loop_indices, indices[offset:offset + 3]):
        original_color_attribute.data[li].color = (*colors[i][:3], 1.0)
        terrain.data.color_attributes["AtlasLinearColor"].data[li].color = (*revised_colors[i][:3], 1.0)
terrain["scope"] = "T62 only. X/Z, coastline, shared seams, city support and approach triangles fixed."
terrain["source"] = str(ASSETS / "terrain/62.glb")
terrain["source_sha256"] = hashes[str((ASSETS / "terrain/62.glb").relative_to(ROOT))]

for index, (j, b, p, ps, ids) in tiles.items():
    if index == TILE:
        continue
    bounds = j["accessors"][p["attributes"]["POSITION"]]
    if bounds["max"][0] < 47 or bounds["min"][0] > 63 or bounds["max"][2] < -6 or bounds["min"][2] > 13:
        continue
    obj, _ = make_mesh(f"REFERENCE T{index:02d}", ps, ids, accessor(j, b, p["attributes"]["COLOR_0"]), context)
    obj.hide_select = True

# City is a visual reference only, never re-exported or changed in the real game.
bpy.ops.import_scene.gltf(filepath=str(ASSETS / "cities/heijokyo.glb"))
imported = list(bpy.context.selected_objects)
city_parent = bpy.data.objects.new("REFERENCE Heijokyo — original asset, fixed placement", None)
context.objects.link(city_parent)
city_parent.location = (city["x"], -city["z"], city["base"] + .026)
city_parent.scale = (city["scale"],) * 3
city_parent.rotation_euler.z = city["rotation"]
for obj in imported:
    if obj.parent not in imported:
        obj.parent = city_parent
    for collection in list(obj.users_collection):
        collection.objects.unlink(obj)
    context.objects.link(obj)
    obj.hide_select = True

# Save an immediately inspectable Blender source with a matching local view.
camera_data = bpy.data.cameras.new("Sample review camera")
camera = bpy.data.objects.new("Sample review camera", camera_data)
scene.collection.objects.link(camera)
target = Vector((55.1, -3.3, .9))
camera.location = target + Vector((8, -16, 21))
camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
camera_data.type = "ORTHO"
camera_data.ortho_scale = 18
scene.camera = camera
scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage = 1920, 1080, 100
sun_data = bpy.data.lights.new("Review sun", "SUN")
sun_data.energy = 2
sun_data.angle = .06
sun = bpy.data.objects.new("Review sun", sun_data)
scene.collection.objects.link(sun)
sun.rotation_euler = (.6, -.5, -.3)
scene.world.color = (.25, .3, .38)
bpy.ops.object.select_all(action="DESELECT")
terrain.select_set(True)
bpy.context.view_layer.objects.active = terrain
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type == "VIEW_3D":
            area.spaces.active.region_3d.view_distance = 15
            area.spaces.active.region_3d.view_location = target
            area.spaces.active.region_3d.view_rotation = camera.rotation_euler.to_quaternion()
            area.spaces.active.shading.color_type = "VERTEX"
            area.spaces.active.clip_end = 1000

# Read the actual Blender shape key; patch original binary so colors/indices
# survive without glTF importer BYTE_COLOR quantization or vertex repacking.
revised = [(p[0], float(sculpt.data[corner_map[i]].co.z), p[2]) for i, p in enumerate(positions)]
normals = list(original_normals)
for offset in range(0, len(indices), 3):
    ids = indices[offset:offset + 3]
    if not any(revised[i] != positions[i] for i in ids):
        continue
    a, b, c = [Vector(revised[i]) for i in ids]
    normal = (b - a).cross(c - a).normalized()
    if normal.dot(Vector(original_normals[ids[0]])) < 0:
        normal = -normal
    for i in ids:
        normals[i] = tuple(normal)
patch_accessor(doc, binary, primitive["attributes"]["POSITION"], revised)
patch_accessor(doc, binary, primitive["attributes"]["NORMAL"], normals)
patch_accessor(doc, binary, primitive["attributes"]["COLOR_0"], revised_colors)
export = OUT / "exports/terrain/62.glb"
write_glb(export, doc, binary)

assert modified, "Protected region left no actual terrain modification"
assert all(revised[i][0] == p[0] and revised[i][2] == p[2] for i, p in enumerate(positions))
assert all(revised[i] == p for i, p in enumerate(positions) if len(owners[key(p)]) > 1 or key(p) in protected)
check_doc, check_bin = read_glb(export)
exported_colors = accessor(check_doc, check_bin, primitive["attributes"]["COLOR_0"])
assert all(exported_colors[i] == colors[i] for i, p in enumerate(positions) if len(owners[key(p)]) > 1)
assert accessor(check_doc, check_bin, primitive["indices"]) == [(i,) for i in indices]
assert all(sha(p) == hashes[str(p.relative_to(ROOT))] for p in inputs), "Input changed during build"
blend_path = OUT / "source/atlas-heijokyo-terrain-v1.blend"
bpy.ops.wm.save_as_mainfile(filepath=str(blend_path))
report = {"scope": "Heijokyo terrain T62 only", "source_assets_sha256": hashes,
          "export": str(export), "export_sha256": sha(export), "blend": str(blend_path),
          "triangles": len(indices) // 3, "unique_vertices": len(terrain.data.vertices),
          "modified_vertices": modified, "modified_count": len(modified),
          "max_height_delta": max(v["delta_y"] for v in modified),
          "city_protection_aabb_xz": [xmin, zmin, xmax, zmax], "protected_vertex_keys": len(protected),
          "invariants": {"all_original_files_unchanged": True, "xz_unchanged": True,
                         "shared_seams_unchanged": True, "shared_seam_colors_unchanged": True,
                         "indices_unchanged": True, "city_support_and_approach_triangles_unchanged": True},
          "local_palette": "Greener lowpoly grass, original colors retained as a Blender attribute; fades at seams and radius.",
          "coordinate_system": "GLB Y-up world positions; Blender uses (x,-z,y)."}
(OUT / "review/build-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print("HEIJOKYO_SAMPLE_BUILT", json.dumps({"vertices_modified": len(modified), "max_delta": report["max_height_delta"], "blend": str(blend_path)}))
