extends RefCounted
## L2 · automatic ground scatter (extra_scripts module). One rule set for every tile:
##  - what grows where comes from the ground colour class under each point (grass / sand / snow / wet, the
##    same classifier as the shader), the place theme (sand on a harbor tile = beach) and the path field;
##  - density per m² per class and kind comes from cfg (global numbers), modulated by two noise fields
##    (meadow clusters, flower patches), thicker right next to objects, thinner on steep ground and in the
##    camp area, zero on footprints / path cores / water / next to L叔;
##  - kinds: grass tufts, dry tufts, flowers, pebbles, snow lumps, dry stalks, fallen leaves under trees
##    whose crown colour is warm and saturated (autumn trees shed; green trees and palms do not) – all low-poly MultiMeshes on the
##    shared "scatter" role material (l2_scatter.gdshader), wind from motion.wind_strength;
##  - the web's V-shaped proc grass is hidden when cfg.hide_web_grass (the scatter replaces it).
const INFO_PATH: String = "res://tools/traveler/lookdev_lshu/modules/l2_ground_info.gd"
const KINDS: Array[String] = ["tuft", "dry", "flower", "pebble", "lump", "stalk", "leaf"]

var host: Node3D
var cfg: Dictionary = {}
var info: RefCounted
var root: Node3D
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var cluster: FastNoiseLite = FastNoiseLite.new()
var patches: FastNoiseLite = FastNoiseLite.new()
var theme: String = "autumn"
var buckets: Dictionary = {}
var meshes: Dictionary = {}
var counts: Dictionary = {}
var candidates: int = 0

func build(h: Node3D, c: Dictionary) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	host = h
	cfg = c
	var script: GDScript = load(INFO_PATH) as GDScript
	info = script.call("get_or_build", host) as RefCounted
	var tile: Dictionary = host.get("tile")
	theme = str((tile.get("place", {}) as Dictionary).get("theme", "autumn"))
	var seed_value: int = int((tile.get("recipe", {}) as Dictionary).get("seed", 1234))
	rng.seed = seed_value ^ 0x5CA77E
	cluster.seed = seed_value % 100003
	cluster.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	cluster.frequency = float(cfg.get("cluster_frequency", 0.75))
	cluster.fractal_octaves = 2
	patches.seed = (seed_value / 7) % 100019
	patches.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	patches.frequency = float(cfg.get("flower_frequency", 1.1))
	patches.fractal_octaves = 1
	for k: String in KINDS:
		buckets[k] = []
	var nodes: Dictionary = host.get("proc_nodes")
	if bool(cfg.get("hide_web_grass", true)) and nodes.has("grass"):
		(nodes["grass"] as Node3D).visible = false
	root = Node3D.new()
	root.name = "L2Scatter"
	(host.get("tile_root") as Node3D).add_child(root)
	_scatter_ground()
	_scatter_leaves()
	_build_meshes()
	var total: int = 0
	for k: String in KINDS:
		var arr: Array = buckets[k]
		counts[k] = arr.size()
		total += arr.size()
		if arr.is_empty():
			continue
		_emit(k, arr)
	var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var rep: Dictionary = {"counts": counts, "total": total, "candidates": candidates, "build_ms": ms, "theme": theme}
	host.call("add_report", "l2_scatter", rep)
	return rep

# ------------------------------------------------------------------ placement rules
func _dens(section: String, kind: String) -> float:
	var d: Dictionary = cfg.get("density", {})
	return float((d.get(section, {}) as Dictionary).get(kind, 0.0))

func _scatter_ground() -> void:
	var cell: float = float(cfg.get("cell", 0.07))
	var edge: float = float(cfg.get("edge_margin", 0.1))
	var span: float = 8.0 - 2.0 * edge
	var cells: int = int(span / cell)
	var level: float = float(info.get("water_level"))
	var char_xz: Vector2 = info.get("character_xz")
	var char_r: float = float(cfg.get("character_radius", 0.26))
	var near_boost: float = float(cfg.get("near_boost", 1.8))
	var activity_scale: float = float(cfg.get("activity_scale", 0.45))
	var area: float = cell * cell
	for j: int in cells:
		for i: int in cells:
			var x: float = -4.0 + edge + (i + rng.randf()) * cell
			var z: float = -4.0 + edge + (j + rng.randf()) * cell
			var r_accept: float = rng.randf()
			var r_kind: float = rng.randf()
			candidates += 1
			var occ: int = int(info.call("occupancy_at", x, z))
			if occ == 2:
				continue
			if Vector2(x, z).distance_to(char_xz) < char_r:
				continue
			var hy: float = float(info.call("height", x, z))
			if level > -50.0 and hy < level + 0.03:
				continue
			var nrm: Vector3 = info.call("normal", x, z)
			if nrm.y < 0.6:
				continue
			var gc: Color = info.call("color_at", x, z)
			var cls: Vector4 = info.get_script().call("classify", gc)
			var u: float = float(info.call("path_at", x, z))
			var dens: Dictionary = {}
			if u < 0.5:
				dens["pebble"] = _dens("path_core", "pebble")
			else:
				var sand_key: String = "beach" if theme == "harbor" else "sand"
				for k: String in KINDS:
					if k == "leaf":
						continue
					var v: float = cls.x * _dens("grass", k) + cls.y * _dens(sand_key, k) + cls.z * _dens("snow", k) + cls.w * _dens("wet", k)
					if u < 0.85:
						v += _dens("path_rim", k) * (1.0 - smoothstep(0.6, 0.85, u))
					if v > 0.0:
						dens[k] = v
				var cl: float = cluster.get_noise_2d(x, z)
				var cm: float = smoothstep(-0.45, 0.55, cl) * 1.9 + 0.1
				for k: String in ["tuft", "dry", "lump", "stalk"]:
					if dens.has(k):
						dens[k] = float(dens[k]) * cm
				if dens.has("flower"):
					dens["flower"] = float(dens["flower"]) * smoothstep(0.15, 0.55, patches.get_noise_2d(x, z)) * 3.0 * (0.4 + 0.6 * cm)
				if occ == 1:
					var nb: Dictionary = cfg.get("near_boost_by_kind", {})
					for k: String in dens.keys():
						dens[k] = float(dens[k]) * float(nb.get(k, near_boost if k in ["tuft", "dry", "pebble", "stalk"] else 1.0))
				if theme == "harbor" and level > -50.0 and hy < level + 0.16:
					dens.erase("dry")
					dens.erase("tuft")
			if nrm.y < 0.8:
				for k: String in dens.keys():
					dens[k] = float(dens[k]) * (0.5 if k == "pebble" else 0.15)
			if bool(info.call("in_activity", x, z)):
				for k: String in dens.keys():
					dens[k] = float(dens[k]) * activity_scale
			var total: float = 0.0
			for k: String in dens.keys():
				total += float(dens[k])
			if total <= 0.0 or r_accept > total * area:
				continue
			var pick: float = r_kind * total
			var kind: String = ""
			for k: String in dens.keys():
				pick -= float(dens[k])
				if pick <= 0.0:
					kind = k
					break
			if kind.is_empty():
				kind = str(dens.keys()[dens.size() - 1])
			_place(kind, x, z, hy, nrm, gc, u < 0.5)

func _clear(x: float, z: float, r: float) -> bool:
	for a: int in 6:
		var ang: float = TAU * a / 6.0
		if int(info.call("occupancy_at", x + cos(ang) * r, z + sin(ang) * r)) == 2:
			return false
	return true

func _range(kind: String, key: String, lo: float, hi: float) -> float:
	var sizes: Dictionary = cfg.get("sizes", {})
	var r: Array = (sizes.get(kind, {}) as Dictionary).get(key, [lo, hi])
	return rng.randf_range(float(r[0]), float(r[1]))

func _pal(section: String, fallback: Array) -> Color:
	var pals: Dictionary = cfg.get(section, {})
	var arr: Array = pals.get(theme, pals.get("default", fallback))
	if arr.is_empty():
		arr = fallback
	return _col(arr[rng.randi() % arr.size()])

static func _col(v: Variant) -> Color:
	if v is String:
		return Color.html(str(v))
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return Color.WHITE

static func _saturate(c: Color, s: float, gain: float) -> Color:
	var l: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	return Color(clampf((l + (c.r - l) * s) * gain, 0.0, 1.0), clampf((l + (c.g - l) * s) * gain, 0.0, 1.0), clampf((l + (c.b - l) * s) * gain, 0.0, 1.0))

func _place(kind: String, x: float, z: float, hy: float, nrm: Vector3, gc: Color, on_path: bool) -> void:
	var yaw: float = rng.randf() * TAU
	var up: Vector3 = Vector3.UP
	var s: Vector3 = Vector3.ONE
	var col: Color = Color.WHITE
	var custom: Color = Color(0, 0, 0, 0)
	var sink: float = 0.0
	var jitter: float = rng.randf_range(0.93, 1.07)
	match kind:
		"tuft":
			var k: float = _range(kind, "scale", 0.8, 1.35)
			s = Vector3(k, k * rng.randf_range(0.85, 1.2), k)
			up = Vector3.UP.lerp(nrm, 0.35).normalized()
			var gcfg: Array = cfg.get("tuft_tone", [1.35, 0.8])
			col = _saturate(gc, float(gcfg[0]), float(gcfg[1]) * jitter)
			col.g = clampf(col.g * rng.randf_range(0.97, 1.04), 0.0, 1.0)
		"dry", "stalk":
			var k2: float = _range(kind, "scale", 0.8, 1.3)
			s = Vector3(k2, k2 * rng.randf_range(0.85, 1.25), k2)
			up = Vector3.UP.lerp(nrm, 0.3).normalized()
			col = _pal("dry_colors" if kind == "dry" else "stalk_colors", ["#9a9550"])
			col = col.lerp(gc, 0.2) * jitter
		"flower":
			var k3: float = _range(kind, "scale", 0.8, 1.3)
			s = Vector3(k3, k3, k3)
			up = Vector3.UP.lerp(nrm, 0.25).normalized()
			var fcfg: Array = cfg.get("tuft_tone", [1.35, 0.8])
			col = _saturate(gc, float(fcfg[0]), float(fcfg[1]) * 0.95)
			custom = _pal("flower_colors", ["#f4f1e8"]) * rng.randf_range(0.94, 1.04)
			custom.a = 1.0
		"pebble":
			var r: float = _range(kind, "radius", 0.018, 0.05) * (0.6 if on_path else 1.0)
			if not _clear(x, z, r * 1.3):
				return
			s = Vector3(r * rng.randf_range(0.85, 1.35), r * rng.randf_range(0.8, 1.2), r * rng.randf_range(0.85, 1.35))
			up = nrm
			col = _pal("pebble_colors", ["#9a9a96"]).lerp(gc, float(cfg.get("pebble_ground_mix", 0.3))) * jitter
			sink = r * 0.25
		"lump":
			var r2: float = _range(kind, "radius", 0.05, 0.13)
			if not _clear(x, z, r2 * 1.1):
				return
			var stretch: float = float(cfg.get("lump_stretch", 1.0))
			s = Vector3(r2 * rng.randf_range(0.9, 1.3) * stretch, r2 * rng.randf_range(0.8, 1.1), r2 * rng.randf_range(0.9, 1.3))
			up = nrm
			col = _pal("lump_colors", ["#f3f7f8"]) * rng.randf_range(0.97, 1.02)
			sink = r2 * 0.12
	var basis: Basis = Basis(Quaternion(Vector3.UP, up)) * Basis(Vector3.UP, yaw) * Basis.from_scale(s)
	var xf: Transform3D = Transform3D(basis, Vector3(x, hy - sink, z))
	(buckets[kind] as Array).append({"xf": xf, "color": col, "custom": custom})

## Leaves under trees whose crown colour is warm (autumn trees): colour from the crown itself.
func _scatter_leaves() -> void:
	var per_tree: int = int(cfg.get("leaves_per_tree", 0))
	if per_tree <= 0:
		return
	var level: float = float(info.get("water_level"))
	for rec: Dictionary in host.get("instance_nodes"):
		var d: Dictionary = rec.data
		if str(d.get("group", "")) != "tree":
			continue
		var crown: Color = _crown_color(rec.meshes)
		if not (crown.r > crown.g * 1.2 and crown.r > crown.b * 1.6 and crown.r - crown.b > 0.25):   # warm, saturated crowns only (palms stay clean)
			continue
		var holder: Node3D = rec.node
		var aabb: AABB = AABB()
		var first: bool = true
		for mi: MeshInstance3D in rec.meshes:
			var bb: AABB = mi.global_transform * mi.get_aabb()
			aabb = bb if first else aabb.merge(bb)
			first = false
		var radius: float = maxf(aabb.size.x, aabb.size.z) * 0.5 * float(cfg.get("leaf_spread", 1.25))
		var cx: float = holder.global_position.x
		var cz: float = holder.global_position.z
		for n: int in per_tree:
			var ang: float = rng.randf() * TAU
			var rr: float = sqrt(rng.randf()) * radius
			var x: float = cx + cos(ang) * rr
			var z: float = cz + sin(ang) * rr
			if absf(x) > 3.9 or absf(z) > 3.9:
				continue
			if int(info.call("occupancy_at", x, z)) == 2:
				continue
			if float(info.call("path_at", x, z)) < 0.45:
				continue
			var hy: float = float(info.call("height", x, z))
			if level > -50.0 and hy < level + 0.02:
				continue
			var nrm: Vector3 = info.call("normal", x, z)
			var k: float = _range("leaf", "scale", 0.8, 1.3)
			var tilt: Vector3 = (nrm + Vector3(rng.randf_range(-0.25, 0.25), 0.0, rng.randf_range(-0.25, 0.25))).normalized()
			var basis: Basis = Basis(Quaternion(Vector3.UP, tilt)) * Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(k, k, k))
			var col: Color = crown * rng.randf_range(0.8, 1.08)
			if rng.randf() < 0.25:
				col = col.lerp(Color(0.55, 0.36, 0.22), 0.45)
			col.a = 1.0
			(buckets["leaf"] as Array).append({"xf": Transform3D(basis, Vector3(x, hy + 0.004, z)), "color": col, "custom": Color(0, 0, 0, 0)})

func _crown_color(ms: Array) -> Color:
	var sum: Vector3 = Vector3.ZERO
	var cnt: int = 0
	for mi: MeshInstance3D in ms:
		var aabb: AABB = mi.get_aabb()
		var cut: float = aabb.position.y + aabb.size.y * 0.45
		for s: int in mi.mesh.get_surface_count():
			var arrays: Array = mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if arrays[Mesh.ARRAY_COLOR] == null:
				continue
			var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			for i: int in range(0, verts.size(), 3):
				if verts[i].y > cut:
					sum += Vector3(cols[i].r, cols[i].g, cols[i].b)
					cnt += 1
	if cnt == 0:
		return Color(0.5, 0.6, 0.4)
	sum /= float(cnt)
	return Color(sum.x, sum.y, sum.z)

# ------------------------------------------------------------------ meshes
func _build_meshes() -> void:
	meshes["tuft"] = _mesh_blades(6, 0.05, 0.088, 0.026, 0.5, 11)
	meshes["dry"] = _mesh_blades(5, 0.055, 0.1, 0.016, 0.6, 23)
	meshes["stalk"] = _mesh_blades(3, 0.09, 0.15, 0.007, 0.3, 37)
	meshes["flower"] = _mesh_flower()
	meshes["pebble"] = _mesh_pebble()
	meshes["lump"] = _mesh_lump()
	meshes["leaf"] = _mesh_leaf()

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color, uv: Vector2) -> void:
	var nrm: Vector3 = (b - a).cross(c - a).normalized()
	if nrm.y < 0.0:
		nrm = -nrm
	for p: Array in [[a, ca], [c, cc], [b, cb]]:   # Godot front faces are clockwise
		st.set_color(p[1])
		st.set_uv(uv)
		st.set_normal(nrm)
		st.add_vertex(p[0])

func _mesh_blades(blades: int, h_lo: float, h_hi: float, width: float, lean: float, seed_value: int) -> ArrayMesh:
	var r: RandomNumberGenerator = RandomNumberGenerator.new()
	r.seed = seed_value
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var base_c: Color = Color(0.72, 0.74, 0.7)
	var mid_c: Color = Color(0.9, 0.92, 0.86)
	var tip_c: Color = Color(0.98, 1.0, 0.9)
	for b: int in blades:
		var ang: float = TAU * b / blades + r.randf_range(-0.45, 0.45)
		var dir: Vector3 = Vector3(cos(ang), 0.0, sin(ang))
		var side: Vector3 = Vector3(-dir.z, 0.0, dir.x)
		var hgt: float = r.randf_range(h_lo, h_hi)
		var off: Vector3 = dir * r.randf_range(0.0, 0.014)
		var lean_v: Vector3 = dir * hgt * r.randf_range(lean * 0.4, lean)
		var p0: Vector3 = off - side * width * 0.5
		var p1: Vector3 = off + side * width * 0.5
		var pm: Vector3 = off + lean_v * 0.35 + Vector3(0.0, hgt * 0.55, 0.0)
		var p2: Vector3 = off + lean_v + Vector3(0.0, hgt, 0.0)
		# two-segment blade: a narrow quad-ish base and a tip, still low-poly
		var m0: Vector3 = pm - side * width * 0.32
		var m1: Vector3 = pm + side * width * 0.32
		_tri(st, p0, p1, m1, base_c, base_c, mid_c, Vector2(0.0, 1.0))
		_tri(st, p0, m1, m0, base_c, mid_c, mid_c, Vector2(0.0, 1.0))
		_tri(st, m0, m1, p2, mid_c, mid_c, tip_c, Vector2(0.0, 1.0))
	return st.commit()

func _mesh_flower() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hf: float = 0.08
	var stem_c: Color = Color(0.62, 0.64, 0.6)
	var stem_t: Color = Color(0.95, 0.97, 0.9)
	_tri(st, Vector3(-0.004, 0.0, 0.0), Vector3(0.004, 0.0, 0.0), Vector3(0.002, hf, 0.001), stem_c, stem_c, stem_t, Vector2(0.0, 1.0))
	_tri(st, Vector3(0.0, 0.0, -0.004), Vector3(0.0, 0.0, 0.004), Vector3(0.001, hf, 0.002), stem_c, stem_c, stem_t, Vector2(0.0, 1.0))
	# leaves at the base
	_tri(st, Vector3(0.0, 0.004, 0.0), Vector3(0.028, 0.012, 0.006), Vector3(0.012, 0.022, -0.004), stem_c, stem_t, stem_t, Vector2(0.0, 1.0))
	_tri(st, Vector3(0.0, 0.004, 0.0), Vector3(-0.022, 0.014, -0.012), Vector3(-0.006, 0.026, 0.006), stem_c, stem_t, stem_t, Vector2(0.0, 1.0))
	var centre: Vector3 = Vector3(0.002, hf + 0.004, 0.001)
	var petals: int = 5
	var rad: float = 0.03
	var cc: Color = Color(1.0, 1.0, 1.0, 0.72)
	var rc: Color = Color(1.0, 1.0, 1.0, 1.0)
	for p: int in petals:
		var a0: float = TAU * p / petals - 0.5
		var a1: float = TAU * p / petals + 0.5
		var am: float = TAU * p / petals
		var r0: Vector3 = centre + Vector3(cos(a0) * rad * 0.75, -0.003, sin(a0) * rad * 0.75)
		var rm: Vector3 = centre + Vector3(cos(am) * rad, 0.002, sin(am) * rad)
		var r1: Vector3 = centre + Vector3(cos(a1) * rad * 0.75, -0.003, sin(a1) * rad * 0.75)
		_tri(st, centre, r0, rm, cc, rc, rc, Vector2(1.0, 1.0))
		_tri(st, centre, rm, r1, cc, rc, rc, Vector2(1.0, 1.0))
	return st.commit()

func _mesh_pebble() -> ArrayMesh:
	var t: float = (1.0 + sqrt(5.0)) / 2.0
	var v: Array[Vector3] = [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var f: Array[Vector3i] = [Vector3i(0, 11, 5), Vector3i(0, 5, 1), Vector3i(0, 1, 7), Vector3i(0, 7, 10), Vector3i(0, 10, 11), Vector3i(1, 5, 9), Vector3i(5, 11, 4), Vector3i(11, 10, 2), Vector3i(10, 7, 6), Vector3i(7, 1, 8), Vector3i(3, 9, 4), Vector3i(3, 4, 2), Vector3i(3, 2, 6), Vector3i(3, 6, 8), Vector3i(3, 8, 9), Vector3i(4, 9, 5), Vector3i(2, 4, 11), Vector3i(6, 2, 10), Vector3i(8, 6, 7), Vector3i(9, 8, 1)]
	var r: RandomNumberGenerator = RandomNumberGenerator.new()
	r.seed = 71
	var pts: Array[Vector3] = []
	for p: Vector3 in v:
		var q: Vector3 = p.normalized() * r.randf_range(0.82, 1.12)
		q.y *= 0.58
		pts.append(q + Vector3(0.0, 0.3, 0.0))
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var top_c: Color = Color(1.0, 1.0, 1.0)
	var low_c: Color = Color(0.78, 0.78, 0.8)
	for tri: Vector3i in f:
		var a: Vector3 = pts[tri.x]
		var b: Vector3 = pts[tri.y]
		var c: Vector3 = pts[tri.z]
		var nrm: Vector3 = (b - a).cross(c - a).normalized()
		if nrm.dot((a + b + c) / 3.0 - Vector3(0.0, 0.3, 0.0)) < 0.0:
			var tmp: Vector3 = b
			b = c
			c = tmp
			nrm = -nrm
		for p2: Vector3 in [a, c, b]:   # clockwise = front in Godot
			st.set_color(top_c if p2.y > 0.3 else low_c)
			st.set_uv(Vector2.ZERO)
			st.set_normal(nrm)
			st.add_vertex(p2)
	return st.commit()

func _mesh_lump() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg: int = 7
	var ring0: Array[Vector3] = []
	var ring1: Array[Vector3] = []
	for i: int in seg:
		var a: float = TAU * i / seg
		ring0.append(Vector3(cos(a), -0.05, sin(a)))
		var b: float = a + PI / seg
		ring1.append(Vector3(cos(b) * 0.58, 0.22, sin(b) * 0.58))
	var apex: Vector3 = Vector3(0.08, 0.3, -0.05)
	var c: Color = Color.WHITE
	for i: int in seg:
		var j: int = (i + 1) % seg
		_tri_out(st, ring0[i], ring0[j], ring1[i], c)
		_tri_out(st, ring1[i], ring0[j], ring1[j], c)
		_tri_out(st, ring1[i], ring1[j], apex, c)
	return st.commit()

func _tri_out(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	var nrm: Vector3 = (b - a).cross(c - a).normalized()
	var cen: Vector3 = (a + b + c) / 3.0
	if nrm.dot(Vector3(cen.x, cen.y + 0.2, cen.z)) < 0.0:
		var tmp: Vector3 = b
		b = c
		c = tmp
		nrm = -nrm
	for p: Vector3 in [a, c, b]:   # clockwise = front in Godot
		st.set_color(col)
		st.set_uv(Vector2.ZERO)
		st.set_normal(nrm)
		st.add_vertex(p)

func _mesh_leaf() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c: Color = Color.WHITE
	var d: Color = Color(0.85, 0.85, 0.85)
	var a: Vector3 = Vector3(-0.02, 0.0, 0.0)
	var b: Vector3 = Vector3(0.0, 0.004, 0.011)
	var e: Vector3 = Vector3(0.022, 0.001, 0.0)
	var f: Vector3 = Vector3(0.0, 0.004, -0.011)
	_tri(st, a, b, e, d, c, c, Vector2(0.0, 1.0))
	_tri(st, a, e, f, d, c, c, Vector2(0.0, 1.0))
	return st.commit()

# ------------------------------------------------------------------ MultiMesh
func _emit(kind: String, arr: Array) -> void:
	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = kind == "flower"
	mm.mesh = meshes[kind]
	mm.instance_count = arr.size()
	for i: int in arr.size():
		var it: Dictionary = arr[i]
		mm.set_instance_transform(i, it.xf)
		mm.set_instance_color(i, it.color)
		if mm.use_custom_data:
			mm.set_instance_custom_data(i, it.custom)
	var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	mmi.name = "scatter_" + kind
	mmi.multimesh = mm
	mmi.material_override = host.call("role_material", str(cfg.get("role", "scatter"))) as Material
	var casters: Array = cfg.get("cast_shadow", ["pebble", "lump"])
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casters.has(kind) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mmi)
