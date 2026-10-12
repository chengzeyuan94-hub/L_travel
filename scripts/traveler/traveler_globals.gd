extends RefCounted
## 一幕开在开场同一个窗口里（scripts/traveler/traveler_host.gd）时它可能改动的全局设置：进场前 snapshot()，回开场后 restore()，
## 测试拿 diff() 逐项比。以前每一幕是单独的进程，改了什么进程一退就没了；现在是同一个进程，下面这些都得原样还原：
##   engine/*   Engine.max_fps（各幕锁 30 帧、单独测帧时 0）、物理帧率、time_scale …
##   os/*       省电模式
##   display/*  垂直同步（各幕改过）
##   root/*     根窗口 / 根视口所有能存的属性逐项比：3D 缩放、MSAA、TAA、屏幕空间抗锯齿、去色带、阴影图集、标题、置顶 …
##              （长安改 MSAA / TAA，找 L叔 改去色带 / TAA / 阴影图集，巴格达单独开时改标题栏）。
##              窗口模式、大小、位置、所在屏幕只记不还原（REPORT_ONLY）：一幕开着时玩家自己拖窗口、切全屏，回来就该是那样；
##              各幕开在开场窗口里时一律不碰窗口，测试断言这几项进出前后相等。
##   world3d/*  根视口的 3D 世界（traveler_host.gd 给每一幕换一个新的，回来换回原来的）
##   rs/*       渲染器全局：render_globals.gd 记着的阴影 / 景深 / 体积雾 / SSAO 画质（没有读取接口）、默认清屏色
##   ps/*       运行时改过的项目设置（长安改方向光阴影图集大小）
##   audio/*    每条总线的名字、音量、静音、独奏、旁通、送往、效果开关，总线数，全局播放速度
##   input/*    鼠标模式、默认光标（热点上的小手）
##   tree/*     SceneTree 的暂停、自动接受退出

const RenderGlobals := preload("res://scripts/traveler/render_globals.gd")
const Launch := preload("res://scripts/traveler/traveler_launch.gd")

## 根窗口里只记、不还原的属性
const REPORT_ONLY: Array[String] = ["root/mode", "root/size", "root/position", "root/current_screen"]
## 根窗口里不比的属性（脚本本身、每帧会变的）
const ROOT_SKIP: Array[String] = ["script", "canvas_transform", "global_canvas_transform"]
## 运行时可能被改的项目设置
const PS_KEYS: Array[String] = ["rendering/lights_and_shadows/directional_shadow/size"]
const ROOT_TYPES: Array[int] = [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME, TYPE_VECTOR2, TYPE_VECTOR2I,
	TYPE_RECT2, TYPE_RECT2I, TYPE_COLOR, TYPE_OBJECT]


static func snapshot(tree: SceneTree) -> Dictionary:
	var s := {}
	s["engine/max_fps"] = Engine.max_fps
	s["engine/physics_ticks_per_second"] = Engine.physics_ticks_per_second
	s["engine/max_physics_steps_per_frame"] = Engine.max_physics_steps_per_frame
	s["engine/time_scale"] = Engine.time_scale
	s["engine/physics_jitter_fix"] = Engine.physics_jitter_fix
	s["os/low_processor_usage_mode"] = OS.low_processor_usage_mode
	s["os/low_processor_usage_mode_sleep_usec"] = OS.low_processor_usage_mode_sleep_usec
	s["display/vsync"] = DisplayServer.window_get_vsync_mode()
	var root := tree.root
	for p: Dictionary in root.get_property_list():
		var pname := str(p.name)
		if ROOT_SKIP.has(pname) or not ROOT_TYPES.has(int(p.type)):
			continue
		if (int(p.usage) & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR)) == 0:
			continue
		s["root/" + pname] = root.get(pname)
	var w: World3D = root.world_3d
	s["world3d/environment"] = w.environment if w != null else null
	s["world3d/fallback_environment"] = w.fallback_environment if w != null else null
	s["world3d/camera_attributes"] = w.camera_attributes if w != null else null
	var rg: Dictionary = RenderGlobals.state()
	for k: String in rg:
		s["rs/" + k] = rg[k]
	s["rs/default_clear_color"] = RenderingServer.get_default_clear_color()
	# 全局着色器参数：读取接口只许在编辑器里用（运行时调会报错），项目里也没有声明任何一个（project.godot 没有 [shader_globals]），
	# 各幕也不加（grep global_shader_parameter：没有），所以不记
	for k: String in PS_KEYS:
		s["ps/" + k] = ProjectSettings.get_setting(k)
	s["audio/bus_count"] = AudioServer.bus_count
	s["audio/playback_speed_scale"] = AudioServer.playback_speed_scale
	for i in AudioServer.bus_count:
		var fx: Array = []
		for e in AudioServer.get_bus_effect_count(i):
			var eff: AudioEffect = AudioServer.get_bus_effect(i, e)
			fx.append([eff.get_class() if eff != null else "", AudioServer.is_bus_effect_enabled(i, e)])
		s["audio/bus/%d" % i] = {"name": str(AudioServer.get_bus_name(i)), "volume_db": AudioServer.get_bus_volume_db(i),
			"mute": AudioServer.is_bus_mute(i), "solo": AudioServer.is_bus_solo(i), "bypass": AudioServer.is_bus_bypassing_effects(i),
			"send": str(AudioServer.get_bus_send(i)), "effects": fx}
	s["input/mouse_mode"] = Input.mouse_mode
	s["input/cursor_hand"] = Launch.cursor_hand
	s["tree/paused"] = tree.paused
	s["tree/auto_accept_quit"] = tree.auto_accept_quit
	return s


## 把现在和 snap 不一样的项一项项设回去（REPORT_ONLY 的只报告）；返回动过的项名（带 REPORT_ONLY 的前缀「report:」）
static func restore(tree: SceneTree, snap: Dictionary) -> Array[String]:
	var changed: Array[String] = []
	var now := snapshot(tree)
	for k: String in diff(snap, now):
		if REPORT_ONLY.has(k):
			changed.append("report:" + k)
			continue
		changed.append(k)
		var v: Variant = snap.get(k)
		if k.begins_with("root/"):
			tree.root.set(k.trim_prefix("root/"), v)
		elif k.begins_with("engine/"):
			Engine.set(k.trim_prefix("engine/"), v)
		elif k.begins_with("os/"):
			OS.set(k.trim_prefix("os/"), v)
		elif k == "display/vsync":
			DisplayServer.window_set_vsync_mode(int(v) as DisplayServer.VSyncMode)
		elif k.begins_with("world3d/"):
			if tree.root.world_3d != null:
				tree.root.world_3d.set(k.trim_prefix("world3d/"), v)
		elif k == "rs/default_clear_color":
			RenderingServer.set_default_clear_color(v as Color)
		elif k.begins_with("rs/"):
			pass   # 下面 RenderGlobals.restore 一起做
		elif k.begins_with("ps/"):
			ProjectSettings.set_setting(k.trim_prefix("ps/"), v)
		elif k.begins_with("audio/"):
			pass   # 下面 _restore_audio 一起做
		elif k == "input/mouse_mode":
			Input.mouse_mode = int(v) as Input.MouseMode
		elif k == "input/cursor_hand":
			Launch.cursor_hand = bool(v)
			Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if bool(v) else Input.CURSOR_ARROW)
		elif k.begins_with("tree/"):
			tree.set(k.trim_prefix("tree/"), v)
	var rg := {}
	for k: String in snap:
		if k.begins_with("rs/") and k != "rs/default_clear_color":
			rg[k.trim_prefix("rs/")] = snap[k]
	RenderGlobals.restore(rg)
	_restore_audio(snap)
	return changed


## 两份快照里值不一样的项（一边有一边没有也算）
static func diff(a: Dictionary, b: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for k: String in a:
		if not b.has(k) or not _same(a[k], b[k]):
			out.append(k)
	for k: String in b:
		if not a.has(k):
			out.append(k)
	return out


## 给日志 / 测试看的差异：{项: [之前, 现在]}
static func describe(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	for k in diff(a, b):
		out[k] = [str(a.get(k, "<none>")), str(b.get(k, "<none>"))]
	return out


static func _same(x: Variant, y: Variant) -> bool:
	if typeof(x) == TYPE_OBJECT or typeof(y) == TYPE_OBJECT:
		return typeof(x) == typeof(y) and x == y
	if typeof(x) == TYPE_FLOAT and typeof(y) == TYPE_FLOAT:
		return is_equal_approx(x, y)
	if typeof(x) != typeof(y):
		return JSON.stringify(x) == JSON.stringify(y)
	return x == y


static func _restore_audio(snap: Dictionary) -> void:
	var want := int(snap.get("audio/bus_count", AudioServer.bus_count))
	# 这一幕开着时新建的总线（正式运行时总线开场就建好了，不会有；测试 / 无声驱动下可能有）先删掉，再按名字对回去
	while AudioServer.bus_count > want and AudioServer.bus_count > 1:
		AudioServer.remove_bus(AudioServer.bus_count - 1)
	if snap.has("audio/playback_speed_scale") and AudioServer.playback_speed_scale != float(snap["audio/playback_speed_scale"]):
		AudioServer.playback_speed_scale = float(snap["audio/playback_speed_scale"])
	for i in mini(want, AudioServer.bus_count):
		var b: Dictionary = snap.get("audio/bus/%d" % i, {})
		if b.is_empty():
			continue
		if str(AudioServer.get_bus_name(i)) != str(b.name):
			AudioServer.set_bus_name(i, str(b.name))
		if not is_equal_approx(AudioServer.get_bus_volume_db(i), float(b.volume_db)):
			AudioServer.set_bus_volume_db(i, float(b.volume_db))
		if AudioServer.is_bus_mute(i) != bool(b.mute):
			AudioServer.set_bus_mute(i, bool(b.mute))
		if AudioServer.is_bus_solo(i) != bool(b.solo):
			AudioServer.set_bus_solo(i, bool(b.solo))
		if AudioServer.is_bus_bypassing_effects(i) != bool(b.bypass):
			AudioServer.set_bus_bypass_effects(i, bool(b.bypass))
		if str(AudioServer.get_bus_send(i)) != str(b.send):
			AudioServer.set_bus_send(i, StringName(str(b.send)))
		var fx: Array = b.effects
		for e in mini(fx.size(), AudioServer.get_bus_effect_count(i)):
			if AudioServer.is_bus_effect_enabled(i, e) != bool(fx[e][1]):
				AudioServer.set_bus_effect_enabled(i, e, bool(fx[e][1]))


## 声音现状：各总线静音 / 峰值，act 下面每个播放器走哪条总线、在不在放（测试和 --lshu-audio-probe 用）
static func audio_state(act: Node) -> Dictionary:
	var buses := {}
	for i in AudioServer.bus_count:
		buses[str(AudioServer.get_bus_name(i))] = {"mute": AudioServer.is_bus_mute(i),
			"peak_db": snappedf(maxf(AudioServer.get_bus_peak_volume_left_db(i, 0), AudioServer.get_bus_peak_volume_right_db(i, 0)), 0.1)}
	var players: Array = []
	if act != null and is_instance_valid(act):
		for cls: String in ["AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D"]:
			for p: Node in act.find_children("*", cls, true, false):
				players.append({"name": str(p.name), "bus": str(p.get("bus")), "playing": bool(p.get("playing"))})
	return {"buses": buses, "players": players, "hosted": Launch.hosting()}
