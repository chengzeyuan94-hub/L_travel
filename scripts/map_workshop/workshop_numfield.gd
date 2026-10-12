extends VBoxContainer
## 属性面板的数字框（DESIGN 3.12.3「改数字」，照 C4D 属性管理器）：
##   - 直接输入数字；离开即生效：回车、Tab、点视口任意处、点面板里别的控件、换了选中的对象，都先提交再离开；
##   - 右边 ▲▼：点一下加减一格；按住 ▲▼ 上下拖，连续调（松手算一次提交）；
##   - 滚轮在数字框上不改值（只让面板滚动）——所以用 LineEdit + 自己画的 ▲▼，不用 SpinBox；
##   - 输入不合格（不是数字，或规则不许）：框变红，2 秒后恢复原值（R27）。
## 数值合不合格由外面给的 validator(value) 判断：返回 "" = 可以，否则是孩子话。
## 面板换内容（选中的对象换了）时先调 detach()：被拆下来的框永远不再提交（它被释放时 Godot 还会发一次 focus_exited，
## 那时框里要是有没提交的字，会在拆子节点的半路上又改一次文档、再嵌套一次重建面板）。

signal committed(value: float)
signal rejected(reason: String)
signal repaired
var error_label: Label

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const RED := Color("#CD483A")
const REVERT_MS := 2000
const DRAG_PX_PER_STEP := 4.0

var step := 0.1
var decimals := 2
var min_value := -INF
var max_value := INF
var suffix := ""
var validator: Callable
var edit: LineEdit
var _value := 0.0
var _spin: Control
var _drag_from := Vector2.INF
var _drag_base := 0.0
var _drag_steps := 0
var _dragged := false
var _revert_at := 0
var _normal_box: StyleBoxFlat
var _bad_box: StyleBoxFlat
var _dying := false
var _suspending_focus := false
var _suspended_draft := false


func _init(field_width := 150.0, px := 22) -> void:
	add_theme_constant_override("separation", 4)
	var inputs := HBoxContainer.new(); inputs.add_theme_constant_override("separation",4); add_child(inputs)
	edit = LineEdit.new()
	edit.custom_minimum_size = Vector2(field_width, 44)
	edit.add_theme_font_override("font", Kit.font("body", 600))
	edit.add_theme_font_size_override("font_size", px)
	edit.add_theme_color_override("font_color", Kit.INK)
	edit.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	edit.select_all_on_focus = true
	edit.context_menu_enabled = false
	_normal_box = _box(Kit.SATCHEL.lightened(0.35))
	_bad_box = _box(RED)
	edit.add_theme_stylebox_override("normal", _normal_box)
	edit.add_theme_stylebox_override("focus", _box(Kit.OCHRE))
	edit.text_submitted.connect(func(_t: String) -> void: _commit_text())
	edit.focus_exited.connect(_commit_text)
	inputs.add_child(edit)
	_spin = Control.new()
	_spin.custom_minimum_size = Vector2(30, 44)
	_spin.mouse_default_cursor_shape = Control.CURSOR_VSIZE
	_spin.mouse_filter = Control.MOUSE_FILTER_STOP
	_spin.gui_input.connect(_spin_input)
	_spin.draw.connect(_draw_spin)
	inputs.add_child(_spin)
	error_label = Kit.label("", 16, RED)
	error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	error_label.custom_minimum_size.x = 130
	error_label.visible = false
	add_child(error_label)


func _box(border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color("#FFFDF7")
	s.border_color = border
	s.set_border_width_all(2)
	s.set_corner_radius_all(10)
	s.content_margin_left = 10
	s.content_margin_right = 10
	return s


## 外面改了值（撤销、拖动、别的框提交后刷新）：框里正打着没提交的字时不动字，其它时候换成新值
func set_value(v: float) -> void:
	var typing := has_uncommitted_edit() or _suspended_draft
	_value = v
	if not typing:
		edit.text = _fmt(v)


func value() -> float:
	return _value


## 正在编辑、且框里的字和提交过的不一样（⌘Z 这时让给输入框，3.12.3）
func has_uncommitted_edit() -> bool:
	return edit.has_focus() and edit.text != _fmt(_value)


## Esc：丢掉没提交的字、结束编辑
func discard_edit() -> void:
	_suspended_draft = false
	edit.text = _fmt(_value)
	if edit.has_focus():
		edit.release_focus()


## Read-only location keeps the exact draft while releasing GUI focus without commit.
func suspend_edit() -> void:
	_suspended_draft = edit.text != _fmt(_value)
	_suspending_focus = true
	edit.release_focus()
	_suspending_focus = false


func restore_draft(text: String) -> void:
	edit.text = text
	_suspended_draft = text != _fmt(_value)


func has_suspended_draft() -> bool:
	return _suspended_draft and edit.text != _fmt(_value)


## 面板要拆掉这个框了：从此不再提交（先立标志、再放焦点，放焦点触发的 focus_exited 什么都不做）
func detach() -> void:
	_dying = true
	if edit.has_focus():
		edit.release_focus()


func _fmt(v: float) -> String:
	return ("%." + str(decimals) + "f") % v


func _commit_text() -> void:
	if _dying or _suspending_focus or not is_inside_tree() or edit.has_ime_text():
		return
	_suspended_draft = false
	var t := edit.text.strip_edges().replace("°", "").replace("%", "").replace(",", ".").replace("，", ".")
	if t == _fmt(_value):
		_clear_error()
		return
	if not t.is_valid_float():
		_reject("要填一个数字")
		return
	_try_commit(float(t))


func _try_commit(v: float, clamp_to_bounds := false) -> void:
	if not is_finite(v):
		_reject("要填一个有限的数字")
		return
	if not clamp_to_bounds and (v < min_value or v > max_value):
		_reject("要填 %s–%s 之间的数字" % [_fmt(min_value), _fmt(max_value)])
		return
	v = snappedf(v, pow(10.0, -decimals))
	if clamp_to_bounds: v = clampf(v, min_value, max_value)
	if absf(v - _value) < pow(10.0, -decimals) * 0.5:
		edit.text = _fmt(_value)
		_clear_error()
		return
	var why: String = validator.call(v) if validator.is_valid() else ""
	if why != "":
		_reject(why)
		return
	_clear_error()
	_value = v
	edit.text = _fmt(v)
	committed.emit(v)


## R27：框变红，2 秒后恢复原值
func _reject(why: String) -> void:
	error_label.text = why
	error_label.show()
	edit.tooltip_text = why
	edit.add_theme_stylebox_override("normal", _bad_box)
	edit.add_theme_color_override("font_color", RED)
	_revert_at = Time.get_ticks_msec() + REVERT_MS
	rejected.emit(why)
	get_tree().create_timer(REVERT_MS / 1000.0).timeout.connect(_end_reject)       # 框先被拆掉了：连接跟着断，不会打到释放了的框


func _end_reject() -> void:
	if _suspended_draft:
		return
	if Time.get_ticks_msec() + 5 < _revert_at:
		return                         # 2 秒里又红了一次：按后一次算
	edit.add_theme_stylebox_override("normal", _normal_box)
	edit.add_theme_color_override("font_color", Kit.INK)
	edit.text = _fmt(_value)


func is_showing_error() -> bool:
	return Time.get_ticks_msec() < _revert_at


# ------------------------------------------------------------------ ▲▼：点一下一格；按住上下拖连续调
func _spin_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			return                     # 滚轮不改值（交给面板滚动）
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			if _dying:
				return
			if edit.has_focus():
				_commit_text()
			_drag_from = mb.position
			_drag_base = _value
			_drag_steps = 0
			_dragged = false
			_spin.accept_event()
		elif _drag_from != Vector2.INF:
			var up := _drag_from.y < _spin.size.y * 0.5
			_drag_from = Vector2.INF
			_spin.accept_event()
			if _dragged:
				var v := _drag_base + _drag_steps * step
				_value = _drag_base          # 拖的过程只是预览：松手时整段算一次提交
				_try_commit(v, true)
			else:
				_try_commit(_value + (step if up else -step), true)
	elif event is InputEventMouseMotion and _drag_from != Vector2.INF:
		var dy := (event as InputEventMouseMotion).position.y - _drag_from.y
		var n := int(-dy / DRAG_PX_PER_STEP)
		if absf(dy) > DRAG_PX_PER_STEP:
			_dragged = true
		if _dragged and n != _drag_steps:
			_drag_steps = n
			edit.text = _fmt(clampf(_drag_base + n * step, min_value, max_value))
		_spin.accept_event()


func _draw_spin() -> void:
	var w := _spin.size.x
	var h := _spin.size.y
	var r := Rect2(Vector2.ZERO, _spin.size)
	_spin.draw_style_box(_box(Kit.SATCHEL.lightened(0.35)), r)
	var c := Kit.SATCHEL
	_spin.draw_colored_polygon(PackedVector2Array([Vector2(w * 0.5, h * 0.14), Vector2(w * 0.78, h * 0.4), Vector2(w * 0.22, h * 0.4)]), c)
	_spin.draw_colored_polygon(PackedVector2Array([Vector2(w * 0.5, h * 0.86), Vector2(w * 0.78, h * 0.6), Vector2(w * 0.22, h * 0.6)]), c)

func _clear_error() -> void:
	var had_error := not error_label.text.is_empty()
	_revert_at = 0
	error_label.text = ""; error_label.hide(); edit.tooltip_text = ""
	edit.add_theme_stylebox_override("normal", _normal_box)
	edit.add_theme_color_override("font_color", Kit.INK)
	if had_error: repaired.emit()
