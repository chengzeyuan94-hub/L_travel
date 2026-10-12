extends CanvasLayer
## 旅人模式每一幕共用的克制界面（2026-09-27 Carlos：「旅人模式进入之后就无法退出」；当晚夜测 TRV-2~12、TL-3~7、LSHU-2/11 一起修）。
## 两种开法，这一层都一样：
##   · 从开场「进入」（2026-09-27 Carlos 起：开在开场同一个窗口里，不另起进程，scripts/traveler/traveler_host.gd）：
##     开场先建好这一层（hosted = true，载入卡盖住开场），再读这一幕的场景；这一幕 attach() 时拿到的就是这一层。
##   · 单独开：带 --lshu-act（或 --lshu-act=<幕 id>）启动（正式包 -- --lshu-act=<id>、tools/open_*_traveler.command、冒烟）。
##   截图、录像、测帧等工具单独开某一幕时不带这个参数，画面里什么都不多。
## 这一幕的参数一律经 scripts/traveler/traveler_launch.gd 读（开在开场里时是开场给的，单独开时是命令行）。
##   · 左上角「‹ 返回」小药丸 + Esc：先按关窗口的流程通知这一幕（找 L叔 在这时存进度），再回开场（开在开场里）或结束进程（单独开）。
##     安卓（触屏防误触开着）：药丸和手柄 B 一样两步——第一下只提示「再点一次「返回」」（载入卡盖着时也提示），停一下再点才回（_on_pill_pressed）。
##     Esc 走 _unhandled_key_input，而且这一层在这一幕前面（单独开：挂在这一幕根节点的最前面；开在开场里：在根下、这一幕之前），
##     最后一个收到未处理按键：明信片 / 旅行本开着时 Esc 先把它们收起来，再按一次才离开（夜测 LSHU-2）。
##   · 底部正中一行操作提示（读正文圆体）：这一幕就绪后显示 6 秒，一动鼠标再出来，不动就淡出；H 关掉 / 打开，
##     选择存在 ShanheLvren/traveler_settings.json（和 progress.json 同一个目录），下次进来还记得。
##   · 就绪前盖一张「L叔在收拾行李…」的载入卡（巴格达冷启动要十几秒、找 L叔 第一次要编译着色器），就绪后淡出；盖着时挡住鼠标。
##     各幕在真正能看、能点的时候调 mark_ready()；返回药丸的计时也从那时开始（夜测 TRV-12、LSHU-11）。
##     开在开场里时：进场从开场的选幕页淡入这张卡，离开时 show_cover() 再盖回来，回到开场后淡出。
##   · 帧率：屏保一样挂着的场景不需要跑满——开垂直同步、锁 30 帧（夜测 TRV-7；找 L叔 有自己的帧率策略，挂的时候关掉 manage_fps）。
##     开在开场里时回开场由 traveler_host.gd 把帧率、垂直同步等全局设置还原。
## 调试键（盘橐空格冻结、巴格达 P 暂停 / 1 2 3 跳段 等）在幕模式下只有再带 --lshu-dev 才开（dev_keys_allowed()）。
## 冒烟测试（正式包导出后逐幕跑，tools/traveler/release_act_smoke.sh）：--lshu-act-smoke 就绪后 4 秒、16 秒各调一次
## 这一幕的 act_poke()（点城门 / 篝火 / 土豆），--lshu-act-smoke-quit=<秒> 就绪后到点按「返回」同样的流程退出，
## --lshu-act-shot=<绝对路径.png>,<秒>,... 到点存整窗截图（数字 = 就绪后几秒；l 开头 = 启动后几秒，拍载入卡）。

const FLAG := "--lshu-act"
const DEV_FLAG := "--lshu-dev"
const IDLE_FADE_SEC := 3.0
const HINT_SHOW_SEC := 6.0
const REST_ALPHA := 0.82
const HINT_ALPHA := 0.9
const ACT_FPS := 30
const SETTINGS_FILE := "traveler_settings.json"
const LOADING_TEXT := "L叔在收拾行李"
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const Progress := preload("res://scripts/lshu_ui/lshu_progress.gd")
const Launch := preload("res://scripts/traveler/traveler_launch.gd")
const Pad := preload("res://scripts/pad/pad_input.gd")

## 这一幕能看、能点了（mark_ready 之后）
signal act_ready

## 这一幕的 id（changan / panti / baghdad / lshu），决定底部提示那一行
var act_id := ""
## false：这一幕自己管帧率（找 L叔 的导演：前台 30、后台 10）
var manage_fps := true
## 这一幕自己的界面开着（找 L叔 的明信片、旅行本）：底部提示先不出来，免得叠在上面
var busy := false
## 这一幕的根节点（冒烟测试调它的 act_poke()）
var host: Node
var hints_hidden := false
## true：开在开场同一个窗口里（traveler_host.gd 建的）：不碰窗口，离开时回开场而不是退出进程
var hosted := false
## 开在开场里时载入卡从 0 淡入的秒数（从选幕页盖过来）；0 = 一出来就盖满
var cover_in := 0.0
## 开在开场里、要放入场片时（traveler_host.gd）：就绪后载入卡先不撤，等入场片盖满后 release_cover()，
## 片尾入场片叠化进的就是这一幕的实时画面（载入卡撤早了，片子淡入那 0.4 秒会露出这一幕）
var hold_cover := false

var _root: Control
var _btn: Button
var _hint: PanelContainer
var _hint_label: Label
var _hint_text := ""
var _loading: Control
var _loading_label: Label
var _walker: TextureRect
var _idle := 0.0
var _since_ready := 0.0
## 底部提示重新计时的起点（入场片播完 replay_hint()：提示的 6 秒在片子底下已经过去了）
var _hint_from := 0.0
var _alpha := 1.0
var _hint_alpha := 0.0
var _toast := ""
var _toast_left := 0.0
## 这条提示在载入卡盖着时也要出（安卓「再点一次返回」）；H 的「提示已关」还是只在就绪后出，和以前一样
var _toast_early := false
var _leaving := false
var _is_ready := false
var _loading_t := 0.0
var _smoke_pokes: Array[float] = []
## --lshu-audio-probe：就绪后每秒一行 LSHU_AUDIO_PROBE（各总线静音 / 峰值、这一幕的播放器走哪条总线）；Movie Maker 录着量静音键
var _audio_probe := false
var _probe_t := 0.0
var _smoke_quit := -1.0
var _shot_base := ""
var _shots: Array[String] = []
var _t_total := 0.0
var _ready_msec := 0
var _ready_frames := 0


# ------------------------------------------------------------------ 参数
## 开在开场窗口里的一幕，或带 --lshu-act / --lshu-act=<id> 启动的，就是「从开场进来的一幕」
static func is_act() -> bool:
	if Launch.hosting():
		return true
	for a: String in Launch.user_args():
		if a == FLAG or a.begins_with(FLAG + "="):
			return true
	return false


## --lshu-act=<id> 里的 id；只带 --lshu-act 时是空串
static func act_id_from_args() -> String:
	for a: String in Launch.user_args():
		if a.begins_with(FLAG + "="):
			return a.trim_prefix(FLAG + "=")
	return ""


## 调试 / 审片用的按键能不能用：单独开某一幕（工具、截图）时照旧能用；从开场进来的一幕要再带 --lshu-dev
static func dev_keys_allowed() -> bool:
	return not is_act() or DEV_FLAG in Launch.user_args()


## 鼠标在这一幕能点的东西上（城门、篝火、土豆）时变成小手（回开场时 traveler_globals.gd 换回箭头）
static func set_hotspot_cursor(on: bool) -> void:
	if Launch.cursor_hand == on:
		return
	Launch.cursor_hand = on
	Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if on else Input.CURSOR_ARROW)


## 在这一幕的根节点下挂一个（挂在最前面，见文件头）；没带 --lshu-act 时什么都不做，返回 null。
## 开在开场窗口里时这一层已经在了（traveler_host.gd 先建的），直接把它交给这一幕。
## default_id：只带 --lshu-act 没写 id 时用哪一幕的提示
static func attach(host: Node, default_id: String = "") -> Node:
	var existing: Node = Launch.overlay()
	if existing != null:
		existing.set("host", host)
		if str(existing.get("act_id")) == "":
			existing.set("act_id", default_id)
		return existing
	if not is_act():
		return null
	var layer: CanvasLayer = load("res://scripts/traveler/act_exit_button.gd").new()
	layer.name = "ActExitButton"
	var id := act_id_from_args()
	layer.set("act_id", id if id != "" else default_id)
	layer.set("host", host)
	host.add_child.call_deferred(layer)
	(func() -> void:
		if layer.get_parent() == host:
			host.move_child(layer, 0)).call_deferred()
	return layer


# ------------------------------------------------------------------ 搭界面
func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	hints_hidden = bool(_read_settings().get("hints_hidden", false))
	for a: String in Launch.user_args():
		if a == "--lshu-act-smoke":
			_smoke_pokes = [4.0, 16.0]
		elif a.begins_with("--lshu-act-smoke-quit="):
			_smoke_quit = float(a.trim_prefix("--lshu-act-smoke-quit="))
		elif a == "--lshu-audio-probe":
			_audio_probe = true
		elif a.begins_with("--lshu-act-shot="):
			var parts := a.trim_prefix("--lshu-act-shot=").split(",", false)
			_shot_base = parts[0].trim_suffix(".png")
			for i in range(1, parts.size()):
				_shots.append(parts[i])
	_root = Control.new()
	_root.name = "ActOverlay"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_loading()
	_build_hint()
	_build_back()
	_apply_fps()
	# 单独开的新窗口有时出来在别的窗口后面、拿不到键盘（夜测 TL-4）；macOS 不画被挡住的窗口，巴格达会一直卡在载入。
	# 开在开场窗口里时一律不碰窗口
	if DisplayServer.get_name() != "headless" and not hosted:
		DisplayServer.window_move_to_foreground()
		if "--lshu-act-on-top" in Launch.user_args():
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)   # 截图验证用：别的窗口挡不住
	if hosted and cover_in > 0.0:
		_loading.modulate.a = 0.0
		_loading.create_tween().tween_property(_loading, "modulate:a", 1.0, cover_in).set_trans(Tween.TRANS_SINE)
	print("LSHU_ACT_OVERLAY ", JSON.stringify({"act": act_id, "hint": _hint_label.text, "hints_hidden": hints_hidden, "hosted": hosted}))
	var pad_hub := get_node_or_null("/root/PadInput")
	if pad_hub != null:
		pad_hub.register(self, PAD_PRIORITY)
	if _is_ready:
		_on_act_ready()


func _pill(bg_alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Kit.CREAM, bg_alpha)
	sb.border_color = Color(Kit.SATCHEL, 0.55)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(18)
	sb.content_margin_left = 16
	sb.content_margin_right = 18
	sb.content_margin_top = 6
	sb.content_margin_bottom = 7
	sb.shadow_color = Color(0.15, 0.08, 0.03, 0.18)
	sb.shadow_size = 4
	sb.anti_aliasing = true
	return sb


func _build_back() -> void:
	_btn = Button.new()
	_btn.name = "BackToTitle"
	_btn.text = "‹ 返回"
	_btn.tooltip_text = "回到开场（Esc）"
	_btn.focus_mode = Control.FOCUS_NONE
	_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_btn.add_theme_font_override("font", Kit.font("body", 700))
	_btn.add_theme_font_size_override("font_size", 18)
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		_btn.add_theme_color_override(key, Kit.INK)
	for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
		_btn.add_theme_stylebox_override(state, _pill(0.72 if state == "normal" or state == "focus" else 0.94))
	_btn.position = Vector2(18, 16)
	_btn.pressed.connect(_on_pill_pressed)
	_root.add_child(_btn)


func _build_hint() -> void:
	_hint = PanelContainer.new()
	_hint.name = "ActHint"
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := _pill(0.8)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 8
	sb.content_margin_bottom = 9
	_hint.add_theme_stylebox_override("panel", sb)
	_hint_label = Label.new()
	_hint_label.name = "HintText"
	_hint_text = str(Progress.act_info(act_id).get("hint", ""))
	_hint_label.text = _hint_text
	_hint_label.add_theme_font_override("font", Kit.font("body", 700))
	_hint_label.add_theme_font_size_override("font_size", 19)
	_hint_label.add_theme_color_override("font_color", Kit.INK)
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_child(_hint_label)
	_hint.anchor_left = 0.5
	_hint.anchor_right = 0.5
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint.offset_bottom = -26
	_hint.modulate.a = 0.0
	_root.add_child(_hint)


## 载入卡：暖深色底 + 正中一张奶油色小卡（走路招手的 L叔 + 「L叔在收拾行李…」）
func _build_loading() -> void:
	_loading = Control.new()
	_loading.name = "ActLoading"
	_loading.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_loading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.color = Color("#2B2420")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP   # 盖着时挡住下面（开场、还没就绪的这一幕）的点击；「‹ 返回」在它上面照样能点
	_loading.add_child(bg)
	var card := PanelContainer.new()
	card.name = "LoadingCard"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Kit.CREAM
	sb.border_color = Kit.SATCHEL
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(26)
	sb.content_margin_left = 26
	sb.content_margin_right = 34
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	sb.shadow_color = Color(0, 0, 0, 0.3)
	sb.shadow_size = 12
	sb.shadow_offset = Vector2(0, 4)
	sb.anti_aliasing = true
	card.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_walker = TextureRect.new()
	_walker.name = "Walker"
	var tex_path := "res://assets/game/ui/lshu_loading/lshu_walk.png"
	if ResourceLoader.exists(tex_path):
		_walker.texture = load(tex_path)
	_walker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_walker.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_walker.custom_minimum_size = Vector2(52, 96)
	_walker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_walker)
	_loading_label = Label.new()
	_loading_label.name = "LoadingText"
	_loading_label.text = LOADING_TEXT + "…"
	_loading_label.custom_minimum_size = Vector2(250, 0)
	_loading_label.add_theme_font_override("font", Kit.font("body", 700))
	_loading_label.add_theme_font_size_override("font_size", 24)
	_loading_label.add_theme_color_override("font_color", Kit.INK)
	_loading_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_loading_label)
	card.add_child(row)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	_loading.add_child(card)
	_root.add_child(_loading)


# ------------------------------------------------------------------ 就绪
## 这一幕能看、能点了（各幕自己调；在 _ready 之前调也行）
func mark_ready() -> void:
	if _is_ready:
		return
	_is_ready = true
	if is_node_ready():
		_on_act_ready()


func is_act_ready() -> bool:
	return _is_ready


## 载入卡现在是不是盖着（完全不透明）
func is_covered() -> bool:
	return _loading != null and _loading.visible and _loading.modulate.a > 0.99


func _on_act_ready() -> void:
	_idle = 0.0
	_since_ready = 0.0
	_ready_msec = Time.get_ticks_msec()
	_ready_frames = Engine.get_frames_drawn()
	_apply_fps()
	if not _leaving and not hold_cover:
		_fade_loading(0.0, 0.7)
	print("LSHU_ACT_READY ", JSON.stringify({"act": act_id, "msec": Time.get_ticks_msec(), "max_fps": Engine.max_fps, "vsync": DisplayServer.window_get_vsync_mode(), "hosted": hosted}))
	act_ready.emit()


## 开在开场里离开时：载入卡盖回来（sec 秒淡入），回到开场后 uncover() 淡出
func show_cover(sec: float = 0.25) -> void:
	if _loading == null:
		return
	_leaving = true
	_btn.visible = false
	_hint.visible = false
	_fade_loading(1.0, sec)


func uncover(sec: float = 0.35) -> void:
	_fade_loading(0.0, sec)


## 入场片已经盖满（或跳过 / 播不了）：载入卡撤掉，sec = 0 立刻撤
func release_cover(sec: float = 0.0) -> void:
	hold_cover = false
	if _is_ready and not _leaving:
		_fade_loading(0.0, sec)


## 入场片播完：「‹ 返回」和底部提示再出来一次（就绪后那 6 秒在片子底下已经过去了）
func replay_hint() -> void:
	_idle = 0.0
	_hint_from = _since_ready


var _loading_tw: Tween


func _fade_loading(to: float, sec: float) -> void:
	if _loading_tw != null and _loading_tw.is_valid():
		_loading_tw.kill()
	if to > 0.0:
		_loading.visible = true
	_loading_tw = _loading.create_tween()
	_loading_tw.tween_property(_loading, "modulate:a", to, maxf(0.01, sec)).set_trans(Tween.TRANS_SINE)
	if to <= 0.0:
		_loading_tw.tween_callback(func() -> void: _loading.visible = false)


func _apply_fps() -> void:
	if not manage_fps:
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	Engine.max_fps = ACT_FPS


# ------------------------------------------------------------------ 输入
## 「‹ 返回」被点。桌面：点一下就回开场（和以前一样）。
## 安卓（触屏防误触开着，scripts/pad/pad_input.gd touch_guards）：和手柄的 B 一样两步——第一下只叫出「再点一次返回」，
## 停一下（离上一下 ≥ 0.4 秒）、3 秒内再点才回开场；一直连点不算（安卓压力测试 TS-4）。载入卡盖着时也一样（那时也可能要出去：
## 这一幕读不出来时这是唯一的出口），提示也照样出。系统取消的触摸（手掌误触、拉通知栏）松开时不算点（TS-3）
func _on_pill_pressed() -> void:
	if not Pad.guards_on(self):
		leave("pill")
		return
	if Pad.canceled_press(self):
		return
	_idle = 0.0
	var now := Time.get_ticks_msec()
	var armed := pad_armed()
	var calm := now - _pad_last_press >= PAD_CALM_MS
	_pad_last_press = now
	if armed and calm:
		leave("pill")
		return
	_pad_armed_at = now
	_toast = "再点一次「返回」，回到开场"
	_toast_left = PAD_ARM_MS / 1000.0
	_toast_early = true


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventScreenTouch:
		_idle = 0.0
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		_idle = 0.0


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		leave("esc")
	elif k.keycode == KEY_H:
		get_viewport().set_input_as_handled()
		set_hints_hidden(not hints_hidden)


func set_busy(on: bool) -> void:
	busy = on


func set_hints_hidden(on: bool) -> void:
	hints_hidden = on
	_write_settings({"hints_hidden": hints_hidden})
	_toast = "提示已关，按 H 再打开" if on else ""
	_toast_early = false
	_toast_left = 2.5 if on else 0.0
	_since_ready = 0.0
	_hint_from = 0.0
	_idle = 0.0
	print("LSHU_ACT_HINTS ", JSON.stringify({"hidden": hints_hidden}))


# ------------------------------------------------------------------ 手柄（scripts/pad/pad_input.gd 的一个上下文）
## B：先叫出「‹ 返回」药丸并框住它（底部闪一句「再按一次 B 回开场」），停一下再按 B（或按 A）才返回——两步；
## 第二下离上一下不到 0.4 秒不算（孩子连着乱按不会离开），3 秒不按就收回。找 L叔 的明信片 / 旅行本开着时 B 先收它们（act_pad）。
## Y：提示开 / 关（= H）。A：这一幕自己的那一下（act_pad("accept")，没有就 act_poke()：点城门 / 篝火 / 土豆），1 秒内不重复。
## 其余键先问这一幕（act_pad），没人要就吞掉。
const PAD_PRIORITY := 50
const PAD_ARM_MS := 3000
const PAD_CALM_MS := 400
const PAD_POKE_GAP_MS := 1000
var _pad_armed_at := -1
var _pad_last_press := -100000
var _pad_last_poke := -100000


func pad_active() -> bool:
	return is_inside_tree() and not _leaving


func pad_armed() -> bool:
	return _pad_armed_at >= 0 and Time.get_ticks_msec() - _pad_armed_at < PAD_ARM_MS


func pad_action(a: String) -> bool:
	_idle = 0.0
	var now := Time.get_ticks_msec()
	var armed := pad_armed()
	var calm := now - _pad_last_press >= PAD_CALM_MS
	_pad_last_press = now
	if a == "back":
		if _is_ready and host != null and is_instance_valid(host) and host.has_method("act_pad") and bool(host.call("act_pad", "back")):
			_pad_armed_at = -1
			return true
		if armed and calm:
			leave("pad")
			return true
		_pad_armed_at = now
		# 安卓的返回手势也走这里（那时没在用手柄）：提示别写「B」
		var hub := get_node_or_null("/root/PadInput")
		_toast = "再按一次 B，回到开场" if hub != null and bool(hub.get("pad_mode")) else "再返回一次，回到开场"
		_toast_early = true          # 载入卡盖着时也出（手柄层只在安卓上开）
		_toast_left = PAD_ARM_MS / 1000.0
		return true
	if a == "accept" and armed:
		if calm:
			leave("pad")
		return true
	if armed:
		_pad_armed_at = -1          # 按了别的键：不回去了
		_toast_left = 0.0
	if not _is_ready:
		return true
	var has_pad := host != null and is_instance_valid(host) and host.has_method("act_pad")
	if has_pad and bool(host.call("act_pad", a)):
		return true
	if a == "y":
		set_hints_hidden(not hints_hidden)
		return true
	if a == "accept" and host != null and is_instance_valid(host) and host.has_method("act_poke") and now - _pad_last_poke >= PAD_POKE_GAP_MS:
		_pad_last_poke = now
		host.call("act_poke")
	return true


func pad_focus() -> Variant:
	if pad_armed() and _btn.visible:
		return _btn
	if _is_ready and host != null and is_instance_valid(host) and host.has_method("act_pad_focus"):
		return host.call("act_pad_focus")
	return null


func pad_glyphs() -> Array:
	return [[_btn, "B", "side"]] if pad_armed() and _btn.visible else []


var _pad_hint_cache := {}


## 底部那一行：用手柄时换成按键说法（lshu_progress.gd 的 pad_hint）
func _current_hint() -> String:
	var hub := get_node_or_null("/root/PadInput")
	if hub != null and bool(hub.get("pad_mode")):
		if not _pad_hint_cache.has(act_id):
			_pad_hint_cache[act_id] = str(Progress.act_info(act_id).get("pad_hint", ""))
		var ph := String(_pad_hint_cache[act_id])
		if ph != "":
			return ph
	return _hint_text


# ------------------------------------------------------------------ 每帧
func _process(delta: float) -> void:
	_t_total += delta
	# 计时用截短的 delta：巴格达、找 L叔 刚就绪那几帧可能卡一两秒（第一次编译着色器），不能让药丸和提示还没被看见就算「闲置」过去了
	delta = minf(delta, 0.1)
	_idle += delta
	_since_ready += delta
	if not _shots.is_empty():
		var spec: String = _shots[0]
		var due := (_t_total >= float(spec.trim_prefix("l"))) if spec.begins_with("l") else (_is_ready and _since_ready >= float(spec))
		if due:
			_shots.pop_front()
			_take_shot(spec)
	_toast_left = maxf(0.0, _toast_left - delta)
	# 返回药丸：载入中一直在；就绪后不动鼠标 3 秒淡出，一动就回来；悬停时不淡出
	var hovered := _btn.visible and _btn.get_global_rect().has_point(_btn.get_global_mouse_position())
	var goal := REST_ALPHA if (not _is_ready or _idle < IDLE_FADE_SEC or hovered) else 0.0
	_alpha = move_toward(_alpha, goal, delta * (4.0 if goal > _alpha else 1.2))
	_btn.modulate.a = _alpha
	_btn.mouse_filter = Control.MOUSE_FILTER_STOP if _alpha > 0.05 else Control.MOUSE_FILTER_IGNORE
	# 底部提示：就绪后 6 秒，之后跟着鼠标出来、淡出；H 关掉时只闪一下「提示已关」
	var text: String = _toast if _toast_left > 0.0 else _current_hint()
	if _hint_label.text != text:
		_hint_label.text = text
	if _toast_left <= 0.0:
		_toast_early = false
	var show_hint := (_is_ready or (_toast_early and _toast_left > 0.0)) and not _leaving and text != "" and (_toast_left > 0.0 or (not hints_hidden and not busy and (_since_ready - _hint_from < HINT_SHOW_SEC or _idle < IDLE_FADE_SEC)))
	_hint_alpha = move_toward(_hint_alpha, HINT_ALPHA if show_hint else 0.0, delta * (3.0 if show_hint else 1.0))
	_hint.modulate.a = _hint_alpha
	_hint.visible = _hint_alpha > 0.01
	if (not _is_ready or _leaving) and _loading.visible:
		_loading_t += delta
		_walker.rotation = sin(_loading_t * 5.0) * 0.06   # 走路时身子轻轻晃（主线程被巴格达建场景卡住时就停一下，不要紧）
		_walker.pivot_offset = _walker.size * Vector2(0.5, 1.0)
	if _audio_probe and _is_ready and not _leaving:
		_probe_t += delta
		if _probe_t >= 1.0:
			_probe_t = 0.0
			var st: Dictionary = preload("res://scripts/traveler/traveler_globals.gd").audio_state(host)
			st["act"] = act_id
			st["since_ready"] = snappedf(_since_ready, 0.1)
			print("LSHU_AUDIO_PROBE ", JSON.stringify(st))
	if _is_ready and not _leaving and not _smoke_pokes.is_empty() and _since_ready >= _smoke_pokes[0]:
		_smoke_pokes.pop_front()
		var poked := host != null and is_instance_valid(host) and host.has_method("act_poke")
		print("LSHU_ACT_POKE ", JSON.stringify({"act": act_id, "called": poked}))
		if poked:
			host.call("act_poke")
	if _is_ready and _smoke_quit >= 0.0 and _since_ready >= _smoke_quit:
		_smoke_quit = -1.0
		var secs := maxf(0.001, float(Time.get_ticks_msec() - _ready_msec) / 1000.0)
		print("LSHU_ACT_SMOKE_QUIT ", JSON.stringify({"act": act_id, "fps_since_ready": snappedf(float(Engine.get_frames_drawn() - _ready_frames) / secs, 0.1), "max_fps": Engine.max_fps, "hosted": hosted}))
		leave("smoke")


func _take_shot(spec: String) -> void:
	# 等这一帧画完再拍；窗口被别的窗口挡住时 macOS 不画，frame_post_draw 不来——最多等 2 秒
	var drawn := [false]
	var on_drawn := func() -> void: drawn[0] = true
	RenderingServer.frame_post_draw.connect(on_drawn, CONNECT_ONE_SHOT)
	var t0 := Time.get_ticks_msec()
	while not drawn[0] and Time.get_ticks_msec() - t0 < 2000:
		await get_tree().process_frame
	if RenderingServer.frame_post_draw.is_connected(on_drawn):
		RenderingServer.frame_post_draw.disconnect(on_drawn)
	var path := "%s_%s.png" % [_shot_base, spec]
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("LSHU_ACT_SHOT ", JSON.stringify({"act": act_id, "path": path, "err": err, "drawn": drawn[0], "ready": _is_ready, "hint_alpha": snappedf(_hint_alpha, 0.01), "back_alpha": snappedf(_alpha, 0.01)}))


# ------------------------------------------------------------------ 设置
static func _settings_path() -> String:
	return Progress.dir_path().path_join(SETTINGS_FILE)


static func _read_settings() -> Dictionary:
	var p := _settings_path()
	if not FileAccess.file_exists(p):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return d if d is Dictionary else {}


static func _write_settings(patch: Dictionary) -> void:
	var d := _read_settings()
	d.merge(patch, true)
	d["schema"] = "lshu.traveler_settings.v1"
	DirAccess.make_dir_recursive_absolute(Progress.dir_path())
	var f := FileAccess.open(_settings_path(), FileAccess.WRITE)
	if f == null:
		push_warning("旅人模式设置写不进 %s" % _settings_path())
		return
	f.store_string(JSON.stringify(d, "  "))
	f.close()


# ------------------------------------------------------------------ 离开
## 离开这一幕。开在开场窗口里：交给 traveler_host.gd（盖上载入卡、发关窗口通知让这一幕存进度、停声音、释放、还原、回开场）。
## 单独开：先按关窗口的流程通知（各幕在这时存进度 / 收尾），再结束进程。
## cause（日志用）：pill =「‹ 返回」、esc、smoke = 冒烟到点；各幕自己调时不写
func leave(cause: String = "") -> void:
	if _leaving:
		return
	_leaving = true
	print("LSHU_ACT_LEAVE ", JSON.stringify({"act": act_id, "cause": cause, "hosted": hosted, "ready": _is_ready}))
	if hosted and Launch.host() != null:
		Launch.finish(get_tree(), 0)
		return
	get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
	get_tree().quit()


func is_leaving() -> bool:
	return _leaving
