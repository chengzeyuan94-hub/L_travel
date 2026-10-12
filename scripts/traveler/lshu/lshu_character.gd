extends Node3D
## 第四幕「L叔在哪儿」· L叔, the real model of acts 1-3 (preloaded, never copied). Pose by the tile's kit action
## through look.json character.pose_map: look -> standing (action2_character.tscn + character_style.gd, idle),
## tea -> seated (panti sitting asset + panti_seated_actor.gd / panti_seated_style.gd), bloom -> carrying
## (baghdad_carrying_pose.gd + baghdad_potato_blossom.gd).
## Plus the character-side life of look.json "life.character": own render layer, facing clamp toward the camera,
## rim next_pass keyed to the sun (or a nearby fire / lamp), contact-shadow decal, tea cup, blossoms, optional
## character-only fill, and a feet-vs-ground check.
## One rig per pose is built once and re-placed on every tile (fix #6: no model loading on a tile switch).

const ACTION2_SCENE: String = "res://scenes/traveler/action2_character.tscn"
const SEATED_ASSET: String = "res://assets/traveler/panti/camp/character/sitting-animated.glb"
const STYLE_SCRIPT: GDScript = preload("res://scripts/traveler/character_style.gd")
const SEATED_ACTOR_SCRIPT: GDScript = preload("res://scripts/traveler/panti/panti_seated_actor.gd")
const SEATED_STYLE_SCRIPT: GDScript = preload("res://scripts/traveler/panti/panti_seated_style.gd")
const CARRYING_SCRIPT: GDScript = preload("res://scripts/traveler/baghdad/baghdad_carrying_pose.gd")
const BLOSSOM_SCRIPT: GDScript = preload("res://scripts/traveler/baghdad/baghdad_potato_blossom.gd")
const RIM_SHADER: Shader = preload("res://shaders/traveler/lshu/lshu_character_rim.gdshader")
const CAMERA: GDScript = preload("res://scripts/traveler/lshu/lshu_camera.gd")
const GROUND_INFO: GDScript = preload("res://scripts/traveler/lshu/lshu_ground_info.gd")
const BAGHDAD_CHARACTER_HEIGHT: float = 0.6375
## Fix #1 sole sampling (model units): vertices within SOLE_BAND_U of their foot's lowest vertex count as sole,
## deduplicated on a SOLE_CELL_U grid (lowest point per cell).
const SOLE_BAND_U: float = 0.02
const SOLE_CELL_U: float = 0.01
## Fix #1 seat column grid cell (metres, in the seat asset's frame).
const SEAT_CELL_M: float = 0.015
const FLOOR_LAYER: int = 1 << 19
const PARK_OFFSET: Vector3 = Vector3(0.0, -1000.0, 0.0)

## One built pose. Also the host object the act-3 carrying pose reads (character, character_model,
## character_body, character_geometry, stage_point()).
class Rig extends Node3D:
	var pose: String = ""
	var character: Node3D
	var character_model: Node3D
	var character_body: MeshInstance3D
	var character_geometry: Mesh
	var character_style: RefCounted
	var player: AnimationPlayer
	var anim: StringName = &""
	var anim_length: float = 0.0
	var seated_actor: RefCounted
	var carrying_pose: Node3D
	var flowers: Node3D
	var flowers_ratio: float = 1.0
	var cup: Node3D
	var cup_skeleton: Skeleton3D
	var cup_bones: Array[int] = []
	var meshes: Array[MeshInstance3D] = []
	var shadow_meshes: Array[MeshInstance3D] = []
	var rim_material: ShaderMaterial
	var contact_decal: Decal
	var fill: OmniLight3D
	var ok: bool = false
	var notes: Array[String] = []
	var bounds_geometry: Mesh
	## The character node's scale as built; place() sets it again every time, so a placement never depends on what
	## was done to the node before (a scale read back from a rotated transform can differ in its last bit).
	var base_scale: Vector3 = Vector3.ONE
	## Seated only (fix #1): lowest sole points over the whole seated idle, in character space (model units).
	var sole_points: PackedVector3Array = PackedVector3Array()

	func stage_point(a: Vector3) -> Vector3:
		return a

static var _blob_cache: Dictionary = {}
static var _seat_grid_cache: Dictionary = {}

var look: RefCounted
var rigs: Dictionary = {}
var active: Rig
var height_m: float = 1.15
var char_layer: int = 1 << 18
var tile_data: Dictionary = {}
var tile_node: Node3D
var steam_emitter: Dictionary = {}
var report: Dictionary = {}
var seat_fit: Dictionary = {}

func setup(look_ref: RefCounted) -> void:
	name = "LshuCharacter"
	look = look_ref
	var ch: Dictionary = (look.get("cfg") as Dictionary).get("character", {})
	height_m = float(ch.get("height_m", 1.15))
	char_layer = 1 << int(_g(["character", "layer_bit"], 18))

func _life() -> Dictionary:
	return (look.get("cfg") as Dictionary).get("life", {})

func _g(path: Array, fallback: Variant) -> Variant:
	var d: Variant = _life()
	for k: Variant in path:
		if not d is Dictionary or not (d as Dictionary).has(k):
			return fallback
		d = (d as Dictionary)[k]
	return d

static func _col(v: Variant, fallback: Color) -> Color:
	if v is String:
		return Color.html(str(v))
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return fallback

static func _v3(v: Variant, fallback: Vector3) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback

func pose_for(tile: Dictionary) -> String:
	var ch: Dictionary = (look.get("cfg") as Dictionary).get("character", {})
	var pose_map: Dictionary = ch.get("pose_map", {"look": "standing", "tea": "seated", "bloom": "carrying"})
	return str(pose_map.get(str((tile.get("character", {}) as Dictionary).get("action", "look")), "standing"))

# ------------------------------------------------------------------ rig construction (once per pose)
## Builds (or returns) the rig of a pose. Awaitable: the standing model needs one drawn frame to pose.
func rig_for(pose: String) -> Rig:
	if rigs.has(pose):
		return rigs[pose]
	var ch: Dictionary = (look.get("cfg") as Dictionary).get("character", {})
	var rig: Rig = Rig.new()
	rig.name = "Rig_" + pose
	rig.pose = pose
	add_child(rig)
	rig.character = Node3D.new()
	rig.character.name = "LshuTraveler"
	rig.add_child(rig.character)
	if pose == "seated":
		_build_seated(rig, ch)
	else:
		await _build_standing(rig, ch)
		if pose == "carrying":
			_build_carrying(rig, ch)
	# Camera-rule geometry: the body as it is right after the pose module configured it (the moment the
	# approved probe measured its tile bounds; for the seated rig that is not yet the drawn seated pose).
	if rig.character_body != null:
		rig.bounds_geometry = rig.character_body.bake_mesh_from_current_skeleton_pose() if rig.character_body.skin != null else rig.character_body.mesh
	_finish_rig(rig)
	if rig.seated_actor != null:
		_measure_soles(rig)
	rig.position = PARK_OFFSET
	rigs[pose] = rig
	return rig

func _build_standing(rig: Rig, ch: Dictionary) -> void:
	rig.character_model = (load(ACTION2_SCENE) as PackedScene).instantiate() as Node3D
	rig.character.add_child(rig.character_model)
	rig.player = rig.character_model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	rig.anim = StringName(str(ch.get("standing_animation", "idle")))
	rig.player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	rig.player.play(rig.anim)
	rig.anim_length = rig.player.get_animation(rig.anim).length
	rig.player.seek(float(ch.get("idle_offset_s", 0.0)), true)
	rig.player.advance(0.0)
	await RenderingServer.frame_post_draw
	rig.character_body = rig.character_model.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	rig.character_geometry = rig.character_body.bake_mesh_from_current_skeleton_pose()
	var bounds: AABB = rig.character_geometry.get_aabb()
	rig.character_model.position = Vector3(-bounds.get_center().x, -bounds.position.y, -bounds.get_center().z)
	rig.character_style = STYLE_SCRIPT.new()
	rig.character_style.call("configure", rig.character_model)
	var mult: float = float(ch.get("outline_multiplier", 1.0))
	for shell: MeshInstance3D in rig.character_style.get("shells"):
		(shell.material_override as StandardMaterial3D).grow_amount *= mult
	rig.base_scale = Vector3.ONE * (height_m / maxf(bounds.size.y, 0.001))
	rig.character.scale = rig.base_scale
	rig.ok = true

func _build_seated(rig: Rig, ch: Dictionary) -> void:
	rig.character_model = (load(SEATED_ASSET) as PackedScene).instantiate() as Node3D
	rig.character.add_child(rig.character_model)
	rig.seated_actor = SEATED_ACTOR_SCRIPT.new()
	rig.seated_actor.call("configure", rig.character_model, {})
	rig.character_style = SEATED_STYLE_SCRIPT.new()
	rig.character_style.call("configure", rig.character_model, float(ch.get("seated_outline_multiplier", ch.get("outline_multiplier", 1.0))))
	rig.character_body = rig.seated_actor.get("body") as MeshInstance3D
	# Seated asset: standing rest height normalized to 1.0 model units.
	rig.base_scale = Vector3.ONE * height_m
	rig.character.scale = rig.base_scale
	rig.ok = true

## Fix #1 seat fit settings: look.json character.seat_fit may override any of these defaults.
func _seat_cfg() -> Dictionary:
	var defaults: Dictionary = {"enabled": true, "sole_clearance_m": 0.003, "cycle_samples": 12, "min_scale": 0.2, "max_scale": 1.5,
		"rest_frac": 0.35, "slide_step_m": 0.01, "slide_max_m": 0.35, "seat_front_margin_m": 0.06, "top_tol_frac": 0.1,
		"balance_feet": true, "lateral_max_m": 0.04, "lateral_step_m": 0.002, "lateral_margin_m": 0.06, "lateral_min_gain_m": 0.003}
	var ch: Dictionary = (look.get("cfg") as Dictionary).get("character", {})
	var over: Variant = ch.get("seat_fit")
	if over is Dictionary:
		defaults.merge(over as Dictionary, true)
	return defaults

## Fix #1, once per seated rig: the lowest points of his soles over the whole seated idle, in character space.
## The foot / toe vertices are skinned on the CPU from the live skeleton with the renderer's own sum
## (bone global pose * bind pose, weighted), so no drawn frame is needed and it also works headless.
func _measure_soles(rig: Rig) -> void:
	var body: MeshInstance3D = rig.character_body
	var sk: Skeleton3D = rig.seated_actor.get("skeleton") as Skeleton3D
	if body == null or body.mesh == null or body.skin == null or sk == null:
		rig.notes.append("seat fit: no skinned seated body; sole points unavailable")
		return
	var skin: Skin = body.skin
	var bind_bone: PackedInt32Array = PackedInt32Array()
	var foot_bind: PackedByteArray = PackedByteArray()
	for i: int in skin.get_bind_count():
		var b: int = skin.get_bind_bone(i)
		if b < 0:
			b = sk.find_bone(str(skin.get_bind_name(i)))
		bind_bone.append(b)
		var bn: String = str(sk.get_bone_name(b)) if b >= 0 else ""
		foot_bind.append(1 if bn.ends_with("Foot") or bn.contains("Toe") else 0)
	# foot vertices: dominant weight on a foot / toe bind
	var verts: PackedVector3Array = PackedVector3Array()
	var vbones: PackedInt32Array = PackedInt32Array()
	var vweights: PackedFloat32Array = PackedFloat32Array()
	var voffset: PackedInt32Array = PackedInt32Array()
	for s: int in body.mesh.get_surface_count():
		var arrays: Array = body.mesh.surface_get_arrays(s)
		var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if arrays[Mesh.ARRAY_BONES] == null or arrays[Mesh.ARRAY_WEIGHTS] == null or sv.is_empty():
			continue
		var sb: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var sw: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var per: int = sb.size() / sv.size()
		for vi: int in sv.size():
			var best_w: float = -1.0
			var best_b: int = -1
			for j: int in per:
				if sw[vi * per + j] > best_w:
					best_w = sw[vi * per + j]
					best_b = sb[vi * per + j]
			if best_b < 0 or best_b >= foot_bind.size() or foot_bind[best_b] == 0:
				continue
			voffset.append(vbones.size())
			verts.append(sv[vi])
			for j2: int in per:
				vbones.append(sb[vi * per + j2])
				vweights.append(sw[vi * per + j2])
	voffset.append(vbones.size())
	if verts.is_empty():
		rig.notes.append("seat fit: no foot-weighted vertices; sole points unavailable")
		return
	var cfg: Dictionary = _seat_cfg()
	var samples: int = maxi(1, int(cfg.get("cycle_samples", 12)))
	var duration: float = float(rig.seated_actor.get("duration_s"))
	var body_to_char: Transform3D = rig.character.global_transform.affine_inverse() * body.global_transform
	var cells: Dictionary = {}
	for k: int in samples:
		rig.seated_actor.call("set_time", duration * float(k) / float(samples))
		var mats: Array[Transform3D] = []
		for i2: int in bind_bone.size():
			mats.append(sk.get_bone_global_pose(bind_bone[i2]) * skin.get_bind_pose(i2) if bind_bone[i2] >= 0 else Transform3D.IDENTITY)
		var pts: PackedVector3Array = PackedVector3Array()
		var lowest: Array[float] = [INF, INF]   # per foot (character-local x < 0 / >= 0)
		for vi2: int in verts.size():
			var acc: Vector3 = Vector3.ZERO
			var wsum: float = 0.0
			for j3: int in range(voffset[vi2], voffset[vi2 + 1]):
				var w: float = vweights[j3]
				if w <= 0.0:
					continue
				acc += (mats[vbones[j3]] * verts[vi2]) * w
				wsum += w
			var p: Vector3 = body_to_char * (acc / maxf(wsum, 1e-6))
			pts.append(p)
			var side: int = 1 if p.x >= 0.0 else 0
			lowest[side] = minf(lowest[side], p.y)
		for p2: Vector3 in pts:
			if p2.y > lowest[1 if p2.x >= 0.0 else 0] + SOLE_BAND_U:
				continue
			var key: Vector2i = Vector2i(floori(p2.x / SOLE_CELL_U), floori(p2.z / SOLE_CELL_U))
			if not cells.has(key) or (cells[key] as Vector3).y > p2.y:
				cells[key] = p2
	rig.seated_actor.call("set_time", 0.0)
	for q: Variant in cells.values():
		rig.sole_points.append(q as Vector3)
	rig.set_meta("sole_foot_vertices", verts.size())

func _build_carrying(rig: Rig, ch: Dictionary) -> void:
	rig.carrying_pose = CARRYING_SCRIPT.new() as Node3D
	rig.carrying_pose.set("turn_right_degrees", float(ch.get("carrying_turn_deg", 0.0)))
	rig.add_child(rig.carrying_pose)
	var ok: bool = bool(rig.carrying_pose.call("configure", rig))
	if not ok:
		rig.notes.append("carrying pose failed; standing idle kept")
		rig.carrying_pose.queue_free()
		rig.carrying_pose = null
		return
	var ratio: float = height_m / BAGHDAD_CHARACTER_HEIGHT * float(ch.get("carrying_bundle_scale", 1.0))
	rig.carrying_pose.call("set_bundle_adjustment", rig.carrying_pose.get("bundle_offset_normalized"), ratio)
	if bool(_g(["character", "flowers", "enabled"], true)):
		_setup_flowers(rig)

func _setup_flowers(rig: Rig) -> void:
	rig.flowers = BLOSSOM_SCRIPT.new() as Node3D
	rig.flowers.set("autoplay", false)
	rig.flowers.set("emission_strength", float(_g(["character", "flowers", "emission"], 0.8)))
	rig.flowers.set("hand_light_energy", 0.0)
	rig.add_child(rig.flowers)
	var ok: bool = bool(rig.flowers.call("configure", rig.carrying_pose))
	if not ok:
		rig.flowers.queue_free()
		rig.flowers = null
		rig.notes.append("potato flowers configure failed")
		return
	# The module sizes flowers in Baghdad world units (L叔 0.6375 m). Scale each stalk about its own
	# anchor by the same height ratio used for the potato bundle.
	rig.flowers_ratio = height_m / BAGHDAD_CHARACTER_HEIGHT * float(_g(["character", "flowers", "scale"], 1.0))
	var stalks: Array = rig.flowers.get("_stalks")
	for rec: Variant in stalks:
		var n: Node3D = (rec as Dictionary).get("node") as Node3D
		if n != null:
			n.scale = Vector3.ONE * rig.flowers_ratio

## Once per rig: collect the visible character meshes, own render layer, rim pass, decal, fill, cup.
func _finish_rig(rig: Rig) -> void:
	for node: Node in rig.character.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node as MeshInstance3D
		if not mi.is_visible_in_tree():
			continue
		rig.meshes.append(mi)
		if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			rig.shadow_meshes.append(mi)
	if rig.carrying_pose != null:
		for node2: Node in rig.carrying_pose.find_children("*", "MeshInstance3D", true, false):
			var mi2: MeshInstance3D = node2 as MeshInstance3D
			if not rig.meshes.has(mi2) and mi2.is_visible_in_tree():
				rig.meshes.append(mi2)
				if mi2.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					rig.shadow_meshes.append(mi2)
	for mi3: MeshInstance3D in rig.meshes:
		mi3.layers = char_layer
	if rig.flowers != null:
		for node3: Node in rig.flowers.find_children("*", "MeshInstance3D", true, false):
			(node3 as MeshInstance3D).layers = char_layer
		if rig.carrying_pose != null:
			for node4: Node in rig.carrying_pose.find_children("*", "MeshInstance3D", true, false):
				var mi4: MeshInstance3D = node4 as MeshInstance3D
				if not rig.meshes.has(mi4):
					rig.meshes.append(mi4)
				mi4.layers = char_layer
	# rim pass on the styled body surfaces (not on the unshaded outline shells), as in the approved probe.
	# It is only drawn after the character has been re-shown once (see refresh_after_place()).
	if bool(_g(["character", "rim", "enabled"], true)):
		rig.rim_material = ShaderMaterial.new()
		rig.rim_material.shader = RIM_SHADER
		# The seated and carrying bodies are depth-prepass transparent meshes, so their additive rim pass ties
		# with the body in the transparent sort (same depth) and the engine's unstable sort decides which draws
		# last; the standing body is opaque and always gets its rim. The approved home tile shows the seated rim,
		# and merging the smoke into one draw (fix #4) flipped that tie, so the seated rim is pinned to draw after
		# (priority 1). The carrying rim is left as approved (not drawn on the pool's carrying tiles).
		if rig.pose == "seated":
			rig.rim_material.render_priority = 1
		var rim_count: int = 0
		for mi5: MeshInstance3D in rig.meshes:
			if mi5.material_override != null or mi5.mesh == null:
				continue
			for s: int in mi5.mesh.get_surface_count():
				var m: Material = mi5.get_active_material(s)
				if m == null or m.next_pass != null:
					continue
				if m is BaseMaterial3D and ((m as BaseMaterial3D).shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED or (m as BaseMaterial3D).cull_mode == BaseMaterial3D.CULL_FRONT):
					continue   # outline shells / unshaded parts
				m.next_pass = rig.rim_material
				rim_count += 1
		rig.set_meta("rim_surfaces", rim_count)
	if bool(_g(["character", "contact", "enabled"], true)):
		rig.contact_decal = Decal.new()
		rig.contact_decal.name = "ContactShadow"
		var radius: float = float(_g(["character", "contact", "seated_radius_m" if rig.pose == "seated" else "radius_m"], 0.4)) * height_m / 1.15
		var box_h: float = float(_g(["character", "contact", "height_m"], 0.5))
		rig.contact_decal.size = Vector3(radius * 2.0, box_h, radius * 2.0)
		rig.contact_decal.set_texture(Decal.TEXTURE_ALBEDO, _blob_texture(float(_g(["character", "contact", "softness"], 1.6))))
		rig.contact_decal.albedo_mix = 1.0
		rig.contact_decal.normal_fade = 0.35
		rig.contact_decal.upper_fade = 0.3
		rig.contact_decal.lower_fade = 0.3
		rig.contact_decal.cull_mask = 0xFFFFF & ~char_layer & ~FLOOR_LAYER
		rig.add_child(rig.contact_decal)
	# character-only fill ("eye light"): lights only the character layer; energy per light preset (0 = off)
	rig.fill = OmniLight3D.new()
	rig.fill.name = "CharacterFill"
	rig.fill.omni_range = height_m * 1.6
	rig.fill.omni_attenuation = 1.0
	rig.fill.light_cull_mask = char_layer
	rig.fill.shadow_enabled = false
	rig.fill.light_specular = 0.0
	rig.add_child(rig.fill)
	if rig.pose == "seated" and bool(_g(["character", "cup", "enabled"], true)):
		_setup_cup(rig)

static func _blob_texture(softness: float) -> ImageTexture:
	if _blob_cache.has(softness):
		return _blob_cache[softness]
	var n: int = 64
	var img: Image = Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y: int in n:
		for x: int in n:
			var dx: float = (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var dy: float = (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var d: float = sqrt(dx * dx + dy * dy)
			var a: float = pow(clampf(1.0 - d, 0.0, 1.0), softness)
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, a))
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_blob_cache[softness] = tex
	return tex

func _setup_cup(rig: Rig) -> void:
	rig.cup_skeleton = rig.character.find_child("Skeleton3D", true, false) as Skeleton3D
	if rig.cup_skeleton == null:
		return
	for bn: String in ["mixamorig_RightHand", "mixamorig_RightHandMiddle1", "mixamorig_LeftHand", "mixamorig_LeftHandMiddle1"]:
		rig.cup_bones.append(rig.cup_skeleton.find_bone(bn))
	if rig.cup_bones.has(-1):
		rig.notes.append("cup: hand bones missing")
		return
	var hscale: float = height_m / 1.15
	rig.cup = Node3D.new()
	rig.cup.name = "TeaCup"
	rig.add_child(rig.cup)
	var cyl: CylinderMesh = CylinderMesh.new()
	var r: float = float(_g(["character", "cup", "radius_m"], 0.035)) * hscale
	var hgt: float = float(_g(["character", "cup", "height_m"], 0.07)) * hscale
	cyl.top_radius = r
	cyl.bottom_radius = r * 0.82
	cyl.height = hgt
	cyl.radial_segments = 8
	cyl.rings = 1
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = _col(_g(["character", "cup", "color"], "#e8dcc8"), Color(0.9, 0.85, 0.78))
	mat.roughness = 0.6
	cyl.material = mat
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = cyl
	mi.layers = char_layer
	rig.cup.add_child(mi)
	var tea: CylinderMesh = CylinderMesh.new()
	tea.top_radius = r * 0.86
	tea.bottom_radius = r * 0.86
	tea.height = 0.004
	tea.radial_segments = 8
	tea.rings = 1
	var tmat: StandardMaterial3D = StandardMaterial3D.new()
	tmat.albedo_color = Color.html("#7a4a22")
	tea.material = tmat
	var tmi: MeshInstance3D = MeshInstance3D.new()
	tmi.mesh = tea
	tmi.position = Vector3(0.0, hgt * 0.5 - 0.006, 0.0)
	tmi.layers = char_layer
	rig.cup.add_child(tmi)
	rig.meshes.append(mi)
	rig.meshes.append(tmi)

# ------------------------------------------------------------------ per tile
## Step 1 (before the camera fit): select the pose rig and put it on the tile's spot. Awaitable.
func place(tile: Dictionary) -> Rig:
	tile_data = tile
	seat_fit = {}
	var pose: String = pose_for(tile)
	var rig: Rig = await rig_for(pose)
	return _place_rig(tile, rig)

## place() for a pose whose rig is already built (synchronous; null when it is not): the scene plans a staged tile with it.
func place_built(tile: Dictionary) -> Rig:
	var pose: String = pose_for(tile)
	if not rigs.has(pose):
		return null
	tile_data = tile
	seat_fit = {}
	return _place_rig(tile, rigs[pose] as Rig)

func _place_rig(tile: Dictionary, rig: Rig) -> Rig:
	# Unused rigs are parked far below the stage, never hidden: a character MeshInstance that is first shown
	# after being hidden draws without its rim next_pass (measured on Godot 4.7.1; the approved probe never
	# hid him), so rigs change place instead of visibility.
	for other: Variant in rigs.values():
		(other as Rig).position = Vector3.ZERO if other == rig else PARK_OFFSET
	active = rig
	var c: Dictionary = tile.get("character", {})
	var ch: Dictionary = (look.get("cfg") as Dictionary).get("character", {})
	rig.character.position = _v3(c.get("position", [0, 0, 0]), Vector3.ZERO) + _v3(ch.get("offset", [0, 0, 0]), Vector3.ZERO)
	rig.character.scale = rig.base_scale
	rig.character.rotation = Vector3(0.0, float(c.get("yaw", 0.4)) + deg_to_rad(float(ch.get("yaw_offset_deg", 0.0))), 0.0)
	if rig.carrying_pose != null:
		rig.character.rotation.y -= deg_to_rad(float(ch.get("carrying_turn_deg", 0.0)))
	if rig.seated_actor != null:
		var cp: Array = c.get("position", [0, 0, 0])
		var seat_top: float = float(c.get("seat_top")) if c.get("seat_top") != null else float(cp[1])
		var seat_world: Vector3 = Vector3(float(cp[0]), seat_top, float(cp[2])) + _v3(ch.get("seat_offset", [0, 0, 0]), Vector3.ZERO)
		var anchor: Vector3 = rig.seated_actor.get("seat_anchor")
		rig.character.global_position = seat_world - rig.character.global_basis * anchor
	# bounds use the pose at clock 0 (as the approved probe did); the scene clock is applied after the fit
	tick(0.0, true)
	return rig

## Planning a staged tile while another one is on screen (verify_r2 item 1): the shared state place() / the fit /
## finish() change - which rig is active and every rig's transforms, the tile data, the reports - captured so
## restore_placement() puts it back exactly within the same frame (the skeleton poses are re-sampled by the next
## tick() before anything is drawn).
func save_placement() -> Dictionary:
	var rs: Array = []
	for v: Variant in rigs.values():
		var rig: Rig = v
		rs.append([rig, rig.transform, rig.character.transform, rig.contact_decal.transform if rig.contact_decal != null else Transform3D.IDENTITY,
			rig.fill.transform if rig.fill != null else Transform3D.IDENTITY, rig.cup.transform if rig.cup != null else Transform3D.IDENTITY])
	return {"active": active, "tile_data": tile_data, "seat_fit": seat_fit, "report": report, "steam_emitter": steam_emitter,
		"tile_node": tile_node, "rigs": rs}

func restore_placement(saved: Dictionary) -> void:
	for v: Variant in saved.rigs as Array:
		var r: Array = v
		var rig: Rig = r[0]
		if not is_instance_valid(rig):
			continue
		rig.transform = r[1]
		rig.character.transform = r[2]
		if rig.contact_decal != null:
			rig.contact_decal.transform = r[3]
		if rig.fill != null:
			rig.fill.transform = r[4]
		if rig.cup != null:
			rig.cup.transform = r[5]
	active = saved.active
	tile_data = saved.tile_data
	seat_fit = saved.seat_fit
	report = saved.report
	steam_emitter = saved.steam_emitter
	tile_node = saved.tile_node

## Fix #1 (seated feet on the ground), one global rule, applied before the tile bounds, for the seat he sits on (the
## tile's support instance nearest his spot; H = its height above its base b):
##  1. slide: where the seat itself stands under his soles higher than rest_frac x H (a stump's trunk under his
##     tucked heels), he slides forward along his facing by the smallest step that clears it, while his seat point
##     stays seat_front_margin_m inside the seat's top face; nothing under his soles, no slide (a bench).
##  1b. each foot: where what is under his two feet differs in height (feet straddling a root's rounded top), he
##     shifts sideways to where the two feet hang most alike (_balance_feet), so the drop below that rests the lower
##     foot leaves the other one resting too.
##  2. height: the seat is scaled in height by s about its base and he moves down with its top, by the smallest
##     drop at which one sole point (lowest reach over the whole seated idle) touches what is under it + clearance:
##     the terrain g, or a low part of the seat itself at hl above b (a root), which scales with it:
##     p - H(1 - s) >= g + c  and  p - H(1 - s) >= b + s hl + c.
## Three steps so the scene can plan it for a staged tile off the swap frame (verify_r2 item 1): fit_inputs() reads
## the scene (main thread, the rig placed on the tile), fit_compute() is pure data (a worker thread may run it),
## fit_apply() moves him and scales the seat. fit_support() runs the three at once.
func fit_support(tile: Node3D) -> void:
	var rig: Rig = active
	if rig == null or rig.seated_actor == null:
		return
	var t0: int = Time.get_ticks_usec()
	var inp: Dictionary = fit_inputs(tile)
	fit_apply(inp, fit_compute(inp))
	seat_fit["fit_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0

## Everything the seat fit reads from the scene, copied (main thread; the active rig placed on the tile). {} when the
## active rig is not seated. "early" = the fit's result when there is nothing to fit.
func fit_inputs(tile: Node3D) -> Dictionary:
	var rig: Rig = active
	if rig == null or rig.seated_actor == null:
		return {}
	var cfg: Dictionary = _seat_cfg()
	var out: Dictionary = {"rule": "slide forward off the seat body under his soles, then scale the seat height so the lowest sole touches ground or a low seat part"}
	if not bool(cfg.get("enabled", true)):
		out["note"] = "disabled"
		return {"early": out}
	if rig.sole_points.is_empty():
		out["note"] = "no sole points"
		return {"early": out}
	var c: Dictionary = tile_data.get("character", {})
	var support_id: String = str(c.get("support", ""))
	var cp: Array = c.get("position", [0, 0, 0])
	var holder: Node3D = null
	var base_scale: float = 1.0
	var best: float = INF
	for rv: Variant in tile.get("instance_nodes"):
		var rec: Dictionary = rv
		var data: Dictionary = rec.get("data", {})
		if str(data.get("asset_id", "")) != support_id:
			continue
		var ip: Array = data.get("position", [0, 0, 0])
		var d: float = Vector2(float(ip[0]) - float(cp[0]), float(ip[2]) - float(cp[2])).length()
		if d < best:
			best = d
			holder = rec.get("node") as Node3D
			base_scale = float(data.get("scale", 1.0))
	if holder == null or c.get("seat_top") == null:
		out["note"] = "no seat instance under him; not fitted"
		return {"early": out}
	var base_y: float = holder.global_position.y
	var seat_top: float = float(c.get("seat_top"))
	var seat_h: float = seat_top - base_y
	if seat_h <= 0.01:
		out["note"] = "seat height <= 0.01 m; not fitted"
		return {"early": out}
	return {"out": out, "cfg": cfg, "holder": holder, "base_scale": base_scale, "best": best, "base_y": base_y, "seat_top": seat_top,
		"seat_h": seat_h, "grid_src": _seat_grid_source(holder), "hxf": holder.global_transform, "xf": rig.character.global_transform,
		"sole_points": rig.sole_points, "anchor_w": (rig.seated_actor.get("model") as Node3D).global_transform * (rig.seated_actor.get("seat_anchor") as Vector3),
		"hgrid": tile.get("height_grid"), "hn": int(tile.get("terrain_n")), "hstep": float(tile.get("terrain_step"))}

## The seat fit on copied data (thread-safe). Returns {out: the seat_fit report, delta: his move, scale: the seat's
## new scale, grid_key / grid: a seat grid built here for the cache}; {out} only when there is nothing to fit.
static func fit_compute(inp: Dictionary) -> Dictionary:
	if inp.is_empty():
		return {}
	if inp.has("early"):
		return {"out": inp.early}
	var out: Dictionary = (inp.out as Dictionary).duplicate()
	var cfg: Dictionary = inp.cfg
	var hg: Array = inp.hgrid
	var hn: int = int(inp.hn)
	var hs: float = float(inp.hstep)
	var base_y: float = float(inp.base_y)
	var seat_top: float = float(inp.seat_top)
	var seat_h: float = float(inp.seat_h)
	var clearance: float = float(cfg.get("sole_clearance_m", 0.003))
	var rest_h: float = float(cfg.get("rest_frac", 0.25)) * seat_h
	var tg: int = Time.get_ticks_usec()
	var src: Dictionary = inp.grid_src
	var grid: Dictionary = src.grid if src.has("grid") else _seat_grid_build(src)
	out["seat_grid_ms"] = float(Time.get_ticks_usec() - tg) / 1000.0   # first use of a seat asset only (cached)
	# work in the seat's own frame (yaw + uniform scale): x/z lookups, heights y_w = base_y + sy * y_l
	var hxf: Transform3D = inp.hxf
	var inv: Transform3D = hxf.affine_inverse()
	var sy: float = hxf.basis.y.y
	var xf: Transform3D = inp.xf
	var fwd: Vector3 = Vector3(xf.basis.z.x, 0.0, xf.basis.z.z).normalized()
	var pts: PackedVector3Array = PackedVector3Array()
	var loc: PackedVector3Array = PackedVector3Array()
	var sole_points: PackedVector3Array = inp.sole_points
	for p: Vector3 in sole_points:
		var w: Vector3 = xf * p
		pts.append(w)
		loc.append(inv * w)
	var rest_l: float = rest_h / sy
	# 1. slide
	var anchor_w: Vector3 = inp.anchor_w
	var top_l: float = (seat_top - float(cfg.get("top_tol_frac", 0.1)) * seat_h - base_y) / sy
	var margin: float = float(cfg.get("seat_front_margin_m", 0.06))
	var step: float = maxf(0.002, float(cfg.get("slide_step_m", 0.01)))
	var slide_max: float = float(cfg.get("slide_max_m", 0.35))
	var slide: float = 0.0
	var cleared: bool = false
	var blocked0: int = _count_blocked(grid, loc, Vector3.ZERO, rest_l)
	var coarse: PackedVector3Array = PackedVector3Array()   # every 4th sole point steps the search; all confirm it
	for ci: int in range(0, loc.size(), 4):
		coarse.append(loc[ci])
	while slide <= slide_max + 1e-6:
		var off_l: Vector3 = inv.basis * (fwd * slide)
		var front: Vector3 = inv * (anchor_w + fwd * (slide + margin))
		if _span(grid, front.x, front.z).y < top_l:
			break   # his seat point would leave the seat's top face
		if _count_blocked(grid, coarse, off_l, rest_l) == 0 and _count_blocked(grid, loc, off_l, rest_l) == 0:
			cleared = true
			break
		slide += step
	if not cleared:
		slide = 0.0
	var slide_v: Vector3 = fwd * slide
	# 1b. each foot
	var side_dir: Vector3 = Vector3(xf.basis.x.x, 0.0, xf.basis.x.z).normalized()
	var feet_side: PackedByteArray = PackedByteArray()
	for p2: Vector3 in sole_points:
		feet_side.append(1 if p2.x >= 0.0 else 0)
	var balance: Dictionary = _balance_feet(cfg, {"grid": grid, "inv": inv, "base_y": base_y, "sy": sy, "rest_l": rest_l,
		"top_l": top_l, "anchor_w": anchor_w + slide_v, "side_dir": side_dir, "hgrid": hg, "hn": hn, "hstep": hs}, pts, loc, feet_side, slide_v)
	var lateral: float = float(balance.get("shift_m", 0.0))
	slide_v += side_dir * lateral
	var slide_l: Vector3 = inv.basis * slide_v
	# 2. height: solve s over every sole point at the slid position
	var s_need: float = -INF
	var gap_before: float = INF
	var ground: PackedFloat32Array = PackedFloat32Array()
	var part: PackedFloat32Array = PackedFloat32Array()
	var blocked: int = 0
	for i: int in pts.size():
		var w2: Vector3 = pts[i]
		var q: Vector3 = w2 + slide_v
		var ql: Vector3 = loc[i] + slide_l
		var g: float = GROUND_INFO.height_at(hg, hn, hs, q.x, q.z)
		var col: Vector2 = _span(grid, ql.x, ql.z)   # seat-frame (lowest, highest) surface in this column
		var hl: float = -INF
		if col.y > -INF:
			if col.y <= rest_l:
				hl = base_y + sy * col.y
			elif col.x < ql.y:
				blocked += 1
		ground.append(g)
		part.append(hl)
		gap_before = minf(gap_before, w2.y - GROUND_INFO.height_at(hg, hn, hs, w2.x, w2.z))
		s_need = maxf(s_need, 1.0 - (q.y - g - clearance) / seat_h)
		if hl > -INF:
			s_need = maxf(s_need, (base_y + clearance - q.y + seat_h) / (seat_h - (hl - base_y)))
	var s: float = clampf(s_need, float(cfg.get("min_scale", 0.2)), float(cfg.get("max_scale", 1.5)))
	var drop: float = seat_h * (1.0 - s)
	var gap_after: float = INF
	var gap_ground_after: float = INF
	var foot_after: Array[float] = [INF, INF]
	var on_parts: int = 0
	for i2: int in pts.size():
		var y: float = pts[i2].y - drop
		var under: float = ground[i2]
		if part[i2] > -INF:
			var hs2: float = base_y + s * (part[i2] - base_y)
			if hs2 > under:
				under = hs2
				on_parts += 1
		gap_after = minf(gap_after, y - under)
		gap_ground_after = minf(gap_ground_after, y - ground[i2])
		foot_after[feet_side[i2]] = minf(foot_after[feet_side[i2]], y - under)
	var base_scale: float = float(inp.base_scale)
	out.merge({"support_distance_m": float(inp.best), "seat_base_y": base_y, "seat_height_m": seat_h, "seat_height_after_m": seat_h * s,
		"scale_y": s, "drop_m": drop, "slide_m": slide, "slide_dir": [fwd.x, fwd.z], "slide_cleared": cleared,
		"sole_points_blocked_before": blocked0, "clearance_m": clearance, "rest_height_m": rest_h,
		"sole_points": pts.size(), "seat_triangles": grid.triangles, "seat_grid_cells": [grid.nx, grid.nz], "sole_points_blocked_after": blocked,
		"sole_points_on_seat_parts": on_parts, "sole_gap_before_m": gap_before, "sole_gap_after_m": gap_after,
		"sole_gap_vs_terrain_after_m": gap_ground_after, "lateral_m": lateral, "feet_balance": balance,
		"foot_gap_after_m": {"minus_x": foot_after[0], "plus_x": foot_after[1]}})
	var res: Dictionary = {"out": out, "delta": slide_v + Vector3(0.0, -drop, 0.0), "scale": Vector3(base_scale, base_scale * s, base_scale)}
	if not src.has("grid"):
		res["grid_key"] = src.key
		res["grid"] = grid
	return res

## Applies a fit_compute() result (main thread): he moves, the seat is scaled, the report is kept; a seat grid built
## by the fit goes into the cache.
func fit_apply(inp: Dictionary, res: Dictionary) -> void:
	if res.is_empty():
		return
	if res.has("grid_key") and not _seat_grid_cache.has(res.grid_key):
		_seat_grid_cache[res.grid_key] = res.grid
	if res.has("delta"):
		active.character.global_position += res.delta as Vector3
		(inp.holder as Node3D).scale = res.scale as Vector3
	seat_fit = res.out

## Fix #1 step 1b, each foot (P0 verifier round 1: the height fit rests his LOWER foot, the other one may still hang).
## Candidate sideways shifts d along his own side-to-side axis (0, +-lateral_step_m ... +-lateral_max_m, applied on
## top of the forward slide). At each, per foot: the gap of its lowest reach over the idle to what is under it
## (terrain, or a seat part no higher than rest_frac x H, its top interpolated between the exact seat-grid samples).
## The chosen shift makes the two feet's gaps most alike (the drop then rests both); it is taken only if it lowers
## the difference by more than lateral_min_gain_m versus no shift, never with a sole over a higher seat part, and
## never moving his seat point within lateral_margin_m of the edge of the seat's top face (sideways).
static func _balance_feet(cfg: Dictionary, seat: Dictionary, pts: PackedVector3Array, loc: PackedVector3Array,
		feet_side: PackedByteArray, slide_v: Vector3) -> Dictionary:
	var out: Dictionary = {"shift_m": 0.0}
	if not bool(cfg.get("balance_feet", true)):
		out["note"] = "off"
		return out
	var side_dir: Vector3 = seat.side_dir
	var step: float = maxf(0.0005, float(cfg.get("lateral_step_m", 0.002)))
	var max_shift: float = float(cfg.get("lateral_max_m", 0.04))
	var margin: float = float(cfg.get("lateral_margin_m", 0.06))
	var t0: int = Time.get_ticks_usec()
	var at_zero: Vector2 = _feet_gaps(seat, pts, loc, feet_side, slide_v)
	if is_inf(at_zero.x) or is_inf(at_zero.y):
		out["note"] = "sole points on one side only"
		return out
	var diff0: float = absf(at_zero.y - at_zero.x)
	# coarse pass: every 4th sole point, 2 x step; then the best coarse shift and its two neighbours with every point
	var c_pts: PackedVector3Array = PackedVector3Array()
	var c_loc: PackedVector3Array = PackedVector3Array()
	var c_side: PackedByteArray = PackedByteArray()
	for ci: int in range(0, pts.size(), 4):
		c_pts.append(pts[ci])
		c_loc.append(loc[ci])
		c_side.append(feet_side[ci])
	var c0: Vector2 = _feet_gaps(seat, c_pts, c_loc, c_side, slide_v)
	var best_c: float = 0.0
	var best_c_diff: float = absf(c0.y - c0.x)
	var tried: int = 0
	var n: int = int(floor(max_shift / (2.0 * step) + 1e-6))
	for k: int in range(1, n + 1):
		for sgn: float in [-1.0, 1.0]:
			var d: float = sgn * float(k) * 2.0 * step
			if not _shift_allowed(seat, c_loc, slide_v, d, margin):
				continue
			tried += 1
			var g: Vector2 = _feet_gaps(seat, c_pts, c_loc, c_side, slide_v + side_dir * d)
			if absf(g.y - g.x) < best_c_diff - 1e-6:
				best_c_diff = absf(g.y - g.x)
				best_c = d
	var best_d: float = 0.0
	var best_diff: float = diff0
	if best_c != 0.0:
		for d2: float in [best_c - step, best_c, best_c + step]:
			if absf(d2) > max_shift + 1e-6 or absf(d2) < 1e-6 or not _shift_allowed(seat, loc, slide_v, d2, margin):
				continue
			tried += 1
			var g2: Vector2 = _feet_gaps(seat, pts, loc, feet_side, slide_v + side_dir * d2)
			if absf(g2.y - g2.x) < best_diff - 1e-6:
				best_diff = absf(g2.y - g2.x)
				best_d = d2
	if diff0 - best_diff <= float(cfg.get("lateral_min_gain_m", 0.003)):
		best_d = 0.0
		best_diff = diff0
	out.merge({"shift_m": best_d, "foot_gap_diff_unshifted_m": diff0, "foot_gap_diff_m": best_diff,
		"foot_gaps_unshifted_m": {"minus_x": at_zero.x, "plus_x": at_zero.y}, "candidates": tried,
		"ms": float(Time.get_ticks_usec() - t0) / 1000.0}, true)
	return out

## A sideways shift d is allowed when his seat point stays margin inside the seat's top face on that side and no
## sole point (seat frame loc, offset by the slide and the shift) stands over a seat part higher than rest_l.
static func _shift_allowed(seat: Dictionary, loc: PackedVector3Array, slide_v: Vector3, d: float, margin: float) -> bool:
	var grid: Dictionary = seat.grid
	var inv: Transform3D = seat.inv
	var side_dir: Vector3 = seat.side_dir
	var edge: Vector3 = inv * ((seat.anchor_w as Vector3) + side_dir * (d + signf(d) * margin))
	if _span(grid, edge.x, edge.z).y < float(seat.top_l):
		return false
	return _count_blocked(grid, loc, inv.basis * (slide_v + side_dir * d), float(seat.rest_l)) == 0

## Per foot (x = his -x side, y = +x side): min over its sole points, offset by off_w (world), of the gap to the
## terrain (seat.hgrid / hn / hstep, the tile's height field) or to a seat part no higher than rest_l (seat top
## interpolated, _span_lerp); before the height fit.
static func _feet_gaps(seat: Dictionary, pts: PackedVector3Array, loc: PackedVector3Array, feet_side: PackedByteArray, off_w: Vector3) -> Vector2:
	var grid: Dictionary = seat.grid
	var inv: Transform3D = seat.inv
	var base_y: float = seat.base_y
	var sy: float = seat.sy
	var rest_l: float = seat.rest_l
	var hg: Array = seat.hgrid
	var hn: int = int(seat.hn)
	var hs: float = float(seat.hstep)
	var off_l: Vector3 = inv.basis * off_w
	var gaps: Array[float] = [INF, INF]
	for i: int in pts.size():
		var q: Vector3 = pts[i] + off_w
		var ql: Vector3 = loc[i] + off_l
		var under: float = GROUND_INFO.height_at(hg, hn, hs, q.x, q.z)
		var top: float = _span_lerp(grid, ql.x, ql.z)
		if top > -INF and top <= rest_l:
			under = maxf(under, base_y + sy * top)
		var sd: int = feet_side[i]
		gaps[sd] = minf(gaps[sd], q.y - under)
	return Vector2(gaps[0], gaps[1])

## Seat top at seat-frame (x, z) interpolated between the four exact grid samples around it; where one of them is
## off the seat, the conservative _span top (highest of the four); -INF outside the seat.
static func _span_lerp(grid: Dictionary, x: float, z: float) -> float:
	var o: Vector3 = grid.origin
	var cell: float = grid.cell
	var nx: int = grid.nx
	var nz: int = grid.nz
	var fx: float = (x - o.x) / cell
	var fz: float = (z - o.z) / cell
	var ix: int = int(floor(fx))
	var jz: int = int(floor(fz))
	if ix >= 0 and jz >= 0 and ix + 1 < nx and jz + 1 < nz:
		var hi_a: PackedFloat32Array = grid.hi
		var h00: float = hi_a[jz * nx + ix]
		var h10: float = hi_a[jz * nx + ix + 1]
		var h01: float = hi_a[(jz + 1) * nx + ix]
		var h11: float = hi_a[(jz + 1) * nx + ix + 1]
		if h00 > -INF and h10 > -INF and h01 > -INF and h11 > -INF:
			var tx: float = fx - float(ix)
			var tz: float = fz - float(jz)
			return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
	return _span(grid, x, z).y

## Sole points (seat frame, offset by off) standing over seat parts higher than rest_l that reach below them.
static func _count_blocked(grid: Dictionary, loc: PackedVector3Array, off: Vector3, rest_l: float) -> int:
	var n: int = 0
	for l: Vector3 in loc:
		var q: Vector3 = l + off
		var col: Vector2 = _span(grid, q.x, q.z)
		if col.y > rest_l and col.x < q.y:
			n += 1
	return n

## The seat asset's column span (lowest / highest surface) on a SEAT_CELL_M grid in the holder's local frame,
## built once per mesh and cached (seat assets are low poly; a few ms the first time, then lookups only).
static func _seat_grid(holder: Node3D) -> Dictionary:
	var src: Dictionary = _seat_grid_source(holder)
	if src.has("grid"):
		return src.grid
	var grid: Dictionary = _seat_grid_build(src)
	_seat_grid_cache[src.key] = grid
	return grid

## Main thread: the cached grid of the holder's meshes ({key, grid}), or what building it needs, copied ({key, parts:
## [mesh-in-holder transform, surface vertex arrays, surface index arrays]}).
static func _seat_grid_source(holder: Node3D) -> Dictionary:
	var meshes: Array[MeshInstance3D] = []
	var key: String = ""
	for n: Node in holder.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = n as MeshInstance3D
		if mi.mesh != null:
			meshes.append(mi)
			key += str(mi.mesh.get_rid().get_id()) + ";"
	if _seat_grid_cache.has(key):
		return {"key": key, "grid": _seat_grid_cache[key]}
	var to_local: Transform3D = holder.global_transform.affine_inverse()
	var parts: Array = []
	for mi2: MeshInstance3D in meshes:
		var xf: Transform3D = to_local * mi2.global_transform
		var surfaces: Array = []
		for si: int in mi2.mesh.get_surface_count():
			var arrays: Array = mi2.mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			surfaces.append([verts, idx])
		parts.append([xf, surfaces])
	return {"key": key, "parts": parts}

## The seat grid from _seat_grid_source() data (pure data, thread-safe).
static func _seat_grid_build(src: Dictionary) -> Dictionary:
	var tris: PackedVector3Array = PackedVector3Array()
	var box: AABB = AABB()
	for pv: Variant in src.parts as Array:
		var part: Array = pv
		var xf: Transform3D = part[0]
		for sv: Variant in part[1] as Array:
			var surf: Array = sv
			var verts: PackedVector3Array = surf[0]
			var idx: PackedInt32Array = surf[1]
			var count: int = idx.size() if not idx.is_empty() else verts.size()
			for k: int in count:
				var v: Vector3 = xf * verts[idx[k] if not idx.is_empty() else k]
				box = AABB(v, Vector3.ZERO) if tris.is_empty() else box.expand(v)
				tris.append(v)
	var cell: float = SEAT_CELL_M
	var nx: int = maxi(1, int(ceil(box.size.x / cell)) + 1)
	var nz: int = maxi(1, int(ceil(box.size.z / cell)) + 1)
	var lo: PackedFloat32Array = PackedFloat32Array()
	var hi: PackedFloat32Array = PackedFloat32Array()
	lo.resize(nx * nz)
	hi.resize(nx * nz)
	lo.fill(INF)
	hi.fill(-INF)
	var i: int = 0
	while i + 2 < tris.size():
		var a: Vector3 = tris[i]
		var b: Vector3 = tris[i + 1]
		var c: Vector3 = tris[i + 2]
		i += 3
		var den: float = (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
		if absf(den) < 1e-10:
			continue
		var i0: int = clampi(int(ceil((minf(a.x, minf(b.x, c.x)) - box.position.x) / cell)), 0, nx - 1)
		var i1: int = clampi(int(floor((maxf(a.x, maxf(b.x, c.x)) - box.position.x) / cell)), 0, nx - 1)
		var j0: int = clampi(int(ceil((minf(a.z, minf(b.z, c.z)) - box.position.z) / cell)), 0, nz - 1)
		var j1: int = clampi(int(floor((maxf(a.z, maxf(b.z, c.z)) - box.position.z) / cell)), 0, nz - 1)
		for jz: int in range(j0, j1 + 1):
			var z: float = box.position.z + float(jz) * cell
			for ix: int in range(i0, i1 + 1):
				var x: float = box.position.x + float(ix) * cell
				var u: float = ((x - a.x) * (c.z - a.z) - (c.x - a.x) * (z - a.z)) / den
				var v2: float = ((b.x - a.x) * (z - a.z) - (x - a.x) * (b.z - a.z)) / den
				if u < -1e-6 or v2 < -1e-6 or u + v2 > 1.0 + 1e-6:
					continue
				var y: float = a.y + (b.y - a.y) * u + (c.y - a.y) * v2
				var id: int = jz * nx + ix
				lo[id] = minf(lo[id], y)
				hi[id] = maxf(hi[id], y)
	return {"origin": box.position, "cell": cell, "nx": nx, "nz": nz, "lo": lo, "hi": hi, "triangles": tris.size() / 3}

## Seat column span (lowest / highest surface, seat frame) at seat-frame (x, z): conservative over the 2 x 2 grid
## cells around the point (highest top, lowest bottom); (-INF, -INF) outside the seat.
static func _span(grid: Dictionary, x: float, z: float) -> Vector2:
	var o: Vector3 = grid.origin
	var cell: float = grid.cell
	var nx: int = grid.nx
	var nz: int = grid.nz
	var fx: int = int(floor((x - o.x) / cell))
	var fz: int = int(floor((z - o.z) / cell))
	var lo_a: PackedFloat32Array = grid.lo
	var hi_a: PackedFloat32Array = grid.hi
	var lo: float = INF
	var hi: float = -INF
	for jz: int in range(fz, fz + 2):
		if jz < 0 or jz >= nz:
			continue
		for ix: int in range(fx, fx + 2):
			if ix < 0 or ix >= nx:
				continue
			var id: int = jz * nx + ix
			if hi_a[id] > hi:
				hi = hi_a[id]
			if lo_a[id] < lo:
				lo = lo_a[id]
	if hi == -INF:
		return Vector2(-INF, -INF)
	return Vector2(lo, hi)

## Min over his sole points (lowest reach over the idle) of their height above the ground function.
func _sole_gap(rig: Rig, height_fn: Callable) -> float:
	var xf: Transform3D = rig.character.global_transform
	var gap: float = INF
	for p: Vector3 in rig.sole_points:
		var w: Vector3 = xf * p
		gap = minf(gap, w.y - float(height_fn.call(w.x, w.z)))
	return gap

## Body geometry for the camera rule (tile bounds), fixed per rig.
func bounds_geometry() -> Mesh:
	if active == null:
		return null
	return active.bounds_geometry

## After a placement: hide L叔 for one frame and show him again. Godot 4.7.1 does not draw his rim next_pass
## (nor some of the fire light on his seated body) until his mesh instances are re-added once; the approved
## probe got exactly this from its findability measurement, which hid and re-showed him during warm-up.
## Measured on the seated night showcase: without it the port differs from the probe by 0.0148/255, with it 0.0041/255.
func refresh_after_place() -> void:
	var rig: Rig = active
	if rig == null:
		return
	rig.character.visible = false
	await get_tree().process_frame
	if is_instance_valid(rig) and rig.character != null:
		rig.character.visible = true

## Posed body geometry of the active rig (projection evidence).
func posed_geometry() -> Mesh:
	if active == null or active.character_body == null:
		return null
	return active.character_body.bake_mesh_from_current_skeleton_pose() if active.character_body.skin != null else active.character_body.mesh

## Step 2 (after the camera fit): facing clamp, contact shadow, fill, cup, ground check. plan_only: the scene plans a
## staged tile (restore_placement() follows): nothing is added to the tile (no cup steam emitter).
func finish(camera: Camera3D, tile: Node3D, terrain_height: Callable, plan_only: bool = false) -> void:
	tile_node = tile
	var rig: Rig = active
	if rig == null:
		return
	report = {"rim_surfaces": rig.get_meta("rim_surfaces", 0), "notes": rig.notes}
	if not seat_fit.is_empty():
		report["seat_fit"] = seat_fit
	var character: Node3D = rig.character
	var c: Dictionary = tile_data.get("character", {})
	var to_cam: Vector3 = camera.global_position - character.global_position
	var cam_yaw: float = atan2(to_cam.x, to_cam.z)
	var max_deg: float = float(_g(["character", "face_camera_max_deg"], 180.0))
	var diff: float = wrapf(character.rotation.y - cam_yaw, -PI, PI)
	var clamped: float = clampf(diff, -deg_to_rad(max_deg), deg_to_rad(max_deg))
	if rig.pose != "seated" and absf(clamped - diff) > 0.0001:
		# seated: the seat anchor is placed in the rotated frame; do not re-rotate a seated actor
		character.rotation.y = cam_yaw + clamped
	report["facing"] = {"web_yaw_to_camera_deg": rad_to_deg(diff), "applied_yaw_to_camera_deg": rad_to_deg(wrapf(character.rotation.y - cam_yaw, -PI, PI)), "max_deg": max_deg}
	var height_scale: float = height_m / 1.15
	if rig.contact_decal != null:
		var ground_y: float = float(c.get("ground_y", character.global_position.y))
		var p: Vector3 = character.global_position
		var foot_center: Vector3 = Vector3(p.x, ground_y, p.z)
		if rig.pose == "seated":
			# seat footprint + feet: centre slightly toward where the feet land (actor forward)
			var fwd: Vector3 = character.global_basis.z.normalized()
			var cp: Array = c.get("position", [0, 0, 0])
			foot_center = Vector3(float(cp[0]), ground_y, float(cp[2])) + Vector3(fwd.x, 0.0, fwd.z) * 0.12 * height_scale
			foot_center += Vector3(fwd.x, 0.0, fwd.z).normalized() * float(seat_fit.get("slide_m", 0.0))   # fix #1 slide
			var side_v: Vector3 = character.global_basis.x
			foot_center += Vector3(side_v.x, 0.0, side_v.z).normalized() * float(seat_fit.get("lateral_m", 0.0))   # fix #1 step 1b
		var box_h: float = float(_g(["character", "contact", "height_m"], 0.5))
		rig.contact_decal.position = foot_center + Vector3(0.0, box_h * 0.3, 0.0)
		report["contact"] = {"radius_m": rig.contact_decal.size.x * 0.5, "center": [foot_center.x, foot_center.y, foot_center.z]}
	var cam_dir: Vector3 = camera.global_position - character.global_position
	cam_dir.y = 0.0
	rig.fill.position = character.global_position + cam_dir.normalized() * height_m * 0.7 + Vector3(0.0, height_m * 0.9, 0.0)
	# steam over the cup (off in the approved look) lives with the tile's other puffs
	steam_emitter = {}
	if not plan_only and rig.cup != null and bool(_g(["character", "cup", "steam"], true)):
		var life: Node3D = tile.get("life")
		if life != null:
			steam_emitter = life.call("make_emitter", "steam", Vector3.ZERO, 1.0, life, char_layer)
	_update_cup(rig)
	_ground_check(rig, terrain_height)

## Feet vs ground: toe-end / foot bones of the live skeleton vs terrain. Bone joints sit inside the shoe,
## so bone_sole_gap_m subtracts a sole allowance scaled by the character height. Seated: sole_gap_m is the
## skinned sole points' lowest reach over the idle (fix #1), otherwise the bone estimate.
func _ground_check(rig: Rig, terrain_height: Callable) -> void:
	var sk: Skeleton3D = null
	for node: Node in rig.character.find_children("*", "Skeleton3D", true, false):
		var cand: Skeleton3D = node as Skeleton3D
		if cand.is_visible_in_tree():
			sk = cand
	if sk == null:
		return
	var out: Dictionary = {}
	var worst: float = INF
	var hscale: float = height_m / 1.15
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
			var terrain: float = float(terrain_height.call(w.x, w.z))
			out[side + part] = {"world": [w.x, w.y, w.z], "above_terrain_m": w.y - terrain}
			if part == "ToeBase":
				worst = minf(worst, w.y - terrain)
	out["toe_base_min_above_terrain_m"] = worst
	out["bone_sole_gap_m"] = worst - 0.035 * hscale
	out["sole_gap_m"] = worst - 0.035 * hscale
	out["sole_gap_source"] = "toe-base bone - sole allowance"
	if not rig.sole_points.is_empty():
		out["sole_gap_vs_terrain_m"] = _sole_gap(rig, terrain_height)
		out["sole_gap_m"] = float(seat_fit.get("sole_gap_after_m", out.sole_gap_vs_terrain_m))
		out["sole_gap_source"] = "skinned sole points (lowest over the seated idle) vs terrain or the seat's own lower parts"
	report["ground_check"] = out

func _update_cup(rig: Rig) -> void:
	if rig.cup == null or rig.cup_skeleton == null:
		return
	var rh: Vector3 = rig.cup_skeleton.to_global(rig.cup_skeleton.get_bone_global_pose(rig.cup_bones[0]).origin)
	var rm: Vector3 = rig.cup_skeleton.to_global(rig.cup_skeleton.get_bone_global_pose(rig.cup_bones[1]).origin)
	var lh: Vector3 = rig.cup_skeleton.to_global(rig.cup_skeleton.get_bone_global_pose(rig.cup_bones[2]).origin)
	var lm: Vector3 = rig.cup_skeleton.to_global(rig.cup_skeleton.get_bone_global_pose(rig.cup_bones[3]).origin)
	var rpalm: Vector3 = rh.lerp(rm, 0.55)
	var lpalm: Vector3 = lh.lerp(lm, 0.55)
	var mode: String = str(_g(["character", "cup", "hold"], "both"))
	var hscale: float = height_m / 1.15
	var p: Vector3 = rpalm if mode == "right" else (rpalm + lpalm) * 0.5
	p += _v3(_g(["character", "cup", "offset_m"], [0.0, -0.02, 0.0]), Vector3(0, -0.02, 0)) * hscale
	rig.cup.global_position = p
	rig.cup.global_basis = Basis.IDENTITY
	if not steam_emitter.is_empty():
		steam_emitter["base"] = p + Vector3(0.0, float(_g(["character", "cup", "height_m"], 0.07)) * hscale * 0.5, 0.0)
	report["cup_hands"] = {"right_palm": [rpalm.x, rpalm.y, rpalm.z], "left_palm": [lpalm.x, lpalm.y, lpalm.z], "hand_gap_m": rpalm.distance_to(lpalm)}

# ------------------------------------------------------------------ per light / per frame
func on_light(sun: DirectionalLight3D, camp_fire_keys: Array[Vector3]) -> void:
	var rig: Rig = active
	if rig == null:
		return
	if rig.rim_material != null:
		# Continuous light (look.blend non-empty): the rim is resolved for each of the two presets with its own rules
		# (sun colour / local fire-lamp key) and the results are mixed, so neither the "sun" colour switch nor the
		# local-key radius makes a step during a blend; an exact preset uses exactly the single-preset result.
		var bl: Dictionary = look.get("blend")
		var st: Dictionary
		if bl.is_empty():
			st = _rim_state(_life(), sun.light_color, sun.global_basis.z.normalized(), camp_fire_keys, rig)   # key points toward the light
		else:
			var ca: Dictionary = bl.cfg_a
			var cb: Dictionary = bl.cfg_b
			var sa: Dictionary = _rim_state(ca.get("life", {}), _col((ca.get("sun", {}) as Dictionary).get("color", "#ffffff"), Color.WHITE),
				_v3((ca.get("sun", {}) as Dictionary).get("position", [-8, 13, 7]), Vector3(-8, 13, 7)).normalized(), camp_fire_keys, rig)
			var sb: Dictionary = _rim_state(cb.get("life", {}), _col((cb.get("sun", {}) as Dictionary).get("color", "#ffffff"), Color.WHITE),
				_v3((cb.get("sun", {}) as Dictionary).get("position", [-8, 13, 7]), Vector3(-8, 13, 7)).normalized(), camp_fire_keys, rig)
			st = _mix_rim(sa, sb, float(bl.t))
		rig.rim_material.set_shader_parameter("rim_color", st.color)
		rig.rim_material.set_shader_parameter("rim_strength", st.strength)
		rig.rim_material.set_shader_parameter("rim_power", st.power)
		rig.rim_material.set_shader_parameter("key_bias", st.key_bias)
		rig.rim_material.set_shader_parameter("top_bias", st.top_bias)
		var key: Vector3 = st.key
		rig.rim_material.set_shader_parameter("key_dir_world", key)
		report["rim_key"] = {"source": st.source, "dir": [key.x, key.y, key.z]}
	_on_light_rest(rig)

## Rim of one light preset (life = that preset's look "life" section): colour, strengths and the key direction
## (the sun, or the nearest camp fire / lamp within rim.local_key_radius_m of his chest).
func _rim_state(life: Dictionary, sun_color: Color, to_sun: Vector3, camp_fire_keys: Array[Vector3], rig: Rig) -> Dictionary:
	var rc: Variant = _gl(life, ["character", "rim", "color"], "sun")
	var rim_col: Color
	if str(rc) == "sun":
		var tint: Color = _col(_gl(life, ["character", "rim", "tint"], "#ffffff"), Color.WHITE)
		rim_col = Color(sun_color.r * tint.r, sun_color.g * tint.g, sun_color.b * tint.b)
	else:
		rim_col = _col(rc, Color.WHITE)
	var key: Vector3 = to_sun
	var key_src: String = "sun"
	var local_r: float = float(_gl(life, ["character", "rim", "local_key_radius_m"], 0.0))
	if local_r > 0.0:
		var best: float = local_r
		var chest: Vector3 = rig.character.global_position + Vector3(0.0, height_m * 0.5, 0.0)
		var cands: Array[Vector3] = camp_fire_keys.duplicate()
		for lp: Variant in tile_data.get("lamps", []):
			cands.append(_v3(lp, Vector3.ZERO))
		for cpos: Vector3 in cands:
			var dist: float = cpos.distance_to(chest)
			if dist < best:
				best = dist
				key = (cpos - chest).normalized()
				key_src = "local"
		if key_src == "local":
			rim_col = _col(_gl(life, ["character", "rim", "local_key_color"], "#ffa060"), Color(1.0, 0.63, 0.38))
	return {"color": rim_col, "strength": float(_gl(life, ["character", "rim", "strength"], 0.3)),
		"power": float(_gl(life, ["character", "rim", "power"], 3.0)), "key_bias": float(_gl(life, ["character", "rim", "key_bias"], 0.6)),
		"top_bias": float(_gl(life, ["character", "rim", "top_bias"], 0.25)), "key": key, "source": key_src}

static func _mix_rim(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var key: Vector3 = (a.key as Vector3).lerp(b.key as Vector3, t)
	key = key.normalized() if key.length() > 0.0001 else (b.key as Vector3 if t >= 0.5 else a.key as Vector3)
	return {"color": (a.color as Color).lerp(b.color as Color, t), "strength": lerpf(float(a.strength), float(b.strength), t),
		"power": lerpf(float(a.power), float(b.power), t), "key_bias": lerpf(float(a.key_bias), float(b.key_bias), t),
		"top_bias": lerpf(float(a.top_bias), float(b.top_bias), t), "key": key,
		"source": str(a.source) if str(a.source) == str(b.source) else "%s>%s" % [a.source, b.source]}

static func _gl(life: Dictionary, path: Array, fallback: Variant) -> Variant:
	var d: Variant = life
	for k: Variant in path:
		if not d is Dictionary or not (d as Dictionary).has(k):
			return fallback
		d = (d as Dictionary)[k]
	return d

func _on_light_rest(rig: Rig) -> void:
	var fe: float = float(_g(["character", "fill", "energy"], 0.0))
	rig.fill.visible = fe > 0.0
	rig.fill.light_energy = fe
	rig.fill.light_color = _col(_g(["character", "fill", "color"], "#ffe8cc"), Color(1.0, 0.91, 0.8))
	if rig.contact_decal != null:
		rig.contact_decal.modulate = Color(1, 1, 1, float(_g(["character", "contact", "strength"], 0.5)))

## Actor motion hook (lshu_actor_motion.gd sets it): called at the end of tick() with the same clock, so walking,
## bowing and blend poses land after the pose modules sampled their idles, whatever order the scene ticks in.
var motion_hook: Callable = Callable()

func tick(t: float, _frozen: bool) -> void:
	_tick_pose(t)
	if motion_hook.is_valid():
		motion_hook.call(t)

func _tick_pose(t: float) -> void:
	var rig: Rig = active
	if rig == null:
		return
	var ch: Dictionary = (look.get("cfg") as Dictionary).get("character", {})
	if rig.player != null and rig.anim_length > 0.0 and rig.carrying_pose == null:
		rig.player.seek(fposmod(t + float(ch.get("idle_offset_s", 0.0)), rig.anim_length), true)
	if rig.seated_actor != null:
		rig.seated_actor.call("set_time", t)
	if rig.carrying_pose != null:
		rig.carrying_pose.call("set_time", t)
	if rig.cup != null:
		_update_cup(rig)
	if rig.flowers != null:
		rig.flowers.call("set_story_time", float(_g(["character", "flowers", "growth_s"], 5.5)), t)

func evidence(camera: Camera3D) -> Dictionary:
	var rig: Rig = active
	if rig == null:
		return {}
	var proj: Dictionary = {}
	var posed: Mesh = posed_geometry()
	if posed != null:
		proj = CAMERA.projected_bounds(camera, rig.character_body, posed)
	var c: Dictionary = tile_data.get("character", {})
	var out: Dictionary = {"pose": rig.pose, "action": c.get("action"), "kit": c.get("kit"), "height_m": height_m,
		"world_position": [rig.character.global_position.x, rig.character.global_position.y, rig.character.global_position.z],
		"projection": proj,
		"seated": rig.seated_actor.call("evidence") if rig.seated_actor != null else null,
		"carrying": rig.carrying_pose.call("evidence") if rig.carrying_pose != null else null,
		"life": report}
	return out
