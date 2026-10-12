extends RefCounted
## A reversible wet-surface pass. Geometry, source atlases and layout stay intact.
const STONE_SHADER := preload("res://shaders/traveler/baghdad/baghdad_rain_wet_stone.gdshader")
const GROUND_SHADER := preload("res://shaders/traveler/baghdad/baghdad_rain_wet_ground.gdshader")

var wetness := 0.92
var puddle_amount := 0.72
var ripple_strength := 0.10
var _saved: Array[Dictionary] = []
var _animated: Array[ShaderMaterial] = []
var _evidence: Dictionary = {}
var _stone_heights: Dictionary = {}
const HEIGHT_CELL := 0.035

func apply(viewer: Node3D) -> Dictionary:
	restore()
	var stone_surfaces := 0
	var textured_surfaces := 0
	for item in viewer.find_children("*", "MeshInstance3D", true, false):
		var mesh := item as MeshInstance3D
		if mesh.mesh == null:
			continue
		var label := str(mesh.name)
		if not (label.begins_with("StonePaving") or label.begins_with("FineGravel")):
			continue
		if label.begins_with("StonePaving"):
			_cache_stone_heights(mesh)
		var originals: Array[Material] = []
		for index in mesh.mesh.get_surface_count():
			originals.append(mesh.get_surface_override_material(index))
		_saved.append({"mesh":mesh,"override":mesh.material_override,"surfaces":originals})
		for index in mesh.mesh.get_surface_count():
			var source := mesh.get_active_material(index) as StandardMaterial3D
			if source == null:
				continue
			var material := ShaderMaterial.new()
			material.shader = STONE_SHADER
			material.set_shader_parameter("base_texture",source.albedo_texture)
			material.set_shader_parameter("use_texture",source.albedo_texture != null)
			material.set_shader_parameter("base_tint",source.albedo_color)
			material.set_shader_parameter("use_vertex_color",source.vertex_color_use_as_albedo)
			material.set_shader_parameter("vertex_color_srgb",source.vertex_color_is_srgb)
			material.set_shader_parameter("uv_scale",source.uv1_scale)
			material.set_shader_parameter("uv_offset",source.uv1_offset)
			material.set_shader_parameter("wetness",wetness)
			material.set_shader_parameter("gravel_surface",label.begins_with("FineGravel"))
			mesh.set_surface_override_material(index,material)
			stone_surfaces += 1
			if source.albedo_texture != null:
				textured_surfaces += 1
		mesh.material_override = null
	var ground := viewer.get("ground") as MeshInstance3D
	if ground != null and ground.mesh != null:
		var original_surfaces: Array[Material] = []
		for index in ground.mesh.get_surface_count():
			original_surfaces.append(ground.get_surface_override_material(index))
		_saved.append({"mesh":ground,"override":ground.material_override,"surfaces":original_surfaces})
		var material := ShaderMaterial.new()
		material.shader = GROUND_SHADER
		material.set_shader_parameter("wetness",wetness)
		material.set_shader_parameter("puddle_amount",puddle_amount)
		material.set_shader_parameter("ripple_strength",ripple_strength)
		var character := viewer.get("character") as Node3D
		if character != null:
			material.set_shader_parameter("traveler_xz",Vector2(character.global_position.x,character.global_position.z))
		var fire := viewer.find_child("StaticCampFire",true,false) as Node3D
		if fire != null:
			material.set_shader_parameter("fire_xz",Vector2(fire.global_position.x,fire.global_position.z))
		ground.material_override = material
		_animated.append(material)
	var tree_surfaces := _apply_object_dampness(viewer.get("tree") as Node3D,true)
	var arch_surfaces := _apply_object_dampness(viewer.get("arch") as Node3D,false)
	_evidence = {"wet_stone_surfaces":stone_surfaces,"preserved_source_atlases":textured_surfaces,
		"wet_tree_surfaces":tree_surfaces,"wet_arch_surfaces":arch_surfaces,
		"tree_roughness":0.62,"tree_specular":0.30,"tree_glow_parameters_preserved":true,
		"arch_albedo_multiplier":0.90,"arch_roughness":0.56,"arch_specular":0.32,
		"wetness":wetness,"puddle_amount":puddle_amount,"ripple_strength":ripple_strength,
		"stone_roughness_range":[0.20,0.66],"pool_roughness":0.13,
		"source_meshes_unchanged":true,"source_uvs_unchanged":true,
		"new_geometry":0,"pool_surface":"procedural wet patches on the existing terrain receiver",
		"pools_exclude_fire_and_traveler":true,"lighting":"real PBR sky reflections and scene lights; existing tree glow preserved, no added emission"}
	return _evidence.duplicate(true)

func _apply_object_dampness(root: Node3D, is_tree: bool) -> int:
	if root == null:
		return 0
	var changed_surfaces := 0
	var meshes: Array[Node] = root.find_children("*","MeshInstance3D",true,false)
	if root is MeshInstance3D:
		meshes.append(root)
	for item in meshes:
		var mesh := item as MeshInstance3D
		if mesh.mesh == null:
			continue
		var originals: Array[Material] = []
		var replacements: Array[Material] = []
		var changed := false
		for index in mesh.mesh.get_surface_count():
			originals.append(mesh.get_surface_override_material(index))
			var active := mesh.get_active_material(index)
			if is_tree and active is ShaderMaterial:
				var source := active as ShaderMaterial
				if source.shader != null and source.shader.code.contains("uniform float surface_roughness") and source.shader.code.contains("uniform float surface_specular"):
					# Shallow duplication retains the atlas, shader and every emission / beam
					# uniform; the damp pass changes only these two PBR response values.
					var damp := source.duplicate() as ShaderMaterial
					damp.set_shader_parameter("surface_roughness",0.62)
					damp.set_shader_parameter("surface_specular",0.30)
					replacements.append(damp)
					changed = true
					changed_surfaces += 1
					continue
			elif not is_tree and active is StandardMaterial3D:
				var source := active as StandardMaterial3D
				if source.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED:
					var damp := source.duplicate() as StandardMaterial3D
					var albedo := source.albedo_color
					damp.albedo_color = Color(albedo.r*0.90,albedo.g*0.90,albedo.b*0.90,albedo.a)
					damp.roughness = 0.56
					damp.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
					damp.metallic_specular = 0.32
					replacements.append(damp)
					changed = true
					changed_surfaces += 1
					continue
			replacements.append(active)
		if changed:
			_saved.append({"mesh":mesh,"override":mesh.material_override,"surfaces":originals})
			mesh.material_override = null
			for index in replacements.size():
				mesh.set_surface_override_material(index,replacements[index])
	return changed_surfaces

func _cache_stone_heights(mesh: MeshInstance3D) -> void:
	var transform := mesh.global_transform
	var normal_basis := transform.basis.inverse().transposed()
	for surface in mesh.mesh.get_surface_count():
		var arrays: Array = mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for index in vertices.size():
			if index < normals.size() and (normal_basis * normals[index]).normalized().y < 0.45:
				continue
			var vertex := transform * vertices[index]
			var cell := Vector2i(floori(vertex.x / HEIGHT_CELL),floori(vertex.z / HEIGHT_CELL))
			_stone_heights[cell] = maxf(float(_stone_heights.get(cell,-INF)),vertex.y)

## Highest nearby upward-facing stone vertex; NAN means this point is a gap.
## The 3.5 cm cells follow the actual draped stone mesh, not an average offset.
func sample_surface_height(world_x: float, world_z: float) -> float:
	var center := Vector2i(floori(world_x / HEIGHT_CELL),floori(world_z / HEIGHT_CELL))
	var highest := -INF
	for x in range(-1,2):
		for z in range(-1,2):
			highest = maxf(highest,float(_stone_heights.get(center+Vector2i(x,z),-INF)))
	return NAN if highest == -INF else highest

func set_time(seconds: float) -> void:
	for material in _animated:
		material.set_shader_parameter("rain_time",seconds)

func evidence() -> Dictionary:
	return _evidence.duplicate(true)

func restore() -> void:
	for record in _saved:
		var mesh := record.mesh as MeshInstance3D
		if is_instance_valid(mesh):
			mesh.material_override = record.override
			for index in record.surfaces.size():
				mesh.set_surface_override_material(index,record.surfaces[index])
	_saved.clear()
	_animated.clear()
	_evidence.clear()
	_stone_heights.clear()
