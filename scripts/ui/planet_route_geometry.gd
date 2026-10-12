extends RefCounted

## Indexed presentation ribbons. Logical route samples are never rewritten.
## Adjacent segments share the same miter pair; a bounded bevel closes sharp
## turns and reversals without the unbounded spike of a near-180-degree miter.
const SphereGeometry := preload("res://scripts/ui/planet_geometry.gd")
const SAMPLE_SPACING := 16.0
const MAX_MITER_RATIO := 2.5


static func build_geometry(polylines: Array, half_width: float, height: float) -> Dictionary:
	var result := {"positions": PackedVector3Array(), "normals": PackedVector3Array(),
		"indices": PackedInt32Array(), "polyline_count": 0, "sample_count": 0,
		"miter_join_count": 0, "bevel_join_count": 0}
	if half_width <= 0.0:
		return result
	for polyline in polylines:
		var points: PackedVector2Array = polyline
		var samples := _sample(points)
		if samples.size() < 2:
			continue
		result["polyline_count"] += 1
		result["sample_count"] += samples.size()
		var centers := PackedVector3Array()
		for sample in samples:
			centers.append(SphereGeometry.to_world(sample, height))
		var incoming: Array[Vector2i] = []
		var outgoing: Array[Vector2i] = []
		for index in centers.size():
			var center := centers[index]
			var normal := center.normalized()
			var before := Vector3.ZERO
			var after := Vector3.ZERO
			if index > 0:
				before = _tangent(center - centers[index - 1], normal)
			if index + 1 < centers.size():
				after = _tangent(centers[index + 1] - center, normal)
			if index == 0 or index + 1 == centers.size():
				var side := normal.cross(after if index == 0 else before).normalized()
				var pair := _pair(result, center, side * half_width)
				incoming.append(pair)
				outgoing.append(pair)
				continue
			var side_before := normal.cross(before).normalized()
			var side_after := normal.cross(after).normalized()
			var miter := (side_before + side_after).normalized()
			var denominator := miter.dot(side_after)
			if denominator >= 1.0 / MAX_MITER_RATIO:
				var pair := _pair(result, center, miter * half_width / denominator)
				incoming.append(pair)
				outgoing.append(pair)
				result["miter_join_count"] += 1
			else:
				# The two segment ends and the join fan share these exact indices.
				# At a true reversal the fan is collinear and is safely omitted;
				# the two opposite-oriented end pairs coincide without a gap.
				var first := _pair(result, center, side_before * half_width)
				var second := _pair(result, center, side_after * half_width)
				var middle := _vertex(result, center)
				incoming.append(first)
				outgoing.append(second)
				_triangle(result, first.x, second.x, middle)
				_triangle(result, first.y, middle, second.y)
				result["bevel_join_count"] += 1
		for index in range(1, centers.size()):
			var a := outgoing[index - 1]
			var b := incoming[index]
			_triangle(result, a.x, b.x, b.y)
			_triangle(result, a.x, b.y, a.y)
	return result


static func mesh_from_geometry(geometry: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if geometry["indices"].is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = geometry["positions"]
	arrays[Mesh.ARRAY_NORMAL] = geometry["normals"]
	arrays[Mesh.ARRAY_INDEX] = geometry["indices"]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func create_mesh(points: PackedVector2Array, half_width: float, height: float) -> ArrayMesh:
	return mesh_from_geometry(build_geometry([points], half_width, height))


static func _sample(points: PackedVector2Array) -> PackedVector2Array:
	var samples := PackedVector2Array()
	for point in points:
		if not point.is_finite():
			return PackedVector2Array()
		if samples.is_empty():
			samples.append(point)
			continue
		var previous := samples[-1]
		var distance := previous.distance_to(point)
		if distance < 0.0001:
			continue
		var subdivisions := maxi(1, ceili(distance / SAMPLE_SPACING))
		for step in range(1, subdivisions + 1):
			samples.append(previous.lerp(point, float(step) / subdivisions))
	return samples


static func _tangent(direction: Vector3, normal: Vector3) -> Vector3:
	return (direction - normal * direction.dot(normal)).normalized()


static func _vertex(geometry: Dictionary, position: Vector3) -> int:
	var index: int = geometry["positions"].size()
	geometry["positions"].append(position)
	geometry["normals"].append(position.normalized())
	return index


static func _pair(geometry: Dictionary, center: Vector3, offset: Vector3) -> Vector2i:
	var radius := center.length()
	# Keep both edges at the original route height, not a tangent-plane lift.
	return Vector2i(_vertex(geometry, (center - offset).normalized() * radius),
		_vertex(geometry, (center + offset).normalized() * radius))


static func _triangle(geometry: Dictionary, a: int, b: int, c: int) -> void:
	var pa: Vector3 = geometry["positions"][a]
	var pb: Vector3 = geometry["positions"][b]
	var pc: Vector3 = geometry["positions"][c]
	var normal := (pb - pa).cross(pc - pa)
	if normal.length_squared() < 0.00000000000001:
		return
	geometry["indices"].append(a)
	geometry["indices"].append(b if normal.dot(pa + pb + pc) > 0.0 else c)
	geometry["indices"].append(c if normal.dot(pa + pb + pc) > 0.0 else b)
