extends Node3D
## Dusk cave embers. GPU state is advanced by MotionDirector's explicit clock.

var particles: GPUParticles3D
var particles_right: GPUParticles3D
var process_material: ParticleProcessMaterial
var params: Dictionary = {}
var frozen := false
var last_time := 0.0
var emitter_local := Vector3(-0.20, 0.20, 0.20)
var right_offset_px := 120.0
var right_offset_up_px := 10.0
var emitter_global := Vector3.ZERO
var emitter_global_right := Vector3.ZERO
var wind_drift_world := Vector3.ZERO
var drift_duration_s := 0.0
var period_blend := 1.0

func configure(host: Node3D, overrides: Dictionary = {}) -> void:
	params = overrides.duplicate(true)
	name = "DuskCaveSparks"
	set_process(false)
	var buddha := host.world.get_node_or_null("CliffBuddha") as Node3D
	if buddha == null:
		push_error("Dusk cave sparks need the installed CliffBuddha node")
		return
	# Start inside the left side of the cave, behind the statue silhouette, so
	# embers read as drifting out of the grotto instead of sticking to its chest.
	var emitter := buddha.to_global(emitter_local)
	emitter_global = emitter
	global_position = emitter
	particles = GPUParticles3D.new()
	particles.name = "CaveEmbers"
	particles.amount = 24
	# Five-second maximum life; ParticleProcessMaterial.lifetime_randomness below
	# gives each ember an individual 2..5 s lifetime.
	particles.lifetime = 5.0
	# No preprocess burst; the normal emitter fills continuously from empty.
	particles.preprocess = 0.0
	particles.randomness = 0.35
	particles.explosiveness = 0.0
	particles.fixed_fps = 30
	particles.interpolate = true
	particles.fract_delta = true
	particles.use_fixed_seed = true
	particles.seed = 20260919
	particles.local_coords = false
	# This is a normal continuously emitting GPU particle system. MotionDirector's
	# shared switch pauses it through speed_scale; there is no second manual clock.
	particles.speed_scale = 1.0
	particles.draw_order = GPUParticles3D.DRAW_ORDER_INDEX
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb = AABB(Vector3(-1.2, -0.2, -1.2), Vector3(2.4, 4.0, 2.4))
	particles.draw_passes = 1
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.026, 0.026)
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color(1.0, 0.42, 0.12, 0.92)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.20, 0.03)
	material.emission_energy_multiplier = 2.6
	# Keep the ember trail readable as it crosses the dark rock face.
	material.no_depth_test = true
	mesh.material = material
	particles.draw_pass_1 = mesh
	process_material = ParticleProcessMaterial.new()
	process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process_material.emission_sphere_radius = 0.12
	# Every ember moves outward as soon as it is born. Low damping keeps that
	# motion continuous until its individual lifetime expires.
	process_material.direction = Vector3(0.65, 0.72, -0.12)
	process_material.spread = 18.0
	process_material.initial_velocity_min = 0.45
	process_material.initial_velocity_max = 0.80
	process_material.gravity = Vector3(0.0, 0.08, 0.0)
	process_material.damping_min = 0.05
	process_material.damping_max = 0.12
	process_material.lifetime_randomness = 0.60
	process_material.scale_min = 0.6
	process_material.scale_max = 1.0
	process_material.turbulence_enabled = true
	# Only a light curl remains for natural tail scatter; the previous 2.4 force
	# was several times the ember velocity and visibly formed little whirlpools.
	process_material.turbulence_noise_strength = 0.45
	process_material.turbulence_noise_scale = 2.5
	process_material.turbulence_noise_speed = Vector3(0.03, 0.12, 0.03)
	# Keep the mouth compact while the older tail picks up more turbulence.
	process_material.turbulence_influence_min = 0.08
	process_material.turbulence_influence_max = 0.22
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([Color(1.0, 0.95, 0.69, 1.0), Color(1.0, 0.61, 0.16, 0.85), Color(0.70, 0.12, 0.03, 0.0)])
	gradient.offsets = PackedFloat32Array([0.0, 0.42, 1.0])
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	process_material.color_initial_ramp = ramp
	particles.process_material = process_material
	add_child(particles)
	particles.global_position = emitter_global
	particles.emitting = true
	# Place the second mouth by screen space: exactly ~60 native pixels to the
	# right at the same camera depth and height. This avoids guessing the model's
	# local left/right axes.
	var camera := host.camera as Camera3D
	var camera_forward := -camera.global_transform.basis.z.normalized()
	var camera_right := camera.global_transform.basis.x.normalized()
	var camera_up := camera.global_transform.basis.y.normalized()
	var depth := maxf(0.1, (emitter_global - camera.global_position).dot(camera_forward))
	var viewport_aspect := 1920.0 / 1080.0
	var world_per_pixel := (2.0 * depth * tan(deg_to_rad(camera.fov) * 0.5) * viewport_aspect) / 1920.0
	var vertical_world_per_pixel := (2.0 * depth * tan(deg_to_rad(camera.fov) * 0.5)) / 1080.0
	emitter_global_right = emitter_global + camera_right * world_per_pixel * right_offset_px + camera_up * vertical_world_per_pixel * right_offset_up_px
	# top_level keeps this second emitter fixed if the component parent is ever
	# repositioned.
	particles_right = particles.duplicate() as GPUParticles3D
	particles_right.name = "CaveEmbersRight"
	particles_right.seed = particles.seed + 1
	particles_right.top_level = true
	add_child(particles_right)
	particles_right.global_position = emitter_global_right
	particles_right.emitting = true
	apply_time(0.0)

func set_period_blend(value: float, _doorway_base_energy: float = -1.0) -> void:
	period_blend=clampf(value,0.0,1.0)
	var enabled:=period_blend>0.001
	visible=enabled
	if particles!=null:
		particles.amount_ratio=period_blend
		particles.emitting=enabled
	if particles_right!=null:
		particles_right.amount_ratio=period_blend
		particles_right.emitting=enabled

func apply_time(at_time: float) -> void:
	if particles == null:
		return
	var requested := maxf(at_time, 0.0)
	# The mouth stays fixed on the Buddha's left shoulder. All visible movement is
	# produced by the ordinary continuous GPU emitter.
	global_position = emitter_global
	last_time = requested

func set_frozen(value: bool) -> void:
	frozen = value
	if particles != null:
		particles.speed_scale = 0.0 if frozen else 1.0
	if particles_right != null:
		particles_right.speed_scale = 0.0 if frozen else 1.0

func evidence() -> Dictionary:
	return {
		"schema": "silkroad.day-sparks-evidence.v1",
		"kind": "GPUParticles3D / ParticleProcessMaterial",
		"anim_t": last_time,
		"frozen": frozen,
		"period_blend": period_blend,
		"amount": particles.amount if particles != null else 0,
		"lifetime_s": particles.lifetime if particles != null else 0.0,
		"lifetime_randomness": process_material.lifetime_randomness if process_material != null else 0.0,
		"seed": particles.seed if particles != null else 0,
		"right_seed": particles_right.seed if particles_right != null else 0,
		"local_coords": particles.local_coords if particles != null else false,
		"emitter_local": [emitter_local.x, emitter_local.y, emitter_local.z],
		"right_offset_px": right_offset_px,
		"right_offset_up_px": right_offset_up_px,
		"direction": [process_material.direction.x, process_material.direction.y, process_material.direction.z] if process_material != null else [],
		"spread_deg": process_material.spread if process_material != null else 0.0,
		"initial_velocity": [process_material.initial_velocity_min, process_material.initial_velocity_max] if process_material != null else [],
		"gravity": [process_material.gravity.x, process_material.gravity.y, process_material.gravity.z] if process_material != null else [],
		"wind_drift_world": [wind_drift_world.x, wind_drift_world.y, wind_drift_world.z],
		"drift_duration_s": drift_duration_s,
		"turbulence_enabled": process_material.turbulence_enabled if process_material != null else false,
		"clock": "GPUParticles3D automatic clock; MotionDirector speed_scale freeze"
	}
