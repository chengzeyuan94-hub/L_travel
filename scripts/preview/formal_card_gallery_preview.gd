extends Control

## Independent formal city/event card gallery.
## Loads lshu_configurable_v1 only — never calls SetupSystem / never resolves effects.

enum Mode { CITIES, EVENTS }

var _content: Dictionary = {}
var _mode := Mode.CITIES
var _city_ids: Array[String] = []
var _event_ids: Array[String] = []
var _index := 0
var _city_card: FormalCityCard
var _event_card: EventCard
var _meta: Label
var _blocked_banner: Label
var _title: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_content = GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	_city_ids.clear()
	for city_id in _content.get("cities", {}).keys():
		_city_ids.append(String(city_id))
	_city_ids.sort()
	_event_ids.clear()
	for event_id in _content.get("event_definitions", {}).keys():
		_event_ids.append(String(event_id))
	_event_ids.sort_custom(func(a: String, b: String) -> bool:
		var da: Dictionary = _content["event_definitions"][a]
		var db: Dictionary = _content["event_definitions"][b]
		var ta := String(da.get("deck_type", ""))
		var tb := String(db.get("deck_type", ""))
		if ta != tb:
			return ta < tb
		return int(da.get("card_number", 0)) < int(db.get("card_number", 0))
	)
	_show_current()


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color("2A2118")
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_title = Label.new()
	_title.position = Vector2(24, 16)
	_title.size = Vector2(800, 28)
	HudStyle.apply_heading(_title, HudStyle.TOPBAR_GOLD_TEXT, 20)
	add_child(_title)

	_meta = Label.new()
	_meta.position = Vector2(24, 48)
	_meta.size = Vector2(900, 72)
	_meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	HudStyle.apply_body(_meta, Color("E8DCC4"), 14)
	add_child(_meta)

	_blocked_banner = Label.new()
	_blocked_banner.position = Vector2(24, 120)
	_blocked_banner.size = Vector2(600, 24)
	_blocked_banner.visible = false
	HudStyle.apply_caption(_blocked_banner, HudStyle.CINNABAR_TEXT, 13)
	add_child(_blocked_banner)

	_city_card = preload("res://scenes/ui/components/formal_city_card.tscn").instantiate() as FormalCityCard
	_city_card.position = Vector2(360, 150)
	_city_card.size = Vector2(360, 480)
	add_child(_city_card)

	_event_card = preload("res://scenes/ui/components/event_card.tscn").instantiate() as EventCard
	_event_card.position = Vector2(390, 150)
	_event_card.size = Vector2(300, 400)
	_event_card.visible = false
	add_child(_event_card)

	_add_button("城市卡 16", Vector2(24, 640), func(): _set_mode(Mode.CITIES))
	_add_button("事件卡 36", Vector2(160, 640), func(): _set_mode(Mode.EVENTS))
	_add_button("上一张", Vector2(320, 640), func(): _step(-1))
	_add_button("下一张", Vector2(440, 640), func(): _step(1))


func _add_button(text: String, pos: Vector2, cb: Callable) -> void:
	var btn := Button.new()
	btn.text = text
	btn.position = pos
	btn.size = Vector2(120, 36)
	btn.pressed.connect(cb)
	add_child(btn)


func _set_mode(mode: Mode) -> void:
	_mode = mode
	_index = 0
	_show_current()


func _step(delta: int) -> void:
	var n := _city_ids.size() if _mode == Mode.CITIES else _event_ids.size()
	if n <= 0:
		return
	_index = (_index + delta) % n
	if _index < 0:
		_index += n
	_show_current()


func _show_current() -> void:
	_city_card.clear_texture()
	_event_card.clear_illustration()
	_blocked_banner.visible = false
	if _mode == Mode.CITIES:
		_event_card.visible = false
		_city_card.visible = true
		_title.text = "正式城市卡图库 · lshu_configurable_v1（仅预览）"
		if _city_ids.is_empty():
			_meta.text = "无城市"
			return
		var city_id := _city_ids[_index]
		var resolved := FormalCardPresentationResolver.resolve_city_card(_content, city_id)
		_city_card.bind_resolved(resolved, _content)
		_meta.text = "city_id=%s  card_number=%d  transport=%s  art=%s  [%d/%d]" % [
			city_id,
			int(resolved.get("card_number", 0)),
			String(resolved.get("starting_transport", "")),
			String(resolved.get("art_review_status", "")),
			_index + 1,
			_city_ids.size(),
		]
	else:
		_city_card.visible = false
		_event_card.visible = true
		_title.text = "正式事件卡图库 · lshu_configurable_v1（仅预览）"
		if _event_ids.is_empty():
			_meta.text = "无事件"
			return
		var event_id := _event_ids[_index]
		var resolved_e := FormalCardPresentationResolver.resolve_event(_content, event_id)
		_event_card.set_content_override(_content)
		_event_card.configure_front(event_id, _content)
		_event_card.show_front()
		var status := String(resolved_e.get("runtime_resolution_status", ""))
		_blocked_banner.visible = status == "RULE_BLOCKED"
		if _blocked_banner.visible:
			_blocked_banner.text = "规则待裁决 · 仅预览"
		_meta.text = "event_id=%s  %s #%d  sentiment=%s  status=%s  [%d/%d]" % [
			event_id,
			String(resolved_e.get("deck_type", "")),
			int(resolved_e.get("card_number", 0)),
			String(resolved_e.get("sentiment", "")),
			status,
			_index + 1,
			_event_ids.size(),
		]


func current_mode_name() -> String:
	return "CITIES" if _mode == Mode.CITIES else "EVENTS"


func current_index() -> int:
	return _index


func city_ids() -> Array[String]:
	return _city_ids.duplicate()


func event_ids() -> Array[String]:
	return _event_ids.duplicate()


func content() -> Dictionary:
	return _content
