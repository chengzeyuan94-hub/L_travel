extends RefCounted
## Explicit-clock wind for the existing Panti cedar MultiMeshes.
## configure after build_trees; call set_time from the shared motion clock.
## Repeating set_time(t) freezes the pose. set_enabled(false) restores the exact
## original material override and undeformed mesh, without resetting the clock.

const SHADER_PATH := "res://shaders/traveler/panti/panti_tree_wind.gdshader"
const DEFAULTS := {
	"enabled": true,
	"tip_displacement_ratio": 0.011,
	"gust_period_s": 10.0,
	"sway_period_s": 9.6,
	"gust_weight": 0.72,
	"rest_bend_ratio": 0.18,
	"bend_exponent": 1.8,
	"root_lock_fraction": 0.02,
	"crown_ripple_ratio": 0.12,
	"crown_layers": 3.0,
	"bounds_padding_u": 0.04,
}

var params: Dictionary = {}
var groups: Array[Dictionary] = []
var camera: Camera3D
var wind_world := Vector3.LEFT
var anim_t := 0.0
var enabled := true
var configured := false

func configure(viewer: Node3D, overrides: Dictionary = {}) -> void:
	_restore_groups()
	params = DEFAULTS.duplicate(true)
	for key in overrides:
		params[key] = overrides[key]
	params.tip_displacement_ratio = clampf(float(params.tip_displacement_ratio), 0.0, 0.10)
	params.gust_period_s = maxf(float(params.gust_period_s), 0.1)
	params.sway_period_s = maxf(float(params.sway_period_s), 0.1)
	params.gust_weight = clampf(float(params.gust_weight), 0.0, 1.0)
	params.rest_bend_ratio = clampf(float(params.rest_bend_ratio), 0.0, 1.0)
	params.bend_exponent = maxf(float(params.bend_exponent), 1.0)
	params.root_lock_fraction = clampf(float(params.root_lock_fraction), 0.0, 0.25)
	params.crown_ripple_ratio = clampf(float(params.crown_ripple_ratio), 0.0, 0.5)
	params.crown_layers = maxf(float(params.crown_layers), 0.0)
	params.bounds_padding_u = maxf(float(params.bounds_padding_u), 0.0)
	var world := viewer.get("world") as Node3D
	camera = viewer.get("camera") as Camera3D
	if world == null or camera == null:
		push_error("Panti tree wind requires the built world and camera")
		return
	wind_world = -camera.global_basis.x
	wind_world.y = 0.0
	if wind_world.length_squared() < 0.000001:
		push_error("Panti tree wind cannot derive a horizontal camera-left direction")
		return
	wind_world = wind_world.normalized()
	var shader := load(SHADER_PATH) as Shader
	if shader == null:
		push_error("Missing Panti tree wind shader: " + SHADER_PATH)
		return
	for candidate in world.find_children("SnowCedars_*", "MultiMeshInstance3D", true, false):
		var node := candidate as MultiMeshInstance3D
		_bind_group(node, shader)
	configured = not groups.is_empty()
	if not configured:
		push_error("Panti tree wind found no usable SnowCedars_* MultiMeshes")
	set_enabled(bool(params.enabled))
	set_time(anim_t)

func _bind_group(node: MultiMeshInstance3D, shader: Shader) -> void:
	var mm := node.multimesh
	if mm == null or mm.mesh == null or mm.instance_count == 0:
		return
	if not mm.use_custom_data or mm.mesh.get_surface_count() != 1:
		push_error("Panti cedar wind needs one mesh surface and enabled custom data: " + str(node.name))
		return
	var original_override: Material = node.material_override
	var source := original_override as StandardMaterial3D
	if source == null:
		source = mm.mesh.surface_get_material(0) as StandardMaterial3D
	if source == null or source.albedo_texture == null:
		push_error("Panti cedar wind requires the original textured StandardMaterial3D: " + str(node.name))
		return
	var local_bounds: AABB = mm.mesh.get_aabb()
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("texture_albedo", source.albedo_texture)
	material.set_shader_parameter("albedo_color", source.albedo_color)
	material.set_shader_parameter("uv_scale", Vector2(source.uv1_scale.x, source.uv1_scale.y))
	material.set_shader_parameter("uv_offset", Vector2(source.uv1_offset.x, source.uv1_offset.y))
	material.set_shader_parameter("roughness", source.roughness)
	material.set_shader_parameter("mesh_bottom_y", local_bounds.position.y)
	material.set_shader_parameter("mesh_height", local_bounds.size.y)
	material.set_shader_parameter("wind_world", wind_world)
	material.set_shader_parameter("anim_t", anim_t)
	for key in DEFAULTS:
		if key != "enabled" and key != "bounds_padding_u":
			material.set_shader_parameter(key, params[key])
	var tip_local := Vector3(0.0, local_bounds.end.y, 0.0)
	var arrays: Array = mm.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var max_y := -INF
	for vertex in vertices:
		if vertex.y > max_y:
			max_y = vertex.y
			tip_local = vertex
	var static_bounds: AABB = mm.get_instance_transform(0) * local_bounds
	var max_displacement_world := 0.0
	var tip_records: Array[Dictionary] = []
	for i in mm.instance_count:
		var transform: Transform3D = mm.get_instance_transform(i)
		static_bounds = static_bounds.merge(transform * local_bounds)
		var to_world: Transform3D = node.global_transform * transform
		var height_world: float = to_world.basis.y.length() * local_bounds.size.y
		var custom: Color = mm.get_instance_custom_data(i)
		var tip_peak: float = height_world * float(params.tip_displacement_ratio) * maxf(custom.g, 0.0)
		# The canopy envelope has maximum 0.25, and trunk_bend is bounded by 1.
		max_displacement_world = maxf(max_displacement_world, tip_peak * (1.0 + 0.25 * float(params.crown_ripple_ratio)))
		tip_records.append({"tip_world": to_world * tip_local, "height_world_u": height_world, "tip_peak_world_u": tip_peak})
	var basis: Basis = node.global_basis
	var minimum_scale: float = minf(basis.x.length(), minf(basis.y.length(), basis.z.length()))
	var margin_local: float = (max_displacement_world + float(params.bounds_padding_u)) / maxf(minimum_scale, 0.000001)
	var original_aabb: AABB = node.custom_aabb
	node.custom_aabb = static_bounds.grow(margin_local)
	groups.append({"node": node, "material": material, "original_override": original_override,
		"original_aabb": original_aabb, "static_aabb": static_bounds, "aabb_margin_local_u": margin_local,
		"max_displacement_world_u": max_displacement_world, "tip_records": tip_records,
		"source_albedo": source.albedo_texture.resource_path, "source_roughness": source.roughness,
		"source_cull_mode": source.cull_mode, "source_diffuse_mode": source.diffuse_mode})

func set_time(value: float) -> void:
	anim_t = maxf(value, 0.0)
	for group in groups:
		var material: ShaderMaterial = group.material
		material.set_shader_parameter("anim_t", anim_t)

func set_enabled(value: bool) -> void:
	enabled = value
	for group in groups:
		var node: MultiMeshInstance3D = group.node
		if not is_instance_valid(node):
			continue
		var material: ShaderMaterial = group.material
		material.set_shader_parameter("wind_enabled", enabled)
		node.material_override = material if enabled else group.original_override

func _restore_groups() -> void:
	for group in groups:
		var node: MultiMeshInstance3D = group.node
		if is_instance_valid(node):
			if node.material_override == group.material:
				node.material_override = group.original_override
			node.custom_aabb = group.original_aabb
	groups.clear()
	configured = false

func evidence() -> Dictionary:
	var batches: Array[Dictionary] = []
	var pixels: Array[float] = []
	var total := 0
	for group in groups:
		var node: MultiMeshInstance3D = group.node
		if not is_instance_valid(node):
			continue
		var group_pixels: Array[float] = []
		for tip in group.tip_records:
			var at: Vector3 = tip.tip_world
			if camera != null and not camera.is_position_behind(at):
				var shifted: Vector3 = at + wind_world * float(tip.tip_peak_world_u)
				var span: float = camera.unproject_position(at).distance_to(camera.unproject_position(shifted))
				group_pixels.append(span)
				pixels.append(span)
		total += node.multimesh.instance_count
		batches.append({"node": str(node.name), "instances": node.multimesh.instance_count,
			"custom_data_enabled": node.multimesh.use_custom_data, "source_albedo": group.source_albedo,
			"source_roughness": group.source_roughness, "source_cull_mode": group.source_cull_mode,
			"source_diffuse_mode": group.source_diffuse_mode, "custom_aabb": str(node.custom_aabb),
			"aabb_margin_local_u": group.aabb_margin_local_u, "max_displacement_world_u": group.max_displacement_world_u,
			"projected_tip_amplitude_px": _range(group_pixels)})
	return {"schema": "silkroad.panti-tree-wind.v1", "configured": configured, "enabled": enabled,
		"anim_t": anim_t, "params": params.duplicate(true), "instance_count": total, "batch_count": batches.size(),
		"wind_world": [wind_world.x, wind_world.y, wind_world.z],
		"clock": "caller supplies anim_t; no internal process or wall clock",
		"disabled_behavior": "original material override and undeformed mesh restored",
		"projected_tip_amplitude_px": _range(pixels),
		"projection_basis": "analytic upper bound from each mesh's highest vertex, actual instance transform, configured tip ratio and custom amplitude; not a temporal optical-flow measurement",
		"projection_viewport_size": [camera.get_viewport().get_visible_rect().size.x, camera.get_viewport().get_visible_rect().size.y] if camera != null else [],
		"batches": batches}

func _range(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"count": 0}
	var ordered: Array[float] = values.duplicate()
	ordered.sort()
	var n := ordered.size()
	var middle: int = n >> 1
	var median: float = ordered[middle] if n % 2 == 1 else (ordered[middle - 1] + ordered[middle]) * 0.5
	return {"count": n, "min": ordered[0], "median": median, "max": ordered[n - 1]}
