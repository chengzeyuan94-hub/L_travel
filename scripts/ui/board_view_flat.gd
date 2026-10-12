extends "res://scripts/ui/lowpoly_board_view.gd"
## Isolated flat presentation. Production rules, movement samples, animation
## completion, picking policy and fail-closed behavior remain inherited.
const Greybox := preload("res://docs/design/greybox-030/g0_preview.gd")
const FLAT_ROOT := "res://docs/design/greybox-030/"
const TRUTH_ROOT := "res://docs/design/map-v3/truth/"
const HaloShader := preload("res://scripts/ui/shaders/board_flat_city_halo.gdshader")
const ScatterLoader := preload("res://docs/design/greybox-030/task-09/helper/scatter_multimesh_loader.gd")
const PlacementEditor := preload("res://docs/design/greybox-030/task-editor/placement_editor.gd")
const CAMERA_TRANSITION_SECONDS := 0.45
var placement_editor: Node
var _flat_scene: FlatScene
var _overview_size := 20.0
var _follow_size := 10.0
var _camera_size := 20.0
var _flat_follow := false
var _camera_input_enabled := true
var _lighting_preset := "day"
var _flat_source_hashes: Dictionary = {}
var _camera_transition: Tween
var _transition_camera_position := Vector3.ZERO
var _route_emission_materials: Array[StandardMaterial3D] = []
var _halo_materials: Array[ShaderMaterial] = []
var _stop_rings: MultiMeshInstance3D
var _route_style_counts: Dictionary = {}
var _scatter_render_result: Dictionary = {}
var generated_root := FLAT_ROOT + "generated/"
var _presentation_rig: RefCounted
var _surface_details: Node3D
var _presentation_applying := false
var _presentation_profile := "C"
var display_mode := "debug"
var visual_repair_enabled := false
var _visual_repair: RefCounted
var _repair_settings: Dictionary = {}
var _repair_camera_elevation := 48.0
const VisualRepair := preload("res://docs/design/greybox-030/task-visual-repair-runtime/visual_repair.gd")
const RepairSettings := "res://docs/design/greybox-030/task-visual-repair-runtime/recipe.json"

func _ready() -> void:
	visual_repair_enabled = visual_repair_enabled or "--visual-repair" in OS.get_cmdline_user_args()
	if "--visual-repair-off" in OS.get_cmdline_user_args(): visual_repair_enabled = false
	if visual_repair_enabled: _repair_settings = JSON.parse_string(FileAccess.get_file_as_string(RepairSettings))
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--flat-generated-root="):
			generated_root = argument.substr("--flat-generated-root=".length()).trim_suffix("/") + "/"
	super._ready()
	await get_tree().process_frame
	_on_resized()
	if is_instance_valid(_flat_scene): reset_camera_to_fit()

class FlatScene extends Greybox:
	var board: Control
	func _ready() -> void:
		pass
	func initialize() -> void:
		scene_data_path = board.generated_root + "scene-data.json"
		terrain_data_path = board.generated_root + "terrain.json"
		scatter_data_path = board.generated_root + "scatter.json"
		asset_directory = board.generated_root + "assets"
		data = _read_json(scene_data_path)
		terrain = _read_json(terrain_data_path)
		if board.visual_repair_enabled: VisualRepair.prepare_assets(data, board._repair_settings)
		data.palette = _read_json("res://docs/design/map-v3/truth/palette.json")
		data.lighting = {"day": _read_json("res://docs/design/map-v3/truth/lighting-day.json"),
			"night": _read_json("res://docs/design/map-v3/truth/lighting-night.json")}
		_build_ui()
		_build_height_index()
		_build_world()
		board._load_flat_scatter(world)
		_set_lighting(false)
		set_process_unhandled_key_input(false)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_map_input(self)
	func _ignore_map_input(node: Node) -> void:
		for child in node.get_children():
			if child is Control and not child is Button:
				child.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_ignore_map_input(child)
	func fit_reference(value: bool) -> void:
		super._set_camera(value)
	func _set_camera(value: bool) -> void:
		if board != null: board.set_flat_camera(value)
	func _set_lighting(value: bool) -> void:
		super._set_lighting(value)
		var preset: Dictionary = data.lighting["night" if value else "day"]
		var adjustments: Dictionary = preset.get("post", {}).get("adjustments", {})
		env.adjustment_enabled = bool(adjustments.get("enabled", false))
		env.adjustment_saturation = float(adjustments.get("saturation", 1.0))
		if not value and preset.key_light.has("elevation_degrees"):
			key.rotation_degrees.x = -float(preset.key_light.elevation_degrees)
		if board != null:
			board._lighting_preset = "night" if value else "day"
			board._set_flat_emission(value)
			board._refresh_promoted_presentation(value)
	func _build_routes() -> void:
		board._build_flat_routes()

class FlatPieceActor extends PieceActor:
	var height_lookup: Callable
	var land_y: float
	var water_y: float
	func set_logical_position(point: Vector2) -> void:
		logical_pos = point
		var y := water_y if transport == GameData.Transport.SHIP else land_y
		if transport != GameData.Transport.SHIP and height_lookup.is_valid():
			y = float(height_lookup.call(point))
		position = Vector3((point.x - 2048.0) * 0.01, y, (point.y - 681.5) * 0.01)
		basis = Basis.IDENTITY
		_sync_trail_transforms()
	func _face_path_tangent(tangent: Vector2, weight: float) -> void:
		if _body != null and tangent.length_squared() > 0.00001:
			_body.rotation.y = lerp_angle(_body.rotation.y, atan2(-tangent.x, -tangent.y), weight)
	func _sync_trail_transforms() -> void:
		if _body == null: return
		var heading := Basis(Vector3.UP, _body.rotation.y)
		for kind in _trail_fx:
			var ship := int(kind) == GameData.Transport.SHIP
			var tail := _ship_stern_z + 0.025 if ship else _camel_tail_z + 0.075
			var point := transform * (heading * Vector3(0, 0, tail))
			point.y = water_y + 0.013 if ship else position.y + 0.075
			(_trail_fx[kind] as CPUParticles3D).transform = transform.affine_inverse() * Transform3D(heading, point)

func reload_for_current_game() -> void:
	var saved_preset := _lighting_preset
	_loaded_ruleset = String(GameState.content.get("ruleset", {}).get("ruleset_id", ""))
	_formal_world_mode = _loaded_ruleset == "lshu_configurable_v1"
	if not _formal_world_mode:
		super.reload_for_current_game()
		return
	_cancel_camera_follow()
	cancel_all_animations()
	clear_selection()
	if is_instance_valid(placement_editor):
		placement_editor.free()
		placement_editor = null
	_presentation_rig = null
	_surface_details = null
	_visual_repair = null
	if is_instance_valid(_flat_scene):
		remove_child(_flat_scene)
		_flat_scene.free()
	for overlay in [_labels, _tooltip, _hint, _diagnostic]:
		if is_instance_valid(overlay): overlay.free()
	_pieces.clear()
	_city_visuals.clear()
	_routes.clear()
	_markers.clear()
	_marker_batch = null
	_missing_assets.clear()
	_route_emission_materials.clear()
	_halo_materials.clear()
	_build_world()
	if _world == null: return
	_rebuild_assets()
	_sync_pieces()
	set_lighting_preset(saved_preset)
	reset_camera_to_fit()
	_sync_render_activity()

func _build_world() -> void:
	var required := [generated_root + "scene-data.json", generated_root + "terrain.json",
		TRUTH_ROOT + "palette.json", TRUTH_ROOT + "lighting-day.json", TRUTH_ROOT + "lighting-night.json"]
	for path in required:
		if not FileAccess.file_exists(path): _missing_assets.append(path)
		else:
			_flat_source_hashes[path] = FileAccess.get_sha256(path)
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			var valid := parsed is Dictionary
			if valid and path.ends_with("scene-data.json"):
				valid = parsed.get("nodes", []).size() == 54 and parsed.get("edges", []).size() == 57 and parsed.get("cities", []).size() == 16
			elif valid and path.ends_with("terrain.json"):
				valid = not parsed.get("positions", []).is_empty() and not parsed.get("indices", []).is_empty() and parsed.has("water")
			elif valid and path.ends_with("palette.json"):
				valid = parsed.has("colors") and parsed.has("accents")
			elif valid:
				valid = parsed.has("backdrop") and parsed.has("ambient") and parsed.has("key_light") and parsed.has("fill_light")
			if not valid: _missing_assets.append(path + ":invalid_contract")
	if not _missing_assets.is_empty(): return
	_flat_scene = FlatScene.new()
	_flat_scene.board = self
	_flat_scene.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_flat_scene)
	_flat_scene.initialize()
	for property in _flat_scene.get_property_list():
		if str(property.name) == "asset_load_result":
			var result: Variant = _flat_scene.get("asset_load_result")
			if result is Dictionary and not result.is_empty() and not bool(result.get("ok",false)):
				for error in result.get("errors",[]): _missing_assets.append("asset_instances:" + str(error))
	_viewport = _flat_scene.vp
	_viewport_container = _viewport.get_parent()
	_world = _flat_scene.world
	_camera = _flat_scene.camera
	_sun = _flat_scene.key
	_fill = _flat_scene.fill
	_static_root = Node3D.new()
	_static_root.name = "InteractionProxies"
	_world.add_child(_static_root)
	_piece_root = Node3D.new()
	_piece_root.name = "Players"
	_world.add_child(_piece_root)
	_highlight = MeshInstance3D.new()
	_highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(_highlight)
	_labels = Control.new()
	_labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_labels.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_labels)
	_hint = _new_label("", 12)
	add_child(_hint)
	_diagnostic = _new_label("", 13)
	_diagnostic.position = Vector2(18, 34)
	_diagnostic.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_diagnostic)
	_tooltip = PanelContainer.new()
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.add_theme_stylebox_override("panel", _paper_style())
	_tooltip_text = _new_label("", 14)
	_tooltip_text.custom_minimum_size = Vector2(170, 0)
	_tooltip.add_child(_tooltip_text)
	_tooltip.hide()
	add_child(_tooltip)
	_right_safe_inset = size.x * 0.28
	_on_resized()

func _rebuild_assets() -> void:
	_state_rebuilds += 1
	for city in _flat_scene.data.cities:
		var root := Node3D.new()
		root.position = _flat_scene._position(city.get("center_logical", city.logical))
		root.position.y = float(city.get("base_y", root.position.y))
		root.rotation_degrees.y = float(city.get("yaw_degrees", 0))
		_static_root.add_child(root)
		var dims := _flat_scene._v3(city.dimensions)
		var tag := Control.new()
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tag.hide()
		_labels.add_child(tag)
		var label := Label.new()
		label.hide()
		tag.add_child(label)
		_city_visuals[str(city.id)] = {"root": root, "model": root, "logical": _vec2(city.logical),
			"tag": tag, "label": label, "bounds": AABB(Vector3(-dims.x / 2, 0, -dims.z / 2), dims), "screen_rect": Rect2()}
	for edge in GameState.content.get("board_edges", []):
		var samples := PackedVector2Array()
		for point in edge.get("movement_polyline", edge.get("movement_polyline_px", [])):
			samples.append(_vec2(point))
		_routes[str(edge.id)] = samples
	for entry in _flat_scene.data.get("asset_instances", []):
		var path: String = entry.get("glb", generated_root + "assets/" + str(entry.get("asset_id", "")) + ".glb")
		if not path.begins_with("res://") and not path.is_absolute_path(): path = (generated_root + "assets").path_join(path)
		# The shared G1 loader reads GLB bytes directly; it needs no .godot import.
		if not FileAccess.file_exists(path): _missing_assets.append(path)
	_update_diagnostic()
	_build_city_halos()
	_bind_city_presentations()
	_set_flat_emission(_lighting_preset == "night")
	placement_editor = PlacementEditor.new()
	add_child(placement_editor)
	placement_editor.initialize(self)
	if placement_editor.rejected_load: _missing_assets.append("layout-overrides:failed_validation")
	_install_promoted_presentation()
	if visual_repair_enabled:
		_visual_repair = VisualRepair.new()
		_visual_repair.initialize(self, _repair_settings)
		set_display_mode("beauty")

func _install_promoted_presentation() -> void:
	var path := generated_root + "render-profile.json"
	if not FileAccess.file_exists(path): return
	var settings: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not settings is Dictionary or settings.get("profile", "") != "C":
		_missing_assets.append("render-profile:invalid_contract")
		return
	_flat_source_hashes[path] = FileAccess.get_sha256(path)
	_presentation_profile = settings.profile
	var recipe: Script = load("res://docs/design/greybox-030/task-g2-render-e/render_recipe.gd")
	_presentation_rig = recipe.new()
	_presentation_rig.initialize(self)
	# F's reversible wall override must restore the approved E material,
	# including terrain roughness, when the detail comparison is disabled.
	_refresh_promoted_presentation(_lighting_preset == "night")
	var detail_path := generated_root + "surface-details.json"
	if not FileAccess.file_exists(detail_path):
		_missing_assets.append("surface-details:missing_promoted_document")
		return
	_flat_source_hashes[detail_path] = FileAccess.get_sha256(detail_path)
	var detail_script: Script = load("res://docs/design/greybox-030/task-g2-surface-f/surface_layer.gd")
	_surface_details = detail_script.new()
	_surface_details.name = "PromotedSurfaceDetails"
	_flat_scene.world.add_child(_surface_details)
	_surface_details.install(self, detail_path)
	_refresh_promoted_presentation(_lighting_preset == "night")

func _refresh_promoted_presentation(is_night: bool) -> void:
	if _presentation_applying or _presentation_rig == null: return
	_presentation_applying = true
	_presentation_rig.apply(_presentation_profile, is_night)
	if is_instance_valid(_surface_details): _surface_details.set_enabled(true)
	_presentation_applying = false
	if _visual_repair != null: _visual_repair.apply_lighting(is_night)

func _load_flat_scatter(parent: Node3D) -> void:
	_scatter_render_result = {}
	var path := generated_root + "scatter.json"
	if FileAccess.file_exists(path): _flat_source_hashes[path] = FileAccess.get_sha256(path)
	# G0 may already have invoked the same helper. Reuse its result, never draw twice.
	for property in _flat_scene.get_property_list():
		if str(property.name) == "scatter_load_report":
			var report: Variant = _flat_scene.get("scatter_load_report")
			if report is Dictionary and not report.is_empty():
				_scatter_render_result = report
				for source in report.get("source_hashes",{}): _flat_source_hashes[source] = report.source_hashes[source]
				if not bool(report.get("ok",false)):
					for error in report.get("errors",[]): _missing_assets.append("scatter:" + str(error))
				return
	if parent.get_node_or_null("ScatterMultiMeshes") != null: return
	if not FileAccess.file_exists(path): return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		_missing_assets.append(path + ":invalid_contract")
		return
	_scatter_render_result = ScatterLoader.load_scatter(parent,parsed,_flat_scene.data.projection,_flat_scene._height,generated_root + "assets")
	for source in _scatter_render_result.source_hashes: _flat_source_hashes[source] = _scatter_render_result.source_hashes[source]
	if not _scatter_render_result.ok:
		for error in _scatter_render_result.errors: _missing_assets.append("scatter:" + str(error))

func _bind_city_presentations() -> void:
	for item in _flat_scene.world.find_children("*", "Node3D", true, false):
		if item.has_meta("city_id"):
			var id := str(item.get_meta("city_id"))
			if _city_visuals.has(id):
				_city_visuals[id].root = item
				_city_visuals[id].model = item
				_city_visuals[id].bounds = _model_bounds(item)
	for label in _flat_scene.world.find_children("*", "Label3D", true, false):
		for id in _city_visuals:
			if label.text == str(Greybox.CITY_NAMES.get(id, id)):
				_city_visuals[id]["visual_label"] = label

func _sync_pieces() -> void:
	if not is_instance_valid(_piece_root): return
	var seen := {}
	for player in GameState.players:
		seen[player.player_id] = true
		if not _pieces.has(player.player_id):
			var actor := FlatPieceActor.new()
			actor.height_lookup = _flat_ground_height
			actor.land_y = float(_flat_scene.data.projection.land_y)
			actor.water_y = float(_flat_scene.data.projection.water_y)
			_piece_root.add_child(actor)
			var player_color := Color("b54d36")
			for choice in GameData.get_player_colors(GameState.content):
				if choice.get("id", "") == player.color_id: player_color = Color(str(choice.color))
			actor.setup(player.player_id, player.is_local_human(), player.active_transport, player_color)
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

func is_ready_for_play() -> bool:
	return not _formal_world_mode or (is_instance_valid(_flat_scene) and is_instance_valid(_world)
		and _flat_scene.data.has("nodes") and _flat_scene.terrain.has("indices") and get_missing_asset_paths().is_empty())

func _flat_ground_height(logical: Vector2) -> float:
	return _flat_scene._height((logical.x - 2048.0) * 0.01, (logical.y - 681.5) * 0.01)

func _flat_position(logical: Vector2, lift: float = 0.0) -> Vector3:
	return Vector3((logical.x - 2048.0) * 0.01, _flat_ground_height(logical) + lift, (logical.y - 681.5) * 0.01)

func set_lighting_preset(preset: String) -> void:
	if preset not in ["day", "night"]:
		push_error("Flat board: invalid lighting preset")
		return
	if is_instance_valid(_flat_scene): _flat_scene._set_lighting(preset == "night")

func set_map_safe_right_inset(pixels: float) -> void:
	if display_mode == "beauty":
		_right_safe_inset = 0.0
		_on_resized()
		return
	_right_safe_inset = maxf(size.x * 0.28, pixels)
	_on_resized()

func set_display_mode(mode: String) -> void:
	assert(mode in ["beauty", "debug"])
	display_mode = mode
	if not is_instance_valid(_flat_scene): return
	for child in _flat_scene.get_children():
		if child is MarginContainer: child.visible = mode == "debug"
	for label in _flat_scene.world.find_children("*", "Label3D", true, false): label.visible = mode == "debug"
	if is_instance_valid(_diagnostic): _diagnostic.visible = mode == "debug"
	if is_instance_valid(_hint): _hint.visible = mode == "debug"
	_right_safe_inset = 0.0 if mode == "beauty" else size.x * 0.28
	_on_resized()

func _on_resized() -> void:
	if not is_instance_valid(_flat_scene) or not is_instance_valid(_camera): return
	if display_mode == "beauty" or visual_repair_enabled:
		_right_safe_inset = 0.0 if display_mode == "beauty" else size.x * 0.28
		var pixels := DisplayServer.window_get_size()
		var target := Vector2i(maxi(1,int(pixels.x * (1.0 if display_mode == "beauty" else 0.72))), maxi(1,pixels.y))
		_viewport_container.stretch = false
		_viewport_container.size = Vector2(target)
		_viewport.size = target
		_viewport_container.scale = Vector2((size.x - _right_safe_inset) / target.x, size.y / target.y)
		if _visual_repair != null:
			_visual_repair.set_view("corridor" if _flat_follow else "overview")
		return
	_right_safe_inset = maxf(size.x * 0.28, _right_safe_inset)
	_viewport_container.scale = Vector2((size.x - _right_safe_inset) / float(_viewport.size.x), size.y / float(_viewport.size.y))
	_flat_scene.fit_reference(false)
	_overview_size = _camera.size
	_flat_scene.fit_reference(true)
	_follow_size = _camera.size
	_camera_size = _overview_size / _zoom
	_apply_camera_transform()

func set_flat_camera(value: bool) -> void:
	_cancel_camera_follow()
	_flat_follow = value
	if _visual_repair != null:
		_visual_repair.set_view("corridor" if value else "overview")
		return
	_transition_to(_flat_position(Vector2(1930, 440)) if value else Vector3.ZERO,
		clampf(_follow_size if value else _overview_size, _overview_size * 0.35, _overview_size),
		0.0 if value else deg_to_rad(8.0))
	_clear_hover()

func reset_camera_to_fit() -> void:
	if is_instance_valid(_flat_scene): set_flat_camera(false)

func focus_logical_point(logical: Vector2, absolute_zoom: float = 2.6) -> void:
	if not logical.is_finite() or not is_instance_valid(_camera): return
	_cancel_camera_follow()
	_flat_follow = true
	_transition_to(_flat_position(logical), _overview_size / clampf(absolute_zoom, 1.0, 1.0 / 0.35), 0.0)
	_clear_hover()

func _transition_to(target: Vector3, target_size: float, target_yaw: float) -> void:
	_stop_camera_transition()
	_transition_camera_position = _camera.position
	var pitch := deg_to_rad(32.0)
	var end_position := target + Vector3(sin(target_yaw) * cos(pitch), sin(pitch), cos(target_yaw) * cos(pitch)) * 70.0
	_camera_transition = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_camera_transition.tween_property(self, "_transition_camera_position", end_position, CAMERA_TRANSITION_SECONDS)
	_camera_transition.tween_property(self, "_camera_center", target, CAMERA_TRANSITION_SECONDS)
	_camera_transition.tween_property(self, "_camera_size", target_size, CAMERA_TRANSITION_SECONDS)
	_camera_transition.tween_property(self, "_camera_yaw", target_yaw, CAMERA_TRANSITION_SECONDS)
	_camera_transition.finished.connect(func():
		_apply_camera_transform()
		_sync_follow_processing())
	set_process(true)

func _stop_camera_transition() -> void:
	if _camera_transition != null and _camera_transition.is_valid(): _camera_transition.kill()
	_camera_transition = null

func _cancel_camera_follow() -> void:
	_stop_camera_transition()
	super._cancel_camera_follow()

func _sync_follow_processing() -> void:
	var actor: Node3D = _pieces.get(_follow_player_id)
	var transitioning := _camera_transition != null and _camera_transition.is_running()
	set_process(is_visible_in_tree() and _formal_world_mode and (transitioning or (is_instance_valid(actor)
		and actor.is_animating() and GameState.phase != GameState.Phase.GAME_OVER)))

func _update_follow_camera(force: bool = false) -> void:
	if _camera_transition != null and _camera_transition.is_running(): return
	super._update_follow_camera(force)

func _process(_delta: float) -> void:
	if _camera_transition != null and _camera_transition.is_running(): _apply_camera_transform()
	else: _update_follow_camera()
	_sync_follow_processing()

func _aim_camera_at_logical(logical: Vector2) -> void:
	_camera_center = _flat_position(logical)

func _apply_camera_transform() -> void:
	if not is_instance_valid(_camera): return
	_camera_elevation = deg_to_rad(_repair_camera_elevation if visual_repair_enabled else 32.0)
	_camera_yaw = clampf(_camera_yaw, deg_to_rad(-35 if visual_repair_enabled else -15), deg_to_rad(35 if visual_repair_enabled else 15))
	_camera_center.x = clampf(_camera_center.x, -21.48, 21.48)
	_camera_center.z = clampf(_camera_center.z, -7.815, 7.815)
	_camera_size = clampf(_camera_size, _overview_size * (0.14 if visual_repair_enabled else 0.35), _overview_size)
	_zoom = _overview_size / maxf(_camera_size, 0.001)
	if _camera_transition != null and _camera_transition.is_running():
		_camera.position = _transition_camera_position
		_camera.rotation = Vector3(-_camera_elevation, _camera_yaw, 0.0)
	else:
		_camera.look_at_from_position(_camera_center + _camera_direction() * 70.0, _camera_center, Vector3.UP)
	_camera.size = _camera_size
	_flat_scene.camera_target = _camera_center
	_flat_scene.follow = _flat_follow
	_flat_scene._refresh_text()
	_update_projected_labels()

func _project(point: Vector3) -> Vector2:
	if not is_instance_valid(_camera) or not _camera.is_inside_tree(): return Vector2.INF
	return get_global_transform().affine_inverse() * (_viewport_container.get_global_transform() * _camera.unproject_position(point))

func world_to_screen(logical: Vector2) -> Vector2:
	return _project(_flat_position(logical, 0.065))

func _surface_point_visible(point: Vector3) -> bool:
	return is_instance_valid(_camera) and _camera.is_inside_tree() and not _camera.is_position_behind(point) and Rect2(Vector2.ZERO, Vector2(size.x - _right_safe_inset, size.y)).has_point(_project(point))

func is_logical_point_visible(logical: Vector2, _height: float = ROUTE_Y) -> bool:
	return _surface_point_visible(_flat_position(logical, 0.065))

func _ground_at(screen: Vector2) -> Vector3:
	if not is_instance_valid(_camera): return Vector3.INF
	var pixel := _viewport_container.get_global_transform().affine_inverse() * (get_global_transform() * screen)
	var origin := _camera.project_ray_origin(pixel)
	var direction := _camera.project_ray_normal(pixel)
	if absf(direction.y) < 0.00001: return Vector3.INF
	var point := origin + direction * ((float(_flat_scene.data.projection.land_y) - origin.y) / direction.y)
	# Intersect the actual flat terrain, including the marker's projection plane.
	for iteration in range(4):
		var y := _flat_scene._height(point.x, point.z) + 0.065
		point = origin + direction * ((y - origin.y) / direction.y)
	return point

func screen_to_world(screen: Vector2) -> Vector2:
	var point := _ground_at(screen)
	return Vector2(point.x / 0.01 + 2048.0, point.z / 0.01 + 681.5) if point.is_finite() else Vector2.INF

func zoom_immediate_around(screen: Vector2, absolute_zoom: float) -> void:
	if not is_instance_valid(_camera) or not _camera_input_enabled: return
	_stop_camera_transition()
	var before := _ground_at(screen)
	_zoom = clampf(absolute_zoom, 1.0, 1.0 / (0.14 if visual_repair_enabled else 0.35))
	_camera_size = _overview_size / _zoom
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
		_apply_camera_transform()
		return
	var before := _ground_at(previous)
	var after := _ground_at(current)
	if before.is_finite() and after.is_finite(): _camera_center += before - after
	_camera_center.x = clampf(_camera_center.x, -21.48, 21.48)
	_camera_center.z = clampf(_camera_center.z, -7.815, 7.815)
	_apply_camera_transform()

func _gui_input(event: InputEvent) -> void:
	if not _camera_input_enabled: return
	# Always finish a placement drag, including releases inside the HUD safe area.
	if is_instance_valid(placement_editor) and placement_editor.dragging and event is InputEventMouseButton and not event.pressed:
		if placement_editor.handle_mouse(event):
			accept_event()
			return
	var at := Vector2.ZERO
	if event is InputEventMouse: at = event.position
	elif event is InputEventGesture: at = event.position
	if not Rect2(Vector2.ZERO, Vector2(size.x - _right_safe_inset, size.y)).has_point(at):
		if event is InputEventMouseButton and not event.pressed:
			_button_down = 0
			_dragged = false
		return
	if is_instance_valid(placement_editor) and placement_editor.handle_mouse(event):
		accept_event()
		return
	if event is InputEventMagnifyGesture:
		zoom_immediate_around(event.position, _zoom * event.factor)
		accept_event()
		return
	super._gui_input(event)

func _unhandled_input(event: InputEvent) -> void:
	if not _camera_input_enabled: return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_N:
		set_lighting_preset("night" if _lighting_preset == "day" else "day")
		get_viewport().set_input_as_handled()
		return
	super._unhandled_input(event)

func set_camera_input_enabled(value: bool) -> void:
	_camera_input_enabled = value

func _update_projected_labels() -> void:
	if not is_instance_valid(_camera) or not _camera.is_inside_tree(): return
	for id in _city_visuals:
		var entry: Dictionary = _city_visuals[id]
		var root: Node3D = entry.root
		if not root.is_inside_tree(): continue
		var bounds: AABB = entry.bounds
		var rect := Rect2(_project(root.global_transform * bounds.get_endpoint(0)), Vector2.ZERO)
		for i in range(1, 8): rect = rect.expand(_project(root.global_transform * bounds.get_endpoint(i)))
		entry.screen_rect = rect
		entry.front_facing = _surface_point_visible(root.global_position)
		var visual_label: Label3D = entry.get("visual_label")
		if is_instance_valid(visual_label) and visual_label.is_inside_tree():
			var label_bounds := visual_label.get_aabb()
			var center: Vector3 = visual_label.global_position + _camera.global_basis.x * label_bounds.get_center().x + _camera.global_basis.y * label_bounds.get_center().y
			var a := _project(center - _camera.global_basis.x * label_bounds.size.x * 0.5 - _camera.global_basis.y * label_bounds.size.y * 0.5)
			var b := _project(center + _camera.global_basis.x * label_bounds.size.x * 0.5 + _camera.global_basis.y * label_bounds.size.y * 0.5)
			entry.tag.position = a.min(b)
			entry.tag.size = (a-b).abs()
			entry.tag.visible = visual_label.visible and entry.front_facing
			entry.label.visible = entry.tag.visible
		else:
			entry.tag.hide()

func _ribbon_mesh(points: PackedVector2Array, width: float, height: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	for i in range(points.size() - 1):
		var a := _flat_position(points[i], height - GROUND_Y)
		var b := _flat_position(points[i + 1], height - GROUND_Y)
		var right := Vector3(-(b.z - a.z), 0, b.x - a.x).normalized() * width
		for v in [a - right, a + right, b - right, a + right, b + right, b - right]: vertices.append(v)
	var mesh := ArrayMesh.new()
	if vertices.is_empty(): return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _flat_color(name: String) -> Color:
	var palette: Dictionary = _flat_scene.data.palette
	return Color(str(palette.accents[name])) if palette.accents.has(name) else Color(str(palette.colors[name].hex))

func _flat_surface(vertices: PackedVector3Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if vertices.is_empty(): return mesh
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _flat_ring(outer: float, inner: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	for i in range(32):
		var a := TAU * float(i) / 32.0
		var b := TAU * float(i + 1) / 32.0
		var ao := Vector3(cos(a), 0, sin(a)) * outer
		var bo := Vector3(cos(b), 0, sin(b)) * outer
		var ai := Vector3(cos(a), 0, sin(a)) * inner
		var bi := Vector3(cos(b), 0, sin(b)) * inner
		for point in [ao, bo, ai, bo, bi, ai]: vertices.append(point)
	return _flat_surface(vertices)

func _flat_batch(mesh: Mesh, transforms: Array[Transform3D], material: StandardMaterial3D,
		colors: Array[Color] = []) -> MultiMeshInstance3D:
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = not colors.is_empty()
	multi.mesh = mesh
	multi.instance_count = transforms.size()
	for i in range(transforms.size()):
		multi.set_instance_transform(i, transforms[i])
		if not colors.is_empty(): multi.set_instance_color(i, colors[i])
	var item := MultiMeshInstance3D.new()
	item.multimesh = multi
	item.material_override = material
	item.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flat_scene.world.add_child(item)
	return item

func _route_sample(points: Array, distance: float) -> Vector2:
	for i in range(points.size() - 1):
		var a := _vec2(points[i])
		var b := _vec2(points[i + 1])
		var span := a.distance_to(b) * 0.01
		if distance <= span and span > 0.00001: return a.lerp(b, distance / span)
		distance -= span
	return _vec2(points[-1])

func _build_flat_routes() -> void:
	var stepping := CylinderMesh.new()
	stepping.top_radius = 0.035
	stepping.bottom_radius = 0.045
	stepping.height = 0.025
	stepping.radial_segments = 8
	var steps: Array[Transform3D] = []
	var sea_vertices := PackedVector3Array()
	var sea_segments := 0
	for edge in _flat_scene.data.edges:
		var points: Array = edge.points
		var total := 0.0
		for i in range(points.size() - 1): total += _vec2(points[i]).distance_to(_vec2(points[i + 1])) * 0.01
		var route_type: String = edge.get("route_type", "LAND")
		if route_type == "LAND":
			var distance := 0.13
			while distance < total:
				steps.append(Transform3D(Basis.IDENTITY, _flat_position(_route_sample(points, distance), 0.04)))
				distance += 0.13
		else:
			var distance := 0.0
			while distance < total:
				var end := minf(total, distance + 0.36)
				var a := _flat_position(_route_sample(points, distance), 0.04)
				var b := _flat_position(_route_sample(points, end), 0.04)
				var right := Vector3(-(b.z-a.z),0,b.x-a.x).normalized() * SEA_ROUTE_HALF_WIDTH
				# Godot uses clockwise front faces. Up-facing winding must agree
				# with the UP normals or double-sided lighting darkens the water dashes.
				for point in [a-right, b-right, a+right, a+right, b-right, b+right]: sea_vertices.append(point)
				sea_segments += 1
				distance += 0.36 + 0.20
	_flat_batch(stepping, steps, _flat_scene.route_material)
	var sea := MeshInstance3D.new()
	sea.name = "FlatSeaDashes"
	sea.mesh = _flat_surface(sea_vertices)
	sea.material_override = _flat_scene._material(_flat_color("cream"))
	sea.material_override.cull_mode = BaseMaterial3D.CULL_BACK
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flat_scene.world.add_child(sea)
	_route_emission_materials.append(sea.material_override)
	_route_emission_materials.append(_flat_scene.route_material)
	_flat_scene.decorative_dot_count = steps.size()
	var ordinary_transforms: Array[Transform3D] = []
	var ordinary_colors: Array[Color] = []
	var ring_colors: Array[Color] = []
	var city_transforms: Array[Transform3D] = []
	var city_colors: Array[Color] = []
	for node in _flat_scene.data.nodes:
		var at := _flat_position(_vec2(node.logical), 0.065)
		_flat_scene.node_positions[str(node.id)] = at
		var anchor: Dictionary = _node_visual_anchors(str(node.id))[0]
		var is_city: bool = str(node.type) == "CITY"
		var radius := 0.24 if is_city else (LAND_MARKER_RADIUS if anchor.route_type == "LAND" else SEA_MARKER_RADIUS)
		var tx := Transform3D(Basis.from_scale(Vector3(radius, 1, radius)), at)
		var marker := {"node_id": str(node.id), "route_type": anchor.route_type, "route_types": anchor.route_types,
			"transform": tx, "base_color": _flat_color("gold") if is_city else _flat_color("terracotta"), "is_city": is_city}
		if is_city:
			marker["batch_index"] = city_transforms.size()
			city_transforms.append(tx)
			city_colors.append(_flat_color("gold"))
		else:
			marker["batch_index"] = ordinary_transforms.size()
			ordinary_transforms.append(tx)
			ordinary_colors.append(_flat_color("terracotta"))
			ring_colors.append(_flat_color("cream"))
		_markers.append(marker)
	var top := CylinderMesh.new()
	top.top_radius = 0.8
	top.bottom_radius = 0.8
	top.height = 0.014
	top.radial_segments = 24
	var top_material := _flat_scene._material(Color.WHITE)
	top_material.vertex_color_use_as_albedo = true
	_marker_batch = _flat_batch(top, ordinary_transforms, top_material, ordinary_colors)
	_stop_rings = _flat_batch(_flat_ring(1.0, 0.8), ordinary_transforms, top_material, ring_colors)
	var city_rings := _flat_batch(_flat_ring(1.0, 1.0 - 0.04 / 0.24), city_transforms, top_material, city_colors)
	for marker in _markers:
		marker["batch"] = city_rings if marker.is_city else _marker_batch
		marker["ring_batch"] = city_rings if marker.is_city else _stop_rings
	_route_emission_materials.append(top_material)
	_route_style_counts = {"land_steps": steps.size(), "land_spacing":0.13, "sea_dashes":sea_segments,
		"sea_dash_length":0.36,"sea_gap":0.20,"ordinary_stops":ordinary_transforms.size(),"city_rings":city_transforms.size(),
		"city_radius":0.24,"city_line_width":0.04,"static_batches":5}

func _update_markers() -> void:
	var route_type := _current_route_type()
	for entry in _markers:
		if not entry.has("batch"): continue
		var legal: bool = legal_nodes.has(entry.node_id) and route_type in entry.route_types
		var scale := LEGAL_MARKER_SCALE if legal else 1.0
		var base: Transform3D = entry.transform
		var tx := Transform3D(base.basis * Basis.from_scale(Vector3(scale, 1, scale)), base.origin)
		var batch: MultiMeshInstance3D = entry.batch
		batch.multimesh.set_instance_transform(entry.batch_index, tx)
		batch.multimesh.set_instance_color(entry.batch_index, _flat_color("gold") if legal else entry.base_color)
		var ring: MultiMeshInstance3D = entry.ring_batch
		ring.multimesh.set_instance_transform(entry.batch_index, tx)

func _update_highlight() -> void:
	if not is_instance_valid(_highlight): return
	super._update_highlight()
	_highlight.material_override = _material(_flat_color("gold"), true)

func _build_city_halos() -> void:
	for city in _flat_scene.data.cities:
		var item := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		var radius := float(city.dimensions[0]) * 0.9
		mesh.size = Vector2.ONE * radius * 2.0
		item.mesh = mesh
		item.position = _flat_position(_vec2(city.get("center_logical", city.logical)), 0.012)
		var material := ShaderMaterial.new()
		material.shader = HaloShader
		material.set_shader_parameter("halo_color", Color(str(_flat_scene.data.lighting.night.emissive.windows.color)))
		material.set_shader_parameter("night_enabled", 0.0)
		item.material_override = material
		item.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_flat_scene.world.add_child(item)
		_halo_materials.append(material)

func _set_flat_emission(value: bool) -> void:
	if not is_instance_valid(_flat_scene) or _flat_scene.data.is_empty(): return
	var preset: Dictionary = _flat_scene.data.lighting.night.emissive.route_dots
	for material in _route_emission_materials:
		material.emission_enabled = value
		material.emission = Color(str(preset.color))
		material.emission_energy_multiplier = float(preset.energy)
	for material in _halo_materials: material.set_shader_parameter("night_enabled", 1.0 if value else 0.0)

func get_map_debug_state() -> Dictionary:
	var result := super.get_map_debug_state()
	result.renderer = "flat_3d_isolated"
	result.world_shape = "flat"
	result.camera.projection = "orthogonal"
	result.camera.erase("radius")
	result.camera["size"] = _camera_size
	result.camera["overview_size"] = _overview_size
	result.camera["follow_size"] = _follow_size
	result["source_hashes"] = _flat_source_hashes
	result["lighting_preset"] = _lighting_preset
	result["flat_route_style"] = _route_style_counts
	result.camera["transition_seconds"] = CAMERA_TRANSITION_SECONDS
	result.camera["transitioning"] = _camera_transition != null and _camera_transition.is_running()
	return result
