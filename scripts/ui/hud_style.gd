class_name HudStyle
extends RefCounted

## TASK-HUD-VISUAL-PARITY-005：对局 HUD 唯一文字令牌（字体/字重/字号/颜色）。
## 禁止在业务 Label 上散落临时色值或默认字体。

const FONT_DISPLAY_BOLD: Font = preload("res://assets/game/ui/fonts/hud_display_bold.tres")
const FONT_HEADING_SEMIBOLD: Font = preload("res://assets/game/ui/fonts/hud_heading_semibold.tres")
const FONT_BODY_REGULAR: Font = preload("res://assets/game/ui/fonts/hud_body_regular.tres")
const FONT_BODY_MEDIUM: Font = preload("res://assets/game/ui/fonts/hud_body_medium.tres")

const INK_STRONG := Color("3E2A1E")
const INK_BODY := Color("5D4632")
const INK_WEAK := Color("7D5A3A")
const PARCHMENT_LIGHT := Color("F2E6C9")
const TOPBAR_GOLD_TEXT := Color("FFE2A6")
const CINNABAR_TEXT := Color("8C3A30")
const GOLD := Color("C58B32")
const SUCCESS := Color("3F7D63")
const FAILURE := Color("A54A3F")
const TEXT_OUTLINE_DARK := Color(0.12, 0.065, 0.025, 0.82)
const TEXT_SHADOW_WARM := Color(0.18, 0.10, 0.04, 0.26)

const SIZE_PLAQUE := 18
const SIZE_PUBLIC_SILVER := 26
const SIZE_CARGO_TITLE := 15
const SIZE_ACTION_HEADING := 18
const SIZE_ROUND_CAPTION := 11
const SIZE_PHASE := 18
const SIZE_BODY := 13
const SIZE_BUTTON := 15
const SIZE_CAPTION := 11
const SIZE_FOOTER := 11
const SIZE_AI_TITLE := 18
const SIZE_AI_SILVER := 16
const SIZE_AI_COUNT := 11
const SIZE_CITY_PLAQUE := 13
const SIZE_TRADE_COL := 13
const SIZE_TRADE_QTY := 11
const SIZE_TRADE_HELD := 11
const SIZE_TRADE_PREVIEW := 11
const SIZE_MOVE_BUDGET := 29
const SIZE_COUNT_BADGE := 11

const LINE_HEIGHT_BODY := 1.35
const LETTER_SPACING_DEFAULT := 0.0

const APPROVED_TEXT_COLORS: Array[Color] = [
	INK_STRONG,
	INK_BODY,
	INK_WEAK,
	PARCHMENT_LIGHT,
	TOPBAR_GOLD_TEXT,
	CINNABAR_TEXT,
	GOLD,
	SUCCESS,
	FAILURE,
	Color("FFF1BD"), # AI 数量小底上的浅金
]


static func apply_font(control: Control, font: Font, size_px: int, color: Color) -> void:
	if control == null or font == null:
		return
	control.add_theme_font_override("font", font)
	control.add_theme_font_size_override("font_size", size_px)
	control.add_theme_color_override("font_color", color)
	_apply_text_depth(control, color, size_px)


static func _apply_text_depth(control: Control, color: Color, size_px: int) -> void:
	# 手绘 UI 的文字不能像默认 Control 一样“浮”在贴图上。亮字用极细暗描边，
	# 羊皮纸上的深字只加 1px 暖阴影；保持字号与排版不变，避免低分辨率发糊。
	var light_text := (
		color.get_luminance() >= 0.58
		or color.is_equal_approx(GOLD)
		or color.is_equal_approx(CINNABAR_TEXT)
	)
	control.add_theme_color_override(
		"font_outline_color",
		TEXT_OUTLINE_DARK if light_text else Color(0, 0, 0, 0)
	)
	control.add_theme_constant_override("outline_size", 1 if light_text and size_px >= 11 else 0)
	control.add_theme_color_override(
		"font_shadow_color",
		Color(0, 0, 0, 0) if light_text else TEXT_SHADOW_WARM
	)
	control.add_theme_constant_override("shadow_offset_x", 0)
	control.add_theme_constant_override("shadow_offset_y", 1 if not light_text and size_px >= 12 else 0)
	control.add_theme_constant_override("shadow_outline_size", 0)


static func apply_display(control: Control, color: Color = TOPBAR_GOLD_TEXT, size_px: int = SIZE_PUBLIC_SILVER) -> void:
	apply_font(control, FONT_DISPLAY_BOLD, size_px, color)


static func apply_heading(control: Control, color: Color = INK_STRONG, size_px: int = SIZE_PHASE) -> void:
	apply_font(control, FONT_HEADING_SEMIBOLD, size_px, color)


static func apply_body(control: Control, color: Color = INK_WEAK, size_px: int = SIZE_BODY) -> void:
	apply_font(control, FONT_BODY_REGULAR, size_px, color)


static func apply_caption(control: Control, color: Color = INK_WEAK, size_px: int = SIZE_CAPTION) -> void:
	apply_font(control, FONT_BODY_REGULAR, size_px, color)


static func apply_button(button: BaseButton) -> void:
	apply_font(button, FONT_HEADING_SEMIBOLD, SIZE_BUTTON, PARCHMENT_LIGHT)
	button.add_theme_color_override("font_hover_color", PARCHMENT_LIGHT)
	button.add_theme_color_override("font_pressed_color", PARCHMENT_LIGHT)
	button.add_theme_color_override("font_disabled_color", INK_WEAK)
	button.add_theme_color_override("font_outline_color", TEXT_OUTLINE_DARK)
	button.add_theme_constant_override("outline_size", 1)


static func apply_link(link: LinkButton) -> void:
	apply_caption(link, INK_WEAK, SIZE_CAPTION)
	link.add_theme_color_override("font_hover_color", GOLD)
	link.add_theme_color_override("font_disabled_color", Color(INK_WEAK, 0.45))


static func is_approved_text_color(color: Color) -> bool:
	if color.a < 0.02:
		return true
	for approved in APPROVED_TEXT_COLORS:
		if (
			absf(color.r - approved.r) < 0.02
			and absf(color.g - approved.g) < 0.02
			and absf(color.b - approved.b) < 0.02
		):
			return true
	return false


static func uses_hud_font(control: Control) -> bool:
	if control == null:
		return false
	var font: Font = control.get_theme_font("font")
	if font == null:
		return false
	# SystemFont 资源路径或同字重实例均可。
	var path := str(font.resource_path)
	if (
		path.contains("hud_display_bold")
		or path.contains("hud_heading_semibold")
		or path.contains("hud_body_regular")
		or path.contains("hud_body_medium")
	):
		return true
	if font is SystemFont:
		var names: PackedStringArray = (font as SystemFont).font_names
		for n in names:
			var s := String(n)
			if (
				s.contains("PingFang")
				or s.contains("Hiragino")
				or s.contains("Heiti")
				or s.contains("STHeiti")
				or s.contains("Songti")
			):
				return true
	return false
