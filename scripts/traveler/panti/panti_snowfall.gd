extends Node3D
## Panti-only continuous snowfall. No TIME shader or independent frame callback.
## The scene owns this node and calls freeze() with its shared motion switch.
var params:Dictionary = {}
var particles:Array[GPUParticles3D] = []
var layer_records:Array[Dictionary] = []
var frozen := false
var screen_left_world := Vector3.LEFT
var snow_material:StandardMaterial3D
var reference_size := Vector2(1920.0,1080.0)
var focal_px := 0.0

func configure(viewer:Node3D, configuration:Dictionary) -> void:
	params = configuration.duplicate(true)
	for emitter in particles:
		remove_child(emitter)
		emitter.free()
	particles.clear()
	layer_records.clear()
	name = "PantiSnowfall"
	var camera:Camera3D = viewer.camera
	var image_size:Array = params.get("reference_image_size",[1920,1080])
	reference_size = Vector2(float(image_size[0]),float(image_size[1]))
	focal_px = reference_size.y / (2.0 * tan(deg_to_rad(camera.fov) * 0.5))
	screen_left_world = -camera.global_basis.x
	screen_left_world.y = 0.0
	screen_left_world = screen_left_world.normalized()
	snow_material = _make_material()
	var layers:Array = params.get("layers",[])
	if layers.is_empty():
		push_error("Panti snowfall requires data-driven layers; no hidden particle count")
		return
	for index in layers.size():
		_build_layer(camera,layers[index],index)
	visible = bool(params.get("enabled",true))
	freeze(frozen)

func _make_material() -> StandardMaterial3D:
	# Compact disc with a narrow soft edge, not a broad blurred halo.
	var image := Image.create(32,32,false,Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var uv := (Vector2(float(x),float(y))+Vector2.ONE*0.5)/32.0
			var radius:float = (uv-Vector2.ONE*0.5).length()
			var alpha:float = 1.0-smoothstep(0.28,0.5,radius)
			image.set_pixel(x,y,Color(1.0,1.0,1.0,alpha))
	var material := StandardMaterial3D.new()
	material.resource_name = "Panti compact snowflake"
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.billboard_keep_scale = true
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	material.albedo_texture = ImageTexture.create_from_image(image)
	var white:float = clampf(float(params.get("whiteness",0.96)),0.0,1.0)
	material.albedo_color = Color(white,white,white,clampf(float(params.get("opacity",0.85)),0.0,1.0))
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	return material

func _build_layer(camera:Camera3D, layer:Dictionary, index:int) -> void:
	var depth:float = maxf(float(layer.get("depth_u",9.5)),6.5)
	var depth_half:float = clampf(float(layer.get("depth_half_u",1.25)),0.05,depth-5.5)
	var lifetime:float = maxf(float(layer.get("lifetime_s",11.0)),0.5)
	var lifetime_randomness:float = clampf(float(layer.get("lifetime_randomness",0.2)),0.0,0.8)
	var wind_speed:float = maxf(float(layer.get("wind_speed_u_s",0.28)),0.001)
	var fall_speed:float = maxf(float(layer.get("fall_speed_u_s",0.13)),0.001)
	var velocity_randomness:float = clampf(float(layer.get("velocity_randomness",0.18)),0.0,0.5)
	var world_velocity:Vector3 = screen_left_world*wind_speed+Vector3.DOWN*fall_speed
	var emitter_basis:Basis = camera.global_basis.orthonormalized()
	var local_velocity:Vector3 = emitter_basis.inverse()*world_velocity
	var half_height:float = depth*tan(deg_to_rad(camera.fov)*0.5)
	var half_width:float = half_height*reference_size.x/reference_size.y
	var margin:float = maxf(float(layer.get("frustum_margin",1.04)),1.0)
	var extents := Vector3(half_width*margin,half_height*margin,depth_half)
	var emitter := GPUParticles3D.new()
	emitter.name = "Snow_"+str(layer.get("name",str(index)))
	emitter.amount = maxi(int(layer.get("amount",1)),1)
	emitter.lifetime = lifetime
	emitter.preprocess = maxf(float(layer.get("prewarm_s",lifetime)),0.0)
	emitter.one_shot = false
	emitter.explosiveness = 0.0
	emitter.randomness = 0.0 # Even spawn intervals, with seeded spatial randomness.
	emitter.fixed_fps = int(params.get("simulation_hz",60))
	emitter.interpolate = true
	emitter.fract_delta = true
	emitter.use_fixed_seed = true
	emitter.seed = int(params.get("seed",20260920))+index*1009
	emitter.local_coords = false
	emitter.draw_order = GPUParticles3D.DRAW_ORDER_INDEX
	emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	emitter.draw_passes = 1
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = snow_material
	emitter.draw_pass_1 = quad
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = extents
	# Godot transforms initial direction/velocity by EMISSION_TRANSFORM. Express
	# the desired world-space left/down vector in this camera-aligned emitter.
	process.direction = local_velocity.normalized()
	process.spread = clampf(float(layer.get("spread_deg",5.0)),0.0,15.0)
	process.initial_velocity_min = world_velocity.length()*(1.0-velocity_randomness)
	process.initial_velocity_max = world_velocity.length()*(1.0+velocity_randomness)
	process.gravity = Vector3.ZERO # Constant slow drift from birth to disappearance.
	process.damping_min = 0.0
	process.damping_max = 0.0
	process.turbulence_enabled = false
	process.lifetime_randomness = lifetime_randomness
	var minimum_px:float = maxf(float(layer.get("size_min_px",2.0)),0.5)
	var maximum_px:float = maxf(float(layer.get("size_max_px",4.8)),minimum_px)
	process.scale_min = minimum_px*depth/focal_px
	process.scale_max = maximum_px*depth/focal_px
	var fade_in:float = clampf(float(layer.get("fade_in_fraction",0.08)),0.01,0.3)
	var fade_out:float = clampf(float(layer.get("fade_out_start_fraction",0.82)),0.5,0.99)
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0,fade_in,fade_out,1.0])
	fade.colors = PackedColorArray([Color(1,1,1,0),Color.WHITE,Color(1,1,1,0.9),Color(1,1,1,0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	process.color_ramp = ramp
	emitter.process_material = process
	# Bounds cover initial box and entire maximum drift, including spread.
	var drift:Vector3 = local_velocity*lifetime*(1.0+velocity_randomness)
	var spread_padding:float = world_velocity.length()*lifetime*sin(deg_to_rad(process.spread))
	var padding := Vector3.ONE*(spread_padding+process.scale_max)
	var low:Vector3 = -extents+Vector3.ZERO.min(drift)-padding
	var high:Vector3 = extents+Vector3.ZERO.max(drift)+padding
	emitter.visibility_aabb = AABB(low,high-low)
	add_child(emitter)
	emitter.global_transform = Transform3D(emitter_basis,camera.global_position-camera.global_basis.z*depth)
	emitter.speed_scale = 0.0 if frozen else 1.0
	emitter.emitting = bool(params.get("enabled",true))
	particles.append(emitter)
	layer_records.append({
		"name":str(emitter.name),"amount":emitter.amount,"seed":emitter.seed,
		"camera_depth_center_u":depth,"camera_depth_spawn_range_u":[depth-depth_half,depth+depth_half],
		"size_at_center_px":[minimum_px,maximum_px],"quad_world_size_u":[process.scale_min,process.scale_max],
		"size_projection_spawn_extremes_px":[minimum_px*depth/(depth+depth_half),maximum_px*depth/(depth-depth_half)],
		"world_velocity_u_s":_array(world_velocity),"direction_local":_array(process.direction),
		"screen_center_drift_px_s":{"left":-world_velocity.dot(camera.global_basis.x)*focal_px/depth,"down":-world_velocity.dot(camera.global_basis.y)*focal_px/depth},
		"lifetime_range_s":[lifetime*(1.0-lifetime_randomness),lifetime],"prewarm_s":emitter.preprocess,
		"emission_half_extents_u":_array(extents),"world_origin":_array(emitter.global_position),
		"visibility_aabb":{"position":_array(low),"size":_array(high-low)},
		"draw_passes":1,"casts_shadow":false
	})

func freeze(value:bool) -> void:
	frozen = value
	for emitter in particles:emitter.speed_scale = 0.0 if frozen else 1.0

func evidence() -> Dictionary:
	var amount := 0
	for emitter in particles:amount += emitter.amount
	return {
		"kind":"GPUParticles3D continuous sparse snow / ParticleProcessMaterial",
		"parameters":params,"enabled":visible,"frozen":frozen,
		"screen_left_world":_array(screen_left_world),"layers":layer_records,
		"allocated_particle_count":amount,"visible_particle_count":null,
		"visible_count_status":"Requires rendered measurement; allocation is not visible count",
		"reference_image_size":[int(reference_size.x),int(reference_size.y)],"focal_length_px":focal_px,
		"size_method":"Quad height = target pixels * layer camera depth / focal_length_px; spawn-depth extremes reported separately. Actual soft-dot footprint and occlusion require raster measurement.",
		"draw_passes":particles.size(),"shadow_draws":0,
		"clock":"GPU particle simulation only; shared freeze uses speed_scale=0; no TIME/turbulence shader",
		"emission":"Continuous, explosiveness=0, prewarmed; fade follows individual lifetime",
		"parented_to_camera":get_parent() is Camera3D
	}

func _array(value:Vector3) -> Array:
	return [value.x,value.y,value.z]
