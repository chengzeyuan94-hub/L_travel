class_name EventCard
extends Control

signal clicked(card: EventCard)

## Demo-only legacy. Formal 36 events must never be added here.
const EVENT_CONFIG := {
	"cn_ev_land_smooth": {
		"title": "驿道顺畅",
		"illustration": "res://assets/game/ui/event_cards/event_post_road_768.png",
		"instruction": "立即沿当前交通方式",
		"emphasis": "额外移动 0–2 步",
		"flavor": "商队沿驿道疾行，行程顺畅。",
		"sentiment": "positive",
	},
	"cn_ev_land_lose": {
		"title": "货物遗落",
		"illustration": "res://assets/game/ui/event_cards/event_lost_cargo_768.png",
		"instruction": "若货舱中有货物",
		"emphasis": "选择失去 1 件货物",
		"flavor": "颠簸的山路上，一件货物不慎跌落。",
		"sentiment": "negative",
	},
	"cn_ev_sea_gain": {
		"title": "海上拾遗",
		"illustration": "res://assets/game/ui/event_cards/event_sea_salvage_768.png",
		"instruction": "若货舱尚有空位",
		"emphasis": "获得 1 件本地特产",
		"flavor": "船员在甲板上意外拾得一件本地特产。",
		"sentiment": "positive",
	},
	"cn_ev_sea_wind": {
		"title": "顺风而行",
		"illustration": "res://assets/game/ui/event_cards/event_tailwind_768.png",
		"instruction": "立即沿当前交通方式",
		"emphasis": "额外移动 0–3 步",
		"flavor": "海面刮起顺风，商船加速前进。",
		"sentiment": "positive",
	},
}
## 正式卡面（2026-09-26 起）：「旅行L叔」明信片风——奶油缝线卡 + 铜夹 + 彩色标题签 + 白边插画框，
## 下方是原版效果原文（按吉凶上色）与几十字的成语释义。Demo 旧卡保持原样。
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const POSTCARD_BASE := "res://assets/game/ui/event_cards_v2/event_paper_768x1024.png"
const RIBBON_LAND := "res://assets/game/ui/city_cards/v2/ribbon.png"
const RIBBON_SEA := "res://assets/game/ui/city_cards/v2/ribbon_denim.png"
const DIVIDER_TEXTURE := "res://assets/game/ui/city_cards/v2/divider.png"
const POSTCARD_BACK := "res://assets/game/ui/event_cards_v2/event_card_back_map_768x1024.png"
const CLIP_TEXTURE := "res://assets/game/ui/lshu_title/clip.png"
const POSITIVE_INK := Color("#4E8A3C")
const NEGATIVE_INK := Color("#B4553F")
const LEGACY_RULESET_IDS := {
	"cn_demo_v1": true,
	"test_fixture": true,
}

var event_id := ""
var sentiment := "neutral"
var _interactive := false
var _content_override: Dictionary = {}
var _using_formal := false
var _legacy_frame: Texture2D
var _legacy_back: Texture2D
var _deck_type := ""
var _photo: Panel
var _title_tab: TextureRect
var _note_rule: TextureRect
var _idiom_note: Label
var _clip: TextureRect
var _signature: Label


func _ready() -> void:
	gui_input.connect(_on_gui_input)
	HudStyle.apply_heading(%Title, HudStyle.TOPBAR_GOLD_TEXT, 15)
	HudStyle.apply_font(%Instruction, HudStyle.FONT_BODY_MEDIUM, 11, HudStyle.INK_STRONG)
	HudStyle.apply_heading(%Emphasis, HudStyle.GOLD, 14)
	HudStyle.apply_font(%Flavor, HudStyle.FONT_BODY_MEDIUM, 10, HudStyle.INK_BODY)
	%Illustration.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_legacy_frame = $Front/Frame.texture
	_legacy_back = $Back.texture
	resized.connect(func() -> void:
		if _using_formal:
			call_deferred("_fit_formal_text"))
	# 明信片卡面节点一次建好（默认隐藏），反复 configure_front 不增删节点
	_build_postcard_nodes()
	for n in [_photo, _title_tab, _note_rule, _idiom_note, _clip, _signature]:
		n.visible = false
	show_back()


func set_content_override(content: Dictionary) -> void:
	_content_override = content.duplicate(true) if not content.is_empty() else {}


func clear_illustration() -> void:
	%Illustration.texture = null


func configure_front(id: String, content: Dictionary = {}) -> void:
	event_id = id
	clear_illustration()
	var use_content := content
	if use_content.is_empty():
		use_content = _content_override if not _content_override.is_empty() else GameState.content
	var ruleset_id := _ruleset_id(use_content)
	if ruleset_id == "lshu_configurable_v1":
		_using_formal = true
		var formal := FormalCardPresentationResolver.resolve_event(use_content, id)
		if bool(formal.get("success", false)):
			_apply_formal(formal)
		else:
			_apply_formal_failure(String(formal.get("reason", "正式事件资源缺失")))
		return
	if not LEGACY_RULESET_IDS.has(ruleset_id):
		# Unknown or malformed editions fail closed. They must not inherit Demo event
		# art/copy merely because an event ID happens to overlap the legacy table.
		_using_formal = true
		_apply_formal_failure(
			"未知规则包：%s" % (ruleset_id if ruleset_id != "" else "（缺失 ruleset_id）")
		)
		return
	# Demo/fixture content never probes the formal resolver. This keeps the expected
	# cn_ev_* path warning-free and makes edition ownership explicit.
	_using_formal = false
	_apply_legacy_layout()
	var config: Dictionary = EVENT_CONFIG.get(id, {})
	if config.is_empty():
		push_warning("EventCard: 未找到事件插画配置 %s" % id)
		%Title.text = "未知事件"
		%Instruction.text = ""
		%Emphasis.text = ""
		%Flavor.text = ""
		%Flavor.visible = false
		sentiment = "neutral"
		_apply_sentiment_colors()
		return
	var path := String(config.get("illustration", ""))
	%Illustration.texture = load(path) if ResourceLoader.exists(path) else null
	%Title.text = String(config.get("title", ""))
	%Instruction.text = String(config.get("instruction", ""))
	%Instruction.visible = true
	%Emphasis.text = String(config.get("emphasis", ""))
	%Emphasis.visible = not %Emphasis.text.is_empty()
	%Flavor.text = String(config.get("flavor", ""))
	%Flavor.visible = not %Flavor.text.is_empty()
	sentiment = String(config.get("sentiment", "positive"))
	_apply_sentiment_colors()


func _apply_formal(resolved: Dictionary) -> void:
	_apply_formal_layout()
	var path := String(resolved.get("illustration_path", ""))
	if path != "" and ResourceLoader.exists(path):
		%Illustration.texture = load(path) as Texture2D
	else:
		%Illustration.texture = null
	%Title.text = String(resolved.get("title", ""))
	_deck_type = String(resolved.get("deck_type", ""))
	_paint_title_tab()
	var original := String(resolved.get("original_effect_text", ""))
	%Instruction.text = original
	%Instruction.visible = true
	# 成语释义（presentation/card_text_v1.json）：卡面自己的说明文字，不是规则文本
	_idiom_note.text = String(resolved.get("idiom_explain", "")).replace("L叔", "L\u2060叔")
	_idiom_note.visible = not _idiom_note.text.is_empty()
	_note_rule.visible = _idiom_note.visible
	# The physical card face owns only its verified original wording. Normalized copy and
	# runtime effect_message belong to the overlay/game feedback outside this component.
	%Emphasis.text = ""
	%Emphasis.visible = false
	%Flavor.text = ""
	%Flavor.visible = false
	sentiment = String(resolved.get("sentiment", "neutral"))
	_apply_sentiment_colors()
	call_deferred("_fit_formal_text")


## 效果原文与成语释义各有固定窗口：放不下时只缩这一段的字号（原文 12→9，释义 9→7），不改版式、不截断
func _fit_formal_text() -> void:
	if not _using_formal or not is_inside_tree():
		return
	for spec in [[%Instruction, 12, 9], [_idiom_note, 9, 8]]:
		var label: Label = spec[0]
		if label == null or not label.visible:
			continue
		var fs: int = spec[1]
		label.add_theme_font_size_override("font_size", fs)
		var box := (label.anchor_bottom - label.anchor_top) * size.y
		while label.get_minimum_size().y > box + 0.5 and fs > int(spec[2]):
			fs -= 1
			label.add_theme_font_size_override("font_size", fs)


func _apply_formal_failure(reason: String) -> void:
	_apply_formal_layout()
	%Illustration.texture = null
	%Title.text = "正式事件资源缺失"
	_deck_type = ""
	_paint_title_tab()
	_idiom_note.text = ""
	_idiom_note.visible = false
	_note_rule.visible = false
	%Instruction.text = reason
	%Instruction.visible = true
	%Emphasis.text = ""
	%Emphasis.visible = false
	%Flavor.text = ""
	%Flavor.visible = false
	sentiment = "negative"
	_apply_sentiment_colors()


func _apply_formal_layout() -> void:
	_build_postcard_nodes()
	var front: Control = $Front
	var frame: TextureRect = $Front/Frame
	# 明信片底板是不透明的：放到最底层，插画叠在它上面的白边相框里
	if ResourceLoader.exists(POSTCARD_BASE):
		frame.texture = load(POSTCARD_BASE) as Texture2D
	frame.stretch_mode = TextureRect.STRETCH_SCALE
	front.move_child(frame, 0)
	front.move_child(_photo, 1)
	front.move_child(%Illustration, 2)
	if ResourceLoader.exists(POSTCARD_BACK):
		$Back.texture = load(POSTCARD_BACK) as Texture2D
	$Front/TitleBack.visible = false
	_title_tab.visible = true
	_clip.visible = false            # 缎带取代了夹子
	_signature.visible = false
	# 标题压在照片之上：缎带与标题移到最上层
	front.move_child(_title_tab, front.get_child_count() - 1)
	front.move_child(%Title, front.get_child_count() - 1)
	# 版式与城市卡同一套零件：缎带标题压在白边照片上沿，下方效果原文 · 花朵分隔线 · 成语释义
	_set_anchors(_title_tab, 0.05, 0.008, 0.95, 0.192)
	_set_anchors(%Title, 0.24, 0.040, 0.76, 0.122)
	_set_anchors(_photo, 0.083, 0.160, 0.917, 0.772)
	_set_anchors(%Illustration, 0.10, 0.176, 0.90, 0.756)
	_set_anchors(%Instruction, 0.07, 0.776, 0.93, 0.842)
	_set_anchors(_note_rule, 0.22, 0.840, 0.78, 0.868)
	_set_anchors(_idiom_note, 0.08, 0.866, 0.92, 0.962)
	_set_anchors(_clip, 0.42, -0.045, 0.58, 0.07)
	_set_anchors(_signature, 0.80, 0.962, 0.93, 0.992)
	%Instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	%Instruction.clip_text = false
	%Instruction.max_lines_visible = 2
	%Instruction.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	%Title.clip_text = true
	%Title.add_theme_font_override("font", Kit.font("title", 700))
	%Title.add_theme_font_size_override("font_size", 18)
	%Title.add_theme_color_override("font_color", Kit.CREAM)
	%Title.add_theme_constant_override("outline_size", 3)
	%Title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))


func _build_postcard_nodes() -> void:
	if _photo != null:
		return
	var front: Control = $Front
	_photo = Panel.new()
	_photo.name = "PhotoFrame"
	_photo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var photo_box := StyleBoxFlat.new()
	photo_box.bg_color = Color("#FFFDF7")
	photo_box.set_corner_radius_all(6)
	photo_box.shadow_color = Color(0.35, 0.22, 0.12, 0.28)
	photo_box.shadow_size = 5
	photo_box.shadow_offset = Vector2(0, 2)
	_photo.add_theme_stylebox_override("panel", photo_box)
	front.add_child(_photo)
	_title_tab = TextureRect.new()
	_title_tab.name = "TitleTab"
	_title_tab.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_title_tab.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_title_tab.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_title_tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	front.add_child(_title_tab)
	front.move_child(_title_tab, %Title.get_index())
	_note_rule = TextureRect.new()
	_note_rule.name = "IdiomRule"
	_note_rule.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_note_rule.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_note_rule.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_note_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(DIVIDER_TEXTURE):
		_note_rule.texture = load(DIVIDER_TEXTURE) as Texture2D
	front.add_child(_note_rule)
	_idiom_note = Label.new()
	_idiom_note.name = "IdiomNote"
	_idiom_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_idiom_note.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_idiom_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_idiom_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_idiom_note.add_theme_font_override("font", Kit.font("body", 500))
	_idiom_note.add_theme_font_size_override("font_size", 9)
	_idiom_note.add_theme_color_override("font_color", Color("#5E4A3C"))
	_idiom_note.add_theme_constant_override("line_spacing", 0)
	front.add_child(_idiom_note)
	_clip = TextureRect.new()
	_clip.name = "Clip"
	_clip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_clip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_clip.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if ResourceLoader.exists(CLIP_TEXTURE):
		_clip.texture = load(CLIP_TEXTURE) as Texture2D
	front.add_child(_clip)
	_signature = Label.new()
	_signature.name = "Signature"
	_signature.text = "— L"
	_signature.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_signature.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_signature.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_signature.add_theme_font_override("font", Kit.font("title", 500))
	_signature.add_theme_font_size_override("font_size", 8)
	_signature.add_theme_color_override("font_color", Color(Kit.INK_SOFT, 0.8))
	front.add_child(_signature)


func _paint_title_tab() -> void:
	if _title_tab == null:
		return
	var sea := _deck_type == "SEA"
	var path := RIBBON_SEA if sea else RIBBON_LAND
	if ResourceLoader.exists(path):
		_title_tab.texture = load(path) as Texture2D
	%Title.add_theme_color_override("font_outline_color", Color("#2F4E78") if sea else Color("#6B3A1C"))


static func _set_anchors(node: Control, l: float, t: float, r: float, b: float) -> void:
	node.anchor_left = l
	node.anchor_top = t
	node.anchor_right = r
	node.anchor_bottom = b
	node.offset_left = 0.0
	node.offset_top = 0.0
	node.offset_right = 0.0
	node.offset_bottom = 0.0


func _apply_legacy_layout() -> void:
	if _photo != null:
		$Front/Frame.texture = _legacy_frame
		# 旧卡框是透明窗框：必须盖在插画之上
		$Front.move_child($Front/Frame, %Illustration.get_index())
		$Back.texture = _legacy_back
		$Front/TitleBack.visible = true
		for n in [_photo, _title_tab, _note_rule, _idiom_note, _clip, _signature]:
			n.visible = false
		_set_anchors(%Illustration, 0.125, 0.18, 0.875, 0.75)
		_set_anchors(%Title, 0.22, 0.065, 0.78, 0.155)
		HudStyle.apply_heading(%Title, HudStyle.TOPBAR_GOLD_TEXT, 15)
	%Instruction.anchor_left = 0.10
	%Instruction.anchor_top = 0.765
	%Instruction.anchor_right = 0.90
	%Instruction.anchor_bottom = 0.82
	%Instruction.offset_left = 0.0
	%Instruction.offset_top = 0.0
	%Instruction.offset_right = 0.0
	%Instruction.offset_bottom = 0.0
	%Instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	%Instruction.clip_text = false
	%Instruction.max_lines_visible = 2
	%Instruction.vertical_alignment = VERTICAL_ALIGNMENT_CENTER


func _apply_sentiment_colors() -> void:
	if _using_formal:
		var ink := POSITIVE_INK if sentiment == "positive" else (NEGATIVE_INK if sentiment == "negative" else Kit.INK)
		%Instruction.add_theme_font_override("font", Kit.font("body", 700))
		%Instruction.add_theme_font_size_override("font_size", 12)
		%Instruction.add_theme_color_override("font_color", ink)
		%Instruction.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0))
		%Instruction.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
		return
	var color := HudStyle.INK_STRONG
	if sentiment == "negative":
		color = HudStyle.CINNABAR_TEXT
	elif sentiment == "positive":
		color = HudStyle.GOLD
	HudStyle.apply_heading(%Emphasis, color, 14)
	HudStyle.apply_font(%Instruction, HudStyle.FONT_BODY_MEDIUM, 11, color if sentiment != "neutral" else HudStyle.INK_STRONG)


func show_back() -> void:
	$Back.visible = true
	$Front.visible = false


func show_front() -> void:
	$Back.visible = false
	$Front.visible = true


func set_interactive(enabled: bool) -> void:
	_interactive = enabled
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if enabled else Control.CURSOR_ARROW


func using_formal() -> bool:
	return _using_formal


func _on_gui_input(event: InputEvent) -> void:
	if not _interactive:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit(self)
		accept_event()


static func config_for(id: String) -> Dictionary:
	return (EVENT_CONFIG.get(id, {}) as Dictionary).duplicate(true)


static func _ruleset_id(content: Dictionary) -> String:
	return String(content.get("ruleset", {}).get("ruleset_id", ""))
