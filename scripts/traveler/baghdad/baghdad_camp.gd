extends Node3D
## Foreground props for the independent Panti stage; all layout comes from JSON.
var viewer:Node3D
var settings:Dictionary
var props:Dictionary={}
var records:Array=[]
var fire:Node3D
var lantern_light:OmniLight3D
var seat_world:=Vector3.ZERO

func configure(owner_viewer:Node3D) -> void:
	viewer=owner_viewer
	settings=viewer.settings.camp
	name="CampRoot"
	position=viewer.stage_point(viewer.vec(settings.root_stage))
	for prop in settings.props:
		var resource:Dictionary=viewer.asset(str(prop.asset))
		var instance:=MeshInstance3D.new()
		instance.name=str(prop.id).capitalize();instance.mesh=resource.mesh
		var axis:int={"x":0,"y":1,"z":2}[str(prop.size_axis)]
		var scale_u:float=float(prop.size_u)/resource.bounds.size[axis]
		instance.scale=Vector3.ONE*scale_u
		instance.rotation.y=float(viewer.motion_params._measured.traveler_camera.azimuth_rad)+deg_to_rad(float(prop.yaw_deg))
		add_child(instance)
		var stage:Vector3=viewer.vec(settings.root_stage)+viewer.vec(prop.offset_stage)
		var support:float=viewer.snow_surface.height_at(Vector2(stage.x,stage.z))
		stage.y=support-float(prop.bury_u)
		instance.global_position=viewer.stage_point(stage)
		if prop.get("mount","")=="stump":
			var host:Dictionary=props.stump
			var fraction:Array=prop.mount_fraction
			instance.global_position=host.node.global_transform*Vector3(host.resource.bounds.size.x*fraction[0],host.resource.bounds.size.y*fraction[1],host.resource.bounds.size.z*fraction[2])
		props[str(prop.id)]={"node":instance,"resource":resource,"scale_u":scale_u,"stage":stage}
		records.append({"id":prop.id,"source":prop.asset,"triangles":resource.triangles,"stage_position_u":[stage.x,stage.y,stage.z],"scale_u":scale_u,"support_y":support,"bury_u":prop.bury_u})
	var stump:Dictionary=props.stump
	var seat:Array=settings.seat.stump_local_fraction
	seat_world=stump.node.global_transform*Vector3(stump.resource.bounds.size.x*float(seat[0]),stump.resource.bounds.size.y*float(seat[1]),stump.resource.bounds.size.z*float(seat[2]))
	build_lantern()
	build_fire()

func build_lantern() -> void:
	var entry:Dictionary=props.lantern
	var material:=ShaderMaterial.new()
	material.shader=load("res://shaders/traveler/panti/camp_lantern.gdshader")
	material.set_shader_parameter("basecolor",entry.resource.material.albedo_texture)
	material.set_shader_parameter("emission_energy",float(settings.lantern.emission_energy))
	entry.node.material_override=material
	lantern_light=OmniLight3D.new();lantern_light.name="LanternWarmth"
	lantern_light.light_color=Color(settings.lantern.light_color[0],settings.lantern.light_color[1],settings.lantern.light_color[2])
	lantern_light.light_energy=float(settings.lantern.light_energy)
	lantern_light.omni_range=float(settings.lantern.light_range_u)
	lantern_light.shadow_enabled=false
	add_child(lantern_light)
	lantern_light.global_position=entry.node.global_position+Vector3.UP*entry.resource.bounds.size.y*float(entry.scale_u)*0.43

func build_fire() -> void:
	var entry:Dictionary=props.firepit
	fire=load("res://scripts/traveler/baghdad/baghdad_camp_fire.gd").new()
	fire.configure(settings.fire)
	add_child(fire)
	fire.global_position=entry.node.global_position+Vector3.UP*entry.resource.bounds.size.y*float(entry.scale_u)*0.70

func evidence() -> Dictionary:
	var measurements:Array=[]
	for record in records:
		var item:Dictionary=record.duplicate(true)
		item["projection"]=viewer.projected_bounds(props[str(record.id)].node)
		var pos:Vector3=props[str(record.id)].node.global_position
		item["world_position_u"]=[pos.x,pos.y,pos.z]
		measurements.append(item)
	var seat:Vector2=viewer.camera.unproject_position(seat_world)
	return {"enabled":true,"props":measurements,"seat_screen_px":[seat.x,seat.y],"seat_world_u":[seat_world.x,seat_world.y,seat_world.z],"settings":settings,"fire":fire.evidence() if fire.has_method("evidence") else {}}
