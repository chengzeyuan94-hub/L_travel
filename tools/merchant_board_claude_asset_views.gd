extends Node
## Renders one mountain-kit GLB in Godot for acceptance: four orthographic views
## (front = looking north from the south, back, left = looking east from the west,
## right) plus one board-camera view (orthographic, 40 deg elevation, like the
## merchant board's target framing), with the board's lighting.
## Args: -- --glb=/abs/path.glb --out=/abs/dir [--name=prefix]

const IMAGE := Vector2i(900, 900)

var viewport: SubViewport
var camera: Camera3D
var glb := ""
var out_dir := ""
var prefix := "asset"
var no_ground := false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--glb="):
			glb = arg.trim_prefix("--glb=")
		elif arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--name="):
			prefix = arg.trim_prefix("--name=")
		elif arg == "--no-ground":
			no_ground = true
	if glb == "" or out_dir == "":
		push_error("need --glb= and --out=")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	viewport = SubViewport.new()
	viewport.size = IMAGE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	add_child(viewport)
	var root := Node3D.new()
	viewport.add_child(root)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.82, 0.84, 0.86)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.84, 0.83, 0.9)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.9
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.92, 0.78)
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	sun.transform = Transform3D(Basis.looking_at(Vector3(0.72, -0.66, 0.12).normalized(), Vector3.UP), Vector3.ZERO)
	root.add_child(sun)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(glb, state) != OK:
		push_error("cannot load " + glb)
		get_tree().quit(1)
		return
	var model := doc.generate_scene(state) as Node3D
	root.add_child(model)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.93
	var box := AABB()
	var first := true
	for mi in _meshes(model):
		mi.material_override = mat
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	# ground plane for contact
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.9, 0.78, 0.5)
	ground.material_override = gm
	if not no_ground:
		root.add_child(ground)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.current = true
	root.add_child(camera)
	var c := box.get_center()
	var span := maxf(box.size.x, maxf(box.size.y, box.size.z)) * 1.25
	camera.size = span
	var report := {"glb": glb, "aabb": [box.position.x, box.position.y, box.position.z, box.size.x, box.size.y, box.size.z], "views": []}
	# +Z is south (toward the board camera); front view looks from +Z toward -Z.
	var views := {
		"front": Vector3(0, 0, 1), "back": Vector3(0, 0, -1),
		"left": Vector3(-1, 0, 0), "right": Vector3(1, 0, 0),
		"board": Vector3(0, sin(deg_to_rad(40.2)), cos(deg_to_rad(40.2))),
	}
	for v: String in views:
		var dir: Vector3 = views[v]
		camera.position = c + dir * 50.0
		camera.look_at(c, Vector3.UP)
		for i in 20:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := viewport.get_texture().get_image()
		var path := out_dir.path_join("%s-godot-%s.png" % [prefix, v])
		img.save_png(path)
		report.views.append(path)
	var f := FileAccess.open(out_dir.path_join("%s-godot-report.json" % prefix), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	print("ASSET_VIEWS_DONE ", out_dir)
	get_tree().quit()


func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for ch in n.get_children():
		out.append_array(_meshes(ch))
	return out
