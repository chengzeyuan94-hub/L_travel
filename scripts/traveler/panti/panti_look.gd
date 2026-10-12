extends "res://scripts/traveler/traveler_lookdev.gd"
## Reuse the accepted pipeline with Panti's independent daylight / sunset recipes.
var selected_recipe:Dictionary={}
var selected_period:="day"
var night_sky:RefCounted

func configure(viewer:Node3D,_dusk:bool=false,_far_backdrop:bool=false) -> void:
	if night_sky!=null and night_sky.has_method("clear"):night_sky.clear()
	var presets:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/look_presets.json"))
	selected_period=viewer.lighting_period
	assert(presets.scenes.panti.has(selected_period),"Missing Panti period preset: "+selected_period)
	selected_recipe=presets.scenes.panti[selected_period]
	var theme:Dictionary=selected_recipe.sky
	day_sky_top=rgb(theme.top);day_sky_horizon=rgb(theme.horizon)
	day_ground_bottom=rgb(theme.ground_bottom);day_ground_horizon=rgb(theme.ground_horizon)
	viewer.look_overrides=selected_recipe.params.duplicate(true)
	var dof:Dictionary=viewer.settings.get("depth_of_field_override",{})
	if not dof.is_empty():
		viewer.look_overrides.dof=float(dof.far_distance_u)
		viewer.look_overrides.blur=float(dof.blur_amount)
	super.configure(viewer,false,false)
	if not dof.is_empty():
		var attributes:=camera.attributes as CameraAttributesPractical
		attributes.dof_blur_far_transition=float(dof.far_transition_u)
	preset_id="panti/"+selected_period
	environment.fog_light_color=rgb(theme.fog_color)
	sun.light_color=rgb(theme.sun_color)
	if selected_recipe.has("ambient"):
		environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color=rgb(selected_recipe.ambient.color)
		environment.ambient_light_sky_contribution=float(selected_recipe.ambient.sky_contribution)
	if selected_recipe.has("galaxy"):
		night_sky=load("res://scripts/traveler/panti/panti_night_sky.gd").new()
		var sky_settings:Dictionary=JSON.parse_string(FileAccess.get_file_as_string(str(selected_recipe.galaxy.settings)))
		night_sky.configure(viewer,sky_settings.get("parameters",sky_settings))
	else:
		night_sky=null

func evidence(image:Image) -> Dictionary:
	var report:=super.evidence(image)
	report["selected_period"]=selected_period
	report["effective_sky_and_sun_colors"]=selected_recipe.sky.duplicate(true)
	report["period_authorization"]=selected_recipe.get("source","")
	report["ambient_source"]=environment.ambient_light_source
	report["ambient_color"]=[environment.ambient_light_color.r,environment.ambient_light_color.g,environment.ambient_light_color.b]
	report["sky_contribution"]=environment.ambient_light_sky_contribution
	if night_sky!=null:report["galaxy"]=night_sky.evidence()
	return report

func rgb(value:Array) -> Color:return Color(value[0],value[1],value[2])
