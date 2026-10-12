extends Node
## 巴格达旅人 · 循环实机窗口：「下雨 → 开花、树叶发光 → 黄昏晚霞 → 下雨」。
## 2026-09-27：从 SceneTree 脚本 review_cycle.gd 搬成节点（场景 scenes/traveler/baghdad_cycle.tscn），正式包才能当一幕打开
## （导出模板不认 --script，夜测 TL-1 / TRV-1）。review_cycle.gd 现在只是把这个场景挂到 root 上，下面所有参数和模式照旧。
## 两个 viewer 以前是读 baghdad_viewer.gd 的源码替换字符串再现编译；正式包里读不到源码，改成建之前设 viewer 的三个钩子
## （layout_path / skip_storm_look / post_build_overlay，默认值就是原来的行为），画面不变。
## 从开场进来（带 --lshu-act）时：不强制最大化、沿用开场传来的窗口大小，两侧留边是深色；载入卡盖到能点为止；
## 调试键 R / P / 1 2 3 / H（标题栏）要再带 --lshu-dev，空格（= 点土豆）照常；预热不等 frame_post_draw（窗口被挡住时不会卡在载入）。
##
## 两个世界并排跑、同一个时钟：
##   A 雨世界 = Codex 的雨景装配（storm look + 捧物 + 开花 + 雨 + 光束 / 叶面发光 / 城灯 / 火与树风），
##             加上晚霞世界已认可的中景沙脊与碎石（按雨世界的湿地约定改造，见 cycle_midground.gd）和地面草风。
##   B 晚霞世界 = 晚霞探针 m_grass（光、云、金边、沙地、风沙、树风、落叶、草），换上 Codex 的捧物动作与土豆开花。
## 两边的人物动作、土豆与花由同一个时钟驱动，所以过渡时人物不会重影。
## 合成层（cycle_mix.gdshader）按时间线把两张图过渡：晚霞从太阳处向外铺开，雨从左上方压回来。
## 过渡以外只渲染正在显示的那个世界（另一个 SubViewport 暂停），过渡前 1 秒预热。
##
## 时间线（cycle_config.json 可改）：0–8 s 为 Codex 原节奏（0–4 开花、3–6 光束下探、6.2–8 叶面发光、4–8 城灯），
## 8–12 s 过渡到晚霞（手中保持盛开的花），晚霞停留，4 s 过渡回雨（花收回），下雨停留，再开始下一轮。
##
## 交互（Carlos 2026-09-23：「交互为：点击「土豆」进行自动切换」）：默认是点击模式，三个状态轮流切换，
##   下雨（等待）→ 点土豆 → 开花、树叶发光（Codex 8 秒节奏）→ 点土豆 → 云层滚走露出晚霞（8 秒）→ 点土豆 → 雨压回来、花收回（4 秒）→ 下雨。
##   鼠标移到土豆上变成小手；切换过程中点击不响应。空格等同点土豆。--cycle-auto 回到自动循环。
## 按键：R 回到下雨  P 暂停/继续  1/2/3 直接跳到 下雨/开花发光/晚霞  H 标题栏提示显示/隐藏。
## 抽查静帧（给导演验证用）：--cycle-stills=<绝对目录> --cycle-times=0,4.8,8,10,12,20,24,26 会逐个时间点截合成图后退出。
const LAYOUT := "res://data/traveler/baghdad_scene.lookdev.json"
const VIEWER_SOURCE := "res://scripts/traveler/baghdad/baghdad_viewer.gd"
const CONFIG := "res://tools/traveler/baghdad/cycle/cycle_config.json"
const MIX_SHADER := "res://tools/traveler/baghdad/cycle/cycle_mix.gdshader"
const SIZE := Vector2i(1920, 1080)
const PREROLL := 1.0
const ActExit := preload("res://scripts/traveler/act_exit_button.gd")
## 参数、退出都经 traveler_launch.gd：开场里进来（同一个窗口）时读开场给的参数，结束时回开场，并且不碰窗口（大小、标题栏）
const Launch := preload("res://scripts/traveler/traveler_launch.gd")

var cfg: Dictionary = {}
var vp_a: SubViewport
var vp_b: SubViewport
var vp_mix: SubViewport
var mix_mat: ShaderMaterial
var viewer_a: Node3D
var viewer_b: Node3D
var pose_a: Node3D
var pose_b: Node3D
var flower_a: Node3D
var flower_b: Node3D
var rain_a: Node3D
var story_a: Node3D
var motion_b: Node3D
var ready_state := false
var clock_base := 0.0
var clock_started := 0
var clock_paused := false
var show_time := true
var _last_title := 0
var _state: Dictionary = {}
var stills_dir := ""
var still_times: Array[float] = []
var perf_seconds := 0.0
var video_dir := ""
var video_seconds := 0.0
var _perf: Dictionary = {}
var interactive := true
var preview: TextureRect
var i_state := "rain"      # rain | bloom | dusk
var i_trans := ""          # "" | to_bloom | to_dusk | to_rain
var i_trans_start := 0.0
var i_loops := 0
var selftest_dir := ""
var selftest_os := false   # true：自测走 Input.parse_input_event（与真实窗口鼠标事件同一路径：窗口坐标 → 拉伸变换 → GUI）
var _hover := false
var _perf_last := 0
var root: Window
var act_overlay: Node
var act_mode := false

func _ready() -> void:
	root = get_tree().root
	call_deferred("run")

func run() -> void:
	for arg in Launch.user_args():
		if arg.begins_with("--cycle-stills="):
			stills_dir = arg.trim_prefix("--cycle-stills=")
		if arg.begins_with("--cycle-video="):
			video_dir = arg.trim_prefix("--cycle-video=")
		if arg.begins_with("--cycle-video-seconds="):
			video_seconds = float(arg.trim_prefix("--cycle-video-seconds="))
		if arg == "--cycle-auto":
			interactive = false
		if arg == "--cycle-selftest-os":
			selftest_os = true
		if arg.begins_with("--cycle-selftest="):
			selftest_dir = arg.trim_prefix("--cycle-selftest=")
		if arg.begins_with("--cycle-perf="):
			perf_seconds = float(arg.trim_prefix("--cycle-perf="))
		if arg.begins_with("--cycle-times="):
			for part in arg.trim_prefix("--cycle-times=").split(",", false):
				still_times.append(float(part))
	var config_path := CONFIG
	for arg in Launch.user_args():
		if arg.begins_with("--cycle-config="):
			config_path = arg.trim_prefix("--cycle-config=")
	cfg = JSON.parse_string(FileAccess.get_file_as_string(config_path))
	if not Launch.hosting():
		root.title = "巴格达旅人 · 循环（载入中…）"
	if not stills_dir.is_empty() or perf_seconds > 0.0 or not video_dir.is_empty():
		interactive = false   # 抽查 / 录像 / 测帧沿用自动时间线
	act_overlay = ActExit.attach(self, "baghdad")  # 从开场进来时：返回 + 提示 + 载入卡（2026-09-27）
	act_mode = act_overlay != null
	if act_mode:
		pass   # 从开场进来：沿用开场传来的 --position / --resolution（或全屏），不再强制最大化（夜测 TRV-9）
	elif stills_dir.is_empty() and perf_seconds <= 0.0 and video_dir.is_empty() and selftest_dir.is_empty():
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	else:
		# 抽查 / 测帧模式：窗口缩到屏幕右下角并置顶。macOS 上被别的窗口完全挡住的 Godot 窗口会停止绘制，截图会卡死。
		var wid := DisplayServer.MAIN_WINDOW_ID
		var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(wid))
		DisplayServer.window_set_size(Vector2i(480, 270), wid)
		DisplayServer.window_set_position(usable.position + usable.size - Vector2i(488, 278), wid)
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true, wid)
	root.window_input.connect(_on_input)
	vp_a = _make_viewport("RainWorld", true)
	vp_b = _make_viewport("DuskWorld", true)
	vp_mix = _make_viewport("CycleMix", false)
	var rect := TextureRect.new()
	rect.size = Vector2(SIZE)
	rect.texture = vp_a.get_texture()
	mix_mat = ShaderMaterial.new()
	mix_mat.shader = load(MIX_SHADER)
	mix_mat.set_shader_parameter("tex_a", vp_a.get_texture())
	mix_mat.set_shader_parameter("tex_b", vp_b.get_texture())
	rect.material = mix_mat
	vp_mix.add_child(rect)
	# 16:9 画面按比例居中，窗口比例不同时两侧露出的是窗口底色：垫一层深色，不再是 Godot 默认的灰（夜测 TRV-9）
	var backdrop := ColorRect.new()
	backdrop.name = "Letterbox"
	backdrop.color = Color(0.07, 0.06, 0.055)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview = TextureRect.new()
	preview.texture = vp_mix.get_texture()
	preview.mouse_filter = Control.MOUSE_FILTER_STOP
	preview.gui_input.connect(_on_preview_input)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if act_mode:
		# 先让载入卡画出来几帧，再开始建两个世界（建晚霞世界时主线程会卡几秒）
		for i in 3:
			await get_tree().process_frame
	if not await _build_rain_world():
		return
	if not await _build_dusk_world():
		return
	_polish(story_a.get("_motion"), story_a.get("_city"), cfg.get("polish", {}).get("rain_world", {}))
	_polish(motion_b, null, cfg.get("polish", {}).get("dusk_world", {}))
	Engine.max_fps = 0 if perf_seconds > 0.0 else 30
	if interactive:
		for i in 60:
			apply_time(float(i) / 30.0)
			vp_a.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			vp_b.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			await _preroll_frame()
	ready_state = true
	if stills_dir.is_empty() and video_dir.is_empty() and selftest_dir.is_empty() and perf_seconds <= 0.0 and load("res://scripts/audio/ambience/amb_kit.gd").allowed():
		var amb: Node = load("res://scripts/audio/ambience/baghdad_ambience.gd").new()   # 环境声（方案 §3.7）；只在实机看的时候挂，截图 / 录像 / 自检 / 测帧率都不挂
		amb.set("driver", self)   # 状态（i_state / i_trans / _state）在这个节点上，不在 SceneTree 上了
		add_child(amb)
	clock_started = Time.get_ticks_usec()
	get_tree().process_frame.connect(_tick)
	print("BAGHDAD_CYCLE_READY ", JSON.stringify({"cycle_seconds": _cycle_length(), "timeline": cfg.timeline}))
	if act_overlay != null:
		act_overlay.call("mark_ready")
	if not stills_dir.is_empty():
		await _capture_stills()
	elif not video_dir.is_empty():
		await _capture_video()
	elif not selftest_dir.is_empty():
		await _selftest()

## 预热一帧：单独开（审片 / 截图）时照旧等画完这一帧；从开场进来时只等一个处理帧——
## macOS 不画被挡住的窗口，frame_post_draw 会一直不来，巴格达就卡在载入（夜测 TL-4）
func _preroll_frame() -> void:
	if act_mode:
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw

## 冒烟测试（act_exit_button --lshu-act-smoke）：点一下土豆
func act_poke() -> void:
	if ready_state and interactive:
		advance(clock())

func _make_viewport(node_name: String, world: bool) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = node_name
	vp.size = SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if world:
		vp.own_world_3d = true
		vp.msaa_3d = Viewport.MSAA_4X
		vp.use_taa = false
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	else:
		vp.disable_3d = true
	add_child(vp)
	return vp

## 雨世界 = 原 viewer + lookdev 布局；晚霞世界再加：电影感夕照、不挂暴雨外观、建完叠 lookdev_overlay（--lookdev=<变体>）。
## 和以前改源码的三处替换一一对应（见 baghdad_viewer.gd 的钩子说明）。
func _compile_viewer(dusk: bool) -> Node3D:
	var script: Script = load(VIEWER_SOURCE)
	if script == null:
		_fail("viewer 脚本载入失败（%s 世界）" % ("晚霞" if dusk else "雨"))
		return null
	var viewer: Node3D = script.new()
	viewer.set("layout_path", LAYOUT)
	if dusk:
		viewer.set("cinematic_sunset", true)
		viewer.set("skip_storm_look", true)
		viewer.set("post_build_overlay", "res://tools/traveler/lookdev_baghdad/lookdev_overlay.gd")
	return viewer

func _await_ready(viewer: Node3D) -> bool:
	var deadline := Time.get_ticks_msec() + 90000
	while not bool(viewer.get("ready_for_capture")):
		if Time.get_ticks_msec() > deadline:
			_fail("viewer 就绪超时")
			return false
		await get_tree().process_frame
	return true

func _build_rain_world() -> bool:
	viewer_a = _compile_viewer(false)
	if viewer_a == null:
		return false
	vp_a.add_child(viewer_a)
	if not await _await_ready(viewer_a):
		return false
	pose_a = load("res://scripts/traveler/baghdad/baghdad_carrying_pose.gd").new()
	viewer_a.add_child(pose_a)
	if not bool(await pose_a.call("configure", viewer_a)):
		_fail("雨世界：捧物动作配置失败")
		return false
	pose_a.set_process(false)
	flower_a = load("res://scripts/traveler/baghdad/baghdad_potato_blossom.gd").new()
	flower_a.set("autoplay", false)
	viewer_a.add_child(flower_a)
	if not bool(await flower_a.call("configure", pose_a)):
		_fail("雨世界：土豆开花配置失败")
		return false
	flower_a.set_process(false)
	rain_a = load("res://scripts/traveler/baghdad/baghdad_rain_look.gd").new()
	viewer_a.add_child(rain_a)
	rain_a.call("configure", viewer_a)
	rain_a.set_process(false)
	var geo: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tools/traveler/lookdev_baghdad/variants/t_combo_geo.json"))
	var drift_cfg: Dictionary = {}
	var scatter_cfg: Dictionary = {}
	for item in geo.extra_scripts:
		if str(item.script).ends_with("lookdev_extra_drift.gd"):
			drift_cfg = item.cfg
		elif str(item.script).ends_with("lookdev_extra_scatter.gd"):
			scatter_cfg = item.cfg
	var mid: Dictionary = load("res://tools/traveler/baghdad/cycle/cycle_midground.gd").new().build(viewer_a, drift_cfg, scatter_cfg, cfg.rain_world.get("wet", {}))
	print("BAGHDAD_CYCLE_RAIN_MIDGROUND ", JSON.stringify(mid.get("converted_for_rain_world", [])))
	var grass: Dictionary = load("res://tools/traveler/lookdev_baghdad/lookdev_extra_grass.gd").new().build(viewer_a, {"sway_ratio": 0.22})
	print("BAGHDAD_CYCLE_RAIN_GRASS ", grass.nodes.size())
	story_a = load("res://tools/traveler/baghdad/cycle/cycle_story.gd").new()
	viewer_a.add_child(story_a)
	if not bool(story_a.call("configure", viewer_a, pose_a, flower_a, rain_a, cfg.rain_world)):
		_fail("雨世界：时间线控制器配置失败")
		return false
	return true

func _build_dusk_world() -> bool:
	viewer_b = _compile_viewer(true)
	if viewer_b == null:
		return false
	vp_b.add_child(viewer_b)
	if not await _await_ready(viewer_b):
		return false
	pose_b = load("res://scripts/traveler/baghdad/baghdad_carrying_pose.gd").new()
	viewer_b.add_child(pose_b)
	if not bool(await pose_b.call("configure", viewer_b)):
		_fail("晚霞世界：捧物动作配置失败")
		return false
	pose_b.set_process(false)
	flower_b = load("res://scripts/traveler/baghdad/baghdad_potato_blossom.gd").new()
	flower_b.set("autoplay", false)
	viewer_b.add_child(flower_b)
	if not bool(await flower_b.call("configure", pose_b)):
		_fail("晚霞世界：土豆开花配置失败")
		return false
	flower_b.set_process(false)
	_rim_character(viewer_b, cfg.dusk_world.get("character_rim", {}))
	# 只借用 Codex 的火焰动态（树不会被接管：晚霞世界的树材质里没有 glow_strength）
	motion_b = load("res://scripts/traveler/baghdad/baghdad_ambient_motion.gd").new()
	viewer_b.add_child(motion_b)
	motion_b.call("configure", viewer_b)
	return true

func _rim_character(viewer: Node3D, rim: Dictionary) -> void:
	var shader: Shader = load("res://tools/traveler/lookdev_baghdad/lookdev_fresnel_rim.gdshader")
	var sun: DirectionalLight3D = viewer.get("sun")
	var character: Node3D = viewer.get("character")
	var color: Array = rim.get("color", [1.0, 0.72, 0.32])
	var count := 0
	for item in character.find_children("*", "MeshInstance3D", true, false):
		var mi := item as MeshInstance3D
		if not mi.is_visible_in_tree() or str(mi.name).begins_with("CarryingPoseOutline_") or str(mi.get_path()).contains("PotatoBundle"):
			continue
		var pass_mat := ShaderMaterial.new()
		pass_mat.shader = shader
		pass_mat.set_shader_parameter("rim_color", Color(float(color[0]), float(color[1]), float(color[2])))
		pass_mat.set_shader_parameter("rim_power", float(rim.get("power", 3.4)))
		pass_mat.set_shader_parameter("rim_intensity", float(rim.get("intensity", 1.6)))
		pass_mat.set_shader_parameter("light_dir", sun.global_basis.z.normalized())
		pass_mat.set_shader_parameter("dir_weight", float(rim.get("dir_weight", 0.8)))
		pass_mat.set_shader_parameter("dir_softness", float(rim.get("dir_softness", 0.35)))
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			if m == null:
				continue
			var d := m.duplicate() as Material
			d.next_pass = pass_mat
			mi.set_surface_override_material(s, d)
			count += 1
	print("BAGHDAD_CYCLE_DUSK_CHARACTER_RIM ", count)

## 打磨（Codex 复盘三项里的火焰与城灯；树冠亮斑在 cycle_story 里按参数调）。只换材质的 shader 和灯的参数，不改 Codex 文件。
func _polish(motion: Node, city: Node, p: Dictionary) -> void:
	var notes := {}
	if motion != null and p.has("flame"):
		var f: Dictionary = p.flame
		var shader: Shader = load("res://tools/traveler/baghdad/cycle/cycle_flame.gdshader")
		for m in motion.get("flame_materials"):
			var mat := m as ShaderMaterial
			mat.shader = shader
			for key in ["core_gain", "outer_gain", "edge_soft", "tip_start", "alpha_max"]:
				if f.has(key):
					mat.set_shader_parameter(key, float(f[key]))
		var light := motion.get("_fire_light") as OmniLight3D
		if light != null:
			motion.set("_original_fire_energy", float(f.get("light_energy", 0.22)))
			light.light_specular = float(f.get("light_specular", 0.7))
			light.omni_range = float(f.get("light_range", 1.1))
		notes["flame"] = (motion.get("flame_materials") as Array).size()
	if city != null and p.has("city"):
		var c: Dictionary = p.city
		var shader2: Shader = load("res://tools/traveler/baghdad/cycle/cycle_city_lights.gdshader")
		var n := 0
		for record in city.get("_faces"):
			var mat2: ShaderMaterial = record.material
			mat2.shader = shader2
			var lantern := str((record.node as Node).name).begins_with("OriginalLantern")
			mat2.set_shader_parameter("energy", float(c.get("lantern_level" if lantern else "window_level", 1.3)))
			mat2.set_shader_parameter("door_level", float(c.get("door_level", 0.4)))
			n += 1
		city.set("wall_wash_energy", float(c.get("wall_wash_energy", 0.02)))
		var wash := (city as Node).find_child("WarmTownReflectedLight", true, false) as OmniLight3D
		if wash != null:
			wash.omni_attenuation = float(c.get("wall_wash_attenuation", 0.8))
		notes["city_faces"] = n
	print("BAGHDAD_CYCLE_POLISH ", JSON.stringify(notes))

func _cycle_length() -> float:
	var t: Dictionary = cfg.timeline
	return float(t.bloom_story_seconds) + float(t.to_dusk_seconds) + float(t.dusk_hold_seconds) + float(t.to_rain_seconds) + float(t.rain_hold_seconds)

func _ease(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)

func cycle_state(motion_t: float) -> Dictionary:
	var total := _cycle_length()
	return cycle_state_at(fposmod(motion_t, total), floorf(motion_t / total))

func cycle_state_at(c: float, n_cycles: float) -> Dictionary:
	var t: Dictionary = cfg.timeline
	var t1 := float(t.bloom_story_seconds)
	var t2 := t1 + float(t.to_dusk_seconds)
	var t3 := t2 + float(t.dusk_hold_seconds)
	var t4 := t3 + float(t.to_rain_seconds)
	var total := _cycle_length()
	var full := float(cfg.flower.growth_full)
	var rate := float(cfg.flower.growth_rate)
	var s := {"cycle_t": c, "cycle_seconds": total}
	if c < t1:
		s.merge({"phase": "下雨 → 开花发光", "story_t": c, "growth": minf(rate * c, full), "direction": 0, "progress": 0.0})
	elif c < t2:
		var ud := (c - t1) / (t2 - t1)
		var td: Dictionary = cfg.transition.to_dusk
		# 云先动起来再露天：前沿在 progress_start 之后开始，之后在剩余时间里近乎匀速推进（轻微缓入缓出）
		var lin := clampf((ud - float(td.get("progress_start", 0.05))) / (1.0 - float(td.get("progress_start", 0.05))), 0.0, 1.0)
		var pd := lerpf(lin, _ease(lin), float(td.get("progress_ease", 0.35)))
		s.merge({"phase": "开花发光 → 晚霞", "story_t": t1, "growth": full, "direction": 0, "progress": pd,
			"sky_scroll": float(td.get("sky_scroll_total", 0.75)) * pow(ud, float(td.get("scroll_power", 1.7)))})
	elif c < t3:
		s.merge({"phase": "黄昏晚霞", "story_t": t1, "growth": full, "direction": 0, "progress": 1.0})
	elif c < t4:
		var u := (c - t3) / (t4 - t3)
		var tr_: Dictionary = cfg.transition.to_rain
		# 新雨云从右边压进来，逐渐减速停住（滚动量从 -total 回到 0）
		s.merge({"phase": "晚霞 → 下雨", "story_t": 0.0, "growth": full * (1.0 - _ease(u)), "direction": 1, "progress": _ease(u),
			"sky_scroll": -float(tr_.get("sky_scroll_total", 0.4)) * pow(1.0 - u, float(tr_.get("scroll_power", 1.7)))})
	else:
		s.merge({"phase": "下雨", "story_t": 0.0, "growth": 0.0, "direction": 1, "progress": 1.0})
	if not s.has("sky_scroll"):
		s["sky_scroll"] = 0.0
	# 晚霞天空的"延时摄影"：两次过渡期间晚霞云额外加速平移（速度呈钟形，结束时回到常速），累积量跨循环单调增加，不会跳回
	var extra_d := float(cfg.transition.to_dusk.get("dusk_cloud_extra", 0.0))
	var extra_r := float(cfg.transition.to_rain.get("dusk_cloud_extra", 0.0))
	var partial := 0.0
	if c >= t1 and c < t2:
		partial = extra_d * 0.5 * (1.0 - cos(PI * (c - t1) / (t2 - t1)))
	elif c >= t2:
		partial = extra_d
	if c >= t3 and c < t4:
		partial += extra_r * 0.5 * (1.0 - cos(PI * (c - t3) / (t4 - t3)))
	elif c >= t4:
		partial += extra_r
	s["dusk_cloud_offset"] = n_cycles * (extra_d + extra_r) + partial
	var need_a := c < t2 or c >= t3 - PREROLL
	var need_b := c >= t1 - PREROLL and c < t4
	s["need_a"] = need_a
	s["need_b"] = need_b
	return s

## 点击模式的状态机：把三个等待状态和三段过渡映射到自动时间线上的"虚拟循环时刻"，画面逻辑与自动循环完全共用。
## 下雨 = 0 s；开花发光 = 8 s（剧情走完）；晚霞 = 转晚霞结束时刻。过渡进行中按真实时间推进这个时刻。
func interactive_c(motion_t: float) -> float:
	var t: Dictionary = cfg.timeline
	var t1 := float(t.bloom_story_seconds)
	var t2 := t1 + float(t.to_dusk_seconds)
	var t3 := t2 + float(t.dusk_hold_seconds)
	var t4 := t3 + float(t.to_rain_seconds)
	var e := motion_t - i_trans_start
	match i_trans:
		"to_bloom":
			if e >= t1:
				_finish("bloom")
				return t1
			return maxf(e, 0.0)
		"to_dusk":
			if e >= t2 - t1:
				_finish("dusk")
				return t2
			return t1 + maxf(e, 0.0)
		"to_rain":
			if e >= t4 - t3:
				i_loops += 1
				_finish("rain")
				return 0.0
			return t3 + maxf(e, 0.0)
	match i_state:
		"bloom":
			return t1
		"dusk":
			return t2
	return 0.0

func _finish(state: String) -> void:
	i_state = state
	i_trans = ""
	print("BAGHDAD_CYCLE_STATE ", state)

func advance(now: float) -> bool:
	if i_trans != "":
		return false
	i_trans = {"rain": "to_bloom", "bloom": "to_dusk", "dusk": "to_rain"}[i_state]
	i_trans_start = now
	print("BAGHDAD_CYCLE_CLICK ", JSON.stringify({"from": i_state, "transition": i_trans, "t": now}))
	return true

func jump_to(state: String) -> void:
	if state == "rain" and (i_state != "rain" or i_trans != ""):
		i_loops += 1
	i_state = state
	i_trans = ""

func state_label() -> String:
	match i_trans:
		"to_bloom":
			return "开花中…"
		"to_dusk":
			return "云层散去…"
		"to_rain":
			return "下雨了…"
	return {"rain": "下雨 · 点土豆开花", "bloom": "开花、树叶发光 · 点土豆放晴", "dusk": "黄昏晚霞 · 点土豆下雨"}[i_state]

## 土豆（连同手里的花）在 1920×1080 画面上的包围框，外扩 hit_padding_px。
func potato_rect() -> Rect2:
	var in_dusk := i_state == "dusk" and i_trans == ""
	var pose: Node3D = pose_b if in_dusk else pose_a
	var viewer: Node3D = viewer_b if in_dusk else viewer_a
	var bundle := pose.get("potato_bundle") as Node3D
	var cam := viewer.get("camera") as Camera3D
	var r := Rect2()
	var first := true
	for item in bundle.find_children("*", "MeshInstance3D", true, false):
		var mi := item as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var box: AABB = mi.global_transform * mi.mesh.get_aabb()
		for k in 8:
			var p := box.get_endpoint(k)
			if cam.is_position_behind(p):
				continue
			var sp := cam.unproject_position(p)
			if first:
				r = Rect2(sp, Vector2.ZERO)
				first = false
			else:
				r = r.expand(sp)
	var ic: Dictionary = cfg.get("interaction", {})
	r = r.grow(float(ic.get("hit_padding_px", 24.0)))
	var min_size := float(ic.get("hit_min_px", 72.0))
	if r.size.x < min_size:
		r = r.grow_individual((min_size - r.size.x) * 0.5, 0.0, (min_size - r.size.x) * 0.5, 0.0)
	if r.size.y < min_size:
		r = r.grow_individual(0.0, (min_size - r.size.y) * 0.5, 0.0, (min_size - r.size.y) * 0.5)
	return r

## 预览控件局部坐标 → 1920×1080 画面像素（TextureRect 按比例居中显示）
func to_frame_px(local: Vector2) -> Vector2:
	var sz := preview.size
	var s := minf(sz.x / float(SIZE.x), sz.y / float(SIZE.y))
	var off := (sz - Vector2(SIZE) * s) * 0.5
	return (local - off) / s

func from_frame_px(px: Vector2) -> Vector2:
	var sz := preview.size
	var s := minf(sz.x / float(SIZE.x), sz.y / float(SIZE.y))
	var off := (sz - Vector2(SIZE) * s) * 0.5
	return off + px * s

func _on_preview_input(event: InputEvent) -> void:
	if not ready_state or not interactive:
		return
	if event is InputEventMouseMotion:
		var over := i_trans == "" and potato_rect().has_point(to_frame_px((event as InputEventMouseMotion).position))
		if over != _hover:
			_hover = over
			preview.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if over else Control.CURSOR_ARROW
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var px := to_frame_px(mb.position)
			var pr := potato_rect()
			print("BAGHDAD_CYCLE_MOUSE_PREVIEW ", JSON.stringify({"frame_px": [roundf(px.x), roundf(px.y)], "potato_rect": [roundf(pr.position.x), roundf(pr.position.y), roundf(pr.size.x), roundf(pr.size.y)], "hit": pr.has_point(px), "state": i_state, "busy": i_trans != ""}))
			if pr.has_point(px):
				if advance(clock()):
					_hover = false
					preview.mouse_default_cursor_shape = Control.CURSOR_ARROW
			preview.accept_event()

func clock() -> float:
	if clock_paused:
		return clock_base
	return clock_base + float(Time.get_ticks_usec() - clock_started) / 1000000.0

func set_clock(seconds: float) -> void:
	clock_base = maxf(seconds, 0.0)
	clock_started = Time.get_ticks_usec()

func apply_time(motion_t: float) -> void:
	var s: Dictionary
	if interactive and ready_state:
		s = cycle_state_at(interactive_c(motion_t), float(i_loops))
		s["phase"] = state_label()
		var busy := i_trans != ""
		s["need_a"] = i_trans in ["to_bloom", "to_dusk", "to_rain"] or (not busy and i_state != "dusk")
		s["need_b"] = i_trans in ["to_dusk", "to_rain"] or (not busy and i_state == "dusk")
	else:
		s = cycle_state(motion_t)
	_state = s
	story_a.call("set_state", float(s.story_t), motion_t, float(s.growth))
	pose_b.call("set_time", motion_t)
	flower_b.call("set_story_time", float(s.growth), motion_t)
	motion_b.call("set_time", motion_t)
	var key := "to_dusk" if int(s.direction) == 0 else "to_rain"
	var tr: Dictionary = cfg.transition[key]
	story_a.call("set_sky_scroll", float(s.sky_scroll))
	var dusk_sky: ShaderMaterial = (viewer_b.get("look_profile") as RefCounted).get("sky_material")
	if dusk_sky != null:
		dusk_sky.set_shader_parameter("cloud_drift_offset", float(s.dusk_cloud_offset))
	mix_mat.set_shader_parameter("direction", int(s.direction))
	mix_mat.set_shader_parameter("progress", float(s.progress))
	# 天空每滚动 1 rad，画面上约平移 0.872 个画面宽（1920 宽、竖直视场 40° 时中心处约 1674 px/rad）
	mix_mat.set_shader_parameter("noise_scroll", float(s.sky_scroll) * 0.872)
	for k in ["wipe", "soft", "tilt", "edge_glow"]:
		mix_mat.set_shader_parameter(k, float(tr[k]))
	mix_mat.set_shader_parameter("noise_amount", float(tr.noise))
	vp_a.render_target_update_mode = SubViewport.UPDATE_ALWAYS if bool(s.need_a) else SubViewport.UPDATE_DISABLED
	vp_b.render_target_update_mode = SubViewport.UPDATE_ALWAYS if bool(s.need_b) else SubViewport.UPDATE_DISABLED

func _tick() -> void:
	if not ready_state or not stills_dir.is_empty() or not video_dir.is_empty():
		return
	apply_time(clock())
	if perf_seconds > 0.0:
		_perf_tick()
	var now := Time.get_ticks_msec()
	if now - _last_title > 250 and not Launch.hosting():
		_last_title = now
		if show_time and interactive:
			root.title = "巴格达旅人 · %s%s" % [_state.phase, "（暂停）" if clock_paused else ""]
		elif show_time:
			root.title = "巴格达旅人 · %s  %.1f / %.0f 秒%s  ·  R 重播  P 暂停  1–4 跳段  H 隐藏" % [_state.phase, float(_state.cycle_t), float(_state.cycle_seconds), "（暂停）" if clock_paused else ""]
		else:
			root.title = "巴格达旅人"

## 性能模式（--cycle-perf=秒）：不锁帧跑满一个或多个循环，按阶段统计帧间隔 p50 / p95，然后退出。
func _perf_tick() -> void:
	var now := Time.get_ticks_usec()
	if _perf_last != 0 and clock() > 3.0:
		var key := str(_state.phase)
		if not _perf.has(key):
			_perf[key] = []
		(_perf[key] as Array).append(float(now - _perf_last) / 1000.0)
	_perf_last = now
	if clock() >= perf_seconds:
		var out := {}
		for key in _perf:
			var arr: Array = _perf[key]
			arr.sort()
			out[key] = {"frames": arr.size(), "p50_ms": arr[int(arr.size() * 0.5)], "p95_ms": arr[int(arr.size() * 0.95)], "max_ms": arr[arr.size() - 1]}
		print("BAGHDAD_CYCLE_PERF ", JSON.stringify(out))
		Launch.finish(get_tree(), 0)

func _on_input(event: InputEvent) -> void:
	if ready_state and event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		print("BAGHDAD_CYCLE_MOUSE_WINDOW ", JSON.stringify({"pos": [event.position.x, event.position.y]}))
	if not ready_state or not event is InputEventKey:
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	var key := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
	if not ActExit.dev_keys_allowed() and key != KEY_SPACE:
		return   # 从开场进来：R / P / 1 2 3 / H 这些审片键不开（夜测 TRV-11）；H、Esc 交给 act_exit_button
	var t: Dictionary = cfg.timeline
	var t1 := float(t.bloom_story_seconds)
	var t2 := t1 + float(t.to_dusk_seconds)
	var t3 := t2 + float(t.dusk_hold_seconds)
	if interactive:
		match key:
			KEY_SPACE:
				advance(clock())
			KEY_R, KEY_1:
				jump_to("rain")
			KEY_2:
				jump_to("bloom")
			KEY_3:
				jump_to("dusk")
			KEY_P:
				set_clock(clock())
				clock_paused = not clock_paused
			KEY_H:
				show_time = not show_time
			_:
				return
		root.set_input_as_handled()
		return
	var cycle_start := clock() - fposmod(clock(), _cycle_length())
	match key:
		KEY_R, KEY_1:
			set_clock(cycle_start + _cycle_length())
		KEY_2:
			set_clock(cycle_start + t1)
		KEY_3:
			set_clock(cycle_start + t2)
		KEY_4:
			set_clock(cycle_start + t3)
		KEY_P:
			set_clock(clock())
			clock_paused = not clock_paused
		KEY_H:
			show_time = not show_time
		_:
			return
	root.set_input_as_handled()

func _capture_stills() -> void:
	DirAccess.make_dir_recursive_absolute(stills_dir)
	var report: Array = []
	for t in still_times:
		# 从 t-1.5 s 起逐帧推进到 t，让体积雾 / SDFGI / 粒子有历史，再截图
		var steps := 45
		for i in steps:
			var tt := t - 1.5 + 1.5 * float(i + 1) / float(steps)
			apply_time(maxf(tt, 0.0))
			vp_a.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			vp_b.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			await RenderingServer.frame_post_draw
		var img := vp_mix.get_texture().get_image()
		var path := stills_dir.path_join("cycle_%05.1f.png" % t)
		img.save_png(path)
		report.append({"t": t, "file": path.get_file(), "state": _state, "story": story_a.call("evidence")})
		print("BAGHDAD_CYCLE_STILL ", path)
	var f := FileAccess.open(stills_dir.path_join("stills.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "\t"))
	f.close()
	Launch.finish(get_tree(), 0)

## 录像（--cycle-video=<目录> [--cycle-video-seconds=N]，要配合 Godot 的 --fixed-fps 30）：
## 每帧把时钟设为 帧号/30 秒，逐帧存 JPEG，默认录一整轮。TIME、粒子、树风的 delta 由 --fixed-fps 保证同样按 1/30 s 推进。
func _capture_video() -> void:
	DirAccess.make_dir_recursive_absolute(video_dir)
	var seconds := video_seconds if video_seconds > 0.0 else _cycle_length()
	var frames := int(round(seconds * 30.0))
	for i in 90:
		apply_time(0.0)
		vp_a.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp_b.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		await RenderingServer.frame_post_draw
	var last_hash := 0
	var repeats := 0
	var started := Time.get_ticks_msec()
	for f in frames:
		apply_time(float(f) / 30.0)
		await RenderingServer.frame_post_draw
		var img := vp_mix.get_texture().get_image()
		var h := hash(img.get_data())
		if h == last_hash:
			repeats += 1
		last_hash = h
		img.save_jpg(video_dir.path_join("f_%04d.jpg" % f), 0.95)
		if (f + 1) % 150 == 0:
			print("BAGHDAD_CYCLE_VIDEO_PROGRESS %d/%d  %.0fs" % [f + 1, frames, float(Time.get_ticks_msec() - started) / 1000.0])
	print("BAGHDAD_CYCLE_VIDEO_DONE ", JSON.stringify({"frames": frames, "seconds": seconds, "repeated_frames": repeats, "dir": video_dir}))
	Launch.finish(get_tree(), 0)

## 自测（--cycle-selftest=<目录>）：用 Viewport.push_input 模拟真实鼠标点击（走 GUI 路由），
## 检查点空白不响应、点土豆触发、切换中点击不响应，并在三个状态和过渡中途截图。时钟由自测手动推进。
func _selftest() -> void:
	DirAccess.make_dir_recursive_absolute(selftest_dir)
	var log := []
	clock_paused = true
	var t := 5.0
	set_clock(t)
	await _settle(t)
	var r := potato_rect()
	log.append({"step": "rain_idle", "state": i_state, "potato_rect_px": [r.position.x, r.position.y, r.size.x, r.size.y]})
	_snap("1_rain_idle", log)
	_click_px(Vector2(300, 300))
	log.append({"step": "click_empty_sky", "state": i_state, "trans": i_trans, "ok": i_trans == ""})
	_hover_px(r.get_center())
	log.append({"step": "hover_potato", "cursor_hand": preview.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND})
	_click_px(r.get_center())
	log.append({"step": "click_potato", "trans": i_trans, "ok": i_trans == "to_bloom"})
	t += 4.0
	await _settle(t)
	_snap("2_to_bloom_4s", log)
	_click_px(potato_rect().get_center())
	log.append({"step": "click_during_transition", "trans": i_trans, "ok": i_trans == "to_bloom"})
	t += 5.0
	await _settle(t)
	log.append({"step": "bloom_idle", "state": i_state, "ok": i_state == "bloom" and i_trans == ""})
	_snap("3_bloom_idle", log)
	_click_px(potato_rect().get_center())
	log.append({"step": "click_potato_2", "trans": i_trans, "ok": i_trans == "to_dusk"})
	t += 4.0
	await _settle(t)
	_snap("4_to_dusk_4s", log)
	t += 5.0
	await _settle(t)
	log.append({"step": "dusk_idle", "state": i_state, "ok": i_state == "dusk" and i_trans == ""})
	_snap("5_dusk_idle", log)
	var rd := potato_rect()
	log.append({"step": "dusk_potato_rect", "potato_rect_px": [rd.position.x, rd.position.y, rd.size.x, rd.size.y]})
	_click_px(rd.get_center())
	log.append({"step": "click_potato_3", "trans": i_trans, "ok": i_trans == "to_rain"})
	t += 2.0
	await _settle(t)
	_snap("6_to_rain_2s", log)
	t += 3.0
	await _settle(t)
	log.append({"step": "rain_again", "state": i_state, "loops": i_loops, "ok": i_state == "rain" and i_trans == ""})
	_snap("7_rain_again", log)
	var f := FileAccess.open(selftest_dir.path_join("selftest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(log, "\t"))
	f.close()
	print("BAGHDAD_CYCLE_SELFTEST ", JSON.stringify(log))
	Launch.finish(get_tree(), 0)

func _settle(t: float) -> void:
	# 从 t-1.2 s 逐帧推进到 t（时钟单调递增），让体积雾 / 粒子有历史
	for i in 36:
		var tt := t - 1.2 + 1.2 * float(i + 1) / 36.0
		set_clock(maxf(tt, clock_base))
		apply_time(clock())
		await RenderingServer.frame_post_draw

func _snap(snap_name: String, log: Array) -> void:
	var img := vp_mix.get_texture().get_image()
	var r := potato_rect()
	img.save_png(selftest_dir.path_join(snap_name + ".png"))
	log.append({"snap": snap_name, "state": i_state, "trans": i_trans, "potato_rect_px": [r.position.x, r.position.y, r.size.x, r.size.y]})

func _to_viewport(px: Vector2) -> Vector2:
	return preview.get_global_transform_with_canvas() * from_frame_px(px)

func _click_px(px: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		if selftest_os:
			ev.position = root.get_final_transform() * _to_viewport(px)
			ev.global_position = ev.position
			Input.parse_input_event(ev)
			Input.flush_buffered_events()
		else:
			ev.position = _to_viewport(px)
			ev.global_position = ev.position
			root.push_input(ev, true)

func _hover_px(px: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	if selftest_os:
		ev.position = root.get_final_transform() * _to_viewport(px)
		ev.global_position = ev.position
		Input.parse_input_event(ev)
		Input.flush_buffered_events()
	else:
		ev.position = _to_viewport(px)
		ev.global_position = ev.position
		root.push_input(ev, true)

func _fail(message: String) -> void:
	push_error("BAGHDAD_CYCLE_FAIL " + message)
	print("BAGHDAD_CYCLE_FAIL ", message)
	Launch.finish(get_tree(), 1)
