extends RefCounted
## C 线探针：打印营地、人物、城堡、岩石的世界坐标与屏幕投影（只读，不改场景）。
func _p(host: Node3D, v: Vector3) -> Array:
	var s: Vector2 = host.camera.unproject_position(v)
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001), int(s.x), int(s.y)]

func build(host: Node3D, _cfg: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	out["camera"] = _p(host, host.camera.global_position)
	out["cam_fwd"] = str(-host.camera.global_basis.z)
	var camp: Node3D = host.get("camp")
	if camp != null:
		for k in camp.props.keys():
			var n: MeshInstance3D = camp.props[k].node
			var ab: AABB = n.global_transform * n.get_aabb()
			out["prop_" + str(k)] = {"pos": _p(host, n.global_position), "min": _p(host, ab.position), "max": _p(host, ab.end), "center": _p(host, ab.get_center())}
		out["fire"] = _p(host, camp.fire.global_position)
		out["fire_light"] = _p(host, camp.fire.fire_light.global_position)
		out["seat"] = _p(host, camp.seat_world)
	var ch: Node3D = host.get("character")
	if ch != null:
		out["character"] = _p(host, ch.global_position)
		for mi in ch.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			var ab2: AABB = m.global_transform * m.get_aabb()
			out["char_" + str(m.name)] = {"min": _p(host, ab2.position), "max": _p(host, ab2.end), "center": _p(host, ab2.get_center())}
	var castle: MeshInstance3D = host.castle
	var cab: AABB = castle.global_transform * castle.get_aabb()
	out["castle"] = {"pos": _p(host, castle.global_position), "min": _p(host, cab.position), "max": _p(host, cab.end), "center": _p(host, cab.get_center()), "scale": str(castle.global_basis.get_scale())}
	for l in host.castle_lighting.spills:
		out["spill_" + str(l.name)] = _p(host, (l as OmniLight3D).global_position)
	var rocks: Array = []
	for rn in host.rock_nodes:
		var mmi := rn as MultiMeshInstance3D
		for i in mmi.multimesh.instance_count:
			var t: Transform3D = mmi.global_transform * mmi.multimesh.get_instance_transform(i)
			var p: Array = _p(host, t.origin)
			p.append(str(mmi.name))
			p.append(snappedf(t.basis.get_scale().x, 0.001))
			rocks.append(p)
	out["rocks"] = rocks
	out["world_children"] = host.world.get_children().map(func(c: Node) -> String: return str(c.name))
	out["ground_h_at_fire"] = host.snow_surface.call("height_at", Vector2(0, 0)) if host.snow_surface != null else 0
	print("C_PROBE ", JSON.stringify(out))
	return {"ok": true}
