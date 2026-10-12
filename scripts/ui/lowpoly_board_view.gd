extends Control

## Formal board renderer. Rule nodes, routes, trade and RNG remain owned by the
## existing systems. The old renderer is only instantiated for explicit Demo games.
signal node_clicked(node_id: String)
signal city_inspect_requested(city_id: String)
signal move_animation_finished(player_id: String)

const PieceActor := preload("res://scripts/ui/lowpoly_map_piece_actor.gd")
const PlanetGeometry := preload("res://scripts/ui/planet_geometry.gd")
const RouteGeometry := preload("res://scripts/ui/planet_route_geometry.gd")
const AmbientLayer := preload("res://scripts/ui/planet_ambient_layer.gd")
const CorridorLayer := preload("res://scripts/ui/planet_corridor_props.gd")
const LegacyBoard := preload("res://scripts/ui/board_view.gd")
const GROUND_Y := 0.08
const ROUTE_Y := 0.105
const LAND_ROUTE_HALF_WIDTH := 0.16
const SEA_ROUTE_HALF_WIDTH := 0.11
const LAND_MARKER_RADIUS := 0.18
const SEA_MARKER_RADIUS := 0.14
const LEGAL_MARKER_SCALE := 1.5
const SELECTED_ROUTE_EXTRA_WIDTH := 0.04
const SELECTED_ROUTE_HEIGHT := 0.020
const MARKER_HEIGHT := 0.045
const MOVE_SPEED := 100.0
const MIN_MOVE_SECONDS := 1.0
const SWITCH_SECONDS := 0.32
const HIT_RADIUS := 22.0
const DRAG_THRESHOLD := 6.0
const CAMERA_FOV := 42.0
const MIN_ZOOM := 0.65
const MAX_ZOOM := 4.2
const MAX_ORBIT_ELEVATION := 1.45
const CITY_DIR := "res://assets/game/lowpoly/cities/"
const CITY_PLAQUE_TEXTURE := preload("res://assets/game/ui/ui_hud_city_plaque_v1.png")
const WaterShader := preload("res://scripts/ui/shaders/planet_water.gdshader")
const AtmosphereShader := preload("res://scripts/ui/shaders/planet_atmosphere.gdshader")
const SpaceShader := preload("res://scripts/ui/shaders/planet_space.gdshader")
const CITY_VISUAL_OFFSET := Vector2(0.0, -85.0)

var legal_nodes: Dictionary = {}
var selected_path: Array = []
var input_enabled := true
var animating := false
var test_duration_override := -1.0
var test_move_speed_px_per_second := -1.0
var test_min_move_seconds := -1.0
var _formal_world_mode := false
var _selection_mode := false
var _legacy: Control
var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _world: Node3D
var _camera: Camera3D
var _sun: DirectionalLight3D
var _fill: DirectionalLight3D
var _space_material: ShaderMaterial
var _static_root: Node3D
var _piece_root: Node3D
var _ambient: Node3D
var _corridor: Node3D
var _highlight: MeshInstance3D
var _labels: Control
var _hint: Label
var _tooltip: PanelContainer
var _tooltip_text: Label
var _diagnostic: Label
var _city_visuals: Dictionary = {}
var _pieces: Dictionary = {}
var _routes: Dictionary = {}
var _markers: Array[Dictionary] = []
var _marker_batch: MultiMeshInstance3D
var _route_render_stats: Dictionary = {}
var _missing_assets: Array[String] = []
## One active visual per player. Replacing an actor's animation cancels the old
## one without emitting completion, so counting requests would leave a stale lock.
var _active_animations: Dictionary = {}
var _right_safe_inset := 0.0
var _camera_center := Vector3.ZERO
var _camera_yaw := 0.0
var _camera_elevation := 0.18
var _camera_distance := 40.0
var _overview_distance := 40.0
var _zoom := 1.0
var _press_point := Vector2.ZERO
var _last_pointer := Vector2.ZERO
var _button_down := 0
var _dragged := false
var _hover_node := ""
var _hover_city := ""
var _hover_path: Array = []
var _state_rebuilds := 0
var _loaded_ruleset := ""
var _warning_signature := ""
var _rendering_enabled := true
var _follow_player_id := ""
var _follow_logical_position := Vector2.INF


func _ready() -> void:
	# Actors advance at the default priority; a following camera reads their new
	# position afterwards, without adding a one-frame lag to movement.
	process_priority = 1
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_on_resized)
	visibility_changed.connect(_sync_render_activity)
	mouse_exited.connect(_clear_hover)
	GameState.state_changed.connect(_on_state_changed)
	if not GameState.content.is_empty():
		reload_for_current_game()
	set_process(false)


func _build_world() -> void:
	_viewport_container = SubViewportContainer.new()
	_viewport_container.name = "WorldViewportContainer"
	_viewport_container.stretch = true
	_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_viewport_container)
	_viewport = SubViewport.new()
	_viewport.name = "WorldViewport"
	_viewport.own_world_3d = true
	_viewport.handle_input_locally = false
	_viewport.gui_disable_input = true
	_viewport.msaa_3d = Viewport.MSAA_2X
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport_container.add_child(_viewport)
	_world = Node3D.new()
	_world.name = "LowpolyWorld"
	_viewport.add_child(_world)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("152d46")
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("5c86c8")
	sky_material.sky_horizon_color = Color("a9c4e6")
	sky_material.ground_horizon_color = Color("9fb0c4")
	sky_material.ground_bottom_color = Color("5a6a80")
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	settings.sky = sky
	# Local Compatibility A/B found SKY ambient washes out warm terrain. Keep
	# the calibrated color ambient; the cool sky still supplies water reflection.
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("e8dccb")
	settings.ambient_light_sky_contribution = 0.0
	settings.ambient_light_energy = 0.16
	settings.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	settings.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	settings.adjustment_enabled = true
	settings.adjustment_saturation = 1.15
	settings.adjustment_contrast = 1.05
	settings.adjustment_brightness = 1.0
	environment.environment = settings
	_world.add_child(environment)
	_sun = DirectionalLight3D.new()
	_sun.name = "WarmSun"
	_sun.light_color = Color("fff4e4")
	_sun.light_energy = 0.50
	_sun.shadow_enabled = true
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_sun.directional_shadow_max_distance = 70.0
	_sun.shadow_bias = 0.1
	_sun.shadow_normal_bias = 1.5
	_world.add_child(_sun)
	_fill = DirectionalLight3D.new()
	_fill.name = "CoolHemisphereFill"
	_fill.light_color = Color("d6ecff")
	_fill.light_energy = 0.08
	_fill.shadow_enabled = false
	_world.add_child(_fill)
	var atmosphere := MeshInstance3D.new()
	atmosphere.name = "ThinAtmosphereRim"
	var shell := SphereMesh.new()
	shell.radius = PlanetGeometry.RADIUS + 0.75
	shell.height = shell.radius * 2.0
	shell.radial_segments = 64
	shell.rings = 32
	atmosphere.mesh = shell
	atmosphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var rim_material := ShaderMaterial.new()
	rim_material.shader = AtmosphereShader
	rim_material.set_shader_parameter("planet_r", PlanetGeometry.RADIUS + 0.03)
	rim_material.set_shader_parameter("outer_r", shell.radius)
	atmosphere.material_override = rim_material
	_world.add_child(atmosphere)
	var backdrop := MeshInstance3D.new()
	backdrop.name = "SpaceBackdrop"
	var background_sphere := SphereMesh.new()
	background_sphere.radius = 120.0
	background_sphere.height = 240.0
	background_sphere.radial_segments = 48
	background_sphere.rings = 24
	backdrop.mesh = background_sphere
	backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_space_material = ShaderMaterial.new()
	_space_material.shader = SpaceShader
	backdrop.material_override = _space_material
	_world.add_child(backdrop)
	_camera = Camera3D.new()
	_camera.name = "BoardCamera"
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = CAMERA_FOV
	_camera.near = 0.1
	_camera.far = 200.0
	_camera.current = true
	_world.add_child(_camera)
	_static_root = Node3D.new()
	_static_root.name = "BoardAssets"
	_world.add_child(_static_root)
	_piece_root = Node3D.new()
	_piece_root.name = "Players"
	_world.add_child(_piece_root)
	_ambient = AmbientLayer.new()
	_ambient.name = "AmbientLayer"
	_world.add_child(_ambient)
	_corridor = CorridorLayer.new()
	_corridor.name = "CorridorProps"
	_world.add_child(_corridor)
	_highlight = MeshInstance3D.new()
	_highlight.name = "SelectedRoute"
	_highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(_highlight)
	_labels = Control.new()
	_labels.name = "MapLabels"
	_labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_labels.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_labels)
	_hint = _new_label("拖动旋转星球 · 滚轮缩放 · Q E 环绕 · F 跟随玩家 · R 整颗星球", 12)
	_hint.name = "CameraHelp"
	_hint.position = Vector2(18, 12)
	_hint.add_theme_color_override("font_color", Color("fff6df"))
	_hint.add_theme_color_override("font_shadow_color", Color("273b40"))
	_hint.add_theme_constant_override("shadow_offset_x", 1)
	_hint.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_hint)
	_diagnostic = _new_label("", 13)
	_diagnostic.name = "AssetDiagnostic"
	_diagnostic.position = Vector2(18, 34)
	_diagnostic.add_theme_color_override("font_color", Color("7c231b"))
	_diagnostic.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_diagnostic)
	_tooltip = PanelContainer.new()
	_tooltip.name = "CityMarketTooltip"
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.add_theme_stylebox_override("panel", _paper_style())
	_tooltip_text = _new_label("", 14)
	_tooltip_text.custom_minimum_size = Vector2(170, 0)
	_tooltip.add_child(_tooltip_text)
	_tooltip.visible = false
	add_child(_tooltip)
	_on_resized()


func _new_label(text: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	HudStyle.apply_body(label, HudStyle.INK_STRONG, font_size)
	return label


func _paper_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = HudStyle.PARCHMENT_LIGHT
	style.border_color = HudStyle.GOLD
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style


func reload_for_current_game() -> void:
	_cancel_camera_follow()
	cancel_all_animations()
	clear_selection()
	_loaded_ruleset = String(GameState.content.get("ruleset", {}).get("ruleset_id", ""))
	_formal_world_mode = _loaded_ruleset == "lshu_configurable_v1"
	if not _formal_world_mode:
		if _loaded_ruleset.is_empty():
			return
		if _legacy == null:
			_legacy = Control.new()
			_legacy.set_script(LegacyBoard)
			_legacy.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			add_child(_legacy)
			_legacy.node_clicked.connect(func(id: String): node_clicked.emit(id))
			_legacy.city_inspect_requested.connect(func(id: String): city_inspect_requested.emit(id))
			_legacy.move_animation_finished.connect(func(id: String): move_animation_finished.emit(id))
		_legacy.show()
		_legacy.set_map_safe_right_inset(_right_safe_inset)
		_legacy.reload_for_current_game()
		_set_world_ui_visible(false)
		return
	if _legacy != null:
		remove_child(_legacy)
		_legacy.queue_free()
		_legacy = null
	if _world == null:
		_build_world()
	_set_world_ui_visible(true)
	_clear_children(_piece_root)
	_pieces.clear()
	_rebuild_assets()
	_sync_pieces()
	reset_camera_to_fit()
	_sync_render_activity()


func _set_world_ui_visible(value: bool) -> void:
	for control in [_viewport_container, _labels, _hint, _diagnostic]:
		if control != null:
			control.visible = value
	if _tooltip != null:
		_tooltip.hide()
	_sync_render_activity()


func _rebuild_assets() -> void:
	_state_rebuilds += 1
	_clear_children(_static_root)
	_clear_children(_labels)
	_city_visuals.clear()
	_markers.clear()
	_marker_batch = null
	_route_render_stats.clear()
	_routes.clear()
	_missing_assets.clear()
	for kind in ["terrain", "water"]:
		var path := "res://assets/game/lowpoly/planet/%s.glb" % kind
		var asset := _load_model(path)
		if asset != null:
			_static_root.add_child(asset)
			if kind == "water":
				_apply_water_shader(asset)
			else:
				_enable_imported_vertex_colors(asset)
	for city_id_value in GameState.content.get("cities", {}):
		var city_id := String(city_id_value)
		var root := Node3D.new()
		root.name = "City_%s" % city_id
		var logical := _node_pos(city_id)
		root.position = PlanetGeometry.to_world(logical + CITY_VISUAL_OFFSET, GROUND_Y)
		root.basis = PlanetGeometry.basis_at(logical + CITY_VISUAL_OFFSET)
		_static_root.add_child(root)
		var model := _load_model(CITY_DIR + city_id + ".glb")
		if model == null:
			model = _city_diagnostic()
		root.add_child(model)
		var city_name := GameData.get_node_display_name(GameState.content, city_id)
		var tag := Control.new()
		tag.name = "CityPlaque_%s" % city_id
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_labels.add_child(tag)
		var plaque := NinePatchRect.new()
		plaque.name = "RedPlaque"
		plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
		plaque.texture = CITY_PLAQUE_TEXTURE
		plaque.patch_margin_left = 20
		plaque.patch_margin_right = 20
		plaque.patch_margin_top = 12
		plaque.patch_margin_bottom = 12
		tag.add_child(plaque)
		plaque.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var label := Label.new()
		label.name = "Label_%s" % city_id
		label.text = city_name
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		HudStyle.apply_heading(label, HudStyle.PARCHMENT_LIGHT, HudStyle.SIZE_CITY_PLAQUE)
		tag.add_child(label)
		tag.size = Vector2(clampf(label.get_minimum_size().x + 24.0, 72.0, 96.0), 25.0)
		label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		label.offset_left = 6.0
		label.offset_right = -6.0
		label.offset_top = 1.0
		label.offset_bottom = -1.0
		var bounds := _model_bounds(model)
		_city_visuals[city_id] = {"root": root, "model": model, "logical": logical,
			"tag": tag, "label": label, "bounds": bounds, "screen_rect": Rect2()}

	var route_polylines := {"LAND": [], "SEA": []}
	for edge_value in GameState.content.get("board_edges", []):
		var edge: Dictionary = edge_value
		var points: Array = edge.get("movement_polyline", edge.get("movement_polyline_px", []))
		var samples := PackedVector2Array()
		for point in points:
			samples.append(_vec2(point))
		_routes[String(edge.get("id", ""))] = samples
		route_polylines[String(edge.get("route_type", "LAND"))].append(samples)
	_create_route_batches(route_polylines)
	_create_route_markers()
	# Static corridor instances have their own cache and diagnostic contract.
	# A formal asset reload reconfigures them; normal state changes do not.
	_corridor.configure(GameState.content)
	# Environment is a sibling of the cached board and the actors. Reconfigure
	# only on a real asset rebuild; ordinary state changes leave its clock intact.
	_ambient.configure(GameState.content, CITY_VISUAL_OFFSET)
	_ambient.set_view(_camera, _zoom)
	_update_diagnostic()


func _apply_water_shader(asset: Node3D) -> void:
	var water_material := ShaderMaterial.new()
	water_material.shader = WaterShader
	for node in asset.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		mesh_instance.material_override = water_material


func _enable_imported_vertex_colors(asset: Node3D) -> void:
	# Godot 4.7 Compatibility does not enable this flag when importing glTF.
	# The exporter writes sRGB COLOR_0 and white albedo; do not linearize twice.
	for node in asset.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		# Oasis pools carry the same distance/depth data as the sea, at their
		# own terrain-following elevation. COLOR_0 here is data, not albedo.
		if String(mesh_instance.name).contains("oasis_pool"):
			var pool_material := ShaderMaterial.new()
			pool_material.shader = WaterShader
			mesh_instance.material_override = pool_material
			continue
		for index in range(mesh_instance.mesh.get_surface_count()):
			if not (mesh_instance.mesh.surface_get_format(index) & Mesh.ARRAY_FORMAT_COLOR):
				continue
			var source := mesh_instance.get_active_material(index) as StandardMaterial3D
			if source == null:
				continue
			var material := source.duplicate() as StandardMaterial3D
			material.vertex_color_use_as_albedo = true
			mesh_instance.set_surface_override_material(index, material)


func _load_model(path: String) -> Node3D:
	if ResourceLoader.exists(path):
		var packed := load(path) as PackedScene
		if packed != null:
			return packed.instantiate() as Node3D
	_missing_assets.append(path)
	return null


func _city_diagnostic() -> Node3D:
	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.7, 0.6, 0.7)
	mesh.mesh = box
	mesh.position.y = 0.3
	mesh.material_override = _material(Color("d5a157"))
	root.add_child(mesh)
	return root


func _update_diagnostic() -> void:
	if _diagnostic == null:
		return
	var paths := get_missing_asset_paths()
	_diagnostic.text = "正式对局已停用：缺少 %d 项 3D 资源。请修复资源后重新进入对局。\n%s" % [paths.size(), "\n".join(paths)] if not paths.is_empty() else ""
	if not paths.is_empty():
		_diagnostic.add_theme_stylebox_override("normal", _paper_style())
		input_enabled = false
		for actor in _pieces.values():
			actor.cancel_motion()
		_active_animations.clear()
		animating = false
		_clear_hover()
	else:
		_diagnostic.remove_theme_stylebox_override("normal")
	var signature := str(paths)
	if not paths.is_empty() and signature != _warning_signature:
		push_warning("LowpolyBoardView formal play disabled; missing assets: %s" % signature)
	_warning_signature = signature


func get_missing_asset_paths() -> Array[String]:
	var paths: Array[String] = _missing_assets.duplicate()
	if _corridor != null:
		for path in _corridor.get_missing_asset_paths():
			if not paths.has(path):
				paths.append(path)
	for actor in _pieces.values():
		for path in actor.missing_models:
			if not paths.has(path):
				paths.append(path)
	return paths


## Shared by the GameScreen HUD/AI gate as well as local input. Explicit Demo
## uses its own assets and must not inherit a previous formal asset failure.
func is_ready_for_play() -> bool:
	return not _formal_world_mode or (_world != null and get_missing_asset_paths().is_empty())


func _material(color: Color, unshaded: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.9
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _ribbon_mesh(points: PackedVector2Array, width: float, height: float) -> ArrayMesh:
	return RouteGeometry.create_mesh(points, width, height)


func _route_half_width(route_type: String) -> float:
	return LAND_ROUTE_HALF_WIDTH if route_type == "LAND" else SEA_ROUTE_HALF_WIDTH


func _route_height(_route_type: String) -> float:
	# Navigation ribbons also cross the short shore approach to a shared city
	# seat. Both modes clear the protected port ground (radius <= 11.08).
	return ROUTE_Y


func _create_route_batches(polylines: Dictionary) -> void:
	for route_type in ["LAND", "SEA"]:
		var geometry := RouteGeometry.build_geometry(polylines[route_type],
			_route_half_width(route_type), _route_height(route_type))
		var line := MeshInstance3D.new()
		line.name = "RouteBatch_" + route_type
		line.mesh = RouteGeometry.mesh_from_geometry(geometry)
		line.material_override = _material(Color("ead5ac") if route_type == "LAND" else Color("65a7d8"), true)
		line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_static_root.add_child(line)
		_route_render_stats[route_type] = {"full_width": _route_half_width(route_type) * 2.0,
			"polyline_count": geometry["polyline_count"], "sample_count": geometry["sample_count"],
			"miter_join_count": geometry["miter_join_count"], "bevel_join_count": geometry["bevel_join_count"],
			"vertices": geometry["positions"].size(), "triangles": geometry["indices"].size() / 3,
			"surfaces": line.mesh.get_surface_count()}


func _create_route_markers() -> void:
	for node_id_value in GameState.content.get("board_nodes", {}):
		var node_id := String(node_id_value)
		for anchor in _node_visual_anchors(node_id):
			var route_type: String = anchor["route_type"]
			var radius := LAND_MARKER_RADIUS if route_type == "LAND" else SEA_MARKER_RADIUS
			var basis := PlanetGeometry.basis_at(anchor["position"]) * Basis.from_scale(Vector3(radius, 1, radius))
			var position := PlanetGeometry.to_world(anchor["position"], _route_height(route_type) + MARKER_HEIGHT)
			_markers.append({"node_id": node_id, "route_type": route_type, "route_types": anchor["route_types"],
				"transform": Transform3D(basis, position), "base_color": Color("98534c") if route_type == "LAND" else Color("275577")})
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.014
	disc.radial_segments = 12
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.use_colors = true
	instances.mesh = disc
	instances.instance_count = _markers.size()
	_marker_batch = MultiMeshInstance3D.new()
	_marker_batch.name = "RouteStops"
	_marker_batch.multimesh = instances
	var material := _material(Color.WHITE, true)
	material.vertex_color_use_as_albedo = true
	_marker_batch.material_override = material
	_marker_batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_static_root.add_child(_marker_batch)
	_update_markers()


func _model_bounds(model: Node3D) -> AABB:
	var bounds := AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 0.8, 1))
	var found := false
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.mesh == null:
			continue
		var local_transform := model.global_transform.affine_inverse() * mesh.global_transform
		var aabb: AABB = local_transform * mesh.get_aabb()
		bounds = bounds.merge(aabb) if found else aabb
		found = true
	return bounds


func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func _sync_pieces() -> void:
	if _piece_root == null:
		return
	var seen := {}
	for player in GameState.players:
		seen[player.player_id] = true
		if not _pieces.has(player.player_id):
			var actor := PieceActor.new()
			_piece_root.add_child(actor)
			var player_color := Color("b54d36")
			for choice in GameData.get_player_colors(GameState.content):
				if choice.get("id", "") == player.color_id:
					player_color = Color(String(choice.get("color", "b54d36")))
			actor.setup(player.player_id, player.is_local_human(), player.active_transport, player_color)
			actor.move_finished.connect(_on_piece_finished)
			_pieces[player.player_id] = actor
		var actor: Node3D = _pieces[player.player_id]
		if not actor.is_animating():
			actor.set_transport(player.active_transport)
			actor.set_logical_position(_node_route_pos(player.current_node_id,
				_route_name(player.active_transport)))
	for id in _pieces.keys():
		if not seen.has(id):
			_pieces[id].queue_free()
			_pieces.erase(id)
			_active_animations.erase(id)
	animating = not _active_animations.is_empty()
	_update_diagnostic()
	_update_follow_camera()
	_sync_follow_processing()


func _on_state_changed() -> void:
	if not _formal_world_mode or _world == null:
		return
	if GameState.phase == GameState.Phase.GAME_OVER:
		_cancel_camera_follow()
	if GameState.players.is_empty():
		_cancel_camera_follow()
		cancel_all_animations()
		_clear_children(_piece_root)
		_pieces.clear()
		return
	_sync_pieces()
	refresh_visible_trade_card()


func set_input_enabled(enabled: bool) -> void:
	input_enabled = enabled and not animating and is_ready_for_play()
	if _using_legacy():
		_legacy.set_input_enabled(enabled)


func set_selection_mode(enabled: bool) -> void:
	_selection_mode = enabled
	if _using_legacy():
		_legacy.set_selection_mode(enabled)


func set_legal_nodes(nodes: Dictionary) -> void:
	legal_nodes = nodes.duplicate()
	if _using_legacy():
		_legacy.set_legal_nodes(nodes)
	else:
		_update_markers()


func set_selected_path(path: Array) -> void:
	selected_path = path.duplicate()
	if _using_legacy():
		_legacy.set_selected_path(path)
	else:
		_update_highlight()


func clear_selection() -> void:
	legal_nodes.clear()
	selected_path.clear()
	_clear_hover()
	if _using_legacy():
		_legacy.clear_selection()
	else:
		_update_markers()
		_update_highlight()


func _using_legacy() -> bool:
	return not _formal_world_mode and is_instance_valid(_legacy)


func is_animating() -> bool:
	return _legacy.is_animating() if _using_legacy() else animating


func get_move_speed() -> float:
	return test_move_speed_px_per_second if test_move_speed_px_per_second > 0.0 else MOVE_SPEED


func get_min_move_seconds() -> float:
	return test_min_move_seconds if test_min_move_seconds >= 0.0 else MIN_MOVE_SECONDS


func play_visual_move(visual: Dictionary) -> void:
	if _using_legacy():
		_legacy.test_duration_override = test_duration_override
		_legacy.play_visual_move(visual)
		return
	if not is_ready_for_play():
		_update_diagnostic()
		return
	var id := String(visual.get("player_id", ""))
	_sync_pieces()
	if not is_ready_for_play():
		return
	if not _pieces.has(id):
		move_animation_finished.emit(id)
		return
	var transport := int(visual.get("transport", GameData.Transport.CAMEL))
	var route_type := _route_name(transport)
	var path: Array = visual.get("path", [])
	var built := _build_path(path, route_type)
	var actor: Node3D = _pieces[id]
	actor.set_transport(transport)
	if built["samples"].size() < 2:
		actor.cancel_motion()
		_active_animations.erase(id)
		animating = not _active_animations.is_empty()
		actor.set_logical_position(_node_route_pos(String(visual.get("to_node_id", "")), route_type))
		move_animation_finished.emit(id)
		return
	animating = true
	_active_animations[id] = true
	actor.test_duration_override = test_duration_override
	actor.play_path(built["samples"], built["cum"], built["total"],
		estimated_move_seconds(visual), built["breaks"], path.slice(1, path.size() - 1))
	_update_follow_camera()
	_sync_follow_processing()


func estimated_move_seconds(visual: Dictionary) -> float:
	if _using_legacy():
		_legacy.test_duration_override = test_duration_override
		return _legacy.estimated_move_seconds(visual)
	var path: Array = visual.get("path", [])
	if path.size() < 2:
		return 0.0
	if test_duration_override > 0.0:
		return test_duration_override
	var built := _build_path(path, _route_name(int(visual.get("transport", 0))))
	return maxf(float(built["total"]) / get_move_speed(), get_min_move_seconds())


func play_transport_switch_visual(id: String, from_transport: int, to_transport: int) -> void:
	if _using_legacy():
		_legacy.play_transport_switch_visual(id, from_transport, to_transport)
		return
	if not is_ready_for_play():
		_update_diagnostic()
		return
	_sync_pieces()
	if not is_ready_for_play():
		return
	for player in GameState.players:
		if player.player_id == id and _pieces.has(id):
			animating = true
			_active_animations[id] = true
			_pieces[id].play_transport_switch(
				_node_route_pos(player.current_node_id, _route_name(from_transport)),
				_node_route_pos(player.current_node_id, _route_name(to_transport)),
				from_transport, to_transport, estimated_transport_switch_seconds())
			_update_follow_camera()
			_sync_follow_processing()
			return
	move_animation_finished.emit(id)


func estimated_transport_switch_seconds() -> float:
	return _legacy.estimated_transport_switch_seconds() if _using_legacy() else SWITCH_SECONDS


func _on_piece_finished(id: String) -> void:
	if not _active_animations.has(id):
		return
	_active_animations.erase(id)
	animating = not _active_animations.is_empty()
	_sync_pieces()
	move_animation_finished.emit(id)


func cancel_all_animations() -> void:
	if _legacy != null:
		_legacy.cancel_all_animations()
	for actor in _pieces.values():
		actor.cancel_motion()
	animating = false
	_active_animations.clear()
	if is_inside_tree() and _formal_world_mode:
		_sync_pieces()


func _build_path(path: Array, route_type: String) -> Dictionary:
	var samples := PackedVector2Array()
	var breaks := PackedFloat32Array()
	var cumulative := PackedFloat32Array()
	var total := 0.0
	for index in range(1, path.size()):
		var a := String(path[index - 1])
		var b := String(path[index])
		var points := PackedVector2Array()
		var route_enum := GameData.RouteType.LAND if route_type == "LAND" else GameData.RouteType.SEA
		for edge in GameData.get_edges_from(GameState.content, a, route_enum):
			if GameData.edge_other_node(edge, a) == b:
				points = _routes.get(String(edge.get("id", "")), PackedVector2Array()).duplicate()
				break
		if points.size() < 2:
			points = PackedVector2Array([_node_route_pos(a, route_type), _node_route_pos(b, route_type)])
		if points[0].distance_to(_node_route_pos(a, route_type)) > points[-1].distance_to(_node_route_pos(a, route_type)):
			points.reverse()
		for point in points:
			if not samples.is_empty():
				var distance := samples[-1].distance_to(point)
				if distance < 0.001:
					continue
				total += distance
			samples.append(point)
			cumulative.append(total)
		if index < path.size() - 1:
			breaks.append(total)
	return {"samples": samples, "cum": cumulative, "total": total, "breaks": breaks}


func _update_markers() -> void:
	if _marker_batch == null:
		return
	var route_type := _current_route_type()
	var instances := _marker_batch.multimesh
	for index in _markers.size():
		var entry: Dictionary = _markers[index]
		var legal: bool = legal_nodes.has(entry["node_id"]) and route_type in entry["route_types"]
		var base: Transform3D = entry["transform"]
		var scale := LEGAL_MARKER_SCALE if legal else 1.0
		instances.set_instance_transform(index, Transform3D(base.basis * Basis.from_scale(Vector3(scale, 1, scale)), base.origin))
		instances.set_instance_color(index, Color("94ed8b") if legal else entry["base_color"])


func _update_highlight() -> void:
	if _highlight == null:
		return
	var path := selected_path if not selected_path.is_empty() else _hover_path
	var built := _build_path(path, _current_route_type())
	var route_type := _current_route_type()
	_highlight.mesh = _ribbon_mesh(built["samples"], _route_half_width(route_type) + SELECTED_ROUTE_EXTRA_WIDTH,
		_route_height(route_type) + SELECTED_ROUTE_HEIGHT)
	_highlight.material_override = _material(Color("f97835"), true)


func _node_pos(id: String) -> Vector2:
	var node: Dictionary = GameState.content.get("board_nodes", {}).get(id, {})
	return _vec2(node.get("map_position", [0, 0]))


func _node_route_pos(id: String, route_type: String) -> Vector2:
	var node: Dictionary = GameState.content.get("board_nodes", {}).get(id, {})
	var anchors: Dictionary = node.get("route_anchors", {})
	return _vec2(anchors.get(route_type, node.get("map_position", [0, 0])))


func _node_visual_anchors(id: String) -> Array[Dictionary]:
	var node: Dictionary = GameState.content.get("board_nodes", {}).get(id, {})
	var result: Array[Dictionary] = []
	for route_type in node.get("allowed_routes", []):
		var position := _node_route_pos(id, String(route_type))
		var merged := false
		for anchor in result:
			if (anchor["position"] as Vector2).distance_to(position) <= 0.01:
				anchor["route_types"].append(String(route_type))
				merged = true
				break
		if not merged:
			result.append({"route_type": String(route_type), "route_types": [String(route_type)], "position": position})
	return result


func _interaction_node_pos(id: String) -> Vector2:
	return _node_route_pos(id, _current_route_type())


func _current_route_type() -> String:
	return _route_name(GameState.current_player().active_transport) if not GameState.players.is_empty() else "LAND"


func _route_name(transport: int) -> String:
	return "LAND" if transport == GameData.Transport.CAMEL else "SEA"


func _vec2(value: Variant) -> Vector2:
	return value if value is Vector2 else Vector2(float(value[0]), float(value[1]))


func set_map_safe_right_inset(pixels: float) -> void:
	_right_safe_inset = maxf(pixels, 0.0)
	if _using_legacy():
		_legacy.set_map_safe_right_inset(pixels)
	else:
		_apply_camera_transform()


func reset_camera_to_fit() -> void:
	_cancel_camera_follow()
	if _using_legacy():
		_legacy.reset_camera_to_fit()
		return
	# Show a complete circular silhouette on entry and on R. The usable viewport
	# excludes the HUD, so the planet is centered in the area players can explore.
	_zoom = 1.0
	_camera_yaw = 0.0
	_camera_elevation = 0.18
	_camera_center = Vector3.ZERO
	_clear_hover()
	_apply_camera_transform()


func focus_current_player() -> void:
	if _using_legacy():
		_legacy.reset_camera_to_fit()
		return
	if GameState.players.is_empty():
		reset_camera_to_fit()
		return
	var player := GameState.current_player()
	focus_logical_point(_node_route_pos(player.current_node_id, _route_name(player.active_transport)))
	if GameState.phase == GameState.Phase.GAME_OVER:
		return
	_follow_player_id = player.player_id
	_follow_logical_position = Vector2.INF
	_update_follow_camera(true)
	_sync_follow_processing()


func focus_logical_point(logical: Vector2, absolute_zoom: float = 2.6) -> void:
	_cancel_camera_follow()
	if not logical.is_finite():
		return
	if _using_legacy():
		return
	_aim_camera_at_logical(logical)
	_zoom = clampf(absolute_zoom, MIN_ZOOM, MAX_ZOOM)
	_clear_hover()
	_apply_camera_transform()


func _aim_camera_at_logical(logical: Vector2) -> void:
	var normal := PlanetGeometry.to_world(logical, 0.0).normalized()
	_camera_yaw = atan2(normal.x, normal.z)
	_camera_elevation = clampf(asin(normal.y), -MAX_ORBIT_ELEVATION, MAX_ORBIT_ELEVATION)


func _cancel_camera_follow() -> void:
	_follow_player_id = ""
	_follow_logical_position = Vector2.INF
	set_process(false)


func _sync_follow_processing() -> void:
	var actor: Node3D = _pieces.get(_follow_player_id)
	# Idle followers need no frame callback. A move/switch starts processing;
	# its completion, hiding the board or canceling follow stops it again.
	set_process(is_visible_in_tree() and _formal_world_mode and is_instance_valid(actor)
		and actor.is_animating() and GameState.phase != GameState.Phase.GAME_OVER)


func _update_follow_camera(force: bool = false) -> void:
	if _follow_player_id.is_empty():
		return
	var actor: Node3D = _pieces.get(_follow_player_id)
	if not is_instance_valid(actor) or GameState.phase == GameState.Phase.GAME_OVER:
		_cancel_camera_follow()
		return
	var logical: Vector2 = actor.logical_pos
	if not logical.is_finite():
		return
	if not force and logical.is_equal_approx(_follow_logical_position):
		return
	_follow_logical_position = logical
	_aim_camera_at_logical(logical)
	_apply_camera_transform()


func _process(_delta: float) -> void:
	_update_follow_camera()
	_sync_follow_processing()


func zoom_factor_is_default() -> bool:
	return is_equal_approx(_zoom, 1.0)


func _on_resized() -> void:
	if _viewport == null:
		return
	# With stretch=true the container owns its SubViewport's dimensions.
	_diagnostic.size.x = maxf(100.0, size.x - _right_safe_inset - 36.0)
	_apply_camera_transform()


func _camera_direction() -> Vector3:
	return Vector3(sin(_camera_yaw) * cos(_camera_elevation),
		sin(_camera_elevation), cos(_camera_yaw) * cos(_camera_elevation))


func _apply_camera_transform() -> void:
	if _camera == null or size.y <= 1.0:
		return
	_camera_elevation = clampf(_camera_elevation, -MAX_ORBIT_ELEVATION, MAX_ORBIT_ELEVATION)
	_camera_yaw = wrapf(_camera_yaw, -PI, PI)
	_camera_center = Vector3.ZERO
	var visible_radius := PlanetGeometry.RADIUS + 2.1
	var focal_pixels := size.y / (2.0 * tan(deg_to_rad(CAMERA_FOV * 0.5)))
	var usable_width := maxf(120.0, size.x - _right_safe_inset - 64.0)
	var usable_height := maxf(120.0, size.y - 88.0)
	var half_extent := minf(usable_width, usable_height) * 0.5
	# Exact tangent-circle framing for a sphere under perspective projection.
	_overview_distance = sqrt(visible_radius * visible_radius + pow(visible_radius * focal_pixels / half_extent, 2.0))
	_camera_distance = PlanetGeometry.RADIUS + (_overview_distance - PlanetGeometry.RADIUS) / _zoom
	var right := Vector3(cos(_camera_yaw), 0.0, -sin(_camera_yaw))
	var direction := _camera_direction()
	var up := direction.cross(right).normalized()
	# An overview centers the sphere, while a close view centers its front surface.
	# Using the sphere-center depth at high zoom would push the focused player
	# left under perspective, especially when the HUD reserves a wide inset.
	var framing_radius := (PlanetGeometry.RADIUS + ROUTE_Y) * clampf((_zoom - 1.0) / 1.2, 0.0, 1.0)
	var units_per_pixel := (_camera_distance - framing_radius) / focal_pixels
	var target := right * _right_safe_inset * 0.5 * units_per_pixel
	_camera.position = direction * _camera_distance + target
	_camera.look_at(target, up)
	_update_camera_lighting(right, up, direction)
	_update_space_backdrop()
	if _ambient != null:
		_ambient.set_view(_camera, _zoom)
	_update_projected_labels()


func _update_camera_lighting(right: Vector3, up: Vector3, direction: Vector3) -> void:
	if _sun == null or _fill == null:
		return
	# Keep the warm key above-left and the terminator below-right on every
	# hemisphere. This is a presentation rig, independent of game time and RNG.
	const SUN_LEFT := 0.49
	const SUN_ABOVE := 0.80
	var sun_from := (-right * sin(SUN_LEFT) * cos(SUN_ABOVE) + up * sin(SUN_ABOVE)
		+ direction * cos(SUN_LEFT) * cos(SUN_ABOVE)).normalized()
	_sun.global_transform = Transform3D(Basis.looking_at(-sun_from, up), Vector3.ZERO)
	var fill_from := (right * 0.62 - up * 0.50 - direction * 0.20).normalized()
	_fill.global_transform = Transform3D(Basis.looking_at(-fill_from, up), Vector3.ZERO)


func _update_space_backdrop() -> void:
	if _space_material == null or _viewport == null:
		return
	var viewport_size := Vector2(_viewport.size).max(Vector2.ONE)
	var planet_uv := Vector2(0.5, 0.5)
	if not _camera.is_position_behind(Vector3.ZERO):
		var projected := _camera.unproject_position(Vector3.ZERO) / viewport_size
		if projected.is_finite():
			planet_uv = projected
	_space_material.set_shader_parameter("planet_uv", planet_uv)
	_space_material.set_shader_parameter("aspect", viewport_size.x / viewport_size.y)


func world_to_screen(logical: Vector2) -> Vector2:
	if _using_legacy():
		return _legacy.world_to_screen(logical)
	return _project(PlanetGeometry.to_world(logical, ROUTE_Y))


func logical_to_screen(logical: Vector2) -> Vector2:
	return world_to_screen(logical)


func _project(point: Vector3) -> Vector2:
	if _camera == null or _viewport.size.x < 1 or _viewport.size.y < 1:
		return Vector2.INF
	var viewport_point := _camera.unproject_position(point)
	return viewport_point * size / Vector2(_viewport.size)


func is_logical_point_visible(logical: Vector2, height: float = ROUTE_Y) -> bool:
	return _surface_point_visible(PlanetGeometry.to_world(logical, height))


func _surface_point_visible(point: Vector3) -> bool:
	if _camera == null or _camera.is_position_behind(point):
		return false
	# The far hemisphere must never expose labels or clickable route anchors.
	return point.normalized().dot(_camera.global_position - point) > 0.02


func screen_to_world(screen: Vector2) -> Vector2:
	if _using_legacy():
		return _legacy.screen_to_world(screen)
	var point := _ground_at(screen)
	if not point.is_finite():
		return Vector2.INF
	return PlanetGeometry.logical_from_world(point)


func _ground_at(screen: Vector2) -> Vector3:
	if _camera == null:
		return Vector3.INF
	var pixel := screen * Vector2(_viewport.size) / size.max(Vector2.ONE)
	var origin := _camera.project_ray_origin(pixel)
	var direction := _camera.project_ray_normal(pixel)
	return PlanetGeometry.ray_intersection(origin, direction, ROUTE_Y)


func _rotate_camera_between(from_normal: Vector3, to_normal: Vector3) -> void:
	var orbit_rotation := Quaternion(from_normal.normalized(), to_normal.normalized())
	var direction := (orbit_rotation * _camera_direction()).normalized()
	_camera_yaw = atan2(direction.x, direction.z)
	_camera_elevation = clampf(asin(direction.y), -MAX_ORBIT_ELEVATION, MAX_ORBIT_ELEVATION)


func zoom_immediate_around(screen: Vector2, absolute_zoom: float) -> void:
	if _using_legacy():
		_legacy.zoom_immediate_around(screen, absolute_zoom)
		return
	var before := _ground_at(screen)
	_zoom = clampf(absolute_zoom, MIN_ZOOM, MAX_ZOOM)
	_apply_camera_transform()
	# Keep the place under the cursor steady while zooming. A miss over space
	# zooms toward the current hemisphere and never injects invalid coordinates.
	if before.is_finite():
		for iteration in range(2):
			var after := _ground_at(screen)
			if not after.is_finite():
				break
			_rotate_camera_between(after, before)
			_apply_camera_transform()
	_clear_hover()
	_update_follow_camera(true)


func _update_projected_labels() -> void:
	if _camera == null:
		return
	var usable_rect := Rect2(Vector2.ZERO, Vector2(maxf(0.0, size.x - _right_safe_inset), size.y))
	for city_id in _city_visuals:
		var entry: Dictionary = _city_visuals[city_id]
		var root: Node3D = entry["root"]
		var label: Label = entry["label"]
		var tag: Control = entry["tag"]
		var bounds: AABB = entry["bounds"]
		var surface_visible := _surface_point_visible(root.global_position)
		entry["front_facing"] = surface_visible
		if not surface_visible:
			entry["screen_rect"] = Rect2()
			tag.hide()
			label.hide()
			continue
		var screen_rect := Rect2()
		for index in range(8):
			var point := _project(root.global_transform * bounds.get_endpoint(index))
			screen_rect = Rect2(point, Vector2.ZERO) if index == 0 else screen_rect.expand(point)
		entry["screen_rect"] = screen_rect
		var anchor := Vector2(screen_rect.get_center().x, screen_rect.end.y + 4.0)
		tag.position = anchor - Vector2(tag.size.x * 0.5, 0.0)
		tag.position.x = clampf(tag.position.x, 4.0, maxf(4.0, usable_rect.size.x - tag.size.x - 4.0))
		var plaque_visible := usable_rect.grow(8.0).has_point(anchor)
		tag.visible = plaque_visible
		label.visible = plaque_visible
		label.add_theme_color_override("font_color", HudStyle.TOPBAR_GOLD_TEXT if city_id == _hover_city else HudStyle.PARCHMENT_LIGHT)
	if not _hover_city.is_empty():
		if not bool(_city_visuals.get(_hover_city, {}).get("front_facing", false)):
			_hover_city = ""
			_hover_node = ""
			_hover_path.clear()
			if _tooltip != null:
				_tooltip.hide()
		else:
			_position_tooltip()


func _gui_input(event: InputEvent) -> void:
	if not _formal_world_mode or _camera == null:
		return
	if event is InputEventMagnifyGesture:
		zoom_immediate_around(get_local_mouse_position(), _zoom * event.factor)
		accept_event()
	elif event is InputEventPanGesture:
		_pan(Vector2(size * 0.5), Vector2(size * 0.5) + event.delta * 8.0)
		accept_event()
	elif event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.pressed and mouse.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			zoom_immediate_around(mouse.position, _zoom * (1.1 if mouse.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.1))
			accept_event()
		elif mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
			if mouse.pressed:
				_button_down = mouse.button_index
				_press_point = mouse.position
				_last_pointer = mouse.position
				_dragged = false
			else:
				if _button_down == MOUSE_BUTTON_LEFT and not _dragged:
					_dispatch_click(mouse.position)
				_button_down = 0
				_dragged = false
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _button_down != 0:
			_dragged = _dragged or motion.position.distance_to(_press_point) >= DRAG_THRESHOLD
			if _dragged:
				_clear_hover()
				_pan(_last_pointer, motion.position)
			_last_pointer = motion.position
		else:
			_last_pointer = motion.position
			_update_hover(motion.position)


func _pan(previous: Vector2, current: Vector2) -> void:
	_cancel_camera_follow()
	# Drag the globe as an object. Surface grabs use an arcball; dragging empty
	# space still orbits predictably, so every hemisphere remains reachable.
	var before := _ground_at(previous)
	var after := _ground_at(current)
	if before.is_finite() and after.is_finite():
		_rotate_camera_between(after, before)
	else:
		var delta := current - previous
		_camera_yaw -= delta.x * 0.006 / sqrt(_zoom)
		_camera_elevation += delta.y * 0.005 / sqrt(_zoom)
	_apply_camera_transform()


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not _formal_world_mode or _camera == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_Q:
				_cancel_camera_follow()
				_camera_yaw += PI / 12.0
			KEY_E:
				_cancel_camera_follow()
				_camera_yaw -= PI / 12.0
			KEY_R, KEY_HOME:
				reset_camera_to_fit()
			KEY_F:
				focus_current_player()
			KEY_EQUAL, KEY_KP_ADD:
				zoom_immediate_around(size * 0.5, _zoom * 1.1)
			KEY_MINUS, KEY_KP_SUBTRACT:
				zoom_immediate_around(size * 0.5, _zoom / 1.1)
			_:
				return
		_clear_hover()
		_apply_camera_transform()
		get_viewport().set_input_as_handled()


func _legal_node_at(point: Vector2) -> String:
	var closest := ""
	var distance := HIT_RADIUS
	for id in legal_nodes:
		if not is_logical_point_visible(_interaction_node_pos(String(id))):
			continue
		if not GameState.players.is_empty() and id == GameState.current_player().current_node_id:
			continue
		var candidate := point.distance_to(world_to_screen(_interaction_node_pos(String(id))))
		if candidate < distance:
			distance = candidate
			closest = String(id)
	return closest


func _city_at(point: Vector2) -> String:
	var closest := ""
	var distance := INF
	for id in _city_visuals:
		var entry: Dictionary = _city_visuals[id]
		if not bool(entry.get("front_facing", false)):
			continue
		var tag: Control = entry["tag"]
		var rect: Rect2 = entry["screen_rect"]
		var label_rect := Rect2(tag.position, tag.size)
		if (tag.visible and label_rect.has_point(point)) or rect.grow(6.0).has_point(point):
			var candidate := point.distance_squared_to(rect.get_center())
			if candidate < distance:
				distance = candidate
				closest = String(id)
	return closest


func _pointer_target_at(point: Vector2) -> Dictionary:
	if not Rect2(Vector2.ZERO, Vector2(maxf(0.0, size.x - _right_safe_inset), size.y)).has_point(point):
		return {}
	if not is_ready_for_play():
		return {}
	if _selection_mode and input_enabled and not animating:
		var legal := _legal_node_at(point)
		if not legal.is_empty():
			return {"kind": "node", "id": legal}
	var city := _city_at(point)
	if not city.is_empty():
		if _selection_mode and input_enabled and not animating and legal_nodes.has(city) and is_logical_point_visible(_interaction_node_pos(city)):
			return {"kind": "node", "id": city}
		return {"kind": "city", "id": city}
	return {}


func _dispatch_click(point: Vector2) -> void:
	var target := _pointer_target_at(point)
	if target.get("kind", "") == "node":
		node_clicked.emit(String(target["id"]))
	elif target.get("kind", "") == "city" and not _selection_mode:
		city_inspect_requested.emit(String(target["id"]))


func _update_hover(point: Vector2) -> void:
	if not is_ready_for_play():
		_clear_hover()
		return
	var target := _pointer_target_at(point)
	_hover_node = String(target.get("id", ""))
	_hover_city = _city_at(point)
	_hover_path.clear()
	if target.get("kind", "") == "node" and input_enabled and not GameState.players.is_empty():
		var player := GameState.current_player()
		_hover_path = MovementSystem.find_path(player, _hover_node, player.movement_budget)
		_tooltip_text.text = "%s · %d 步" % [GameData.get_node_display_name(GameState.content, _hover_node), int(legal_nodes.get(_hover_node, 0))]
		_tooltip.show()
	elif not _hover_city.is_empty():
		refresh_visible_trade_card()
	else:
		_tooltip.hide()
	_update_highlight()
	_update_projected_labels()
	_position_tooltip()
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not _hover_node.is_empty() else Control.CURSOR_ARROW


func _clear_hover() -> void:
	_hover_node = ""
	_hover_city = ""
	_hover_path.clear()
	if _tooltip != null:
		_tooltip.hide()
	_update_highlight()
	_update_projected_labels()
	mouse_default_cursor_shape = Control.CURSOR_ARROW


func refresh_visible_trade_card() -> void:
	if _using_legacy():
		_legacy.refresh_visible_trade_card()
		return
	if _hover_city.is_empty() or _tooltip == null:
		return
	var lines: Array[String] = [GameData.get_node_display_name(GameState.content, _hover_city)]
	var market: Dictionary = GameState.city_market_states.get(_hover_city, {})
	if not bool(market.get("trade_route_open", false)):
		lines.append("尚未开通商道 · 首次抵达 +2 银")
	else:
		var card := TradeSystem.get_trade_card_for_city(_hover_city)
		var entries: Array = card.get("entries", [])
		for entry in entries:
			var name := "白银" if entry.get("resource_kind", "") == "SILVER" else GameData.get_good_name(GameState.content, String(entry.get("resource_id", "")))
			lines.append("%s × %d" % [name, int(entry.get("quantity", 0))])
		if entries.is_empty():
			lines.append("暂无贸易卡")
	lines.append("点击建筑或城市名，查看城市图鉴" if not _selection_mode else "绿色节点为本回合可达位置")
	_tooltip_text.text = "\n".join(lines)
	_tooltip.show()
	_position_tooltip()


func _position_tooltip() -> void:
	if _tooltip == null or not _tooltip.visible:
		return
	_tooltip.reset_size()
	var x_max := maxf(8.0, size.x - _right_safe_inset - _tooltip.size.x - 8.0)
	_tooltip.position = Vector2(clampf(_last_pointer.x + 18, 8.0, x_max),
		clampf(_last_pointer.y + 18, 8.0, maxf(8.0, size.y - _tooltip.size.y - 8.0)))


func _sync_render_activity() -> void:
	if _viewport == null:
		return
	var active := is_visible_in_tree() and _formal_world_mode
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active and _rendering_enabled else SubViewport.UPDATE_DISABLED
	_world.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	_sync_follow_processing()
	if active:
		_update_follow_camera()
	if not active:
		_clear_hover()


## Rendering can be suppressed independently of animation/control flow, e.g. by
## headless full-game tests. Hiding the board still suspends the complete 3D world.
func set_rendering_enabled(enabled: bool) -> void:
	_rendering_enabled = enabled
	_sync_render_activity()


func get_route_polyline(edge_id: String) -> PackedVector2Array:
	return _legacy.get_route_polyline(edge_id) if _using_legacy() else _routes.get(edge_id, PackedVector2Array())


func get_map_debug_state() -> Dictionary:
	if _using_legacy():
		return _legacy.get_map_debug_state()
	var city_state := {}
	for id in _city_visuals:
		var entry: Dictionary = _city_visuals[id]
		var label: Label = entry["label"]
		city_state[id] = {"base": entry["logical"], "screen": world_to_screen(entry["logical"]),
			"building_screen_rect": entry["screen_rect"], "plaque_global": (entry["tag"] as Control).get_global_rect(),
			"front_facing": entry.get("front_facing", false), "label_visible": label.visible,
			"position_3d": entry["root"].position, "up_direction": entry["root"].basis.y}
	var piece_state := {}
	for id in _pieces:
		var actor: Node3D = _pieces[id]
		piece_state[id] = {"world_position": actor.logical_pos, "position_3d": actor.position,
			"screen_position": world_to_screen(actor.logical_pos), "visible": actor.visible and is_logical_point_visible(actor.logical_pos),
			"animating": actor.is_animating()}
	return {"renderer": "lowpoly_3d", "world_shape": "sphere", "formal_world_mode": _formal_world_mode,
		"logical_size": Vector2(4096, 1363), "city_visual_count": _city_visuals.size(),
		"route_polyline_count": _routes.size(), "piece_count": _pieces.size(),
		"route_rendering": {"batches": _route_render_stats.duplicate(true), "marker_count": _markers.size(),
			"marker_batches": 1 if _marker_batch != null else 0, "selected_extra_half_width": SELECTED_ROUTE_EXTRA_WIDTH,
			"land_marker_radius": LAND_MARKER_RADIUS, "sea_marker_radius": SEA_MARKER_RADIUS,
			"legal_marker_scale": LEGAL_MARKER_SCALE},
		"cities": city_state, "pieces": piece_state, "missing_assets": get_missing_asset_paths(),
		"ready_for_play": is_ready_for_play(),
		"ambient": _ambient.get_diagnostics() if _ambient != null else {},
		"corridor": _corridor.get_diagnostics() if _corridor != null else {},
		"board_size": size, "right_safe_inset": _right_safe_inset,
		"static_layer_rebuild_count": _state_rebuilds, "route_cache_rebuild_count": _state_rebuilds,
		"camera": {"zoom_factor": _zoom, "yaw": _camera_yaw, "elevation": _camera_elevation,
			"projection": "perspective", "center": _camera_center, "distance": _camera_distance,
			"radius": PlanetGeometry.RADIUS, "position_3d": _camera.position if _camera != null else Vector3.ZERO,
			"follow_player_id": _follow_player_id},
		"viewport_size": _viewport.size if _viewport != null else Vector2i.ZERO,
		"own_world_3d": _viewport.own_world_3d if _viewport != null else false}


func get_hover_debug_state() -> Dictionary:
	return {"node_id": _hover_node, "city_id": _hover_city, "path": _hover_path.duplicate()}


func get_trade_bubble_debug_state() -> Dictionary:
	return {"visible": _tooltip != null and _tooltip.visible, "city_id": _hover_city,
		"text": _tooltip_text.text if _tooltip_text != null else ""}


func _exit_tree() -> void:
	_cancel_camera_follow()
	cancel_all_animations()
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
