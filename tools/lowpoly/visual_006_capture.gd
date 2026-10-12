extends Node
## Visual evidence only. Scenario placement is a fixture, not a gameplay command.
## Run after window_qa, never concurrently with another window test.

const OUTPUT := "res://docs/design/planet-v2/validation/visual-006/detail-captures"
var _screen: Control
var _board: Control
var _report := {"visual_revision": "TASK-PLANET-VISUAL-006", "captures": []}


func _ready() -> void:
	call_deferred("_run")
	get_tree().create_timer(30.0).timeout.connect(func():
		push_error("Visual capture timed out.")
		get_tree().quit(1))


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Visual capture requires a real window.")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var content := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var configs := [
		{"display_name": "地图验收", "color_id": "red", "controller_type": "LOCAL_HUMAN"},
		{"display_name": "AI", "color_id": "blue", "controller_type": "AI"},
	]
	var prepared := SetupSystem.prepare_new_game(content, configs, 2026090701, "FORMAL")
	if not prepared.get("success", false) or not SetupSystem.finalize_new_game().get("success", false):
		get_tree().quit(1)
		return
	_screen = (load("res://scenes/game_screen.tscn") as PackedScene).instantiate() as Control
	add_child(_screen)
	_screen.show()
	_screen.call("on_game_started", configs)
	_board = _screen.get_node("%BoardView") as Control
	await _frames(12)
	# Five review locations plus the remaining real transport interchanges.
	for city_id in ["constantinople", "baghdad", "jeddah", "cairo", "rome", "geumseong", "simhala", "quanzhou"]:
		var node: Dictionary = content["board_nodes"][city_id]
		var player = GameState.current_player()
		player.current_node_id = city_id
		player.active_transport = GameData.Transport.SHIP if "SEA" in node.get("allowed_routes", []) else GameData.Transport.CAMEL
		_board.call("_sync_pieces")
		var xy: Vector2 = node["map_position"]
		_board.call("focus_logical_point", xy + Vector2(0, -45.0), 3.2)
		await _frames(4)
		await _capture("city-" + city_id + ".png")
	# A fixed rear-ocean composition: only the water shader animates between frames.
	_board.call("focus_logical_point", Vector2(-650, 750), 1.0)
	await _frames(4)
	await _capture("water-t0.png")
	await get_tree().create_timer(2.0).timeout
	await _capture("water-t2.png")
	var viewport: SubViewport = _board.get("_viewport")
	var elapsed: Array[float] = []
	var began := Time.get_ticks_usec()
	var previous := began
	while Time.get_ticks_usec() - began < 5000000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		elapsed.append(float(now - previous) / 1000.0)
		previous = now
	elapsed.sort()
	_report["performance"] = {
		"scope": "One local five-second sample with VSync; no cross-device claim.",
		"window_size": str(DisplayServer.window_get_size()),
		"subviewport_size": str(viewport.size),
		"renderer": RenderingServer.get_current_rendering_method(),
		"device": RenderingServer.get_video_adapter_name(),
		"sample_frames": elapsed.size(),
		"median_frame_ms": elapsed[elapsed.size() / 2],
		"p95_frame_ms": elapsed[int(elapsed.size() * .95)],
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
	}
	var file := FileAccess.open(OUTPUT.path_join("report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(_report, "\t"))
	file.close()
	_screen.call("cancel_ai")
	AudioManager.silence_all()
	print("VISUAL_006_CAPTURE_COMPLETE ", JSON.stringify(_report["performance"]))
	get_tree().quit()


func _frames(count: int) -> void:
	for index in range(count):
		await get_tree().process_frame


func _capture(filename: String) -> void:
	await RenderingServer.frame_post_draw
	var result := get_viewport().get_texture().get_image().save_png(OUTPUT.path_join(filename))
	if result != OK:
		push_error("Screenshot save failed: " + filename)
		get_tree().quit(1)
	(_report["captures"] as Array).append(filename)
