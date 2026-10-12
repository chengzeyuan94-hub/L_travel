extends RefCounted
## Correct a back-facing receiver mesh in this look only; source terrain is untouched.
var ground: MeshInstance3D
var original_mesh: Mesh
var original_override: Material
var original_surfaces: Array[Material] = []

func apply(viewer: Node3D) -> Dictionary:
	ground = viewer.ground
	original_mesh = ground.mesh
	original_override = ground.material_override
	var corrected := ArrayMesh.new()
	var fixed_faces := 0
	for surface in original_mesh.get_surface_count():
		original_surfaces.append(ground.get_surface_override_material(surface))
		var arrays: Array = original_mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			indices.resize(vertices.size())
			for index in vertices.size():
				indices[index] = index
		for first in range(0,indices.size(),3):
			var a := indices[first]
			var b := indices[first+1]
			var c := indices[first+2]
			# Godot front faces are clockwise: native PlaneMesh cross·normal is -1.
			if (vertices[b]-vertices[a]).cross(vertices[c]-vertices[a]).dot(normals[a]) > 0.0:
				indices[first+1] = c
				indices[first+2] = b
				fixed_faces += 1
		arrays[Mesh.ARRAY_INDEX] = indices
		corrected.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		corrected.surface_set_material(surface,original_mesh.surface_get_material(surface))
	ground.mesh = corrected
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/traveler/baghdad/baghdad_storm_ground.gdshader")
	material.set_shader_parameter("sand_color",Color(0.73,0.63,0.48))
	ground.material_override = material
	var record := {"reversed_receiver_faces":fixed_faces,"vertex_positions_unchanged":true,
		"ground_height_sampling_unchanged":true,"surface":"granular sand with restrained damp patches",
		"source_terrain_file_modified":false}
	ground.set_meta("storm_surface",record)
	return record

func restore() -> void:
	if is_instance_valid(ground):
		ground.mesh = original_mesh
		ground.material_override = original_override
		for index in original_surfaces.size():
			ground.set_surface_override_material(index,original_surfaces[index])
	original_surfaces.clear()
