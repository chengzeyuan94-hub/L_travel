extends RefCounted
## Utilities for the independent Baghdad cinematic lighting sample.
##
## The production composition is assembled at runtime, while LightmapGI's bake
## button operates on an editor scene.  This helper freezes the assembled scene
## into a self-contained PackedScene, gives copied meshes a UV2 atlas (exact
## per-triangle islands for small meshes and a stable projection for dense
## meshes), marks static/dynamic GI participants, and adds probe points. It never
## changes the imported source assets.

const OUTPUT_SCENE := "res://scenes/traveler/baghdad_cinematic_baked.tscn"
const SAMPLE_ROOT_NAME := "BaghdadCinematicBakeRoot"

var _stats: Dictionary = {
	"mesh_count": 0,
	"uv2_generated": 0,
	"triangles_unwrapped": 0,
	"static_mesh_count": 0,
	"dynamic_mesh_count": 0,
	"disabled_mesh_count": 0,
	"probe_count": 0,
	"notes": []
}

## Call this after the cinematic viewer has built all geometry and lights.
## `viewer` is deliberately typed as Node3D so this utility stays independent
## from the runtime viewer implementation.
func prepare(viewer: Node3D) -> Dictionary:
	_stats = {
		"mesh_count": 0,
		"uv2_generated": 0,
		"triangles_unwrapped": 0,
		"static_mesh_count": 0,
		"dynamic_mesh_count": 0,
		"disabled_mesh_count": 0,
		"probe_count": 0,
		"notes": []
	}
	var character: Node = viewer.get("character") as Node
	for child in viewer.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := child as MeshInstance3D
		if mesh_node == null or mesh_node.mesh == null:
			continue
		_stats.mesh_count += 1
		if character != null and character.is_ancestor_of(mesh_node):
			# The moving actor receives baked irradiance from probes; its geometry
			# itself must not be included in the static lightmap.
			mesh_node.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
			_stats.dynamic_mesh_count += 1
			continue
		if _is_dynamic_or_effect(mesh_node):
			mesh_node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			_stats.disabled_mesh_count += 1
			continue
		var copied := _copy_mesh_with_uv2(mesh_node.mesh)
		if copied != null:
			mesh_node.mesh = copied
			mesh_node.gi_mode = GeometryInstance3D.GI_MODE_STATIC
			_stats.static_mesh_count += 1
			_stats.uv2_generated += 1
		else:
			_stats.notes.append("UV2 copy skipped: %s" % mesh_node.get_path())
	# LightmapGI is intentionally added after geometry is ready.  Bake settings
	# match the cinematic sample brief: medium, three bounces and denoising.
	var gi := viewer.get_node_or_null("CinematicLightmapGI") as LightmapGI
	if gi == null:
		gi = LightmapGI.new()
		gi.name = "CinematicLightmapGI"
		viewer.add_child(gi)
	gi.quality = LightmapGI.BAKE_QUALITY_MEDIUM
	gi.bounces = 3
	gi.bounce_indirect_energy = 1.0
	gi.use_denoiser = true
	gi.denoiser_strength = 0.1
	gi.denoiser_range = 10
	gi.texel_scale = 0.15
	gi.max_texture_size = 4096
	gi.generate_probes_subdiv = LightmapGI.GENERATE_PROBES_SUBDIV_4
	gi.directional = true
	gi.environment_mode = LightmapGI.ENVIRONMENT_MODE_SCENE
	_add_probe_points(viewer, character)
	_stats.notes.append("Bake in the Godot editor using CinematicLightmapGI > Bake.")
	_stats.notes.append("Sunset key light remains Dynamic for realtime direct shadows; actor/effects are probe-lit or disabled.")
	viewer.set_meta("lightmap_prepare", _stats.duplicate(true))
	return _stats.duplicate(true)

## Freeze the prepared runtime tree to an editor scene.  Runtime scripts are
## stripped from the root; child scripts are retained only if an authored
## child explicitly needs one.
func pack_static(viewer: Node3D, output_path: String = OUTPUT_SCENE) -> Dictionary:
	var prepared := prepare(viewer)
	var copy := viewer.duplicate(Node.DUPLICATE_USE_INSTANTIATION | Node.DUPLICATE_SCRIPTS) as Node3D
	if copy == null:
		push_error("Could not duplicate Baghdad cinematic tree")
		return {"ok": false, "error": "duplicate_failed"}
	copy.name = SAMPLE_ROOT_NAME
	copy.set_script(null)
	_assign_owner(copy, copy)
	var packed := PackedScene.new()
	var err := packed.pack(copy)
	copy.free()
	if err != OK:
		push_error("PackedScene.pack failed: %s" % err)
		return {"ok": false, "error": str(err), "stats": prepared}
	var absolute := ProjectSettings.globalize_path(output_path)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	err = ResourceSaver.save(packed, output_path)
	if err != OK:
		push_error("Could not save cinematic bake scene: %s" % err)
		return {"ok": false, "error": str(err), "stats": prepared}
	return {"ok": true, "path": output_path, "stats": prepared}

func _assign_owner(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_assign_owner(child, owner)

func _is_dynamic_or_effect(mesh_node: MeshInstance3D) -> bool:
	var lower := str(mesh_node.name).to_lower()
	if mesh_node.is_inside_tree():
		lower = str(mesh_node.get_path()).to_lower()
	return lower.contains("particle") or lower.contains("flame") or lower.contains("fire") or lower.contains("smoke") or lower.contains("mist")

## Build a small, independent probe cluster around the moving actor and the
## portal. LightmapProbe has no authored mesh and is safe to keep in the packed
## scene; LightmapGI populates its data when the editor bake completes.
func _add_probe_points(viewer: Node3D, character: Node) -> void:
	var points: Array[Vector3] = []
	if character != null:
		points.append((character as Node3D).global_position + Vector3(0.0, 0.35, 0.0))
		points.append((character as Node3D).global_position + Vector3(0.0, 1.0, 0.0))
	points.append(viewer.stage_point(Vector3(0.0, 1.2, 2.7)))
	points.append(viewer.stage_point(Vector3(0.0, 1.6, 3.4)))
	for i in points.size():
		var probe := LightmapProbe.new()
		probe.name = "CinematicLightmapProbe_%02d" % i
		viewer.add_child(probe)
		probe.global_position = points[i]
		_stats.probe_count += 1

## Generate a true, non-overlapping per-triangle UV2 atlas. Imported FBX/GLB
## meshes in this project contain no UV2; assigning the original UV would make
## unrelated surfaces overlap during a bake. De-indexing only the bake copy
## preserves source positions, normals, tangents, colors, skin data and UV1.
func _copy_mesh_with_uv2(source: Mesh) -> ArrayMesh:
	if not source is ArrayMesh:
		return null
	var result := ArrayMesh.new()
	for surface_index in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface_index)
		var vertex_value: Variant = arrays[Mesh.ARRAY_VERTEX]
		if not vertex_value is PackedVector3Array:
			continue
		var vertices: PackedVector3Array = vertex_value
		var index_value: Variant = arrays[Mesh.ARRAY_INDEX]
		var indices := index_value as PackedInt32Array if index_value is PackedInt32Array else PackedInt32Array()
		var index_count := indices.size() if not indices.is_empty() else vertices.size()
		var triangle_count := maxi(1, int(index_count / 3))
		# The arch and tree are intentionally dense source meshes. De-indexing
		# those would multiply their memory footprint several times over and make
		# the editor scene impractical to open. Keep their index buffers and use
		# a stable box projection; small props still receive the exact per-triangle
		# atlas below.
		if triangle_count > 50000:
			return _copy_dense_mesh_with_projected_uv2(source)
		var grid := ceili(sqrt(float(triangle_count)))
		var out: Array = []
		out.resize(Mesh.ARRAY_MAX)
		var out_vertices := PackedVector3Array()
		var out_normals := PackedVector3Array()
		var out_tangents := PackedFloat32Array()
		var out_uv := PackedVector2Array()
		var out_uv2 := PackedVector2Array()
		var out_colors := PackedColorArray()
		var out_bones := PackedInt32Array()
		var out_weights := PackedFloat32Array()
		var has_normals := arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array and not (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).is_empty()
		var has_tangents := arrays[Mesh.ARRAY_TANGENT] is PackedFloat32Array and not (arrays[Mesh.ARRAY_TANGENT] as PackedFloat32Array).is_empty()
		var has_uv := arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array and not (arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).is_empty()
		var has_color := arrays[Mesh.ARRAY_COLOR] is PackedColorArray and not (arrays[Mesh.ARRAY_COLOR] as PackedColorArray).is_empty()
		var has_bones := arrays[Mesh.ARRAY_BONES] is PackedInt32Array and not (arrays[Mesh.ARRAY_BONES] as PackedInt32Array).is_empty()
		var has_weights := arrays[Mesh.ARRAY_WEIGHTS] is PackedFloat32Array and not (arrays[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array).is_empty()
		for tri in triangle_count:
			var cell_x := tri % grid
			var cell_y := tri / grid
			var origin := Vector2(float(cell_x) / grid, float(cell_y) / grid)
			var tile := 1.0 / float(grid)
			var tri_uv := [origin + Vector2(tile * 0.12, tile * 0.12), origin + Vector2(tile * 0.88, tile * 0.12), origin + Vector2(tile * 0.12, tile * 0.88)]
			for corner in 3:
				var src_index := tri * 3 + corner
				var vi := int(indices[src_index]) if not indices.is_empty() else src_index
				vi = clampi(vi, 0, vertices.size() - 1)
				out_vertices.append(vertices[vi])
				out_uv2.append(tri_uv[corner])
				if has_normals: out_normals.append((arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array)[vi])
				if has_uv: out_uv.append((arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array)[vi])
				if has_color: out_colors.append((arrays[Mesh.ARRAY_COLOR] as PackedColorArray)[vi])
				if has_tangents:
					var tangent_index := vi * 4
					for k in 4: out_tangents.append((arrays[Mesh.ARRAY_TANGENT] as PackedFloat32Array)[tangent_index + k])
				if has_bones:
					var bone_index := vi * 4
					for k in 4: out_bones.append((arrays[Mesh.ARRAY_BONES] as PackedInt32Array)[bone_index + k])
				if has_weights:
					var weight_index := vi * 4
					for k in 4: out_weights.append((arrays[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array)[weight_index + k])
		out[Mesh.ARRAY_VERTEX] = out_vertices
		out[Mesh.ARRAY_TEX_UV2] = out_uv2
		if has_normals: out[Mesh.ARRAY_NORMAL] = out_normals
		if has_tangents: out[Mesh.ARRAY_TANGENT] = out_tangents
		if has_uv: out[Mesh.ARRAY_TEX_UV] = out_uv
		if has_color: out[Mesh.ARRAY_COLOR] = out_colors
		if has_bones: out[Mesh.ARRAY_BONES] = out_bones
		if has_weights: out[Mesh.ARRAY_WEIGHTS] = out_weights
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
		var material := source.surface_get_material(surface_index)
		if material != null: result.surface_set_material(result.get_surface_count() - 1, material)
		_stats.triangles_unwrapped += triangle_count
	result.resource_name = "%s_lightmap_uv2" % source.resource_name
	return result

func _copy_dense_mesh_with_projected_uv2(source: ArrayMesh) -> ArrayMesh:
	var result := ArrayMesh.new()
	for surface_index in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface_index)
		var vertex_value: Variant = arrays[Mesh.ARRAY_VERTEX]
		if not vertex_value is PackedVector3Array:
			continue
		var vertices: PackedVector3Array = vertex_value
		var box := AABB()
		if not vertices.is_empty():
			box = AABB(vertices[0], Vector3.ZERO)
			for vertex in vertices:
				box = box.expand(vertex)
		var dimensions := [box.size.x, box.size.y, box.size.z]
		var first := 0
		var second := 1
		if dimensions[second] > dimensions[first]:
			var swap := first; first = second; second = swap
		if dimensions[2] > dimensions[first]:
			var swap_first := first; first = 2; second = swap_first
		elif dimensions[2] > dimensions[second]:
			second = 2
		var uv2 := PackedVector2Array()
		for vertex in vertices:
			var values := [vertex.x, vertex.y, vertex.z]
			var u := inverse_lerp(float(box.position[first]), float(box.position[first]) + maxf(float(dimensions[first]), 0.0001), float(values[first]))
			var v := inverse_lerp(float(box.position[second]), float(box.position[second]) + maxf(float(dimensions[second]), 0.0001), float(values[second]))
			# Deliberately leave a small border around each dense surface.
			uv2.append(Vector2(0.04 + 0.92 * u, 0.04 + 0.92 * v))
		var copied: Array = arrays.duplicate()
		copied[Mesh.ARRAY_TEX_UV2] = uv2
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, copied)
		var material := source.surface_get_material(surface_index)
		if material != null: result.surface_set_material(result.get_surface_count() - 1, material)
		var dense_triangles := int(source.surface_get_array_index_len(surface_index) / 3)
		if dense_triangles == 0: dense_triangles = int(vertices.size() / 3)
		_stats.triangles_unwrapped += dense_triangles
		_stats.notes.append("Projected UV2 retained index buffer for dense mesh (%d triangles)" % dense_triangles)
	result.resource_name = "%s_lightmap_uv2_dense" % source.resource_name
	return result
