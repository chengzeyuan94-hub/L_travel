extends Node
## Native-resolution interactive preview of the production traveler scene.
var viewport:SubViewport
var host:Node3D
var review_ready:=false

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps=0
	viewport=SubViewport.new()
	viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d=Viewport.MSAA_4X
	add_child(viewport)
	host=load("res://scenes/traveler/traveler_main.tscn").instantiate()
	host.requested_view="changan"
	host.look_on=true
	host.look_far=true
	viewport.add_child(host)
	host.ui.visible=false
	var preview:=TextureRect.new()
	preview.texture=viewport.get_texture()
	preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	while not is_instance_valid(host.character_controller) or not host.character_controller.ready_for_input:
		await get_tree().process_frame
	review_ready=true

func _input(event:InputEvent) -> void:
	if not review_ready:return
	var copy:=event.duplicate() as InputEvent
	if copy is InputEventMouse:
		var size:Vector2=get_viewport().get_visible_rect().size
		var factor:float=minf(size.x/1920.0,size.y/1080.0)
		var offset:Vector2=(size-Vector2(1920,1080)*factor)*0.5
		copy.position=(event.position-offset)/factor
		copy.global_position=copy.position
	viewport.push_input(copy,true)
