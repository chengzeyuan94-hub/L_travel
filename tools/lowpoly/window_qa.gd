extends Node
## WINDOW-only QA for the low-poly production board. All pointer/key events enter the root Viewport.
## Positions use get_global_transform_with_canvas(), so push_input(..., true)
## declares viewport-local coordinates and avoids a second stretch transform.
## Camera arrangement and deterministic scenario setup are test fixtures.
## This probe does not call BoardView._gui_input or emit gameplay signals.

const OUTPUT := "/tmp/silkroad_planet_gui_probe"
var _screen: Control
var _board: Control
var _hits: Array[String] = []
var _checks: Array[Dictionary] = []
var _report: Dictionary = {"test": "production GameScreen actual-window GUI routing", "screenshots": []}
var _last_mouse := Vector2.ZERO
var _finished := false


func _ready() -> void:
	call_deferred("_run")
	get_tree().create_timer(45.0).timeout.connect(_watchdog)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	_report["environment"] = {
		"display_server": DisplayServer.get_name(),
		"godot_version": Engine.get_version_info(),
		"cpu": OS.get_processor_name(),
		"device_context": "Local Apple M1 Ultra, as identified for this QA session",
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"window_size": _v2(DisplayServer.window_get_size()),
		"window_vsync_mode": DisplayServer.window_get_vsync_mode(),
		"root_viewport_size": _v2(get_viewport().get_visible_rect().size),
		"performance_scope": "One local window; VSync may cap FPS. Not a cross-device performance acceptance result."
	}
	if not _check(DisplayServer.get_name() != "headless", "requires_real_window"):
		_finish()
		return
	var content: Dictionary = GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var configs: Array = [
		{"display_name": "窗口验收", "color_id": "red", "controller_type": "LOCAL_HUMAN"},
		{"display_name": "AI", "color_id": "blue", "controller_type": "AI"}
	]
	var prepared: Dictionary = SetupSystem.prepare_new_game(content, configs, 2026090710, "FORMAL")
	if not _check(bool(prepared.get("success", false)), "formal_prepare", prepared):
		_finish()
		return
	var finalized: Dictionary = SetupSystem.finalize_new_game()
	if not _check(bool(finalized.get("success", false)), "formal_finalize", finalized):
		_finish()
		return
	# Scenario fixture only: central land city makes the camel and HUD pan observable.
	var player = GameState.current_player()
	player.current_node_id = "baghdad"
	player.active_transport = GameData.Transport.CAMEL
	_report["scenario"] = {"seed": 2026090710, "fixture_city": "baghdad", "fixture_transport": "CAMEL", "fixed_die_face": 5}
	_screen = (load("res://scenes/game_screen.tscn") as PackedScene).instantiate() as Control
	add_child(_screen)
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_screen.show()
	_screen.call("on_game_started", configs)
	_board = _screen.get_node("%BoardView") as Control
	_board.connect("node_clicked", func(id: String): _hits.append(id))
	await _frames(10)
	var initial: Dictionary = _board.call("get_map_debug_state")
	_report["map_initial"] = initial
	_check(initial.get("renderer") == "lowpoly_3d" and bool(initial.get("formal_world_mode", false)), "formal_3d_renderer")
	_check(initial.get("world_shape") == "sphere" and initial.get("camera", {}).get("projection") == "perspective", "real_sphere_with_perspective_camera")
	_check(int(initial.get("city_visual_count", 0)) == 16 and int(initial.get("route_polyline_count", 0)) == 57 and int(initial.get("piece_count", 0)) == 2, "formal_16_cities_57_edges_2_pieces")
	_check((initial.get("missing_assets", []) as Array).is_empty(), "no_missing_world_city_assets", initial.get("missing_assets", []))
	for actor in (_board.get("_pieces") as Dictionary).values():
		_check((actor.get("missing_models") as Array).is_empty(), "no_missing_vehicle_assets_" + str(actor.name), actor.get("missing_models"))
	_board.call("focus_current_player")
	await _frames(3)
	await _capture("01-camel-focus.png")
	await _key(KEY_R)
	await _frames(3)
	await _capture("00-planet-overview.png")
	_check(absf(float(_board.get("_zoom")) - 1.0) < 0.001, "viewport_r_key_shows_whole_planet")
	for step in range(12):
		await _key(KEY_E)
	_check(absf(float(_board.get("_camera_yaw"))) > 2.9, "viewport_orbit_reaches_opposite_hemisphere")
	await _capture("00-planet-far-side.png")
	await _key(KEY_F)
	var yaw_before := float(_board.get("_camera_yaw"))
	await _key(KEY_E)
	await _key(KEY_E)
	_check(absf(float(_board.get("_camera_yaw")) - yaw_before) > 0.1, "viewport_keyboard_rotates_camera")
	var player_logical: Vector2 = _board.call("_interaction_node_pos", "baghdad")
	var player_point: Vector2 = _board.call("world_to_screen", player_logical)
	var zoom_before := float(_board.get("_zoom"))
	await _wheel(_board.get_global_transform_with_canvas() * player_point, MOUSE_BUTTON_WHEEL_UP)
	_check(float(_board.get("_zoom")) > zoom_before, "actual_mouse_wheel_zooms_planet")
	var orbit_before := Vector2(float(_board.get("_camera_yaw")), float(_board.get("_camera_elevation")))
	var drag_from: Vector2 = _board.get_global_transform_with_canvas() * Vector2(260, 330)
	await _drag(drag_from, drag_from + Vector2(70, 24))
	var orbit_after := Vector2(float(_board.get("_camera_yaw")), float(_board.get("_camera_elevation")))
	_check(orbit_before.distance_to(orbit_after) > 0.05 and _hits.is_empty(), "actual_drag_rotates_globe_without_submitting_move")
	_board.call("focus_logical_point", player_logical, 3.2)
	await _frames(3)
	_report["camel_camera"] = (_board.call("get_map_debug_state") as Dictionary).get("camera", {})
	await _capture("02-camel-rotated-close.png")
	await _sample_performance()
	# Use the rules' fixed die entry point and production GameScreen selection logic.
	var rolled: Dictionary = TurnSystem.roll_die(5)
	_check(bool(rolled.get("success", false)), "fixed_die_enters_movement", rolled)
	_screen.call("_refresh")
	_screen.call("_refresh_move_selection")
	await _frames(4)
	var legal: Dictionary = MovementSystem.get_legal_destinations(player, player.movement_budget)
	var target := _choose_target(legal, player.current_node_id)
	if not _check(not target.is_empty(), "legal_target_exists", legal):
		_finish()
		return
	_report["target_id"] = target
	_report["legal_destinations"] = legal
	_board.call("focus_current_player")
	var safe_width := _board.size.x - float(_board.get("_right_safe_inset"))
	var map_local := Vector2(safe_width * 0.55, _board.size.y * 0.53)
	var map_arrangement := await _arrange_target(target, map_local)
	_report["unobstructed_precondition"] = map_arrangement
	if not _check(bool(map_arrangement["valid"]), "legal_target_projected_in_exposed_map", map_arrangement):
		_finish()
		return
	var map_global := _board.get_global_transform_with_canvas() * map_local
	await _motion(map_global)
	_report["unobstructed_hovered_control"] = _hovered_path()
	var hovered: Dictionary = _board.call("get_hover_debug_state")
	_report["route_hover"] = hovered
	_check(hovered.get("node_id", "") == target and not (hovered.get("path", []) as Array).is_empty(), "actual_mouse_motion_previews_route", hovered)
	await _capture("03-route-tooltip.png")
	await _click(map_global)
	var selected: Array = (_screen.get("_selected_path") as Array).duplicate()
	_report["selected_path"] = selected
	_check(_hits.size() == 1 and _hits[0] == target and selected.size() >= 2 and str(selected[-1]) == target, "actual_unobstructed_click_selects_route", {"hits": _hits.duplicate(), "path": selected})
	await _capture("04-route-selected.png")
	var before_hits := _hits.size()
	var before_node := str(player.current_node_id)
	var before_phase := int(GameState.phase)
	var hud: Control = _screen.get("_hud_scroll_root") as Control
	# Use the scroll's noninteractive paper margin to avoid pressing a real CTA.
	var hud_global := hud.get_global_transform_with_canvas() * Vector2(12.0, hud.size.y * 0.47)
	var hud_local := _board.get_global_transform_with_canvas().affine_inverse() * hud_global
	var hud_arrangement := await _arrange_target(target, hud_local, true)
	_report["hud_precondition"] = hud_arrangement
	if not _check(bool(hud_arrangement["valid"]), "same_legal_target_projected_under_scroll", hud_arrangement):
		_finish()
		return
	_check((_board.call("_pointer_target_at", hud_local) as Dictionary).is_empty(), "hud_safe_area_blocks_map_target_even_before_gui_dispatch")
	await _motion(hud_global)
	var hover_control: Control = get_viewport().gui_get_hovered_control()
	var hud_owns_pointer := hover_control != null and (hover_control == hud or hud.is_ancestor_of(hover_control))
	_check(hud_owns_pointer, "actual_gui_pointer_owned_by_scroll", _hovered_path())
	_report["hud_hovered_control"] = _hovered_path()
	await _click(hud_global)
	var after_path: Array = _screen.get("_selected_path") as Array
	_check(_hits.size() == before_hits and after_path == selected, "scroll_click_does_not_reach_map", {"before_hits": before_hits, "after_hits": _hits.size(), "selected_before": selected, "selected_after": after_path})
	_check(str(player.current_node_id) == before_node and int(GameState.phase) == before_phase and player.active_transport == GameData.Transport.CAMEL, "probe_clicks_do_not_commit_rule_move")
	await _capture("05-hud-occlusion.png")
	_report["final_hover"] = _board.call("get_hover_debug_state")
	_report["map_final"] = _board.call("get_map_debug_state")
	_finish()


func _choose_target(legal: Dictionary, current: String) -> String:
	var ids: Array = legal.keys()
	ids.sort()
	# One or two steps keeps the selected line and current camel in one shot.
	for id in ids:
		if str(id) != current and int(legal[id]) >= 1 and int(legal[id]) <= 2 and str(id).begins_with("land_"):
			return str(id)
	for id in ids:
		if str(id) != current:
			return str(id)
	return ""


func _arrange_target(target: String, desired: Vector2, under_hud: bool = false) -> Dictionary:
	var logical: Vector2 = _board.call("_interaction_node_pos", target)
	var result: Dictionary = {}
	# A spherical camera has angular degrees of freedom. Arrange the fixture by
	# solving its local projection Jacobian, without a fictitious flat-plane pan.
	# Actual pointer/key tests below still go through the root Viewport.
	for zoom in [2.6, 3.4, 4.5]:
		_board.call("focus_logical_point", logical, zoom)
		for attempt in range(24):
			var projected: Vector2 = _board.call("world_to_screen", logical)
			var error := desired - projected
			if error.length() < 1.0:
				break
			var yaw := float(_board.get("_camera_yaw"))
			var elevation := float(_board.get("_camera_elevation"))
			var epsilon := 0.001
			_board.set("_camera_yaw", yaw + epsilon)
			_board.call("_apply_camera_transform")
			var d_yaw: Vector2 = ((_board.call("world_to_screen", logical) as Vector2) - projected) / epsilon
			_board.set("_camera_yaw", yaw)
			_board.set("_camera_elevation", elevation + epsilon)
			_board.call("_apply_camera_transform")
			var d_elevation: Vector2 = ((_board.call("world_to_screen", logical) as Vector2) - projected) / epsilon
			var determinant := d_yaw.cross(d_elevation)
			if absf(determinant) < 0.001:
				_board.set("_camera_elevation", elevation)
				_board.call("_apply_camera_transform")
				break
			var yaw_step := error.cross(d_elevation) / determinant
			var elevation_step := d_yaw.cross(error) / determinant
			_board.set("_camera_yaw", yaw + clampf(yaw_step, -0.25, 0.25))
			_board.set("_camera_elevation", clampf(elevation + clampf(elevation_step, -0.25, 0.25), -1.25, 1.25))
			_board.call("_apply_camera_transform")
		await _frames(2)
		var actual: Vector2 = _board.call("world_to_screen", logical)
		var hit: Dictionary = _board.call("_pointer_target_at", desired)
		var visible: bool = _board.call("is_logical_point_visible", logical)
		var geometric_target: String = _board.call("_legal_node_at", desired)
		var target_matches: bool = geometric_target == target if under_hud else hit.get("kind", "") == "node" and hit.get("id", "") == target
		result = {"valid": visible and actual.distance_to(desired) < 3.0 and target_matches, "target": target, "desired_board_local": _v2(desired), "projected_board_local": _v2(actual), "error_px": actual.distance_to(desired), "read_only_target_test": hit, "geometry_only_legal_target": geometric_target, "under_hud": under_hud, "zoom": zoom, "surface_visible": visible, "camera": (_board.call("get_map_debug_state") as Dictionary).get("camera", {})}
		if bool(result["valid"]):
			break
	return result


func _wheel(point: Vector2, button: MouseButton) -> void:
	await _motion(point)
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = point
	event.global_position = point
	event.pressed = true
	get_viewport().push_input(event, true)
	await _frames(3)


func _drag(from_point: Vector2, to_point: Vector2) -> void:
	await _motion(from_point)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.position = from_point
	down.global_position = from_point
	down.pressed = true
	get_viewport().push_input(down, true)
	await _frames(2)
	var motion := InputEventMouseMotion.new()
	motion.position = to_point
	motion.global_position = to_point
	motion.relative = to_point - from_point
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	get_viewport().push_input(motion, true)
	_last_mouse = to_point
	await _frames(3)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = to_point
	up.global_position = to_point
	up.pressed = false
	get_viewport().push_input(up, true)
	await _frames(3)


func _motion(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	event.relative = point - _last_mouse
	_last_mouse = point
	get_viewport().push_input(event, true)
	await _frames(3)


func _click(point: Vector2) -> void:
	await _motion(point)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.position = point
	down.global_position = point
	down.pressed = true
	get_viewport().push_input(down, true)
	await _frames(2)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.position = point
	up.global_position = point
	up.pressed = false
	get_viewport().push_input(up, true)
	await _frames(4)


func _key(code: Key) -> void:
	var down := InputEventKey.new()
	down.keycode = code
	down.physical_keycode = code
	down.pressed = true
	get_viewport().push_input(down, true)
	await _frames(2)
	var up := InputEventKey.new()
	up.keycode = code
	up.physical_keycode = code
	up.pressed = false
	get_viewport().push_input(up, true)
	await _frames(2)


func _sample_performance() -> void:
	await _frames(8)
	var start := Time.get_ticks_usec()
	var frame_count := 0
	var draws: Array[float] = []
	var objects: Array[float] = []
	var primitives: Array[float] = []
	while Time.get_ticks_usec() - start < 2000000:
		await get_tree().process_frame
		frame_count += 1
		draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		objects.append(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
		primitives.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var seconds := float(Time.get_ticks_usec() - start) / 1000000.0
	var state: Dictionary = _board.call("get_map_debug_state")
	var render_viewport: SubViewport = _board.get("_viewport") as SubViewport
	var render_size := render_viewport.size if render_viewport != null else Vector2i.ZERO
	_check(render_size.x > 0 and render_size.y > 0, "actual_subviewport_has_nonzero_size", _v2(render_size))
	_report["performance"] = {"sample_seconds": seconds, "process_frames": frame_count, "observed_process_fps": frame_count / seconds, "engine_fps": Engine.get_frames_per_second(), "draw_calls": _stats(draws), "objects": _stats(objects), "primitives": _stats(primitives), "subviewport_size": _v2(render_size), "window_size": _v2(DisplayServer.window_get_size()), "root_viewport_size": _v2(get_viewport().get_visible_rect().size), "camera": state.get("camera", {}), "scope": "Total rendered frame including production HUD and 3D SubViewport; about 2 seconds on local M1 Ultra. VSync may cap FPS; not a cross-device target verdict."}


func _stats(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {}
	var total := 0.0
	for value in values:
		total += value
	return {"mean": total / values.size(), "min": values.min(), "max": values.max()}


func _capture(filename: String) -> void:
	await RenderingServer.frame_post_draw
	var screenshot := get_viewport().get_texture().get_image()
	var path := OUTPUT.path_join(filename)
	var error := screenshot.save_png(path)
	_check(error == OK, "screenshot_" + filename, {"path": path, "size": [screenshot.get_width(), screenshot.get_height()], "error": error})
	(_report["screenshots"] as Array).append(path)


func _hovered_path() -> String:
	var hovered: Control = get_viewport().gui_get_hovered_control()
	return str(hovered.get_path()) if hovered != null else "<none>"


func _v2(value: Variant) -> Array:
	return [value.x, value.y]


func _frames(count: int) -> void:
	for index in range(count):
		await get_tree().process_frame


func _check(passed: bool, label: String, evidence: Variant = null) -> bool:
	_checks.append({"name": label, "passed": passed, "evidence": evidence})
	print("LOWPOLY_GUI_CHECK ", "PASS " if passed else "FAIL ", label)
	return passed


func _watchdog() -> void:
	if not _finished:
		_check(false, "watchdog_timeout_45_seconds")
		_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	var failures := 0
	for item in _checks:
		if not bool(item["passed"]):
			failures += 1
	_report["checks"] = _checks
	_report["passed"] = failures == 0
	_report["failure_count"] = failures
	var file := FileAccess.open(OUTPUT.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_report, "\t"))
		file.close()
	print("LOWPOLY_GUI_PROBE_RESULT ", JSON.stringify({"passed": failures == 0, "failures": failures, "report": OUTPUT.path_join("report.json")}))
	if is_instance_valid(_screen):
		_screen.call("cancel_ai")
	AudioManager.silence_all()
	get_tree().quit(0 if failures == 0 else 1)
