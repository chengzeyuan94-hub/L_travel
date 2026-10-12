extends SceneTree
## 巴格达 · 三角预算实测探针（2026-09-21）
##
## 起因：总监在起始 prompt 里给生命树定了「减到 3.5–4.5 万」的目标，
## 依据是「107 万三角超过盘橐整帧 424,631 图元」。Carlos 驳回：
## 「你盲目减面干吊？轴心的生命之树需要大量细节」。
##
## 他是对的，而且那个依据站不住：
##   - 424,631 是盘橐**清晨**那一帧的 rendered_primitives，不是场景三角上限；
##     同一场景**深夜**渲了 887,758 图元，P95 仍只有 15.953ms（预算 33.3ms）。
##   - 今天实测夜景开销大头是夜空遮罩把整帧渲两遍的 6.561ms（占 54.7%），
##     是填充率问题；三角数在本项目里从未被实测为瓶颈。
##   - 逆光剪影是减面最不能碰的情况：树冠边缘正对全画最亮处，
##     碎叶边界一丢就塌成圆锥团块。
##
## 所以这份探针只回答一个问题：**原样 574,514 三角的生命树，在巴格达这一档机位下要多少帧时间。**
## 不预设结论。
##
##   godot --path . --script res://tools/traveler/baghdad_tri_budget.gd -- --out=<前缀> [--variant=full|no-tree|no-arch|bare]
##
## 口径与盘橐定版一致：1920×1080 / 关 VSync / Engine.max_fps=0 / 预热 120 帧 / 采样 180 帧。

const IMG := Vector2i(1920, 1080)
const WARMUP := 120
const SAMPLES := 180

# L 叔身高 1.0 = 0.6375 世界单位（character-style-spec.md 已定版）
const C := 0.6375
const H_TREE := 12.0 * C        # 7.6500
const H_ARCH_OPEN := 4.0 * C    # 2.5500
const H_SKYLINE := 6.0 * C      # 3.8250

const ASSETS := {
	"arch": "res://assets/traveler/baghdad/ancient+stone+arch+3d+model.fbx",
	"tree": "res://assets/traveler/baghdad/tree+3d+model.fbx",
	"mosque": "res://assets/traveler/baghdad/desert+mosque+3d+model.fbx",
}

var out_prefix := ""
var variant := "full"
var report: Dictionary = {}


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_prefix = a.trim_prefix("--out=")
		elif a.begins_with("--variant="):
			variant = a.trim_prefix("--variant=")
	if out_prefix.is_empty():
		push_error("需要 --out=")
		quit(1)
		return
	# 测性能必须关 VSync，否则每个配置都读成 16.667ms（本项目踩过）
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	call_deferred("run")


func _load(key: String) -> Dictionary:
	var packed: PackedScene = load(ASSETS[key])
	if packed == null:
		return {}
	var root: Node3D = packed.instantiate()
	var tris := 0
	var surfaces := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node
		if mi.mesh == null:
			continue
		surfaces += mi.mesh.get_surface_count()
		for si in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(si)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if idx.size() > 0:
				tris += idx.size() / 3
			else:
				tris += int(arr[Mesh.ARRAY_VERTEX].size() / 3)
	# AABB 必须在节点**入树之后**才能取 global_transform（今天已经踩过两次这个错）。
	# 这里改成手动沿父链累乘 local transform，不依赖入树状态。
	var aabb := AABB()
	var first := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi2: MeshInstance3D = node
		if mi2.mesh == null:
			continue
		var xf: Transform3D = mi2.transform
		var parent: Node = mi2.get_parent()
		while parent is Node3D and parent != root:
			xf = (parent as Node3D).transform * xf
			parent = parent.get_parent()
		var b: AABB = xf * mi2.mesh.get_aabb()
		aabb = b if first else aabb.merge(b)
		first = false
	return {"node": root, "triangles": tris, "surfaces": surfaces, "aabb": aabb}


func run() -> void:
	var vp := SubViewport.new()
	vp.size = IMG
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(vp)

	var world := Node3D.new()
	vp.add_child(world)

	var placed := {}

	# ---- 生命树：按契约 7.65 单位高，原样不减面
	if variant != "no-tree" and variant != "bare":
		var t := _load("tree")
		if not t.is_empty():
			var n: Node3D = t["node"]
			var ab: AABB = t["aabb"]
			var s: float = H_TREE / maxf(ab.size.y, 1e-6)
			n.scale = Vector3(s, s, s)
			n.position = Vector3(1.6, -ab.position.y * s, 9.0)
			world.add_child(n)
			placed["tree"] = {"triangles": t["triangles"], "surfaces": t["surfaces"],
				"scale": s, "world_height": H_TREE,
				"aabb": [ab.size.x, ab.size.y, ab.size.z]}

	# ---- 拱门：按契约券洞净高 2.55 单位。这里先用包围盒高近似（探针只测开销，不定最终摆位）
	if variant != "no-arch" and variant != "bare":
		var a := _load("arch")
		if not a.is_empty():
			var n2: Node3D = a["node"]
			var ab2: AABB = a["aabb"]
			var s2: float = (H_ARCH_OPEN / 0.72) / maxf(ab2.size.y, 1e-6)   # 券洞约占资产高七成
			n2.scale = Vector3(s2, s2, s2)
			n2.position = Vector3(0.0, -ab2.position.y * s2, -0.4)
			world.add_child(n2)
			placed["arch"] = {"triangles": a["triangles"], "surfaces": a["surfaces"],
				"scale": s2, "aabb": [ab2.size.x, ab2.size.y, ab2.size.z]}

	# ---- 远景清真寺：6 份拼成天际线带，原样不减面（看它到底贵不贵）
	if variant == "full":
		var m := _load("mosque")
		if not m.is_empty():
			var proto: Node3D = m["node"]
			var abm: AABB = m["aabb"]
			var sm: float = H_SKYLINE / maxf(abm.size.y, 1e-6)
			var n_sky := 6
			for i in n_sky:
				var inst: Node3D = proto.duplicate() if i > 0 else proto
				inst.scale = Vector3(sm, sm, sm)
				inst.position = Vector3(14.0 + float(i) * 7.0, -abm.position.y * sm, 46.0 + float(i % 2) * 4.0)
				inst.rotation.y = float(i) * 0.7
				world.add_child(inst)
			placed["mosque"] = {"triangles_each": m["triangles"], "count": n_sky,
				"triangles_total": int(m["triangles"]) * n_sky, "surfaces": m["surfaces"]}

	# ---- 地面：一块简单沙色平面，探针不做地形
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(140.0, 160.0)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.784, 0.612, 0.408)
	gm.roughness = 1.0
	gm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	pm.material = gm
	ground.mesh = pm
	ground.position = Vector3(0.0, 0.0, 40.0)
	# 低太阳下地表不要投自己的影子：盘橐实测 |dy| 0.02196 → 关掉后 0.00017，全是 acne
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(ground)

	_setup_look(vp)

	# ---- 机位：巴格达一档（近地、太阳进画）。探针用近似值，最终机位由 S3 定。
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.fov = 40.0
	cam.near = 0.05
	cam.far = 500.0
	vp.add_child(cam)
	cam.make_current()
	cam.position = Vector3(0.0, 0.42, -1.4)
	cam.look_at(Vector3(1.2, 1.5, 12.0))

	for i in WARMUP:
		await process_frame
	await RenderingServer.frame_post_draw

	var prim := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)

	var ms: Array = []
	for i in SAMPLES:
		var t0 := Time.get_ticks_usec()
		await process_frame
		ms.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	ms.sort()
	var p := func(q: float) -> float: return float(ms[clampi(int(float(ms.size() - 1) * q), 0, ms.size() - 1)])

	await RenderingServer.frame_post_draw
	var err: int = vp.get_texture().get_image().save_png("%s.png" % out_prefix)

	report = {
		"schema": "silkroad.baghdad-tri-budget.v1",
		"question": "原样不减面的生命树（574,514 三角）在巴格达一档机位下要多少帧时间",
		"variant": variant,
		"discipline": {"resolution": [IMG.x, IMG.y], "vsync": "disabled",
			"engine_max_fps": 0, "warmup_frames": WARMUP, "samples": SAMPLES,
			"msaa": "4x", "note": "与盘橐定版口径一致"},
		"placed": placed,
		"measured": {
			"primitives_in_frame": prim,
			"draw_calls_in_frame": calls,
			"frame_ms": {"p50": snappedf(p.call(0.50), 0.001), "p95": snappedf(p.call(0.95), 0.001),
				"p99": snappedf(p.call(0.99), 0.001), "min": snappedf(ms[0], 0.001),
				"max": snappedf(ms[ms.size() - 1], 0.001)},
		},
		"baseline_panti_frozen": {
			"morning": {"draw_calls": 45, "p50": 5.619, "p95": 11.468},
			"midnight": {"draw_calls": 90, "p50": 11.796, "p95": 15.953,
				"primitives": 887758,
				"note": "深夜的 draw call 与图元恰为清晨两倍，因夜空遮罩把整帧渲了两遍"},
			"budget_p95_ms": 33.3,
		},
		"image": "%s.png" % out_prefix, "save_error": err,
	}
	var f := FileAccess.open("%s.json" % out_prefix, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()

	print("[TRI-BUDGET] variant=%s  图元 %d  draw call %d  P50 %.3fms  P95 %.3fms  P99 %.3fms  (预算 33.3ms)" % [
		variant, prim, calls, p.call(0.50), p.call(0.95), p.call(0.99)])
	for k in placed:
		print("    %s: %s" % [k, JSON.stringify(placed[k])])
	quit(0)


func _setup_look(vp: SubViewport) -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	# 日落：太阳在地平线上，天顶偏冷紫，地平线橙金
	sm.sky_top_color = Color(0.353, 0.408, 0.643)
	sm.sky_horizon_color = Color(0.976, 0.722, 0.376)
	sm.ground_horizon_color = Color(0.827, 0.612, 0.396)
	sm.ground_bottom_color = Color(0.478, 0.373, 0.294)
	sm.sun_angle_max = 6.0
	sm.sun_curve = 0.08
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.55
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ssao_enabled = true
	env.ssao_radius = 0.35
	env.ssao_intensity = 2.4
	env.ssil_enabled = false
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.937, 0.729, 0.478)
	env.fog_density = 0.7
	env.fog_depth_begin = 22.0
	env.fog_depth_end = 90.0
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.30
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.15
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.6
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.12
	env.adjustment_contrast = 1.06
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)

	# 太阳贴着地平线，从画面右后方来 → 树与人物逆光成剪影
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.741, 0.42)
	sun.light_energy = 3.2
	sun.shadow_enabled = true
	sun.shadow_blur = 1.1
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 0.10
	sun.directional_shadow_max_distance = 70.0
	sun.rotation = Vector3(deg_to_rad(-4.0), deg_to_rad(196.0), 0.0)
	vp.add_child(sun)
