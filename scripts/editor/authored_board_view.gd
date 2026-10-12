extends "res://scripts/ui/miniworld_board_view.gd"
const LayoutStore := preload("res://scripts/editor/map_layout_store.gd")
const AuthoredWorld := preload("res://scripts/editor/authored_world.gd")
var layout_path := LayoutStore.DEFAULT_GAME_PATH
var layout_data: Dictionary = {}
var layout_errors: Array[String] = []

func _create_world_builder() -> Node3D:
	layout_errors.clear()
	if layout_data.is_empty():
		var loaded := LayoutStore.load_layout(layout_path)
		if loaded.ok: layout_data = loaded.data
		else:
			for message in loaded.errors: layout_errors.append(str(message))
	var checked := LayoutStore.validate(layout_data, true)
	for message in checked.errors: layout_errors.append(str(message))
	var builder := AuthoredWorld.new()
	builder.layout = layout_data if layout_errors.is_empty() else LayoutStore.blank_layout()
	return builder

func is_ready_for_play() -> bool:
	return layout_errors.is_empty() and super.is_ready_for_play()

func get_missing_asset_paths() -> Array[String]:
	var result := super.get_missing_asset_paths()
	for message in layout_errors: result.append("Layout: " + message)
	return result

func reset_camera_to_fit() -> void:
	super.reset_camera_to_fit()
	if layout_data.is_empty(): return
	var settings: Dictionary = layout_data.get("visual_settings", {})
	_camera_yaw = float(settings.get("camera_yaw", -0.1))
	_camera_elevation = float(settings.get("camera_pitch", 0.7))
	_apply_camera_transform()

func _apply_camera_transform() -> void:
	if not is_instance_valid(_camera) or not _camera.is_inside_tree(): return
	var board: Dictionary = layout_data.get("board", {"width":60.0,"depth":20.0})
	var width := float(board.width)
	var depth := float(board.depth)
	_camera_elevation = clampf(_camera_elevation, deg_to_rad(25), deg_to_rad(85))
	_camera_center.x = clampf(_camera_center.x, -width * 0.6, width * 0.6)
	_camera_center.z = clampf(_camera_center.z, -depth * 0.75, depth * 0.75)
	var aspect := maxf(size.x, 1) / maxf(size.y, 1)
	var available := maxf(size.x - _right_safe_inset, size.x * 0.4) / maxf(size.x, 1)
	_overview_size = maxf(depth + 6, (width + 4) / maxf(aspect * available, 0.3))
	_camera_size = _overview_size / clampf(_zoom, 1, 6.5)
	_camera.size = _camera_size
	var right := Vector3(cos(_camera_yaw), 0, -sin(_camera_yaw))
	var target := _camera_center + right * (_camera_size * aspect * (1 - available) * 0.5)
	_camera.look_at_from_position(target + _camera_direction() * 90, target, Vector3.UP)
	_update_projected_labels()

func set_lighting_preset(preset: String) -> void:
	super.set_lighting_preset(preset)
	if _environment == null: return
	var night := preset == "night"
	_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_environment.background_color = Color("182b3f") if night else Color("dbe1d8")
	_environment.ambient_light_color = Color("82a8cf") if night else Color("e0e8dc")
	_environment.ambient_light_energy = 0.34 if night else 0.28
	_sun.light_color = Color("93b9ef") if night else Color("fff0d9")
	_sun.light_energy = 0.35 if night else 0.60
	_fill.light_color = Color("789acb") if night else Color("c5e2e4")
	_fill.light_energy = 0.07 if night else 0.10
