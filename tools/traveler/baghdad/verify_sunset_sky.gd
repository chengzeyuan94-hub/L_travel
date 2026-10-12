extends SceneTree
## Small isolated shader compile / appearance check; does not load the Baghdad scene.
var output_path:=""
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):output_path=arg.trim_prefix("--out=")
	assert(not output_path.is_empty(),"Pass --out=<new absolute PNG path>")
	call_deferred("run")

func run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED);Engine.max_fps=0
	var recipe:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/look_presets.json")).scenes.baghdad.sunset
	var theme:Dictionary=recipe.sky
	var vp:=SubViewport.new();vp.size=Vector2i(640,360);vp.own_world_3d=true;vp.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(vp)
	var env:=Environment.new();env.background_mode=Environment.BG_SKY
	env.tonemap_mode=Environment.TONE_MAPPER_AGX;env.tonemap_exposure=float(recipe.params.exp);env.tonemap_white=float(recipe.params.white)
	env.adjustment_enabled=true;env.adjustment_saturation=float(recipe.params.sat);env.adjustment_contrast=float(recipe.params.con)
	var sky:=Sky.new();var material:=ShaderMaterial.new()
	material.shader=load("res://shaders/traveler/baghdad/baghdad_sunset_sky.gdshader")
	for pair in [["zenith_color","top"],["horizon_color","horizon"],["ground_bottom_color","ground_bottom"],["ground_horizon_color","ground_horizon"],["sun_disc_color","sun_disc_color"],["cloud_color","cloud_color"]]:
		var color:Array=theme[pair[1]];material.set_shader_parameter(pair[0],Color(color[0],color[1],color[2]))
	for key in ["horizon_falloff","sky_energy","sun_disc_energy","sun_radius_deg","sun_edge_deg","sun_halo_radius_deg","sun_halo_strength","cloud_opacity","cloud_seed","cloud_coverage"]:
		material.set_shader_parameter(key,float(theme[key]))
	var light_rotation:=Vector3(deg_to_rad(float(recipe.params.sunel)),deg_to_rad(float(recipe.params.sunaz)),0.0)
	material.set_shader_parameter("sun_direction",Basis.from_euler(light_rotation).z.normalized())
	sky.sky_material=material;env.sky=sky
	var we:=WorldEnvironment.new();we.environment=env;vp.add_child(we)
	var cam:=Camera3D.new();vp.add_child(cam);cam.fov=40.0;cam.keep_aspect=Camera3D.KEEP_HEIGHT
	cam.look_at(Vector3(0,tan(deg_to_rad(10.43)),1));cam.make_current()
	for i in 20:await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var image:=vp.get_texture().get_image();var error:=image.save_png(output_path)
	print("BAGHDAD_SUNSET_SKY_CHECK ",JSON.stringify({"image_size":[640,360],"save_error":error,"static":true,"sun_radius_deg":theme.sun_radius_deg,"full_scene_loaded":false}))
	quit(error)
