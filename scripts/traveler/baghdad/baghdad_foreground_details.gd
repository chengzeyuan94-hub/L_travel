extends RefCounted
## Blender-authored paving and vegetation, conformed to the current desert mesh.
## Imported glTF is (stage X, height, -stage Z); the viewer mirrors stage X.
const ASSET := "res://assets/traveler/baghdad/foreground/cracked_road.glb"
const LEGACY_ASSET := "res://assets/traveler/baghdad/foreground/foreground_detail.glb"

func build(viewer: Node3D, asset_path: String = "") -> Node3D:
	if asset_path.is_empty():
		asset_path = LEGACY_ASSET if preload("res://scripts/traveler/traveler_launch.gd").user_args().has("--legacy-foreground") else ASSET
	var root := Node3D.new()
	root.name = "BaghdadForegroundDetails"
	if not FileAccess.file_exists(asset_path):
		push_error("Missing Blender foreground asset: " + asset_path)
		return root
	# Runtime GLTFDocument avoids requiring an editor import or touching shared caches.
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(asset_path, state)
	if error != OK:
		push_error("Unable to load Baghdad foreground GLB: %s" % error)
		return root
	var source_root := document.generate_scene(state)
	if source_root == null:
		push_error("Unable to instantiate Baghdad foreground GLB")
		return root
	var records: Array[Dictionary] = []
	var total_triangles := 0
	for item in source_root.find_children("*", "MeshInstance3D", true, false):
		var source := item as MeshInstance3D
		var transform := source.transform
		var ancestor := source.get_parent()
		while ancestor is Node3D:
			transform = (ancestor as Node3D).transform * transform
			ancestor = ancestor.get_parent()
		var result := ArrayMesh.new()
		var triangle_count := 0
		var material_records: Array[Dictionary] = []
		for surface_index in source.mesh.get_surface_count():
			var arrays: Array = source.mesh.surface_get_arrays(surface_index)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var tangents := PackedFloat32Array()
			if arrays[Mesh.ARRAY_TANGENT] != null:
				tangents = arrays[Mesh.ARRAY_TANGENT]
			var normal_basis := transform.basis.inverse().transposed()
			# Imported X/Z both change sign: this is a rotation, not a reflection.
			# Only a reflected source transform changes tangent handedness.
			var tangent_handedness := -1.0 if transform.basis.determinant() < 0.0 else 1.0
			for index in vertices.size():
				var imported: Vector3 = transform * vertices[index]
				var stage := Vector3(imported.x, imported.y, -imported.z)
				stage.y += float(viewer.ground_surface.height_at(Vector2(stage.x, stage.z)))
				vertices[index] = viewer.stage_point(stage)
				if index < normals.size():
					var normal: Vector3 = (normal_basis * normals[index]).normalized()
					normals[index] = Vector3(-normal.x, normal.y, -normal.z)
				var tangent_index := index * 4
				if tangent_index + 3 < tangents.size():
					var tangent := transform.basis * Vector3(tangents[tangent_index], tangents[tangent_index + 1], tangents[tangent_index + 2])
					tangent = Vector3(-tangent.x, tangent.y, -tangent.z)
					if index < normals.size():
						tangent -= normals[index] * tangent.dot(normals[index])
					tangent = tangent.normalized()
					tangents[tangent_index] = tangent.x
					tangents[tangent_index + 1] = tangent.y
					tangents[tangent_index + 2] = tangent.z
					tangents[tangent_index + 3] *= tangent_handedness
			arrays[Mesh.ARRAY_VERTEX] = vertices
			arrays[Mesh.ARRAY_NORMAL] = normals
			if not tangents.is_empty():
				arrays[Mesh.ARRAY_TANGENT] = tangents
			result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var original := source.get_active_material(surface_index) as StandardMaterial3D
			var material: StandardMaterial3D = original.duplicate() if original != null else StandardMaterial3D.new()
			# The neutral stone texture multiplies the authored vertex colours.
			# Preserve imported texture channels, UV settings and normal-map strength.
			var stone_surface := str(source.name).begins_with("StonePaving") or str(source.name).begins_with("FineGravel")
			var textured_stone := stone_surface and (material.albedo_texture != null or material.normal_texture != null or material.roughness_texture != null)
			material.vertex_color_use_as_albedo = true
			if not textured_stone:
				material.roughness = 0.94
				material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
			material.metallic = 0.0
			material.cull_mode = BaseMaterial3D.CULL_DISABLED
			material.emission_enabled = false
			result.surface_set_material(surface_index, material)
			material_records.append({"surface": surface_index, "textured_stone": textured_stone,
				"albedo_texture": material.albedo_texture != null, "normal_texture": material.normal_texture != null,
				"roughness_texture": material.roughness_texture != null, "normal_enabled": material.normal_enabled,
				"roughness": material.roughness, "tangent_vertices": tangents.size() / 4,
				"vertex_color_use_as_albedo": material.vertex_color_use_as_albedo})
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			triangle_count += (indices.size() if not indices.is_empty() else vertices.size()) / 3
		var mesh := MeshInstance3D.new()
		mesh.name = source.name
		mesh.mesh = result
		# Tiny near-horizontal meshes do not cast low-sun acne onto one another.
		# They receive the existing directional shadow, SSAO and SDFGI.
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mesh)
		total_triangles += triangle_count
		records.append({"name": str(mesh.name), "triangles": triangle_count,
			"surfaces": result.get_surface_count(), "materials": material_records})
	source_root.free()
	root.set_meta("evidence", {"asset": asset_path, "meshes": records, "triangles": total_triangles,
		"contact": "each vertex samples current rendered terrain triangles", "authored_in": "Blender 5.2.1 via MCP",
		"layout_source": "current viewer settings; existing scene configuration is not modified"})
	return root
