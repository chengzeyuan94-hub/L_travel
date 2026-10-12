extends SceneTree
## Runs the real preview/input path and records behavior plus rendered geometry.
var output:=""
var wrapper:Node
var host:Node3D
var cc:Node3D
var checks:Dictionary={}
var records:Array=[]
var started:=0
var last_record:=-1.0
var outside_day_samples:=0
var day_samples:=0
var obstacle_overlap_samples:=0
var seen:Dictionary={}
var max_bone_length_change:=0.0
var initial_lengths:Dictionary={}

func _initialize() -> void:call_deferred("run")

func click_building() -> void:
	var gate:=Vector2.ZERO
	for city in host.cities:
		if city.id=="changan":gate=host.camera.unproject_position(Vector3(city.x,float(city.base)+float(city.scale)*0.65,city.z))
	checks["building_hit"]=host.period_hotspot_hit(gate)
	var size:Vector2=root.get_visible_rect().size
	var factor:float=minf(size.x/1920.0,size.y/1080.0)
	var pos:Vector2=(size-Vector2(1920,1080)*factor)*0.5+gate*factor
	for pressed in [true,false]:
		var event:=InputEventMouseButton.new()
		event.button_index=MOUSE_BUTTON_LEFT; event.position=pos; event.global_position=pos; event.pressed=pressed
		wrapper._input(event)

func sample() -> void:
	if not cc.obstacles.is_clear(cc.actor.global_position,cc.clearance_radius,cc.clearance_height,cc.clearance_bottom):obstacle_overlap_samples+=1
	day_samples+=int(cc.mode=="day_roam")
	if cc.mode=="day_roam" and not Geometry2D.is_point_in_polygon(cc.screen_position,cc.boundary):outside_day_samples+=1
	seen[cc.state]=true
	for bone in cc.character_skeleton.get_bone_count():
		var length:float=cc.character_skeleton.get_bone_pose_position(bone).length()
		if not initial_lengths.has(bone):initial_lengths[bone]=length
		if bone!=0:max_bone_length_change=maxf(max_bone_length_change,absf(length-float(initial_lengths[bone])))
	var time:=float(Time.get_ticks_msec()-started)/1000.0
	if time-last_record>=0.2:
		last_record=time
		records.append({"t":time,"mode":cc.mode,"animation":cc.state,"animation_s":cc.animator.current_animation_position,"pixel":[cc.screen_position.x,cc.screen_position.y],"world_y":cc.actor.global_position.y,"speed":cc.current_speed_px_s,"period":host.look_profile.current_period_t})

func tick_for(seconds:float) -> void:
	var end:=Time.get_ticks_msec()+int(seconds*1000.0)
	while Time.get_ticks_msec()<end:
		await process_frame
		sample()

func wait_mode(mode:String,seconds:float) -> bool:
	var end:=Time.get_ticks_msec()+int(seconds*1000.0)
	while Time.get_ticks_msec()<end:
		await process_frame; sample()
		if cc.mode==mode:return true
	return false

func capture(label:String) -> void:
	var samples:Array[float]=[]
	await RenderingServer.frame_post_draw
	var previous:=Time.get_ticks_usec()
	for _i in 120:
		await RenderingServer.frame_post_draw
		var now:=Time.get_ticks_usec()
		samples.append(float(now-previous)/1000.0); previous=now
		sample()
	samples.sort()
	var img:Image=wrapper.viewport.get_texture().get_image()
	img.save_png(output+"/"+label+".png")
	var mesh:MeshInstance3D=cc.model.find_children("*","MeshInstance3D",true,false)[0]
	var posed:=mesh.bake_mesh_from_current_skeleton_pose()
	var min_pixel:=Vector2(INF,INF);var max_pixel:=Vector2(-INF,-INF)
	var min_world_y:=INF
	for surface in posed.get_surface_count():
		for vertex in posed.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			var world:Vector3=mesh.global_transform*vertex
			min_world_y=minf(min_world_y,world.y)
			var pixel:Vector2=host.camera.unproject_position(world)
			min_pixel=min_pixel.min(pixel); max_pixel=max_pixel.max(pixel)
	var report:Dictionary={"image_size":[img.get_width(),img.get_height()],"viewport_size":[1920,1080],"character":cc.evidence(),"rendered_character_bounds_px":[min_pixel.x,min_pixel.y,max_pixel.x,max_pixel.y],"rendered_character_height_px":max_pixel.y-min_pixel.y,"foot_mesh_min_world_y":min_world_y,"floor_world_y":cc.actor.global_position.y,"sole_minus_floor_u":min_world_y-cc.actor.global_position.y,"draw_calls":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),"viewport_draw_calls":wrapper.viewport.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME),"frame_ms":{"p50":samples[59],"p95":samples[113],"count":samples.size(),"vsync_disabled":DisplayServer.window_get_vsync_mode()==DisplayServer.VSYNC_DISABLED,"max_fps":Engine.max_fps},"look":host.look_profile.evidence(img),"frozen_camera":host.motion_params._measured.traveler_camera}
	FileAccess.open(output+"/"+label+".json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):output=arg.trim_prefix("--out=")
	if output.is_empty():push_error("Use --out=<new evidence directory>");quit(1);return
	DirAccess.make_dir_recursive_absolute(output)
	if FileAccess.file_exists(output+"/integration.json"):push_error("Evidence already exists; choose a new directory");quit(1);return
	wrapper=load("res://tools/traveler/action2_preview.tscn").instantiate()
	root.add_child(wrapper)
	while not wrapper.review_ready:await process_frame
	host=wrapper.host;cc=host.character_controller
	started=Time.get_ticks_msec()
	await tick_for(10.0)
	await capture("day")
	checks["autonomous_walk"]=seen.has("walk")
	checks["autonomous_idle"]=seen.has("idle")
	click_building()
	checks["dusk_hold_reached"]=await wait_mode("dusk_hold",25.0)
	var fixed_position:Vector3=cc.actor.global_position
	var fixed_pose:float=cc.animator.current_animation_position
	await tick_for(2.0)
	checks["dusk_holds_position"]=fixed_position==cc.actor.global_position
	checks["dusk_holds_animation"]=fixed_pose==cc.animator.current_animation_position
	checks["dusk_at_gate"]=cc.screen_position.distance_to(cc.gate_target)<0.5
	checks["on_raised_slab"]=cc.actor.global_position.y>0.68
	await capture("dusk")
	click_building()
	checks["returned_to_day"]=await wait_mode("day_roam",20.0)
	await tick_for(9.0)
	checks["back_to_day_lighting"]=host.look_profile.current_period_t<0.001
	await capture("return-day")
	# Mid-journey reversal: the second real click must cancel the pending bow.
	click_building();await tick_for(0.6);click_building();await tick_for(9.0)
	checks["quick_reversal_returns_to_roam"]=cc.mode=="day_roam"
	checks["only_authorized_actions"]=not seen.has("run") and not seen.has("sit")
	checks["no_lantern"]=cc.find_child("RightHandLanternLight",true,false)==null
	host.motion_director.set_motion_enabled(false)
	var paused_position:Vector3=cc.actor.global_position
	var paused_animation:float=cc.animator.current_animation_position
	await tick_for(0.5)
	checks["pause_stops_character"]=paused_position==cc.actor.global_position and paused_animation==cc.animator.current_animation_position
	host.motion_director.set_motion_enabled(true)
	checks["day_stays_inside_blue"]=day_samples>0 and outside_day_samples==0
	checks["no_obstacle_overlap"]=obstacle_overlap_samples==0
	checks["solid_obstacles_present"]=int(cc.obstacles.report.convex_pieces)>0
	checks["bush_is_impassable"]=not cc.obstacles.is_clear(Vector3(29.87,0.6434,8.03),cc.clearance_radius,cc.clearance_height,cc.clearance_bottom)
	checks["limb_lengths_stable"]=max_bone_length_change<0.0001
	var all_pass:=true
	for value in checks.values():all_pass=all_pass and bool(value)
	var report:Dictionary={"checks":checks,"all_pass":all_pass,"elapsed_s":float(Time.get_ticks_msec()-started)/1000.0,"states_seen":seen.keys(),"outside_day_samples":outside_day_samples,"obstacle_overlap_samples":obstacle_overlap_samples,"day_samples":day_samples,"max_nonroot_bone_length_delta_u":max_bone_length_change,"samples":records,"commands":{"executable":OS.get_executable_path(),"args":OS.get_cmdline_args(),"user_args":OS.get_cmdline_user_args()}}
	FileAccess.open(output+"/integration.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("ACTION2_INTEGRATION ",JSON.stringify(checks))
	host.motion_director.set_process(false)
	quit(0 if all_pass else 1)
