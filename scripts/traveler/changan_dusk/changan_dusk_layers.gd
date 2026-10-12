extends RefCounted
## 长安旅人 · 日暮光影图层（TASK-CHANGAN-DUSK-001，2026-09-24 转正）。
## 画面照 Carlos 2026-09-23 认可的探针 k_merge_c（看板 docs/reports/traveler-changan-dusk-20260923/changan_dusk_after.png）逐项搬过来，
## 数值全部在 data/traveler/look_presets.json 的 scenes.changan.dusk.layers（键名照探针 variant）。机位不动，只作用于长安的日暮。
##
## 由 traveler_lookdev.gd 在长安（selected == "changan"）时 install()，之后每次 apply_period_mix(t) 调 set_mix(t)：
##   t = 0（白天）：什么都不挂——材质换回 atlas_surface.gdshader、金边代理隐藏、补光隐藏、散布隐藏，画面与改动前逐像素一致；
##   0 < t ≤ 1：换到 atlas_surface_dusk.gdshader，金边 / 雪山晚霞 / 反光 / 地面 / 人物金边全部按 t 淡入（t = 1 与探针逐项相同）。
## 图层：
##   surface  地表着色器：太阳单独 wrap、暗部反光、灯下反光、琉璃瓦高光（atlas_surface_dusk.gdshader，uniform 按 dusk_mix 淡入）
##   rim      金边：dusk_rim_edge.gdshader 屏幕空间深度边（近景 atlas 几何、佛窟山崖、远景雪山）+ 人物菲涅尔边（dusk_rim_fresnel）
##            探针把金边 pass 挂在共享材质的 next_pass 上，整片大陆（远处城市、所有植被瓦片）都会再画一遍（+570 万三角形），
##            而探针自己的 cull_dist 会把离相机 30 u 以外的实例整个退化掉、24 u 以外的像素全丢弃——那些几何从来不出边。
##            正式版只给能出边的几何建"金边代理"（同网格、同变换、同实例数据，材质 = 金边 pass），判定条件与着色器相同，画面一致。
##   snow     雪山晚霞：只照雪山的同向暖光（可视层 1<<19）+ 雪面粉色柔光 pass（dusk_snow_sheen）
##   bounce   反光：地表着色器的反光项 + 佛窟山崖两盏只照山崖的弱反光灯（可视层 1<<16）+ 人物腿脚暖反光小灯；SSIL 在 dusk params
##   ground   地面：地形材质的秋天色斑 / 土块 / 颗粒 / 碎叶斑 + 离线烘好的落叶 / 干草 / 碎石散布（ground_scatter_bake.gd）
## 旅人模式可视层登记（VisualInstance3D.layers / Light3D.light_cull_mask）：
##   1<<16 佛窟山崖反光灯（本文件，bounce.cliff_rig.layer）   1<<17 人物补光 CHARACTER_LIGHT_LAYER（character_controller.gd）
##   1<<19 远景雪山晚霞暖光（本文件，rim.massif_key.layer_bit）
##   character_controller 里的 1<<18 GROUND_LAYER / 1<<19 OBSTACLE_LAYER 是物理碰撞层，不是可视层，不冲突。
##
## 对照开关（只给证据截图用）：--changan-dusk-off=light,rim,snow,bounce,ground,clouds（逗号分隔，可多选），
## 被关掉的层回到改动前（layers.previous 里记着改动前的数值）。
const DUSK_SHADER_PATH := "res://shaders/traveler/atlas_surface_dusk.gdshader"
const DUSK_GLAZE_SHADER_PATH := "res://shaders/traveler/atlas_surface_dusk_glaze.gdshader"
const DUSK_GROUND_SHADER_PATH := "res://shaders/traveler/atlas_surface_dusk_ground.gdshader"
const BASE_SHADER_SUFFIX := "atlas_surface.gdshader"
const RIM_EDGE_PATH := "res://shaders/traveler/dusk_rim_edge.gdshader"
const RIM_FRESNEL_PATH := "res://shaders/traveler/dusk_rim_fresnel.gdshader"
const SNOW_SHEEN_PATH := "res://shaders/traveler/dusk_snow_sheen.gdshader"
const DRIVER_PATH := "res://scripts/traveler/changan_dusk/changan_dusk_driver.gd"
const BAKE_PATH := "res://scripts/traveler/changan_dusk/ground_scatter_bake.gd"
const WIND_KEYS := ["wind_amp", "wind_stiff", "wind_gust", "wind_dir", "anim_t", "base_color", "brightness"]
const EDGE_SKIP_KEYS := ["kind", "root", "match", "path", "mode", "exclude", "cull_exempt", "use_vertex_color", "max_aspect", "margin_u"]
const OFF_ARG := "--changan-dusk-off="

var host: Node3D
var world: Node3D
var cfg: Dictionary = {}
var off: Array[String] = []
var started := false
var stopped := false
var active := false
var mix := 0.0
var pending_mix := 0.0
var driver: Node
var layer_root: Node3D
var report: Dictionary = {}

# surface
var base_shader: Shader
var dusk_shader: Shader            # 通用变体
var dusk_shader_of: Dictionary = {}  # 地表材质 → 日暮着色器变体（地形用 ground，寺庙 Atlas_solid 用 glaze，其余通用）
var surface_mats: Array[ShaderMaterial] = []
var terrain_mats: Array[ShaderMaterial] = []
var dusk_mix_mats: Array[ShaderMaterial] = []   # 所有要写 dusk_mix / sun_dir_world 的地表材质（含散布材质）
# rim
var rim_pairs: Array = []        # [[主材质 ShaderMaterial, 金边 pass ShaderMaterial]]：driver 每帧同步风动参数
var rim_proxies: Array = []      # [[代理 GeometryInstance3D, 原几何 GeometryInstance3D]]
var rim_proxy_root: Node3D
var fade_params: Array = []      # [[ShaderMaterial, 参数名, t=1 时的值]]：淡入淡出时按 t 缩放
var sun_dir_mats: Array[ShaderMaterial] = []    # 需要 sun_dir_world 的 pass 材质
var material_swaps: Array = []   # [[MeshInstance3D, 表面序号（-1 = material_override）, 原材质, 日暮材质]]
var char_specs: Array = []
var char_passes: Array = []      # [[BaseMaterial3D, 金边 pass]]
var char_done := false
# snow / bounce lights
var alpenglow: DirectionalLight3D
var alpenglow_energy := 0.0
var massif_node: VisualInstance3D
var massif_bit := 0
var cliff_meshes: Array[VisualInstance3D] = []
var cliff_bit := 0
var cliff_lights: Array = []     # [[DirectionalLight3D, t=1 时的能量]]
var char_light_spec: Dictionary = {}
var char_light: OmniLight3D
var court := Vector3.ZERO
# ground
var scatter_root: Node3D
var scatter_mms: Array[MultiMesh] = []
var scatter_mat: ShaderMaterial
# clouds（只在 --changan-dusk-off=clouds 时用：把日暮云改回旧配色）
var cloud_off_done := false

## traveler_lookdev.configure 在建 lk 之前调用：按对照开关把 dusk params 退回改动前（只给证据截图用）。
## 返回日暮太阳颜色（没有覆盖时返回 fallback）。
static func dusk_param_overrides(layers_cfg: Dictionary, dusk_lk: Dictionary, sun_color: Color) -> Color:
	var switches := _parse_off()
	if switches.is_empty():
		return sun_color
	var prev: Dictionary = layers_cfg.get("previous", {})
	var prev_params: Dictionary = prev.get("params", {})
	var groups: Dictionary = prev.get("param_groups", {})
	for layer in switches:
		for key in groups.get(layer, []):
			if prev_params.has(key) and dusk_lk.has(key):
				dusk_lk[key] = prev_params[key]
	if switches.has("light") and prev.has("sun_color"):
		var c: Array = prev.sun_color
		return Color(float(c[0]), float(c[1]), float(c[2]))
	return sun_color

static func _parse_off() -> Array[String]:
	var result: Array[String] = []
	for arg in preload("res://scripts/traveler/traveler_launch.gd").user_args():
		if arg.begins_with(OFF_ARG):
			for item in arg.trim_prefix(OFF_ARG).split(",", false):
				result.append(item.strip_edges())
	return result

func install(profile: RefCounted, layers_cfg: Dictionary) -> void:
	# 不持有 profile 本身（它持有本对象，互相引用会让两者在退出时泄漏）
	host = profile.host
	world = profile.world
	cfg = layers_cfg
	off = _parse_off()
	var t0 := Time.get_ticks_msec()
	layer_root = Node3D.new()
	layer_root.name = "ChangAnDuskLayers"
	world.add_child(layer_root)
	report = {"source": str(cfg.get("source", "")), "off": off.duplicate()}
	_collect_surface()
	if preload("res://scripts/traveler/traveler_launch.gd").user_args().has("--bake-changan-dusk-scatter"):
		_bake_scatter()
	# 顺序与探针 overlay 相同：地表参数 → 反光（院心 / 琉璃瓦 / 山崖灯）→ 地面（地形参数 + 散布材质 = 地形材质复制）→ 金边 → 雪山（柔光接在雪山金边 pass 之后）
	report["surface"] = _install_surface()
	report["bounce"] = _install_bounce() if not off.has("bounce") else "off"
	report["ground"] = _install_ground() if not off.has("ground") else "off"
	report["rim"] = _install_rim() if not off.has("rim") else "off"
	_link_scatter_rim()
	report["snow"] = _install_snow() if not off.has("snow") else "off"
	report["surface"]["variants"] = _pick_variants()
	report["install_ms"] = Time.get_ticks_msec() - t0
	driver = load(DRIVER_PATH).new()
	driver.name = "ChangAnDuskDriver"
	driver.set("layers", self)
	driver.process_priority = 1000   # 在 MotionDirector 写完 anim_t / wind_gust 之后再同步到金边 pass
	host.add_child(driver)
	world.tree_exiting.connect(driver.stop)
	# 首次生效推迟到 atlas_viewer._ready 结束之后：MotionDirector.configure 按"着色器路径以 atlas_surface.gdshader 结尾"收风动材质，
	# 必须在换到日暮着色器之前收完，否则日暮开场的树不会动。
	driver.call_deferred("start")
	print("CHANGAN_DUSK_LAYERS ", JSON.stringify(report))

func start() -> void:
	if stopped:
		return
	started = true
	set_mix(pending_mix)

## 世界节点要被释放时（截图结束 / 换场景）：不再动任何节点。
func stop() -> void:
	stopped = true
	started = false

## traveler_lookdev.apply_period_mix 每次调用（开场一次、日暮切换时每帧一次）。
func set_mix(t: float) -> void:
	pending_mix = clampf(t, 0.0, 1.0)
	if not started:
		return
	mix = pending_mix
	if mix > 0.0 and not active:
		_activate()
	elif mix <= 0.0 and active:
		_deactivate()
	if active:
		_apply_mix()

func evidence() -> Dictionary:
	var e := report.duplicate(true)
	e["active"] = active
	e["mix"] = mix
	e["rim_proxies"] = rim_proxies.size()
	e["character_rim_surfaces"] = char_passes.size()
	e["character_bounce_light"] = char_light != null
	if scatter_root != null:
		var counts: Array = []
		for mm in scatter_mms:
			var n := mm.instance_count if mm.visible_instance_count < 0 else mm.visible_instance_count
			counts.append(n if scatter_root.visible else 0)
		e["scatter_visible_instances"] = counts
	return e

# ---------------------------------------------------------------- 取值小工具（与探针相同的类型转换）
static func _color(v: Variant) -> Variant:
	if v is Array:
		var a: Array = v
		if a.size() == 2:
			return Vector2(float(a[0]), float(a[1]))
		if a.size() >= 3:
			return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	return v

static func _vector(v: Variant) -> Variant:
	if v is Array:
		var a: Array = v
		if a.size() == 2:
			return Vector2(float(a[0]), float(a[1]))
		if a.size() == 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
		if a.size() >= 4:
			return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
	return v

func _sun_dir() -> Vector3:
	return (host.sun as DirectionalLight3D).global_basis.z.normalized()

# ---------------------------------------------------------------- surface
func _collect_surface() -> void:
	for m in host.material_list:
		var sm := m as ShaderMaterial
		if sm == null or sm.shader == null or not sm.shader.resource_path.ends_with(BASE_SHADER_SUFFIX):
			continue
		if base_shader == null:
			base_shader = sm.shader
		surface_mats.append(sm)
	var terrain: Node = world.get_node_or_null("Terrain64")
	if terrain != null:
		for item in terrain.find_children("*", "MeshInstance3D", true, false):
			var mi := item as MeshInstance3D
			if mi.mesh == null:
				continue
			for s in mi.mesh.get_surface_count():
				var m := mi.get_active_material(s) as ShaderMaterial
				if m != null and surface_mats.has(m) and not terrain_mats.has(m):
					terrain_mats.append(m)

func _install_surface() -> Dictionary:
	dusk_shader = load(DUSK_SHADER_PATH)
	var u: Dictionary = cfg.get("surface", {})
	for sm in surface_mats:
		for k in u.keys():
			sm.set_shader_parameter(k, _color(u[k]))
		if off.has("light"):
			sm.set_shader_parameter("sun_wrap", -1.0)
		if off.has("bounce"):
			for k in ["bounce_strength", "bounce_floor", "lamp_bounce_strength", "glaze_sky_strength", "glaze_sun_spec", "glaze_gold_spec"]:
				sm.set_shader_parameter(k, 0.0)
		dusk_mix_mats.append(sm)
	return {"materials": surface_mats.size(), "terrain_materials": terrain_mats.size(), "keys": u.size(), "shader": DUSK_SHADER_PATH}

## 每个地表材质用哪个日暮着色器变体：只有地形需要地面细节、只有打开了 glaze_enable 的材质（寺庙所在的 Atlas_solid）需要琉璃瓦。
func _pick_variants() -> Dictionary:
	var ground: Shader = load(DUSK_GROUND_SHADER_PATH)
	var glaze: Shader = load(DUSK_GLAZE_SHADER_PATH)
	var counts := {"ground": 0, "glaze": 0, "base": 0}
	for sm in surface_mats:
		var g: Variant = sm.get_shader_parameter("glaze_enable")
		if terrain_mats.has(sm) and not off.has("ground"):
			dusk_shader_of[sm] = ground
			counts.ground += 1
		elif g != null and float(g) > 0.5:
			dusk_shader_of[sm] = glaze
			counts.glaze += 1
		else:
			dusk_shader_of[sm] = dusk_shader
			counts.base += 1
	return counts

func _activate() -> void:
	active = true
	for sm in surface_mats:
		sm.shader = dusk_shader_of.get(sm, dusk_shader)
	for p in rim_proxies:
		(p[0] as GeometryInstance3D).visible = (p[1] as GeometryInstance3D).is_visible_in_tree()
	for s in material_swaps:
		_set_material(s[0], int(s[1]), s[3])
	if massif_node != null and massif_bit != 0:
		massif_node.layers = massif_node.layers | massif_bit
	for mi in cliff_meshes:
		mi.layers = mi.layers | cliff_bit
	if alpenglow != null:
		alpenglow.visible = true
	for l in cliff_lights:
		(l[0] as Light3D).visible = true
	if char_light != null:
		char_light.visible = true
	if scatter_root != null:
		scatter_root.visible = true
	for p in char_passes:
		(p[0] as BaseMaterial3D).next_pass = p[1]
	if off.has("clouds") and not cloud_off_done:
		_clouds_previous()

func _deactivate() -> void:
	active = false
	for sm in surface_mats:
		sm.shader = base_shader
	for p in rim_proxies:
		(p[0] as GeometryInstance3D).visible = false
	for s in material_swaps:
		_set_material(s[0], int(s[1]), s[2])
	if massif_node != null and massif_bit != 0:
		massif_node.layers = massif_node.layers & ~massif_bit
	for mi in cliff_meshes:
		mi.layers = mi.layers & ~cliff_bit
	if alpenglow != null:
		alpenglow.visible = false
	for l in cliff_lights:
		(l[0] as Light3D).visible = false
	if char_light != null:
		char_light.visible = false
	if scatter_root != null:
		scatter_root.visible = false
	for p in char_passes:
		(p[0] as BaseMaterial3D).next_pass = null

func _apply_mix() -> void:
	var sun_dir := _sun_dir()
	for sm in dusk_mix_mats:
		sm.set_shader_parameter("dusk_mix", mix)
		sm.set_shader_parameter("sun_dir_world", sun_dir)
	for pm in sun_dir_mats:
		pm.set_shader_parameter("sun_dir_world", sun_dir)
	for f in fade_params:
		var full: float = f[2]
		(f[0] as ShaderMaterial).set_shader_parameter(str(f[1]), full if mix >= 1.0 else full * mix)
	if alpenglow != null:
		alpenglow.light_energy = alpenglow_energy if mix >= 1.0 else alpenglow_energy * mix
		alpenglow.global_basis = (host.sun as DirectionalLight3D).global_basis
	for l in cliff_lights:
		var full_energy: float = l[1]
		(l[0] as Light3D).light_energy = full_energy if mix >= 1.0 else full_energy * mix
	if char_light != null:
		var e := float(char_light_spec.get("energy", 0.8))
		char_light.light_energy = e if mix >= 1.0 else e * mix
	for mm in scatter_mms:
		# 散布按实例顺序（采样顺序本身是空间随机的）逐步出现：t = 1 全部显示
		mm.visible_instance_count = -1 if mix >= 1.0 else int(floor(float(mm.instance_count) * mix))

func _set_material(mi: MeshInstance3D, surface: int, m: Material) -> void:
	if surface < 0:
		mi.material_override = m
	else:
		mi.set_surface_override_material(surface, m)

# ---------------------------------------------------------------- rim
func _make_pass(shader: Shader, spec: Dictionary, mode: String) -> ShaderMaterial:
	# 与探针 changan_extra_rim.gd::_make 相同：spec 里的键直接当 uniform（color → rim_tint / rim_color；fresnel 的 intensity / power → rim_*）
	var pm := ShaderMaterial.new()
	pm.shader = shader
	pm.set_shader_parameter("sun_dir_world", _sun_dir())
	for k in spec.keys():
		if k in EDGE_SKIP_KEYS:
			continue
		var pname: String = k
		if k == "color":
			pname = "rim_tint" if mode == "edge" else "rim_color"
		elif mode != "edge" and k in ["intensity", "power"]:
			pname = "rim_" + k
		var v: Variant = spec[k]
		if v is Array:
			var a: Array = v
			v = Color(float(a[0]), float(a[1]), float(a[2])) if a.size() >= 3 else Vector2(float(a[0]), float(a[1]))
		pm.set_shader_parameter(pname, v)
	var strength_key := "rim_strength" if mode == "edge" else "rim_intensity"
	var full: Variant = pm.get_shader_parameter(strength_key)
	fade_params.append([pm, strength_key, float(full) if full != null else (1.5 if mode == "edge" else 1.2)])
	sun_dir_mats.append(pm)
	return pm

func _install_rim() -> Dictionary:
	var rim_cfg: Dictionary = cfg.get("rim", {})
	var edge_shader: Shader = load(RIM_EDGE_PATH)
	var out := {}
	for spec in rim_cfg.get("targets", []):
		if str(spec.get("kind", "")) == "atlas":
			out["atlas"] = _install_atlas_rim(spec, edge_shader)
		elif str(spec.get("root", "world")) == "character":
			char_specs.append(spec)
			out["character:" + str(spec.get("match", ""))] = "deferred"
		else:
			out[str(spec.get("path", "world"))] = _install_node_edge(spec, edge_shader)
	return out

## 近景 atlas 几何的金边代理（替代探针"挂在共享材质 next_pass 上、整片大陆再画一遍"）。只给可能出边的实例建代理，判定与
## dusk_rim_edge.gdshader 的结果一一对应，所以画面不变：
##   1. 普通材质：实例原点离相机 > cull_dist 时着色器把整个实例退化掉 → 跳过（cull_exempt 的地形不做这一条）；
##   2. fade_min = 0 时视深 > fade_end 的像素 fade = 0、全部 discard → 包围球整个在 fade_end 之外的实例跳过；
##   3. 包围球整个在冻结机位的视锥之外 → 跳过。横向按最宽 21:9（max_aspect 2.4）算，窗口比截图宽也不会漏；
##      包围球半径另加 margin_u（默认 0.5 u，覆盖风动摆幅）。
## 机位冻结（motion_params._measured.traveler_camera），所以这张代理表在安装时算一次即可。
func _install_atlas_rim(spec: Dictionary, edge_shader: Shader) -> Dictionary:
	var excl: Array = spec.get("exclude", [])
	var exempt_names: Array = spec.get("cull_exempt", [])
	var cull_dist := float(spec.get("cull_dist", 1000000.0))
	var pm_of: Dictionary = {}
	var exempt_of: Dictionary = {}
	var names: Array = []
	var skipped: Array = []
	for m in host.material_list:
		var sm := m as ShaderMaterial
		if sm == null:
			continue
		var nm := str(sm.resource_name)
		var skip := false
		for e in excl:
			if nm.contains(str(e)):
				skip = true
		if skip:
			skipped.append(nm)
			continue
		var pm := _make_pass(edge_shader, spec, "edge")
		var exempt := false
		for e in exempt_names:
			if nm.contains(str(e)):
				exempt = true
		if exempt:
			pm.set_shader_parameter("cull_dist", 1000000.0)
		for k in WIND_KEYS:
			var v: Variant = sm.get_shader_parameter(k)
			if v != null:
				pm.set_shader_parameter(k, v)
		pm_of[sm] = pm
		exempt_of[sm] = exempt
		rim_pairs.append([sm, pm])
		names.append(nm)
	if rim_proxy_root == null:
		rim_proxy_root = Node3D.new()
		rim_proxy_root.name = "RimProxies"
		layer_root.add_child(rim_proxy_root)
	var cam := host.camera as Camera3D
	var view := {"pos": cam.global_position, "fwd": -cam.global_basis.z, "right": cam.global_basis.x, "up": cam.global_basis.y,
		"tan_v": tan(deg_to_rad(cam.fov) * 0.5), "max_aspect": float(spec.get("max_aspect", 2.4)), "near": cam.near,
		"depth_limit": float(spec.get("fade_end", 1000000.0)) if float(spec.get("fade_min", 0.35)) <= 0.0 else INF,
		"margin": float(spec.get("margin_u", 0.5)), "cull_dist": cull_dist}
	var skip_material := _null_pass()
	var stats := {"mesh_proxies": 0, "multimesh_proxies": 0, "instances_kept": 0, "instances_total": 0, "meshes_considered": 0, "mixed_surfaces": 0}
	for item in world.find_children("*", "GeometryInstance3D", true, false):
		var gi := item as GeometryInstance3D
		if layer_root.is_ancestor_of(gi) or not gi.is_visible_in_tree():
			continue
		if gi is MeshInstance3D:
			_mesh_proxy(gi as MeshInstance3D, pm_of, exempt_of, view, skip_material, stats)
		elif gi is MultiMeshInstance3D:
			_multimesh_proxy(gi as MultiMeshInstance3D, pm_of, exempt_of, view, skip_material, stats)
	stats["materials"] = names.size()
	stats["names"] = names
	stats["skipped"] = skipped
	stats["proxies"] = rim_proxies.size()
	return stats

## 包围球（世界坐标）能不能画出金边像素：见 _install_atlas_rim 的第 2、3 条。
static func _rim_sphere_visible(center: Vector3, radius: float, view: Dictionary) -> bool:
	var rel: Vector3 = center - (view.pos as Vector3)
	var r: float = radius + float(view.margin)
	var depth: float = rel.dot(view.fwd)
	if depth - r > float(view.depth_limit) or depth + r < float(view.near):
		return false
	var x: float = rel.dot(view.right)
	var y: float = rel.dot(view.up)
	var tv: float = float(view.tan_v)
	var th: float = tv * float(view.max_aspect)
	if (absf(y) - depth * tv) / sqrt(1.0 + tv * tv) > r:
		return false
	if (absf(x) - depth * th) / sqrt(1.0 + th * th) > r:
		return false
	return true

func _null_pass() -> ShaderMaterial:
	# 混合网格里不出金边的表面：顶点全部落到裁剪体外，不进光栅（实际长安场景里没有这种表面，只是兜底）
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode unshaded, depth_draw_never, blend_add;\nvoid vertex() { POSITION = vec4(2.0, 2.0, 2.0, 1.0); }\nvoid fragment() { ALBEDO = vec3(0.0); }\n"
	var m := ShaderMaterial.new()
	m.shader = sh
	return m

func _copy_instance_settings(proxy: GeometryInstance3D, src: GeometryInstance3D) -> void:
	proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	proxy.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	proxy.layers = src.layers
	proxy.extra_cull_margin = src.extra_cull_margin
	proxy.custom_aabb = src.custom_aabb
	proxy.visibility_range_begin = src.visibility_range_begin
	proxy.visibility_range_begin_margin = src.visibility_range_begin_margin
	proxy.visibility_range_end = src.visibility_range_end
	proxy.visibility_range_end_margin = src.visibility_range_end_margin
	proxy.visibility_range_fade_mode = src.visibility_range_fade_mode
	proxy.visible = false

func _mesh_proxy(mi: MeshInstance3D, pm_of: Dictionary, exempt_of: Dictionary, view: Dictionary, skip_material: ShaderMaterial, stats: Dictionary) -> void:
	if mi.mesh == null or mi.skeleton != NodePath("") and mi.get_node_or_null(mi.skeleton) is Skeleton3D:
		return
	var n := mi.mesh.get_surface_count()
	var mats: Array = []
	var any := false
	var exempt := false
	for s in n:
		var m := mi.get_active_material(s)
		mats.append(m)
		if pm_of.has(m):
			any = true
			exempt = exempt or bool(exempt_of[m])
	if not any:
		return
	stats["meshes_considered"] = int(stats["meshes_considered"]) + 1
	if not exempt and mi.global_position.distance_to(view.pos) > float(view.cull_dist):
		return
	var box: AABB = mi.global_transform * mi.get_aabb()
	if not _rim_sphere_visible(box.get_center(), box.size.length() * 0.5, view):
		return
	var proxy := MeshInstance3D.new()
	proxy.name = "Rim_" + str(mi.name)
	proxy.mesh = mi.mesh
	_copy_instance_settings(proxy, mi)
	rim_proxy_root.add_child(proxy)
	proxy.global_transform = mi.global_transform
	for s in n:
		var m: Variant = mats[s]
		if pm_of.has(m):
			proxy.set_surface_override_material(s, pm_of[m])
		else:
			proxy.set_surface_override_material(s, skip_material)
			stats["mixed_surfaces"] = int(stats["mixed_surfaces"]) + 1
	rim_proxies.append([proxy, mi])
	stats["mesh_proxies"] = int(stats["mesh_proxies"]) + 1

func _multimesh_proxy(node: MultiMeshInstance3D, pm_of: Dictionary, exempt_of: Dictionary, view: Dictionary, skip_material: ShaderMaterial, stats: Dictionary) -> void:
	var mm := node.multimesh
	if mm == null or mm.mesh == null or mm.instance_count == 0 or mm.transform_format != MultiMesh.TRANSFORM_3D:
		return
	var mesh := mm.mesh
	var n := mesh.get_surface_count()
	var mats: Array = []
	var any := false
	var exempt := false
	for s in n:
		var m: Material = node.material_override if node.material_override != null else mesh.surface_get_material(s)
		mats.append(m)
		if pm_of.has(m):
			any = true
			exempt = exempt or bool(exempt_of[m])
	if not any:
		return
	var buf := mm.buffer
	var stride := 12 + (4 if mm.use_colors else 0) + (4 if mm.use_custom_data else 0)
	var count := mm.instance_count
	var visible_count := count if mm.visible_instance_count < 0 else mini(mm.visible_instance_count, count)
	if buf.size() < count * stride:
		return
	var xf := node.global_transform
	var local_center: Vector3 = mesh.get_aabb().get_center()
	var local_radius: float = mesh.get_aabb().size.length() * 0.5
	var cam_pos: Vector3 = view.pos
	var cull_dist: float = view.cull_dist
	var kept := PackedFloat32Array()
	var kept_n := 0
	for i in visible_count:
		var k := i * stride
		var inst := Transform3D(Basis(Vector3(buf[k], buf[k + 4], buf[k + 8]), Vector3(buf[k + 1], buf[k + 5], buf[k + 9]), Vector3(buf[k + 2], buf[k + 6], buf[k + 10])), Vector3(buf[k + 3], buf[k + 7], buf[k + 11]))
		var world_xf: Transform3D = xf * inst
		if not exempt and world_xf.origin.distance_to(cam_pos) > cull_dist:
			continue
		var scale: Vector3 = world_xf.basis.get_scale()
		if not _rim_sphere_visible(world_xf * local_center, local_radius * maxf(absf(scale.x), maxf(absf(scale.y), absf(scale.z))), view):
			continue
		kept.append_array(buf.slice(k, k + stride))
		kept_n += 1
	stats["instances_total"] = int(stats["instances_total"]) + visible_count
	if kept_n == 0:
		return
	stats["instances_kept"] = int(stats["instances_kept"]) + kept_n
	var pmesh: Mesh
	if mesh is ArrayMesh:
		pmesh = (mesh as ArrayMesh).duplicate()
		for s in n:
			var m: Variant = mats[s]
			(pmesh as ArrayMesh).surface_set_material(s, pm_of[m] if pm_of.has(m) else skip_material)
	else:
		var am := ArrayMesh.new()
		for s in n:
			am.add_surface_from_arrays(mesh.surface_get_primitive_type(s), mesh.surface_get_arrays(s))
			var m: Variant = mats[s]
			am.surface_set_material(s, pm_of[m] if pm_of.has(m) else skip_material)
		pmesh = am
	var pmm := MultiMesh.new()
	pmm.transform_format = MultiMesh.TRANSFORM_3D
	pmm.use_colors = mm.use_colors
	pmm.use_custom_data = mm.use_custom_data
	pmm.mesh = pmesh
	pmm.instance_count = kept_n
	pmm.buffer = kept
	var proxy := MultiMeshInstance3D.new()
	proxy.name = "Rim_" + str(node.name)
	proxy.multimesh = pmm
	_copy_instance_settings(proxy, node)
	rim_proxy_root.add_child(proxy)
	proxy.global_transform = xf
	rim_proxies.append([proxy, node])
	stats["multimesh_proxies"] = int(stats["multimesh_proxies"]) + 1

## 佛窟山崖 / 远景雪山的金边。探针做法是复制材质、把金边 pass 挂在 next_pass 上。
## 会投影的节点（佛窟山崖，37.7 万三角形）改用金边代理：next_pass 会跟着主材质进阴影 pass（透明、不写深度，白画），
## 代理关掉投影，画面相同。不投影的节点（远景雪山）照探针挂 next_pass（雪面柔光再接在它后面）。
## 日暮时换上 / 显示，白天换回原材质 / 隐藏。
func _install_node_edge(spec: Dictionary, edge_shader: Shader) -> int:
	var root: Node = world.get_node_or_null(NodePath(str(spec.get("path", ""))))
	if root == null:
		return -1
	var nodes: Array = root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		nodes.append(root)
	var count := 0
	for item in nodes:
		var mi := item as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var pm := _make_pass(edge_shader, spec, "edge")
		pm.set_shader_parameter("use_vertex_color", bool(spec.get("use_vertex_color", false)))
		pm.set_shader_parameter("brightness", 1.0)
		if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			if rim_proxy_root == null:
				rim_proxy_root = Node3D.new()
				rim_proxy_root.name = "RimProxies"
				layer_root.add_child(rim_proxy_root)
			var proxy := MeshInstance3D.new()
			proxy.name = "Rim_" + str(mi.name)
			proxy.mesh = mi.mesh
			_copy_instance_settings(proxy, mi)
			proxy.material_override = pm
			rim_proxy_root.add_child(proxy)
			proxy.global_transform = mi.global_transform
			rim_proxies.append([proxy, mi])
			count += 1
			continue
		if mi.material_override != null:
			var d := mi.material_override.duplicate() as Material
			d.next_pass = pm
			material_swaps.append([mi, -1, mi.material_override, d])
			count += 1
			continue
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			if m == null:
				continue
			var d2 := m.duplicate() as Material
			d2.next_pass = pm
			material_swaps.append([mi, s, mi.get_surface_override_material(s), d2])
			count += 1
	return count

## 人物金边：人物异步生成，driver 等 character_style 材质就位后调用（与探针 changan_extra_rim_watch.gd 相同的时机）。
## 探针复制人物材质再挂 next_pass；这里直接挂在人物各表面自己的风格材质上（每个表面一份，不与别人共享），白天摘掉。
func attach_character() -> Array:
	var counts: Array = []
	var fresnel: Shader = load(RIM_FRESNEL_PATH)
	for spec in char_specs:
		var cc: Node = host.character_controller
		var needle := str(spec.get("match", ""))
		var nodes: Array = cc.find_children("*" + needle + "*" if not needle.is_empty() else "*", "MeshInstance3D", true, false)
		var count := 0
		for item in nodes:
			var mi := item as MeshInstance3D
			if mi == null or mi.mesh == null or str(mi.name).begins_with("CharacterOutline_"):
				continue
			var mats: Array = []
			if mi.material_override != null:
				mats.append(mi.material_override)
			else:
				for s in mi.mesh.get_surface_count():
					mats.append(mi.get_active_material(s))
			for m in mats:
				var bm := m as BaseMaterial3D
				if bm == null:
					continue
				var pm := _make_pass(fresnel, spec, "fresnel")
				char_passes.append([bm, pm])
				if active:
					bm.next_pass = pm
				count += 1
		counts.append(count)
	char_done = true
	if active:
		_apply_mix()
	return counts

# ---------------------------------------------------------------- snow
func _install_snow() -> Dictionary:
	var out := {}
	var rim_cfg: Dictionary = cfg.get("rim", {})
	var bounce_cfg: Dictionary = cfg.get("bounce", {})
	massif_node = world.get_node_or_null("FarBackdrop/MassifBandMerged") as MeshInstance3D
	if massif_node == null:
		return {"error": "FarBackdrop/MassifBandMerged missing"}
	# 1. 只照雪山的同向暖光（晚霞染色）：雪山节点加专用可视层，灯的 cull_mask 只含这一位；雪山在阴影距离之外，不开阴影
	if rim_cfg.has("massif_key"):
		var c: Dictionary = rim_cfg.massif_key
		massif_bit = 1 << int(c.get("layer_bit", 19))
		alpenglow = DirectionalLight3D.new()
		alpenglow.name = "RimMassifAlpenglow"
		var col: Array = c.get("color", [1.0, 0.72, 0.6])
		alpenglow.light_color = Color(float(col[0]), float(col[1]), float(col[2]))
		alpenglow_energy = float(c.get("energy", 0.35))
		alpenglow.light_energy = alpenglow_energy
		alpenglow.light_specular = 0.0
		alpenglow.shadow_enabled = false
		alpenglow.light_cull_mask = massif_bit
		alpenglow.visible = false
		layer_root.add_child(alpenglow)
		alpenglow.global_basis = (host.sun as DirectionalLight3D).global_basis
		out["alpenglow"] = {"layer": massif_bit, "energy": alpenglow_energy}
	# 2. 雪面粉色柔光：接在雪山材质链的末尾（金边 pass 之后，与探针相同）
	if bounce_cfg.has("snow"):
		var sm := ShaderMaterial.new()
		sm.shader = load(SNOW_SHEEN_PATH)
		var snow: Dictionary = bounce_cfg.snow
		for k in snow.keys():
			sm.set_shader_parameter(k, _color(snow[k]))
		sm.set_shader_parameter("sun_dir_world", _sun_dir())
		sun_dir_mats.append(sm)
		fade_params.append([sm, "sheen_strength", float(snow.get("sheen_strength", 0.2))])
		var target: Material = null
		for s in material_swaps:
			if s[0] == massif_node and int(s[1]) == -1:
				target = s[3]
		if target == null:
			# 金边关掉时：自己复制一份雪山材质来挂
			target = (massif_node as MeshInstance3D).material_override.duplicate() as Material
			material_swaps.append([massif_node, -1, (massif_node as MeshInstance3D).material_override, target])
		var depth := 0
		while target.next_pass != null and depth < 8:
			target = target.next_pass
			depth += 1
		target.next_pass = sm
		out["sheen_chain_depth"] = depth + 1
	return out

# ---------------------------------------------------------------- bounce
func _install_bounce() -> Dictionary:
	var out := {}
	var b: Dictionary = cfg.get("bounce", {})
	# 琉璃瓦与院心：寺庙 surface 0（Atlas_solid，所有城市共用）打开 glaze_enable，着色器里再按 glaze_center 半径遮罩
	var temple := world.get_node_or_null(NodePath(str(b.get("temple_path", "Cities/changan/changan")))) as MeshInstance3D
	if temple == null:
		out["temple"] = "missing"
	else:
		var tp: Vector3 = temple.global_position
		var to_cam: Vector3 = (host.camera as Camera3D).global_position - tp
		to_cam.y = 0.0
		to_cam = to_cam.normalized()
		court = tp + to_cam * float(b.get("court_offset", 1.4)) + Vector3.UP * float(b.get("court_lift", 0.0))
		for sm in surface_mats:
			sm.set_shader_parameter("lamp_bounce_pos", court)
		var solid := temple.get_active_material(0) as ShaderMaterial
		if solid != null:
			solid.set_shader_parameter("glaze_enable", 1.0)
			solid.set_shader_parameter("glaze_center", tp + Vector3.UP * float(b.get("glaze_center_lift", 0.8)))
		out["temple"] = {"pos": [tp.x, tp.y, tp.z], "court": [court.x, court.y, court.z], "solid": solid.resource_name if solid != null else "none"}
	# 佛窟山崖反光灯：山崖网格加专用可视层，几盏只照这一层、不投影的平行光（方向用相机系写，指"从表面指向光源"）
	if b.has("cliff_rig"):
		var rig: Dictionary = b.cliff_rig
		cliff_bit = int(rig.get("layer", 1 << 16))
		var root: Node = world.get_node_or_null(NodePath(str(rig.get("path", "CliffBuddha"))))
		if root != null:
			var list: Array = root.find_children("*", "MeshInstance3D", true, false)
			if root is MeshInstance3D:
				list.append(root)
			for mi in list:
				cliff_meshes.append(mi as VisualInstance3D)
		var cam := host.camera as Camera3D
		var fwd: Vector3 = -cam.global_basis.z
		fwd.y = 0.0
		var to_cam_h: Vector3 = -fwd.normalized()
		var right_h: Vector3 = cam.global_basis.x
		right_h.y = 0.0
		right_h = right_h.normalized()
		var made := 0
		for spec in rig.get("lights", []):
			var d: Dictionary = spec.get("dir", {})
			var to_light: Vector3 = (right_h * float(d.get("right", 0.0)) + Vector3.UP * float(d.get("up", 0.0)) + to_cam_h * float(d.get("toward_cam", 0.0))).normalized()
			var l := DirectionalLight3D.new()
			l.name = "BounceRig%d" % made
			l.light_cull_mask = cliff_bit
			var c: Array = spec.get("color", [1.0, 0.6, 0.35])
			l.light_color = Color(float(c[0]), float(c[1]), float(c[2]))
			l.light_energy = float(spec.get("energy", 0.2))
			l.light_specular = 0.0
			l.shadow_enabled = false
			l.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
			l.visible = false
			layer_root.add_child(l)
			l.look_at(l.global_position - to_light, Vector3.UP if absf(to_light.y) < 0.95 else Vector3.RIGHT)
			cliff_lights.append([l, l.light_energy])
			made += 1
		out["cliff_rig"] = {"meshes": cliff_meshes.size(), "lights": made, "layer": cliff_bit}
	if b.has("character"):
		char_light_spec = b.character
		out["character"] = "deferred"
	return out

## 人物腿脚暖反光：driver 等人物就位后调用；灯只照人物层（character_controller.CHARACTER_LIGHT_LAYER），不照场景、不投影。
func attach_character_light(cc: Node) -> void:
	if char_light_spec.is_empty() or char_light != null:
		return
	char_light = OmniLight3D.new()
	char_light.name = "CharacterBounceWarm"
	var layer: Variant = cc.get("CHARACTER_LIGHT_LAYER")
	char_light.light_cull_mask = int(layer) if layer != null else (1 << 17)
	var c: Array = char_light_spec.get("color", [1.0, 0.6, 0.32])
	char_light.light_color = Color(float(c[0]), float(c[1]), float(c[2]))
	char_light.light_energy = float(char_light_spec.get("energy", 0.8))
	char_light.omni_range = float(char_light_spec.get("range", 0.6))
	char_light.omni_attenuation = float(char_light_spec.get("attenuation", 1.2))
	char_light.light_specular = 0.0
	char_light.shadow_enabled = false
	char_light.visible = active
	cc.add_child(char_light)
	follow_character_light(cc)
	if active:
		_apply_mix()

func follow_character_light(cc: Node) -> void:
	if char_light == null or not is_instance_valid(cc):
		return
	var a: Variant = cc.get("actor")
	if not is_instance_valid(a):
		return
	var p: Vector3 = (a as Node3D).global_position
	var d: Vector3 = court - p
	d.y = 0.0
	if d.length() > 0.001:
		d = d.normalized()
	char_light.global_position = p + d * float(char_light_spec.get("toward_court", 0.15)) + Vector3.UP * float(char_light_spec.get("lift", -0.05))

# ---------------------------------------------------------------- ground
func _install_ground() -> Dictionary:
	var g: Dictionary = cfg.get("ground", {})
	var out := {}
	var u: Dictionary = g.get("terrain", {})
	for m in terrain_mats:
		for k in u.keys():
			m.set_shader_parameter(k, _vector(u[k]))
	for m in surface_mats:
		if not terrain_mats.has(m):
			m.set_shader_parameter("ground_v2", 0.0)
	out["terrain_materials"] = terrain_mats.size()
	var path := str(g.get("scatter", ""))
	var packed: PackedScene = load(path) if not path.is_empty() and ResourceLoader.exists(path) else null
	if packed == null:
		push_error("Changan dusk ground scatter missing: " + path + " (bake it with --bake-changan-dusk-scatter)")
		out["scatter"] = "missing"
		return out
	scatter_root = packed.instantiate() as Node3D
	scatter_root.visible = false
	layer_root.add_child(scatter_root)
	if bool(g.get("clear_court", true)) and scatter_root.has_meta("court_rect"):
		var r: Array = scatter_root.get_meta("court_rect")
		var cr := Rect2(Vector2(float(r[0]), float(r[1])), Vector2(float(r[2]) - float(r[0]), float(r[3]) - float(r[1]))).grow(float(g.get("court_clear_grow", 0.02)))
		for m in terrain_mats:
			m.set_shader_parameter("ground_clear_rect", Vector4(cr.position.x, cr.position.y, cr.end.x, cr.end.y))
		out["court_clear_rect"] = [cr.position.x, cr.position.y, cr.end.x, cr.end.y]
	# 散布材质 = 地形材质的复制（同一着色器、同一套光照参数），关掉地面细节与风；与探针一样和地形共用同一个金边 pass（在 _install_rim 之后接上）
	if not terrain_mats.is_empty():
		scatter_mat = _clone_with_dusk_shader(terrain_mats[0])
		scatter_mat.set_shader_parameter("ground_v2", 0.0)
		scatter_mat.set_shader_parameter("wind_amp", 0.0)
		dusk_mix_mats.append(scatter_mat)
	var counts := {}
	for child in scatter_root.get_children():
		var node := child as MultiMeshInstance3D
		if node == null or node.multimesh == null:
			continue
		node.material_override = scatter_mat
		scatter_mms.append(node.multimesh)
		counts[str(node.name)] = node.multimesh.instance_count
	out["scatter"] = counts
	out["scatter_path"] = path
	return out

## 复制一份地表材质、换成日暮着色器。不能直接 duplicate()：地形材质此时还挂着 atlas_surface.gdshader，
## duplicate 只复制当前着色器声明过的 uniform，日暮专用的参数（sun_wrap / bounce_* / 地面细节 …）会丢。
func _clone_with_dusk_shader(src: ShaderMaterial) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.resource_name = src.resource_name
	m.shader = dusk_shader
	for u in dusk_shader.get_shader_uniform_list():
		var uname := str(u.get("name", ""))
		var v: Variant = src.get_shader_parameter(uname)
		if v != null:
			m.set_shader_parameter(uname, v)
	return m

## 金边装好之后再把地形的金边 pass 接到散布材质上（探针里散布材质是地形材质的浅复制，next_pass 与地形共用）。
func _link_scatter_rim() -> void:
	if scatter_mat == null or terrain_mats.is_empty():
		return
	for p in rim_pairs:
		if p[0] == terrain_mats[0]:
			scatter_mat.next_pass = p[1]

func _bake_scatter() -> void:
	var g: Dictionary = cfg.get("ground", {})
	var path := str(g.get("scatter", ""))
	var result: Dictionary = load(BAKE_PATH).new().bake(host, g.get("scatter_bake", {}), path)
	print("CHANGAN_DUSK_SCATTER_BAKED ", JSON.stringify(result))

# ---------------------------------------------------------------- clouds（对照开关）
func _clouds_previous() -> void:
	cloud_off_done = true
	var prev: Dictionary = cfg.get("previous", {}).get("cloud_dusk_palette", {})
	if prev.is_empty():
		return
	for item in world.find_children("*", "", true, false):
		var name := str(item.name)
		if not (name.begins_with("CloudDusk") or name.begins_with("CloudAccentdusk")):
			continue
		var lobes := item.get_node_or_null("Lobes") as GeometryInstance3D
		if lobes != null and lobes.material_override is ShaderMaterial:
			(lobes.material_override as ShaderMaterial).set_shader_parameter("cloud_color", Color(str(prev.light)))
			(lobes.material_override as ShaderMaterial).set_shader_parameter("shade_color", Color(str(prev.shade)))
