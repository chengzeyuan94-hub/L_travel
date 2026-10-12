extends Node
## Captures the production GameScreen. Camera/actor placement below are evidence
## fixtures, never new game commands. Run GUI probes serially.

const OUTPUT := "res://docs/design/planet-v2/validation/variation-007"
const FRAMES := "/tmp/silkroad-variation-007-frames"
var _screen: Control
var _board: Control
var _report: Dictionary = {"task": "TASK-PLANET-VARIATION-007", "captures": [], "sequences": []}
var _mode := "stills"


func _ready() -> void:
	_mode = OS.get_environment("SILKROAD_VARIATION_CAPTURE_MODE")
	if _mode.is_empty():
		_mode = "stills"
	call_deferred("_run")
	get_tree().create_timer(180.0, true, false, true).timeout.connect(func():
		push_error("VARIATION_007_CAPTURE_TIMEOUT")
		get_tree().quit(1))


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Capture requires a real rendered window.")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT.path_join("captures")))
	var content := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var configs := [
		{"display_name": "地图验收", "color_id": "red", "controller_type": "LOCAL_HUMAN"},
		{"display_name": "AI", "color_id": "blue", "controller_type": "AI"},
	]
	var prepared := SetupSystem.prepare_new_game(content, configs, 2026090710, "FORMAL")
	if not prepared.get("success", false) or not SetupSystem.finalize_new_game().get("success", false):
		get_tree().quit(1)
		return
	var player = GameState.current_player()
	player.current_node_id = "baghdad"
	player.active_transport = GameData.Transport.CAMEL
	_screen = (load("res://scenes/game_screen.tscn") as PackedScene).instantiate() as Control
	add_child(_screen)
	_screen.show()
	_screen.call("on_game_started", configs)
	_screen.call("cancel_ai")
	_board = _screen.get_node("%BoardView") as Control
	await _frames(12)
	_report["mode"] = _mode
	_report["environment"] = {"godot": Engine.get_version_info(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"device": RenderingServer.get_video_adapter_name(),
		"source_sha256": _source_hashes(),
		"window_size": str(DisplayServer.window_get_size()),
		"viewport_size": str((_board.get("_viewport") as SubViewport).size),
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"window_vsync_mode": DisplayServer.window_get_vsync_mode(),
		"note": "Capture fixtures in production renderer; performance is measured separately without movie writing or screenshot I/O."}
	if _mode == "motion":
		Engine.max_fps = 30
		_board.reset_camera_to_fit()
		await _frames(12)
		await _sequence("front", 90)
		_board.focus_logical_point(Vector2(-650, 750), 1.0)
		await _frames(12)
		await _sequence("back", 90)
		await _hidden_sequence()
	elif _mode == "draw_probe":
		await _draw_probe()
	elif _mode == "performance":
		_report["performance"] = []
		for view in [Vector3(2048, 520, 1.0), Vector3(-650, 750, 1.0), Vector3(2220, 1120, 2.7), Vector3(3103, 614, 2.7)]:
			_board.focus_logical_point(Vector2(view.x, view.y), view.z)
			await _frames(30)
			(_report["performance"] as Array).append(await _sample_performance())
	elif _mode == "film":
		await _film(content, player)
	elif _mode == "actors":
		await _actor_evidence(content, player)
	else:
		_board.reset_camera_to_fit()
		await _frames(8)
		await _capture("playable-world-view.png")
		for view in [
			["far-side", Vector2(-650, 750), 1.0],
			["desert", Vector2(2420, 570), 2.8],
			["iran-oasis", Vector2(1775, 625), 3.1],
			["mountains", Vector2(2450, 310), 2.6],
			["forest", Vector2(2850, 360), 2.8],
			["monsoon", Vector2(2220, 1120), 3.0],
			["quanzhou-harbor", Vector2(3103, 614), 2.8],
			["polar-ice", Vector2(300, -300), 2.2],
			["whale-ocean", Vector2(-682.6667, 281.5), 2.8],
		]:
			_board.focus_logical_point(view[1], view[2])
			await _frames(8)
			await _capture(String(view[0]) + ".png")
		_board.focus_current_player()
		await _frames(8)
		await _capture("playable-player-view.png")
	var file := FileAccess.open(OUTPUT.path_join(_mode + "-report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(_report, "\t"))
	file.close()
	_screen.call("cancel_ai")
	_board.cancel_all_animations()
	AudioManager.silence_all()
	print("VARIATION_007_CAPTURE_COMPLETE mode=", _mode)
	get_tree().quit()


func _source_hashes() -> Dictionary:
	var hashes := {}
	for path in ["assets/game/lowpoly/planet/terrain.glb", "assets/game/lowpoly/planet/water.glb",
		"scripts/ui/lowpoly_board_view.gd", "scripts/ui/lowpoly_map_piece_actor.gd", "scripts/ui/planet_ambient_layer.gd",
		"scripts/ui/ambient/ambient_meshes.gd", "scripts/ui/ambient/ambient_motion.gdshader", "scripts/ui/ambient/placements.json",
		"scripts/ui/shaders/planet_water.gdshader", "tools/lowpoly/variation_007_capture.gd"]:
		hashes[path] = FileAccess.get_sha256("res://" + path)
	return hashes


func _capture(filename: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(OUTPUT.path_join("captures").path_join(filename))
	if error != OK:
		push_error("Capture failed " + filename)
	var entry := _view_evidence()
	entry["image"] = filename
	(_report["captures"] as Array).append(entry)


func _view_evidence() -> Dictionary:
	var ambient: Node3D = _board.get("_ambient")
	var camera: Camera3D = _board.get("_camera")
	var anchors: Array = []
	for anchor in ambient.get_motion_anchors():
		var world: Vector3 = anchor.get("world_position", Vector3.ZERO)
		var screen: Vector2 = _board.call("_project", world)
		var entry: Dictionary = anchor.duplicate()
		entry["pixel"] = [screen.x + _board.global_position.x, screen.y + _board.global_position.y]
		entry["camera_front"] = not camera.is_position_behind(world)
		entry["hemisphere_visible"] = PlanetGeometry.is_front_facing(world, camera.position)
		anchors.append(entry)
	return {"camera": _board.get_map_debug_state()["camera"], "ambient": ambient.get_diagnostics(), "anchors": anchors}


func _sequence(id: String, count: int) -> void:
	var directory := FRAMES.path_join(id)
	DirAccess.make_dir_recursive_absolute(directory)
	var entry := _view_evidence()
	entry["id"] = id
	entry["directory"] = directory
	entry["frame_count"] = count
	entry["started_usec"] = Time.get_ticks_usec()
	for index in range(count):
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		image.save_png(directory.path_join("%04d.png" % index))
		if index == 0 or index == count - 1:
			image.save_png(OUTPUT.path_join("captures/%s-%s.png" % [id, "start" if index == 0 else "end"]))
	entry["ended_usec"] = Time.get_ticks_usec()
	entry["end"] = _view_evidence()
	(_report["sequences"] as Array).append(entry)


func _hidden_sequence() -> void:
	var viewport: SubViewport = _board.get("_viewport")
	var ambient: Node3D = _board.get("_ambient")
	_board.hide()
	await _frames(3)
	var before: Dictionary = ambient.get_diagnostics()
	var hashes: Array[String] = []
	for index in range(31):
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(image.get_data())
		hashes.append(hash.finish().hex_encode())
		if index == 0 or index == 30:
			image.save_png(OUTPUT.path_join("captures/hidden-%d.png" % index))
	_report["hidden"] = {"hashes": hashes, "before": before, "after": ambient.get_diagnostics(),
		"clock_frozen": before.get("clock") == ambient.get_diagnostics().get("clock"),
		"viewport_update_disabled": viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED}
	_board.show()


func _draw_probe() -> void:
	var ambient: Node3D = _board.get("_ambient")
	var rows: Array = []
	for point in [Vector2(2048,520), Vector2(-650,750)]:
		_board.focus_logical_point(point, 1.0)
		await _frames(30)
		rows.append({"point": str(point), "case": "full", "draw": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)})
		for marker in _board.get("_markers"):
			(marker["mesh"] as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		await _frames(12)
		rows.append({"point": str(point), "case": "full_marker_shadows_off", "draw": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)})
		await _capture("marker-shadows-off-" + ("front" if point.x > 0 else "back") + ".png")
		for marker in _board.get("_markers"):
			(marker["mesh"] as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		await _frames(12)
		ambient.hide()
		await _frames(12)
		rows.append({"point": str(point), "case": "no_ambient", "draw": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)})
		ambient.show()
		var children: Array[Node] = ambient.get_children()
		for child in children:
			if child is Node3D:
				child.hide()
		for child in children:
			if child is Node3D:
				child.show()
				await _frames(8)
				rows.append({"point": str(point), "case": String(child.name), "draw": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)})
				child.hide()
		for child in children:
			if child is Node3D:
				child.show()
	_report["draw_probe"] = rows


func _sample_performance() -> Dictionary:
	var durations: Array[float] = []
	var draws: Array[float] = []
	var began := Time.get_ticks_usec()
	var previous := began
	while Time.get_ticks_usec() - began < 5000000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		durations.append(float(now - previous) / 1000.0)
		draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		previous = now
	durations.sort()
	return {"camera": _board.get_map_debug_state()["camera"], "frames": durations.size(),
		"median_ms": durations[durations.size() / 2], "p95_ms": durations[int(durations.size() * 0.95)],
		"draw_calls_min": draws.min(), "draw_calls_max": draws.max(),
		"ambient": (_board.get("_ambient") as Node3D).get_diagnostics(),
		"particle_budget": _particle_budget()}


func _particle_budget() -> Dictionary:
	var nodes: Array[Node] = [_board.get("_world") as Node]
	var capacity := 0
	var emitting_capacity := 0
	var systems := 0
	var casts_shadows := 0
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		for child in node.get_children():
			nodes.append(child)
		if node is CPUParticles3D:
			systems += 1
			capacity += node.amount
			if node.emitting:
				emitting_capacity += node.amount
			if node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				casts_shadows += 1
	return {"whole_world_capacity": capacity, "emitting_capacity": emitting_capacity,
		"systems": systems, "systems_casting_shadows": casts_shadows}


func _film(content: Dictionary, player) -> void:
	_board.reset_camera_to_fit()
	await _frames(90)
	await _glide(Vector2(2420, 570), 2.8, 65)
	await _frames(105)
	await _glide(Vector2(2850, 360), 2.8, 65)
	await _frames(100)
	await _glide(Vector2(1775, 625), 3.1, 60)
	await _frames(105)
	await _glide(Vector2(2220, 1120), 3.0, 75)
	await _frames(150)
	await _travel(content, player, "edge_land_baghdad__land_baghdad_panti_01", GameData.Transport.CAMEL, 180)
	await _travel(content, player, "edge_sea_quanzhou__sea_quanzhou_geumseong_01", GameData.Transport.SHIP, 180)
	await _glide(Vector2(-650, 750), 1.0, 120)
	await _frames(90)
	await _glide(Vector2(-682.6667, 281.5), 2.8, 60)
	await _frames(120)
	await _glide(Vector2(300, -300), 2.2, 80)
	await _frames(90)
	await _glide(Vector2(2048, 681.5 - .18 * 2400.0 / PI), 1.0, 105)
	await _frames(90)


func _glide(point: Vector2, zoom: float, frames: int) -> void:
	var state: Dictionary = _board.get_map_debug_state()["camera"]
	var start_yaw := float(state["yaw"])
	var start_elevation := float(state["elevation"])
	var start_zoom := float(state["zoom_factor"])
	var target_yaw := (point.x - 2048.0) * TAU / 6144.0
	var target_elevation := (681.5 - point.y) * PI / 2400.0
	for index in frames:
		var t := smoothstep(0.0, 1.0, float(index + 1) / frames)
		var yaw := lerp_angle(start_yaw, target_yaw, t)
		var elevation := lerpf(start_elevation, target_elevation, t)
		_board.focus_logical_point(Vector2(2048.0 + yaw * 6144.0 / TAU,
			681.5 - elevation * 2400.0 / PI), lerpf(start_zoom, zoom, t))
		await get_tree().process_frame


func _travel(content: Dictionary, player, edge_id: String, transport: int, frames: int) -> void:
	_start_route(content, player, edge_id, transport)
	await _frames(frames)


func _start_route(content: Dictionary, player, edge_id: String, transport: int) -> Node3D:
	# Playback fixture uses exact formal polylines, with no writes to rule data.
	for edge in content.get("board_edges", []):
		if String(edge.get("id", "")) != edge_id:
			continue
		var route := PackedVector2Array()
		for point in edge.get("movement_polyline", []):
			route.append(Vector2(point[0], point[1]) if point is Array else point)
		var actor: Node3D = (_board.get("_pieces") as Dictionary)[player.player_id]
		actor.set_transport(transport)
		actor.set_logical_position(route[0])
		var lengths := PackedFloat32Array([0.0])
		var total := 0.0
		for i in range(1, route.size()):
			total += route[i - 1].distance_to(route[i])
			lengths.append(total)
		_board.focus_logical_point(route[route.size() / 2], 3.2)
		actor.play_path(route, lengths, total, 5.0)
		return actor
	push_error("Missing capture route: " + edge_id)
	return null


func _actor_evidence(content: Dictionary, player) -> void:
	for fixture in [["camel", "edge_land_baghdad__land_baghdad_panti_01", GameData.Transport.CAMEL],
		["ship", "edge_sea_quanzhou__sea_quanzhou_geumseong_01", GameData.Transport.SHIP]]:
		var actor := _start_route(content, player, fixture[1], fixture[2])
		await get_tree().create_timer(2.4).timeout
		await _capture(fixture[0] + "-moving.png")
		_report[fixture[0] + "_moving"] = actor.get_motion_effects_debug_state()
		await get_tree().create_timer(2.8).timeout
		await _capture(fixture[0] + "-draining.png")
		_report[fixture[0] + "_draining"] = actor.get_motion_effects_debug_state()
		await get_tree().create_timer(1.4).timeout
		await _capture(fixture[0] + "-finished.png")
		_report[fixture[0] + "_finished"] = actor.get_motion_effects_debug_state()


func _frames(count: int) -> void:
	for index in range(count):
		await get_tree().process_frame
