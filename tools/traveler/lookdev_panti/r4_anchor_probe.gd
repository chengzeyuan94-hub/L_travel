extends RefCounted
## r4 probe (robustness lens, not delivery code): where would c_warm_bounce.gd's "screen" anchors land if the
## live window had another aspect ratio? The project uses stretch aspect "expand" + Camera3D KEEP_HEIGHT, so a
## wider / narrower window changes the horizontal FOV. This mirrors c_warm_bounce._anchor({"screen": ..}) exactly,
## but on a throwaway SubViewport + Camera3D copy of the scene camera sized to each test aspect. Nothing is added
## to the scene permanently.

func build(host: Node3D, cfg: Dictionary) -> Dictionary:
	var cam: Camera3D = host.camera
	var castle: MeshInstance3D = host.get("castle") as MeshInstance3D
	var tm: TriangleMesh = castle.mesh.generate_triangle_mesh()
	var anchors: Array = cfg.get("anchors", [[835, 812], [985, 812], [1105, 812], [1320, 812], [1590, 812]])
	var sizes: Array = cfg.get("sizes", [[1920, 1080], [1280, 720], [1920, 1200], [1440, 1080], [2560, 1080]])
	var out: Dictionary = {}
	for s: Variant in sizes:
		var sa: Array = s
		var vw: int = int(sa[0])
		var vh: int = int(sa[1])
		var sv: SubViewport = SubViewport.new()
		sv.size = Vector2i(vw, vh)
		sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
		host.add_child(sv)
		var c2: Camera3D = Camera3D.new()
		c2.keep_aspect = cam.keep_aspect
		c2.fov = cam.fov
		c2.near = cam.near
		c2.far = cam.far
		sv.add_child(c2)
		c2.global_transform = cam.global_transform
		var rows: Array = []
		for a: Variant in anchors:
			var px: Array = a
			var vs: Vector2 = c2.get_viewport().get_visible_rect().size
			var sp: Vector2 = Vector2(float(px[0]) * vs.x / 1920.0, float(px[1]) * vs.y / 1080.0)
			var o: Vector3 = c2.project_ray_origin(sp)
			var d: Vector3 = c2.project_ray_normal(sp)
			var inv: Transform3D = castle.global_transform.affine_inverse()
			var r: Dictionary = tm.intersect_ray(inv * o, (inv.basis * d).normalized())
			if r.is_empty():
				rows.append({"px": px, "hit": false})
			else:
				var p: Vector3 = castle.global_transform * (r["position"] as Vector3)
				var back: Vector2 = cam.unproject_position(p)
				rows.append({"px": px, "hit": true, "pos": [snappedf(p.x, 0.001), snappedf(p.y, 0.001), snappedf(p.z, 0.001)],
					"as_seen_in_1080p_px": [int(back.x), int(back.y)]})
		out["%dx%d" % [vw, vh]] = rows
		sv.remove_child(c2)
		c2.free()
		host.remove_child(sv)
		sv.free()
	print("R4_ANCHOR_PROBE ", JSON.stringify(out))
	return out
