class_name LshuMatchHud
extends Control

## 商旅对局界面（2026-09-26「旅行L叔」重设计，按 ui-concepts-lshu-20260925 的 04_turn / 05_trade / 06_win）。
## 只负责「长什么样、放在哪」：六个角/边分组（左上对手、上中回合牌+步骤条、右上时钟与公共银库、
## 左下当前玩家挎包、下中骰子托盘、右下主按钮+L叔引导泡泡）、右侧市集面板、换人卡和结算页。
## 规则与流程仍在 GameScreen：它把原有功能节点（PrimaryAction、SecondaryActions、NextStepPrompt、
## CargoSelectGrid、MatchClock、SupplyValue、Dice3DView…）搬进这里的插槽，节点名不变，测试与机器人照旧可用。
## 设计分辨率 1920×1080：每组按 k = min(宽/1920, 高/1080) 缩放后贴到屏幕角上；零件贴图为 1080p 下 1:1 像素。

signal trade_row_pressed(index: int)
signal trade_row_action(index: int)
signal trade_times_pressed(delta: int)
signal mode_tab_pressed(mode: int)
signal dice_pressed
signal menu_pressed
signal save_pressed
signal handover_pressed
signal guide_toggled
signal discard_toggled
signal exchange_give_pressed(good_id: String)
signal exchange_target_pressed(target_id: String)
signal exchange_receive_pressed(good_id: String)
signal market_collapse_changed(collapsed: bool)
signal choice_pressed(id: String)
signal campfire_dismissed

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const CandySkinLib := preload("res://scripts/lshu_ui/lshu_skin.gd")
const ChoiceView := preload("res://scripts/lshu_ui/lshu_choice_view.gd")
const FunParts := preload("res://scripts/lshu_ui/lshu_fun_parts.gd")
const DIR := "res://assets/game/ui/match_hud/"
const DESIGN := Vector2(1920, 1080)
const GUTTER := 18.0

# 各组设计尺寸
const TC_SIZE := Vector2(720, 150)
const TR_SIZE := Vector2(376, 152)
const TL_SIZE := Vector2(520, 330)
const BL_SIZE := Vector2(720, 236)
const BC_SIZE := Vector2(250, 250)
const BR_SIZE := Vector2(600, 240)
const MARKET_W := 880.0
const MARKET_H_MIN := 760.0
const MARKET_H_MAX := 900.0
const MARKET_GAP := 12.0          # 面板底边与右下按钮区之间的留白
const DOCK_BUTTONS_TOP := 70.0    # 右下组里次要按钮的顶边（面板只占到这里为止）
## 右下角（Carlos 2026-09-26：「L叔 建议会持续遮挡东南沿海……可以直接关闭，要不就找一个不会遮挡的地方」）：
## 大泡泡换成按钮上方的一条单行提示，L叔 小头像放到按钮右边，点头像收起 / 打开提示
const PROMPT_RECT := Rect2(24, 4, 416, 54)

var k := 1.0
var market_mode := ""             # "" / "trade" / "exchange" / "extra" / "decision"
var _meta: Dictionary = {}
var _tex_cache: Dictionary = {}
var _market_h := MARKET_H_MIN

var group_tl: Control
var group_tc: Control
var group_tr: Control
var group_bl: Control
var group_bc: Control
var group_br: Control
var market: Control
var handover: Control
var result: Control

# 插槽：GameScreen 把功能节点搬进来
var slot_round: Control
var slot_clock: Control
var slot_supply: Control
var slot_wallet: Control
var slot_cargo: Control
var slot_dice: Control
var slot_prompt: Control
var slot_primary: Control
var slot_secondary: Control
var slot_receipt: Control
var slot_market_extra: Control
var slot_result_buttons: HBoxContainer

# 自带显示部件
var satchel_avatar: TextureRect
var satchel_name: Label
var satchel_ring: Panel
var discard_button: Button
var step_badge: Control
var step_badge_label: Label
var guide_portrait: TextureRect
var guide_bubble: NinePatchRect
var _steps: Array = []            # [{lens: Panel, icon: TextureRect, label: Label}]
var _chips: Array = []            # 对手小卡
var market_bg: NinePatchRect
var market_title: Label
var market_tabs: HBoxContainer
var market_subtitle: Label
var market_chain: HBoxContainer
var market_rows_scroll: ScrollContainer
var market_rows: VBoxContainer
var _market_row_nodes: Array = []
## 事件交换（market_mode == "exchange"）：① 交出 ② 换回 + 来源 + 底部预览
var market_exchange: Control
## 市集面板可收起（2026-09-26 Carlos：面板开着时「地图最右侧的如平城京，泉州等地图是难以显示的，建议交易面板设置为可以隐藏或者折叠」）：
## 面板左边一个皮革拉手，点一下整块滑出屏幕，只剩右边缘一截「◂ 市集」拉手；右下的主 / 次按钮不动，收起时照样能确认或结束回合。
## 每次打开市集都从展开开始（不替小朋友把能做的交易藏起来）。
var save_button: Button
var market_collapsed := false
var market_tab: Button
var _market_slide := 0.0          # 0 = 展开，1 = 收到屏幕外
var _market_slide_tween: Tween
var _market_open_x := 0.0
var _view_w := 1920.0
var _exchange_sig := ""
var _exchange_nodes := {}         # "give:<id>" / "recv:<id>" / "target:<id>" → Button
var _exchange_give_row: HBoxContainer
var _exchange_recv_grid: GridContainer
var _exchange_recv_scroll: ScrollContainer
var _exchange_targets: HFlowContainer
var _exchange_targets_rows := 0   # 0 = 来源和「② 换回什么？」同一行；≥1 = 来源自己占几行（在 ② 下面）
var _exchange_recv_head: Label
var _exchange_preview: Control
## 「L叔的趣味事件」的选择面板（market_mode == "decision"）：付银或丢货、听声三选一、二选一、看牌（lshu_choice_view.gd）
var market_choice: Control
## 围炉夜话的篝火问题泡泡：不挡操作，点一下才收起（GameScreen 管什么时候收）
var campfire: Control
var _campfire_text: Label
var _campfire_replies: Label
var _prompt_lines := 1
var handover_avatar: TextureRect
var handover_ring: Panel
var handover_title: Label
var handover_sub: Label
var handover_note: Label
var _handover_bg: Control
var handover_button: Button
var _handover_card: Control
var _result_title: Label
var _result_rows: VBoxContainer
var _result_progress: Label
var _result_card: Control
var _result_bubble_text: Label
var _result_guide: Control


func _init() -> void:
	name = "LshuMatchHud"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var f := FileAccess.open(DIR + "match_hud.json", FileAccess.READ)
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			_meta = parsed


# ------------------------------------------------------------------ 素材

func tex(name_: String) -> Texture2D:
	if _tex_cache.has(name_):
		return _tex_cache[name_]
	var p := DIR + name_ + ".png"
	var t: Texture2D = load(p) as Texture2D if ResourceLoader.exists(p) else null
	_tex_cache[name_] = t
	return t


## 不透明的界面底图一律挡住鼠标（MOUSE_FILTER_STOP）：点在回合牌、挎包、对手小卡上不能「点穿」到下面的地图，
## 否则会选中（09-27 以前是直接出发到）被挡住的地点（2026-09-26 复检 EI-2）。放进按钮里的底图由按钮自己改成 IGNORE。
func nine(name_: String) -> NinePatchRect:
	var n := NinePatchRect.new()
	n.name = "Skin_" + name_
	n.texture = tex(name_)
	n.mouse_filter = Control.MOUSE_FILTER_STOP
	var m: Array = _meta.get(name_, {}).get("nine", [0, 0, 0, 0])
	n.patch_margin_left = int(m[0])
	n.patch_margin_top = int(m[1])
	n.patch_margin_right = int(m[2])
	n.patch_margin_bottom = int(m[3])
	return n


func image(name_: String) -> TextureRect:
	var t := TextureRect.new()
	t.name = "Img_" + name_
	t.texture = tex(name_)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.mouse_filter = Control.MOUSE_FILTER_STOP
	return t


static func place(c: Control, r: Rect2) -> void:
	c.position = r.position
	c.size = r.size


func _group(n: String, s: Vector2) -> Control:
	var g := Control.new()
	g.name = n
	g.size = s
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(g)
	return g


func _slot(parent: Control, n: String, r: Rect2) -> Control:
	var s := Control.new()
	s.name = n
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(s, r)
	parent.add_child(s)
	return s


static func label(text: String, px: int, color: Color, kind := "body", weight := 700) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	style_label(l, px, color, kind, weight)
	return l


## 字体分层（Carlos 2026-09-26：「如果全是这种卡通字体，可读性很累」）：
##   display = 娃娃体，只给少数大标题（市集名、结算大字、换人卡）；
##   title   = 圆体真粗体（回合牌、名字、按钮）；body = 圆体常规 / 中等（提示、说明、数字）。
## 圆体用系统字重本身，不用 FontVariation 人为加粗（加粗后字形发糊）。
static var _ui_fonts: Dictionary = {}


static func ui_font(weight: int) -> Font:
	var w := 700 if weight >= 650 else 500 if weight >= 500 else 400
	if _ui_fonts.has(w):
		return _ui_fonts[w]
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Yuanti SC", "PingFang SC", "Hiragino Sans GB"])
	f.font_weight = w
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	_ui_fonts[w] = f
	return f


static func font_for(kind: String, weight: int) -> Font:
	if kind == "display":
		return Kit.font("title", 700)
	return ui_font(700 if kind == "title" else mini(weight, 600))


static func style_label(l: Label, px: int, color: Color, kind := "body", weight := 700) -> void:
	l.add_theme_font_override("font", font_for(kind, weight))
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0))
	l.add_theme_constant_override("outline_size", 0)
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 0)


## 圆形头像：圆形遮罩着色器
const ROUND_SHADER := """
shader_type canvas_item;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float d = distance(UV, vec2(0.5));
	c.a *= 1.0 - smoothstep(0.485, 0.5, d);
	COLOR = c * COLOR;
}
"""
static var _round_mat: ShaderMaterial


static func round_avatar() -> TextureRect:
	if _round_mat == null:
		var sh := Shader.new()
		sh.code = ROUND_SHADER
		_round_mat = ShaderMaterial.new()
		_round_mat.shader = sh
	var t := TextureRect.new()
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	t.material = _round_mat
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


static func ring(color: Color, width: int, fill := Color(0, 0, 0, 0)) -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_ring(p, color, width, fill)
	return p


static func set_ring(p: Panel, color: Color, width: int, fill := Color(0, 0, 0, 0)) -> void:
	var b := StyleBoxFlat.new()
	b.bg_color = fill
	b.border_color = color
	b.set_border_width_all(width)
	b.set_corner_radius_all(999)
	b.anti_aliasing = true
	p.add_theme_stylebox_override("panel", b)


## 长名字（开局页允许 12 个字）：先把字号往下缩，缩到下限还放不下就加省略号（复检 MS-6 / LC-6 / LC-7）
static func fit_label(l: Label, max_w: float, px_max: int, px_min: int) -> void:
	var font := l.get_theme_font("font")
	var px := px_max
	while px > px_min and font != null and font.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > max_w:
		px -= 2
	l.add_theme_font_size_override("font_size", px)
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS


static func candy(text: String, color: String, px: int) -> Button:
	var b := Button.new()
	b.text = text
	CandySkinLib.skin_button(b, color)
	b.add_theme_font_override("font", ui_font(700))
	b.add_theme_font_size_override("font_size", px)
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(key, Kit.INK)
	b.add_theme_color_override("font_disabled_color", Kit.INK_SOFT)
	return b


static func flat_hit(b: BaseButton) -> void:
	var empty := StyleBoxEmpty.new()
	for key in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(key, empty)
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


# ------------------------------------------------------------------ 搭建

func build() -> void:
	group_tl = _group("HudTopLeft", TL_SIZE)
	group_tc = _group("HudTopCenter", TC_SIZE)
	group_tr = _group("HudTopRight", TR_SIZE)
	group_bl = _group("HudBottomLeft", BL_SIZE)
	group_bc = _group("HudBottomCenter", BC_SIZE)
	group_br = _group("HudBottomRight", BR_SIZE)
	_build_top_center()
	_build_top_right()
	_build_satchel()
	_build_dice_tray()
	_build_dock()
	_build_market()
	_build_campfire()
	_build_handover()
	_build_result()


func _build_top_center() -> void:
	var pill := nine("pill")
	pill.name = "RoundPill"
	place(pill, Rect2(70, 0, 580, 72))
	group_tc.add_child(pill)
	slot_round = _slot(group_tc, "SlotRound", Rect2(110, 4, 500, 62))
	var bar := nine("stepbar")
	bar.name = "StepBar"
	place(bar, Rect2(20, 80, 680, 66))
	group_tc.add_child(bar)
	var names := ["掷骰", "走路", "交易", "结束"]
	var icons := ["icon_dice", "icon_walk", "icon_trade", "icon_flag"]
	for i in 4:
		var x := 58.0 + i * 160.0
		if i > 0:
			var dash := label("· · ·", 22, Kit.CAMEL, "body", 700)
			place(dash, Rect2(x - 56, 94, 50, 36))
			group_tc.add_child(dash)
		var lens := ring(Kit.INK, 4)
		place(lens, Rect2(x, 86, 54, 54))
		group_tc.add_child(lens)
		var ic := image(icons[i])
		place(ic, Rect2(x + 7, 93, 40, 40))
		group_tc.add_child(ic)
		var lb := label(names[i], 26, Kit.INK_SOFT)
		lb.name = "LshuStep%d" % i
		lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		place(lb, Rect2(x + 60, 92, 96, 40))
		group_tc.add_child(lb)
		_steps.append({"lens": lens, "icon": ic, "label": lb})


## current: 0..3 当前步（-1 = 全部淡出）
func set_steps(current: int) -> void:
	for i in _steps.size():
		var s: Dictionary = _steps[i]
		var lens: Panel = s.lens
		var lb: Label = s.label
		var ic: TextureRect = s.icon
		if current >= 0 and i < current:
			set_ring(lens, Kit.INK, 4, Kit.SPROUT)
			style_label(lb, 26, Color("#4E7A3F"), "body", 500)
			ic.modulate = Color(1, 1, 1, 0.9)
		elif i == current:
			set_ring(lens, Kit.INK, 4, Kit.OCHRE)
			style_label(lb, 29, Kit.INK, "title", 700)
			ic.modulate = Color.WHITE
		else:
			set_ring(lens, Color(Kit.INK_SOFT, 0.55), 4, Kit.CREAM)
			style_label(lb, 26, Kit.INK_SOFT, "body", 500)
			ic.modulate = Color(1, 1, 1, 0.6)
		lb.set_meta("state", "done" if current >= 0 and i < current else "current" if i == current else "todo")


func step_state(i: int) -> String:
	return String((_steps[i].label as Label).get_meta("state", "todo"))


## 右上两行：公共银库 + 齿轮在上，剩余时间在下（1280×720 时不和上中的步骤条挤在一起）
func _build_top_right() -> void:
	var supply := nine("pill")
	supply.name = "SupplyPill"
	place(supply, Rect2(0, 4, 292, 72))
	group_tr.add_child(supply)
	slot_supply = _slot(group_tr, "SlotSupply", Rect2(22, 8, 248, 62))
	var gear := TextureButton.new()
	gear.name = "MenuButton"
	gear.texture_normal = load("res://assets/game/ui/lshu_title/lens_gear.png") as Texture2D
	gear.ignore_texture_size = true
	gear.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	gear.focus_mode = Control.FOCUS_NONE
	gear.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	gear.tooltip_text = "回到开场"
	place(gear, Rect2(298, 0, 78, 78))
	gear.pressed.connect(func() -> void: menu_pressed.emit())
	group_tr.add_child(gear)
	var clock := nine("pill")
	clock.name = "ClockPill"
	place(clock, Rect2(84, 84, 208, 66))
	group_tr.add_child(clock)
	var clock_icon := TextureRect.new()
	clock_icon.texture = load("res://assets/game/ui/lshu_setup/icon_clock.png") as Texture2D
	clock_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	clock_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	clock_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(clock_icon, Rect2(108, 94, 44, 44))
	group_tr.add_child(clock_icon)
	slot_clock = _slot(group_tr, "SlotClock", Rect2(152, 88, 124, 58))
	_build_save_button()


## 右上角时钟左边的「存档」（2026-09-27 Carlos：「到现在我都没有发现对局中存档按钮在哪」）。
## 存档不会弄丢任何东西，小朋友点到也无妨；存的是这一回合开始的样子，开场点「加载存档」接着玩。
func _build_save_button() -> void:
	save_button = Button.new()
	save_button.name = "SaveButton"
	save_button.tooltip_text = "存档：开场点「加载存档」就能接着玩"
	flat_hit(save_button)
	place(save_button, Rect2(0, 84, 80, 66))
	var bg := nine("pill")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	save_button.add_child(bg)
	var ic := TextureRect.new()
	ic.name = "Icon"
	ic.texture = Kit.icon("chest")
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(ic, Rect2(22, 5, 36, 32))
	save_button.add_child(ic)
	var t := label("存档", 19, Kit.INK, "body", 700)
	t.name = "SaveText"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(t, Rect2(0, 36, 80, 26))
	save_button.add_child(t)
	save_button.pivot_offset = Vector2(40, 33)
	save_button.pressed.connect(func() -> void: save_pressed.emit())
	group_tr.add_child(save_button)


## 存好了：按钮弹一下，字换成「已存」一会儿
func flash_saved() -> void:
	if save_button == null:
		return
	var t := save_button.get_node("SaveText") as Label
	t.text = "已存 ✓"
	var tw := save_button.create_tween()
	tw.tween_property(save_button, "scale", Vector2(1.12, 1.12), 0.08).set_trans(Tween.TRANS_SINE)
	tw.tween_property(save_button, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.6)
	tw.tween_callback(func() -> void: t.text = "存档")


func _build_satchel() -> void:
	var bag := nine("satchel")
	bag.name = "SatchelSkin"
	place(bag, Rect2(0, 10, 720, 226))
	group_bl.add_child(bag)
	satchel_ring = ring(Kit.CAMEL, 8, Kit.CREAM)
	satchel_ring.name = "SatchelRing"
	place(satchel_ring, Rect2(22, 52, 150, 150))
	group_bl.add_child(satchel_ring)
	satchel_avatar = round_avatar()
	satchel_avatar.name = "SatchelAvatar"
	place(satchel_avatar, Rect2(30, 60, 134, 134))
	group_bl.add_child(satchel_avatar)
	var tag := PanelContainer.new()
	tag.name = "SatchelNameTag"
	tag.mouse_filter = Control.MOUSE_FILTER_STOP
	var tb := StyleBoxFlat.new()
	tb.bg_color = Kit.CREAM
	tb.border_color = Kit.SATCHEL_DEEP
	tb.set_border_width_all(4)
	tb.set_corner_radius_all(18)
	tb.content_margin_left = 18
	tb.content_margin_right = 18
	tb.content_margin_top = 2
	tb.content_margin_bottom = 2
	tag.add_theme_stylebox_override("panel", tb)
	place(tag, Rect2(200, 0, 0, 44))
	group_bl.add_child(tag)
	satchel_name = label("", 28, Kit.INK, "title", 700)
	satchel_name.name = "SatchelName"
	satchel_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.add_child(satchel_name)
	var wallet_tag := Panel.new()
	wallet_tag.name = "WalletTag"
	wallet_tag.mouse_filter = Control.MOUSE_FILTER_STOP
	wallet_tag.add_theme_stylebox_override("panel", tb.duplicate())
	place(wallet_tag, Rect2(470, 0, 128, 46))
	group_bl.add_child(wallet_tag)
	slot_wallet = _slot(group_bl, "SlotWallet", Rect2(478, 0, 112, 46))
	slot_cargo = _slot(group_bl, "SlotCargo", Rect2(186, 58, 500, 160))
	# 原版：「货仓里的货物可在任何时候丢弃，但不会获得任何白银」——挎包上的「丢货」，进入挑选后再确认（两步，防误触）
	discard_button = candy("丢货", "cream", 22)
	discard_button.name = "DiscardToggle"
	discard_button.tooltip_text = "挑出不要的货丢掉（不换钱），给新货腾地方"
	place(discard_button, Rect2(604, -2, 96, 48))
	discard_button.pressed.connect(func() -> void: discard_toggled.emit())
	group_bl.add_child(discard_button)


func set_satchel(avatar: Texture2D, display_name: String, seat_color: Color) -> void:
	satchel_avatar.texture = avatar
	if satchel_name.text != display_name:
		satchel_name.text = display_name
		fit_label(satchel_name, 226.0, 28, 20)
		var font := satchel_name.get_theme_font("font")
		var w := font.get_string_size(display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, satchel_name.get_theme_font_size("font_size")).x if font != null else 120.0
		satchel_name.custom_minimum_size = Vector2(minf(w + 2.0, 226.0), 0)
	set_ring(satchel_ring, seat_color, 8, Kit.CREAM)


func _build_dice_tray() -> void:
	var mat := image("mat")
	mat.name = "DiceMat"
	place(mat, Rect2(8, 128, 234, 118))
	group_bc.add_child(mat)
	slot_dice = _slot(group_bc, "SlotDice", Rect2(15, 10, 220, 220))
	var hit := Button.new()
	hit.name = "DiceHit"
	flat_hit(hit)
	hit.tooltip_text = "掷骰"
	place(hit, Rect2(25, 20, 200, 220))
	hit.pressed.connect(func() -> void: dice_pressed.emit())
	group_bc.add_child(hit)
	step_badge = Control.new()
	step_badge.name = "StepBadge"
	step_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(step_badge, Rect2(150, 0, 123, 56))
	var sb := nine("badge_step")
	sb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	step_badge.add_child(sb)
	step_badge_label = label("", 26, Kit.INK, "title", 700)
	step_badge_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	step_badge_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	place(step_badge_label, Rect2(44, 0, 74, 54))
	step_badge.add_child(step_badge_label)
	# 步数牌右半截伸出骰子的点击区：以前点在牌上会「点穿」到下面的地图、选中被挡住的目的地（复检 UIRES-5）。
	# 整块牌接住点击，和点骰子一样（只在掷骰阶段有用，走路阶段点它什么也不发生）
	var badge_hit := Button.new()
	badge_hit.name = "StepBadgeHit"
	flat_hit(badge_hit)
	badge_hit.tooltip_text = "这回能走的步数"
	badge_hit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	badge_hit.pressed.connect(func() -> void: dice_pressed.emit())
	step_badge.add_child(badge_hit)
	step_badge.visible = false
	group_bc.add_child(step_badge)


func set_step_badge(text: String) -> void:
	step_badge.visible = not text.is_empty()
	step_badge_label.text = text


func _build_dock() -> void:
	# 右下（设计像素 600×240）：一条单行提示 → 次要按钮 → 主按钮；L叔 小头像在按钮右边，点它收起 / 打开提示
	guide_bubble = nine("pill")
	guide_bubble.name = "GuideBubble"
	place(guide_bubble, Rect2(0, 0, 464, 62))
	group_br.add_child(guide_bubble)
	slot_prompt = _slot(group_br, "SlotPrompt", PROMPT_RECT)
	# 收据改成屏幕上方的淡入淡出横幅（GameScreen 的 TurnToast），这里的插槽只留给旧节点落脚，不显示
	slot_receipt = _slot(group_br, "SlotReceipt", Rect2(0, 0, 464, 1))
	slot_receipt.visible = false
	slot_secondary = _slot(group_br, "SlotSecondary", Rect2(0, 70, 464, 58))
	slot_primary = _slot(group_br, "SlotPrimary", Rect2(0, 136, 464, 100))
	guide_portrait = TextureRect.new()
	guide_portrait.name = "GuidePortrait"
	guide_portrait.texture = load("res://assets/game/ui/lshu_title/lshu_avatar2.png") as Texture2D
	guide_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	guide_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	guide_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(guide_portrait, Rect2(474, 70, 126, 166))
	group_br.add_child(guide_portrait)
	var toggle := Button.new()
	toggle.name = "GuideToggle"
	flat_hit(toggle)
	toggle.tooltip_text = "点 L叔：收起 / 打开提示"
	place(toggle, Rect2(474, 70, 126, 166))
	toggle.pressed.connect(func() -> void: guide_toggled.emit())
	group_br.add_child(toggle)


## 提示条的行数（电脑抽的卡改了你的白银 / 货时，轮到你的提示里多一两行结果和原因）：泡泡往上长、铺满这一组的宽度
func set_prompt_lines(n: int) -> void:
	n = clampi(n, 1, 4)
	if n == _prompt_lines:
		return
	_prompt_lines = n
	if n <= 1:
		place(guide_bubble, Rect2(0, 0, 464, 62))
		if slot_prompt.get_parent() == group_br:
			place(slot_prompt, PROMPT_RECT)
		return
	var h := 62.0 + 32.0 * (n - 1)
	place(guide_bubble, Rect2(0, 62.0 - h, BR_SIZE.x, h))
	if slot_prompt.get_parent() == group_br:
		place(slot_prompt, Rect2(28, 62.0 - h + 4, BR_SIZE.x - 56, h - 8))


func prompt_lines() -> int:
	return _prompt_lines


## 提示开关的外观：关掉时 L叔 变淡
func set_hints_look(on: bool) -> void:
	guide_portrait.modulate = Color.WHITE if on else Color(1, 1, 1, 0.5)
	(group_br.get_node("GuideToggle") as Button).tooltip_text = "点 L叔：收起提示" if on else "点 L叔：打开提示"


# ------------------------------------------------------------------ 对手小卡（左上）

## seats: [{name, avatar, color, silver, goods: Array[Texture2D], acting: bool, status: String}]
func set_roster(seats: Array) -> void:
	while _chips.size() < seats.size():
		_chips.append(_make_chip(_chips.size()))
	for i in _chips.size():
		var chip: Dictionary = _chips[i]
		var root: Control = chip.root
		if i >= seats.size():
			root.visible = false
			continue
		var s: Dictionary = seats[i]
		root.visible = true
		(chip.avatar as TextureRect).texture = s.get("avatar")
		(chip.avatar as TextureRect).flip_h = bool(s.get("flip", false))
		(chip.name as Label).text = String(s.get("name", ""))
		fit_label(chip.name as Label, 186.0, 26, 18)
		(chip.silver as Label).text = str(int(s.get("silver", 0)))
		set_ring(chip.ring as Panel, s.get("color", Kit.CAMEL), 6)
		var gbox: HBoxContainer = chip.goods
		var goods: Array = s.get("goods", [])
		for c in gbox.get_children():
			gbox.remove_child(c)
			c.queue_free()
		for g in goods:
			var gi := TextureRect.new()
			gi.texture = g
			gi.custom_minimum_size = Vector2(34, 34)
			gi.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			gi.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			gi.mouse_filter = Control.MOUSE_FILTER_IGNORE
			gbox.add_child(gi)
		var acting := bool(s.get("acting", false))
		(chip.glow as Panel).visible = acting
		var status := String(s.get("status", ""))
		(chip.status_box as Control).visible = acting and not status.is_empty()
		(chip.status as Label).text = status
		(chip.status as Label).visible = acting and not status.is_empty()
		root.set_meta("acting", acting)


func chip_count() -> int:
	var n := 0
	for c in _chips:
		if (c.root as Control).visible:
			n += 1
	return n


func _make_chip(i: int) -> Dictionary:
	var root := Control.new()
	root.name = "OpponentChip_%d" % i
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(root, Rect2(0, i * 110, 520, 100))
	group_tl.add_child(root)
	var glow := Panel.new()
	glow.name = "ActingGlow"
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var gb := StyleBoxFlat.new()
	gb.bg_color = Color(Kit.OCHRE, 0.25)
	gb.set_corner_radius_all(46)
	gb.shadow_color = Color(Kit.OCHRE, 0.8)
	gb.shadow_size = 16
	glow.add_theme_stylebox_override("panel", gb)
	place(glow, Rect2(6, 6, 300, 88))
	root.add_child(glow)
	var bg := nine("chip")
	place(bg, Rect2(0, 0, 310, 100))
	root.add_child(bg)
	var av := round_avatar()
	place(av, Rect2(16, 14, 72, 72))
	root.add_child(av)
	var rg := ring(Kit.CAMEL, 6)
	place(rg, Rect2(12, 10, 80, 80))
	root.add_child(rg)
	var nm := label("", 26, Kit.INK, "title", 700)
	nm.name = "ChipName"
	nm.clip_text = true
	place(nm, Rect2(104, 16, 190, 36))
	root.add_child(nm)
	var ingot := TextureRect.new()
	ingot.texture = Kit.icon("silver")
	ingot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ingot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ingot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(ingot, Rect2(102, 54, 32, 32))
	root.add_child(ingot)
	var sv := label("", 26, Kit.INK, "title", 700)
	sv.name = "ChipSilver"
	place(sv, Rect2(138, 50, 50, 40))
	root.add_child(sv)
	var goods := HBoxContainer.new()
	goods.name = "ChipGoods"
	goods.add_theme_constant_override("separation", 0)
	goods.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(goods, Rect2(170, 52, 130, 34))
	root.add_child(goods)
	var status_box := nine("bubble")
	status_box.name = "ChipStatusBubble"
	place(status_box, Rect2(316, 8, 204, 80))
	root.add_child(status_box)
	var st := label("", 22, Kit.INK, "body", 500)
	st.name = "ChipStatus"
	st.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	st.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	st.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	st.max_lines_visible = 2
	place(st, Rect2(336, 12, 170, 56))
	root.add_child(st)
	return {"root": root, "glow": glow, "avatar": av, "ring": rg, "name": nm, "silver": sv, "goods": goods,
		"status_box": status_box, "status": st}


# ------------------------------------------------------------------ 市集面板（05）

func _build_market() -> void:
	market = Control.new()
	market.name = "MarketPanel"
	market.size = Vector2(MARKET_W, _market_h)
	market.mouse_filter = Control.MOUSE_FILTER_STOP
	market.visible = false
	add_child(market)
	market_bg = nine("panel_satchel")
	market_bg.name = "MarketSkin"
	market.add_child(market_bg)
	_build_market_tab()
	var tab := TextureRect.new()
	tab.name = "MarketTitleRibbon"
	tab.texture = load("res://assets/game/ui/city_cards/v2/ribbon.png") as Texture2D
	tab.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tab.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(tab, Rect2(160, -6, 560, 136))
	market.add_child(tab)
	market_title = label("", 46, Kit.CREAM, "display", 700)
	market_title.name = "MarketTitle"
	market_title.add_theme_color_override("font_outline_color", Color("#6B3A1C"))
	market_title.add_theme_constant_override("outline_size", 10)
	market_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	market_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	place(market_title, Rect2(240, 10, 400, 84))
	market.add_child(market_title)
	market_tabs = HBoxContainer.new()
	market_tabs.name = "MarketTabs"
	market_tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	market_tabs.add_theme_constant_override("separation", 10)
	market.add_child(market_tabs)
	market_subtitle = label("", 25, Kit.INK_SOFT, "body", 500)
	market_subtitle.name = "MarketSubtitle"
	market_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	market.add_child(market_subtitle)
	market_chain = HBoxContainer.new()
	market_chain.name = "MarketChain"
	market_chain.alignment = BoxContainer.ALIGNMENT_CENTER
	market_chain.add_theme_constant_override("separation", 4)
	market_chain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	market.add_child(market_chain)
	market_rows_scroll = ScrollContainer.new()
	market_rows_scroll.name = "MarketRowsScroll"
	market_rows_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	market.add_child(market_rows_scroll)
	var vbar := market_rows_scroll.get_v_scroll_bar()
	vbar.custom_minimum_size.x = 18
	var grab := StyleBoxFlat.new()
	grab.bg_color = Color(Kit.CAMEL, 0.85)
	grab.set_corner_radius_all(9)
	vbar.add_theme_stylebox_override("grabber", grab)
	vbar.add_theme_stylebox_override("grabber_highlight", grab)
	vbar.add_theme_stylebox_override("grabber_pressed", grab)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(Kit.CAMEL, 0.18)
	track.set_corner_radius_all(9)
	vbar.add_theme_stylebox_override("scroll", track)
	market_rows = VBoxContainer.new()
	market_rows.name = "MarketRows"
	market_rows.custom_minimum_size = Vector2(796, 0)
	market_rows.add_theme_constant_override("separation", 10)
	market_rows_scroll.add_child(market_rows)
	slot_market_extra = _slot(market, "SlotMarketExtra", Rect2())
	_build_exchange()
	market_choice = ChoiceView.new()
	market_choice.visible = false
	market_choice.connect("picked", func(id: String) -> void: choice_pressed.emit(id))
	market.add_child(market_choice)
	_layout_market()


func _layout_market() -> void:
	var h := _market_h
	market.size = Vector2(MARKET_W, h)
	place(market_bg, Rect2(0, 48, MARKET_W, h - 48))
	# 顶部压紧（副标题 → 112 高的牌面 → 一行提示），清单从 306 开始，1080p 下能看到三行半
	place(market_tabs, Rect2(40, 136, 800, 56))
	place(market_subtitle, Rect2(40, 116, 800, 30))
	place(market_chain, Rect2(40, 150, 800, 112))
	var rows_top := 306.0
	place(market_rows_scroll, Rect2(42, rows_top, 800, maxf(120.0, h - rows_top - 26)))
	_layout_exchange(h)
	if market_choice != null:
		market_choice.call("layout_in", h)
	if market_mode == "extra":
		# 事件交换：提示在上，旧控制台在提示下面，互不遮挡（复检 EI-1）
		place(slot_prompt, Rect2(52, 118, 776, 44))
		place(slot_market_extra, Rect2(46, 168, 788, h - 168 - 26))
	else:
		place(slot_market_extra, Rect2(46, 136, 788, h - 136 - 26))
		if market_mode != "":
			place(slot_prompt, Rect2(52, 264, 776, 40))


## mode: "" 关闭 / "trade" 交易页 / "extra" 事件交换（旧控制台内容搬进面板）
## 主按钮和次要按钮始终留在右下同一个位置（面板只占到按钮区上沿）；交易时收起 L叔 头像和泡泡，
## 「下一步」提示搬进面板顶部。
func set_market_mode(mode: String) -> void:
	if mode == market_mode:
		return
	var was := market_mode
	market_mode = mode
	market.visible = mode != ""
	var in_market := mode != ""
	if in_market != (was != ""):
		set_market_collapsed(false, false)     # 每次打开 / 关掉都回到展开
	if in_market and was == "":
		slot_prompt.reparent(market, false)
	elif not in_market:
		slot_prompt.reparent(group_br, false)
		place(slot_prompt, PROMPT_RECT)
		var lines := _prompt_lines
		_prompt_lines = 1
		set_prompt_lines(lines)
	guide_bubble.visible = not in_market
	var trade := mode == "trade"
	if trade and was != "trade":
		market_rows_scroll.scroll_vertical = 0      # 每次打开都从最上面（最好的交易）看起（复检 MKT-1）
	market_tabs.visible = false         # 2026-09-26：页签取消，所有交易排成一张清单
	market_subtitle.visible = trade
	market_chain.visible = trade
	market_rows_scroll.visible = trade
	slot_market_extra.visible = mode == "extra"
	market_exchange.visible = mode == "exchange"
	market_choice.visible = mode == "decision"
	if mode != "exchange":
		_exchange_sig = ""
	_layout_market()


## specs: [{mode: int, text: String, selected: bool, enabled: bool}]
func set_market_tabs(specs: Array) -> void:
	var sig := JSON.stringify(specs)
	if market_tabs.get_meta("sig", "") == sig:
		return
	market_tabs.set_meta("sig", sig)
	for c in market_tabs.get_children():
		market_tabs.remove_child(c)
		c.queue_free()
	for s in specs:
		var sel := bool(s.get("selected", false))
		var b := candy(String(s.get("text", "")), "ochre" if sel else "cream", 26)
		b.name = "MarketTab_%d" % int(s.get("mode", 0))
		b.custom_minimum_size = Vector2(172, 56)
		b.disabled = not bool(s.get("enabled", true)) and not sel
		var m := int(s.get("mode", 0))
		b.pressed.connect(func() -> void: mode_tab_pressed.emit(m))
		market_tabs.add_child(b)


## entries: [{icon: Texture2D, text: String}]；sep 为两格之间的符号（牌面链用「=」，直售用「→」）
func set_market_chain(entries: Array, sep := "=") -> void:
	for c in market_chain.get_children():
		market_chain.remove_child(c)
		c.queue_free()
	var tile_w := 150.0 if entries.size() <= 4 else 124.0
	var tile_h := 112.0
	for i in entries.size():
		if i > 0:
			var eq := label(sep, 50, Kit.SATCHEL, "title", 800)
			eq.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			eq.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			eq.custom_minimum_size = Vector2(40, tile_h)
			market_chain.add_child(eq)
		market_chain.add_child(_tile(entries[i], Vector2(tile_w, tile_h), 54))


func _tile(e: Dictionary, sz: Vector2, icon_px: int) -> Control:
	var t := Control.new()
	t.custom_minimum_size = sz
	t.size = sz
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := NinePatchRect.new()
	bg.texture = tex("tile")
	bg.patch_margin_left = 36
	bg.patch_margin_right = 36
	bg.patch_margin_top = 36
	bg.patch_margin_bottom = 36
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	t.add_child(bg)
	var ic := TextureRect.new()
	ic.name = "TileIcon"
	ic.texture = e.get("icon")
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 贴图四周有约 20px 的描边：图标和字都收在里面
	var small := sz.y < 120
	var top := 8.0 if small else 12.0
	place(ic, Rect2((sz.x - icon_px) * 0.5, top, icon_px, icon_px))
	t.add_child(ic)
	var lb := label(String(e.get("text", "")), 20 if small else 23, Kit.INK, "title", 700)
	lb.name = "TileText"
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.clip_text = true
	place(lb, Rect2(10, top + icon_px - 2, sz.x - 20, 28 if small else 32))
	t.add_child(lb)
	return t


## rows: 每行 {section: String}（分段标题，不可点）或
##   {tag: String, tag_color: Color, give: {icon,text}, receive: {icon,text}, note: String, enabled: bool,
##    selected: bool, times: int, max_times: int, action: String（行尾一键成交按钮的字，空 = 没有）, check: bool（多选勾）}
func set_market_rows(rows: Array) -> void:
	for n in _market_row_nodes:
		market_rows.remove_child(n)
		(n as Node).queue_free()
	_market_row_nodes.clear()
	for i in rows.size():
		var r: Dictionary = rows[i]
		if r.has("section"):
			var head_box := MarginContainer.new()
			head_box.name = "TradeSection_%d" % i
			head_box.add_theme_constant_override("margin_left", 18)
			head_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var head := label(String(r["section"]), 24, Kit.SATCHEL, "title", 700)
			head.custom_minimum_size = Vector2(760, 42)
			head.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
			head_box.add_child(head)
			market_rows.add_child(head_box)
			_market_row_nodes.append(head_box)
			continue
		if r.has("notice"):
			# 做不成交易的原因：一块醒目的说明，放在清单最上面
			var box := PanelContainer.new()
			box.name = "TradeNotice_%d" % i
			box.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color("#FFF1D6")
			sb.border_color = Kit.OCHRE
			sb.set_border_width_all(3)
			sb.set_corner_radius_all(22)
			sb.content_margin_left = 24
			sb.content_margin_right = 24
			sb.content_margin_top = 14
			sb.content_margin_bottom = 14
			box.add_theme_stylebox_override("panel", sb)
			var t := label(String(r["notice"]), 26, Kit.INK, "title", 700)
			t.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
			t.custom_minimum_size = Vector2(740, 0)
			box.add_child(t)
			market_rows.add_child(box)
			_market_row_nodes.append(box)
			continue
		if r.has("line"):
			# 做不了的组合：只留一行灰字，不占地方
			var line_box := MarginContainer.new()
			line_box.name = "TradeLine_%d" % i
			line_box.add_theme_constant_override("margin_left", 30)
			line_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var line := label(String(r["line"]), 22, Kit.INK_SOFT, "body", 500)
			line.custom_minimum_size = Vector2(740, 34)
			line.clip_text = true
			line_box.add_child(line)
			market_rows.add_child(line_box)
			_market_row_nodes.append(line_box)
			continue
		var b := Button.new()
		b.name = "TradeOption_%d" % i
		flat_hit(b)
		b.custom_minimum_size = Vector2(796, 100)
		var enabled := bool(r.get("enabled", true))
		var sel := bool(r.get("selected", false))
		b.set_meta("enabled", enabled)
		b.set_meta("selected", sel)
		var bg := nine("row_sel" if sel else "row")
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		if not enabled:
			bg.modulate = Color(0.9, 0.87, 0.82, 0.8)
		b.add_child(bg)
		var tag := ring(Kit.CREAM, 0, r.get("tag_color", Kit.CAMEL) if enabled else Kit.DISABLED_DEEP)
		place(tag, Rect2(16, 26, 48, 48))
		b.add_child(tag)
		var tag_l := label(String(r.get("tag", "")), 26, Kit.CREAM, "title", 700)
		tag_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tag_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		place(tag_l, Rect2(16, 26, 48, 48))
		b.add_child(tag_l)
		var give := _tile(r.get("give", {}), Vector2(150, 86), 42)
		place(give, Rect2(72, 7, 150, 86))
		b.add_child(give)
		var arrow := label("→", 40, Kit.SATCHEL if enabled else Kit.DISABLED_DEEP, "title", 700)
		arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		place(arrow, Rect2(222, 7, 46, 86))
		b.add_child(arrow)
		var recv := _tile(r.get("receive", {}), Vector2(150, 86), 42)
		place(recv, Rect2(268, 7, 150, 86))
		b.add_child(recv)
		if not enabled:
			give.modulate = Color(1, 1, 1, 0.6)
			recv.modulate = Color(1, 1, 1, 0.6)
		var max_t := int(r.get("max_times", 0))
		var stepper := sel and enabled and max_t > 1
		var note := label(String(r.get("note", "")), 22, Kit.INK if enabled else Kit.INK_SOFT, "body", 500)
		note.name = "RowNote"
		note.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		note.max_lines_visible = 2
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var action := String(r.get("action", "")) if enabled else ""
		var note_w := 214.0 if not action.is_empty() or bool(r.get("check_row", false)) else 350.0
		place(note, Rect2(432, 4, note_w, 46 if stepper else 92))
		b.add_child(note)
		for c in b.get_children():
			if c is Control:
				(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		if stepper:
			var t := int(r.get("times", 1))
			var minus := candy("−", "cream", 28)
			minus.name = "TimesMinus"
			minus.disabled = t <= 1
			place(minus, Rect2(432, 50, 54, 44))
			minus.pressed.connect(func() -> void: trade_times_pressed.emit(-1))
			b.add_child(minus)
			var tl := label("%d 次" % t, 24, Kit.INK, "title", 700)
			tl.name = "TimesLabel"
			tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			tl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			place(tl, Rect2(488, 50, 100, 44))
			b.add_child(tl)
			var plus := candy("+", "cream", 28)
			plus.name = "TimesPlus"
			plus.disabled = t >= max_t
			place(plus, Rect2(590, 50, 54, 44))
			plus.pressed.connect(func() -> void: trade_times_pressed.emit(1))
			b.add_child(plus)
		var idx := i
		if not action.is_empty():
			var go := candy(action, "ochre", 26)
			go.name = "RowGo"
			go.tooltip_text = "一键成交"
			place(go, Rect2(654, 22, 128, 64))
			go.pressed.connect(func() -> void: trade_row_action.emit(idx))
			b.add_child(go)
		if bool(r.get("check_row", false)):
			var box := ring(Kit.SATCHEL, 5, Kit.OCHRE if sel else Kit.CREAM)
			place(box, Rect2(706, 26, 48, 48))
			b.add_child(box)
			if sel:
				var tick := label("✓", 34, Kit.INK, "title", 700)
				tick.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				tick.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				place(tick, Rect2(706, 24, 48, 48))
				tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
				b.add_child(tick)
			box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.pressed.connect(func() -> void: trade_row_pressed.emit(idx))
		market_rows.add_child(b)
		_market_row_nodes.append(b)


func market_row_count() -> int:
	return _market_row_nodes.filter(func(n): return n is Button).size()


## 第 i 个节点（含分段标题；分段标题返回 null）
func market_row(i: int) -> Button:
	return _market_row_nodes[i] as Button if i >= 0 and i < _market_row_nodes.size() else null


# ------------------------------------------------------------------ 事件交换

## Carlos 2026-09-26：「这个商品交换面板实在是太丑了」——原来是把旧卷轴的两列按钮、来源下拉框、状态条整块搬进市集。
## 现在是三块：① 交出哪一件（挎包里的货，大格子）② 换回什么（可换的货，一行 8 格；来源不止一个时，同一行右边挑「从谁那换」，
## 3–4 位玩家、名字长、一行放不下时，来源在 ② 下面自己占一整行、可折行，名字过长加省略号，复检 UIRES-1）
## 底部一条预览（「象牙 → 黑胡椒，从公共商品堆」）。点格子只是选中，成交仍在右下「确认交换」。
const EXCHANGE_TILE := Vector2(152, 116)
const EXCHANGE_RECV_TILE := Vector2(92, 100)
const EXCHANGE_GAP := 8
const EXCHANGE_ROW_W := 784.0          # ② 那一行的可用宽（面板内 8..792）
const EXCHANGE_SOURCE_H := 50.0
const EXCHANGE_SOURCE_GAP := 8
const EXCHANGE_SOURCE_TEXT_MAX := 206.0   # 来源按钮上名字最多占的宽：22 号字约 9 个字，再长加省略号
const EXCHANGE_SOURCE_PAD := 44.0


func _build_exchange() -> void:
	market_exchange = Control.new()
	market_exchange.name = "MarketExchange"
	market_exchange.visible = false
	market_exchange.mouse_filter = Control.MOUSE_FILTER_IGNORE
	market.add_child(market_exchange)
	var sub := label("", 25, Kit.INK_SOFT, "body", 500)
	sub.name = "ExchangeSubtitle"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	place(sub, Rect2(0, 0, 800, 34))
	market_exchange.add_child(sub)
	var give_head := label("① 交出哪一件？", 27, Kit.SATCHEL, "title", 700)
	give_head.name = "ExchangeGiveHead"
	place(give_head, Rect2(8, 40, 500, 36))
	market_exchange.add_child(give_head)
	_exchange_give_row = HBoxContainer.new()
	_exchange_give_row.name = "ExchangeGiveRow"
	_exchange_give_row.add_theme_constant_override("separation", 14)
	place(_exchange_give_row, Rect2(8, 78, 784, EXCHANGE_TILE.y))
	market_exchange.add_child(_exchange_give_row)
	_exchange_recv_head = label("② 换回什么？", 27, Kit.SATCHEL, "title", 700)
	_exchange_recv_head.name = "ExchangeReceiveHead"
	_exchange_recv_head.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	market_exchange.add_child(_exchange_recv_head)
	# 来源按钮（复检 UIRES-1：4 位玩家时原来一行往右长，后两个按钮跑出面板、出了屏幕，小朋友点不到）：
	# 放得下就和 ② 同一行靠右；放不下就在 ② 下面自己占一整行（784 宽），再放不下就折到下一行，永远不出面板
	_exchange_targets = HFlowContainer.new()
	_exchange_targets.name = "ExchangeTargets"
	_exchange_targets.alignment = FlowContainer.ALIGNMENT_END
	_exchange_targets.add_theme_constant_override("h_separation", EXCHANGE_SOURCE_GAP)
	_exchange_targets.add_theme_constant_override("v_separation", EXCHANGE_SOURCE_GAP)
	_exchange_targets.mouse_filter = Control.MOUSE_FILTER_IGNORE
	market_exchange.add_child(_exchange_targets)
	_exchange_recv_scroll = ScrollContainer.new()
	_exchange_recv_scroll.name = "ExchangeReceiveScroll"
	_exchange_recv_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	market_exchange.add_child(_exchange_recv_scroll)
	_exchange_recv_grid = GridContainer.new()
	_exchange_recv_grid.name = "ExchangeReceiveGrid"
	_exchange_recv_grid.columns = 8   # 公共商品堆最多 15 种（交出的那种灰着留在原位）：1080p 下两行全放下
	_exchange_recv_grid.add_theme_constant_override("h_separation", EXCHANGE_GAP)
	_exchange_recv_grid.add_theme_constant_override("v_separation", 10)
	_exchange_recv_scroll.add_child(_exchange_recv_grid)
	_exchange_preview = PanelContainer.new()
	_exchange_preview.name = "ExchangePreview"
	_exchange_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#FFF1D6")
	sb.border_color = Kit.OCHRE
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(22)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	_exchange_preview.add_theme_stylebox_override("panel", sb)
	market_exchange.add_child(_exchange_preview)
	var line := HBoxContainer.new()
	line.name = "PreviewLine"
	line.alignment = BoxContainer.ALIGNMENT_CENTER
	line.add_theme_constant_override("separation", 10)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_exchange_preview.add_child(line)


func _layout_exchange(h: float) -> void:
	# 面板里标题飘带（到 118）以下归交换；1080p 下面板约 690–700 高，两行「换回」格子 + 预览条正好放下，更多就在格子区里滚
	var eh := h - 118.0 - 18.0
	place(market_exchange, Rect2(40, 118, 800, eh))
	var head_y := 78.0 + EXCHANGE_TILE.y + 12.0
	var grid_y := head_y + 54.0
	if _exchange_targets_rows <= 0:
		# 和 ② 同一行，从标题字后面到行尾，靠右排（set_exchange_view 已确认放得下）
		var hx := 8.0 + _exchange_head_width() + 16.0
		place(_exchange_recv_head, Rect2(8, head_y, maxf(0.0, hx - 8.0), 50))
		place(_exchange_targets, Rect2(hx, head_y, maxf(0.0, 8.0 + EXCHANGE_ROW_W - hx), EXCHANGE_SOURCE_H))
		_exchange_targets.alignment = FlowContainer.ALIGNMENT_END
	else:
		# 自己占 ② 下面的整行（可折行），「换回」格子区跟着往下挪；1080p 下格子区放不下两行时在格子区里滚
		place(_exchange_recv_head, Rect2(8, head_y, EXCHANGE_ROW_W, 50))
		var rows_h := _exchange_targets_rows * EXCHANGE_SOURCE_H + (_exchange_targets_rows - 1) * EXCHANGE_SOURCE_GAP
		place(_exchange_targets, Rect2(8, head_y + 50.0, EXCHANGE_ROW_W, rows_h))
		_exchange_targets.alignment = FlowContainer.ALIGNMENT_BEGIN
		grid_y = head_y + 50.0 + rows_h + 10.0
	var preview_h := 64.0
	place(_exchange_preview, Rect2(0, eh - preview_h, 800, preview_h))
	place(_exchange_recv_scroll, Rect2(4, grid_y, 796, maxf(EXCHANGE_RECV_TILE.y, eh - preview_h - 10.0 - grid_y)))


func _exchange_head_width() -> float:
	var font := _exchange_recv_head.get_theme_font("font")
	if font == null:
		return 420.0
	return font.get_string_size(_exchange_recv_head.text, HORIZONTAL_ALIGNMENT_LEFT, -1, _exchange_recv_head.get_theme_font_size("font_size")).x


## 来源一行摆得下（标题 + 「从：」+ 按钮 ≤ 784）→ 0；否则按 784 宽折行，返回占几行
func _exchange_source_rows() -> int:
	var widths: Array[float] = []
	for c in _exchange_targets.get_children():
		if c is Control:
			widths.append((c as Control).get_combined_minimum_size().x)
	if widths.is_empty():
		return 0
	var total := 0.0
	for w in widths:
		total += w
	total += EXCHANGE_SOURCE_GAP * (widths.size() - 1)
	if _exchange_head_width() + 16.0 + total <= EXCHANGE_ROW_W:
		return 0
	var rows := 1
	var x := 0.0
	for w in widths:
		var need := w if x <= 0.0 else x + EXCHANGE_SOURCE_GAP + w
		if need > EXCHANGE_ROW_W and x > 0.0:
			rows += 1
			x = w
		else:
			x = need
	return rows


## 按钮上的名字：先从 px_max 缩到 px_min，还放不下就截成「前几个字…」（完整名字放在 tooltip）；按钮宽 = 字宽 + 左右留白
static func fit_button_ellipsis(b: Button, max_w: float, px_max: int, px_min: int, pad: float) -> void:
	var font := b.get_theme_font("font")
	var full := b.text
	var px := px_max
	while px > px_min and font != null and font.get_string_size(full, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > max_w:
		px -= 1
	b.add_theme_font_size_override("font_size", px)
	var shown := full
	if font != null and font.get_string_size(full, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > max_w:
		var n := full.length() - 1
		while n > 1 and font.get_string_size(full.left(n) + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > max_w:
			n -= 1
		shown = full.left(n) + "…"
	b.text = shown
	b.clip_text = true
	var tw := font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x if font != null else max_w
	b.custom_minimum_size.x = ceilf(minf(max_w, tw) + pad)


## d: {subtitle, give: [{id, icon, text, selected, enabled}], targets: [{id, text, selected}], receive_head,
##     receive: [{id, icon, text, selected, enabled}], preview: {give: {icon,text}, receive: {icon,text}, from} 或 {}, hint}
## 格子只在货物清单变了时重建（重建会吃掉正在按下的那一下，复检 LC-4）；选中 / 可点只改状态
func set_exchange_view(d: Dictionary) -> void:
	(market_exchange.get_node("ExchangeSubtitle") as Label).text = String(d.get("subtitle", ""))
	_exchange_recv_head.text = String(d.get("receive_head", "② 换回什么？"))
	var gives: Array = d.get("give", [])
	var targets: Array = d.get("targets", [])
	var recvs: Array = d.get("receive", [])
	# 三块各自比对：换来源只重建「换回」那一格区，「交出」的格子不动
	var sigs := [
		JSON.stringify(gives.map(func(e): return [e.id, e.text])),
		JSON.stringify(targets.map(func(e): return [e.id, e.text])),
		JSON.stringify(recvs.map(func(e): return [e.id, e.text])),
	]
	var old: Array = Array(_exchange_sig.split("\n")) if not _exchange_sig.is_empty() else ["", "", ""]
	_exchange_sig = "\n".join(sigs)
	if sigs[0] != old[0]:
		_clear_exchange_box(_exchange_give_row, "give:")
		for e in gives:
			var b := _exchange_tile(e, EXCHANGE_TILE, 52)
			b.name = "ExchangeGive_%s" % e.id
			var gid := String(e.id)
			b.pressed.connect(func() -> void: exchange_give_pressed.emit(gid))
			_exchange_give_row.add_child(b)
			_exchange_nodes["give:" + gid] = b
	if sigs[1] != old[1]:
		_clear_exchange_box(_exchange_targets, "target:")
		# 只有一个来源（通常是公共商品堆）就不摆按钮，写进标题里
		if targets.size() > 1:
			var from := label("从：", 24, Kit.INK_SOFT, "body", 700)
			from.name = "ExchangeFrom"
			from.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			from.custom_minimum_size = Vector2(0, EXCHANGE_SOURCE_H)
			_exchange_targets.add_child(from)
			for t in targets:
				var tb := candy(String(t.text), "cream", 24)
				tb.name = "ExchangeTarget_%s" % t.id
				tb.tooltip_text = String(t.text)
				tb.custom_minimum_size = Vector2(0, EXCHANGE_SOURCE_H)
				fit_button_ellipsis(tb, EXCHANGE_SOURCE_TEXT_MAX, 24, 22, EXCHANGE_SOURCE_PAD)
				var tid := String(t.id)
				tb.pressed.connect(func() -> void: exchange_target_pressed.emit(tid))
				_exchange_targets.add_child(tb)
				_exchange_nodes["target:" + tid] = tb
	var rows := _exchange_source_rows()
	if rows != _exchange_targets_rows or sigs[1] != old[1]:
		_exchange_targets_rows = rows
		_layout_exchange(_market_h)
	if sigs[2] != old[2]:
		_clear_exchange_box(_exchange_recv_grid, "recv:")
		_exchange_recv_scroll.scroll_vertical = 0
		for e in recvs:
			var b := _exchange_tile(e, EXCHANGE_RECV_TILE, 42)
			b.name = "ExchangeReceive_%s" % e.id
			var rid := String(e.id)
			b.pressed.connect(func() -> void: exchange_receive_pressed.emit(rid))
			_exchange_recv_grid.add_child(b)
			_exchange_nodes["recv:" + rid] = b
	for e in gives:
		_exchange_tile_state(_exchange_nodes.get("give:" + String(e.id)), e)
	for e in recvs:
		_exchange_tile_state(_exchange_nodes.get("recv:" + String(e.id)), e)
	for t in targets:
		var tb: Button = _exchange_nodes.get("target:" + String(t.id))
		if tb != null:
			set_candy_color(tb, "ochre" if bool(t.get("selected", false)) else "cream")
	_paint_exchange_preview(d.get("preview", {}), String(d.get("hint", "")))


func _clear_exchange_box(box: Node, key_prefix: String) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	for k in _exchange_nodes.keys():
		if String(k).begins_with(key_prefix):
			_exchange_nodes.erase(k)


## candy() 按钮换底色：改它身上那层 CandySkin（再调一次 skin_button 会把新底垫在旧底下面，看不出变化）
static func set_candy_color(b: Button, color: String) -> void:
	var s := b.get_node_or_null("CandySkin")
	if s == null:
		CandySkinLib.skin_button(b, color)
		return
	s.skin = CandySkinLib.tex("btn_" + color)
	s.skin_pressed = CandySkinLib.tex("btn_%s_pressed" % color)
	s.nine = CandySkinLib.margins("btn_" + color)
	(s as CanvasItem).queue_redraw()


## 按钮上的字太长就缩（玩家名最长 12 个字）
static func fit_label_button(b: Button, max_w: float, px_max: int, px_min: int) -> void:
	var font := b.get_theme_font("font")
	var px := px_max
	while px > px_min and font != null and font.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > max_w:
		px -= 2
	b.add_theme_font_size_override("font_size", px)
	b.clip_text = true
	b.custom_minimum_size.x = minf(max_w, font.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x if font != null else max_w) + 44.0


func _exchange_tile(e: Dictionary, sz: Vector2, icon_px: int) -> Button:
	var b := Button.new()
	flat_hit(b)
	b.custom_minimum_size = sz
	b.size = sz
	var bg := NinePatchRect.new()
	bg.name = "Bg"
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	b.add_child(bg)
	var ic := TextureRect.new()
	ic.name = "TileIcon"
	ic.texture = e.get("icon")
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 贴图四周约 20px 是描边和小花：图标、字都收在里面，字不压底边
	place(ic, Rect2((sz.x - icon_px) * 0.5, 10, icon_px, icon_px))
	b.add_child(ic)
	var lb := label(String(e.get("text", "")), 22, Kit.INK, "title", 700)
	lb.name = "TileText"
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.clip_text = true
	place(lb, Rect2(10, 10 + icon_px, sz.x - 20, 30))
	b.add_child(lb)
	# 选中：右上角一个橙色小勾
	var tick_bg := ring(Kit.CREAM, 3, Kit.OCHRE)
	tick_bg.name = "Tick"
	place(tick_bg, Rect2(sz.x - 42, 4, 36, 36))
	b.add_child(tick_bg)
	var tick := label("✓", 24, Kit.INK, "title", 700)
	tick.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tick.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	place(tick, Rect2(0, 0, 36, 36))
	tick_bg.add_child(tick)
	return b


func _exchange_tile_state(b: Button, e: Dictionary) -> void:
	if b == null:
		return
	var sel := bool(e.get("selected", false))
	var enabled := bool(e.get("enabled", true))
	var bg := b.get_node("Bg") as NinePatchRect
	bg.texture = tex("pocket_sel" if sel else "tile")
	var m := 30 if sel else 36
	bg.patch_margin_left = m
	bg.patch_margin_right = m
	bg.patch_margin_top = m
	bg.patch_margin_bottom = m
	(b.get_node("Tick") as Control).visible = sel
	b.disabled = not enabled
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if enabled else Control.CURSOR_ARROW
	b.modulate = Color.WHITE if enabled else Color(1, 1, 1, 0.42)
	b.set_meta("selected", sel)
	b.set_meta("enabled", enabled)


func _paint_exchange_preview(pv: Dictionary, hint: String) -> void:
	var line := _exchange_preview.get_node("PreviewLine") as HBoxContainer
	for c in line.get_children():
		line.remove_child(c)
		c.queue_free()
	if pv.is_empty():
		var t := label(hint, 26, Kit.INK, "title", 700)
		t.name = "PreviewHint"
		t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line.add_child(t)
		return
	for k in ["give", "receive"]:
		if k == "receive":
			var ar := label("→", 36, Kit.SATCHEL, "title", 700)
			ar.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			line.add_child(ar)
		var e: Dictionary = pv.get(k, {})
		var ic := TextureRect.new()
		ic.texture = e.get("icon")
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.custom_minimum_size = Vector2(48, 48)
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(ic)
		var t := label(String(e.get("text", "")), 28, Kit.INK, "title", 700)
		t.name = "PreviewGive" if k == "give" else "PreviewReceive"
		t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line.add_child(t)
	var from := label("（从%s换）" % String(pv.get("from", "")), 24, Kit.INK_SOFT, "body", 700)
	from.name = "PreviewFrom"
	from.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(from)


func exchange_tile(kind: String, id: String) -> Button:
	return _exchange_nodes.get("%s:%s" % [kind, id]) as Button


# ------------------------------------------------------------------ 篝火泡泡（围炉夜话）

## 左边对手小卡下面：L叔 的脸 + 对话泡泡（问题 + 电脑的回话）。整块是一个按钮，点一下收起。
## 不设倒计时；真人抽到时这回合结束收起，电脑抽到时留到下一位真人点掉或走完自己的回合（GameScreen 判断）。
const CAMPFIRE_SIZE := Vector2(620, 236)


func _build_campfire() -> void:
	campfire = Button.new()
	campfire.name = "CampfireBubble"
	flat_hit(campfire as Button)
	(campfire as Button).tooltip_text = "点一下收起"
	campfire.size = CAMPFIRE_SIZE
	campfire.visible = false
	add_child(campfire)
	var face := TextureRect.new()
	face.name = "LshuFace"
	face.texture = load("res://assets/game/ui/lshu_title/lshu_avatar2.png") as Texture2D
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(face, Rect2(0, 76, 116, 140))
	campfire.add_child(face)
	var bub := FunParts.speech_bubble()
	place(bub, Rect2(100, 0, CAMPFIRE_SIZE.x - 100, CAMPFIRE_SIZE.y - 10))
	campfire.add_child(bub)
	var head := label("篝火边聊一聊", 22, Kit.OCHRE_DEEP, "title", 700)
	head.name = "CampfireHead"
	place(head, Rect2(160, 16, 300, 30))
	campfire.add_child(head)
	var tap := label("点我收起", 20, Kit.INK_SOFT, "body", 500)
	tap.name = "CampfireTap"
	tap.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	place(tap, Rect2(CAMPFIRE_SIZE.x - 190, 16, 150, 30))
	campfire.add_child(tap)
	_campfire_text = label("", 28, Kit.INK, "title", 700)
	_campfire_text.name = "CampfireQuestion"
	_campfire_text.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_campfire_text.max_lines_visible = 2
	place(_campfire_text, Rect2(160, 46, CAMPFIRE_SIZE.x - 210, 76))
	campfire.add_child(_campfire_text)
	_campfire_replies = label("", 21, Kit.INK, "body", 500)
	_campfire_replies.name = "CampfireReplies"
	_campfire_replies.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_campfire_replies.max_lines_visible = 3
	place(_campfire_replies, Rect2(160, 122, CAMPFIRE_SIZE.x - 210, 84))
	campfire.add_child(_campfire_replies)
	(campfire as Button).pressed.connect(func() -> void:
		hide_campfire()
		campfire_dismissed.emit())


func show_campfire(question: String, replies: Array) -> void:
	_campfire_text.text = question
	var lines: Array[String] = []
	for r in replies:
		var t := String((r as Dictionary).get("text", ""))
		if not t.is_empty():
			lines.append("%s：%s" % [String((r as Dictionary).get("display_name", "")), t])
	_campfire_replies.text = "\n".join(lines)
	campfire.visible = true
	campfire.modulate.a = 0.0
	create_tween().tween_property(campfire, "modulate:a", 1.0, 0.2)


func hide_campfire() -> void:
	campfire.visible = false


# ------------------------------------------------------------------ 换人卡（同屏多位真人）

func _build_handover() -> void:
	handover = Control.new()
	handover.name = "HandoverCard"
	handover.mouse_filter = Control.MOUSE_FILTER_STOP
	handover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	handover.visible = false
	add_child(handover)
	var dim := ColorRect.new()
	dim.color = Color(0.16, 0.1, 0.06, 0.45)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	handover.add_child(dim)
	_handover_card = Control.new()
	_handover_card.name = "Card"
	_handover_card.size = Vector2(760, 560)
	_handover_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	handover.add_child(_handover_card)
	var bg := nine("panel_satchel")
	place(bg, Rect2(0, 60, 760, 500))
	_handover_card.add_child(bg)
	_handover_bg = bg
	handover_ring = ring(Kit.CAMEL, 10, Kit.CREAM)
	place(handover_ring, Rect2(270, 0, 220, 220))
	_handover_card.add_child(handover_ring)
	handover_avatar = round_avatar()
	place(handover_avatar, Rect2(282, 12, 196, 196))
	_handover_card.add_child(handover_avatar)
	handover_title = label("", 54, Kit.INK, "display", 700)
	handover_title.name = "HandoverTitle"
	handover_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	place(handover_title, Rect2(40, 236, 680, 70))
	_handover_card.add_child(handover_title)
	handover_sub = label("", 28, Kit.INK_SOFT, "body", 500)
	handover_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	handover_sub.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	place(handover_sub, Rect2(60, 310, 640, 80))
	_handover_card.add_child(handover_sub)
	# 电脑抽的卡改了这位的白银 / 货：一块奶油底的留言，写结果和原因（没有时不占地方）
	handover_note = label("", 26, Kit.INK, "title", 700)
	handover_note.name = "HandoverNote"
	handover_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	handover_note.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	handover_note.max_lines_visible = 4
	handover_note.visible = false
	place(handover_note, Rect2(60, 306, 640, 36))   # 先定宽：自动折行的最小高度按这个宽算
	_handover_card.add_child(handover_note)
	handover_button = candy("我来掷骰！", "ochre", 40)
	handover_button.name = "HandoverGo"
	place(handover_button, Rect2(170, 410, 420, 110))
	handover_button.pressed.connect(func() -> void: handover_pressed.emit())
	_handover_card.add_child(handover_button)


func show_handover(avatar: Texture2D, who: String, seat_color: Color, sub: String, note := "") -> void:
	handover_avatar.texture = avatar
	set_ring(handover_ring, seat_color, 10, Kit.CREAM)
	handover_title.text = "轮到%s啦" % who
	fit_label(handover_title, 660.0, 54, 32)
	handover_sub.text = sub
	# 有留言时卡片往下长：标题 → 留言（最多 4 行）→ 说明 → 按钮
	var extra := 0.0
	handover_note.text = note
	handover_note.visible = not note.is_empty()
	if not note.is_empty():
		var lines := 0
		for part in note.split("\n"):
			lines += maxi(1, ceili(float(part.length()) / 24.0))
		lines = mini(lines, 4)
		extra = 36.0 * lines + 16.0
		handover_note.size = Vector2(640, 36)
		place(handover_note, Rect2(60, 306, 640, 36.0 * lines))
	place(handover_sub, Rect2(60, 310 + extra, 640, 80))
	place(handover_button, Rect2(170, 410 + extra, 420, 110))
	place(_handover_bg, Rect2(0, 60, 760, 500 + extra))
	_handover_card.size = Vector2(760, 560 + extra)
	_layout_overlays(get_viewport_rect().size if is_inside_tree() else Vector2(1920, 1080))
	handover.visible = true
	handover.modulate.a = 0.0
	create_tween().tween_property(handover, "modulate:a", 1.0, 0.18)


# ------------------------------------------------------------------ 结算（06）

func _build_result() -> void:
	result = Control.new()
	result.name = "ResultPage"
	result.mouse_filter = Control.MOUSE_FILTER_STOP
	result.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	result.visible = false
	add_child(result)
	var dim := ColorRect.new()
	dim.color = Color(0.2, 0.13, 0.06, 0.42)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	result.add_child(dim)
	_result_card = Control.new()
	_result_card.name = "Card"
	_result_card.size = Vector2(1000, 1040)
	_result_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.add_child(_result_card)
	_result_title = label("", 110, Color("#FFE7A6"), "display", 800)
	_result_title.name = "ResultTitle"
	_result_title.add_theme_color_override("font_outline_color", Color("#5A3418"))
	_result_title.add_theme_constant_override("outline_size", 22)
	_result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	place(_result_title, Rect2(0, 0, 1000, 150))
	_result_card.add_child(_result_title)
	var bg := nine("panel_satchel")
	place(bg, Rect2(40, 170, 920, 690))
	_result_card.add_child(bg)
	_result_rows = VBoxContainer.new()
	_result_rows.name = "ResultRows"
	_result_rows.add_theme_constant_override("separation", 14)
	place(_result_rows, Rect2(96, 218, 808, 440))
	_result_card.add_child(_result_rows)
	_result_progress = label("", 28, Kit.INK, "body", 500)
	_result_progress.name = "ResultProgress"
	_result_progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_progress.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	place(_result_progress, Rect2(96, 690, 808, 96))
	_result_card.add_child(_result_progress)
	slot_result_buttons = HBoxContainer.new()
	slot_result_buttons.name = "ResultButtons"
	slot_result_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	slot_result_buttons.add_theme_constant_override("separation", 40)
	place(slot_result_buttons, Rect2(40, 900, 920, 120))
	_result_card.add_child(slot_result_buttons)
	_result_guide = Control.new()
	_result_guide.name = "ResultGuide"
	_result_guide.size = Vector2(560, 180)
	_result_guide.mouse_filter = Control.MOUSE_FILTER_IGNORE
	result.add_child(_result_guide)
	var face := TextureRect.new()
	face.texture = load("res://assets/game/ui/lshu_title/lshu_avatar2.png") as Texture2D
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	place(face, Rect2(0, 10, 150, 170))
	_result_guide.add_child(face)
	var bub := nine("bubble")
	place(bub, Rect2(150, 0, 410, 150))
	_result_guide.add_child(bub)
	_result_bubble_text = label("", 26, Kit.INK, "body", 500)
	_result_bubble_text.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_result_bubble_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	place(_result_bubble_text, Rect2(196, 12, 330, 100))
	_result_guide.add_child(_result_bubble_text)


func hide_result() -> void:
	result.visible = false
	for grp in [group_tl, group_tc, group_tr, group_bl, group_bc, group_br]:
		(grp as Control).visible = true
	market.visible = market_mode != ""


## 开新局 / 回开场：市集、换人卡、结算页全部复位，右下按钮组一定看得见（复检 MS-1：上一局开着市集回开场，
## 下一局右下角整组按钮消失，卡在第一座城）
func reset_for_new_match() -> void:
	set_market_mode("")
	handover.visible = false
	hide_campfire()
	set_prompt_lines(1)
	hide_result()
	group_br.visible = true
	guide_portrait.visible = true


## standings: [{rank, name, avatar, color, silver, goods, winner, flip}]
func show_result(title: String, standings: Array, progress_text: String, guide_text: String) -> void:
	_result_title.text = title
	fit_label(_result_title, 960.0, 110, 48)
	for c in _result_rows.get_children():
		_result_rows.remove_child(c)
		c.queue_free()
	for s in standings:
		_result_rows.add_child(_result_row(s))
	_result_progress.text = progress_text
	_result_progress.visible = not progress_text.is_empty()
	_result_bubble_text.text = guide_text
	for grp in [group_tl, group_tc, group_tr, group_bl, group_bc, group_br, market, handover, campfire]:
		(grp as Control).visible = false
	result.visible = true
	result.modulate.a = 0.0
	create_tween().tween_property(result, "modulate:a", 1.0, 0.25)
	_layout_overlays(size)


func _result_row(s: Dictionary) -> Control:
	var winner := bool(s.get("winner", false))
	var row := Control.new()
	row.name = "ResultRow_%d" % int(s.get("rank", 0))
	row.custom_minimum_size = Vector2(808, 96)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := nine("winner_row" if winner else "plain_row")
	place(bg, Rect2(40 if winner else 60, 0, 768 if winner else 748, 96))
	row.add_child(bg)
	var rank := image("rank_%d" % clampi(int(s.get("rank", 1)), 1, 4))
	place(rank, Rect2(0, 0, 96, 96))
	row.add_child(rank)
	var num := label(str(int(s.get("rank", 1))), 40, Kit.CREAM if int(s.get("rank", 1)) <= 3 else Kit.INK, "title", 800)
	num.add_theme_color_override("font_outline_color", Color("#5A3418"))
	num.add_theme_constant_override("outline_size", 8 if int(s.get("rank", 1)) <= 3 else 0)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	place(num, Rect2(0, 8 if int(s.get("rank", 1)) == 1 else 0, 96, 96))
	row.add_child(num)
	var rg := ring(s.get("color", Kit.CAMEL), 6, Kit.CREAM)
	place(rg, Rect2(112, 8, 80, 80))
	row.add_child(rg)
	var av := round_avatar()
	av.texture = s.get("avatar")
	av.flip_h = bool(s.get("flip", false))
	place(av, Rect2(118, 14, 68, 68))
	row.add_child(av)
	var nm := label(String(s.get("name", "")), 32, Kit.INK, "title", 700)
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	fit_label(nm, 276.0, 32, 20)
	place(nm, Rect2(210, 0, 280, 96))
	row.add_child(nm)
	var ingot := TextureRect.new()
	ingot.texture = Kit.icon("silver")
	ingot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ingot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	place(ingot, Rect2(500, 26, 44, 44))
	row.add_child(ingot)
	var sv := label("白银 %d" % int(s.get("silver", 0)), 28, Kit.INK, "body", 800)
	sv.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	place(sv, Rect2(548, 0, 130, 96))
	row.add_child(sv)
	var gd := label("货物 %d" % int(s.get("goods", 0)), 26, Kit.INK_SOFT, "body", 700)
	gd.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	place(gd, Rect2(684, 0, 120, 96))
	row.add_child(gd)
	return row


# ------------------------------------------------------------------ 布局

func layout(view: Vector2) -> void:
	k = minf(view.x / DESIGN.x, view.y / DESIGN.y)
	var g := GUTTER * k
	for grp in [group_tl, group_tc, group_tr, group_bl, group_bc, group_br, market]:
		(grp as Control).scale = Vector2(k, k)
	group_tl.position = Vector2(g, g)
	group_tc.position = Vector2(roundf((view.x - TC_SIZE.x * k) * 0.5), g * 0.6)
	group_tr.position = Vector2(view.x - TR_SIZE.x * k - g, g)
	group_bl.position = Vector2(g, view.y - BL_SIZE.y * k - g * 0.5)
	group_bc.position = Vector2(g + BL_SIZE.x * k + 16 * k, view.y - BC_SIZE.y * k - g * 0.4)
	group_br.position = Vector2(view.x - BR_SIZE.x * k - g * 0.5, view.y - BR_SIZE.y * k - g * 0.3)
	# 市集面板：右上胶囊之下，到右下按钮区上沿为止（按钮不进面板，位置全程不动）
	var top := (TR_SIZE.y + 10.0) * k + g
	var bottom := group_br.position.y + (DOCK_BUTTONS_TOP - MARKET_GAP) * k
	_market_h = maxf(420.0, (bottom - top) / k)
	market.scale = Vector2(k, k)
	_view_w = view.x
	_market_open_x = view.x - MARKET_W * k - g
	market.position = Vector2(_market_open_x, top)
	_place_market()
	# 篝火泡泡：左边对手小卡下面（1–3 位对手都不压住），挎包上面
	campfire.scale = Vector2(k, k)
	campfire.position = Vector2(g, (TL_SIZE.y + 24.0) * k + g)
	_layout_market()
	_layout_overlays(view)


func _layout_overlays(view: Vector2) -> void:
	if _handover_card != null:
		_handover_card.scale = Vector2(k, k)
		_handover_card.position = ((view - _handover_card.size * k) * 0.5).round()
	if _result_card != null:
		var rk := minf(k, view.y * 0.96 / _result_card.size.y)
		_result_card.scale = Vector2(rk, rk)
		_result_card.position = Vector2(roundf((view.x - _result_card.size.x * rk) * 0.5 + 120 * k), roundf((view.y - _result_card.size.y * rk) * 0.5))
		_result_guide.scale = Vector2(k, k)
		_result_guide.position = Vector2(GUTTER * k * 2, GUTTER * k * 2)


## 地图右侧被面板遮住的宽度（逻辑像素），给 BoardView.set_map_safe_right_inset
func market_inset() -> float:
	return (MARKET_W * market.scale.x + GUTTER * k * 2.0) if market.visible and not market_collapsed else 0.0


## 地图上没被上下两排界面盖住的那一条（逻辑像素，和 r 同一坐标系）：上沿 = 上中回合牌 + 步骤条的底，
## 下沿 = 左下挎包 / 下中骰子 / 右下按钮三组里最高的顶。事件抽卡的卡、标题牌、「继续」都排在这条里（复检 UIRES-3）
func free_band(r: Rect2) -> Rect2:
	var top := group_tc.get_global_rect().end.y
	var bottom := minf(group_bl.get_global_rect().position.y, minf(group_bc.get_global_rect().position.y, group_br.get_global_rect().position.y))
	var y0 := maxf(r.position.y, top)
	var y1 := minf(r.end.y, bottom)
	if y1 - y0 < 200.0:
		return r
	return Rect2(r.position.x, y0, r.size.x, y1 - y0)


## 面板在屏幕上的矩形（逻辑像素）；关闭时为空
func market_rect() -> Rect2:
	return Rect2(market.position, Vector2(MARKET_W, _market_h) * market.scale.x) if market.visible and not market_collapsed else Rect2()


func _build_market_tab() -> void:
	market_tab = Button.new()
	market_tab.name = "MarketCollapseTab"
	market_tab.focus_mode = Control.FOCUS_NONE
	market_tab.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	market_tab.tooltip_text = "收起 / 展开市集面板"
	# 贴在面板左边、往外探出一截；右边压进面板 10 像素，和面板皮连在一起
	place(market_tab, Rect2(-64, 168, 74, 200))
	var t := label("", 26, Kit.CREAM, "title", 800)
	t.name = "TabText"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	t.add_theme_constant_override("line_spacing", -2)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(t, Rect2(0, 0, 64, 200))
	market_tab.add_child(t)
	market_tab.pressed.connect(func() -> void: set_market_collapsed(not market_collapsed))
	market.add_child(market_tab)
	_paint_market_tab()


func _paint_market_tab() -> void:
	if market_tab == null:
		return
	(market_tab.get_node("TabText") as Label).text = "◂\n市\n集" if market_collapsed else "收\n起\n▸"
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		var base: Color = Kit.OCHRE_DEEP if market_collapsed else Kit.SATCHEL
		sb.bg_color = base.lightened(0.12) if state == "hover" else (base.darkened(0.1) if state.begins_with("pressed") else base)
		sb.border_color = Kit.OCHRE if market_collapsed else Color("#E8C9A0")
		sb.set_border_width_all(3)
		sb.border_width_right = 0
		sb.corner_radius_top_left = 26
		sb.corner_radius_bottom_left = 26
		sb.shadow_color = Color(0.2, 0.1, 0.04, 0.35)
		sb.shadow_size = 6
		sb.shadow_offset = Vector2(-2, 3)
		market_tab.add_theme_stylebox_override(state, sb)


func set_market_collapsed(c: bool, animate := true) -> void:
	var changed := c != market_collapsed
	market_collapsed = c
	_paint_market_tab()
	# 收起时「下一步」提示回到右下按钮上方，不跟着面板滑出屏幕（复检 NOV-4：以前收起后什么提示都没有）
	if market_mode != "":
		var want_parent: Control = group_br if c else market
		if slot_prompt.get_parent() != want_parent:
			slot_prompt.reparent(want_parent, false)
		if c:
			place(slot_prompt, PROMPT_RECT)
		else:
			_layout_market()
		guide_bubble.visible = c
	# 收起时拉手整块露在屏幕里（右边不再被屏幕边切掉一截）
	place(market_tab, Rect2(-74 if c else -64, 168, 74, 200))
	if _market_slide_tween != null and _market_slide_tween.is_valid():
		_market_slide_tween.kill()
	var goal := 1.0 if c else 0.0
	if animate and is_inside_tree() and not is_equal_approx(goal, _market_slide):
		_market_slide_tween = create_tween()
		_market_slide_tween.tween_method(_set_market_slide, _market_slide, goal, 0.22) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	else:
		_set_market_slide(goal)
	if changed:
		market_collapse_changed.emit(c)


func _set_market_slide(v: float) -> void:
	_market_slide = v
	_place_market()


## 收起时面板整块移到屏幕右边外面，只剩拉手露在边上
func _place_market() -> void:
	market.position.x = lerpf(_market_open_x, _view_w, _market_slide)
