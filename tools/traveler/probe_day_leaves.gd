extends SceneTree
## S6 diagnostic only. Required --leaf-output=<new directory>. No resource writes.
var viewport: SubViewport
var viewer: Node3D
var leaves: Node3D
var output := ""
var samples: Array=[]

func _initialize() -> void:
	call_deferred("run")

func write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:
		push_error("Cannot write leaf evidence: "+path)
		quit(1)
		return
	file.store_string(JSON.stringify(value,"\t"))
	file.close()

func capture(second: int) -> void:
	var image := viewport.get_texture().get_image()
	var path := output+"/f%04d.png" % second
	var error := image.save_png(path)
	if error!=OK:push_error("Leaf mask capture failed: "+path)
	var record := {"time_s":second,"image_size":[image.get_width(),image.get_height()],"viewport_size":[viewport.size.x,viewport.size.y],"capture_error":error,"anim_t":viewer.motion_director.anim_t,"file":path,"diagnostic_only":true}
	samples.append(record)
	write_json(path.trim_suffix(".png")+".json",record)

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--leaf-output="):output=arg.trim_prefix("--leaf-output=")
	if output.is_empty() or DisplayServer.get_name()=="headless":
		push_error("Leaf mask requires a real renderer and --leaf-output=<new evidence directory>")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	viewport=SubViewport.new()
	viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true
	viewport.msaa_3d=Viewport.MSAA_4X
	viewport.use_taa=false
	viewport.screen_space_aa=Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP,true)
	DisplayServer.window_move_to_foreground()
	var preview := TextureRect.new()
	preview.texture=viewport.get_texture()
	preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewer=load("res://scenes/traveler/traveler_main.tscn").instantiate()
	viewport.add_child(viewer)
	assert(viewer.look_on and viewer.look_far and viewer.selected=="changan","Use --day --far --view=changan")
	viewer.ui.visible=false
	viewer.set_process(false)
	viewer.set_process_unhandled_input(false)
	viewer.camera.make_current()
	viewer.motion_director.externally_clocked=true
	var only_leaves: Array[String]=["leaves"]
	viewer.motion_director.set_active_items(only_leaves)
	viewer.motion_director.set_motion_enabled(true)
	viewer.motion_director.apply_time(0.0)
	Engine.max_fps=0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	leaves=viewer.motion_director.day_components.leaves
	var original_evidence: Dictionary=leaves.evidence()
	var original_look: Dictionary=viewer.look_profile.lk.duplicate(true)
	var black := StandardMaterial3D.new()
	black.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color=Color.BLACK
	black.cull_mode=BaseMaterial3D.CULL_DISABLED
	for node in viewer.world.find_children("*","GeometryInstance3D",true,false):
		if node!=leaves.particles:node.material_override=black
	leaves.set_diagnostic_mask(true)
	viewer.environment.background_mode=Environment.BG_COLOR
	viewer.environment.background_color=Color.BLACK
	viewer.environment.glow_enabled=false
	viewer.environment.fog_enabled=false
	viewer.environment.adjustment_enabled=false
	viewer.environment.tonemap_mode=Environment.TONE_MAPPER_LINEAR
	viewer.environment.tonemap_exposure=1.0
	viewer.environment.ssil_enabled=false
	viewer.environment.ssao_enabled=false
	viewer.environment.ambient_light_energy=0
	for frame in 60:
		await process_frame
		await RenderingServer.frame_post_draw
	capture(0)
	for frame in range(1,301):
		await process_frame
		viewer.motion_director.apply_time(float(frame)/30.0)
		await RenderingServer.frame_post_draw
		if frame%30==0:capture(frame/30)
	var half: Vector3=leaves.process_material.emission_box_extents
	var depth_range := [INF,-INF]
	for x in [-1.0,1.0]:
		for y in [-1.0,1.0]:
			for z in [-1.0,1.0]:
				var corner: Vector3=leaves.global_transform*Vector3(half.x*x,half.y*y,half.z*z)
				var camera_point: Vector3=viewer.camera.global_transform.affine_inverse()*corner
				depth_range[0]=minf(depth_range[0],-camera_point.z)
				depth_range[1]=maxf(depth_range[1],-camera_point.z)
	write_json(output+"/leaf-mask-evidence.json",{"schema":"traveler.s6.leaf-mask.v1","diagnostic_only":true,"image_size":[1920,1080],"viewport_size":[1920,1080],"frozen_camera":viewer.motion_params._measured.traveler_camera,"original_look_params":original_look,"leaf_evidence":original_evidence,"emission_camera_depth_range_u":depth_range,"emission_box_volume_u3":8.0*half.x*half.y*half.z,"particle_depth_readback":false,"depth_proof":"Emission box corners transformed with actual frozen camera; leaf shader discards particle origins outside configured clear depth 5.5..19. This is construction/clip evidence, not per-particle GPU position readback.","simulation_step_s":1.0/30.0,"samples":samples,"method":"Only leaf layer active. Same geometry, camera and DOF. Other geometry is transient black unshaded depth occlusion; leaves white emission. Black background; fog/glow/SSAO/SSIL/adjustment disabled; linear exposure1 for mask. No resources saved."})
	print("LEAF_MASK_EVIDENCE ",JSON.stringify({"samples":samples.size(),"image_size":[1920,1080],"emission_camera_depth_range_u":depth_range}))
	viewer.queue_free()
	await process_frame
	await process_frame
	quit()
