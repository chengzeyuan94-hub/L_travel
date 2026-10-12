extends RefCounted
## Independent sunset recipe: no Changan fallback, transition or night effects.
var viewer:Node3D
var preset_id:="baghdad/sunset"
var recipe:Dictionary={}
var sky:Sky
var sky_material:ShaderMaterial

func configure(host:Node3D) -> void:
	viewer=host
	var scene_settings:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/baghdad_scene.json"))
	if bool(viewer.get("studio_mode")):
		_configure_studio(scene_settings)
		return
	var requested_period:=str(scene_settings.get("default_period","sunset"))
	if bool(viewer.get("cinematic_sunset")):
		recipe=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/baghdad_cinematic_sunset.json"))
		preset_id=str(recipe.get("preset", "baghdad/cinematic-sunset"))
	elif requested_period=="noon" and FileAccess.file_exists("res://data/traveler/baghdad_noon_preset.json"):
		recipe=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/baghdad_noon_preset.json"))
	else:
		var presets:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/look_presets.json"))
		assert(presets.scenes.has("baghdad") and presets.scenes.baghdad.has("sunset"),"Missing Baghdad sunset look preset")
		recipe=presets.scenes.baghdad.sunset.duplicate(true)
	preset_id=str(recipe.get("preset",preset_id))
	var p:Dictionary=recipe.params
	var theme:Dictionary=recipe.sky
	var env:Environment=viewer.environment
	var light:DirectionalLight3D=viewer.sun
	sky=Sky.new();sky_material=ShaderMaterial.new()
	sky_material.shader=load("res://shaders/traveler/baghdad/baghdad_sunset_sky.gdshader")
	sky_material.set_shader_parameter("zenith_color",rgb(theme.top))
	sky_material.set_shader_parameter("horizon_color",rgb(theme.horizon))
	sky_material.set_shader_parameter("ground_bottom_color",rgb(theme.ground_bottom))
	sky_material.set_shader_parameter("ground_horizon_color",rgb(theme.ground_horizon))
	for key in ["sun_disc_color","cloud_color"]:
		sky_material.set_shader_parameter(key,rgb(theme[key]))
	for key in ["horizon_falloff","sky_energy","sun_disc_energy","sun_radius_deg","sun_edge_deg","sun_halo_radius_deg","sun_halo_strength","cloud_opacity","cloud_seed","cloud_coverage"]:
		sky_material.set_shader_parameter(key,float(theme[key]))
	sky.sky_material=sky_material
	env.background_mode=Environment.BG_SKY;env.sky=sky
	if p.has("ambient_fill_color"):
		var fill:Array=p.ambient_fill_color
		env.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color=Color(float(fill[0]),float(fill[1]),float(fill[2]))
		env.ambient_light_energy=float(p.get("ambient_fill_energy",p.amb))
	else:
		env.ambient_light_source=Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution=1.0;env.ambient_light_energy=float(p.amb)
	env.reflected_light_source=Environment.REFLECTION_SOURCE_SKY
	var RG := preload("res://scripts/traveler/render_globals.gd")     # Mobile 渲染器没有的效果不开（TS-9）
	env.ssao_enabled=RG.env_feature("ssao");env.ssao_radius=float(p.ao);env.ssao_intensity=float(p.aoi)
	env.ssao_power=1.6;env.ssao_detail=0.6;env.ssao_light_affect=0.18
	env.ssil_enabled=float(p.ssili)>0.0 and RG.env_feature("ssil");env.ssil_radius=float(p.ssil);env.ssil_intensity=float(p.ssili)
	# Runtime global illumination for the Forward+ Baghdad preview. Static meshes
	# use their default STATIC GI mode; particles explicitly opt out in their
	# own builders. Keep the field data-driven so this scene can be tuned without
	# touching the frozen composition or project renderer settings.
	env.sdfgi_enabled=bool(p.get("sdfgi_enabled",false)) and RG.env_feature("sdfgi")
	if env.sdfgi_enabled:
		env.sdfgi_read_sky_light=bool(p.get("sdfgi_read_sky_light",true))
		env.sdfgi_use_occlusion=bool(p.get("sdfgi_use_occlusion",true))
		env.sdfgi_cascades=clampi(int(p.get("sdfgi_cascades",4)),1,4)
		env.sdfgi_min_cell_size=maxf(float(p.get("sdfgi_min_cell_size",0.5)),0.1)
		env.sdfgi_max_distance=maxf(float(p.get("sdfgi_max_distance",64.0)),8.0)
		env.sdfgi_y_scale=clampi(int(p.get("sdfgi_y_scale",2)),0,2)
		env.sdfgi_energy=maxf(float(p.get("sdfgi_energy",0.7)),0.0)
		env.sdfgi_bounce_feedback=clampf(float(p.get("sdfgi_bounce_feedback",0.7)),0.0,1.0)
		env.sdfgi_normal_bias=maxf(float(p.get("sdfgi_normal_bias",1.1)),0.0)
		env.sdfgi_probe_bias=maxf(float(p.get("sdfgi_probe_bias",1.1)),0.0)
	env.glow_enabled=true;env.glow_intensity=float(p.glow);env.glow_bloom=0.15
	env.glow_blend_mode=Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.tonemap_mode=Environment.TONE_MAPPER_AGX;env.tonemap_exposure=float(p.exp);env.tonemap_white=float(p.white)
	env.adjustment_enabled=true;env.adjustment_saturation=float(p.sat);env.adjustment_contrast=float(p.con)
	env.volumetric_fog_enabled=false;env.fog_enabled=true;env.fog_mode=Environment.FOG_MODE_DEPTH
	env.fog_light_color=rgb(theme.fog_color);env.fog_density=float(p.fogd)
	env.fog_depth_begin=float(p.fogb);env.fog_depth_end=float(p.foge);env.fog_depth_curve=1.35
	env.fog_sky_affect=0.0;env.fog_aerial_perspective=float(p.aerial)
	light.light_color=rgb(theme.sun_color);light.light_energy=float(p.sun)
	light.light_angular_distance=float(p.ang);light.shadow_enabled=true
	light.shadow_blur=float(p.sblur);light.shadow_bias=float(p.bias);light.shadow_normal_bias=float(p.nbias)
	light.directional_shadow_mode=DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	light.directional_shadow_split_1=0.15;light.directional_shadow_max_distance=float(p.shmax)
	light.rotation=Vector3(deg_to_rad(float(p.sunel)),deg_to_rad(float(p.sunaz)),0.0)
	sky_material.set_shader_parameter("sun_direction",light.global_basis.z.normalized())
	preload("res://scripts/traveler/render_globals.gd").shadow_atlas(int(p.get("shadow_atlas_size",4096)),true)
	if float(p.dof)>0.0:
		var attributes:=CameraAttributesPractical.new()
		attributes.dof_blur_far_enabled=true;attributes.dof_blur_far_distance=float(p.dof)
		attributes.dof_blur_far_transition=float(p.get("dof_transition",float(p.dof)*0.55))
		attributes.dof_blur_amount=float(p.blur);viewer.camera.attributes=attributes
	if bool(p.get("cinematic_character_fill",false)):
		_add_cinematic_character_fill(viewer, p)
	if bool(p.get("cinematic_cool_fill",false)):
		_add_cinematic_cool_fill(viewer, p)
	var vp:Viewport=viewer.get_viewport()
	vp.msaa_3d=Viewport.MSAA_4X;vp.screen_space_aa=Viewport.SCREEN_SPACE_AA_DISABLED;vp.use_taa=false

func _add_cinematic_character_fill(host:Node3D, p:Dictionary) -> void:
	# A restrained local key keeps the traveler readable in the arch shadow. It
	# is deliberately separate from the sunset sun and does not affect baking.
	var fill:=SpotLight3D.new()
	fill.name="CinematicTravelerFill"
	fill.light_color=rgb(p.get("character_fill_color",[1.0,0.72,0.48]))
	fill.light_energy=float(p.get("character_fill_energy",0.32))
	fill.spot_range=float(p.get("character_fill_range",4.5))
	fill.spot_angle=float(p.get("character_fill_angle",42.0))
	fill.spot_angle_attenuation=1.6
	fill.shadow_enabled=false
	fill.light_specular=0.0
	fill.position=host.stage_point(Vector3(-1.35,1.65,3.0))
	fill.look_at_from_position(fill.position,host.stage_point(Vector3(-0.47,0.30,1.75)),Vector3.UP)
	host.add_child(fill)

func _add_cinematic_cool_fill(host:Node3D, p:Dictionary) -> void:
	# Broad, shadowless sky fill keeps the green canopy and cool stone readable
	# while the warm key still defines the direction and contact shadows.
	var fill:=DirectionalLight3D.new()
	fill.name="CinematicCoolSkyFill"
	fill.light_color=rgb(p.get("cinematic_cool_fill_color",[0.48,0.58,0.82]))
	fill.light_energy=float(p.get("cinematic_cool_fill_energy",0.65))
	fill.shadow_enabled=false
	fill.light_specular=0.0
	fill.rotation=Vector3(deg_to_rad(-24.0),deg_to_rad(165.0),0.0)
	host.add_child(fill)

func _configure_studio(scene_settings:Dictionary) -> void:
	var config:Dictionary=scene_settings.get("studio_render",{})
	preset_id="baghdad/studio"
	var bg:Array=config.get("background_color",[0.88,0.86,0.82])
	var ambient:Array=config.get("ambient_color",[0.77,0.80,0.84])
	var key_color:Array=config.get("key_color",[1.0,0.96,0.87])
	var fill_color:Array=config.get("fill_color",[0.78,0.86,1.0])
	var rim_color:Array=config.get("rim_color",[1.0,0.66,0.42])
	var p:Dictionary={"studio":true,"ambient_energy":float(config.get("ambient_energy",0.42)),"ao":float(config.get("ssao_radius",0.30)),"aoi":float(config.get("ssao_intensity",1.0)),"ssil":0.0,"ssili":0.0,"sdfgi_enabled":true,"sdfgi_energy":float(config.get("sdfgi_energy",0.6)),"sdfgi_bounce_feedback":float(config.get("sdfgi_bounce_feedback",0.7)),"dof":float(config.get("dof",12.0)),"dof_transition":float(config.get("dof_transition",8.0)),"exposure":float(config.get("exposure",1.0)),"lowpoly_materials":true,"lowpoly_roughness":0.86,"lowpoly_specular_disabled":true,"tree_albedo_boost":1.4,"tree_emission_enabled":true,"tree_emission_color":[0.025,0.09,0.012],"tree_emission_energy":1.0}
	recipe={"preset":preset_id,"params":p,"sky":{"background_color":bg,"ambient_color":ambient,"key_color":key_color}}
	var env:Environment=viewer.environment
	env.background_mode=Environment.BG_COLOR
	env.background_color=rgb(bg)
	env.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color=rgb(ambient)
	env.ambient_light_energy=p.ambient_energy
	env.reflected_light_source=Environment.REFLECTION_SOURCE_DISABLED
	var RG2 := preload("res://scripts/traveler/render_globals.gd")    # Mobile 渲染器没有的效果不开（TS-9）
	env.ssao_enabled=RG2.env_feature("ssao");env.ssao_radius=p.ao;env.ssao_intensity=p.aoi
	env.ssao_power=1.6;env.ssao_detail=0.6;env.ssao_light_affect=0.22
	env.ssil_enabled=false
	env.sdfgi_enabled=RG2.env_feature("sdfgi");env.sdfgi_read_sky_light=false;env.sdfgi_use_occlusion=true
	env.sdfgi_cascades=4;env.sdfgi_min_cell_size=0.5;env.sdfgi_max_distance=64.0;env.sdfgi_y_scale=2
	env.sdfgi_energy=p.sdfgi_energy;env.sdfgi_bounce_feedback=p.sdfgi_bounce_feedback
	env.sdfgi_normal_bias=1.1;env.sdfgi_probe_bias=1.1
	env.glow_enabled=false;env.tonemap_mode=Environment.TONE_MAPPER_AGX;env.tonemap_exposure=p.exposure;env.tonemap_white=1.4
	env.adjustment_enabled=true;env.adjustment_saturation=1.02;env.adjustment_contrast=1.04
	env.fog_enabled=false
	var key:DirectionalLight3D=viewer.sun
	key.light_color=rgb(key_color);key.light_energy=float(config.get("key_energy",1.1));key.light_angular_distance=0.8
	key.shadow_enabled=true;key.shadow_blur=0.7;key.rotation=Vector3(deg_to_rad(-38.0),deg_to_rad(-32.0),0.0)
	_add_studio_directional("StudioFill",fill_color,float(config.get("fill_energy",0.28)),Vector3(-26.0,142.0,0.0))
	_add_studio_directional("StudioRim",rim_color,float(config.get("rim_energy",0.35)),Vector3(-20.0,34.0,0.0))
	var attributes:=CameraAttributesPractical.new()
	attributes.dof_blur_far_enabled=true;attributes.dof_blur_far_distance=p.dof;attributes.dof_blur_far_transition=p.dof_transition;attributes.dof_blur_amount=0.04
	viewer.camera.attributes=attributes
	var vp:Viewport=viewer.get_viewport();vp.msaa_3d=Viewport.MSAA_4X;vp.screen_space_aa=Viewport.SCREEN_SPACE_AA_DISABLED;vp.use_taa=false

func _add_studio_directional(name_value:String,color_value:Array,energy:float,rotation:Vector3) -> void:
	var light:=DirectionalLight3D.new();light.name=name_value;light.light_color=rgb(color_value);light.light_energy=energy;light.shadow_enabled=false
	light.rotation=Vector3(deg_to_rad(rotation.x),deg_to_rad(rotation.y),deg_to_rad(rotation.z));viewer.add_child(light)

func rgb(value:Array) -> Color:return Color(float(value[0]),float(value[1]),float(value[2]))

func evidence(image:Image) -> Dictionary:
	return {"preset":preset_id,"effective_params":recipe.params.duplicate(true),"sky":recipe.sky.duplicate(true),"measured":load("res://scripts/traveler/look_evidence.gd").hsv_stats(image),"report_only":true,"note":"HSV values describe the image; they are not acceptance thresholds."}
