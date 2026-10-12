extends Node3D
## 第四幕「L叔在哪儿」· cheap global life for one tile (look.json section "life" = probe L3; nothing keyed by tile id).
## Driven by tile data every recipe already has (fires[], lamps[], smoke[]):
##   fire lights : one OmniLight per fires[] entry (fires.* in look.json), flicker per frame
##   fire        : act-3 camp fire module (scripts/traveler/baghdad/baghdad_camp_fire.gd, preloaded, not copied:
##                 flame cards + sparks) on every fires[] entry, sized by the entry's scale, plus an emissive coal
##                 bed; the web's icosahedron flames only when fires.flame is true (off in the approved look)
##   lamp lights : one OmniLight per lamps[] point (lamps.*), plus a small flicker and an aura quad behind it
##   smoke       : chimney puffs from smoke[], faint wisps above camp fires; all puffs are instances of one
##                 MultiMesh (fix #4: one draw call for the whole smoke)
## The character-side parts (rim, contact shadow, cup, potato flowers) live in lshu_character.gd.
## Fire level (P1 director, set_fire_level): 1 = burning, exactly the approved look (nothing is touched at 1); lower
## = dying down (he went into the tent: low; he left the tile: embers). Flames and sparks shrink with the level, the
## fire light follows it, the coal bed keeps glowing a little dimmer, the fire smoke thins. Numbers come from the
## caller (data/traveler/lshu/director.json fire.*).

const CAMP_FIRE_SCRIPT: GDScript = preload("res://scripts/traveler/baghdad/baghdad_camp_fire.gd")
const SMOKE_SHADER: Shader = preload("res://shaders/traveler/lshu/lshu_smoke.gdshader")
const HALO_SHADER: Shader = preload("res://shaders/traveler/lshu/lshu_halo.gdshader")
const FLOOR_LAYER: int = 1 << 19

static var _puff_mesh: SphereMesh
static var _halo_quad: QuadMesh

var look: RefCounted
var life: Dictionary = {}
var fire_lights: Array[OmniLight3D] = []
var lamp_lights: Array[OmniLight3D] = []
var flames: Array[Dictionary] = []
var fires: Array[Dictionary] = []
var smoke_emitters: Array[Dictionary] = []
var smoke_material_all: ShaderMaterial
var smoke_batches: Dictionary = {}
var halos: Array[Dictionary] = []
var halo_material: ShaderMaterial
var report: Dictionary = {}
var fire_level: float = 1.0
var fire_shape: Dictionary = {}

static func puff_mesh() -> SphereMesh:
	if _puff_mesh == null:
		_puff_mesh = SphereMesh.new()
		_puff_mesh.radius = 0.5
		_puff_mesh.height = 1.0
		_puff_mesh.radial_segments = 7
		_puff_mesh.rings = 4
	return _puff_mesh

func g(path: Array, fallback: Variant) -> Variant:
	var d: Variant = life
	for k: Variant in path:
		if not d is Dictionary or not (d as Dictionary).has(k):
			return fallback
		d = (d as Dictionary)[k]
	return d

static func colr(v: Variant, fallback: Color) -> Color:
	if v is String:
		return Color.html(str(v))
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return fallback

static func v3(v: Variant, fallback: Vector3) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback

## Builds every effect of the tile. Call once, before the tile is shown.
func build(look_ref: RefCounted, tile: Dictionary, motion_frozen: bool) -> void:
	name = "Life"
	look = look_ref
	var cfg: Dictionary = look.get("cfg")
	life = cfg.get("life", {})
	var fires_cfg: Dictionary = cfg.get("fires", {})
	for f: Dictionary in tile.get("fires", []):
		var center: Vector3 = v3(f.get("flame_center", f.position), Vector3.ZERO)
		var light: OmniLight3D = OmniLight3D.new()
		light.name = "FireLight_%d" % fire_lights.size()
		light.position = center + Vector3(0.0, float(fires_cfg.get("light_lift", 0.15)), 0.0)
		light.light_cull_mask = 0xFFFFF & ~FLOOR_LAYER
		add_child(light)
		fire_lights.append(light)
		if bool(fires_cfg.get("flame", true)):
			_build_flame(v3(f.position, Vector3.ZERO), float(f.get("scale", 0.6)), str(f.get("source", "")) != "camp_kit")
	for p: Variant in tile.get("lamps", []):
		var lamp: OmniLight3D = OmniLight3D.new()
		lamp.name = "LampLight_%d" % lamp_lights.size()
		lamp.position = v3(p, Vector3.ZERO)
		lamp.light_cull_mask = 0xFFFFF & ~FLOOR_LAYER
		add_child(lamp)
		lamp_lights.append(lamp)
	_setup_fires(tile)
	_setup_smoke(tile)
	_setup_lanterns(tile)
	on_light()
	tick(float((cfg.get("motion", {}) as Dictionary).get("freeze_time_s", 2.5)) if motion_frozen else 0.0, motion_frozen)

## The web draws flames as three emissive icosahedra (only used when look fires.flame is true).
func _build_flame(pos: Vector3, scale_value: float, effect_point: bool) -> void:
	var colors: Array[Color] = [Color.html("#ed792d"), Color.html("#ffc34c"), Color.html("#fff0a8")]
	var root: Node3D = Node3D.new()
	root.name = "Flame_%d" % flames.size()
	root.position = pos
	add_child(root)
	for i: int in 3:
		var m: SphereMesh = SphereMesh.new()
		m.radius = 1.0
		m.height = 2.0
		m.radial_segments = 6
		m.rings = 3
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

# ------------------------------------------------------------------ fires (act-3 camp fire on every fires[] entry)
func _setup_fires(tile: Dictionary) -> void:
	if not bool(g(["fire", "enabled"], true)):
		return
	var per_h: float = float(g(["fire", "flame_height_per_scale"], 0.62))
	var per_w: float = float(g(["fire", "flame_width_per_scale"], 0.42))
	var lift: float = float(g(["fire", "base_lift_per_scale"], 0.11))
	var effect_mult: float = float(g(["fire", "effect_point_mult"], 0.7))
	var i: int = 0
	for f: Dictionary in tile.get("fires", []):
		var sc: float = float(f.get("scale", 0.55))
		var effect_point: bool = str(f.get("source", "")) != "camp_kit"
		var m: float = effect_mult if effect_point else 1.0
		var node: Node3D = CAMP_FIRE_SCRIPT.new() as Node3D
		node.name = "CampFire_%d" % i
		var fh: float = per_h * sc * m
		var fw: float = per_w * sc * m
		node.call("configure", {
			"flame_height_u": fh, "flame_width_u": fw, "flame_count": int(g(["fire", "flame_count"], 5)),
			"spark_amount": int(g(["fire", "spark_amount"], 10)), "spark_lifetime_s": float(g(["fire", "spark_lifetime_s"], 1.4)),
			"spark_size_u": float(g(["fire", "spark_size_per_scale"], 0.028)) * sc * m,
			"spark_speed_min_u_s": 0.25 * sc * m, "spark_speed_max_u_s": 0.55 * sc * m, "spark_spread_deg": 22.0,
			"light_energy": 0.0, "seed": 20260923 + i,
		})
		var pos: Vector3 = v3(f.get("position"), Vector3.ZERO)
		node.position = pos + Vector3(0.0, (0.02 if effect_point else lift) * sc * m, 0.0)
		add_child(node)
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
		if bool(g(["fire", "coals"], true)) and not effect_point:
			var coal: MeshInstance3D = MeshInstance3D.new()
			var cm: CylinderMesh = CylinderMesh.new()
			cm.top_radius = fw * 0.55
			cm.bottom_radius = fw * 0.62
			cm.height = 0.02
			cm.radial_segments = 7
			cm.rings = 1
			var cmat: StandardMaterial3D = StandardMaterial3D.new()
			cmat.albedo_color = Color.html("#3a1d10")
			cmat.emission_enabled = true
			cmat.emission = Color.html("#ff5a1a")
			cm.material = cmat
			coal.mesh = cm
			coal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			coal.position = node.position + Vector3(0.0, 0.005, 0.0)
			add_child(coal)
			rec["coal_mat"] = cmat
		fires.append(rec)
		i += 1
	var fire_records: Array = []
	for r: Dictionary in fires:
		fire_records.append({"scale": r.scale, "effect_point": r.effect, "flame_h_m": r.flame_h})
	report["fires"] = fire_records

## Camp-fire centres usable as a local key light (non-effect-point fires): world positions at mid flame height.
func camp_fire_keys() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for f: Dictionary in fires:
		if not bool(f.effect):
			out.append((f.pos as Vector3) + Vector3(0.0, float(f.flame_h) * 0.5, 0.0))
	return out

## Director: how much the fire still burns (1 = the approved look, lower = low / embers). shape (optional):
## {flame_width_min, coal_min, smoke_min, spark_from} - how the parts follow the level. Cheap; call it every frame.
func set_fire_level(level: float, shape: Dictionary = {}) -> void:
	var lv: float = clampf(level, 0.0, 1.0)
	if not shape.is_empty():
		fire_shape = shape
	if is_equal_approx(lv, fire_level):
		return
	fire_level = lv
	var full: bool = fire_level >= 1.0
	var w: float = 1.0 if full else lerpf(float(fire_shape.get("flame_width_min", 0.55)), 1.0, fire_level)
	var spark_from: float = float(fire_shape.get("spark_from", 0.15))
	for f: Dictionary in fires:
		var node: Node3D = f.node
		var bank: Node3D = node.get("flame_bank") as Node3D
		if bank != null:
			bank.scale = Vector3.ONE if full else Vector3(w, maxf(fire_level, 0.001), w)
			bank.visible = full or fire_level > 0.02
		var sp: GPUParticles3D = node.get("sparks") as GPUParticles3D
		if sp != null:
			sp.amount_ratio = 1.0 if full else clampf((fire_level - spark_from) / maxf(1.0 - spark_from, 0.01), 0.0, 1.0)
	for fl_rec: Dictionary in flames:
		(fl_rec.node as MeshInstance3D).visible = full or fire_level > 0.02

func _fire_light_factor() -> float:
	return 1.0 if fire_level >= 1.0 else fire_level

func _coal_factor() -> float:
	return 1.0 if fire_level >= 1.0 else lerpf(float(fire_shape.get("coal_min", 0.6)), 1.0, fire_level)

func _smoke_factor(kind: String) -> float:
	if kind != "fire" or fire_level >= 1.0:
		return 1.0
	return lerpf(float(fire_shape.get("smoke_min", 0.5)), 1.0, fire_level)

# ------------------------------------------------------------------ smoke / steam puffs (fix #4: one draw)
## Every puff of every emitter (chimney, camp-fire wisps, cup steam) is one instance of a single MultiMesh per render
## layer (normally one), so the whole smoke costs one draw call. Kind colours are uniform arrays; per-puff opacity,
## warmth and kind ride in INSTANCE_CUSTOM. Separate transparent meshes were depth-sorted by the renderer; the
## instances of one MultiMesh are not, so tick() writes them back to front.
const SMOKE_KINDS: Array[String] = ["chimney", "fire", "steam"]

func smoke_material() -> ShaderMaterial:
	if smoke_material_all == null:
		smoke_material_all = ShaderMaterial.new()
		smoke_material_all.shader = SMOKE_SHADER
		_push_smoke_uniforms()
	return smoke_material_all

## Registers an emitter of life.smoke.<kind>.puffs puffs at base (this node's space). The returned Dictionary is
## live: the caller may move its "base" every frame (the cup steam does). parent is kept for the callers' API; the
## puffs always draw from this node's batch for the given render layer.
func make_emitter(kind: String, base: Vector3, scale_value: float, _parent: Node3D, layer: int) -> Dictionary:
	var kind_index: int = SMOKE_KINDS.find(kind)
	if kind_index < 0:
		push_error("LSHU smoke kind not supported: " + kind)
		return {}
	var e: Dictionary = {"kind": kind, "kind_index": kind_index, "base": base, "scale": scale_value, "layer": layer,
		"count": int(g(["smoke", kind, "puffs"], 7)), "phase": base.x * 1.7 + base.z * 0.9}
	smoke_emitters.append(e)
	if not smoke_batches.has(layer):
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = puff_mesh()
		var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
		mmi.name = "Smoke_%d" % smoke_batches.size()
		mmi.multimesh = mm
		mmi.material_override = smoke_material()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.layers = layer
		add_child(mmi)
		smoke_batches[layer] = mmi
	var puffs: int = 0
	for se: Dictionary in smoke_emitters:
		puffs += int(se.count)
	report["smoke"] = {"emitters": smoke_emitters.size(), "puffs": puffs, "draw_batches": smoke_batches.size()}
	return e

func _setup_smoke(tile: Dictionary) -> void:
	var smoke: Array = tile.get("smoke", [])
	if bool(g(["smoke", "chimney", "enabled"], true)) and not smoke.is_empty():
		make_emitter("chimney", v3(smoke[0], Vector3.ZERO) + Vector3(0.0, -0.12, 0.0), 1.0, self, 1)
	if bool(g(["smoke", "fire", "enabled"], true)):
		for f: Dictionary in fires:
			if bool(f.effect):
				continue
			var above: float = float(g(["smoke", "fire", "start_above_flame"], 0.9))
			make_emitter("fire", (f.pos as Vector3) + Vector3(0.0, float(f.flame_h) * above, 0.0), float(f.scale) / 0.55, self, 1)

func _push_smoke_uniforms() -> void:
	if smoke_material_all == null:
		return
	var cols: PackedVector3Array = PackedVector3Array()
	var warms: PackedVector3Array = PackedVector3Array()
	var lits: PackedFloat32Array = PackedFloat32Array()
	for kind: String in SMOKE_KINDS:
		# linear, as the renderer converts a source_color uniform
		var c: Color = colr(g(["smoke", kind, "color"], "#d8ddd8"), Color(0.85, 0.87, 0.85)).srgb_to_linear()
		var w: Color = colr(g(["smoke", kind, "warm_color"], "#ff8a40"), Color(1.0, 0.54, 0.25)).srgb_to_linear()
		cols.append(Vector3(c.r, c.g, c.b))
		warms.append(Vector3(w.r, w.g, w.b))
		lits.append(float(g(["smoke", kind, "self_lit"], 0.0)))
	smoke_material_all.set_shader_parameter("puff_colors", cols)
	smoke_material_all.set_shader_parameter("warm_colors", warms)
	smoke_material_all.set_shader_parameter("self_lits", lits)

func _update_smoke(t: float) -> void:
	if smoke_batches.is_empty():
		return
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	var to_world: Transform3D = global_transform if is_inside_tree() else Transform3D.IDENTITY
	var rows_by_layer: Dictionary = {}
	var order: int = 0
	for e: Dictionary in smoke_emitters:
		var kind: String = e.kind
		var n: int = int(e.count)
		var sc: float = float(e.scale)
		var rise: float = float(g(["smoke", kind, "rise_m"], 1.3)) * sc
		var drift: Vector3 = v3(g(["smoke", kind, "drift_m"], [0.3, 0.0, -0.1]), Vector3(0.3, 0, -0.1)) * sc
		var speed: float = float(g(["smoke", kind, "speed"], 0.12))
		var s0: float = float(g(["smoke", kind, "size_start_m"], 0.12)) * sc
		var s1: float = float(g(["smoke", kind, "size_end_m"], 0.34)) * sc
		var alpha: float = float(g(["smoke", kind, "alpha"], 0.4)) * _smoke_factor(kind)
		var warm: float = float(g(["smoke", kind, "warm"], 0.0))
		var wobble: float = float(g(["smoke", kind, "wobble_m"], 0.05)) * sc
		var base: Vector3 = e.base
		var rows: Array = rows_by_layer.get_or_add(int(e.layer), [])
		for k: int in n:
			var u: float = fposmod(t * speed + float(k) / float(n) + float(e.phase) * 0.013, 1.0)
			# per-puff jitter (stable per index) so the column does not read as a stack of equal beads
			var rk: float = fposmod(sin(float(k) * 12.9898 + float(e.phase)) * 43758.5453, 1.0)
			var rk2: float = fposmod(sin(float(k) * 78.233 + float(e.phase)) * 12543.853, 1.0)
			var curve: float = u * u * 0.6 + u * 0.4
			var p: Vector3 = base + Vector3(drift.x * curve + sin(t * 0.7 + k * 1.9 + float(e.phase)) * wobble * u + (rk - 0.5) * wobble * 2.0 * u, rise * u, drift.z * curve + cos(t * 0.55 + k * 1.3) * wobble * u + (rk2 - 0.5) * wobble * 2.0 * u)
			var s: float = lerpf(s0, s1, sqrt(u)) * (0.8 + 0.4 * rk2)
			# same composition as a Node3D (rotation YXZ, then local scale)
			var xf: Transform3D = Transform3D(Basis.from_euler(Vector3(k * 0.7, t * 0.2 + k, k * 0.4)) * Basis.from_scale(Vector3(s, s * 0.85, s)), p)
			var a: float = alpha * smoothstep(0.0, 0.12, u) * pow(1.0 - u, 1.3)
			var depth: float = 0.0
			if cam != null:
				depth = (to_world * p - cam.global_position).dot(-cam.global_basis.z)
			rows.append([depth, order, xf, Color(a, warm * (1.0 - u) * (1.0 - u), float(e.kind_index), 0.0)])
			order += 1
	for layer: Variant in smoke_batches.keys():
		var mm: MultiMesh = (smoke_batches[layer] as MultiMeshInstance3D).multimesh
		var rows: Array = rows_by_layer.get(layer, [])
		rows.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) > float(y[0]) or (float(x[0]) == float(y[0]) and int(x[1]) < int(y[1])))
		if mm.instance_count != rows.size():
			mm.instance_count = rows.size()
		for i: int in rows.size():
			var row: Array = rows[i]
			var row_xf: Transform3D = row[2]
			var row_custom: Color = row[3]
			mm.set_instance_transform(i, row_xf)
			mm.set_instance_custom_data(i, row_custom)

# ------------------------------------------------------------------ lanterns
func _setup_lanterns(tile: Dictionary) -> void:
	var lamps: Array = tile.get("lamps", [])
	if lamps.is_empty() or not bool(g(["lanterns", "enabled"], true)):
		return
	halo_material = ShaderMaterial.new()
	halo_material.shader = HALO_SHADER
	if _halo_quad == null:
		_halo_quad = QuadMesh.new()
		_halo_quad.size = Vector2.ONE
	var i: int = 0
	for p: Variant in lamps:
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = "LanternHalo_%d" % i
		mi.mesh = _halo_quad
		mi.material_override = halo_material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = v3(p, Vector3.ZERO)
		mi.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
		add_child(mi)
		halos.append({"node": mi, "phase": float(i) * 2.3})
		i += 1

# ------------------------------------------------------------------ per light / per frame
## After look.apply(): re-read the life section and push per-light values.
func on_light() -> void:
	var cfg: Dictionary = look.get("cfg")
	life = cfg.get("life", {})
	var flame_energy: float = float((cfg.get("fires", {}) as Dictionary).get("flame_emission", 1.5))
	for fl_rec: Dictionary in flames:
		(fl_rec.material as StandardMaterial3D).emission_energy_multiplier = flame_energy
	for f: Dictionary in fires:
		if f.has("coal_mat"):
			(f.coal_mat as StandardMaterial3D).emission_energy_multiplier = float(g(["fire", "coal_emission"], 1.0))
	_push_smoke_uniforms()
	if halo_material != null:
		halo_material.set_shader_parameter("halo_color", colr(g(["lanterns", "halo_color"], "#ffb66e"), Color(1.0, 0.71, 0.43)))
		halo_material.set_shader_parameter("halo_strength", float(g(["lanterns", "halo_strength"], 0.0)))
		halo_material.set_shader_parameter("halo_falloff", float(g(["lanterns", "halo_falloff"], 3.2)))
		halo_material.set_shader_parameter("toward_camera_m", float(g(["lanterns", "halo_toward_camera_m"], 0.25)))
		var hs: float = float(g(["lanterns", "halo_size_m"], 0.6))
		for hrec: Dictionary in halos:
			(hrec.node as MeshInstance3D).scale = Vector3.ONE * hs
			(hrec.node as MeshInstance3D).visible = float(g(["lanterns", "halo_strength"], 0.0)) > 0.0

## Per frame with the scene clock t (held still under --motion-freeze).
func tick(t: float, motion_frozen: bool) -> void:
	var cfg: Dictionary = look.get("cfg")
	var fires_cfg: Dictionary = cfg.get("fires", {})
	for f: Dictionary in flames:
		var mi: MeshInstance3D = f.node
		var s: Vector3 = f.scale
		mi.scale = Vector3(s.x, s.y * (0.94 + 0.12 * sin(t * 8.0 + float(f.phase))) * _fire_light_factor(), s.z)
		mi.rotation.z = sin(t * 4.0 + float(f.phase)) * 0.08
	var flicker: float = float(fires_cfg.get("flicker", 0.12))
	var fire_energy: float = float(fires_cfg.get("light_energy", 0.6))
	for i: int in fire_lights.size():
		fire_lights[i].light_energy = fire_energy * (1.0 + flicker * sin(t * 7.3 + i * 1.3) * sin(t * 3.1 + i)) * _fire_light_factor()
	for f: Dictionary in fires:
		(f.node as Node3D).call("set_anim_time", t)
		# the act-3 module parks its sparks while frozen; follow the scene's motion switch instead
		var sp: GPUParticles3D = (f.node as Node3D).get("sparks") as GPUParticles3D
		if sp != null:
			sp.speed_scale = 0.0 if motion_frozen else 1.0
		if f.has("coal_mat"):
			var ce: float = float(g(["fire", "coal_emission"], 1.0))
			(f.coal_mat as StandardMaterial3D).emission_energy_multiplier = ce * (0.85 + 0.15 * sin(t * 2.3 + float(f.scale) * 5.0)) * _coal_factor()
	_update_smoke(t)
	var flick: float = float(g(["lanterns", "flicker"], 0.0))
	if flick > 0.0:
		var base_e: float = float((cfg.get("lamps", {}) as Dictionary).get("light_energy", 0.5))
		for li: int in lamp_lights.size():
			var w: float = 1.0 + flick * (sin(t * 5.3 + li * 2.1) * 0.6 + sin(t * 11.7 + li) * 0.4)
			lamp_lights[li].light_energy = base_e * w
		for hrec: Dictionary in halos:
			(hrec.node as MeshInstance3D).set_instance_shader_parameter("halo_flicker", 1.0 + flick * sin(t * 5.3 + float(hrec.phase)) * 0.8)
