extends Control
## Act 4 UI: a postcard thumbnail (travel book, away card). White border, cover-cropped image,
## soft shadow; lifts a little under the mouse; click asks the UI to open that postcard.

signal pressed(record: Dictionary, from_rect: Rect2)

const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")

var record: Dictionary = {}
var texture: Texture2D = null
var palette: Dictionary = {}
var tilt: float = 0.0
var _hover: float = 0.0
var _tween: Tween
var _box: StyleBoxFlat


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func() -> void: _hover_to(1.0))
	mouse_exited.connect(func() -> void: _hover_to(0.0))
	resized.connect(_on_resized)


func setup(rec: Dictionary, thumb_size: Vector2) -> void:
	record = rec
	palette = S.stamp_palette(String(rec.get("biome", "")), String(rec.get("band", "")))
	custom_minimum_size = thumb_size
	size = thumb_size
	# small stable tilt from the card id: no randomness at draw time
	tilt = (float(hash(String(rec.get("id", ""))) % 7) - 3.0) * 0.012


func set_texture(tex: Texture2D) -> void:
	texture = tex
	queue_redraw()


func _draw() -> void:
	if _box == null:
		_box = S.paper_box(S.CARD_WHITE, size.y * 0.03, maxf(2.0, size.y * 0.06), 0.3)
	var lift: float = _hover
	draw_set_transform(size * 0.5 - Vector2(0.0, lift * size.y * 0.05), tilt * (1.0 - lift), Vector2.ONE * (1.0 + lift * 0.06))
	var r: Rect2 = Rect2(-size * 0.5, size)
	draw_style_box(_box, r)
	var pr: Rect2 = r.grow(-maxf(2.0, size.y * 0.06))
	if texture != null:
		var ts: Vector2 = texture.get_size()
		var ar: float = pr.size.x / pr.size.y
		var src: Rect2
		if ts.x / ts.y > ar:
			var w: float = ts.y * ar
			src = Rect2(Vector2((ts.x - w) * 0.5, 0.0), Vector2(w, ts.y))
		else:
			var h: float = ts.x / ar
			src = Rect2(Vector2(0.0, (ts.y - h) * 0.5), Vector2(ts.x, h))
		draw_texture_rect_region(texture, pr, src)
	else:
		S.draw_scene_art(self, pr, palette)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _gui_input(event: InputEvent) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		pressed.emit(record, get_global_rect())


func _hover_to(v: float) -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(_apply_hover, _hover, v, 0.16)


func _apply_hover(x: float) -> void:
	_hover = x
	queue_redraw()


func _on_resized() -> void:
	_box = S.paper_box(S.CARD_WHITE, size.y * 0.03, maxf(2.0, size.y * 0.06), 0.3)
	queue_redraw()
