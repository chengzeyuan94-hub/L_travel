extends Control
## Act 4 UI: the travel book (key L). A cloth-bound notebook over the blurred scene; one entry per
## trip, newest first: "9月23日–24日：甲地 → 乙地（过夜）→ … → 回家". A stop that sent a
## postcard carries its thumbnail; clicking it opens the postcard. No counts, no completion.

signal postcard_requested(record: Dictionary, from_rect: Rect2)
signal closed

const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")
const D := preload("res://scripts/traveler/lshu/ui/lshu_ui_data.gd")
const Thumb := preload("res://scripts/traveler/lshu/ui/lshu_postcard_thumb.gd")
const PAGE_TRIPS: int = 12


class BookFace extends Control:
	const St := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")
	var s: float = 1.0
	var ppu: float = 1.0
	var page: Rect2 = Rect2()
	var margin_x: float = 0.0
	var rule_y: float = 0.0
	var rule_x: Vector2 = Vector2.ZERO

	func _draw() -> void:
		var r: Rect2 = Rect2(Vector2.ZERO, size)
		draw_style_box(St.paper_box(St.COVER, 12.0 * s, 26.0 * s, 0.4), r)
		draw_style_box(St.paper_box(St.PAPER, 6.0 * s, 3.0 * s, 0.18), page)
		var thin: float = maxf(1.0 / ppu, 1.2 * s)
		# binding: a darker band with a stitched seam
		var band: Rect2 = Rect2(Vector2(0.0, 0.0), Vector2(page.position.x - 6.0 * s, size.y))
		draw_rect(Rect2(band.position + Vector2(10.0 * s, 0.0), Vector2(band.size.x - 16.0 * s, band.size.y)), Color(St.COVER_DARK, 0.55))
		var sx: float = page.position.x * 0.5
		var y: float = 22.0 * s
		while y < size.y - 22.0 * s:
			draw_line(Vector2(sx, y), Vector2(sx, y + 9.0 * s), Color(St.PAPER, 0.55), thin, true)
			y += 18.0 * s
		# notebook margin line and the rule under the title
		draw_line(Vector2(margin_x, page.position.y), Vector2(margin_x, page.end.y), St.MARGIN_LINE, thin, true)
		draw_line(Vector2(rule_x.x, rule_y), Vector2(rule_x.y, rule_y), Color(St.INK, 0.22), thin, true)


var images: RefCounted = null        # LshuUiImages, set by LshuUi
var idle_limit: float = 60.0
var tz_s: int = 0

var _backdrop: ColorRect
var _book: BookFace
var _title: Label
var _scroll: ScrollContainer
var _list: VBoxContainer
var _more: Button
var _trips: Array = []
var _shown: int = 0
var _open: bool = false
var _idle: float = 0.0
var _blur: float = 0.0
var _tween: Tween
var _vp: Vector2 = Vector2(1920.0, 1080.0)
var _s: float = 1.0
var _ppu: float = 1.0
var _text_px: int = 24
var _thumbs: Array = []


func _init() -> void:
	name = "TravelBook"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_backdrop = S.blur_backdrop()
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)
	_book = BookFace.new()
	_book.name = "Book"
	_book.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_book)
	_title = S.label("L叔的旅行本", S.FONT_SEMIBOLD, 30, S.INK)
	_book.add_child(_title)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_book.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_list)


func is_open() -> bool:
	return _open


func poke() -> void:
	_idle = 0.0


func book_rect() -> Rect2:
	return Rect2(_book.position, _book.size)


func thumbs() -> Array:
	var out: Array = []
	for t: Variant in _thumbs:
		if is_instance_valid(t):
			out.append(t)
	return out


func trip_count_shown() -> int:
	return _shown


func scroll_container() -> ScrollContainer:
	return _scroll


## trips: LshuUiData.build_trips() output, newest first.
func open(trips: Array) -> void:
	_trips = trips
	_open = true
	_idle = 0.0
	visible = true
	_rebuild(mini(PAGE_TRIPS, trips.size()))
	_scroll.scroll_vertical = 0
	var target: Vector2 = _book.position
	_book.position = target + Vector2(0.0, 36.0 * _s)
	_book.modulate.a = 0.0
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_book, "position", target, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_book, "modulate:a", 1.0, 0.35)
	_tween.tween_method(_set_blur, _blur, 1.0, 0.4)


func close() -> void:
	if not _open:
		return
	_open = false
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_book, "position:y", _book.position.y + 30.0 * _s, 0.28).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_property(_book, "modulate:a", 0.0, 0.26)
	_tween.tween_method(_set_blur, _blur, 0.0, 0.3)
	_tween.chain().tween_callback(_finish_close)


func _finish_close() -> void:
	if not _open:
		visible = false
		_clear()
		closed.emit()


func layout(vp: Vector2, s: float, ppu: float) -> void:
	_vp = vp
	_s = s
	_ppu = ppu
	_text_px = S.font_px(S.BOOK_TEXT, s, ppu)
	var bs: Vector2 = Vector2(minf(S.BOOK_SIZE.x * s, vp.x * 0.94), minf(S.BOOK_SIZE.y * s, vp.y * 0.94))
	_book.size = bs
	_book.position = ((vp - bs) * 0.5).round()
	_book.s = s
	_book.ppu = ppu
	var bind_w: float = 46.0 * s
	var pad: float = 14.0 * s
	_book.page = Rect2(Vector2(bind_w, pad), Vector2(bs.x - bind_w - pad, bs.y - pad * 2.0))
	var left: float = _book.page.position.x + clampf(96.0 * s, 24.0 * s, bs.x * 0.09)
	_book.margin_x = left - 26.0 * s
	S.style_label(_title, S.spaced(S.FONT_SEMIBOLD, maxi(1, roundi(3.0 * s))), S.font_px(S.BOOK_TITLE, s, ppu), S.INK)
	var ts: Vector2 = _title.get_combined_minimum_size()
	_title.position = Vector2(left, _book.page.position.y + clampf(34.0 * s, 10.0 * s, bs.y * 0.05))
	_title.size = ts
	_book.rule_y = _title.position.y + ts.y + 12.0 * s
	_book.rule_x = Vector2(left, _book.page.end.x - 40.0 * s)
	var top: float = _book.rule_y + clampf(22.0 * s, 8.0 * s, bs.y * 0.035)
	_scroll.position = Vector2(left, top)
	_scroll.size = Vector2(_book.page.end.x - 36.0 * s - left, _book.page.end.y - clampf(26.0 * s, 8.0 * s, bs.y * 0.04) - top)
	_list.add_theme_constant_override("separation", roundi(18.0 * s))
	_style_scrollbar()
	_book.queue_redraw()
	if _open:
		var n: int = _shown
		_rebuild(n)


func _process(delta: float) -> void:
	if _open:
		_idle += delta
		if _idle >= idle_limit:
			close()


func _rebuild(n: int) -> void:
	_clear()
	_shown = 0
	if _trips.is_empty():
		var empty: Label = S.label("他还没出过远门。", S.FONT_REGULAR, _text_px, S.INK_SOFT)
		_list.add_child(empty)
		return
	_append(n)


func _append(n: int) -> void:
	if _more != null and is_instance_valid(_more):
		_more.queue_free()
		_more = null
	var until: int = mini(_trips.size(), _shown + n)
	for i: int in range(_shown, until):
		if i > 0:
			var line: ColorRect = ColorRect.new()
			line.color = Color(S.INK, 0.10)
			line.custom_minimum_size = Vector2(0.0, maxf(1.0 / _ppu, 1.0 * _s))
			line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_list.add_child(line)
		_list.add_child(_trip_entry(_trips[i] as Dictionary))
	_shown = until
	if _shown < _trips.size():
		_more = Button.new()
		_more.text = "更早的旅程"
		_more.flat = true
		_more.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_more.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_more.add_theme_font_override("font", S.FONT_REGULAR)
		_more.add_theme_font_size_override("font_size", S.font_px(21.0, _s, _ppu))
		_more.add_theme_color_override("font_color", S.INK_SOFT)
		_more.add_theme_color_override("font_hover_color", S.ACCENT)
		_more.add_theme_color_override("font_pressed_color", S.ACCENT)
		_more.add_theme_color_override("font_focus_color", S.INK_SOFT)
		for st: String in ["normal", "hover", "pressed", "focus", "disabled"]:
			_more.add_theme_stylebox_override(st, StyleBoxEmpty.new())
		_more.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		_more.pressed.connect(func() -> void: _append(PAGE_TRIPS))
		_list.add_child(_more)


func _clear() -> void:
	for c: Node in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	_more = null
	_thumbs.clear()


func _trip_entry(t: Dictionary) -> Control:
	var flow: HFlowContainer = HFlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flow.add_theme_constant_override("h_separation", roundi(9.0 * _s))
	flow.add_theme_constant_override("v_separation", roundi(10.0 * _s))
	flow.add_child(_word(String(t.get("date_label", "")) + "：", S.FONT_SEMIBOLD, S.INK))
	var items: Array[Control] = []
	if bool(t.get("summary", false)):
		for n: Variant in t.get("places", []) as Array:
			items.append(_word(String(n), S.FONT_REGULAR, S.INK))
		for sv: Variant in t.get("stops", []) as Array:
			if bool((sv as Dictionary).get("long_way", false)):
				items.append(_word(D.LONG_WAY_WORD, S.FONT_REGULAR, S.INK_SOFT))
		if bool(t.get("more", false)):
			items.append(_word(D.MORE_MARK, S.FONT_REGULAR, S.INK_SOFT))
		if bool(t.get("home", false)):
			items.append(_word(D.HOME_WORD, S.FONT_MEDIUM, S.ACCENT))
		_add_chain(flow, items, false)
		var pcs: Array = t.get("postcards", []) as Array
		if pcs.is_empty():
			return flow
		var box: VBoxContainer = VBoxContainer.new()
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_theme_constant_override("separation", roundi(10.0 * _s))
		box.add_child(flow)
		var row: HFlowContainer = HFlowContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("h_separation", roundi(14.0 * _s))
		for pc: Variant in pcs:
			row.add_child(_thumb(pc as Dictionary))
		box.add_child(row)
		return box
	for sv: Variant in t.get("stops", []) as Array:
		items.append(_stop_item(sv as Dictionary))
	var trailing_more: bool = bool(t.get("in_progress", false)) and not bool(t.get("home", false))
	if trailing_more:
		items.append(_word(D.MORE_MARK, S.FONT_REGULAR, S.INK_SOFT))
	_add_chain(flow, items, trailing_more)
	return flow


## Lays route items into the flow as "item →" units, so a wrapped line never starts with an arrow.
## tail_joined: the last item (the "…" of a trip still under way) rides with the stop before it.
func _add_chain(flow: HFlowContainer, items: Array[Control], tail_joined: bool) -> void:
	var n: int = items.size()
	var i: int = 0
	while i < n:
		var last: bool = i == n - 1
		if last:
			flow.add_child(items[i])
			break
		var unit: HBoxContainer = HBoxContainer.new()
		unit.mouse_filter = Control.MOUSE_FILTER_IGNORE
		unit.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		unit.add_theme_constant_override("separation", roundi(9.0 * _s))
		unit.add_child(items[i])
		unit.add_child(_arrow_label())
		if tail_joined and i == n - 2:
			unit.add_child(items[n - 1])
			flow.add_child(unit)
			break
		flow.add_child(unit)
		i += 1


func _stop_item(st: Dictionary) -> Control:
	var pc: Dictionary = st.get("postcard", {}) as Dictionary
	var name_box: Control
	if bool(st.get("long_way", false)):
		name_box = _word(D.LONG_WAY_WORD, S.FONT_REGULAR, S.INK_SOFT)
	elif bool(st.get("home", false)):
		name_box = _word(String(st.get("home_word", D.HOME_WORD)), S.FONT_MEDIUM, S.ACCENT)
	elif bool(st.get("night", false)):
		var hb: HBoxContainer = HBoxContainer.new()
		hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_theme_constant_override("separation", 0)
		hb.add_child(_word(String(st.get("name", "")), S.FONT_REGULAR, S.INK))
		hb.add_child(_word(D.NIGHT_MARK, S.FONT_REGULAR, S.INK_SOFT))
		name_box = hb
	else:
		name_box = _word(String(st.get("name", "")), S.FONT_REGULAR, S.INK)
	if pc.is_empty():
		name_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		return name_box
	var item: HBoxContainer = HBoxContainer.new()
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_theme_constant_override("separation", roundi(10.0 * _s))
	item.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var th: Control = _thumb(pc)
	th.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	item.add_child(th)
	item.add_child(name_box)
	return item


func _thumb(pc: Dictionary) -> Control:
	var th: Control = Thumb.new()
	th.call("setup", pc, (S.BOOK_THUMB * _s).round())
	th.connect("pressed", _on_thumb_pressed)
	_thumbs.append(th)
	if images != null:
		images.call("request", String(pc.get("file", "")), 320, Callable(th, "set_texture"))
	return th


func _word(text: String, font: Font, color: Color) -> Label:
	var l: Label = S.label(text, font, _text_px, color)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l


func _arrow_label() -> Label:
	return _word("→", S.FONT_REGULAR, Color(S.INK_SOFT, 0.8))


func _on_thumb_pressed(record: Dictionary, from_rect: Rect2) -> void:
	_idle = 0.0
	postcard_requested.emit(record, from_rect)


func _on_backdrop_input(event: InputEvent) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_backdrop.accept_event()
		close()


func _set_blur(v: float) -> void:
	_blur = v
	S.set_blur(_backdrop, v)


func _style_scrollbar() -> void:
	var bar: VScrollBar = _scroll.get_v_scroll_bar()
	var track: StyleBoxFlat = StyleBoxFlat.new()
	track.bg_color = Color(S.INK, 0.05)
	track.set_corner_radius_all(roundi(3.0 * _s))
	track.content_margin_left = maxf(1.0, 3.0 * _s)
	track.content_margin_right = maxf(1.0, 3.0 * _s)
	bar.add_theme_stylebox_override("scroll", track)
	bar.add_theme_stylebox_override("scroll_focus", track)
	for key: String in ["grabber", "grabber_highlight", "grabber_pressed"]:
		var g: StyleBoxFlat = StyleBoxFlat.new()
		g.bg_color = Color(S.INK_SOFT, 0.35 if key == "grabber" else 0.5)
		g.set_corner_radius_all(roundi(3.0 * _s))
		bar.add_theme_stylebox_override(key, g)
