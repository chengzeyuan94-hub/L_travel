extends RefCounted
## 开场界面的贴图皮肤（image 2.5 按 L叔 概念图 01_title / 09_uikit 生成，处理脚本 tools/lshu_ui/process_kit.py）。
## 贴图按两倍设计像素保存；九宫格边距在 kit.json 里，绘制时按目标高度等比缩放，所以大小不同的按钮共用一套贴图。

const DIR := "res://assets/game/ui/lshu_title/"

static var _kit: Dictionary = {}


static func tex(name: String) -> Texture2D:
	var p: String = DIR + name + ".png"
	return load(p) as Texture2D if ResourceLoader.exists(p) else null


static func margins(name: String) -> Array:
	if _kit.is_empty():
		var p: String = DIR + "kit.json"
		if FileAccess.file_exists(p):
			var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
			if d is Dictionary:
				_kit = d
	return (_kit.get(name, {}) as Dictionary).get("nine", [0, 0, 0, 0])


## 糖果按钮：底图是九宫格贴图（按下换成压扁的那张），里面的图标和字是子节点 content，按下时整体下沉。
## 动效：悬停轻轻放大、图标摆一下；按下压扁；松开回弹。
class CandyButton extends Button:
	var skin: Texture2D
	var skin_pressed: Texture2D
	var nine: Array = [0, 0, 0, 0]
	var content: Control
	var wiggle_target: Control
	var _hover: bool = false
	var _down: bool = false
	var _tw: Tween

	func _init() -> void:
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var empty := StyleBoxEmpty.new()
		for key: String in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
			add_theme_stylebox_override(key, empty)
		mouse_entered.connect(func() -> void:
			_hover = true
			if disabled:
				return
			_bounce(Vector2(1.04, 1.04), 0.18)
			if wiggle_target != null:
				wiggle(wiggle_target)
			queue_redraw())
		mouse_exited.connect(func() -> void:
			_hover = false
			_set_down(false)
			_bounce(Vector2.ONE, 0.2)
			queue_redraw())
		button_down.connect(func() -> void:
			_set_down(true)
			_squash())
		button_up.connect(func() -> void:
			_set_down(false)
			_release())
		resized.connect(func() -> void: pivot_offset = size * 0.5)

	func _set_down(v: bool) -> void:
		_down = v
		if content != null:
			content.position.y = size.y * 0.05 if v else 0.0
		queue_redraw()

	func _draw() -> void:
		var t: Texture2D = skin_pressed if _down and skin_pressed != null else skin
		if t == null:
			return
		var mod := Color.WHITE
		if disabled:
			mod = Color(0.93, 0.9, 0.86)
		elif _hover and not _down:
			mod = Color(1.06, 1.05, 1.03)
		LshuSkinDraw.nine(self, t, nine, Rect2(Vector2.ZERO, size), size.y / float(t.get_height()), mod)

	func _bounce(to: Vector2, dur: float) -> void:
		if _tw != null:
			_tw.kill()
		_tw = create_tween()
		_tw.tween_property(self, "scale", to, dur).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	func _squash() -> void:
		if _tw != null:
			_tw.kill()
		_tw = create_tween()
		_tw.tween_property(self, "scale", Vector2(1.05, 0.92), 0.06).set_trans(Tween.TRANS_SINE)

	func _release() -> void:
		if _tw != null:
			_tw.kill()
		_tw = create_tween()
		_tw.tween_property(self, "scale", Vector2(0.97, 1.05), 0.08).set_trans(Tween.TRANS_SINE)
		_tw.tween_property(self, "scale", Vector2(1.04, 1.04) if _hover else Vector2.ONE, 0.3).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

	static func wiggle(node: Control) -> void:
		node.pivot_offset = node.size * 0.5
		var tw := node.create_tween()
		tw.tween_property(node, "rotation", deg_to_rad(-10.0), 0.07)
		tw.tween_property(node, "rotation", deg_to_rad(8.0), 0.1)
		tw.tween_property(node, "rotation", deg_to_rad(-4.0), 0.09)
		tw.tween_property(node, "rotation", 0.0, 0.1)


## 贴图按钮（眼镜片按钮等）：整张贴图就是按钮，悬停放大、按下压扁
class ImageButton extends TextureButton:
	var _tw: Tween

	func _init() -> void:
		focus_mode = Control.FOCUS_NONE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		ignore_texture_size = true
		stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		resized.connect(func() -> void: pivot_offset = size * 0.5)
		mouse_entered.connect(func() -> void: _to(Vector2(1.1, 1.1), 0.2, Tween.TRANS_BACK))
		mouse_exited.connect(func() -> void: _to(Vector2.ONE, 0.2, Tween.TRANS_BACK))
		button_down.connect(func() -> void: _to(Vector2(0.9, 0.9), 0.06, Tween.TRANS_SINE))
		button_up.connect(func() -> void: _to(Vector2(1.1, 1.1) if is_hovered() else Vector2.ONE, 0.35, Tween.TRANS_ELASTIC))

	func _to(s: Vector2, dur: float, trans: int) -> void:
		if _tw != null:
			_tw.kill()
		_tw = create_tween()
		_tw.tween_property(self, "scale", s, dur).set_trans(trans).set_ease(Tween.EASE_OUT)


## 画九宫格背景的普通容器（皮革面板、对话泡泡）：px 固定 0.5（贴图两倍存）
class NinePanel extends PanelContainer:
	var skin: Texture2D
	var nine: Array = [0, 0, 0, 0]
	var px: float = 0.5

	func _init(pad_l: float = 0, pad_t: float = 0, pad_r: float = 0, pad_b: float = 0) -> void:
		var s := StyleBoxEmpty.new()
		s.content_margin_left = pad_l
		s.content_margin_top = pad_t
		s.content_margin_right = pad_r
		s.content_margin_bottom = pad_b
		add_theme_stylebox_override("panel", s)

	func _draw() -> void:
		LshuSkinDraw.nine(self, skin, nine, Rect2(Vector2.ZERO, size), px)


## 内部类里拿不到外层的静态函数，九宫格绘制单独放一个内部类转发
class LshuSkinDraw:
	static func nine(ci: CanvasItem, t: Texture2D, m: Array, r: Rect2, px: float, mod: Color = Color.WHITE) -> void:
		if t == null:
			return
		var tw: float = t.get_width()
		var th: float = t.get_height()
		var sx: Array[float] = [0.0, float(m[0]), tw - float(m[2]), tw]
		var sy: Array[float] = [0.0, float(m[1]), th - float(m[3]), th]
		var cap_x: float = minf(1.0, r.size.x / maxf(1.0, (float(m[0]) + float(m[2])) * px))
		var cap_y: float = minf(1.0, r.size.y / maxf(1.0, (float(m[1]) + float(m[3])) * px))
		var dx: Array[float] = [r.position.x, r.position.x + float(m[0]) * px * cap_x, r.end.x - float(m[2]) * px * cap_x, r.end.x]
		var dy: Array[float] = [r.position.y, r.position.y + float(m[1]) * px * cap_y, r.end.y - float(m[3]) * px * cap_y, r.end.y]
		for j in 3:
			for i in 3:
				var dst := Rect2(dx[i], dy[j], dx[i + 1] - dx[i], dy[j + 1] - dy[j])
				var src := Rect2(sx[i], sy[j], sx[i + 1] - sx[i], sy[j + 1] - sy[j])
				if dst.size.x > 0.01 and dst.size.y > 0.01 and src.size.x > 0.01 and src.size.y > 0.01:
					ci.draw_texture_rect_region(t, dst, src, mod, false, true)


static func candy_button(color: String) -> CandyButton:
	var b := CandyButton.new()
	b.skin = tex("btn_" + color)
	b.skin_pressed = tex("btn_%s_pressed" % color)
	b.nine = margins("btn_" + color)
	return b


static func nine_panel(name: String, pad: Vector4) -> NinePanel:
	var p := NinePanel.new(pad.x, pad.y, pad.z, pad.w)
	p.skin = tex(name)
	p.nine = margins(name)
	return p


static func image_button(name: String, sz: Vector2) -> ImageButton:
	var b := ImageButton.new()
	b.texture_normal = tex(name)
	b.custom_minimum_size = sz
	return b


static func image(name: String, height: float) -> TextureRect:
	var t := TextureRect.new()
	t.texture = tex(name)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if t.texture != null:
		t.custom_minimum_size = Vector2(height * t.texture.get_width() / t.texture.get_height(), height)
	return t


## 小箭头 ›：圆头粗线，比字体里的 › 更像概念图
class Chevron extends Control:
	var color: Color = Color("#4A2C1A")
	var outline: Color = Color(0, 0, 0, 0)
	var thick: float = 7.0

	func _init(sz: Vector2 = Vector2(22, 34)) -> void:
		custom_minimum_size = sz
		size = sz
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var pts := PackedVector2Array([Vector2(thick * 0.6, thick * 0.6), Vector2(size.x - thick * 0.6, size.y * 0.5), Vector2(thick * 0.6, size.y - thick * 0.6)])
		if outline.a > 0.0:
			draw_polyline(pts, outline, thick + 5.0, true)
			for p in pts:
				draw_circle(p, (thick + 5.0) * 0.5, outline)
		draw_polyline(pts, color, thick, true)
		for p in pts:
			draw_circle(p, thick * 0.5, color)


## 给已有的 Button 换成糖果贴图（不换节点类型，别的脚本和测试照样认它）：
## 在按钮下面垫一层画在它身后的九宫格（show_behind_parent），状态跟着按钮自己的 draw mode 走；
## 悬停轻轻放大、按下压扁、松开回弹。按钮自己的 styleboxes 清空，文字照常画在上面。
class CandySkin extends Control:
	var skin: Texture2D
	var skin_pressed: Texture2D
	var nine: Array = [0, 0, 0, 0]
	var dim_disabled: bool = true
	var _tw: Tween

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		show_behind_parent = true

	func _ready() -> void:
		var b := get_parent() as BaseButton
		if b == null:
			return
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		b.draw.connect(queue_redraw)
		b.resized.connect(func() -> void: b.pivot_offset = b.size * 0.5)
		b.pivot_offset = b.size * 0.5
		b.mouse_entered.connect(func() -> void:
			if not b.disabled:
				_to(b, Vector2(1.04, 1.04), 0.18, Tween.TRANS_BACK))
		b.mouse_exited.connect(func() -> void: _to(b, Vector2.ONE, 0.2, Tween.TRANS_BACK))
		b.button_down.connect(func() -> void: _to(b, Vector2(1.05, 0.92), 0.06, Tween.TRANS_SINE))
		b.button_up.connect(func() -> void:
			_to(b, Vector2(1.04, 1.04) if b.is_hovered() else Vector2.ONE, 0.32, Tween.TRANS_ELASTIC))

	func _to(b: Control, s: Vector2, dur: float, trans: int) -> void:
		if _tw != null:
			_tw.kill()
		_tw = b.create_tween()
		_tw.tween_property(b, "scale", s, dur).set_trans(trans).set_ease(Tween.EASE_OUT)

	func _draw() -> void:
		var b := get_parent() as BaseButton
		if b == null or skin == null:
			return
		var mode: int = b.get_draw_mode()
		var down: bool = mode == BaseButton.DRAW_PRESSED or mode == BaseButton.DRAW_HOVER_PRESSED
		var t: Texture2D = skin_pressed if down and skin_pressed != null else skin
		var mod := Color.WHITE
		if mode == BaseButton.DRAW_DISABLED and dim_disabled:
			mod = Color(0.82, 0.8, 0.76, 0.9)
		elif mode == BaseButton.DRAW_HOVER:
			mod = Color(1.06, 1.05, 1.03)
		LshuSkinDraw.nine(self, t, nine, Rect2(Vector2.ZERO, size), size.y / float(t.get_height()), mod)


static func skin_button(b: Button, color: String) -> CandySkin:
	var empty := StyleBoxEmpty.new()
	for key: String in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(key, empty)
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var s := CandySkin.new()
	s.name = "CandySkin"
	s.skin = tex("btn_" + color)
	s.skin_pressed = tex("btn_%s_pressed" % color)
	s.nine = margins("btn_" + color)
	b.add_child(s)
	b.move_child(s, 0)
	return s
