extends Control


const MAP_TEXTURE_PATH := "res://assets/game/maps/world_preview/final_world_map_preview_v1.png"
const MANIFEST_PATH := "res://assets/game/cities/world_hover_preview/manifest.json"
const ICON_SCRIPT := preload("res://scripts/preview/world_city_hover_icon.gd")
const RANDOM_SEED := 20260730
const GRID_COLUMNS := 4
const GRID_ROWS := 4

var _map_texture: Texture2D
var _map_rect: TextureRect
var _icons_layer: Control
var _icons: Dictionary = {}
var _normalized_positions: Dictionary = {}


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.055, 0.075, 0.085))
	_build_background()
	_build_header()
	_build_icons()
	resized.connect(_layout_preview)
	call_deferred("_layout_preview")


func get_icon(city_id: String) -> WorldCityHoverIcon:
	return _icons.get(city_id) as WorldCityHoverIcon


func set_city_hovered(city_id: String, value: bool) -> void:
	var icon := get_icon(city_id)
	if icon != null:
		icon.set_hovered_for_preview(value)


func get_debug_state() -> Dictionary:
	var city_states := {}
	for city_id in _icons:
		city_states[city_id] = (_icons[city_id] as WorldCityHoverIcon).get_preview_state()
	return {
		"city_count": _icons.size(),
		"map_rect": Rect2(_map_rect.position, _map_rect.size) if _map_rect != null else Rect2(),
		"cities": city_states,
	}


func _build_background() -> void:
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.055, 0.075, 0.085)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	_map_texture = load(MAP_TEXTURE_PATH) as Texture2D
	if _map_texture == null:
		push_error("WorldCityHoverPreview: failed to load map texture")
		return
	_map_rect = TextureRect.new()
	_map_rect.name = "FinalWorldMap"
	_map_rect.texture = _map_texture
	_map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_map_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_map_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_map_rect)

	_icons_layer = Control.new()
	_icons_layer.name = "RandomCityPreviewLayer"
	_icons_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icons_layer.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_icons_layer)


func _build_header() -> void:
	var panel := PanelContainer.new()
	panel.name = "PreviewHeader"
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.position = Vector2(-250.0, 12.0)
	panel.size = Vector2(500.0, 56.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.z_index = 200
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.055, 0.035, 0.90)
	style.border_color = Color(0.76, 0.49, 0.15, 0.92)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var text_box := VBoxContainer.new()
	text_box.add_theme_constant_override("separation", 1)
	panel.add_child(text_box)
	var title := Label.new()
	title.text = "16 城 Hover 动效临时测试"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1.0, 0.89, 0.63))
	text_box.add_child(title)
	var hint := Label.new()
	hint.text = "鼠标悬停城市：轻微放大并循环播放 32 帧动画"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.90, 0.83, 0.70))
	text_box.add_child(hint)


func _build_icons() -> void:
	var manifest := _load_manifest()
	var cities: Array = manifest.get("cities", [])
	if cities.size() != 16:
		push_error("WorldCityHoverPreview: expected 16 cities, got %d" % cities.size())
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = RANDOM_SEED
	for index in range(cities.size()):
		var entry: Dictionary = cities[index]
		var icon := ICON_SCRIPT.new() as WorldCityHoverIcon
		icon.name = "City_%s" % str(entry.get("id", index))
		icon.setup(entry)
		_icons_layer.add_child(icon)
		var column := index % GRID_COLUMNS
		var row := index / GRID_COLUMNS
		var normalized := Vector2(
			(float(column) + 0.5) / float(GRID_COLUMNS),
			(float(row) + 0.5) / float(GRID_ROWS)
		)
		normalized += Vector2(rng.randf_range(-0.026, 0.026), rng.randf_range(-0.018, 0.018))
		var city_id := str(entry.get("id", ""))
		_normalized_positions[city_id] = normalized
		_icons[city_id] = icon


func _load_manifest() -> Dictionary:
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		push_error("WorldCityHoverPreview: failed to open manifest")
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		push_error("WorldCityHoverPreview: invalid manifest")
		return {}
	return parsed


func _layout_preview() -> void:
	if _map_rect == null or _map_texture == null:
		return
	var available: Vector2 = size
	var texture_size := Vector2(_map_texture.get_width(), _map_texture.get_height())
	var scale_factor: float = minf(
		available.x / texture_size.x,
		available.y / texture_size.y
	)
	var displayed_size: Vector2 = texture_size * scale_factor
	var displayed_position: Vector2 = (available - displayed_size) * 0.5
	_map_rect.position = displayed_position
	_map_rect.size = displayed_size

	for city_id in _icons:
		var icon := _icons[city_id] as WorldCityHoverIcon
		var normalized: Vector2 = _normalized_positions[city_id]
		var center: Vector2 = displayed_position + normalized * displayed_size
		icon.set_home_position(center - icon.size * 0.5)
