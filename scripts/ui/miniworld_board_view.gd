extends "res://scripts/ui/lowpoly_board_view.gd"
## Continuous miniature map. Rule IDs/costs/saves stay in GameState; the builder
## owns independent visual anchors. No historical art-coordinate contracts load.
const Miniworld := preload("res://scripts/world/miniworld_scene.gd")
const TravelProps := preload("res://scripts/world/miniworld_props.gd")
var miniature: Node3D
var _environment: Environment
var _lighting_preset := "day"
var _overview_size := 31.0
var _camera_size := 31.0
var _night_button: Button
var _camera_input_enabled := true
var display_mode := "game"
var _route_segments: Array = []

class MiniaturePiece extends PieceActor:
	var board: Control
	func setup(p_id: String, human: bool, initial_transport: int, player_color: Color = Color("b54d36")) -> void:
		player_id = p_id
		is_human = human
		_player_color = player_color
		name = "Piece_" + p_id
		_body = Node3D.new()
		_body.name = "Body"
		add_child(_body)
		_models = {GameData.Transport.CAMEL: TravelProps.camel(1 if human else 2), GameData.Transport.SHIP: TravelProps.boat(false)}
		for model: Node3D in _models.values(): _body.add_child(model)
		_ring = MeshInstance3D.new()
		_ring.name = "PlayerMarker"
		var ring := CylinderMesh.new()
		ring.top_radius = 0.33
		ring.bottom_radius = 0.33
		ring.height = 0.02
		ring.radial_segments = 24
		_ring.mesh = ring
		var material := StandardMaterial3D.new()
		material.albedo_color = player_color.lightened(0.25)
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_ring.material_override = material
		_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ring.position.y = 0.012
		add_child(_ring)
		_ship_bounds = _read_model_bounds(_models[GameData.Transport.SHIP])
		_ship_stern_z = _ship_bounds.end.z
		_camel_bounds = _read_model_bounds(_models[GameData.Transport.CAMEL])
		_camel_tail_z = _camel_bounds.end.z
		_visual_motion = IdleVisualMotion.new()
		_visual_motion.name = "GentleBoatMotion"
		add_child(_visual_motion)
		_build_motion_effects()
		set_transport(initial_transport)
		set_process(false)
	func set_logical_position(point: Vector2) -> void:
		logical_pos = point
		position = board._visual_position(point)
		position.y += 0.06
		basis = Basis.IDENTITY
		_sync_trail_transforms()
	func _face_path_tangent(tangent: Vector2, weight: float) -> void:
		if _body != null and tangent.length_squared() > 0.00001:
			_body.rotation.y = lerp_angle(_body.rotation.y, atan2(-tangent.x, -tangent.y), weight)
	func _sync_trail_transforms() -> void:
		if _body == null: return
		var heading := Basis(Vector3.UP, _body.rotation.y)
		for kind in _trail_fx:
			var tail := _ship_stern_z + 0.025 if int(kind) == GameData.Transport.SHIP else _camel_tail_z + 0.075
			var point := transform * (heading * Vector3(0, 0, tail))
			point.y = position.y + 0.025
			(_trail_fx[kind] as CPUParticles3D).transform = transform.affine_inverse() * Transform3D(heading, point)

func _build_world() -> void:
	_viewport_container = SubViewportContainer.new()
	_viewport_container.name = "MiniatureViewportContainer"
	_viewport_container.stretch = true
	_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_viewport_container)
	_viewport = SubViewport.new()
	_viewport.name = "MiniatureViewport"
	_viewport.own_world_3d = true
	_viewport.handle_input_locally = false
	_viewport.gui_disable_input = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport_container.add_child(_viewport)
	_world = Node3D.new()
	_world.name = "SilkRoadMiniature"
	_viewport.add_child(_world)
	var env_node := WorldEnvironment.new()
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_COLOR
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	_environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = _environment
	_world.add_child(env_node)
	_sun = DirectionalLight3D.new()
	_sun.name = "SunMoon"
	_sun.rotation_degrees = Vector3(-52, -30, 0)
	_sun.shadow_enabled = true
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	_sun.directional_shadow_max_distance = 120
	_sun.shadow_bias = 0.035
	_sun.shadow_normal_bias = 0.5
	_world.add_child(_sun)
	_fill = DirectionalLight3D.new()
	_fill.rotation_degrees = Vector3(-40, 135, 0)
	_fill.shadow_enabled = false
	_world.add_child(_fill)
	_camera = Camera3D.new()
	_camera.name = "MiniatureCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.near = 0.1
	_camera.far = 240
	_camera.current = true
	_world.add_child(_camera)
	_static_root = Node3D.new()
	_static_root.name = "Map"
	_world.add_child(_static_root)
	_piece_root = Node3D.new()
	_piece_root.name = "Players"
	_world.add_child(_piece_root)
	_highlight = MeshInstance3D.new()
	_highlight.name = "SelectedRoute"
	_highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(_highlight)
	_labels = Control.new()
	_labels.name = "CityLabels"
	_labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_labels.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_labels)
	_hint = _new_label("拖动探索 · 右键环绕 · 滚轮靠近 · F 跟随 · R 总览 · N 昼夜", 12)
	_hint.position = Vector2(20, 14)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)
	_diagnostic = _new_label("", 13)
	_diagnostic.position = Vector2(20, 45)
	add_child(_diagnostic)
	_tooltip = PanelContainer.new()
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.add_theme_stylebox_override("panel", _paper_style())
	_tooltip_text = _new_label("", 14)
	_tooltip_text.custom_minimum_size = Vector2(160, 0)
	_tooltip.add_child(_tooltip_text)
	_tooltip.hide()
	add_child(_tooltip)
	_night_button = Button.new()
	_night_button.name = "DayNightToggle"
	_night_button.position = Vector2(20, 42)
	_night_button.custom_minimum_size = Vector2(92, 30)
	_night_button.pressed.connect(func(): set_lighting_preset("night" if _lighting_preset == "day" else "day"))
	add_child(_night_button)
	set_lighting_preset(_lighting_preset)

func _create_world_builder() -> Node3D:
	return Miniworld.new()

func _rebuild_assets() -> void:
	_state_rebuilds += 1
	_clear_children(_static_root)
	_clear_children(_labels)
	_city_visuals.clear()
	_routes.clear()
	_markers.clear()
	_route_segments.clear()
	_missing_assets.clear()
	miniature = _create_world_builder()
	_static_root.add_child(miniature)
	miniature.build(GameState.content)
	for edge_id in miniature.routes:
		var samples := PackedVector2Array()
		var points: PackedVector3Array = miniature.routes[edge_id]
		for point in points: samples.append(_encode(point))
		_routes[str(edge_id)] = samples
		for index in range(1, points.size()): _route_segments.append([points[index - 1], points[index]])
	for id in miniature.cities:
		var city: Dictionary = miniature.cities[id]
		var tag := PanelContainer.new()
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.96, 0.94, 0.83, 0.90)
		style.corner_radius_top_left = 5
		style.corner_radius_top_right = 5
		style.corner_radius_bottom_left = 5
		style.corner_radius_bottom_right = 5
		style.content_margin_left = 7
		style.content_margin_right = 7
		style.content_margin_top = 2
		style.content_margin_bottom = 2
		tag.add_theme_stylebox_override("panel", style)
		var label := _new_label(GameData.get_node_display_name(GameState.content, str(id)), 13)
		label.add_theme_color_override("font_color", Color("3d4c49"))
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tag.add_child(label)
		_labels.add_child(tag)
		_city_visuals[str(id)] = {"root": city.root, "model": city.root,
			"logical": _encode(city.anchor), "tag": tag, "label": label,
			"bounds": city.bounds, "screen_rect": Rect2()}
	var dot := CylinderMesh.new()
	dot.top_radius = 0.105
	dot.bottom_radius = 0.13
	dot.height = 0.04
	dot.radial_segments = 16
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.use_colors = true
	instances.mesh = dot
	instances.instance_count = miniature.anchors.size()
	var index := 0
	for id in miniature.anchors:
		var node: Dictionary = GameState.content.board_nodes.get(str(id), {})
		var anchor: Vector3 = miniature.anchors[id]
		var tx := Transform3D(Basis.IDENTITY, anchor + Vector3(0, 0.065, 0))
		var color := Color("e9ce93") if node.get("node_type", "") == "CITY" else Color("dbb67c")
		instances.set_instance_transform(index, tx)
		instances.set_instance_color(index, color)
		_markers.append({"node_id": str(id), "route_types": node.get("allowed_routes", ["LAND"]),
			"transform": tx, "base_color": color})
		index += 1
	_marker_batch = MultiMeshInstance3D.new()
	_marker_batch.name = "TravelStops"
	_marker_batch.multimesh = instances
	var mat := _material(Color.WHITE)
	mat.vertex_color_use_as_albedo = true
	_marker_batch.material_override = mat
	_static_root.add_child(_marker_batch)
	set_lighting_preset(_lighting_preset)
	_update_markers()
	_update_projected_labels()

func _sync_pieces() -> void:
	if not is_instance_valid(_piece_root) or not is_instance_valid(miniature): return
	var seen := {}
	for player in GameState.players:
		seen[player.player_id] = true
		if not _pieces.has(player.player_id):
			var actor := MiniaturePiece.new()
			actor.board = self
			_piece_root.add_child(actor)
			var color := Color("b54d36")
			for choice in GameData.get_player_colors(GameState.content):
				if choice.get("id", "") == player.color_id: color = Color(str(choice.color))
			actor.setup(player.player_id, player.is_local_human(), player.active_transport, color)
			actor.move_finished.connect(_on_piece_finished)
			_pieces[player.player_id] = actor
		var actor: Node3D = _pieces[player.player_id]
		if not actor.is_animating():
			actor.set_transport(player.active_transport)
			actor.set_logical_position(_node_route_pos(player.current_node_id, _route_name(player.active_transport)))
	for id in _pieces.keys():
		if not seen.has(id):
			_pieces[id].queue_free()
			_pieces.erase(id)
			_active_animations.erase(id)
	animating = not _active_animations.is_empty()
	_update_diagnostic()
	_update_follow_camera()
	_sync_follow_processing()

func _encode(point: Vector3) -> Vector2:
	return Vector2(point.x * 100.0 + 2048.0, point.z * 100.0 + 681.5)

func _visual_position(point: Vector2, lift: float = 0.0) -> Vector3:
	var result := Vector3((point.x - 2048.0) * 0.01, 0.15, (point.y - 681.5) * 0.01)
	var best := INF
	for segment in _route_segments:
		var a: Vector3 = segment[0]
		var b: Vector3 = segment[1]
		var delta := Vector2(b.x - a.x, b.z - a.z)
		var t := clampf(Vector2(result.x - a.x, result.z - a.z).dot(delta) / maxf(delta.length_squared(), 0.0001), 0, 1)
		var closest := a.lerp(b, t)
		var distance := Vector2(result.x - closest.x, result.z - closest.z).length_squared()
		if distance < best:
			best = distance
			result.y = closest.y
	result.y += lift
	return result

func _node_pos(id: String) -> Vector2:
	if is_instance_valid(miniature) and miniature.anchors.has(id): return _encode(miniature.anchors[id])
	return super._node_pos(id)

func _node_route_pos(id: String, _route_type: String) -> Vector2:
	return _node_pos(id)

func set_lighting_preset(preset: String) -> void:
	if preset not in ["day", "night"]: return
	_lighting_preset = preset
	var night := preset == "night"
	if _environment != null:
		_environment.background_color = Color("101e38") if night else Color("e6e1d5")
		_environment.ambient_light_color = Color("799acd") if night else Color("e9f2e1")
		_environment.ambient_light_energy = 0.58 if night else 0.45
		_sun.light_color = Color("9ebce9") if night else Color("fff0d2")
		_sun.light_energy = 0.42 if night else 0.70
		_fill.light_color = Color("7196c8") if night else Color("b9dcf2")
		_fill.light_energy = 0.12 if night else 0.26
	if is_instance_valid(miniature): miniature.set_night(night)
	if is_instance_valid(_night_button): _night_button.text = "☀ 明亮" if night else "☾ 夜晚"
	if is_instance_valid(_hint): _hint.add_theme_color_override("font_color", Color("d5e5e4") if night else Color("375c66"))

func set_map_safe_right_inset(pixels: float) -> void:
	_right_safe_inset = maxf(0, pixels) if display_mode != "beauty" else 0.0
	_apply_camera_transform()

func set_display_mode(mode: String) -> void:
	display_mode = mode
	if mode == "beauty": _right_safe_inset = 0.0
	if is_instance_valid(_labels): _labels.visible = mode != "beauty"
	if is_instance_valid(_hint): _hint.visible = mode != "beauty"
	if is_instance_valid(_night_button): _night_button.visible = mode != "beauty"
	_apply_camera_transform()

func set_camera_input_enabled(value: bool) -> void:
	_camera_input_enabled = value

func reset_camera_to_fit() -> void:
	_cancel_camera_follow()
	_zoom = 1.0
	_camera_yaw = deg_to_rad(-12)
	_camera_elevation = deg_to_rad(48)
	_camera_center = Vector3(0, 0.5, 0)
	_apply_camera_transform()
	_clear_hover()

func focus_logical_point(logical: Vector2, absolute_zoom: float = 2.6) -> void:
	_cancel_camera_follow()
	if not logical.is_finite(): return
	_camera_center = _visual_position(logical)
	_zoom = clampf(absolute_zoom, 1.0, 6.5)
	_apply_camera_transform()
	_clear_hover()

func focus_city(id: String, absolute_zoom: float = 3.4) -> void:
	focus_logical_point(_node_pos(id), absolute_zoom)

func _aim_camera_at_logical(logical: Vector2) -> void:
	_camera_center = _visual_position(logical)

func _on_resized() -> void:
	if is_instance_valid(_diagnostic): _diagnostic.size.x = maxf(100, size.x - _right_safe_inset - 40)
	_apply_camera_transform()

func _apply_camera_transform() -> void:
	if not is_instance_valid(_camera) or not _camera.is_inside_tree(): return
	_camera_elevation = clampf(_camera_elevation, deg_to_rad(25), deg_to_rad(78))
	_camera_center.x = clampf(_camera_center.x, -22, 22)
	_camera_center.z = clampf(_camera_center.z, -14, 14)
	var aspect := maxf(size.x, 1) / maxf(size.y, 1)
	var available := maxf(size.x - _right_safe_inset, size.x * 0.4) / maxf(size.x, 1)
	_overview_size = maxf(31.0, 45.0 / maxf(aspect * available, 0.3))
	_camera_size = _overview_size / clampf(_zoom, 1.0, 6.5)
	_camera.size = _camera_size
	var right := Vector3(cos(_camera_yaw), 0, -sin(_camera_yaw))
	var target := _camera_center + right * (_camera_size * aspect * (1.0 - available) * 0.5)
	_camera.look_at_from_position(target + _camera_direction() * 80, target, Vector3.UP)
	_update_projected_labels()

func _project(point: Vector3) -> Vector2:
	if not is_instance_valid(_camera) or not _camera.is_inside_tree(): return Vector2.INF
	return get_global_transform().affine_inverse() * (_viewport_container.get_global_transform() * _camera.unproject_position(point))

func world_to_screen(logical: Vector2) -> Vector2:
	return _project(_visual_position(logical, 0.065))

func _surface_point_visible(point: Vector3) -> bool:
	return is_instance_valid(_camera) and _camera.is_inside_tree() and not _camera.is_position_behind(point) and Rect2(Vector2.ZERO, Vector2(maxf(0, size.x - _right_safe_inset), size.y)).has_point(_project(point))

func is_logical_point_visible(logical: Vector2, _height: float = ROUTE_Y) -> bool:
	return _surface_point_visible(_visual_position(logical, 0.065))

func _ground_at(screen: Vector2) -> Vector3:
	if not is_instance_valid(_camera): return Vector3.INF
	var pixel := _viewport_container.get_global_transform().affine_inverse() * (get_global_transform() * screen)
	var origin := _camera.project_ray_origin(pixel)
	var ray := _camera.project_ray_normal(pixel)
	if absf(ray.y) < 0.00001: return Vector3.INF
	var point := origin + ray * ((0.48 - origin.y) / ray.y)
	if is_instance_valid(miniature) and miniature.has_method("surface_height"):
		for iteration in range(3):
			var ground := float(miniature.surface_height(point.x, point.z)) + 0.065
			point = origin + ray * ((ground - origin.y) / ray.y)
	return point

func screen_to_world(screen: Vector2) -> Vector2:
	return _encode(_ground_at(screen))

func zoom_immediate_around(screen: Vector2, absolute_zoom: float) -> void:
	if not _camera_input_enabled: return
	_cancel_camera_follow()
	var before := _ground_at(screen)
	_zoom = clampf(absolute_zoom, 1.0, 6.5)
	_apply_camera_transform()
	var after := _ground_at(screen)
	if before.is_finite() and after.is_finite():
		_camera_center += before - after
		_apply_camera_transform()
	_clear_hover()

func _pan(previous: Vector2, current: Vector2) -> void:
	_cancel_camera_follow()
	if _button_down == MOUSE_BUTTON_RIGHT:
		_camera_yaw -= (current.x - previous.x) * 0.006
		_camera_elevation += (current.y - previous.y) * 0.004
	else:
		var a := _ground_at(previous)
		var b := _ground_at(current)
		if a.is_finite() and b.is_finite(): _camera_center += a - b
	_apply_camera_transform()

func _gui_input(event: InputEvent) -> void:
	if not _camera_input_enabled: return
	if event is InputEventMouse and event.position.x > size.x - _right_safe_inset:
		if event is InputEventMouseButton and not event.pressed: _button_down = 0
		return
	super._gui_input(event)

func _unhandled_input(event: InputEvent) -> void:
	if not _camera_input_enabled or not is_visible_in_tree(): return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_N:
		set_lighting_preset("night" if _lighting_preset == "day" else "day")
		get_viewport().set_input_as_handled()
		return
	super._unhandled_input(event)

func _update_projected_labels() -> void:
	if not is_instance_valid(_camera) or not _camera.is_inside_tree(): return
	for id in _city_visuals:
		var entry: Dictionary = _city_visuals[id]
		var root: Node3D = entry.root
		if not root.is_inside_tree(): continue
		var bounds: AABB = entry.bounds
		var rect := Rect2(_project(root.global_transform * bounds.get_endpoint(0)), Vector2.ZERO)
		for index in range(1, 8): rect = rect.expand(_project(root.global_transform * bounds.get_endpoint(index)))
		entry.screen_rect = rect
		entry.front_facing = _surface_point_visible(root.global_position)
		var tag: Control = entry.tag
		tag.reset_size()
		var anchor := _project(root.global_transform * Vector3(bounds.get_center().x, bounds.end.y + 0.12, bounds.get_center().z))
		tag.position = anchor - Vector2(tag.size.x * 0.5, tag.size.y)
		tag.visible = entry.front_facing and display_mode != "beauty"

func _ribbon_mesh(points: PackedVector2Array, width: float, _height: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(_material(Color("f5c76d"), true))
	for index in range(1, points.size()):
		var a := _visual_position(points[index - 1], 0.09)
		var b := _visual_position(points[index], 0.09)
		var right := Vector3(-(b.z - a.z), 0, b.x - a.x).normalized() * width * 0.6
		for point in [a - right, b - right, a + right, a + right, b - right, b + right]:
			surface.set_normal(Vector3.UP)
			surface.add_vertex(point)
	if points.size() < 2: return ArrayMesh.new()
	return surface.commit()

func get_map_debug_state() -> Dictionary:
	var result := super.get_map_debug_state()
	result.renderer = "miniworld_3d"
	result.world_shape = "continuous_miniature"
	result.camera.projection = "orthogonal"
	result.camera["size"] = _camera_size
	result.camera.erase("radius")
	result["lighting_preset"] = _lighting_preset
	result["visual_anchor_count"] = miniature.anchors.size() if is_instance_valid(miniature) else 0
	return result
