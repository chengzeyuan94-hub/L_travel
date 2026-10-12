extends Node
## 「旅行L叔」 map-editor catalogue — step 4 of the archetype model chain: in-engine acceptance renders.
##
## Loads assets/custom_map_catalogue/cities/<id>.glb with GLTFDocument from the raw file (as the merchant board's
## build_cities() does, tools/merchant_board_claude_review.gd) and writes into art-src/custom-map-catalogue/archetypes/<id>/:
##   04-godot-ortho.png          FRONT / BACK / LEFT / RIGHT orthographic elevations, one common scale and ground
##                               line, 2 x 2 like 02-fourview.png (front = glTF +Z = the side facing the board camera)
##   04-godot-board-compare.png  the new city (top-left, "NEW") beside EVERY shipped board city of its OWN side (west
##                               archetypes vs the 7 west cities, east vs the 9 east ones; the archetype's closest
##                               compare_cities first), in a grid, each placed exactly like build_cities(): scale =
##                               the city's own layout foot / building_width, centre offset, its layout rotation +
##                               CITY_FIT yaw (CITY_YAW -0.44 by default; the new city gets CITY_YAW and foot 3.75),
##                               render layer 2, the board's noon lights and PITCH 0.76 orthographic camera; below it
##                               the same grid downscaled so a city is ~120 px wide (board default zoom) and ~45 px
##                               (MIN_ZOOM 0.42)
##   04-godot-twilight.png       the same grid at the twilight preset with the board's night-glow rule applied
##                               (materials named *Lamp* glow as lanterns, the window regex as lit openings)
##   04-godot-report.json        AABB, board scale, which materials the night-glow rule picked up per city
##
## Run with a real renderer (a --headless run has no GPU and saves blank images), e.g.:
##   HOME=<scratch>/godot_home /Applications/Godot.app/Contents/MacOS/Godot --path <repo> --audio-driver Dummy \
##       res://tools/map_catalogue/godot_ortho_check.tscn -- --id=kiln_town [--compare=quanzhou,changan,chenla] [--foot=3.75]
## --compare overrides the list (it must still be cities of the archetype's own side).

const BOARD_CITY_DIR := "res://assets/merchant_board_claude/cities/"
const BOARD_BOUNDS := "res://assets/merchant_board_claude/cities/building_bounds.json"
const CAT_CITY_DIR := "res://assets/custom_map_catalogue/cities/"
const CAT_BOUNDS := "res://assets/custom_map_catalogue/cities/building_bounds.json"
const HINTS := "res://tools/map_catalogue/archetype_models.json"
const CATALOGUE := "res://docs/design/map-editor-20260930/work/catalogue/catalogue.json"
const BOARD_LAYOUT := "res://assets/merchant_board_claude/board_layout.json"
const CITY_FIT := {"rome": [0.0, -0.5, 0.0], "simhala": [-0.15, -0.3, 0.0], "heijokyo": [-0.2, -0.25, -0.25],
	"geumseong": [-0.25, 0.2, 0.2]}      # merchant_board_claude_review.gd (yaw, dx, dz); others CITY_YAW
const ROW_DZ := 8.0                     # grid rows 8 units apart in z: they separate cleanly under the 0.76 pitch
const GRID_W := 2000
const ART_DIR := "res://art-src/custom-map-catalogue/archetypes/"
const CITY_YAW := -0.44                 # merchant_board_claude_review.gd
const PITCH := 0.76                     # merchant_board_claude_play_board.gd
const SPACING := 5.2
const WINDOW_RE := "(^|_)Dark(\\.|_|$)|DeepArch|Entry_Reveal|CedarDoor|EntryFrameShade|PagodaReveal|EaveUnderside"
const WINDOW_GLOW := Color(1.0, 0.62, 0.28)
const LAMP_GLOW := Color(1.0, 0.74, 0.4)
const PANEL := Vector2i(800, 560)
var ROW := Vector2i(1800, 620)
var side := ""
var grid_cols := 1
var grid_rows := 1

# noon / twilight: the board's LIGHTING presets (merchant_board_claude_review.gd) reduced to what a city needs
const NOON := {"sky_top": Color(0.36, 0.56, 0.9), "sky_horizon": Color(0.74, 0.86, 0.97), "ambient": 0.3, "exposure": 1.03,
	"saturation": 1.55, "contrast": 1.05, "glow": 0.3, "glow_threshold": 1.05, "sun_color": Color(1.0, 0.9, 0.7),
	"sun_energy": 2.0, "sun_dir": Vector3(0.69, -0.72, 0.09), "fill_color": Color(1.0, 0.78, 0.58), "fill_energy": 0.42,
	"rim_color": Color(1.0, 0.97, 0.92), "rim_energy": 0.08, "sky_energy": 1.0, "ground": Color(0.93, 0.8, 0.56)}
const TWILIGHT := {"sky_top": Color(0.1, 0.13, 0.3), "sky_horizon": Color(0.95, 0.52, 0.42), "ambient": 0.6, "exposure": 1.0,
	"saturation": 1.12, "contrast": 1.08, "glow": 0.85, "glow_threshold": 0.75, "sun_color": Color(0.92, 0.5, 0.55),
	"sun_energy": 0.22, "sun_dir": Vector3(0.95, -0.12, 0.2), "fill_color": Color(0.5, 0.58, 1.0), "fill_energy": 0.85,
	"rim_color": Color(1.0, 0.6, 0.5), "rim_energy": 0.2, "sky_energy": 0.8, "ground": Color(0.42, 0.4, 0.5)}

var vp: SubViewport
var content: Node3D
var cam: Camera3D
var env: Environment
var sky_mat: ProceduralSkyMaterial
var sun: DirectionalLight3D
var fill: DirectionalLight3D
var rim: DirectionalLight3D
var overlay: Control
var aid := ""
var foot := 3.75
var compare: Array = []
var out_dir := ""
var report := {}


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--id="):
			aid = arg.trim_prefix("--id=")
		elif arg.begins_with("--compare="):
			compare = Array(arg.trim_prefix("--compare=").split(",", false))
		elif arg.begins_with("--foot="):
			foot = float(arg.trim_prefix("--foot="))
	if aid == "":
		push_error("need --id=<archetype id>")
		get_tree().quit(1)
		return
	# comparison cities: the archetype's OWN side only (west archetypes vs west cities, east vs east)
	var hints: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(HINTS))
	var cat: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CATALOGUE))
	for a: Dictionary in cat.archetypes:
		if a.id == aid:
			side = String(a.side_hint)
	if side == "":
		push_error("archetype %s not in the catalogue" % aid)
		get_tree().quit(1)
		return
	var side_all: Array = hints.defaults.board_cities_by_side[side]
	if compare.is_empty():
		var closest: Array = hints.get("archetypes", {}).get(aid, {}).get("compare_cities", hints.defaults.compare_cities[side])
		compare = closest.duplicate()
		for c in side_all:
			if not compare.has(c):
				compare.append(c)
	for c in compare:
		if not side_all.has(c):
			push_error("compare city %s is not a %s board city" % [c, side])
			get_tree().quit(1)
			return
	var n := compare.size() + 1
	grid_rows = 1 if n <= 4 else 2
	grid_cols = ceili(float(n) / grid_rows)
	var horiz := grid_cols * SPACING + 0.6
	var vert := (grid_rows - 1) * ROW_DZ * sin(PITCH) + 6.4
	ROW = Vector2i(GRID_W, int(round(GRID_W * vert / horiz)))
	out_dir = ProjectSettings.globalize_path(ART_DIR + aid)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_build_stage()
	var glb := ProjectSettings.globalize_path(CAT_CITY_DIR + aid + ".glb")
	report = {"id": aid, "side": side, "glb": glb, "glb_bytes": FileAccess.get_file_as_bytes(glb).size(), "foot": foot,
		"compare": compare, "grid": [grid_cols, grid_rows]}
	await _ortho_sheet(glb)
	await _board_rows()
	var f := FileAccess.open(out_dir.path_join("04-godot-report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("GODOT_ORTHO_CHECK_DONE ", out_dir)
	get_tree().quit()


# ------------------------------------------------------------------------------------------------ stage
func _build_stage() -> void:
	vp = SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.size = PANEL
	add_child(vp)
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_curve = 0.12
	sky_mat.sun_angle_max = 0.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.82, 0.82, 0.82)
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.adjustment_enabled = true
	env.glow_enabled = true
	env.glow_strength = 1.1
	env.glow_bloom = 0.06
	env.ssao_enabled = true
	env.ssao_radius = 1.1
	env.ssao_intensity = 2.0
	env.ssao_power = 1.4
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	sun = _light(0xFFFFF, true)
	sun.shadow_opacity = 0.95
	sun.shadow_blur = 1.0
	sun.light_angular_distance = 1.5
	sun.directional_shadow_max_distance = 80.0
	fill = _light(0xFFFFF & ~2, false)          # not on the cities (layer 2), as on the board
	rim = _light(0xFFFFF, false)
	var shade := _light(2, false)               # CityShade
	shade.light_color = Color(1.0, 0.7, 0.48)
	shade.light_energy = 0.18
	shade.transform = Transform3D(Basis.looking_at(Vector3(-0.72, -0.55, -0.2).normalized(), Vector3.UP), Vector3.ZERO)
	var lift := _light(2, false)                # CityLift
	lift.light_color = Color(1.0, 0.92, 0.8)
	lift.light_energy = 0.15
	lift.transform = Transform3D(Basis.looking_at(Vector3(0.5, -0.4, -0.77).normalized(), Vector3.UP), Vector3.ZERO)
	content = Node3D.new()
	vp.add_child(content)
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.far = 400.0
	cam.current = true
	vp.add_child(cam)
	overlay = Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vp.add_child(overlay)
	_apply(NOON)


func _light(mask: int, shadow: bool) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.light_cull_mask = mask
	l.shadow_enabled = shadow
	vp.add_child(l)
	return l


func _apply(p: Dictionary) -> void:
	sky_mat.sky_top_color = p.sky_top
	sky_mat.sky_horizon_color = p.sky_horizon
	sky_mat.ground_bottom_color = p.sky_horizon.darkened(0.3)
	sky_mat.ground_horizon_color = p.sky_horizon
	sky_mat.energy_multiplier = p.sky_energy
	env.ambient_light_energy = p.ambient
	env.tonemap_exposure = p.exposure
	env.adjustment_saturation = p.saturation
	env.adjustment_contrast = p.contrast
	env.glow_intensity = p.glow
	env.glow_hdr_threshold = p.glow_threshold
	sun.light_color = p.sun_color
	sun.light_energy = p.sun_energy
	sun.transform = Transform3D(Basis.looking_at((p.sun_dir as Vector3).normalized(), Vector3.UP), Vector3.ZERO)
	fill.light_color = p.fill_color
	fill.light_energy = p.fill_energy
	fill.transform = Transform3D(Basis.looking_at(Vector3(-0.72, -0.55, -0.2).normalized(), Vector3.UP), Vector3.ZERO)
	rim.light_color = p.rim_color
	rim.light_energy = p.rim_energy
	rim.transform = Transform3D(Basis.looking_at(Vector3(0.2, -0.3, 0.93).normalized(), Vector3.UP), Vector3.ZERO)


func _capture(size: Vector2i) -> Image:
	vp.size = size
	for i in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()


func _clear() -> void:
	for c in content.get_children():
		content.remove_child(c)
		c.queue_free()
	for c in overlay.get_children():
		overlay.remove_child(c)
		c.queue_free()


# ------------------------------------------------------------------------------------------------ loading
func load_gltf(path: String) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_error("GLTF load failed %s: %s" % [path, error_string(err)])
		return null
	return doc.generate_scene(state) as Node3D


func meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for ch in n.get_children():
		out.append_array(meshes(ch))
	return out


func aabb_of(n: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in meshes(n):
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _label(text: String, pos: Vector2, size := 22, colour := Color(0.16, 0.11, 0.08)) -> void:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	overlay.add_child(l)


# ------------------------------------------------------------------------------------------------ 04-godot-ortho.png
func _ortho_sheet(glb: String) -> void:
	_clear()
	_apply(NOON)
	env.background_mode = Environment.BG_COLOR
	var model := load_gltf(glb)
	content.add_child(model)
	for mi in meshes(model):
		mi.layers = 2
	await get_tree().process_frame
	var box := aabb_of(model)
	report["aabb_gltf"] = {"position": [box.position.x, box.position.y, box.position.z], "size": [box.size.x, box.size.y, box.size.z]}
	var c := box.get_center()
	var aspect := float(PANEL.x) / PANEL.y
	var span := maxf(box.size.y, maxf(box.size.x, box.size.z) / aspect) * 1.12
	cam.size = span
	var views := [["FRONT", Vector3(0, 0, 1)], ["BACK", Vector3(0, 0, -1)], ["LEFT", Vector3(-1, 0, 0)], ["RIGHT", Vector3(1, 0, 0)]]
	var shots: Array[Image] = []
	for v: Array in views:
		var d: Vector3 = v[1]
		var target := Vector3(c.x, box.position.y + span * 0.42, c.z)
		cam.position = target + d * 60.0
		cam.look_at(target, Vector3.UP)
		var key := (d + Vector3(0, 0.9, 0) + d.cross(Vector3.UP) * 0.6).normalized()
		sun.transform = Transform3D(Basis.looking_at(-key, Vector3.UP), Vector3.ZERO)
		for ch in overlay.get_children():
			ch.queue_free()
		_label(String(v[0]), Vector2(22, 14), 30)
		shots.append(await _capture(PANEL))
	var gap := 8
	var sheet := Image.create(PANEL.x * 2 + gap * 3, PANEL.y * 2 + gap * 3, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.93, 0.93, 0.93))
	for i in shots.size():
		var img := shots[i]
		img.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, PANEL), Vector2i(gap + (i % 2) * (PANEL.x + gap), gap + (i / 2) * (PANEL.y + gap)))
	sheet.save_png(out_dir.path_join("04-godot-ortho.png"))


# ------------------------------------------------------------------------------------------------ board rows
func _place_row() -> Array:
	var board_bounds: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BOARD_BOUNDS)).cities
	var cat_bounds: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CAT_BOUNDS)).cities
	var layout_by_id := {}
	for c: Dictionary in JSON.parse_string(FileAccess.get_file_as_string(BOARD_LAYOUT)).cities:
		layout_by_id[String(c.id)] = c
	var ids: Array = [aid] + compare
	var placed := []
	for i in ids.size():
		var id: String = ids[i]
		var is_new := i == 0
		var path := ProjectSettings.globalize_path((CAT_CITY_DIR if is_new else BOARD_CITY_DIR) + id + ".glb")
		var bb: Dictionary = (cat_bounds if is_new else board_bounds)[id]
		var node := load_gltf(path)
		var holder := Node3D.new()
		holder.name = "City_" + id
		holder.add_child(node)
		node.position -= Vector3(bb.building_centre_xz[0], 0.0, bb.building_centre_xz[1])
		# exactly as build_cities(): the city's own layout foot and rotation + its CITY_FIT yaw (default CITY_YAW)
		var city_foot := foot
		var yaw := CITY_YAW
		if not is_new:
			var lc: Dictionary = layout_by_id[id]
			city_foot = float(lc.foot)
			yaw = float(lc.rotation) + float(CITY_FIT.get(id, [CITY_YAW])[0])
		var s := city_foot / float(bb.building_width)
		holder.scale = Vector3.ONE * s
		holder.rotation.y = yaw
		var col := i % grid_cols
		var row := i / grid_cols
		holder.position = Vector3((col - (grid_cols - 1) * 0.5) * SPACING, 0.0, (row - (grid_rows - 1) * 0.5) * ROW_DZ)
		content.add_child(holder)
		for mi in meshes(holder):
			mi.layers = 2
		placed.append({"id": id, "holder": holder, "scale": s, "new": is_new, "foot": city_foot, "yaw": yaw})
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(200, 200)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.roughness = 1.0
	ground.material_override = gm
	ground.name = "Ground"
	content.add_child(ground)
	return placed


func _board_cam(n: int, size: Vector2i) -> void:
	var target := Vector3(0, 0.9, 0)
	cam.size = (grid_cols * SPACING + 0.6) / (float(size.x) / size.y)
	cam.position = target + Vector3(0, sin(PITCH), cos(PITCH)) * 120.0
	cam.look_at(target, Vector3.UP)


func _board_rows() -> void:
	_clear()
	var placed := _place_row()
	await get_tree().process_frame
	var n := placed.size()
	_board_cam(n, ROW)
	var ground: MeshInstance3D = content.get_node("Ground")
	# ---- noon
	_apply(NOON)
	env.background_mode = Environment.BG_COLOR
	env.background_color = NOON.ground
	(ground.material_override as StandardMaterial3D).albedo_color = NOON.ground
	var clean := await _capture(ROW)
	var info := {}
	for p: Dictionary in placed:
		var h: Node3D = p.holder
		var box := aabb_of(h)
		var lp := cam.unproject_position(Vector3(h.position.x, 0.0, h.position.z + float(p.foot) * 0.62))
		_label(("NEW  " if p.new else "") + String(p.id), Vector2(lp.x - 70, lp.y), 24, Color(0.62, 0.12, 0.05) if p.new else Color(0.16, 0.11, 0.08))
		info[p.id] = {"scale": snappedf(p.scale, 0.0001), "foot": p.foot, "yaw": snappedf(p.yaw, 0.001),
			"board_size": [snappedf(box.size.x, 0.01), snappedf(box.size.y, 0.01), snappedf(box.size.z, 0.01)]}
	var labelled := await _capture(ROW)
	report["board"] = info
	# downscaled copies: the city foot at ~120 px (board default zoom) and ~45 px (MIN_ZOOM 0.42)
	var px_per_unit := float(ROW.y) / cam.size
	var foot_px := foot * px_per_unit
	var small := []
	for target_px in [120.0, 45.0]:
		var k: float = target_px / foot_px
		var im := clean.duplicate() as Image
		im.resize(maxi(1, int(ROW.x * k)), maxi(1, int(ROW.y * k)), Image.INTERPOLATE_LANCZOS)
		small.append(im)
	report["foot_px_full"] = snappedf(foot_px, 0.1)
	var gap := 10
	var bottom_h: int = (small[0] as Image).get_height()
	var sheet := Image.create(ROW.x, ROW.y + bottom_h + gap * 3, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.93, 0.93, 0.93))
	labelled.convert(Image.FORMAT_RGBA8)
	sheet.blit_rect(labelled, Rect2i(Vector2i.ZERO, ROW), Vector2i(0, 0))
	var x := gap
	for im: Image in small:
		im.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(im, Rect2i(Vector2i.ZERO, im.get_size()), Vector2i(x, ROW.y + gap * 2))
		x += im.get_width() + gap * 4
	sheet.save_png(out_dir.path_join("04-godot-board-compare.png"))
	# ---- twilight with the board's night-glow rule
	_apply(TWILIGHT)
	env.background_color = TWILIGHT.ground
	(ground.material_override as StandardMaterial3D).albedo_color = TWILIGHT.ground
	var re := RegEx.create_from_string(WINDOW_RE)
	var glow := {}
	for p: Dictionary in placed:
		var lamps := []
		var windows := []
		for mi in meshes(p.holder):
			for si in mi.mesh.get_surface_count():
				var m := mi.get_active_material(si) as StandardMaterial3D
				if m == null:
					continue
				var nm := String(m.resource_name)
				var lamp := nm.contains("Lamp")
				if not lamp and re.search(nm) == null:
					continue
				var mm := m.duplicate() as StandardMaterial3D
				mm.emission_enabled = true
				mm.emission = LAMP_GLOW if lamp else WINDOW_GLOW
				mm.emission_energy_multiplier = 5.0 if lamp else 1.8
				mi.set_surface_override_material(si, mm)
				(lamps if lamp else windows).append(nm)
		glow[p.id] = {"lamp_materials": lamps, "window_materials": windows}
	report["night_glow"] = glow
	var tw := await _capture(ROW)
	tw.save_png(out_dir.path_join("04-godot-twilight.png"))
