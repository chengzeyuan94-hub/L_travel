extends Node3D
## Frozen-camera traveler: screen-authored boundary, terrain-grounded navigation.
var host: Node3D
var actor: Node3D
var model: Node3D
var character_skeleton: Skeleton3D
var model_height := 1.0
var pose_bounds := AABB()
var animator: AnimationPlayer
var appearance:RefCounted
var dusk_fill: OmniLight3D
var dusk_rim: OmniLight3D
const CHARACTER_LIGHT_LAYER := 1 << 17
var settings: Dictionary
var boundary := PackedVector2Array()
var navigation := AStar2D.new()
var route := PackedVector2Array()
var screen_position := Vector2.ZERO
var current_speed_px_s := 0.0
var animation_rate := 1.0
var ready_for_input := false
# Behavior and animation are separate: playing a clip never loses the journey destination.
var mode := "day_roam"
var state := "idle"
var state_elapsed := 0.0
var collision_root: Node3D
var roam_wait := 1.0
var target_dusk := false
var gate_target := Vector2.ZERO
var gate_entry := Vector2.ZERO
var rng := RandomNumberGenerator.new()
var turn_start_yaw := 0.0
var turn_end_yaw := 0.0
var feet: Array[int] = []
var foot_reference_y := 0.0
var base_model_y := 0.0
var ground_height := 0.0
var floor_surfaces:RefCounted
var obstacles:RefCounted
var transit_navigation:=AStar2D.new()
var collision_stops:=0
var clearance_radius:=0.085
var clearance_height:=0.40
var clearance_bottom:=0.015
const OBSTACLE_LAYER:=1 << 19
const GROUND_LAYER := 1 << 18
const NATIVE_SIZE := Vector2(1920,1080)

func configure(viewer: Node3D) -> void:
	host=viewer
	settings=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/character_control.json"))
	rng.seed=20260920
	for point in settings.boundary_normalized:
		boundary.append(Vector2(float(point[0]),float(point[1]))*NATIVE_SIZE)
	process_priority=20
	_build_ground_collision()
	floor_surfaces=load("res://tools/traveler/character_surface.gd").new()
	floor_surfaces.configure(host,collision_root,GROUND_LAYER)
	obstacles=load("res://scripts/traveler/character_obstacles.gd").new()
	clearance_radius=float(settings.collision.radius_u)
	clearance_height=float(settings.collision.height_u)
	clearance_bottom=float(settings.collision.sole_clearance_u)
	call_deferred("_finish_setup")

func _build_ground_collision() -> void:
	collision_root=Node3D.new()
	collision_root.name="TravelerGroundQueries"
	add_child(collision_root)
	var terrain: Node=host.world.get_node("Terrain64")
	for node in terrain.find_children("*","MeshInstance3D",true,false):
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh==null:continue
		var bounds: AABB=mesh_node.global_transform*mesh_node.get_aabb()
		var nearest: Vector3=host.camera.global_position.clamp(bounds.position,bounds.end)
		if nearest.distance_to(host.camera.global_position)>40.0:continue
		var body:=StaticBody3D.new()
		body.collision_layer=GROUND_LAYER
		body.collision_mask=0
		collision_root.add_child(body)
		body.global_transform=mesh_node.global_transform
		var shape:=CollisionShape3D.new()
		shape.shape=mesh_node.mesh.create_trimesh_shape()
		body.add_child(shape)

func _interaction_world_bounds() -> AABB:
	var bounds:=AABB()
	var initialized:=false
	var plane:=Plane(Vector3.UP,0.6434)
	var pixels:=boundary.duplicate()
	pixels.append(Vector2(settings.dusk_gate_screen[0],settings.dusk_gate_screen[1]))
	for point in pixels:
		var screen:Vector2=point/NATIVE_SIZE*host.get_viewport().get_visible_rect().size
		var intersection:Variant=plane.intersects_ray(host.camera.project_ray_origin(screen),host.camera.project_ray_normal(screen))
		if intersection==null:continue
		if not initialized:bounds=AABB(intersection,Vector3.ZERO);initialized=true
		else:bounds=bounds.expand(intersection)
	return bounds.grow(1.0)

func _ground(pixel: Vector2) -> Dictionary:
	var viewport_size: Vector2=host.get_viewport().get_visible_rect().size
	var screen: Vector2=pixel/NATIVE_SIZE*viewport_size
	var origin: Vector3=host.camera.project_ray_origin(screen)
	var direction: Vector3=host.camera.project_ray_normal(screen)
	var query:=PhysicsRayQueryParameters3D.create(origin,origin+direction*80.0,GROUND_LAYER)
	return get_world_3d().direct_space_state.intersect_ray(query)

func _in_blue(pixel:Vector2) -> bool:
	if not Geometry2D.is_point_in_polygon(pixel,boundary):return false
	for offset in [Vector2(10,0),Vector2(-10,0),Vector2(0,8),Vector2(0,-8)]:
		if not Geometry2D.is_point_in_polygon(pixel+offset,boundary):return false
	return true

func _in_transit_region(pixel:Vector2) -> bool:
	if _in_blue(pixel):return true
	var previous:=Vector2(settings.gate_entry_screen[0],settings.gate_entry_screen[1])
	var waypoints:Array=settings.gate_waypoints_screen.duplicate()
	waypoints.append(settings.dusk_gate_screen)
	for point in waypoints:
		var next:=Vector2(point[0],point[1])
		if pixel.distance_to(Geometry2D.get_closest_point_to_segment(pixel,previous,next))<=float(settings.transit_half_width_px):return true
		previous=next
	return false

func _valid_ground(pixel:Vector2,blue_only:bool=true) -> Dictionary:
	if not (_in_blue(pixel) if blue_only else _in_transit_region(pixel)):return {}
	var hit:=_ground(pixel)
	if hit.is_empty() or (hit.normal as Vector3).y<0.60:return {}
	if not obstacles.is_clear(hit.position,clearance_radius,clearance_height,clearance_bottom):return {}
	return hit

func _segment_clear(from:Vector2,to:Vector2,blue_only:bool) -> bool:
	var previous:=_valid_ground(from,blue_only)
	if previous.is_empty():return false
	var count:=maxi(1,int(ceil(from.distance_to(to)/5.0)))
	for i in range(1,count+1):
		var hit:=_valid_ground(from.lerp(to,float(i)/count),blue_only)
		if hit.is_empty() or absf(hit.position.y-previous.position.y)>float(settings.collision.max_step_u):return false
		if not obstacles.sweep(previous.position,hit.position,clearance_radius,clearance_height,clearance_bottom).clear:return false
		previous=hit
	return true

func _build_navigation(blue_only:bool) -> AStar2D:
	var graph:=AStar2D.new()
	var cell_ids:Dictionary={}
	var step:=int(settings.grid_px)
	for y in range(0,1080,step):
		for x in range(0,1920,step):
			var pixel:=Vector2(x,y)
			var hit:=_valid_ground(pixel,blue_only)
			if hit.is_empty():continue
			var id:=graph.get_available_point_id()
			graph.add_point(id,pixel)
			cell_ids[Vector2i(x/step,y/step)]=id
	for cell in cell_ids:
		var from_id:int=cell_ids[cell]
		for offset in [Vector2i(1,0),Vector2i(0,1),Vector2i(1,1),Vector2i(-1,1)]:
			var neighbor:Vector2i=cell+offset
			if not cell_ids.has(neighbor):continue
			var to_id:int=cell_ids[neighbor]
			if _segment_clear(graph.get_point_position(from_id),graph.get_point_position(to_id),blue_only):
				graph.connect_points(from_id,to_id)
	return graph

func _finish_setup() -> void:
	# MultiMesh transforms are backed by the renderer. Read them only after the
	# initial upload, then let physics register the collision-only copies.
	await RenderingServer.frame_post_draw
	obstacles.configure(host,collision_root,OBSTACLE_LAYER,_interaction_world_bounds())
	await get_tree().physics_frame
	await get_tree().physics_frame
	navigation=_build_navigation(true)
	transit_navigation=_build_navigation(false)
	if navigation.get_point_count()==0 or transit_navigation.get_point_count()==0:
		push_error("Traveler navigation has no collision-free walkable ground")
		return
	var spawn:=Vector2(float(settings.spawn_normalized[0]),float(settings.spawn_normalized[1]))*NATIVE_SIZE
	var spawn_id:=navigation.get_closest_point(spawn)
	screen_position=navigation.get_point_position(spawn_id)
	actor=Node3D.new()
	var source_scene:PackedScene=load("res://scenes/traveler/action2_character.tscn")
	if source_scene==null:
		push_error("Traveler character source scene failed to load")
		return
	model=source_scene.instantiate()
	actor.add_child(model)
	actor.name="TravelerCharacter"
	add_child(actor)
	actor.global_position=_ground(screen_position).position
	animator=model.find_child("AnimationPlayer",true,false) as AnimationPlayer
	if animator==null:
		push_error("Traveler character AnimationPlayer missing")
		return
	animator.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var idle_animation:=_resolve_animation("idle")
	if animator.has_animation(idle_animation):
		animator.play(idle_animation)
	animator.advance(0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	character_skeleton=model.find_child("Skeleton3D",true,false) as Skeleton3D
	if character_skeleton!=null:
		character_skeleton.force_update_all_bone_transforms()
	var skin_mesh:MeshInstance3D=null
	for node in model.find_children("*","MeshInstance3D",true,false):
		if node is MeshInstance3D:
			skin_mesh=node
			break
	if skin_mesh==null:
		push_error("Traveler character skinned mesh missing")
		return
	var posed_mesh:Mesh
	if character_skeleton!=null:
		posed_mesh=skin_mesh.bake_mesh_from_current_skeleton_pose()
	else:
		posed_mesh=skin_mesh.mesh
	pose_bounds=posed_mesh.get_aabb() if posed_mesh!=null else skin_mesh.get_aabb()
	model_height=maxf(pose_bounds.size.y,0.001)
	model.position=Vector3(-pose_bounds.get_center().x,-pose_bounds.position.y,-pose_bounds.get_center().z)
	# Some FBX exports keep a large unit conversion on the armature node
	# (the Quaternius asset is ~69x). Normalize that nested scale at the
	# imported scene root so the approved model-space scale remains valid.
	var nested_scale:=1.0
	var scale_node:Node3D=skin_mesh
	while scale_node!=model:
		nested_scale*=maxf(scale_node.transform.basis.get_scale().x,0.0001)
		scale_node=scale_node.get_parent() as Node3D
	if absf(nested_scale-1.0)>0.001:
		model.scale=Vector3.ONE/nested_scale
	print("CHARACTER_SOURCE action2 ANIMATIONS ",animator.get_animation_list())
	print("CHARACTER_POSED_BOUNDS ",pose_bounds)

	appearance=load("res://scripts/traveler/character_style.gd").new()
	appearance.configure(model)
	_attach_readability_lights()
	_update_size()
	actor.look_at(Vector3(host.camera.global_position.x,actor.global_position.y,host.camera.global_position.z),Vector3.UP,true)
	base_model_y=model.position.y
	for bone in ["mixamorig_LeftFoot","mixamorig_RightFoot","mixamorig_LeftToeBase","mixamorig_RightToeBase"]:
		var id:int=character_skeleton.find_bone(bone)
		if id>=0:feet.append(id)
	foot_reference_y=_lowest_foot_y()
	gate_target=Vector2(settings.dusk_gate_screen[0],settings.dusk_gate_screen[1])
	gate_entry=navigation.get_point_position(navigation.get_closest_point(Vector2(settings.gate_entry_screen[0],settings.gate_entry_screen[1])))
	_play("idle")
	ready_for_input=true
	# Starting directly in dusk uses the same walk-to-gate and one-shot bow.
	if host.look_profile!=null and (host.look_profile.transition_target_dusk if host.look_profile.transition_active else host.look_profile.look_dusk):
		begin_period_transition(true)
	print("TRAVELER_CHARACTER_READY ",JSON.stringify(evidence()))

func _resolve_animation(requested:String) -> String:
	if animator==null:return requested
	if animator.has_animation(requested):return requested
	var wanted:=requested.to_lower()
	for name in animator.get_animation_list():
		var lower:=name.to_lower()
		if lower.ends_with("|"+wanted) or lower.ends_with("/"+wanted) or lower==wanted or lower.contains(wanted):
			return name
	return requested

func _attach_readability_lights() -> void:
	# Reserved visual layer limits the soft fill to this character's meshes.
	for mesh in model.find_children("*","MeshInstance3D",true,false):
		mesh.layers |= CHARACTER_LIGHT_LAYER
	dusk_fill=OmniLight3D.new()
	dusk_rim=OmniLight3D.new()
	for light in [dusk_fill,dusk_rim]:
		light.light_cull_mask=CHARACTER_LIGHT_LAYER
		light.light_energy=0.0
		light.omni_range=2.4
		light.omni_attenuation=1.1
		light.light_specular=0.0
		light.shadow_enabled=false
		add_child(light)
	dusk_fill.name="CharacterDuskFill"
	dusk_fill.light_color=Color("cbd4e5")
	dusk_rim.name="CharacterDuskRim"
	dusk_rim.light_color=Color("e9cdb6")

func _update_size() -> void:
	# Fixed world scale from the approved style specification; no pixel-height compensation.
	actor.scale=Vector3.ONE*float(appearance.settings.scale)

func _update_readability() -> void:
	var dusk:float=float(host.look_profile.current_period_t) if host.look_profile!=null else 0.0
	var blend:=smoothstep(0.35,0.9,dusk)
	if dusk_fill!=null:
		var body_center:Vector3=actor.global_position+Vector3.UP*actor.scale.x*model_height*0.55
		dusk_fill.global_position=body_center+host.camera.global_basis.z*0.9-host.camera.global_basis.x*0.35+Vector3.UP*0.3
		dusk_rim.global_position=body_center-host.camera.global_basis.z*0.65+host.camera.global_basis.x*0.55+Vector3.UP*0.45
		dusk_fill.light_energy=float(settings.dusk_fill_energy)*blend
		dusk_rim.light_energy=float(settings.dusk_rim_energy)*blend

func _remaining_route_px() -> float:
	var total:=0.0
	var previous:=screen_position
	for point in route:
		total+=previous.distance_to(point)
		previous=point
	return total

func _process(delta: float) -> void:
	if not ready_for_input or delta<=0.0:return
	if not is_instance_valid(host.motion_director) or not host.motion_director.motion_enabled:return
	state_elapsed+=delta
	if mode=="dusk_hold":
		_update_readability()
		return
	if state=="bow":
		var length:float=animator.get_animation("bow").length
		animator.advance(minf(delta,maxf(0.0,length-animator.current_animation_position)))
		if state_elapsed>=length:
			animator.seek(length,true)
			mode="dusk_hold"
		_align_sole(); _update_readability()
		return
	if state=="turn_180":
		var length:float=animator.get_animation("turn_180").length
		animator.advance(delta)
		actor.rotation.y=lerp_angle(turn_start_yaw,turn_end_yaw,smoothstep(0.0,1.0,state_elapsed/length))
		if state_elapsed>=length:
			actor.rotation.y=turn_end_yaw
			_play("walk")
		_align_sole(); _update_readability()
		return
	if route.is_empty():
		if mode=="to_gate":
			if screen_position.distance_to(gate_target)<1.0:
				_face_gate()
				_play("bow")
			else:_retry_journey(delta)
		elif mode=="to_day":
			if _in_blue(screen_position):
				mode="day_roam"
				_idle()
			else:_retry_journey(delta)
		elif state=="walk":
			_idle()
		elif mode=="day_roam":
			roam_wait-=delta
			if roam_wait<=0.0:_choose_roam_route()
	var previous_world:=actor.global_position
	if not route.is_empty():_advance_route(delta)
	if state=="walk":
		var moved:=Vector2(actor.global_position.x-previous_world.x,actor.global_position.z-previous_world.z).length()
		animation_rate=clampf(moved/maxf(delta*float(settings.walk_stance_u_s)*actor.scale.x,0.000001),0.0,2.0)
	else:animation_rate=1.0
	animator.advance(delta*animation_rate)
	_update_size()
	_align_sole()
	_update_readability()

func _advance_route(delta:float) -> void:
	while not route.is_empty() and screen_position.distance_to(route[0])<0.001:route.remove_at(0)
	if route.is_empty():return
	var ahead:=_ground(route[0])
	if ahead.is_empty():_blocked();return
	var forward:Vector3=ahead.position-actor.global_position
	forward.y=0.0
	if forward.length_squared()>0.000001:
		var heading:=atan2(forward.x,forward.z)
		actor.rotation.y=lerp_angle(actor.rotation.y,heading,1.0-exp(-float(settings.turn_smoothing)*delta))
	var remaining:=_remaining_route_px()
	var target_speed:=minf(float(settings.walk_px_s),sqrt(2.0*float(settings.stop_decel_px_s2)*remaining))
	current_speed_px_s=move_toward(current_speed_px_s,target_speed,float(settings.walk_accel_px_s2)*delta)
	var distance:=current_speed_px_s*delta
	if remaining<0.5:distance=remaining
	# Every committed substep uses the same capsule sweep as graph construction.
	# A slow render frame cannot skip a tree, rock, or waypoint.
	while not route.is_empty() and distance>0.00001:
		var segment:=screen_position.distance_to(route[0])
		var consumed:=minf(minf(segment,distance),4.0)
		var candidate:=screen_position.move_toward(route[0],consumed)
		if not _segment_clear(screen_position,candidate,mode=="day_roam"):
			_blocked();return
		var hit:=_ground(candidate)
		screen_position=candidate
		actor.global_position=hit.position
		ground_height=actor.global_position.y
		distance-=consumed
		if segment<=consumed+0.001:route.remove_at(0)

func _blocked() -> void:
	collision_stops+=1
	route.clear()
	_idle()
	roam_wait=0.5

func _retry_journey(delta:float) -> void:
	roam_wait-=delta
	if roam_wait<=0.0:begin_period_transition(target_dusk)

func _lowest_foot_y() -> float:
	if feet.is_empty():return 0.0
	character_skeleton.force_update_all_bone_transforms()
	var low:=INF
	for id in feet:
		var point:Vector3=character_skeleton.to_global(character_skeleton.get_bone_global_pose(id).origin)
		low=minf(low,actor.to_local(point).y)
	return low

func _align_sole() -> void:
	# A whole-model lift only. Never modify a bone, its scale, or a persistent IK override.
	model.position.y=base_model_y
	if not feet.is_empty():model.position.y+=foot_reference_y-_lowest_foot_y()

func _play(animation:String,restart:bool=false) -> void:
	if not restart and state==animation and animator.current_animation==animation:return
	if not animator.has_animation(animation):
		push_error("Traveler animation missing: "+animation); return
	state=animation
	state_elapsed=0.0
	animation_rate=1.0
	# Each source FBX uses the same bind skeleton. Clear the previous pose and
	# evaluation cache instead of inheriting gait phase or any previous bone override.
	animator.stop()
	character_skeleton.reset_bone_poses()
	animator.play(animation,0.0)
	animator.seek(0.0,true)
	animator.advance(0.0)

func _idle() -> void:
	current_speed_px_s=0.0
	_play("idle")
	roam_wait=rng.randf_range(float(settings.roam_idle_min_s),float(settings.roam_idle_max_s))

func _path_in_blue(from:Vector2,to:Vector2) -> PackedVector2Array:
	return _safe_path(navigation,from,to,true)

func _safe_path(graph:AStar2D,from:Vector2,to:Vector2,blue_only:bool) -> PackedVector2Array:
	if _segment_clear(from,to,blue_only):return PackedVector2Array([to])
	var starts:Array=[]
	var ends:Array=[]
	for id in graph.get_point_ids():
		var p:Vector2=graph.get_point_position(id)
		starts.append({"id":id,"distance":p.distance_squared_to(from)})
		ends.append({"id":id,"distance":p.distance_squared_to(to)})
	starts.sort_custom(func(a,b):return a.distance<b.distance)
	ends.sort_custom(func(a,b):return a.distance<b.distance)
	for start in starts.slice(0,8):
		if not _segment_clear(from,graph.get_point_position(start.id),blue_only):continue
		for end in ends.slice(0,8):
			if not _segment_clear(graph.get_point_position(end.id),to,blue_only):continue
			var path:=graph.get_point_path(start.id,end.id)
			if path.is_empty():continue
			path.append(to)
			# Simplify only when the entire replacement segment has support,
			# remains in its allowed region and passes the swept body query.
			var result:=PackedVector2Array()
			var anchor:=from
			var i:=0
			while i<path.size():
				var farthest:=i
				for j in range(i+1,path.size()):
					if _segment_clear(anchor,path[j],blue_only):farthest=j
				if anchor.distance_to(path[farthest])>0.001:result.append(path[farthest])
				anchor=path[farthest];i=farthest+1
			return result
	return PackedVector2Array()

func _choose_roam_route() -> void:
	var points:=navigation.get_point_ids()
	for _attempt in 30:
		var id:int=points[rng.randi_range(0,points.size()-1)]
		var p:Vector2=navigation.get_point_position(id)
		if p.distance_to(screen_position)<65.0:continue
		var candidate:=_path_in_blue(screen_position,p)
		if candidate.is_empty():continue
		route=candidate
		_start_walking()
		return
	roam_wait=1.0

func _start_walking() -> void:
	if route.is_empty():return
	var hit:=_ground(route[0])
	if hit.is_empty():return
	var forward:Vector3=hit.position-actor.global_position
	var heading:=atan2(forward.x,forward.z)
	var difference:=angle_difference(actor.rotation.y,heading)
	if absf(difference)>deg_to_rad(110.0):
		turn_start_yaw=actor.rotation.y
		turn_end_yaw=heading
		_play("turn_180",true)
	else:_play("walk")

func _face_gate() -> void:
	for city in host.cities:
		if city.id=="changan":
			var direction:Vector3=Vector3(city.x,actor.global_position.y,city.z)-actor.global_position
			actor.rotation.y=atan2(direction.x,direction.z)

func begin_period_transition(dusk:bool) -> void:
	target_dusk=dusk
	if not ready_for_input:return
	current_speed_px_s=0.0
	mode="to_gate" if dusk else "to_day"
	var goal:Vector2=gate_target if dusk else gate_entry
	if not dusk and _in_blue(screen_position):
		route.clear();mode="day_roam";_idle();return
	route=_safe_path(transit_navigation,screen_position,goal,false)
	if route.is_empty():_idle();roam_wait=1.0;return
	_start_walking()

func move_to(pixel:Vector2,_fast:bool=false) -> bool:
	# Kept for diagnostic tools; manual mouse movement is no longer the product flow.
	if not ready_for_input or mode!="day_roam" or not host.motion_director.motion_enabled:return false
	if _valid_ground(pixel).is_empty():return false
	var path:=_path_in_blue(screen_position,pixel)
	if path.is_empty():return false
	route=path
	_start_walking()
	return true

func handle_input(_event:InputEvent) -> bool:
	return false

func evidence() -> Dictionary:
	return {"ready":ready_for_input,"source":"action2_character.tscn","appearance":appearance.evidence() if appearance!=null else {},
		"posed_bounds":str(pose_bounds),"screen_position_px":[screen_position.x,screen_position.y],"state":state,"mode":mode,
		"current_speed_px_s":current_speed_px_s,"animation_rate":animation_rate,
		"navigation_points":navigation.get_point_count(),"waypoints_remaining":route.size(),
		"scale":actor.scale.x if actor!=null else 0.0,"world_position":str(actor.global_position) if actor!=null else "",
		"boundary_normalized":settings.boundary_normalized,"gate_target_px":[gate_target.x,gate_target.y],
		"gate_entry_px":[gate_entry.x,gate_entry.y],"lantern_present":false,"bone_ik_enabled":false,"run_wired":false,
		"obstacles":obstacles.report,"collision_stops":collision_stops,"transit_navigation_points":transit_navigation.get_point_count(),"collision_capsule":settings.collision,
		"controls":"automatic day walk/idle; building click: walk to gate, bow once, hold; next click: return to blue area",
		"clock":"manual AnimationPlayer.advance and controller movement guarded by MotionDirector.motion_enabled"}
