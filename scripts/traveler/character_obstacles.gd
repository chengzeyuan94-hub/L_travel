extends RefCounted
## Collision-only copies of nearby scene geometry. No visual mesh is changed.
## Connected solid pieces become convex volumes, so being inside a rock is
## blocked too (a concave triangle shell only detects its surface).

var host: Node3D
var obstacle_layer := 0
var region := AABB()
var report: Dictionary = {}
var _components: Dictionary = {}
var _capsules: Dictionary = {}
var _shapes: Dictionary = {}

func configure(viewer: Node3D, collision_parent: Node3D, layer: int, world_region: AABB) -> Dictionary:
	host = viewer
	obstacle_layer = layer
	region = world_region.grow(0.2)
	var counts := {"multimesh_instances": 0, "city_meshes": 0, "convex_pieces": 0, "sources": {}}
	for branch_name in ["VegetationHigh", "NaturalDetails"]:
		var branch: Node = host.world.get_node_or_null(branch_name)
		if branch == null:
			continue
		for candidate in branch.find_children("*", "MultiMeshInstance3D", true, false):
			var node := candidate as MultiMeshInstance3D
			var label := String(node.name).to_lower()
			if label.contains("grass") or label.contains("flower") or node.multimesh == null:
				continue
			var mesh := node.multimesh.mesh
			if mesh == null:
				continue
			for instance_index in node.multimesh.instance_count:
				var placement: Transform3D = node.global_transform * node.multimesh.get_instance_transform(instance_index)
				if absf(placement.basis.determinant()) < 0.000001:
					continue
				if not region.intersects(placement * mesh.get_aabb()):
					continue
				var added := _add_mesh_pieces(mesh, placement, collision_parent, String(node.name) + "_" + str(instance_index), false, 0.0)
				if added > 0:
					counts.multimesh_instances += 1
					counts.convex_pieces += added
					counts.sources[branch_name] = int(counts.sources.get(branch_name, 0)) + added
	var city := host.world.get_node_or_null("Cities/changan") as Node3D
	if city != null:
		for candidate in city.find_children("*", "MeshInstance3D", true, false):
			var node := candidate as MeshInstance3D
			if node.mesh == null or not region.intersects(node.global_transform * node.get_aabb()):
				continue
			var added := _add_mesh_pieces(node.mesh, node.global_transform, collision_parent, "Changan_" + String(node.name), true, city.global_position.y)
			if added > 0:
				counts.city_meshes += 1
				counts.convex_pieces += added
				counts.sources["City"] = int(counts.sources.get("City", 0)) + added
	report = counts
	report["world_region"] = str(region)
	report["collision_only"] = true
	report["method"] = "Near-region connected mesh pieces as closed convex obstacles; upright body capsule ignores crowns above head; grass/flowers excluded."
	return report

func _add_mesh_pieces(mesh: Mesh, placement: Transform3D, parent: Node3D, label: String, is_city: bool, city_base: float) -> int:
	var pieces: Array = _mesh_components(mesh)
	var body: StaticBody3D = null
	var added := 0
	for component_index in pieces.size():
		var piece: Dictionary = pieces[component_index]
		var bounds: AABB = placement * piece.bounds
		if not region.intersects(bounds):
			continue
		# Ground panels and approach slabs remain walkable through the separate
		# floor collision layer, rather than becoming obstacle volumes.
		if is_city and bounds.size.y <= 0.061 and bounds.end.y <= city_base + 0.12:
			continue
		# Reject blades/single decorative cards, preserving bush and trunk volumes.
		if bounds.size.y < 0.035 or (bounds.size.y < 0.11 and maxf(bounds.size.x, bounds.size.z) < 0.085):
			continue
		if piece.points.size() < 4:
			continue
		if body == null:
			body = StaticBody3D.new()
			body.name = "Obstacle_" + label
			body.collision_layer = obstacle_layer
			body.collision_mask = 0
			parent.add_child(body)
			body.global_transform = placement
		var cache_key := str(mesh.get_instance_id()) + ":" + str(component_index)
		if not _shapes.has(cache_key):
			var shape := ConvexPolygonShape3D.new()
			shape.points = piece.points
			_shapes[cache_key] = shape
		var child := CollisionShape3D.new()
		child.shape = _shapes[cache_key]
		body.add_child(child)
		added += 1
	return added

func _root_of(parents: Array[int], index: int) -> int:
	var root_index := index
	while parents[root_index] != root_index:
		root_index = parents[root_index]
	while parents[index] != index:
		var next := parents[index]
		parents[index] = root_index
		index = next
	return root_index

func _mesh_components(mesh: Mesh) -> Array:
	var mesh_id := mesh.get_instance_id()
	if _components.has(mesh_id):
		return _components[mesh_id]
	var pieces: Array = []
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var unique: Dictionary = {}
		var positions := PackedVector3Array()
		var remap := PackedInt32Array()
		var parents: Array[int] = []
		for vertex in vertices:
			# Importers duplicate vertices at normal/UV seams. Weld by position
			# solely for collision connectivity, without touching the source mesh.
			var key := Vector3i(roundi(vertex.x * 100000.0), roundi(vertex.y * 100000.0), roundi(vertex.z * 100000.0))
			if not unique.has(key):
				unique[key] = positions.size()
				parents.append(positions.size())
				positions.append(vertex)
			remap.append(int(unique[key]))
		var count := indices.size() if not indices.is_empty() else vertices.size()
		for offset in range(0, count, 3):
			var a := remap[indices[offset] if not indices.is_empty() else offset]
			var b := remap[indices[offset + 1] if not indices.is_empty() else offset + 1]
			var c := remap[indices[offset + 2] if not indices.is_empty() else offset + 2]
			parents[_root_of(parents, b)] = _root_of(parents, a)
			parents[_root_of(parents, c)] = _root_of(parents, a)
		var grouped: Dictionary = {}
		for index in positions.size():
			var component := _root_of(parents, index)
			if not grouped.has(component):
				grouped[component] = PackedVector3Array()
			var points: PackedVector3Array = grouped[component]
			points.append(positions[index])
			grouped[component] = points
		for points: PackedVector3Array in grouped.values():
			if points.size() < 4:
				continue
			var bounds := AABB(points[0], Vector3.ZERO)
			for point in points:
				bounds = bounds.expand(point)
			pieces.append({"points": points, "bounds": bounds, "surface": surface})
	_components[mesh_id] = pieces
	return pieces

func _query(feet: Vector3, radius: float, height: float, bottom_clearance: float) -> PhysicsShapeQueryParameters3D:
	var key := str(radius) + ":" + str(height)
	if not _capsules.has(key):
		var capsule := CapsuleShape3D.new()
		capsule.radius = radius
		capsule.height = maxf(height, radius * 2.0)
		_capsules[key] = capsule
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _capsules[key]
	query.transform = Transform3D(Basis.IDENTITY, feet + Vector3.UP * (bottom_clearance + maxf(height, radius * 2.0) * 0.5))
	query.collision_mask = obstacle_layer
	query.collide_with_areas = false
	query.margin = 0.003
	return query

func is_clear(foot_world: Vector3, radius: float = 0.075, height: float = 0.36, bottom_clearance: float = 0.015) -> bool:
	return host.get_world_3d().direct_space_state.intersect_shape(_query(foot_world, radius, height, bottom_clearance), 1).is_empty()

func sweep(from_feet: Vector3, to_feet: Vector3, radius: float = 0.075, height: float = 0.36, bottom_clearance: float = 0.015) -> Dictionary:
	var query := _query(from_feet, radius, height, bottom_clearance)
	var physics := host.get_world_3d().direct_space_state
	if not physics.intersect_shape(query, 1).is_empty():
		return {"clear": false, "safe_fraction": 0.0, "started_overlapping": true}
	query.motion = to_feet - from_feet
	var fractions := physics.cast_motion(query)
	var safe := float(fractions[0]) if fractions.size() >= 1 else 0.0
	var end_clear := is_clear(to_feet, radius, height, bottom_clearance)
	return {"clear": safe >= 0.9999 and end_clear, "safe_fraction": safe if end_clear else minf(safe, 0.999), "started_overlapping": false}

func capsule_clear(foot_world: Vector3, height: float = 0.36, radius: float = 0.075) -> bool:
	return is_clear(foot_world, radius, height)

func capsule_sweep(from_feet: Vector3, to_feet: Vector3, height: float = 0.36, radius: float = 0.075) -> Dictionary:
	return sweep(from_feet, to_feet, radius, height)
