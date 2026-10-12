@tool
extends RefCounted
## 第四幕「L叔在哪儿」· crease (edge) data. One automatic rule for every mesh: an edge is a crease when the
## two faces sharing it meet at more than look.modules.edges.crease_deg. The mesh is rebuilt de-indexed with
## CUSTOM0 = (barycentric xyz, crease bits + 1); lshu_surface.gdshader draws a ~1 px catch-light on upward
## creases and a slight darkening on downward ones. Meshes without CUSTOM0 read w = 0 and are untouched.
##
## This runs OFFLINE, once per source mesh, from the import pipeline (tools/traveler/lshu/bake/
## lshu_post_import.gd): every prop mesh, and the proc roles listed in modules.edges.proc_roles of each tile.
## At runtime the scene only reports what it received (report()). @tool so the import script can call it.

const LOOK_PATH: String = "res://data/traveler/lshu/look.json"

## modules.edges of look.json ({crease_deg, proc_roles}); empty on a read error.
static func edges_config() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LOOK_PATH))
	if not parsed is Dictionary:
		return {}
	var modules: Dictionary = (parsed as Dictionary).get("modules", {})
	return modules.get("edges", {})

## Rebuilds src with CUSTOM0 crease data. stats accumulates meshes / triangles / creases.
static func process_mesh(src: ArrayMesh, crease_deg: float, stats: Dictionary) -> ArrayMesh:
	if src == null:
		return null
	var cos_limit: float = cos(deg_to_rad(crease_deg))
	var out: ArrayMesh = ArrayMesh.new()
	out.resource_name = src.resource_name
	for s: int in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var tri_count: int = (idx.size() if not idx.is_empty() else verts.size()) / 3
		var order: PackedInt32Array = PackedInt32Array()
		order.resize(tri_count * 3)
		for i: int in tri_count * 3:
			order[i] = idx[i] if not idx.is_empty() else i
		# face normals + edge adjacency on quantised positions
		var fn: PackedVector3Array = PackedVector3Array()
		fn.resize(tri_count)
		var edges: Dictionary = {}
		var keys: Array[Vector3i] = []
		keys.resize(verts.size())
		for v: int in verts.size():
			keys[v] = Vector3i(roundi(verts[v].x * 2000.0), roundi(verts[v].y * 2000.0), roundi(verts[v].z * 2000.0))
		for t: int in tri_count:
			var a: Vector3 = verts[order[t * 3]]
			var b: Vector3 = verts[order[t * 3 + 1]]
			var cc: Vector3 = verts[order[t * 3 + 2]]
			fn[t] = (b - a).cross(cc - a).normalized()
			for e: int in 3:
				var ka: Vector3i = keys[order[t * 3 + (e + 1) % 3]]
				var kb: Vector3i = keys[order[t * 3 + (e + 2) % 3]]
				var ek: String = _edge_key(ka, kb)
				if edges.has(ek):
					(edges[ek] as Array).append(t * 3 + e)
				else:
					edges[ek] = [t * 3 + e]
		var bits: PackedInt32Array = PackedInt32Array()
		bits.resize(tri_count)
		for ek: String in edges.keys():
			var users: Array = edges[ek]
			if users.size() != 2:
				continue
			var t0: int = int(users[0]) / 3
			var t1: int = int(users[1]) / 3
			if fn[t0] == Vector3.ZERO or fn[t1] == Vector3.ZERO:
				continue
			if fn[t0].dot(fn[t1]) < cos_limit:
				bits[t0] |= 1 << (int(users[0]) % 3)
				bits[t1] |= 1 << (int(users[1]) % 3)
				stats["creases"] = int(stats.get("creases", 0)) + 1
		# de-indexed output with CUSTOM0
		var new_arrays: Array = []
		new_arrays.resize(Mesh.ARRAY_MAX)
		var nv: PackedVector3Array = PackedVector3Array()
		var nn: PackedVector3Array = PackedVector3Array()
		var nc: PackedColorArray = PackedColorArray()
		var nuv: PackedVector2Array = PackedVector2Array()
		var custom: PackedFloat32Array = PackedFloat32Array()
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var count: int = tri_count * 3
		nv.resize(count)
		custom.resize(count * 4)
		if not normals.is_empty():
			nn.resize(count)
		if not colors.is_empty():
			nc.resize(count)
		if not uvs.is_empty():
			nuv.resize(count)
		for t: int in tri_count:
			for k: int in 3:
				var o: int = t * 3 + k
				var vi: int = order[o]
				nv[o] = verts[vi]
				if not normals.is_empty():
					nn[o] = normals[vi]
				if not colors.is_empty():
					nc[o] = colors[vi]
				if not uvs.is_empty():
					nuv[o] = uvs[vi]
				custom[o * 4] = 1.0 if k == 0 else 0.0
				custom[o * 4 + 1] = 1.0 if k == 1 else 0.0
				custom[o * 4 + 2] = 1.0 if k == 2 else 0.0
				custom[o * 4 + 3] = float(bits[t] + 1)
		new_arrays[Mesh.ARRAY_VERTEX] = nv
		if not nn.is_empty():
			new_arrays[Mesh.ARRAY_NORMAL] = nn
		if not nc.is_empty():
			new_arrays[Mesh.ARRAY_COLOR] = nc
		if not nuv.is_empty():
			new_arrays[Mesh.ARRAY_TEX_UV] = nuv
		new_arrays[Mesh.ARRAY_CUSTOM0] = custom
		var flags: int = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, new_arrays, [], {}, flags)
		out.surface_set_material(out.get_surface_count() - 1, src.surface_get_material(s))
		out.surface_set_name(out.get_surface_count() - 1, src.surface_get_name(s))
		stats["triangles"] = int(stats.get("triangles", 0)) + tri_count
	stats["meshes"] = int(stats.get("meshes", 0)) + 1
	return out

static func _edge_key(a: Vector3i, b: Vector3i) -> String:
	if a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z))):
		return "%d,%d,%d|%d,%d,%d" % [a.x, a.y, a.z, b.x, b.y, b.z]
	return "%d,%d,%d|%d,%d,%d" % [b.x, b.y, b.z, a.x, a.y, a.z]

## True when every surface of the mesh carries the CUSTOM0 crease channel.
static func has_edges(mesh: Mesh) -> bool:
	if mesh == null or mesh.get_surface_count() == 0:
		return false
	for s: int in mesh.get_surface_count():
		if (mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_CUSTOM0) == 0:
			return false
	return true

## Runtime evidence: how many of the given meshes arrived with crease data.
static func report(meshes: Array[MeshInstance3D]) -> Dictionary:
	var with_edges: int = 0
	var seen: Dictionary = {}
	for mi: MeshInstance3D in meshes:
		if mi == null or mi.mesh == null or seen.has(mi.mesh.get_instance_id()):
			continue
		seen[mi.mesh.get_instance_id()] = true
		if has_edges(mi.mesh):
			with_edges += 1
	return {"unique_meshes": seen.size(), "with_edges": with_edges, "source": "offline (import-time)"}
