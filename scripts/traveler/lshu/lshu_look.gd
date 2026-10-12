extends RefCounted
## 第四幕「L叔在哪儿」· the ONE global look (data/traveler/lshu/look.json = approved probe m_final, flattened).
## Effective config for a light preset = merge(common, lights.<light>). Nothing here knows a tile id: per-tile
## inputs are the tile's theme (backdrop colour), its bounds / camera fit (shadow range, fog depth, DOF focus)
## and its lights / fires, all passed in by the assembler.
##
## Owns:
##  - one ShaderMaterial per surface role, shared by every tile (uniforms = surface.uniforms + surface.roles.<role>)
##  - stage lighting: sun, fill, Environment (tonemap, SSAO, SSIL, glow, adjustments), sky / backdrop, the
##    shadow-catcher floor, CameraAttributes (DOF), fire / lamp light parameters
##  - atmosphere (probe module "atmos"): tonemap-compensated backdrop, floor extras, depth fog + height mist,
##    glow / SSIL extras; renderer quality via apply_render_scope() / restore_render_scope()
##  - continuous light (P1): set_light_blend(a, b, t) / set_light_state(clock light) interpolate every parameter
##    between two presets (see "continuous light" below); t = 0 / 1 is exactly set_light(a) / set_light(b)

const LOOK_PATH: String = "res://data/traveler/lshu/look.json"
const RenderGlobals := preload("res://scripts/traveler/render_globals.gd")
const LIGHTS: Array[String] = ["morning", "day", "sunset", "night"]

var data: Dictionary = {}
var modules: Dictionary = {}
var light_name: String = "day"
var cfg: Dictionary = {}
var materials: Dictionary = {}          # role -> ShaderMaterial (shared by all tiles)
var shader_cache: Dictionary = {}
var uniform_types: Dictionary = {}      # shader path -> {uniform: Variant.Type}
var errors: Array[String] = []
var backdrop_display: Color = Color.WHITE
var backdrop_lin: Array[Vector3] = []
var atmos_report: Dictionary = {}
var _scope_saved: Dictionary = {}
## Continuous light: {} on an exact preset, else {a, b, t, cfg_a, cfg_b} (cfg_* = the two merged presets).
var blend: Dictionary = {}
var blend_report: Dictionary = {}
var _bound_uniforms: Dictionary = {}    # role -> {uniform: true} bound from cfg last time (absent ones revert)

func load_look() -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LOOK_PATH))
	if not parsed is Dictionary:
		push_error("LSHU look.json missing or invalid: " + LOOK_PATH)
		return false
	data = parsed
	modules = data.get("modules", {})
	return true

func module_cfg(key: String) -> Dictionary:
	return modules.get(key, {})

func set_light(name_value: String) -> bool:
	if not LIGHTS.has(name_value):
		push_error("LSHU unknown light preset: " + name_value)
		return false
	light_name = name_value
	cfg = effective(light_name)
	blend = {}
	blend_report = {"a": light_name, "b": light_name, "t": 0.0, "held": [], "switched": []}
	return true

func effective(light: String) -> Dictionary:
	var common: Dictionary = data.get("common", {})
	var lights: Dictionary = data.get("lights", {})
	return merge(common, lights.get(light, {}))

static func merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = a.duplicate(true)
	for k: Variant in b.keys():
		if out.has(k) and out[k] is Dictionary and b[k] is Dictionary:
			out[k] = merge(out[k], b[k])
		else:
			out[k] = b[k].duplicate(true) if (b[k] is Dictionary or b[k] is Array) else b[k]
	return out

# ------------------------------------------------------------------ continuous light (P1: the light follows the clock)
## The loop clock's light output r.light = {preset_a, preset_b, blend} (blend already smoothstepped; 0 outside a
## transition). The effective config becomes ONE config interpolated key by key between merge(common, a) and
## merge(common, b), and apply() / on_light() consumers read it as they read a preset, so every look parameter
## (sun, fill, sky / backdrop, environment, fog, DOF, role shader uniforms incl. emissive windows, fires, lamps,
## halos, smoke, floor) moves continuously. Rules, all global:
##   numbers lerp; colours ("#rrggbb" or [r, g, b(, a)]) lerp in sRGB and come out as [r, g, b(, a)]; number arrays
##   lerp per element; sun.position lerps the two unit directions; a "shadow" switch that differs stays on and its
##   shadow_opacity follows the weight of the side that casts (no shadow pop); any other differing bool / string
##   takes the nearer preset (blend_report.switched: only the character rim colour "sun", which the character
##   blends itself from cfg_a / cfg_b). A key only one side has: a role uniform takes the shader default on the
##   other side, anything else keeps its value (blend_report.held; look.json gives every preset-overridden key a
##   common value, so this stays empty).
## t <= 0 or a == b is exactly set_light(a); t >= 1 is exactly set_light(b).
func set_light_blend(preset_a: String, preset_b: String, t: float) -> bool:
	if not LIGHTS.has(preset_a) or not LIGHTS.has(preset_b):
		push_error("LSHU unknown light preset in blend: %s -> %s" % [preset_a, preset_b])
		return false
	var tt: float = clampf(t, 0.0, 1.0)
	if preset_a == preset_b or tt <= 0.0:
		return set_light(preset_a)
	if tt >= 1.0:
		return set_light(preset_b)
	var ca: Dictionary = effective(preset_a)
	var cb: Dictionary = effective(preset_b)
	_fill_uniform_defaults(ca, cb)
	var held: Array[String] = []
	var switched: Array[String] = []
	cfg = blend_config(ca, cb, tt, "", held, switched)
	light_name = preset_a if tt < 0.5 else preset_b
	blend = {"a": preset_a, "b": preset_b, "t": tt, "cfg_a": ca, "cfg_b": cb}
	blend_report = {"a": preset_a, "b": preset_b, "t": tt, "held": held, "switched": switched}
	return true

## The clock's r.light ({preset_a, preset_b, blend, ...}); an empty preset_b means preset_a.
func set_light_state(light: Dictionary) -> bool:
	var a: String = str(light.get("preset_a", light_name))
	var b: String = str(light.get("preset_b", a))
	if b.is_empty():
		b = a
	return set_light_blend(a, b, float(light.get("blend", 0.0)))

## Weight of a preset in the current light: 1 / 0 on an exact preset, 1 - t / t inside a blend.
func weight(preset: String) -> float:
	if blend.is_empty():
		return 1.0 if light_name == preset else 0.0
	var t: float = float(blend.t)
	return (1.0 - t if str(blend.a) == preset else 0.0) + (t if str(blend.b) == preset else 0.0)

static func blend_config(a: Dictionary, b: Dictionary, t: float, path: String, held: Array[String], switched: Array[String]) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in a.keys():
		var p: String = path + "/" + str(k)
		if b.has(k):
			out[k] = blend_value(a[k], b[k], t, p, held, switched)
		else:
			out[k] = _copy(a[k])
			held.append(p)
	for k: Variant in b.keys():
		if not a.has(k):
			out[k] = _copy(b[k])
			held.append(path + "/" + str(k))
	# a shadow switch that differs: stays on, its opacity follows the weight of the casting side
	if a.get("shadow") is bool and b.get("shadow") is bool and bool(a.shadow) != bool(b.shadow):
		out["shadow"] = true
		var oa: float = float(a.get("shadow_opacity", 1.0)) if bool(a.shadow) else 0.0
		var ob: float = float(b.get("shadow_opacity", 1.0)) if bool(b.shadow) else 0.0
		out["shadow_opacity"] = lerpf(oa, ob, t)
		switched.erase(path + "/shadow")
	return out

static func blend_value(va: Variant, vb: Variant, t: float, path: String, held: Array[String], switched: Array[String]) -> Variant:
	if typeof(va) == typeof(vb) and va == vb:
		return _copy(va)
	if va is Dictionary and vb is Dictionary:
		return blend_config(va, vb, t, path, held, switched)
	if _is_number(va) and _is_number(vb):
		return lerpf(float(va), float(vb), t)
	if path == "/sun/position" and va is Array and vb is Array:
		var d: Vector3 = vec3(va).normalized().lerp(vec3(vb).normalized(), t)
		return [d.x, d.y, d.z]
	var ca: Array = _colour_array(va)
	var cb: Array = _colour_array(vb)
	if not ca.is_empty() and not cb.is_empty():
		if ca.size() != cb.size():
			ca = _rgba(ca)
			cb = _rgba(cb)
		var outc: Array = []
		for i: int in ca.size():
			outc.append(lerpf(float(ca[i]), float(cb[i]), t))
		return outc
	if va is Array and vb is Array and (va as Array).size() == (vb as Array).size() and _all_numbers(va) and _all_numbers(vb):
		var outa: Array = []
		for i: int in (va as Array).size():
			outa.append(lerpf(float(va[i]), float(vb[i]), t))
		return outa
	switched.append(path)
	return _copy(va if t < 0.5 else vb)

static func _copy(v: Variant) -> Variant:
	return v.duplicate(true) if (v is Dictionary or v is Array) else v

static func _is_number(v: Variant) -> bool:
	return v is float or v is int

static func _all_numbers(v: Variant) -> bool:
	for x: Variant in v:
		if not _is_number(x):
			return false
	return true

## sRGB components of a colour value ("#rrggbb", "#rrggbbaa" or a 3 / 4 number array); [] if it is not one.
static func _colour_array(v: Variant) -> Array:
	if v is String:
		var s: String = str(v)
		if s.begins_with("#") and Color.html_is_valid(s):
			var c: Color = Color.html(s)
			return [c.r, c.g, c.b, c.a] if s.length() == 9 else [c.r, c.g, c.b]
		return []
	if v is Array and ((v as Array).size() == 3 or (v as Array).size() == 4) and _all_numbers(v):
		return (v as Array).duplicate()
	return []

static func _rgba(c: Array) -> Array:
	return c if c.size() == 4 else [c[0], c[1], c[2], 1.0]

func _role_shader_path(surf: Dictionary, role: String) -> String:
	var roles: Dictionary = surf.get("roles", {})
	var rcfg: Dictionary = roles.get(role, {})
	var overlay_roles: Array = surf.get("overlay_roles", [])
	return str(rcfg.get("shader", surf.get("overlay_shader", "") if overlay_roles.has(role) else surf.get("shader", "")))

## A role uniform one preset sets and the other does not: the other side gets the shader's default value, so the
## blend runs from / to exactly what that preset renders (bind_role_uniforms reverts absent uniforms to default).
func _fill_uniform_defaults(ca: Dictionary, cb: Dictionary) -> void:
	var sa: Dictionary = ca.get("surface", {})
	var sb: Dictionary = cb.get("surface", {})
	var ra: Dictionary = sa.get("roles", {})
	var rb: Dictionary = sb.get("roles", {})
	var roles: Array = ra.keys()
	for r: Variant in rb.keys():
		if not roles.has(r):
			roles.append(r)
	for role: Variant in roles:
		var da: Dictionary = ra.get(role, {})
		var db: Dictionary = rb.get(role, {})
		var keys: Array = da.keys()
		for k: Variant in db.keys():
			if not keys.has(k):
				keys.append(k)
		for k: Variant in keys:
			if str(k) == "shader" or (da.has(k) and db.has(k)):
				continue
			var missing: Dictionary = db if da.has(k) else da
			var surf: Dictionary = sb if da.has(k) else sa
			var sh: Shader = shader(_role_shader_path(surf, str(role)))
			if sh == null:
				continue
			var def: Variant = RenderingServer.shader_get_parameter_default(sh.get_rid(), StringName(str(k)))
			if def == null:
				continue
			missing[k] = _json_value(def)
			(surf.get_or_add("roles", {}) as Dictionary)[role] = missing

static func _json_value(v: Variant) -> Variant:
	if v is Color:
		var c: Color = v
		return [c.r, c.g, c.b, c.a]
	if v is Vector2:
		return [v.x, v.y]
	if v is Vector3:
		return [v.x, v.y, v.z]
	if v is Vector4:
		return [v.x, v.y, v.z, v.w]
	return v

func sec(section: String) -> Dictionary:
	return cfg.get(section, {})

func cfgv(section: String, key: String, fallback: Variant) -> Variant:
	var s: Dictionary = cfg.get(section, {})
	return s.get(key, fallback)

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

# ------------------------------------------------------------------ materials (one per role, shared by all tiles)
func shader(path: String) -> Shader:
	if not shader_cache.has(path):
		var s: Shader = load(path) as Shader
		if s == null:
			push_error("LSHU shader missing: " + path)
			return null
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
	var group_roles: Dictionary = cfgv("surface", "group_roles", {})
	return str(group_roles.get(group, "matte"))

func role_material(role: String) -> ShaderMaterial:
	if materials.has(role):
		return materials[role]
	var surf: Dictionary = sec("surface")
	var roles: Dictionary = surf.get("roles", {})
	var rcfg: Dictionary = roles.get(role, {})
	var overlay_roles: Array = surf.get("overlay_roles", [])
	var path: String = str(rcfg.get("shader", surf.get("overlay_shader", "") if overlay_roles.has(role) else surf.get("shader", "")))
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = shader(path)
	m.resource_name = "lshu_role_" + role
	m.set_meta("shader_path", path)
	m.set_meta("role", role)
	materials[role] = m
	bind_role_uniforms(role)
	return m

func role_types(role: String) -> Dictionary:
	var m: ShaderMaterial = role_material(role)
	return uniform_types.get(str(m.get_meta("shader_path")), {})

func bind_role_uniforms(role: String) -> void:
	var m: ShaderMaterial = materials[role]
	var path: String = str(m.get_meta("shader_path"))
	var types: Dictionary = uniform_types.get(path, {})
	var surf: Dictionary = sec("surface")
	var common: Dictionary = surf.get("uniforms", {})
	var roles: Dictionary = surf.get("roles", {})
	var rcfg: Dictionary = roles.get(role, {})
	var bound: Dictionary = {}
	for k: String in common.keys():
		if types.has(k):
			m.set_shader_parameter(k, uniform_value(common[k], int(types[k])))
			bound[k] = true
	for k: String in rcfg.keys():
		if k == "shader":
			continue
		if types.has(k):
			m.set_shader_parameter(k, uniform_value(rcfg[k], int(types[k])))
			bound[k] = true
		else:
			push_error("LSHU look.json role %s: uniform %s not in %s" % [role, k, path.get_file()])
	# a uniform the previous light set and this one does not reverts to the shader default (a fresh material
	# never had it set, so a preset renders the same whatever light came before it)
	var previous: Dictionary = _bound_uniforms.get(role, {})
	for k: String in previous.keys():
		if not bound.has(k):
			m.set_shader_parameter(k, null)
	_bound_uniforms[role] = bound

## Per-tile inputs on a shared role material (height field, ground maps). Called by the assembler at swap time.
func set_role_uniform(role: String, uniform: String, value: Variant) -> void:
	var m: ShaderMaterial = role_material(role)
	var types: Dictionary = uniform_types.get(str(m.get_meta("shader_path")), {})
	if types.has(uniform):
		m.set_shader_parameter(uniform, value)

static func uniform_value(v: Variant, t: int) -> Variant:
	match t:
		TYPE_COLOR: return col(v)
		TYPE_VECTOR3: return vec3(v)
		TYPE_VECTOR2: return Vector2(float(v[0]), float(v[1]))
		TYPE_VECTOR4: return Vector4(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
		TYPE_FLOAT: return float(v)
		TYPE_INT: return int(v)
		TYPE_BOOL: return bool(v)
	return v

## Every role a tile can reference, created up front so tile switches never compile a material.
func prewarm_roles() -> void:
	var surf: Dictionary = sec("surface")
	var roles: Dictionary = surf.get("roles", {})
	for role: String in roles.keys():
		role_material(role)
	var group_roles: Dictionary = surf.get("group_roles", {})
	for role: Variant in group_roles.values():
		role_material(str(role))
	for role: String in ["ground", "skirt", "cliff", "structure", "steps", "glow", "water", "water_side", "foam", "ripple", "grass", "matte", "metal"]:
		role_material(role)

func role_has(role: String, key: String) -> bool:
	var roles: Dictionary = cfgv("surface", "roles", {})
	return (roles.get(role, {}) as Dictionary).has(key) or (cfgv("surface", "uniforms", {}) as Dictionary).has(key)

# ------------------------------------------------------------------ renderer quality (probe module "atmos", part 1)
## Viewport settings go on the scene's own viewport. Directional shadow atlas size, soft-shadow filter quality and
## DOF blur quality / bokeh shape have no per-scene equivalent in Godot 4.7 (they are RenderingServer-wide), so
## they are applied while this scene is in the tree and restored to the project settings when it leaves.
func apply_render_scope(vp: Viewport) -> Dictionary:
	var a: Dictionary = module_cfg("atmos")
	if _scope_saved.is_empty():
		_scope_saved = {"viewport": vp, "use_debanding": vp.use_debanding, "use_taa": vp.use_taa, "positional_shadow_atlas_size": vp.positional_shadow_atlas_size}
	vp.use_debanding = bool(a.get("debanding", true))
	vp.use_taa = bool(a.get("taa", false))
	vp.positional_shadow_atlas_size = int(a.get("positional_shadow_atlas", 4096))
	var atlas: int = int(a.get("shadow_atlas", 8192))
	# RenderingServer-wide: through render_globals.gd, which remembers the values (no getters) so a hosted act can be undone
	RenderGlobals.shadow_atlas(atlas, true)
	RenderGlobals.directional_soft_shadow(int(a.get("soft_shadow_quality", 4)))
	RenderGlobals.positional_soft_shadow(int(a.get("positional_soft_shadow_quality", 3)))
	var dof_q: Dictionary = {"very_low": RenderingServer.DOF_BLUR_QUALITY_VERY_LOW, "low": RenderingServer.DOF_BLUR_QUALITY_LOW, "medium": RenderingServer.DOF_BLUR_QUALITY_MEDIUM, "high": RenderingServer.DOF_BLUR_QUALITY_HIGH}
	RenderGlobals.dof_blur_quality(int(dof_q.get(str(a.get("dof_quality", "high")), RenderingServer.DOF_BLUR_QUALITY_HIGH)), bool(a.get("dof_jitter", false)))
	var shapes: Dictionary = {"box": RenderingServer.DOF_BOKEH_BOX, "hexagon": RenderingServer.DOF_BOKEH_HEXAGON, "circle": RenderingServer.DOF_BOKEH_CIRCLE}
	RenderGlobals.dof_bokeh_shape(int(shapes.get(str(a.get("dof_bokeh", "circle")), RenderingServer.DOF_BOKEH_CIRCLE)))
	return {"shadow_atlas": atlas, "soft_shadow_quality": int(a.get("soft_shadow_quality", 4)), "dof_quality": str(a.get("dof_quality", "high")), "debanding": vp.use_debanding, "taa": vp.use_taa, "positional_shadow_atlas": vp.positional_shadow_atlas_size, "scope": "viewport settings on the scene viewport; RenderingServer-wide quality restored to project settings on exit"}

func restore_render_scope() -> void:
	if _scope_saved.is_empty():
		return
	var vp: Viewport = _scope_saved.get("viewport") as Viewport
	if is_instance_valid(vp):
		vp.use_debanding = bool(_scope_saved.use_debanding)
		vp.use_taa = bool(_scope_saved.use_taa)
		vp.positional_shadow_atlas_size = int(_scope_saved.positional_shadow_atlas_size)
	var d: Dictionary = RenderGlobals.defaults()
	RenderGlobals.shadow_atlas(int(d.shadow_atlas[0]), bool(d.shadow_atlas[1]))
	RenderGlobals.directional_soft_shadow(int(d.directional_soft_shadow[0]))
	RenderGlobals.positional_soft_shadow(int(d.positional_soft_shadow[0]))
	RenderGlobals.dof_blur_quality(int(d.dof_blur[0]), bool(d.dof_blur[1]))
	RenderGlobals.dof_bokeh_shape(int(d.dof_bokeh[0]))
	_scope_saved = {}

# ------------------------------------------------------------------ light preset application
## Everything that depends on the light preset. stage: the scene (camera, sun, fill, environment, sky_material,
## floor_node, floor_material, camera_attributes). tile: the assembled tile (theme, bounds, camera fit, lights).
func apply(stage: Node3D, tile: Node3D) -> void:
	var tile_data: Dictionary = tile.get("tile")
	var camera_fit: Dictionary = tile.get("camera_fit")
	var tile_bounds: AABB = tile.get("tile_bounds")
	var sun: DirectionalLight3D = stage.get("sun")
	var fill: DirectionalLight3D = stage.get("fill")
	var environment: Environment = stage.get("environment")
	var sky_material: ShaderMaterial = stage.get("sky_material")
	var floor_node: MeshInstance3D = stage.get("floor_node")
	var floor_material: ShaderMaterial = stage.get("floor_material")
	var camera_attributes: CameraAttributesPractical = stage.get("camera_attributes")
	var theme: String = str(tile_data.get("place", {}).get("theme", "autumn"))
	# sun
	var s: Dictionary = sec("sun")
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
	# Shadow range rule (same for every tile): the far split reaches the stage floor behind the tile;
	# split 1 ("auto") ends just past the tile so the tile itself gets the sharp split.
	var cam_dist: float = float(camera_fit.get("distance", 30.0))
	var tile_radius: float = tile_bounds.size.length() * 0.5 if tile_bounds.size != Vector3.ZERO else 6.5
	sun.directional_shadow_max_distance = cam_dist + tile_radius + float(s.get("shadow_extra_distance", 20.0))
	var split_1: Variant = s.get("shadow_split_1", "auto")
	sun.directional_shadow_split_1 = clampf((cam_dist + tile_radius) / sun.directional_shadow_max_distance, 0.05, 0.95) if str(split_1) == "auto" else float(split_1)
	sun.directional_shadow_fade_start = float(s.get("shadow_fade_start", 0.95))
	sun.directional_shadow_blend_splits = bool(s.get("shadow_blend_splits", true))
	# fill
	var f: Dictionary = sec("fill")
	fill.visible = bool(f.get("enabled", true))
	var fill_dir: Vector3 = vec3(f.get("direction", [6, 4, -6]), Vector3(6, 4, -6)).normalized()
	fill.transform = Transform3D(Basis.looking_at(-fill_dir, Vector3.UP), Vector3.ZERO)
	fill.light_color = col(f.get("color", [0.38, 0.49, 0.75]))
	fill.light_energy = float(f.get("energy", 0.4))
	fill.shadow_enabled = bool(f.get("shadow", false))
	fill.light_specular = float(f.get("specular", 0.0))
	# environment
	var e: Dictionary = sec("env")
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
	environment.ssao_enabled = bool(ssao.get("enabled", false)) and RenderGlobals.env_feature("ssao")     # Mobile 没有（TS-9）
	environment.ssao_radius = float(ssao.get("radius", 1.0))
	environment.ssao_intensity = float(ssao.get("intensity", 2.0))
	environment.ssao_power = float(ssao.get("power", 1.5))
	environment.ssao_detail = float(ssao.get("detail", 0.5))
	environment.ssao_horizon = float(ssao.get("horizon", 0.06))
	environment.ssao_sharpness = float(ssao.get("sharpness", 0.98))
	environment.ssao_light_affect = float(ssao.get("light_affect", 0.0))
	environment.ssao_ao_channel_affect = float(ssao.get("ao_channel_affect", 0.0))
	var ssil: Dictionary = e.get("ssil", {})
	environment.ssil_enabled = bool(ssil.get("enabled", false)) and RenderGlobals.env_feature("ssil")
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
	# sky / backdrop (colours solved by the atmosphere pass below)
	var sk: Dictionary = sec("sky")
	var theme_bd: Dictionary = sk.get("theme_backdrop", {})
	backdrop_display = col(theme_bd.get(theme, sk.get("backdrop", "#eadbcc")))
	sky_material.set_shader_parameter("vignette", float(sk.get("vignette", 0.0)))
	sky_material.set_shader_parameter("glow_amount", float(sk.get("glow_amount", 0.0)))
	sky_material.set_shader_parameter("ambient_top", col(sk.get("ambient_top", [0.48, 0.56, 0.69])))
	sky_material.set_shader_parameter("ambient_horizon", col(sk.get("ambient_horizon", [0.40, 0.40, 0.44])))
	sky_material.set_shader_parameter("ambient_bottom", col(sk.get("ambient_bottom", [0.20, 0.15, 0.19])))
	sky_material.set_shader_parameter("ambient_energy", float(sk.get("ambient_energy", 1.0)))
	# floor (shadow catcher and visible backdrop)
	var fl: Dictionary = sec("floor")
	floor_node.visible = bool(fl.get("enabled", true))
	floor_node.position = Vector3(0.0, float(fl.get("y", -0.92)), 0.0)
	(floor_node.mesh as PlaneMesh).size = Vector2.ONE * float(fl.get("size", 400.0))
	floor_material.set_shader_parameter("vignette", float(sk.get("vignette", 0.0)))
	floor_material.set_shader_parameter("glow_amount", float(sk.get("glow_amount", 0.0)))
	floor_material.set_shader_parameter("shadow_value", float(fl.get("shadow_value", 0.72)))
	var tint: Color = col(fl.get("shadow_tint", [1, 1, 1])).srgb_to_linear()
	floor_material.set_shader_parameter("shadow_tint", Vector3(tint.r, tint.g, tint.b))
	# camera attributes / DOF
	var cam: Dictionary = sec("camera")
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
		bind_role_uniforms(role)
	# fires / lamps (the tile's OmniLights)
	var fires: Dictionary = sec("fires")
	for light: OmniLight3D in tile.get("fire_lights"):
		light.visible = bool(fires.get("enabled", true))
		light.light_color = col(fires.get("light_color", [1.0, 0.45, 0.12]))
		light.light_energy = float(fires.get("light_energy", 0.6))
		light.omni_range = float(fires.get("light_range", 2.5))
		light.omni_attenuation = float(fires.get("light_attenuation", 1.5))
		light.shadow_enabled = bool(fires.get("shadow", false))
		light.shadow_opacity = float(fires.get("shadow_opacity", 1.0))
		light.omni_shadow_mode = omni_shadow_mode(fires)
	var lamps: Dictionary = sec("lamps")
	for lamp: OmniLight3D in tile.get("lamp_lights"):
		lamp.visible = bool(lamps.get("enabled", true))
		lamp.light_color = col(lamps.get("light_color", [1.0, 0.55, 0.22]))
		lamp.light_energy = float(lamps.get("light_energy", 0.5))
		lamp.omni_range = float(lamps.get("light_range", 2.5))
		lamp.omni_attenuation = float(lamps.get("light_attenuation", 1.5))
		lamp.shadow_enabled = bool(lamps.get("shadow", false))
		lamp.shadow_opacity = float(lamps.get("shadow_opacity", 1.0))
		lamp.omni_shadow_mode = omni_shadow_mode(lamps)
	var motion: Dictionary = sec("motion")
	for role: String in materials.keys():
		var m: ShaderMaterial = materials[role]
		var types: Dictionary = uniform_types.get(str(m.get_meta("shader_path")), {})
		if types.has("wind_strength") and not role_has(role, "wind_strength"):
			m.set_shader_parameter("wind_strength", float(motion.get("wind_strength", 0.0)))
	_apply_atmosphere(environment, sky_material, floor_material, camera_fit)

## Omni shadow layout of a fires / lamps section: "cube" (6 shadow passes) or "dual_paraboloid" (2 passes; the P0
## draw-call rule for night fires: mean 0.003-0.008/255 against cube shadows on the night fire tiles, report only).
static func omni_shadow_mode(section: Dictionary) -> OmniLight3D.ShadowMode:
	return OmniLight3D.SHADOW_DUAL_PARABOLOID if str(section.get("shadow_mode", "cube")) == "dual_paraboloid" else OmniLight3D.SHADOW_CUBE

# ------------------------------------------------------------------ atmosphere (probe module "atmos", part 2)
func _atmos() -> Dictionary:
	return cfg.get("atmos", {})

static func _lin(v: Variant, fallback: Color) -> Vector3:
	var c: Color = fallback
	if v is String:
		c = Color.html(str(v))
	elif v is Array and (v as Array).size() >= 3:
		var a: Array = v
		c = Color(float(a[0]), float(a[1]), float(a[2]))
	c = c.srgb_to_linear()
	return Vector3(c.r, c.g, c.b)

func _apply_atmosphere(env: Environment, sky_mat: ShaderMaterial, floor_mat: ShaderMaterial, camera_fit: Dictionary) -> void:
	var a: Dictionary = _atmos()
	var focus: float = float(camera_fit.get("focus_distance", 28.0))
	var fl: Dictionary = a.get("floor", {})
	# Backdrop compensation: per-channel bisection through the full display transform
	# (exposure -> ACES -> sRGB -> brightness/contrast/saturation), Gauss-Seidel sweeps, clamped at 0.
	var sk: Dictionary = sec("sky")
	var top_target: Color = _mul(backdrop_display, float(sk.get("top_mult", 1.0)), fl.get("top_tint", null))
	var bottom_target: Color = _mul(backdrop_display, float(sk.get("bottom_mult", 1.0)), fl.get("bottom_tint", null))
	var top_lin: Vector3 = _solve_display(top_target, env)
	var bottom_lin: Vector3 = _solve_display(bottom_target, env)
	backdrop_lin = [top_lin, bottom_lin]
	floor_mat.set_shader_parameter("backdrop_top", top_lin)
	floor_mat.set_shader_parameter("backdrop_bottom", bottom_lin)
	sky_mat.set_shader_parameter("backdrop_top", Color(top_lin.x, top_lin.y, top_lin.z).linear_to_srgb())
	sky_mat.set_shader_parameter("backdrop_bottom", Color(bottom_lin.x, bottom_lin.y, bottom_lin.z).linear_to_srgb())
	atmos_report["backdrop"] = {"display_top": top_target.to_html(false), "display_bottom": bottom_target.to_html(false), "predicted_top": _display(top_lin, env).to_html(false), "predicted_bottom": _display(bottom_lin, env).to_html(false)}
	floor_mat.set_shader_parameter("gradient_curve", float(fl.get("gradient_curve", 1.0)))
	floor_mat.set_shader_parameter("glow_tint", _lin(fl.get("glow_tint", "#ffffff"), Color.WHITE))
	var gr: Array = fl.get("glow_radius", [1.4, 2.0])
	floor_mat.set_shader_parameter("glow_radius", Vector2(float(gr[0]), float(gr[1])))
	var gc: Array = fl.get("glow_center", [0.5, 0.45])
	floor_mat.set_shader_parameter("glow_center", Vector2(float(gc[0]), float(gc[1])))
	floor_mat.set_shader_parameter("vignette_inner", float(fl.get("vignette_inner", 0.25)))
	floor_mat.set_shader_parameter("vignette_outer", float(fl.get("vignette_outer", 0.8)))
	floor_mat.set_shader_parameter("contact_ao", float(fl.get("contact_ao", 0.0)))
	floor_mat.set_shader_parameter("contact_ao_radius", float(fl.get("contact_ao_radius", 1.0)))
	floor_mat.set_shader_parameter("shadow_fade_distance", float(fl.get("shadow_fade_distance", 60.0)))
	floor_mat.set_shader_parameter("stars_amount", float(fl.get("stars_amount", 0.0)))
	floor_mat.set_shader_parameter("stars_density", float(fl.get("stars_density", 0.004)))
	floor_mat.set_shader_parameter("stars_tint", _lin(fl.get("stars_tint", "#ffffff"), Color.WHITE))
	floor_mat.set_shader_parameter("stars_top_bias", float(fl.get("stars_top_bias", 1.4)))
	# the sky's own visible branch sits behind the floor; keep its glow centre in step anyway
	if fl.has("glow_center"):
		var gc2: Array = fl.get("glow_center")
		sky_mat.set_shader_parameter("glow_center", Vector2(float(gc2[0]), float(gc2[1])))
	# fog: colour from the backdrop (so haze melts into it), depth fog relative to the camera fit,
	# height mist relative to the ground (y = 0 is the web ground datum on every tile)
	var fog: Dictionary = a.get("fog", {})
	env.fog_enabled = bool(fog.get("enabled", false))
	if env.fog_enabled:
		var mode: String = str(fog.get("mode", "depth"))
		env.fog_mode = Environment.FOG_MODE_DEPTH if mode == "depth" else Environment.FOG_MODE_EXPONENTIAL
		env.fog_depth_begin = maxf(0.0, focus + float(fog.get("depth_begin_offset", 0.0)))
		env.fog_depth_end = maxf(env.fog_depth_begin + 0.1, focus + float(fog.get("depth_end_offset", 40.0)))
		env.fog_depth_curve = float(fog.get("depth_curve", 1.0))
		env.fog_density = float(fog.get("density", 0.0))
		env.fog_height = float(fog.get("height", -0.2))
		env.fog_height_density = float(fog.get("height_density", 0.0))
		env.fog_sun_scatter = float(fog.get("sun_scatter", 0.0))
		env.fog_aerial_perspective = float(fog.get("aerial_perspective", 0.0))
		env.fog_sky_affect = float(fog.get("sky_affect", 0.0))
		env.fog_light_energy = float(fog.get("light_energy", 1.0))
		var fm: float = float(fog.get("backdrop_mix", 0.6))
		var fl_lin: Vector3 = top_lin.lerp(bottom_lin, fm)
		var fog_col: Color = Color(fl_lin.x, fl_lin.y, fl_lin.z).linear_to_srgb()
		if fog.has("color"):
			var fc: Variant = fog.get("color")
			var custom: Color = Color.html(str(fc)) if fc is String else Color(float(fc[0]), float(fc[1]), float(fc[2]))
			fog_col = fog_col.lerp(custom, float(fog.get("color_mix", 1.0)))
		env.fog_light_color = fog_col
	var gl: Dictionary = a.get("glow", {})
	env.glow_hdr_luminance_cap = float(gl.get("luminance_cap", 12.0))
	env.glow_normalized = bool(gl.get("normalized", false))
	env.glow_mix = float(gl.get("mix", 0.05))
	var si: Dictionary = a.get("ssil", {})
	env.ssil_sharpness = float(si.get("sharpness", 0.98))
	env.ssil_normal_rejection = float(si.get("normal_rejection", 1.0))
	atmos_report["light"] = light_name
	atmos_report["blend"] = blend_report
	atmos_report["fog"] = {"enabled": env.fog_enabled, "depth_begin": env.fog_depth_begin, "depth_end": env.fog_depth_end, "color": env.fog_light_color.to_html(false)}

static func _mul(c: Color, k: float, tint: Variant) -> Color:
	var out: Color = Color(c.r * k, c.g * k, c.b * k)
	if tint is Array and (tint as Array).size() >= 3:
		var t: Array = tint
		out = Color(out.r * float(t[0]), out.g * float(t[1]), out.b * float(t[2]))
	elif tint is String:
		var tc: Color = Color.html(str(tint))
		out = Color(out.r * tc.r, out.g * tc.g, out.b * tc.b)
	return Color(clampf(out.r, 0.0, 1.0), clampf(out.g, 0.0, 1.0), clampf(out.b, 0.0, 1.0))

## Godot's ACES (4.x tonemap.glsl) forward curve.
static func aces(x: Vector3, white: float) -> Vector3:
	var bias: float = 1.8
	var a: float = 0.0245786
	var b: float = 0.000090537
	var c: float = 0.983729
	var d: float = 0.432951
	var e: float = 0.238081
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

static func _rrt(v: float, a: float, b: float, c: float, d: float, e: float) -> float:
	return (v * (v + a) - b) / (v * (c * v + d) + e)

## Forward display model of a linear scene colour (what the floor outputs before tonemapping).
static func _display(x: Vector3, env: Environment) -> Color:
	var y: Vector3 = x * env.tonemap_exposure
	if env.tonemap_mode == Environment.TONE_MAPPER_ACES:
		y = aces(y, env.tonemap_white)
	y = y.clamp(Vector3.ZERO, Vector3.ONE)
	var c: Color = Color(y.x, y.y, y.z).linear_to_srgb()
	if env.adjustment_enabled:
		var v: Vector3 = Vector3(c.r, c.g, c.b) * env.adjustment_brightness
		v = Vector3(0.5, 0.5, 0.5).lerp(v, env.adjustment_contrast)
		var g: float = (v.x + v.y + v.z) / 3.0
		v = Vector3(g, g, g).lerp(v, env.adjustment_saturation)
		c = Color(v.x, v.y, v.z)
	return c

static func _solve_display(target: Color, env: Environment) -> Vector3:
	var lin: Color = target.srgb_to_linear()
	var x: Vector3 = Vector3(lin.r, lin.g, lin.b)
	for _sweep: int in 6:
		for ch: int in 3:
			var lo: float = 0.0
			var hi: float = 16.0
			for _it: int in 22:
				var mid: float = (lo + hi) * 0.5
				var probe: Vector3 = x
				probe[ch] = mid
				var d: Color = _display(probe, env)
				var got: float = d.r if ch == 0 else (d.g if ch == 1 else d.b)
				var want: float = target.r if ch == 0 else (target.g if ch == 1 else target.b)
				if got < want:
					lo = mid
				else:
					hi = mid
			x[ch] = (lo + hi) * 0.5
	return x
