extends RefCounted
## 第四幕「L叔在哪儿」· ground information, derived automatically from the baked tile (no per-tile parameters).
## Computed OFFLINE by tools/traveler/lshu/bake/precompute_tiles.gd (fix #6) and stored in the tile JSON under
## precompute.ground_info; at runtime only textures_from() runs (two small textures from stored bytes).
##   - cell colours: the web ground mesh colour per 52x52 grid cell (sRGB-encoded, same as COLOR_0), averaged
##     over the cell's triangles -> colour texture (linear filtering = smooth, no triangle stripes)
##   - path field: distance to the nearest path centreline / that path's width -> R8 texture
##   - footprint: 5 cm occupancy grid rasterised from every instance / procedural structure triangle that
##     touches the ground, plus a "near" band; offline only (keeps scatter off objects)
##   - terrain height / normal: same interpolation as the web planner's height()

const PATH_N: int = 256
const OCC_N: int = 160
const HALF: float = 4.0
const NEAR_CELLS: int = 6

var tile: Dictionary = {}
var n: int = 52
var step: float = 8.0 / 52.0
var heights: Array = []
var cell_colors: PackedColorArray = PackedColorArray()
var cell_bytes: PackedByteArray = PackedByteArray()
var path_u: PackedFloat32Array = PackedFloat32Array()
var path_bytes: PackedByteArray = PackedByteArray()
var occ: PackedByteArray = PackedByteArray()        # 0 free, 1 near (within NEAR_CELLS), 2 occupied
var water_level: float = -100.0
var ground_min: float = 0.0
var ground_max: float = 1.0
var character_xz: Vector2 = Vector2(99.0, 99.0)
var activity: Array[Dictionary] = []
var stats: Dictionary = {}

## Offline: tile = parsed tile JSON; ground = proc ground MeshInstance3D (in the tree);
## footprint_meshes = every instance mesh + non-ground procedural mesh (in the tree).
func compute(tile_data: Dictionary, ground: MeshInstance3D, footprint_meshes: Array[MeshInstance3D]) -> void:
	tile = tile_data
	_read_tile()
	_build_cell_colors(ground)
	_build_path_field()
	_build_occupancy(footprint_meshes)

func _read_tile() -> void:
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

## Record stored in the tile JSON (precompute.ground_info).
func to_record() -> Dictionary:
	return {"n": n, "cell_rgba8_b64": Marshalls.raw_to_base64(cell_bytes), "path_n": PATH_N, "path_r8_b64": Marshalls.raw_to_base64(path_bytes),
		"water_level": water_level, "ground_min": ground_min, "ground_max": ground_max, "stats": stats}

## Runtime: the two map textures from a stored record.
static func textures_from(record: Dictionary) -> Dictionary:
	var cn: int = int(record.get("n", 52))
	var pn: int = int(record.get("path_n", PATH_N))
	var cb: PackedByteArray = Marshalls.base64_to_raw(str(record.get("cell_rgba8_b64", "")))
	var pb: PackedByteArray = Marshalls.base64_to_raw(str(record.get("path_r8_b64", "")))
	if cb.size() != cn * cn * 4 or pb.size() != pn * pn:
		push_error("LSHU tile precompute.ground_info has wrong map sizes")
		return {}
	var color_img: Image = Image.create_from_data(cn, cn, false, Image.FORMAT_RGBA8, cb)
	var path_img: Image = Image.create_from_data(pn, pn, false, Image.FORMAT_R8, pb)
	return {"color_tex": ImageTexture.create_from_image(color_img), "path_tex": ImageTexture.create_from_image(path_img),
		"ground_range": Vector2(float(record.get("ground_min", 0.0)), float(record.get("ground_max", 1.0))),
		"water_level": float(record.get("water_level", -100.0))}

# ------------------------------------------------------------------ terrain
func height(x: float, z: float) -> float:
	return height_at(heights, n, step, x, z)

## Same barycentric interpolation (same diagonals) as the web planner's height().
static func height_at(grid: Array, grid_n: int, grid_step: float, x: float, z: float) -> float:
	if grid.is_empty():
		return 0.0
	x = clampf(x, -HALF, HALF)
	z = clampf(z, -HALF, HALF)
	var ix: int = mini(grid_n - 1, int(floor((x + HALF) / grid_step)))
	var iz: int = mini(grid_n - 1, int(floor((z + HALF) / grid_step)))
	var u: float = (x + HALF) / grid_step - ix
	var v: float = (z + HALF) / grid_step - iz
	var a: float = float(grid[iz][ix])
	var b: float = float(grid[iz][ix + 1])
	var cc: float = float(grid[iz + 1][ix + 1])
	var d: float = float(grid[iz + 1][ix])
	if u + v <= 1.0:
		return a + (b - a) * u + (d - a) * v
	return b * (1.0 - v) + d * (1.0 - u) + cc * (u + v - 1.0)

func normal(x: float, z: float) -> Vector3:
	var e: float = 0.06
	var hx: float = height(x - e, z) - height(x + e, z)
	var hz: float = height(x, z - e) - height(x, z + e)
	return Vector3(hx, 2.0 * e, hz).normalized()

# ------------------------------------------------------------------ ground colour
func _build_cell_colors(ground: MeshInstance3D) -> void:
	var sums: Array[Vector4] = []
	sums.resize(n * n)
	for i: int in n * n:
		sums[i] = Vector4.ZERO
	var filled: int = 0
	if ground != null and ground.mesh != null:
		var xf: Transform3D = ground.global_transform
		for s: int in ground.mesh.get_surface_count():
			var arrays: Array = ground.mesh.surface_get_arrays(s)
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
	cell_bytes = img.get_data()
	stats["ground_triangles"] = filled

func color_at(x: float, z: float) -> Color:
	var ci: int = clampi(int(floor((x + HALF) / step)), 0, n - 1)
	var cj: int = clampi(int(floor((z + HALF) / step)), 0, n - 1)
	return cell_colors[cj * n + ci]

## Same classification as lshu_surface.gdshader ground_class(): x grass, y sand/earth, z snow, w wet.
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
	path_bytes = img.get_data()

func path_at(x: float, z: float) -> float:
	var i: int = clampi(int(floor((x + HALF) / (2.0 * HALF) * PATH_N)), 0, PATH_N - 1)
	var j: int = clampi(int(floor((z + HALF) / (2.0 * HALF) * PATH_N)), 0, PATH_N - 1)
	return path_u[j * PATH_N + i]

# ------------------------------------------------------------------ footprints
func _build_occupancy(meshes: Array[MeshInstance3D]) -> void:
	occ.resize(OCC_N * OCC_N)
	occ.fill(0)
	var cell: float = 2.0 * HALF / OCC_N
	var tris: int = 0
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
	var ends: Array[Vector2] = [a, b, c]
	for e: int in 3:
		var p: Vector2 = ends[e]
		var q2: Vector2 = ends[(e + 1) % 3]
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
