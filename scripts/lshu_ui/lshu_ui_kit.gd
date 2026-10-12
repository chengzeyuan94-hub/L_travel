extends RefCounted
## 「旅行L叔」全局界面风格：颜色、字体、按钮、面板。所有新界面都从这里取，不在各自脚本里写颜色和尺寸。
## 设计分辨率 1920×1080；界面放在一个按 k = min(宽/1920, 高/1080) 缩放的设计根节点里，所以这里的尺寸都是设计像素。
## 配色取自 L叔 本人：驼色卫衣、橄榄绿帽子和补丁、挎包棕、牛仔蓝、眼镜墨、腮红粉、嫩芽绿。
## 字体目前引用 macOS 系统字体（圆体、娃娃体），不随游戏打包；正式版等 Carlos 定字体后换成开源字体。

const DESIGN := Vector2(1920, 1080)

const CAMEL := Color("#C98E4E")
const OLIVE := Color("#8A8B5A")
const CREAM := Color("#FBF3E4")
const CREAM_DEEP := Color("#F1E4CB")
const SATCHEL := Color("#8A5A3B")
const SATCHEL_DEEP := Color("#6B4228")
const DENIM := Color("#7FA6D6")
const DENIM_DEEP := Color("#4E77A8")
const INK := Color("#3A2A22")
const INK_SOFT := Color("#7A6556")
const BLUSH := Color("#F2A7A0")
const SPROUT := Color("#7DBF6A")
const OCHRE := Color("#E3A34E")
const OCHRE_DEEP := Color("#A8692B")
const DISABLED := Color("#D9D0C2")
const DISABLED_DEEP := Color("#B4A898")

const ICON_DIR := "res://assets/game/ui/lshu_3d/icons/"

static var _fonts: Dictionary = {}

## kind: "body" 圆体 / "title" 娃娃体（标题字）
static func font(kind: String = "body", weight: int = 600) -> Font:
	var key: String = "%s_%d" % [kind, weight]
	if _fonts.has(key):
		return _fonts[key]
	var f := SystemFont.new()
	if kind == "title":
		f.font_names = PackedStringArray(["Wawati SC", "Yuanti SC", "PingFang SC"])
	else:
		f.font_names = PackedStringArray(["Yuanti SC", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans CJK SC", "Noto Sans SC", "Droid Sans Fallback"])
	f.font_weight = weight
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	var out: Font = f
	if weight >= 600:
		# 系统圆体的粗体不一定被找到：用 FontVariation 加粗，保证按钮和标题够“胖”
		var v := FontVariation.new()
		v.base_font = f
		v.variation_embolden = clampf(float(weight - 500) / 450.0, 0.0, 0.7)
		out = v
	_fonts[key] = out
	return out

static func icon(name: String) -> Texture2D:
	var p: String = ICON_DIR + name + ".png"
	if ResourceLoader.exists(p):
		return load(p) as Texture2D
	return null

## 圆胖糖果按钮的样式：底色 + 下方一道深色“底唇”；按下时底唇变薄、字往下沉。
static func candy_box(bg: Color, lip: Color, radius: int, lip_px: int, pad_x: int, pad_y: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = lip
	s.border_width_bottom = lip_px
	s.set_corner_radius_all(radius)
	s.corner_detail = 12
	s.content_margin_left = pad_x
	s.content_margin_right = pad_x
	s.content_margin_top = pad_y
	s.content_margin_bottom = pad_y
	s.shadow_color = Color(0.23, 0.14, 0.08, 0.22)
	s.shadow_size = 10
	s.shadow_offset = Vector2(0, 5)
	s.anti_aliasing = true
	return s

## variant: "primary" 驼黄 / "cream" 奶油 / "denim" 牛仔蓝
static func style_button(b: Button, variant: String, height: float, font_px: int) -> void:
	var bg: Color = OCHRE
	var lip: Color = OCHRE_DEEP
	var fg: Color = Color("#FFF8EC")
	if variant == "cream":
		bg = CREAM; lip = Color("#C9A77C"); fg = INK
	elif variant == "denim":
		bg = DENIM; lip = DENIM_DEEP; fg = Color("#FFFFFF")
	var r: int = int(height * 0.5)
	var lip_px: int = maxi(5, int(height * 0.085))
	var pad_x: int = int(height * 0.38)
	var pad_y: int = int(height * 0.12)
	var normal := candy_box(bg, lip, r, lip_px, pad_x, pad_y)
	var hover := candy_box(bg.lightened(0.08), lip, r, lip_px, pad_x, pad_y)
	var pressed := candy_box(bg.darkened(0.04), lip, r, 2, pad_x, pad_y)
	pressed.content_margin_top = pad_y + lip_px - 2
	pressed.shadow_size = 4
	pressed.shadow_offset = Vector2(0, 2)
	var disabled := candy_box(DISABLED, DISABLED_DEEP, r, lip_px, pad_x, pad_y)
	var focus := StyleBoxEmpty.new()
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_stylebox_override("focus", focus)
	b.add_theme_font_override("font", font("body", 700))
	b.add_theme_font_size_override("font_size", font_px)
	for key: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(key, fg)
	b.add_theme_color_override("font_disabled_color", Color("#8C8274"))
	if variant == "primary" or variant == "denim":
		b.add_theme_color_override("font_outline_color", lip.darkened(0.2))
		b.add_theme_constant_override("outline_size", maxi(2, int(font_px * 0.08)))
	b.add_theme_constant_override("icon_max_width", int(height * 0.62))
	b.add_theme_constant_override("h_separation", int(height * 0.16))
	b.custom_minimum_size.y = height
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

static func button(text: String, variant: String, height: float, font_px: int, icon_name: String = "") -> Button:
	var b := Button.new()
	b.text = text
	style_button(b, variant, height, font_px)
	if icon_name != "":
		b.icon = icon(icon_name)
		b.expand_icon = true
	return b

## 挎包盖面板：奶油底、挎包棕描边、大圆角；缝线由 StitchLayer 画。
static func satchel_box(radius: int = 34, border: int = 5, pad: int = 28, bg: Color = CREAM) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = SATCHEL
	s.set_border_width_all(border)
	s.set_corner_radius_all(radius)
	s.corner_detail = 12
	s.set_content_margin_all(pad)
	s.shadow_color = Color(0.2, 0.12, 0.06, 0.25)
	s.shadow_size = 18
	s.shadow_offset = Vector2(0, 8)
	s.anti_aliasing = true
	return s

## 胶囊信息条（半透明奶油）
static func pill_box(pad_x: int = 26, pad_y: int = 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(CREAM.r, CREAM.g, CREAM.b, 0.93)
	s.set_corner_radius_all(999)
	s.corner_detail = 12
	s.content_margin_left = pad_x
	s.content_margin_right = pad_x
	s.content_margin_top = pad_y
	s.content_margin_bottom = pad_y
	s.shadow_color = Color(0.2, 0.12, 0.06, 0.2)
	s.shadow_size = 10
	s.shadow_offset = Vector2(0, 4)
	s.anti_aliasing = true
	return s

static func label(text: String, px: int, color: Color = INK, kind: String = "body", weight: int = 600) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font(kind, weight))
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	return l

## 标题式大字：白字 + 深色描边 + 投影
static func title_label(text: String, px: int, fill: Color, outline: Color) -> Label:
	var l := label(text, px, fill, "title", 700)
	l.add_theme_color_override("font_outline_color", outline)
	l.add_theme_constant_override("outline_size", int(px * 0.12))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.28))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", int(px * 0.06))
	l.add_theme_constant_override("shadow_outline_size", int(px * 0.14))
	return l
