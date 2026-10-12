extends RefCounted
## L2 shared ground information, derived automatically from the baked tile (no per-tile parameters).
## Built once per viewer and cached on the host as meta "l2_ground_info"; used by l2_surface_detail.gd
## (shader maps) and l2_scatter.gd (placement rules).
##   - cell colours: the web ground mesh colour per 52x52 grid cell (sRGB-encoded, same as COLOR_0),
##     averaged over the cell's two triangles -> color_tex (linear filtering = smooth, no triangle stripes)
##   - path field: distance to the nearest path centreline divided by that path's width -> path_tex (R8)
##   - footprint: 5 cm occupancy grid rasterised from every instance / procedural structure triangle that
##     touches the ground (bases, walls, trunks), plus a "near" band; used to keep scatter off objects
##   - terrain height / normal: same interpolation as the viewer's terrain_height()

const PATH_N: int = 256
const OCC_N: int = 160
const HALF: float = 4.0
const NEAR_CELLS: int = 6

var host: Node3D
var tile: Dictionary = {}
var n: int = 52
var step: float = 8.0 / 52.0
var heights: Array = []
var cell_colors: PackedColorArray = PackedColorArray()
var path_u: PackedFloat32Array = PackedFloat32Array()
var occ: PackedByteArray = PackedByteArray()        # 0 free, 1 near (within NEAR_CELLS), 2 occupied
var color_tex: ImageTexture
var path_tex: ImageTexture
var water_level: float = -100.0
var ground_min: float = 0.0
var ground_max: float = 1.0
var character_xz: Vector2 = Vector2(99.0, 99.0)
var activity: Array[Dictionary] = []
var build_ms: float = 0.0
var stats: Dictionary = {}

static func get_or_build(h: Node3D) -> RefCounted:
	if h.has_meta("l2_ground_info"):
		return h.get_meta("l2_ground_info") as RefCounted
	var script: GDScript = load("res://tools/traveler/lookdev_lshu/modules/l2_ground_info.gd") as GDScript
	var info: RefCounted = script.new()
	info.call("build", h)
	h.set_meta("l2_ground_info", info)
	return info

func build(h: Node3D) -> void:
	var t0: int = Time.get_ticks_usec()
	host = h
	tile = host.get("tile")
	var terrain: Dictionary = tile.get("terrain", {})
	heights = terrain.get("heights", [])
	n = int(terrain.get("N", 52))
	step = float(terrain.get("step", 8.0 / 52.0))
	var yr: Array = (tile.get("tile", {}) as Dictionary).get("ground_y_range", [0.0, 1.0])
	ground_min = float(yr[0])
	ground_max = float(yr[1])
	var w: Variant = tile.get("water")
	if w is Dictionary and (w as Dictionary).get("level") != null:
		water_level = float((w as Dictionary).get("level"))
	var c: Dictionary = tile.get("character", {})
	if c.has("position"):
		var p: Array = c.get("position")
		character_xz = Vector2(float(p[0]), float(p[2]))
	for r: Variant in tile.get("reservations", []):
		var rd: Dictionary = r
		if str(rd.get("kind", "")) == "activity":
			activity.append(rd)
	_build_cell_colors()
	_build_path_field()
	_build_occupancy()
	build_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	stats["build_ms"] = build_ms

# ------------------------------------------------------------------ terrain
func height(x: float, z: float) -> float:
	if heights.is_empty():
		return 0.0
	x = clampf(x, -HALF, HALF)
	z = clampf(z, -HALF, HALF)
	var ix: int = mini(n - 1, int(floor((x + HALF) / step)))
	var iz: int = mini(n - 1, int(floor((z + HALF) / step)))
	var u: float = (x + HALF) / step - ix
	var v: float = (z + HALF) / step - iz
	var a: float = float(heights[iz][ix])
	var b: float = float(heights[iz][ix + 1])
	var cc: float = float(heights[iz + 1][ix + 1])
	var d: float = float(heights[iz + 1][ix])
	if u + v <= 1.0:
		return a + (b - a) * u + (d - a) * v
	return b * (1.0 - v) + d * (1.0 - u) + cc * (u + v - 1.0)

func normal(x: float, z: float) -> Vector3:
	var e: float = 0.06
	var hx: float = height(x - e, z) - height(x + e, z)
	var hz: float = height(x, z - e) - height(x, z + e)
	return Vector3(hx, 2.0 * e, hz).normalized()

# ------------------------------------------------------------------ ground colour
func _build_cell_colors() -> void:
	var sums: Array[Vector4] = []
	sums.resize(n * n)
	for i: int in n * n:
		sums[i] = Vector4.ZERO
	var nodes: Dictionary = host.get("proc_nodes")
	var filled: int = 0
	if nodes.has("ground"):
		var mi: MeshInstance3D = nodes["ground"]
		var xf: Transform3D = mi.global_transform
		for s: int in mi.mesh.get_surface_count():
			var arrays: Array = mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if cols.is_empty():
				continue
			var tri_count: int = (idx.size() if not idx.is_empty() else verts.size()) / 3
			for t: int in tri_count:
				var i0: int = idx[t * 3] if not idx.is_empty() else t * 3
				var i1: int = idx[t * 3 + 1] if not idx.is_empty() else t * 3 + 1
				var i2: int = idx[t * 3 + 2] if not idx.is_empty() else t * 3 + 2
				var cen: Vector3 = xf * ((verts[i0] + verts[i1] + verts[i2]) / 3.0)
				var ci: int = clampi(int(floor((cen.x + HALF) / step)), 0, n - 1)
				var cj: int = clampi(int(floor((cen.z + HALF) / step)), 0, n - 1)
				var col: Color = (cols[i0] + cols[i1] + cols[i2]) / 3.0
				sums[cj * n + ci] += Vector4(col.r, col.g, col.b, 1.0)
				filled += 1
	cell_colors.resize(n * n)
	var img: Image = Image.create(n, n, false, Image.FORMAT_RGBA8)
	var fallback: Color = Color(0.64, 0.66, 0.5)
	for j: int in n:
		for i: int in n:
			var s4: Vector4 = sums[j * n + i]
			var col2: Color = Color(s4.x / s4.w, s4.y / s4.w, s4.z / s4.w) if s4.w > 0.0 else fallback
			cell_colors[j * n + i] = col2
			img.set_pixel(i, j, col2)
	color_tex = ImageTexture.create_from_image(img)
	stats["ground_triangles"] = filled

func color_at(x: float, z: float) -> Color:
	var ci: int = clampi(int(floor((x + HALF) / step)), 0, n - 1)
	var cj: int = clampi(int(floor((z + HALF) / step)), 0, n - 1)
	return cell_colors[cj * n + ci]

## Same classification as l2_surface.gdshader ground_class(): x grass, y sand/earth, z snow, w wet.
static func classify(c: Color) -> Vector4:
	var mx: float = maxf(c.r, maxf(c.g, c.b))
	var mn: float = minf(c.r, minf(c.g, c.b))
	var sat: float = (mx - mn) / maxf(mx, 0.001)
	var lum: float = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	var snow: float = smoothstep(0.74, 0.84, lum) * (1.0 - smoothstep(0.07, 0.16, sat))
	var grass: float = smoothstep(-0.015, 0.03, c.g - c.r) * smoothstep(0.07, 0.14, c.g - c.b) * (1.0 - snow)
	var wet: float = smoothstep(-0.01, 0.04, c.b - c.r) * (1.0 - snow) * (1.0 - grass)
	var sand: float = clampf(1.0 - grass - snow - wet, 0.0, 1.0)
	return Vector4(grass, sand, snow, wet)

# ------------------------------------------------------------------ paths
func _build_path_field() -> void:
	path_u.resize(PATH_N * PATH_N)
	path_u.fill(1.0)
	var texel: float = 2.0 * HALF / PATH_N
	for p: Variant in tile.get("paths", []):
		var pd: Dictionary = p
		var width: float = maxf(0.1, float(pd.get("width", 0.5)))
		var pts: Array = pd.get("points", [])
		var reach: float = width * 1.05
		for k: int in pts.size() - 1:
			var pa: Array = pts[k]
			var pb: Array = pts[k + 1]
			var a: Vector2 = Vector2(float(pa[0]), float(pa[2]))
			var b: Vector2 = Vector2(float(pb[0]), float(pb[2]))
			var i0: int = clampi(int(floor((minf(a.x, b.x) - reach + HALF) / texel)), 0, PATH_N - 1)
			var i1: int = clampi(int(ceil((maxf(a.x, b.x) + reach + HALF) / texel)), 0, PATH_N - 1)
			var j0: int = clampi(int(floor((minf(a.y, b.y) - reach + HALF) / texel)), 0, PATH_N - 1)
			var j1: int = clampi(int(ceil((maxf(a.y, b.y) + reach + HALF) / texel)), 0, PATH_N - 1)
			var ab: Vector2 = b - a
			var len2: float = maxf(ab.length_squared(), 1e-8)
			for j: int in range(j0, j1 + 1):
				var pz: float = -HALF + (j + 0.5) * texel
				for i: int in range(i0, i1 + 1):
					var q: Vector2 = Vector2(-HALF + (i + 0.5) * texel, pz)
					var tt: float = clampf((q - a).dot(ab) / len2, 0.0, 1.0)
					var u: float = (q - (a + ab * tt)).length() / width
					var id: int = j * PATH_N + i
					if u < path_u[id]:
						path_u[id] = u
	var img: Image = Image.create(PATH_N, PATH_N, false, Image.FORMAT_R8)
	for j: int in PATH_N:
		for i: int in PATH_N:
			img.set_pixel(i, j, Color(clampf(path_u[j * PATH_N + i], 0.0, 1.0), 0.0, 0.0))
	path_tex = ImageTexture.create_from_image(img)

func path_at(x: float, z: float) -> float:
	var i: int = clampi(int(floor((x + HALF) / (2.0 * HALF) * PATH_N)), 0, PATH_N - 1)
	var j: int = clampi(int(floor((z + HALF) / (2.0 * HALF) * PATH_N)), 0, PATH_N - 1)
	return path_u[j * PATH_N + i]

# ------------------------------------------------------------------ footprints
func _build_occupancy() -> void:
	occ.resize(OCC_N * OCC_N)
	occ.fill(0)
	var cell: float = 2.0 * HALF / OCC_N
	var tris: int = 0
	var meshes: Array[MeshInstance3D] = []
	for rec: Dictionary in host.get("instance_nodes"):
		for mi: MeshInstance3D in rec.meshes:
			meshes.append(mi)
	var nodes: Dictionary = host.get("proc_nodes")
	for role: String in nodes.keys():
		if role in ["ground", "skirt", "water", "water_side", "foam", "ripple", "grass"]:
			continue
		meshes.append(nodes[role] as MeshInstance3D)
	for mi: MeshInstance3D in meshes:
		if mi == null or mi.mesh == null:
			continue
		var xf: Transform3D = mi.global_transform
		for s: int in mi.mesh.get_surface_count():
			var arrays: Array = mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var tri_count: int = (idx.size() if not idx.is_empty() else verts.size()) / 3
			for t: int in tri_count:
				var a: Vector3 = xf * verts[idx[t * 3] if not idx.is_empty() else t * 3]
				var b: Vector3 = xf * verts[idx[t * 3 + 1] if not idx.is_empty() else t * 3 + 1]
				var c: Vector3 = xf * verts[idx[t * 3 + 2] if not idx.is_empty() else t * 3 + 2]
				var low: float = minf(a.y, minf(b.y, c.y))
				var gx: float = (a.x + b.x + c.x) / 3.0
				var gz: float = (a.z + b.z + c.z) / 3.0
				if low > height(gx, gz) + 0.22:
					continue
				tris += 1
				_raster_tri(Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z), cell)
	# near band: square dilation by NEAR_CELLS via running window counts (separable) -> value 1
	var horiz: PackedByteArray = PackedByteArray()
	horiz.resize(OCC_N * OCC_N)
	for j: int in OCC_N:
		var count: int = 0
		for i: int in range(-NEAR_CELLS, OCC_N + NEAR_CELLS):
			var add_i: int = i + NEAR_CELLS
			if add_i >= 0 and add_i < OCC_N and occ[j * OCC_N + add_i] == 2:
				count += 1
			var rem_i: int = i - NEAR_CELLS - 1
			if rem_i >= 0 and rem_i < OCC_N and occ[j * OCC_N + rem_i] == 2:
				count -= 1
			if i >= 0 and i < OCC_N and count > 0:
				horiz[j * OCC_N + i] = 1
	for i: int in OCC_N:
		var count2: int = 0
		for j: int in range(-NEAR_CELLS, OCC_N + NEAR_CELLS):
			var add_j: int = j + NEAR_CELLS
			if add_j >= 0 and add_j < OCC_N and horiz[add_j * OCC_N + i] == 1:
				count2 += 1
			var rem_j: int = j - NEAR_CELLS - 1
			if rem_j >= 0 and rem_j < OCC_N and horiz[rem_j * OCC_N + i] == 1:
				count2 -= 1
			if j >= 0 and j < OCC_N and count2 > 0 and occ[j * OCC_N + i] == 0:
				occ[j * OCC_N + i] = 1
	stats["footprint_triangles"] = tris

func _mark(i: int, j: int) -> void:
	if i >= 0 and i < OCC_N and j >= 0 and j < OCC_N:
		occ[j * OCC_N + i] = 2

func _raster_tri(a: Vector2, b: Vector2, c: Vector2, cell: float) -> void:
	var lo: Vector2 = a.min(b).min(c)
	var hi: Vector2 = a.max(b).max(c)
	var i0: int = int(floor((lo.x + HALF) / cell))
	var i1: int = int(floor((hi.x + HALF) / cell))
	var j0: int = int(floor((lo.y + HALF) / cell))
	var j1: int = int(floor((hi.y + HALF) / cell))
	var area: float = (b - a).cross(c - a)
	if absf(area) > 1e-6 and (i1 - i0 + 1) * (j1 - j0 + 1) < 40000:
		for j: int in range(j0, j1 + 1):
			for i: int in range(i0, i1 + 1):
				var q: Vector2 = Vector2(-HALF + (i + 0.5) * cell, -HALF + (j + 0.5) * cell)
				var w0: float = (b - q).cross(c - q) / area
				var w1: float = (c - q).cross(a - q) / area
				var w2: float = 1.0 - w0 - w1
				if w0 >= -0.02 and w1 >= -0.02 and w2 >= -0.02:
					_mark(i, j)
	# edges too (walls seen edge-on have no area in xz)
	for e: int in 3:
		var p: Vector2 = [a, b, c][e]
		var q2: Vector2 = [b, c, a][e]
		var steps: int = maxi(1, int(ceil(p.distance_to(q2) / (cell * 0.5))))
		for s: int in steps + 1:
			var r: Vector2 = p.lerp(q2, float(s) / steps)
			_mark(int(floor((r.x + HALF) / cell)), int(floor((r.y + HALF) / cell)))

## 0 free, 1 near an object (within NEAR_CELLS * 5 cm), 2 on an object's footprint.
func occupancy_at(x: float, z: float) -> int:
	var cell: float = 2.0 * HALF / OCC_N
	var i: int = int(floor((x + HALF) / cell))
	var j: int = int(floor((z + HALF) / cell))
	if i < 0 or i >= OCC_N or j < 0 or j >= OCC_N:
		return 2
	return occ[j * OCC_N + i]

func in_activity(x: float, z: float) -> bool:
	for r: Dictionary in activity:
		if absf(x - float(r.x)) < float(r.rx) and absf(z - float(r.z)) < float(r.rz):
			return true
	return false
