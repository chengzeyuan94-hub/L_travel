extends SceneTree
## Fixed 1080p live preview with input forwarded through the displayed texture.
var viewport:SubViewport
var preview:TextureRect

func _initialize() -> void:call_deferred("run")

func run() -> void:
	DisplayServer.window_set_title("山海之旅 · 盘橐 · 点击城池切换8秒 / 1清晨 / 2深夜 / 空格暂停")
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP,true)
	DisplayServer.window_move_to_foreground()
	viewport=SubViewport.new();viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true;viewport.msaa_3d=Viewport.MSAA_4X
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(viewport)
	preview=TextureRect.new();preview.texture=viewport.get_texture()
	preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.focus_mode=Control.FOCUS_ALL
	root.add_child(preview);preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview.gui_input.connect(forward_input);preview.grab_focus()
	viewport.add_child(load("res://scenes/traveler/panti_main.tscn").instantiate())

func forward_input(event:InputEvent) -> void:
	var forwarded:InputEvent=event.duplicate()
	if forwarded is InputEventMouse:
		var scale_factor:float=minf(preview.size.x/1920.0,preview.size.y/1080.0)
		var offset:Vector2=(preview.size-Vector2(1920,1080)*scale_factor)*0.5
		forwarded.position=(forwarded.position-offset)/scale_factor
		forwarded.global_position=forwarded.position
	viewport.push_input(forwarded,true)
	preview.accept_event()
