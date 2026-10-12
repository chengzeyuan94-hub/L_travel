extends Control
## 「旅行L叔」开场：「商旅模式」「加载存档」「旅人模式」三个按钮，背景是选定旅人幕的成片（缓慢推近 + 飘雪 / 落叶 / 光点）。
## 按钮、Logo、面板、气泡都是 image 2.5 照概念图 01_title / 02_picker 生成的贴图（assets/game/ui/lshu_title/）。
## 旅人模式是开场里的一页（选幕）。进入某一幕时在同一个窗口里开（2026-09-27 Carlos：不再另起进程、开场不收起）：
## scripts/traveler/traveler_host.gd 盖上载入卡、藏起商旅模式、开那一幕；「‹ 返回」/ Esc 后回到这一页，音乐和环境声回来。
## 对主流程的约定和旧开场一样：节点名 StartScreen、信号 new_game_requested、按钮 %NewGameButton（测试和别的工具依赖它们）。

signal new_game_requested
## 「加载存档」：接着上一局（存档见 scripts/lshu_ui/lshu_match_save.gd）
signal continue_requested

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const W := preload("res://scripts/lshu_ui/lshu_widgets.gd")
const LSkin := preload("res://scripts/lshu_ui/lshu_skin.gd")
const Progress := preload("res://scripts/lshu_ui/lshu_progress.gd")
const MatchSave := preload("res://scripts/lshu_ui/lshu_match_save.gd")
const Home := preload("res://scripts/lshu_ui/lshu_home_scene.gd")
const TitleAmb := preload("res://scripts/audio/ambience/title_ambience.gd")
const Buses := preload("res://scripts/audio/audio_buses.gd")
const BGM_PATH := "res://assets/audio/title/title_bgm_loop_v1.wav"

## 每一幕的场景和参数在 lshu_progress.gd 的 ACTS（scene / args）里；进场、离开、还原全局设置都在 traveler_host.gd。
## 单独开某一幕（正式包 -- --lshu-act=<幕 id>）由入口 tools/merchant_board_claude_play.gd 换场景，和这里无关。
const TravelerHost := preload("res://scripts/traveler/traveler_host.gd")
const Launch := preload("res://scripts/traveler/traveler_launch.gd")
const Pad := preload("res://scripts/pad/pad_input.gd")

## 开场背景上飘的东西，跟着当前那一幕走
const AMBIENT: Dictionary = {
	"changan": {"kind": "leaf", "amount": 24, "life": 16.0, "fall": true, "dir": Vector2(0.45, 1.0), "vel": [45.0, 80.0], "scale": [0.55, 1.0], "spin": 80.0,
		"colors": ["#E0782F", "#C9502C", "#F0B04A", "#B8402A"]},
	"panti": {"kind": "dot", "amount": 130, "life": 15.0, "fall": true, "dir": Vector2(0.12, 1.0), "vel": [35.0, 70.0], "scale": [0.18, 0.5], "spin": 0.0,
		"colors": ["#FFFFFF", "#EEF4FF"]},
	"baghdad": {"kind": "glow", "amount": 34, "life": 13.0, "fall": false, "dir": Vector2(0.1, -1.0), "vel": [14.0, 30.0], "scale": [0.25, 0.6], "spin": 0.0,
		"colors": ["#FFD27A", "#FFE9B0", "#FFB866"]},
	"lshu": {"kind": "glow", "amount": 22, "life": 14.0, "fall": false, "dir": Vector2(0.2, -1.0), "vel": [10.0, 22.0], "scale": [0.2, 0.45], "spin": 0.0,
		"colors": ["#FFF4E0", "#FFE2C8"]},
}

## 主按钮上每隔几秒扫过一道高光（只提亮浅色的按钮面，不碰深棕描边）
const SHINE_SHADER := """
shader_type canvas_item;
uniform float shine = -1.0;
void fragment() {
	vec4 c = COLOR;  // Godot 4 的 COLOR 已经乘过贴图颜色
	float lum = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	float band = smoothstep(0.08, 0.0, abs(UV.x - shine + (UV.y - 0.5) * 0.22));
	c.rgb += band * smoothstep(0.42, 0.68, lum) * 0.34;
	COLOR = c;
}
"""

const BTN_SIZE := Vector2(600, 150)
const BTN_GAP := 22.0
const INK_BROWN := Color("#4A2C1A")
const GOLD := Color("#FFD45C")

var progress := Progress.new()
var design: Control
var ambient: Control
var home: Control
var bg: TextureRect
var bg_next: TextureRect
var picker: Control
var settings: Control
var bgm: AudioStreamPlayer
var _amb: TitleAmb  # 开场环境音（无界面 / 测试下为 null）
var act_extra_args: PackedStringArray = []  # 冒烟测试用：追加给那一幕的参数（比如把第四幕的存档指到临时目录）
var sound_button: TextureButton
var act_host: Node                # 正开着的那一幕（traveler_host.gd）；没有时为 null
var _act_id: String = ""
var _kb_tween: Tween
var _built: bool = false
var _entered: bool = false
var _shine_mat: ShaderMaterial


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 贴图按两倍存，缩小显示时用多级纹理，不起锯齿
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	progress.load_progress()
	_build()
	resized.connect(_layout)
	visibility_changed.connect(_on_visibility_changed)
	_layout()
	_on_visibility_changed()
	add_child(preload("res://scripts/pad/pad_title.gd").new())   # 手柄（scripts/pad/pad_title.gd）
	_smoke_enter_from_args()


## 冒烟（正式包也能用，tools/traveler/release_act_smoke.sh）：-- --lshu-unlock-all --lshu-smoke-enter=<幕 id>
## 开场出来 3 秒后自己点「进入」那一幕（同一个窗口里），那一幕就绪 12 秒后按「返回」同样的流程回开场，开场回来后退出进程
## （退出码 0 = 整条路走通，且全程只有这一个进程、一个窗口）
## 再带 --lshu-smoke-enter-close=<秒>：点「进入」后到点模拟点窗口的关闭按钮（那一幕可能还在载入：长安的场景要在后台读 5–6 秒，
## 这时开场那一层等它读完再退出，日志 TRAVELER_HOST_QUIT_DEFERRED → TRAVELER_HOST_QUIT_AFTER_READ，退出时不许有引擎报错）
var _smoke_enter: String = ""


func _smoke_enter_from_args() -> void:
	var quit_after := "12"
	var close_after := -1.0
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--lshu-smoke-enter="):
			_smoke_enter = a.trim_prefix("--lshu-smoke-enter=")
		elif a.begins_with("--lshu-smoke-enter-quit="):
			quit_after = a.trim_prefix("--lshu-smoke-enter-quit=")
		elif a.begins_with("--lshu-smoke-enter-close="):
			close_after = float(a.trim_prefix("--lshu-smoke-enter-close="))
	if _smoke_enter == "" or not is_inside_tree():
		return
	await get_tree().create_timer(3.0).timeout
	act_extra_args.append_array(PackedStringArray(["--lshu-act-smoke", "--lshu-act-smoke-quit=" + quit_after]))
	_enter_act(_smoke_enter)
	if act_host == null:
		print("LSHU_TITLE_SMOKE ", JSON.stringify({"act": _smoke_enter, "ok": false, "why": "enter failed"}))
		get_tree().quit(1)
		return
	if close_after >= 0.0:
		await get_tree().create_timer(close_after).timeout
		var st: String = str(act_host.get("state")) if is_instance_valid(act_host) else "gone"
		print("LSHU_TITLE_SMOKE_CLOSE ", JSON.stringify({"act": _smoke_enter, "after_sec": close_after, "state": st}))
		# 同窗口的关闭按钮：先给每个节点发关窗口通知，再发 close_requested（SceneTree 在 auto_accept_quit 为真时退出）
		get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
		get_tree().root.close_requested.emit()


# ------------------------------------------------------------------ 搭界面
func _build() -> void:
	for c in get_children():
		c.queue_free()
	clip_contents = true
	var backdrop := ColorRect.new()
	backdrop.color = Color("#2B2420")
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)
	# 默认开场「旅行L叔」是一段会动的插画，在各幕成片下面；选了某一幕时成片盖在它上面
	home = Home.new()
	home.name = "HomeScene"
	home.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	home.lshu_poked.connect(_on_lshu_poked)
	add_child(home)
	_amb = TitleAmb.attach(self, home) as TitleAmb
	bg = _make_bg(progress.title_cg_path())
	bg.flip_h = progress.title_cg_flip()
	add_child(bg)
	bg_next = _make_bg("")
	bg_next.modulate.a = 0.0
	add_child(bg_next)
	add_child(_make_shade())

	design = Control.new()
	design.name = "Design"
	design.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(design)
	ambient = Control.new()
	ambient.name = "Ambient"
	ambient.mouse_filter = Control.MOUSE_FILTER_IGNORE
	design.add_child(ambient)
	_make_ambient(progress.current_title_id())

	_build_logo()
	_build_menu()
	_build_top_right()
	_build_settings()
	_build_scene_chip()
	_build_progress()
	_build_guide()
	picker = _build_picker()
	picker.visible = false
	design.add_child(picker)
	_apply_title(false)

	bgm = AudioStreamPlayer.new()
	bgm.name = "TitleBgm"
	if ResourceLoader.exists(BGM_PATH):
		bgm.stream = load(BGM_PATH)
	# 2026-09-27 BGM 文件重渲到 −1.1 dBTP（整体低 1.6 dB），这里抬 1.6 dB，听到的和原来 −10 一样；走 Music 总线（静音键只静音乐和环境声）
	bgm.volume_db = -8.4
	bgm.bus = Buses.bus_or_master(Buses.MUSIC)
	bgm.finished.connect(func() -> void:
		if is_visible_in_tree() and not Launch.hosting():
			bgm.play())
	add_child(bgm)
	_built = true


func _make_bg(path: String) -> TextureRect:
	var t := TextureRect.new()
	t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if path != "" and ResourceLoader.exists(path):
		t.texture = load(path) as Texture2D
	return t


func _make_shade() -> TextureRect:
	# 左侧压暗一点，让按钮和标题在任何背景上都读得清
	var g := Gradient.new()
	g.set_color(0, Color(0.1, 0.07, 0.05, 0.36))
	g.set_color(1, Color(0.1, 0.07, 0.05, 0.0))
	g.add_point(0.45, Color(0.1, 0.07, 0.05, 0.06))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0.5)
	gt.fill_to = Vector2(1, 0.5)
	var t := TextureRect.new()
	t.texture = gt
	t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


## 把一块内容放进设计根：slot 只负责定位（pos 是离锚定那两条边的设计像素距离），
## 内容在 slot 里的位置留给动效用，_layout() 不碰它。
func _place(name_: String, content: Control, side: Vector2i, pos: Vector2) -> Control:
	var slot := Control.new()
	slot.name = name_
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(content)
	design.add_child(slot)
	slot.set_meta("anchor_pos", pos)
	slot.set_meta("anchor_side", side)
	slot.set_meta("content", content)
	return slot


func _content(slot_name: String) -> Control:
	var s := design.get_node_or_null(slot_name) as Control
	return s.get_meta("content") as Control if s != null and s.has_meta("content") else null


func _build_logo() -> void:
	var box := Control.new()
	box.name = "LogoBox"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var logo := LSkin.image("logo", 222)
	logo.name = "LogoImage"
	logo.size = logo.custom_minimum_size
	box.add_child(logo)
	var sub := LSkin.image("txt_subtitle", 58)
	sub.name = "Subtitle"
	sub.position = Vector2(30, 236)
	sub.size = sub.custom_minimum_size
	box.add_child(sub)
	box.custom_minimum_size = Vector2(maxf(logo.size.x, sub.position.x + sub.size.x), sub.position.y + sub.size.y)
	_place("Logo", box, Vector2i(0, 0), Vector2(92, 46))


func _build_menu() -> void:
	var box := Control.new()
	box.name = "MenuBox"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var merchant := _menu_button("NewGameButton", "ochre", "txt_merchant", "icon_suitcase", "")
	merchant.pressed.connect(func() -> void: new_game_requested.emit())
	_shine_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHINE_SHADER
	_shine_mat.shader = sh
	merchant.material = _shine_mat
	var load_b := _menu_button("LoadButton", "cream", "txt_load", "chest", "还没有存档")
	load_b.pressed.connect(func() -> void:
		if not MatchSave.exists():
			_refresh_load_button()
			return
		continue_requested.emit())
	_load_button = load_b
	_refresh_load_button()
	var trav := _menu_button("TravelerButton", "denim", "txt_traveler", "icon_mountain", "")
	trav.pressed.connect(_open_picker)
	var y: float = 0.0
	for b: Button in [merchant, load_b, trav]:
		b.position = Vector2(0, y)
		b.set_meta("base_pos", b.position)
		box.add_child(b)
		y += BTN_SIZE.y + BTN_GAP
	box.custom_minimum_size = Vector2(BTN_SIZE.x * 1.05, y - BTN_GAP)
	_place("Menu", box, Vector2i(0, 0), Vector2(92, 392))
	# unique_name_in_owner 需要 owner 是本场景根（测试用 %NewGameButton 找它）；进了场景树才能设 owner
	for b: Button in [merchant, load_b, trav]:
		b.owner = self
		b.unique_name_in_owner = true


func _menu_button(name_: String, color: String, label_tex: String, icon_name: String, caption: String) -> LSkin.CandyButton:
	var b := LSkin.candy_button(color)
	b.name = name_
	b.custom_minimum_size = BTN_SIZE
	b.size = BTN_SIZE
	b.pivot_offset = BTN_SIZE * 0.5
	var content := Control.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.size = BTN_SIZE
	b.add_child(content)
	b.content = content
	# 贴图下方有一道底唇，按钮面的视觉中线在 45% 高度
	var mid: float = BTN_SIZE.y * 0.45
	var ic: TextureRect
	if icon_name.begins_with("icon_"):
		ic = LSkin.image(icon_name, 80 if icon_name == "icon_suitcase" else 64)
	else:
		ic = TextureRect.new()
		ic.texture = Kit.icon(icon_name)
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ic.custom_minimum_size = Vector2(104, 104)
	ic.name = "Icon"
	ic.size = ic.custom_minimum_size
	ic.position = Vector2(92 - ic.size.x * 0.5, mid - ic.size.y * 0.5)
	content.add_child(ic)
	b.wiggle_target = ic
	var lab := LSkin.image(label_tex, 70 if caption == "" else 62)
	lab.name = "Label"
	lab.size = lab.custom_minimum_size
	lab.position = Vector2(162, mid - lab.size.y * 0.5 - (16.0 if caption != "" else 0.0))
	content.add_child(lab)
	if caption != "":
		var c := Kit.label(caption, 24, Color("#7A5A44"), "body", 700)
		c.name = "Caption"
		c.position = Vector2(170, mid + 16)
		content.add_child(c)
	var arrow := LSkin.Chevron.new(Vector2(24, 38))
	arrow.name = "Arrow"
	arrow.thick = 8.0
	if color == "denim":
		arrow.color = Color("#FFF8EC")
		arrow.outline = INK_BROWN
	arrow.position = Vector2(BTN_SIZE.x - 82, mid - 19)
	arrow.set_meta("base_pos", arrow.position)
	content.add_child(arrow)
	return b


## 设置里的「退出游戏」。桌面：点一下就退（和以前一样）。
## 安卓（触屏防误触开着）：第一下只把按钮换成「再点一次退出」，停一下（离上一下 ≥ 0.4 秒）、3 秒内再点才退；
## 一直连点的孩子退不出去（安卓压力测试 TS-7：以前齿轮 → 退出游戏两下就把整个游戏关了）。系统取消的触摸不算点
const QUIT_TEXT := "退出游戏"
const QUIT_ARMED_TEXT := "再点一次退出"
const QUIT_ARM_MS := 3000
const QUIT_CALM_MS := 400
var _quit_armed_at := -100000
var _quit_last_press := -100000


func _on_quit_pressed(b: Control) -> void:
	if _quit_press_confirms(b):
		_quit_game()


## 这一下「退出游戏」算不算数（桌面：算；安卓：第一下武装、换字，停一下再点才算）
func _quit_press_confirms(b: Control) -> bool:
	if not Pad.guards_on(self):
		return true
	if Pad.canceled_press(self):
		return false
	var now := Time.get_ticks_msec()
	var armed := now - _quit_armed_at < QUIT_ARM_MS
	var calm := now - _quit_last_press >= QUIT_CALM_MS
	_quit_last_press = now
	if armed and calm:
		return true
	_quit_armed_at = now
	_set_quit_text(b, QUIT_ARMED_TEXT)
	var at := now
	get_tree().create_timer(QUIT_ARM_MS / 1000.0, true, false, true).timeout.connect(func() -> void:
		if is_instance_valid(b) and _quit_armed_at == at:
			_set_quit_text(b, QUIT_TEXT))
	return false


static func _set_quit_text(b: Control, text: String) -> void:
	var l := b.get_node_or_null("Content/Text") as Label
	if l != null:
		l.text = text


## 退出前先停掉开场音乐和环境声，给音频线程一点时间释放，关窗时就不会报播放对象泄漏
func _quit_game() -> void:
	bgm.stop()
	bgm.stream = null
	if _amb:
		_amb.queue_free()
		_amb = null
	await get_tree().create_timer(0.15).timeout
	get_tree().quit()


## 用字体写字的糖果按钮（选幕页、设置里用）
func _text_button(text: String, color: String, sz: Vector2, px: int) -> LSkin.CandyButton:
	var b := LSkin.candy_button(color)
	b.custom_minimum_size = sz
	b.size = sz
	var content := Control.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.offset_bottom = -sz.y * 0.1
	b.add_child(content)
	b.content = content
	var fg: Color = INK_BROWN if color == "cream" else Color("#FFF8EC")
	var l := Kit.label(text, px, fg, "body", 800)
	l.name = "Text"
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if color != "cream":
		l.add_theme_color_override("font_outline_color", INK_BROWN)
		l.add_theme_constant_override("outline_size", maxi(6, int(px * 0.2)))
	content.add_child(l)
	return b


func _build_top_right() -> void:
	var box := Control.new()
	box.name = "TopRightBox"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sound_button = LSkin.image_button("lens_music", Vector2(112, 96))
	sound_button.name = "SoundButton"
	sound_button.tooltip_text = "背景音乐"
	sound_button.size = sound_button.custom_minimum_size
	sound_button.pressed.connect(_toggle_sound)
	var slash := Line2D.new()
	slash.name = "MuteSlash"
	slash.points = PackedVector2Array([Vector2(30, 70), Vector2(84, 24)])
	slash.width = 9.0
	slash.default_color = Color("#B5473A")
	slash.begin_cap_mode = Line2D.LINE_CAP_ROUND
	slash.end_cap_mode = Line2D.LINE_CAP_ROUND
	slash.antialiased = true
	slash.visible = false
	sound_button.add_child(slash)
	_show_mute(Buses.load_music_muted(get_tree()))  # 上次关掉的，这次打开还是关着
	box.add_child(sound_button)
	var gear := LSkin.image_button("lens_gear", Vector2(112, 96))
	gear.name = "SettingsButton"
	gear.tooltip_text = "设置"
	gear.size = gear.custom_minimum_size
	gear.position = Vector2(130, 0)
	gear.pressed.connect(_toggle_settings)
	box.add_child(gear)
	box.custom_minimum_size = Vector2(242, 96)
	_place("TopRight", box, Vector2i(1, 0), Vector2(44, 42))


func _build_settings() -> void:
	var panel := LSkin.nine_panel("panel_leather", Vector4(34, 34, 40, 34))
	panel.name = "SettingsPanel"
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	var full := _text_button(_fullscreen_text(), "cream", Vector2(300, 78), 30)
	full.name = "FullscreenButton"
	full.pressed.connect(func() -> void:
		var fs: bool = DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fs else DisplayServer.WINDOW_MODE_FULLSCREEN)
		(full.content.get_node("Text") as Label).text = _fullscreen_text())
	# 安卓（触屏防误触开着）：游戏本来就全屏沉浸，「全屏显示 / 换成窗口」没有意义，不放（安卓压力测试 TS-7）
	full.visible = not Pad.guards_on(self)
	col.add_child(full)
	var quit_b := _text_button(QUIT_TEXT, "cream", Vector2(300, 78), 30)
	quit_b.name = "QuitButton"
	quit_b.pressed.connect(_on_quit_pressed.bind(quit_b))
	col.add_child(quit_b)
	panel.add_child(col)
	settings = _place("Settings", panel, Vector2i(1, 0), Vector2(44, 156))
	settings.visible = false


func _fullscreen_text() -> String:
	var fs: bool = DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	return "换成窗口" if fs else "全屏显示"


func _build_scene_chip() -> void:
	var chip := LSkin.candy_button("cream")
	chip.name = "SceneChipButton"
	var content := Control.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(content)
	chip.content = content
	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var glasses := LSkin.image("icon_glasses", 26)
	row.add_child(glasses)
	chip.wiggle_target = glasses
	var name_l := Kit.label("", 27, INK_BROWN, "body", 800)
	name_l.name = "SceneName"
	row.add_child(name_l)
	var more := Kit.label("换一个", 24, Color("#8A5A3B"), "body", 700)
	more.name = "More"
	row.add_child(more)
	var arrow := LSkin.Chevron.new(Vector2(14, 22))
	arrow.name = "MoreArrow"
	arrow.thick = 5.0
	arrow.color = Color("#8A5A3B")
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(arrow)
	content.add_child(row)
	chip.pressed.connect(_cycle_title_scene)
	_place("SceneChip", chip, Vector2i(0, 1), Vector2(92, 44))
	_refresh_chip()


func _refresh_chip() -> void:
	var chip := _content("SceneChip") as LSkin.CandyButton
	if chip == null:
		return
	var ids: Array[String] = progress.title_ids()
	design.get_node("SceneChip").visible = ids.size() > 1 and not picker_visible()
	if ids.size() < 2:
		return
	var row := chip.content.get_node("Row") as HBoxContainer
	(row.get_node("SceneName") as Label).text = "开场画面：%s" % str(progress.act(progress.current_title_id()).name)
	var many: bool = ids.size() > 1
	(row.get_node("More") as Control).visible = many
	(row.get_node("MoreArrow") as Control).visible = many
	chip.disabled = not many
	var h: float = 74.0
	var rs: Vector2 = row.get_combined_minimum_size()
	row.size = rs
	row.position = Vector2(34, h * 0.45 - rs.y * 0.5)
	chip.custom_minimum_size = Vector2(rs.x + 72, h)
	chip.size = chip.custom_minimum_size
	chip.content.size = chip.size
	_layout()


func picker_visible() -> bool:
	return picker != null and picker.visible


func _build_progress() -> void:
	var panel := LSkin.nine_panel("panel_leather", Vector4(38, 30, 46, 36))
	panel.name = "ProgressCard"
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 10)
	var fl := TextureRect.new()
	fl.texture = Kit.icon("potato_bloom")
	fl.custom_minimum_size = Vector2(50, 50)
	fl.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fl.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	fl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r1.add_child(fl)
	r1.add_child(_rich("已经赢了 [font_size=46][color=#%s]%d[/color][/font_size] 局" % [GOLD.to_html(false), progress.wins], 32))
	col.add_child(r1)
	var nxt: Dictionary = progress.next_locked()
	if nxt.is_empty():
		col.add_child(_rich("所有旅行地都解锁啦", 27))
	else:
		col.add_child(_rich("再赢 [color=#%s]%d[/color] 局，解锁 [color=#%s]%s[/color]" % [GOLD.to_html(false), int(nxt.wins) - progress.wins, GOLD.to_html(false), str(nxt.name)], 27))
	var inset := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.17, 0.09, 0.05, 0.42)
	s.border_color = Color(1.0, 0.88, 0.7, 0.16)
	s.set_border_width_all(2)
	s.set_corner_radius_all(22)
	s.corner_detail = 10
	s.anti_aliasing = true
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 12
	s.content_margin_bottom = 6
	inset.add_theme_stylebox_override("panel", s)
	var badges := HBoxContainer.new()
	badges.name = "Badges"
	badges.add_theme_constant_override("separation", 6)
	var last_filled: int = -1
	for i in range(Progress.ACTS.size()):
		if progress.is_unlocked(str(Progress.ACTS[i].id)):
			last_filled = i
	for i in range(Progress.ACTS.size()):
		var a: Dictionary = Progress.ACTS[i]
		var on: bool = progress.is_unlocked(str(a.id))
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 0)
		var holder := Control.new()
		holder.name = "Holder"
		holder.custom_minimum_size = Vector2(96, 50)
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if on and i == last_filled:
			var glow := TextureRect.new()
			glow.name = "Glow"
			glow.texture = _soft_texture("glow", Vector2i(64, 64))
			glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			glow.offset_left = -18
			glow.offset_right = 18
			glow.offset_top = -22
			glow.offset_bottom = 22
			glow.modulate = Color(1.0, 0.85, 0.45, 0.55)
			glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
			holder.add_child(glow)
		var badge := TextureRect.new()
		badge.name = "Badge"
		badge.texture = LSkin.tex("badge_on" if on else "badge_off")
		badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		badge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if not on:
			badge.modulate = Color(1.3, 1.2, 1.1, 0.9)
		holder.add_child(badge)
		cell.add_child(holder)
		var n := Kit.label(str(int(a.wins)), 26, Color("#FFF1D6") if on else Color(1, 0.94, 0.84, 0.5), "body", 800)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		n.add_theme_color_override("font_outline_color", Color("#3B2215"))
		n.add_theme_constant_override("outline_size", 6 if on else 0)
		cell.add_child(n)
		badges.add_child(cell)
	inset.add_child(badges)
	col.add_child(inset)
	panel.add_child(col)
	_place("ProgressPanel", panel, Vector2i(1, 0), Vector2(44, 160))


func _rich(bb: String, px: int, color: Color = Color("#FFF1D6")) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.scroll_active = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_override("normal_font", Kit.font("body", 800))
	r.add_theme_font_override("bold_font", Kit.font("body", 900))
	r.add_theme_font_size_override("normal_font_size", px)
	r.add_theme_font_size_override("bold_font_size", int(px * 1.15))
	r.add_theme_color_override("default_color", color)
	if color.get_luminance() > 0.6:
		r.add_theme_color_override("font_outline_color", Color("#3B2215"))
		r.add_theme_constant_override("outline_size", 7)
		r.add_theme_color_override("font_shadow_color", Color(0.1, 0.05, 0.02, 0.45))
		r.add_theme_constant_override("shadow_offset_y", 3)
		r.add_theme_constant_override("shadow_offset_x", 0)
		r.add_theme_constant_override("shadow_outline_size", 8)
	r.text = bb
	return r


func _build_guide() -> void:
	# L叔 小头像 + 对话泡泡：一屏只有这一句提示
	var bubble := LSkin.nine_panel("bubble", Vector4(26, 22, 34, 50))
	bubble.name = "GuideBubble"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var face := _avatar(92)
	face.name = "Face"
	row.add_child(face)
	var nxt: Dictionary = progress.next_locked()
	# 手动断行：自动换行会把「，」挤到下一行行首
	var line: String = "所有地方都能去啦，\n放着看风景吧！"
	if not nxt.is_empty():
		# 第四幕不是地名（复检 WIN-7：以前读成「跟我去L叔去哪儿看看」）
		var tease: String = str(nxt.get("tease", "就能跟我去%s看看！" % str(nxt.name).trim_suffix("旅人")))
		line = "再赢 %d 局，\n%s" % [int(nxt.wins) - progress.wins, tease]
	var text := Kit.label(line, 27, INK_BROWN, "body", 800)
	text.name = "GuideText"
	# 入场动画把 visible_ratio 从 0 拉到 1；按「排版后再截字」算最小尺寸，泡泡一开始就是整句的大小，
	# 不会在字出完之后往右长出屏幕（复检 NOV-6）
	text.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.add_theme_constant_override("line_spacing", 2)
	row.add_child(text)
	bubble.add_child(row)
	_place("Guide", bubble, Vector2i(1, 1), Vector2(52, 40))


func _avatar(d: float) -> PanelContainer:
	var face := PanelContainer.new()
	var fs := StyleBoxFlat.new()
	fs.bg_color = Color("#F7E6D0")
	fs.border_color = Color("#5A3A24")
	fs.set_border_width_all(5)
	fs.set_corner_radius_all(int(d))
	fs.corner_detail = 16
	fs.anti_aliasing = true
	fs.set_content_margin_all(4)
	face.add_theme_stylebox_override("panel", fs)
	face.custom_minimum_size = Vector2(d, d)
	face.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	face.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var av := TextureRect.new()
	var portrait: Texture2D = LSkin.tex("lshu_avatar2")
	if portrait != null:
		# 新头像是半身像，圆框里只放头（从头顶开始取一个正方形）
		var head := AtlasTexture.new()
		head.atlas = portrait
		var w: float = portrait.get_width()
		head.region = Rect2(0, 6, w, w)
		av.texture = head
	else:
		av.texture = Kit.icon("lshu_avatar")
	av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	av.mouse_filter = Control.MOUSE_FILTER_IGNORE
	face.add_child(av)
	return face


# ------------------------------------------------------------------ 背景飘落物
func _soft_texture(kind: String, sz: Vector2i) -> GradientTexture2D:
	var g := Gradient.new()
	if kind == "leaf":
		g.offsets = PackedFloat32Array([0.0, 0.62, 0.8])
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.95), Color(1, 1, 1, 0)])
	elif kind == "dot":
		g.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.75), Color(1, 1, 1, 0)])
	else:
		g.offsets = PackedFloat32Array([0.0, 0.15, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = sz.x
	t.height = sz.y
	return t


func _make_ambient(id: String) -> void:
	for c in ambient.get_children():
		c.queue_free()
	if id == "" or id == "home":
		return
	var cfg: Dictionary = AMBIENT.get(id, AMBIENT["lshu"])
	var kind: String = str(cfg.kind)
	var p := CPUParticles2D.new()
	p.name = "Drift"
	p.amount = int(cfg.amount)
	p.lifetime = float(cfg.life)
	p.preprocess = float(cfg.life)
	p.texture = _soft_texture(kind, Vector2i(40, 18) if kind == "leaf" else Vector2i(48, 48))
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = cfg.dir as Vector2
	p.spread = 14.0
	p.gravity = Vector2(4, 8) if bool(cfg.fall) else Vector2(0, -3)
	p.initial_velocity_min = float(cfg.vel[0])
	p.initial_velocity_max = float(cfg.vel[1])
	p.scale_amount_min = float(cfg.scale[0])
	p.scale_amount_max = float(cfg.scale[1])
	p.angle_min = 0.0
	p.angle_max = 360.0 if kind == "leaf" else 0.0
	p.angular_velocity_min = -float(cfg.spin)
	p.angular_velocity_max = float(cfg.spin)
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.12, 0.85, 1.0])
	fade.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	p.color_ramp = fade
	var tint := Gradient.new()
	var cols: Array = cfg.colors
	var offs := PackedFloat32Array()
	var pcs := PackedColorArray()
	for i in cols.size():
		offs.append(float(i) / maxf(1.0, float(cols.size() - 1)))
		pcs.append(Color(str(cols[i])))
	tint.offsets = offs
	tint.colors = pcs
	tint.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	p.color_initial_ramp = tint
	if kind == "glow":
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		p.material = m
	p.set_meta("fall", bool(cfg.fall))
	ambient.add_child(p)
	_layout_ambient()


func _layout_ambient() -> void:
	if ambient == null or design == null:
		return
	var sz: Vector2 = design.size
	for c in ambient.get_children():
		var p := c as CPUParticles2D
		if p == null:
			continue
		if bool(p.get_meta("fall", true)):
			p.position = Vector2(sz.x * 0.4, -40)
			p.emission_rect_extents = Vector2(sz.x * 0.7, 20)
		else:
			p.position = Vector2(sz.x * 0.5, sz.y * 0.72)
			p.emission_rect_extents = Vector2(sz.x * 0.5, sz.y * 0.3)


# ------------------------------------------------------------------ 旅人选幕页
func _build_picker() -> Control:
	var page := Control.new()
	page.name = "Picker"
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var paper_tex: Texture2D = LSkin.tex("picker_bg")
	if paper_tex != null:
		var paper := TextureRect.new()
		paper.texture = paper_tex
		paper.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		paper.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		paper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		page.add_child(paper)
	else:
		var flat := ColorRect.new()
		flat.color = Kit.CREAM_DEEP
		flat.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		page.add_child(flat)
	var back := LSkin.image_button("btn_back", Vector2(118, 104))
	back.name = "BackButton"
	back.tooltip_text = "回开场"
	back.position = Vector2(64, 40)
	back.size = back.custom_minimum_size
	back.pressed.connect(_close_picker)
	page.add_child(back)
	var htitle := LSkin.image("txt_picker", 100)
	htitle.position = Vector2(196, 22)
	htitle.size = htitle.custom_minimum_size
	page.add_child(htitle)
	var cap := Kit.label("在商旅模式赢了 %d 局 · 已解锁 %d 幕" % [progress.wins, progress.unlocked_ids().size()], 30, INK_BROWN, "body", 800)
	cap.position = Vector2(214, 124)
	page.add_child(cap)
	var cards := Control.new()
	cards.name = "Cards"
	cards.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cards.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_child(cards)
	var n: int = Progress.ACTS.size()
	for i in n:
		var card := _act_card(Progress.ACTS[i])
		card.set_meta("slot", i)
		cards.add_child(card)
	cards.resized.connect(func() -> void: _layout_cards(cards))
	var figure := TextureRect.new()
	figure.name = "Figure"
	figure.texture = LSkin.tex("lshu_point")
	figure.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	figure.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	figure.mouse_filter = Control.MOUSE_FILTER_IGNORE
	figure.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	figure.offset_left = -196
	figure.offset_right = -46
	figure.offset_top = -318
	figure.offset_bottom = -14
	page.add_child(figure)
	var say := LSkin.nine_panel("bubble", Vector4(28, 18, 32, 46))
	say.name = "PickerBubble"
	say.add_child(Kit.label("想去哪儿看看？", 32, INK_BROWN, "body", 800))
	say.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	say.offset_left = -500
	say.offset_right = -196
	say.offset_top = -214
	say.offset_bottom = -110
	page.add_child(say)
	return page


const CARD_SIZE := Vector2(404, 636)


func _layout_cards(cards: Control) -> void:
	var n: int = cards.get_child_count()
	var gap: float = 34.0
	var total: float = CARD_SIZE.x * n + gap * (n - 1)
	var x0: float = (cards.size.x - total) * 0.5
	for c in cards.get_children():
		var card := c as Control
		var i: int = int(card.get_meta("slot", 0))
		card.size = CARD_SIZE
		card.pivot_offset = Vector2(CARD_SIZE.x * 0.5, 0)
		var p := Vector2(x0 + i * (CARD_SIZE.x + gap), 214)
		card.set_meta("base_pos", p)
		if not card.has_meta("animating"):
			card.position = p


func _act_card(a: Dictionary) -> Control:
	var id: String = str(a.id)
	var unlocked: bool = progress.is_unlocked(id)
	var is_title: bool = unlocked and progress.current_title_id() == id
	var card := LSkin.nine_panel("card_blank", Vector4(26, 26, 26, 30))
	card.name = "Card_" + id
	card.px = 0.5
	if card.skin == null:
		card.add_theme_stylebox_override("panel", Kit.satchel_box(30, 5, 26, Kit.CREAM))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	var photo := PanelContainer.new()
	photo.name = "Photo"
	var ps := StyleBoxFlat.new()
	ps.bg_color = Color.WHITE
	ps.set_corner_radius_all(18)
	ps.corner_detail = 10
	ps.anti_aliasing = true
	photo.add_theme_stylebox_override("panel", ps)
	photo.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	photo.custom_minimum_size = Vector2(0, 236)
	var thumb := TextureRect.new()
	thumb.texture = load(str(a.thumb)) as Texture2D
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	thumb.flip_h = bool(a.get("flip", false))
	if not unlocked:
		thumb.material = W.gray_material()
	photo.add_child(thumb)
	col.add_child(photo)
	# 照片上的角标：左上眼镜章（解锁）/ 右上锁（未解锁）/「开场中」印章
	var badge := LSkin.image("badge_on" if unlocked else "badge_off", 44)
	badge.position = Vector2(40, 42)
	badge.size = badge.custom_minimum_size
	if not unlocked:
		badge.modulate = Color(1.6, 1.6, 1.6, 0.9)
	var name_l := Kit.label(str(a.name), 44, INK_BROWN if unlocked else Color("#8C7A68"), "body", 900)
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(name_l)
	var divider := _divider()
	col.add_child(divider)
	# 一两行小字说这一幕是什么、能点什么（以前 desc 写了却没显示，复检 LSHU-8）；句号处断行
	var desc := Kit.label(str(a.get("desc", "")).replace("。", "。\n").strip_edges(), 21, Color("#7A5A44") if unlocked else Color("#9A8A7A"), "body", 700)
	desc.name = "Desc"
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.add_theme_constant_override("line_spacing", 0)   # 不开自动换行：在容器里会把卡片撑得很高；每句都短于一行
	col.add_child(desc)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)
	if unlocked:
		# 这一幕引用的东西没装进包里（从没有 generated/ 的检出导出，PAD-MAR-1）：「进入」灰掉、写明，不让孩子进去对着载入卡干等
		var available := Progress.act_available(id)
		var enter := _text_button("进入" if available else "这一幕没装进来", "ochre", Vector2(0, 90), 40 if available else 30)
		enter.name = "Enter_" + id
		enter.disabled = not available
		if not available:
			enter.content.modulate = Color(1, 1, 1, 0.55)
		enter.pressed.connect(func() -> void: _enter_act(id))
		col.add_child(enter)
		var set_b := _text_button("已是开场" if is_title else "设为开场", "cream", Vector2(0, 66), 28)
		set_b.name = "SetTitle_" + id
		set_b.disabled = is_title
		if is_title:
			set_b.content.modulate = Color(1, 1, 1, 0.55)
		set_b.pressed.connect(func() -> void: _set_title_scene(id))
		col.add_child(set_b)
	else:
		var need: int = int(a.wins) - progress.wins
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 10)
		var lk := TextureRect.new()
		lk.texture = Kit.icon("lock")
		lk.custom_minimum_size = Vector2(44, 44)
		lk.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lk.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(lk)
		row.add_child(Kit.label("再赢 %d 局就能来" % need, 30, INK_BROWN, "body", 800))
		col.add_child(row)
		var bar_row := HBoxContainer.new()
		bar_row.add_theme_constant_override("separation", 12)
		var bar := ProgressBar.new()
		bar.min_value = 0
		bar.max_value = float(int(a.wins))
		bar.value = float(mini(progress.wins, int(a.wins)))
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 24)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var bg_s := StyleBoxFlat.new()
		bg_s.bg_color = Color("#6E5140")
		bg_s.set_corner_radius_all(12)
		bg_s.anti_aliasing = true
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color("#7DB65E")
		fill.border_color = Color("#6E5140")
		fill.set_border_width_all(3)
		fill.set_corner_radius_all(12)
		fill.anti_aliasing = true
		bar.add_theme_stylebox_override("background", bg_s)
		bar.add_theme_stylebox_override("fill", fill)
		bar_row.add_child(bar)
		bar_row.add_child(Kit.label("%d / %d" % [mini(progress.wins, int(a.wins)), int(a.wins)], 26, Color("#6E5140"), "body", 800))
		col.add_child(bar_row)
		var pad := Control.new()
		pad.custom_minimum_size = Vector2(0, 40)
		col.add_child(pad)
	card.add_child(col)
	# 铜夹、角标、印章不参与排版，直接叠在卡片上
	var over := Control.new()
	over.name = "Over"
	over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(over)
	card.sort_children.connect(func() -> void:
		over.position = Vector2.ZERO
		over.size = card.size)
	var clip := LSkin.image("clip", 74)
	clip.size = clip.custom_minimum_size
	clip.position = Vector2(CARD_SIZE.x * 0.5 - clip.size.x * 0.5, -40)
	over.add_child(clip)
	over.add_child(badge)
	if not unlocked:
		var lock2 := TextureRect.new()
		lock2.texture = Kit.icon("lock")
		lock2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lock2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lock2.size = Vector2(62, 62)
		lock2.position = Vector2(CARD_SIZE.x - 102, 36)
		lock2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		over.add_child(lock2)
	if is_title:
		var stamp := LSkin.image("stamp_current", 132)
		stamp.size = stamp.custom_minimum_size
		stamp.position = Vector2(CARD_SIZE.x - stamp.size.x - 10, 10)
		stamp.pivot_offset = stamp.size * 0.5
		stamp.rotation = deg_to_rad(10)
		stamp.name = "Stamp"
		over.add_child(stamp)
	return card


func _divider() -> Control:
	# 名字下面一道细线，中间一朵小土豆花
	var d := Control.new()
	d.custom_minimum_size = Vector2(0, 26)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var flower: Texture2D = Kit.icon("potato_bloom")
	d.draw.connect(func() -> void:
		var y: float = d.size.y * 0.5
		var cx: float = d.size.x * 0.5
		var c := Color("#B99A7A")
		d.draw_line(Vector2(cx - 150, y), Vector2(cx - 22, y), c, 3.0, true)
		d.draw_line(Vector2(cx + 22, y), Vector2(cx + 150, y), c, 3.0, true)
		if flower != null:
			d.draw_texture_rect(flower, Rect2(cx - 16, y - 16, 32, 32), false))
	return d


func _open_picker() -> void:
	_show_settings(false)
	if _amb: _amb.set_picker(true)
	picker.visible = true
	picker.modulate.a = 0.0
	_update_home_process()
	for n: String in ["Logo", "Menu", "TopRight", "SceneChip", "ProgressPanel", "Guide"]:
		var c := design.get_node_or_null(n) as Control
		if c != null:
			c.visible = false
	var cards := picker.get_node("Cards") as Control
	_layout_cards(cards)
	var tw := picker.create_tween()
	tw.tween_property(picker, "modulate:a", 1.0, 0.25)
	for c in cards.get_children():
		var card := c as Control
		var base: Vector2 = card.get_meta("base_pos")
		var i: int = int(card.get_meta("slot", 0))
		card.set_meta("animating", true)
		card.position = base + Vector2(0, 120)
		card.modulate.a = 0.0
		card.rotation = deg_to_rad(-3.0 + 2.0 * float(i % 2) * 1.5)
		var ct := card.create_tween().set_parallel(true)
		ct.tween_property(card, "position", base, 0.55).set_delay(0.06 * i + 0.08).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		ct.tween_property(card, "modulate:a", 1.0, 0.25).set_delay(0.06 * i + 0.08)
		ct.tween_property(card, "rotation", 0.0, 0.7).set_delay(0.06 * i + 0.08).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
		ct.chain().tween_callback(func() -> void: card.remove_meta("animating"))


func _close_picker() -> void:
	if _amb: _amb.set_picker(false)
	var tw := picker.create_tween()
	tw.tween_property(picker, "modulate:a", 0.0, 0.18)
	tw.tween_callback(func() -> void:
		picker.visible = false
		_update_home_process()
		for n: String in ["Logo", "Menu", "TopRight", "ProgressPanel", "Guide"]:
			var c := design.get_node_or_null(n) as Control
			if c != null:
				c.visible = true
		_refresh_chip())


# ------------------------------------------------------------------ 动效：入场 + 待机
func _from(node: Control, delay: float, offset: Vector2, dur: float = 0.6, trans: int = Tween.TRANS_BACK) -> Tween:
	var base: Vector2 = node.get_meta("base_pos", node.position)
	node.set_meta("base_pos", base)
	node.position = base + offset
	node.modulate.a = 0.0
	var tw := node.create_tween().set_parallel(true)
	tw.tween_property(node, "position", base, dur).set_delay(delay).set_trans(trans).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "modulate:a", 1.0, dur * 0.45).set_delay(delay)
	return tw


func _pop(node: Control, delay: float, dur: float = 0.55) -> Tween:
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2(0.2, 0.2)
	node.modulate.a = 0.0
	var tw := node.create_tween().set_parallel(true)
	tw.tween_property(node, "scale", Vector2.ONE, dur).set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "modulate:a", 1.0, dur * 0.4).set_delay(delay)
	return tw


func _play_entrance() -> void:
	if _entered:
		return
	_entered = true
	var logo_box := _content("Logo")
	var logo := logo_box.get_node("LogoImage") as Control
	var sub := logo_box.get_node("Subtitle") as Control
	_from(logo, 0.05, Vector2(0, -280), 0.8).chain().tween_callback(_idle_logo)
	_from(sub, 0.5, Vector2(-40, 0), 0.5, Tween.TRANS_CUBIC)
	var menu := _content("Menu")
	var i: int = 0
	for b in menu.get_children():
		_from(b as Control, 0.28 + 0.1 * i, Vector2(-220, 0), 0.62)
		i += 1
	var top := _content("TopRight")
	i = 0
	for b in top.get_children():
		_pop(b as Control, 0.55 + 0.1 * i)
		i += 1
	var panel := _content("ProgressPanel")
	_from(panel, 0.5, Vector2(260, 0), 0.65)
	var badges := panel.find_child("Badges", true, false) as Control
	i = 0
	for cell in badges.get_children():
		var holder := (cell as Control).get_node("Holder") as Control
		var tw := _pop(holder, 0.95 + 0.14 * i, 0.5)
		if holder.has_node("Glow"):
			tw.chain().tween_callback(_idle_glow.bind(holder.get_node("Glow")))
		i += 1
	var chip := _content("SceneChip")
	_from(chip, 0.8, Vector2(0, 60), 0.5)
	var guide := _content("Guide")
	var gt := _pop(guide, 1.35, 0.5)
	var text := guide.find_child("GuideText", true, false) as Label
	text.visible_ratio = 0.0
	gt.chain().tween_property(text, "visible_ratio", 1.0, 0.9)
	gt.chain().tween_callback(_idle_guide)
	# 主按钮：箭头轻推 + 隔几秒一道高光
	var merchant := menu.get_node("NewGameButton") as LSkin.CandyButton
	var arrow := merchant.content.get_node("Arrow") as Control
	var base_x: float = (arrow.get_meta("base_pos") as Vector2).x
	var at := arrow.create_tween().set_loops()
	at.tween_property(arrow, "position:x", base_x + 7.0, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	at.tween_property(arrow, "position:x", base_x, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var st := create_tween().set_loops()
	st.tween_interval(2.2)
	st.tween_method(func(v: float) -> void: _shine_mat.set_shader_parameter("shine", v), -0.25, 1.25, 0.95).set_trans(Tween.TRANS_SINE)
	st.tween_interval(3.4)


func _idle_logo() -> void:
	var logo := _content("Logo").get_node("LogoImage") as Control
	var base: Vector2 = logo.get_meta("base_pos")
	logo.pivot_offset = logo.size * Vector2(0.5, 1.0)
	var tw := logo.create_tween().set_loops()
	tw.tween_property(logo, "position:y", base.y - 7.0, 1.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.parallel().tween_property(logo, "rotation", deg_to_rad(-0.7), 1.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(logo, "position:y", base.y, 1.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.parallel().tween_property(logo, "rotation", deg_to_rad(0.5), 1.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _idle_glow(glow: Control) -> void:
	var tw := glow.create_tween().set_loops()
	tw.tween_property(glow, "modulate:a", 0.95, 1.1).set_trans(Tween.TRANS_SINE)
	tw.tween_property(glow, "modulate:a", 0.35, 1.1).set_trans(Tween.TRANS_SINE)


func _idle_guide() -> void:
	# L叔 头像隔一会儿歪头点一下
	var face := _content("Guide").find_child("Face", true, false) as Control
	face.pivot_offset = face.size * Vector2(0.5, 0.9)
	var tw := face.create_tween().set_loops()
	tw.tween_interval(3.0)
	tw.tween_property(face, "rotation", deg_to_rad(-8.0), 0.22).set_trans(Tween.TRANS_SINE)
	tw.tween_property(face, "rotation", deg_to_rad(5.0), 0.26).set_trans(Tween.TRANS_SINE)
	tw.tween_property(face, "rotation", 0.0, 0.3).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


# ------------------------------------------------------------------ 行为
func _set_title_scene(id: String) -> void:
	progress.title_scene = id
	progress.save_progress()
	_apply_title(true)
	# 选幕页里的「开场中」印章和按钮状态要刷新
	var was_open: bool = picker.visible
	picker.queue_free()
	picker = _build_picker()
	design.add_child(picker)
	picker.visible = was_open
	_layout()
	_layout_cards(picker.get_node("Cards") as Control)


func _cycle_title_scene() -> void:
	var ids: Array[String] = progress.title_ids()
	if ids.size() < 2:
		return
	var cur: String = progress.current_title_id()
	var i: int = ids.find(cur)
	progress.title_scene = ids[(i + 1) % ids.size()]
	progress.save_progress()
	_apply_title(true)
	_refresh_chip()


## 按当前选中的开场切背景：默认「旅行L叔」时露出下面会动的插画，否则成片盖上来（淡入淡出）
func _apply_title(animate: bool) -> void:
	var id: String = progress.current_title_id()
	if _amb: _amb.set_scene(id, animate)
	_make_ambient(id)
	var dur: float = 0.8 if animate else 0.0
	if id == "home":
		home.visible = true
		_update_home_process()
		for t: TextureRect in [bg, bg_next]:
			if animate:
				create_tween().tween_property(t, "modulate:a", 0.0, dur)
			else:
				t.modulate.a = 0.0
		return
	var path: String = progress.title_cg_path()
	if not ResourceLoader.exists(path):
		return
	if not animate:
		bg.texture = load(path) as Texture2D
		bg.flip_h = progress.title_cg_flip()
		bg.modulate.a = 1.0
		bg_next.modulate.a = 0.0
		home.visible = false
		_update_home_process()
		return
	if bg.modulate.a < 0.5:
		# 从插画切到成片：成片直接淡入，淡完把插画停下
		bg.texture = load(path) as Texture2D
		bg.flip_h = progress.title_cg_flip()
		bg_next.modulate.a = 0.0
		var tw := create_tween()
		tw.tween_property(bg, "modulate:a", 1.0, dur)
		tw.tween_callback(func() -> void:
			home.visible = false
			_update_home_process())
		return
	_crossfade_bg(path)


## 插画只在开场可见、没打开选幕页、且选中的是默认开场时才跑
func _update_home_process() -> void:
	if home == null:
		return
	var run: bool = home.visible and is_visible_in_tree() and not picker_visible() and progress.current_title_id() == "home"
	home.process_mode = Node.PROCESS_MODE_INHERIT if run else Node.PROCESS_MODE_DISABLED


## 点了插画里的 L叔：右下的气泡换一句俏皮话，过一会儿换回来
func _on_lshu_poked() -> void:
	if _content("Guide") == null:
		return
	_guide_say(home.next_poke_line(), 5.0)


## 读档失败时（lshu_preview_main.gd 的 _on_continue_requested 调，docs/design/map-editor-20260930/DESIGN.md 3.8）：
## L叔 在右下的气泡里把原因说出来（孩子话，比如「这一局用的是自制地图，地图资料读不到，存档接不上。请更新游戏。」），
## 停得比俏皮话久一些，再换回原来那句
const NOTICE_SEC := 10.0


func show_notice(text: String) -> void:
	var line := text.strip_edges()
	if line == "":
		return
	print("LSHU_TITLE_NOTICE ", JSON.stringify({"text": line}))
	_guide_say(_notice_lines(line), NOTICE_SEC, true)


## 长句按标点折成几行（一行不超过 14 个字），泡泡不会横着伸出屏幕；本来带换行的原样用
static func _notice_lines(text: String) -> String:
	if text.contains("\n"):
		return text
	var parts: Array[String] = []
	var cur := ""
	for ch in text:
		cur += ch
		if "，。！？；".contains(ch):
			parts.append(cur)
			cur = ""
	if cur != "":
		parts.append(cur)
	var lines: Array[String] = []
	var line := ""
	for p in parts:
		if line != "" and line.length() + p.length() > 14:
			lines.append(line)
			line = ""
		line += p
	if line != "":
		lines.append(line)
	return "\n".join(lines)


## 右下的气泡换一句话、弹一下，hold_sec 秒后换回原来那句（中途又换了别的话，就由最后那一句的计时器换回）。
## relayout：句子比原来那句长（读档失败的说明有三四行）时，按新大小重新贴到右下角。气泡上记一个 notice_relayout：
## 提示还在的时候孩子点了 L叔，俏皮话也按自己的大小重新贴；不管哪一次的计时器换回原来那句，都再贴一次，气泡缩回原样。
## 没说过提示时点 L叔 照旧不重新排版
func _guide_say(line: String, hold_sec: float, relayout: bool = false) -> void:
	var guide := _content("Guide")
	if guide == null:
		return
	var text := guide.find_child("GuideText", true, false) as Label
	if not text.has_meta("default_text"):
		text.set_meta("default_text", text.text)
	text.text = line
	text.visible_ratio = 0.0
	if relayout:
		text.set_meta("notice_relayout", true)
	if text.has_meta("notice_relayout"):
		_layout.call_deferred()
	guide.pivot_offset = guide.size * Vector2(0.15, 1.0)
	var tw := guide.create_tween()
	tw.tween_property(guide, "scale", Vector2(1.08, 1.08), 0.1).set_trans(Tween.TRANS_SINE)
	tw.tween_property(guide, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(text, "visible_ratio", 1.0, 0.5)
	var serial: int = int(text.get_meta("poke_serial", 0)) + 1
	text.set_meta("poke_serial", serial)
	# 只记节点 id，不把 Label 本身捕获进 lambda：这几秒内 _reload_progress 重建了气泡（旧 Label 被释放）时，
	# 捕获着已释放对象的 lambda 会报「Lambda capture at index 0 was freed」（TS-10）
	var text_id := text.get_instance_id()
	var self_id := get_instance_id()
	get_tree().create_timer(hold_sec).timeout.connect(func() -> void:
		var t := instance_from_id(text_id) as Label
		if t != null and int(t.get_meta("poke_serial", 0)) == serial:
			t.text = str(t.get_meta("default_text"))
			t.visible_ratio = 1.0
			if t.has_meta("notice_relayout"):
				t.remove_meta("notice_relayout")
				var me := instance_from_id(self_id) as Control
				if me != null:
					me.call_deferred("_layout"))


func _crossfade_bg(path: String) -> void:
	if not ResourceLoader.exists(path):
		return
	bg_next.texture = load(path) as Texture2D
	bg_next.flip_h = progress.title_cg_flip()
	bg_next.scale = bg.scale
	var tw := create_tween()
	tw.tween_property(bg_next, "modulate:a", 1.0, 0.8)
	tw.tween_callback(func() -> void:
		bg.texture = bg_next.texture
		bg.flip_h = bg_next.flip_h
		bg_next.modulate.a = 0.0)


## 静音键（Carlos 2026-09-27）：只静音乐和环境声（按钮音、对局音效照常），并记住这个设置
func _toggle_sound() -> void:
	var muted: bool = not Buses.music_muted()
	Buses.set_music_muted(muted, get_tree())
	_show_mute(muted)


func _show_mute(muted: bool) -> void:
	(sound_button.get_node("MuteSlash") as CanvasItem).visible = muted
	sound_button.modulate = Color(0.8, 0.78, 0.76) if muted else Color.WHITE


func _toggle_settings() -> void:
	_show_settings(not settings.visible)


func _show_settings(on: bool) -> void:
	if settings == null or settings.visible == on:
		return
	var panel := settings.get_meta("content") as Control
	if on:
		settings.visible = true
		settings.move_to_front()
		_layout()
		panel.pivot_offset = Vector2(panel.size.x - 60, 0)
		panel.scale = Vector2(0.6, 0.6)
		panel.modulate.a = 0.0
		var tw := panel.create_tween().set_parallel(true)
		tw.tween_property(panel, "scale", Vector2.ONE, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(panel, "modulate:a", 1.0, 0.14)
	else:
		var tw := panel.create_tween()
		tw.tween_property(panel, "modulate:a", 0.0, 0.12)
		tw.tween_callback(func() -> void: settings.visible = false)


## 点「进入」：在同一个窗口里开这一幕（traveler_host.gd）。开场的音乐马上停、环境声 0.4 秒淡出，载入卡从这一页上淡入盖满；
## 一幕开着时开场整个藏起来、不处理，别的按钮也就点不到（以前要把商旅模式、加载存档灰掉，夜测 TL-3）
func _enter_act(id: String) -> void:
	if Launch.hosting() or Progress.act_info(id).is_empty():
		return
	_show_settings(false)
	if _amb: _amb.set_act(true)
	bgm.stop()
	act_host = TravelerHost.enter(self, id, act_extra_args)
	if act_host == null:
		if _amb: _amb.set_act(false)
		if is_visible_in_tree():
			bgm.play()
		return
	_act_id = id


## traveler_host.gd 收尾完（这一幕释放、全局设置还原、开场重新显示）后调：回到选幕页，音乐、环境声回来，胜场按盘上刷新
func _on_act_returned(info: Dictionary) -> void:
	act_host = null
	_act_id = ""
	if _amb: _amb.set_act(false)
	if is_visible_in_tree():
		_refresh_load_button()
		_reload_progress()
		if bgm.stream != null and not bgm.playing:
			bgm.play()
	if _smoke_enter != "":
		print("LSHU_TITLE_SMOKE ", JSON.stringify({"act": _smoke_enter, "ok": true, "single_process": true, "windows": DisplayServer.get_window_list().size(), "restored": info.get("restored", [])}))
		get_tree().create_timer(1.0).timeout.connect(_quit_game)


var _load_button: Button


## 按盘上的胜场重搭跟胜场有关的几块：进度面板、引导泡泡、选幕页、开场画面按钮（复检 WIN-1：以前只在启动时读一次，
## 打完一局回来还是旧数，刚解锁的一幕要重开游戏才进得去）
func _reload_progress() -> void:
	if design == null or picker == null:
		return
	var fresh := Progress.new()
	fresh.load_progress()
	if fresh.wins == progress.wins and fresh.title_scene == progress.title_scene:
		return
	progress = fresh
	for n: String in ["ProgressPanel", "Guide"]:
		var slot := design.get_node_or_null(n)
		if slot != null:
			design.remove_child(slot)
			slot.queue_free()
	_build_progress()
	_build_guide()
	var was_open: bool = picker.visible
	design.remove_child(picker)
	picker.queue_free()
	picker = _build_picker()
	picker.visible = was_open
	design.add_child(picker)
	_refresh_chip()
	_apply_title(false)
	_layout()


## 有存档（商旅模式一局没打完）时「加载存档」可点，下面一行写「第 3 轮 · 小驼铃的回合」；没有时灰着。
## 用了自制地图的存档先轻查一遍（MatchSave.quick_check：入口门、地图的 schema、生成器版本、目录版本，
## docs/design/map-editor-20260930/DESIGN.md 3.8）：接不上就灰着，下面一行写原因（「这局用的地图读不到」
## 「这局用了自制地图，只能在 3D 版里接着玩」）；存档不删，游戏更新后还能接着玩。不带地图的存档和原来一样
const LOAD_MAP_UNREADABLE := "这局用的地图读不到"
## 灰着时说明文字可以写到按钮右边的箭头那里（箭头藏起来了）；再长就把字缩小，最小 18 px
const LOAD_CAPTION_MAX_W := 400.0
const LOAD_CAPTION_PX := 24
const LOAD_CAPTION_MIN_PX := 18


func _refresh_load_button() -> void:
	if _load_button == null:
		return
	var d: Dictionary = MatchSave.read()
	var has := not d.is_empty()
	var why := ""
	if has:
		var check := _save_quick_check(d)
		if not bool(check.get("ok", true)):
			why = String(check.get("kid_text", "")).strip_edges()
			if why == "":
				why = LOAD_MAP_UNREADABLE
	var can := has and why == ""
	_load_button.disabled = not can
	_load_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if can else Control.CURSOR_ARROW
	_load_button.tooltip_text = "接着上一局玩" if can else (why if has else "还没有存档：商旅模式每回合开始会自动存档")
	var content := _load_button.get("content") as Control
	if content != null:
		content.modulate = Color.WHITE if can else Color(1, 1, 1, 0.7)
		var arrow := content.get_node_or_null("Arrow") as Control
		if arrow != null:
			arrow.visible = can
		var cap := content.get_node_or_null("Caption") as Label
		if cap != null:
			cap.text = MatchSave.summary(d) if can else (why if has else "还没有存档")
			_fit_load_caption(cap, why != "")


## 存档能不能接上（只读的轻查，不做整份校验）。MatchSave.quick_check 由规则层提供（WP1）；
## 还没有这个函数的版本，一律当作能接（和原来一样只看 read() 读不读得出来）
func _save_quick_check(d: Dictionary) -> Dictionary:
	var save_script: Script = MatchSave
	if not save_script.has_method("quick_check"):
		return {"ok": true, "kid_text": ""}
	var r: Variant = save_script.call("quick_check", d)
	return r as Dictionary if r is Dictionary else {"ok": false, "kid_text": LOAD_MAP_UNREADABLE}


## 说明文字：原因那种长句放不下时缩小字号；平常的「第 3 轮 · 谁的回合」保持原来的 24 px
func _fit_load_caption(cap: Label, is_reason: bool) -> void:
	var px := LOAD_CAPTION_PX
	var font := cap.get_theme_font("font")
	while is_reason and font != null and px > LOAD_CAPTION_MIN_PX and font.get_string_size(cap.text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > LOAD_CAPTION_MAX_W:
		px -= 1
	cap.add_theme_font_size_override("font_size", px)


## 离树（关窗、换场景）时释放开场音乐；在响的话等音频线程混完这一段再走，不然退出时报播放对象泄漏
func _exit_tree() -> void:
	if bgm == null:
		return
	# 子节点先离树，TitleBgm 离树时已把自己暂停，这里 playing 恒为假；还有没释放的播放就等一下
	var was_playing: bool = bgm.has_stream_playback()
	bgm.stop()
	bgm.stream = null
	if was_playing:
		OS.delay_msec(60)


func _on_visibility_changed() -> void:
	if not _built:
		return
	if is_visible_in_tree():
		_refresh_load_button()     # 从对局回来：这局可能刚存过
		_reload_progress()         # 从对局回来：可能刚赢了一局、刚解锁一幕
	if _amb: _amb.set_shown(is_visible_in_tree())
	if is_visible_in_tree():
		if bgm.stream != null and not bgm.playing and not Launch.hosting():
			bgm.play()
		_start_ken_burns()
	else:
		bgm.stop()
		if _kb_tween != null:
			_kb_tween.kill()
	_update_home_process()


func _start_ken_burns() -> void:
	if _kb_tween != null:
		_kb_tween.kill()
	bg.scale = Vector2.ONE
	_kb_tween = create_tween().set_loops()
	_kb_tween.tween_property(bg, "scale", Vector2(1.07, 1.07), 36.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_kb_tween.tween_property(bg, "scale", Vector2.ONE, 36.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# ------------------------------------------------------------------ 布局：设计根按 k 缩放并铺满窗口
func _layout() -> void:
	if design == null:
		return
	var vp: Vector2 = size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	var k: float = minf(vp.x / Kit.DESIGN.x, vp.y / Kit.DESIGN.y)
	design.scale = Vector2(k, k)
	design.position = Vector2.ZERO
	design.size = vp / k
	for bgr: TextureRect in [bg, bg_next]:
		bgr.pivot_offset = vp * 0.5
	for c in design.get_children():
		var slot := c as Control
		if slot == null or not slot.has_meta("anchor_pos"):
			continue
		var content := slot.get_meta("content") as Control
		var sz: Vector2 = content.get_combined_minimum_size()
		content.size = sz
		slot.size = sz
		var p: Vector2 = slot.get_meta("anchor_pos")
		var side: Vector2i = slot.get_meta("anchor_side")
		slot.position = Vector2(design.size.x - p.x - sz.x if side.x == 1 else p.x, design.size.y - p.y - sz.y if side.y == 1 else p.y)
	_layout_ambient()
	if not _entered:
		_play_entrance.call_deferred()
