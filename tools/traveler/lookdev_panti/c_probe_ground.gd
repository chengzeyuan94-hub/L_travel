extends RefCounted
## C 线探针：沿屏幕竖线对雪地/城堡做射线，打印命中点（只读）。
func build(host: Node3D, cfg: Dictionary) -> Dictionary:
	var cam: Camera3D = host.camera
	var out: Dictionary = {}
	var ground: MeshInstance3D = host.get("snow_ground")
	var castle: MeshInstance3D = host.get("castle")
	var tg: TriangleMesh = ground.mesh.generate_triangle_mesh()
	var tc: TriangleMesh = castle.mesh.generate_triangle_mesh()
	for x in cfg.get("xs", [1037]):
		var col: Array = []
		for y in cfg.get("ys", [830, 840, 850, 860, 880, 900]):
			var sp := Vector2(float(x), float(y))
			var o: Vector3 = cam.project_ray_origin(sp)
			var d: Vector3 = cam.project_ray_normal(sp)
			var rec: Dictionary = {"y": y}
			for pair in [["g", ground, tg], ["c", castle, tc]]:
				var gi: MeshInstance3D = pair[1]
				var inv: Transform3D = gi.global_transform.affine_inverse()
				var r: Dictionary = (pair[2] as TriangleMesh).intersect_ray(inv * o, (inv.basis * d).normalized())
				if not r.is_empty():
					var p: Vector3 = gi.global_transform * (r["position"] as Vector3)
					rec[pair[0]] = [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01), snappedf(p.distance_to(o), 0.01)]
			col.append(rec)
		out[str(x)] = col
	print("C_GROUND ", JSON.stringify(out))
	return {}
