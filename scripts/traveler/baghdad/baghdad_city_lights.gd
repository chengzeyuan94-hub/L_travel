extends Node3D
## Warm light confined to the original Baghdad window, door and lantern faces.
## No building geometry, placement or shared material is changed.

const LIGHT_SHADER := preload("res://scripts/traveler/baghdad/baghdad_city_lights.gdshader")
const WARM := Color(1.0, 0.49, 0.14)

var window_energy := 5.6
var lantern_energy := 7.2
var wall_wash_energy := 0.07
var _viewer: Node3D
var _amount := 0.0
var _clock := 0.0
var _faces: Array[Dictionary] = []
var _lights: Array[OmniLight3D] = []
var _records: Array[Dictionary] = []
var _created: Array[Node] = []

func configure(viewer: Node3D) -> bool:
	restore()
	_viewer = viewer
	name = "BaghdadCityLights"
	var city_roots: Array[Node3D] = []
	for candidate in viewer.world.find_children("*", "Node3D", true, false):
		var node := candidate as Node3D
		var placement: Dictionary = node.get_meta("mountain_placement", {})
		if str(placement.get("asset", "")).get_file().to_lower() == "baghdad.glb":
			city_roots.append(node)
	# The authored town currently resides in BaghdadMountainBands/editor_01.
	# Do not activate the disabled legacy mosque or create a replacement town.
	for city in city_roots:
		for candidate in city.find_children("*", "MeshInstance3D", true, false):
			var source := candidate as MeshInstance3D
			if source.mesh == null:
				continue
			_add_original_faces(source)
		_add_wall_wash(city)
	set_amount(0.0)
	return not _faces.is_empty()

func _add_original_faces(source: MeshInstance3D) -> void:
	for surface_index in source.mesh.get_surface_count():
		var arrays := source.mesh.surface_get_arrays(surface_index)
		if arrays.is_empty():
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var source_material := source.mesh.surface_get_material(surface_index)
		var is_lantern := source_material != null and source_material.resource_name.to_lower().contains("emissive")
		if not is_lantern and colors.size() != vertices.size():
			continue
		var offset_world := 0.002
		var normal_to_world := source.global_basis.inverse().transposed()
		var world_to_local := source.global_basis.inverse()
		var selected_vertices := PackedVector3Array()
		var selected_normals := PackedVector3Array()
		var triangle_count := int((vertices.size() if indices.is_empty() else indices.size()) / 3)
		var accepted := 0
		for triangle in triangle_count:
			var ids := PackedInt32Array()
			var matches := true
			for corner in 3:
				var index := triangle * 3 + corner if indices.is_empty() else indices[triangle * 3 + corner]
				ids.append(index)
				if not is_lantern and not _window_color(colors[index]):
					matches = false
			if not matches:
				continue
			accepted += 1
			for index in ids:
				var normal := normals[index] if normals.size() == vertices.size() else Vector3.UP
				# Fixed two-millimetre world separation survives distant depth precision
				# while retaining the original arch and lantern contours.
				var offset_local := world_to_local * (normal_to_world * normal).normalized() * offset_world
				selected_vertices.append(vertices[index] + offset_local)
				selected_normals.append(normal)
		if accepted == 0:
			continue
		var output := []
		output.resize(Mesh.ARRAY_MAX)
		output[Mesh.ARRAY_VERTEX] = selected_vertices
		output[Mesh.ARRAY_NORMAL] = selected_normals
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, output)
		var material := ShaderMaterial.new()
		material.shader = LIGHT_SHADER
		material.set_shader_parameter("warm_color", WARM)
		material.set_shader_parameter("energy", lantern_energy if is_lantern else window_energy)
		material.set_shader_parameter("amount", 0.0)
		var luminous := MeshInstance3D.new()
		luminous.name = "OriginalLanternLightFaces" if is_lantern else "OriginalWindowLightFaces"
		luminous.mesh = mesh
		luminous.material_override = material
		luminous.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		luminous.ignore_occlusion_culling = true
		source.add_child(luminous)
		_created.append(luminous)
		_faces.append({"node": luminous, "material": material, "lantern": is_lantern})
		_records.append({"source_node": str(source.get_path()), "surface": surface_index,
			"source_material": source_material.resource_name if source_material != null else "",
			"kind": "original_lantern_faces" if is_lantern else "original_arch_window_and_door_faces",
			"selected_triangles": accepted, "source_triangles": triangle_count,
			"source_contours_preserved": true, "offset_world_units": offset_world})

func _window_color(color: Color) -> bool:
	# Authored dark recess paint in baghdad.glb (linear RGB approximately
	# 0.0612, 0.0412, 0.0205), including the brighter outer window pane. Recess backs are R~0.061;
	# the visible front is R~0.08-0.17. Colour ratios distinguish both from wood.
	# This excludes sandstone, roofs, palm leaves, wood and paving.
	if color.r < 0.044 or color.r > 0.28:
		return false
	var green_ratio := color.g / color.r
	var blue_ratio := color.b / color.r
	return green_ratio > 0.59 and green_ratio < 0.74 and blue_ratio > 0.27 and blue_ratio < 0.365

func _add_wall_wash(city: Node3D) -> void:
	var bounds := AABB()
	var found := false
	for candidate in city.find_children("*", "MeshInstance3D", true, false):
		var item := candidate as MeshInstance3D
		if item.mesh == null or item.name.begins_with("OriginalWindowLight") or item.name.begins_with("OriginalLanternLight"):
			continue
		var box: AABB = city.global_transform.affine_inverse() * item.global_transform * item.mesh.get_aabb()
		bounds = bounds.merge(box) if found else box
		found = true
	if not found:
		return
	# Low-power reflected amber around the existing entry, not a second sun.
	var light := OmniLight3D.new()
	light.name = "WarmTownReflectedLight"
	light.light_color = WARM
	light.light_energy = 0.0
	light.light_specular = 0.15
	light.light_volumetric_fog_energy = 0.0
	light.shadow_enabled = false
	city.add_child(light)
	light.position = bounds.get_center() + Vector3(0.0, -bounds.size.y * 0.16, bounds.size.z * 0.22)
	light.omni_range = maxf(bounds.size.y * city.global_basis.get_scale().y * 0.63, 0.5)
	light.omni_attenuation = 1.9
	light.visible = false
	_created.append(light)
	_lights.append(light)

func set_amount(amount: float, seconds: float = 0.0) -> void:
	_amount = clampf(amount, 0.0, 1.0)
	_clock = maxf(seconds, 0.0)
	for record in _faces:
		var node: MeshInstance3D = record.node
		if not is_instance_valid(node):
			continue
		node.visible = _amount > 0.0001
		var material: ShaderMaterial = record.material
		material.set_shader_parameter("amount", _amount)
		material.set_shader_parameter("clock", _clock)
	for light in _lights:
		if is_instance_valid(light):
			light.visible = _amount > 0.0001
			light.light_energy = wall_wash_energy * _amount

func evidence() -> Dictionary:
	return {"configured": not _faces.is_empty(), "amount": _amount, "seconds": _clock,
		"window_emission_energy": window_energy, "lantern_emission_energy": lantern_energy,
		"wall_wash_energy": wall_wash_energy, "face_groups": _records.duplicate(true),
		"source_geometry_unchanged": true, "source_materials_unchanged": true,
		"building_placement_unchanged": true, "a_state_has_no_added_light": _amount <= 0.0001,
		"lighting_method": "Only original dark arch recess faces and existing emissive lantern faces; no wall emission."}

func restore() -> void:
	for node in _created:
		if is_instance_valid(node):
			node.free()
	_created.clear()
	_faces.clear()
	_lights.clear()
	_records.clear()
	_amount = 0.0

func _exit_tree() -> void:
	restore()
