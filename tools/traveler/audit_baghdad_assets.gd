extends SceneTree
## Baghdad S1: original imported geometry/material audit and four orthographic views.
## godot --path <project> --script res://tools/traveler/audit_baghdad_assets.gd -- --view=baghdad --out=<directory>

const ASSETS := {
	"arch": "res://assets/traveler/baghdad/ancient+stone+arch+3d+model.fbx",
	"tree": "res://assets/traveler/baghdad/tree+3d+model.fbx",
	"mosque": "res://assets/traveler/baghdad/desert+mosque+3d+model.fbx",
}
const VIEWS := ["front", "left", "back", "right"]
var output := ""
var measure_only := false
var report: Dictionary = {"schema": "silkroad.baghdad-assets.v1", "assets": {}}

func _initialize() -> void:
	var view := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg.begins_with("--view="): view = arg.trim_prefix("--view=")
		if arg == "--measure-only": measure_only = true
	if output.is_empty() or view != "baghdad":
		push_error("Requires --view=baghdad and --out=<directory>"); quit(1); return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DirAccess.make_dir_recursive_absolute(output)
	call_deferred("run")

func xyz(v: Vector3) -> Array: return [v.x, v.y, v.z]

func relative_transform(node: Node3D, subject: Node3D) -> Transform3D:
	var result := node.transform
	var parent := node.get_parent()
	while parent is Node3D and parent != subject:
		result = parent.transform * result
		parent = parent.get_parent()
	return result

func inspect(subject: Node3D, key: String) -> Dictionary:
	var doc: Dictionary = {"asset": ASSETS[key], "meshes": [], "triangles": 0, "vertices": 0, "surfaces": 0, "materials_preserved": true}
	var bbox := AABB()
	var first := true
	var arch_faces := PackedVector3Array()
	for node in subject.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null: continue
		var xf := relative_transform(mi, subject)
		var bound := xf * mi.mesh.get_aabb()
		bbox = bound if first else bbox.merge(bound)
		first = false
		var item: Dictionary = {"path": str(subject.get_path_to(mi)), "mesh_class": mi.mesh.get_class(), "transform": {"origin": xyz(xf.origin), "basis_x": xyz(xf.basis.x), "basis_y": xyz(xf.basis.y), "basis_z": xyz(xf.basis.z)}, "surfaces": []}
		for si in mi.mesh.get_surface_count():
			var arrays: Array = mi.mesh.surface_get_arrays(si)
			var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
			var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT] if arrays[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
			var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			var triangles: int = (indices.size() if not indices.is_empty() else positions.size()) / 3
			var material: Material = mi.get_active_material(si)
			var mat: Dictionary = {"class": material.get_class() if material else "null", "name": material.resource_name if material else ""}
			if material is StandardMaterial3D:
				var standard := material as StandardMaterial3D
				mat.merge({"albedo_color": standard.albedo_color.to_html(), "roughness": standard.roughness, "metallic": standard.metallic, "normal_enabled": standard.normal_enabled, "normal_scale": standard.normal_scale, "cull_mode": standard.cull_mode, "vertex_color_use_as_albedo": standard.vertex_color_use_as_albedo, "textures": {}})
				for slot in {"albedo": BaseMaterial3D.TEXTURE_ALBEDO, "normal": BaseMaterial3D.TEXTURE_NORMAL, "roughness": BaseMaterial3D.TEXTURE_ROUGHNESS, "metallic": BaseMaterial3D.TEXTURE_METALLIC}:
					var texture := standard.get_texture({"albedo": BaseMaterial3D.TEXTURE_ALBEDO, "normal": BaseMaterial3D.TEXTURE_NORMAL, "roughness": BaseMaterial3D.TEXTURE_ROUGHNESS, "metallic": BaseMaterial3D.TEXTURE_METALLIC}[slot])
					mat.textures[slot] = {"path": texture.resource_path, "size": [texture.get_width(), texture.get_height()]} if texture else null
			item.surfaces.append({"index": si, "triangles": triangles, "vertices": positions.size(), "normals": normals.size(), "tangents": tangents.size() / 4, "uv": uv.size(), "material": mat})
			doc.triangles += triangles; doc.vertices += positions.size(); doc.surfaces += 1
			if key == "arch":
				if indices.is_empty():
					for point in positions: arch_faces.append(xf * point)
				else:
					for index in indices: arch_faces.append(xf * positions[index])
		doc.meshes.append(item)
	doc["mesh_instances"] = doc.meshes.size()
	doc["aabb_position"] = xyz(bbox.position)
	doc["aabb_size"] = xyz(bbox.size)
	doc["aabb"] = bbox
	if key == "arch": doc["arch_opening"] = opening_measure(arch_faces, bbox)
	return doc

func opening_measure(faces: PackedVector3Array, bbox: AABB) -> Dictionary:
	# Intersect original triangles with vertical X planes. Union their projected
	# Y intervals; empty spans correspond to an unobstructed through-opening.
	var scans: Array = []
	for x in [-0.08, -0.04, 0.0, 0.04, 0.08]:
		var intervals: Array[Vector2] = []
		for fi in range(0, faces.size(), 3):
			var a := faces[fi]; var b := faces[fi + 1]; var c := faces[fi + 2]
			if x < minf(a.x, minf(b.x, c.x)) or x > maxf(a.x, maxf(b.x, c.x)): continue
			var ys: Array[float] = []
			for edge in [[a, b], [b, c], [c, a]]:
				var v: Vector3 = edge[0]; var w: Vector3 = edge[1]
				if absf(w.x - v.x) < 0.0000001: continue
				var t: float = (x - v.x) / (w.x - v.x)
				if t >= 0.0 and t <= 1.0: ys.append(lerpf(v.y, w.y, t))
			if ys.size() >= 2:
				ys.sort(); intervals.append(Vector2(ys[0], ys[-1]))
		intervals.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
		var merged: Array[Vector2] = []
		for segment in intervals:
			if merged.is_empty() or segment.x > merged[-1].y + 0.000002: merged.append(segment)
			else: merged[-1].y = maxf(merged[-1].y, segment.y)
		var largest := Vector2(bbox.position.y, bbox.position.y)
		var previous := bbox.position.y
		for segment in merged:
			if segment.x - previous > largest.y - largest.x: largest = Vector2(previous, segment.x)
			previous = maxf(previous, segment.y)
		scans.append({"x": x, "open_floor_y": largest.x, "inner_arch_y": largest.y, "clear_height": largest.y - largest.x})
	var widths: Array = []
	for y in [0.05, 0.1, 0.2, 0.3, 0.4, 0.5]:
		var intervals: Array[Vector2] = []
		for fi in range(0, faces.size(), 3):
			var a := faces[fi]; var b := faces[fi + 1]; var c := faces[fi + 2]
			if y < minf(a.y, minf(b.y, c.y)) or y > maxf(a.y, maxf(b.y, c.y)): continue
			var xs: Array[float] = []
			for edge in [[a, b], [b, c], [c, a]]:
				var v: Vector3 = edge[0]; var w: Vector3 = edge[1]
				if absf(w.y - v.y) < 0.0000001: continue
				var t: float = (y - v.y) / (w.y - v.y)
				if t >= 0.0 and t <= 1.0: xs.append(lerpf(v.x, w.x, t))
			if xs.size() >= 2:
				xs.sort(); intervals.append(Vector2(xs[0], xs[-1]))
		var left := bbox.position.x
		var right := bbox.end.x
		for segment in intervals:
			if segment.y <= 0.0: left = maxf(left, segment.y)
			elif segment.x >= 0.0: right = minf(right, segment.x)
			else: left = 0.0; right = 0.0; break
		widths.append({"y": y, "inner_left_x": left, "inner_right_x": right, "clear_width": right - left})
	var height: float = scans[2].clear_height
	return {"method": "Exact triangle / plane intersections; union of projected intervals across entire arch depth. Largest uncovered Y interval is the unobstructed through-opening; horizontal scans measure the open gap that contains X=0.", "coordinate_space": "FBX root space; accumulated imported node transforms", "vertical_scans": scans, "horizontal_scans": widths, "reference_floor_y": scans[2].open_floor_y, "central_inner_arch_y": scans[2].inner_arch_y, "central_clear_height": height, "contract_clear_height_u": 2.55, "uniform_scale_for_contract": 2.55 / height, "resulting_total_height_u": bbox.size.y * 2.55 / height, "front_direction": "+Z; front camera at +Z looks towards -Z, wooden door and iron ring on image left; red tapestry on image right", "note": "Central keystone hangs below neighboring arch stones, so center-line clearance is slightly lower than the +/-0.04 scans. Use the central unobstructed clearance to satisfy the 2.55u net opening height."}

func run() -> void:
	if measure_only:
		var packed := load(ASSETS.arch) as PackedScene
		var subject := packed.instantiate() as Node3D
		var doc := inspect(subject, "arch")
		var file := FileAccess.open(output.path_join("arch-clearance.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(doc.arch_opening, "  ")); file.close()
		subject.free()
		print("BAGHDAD_ARCH_CLEARANCE ", JSON.stringify(doc.arch_opening))
		quit(); return
	var vp := SubViewport.new()
	vp.size = Vector2i(1920, 1080); vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X; vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR; environment.background_color = Color(0.62, 0.63, 0.66)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; environment.ambient_light_color = Color(0.70, 0.74, 0.82); environment.ambient_light_energy = 0.55
	var we := WorldEnvironment.new(); we.environment = environment; vp.add_child(we)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.near = 0.001; vp.add_child(camera); camera.make_current()
	var key_light := DirectionalLight3D.new(); key_light.light_color = Color(1.0, 0.95, 0.88); key_light.light_energy = 1.7; vp.add_child(key_light)
	var fill := DirectionalLight3D.new(); fill.light_color = Color(0.70, 0.78, 1.0); fill.light_energy = 0.45; vp.add_child(fill)
	for key in ASSETS:
		var packed := load(ASSETS[key]) as PackedScene
		assert(packed != null, "Asset must load")
		var subject := packed.instantiate() as Node3D; vp.add_child(subject)
		var doc := inspect(subject, key)
		var bbox: AABB = doc.aabb; doc.erase("aabb")
		var span := maxf(bbox.size.x, maxf(bbox.size.y, bbox.size.z))
		var center := bbox.get_center()
		camera.size = span * 1.15; camera.far = span * 20.0 + 10.0
		doc["views"] = []
		for i in VIEWS.size():
			var yaw := PI * 0.5 * float(i)
			var basis := Basis(Vector3.UP, yaw)
			camera.transform = Transform3D(basis, center + basis * Vector3(0.0, 0.0, span * 3.0))
			key_light.basis = Basis(Vector3.UP, yaw - 0.7) * Basis(Vector3.RIGHT, -0.6)
			fill.basis = Basis(Vector3.UP, yaw + 2.3) * Basis(Vector3.RIGHT, -0.2)
			for f in 5: await process_frame
			await RenderingServer.frame_post_draw
			var image := vp.get_texture().get_image()
			var path: String = output.path_join(key + "-" + VIEWS[i] + ".png")
			var error := image.save_png(path)
			assert(error == OK, "Screenshot save must succeed")
			doc.views.append({"view": VIEWS[i], "path": path, "image_size": [image.get_width(), image.get_height()], "viewport_size": [vp.size.x, vp.size.y], "projection": "orthographic", "camera_position": xyz(camera.position), "camera_target": xyz(center), "orthographic_size": camera.size, "save_error": error})
			report.assets[key] = doc
		var individual := FileAccess.open(output.path_join(key + ".json"), FileAccess.WRITE)
		individual.store_string(JSON.stringify(doc, "  ")); individual.close()
		print("BAGHDAD_ASSET ", JSON.stringify({"asset": key, "triangles": doc.triangles, "aabb_position": doc.aabb_position, "aabb_size": doc.aabb_size, "arch_opening": doc.get("arch_opening", {})}))
		subject.queue_free(); await process_frame
	report["note"] = "Original imported StandardMaterial3D and geometry, unchanged. Neutral orthographic inspection lighting is not the sunset scene look. Front camera looks along -Z from +Z."
	var file := FileAccess.open(output.path_join("asset-audit.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ")); file.close()
	quit()
