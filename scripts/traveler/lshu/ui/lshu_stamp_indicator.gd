extends Control
## Act 4 UI: the little postage stamp, bottom-right, shown only while there are unread postcards.
## No number on it. Its picture takes the biome / time band of the newest unread card.

signal pressed

const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")

const TILT: float = -0.09

var palette: Dictionary = {}
var unread: int = 0
var suppressed: bool = false        # hidden while the travel book is open
var _hover: float = 0.0
var _bump: float = 0.0
var _s: float = 1.0
var _vp: Vector2 = Vector2(1920.0, 1080.0)
var _tween: Tween
var _hover_tween: Tween


func _init() -> void:
	name = "StampIndicator"
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	visible = false
	modulate = Color(1, 1, 1, 0)
	palette = S.stamp_palette("", "day")
	mouse_entered.connect(func() -> void: _set_hover(1.0))
	mouse_exited.connect(func() -> void: _set_hover(0.0))


## n unread postcards (only zero / non-zero matters on screen). pal: S.stamp_palette() of the
## newest one. A new card makes the stamp pop in, or wiggle when it is already there.
func set_unread(n: int, pal: Dictionary) -> void:
	var before: int = unread
	unread = maxi(0, n)
	if not pal.is_empty():
		palette = pal
	queue_redraw()
	if suppressed:
		return
	if unread > 0 and before == 0:
		_appear()
	elif unread == 0 and before > 0:
		_disappear()
	elif unread > before:
		bump()


func set_suppressed(on: bool) -> void:
	if on == suppressed:
		return
	suppressed = on
	if on and visible:
		_disappear()
	elif not on and unread > 0:
		_appear()


func is_shown() -> bool:
	return unread > 0 and visible and not suppressed


func center() -> Vector2:
	return get_global_rect().get_center()


## Tiny bounce, e.g. when a postcard flies back into it.
func bump() -> void:
	var t: Tween = create_tween()
	t.tween_method(_set_bump, 0.0, 1.0, 0.45)


func layout(vp: Vector2, s: float, _ppu: float) -> void:
	_vp = vp
	_s = s
	var pad: Vector2 = Vector2(22.0, 22.0) * s   # 画出来的邮票不变，点击范围外扩一圈，孩子好点（LSHU-3）
	size = S.STAMP_SIZE * s + pad * 2.0
	position = vp - S.STAMP_MARGIN * s - size + pad
	pivot_offset = size * 0.5
	queue_redraw()


func _draw() -> void:
	var lift: float = _hover * 0.08 + sin(_bump * PI) * 0.12
	var rot: float = TILT * (1.0 - _hover * 0.5) + sin(_bump * TAU) * 0.08
	draw_set_transform(size * 0.5 - Vector2(0.0, _hover * 3.0 * _s), rot, Vector2.ONE * (1.0 + lift))
	var st: Vector2 = S.STAMP_SIZE * _s
	S.draw_stamp(self, Rect2(-st * 0.5, st), palette, _s, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _gui_input(event: InputEvent) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and visible and not suppressed:
		accept_event()
		# 双击的第二下不算：以前双击 = 打开又马上收回，还记成已读（LSHU-4）
		if not mb.double_click:
			pressed.emit()


func _appear() -> void:
	if _tween != null:
		_tween.kill()
	visible = true
	scale = Vector2.ONE * 0.6
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(self, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)
	_tween.tween_property(self, "scale", Vector2.ONE, 0.7).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _disappear() -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, 0.6).set_trans(Tween.TRANS_SINE)
	_tween.tween_callback(func() -> void: visible = false)


func _set_hover(target: float) -> void:
	if _hover_tween != null:
		_hover_tween.kill()
	_hover_tween = create_tween()
	_hover_tween.tween_method(_apply_hover, _hover, target, 0.18)


func _apply_hover(v: float) -> void:
	_hover = v
	queue_redraw()


func _set_bump(v: float) -> void:
	_bump = v if v < 1.0 else 0.0
	queue_redraw()
