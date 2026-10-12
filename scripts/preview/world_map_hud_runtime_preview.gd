extends Control
class_name WorldMapHudRuntimePreview

## TASK-WORLD-MAP-HUD-CAMERA-003: formal 16-city map + fixed HUD + half-view camera.
## Presentation-only. Does not call SetupSystem / TradeSystem / EventSystem.

const TOPBAR_TEX := "res://assets/game/ui/ui_hud_topbar_wood_v1.png"
const SCROLL_TEX := "res://assets/game/ui/ui_hud_scroll_v1.png"
const AI_CARD_TEX := "res://assets/game/ui/ui_hud_ai_card_v1.png"
const SILVER_TEX := "res://assets/game/ui/ui_hud_silver_ingot_v1.png"
const ACTION_PLAQUE_TEX := "res://assets/game/ui/ui_hud_current_action_plaque_v1.png"
const PRIMARY_BUTTON_TEX := "res://assets/game/ui/ui_hud_primary_button_v1.png"
const CARGO_SLOT_TEX := "res://assets/game/ui/trade/cargo_slot_normal_hd.png"
const DIVIDER_TEX := "res://assets/game/ui/trade/divider_horizontal_ornate_hd.png"
const GOOD_TEXTURES := {
	"jade": "res://assets/game/ui/ui_hud_good_jade_v1.png",
	"porcelain": "res://assets/game/ui/ui_hud_good_porcelain_v1.png",
	"silk": "res://assets/game/ui/ui_hud_good_silk_v1.png",
	"tea": "res://assets/game/ui/ui_hud_good_tea_v1.png",
}
const TOPBAR_H := 64.0
const SCROLL_MIN := 286.0
const SCROLL_MAX := 344.0
const SCROLL_SOURCE_SIZE := Vector2(1024.0, 2314.0)
const SCROLL_REFERENCE_H := 656.0
const SCROLL_REFERENCE_W := SCROLL_REFERENCE_H * SCROLL_SOURCE_SIZE.x / SCROLL_SOURCE_SIZE.y
const SCROLL_PAPER_SIDE_PX := 52.0
const SCROLL_CONTENT_LOGICAL_W := 210.0
const SCROLL_CONTENT_BASE_SCALE := (SCROLL_REFERENCE_W - SCROLL_PAPER_SIDE_PX * 2.0) / SCROLL_CONTENT_LOGICAL_W
const SCROLL_CONTENT_LOGICAL_H := (SCROLL_REFERENCE_H - 144.0) / SCROLL_CONTENT_BASE_SCALE
const MAP_UNDER_SCROLL_FRINGE := 16.0
const FOCUS_MARGIN := 28.0

var _map_host: Control
var _map: WorldMapRuntimePreview
var _fixed_hud: CanvasLayer
var _fixed_hud_root: Control
var _topbar: Control
var _scroll: Control
var _scroll_body: VBoxContainer
var _ai_card: Control
var _top_plaque: Control
var _public_silver: Control
var _banner: Label
var _city_lore: CityLoreCard
var _formal_content: Dictionary = {}
var _sim_city_id := "yumenguan"
var _hud_lock_rects: Array[Rect2] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_map()
	_build_fixed_hud()
	await get_tree().process_frame
	_layout_hud()
	_sync_map_rects()
	_sync_city_lore_rect()
	_map.set_focus_city_id(_sim_city_id)
	_show_piece_at_city(_sim_city_id)
	_map.focus_city(_sim_city_id, false)


func get_map() -> WorldMapRuntimePreview:
	return _map


func get_city_lore_card() -> CityLoreCard:
	return _city_lore


func set_route_selection_active(active: bool) -> void:
	if _city_lore != null and _city_lore.is_open():
		_city_lore.force_close()
	if _map != null:
		_map.set_route_selection_active(active)


func get_debug_state() -> Dictionary:
	var map_dbg := _map.get_debug_state() if _map != null else {}
	return {
		"map": map_dbg,
		"topbar_rect": _topbar.get_global_rect() if _topbar else Rect2(),
		"scroll_rect": _scroll.get_global_rect() if _scroll else Rect2(),
		"ai_rect": _ai_card.get_global_rect() if _ai_card else Rect2(),
		"map_interaction_rect": map_interaction_rect(),
		"focus_safe_rect": focus_safe_rect(),
		"hud_occlusion_rects": hud_occlusion_rects(),
		"sim_city_id": _sim_city_id,
		"city_lore_open": _city_lore != null and _city_lore.is_open(),
		"city_lore_city_id": _city_lore.current_city_id if _city_lore != null else "",
	}


func map_interaction_rect() -> Rect2:
	## Global rect of the interactive map host.
	if _map_host == null:
		return get_global_rect()
	return _map_host.get_global_rect()


func map_local_safe_rect() -> Rect2:
	if _map == null:
		return Rect2()
	return Rect2(Vector2.ZERO, _map.size)


func focus_safe_rect() -> Rect2:
	## Map-local focus safe rect (camera space).
	var local := map_local_safe_rect().grow(-FOCUS_MARGIN)
	if _map == null or _ai_card == null:
		return local
	var ai_global := _ai_card.get_global_rect().grow(FOCUS_MARGIN)
	var ai_local := Rect2(ai_global.position - _map.get_global_rect().position, ai_global.size)
	if local.intersects(ai_local):
		var cut_bottom := ai_local.position.y - FOCUS_MARGIN
		if cut_bottom > local.position.y + 40.0:
			local.size.y = cut_bottom - local.position.y
	return local


func hud_occlusion_rects() -> Array:
	## Returned in map-local space for intersection tests with world_to_screen().
	var out: Array = []
	if _map == null:
		return out
	var origin := _map.get_global_rect().position
	for node in [_topbar, _scroll, _ai_card]:
		if node == null:
			continue
		var g: Rect2 = node.get_global_rect()
		out.append(Rect2(g.position - origin, g.size))
	return out


func set_simulated_active_city(city_id: String) -> void:
	_sim_city_id = city_id
	if _map == null:
		return
	_map.set_focus_city_id(city_id)
	_show_piece_at_city(city_id)
	_maybe_refocus_active()


func focus_city(city_id: String, animated: bool = true) -> void:
	_sim_city_id = city_id
	if _map != null:
		_map.focus_city(city_id, animated)
		_show_piece_at_city(city_id)


func _show_piece_at_city(city_id: String) -> void:
	if _map == null or not _map._stops_by_id.has(city_id):
		return
	# select_stop toggles off when called twice with the same id.
	if _map._selected_stop != city_id:
		if _map._selected_stop != "":
			_map.clear_selection()
		_map.select_stop(city_id)
	else:
		_map._place_piece_at_stop(city_id)
	_map._tune_piece_preview_scale()


func set_camera_input_enabled(enabled: bool) -> void:
	if _map != null:
		_map.set_camera_input_enabled(enabled)


func _build_map() -> void:
	_map_host = Control.new()
	_map_host.name = "WorldMapViewport"
	_map_host.mouse_filter = Control.MOUSE_FILTER_STOP
	_map_host.clip_contents = true
	add_child(_map_host)
	_map = preload("res://scenes/preview/world_map_runtime_preview.tscn").instantiate() as WorldMapRuntimePreview
	_map.hud_half_view_mode = true
	_map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_host.add_child(_map)
	_map.set_route_selection_active(false)
	_map.city_inspect_requested.connect(_on_city_inspect_requested)


func _build_fixed_hud() -> void:
	_fixed_hud = CanvasLayer.new()
	_fixed_hud.name = "FixedHUD"
	_fixed_hud.layer = 20
	add_child(_fixed_hud)

	_fixed_hud_root = Control.new()
	_fixed_hud_root.name = "FixedHUDRoot"
	_fixed_hud_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fixed_hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fixed_hud.add_child(_fixed_hud_root)

	_topbar = TextureRect.new()
	_topbar.name = "TopStatusBar"
	_topbar.texture = load(TOPBAR_TEX) as Texture2D
	_topbar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_topbar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_topbar.mouse_filter = Control.MOUSE_FILTER_STOP
	_topbar.gui_input.connect(_on_hud_gui_input)
	_fixed_hud_root.add_child(_topbar)

	_top_plaque = TextureRect.new()
	_top_plaque.name = "CurrentActionPlaque"
	(_top_plaque as TextureRect).texture = load(ACTION_PLAQUE_TEX) as Texture2D
	(_top_plaque as TextureRect).expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	(_top_plaque as TextureRect).stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_top_plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fixed_hud_root.add_child(_top_plaque)
	var action_label := Label.new()
	action_label.name = "CurrentActionLabel"
	action_label.text = "当前行动：玩家"
	action_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	action_label.offset_left = 58
	action_label.offset_right = -58
	action_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	action_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	HudStyle.apply_heading(action_label, HudStyle.TOPBAR_GOLD_TEXT, 14)
	action_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top_plaque.add_child(action_label)

	_public_silver = HBoxContainer.new()
	_public_silver.name = "PublicSilverDisplay"
	(_public_silver as HBoxContainer).add_theme_constant_override("separation", 8)
	_public_silver.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fixed_hud_root.add_child(_public_silver)
	var public_icon := _texture_rect(SILVER_TEX, "PublicSilverIcon")
	public_icon.custom_minimum_size = Vector2(32, 32)
	_public_silver.add_child(public_icon)
	var public_label := _label("公共银两：100", "PublicSilverValue")
	HudStyle.apply_display(public_label, HudStyle.TOPBAR_GOLD_TEXT, 24)
	public_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_public_silver.add_child(public_label)

	_scroll = TextureRect.new()
	_scroll.name = "RightScrollPanel"
	_scroll.texture = load(SCROLL_TEX) as Texture2D
	_scroll.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_scroll.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	_scroll.gui_input.connect(_on_hud_gui_input)
	_fixed_hud_root.add_child(_scroll)

	_scroll_body = VBoxContainer.new()
	_scroll_body.name = "ScrollSafeContent"
	_scroll_body.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_scroll_body.add_theme_constant_override("separation", 10)
	_scroll_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_scroll_body)
	var cargo_header := HBoxContainer.new()
	cargo_header.name = "PlayerCargoHeader"
	cargo_header.add_theme_constant_override("separation", 4)
	_scroll_body.add_child(cargo_header)
	var cargo_title := _label("玩家船舱", "PlayerCargoTitle")
	HudStyle.apply_heading(cargo_title, HudStyle.INK_STRONG, 15)
	cargo_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cargo_header.add_child(cargo_title)
	cargo_header.add_child(_wallet("PlayerSilver", 76, true))

	var cargo_center := CenterContainer.new()
	cargo_center.name = "PlayerCargoCenter"
	cargo_center.custom_minimum_size = Vector2(0, 54)
	_scroll_body.add_child(cargo_center)
	var cargo_slots := HBoxContainer.new()
	cargo_slots.name = "PlayerCargoSlots"
	cargo_slots.add_theme_constant_override("separation", 6)
	cargo_center.add_child(cargo_slots)
	cargo_slots.add_child(_cargo_slot("jade", 2, false, "PlayerCargoSlot0"))
	cargo_slots.add_child(_cargo_slot("porcelain", 1, false, "PlayerCargoSlot1"))
	cargo_slots.add_child(_cargo_slot("", 0, true, "PlayerCargoSlot2"))
	cargo_slots.add_child(_cargo_slot("", 0, true, "PlayerCargoSlot3"))

	var divider := _texture_rect(DIVIDER_TEX, "CargoDivider")
	divider.custom_minimum_size = Vector2(0, 12)
	divider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_body.add_child(divider)
	var round_label := _label("本回合行动  ·  第 1 轮", "TurnHeading")
	HudStyle.apply_heading(round_label, HudStyle.INK_STRONG, 16)
	round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scroll_body.add_child(round_label)
	var phase_label := _label("准备掷骰", "PhaseHeading")
	HudStyle.apply_heading(phase_label, HudStyle.CINNABAR_TEXT, 18)
	phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scroll_body.add_child(phase_label)
	var phase_body := _label("掷出 1–5 步，或触发意外事件。", "PhaseDescription")
	phase_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	phase_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	HudStyle.apply_body(phase_body, HudStyle.INK_WEAK, 12)
	_scroll_body.add_child(phase_body)
	var action_spacer := Control.new()
	action_spacer.name = "ActionSpacer"
	action_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_body.add_child(action_spacer)
	var primary := _texture_rect(PRIMARY_BUTTON_TEX, "PrimaryActionButton")
	primary.custom_minimum_size = Vector2(0, 52)
	primary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_body.add_child(primary)
	var primary_label := _label("掷骰", "PrimaryActionLabel")
	primary_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	primary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	primary_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	HudStyle.apply_heading(primary_label, HudStyle.PARCHMENT_LIGHT, 15)
	primary.add_child(primary_label)
	var footer := _label("点击按钮开始本回合", "FooterHint")
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	HudStyle.apply_caption(footer, HudStyle.INK_WEAK, 11)
	_scroll_body.add_child(footer)

	_ai_card = TextureRect.new()
	_ai_card.name = "AIPlayerCard"
	_ai_card.texture = load(AI_CARD_TEX) as Texture2D
	_ai_card.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_ai_card.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_ai_card.mouse_filter = Control.MOUSE_FILTER_STOP
	_ai_card.gui_input.connect(_on_hud_gui_input)
	_fixed_hud_root.add_child(_ai_card)
	var ai_content := HBoxContainer.new()
	ai_content.name = "AIContent"
	ai_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ai_content.offset_left = 16
	ai_content.offset_right = -16
	ai_content.offset_top = 9
	ai_content.offset_bottom = -9
	ai_content.add_theme_constant_override("separation", 8)
	ai_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ai_card.add_child(ai_content)
	var ai_identity := VBoxContainer.new()
	ai_identity.name = "AIIdentity"
	ai_identity.custom_minimum_size = Vector2(102, 0)
	ai_identity.add_theme_constant_override("separation", 2)
	ai_content.add_child(ai_identity)
	var ai_name := _label("电脑商旅", "AIName")
	HudStyle.apply_heading(ai_name, HudStyle.TOPBAR_GOLD_TEXT, 15)
	ai_identity.add_child(ai_name)
	ai_identity.add_child(_wallet("AISilver", 68, false))
	var ai_goods := HBoxContainer.new()
	ai_goods.name = "AIGoods"
	ai_goods.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ai_goods.alignment = BoxContainer.ALIGNMENT_END
	ai_goods.add_theme_constant_override("separation", 4)
	ai_content.add_child(ai_goods)
	# AI 卡只展示非零货物，不绘制 0 数量占位。
	ai_goods.add_child(_cargo_slot("jade", 2, false, "AIGoodJade", 38.0))
	ai_goods.add_child(_cargo_slot("silk", 1, false, "AIGoodSilk", 38.0))

	_formal_content = GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	_city_lore = preload("res://scenes/ui/components/city_lore_card.tscn").instantiate() as CityLoreCard
	_city_lore.name = "FormalWorldCityLoreCard"
	_city_lore.set_content_override(_formal_content)
	_city_lore.closed.connect(_on_city_lore_closed)
	_fixed_hud_root.add_child(_city_lore)


func _texture_rect(path: String, node_name: String) -> TextureRect:
	var rect := TextureRect.new()
	rect.name = node_name
	rect.texture = load(path) as Texture2D
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


func _label(value: String, node_name: String) -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = value
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _wallet(node_name: String, amount: int, parchment: bool) -> HBoxContainer:
	var wallet := HBoxContainer.new()
	wallet.name = node_name
	wallet.add_theme_constant_override("separation", 3)
	wallet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := _texture_rect(SILVER_TEX, "%sIcon" % node_name)
	icon.custom_minimum_size = Vector2(22, 22)
	wallet.add_child(icon)
	var amount_label := _label(str(amount), "%sValue" % node_name)
	HudStyle.apply_heading(
		amount_label,
		HudStyle.INK_BODY if parchment else HudStyle.TOPBAR_GOLD_TEXT,
		14
	)
	amount_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	wallet.add_child(amount_label)
	return wallet


func _cargo_slot(
	good_id: String,
	count: int,
	empty: bool,
	node_name: String,
	slot_px: float = 48.0
) -> Control:
	var slot := Control.new()
	slot.name = node_name
	slot.custom_minimum_size = Vector2(slot_px, slot_px)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var plate := _texture_rect(CARGO_SLOT_TEX, "Plate")
	plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	plate.modulate = Color(0.58, 0.55, 0.50, 0.72) if empty else Color.WHITE
	slot.add_child(plate)
	if empty or good_id == "" or count <= 0:
		return slot
	var texture_path := String(GOOD_TEXTURES.get(good_id, ""))
	if texture_path != "" and ResourceLoader.exists(texture_path):
		var icon := _texture_rect(texture_path, "GoodIcon")
		var inset := 7.0 if slot_px >= 44.0 else 5.0
		icon.position = Vector2(inset, inset - 1.0)
		icon.size = Vector2(slot_px - inset * 2.0, slot_px - inset * 2.0)
		slot.add_child(icon)
	var badge := _label(str(count), "Count")
	badge.position = Vector2(slot_px - 17.0, slot_px - 16.0)
	badge.size = Vector2(14, 13)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	HudStyle.apply_heading(badge, HudStyle.INK_STRONG, 10)
	slot.add_child(badge)
	return slot


func _build_banner() -> void:
	_banner = Label.new()
	_banner.name = "PreviewBanner"
	_banner.text = "正式地图表现预览 · 未接正式规则开局"
	_banner.position = Vector2(12, 68)
	_banner.size = Vector2(520, 22)
	HudStyle.apply_caption(_banner, Color(0.92, 0.86, 0.72, 0.95), 12)
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fixed_hud.get_child(0).add_child(_banner)


func _layout_hud() -> void:
	if (
		_topbar == null or _scroll == null or _ai_card == null or _map_host == null
		or _top_plaque == null or _public_silver == null
	):
		return
	var vp := get_viewport_rect().size
	if vp.x < 2.0 or vp.y < 2.0:
		vp = Vector2(1280, 720)
	var scroll_w := _compute_scroll_width(vp)
	_topbar.position = Vector2.ZERO
	_topbar.size = Vector2(vp.x, TOPBAR_H)
	_top_plaque.position = Vector2(24, 6)
	# The source plaque includes generous transparent side padding.  A 280px
	# texture rect yields a ~168px visible red plaque, enough for the full label.
	_top_plaque.size = Vector2(280, 52)
	_public_silver.size = Vector2(250, 38)
	_public_silver.position = Vector2(vp.x - scroll_w - 280.0, 13.0)
	_scroll.position = Vector2(vp.x - scroll_w, TOPBAR_H)
	_scroll.size = Vector2(scroll_w, maxf(vp.y - TOPBAR_H, 1.0))
	_layout_scroll_safe_content()
	var ai_w := clampf(vp.x * 0.20, 220.0, 280.0)
	var ai_h := 72.0
	_ai_card.size = Vector2(ai_w, ai_h)
	_ai_card.position = Vector2(20.0, vp.y - ai_h - 14.0)
	_map_host.position = Vector2(0, TOPBAR_H)
	_map_host.size = Vector2(maxf(vp.x - scroll_w + MAP_UNDER_SCROLL_FRINGE, 1.0), maxf(vp.y - TOPBAR_H, 1.0))
	if _map != null:
		_map.anchor_right = 0.0
		_map.anchor_bottom = 0.0
		_map.position = Vector2.ZERO
		_map.size = _map_host.size


func _layout_scroll_safe_content() -> void:
	if _scroll == null or _scroll_body == null:
		return
	# TextureRect uses KEEP_ASPECT_CENTERED, so its visible paper can be narrower
	# than the clamped outer Control at 1024×576.  Lay out against that actual
	# drawn texture, then scale the complete reference content as one unit.
	var draw_scale := minf(
		_scroll.size.x / SCROLL_SOURCE_SIZE.x,
		_scroll.size.y / SCROLL_SOURCE_SIZE.y
	)
	var draw_size := SCROLL_SOURCE_SIZE * draw_scale
	var draw_origin := (_scroll.size - draw_size) * 0.5
	var draw_ratio := draw_size.x / SCROLL_REFERENCE_W
	var content_scale := draw_ratio * SCROLL_CONTENT_BASE_SCALE
	_scroll_body.position = draw_origin + Vector2(SCROLL_PAPER_SIDE_PX, 80.0) * draw_ratio
	_scroll_body.size = Vector2(SCROLL_CONTENT_LOGICAL_W, SCROLL_CONTENT_LOGICAL_H)
	_scroll_body.scale = Vector2(content_scale, content_scale)


func _compute_scroll_width(vp: Vector2) -> float:
	# Match game_screen aspect math: (viewport_h - topbar) * 1024/2314
	var h := maxf(vp.y - TOPBAR_H, 1.0)
	var w := h * 1024.0 / 2314.0
	return clampf(w, SCROLL_MIN, SCROLL_MAX)


func _sync_map_rects() -> void:
	if _map == null:
		return
	if _map.size.x < 2.0 or _map.size.y < 2.0:
		_map.size = _map_host.size
	var local_safe := Rect2(Vector2.ZERO, _map.size)
	_map.set_external_safe_view(local_safe)
	_map.set_focus_safe_rect(focus_safe_rect())
	# Re-apply half-view fit against the real safe size.
	if _map.hud_half_view_mode:
		var cam := _map.get_camera()
		var profile: Dictionary = _map.get_debug_state().get("camera", {})
		# Force fit recompute via safe rect setter path.
		cam.set_safe_view_rect(local_safe)
		_map._apply_camera_transform()
	_sync_city_lore_rect()


func _sync_city_lore_rect() -> void:
	if _city_lore == null or _map_host == null:
		return
	var lore_origin := _city_lore.get_global_rect().position
	var map_global := _map_host.get_global_rect()
	_city_lore.set_map_rect(Rect2(map_global.position - lore_origin, map_global.size))


func _on_city_inspect_requested(ruleset_city_id: String) -> void:
	if _city_lore == null or _map == null or _map.is_route_selection_active():
		return
	_sync_city_lore_rect()
	_map.set_camera_input_enabled(false)
	_city_lore.open_for_city(ruleset_city_id)
	if not _city_lore.is_open():
		_map.set_camera_input_enabled(true)


func _on_city_lore_closed() -> void:
	if _map != null:
		_map.set_camera_input_enabled(true)


func _maybe_refocus_active() -> void:
	if _map == null:
		return
	var wp := _map.city_world_point(_sim_city_id)
	if wp == Vector2.INF:
		return
	if _map.get_camera().is_world_point_in_focus_safe(wp, 8.0):
		return
	_map.focus_world_point(wp, true)


func _on_hud_gui_input(event: InputEvent) -> void:
	# Swallow wheel/drag so map camera does not move when pointer is on HUD.
	if event is InputEventMouseButton or event is InputEventMouseMotion \
		or event is InputEventMagnifyGesture or event is InputEventPanGesture:
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_hud()
		_sync_map_rects()
