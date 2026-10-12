extends RefCounted
## L2 · crease highlight preprocessing (extra_scripts module). One automatic rule for every asset:
## each instance mesh (and the procedural structure / steps / cliff parts) is rebuilt once per source mesh
## with CUSTOM0 = (barycentric xyz, crease bits + 1). An edge is a crease when the two faces sharing it
## meet at more than cfg.crease_deg. l2_surface.gdshader then draws a ~1 px catch-light on upward creases
## and a slight darkening on downward ones (uniforms l2_edge / l2_edge_px / l2_edge_dark per role).
## Meshes without CUSTOM0 read w = 0 and are untouched. Role materials and surface overrides are kept.
var host: Node3D
var cfg: Dictionary = {}
var cache: Dictionary = {}
var stats: Dictionary = {"meshes": 0, "triangles": 0, "creases": 0, "ms": 0.0}

func build(h: Node3D, c: Dictionary) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	host = h
	cfg = c
	var cos_limit: float = cos(deg_to_rad(float(cfg.get("crease_deg", 28.0))))
	var targets: Array[MeshInstance3D] = []
	for rec: Dictionary in host.get("instance_nodes"):
		for mi: MeshInstance3D in rec.meshes:
			targets.append(mi)
	var nodes: Dictionary = host.get("proc_nodes")
	for r: Variant in cfg.get("proc_roles", ["structure", "steps", "cliff"]):
		if nodes.has(str(r)):
			targets.append(nodes[str(r)] as MeshInstance3D)
	for mi: MeshInstance3D in targets:
		if mi == null or mi.mesh == null:
			continue
		var key: int = mi.mesh.get_instance_id()
		if not cache.has(key):
			cache[key] = _process(mi.mesh as ArrayMesh, cos_limit)
		var out: ArrayMesh = cache[key]
		if out != null:
			mi.mesh = out
	stats["ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	host.call("add_report", "l2_edges", stats)
	return stats

func _process(src: ArrayMesh, cos_limit: float) -> ArrayMesh:
	if src == null:
		return null
	var out: ArrayMesh = ArrayMesh.new()
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
				stats["creases"] = int(stats["creases"]) + 1
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
		stats["triangles"] = int(stats["triangles"]) + tri_count
	stats["meshes"] = int(stats["meshes"]) + 1
	return out

static func _edge_key(a: Vector3i, b: Vector3i) -> String:
	if a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z))):
		return "%d,%d,%d|%d,%d,%d" % [a.x, a.y, a.z, b.x, b.y, b.z]
	return "%d,%d,%d|%d,%d,%d" % [b.x, b.y, b.z, a.x, a.y, a.z]
