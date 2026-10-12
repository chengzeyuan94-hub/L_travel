extends RefCounted
## Act 4 「L叔在哪儿」 UI: shared look. Warm paper tones, one ink family, the project's own Chinese
## UI fonts (assets/game/ui/fonts/*.tres, read only). Sizes are written for a 1920x1080 screen and
## multiplied by the scale LshuUi computes; nothing here knows about any tile, place or asset.

const FONT_REGULAR: Font = preload("res://assets/game/ui/fonts/hud_body_regular.tres")
const FONT_MEDIUM: Font = preload("res://assets/game/ui/fonts/hud_body_medium.tres")
const FONT_SEMIBOLD: Font = preload("res://assets/game/ui/fonts/hud_heading_semibold.tres")
const FONT_BOLD: Font = preload("res://assets/game/ui/fonts/hud_display_bold.tres")

# ---------------------------------------------------------------------------------- palette
const PAPER: Color = Color(0.957, 0.925, 0.867)          # notebook page
const PAPER_LIGHT: Color = Color(0.984, 0.969, 0.937)    # postcard back
const PAPER_EDGE: Color = Color(0.871, 0.816, 0.722)
const CARD_WHITE: Color = Color(0.985, 0.976, 0.953)     # photo border
const INK: Color = Color(0.290, 0.227, 0.173)            # printed text
const INK_SOFT: Color = Color(0.541, 0.451, 0.361)
const PEN: Color = Color(0.200, 0.235, 0.325)            # L叔's handwriting: blue-black
const POSTMARK: Color = Color(0.690, 0.318, 0.235, 0.82)
const CAPTION: Color = Color(1.0, 0.969, 0.918)
const CAPTION_SUB: Color = Color(1.0, 0.953, 0.878, 0.9)
const SHADOW: Color = Color(0.157, 0.098, 0.051)
const COVER: Color = Color(0.463, 0.341, 0.251)          # travel book cloth
const COVER_DARK: Color = Color(0.345, 0.251, 0.184)
const MARGIN_LINE: Color = Color(0.741, 0.420, 0.333, 0.38)
const ACCENT: Color = Color(0.639, 0.341, 0.247)         # 回家, 过夜 marks

# ---------------------------------------------------------------------------------- sizes (px at 1920x1080)
const REF_SIZE: Vector2 = Vector2(1920.0, 1080.0)
const MIN_SCALE: float = 0.5        # a 640x360 window still reads
const MAX_SCALE: float = 4.0
const MIN_FONT_PX: float = 11.0     # physical pixels; small print never goes below this

const CAPTION_MARGIN: Vector2 = Vector2(76.0, 70.0)
const CAPTION_TITLE: float = 44.0
const CAPTION_SUB_SIZE: float = 24.0   # 地名下面那一行：21 在 1280×720 窗口里只有 14 像素（LSHU-9）
const STAMP_SIZE: Vector2 = Vector2(46.0, 56.0)
const STAMP_MARGIN: Vector2 = Vector2(58.0, 54.0)
const BOOK_SIZE: Vector2 = Vector2(1240.0, 860.0)
const BOOK_TEXT: float = 24.0
const BOOK_TITLE: float = 30.0
const BOOK_THUMB: Vector2 = Vector2(96.0, 64.0)
const AWAY_MARGIN: Vector2 = Vector2(64.0, 108.0)   # 让开左上角的「‹ 返回」（act_exit_button.gd，LSHU-10）
const AWAY_WIDTH: float = 520.0
const AWAY_TITLE: float = 28.0
const AWAY_TEXT: float = 21.0
const AWAY_THUMB: Vector2 = Vector2(120.0, 80.0)

static var _variations: Dictionary = {}
static var _blur_shader: Shader = null


## Pixels on screen per logical canvas unit. 1 inside a plain SubViewport; the stretch factor for
## the root window under the project's canvas_items stretch (1280x720 base).
static func pixels_per_unit(vp: Viewport) -> float:
	if vp == null:
		return 1.0
	var k: float = vp.get_final_transform().get_scale().x
	return k if k > 0.0001 else 1.0


## The logical-unit scale for a viewport: sizes are designed at 1920x1080 physical pixels, clamped
## so a 640x360 window still reads and a 3440x1440 one does not balloon (height decides on ultrawide).
static func ui_scale(logical_size: Vector2, px_per_unit: float) -> float:
	var phys: Vector2 = logical_size * px_per_unit
	var s: float = clampf(minf(phys.x / REF_SIZE.x, phys.y / REF_SIZE.y), MIN_SCALE, MAX_SCALE)
	return s / maxf(px_per_unit, 0.0001)


## Font size in logical units for a size designed at 1080p, never below MIN_FONT_PX on screen.
static func font_px(base: float, s: float, px_per_unit: float) -> int:
	return maxi(roundi(base * s), ceili(MIN_FONT_PX / maxf(px_per_unit, 0.0001)))


## The project font with extra letter spacing (FontVariation over the same SystemFont).
static func spaced(base: Font, glyph_px: int) -> Font:
	var key: String = "%d:%d" % [base.get_instance_id(), glyph_px]
	if _variations.has(key):
		return _variations[key]
	var fv: FontVariation = FontVariation.new()
	fv.base_font = base
	fv.spacing_glyph = glyph_px
	_variations[key] = fv
	return fv


static func label(text: String, font: Font, size: int, color: Color) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	style_label(l, font, size, color)
	return l


static func style_label(l: Label, font: Font, size: int, color: Color) -> void:
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)


## Paper panel with a soft drop shadow.
static func paper_box(color: Color, radius: float, shadow_px: float, shadow_alpha: float = 0.28) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(maxi(0, roundi(radius)))
	sb.shadow_color = Color(SHADOW, shadow_alpha)
	sb.shadow_size = maxi(0, roundi(shadow_px))
	sb.shadow_offset = Vector2(0.0, shadow_px * 0.35)
	sb.anti_aliasing = true
	return sb


# ---------------------------------------------------------------------------------- backdrop blur
const BLUR_CODE: String = """
shader_type canvas_item;
// Act 4 UI backdrop: the scene behind an open postcard or the travel book, slightly blurred
// and dimmed toward a warm brown. amount 0..1 is animated by the UI.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float lod_max = 2.6;
uniform float dim = 0.34;
uniform vec3 warm = vec3(0.24, 0.16, 0.10);

void fragment() {
	float lod = lod_max * amount;
	vec2 o = SCREEN_PIXEL_SIZE * exp2(lod) * 0.9;
	vec3 c = textureLod(screen_tex, SCREEN_UV, lod).rgb * 0.28;
	c += textureLod(screen_tex, SCREEN_UV + vec2(o.x, 0.0), lod).rgb * 0.09;
	c += textureLod(screen_tex, SCREEN_UV - vec2(o.x, 0.0), lod).rgb * 0.09;
	c += textureLod(screen_tex, SCREEN_UV + vec2(0.0, o.y), lod).rgb * 0.09;
	c += textureLod(screen_tex, SCREEN_UV - vec2(0.0, o.y), lod).rgb * 0.09;
	c += textureLod(screen_tex, SCREEN_UV + o, lod).rgb * 0.09;
	c += textureLod(screen_tex, SCREEN_UV - o, lod).rgb * 0.09;
	c += textureLod(screen_tex, SCREEN_UV + vec2(o.x, -o.y), lod).rgb * 0.09;
	c += textureLod(screen_tex, SCREEN_UV + vec2(-o.x, o.y), lod).rgb * 0.09;
	vec3 dimmed = mix(c, c * 0.58 + warm * 0.42 * 0.35, dim * amount * 1.6);
	COLOR = vec4(dimmed, 1.0);
}
"""


static func blur_material() -> ShaderMaterial:
	if _blur_shader == null:
		_blur_shader = Shader.new()
		_blur_shader.code = BLUR_CODE
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = _blur_shader
	m.set_shader_parameter("amount", 0.0)
	return m


static func blur_backdrop() -> ColorRect:
	var r: ColorRect = ColorRect.new()
	r.color = Color.WHITE
	r.material = blur_material()
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_STOP
	r.visible = false
	return r


static func set_blur(r: ColorRect, amount: float) -> void:
	(r.material as ShaderMaterial).set_shader_parameter("amount", clampf(amount, 0.0, 1.0))
	r.visible = amount > 0.001


# ---------------------------------------------------------------------------------- stamp art
## Colors for the little picture on a stamp, from the postcard's biome and time band only.
static func stamp_palette(biome: String, band: String) -> Dictionary:
	var p: Dictionary
	match biome:
		"snow":
			p = {"sky": Color(0.78, 0.86, 0.90), "far": Color(0.90, 0.93, 0.94), "near": Color(0.62, 0.72, 0.74), "sun": Color(0.98, 0.86, 0.66)}
		"desert", "sand":
			p = {"sky": Color(0.96, 0.82, 0.66), "far": Color(0.86, 0.56, 0.37), "near": Color(0.72, 0.40, 0.26), "sun": Color(1.0, 0.95, 0.80)}
		"harbor", "harbour", "water":
			p = {"sky": Color(0.76, 0.86, 0.88), "far": Color(0.50, 0.66, 0.71), "near": Color(0.36, 0.53, 0.59), "sun": Color(0.99, 0.90, 0.70)}
		_:
			p = {"sky": Color(0.95, 0.87, 0.71), "far": Color(0.79, 0.56, 0.33), "near": Color(0.56, 0.44, 0.27), "sun": Color(1.0, 0.95, 0.82)}
	match band:
		"night":
			p["sky"] = Color(0.23, 0.27, 0.40)
			p["sun"] = Color(0.95, 0.92, 0.80)
			p["far"] = (p.far as Color).darkened(0.45)
			p["near"] = (p.near as Color).darkened(0.5)
		"sunset":
			p["sky"] = Color(0.94, 0.70, 0.60)
			p["sun"] = Color(1.0, 0.86, 0.62)
		"morning":
			p["sky"] = (p.sky as Color).lerp(Color(0.97, 0.88, 0.82), 0.45)
	p["paper"] = CARD_WHITE
	p["frame"] = Color(INK_SOFT, 0.55)
	return p


## Outline of a postage stamp: a rectangle whose edges are bitten by semicircular perforations.
## Notch centres keep 1.5 r from each corner and at least 2.3 r from each other, so the outline never
## crosses itself at any size (a self-crossing outline cannot be triangulated).
static func perforated_polygon(rect: Rect2, r: float, pitch: float) -> PackedVector2Array:
	var pts: PackedVector2Array = PackedVector2Array()
	var corners: Array[Vector2] = [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	var segs: int = 6
	var margin: float = r * 1.5
	for e: int in 4:
		var a: Vector2 = corners[e]
		var b: Vector2 = corners[(e + 1) % 4]
		var edge: Vector2 = b - a
		var length: float = edge.length()
		var d: Vector2 = edge / length
		var inward: Vector2 = Vector2(-d.y, d.x)
		pts.append(a)
		var span: float = length - margin * 2.0
		if span < 0.0:
			continue
		var n: int = maxi(1, roundi(span / maxf(pitch, r * 2.3)) + 1)
		while n > 1 and span / float(n - 1) < r * 2.3:
			n -= 1
		var step: float = span / float(n - 1) if n > 1 else 0.0
		for i: int in n:
			var c: Vector2 = a + d * (margin + step * float(i) if n > 1 else length * 0.5)
			for j: int in segs + 1:
				var ang: float = PI * float(j) / float(segs)
				pts.append(c - d * r * cos(ang) + inward * r * sin(ang))
	return pts


static func draw_stamp(ci: CanvasItem, rect: Rect2, pal: Dictionary, s: float, with_shadow: bool = true) -> void:
	var r: float = maxf(1.2, rect.size.x * 0.045)
	var pitch: float = maxf(3.2, rect.size.x * 0.13)
	if with_shadow:
		var sh: PackedVector2Array = perforated_polygon(Rect2(rect.position + Vector2(1.5, 2.5) * s, rect.size), r, pitch)
		ci.draw_colored_polygon(sh, Color(SHADOW, 0.22))
	ci.draw_colored_polygon(perforated_polygon(rect, r, pitch), pal.get("paper", CARD_WHITE))
	var inset: float = rect.size.x * 0.13
	var ir: Rect2 = rect.grow(-inset)
	draw_scene_art(ci, ir, pal)
	ci.draw_rect(ir, pal.frame, false, maxf(1.0, 0.8 * s))


## A tiny generic landscape (sky, sun or moon, two ridges) in a postcard's biome / band colors.
## Used inside stamps and as the placeholder of a front whose image is not on disk.
static func draw_scene_art(ci: CanvasItem, ir: Rect2, pal: Dictionary) -> void:
	var w: float = ir.size.x
	var h: float = ir.size.y
	var o: Vector2 = ir.position
	ci.draw_rect(ir, pal.sky)
	ci.draw_rect(Rect2(o + Vector2(0.0, h * 0.5), Vector2(w, h * 0.5)), Color(1.0, 1.0, 1.0, 0.10))
	ci.draw_circle(o + Vector2(w * 0.70, h * 0.30), minf(w, h * 1.3) * 0.13, pal.sun)
	ci.draw_colored_polygon(PackedVector2Array([
		o + Vector2(0.0, h * 0.74), o + Vector2(w * 0.30, h * 0.40), o + Vector2(w * 0.50, h * 0.60),
		o + Vector2(w * 0.72, h * 0.46), o + Vector2(w, h * 0.70), o + Vector2(w, h), o + Vector2(0.0, h)]), pal.far)
	ci.draw_colored_polygon(PackedVector2Array([
		o + Vector2(0.0, h * 0.88), o + Vector2(w * 0.38, h * 0.70), o + Vector2(w * 0.70, h * 0.86),
		o + Vector2(w, h * 0.80), o + Vector2(w, h), o + Vector2(0.0, h)]), pal.near)


# ---------------------------------------------------------------------------------- postmark
## Round postmark: place name along the upper arc, the date across the middle between two bars,
## the time band (and 家 at home) at the bottom. info = LshuUiData.postmark_info().
static func draw_postmark(ci: CanvasItem, c: Vector2, r: float, info: Dictionary, col: Color, font: Font) -> void:
	var w_outer: float = maxf(1.0, r * 0.045)
	ci.draw_arc(c, r, 0.0, TAU, 96, col, w_outer, true)
	ci.draw_arc(c, r * 0.86, 0.0, TAU, 96, Color(col, col.a * 0.8), maxf(1.0, r * 0.022), true)
	# place name on the upper arc
	var place: String = String(info.get("place", ""))
	var chars: PackedStringArray = _glyphs(place)
	if chars.size() > 0:
		var rt: float = r * 0.63
		var fs: int = maxi(6, roundi(minf(r * 0.25, (rt * deg_to_rad(165.0)) / float(chars.size()) / 1.04)))
		var step: float = float(fs) * 1.04 / rt
		var span: float = step * float(chars.size())
		var start: float = -PI * 0.5 - span * 0.5
		for i: int in chars.size():
			var ang: float = start + step * (float(i) + 0.5)
			var pos: Vector2 = c + Vector2(cos(ang), sin(ang)) * rt
			var cw: float = font.get_string_size(chars[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			ci.draw_set_transform(pos, ang + PI * 0.5, Vector2.ONE)
			ci.draw_string(font, Vector2(-cw * 0.5, float(fs) * 0.36), chars[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# bars and date
	var bar_y: float = r * 0.2
	var half: float = sqrt(maxf(0.0, (r * 0.86) * (r * 0.86) - bar_y * bar_y))
	ci.draw_line(c + Vector2(-half, -bar_y), c + Vector2(half, -bar_y), col, maxf(1.0, r * 0.022), true)
	ci.draw_line(c + Vector2(-half, bar_y), c + Vector2(half, bar_y), col, maxf(1.0, r * 0.022), true)
	var date: String = String(info.get("date", ""))
	if date != "":
		var dfs: int = maxi(6, roundi(r * 0.21))
		var dw: float = font.get_string_size(date, HORIZONTAL_ALIGNMENT_LEFT, -1, dfs).x
		var maxw: float = half * 1.74        # keeps clear of the inner ring at the bar ends
		if dw > maxw:
			dfs = maxi(6, floori(float(dfs) * maxw / dw))
			dw = font.get_string_size(date, HORIZONTAL_ALIGNMENT_LEFT, -1, dfs).x
		ci.draw_string(font, c + Vector2(-dw * 0.5, float(dfs) * 0.36), date, HORIZONTAL_ALIGNMENT_LEFT, -1, dfs, col)
	# time band (and home mark) at the bottom
	var band: String = String(info.get("band_label", ""))
	if String(info.get("home_mark", "")) != "":
		band = String(info.home_mark) + " · " + band if band != "" else String(info.home_mark)
	if band != "":
		var bfs: int = maxi(6, roundi(r * 0.24))
		var bw: float = font.get_string_size(band, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs).x
		ci.draw_string(font, c + Vector2(-bw * 0.5, r * 0.60), band, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs, col)


## Wavy cancellation lines running right from a postmark.
static func draw_cancel_waves(ci: CanvasItem, from: Vector2, length: float, amp: float, gap: float, count: int, col: Color, width: float) -> void:
	for k: int in count:
		var pts: PackedVector2Array = PackedVector2Array()
		var y0: float = from.y + (float(k) - float(count - 1) * 0.5) * gap
		var steps: int = 28
		for i: int in steps + 1:
			var t: float = float(i) / float(steps)
			pts.append(Vector2(from.x + length * t, y0 + sin(t * TAU * 2.0) * amp))
		ci.draw_polyline(pts, col, width, true)


static func _glyphs(text: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for i: int in text.length():
		out.append(text.substr(i, 1))
	return out


## Greedy line wrap for Chinese text: breaks between any two characters, never starts a line with
## closing punctuation (it stays on the previous line), never ends a line with an opening quote.
const NO_LINE_START: String = "。，、．！？；：”’」』）》〉…—·,.!?;:)"
const NO_LINE_END: String = "“‘「『（《〈("
const BREAK_AFTER: String = "，、；：。！？,;:"


static func wrap_cjk(text: String, font: Font, size: int, width: float) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var line: String = ""
	for i: int in text.length():
		var ch: String = text.substr(i, 1)
		if ch == "\n":
			out.append(line)
			line = ""
			continue
		var trial: String = line + ch
		if line != "" and font.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > width and not NO_LINE_START.contains(ch):
			# prefer to break right after a comma-like mark in the last 45% of the line
			var cut: int = -1
			for j: int in range(line.length() - 1, int(float(line.length()) * 0.55) - 1, -1):
				if BREAK_AFTER.contains(line.substr(j, 1)):
					cut = j + 1
					break
			var carry: String = ""
			if cut > 0 and cut < line.length():
				carry = line.substr(cut)
				line = line.substr(0, cut)
			while line.length() > 1 and NO_LINE_END.contains(line.substr(line.length() - 1, 1)):
				carry = line.substr(line.length() - 1, 1) + carry
				line = line.substr(0, line.length() - 1)
			out.append(line)
			line = carry + ch
		else:
			line = trial
	if line != "":
		out.append(line)
	return out
