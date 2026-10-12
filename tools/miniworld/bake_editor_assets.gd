extends SceneTree
## Deterministically rebuild the editable library from local source meshes.
## Godot --headless --path . --script res://tools/miniworld/bake_editor_assets.gd
## Add -- --preview for a real native render, or -- --closeup for the city samples.
const Catalog = preload("res://scripts/editor/map_asset_catalog.gd")
var _serial := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(Catalog.PREFAB_DIR))
	for entry in Catalog.list_assets():
		var asset: Node3D = Catalog.build_source(entry.id)
		_serial = 0
		_prepare(asset, asset)
		var packed := PackedScene.new()
		var result := packed.pack(asset)
		if result != OK:
			push_error("Cannot pack " + entry.id)
			quit(1)
			return
		var path: String = Catalog.PREFAB_DIR + entry.id + ".tscn"
		result = ResourceSaver.save(packed, path)
		if result != OK:
			push_error("Cannot save " + path)
			quit(1)
			return
		print("Baked ", entry.id, " — ", _serial, " editable nodes")
		asset.free()
	var args := OS.get_cmdline_user_args()
	if "--preview" in args or "--closeup" in args:
		await _preview("--closeup" in args)
	quit()

func _prepare(node: Node, scene_root: Node) -> void:
	if node != scene_root:
		node.owner = scene_root
		_serial += 1
		if String(node.name).begins_with("@") or node.name == "MeshInstance3D":
			var prefix := "Detail"
			if node is MeshInstance3D:
				if node.mesh is BoxMesh: prefix = "TimberOrMasonry"
				elif node.mesh is CylinderMesh: prefix = "PostOrSpar"
				else: prefix = "SculptedSurface"
			node.name = "%s_%03d" % [prefix, _serial]
	if node is MeshInstance3D and node.material_override is StandardMaterial3D:
		var material:StandardMaterial3D = node.material_override
		if material.resource_name == "LanternGlow": material.resource_local_to_scene = true
	for child in node.get_children(): _prepare(child, scene_root)

func _preview(closeup: bool) -> void:
	root.size = Vector2i(1600, 1000)
	var world := Node3D.new()
	world.name = "AssetLibraryPreview"
	root.add_child(world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("d5dbd4")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("d2dce1")
	environment.environment.ambient_light_energy = 0.20
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -28, 0)
	sun.light_color = Color("ffffff")
	sun.light_energy = 0.70
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 50
	world.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 50)
	ground.mesh = plane
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color("bfc5b3")
	ground_material.roughness = 0.98
	ground.material_override = ground_material
	ground.position.y = -0.035
	world.add_child(ground)
	var choices := [
		["city_blue_dome",Vector3(-4.5,0,-3.0)], ["city_chinese",Vector3(0,0,-3.0)], ["city_caravanserai",Vector3(4.5,0,-3.0)],
		["mountain_snow",Vector3(-5.0,0,1.0)], ["mountain_sand",Vector3(0.7,0,1.0)], ["coast",Vector3(5.5,0,1.0)],
		["palm",Vector3(-5.4,0,4.3)], ["conifer",Vector3(-3.9,0,4.3)], ["broadleaf",Vector3(-2.7,0,4.3)], ["blossom",Vector3(-1.4,0,4.3)],
		["camel",Vector3(0.1,0,4.3)], ["market",Vector3(1.7,0,4.3)], ["ship",Vector3(3.4,0,4.3)], ["junk",Vector3(5.1,0,4.3)],
	]
	if closeup:
		choices = [["city_blue_dome",Vector3(-3.1,0,0)],["city_chinese",Vector3(0,0,0)],["city_caravanserai",Vector3(3.1,0,0)]]
	for choice in choices:
		var asset := Catalog.create(choice[0])
		asset.position = choice[1]
		world.add_child(asset)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 8.7 if closeup else 17.5
	camera.position = Vector3(6.3, 8.7, 14) if closeup else Vector3(9,16,24)
	world.add_child(camera)
	camera.look_at(Vector3(0,0.9,0) if closeup else Vector3(0,0.3,0.1))
	camera.current = true
	for i in range(12): await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var directory := "res://artifacts/map_editor/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var path := directory + ("city_samples_native.png" if closeup else "asset_library_native.png")
	image.save_png(ProjectSettings.globalize_path(path))
	print("NATIVE_RENDER_SAVED ", path, " ", image.get_size())
