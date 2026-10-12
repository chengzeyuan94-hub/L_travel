extends RefCounted
## L叔 风格的自绘小部件：挎包缝线、眼镜进度章、眼镜镜片形圆按钮。

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")


## 挎包缝线：沿父面板内缩一圈画虚线（直边 + 四个圆角弧）。作为面板的子节点铺满即可。
class StitchLayer extends Control:
	var inset: float = 14.0
	var radius: float = 24.0
	var dash: float = 12.0
	var gap: float = 8.0
	var width: float = 2.5
	var color: Color = Color("#B88B63")

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	func _draw() -> void:
		# 按父面板的外框画（本节点被容器放在内边距里，所以先退回父面板坐标）
		var host := get_parent() as Control
		var origin: Vector2 = -position if host != null else Vector2.ZERO
		var full: Vector2 = host.size if host != null else size
		var r := Rect2(origin + Vector2(inset, inset), full - Vector2(inset, inset) * 2.0)
		if r.size.x <= radius * 2.0 or r.size.y <= radius * 2.0:
			return
		var pts: PackedVector2Array = PackedVector2Array()
		var corners: Array = [
			[Vector2(r.position.x + radius, r.position.y + radius), PI, 1.5 * PI],
			[Vector2(r.end.x - radius, r.position.y + radius), 1.5 * PI, 2.0 * PI],
			[Vector2(r.end.x - radius, r.end.y - radius), 0.0, 0.5 * PI],
			[Vector2(r.position.x + radius, r.end.y - radius), 0.5 * PI, PI],
		]
		for c: Array in corners:
			var ctr: Vector2 = c[0]
			var a0: float = c[1]
			var a1: float = c[2]
			for i in range(9):
				var a: float = lerpf(a0, a1, float(i) / 8.0)
				pts.append(ctr + Vector2(cos(a), sin(a)) * radius)
		pts.append(pts[0])
		# 按弧长切成虚线
		var on: bool = true
		var left: float = dash
		for i in range(pts.size() - 1):
			var p0: Vector2 = pts[i]
			var p1: Vector2 = pts[i + 1]
			var seg: float = p0.distance_to(p1)
			var t: float = 0.0
			while t < seg:
				var step: float = minf(left, seg - t)
				var q0: Vector2 = p0.lerp(p1, t / seg)
				var q1: Vector2 = p0.lerp(p1, (t + step) / seg)
				if on:
					draw_line(q0, q1, color, width, true)
				t += step
				left -= step
				if left <= 0.001:
					on = not on
					left = dash if on else gap


## 眼镜形进度章：两片圆角方镜片 + 鼻梁。filled 时镜片里放土豆花，fresh 时加发光。
class GlassesBadge extends Control:
	var filled: bool = false
	var fresh: bool = false
	var number: String = ""
	var flower: Texture2D
	var frame_color: Color = Color("#3A2A22")

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(118, 96)

	func _draw() -> void:
		var w: float = size.x
		var lens_w: float = w * 0.42
		var lens_h: float = lens_w * 0.78
		var y0: float = 4.0
		var lenses: Array = [Rect2(Vector2(w * 0.04, y0), Vector2(lens_w, lens_h)), Rect2(Vector2(w * 0.54, y0), Vector2(lens_w, lens_h))]
		var thick: float = maxf(3.0, w * 0.05)
		if fresh:
			draw_circle(Vector2(w * 0.5, y0 + lens_h * 0.5), w * 0.55, Color(1.0, 0.9, 0.55, 0.35))
		for r: Rect2 in lenses:
			var box := StyleBoxFlat.new()
			box.set_corner_radius_all(int(lens_h * 0.3))
			box.corner_detail = 8
			box.anti_aliasing = true
			if filled:
				box.bg_color = Color("#FFF6E0") if not fresh else Color("#FFF1C2")
				box.border_color = frame_color
				box.set_border_width_all(int(thick))
			else:
				box.bg_color = Color(1, 1, 1, 0.35)
				box.border_color = Color("#B9AC9A")
				box.set_border_width_all(int(thick * 0.6))
			draw_style_box(box, r)
			if filled and flower != null:
				var s: float = lens_h * 0.86
				draw_texture_rect(flower, Rect2(r.get_center() - Vector2(s, s) * 0.5, Vector2(s, s)), false)
		var bridge_y: float = y0 + lens_h * 0.36
		draw_line(Vector2(w * 0.04 + lens_w, bridge_y), Vector2(w * 0.54, bridge_y), frame_color if filled else Color("#B9AC9A"), thick * (1.0 if filled else 0.6), true)
		if number != "":
			var f: Font = Kit.font("body", 700)
			var px: int = int(w * 0.2)
			var tw: float = f.get_string_size(number, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
			draw_string(f, Vector2(w * 0.5 - tw * 0.5, y0 + lens_h + px + 4), number, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color("#3A2A22") if filled else Color("#9C8F7E"))


## 镜片形圆按钮：奶油圆底 + 粗眼镜框，中间放图标或一个字。
static func lens_button(glyph: String, diameter: float, tex: Texture2D = null) -> Button:
	var b := Button.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Kit.CREAM
	s.border_color = Kit.INK
	s.set_border_width_all(int(diameter * 0.075))
	s.border_width_bottom = int(diameter * 0.12)
	s.set_corner_radius_all(int(diameter))
	s.corner_detail = 16
	s.anti_aliasing = true
	s.shadow_color = Color(0.2, 0.12, 0.06, 0.22)
	s.shadow_size = 8
	s.shadow_offset = Vector2(0, 4)
	var hover := s.duplicate() as StyleBoxFlat
	hover.bg_color = Color("#FFFAF0")
	var pressed := s.duplicate() as StyleBoxFlat
	pressed.border_width_bottom = int(diameter * 0.075)
	for pair: Array in [["normal", s], ["hover", hover], ["pressed", pressed], ["hover_pressed", pressed], ["focus", StyleBoxEmpty.new()]]:
		b.add_theme_stylebox_override(pair[0], pair[1])
	b.custom_minimum_size = Vector2(diameter, diameter)
	b.text = glyph
	b.add_theme_font_override("font", Kit.font("body", 700))
	b.add_theme_font_size_override("font_size", int(diameter * 0.42))
	for key: String in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(key, Kit.INK)
	if tex != null:
		b.icon = tex
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_constant_override("icon_max_width", int(diameter * 0.6))
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return b


## 邮戳：砖红色双圈 + 右边三道波浪线（代码画的，墨色有一点透）
class Postmark extends Control:
	## 圈里放城市名的区域：内圈半径 42，字要缩到这个宽度以内才不压圈
	const TEXT_MAX_W := 68.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## 按实际量出来的字宽定字号（最大 30），长名字（君士坦丁堡）也不压到圈上
	static func fit_label(l: Label, text: String, base_px: int = 30) -> void:
		l.text = text
		var f: Font = l.get_theme_font("font")
		var px: int = base_px
		if f != null and text != "":
			var w: float = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, base_px).x
			if w > TEXT_MAX_W:
				px = maxi(12, int(floor(float(base_px) * TEXT_MAX_W / w)))
		l.add_theme_font_size_override("font_size", px)

	func _draw() -> void:
		var ink := Color("#B5473A", 0.82)
		var c := Vector2(60, 55)
		draw_arc(c, 50, 0, TAU, 64, ink, 4.0, true)
		draw_arc(c, 42, 0, TAU, 64, Color(ink, 0.6), 2.0, true)
		for i in 12:
			var ang: float = TAU * float(i) / 12.0
			draw_circle(c + Vector2(cos(ang), sin(ang)) * 46.0, 1.4, Color(ink, 0.7))
		for j in 3:
			var pts := PackedVector2Array()
			for k in 13:
				var x: float = 108.0 + k * 5.0
				pts.append(Vector2(x, 34.0 + j * 20.0 + sin(k * 0.9) * 4.0))
			draw_polyline(pts, Color(ink, 0.75), 3.0, true)


const GRAY_SHADER := """
shader_type canvas_item;
uniform float amount = 0.85;
uniform float lift = 0.12;
void fragment() {
	vec4 c = COLOR;  // Godot 4 的 COLOR 已经乘过贴图颜色
	float g = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	c.rgb = mix(c.rgb, vec3(g), amount) + lift;
	COLOR = c;
}
"""

static var _gray: ShaderMaterial

## 锁住的幕：缩略图去色、提亮
static func gray_material() -> ShaderMaterial:
	if _gray == null:
		var sh := Shader.new()
		sh.code = GRAY_SHADER
		_gray = ShaderMaterial.new()
		_gray.shader = sh
	return _gray
