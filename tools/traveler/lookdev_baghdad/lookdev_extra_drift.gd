extends RefCounted
## drift：中景沙面上的低多边形「沙脊 / 风积沙垄」几何层（look-dev 探针，不是交付代码）。
##
## 思路：低太阳（仰角 8.5°、逆光）下，平整的大三角沙面只有一种亮度。
## 在上面铺一层细长、带锐利脊线的小沙垄（高 0.02–0.12u），
## 脊顶一条窄帽面受光、朝相机的背风陡面落进阴影，再投一条 6–7 倍高的影子到身前沙面，
## 于是每条沙垄在屏幕上都是「一线亮脊 + 一条暗带」，成排出现就刮出细碎的明暗层次。
## 全部顶点用 ground_surface.height_at 贴地，底边埋 bury_u 以免浮空；平面法线（faceted）。

const MASK_CELL := 0.2

var _viewer: Node3D
var _surface: Object
var _cfg: Dictionary = {}
var _circles: Array = []          # [[Vector2 center, float radius], ...]
var _road: Dictionary = {}        # Vector2i -> true，路面/前景细节占用的格子
var _camera: Camera3D
var _screen: Vector2
var _window: Rect2
var _st: SurfaceTool
var _tris := 0
var _stats := {"rows": 0, "ridges": 0, "ripples": 0, "skip_exclusion": 0, "skip_road": 0, "skip_screen": 0, "skip_region": 0}
var _zmin_used := INF
var _zmax_used := -INF
var _facet_rng := RandomNumberGenerator.new()
var _facet_jitter := 0.0

func build(viewer: Node3D, cfg: Dictionary) -> Dictionary:
	_viewer = viewer
	_cfg = cfg
	_surface = viewer.ground_surface
	_camera = viewer.camera
	_screen = viewer.get_viewport().get_visible_rect().size
	var win: Array = cfg.get("screen_window_uv", [0.22, 0.60, 0.79, 1.0])
	_window = Rect2(Vector2(float(win[0]) * _screen.x, float(win[1]) * _screen.y), Vector2((float(win[2]) - float(win[0])) * _screen.x, (float(win[3]) - float(win[1])) * _screen.y))
	var settings: Dictionary = viewer.settings
	var albedo: Array = settings.ground.albedo
	var base := Color(float(albedo[0]), float(albedo[1]), float(albedo[2]))
	_build_exclusions(settings)
	var road_cells := _build_road_mask()
	var rng := RandomNumberGenerator.new()
	rng.seed = int(cfg.get("seed", 20260923))
	_facet_rng.seed = int(cfg.get("seed", 20260923)) + 77
	_facet_jitter = float(cfg.get("facet_tone_jitter", 0.0))
	_st = SurfaceTool.new()
	_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var t0 := Time.get_ticks_msec()
	# 主沙垄族 + （可选）细沙纹族
	_family(rng, base, cfg.get("main", {}), "ridges")
	if cfg.has("ripples"):
		_family(rng, base, cfg.ripples, "ripples")
	var mesh := _st.commit()
	var node := MeshInstance3D.new()
	node.name = "LookdevDriftRidges"
	node.mesh = mesh
	node.material_override = _material()
	var cast := bool(cfg.get("cast_shadow", true))
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	viewer.world.add_child(node)
	var aabb := mesh.get_aabb() if mesh != null else AABB()
	return {
		"triangles": _tris,
		"vertices": _tris * 3,
		"stats": _stats,
		"road_mask_cells": road_cells,
		"exclusion_circles": _circles.size(),
		"z_range_used": [_zmin_used, _zmax_used],
		"cast_shadow": cast,
		"aabb_world": [aabb.position.x, aabb.position.y, aabb.position.z, aabb.size.x, aabb.size.y, aabb.size.z],
		"build_ms": Time.get_ticks_msec() - t0,
		"normal_mode": "flat per triangle",
		"contact": "every vertex y = ground_surface.height_at(stage x,z) (+crest height, base edges -bury_u)",
	}

# ---------------------------------------------------------------- 禁放区
func _build_exclusions(settings: Dictionary) -> void:
	var pad := float(_cfg.get("exclusion_pad_u", 0.15))
	var sp: Dictionary = settings.supporting_props
	for e in sp.surface_details.get("exclusions", []):
		_circles.append([Vector2(float(e.center[0]), float(e.center[1])), float(e.radius_u) + pad])
	for c in sp.surface_details.get("pebble_clusters", []):
		var r: Array = c.radius
		_circles.append([Vector2(float(c.center[0]), float(c.center[1])), maxf(float(r[0]), float(r[1])) * 0.8])
	for rock in sp.get("rocks", []):
		_circles.append([Vector2(float(rock.position[0]), float(rock.position[2])), float(rock.get("width_u", 0.3)) * 0.6 + 0.1])
	for palm in sp.get("palms", []):
		_circles.append([Vector2(float(palm.position[0]), float(palm.position[2])), 0.32])
	for tuft in sp.get("tufts", []):
		_circles.append([Vector2(float(tuft.position[0]), float(tuft.position[2])), 0.22])
	var fire: Dictionary = sp.get("fire", {})
	if not fire.is_empty():
		_circles.append([Vector2(float(fire.position[0]), float(fire.position[2])), 0.9])
	var tree: Array = settings.tree.stage_position
	_circles.append([Vector2(float(tree[0]), float(tree[2])), float(_cfg.get("tree_radius_u", 1.35))])
	var ch: Array = settings.character.stage_position
	_circles.append([Vector2(float(ch[0]), float(ch[2])), 0.7])
	# 路与营地走廊（构图事实：x −1.5…1.5、z 2…7）
	var corridor: Array = _cfg.get("path_corridor", [-1.7, 1.7, 0.0, 7.2])
	_circles.append(["rect", Rect2(float(corridor[0]), float(corridor[2]), float(corridor[1]) - float(corridor[0]), float(corridor[3]) - float(corridor[2]))])

func _build_road_mask() -> int:
	var root: Node = _viewer.world.find_child("BaghdadForegroundDetails", true, false)
	if root == null:
		return 0
	for item in root.find_children("*", "MeshInstance3D", true, false):
		var mi := item as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var xf := mi.global_transform
		for si in mi.mesh.get_surface_count():
			var arrays: Array = mi.mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx := PackedInt32Array()
			if arrays[Mesh.ARRAY_INDEX] != null:
				idx = arrays[Mesh.ARRAY_INDEX]
			var count := idx.size() if idx.size() > 0 else verts.size()
			var t := 0
			while t + 2 < count:
				var a: Vector3 = xf * verts[idx[t] if idx.size() > 0 else t]
				var b: Vector3 = xf * verts[idx[t + 1] if idx.size() > 0 else t + 1]
				var c: Vector3 = xf * verts[idx[t + 2] if idx.size() > 0 else t + 2]
				# world → stage：x 取反
				var x0 := minf(-a.x, minf(-b.x, -c.x)); var x1 := maxf(-a.x, maxf(-b.x, -c.x))
				var z0 := minf(a.z, minf(b.z, c.z)); var z1 := maxf(a.z, maxf(b.z, c.z))
				for gx in range(int(floor(x0 / MASK_CELL)), int(floor(x1 / MASK_CELL)) + 1):
					for gz in range(int(floor(z0 / MASK_CELL)), int(floor(z1 / MASK_CELL)) + 1):
						_road[Vector2i(gx, gz)] = true
				t += 3
	return _road.size()

func _blocked(p: Vector2) -> int:
	for c in _circles:
		if c[0] is String:
			if (c[1] as Rect2).has_point(p):
				return 1
		elif p.distance_to(c[0]) < float(c[1]):
			return 1
	var g := Vector2i(int(floor(p.x / MASK_CELL)), int(floor(p.y / MASK_CELL)))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			if _road.has(Vector2i(g.x + dx, g.y + dz)):
				return 2
	return 0

func _h(p: Vector2) -> float:
	return float(_surface.height_at(p))

func _on_screen(p: Vector2, y: float) -> bool:
	var w: Vector3 = _viewer.stage_point(Vector3(p.x, y, p.y))
	if _camera.is_position_behind(w):
		return false
	return _window.has_point(_camera.unproject_position(w))

# ---------------------------------------------------------------- 一族沙垄（成排、按风向）
func _family(rng: RandomNumberGenerator, base: Color, f: Dictionary, kind: String) -> void:
	var region: Array = f.get("region", [-10.0, 10.0, 4.4, 24.0])   # x0, x1, z0, z1
	var ang := deg_to_rad(float(f.get("crest_angle_deg", 16.0)))
	var tan0 := Vector2(cos(ang), sin(ang))            # 脊线方向 (x, z)
	var n0 := Vector2(-tan0.y, tan0.x)                 # 行法线，指向远处
	var wind := -n0 if bool(f.get("lee_toward_camera", true)) else n0   # 下风向
	var corners := [Vector2(region[0], region[2]), Vector2(region[1], region[2]), Vector2(region[0], region[3]), Vector2(region[1], region[3])]
	var umin := INF; var umax := -INF; var vmin := INF; var vmax := -INF
	for c in corners:
		umin = minf(umin, c.dot(tan0)); umax = maxf(umax, c.dot(tan0))
		vmin = minf(vmin, c.dot(n0)); vmax = maxf(vmax, c.dot(n0))
	var v := vmin
	while v < vmax:
		var zc := v / cos(ang)
		var tr := _depth_t(zc, f)
		var spacing := lerpf(float(f.get("spacing_near", 1.0)), float(f.get("spacing_far", 0.45)), tr) * rng.randf_range(0.75, 1.25)
		var wob := {"a": minf(float(f.get("wobble_u", 0.3)), spacing * 0.4), "f": rng.randf_range(0.35, 0.7), "p": rng.randf() * TAU, "p2": rng.randf() * TAU}
		var u := umin - rng.randf() * 1.5
		_stats.rows += 1
		while u < umax:
			var mid := tan0 * u + n0 * v
			var t := _depth_t(mid.y, f)
			var length := lerpf(float(f.get("len_near", 2.4)), float(f.get("len_far", 0.8)), t) * rng.randf_range(0.6, 1.4)
			var gap := lerpf(float(f.get("gap_near", 0.7)), float(f.get("gap_far", 0.3)), t) * rng.randf_range(0.25, 1.6)
			if mid.x >= region[0] and mid.x <= region[1] and mid.y >= region[2] and mid.y <= region[3]:
				_ridge(rng, base, f, kind, tan0, n0, wind, u, v, length, wob, t)
			else:
				_stats.skip_region += 1
			u += length + gap
		v += spacing

func _depth_t(z: float, f: Dictionary) -> float:
	var zr: Array = f.get("size_depth", [5.0, 20.0])
	return clampf((z - float(zr[0])) / (float(zr[1]) - float(zr[0])), 0.0, 1.0)

func _ridge(rng: RandomNumberGenerator, base: Color, f: Dictionary, kind: String, tan0: Vector2, n0: Vector2, wind: Vector2, u0: float, v: float, length: float, wob: Dictionary, t: float) -> void:
	if _tris >= int(_cfg.get("max_triangles", 29000)):
		_stats["skip_budget"] = int(_stats.get("skip_budget", 0)) + 1
		return
	var seg_len := float(f.get("seg_len_u", 0.3))
	var n_seg := clampi(int(ceil(length / seg_len)), 3, int(f.get("max_seg", 8)))
	var h := lerpf(float(f.get("h_near", 0.1)), float(f.get("h_far", 0.035)), t) * rng.randf_range(0.7, 1.3)
	var bend := length * rng.randf_range(0.03, 0.12) * float(f.get("crescent", 1.0))
	var shape := {
		"stoss": float(f.get("stoss_ratio", 4.5)) * rng.randf_range(0.8, 1.2),
		"lee": float(f.get("lee_ratio", 1.5)) * rng.randf_range(0.75, 1.3),
		"m_frac": rng.randf_range(0.4, 0.55),
		"m_h": rng.randf_range(0.6, 0.75),
	}
	var jit := float(f.get("crest_jitter_u", 0.0))
	var pts: Array[Vector2] = []
	var ok: Array[bool] = []
	var any_block := 0
	for i in n_seg + 1:
		var s := float(i) / n_seg
		var u := u0 + length * s
		var off := float(wob.a) * (sin(u * float(wob.f) + float(wob.p)) + 0.5 * sin(u * float(wob.f) * 2.7 + float(wob.p2)))
		# 弯月：中段向上风鼓出、两角拖向下风
		var p := tan0 * u + n0 * (v + off) - wind * bend * (1.0 - pow(2.0 * s - 1.0, 2.0))
		if jit > 0.0 and i > 0 and i < n_seg:
			p += Vector2(rng.randf_range(-jit, jit), rng.randf_range(-jit, jit))
		pts.append(p)
		var b := _blocked(p)
		if b == 0:
			b = maxi(_blocked(p + wind * h * float(shape.lee) * 1.2), _blocked(p - wind * h * float(shape.stoss)))
		ok.append(b == 0)
		any_block = maxi(any_block, b)
	# 碰到禁放区就截断成若干段（每段至少 2 个分段），不整条丢掉
	var run: Array[Vector2] = []
	var emitted := false
	for i in pts.size() + 1:
		if i < pts.size() and ok[i]:
			run.append(pts[i])
			continue
		if run.size() >= 3:
			var frac := float(run.size() - 1) / float(n_seg)
			if _emit(rng, base, f, run, h * lerpf(0.75, 1.0, frac), bend, wind, shape):
				emitted = true
		run.clear()
	if any_block == 1:
		_stats.skip_exclusion += 1
	elif any_block == 2:
		_stats.skip_road += 1
	if emitted:
		if kind == "ripples":
			_stats.ripples += 1
		else:
			_stats.ridges += 1

func _emit(rng: RandomNumberGenerator, base: Color, f: Dictionary, pts: Array[Vector2], h: float, bend: float, wind: Vector2, shape: Dictionary) -> bool:
	var n_seg := pts.size() - 1
	var hs: PackedFloat32Array = []
	for i in pts.size():
		var s := float(i) / n_seg
		hs.append(h * pow(sin(PI * s), 0.6) * rng.randf_range(0.85, 1.15) if i > 0 and i < n_seg else 0.0)
	# 屏幕可见检查（任一脊点落进拱门开口窗）
	var seen := false
	for i in pts.size():
		if _on_screen(pts[i], _h(pts[i]) + hs[i]):
			seen = true
			break
	if not seen:
		_stats.skip_screen += 1
		return false
	var bury := float(f.get("bury_u", 0.004))
	# 颜色：同沙色系，逐条略偏亮/偏红
	var kb := rng.randf_range(float(f.get("tone_lo", 0.97)), float(f.get("tone_hi", 1.05)))
	var red := rng.randf_range(0.0, float(f.get("red_shift", 0.04)))
	var c_stoss := Color(base.r * kb * (1.0 + red * 0.5), base.g * kb, base.b * kb * (1.0 - red))
	var c_stoss_hi := c_stoss.lerp(Color(1, 0.9, 0.7), 0.06)
	var cap_boost := float(f.get("cap_boost", 1.12))
	var c_cap := Color(minf(base.r * cap_boost * 1.02, 1.0), minf(base.g * cap_boost, 1.0), minf(base.b * cap_boost * 0.96, 1.0))
	var lee_tone := float(f.get("lee_tone", 1.0))
	var c_lee := Color(minf(base.r * kb * lee_tone * (1.0 + red), 1.0), base.g * kb * lee_tone * (0.97 - red * 0.5), base.b * kb * lee_tone * (0.92 - red))
	var foot := float(f.get("lee_foot_tone", 0.0))
	var c_foot := c_lee.darkened(foot) if foot > 0.0 else c_lee
	var lee_split := float(f.get("lee_split", 0.0))   # >0：背风面拆成上陡下缓两片
	var sections: Array = []
	for i in pts.size():
		var tangent: Vector2 = (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
		var w := Vector2(-tangent.y, tangent.x)
		if w.dot(wind) < 0.0:
			w = -w
		var hp: float = hs[i]
		var taper := 0.35 + 0.65 * sqrt(clampf(hp / maxf(h, 0.0001), 0.0, 1.0))
		var ws := maxf(h * float(shape.stoss) * taper, 0.015)
		var wl := maxf(maxf(hp, h * 0.25) * float(shape.lee), 0.008)
		var cap := maxf(hp * float(f.get("cap_ratio", 0.35)), 0.004)
		var p: Vector2 = pts[i]
		var ground := _h(p)
		var sp := p - w * ws
		var mp := p - w * ws * float(shape.m_frac)
		var kp := p + w * cap
		var top := ground + hp if hp > 0.0 else ground - bury
		var sec := [
			_v3(sp, _h(sp) - bury),
			_v3(mp, _h(mp) + (hp * float(shape.m_h) if hp > 0.0 else -bury)),
			_v3(p, top),
			_v3(kp, _h(kp) + (hp * float(f.get("cap_drop", 0.9)) if hp > 0.0 else -bury)),
		]
		if lee_split > 0.0:
			var jp := p + w * (cap + wl * 0.45)
			sec.append(_v3(jp, _h(jp) + (hp * float(f.get("cap_drop", 0.9)) * lee_split if hp > 0.0 else -bury)))
			var lp2 := p + w * (cap + wl * 0.45 + wl * float(f.get("foot_ratio", 1.6)))
			sec.append(_v3(lp2, _h(lp2) - bury))
		else:
			var lp := p + w * (wl + cap)
			sec.append(_v3(lp, _h(lp) - bury))
		sections.append(sec)
		_zmin_used = minf(_zmin_used, p.y); _zmax_used = maxf(_zmax_used, p.y)
	var colors := [c_stoss, c_stoss_hi, c_cap, c_lee, c_foot]
	var strips: int = (sections[0] as Array).size() - 1
	for i in sections.size() - 1:
		var a: Array = sections[i]
		var b: Array = sections[i + 1]
		for k in strips:
			var flip := (i + k) % 2 == 0
			if flip:
				_tri(a[k], a[k + 1], b[k + 1], colors[k])
				_tri(a[k], b[k + 1], b[k], colors[k])
			else:
				_tri(a[k], a[k + 1], b[k], colors[k])
				_tri(a[k + 1], b[k + 1], b[k], colors[k])
	return true
func _v3(p: Vector2, y: float) -> Vector3:
	return _viewer.stage_point(Vector3(p.x, y, p.y))

func _tri(a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-14:
		return
	# 与地面网格同一绕序约定：叉积朝上（地面 CULL_DISABLED、渲染正确）
	if n.y < 0.0:
		var tmp := b; b = c; c = tmp
		n = -n
	n = n.normalized()
	if _facet_jitter > 0.0:
		# 逐面明度抖动：低多边形的「马赛克颗粒」
		var k := 1.0 + _facet_rng.randf_range(-_facet_jitter, _facet_jitter)
		color = Color(minf(color.r * k, 1.0), minf(color.g * k, 1.0), minf(color.b * k, 1.0))
	for p in [a, b, c]:
		_st.set_color(color)
		_st.set_normal(n)
		_st.add_vertex(p)
	_tris += 1

func _material() -> Material:
	var ground := _viewer.world.find_child("AuthoredDesertDunes", true, false) as MeshInstance3D
	var mat: StandardMaterial3D
	if ground != null and ground.material_override is StandardMaterial3D:
		mat = (ground.material_override as StandardMaterial3D).duplicate()
	else:
		mat = StandardMaterial3D.new()
		mat.roughness = 1.0
		mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color.WHITE
	mat.albedo_texture = null
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	return mat
