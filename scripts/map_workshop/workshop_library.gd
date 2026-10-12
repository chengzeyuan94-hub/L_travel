extends Control
## 「我的地图」全屏浮层（DESIGN 3.12.8「打开」「扔掉」「拿回来」「游戏用回原版」）：
##   两个页签「我的地图」「扔掉的地图」；卡片网格，每张 360×270（缩略图、名字、「2 座新城 · 10月1日」，
##   游戏正在用的那张带「已装进游戏」绿章）；点卡片 = 选中，再点下方按钮：「打开这张」/「扔掉」（我的地图）、「拿回来」（扔掉的地图）；
##   右下角「在文件夹里看」；「游戏正在用：…」只是一行状态文字，旁边另有独立按钮「让游戏用回原版」（要确认）。
## 列表和按钮背后都是 CustomMapStore（WP1）：骨架阶段列表是空的、按钮点了只会说「还不行」。
## 卡片由根节点经 workshop_backend.gd 的 library_cards / trash_cards 拼好再给进来：{id, map_id, name, subtitle, thumb, installed}
## （缩略图、副标题、「已装进游戏」都是工坊自己算的，不依赖 store 条目的形状）。
## 本浮层只负责「选」；要不要确认、真的去改文件，由根节点（map_workshop.gd）按 R26 处理。

signal request(action: String, entry: Dictionary)     # "open" / "trash" / "restore" / "reveal" / "uninstall" / "close"

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const STAGE := Vector2(1920, 1080)
const CARD := Vector2(360, 270)

var tab := "library"
var entries: Array = []
var selected := {}
var installed_name := ""
var _grid: GridContainer
var _tabs := {}
var _status: Label
var _btn_main: Button
var _btn_trash: Button
var _btn_uninstall: Button
var _empty: Label


func _ready() -> void:
	size = STAGE
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.size = STAGE
	add_child(dim)
	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", Kit.satchel_box(34, 5, 0))
	panel.position = Vector2(120, 80)
	panel.size = Vector2(1680, 920)
	add_child(panel)
	var title := Kit.label("我的地图", 34, Kit.SATCHEL_DEEP, "body", 700)
	title.position = Vector2(170, 110)
	add_child(title)
	var tabs := HBoxContainer.new()
	tabs.position = Vector2(420, 104)
	tabs.add_theme_constant_override("separation", 12)
	add_child(tabs)
	for t in [["library", "我的地图"], ["trash", "扔掉的地图"]]:
		var b := Kit.button(String(t[1]), "cream", 64, 24)
		b.custom_minimum_size.x = 180
		b.pressed.connect(func() -> void: set_tab(String(t[0])))
		tabs.add_child(b)
		_tabs[t[0]] = b
	var close := Kit.button("关上", "cream", 64, 24)
	close.custom_minimum_size.x = 130
	close.position = Vector2(1620, 102)
	close.pressed.connect(func() -> void: request.emit("close", {}))
	add_child(close)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(170, 190)
	scroll.size = Vector2(1580, 650)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = 4
	_grid.add_theme_constant_override("h_separation", 24)
	_grid.add_theme_constant_override("v_separation", 24)
	scroll.add_child(_grid)
	_empty = Kit.label("", 26, Kit.INK_SOFT)
	_empty.position = Vector2(170, 220)
	add_child(_empty)
	var bottom := HBoxContainer.new()
	bottom.position = Vector2(170, 870)
	bottom.size = Vector2(1580, 72)
	bottom.add_theme_constant_override("separation", 18)
	add_child(bottom)
	_btn_main = Kit.button("打开这张", "primary", 64, 26)
	_btn_main.custom_minimum_size.x = 220
	_btn_main.pressed.connect(func() -> void: request.emit("open" if tab == "library" else "restore", selected))
	bottom.add_child(_btn_main)
	_btn_trash = Kit.button("扔掉", "cream", 64, 26)
	_btn_trash.custom_minimum_size.x = 160
	_btn_trash.pressed.connect(func() -> void: request.emit("trash", selected))
	bottom.add_child(_btn_trash)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(gap)
	_status = Kit.label("", 22, Kit.INK)
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bottom.add_child(_status)
	_btn_uninstall = Kit.button("让游戏用回原版", "cream", 64, 24)
	_btn_uninstall.pressed.connect(func() -> void: request.emit("uninstall", {}))
	bottom.add_child(_btn_uninstall)
	var reveal := Kit.button("在文件夹里看", "cream", 64, 24)
	reveal.pressed.connect(func() -> void: request.emit("reveal", {}))
	bottom.add_child(reveal)


func open(library: Array, trash: Array, installed: String) -> void:
	installed_name = installed
	set_meta("library", library)
	set_meta("trash", trash)
	visible = true
	set_tab("library")


func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


func set_tab(t: String) -> void:
	tab = t
	selected = {}
	entries = get_meta(t, [])
	for k in _tabs:
		(_tabs[k] as Button).modulate = Color.WHITE if k == t else Color(1, 1, 1, 0.6)
	_btn_main.text = "打开这张" if t == "library" else "拿回来"
	_btn_trash.visible = t == "library"
	_status.text = "游戏正在用：%s" % (installed_name if installed_name != "" else "原版地图")
	_btn_uninstall.visible = installed_name != ""
	_empty.text = ("还没有保存过的地图。" if t == "library" else "这里是空的：没有扔掉的地图。") if entries.is_empty() else ""
	_fill()


func _fill() -> void:
	for c in _grid.get_children():
		c.queue_free()
	for e: Dictionary in entries:
		_grid.add_child(_card(e))
	_btn_main.disabled = selected.is_empty()
	_btn_trash.disabled = selected.is_empty()


func _card(e: Dictionary) -> Control:
	var on := not selected.is_empty() and String(selected.get("id", "")) == String(e.get("id", ""))
	var p := Panel.new()
	p.custom_minimum_size = CARD
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#FFFDF7")
	sb.border_color = Kit.OCHRE if on else Kit.SATCHEL.lightened(0.5)
	sb.set_border_width_all(5 if on else 2)
	sb.set_corner_radius_all(18)
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var thumb := TextureRect.new()
	thumb.position = Vector2(12, 12)
	thumb.size = Vector2(CARD.x - 24, 190)
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture = e.get("thumb")
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(thumb)
	var name := Kit.label(String(e.get("name", "")), 24, Kit.INK, "body", 700)
	name.position = Vector2(16, 204)
	name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(name)
	var sub := Kit.label(String(e.get("subtitle", "")), 20, Kit.INK_SOFT)
	sub.position = Vector2(16, 236)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(sub)
	if bool(e.get("installed", false)):
		# 游戏正在用的那张：缩略图右上角一枚小绿章
		var badge := PanelContainer.new()
		var bs := Kit.pill_box(12, 4)
		bs.bg_color = Color("#7DBF6A")
		bs.shadow_size = 0
		badge.add_theme_stylebox_override("panel", bs)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge.add_child(Kit.label("已装进游戏", 20, Color.WHITE, "body", 700))
		badge.position = Vector2(CARD.x - 150, 20)
		p.add_child(badge)
	p.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			selected = e
			_fill())
	return p
