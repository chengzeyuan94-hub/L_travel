class_name LshuSeats
extends RefCounted
## 「旅行L叔」商旅模式的座位形象：一局 2–4 个座位（真人 / 电脑任意组合，一台电脑轮流玩），
## 每个座位用什么头像、什么颜色、叫什么。设置页、加载页、对局界面都从这里取，同一个座位在各页长得一样。
##
##   头像 avatar_texture：
##     · 第一位真人（座位顺序最靠前的真人）是 L叔（lshu_title/lshu_avatar2.png 的头部，正方形）；
##     · 第 2 / 3 / 4 位真人用 lshu_setup/seat_2.png / seat_3.png / seat_4.png（旅行小朋友，不戴眼镜——眼镜只属于 L叔）；
##       这几张还没画出来时先用 L叔 顶上，同一张图的第二个座位左右镜像（avatar_flip_h）；
##     · 电脑小伙伴按难度用 lshu_setup/kid_7 / kid_12 / kid_16.png；同一难度的第二个电脑也镜像。
##     返回的都是正方形贴图，放进圆框（Badge）或方格都行。
##   颜色 seat_color：规则里的红 / 蓝 / 绿 / 黄四色，调亮成和 Kit 调色板同一套糖果色（取自四色圆章 token_*.png）；
##     seat_color_deep 做描边 / 底唇，seat_color_soft 做浅底。
##   名字：真人默认「玩家一…四」（按座位号），电脑默认「小驼铃 / 小沙枣 / 小月牙」。
##
## who 可以是 PlayerState，也可以是开局配置字典 {"display_name","color_id","controller_type","ai_difficulty"}；
## roster 是同一局按座位顺序的全部座位（PlayerState 或配置字典的数组），省略时用 GameState.players。
## 所有函数对缺字段、找不到座位、空 roster 都有兜底，不会报错。

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const SETUP_DIR := "res://assets/game/ui/lshu_setup/"
const LSHU_PORTRAIT := "res://assets/game/ui/lshu_title/lshu_avatar2.png"

const KID_ART: Dictionary = {"qingzhuang": "kid_7", "shanhai": "kid_12", "wanli": "kid_16"}
const HUMAN_NUMBERS: Array[String] = ["一", "二", "三", "四"]
const AI_NAMES: Array[String] = ["小驼铃", "小沙枣", "小月牙"]
const MAX_SEATS := 4

## 规则四色 → 糖果色（和 lshu_setup/token_*.png 圆章同色相，略提亮，配 Kit 的驼黄 / 牛仔蓝 / 嫩芽绿）
const SEAT_COLORS: Dictionary = {
	"red": Color("#C8604F"),
	"blue": Color("#4F7FAE"),
	"green": Color("#4A8C6A"),
	"yellow": Color("#DA9A36"),
}
const COLOR_NAMES: Dictionary = {"red": "红", "blue": "蓝", "green": "绿", "yellow": "黄"}

static var _lshu_head: Texture2D
static var _cache: Dictionary = {}


# ------------------------------------------------------------------ 读座位字段（PlayerState / 配置字典都行）
static func is_ai(who: Variant) -> bool:
	if who is PlayerState:
		return (who as PlayerState).is_ai()
	if who is Dictionary:
		return String((who as Dictionary).get("controller_type", "LOCAL_HUMAN")) == "AI"
	return false


static func is_human(who: Variant) -> bool:
	return (who is PlayerState or who is Dictionary) and not is_ai(who)


static func color_id_of(who: Variant) -> String:
	if who is PlayerState:
		return (who as PlayerState).color_id
	if who is Dictionary:
		return String((who as Dictionary).get("color_id", ""))
	return ""


static func name_of(who: Variant) -> String:
	if who is PlayerState:
		return (who as PlayerState).display_name
	if who is Dictionary:
		return String((who as Dictionary).get("display_name", ""))
	return ""


## 电脑的难度（AIDifficulty id）；真人返回 ""
static func difficulty_of(who: Variant) -> String:
	if not is_ai(who):
		return ""
	if who is PlayerState:
		return AIDifficulty.of(who as PlayerState)
	return AIDifficulty.normalize(String((who as Dictionary).get("ai_difficulty", "")))


static func _roster(roster: Array) -> Array:
	if not roster.is_empty():
		return roster
	var gs := _game_state()
	return gs.get("players") as Array if gs != null else []


## 自动加载的 GameState：运行时从场景树取（不在编译期引用它，这样 -s 模式的截图 / 工具脚本也能用本类）
static func _game_state() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("GameState") if tree != null and tree.root != null else null


## 座位下标（0 起）：在 roster 里找；找不到时 PlayerState 用 seat_index，配置字典用 "seat_index" 字段；都没有返回 -1
static func seat_index_of(who: Variant, roster: Array = []) -> int:
	var r := _roster(roster)
	for i in r.size():
		if is_same(r[i], who):
			return i
	if who is Dictionary:
		var i := r.find(who)
		if i >= 0:
			return i
		return int((who as Dictionary).get("seat_index", -1))
	if who is PlayerState:
		var p := who as PlayerState
		for i in r.size():
			if r[i] is PlayerState and (r[i] as PlayerState).player_id == p.player_id and p.player_id != "":
				return i
		return p.seat_index
	return -1


static func first_human_index(roster: Array = []) -> int:
	var r := _roster(roster)
	for i in r.size():
		if is_human(r[i]):
			return i
	return -1


# ------------------------------------------------------------------ 头像
## 头像 id："lshu"（L叔）/ "seat_2..4"（第 2..4 位真人）/ "kid_7|kid_12|kid_16"（电脑，按难度）
## 真人按「这一局第几位真人」分：第 1 位真人是 L叔，第 k 位用 seat_k（不看坐在第几个座位，两人局的第二位真人总是同一个小朋友）
static func avatar_id(who: Variant, roster: Array = []) -> String:
	if is_ai(who):
		return String(KID_ART.get(difficulty_of(who), "kid_12"))
	var k := human_ordinal(who, roster)
	if k <= 0:
		return "lshu"
	var id := "seat_%d" % mini(k + 1, MAX_SEATS)
	return id if has_art(id) else "lshu"


## 这位真人是这一局的第几位真人（0 起）；电脑或找不到座位时返回 0
static func human_ordinal(who: Variant, roster: Array = []) -> int:
	if is_ai(who):
		return 0
	var r := _roster(roster)
	var i := seat_index_of(who, roster)
	if i < 0:
		return 0
	var k := 0
	for j in mini(i, r.size()):
		if is_human(r[j]):
			k += 1
	return k


## 头像贴图（正方形）。who 为空或什么都找不到时退回座位颜色的圆章
static func avatar_texture(who: Variant, roster: Array = []) -> Texture2D:
	if not (who is PlayerState or who is Dictionary):
		return null
	var t := texture_for_id(avatar_id(who, roster))
	if t == null:
		t = token_texture(color_id_of(who))
	return t


static func texture_for_id(id: String) -> Texture2D:
	if id == "lshu":
		return lshu_head()
	if _cache.has(id):
		return _cache[id]
	var p := SETUP_DIR + id + ".png"
	var t: Texture2D = load(p) as Texture2D if ResourceLoader.exists(p) else null
	_cache[id] = t
	return t


static func has_art(id: String) -> bool:
	return ResourceLoader.exists(SETUP_DIR + id + ".png")


## L叔 头像：半身像只取头部一个正方形（和开场的圆头像同一种取法）
static func lshu_head() -> Texture2D:
	if _lshu_head != null:
		return _lshu_head
	if not ResourceLoader.exists(LSHU_PORTRAIT):
		return null
	var portrait := load(LSHU_PORTRAIT) as Texture2D
	var head := AtlasTexture.new()
	head.atlas = portrait
	var w: float = portrait.get_width()
	head.region = Rect2(0, 6, w, minf(w, portrait.get_height() - 6))
	_lshu_head = head
	return head


## 同一张头像在这一局里第几次出现（0 起）：第二个 12 岁电脑、第二个借用 L叔 的真人等
static func avatar_variant(who: Variant, roster: Array = []) -> int:
	var r := _roster(roster)
	var i := seat_index_of(who, roster)
	if i < 0 or i >= r.size():
		return 0
	var id := avatar_id(who, roster)
	var n := 0
	for j in i:
		if avatar_id(r[j], roster) == id:
			n += 1
	return n


## 头像要不要左右镜像：同一张图第偶数次出现时镜像，一眼能分开是两个人
static func avatar_flip_h(who: Variant, roster: Array = []) -> bool:
	return avatar_variant(who, roster) % 2 == 1


# ------------------------------------------------------------------ 颜色
static func seat_color(color_id: String) -> Color:
	if SEAT_COLORS.has(color_id):
		return SEAT_COLORS[color_id]
	var gs := _game_state()
	var content: Dictionary = gs.get("content") if gs != null else {}
	var ruleset_colors: Array = GameData.get_player_colors(content) if content.has("ruleset") else []
	for c in ruleset_colors:
		if String((c as Dictionary).get("id", "")) == color_id:
			return Color(String((c as Dictionary).get("color", "#C98E4E")))
	return Kit.CAMEL


static func seat_color_deep(color_id: String) -> Color:
	return seat_color(color_id).darkened(0.28)


static func seat_color_soft(color_id: String) -> Color:
	return seat_color(color_id).lerp(Kit.CREAM, 0.78)


static func color_name(color_id: String) -> String:
	return String(COLOR_NAMES.get(color_id, ""))


## 座位颜色的光面圆章（lshu_setup/token_<颜色>.png）
static func token_texture(color_id: String) -> Texture2D:
	return texture_for_id("token_%s" % color_id) if color_id != "" else null


# ------------------------------------------------------------------ 名字、说明文字
static func default_human_name(seat_index: int) -> String:
	return "玩家%s" % HUMAN_NUMBERS[clampi(seat_index, 0, HUMAN_NUMBERS.size() - 1)]


static func default_ai_name(k: int) -> String:
	return AI_NAMES[posmod(k, AI_NAMES.size())]


## 「真人」/「电脑 · 12 岁」
static func role_text(who: Variant) -> String:
	if is_ai(who):
		return "电脑 · %s" % AIDifficulty.age_text(difficulty_of(who))
	return "真人"


## 「小驼铃（电脑 · 12 岁）」/「玩家一」
static func full_label(who: Variant) -> String:
	if is_ai(who):
		return "%s（%s）" % [name_of(who), role_text(who)]
	return name_of(who)


## 座位号（行动顺序）的显示：1–4
static func turn_number_text(seat_index: int) -> String:
	return str(seat_index + 1)


# ------------------------------------------------------------------ 圆头像徽章（可直接放进任何界面）
## 圆框头像：奶油底 + 座位颜色的粗圈；可选左上角的座位号小皮章。
##   var b := LshuSeats.Badge.new(96)  ;  b.set_seat(player)  或  b.set_seat(config, configs)
class Badge extends Control:
	var diameter: float = 96.0
	var ring_px: float = 7.0
	var show_number: bool = false
	var _face: PanelContainer
	var _img: TextureRect
	var _ring: _Ring
	var _num: Label
	var _num_bg: Panel

	func _init(d: float = 96.0) -> void:
		diameter = d
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(d, d)
		size = Vector2(d, d)
		pivot_offset = size * 0.5
		_face = PanelContainer.new()
		_face.name = "Face"
		var fs := StyleBoxFlat.new()
		fs.bg_color = Color("#FFF3DC")
		fs.set_corner_radius_all(int(d))
		fs.corner_detail = 18
		fs.anti_aliasing = true
		_face.add_theme_stylebox_override("panel", fs)
		_face.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
		_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_face.size = Vector2(d, d)
		add_child(_face)
		_img = TextureRect.new()
		_img.name = "Avatar"
		_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_face.add_child(_img)
		_ring = _Ring.new()
		_ring.name = "Ring"
		_ring.size = Vector2(d, d)
		add_child(_ring)
		_num_bg = Panel.new()
		_num_bg.name = "Number"
		var ns := StyleBoxFlat.new()
		ns.bg_color = Color("#7A4A2A")
		ns.border_color = Color("#FFF1DC")
		ns.set_border_width_all(3)
		ns.set_corner_radius_all(99)
		ns.corner_detail = 10
		ns.anti_aliasing = true
		ns.shadow_color = Color(0.25, 0.12, 0.05, 0.3)
		ns.shadow_size = 3
		ns.shadow_offset = Vector2(0, 2)
		_num_bg.add_theme_stylebox_override("panel", ns)
		var nd: float = maxf(30.0, d * 0.34)
		_num_bg.size = Vector2(nd, nd)
		_num_bg.position = Vector2(-nd * 0.18, -nd * 0.18)
		_num_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_num_bg.visible = false
		add_child(_num_bg)
		_num = preload("res://scripts/lshu_ui/lshu_ui_kit.gd").label("1", int(nd * 0.62), Color("#FFF1DC"), "body", 900)
		_num.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_num.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_num_bg.add_child(_num)

	## 按座位填：头像、镜像、座位颜色圈、座位号
	func set_seat(who: Variant, roster: Array = []) -> void:
		set_look(LshuSeats.avatar_texture(who, roster), LshuSeats.avatar_flip_h(who, roster), LshuSeats.seat_color(LshuSeats.color_id_of(who)))
		var i := LshuSeats.seat_index_of(who, roster)
		_num.text = LshuSeats.turn_number_text(maxi(i, 0))
		_num_bg.visible = show_number and i >= 0

	func set_look(tex: Texture2D, flip: bool, ring: Color) -> void:
		_img.texture = tex
		_img.flip_h = flip
		_ring.color = ring
		_ring.width = ring_px
		_ring.queue_redraw()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED and _face != null:
			_face.size = size
			_ring.size = size
			pivot_offset = size * 0.5


	class _Ring extends Control:
		var color: Color = Color("#8A5A3B")
		var width: float = 7.0

		func _init() -> void:
			mouse_filter = Control.MOUSE_FILTER_IGNORE

		func _draw() -> void:
			var r: float = minf(size.x, size.y) * 0.5
			var c := size * 0.5
			# 外圈一道深色细边 + 座位颜色粗圈 + 内侧一道亮边，像糖果圆框
			draw_arc(c, r - width * 0.5, 0.0, TAU, 72, color.darkened(0.3), width + 3.0, true)
			draw_arc(c, r - width * 0.5 - 1.0, 0.0, TAU, 72, color, width, true)
			draw_arc(c, r - width - 1.5, PI * 1.05, PI * 1.6, 24, Color(1, 1, 1, 0.45), 2.0, true)
