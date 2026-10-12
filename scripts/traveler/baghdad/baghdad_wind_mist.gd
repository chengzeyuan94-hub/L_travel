extends Node3D
# （2026-09-23 去掉重复的 class_name PantiWindMist：与 panti_wind_mist.gd 同名，导致盘橐白雾脚本加载失败；本文件按路径加载，不需要类名）

## Sparse world-space ribbons. The two depth bands keep mist behind the camp
## and let the castle occlude the farther forest band through normal depth tests.
const MIST_SHADER := "res://shaders/traveler/panti/panti_wind_mist.gdshader"
const DEFAULTS := {
	"enabled": true,
	"seed": 2026092027,
	"density": 1.0,
	"lifetime_s": 12.0,
	"lifetime_randomness": 0.25,
	"preprocess_s": 14.0,
	"speed_min_u_s": 0.15,
	"speed_max_u_s": 0.27,
	"spread_deg": 2.0,
	"width_px": [170.0, 370.0],
	"height_px": 68.0,
	"reference_image_size": [1920.0, 1080.0],
	"alpha": 0.19,
	"color": Color(0.96, 0.985, 1.0, 1.0),
	"bands": [
		{"id": "snow_midground", "center_stage": [-2.65, 0.46, -7.0], "amount": 7,
		 "half_width_frame": 0.70, "half_height_u": 0.20, "half_depth_u": 1.5, "alpha_scale": 0.79},
		{"id": "forest_lower_edge", "center_stage": [-2.65, 1.1, 11.0], "amount": 9,
		 "half_width_frame": 0.69, "half_height_u": 0.43, "half_depth_u": 3.0, "alpha_scale": 1.0},
	],
}

var params: Dictionary = {}
var emitters: Array[GPUParticles3D] = []
var materials: Array[ShaderMaterial] = []
var measured_bands: Array[Dictionary] = []
var world_wind := Vector3.LEFT
var frozen := false
var anim_t := 0.0

func configure(viewer: Node3D, overrides: Dictionary = {}) -> void:
	params = DEFAULTS.duplicate(true)
	for key in overrides:
		params[key] = overrides[key]
	for child in get_children():
		remove_child(child)
		child.queue_free()
	emitters.clear()
	materials.clear()
	measured_bands.clear()
	var camera: Camera3D = viewer.camera
	var right := camera.global_basis.x
	right.y = 0.0
	right = right.normalized()
	world_wind = -right
	var emitter_basis := Basis(right, Vector3.UP, right.cross(Vector3.UP))
	var shader := load(MIST_SHADER) as Shader
	if shader == null:
		push_error("Panti mist shader failed to load: " + MIST_SHADER)
		return
	var bands: Array = params.get("bands", DEFAULTS.bands)
	for index in bands.size():
		_build_band(viewer, camera, emitter_basis, shader, bands[index], index)
	_apply_freeze()

func _build_band(viewer: Node3D, camera: Camera3D, emitter_basis: Basis,
		shader: Shader, band: Dictionary, index: int) -> void:
	var center: Array = band.center_stage
	var world_center: Vector3 = viewer.stage_point(Vector3(center[0], center[1], center[2]))
	var depth := maxf((world_center - camera.global_position).dot(-camera.global_basis.z), 1.0)
	var reference: Array = params.reference_image_size
	var units_per_pixel := 2.0 * depth * tan(deg_to_rad(camera.fov) * 0.5) / float(reference[1])
	var frame_width := units_per_pixel * float(reference[0])
	var width_range: Array = params.width_px
	var width := float(width_range[1]) * units_per_pixel
	var height := float(params.height_px) * units_per_pixel
	var half_width := frame_width * float(band.get("half_width_frame", 0.7))
	var half_height := float(band.get("half_height_u", 0.25))
	var half_depth := float(band.get("half_depth_u", 1.5))
	var particles := GPUParticles3D.new()
	particles.name = "Mist_" + str(band.get("id", index))
	particles.amount = maxi(roundi(float(band.get("amount", 7)) * float(params.density)), 1)
	particles.lifetime = clampf(float(params.lifetime_s), 8.0, 14.0)
	particles.preprocess = maxf(float(params.preprocess_s), particles.lifetime)
	particles.explosiveness = 0.0
	particles.randomness = 0.25
	particles.one_shot = false
	particles.local_coords = false
	particles.fixed_fps = 30
	particles.interpolate = true
	particles.fract_delta = true
	particles.use_fixed_seed = true
	particles.seed = int(params.seed) + index * 7919
	particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	particles.emitting = bool(params.enabled) and float(params.density) > 0.0
	particles.visible = particles.emitting
	var travel := float(params.speed_max_u_s) * particles.lifetime
	particles.visibility_aabb = AABB(
		Vector3(-half_width - travel - width, -half_height - height, -half_depth - width),
		Vector3(half_width * 2.0 + travel + width * 2.0, half_height * 2.0 + height * 2.0, half_depth * 2.0 + width * 2.0))
	var process_material := ParticleProcessMaterial.new()
	process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process_material.emission_box_extents = Vector3(half_width, half_height, half_depth)
	# The emitter's X axis is the camera's horizontal right vector. Particle
	# motion is transformed into world space once, and never follows the camera.
	process_material.direction = Vector3.LEFT
	process_material.spread = float(params.spread_deg)
	process_material.initial_velocity_min = float(params.speed_min_u_s)
	process_material.initial_velocity_max = float(params.speed_max_u_s)
	process_material.gravity = Vector3.ZERO
	process_material.damping_min = 0.0
	process_material.damping_max = 0.0
	process_material.lifetime_randomness = clampf(float(params.lifetime_randomness), 0.0, 0.33)
	process_material.scale_min = float(width_range[0]) / float(width_range[1])
	process_material.scale_max = 1.0
	process_material.anim_offset_min = 0.0
	process_material.anim_offset_max = 1.0
	process_material.anim_speed_min = 0.0
	process_material.anim_speed_max = 0.0
	particles.process_material = process_material
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("anim_t", anim_t)
	material.set_shader_parameter("opacity", float(params.alpha) * float(band.get("alpha_scale", 1.0)))
	var tint = params.color
	material.set_shader_parameter("mist_color", tint if tint is Color else Color(str(tint)))
	var quad := QuadMesh.new()
	quad.size = Vector2(width, height)
	quad.material = material
	particles.draw_pass_1 = quad
	add_child(particles)
	particles.global_transform = Transform3D(emitter_basis, world_center)
	emitters.append(particles)
	materials.append(material)
	measured_bands.append({
		"id": str(band.get("id", index)), "amount": particles.amount,
		"center_stage": center, "camera_depth_u": depth,
		"nominal_width_px": width_range, "nominal_height_px": [float(params.height_px) * process_material.scale_min, float(params.height_px)],
		"quad_size_u": [width, height], "emission_half_extents_u": [half_width, half_height, half_depth],
		"opacity_cap": float(params.alpha) * float(band.get("alpha_scale", 1.0)),
		"speed_px_s_at_center": [float(params.speed_min_u_s) / units_per_pixel, float(params.speed_max_u_s) / units_per_pixel],
	})

func _process(delta: float) -> void:
	if frozen:
		return
	anim_t += delta
	for material in materials:
		material.set_shader_parameter("anim_t", anim_t)

func set_anim_time(value: float) -> void:
	anim_t = maxf(value, 0.0)
	for material in materials:
		material.set_shader_parameter("anim_t", anim_t)

func freeze(value: bool) -> void:
	frozen = value
	_apply_freeze()

func set_frozen(value: bool) -> void:
	freeze(value)

func _apply_freeze() -> void:
	for particles in emitters:
		particles.speed_scale = 0.0 if frozen else 1.0

func evidence() -> Dictionary:
	return {
		"schema": "silkroad.panti-wind-mist.v1", "frozen": frozen,
		"anim_t": anim_t, "world_wind": [world_wind.x, world_wind.y, world_wind.z],
		"params": params.duplicate(true), "bands": measured_bands.duplicate(true),
		"draw_passes": emitters.size(), "local_coords": false,
		"emission": "continuous staggered release; prewarmed; lifetime fade in and out",
		"occlusion": "snow band behind foreground camp; forest band behind castle; normal depth testing",
	}
