extends Control
## Act 4 UI：右下角邮票左边一本小小的旅行本（2026-09-27 夜测 LSHU-3：「L叔的旅行本」以前只有按 L 键才打开，
## 只会用鼠标的孩子永远找不到以前的明信片）。平时不在画面上；一动鼠标和地名一起浮出来几秒，不动就淡掉；
## 明信片 / 旅行本打开时不出现。点一下 = 打开旅行本。画法和邮票一样用 lshu_ui_style 的纸色和布面色，下面一行小字「旅行本」。

signal pressed

const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")

const ICON: Vector2 = Vector2(40.0, 50.0)      # 书的大小（1080p 像素）
const PAD: Vector2 = Vector2(22.0, 18.0)       # 点击范围往外扩一圈，孩子好点
const GAP_TO_STAMP: float = 48.0     # 和邮票（点击范围外扩 22）之间不重叠

var suppressed: bool = false
var _hold: float = 0.0
var _hover: float = 0.0
var _s: float = 1.0
var _ppu: float = 1.0
var _label: Label
var _tween: Tween


func _init() -> void:
	name = "BookButton"
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	tooltip_text = "L叔的旅行本（L）"
	visible = false
	modulate = Color(1, 1, 1, 0)
	_label = S.label("旅行本", S.FONT_MEDIUM, 18, S.CAPTION)
	_label.add_theme_color_override("font_shadow_color", Color(S.SHADOW, 0.7))
	_label.add_theme_constant_override("shadow_offset_y", 1)
	_label.add_theme_constant_override("shadow_outline_size", 4)
	add_child(_label)
	mouse_entered.connect(func() -> void:
		_hover = 1.0
		_hold = maxf(_hold, 1.5)
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hover = 0.0
		queue_redraw())


## 浮出来 hold_s 秒（鼠标一动就续上）
func peek(hold_s: float) -> void:
	if suppressed:
		return
	_hold = maxf(_hold, hold_s)
	if not visible or modulate.a < 0.99:
		_fade_to(1.0, 0.35)


func set_suppressed(on: bool) -> void:
	suppressed = on
	if on:
		_hold = 0.0
		_fade_to(0.0, 0.25)


func is_shown() -> bool:
	return visible and modulate.a > 0.5


## vp、s、ppu 同 lshu_ui 的其他部件；位置在邮票左边，和邮票底边对齐
func layout(vp: Vector2, s: float, ppu: float) -> void:
	_s = s
	_ppu = ppu
	S.style_label(_label, S.FONT_MEDIUM, S.font_px(21.0, s, ppu), S.CAPTION)
	var ls: Vector2 = _label.get_combined_minimum_size()
	size = Vector2(maxf(ICON.x * s, ls.x), ICON.y * s + 4.0 * s + ls.y) + PAD * 2.0 * s
	var stamp_left: float = vp.x - S.STAMP_MARGIN.x * s - S.STAMP_SIZE.x * s
	var bottom: float = vp.y - S.STAMP_MARGIN.y * s
	position = Vector2(stamp_left - GAP_TO_STAMP * s - size.x + PAD.x * s, bottom - size.y + PAD.y * s + ls.y + 4.0 * s)
	_label.size = ls
	_label.position = Vector2((size.x - ls.x) * 0.5, PAD.y * s + ICON.y * s + 4.0 * s)
	pivot_offset = size * 0.5
	queue_redraw()


func _draw() -> void:
	var s: float = _s
	var lift: float = _hover * 3.0 * s
	var r := Rect2(Vector2((size.x - ICON.x * s) * 0.5, PAD.y * s - lift), ICON * s)
	# 投影
	draw_rect(Rect2(r.position + Vector2(3.0, 4.0) * s, r.size), Color(S.SHADOW, 0.35))
	# 书页（右边、下边露一点纸）
	draw_rect(Rect2(r.position + Vector2(4.0 * s, 3.0 * s), r.size - Vector2(2.0 * s, 0.0)), S.PAPER_EDGE)
	draw_rect(Rect2(r.position + Vector2(3.0 * s, 1.5 * s), r.size - Vector2(3.0 * s, 1.5 * s)), S.PAPER)
	# 布面封皮 + 书脊
	var cover := Rect2(r.position, r.size - Vector2(4.0 * s, 3.0 * s))
	draw_rect(cover, S.COVER.lerp(Color.WHITE, 0.08 * _hover))
	draw_rect(Rect2(cover.position, Vector2(6.0 * s, cover.size.y)), S.COVER_DARK)
	# 封面上一块小标签和一道线
	var tag := Rect2(cover.position + Vector2(cover.size.x * 0.3, cover.size.y * 0.24), Vector2(cover.size.x * 0.56, cover.size.y * 0.2))
	draw_rect(tag, S.PAPER_LIGHT)
	draw_line(tag.position + Vector2(3.0 * s, tag.size.y * 0.5), tag.end - Vector2(3.0 * s, tag.size.y * 0.5), Color(S.INK_SOFT, 0.7), maxf(1.0, 1.5 * s))
	# 绑带
	draw_rect(Rect2(Vector2(cover.end.x - 9.0 * s, cover.position.y), Vector2(3.0 * s, cover.size.y)), S.ACCENT)


func _process(delta: float) -> void:
	if _hold > 0.0 and _hover < 0.5:
		_hold -= delta
		if _hold <= 0.0 and visible:
			_fade_to(0.0, 1.2)


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and visible and modulate.a > 0.3 and not suppressed:
		accept_event()
		pressed.emit()


func _fade_to(a: float, dur: float) -> void:
	if _tween != null:
		_tween.kill()
	if a > 0.0:
		visible = true
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", a, dur).set_trans(Tween.TRANS_SINE)
	if a <= 0.0:
		_tween.tween_callback(func() -> void: visible = false)
