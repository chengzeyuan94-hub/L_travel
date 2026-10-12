# 自动生成，不要手改。由 tools/traveler/lookdev_baghdad/lookdev.py 每次跑批前
# 从 scripts/traveler/baghdad/baghdad_viewer.gd 克隆：数据路径换成 lookdev 快照，
# 并在 ready_for_capture 之前挂上 lookdev_overlay.gd。Codex 的文件零写入。
extends Node3D
## Independent Baghdad sunset composition. Copied from Panti; no Atlas or live motion.
var world:Node3D
var camera:Camera3D
var sun:DirectionalLight3D
var environment:Environment
var settings:Dictionary={}
var camera_params:Dictionary={}
var selected:=""
var requested_view:=""
var lighting_period:="sunset"
var capture_path:=""
var studio_mode:=false
var cinematic_sunset:=false
var prepare_lightmap:=false
var debug_hide_mountains:=false
var debug_hide_ground:=false
var debug_hide_skyline:=false
var debug_hide_sand_ridges:=false
var look_profile:RefCounted
var storm_look:Node3D
var arch:Node3D
var tree:Node3D
var character:Node3D
var character_model:Node3D
var character_style:RefCounted
var character_body:MeshInstance3D
var ground:MeshInstance3D
var ground_builder:RefCounted
var ground_surface:RefCounted
var supporting_props:RefCounted
var mountain_layer:RefCounted
var ready_for_capture:=false
var asset_cache:Dictionary={}
var asset_records:Array=[]
var layout_records:Array=[]
var character_geometry:Mesh
var main_assets:Array[Node3D]=[]

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps=0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):requested_view=arg.trim_prefix("--view=")
		if arg.begins_with("--capture="):capture_path=arg.trim_prefix("--capture=")
		if arg=="--studio":studio_mode=true
		if arg=="--cinematic-sunset":cinematic_sunset=true
		if arg=="--prepare-lightmap":prepare_lightmap=true
		if arg=="--debug-hide-mountains":debug_hide_mountains=true
		if arg=="--debug-hide-ground":debug_hide_ground=true
		if arg=="--debug-hide-skyline":debug_hide_skyline=true
		if arg=="--debug-hide-sand-ridges":debug_hide_sand_ridges=true
	if requested_view!="baghdad":
		push_error("Baghdad scene requires --view=baghdad; no preset fallback")
		get_tree().quit(1);return
	selected=requested_view
	settings=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/baghdad_scene.lookdev.json"))
	lighting_period=str(settings.get("default_period","sunset"))
	if cinematic_sunset:lighting_period="cinematic-sunset"
	camera_params=settings.camera.duplicate(true)
	world=Node3D.new();world.name="BaghdadWorld";add_child(world)
	camera=Camera3D.new();camera.name="CompositionCamera";add_child(camera);update_camera();camera.make_current()
	sun=DirectionalLight3D.new();sun.name="SunsetBacklight";add_child(sun)
	environment=Environment.new()
	var environment_node:=WorldEnvironment.new();environment_node.name="SunsetEnvironment";environment_node.environment=environment;add_child(environment_node)
	look_profile=load("res://scripts/traveler/baghdad/baghdad_look.gd").new();look_profile.configure(self)
	build_ground()
	build_main_assets()
	build_mountains()
	await build_character()
	build_supporting_props()
	_apply_lowpoly_materials()
	# Independent Blender detail layer; keep the live editor layout untouched.
	world.add_child(load("res://scripts/traveler/baghdad/baghdad_foreground_details.gd").new().build(self))
	if not studio_mode and not prepare_lightmap and not OS.get_cmdline_user_args().has("--clear-weather"):
		storm_look=load("res://scripts/traveler/baghdad/baghdad_storm_look.gd").new()
		add_child(storm_look)
		storm_look.configure(self)
	load("res://tools/traveler/lookdev_baghdad/lookdev_overlay.gd").new().apply(self)
	ready_for_capture=true
	print("BAGHDAD_READY ",JSON.stringify({"view":selected,"preset":look_profile.preset_id,"studio":studio_mode,"cinematic_sunset":cinematic_sunset,"camera":camera_params,"motion":false,"interaction":false,"assets":asset_records}))
	if prepare_lightmap:
		var prep:RefCounted=load("res://scripts/traveler/baghdad/baghdad_lightmap_prepare.gd").new()
		# Binary .scn keeps the de-indexed UV2 bake copy loadable in the editor;
		# the equivalent text .tscn is hundreds of MB for this asset set.
		var packed_result:Dictionary=prep.pack_static(self,"res://scenes/traveler/baghdad_cinematic_baked.scn")
		print("BAGHDAD_LIGHTMAP_PREPARED ",JSON.stringify(packed_result))
		get_tree().quit()
		return
	if not capture_path.is_empty():
		await capture(capture_path)
		get_tree().quit()

func vec(a:Array) -> Vector3:
	return Vector3(float(a[0]),float(a[1]),float(a[2]))

func stage_point(a:Vector3) -> Vector3:
	# Baghdad stage is screen-right X, Y up, +Z into the view. Godot camera-right
	# is world -X when looking +Z, so explicitly mirror X for authored stage points.
	return Vector3(-a.x,a.y,a.z)

func update_camera() -> void:
	camera.projection=Camera3D.PROJECTION_PERSPECTIVE
	camera.keep_aspect=Camera3D.KEEP_HEIGHT
	camera.fov=float(camera_params.fov_vertical_deg)
	camera.near=float(camera_params.get("near_u",0.03));camera.far=float(camera_params.get("far_u",500.0))
	camera.position=stage_point(vec(camera_params.position))
	camera.look_at(stage_point(vec(camera_params.look_at)))

func asset(path:String) -> Dictionary:
	if asset_cache.has(path):return asset_cache[path]
	var packed:=load(path) as PackedScene
	assert(packed!=null,"Missing Baghdad asset: "+path)
	var scene:=packed.instantiate()
	var meshes:=scene.find_children("*","MeshInstance3D",true,false)
	assert(meshes.size()==1,"Baghdad source contract: exactly one MeshInstance3D: "+path)
	var source:=meshes[0] as MeshInstance3D
	assert(source.mesh!=null and source.mesh.get_surface_count()==1,"Baghdad source contract: one mesh surface")
	var transform:=source.transform
	var parent:=source.get_parent()
	while parent is Node3D:
		transform=(parent as Node3D).transform*transform
		parent=parent.get_parent()
	var material:=source.get_active_material(0) as StandardMaterial3D
	assert(material!=null and material.albedo_texture!=null,"Missing original Baghdad basecolor: "+path)
	var mesh:Mesh=source.mesh
	var count:int=mesh.surface_get_array_index_len(0)
	if count==0:count=mesh.surface_get_array_len(0)
	var bounds:AABB=transform*mesh.get_aabb()
	var result:Dictionary={"mesh":mesh,"material":material.duplicate(),"source_transform":transform,"bounds":bounds,"triangles":count/3,"source":path}
	asset_cache[path]=result
	asset_records.append({"source":path,"triangles":count/3,"mesh_count":1,"surface_count":1,"original_geometry_preserved":true,"source_bounds":{"position":vector_array(bounds.position),"size":vector_array(bounds.size)},"basecolor_texture":material.albedo_texture.resource_path,"normal_texture":material.normal_texture.resource_path if material.normal_texture!=null else "","normal_mapping_enabled":material.normal_enabled,"source_normals_preserved":true})
	scene.free()
	return result

func place_asset(name_value:String,resource:Dictionary,configuration:Dictionary,height_u:float) -> Node3D:
	var root:=Node3D.new();root.name=name_value;world.add_child(root)
	var bounds:AABB=resource.bounds
	var scale_value:=height_u/bounds.size.y
	if configuration.has("uniform_scale"):scale_value=float(configuration.uniform_scale)
	root.scale=Vector3.ONE*scale_value
	root.rotation.y=deg_to_rad(float(configuration.get("yaw_deg",0.0)))
	root.position=stage_point(vec(configuration.stage_position))
	var mesh:=MeshInstance3D.new();mesh.name="OriginalTexturedMesh";mesh.mesh=resource.mesh
	mesh.material_override=resource.material
	mesh.transform=resource.source_transform
	# Center horizontal axes, then put the asset's actual bottom on the authored position.
	mesh.position-=Vector3(bounds.get_center().x,bounds.position.y,bounds.get_center().z)
	root.add_child(mesh)
	if not bool(configuration.get("cast_shadow",true)):mesh.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	main_assets.append(root)
	layout_records.append({"id":name_value,"stage_position":configuration.stage_position,"yaw_deg":configuration.get("yaw_deg",0.0),"uniform_scale":scale_value,"height_u":bounds.size.y*scale_value,"triangles_each":resource.triangles})
	return root

func build_main_assets() -> void:
	var arch_resource:=asset(str(settings.assets.arch))
	var arch_config:Dictionary=settings.arch.duplicate(true)
	var source_opening:=float(arch_config.source_opening_height_u)
	assert(source_opening>0.0,"S1 arch clear-opening height is required")
	arch_config.uniform_scale=float(arch_config.opening_height_u)/source_opening
	arch=place_asset("ForegroundArch",arch_resource,arch_config,float(arch_resource.bounds.size.y)*float(arch_config.uniform_scale))
	tree=place_asset("TreeOfLife",asset(str(settings.assets.tree)),settings.tree,float(settings.tree.height_u))
	var mosque_resource:=asset(str(settings.assets.mosque))
	for entry in settings.skyline.instances:
		var skyline_node:=place_asset("Skyline_"+str(entry.id),mosque_resource,entry,float(settings.skyline.height_u)*float(entry.get("height_scale",1.0)))
		if debug_hide_skyline:skyline_node.visible=false

func build_mountains() -> void:
	if not settings.has("mountains"):
		return
	mountain_layer=load("res://scripts/traveler/baghdad/baghdad_mountain_layer.gd").new()
	mountain_layer.configure(self)
	var node:Node3D=mountain_layer.build()
	world.add_child(node)
	if debug_hide_mountains:node.visible=false

func build_ground() -> void:
	var cfg:Dictionary=settings.ground
	if cfg.has("builder"):
		ground_builder=load(str(cfg.builder)).new()
		ground_surface=ground_builder
		ground=ground_builder.build(self)
		if ground.get_parent()==null:world.add_child(ground)
		if debug_hide_ground:ground.visible=false
		return
	var plane:=PlaneMesh.new();plane.size=Vector2(float(cfg.size_u[0]),float(cfg.size_u[1]))
	var mat:=StandardMaterial3D.new();mat.albedo_color=Color(float(cfg.albedo[0]),float(cfg.albedo[1]),float(cfg.albedo[2]))
	mat.roughness=1.0;mat.specular_mode=BaseMaterial3D.SPECULAR_DISABLED;mat.cull_mode=BaseMaterial3D.CULL_DISABLED
	ground=MeshInstance3D.new();ground.name="DesertGround";ground.mesh=plane;ground.material_override=mat
	ground.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if debug_hide_ground:ground.visible=false
	ground.position=stage_point(vec(cfg.center_stage));world.add_child(ground)

func build_character() -> void:
	var cfg:Dictionary=settings.character
	character=Node3D.new();character.name="ApprovedTraveler";world.add_child(character)
	character_model=load(str(cfg.scene)).instantiate();character.add_child(character_model)
	var player:=character_model.find_child("AnimationPlayer",true,false) as AnimationPlayer
	if player!=null:
		player.callback_mode_process=AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		player.play(str(cfg.get("pose","idle")));player.advance(float(cfg.get("pose_time_s",0.0)))
	await RenderingServer.frame_post_draw
	character_body=character_model.find_children("*","MeshInstance3D",true,false)[0] as MeshInstance3D
	character_geometry=character_body.bake_mesh_from_current_skeleton_pose()
	var bounds:=character_geometry.get_aabb()
	character_model.position=Vector3(-bounds.get_center().x,-bounds.position.y,-bounds.get_center().z)
	character_style=load("res://scripts/traveler/character_style.gd").new();character_style.configure(character_model)
	for shell in character_style.shells:
		shell.material_override.grow_amount*=float(cfg.get("outline_width_multiplier",1.0))
	character.scale=Vector3.ONE*float(cfg.height_u)
	character.rotation.y=deg_to_rad(float(cfg.get("yaw_deg",0.0)))
	character.position=stage_point(vec(cfg.stage_position))

func build_supporting_props() -> void:
	if not settings.has("supporting_props_builder"):return
	supporting_props=load(str(settings.supporting_props_builder)).new()
	if debug_hide_sand_ridges and settings.has("supporting_props"):
		settings.supporting_props.surface_details.enabled=false
	world.add_child(supporting_props.build(self))

func _apply_lowpoly_materials() -> void:
	if look_profile==null or not bool(look_profile.recipe.params.get("lowpoly_materials",false)):
		return
	var roughness:=clampf(float(look_profile.recipe.params.get("lowpoly_roughness",0.86)),0.0,1.0)
	var disabled:=bool(look_profile.recipe.params.get("lowpoly_specular_disabled",true))
	var cinematic_materials:=bool(look_profile.recipe.params.get("cinematic_materials",false))
	var tree_boost:=maxf(float(look_profile.recipe.params.get("tree_albedo_boost",1.0)),1.0)
	var tree_emission_enabled:=bool(look_profile.recipe.params.get("tree_emission_enabled",false))
	var tree_emission_color:=look_profile.recipe.params.get("tree_emission_color",[0.0,0.0,0.0]) as Array
	var tree_emission_energy:=maxf(float(look_profile.recipe.params.get("tree_emission_energy",0.0)),0.0)
	var skyline_albedo_scale:=clampf(float(look_profile.recipe.params.get("skyline_albedo_scale",1.0)),0.0,1.0)
	var skyline_emission_enabled:=bool(look_profile.recipe.params.get("skyline_emission_enabled",false))
	var changed:=0
	for item in world.find_children("*","MeshInstance3D",true,false):
		var mesh_node:=item as MeshInstance3D
		if mesh_node==null or (character!=null and character.is_ancestor_of(mesh_node)):
			continue
		var source:=mesh_node.get_active_material(0) as StandardMaterial3D
		if source==null:
			continue
		var material:=source.duplicate() as StandardMaterial3D
		material.shading_mode=BaseMaterial3D.SHADING_MODE_PER_PIXEL
		material.diffuse_mode=BaseMaterial3D.DIFFUSE_BURLEY if cinematic_materials else BaseMaterial3D.DIFFUSE_TOON
		material.metallic=0.0
		material.roughness=roughness
		if tree!=null and tree.is_ancestor_of(mesh_node):
			material.albedo_color=material.albedo_color*tree_boost
			if tree_emission_enabled and tree_emission_color.size()>=3:
				material.emission_enabled=true
				material.emission=Color(float(tree_emission_color[0]),float(tree_emission_color[1]),float(tree_emission_color[2]))
				material.emission_energy_multiplier=tree_emission_energy
		if mesh_node.name.begins_with("Skyline_"):
			# The distant mosque texture contains bright window pixels. They are
			# albedo detail, not a separate night-light system; keep them subdued
			# in the sunset sample and explicitly prevent inherited source emission.
			material.albedo_color=material.albedo_color*skyline_albedo_scale
			material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
			material.roughness=1.0
			material.emission_enabled=skyline_emission_enabled
			if not skyline_emission_enabled:
				material.emission=Color.BLACK
				material.emission_energy_multiplier=0.0
		if cinematic_materials:
			material.specular_mode=BaseMaterial3D.SPECULAR_SCHLICK_GGX
		elif disabled:
			material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
		mesh_node.material_override=material
		changed+=1
	world.set_meta("lowpoly_materials",{"enabled":true,"mesh_count":changed,"shading_mode":"PER_PIXEL","diffuse_mode":"BURLEY" if cinematic_materials else "TOON","roughness":roughness,"specular_disabled":disabled and not cinematic_materials,"cinematic_materials":cinematic_materials,"tree_albedo_boost":tree_boost,"tree_emission_enabled":tree_emission_enabled,"tree_emission_energy":tree_emission_energy,"skyline_albedo_scale":skyline_albedo_scale,"skyline_emission_enabled":skyline_emission_enabled,"skyline_specular_disabled":true})

func projected_bounds(node:Node3D,posed_mesh:Mesh=null) -> Dictionary:
	var minimum:=Vector2(INF,INF);var maximum:=Vector2(-INF,-INF)
	var minimum_depth:=INF;var maximum_depth:=-INF
	var meshes:Array=[]
	if node is MeshInstance3D:meshes.append(node)
	else:meshes=node.find_children("*","MeshInstance3D",true,false)
	for item in meshes:
		var mesh_node:=item as MeshInstance3D
		var geometry:Mesh=posed_mesh if posed_mesh!=null else mesh_node.mesh
		if geometry==null:continue
		for surface in geometry.get_surface_count():
			for vertex in geometry.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
				var world_vertex:Vector3=mesh_node.global_transform*vertex
				var depth:float=(world_vertex-camera.global_position).dot(-camera.global_basis.z)
				if depth<=camera.near:continue
				var pixel:=camera.unproject_position(world_vertex)
				minimum=minimum.min(pixel);maximum=maximum.max(pixel)
				minimum_depth=minf(minimum_depth,depth);maximum_depth=maxf(maximum_depth,depth)
	var size:=get_viewport().get_visible_rect().size
	return {"bounds_px":[minimum.x,minimum.y,maximum.x,maximum.y],"bounds_uv":[minimum.x/size.x,minimum.y/size.y,maximum.x/size.x,maximum.y/size.y],"width_px":maximum.x-minimum.x,"height_px":maximum.y-minimum.y,"height_fraction":(maximum.y-minimum.y)/size.y,"camera_depth_range_u":[minimum_depth,maximum_depth]}

func composition_evidence() -> Dictionary:
	var camera_forward:Vector3=-camera.global_basis.z
	var horizon:=camera.unproject_position(camera.global_position+Vector3(camera_forward.x,0.0,camera_forward.z).normalized()*1000.0)
	var sun_direction:Vector3=sun.global_basis.z
	var sun_pixel:=camera.unproject_position(camera.global_position+sun_direction*1000.0)
	var size:=get_viewport().get_visible_rect().size
	var sun_radius_deg:float=float(look_profile.recipe.sky.get("sun_radius_deg",1.08))
	var sun_edge:Vector3=(sun_direction+camera.global_basis.x*tan(deg_to_rad(sun_radius_deg))).normalized()
	var sun_radius_px:=sun_pixel.distance_to(camera.unproject_position(camera.global_position+sun_edge*1000.0))
	return {"horizon_y_uv":horizon.y/size.y,"sun_center_uv":[sun_pixel.x/size.x,sun_pixel.y/size.y],"sun_radius_px_projected":sun_radius_px,"camera_elevation_deg":rad_to_deg(asin(camera_forward.y)),"character":projected_bounds(character_body,character_geometry),"tree":projected_bounds(tree),"arch":projected_bounds(arch)}

func capture(output_path:String) -> void:
	for i in 120:await RenderingServer.frame_post_draw
	var samples:Array[float]=[]
	var previous:=Time.get_ticks_usec()
	for i in 180:
		await RenderingServer.frame_post_draw
		var now:=Time.get_ticks_usec();samples.append(float(now-previous)/1000.0);previous=now
	var sorted:=samples.duplicate();sorted.sort()
	var draw_calls:=RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var viewport_calls:=get_viewport().get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var primitives:=RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var image:=get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var error:=image.save_png(output_path)
	var report:Dictionary={"schema":"silkroad.baghdad-composition.v1","stage":settings.stage,"view":selected,"lighting_period":lighting_period,"studio_mode":studio_mode,"cinematic_sunset":cinematic_sunset,"renderer":RenderingServer.get_current_rendering_method(),"image_size":[image.get_width(),image.get_height()],"viewport_size":[get_viewport().get_visible_rect().size.x,get_viewport().get_visible_rect().size.y],"capture_error":error,"draw_calls":draw_calls,"viewport_draw_calls":viewport_calls,"rendered_primitives":primitives,"frame_ms":{"p50":sorted[89],"p95":sorted[170],"samples":samples,"sample_count":180,"warmup_frames":120,"vsync_disabled":DisplayServer.window_get_vsync_mode()==DisplayServer.VSYNC_DISABLED,"engine_max_fps":Engine.max_fps},"camera":camera_params,"camera_transform":str(camera.global_transform),"look":look_profile.evidence(image),"render_style":world.get_meta("lowpoly_materials",{}),"layout":settings,"composition":composition_evidence(),"character_style":character_style.evidence(),"assets":asset_records,"placement":layout_records,"scope":{"static_sunset_only":not studio_mode and not cinematic_sunset,"studio_mode":studio_mode,"cinematic_sunset":cinematic_sunset,"motion":false,"interaction":false,"original_main_assets_no_decimation":true}}
	report["character_style"]["outline_width_multiplier"]=float(settings.character.get("outline_width_multiplier",1.0))
	report["character_style"]["effective_outline_grow_amount_model_u"]=float(character_style.shells[0].material_override.grow_amount)
	var active_storm:=get_node_or_null("BaghdadStormLook")
	if active_storm!=null and active_storm.has_method("evidence"):
		report["base_look"]=report["look"]
		report["look"]=active_storm.evidence()
		report["lighting_period"]="storm-cloudbreak"
		report["scope"]["static_sunset_only"]=false
		report["scope"]["static_storm_cloudbreak"]=true
	if ground_builder!=null and ground_builder.has_method("evidence"):report["terrain"]=ground_builder.evidence()
	if supporting_props!=null and supporting_props.has_method("evidence"):report["supporting_props"]=supporting_props.evidence()
	if mountain_layer!=null and mountain_layer.has_method("evidence"):report["mountains"]=mountain_layer.evidence()
	FileAccess.open(output_path.trim_suffix(".png")+".json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("BAGHDAD_CAPTURE ",JSON.stringify({"image_size":report.image_size,"draw_calls":draw_calls,"viewport_draw_calls":viewport_calls,"p50":sorted[89],"p95":sorted[170],"composition":report.composition}))
	if error!=OK:push_error("Baghdad capture save failed: "+output_path)

func vector_array(value:Vector3) -> Array:
	return [value.x,value.y,value.z]
