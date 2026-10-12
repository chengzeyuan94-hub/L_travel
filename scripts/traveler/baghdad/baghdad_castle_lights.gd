extends Node3D
## The original fortress texture/mesh stay intact. A separate mask lights only
## existing narrow window interiors; a few warm pools reach nearby masonry/snow.
var viewer:Node3D
var settings:Dictionary={}
var lit_material:StandardMaterial3D
var original_material:Material
var original_material_override:Material
var spills:Array[OmniLight3D]=[]
var night_enabled:=false
var night_weight:=0.0
var anim_time:=0.0

func configure(owner_viewer:Node3D,parameters:Dictionary={}) -> void:
	viewer=owner_viewer
	settings=parameters
	if settings.is_empty():
		settings=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/panti_castle_lights.json"))
	name="PantiCastleLights"
	assert(viewer.castle!=null,"Castle lights require the already built fortress")
	original_material=viewer.castle.get_active_material(0)
	original_material_override=viewer.castle.material_override
	assert(original_material is StandardMaterial3D,"Preserve original fortress material type")
	lit_material=original_material.duplicate() as StandardMaterial3D
	var emission:Dictionary=settings.window_emission
	lit_material.emission_enabled=true
	lit_material.emission=Color(str(emission.color))
	lit_material.emission_energy_multiplier=float(emission.energy)
	lit_material.emission_texture=load(str(emission.texture)) as Texture2D
	assert(lit_material.emission_texture!=null,"Missing castle window mask")
	lit_material.emission_operator=BaseMaterial3D.EMISSION_OP_MULTIPLY
	var spill:Dictionary=settings.spill
	for record:Dictionary in spill.anchors:
		var lamp:=OmniLight3D.new()
		lamp.name=str(record.id)
		var coordinates:Array=record.castle_local_position
		var surface_point:Vector3=viewer.castle.to_global(Vector3(float(coordinates[0]),float(coordinates[1]),float(coordinates[2])))
		var outward:Vector3=(viewer.camera.global_position-surface_point).normalized()
		add_child(lamp)
		lamp.global_position=surface_point+outward*float(record.camera_offset_u)
		lamp.light_color=Color(str(spill.color))
		lamp.light_energy=float(record.energy)
		lamp.omni_range=float(record.range_u)
		lamp.omni_attenuation=float(spill.attenuation)
		lamp.shadow_enabled=bool(spill.shadow_enabled)
		spills.append(lamp)
	set_period(str(viewer.lighting_period))

func set_period(period:String) -> void:
	set_night_enabled(period in settings.get("enabled_periods",["midnight"]))

func set_night_enabled(enabled:bool) -> void:
	set_night_weight(1.0 if enabled else 0.0)

func set_night_weight(weight:float) -> void:
	night_weight=clampf(weight,0.0,1.0)
	night_enabled=night_weight>0.0
	visible=night_enabled
	# The viewer supplies its shared eight-second transition weight. No separate
	# tween or process clock can keep a light moving while weather is frozen.
	viewer.castle.material_override=lit_material if night_enabled else original_material_override
	apply_lighting()

func set_anim_time(time_s:float) -> void:
	anim_time=time_s
	apply_lighting()

func breath_multiplier(breath:Dictionary) -> float:
	var period:float=maxf(float(breath.get("period_s",6.0)),0.001)
	var amplitude:float=clampf(float(breath.get("amplitude",0.0)),0.0,0.95)
	var phase:float=float(breath.get("phase_rad",0.0))
	return 1.0+amplitude*sin(TAU*anim_time/period+phase)

func apply_lighting() -> void:
	if lit_material==null:return
	var emission:Dictionary=settings.window_emission
	lit_material.emission_energy_multiplier=float(emission.energy)*night_weight*breath_multiplier(emission.get("breath",{}))
	for index in range(spills.size()):
		var record:Dictionary=settings.spill.anchors[index]
		spills[index].light_energy=float(record.energy)*night_weight*breath_multiplier(record.get("breath",{}))

func evidence() -> Dictionary:
	var positions:Array=[]
	for index in range(spills.size()):
		var lamp:OmniLight3D=spills[index]
		var record:Dictionary=settings.spill.anchors[index]
		var screen:Vector2=viewer.camera.unproject_position(lamp.global_position)
		positions.append({"name":lamp.name,"world_position":[lamp.global_position.x,lamp.global_position.y,lamp.global_position.z],"screen_px":[screen.x,screen.y],"energy":lamp.light_energy,"base_energy":float(record.energy),"breath":record.get("breath",{}),"range_u":lamp.omni_range,"shadows":lamp.shadow_enabled})
	return {"enabled":night_enabled,"night_weight":night_weight,"shared_anim_time_s":anim_time,"window_count":int(settings.window_emission.window_count),"emission_energy":lit_material.emission_energy_multiplier,"base_emission_energy":float(settings.window_emission.energy),"window_breath":settings.window_emission.get("breath",{}),"emission_mask":str(settings.window_emission.texture),"spill_lights":positions,"extra_window_geometry":0,"extra_window_draw_calls":0,"original_mesh_and_albedo_preserved":true,"time_dependent":true,"clock_source":"viewer supplies shared weather.anim_t; no independent process, tween or shader TIME","transition":settings.get("transition",{}),"configuration":"res://data/traveler/panti_castle_lights.json"}
