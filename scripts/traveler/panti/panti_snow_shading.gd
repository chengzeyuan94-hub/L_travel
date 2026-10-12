extends RefCounted
## Panti light polish · snow surface (ported 1:1 from the approved probe, variant m4_final).
## Swaps the SnowGround StandardMaterial3D for panti_snow_surface.gdshader with the same albedo:
## wind ripples, morning sun warm/cool, glitter on the weather clock, and an un-clipped warm
## reflection lobe that reads the fire, lantern and castle spill lights' live positions and energies.
## Every shader default is written with its own type first, so an untagged vec3 multiplier stays a
## Vector3 (a Color would be sRGB-converted and inflate the ratio).
const SHADER_PATH := "res://shaders/traveler/panti/panti_snow_surface.gdshader"
const REFLECTION_SLOTS := 6
## Switches that are all 0 in the shader defaults (at 0 the shader stays within 1/255 of the original
## material; measured in docs/reports/traveler-port-20260924/panti/). Reported in evidence().
const EFFECT_SWITCHES: Array[String] = ["detail", "macro_amount", "facet_jitter", "sheen_sun", "sheen_point",
	"sun_tint_amount", "vr_strength", "vr_glit", "glit_sun", "glit_point"]

var viewer: Node3D
var cfg: Dictionary = {}
var material: ShaderMaterial
var original_material: Material
var reflection_lights: Array[Light3D] = []
var reflection_gains: Array[float] = []
var reflection_names: Array[String] = []
var enabled: bool = true

func build(stage: Node3D, config: Dictionary) -> Dictionary:
	viewer = stage
	cfg = config
	var ground: MeshInstance3D = viewer.snow_ground
	original_material = ground.material_override
	var source: StandardMaterial3D = original_material as StandardMaterial3D
	assert(source != null, "Panti snow surface expects the original SnowGround StandardMaterial3D")
	material = ShaderMaterial.new()
	material.shader = load(SHADER_PATH) as Shader
	for uniform_info: Dictionary in material.shader.get_shader_uniform_list():
		var uniform_name: String = str(uniform_info.get("name", ""))
		var default_value: Variant = RenderingServer.shader_get_parameter_default(material.shader.get_rid(), uniform_name)
		if default_value != null:
			material.set_shader_parameter(uniform_name, default_value)
	material.set_shader_parameter("albedo", source.albedo_color)
	var uniforms: Dictionary = cfg.uniforms
	for key: String in uniforms:
		material.set_shader_parameter(key, _typed(uniforms[key], material.get_shader_parameter(key)))
	# Glitter cells are locked to the frozen camera: origin, horizontal forward and angle per 1080p pixel.
	var camera: Camera3D = viewer.camera
	var forward3: Vector3 = -camera.global_basis.z
	var forward: Vector2 = Vector2(forward3.x, forward3.z).normalized()
	material.set_shader_parameter("ref_cam_pos", camera.global_position)
	material.set_shader_parameter("ref_cam_fwd", forward)
	material.set_shader_parameter("ref_rad_per_px", deg_to_rad(camera.fov) / 1080.0)
	if viewer.weather != null:
		material.set_shader_parameter("anim_t", float(viewer.weather.anim_t))
	ground.material_override = material
	for entry: Dictionary in cfg.reflection_lights:
		reflection_names.append(str(entry.light))
		reflection_lights.append(_light(str(entry.light)))
		reflection_gains.append(float(entry.gain))
	assert(reflection_lights.size() <= REFLECTION_SLOTS, "Panti snow surface has 6 reflection slots")
	return {"albedo": source.albedo_color.to_html(false), "static_uniforms": uniforms.size(), "reflection_lights": reflection_names,
		"glitter_reference": {"position": str(camera.global_position), "forward": str(forward), "rad_per_px": deg_to_rad(camera.fov) / 1080.0}}

func _light(light_id: String) -> Light3D:
	if light_id == "fire":
		return viewer.camp.fire.fire_light if viewer.camp != null else null
	if light_id == "lantern":
		return viewer.camp.lantern_light if viewer.camp != null else null
	for lamp: OmniLight3D in viewer.castle_lighting.spills:
		if str(lamp.name) == light_id:
			return lamp
	push_error("Panti snow reflection light missing: " + light_id)
	return null

## Keep the uniform's own type: Vector2 for vec2, Vector3 for an untagged vec3, Color for source_color.
func _typed(value: Variant, like: Variant) -> Variant:
	if value is Array:
		var values: Array = value
		if values.size() == 2:
			return Vector2(float(values[0]), float(values[1]))
		if like is Vector3:
			return Vector3(float(values[0]), float(values[1]), float(values[2]))
		return Color(float(values[0]), float(values[1]), float(values[2]))
	return float(value)

## Layer off (comparison, or day / sunset): the untouched original StandardMaterial3D comes back.
func apply_blend(weight: float) -> void:
	viewer.snow_ground.material_override = material if enabled else original_material
	var morning: Dictionary = cfg.morning
	var midnight: Dictionary = cfg.midnight
	for key: String in morning:
		var like: Variant = material.get_shader_parameter(key)
		var a: Variant = _typed(morning[key], like)
		var b: Variant = _typed(midnight[key], like)
		var value: Variant
		if a is Color:
			value = (a as Color).lerp(b as Color, weight)
		elif a is Vector3:
			value = (a as Vector3).lerp(b as Vector3, weight)
		else:
			value = lerpf(float(a), float(b), weight)
		material.set_shader_parameter(key, value)

## Glitter clock and reflection light feed; called from the shared weather clock.
func feed(anim_t: float) -> void:
	material.set_shader_parameter("anim_t", anim_t)
	var positions: PackedVector3Array = PackedVector3Array()
	var colors: PackedVector3Array = PackedVector3Array()
	for index: int in REFLECTION_SLOTS:
		var lamp: Light3D = reflection_lights[index] if index < reflection_lights.size() else null
		if lamp == null or not lamp.is_visible_in_tree():
			positions.append(Vector3.ZERO)
			colors.append(Vector3.ZERO)
			continue
		var linear: Color = lamp.light_color.srgb_to_linear()
		positions.append(lamp.global_position)
		colors.append(Vector3(linear.r, linear.g, linear.b) * lamp.light_energy * reflection_gains[index])
	material.set_shader_parameter("vr_pos", positions)
	material.set_shader_parameter("vr_col", colors)

func evidence() -> Dictionary:
	var switches: Dictionary = {}
	for key: String in EFFECT_SWITCHES:
		switches[key] = material.get_shader_parameter(key)
	var active_material: String = "panti_snow_surface.gdshader" if viewer.snow_ground.material_override == material else "original StandardMaterial3D"
	return {"enabled": enabled, "material": active_material, "switches": switches,
		"anim_t": material.get_shader_parameter("anim_t"), "reflection_lights": reflection_names}
