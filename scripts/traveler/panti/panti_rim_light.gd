extends RefCounted
## Panti light polish · rim light. Additive screen-space depth-edge passes hung on existing
## materials as next_pass (ported 1:1 from the approved probe, variant m4_final):
##   cedars    SnowCedars_* wind material  -> panti_rim_edge_tree.gdshader, one pass per tier (gain per tier)
##   castle    fortress surface material + castle_lighting.lit_material -> one panti_rim_edge.gdshader pass
##   rocks     SnowRocks_* mesh surface materials -> one panti_rim_edge.gdshader pass
##   props     Tent / Stump / Banner -> material_override copy carrying one panti_rim_edge.gdshader pass
##             (only material_override, never a surface override as well: both at once leaves 8 engine
##             "Parameter material is null" errors at exit)
##   character PantiSeatedBody surface override -> panti_rim_character.gdshader (render_priority 1)
## Period values blend by the transition weight in apply_blend(); rim brightness follows the straight
## line between the two endpoints with a small mid-transition dip, so no in-between frame is brighter
## than both ends. sync() keeps sun_dir_world (main-light gate) and the cedar wind clock aligned.
const EDGE_SHADER := "res://shaders/traveler/panti/panti_rim_edge.gdshader"
const TREE_SHADER := "res://shaders/traveler/panti/panti_rim_edge_tree.gdshader"
const CHARACTER_SHADER := "res://shaders/traveler/panti/panti_rim_character.gdshader"
const WIND_SHADER := "res://shaders/traveler/panti/panti_tree_wind.gdshader"
const WIND_KEYS: Array[String] = ["uv_scale", "uv_offset", "wind_enabled", "anim_t", "wind_world", "mesh_bottom_y",
	"mesh_height", "tip_displacement_ratio", "gust_period_s", "sway_period_s", "gust_weight", "rest_bend_ratio",
	"bend_exponent", "root_lock_fraction", "crown_ripple_ratio", "crown_layers"]
const RESERVED: Array[String] = ["gain", "gain_night", "nodes"]

var viewer: Node3D
var cfg: Dictionary = {}
var passes: Array[ShaderMaterial] = []
var tree_passes: Array[ShaderMaterial] = []
var edge_passes: Array[ShaderMaterial] = []
var character_pass: ShaderMaterial
var tree_pairs: Array[Dictionary] = []
var enabled: bool = true
var last_curve: Dictionary = {}
var built: Dictionary = {}

func build(stage: Node3D, config: Dictionary) -> Dictionary:
	viewer = stage
	cfg = config
	var sun_dir: Vector3 = viewer.sun.global_basis.z.normalized()
	var edge_shader: Shader = load(EDGE_SHADER) as Shader
	var tree_shader: Shader = load(TREE_SHADER) as Shader
	var character_shader: Shader = load(CHARACTER_SHADER) as Shader
	_check_wind_copy(tree_shader)
	var classes: Dictionary = cfg.classes
	built["trees"] = _trees(tree_shader, classes.trees, sun_dir)
	built["castle"] = _castle(edge_shader, classes.castle, sun_dir)
	built["rocks"] = _rocks(edge_shader, classes.rocks, sun_dir)
	built["props"] = _props(edge_shader, classes.props, sun_dir)
	built["character"] = _character(character_shader, cfg.character, sun_dir)
	built["passes"] = passes.size()
	return built

## The cedar rim pass must deform exactly like the cedar itself. Its vertex() carries a verbatim copy
## of panti_tree_wind.gdshader vertex(); refuse silently drifting copies.
func _check_wind_copy(tree_shader: Shader) -> void:
	var wind_code: String = (load(WIND_SHADER) as Shader).code
	var head: String = "void vertex() {\n"
	var start: int = wind_code.find(head)
	var stop: int = wind_code.find("\n}\n", start)
	var body: String = wind_code.substr(start + head.length(), stop - start - head.length()) if start >= 0 and stop > start else ""
	if body.is_empty() or not tree_shader.code.contains(body):
		push_error("panti_rim_edge_tree.gdshader wind vertex() no longer matches panti_tree_wind.gdshader")

func _make(shader: Shader, spec: Dictionary, key: String, sun_dir: Vector3) -> ShaderMaterial:
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("sun_dir_world", sun_dir)
	material.set_shader_parameter("main_gate", float(cfg.main_gate))
	var day_gain: float = _gain(spec, "gain", key)
	material.set_shader_parameter("gain_day", day_gain)
	material.set_shader_parameter("gain_night", _gain(spec, "gain_night", key) if spec.has("gain_night") else day_gain)
	for uniform_name: String in spec.keys():
		if uniform_name in RESERVED:
			continue
		material.set_shader_parameter(uniform_name, float(spec[uniform_name]))
	passes.append(material)
	return material

func _gain(spec: Dictionary, field: String, key: String) -> float:
	var value: Variant = spec.get(field, 1.0)
	if value is Dictionary:
		return float((value as Dictionary).get(key, 1.0))
	return float(value)

func _trees(shader: Shader, spec: Dictionary, sun_dir: Vector3) -> Dictionary:
	var result: Dictionary = {}
	for item: Node in viewer.world.find_children("SnowCedars_*", "MultiMeshInstance3D", true, false):
		var node: MultiMeshInstance3D = item as MultiMeshInstance3D
		var main: ShaderMaterial = node.material_override as ShaderMaterial
		if main == null:
			push_error("Panti cedar rim needs the tree wind material on " + str(node.name))
			continue
		var tier: String = str(node.name).trim_prefix("SnowCedars_")
		var pass_material: ShaderMaterial = _make(shader, spec, tier, sun_dir)
		for key: String in WIND_KEYS:
			var value: Variant = main.get_shader_parameter(key)
			if value != null:
				pass_material.set_shader_parameter(key, value)
		main.next_pass = pass_material
		tree_pairs.append({"main": main, "pass": pass_material})
		tree_passes.append(pass_material)
		result[str(node.name)] = node.multimesh.instance_count
	return result

func _castle(shader: Shader, spec: Dictionary, sun_dir: Vector3) -> Dictionary:
	var castle: MeshInstance3D = viewer.castle
	var pass_material: ShaderMaterial = _make(shader, spec, "castle", sun_dir)
	edge_passes.append(pass_material)
	var targets: Array[Material] = []
	var candidates: Array = [castle.mesh.surface_get_material(0), castle.get_surface_override_material(0)]
	var lights: Node3D = viewer.castle_lighting
	if lights != null:
		candidates.append(lights.original_material)
		candidates.append(lights.original_material_override)
		candidates.append(lights.lit_material)
	for candidate: Variant in candidates:
		var material: Material = candidate as Material
		if material != null and not targets.has(material):
			material.next_pass = pass_material
			targets.append(material)
	return {"materials": targets.size()}

func _rocks(shader: Shader, spec: Dictionary, sun_dir: Vector3) -> Dictionary:
	var pass_material: ShaderMaterial = _make(shader, spec, "rocks", sun_dir)
	edge_passes.append(pass_material)
	var seen: Array[Material] = []
	for item: Node in viewer.world.find_children("SnowRocks_*", "MultiMeshInstance3D", true, false):
		var node: MultiMeshInstance3D = item as MultiMeshInstance3D
		if node.material_override != null:
			if not seen.has(node.material_override):
				node.material_override.next_pass = pass_material
				seen.append(node.material_override)
			continue
		var mesh: Mesh = node.multimesh.mesh
		for surface: int in mesh.get_surface_count():
			var material: Material = mesh.surface_get_material(surface)
			if material != null and not seen.has(material):
				material.next_pass = pass_material
				seen.append(material)
	return {"materials": seen.size()}

func _props(shader: Shader, spec: Dictionary, sun_dir: Vector3) -> Dictionary:
	var pass_material: ShaderMaterial = _make(shader, spec, "props", sun_dir)
	edge_passes.append(pass_material)
	var result: Dictionary = {}
	for node_name: Variant in spec.get("nodes", []):
		var node: MeshInstance3D = viewer.world.find_child(str(node_name), true, false) as MeshInstance3D
		if node == null or node.mesh == null:
			push_error("Panti prop rim target missing: " + str(node_name))
			continue
		var count: int = 0
		if node.material_override != null:
			var copy: Material = node.material_override.duplicate() as Material
			copy.next_pass = pass_material
			node.material_override = copy
			count += 1
		elif node.mesh.get_surface_count() == 1 and node.get_active_material(0) != null:
			var single: Material = node.get_active_material(0).duplicate() as Material
			single.next_pass = pass_material
			node.material_override = single
			count += 1
		else:
			for surface: int in node.mesh.get_surface_count():
				var source: Material = node.get_active_material(surface)
				if source == null:
					continue
				var surface_copy: Material = source.duplicate() as Material
				surface_copy.next_pass = pass_material
				node.set_surface_override_material(surface, surface_copy)
				count += 1
		result[str(node_name)] = count
	return result

func _character(shader: Shader, spec: Dictionary, sun_dir: Vector3) -> Dictionary:
	character_pass = ShaderMaterial.new()
	character_pass.shader = shader
	character_pass.set_shader_parameter("sun_dir_world", sun_dir)
	character_pass.set_shader_parameter("main_gate", float(cfg.main_gate))
	# The body is ALPHA_DEPTH_PRE_PASS (transparent queue): draw the rim after it, or its blend covers the rim.
	character_pass.render_priority = int(spec.get("render_priority", 1))
	passes.append(character_pass)
	var count: int = 0
	for item: Node in viewer.character_model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = item as MeshInstance3D
		if mesh_instance.mesh == null or str(mesh_instance.name).contains("Outline") or mesh_instance.material_override != null:
			continue
		for surface: int in mesh_instance.mesh.get_surface_count():
			var active: Material = mesh_instance.get_active_material(surface)
			if active == null:
				continue
			var own: Material = mesh_instance.get_surface_override_material(surface)
			if own == null:
				own = active.duplicate() as Material
				mesh_instance.set_surface_override_material(surface, own)
			own.next_pass = character_pass
			count += 1
	return {"surfaces": count, "render_priority": character_pass.render_priority}

## weight: 0 = morning, 1 = midnight. sun_now / sun_morning / sun_midnight are the main-light colours
## (current and both endpoints) used for the straight-line brightness correction.
func apply_blend(weight: float, sun_now: Color, sun_morning: Color, sun_midnight: Color) -> void:
	var tree_values: Dictionary = _mix(cfg.tree_edge, weight)
	var edge_values: Dictionary = _mix(cfg.edge, weight)
	var character_values: Dictionary = _mix(cfg.character_pass, weight)
	var dip: Dictionary = cfg.transition_dip
	tree_values.rim_strength = float(tree_values.rim_strength) * _curve(weight, float(dip.trees), sun_now, sun_morning, sun_midnight, cfg.tree_edge, tree_values.rim_tint, "trees")
	edge_values.rim_strength = float(edge_values.rim_strength) * _curve(weight, float(dip.objects), sun_now, sun_morning, sun_midnight, cfg.edge, edge_values.rim_tint, "objects")
	if not enabled:
		tree_values.rim_strength = 0.0
		edge_values.rim_strength = 0.0
		character_values.rim_intensity = 0.0
		character_values.fire_intensity = 0.0
	for material: ShaderMaterial in tree_passes:
		_set_all(material, tree_values)
	for material: ShaderMaterial in edge_passes:
		_set_all(material, edge_values)
	if character_pass != null:
		_set_all(character_pass, character_values)

func _set_all(material: ShaderMaterial, values: Dictionary) -> void:
	for key: String in values:
		material.set_shader_parameter(key, values[key])

func _mix(periods: Dictionary, weight: float) -> Dictionary:
	var result: Dictionary = {}
	var a: Dictionary = periods.morning
	var b: Dictionary = periods.midnight
	for key: String in a:
		result[key] = _lerp_value(a[key], b[key], weight)
	return result

## Rim colours are source_color uniforms: blend them as sRGB Colors (like the approved probe).
func _lerp_value(a: Variant, b: Variant, weight: float) -> Variant:
	if a is Array:
		var ca: Array = a
		var cb: Array = b
		return Color(float(ca[0]), float(ca[1]), float(ca[2])).lerp(Color(float(cb[0]), float(cb[1]), float(cb[2])), weight)
	return lerpf(float(a), float(b), weight)

## Brightness of the rim colour exactly as the shader forms it: max-normalised linear main-light hue x tint.
func _rim_luminance(sun_srgb: Color, tint_srgb: Color) -> float:
	var sun_linear: Color = sun_srgb.srgb_to_linear()
	var peak: float = maxf(maxf(sun_linear.r, sun_linear.g), maxf(sun_linear.b, 0.0001))
	var tint_linear: Color = tint_srgb.srgb_to_linear()
	return 0.2126 * sun_linear.r / peak * tint_linear.r + 0.7152 * sun_linear.g / peak * tint_linear.g + 0.0722 * sun_linear.b / peak * tint_linear.b

## Mid-transition the warm and cold main-light hues pass through neutral, where max-channel
## normalisation lifts all channels toward 1. Rescale so rim brightness moves on the straight line
## between both approved endpoints, then dip by dip * 4w(1 - w). Exactly 1 at w = 0 and w = 1.
func _curve(weight: float, dip: float, sun_now: Color, sun_morning: Color, sun_midnight: Color, periods: Dictionary, tint_now: Color, label: String) -> float:
	var tint_morning: Array = periods.morning.rim_tint
	var tint_midnight: Array = periods.midnight.rim_tint
	var now: float = _rim_luminance(sun_now, tint_now)
	var at_morning: float = _rim_luminance(sun_morning, Color(float(tint_morning[0]), float(tint_morning[1]), float(tint_morning[2])))
	var at_midnight: float = _rim_luminance(sun_midnight, Color(float(tint_midnight[0]), float(tint_midnight[1]), float(tint_midnight[2])))
	var factor: float = 1.0
	if weight > 0.0 and weight < 1.0 and now > 0.00001:
		factor = lerpf(at_morning, at_midnight, weight) / now * (1.0 - dip * 4.0 * weight * (1.0 - weight))
	last_curve[label] = {"weight": weight, "factor": factor, "dip": dip}
	return factor

## Main-light direction for the gate / screen direction, and the cedar wind clock for the tree passes.
func sync() -> void:
	var direction: Vector3 = viewer.sun.global_basis.z.normalized()
	for material: ShaderMaterial in passes:
		material.set_shader_parameter("sun_dir_world", direction)
	for pair: Dictionary in tree_pairs:
		var main: ShaderMaterial = pair.main
		var pass_material: ShaderMaterial = pair.pass
		pass_material.set_shader_parameter("anim_t", main.get_shader_parameter("anim_t"))
		pass_material.set_shader_parameter("wind_enabled", main.get_shader_parameter("wind_enabled"))

func evidence() -> Dictionary:
	var strengths: Dictionary = {}
	if not tree_passes.is_empty():
		strengths["trees"] = tree_passes[0].get_shader_parameter("rim_strength")
	if not edge_passes.is_empty():
		strengths["objects"] = edge_passes[0].get_shader_parameter("rim_strength")
	if character_pass != null:
		strengths["character"] = character_pass.get_shader_parameter("rim_intensity")
		strengths["character_fire"] = character_pass.get_shader_parameter("fire_intensity")
	return {"enabled": enabled, "built": built, "rim_strength": strengths, "transition_curve": last_curve,
		"main_light_gate": float(cfg.main_gate), "wind_copy_checked": true}
