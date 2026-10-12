extends Control
## Quick atlas view shares the exact production board, formal data and assets.
var board: Control
var _output := "res://docs/reports/astra-rebuild/captures/"
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var content:=GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var configs:=[{"display_name":"旅人","color_id":"red","controller_type":"LOCAL_HUMAN"},{"display_name":"商旅","color_id":"blue","controller_type":"LOCAL_HUMAN"}]
	SetupSystem.prepare_new_game(content,configs,20260916,"FORMAL")
	SetupSystem.finalize_new_game()
	board=preload("res://scripts/ui/miniworld_board_view.gd").new()
	board.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(board)
	board.set_selection_mode(false)
	board.city_inspect_requested.connect(func(id:String):board.focus_city(id,4.6))
	await get_tree().process_frame
	board.reset_camera_to_fit()
	if "--capture" in OS.get_cmdline_user_args():
		get_window().size=Vector2i(1600,1100)
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--output="):_output=arg.substr(9).trim_suffix("/")+"/"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output))
		board.set_display_mode("beauty")
		await capture("overview-day")
		board.set_lighting_preset("night")
		await capture("overview-night")
		board.focus_city("baghdad",4.6)
		await capture("baghdad-night")
		board.set_lighting_preset("day")
		await capture("baghdad-day")
		board.focus_city("changan",4.6)
		await capture("changan-day")
		board.focus_city("quanzhou",4.6)
		await capture("quanzhou-day")
		board.focus_city("yumenguan",3.8)
		await capture("mountain-pass")
		if not "--preview" in OS.get_cmdline_user_args():get_tree().quit()
func capture(id:String)->void:
	for i in range(18):await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_output+id+".png")
	print("ATLAS_CAPTURE ",_output+id+".png")
func _unhandled_key_input(event:InputEvent)->void:
	if not event is InputEventKey or not event.pressed:return
	if event.keycode==KEY_B:board.focus_city("baghdad",4.6)
	elif event.keycode==KEY_C:board.focus_city("changan",4.6)
	elif event.keycode==KEY_P:board.focus_city("quanzhou",4.6)
	elif event.keycode==KEY_H:board.set_display_mode("game" if board.display_mode=="beauty" else "beauty")
	elif event.keycode==KEY_ENTER:get_tree().change_scene_to_file("res://scenes/main.tscn")
