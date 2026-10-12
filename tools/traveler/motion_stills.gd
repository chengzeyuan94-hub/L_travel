extends SceneTree
## Paired exact-time diagnostic and CP1 capture. No camera edits.
var viewport: SubViewport
var viewer: Node3D
var prefix := "res://docs/reports/traveler-motion-001/S2"
var preset := "recommended"
var movie_frames := 0
var probe := false
var probe_part := "canopy"
var times := [0.0,1.43]
var selected_batch := "T48_gold_detail"
var selected_instance := 6
var measurements: Array = []

func _initialize() -> void:
	call_deferred("run")

func save_image(index: int, at_time: float) -> void:
	var img := viewport.get_texture().get_image()
	var path := "%s-%04d.png" % [prefix,index]
	var err := img.save_png(path)
	var file := FileAccess.open(path.trim_suffix(".png")+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"image_size":[img.get_width(),img.get_height()],"viewport_size":[viewport.size.x,viewport.size.y],"capture_error":err,"time_s":at_time,"preset":preset,"frozen_camera":viewer.motion_params._measured.traveler_camera,"probe":probe,"probe_part":probe_part,"look":viewer.look_profile.evidence(img)},"\t"));file.close()
	if err!=OK:push_error("Cannot save "+path)

func configure_probe() -> void:
	# Isolate the same actual instance, retaining its transform and all vertices.
	# Diagnostic flat colors identify crown/trunk top regions in the same crop.
	var batch: MultiMeshInstance3D = viewer.world.get_node("VegetationHigh/"+selected_batch)
	var mm := batch.multimesh.duplicate() as MultiMesh
	var transform := mm.get_instance_transform(selected_instance)
	var custom := mm.get_instance_custom_data(selected_instance)
	# Evaluate the actual selected-instance trajectory without moving the camera.
	var trajectory: Array = []
	var basis:=transform.basis
	var phase:=transform.origin.x*0.72+transform.origin.z*0.63+custom.r*TAU
	for frame in 1801:
		var t:=float(frame)/30.0
		var gust:float=1.0+(viewer.motion_director.gust(t)-1.0)*custom.b
		var movement:float=(sin(t*1.1+phase)+0.4*sin(t*1.8+phase*1.6))*0.017*custom.g*gust
		var tip:=Vector3(0,1.65086424350739,0)
		tip+=Vector3(1,0,0.38)*movement*pow(tip.y,1.6)
		var projected:Vector2=viewer.camera.unproject_position(transform*tip)
		trajectory.append({"time_s":t,"screen_x":projected.x,"world_move":movement})
	var trace:=FileAccess.open(prefix+"-trajectory.json",FileAccess.WRITE)
	trace.store_string(JSON.stringify(trajectory));trace.close()
	var color := mm.get_instance_color(selected_instance)
	mm.instance_count=1
	mm.set_instance_transform(0,transform)
	mm.set_instance_custom_data(0,custom)
	mm.set_instance_color(0,color)
	mm.mesh=mm.mesh.duplicate()
	batch.multimesh=mm
	for node in viewer.world.find_children("*","GeometryInstance3D",true,false):
		node.visible=node==batch
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
	var materials: Array[ShaderMaterial] = []
	var geometry: Array = []
	for surface in mm.mesh.get_surface_count():
		var original: ShaderMaterial = mm.mesh.surface_get_material(surface)
		var material := original.duplicate() as ShaderMaterial
		var vertices: PackedVector3Array = mm.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		var top := -INF
		for vertex in vertices:top=maxf(top,vertex.y)
		var shader := Shader.new()
		var code: String = FileAccess.get_file_as_string("res://shaders/traveler/atlas_surface.gdshader")
		code=code.substr(0,code.find("void fragment()"))
		code=code.replace("render_mode cull_disabled, diffuse_lambert_wrap;","render_mode cull_disabled, unshaded, fog_disabled;")
		code=code.replace("void vertex() {","varying float local_height;\nvarying vec3 vertex_color;\nvoid vertex() {\n local_height=VERTEX.y; vertex_color=COLOR.rgb;")
		# Actual brown branch/trunk vertices are in Atlas_plants. Atlas_trunk is
		# the exposed-root surface (max y=.08), not the upper stem.
		var brown_top := 1.48815965652466
		var condition := "vertex_color.r < 0.20 && vertex_color.g < 0.10"
		if original.resource_name!="Atlas_plants":
			code+="\nvoid fragment(){discard;}"
		elif probe_part=="trunk":
			code+="\nvoid fragment(){if(!(%s) || local_height<%f) discard; ALBEDO=vec3(0,1,0);}" % [condition,brown_top*0.9]
		else:
			var cutoff := 0.0 if probe_part=="crown" else top*0.9
			code+="\nvoid fragment(){if((%s) || local_height<%f) discard; ALBEDO=vec3(1,0,0);}" % [condition,cutoff]
		shader.code=code;material.shader=shader
		mm.mesh.surface_set_material(surface,material);materials.append(material)
		var colors: PackedColorArray = mm.mesh.surface_get_arrays(surface)[Mesh.ARRAY_COLOR]
		var groups := {}
		for vi in vertices.size():
			var key := colors[vi].to_html(false)
			if not groups.has(key):groups[key]={"min_y":vertices[vi].y,"max_y":vertices[vi].y,"count":0,"rgb":[colors[vi].r,colors[vi].g,colors[vi].b]}
			groups[key].min_y=minf(float(groups[key].min_y),vertices[vi].y)
			groups[key].max_y=maxf(float(groups[key].max_y),vertices[vi].y)
			groups[key].count+=1
		geometry.append({"vertex_colors":groups,"material":original.resource_name,"top_local_y":top,"wind_amp":original.get_shader_parameter("wind_amp"),"wind_stiff":original.get_shader_parameter("wind_stiff")})
	viewer.motion_director.wind_materials.clear()
	viewer.motion_director.original_amplitudes.clear()
	for material in materials:
		viewer.motion_director.wind_materials.append(material)
		viewer.motion_director.original_amplitudes.append(float(material.get_shader_parameter("wind_amp")))
	var file := FileAccess.open(prefix+"-geometry.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"batch":selected_batch,"instance":selected_instance,"surfaces":geometry,"origin":[transform.origin.x,transform.origin.y,transform.origin.z],"scale":transform.basis.get_scale().x,"custom":[custom.r,custom.g,custom.b,custom.a]},"\t"));file.close()

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--still-prefix="):prefix=arg.trim_prefix("--still-prefix=")
		if arg.begins_with("--wind-preset="):preset=arg.trim_prefix("--wind-preset=")
		if arg.begins_with("--movie-frames="):movie_frames=int(arg.trim_prefix("--movie-frames="))
		if arg=="--probe-tree":probe=true
		if arg.begins_with("--probe-part="):probe_part=arg.trim_prefix("--probe-part=")
		if arg.begins_with("--still-times="):
			times=[]
			for value in arg.trim_prefix("--still-times=").split(","):times.append(float(value))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(prefix.get_base_dir()))
	viewport=SubViewport.new();viewport.size=Vector2i(1920,1080);viewport.own_world_3d=true
	viewport.msaa_3d=Viewport.MSAA_4X;viewport.use_taa=false;viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	viewer=load("res://scenes/traveler/traveler_main.tscn").instantiate();viewport.add_child(viewer)
	viewer.ui.visible=false;viewer.set_process(false);viewer.set_process_unhandled_input(false)
	viewer.camera.make_current();viewer.motion_director.externally_clocked=true
	for material in viewer.material_list:
		if material.shader.resource_path.ends_with("atlas_water.gdshader"):material.set_shader_parameter("anim_t",0.0)
	if preset=="zero":viewer.motion_director.set_wind_enabled(false)
	if preset=="strong":
		for index in viewer.motion_director.wind_materials.size():
			if viewer.motion_director.wind_materials[index].resource_name in ["Atlas_plants","Atlas_trunk"]:
				viewer.motion_director.original_amplitudes[index]=0.024
	if preset=="legacy":
		var shader:=Shader.new()
		var code:=FileAccess.get_file_as_string("res://docs/design/shanhe-luren/lookdev/recipe/atlas_surface-lookdev.gdshader")
		shader.code=code.replace("TIME","anim_t").replace("void vertex()", "uniform float anim_t=0.0;\nvoid vertex()")
		for material in viewer.motion_director.wind_materials:
			material.shader=shader
			var strength:=0.0
			if material.resource_name in ["Atlas_plants","Atlas_cypress","Atlas_bush"]:strength=0.014
			if material.resource_name=="Atlas_grass":strength=0.02
			if material.resource_name=="Atlas_city_plants":strength=0.005
			material.set_shader_parameter("wind_strength",strength)
	if probe:configure_probe()
	if movie_frames>0:
		viewer.motion_director.apply_time(0.0)
		for warmup in 60:
			await process_frame
			await RenderingServer.frame_post_draw
		for frame in movie_frames:
			var t:=float(frame)/30.0
			await process_frame
			viewer.motion_director.apply_time(t)
			await RenderingServer.frame_post_draw
			save_image(frame,t)
	else:
		for index in times.size():
			viewer.motion_director.apply_time(float(times[index]))
			for warmup in 60:
				await process_frame
				await RenderingServer.frame_post_draw
			save_image(index,float(times[index]))
	print("MOTION_STILLS ",JSON.stringify({"preset":preset,"probe":probe,"frames":movie_frames if movie_frames>0 else times.size()}))
	viewer.queue_free()
	await process_frame
	await process_frame
	quit()
