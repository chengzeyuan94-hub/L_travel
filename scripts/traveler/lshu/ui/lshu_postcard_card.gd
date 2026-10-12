extends Control
## Act 4 UI: one 3:2 postcard, drawn in code. Front: the rendered JPG inside a white border (cover
## crop, so any render aspect works). Back: printed 明信片 header, L叔's 1–2 lines in blue-black
## ink on faint rules, signature, a stamp in the card's biome / band colors, a round postmark
## (place, date, time band) with wavy cancel lines, and blank address rules.

const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")
const D := preload("res://scripts/traveler/lshu/ui/lshu_ui_data.gd")

var record: Dictionary = {}
var front: Texture2D = null
var show_back: bool = false
var info: Dictionary = {}
var lines: PackedStringArray = PackedStringArray()
var sig: String = "L"
var palette: Dictionary = {}
var ppu: float = 1.0
var _box_front: StyleBoxFlat
var _box_back: StyleBoxFlat
var _wrapped: PackedStringArray = PackedStringArray()
var _wrap_key: String = ""
var _wrap_fsize: int = 0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	resized.connect(_on_resized)


func set_record(rec: Dictionary, tex: Texture2D, tz_s: int) -> void:
	record = rec
	front = tex
	info = D.postmark_info(rec, tz_s)
	lines = D.postcard_lines(rec)
	sig = D.signature(rec)
	palette = S.stamp_palette(String(rec.get("biome", "")), String(rec.get("band", "")))
	_wrap_key = ""
	queue_redraw()


func set_front(tex: Texture2D) -> void:
	front = tex
	queue_redraw()


func set_face(back: bool) -> void:
	if back != show_back:
		show_back = back
		queue_redraw()


func _on_resized() -> void:
	var H: float = size.y
	_box_front = S.paper_box(S.CARD_WHITE, H * 0.012, H * 0.045, 0.34)
	_box_back = S.paper_box(S.PAPER_LIGHT, H * 0.012, H * 0.045, 0.34)
	_wrap_key = ""
	queue_redraw()


func _draw() -> void:
	if size.x < 4.0 or size.y < 4.0:
		return
	if _box_front == null:
		_on_resized()
	var r: Rect2 = Rect2(Vector2.ZERO, size)
	if show_back:
		draw_style_box(_box_back, r)
		_draw_back(r)
	else:
		draw_style_box(_box_front, r)
		_draw_front(r)


func _draw_front(r: Rect2) -> void:
	var H: float = r.size.y
	var pr: Rect2 = r.grow(-H * 0.045)
	if front != null:
		var ts: Vector2 = front.get_size()
		var target_ar: float = pr.size.x / pr.size.y
		var src: Rect2
		if ts.x / ts.y > target_ar:
			var w: float = ts.y * target_ar
			src = Rect2(Vector2((ts.x - w) * 0.5, 0.0), Vector2(w, ts.y))
		else:
			var h: float = ts.x / target_ar
			src = Rect2(Vector2(0.0, (ts.y - h) * 0.5), Vector2(ts.x, h))
		draw_texture_rect_region(front, pr, src)
	else:
		S.draw_scene_art(self, pr, palette)
	draw_rect(pr, Color(S.SHADOW, 0.10), false, maxf(1.0, H * 0.002))


func _draw_back(r: Rect2) -> void:
	var W: float = r.size.x
	var H: float = r.size.y
	var thin: float = maxf(1.0 / ppu, H * 0.0022)
	# printed frame and header
	draw_rect(r.grow(-H * 0.03), Color(S.INK_SOFT, 0.22), false, thin)
	var hfont: Font = S.spaced(S.FONT_MEDIUM, maxi(2, roundi(H * 0.018)))
	var hsize: int = maxi(6, roundi(H * 0.036))
	draw_string(hfont, Vector2(W * 0.07, H * 0.15), "明信片", HORIZONTAL_ALIGNMENT_LEFT, -1, hsize, Color(S.INK_SOFT, 0.85))
	# divider
	var divx: float = W * 0.555
	draw_line(Vector2(divx, H * 0.2), Vector2(divx, H * 0.86), Color(S.INK_SOFT, 0.35), thin, true)
	# message on faint rules
	var x0: float = W * 0.07
	var colw: float = divx - x0 - W * 0.045
	var fsize: int = maxi(6, roundi(H * 0.05))
	var font: Font = S.FONT_REGULAR
	var key: String = "%d:%d:%d" % [fsize, roundi(colw), lines.size()]
	if key != _wrap_key:
		_wrap_key = key
		_wrapped = PackedStringArray()
		for t: String in lines:
			_wrapped.append_array(S.wrap_cjk(t, font, fsize, colw))
		while _wrapped.size() > 5 and fsize > 6:
			fsize -= 1
			_wrapped = PackedStringArray()
			for t: String in lines:
				_wrapped.append_array(S.wrap_cjk(t, font, fsize, colw))
		_wrap_fsize = fsize
	# a shrunk size is kept with the cached wrap, so later redraws use the size the lines were cut for
	fsize = _wrap_fsize
	var lh: float = H * 0.092 * float(fsize) / maxf(1.0, float(maxi(6, roundi(H * 0.05))))
	var base0: float = H * 0.33
	var rows: int = maxi(5, _wrapped.size() + 1)
	for i: int in rows:
		var y: float = base0 + lh * float(i) + H * 0.02
		if y > H * 0.86:
			break
		draw_line(Vector2(x0, y), Vector2(x0 + colw, y), Color(S.INK, 0.11), thin, true)
	for i: int in _wrapped.size():
		draw_string(font, Vector2(x0 + H * 0.004, base0 + lh * float(i)), _wrapped[i], HORIZONTAL_ALIGNMENT_LEFT, colw, fsize, S.PEN)
	# signature, right-aligned on the row after the text, a little tilted like a hand
	var sfont: Font = S.FONT_SEMIBOLD
	var ssize: int = maxi(8, roundi(H * 0.084))
	var sw: float = sfont.get_string_size(sig, HORIZONTAL_ALIGNMENT_LEFT, -1, ssize).x
	var sy: float = base0 + lh * float(maxi(2, _wrapped.size()))
	draw_set_transform(Vector2(x0 + colw - sw - H * 0.02, sy), -0.1, Vector2.ONE)
	draw_string(sfont, Vector2.ZERO, sig, HORIZONTAL_ALIGNMENT_LEFT, -1, ssize, S.PEN)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# address rules (left blank)
	for yy: float in [0.62, 0.73, 0.84]:
		draw_line(Vector2(W * 0.61, H * yy), Vector2(W * 0.925, H * yy), Color(S.INK, 0.16), thin, true)
	# stamp, postmark, cancel waves
	var sh: float = H * 0.25
	var stamp_rect: Rect2 = Rect2(Vector2(W * 0.925 - sh * 0.82, H * 0.09), Vector2(sh * 0.82, sh))
	S.draw_stamp(self, stamp_rect, palette, H / 648.0, true)
	var pr: float = H * 0.125
	var c: Vector2 = Vector2(stamp_rect.position.x - pr * 0.72, stamp_rect.position.y + sh * 0.78)
	S.draw_cancel_waves(self, Vector2(c.x + pr * 1.08, c.y - pr * 0.05), stamp_rect.end.x + W * 0.015 - (c.x + pr * 1.08), H * 0.010, H * 0.032, 4,
		Color(S.POSTMARK, 0.55), maxf(1.0 / ppu, H * 0.0032))
	S.draw_postmark(self, c, pr, info, S.POSTMARK, S.FONT_MEDIUM)
