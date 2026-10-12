extends Node

## Does a fixed-size SubViewport really render at 1920x1080 on this machine,
## even though the window itself cannot be that large?
func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1920, 1080)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = false
	add_child(sv)

	var world := Node3D.new()
	sv.add_child(world)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.17, 0.30)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.75, 0.9)
	env.ambient_light_energy = 0.6
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-35.0), deg_to_rad(40.0), 0.0)
	sun.shadow_enabled = true
	world.add_child(sun)

	for i in 3:
		var m := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(1.0, 1.0 + float(i) * 0.6, 1.0)
		m.mesh = box
		m.position = Vector3(float(i) * 1.6 - 1.6, box.size.y * 0.5, 0.0)
		world.add_child(m)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	ground.mesh = plane
	world.add_child(ground)

	var cam := Camera3D.new()
	cam.fov = 36.0
	cam.position = Vector3(4.0, 3.0, 7.0)
	world.add_child(cam)
	cam.look_at(Vector3(0, 0.8, 0))
	cam.make_current()

	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var img := sv.get_texture().get_image()
	var err := img.save_png("res://subviewport_capture.png")
	var win := DisplayServer.window_get_size()
	print("SUBVIEWPORT_PROBE ", JSON.stringify({
		"requested": [1920, 1080],
		"subviewport_size": [sv.size.x, sv.size.y],
		"image_size": [img.get_width(), img.get_height()],
		"window_size": [win.x, win.y],
		"root_viewport": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"save_error": err,
		"renderer": RenderingServer.get_current_rendering_method(),
	}))
	get_tree().quit()
