extends Node3D
## Period-only lighting/tints; switching periods never restarts weather or idle.
const CHARACTER_LAYER:=1<<19
var viewer:Node3D
var character_fill:OmniLight3D
var current_effects:Dictionary={}

func configure(stage:Node3D) -> void:
	viewer=stage
	name="PantiPeriodLighting"
	character_fill=OmniLight3D.new()
	character_fill.name="NightCharacterFill"
	character_fill.light_cull_mask=CHARACTER_LAYER
	character_fill.shadow_enabled=false
	character_fill.light_specular=0.0
	add_child(character_fill)
	for mesh in viewer.character_model.find_children("*","MeshInstance3D",true,false):
		mesh.layers|=CHARACTER_LAYER
	character_fill.global_position=viewer.character.global_position+viewer.camera.global_basis.z*0.65+Vector3.UP*0.65
	apply_period()

func apply_period() -> void:
	current_effects=viewer.look_profile.selected_recipe.get("period_effects",{}).duplicate(true)
	_apply_effects()

func apply_blend(morning:Dictionary,midnight:Dictionary,weight:float) -> void:
	var settings:Dictionary=viewer.settings.camp
	var defaults:Dictionary={"fire_energy":settings.fire.light_energy,"fire_range_u":settings.fire.light_range_u,
		"lantern_energy":settings.lantern.light_energy,"lantern_range_u":settings.lantern.light_range_u,
		"lantern_emission":settings.lantern.emission_energy,"character_fill_energy":0.0,"character_fill_range_u":1.7}
	var a:Dictionary=morning.get("period_effects",{})
	var b:Dictionary=midnight.get("period_effects",{})
	current_effects={}
	for key in defaults:
		current_effects[key]=lerpf(float(a.get(key,defaults[key])),float(b.get(key,defaults[key])),weight)
	for key in ["mist_color","snow_color"]:
		current_effects[key]=Color(str(a[key])).lerp(Color(str(b[key])),weight).to_html(false)
	current_effects.character_fill_color=b.get("character_fill_color",[0.4,0.5,0.84])
	_apply_effects()

func _apply_effects() -> void:
	var settings:Dictionary=viewer.settings.camp
	if viewer.camp!=null:
		var fire:Node3D=viewer.camp.fire
		fire.params.light_energy=float(current_effects.get("fire_energy",settings.fire.light_energy))
		fire.fire_light.omni_range=float(current_effects.get("fire_range_u",settings.fire.light_range_u))
		fire.set_anim_time(fire.anim_t)
		viewer.camp.lantern_light.light_energy=float(current_effects.get("lantern_energy",settings.lantern.light_energy))
		viewer.camp.lantern_light.omni_range=float(current_effects.get("lantern_range_u",settings.lantern.light_range_u))
		viewer.camp.props.lantern.node.material_override.set_shader_parameter("emission_energy",float(current_effects.get("lantern_emission",settings.lantern.emission_energy)))
	if viewer.weather!=null:
		var mist_color:=Color(str(current_effects.get("mist_color",viewer.settings.weather.mist.color)))
		for material in viewer.weather.mist.materials:material.set_shader_parameter("mist_color",mist_color)
		var whiteness:float=viewer.settings.weather.snow.whiteness
		var snow_color:=Color(str(current_effects.get("snow_color","#FFFFFF"))) if current_effects.has("snow_color") else Color(whiteness,whiteness,whiteness)
		snow_color.a=float(viewer.settings.weather.snow.opacity)
		viewer.weather.snow.snow_material.albedo_color=snow_color
	character_fill.light_energy=float(current_effects.get("character_fill_energy",0.0))
	character_fill.visible=character_fill.light_energy>0.0
	var fill_color:Array=current_effects.get("character_fill_color",[1.0,1.0,1.0])
	character_fill.light_color=Color(fill_color[0],fill_color[1],fill_color[2])
	character_fill.omni_range=float(current_effects.get("character_fill_range_u",1.7))

func evidence() -> Dictionary:
	return {"period":viewer.lighting_period,"effects":current_effects,"character_fill":{"visible":character_fill.visible,"energy":character_fill.light_energy,"range_u":character_fill.omni_range,"cull_mask":character_fill.light_cull_mask},"clock_reset":false}
