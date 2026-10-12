extends SceneTree
## Original props, 512-square neutral inspection previews. Does not modify materials.
## Godot --path <project> --script res://tools/traveler/baghdad/catalog_props.gd -- --view=baghdad --out=<absolute directory>

const MANIFEST := "res://docs/reports/traveler-baghdad-001/checkpoint-02/assets/source-manifest.json"
var output := ""
var sheet_only := false

func _initialize() -> void:
	var view := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.trim_prefix("--out=")
		if arg.begins_with("--view="): view = arg.trim_prefix("--view=")
		if arg == "--sheet-only": sheet_only = true
	if output.is_empty() or view != "baghdad":
		push_error("Requires --view=baghdad and --out=<absolute directory>")
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DirAccess.make_dir_recursive_absolute(output)
	call_deferred("run")

func xyz(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

func inspect(subject: Node3D, asset_path: String) -> Dictionary:
	var doc: Dictionary = {"asset": asset_path, "mesh_instances": 0, "triangles": 0, "vertices": 0, "surface_count": 0, "surfaces": []}
	var bounds := AABB()
	var first := true
	for node in subject.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null: continue
		var xf := subject.global_transform.affine_inverse() * mi.global_transform
		var bound := xf * mi.mesh.get_aabb()
		bounds = bound if first else bounds.merge(bound)
		first = false
		doc.mesh_instances += 1
		for si in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(si)
			var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var triangles: int = (indices.size() if not indices.is_empty() else positions.size()) / 3
			var material := mi.get_active_material(si)
			var mat: Dictionary = {"type": material.get_class() if material else "null", "name": material.resource_name if material else "", "textures": {}}
			if material is StandardMaterial3D:
				var standard := material as StandardMaterial3D
				mat.merge({"albedo_color": standard.albedo_color.to_html(), "roughness": standard.roughness, "metallic": standard.metallic, "normal_enabled": standard.normal_enabled, "normal_scale": standard.normal_scale})
				var slots := {"albedo": BaseMaterial3D.TEXTURE_ALBEDO, "normal": BaseMaterial3D.TEXTURE_NORMAL, "roughness": BaseMaterial3D.TEXTURE_ROUGHNESS, "metallic": BaseMaterial3D.TEXTURE_METALLIC}
				for slot in slots:
					var texture := standard.get_texture(slots[slot])
					mat.textures[slot] = {"path": texture.resource_path, "size": [texture.get_width(), texture.get_height()]} if texture else null
			doc.surfaces.append({"mesh": str(subject.get_path_to(mi)), "index": si, "triangles": triangles, "vertices": positions.size(), "material": mat})
			doc.triangles += triangles
			doc.vertices += positions.size()
			doc.surface_count += 1
	doc["aabb_position"] = xyz(bounds.position)
	doc["aabb_size"] = xyz(bounds.size)
	doc["bounds"] = bounds
	return doc

func run() -> void:
	if sheet_only:
		var previous: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output.path_join("catalog.json")))
		await render_sheet(previous)
		quit()
		return
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	var vp := SubViewport.new()
	vp.size = Vector2i(512, 512)
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.32, 0.34, 0.37)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.83, 0.91)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.near = 0.001
	vp.add_child(cam)
	cam.make_current()
	var key := DirectionalLight3D.new()
	key.light_color = Color(1.0, 0.95, 0.87)
	key.light_energy = 1.7
	key.rotation_degrees = Vector3(-38.0, -35.0, 0.0)
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_color = Color(0.7, 0.8, 1.0)
	fill.light_energy = 0.6
	fill.rotation_degrees = Vector3(-18.0, 110.0, 0.0)
	vp.add_child(fill)
	var report: Dictionary = {"assets": [], "note": "Three-quarter orthographic previews at 512x512; original geometry and materials unchanged; neutral inspection lighting only."}
	for asset in source.assets:
		var resource_path := "res://" + str(asset.path)
		var packed := load(resource_path) as PackedScene
		if packed == null:
			push_error("Cannot load " + resource_path)
			quit(1)
			return
		var subject := packed.instantiate() as Node3D
		vp.add_child(subject)
		var doc := inspect(subject, resource_path)
		var bound: AABB = doc.bounds
		doc.erase("bounds")
		var span := maxf(bound.size.x, maxf(bound.size.y, bound.size.z))
		var center := bound.get_center()
		cam.size = span * 1.25
		cam.far = span * 20.0 + 100.0
		cam.position = center + Vector3(0.7, 0.50, 1.0).normalized() * span * 3.0
		cam.look_at(center, Vector3.UP)
		for frame in 5: await process_frame
		await RenderingServer.frame_post_draw
		var image := vp.get_texture().get_image()
		var index: int = report.assets.size() + 1
		var stem := "%02d-" % index + resource_path.get_file().get_basename()
		var png_path := output.path_join(stem + ".png")
		var err := image.save_png(png_path)
		assert(err == OK, "Image save failed")
		doc.merge({"index": index, "preview": png_path, "image_size": [image.get_width(), image.get_height()], "viewport_size": [vp.size.x, vp.size.y], "camera_position": xyz(cam.position), "camera_target": xyz(center), "orthographic_size": cam.size, "save_error": err})
		var file := FileAccess.open(output.path_join(stem + ".json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(doc, "  "))
		file.close()
		report.assets.append(doc)
		print("PROP_CATALOG ", JSON.stringify({"path": resource_path, "triangles": doc.triangles, "aabb_size": doc.aabb_size, "image": png_path}))
		subject.queue_free()
		await process_frame
	var file := FileAccess.open(output.path_join("catalog.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	await render_sheet(report)
	quit()

func render_sheet(report: Dictionary) -> void:
	var sheet := SubViewport.new()
	sheet.size = Vector2i(1280, 364 * ceili(report.assets.size() / 4.0))
	sheet.disable_3d = true
	sheet.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sheet)
	var background := ColorRect.new()
	background.color = Color(0.13, 0.14, 0.16)
	background.size = Vector2(sheet.size)
	sheet.add_child(background)
	for i in report.assets.size():
		var doc: Dictionary = report.assets[i]
		var x: int = (i % 4) * 320
		var y: int = floori(i / 4.0) * 364
		var photo := TextureRect.new()
		photo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		photo.texture = ImageTexture.create_from_image(Image.load_from_file(doc.preview))
		photo.position = Vector2(x, y)
		photo.size = Vector2(320, 320)
		sheet.add_child(photo)
		var label := Label.new()
		label.text = "%02d  %s\n%d triangles" % [i + 1, str(doc.asset).get_file().replace("+", " "), doc.triangles]
		label.add_theme_font_size_override("font_size", 14)
		label.position = Vector2(x + 8, y + 321)
		label.size = Vector2(308, 42)
		sheet.add_child(label)
	for frame in 4: await process_frame
	await RenderingServer.frame_post_draw
	var path := output.path_join("contact-sheet.png")
	assert(sheet.get_texture().get_image().save_png(path) == OK)
	print("PROP_CONTACT_SHEET ", path)
