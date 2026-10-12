extends Node3D
## L叔在哪儿 · act-4 tile probe viewer (director probe infrastructure, not delivery code).
##
## Assembles one baked tile (baked/<ID>.json + baked/<ID>_proc.glb + glb/<asset>.glb) with ONE global
## pipeline: shared surface shader per role, light presets, backdrop, camera rule, real L叔 from the other
## acts. Nothing here is per tile; every number comes from the variant JSON (variants/<name>.json).
##
## Args (after --):
##   --recipe=<ID>        baked tile id (D01..D12 or a composition id such as J721)
##   --light=<morning|day|sunset|night>   default: the tile's baked light
##   --variant=<name>     variants/<name>.json (default baseline); "base" inheritance, see README_PROBE.md
##   --capture=<png>      warm up 120 frames, time 180 frames, save PNG + JSON, quit
##   --park=<slot>        shrink + park the window at a distinct screen slot (parallel runs)
##   --motion-freeze      hold all motion at motion.freeze_time_s
## Keys (interactive): L = next light, F = toggle motion freeze.

const PROBE_DIR := "res://tools/traveler/lookdev_lshu/"
const LIGHTS: Array[String] = ["morning", "day", "sunset", "night"]
const ACTION2_SCENE := "res://scenes/traveler/action2_character.tscn"
const STYLE_SCRIPT := "res://scripts/traveler/character_style.gd"
const SEATED_ASSET := "res://assets/traveler/panti/camp/character/sitting-animated.glb"
const SEATED_ACTOR_SCRIPT := "res://scripts/traveler/panti/panti_seated_actor.gd"
const SEATED_STYLE_SCRIPT := "res://scripts/traveler/panti/panti_seated_style.gd"
const CARRYING_SCRIPT := "res://scripts/traveler/baghdad/baghdad_carrying_pose.gd"
const BAGHDAD_CHARACTER_HEIGHT := 0.6375
## The shadow-catcher floor lives on its own render layer: shadow_to_opacity takes min(1 - attenuation) over
## every light that reaches it, so unshadowed lights (fill, fires, lamps) must not see the floor.
const FLOOR_LAYER := 1 << 19

var recipe_id: String = "D05"
var light_name: String = ""
var variant_name: String = "baseline"
var capture_path: String = ""
var park_slot: int = -1
var motion_frozen: bool = false

var tile: Dictionary = {}
var variant: Dictionary = {}
var cfg: Dictionary = {}
var world: Node3D
var tile_root: Node3D
var proc_root: Node3D
var instances_root: Node3D
var fx_root: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var fill: DirectionalLight3D
var environment: Environment
var world_env: WorldEnvironment
var camera_attributes: CameraAttributesPractical
var sky_material: ShaderMaterial
var floor_node: MeshInstance3D
var floor_material: ShaderMaterial
var materials: Dictionary = {}
var shader_cache: Dictionary = {}
var uniform_types: Dictionary = {}
var asset_cache: Dictionary = {}
var instance_nodes: Array[Dictionary] = []
var proc_nodes: Dictionary = {}
var fire_lights: Array[OmniLight3D] = []
var lamp_lights: Array[OmniLight3D] = []
var flames: Array[Dictionary] = []
var rotors: Array[Dictionary] = []
var bobbers: Array[Dictionary] = []
var sway_nodes: Array[MeshInstance3D] = []
var tick_callbacks: Array[Callable] = []
var light_callbacks: Array[Callable] = []
var report_extra: Dictionary = {}
var extra_results: Array = []
var extra_modules: Array = []
var notes: Array[String] = []
var height_texture: ImageTexture
var height_grid: Array = []
var terrain_n: int = 52
var terrain_step: float = 8.0 / 52.0
var tile_bounds: AABB
var camera_fit: Dictionary = {}
var backdrop_display: Color = Color.WHITE
var character: Node3D
var character_model: Node3D
var character_body: MeshInstance3D
var character_geometry: Mesh
var character_style: RefCounted
var character_pose: String = ""
var character_player: AnimationPlayer
var character_anim: StringName = &""
var character_anim_length: float = 0.0
var character_height_m: float = 1.15
var seated_actor: RefCounted
var carrying_pose: Node3D
var anim_t: float = 0.0

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--recipe="): recipe_id = arg.trim_prefix("--recipe=")
		elif arg.begins_with("--light="): light_name = arg.trim_prefix("--light=")
		elif arg.begins_with("--variant="): variant_name = arg.trim_prefix("--variant=")
		elif arg.begins_with("--capture="): capture_path = arg.trim_prefix("--capture=")
		elif arg.begins_with("--park="): park_slot = int(arg.trim_prefix("--park="))
		elif arg == "--motion-freeze": motion_frozen = true
	# The capture harness grabs the camera right after instantiation: create it before any await.
	camera = Camera3D.new()
	camera.name = "TileCamera"
	add_child(camera)
	camera.make_current()
	if park_slot >= 0:
		_park(park_slot)
	var tile_path: String = PROBE_DIR + "baked/%s.json" % recipe_id
	if not FileAccess.file_exists(tile_path):
		push_error("LSHU baked tile missing: " + tile_path)
		get_tree().quit(1)
		return
	tile = JSON.parse_string(FileAccess.get_file_as_string(tile_path))
	if light_name.is_empty():
		light_name = str(tile.get("light", "day"))
	if not LIGHTS.has(light_name):
		push_error("LSHU unknown light preset: " + light_name)
		get_tree().quit(1)
		return
	variant = _load_variant(variant_name, 0)
	cfg = _effective_config(light_name)
	world = Node3D.new(); world.name = "LshuWorld"; add_child(world)
	tile_root = Node3D.new(); tile_root.name = "Tile"; world.add_child(tile_root)
	proc_root = Node3D.new(); proc_root.name = "Procedural"; tile_root.add_child(proc_root)
	instances_root = Node3D.new(); instances_root.name = "Instances"; tile_root.add_child(instances_root)
	fx_root = Node3D.new(); fx_root.name = "Effects"; world.add_child(fx_root)
	_build_height_field()
	_build_environment()
	_build_lights()
	_build_proc()
	_build_instances()
	_build_effects()
	await _build_character()
	_build_floor()
	_compute_bounds()
	_fit_camera()
	_apply_light_config()
	_run_extra_scripts()
	if motion_frozen:
		anim_t = float(_cfgv("motion", "freeze_time_s", 2.5))
	_apply_motion(anim_t, 0.0)
	print("LSHU_READY ", JSON.stringify({"recipe": recipe_id, "light": light_name, "variant": variant_name, "pose": character_pose, "instances": instance_nodes.size(), "proc_roles": proc_nodes.keys(), "roles": materials.keys(), "camera": camera_fit, "extra_scripts": extra_results.size()}))
	if not capture_path.is_empty():
		await capture(capture_path)
		get_tree().quit()

# ------------------------------------------------------------------ variant / config
func _load_variant(vname: String, depth: int) -> Dictionary:
	var path: String = PROBE_DIR + "variants/%s.json" % vname
	if depth > 8 or not FileAccess.file_exists(path):
		push_error("LSHU variant missing: " + path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_error("LSHU variant is not a JSON object: " + path)
		return {}
	var d: Dictionary = parsed
	if d.has("base"):
		var b: Dictionary = _load_variant(str(d.base), depth + 1)
		var child: Dictionary = d.duplicate(true)
		child.erase("base")
		var scripts: Array = []
		if not bool(child.get("extra_scripts_replace", false)):
			scripts.append_array(b.get("extra_scripts", []))
		scripts.append_array(child.get("extra_scripts", []))
		child.erase("extra_scripts")
		var merged: Dictionary = _merge(b, child)
		merged["extra_scripts"] = scripts
		merged["name"] = vname
		return merged
	d["name"] = vname
	return d

func _merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = a.duplicate(true)
	for k: Variant in b.keys():
		if out.has(k) and out[k] is Dictionary and b[k] is Dictionary:
			out[k] = _merge(out[k], b[k])
		else:
			out[k] = b[k].duplicate(true) if (b[k] is Dictionary or b[k] is Array) else b[k]
	return out

func _effective_config(light: String) -> Dictionary:
	var common: Dictionary = variant.get("common", {})
	var lights: Dictionary = variant.get("lights", {})
	return _merge(common, lights.get(light, {}))

func _cfgv(section: String, key: String, fallback: Variant) -> Variant:
	var s: Dictionary = cfg.get(section, {})
	return s.get(key, fallback)

func _sec(section: String) -> Dictionary:
	return cfg.get(section, {})

static func col(v: Variant, fallback: Color = Color.WHITE) -> Color:
	if v is String:
		return Color.html(str(v))
	if v is Array:
		var a: Array = v
		if a.size() >= 3:
			return Color(float(a[0]), float(a[1]), float(a[2]), float(a[3]) if a.size() > 3 else 1.0)
	if v is Color:
		return v
	return fallback

static func vec3(v: Variant, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback

## Kept for modules copied from the Baghdad stack (prop placer): tile coordinates ARE world coordinates.
func stage_point(a: Vector3) -> Vector3:
	return a

# ------------------------------------------------------------------ terrain height field
func _build_height_field() -> void:
	var terrain: Dictionary = tile.get("terrain", {})
	height_grid = terrain.get("heights", [])
	terrain_n = int(terrain.get("N", 52))
	terrain_step = float(terrain.get("step", 8.0 / 52.0))
	var size: int = terrain_n + 1
	var img: Image = Image.create(size, size, false, Image.FORMAT_RF)
	for j: int in size:
		var row: Array = height_grid[j]
		for i: int in size:
			img.set_pixel(i, j, Color(float(row[i]), 0.0, 0.0))
	height_texture = ImageTexture.create_from_image(img)

## Same barycentric interpolation (same diagonals) as the web planner's height().
func terrain_height(x: float, z: float) -> float:
	if height_grid.is_empty():
		return 0.0
	x = clampf(x, -4.0, 4.0)
	z = clampf(z, -4.0, 4.0)
	var ix: int = mini(terrain_n - 1, int(floor((x + 4.0) / terrain_step)))
	var iz: int = mini(terrain_n - 1, int(floor((z + 4.0) / terrain_step)))
	var u: float = (x + 4.0) / terrain_step - ix
	var w: float = (z + 4.0) / terrain_step - iz
	var a: float = float(height_grid[iz][ix])
	var b: float = float(height_grid[iz][ix + 1])
	var c: float = float(height_grid[iz + 1][ix + 1])
	var d: float = float(height_grid[iz + 1][ix])
	if u + w <= 1.0:
		return a + (b - a) * u + (d - a) * w
	return b * (1.0 - w) + d * (1.0 - u) + c * (u + w - 1.0)

# ------------------------------------------------------------------ materials (one per role, shared by all tiles)
func _shader(path: String) -> Shader:
	if not shader_cache.has(path):
		var s: Shader = load(path) as Shader
		if s == null:
			push_error("LSHU shader missing: " + path)
			s = load(PROBE_DIR + "shaders/lshu_surface.gdshader") as Shader
		shader_cache[path] = s
		var types: Dictionary = {}
		for u: Dictionary in s.get_shader_uniform_list():
			types[str(u.name)] = int(u.type)
		uniform_types[path] = types
	return shader_cache[path]

## Role key for an asset surface: glow / water / metal keep their role; matte maps by asset group.
func asset_role(surface_role: String, group: String) -> String:
	if surface_role != "matte":
		return surface_role
	var group_roles: Dictionary = _cfgv("surface", "group_roles", {})
	return str(group_roles.get(group, "matte"))

func role_material(role: String) -> ShaderMaterial:
	if materials.has(role):
		return materials[role]
	var surf: Dictionary = _sec("surface")
	var roles: Dictionary = surf.get("roles", {})
	var rcfg: Dictionary = roles.get(role, {})
	var overlay_roles: Array = surf.get("overlay_roles", ["ripple"])
	var path: String = str(rcfg.get("shader", surf.get("overlay_shader", PROBE_DIR + "shaders/lshu_overlay.gdshader") if overlay_roles.has(role) else surf.get("shader", PROBE_DIR + "shaders/lshu_surface.gdshader")))
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = _shader(path)
	m.resource_name = "lshu_role_" + role
	m.set_meta("shader_path", path)
	m.set_meta("role", role)
	materials[role] = m
	_bind_role_uniforms(role)
	return m

func _bind_role_uniforms(role: String) -> void:
	var m: ShaderMaterial = materials[role]
	var path: String = str(m.get_meta("shader_path"))
	var types: Dictionary = uniform_types.get(path, {})
	var surf: Dictionary = _sec("surface")
	var common: Dictionary = surf.get("uniforms", {})
	var roles: Dictionary = surf.get("roles", {})
	var rcfg: Dictionary = roles.get(role, {})
	for k: String in common.keys():
		if types.has(k):
			m.set_shader_parameter(k, _uniform_value(common[k], int(types[k])))
	for k: String in rcfg.keys():
		if k == "shader":
			continue
		if types.has(k):
			m.set_shader_parameter(k, _uniform_value(rcfg[k], int(types[k])))
		else:
			push_warning("LSHU role %s: uniform %s not in %s" % [role, k, path.get_file()])
	if types.has("height_tex"): m.set_shader_parameter("height_tex", height_texture)
	if types.has("height_rect"): m.set_shader_parameter("height_rect", Vector4(-4.0, -4.0, 8.0, 8.0))
	if types.has("height_grid_n"): m.set_shader_parameter("height_grid_n", float(terrain_n + 1))

func _uniform_value(v: Variant, t: int) -> Variant:
	match t:
		TYPE_COLOR: return col(v)
		TYPE_VECTOR3: return vec3(v)
		TYPE_VECTOR2: return Vector2(float(v[0]), float(v[1]))
		TYPE_VECTOR4: return Vector4(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
		TYPE_FLOAT: return float(v)
		TYPE_INT: return int(v)
		TYPE_BOOL: return bool(v)
	return v

## For modules: set one uniform on a role material (creates the role if needed).
func set_role_uniform(role: String, uniform: String, value: Variant) -> void:
	var m: ShaderMaterial = role_material(role)
	var types: Dictionary = uniform_types.get(str(m.get_meta("shader_path")), {})
	m.set_shader_parameter(uniform, _uniform_value(value, int(types.get(uniform, typeof(value)))))

func _assign_surfaces(mi: MeshInstance3D, group: String, is_asset: bool) -> void:
	var no_shadow: Array = _cfgv("surface", "no_shadow_roles", ["water", "foam", "ripple"])
	var casts: bool = true
	for i: int in mi.mesh.get_surface_count():
		var src: Material = mi.mesh.surface_get_material(i)
		var sname: String = src.resource_name if src != null else "lshu_matte"
		var base_role: String = sname.trim_prefix("lshu_") if sname.begins_with("lshu_") else "matte"
		var role: String = asset_role(base_role, group) if is_asset else base_role
		mi.set_surface_override_material(i, role_material(role))
		if no_shadow.has(role) and mi.mesh.get_surface_count() == 1:
			casts = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# ------------------------------------------------------------------ geometry
func _build_proc() -> void:
	var proc: Dictionary = tile.get("proc", {})
	var path: String = PROBE_DIR + "baked/" + str(proc.get("file", recipe_id + "_proc.glb"))
	var doc: GLTFDocument = GLTFDocument.new()
	var state: GLTFState = GLTFState.new()
	var err: int = doc.append_from_file(path, state)
	if err != OK:
		push_error("LSHU cannot read procedural GLB %s (%d)" % [path, err])
		return
	var scene: Node = doc.generate_scene(state)
	proc_root.add_child(scene)
	for node: Node in scene.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node as MeshInstance3D
		_assign_surfaces(mi, "", false)
		proc_nodes[str(mi.name).trim_prefix("proc_")] = mi

func _asset_scene(id: String) -> PackedScene:
	if not asset_cache.has(id):
		asset_cache[id] = load(PROBE_DIR + "glb/%s.glb" % id) as PackedScene
		if asset_cache[id] == null:
			push_error("LSHU asset GLB missing or not imported: " + id)
	return asset_cache[id]

func _build_instances() -> void:
	var motion: Dictionary = _sec("motion")
	var index: int = 0
	for data: Dictionary in tile.get("instances", []):
		var id: String = str(data.asset_id)
		var packed: PackedScene = _asset_scene(id)
		if packed == null:
			continue
		var holder: Node3D = Node3D.new()
		holder.name = "%s_%02d" % [id, index]
		holder.position = vec3(data.position)
		holder.rotation.y = float(data.get("yaw", 0.0))
		holder.scale = Vector3.ONE * float(data.get("scale", 1.0))
		instances_root.add_child(holder)
		var inst: Node3D = packed.instantiate() as Node3D
		holder.add_child(inst)
		var group: String = str(data.get("group", ""))
		var meshes: Array[MeshInstance3D] = []
		for node: Node in inst.find_children("*", "MeshInstance3D", true, false):
			var mi: MeshInstance3D = node as MeshInstance3D
			meshes.append(mi)
			_assign_surfaces(mi, group, true)
			if str(data.get("anim", "")) == "sway":
				mi.set_instance_shader_parameter("sway", float(motion.get("sway_scale", 1.0)))
				mi.set_instance_shader_parameter("sway_phase", float(data.get("phase", index * 1.7)))
				sway_nodes.append(mi)
			if str(mi.name).begins_with("rotor_") and mi.has_meta("extras"):
				var ex: Dictionary = mi.get_meta("extras")
				var part: Dictionary = ex.get("lshu", {}).get("runtime_part", {})
				rotors.append({"node": mi, "axis": vec3(part.get("axis", [0, 0, 1]), Vector3.BACK).normalized(), "speed": float(part.get("speed_rad_s", 0.2)), "base": mi.basis})
		var anim: String = str(data.get("anim", ""))
		if anim == "boat" or anim == "bob":
			bobbers.append({"node": holder, "base_y": holder.position.y, "phase": float(data.get("phase", 0.7))})
		instance_nodes.append({"node": holder, "data": data, "meshes": meshes})
		index += 1

func _build_effects() -> void:
	var fires: Dictionary = _sec("fires")
	for f: Dictionary in tile.get("fires", []):
		var center: Vector3 = vec3(f.get("flame_center", f.position))
		var light: OmniLight3D = OmniLight3D.new()
		light.name = "FireLight_%d" % fire_lights.size()
		light.position = center + Vector3(0.0, float(fires.get("light_lift", 0.15)), 0.0)
		fx_root.add_child(light)
		fire_lights.append(light)
		if bool(fires.get("flame", true)):
			_build_flame(vec3(f.position), float(f.get("scale", 0.6)), str(f.get("source", "")) != "camp_kit")
	for p: Variant in tile.get("lamps", []):
		var lamp: OmniLight3D = OmniLight3D.new()
		lamp.name = "LampLight_%d" % lamp_lights.size()
		lamp.position = vec3(p)
		fx_root.add_child(lamp)
		lamp_lights.append(lamp)

## The web draws flames as three emissive icosahedra; same here, with a flicker in _apply_motion.
func _build_flame(pos: Vector3, scale_value: float, effect_point: bool) -> void:
	var colors: Array[Color] = [Color.html("#ed792d"), Color.html("#ffc34c"), Color.html("#fff0a8")]
	var root: Node3D = Node3D.new()
	root.name = "Flame_%d" % flames.size()
	root.position = pos
	fx_root.add_child(root)
	for i: int in 3:
		var m: SphereMesh = SphereMesh.new()
		m.radius = 1.0; m.height = 2.0; m.radial_segments = 6; m.rings = 3
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = colors[i]
		mat.emission_enabled = true
		mat.emission = colors[i]
		m.material = mat
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var s: Vector3
		if effect_point:
			mi.position = Vector3((i - 1) * 0.06, 0.10 + i * 0.035, 0.0) * scale_value / 0.6
			s = Vector3(0.13 - i * 0.022, 0.24 - i * 0.035, 0.10 - i * 0.014) * scale_value / 0.6
		else:
			mi.position = Vector3((i - 1) * 0.07 * scale_value, (0.3 + i * 0.04) * scale_value, 0.0)
			s = Vector3((0.17 - i * 0.026) * scale_value, (0.34 - i * 0.055) * scale_value, (0.14 - i * 0.025) * scale_value)
		mi.scale = s
		root.add_child(mi)
		flames.append({"node": mi, "scale": s, "phase": i * 2.0, "material": mat, "color": colors[i]})

# ------------------------------------------------------------------ character (the real L叔 from acts 1-3)
func _build_character() -> void:
	var c: Dictionary = tile.get("character", {})
	var ch: Dictionary = _sec("character")
	var pose_map: Dictionary = ch.get("pose_map", {"look": "standing", "tea": "seated", "bloom": "carrying"})
	character_pose = str(pose_map.get(str(c.get("action", "look")), "standing"))
	character_height_m = float(ch.get("height_m", 1.15))
	character = Node3D.new()
	character.name = "LshuTraveler"
	world.add_child(character)
	character.position = vec3(c.get("position", [0, 0, 0])) + vec3(ch.get("offset", [0, 0, 0]))
	character.rotation.y = float(c.get("yaw", 0.4)) + deg_to_rad(float(ch.get("yaw_offset_deg", 0.0)))
	if character_pose == "seated":
		_build_seated(c, ch)
		return
	await _build_standing(ch)
	if character_pose == "carrying":
		_build_carrying(ch)

func _build_standing(ch: Dictionary) -> void:
	character_model = (load(ACTION2_SCENE) as PackedScene).instantiate() as Node3D
	character.add_child(character_model)
	character_player = character_model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	character_anim = StringName(str(ch.get("standing_animation", "idle")))
	character_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	character_player.play(character_anim)
	character_anim_length = character_player.get_animation(character_anim).length
	character_player.seek(float(ch.get("idle_offset_s", 0.0)), true)
	character_player.advance(0.0)
	await RenderingServer.frame_post_draw
	character_body = character_model.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	character_geometry = character_body.bake_mesh_from_current_skeleton_pose()
	var bounds: AABB = character_geometry.get_aabb()
	character_model.position = Vector3(-bounds.get_center().x, -bounds.position.y, -bounds.get_center().z)
	character_style = load(STYLE_SCRIPT).new()
	character_style.configure(character_model)
	var mult: float = float(ch.get("outline_multiplier", 1.0))
	for shell: MeshInstance3D in character_style.get("shells"):
		(shell.material_override as StandardMaterial3D).grow_amount *= mult
	character.scale = Vector3.ONE * (character_height_m / maxf(bounds.size.y, 0.001))

func _build_seated(c: Dictionary, ch: Dictionary) -> void:
	character_model = (load(SEATED_ASSET) as PackedScene).instantiate() as Node3D
	character.add_child(character_model)
	seated_actor = load(SEATED_ACTOR_SCRIPT).new()
	seated_actor.configure(character_model, {})
	character_style = load(SEATED_STYLE_SCRIPT).new()
	character_style.configure(character_model, float(ch.get("seated_outline_multiplier", ch.get("outline_multiplier", 1.0))))
	character_body = seated_actor.get("body") as MeshInstance3D
	# Seated asset: standing rest height normalized to 1.0 model units.
	character.scale = Vector3.ONE * character_height_m
	var seat_top: float = float(c.get("seat_top", c.position[1])) if c.get("seat_top") != null else float(c.position[1])
	var seat_world: Vector3 = Vector3(float(c.position[0]), seat_top, float(c.position[2])) + vec3(ch.get("seat_offset", [0, 0, 0]))
	var anchor: Vector3 = seated_actor.get("seat_anchor")
	character.global_position = seat_world - character.global_basis * anchor

func _build_carrying(ch: Dictionary) -> void:
	carrying_pose = load(CARRYING_SCRIPT).new() as Node3D
	carrying_pose.set("turn_right_degrees", float(ch.get("carrying_turn_deg", 0.0)))
	world.add_child(carrying_pose)
	var ok: bool = bool(carrying_pose.call("configure", self))
	if not ok:
		notes.append("carrying pose failed; standing idle kept")
		carrying_pose.queue_free()
		carrying_pose = null
		character_pose = "standing"
		return
	var ratio: float = character_height_m / BAGHDAD_CHARACTER_HEIGHT * float(ch.get("carrying_bundle_scale", 1.0))
	carrying_pose.call("set_bundle_adjustment", carrying_pose.get("bundle_offset_normalized"), ratio)

# ------------------------------------------------------------------ stage: environment, lights, floor
func _build_environment() -> void:
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky: Sky = Sky.new()
	sky_material = ShaderMaterial.new()
	sky_material.shader = load(PROBE_DIR + "shaders/lshu_backdrop.gdshader") as Shader
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	world_env = WorldEnvironment.new()
	world_env.name = "Environment"
	world_env.environment = environment
	add_child(world_env)
	camera_attributes = CameraAttributesPractical.new()
	camera.attributes = camera_attributes

func _build_lights() -> void:
	sun = DirectionalLight3D.new(); sun.name = "Sun"; world.add_child(sun)
	fill = DirectionalLight3D.new(); fill.name = "Fill"; world.add_child(fill)

func _build_floor() -> void:
	floor_node = MeshInstance3D.new()
	floor_node.name = "StageFloor"
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = Vector2.ONE * 400.0
	floor_node.mesh = plane
	floor_material = ShaderMaterial.new()
	floor_material.shader = load(PROBE_DIR + "shaders/lshu_floor.gdshader") as Shader
	floor_node.material_override = floor_material
	floor_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	floor_node.layers = FLOOR_LAYER
	world.add_child(floor_node)
	fill.light_cull_mask = 0xFFFFF & ~FLOOR_LAYER
	for light: OmniLight3D in fire_lights + lamp_lights:
		light.light_cull_mask = 0xFFFFF & ~FLOOR_LAYER

## Everything that depends on the light preset. Re-entrant: set_light() calls it again.
func _apply_light_config() -> void:
	var theme: String = str(tile.get("place", {}).get("theme", "autumn"))
	# sun
	var s: Dictionary = _sec("sun")
	var sun_pos: Vector3 = vec3(s.get("position", [-8, 13, 7]), Vector3(-8, 13, 7))
	sun.transform = Transform3D(Basis.looking_at(-sun_pos.normalized(), Vector3.UP if absf(sun_pos.normalized().y) < 0.99 else Vector3.BACK), Vector3.ZERO)
	sun.light_color = col(s.get("color", "#ffffff"))
	sun.light_energy = float(s.get("energy", 1.7))
	sun.light_indirect_energy = float(s.get("indirect_energy", 1.0))
	sun.light_angular_distance = float(s.get("angular_distance_deg", 0.5))
	sun.shadow_enabled = bool(s.get("shadow", true))
	sun.shadow_bias = float(s.get("shadow_bias", 0.03))
	sun.shadow_normal_bias = float(s.get("shadow_normal_bias", 1.0))
	sun.shadow_blur = float(s.get("shadow_blur", 1.0))
	sun.shadow_opacity = float(s.get("shadow_opacity", 1.0))
	var mode: String = str(s.get("shadow_mode", "parallel_2"))
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if mode == "orthogonal" else (DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if mode == "parallel_4" else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS)
	# Shadow range rule (same for every tile): the far split must reach the stage floor behind the tile;
	# split 1 ("auto") ends just past the tile so the tile itself gets the sharp split.
	var cam_dist: float = float(camera_fit.get("distance", 30.0))
	var tile_radius: float = tile_bounds.size.length() * 0.5 if tile_bounds.size != Vector3.ZERO else 6.5
	sun.directional_shadow_max_distance = cam_dist + tile_radius + float(s.get("shadow_extra_distance", 20.0))
	var split_1: Variant = s.get("shadow_split_1", "auto")
	sun.directional_shadow_split_1 = clampf((cam_dist + tile_radius) / sun.directional_shadow_max_distance, 0.05, 0.95) if str(split_1) == "auto" else float(split_1)
	sun.directional_shadow_fade_start = float(s.get("shadow_fade_start", 0.95))
	sun.directional_shadow_blend_splits = bool(s.get("shadow_blend_splits", true))
	# fill
	var f: Dictionary = _sec("fill")
	fill.visible = bool(f.get("enabled", true))
	var fill_dir: Vector3 = vec3(f.get("direction", [6, 4, -6]), Vector3(6, 4, -6)).normalized()
	fill.transform = Transform3D(Basis.looking_at(-fill_dir, Vector3.UP), Vector3.ZERO)
	fill.light_color = col(f.get("color", [0.38, 0.49, 0.75]))
	fill.light_energy = float(f.get("energy", 0.4))
	fill.shadow_enabled = bool(f.get("shadow", false))
	fill.light_specular = float(f.get("specular", 0.0))
	# environment
	var e: Dictionary = _sec("env")
	var tonemaps: Dictionary = {"linear": Environment.TONE_MAPPER_LINEAR, "reinhard": Environment.TONE_MAPPER_REINHARDT, "filmic": Environment.TONE_MAPPER_FILMIC, "aces": Environment.TONE_MAPPER_ACES, "agx": Environment.TONE_MAPPER_AGX}
	environment.tonemap_mode = tonemaps.get(str(e.get("tonemap", "aces")), Environment.TONE_MAPPER_ACES)
	environment.tonemap_exposure = float(e.get("exposure", 1.0))
	environment.tonemap_white = float(e.get("white", 1.0))
	environment.ambient_light_energy = float(e.get("ambient_energy", 1.0))
	environment.ambient_light_sky_contribution = float(e.get("ambient_sky_contribution", 1.0))
	if str(e.get("ambient_source", "sky")) == "color":
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = col(e.get("ambient_color", [0.5, 0.5, 0.5]))
	else:
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var ssao: Dictionary = e.get("ssao", {})
	environment.ssao_enabled = bool(ssao.get("enabled", false))
	environment.ssao_radius = float(ssao.get("radius", 1.0))
	environment.ssao_intensity = float(ssao.get("intensity", 2.0))
	environment.ssao_power = float(ssao.get("power", 1.5))
	environment.ssao_detail = float(ssao.get("detail", 0.5))
	environment.ssao_horizon = float(ssao.get("horizon", 0.06))
	environment.ssao_sharpness = float(ssao.get("sharpness", 0.98))
	environment.ssao_light_affect = float(ssao.get("light_affect", 0.0))
	environment.ssao_ao_channel_affect = float(ssao.get("ao_channel_affect", 0.0))
	var ssil: Dictionary = e.get("ssil", {})
	environment.ssil_enabled = bool(ssil.get("enabled", false))
	environment.ssil_radius = float(ssil.get("radius", 5.0))
	environment.ssil_intensity = float(ssil.get("intensity", 1.0))
	var glow: Dictionary = e.get("glow", {})
	environment.glow_enabled = bool(glow.get("enabled", false))
	environment.glow_intensity = float(glow.get("intensity", 0.8))
	environment.glow_strength = float(glow.get("strength", 1.0))
	environment.glow_bloom = float(glow.get("bloom", 0.0))
	environment.glow_hdr_threshold = float(glow.get("hdr_threshold", 1.0))
	environment.glow_hdr_scale = float(glow.get("hdr_scale", 2.0))
	var blends: Dictionary = {"additive": Environment.GLOW_BLEND_MODE_ADDITIVE, "screen": Environment.GLOW_BLEND_MODE_SCREEN, "softlight": Environment.GLOW_BLEND_MODE_SOFTLIGHT, "replace": Environment.GLOW_BLEND_MODE_REPLACE, "mix": Environment.GLOW_BLEND_MODE_MIX}
	environment.glow_blend_mode = blends.get(str(glow.get("blend_mode", "screen")), Environment.GLOW_BLEND_MODE_SCREEN)
	var levels: Array = glow.get("levels", [0, 0, 1, 0, 1, 0, 0])
	for i: int in mini(7, levels.size()):
		environment.set_glow_level(i, float(levels[i]))
	var fog: Dictionary = e.get("fog", {})
	environment.fog_enabled = bool(fog.get("enabled", false))
	environment.fog_light_color = col(fog.get("color", [0.8, 0.8, 0.8]))
	environment.fog_density = float(fog.get("density", 0.005))
	environment.fog_sky_affect = float(fog.get("sky_affect", 0.0))
	environment.fog_height = float(fog.get("height", -2.0))
	environment.fog_height_density = float(fog.get("height_density", 0.0))
	var adj: Dictionary = e.get("adjust", {})
	environment.adjustment_enabled = bool(adj.get("enabled", false))
	environment.adjustment_brightness = float(adj.get("brightness", 1.0))
	environment.adjustment_contrast = float(adj.get("contrast", 1.0))
	environment.adjustment_saturation = float(adj.get("saturation", 1.0))
	# sky / backdrop
	var sk: Dictionary = _sec("sky")
	var theme_bd: Dictionary = sk.get("theme_backdrop", {})
	backdrop_display = col(theme_bd.get(theme, sk.get("backdrop", "#eadbcc")))
	var top_mult: float = float(sk.get("top_mult", 1.0))
	var bottom_mult: float = float(sk.get("bottom_mult", 1.0))
	var compensate: bool = bool(sk.get("compensate_tonemap", true))
	var top_c: Color = _backdrop_input(backdrop_display * top_mult, compensate)
	var bottom_c: Color = _backdrop_input(backdrop_display * bottom_mult, compensate)
	sky_material.set_shader_parameter("backdrop_top", Vector3(top_c.r, top_c.g, top_c.b))
	sky_material.set_shader_parameter("backdrop_bottom", Vector3(bottom_c.r, bottom_c.g, bottom_c.b))
	sky_material.set_shader_parameter("vignette", float(sk.get("vignette", 0.0)))
	sky_material.set_shader_parameter("glow_amount", float(sk.get("glow_amount", 0.0)))
	sky_material.set_shader_parameter("ambient_top", col(sk.get("ambient_top", [0.48, 0.56, 0.69])))
	sky_material.set_shader_parameter("ambient_horizon", col(sk.get("ambient_horizon", [0.40, 0.40, 0.44])))
	sky_material.set_shader_parameter("ambient_bottom", col(sk.get("ambient_bottom", [0.20, 0.15, 0.19])))
	sky_material.set_shader_parameter("ambient_energy", float(sk.get("ambient_energy", 1.0)))
	# floor (shadow catcher)
	var fl: Dictionary = _sec("floor")
	floor_node.visible = bool(fl.get("enabled", true))
	floor_node.position = Vector3(0.0, float(fl.get("y", -0.92)), 0.0)
	(floor_node.mesh as PlaneMesh).size = Vector2.ONE * float(fl.get("size", 400.0))
	floor_material.set_shader_parameter("backdrop_top", Vector3(top_c.r, top_c.g, top_c.b))
	floor_material.set_shader_parameter("backdrop_bottom", Vector3(bottom_c.r, bottom_c.g, bottom_c.b))
	floor_material.set_shader_parameter("vignette", float(sk.get("vignette", 0.0)))
	floor_material.set_shader_parameter("glow_amount", float(sk.get("glow_amount", 0.0)))
	floor_material.set_shader_parameter("shadow_value", float(fl.get("shadow_value", 0.72)))
	var tint: Color = col(fl.get("shadow_tint", [1, 1, 1])).srgb_to_linear()
	floor_material.set_shader_parameter("shadow_tint", Vector3(tint.r, tint.g, tint.b))
	# camera attributes / DOF
	var cam: Dictionary = _sec("camera")
	var dof: Dictionary = cam.get("dof", {})
	var focus: float = float(camera_fit.get("focus_distance", 25.0))
	camera_attributes.dof_blur_far_enabled = bool(dof.get("far_enabled", false))
	camera_attributes.dof_blur_far_distance = focus + float(dof.get("far_offset", 3.0))
	camera_attributes.dof_blur_far_transition = float(dof.get("far_transition", 8.0))
	camera_attributes.dof_blur_near_enabled = bool(dof.get("near_enabled", false))
	camera_attributes.dof_blur_near_distance = maxf(0.1, focus - float(dof.get("near_offset", 3.0)))
	camera_attributes.dof_blur_near_transition = float(dof.get("near_transition", 4.0))
	camera_attributes.dof_blur_amount = float(dof.get("amount", 0.08))
	# role materials (per-light uniforms such as glow emission)
	for role: String in materials.keys():
		_bind_role_uniforms(role)
	# fires / lamps
	var fires: Dictionary = _sec("fires")
	for light: OmniLight3D in fire_lights:
		light.visible = bool(fires.get("enabled", true))
		light.light_color = col(fires.get("light_color", [1.0, 0.45, 0.12]))
		light.light_energy = float(fires.get("light_energy", 0.6))
		light.omni_range = float(fires.get("light_range", 2.5))
		light.omni_attenuation = float(fires.get("light_attenuation", 1.5))
		light.shadow_enabled = bool(fires.get("shadow", false))
	var flame_energy: float = float(fires.get("flame_emission", 1.5))
	for fl_rec: Dictionary in flames:
		var fm: StandardMaterial3D = fl_rec.material
		fm.emission_energy_multiplier = flame_energy
	var lamps: Dictionary = _sec("lamps")
	for lamp: OmniLight3D in lamp_lights:
		lamp.visible = bool(lamps.get("enabled", true))
		lamp.light_color = col(lamps.get("light_color", [1.0, 0.55, 0.22]))
		lamp.light_energy = float(lamps.get("light_energy", 0.5))
		lamp.omni_range = float(lamps.get("light_range", 2.5))
		lamp.omni_attenuation = float(lamps.get("light_attenuation", 1.5))
		lamp.shadow_enabled = bool(lamps.get("shadow", false))
	var motion: Dictionary = _sec("motion")
	for role: String in materials.keys():
		var m: ShaderMaterial = materials[role]
		var types: Dictionary = uniform_types.get(str(m.get_meta("shader_path")), {})
		if types.has("wind_strength") and not _role_has(role, "wind_strength"):
			m.set_shader_parameter("wind_strength", float(motion.get("wind_strength", 0.0)))
	for cb: Callable in light_callbacks:
		cb.call(light_name)

func _role_has(role: String, key: String) -> bool:
	var roles: Dictionary = _cfgv("surface", "roles", {})
	return (roles.get(role, {}) as Dictionary).has(key) or (_cfgv("surface", "uniforms", {}) as Dictionary).has(key)

## Switch the light preset at runtime (keys, modules). Rebuilds the effective config and re-applies it.
func set_light(name_value: String) -> void:
	if not LIGHTS.has(name_value):
		return
	light_name = name_value
	cfg = _effective_config(light_name)
	_apply_light_config()

## Godot's ACES (4.x tonemap.glsl) forward curve, used to pre-compensate the backdrop so the displayed
## colour matches the web palette. The capture JSON reports the measured error.
func _aces(x: Vector3, white: float) -> Vector3:
	var bias: float = 1.8
	var a: float = 0.0245786; var b: float = 0.000090537; var c: float = 0.983729; var d: float = 0.432951; var e: float = 0.238081
	var rrt: Vector3 = Vector3(
		(0.59719 * x.x + 0.35458 * x.y + 0.04823 * x.z) * bias,
		(0.07600 * x.x + 0.90834 * x.y + 0.01566 * x.z) * bias,
		(0.02840 * x.x + 0.13383 * x.y + 0.83777 * x.z) * bias)
	var t: Vector3 = Vector3(_rrt(rrt.x, a, b, c, d, e), _rrt(rrt.y, a, b, c, d, e), _rrt(rrt.z, a, b, c, d, e))
	var odt: Vector3 = Vector3(
		1.60475 * t.x - 0.53108 * t.y - 0.07367 * t.z,
		-0.10208 * t.x + 1.10813 * t.y - 0.00605 * t.z,
		-0.00327 * t.x - 0.07276 * t.y + 1.07602 * t.z)
	var w: float = white * bias
	return odt / _rrt(w, a, b, c, d, e)

func _rrt(v: float, a: float, b: float, c: float, d: float, e: float) -> float:
	return (v * (v + a) - b) / (v * (c * v + d) + e)

func _backdrop_input(display_srgb: Color, compensate: bool) -> Color:
	var target: Color = display_srgb.srgb_to_linear()
	if not compensate or environment.tonemap_mode != Environment.TONE_MAPPER_ACES:
		return target
	var exposure: float = environment.tonemap_exposure
	var white: float = environment.tonemap_white
	var x: Vector3 = Vector3(target.r, target.g, target.b)
	var goal: Vector3 = x
	for _i: int in 40:
		var y: Vector3 = _aces(x * exposure, white)
		x = Vector3(x.x * goal.x / maxf(y.x, 1e-5), x.y * goal.y / maxf(y.y, 1e-5), x.z * goal.z / maxf(y.z, 1e-5))
		x = x.clamp(Vector3.ZERO, Vector3.ONE * 64.0)
	return Color(x.x, x.y, x.z)

# ------------------------------------------------------------------ bounds + camera rule
func _compute_bounds() -> void:
	var t: Dictionary = tile.get("tile", {})
	var yr: Array = t.get("ground_y_range", [0.0, 1.0])
	tile_bounds = AABB(Vector3(-4.0, float(t.get("plinth_bottom_y", -0.83)), -4.0), Vector3(8.0, float(yr[1]) - float(t.get("plinth_bottom_y", -0.83)), 8.0))
	for rec: Dictionary in instance_nodes:
		for mi: MeshInstance3D in rec.meshes:
			tile_bounds = tile_bounds.merge(mi.global_transform * mi.get_aabb())
	for role: String in proc_nodes.keys():
		var pm: MeshInstance3D = proc_nodes[role]
		tile_bounds = tile_bounds.merge(pm.global_transform * pm.get_aabb())
	if character_body != null:
		var geo: Mesh = character_body.bake_mesh_from_current_skeleton_pose() if character_body.skin != null else character_body.mesh
		tile_bounds = tile_bounds.merge(character_body.global_transform * geo.get_aabb())

## One rule for every tile: fixed yaw/pitch/fov (variant camera section); target + distance solved so the
## tile bounds fill the 16:9 frame with the given margin, centred.
func _fit_camera() -> void:
	var cam: Dictionary = _sec("camera")
	var yaw: float = deg_to_rad(float(cam.get("yaw_deg", 40.1)))
	var pitch: float = deg_to_rad(float(cam.get("pitch_deg", 37.8)))
	var fov: float = float(cam.get("fov_deg", 24.0))
	var aspect: float = float(cam.get("aspect", 16.0 / 9.0))
	var margin: float = float(cam.get("margin", 0.06))
	var ortho: bool = str(cam.get("projection", "perspective")) == "orthographic"
	var dir: Vector3 = Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)).normalized()
	var zaxis: Vector3 = dir
	var xaxis: Vector3 = Vector3.UP.cross(zaxis).normalized()
	var yaxis: Vector3 = zaxis.cross(xaxis)
	var target: Vector3 = tile_bounds.get_center() + vec3(cam.get("target_offset", [0, 0, 0]))
	var tan_half: float = tan(deg_to_rad(fov) * 0.5)
	var dist: float = 30.0
	var ortho_size: float = 10.0
	var corners: Array[Vector3] = []
	for i: int in 8:
		corners.append(tile_bounds.get_endpoint(i))
	for _iter: int in 24:
		var eye: Vector3 = target + dir * dist
		var minx: float = INF; var maxx: float = -INF; var miny: float = INF; var maxy: float = -INF
		for p: Vector3 in corners:
			var v: Vector3 = p - eye
			var cx: float = v.dot(xaxis); var cy: float = v.dot(yaxis); var cz: float = -v.dot(zaxis)
			var nx: float = cx / (ortho_size * 0.5 * aspect) if ortho else cx / (cz * tan_half * aspect)
			var ny: float = cy / (ortho_size * 0.5) if ortho else cy / (cz * tan_half)
			minx = minf(minx, nx); maxx = maxf(maxx, nx); miny = minf(miny, ny); maxy = maxf(maxy, ny)
		var center_x: float = (minx + maxx) * 0.5
		var center_y: float = (miny + maxy) * 0.5
		var extent: float = maxf((maxx - minx) * 0.5, (maxy - miny) * 0.5) / (1.0 - margin)
		var depth: float = (tile_bounds.get_center() - eye).dot(-zaxis)
		if ortho:
			target += xaxis * center_x * ortho_size * 0.5 * aspect + yaxis * center_y * ortho_size * 0.5
			ortho_size *= extent
		else:
			target += xaxis * center_x * depth * tan_half * aspect + yaxis * center_y * depth * tan_half
			dist = maxf(2.0, dist * lerpf(1.0, extent, 0.85))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL if ortho else Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = fov
	camera.size = ortho_size
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = float(cam.get("near", 0.1))
	camera.far = float(cam.get("far", 400.0))
	camera.global_transform = Transform3D(Basis(xaxis, yaxis, zaxis), target + dir * dist)
	var focus_point: Vector3 = character.global_position if character != null and bool(cam.get("focus_on_character", false)) else tile_bounds.get_center()
	camera_fit = {"rule": "fixed yaw/pitch/fov, fit tile bounds to 16:9 with margin", "yaw_deg": rad_to_deg(yaw), "pitch_deg": rad_to_deg(pitch), "fov_deg": fov, "projection": "orthographic" if ortho else "perspective", "distance": dist, "ortho_size": ortho_size, "target": [target.x, target.y, target.z], "margin": margin, "bounds": {"position": [tile_bounds.position.x, tile_bounds.position.y, tile_bounds.position.z], "size": [tile_bounds.size.x, tile_bounds.size.y, tile_bounds.size.z]}, "focus_distance": (focus_point - camera.global_position).dot(-camera.global_basis.z)}

# ------------------------------------------------------------------ extension modules
func _run_extra_scripts() -> void:
	for item: Variant in variant.get("extra_scripts", []):
		if not item is Dictionary:
			continue
		var d: Dictionary = item
		if d.has("lights") and not (d.lights as Array).has(light_name):
			continue
		var script_path: String = str(d.get("script", ""))
		var script: Script = load(script_path) as Script
		if script == null:
			push_error("LSHU extra script missing: " + script_path)
			continue
		var obj: Object = script.new()
		extra_modules.append(obj) # keeps RefCounted modules alive for their tick / light callbacks
		if obj is Node:
			add_child(obj as Node)
		var result: Variant = obj.call("build", self, d.get("cfg", {}))
		extra_results.append({"script": script_path.get_file(), "result": result})

## Modules: called every frame with (t, delta); t holds still under --motion-freeze.
func register_tick(cb: Callable) -> void:
	tick_callbacks.append(cb)

## Modules: called with the light name whenever the light preset is (re)applied.
func register_light_callback(cb: Callable) -> void:
	light_callbacks.append(cb)

func add_report(key: String, value: Variant) -> void:
	report_extra[key] = value

# ------------------------------------------------------------------ motion
func _process(delta: float) -> void:
	if not motion_frozen:
		anim_t += delta
	_apply_motion(anim_t, delta)

func _apply_motion(t: float, delta: float) -> void:
	for role: String in materials.keys():
		(materials[role] as ShaderMaterial).set_shader_parameter("anim_time", t)
	if character_player != null and character_anim_length > 0.0 and carrying_pose == null:
		character_player.seek(fposmod(t + float(_cfgv("character", "idle_offset_s", 0.0)), character_anim_length), true)
	if seated_actor != null:
		seated_actor.call("set_time", t)
	if carrying_pose != null:
		carrying_pose.call("set_time", t)
	var motion: Dictionary = _sec("motion")
	if bool(motion.get("rotor", true)):
		for r: Dictionary in rotors:
			(r.node as Node3D).basis = (r.base as Basis) * Basis(r.axis, t * float(r.speed))
	var bob: float = float(motion.get("boat_bob", 0.016))
	for b: Dictionary in bobbers:
		var n: Node3D = b.node
		n.position.y = float(b.base_y) + sin(t * 1.0 + float(b.phase)) * bob
		n.rotation.z = sin(t * 0.78 + float(b.phase)) * bob * 1.25
	for f: Dictionary in flames:
		var mi: MeshInstance3D = f.node
		var s: Vector3 = f.scale
		mi.scale = Vector3(s.x, s.y * (0.94 + 0.12 * sin(t * 8.0 + float(f.phase))), s.z)
		mi.rotation.z = sin(t * 4.0 + float(f.phase)) * 0.08
	var flicker: float = float(_cfgv("fires", "flicker", 0.12))
	var fire_energy: float = float(_cfgv("fires", "light_energy", 0.6))
	for i: int in fire_lights.size():
		fire_lights[i].light_energy = fire_energy * (1.0 + flicker * sin(t * 7.3 + i * 1.3) * sin(t * 3.1 + i))
	for cb: Callable in tick_callbacks:
		cb.call(t, delta)

func _unhandled_key_input(event: InputEvent) -> void:
	var k: InputEventKey = event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_L:
		set_light(LIGHTS[(LIGHTS.find(light_name) + 1) % LIGHTS.size()])
		print("LSHU_LIGHT ", light_name)
	elif k.keycode == KEY_F:
		motion_frozen = not motion_frozen

# ------------------------------------------------------------------ window parking / capture
func _park(slot: int) -> void:
	var wid: int = DisplayServer.MAIN_WINDOW_ID
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(wid))
	var size: Vector2i = Vector2i(400, 225)
	DisplayServer.window_set_size(size, wid)
	DisplayServer.window_set_position(usable.position + usable.size - Vector2i((slot % 4 + 1) * (size.x + 8), (slot / 4 + 1) * (size.y + 36)), wid)

func projected_bounds(mesh: MeshInstance3D, geometry: Mesh = null) -> Dictionary:
	var geo: Mesh = geometry if geometry != null else mesh.mesh
	var minimum: Vector2 = Vector2(INF, INF)
	var maximum: Vector2 = -minimum
	for surface: int in geo.get_surface_count():
		var verts: PackedVector3Array = geo.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for vi: int in range(0, verts.size(), 7):
			var px: Vector2 = camera.unproject_position(mesh.global_transform * verts[vi])
			minimum = minimum.min(px)
			maximum = maximum.max(px)
	return {"bounds_px": [minimum.x, minimum.y, maximum.x, maximum.y], "width_px": maximum.x - minimum.x, "height_px": maximum.y - minimum.y}

func capture(output_path: String) -> void:
	for _i: int in 120:
		await RenderingServer.frame_post_draw
	var samples: Array[float] = []
	var previous: int = Time.get_ticks_usec()
	for _i: int in 180:
		await RenderingServer.frame_post_draw
		var now: int = Time.get_ticks_usec()
		samples.append(float(now - previous) / 1000.0)
		previous = now
	var global_draws: int = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var viewport_draws: int = get_viewport().get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var shadow_draws: int = get_viewport().get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var primitives: int = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	var image: Image = get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	var error: int = image.save_png(output_path)
	var sorted: Array[float] = samples.duplicate()
	sorted.sort()
	var corner: Color = image.get_pixel(12, 12)
	var character_proj: Dictionary = {}
	if character_body != null:
		var posed: Mesh = character_body.bake_mesh_from_current_skeleton_pose() if character_body.skin != null else character_body.mesh
		character_proj = projected_bounds(character_body, posed)
	var inst_records: Array = []
	for rec: Dictionary in instance_nodes:
		var d: Dictionary = rec.data
		inst_records.append({"asset_id": d.asset_id, "role": d.get("role"), "group": d.get("group"), "anim": d.get("anim")})
	var report: Dictionary = {
		"schema": "lshu.capture.v1", "recipe": recipe_id, "composition_id": tile.get("composition_id"), "name": tile.get("name"),
		"place": tile.get("place"), "kit": tile.get("kit"), "light": light_name, "variant": variant_name,
		"image_size": [image.get_width(), image.get_height()], "viewport_size": [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y],
		"capture_error": error, "draw_calls": global_draws, "viewport_draw_calls": viewport_draws, "shadow_draw_calls": shadow_draws, "rendered_primitives": primitives,
		"frame_ms": {"p50": sorted[89], "p95": sorted[170], "max": sorted[179], "samples": samples, "sample_count": 180, "warmup_frames": 120, "vsync_disabled": DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED, "engine_max_fps": Engine.max_fps},
		"motion_frozen": motion_frozen, "anim_t": anim_t,
		"camera": camera_fit, "camera_transform": str(camera.global_transform),
		"character": {"pose": character_pose, "action": tile.get("character", {}).get("action"), "kit": tile.get("character", {}).get("kit"), "height_m": character_height_m, "world_position": [character.global_position.x, character.global_position.y, character.global_position.z] if character != null else [], "projection": character_proj,
			"seated": seated_actor.call("evidence") if seated_actor != null else null, "carrying": carrying_pose.call("evidence") if carrying_pose != null else null},
		"backdrop": {"target_srgb": [backdrop_display.r, backdrop_display.g, backdrop_display.b], "measured_corner_srgb": [corner.r, corner.g, corner.b], "error_max": maxf(absf(corner.r - backdrop_display.r), maxf(absf(corner.g - backdrop_display.g), absf(corner.b - backdrop_display.b)))},
		"roles": materials.keys(), "proc_roles": proc_nodes.keys(), "instances": inst_records, "fires": fire_lights.size(), "lamps": lamp_lights.size(), "rotors": rotors.size(),
		"extra_scripts": extra_results, "extra": report_extra, "notes": notes, "config": cfg,
	}
	var f: FileAccess = FileAccess.open(output_path.get_basename() + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify(report, " "))
	f.close()
	print("LSHU_CAPTURE ", JSON.stringify({"png": output_path, "error": error, "p50": sorted[89], "p95": sorted[170], "draw_calls": global_draws, "character_px": character_proj.get("height_px", 0.0), "backdrop_err": report.backdrop.error_max}))
	if error != OK:
		push_error("LSHU capture save failed: " + output_path)
