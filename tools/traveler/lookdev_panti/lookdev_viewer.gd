# 自动生成，不要手改。由 tools/traveler/lookdev_panti/panti_lookdev.py 从
# scripts/traveler/panti/panti_viewer.gd 克隆，只在 PANTI_READY 前挂上 panti_overlay.gd。
extends Node3D
## Independent Panti stage. Never instantiates or modifies Atlas / Changan.
var world:Node3D
var camera:Camera3D
var sun:DirectionalLight3D
var environment:Environment
var target:=Vector3.ZERO
var selected:=""
var requested_view:=""
var look_on:=true
var look_far:=false
var look_dusk:=false
var night:=false
var dump_massif:=""
var look_overrides:Dictionary={}
var cities:Array=[]
var material_list:Array[ShaderMaterial]=[]
var city_lights:Array[OmniLight3D]=[]
var motion_director:Node
var look_profile:RefCounted
var motion_params:Dictionary
var camera_params:Dictionary
var settings:Dictionary
var castle:MeshInstance3D
var character:Node3D
var character_model:Node3D
var character_style:RefCounted
var tree_records:Array=[]
var rock_records:Array=[]
var rock_nodes:Array[MultiMeshInstance3D]=[]
var rock_ground_bindings:Array=[]
var compare_rocks:=false
var rocks_visible:=true
var batch_records:Array=[]
var capture_path:=""
var stage_basis:=Basis.IDENTITY
var normal_targets:Array=[]
var facet_normals:=true
var compare_normals:=false
var compare_dof:=false
var camera_pan_u:=0.0
var lighting_period:=""
var compare_periods:=false
var snow_ground:MeshInstance3D
var snow_flat_mesh:PlaneMesh
var snow_relief_mesh:ArrayMesh
var snow_surface:RefCounted
var snow_relief_enabled:=false
var compare_ground:=false
var camp:Node3D
var character_is_baked:=false
var seated_landmarks:Dictionary={}
var seated_actor:RefCounted
var weather:Node
var start_frozen:=false
var weather_off:=false
var castle_lighting:Node3D
var period_lighting:Node3D
var frozen_render_generation:=0
var period_transition:RefCounted
const CAMPFIRE_INTERACTION_LAYER:=1<<19

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps=0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):requested_view=arg.trim_prefix("--view=")
		if arg.begins_with("--capture="):capture_path=arg.trim_prefix("--capture=")
		if arg=="--compare-normals":compare_normals=true
		if arg=="--compare-dof":compare_dof=true
		if arg=="--compare-rocks":compare_rocks=true
		if arg=="--compare-ground":compare_ground=true
		if arg=="--day":lighting_period="day"
		if arg=="--sunset":lighting_period="sunset"
		if arg=="--morning":lighting_period="morning"
		if arg=="--midnight":lighting_period="midnight"
		if arg=="--compare-periods":compare_periods=true
		if arg=="--motion-freeze":start_frozen=true
		if arg=="--weather-off":weather_off=true
	if requested_view!="panti":
		push_error("Panti scene requires --view=panti; no silent preset fallback")
		get_tree().quit(1);return
	selected=requested_view
	settings=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/panti_scene.json"))
	if lighting_period.is_empty():lighting_period=str(settings.get("default_period","day"))
	motion_params=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/motion_params.json"))
	camera_params=motion_params._measured.traveler_camera.duplicate(true)
	for key in settings.get("camera_override",{}):
		if camera_params.has(key):camera_params[key]=settings.camera_override[key]
	if settings.has("camera_composition"):
		camera_params=settings.camera_composition.duplicate(true)
	target=vec(settings.camera_target)
	stage_basis=Basis(Vector3.UP,float(motion_params._measured.traveler_camera.azimuth_rad))
	world=Node3D.new();world.name="PantiWorld";add_child(world)
	camera=Camera3D.new();camera.name="FrozenCamera";add_child(camera);camera.make_current();update_camera()
	sun=DirectionalLight3D.new();sun.name="Daylight";add_child(sun)
	environment=Environment.new()
	var environment_node:=WorldEnvironment.new();environment_node.environment=environment;add_child(environment_node)
	look_profile=load("res://scripts/traveler/panti/panti_look.gd").new()
	look_profile.configure(self,false,false)
	build_ground()
	build_castle()
	build_trees()
	build_rocks()
	if settings.get("camp",{}).get("enabled",false):
		camp=load("res://scripts/traveler/panti/panti_camp.gd").new()
		world.add_child(camp);camp.configure(self)
	await build_character()
	if settings.has("weather"):
		weather=load("res://scripts/traveler/panti/panti_weather.gd").new()
		add_child(weather);weather.configure(self)
		if weather_off:weather.set_enabled(false)
		weather.set_frozen(start_frozen)
	castle_lighting=load("res://scripts/traveler/panti/panti_castle_lights.gd").new()
	world.add_child(castle_lighting);castle_lighting.configure(self)
	castle_lighting.set_period(lighting_period)
	period_lighting=load("res://scripts/traveler/panti/panti_period_lighting.gd").new()
	world.add_child(period_lighting);period_lighting.configure(self)
	if lighting_period in ["morning","midnight"]:prepare_period_transition()
	# Period switching is a camp interaction: clicking the visible fire toggles
	# morning <-> midnight. The fortress remains visual-only for this input.
	if camp!=null and camp.fire!=null:
		var fire_body:=StaticBody3D.new()
		fire_body.name="CampFirePeriodInteraction"
		fire_body.collision_layer=CAMPFIRE_INTERACTION_LAYER;fire_body.collision_mask=0
		world.add_child(fire_body)
		fire_body.global_position=camp.fire.global_position
		var fire_shape:=CollisionShape3D.new()
		var fire_box:=BoxShape3D.new()
		fire_box.size=Vector3(0.72,0.62,0.72)
		fire_shape.shape=fire_box
		fire_shape.position.y=0.24
		fire_body.add_child(fire_shape)
	load("res://tools/traveler/lookdev_panti/panti_overlay.gd").new().apply(self)
	refresh_frozen_viewport()
	print("PANTI_READY ",JSON.stringify({"view":selected,"preset":look_profile.preset_id,"tree_batches":batch_records,"camera":camera_params}))
	if not capture_path.is_empty():
		if compare_ground:
			set_ground_relief(false)
			await capture(capture_path.trim_suffix(".png")+"-flat-ground.png")
			set_ground_relief(true)
		if compare_rocks:
			set_rocks_visible(false)
			await capture(capture_path.trim_suffix(".png")+"-no-rocks.png")
			set_rocks_visible(true)
		if compare_periods and lighting_period!="day":
			var final_period:=lighting_period
			set_lighting_period("day")
			await capture(capture_path.trim_suffix(".png")+"-day-control.png")
			set_lighting_period(final_period)
		if compare_dof:
			var dof_attributes:=camera.attributes as CameraAttributesPractical
			assert(dof_attributes!=null,"DOF comparison requires a configured camera")
			dof_attributes.dof_blur_far_enabled=false
			await capture(capture_path.trim_suffix(".png")+"-no-dof.png")
			dof_attributes.dof_blur_far_enabled=true
		if compare_normals:
			set_facet_normals(false)
			await capture(capture_path.trim_suffix(".png")+"-smooth.png")
			set_facet_normals(true)
		await capture(capture_path)
		get_tree().quit()

func vec(a:Array) -> Vector3:return Vector3(a[0],a[1],a[2])

func set_motion_frozen(value:bool) -> void:
	if weather!=null:weather.set_frozen(value)
	elif camp!=null:camp.fire.freeze(value)
	refresh_frozen_viewport()

func refresh_frozen_viewport() -> void:
	# Keep the last completed frame while paused, including static lighting.
	# Re-render on a period change, then hold again; resume always restores drawing.
	var viewport:=get_viewport() as SubViewport
	if viewport==null:return
	frozen_render_generation+=1
	var generation:=frozen_render_generation
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	if look_profile!=null and look_profile.night_sky!=null and look_profile.night_sky.has_method("set_frozen"):
		look_profile.night_sky.set_frozen(false)
	if weather==null or not weather.frozen:return
	for i in 3:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		if generation!=frozen_render_generation:return
	if weather.frozen:
		viewport.render_target_update_mode=SubViewport.UPDATE_DISABLED
		if look_profile.night_sky!=null and look_profile.night_sky.has_method("set_frozen"):
			look_profile.night_sky.set_frozen(true)

func _unhandled_key_input(event:InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode==KEY_SPACE and weather!=null:set_motion_frozen(not weather.frozen)
		if event.keycode==KEY_1:request_lighting_period("morning")
		if event.keycode==KEY_2:request_lighting_period("midnight")

func _unhandled_input(event:InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.pressed:
		var origin:=camera.project_ray_origin(event.position)
		var ray:=PhysicsRayQueryParameters3D.create(origin,origin+camera.project_ray_normal(event.position)*camera.far,CAMPFIRE_INTERACTION_LAYER)
		var hit:=get_world_3d().direct_space_state.intersect_ray(ray)
		if not hit.is_empty():
			var to_night:bool=period_transition==null or period_transition.target_period!="midnight"
			request_lighting_period("midnight" if to_night else "morning")
			get_viewport().set_input_as_handled()

func prepare_period_transition() -> void:
	period_transition=load("res://scripts/traveler/panti/panti_period_transition.gd").new()
	period_transition.configure(self)

func request_lighting_period(period:String) -> void:
	if period_transition==null:prepare_period_transition()
	period_transition.request(period)
	refresh_frozen_viewport()

func tick_period_effects(delta:float,anim_t:float) -> void:
	if period_transition!=null:period_transition.tick(delta,anim_t)

func set_lighting_period(period:String) -> void:
	assert(period in ["day","sunset","morning","midnight"],"Unknown Panti period")
	if period in ["morning","midnight"] and period_lighting!=null:
		if period_transition==null:prepare_period_transition()
		period_transition.snap(period)
		refresh_frozen_viewport()
		return
	if period==lighting_period:return
	period_transition=null
	lighting_period=period
	look_profile.configure(self,false,false)
	if castle_lighting!=null:castle_lighting.set_period(period)
	if period_lighting!=null:period_lighting.apply_period()
	refresh_frozen_viewport()
	print("PANTI_PERIOD ",period)

func stage_point(a:Vector3) -> Vector3:
	return target+stage_basis*Vector3(a.x,a.y+float(settings.get("stage_elevation_u",0.0)),-a.z)

func update_camera() -> void:
	var frozen:Dictionary=camera_params
	camera.projection=Camera3D.PROJECTION_PERSPECTIVE
	camera.keep_aspect=Camera3D.KEEP_HEIGHT;camera.fov=float(frozen.fov_vertical_deg)
	camera.near=0.15;camera.far=900.0
	if settings.has("camera_composition"):
		camera.position=stage_point(vec(frozen.position_stage))
		camera.look_at(stage_point(vec(frozen.look_at_stage)))
		camera_pan_u=0.0
		return
	var elevation:=deg_to_rad(float(frozen.pitch_deg));var az:=float(frozen.azimuth_rad)
	var direction:=Vector3(cos(elevation)*sin(az),sin(elevation),cos(elevation)*cos(az))
	camera.position=target+direction*float(frozen.distance_u)
	camera.look_at(target+Vector3(0,float(frozen.lift_u),0))
	# Translate only the camera, leaving the stage fixed. Negative pan looks left.
	var pan:Dictionary=settings.get("camera_pan",{})
	if not pan.is_empty():
		var reference:=stage_point(vec(pan.reference_stage_position))
		var depth:float=(reference-camera.global_position).dot(-camera.global_basis.z)
		var viewport_size:=get_viewport().get_visible_rect().size
		var frame_width:float=2.0*depth*tan(deg_to_rad(camera.fov)*0.5)*viewport_size.x/viewport_size.y
		camera_pan_u=frame_width*float(pan.horizontal_frame_fraction)
		camera.position+=camera.global_basis.x*camera_pan_u

func set_cliff_buddha_glow(_enabled:bool) -> void:pass

func asset(path:String) -> Dictionary:
	var packed:=load(path) as PackedScene
	assert(packed!=null,"Missing processed Panti asset: "+path)
	var scene:=packed.instantiate()
	var source:MeshInstance3D=scene.find_children("*","MeshInstance3D",true,false)[0]
	var transform:=source.transform
	var parent:=source.get_parent()
	while parent is Node3D:
		transform=parent.transform*transform
		parent=parent.get_parent()
	var builder:=SurfaceTool.new();builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	var material:=source.get_active_material(0).duplicate() as StandardMaterial3D
	assert(material!=null and material.albedo_texture!=null,"Missing original Panti albedo")
	material.metallic=0.0;material.roughness=0.95
	material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
	builder.set_material(material)
	builder.append_from(source.mesh,0,transform)
	var mesh:=builder.commit()
	var result:Dictionary={"mesh":flat_mesh(mesh),"smooth_mesh":mesh,"material":material,"bounds":mesh.get_aabb(),"triangles":mesh.surface_get_array_index_len(0)/3,"source":path}
	scene.free()
	return result

func flat_mesh(mesh:ArrayMesh) -> ArrayMesh:
	# Split vertices at triangle boundaries; keep geometry, UVs and basecolor intact.
	var arrays:=mesh.surface_get_arrays(0)
	var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var normals:PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
	var uv:PackedVector2Array=arrays[Mesh.ARRAY_TEX_UV]
	var indices:PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
	var builder:=SurfaceTool.new();builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	builder.set_material(mesh.surface_get_material(0))
	for i in range(0,indices.size(),3):
		var a:=indices[i];var b:=indices[i+1];var c:=indices[i+2]
		var normal:Vector3=(vertices[b]-vertices[a]).cross(vertices[c]-vertices[a]).normalized()
		if normal.dot(normals[a]+normals[b]+normals[c])<0.0:normal=-normal
		for index in [a,b,c]:
			builder.set_normal(normal);builder.set_uv(uv[index]);builder.add_vertex(vertices[index])
	return builder.commit()

func set_facet_normals(enabled:bool) -> void:
	facet_normals=enabled
	for record in normal_targets:
		if record.has("node"):record.node.mesh=record.flat if enabled else record.smooth
		else:record.multimesh.mesh=record.flat if enabled else record.smooth

func build_ground() -> void:
	snow_flat_mesh=PlaneMesh.new();snow_flat_mesh.size=Vector2(settings.ground.size_u[0],settings.ground.size_u[1])
	var mat:=StandardMaterial3D.new()
	mat.albedo_color=Color(settings.ground.albedo[0],settings.ground.albedo[1],settings.ground.albedo[2])
	mat.roughness=1.0;mat.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
	snow_ground=MeshInstance3D.new();snow_ground.name="SnowGround";snow_ground.material_override=mat
	# Preserve the accepted shadow reception; avoid low-sun self-shadow stripes.
	snow_ground.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(snow_ground)
	if settings.ground.has("relief"):
		snow_surface=load("res://scripts/traveler/panti/panti_snow_ground.gd").new()
		snow_relief_mesh=snow_surface.build(self)
	set_ground_relief(snow_relief_mesh!=null)

func set_ground_relief(enabled:bool) -> void:
	snow_relief_enabled=enabled and snow_relief_mesh!=null
	snow_ground.mesh=snow_relief_mesh if snow_relief_enabled else snow_flat_mesh
	snow_ground.position=Vector3.ZERO if snow_relief_enabled else stage_point(vec(settings.ground.center_stage))
	update_rock_grounding()

func build_castle() -> void:
	var resource:=asset(settings.fortress.asset)
	castle=MeshInstance3D.new();castle.name="PantiFortress";castle.mesh=resource.mesh
	normal_targets.append({"node":castle,"flat":resource.mesh,"smooth":resource.smooth_mesh})
	var scale_value:float=float(settings.fortress.height_u)/resource.bounds.size.y
	castle.scale=Vector3.ONE*scale_value
	castle.position=stage_point(vec(settings.fortress.stage_position))
	castle.rotation.y=float(motion_params._measured.traveler_camera.azimuth_rad)+deg_to_rad(float(settings.fortress.yaw_relative_camera_deg))
	world.add_child(castle)
	batch_records.append({"kind":"fortress","count":1,"triangles_each":resource.triangles,"height_u":settings.fortress.height_u,"source_bounds":str(resource.bounds),"draw_batches":1})

func build_trees() -> void:
	var resource:=asset(settings.trees.asset)
	if settings.trees.has("instances"):
		build_authored_trees(resource)
		return
	var rng:=RandomNumberGenerator.new();rng.seed=int(settings.seed)
	var tree:Dictionary=settings.trees
	var exclusion:Array=tree.exclude_castle_rectangle
	for tier in tree.tiers:
		var count:int=tier.count
		var mm:=MultiMesh.new();mm.transform_format=MultiMesh.TRANSFORM_3D
		mm.use_custom_data=true;mm.mesh=resource.mesh;mm.instance_count=count
		normal_targets.append({"multimesh":mm,"flat":resource.mesh,"smooth":resource.smooth_mesh})
		for i in count:
			var theta:float=lerpf(float(tree.arc_deg[0]),float(tree.arc_deg[1]),(float(i)+0.5)/count)+rng.randf_range(-float(tree.angle_jitter_deg),float(tree.angle_jitter_deg))
			var radius:float=float(tier.radius_u)+rng.randf_range(-float(tree.radial_jitter_u),float(tree.radial_jitter_u))
			var x:float=float(tree.center_stage[0])+cos(deg_to_rad(theta))*radius
			var depth:float=float(tree.center_stage[1])+sin(deg_to_rad(theta))*float(tier.depth_radius_u)*float(tree.depth_radius_ratio)+rng.randf_range(-float(tree.radial_jitter_u),float(tree.radial_jitter_u))
			depth=maxf(depth,float(tree.foreground_min_depth_u))
			if x>exclusion[0] and x<exclusion[1] and depth>exclusion[2] and depth<exclusion[3]:depth=float(exclusion[3])+float(tier.height_u)*0.21
			var height:float=float(tier.height_u)*float(tree.get("height_multiplier",1.0))*(1.0+rng.randf_range(-float(tree.scale_jitter),float(tree.scale_jitter)))
			var scaling:float=height/resource.bounds.size.y
			var basis:=Basis(Vector3.UP,deg_to_rad(rng.randf_range(tree.yaw_random_deg[0],tree.yaw_random_deg[1]))).scaled(Vector3.ONE*scaling)
			var at:=stage_point(Vector3(x,0,depth))
			mm.set_instance_transform(i,Transform3D(basis,at))
			mm.set_instance_custom_data(i,Color(rng.randf(),rng.randf_range(.85,1.15),rng.randf_range(.8,1.2),1.0))
			tree_records.append({"tier":tier.name,"height_u":height,"world_position":[at.x,at.y,at.z],"stage_position":[x,0,depth],"height_px":camera.unproject_position(at).distance_to(camera.unproject_position(at+Vector3.UP*height))})
		var node:=MultiMeshInstance3D.new();node.name="SnowCedars_"+str(tier.name);node.multimesh=mm;world.add_child(node)
		batch_records.append({"kind":"pine_"+str(tier.name),"count":count,"triangles_each":resource.triangles,"height_u_nominal":float(tier.height_u)*float(tree.get("height_multiplier",1.0)),"draw_batches":1})

func build_authored_trees(resource:Dictionary) -> void:
	var groups:Dictionary={}
	for entry in settings.trees.instances:
		var tier:String=entry.get("tier","G")
		if not groups.has(tier):groups[tier]=[]
		groups[tier].append(entry)
	for tier in groups:
		build_tree_group(resource,str(tier),groups[tier])

func build_tree_group(resource:Dictionary,tier:String,instances:Array) -> void:
	var mm:=MultiMesh.new();mm.transform_format=MultiMesh.TRANSFORM_3D
	mm.use_custom_data=true;mm.mesh=resource.mesh;mm.instance_count=instances.size()
	normal_targets.append({"multimesh":mm,"flat":resource.mesh,"smooth":resource.smooth_mesh})
	var rng:=RandomNumberGenerator.new();rng.seed=int(settings.seed)
	for i in instances.size():
		var entry:Dictionary=instances[i]
		var height:float=entry.height_u
		var width_scale:float=float(entry.crown_diameter_u)/maxf(resource.bounds.size.x,resource.bounds.size.z)
		var scaling:=Vector3(width_scale,height/resource.bounds.size.y,width_scale)
		var basis:=Basis(Vector3.UP,deg_to_rad(float(entry.yaw_deg))).scaled(scaling)
		var at:=stage_point(vec(entry.stage_position))
		mm.set_instance_transform(i,Transform3D(basis,at))
		mm.set_instance_custom_data(i,Color(rng.randf(),rng.randf_range(.85,1.15),rng.randf_range(.8,1.2),1.0))
		tree_records.append({"id":entry.id,"tier":tier,"height_u":height,"crown_diameter_u":entry.crown_diameter_u,"world_position":[at.x,at.y,at.z],"stage_position":entry.stage_position,"height_px":camera.unproject_position(at).distance_to(camera.unproject_position(at+Vector3.UP*height))})
	var node:=MultiMeshInstance3D.new();node.name="SnowCedars_"+tier;node.multimesh=mm;world.add_child(node)
	batch_records.append({"kind":"pine_"+tier,"count":instances.size(),"triangles_each":resource.triangles,"draw_batches":1})

func build_rocks() -> void:
	var rock_settings:Dictionary=settings.get("rocks",{})
	if rock_settings.is_empty():return
	var resources:Dictionary={}
	var groups:Dictionary={}
	for entry in rock_settings.instances:
		var key:String=str(entry.asset)+"_"+str(entry.tier)
		if not groups.has(key):groups[key]=[]
		groups[key].append(entry)
	for key in groups:
		var instances:Array=groups[key]
		var asset_id:String=instances[0].asset
		if not resources.has(asset_id):resources[asset_id]=asset(str(rock_settings.assets[asset_id]))
		var resource:Dictionary=resources[asset_id]
		var mm:=MultiMesh.new();mm.transform_format=MultiMesh.TRANSFORM_3D
		mm.mesh=resource.mesh;mm.instance_count=instances.size()
		normal_targets.append({"multimesh":mm,"flat":resource.mesh,"smooth":resource.smooth_mesh})
		for i in instances.size():
			var entry:Dictionary=instances[i]
			var scale_value:float=float(entry.height_u)/resource.bounds.size.y
			var basis:=Basis(Vector3.UP,deg_to_rad(float(entry.yaw_deg))).scaled(Vector3.ONE*scale_value)
			var transform:=Transform3D(basis,stage_point(vec(entry.stage_position)))
			mm.set_instance_transform(i,transform)
			var minimum:=Vector2(INF,INF);var maximum:=Vector2(-INF,-INF)
			for vertex in resource.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
				var pixel:=camera.unproject_position(transform*vertex)
				minimum=minimum.min(pixel);maximum=maximum.max(pixel)
			rock_records.append({"id":entry.id,"asset":asset_id,"tier":entry.tier,"cluster":entry.cluster,"stage_position":entry.stage_position,"height_u":entry.height_u,"height_px":maximum.y-minimum.y,"width_px":maximum.x-minimum.x,"bounds_px":[minimum.x,minimum.y,maximum.x,maximum.y],"triangles_each":resource.triangles})
			rock_ground_bindings.append({"multimesh":mm,"index":i,"entry":entry,"basis":basis,"mesh":resource.mesh,"record":rock_records[-1]})
		var node:=MultiMeshInstance3D.new();node.name="SnowRocks_"+str(key);node.multimesh=mm;world.add_child(node)
		rock_nodes.append(node)
		batch_records.append({"kind":"rock_"+str(key),"count":instances.size(),"triangles_each":resource.triangles,"draw_batches":1})
	update_rock_grounding()

func update_rock_grounding() -> void:
	for binding in rock_ground_bindings:
		var entry:Dictionary=binding.entry
		var at:=vec(entry.stage_position)
		if snow_relief_enabled:at.y=float(snow_surface.rock_heights[str(entry.id)])
		var transform:=Transform3D(binding.basis,stage_point(at))
		binding.multimesh.set_instance_transform(binding.index,transform)
		var minimum:=Vector2(INF,INF);var maximum:=Vector2(-INF,-INF)
		for vertex in binding.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			var pixel:=camera.unproject_position(transform*vertex)
			minimum=minimum.min(pixel);maximum=maximum.max(pixel)
		binding.record["effective_stage_position"]=[at.x,at.y,at.z]
		binding.record["ground_height_adjustment_u"]=at.y-float(entry.stage_position[1])
		binding.record["height_px"]=maximum.y-minimum.y
		binding.record["width_px"]=maximum.x-minimum.x
		binding.record["bounds_px"]=[minimum.x,minimum.y,maximum.x,maximum.y]

func set_rocks_visible(enabled:bool) -> void:
	rocks_visible=enabled
	for node in rock_nodes:node.visible=enabled

func build_character() -> void:
	if camp!=null:
		build_seated_character()
		return
	character=Node3D.new();character.name="ApprovedTraveler";world.add_child(character)
	character.position=stage_point(vec(settings.character.stage_position))
	character_model=load(str(settings.character.scene)).instantiate();character.add_child(character_model)
	var player:=character_model.find_child("AnimationPlayer",true,false) as AnimationPlayer
	player.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	player.play("idle");player.advance(0.0)
	await RenderingServer.frame_post_draw
	var mesh:MeshInstance3D=character_model.find_children("*","MeshInstance3D",true,false)[0]
	var bounds:=mesh.bake_mesh_from_current_skeleton_pose().get_aabb()
	character_model.position=Vector3(-bounds.get_center().x,-bounds.position.y,-bounds.get_center().z)
	character_style=load("res://scripts/traveler/character_style.gd").new();character_style.configure(character_model)
	character.scale=Vector3.ONE*float(character_style.settings.scale)
	character.look_at(stage_point(vec(settings.fortress.stage_position)),Vector3.UP,true)

func build_seated_character() -> void:
	var idle:Dictionary=settings.camp.get("seated_idle",{})
	character_is_baked=not bool(idle.get("enabled",false))
	character=Node3D.new();character.name="SeatedTraveler";world.add_child(character)
	var scene_path:String="res://assets/traveler/panti/camp/character/sitting-pose.glb" if character_is_baked else str(idle.asset)
	character_model=load(scene_path).instantiate()
	character.add_child(character_model)
	if not character_is_baked:
		seated_actor=load("res://scripts/traveler/panti/panti_seated_actor.gd").new()
		seated_actor.configure(character_model,idle)
	character_style=load("res://scripts/traveler/panti/panti_seated_style.gd").new()
	character_style.configure(character_model,float(settings.camp.get("character_outline_width_multiplier",1.0)))
	character.scale=Vector3.ONE*float(character_style.settings.scale)
	character.rotation.y=float(motion_params._measured.traveler_camera.azimuth_rad)+deg_to_rad(float(settings.camp.seat.yaw_deg))
	seated_landmarks=JSON.parse_string(FileAccess.get_file_as_string("res://assets/traveler/panti/camp/character/seated-landmarks.json"))
	var seat_local:Vector3=vec(seated_landmarks.landmarks.seat_contact_local) if seated_actor==null else seated_actor.seat_anchor
	character.global_position=camp.seat_world-character.global_basis*seat_local

func projected_bounds(mesh:MeshInstance3D,posed:bool=false) -> Dictionary:
	var geometry:Mesh=mesh.bake_mesh_from_current_skeleton_pose() if posed and not character_is_baked else mesh.mesh
	var minimum:=Vector2(INF,INF);var maximum:=-minimum
	var depth_min:=INF;var depth_max:=-INF
	for surface in geometry.get_surface_count():
		for vertex in geometry.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			var world_vertex:Vector3=mesh.global_transform*vertex
			var pixel:=camera.unproject_position(world_vertex)
			var depth:float=(world_vertex-camera.global_position).dot(-camera.global_basis.z)
			depth_min=minf(depth_min,depth);depth_max=maxf(depth_max,depth)
			minimum=minimum.min(pixel);maximum=maximum.max(pixel)
	return {"bounds_px":[minimum.x,minimum.y,maximum.x,maximum.y],"width_px":maximum.x-minimum.x,"height_px":maximum.y-minimum.y,"width_fraction":(maximum.x-minimum.x)/get_viewport().get_visible_rect().size.x,"camera_depth_range_u":[depth_min,depth_max]}

func capture(output_path:String) -> void:
	for _i in 120:await RenderingServer.frame_post_draw
	var samples:Array[float]=[]
	var previous:=Time.get_ticks_usec()
	for _i in 180:
		await RenderingServer.frame_post_draw
		var now:=Time.get_ticks_usec();samples.append(float(now-previous)/1000.0);previous=now
	var global_draws:=RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var viewport_draws:=get_viewport().get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var primitives:=RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var image:=get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var error:=image.save_png(output_path)
	var sorted:=samples.duplicate();sorted.sort()
	var body:MeshInstance3D=seated_actor.body if seated_actor!=null else character_model.find_children("*","MeshInstance3D",true,false)[0]
	var report:Dictionary={"stage":settings.stage,"view":selected,"image_size":[image.get_width(),image.get_height()],"viewport_size":[get_viewport().get_visible_rect().size.x,get_viewport().get_visible_rect().size.y],"capture_error":error,"draw_calls":global_draws,"viewport_draw_calls":viewport_draws,"rendered_primitives":primitives,"frame_ms":{"p50":sorted[89],"p95":sorted[170],"samples":samples,"sample_count":180,"warmup_frames":120,"vsync_disabled":DisplayServer.window_get_vsync_mode()==DisplayServer.VSYNC_DISABLED,"engine_max_fps":Engine.max_fps},"camera":motion_params._measured.traveler_camera,"camera_transform":str(camera.global_transform),"look":look_profile.evidence(image),"layout":settings,"fortress_projection":projected_bounds(castle),"character_projection":projected_bounds(body,true),"character_style":character_style.evidence(),"batches":batch_records,"trees":tree_records,"note":"Composition checkpoint: simple snow plane and static approved character for scale. Detailed ground, rocks, wind and clouds await composition review."}
	report["face_normals"]=facet_normals
	if weather!=null:report["weather"]=weather.evidence()
	report["paused_render_hold"]=get_viewport() is SubViewport and get_viewport().render_target_update_mode==SubViewport.UPDATE_DISABLED
	if castle_lighting!=null:report["castle_lighting"]=castle_lighting.evidence()
	if period_lighting!=null:report["period_lighting"]=period_lighting.evidence()
	if period_transition!=null:report["period_transition"]=period_transition.evidence()
	report["rocks"]={"visible":rocks_visible,"comparison_same_process":compare_rocks,"batch_count":rock_nodes.size(),"instances":rock_records}
	report["ground"]={"relief_enabled":snow_relief_enabled,"comparison_same_process":compare_ground,"geometry":snow_surface.measured if snow_surface!=null else {},"albedo":settings.ground.albedo}
	report["note"]="Panti composition with authored snow relief, cedars and rock clusters. Motion awaits review."
	if camp!=null:
		report["camp"]=camp.evidence()
		report["camp"]["character_pose"]=seated_actor.metadata if seated_actor!=null else seated_landmarks
		if seated_actor!=null:report["camp"]["character_animation"]=seated_actor.evidence()
		var seat_now:Vector3=seated_actor.current_seat_anchor() if seated_actor!=null else vec(seated_landmarks.landmarks.seat_contact_local)
		report["camp"]["seat_contact_error_u"]=(character_model.global_transform*seat_now).distance_to(camp.seat_world)
		report["note"]="Panti camp: supplied textured props, seated character and original toon style, continuous fire, wind, mist and snow. Character animation status recorded separately."
	report["camera"]=camera_params
	report["camera_override_authorization"]=settings.get("camera_override",{})
	report["camera_pan"]={"settings":settings.get("camera_pan",{}),"translation_u":camera_pan_u}
	var dof_attributes:=camera.attributes as CameraAttributesPractical
	if dof_attributes!=null:
		report["depth_of_field"]={"far_enabled":dof_attributes.dof_blur_far_enabled,"far_distance_u":dof_attributes.dof_blur_far_distance,"far_transition_u":dof_attributes.dof_blur_far_transition,"near_enabled":dof_attributes.dof_blur_near_enabled,"blur_amount":dof_attributes.dof_blur_amount,"comparison_same_process":compare_dof}
	var camera_forward:Vector3=-camera.global_basis.z
	report["camera_geometry"]={"position_u":[camera.global_position.x,camera.global_position.y,camera.global_position.z],"height_above_ground_u":camera.global_position.y-stage_point(vec(settings.ground.center_stage)).y,"optical_axis_elevation_deg":rad_to_deg(asin(camera_forward.y)),"horizontal_orbit_distance_u":Vector2(camera.position.x-target.x,camera.position.z-target.z).length()}
	report["normal_comparison_same_process"]=compare_normals
	report["lighting_period"]=lighting_period
	report["period_comparison_same_process"]=compare_periods
	var character_foot:=camera.unproject_position(character.global_position)
	report["character_placement"]={"world_position_u":[character.global_position.x,character.global_position.y,character.global_position.z],"root_screen_px":[character_foot.x,character_foot.y],"stage_position_u":settings.character.stage_position,"reference":settings.character.get("placement_reference",{})}
	if camp!=null:
		var actor_stage:Vector3=stage_basis.inverse()*(character.global_position-target)
		report.character_placement.stage_position_u=[actor_stage.x,actor_stage.y,-actor_stage.z]
		report.character_placement.reference={"source":settings.camp.reference,"pose":"seated_idle loop" if seated_actor!=null else "supplied Sitting clip, stable seated frame","anchor":"pelvis contact to stump seat"}
	FileAccess.open(output_path.trim_suffix(".png")+".json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("PANTI_CAPTURE ",JSON.stringify({"image_size":report.image_size,"fortress":report.fortress_projection,"character":report.character_projection,"draw_calls":global_draws,"viewport_draw_calls":viewport_draws,"p50":sorted[89],"p95":sorted[170]}))
	if error!=OK:push_error("Panti capture save failed: "+output_path)
