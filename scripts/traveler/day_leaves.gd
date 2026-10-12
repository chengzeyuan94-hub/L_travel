extends Node3D
## S6: world-volume leaves, advanced only by the shared MotionDirector clock.
var particles: GPUParticles3D
var process_material: ParticleProcessMaterial
var leaf_material: ShaderMaterial
var params: Dictionary
var frozen := false
var last_time := 0.0
var camera_at_install: Transform3D

func vector(value: Array) -> Vector3:
	return Vector3(float(value[0]),float(value[1]),float(value[2]))

func configure(host: Node3D, settings: Dictionary) -> void:
	params=settings.duplicate(true)
	name="DayLeaves"
	set_process(false)
	var camera: Camera3D=host.camera
	camera_at_install=camera.global_transform
	var right := camera.global_basis.x
	right.y=0.0
	right=right.normalized()
	var backward := right.cross(Vector3.UP).normalized()
	var center := camera.global_position-camera.global_basis.z*float(params.emitter.camera_depth_u)
	center+=Vector3.UP*float(params.emitter.height_above_camera_ray_u)+right*float(params.emitter.horizontal_offset_u)
	global_transform=Transform3D(Basis(right,Vector3.UP,backward),center)
	particles=GPUParticles3D.new()
	particles.name="FallingLeaves"
	particles.amount=int(params.amount)
	particles.amount_ratio=float(params.amount_ratio)
	particles.lifetime=float(params.lifetime_s)
	particles.preprocess=float(params.preprocess_s)
	particles.randomness=float(params.randomness)
	particles.explosiveness=float(params.explosiveness)
	particles.fixed_fps=int(params.fixed_fps)
	particles.interpolate=bool(params.interpolate)
	particles.fract_delta=bool(params.fract_delta)
	particles.use_fixed_seed=true
	particles.seed=int(params.seed)
	particles.local_coords=false
	particles.speed_scale=0.0
	particles.draw_order=GPUParticles3D.DRAW_ORDER_INDEX
	particles.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb=AABB(vector(params.render.visibility_aabb_position_u),vector(params.render.visibility_aabb_size_u))
	particles.draw_passes=1
	leaf_material=ShaderMaterial.new()
	leaf_material.shader=load("res://shaders/traveler/day_leaf.gdshader")
	leaf_material.set_shader_parameter("clear_depth_near",float(params.render.clear_depth_clip_u[0]))
	leaf_material.set_shader_parameter("clear_depth_far",float(params.render.clear_depth_clip_u[1]))
	leaf_material.set_shader_parameter("leaf_roughness",float(params.render.roughness))
	leaf_material.set_shader_parameter("leaf_specular",float(params.render.specular))
	var mesh := leaf_mesh()
	mesh.surface_set_material(0,leaf_material)
	particles.draw_pass_1=mesh
	process_material=ParticleProcessMaterial.new()
	process_material.emission_shape=ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process_material.emission_box_extents=vector(params.emitter.half_extents_u)
	process_material.direction=vector(params.motion.direction).normalized()
	process_material.spread=float(params.motion.spread_deg)
	process_material.initial_velocity_min=float(params.motion.initial_velocity_u_per_s[0])
	process_material.initial_velocity_max=float(params.motion.initial_velocity_u_per_s[1])
	process_material.gravity=vector(params.motion.gravity_u_per_s2)
	process_material.damping_min=float(params.motion.damping[0])
	process_material.damping_max=float(params.motion.damping[1])
	process_material.angle_min=float(params.motion.initial_angle_deg[0])
	process_material.angle_max=float(params.motion.initial_angle_deg[1])
	process_material.use_rotation_velocity_3d=true
	process_material.rotation_velocity_3d_min=vector(params.motion.rotation_velocity_3d_min_deg_per_s)
	process_material.rotation_velocity_3d_max=vector(params.motion.rotation_velocity_3d_max_deg_per_s)
	process_material.scale_min=float(params.mesh.scale[0])
	process_material.scale_max=float(params.mesh.scale[1])
	process_material.lifetime_randomness=float(params.lifetime_randomness)
	process_material.turbulence_enabled=bool(params.turbulence.enabled)
	process_material.turbulence_noise_strength=float(params.turbulence.noise_strength)
	process_material.turbulence_noise_scale=float(params.turbulence.noise_scale)
	process_material.turbulence_noise_speed=vector(params.turbulence.noise_speed)
	process_material.turbulence_noise_speed_random=float(params.turbulence.noise_speed_random)
	process_material.turbulence_influence_min=float(params.turbulence.influence[0])
	process_material.turbulence_influence_max=float(params.turbulence.influence[1])
	process_material.turbulence_initial_displacement_min=float(params.turbulence.initial_displacement[0])
	process_material.turbulence_initial_displacement_max=float(params.turbulence.initial_displacement[1])
	var gradient := Gradient.new()
	var colors := PackedColorArray()
	var offsets := PackedFloat32Array()
	for index in params.colors.size():
		colors.append(Color(params.colors[index]))
		offsets.append(float(index)/float(params.colors.size()))
	gradient.colors=colors
	gradient.offsets=offsets
	gradient.interpolation_mode=Gradient.GRADIENT_INTERPOLATE_CONSTANT
	var ramp := GradientTexture1D.new()
	ramp.gradient=gradient
	process_material.color_initial_ramp=ramp
	particles.process_material=process_material
	add_child(particles)
	particles.emitting=true

func leaf_mesh() -> ArrayMesh:
	var h := float(params.mesh.height_u)*0.5
	var w := float(params.mesh.width_u)*0.5
	var fold := float(params.mesh.fold_u)
	var points := [Vector3(0,h,0),Vector3(-w,0,0),Vector3(0,-h,0),Vector3(w,0,0)]
	var center := Vector3(0,0,fold)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_color(Color.WHITE)
	for index in points.size():
		for vertex in [center,points[index],points[(index+1)%points.size()]]:
			surface.add_vertex(vertex)
	surface.generate_normals()
	return surface.commit()

func apply_time(at_time: float) -> void:
	if particles==null or frozen:return
	var requested_time := maxf(0.0,at_time)
	if requested_time<last_time-0.000001:
		# Deterministic rewind: the same seed and preprocessing recreate t=0.
		particles.restart(true)
		if requested_time>0.0:particles.request_particles_process(requested_time)
	elif requested_time>last_time:
		# Engine manual processing ignores speed_scale while servicing this request.
		particles.request_particles_process(requested_time-last_time)
	last_time=requested_time

func set_frozen(value: bool) -> void:
	frozen=value
	if particles!=null:particles.speed_scale=0.0

func set_diagnostic_mask(enabled: bool) -> void:
	leaf_material.set_shader_parameter("diagnostic_mask",enabled)

func evidence() -> Dictionary:
	return {"kind":"GPUParticles3D / ParticleProcessMaterial","parameters":params,"amount":particles.amount,"amount_ratio":particles.amount_ratio,"world_origin":[global_position.x,global_position.y,global_position.z],"parent":str(get_parent().get_path()) if get_parent()!=null else "","camera_parented":get_parent() is Camera3D,"local_coords":particles.local_coords,"speed_scale":particles.speed_scale,"turbulence_enabled":process_material.turbulence_enabled,"frozen":frozen,"anim_t":last_time,"seed":particles.seed,"triangle_count":4*particles.amount,"draw_passes":particles.draw_passes,"manual_clock":"request_particles_process; stationary spatial curl eliminates shader global TIME; no autonomous _process","size_measurement":"Use set_diagnostic_mask(true), black occluders, fixed camera/DOF; connected-component native-pixel bbox heights. Measure original leaf visibility separately from all-white diagnostic."}
