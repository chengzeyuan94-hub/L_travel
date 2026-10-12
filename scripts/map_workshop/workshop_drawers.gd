extends Control
## 换样子、换特产的抽屉（DESIGN 3.12.6）：视口下方升起，位置 (0, 700)，大小 1400×380（设计像素）。
## 棋盘用现成的 set_hud_safe_insets(0, 380) 让出这块，镜头把这座城摆在上方露出来的区域中间，边选边在地图上看效果。
##   样子：页签「西边风格」「东边风格」，先打开这座城所在那一侧；只列适配这座城交通类型、而且可用的原型
##         （shipped；开发开关 --catalogue-allow-draft 下也列 draft，R30）。每格 160×150：160×110 缩略图 + 22 px 名字。
##   特产：页签「西边特产」「东边特产」，每页 12 格，每格 104×130，图标 80 px，名字 20 px；鼠标停上去显示一句话。
##         本图其它新城用掉的特产变灰、打一把锁，小字写「XX在用」。
## 点一格就马上换上（普通操作，可撤销，不需要确认）；选中的格子赭黄描边打勾。右上角「好了」或 Esc 收起。
## 目录从 workshop_backend.gd 读（WP6a 之前是灰盒目录：没有缩略图和图标，画成纯色格子）。

signal picked(kind: String, id: String)
signal closed

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const Backend := preload("res://scripts/map_workshop/workshop_backend.gd")
const SIZE := Vector2(400, 952)
const POS := Vector2(1520, 76)
const LOOK_CELL := Vector2(160, 150)
const GOOD_CELL := Vector2(104, 130)
const CHECK_TEX := "res://assets/game/ui/lshu_setup/icon_check.png"
const LOCK_TEX := "res://assets/game/ui/lshu_3d/icons/lock.png"

var mode := ""                       # "look" / "goods"
var side := "W"
var route_type := "LAND"
var free_author := false
var current := ""
var used := {}                       # 特产 key -> 在用它的城名
var preview_only := false            # 第一阶段：还没有新城时只能看（点了只高亮）
var _grid: GridContainer
var _scroll: ScrollContainer
var _tab_btns := {}
var _title: Label
var _hint: Label
var _cells := {}                     # id -> Control


func _ready() -> void:
	position = POS
	size = SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var bg := Panel.new()
	var sb := Kit.satchel_box(30, 5, 0)
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	bg.add_theme_stylebox_override("panel", sb)
	bg.size = SIZE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_title = Kit.label("", 26, Kit.SATCHEL_DEEP, "body", 700)
	_title.position = Vector2(34, 26)
	add_child(_title)
	var tabs := HBoxContainer.new()
	tabs.position = Vector2(20, 74)
	tabs.add_theme_constant_override("separation", 10)
	add_child(tabs)
	for s in ["W", "E"]:
		var b := Kit.button("", "cream", 64, 22)
		b.custom_minimum_size.x = 150
		b.pressed.connect(func() -> void: _set_side(s))
		tabs.add_child(b)
		_tab_btns[s] = b
	var done := Kit.button("完成", "cream", 64, 24)
	done.custom_minimum_size.x = 130
	done.position = Vector2(20, 884)
	done.name="CloseSpecialtyDrawer"
	done.tooltip_text="只关闭面板；选中的特产已经应用。"
	done.pressed.connect(close)
	add_child(done)
	_hint = Kit.label("", 20, Kit.INK_SOFT)
	_hint.position = Vector2(20, 134)
	_hint.size = Vector2(360, 40)
	_hint.clip_text = true
	add_child(_hint)
	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(24, 190)                 # 页签、「好了」都是 64 高（y 12–76）
	_scroll.size = Vector2(352, 670)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 8)          # 8 × 160 + 7 × 8、12 × 104 + 11 × 8 都放得进 1340
	_grid.add_theme_constant_override("v_separation", 12)
	_scroll.add_child(_grid)


## 换样子：route_type 是这座城的交通类型（只列适配的），city_side 决定先打开哪一页
func open_look(city_side: String, rt: String, current_id: String, only_preview := false) -> void:
	mode = "look"
	route_type = rt
	current = current_id
	preview_only = only_preview
	_open(city_side)


## 换特产：used = {key: 在用它的城名}（本图其它新城）
func open_goods(city_side: String, current_key: String, used_by: Dictionary, only_preview := false) -> void:
	mode = "goods"
	current = current_key
	used = used_by
	preview_only = only_preview
	_open(city_side)


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func restore_selection(authoritative_id: String) -> void:
	current = authoritative_id
	_fill()


func _open(s: String) -> void:
	visible = true
	_set_side(s)


func _set_side(s: String) -> void:
	side = s
	for k in _tab_btns:
		var b: Button = _tab_btns[k]
		b.text = ("西边" if k == "W" else "东边") + ("风格" if mode == "look" else "特产")
		b.modulate = Color.WHITE if k == s else Color(1, 1, 1, 0.6)
	_title.text = "换一个样子" if mode == "look" else "换一种特产"
	_hint.text = "只能看看：放城的功能还在接。" if preview_only else ""
	_fill()


func _fill() -> void:
	for c in _grid.get_children():
		c.queue_free()
	_cells.clear()
	var cat := Backend.load_catalogue()
	if mode == "look":
		_grid.columns = 2
		var n := 0
		for a: Dictionary in cat.get("archetypes", []):
			if String(a.get("style_side", "")) != side or not Backend.offered(a) or (not free_author and not (route_type in a.get("fits", []))):
				continue
			_grid.add_child(_look_cell(a))
			n += 1
		if n == 0:
			_grid.add_child(Kit.label("这一边还没有能用的样子。", 22, Kit.INK_SOFT))
	else:
		_grid.columns = 3
		var n := 0
		for s: Dictionary in cat.get("specialties", []):
			if String(s.get("flavor_side", "")) != side or not Backend.offered(s):
				continue
			_grid.add_child(_good_cell(s))
			n += 1
		if n == 0:
			_grid.add_child(Kit.label("这一边还没有能用的特产。", 22, Kit.INK_SOFT))


func _look_cell(a: Dictionary) -> Control:
	var id := String(a.id)
	var cell := _cell(LOOK_CELL, id)
	var thumb := _thumb(String(a.get("thumb", "")), id, String(a.get("title", "")))
	thumb.position = Vector2(4, 4)
	thumb.size = Vector2(LOOK_CELL.x - 8, 106)
	cell.add_child(thumb)
	var l := Kit.label(String(a.get("title", id)), 22, Kit.INK)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.position = Vector2(0, 112)
	l.size = Vector2(LOOK_CELL.x, 34)
	l.clip_text = true
	cell.add_child(l)
	cell.tooltip_text = String(a.get("look", ""))
	return cell


func _good_cell(s: Dictionary) -> Control:
	var key := String(s.key)
	var cell := _cell(GOOD_CELL, key)
	var locked := not free_author and used.has(key) and key != current
	var icon := _thumb(String(s.get("icon", "")), key, String(s.get("display_name", "")))
	icon.position = Vector2((GOOD_CELL.x - 80) * 0.5, 8)
	icon.size = Vector2(80, 80)
	cell.add_child(icon)
	var l := Kit.label(String(s.get("display_name", key)), 20, Kit.INK)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.position = Vector2(0, 92)
	l.size = Vector2(GOOD_CELL.x, 30)
	cell.add_child(l)
	cell.tooltip_text = String(s.get("hint", ""))
	if locked:
		cell.modulate = Color(0.7, 0.7, 0.7, 0.8)
		cell.set_meta("locked", true)
		var lk := TextureRect.new()
		lk.texture = load(LOCK_TEX) if ResourceLoader.exists(LOCK_TEX) else null
		lk.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lk.size = Vector2(34, 34)
		lk.position = Vector2(GOOD_CELL.x - 38, 4)
		lk.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(lk)
		l.text = "%s在用" % String(used[key])
		l.add_theme_font_size_override("font_size", 20)
	return cell


func _cell(sz: Vector2, id: String) -> Control:
	var cell := Panel.new()
	cell.custom_minimum_size = sz
	cell.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var on := id == current
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#FFFDF7")
	sb.border_color = Kit.OCHRE if on else Kit.SATCHEL.lightened(0.5)
	sb.set_border_width_all(4 if on else 2)
	sb.set_corner_radius_all(14)
	cell.add_theme_stylebox_override("panel", sb)
	cell.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			_on_cell(id))
	if on:
		var ck := TextureRect.new()
		ck.texture = load(CHECK_TEX) if ResourceLoader.exists(CHECK_TEX) else null
		ck.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ck.size = Vector2(32, 32)
		ck.position = Vector2(sz.x - 36, sz.y - 36)
		ck.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(ck)
	_cells[id] = cell
	return cell


## 缩略图 / 图标：有就用；灰盒（WP6a 之前）画一块纯色，写上名字的头一个字
func _thumb(path: String, id: String, title: String) -> Control:
	if path != "" and ResourceLoader.exists(path):
		var t := TextureRect.new()
		t.texture = load(path)
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return t
	var p := Panel.new()
	var sb := StyleBoxFlat.new()
	var h := float(abs(hash(id)) % 360) / 360.0
	sb.bg_color = Color.from_hsv(h, 0.28, 0.86)
	sb.set_corner_radius_all(10)
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Kit.label(title.substr(0, 1), 40, Color.from_hsv(h, 0.45, 0.45), "body", 700)
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


func _on_cell(id: String) -> void:
	var cell: Control = _cells.get(id)
	if cell != null and bool(cell.get_meta("locked", false)):
		return
	current = id
	_fill()
	if not preview_only:
		picked.emit(mode, id)


func cell_ids() -> Array:
	return _cells.keys()

func show_applied(title: String) -> void:
	_hint.text="✓ 已换成"+title
	_hint.add_theme_color_override("font_color",Color("5e9e4e"))
