extends SceneTree
## 自制地图 WP3：烘焙棋盘地面高度图（docs/design/map-editor-20260930/DESIGN.md 3.10.4）。
## 读 assets/merchant_board_claude/terrain/board_terrain.glb 的全部三角形，从上往下光栅化到 1024×477 的格子
## （每格 0.125 u，格心采样），每格取落在格心上的三角形里最高的 y；存成 Image.FORMAT_RF，
## 写到 assets/custom_map/terrain/board_height.res（约 1.9 MB）。CustomMapGeo.height() 在格心之间双线性插值。
## 选烘焙而不是运行时射线：游戏和工坊结果完全一样；可以钉死 SHA；不用在棋盘世界里建物理体。
##
## 用法（worktree 根目录，HOME 指到 scratch）：
##   godot --headless --path . --script res://tools/custom_map/bake_height.gd [-- --out=<abs .res>] [--check]
##   --check：只核，不写。核的是：原版 16 城和 38 个停靠点处，高度图与布局里烘焙时的 y 相比（陆上点 p95 ≤ 0.05）。

const TERRAIN := "res://assets/merchant_board_claude/terrain/board_terrain.glb"
const LAYOUT := "res://assets/merchant_board_claude/board_layout.json"
const OUT := "res://assets/custom_map/terrain/board_height.res"
const CELL := 0.125
const W := 1024
const H := 477
## 没有任何三角形落到格心的格子（棋盘外缘）：按海床算
const EMPTY_Y := -0.4


func _initialize() -> void:
	var out := ProjectSettings.globalize_path(OUT)
	var check_only := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
		elif a == "--check":
			check_only = true
	var t0 := Time.get_ticks_msec()
	var img: Image
	if check_only:
		img = load(OUT) as Image
		if img == null:
			printerr("BAKE_HEIGHT FAILED: 读不到 %s" % OUT)
			quit(1)
			return
	else:
		img = bake()
		if img == null:
			printerr("BAKE_HEIGHT FAILED: 光栅化失败")
			quit(1)
			return
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var err := ResourceSaver.save(img, out)
		if err != OK:
			printerr("BAKE_HEIGHT FAILED: 存不了 %s：%s" % [out, error_string(err)])
			quit(1)
			return
		print("BAKE_HEIGHT wrote %s size=%dx%d format=RF sha256=%s in %d ms" % [out, img.get_width(), img.get_height(),
			FileAccess.get_sha256(out), Time.get_ticks_msec() - t0])
	var rep := check(img)
	print("BAKE_HEIGHT_CHECK ", JSON.stringify(rep))
	quit(0 if bool(rep.get("ok", false)) else 1)


## 光栅化：每个三角形在 xz 平面上覆盖到的格心，按重心坐标插出 y，取最大
static func bake() -> Image:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var path := ProjectSettings.globalize_path(TERRAIN) if OS.has_feature("editor") else TERRAIN
	if doc.append_from_file(path, state) != OK:
		return null
	var scene := doc.generate_scene(state) as Node3D
	var heights := PackedFloat32Array()
	heights.resize(W * H)
	heights.fill(-INF)
	var tris := 0
	var verts := 0
	for mi in _mesh_instances(scene):
		if mi.mesh == null:
			continue
		var xf := _xf_to(mi, scene)
		for si in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(si)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			verts += v.size()
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var n := idx.size() if not idx.is_empty() else v.size()
			for k in range(0, n, 3):
				var a := xf * v[idx[k] if not idx.is_empty() else k]
				var b := xf * v[idx[k + 1] if not idx.is_empty() else k + 1]
				var c := xf * v[idx[k + 2] if not idx.is_empty() else k + 2]
				_raster(heights, a, b, c)
				tris += 1
	scene.free()
	var empty := 0
	var data := PackedByteArray()
	data.resize(W * H * 4)
	for i in W * H:
		var y := heights[i]
		if y == -INF:
			y = EMPTY_Y
			empty += 1
		data.encode_float(i * 4, y)
	print("BAKE_HEIGHT raster triangles=%d vertices=%d empty_cells=%d" % [tris, verts, empty])
	return Image.create_from_data(W, H, false, Image.FORMAT_RF, data)


static func _raster(heights: PackedFloat32Array, a: Vector3, b: Vector3, c: Vector3) -> void:
	var den := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(den) < 1e-9:
		return
	var i0 := maxi(0, int(floor(minf(a.x, minf(b.x, c.x)) / CELL - 0.5)))
	var i1 := mini(W - 1, int(ceil(maxf(a.x, maxf(b.x, c.x)) / CELL - 0.5)))
	var j0 := maxi(0, int(floor(minf(a.z, minf(b.z, c.z)) / CELL - 0.5)))
	var j1 := mini(H - 1, int(ceil(maxf(a.z, maxf(b.z, c.z)) / CELL - 0.5)))
	for j in range(j0, j1 + 1):
		var pz := (j + 0.5) * CELL
		for i in range(i0, i1 + 1):
			var px := (i + 0.5) * CELL
			var l1 := ((b.z - c.z) * (px - c.x) + (c.x - b.x) * (pz - c.z)) / den
			var l2 := ((c.z - a.z) * (px - c.x) + (a.x - c.x) * (pz - c.z)) / den
			var l3 := 1.0 - l1 - l2
			if l1 < -1e-6 or l2 < -1e-6 or l3 < -1e-6:
				continue
			var y := l1 * a.y + l2 * b.y + l3 * c.y
			var k := j * W + i
			if y > heights[k]:
				heights[k] = y


static func _mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for ch in node.get_children():
		out.append_array(_mesh_instances(ch))
	return out


static func _xf_to(node: Node, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n := node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## 验收（3.10.4）：原版 16 城、38 个停靠点（陆上的 20 个）处，高度图复原出来的 y 与布局里烘焙时的 y 相比，p95 ≤ 0.05；
## 另核 10 条陆路的点：y = H + LAND_LIFT，p95 ≤ 0.03（3.10.3 第 4 步）。
##   城：布局 y 就是城下的地面高 → 直接比 H(城心)。
##   陆上停靠点：烘焙时硬币放在那一格的地面上再抬 0.06（build_board.py:2322），之后那一圈又被压平、叠了地貌，
##     所以按「硬币 0.7 u 半径内最高的地面 + 0.06」复原（CustomMapGeo.stop_y 用同一个公式给新停靠点定高）。
##   海上停靠点、海路：一律 0.04，与高度图无关。
const LAND_LIFT := 0.09
const STOP_LIFT := 0.06
const STOP_R := 0.7


static func check(img: Image) -> Dictionary:
	var lay: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	var city_err: Array = []
	for c: Dictionary in lay.cities:
		city_err.append(absf(sample(img, float(c.x), float(c.z)) - float(c.y)))
	var stop_err: Array = []
	for s: Dictionary in lay.stops:
		if String(s.type) == "LAND":
			stop_err.append(absf(stop_y(img, float(s.x), float(s.z)) - float(s.y)))
	var route_err: Array = []
	for r: Dictionary in lay.routes:
		if String(r.type) != "LAND":
			continue
		for q: Array in r.points:
			route_err.append(absf(sample(img, float(q[0]), float(q[2])) + LAND_LIFT - float(q[1])))
	var city_p95 := _pct(city_err, 0.95)
	var stop_p95 := _pct(stop_err, 0.95)
	var route_p95 := _pct(route_err, 0.95)
	return {"ok": city_p95 <= 0.05 and stop_p95 <= 0.05 and route_p95 <= 0.03, "size": [img.get_width(), img.get_height()],
		"cities": city_err.size(), "city_abs_err_p95": snappedf(city_p95, 0.0001), "city_abs_err_max": snappedf(_pct(city_err, 1.0), 0.0001),
		"land_stops": stop_err.size(), "land_stop_abs_err_p95": snappedf(stop_p95, 0.0001), "land_stop_abs_err_max": snappedf(_pct(stop_err, 1.0), 0.0001),
		"land_route_points": route_err.size(), "land_route_abs_err_p95": snappedf(route_p95, 0.0001), "land_route_abs_err_max": snappedf(_pct(route_err, 1.0), 0.0001)}


## 硬币的高：STOP_R 半径内（24 个方向 × 圆心、半径一半、半径）最高的地面 + STOP_LIFT
static func stop_y(img: Image, x: float, z: float) -> float:
	var mx := sample(img, x, z)
	for i in 24:
		var a := TAU * i / 24.0
		for rr in [STOP_R * 0.5, STOP_R]:
			mx = maxf(mx, sample(img, x + cos(a) * rr, z + sin(a) * rr))
	return mx + STOP_LIFT


## 格心之间双线性插值（与 CustomMapGeo.height 同一种算法）
static func sample(img: Image, x: float, z: float) -> float:
	var u := x / CELL - 0.5
	var v := z / CELL - 0.5
	var x0 := clampi(int(floor(u)), 0, W - 1)
	var y0 := clampi(int(floor(v)), 0, H - 1)
	var x1 := mini(x0 + 1, W - 1)
	var y1 := mini(y0 + 1, H - 1)
	var fx := clampf(u - floor(u), 0.0, 1.0)
	var fy := clampf(v - floor(v), 0.0, 1.0)
	var h00 := img.get_pixel(x0, y0).r
	var h10 := img.get_pixel(x1, y0).r
	var h01 := img.get_pixel(x0, y1).r
	var h11 := img.get_pixel(x1, y1).r
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)


static func _pct(values: Array, q: float) -> float:
	if values.is_empty():
		return 0.0
	var s := values.duplicate()
	s.sort()
	return float(s[clampi(int(ceil(q * s.size())) - 1, 0, s.size() - 1)])
