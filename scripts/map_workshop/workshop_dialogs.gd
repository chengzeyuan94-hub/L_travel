extends Control
## 起名框和确认框（DESIGN R26、3.12.8）。孩子会乱点，所以：
##   - 所有不可逆操作一律「按钮 → 确认框 → 确定……」；
##   - 确认框弹出后 0.4 秒内的点击（和回车）都不算；
##   - 按钮顺序统一：最左边是安全选项（「再想想」「接着改」），默认焦点在它上面，Esc 等于它；
##     最右边粉色的是会丢东西的那个；三选一时中间是「先保存」。
## 760×400，居中，全屏压暗 50%。一次只开一个框。

signal closed(dialog_id: String, choice: String)

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const GUARD_MS := 400
const SIZE := Vector2(760, 400)
const STAGE := Vector2(1920, 1080)
const PINK := Color("#EE8F86")
const PINK_DEEP := Color("#C4655D")

var _id := ""
var _cb: Callable
var _shown_ms := 0
var _safe := ""
var _buttons := {}                   # choice id -> Button
var _dim: ColorRect
var _panel: PanelContainer
var _name_edit: LineEdit
var _name_hint: Label
var _title_label: Label
var _body_label: Label
var ignored_clicks := 0              # 0.4 秒内被挡掉的点击（测试用）


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = STAGE
	visible = false


func is_open() -> bool:
	return visible and _id != ""


func current_id() -> String:
	return _id


func safe_choice() -> String:
	return _safe


## 确认框。buttons：从左到右 [{id, text, kind}]，kind 是 "safe" / "middle" / "danger"；第一个必须是安全选项。
## on_choice(choice) 在关框之后调用。thumb 可选（导入框的缩略图）
func confirm(dialog_id: String, title: String, text: String, buttons: Array, on_choice: Callable = Callable(), thumb: Texture2D = null, scroll_body: bool = false) -> void:
	assert(not buttons.is_empty() and String(buttons[0].get("kind", "")) == "safe", "确认框最左边必须是安全选项")
	_open(dialog_id, on_choice)
	var box := _frame(title)
	if scroll_body:
		_panel.position=Vector2(500,170);_panel.custom_minimum_size=Vector2(920,740);_panel.size=Vector2(920,740)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 22)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(body)
	if thumb != null:
		var t := TextureRect.new()
		t.texture = thumb
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.custom_minimum_size = Vector2(240, 135)
		t.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		body.add_child(t)
	var l := Kit.label(text, 24, Kit.INK, "body", 500)
	_body_label = l
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if scroll_body:
		var scroll:=ScrollContainer.new();scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;scroll.size_flags_horizontal=Control.SIZE_EXPAND_FILL;scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL;scroll.custom_minimum_size.y=320;body.add_child(scroll)
		l.custom_minimum_size.x=800;l.vertical_alignment=VERTICAL_ALIGNMENT_TOP;scroll.add_child(l)
	else:body.add_child(l)
	_add_buttons(box, buttons)


## 起名框：「给这张地图起个名字」，1–10 个字；on_choice(choice)，choice 为 "ok" 时名字在 entered_name()
func ask_name(dialog_id: String, title: String, prefill: String, ok_text: String, on_choice: Callable = Callable()) -> void:
	_open(dialog_id, on_choice)
	var box := _frame(title)
	_name_edit = LineEdit.new()
	_name_edit.max_length = 10
	_name_edit.text = prefill
	_name_edit.custom_minimum_size = Vector2(0, 64)
	_name_edit.add_theme_font_override("font", Kit.font("body", 600))
	_name_edit.add_theme_font_size_override("font_size", 28)
	_name_edit.add_theme_color_override("font_color", Kit.INK)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#FFFDF7")
	sb.border_color = Kit.OCHRE
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 18
	_name_edit.add_theme_stylebox_override("normal", sb)
	_name_edit.add_theme_stylebox_override("focus", sb)
	_name_edit.text_submitted.connect(func(_t: String) -> void: _choose("ok"))
	_name_edit.text_changed.connect(func(_t: String) -> void: _refresh_name_hint())
	box.add_child(_name_edit)
	_name_hint = Kit.label("", 20, Kit.INK_SOFT)
	box.add_child(_name_hint)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)
	_add_buttons(box, [{"id": "cancel", "text": "再想想", "kind": "safe"}, {"id": "ok", "text": ok_text, "kind": "primary"}])
	_refresh_name_hint()
	_name_edit.grab_focus()
	_name_edit.select_all()


func entered_name() -> String:
	return _name_edit.text.strip_edges() if _name_edit != null else ""


## Update a waiting message without rebuilding buttons or resetting their focus/guard.
func update_confirm_text(dialog_id: String, title: String, text: String) -> bool:
	if not is_open() or _id != dialog_id or _name_edit != null:
		return false
	if not is_instance_valid(_title_label) or not is_instance_valid(_body_label):
		return false
	_title_label.text = title
	_body_label.text = text
	return true


func _refresh_name_hint() -> void:
	var n := entered_name().length()
	_name_hint.text = "1–10 个字" if n > 0 else "还没写名字呢"
	if _buttons.has("ok"):
		(_buttons["ok"] as Button).disabled = n == 0


## Esc = 安全选项（不受 0.4 秒限制：安全选项不丢任何东西）
func press_safe() -> void:
	if is_open():
		_finish(_safe)


# ------------------------------------------------------------------ 内部
func _open(dialog_id: String, on_choice: Callable) -> void:
	if is_open():
		_finish(_safe)                 # 一次只开一个框：旧的按安全选项关掉
	for c in get_children():
		c.queue_free()
	_buttons.clear()
	_name_edit = null
	_title_label = null
	_body_label = null
	_id = dialog_id
	_cb = on_choice
	_shown_ms = Time.get_ticks_msec()
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.5)
	_dim.size = STAGE
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)


func _frame(title: String) -> VBoxContainer:
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", Kit.satchel_box(30, 5, 34))
	_panel.position = (STAGE - SIZE) * 0.5
	_panel.custom_minimum_size = SIZE
	_panel.size = SIZE
	add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	_panel.add_child(box)
	var t := Kit.label(title, 30, Kit.SATCHEL_DEEP, "body", 700)
	_title_label = t
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(t)
	return box


func _add_buttons(box: VBoxContainer, buttons: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	_safe = String(buttons[0].id)
	for i in buttons.size():
		var bd: Dictionary = buttons[i]
		var kind := String(bd.get("kind", "safe"))
		var variant := "cream" if kind in ["safe", "outline_danger"] else ("denim" if kind == "middle" else "primary")
		if _id == "autosave" and kind == "safe": variant = "primary"
		var b := Kit.button(String(bd.text), variant, 64, 26)
		b.custom_minimum_size.x = 190
		if kind == "danger":
			_pink(b)
		elif kind == "outline_danger":
			var outline := Kit.pill_box(28, 2).duplicate() as StyleBoxFlat
			outline.bg_color=Color("fffdf7"); outline.border_color=Color("cd483a")
			b.add_theme_stylebox_override("normal",outline)
			b.add_theme_color_override("font_color",Color("cd483a"))
		b.focus_mode = Control.FOCUS_ALL
		var ring := StyleBoxFlat.new()
		ring.draw_center = false
		ring.border_color = Kit.SATCHEL_DEEP
		ring.set_border_width_all(3)
		ring.set_corner_radius_all(32)
		ring.expand_margin_left = 4
		ring.expand_margin_right = 4
		ring.expand_margin_top = 4
		ring.expand_margin_bottom = 4
		b.add_theme_stylebox_override("focus", ring)
		b.name = "Choice_" + String(bd.id)
		b.pressed.connect(_choose.bind(String(bd.id)))
		if i > 0:                      # 安全选项贴最左、会丢东西的贴最右，中间的居中
			var gap := Control.new()
			gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(gap)
		row.add_child(b)
		_buttons[String(bd.id)] = b
	if _name_edit == null:
		(_buttons[_safe] as Button).grab_focus()


func _pink(b: Button) -> void:
	var h := b.custom_minimum_size.y
	var r := int(h * 0.5)
	var lip := maxi(5, int(h * 0.085))
	var n := Kit.candy_box(PINK, PINK_DEEP, r, lip, int(h * 0.38), int(h * 0.12))
	var hv := Kit.candy_box(PINK.lightened(0.08), PINK_DEEP, r, lip, int(h * 0.38), int(h * 0.12))
	var p := Kit.candy_box(PINK.darkened(0.05), PINK_DEEP, r, 2, int(h * 0.38), int(h * 0.12))
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_stylebox_override("pressed", p)
	b.add_theme_stylebox_override("hover_pressed", p)
	for key: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(key, Color.WHITE)
	b.add_theme_color_override("font_outline_color", PINK_DEEP.darkened(0.2))
	b.add_theme_constant_override("outline_size", 2)


## 0.4 秒内的点击不算（R26）
func _choose(choice: String) -> void:
	if not is_open():
		return
	if Time.get_ticks_msec() - _shown_ms < GUARD_MS:
		ignored_clicks += 1
		return
	if choice == "ok" and _name_edit != null and entered_name().is_empty():
		return
	_finish(choice)


func _finish(choice: String) -> void:
	var id := _id
	var cb := _cb
	var nm := entered_name()
	_id = ""
	_cb = Callable()
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in get_children():
		c.queue_free()
	_buttons.clear()
	if _name_edit != null:
		_name_edit.set_meta("entered", nm)
	set_meta("last_name", nm)
	closed.emit(id, choice)
	if cb.is_valid():
		cb.call(choice)


func last_entered_name() -> String:
	return String(get_meta("last_name", ""))


## 测试用：按钮顺序（从左到右的 choice id）和默认焦点
func debug_state() -> Dictionary:
	var order := []
	var focus := ""
	for k in _buttons:
		order.append(k)
		if (_buttons[k] as Button).has_focus():
			focus = String(k)
	return {"id": _id, "order": order, "focus": focus, "safe": _safe, "open_ms": Time.get_ticks_msec() - _shown_ms}


func button(choice: String) -> Button:
	return _buttons.get(choice)
