extends Node3D
## Engine-side check of one custom-map specialty icon (run with a real renderer, not --headless):
##   HOME=<scratch> Godot --path . --audio-driver Dummy res://tools/map_catalogue/godot_verify_specialty.tscn \
##       -- --key kaolin --glb <abs>/kaolin.glb --out <abs>/04-godot-ortho.png
## 1. four orthographic views (front, right, back, left — the order of render_asset.py's strip and of
##    02-fourview.png) of the exported GLB, loaded at runtime with GLTFDocument, lit by the icon
##    studio's three sun directions, saved as one 2048x512 strip;
## 2. the game's own icon lookup: lshu_icons.gd good(<key>) must return the new 3D icon (not the
##    fallback), and GameData's conventional fallback path good_<key>_128.png must exist.
## Prints one line "SPECIALTY_VERIFY {json}" and quits (exit code 1 on a failed check).

const W := 512
# Blender euler XYZ (degrees) and strength of the three studio suns (tools/ui_icons/setup_studio.py)
const SUNS := [[Vector3(45, 0, -35), 1.15, Color(1.0, 0.95, 0.86)],
		[Vector3(70, 0, 145), 0.3, Color(0.82, 0.88, 1.0)],
		[Vector3(112, 0, 205), 0.45, Color(1.0, 0.9, 0.75)]]


func _args() -> Dictionary:
	var out := {}
	var a := OS.get_cmdline_user_args()
	for i in range(0, a.size() - 1, 2):
		out[a[i].trim_prefix("--")] = a[i + 1]
	return out


static func _blender_dir_to_godot(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y)


static func _sun_dir(euler_deg: Vector3) -> Vector3:
	# Blender: a sun shines along its local -Z; object matrix = Rz * Ry * Rx
	var e := euler_deg * (PI / 180.0)
	var b := Basis(Vector3(0, 0, 1), e.z) * Basis(Vector3(0, 1, 0), e.y) * Basis(Vector3(1, 0, 0), e.x)
	return _blender_dir_to_godot(b * Vector3(0, 0, -1)).normalized()


func _ready() -> void:
	var args := _args()
	var key := String(args.get("key", "kaolin"))
	var report := {"key": key}
	var ok := true

	# --- 2. icon lookup through the game's own entry point
	var icons := load("res://scripts/lshu_ui/lshu_icons.gd")
	var icon_path := "res://assets/game/ui/lshu_3d/icons/%s.png" % key
	var tex: Texture2D = icons.good(key)
	report["good_returns"] = tex.resource_path if tex else "<null>"
	report["good_is_3d_icon"] = tex != null and tex.resource_path == icon_path
	if tex:
		report["icon_size"] = [tex.get_width(), tex.get_height()]
		report["icon_mipmaps"] = tex.get_image().has_mipmaps()
	var sprite := "res://assets/game/goods/good_%s_128.png" % key
	report["fallback_sprite_exists"] = ResourceLoader.exists(sprite)
	if ResourceLoader.exists(sprite):
		var st := load(sprite) as Texture2D
		report["fallback_sprite_size"] = [st.get_width(), st.get_height()]
	ok = ok and bool(report["good_is_3d_icon"]) and bool(report["fallback_sprite_exists"])

	# --- 1. GLB four-way ortho
	var glb := String(args.get("glb", ""))
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(glb, state)
	report["glb_load"] = error_string(err)
	if err != OK:
		_finish(report, false)
		return
	var model := doc.generate_scene(state)
	add_child(model)
	var aabb := AABB()
	var first := true
	var tris := 0
	var mats := {}
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var box := m.global_transform * m.get_aabb()
		aabb = box if first else aabb.merge(box)
		first = false
		for s in m.mesh.get_surface_count():
			var arr := m.mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			tris += (idx.size() if idx.size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
			var mat := m.get_active_material(s)
			if mat:
				mats[mat.resource_name] = true
	report["mesh_instances"] = model.find_children("*", "MeshInstance3D", true, false).size()
	report["tris"] = tris
	report["materials"] = mats.keys()
	report["aabb_size_godot_xyz"] = [snappedf(aabb.size.x, 0.001), snappedf(aabb.size.y, 0.001), snappedf(aabb.size.z, 0.001)]
	report["aabb_min_y"] = snappedf(aabb.position.y, 0.001)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color8(150, 146, 140)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.95, 0.9, 0.82)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	for s in SUNS:
		var l := DirectionalLight3D.new()
		l.light_energy = s[1]
		l.light_color = s[2]
		l.shadow_enabled = true
		var d := _sun_dir(s[0])
		l.basis = Basis.looking_at(d, Vector3.UP if absf(d.y) < 0.99 else Vector3.FORWARD)
		add_child(l)

	var ctr := aabb.get_center()
	var big := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	# Blender front (0,-1,0) / right (1,0,0) / back (0,1,0) / left (-1,0,0), in Godot axes
	var views := [["front", Vector3(0, 0, 1)], ["right", Vector3(1, 0, 0)], ["back", Vector3(0, 0, -1)], ["left", Vector3(-1, 0, 0)]]
	var vps: Array[SubViewport] = []
	for v in views:
		var vp := SubViewport.new()
		vp.size = Vector2i(W, W)
		vp.msaa_3d = Viewport.MSAA_4X
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = big * 1.25
		cam.near = 0.01
		cam.far = big * 10.0
		vp.add_child(cam)
		add_child(vp)
		cam.look_at_from_position(ctr + (v[1] as Vector3) * big * 4.0, ctr, Vector3.UP)
		cam.current = true
		vps.append(vp)
	for i in 6:
		await RenderingServer.frame_post_draw
	var strip := Image.create(W * 4, W, false, Image.FORMAT_RGBA8)
	for i in vps.size():
		var img := vps[i].get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		strip.blit_rect(img, Rect2i(0, 0, W, W), Vector2i(i * W, 0))
	var out := String(args.get("out", "user://godot-ortho.png"))
	report["ortho_png"] = out
	report["ortho_save"] = error_string(strip.save_png(out))
	_finish(report, ok)


func _finish(report: Dictionary, ok: bool) -> void:
	report["ok"] = ok
	print("SPECIALTY_VERIFY " + JSON.stringify(report))
	get_tree().quit(0 if ok else 1)
