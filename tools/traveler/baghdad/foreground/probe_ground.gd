extends SceneTree
class Host extends Node3D:
	var settings: Dictionary
	func stage_point(p: Vector3) -> Vector3:
		return Vector3(-p.x,p.y,p.z)

func _initialize() -> void:
	var host := Host.new()
	host.settings = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/baghdad_scene.edited.json"))
	var surface = load("res://scripts/traveler/baghdad/baghdad_ground.gd").new()
	var ground: MeshInstance3D = surface.build(host)
	for data in [["native_plane",PlaneMesh.new()],["authored_ground",ground.mesh]]:
		var arrays: Array = data[1].surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var a: int = idx[0] if not idx.is_empty() else 0
		var b: int = idx[1] if not idx.is_empty() else 1
		var c: int = idx[2] if not idx.is_empty() else 2
		print(data[0]," cross_dot_normal=",(v[b]-v[a]).cross(v[c]-v[a]).normalized().dot(n[a])," normal=",n[a])
	ground.free()
	host.free()
	quit()
