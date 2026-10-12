extends SceneTree
## Same-process appearance comparison; never writes source assets or presets.
var output:=""
var wrapper:Node
var host:Node3D
var cc:Node3D
var source:MeshInstance3D
var report:Dictionary={}

func _initialize() -> void:call_deferred("run")

func settle(frames:int=30) -> void:
	for _i in frames:await RenderingServer.frame_post_draw

func write_json(name:String,value:Dictionary) -> void:
	FileAccess.open(output+"/"+name+".json",FileAccess.WRITE).store_string(JSON.stringify(value,"\t"))

func geometry() -> Dictionary:
	var posed:=source.bake_mesh_from_current_skeleton_pose()
	var minimum:=Vector2(INF,INF);var maximum:=Vector2(-INF,-INF)
	var low_y:=INF
	for surface in posed.get_surface_count():
		for vertex in posed.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			var world:Vector3=source.global_transform*vertex
			var pixel:Vector2=host.camera.unproject_position(world)
			minimum=minimum.min(pixel);maximum=maximum.max(pixel);low_y=minf(low_y,world.y)
	var center:Vector3=source.global_transform*posed.get_aabb().get_center()
	var grow_world:float=float(cc.appearance.settings.outline.grow_amount_model_u)*cc.actor.scale.x
	var projected_grow:float=host.camera.unproject_position(center).distance_to(host.camera.unproject_position(center+host.camera.global_basis.x*grow_world))
	return {"projected_skinned_vertex_bounds_px":[minimum.x,minimum.y,maximum.x,maximum.y],"projected_skinned_vertex_height_px":maximum.y-minimum.y,"projected_grow_radius_px_estimate":projected_grow,"grow_projection_note":"Geometric projection, not a raster measurement; measured silhouette expansion is in measurements.json.","foot_mesh_min_world_y":low_y,"floor_world_y":cc.actor.global_position.y,"scale":cc.actor.scale.x,"model_pose_height":cc.model_height}

func capture(label:String) -> Dictionary:
	await settle(120)
	var times:Array[float]=[]
	var previous:=Time.get_ticks_usec()
	for _i in 180:
		await RenderingServer.frame_post_draw
		var now:=Time.get_ticks_usec()
		times.append(float(now-previous)/1000.0);previous=now
	var global_draws:=RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var viewport_draws:int=wrapper.viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var sorted:=times.duplicate();sorted.sort()
	var image:Image=wrapper.viewport.get_texture().get_image()
	var error:=image.save_png(output+"/"+label+".png")
	var evidence:Dictionary={"image_size":[image.get_width(),image.get_height()],"viewport_size":[1920,1080],"capture_error":error,"view":host.requested_view,"renderer":RenderingServer.get_current_rendering_method(),"draw_calls":global_draws,"viewport_draw_calls":viewport_draws,"frame_ms":{"p50":sorted[89],"p95":sorted[170],"sample_count":times.size(),"samples":times,"method":"monotonic wall time between frame_post_draw signals; same process, frozen environment and pose; excludes texture readback","warmup_frames":120,"vsync_disabled":DisplayServer.window_get_vsync_mode()==DisplayServer.VSYNC_DISABLED,"engine_max_fps":Engine.max_fps},"character":cc.evidence(),"geometry":geometry(),"look":host.look_profile.evidence(image),"frozen_camera":host.motion_params._measured.traveler_camera,"camera_transform":str(host.camera.global_transform),"camera_fov":host.camera.fov,"motion_anim_t":host.motion_director.anim_t,"motion_frozen":not host.motion_director.motion_enabled,"dusk_lights":{"fill_energy":cc.dusk_fill.light_energy,"rim_energy":cc.dusk_rim.light_energy,"cull_mask":cc.dusk_fill.light_cull_mask},"process_id":OS.get_process_id(),"command":{"executable":OS.get_executable_path(),"args":OS.get_cmdline_args(),"user_args":OS.get_cmdline_user_args()}}
	write_json(label,evidence)
	print("STYLE_CAPTURE ",label," ",JSON.stringify({"geometry":evidence.geometry,"draw_calls":global_draws,"viewport_draw_calls":viewport_draws,"p50":sorted[89],"p95":sorted[170]}))
	return evidence

func masks(before:bool=false) -> void:
	var camera:Camera3D=host.camera
	var old_mask:=camera.cull_mask
	var old_environment:=camera.environment
	var old_attributes:=camera.attributes
	var old_material:=source.material_override
	var shell:MeshInstance3D=cc.appearance.shells[0]
	var old_outline:=shell.material_override
	var old_visible:=shell.visible
	var white:=StandardMaterial3D.new()
	white.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	white.albedo_color=Color.WHITE
	source.material_override=white
	var white_outline:=old_outline.duplicate() as StandardMaterial3D
	white_outline.albedo_color=Color.WHITE
	shell.material_override=white_outline
	var plain:=Environment.new()
	plain.background_mode=Environment.BG_COLOR
	plain.background_color=Color.BLACK
	plain.tonemap_mode=Environment.TONE_MAPPER_LINEAR
	camera.environment=plain
	camera.attributes=null
	camera.cull_mask=cc.CHARACTER_LIGHT_LAYER
	for label in (["mask-before"] if before else ["mask-body","mask-outline"]):
		shell.visible=label=="mask-outline"
		await settle(8)
		wrapper.viewport.get_texture().get_image().save_png(output+"/"+label+".png")
	shell.visible=old_visible
	source.material_override=old_material;shell.material_override=old_outline
	camera.cull_mask=old_mask;camera.environment=old_environment;camera.attributes=old_attributes
	report["mask_method"]="Same pose/scale/camera and 4x MSAA. Character-only white unshaded masks on black; body then body+white inverted hull. Diagnostic masks disable camera depth of field and environmental postprocessing; scene captures keep original settings."
	await settle()

func audit_shell() -> void:
	var shell:MeshInstance3D=cc.appearance.shells[0]
	var body_arrays:Array=source.mesh.surface_get_arrays(0)
	var shell_arrays:Array=shell.mesh.surface_get_arrays(0)
	var checks:Dictionary={"same_parent":shell.get_parent()==source.get_parent(),"same_vertex_array":body_arrays[Mesh.ARRAY_VERTEX]==shell_arrays[Mesh.ARRAY_VERTEX],"same_bone_indices":body_arrays[Mesh.ARRAY_BONES]==shell_arrays[Mesh.ARRAY_BONES],"same_bone_weights":body_arrays[Mesh.ARRAY_WEIGHTS]==shell_arrays[Mesh.ARRAY_WEIGHTS],"same_skin":shell.skin==source.skin,"same_skeleton":shell.get_node(shell.skeleton)==source.get_node(source.skeleton),"same_transform":shell.transform==source.transform,"same_layers":shell.layers==source.layers,"no_shadow":shell.cast_shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF}
	var poses:Array=[]
	for animation in ["idle","walk","turn_180","bow"]:
		cc._play(animation,true)
		var length:float=cc.animator.get_animation(animation).length
		for fraction in [0.0,0.5,0.95]:
			cc.animator.seek(length*fraction,true)
			cc.animator.advance(0.0)
			cc.character_skeleton.force_update_all_bone_transforms()
			await settle(2)
			var body_mesh:=source.bake_mesh_from_current_skeleton_pose()
			var shell_mesh:=shell.bake_mesh_from_current_skeleton_pose()
			var equal:=true
			for surface in body_mesh.get_surface_count():
				equal=equal and body_mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]==shell_mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
			poses.append({"animation":animation,"seconds":length*fraction,"same_skinned_vertices_before_grow":equal})
	checks["all_sampled_poses_match"]=true
	for pose in poses:checks.all_sampled_poses_match=checks.all_sampled_poses_match and pose.same_skinned_vertices_before_grow
	report["shell_animation_audit"]={"checks":checks,"poses":poses}
	report["outline_mesh_filter"]=shell.mesh.get_meta("outline_filter",{})
	cc._play("idle",true)
	cc._align_sole()

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):output=arg.trim_prefix("--out=")
	if output.is_empty():push_error("Use --out=<new absolute evidence directory>");quit(1);return
	DirAccess.make_dir_recursive_absolute(output)
	if FileAccess.file_exists(output+"/day-after.png"):
		push_error("Evidence already exists; choose a new directory");quit(1);return
	wrapper=load("res://tools/traveler/action2_preview.tscn").instantiate()
	root.add_child(wrapper)
	DisplayServer.window_move_to_foreground()
	while not wrapper.review_ready:await process_frame
	host=wrapper.host;cc=host.character_controller
	cc.set_process(false)
	host.motion_director.set_motion_enabled(false)
	host.motion_director.set_process(false)
	source=cc.appearance.surfaces[0].source
	await audit_shell()
	# Exact former sizing expression, at the unchanged production spawn/pose.
	var base:Vector2=host.camera.unproject_position(cc.actor.global_position)
	var top:Vector2=host.camera.unproject_position(cc.actor.global_position+Vector3.UP)
	var pixels_per_unit:float=base.distance_to(top)*1080.0/host.get_viewport().get_visible_rect().size.y
	var old_scale:float=float(cc.settings.height_px)/maxf(pixels_per_unit*cc.model_height,1.0)
	cc.appearance.set_enabled(false)
	cc.actor.scale=Vector3.ONE*old_scale
	cc._align_sole();cc._update_readability()
	report["before"]=await capture("day-before")
	await masks(true)
	cc.appearance.set_enabled(true);cc._update_size()
	cc._align_sole();cc._update_readability()
	report["after"]=await capture("day-after")
	await masks()
	# Record the existing dusk-only fill on the same current character.
	host.look_profile.start_period_transition(true,0.01)
	host.look_profile.tick_transition(1.0)
	assert(is_equal_approx(host.look_profile.current_period_t,1.0))
	cc._update_readability()
	report["dusk"]=await capture("dusk-after")
	report["same_process_before_after"]=true
	report["source_rest_height_u"]=source.mesh.get_aabb().size.y
	report["scope"]="Style and fixed scale only. Source model/action library, controller movement/navigation/collision, existing dusk fill and world/camera unchanged."
	write_json("capture",report)
	print("STYLE_REVIEW_COMPLETE ",output)
	quit()
