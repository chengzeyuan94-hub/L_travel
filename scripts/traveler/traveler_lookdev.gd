extends RefCounted
## Static lookdev recipe promoted for the frozen traveler camera (no cloud motion).
var host: Node3D
var world: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var environment: Environment
var target: Vector3
var selected: String
var cities: Array
var material_list: Array[ShaderMaterial]
var city_lights: Array[OmniLight3D]
var look_dusk := false
var look_far := false
var preset_id := ""
var baseline_image := ""
var baseline_stats: Dictionary = {}
var day_baseline_image := ""
var dusk_baseline_image := ""
var mountain_params: Dictionary = {}
var audit_enabled := false
var audit_faces: Array = []
var audit_bodies: Array = []
var audit_peak := -1
var audit_main := false
var day_lk: Dictionary = {}
var dusk_lk: Dictionary = {}
var current_period_t := 0.0
var transition_from_t := 0.0
var transition_to_t := 0.0
var transition_elapsed := 0.0
var transition_duration := 8.0
var transition_active := false
var transition_target_dusk := false
var sky: Sky
var sky_mat: ProceduralSkyMaterial
var day_sky_top := Color(0.26,0.30,0.64)
var day_sky_horizon := Color(0.99,0.74,0.58)
var day_ground_bottom := Color(0.30,0.27,0.30)
var day_ground_horizon := Color(0.86,0.66,0.58)
var dusk_sky_top := Color(0.07,0.09,0.26)
var dusk_sky_horizon := Color(0.66,0.42,0.54)
var dusk_ground_bottom := Color(0.08,0.08,0.13)
var dusk_ground_horizon := Color(0.46,0.34,0.42)
# Dusk sun colour; a scene may override it with scenes.<id>.dusk.sun_color (Chang'an does since 2026-09-24).
var dusk_sun_color := Color(0.58,0.62,0.95)
# Chang'an dusk light layers (rim / snow alpenglow / bounce / ground): scripts/traveler/changan_dusk/.
const CHANGAN_DUSK_LAYERS_PATH := "res://scripts/traveler/changan_dusk/changan_dusk_layers.gd"
var dusk_layers: RefCounted
var lk:={"ao":0.2,"aoi":3.2,"amb":0.38,"exp":0.95,"white":1.5,"sat":1.22,"con":1.10,
"fogb":40.0,"foge":260.0,"aerial":0.35,"fogd":1.0,"sun":3.1,"sunel":-19.0,"sunaz":42.0,
"ssil":0.6,"ssili":0.7,"rock":0.6,"rough":0.95,"glow":0.55,"dof":0.0,"dofn":0.0,"blur":0.14,"ang":0.35,"sblur":0.8,"shmax":60.0,"bias":0.02,"nbias":0.06}

func configure(viewer: Node3D, dusk: bool, far_backdrop: bool) -> void:
	host = viewer
	audit_enabled = not host.dump_massif.is_empty()
	world = host.world
	camera = host.camera
	sun = host.sun
	environment = host.environment
	target = host.target
	selected = host.selected
	cities = host.cities
	material_list = host.material_list
	city_lights = host.city_lights
	look_dusk = dusk
	look_far = far_backdrop
	var presets: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/look_presets.json"))
	var scene_presets: Dictionary = presets.scenes.get(selected,{})
	var period := "dusk" if dusk else "day"
	var default_lk: Dictionary = lk.duplicate(true)
	day_lk = default_lk.duplicate(true)
	dusk_lk = default_lk.duplicate(true)
	if scene_presets.has("day"):
		day_lk = scene_presets.day.params.duplicate(true)
	if scene_presets.has("dusk"):
		dusk_lk = scene_presets.dusk.params.duplicate(true)
		if scene_presets.dusk.has("sun_color"):
			var sc: Array = scene_presets.dusk.sun_color
			dusk_sun_color = Color(float(sc[0]), float(sc[1]), float(sc[2]))
		if selected == "changan" and scene_presets.dusk.has("layers"):
			# Evidence-only switch (--changan-dusk-off=...) puts the chosen dusk params back to their previous values.
			dusk_sun_color = load(CHANGAN_DUSK_LAYERS_PATH).dusk_param_overrides(scene_presets.dusk.layers, dusk_lk, dusk_sun_color)
	if not scene_presets.has(period):
		push_warning("No scene look preset: "+selected+"/"+period+"; reporting recipe defaults explicitly")
	for key in host.look_overrides:
		if not day_lk.has(key) and not dusk_lk.has(key):
			push_error("Unknown look parameter: "+str(key))
			continue
		if day_lk.has(key):day_lk[key]=host.look_overrides[key]
		if dusk_lk.has(key):dusk_lk[key]=host.look_overrides[key]
	lk = (dusk_lk if dusk else day_lk).duplicate(true)
	current_period_t = 1.0 if dusk else 0.0
	transition_target_dusk = dusk
	preset_id = selected+"/"+period if scene_presets.has(period) else "unconfigured/"+selected+"/"+period
	if scene_presets.has(period):
		var preset: Dictionary = scene_presets[period]
		look_dusk = bool(preset.dusk_colors)
		baseline_image = str(preset.baseline_image)
		# 参考图只用来算画面证据（evidence），在 docs/ 里；正式包不带 docs，没有就跳过，不报错（2026-09-27）
		var baseline:Image=Image.load_from_file("res://"+baseline_image) if FileAccess.file_exists("res://"+baseline_image) else null
		if baseline!=null:baseline_stats=load("res://scripts/traveler/look_evidence.gd").hsv_stats(baseline)
	if scene_presets.has("day"):day_baseline_image=str(scene_presets.day.baseline_image)
	if scene_presets.has("dusk"):dusk_baseline_image=str(scene_presets.dusk.baseline_image)
	apply_lookdev()
	host.set_cliff_buddha_glow(look_dusk or host.night)
	if selected == "changan" and scene_presets.has("dusk") and scene_presets.dusk.has("layers"):
		dusk_layers = load(CHANGAN_DUSK_LAYERS_PATH).new()
		dusk_layers.install(self, scene_presets.dusk.layers)
		dusk_layers.set_mix(current_period_t)

func evidence(image: Image) -> Dictionary:
	var stats: Dictionary = load("res://scripts/traveler/look_evidence.gd").hsv_stats(image)
	var deviations := {}
	for key in ["meanV","meanS"]:
		if baseline_stats.has(key):deviations[key]=float(stats[key])-float(baseline_stats[key])
	var report := {"preset":preset_id,"dusk_colors":look_dusk,"effective_params":lk.duplicate(true),
		"period_blend":current_period_t,"transition_active":transition_active,
		"transition_target_dusk":transition_target_dusk,"transition_duration_s":transition_duration,
		"overrides":host.look_overrides.duplicate(true),"baseline_image":baseline_image,
		"measured":stats,"baseline_measured":baseline_stats,"deviation":deviations,
		"mountain_params":mountain_params.duplicate(true),
		"near_mountain":world.get_meta("near_mountain",{}),
		"cliff_buddha":world.get_meta("cliff_buddha",{}),
		"framed_mountain":world.get_node("FarBackdrop").get_meta("framed_mountain",{}) if world.has_node("FarBackdrop") else {},
		"mountain_asset_report":world.get_node("FarBackdrop").get_meta("mountain_asset_report",{}) if world.has_node("FarBackdrop") else {},
		"report_only":true,"note":"HSV statistics report appearance changes; they are not a pass/fail gate."}
	if dusk_layers!=null:
		report["changan_dusk"]=dusk_layers.evidence()
		report["dusk_sun_color"]=[dusk_sun_color.r,dusk_sun_color.g,dusk_sun_color.b]
	return report

func update_camera() -> void:
	host.update_camera()

func apply_lookdev()->void:
	# Sky instead of a flat background colour: half the "cheap" look comes from a dead sky.
	sky=Sky.new()
	sky_mat=ProceduralSkyMaterial.new()
	sky_mat.sky_top_color=dusk_sky_top if look_dusk else day_sky_top
	sky_mat.sky_horizon_color=dusk_sky_horizon if look_dusk else day_sky_horizon
	sky_mat.sky_curve=0.10
	sky_mat.sky_energy_multiplier=1.0
	sky_mat.ground_bottom_color=dusk_ground_bottom if look_dusk else day_ground_bottom
	sky_mat.ground_horizon_color=dusk_ground_horizon if look_dusk else day_ground_horizon
	sky_mat.ground_curve=0.08
	sky_mat.sun_angle_max=4.5
	sky_mat.sun_curve=0.06
	sky_mat.energy_multiplier=1.0
	sky.sky_material=sky_mat
	environment.background_mode=Environment.BG_SKY
	environment.sky=sky
	environment.ambient_light_source=Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution=1.0
	environment.ambient_light_energy=lk.amb
	environment.reflected_light_source=Environment.REFLECTION_SOURCE_SKY
	# Real AO is the whole point of the shader rewrite.
	var RG := preload("res://scripts/traveler/render_globals.gd")     # Mobile 渲染器没有的效果不开（TS-9）
	environment.ssao_enabled=RG.env_feature("ssao")
	environment.ssao_radius=lk.ao
	environment.ssao_intensity=lk.aoi
	environment.ssao_power=1.6
	environment.ssao_detail=0.6
	environment.ssao_horizon=0.06
	environment.ssao_light_affect=0.18
	environment.ssao_ao_channel_affect=0.0
	environment.ssil_enabled=RG.env_feature("ssil")
	environment.ssil_radius=lk.ssil
	environment.ssil_intensity=lk.ssili
	environment.ssil_sharpness=0.98
	environment.glow_enabled=true
	environment.glow_blend_mode=Environment.GLOW_BLEND_MODE_SOFTLIGHT
	environment.glow_intensity=lk.glow
	environment.glow_bloom=0.16
	environment.glow_hdr_threshold=0.92
	environment.set_glow_level(3,1.0);environment.set_glow_level(4,1.0);environment.set_glow_level(5,0.6)
	# Depth fog only. Volumetric fog is a trap here (it turns the whole frame brown).
	environment.volumetric_fog_enabled=false
	environment.fog_enabled=true
	environment.fog_mode=Environment.FOG_MODE_DEPTH
	environment.fog_light_color=Color(0.79,0.70,0.78)
	environment.fog_light_energy=1.0
	environment.fog_sun_scatter=0.28
	environment.fog_density=lk.fogd
	environment.fog_depth_begin=lk.fogb
	environment.fog_depth_end=lk.foge
	environment.fog_depth_curve=1.35
	environment.fog_sky_affect=0.0
	environment.fog_aerial_perspective=lk.aerial
	environment.tonemap_mode=Environment.TONE_MAPPER_AGX
	environment.tonemap_exposure=lk.exp
	environment.tonemap_white=lk.white
	environment.adjustment_enabled=true
	environment.adjustment_saturation=lk.sat
	environment.adjustment_contrast=lk.con
	environment.adjustment_brightness=1.0
	# Low warm key with long soft shadows; the fill is the sky, not a second warm lamp.
	sun.light_color=Color(0.58,0.62,0.95) if look_dusk else Color(1.0,0.80,0.62)
	sun.light_energy=lk.sun
	sun.light_angular_distance=lk.ang
	sun.shadow_enabled=true
	sun.shadow_blur=lk.sblur
	sun.shadow_bias=lk.bias
	sun.shadow_normal_bias=lk.nbias
	sun.directional_shadow_mode=DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_split_1=0.08
	sun.directional_shadow_max_distance=lk.shmax
	sun.rotation=Vector3(deg_to_rad(lk.sunel),deg_to_rad(lk.sunaz),0.0)
	if lk.dof>0.0:
		var ca:=CameraAttributesPractical.new()
		ca.dof_blur_amount=lk.blur
		ca.dof_blur_far_enabled=true
		ca.dof_blur_far_distance=lk.dof
		ca.dof_blur_far_transition=lk.dof*0.55
		if lk.dofn>0.0:
			ca.dof_blur_near_enabled=true
			ca.dof_blur_near_distance=lk.dofn
			ca.dof_blur_near_transition=lk.dofn*0.6
		camera.attributes=ca
	if look_dusk:
		for m in material_list:m.set_shader_parameter("emission_strength",0.06)
	ProjectSettings.set_setting("rendering/lights_and_shadows/directional_shadow/size",8192)
	preload("res://scripts/traveler/render_globals.gd").shadow_atlas(8192,true)
	var vp:=host.get_viewport()
	vp.msaa_3d=Viewport.MSAA_4X
	vp.screen_space_aa=Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa=false # MOTION gate contract; frozen lighting remains unchanged.
	for m in material_list:
		m.set_shader_parameter("roughness",lk.rough)
		m.set_shader_parameter("brightness",1.0)
		m.set_shader_parameter("rock_tint_amount",lk.rock)
	# Lantern warmth at the selected city, this time casting shadows.
	for i in cities.size():
		var c:Dictionary=cities[i]
		if c.id==selected:
			var lamp:OmniLight3D=city_lights[i]
			lamp.visible=true
			lamp.light_energy=3.4 if look_dusk else 1.1
			lamp.light_color=Color(1.0,0.66,0.34)
			lamp.omni_range=float(c.scale)*6.0
			lamp.position=Vector3(c.x,float(c.base)+float(c.scale)*0.55,c.z)
			lamp.shadow_enabled=true
	if look_far:build_far_backdrop()
	apply_period_mix(current_period_t)
	update_camera()

func start_period_transition(to_dusk: bool, duration_s: float = 8.0) -> void:
	if not host.look_on or selected != "changan":
		return
	transition_from_t=current_period_t
	transition_to_t=1.0 if to_dusk else 0.0
	transition_elapsed=0.0
	transition_duration=maxf(duration_s,0.1)
	transition_target_dusk=to_dusk
	transition_active=not is_equal_approx(transition_from_t,transition_to_t)
	if not transition_active:
		look_dusk=to_dusk
		return
	# Apply the starting point immediately so a reversed transition never jumps.
	apply_period_mix(current_period_t)

func tick_transition(delta: float) -> void:
	if not transition_active:
		return
	transition_elapsed=minf(transition_elapsed+maxf(delta,0.0),transition_duration)
	var linear_t:=clampf(transition_elapsed/transition_duration,0.0,1.0)
	# Smoothstep keeps the start/end quiet while leaving the middle readable.
	var eased:=linear_t*linear_t*(3.0-2.0*linear_t)
	current_period_t=lerpf(transition_from_t,transition_to_t,eased)
	apply_period_mix(current_period_t)
	if linear_t>=1.0:
		transition_active=false
		current_period_t=transition_to_t
		look_dusk=transition_target_dusk
		preset_id=selected+("/dusk" if look_dusk else "/day")
		baseline_image=dusk_baseline_image if look_dusk else day_baseline_image
		var finished_baseline:Image=Image.load_from_file("res://"+baseline_image) if FileAccess.file_exists("res://"+baseline_image) else null
		if finished_baseline!=null:
			baseline_stats=load("res://scripts/traveler/look_evidence.gd").hsv_stats(finished_baseline)
		# Re-apply once after clearing the transition flag so cloud drift returns
		# from its expressive handoff speed to the quiet period speed.
		apply_period_mix(current_period_t)

func apply_period_mix(period_t: float) -> void:
	var t:=clampf(period_t,0.0,1.0)
	if sky_mat!=null:
		sky_mat.sky_top_color=day_sky_top.lerp(dusk_sky_top,t)
		sky_mat.sky_horizon_color=day_sky_horizon.lerp(dusk_sky_horizon,t)
		sky_mat.ground_bottom_color=day_ground_bottom.lerp(dusk_ground_bottom,t)
		sky_mat.ground_horizon_color=day_ground_horizon.lerp(dusk_ground_horizon,t)
	var mixed: Dictionary = {}
	for key in day_lk:
		if dusk_lk.has(key) and (day_lk[key] is float or day_lk[key] is int):
			mixed[key]=lerpf(float(day_lk[key]),float(dusk_lk[key]),t)
		else:
			mixed[key]=day_lk[key]
	lk=mixed
	if environment!=null:
		environment.ambient_light_energy=float(lk.amb)
		environment.ssao_radius=float(lk.ao)
		environment.ssao_intensity=float(lk.aoi)
		environment.ssil_radius=float(lk.ssil)
		environment.ssil_intensity=float(lk.ssili)
		environment.glow_intensity=float(lk.glow)
		environment.fog_density=float(lk.fogd)
		environment.fog_depth_begin=float(lk.fogb)
		environment.fog_depth_end=float(lk.foge)
		environment.fog_aerial_perspective=float(lk.aerial)
		environment.tonemap_exposure=float(lk.exp)
		environment.tonemap_white=float(lk.white)
		environment.adjustment_saturation=float(lk.sat)
		environment.adjustment_contrast=float(lk.con)
	if sun!=null:
		sun.light_color=Color(1.0,0.80,0.62).lerp(dusk_sun_color,t)
		sun.light_energy=float(lk.sun)
		sun.light_angular_distance=float(lk.ang)
		sun.shadow_blur=float(lk.sblur)
		sun.shadow_bias=float(lk.bias)
		sun.shadow_normal_bias=float(lk.nbias)
		sun.directional_shadow_max_distance=float(lk.shmax)
		sun.directional_shadow_split_1=float(lk.get("split1",0.08))
		sun.rotation=Vector3(deg_to_rad(float(lk.sunel)),deg_to_rad(float(lk.sunaz)),0.0)
	for m in material_list:
		m.set_shader_parameter("emission_strength",0.06*t)
		m.set_shader_parameter("roughness",lk.rough)
		m.set_shader_parameter("brightness",1.0)
		m.set_shader_parameter("rock_tint_amount",lk.rock)
	if camera!=null:
		var ca:=camera.attributes as CameraAttributesPractical
		if ca==null:
			ca=CameraAttributesPractical.new()
			camera.attributes=ca
		ca.dof_blur_amount=float(lk.blur)
		ca.dof_blur_far_enabled=float(lk.dof)>0.0
		ca.dof_blur_far_distance=float(lk.dof)
		ca.dof_blur_far_transition=float(lk.dof)*0.55
		ca.dof_blur_near_enabled=float(lk.dofn)>0.0
		ca.dof_blur_near_distance=float(lk.dofn)
		ca.dof_blur_near_transition=float(lk.dofn)*0.6
	var lamp_energy:=0.0
	for i in cities.size():
		var c:Dictionary=cities[i]
		if c.id==selected:
			var lamp:OmniLight3D=city_lights[i]
			lamp_energy=lerpf(1.1,3.4,t)
			lamp.visible=true
			lamp.light_energy=lamp_energy
			lamp.light_color=Color(1.0,0.66,0.34)
			lamp.omni_range=float(c.scale)*6.0
			lamp.shadow_enabled=true
	if host!=null:
		host.set_cliff_buddha_glow(t>0.02 or host.night)
		if host.motion_director!=null and host.motion_director.has_method("set_period_blend"):
			host.motion_director.set_period_blend(t,lamp_energy,transition_active)
		if world.has_node("FarBackdrop"):
			set_mountain_period(t>0.5 or host.night)
	if dusk_layers!=null:
		dusk_layers.set_mix(t)


# ---------------------------------------------------------------------------
# Massif generator (2026-09-18). Replaces instanced 12-sided cones.
# Distilled from the four references Carlos sent: a mountain reads as MASS, not
# as a spire. Base radius is 1.6-2.4x the height, every face is broken into many
# irregular facets with their own value, 3-6 lower shoulders are fused onto the
# main body so silhouettes step and overlap, and the snow line is a hard cut that
# wanders per ridge instead of a clean ring.
# One ArrayMesh per band => one draw call per band.
# ---------------------------------------------------------------------------
func _massif_point(a:float, t:float, base_r:float, height:float, ridge:PackedFloat32Array, rng:RandomNumberGenerator)->Vector3:
	# References read as "pointed summit on a wide skirt", not a dome. So: the lower third
	# barely narrows (the skirt), then it tapers steadily to a point.
	var prof:float
	if t<0.34:
		prof=lerp(1.0,0.74,t/0.34)
	else:
		prof=0.74*pow(1.0-(t-0.34)/0.66,0.92)
	var n:int=ridge.size()
	var fi:float=a/TAU*float(n)
	var i0:int=int(floor(fi))%n
	var i1:int=(i0+1)%n
	var f:float=fi-floor(fi)
	var rmod:float=lerp(ridge[i0],ridge[i1],f)
	var r:float=base_r*prof*rmod*(1.0+rng.randf_range(-0.045,0.045))
	return Vector3(cos(a)*r, height*pow(t,0.94), sin(a)*r)

func _add_massif_body(st:SurfaceTool, origin:Vector3, base_r:float, height:float, rock:Color, snow:Color, rng:RandomNumberGenerator, n_ang:int, n_ring:int)->void:
	if audit_enabled:
		audit_bodies.append({"origin":[origin.x,origin.y,origin.z],"radius":base_r,"height":height,
			"face_start":audit_faces.size(),"n_ang":n_ang,"n_ring":n_ring,"peak_id":audit_peak,"main":audit_main})
	var ridge:=PackedFloat32Array()
	var lobes:int=rng.randi_range(3,5)
	var phase:float=rng.randf_range(0.0,TAU)
	for j in n_ang:
		var a:float=TAU*float(j)/float(n_ang)
		# Two ridge harmonics + jitter: buttresses and gullies, not a circle.
		var v:float=1.0+0.26*sin(float(lobes)*a+phase)+0.13*sin(7.0*a+phase*1.7)+rng.randf_range(-0.07,0.07)
		ridge.append(maxf(0.42,v))
	if audit_enabled:audit_bodies[-1]["ridge"]=Array(ridge)
	# Snow line wanders per ridge so the cut is not a clean ring.
	var snow_t:PackedFloat32Array=PackedFloat32Array()
	var base_snow:float=rng.randf_range(0.46,0.60)
	for j in n_ang:
		snow_t.append(clampf(base_snow+rng.randf_range(-0.10,0.10),0.30,0.80))
	var grid:Array=[]
	for i in n_ring:
		var t:float=float(i)/float(n_ring-1)
		var row:Array=[]
		for j in n_ang:
			var a:float=TAU*float(j)/float(n_ang)
			row.append(origin+_massif_point(a,t,base_r,height,ridge,rng))
		grid.append(row)
	var apex:Vector3=origin+Vector3(rng.randf_range(-0.04,0.04)*base_r, height*1.02, rng.randf_range(-0.04,0.04)*base_r)
	for i in n_ring-1:
		for j in n_ang:
			var j2:int=(j+1)%n_ang
			var a0:Vector3=grid[i][j]
			var a1:Vector3=grid[i][j2]
			var b1:Vector3=grid[i+1][j2]
			var b0:Vector3=grid[i+1][j]
			_add_facet(st,a0,a1,b1,rock,snow,height,origin.y,snow_t[j],rng)
			_add_facet(st,a0,b1,b0,rock,snow,height,origin.y,snow_t[j],rng)
	for j in n_ang:
		var j2:int=(j+1)%n_ang
		_add_facet(st,grid[n_ring-1][j],grid[n_ring-1][j2],apex,rock,snow,height,origin.y,snow_t[j],rng)

func _add_facet(st:SurfaceTool, p0:Vector3, p1:Vector3, p2:Vector3, rock:Color, snow:Color, height:float, base_y:float, snow_t:float, rng:RandomNumberGenerator)->void:
	var nrm:Vector3=(p1-p0).cross(p2-p0)
	if nrm.length()<1e-7:return
	nrm=nrm.normalized()
	var mid_t:float=((p0.y+p1.y+p2.y)/3.0-base_y)/maxf(height,1e-4)
	var is_snow:bool=mid_t>snow_t
	# Steep faces shed snow, exactly as in the references.
	if is_snow and nrm.y<0.22 and rng.randf()<0.55:is_snow=false
	var c:Color=snow if is_snow else rock
	# Per-facet value jitter is what makes a big face read as volume.
	var k:float=1.0+rng.randf_range(-0.085,0.085)
	c=Color(clampf(c.r*k,0,1),clampf(c.g*k,0,1),clampf(c.b*k,0,1))
	if audit_enabled:audit_faces.append({"body":audit_bodies.size()-1,"material":"snow" if is_snow else "rock"})
	for p in [p0,p1,p2]:
		st.set_normal(nrm)
		st.set_color(c)
		st.add_vertex(p)

func build_massif_band(specs:Array, rock:Color, snow:Color, seed:int, n_ang:int, n_ring:int)->ArrayMesh:
	# Legacy geometry and RNG order retained for board-swap. Audit is read-only.
	if audit_enabled:audit_faces=[];audit_bodies=[];audit_peak=-1
	var rng:=RandomNumberGenerator.new()
	rng.seed=seed
	var st:=SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for sp in specs:
		if audit_enabled:audit_peak+=1;audit_main=true
		var o:Vector3=sp["pos"]
		var h:float=float(sp["h"])
		var br:float=float(sp["r"])
		_add_massif_body(st,o,br,h,rock,snow,rng,n_ang,n_ring)
		# Shoulders: lower, fatter, pushed out from the centre so they overlap the
		# main body's silhouette. This is where the "thickness" comes from.
		var n_sh:int=rng.randi_range(3,6)
		if audit_enabled:audit_main=false
		for k in n_sh:
			var a:float=rng.randf_range(0.0,TAU)
			var d:float=br*rng.randf_range(0.50,0.92)
			var sh_h:float=h*rng.randf_range(0.26,0.48)
			var sh_r:float=br*rng.randf_range(0.36,0.62)
			_add_massif_body(st,o+Vector3(cos(a)*d,0.0,sin(a)*d),sh_r,sh_h,rock,snow,rng,maxi(8,n_ang*2/3),maxi(4,n_ring-2))
	return st.commit()

func build_massif_band_v2(specs:Array, rock:Color, snow:Color, seed:int, n_ang:int, n_ring:int, generator:RefCounted)->ArrayMesh:
	# Preserve the legacy public generator and its RNG stream for board-swap.
	# S3 changes only normals and lighting; S4 owns snow selection and S5 topology.
	var previous_audit := audit_enabled
	audit_enabled=true
	var source := build_massif_band(specs,rock,snow,seed,n_ang,n_ring)
	var rebuilt: Dictionary=generator.rebuild(audit_bodies,seed,mountain_params)
	audit_faces=rebuilt.faces;audit_bodies=rebuilt.bodies
	var result: ArrayMesh=rebuilt.mesh
	audit_enabled=previous_audit
	return result

func _tint_flat(node:Node, tint:Color, rough:float, unshaded_boost:float, use_vcol:bool=true)->void:
	for m in node.find_children("*","MeshInstance3D",true,false):
		var mat:=StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo=use_vcol
		mat.albedo_color=tint
		mat.roughness=rough
		mat.metallic=0.0
		mat.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
		mat.diffuse_mode=BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
		if unshaded_boost>0.0:
			mat.emission_enabled=true
			mat.emission=tint
			mat.emission_energy_multiplier=unshaded_boost
		m.material_override=mat
		m.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func build_far_backdrop()->void:
	var far_root:=Node3D.new();far_root.name="FarBackdrop";world.add_child(far_root)
	mountain_params=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/mountain_params.json"))
	if preload("res://scripts/traveler/traveler_launch.gd").user_args().has("--mountain-source") or str(mountain_params.get("runtime_mode","asset"))=="reference_massifs":
		_build_reference_massifs(far_root)
	elif str(mountain_params.get("runtime_mode","asset"))=="framed_massif":
		_build_framed_massif(far_root)
	else:
		if mountain_params.has("asset_variant_params_path"):
			mountain_params=JSON.parse_string(FileAccess.get_file_as_string(mountain_params.asset_variant_params_path))
		_build_authorized_massifs(far_root)
	# Static cloud density, with node-only movement and two crossfading banks.
	var cloud_settings:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/day_clouds_params.json"))
	var cloud_layout:Array=cloud_settings.layout
	var cloud_report:Array=[]
	for i in cloud_layout.size():
		var c:Array=cloud_layout[i]
		var base:=Vector3(target.x+float(c[0]),float(c[2]),target.z+float(c[1]))
		var size:=float(c[3])
		var variant:=int(c[4])
		var day_cloud:=_make_fluffy_cloud("CloudDay%02d"%i,base,size,variant,"day",i)
		far_root.add_child(day_cloud)
		cloud_report.append({"set":"day","name":day_cloud.name,"position":[base.x,base.y,base.z],"lobe_count":day_cloud.get_meta("lobe_count")})
		# The dusk bank is a separate, slightly offset arrangement. Both banks
		# exist from frame zero so a transition never rebuilds the frozen scene.
		var dusk_base:=base+Vector3(2.2+sin(float(i)*1.7)*1.8,0.8+cos(float(i)*1.3)*0.35,1.5)
		var dusk_cloud:=_make_fluffy_cloud("CloudDusk%02d"%i,dusk_base,size*0.96,(variant+1)%3,"dusk",i)
		far_root.add_child(dusk_cloud)
		cloud_report.append({"set":"dusk","name":dusk_cloud.name,"position":[dusk_base.x,dusk_base.y,dusk_base.z],"lobe_count":dusk_cloud.get_meta("lobe_count")})
	# Four lighter accents in the frozen view, living in world space.
	for j in cloud_settings.get("accent_clouds",[]).size():
		var accent:Dictionary=cloud_settings.accent_clouds[j]
		for bank in ["day","dusk"]:
			var uv:=Vector2(float(accent.screen[0]),float(accent.screen[1]))
			if bank=="dusk":uv+=Vector2(0.018,-0.008)
			var depth:=float(accent.depth)
			var center:Vector3=camera.project_position(uv*camera.get_viewport().get_visible_rect().size,depth)
			var cloud:=_make_fluffy_cloud("CloudAccent%s%02d"%[bank,j],center,1.0,j,bank,cloud_layout.size()+j)
			var card:=cloud.get_node("Lobes") as MeshInstance3D
			var pixel_scale:=2.0*depth*tan(deg_to_rad(camera.fov)*0.5)/1080.0
			(card.mesh as QuadMesh).size=Vector2(float(accent.size_px[0]),float(accent.size_px[1]))*pixel_scale
			(card.material_override as ShaderMaterial).set_shader_parameter("opacity",float(accent.opacity))
			(card.material_override as ShaderMaterial).set_shader_parameter("shape",float(accent.shape))
			far_root.add_child(cloud)
			cloud_report.append({"set":bank,"name":cloud.name,"screen_uv":[uv.x,uv.y],"opacity":accent.opacity,"depth":depth})
	far_root.set_meta("far_cloud_report",cloud_report)
	far_root.set_meta("cloud_style","wispy_static_density")
	far_root.set_meta("cloud_sets",2)

func _make_fluffy_cloud(name:String, center:Vector3, size:float, variant:int, set_name:String, index:int)->Node3D:
	var root:=Node3D.new()
	root.name=name
	root.position=center
	root.basis=camera.global_basis.orthonormalized()
	root.scale=Vector3.ONE*size
	root.set_meta("traveler_cloud_cluster",true)
	root.set_meta("cloud_set",set_name)
	root.set_meta("lobe_count",5)
	var config:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/day_clouds_params.json"))
	var palette:Dictionary=config.palette[set_name]
	var material:=ShaderMaterial.new()
	material.shader=load("res://scripts/traveler/wispy_cloud.gdshader")
	material.set_shader_parameter("cloud_color",Color(str(palette.light)))
	material.set_shader_parameter("shade_color",Color(str(palette.shade)))
	material.set_shader_parameter("variant",float(index*3+variant))
	material.set_shader_parameter("bank_alpha",1.0 if set_name=="day" else 0.0)
	var quad:=QuadMesh.new()
	quad.size=Vector2(float(config.card_width),float(config.card_height))
	var instance:=MeshInstance3D.new()
	instance.name="Lobes"
	instance.mesh=quad
	instance.material_override=material
	instance.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(instance)
	return root

func _build_reference_massifs(far_root: Node3D) -> void:
	var placement: Dictionary=mountain_params.placement
	var brng:=RandomNumberGenerator.new()
	brng.seed=int(placement.seed)
	var bands: Array=mountain_params.bands
	var mountain_generator=load("res://scripts/traveler/traveler_mountain.gd").new()
	for bi in bands.size():
		var band:Dictionary=bands[bi]
		var specs:Array=[]
		var n:int=int(band.count)
		var span:float=float(band.span)
		for i in n:
			var t:float=float(i)/float(maxi(1,n-1))
			var x:float=-span*0.5+span*t+brng.randf_range(-float(placement.x_jitter),float(placement.x_jitter))
			var z:float=float(band.z)+brng.randf_range(-float(placement.z_jitter),float(placement.z_jitter))
			specs.append({"pos":Vector3(target.x+x,float(placement.base_y)+float(bi)*float(placement.band_y_step),target.z+z),
				"h":float(band.h)*brng.randf_range(placement.height_range[0],placement.height_range[1]),
				"r":float(band.r)*brng.randf_range(placement.radius_range[0],placement.radius_range[1])})
		var mesh:ArrayMesh=build_massif_band_v2(specs,mountain_generator.color3(band.rock),mountain_generator.color3(band.snow),int(placement.seed)+bi*int(placement.seed_stride),int(band.ang),int(band.ring),mountain_generator)
		var mi:=MeshInstance3D.new()
		mi.name="MassifBand%d"%bi
		mi.mesh=mesh
		if audit_enabled or preload("res://scripts/traveler/traveler_launch.gd").user_args().has("--mountain-source"):
			mi.set_meta("massif_faces",audit_faces.duplicate(true))
			mi.set_meta("massif_bodies",audit_bodies.duplicate(true))
		mi.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.material_override=mountain_generator.material(mountain_params.lighting)
		far_root.add_child(mi)

func _build_authorized_massifs(far_root: Node3D) -> void:
	var placement: Dictionary=mountain_params.placement
	var lighting: Dictionary=mountain_params.lighting
	var layer_mask := int(lighting.layer_mask)
	sun.light_cull_mask &= ~layer_mask
	var key := DirectionalLight3D.new()
	key.name="MountainKey"
	key.light_cull_mask=layer_mask
	key.light_color=Color(lighting.color[0],lighting.color[1],lighting.color[2])
	key.light_energy=float(lighting.energy)
	key.rotation_degrees=Vector3(lighting.rotation_degrees[0],lighting.rotation_degrees[1],lighting.rotation_degrees[2])
	key.shadow_enabled=bool(lighting.shadow_enabled)
	key.sky_mode=DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	far_root.add_child(key)
	var asset_layer=load("res://scripts/traveler/mountain_asset_layer.gd").new()
	asset_layer.configure(mountain_params)
	var brng:=RandomNumberGenerator.new()
	brng.seed=int(placement.seed)
	var bands: Array=mountain_params.bands
	for bi in bands.size():
		var band:Dictionary=bands[bi]
		var specs:Array=[]
		var n:int=int(band.count)
		var span:float=float(band.span)
		for i in n:
			var t:float=float(i)/float(maxi(1,n-1))
			var x:float=-span*0.5+span*t+brng.randf_range(-float(placement.x_jitter),float(placement.x_jitter))
			var z:float=float(band.z)+brng.randf_range(-float(placement.z_jitter),float(placement.z_jitter))
			specs.append({"pos":Vector3(target.x+x,float(placement.base_y)+float(bi)*float(placement.band_y_step),target.z+z),
				"h":float(band.h)*brng.randf_range(placement.height_range[0],placement.height_range[1]),
				"r":float(band.r)*brng.randf_range(placement.radius_range[0],placement.radius_range[1])})
		asset_layer.build_band(far_root,specs,bi,not host.no_mountain_foot)
	asset_layer.finish(far_root)

func _build_framed_massif(far_root: Node3D) -> void:
	var cfg: Dictionary=mountain_params.framed_asset
	var mesh := load(str(cfg.path)) as ArrayMesh
	if mesh==null:
		push_error("Missing framed mountain. Run tools/traveler/build_framed_mountain.gd with --mountain-source.")
		return
	var node := MeshInstance3D.new()
	node.name="MassifBandMerged"
	node.mesh=mesh
	node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.set_meta("mountain_geometry",true)
	var generator=load("res://scripts/traveler/traveler_mountain.gd").new()
	var material: StandardMaterial3D=generator.material(mountain_params.lighting)
	node.material_override=material
	far_root.add_child(node)
	var report: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(str(cfg.report)))
	report["model_count"]=1
	report["surface_count"]=mesh.get_surface_count()
	far_root.set_meta("framed_mountain",report)
	set_mountain_period(look_dusk or host.night)

func set_mountain_period(dusk: bool) -> void:
	var node := world.get_node_or_null("FarBackdrop/MassifBandMerged") as MeshInstance3D
	if node==null:return
	# Mountains now use scene lighting. Period changes affect Sun/environment,
	# never a separate mountain brightness override.
	node.material_override.albedo_color=Color.WHITE
	var far_root := world.get_node("FarBackdrop")
	var report: Dictionary=far_root.get_meta("framed_mountain")
	report["period"]="dusk" if dusk else "day"
	report["lighting"]="scene_sun_and_environment"
	far_root.set_meta("framed_mountain",report)
