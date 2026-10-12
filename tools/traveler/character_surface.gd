extends RefCounted
## Collision-only floor extraction for the traveler; authored city visuals stay intact.
## Changan's courtyard is at y=0.669365 and its approach slabs at y=0.692708,
## above the Terrain64 floor (y=0.6434). Querying Terrain64 alone sinks the feet.

const NATIVE_SIZE := Vector2(1920, 1080)
const UP_DOT_MIN := 0.985
const MIN_TRIANGLE_AREA := 0.001

var host: Node3D
var ground_layer := 0
var report: Dictionary = {}

func configure(viewer: Node3D, collision_parent: Node3D, layer: int, max_city_floor_rise: float = 0.12) -> Dictionary:
	host = viewer
	ground_layer = layer
	var city := host.world.get_node_or_null("Cities/changan") as Node3D
	if city == null:
		push_error("Traveler city floor extraction: changan is missing")
		return {}
	var faces := PackedVector3Array()
	var levels: Dictionary = {}
	var base_y := city.global_position.y
	for candidate in city.find_children("*", "MeshInstance3D", true, false):
		var node := candidate as MeshInstance3D
		if node.mesh == null:
			continue
		for surface in node.mesh.get_surface_count():
			var material := node.get_active_material(surface)
			# Plants and emissive geometry have small, sometimes horizontal faces.
			# They must not become little invisible stepping stones.
			if material == null or material.resource_name != "Atlas_solid":
				continue
			var arrays := node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var count := indices.size() if not indices.is_empty() else vertices.size()
			for offset in range(0, count, 3):
				var a: Vector3 = node.global_transform * vertices[indices[offset] if not indices.is_empty() else offset]
				var b: Vector3 = node.global_transform * vertices[indices[offset + 1] if not indices.is_empty() else offset + 1]
				var c: Vector3 = node.global_transform * vertices[indices[offset + 2] if not indices.is_empty() else offset + 2]
				var cross := (c - a).cross(b - a)
				if cross.length() * 0.5 < MIN_TRIANGLE_AREA:
					continue
				if cross.normalized().y < UP_DOT_MIN:
					continue
				if minf(a.y, minf(b.y, c.y)) < base_y - 0.002:
					continue
				if maxf(a.y, maxf(b.y, c.y)) > base_y + max_city_floor_rise:
					continue
				faces.append_array(PackedVector3Array([a, b, c]))
				var level := str(snappedf((a.y + b.y + c.y) / 3.0, 0.00001))
				levels[level] = int(levels.get(level, 0)) + 1
	var body := StaticBody3D.new()
	body.name = "TravelerCityWalkableFloors"
	body.collision_layer = ground_layer
	body.collision_mask = 0
	collision_parent.add_child(body)
	# Vertices are already in world space, independent of the parent transform.
	body.global_transform = Transform3D.IDENTITY
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var shape_node := CollisionShape3D.new()
	shape_node.shape = shape
	body.add_child(shape_node)
	report = {"city": str(city.get_path()), "floor_triangles": faces.size() / 3,
		"level_triangle_counts": levels, "city_base_y": base_y,
		"max_city_floor_rise_u": max_city_floor_rise,
		"up_dot_min": UP_DOT_MIN, "collision_only": true}
	return report

func query_screen(pixel: Vector2) -> Dictionary:
	var viewport_size: Vector2 = host.get_viewport().get_visible_rect().size
	var screen: Vector2 = pixel / NATIVE_SIZE * viewport_size
	var origin: Vector3 = host.camera.project_ray_origin(screen)
	var direction: Vector3 = host.camera.project_ray_normal(screen)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 80.0, ground_layer)
	return host.get_world_3d().direct_space_state.intersect_ray(query)

func query_vertical(world_position: Vector3, step_up: float = 0.16, step_down: float = 0.6) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(world_position + Vector3.UP * step_up,
		world_position - Vector3.UP * step_down, ground_layer)
	return host.get_world_3d().direct_space_state.intersect_ray(query)
