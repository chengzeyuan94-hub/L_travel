extends Node3D
## Static presentation geometry: four shared prototypes, explicit sampled contacts.
## The JSON is also the independent asset auditor's source for real mesh geometry.

const PLACEMENTS_PATH := "res://scripts/ui/ambient/corridor_017_placements.json"
const SCHEMA := "silkroad.corridor-props.v1"
var _configured := false
var _failure_reason := ""
var _source_path := PLACEMENTS_PATH
var _signature := ""
var _build_count := 0
var _instance_count := 0
var _triangle_count := 0
var _groups: Array[Dictionary] = []


func _init() -> void:
	name = "CorridorProps"
	set_process(false)
	set_physics_process(false)


func configure(_content: Dictionary, placements_path: String = PLACEMENTS_PATH) -> bool:
	_source_path = placements_path
	if not FileAccess.file_exists(placements_path):
		return _fail("missing placements file")
	var raw := FileAccess.get_file_as_string(placements_path)
	var signature := raw.sha256_text()
	if _configured and signature == _signature:
		return true
	clear()
	var parsed: Variant = JSON.parse_string(raw)
	if not parsed is Dictionary:
		return _fail("invalid JSON dictionary")
	var data: Dictionary = parsed
	var error := _validate(data)
	if not error.is_empty():
		return _fail(error)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color.WHITE
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for group: Dictionary in data["groups"]:
		var entries: Array = group["instances"]
		if entries.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		var colors := PackedColorArray()
		for value: Array in group["vertices"]:
			vertices.append(_v3(value))
		for value: Array in group["normals"]:
			normals.append(_v3(value))
		for value: Array in group["colors"]:
			colors.append(_color(value))
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(group["indices"])
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, material)
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = mesh
		multimesh.instance_count = entries.size()
		for i in entries.size():
			var entry: Dictionary = entries[i]
			var values: Array = entry["basis"]
			var basis := Basis(Vector3(values[0], values[1], values[2]), Vector3(values[3], values[4], values[5]), Vector3(values[6], values[7], values[8]))
			multimesh.set_instance_transform(i, Transform3D(basis, _v3(entry["position"])))
			multimesh.set_instance_color(i, _color(entry["color"]))
		var node := MultiMeshInstance3D.new()
		node.name = str(group["id"])
		node.multimesh = multimesh
		# Static low shrubs and rocks retain their contact shadows.
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(node)
		var triangles := (group["indices"] as Array).size() / 3
		_groups.append({"id": group["id"], "instances": entries.size(), "prototype_triangles": triangles})
		_instance_count += entries.size()
		_triangle_count += triangles * entries.size()
	_configured = true
	_failure_reason = ""
	_signature = signature
	_build_count += 1
	return true


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_configured = false
	_signature = ""
	_failure_reason = ""
	_instance_count = 0
	_triangle_count = 0
	_groups.clear()


func get_missing_asset_paths() -> PackedStringArray:
	if not FileAccess.file_exists(_source_path) or not _failure_reason.is_empty():
		return PackedStringArray([_source_path])
	return PackedStringArray()


func get_diagnostics() -> Dictionary:
	return {"configured": _configured, "failure_reason": _failure_reason, "source_path": _source_path,
		"source_sha256": _signature, "build_count": _build_count, "batch_count": _groups.size(),
		"instance_count": _instance_count, "rendered_triangles": _triangle_count,
		"process_enabled": is_processing(), "groups": _groups.duplicate(true)}


func _fail(reason: String) -> bool:
	clear()
	_failure_reason = reason
	return false


func _validate(data: Dictionary) -> String:
	if data.get("schema", "") != SCHEMA:
		return "unsupported placements schema"
	if not data.get("groups") is Array or (data["groups"] as Array).is_empty() or (data["groups"] as Array).size() > 4:
		return "expected one to four prototype groups"
	var ids: Array[String] = []
	var instance_ids: Array[String] = []
	var total := 0
	for value: Variant in data["groups"]:
		if not value is Dictionary:
			return "invalid prototype dictionary"
		var group: Dictionary = value
		var id := str(group.get("id", ""))
		if id.is_empty() or id in ids:
			return "invalid or duplicate prototype id"
		ids.append(id)
		for key in ["vertices", "normals", "colors", "indices", "instances", "foot_points"]:
			if not group.get(key) is Array:
				return "prototype missing " + key
		var vertices: Array = group["vertices"]
		if vertices.size() < 3 or vertices.size() > 4096:
			return "invalid prototype vertex count"
		if (group["normals"] as Array).size() != vertices.size() or (group["colors"] as Array).size() != vertices.size():
			return "prototype attribute lengths differ"
		for i in vertices.size():
			if not _numbers(vertices[i], 3) or not _numbers(group["normals"][i], 3) or not _numbers(group["colors"][i], 4, true):
				return "invalid prototype vertex attributes"
		var indices: Array = group["indices"]
		if indices.is_empty() or indices.size() % 3 != 0:
			return "invalid triangle indices"
		for index: Variant in indices:
			if not (index is int or index is float) or not is_finite(float(index)) or int(index) != float(index) or index < 0 or index >= vertices.size():
				return "triangle index out of bounds"
		if (group["foot_points"] as Array).is_empty():
			return "missing contact vertices"
		for foot: Variant in group["foot_points"]:
			if not _numbers(foot, 3):
				return "invalid contact vertex"
		for entry: Variant in group["instances"]:
			if not entry is Dictionary:
				return "invalid instance dictionary"
			var entry_id := str(entry.get("id", ""))
			if entry_id.is_empty() or entry_id in instance_ids:
				return "invalid or duplicate instance id"
			instance_ids.append(entry_id)
			if not _numbers(entry.get("position"), 3) or not _numbers(entry.get("basis"), 9) or not _numbers(entry.get("color"), 4, true):
				return "invalid instance transform or color"
			var b: Array = entry["basis"]
			var determinant := Basis(Vector3(b[0],b[1],b[2]),Vector3(b[3],b[4],b[5]),Vector3(b[6],b[7],b[8])).determinant()
			if determinant <= 0.001 or determinant > 8.0:
				return "invalid instance basis determinant"
			total += 1
	if total < 1 or total > 256 or total != int(data.get("instance_count", -1)):
		return "instance count mismatch"
	return ""


func _numbers(value: Variant, count: int, unit_range: bool = false) -> bool:
	if not value is Array or (value as Array).size() != count:
		return false
	for number: Variant in value:
		if not (number is int or number is float) or not is_finite(float(number)):
			return false
		if unit_range and (number < 0 or number > 1):
			return false
	return true


func _v3(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])


func _color(value: Array) -> Color:
	return Color(value[0], value[1], value[2], value[3])
