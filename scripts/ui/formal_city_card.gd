extends Control
class_name FormalCityCard

## 正式城市卡（2026-09-26 v2，「旅行L叔」明信片风）。
## Carlos：「城市卡版面太丑……基于参考图重新优化」——按已认可的 L叔 界面概念图（07_unlock 明信片、02_picker 夹卡、
## 09_uikit 风格板）用 image 2.5 生成零件（art-src/cards-v2/kit → tools/cards/process_card_kit.py），在这里按固定版式拼：
##   卡纸 → 白边照片（插画 4:3）→ 缎带标题（城名）/ 眼镜徽章 / 黄色笔刷条（别称）
##   → 皮质小标签「简介」「风貌」+ 两段短文（presentation/card_text_v1.json，≤100 字）
##   → 花朵分隔线 → 邮票框（起始资源图标）+ 起始资源 / 地图属性 · 起始交通 + 邮戳（第 N 号城市卡）。
## 所有文字由代码绘制，素材里没有字。长篇图鉴（位置 / 历史人文 / 知名景点）仍在数据里，不上卡。

const TEMPLATE_PATH := "res://assets/game/ui/city_cards/v2/paper_1086x1448.png"
const KIT_DIR := "res://assets/game/ui/city_cards/v2/"
const ICON_DIR := "res://assets/game/ui/lshu_3d/icons/"
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const SILVER_ICON := "res://assets/game/ui/ui_hud_silver_ingot_v1.png"
const MISSING_COLOR := Color(0.35, 0.28, 0.22, 1.0)
const LORE_FALLBACK := "城市资料待补充"
const DESIGN_SIZE := Vector2(1086.0, 1448.0)

# 版式（卡纸 1086×1448 设计像素）
const RIBBON_RECT := Rect2(133, 14, 820, 220)
const TITLE_RECT := Rect2(250, 36, 586, 124)
const PHOTO_RECT := Rect2(115, 226, 856, 651)
const ART_RECT := Rect2(133, 244, 820, 615)          # 正好 4:3，插画不裁切
const BADGE_RECT := Rect2(84, 214, 150, 124)
const HIGHLIGHT_RECT := Rect2(213, 806, 660, 150)
const EPITHET_RECT := Rect2(303, 844, 480, 72)
const INTRO_TAG_RECT := Rect2(96, 976, 150, 58)
const INTRO_BADGE_RECT := Rect2(138, 976, 104, 58)
const INTRO_BODY_RECT := Rect2(262, 956, 728, 98)
const SCENERY_TAG_RECT := Rect2(96, 1092, 150, 58)
const SCENERY_BADGE_RECT := Rect2(138, 1092, 104, 58)
const SCENERY_BODY_RECT := Rect2(262, 1072, 728, 98)
const DIVIDER_RECT := Rect2(143, 1170, 800, 52)
const STAMP_RECT := Rect2(118, 1228, 126, 134)
const STAMP_FILL_RECT := Rect2(134, 1247, 94, 94)
const GRANT_ICON_RECT := Rect2(138, 1250, 88, 88)
const GRANT_TEXT_RECT := Rect2(262, 1230, 452, 54)
const FACTS_RECT := Rect2(262, 1286, 452, 38)
const META_RECT := Rect2(262, 1326, 452, 30)
const POSTMARK_RECT := Rect2(714, 1216, 212, 146)
# 资料 / 插画待校订：照片右上角一枚红色橡皮章（参考 02_picker 的「开场中」），完整说明放 tooltip
const BLOCKED_NOTE_RECT := Rect2(790, 262, 166, 50)
# 旧版节点保留给旧契约，但不再显示
const TRAVELLER_TITLE_RECT := Rect2(0, 0, 0, 0)
const POSITION_BADGE_RECT := Rect2(0, 0, 0, 0)
const POSITION_BODY_RECT := Rect2(0, 0, 0, 0)
const HISTORY_BADGE_RECT := Rect2(0, 0, 0, 0)
const HISTORY_BODY_RECT := Rect2(0, 0, 0, 0)
const SIGHTS_BADGE_RECT := Rect2(0, 0, 0, 0)
const SIGHTS_BODY_RECT := Rect2(0, 0, 0, 0)

var show_user_intro := false
var _user_intro_active := false
var _user_body_separator := ""
var _user_body_scrolls: Array[ScrollContainer] = []
var _content: Dictionary = {}
var _bound_city_id := ""
var _expanded := false

var _panel: Control
var _art_wrap: Control
var _art_back: ColorRect
var _art: TextureRect
var _art_missing: Label
var _template: TextureRect
var _photo: Panel
var _deco: Control
var _deco_nodes: Dictionary = {}     # name -> [TextureRect, Rect2]
var _root_vbox: Control
var _title: Label
var _epithet: Label
var _meta: Label
var _position_body: Label
var _history_body: Label
var _sights_body: Label
var _traveller_title: Label
var _facts_row: HBoxContainer
var _attribute: Label
var _transport: Label
var _facts_dot: Label
var _grant_icon: TextureRect
var _grant_text: Label
var _blocked_note: Label
var _section_titles: Array[Label] = []
var _intro_badge: Label
var _intro_body: Label
var _scenery_badge: Label
var _scenery_body: Label
var _attribute_suffix_transport := "骆驼"
var _stamp_fill: Panel
var _title_font_var: FontVariation


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	_apply_view_density()
	resized.connect(_on_card_resized)


func bind_resolved(resolved: Dictionary, content: Dictionary, draft_image: Texture2D = null) -> void:
	_build()
	clear_texture()
	_content = content
	if not bool(resolved.get("success", false)):
		_bind_failure(String(resolved.get("reason", "城市资料待补充")))
		_apply_view_density()
		return

	_bound_city_id = String(resolved.get("city_id", ""))
	_title.text = String(resolved.get("display_name", ""))
	_epithet.text = String(resolved.get("epithet", LORE_FALLBACK))
	_meta.text = "第 %d 号城市卡" % int(resolved.get("card_number", 0))
	# 缎带颜色随起始交通：骆驼城驼色，商船城牛仔蓝（与事件卡陆地 / 海上一致）
	var ship := String(resolved.get("starting_transport", "CAMEL")) == "SHIP"
	var ribbon: TextureRect = _deco_nodes["Ribbon"][0]
	var ribbon_path := KIT_DIR + ("ribbon_denim.png" if ship else "ribbon.png")
	if ResourceLoader.exists(ribbon_path):
		ribbon.texture = load(ribbon_path) as Texture2D
	_attribute_suffix_transport = FormalCardPresentationResolver.transport_label(String(resolved.get("starting_transport", "CAMEL")))
	_position_body.text = _lore_text(resolved, "position")
	_history_body.text = _lore_text(resolved, "history")
	_sights_body.text = _lore_text(resolved, "sights")
	_intro_body.text = _no_break(_lore_text(resolved, "intro"))
	_scenery_body.text = _no_break(_lore_text(resolved, "scenery"))
	_attribute.text = String(resolved.get("map_attribute", LORE_FALLBACK))
	_transport.text = "起始交通 · %s" % _attribute_suffix_transport

	var path := String(resolved.get("illustration_path", ""))
	if path != "" and ResourceLoader.exists(path):
		_art.texture = load(path) as Texture2D
		_art_missing.visible = false
	else:
		_art.texture = null
		_art_missing.visible = true

	_populate_grants(resolved.get("starting_grant", {}))
	var art_status := String(resolved.get("art_review_status", ""))
	var lore_status := String(resolved.get("lore_verification_status", ""))
	_blocked_note.visible = art_status == "legacy_style_alignment_pending" or lore_status == "CONTENT_BLOCKED"
	if lore_status == "CONTENT_BLOCKED":
		_blocked_note.text = "资料待校订"
		_blocked_note.tooltip_text = "城市资料待校订 · 规则信息不受影响"
	elif _blocked_note.visible:
		_blocked_note.text = "插画待对齐"
		_blocked_note.tooltip_text = "插画风格待对齐 · 仅预览"
	_paint_stamp_fill()
	if show_user_intro and not resolved.get("user_intro", {}).is_empty():
		_bind_user_intro(resolved.user_intro, draft_image)
	_apply_view_density()


func set_expanded(expanded: bool) -> void:
	_expanded = expanded
	if _panel != null:
		_apply_view_density()


func is_expanded_layout() -> bool:
	return _expanded


func clear_texture() -> void:
	_restore_default_body()
	if _panel != null:_panel.show()
	if _art != null:
		_art.texture = null
	_clear_grants()
	_bound_city_id = ""


func bound_city_id() -> String:
	return _bound_city_id


func has_texture() -> bool:
	return _art != null and _art.texture != null


func template_texture() -> Texture2D:
	return _template.texture if _template != null else null


func _build() -> void:
	if _panel != null:
		return
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0

	_panel = Control.new()
	_panel.name = "CardBody"
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	# 卡纸（不透明）在最底层；插画放进它上面的白边相框
	_template = _make_texture("EncyclopediaTemplate", TEMPLATE_PATH, TextureRect.STRETCH_SCALE)
	_template.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(_template)

	_photo = Panel.new()
	_photo.name = "PhotoFrame"
	_photo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var photo_box := StyleBoxFlat.new()
	photo_box.bg_color = Color("#FFFDF7")
	photo_box.set_corner_radius_all(10)
	photo_box.border_color = Color("#EADCC0")
	photo_box.set_border_width_all(1)
	photo_box.shadow_color = Color(0.35, 0.22, 0.12, 0.26)
	photo_box.shadow_size = 10
	photo_box.shadow_offset = Vector2(0, 4)
	_photo.add_theme_stylebox_override("panel", photo_box)
	_panel.add_child(_photo)

	_art_wrap = Control.new()
	_art_wrap.name = "ArtFrame"
	_art_wrap.clip_contents = true
	_art_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_art_wrap)

	_art_back = ColorRect.new()
	_art_back.name = "ArtBackground"
	_art_back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art_back.color = Color("D8C49A")
	_art_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art_wrap.add_child(_art_back)

	_art = TextureRect.new()
	_art.name = "Illustration"
	_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art_wrap.add_child(_art)

	_art_missing = Label.new()
	_art_missing.name = "ArtMissing"
	_art_missing.text = "插画缺失"
	_art_missing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_art_missing.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_art_missing.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art_missing.add_theme_color_override("font_color", MISSING_COLOR)
	_art_missing.visible = false
	_art_missing.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art_wrap.add_child(_art_missing)

	# 装饰零件层：盖在插画上（徽章、笔刷条会压住相框边）
	_deco = Control.new()
	_deco.name = "CardDeco"
	_deco.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_deco.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_deco)
	for spec in [
		["Ribbon", "ribbon.png", RIBBON_RECT],
		["GlassesBadge", "badge.png", BADGE_RECT],
		["Highlight", "highlight.png", HIGHLIGHT_RECT],
		["IntroTag", "tag_olive.png", INTRO_TAG_RECT],
		["SceneryTag", "tag_camel.png", SCENERY_TAG_RECT],
		["Divider", "divider.png", DIVIDER_RECT],
		["Stamp", "stamp.png", STAMP_RECT],
		["Postmark", "postmark.png", POSTMARK_RECT],
	]:
		var t := _make_texture(String(spec[0]), KIT_DIR + String(spec[1]), TextureRect.STRETCH_KEEP_ASPECT_CENTERED)
		_deco.add_child(t)
		_deco_nodes[spec[0]] = [t, spec[2]]
		if spec[0] == "Stamp":
			# 邮票里垫一块陆 / 海底色，白色、灰色货物图标才看得清
			_stamp_fill = Panel.new()
			_stamp_fill.name = "StampFill"
			_stamp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_deco.add_child(_stamp_fill)

	_root_vbox = Control.new()
	_root_vbox.name = "CardContents"
	_root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_vbox.offset_left = 4
	_root_vbox.offset_top = 4
	_root_vbox.offset_right = -4
	_root_vbox.offset_bottom = -4
	_root_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_root_vbox)

	_title = _make_label("CityName", HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	_root_vbox.add_child(_title)
	_epithet = _make_label("CityEpithet", HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	_root_vbox.add_child(_epithet)
	_meta = _make_label("CardMeta", HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_CENTER)
	_root_vbox.add_child(_meta)
	# 旧三段长文（隐藏）
	_position_body = _add_hidden_lore_pair("位置")
	_history_body = _add_hidden_lore_pair("历史人文")
	_sights_body = _add_hidden_lore_pair("知名景点")
	_intro_badge = _make_label("简介Heading", HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	_intro_badge.text = "简介"
	_root_vbox.add_child(_intro_badge)
	_intro_body = _make_label("简介Body", HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_CENTER, true)
	_root_vbox.add_child(_intro_body)
	_scenery_badge = _make_label("风貌Heading", HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	_scenery_badge.text = "风貌"
	_root_vbox.add_child(_scenery_badge)
	_scenery_body = _make_label("风貌Body", HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_CENTER, true)
	_root_vbox.add_child(_scenery_body)

	_traveller_title = _make_label("TravellerTitle", HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	_traveller_title.text = "旅人情报"
	_traveller_title.visible = false
	_root_vbox.add_child(_traveller_title)
	_facts_row = HBoxContainer.new()
	_facts_row.name = "TravelFacts"
	_facts_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	_facts_row.add_theme_constant_override("separation", 6)
	_facts_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root_vbox.add_child(_facts_row)
	_attribute = _make_label("MapAttribute", HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_CENTER)
	_facts_row.add_child(_attribute)
	_facts_dot = _make_label("FactDivider", HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	_facts_dot.text = "·"
	_facts_row.add_child(_facts_dot)
	_transport = _make_label("StartingTransport", HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_CENTER)
	_facts_row.add_child(_transport)
	_grant_icon = TextureRect.new()
	_grant_icon.name = "StartingGrantIcon"
	_grant_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_grant_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_grant_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_grant_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root_vbox.add_child(_grant_icon)
	_grant_text = _make_label("StartingGrantText", HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_CENTER)
	_root_vbox.add_child(_grant_text)
	_blocked_note = _make_label("ReviewNote", HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	_blocked_note.mouse_filter = Control.MOUSE_FILTER_PASS
	_blocked_note.visible = false
	_root_vbox.add_child(_blocked_note)


func _make_texture(node_name: String, path: String, stretch: TextureRect.StretchMode) -> TextureRect:
	var t := TextureRect.new()
	t.name = node_name
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = stretch
	t.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(path):
		t.texture = load(path) as Texture2D
	else:
		push_warning("FormalCityCard: 卡面零件缺失 %s" % path)
	return t


func _add_hidden_lore_pair(heading: String) -> Label:
	var badge := _make_label("%sHeading" % heading, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	badge.text = heading
	badge.visible = false
	_root_vbox.add_child(badge)
	_section_titles.append(badge)
	var body := _make_label("%sBody" % heading, HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_CENTER, true)
	body.visible = false
	_root_vbox.add_child(body)
	return body


func _make_label(
	name_value: String,
	horizontal: HorizontalAlignment,
	vertical: VerticalAlignment,
	wrap: bool = false
) -> Label:
	var label := Label.new()
	label.name = name_value
	label.horizontal_alignment = horizontal
	label.vertical_alignment = vertical
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wrap else TextServer.AUTOWRAP_OFF
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _bind_failure(reason: String) -> void:
	_bound_city_id = ""
	_title.text = "城市卡缺失"
	_epithet.text = LORE_FALLBACK
	_meta.text = reason
	_position_body.text = LORE_FALLBACK
	_history_body.text = LORE_FALLBACK
	_sights_body.text = LORE_FALLBACK
	_intro_body.text = LORE_FALLBACK
	_scenery_body.text = LORE_FALLBACK
	_attribute.text = "规则资料不可用"
	_transport.text = ""
	_art.texture = null
	_art_missing.visible = true
	_clear_grants()
	_blocked_note.visible = true
	_blocked_note.text = "资料校验失败"
	_blocked_note.tooltip_text = "正式资料校验失败 · 未回退 Demo 卡"


## 「L叔」不在行尾被拆成「L / 叔」：中间插一个不可见的连字符（U+2060 WORD JOINER）
static func _no_break(text: String) -> String:
	return text.replace("L叔", "L\u2060叔")


func _paint_stamp_fill() -> void:
	if _stamp_fill == null:
		return
	var box := StyleBoxFlat.new()
	box.bg_color = Color("#D5E1EE") if _attribute_suffix_transport == "商船" else Color("#EEDAB8")
	box.set_corner_radius_all(4)
	_stamp_fill.add_theme_stylebox_override("panel", box)


func _lore_text(resolved: Dictionary, key: String) -> String:
	var value := String(resolved.get(key, "")).strip_edges()
	return value if value != "" else LORE_FALLBACK


## 字号按卡高等比：设计稿 1448 高下的像素 × 实际卡高 / 1448（默认视图卡约 577 高 → 正文约 10.4 px）
func _px(design_px: float) -> int:
	return maxi(6, roundi(design_px * size.y / DESIGN_SIZE.y))


func _apply_view_density() -> void:
	if _panel == null or size.x <= 0.0 or size.y <= 0.0:
		return
	_layout_from_template()
	var title_font := Kit.font("title", 700)
	var body_font := Kit.font("body", 500)
	var strong_font := Kit.font("body", 700)
	if _title_font_var == null:
		_title_font_var = FontVariation.new()
		_title_font_var.base_font = title_font
	var n := _title.text.length()
	_title_font_var.spacing_glyph = _px(10) if n <= 2 else 0
	_style(_title, _title_font_var, _px(90 if n <= 3 else (82 if n == 4 else 74)), Kit.CREAM)
	_title.add_theme_color_override(
		"font_outline_color", Color("#2F4E78") if _attribute_suffix_transport == "商船" else Color("#6B3A1C")
	)
	_title.add_theme_constant_override("outline_size", maxi(2, _px(9)))
	_style(_epithet, Kit.font("title", 700), _px(38), Kit.SATCHEL_DEEP)
	_style(_meta, body_font, _px(23), Kit.INK_SOFT)
	for badge in [_intro_badge, _scenery_badge]:
		_style(badge, strong_font, _px(26), Kit.CREAM)
		badge.add_theme_color_override("font_outline_color", Color(Kit.INK, 0.35))
		badge.add_theme_constant_override("outline_size", maxi(1, _px(3)))
	for body in [_intro_body, _scenery_body]:
		_style(body, body_font, _px(28), Kit.INK)
		# 圆体自身行高约 1.9 倍字号：收紧到约 1.55 倍，两段之间的留白才看得出分段
		body.add_theme_constant_override("line_spacing", roundi(-3.0 * size.y / DESIGN_SIZE.y))
	_style(_grant_text, strong_font, _px(30), Kit.SATCHEL_DEEP)
	_style(_attribute, body_font, _px(25), Kit.INK_SOFT)
	_style(_facts_dot, body_font, _px(25), Kit.CAMEL)
	_style(_transport, body_font, _px(25), Kit.INK_SOFT)
	_style(_blocked_note, strong_font, _px(26), Color("#B4553F"))
	var stamp_box := StyleBoxFlat.new()
	stamp_box.bg_color = Color(1.0, 0.973, 0.933, 0.9)
	stamp_box.border_color = Color("#B4553F")
	stamp_box.set_border_width_all(1)
	stamp_box.set_corner_radius_all(maxi(2, _px(10)))
	_blocked_note.add_theme_stylebox_override("normal", stamp_box)
	_style(_art_missing, body_font, _px(26), MISSING_COLOR)
	if _user_intro_active:call_deferred("_fit_user_title")
	else:call_deferred("_fit_lore_labels")


func _style(label: Label, font: Font, font_size: int, color: Color) -> void:
	if label == null:
		return
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	if label != _title and label != _intro_badge and label != _scenery_badge:
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0))
		label.add_theme_constant_override("outline_size", 0)


func _layout_from_template() -> void:
	_set_card_rect(_photo, PHOTO_RECT, false)
	_set_card_rect(_art_wrap, ART_RECT, false)
	for key in _deco_nodes:
		_set_card_rect(_deco_nodes[key][0], _deco_nodes[key][1], false)
	_set_card_rect(_title, TITLE_RECT)
	_set_card_rect(_epithet, EPITHET_RECT)
	_set_card_rect(_meta, META_RECT)
	_set_card_rect(_intro_badge, INTRO_BADGE_RECT)
	_set_user_body_rect(0, _intro_body, INTRO_BODY_RECT)
	_set_card_rect(_scenery_badge, SCENERY_BADGE_RECT)
	_set_user_body_rect(1, _scenery_body, SCENERY_BODY_RECT)
	_set_card_rect(_facts_row, FACTS_RECT)
	_set_card_rect(_grant_icon, GRANT_ICON_RECT)
	_set_card_rect(_grant_text, GRANT_TEXT_RECT)
	_set_card_rect(_blocked_note, BLOCKED_NOTE_RECT)
	_blocked_note.pivot_offset = _blocked_note.size * 0.5
	_blocked_note.rotation_degrees = -6.0
	_set_card_rect(_stamp_fill, STAMP_FILL_RECT, false)


func _set_card_rect(node: Control, design_rect: Rect2, content_child: bool = true) -> void:
	if node == null:
		return
	var scale_xy := Vector2(size.x / DESIGN_SIZE.x, size.y / DESIGN_SIZE.y)
	var mapped := Rect2(design_rect.position * scale_xy, design_rect.size * scale_xy)
	if content_child:
		mapped.position -= _root_vbox.position
	node.position = mapped.position
	node.size = mapped.size
	node.set_meta("target_h", mapped.size.y)


func _fit_lore_labels() -> void:
	if _user_intro_active: return
	if not is_inside_tree() or not visible:
		return
	# 简介 / 风貌 各有固定阅读窗：放不下时只缩这一段字号，不改版式、不截断
	for label in [_intro_body, _scenery_body]:
		if label == null:
			continue
		var target := float(label.get_meta("target_h", label.size.y))
		var font_size: int = label.get_theme_font_size("font_size")
		while label.get_minimum_size().y > target + 0.5 and font_size > 6:
			font_size -= 1
			label.add_theme_font_size_override("font_size", font_size)
		label.size.y = target


func _on_card_resized() -> void:
	_apply_view_density()


func _clear_grants() -> void:
	if _grant_icon != null:
		_grant_icon.texture = null
	if _grant_text != null:
		_grant_text.text = ""


func _populate_grants(grant: Dictionary) -> void:
	_clear_grants()
	var entries: Array = grant.get("entries", []) if grant is Dictionary else []
	if entries.is_empty():
		_grant_text.text = "起始资源 · 无"
		return
	var entry: Dictionary = entries[0] if entries[0] is Dictionary else {}
	var kind := String(entry.get("resource_kind", ""))
	var rid := String(entry.get("resource_id", ""))
	var qty := int(entry.get("quantity", 0))
	var resource_name := "白银" if kind == "SILVER" else rid
	var goods: Dictionary = _content.get("goods", {})
	# 邮票框里放「旅行L叔」3D 图标；缺图时退回正式 HUD 图标
	# 白银用正式 HUD 的彩绘银锭（3D 图标库里的银是无材质灰模，放小了像一条灰船）
	var icon_path := ICON_DIR + rid + ".png"
	if kind == "SILVER":
		_grant_icon.texture = preload("res://scripts/lshu_ui/lshu_icons.gd").silver()
	elif ResourceLoader.exists(icon_path):
		_grant_icon.texture = load(icon_path) as Texture2D
	elif kind == "GOOD":
		_grant_icon.texture = preload("res://scripts/lshu_ui/lshu_icons.gd").good(rid, _content)
	if kind == "GOOD" and goods.has(rid):
		resource_name = String(goods[rid].get("display_name", rid))
	_grant_text.text = "起始资源 · %s ×%d" % [resource_name, qty]
	if entries.size() > 1:
		_grant_text.text += " 等 %d 项" % entries.size()


## Custom text/photo only: keep the original postcard shell, facts, grants and decorations.
func _bind_user_intro(card: Dictionary, draft_image: Texture2D) -> void:
	_user_intro_active = true
	_title.text = str(card.get("title", "")).substr(0, CustomMapCityIntro.TITLE_MAX)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.clip_text = true
	var body := CustomMapCityIntro.normalize_lines(str(card.get("description", ""))).substr(0, CustomMapCityIntro.BODY_MAX)
	var chunks: Array[String] = [body, ""]
	_user_body_separator = ""
	if body.contains("\n"):
		var lines := body.split("\n", true)
		var middle := maxi(1, ceili(lines.size() / 2.0))
		chunks = ["\n".join(lines.slice(0, middle)), "\n".join(lines.slice(middle))]
		_user_body_separator = "\n"
	elif body.length() > 80:
		var middle := body.length() / 2
		for offset in 20:
			var candidate := int(middle) + offset
			if candidate < body.length() - 1 and body[candidate] in ["。", "！", "？", "；"]:
				middle = candidate + 1; break
		chunks = [body.substr(0, int(middle)), body.substr(int(middle))]
	_intro_body.text = chunks[0]
	_scenery_body.text = chunks[1]
	if _user_body_scrolls.is_empty():
		for i in 2:
			var scroll := ScrollContainer.new()
			scroll.name = "CustomIntroReadingWindow" if i == 0 else "CustomSceneryReadingWindow"
			scroll.mouse_filter = Control.MOUSE_FILTER_PASS
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
			_root_vbox.add_child(scroll)
			_user_body_scrolls.append(scroll)
	for i in 2:
		var label: Label = [_intro_body, _scenery_body][i]
		label.reparent(_user_body_scrolls[i], false)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_user_body_scrolls[i].show()
		_user_body_scrolls[i].scroll_vertical = 0
	var image := draft_image
	if image == null and str(card.get("image", "")) != "": image = CustomMapLocalAssets.texture(card.image)
	if image != null:
		_art.texture = image
		_art_missing.hide()


func _restore_default_body() -> void:
	_user_intro_active = false
	_user_body_separator = ""
	if _title != null:
		_title.autowrap_mode = TextServer.AUTOWRAP_OFF
		_title.clip_text = false
	for i in _user_body_scrolls.size():
		var label: Label = [_intro_body, _scenery_body][i]
		if label.get_parent() != _root_vbox: label.reparent(_root_vbox, false)
		_user_body_scrolls[i].hide()


func _set_user_body_rect(index: int, label: Label, rect: Rect2) -> void:
	if not _user_intro_active:
		_set_card_rect(label, rect)
		return
	var scroll: ScrollContainer = _user_body_scrolls[index]
	_set_card_rect(scroll, rect)
	label.position = Vector2.ZERO
	label.custom_minimum_size.x = 0
	label.size.x = scroll.size.x


func _fit_user_title() -> void:
	if not is_inside_tree() or not _user_intro_active: return
	var target := float(_title.get_meta("target_h", _title.size.y))
	var font_size := _title.get_theme_font_size("font_size")
	var font := _title.get_theme_font("font")
	while font_size > 6 and (font.get_multiline_string_size(_title.text, HORIZONTAL_ALIGNMENT_CENTER, _title.size.x, font_size).y > target + 0.5 or _title.get_visible_line_count() < _title.get_line_count()):
		font_size -= 1
		_title.add_theme_font_size_override("font_size", font_size)
	_title.size.y = target


func user_description_text() -> String:
	return _intro_body.text + (_user_body_separator + _scenery_body.text if _scenery_body.text != "" or _user_body_separator != "" else "")
