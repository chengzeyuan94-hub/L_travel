extends Node3D
## Reversible A/B atmosphere motion. The review's single clock drives every
## shader and the fire light; source meshes, tree atlas and wet PBR stay intact.
const FLAME_SHADER := preload("res://shaders/traveler/baghdad/baghdad_ambient_flame.gdshader")
const WIND_UNIFORMS := """
uniform float motion_time = 0.0;
uniform float wind_base_y = 0.0;
uniform float wind_height = 5.0;
uniform float wind_amplitude = 0.105;

"""
const WIND_VERTEX := """
	// Work in world units even when the imported mesh has a tiny source scale.
	vec3 wind_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float wind_h = clamp((wind_world.y - wind_base_y) / max(wind_height, 0.001), 0.0, 1.0);
	float wind_bend = smoothstep(0.22, 0.98, wind_h);
	float wind_crown = smoothstep(0.38, 0.72, wind_h);
	float wind_t = motion_time;
	float wind_primary = 0.68 * sin(wind_t * 0.67) + 0.23 * sin(wind_t * 1.23 + 0.8) + 0.09 * sin(wind_t * 1.91 + 1.6);
	float wind_leaf = sin(wind_t * 2.1 + wind_world.x * 1.4 + wind_world.z * 0.9);
	vec3 wind_offset = vec3(
		wind_amplitude * (wind_primary * wind_bend + 0.12 * wind_leaf * wind_crown),
		0.0,
		wind_amplitude * 0.32 * sin(wind_t * 0.81 + 0.45) * wind_bend);
	VERTEX += (inverse(MODEL_MATRIX) * vec4(wind_offset, 0.0)).xyz;
"""

@export var wind_amplitude_u := 0.105
@export var fire_flicker_amount := 0.16
var tree_materials: Array[ShaderMaterial] = []
var flame_materials: Array[ShaderMaterial] = []
var motion_time := 0.0
var _saved: Array[Dictionary] = []
var _fire_light: OmniLight3D
var _original_fire_energy := 0.0
var _tree_bounds := AABB()
var _configured := false

func configure(viewer: Node3D) -> bool:
	restore()
	if viewer == null:
		return false
	var tree := viewer.get("tree") as Node3D
	if tree == null:
		push_error("BaghdadAmbientMotion needs the existing TreeOfLife")
		return false
	_tree_bounds = _world_bounds(tree)
	for mesh in _meshes(tree):
		_install_tree_motion(mesh)
	var fire := viewer.find_child("StaticCampFire", true, false) as Node3D
	if fire != null:
		var flame := fire.find_child("StaticFlameSilhouette", true, false) as MeshInstance3D
		if flame != null:
			_install_flame_motion(flame)
		_fire_light = fire.find_child("StaticFireWarmth", true, false) as OmniLight3D
		if _fire_light != null:
			_original_fire_energy = _fire_light.light_energy
	_configured = not tree_materials.is_empty() and not flame_materials.is_empty()
	set_time(0.0)
	return _configured

func set_time(seconds: float) -> void:
	motion_time = maxf(seconds, 0.0)
	for material in tree_materials:
		material.set_shader_parameter("motion_time", motion_time)
		material.set_shader_parameter("wind_amplitude", wind_amplitude_u)
	for material in flame_materials:
		material.set_shader_parameter("motion_time", motion_time)
	if is_instance_valid(_fire_light):
		var flicker := 0.58 * sin(motion_time * 4.2) + 0.27 * sin(motion_time * 7.7 + 1.1) + 0.15 * sin(motion_time * 11.3 + 0.4)
		_fire_light.light_energy = _original_fire_energy * (1.0 + fire_flicker_amount * flicker)

func set_tree_glow_strength(value: float) -> void:
	# Storm's saved material list predates the rain and wind copies. This helper
	# targets the actual displayed materials while leaving all beam masks intact.
	for material in tree_materials:
		material.set_shader_parameter("glow_strength", maxf(value, 0.0))

func evidence() -> Dictionary:
	return {"configured": _configured, "motion_time_s": motion_time,
		"tree_surfaces": tree_materials.size(), "flame_surfaces": flame_materials.size(),
		"tree_wind_amplitude_u": wind_amplitude_u, "tree_root_locked_below_height_fraction": 0.22,
		"tree_height_u": _tree_bounds.size.y, "tree_original_atlas_and_glow_uniforms_preserved": true,
		"fire_light": str(_fire_light.name) if is_instance_valid(_fire_light) else "missing",
		"fire_light_original_energy": _original_fire_energy,
		"fire_light_current_energy": _fire_light.light_energy if is_instance_valid(_fire_light) else 0.0,
		"fire_flicker_amount": fire_flicker_amount, "fire_pit_and_logs_unchanged": true,
		"clock": "explicit set_time; no TIME and no automatic process", "reversible": true}

func restore() -> void:
	for record in _saved:
		var mesh := record.mesh as MeshInstance3D
		if not is_instance_valid(mesh):
			continue
		mesh.material_override = record.material_override
		mesh.extra_cull_margin = float(record.extra_cull_margin)
		var surfaces: Array = record.surfaces
		for index in mini(surfaces.size(), mesh.mesh.get_surface_count()):
			mesh.set_surface_override_material(index, surfaces[index])
	if is_instance_valid(_fire_light):
		_fire_light.light_energy = _original_fire_energy
	_saved.clear()
	tree_materials.clear()
	flame_materials.clear()
	_fire_light = null
	_configured = false

func _install_tree_motion(mesh: MeshInstance3D) -> void:
	var replacements: Array[Material] = []
	var changed := false
	for index in mesh.mesh.get_surface_count():
		var active := mesh.get_active_material(index)
		var source := active as ShaderMaterial
		if source == null or source.shader == null or not source.shader.code.contains("uniform float glow_strength"):
			replacements.append(active)
			continue
		var source_code := source.shader.code
		if not source_code.contains("void vertex() {"):
			replacements.append(active)
			continue
		var shader := Shader.new()
		shader.code = source_code.replace("void vertex() {", WIND_UNIFORMS + "void vertex() {\n" + WIND_VERTEX)
		var material := source.duplicate() as ShaderMaterial
		material.shader = shader
		for uniform in source.shader.get_shader_uniform_list():
			var uniform_name := StringName(uniform.name)
			material.set_shader_parameter(uniform_name, source.get_shader_parameter(uniform_name))
		material.set_shader_parameter("wind_base_y", _tree_bounds.position.y)
		material.set_shader_parameter("wind_height", _tree_bounds.size.y)
		material.set_shader_parameter("wind_amplitude", wind_amplitude_u)
		tree_materials.append(material)
		replacements.append(material)
		changed = true
	if changed:
		_save_mesh(mesh)
		mesh.material_override = null
		for index in replacements.size():
			mesh.set_surface_override_material(index, replacements[index])
		var scales := mesh.global_basis.get_scale().abs()
		var minimum_scale := maxf(minf(scales.x, minf(scales.y, scales.z)), 0.000001)
		mesh.extra_cull_margin += wind_amplitude_u * 1.5 / minimum_scale

func _install_flame_motion(mesh: MeshInstance3D) -> void:
	if mesh.mesh == null:
		return
	var source := mesh.get_active_material(0) as StandardMaterial3D
	if source == null:
		return
	_save_mesh(mesh)
	var bounds := mesh.mesh.get_aabb()
	var material := ShaderMaterial.new()
	material.shader = FLAME_SHADER
	material.set_shader_parameter("base_tint", source.albedo_color)
	material.set_shader_parameter("vertex_color_srgb", source.vertex_color_is_srgb)
	material.set_shader_parameter("source_emission", source.emission)
	material.set_shader_parameter("source_emission_energy", source.emission_energy_multiplier if source.emission_enabled else 0.0)
	material.set_shader_parameter("flame_bottom", bounds.position.y)
	material.set_shader_parameter("flame_height", maxf(bounds.size.y, 0.001))
	material.set_shader_parameter("flame_width", maxf(bounds.size.x, bounds.size.z))
	mesh.material_override = material
	mesh.extra_cull_margin += bounds.size.y * 0.25
	flame_materials.append(material)

func _save_mesh(mesh: MeshInstance3D) -> void:
	var surfaces: Array[Material] = []
	for index in mesh.mesh.get_surface_count():
		surfaces.append(mesh.get_surface_override_material(index))
	_saved.append({"mesh": mesh, "material_override": mesh.material_override,
		"surfaces": surfaces, "extra_cull_margin": mesh.extra_cull_margin})

func _meshes(root: Node3D) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if root is MeshInstance3D and root.mesh != null:
		result.append(root)
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.mesh != null:
			result.append(mesh)
	return result

func _world_bounds(root: Node3D) -> AABB:
	var bounds := AABB()
	var first := true
	for mesh in _meshes(root):
		var box := mesh.global_transform * mesh.mesh.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	return bounds

func _exit_tree() -> void:
	restore()
