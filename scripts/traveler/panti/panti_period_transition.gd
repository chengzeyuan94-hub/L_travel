extends RefCounted
## One reversible eight-second lighting blend, driven by the existing weather clock.
## Every period-dependent value follows `weight` in _apply(), on both snap() and request() paths:
## look_presets.json recipes, the approved light polish (viewer.light_polish, main light including
## sun.shadow_blur, rim, snow, warm lights, materials), castle lamps, sky and camp effects.
const ENV_FIELDS := ["ambient_light_energy", "tonemap_exposure", "tonemap_white",
	"adjustment_saturation", "adjustment_contrast", "glow_intensity", "ssao_radius",
	"ssao_intensity", "ssil_radius", "ssil_intensity", "fog_density", "fog_depth_begin",
	"fog_depth_end", "fog_aerial_perspective", "fog_light_color"]
var viewer:Node3D
var settings:Dictionary
var recipes:Dictionary
var endpoints:Dictionary={}
var day_sky:Sky
var night_sky:RefCounted
var weight:=0.0
var from_weight:=0.0
var to_weight:=0.0
var elapsed:=0.0
var active:=false
var prepared:=false
var target_period:="morning"
var sky_yaw:=0.0
var sky_from_yaw:=0.0
var sky_to_yaw:=0.0

func configure(stage:Node3D) -> void:
	viewer=stage
	settings=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/panti_period_transition.json"))
	recipes=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/look_presets.json")).scenes.panti
	var initial:String=viewer.lighting_period
	# Prepare both endpoint looks once, before any visible transition frames.
	for period in ["morning","midnight"]:
		viewer.lighting_period=period
		viewer.look_profile.configure(viewer,false,false)
		var properties:Dictionary={}
		for property in ENV_FIELDS:properties[property]=viewer.environment.get(property)
		endpoints[period]=properties
		if period=="morning":day_sky=viewer.environment.sky
	night_sky=viewer.look_profile.night_sky
	night_sky.set_day_sky(day_sky)
	prepared=true
	snap(initial if initial in ["morning","midnight"] else "morning")

func snap(period:String) -> void:
	target_period=period
	weight=1.0 if period=="midnight" else 0.0
	from_weight=weight;to_weight=weight;elapsed=0.0;active=false
	sky_yaw=0.0;sky_from_yaw=0.0;sky_to_yaw=0.0
	_apply()

## Hold a fixed blend weight (capture / review of in-between frames); same state a paused request reaches.
func hold(blend_weight:float) -> void:
	weight=clampf(blend_weight,0.0,1.0)
	target_period="midnight" if weight>=0.5 else "morning"
	from_weight=weight;to_weight=weight;elapsed=0.0;active=false
	_apply()
	print("PANTI_TRANSITION_HOLD ",JSON.stringify(evidence()))

func request(period:String) -> void:
	if period==target_period and (active or is_equal_approx(weight,1.0 if period=="midnight" else 0.0)):return
	target_period=period
	from_weight=weight
	to_weight=1.0 if period=="midnight" else 0.0
	sky_from_yaw=sky_yaw if weight>0.0 else -deg_to_rad(float(settings.sky_flow_degrees))
	sky_to_yaw=0.0 if period=="midnight" else deg_to_rad(float(settings.sky_flow_degrees))
	elapsed=0.0
	active=not is_equal_approx(from_weight,to_weight)
	print("PANTI_TRANSITION_START ",JSON.stringify(evidence()))

func tick(delta:float,anim_t:float) -> void:
	if not prepared:return
	if active:
		elapsed=minf(elapsed+maxf(delta,0.0),float(settings.duration_s))
		if elapsed>float(settings.duration_s)-0.00001:elapsed=float(settings.duration_s)
		var t:=elapsed/float(settings.duration_s)
		weight=lerpf(from_weight,to_weight,t*t*(3.0-2.0*t))
		sky_yaw=lerpf(sky_from_yaw,sky_to_yaw,t*t*(3.0-2.0*t))
		if elapsed>=float(settings.duration_s):
			active=false;weight=to_weight
			if weight==0.0:sky_yaw=0.0
		_apply()
		if not active:print("PANTI_TRANSITION_COMPLETE ",JSON.stringify(evidence()))
	viewer.castle_lighting.set_anim_time(anim_t)
	night_sky.set_anim_time(anim_t)

func _apply() -> void:
	var a:Dictionary=endpoints.morning
	var b:Dictionary=endpoints.midnight
	for property in ENV_FIELDS:
		if a[property] is Color:viewer.environment.set(property,a[property].lerp(b[property],weight))
		else:viewer.environment.set(property,lerpf(float(a[property]),float(b[property]),weight))
	# At contribution=1 COLOR samples the same sky ambient as the morning SKY mode.
	viewer.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	viewer.environment.ambient_light_color=color(recipes.midnight.ambient.color)
	viewer.environment.ambient_light_sky_contribution=1.0-weight
	var mixed:Dictionary={}
	for key in recipes.morning.params:
		mixed[key]=lerpf(float(recipes.morning.params[key]),float(recipes.midnight.params[key]),weight)
	var sun_color:Color=color(recipes.morning.sky.sun_color).lerp(color(recipes.midnight.sky.sun_color),weight)
	# Approved light polish owns sun/moon energy, colour, shadow blur and ambient energy per period.
	var light_polish:Node3D=viewer.get("light_polish") as Node3D
	var polish:Dictionary=light_polish.main_light(weight) if light_polish!=null else {}
	if not polish.is_empty():
		mixed.sun=float(polish.energy);mixed.amb=float(polish.ambient);mixed.sblur=float(polish.shadow_blur)
		sun_color=polish.color
		viewer.environment.ambient_light_energy=mixed.amb
	# Report the accepted scene DOF override, not the look recipe's starting values.
	var attributes:=viewer.camera.attributes as CameraAttributesPractical
	mixed.dof=attributes.dof_blur_far_distance if attributes.dof_blur_far_enabled else 0.0
	mixed.dofn=attributes.dof_blur_near_distance if attributes.dof_blur_near_enabled else 0.0
	mixed.blur=attributes.dof_blur_amount
	viewer.sun.light_energy=mixed.sun
	viewer.sun.light_color=sun_color
	# shadow_blur was left at whichever period look_profile configured last (midnight); blend it too.
	viewer.sun.shadow_blur=mixed.sblur
	viewer.sun.rotation=Vector3(deg_to_rad(mixed.sunel),deg_to_rad(mixed.sunaz),0.0)
	night_sky.set_night_weight(weight)
	viewer.environment.sky=day_sky if weight==0.0 else night_sky.sky
	viewer.environment.sky_rotation=Vector3(0.0,sky_yaw,0.0)
	night_sky.set_sky_flow(viewer.environment.sky_rotation,active)
	night_sky.sync_environment(viewer.environment,viewer.camera)
	viewer.castle_lighting.set_night_weight(smoothstep(float(settings.castle_lights_begin),float(settings.castle_lights_full),weight))
	viewer.period_lighting.apply_blend(recipes.morning,recipes.midnight,weight)
	viewer.lighting_period=target_period if not active else "morning_to_midnight" if to_weight>from_weight else "midnight_to_morning"
	viewer.look_profile.selected_period=viewer.lighting_period
	viewer.look_profile.preset_id="panti/"+viewer.lighting_period
	viewer.look_profile.selected_recipe=recipes[target_period].duplicate(true)
	viewer.look_profile.selected_recipe.params=mixed.duplicate(true)
	for key in recipes.morning.sky:
		var value:Color=color(recipes.morning.sky[key]).lerp(color(recipes.midnight.sky[key]),weight)
		viewer.look_profile.selected_recipe.sky[key]=[value.r,value.g,value.b]
	viewer.look_profile.selected_recipe.sky.sun_color=[sun_color.r,sun_color.g,sun_color.b]
	viewer.look_profile.lk=mixed
	viewer.look_overrides=mixed.duplicate(true)
	viewer.look_profile.current_period_t=weight
	viewer.look_profile.transition_active=active
	viewer.look_profile.transition_duration=float(settings.duration_s)
	viewer.look_profile.transition_target_dusk=target_period=="midnight"
	viewer.castle_lighting.set_anim_time(viewer.weather.anim_t)
	night_sky.set_anim_time(viewer.weather.anim_t)
	# Last: the polish reads the final sun direction / colour, fire energy and castle spill energies.
	if light_polish!=null:light_polish.apply_blend(weight)

func color(values:Array) -> Color:return Color(values[0],values[1],values[2])

func evidence() -> Dictionary:
	return {"active":active,"target":target_period,"night_weight":weight,"from_weight":from_weight,
		"to_weight":to_weight,"elapsed_s":elapsed,"duration_s":float(settings.duration_s),
		"curve":"smoothstep","clock":"weather.anim_t","camera_changed":false,
		"sky_yaw_deg":rad_to_deg(sky_yaw),"sky_flow_active":active}
