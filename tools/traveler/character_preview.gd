extends Node3D
## Fixed 1920x1080 interactive review; project window settings remain unchanged.
var REPORT := "res://docs/reports/traveler-character-002/own/polished"
var viewport: SubViewport
var host: Node3D
var preview: TextureRect
var review_ready := false
var saved_dusk := false
var checks: Dictionary = {}

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--review-output="):REPORT=arg.trim_prefix("--review-output=")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps=0
	# The scene's original World is unused by this isolated review wrapper.
	$World.queue_free()
	viewport=SubViewport.new()
	viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d=Viewport.MSAA_4X
	add_child(viewport)
	host=load("res://scenes/traveler/traveler_main.tscn").instantiate()
	# The approved L-shu character is the default review. The external rig stays
	# available only when explicitly requested for A/B comparison.
	host.set_meta("use_alt_character",OS.get_cmdline_user_args().has("--alternate-character"))
	host.requested_view="changan"
	host.look_on=true
	host.look_far=true
	host.look_dusk=OS.get_cmdline_user_args().has("--dusk")
	viewport.add_child(host)
	host.ui.visible=false
	preview=TextureRect.new()
	preview.texture=viewport.get_texture()
	preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.mouse_filter=Control.MOUSE_FILTER_IGNORE
	add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if OS.get_cmdline_user_args().has("--character-review") or bool(host.get_meta("use_alt_character",false)):
		_run_review()
	else:
		_open_interaction()

func _open_interaction() -> void:
	while not is_instance_valid(host.character_controller) or not host.character_controller.ready_for_input:
		await get_tree().process_frame
	review_ready=true
	saved_dusk=true

func _input(event: InputEvent) -> void:
	if not review_ready:return
	var copy:=event.duplicate() as InputEvent
	if copy is InputEventMouse:
		var size:Vector2=get_viewport().get_visible_rect().size
		var scale:float=minf(size.x/1920.0,size.y/1080.0)
		var offset:Vector2=(size-Vector2(1920,1080)*scale)*0.5
		copy.position=(event.position-offset)/scale
		copy.global_position=copy.position
	viewport.push_input(copy,true)

func _process(_delta:float) -> void:
	if not review_ready:return
	if not saved_dusk and host.look_profile.current_period_t>=1.0:
		saved_dusk=true
		_capture_review("dusk")

func _run_review() -> void:
	while not is_instance_valid(host.character_controller) or not host.character_controller.ready_for_input:
		await get_tree().process_frame
	await get_tree().create_timer(1.0).timeout
	var cc=host.character_controller
	if cc.use_alt_character:
		await get_tree().create_timer(0.6).timeout
		await _capture_candidate_image(_period_label("candidate"))
		cc.move_to(Vector2(828,936),false)
		await get_tree().create_timer(1.0).timeout
		await _capture_candidate_image(_period_label("candidate-walk"))
		return
	var ids=cc.navigation.get_point_ids()
	var outside:=0
	var bad_segments:=0
	for id in ids:
		if not Geometry2D.is_point_in_polygon(cc.navigation.get_point_position(id),cc.boundary):outside+=1
		for neighbor in cc.navigation.get_point_connections(id):
			for i in range(1,10):
				var p:Vector2=cc.navigation.get_point_position(id).lerp(cc.navigation.get_point_position(neighbor),float(i)/10.0)
				if not Geometry2D.is_point_in_polygon(p,cc.boundary):bad_segments+=1
	checks["navigation"]={"points":ids.size(),"outside_points":outside,"outside_edge_samples":bad_segments,"outside_click_rejected":not cc.move_to(Vector2(1800,100))}
	var destinations=[Vector2(828,936),Vector2(1008,936),Vector2(288,792),Vector2(576,846)]
	var move_checks:Array=[]
	for target in destinations:
		var accepted:bool=cc.move_to(target,true)
		var timeout:=0.0
		while accepted and not cc.route.is_empty() and timeout<15.0:
			await get_tree().process_frame
			timeout+=get_process_delta_time()
		move_checks.append({"target":str(target),"accepted":accepted,"arrived":cc.route.is_empty(),"end":str(cc.screen_position)})
	checks["movement"]=move_checks
	# Capture the approved L-shu rig while it is actually in each gait. These
	# stills make cadence and silhouette changes reviewable without replacing the
	# frozen production character.
	cc.move_to(Vector2(828,936),false)
	await get_tree().create_timer(0.8).timeout
	await _capture_candidate_image(_period_label("walk"))
	cc.route.clear()
	cc.move_to(Vector2(576,846),true)
	await get_tree().create_timer(0.8).timeout
	await _capture_candidate_image(_period_label("run"))
	cc.route.clear()
	cc._play("idle")
	cc.current_speed_px_s=0.0
	await get_tree().create_timer(0.35).timeout
	var sk=cc.model.get_node("Skeleton3D")
	var mesh=sk.get_node("tripo_node_02987991")
	var baked=mesh.bake_mesh_from_current_skeleton_pose()
	var low:=INF
	var high:=-INF
	for surface in baked.get_surface_count():
		for vertex in baked.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			var pixel:Vector2=host.camera.unproject_position(mesh.global_transform*vertex)
			low=minf(low,pixel.y)
			high=maxf(high,pixel.y)
	checks["measured_pose_height_px"]=high-low
	cc.move_to(Vector2(828,936))
	await get_tree().create_timer(0.5).timeout
	host.motion_director.set_motion_enabled(false)
	var frozen_position:Vector3=cc.actor.global_position
	var frozen_animation:float=cc.animator.current_animation_position
	await get_tree().create_timer(0.5).timeout
	checks["pause"]={"position_unchanged":frozen_position==cc.actor.global_position,"animation_unchanged":frozen_animation==cc.animator.current_animation_position}
	host.motion_director.set_motion_enabled(true)
	cc.route.clear()
	cc._play("idle")
	review_ready=true
	print("CHARACTER_CHECKS ",JSON.stringify(checks))
	_capture_review("dusk" if host.look_dusk else "day")

func _capture_review(period:String) -> void:
	if period=="candidate":
		await _capture_candidate_image(period)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPORT))
	var samples:Array[float]=[]
	await RenderingServer.frame_post_draw
	var previous:=Time.get_ticks_usec()
	for i in 120:
		await RenderingServer.frame_post_draw
		var now:=Time.get_ticks_usec()
		samples.append(float(now-previous)/1000.0)
		previous=now
	samples.sort()
	var image:=viewport.get_texture().get_image()
	var destination:=REPORT+"/"+period+".png"
	if FileAccess.file_exists(destination):return
	image.save_png(destination)
	var report:Dictionary={"image_size":[image.get_width(),image.get_height()],"viewport_size":[1920,1080],"view":host.selected,"character":host.character_controller.evidence(),"checks":checks,"look":host.look_profile.evidence(image),"frozen_camera":host.motion_params._measured.traveler_camera,"draw_calls":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),"viewport_draw_calls":viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),"frame_ms":{"p50":samples[59],"p95":samples[113],"count":120,"vsync_disabled":true,"max_fps":Engine.max_fps},"entry":"tools/traveler/character_preview.tscn; sets changan/day/far before atlas _ready; includes displayed preview texture"}
	var file:=FileAccess.open(destination.trim_suffix(".png")+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	print("CHARACTER_REVIEW_CAPTURE ",destination)
	if OS.get_cmdline_user_args().has("--quit-after-review"):get_tree().quit()

func _capture_candidate_image(label:String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPORT))
	var image:=viewport.get_texture().get_image()
	var destination:=REPORT+"/"+label+".png"
	if FileAccess.file_exists(destination):return
	image.save_png(destination)
	print("CHARACTER_REVIEW_CAPTURE ",destination)

func _period_label(label:String) -> String:
	return ("dusk-" if host.look_dusk else "")+label
