extends Node
## L3 · L叔 integration & cheap global life (look line L3, extra_scripts module; see README_PROBE.md §6).
##
## Everything here is a global rule driven by tile data every recipe already has (character pose/kit,
## fires[], lamps[], smoke[], instance anim tags). Nothing is keyed by tile id.
##   character : own render layer (l3.character.layer_bit, default 18) so decals skip him; facing clamp toward the
##               camera (only rescues back-facing web yaws); contact-shadow decal under feet / seat; rim next_pass
##               on the styled body keyed to the sun, or to the nearest fire/lamp within local_key_radius_m;
##               tea cup between the hands (seated); act-3 potato blossoms on the carried bundle (carrying);
##               optional character-only fill light (l3.character.fill.energy, 0 = off; measured: it lowers contrast)
##   fire      : act-3 camp fire module (baghdad_camp_fire.gd: flame cards + sparks) on every fires[] entry, sized by
##               the entry's scale, plus an emissive coal bed; the viewer's icosahedra must be off (fires.flame=false).
##               The fire light itself stays the viewer's OmniLight (fires.light_* belong to the lighting line).
##   smoke     : chimney puffs from smoke[] (web D01), faint wisps above camp fires, optional tea steam (off: the
##               chibi head occludes it)
##   lanterns  : aura quad behind each lamps[] point (per-light strength, 0 by day) + small flicker of the lamp lights
##   wind      : nothing here; tree sway is the shared shader's instance uniform, amplitude = motion.wind_strength
##   measure   : findability probe (character mask by hide/show diff; contrast vs surroundings) -> capture JSON extra.l3
## Parameters: host.cfg.l3 (so common + lights.<preset> merge like any other section), re-read on every
## light change. Module cfg (extra_scripts[].cfg): measure (bool), zoom_m (debug close-up), save_mask (debug path).

const CAMP_FIRE_SCRIPT := "res://scripts/traveler/baghdad/baghdad_camp_fire.gd"   # no class_name: safe to load by path
const BLOSSOM_SCRIPT := "res://scripts/traveler/baghdad/baghdad_potato_blossom.gd" # no class_name
const RIM_SHADER := "res://tools/traveler/lookdev_lshu/shaders/l3_character_rim.gdshader"
const SMOKE_SHADER := "res://tools/traveler/lookdev_lshu/shaders/l3_smoke.gdshader"
const HALO_SHADER := "res://tools/traveler/lookdev_lshu/shaders/l3_halo.gdshader"
const BAGHDAD_CHARACTER_HEIGHT := 0.6375
const FLOOR_LAYER := 1 << 19

var host: Node3D
var mcfg: Dictionary = {}
var l3: Dictionary = {}
var root: Node3D
var char_layer: int = 1 << 18
var char_meshes: Array[MeshInstance3D] = []
var char_shadow_meshes: Array[MeshInstance3D] = []
var rim_material: ShaderMaterial
var contact_decal: Decal
var char_fill: OmniLight3D
var fires: Array[Dictionary] = []
var smoke_emitters: Array[Dictionary] = []
var smoke_materials: Dictionary = {}
var puff_mesh: SphereMesh
var halos: Array[Dictionary] = []
var halo_material: ShaderMaterial
var cup: Node3D
var cup_skeleton: Skeleton3D
var cup_bones: Array[int] = []
var steam_emitter: Dictionary = {}
var blossom: Node3D
var blossom_ratio: float = 1.0
var facing: Dictionary = {}
var measure_result: Dictionary = {}
var report: Dictionary = {}

func build(h: Node3D, c: Dictionary) -> Dictionary:
	host = h
	mcfg = c
	l3 = _l3()
	root = Node3D.new()
	root.name = "L3Life"
	(host.get("fx_root") as Node3D).add_child(root)
	char_layer = 1 << int(_g(["character", "layer_bit"], 18))
	puff_mesh = SphereMesh.new()
	puff_mesh.radius = 0.5; puff_mesh.height = 1.0; puff_mesh.radial_segments = 7; puff_mesh.rings = 4
	_setup_character()
	_setup_fires()
	_setup_smoke()
	_setup_lanterns()
	host.call("register_light_callback", _on_light)
	host.call("register_tick", _on_tick)
	_on_light(str(host.get("light_name")))
	_on_tick(float(host.get("anim_t")), 0.0)
	report["facing"] = facing
	host.call("add_report", "l3", report)
	var zoom: float = float(mcfg.get("zoom_m", 0.0))
	if zoom > 0.0:
		# debug close-up for inspection only (same camera angle, moved toward L叔); never used for numbers
		var cam: Camera3D = host.get("camera")
		var ch: Node3D = host.get("character")
		var focus: Vector3 = ch.global_position + Vector3(0.0, float(host.get("character_height_m")) * 0.45, 0.0) + _v3(mcfg.get("zoom_offset", [0, 0, 0]), Vector3.ZERO)
		cam.global_position = focus + cam.global_basis.z * zoom
	elif bool(mcfg.get("measure", true)):
		_measure()
	return {"ok": true, "pose": host.get("character_pose"), "fires": fires.size(), "smoke_emitters": smoke_emitters.size(), "halos": halos.size(), "cup": cup != null, "blossom": blossom != null}

# ------------------------------------------------------------------ config helpers
func _l3() -> Dictionary:
	var cfg: Dictionary = host.get("cfg")
	return cfg.get("l3", {})

func _g(path: Array, fallback: Variant) -> Variant:
	var d: Variant = l3
	for k: Variant in path:
		if not d is Dictionary or not (d as Dictionary).has(k):
			return fallback
		d = (d as Dictionary)[k]
	return d

func _col(v: Variant, fallback: Color) -> Color:
	if v is String:
		return Color.html(str(v))
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return fallback

func _v3(v: Variant, fallback: Vector3) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback

func _sun_dir() -> Vector3:
	var sun: DirectionalLight3D = host.get("sun")
	return sun.global_basis.z.normalized()   # points toward the light

# ------------------------------------------------------------------ character
func _setup_character() -> void:
	var character: Node3D = host.get("character")
	if character == null:
		return
	var tile: Dictionary = host.get("tile")
	var cdata: Dictionary = tile.get("character", {})
	var pose: String = str(host.get("character_pose"))
	# facing: keep the web yaw, but never turn further than N degrees away from the camera (face stays readable)
	var cam: Camera3D = host.get("camera")
	var to_cam: Vector3 = cam.global_position - character.global_position
	var cam_yaw: float = atan2(to_cam.x, to_cam.z)
	var max_deg: float = float(_g(["character", "face_camera_max_deg"], 180.0))
	var yaw_before: float = character.rotation.y
	var diff: float = wrapf(yaw_before - cam_yaw, -PI, PI)
	var clamped: float = clampf(diff, -deg_to_rad(max_deg), deg_to_rad(max_deg))
	if pose != "seated" and absf(clamped - diff) > 0.0001:
		# seated: the seat anchor is placed in the rotated frame; do not re-rotate a seated actor
		character.rotation.y = cam_yaw + clamped
	facing = {"web_yaw_to_camera_deg": rad_to_deg(diff), "applied_yaw_to_camera_deg": rad_to_deg(wrapf(character.rotation.y - cam_yaw, -PI, PI)), "max_deg": max_deg}
	# collect the character meshes (standing, seated or carrying model, outline shells, carried props)
	for node: Node in character.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node as MeshInstance3D
		if not mi.is_visible_in_tree():
			continue
		char_meshes.append(mi)
		if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			char_shadow_meshes.append(mi)
	var carrying: Node3D = host.get("carrying_pose")
	if carrying != null:
		for node: Node in carrying.find_children("*", "MeshInstance3D", true, false):
			var mi2: MeshInstance3D = node as MeshInstance3D
			if not char_meshes.has(mi2) and mi2.is_visible_in_tree():
				char_meshes.append(mi2)
				if mi2.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					char_shadow_meshes.append(mi2)
	for mi3: MeshInstance3D in char_meshes:
		mi3.layers = char_layer
	# rim pass on the styled body surfaces (not on the unshaded outline shells)
	if bool(_g(["character", "rim", "enabled"], true)):
		rim_material = ShaderMaterial.new()
		rim_material.shader = load(RIM_SHADER) as Shader
		var rim_count: int = 0
		for mi4: MeshInstance3D in char_meshes:
			if mi4.material_override != null or mi4.mesh == null:
				continue
			for s: int in mi4.mesh.get_surface_count():
				var m: Material = mi4.get_active_material(s)
				if m == null or m.next_pass != null:
					continue
				if m is BaseMaterial3D and ((m as BaseMaterial3D).shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED or (m as BaseMaterial3D).cull_mode == BaseMaterial3D.CULL_FRONT):
					continue   # outline shells / unshaded parts
				m.next_pass = rim_material
				rim_count += 1
		report["rim_surfaces"] = rim_count
	# contact shadow: one soft decal under the feet (standing/carrying) or under seat + feet (seated)
	if bool(_g(["character", "contact", "enabled"], true)):
		contact_decal = Decal.new()
		contact_decal.name = "L3ContactShadow"
		var radius: float = float(_g(["character", "contact", "seated_radius_m" if pose == "seated" else "radius_m"], 0.4))
		var height_scale: float = float(host.get("character_height_m")) / 1.15
		radius *= height_scale
		var box_h: float = float(_g(["character", "contact", "height_m"], 0.5))
		contact_decal.size = Vector3(radius * 2.0, box_h, radius * 2.0)
		contact_decal.set_texture(Decal.TEXTURE_ALBEDO, _blob_texture(float(_g(["character", "contact", "softness"], 1.6))))
		contact_decal.albedo_mix = 1.0
		contact_decal.normal_fade = 0.35
		contact_decal.upper_fade = 0.3
		contact_decal.lower_fade = 0.3
		contact_decal.cull_mask = 0xFFFFF & ~char_layer & ~FLOOR_LAYER
		var ground_y: float = float(cdata.get("ground_y", character.global_position.y))
		var p: Vector3 = character.global_position
		var foot_center: Vector3 = Vector3(p.x, ground_y, p.z)
		if pose == "seated":
			# seat footprint + feet: centre slightly toward where the feet land (actor forward)
			var fwd: Vector3 = character.global_basis.z.normalized()
			foot_center = Vector3(float(cdata.position[0]), ground_y, float(cdata.position[2])) + Vector3(fwd.x, 0.0, fwd.z) * 0.12 * height_scale
		contact_decal.position = foot_center + Vector3(0.0, box_h * 0.3, 0.0)
		root.add_child(contact_decal)
		report["contact"] = {"radius_m": radius, "center": [foot_center.x, foot_center.y, foot_center.z]}
	# character-only fill ("eye light"): lights only the character layer, never the tile; energy per light preset
	char_fill = OmniLight3D.new()
	char_fill.name = "L3CharacterFill"
	var hs: float = float(host.get("character_height_m"))
	var cam_dir: Vector3 = (cam.global_position - character.global_position)
	cam_dir.y = 0.0
	char_fill.position = character.global_position + cam_dir.normalized() * hs * 0.7 + Vector3(0.0, hs * 0.9, 0.0)
	char_fill.omni_range = hs * 1.6
	char_fill.omni_attenuation = 1.0
	char_fill.light_cull_mask = char_layer
	char_fill.shadow_enabled = false
	char_fill.light_specular = 0.0
	root.add_child(char_fill)
	# kit props
	if pose == "seated" and bool(_g(["character", "cup", "enabled"], true)):
		_setup_cup()
	if pose == "carrying" and bool(_g(["character", "blossom", "enabled"], true)):
		_setup_blossom()
	_ground_check()

## Feet vs ground (seated-feet grounding question): toe-end / foot bones of the live skeleton vs terrain.
## Bone joints sit inside the shoe, so "sole_gap" subtracts a sole allowance scaled by the character height.
func _ground_check() -> void:
	var character: Node3D = host.get("character")
	var sk: Skeleton3D = null
	for node: Node in character.find_children("*", "Skeleton3D", true, false):
		var cand: Skeleton3D = node as Skeleton3D
		if cand.is_visible_in_tree():
			sk = cand
	if sk == null:
		return
	var out: Dictionary = {}
	var worst: float = INF
	var hscale: float = float(host.get("character_height_m")) / 1.15
	for side: String in ["Left", "Right"]:
		for part: String in ["Foot", "ToeBase", "Toe_End"]:
			var idx: int = -1
			for i: int in sk.get_bone_count():
				var bn: String = str(sk.get_bone_name(i))
				if bn.ends_with(side + part):
					idx = i
			if idx < 0:
				continue
			var w: Vector3 = sk.to_global(sk.get_bone_global_pose(idx).origin)
			var terrain: float = float(host.call("terrain_height", w.x, w.z))
			out[side + part] = {"world": [w.x, w.y, w.z], "above_terrain_m": w.y - terrain}
			if part == "ToeBase":
				worst = minf(worst, w.y - terrain)
	out["toe_base_min_above_terrain_m"] = worst
	out["sole_gap_m"] = worst - 0.035 * hscale
	report["ground_check"] = out

func _blob_texture(softness: float) -> ImageTexture:
	var n: int = 64
	var img: Image = Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y: int in n:
		for x: int in n:
			var dx: float = (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var dy: float = (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var d: float = sqrt(dx * dx + dy * dy)
			var a: float = pow(clampf(1.0 - d, 0.0, 1.0), softness)
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, a))
	return ImageTexture.create_from_image(img)

func _setup_cup() -> void:
	var character: Node3D = host.get("character")
	cup_skeleton = character.find_child("Skeleton3D", true, false) as Skeleton3D
	if cup_skeleton == null:
		return
	for bn: String in ["mixamorig_RightHand", "mixamorig_RightHandMiddle1", "mixamorig_LeftHand", "mixamorig_LeftHandMiddle1"]:
		cup_bones.append(cup_skeleton.find_bone(bn))
	if cup_bones.has(-1):
		report["cup_error"] = "hand bones missing"
		return
	var hscale: float = float(host.get("character_height_m")) / 1.15
	cup = Node3D.new()
	cup.name = "L3TeaCup"
	root.add_child(cup)
	var cyl: CylinderMesh = CylinderMesh.new()
	var r: float = float(_g(["character", "cup", "radius_m"], 0.035)) * hscale
	var hgt: float = float(_g(["character", "cup", "height_m"], 0.07)) * hscale
	cyl.top_radius = r; cyl.bottom_radius = r * 0.82; cyl.height = hgt; cyl.radial_segments = 8; cyl.rings = 1
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = _col(_g(["character", "cup", "color"], "#e8dcc8"), Color(0.9, 0.85, 0.78))
	mat.roughness = 0.6
	cyl.material = mat
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = cyl
	mi.layers = char_layer
	cup.add_child(mi)
	var tea: CylinderMesh = CylinderMesh.new()
	tea.top_radius = r * 0.86; tea.bottom_radius = r * 0.86; tea.height = 0.004; tea.radial_segments = 8; tea.rings = 1
	var tmat: StandardMaterial3D = StandardMaterial3D.new()
	tmat.albedo_color = Color.html("#7a4a22")
	tea.material = tmat
	var tmi: MeshInstance3D = MeshInstance3D.new()
	tmi.mesh = tea
	tmi.position = Vector3(0.0, hgt * 0.5 - 0.006, 0.0)
	tmi.layers = char_layer
	cup.add_child(tmi)
	char_meshes.append(mi)
	char_meshes.append(tmi)
	if bool(_g(["character", "cup", "steam"], true)):
		steam_emitter = _make_emitter("steam", Vector3.ZERO, 1.0)
	_update_cup()

func _update_cup() -> void:
	if cup == null or cup_skeleton == null:
		return
	var rh: Vector3 = cup_skeleton.to_global(cup_skeleton.get_bone_global_pose(cup_bones[0]).origin)
	var rm: Vector3 = cup_skeleton.to_global(cup_skeleton.get_bone_global_pose(cup_bones[1]).origin)
	var lh: Vector3 = cup_skeleton.to_global(cup_skeleton.get_bone_global_pose(cup_bones[2]).origin)
	var lm: Vector3 = cup_skeleton.to_global(cup_skeleton.get_bone_global_pose(cup_bones[3]).origin)
	var rpalm: Vector3 = rh.lerp(rm, 0.55)
	var lpalm: Vector3 = lh.lerp(lm, 0.55)
	var mode: String = str(_g(["character", "cup", "hold"], "both"))
	var hscale: float = float(host.get("character_height_m")) / 1.15
	var p: Vector3 = rpalm if mode == "right" else (rpalm + lpalm) * 0.5
	p += _v3(_g(["character", "cup", "offset_m"], [0.0, -0.02, 0.0]), Vector3(0, -0.02, 0)) * hscale
	cup.global_position = p
	cup.global_basis = Basis.IDENTITY
	if not steam_emitter.is_empty():
		steam_emitter["base"] = p + Vector3(0.0, float(_g(["character", "cup", "height_m"], 0.07)) * hscale * 0.5, 0.0)
	report["cup_hands"] = {"right_palm": [rpalm.x, rpalm.y, rpalm.z], "left_palm": [lpalm.x, lpalm.y, lpalm.z], "hand_gap_m": rpalm.distance_to(lpalm)}

func _setup_blossom() -> void:
	var carrying: Node3D = host.get("carrying_pose")
	if carrying == null:
		return
	blossom = load(BLOSSOM_SCRIPT).new() as Node3D
	blossom.set("autoplay", false)
	blossom.set("emission_strength", float(_g(["character", "blossom", "emission"], 0.8)))
	blossom.set("hand_light_energy", 0.0)
	(host.get("world") as Node3D).add_child(blossom)
	var ok: bool = bool(blossom.call("configure", carrying))
	if not ok:
		blossom.queue_free()
		blossom = null
		report["blossom_error"] = "configure failed"
		return
	# The module sizes flowers in Baghdad world units (L叔 0.6375 m). Scale each stalk about its own
	# anchor by the same height ratio the viewer uses for the potato bundle.
	blossom_ratio = float(host.get("character_height_m")) / BAGHDAD_CHARACTER_HEIGHT * float(_g(["character", "blossom", "scale"], 1.0))
	var stalks: Array = blossom.get("_stalks")
	for rec: Variant in stalks:
		var n: Node3D = (rec as Dictionary).get("node") as Node3D
		if n != null:
			n.scale = Vector3.ONE * blossom_ratio
	for node: Node in blossom.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).layers = char_layer
	for node2: Node in carrying.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node2 as MeshInstance3D
		if not char_meshes.has(mi):
			char_meshes.append(mi)
		mi.layers = char_layer
	report["blossom"] = {"stalks": stalks.size(), "ratio": blossom_ratio}

# ------------------------------------------------------------------ fires (act-3 camp fire on every fires[] entry)
func _setup_fires() -> void:
	if not bool(_g(["fire", "enabled"], true)):
		return
	var script: Script = load(CAMP_FIRE_SCRIPT) as Script
	if script == null:
		return
	var tile: Dictionary = host.get("tile")
	var per_h: float = float(_g(["fire", "flame_height_per_scale"], 0.62))
	var per_w: float = float(_g(["fire", "flame_width_per_scale"], 0.42))
	var lift: float = float(_g(["fire", "base_lift_per_scale"], 0.11))
	var effect_mult: float = float(_g(["fire", "effect_point_mult"], 0.7))
	var i: int = 0
	for f: Dictionary in tile.get("fires", []):
		var sc: float = float(f.get("scale", 0.55))
		var effect_point: bool = str(f.get("source", "")) != "camp_kit"
		var m: float = effect_mult if effect_point else 1.0
		var node: Node3D = script.new() as Node3D
		node.name = "L3CampFire_%d" % i
		var fh: float = per_h * sc * m
		var fw: float = per_w * sc * m
		node.call("configure", {
			"flame_height_u": fh, "flame_width_u": fw, "flame_count": int(_g(["fire", "flame_count"], 5)),
			"spark_amount": int(_g(["fire", "spark_amount"], 10)), "spark_lifetime_s": float(_g(["fire", "spark_lifetime_s"], 1.4)),
			"spark_size_u": float(_g(["fire", "spark_size_per_scale"], 0.028)) * sc * m,
			"spark_speed_min_u_s": 0.25 * sc * m, "spark_speed_max_u_s": 0.55 * sc * m, "spark_spread_deg": 22.0,
			"light_energy": 0.0, "seed": 20260923 + i,
		})
		var pos: Vector3 = _v3(f.get("position"), Vector3.ZERO)
		node.position = pos + Vector3(0.0, (0.02 if effect_point else lift) * sc * m, 0.0)
		root.add_child(node)
		node.call("freeze", true)
		var fl: OmniLight3D = node.get("fire_light") as OmniLight3D
		if fl != null:
			fl.visible = false
		var sp: GPUParticles3D = node.get("sparks") as GPUParticles3D
		if sp != null:
			sp.preprocess = sp.lifetime
			sp.visibility_aabb = AABB(Vector3(-1, -0.2, -1), Vector3(2, 2.5, 2))
		var rec: Dictionary = {"node": node, "pos": pos, "scale": sc * m, "effect": effect_point, "flame_h": fh}
		# coal bed: small emissive plate under the flames (per-light emission)
		if bool(_g(["fire", "coals"], true)) and not effect_point:
			var coal: MeshInstance3D = MeshInstance3D.new()
			var cm: CylinderMesh = CylinderMesh.new()
			cm.top_radius = fw * 0.55; cm.bottom_radius = fw * 0.62; cm.height = 0.02; cm.radial_segments = 7; cm.rings = 1
			var cmat: StandardMaterial3D = StandardMaterial3D.new()
			cmat.albedo_color = Color.html("#3a1d10")
			cmat.emission_enabled = true
			cmat.emission = Color.html("#ff5a1a")
			cm.material = cmat
			coal.mesh = cm
			coal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			coal.position = node.position + Vector3(0.0, 0.005, 0.0)
			root.add_child(coal)
			rec["coal_mat"] = cmat
		fires.append(rec)
		i += 1
	report["fires"] = fires.map(func(r: Dictionary) -> Dictionary: return {"scale": r.scale, "effect_point": r.effect, "flame_h_m": r.flame_h})

# ------------------------------------------------------------------ smoke / steam puffs
func _smoke_material(kind: String) -> ShaderMaterial:
	if smoke_materials.has(kind):
		return smoke_materials[kind]
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = load(SMOKE_SHADER) as Shader
	smoke_materials[kind] = m
	return m

func _make_emitter(kind: String, base: Vector3, scale_value: float) -> Dictionary:
	var n: int = int(_g(["smoke", kind, "puffs"], 7))
	var puffs: Array[MeshInstance3D] = []
	var mat: ShaderMaterial = _smoke_material(kind)
	for k: int in n:
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = puff_mesh
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.layers = char_layer if kind == "steam" else 1
		root.add_child(mi)
		puffs.append(mi)
	var e: Dictionary = {"kind": kind, "base": base, "scale": scale_value, "puffs": puffs, "phase": base.x * 1.7 + base.z * 0.9}
	smoke_emitters.append(e)
	return e

func _setup_smoke() -> void:
	var tile: Dictionary = host.get("tile")
	var smoke: Array = tile.get("smoke", [])
	if bool(_g(["smoke", "chimney", "enabled"], true)) and not smoke.is_empty():
		_make_emitter("chimney", _v3(smoke[0], Vector3.ZERO) + Vector3(0.0, -0.12, 0.0), 1.0)
	if bool(_g(["smoke", "fire", "enabled"], true)):
		for f: Dictionary in fires:
			if bool(f.effect):
				continue
			var above: float = float(_g(["smoke", "fire", "start_above_flame"], 0.9))
			_make_emitter("fire", (f.pos as Vector3) + Vector3(0.0, float(f.flame_h) * above, 0.0), float(f.scale) / 0.55)

func _update_smoke(t: float) -> void:
	for e: Dictionary in smoke_emitters:
		var kind: String = e.kind
		var puffs: Array[MeshInstance3D] = e.puffs
		var n: int = puffs.size()
		var sc: float = float(e.scale)
		var rise: float = float(_g(["smoke", kind, "rise_m"], 1.3)) * sc
		var drift: Vector3 = _v3(_g(["smoke", kind, "drift_m"], [0.3, 0.0, -0.1]), Vector3(0.3, 0, -0.1)) * sc
		var speed: float = float(_g(["smoke", kind, "speed"], 0.12))
		var s0: float = float(_g(["smoke", kind, "size_start_m"], 0.12)) * sc
		var s1: float = float(_g(["smoke", kind, "size_end_m"], 0.34)) * sc
		var alpha: float = float(_g(["smoke", kind, "alpha"], 0.4))
		var warm: float = float(_g(["smoke", kind, "warm"], 0.0))
		var wobble: float = float(_g(["smoke", kind, "wobble_m"], 0.05)) * sc
		var base: Vector3 = e.base
		for k: int in n:
			var u: float = fposmod(t * speed + float(k) / float(n) + float(e.phase) * 0.013, 1.0)
			var mi: MeshInstance3D = puffs[k]
			# per-puff jitter (stable per index) so the column does not read as a stack of equal beads
			var rk: float = fposmod(sin(float(k) * 12.9898 + float(e.phase)) * 43758.5453, 1.0)
			var rk2: float = fposmod(sin(float(k) * 78.233 + float(e.phase)) * 12543.853, 1.0)
			var curve: float = u * u * 0.6 + u * 0.4
			mi.position = base + Vector3(drift.x * curve + sin(t * 0.7 + k * 1.9 + float(e.phase)) * wobble * u + (rk - 0.5) * wobble * 2.0 * u, rise * u, drift.z * curve + cos(t * 0.55 + k * 1.3) * wobble * u + (rk2 - 0.5) * wobble * 2.0 * u)
			var s: float = lerpf(s0, s1, sqrt(u)) * (0.8 + 0.4 * rk2)
			mi.scale = Vector3(s, s * 0.85, s)
			mi.rotation = Vector3(k * 0.7, t * 0.2 + k, k * 0.4)
			var a: float = alpha * smoothstep(0.0, 0.12, u) * pow(1.0 - u, 1.3)
			mi.set_instance_shader_parameter("puff_alpha", a)
			mi.set_instance_shader_parameter("puff_warm", warm * (1.0 - u) * (1.0 - u))

# ------------------------------------------------------------------ lanterns
func _setup_lanterns() -> void:
	var lamps: Array = (host.get("tile") as Dictionary).get("lamps", [])
	if lamps.is_empty() or not bool(_g(["lanterns", "enabled"], true)):
		return
	halo_material = ShaderMaterial.new()
	halo_material.shader = load(HALO_SHADER) as Shader
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE
	var i: int = 0
	for p: Variant in lamps:
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = "L3LanternHalo_%d" % i
		mi.mesh = quad
		mi.material_override = halo_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = _v3(p, Vector3.ZERO)
		mi.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
		root.add_child(mi)
		halos.append({"node": mi, "phase": float(i) * 2.3})
		i += 1

# ------------------------------------------------------------------ per light / per frame
func _on_light(_light: String) -> void:
	l3 = _l3()
	var sun: DirectionalLight3D = host.get("sun")
	if rim_material != null:
		var rc: Variant = _g(["character", "rim", "color"], "sun")
		var rim_col: Color
		if str(rc) == "sun":
			var sc: Color = sun.light_color
			var tint: Color = _col(_g(["character", "rim", "tint"], "#ffffff"), Color.WHITE)
			rim_col = Color(sc.r * tint.r, sc.g * tint.g, sc.b * tint.b)
		else:
			rim_col = _col(rc, Color.WHITE)
		rim_material.set_shader_parameter("rim_color", rim_col)
		rim_material.set_shader_parameter("rim_strength", float(_g(["character", "rim", "strength"], 0.3)))
		rim_material.set_shader_parameter("rim_power", float(_g(["character", "rim", "power"], 3.0)))
		rim_material.set_shader_parameter("key_bias", float(_g(["character", "rim", "key_bias"], 0.6)))
		rim_material.set_shader_parameter("top_bias", float(_g(["character", "rim", "top_bias"], 0.25)))
		var key: Vector3 = _sun_dir()
		var local_r: float = float(_g(["character", "rim", "local_key_radius_m"], 0.0))
		var key_src: String = "sun"
		if local_r > 0.0:
			var best: float = local_r
			var ch_node: Node3D = host.get("character")
			var chest: Vector3 = ch_node.global_position + Vector3(0.0, float(host.get("character_height_m")) * 0.5, 0.0)
			var cands: Array[Vector3] = []
			for f: Dictionary in fires:
				if not bool(f.effect):
					cands.append((f.pos as Vector3) + Vector3(0.0, float(f.flame_h) * 0.5, 0.0))
			for lp: Variant in (host.get("tile") as Dictionary).get("lamps", []):
				cands.append(_v3(lp, Vector3.ZERO))
			for cpos: Vector3 in cands:
				var dist: float = cpos.distance_to(chest)
				if dist < best:
					best = dist
					key = (cpos - chest).normalized()
					key_src = "local"
			if key_src == "local":
				rim_material.set_shader_parameter("rim_color", _col(_g(["character", "rim", "local_key_color"], "#ffa060"), Color(1.0, 0.63, 0.38)))
		rim_material.set_shader_parameter("key_dir_world", key)
		report["rim_key"] = {"source": key_src, "dir": [key.x, key.y, key.z]}
	if char_fill != null:
		var fe: float = float(_g(["character", "fill", "energy"], 0.0))
		char_fill.visible = fe > 0.0
		char_fill.light_energy = fe
		char_fill.light_color = _col(_g(["character", "fill", "color"], "#ffe8cc"), Color(1.0, 0.91, 0.8))
	if contact_decal != null:
		contact_decal.modulate = Color(1, 1, 1, float(_g(["character", "contact", "strength"], 0.5)))
	for f: Dictionary in fires:
		if f.has("coal_mat"):
			(f.coal_mat as StandardMaterial3D).emission_energy_multiplier = float(_g(["fire", "coal_emission"], 1.0))
	for kind: String in smoke_materials.keys():
		var m: ShaderMaterial = smoke_materials[kind]
		m.set_shader_parameter("puff_color", _col(_g(["smoke", kind, "color"], "#d8ddd8"), Color(0.85, 0.87, 0.85)))
		m.set_shader_parameter("warm_color", _col(_g(["smoke", kind, "warm_color"], "#ff8a40"), Color(1.0, 0.54, 0.25)))
		m.set_shader_parameter("self_lit", float(_g(["smoke", kind, "self_lit"], 0.0)))
	if halo_material != null:
		halo_material.set_shader_parameter("halo_color", _col(_g(["lanterns", "halo_color"], "#ffb66e"), Color(1.0, 0.71, 0.43)))
		halo_material.set_shader_parameter("halo_strength", float(_g(["lanterns", "halo_strength"], 0.0)))
		halo_material.set_shader_parameter("halo_falloff", float(_g(["lanterns", "halo_falloff"], 3.2)))
		halo_material.set_shader_parameter("toward_camera_m", float(_g(["lanterns", "halo_toward_camera_m"], 0.25)))
		var hs: float = float(_g(["lanterns", "halo_size_m"], 0.6))
		for hrec: Dictionary in halos:
			(hrec.node as MeshInstance3D).scale = Vector3.ONE * hs
			(hrec.node as MeshInstance3D).visible = float(_g(["lanterns", "halo_strength"], 0.0)) > 0.0

func _on_tick(t: float, _delta: float) -> void:
	for f: Dictionary in fires:
		(f.node as Node3D).call("set_anim_time", t)
		# the act-3 module parks its sparks while frozen; follow the viewer's motion switch instead
		var sp: GPUParticles3D = (f.node as Node3D).get("sparks") as GPUParticles3D
		if sp != null:
			sp.speed_scale = 0.0 if bool(host.get("motion_frozen")) else 1.0
		if f.has("coal_mat"):
			var ce: float = float(_g(["fire", "coal_emission"], 1.0))
			(f.coal_mat as StandardMaterial3D).emission_energy_multiplier = ce * (0.85 + 0.15 * sin(t * 2.3 + float(f.scale) * 5.0))
	_update_smoke(t)
	if cup != null:
		_update_cup()
	if blossom != null:
		blossom.call("set_story_time", float(_g(["character", "blossom", "growth_s"], 5.5)), t)
	var flick: float = float(_g(["lanterns", "flicker"], 0.0))
	if flick > 0.0:
		var cfg: Dictionary = host.get("cfg")
		var base_e: float = float((cfg.get("lamps", {}) as Dictionary).get("light_energy", 0.5))
		var lamp_lights: Array = host.get("lamp_lights")
		for li: int in lamp_lights.size():
			var w: float = 1.0 + flick * (sin(t * 5.3 + li * 2.1) * 0.6 + sin(t * 11.7 + li) * 0.4)
			(lamp_lights[li] as OmniLight3D).light_energy = base_e * w
		for hrec: Dictionary in halos:
			(hrec.node as MeshInstance3D).set_instance_shader_parameter("halo_flicker", 1.0 + flick * sin(t * 5.3 + float(hrec.phase)) * 0.8)

# ------------------------------------------------------------------ findability probe
## Character mask = |frame(with L叔, no shadows) - frame(without L叔)|; statistics on the normal frame.
func _measure() -> void:
	var tree: SceneTree = host.get_tree()
	var vp: Viewport = host.get_viewport()
	for _i: int in 24:
		await RenderingServer.frame_post_draw
	var img_a: Image = vp.get_texture().get_image()
	for mi: MeshInstance3D in char_shadow_meshes:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if contact_decal != null:
		contact_decal.visible = false
	if not steam_emitter.is_empty():
		for p0: MeshInstance3D in steam_emitter.puffs:
			p0.visible = false
	for _i: int in 3:
		await RenderingServer.frame_post_draw
	var img_b: Image = vp.get_texture().get_image()
	var character: Node3D = host.get("character")
	var carrying: Node3D = host.get("carrying_pose")
	character.visible = false
	if carrying != null:
		carrying.visible = false
	if cup != null:
		cup.visible = false
	if blossom != null:
		blossom.visible = false
	for _i: int in 3:
		await RenderingServer.frame_post_draw
	var img_c: Image = vp.get_texture().get_image()
	character.visible = true
	if carrying != null:
		carrying.visible = true
	if cup != null:
		cup.visible = true
	if blossom != null:
		blossom.visible = true
	if not steam_emitter.is_empty():
		for p: MeshInstance3D in steam_emitter.puffs:
			p.visible = true
	for mi2: MeshInstance3D in char_shadow_meshes:
		mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if contact_decal != null:
		contact_decal.visible = true
	if tree == null:
		return
	measure_result = _stats(img_a, img_b, img_c)
	report["findability"] = measure_result
	host.call("add_report", "l3", report)

func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)

func _lab(c: Color) -> Vector3:
	var r: float = _lin(c.r); var g: float = _lin(c.g); var b: float = _lin(c.b)
	var x: float = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
	var y: float = 0.2126 * r + 0.7152 * g + 0.0722 * b
	var z: float = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
	var fx: float = _f(x); var fy: float = _f(y); var fz: float = _f(z)
	return Vector3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))

func _f(t: float) -> float:
	return pow(t, 1.0 / 3.0) if t > 0.008856 else 7.787 * t + 16.0 / 116.0

func _stats(a: Image, b: Image, c: Image) -> Dictionary:
	var body: MeshInstance3D = host.get("character_body")
	var pb: Dictionary = host.call("projected_bounds", body, body.bake_mesh_from_current_skeleton_pose() if body.skin != null else body.mesh)
	var bpx: Array = pb.bounds_px
	var h: float = maxf(float(pb.height_px), 20.0)
	var x0: int = clampi(int(float(bpx[0]) - h * 0.9), 0, a.get_width() - 1)
	var x1: int = clampi(int(float(bpx[2]) + h * 0.9), 0, a.get_width() - 1)
	var y0: int = clampi(int(float(bpx[1]) - h * 0.6), 0, a.get_height() - 1)
	var y1: int = clampi(int(float(bpx[3]) + h * 0.6), 0, a.get_height() - 1)
	var w: int = x1 - x0 + 1
	var hh: int = y1 - y0 + 1
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(w * hh)
	var lstar: PackedFloat32Array = PackedFloat32Array()
	lstar.resize(w * hh)
	var mx0: int = w; var mx1: int = -1; var my0: int = hh; var my1: int = -1
	var area: int = 0
	var char_lab: Vector3 = Vector3.ZERO
	for y: int in hh:
		for x: int in w:
			var pa: Color = a.get_pixel(x0 + x, y0 + y)
			var p1: Color = b.get_pixel(x0 + x, y0 + y)
			var p2: Color = c.get_pixel(x0 + x, y0 + y)
			var d: float = maxf(absf(p1.r - p2.r), maxf(absf(p1.g - p2.g), absf(p1.b - p2.b)))
			# keep only differences inside the projected body box (+15% of its height): SSAO/ambient changes
			# elsewhere are not the character
			var gx: float = float(x0 + x); var gy: float = float(y0 + y)
			if gx < float(bpx[0]) - h * 0.15 or gx > float(bpx[2]) + h * 0.15 or gy < float(bpx[1]) - h * 0.15 or gy > float(bpx[3]) + h * 0.15:
				d = 0.0
			var idx: int = y * w + x
			var lab: Vector3 = _lab(pa)
			lstar[idx] = lab.x
			if d > 0.04:
				mask[idx] = 1
				area += 1
				char_lab += lab
				mx0 = mini(mx0, x); mx1 = maxi(mx1, x); my0 = mini(my0, y); my1 = maxi(my1, y)
	if area == 0:
		return {"error": "empty mask"}
	var mask_path: String = str(mcfg.get("save_mask", ""))
	if not mask_path.is_empty():
		var mimg: Image = Image.create(w, hh, false, Image.FORMAT_RGB8)
		for yy: int in hh:
			for xx: int in w:
				var pa2: Color = a.get_pixel(x0 + xx, y0 + yy)
				mimg.set_pixel(xx, yy, Color(1, 0, 0) if mask[yy * w + xx] == 1 else pa2 * 0.6)
		mimg.save_png(mask_path.replace("{id}", str(host.get("recipe_id"))))
	char_lab /= float(area)
	# surround ring: within R px of the mask (separable box dilation), outside the mask
	var rad: int = maxi(4, int(h * 0.12))
	var horiz: PackedByteArray = PackedByteArray()
	horiz.resize(w * hh)
	for y2: int in hh:
		var run: int = 0
		for x2: int in range(-rad, w + rad):
			var add_x: int = x2 + rad
			if add_x >= 0 and add_x < w:
				run += mask[y2 * w + add_x]
			var sub_x: int = x2 - rad - 1
			if sub_x >= 0 and sub_x < w:
				run -= mask[y2 * w + sub_x]
			if x2 >= 0 and x2 < w:
				horiz[y2 * w + x2] = 1 if run > 0 else 0
	var ring_lab: Vector3 = Vector3.ZERO
	var ring_n: int = 0
	var ring_l: PackedFloat32Array = PackedFloat32Array()
	for x3: int in w:
		var run2: int = 0
		for y3: int in range(-rad, hh + rad):
			var add_y: int = y3 + rad
			if add_y >= 0 and add_y < hh:
				run2 += horiz[add_y * w + x3]
			var sub_y: int = y3 - rad - 1
			if sub_y >= 0 and sub_y < hh:
				run2 -= horiz[sub_y * w + x3]
			if y3 >= 0 and y3 < hh and run2 > 0 and mask[y3 * w + x3] == 0:
				var pc: Color = a.get_pixel(x0 + x3, y0 + y3)
				var lab2: Vector3 = _lab(pc)
				ring_lab += lab2
				ring_l.append(lab2.x)
				ring_n += 1
	ring_lab /= maxf(float(ring_n), 1.0)
	var ring_std: float = 0.0
	for v: float in ring_l:
		ring_std += (v - ring_lab.x) * (v - ring_lab.x)
	ring_std = sqrt(ring_std / maxf(float(ring_l.size()), 1.0))
	# silhouette edge contrast: |L*(inside) - L*(outside)| over boundary pixel pairs
	var edge_sum: float = 0.0
	var edge_n: int = 0
	var edge_strong: int = 0
	for y4: int in range(1, hh - 1):
		for x4: int in range(1, w - 1):
			var i4: int = y4 * w + x4
			if mask[i4] == 0:
				continue
			for o: int in [1, -1, w, -w]:
				if mask[i4 + o] == 0:
					var dl: float = absf(lstar[i4] - lstar[i4 + o])
					edge_sum += dl
					edge_n += 1
					if dl > 15.0:
						edge_strong += 1
	var ys: PackedInt32Array = PackedInt32Array()
	for yy2: int in hh:
		for xx2: int in w:
			if mask[yy2 * w + xx2] == 1:
				ys.append(yy2)
	ys.sort()
	var robust_h: int = ys[int(ys.size() * 0.99) - 1] - ys[int(ys.size() * 0.01)] + 1 if ys.size() > 10 else my1 - my0 + 1
	var de: float = char_lab.distance_to(ring_lab)
	return {
		"mask_px": area, "mask_height_px": robust_h, "mask_bbox_height_px": my1 - my0 + 1, "mask_width_px": mx1 - mx0 + 1, "frame_height_frac": float(robust_h) / float(a.get_height()),
		"char_lab": [char_lab.x, char_lab.y, char_lab.z], "ring_lab": [ring_lab.x, ring_lab.y, ring_lab.z], "ring_radius_px": rad,
		"delta_e": de, "delta_l": char_lab.x - ring_lab.x, "ring_l_std": ring_std,
		"edge_contrast_l": edge_sum / maxf(float(edge_n), 1.0), "edge_strong_frac": float(edge_strong) / maxf(float(edge_n), 1.0),
		"salience": de / maxf(ring_std, 2.0),
	}
