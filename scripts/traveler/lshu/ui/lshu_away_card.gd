extends PanelContainer
## Act 4 UI: 「你不在的时候」, a small paper note top-left after an absence of 2 h or more:
## how long you were gone, up to 8 places he passed, where he is now, one line in L叔's hand (a road
## line from the postcard library), and thumbnails of the postcards that came in meanwhile. Hides itself after `hold_s` (paused while the mouse is on it).

signal postcard_requested(record: Dictionary, from_rect: Rect2)
signal hidden_done

const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")
const D := preload("res://scripts/traveler/lshu/ui/lshu_ui_data.gd")
const Thumb := preload("res://scripts/traveler/lshu/ui/lshu_postcard_thumb.gd")

var images: RefCounted = null
var hold_s: float = 15.0
var _left: float = 0.0
var _hovered: bool = false
var _showing: bool = false
var _tween: Tween
var _margin: MarginContainer
var _box: VBoxContainer
var _title: Label
var _when: Label
var _route: HFlowContainer
var _now: Label
var _line: Label
var _sig: Label
var _pc_label: Label
var _row: HBoxContainer
var _records: Array = []
var _names: PackedStringArray = PackedStringArray()
var _s: float = 1.0
var _ppu: float = 1.0
var _vp: Vector2 = Vector2(1920.0, 1080.0)


func _init() -> void:
	name = "AwayCard"
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	modulate = Color(1, 1, 1, 0)
	_margin = MarginContainer.new()
	_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_margin)
	_box = VBoxContainer.new()
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_margin.add_child(_box)
	_title = S.label("", S.FONT_SEMIBOLD, 28, S.INK)
	_when = S.label("", S.FONT_REGULAR, 19, S.INK_SOFT)
	_route = HFlowContainer.new()
	_route.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_now = S.label("", S.FONT_REGULAR, 21, S.INK)
	_now.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_line = S.label("", S.FONT_REGULAR, 21, S.PEN)
	_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sig = S.label("", S.FONT_SEMIBOLD, 21, S.PEN)
	_sig.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_pc_label = S.label("他寄回的明信片", S.FONT_REGULAR, 19, S.INK_SOFT)
	_row = HBoxContainer.new()
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c: Control in [_title, _when, _route, _now, _line, _sig, _pc_label, _row]:
		_box.add_child(c)
	mouse_entered.connect(func() -> void: _hovered = true)
	mouse_exited.connect(func() -> void: _hovered = false)


func is_showing() -> bool:
	return _showing


func time_left() -> float:
	return _left


## catchup: the resolve() catchup event (or r.catchup). records: the new postcards that already
## have an image. current_name: where he is now. line: LshuUiData.away_line() ({text, signature}),
## empty = no line.
func present(catchup: Dictionary, records: Array, current_name: String, line: Dictionary = {}) -> void:
	var t: Dictionary = D.away_text(catchup, current_name)
	_title.text = String(t.title)
	_when.text = String(t.when)
	_names = D.away_places(catchup, current_name)
	_fill_route()
	_now.text = String(t.now)
	_now.visible = _now.text != ""
	_line.text = String(line.get("text", ""))
	_line.visible = _line.text != ""
	_sig.text = "—— " + String(line.get("signature", "L")) if _line.visible else ""
	_sig.visible = _line.visible
	_hovered = false
	_records = records
	for c: Node in _row.get_children():
		_row.remove_child(c)
		c.queue_free()
	for rec: Variant in records:
		var th: Control = Thumb.new()
		th.call("setup", rec, (S.AWAY_THUMB * _s).round())
		th.connect("pressed", _on_thumb)
		_row.add_child(th)
		if images != null:
			images.call("request", String((rec as Dictionary).get("file", "")), 320, Callable(th, "set_texture"))
	_pc_label.visible = not records.is_empty()
	_row.visible = not records.is_empty()
	_left = hold_s
	_showing = true
	visible = true
	_relayout()
	var target: Vector2 = position
	position = target - Vector2(0.0, 14.0 * _s)
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(self, "modulate:a", 1.0, 0.8).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(self, "position", target, 0.8).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func dismiss(fade_s: float = 1.2) -> void:
	if not _showing:
		return
	_showing = false
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, fade_s).set_trans(Tween.TRANS_SINE)
	_tween.tween_callback(_finish)


func hide_now() -> void:
	_showing = false
	if _tween != null:
		_tween.kill()
	modulate.a = 0.0
	visible = false


func _finish() -> void:
	if not _showing:
		visible = false
		hidden_done.emit()


func layout(vp: Vector2, s: float, ppu: float) -> void:
	_vp = vp
	_s = s
	_ppu = ppu
	var sb: StyleBoxFlat = S.paper_box(S.PAPER_LIGHT, 8.0 * s, 18.0 * s, 0.32)
	sb.border_color = Color(S.INK_SOFT, 0.25)
	sb.set_border_width_all(maxi(1, roundi(1.0 * s)))
	add_theme_stylebox_override("panel", sb)
	var m: int = roundi(26.0 * s)
	for side: String in ["margin_left", "margin_right"]:
		_margin.add_theme_constant_override(side, m)
	_margin.add_theme_constant_override("margin_top", roundi(22.0 * s))
	_margin.add_theme_constant_override("margin_bottom", roundi(24.0 * s))
	_box.add_theme_constant_override("separation", roundi(8.0 * s))
	_row.add_theme_constant_override("separation", roundi(14.0 * s))
	S.style_label(_title, S.spaced(S.FONT_SEMIBOLD, maxi(1, roundi(2.0 * s))), S.font_px(S.AWAY_TITLE, s, ppu), S.INK)
	S.style_label(_when, S.FONT_REGULAR, S.font_px(21.0, s, ppu), S.INK_SOFT)   # 19 → 21：1280×720 下不小于 14 像素（LSHU-9）
	_route.add_theme_constant_override("h_separation", roundi(7.0 * s))
	_route.add_theme_constant_override("v_separation", roundi(4.0 * s))
	_fill_route()
	S.style_label(_now, S.FONT_REGULAR, S.font_px(S.AWAY_TEXT, s, ppu), S.INK)
	S.style_label(_line, S.FONT_REGULAR, S.font_px(S.AWAY_TEXT, s, ppu), S.PEN)
	S.style_label(_sig, S.FONT_SEMIBOLD, S.font_px(21.0, s, ppu), S.PEN)
	S.style_label(_pc_label, S.FONT_REGULAR, S.font_px(21.0, s, ppu), S.INK_SOFT)
	for th: Node in _row.get_children():
		th.call("setup", (th as Control).get("record"), (S.AWAY_THUMB * s).round())
	_relayout()


## "他走过了 A → B → C": each place name is one unbreakable item, so names never split, and each
## arrow rides with the name before it, so a wrapped line never starts with "→".
func _fill_route() -> void:
	for c: Node in _route.get_children():
		_route.remove_child(c)
		c.queue_free()
	_route.visible = not _names.is_empty()
	if _names.is_empty():
		return
	var fs: int = S.font_px(S.AWAY_TEXT, _s, _ppu)
	_route.add_child(S.label("他走过了", S.FONT_REGULAR, fs, S.INK_SOFT))
	for i: int in _names.size():
		var name_label: Label = S.label(_names[i], S.FONT_REGULAR, fs, S.INK)
		if i == _names.size() - 1:
			_route.add_child(name_label)
			continue
		var unit: HBoxContainer = HBoxContainer.new()
		unit.mouse_filter = Control.MOUSE_FILTER_IGNORE
		unit.add_theme_constant_override("separation", roundi(7.0 * _s))
		unit.add_child(name_label)
		unit.add_child(S.label("→", S.FONT_REGULAR, fs, Color(S.INK_SOFT, 0.8)))
		_route.add_child(unit)


func _relayout() -> void:
	var w: float = minf(S.AWAY_WIDTH * _s, _vp.x - S.AWAY_MARGIN.x * _s * 2.0)
	custom_minimum_size = Vector2(w, 0.0)
	size = Vector2(w, 0.0)
	reset_size()
	size = Vector2(w, get_combined_minimum_size().y)
	position = (S.AWAY_MARGIN * _s).round()


func _process(delta: float) -> void:
	if visible:
		# autowrapped labels settle their height a frame after the width is set
		var want: float = get_combined_minimum_size().y
		if absf(size.y - want) > 0.5:
			size = Vector2(size.x, want)
	if _showing and not _hovered:
		_left -= delta
		if _left <= 0.0:
			dismiss()


func _gui_input(event: InputEvent) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		dismiss(0.5)


func _on_thumb(record: Dictionary, from_rect: Rect2) -> void:
	postcard_requested.emit(record, from_rect)
	dismiss(0.5)
