extends SceneTree
## S0 read-only asset/wiring audit and transient raster diagnostic. Never saves scene resources.
## Required: --view=changan --day --far --grass-output=<new report directory>.
var viewport: SubViewport
var viewer: Node3D
var output := ""
var grass: MultiMeshInstance3D
var source_material: ShaderMaterial
var source_mm: MultiMesh
var audit := {}
var tip := Vector3.ZERO
var roi := Rect2i(0,0,300,300)

func _initialize() -> void:
	call_deferred("run")

func vec(v: Vector3) -> Array:
	return [v.x,v.y,v.z]

func write_json(path: String, value: Variant) -> void:
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:
		push_error("Cannot write grass evidence: "+path)
		quit(1)
		return
	file.store_string(JSON.stringify(value,"\t"))
	file.close()

func trajectory(instance: int) -> Array:
	var transform := grass.global_transform*source_mm.get_instance_transform(instance)
	var custom := source_mm.get_instance_custom_data(instance)
	var phase := transform.origin.x*0.72+transform.origin.z*0.63+custom.r*TAU
	var amp := float(source_material.get_shader_parameter("wind_amp"))
	var stiff := float(source_material.get_shader_parameter("wind_stiff"))
	var neutral: Vector2 = viewer.camera.unproject_position(transform*tip)
	var trace: Array = []
	for second in 61:
		var t := float(second)
		var gust: float = 1.0+(viewer.motion_director.gust(t)-1.0)*(custom.b if custom.b>0.0 else 1.0)
		var move := (sin(t*1.1+phase)+0.4*sin(t*1.8+phase*1.6))*amp*(custom.g if custom.g>0.0 else 1.0)*gust*pow(tip.y,stiff)
		var position: Vector2 = viewer.camera.unproject_position(transform*(tip+Vector3(1,0,0.38)*move))
		trace.append({"time_s":second,"screen_px":[position.x,position.y],"displacement_from_neutral_px":position.distance_to(neutral),"local_move":move})
	return trace

func make_diagnostic_material(tip_only: bool) -> ShaderMaterial:
	var material := source_material.duplicate() as ShaderMaterial
	var shader := Shader.new()
	var code := FileAccess.get_file_as_string("res://shaders/traveler/atlas_surface.gdshader")
	code=code.substr(0,code.find("void fragment()"))
	code=code.replace("render_mode cull_disabled, diffuse_lambert_wrap;","render_mode cull_disabled, unshaded, fog_disabled;")
	code=code.replace("void vertex() {","varying float grass_local_y;\nvoid vertex() {\n grass_local_y=VERTEX.y;")
	code+="\nvoid fragment(){"
	if tip_only: code+="if(grass_local_y<%f) discard;" % (tip.y*0.75)
	code+="ALBEDO=vec3(1.0);}\n"
	shader.code=code
	material.shader=shader
	return material

func diagnostic_environment() -> void:
	var black := StandardMaterial3D.new()
	black.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color=Color.BLACK
	black.cull_mode=BaseMaterial3D.CULL_DISABLED
	for node in viewer.world.find_children("*","GeometryInstance3D",true,false):
		if node!=grass:node.material_override=black
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

func densest_crop(image: Image) -> Dictionary:
	var w := image.get_width()
	var h := image.get_height()
	var stride := w+1
	var sums := PackedInt32Array()
	sums.resize(stride*(h+1))
	for y in h:
		var line_sum := 0
		for x in w:
			if image.get_pixel(x,y).r>=0.5:line_sum+=1
			sums[(y+1)*stride+x+1]=sums[y*stride+x+1]+line_sum
	var best := -1
	var origin := Vector2i.ZERO
	for y in range(h-300+1):
		for x in range(w-300+1):
			var count := sums[(y+300)*stride+x+300]-sums[y*stride+x+300]-sums[(y+300)*stride+x]+sums[y*stride+x]
			if count>best:
				best=count
				origin=Vector2i(x,y)
	return {"rect":Rect2i(origin,Vector2i(300,300)),"white_pixels":best}

func raster_measure(image: Image) -> Dictionary:
	var weight := 0.0
	var center := Vector2.ZERO
	var count := 0
	for y in range(roi.position.y,roi.end.y):
		for x in range(roi.position.x,roi.end.x):
			var value := image.get_pixel(x,y).r
			if value<=0.01:continue
			weight+=value
			center+=Vector2(x+0.5,y+0.5)*value
			if value>=0.5:count+=1
	if weight>0.0:center/=weight
	return {"centroid_px":[center.x,center.y],"weight":weight,"pixels_above_half":count}

func settle() -> void:
	for frame in 4:
		await process_frame
		await RenderingServer.frame_post_draw

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--grass-output="):output=arg.trim_prefix("--grass-output=")
	if output.is_empty():
		push_error("Required --grass-output=<new report directory>; no legacy path defaults")
		quit(1)
		return
	if DisplayServer.get_name()=="headless":
		push_error("Grass raster evidence requires the real renderer")
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
	assert(viewer.selected=="changan" and viewer.look_on,"Use --view=changan --day --far")
	viewer.ui.visible=false
	viewer.set_process(false)
	viewer.set_process_unhandled_input(false)
	viewer.camera.make_current()
	viewer.motion_director.externally_clocked=true
	viewer.motion_director.set_active_items(["wind"])
	viewer.motion_director.apply_time(0.0)
	Engine.max_fps=0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for material in viewer.material_list:
		if material.shader.resource_path.ends_with("atlas_water.gdshader"):material.set_shader_parameter("anim_t",0.0)
	grass=viewer.world.get_node("NaturalDetails/Grass")
	source_mm=grass.multimesh
	source_material=grass.material_override
	var director_index: int=viewer.motion_director.wind_materials.find(source_material)
	var custom_range := {"r":[INF,-INF],"g":[INF,-INF],"b":[INF,-INF]}
	for i in source_mm.instance_count:
		var custom := source_mm.get_instance_custom_data(i)
		for key in ["r","g","b"]:
			custom_range[key][0]=minf(custom_range[key][0],custom[key])
			custom_range[key][1]=maxf(custom_range[key][1],custom[key])
	for surface in source_mm.mesh.get_surface_count():
		var vertices: PackedVector3Array=source_mm.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for vertex in vertices:
			if vertex.y>tip.y:tip=vertex
	audit={"schema":"traveler.s0.grass-diagnostic.v1","diagnostic_only":true,"image_size":[1920,1080],"viewport_size":[1920,1080],"grass_node":str(grass.get_path()),"source_multimesh":source_mm.resource_path,"material":source_material.resource_name,"shader":source_material.shader.resource_path,"material_registered":director_index>=0,"director_index":director_index,"director_original_amplitude":viewer.motion_director.original_amplitudes[director_index] if director_index>=0 else null,"wind_amp":source_material.get_shader_parameter("wind_amp"),"wind_stiff":source_material.get_shader_parameter("wind_stiff"),"use_custom_data":source_mm.use_custom_data,"custom_data_ranges":custom_range,"instance_count":source_mm.instance_count,"highest_mesh_vertex":vec(tip),"mesh_aabb":{"position":vec(source_mm.mesh.get_aabb().position),"size":vec(source_mm.mesh.get_aabb().size)},"camera":viewer.motion_params._measured.traveler_camera,"camera_position":vec(viewer.camera.position),"method":"Only in-memory diagnostic rendering changes: original geometry/camera/depth occlusion and DOF retained; all occluders black, grass white unshaded, fog/glow/AO/color adjustments disabled. Tip centroids use upper 25% local height. No scene/asset/material resource is saved."}
	diagnostic_environment()
	var mask_material := make_diagnostic_material(false)
	grass.material_override=mask_material
	await settle()
	var mask := viewport.get_texture().get_image()
	mask.save_png(output+"/grass-depth-mask.png")
	var crop := densest_crop(mask)
	roi=crop.rect
	audit["crop_xywh"]=[roi.position.x,roi.position.y,300,300]
	audit["crop_selection"]="Exact exhaustive 300x300 window maximizing depth-tested grass-mask pixels >=0.5 at t=0; earliest y/x breaks ties."
	audit["crop_white_pixels"]=crop.white_pixels
	mask.get_region(roi).save_png(output+"/grass-depth-mask-crop.png")
	var chosen := -1
	var best := -1.0
	var candidates: Array=[]
	for i in source_mm.instance_count:
		var transform := grass.global_transform*source_mm.get_instance_transform(i)
		var world_tip := transform*tip
		if viewer.camera.is_position_behind(world_tip):continue
		var screen: Vector2=viewer.camera.unproject_position(world_tip)
		if not Rect2(roi).grow(-12).has_point(screen):continue
		var found := false
		for dy in range(-8,9):
			for dx in range(-8,9):
				if mask.get_pixel(clampi(int(screen.x)+dx,0,1919),clampi(int(screen.y)+dy,0,1079)).r>=0.5:found=true
		if not found:continue
		var trace := trajectory(i)
		var amplitude := 0.0
		for record in trace:amplitude=maxf(amplitude,record.displacement_from_neutral_px)
		candidates.append({"instance":i,"predicted_peak_displacement_px":amplitude,"neutral_tip_screen":[screen.x,screen.y],"camera_depth":-((viewer.camera.global_transform.affine_inverse()*world_tip).z)})
		if amplitude>best:best=amplitude;chosen=i
	audit["crop_candidates"]=candidates
	if chosen<0:
		audit["raster_error"]="No projectable tip candidate in densest visible crop"
		write_json(output+"/grass-audit.json",audit)
		push_error("No grass tip candidate in crop")
		quit(1)
		return
	var transform := source_mm.get_instance_transform(chosen)
	var custom := source_mm.get_instance_custom_data(chosen)
	var instance_color := source_mm.get_instance_color(chosen)
	var diagnostic_mm := source_mm.duplicate() as MultiMesh
	diagnostic_mm.instance_count=1
	diagnostic_mm.set_instance_transform(0,transform)
	diagnostic_mm.set_instance_custom_data(0,custom)
	diagnostic_mm.set_instance_color(0,instance_color)
	grass.multimesh=diagnostic_mm
	var tip_material := make_diagnostic_material(true)
	grass.material_override=tip_material
	var trace := trajectory(chosen)
	audit["selected_instance"]={"index":chosen,"transform_origin":vec(transform.origin),"scale":vec(transform.basis.get_scale()),"custom":[custom.r,custom.g,custom.b,custom.a],"trace":trace}
	var raster: Array=[]
	var crops: Array[Image]=[]
	for second in 61:
		tip_material.set_shader_parameter("anim_t",float(second))
		tip_material.set_shader_parameter("wind_gust",viewer.motion_director.gust(float(second)))
		await settle()
		var image := viewport.get_texture().get_image()
		var measured := raster_measure(image)
		measured["time_s"]=second
		raster.append(measured)
		crops.append(image.get_region(roi))
	var peak := 0.0
	var peak_pair := [0,0]
	for a in raster.size():
		if raster[a].weight<=0.0:continue
		for b in range(a+1,raster.size()):
			if raster[b].weight<=0.0:continue
			var ca: Array=raster[a].centroid_px
			var cb: Array=raster[b].centroid_px
			var displacement := Vector2(ca[0],ca[1]).distance_to(Vector2(cb[0],cb[1]))
			if displacement>peak:peak=displacement;peak_pair=[a,b]
	for index in peak_pair:crops[index].save_png(output+"/grass-tip-diagnostic-t%02d.png" % index)
	audit["raster_tip_centroids"]=raster
	audit["raster_peak_to_peak_displacement_px"]=peak
	audit["raster_peak_pair_seconds"]=peak_pair
	audit["raster_caution"]="This is raster displacement of a depth-tested upper-tip area centroid, not a mathematical single vertex. Defocus/coverage/occlusion can bias it. The full original-frame crop change rates are measured separately from unaltered S0 A/B PNGs."
	write_json(output+"/grass-audit.json",audit)
	print("GRASS_AUDIT ",JSON.stringify({"registered":director_index>=0,"use_custom_data":source_mm.use_custom_data,"crop_xywh":audit.crop_xywh,"instance":chosen,"raster_peak_to_peak_displacement_px":peak}))
	viewer.queue_free()
	await process_frame
	await process_frame
	quit()
