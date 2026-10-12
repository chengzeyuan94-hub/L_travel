extends Node3D
# （2026-09-23 去掉重复的 class_name PantiCampFire：与 panti_camp_fire.gd 同名，导致盘橐营火脚本加载失败；本文件按路径加载，不需要类名）

## Small, quiet camp fire for the Panti low-poly camp.
##
## The flame cards use an explicit anim_t uniform instead of TIME, so a caller
## can freeze the complete effect without resetting the visible pose. Sparks use
## the same freeze switch through GPUParticles3D.speed_scale.

const FLAME_SHADER := "res://shaders/traveler/panti/panti_camp_fire.gdshader"
const DEFAULTS := {
	"flame_height_u": 0.28,
	"flame_width_u": 0.20,
	"flame_count": 5,
	"spark_amount": 8,
	"spark_lifetime_s": 1.6,
	"spark_size_u": 0.010,
	"spark_speed_min_u_s": 0.08,
	"spark_speed_max_u_s": 0.16,
	"spark_spread_deg": 20.0,
	"light_range_u": 0.90,
	"light_energy": 0.32,
	"light_color": Color(1.0, 0.46, 0.16, 1.0),
	"light_flicker_amount": 0.07,
	"light_flicker_speed": 2.2,
	"flame_base_color": Color(1.0, 0.86, 0.58, 1.0),
	"flame_mid_color": Color(1.0, 0.36, 0.035, 1.0),
	"flame_tip_color": Color(0.92, 0.105, 0.015, 1.0),
	"spark_color": Color(1.0, 0.55, 0.13, 0.92),
	"seed": 20260920,
}

var params: Dictionary = {}
var flame_bank: MultiMeshInstance3D
var flame_material: ShaderMaterial
var sparks: GPUParticles3D
var spark_material: StandardMaterial3D
var fire_light: OmniLight3D
var anim_t := 0.0
var frozen := false
var configured := false

func _ready() -> void:
	# The parent may configure before or after adding this node to the scene.
	if not configured:
		configure({})

func configure(overrides: Dictionary = {}) -> void:
	params = DEFAULTS.duplicate(true)
	for key in overrides:
		params[key] = overrides[key]
	configured = true
	_clear_children()
	_build_flames()
	_build_sparks()
	_build_light()
	_apply_visual_state()

func _clear_children() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	flame_bank = null
	flame_material = null
	sparks = null
	spark_material = null
	fire_light = null

func _build_flames() -> void:
	var shader := load(FLAME_SHADER) as Shader
	if shader == null:
		push_error("Panti camp fire shader failed to load: "+FLAME_SHADER)
		return
	flame_material = ShaderMaterial.new()
	flame_material.shader = shader
	flame_material.set_shader_parameter("flame_base", _color_param("flame_base_color"))
	flame_material.set_shader_parameter("flame_mid", _color_param("flame_mid_color"))
	flame_material.set_shader_parameter("flame_tip", _color_param("flame_tip_color"))
	flame_material.set_shader_parameter("anim_t", anim_t)

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = flame_material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = false
	multimesh.use_custom_data = true
	var count := clampi(int(params.get("flame_count", 5)), 3, 7)
	multimesh.instance_count = count
	multimesh.mesh = quad
	flame_bank = MultiMeshInstance3D.new()
	flame_bank.name = "CampFireFlames"
	flame_bank.multimesh = multimesh
	flame_bank.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flame_bank.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(flame_bank)

	var total_height := maxf(float(params.get("flame_height_u", 0.28)), 0.05)
	var total_width := maxf(float(params.get("flame_width_u", 0.20)), 0.05)
	# Shader billboarding and the tip sway extend outside the raw quad bounds.
	flame_bank.custom_aabb = AABB(Vector3(-total_width, -0.01, -total_width), Vector3(total_width * 2.0, total_height * 1.10, total_width * 2.0))
	# The cards overlap around the same coal bed. Their union stays within the
	# requested silhouette while each card gives the shader a separate phase.
	var x_offsets := PackedFloat32Array([-0.050, -0.020, 0.014, 0.048, 0.0, -0.036, 0.034])
	var z_offsets := PackedFloat32Array([0.012, -0.010, 0.018, -0.016, 0.0, 0.006, -0.004])
	var width_factors := PackedFloat32Array([0.34, 0.43, 0.36, 0.30, 0.39, 0.31, 0.33])
	var height_factors := PackedFloat32Array([0.65, 1.0, 0.76, 0.58, 0.83, 0.68, 0.53])
	var brightness := PackedFloat32Array([0.78, 1.0, 0.84, 0.70, 0.93, 0.76, 0.87])
	for i in count:
		var width := total_width * width_factors[i % width_factors.size()]
		var height := total_height * height_factors[i % height_factors.size()]
		var x := x_offsets[i % x_offsets.size()] * (total_width / 0.20)
		var z := z_offsets[i % z_offsets.size()] * (total_width / 0.20)
		var scale := Vector3(width, height, 1.0)
		var transform := Transform3D(Basis.IDENTITY.scaled(scale), Vector3(x, height * 0.5, z))
		multimesh.set_instance_transform(i, transform)
		# x=phase, y=brightness, z=shape variation. Custom data is stable for
		# deterministic captures and does not require a second animation clock.
		multimesh.set_instance_custom_data(i, Color(float(i) / float(count), brightness[i % brightness.size()], float(i % 4) / 3.0, 1.0))

func _build_sparks() -> void:
	sparks = GPUParticles3D.new()
	sparks.name = "CampFireSparks"
	var requested_amount := clampi(int(params.get("spark_amount", 8)), 0, 24)
	sparks.amount = maxi(requested_amount, 1)
	sparks.emitting = requested_amount > 0
	sparks.visible = requested_amount > 0
	sparks.lifetime = maxf(float(params.get("spark_lifetime_s", 1.6)), 0.2)
	sparks.preprocess = 0.0
	sparks.explosiveness = 0.0
	sparks.randomness = 0.35
	sparks.fixed_fps = 30
	sparks.interpolate = true
	sparks.fract_delta = true
	sparks.use_fixed_seed = true
	sparks.seed = int(params.get("seed", 20260920))
	sparks.local_coords = true
	sparks.draw_order = GPUParticles3D.DRAW_ORDER_LIFETIME
	sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sparks.visibility_aabb = AABB(Vector3(-0.45, -0.04, -0.45), Vector3(0.90, 1.10, 0.90))
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * maxf(float(params.get("spark_size_u", 0.010)), 0.001)
	spark_material = StandardMaterial3D.new()
	spark_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	spark_material.vertex_color_use_as_albedo = true
	spark_material.albedo_color = _color_param("spark_color")
	spark_material.emission_enabled = true
	spark_material.emission = Color(1.0, 0.28, 0.03, 1.0)
	spark_material.emission_energy_multiplier = 1.8
	spark_material.no_depth_test = false
	quad.material = spark_material
	sparks.draw_pass_1 = quad
	var process_material := ParticleProcessMaterial.new()
	process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process_material.emission_sphere_radius = float(params.get("flame_width_u", 0.20)) * 0.20
	process_material.emission_shape_offset = Vector3(0.0, float(params.get("flame_height_u", 0.28)) * 0.35, 0.0)
	process_material.direction = Vector3(0.0, 1.0, 0.0)
	process_material.spread = float(params.get("spark_spread_deg", 20.0))
	process_material.initial_velocity_min = maxf(float(params.get("spark_speed_min_u_s", 0.08)), 0.0)
	process_material.initial_velocity_max = maxf(float(params.get("spark_speed_max_u_s", 0.16)), process_material.initial_velocity_min)
	process_material.gravity = Vector3(0.0, -0.018, 0.0)
	process_material.damping_min = 0.01
	process_material.damping_max = 0.04
	process_material.scale_min = 0.65
	process_material.scale_max = 1.0
	var ramp := Gradient.new()
	ramp.colors = PackedColorArray([Color(1.0, 0.94, 0.62, 1.0), Color(1.0, 0.42, 0.06, 0.65), Color(0.8, 0.12, 0.02, 0.0)])
	ramp.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	var ramp_texture := GradientTexture1D.new()
	ramp_texture.gradient = ramp
	process_material.color_ramp = ramp_texture
	sparks.process_material = process_material
	add_child(sparks)

func _build_light() -> void:
	fire_light = OmniLight3D.new()
	fire_light.name = "CampFireWarmLight"
	fire_light.light_color = _color_param("light_color")
	fire_light.position.y = float(params.get("flame_height_u", 0.28)) * 0.30
	fire_light.omni_range = clampf(float(params.get("light_range_u", 0.90)), 0.2, 1.5)
	fire_light.light_energy = maxf(float(params.get("light_energy", 0.32)), 0.0)
	fire_light.omni_attenuation = 1.35
	fire_light.light_specular = 0.0
	fire_light.shadow_enabled = false
	add_child(fire_light)

func _color_param(key: String) -> Color:
	var value = params.get(key, DEFAULTS[key])
	return value if value is Color else Color(str(value))

func _process(delta: float) -> void:
	if frozen or delta <= 0.0:
		return
	anim_t += delta
	_apply_visual_state()

func _apply_visual_state() -> void:
	if flame_material != null:
		flame_material.set_shader_parameter("anim_t", anim_t)
	if fire_light != null:
		var amount := clampf(float(params.get("light_flicker_amount", 0.07)), 0.0, 0.25)
		var speed := maxf(float(params.get("light_flicker_speed", 2.2)), 0.0)
		fire_light.light_energy = maxf(float(params.get("light_energy", 0.32)), 0.0) * (1.0 + amount * sin(anim_t * speed) + amount * 0.35 * sin(anim_t * speed * 1.73 + 1.1))
	if sparks != null:
		sparks.speed_scale = 0.0 if frozen else 1.0

func set_anim_time(value: float) -> void:
	anim_t = maxf(value, 0.0)
	_apply_visual_state()

func freeze(value: bool) -> void:
	frozen = value
	_apply_visual_state()

func set_frozen(value: bool) -> void:
	freeze(value)

func evidence() -> Dictionary:
	return {
		"schema": "silkroad.panti-camp-fire.v1",
		"frozen": frozen,
		"anim_t": anim_t,
		"flame_count": flame_bank.multimesh.instance_count if flame_bank != null and flame_bank.multimesh != null else 0,
		"flame_height_u": float(params.get("flame_height_u", 0.28)),
		"flame_width_u": float(params.get("flame_width_u", 0.20)),
		"spark_amount": int(params.get("spark_amount", 8)),
		"spark_lifetime_s": sparks.lifetime if sparks != null else 0.0,
		"light_range_u": fire_light.omni_range if fire_light != null else 0.0,
		"light_energy": fire_light.light_energy if fire_light != null else 0.0,
		"draw_passes": 2,
		"clock": "explicit anim_t plus GPUParticles3D speed_scale freeze",
	}
