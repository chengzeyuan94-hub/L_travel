extends Control
## Act 4 UI: the place name, bottom-left. show_place() holds it for `hold_s` and fades it out;
## peek() brings it back for a few seconds when the mouse moves. Cream text over a soft warm
## shadow so it reads on snow, sand and night alike. Text only: title + small sub/epithet.

const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")

var title_text: String = ""
var sub_text: String = ""
var _title: Label
var _rule: ColorRect
var _sub: Label
var _glow: GradientTexture2D
var _hold: float = 0.0
var _showing: bool = false
var _target_a: float = 0.0
var _tween: Tween
var _s: float = 1.0
var _ppu: float = 1.0
var _vp: Vector2 = Vector2(1920.0, 1080.0)


func _init() -> void:
	name = "PlaceCaption"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	modulate = Color(1, 1, 1, 0)
	var g: Gradient = Gradient.new()
	g.set_color(0, Color(S.SHADOW, 0.36))
	g.set_color(1, Color(S.SHADOW, 0.0))
	g.add_point(0.55, Color(S.SHADOW, 0.16))
	_glow = GradientTexture2D.new()
	_glow.gradient = g
	_glow.fill = GradientTexture2D.FILL_RADIAL
	_glow.fill_from = Vector2(0.5, 0.5)
	_glow.fill_to = Vector2(1.0, 0.5)
	_glow.width = 256
	_glow.height = 128
	_title = S.label("", S.FONT_SEMIBOLD, 44, S.CAPTION)
	_rule = ColorRect.new()
	_rule.color = Color(S.CAPTION, 0.7)
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sub = S.label("", S.FONT_REGULAR, 21, S.CAPTION_SUB)
	for l: Label in [_title, _sub]:
		l.add_theme_color_override("font_shadow_color", Color(S.SHADOW, 0.5))
		l.add_theme_constant_override("shadow_offset_x", 0)
		l.add_theme_constant_override("shadow_offset_y", 1)
		l.add_theme_constant_override("shadow_outline_size", 6)
	add_child(_title)
	add_child(_rule)
	add_child(_sub)


func set_place(title: String, sub: String) -> void:
	title_text = title
	sub_text = sub
	_title.text = title
	_sub.text = sub
	_relayout()


## Fade in (unless already up) and hold for hold_s seconds.
func show_place(title: String, sub: String, hold_s: float, fade_in_s: float = 1.0) -> void:
	set_place(title, sub)
	if title == "":
		hide_now()
		return
	_hold = hold_s
	_fade_to(1.0, fade_in_s if not _showing else 0.25)
	_showing = true


## Mouse moved: show the current place for at least hold_s more seconds.
func peek(hold_s: float) -> void:
	if title_text == "":
		return
	if _showing:
		_hold = maxf(_hold, hold_s)
		# already up or fading in: every mouse-move event must not restart the tween
		if _target_a < 0.999:
			_fade_to(1.0, 0.3)
		return
	_hold = hold_s
	_showing = true
	_fade_to(1.0, 0.45)


func hide_soft(fade_s: float = 1.8) -> void:
	if not _showing:
		return
	_showing = false
	_hold = 0.0
	_fade_to(0.0, fade_s)


func hide_now() -> void:
	_showing = false
	_hold = 0.0
	_target_a = 0.0
	if _tween != null:
		_tween.kill()
	modulate.a = 0.0
	visible = false


func is_showing() -> bool:
	return _showing


func hold_left() -> float:
	return _hold


func layout(vp: Vector2, s: float, ppu: float) -> void:
	_vp = vp
	_s = s
	_ppu = ppu
	S.style_label(_title, S.FONT_SEMIBOLD, S.font_px(S.CAPTION_TITLE, s, ppu), S.CAPTION)
	S.style_label(_sub, S.spaced(S.FONT_REGULAR, maxi(1, roundi(2.0 * s))), S.font_px(S.CAPTION_SUB_SIZE, s, ppu), S.CAPTION_SUB)
	_title.add_theme_constant_override("shadow_outline_size", maxi(2, roundi(8.0 * s)))
	_sub.add_theme_constant_override("shadow_outline_size", maxi(2, roundi(6.0 * s)))
	_relayout()


func _relayout() -> void:
	var s: float = _s
	var ts: Vector2 = _title.get_combined_minimum_size()
	_title.position = Vector2.ZERO
	_title.size = ts
	var y: float = ts.y + 6.0 * s
	var has_sub: bool = sub_text != ""
	_rule.visible = has_sub
	_sub.visible = has_sub
	var w: float = ts.x
	if has_sub:
		_rule.position = Vector2(2.0 * s, y)
		_rule.size = Vector2(52.0 * s, maxf(1.0 / _ppu, 1.5 * s))
		y += _rule.size.y + 9.0 * s
		var ss: Vector2 = _sub.get_combined_minimum_size()
		_sub.position = Vector2(1.0 * s, y)
		_sub.size = ss
		y += ss.y
		w = maxf(w, ss.x)
	size = Vector2(w, y)
	position = Vector2(S.CAPTION_MARGIN.x * s, _vp.y - S.CAPTION_MARGIN.y * s - y)
	queue_redraw()


func _draw() -> void:
	if title_text == "":
		return
	var pad: Vector2 = Vector2(110.0, 70.0) * _s
	draw_texture_rect(_glow, Rect2(-pad, size + pad * 2.0), false)


func _process(delta: float) -> void:
	if _showing and _hold > 0.0:
		_hold -= delta
		if _hold <= 0.0:
			hide_soft()


func _fade_to(a: float, dur: float) -> void:
	_target_a = a
	if _tween != null:
		_tween.kill()
	visible = true
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", a, maxf(0.01, dur)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if a <= 0.0:
		_tween.tween_callback(func() -> void: visible = false)
