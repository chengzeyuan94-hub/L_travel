extends Control
## 开局加载页「商队整装中…」（概念图 docs/design/shanhe-luren/loading-lshu-20260926/01_concept.jpg）。
## 设置页点「出发！」之后、对局出现之前盖在最上面：一条丝路做进度条，骆驼从起始城市的邮戳走向「开局」小旗，
## 路边的土豆花走过一朵开一朵；上面写着现在在做哪一步和百分比，左上是这一局的 2–4 位旅伴（按行动顺序），左下 L叔 边走边讲小贴士。
## 进度由外面按真实步骤推（set_stage），这里只负责平滑地走过去；finish() 走满、开旗、淡出。
## 设计分辨率 1920×1080，整页放在按 k = min(宽/1920, 高/1080) 缩放的 Stage 里。

signal finished

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const LSkin := preload("res://scripts/lshu_ui/lshu_skin.gd")
const W := preload("res://scripts/lshu_ui/lshu_widgets.gd")
const Seats := preload("res://scripts/lshu_ui/lshu_seats.gd")
const DIRS: Array[String] = ["res://assets/game/ui/lshu_loading/", "res://assets/game/ui/lshu_setup/", "res://assets/game/ui/lshu_home/"]
const STAGE := Vector2(1920, 1080)
const INK_BROWN := Color("#4A2C1A")

## 进度条上的路：从邮戳右边到小旗脚下，一条缓缓起伏的沙路（Stage 坐标）
const ROAD_X := Vector2(470, 1700)
const ROAD_Y := 566.0
const ROAD_AMP := 16.0
const MILESTONES: Array[float] = [0.1, 0.28, 0.46, 0.64, 0.82]

## 小贴士（每条都能在规则代码里找到出处，见 docs/design/shanhe-luren/loading-lshu-20260926/README.md）
var tips: Array[String] = [
	"骆驼走陆路，\n商船走海路哦～",
	"只有 5 个海陆交叉点，\n才能换乘哦！",
	"掷到几就能走 0 到几步，\n停在哪你来定！",
	"掷到事件面：\n骆驼抽陆地事件，\n商船抽海洋事件～",
	"货仓只能装 4 件货，\n同种货也按件数算！",
	"每回合只能做一笔买卖，\n想好再换哦～",
	"停在没开商道的城里，\n送你 2 白银！",
	"停在半路的停靠点，\n不能做买卖哦～",
	"公共银两拿空或到了对局时长，\n补完这一轮就结算！",
	"谁的白银最多谁赢，\n一样多就比货物！",
	"相邻两座城之间，\n都正好 3 步路～",
	"急用钱？在城里\n1 件货能卖 1 白银！",
	"有的事件卡\n能让你走 6 步呢！",
]

var _stage: Control
var _road: _Road
var _camel: TextureRect
var _flowers: Array[TextureRect] = []
var _bloomed: Array[bool] = []
var _lshu: TextureRect
var _tip: Label
var _status: Label
var _percent: Label
var _flag: TextureRect
var _roster: Control
var _stamp_city: Label
var _display: float = 0.0
var _target: float = 0.0
var _creep_to: float = 0.0
var _t: float = 0.0
var _tip_i: int = 0
var _tip_timer: float = 0.0
var _finishing := false
var _done := false
var _saying := false
var _curtain: ColorRect
var _tip_wrap: Control


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  # 加载时挡住下面对局界面的点击
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_build()
	resized.connect(_layout)
	visibility_changed.connect(_on_visibility_changed)
	_layout()


## 一出现：页面本身不透明，上面盖一块和转场一样的暗幕再淡掉
## （转场暗幕在下面的图层里被这一页挡住；整页淡入会透出引擎的灰底）
func _on_visibility_changed() -> void:
	if visible and not _finishing and _curtain != null:
		modulate.a = 1.0
		_curtain.color.a = 0.72
		_curtain.visible = true
		var tw := create_tween()
		tw.tween_property(_curtain, "color:a", 0.0, 0.18).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_callback(func() -> void: _curtain.visible = false)


func _tex(name: String) -> Texture2D:
	for dir: String in DIRS:
		for ext: String in [".png", ".jpg"]:
			var p: String = dir + name + ext
			if ResourceLoader.exists(p):
				return load(p) as Texture2D
	var t: Texture2D = LSkin.tex(name)
	if t == null:
		t = Kit.icon(name)
	return t


func _image(name: String, pos: Vector2, sz: Vector2, parent: Control = null) -> TextureRect:
	var t := TextureRect.new()
	t.name = name.to_pascal_case()
	t.texture = _tex(name)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.position = pos
	t.size = sz
	(parent if parent != null else _stage).add_child(t)
	return t


func _leather_pill(pos: Vector2, sz: Vector2) -> Panel:
	var p := Panel.new()
	p.position = pos
	p.size = sz
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	st.bg_color = Color("#7A4A2A")
	st.set_corner_radius_all(int(sz.y * 0.5))
	st.corner_detail = 12
	st.border_color = Color("#5A3219")
	st.border_width_bottom = 5
	st.anti_aliasing = true
	st.shadow_color = Color(0.25, 0.12, 0.05, 0.35)
	st.shadow_size = 6
	st.shadow_offset = Vector2(0, 3)
	p.add_theme_stylebox_override("panel", st)
	var stitch := W.StitchLayer.new()
	stitch.inset = 7.0
	stitch.radius = sz.y * 0.5 - 7.0
	stitch.dash = 9.0
	stitch.gap = 7.0
	stitch.width = 2.2
	stitch.color = Color("#E9C99C", 0.85)
	p.add_child(stitch)
	_stage.add_child(p)
	return p


# ------------------------------------------------------------------ 搭界面
func _build() -> void:
	var bg := TextureRect.new()
	bg.name = "MapBackground"
	bg.texture = _tex("bg_map")
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var wash := ColorRect.new()
	wash.color = Color(1.0, 0.93, 0.8, 0.12)
	wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(wash)
	_stage = Control.new()
	_stage.name = "Stage"
	_stage.size = STAGE
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stage)

	_build_petals()
	_build_vs_card()
	# 标题 + 状态条
	var title := _image("txt_loading_title", Vector2(640, 96), Vector2(800, 191))
	title.name = "Title"
	title.pivot_offset = title.size * 0.5
	var sprig := _image("flower_bloom", Vector2(1418, 150), Vector2(64, 82))
	sprig.name = "TitleFlower"
	sprig.rotation = deg_to_rad(18)
	var status_pill := _leather_pill(Vector2(760, 314), Vector2(420, 78))
	status_pill.name = "StatusPill"
	_image("flower_bloom", Vector2(22, 10), Vector2(46, 58), status_pill).name = "Flower"
	_status = Kit.label("清点货物银两…", 34, Color("#FFF1DC"), "body", 800)
	_status.name = "Status"
	_status.position = Vector2(78, 6)
	_status.size = Vector2(330, 66)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_pill.add_child(_status)
	var pct_pill := _leather_pill(Vector2(1196, 314), Vector2(170, 78))
	pct_pill.name = "PercentPill"
	_percent = Kit.label("0%", 42, Color("#FFF1DC"), "body", 900)
	_percent.name = "Percent"
	_percent.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_percent.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_percent.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_percent.add_theme_color_override("font_outline_color", Color("#3B2215"))
	_percent.add_theme_constant_override("outline_size", 6)
	pct_pill.add_child(_percent)

	# 进度条：长条 + 路 + 邮戳 + 小花 + 骆驼 + 小旗
	var strip := LSkin.NinePanel.new()
	strip.name = "Strip"
	strip.skin = _tex("strip_blank")
	strip.nine = [151, 151, 151, 151]
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.position = Vector2(250, 450)
	strip.size = Vector2(1590, 236)
	_stage.add_child(strip)
	_road = _Road.new()
	_road.name = "Road"
	_road.size = STAGE
	_road.screen = self
	_stage.add_child(_road)
	var stamp := W.Postmark.new()
	stamp.name = "Stamp"
	stamp.position = Vector2(300, 500)
	stamp.size = Vector2(170, 110)
	stamp.pivot_offset = Vector2(60, 55)
	stamp.rotation = deg_to_rad(-8)
	_stage.add_child(stamp)
	_stamp_city = Kit.label("", 30, Color("#B5473A"), "body", 900)
	_stamp_city.name = "StampCity"
	_stamp_city.position = Vector2(14, 33)
	_stamp_city.size = Vector2(92, 44)
	_stamp_city.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stamp_city.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_stamp_city.grow_horizontal = Control.GROW_DIRECTION_BOTH
	stamp.add_child(_stamp_city)
	for t: float in MILESTONES:
		var f := _image("flower_bud", Vector2.ZERO, Vector2(56, 72))
		f.name = "Milestone%d" % _flowers.size()
		var p: Vector2 = road_point(t)
		f.position = p - Vector2(28, 66)
		f.pivot_offset = Vector2(28, 70)
		_flowers.append(f)
		_bloomed.append(false)
	_flag = _image("flag_start", Vector2(1664, 360), Vector2(168, 200))
	_flag.name = "Flag"
	_flag.pivot_offset = Vector2(40, 196)
	_camel = _image("icon_camel", Vector2.ZERO, Vector2(150, 137))
	_camel.name = "Camel"
	_camel.pivot_offset = Vector2(75, 132)

	_build_guide()
	_curtain = ColorRect.new()
	_curtain.name = "Curtain"
	_curtain.color = Color(0.10, 0.075, 0.045, 0.0)
	_curtain.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_curtain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curtain.visible = false
	add_child(_curtain)


func _build_petals() -> void:
	var petals := CPUParticles2D.new()
	petals.name = "Petals"
	petals.texture = _tex("petal_1")
	petals.amount = 7
	petals.lifetime = 18.0
	petals.preprocess = 18.0
	petals.position = Vector2(-60, 520)
	petals.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	petals.emission_rect_extents = Vector2(40, 480)
	petals.direction = Vector2(1, 0.08)
	petals.spread = 12.0
	petals.gravity = Vector2(0, 6)
	petals.initial_velocity_min = 80.0
	petals.initial_velocity_max = 130.0
	petals.angle_max = 360.0
	petals.angular_velocity_min = -70.0
	petals.angular_velocity_max = 70.0
	petals.scale_amount_min = 0.2
	petals.scale_amount_max = 0.32
	_stage.add_child(petals)


func _build_vs_card() -> void:
	# 左上：这一局的旅伴（2–4 位，座位号 = 行动顺序）：圆头像 + 座位颜色圈 + 名字 + 真人 / 电脑几岁
	# 外层是普通 Control（纸张是容器，放进去的东西会被撑满整张卡，所以纸单独放一层）；两位时中间放「VS」
	var card := Control.new()
	card.name = "VsCard"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.position = Vector2(56, 52)
	# 名字下面多了一行「真人 / 电脑 · 几岁」：卡片比原来 1 对 1 的 244 高 22，底边缝线才不压在这行字上
	card.size = Vector2(580, 266)
	card.rotation = deg_to_rad(-2)
	_stage.add_child(card)
	var paper := LSkin.NinePanel.new()
	paper.name = "Paper"
	paper.skin = _tex("card_blank")
	paper.nine = LSkin.margins("card_blank")
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	paper.size = card.size
	card.add_child(paper)
	_image("flower_bloom", Vector2(-14, -26), Vector2(60, 78), card).name = "CornerFlower"
	_roster = Control.new()
	_roster.name = "Roster"
	_roster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_roster.position = Vector2(20, 14)
	_roster.size = Vector2(540, 216)
	card.add_child(_roster)
	_fill_roster([{"display_name": "玩家", "color_id": "red", "controller_type": "LOCAL_HUMAN"},
		{"display_name": Seats.default_ai_name(0), "color_id": "blue", "controller_type": "AI", "ai_difficulty": AIDifficulty.DEFAULT}])


## 按座位顺序排开：头像大小随人数变（2 位 132 / 3 位 116 / 4 位 104），名字过长时缩小
func _fill_roster(configs: Array) -> void:
	for c in _roster.get_children():
		c.free()
	var n: int = mini(configs.size(), Seats.MAX_SEATS)
	if n <= 0:
		return
	var d: float = {1: 132.0, 2: 132.0, 3: 116.0, 4: 104.0}[n]
	var col_w: float = 540.0 / float(n) if n > 2 else 200.0
	var vs_w: float = 540.0 - col_w * 2.0 if n == 2 else 0.0
	var x := 0.0
	for i in n:
		var cfg: Dictionary = configs[i]
		var col := Control.new()
		col.name = "Seat%d" % (i + 1)
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.clip_contents = true          # 名字、身份再长也不压到隔壁一列（复检 UIRES-2）
		col.position = Vector2(x, 0)
		col.size = Vector2(col_w, 216)
		_roster.add_child(col)
		var badge := Seats.Badge.new(d)
		badge.name = "Avatar"
		badge.show_number = n > 2
		badge.ring_px = 7.0 if d > 110.0 else 6.0
		badge.position = Vector2((col_w - d) * 0.5, 4 + (132.0 - d) * 0.5)
		col.add_child(badge)
		badge.set_seat(cfg, configs)
		var name := Kit.label(String(cfg.get("display_name", "")), 28 if n <= 3 else 26, INK_BROWN, "body", 900)
		name.name = "Name"
		name.tooltip_text = name.text
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# 先缩字号、到下限还放不下再加省略号（和对局左上小卡一样）；裁切要在定尺寸之前设好，
		# 否则 Label 按整串字的宽度撑开，四位时每个名字都伸进隔壁一列（复检 UIRES-2）
		LshuMatchHud.fit_label(name, col_w - 10.0, 28 if n <= 3 else 26, 20)
		name.custom_minimum_size = Vector2.ZERO
		name.position = Vector2(5, 144)
		name.size = Vector2(col_w - 10.0, 38)
		col.add_child(name)
		var role := Kit.label(_role_text(cfg, n > 2), 21, Color("#8A5A3B"), "body", 800)
		role.name = "Role"
		role.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		role.clip_text = true
		role.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		role.position = Vector2(0, 180)
		role.size = Vector2(col_w, 30)
		col.add_child(role)
		x += col_w
		if n == 2 and i == 0:
			var vs := Kit.label("VS", 50, INK_BROWN, "body", 900)
			vs.name = "Vs"
			vs.position = Vector2(x, 40)
			vs.size = Vector2(vs_w, 64)
			vs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_roster.add_child(vs)
			x += vs_w


## 三四位时每列只有 135 宽，用短说法
func _role_text(cfg: Dictionary, short: bool) -> String:
	if Seats.is_ai(cfg):
		return "%s · %s" % ["电脑" if short else "电脑小伙伴", AIDifficulty.age_text(Seats.difficulty_of(cfg))]
	return "真人" if short else "真人玩家"


## 选中颜色外面的眼镜框（和设置页一样）
class _Ring extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2(8, 8), size - Vector2(16, 16))
		var s := StyleBoxFlat.new()
		s.draw_center = false
		s.border_color = Color("#2E2019")
		s.set_border_width_all(11)
		s.set_corner_radius_all(38)
		s.corner_detail = 10
		s.anti_aliasing = true
		draw_style_box(s, r)
		draw_rect(Rect2(Vector2(-4, size.y * 0.3), Vector2(14, 14)), Color("#2E2019"))
		draw_rect(Rect2(Vector2(size.x - 10, size.y * 0.3), Vector2(14, 14)), Color("#2E2019"))


func _build_guide() -> void:
	var lm: Dictionary = {}
	var p: String = "res://assets/game/ui/lshu_setup/setup.json"
	if FileAccess.file_exists(p):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
		if d is Dictionary:
			lm = (d as Dictionary).get("ledge", {})
	var src: Array = lm.get("src_box", [0, 860, 720, 1152])
	var s: float = STAGE.x / 2048.0
	var ledge := _image("ledge", Vector2(float(src[0]), float(src[1])) * s, Vector2(float(src[2]) - float(src[0]), float(src[3]) - float(src[1])) * s)
	ledge.name = "Ledge"
	ledge.stretch_mode = TextureRect.STRETCH_SCALE
	_lshu = _image("lshu_walk", Vector2(64, 640), Vector2(222, 436))
	_lshu.name = "LshuWalk"
	_lshu.pivot_offset = Vector2(111, 436)
	# 旋转放在外面一层，泡泡本身不转：弹一下时改锚点不会让它跳位
	_tip_wrap = Control.new()
	_tip_wrap.name = "TipWrap"
	_tip_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip_wrap.position = Vector2(300, 736)
	_tip_wrap.rotation = deg_to_rad(-2)
	_stage.add_child(_tip_wrap)
	var bubble := LSkin.nine_panel("bubble", Vector4(34, 24, 36, 54))
	bubble.name = "TipBubble"
	bubble.custom_minimum_size = Vector2(380, 0)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var head := Kit.label("小贴士：", 28, Color("#8A5A3B"), "body", 900)
	head.name = "TipHead"
	col.add_child(head)
	_tip = Kit.label(tips[0], 30, INK_BROWN, "body", 800)
	_tip.name = "Tip"
	_tip.add_theme_constant_override("line_spacing", 4)
	col.add_child(_tip)
	bubble.add_child(col)
	_tip_wrap.add_child(bubble)


# ------------------------------------------------------------------ 路
func road_point(t: float) -> Vector2:
	var x: float = lerpf(ROAD_X.x, ROAD_X.y, t)
	return Vector2(x, ROAD_Y + sin(t * TAU * 1.35 + 0.4) * ROAD_AMP)


class _Road extends Control:
	var screen: Object

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if screen == null:
			return
		var prog: float = float(screen.get("_display"))
		var n := 90
		var done := PackedVector2Array()
		var rest: Array[Vector2] = []
		for i in n + 1:
			var t: float = float(i) / float(n)
			var p: Vector2 = screen.call("road_point", t)
			if t <= prog:
				done.append(p)
			else:
				if rest.is_empty() and done.size() > 0:
					rest.append(done[done.size() - 1])
				rest.append(p)
		# 没走过的路：浅棕虚线
		var dash := 22.0
		var gap := 15.0
		var on := true
		var left := dash
		for i in range(rest.size() - 1):
			var a: Vector2 = rest[i]
			var b: Vector2 = rest[i + 1]
			var seg: float = a.distance_to(b)
			var d := 0.0
			while d < seg:
				var step: float = minf(left, seg - d)
				if on:
					draw_line(a.lerp(b, d / seg), a.lerp(b, (d + step) / seg), Color("#BFA886"), 9.0, true)
				d += step
				left -= step
				if left <= 0.001:
					on = not on
					left = dash if on else gap
		# 走过的路：金色发光
		if done.size() >= 2:
			draw_polyline(done, Color(1.0, 0.82, 0.35, 0.28), 34.0, true)
			draw_polyline(done, Color("#E9A93A"), 16.0, true)
			draw_polyline(done, Color("#FFD978"), 9.0, true)
			var hi := PackedVector2Array()
			for p in done:
				hi.append(p + Vector2(0, -2.5))
			draw_polyline(hi, Color(1.0, 0.97, 0.82, 0.8), 3.0, true)


# ------------------------------------------------------------------ 对外接口
## 进页面前调用：填这一局的旅伴（2–4 位，按座位顺序）和起始城市，进度归零
func begin(configs: Array, prepare: Dictionary) -> void:
	_display = 0.0
	_target = 0.0
	_creep_to = 0.0
	_finishing = false
	_done = false
	_saying = false
	_t = 0.0
	_tip_timer = 0.0
	for i in _flowers.size():
		_bloomed[i] = false
		_flowers[i].texture = _tex("flower_bud")
		_flowers[i].scale = Vector2.ONE
	_flag.rotation = 0.0
	_flag.scale = Vector2.ONE
	_fill_roster(configs)
	var city: String = String(prepare.get("home_city_name", ""))
	W.Postmark.fit_label(_stamp_city, city)
	if not tips.is_empty():
		_tip_i = randi() % tips.size()
		_tip.text = tips[_tip_i]
	set_stage("清点货物银两…", 0.08)
	_update_positions()
	_road.queue_redraw()


## 外面每做完一步调一次：显示这一步的名字，进度往 target 走；卡住时也会缓慢往前挪一点
func set_stage(text: String, target: float) -> void:
	if _status != null and _status.text != text:
		_status.text = text
		var pill := _status.get_parent() as Control
		pill.pivot_offset = pill.size * 0.5
		var tw := pill.create_tween()
		tw.tween_property(pill, "scale", Vector2(1.06, 1.06), 0.08).set_trans(Tween.TRANS_SINE)
		tw.tween_property(pill, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_target = maxf(_target, clampf(target, 0.0, 1.0))
	_creep_to = minf(_target + 0.12, 0.96)


## L叔 临时说一句（比如卡住之前先打招呼）；传空字符串就回到轮换小贴士
func say(text: String) -> void:
	var head := _tip.get_parent().get_node("TipHead") as CanvasItem
	if text == "":
		_saying = false
		head.visible = true
		_tip.text = tips[_tip_i] if not tips.is_empty() else ""
		_tip_timer = 0.0
		return
	_saying = true
	head.visible = false
	_tip.text = text
	_tip.visible_ratio = 1.0
	var bubble := _tip.get_parent().get_parent() as Control
	bubble.pivot_offset = Vector2(40, bubble.size.y)
	var tw := bubble.create_tween()
	tw.tween_property(bubble, "scale", Vector2(1.08, 1.08), 0.08).set_trans(Tween.TRANS_SINE)
	tw.tween_property(bubble, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


## 等骆驼追上当前目标（最多等 max_sec 秒）：外面要卡住主线程之前先调，冻住的那一帧骆驼正好在位
func wait_caught_up(max_sec: float) -> void:
	var t0 := Time.get_ticks_msec()
	while _display < _target - 0.015 and Time.get_ticks_msec() - t0 < int(max_sec * 1000.0):
		await get_tree().process_frame
	# 再多画一帧，让冻住前的画面就是这一刻
	await get_tree().process_frame


## 盖住时吞掉键盘：下面的对局界面会把空格 / 回车当成掷骰
func _input(event: InputEvent) -> void:
	if is_visible_in_tree() and event is InputEventKey:
		get_viewport().set_input_as_handled()


## 走满、开旗、淡出；淡出结束发 finished
func finish() -> void:
	if _finishing:
		return
	_finishing = true
	set_stage("出发！", 1.0)


func is_done() -> bool:
	return _done


# ------------------------------------------------------------------ 每帧
func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_t += delta
	# 进度：先快后慢地追 target；追上以后在「下一步」来之前慢慢往前挪，不让骆驼停住
	var goal: float = _target
	if not _finishing and _display >= _target - 0.005:
		goal = _creep_to
	var speed: float = 6.0 if _finishing else 1.6
	if not _finishing and _display < _target - 0.05:
		speed = 3.2  # 落后太多时追快一点
	var step: float = (goal - _display) * minf(1.0, delta * speed)
	if goal == _creep_to and not _finishing:
		step = minf(step, delta * 0.03)
	step = maxf(step, 0.0)
	if _finishing:
		step = maxf(step, delta * 0.8)
	_display = minf(_display + step, 1.0 if _finishing else _creep_to)
	_percent.text = "%d%%" % int(round(_display * 100.0))
	_update_positions()
	_road.queue_redraw()
	# 小花：走过一朵开一朵
	for i in MILESTONES.size():
		if not _bloomed[i] and _display >= MILESTONES[i]:
			_bloom(i)
	# L叔 走路：上下颠、左右晃
	var step_phase: float = _t * TAU * 1.9
	_lshu.position.y = 640.0 - absf(sin(step_phase)) * 10.0
	_lshu.rotation = sin(step_phase) * 0.035
	# 标题轻轻浮动
	var title := _stage.get_node("Title") as Control
	title.position.y = 96.0 + sin(_t * 2.0) * 5.0
	# 小旗飘
	if not _done:
		_flag.rotation = sin(_t * 3.1) * 0.03
	# 小贴士每 3.2 秒换一条
	_tip_timer += delta
	if _tip_timer > 3.2 and tips.size() > 1 and not _saying:
		_tip_timer = 0.0
		_tip_i = (_tip_i + 1) % tips.size()
		_tip.text = tips[_tip_i]
		_tip.visible_ratio = 0.0
		_tip.create_tween().tween_property(_tip, "visible_ratio", 1.0, 0.45)
	if _finishing and not _done and _display >= 0.999:
		_done = true
		_celebrate()


func _update_positions() -> void:
	var p: Vector2 = road_point(_display)
	var ahead: Vector2 = road_point(minf(1.0, _display + 0.01))
	var bob: float = absf(sin(_t * TAU * 2.2)) * 6.0
	_camel.position = p - Vector2(75, 124 + bob)
	_camel.rotation = clampf((ahead - p).angle(), -0.25, 0.25) + sin(_t * TAU * 2.2) * 0.03


func _bloom(i: int) -> void:
	_bloomed[i] = true
	var f := _flowers[i]
	f.texture = _tex("flower_bloom")
	f.scale = Vector2(0.4, 0.4)
	var tw := f.create_tween()
	tw.tween_property(f, "scale", Vector2(1.18, 1.18), 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(f, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_SINE)
	var sp := CPUParticles2D.new()
	sp.texture = _soft_dot()
	sp.one_shot = true
	sp.explosiveness = 1.0
	sp.amount = 10
	sp.lifetime = 0.7
	sp.position = f.position + Vector2(28, 20)
	sp.direction = Vector2(0, -1)
	sp.spread = 180.0
	sp.gravity = Vector2(0, 60)
	sp.initial_velocity_min = 60.0
	sp.initial_velocity_max = 140.0
	sp.scale_amount_min = 0.15
	sp.scale_amount_max = 0.3
	sp.color = Color(1.0, 0.9, 0.55)
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	sp.material = m
	_stage.add_child(sp)
	sp.emitting = true
	sp.finished.connect(sp.queue_free)


var _dot: GradientTexture2D


func _soft_dot() -> GradientTexture2D:
	if _dot == null:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.5), Color(1, 1, 1, 0)])
		_dot = GradientTexture2D.new()
		_dot.gradient = g
		_dot.fill = GradientTexture2D.FILL_RADIAL
		_dot.fill_from = Vector2(0.5, 0.5)
		_dot.fill_to = Vector2(1.0, 0.5)
		_dot.width = 32
		_dot.height = 32
	return _dot


func _celebrate() -> void:
	# 到站：小旗弹一下，L叔 说「出发！」，然后整页淡出
	_tip.get_parent().get_node("TipHead").visible = false
	_tip.text = "到啦，\n出发！"
	_tip.visible_ratio = 1.0
	var tw := _flag.create_tween()
	tw.tween_property(_flag, "scale", Vector2(1.15, 1.15), 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_flag, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	var out := create_tween()
	out.tween_interval(0.25)
	out.tween_property(self, "modulate:a", 0.0, 0.3).set_trans(Tween.TRANS_SINE)
	out.tween_callback(func() -> void:
		(_tip.get_parent().get_node("TipHead") as CanvasItem).visible = true
		finished.emit())


# ------------------------------------------------------------------ 布局
func _layout() -> void:
	if _stage == null or size.x <= 0.0 or size.y <= 0.0:
		return
	var k: float = minf(size.x / STAGE.x, size.y / STAGE.y)
	_stage.scale = Vector2(k, k)
	_stage.position = (size - STAGE * k) * 0.5
	var petals := _stage.get_node_or_null("Petals") as Node2D
	if petals != null:
		petals.position.x = -_stage.position.x / k - 60.0
