class_name CityLoreCard
extends Control

signal closed

enum ViewState { CLOSED, DEFAULT, EXPANDED }

## Demo-only legacy welded cards. Formal 16 cities must never be added here.
const CITY_CARD_PATHS := {
	"changan": "res://assets/game/ui/city_cards/cards/city_card_changan_768x1024.png",
	"dunhuang": "res://assets/game/ui/city_cards/cards/city_card_dunhuang_768x1024.png",
	"guangzhou": "res://assets/game/ui/city_cards/cards/city_card_guangzhou_768x1024.png",
	"hangzhou": "res://assets/game/ui/city_cards/cards/city_card_hangzhou_768x1024.png",
	"luoyang": "res://assets/game/ui/city_cards/cards/city_card_luoyang_768x1024.png",
	"quanzhou": "res://assets/game/ui/city_cards/cards/city_card_quanzhou_768x1024.png",
	"yumenguan": "res://assets/game/ui/city_cards/cards/city_card_yumenguan_768x1024.png",
}
const LEGACY_RULESET_IDS := {
	"cn_demo_v1": true,
	"test_fixture": true,
}

var view_state := ViewState.CLOSED
var current_city_id := ""
var _map_rect := Rect2(0, 64, 990, 656)
var _active_tween: Tween
var _animating := false
var _session_generation := -1
var _content_override: Dictionary = {}
var _use_formal := false
var _formal_card: FormalCityCard


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	$MapDimmer.gui_input.connect(_on_backdrop_input)
	$FullDimmer.gui_input.connect(_on_backdrop_input)
	$CardTexture.gui_input.connect(_on_card_input)
	_ensure_formal_card()
	set_process_unhandled_input(false)
	visible = false
	_validate_mapping()


func set_content_override(content: Dictionary) -> void:
	_content_override = content.duplicate(true) if not content.is_empty() else {}


func clear_content_override() -> void:
	_content_override = {}


func active_content() -> Dictionary:
	if not _content_override.is_empty():
		return _content_override
	return GameState.content


func set_map_rect(rect: Rect2) -> void:
	_map_rect = rect
	$MapDimmer.position = rect.position
	$MapDimmer.size = rect.size
	if visible and not _animating:
		_apply_rect(_expanded_rect() if view_state == ViewState.EXPANDED else _default_rect())


func open_for_city(city_id: String) -> void:
	if _animating:
		return
	_ensure_formal_card()
	var content := active_content()
	var ruleset_id := _ruleset_id(content)
	_use_formal = ruleset_id == "lshu_configurable_v1" or not LEGACY_RULESET_IDS.has(ruleset_id)
	if ruleset_id == "lshu_configurable_v1":
		# Formal content is fail-closed: a broken manifest/card/illustration must stay visibly
		# broken. Falling through to a similarly named Demo welded card would hide a content
		# regression and could show the wrong edition.
		var formal := FormalCardPresentationResolver.resolve_city_card(content, city_id)
		$CardTexture.visible = false
		$CardShadow.visible = false
		_formal_card.visible = true
		_formal_card.bind_resolved(formal, content)
		_formal_card.set_expanded(false)
	elif LEGACY_RULESET_IDS.has(ruleset_id):
		# Demo/fixture content is resolved only by the legacy table. Do not probe the formal
		# resolver first: expected Demo IDs must not generate misleading formal warnings.
		var path := String(CITY_CARD_PATHS.get(city_id, ""))
		if path.is_empty() or not ResourceLoader.exists(path):
			push_warning("CityLoreCard: 未找到城市图鉴卡 %s" % city_id)
			return
		_formal_card.visible = false
		_formal_card.clear_texture()
		$CardTexture.visible = true
		$CardShadow.visible = true
		var texture := load(path) as Texture2D
		$CardTexture.texture = texture
		$CardShadow.texture = texture
	else:
		# Unknown or malformed editions are not Demo content. Keep them visibly failed
		# instead of silently borrowing a welded legacy card with the same city ID.
		$CardTexture.visible = false
		$CardShadow.visible = false
		_formal_card.visible = true
		_formal_card.bind_resolved({
			"success": false,
			"reason": "未知规则包：%s" % (ruleset_id if ruleset_id != "" else "（缺失 ruleset_id）"),
		}, content)
	_kill_tween()
	current_city_id = city_id
	_session_generation = GameState.session_generation
	view_state = ViewState.DEFAULT
	visible = true
	modulate = Color(1, 1, 1, 0)
	$MapDimmer.visible = true
	$FullDimmer.visible = false
	set_process_unhandled_input(true)
	var target := _default_rect()
	var start := _scaled_about_center(target, 0.92)
	_apply_rect(start)
	_animating = true
	_active_tween = create_tween().set_parallel(true)
	_active_tween.tween_property(self, "modulate:a", 1.0, 0.20)
	_active_tween.tween_method(_apply_rect, start, target, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_active_tween.finished.connect(func():
		if _session_is_current():
			_animating = false
	)


func toggle_expanded() -> void:
	if not visible or _animating:
		return
	_kill_tween()
	_animating = true
	var from := get_card_rect()
	view_state = ViewState.EXPANDED if view_state == ViewState.DEFAULT else ViewState.DEFAULT
	if _use_formal and _formal_card != null:
		_formal_card.set_expanded(view_state == ViewState.EXPANDED)
	$MapDimmer.visible = view_state == ViewState.DEFAULT
	$FullDimmer.visible = view_state == ViewState.EXPANDED
	var target := _expanded_rect() if view_state == ViewState.EXPANDED else _default_rect()
	_active_tween = create_tween()
	_active_tween.tween_method(_apply_rect, from, target, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_active_tween.finished.connect(func():
		if _session_is_current():
			_animating = false
	)


func close(animated: bool = true) -> void:
	if not visible:
		return
	if not animated:
		force_close()
		return
	if _animating:
		return
	_kill_tween()
	_animating = true
	var serial_generation := _session_generation
	_active_tween = create_tween()
	_active_tween.tween_property(self, "modulate:a", 0.0, 0.20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_active_tween.finished.connect(func():
		if serial_generation == _session_generation:
			_finish_close()
	)


func force_close() -> void:
	_kill_tween()
	_finish_close()


func is_open() -> bool:
	return visible and view_state != ViewState.CLOSED


func is_expanded() -> bool:
	return visible and view_state == ViewState.EXPANDED


func get_card_rect() -> Rect2:
	if _use_formal and _formal_card != null and _formal_card.visible:
		return Rect2(_formal_card.position, _formal_card.size)
	return Rect2($CardTexture.position, $CardTexture.size)


func _finish_close() -> void:
	var was_open := visible
	visible = false
	modulate = Color.WHITE
	view_state = ViewState.CLOSED
	current_city_id = ""
	_animating = false
	set_process_unhandled_input(false)
	$MapDimmer.visible = false
	$FullDimmer.visible = false
	$CardTexture.texture = null
	$CardShadow.texture = null
	if _formal_card != null:
		_formal_card.set_expanded(false)
		_formal_card.clear_texture()
		_formal_card.visible = false
	_use_formal = false
	if was_open:
		closed.emit()


func _ensure_formal_card() -> void:
	if _formal_card != null and is_instance_valid(_formal_card):
		return
	_formal_card = preload("res://scenes/ui/components/formal_city_card.tscn").instantiate() as FormalCityCard
	_formal_card.show_user_intro = true
	_formal_card.name = "FormalCityCard"
	_formal_card.visible = false
	_formal_card.gui_input.connect(_on_card_input)
	add_child(_formal_card)


func _apply_rect(rect: Rect2) -> void:
	$CardTexture.position = rect.position
	$CardTexture.size = rect.size
	$CardShadow.position = rect.position + Vector2(4, 4)
	$CardShadow.size = rect.size
	if _formal_card != null:
		_formal_card.position = rect.position
		_formal_card.size = rect.size


func _default_rect() -> Rect2:
	var height := _map_rect.size.y * 0.88
	var width := height * 0.75
	if width > _map_rect.size.x * 0.96:
		width = _map_rect.size.x * 0.96
		height = width * 4.0 / 3.0
	var card_size := Vector2(width, height)
	return Rect2(_map_rect.get_center() - card_size * 0.5, card_size)


func _expanded_rect() -> Rect2:
	var viewport_size := get_viewport_rect().size
	var height := minf(viewport_size.y * 0.98, viewport_size.x * 4.0 / 3.0 * 0.98)
	height = minf(height, viewport_size.y - 10.0)
	var card_size := Vector2(height * 0.75, height)
	return Rect2((viewport_size - card_size) * 0.5, card_size)


func _scaled_about_center(rect: Rect2, factor: float) -> Rect2:
	var scaled := rect.size * factor
	return Rect2(rect.get_center() - scaled * 0.5, scaled)


func _on_card_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		toggle_expanded()
		accept_event()


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		close()
		accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _kill_tween() -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null


func _session_is_current() -> bool:
	return visible and _session_generation == GameState.session_generation


func _validate_mapping() -> void:
	var content := active_content()
	if content.is_empty():
		return
	var ruleset_id := _ruleset_id(content)
	# Mapping validation belongs to the explicit Demo/fixture path only. Formal content is
	# validated by FormalCardPresentationResolver when opened, while unknown editions fail
	# closed. Probing the legacy table for either would blur edition ownership and emit
	# misleading "legacy card missing" warnings.
	if not LEGACY_RULESET_IDS.has(ruleset_id):
		return
	for city_id in content.get("cities", {}).keys():
		var path := String(CITY_CARD_PATHS.get(String(city_id), ""))
		if path.is_empty() or not ResourceLoader.exists(path):
			push_warning("CityLoreCard: 城市映射缺失 %s" % String(city_id))


static func card_path_for(city_id: String) -> String:
	return String(CITY_CARD_PATHS.get(city_id, ""))


static func _ruleset_id(content: Dictionary) -> String:
	return String(content.get("ruleset", {}).get("ruleset_id", ""))
