extends RefCounted
## 长安旅人 · 日暮地面散布的离线烘焙（TASK-CHANGAN-DUSK-001，2026-09-24 由探针 tools/traveler/lookdev_changan/changan_extra_ground.gd 转正）。
## 探针在启动时用 GDScript 现场撒点（约 4 秒）；正式版把同一套算法挪到这里离线跑一次，结果存成
## assets/traveler/changan_dusk/ground_scatter.scn（三组 MultiMesh：落叶、干草、碎石），运行时只加载。
## 采样、避让、网格代码与探针逐行相同（同一随机种子、同一遍历顺序 → 同一批实例），只把"建节点挂到世界"换成"打包存盘"。
##
## 怎么重烘（地形 / 城池 / 树 / 河 / 佛窟位置改了才需要）：在长安日暮同一机位的场景里跑，读的是运行时的真实场景状态
## （佛窟 fit_ground 改过的地形、VegetationHigh 的实例变换只有真渲染器能读回，所以不能 --headless）：
##   Godot --path . --script res://tools/traveler/capture_traveler.gd -- --capture-scene=res://scenes/traveler/traveler_main.tscn \
##     --view=changan --dusk --far --bake-changan-dusk-scatter --capture=<任意 png>
## 参数在 data/traveler/look_presets.json 的 scenes.changan.dusk.layers.ground.scatter_bake（键名照探针 variant）。
## 只撒在画面内、离相机 d_min..d_max：按 1920×1080（截图 SubViewport）判定画面范围。
##
## 做的事（与探针相同）：三层贴地散布（MultiMesh ×3，cast_shadow 关，GI 关）：落叶、干草丛、碎石。
##   - 贴地：对 Terrain64 网格（含佛窟 fit_ground 改过的）+ 长安城底板三角在 xz 上求重心坐标，取最高面；法线取该面。
##   - 避让：城池里贴近地面的非底板三角（石板路、台阶、台基、树干、长椅、灯笼、灌木底）xz 占位 + 膨胀；
##           河道三角占位 + 膨胀；VegetationHigh 树干圆；NaturalDetails 石头圆；佛窟圆；陡坡不撒。
##   - 分布：只撒在画面内、离相机 d_min..d_max；近处略稀、中景最密、景深外淡出；噪声成团；
##           落叶在树冠下成堆（颜色取那棵树的色系），顺风向略偏。
##   - 颜色走 MultiMesh 实例色（乘顶点色）；材质不存盘，运行时由 changan_dusk_layers.gd 复制地形材质挂上。

const OCC := 0.05
const BUCKET := 0.5
const CANOPY_CELL := 0.3

var host: Node3D
var cam: Camera3D
var wrld: Node3D
var cfg: Dictionary = {}
var rng := RandomNumberGenerator.new()
var noise_a := FastNoiseLite.new()
var noise_b := FastNoiseLite.new()
var ta := PackedVector3Array()
var tb := PackedVector3Array()
var tc := PackedVector3Array()
var tplate := PackedByteArray()
var buckets: Dictionary = {}
var occ: Dictionary = {}
var circles: Array = []
var trees: Array = []            # [Vector2 pos, float radius, int palette, float weight]
var tree_grid: Dictionary = {}   # Vector2i(1u) -> Array[int]
var region := Rect2()
var court := Rect2()             # 长安城底板的世界 xz 外框：框内不是底板的地方 = 院子缺口（灯下），什么都不撒
var cam_pos := Vector3.ZERO
var vp_size := Vector2(1920, 1080)
var wind := Vector2(1.0, 0.38)
var reject := {"height": 0, "occ": 0, "circle": 0, "screen": 0, "slope": 0, "density": 0, "plate": 0}
var _pv := PackedVector3Array()
var _pn := PackedVector3Array()
var _pc := PackedColorArray()

# 落叶色系（线性反照率；取自长安城树冠顶点色，略压暗 = 干叶）
var palettes: Array = [
	[Color(0.50, 0.09, 0.03), Color(0.64, 0.19, 0.05), Color(0.36, 0.05, 0.02), Color(0.44, 0.20, 0.04)],   # 0 红 / 铜
	[Color(0.70, 0.45, 0.06), Color(0.56, 0.33, 0.06), Color(0.62, 0.37, 0.07), Color(0.47, 0.25, 0.03)],   # 1 金
	[Color(0.40, 0.30, 0.10), Color(0.30, 0.17, 0.05), Color(0.46, 0.33, 0.12), Color(0.27, 0.20, 0.08)],   # 2 枯褐（常绿树 / 野外）
]

func _f(key: String, fallback: float) -> float:
	return float(cfg.get(key, fallback))

func _col(value: Variant, fallback: Color) -> Color:
	if value is Array and (value as Array).size() >= 3:
		return Color(float(value[0]), float(value[1]), float(value[2]))
	return fallback

func bake(h: Node3D, c: Dictionary, out_path: String) -> Dictionary:
	host = h
	cfg = c
	cam = host.get("camera") as Camera3D
	wrld = host.get("world") as Node3D
	var t0 := Time.get_ticks_msec()
	var seed_value := int(_f("seed", 20260923))
	rng.seed = seed_value
	noise_a.seed = seed_value + 3
	noise_a.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise_a.frequency = _f("clump_freq", 0.35)
	noise_b.seed = seed_value + 11
	noise_b.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise_b.frequency = _f("clump_fine_freq", 1.3)
	cam_pos = cam.global_position
	vp_size = host.get_viewport().get_visible_rect().size
	if cfg.has("wind"):
		wind = Vector2(float(cfg.wind[0]), float(cfg.wind[1]))
	var out := {}
	_make_region()
	out["region"] = [region.position.x, region.position.y, region.end.x, region.end.y]
	out["ground_triangles"] = _collect_ground()
	out["city_occupancy"] = _city_occupancy()
	out["river_occupancy"] = _river_occupancy()
	out["trees"] = _collect_trees()
	out["rocks"] = _collect_rocks()
	out["cliff"] = _cliff_circle()
	out["occ_cells"] = occ.size()
	var root := Node3D.new()
	root.name = "GroundDetailScatter"
	out["leaves"] = _build_leaves(root, null)
	out["grass"] = _build_grass(root, null)
	out["pebbles"] = _build_pebbles(root, null)
	out["new_geometry_instances"] = root.get_child_count()
	out["rejections"] = reject
	out["build_ms"] = Time.get_ticks_msec() - t0
	out["camera_position"] = [cam_pos.x, cam_pos.y, cam_pos.z]
	out["viewport_size"] = [vp_size.x, vp_size.y]
	# 院子缺口（长安城底板外框）：运行时写进地形材质的 ground_clear_rect（地面细节在灯下院子里留白）
	root.set_meta("court_rect", [court.position.x, court.position.y, court.end.x, court.end.y])
	root.set_meta("bake_report", out.duplicate(true))
	root.set_meta("bake_time", Time.get_datetime_string_from_system())
	for child in root.get_children():
		child.owner = root
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	var save_error := ResourceSaver.save(packed, out_path, ResourceSaver.FLAG_COMPRESS) if pack_error == OK else pack_error
	out["saved"] = out_path
	out["save_error"] = save_error
	root.free()
	return out

# ---------------------------------------------------------------- 2. 区域 / 贴地
func _ray_ground_plane(nx: float, ny: float, y: float) -> Variant:
	var sp := Vector2(nx, ny) * vp_size
	var o: Vector3 = cam.project_ray_origin(sp)
	var d: Vector3 = cam.project_ray_normal(sp)
	if d.y > -0.001:
		return null
	var t: float = (y - o.y) / d.y
	return o + d * t

func _make_region() -> void:
	var dmax := _f("d_max", 28.0)
	var first := true
	for iy in 25:
		var ny := lerpf(0.40, 1.0, float(iy) / 24.0)
		for ix in 17:
			var nx := lerpf(-0.05, 1.05, float(ix) / 16.0)
			var hit: Variant = _ray_ground_plane(nx, ny, 0.65)
			if hit == null:
				continue
			var p: Vector3 = hit
			if p.distance_to(cam_pos) > dmax:
				var dir := (p - cam_pos).normalized()
				p = cam_pos + dir * dmax
			var q := Vector2(p.x, p.z)
			if first:
				region = Rect2(q, Vector2.ZERO)
				first = false
			else:
				region = region.expand(q)
	region = region.grow(1.0)

func _bkey(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / BUCKET), floori(z / BUCKET))

func _add_ground_tri(a: Vector3, b: Vector3, c: Vector3, plate: bool) -> void:
	var lo := Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z)))
	var hi := Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z)))
	if hi.x < region.position.x or lo.x > region.end.x or hi.y < region.position.y or lo.y > region.end.y:
		return
	var idx := ta.size()
	ta.append(a)
	tb.append(b)
	tc.append(c)
	tplate.append(1 if plate else 0)
	var k0 := _bkey(lo.x, lo.y)
	var k1 := _bkey(hi.x, hi.y)
	for gx in range(k0.x, k1.x + 1):
		for gz in range(k0.y, k1.y + 1):
			var key := Vector2i(gx, gz)
			if not buckets.has(key):
				buckets[key] = PackedInt32Array()
			var arr: PackedInt32Array = buckets[key]
			arr.append(idx)
			buckets[key] = arr

func _tri_arrays(mesh: Mesh, s: int) -> Array:
	var arrays: Array = mesh.surface_get_arrays(s)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var ids := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		ids = arrays[Mesh.ARRAY_INDEX]
	if ids.is_empty():
		ids.resize(verts.size())
		for i in verts.size():
			ids[i] = i
	return [verts, ids, arrays[Mesh.ARRAY_COLOR]]

func _collect_ground() -> Dictionary:
	var n_terrain := 0
	var n_plate := 0
	var terrain: Node = wrld.get_node_or_null("Terrain64")
	if terrain != null:
		for item in terrain.find_children("*", "MeshInstance3D", true, false):
			var mi := item as MeshInstance3D
			if mi.mesh == null or not mi.is_visible_in_tree():
				continue
			var box: AABB = mi.global_transform * mi.get_aabb()
			if box.end.x < region.position.x or box.position.x > region.end.x or box.end.z < region.position.y or box.position.z > region.end.y:
				continue
			var xf := mi.global_transform
			for s in mi.mesh.get_surface_count():
				var ta_: Array = _tri_arrays(mi.mesh, s)
				var verts: PackedVector3Array = ta_[0]
				var ids: PackedInt32Array = ta_[1]
				for t in range(0, ids.size(), 3):
					_add_ground_tri(xf * verts[ids[t]], xf * verts[ids[t + 1]], xf * verts[ids[t + 2]], false)
					n_terrain += 1
	var city := wrld.get_node_or_null("Cities/changan/changan") as MeshInstance3D
	if city != null and city.mesh != null:
		var xf := city.global_transform
		var ta_: Array = _tri_arrays(city.mesh, 0)
		var verts: PackedVector3Array = ta_[0]
		var ids: PackedInt32Array = ta_[1]
		for t in range(0, ids.size(), 3):
			var a: Vector3 = verts[ids[t]]
			var b: Vector3 = verts[ids[t + 1]]
			var cc: Vector3 = verts[ids[t + 2]]
			if maxf(a.y, maxf(b.y, cc.y)) > 0.004:
				continue
			var wa: Vector3 = xf * a
			var wb: Vector3 = xf * b
			var wc: Vector3 = xf * cc
			_add_ground_tri(wa, wb, wc, true)
			for q in [wa, wb, wc]:
				var q2 := Vector2(q.x, q.z)
				if n_plate == 0 and q == wa:
					court = Rect2(q2, Vector2.ZERO)
				else:
					court = court.expand(q2)
			n_plate += 1
	return {"terrain": n_terrain, "plate": n_plate, "kept": ta.size(), "buckets": buckets.size(),
		"court_rect": [court.position.x, court.position.y, court.end.x, court.end.y]}

## 返回 [y, 法线(朝上), 是否城池底板, 是否院子缺口]；找不到返回 []
func _ground(p: Vector2) -> Array:
	var key := _bkey(p.x, p.y)
	if not buckets.has(key):
		return []
	var best_y := -INF
	var best := -1
	var arr: PackedInt32Array = buckets[key]
	for idx in arr:
		var a: Vector3 = ta[idx]
		var b: Vector3 = tb[idx]
		var c: Vector3 = tc[idx]
		var det := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(det) < 1e-9:
			continue
		var l1 := ((b.z - c.z) * (p.x - c.x) + (c.x - b.x) * (p.y - c.z)) / det
		var l2 := ((c.z - a.z) * (p.x - c.x) + (a.x - c.x) * (p.y - c.z)) / det
		var l3 := 1.0 - l1 - l2
		if l1 < -1e-5 or l2 < -1e-5 or l3 < -1e-5:
			continue
		var y := l1 * a.y + l2 * b.y + l3 * c.y
		if y > best_y:
			best_y = y
			best = idx
	if best < 0:
		return []
	var n: Vector3 = (tb[best] - ta[best]).cross(tc[best] - ta[best]).normalized()
	if n.y < 0.0:
		n = -n
	var on_plate := tplate[best] == 1
	return [best_y, n, on_plate, (not on_plate) and court.has_point(p)]

# ---------------------------------------------------------------- 3. 避让
func _okey(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / OCC), floori(z / OCC))

func _mark_box(lo: Vector2, hi: Vector2, pad: float) -> void:
	var k0 := _okey(lo.x - pad, lo.y - pad)
	var k1 := _okey(hi.x + pad, hi.y + pad)
	if (k1.x - k0.x) * (k1.y - k0.y) > 4000:
		return
	for gx in range(k0.x, k1.x + 1):
		for gz in range(k0.y, k1.y + 1):
			occ[Vector2i(gx, gz)] = true

func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	return p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))

## 精确三角占位（长条三角的 bbox 太大，河道用这个）
func _mark_tri(a: Vector2, b: Vector2, c: Vector2, pad: float) -> int:
	var lo := a.min(b).min(c) - Vector2(pad, pad)
	var hi := a.max(b).max(c) + Vector2(pad, pad)
	if hi.x < region.position.x or lo.x > region.end.x or hi.y < region.position.y or lo.y > region.end.y:
		return 0
	var k0 := _okey(maxf(lo.x, region.position.x), maxf(lo.y, region.position.y))
	var k1 := _okey(minf(hi.x, region.end.x), minf(hi.y, region.end.y))
	var poly := PackedVector2Array([a, b, c])
	var n := 0
	for gx in range(k0.x, k1.x + 1):
		for gz in range(k0.y, k1.y + 1):
			var q := Vector2((gx + 0.5) * OCC, (gz + 0.5) * OCC)
			if Geometry2D.is_point_in_polygon(q, poly) or _seg_dist(q, a, b) < pad or _seg_dist(q, b, c) < pad or _seg_dist(q, c, a) < pad:
				occ[Vector2i(gx, gz)] = true
				n += 1
	return n

func _city_occupancy() -> Dictionary:
	var city := wrld.get_node_or_null("Cities/changan/changan") as MeshInstance3D
	if city == null or city.mesh == null:
		return {"missing": true}
	var xf := city.global_transform
	var low_local := _f("city_low_local", 0.35)
	var pad := _f("city_pad_u", 0.06)
	var n := 0
	var canopy_pts := 0
	var canopy_cells: Dictionary = {}
	for s in city.mesh.get_surface_count():
		var ta_: Array = _tri_arrays(city.mesh, s)
		var verts: PackedVector3Array = ta_[0]
		var ids: PackedInt32Array = ta_[1]
		var cols: Variant = ta_[2]
		var is_plants := s == 2
		for t in range(0, ids.size(), 3):
			var a: Vector3 = verts[ids[t]]
			var b: Vector3 = verts[ids[t + 1]]
			var c: Vector3 = verts[ids[t + 2]]
			var ymin := minf(a.y, minf(b.y, c.y))
			var ymax := maxf(a.y, maxf(b.y, c.y))
			if s == 0 and ymax <= 0.004:
				continue   # 城池底板本身：可撒（只撒少量落叶）
			if is_plants and ymin > 0.9:
				# 城内树冠：按 0.3u 格子聚合成小「树」，落叶在下面成堆
				var cen: Vector3 = xf * ((a + b + c) / 3.0)
				var colr := Color(0.6, 0.2, 0.05)
				if cols != null:
					colr = (cols as PackedColorArray)[ids[t]]
				var ck := Vector2i(floori(cen.x / CANOPY_CELL), floori(cen.z / CANOPY_CELL))
				if not canopy_cells.has(ck):
					canopy_cells[ck] = [Vector2.ZERO, 0, [0, 0, 0]]
				var cell: Array = canopy_cells[ck]
				cell[0] = (cell[0] as Vector2) + Vector2(cen.x, cen.z)
				cell[1] = int(cell[1]) + 1
				var votes: Array = cell[2]
				var pk := _palette_of(colr)
				votes[pk] = int(votes[pk]) + 1
				canopy_pts += 1
				continue
			if ymin > low_local:
				continue
			var wa: Vector3 = xf * a
			var wb: Vector3 = xf * b
			var wc: Vector3 = xf * c
			_mark_box(Vector2(minf(wa.x, minf(wb.x, wc.x)), minf(wa.z, minf(wb.z, wc.z))), Vector2(maxf(wa.x, maxf(wb.x, wc.x)), maxf(wa.z, maxf(wb.z, wc.z))), pad)
			n += 1
	var full := _f("city_canopy_full", 60.0)
	for ck in canopy_cells.keys():
		var cell: Array = canopy_cells[ck]
		var cnt := int(cell[1])
		var votes: Array = cell[2]
		var pal := 0
		for k in 3:
			if int(votes[k]) > int(votes[pal]):
				pal = k
		trees.append([(cell[0] as Vector2) / float(cnt), _f("city_canopy_r", 0.3), pal, _f("city_canopy_w", 0.5) * minf(float(cnt) / full, 1.0)])
	return {"low_triangles": n, "canopy_points": canopy_pts, "canopy_cells": canopy_cells.size()}

func _palette_of(colr: Color) -> int:
	if colr.g >= colr.r:
		return 2
	if colr.g > colr.r * 0.5:
		return 1
	if colr.r > colr.g * 1.6:
		return 0
	return 2

func _river_occupancy() -> Dictionary:
	var water: Node = wrld.get_node_or_null("Water/Rivers")
	if water == null:
		return {"missing": true}
	var pad := _f("river_pad_u", 0.12)
	var tris := 0
	var cells := 0
	for item in water.find_children("*", "MeshInstance3D", true, false):
		var mi := item as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = mi.global_transform * mi.get_aabb()
		if box.end.x < region.position.x or box.position.x > region.end.x or box.end.z < region.position.y or box.position.z > region.end.y:
			continue
		var xf := mi.global_transform
		for s in mi.mesh.get_surface_count():
			var ta_: Array = _tri_arrays(mi.mesh, s)
			var verts: PackedVector3Array = ta_[0]
			var ids: PackedInt32Array = ta_[1]
			for t in range(0, ids.size(), 3):
				var a: Vector3 = xf * verts[ids[t]]
				var b: Vector3 = xf * verts[ids[t + 1]]
				var c: Vector3 = xf * verts[ids[t + 2]]
				var got := _mark_tri(Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z), pad)
				if got > 0:
					tris += 1
					cells += got
	return {"triangles": tris, "cells": cells}

func _collect_trees() -> Dictionary:
	var veg := wrld.get_node_or_null("VegetationHigh") as Node3D
	var n := 0
	var kinds := {}
	if veg != null and veg.is_visible_in_tree():
		for item in veg.find_children("*", "MultiMeshInstance3D", true, false):
			var node := item as MultiMeshInstance3D
			if node.multimesh == null or node.multimesh.mesh == null or not node.is_visible_in_tree():
				continue
			var nm := str(node.name).to_lower()
			var pal := 2
			var w := 0.35
			if nm.contains("gold"):
				pal = 1
				w = 1.0
			elif nm.contains("copper"):
				pal = 0
				w = 1.0
			elif nm.contains("palm") or nm.contains("tropic"):
				w = 0.0
			var aabb := node.multimesh.mesh.get_aabb()
			for i in node.multimesh.instance_count:
				var xf: Transform3D = node.global_transform * node.multimesh.get_instance_transform(i)
				var o := xf.origin
				if not region.grow(1.0).has_point(Vector2(o.x, o.z)):
					continue
				var s := xf.basis.get_scale().x
				if s < 0.0001:
					continue
				var cr := maxf(aabb.size.x, aabb.size.z) * 0.5 * s
				circles.append([Vector2(o.x, o.z), clampf(cr * _f("trunk_frac", 0.12), 0.03, 0.09)])
				if w > 0.0:
					trees.append([Vector2(o.x, o.z), cr, pal, w])
				n += 1
				kinds[nm.get_slice("_", 1)] = int(kinds.get(nm.get_slice("_", 1), 0)) + 1
	for i in trees.size():
		var p: Vector2 = trees[i][0]
		var key := Vector2i(floori(p.x), floori(p.y))
		if not tree_grid.has(key):
			tree_grid[key] = []
		(tree_grid[key] as Array).append(i)
	return {"instances": n, "kinds": kinds, "canopies": trees.size()}

func _collect_rocks() -> Dictionary:
	var nd: Node = wrld.get_node_or_null("NaturalDetails")
	var n := 0
	if nd == null:
		return {"missing": true}
	for item in nd.find_children("*", "MultiMeshInstance3D", true, false):
		var node := item as MultiMeshInstance3D
		var nm := str(node.name).to_lower()
		if nm.contains("grass") or node.multimesh == null or node.multimesh.mesh == null:
			continue
		var aabb := node.multimesh.mesh.get_aabb()
		for i in node.multimesh.instance_count:
			var xf: Transform3D = node.global_transform * node.multimesh.get_instance_transform(i)
			var o := xf.origin
			if not region.grow(1.0).has_point(Vector2(o.x, o.z)):
				continue
			var box: AABB = xf * aabb
			var r := maxf(box.size.x, box.size.z) * 0.5 * _f("rock_r_frac", 0.85) + 0.02
			circles.append([Vector2(box.get_center().x, box.get_center().z), r])
			n += 1
	return {"rocks": n}

func _cliff_circle() -> Dictionary:
	var cliff := wrld.get_node_or_null("CliffBuddha") as Node3D
	if cliff == null:
		return {"missing": true}
	var p := cliff.global_position
	var r := _f("cliff_r", 3.9)
	circles.append([Vector2(p.x, p.z), r])
	return {"center": [p.x, p.z], "r": r}

# ---------------------------------------------------------------- 4. 采样
func _canopy(p: Vector2) -> Array:
	# 返回 [落叶加成, 主色系]
	var q := p - wind.normalized() * _f("leaf_drift_u", 0.15)
	var total := 0.0
	var best := 0.0
	var pal := 2
	var k := Vector2i(floori(q.x), floori(q.y))
	for gx in range(k.x - 2, k.x + 3):
		for gz in range(k.y - 2, k.y + 3):
			var key := Vector2i(gx, gz)
			if not tree_grid.has(key):
				continue
			for i in tree_grid[key]:
				var t: Array = trees[i]
				var r: float = float(t[1]) * _f("canopy_reach", 1.25)
				var d := q.distance_to(t[0])
				if d > r * 1.8:
					continue
				var v := exp(-(d * d) / (r * r)) * float(t[3])
				total += v
				if v > best:
					best = v
					pal = int(t[2])
	return [minf(total, 2.0), pal]

func _clump(p: Vector2) -> float:
	var n := 0.65 * noise_a.get_noise_2d(p.x, p.y) + 0.35 * noise_b.get_noise_2d(p.x, p.y)
	return smoothstep(_f("clump_lo", -0.25), _f("clump_hi", 0.45), n)

func _dist_ramp(d: float) -> float:
	var near := lerpf(_f("near_density", 0.55), 1.0, smoothstep(_f("d_min", 5.0), _f("mid_density_d", 9.0), d))
	var far := lerpf(1.0, 0.0, smoothstep(_f("far_fade_d", 18.0), _f("d_max", 28.0), d))
	return near * far

func _on_screen(w: Vector3) -> bool:
	if cam.is_position_behind(w):
		return false
	var px: Vector2 = cam.unproject_position(w) / vp_size
	return px.x > -0.02 and px.x < 1.02 and px.y > -0.02 and px.y < 1.04

func _blocked(p: Vector2) -> bool:
	if occ.has(_okey(p.x, p.y)):
		reject["occ"] += 1
		return true
	for c in circles:
		var cp: Vector2 = c[0]
		var cr: float = c[1]
		if absf(cp.x - p.x) < cr and absf(cp.y - p.y) < cr and p.distance_squared_to(cp) < cr * cr:
			reject["circle"] += 1
			return true
	return false

## 返回 {p, y, n, d, canopy, pal, plate} 或空
func _sample(kind: String, min_up: float) -> Dictionary:
	for attempt in 60:
		var p := Vector2(rng.randf_range(region.position.x, region.end.x), rng.randf_range(region.position.y, region.end.y))
		var d_flat := Vector2(cam_pos.x, cam_pos.z).distance_to(p)
		if d_flat > _f("d_max", 28.0) or d_flat < _f("d_min", 5.0) * 0.6:
			reject["density"] += 1
			continue
		var cano: Array = [0.0, 2]
		var dens := _clump(p)
		if kind == "leaf":
			cano = _canopy(p)
			dens = dens * _f("leaf_base", 0.35) + float(cano[0]) * _f("leaf_canopy", 1.0)
		elif kind == "grass":
			dens = dens * (1.0 - 0.5 * minf(float(_canopy(p)[0]), 1.0))
		var g := _ground(p)
		if g.is_empty():
			reject["height"] += 1
			continue
		var w := Vector3(p.x, float(g[0]), p.y)
		var d := w.distance_to(cam_pos)
		dens *= _dist_ramp(d)
		if bool(g[3]):
			reject["plate"] += 1
			continue
		if bool(g[2]):
			dens *= _f(kind + "_plate_mul", 0.0)
		if rng.randf() > dens:
			reject["density"] += 1
			continue
		var n: Vector3 = g[1]
		if n.y < min_up:
			reject["slope"] += 1
			continue
		if _blocked(p):
			continue
		if not _on_screen(w):
			reject["screen"] += 1
			continue
		return {"p": p, "w": w, "n": n, "d": d, "canopy": float(cano[0]), "pal": int(cano[1]), "plate": bool(g[2])}
	return {}

# ---------------------------------------------------------------- 5. 网格
func _buf_reset() -> void:
	_pv = PackedVector3Array()
	_pn = PackedVector3Array()
	_pc = PackedColorArray()

func _buf_mesh() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _pv
	arrays[Mesh.ARRAY_NORMAL] = _pn
	arrays[Mesh.ARRAY_COLOR] = _pc
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## Godot 正面 = 顺时针：保证 (c-a)×(b-a) 与期望法线同向（atlas shader 双面，背面会翻法线，所以绕序必须对）
func _tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3, colr: Color) -> void:
	if (c - a).cross(b - a).dot(n) < 0.0:
		var tmp := b
		b = c
		c = tmp
	for q in [a, b, c]:
		_pv.append(q)
		_pn.append(n)
		_pc.append(colr)

func _face(a: Vector3, b: Vector3, c: Vector3, out_hint: Vector3, colr: Color) -> void:
	var n := (b - a).cross(c - a).normalized()
	if n.dot(out_hint) < 0.0:
		n = -n
	_tri(a, b, c, n, colr)

func _leaf_mesh() -> ArrayMesh:
	# 低多边形落叶：叶尖 / 叶柄 / 两侧 + 抬起的中脉 → 4 个面，像微微对折的叶子，两半各自受光。
	_buf_reset()
	var tip := Vector3(0.0, 0.0, 0.5)
	var base := Vector3(0.0, 0.02, -0.5)
	var l := Vector3(-0.32, 0.0, 0.04)
	var r := Vector3(0.30, 0.0, -0.06)
	var mid := Vector3(0.0, 0.14, 0.0)
	var up := Vector3.UP
	_face(tip, l, mid, up, Color.WHITE)
	_face(l, base, mid, up, Color(0.9, 0.9, 0.9))
	_face(base, r, mid, up, Color(0.9, 0.9, 0.9))
	_face(r, tip, mid, up, Color.WHITE)
	return _buf_mesh()

func _pebble_mesh() -> ArrayMesh:
	# 平顶碎块（同巴格达）：底环 5 + 错位顶环 5 + 埋地底尖；露出地面 13 个面。
	var r := RandomNumberGenerator.new()
	r.seed = 4242
	var sides := 5
	var low: Array[Vector3] = []
	var high: Array[Vector3] = []
	for i in sides:
		var a := TAU * (float(i) + r.randf_range(-0.15, 0.15)) / sides
		var rad := r.randf_range(0.44, 0.52)
		low.append(Vector3(cos(a) * rad, r.randf_range(0.26, 0.40), sin(a) * rad))
		var a2 := TAU * (float(i) + 0.5 + r.randf_range(-0.12, 0.12)) / sides
		var rad2 := r.randf_range(0.22, 0.32)
		high.append(Vector3(cos(a2) * rad2 + 0.05, r.randf_range(0.78, 1.0), sin(a2) * rad2 - 0.03))
	var bottom := Vector3.ZERO
	var center := Vector3(0.0, 0.5, 0.0)
	_buf_reset()
	var tris: Array = []
	for i in sides:
		var j := (i + 1) % sides
		tris.append([bottom, low[j], low[i]])
		tris.append([low[i], low[j], high[i]])
		tris.append([high[i], low[j], high[j]])
	for i in range(1, sides - 1):
		tris.append([high[0], high[i], high[i + 1]])
	for tri in tris:
		var a: Vector3 = tri[0]
		var b: Vector3 = tri[1]
		var c: Vector3 = tri[2]
		_face(a, b, c, (a + b + c) / 3.0 - center, Color.WHITE)
	return _buf_mesh()

func _grass_mesh() -> ArrayMesh:
	# 干草丛：n 片细三角，向外倾；正反各一份，法线偏上（避免逆光下整片发黑）。叶根暗、叶尖亮（顶点色，乘实例色）。
	var r := RandomNumberGenerator.new()
	r.seed = 9191
	_buf_reset()
	var blades := int(_f("grass_blades", 7))
	var base_col := Color(0.62, 0.60, 0.58)
	var tip_col := Color(1.0, 1.0, 1.0)
	for i in blades:
		var yaw := TAU * (float(i) + r.randf_range(-0.3, 0.3)) / blades
		var dir := Vector3(cos(yaw), 0.0, sin(yaw))
		var perp := Vector3(-dir.z, 0.0, dir.x)
		var lean := r.randf_range(0.25, 0.8)
		var hh := r.randf_range(0.55, 1.0)
		var w := r.randf_range(0.08, 0.12)
		var b0 := dir * 0.05 + perp * w * 0.5
		var b1 := dir * 0.05 - perp * w * 0.5
		var tip := dir * (0.05 + sin(lean) * hh) + Vector3.UP * cos(lean) * hh + perp * r.randf_range(-0.05, 0.05)
		var fn := (b1 - b0).cross(tip - b0).normalized()
		for side in [1.0, -1.0]:
			var n: Vector3 = (fn * side * 0.55 + Vector3.UP * 0.45).normalized()
			var a := b0
			var b := b1
			var c := tip
			if (c - a).cross(b - a).dot(fn * side) < 0.0:
				var tmp := b
				b = c
				c = tmp
			for q in [a, b, c]:
				_pv.append(q)
				_pn.append(n)
				_pc.append(tip_col if q == tip else base_col)
	return _buf_mesh()

func _mmi(root: Node3D, name: String, mesh: ArrayMesh, xforms: Array, colors: Array, mat: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colors[i])
	var node := MultiMeshInstance3D.new()
	node.name = name
	node.multimesh = mm
	if mat != null:
		node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(node)
	return node

func _align(n: Vector3) -> Basis:
	return Basis(Quaternion(Vector3.UP, n.normalized()))

# ---------------------------------------------------------------- 6. 三层散布
func _build_leaves(root: Node3D, mat: Material) -> Dictionary:
	var want := int(_f("leaf_count", 7000))
	var s0 := _f("leaf_size", 0.055)
	var lift := _f("leaf_lift_u", 0.004)
	var xforms: Array = []
	var colors: Array = []
	var by_pal := [0, 0, 0]
	var on_plate := 0
	for i in want:
		var s := _sample("leaf", _f("leaf_min_up", 0.7))
		if s.is_empty():
			continue
		var n: Vector3 = s.n
		var size := s0 * rng.randf_range(0.65, 1.35) * lerpf(1.0, _f("leaf_far_scale", 1.3), smoothstep(10.0, 22.0, float(s.d)))
		var tilt := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, _f("leaf_tilt", 0.35)))
		var basis := _align(n) * tilt * Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(size * rng.randf_range(0.8, 1.15), size * 0.6, size))
		xforms.append(Transform3D(basis, Vector3(s.w) + n * lift))
		var pal := int(s.pal)
		var cano := float(s.canopy)
		if cano < 0.25 or rng.randf() < _f("leaf_mix_other", 0.15):
			# 空地上的落叶是风吹来的：红 / 金 / 枯褐按权重混
			var r := rng.randf()
			var wr := _f("open_red", 0.32)
			var wg := _f("open_gold", 0.38)
			pal = 0 if r < wr else (1 if r < wr + wg else 2)
		var plist: Array = palettes[pal]
		var cc: Color = plist[rng.randi() % plist.size()]
		var k := rng.randf_range(0.8, 1.1) * _f("leaf_value", 1.0)
		colors.append(Color(cc.r * k, cc.g * k, cc.b * k))
		by_pal[pal] += 1
		if bool(s.plate):
			on_plate += 1
	_mmi(root, "GroundLeaves", _leaf_mesh(), xforms, colors, mat)
	return {"count": xforms.size(), "want": want, "by_palette_red_gold_brown": by_pal, "on_plate": on_plate, "triangles": xforms.size() * 4}

func _build_grass(root: Node3D, mat: Material) -> Dictionary:
	var want := int(_f("grass_count", 2200))
	var h0 := _f("grass_h", 0.075)
	var xforms: Array = []
	var colors: Array = []
	var straw := _col(cfg.get("grass_straw"), Color(0.55, 0.42, 0.18))
	var olive := _col(cfg.get("grass_olive"), Color(0.36, 0.38, 0.17))
	for i in want:
		var s := _sample("grass", _f("grass_min_up", 0.78))
		if s.is_empty():
			continue
		var n: Vector3 = (Vector3(s.n) + Vector3.UP).normalized()
		var hh := h0 * rng.randf_range(0.6, 1.4)
		var wd := hh * rng.randf_range(0.8, 1.3)
		var basis := _align(n) * Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(wd, hh, wd))
		xforms.append(Transform3D(basis, Vector3(s.w) - n * 0.08 * hh))
		var cc := straw if rng.randf() > _f("grass_olive_share", 0.3) else olive
		var k := rng.randf_range(0.8, 1.15)
		colors.append(Color(cc.r * k, cc.g * k, cc.b * k))
	var mesh := _grass_mesh()
	_mmi(root, "GroundDryGrass", mesh, xforms, colors, mat)
	return {"count": xforms.size(), "want": want, "triangles": mesh.get_faces().size() / 3 * xforms.size()}

func _build_pebbles(root: Node3D, mat: Material) -> Dictionary:
	var want := int(_f("pebble_count", 2500))
	var s0 := _f("pebble_size", 0.045)
	var bury := _f("pebble_bury", 0.3)
	var pal: Array = [Color(0.40, 0.37, 0.33), Color(0.46, 0.41, 0.35), Color(0.33, 0.32, 0.34), Color(0.50, 0.44, 0.36), Color(0.38, 0.30, 0.22), Color(0.30, 0.28, 0.27)]
	if cfg.has("pebble_palette"):
		pal.clear()
		for cc in cfg.pebble_palette:
			pal.append(_col(cc, Color.GRAY))
	var xforms: Array = []
	var colors: Array = []
	for i in want:
		var s := _sample("pebble", _f("pebble_min_up", 0.8))
		if s.is_empty():
			continue
		var n: Vector3 = s.n
		var size := s0 * lerpf(0.5, 1.6, pow(rng.randf(), 2.0))
		var sy := size * rng.randf_range(0.35, 0.65)
		var tilt := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.35))
		var basis := _align(n) * tilt * Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(size * rng.randf_range(0.85, 1.25), sy, size * rng.randf_range(0.6, 1.0)))
		xforms.append(Transform3D(basis, Vector3(s.w) - n * bury * sy))
		var cc: Color = pal[rng.randi() % pal.size()]
		var k := rng.randf_range(0.9, 1.1)
		colors.append(Color(cc.r * k, cc.g * k, cc.b * k))
	_mmi(root, "GroundPebbles", _pebble_mesh(), xforms, colors, mat)
	return {"count": xforms.size(), "want": want, "triangles": xforms.size() * 18}
