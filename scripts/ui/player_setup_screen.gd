extends Control

## 一页式 1v1 设置：默认正式 16 城；Demo 仅保留显式测试入口。
## 进入即发城市卡，名称/颜色只更新显示属性，绝不重新发牌。

signal transport_confirmed(human_transport: int)
signal back_requested

const AI_DISPLAY_NAME := "电脑商旅"
const HUMAN_DEFAULT_NAME := "玩家"
const MAX_NAME_LEN := 12
const SEAL_TEXTURE := preload("res://assets/game/ui/trade/seal_badge_blank_hd.png")
const SILVER_TEXTURE := preload("res://assets/game/ui/ui_hud_silver_ingot_small_v1.png")
const CAMEL_SHEET := preload("res://assets/game/pieces/camel/camel_s_walk_8f.png")
const SHIP_SHEET := preload("res://assets/game/pieces/ship/ship_s_sail_8f.png")
const MAIN_ACTIVE := preload("res://assets/game/ui/trade/main_button_active_blank_hd.png")
const MAIN_HOVER := preload("res://assets/game/ui/trade/main_button_hover_blank_hd.png")
const MAIN_PRESSED := preload("res://assets/game/ui/trade/main_button_pressed_blank_hd.png")
const MAIN_DISABLED := preload("res://assets/game/ui/trade/main_button_disabled_blank_hd.png")

const CITY_ILLUSTRATIONS := {
	"dunhuang": "res://assets/game/ui/city_cards/city_illustration_dunhuang_1448x1086.png",
	"yumenguan": "res://assets/game/ui/city_cards/city_illustration_yumenguan_1448x1086.png",
	"changan": "res://assets/game/ui/city_cards/city_illustration_changan_1448x1086.png",
	"luoyang": "res://assets/game/ui/city_cards/city_illustration_luoyang_1448x1086.png",
	"hangzhou": "res://assets/game/ui/city_cards/city_illustration_hangzhou_1448x1086.png",
	"quanzhou": "res://assets/game/ui/city_cards/city_illustration_quanzhou_1448x1086.png",
	"guangzhou": "res://assets/game/ui/city_cards/city_illustration_guangzhou_1448x1086.png",
}

var _colors: Array = []
var _selected_color_index := 0
var _color_buttons: Array[Button] = []
var _allowed_transports: Array = [GameData.Transport.CAMEL]
var _selected_transport: int = GameData.Transport.CAMEL
var _last_configs: Array = []
var _prepare_result: Dictionary = {}
var _prepared := false
var _launching := false
var _session_mode := "FORMAL"
var _content: Dictionary = {}
var _starting_transport_locked := false
## 电脑商旅难度（AIDifficulty）；本次运行内记住上次的选择
static var _remembered_difficulty := AIDifficulty.DEFAULT
var _difficulty := AIDifficulty.DEFAULT
var _difficulty_buttons: Dictionary = {}     # id -> Button
var _difficulty_hint: Label


func _ready() -> void:
	%BackButton.pressed.connect(_on_back_pressed)
	%StartButton.pressed.connect(_on_start_pressed)
	%CamelButton.pressed.connect(func(): _select_transport(GameData.Transport.CAMEL))
	%ShipButton.pressed.connect(func(): _select_transport(GameData.Transport.SHIP))
	%NameEdit.text_changed.connect(_on_name_changed)
	%NameEdit.text = HUMAN_DEFAULT_NAME
	_content = GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	_colors = GameData.get_player_colors(_content)
	_build_color_buttons()
	_build_difficulty_row()
	_build_transport_button(%CamelButton, CAMEL_SHEET, "骆驼")
	_build_transport_button(%ShipButton, SHIP_SHEET, "商船")
	_apply_static_style()
	_refresh_start_enabled()


func begin_setup(seed: int = -1, session_mode: String = "FORMAL") -> Dictionary:
	if session_mode != "FORMAL" and session_mode != "DEMO_1V1":
		var invalid := {"success": false, "message": "设置页不支持会话模式：%s" % session_mode}
		show_start_error(String(invalid["message"]))
		return invalid
	_session_mode = session_mode
	_content = GameData.load_ruleset(
		GameData.FORMAL_RULESET_DIR if _session_mode == "FORMAL" else GameData.DEMO_RULESET_DIR
	)
	_colors = GameData.get_player_colors(_content)
	_build_color_buttons()
	_launching = false
	_prepared = false
	_prepare_result = {}
	_starting_transport_locked = false
	_selected_transport = GameData.Transport.CAMEL
	%NameEdit.text = HUMAN_DEFAULT_NAME
	_selected_color_index = 0
	_refresh_color_buttons()
	_difficulty = _remembered_difficulty
	_refresh_difficulty_buttons()
	var configs := collect_configs()
	var result := SetupSystem.prepare_new_game(_content, configs, seed, _session_mode, _expansion_options())
	if not bool(result.get("success", false)):
		show_start_error(String(result.get("message", "无法准备开局内容。")))
		return result
	_prepared = true
	_prepare_result = result.duplicate(true)
	_last_configs = configs.duplicate(true)
	_allowed_transports = result.get("allowed_transports", [GameData.Transport.CAMEL]).duplicate()
	_starting_transport_locked = bool(result.get("starting_transport_locked", false))
	_selected_transport = int(result.get("starting_transport", GameData.Transport.CAMEL))
	$TopBar/ContentCaption.text = (
		"丝路十六城 · 正式规则 · 玩家 VS 电脑"
		if _session_mode == "FORMAL"
		else "中国七城 · 轻量演示内容"
	)
	_refresh_prepare_preview()
	_apply_display_config()
	_refresh_start_enabled()
	return result


## 旧七城测试必须显式调用，正式“开始新游戏”绝不自动回退 Demo。
func begin_demo_setup(seed: int = -1) -> Dictionary:
	return begin_setup(seed, "DEMO_1V1")


## 开局用的扩展包选项（null = 原版）。原设置页没有扩展包开关；L叔 设置页覆写它，读「L叔的趣味事件」开关。
func _expansion_options() -> Variant:
	return null


func _build_color_buttons() -> void:
	for child in %ColorRow.get_children():
		child.free()
	_color_buttons.clear()
	for i in _colors.size():
		var color_data: Dictionary = _colors[i]
		var button := Button.new()
		button.name = "Color_%s" % String(color_data.get("id", i))
		button.custom_minimum_size = Vector2(64, 48)
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_stylebox_override("normal", _empty_style())
		button.add_theme_stylebox_override("hover", _empty_style())
		button.add_theme_stylebox_override("pressed", _empty_style())
		button.add_theme_stylebox_override("focus", _empty_style())
		var seal := TextureRect.new()
		seal.name = "Seal"
		seal.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		seal.position = Vector2(-24, -17)
		seal.size = Vector2(48, 34)
		seal.texture = SEAL_TEXTURE
		seal.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		seal.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		seal.modulate = Color(String(color_data.get("color", "#FFFFFF")))
		seal.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(seal)
		var label := Label.new()
		label.name = "ColorName"
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.text = String(color_data.get("display_name", ""))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		HudStyle.apply_heading(label, HudStyle.PARCHMENT_LIGHT, 13)
		button.add_child(label)
		var idx := i
		button.pressed.connect(func(): _select_color(idx))
		%ColorRow.add_child(button)
		_color_buttons.append(button)
	_refresh_color_buttons()


## 对手难度：轻装启程（7 岁）/ 山海独旅（12 岁）/ 万里商途（16 岁）
func _build_difficulty_row() -> void:
	var column: VBoxContainer = %AIColorLabel.get_parent()
	var caption := Label.new()
	caption.name = "DifficultyCaption"
	caption.text = "对手难度"
	HudStyle.apply_caption(caption, HudStyle.INK_WEAK, 11)
	column.add_child(caption)
	var row := HBoxContainer.new()
	row.name = "DifficultyRow"
	row.add_theme_constant_override("separation", 8)
	column.add_child(row)
	for id in AIDifficulty.ORDER:
		var button := Button.new()
		button.name = "Difficulty_%s" % id
		button.custom_minimum_size = Vector2(112, 50)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		var box := VBoxContainer.new()
		box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		box.add_theme_constant_override("separation", 0)
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(box)
		var title := Label.new()
		title.name = "Title"
		title.text = AIDifficulty.display_name(id)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		HudStyle.apply_heading(title, HudStyle.INK_STRONG, 14)
		box.add_child(title)
		var age := Label.new()
		age.name = "Age"
		age.text = AIDifficulty.age_text(id)
		age.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		age.mouse_filter = Control.MOUSE_FILTER_IGNORE
		HudStyle.apply_caption(age, HudStyle.INK_WEAK, 11)
		box.add_child(age)
		var pick: String = id
		button.pressed.connect(func(): _select_difficulty(pick))
		button.mouse_entered.connect(_refresh_difficulty_buttons)
		button.mouse_exited.connect(_refresh_difficulty_buttons)
		row.add_child(button)
		_difficulty_buttons[id] = button
	_difficulty_hint = Label.new()
	_difficulty_hint.name = "DifficultyHint"
	HudStyle.apply_caption(_difficulty_hint, HudStyle.INK_WEAK, 11)
	column.add_child(_difficulty_hint)
	_refresh_difficulty_buttons()


func _select_difficulty(id: String) -> void:
	_difficulty = AIDifficulty.normalize(id)
	_remembered_difficulty = _difficulty
	_refresh_difficulty_buttons()
	if _prepared:
		var result := SetupSystem.update_prepared_ai_difficulty(_difficulty)
		if bool(result.get("success", false)):
			_last_configs = collect_configs().duplicate(true)


func _refresh_difficulty_buttons() -> void:
	for id in _difficulty_buttons:
		var button: Button = _difficulty_buttons[id]
		var selected: bool = id == _difficulty
		var hovered := button.is_hovered()
		button.button_pressed = selected
		var style := _choice_style(selected, hovered)
		for state in ["normal", "hover", "pressed", "focus"]:
			button.add_theme_stylebox_override(state, style)
		(button.find_child("Title", true, false) as Label).add_theme_color_override("font_color", HudStyle.CINNABAR_TEXT if selected else HudStyle.INK_STRONG)
	if _difficulty_hint != null:
		_difficulty_hint.text = "电脑水平：%s · %s" % [AIDifficulty.age_text(_difficulty), String(AIDifficulty.INFO[_difficulty]["blurb"])]


func get_ai_difficulty() -> String:
	return _difficulty


func _select_color(index: int) -> void:
	_selected_color_index = clampi(index, 0, maxi(_colors.size() - 1, 0))
	_refresh_color_buttons()
	_refresh_ai_card()
	if _prepared:
		_apply_display_config()


func _refresh_color_buttons() -> void:
	for i in _color_buttons.size():
		var selected := i == _selected_color_index
		var button := _color_buttons[i]
		button.button_pressed = selected
		button.position.y = 2.0 if selected else 0.0
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0, 0, 0, 0)
		style.border_color = HudStyle.GOLD
		style.set_border_width_all(2 if selected else 0)
		style.set_corner_radius_all(4)
		button.add_theme_stylebox_override("pressed", style)
		button.add_theme_stylebox_override("normal", style if selected else _empty_style())


func _ai_color_index() -> int:
	for i in _colors.size():
		if i != _selected_color_index:
			return i
	return 0


func _refresh_ai_card() -> void:
	if _colors.is_empty():
		%AIColorLabel.text = "电脑商旅：—"
		return
	var ai_color: Dictionary = _colors[_ai_color_index()]
	%AIColorLabel.text = "电脑商旅：%s色 · 自动避让" % String(ai_color.get("display_name", ""))


func _on_name_changed(_text: String) -> void:
	if _prepared:
		_apply_display_config()
	_refresh_start_enabled()


func _normalized_name() -> String:
	var value: String = %NameEdit.text.strip_edges()
	return HUMAN_DEFAULT_NAME if value.is_empty() else value.left(MAX_NAME_LEN)


func collect_configs() -> Array:
	if _colors.is_empty():
		return []
	var human_color: Dictionary = _colors[_selected_color_index]
	var ai_color: Dictionary = _colors[_ai_color_index()]
	return [
		{
			"display_name": _normalized_name(),
			"color_id": String(human_color["id"]),
			"controller_type": "LOCAL_HUMAN",
		},
		{
			"display_name": AI_DISPLAY_NAME,
			"color_id": String(ai_color["id"]),
			"controller_type": "AI",
			"ai_difficulty": _difficulty,
		},
	]


func _apply_display_config() -> bool:
	if not _prepared or _colors.is_empty():
		return false
	var configs := collect_configs()
	var result := SetupSystem.update_prepared_display_config(
		String(configs[0]["display_name"]),
		String(configs[0]["color_id"]),
		String(configs[1]["color_id"])
	)
	if bool(result.get("success", false)):
		_last_configs = configs.duplicate(true)
		return true
	show_start_error(String(result.get("message", "无法更新商旅信息。")))
	return false


func _refresh_prepare_preview() -> void:
	var city_id := String(_prepare_result.get("home_city_id", ""))
	var city_path := ""
	if _session_mode == "FORMAL":
		var resolved := FormalCardPresentationResolver.resolve_city_card(_content, city_id)
		if bool(resolved.get("success", false)):
			city_path = String(resolved.get("illustration_path", ""))
	else:
		city_path = String(CITY_ILLUSTRATIONS.get(city_id, ""))
	%CityIllustration.texture = load(city_path) if not city_path.is_empty() and ResourceLoader.exists(city_path) else null
	%HomeCityLabel.text = "起始城市：%s" % String(_prepare_result.get("home_city_name", "—"))
	for child in %StartingGrantRow.get_children():
		child.free()
	var caption := Label.new()
	caption.text = "起始资源："
	HudStyle.apply_body(caption, HudStyle.INK_BODY, 13)
	%StartingGrantRow.add_child(caption)
	var grant: Array = _prepare_result.get("starting_grant", [])
	if grant.is_empty():
		var none := Label.new()
		none.text = "无"
		HudStyle.apply_body(none, HudStyle.INK_WEAK, 13)
		%StartingGrantRow.add_child(none)
	for entry in grant:
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(30, 30)
		icon.texture = _entry_texture(entry)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		%StartingGrantRow.add_child(icon)
		var qty := Label.new()
		qty.text = "×%d" % int(entry.get("quantity", 0))
		HudStyle.apply_heading(qty, HudStyle.INK_STRONG, 13)
		%StartingGrantRow.add_child(qty)
	var camel_allowed := GameData.Transport.CAMEL in _allowed_transports
	var ship_allowed := GameData.Transport.SHIP in _allowed_transports
	%CamelButton.disabled = not camel_allowed or _starting_transport_locked
	%ShipButton.visible = true
	%ShipButton.disabled = not ship_allowed or _starting_transport_locked
	%CamelButton.modulate = Color(1, 1, 1, 1 if camel_allowed else 0.45)
	%ShipButton.modulate = Color(1, 1, 1, 1 if ship_allowed else 0.45)
	if _starting_transport_locked:
		%TransportHint.text = "城市卡指定起始交通：%s" % (
			"商船" if _selected_transport == GameData.Transport.SHIP else "骆驼"
		)
	else:
		%TransportHint.text = "港口城市可选择骆驼或商船" if ship_allowed else "内陆城市只能选择骆驼"
	_select_transport(_selected_transport)


## 起始资源图标：和对局里的市集面板同一套 L叔 图标（scripts/lshu_ui/lshu_icons.gd）
func _entry_texture(entry: Dictionary) -> Texture2D:
	var content: Dictionary = GameState.content if not GameState.content.is_empty() else _content
	return preload("res://scripts/lshu_ui/lshu_icons.gd").entry(entry, content)


func _select_transport(transport: int) -> void:
	if _starting_transport_locked and transport != _selected_transport:
		return
	if transport not in _allowed_transports:
		return
	_selected_transport = transport
	%CamelButton.button_pressed = transport == GameData.Transport.CAMEL
	%ShipButton.button_pressed = transport == GameData.Transport.SHIP
	_refresh_transport_styles()


func _build_transport_button(button: Button, sheet: Texture2D, title: String) -> void:
	button.text = ""
	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = Rect2(0, 0, 256, 256)
	var icon := TextureRect.new()
	icon.name = "PieceIcon"
	icon.position = Vector2(15, 3)
	icon.size = Vector2(66, 66)
	icon.texture = atlas
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(icon)
	var label := Label.new()
	label.position = Vector2(0, 68)
	label.size = Vector2(96, 22)
	label.text = title
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	HudStyle.apply_heading(label, HudStyle.INK_STRONG, 13)
	button.add_child(label)


func _refresh_transport_styles() -> void:
	for pair in [
		[%CamelButton, GameData.Transport.CAMEL],
		[%ShipButton, GameData.Transport.SHIP],
	]:
		var button: Button = pair[0]
		var selected := int(pair[1]) == _selected_transport
		button.add_theme_stylebox_override("normal", _choice_style(selected, false))
		button.add_theme_stylebox_override("hover", _choice_style(selected, true))
		button.add_theme_stylebox_override("pressed", _choice_style(true, true))
		button.add_theme_stylebox_override("disabled", _choice_style(selected, false))


func _on_start_pressed() -> void:
	if %StartButton.disabled or _launching or not _prepared:
		return
	if not _apply_display_config():
		return
	_launching = true
	%StartButton.disabled = true
	transport_confirmed.emit(_selected_transport)


func _on_back_pressed() -> void:
	_launching = false
	_prepared = false
	_prepare_result = {}
	GameState.reset_session()
	back_requested.emit()


func _refresh_start_enabled() -> void:
	var validation: Dictionary = (
		GameData.validate_content(_content)
		if _session_mode == "FORMAL"
		else GameData.validate_demo_content(_content)
	)
	var content_ok := bool(validation.get("valid", false))
	if content_ok:
		%GateLabel.text = ""
	else:
		%GateLabel.text = "%s内容不完整：%s" % [
			"正式" if _session_mode == "FORMAL" else "演示",
			"; ".join(validation.get("missing", [])),
		]
	HudStyle.apply_caption(%GateLabel, HudStyle.FAILURE if not content_ok else HudStyle.INK_WEAK, 11)
	%StartButton.disabled = not content_ok or _colors.is_empty() or (_prepared and _launching) or not _prepared


func show_start_error(message: String) -> void:
	_launching = false
	%GateLabel.text = message
	HudStyle.apply_caption(%GateLabel, HudStyle.FAILURE, 11)
	%StartButton.disabled = true


func get_last_configs() -> Array:
	return _last_configs.duplicate(true)


func get_prepare_result() -> Dictionary:
	return _prepare_result.duplicate(true)


func get_session_mode() -> String:
	return _session_mode


func _apply_static_style() -> void:
	HudStyle.apply_heading($TopBar/TitlePlaque/TitleLabel, HudStyle.PARCHMENT_LIGHT, 18)
	HudStyle.apply_caption($TopBar/ContentCaption, HudStyle.TOPBAR_GOLD_TEXT, 12)
	HudStyle.apply_caption(%BackButton, HudStyle.PARCHMENT_LIGHT, 11)
	%BackButton.add_theme_color_override("font_hover_color", HudStyle.GOLD)
	for card in [%HumanCard, %InfoCard]:
		card.add_theme_stylebox_override("panel", _card_style())
	for heading in [
		$BodyMargin/PageColumn/CardRow/HumanCard/Margin/Column/Heading,
		$BodyMargin/PageColumn/CardRow/InfoCard/Margin/Column/Heading,
	]:
		HudStyle.apply_heading(heading, HudStyle.INK_STRONG, 19)
	for caption in [
		$BodyMargin/PageColumn/CardRow/HumanCard/Margin/Column/NameCaption,
		$BodyMargin/PageColumn/CardRow/HumanCard/Margin/Column/ColorCaption,
		%OpponentLabel,
		%AIColorLabel,
		%TransportHint,
	]:
		HudStyle.apply_caption(caption, HudStyle.INK_WEAK, 11)
	HudStyle.apply_heading(%HomeCityLabel, HudStyle.CINNABAR_TEXT, 15)
	var input_style := StyleBoxFlat.new()
	input_style.bg_color = Color("F2E6C9")
	input_style.border_color = Color("4A3220")
	input_style.set_border_width_all(1)
	input_style.set_corner_radius_all(2)
	input_style.content_margin_left = 10
	input_style.content_margin_right = 10
	input_style.shadow_color = Color(0.16, 0.09, 0.04, 0.14)
	input_style.shadow_size = 2
	%NameEdit.add_theme_stylebox_override("normal", input_style)
	var focus_style := input_style.duplicate() as StyleBoxFlat
	focus_style.border_color = HudStyle.GOLD
	focus_style.set_border_width_all(2)
	%NameEdit.add_theme_stylebox_override("focus", focus_style)
	HudStyle.apply_body(%NameEdit, HudStyle.INK_STRONG, 13)
	%StartButton.add_theme_stylebox_override("normal", _texture_style(MAIN_ACTIVE))
	%StartButton.add_theme_stylebox_override("hover", _texture_style(MAIN_HOVER))
	%StartButton.add_theme_stylebox_override("pressed", _texture_style(MAIN_PRESSED))
	%StartButton.add_theme_stylebox_override("disabled", _texture_style(MAIN_DISABLED))
	%StartButton.add_theme_stylebox_override("focus", _texture_style(MAIN_HOVER))
	HudStyle.apply_button(%StartButton)
	_refresh_ai_card()
	_refresh_transport_styles()


func _card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("F0DEB5", 0.96)
	style.border_color = Color("9A682B", 0.82)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.shadow_color = Color(0.12, 0.065, 0.025, 0.30)
	style.shadow_size = 8
	style.shadow_offset = Vector2(0, 3)
	style.content_margin_left = 2
	style.content_margin_top = 2
	style.content_margin_right = 2
	style.content_margin_bottom = 2
	return style


func _choice_style(selected: bool, hovered: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("F2E6C9", 0.96 if not hovered else 1.0)
	style.border_color = HudStyle.GOLD if selected or hovered else Color("7D5A3A", 0.7)
	style.set_border_width_all(2 if selected else 1)
	style.set_corner_radius_all(5)
	style.shadow_color = Color(0.12, 0.065, 0.025, 0.22 if selected else 0.12)
	style.shadow_size = 4 if selected else 2
	style.shadow_offset = Vector2(0, 2)
	return style


func _texture_style(texture: Texture2D) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	style.texture = texture
	style.texture_margin_left = 24
	style.texture_margin_top = 12
	style.texture_margin_right = 24
	style.texture_margin_bottom = 12
	return style


func _empty_style() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()
