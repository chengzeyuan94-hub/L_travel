extends Control
## Explicit preview entry. Formal main scene remains on its previous renderer.
const Store := preload("res://scripts/editor/map_layout_store.gd")
const AuthoredBoard := preload("res://scripts/editor/authored_board_view.gd")
var _screen: Control
var _layout: Dictionary
var _layout_path := Store.DEFAULT_GAME_PATH
var _seed := 20260916

func _ready() -> void:
	DisplayServer.window_set_title("丝路商旅 · 用户布局预览")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--layout="): _layout_path = arg.substr(9)
		elif arg.begins_with("--seed="): _seed = int(arg.substr(7))
	var loaded := Store.load_layout(_layout_path)
	if not loaded.ok:
		_show_error(loaded.errors)
		return
	var checked := Store.validate(loaded.data, true)
	if not checked.ok:
		_show_error(checked.errors)
		return
	_layout = loaded.data
	_start()

func _start() -> void:
	if is_instance_valid(_screen):
		_screen.cancel_ai()
		remove_child(_screen)
		_screen.queue_free()
	GameState.reset_session()
	var content := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var configs: Array = [{"display_name":"玩家", "color_id":"red", "controller_type":"LOCAL_HUMAN"},
		{"display_name":"电脑商旅", "color_id":"blue", "controller_type":"AI"}]
	var prepared := SetupSystem.prepare_new_game(content, configs, _seed, "FORMAL")
	if not prepared.get("success", false):
		_show_error([str(prepared.get("message", "Could not prepare game."))])
		return
	var finalized := SetupSystem.finalize_new_game()
	if not finalized.get("success", false):
		_show_error([str(finalized.get("message", "Could not start game."))])
		return
	_screen = preload("res://scenes/game_screen.tscn").instantiate()
	var board: Control = _screen.get_node("%BoardView")
	board.set_script(AuthoredBoard)
	board.set("layout_path", _layout_path)
	board.set("layout_data", _layout.duplicate(true))
	add_child(_screen)
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_screen.show()
	_screen.on_game_started(configs)
	board.set_lighting_preset("night" if bool(_layout.get("visual_settings", {}).get("night", false)) else "day")
	_screen.back_to_title_requested.connect(func(): get_tree().quit())
	_screen.restart_requested.connect(func(_configs: Array): _start())
	if "--smoke" in OS.get_cmdline_user_args(): call_deferred("_smoke")

func _smoke() -> void:
	for i in range(12): await get_tree().process_frame
	var board: Control = _screen.get_node("%BoardView")
	var ready: bool = board.is_ready_for_play() and board.size.y > 100
	var moved := false
	var player := GameState.current_player()
	var rolled := TurnSystem.roll_die(3)
	if ready and bool(rolled.get("success", false)):
		var legal := MovementSystem.get_legal_destinations(player, player.movement_budget)
		var target := ""
		for id in legal:
			if str(id) != player.current_node_id:
				target = str(id)
				break
		if not target.is_empty():
			board.focus_logical_point(board._node_route_pos(target, board._current_route_type()))
			await get_tree().process_frame
			var point: Vector2 = board.world_to_screen(board._node_route_pos(target, board._current_route_type()))
			var down := InputEventMouseButton.new()
			down.button_index = MOUSE_BUTTON_LEFT
			down.position = point
			down.pressed = true
			board._gui_input(down)
			var up := down.duplicate() as InputEventMouseButton
			up.pressed = false
			board._gui_input(up)
			board.test_duration_override = 0.08
			_screen._on_confirm_move_pressed()
			var started := Time.get_ticks_msec()
			while board.animating and Time.get_ticks_msec() - started < 4000:
				await get_tree().process_frame
			moved = player.current_node_id == target and not board.animating
			board.reset_camera_to_fit()
	ready = ready and moved
	print("AUTHORED_GAME_PREVIEW ", JSON.stringify({"ok":ready,"selected_and_moved":moved,"layout":_layout_path,
		"nodes":board.miniature.anchors.size(),"routes":board.miniature.routes.size(),"cities":board.miniature.cities.size(),
		"board_size":str(board.size),"ruleset":GameState.content.ruleset.ruleset_id}))
	if "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var path := "res://artifacts/map_editor/authored-game-preview.png"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
		get_viewport().get_texture().get_image().save_png(path)
	_screen.cancel_ai()
	_screen.queue_free()
	for i in range(3): await get_tree().process_frame
	AudioManager.silence_all()
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if ready else 1)

func _show_error(messages: Array) -> void:
	var panel := RichTextLabel.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 30
	panel.offset_top = 30
	panel.offset_right = -30
	panel.offset_bottom = -30
	panel.text = "布局未通过正式规则校验，未启动对局。\n返回编辑器修复并重新导出。\n\n" + "\n".join(messages)
	add_child(panel)
	push_error(panel.text)
	if "--smoke" in OS.get_cmdline_user_args(): get_tree().quit(1)
