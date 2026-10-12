extends RefCounted
## 巴格达旅人·中景沙面「颗粒感」导演探针（key: scatter，2026-09-23）。
##
## 只加东西、不改任何现有网格或道具。三层贴地散布，全部 cast_shadow 关闭：
##   1) 沙斑  —— 一张合并的贴地网格：每块是 5–7 边的扁平不规则多边形，
##               每个顶点单独用 ground_surface.height_at 采样再抬高（>=0.002u），
##               颜色取沙色的深浅变化，法线在地面法线上轻微扰动出平面明暗（低多边形硬边）。
##   2) 碎石/沙粒 —— MultiMesh：顶点偏心的 10 面小多面体（露出地面约 5 个面），
##               随机非等比缩放与倾斜；石子偏棕灰，沙粒是略深/略浅的沙色。
##   3) 干草丛 —— MultiMesh：6 片细三角（正反两面各一份，法线都朝上半球），逆光透光。
## 成团：若干随机团簇（高斯落点）+ 两层噪声调制的稀疏底撒；
## 远近：近处稀而大、中景密而小；只在相机看得见的楔形区内撒（拱门柱后面不撒）。

const OCC_CELL := 0.12

var viewer: Node3D
var cfg: Dictionary = {}
var rng := RandomNumberGenerator.new()
var noise_big := FastNoiseLite.new()
var noise_fine := FastNoiseLite.new()
var occupancy: Dictionary = {}
var circles: Array = []
var screen_size := Vector2(1920, 1080)
var sand := Color(0.84, 0.67, 0.45)
var zmin := 3.8
var zmax := 23.0
var wedge_k := 0.40
var wedge_m := 0.4
var sx_min := 470.0
var sx_max := 1450.0
var road_half := 1.5
var ground_ref: Material = null
var road_z1 := 7.0
var reject := {"domain": 0, "circle": 0, "paving": 0, "screen": 0, "density": 0}
var _pv := PackedVector3Array()
var _pn := PackedVector3Array()
var _pc := PackedColorArray()

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

func _f(key: String, fallback: float) -> float:
	return float(cfg.get(key, fallback))

func _col(value: Variant, fallback: Color) -> Color:
	if value is Array and (value as Array).size() >= 3:
		return Color(float(value[0]), float(value[1]), float(value[2]))
	return fallback

func build(v: Node3D, c: Dictionary) -> Dictionary:
	viewer = v
	cfg = c
	var t0 := Time.get_ticks_msec()
	var seed_value := int(_f("seed", 20260923))
	rng.seed = seed_value
	noise_big.seed = seed_value + 7
	noise_big.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise_big.frequency = _f("clump_freq", 0.28)
	noise_fine.seed = seed_value + 13
	noise_fine.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise_fine.frequency = _f("clump_fine_freq", 1.1)
	zmin = _f("z_min", 3.8)
	zmax = _f("z_max", 23.0)
	wedge_k = _f("wedge_k", 0.40)
	wedge_m = _f("wedge_m", 0.4)
	sx_min = _f("screen_x_min", 470.0)
	sx_max = _f("screen_x_max", 1450.0)
	screen_size = viewer.get_viewport().get_visible_rect().size
	var albedo: Array = viewer.settings.ground.albedo
	sand = Color(float(albedo[0]), float(albedo[1]), float(albedo[2]))
	var paving_info := _build_occupancy()
	_build_circles()
	var root := Node3D.new()
	root.name = "LookdevScatter"
	viewer.world.add_child(root)
	var ground_mat: Material = null
	if viewer.ground != null:
		ground_mat = viewer.ground.get_active_material(0)
	ground_ref = ground_mat
	var diffuse_mode := BaseMaterial3D.DIFFUSE_BURLEY
	var ground_spec := {}
	if ground_mat is BaseMaterial3D:
		var g := ground_mat as BaseMaterial3D
		diffuse_mode = g.diffuse_mode
		ground_spec = {"specular_mode": g.specular_mode, "roughness": g.roughness, "metallic_specular": g.metallic_specular}
	var clusters := _make_clusters()
	var patches := _build_patches(root, clusters, diffuse_mode)
	var pebbles := _build_pebbles(root, clusters, diffuse_mode)
	var grass := _build_grass(root, clusters, diffuse_mode)
	var total := int(patches.count) + int(pebbles.count) + int(grass.count)
	return {
		"elements_total": total,
		"triangles_total": int(patches.triangles) + int(pebbles.triangles) + int(grass.triangles),
		"new_geometry_instances": 3,
		"cast_shadow": false,
		"clusters": clusters.size(),
		"patches": patches, "pebbles": pebbles, "grass": grass,
		"paving_occupancy": paving_info,
		"exclusion_circles": circles.size(),
		"rejections": reject,
		"ground_diffuse_mode": diffuse_mode,
		"ground_specular_copied": ground_spec,
		"ground_material_class": ground_mat.get_class() if ground_mat != null else "none",
		"build_ms": Time.get_ticks_msec() - t0,
	}

# ---------------------------------------------------------------- 禁放：路面占位 + 禁放圆
func _build_occupancy() -> Dictionary:
	var names: Array = []
	var zlo := INF
	var zhi := -INF
	var tri_count := 0
	var dilate := int(_f("paving_dilate_cells", 2))
	for item in viewer.world.find_children("*", "MeshInstance3D", true, false):
		var node := item as MeshInstance3D
		var nm := str(node.name)
		if not (nm.begins_with("StonePaving") or nm.begins_with("FineGravel") or nm.begins_with("Paving") or nm.begins_with("Road")):
			continue
		names.append(nm)
		var xf := node.global_transform
		for s in node.mesh.get_surface_count():
			var arrays: Array = node.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx := PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] != null:
				idx = arrays[Mesh.ARRAY_INDEX]
			var n := idx.size() if not idx.is_empty() else verts.size()
			for t in range(0, n, 3):
				var lo := Vector2(INF, INF)
				var hi := Vector2(-INF, -INF)
				for k in 3:
					var vi: int = idx[t + k] if not idx.is_empty() else t + k
					var w: Vector3 = xf * verts[vi]
					var p := Vector2(-w.x, w.z)
					lo = lo.min(p)
					hi = hi.max(p)
				zlo = minf(zlo, lo.y)
				zhi = maxf(zhi, hi.y)
				tri_count += 1
				for gx in range(floori(lo.x / OCC_CELL) - dilate, floori(hi.x / OCC_CELL) + dilate + 1):
					for gz in range(floori(lo.y / OCC_CELL) - dilate, floori(hi.y / OCC_CELL) + dilate + 1):
						occupancy[Vector2i(gx, gz)] = true
	return {"meshes": names, "triangles": tri_count, "cells": occupancy.size(), "stage_z_range": [zlo, zhi]}

func _build_circles() -> void:
	var sp: Dictionary = viewer.settings.get("supporting_props", {})
	var sd: Dictionary = sp.get("surface_details", {})
	var pad := _f("exclusion_pad_u", 0.15)
	for e in sd.get("exclusions", []):
		circles.append([Vector2(float(e.center[0]), float(e.center[1])), float(e.radius_u) + pad])
	for r in sp.get("rocks", []):
		circles.append([Vector2(float(r.position[0]), float(r.position[2])), float(r.get("width_u", 0.4)) * 0.75 + pad])
	for p in sp.get("palms", []):
		circles.append([Vector2(float(p.position[0]), float(p.position[2])), 0.28])
	var tp: Array = viewer.settings.tree.stage_position
	circles.append([Vector2(float(tp[0]), float(tp[2])), _f("tree_trunk_radius_u", 1.0)])
	# 路 / 营火走廊（任务卡：x −1.5…1.5、z 2…7）用矩形，叠加在路面实际三角面占位之上。
	road_half = _f("road_half_width_u", 1.5)
	road_z1 = _f("road_z_end", 7.0)

# ---------------------------------------------------------------- 采样
func _ground_h(p: Vector2) -> float:
	return float(viewer.ground_surface.height_at(p))

func _stage_normal(p: Vector2) -> Vector3:
	var e := 0.06
	var dx := (_ground_h(p + Vector2(e, 0)) - _ground_h(p - Vector2(e, 0))) / (2.0 * e)
	var dz := (_ground_h(p + Vector2(0, e)) - _ground_h(p - Vector2(0, e))) / (2.0 * e)
	return Vector3(-dx, 1.0, -dz).normalized()

func _world_normal(p: Vector2) -> Vector3:
	var n := _stage_normal(p)
	return Vector3(-n.x, n.y, n.z)

func _in_wedge(p: Vector2) -> bool:
	return p.y >= zmin and p.y <= zmax and absf(p.x) <= wedge_k * p.y + wedge_m

func _ok(p: Vector2) -> bool:
	if not _in_wedge(p):
		reject["domain"] += 1
		return false
	if absf(p.x) <= road_half and p.y >= 2.0 and p.y <= road_z1:
		reject["circle"] += 1
		return false
	for c in circles:
		if p.distance_squared_to(c[0]) < c[1] * c[1]:
			reject["circle"] += 1
			return false
	if occupancy.has(Vector2i(floori(p.x / OCC_CELL), floori(p.y / OCC_CELL))):
		reject["paving"] += 1
		return false
	var wp: Vector3 = viewer.stage_point(Vector3(p.x, _ground_h(p), p.y))
	if viewer.camera.is_position_behind(wp):
		reject["screen"] += 1
		return false
	var px: Vector2 = viewer.camera.unproject_position(wp)
	if px.x < sx_min or px.x > sx_max or px.y < 0.0 or px.y > screen_size.y + 10.0:
		reject["screen"] += 1
		return false
	return true

func _wedge_sample() -> Vector2:
	# 面积均匀：z 的 pdf ∝ 楔形宽度
	var wmax := wedge_k * zmax + wedge_m
	while true:
		var z := rng.randf_range(zmin, zmax)
		if rng.randf() * wmax <= wedge_k * z + wedge_m:
			var half := wedge_k * z + wedge_m
			return Vector2(rng.randf_range(-half, half), z)
	return Vector2.ZERO

func _depth_t(z: float) -> float:
	return smoothstep(zmin, _f("far_size_z", 16.0), z)

func _ramp(z: float) -> float:
	# 近处稀、中景密，景深之后略稀
	var near := lerpf(_f("near_density", 0.35), 1.0, smoothstep(zmin, _f("mid_density_z", 9.0), z))
	var far := lerpf(1.0, _f("far_density", 0.4), smoothstep(_f("far_fade_z", 15.0), zmax, z))
	return near * far

func _clump(p: Vector2) -> float:
	var n := 0.65 * noise_big.get_noise_2d(p.x, p.y) + 0.35 * noise_fine.get_noise_2d(p.x, p.y)
	return smoothstep(_f("clump_lo", -0.15), _f("clump_hi", 0.45), n)

func _make_clusters() -> Array:
	var out: Array = []
	var want := int(_f("cluster_count", 70))
	var tries := 0
	while out.size() < want and tries < want * 80:
		tries += 1
		var p := _wedge_sample()
		if rng.randf() > _ramp(p.y):
			continue
		if not _ok(p):
			continue
		var close := false
		for c in out:
			if (c.c as Vector2).distance_to(p) < _f("cluster_min_gap_u", 0.9):
				close = true
				break
		if close:
			continue
		var s := rng.randf_range(0.3, 1.0) * (0.7 + 0.035 * p.y)
		out.append({"c": p, "rx": s, "rz": s * rng.randf_range(0.45, 0.8), "ang": rng.randf_range(-0.5, 0.5), "w": rng.randf_range(0.5, 1.6)})
	return out

func _pick_cluster(clusters: Array) -> Dictionary:
	var total := 0.0
	for c in clusters:
		total += float(c.w)
	var r := rng.randf() * total
	for c in clusters:
		r -= float(c.w)
		if r <= 0.0:
			return c
	return clusters[-1]

## 返回 [点, 离团簇中心的归一化距离(背景点=1)]；失败返回空数组
func _sample_point(clusters: Array, cluster_share: float, spread: float) -> Array:
	for attempt in 40:
		if not clusters.is_empty() and rng.randf() < cluster_share:
			var c := _pick_cluster(clusters)
			var local := Vector2(rng.randfn(0.0, float(c.rx) * spread), rng.randfn(0.0, float(c.rz) * spread))
			var p: Vector2 = (c.c as Vector2) + local.rotated(float(c.ang))
			if _ok(p):
				var d := Vector2(local.x / float(c.rx), local.y / float(c.rz)).length()
				return [p, clampf(d * 0.5, 0.0, 1.0)]
		else:
			var p := _wedge_sample()
			if rng.randf() > _ramp(p.y) * _clump(p):
				reject["density"] += 1
				continue
			if _ok(p):
				return [p, 1.0]
	return []

# ---------------------------------------------------------------- 1) 沙斑（贴地拼网格）
func _build_patches(root: Node3D, clusters: Array, diffuse_mode: int) -> Dictionary:
	var want := int(_f("patch_count", 2800))
	_buf_reset()
	var dark_col := _col(cfg.get("patch_dark"), sand * Color(0.88, 0.87, 0.85))
	var light_col := _col(cfg.get("patch_light"), sand.lerp(Color(1.0, 0.9, 0.72), 0.32))
	var lift0 := _f("patch_lift_u", 0.002)
	var lift_k := _f("patch_lift_per_u", 0.00025)
	var count := 0
	var dark_count := 0
	for i in want:
		var s := _sample_point(clusters, _f("patch_cluster_share", 0.45), 0.7)
		if s.is_empty():
			continue
		var p: Vector2 = s[0]
		if p.y > _f("patch_z_max", 18.0):
			continue
		var t := _depth_t(p.y)
		var r := lerpf(_f("patch_r_near", 0.07), _f("patch_r_far", 0.14), t) * rng.randf_range(0.6, 1.5)
		var rx := r * rng.randf_range(1.3, 2.4)
		var rz := r * rng.randf_range(0.55, 1.0)
		var yaw := rng.randf_range(-0.4, 0.4)
		var in_cluster := float(s[1]) < 1.0
		var is_dark := rng.randf() < (_f("patch_dark_share_cluster", 0.65) if in_cluster else _f("patch_dark_share", 0.45))
		var base := dark_col if is_dark else light_col
		var k := rng.randf_range(0.95, 1.05)
		var colr := Color(base.r * k, base.g * k, base.b * k)
		if is_dark:
			dark_count += 1
		var lift := lift0 + lift_k * p.y
		var sides := rng.randi_range(5, 7)
		var ring: Array[Vector2] = []
		for j in sides:
			var a := TAU * (float(j) + rng.randf_range(-0.25, 0.25)) / sides
			var jr := rng.randf_range(0.7, 1.1)
			ring.append(p + Vector2(cos(a) * rx * jr, sin(a) * rz * jr).rotated(yaw))
		var ctr: Vector3 = viewer.stage_point(Vector3(p.x, _ground_h(p) + lift, p.y))
		for j in sides:
			var q0: Vector2 = ring[j]
			var q1: Vector2 = ring[(j + 1) % sides]
			# 每个小三角取它自己质心处的地面法线：跨过地面折痕的沙斑也跟着地面分面走
			var tn := _world_normal((p + q0 + q1) / 3.0)
			var w0: Vector3 = viewer.stage_point(Vector3(q0.x, _ground_h(q0) + lift, q0.y))
			var w1: Vector3 = viewer.stage_point(Vector3(q1.x, _ground_h(q1) + lift, q1.y))
			_tri_ground(ctr, w0, w1, tn, colr)
		count += 1
	var mesh := ArrayMesh.new()
	var patch_tris := _pv.size() / 3
	if count > 0:
		mesh = _buf_mesh()
		mesh.surface_set_material(0, _ground_like_material())
	var node := MeshInstance3D.new()
	node.name = "ScatterSandPatches"
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(node)
	return {"count": count, "dark": dark_count, "light": count - dark_count, "triangles": patch_tris, "lift_u": [lift0 + lift_k * zmin, lift0 + lift_k * zmax]}

## 沙斑必须和地面「同一种」受光：地面网格在相机看来是背面（X 镜像后逆时针）、材质双面，
## Godot 对双面材质的背面片元会翻转法线——地面的明暗就是按这个翻转后的法线算的
## （逆光下朝相机的沙丘迎面反而受光，这正是已定稿的画面）。所以沙斑照抄：同样的绕序、
## 同样存「朝上」的面法线、同一份地面材质（只把反照率换成顶点色）。
## 早先按「正确」法线做的沙斑在受光沙面上一律发紫发暗，就是这个差异。
func _tri_ground(a: Vector3, b: Vector3, c: Vector3, n: Vector3, colr: Color) -> void:
	if (c - a).cross(b - a).dot(n) > 0.0:
		var tmp := b
		b = c
		c = tmp
	for q in [a, b, c]:
		_pv.append(q)
		_pn.append(n)
		_pc.append(colr)

func _ground_like_material() -> Material:
	if ground_ref is StandardMaterial3D:
		var m := (ground_ref as StandardMaterial3D).duplicate() as StandardMaterial3D
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.albedo_color = Color.WHITE
		m.albedo_texture = null
		return m
	var fallback := _material(false)
	fallback.cull_mode = BaseMaterial3D.CULL_DISABLED
	return fallback

## 顺时针为正面（Godot 约定）：保证 (c-a)×(b-a) 与期望法线同向
func _tri_out(a: Vector3, b: Vector3, c: Vector3, n: Vector3, colr: Color) -> void:
	if (c - a).cross(b - a).dot(n) < 0.0:
		var tmp := b
		b = c
		c = tmp
	for q in [a, b, c]:
		_pv.append(q)
		_pn.append(n)
		_pc.append(colr)

## 光照响应照抄地面最终材质（_apply_lowpoly_materials 之后的 diffuse / specular / roughness），
## 否则逆光下地面的 GGX 前向高光会让散布物显得发灰发紫。
func _material(backlight: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.roughness = 1.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	if ground_ref is BaseMaterial3D:
		var g := ground_ref as BaseMaterial3D
		m.roughness = g.roughness
		m.specular_mode = g.specular_mode
		m.diffuse_mode = g.diffuse_mode
		m.metallic_specular = g.metallic_specular
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.albedo_color = Color.WHITE
	m.metallic = 0.0
	m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.cull_mode = BaseMaterial3D.CULL_BACK
	if backlight:
		m.backlight_enabled = true
		m.backlight = _col(cfg.get("grass_backlight"), Color(0.42, 0.31, 0.14))
	return m

# ---------------------------------------------------------------- 2) 碎石 / 沙粒
func _pebble_mesh() -> ArrayMesh:
	# 平顶碎块：底环 5 点 + 错位顶环 5 点（高度抖动 → 顶面 3 个小面各自受光）+ 埋地底尖。
	# 18 个面，露出地面的是 10 个侧面 + 3 个顶面。
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
	var bottom := Vector3(0.0, 0.0, 0.0)
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
		var centroid := (a + b + c) / 3.0
		var n := (c - a).cross(b - a).normalized()
		if n.dot(centroid - center) < 0.0:
			n = -n
		_tri_out(a, b, c, n, Color.WHITE)
	return _buf_mesh()

func _build_pebbles(root: Node3D, clusters: Array, diffuse_mode: int) -> Dictionary:
	var want := int(_f("pebble_count", 9000))
	var stone_palette: Array[Color] = [Color(0.62, 0.46, 0.33), Color(0.55, 0.42, 0.32), Color(0.68, 0.53, 0.38), Color(0.52, 0.41, 0.33), Color(0.60, 0.50, 0.40), Color(0.64, 0.45, 0.31)]
	if cfg.has("stone_palette"):
		stone_palette.clear()
		for cc in cfg.stone_palette:
			stone_palette.append(_col(cc, Color.GRAY))
	var stone_share := _f("stone_share", 0.45)
	var s_near := _f("pebble_size_near", 0.065)
	var s_far := _f("pebble_size_far", 0.03)
	var bury := _f("pebble_bury", 0.28)
	var xforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var stones := 0
	var size_min := INF
	var size_max := 0.0
	var zhist := {}
	for i in want:
		var s := _sample_point(clusters, _f("pebble_cluster_share", 0.62), 0.55)
		if s.is_empty():
			continue
		var p: Vector2 = s[0]
		var d: float = s[1]
		var t := _depth_t(p.y)
		var size := lerpf(s_near, s_far, t) * lerpf(0.55, _f("pebble_size_max_factor", 1.45), pow(rng.randf(), 2.2))
		if d < 1.0:
			size *= lerpf(1.35, 0.85, d)
		var is_stone := rng.randf() < stone_share
		var sy := size * (rng.randf_range(0.35, 0.6) if is_stone else rng.randf_range(0.22, 0.38))
		var sx := size * rng.randf_range(0.85, 1.25)
		var sz := size * rng.randf_range(0.6, 1.0)
		var n := _world_normal(p)
		var tilt := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.35))
		var basis := Basis(Quaternion(Vector3.UP, n)) * tilt * Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(sx, sy, sz))
		var origin: Vector3 = viewer.stage_point(Vector3(p.x, _ground_h(p), p.y)) - n * (bury * sy)
		xforms.append(Transform3D(basis, origin))
		var colr: Color
		if is_stone:
			colr = stone_palette[rng.randi() % stone_palette.size()]
			stones += 1
		else:
			var k := rng.randf_range(0.74, 0.9) if rng.randf() < _f("grain_dark_share", 0.5) else rng.randf_range(1.08, 1.18)
			colr = Color(minf(sand.r * k, 1.0), minf(sand.g * k, 1.0), minf(sand.b * k, 1.0))
		var j := rng.randf_range(0.94, 1.06)
		colors.append(Color(colr.r * j, colr.g * j, colr.b * j))
		size_min = minf(size_min, size)
		size_max = maxf(size_max, size)
		var bin := int(floor(p.y / 2.0)) * 2
		zhist[bin] = int(zhist.get(bin, 0)) + 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _pebble_mesh()
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colors[i])
	var node := MultiMeshInstance3D.new()
	node.name = "ScatterPebbles"
	node.multimesh = mm
	node.material_override = _material(false)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(node)
	return {"count": xforms.size(), "stones": stones, "grains": xforms.size() - stones, "triangles": xforms.size() * 18, "size_u": [size_min, size_max], "z_histogram_2u": zhist}

# ---------------------------------------------------------------- 3) 干草丛
func _grass_mesh() -> ArrayMesh:
	var r := RandomNumberGenerator.new()
	r.seed = 9191
	_buf_reset()
	var base_col := _col(cfg.get("grass_base"), Color(0.45, 0.37, 0.24))
	var tip_col := _col(cfg.get("grass_tip"), Color(0.86, 0.74, 0.46))
	var blades := int(_f("grass_blades", 6))
	for i in blades:
		var yaw := TAU * (float(i) + r.randf_range(-0.3, 0.3)) / blades
		var dir := Vector3(cos(yaw), 0.0, sin(yaw))
		var perp := Vector3(-dir.z, 0.0, dir.x)
		var lean := r.randf_range(0.2, 0.75)
		var h := r.randf_range(0.6, 1.0)
		var w := r.randf_range(0.07, 0.11)
		var b0 := dir * 0.06 + perp * w * 0.5
		var b1 := dir * 0.06 - perp * w * 0.5
		var tip := dir * (0.06 + sin(lean) * h) + Vector3.UP * cos(lean) * h + perp * r.randf_range(-0.05, 0.05)
		var fn := (b1 - b0).cross(tip - b0).normalized()
		for side in [1.0, -1.0]:
			var n: Vector3 = (fn * side * 0.7 + Vector3.UP * 0.3).normalized()
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

func _build_grass(root: Node3D, clusters: Array, diffuse_mode: int) -> Dictionary:
	var want := int(_f("grass_count", 600))
	var h_near := _f("grass_h_near", 0.11)
	var h_far := _f("grass_h_far", 0.055)
	var xforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for i in want:
		var s := _sample_point(clusters, _f("grass_cluster_share", 0.5), 0.8)
		if s.is_empty():
			continue
		var p: Vector2 = s[0]
		var t := _depth_t(p.y)
		var h := lerpf(h_near, h_far, t) * rng.randf_range(0.65, 1.35)
		var wd := h * rng.randf_range(0.8, 1.4)
		var n := _world_normal(p).lerp(Vector3.UP, 0.5).normalized()
		var basis := Basis(Quaternion(Vector3.UP, n)) * Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(wd, h, wd))
		var origin: Vector3 = viewer.stage_point(Vector3(p.x, _ground_h(p) - 0.01 * h, p.y))
		xforms.append(Transform3D(basis, origin))
		var k := rng.randf_range(0.85, 1.1)
		var olive := rng.randf() < 0.25
		colors.append(Color(0.86 * k, 0.9 * k, 0.62 * k) if olive else Color(k, k, k))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _grass_mesh()
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colors[i])
	var node := MultiMeshInstance3D.new()
	node.name = "ScatterDryGrass"
	node.multimesh = mm
	node.material_override = _material(true)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	root.add_child(node)
	var tris := mm.mesh.get_faces().size() / 3 * xforms.size()
	return {"count": xforms.size(), "triangles": tris, "height_u": [h_far * 0.65, h_near * 1.35]}
