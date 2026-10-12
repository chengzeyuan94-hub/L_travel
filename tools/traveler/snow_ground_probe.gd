extends SceneTree
## 盘橐雪景地表 · 程序化生成探针
##
## 把 Carlos 的「雪景地板·四视图与起伏设计」当规格实现，不当建模订单。
## **新文件，不碰 Codex 正在编辑的任何脚本。**
##
##   godot --path . --script res://tools/traveler/snow_ground_probe.gd -- --out=<前缀> [--no-props]
##
## 尺寸换算：规格表以 1.8m 的人为参照，而小人已定版 0.6375 世界单位，
## 所以系数 = 0.6375 / 1.8 = 0.354 世界单位／概念米。表里每个高度都按这个换。

const M := 0.354            # 世界单位 / 概念米
const CELL := 0.25          # 格边长（世界单位）
const EXTENT := 26.0        # 地表边长（世界单位）

# 冻结机位实测值
const CAM_POS := Vector3(34.5735778808594, 3.96782684326172, 14.9224071502686)
const CAM_TARGET := Vector3(28.3460006713867, 1.49336516857147, 6.19920015335083)
const FOV := 36.0

# 规格表「起伏关系示意」四个区，已换算
const H_MOUND := 2.5 * M    # A 前景雪丘  0.885
const H_PATH_LO := 0.2 * M  # B 行走路径  0.071
const H_PATH_HI := 0.5 * M  # B           0.177
const H_RIDGE_LO := 1.0 * M # C 侧向山脊  0.354
const H_RIDGE_HI := 1.5 * M # C           0.531
const H_FAR_LO := 0.3 * M   # D 远景过渡  0.106
const H_FAR_HI := 0.8 * M   # D           0.283

# 雪色：接近白的三档，靠切面朝向区分。不给雪加色相变化（会显脏）。
const SNOW_TOP := Color(0.965, 0.972, 0.988)     # 朝上受光面
const SNOW_SLOPE := Color(0.862, 0.892, 0.945)   # 斜面
const SNOW_SHADE := Color(0.706, 0.752, 0.861)   # 背光/凹陷，偏冷蓝
const SNOW_PATH := Color(0.826, 0.857, 0.910)    # 压实路径，略灰略蓝

var out_prefix := ""
var with_props := true
var rng := RandomNumberGenerator.new()
var wind := Vector2(0.82, 0.57).normalized()     # 全局风向（xz 平面）
var rock_spots: Array = []                        # 石头位置，地表要在这些点挖窝
var report: Dictionary = {}


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_prefix = a.trim_prefix("--out=")
		elif a == "--no-props":
			with_props = false
	if out_prefix.is_empty():
		push_error("需要 --out=")
		quit(1)
		return
	rng.seed = 20260920
	call_deferred("run")


# ============================================================ 高度场

func _view_basis() -> Array:
	## 沿视线的前向与右向（xz 平面），构图分区按它定，而不是按世界轴。
	var fwd := Vector3(CAM_TARGET.x - CAM_POS.x, 0.0, CAM_TARGET.z - CAM_POS.z).normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	return [fwd, right]


func _drift(p: Vector2, amp: float, spacing: float) -> float:
	## 风堆雪：垂直风向的脊，迎风缓、背风陡。
	## 这是手雕唯一真正买到的东西，用定向函数实现即可。
	var s: float = p.dot(wind) / spacing
	var t: float = p.dot(Vector2(-wind.y, wind.x))
	# 沿横风方向给脊加相位与幅度调制，否则会退化成平行条纹
	# （Carlos 2026-09-16 明令删过农田垄状条纹，这里必须避开同一个坑）
	var phase_jitter: float = 0.34 * sin(t * 0.63) + 0.21 * sin(t * 1.47 + 1.3)
	var amp_mod: float = 0.55 + 0.45 * sin(t * 0.41 + 0.7) * sin(t * 0.93 + 2.1)
	var u: float = fposmod(s + phase_jitter, 1.0)
	# 迎风 0..0.72 缓升，背风 0.72..1 快落
	var h: float
	if u < 0.72:
		h = smoothstep(0.0, 1.0, u / 0.72)
	else:
		h = 1.0 - smoothstep(0.0, 1.0, (u - 0.72) / 0.28) * 0.92
	return h * amp * maxf(amp_mod, 0.0)


func _fbm(p: Vector2, oct: int, freq: float) -> float:
	var v := 0.0
	var a := 1.0
	var f := freq
	var norm := 0.0
	for i in oct:
		v += a * (sin(p.x * f + float(i) * 1.7) * cos(p.y * f * 1.13 + float(i) * 2.3))
		norm += a
		a *= 0.5
		f *= 2.07
	return v / maxf(norm, 1e-6)


func _path_mask(fwd_d: float, right_d: float) -> float:
	## 压实路径：从画面近端通向城门的走廊。返回 0..1 的隶属度。
	## 路径不是直线——概念图里它是一条弧。
	var curve: float = 1.6 * sin(fwd_d * 0.075) - 0.8
	var off: float = absf(right_d - curve)
	var half_w: float = 1.15
	return 1.0 - smoothstep(half_w, half_w + 1.05, off)


func _height(x: float, z: float) -> Dictionary:
	var b := _view_basis()
	var fwd: Vector3 = b[0]
	var right: Vector3 = b[1]
	var rel := Vector3(x - CAM_POS.x, 0.0, z - CAM_POS.z)
	var fd: float = rel.dot(fwd)       # 离相机的视线距离
	var rd: float = rel.dot(right)     # 横向偏移
	var p := Vector2(x, z)

	# 四区的权重按视线距离分配（规格表的 A/B/C/D 就是一张构图）
	var w_mound: float = 1.0 - smoothstep(6.0, 13.0, fd)                    # A 前景
	var w_far: float = smoothstep(19.0, 27.0, fd)                           # D 远景
	var w_mid: float = clampf(1.0 - w_mound - w_far, 0.0, 1.0)              # C 中景侧脊
	var w_path: float = _path_mask(fd, rd)

	var h := 0.0
	# A 前景雪丘：高而宽。注意近于 5.5 单位会被近端景深糊掉，
	# 所以这一带只做大形，不堆细节。
	h += w_mound * (H_MOUND * (0.48 + 0.52 * _fbm(p * 0.30, 2, 1.0)) * 0.5 + 0.5 * H_MOUND) * 0.62
	# C 侧向山脊：中等破碎起伏，靠风堆雪给方向感
	h += w_mid * (H_RIDGE_LO + (H_RIDGE_HI - H_RIDGE_LO) * 0.5) * (0.35 + 0.65 * _fbm(p * 0.55, 3, 1.0) * 0.5 + 0.5)
	h += w_mid * _drift(p, H_RIDGE_LO * 0.62, 1.35)
	# D 远景过渡：低而简
	h += w_far * (H_FAR_LO + (H_FAR_HI - H_FAR_LO) * (0.5 + 0.5 * _fbm(p * 0.22, 2, 1.0)))
	# 全场细节起伏（很小，只为打碎大面）
	h += _drift(p, 0.055, 0.62) * (1.0 - w_path * 0.85)

	# B 行走路径：压平并轻微下沉
	var flat: float = H_PATH_LO + (H_PATH_HI - H_PATH_LO) * (0.5 + 0.5 * _fbm(p * 1.1, 2, 1.0))
	h = lerp(h, flat, w_path * 0.92)

	# 石头脚下的窝：一圈浅凹 + 背风侧堆雪。这是「雪岩结合」三条细节里
	# 地表要负责的那一条，也是防止石头看起来像摆在白纸上的关键。
	var pocket := 0.0
	for spot in rock_spots:
		var c: Vector2 = spot["xz"]
		var r: float = spot["r"]
		var d: float = p.distance_to(c)
		if d > maxf(r * 2.6, CELL * 12.0):
			continue
		# 环的宽度必须 >= 8 个格子，否则 0.25 的格距解析不出平滑落差、会阶梯化（第一版实测）
		var ring: float = maxf(r * 1.9, CELL * 9.0)
		var q: float = clampf(d / ring, 0.0, 1.0)
		# 用 cos 钟形代替 smoothstep，一阶导在两端都为 0，接缝更软
		var bell: float = 0.5 + 0.5 * cos(q * PI)
		var dip: float = -0.26 * r * bell
		var lee: Vector2 = c + wind * r * 1.45
		var dl: float = p.distance_to(lee)
		var lr: float = maxf(r * 1.7, CELL * 8.0)
		var ql: float = clampf(dl / lr, 0.0, 1.0)
		var pile: float = 0.30 * r * (0.5 + 0.5 * cos(ql * PI))
		pocket += dip + pile
	h += pocket

	return {"h": h, "path": w_path, "fd": fd, "rd": rd}


# ============================================================ 网格

func _build_ground() -> Dictionary:
	var n := int(EXTENT / CELL)
	var origin := Vector3(CAM_TARGET.x - EXTENT * 0.5, 0.0, CAM_TARGET.z - EXTENT * 0.5)
	# 先采样高度与路径隶属度
	var hs := []
	var ps := []
	for i in n + 1:
		var row_h := PackedFloat32Array()
		var row_p := PackedFloat32Array()
		for j in n + 1:
			var x: float = origin.x + float(j) * CELL
			var z: float = origin.z + float(i) * CELL
			var r := _height(x, z)
			row_h.append(float(r["h"]))
			row_p.append(float(r["path"]))
		hs.append(row_h)
		ps.append(row_p)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris := 0
	for i in n:
		for j in n:
			var x0: float = origin.x + float(j) * CELL
			var z0: float = origin.z + float(i) * CELL
			var a := Vector3(x0, hs[i][j], z0)
			var b := Vector3(x0 + CELL, hs[i][j + 1], z0)
			var c := Vector3(x0 + CELL, hs[i + 1][j + 1], z0 + CELL)
			var d := Vector3(x0, hs[i + 1][j], z0 + CELL)
			# 对角线方向按格交替，避免出现规则的条纹走向
			var flip: bool = ((i + j) % 2) == 0
			var path_w: float = (ps[i][j] + ps[i][j + 1] + ps[i + 1][j + 1] + ps[i + 1][j]) * 0.25
			if flip:
				_face(st, a, b, c, path_w); _face(st, a, c, d, path_w)
			else:
				_face(st, a, b, d, path_w); _face(st, b, c, d, path_w)
			tris += 2
	var mesh: ArrayMesh = st.commit()
	return {"mesh": mesh, "triangles": tris, "cells": n * n, "cell_u": CELL, "extent_u": EXTENT}


func _face(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, path_w: float) -> void:
	var nrm: Vector3 = (p1 - p0).cross(p2 - p0)
	if nrm.length() < 1e-9:
		return
	nrm = nrm.normalized()
	if nrm.y < 0.0:
		nrm = -nrm
	# 逐面平色，按朝向在三档白之间取：这是雪地唯一有效的读法
	var up: float = clampf(nrm.y, 0.0, 1.0)
	var col: Color
	if up > 0.93:
		col = SNOW_TOP
	elif up > 0.74:
		col = SNOW_SLOPE.lerp(SNOW_TOP, (up - 0.74) / 0.19)
	else:
		col = SNOW_SHADE.lerp(SNOW_SLOPE, clampf(up / 0.74, 0.0, 1.0))
	if path_w > 0.25:
		col = col.lerp(SNOW_PATH, minf(1.0, (path_w - 0.25) / 0.55) * 0.75)
	# 极轻的逐面明度抖动，打碎大面；幅度小到不产生椒盐
	var k: float = 1.0 + rng.randf_range(-0.012, 0.012)
	col = Color(clampf(col.r * k, 0, 1), clampf(col.g * k, 0, 1), clampf(col.b * k, 0, 1))
	for p in [p0, p1, p2]:
		st.set_normal(nrm)
		st.set_color(col)
		st.add_vertex(p)


func _snow_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 0.92
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
	return m


# ============================================================ 摆件

func _plan_rocks() -> void:
	## 石头排布：前景 XL 框架 → 近景 L → 中景 M → 远景 S，高度逐级降低。
	## 城门正前方保持开阔，不放大石头。
	var b := _view_basis()
	var fwd: Vector3 = b[0]
	var right: Vector3 = b[1]
	var tiers := [
		{"tier": "XL", "h": 3.2 * M, "fd": [6.0, 10.0], "rd": 5.0, "n": 5},
		{"tier": "L", "h": 2.4 * M, "fd": [9.0, 15.0], "rd": 7.5, "n": 9},
		{"tier": "M", "h": 1.6 * M, "fd": [14.0, 21.0], "rd": 9.5, "n": 13},
		{"tier": "S", "h": 1.0 * M, "fd": [19.0, 27.0], "rd": 12.0, "n": 16},
	]
	# 规格表要求成组（边缘框架组 / 错落混合组 / 稀疏过渡组），不是均匀撒点。
	# 做法：每档先定几个组心，再在组心周围下 2-4 块大小混合的石头。
	for t in tiers:
		var clusters: int = maxi(2, int(t["n"]) / 3)
		for ci in clusters:
			var cfd: float = rng.randf_range(t["fd"][0], t["fd"][1])
			var crd: float = rng.randf_range(-float(t["rd"]), float(t["rd"]))
			# 边缘框架：XL/L 偏向左右两侧，把组心推出去
			if String(t["tier"]) in ["XL", "L"]:
				var sgn: float = 1.0 if crd >= 0.0 else -1.0
				crd = sgn * maxf(absf(crd), float(t["rd"]) * 0.55)
			# 城门通道留空
			if absf(crd) < 2.2 and cfd > 13.0:
				crd += (2.2 + rng.randf_range(0.8, 2.4)) * (1.0 if crd >= 0.0 else -1.0)
			var members: int = rng.randi_range(2, 4)
			for k in members:
				var spread: float = float(t["h"]) * rng.randf_range(1.1, 3.0)
				var ang: float = rng.randf_range(0.0, TAU)
				var fd: float = cfd + cos(ang) * spread
				var rd: float = crd + sin(ang) * spread
				var wp: Vector3 = CAM_POS + fwd * fd + right * rd
				# 组内大小混合：一块主石 + 若干配石
				var hm: float = float(t["h"]) * (1.0 if k == 0 else rng.randf_range(0.42, 0.72))
				rock_spots.append({"xz": Vector2(wp.x, wp.z), "r": hm * 0.85,
					"tier": t["tier"], "h": hm, "fd": fd, "rd": rd})


func run() -> void:
	_plan_rocks()
	var g := _build_ground()

	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(vp)

	var world := Node3D.new()
	vp.add_child(world)

	var ground := MeshInstance3D.new()
	ground.name = "SnowGround"
	ground.mesh = g["mesh"]
	ground.material_override = _snow_material()
	world.add_child(ground)

	var placed := {"rocks": 0, "trees": 0, "fortress": 0}
	if with_props:
		placed = _place_props(world)

	# 明亮冷雪天：概念图定的不是黄昏
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.23, 0.46, 0.85)
	sm.sky_horizon_color = Color(0.68, 0.82, 0.95)
	sm.sky_curve = 0.14
	sm.ground_bottom_color = Color(0.82, 0.88, 0.95)
	sm.ground_horizon_color = Color(0.88, 0.93, 0.98)
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.62
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# AO 是白对白唯一的解；radius 0.16 是这个世界尺度下验过的值，不是 0.75
	env.ssao_enabled = true
	env.ssao_radius = 0.16
	env.ssao_intensity = 4.6
	env.ssao_power = 1.7
	env.ssao_detail = 0.6
	env.ssao_horizon = 0.05
	env.ssao_light_affect = 0.10
	env.ssil_enabled = true
	env.ssil_radius = 0.6
	env.ssil_intensity = 0.55
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.86, 0.91, 0.98)
	env.fog_density = 1.0
	env.fog_depth_begin = 26.0
	env.fog_depth_end = 150.0
	env.fog_depth_curve = 1.2
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.34
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 0.92
	env.tonemap_white = 1.6
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.06
	env.adjustment_contrast = 1.14
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.97, 0.92)
	sun.light_energy = 2.6
	# 阴影偏冷蓝：雪景里阴影是唯一的色彩信息来源
	sun.shadow_enabled = true
	sun.shadow_blur = 0.9
	sun.shadow_bias = 0.045
	sun.shadow_normal_bias = 0.12
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_split_1 = 0.08
	sun.directional_shadow_max_distance = 70.0
	sun.rotation = Vector3(deg_to_rad(-34.0), deg_to_rad(126.0), 0.0)
	vp.add_child(sun)

	var cam := Camera3D.new()
	cam.fov = FOV
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	vp.add_child(cam)
	cam.make_current()
	cam.global_position = CAM_POS
	cam.look_at(CAM_TARGET, Vector3.UP)

	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = vp.get_texture().get_image()
	var err: int = img.save_png("%s.png" % out_prefix)

	report = {
		"schema": "silkroad.panti-snow-ground-probe.v1",
		"spec_source": "雪景地板·四视图与起伏设计（Carlos 2026-09-20）",
		"units_per_concept_metre": M,
		"zone_heights_u": {"A_mound": H_MOUND, "B_path": [H_PATH_LO, H_PATH_HI],
			"C_ridge": [H_RIDGE_LO, H_RIDGE_HI], "D_far": [H_FAR_LO, H_FAR_HI]},
		"ground": {"triangles": g["triangles"], "cells": g["cells"],
			"cell_u": g["cell_u"], "extent_u": g["extent_u"], "surfaces": 1, "draw_calls": 1},
		"wind_dir_xz": [wind.x, wind.y],
		"rocks_planned": rock_spots.size(),
		"placed": placed,
		"image": "%s.png" % out_prefix, "save_error": err,
		"camera": {"pos": [CAM_POS.x, CAM_POS.y, CAM_POS.z],
			"target": [CAM_TARGET.x, CAM_TARGET.y, CAM_TARGET.z], "fov": FOV},
		"note": "程序化探针。地表逐面平色（三档白按朝向取）+ 压实路径 + 逐石头凹窝；不用 Tripo、不用 Blender。",
	}
	var f := FileAccess.open("%s.json" % out_prefix, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	print("[SNOW] %s err=%d  地表 %d 三角 / %d 格 / 1 draw call  石头 %d  树 %d  城 %d" % [
		"%s.png" % out_prefix, err, int(g["triangles"]), int(g["cells"]),
		int(placed["rocks"]), int(placed["trees"]), int(placed["fortress"])])
	quit(0)


func _place_props(world: Node3D) -> Dictionary:
	var out := {"rocks": 0, "trees": 0, "fortress": 0}
	var b := _view_basis()
	var fwd: Vector3 = b[0]
	var right: Vector3 = b[1]

	# --- 城堡：主角。目标高约 16 概念米 = 5.67 单位；资产归一化高 0.547
	var fort_scene: PackedScene = load("res://assets/traveler/panti/fortress-raw.fbx")
	if fort_scene != null:
		var fort: Node3D = fort_scene.instantiate()
		var s: float = (16.0 * M) / 0.547
		fort.scale = Vector3(s, s, s)
		var fp: Vector3 = CAM_POS + fwd * 22.0 + right * 0.4
		var hr := _height(fp.x, fp.z)
		fort.position = Vector3(fp.x, float(hr["h"]) - 0.05, fp.z)
		fort.rotation.y = -0.62 + PI
		world.add_child(fort)
		out["fortress"] = 1

	# --- 雪松：弧形环绕在城的后方与两侧；前景不放树
	var pine_scene: PackedScene = load("res://assets/traveler/panti/pine-raw.fbx")
	if pine_scene != null:
		var tiers := [
			{"m": 32.0, "fd": [30.0, 44.0], "rd": 26.0, "n": 9},   # XL 远景天际线
			{"m": 32.0, "fd": [14.0, 30.0], "rd": [13.0, 22.0], "n": 6},  # XL 左右边框
			{"m": 32.0, "fd": [8.5, 13.5], "rd": [7.0, 11.0], "n": 5},    # XL 贴近相机的左右巨树（概念图-1 左三分之一）
			{"m": 24.0, "fd": [26.0, 36.0], "rd": 20.0, "n": 8},   # L 中远景
			{"m": 16.0, "fd": [24.0, 31.0], "rd": 15.0, "n": 7},   # M 过渡
			{"m": 10.0, "fd": [25.0, 30.0], "rd": 11.0, "n": 6},   # S 城后过渡，稀疏
		]
		for t in tiers:
			for k in int(t["n"]):
				var fd: float = rng.randf_range(t["fd"][0], t["fd"][1])
				var rd: float
				if t["rd"] is Array:
					rd = rng.randf_range(t["rd"][0], t["rd"][1]) * (1.0 if rng.randf() < 0.5 else -1.0)
				else:
					rd = rng.randf_range(-float(t["rd"]), float(t["rd"]))
				# 不挡主体：城正前方那一段不放树
				if fd < 24.0 and absf(rd) < 6.0:
					continue
				var wp: Vector3 = CAM_POS + fwd * fd + right * rd
				var inst: Node3D = pine_scene.instantiate()
				var sc: float = (float(t["m"]) * M) / 1.0   # 资产归一化高 = 1.0
				sc *= rng.randf_range(0.86, 1.14)
				inst.scale = Vector3(sc, sc, sc)
				var hh := _height(wp.x, wp.z)
				inst.position = Vector3(wp.x, float(hh["h"]) - sc * 0.02, wp.z)
				inst.rotation.y = rng.randf_range(0.0, TAU)
				world.add_child(inst)
				out["trees"] += 1

	# --- 石头：按 _plan_rocks 的点位
	var r1: PackedScene = load("res://assets/traveler/panti/rock01-raw.fbx")
	var r2: PackedScene = load("res://assets/traveler/panti/rock02-raw.fbx")
	for spot in rock_spots:
		var pick: PackedScene = r2 if rng.randf() < 0.55 else r1
		if pick == null:
			continue
		var inst: Node3D = pick.instantiate()
		var norm_h: float = 0.802 if pick == r2 else 0.415
		var sc: float = float(spot["h"]) / norm_h * rng.randf_range(0.85, 1.2)
		inst.scale = Vector3(sc, sc, sc)
		var c: Vector2 = spot["xz"]
		var hh := _height(c.x, c.y)
		inst.position = Vector3(c.x, float(hh["h"]) - float(spot["h"]) * 0.16, c.y)
		inst.rotation.y = rng.randf_range(0.0, TAU)
		world.add_child(inst)
		rock_spots_placed()
		out["rocks"] += 1
	return out


func rock_spots_placed() -> void:
	pass
