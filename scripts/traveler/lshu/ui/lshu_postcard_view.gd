extends Control
## Act 4 UI: the postcard viewer. The scene behind is blurred and dimmed a little; the card slides
## up (or grows out of the thumbnail it was opened from); a click on the card flips it; a click on
## empty space, Esc, or `idle_limit` seconds without input sends it back (into the stamp, or back
## to its thumbnail) and emits closed(record, reason).

signal opened(record: Dictionary)
signal flipped(back: bool)
signal closed(record: Dictionary, reason: String)

const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")
const Card := preload("res://scripts/traveler/lshu/ui/lshu_postcard_card.gd")

var idle_limit: float = 20.0
var hint_opens: int = 2              # the small how-to line shows on the first N opens
var fly_target: Vector2 = Vector2(-1.0, -1.0)   # where the card goes on close (the stamp); <0 = slide down

var _backdrop: ColorRect
var _card: Control
var _hint: Label
var _record: Dictionary = {}
var _open: bool = false
var _anim: bool = false
var _idle: float = 0.0
var _flip: float = 0.0
var _origin: Rect2 = Rect2()
var _blur: float = 0.0
var _opens: int = 0
var _closing: Array = []           # [record, reason] while the close animation runs
var _tween: Tween
var _flip_tween: Tween
var _hint_tween: Tween
var _vp: Vector2 = Vector2(1920.0, 1080.0)
var _s: float = 1.0
var _ppu: float = 1.0
var _card_size: Vector2 = Vector2(972.0, 648.0)


func _init() -> void:
	name = "PostcardView"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	# A fresh copy of the screen for the blur: without it the backdrop reuses the copy taken for the
	# travel book's blur (one copy per frame), and a card opened from the book would hide the book.
	var bb: BackBufferCopy = BackBufferCopy.new()
	bb.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(bb)
	_backdrop = S.blur_backdrop()
	_backdrop.gui_input.connect(_on_backdrop_input)
	add_child(_backdrop)
	_card = Card.new()
	_card.name = "Card"
	_card.gui_input.connect(_on_card_input)
	add_child(_card)
	# 22 号字 + 半透明深色小药丸衬底（LSHU-9：以前 17 号、1280×720 下只有 11 像素，对比度 2.2:1）
	_hint = S.label("点卡片翻面 · 点空白处收起", S.FONT_MEDIUM, 22, Color(S.CAPTION, 0.96))
	_hint.add_theme_color_override("font_shadow_color", Color(S.SHADOW, 0.55))
	_hint.add_theme_constant_override("shadow_offset_y", 1)
	_hint.add_theme_constant_override("shadow_outline_size", 0)
	var hint_bg := StyleBoxFlat.new()
	hint_bg.bg_color = Color(S.SHADOW, 0.5)
	hint_bg.set_corner_radius_all(40)
	hint_bg.anti_aliasing = true
	_hint.add_theme_stylebox_override("normal", hint_bg)
	_hint.modulate.a = 0.0
	add_child(_hint)


func is_open() -> bool:
	return _open


func is_animating() -> bool:
	return _anim


func showing_back() -> bool:
	return _open and (_card.get("show_back") as bool)


func record() -> Dictionary:
	return _record


func card_rect() -> Rect2:
	return Rect2(_card.position, _card.size)


func card_control() -> Control:
	return _card


func poke() -> void:
	_idle = 0.0


func idle_time() -> float:
	return _idle


## Open a postcard record. tex may be null (a placeholder landscape is drawn). origin: the global
## rect of the thumbnail it came from, or an empty Rect2 to slide up from the bottom.
func open(rec: Dictionary, tex: Texture2D, tz_s: int, origin: Rect2 = Rect2()) -> void:
	if not _closing.is_empty():
		# reopened while the previous card was still flying back: finish that one first
		var prev: Array = _closing
		_closing = []
		closed.emit(prev[0] as Dictionary, String(prev[1]))
	_record = rec
	_origin = origin
	_card.call("set_record", rec, tex, tz_s)
	_card.call("set_face", false)
	_flip = 0.0
	_idle = 0.0
	_open = true
	visible = true
	_card.modulate.a = 1.0
	_card.rotation = 0.0
	_card.scale = Vector2.ONE
	_layout_card()
	var target_pos: Vector2 = _card.position
	var target_rot: float = -0.012
	if origin.size.x > 1.0:
		var k: float = origin.size.x / _card_size.x
		_card.scale = Vector2.ONE * k
		_card.position = origin.get_center() - _card_size * 0.5
	else:
		_card.position = Vector2(target_pos.x, _vp.y + _card_size.y * 0.08)
		_card.rotation = 0.07
		_card.scale = Vector2.ONE * 0.96
	_anim = true
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_card, "position", target_pos, 0.62).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_card, "rotation", target_rot, 0.7).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_card, "scale", Vector2.ONE, 0.62).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_blur, _blur, 1.0, 0.4)
	_tween.chain().tween_callback(func() -> void: _anim = false)
	_opens += 1
	if _opens <= hint_opens:
		_show_hint()
	opened.emit(rec)


## Send the card back. reason: "click", "idle", "key", "api".
func close(reason: String = "api") -> void:
	if not _open:
		return
	_open = false
	_anim = true
	if _flip_tween != null:
		_flip_tween.kill()
	if _tween != null:
		_tween.kill()
	_hint.modulate.a = 0.0
	var rec: Dictionary = _record
	_closing = [rec, reason]
	_tween = create_tween().set_parallel(true)
	if _origin.size.x > 1.0:
		var k: float = _origin.size.x / _card_size.x
		_tween.tween_property(_card, "position", _origin.get_center() - _card_size * 0.5, 0.42).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(_card, "scale", Vector2.ONE * k, 0.42).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(_card, "rotation", 0.0, 0.42)
		_tween.tween_property(_card, "modulate:a", 0.0, 0.14).set_delay(0.3)
	elif fly_target.x >= 0.0:
		_tween.tween_property(_card, "position", fly_target - _card_size * 0.5, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_tween.tween_property(_card, "scale", Vector2.ONE * 0.06, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_tween.tween_property(_card, "rotation", 0.35, 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		_tween.tween_property(_card, "modulate:a", 0.0, 0.16).set_delay(0.36)
	else:
		_tween.tween_property(_card, "position:y", _vp.y + _card_size.y * 0.1, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_tween.tween_property(_card, "rotation", 0.06, 0.45)
	_tween.tween_method(_set_blur, _blur, 0.0, 0.45)
	_tween.chain().tween_callback(_finish_close.bind(rec, reason))


func _finish_close(rec: Dictionary, reason: String) -> void:
	_anim = false
	if _closing.is_empty():
		return
	_closing = []
	if not _open:
		visible = false
	closed.emit(rec, reason)


func flip() -> void:
	if not _open or _anim:
		return
	var to: float = 0.0 if _flip >= 0.5 else 1.0
	if _flip_tween != null:
		_flip_tween.kill()
	_flip_tween = create_tween()
	_flip_tween.tween_method(_set_flip, _flip, to, 0.42).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_flip_tween.tween_callback(func() -> void: flipped.emit(to > 0.5))


## Jump to a face without the animation (tests, screenshots).
func set_face_now(back: bool) -> void:
	if _flip_tween != null:
		_flip_tween.kill()
	_set_flip(1.0 if back else 0.0)


func layout(vp: Vector2, s: float, ppu: float) -> void:
	_vp = vp
	_s = s
	_ppu = ppu
	_card.set("ppu", ppu)
	# The card takes 60% of the height on a big screen and up to 80% in a small window.
	var phys_h: float = vp.y * ppu
	var frac: float = lerpf(0.8, 0.6, clampf(inverse_lerp(360.0, 1080.0, phys_h), 0.0, 1.0))
	var h: float = minf(vp.y * frac, vp.x * 0.86 / 1.5)
	_card_size = Vector2(roundf(h * 1.5), roundf(h))
	S.style_label(_hint, S.FONT_MEDIUM, S.font_px(22.0, s, ppu), Color(S.CAPTION, 0.96))
	var hint_bg := _hint.get_theme_stylebox("normal") as StyleBoxFlat
	if hint_bg != null:
		hint_bg.content_margin_left = 18.0 * s
		hint_bg.content_margin_right = 18.0 * s
		hint_bg.content_margin_top = 5.0 * s
		hint_bg.content_margin_bottom = 6.0 * s
	_hint.add_theme_constant_override("shadow_offset_y", maxi(1, roundi(1.5 * s)))
	if _open and not _anim:
		_layout_card()
	elif not _open:
		_card.size = _card_size
		_card.pivot_offset = _card_size * 0.5


func _layout_card() -> void:
	_card.size = _card_size
	_card.pivot_offset = _card_size * 0.5
	_card.position = Vector2(_vp.x * 0.5, _vp.y * 0.475) - _card_size * 0.5
	var hs: Vector2 = _hint.get_combined_minimum_size()
	_hint.size = hs
	_hint.position = Vector2((_vp.x - hs.x) * 0.5, minf(_vp.y - hs.y - 4.0 * _s, _card.position.y + _card_size.y + 22.0 * _s))


func _process(delta: float) -> void:
	if _open and not _anim:
		_idle += delta
		if _idle >= idle_limit:
			close("idle")


func _on_card_input(event: InputEvent) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_card.accept_event()
		_idle = 0.0
		flip()


func _on_backdrop_input(event: InputEvent) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null and mb.pressed:
		# every button stays off the scene; only a real click (not the wheel) sends the card away
		_backdrop.accept_event()
		if not _anim and (mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT):
			close("click")


func _set_blur(v: float) -> void:
	_blur = v
	S.set_blur(_backdrop, v)


func _set_flip(v: float) -> void:
	_flip = v
	var sx: float = maxf(0.002, absf(cos(v * PI)))
	var lift: float = 1.0 + 0.035 * sin(v * PI)
	_card.scale = Vector2(sx * lift, lift)
	_card.call("set_face", v >= 0.5)


func _show_hint() -> void:
	if _hint_tween != null:
		_hint_tween.kill()
	_hint.modulate.a = 0.0
	_hint_tween = create_tween()
	_hint_tween.tween_interval(0.7)
	_hint_tween.tween_property(_hint, "modulate:a", 1.0, 0.6)
	_hint_tween.tween_interval(3.5)
	_hint_tween.tween_property(_hint, "modulate:a", 0.0, 1.2)
