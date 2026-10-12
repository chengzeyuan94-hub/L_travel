extends Node3D
## 第四幕「L叔在哪儿」· decision 4 (recommended default): at night L叔 always has a camp lantern near him.
## Existing lantern props only (pool.json night_lamp.assets), no new model, his appearance unchanged. One global
## rule, nothing keyed by a tile id (look.json common.night_lamp holds the numbers):
##  - not needed when a fire or a lamp light of the tile is within near_radius_m of him (horizontal distance)
##  - an unlit lantern prop of the tile (instance role "lamp") that close and on his camera side (within
##    front_max_deg of the camera direction) gets the light; no second prop
##  - otherwise one lantern prop (a lantern kind the tile already uses, else a stable hash of the tile id over
##    the pool's list) is set on the ground next to him: the first free spot of fixed rings around him, ordered by
##    how far the angle to the camera direction is from angle_pref_deg (camera side, never straight between him and
##    the camera) and the distance from ring_pref_m,
##    inside the tile edge, off every path, out of water, clear of every placed asset / fire / his feet / the
##    tile's reserved features, on level ground, not covering him on screen and not hidden behind an asset nearer
##    the camera. The prop faces the camera. When
##    he stands on a built support (a pier: the tile reservation whose kind is his support), the spot must be on
##    it and the prop stands at his feet height.
##  - light: one small warm OmniLight without shadow at the prop's glow parts (the tile's floor layer excluded,
##    like every lamp), energy x night weight, a faint flicker and a halo like the tile's own lanterns; plus the
##    same lamp once more on his own render layer only (character_energy), so the lantern reads stronger on him
##    than on the ground pool around him (the stylised key that makes him the brightest thing at the camp), faded
##    out with the sand weight of the ground under him (on bright warm sand he already reads as the dark figure). The
##    prop's glow surfaces use the shared glow role, so they follow the light presets like every other lantern.
## The scene builds it after the camera fit (setup): for a staged tile it plans it hidden before the swap, from the
## rig as it will stand there (subject_of()) and a camera fitted the same way, and keeps it when the swap frame finds
## the same subject and camera (verify_r2 item 1); it calls set_night_weight() after every light change and tick()
## every frame. The P1 director may hold the prop in place for a whole stay that reaches into
## the night (set_hold) so it is set down on arrival instead of appearing at dusk, and hides it while he is away
## (set_present).

const ASSEMBLER: GDScript = preload("res://scripts/traveler/lshu/lshu_tile_assembler.gd")
const GROUND_INFO: GDScript = preload("res://scripts/traveler/lshu/lshu_ground_info.gd")
const CLOCK: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const HALO_SHADER: Shader = preload("res://shaders/traveler/lshu/lshu_halo.gdshader")
const POOL_PATH: String = "res://data/traveler/lshu/pool.json"
const PROPS_DIR: String = "res://assets/traveler/lshu/props/"
const FLOOR_LAYER: int = 1 << 19

static var _pool_assets: Array[String] = []
static var _pool_read: bool = false
static var _halo_quad: QuadMesh

var look: RefCounted
var cfg: Dictionary = {}
var mode: String = "none"           # none | existing | placed | light_only
var prop: Node3D                    # the lantern (owned when mode == placed)
var light: OmniLight3D
var key: OmniLight3D                # the same lamp, on his render layer only
var halo: MeshInstance3D
var halo_material: ShaderMaterial
var light_point: Vector3 = Vector3.ZERO
var night_weight: float = 0.0
var key_factor: float = 1.0         # share of character_energy for this spot (0 on bright sand)
var hold: bool = false
var present: bool = true
## Director: 1 normally; eased to 0 over a couple of seconds as he leaves at night (he takes his lantern), then
## set_present(false). Scales the lamp light, his key light and the halo; the prop stays until set_present(false).
var presence_fade: float = 1.0
var report: Dictionary = {}
var _blocker: String = ""

## The pool's lantern props (pool.json night_lamp.assets).
static func pool_assets() -> Array[String]:
	if not _pool_read:
		_pool_read = true
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(POOL_PATH))
		if parsed is Dictionary:
			for a: Variant in ((parsed as Dictionary).get("night_lamp", {}) as Dictionary).get("assets", []):
				_pool_assets.append(str(a))
	return _pool_assets

## Scene paths of the pool's lantern props, requested on a worker thread (the live scene's prewarm collects them).
static func prefetch() -> Array[String]:
	var paths: Array[String] = []
	for a: String in pool_assets():
		var p: String = PROPS_DIR + a + ".glb"
		paths.append(p)
		# through the assembler's cache-aware request: a second request for a scene it already holds would leave a
		# load token nobody collects (a leaked RefCounted at exit)
		ASSEMBLER.call("_request", p)
	return paths

## What the lamp rule reads of him (the character module's active rig, after the camera fit and finish()): his
## spot, his pose, where his feet are (the contact shadow) and his height scale. {} when no rig is active.
static func subject_of(character: Node3D) -> Dictionary:
	var rig: Node3D = character.get("active") as Node3D if character != null else null
	if rig == null:
		return {}
	var him: Vector3 = (rig.get("character") as Node3D).global_position
	var decal: Decal = rig.get("contact_decal") as Decal
	return {"him": him, "pose": str(rig.get("pose")), "feet": decal.global_position if decal != null else him,
		"hscale": float(character.get("height_m")) / 1.15}

## Decides and builds the lamp for the tile (after the camera fit and character.finish()). subject: subject_of() taken
## earlier (the scene plans a staged tile); empty = read the character now.
func setup(look_ref: RefCounted, tile: Node3D, character: Node3D, camera: Camera3D, enabled: bool = true, subject: Dictionary = {}) -> Dictionary:
	name = "NightLamp"
	look = look_ref
	cfg = look.call("sec", "night_lamp")
	var t0: int = Time.get_ticks_usec()
	report = {"mode": "none"}
	if not enabled or not bool(cfg.get("enabled", true)):
		report["reason"] = "off"
		return report
	var sub: Dictionary = subject if not subject.is_empty() else subject_of(character)
	if sub.is_empty():
		report["reason"] = "no character"
		return report
	var him: Vector3 = sub.him
	var td: Dictionary = tile.get("tile")
	var near_r: float = float(cfg.get("near_radius_m", 1.5))
	# 1. a fire or a lamp light already near him
	var nearest: Dictionary = {"kind": "", "dist_m": INF}
	for f: Variant in td.get("fires", []):
		var fp: Vector3 = _v3((f as Dictionary).get("position"))
		var d: float = _dxz(him, fp)
		if d < float(nearest.dist_m):
			nearest = {"kind": "fire", "dist_m": d}
	for lp: Variant in td.get("lamps", []):
		var d2: float = _dxz(him, _v3(lp))
		if d2 < float(nearest.dist_m):
			nearest = {"kind": "lamp", "dist_m": d2}
	report["nearest_light"] = nearest if float(nearest.dist_m) < INF else {}
	report["near_radius_m"] = near_r
	if float(nearest.dist_m) <= near_r:
		report["reason"] = "%s within %.2f m" % [nearest.kind, float(nearest.dist_m)]
		return report
	# 2. an unlit lantern prop of the tile near him and on his camera side (its light reaches the side we see)
	var best_prop: Dictionary = {}
	var to_cam: Vector3 = _to_camera(him, camera)
	var front_max: float = float(cfg.get("front_max_deg", 75.0))
	for rec: Dictionary in tile.get("instance_nodes"):
		if str((rec.data as Dictionary).get("role", "")) != "lamp":
			continue
		var pp: Vector3 = (rec.node as Node3D).global_position
		var d3: float = _dxz(him, pp)
		var off: Vector3 = Vector3(pp.x - him.x, 0.0, pp.z - him.z)
		var ang: float = rad_to_deg(off.angle_to(to_cam)) if off.length() > 0.001 else 0.0
		report["unlit_prop"] = {"dist_m": d3, "angle_to_camera_deg": ang}
		if d3 <= near_r and ang <= front_max and (best_prop.is_empty() or d3 < float(best_prop.dist)):
			best_prop = {"rec": rec, "dist": d3}
	if not best_prop.is_empty():
		mode = "existing"
		prop = (best_prop.rec as Dictionary).node
		light_point = _glow_point((best_prop.rec as Dictionary).meshes, prop)
		report["reason"] = "unlit lantern prop within %.2f m gets the light" % float(best_prop.dist)
		report["prop_dist_m"] = float(best_prop.dist)
		report["asset"] = str((best_prop.rec.data as Dictionary).get("asset_id", ""))
	else:
		_place(tile, td, sub, him, camera, float(sub.hscale))
	if mode != "none":
		key_factor = _key_factor(tile, him)
		report["key_factor"] = key_factor
		_build_light()
		report["mode"] = mode
		report["light_point"] = [light_point.x, light_point.y, light_point.z]
		report["light_dist_m"] = _dxz(him, light_point)
	report["ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	return report

# ------------------------------------------------------------------ placement rule
func _place(tile: Node3D, td: Dictionary, sub: Dictionary, him: Vector3, camera: Camera3D, hscale: float) -> void:
	var asset: String = _pick_asset(tile, td)
	if asset.is_empty():
		report["reason"] = "pool.json night_lamp.assets is empty"
		mode = "light_only"
		light_point = him + _to_camera(him, camera) * 0.6 + Vector3(0.0, 0.3, 0.0)
		return
	var packed: PackedScene = ASSEMBLER.call("_scene", PROPS_DIR + asset + ".glb") as PackedScene
	if packed == null:
		push_error("LSHU night lamp prop missing or not imported: " + asset)
		mode = "none"
		return
	var holder: Node3D = Node3D.new()
	holder.name = "NightLampProp"
	var inst: Node3D = packed.instantiate() as Node3D
	holder.add_child(inst)
	add_child(holder)
	var sc: float = float(cfg.get("prop_scale", 0.85))
	holder.scale = Vector3.ONE * sc
	var meshes: Array[MeshInstance3D] = []
	for node: Node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node as MeshInstance3D
		meshes.append(mi)
		_assign_surfaces(mi)
	# footprint of the prop at its scale, from its meshes at the origin
	var local_box: AABB = AABB()
	var first: bool = true
	for mi2: MeshInstance3D in meshes:
		var bb: AABB = holder.global_transform.affine_inverse() * (mi2.global_transform * mi2.get_aabb())
		local_box = bb if first else local_box.merge(bb)
		first = false
	var radius: float = maxf(local_box.size.x, local_box.size.z) * 0.5 * sc
	var height: float = local_box.size.y * sc
	var to_cam: Vector3 = _to_camera(him, camera)
	# his screen box: a pose-independent proxy (an upright box of his height at his spot), because the posed skin is
	# only evaluated after the swap frame
	var body_px: Dictionary = {}
	if camera != null:
		var body_box: AABB = AABB(him + Vector3(-0.15, 0.0, -0.15) * hscale, Vector3(0.3 * hscale, height_m_for(str(sub.pose), hscale), 0.3 * hscale))
		var br: Rect2 = _box_rect(camera, body_box)
		body_px = {"bounds_px": [br.position.x, br.position.y, br.end.x, br.end.y]}
	var feet: Vector3 = sub.feet
	# he may stand on a built surface (pier, deck, ...): the reservation whose kind is his support; spots on it
	# stand at his feet height instead of on the terrain under it
	var deck: Dictionary = {}
	var support: String = str((td.get("character", {}) as Dictionary).get("support", "ground"))
	if not support.is_empty() and support != "ground":
		for rv: Variant in td.get("reservations", []):
			if rv is Dictionary and str((rv as Dictionary).get("kind", "")) == support:
				deck = rv
		report["support"] = support
	var tried: int = 0
	var rejects: Dictionary = {}
	var blockers: Dictionary = {}
	var chosen: Dictionary = {}
	# candidates: every ring distance x every angle, cheapest first (angle off the preferred camera-side angle, then
	# distance off the preferred ring), so a camera-side spot a little further out wins over one behind him
	var cands: Array = []
	var pref_a: float = float(cfg.get("angle_pref_deg", 55.0))
	var pref_r: float = float(cfg.get("ring_pref_m", 0.6))
	var unit_a: float = maxf(float(cfg.get("angle_cost_deg", 15.0)), 0.001)
	var unit_r: float = maxf(float(cfg.get("ring_cost_m", 0.12)), 0.001)
	var order: int = 0
	for r: Variant in cfg.get("ring_m", [0.6]):
		for a: Variant in cfg.get("angles_deg", [55, -55]):
			cands.append({"r": float(r), "a": float(a), "cost": absf(absf(float(a)) - pref_a) / unit_a + absf(float(r) - pref_r) / unit_r, "order": order})
			order += 1
	cands.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x.cost) < float(y.cost) or (float(x.cost) == float(y.cost) and int(x.order) < int(y.order)))
	for relax: int in 3:
		for c: Dictionary in cands:
			var dir: Vector3 = to_cam.rotated(Vector3.UP, deg_to_rad(float(c.a)))
			var p: Vector3 = him + dir * float(c.r) * hscale
			tried += 1
			var why: String = _reject(tile, td, p, radius, height, feet, body_px, camera, relax, deck, him)
			if why.is_empty():
				chosen = {"p": p, "ring_m": float(c.r), "angle_deg": float(c.a), "relax": relax}
				break
			rejects[why] = int(rejects.get(why, 0)) + 1
			if why == "asset":
				blockers[_blocker] = int(blockers.get(_blocker, 0)) + 1
		if not chosen.is_empty():
			break
	report["candidates_tried"] = tried
	report["him"] = [him.x, him.y, him.z]
	report["body_px"] = body_px.get("bounds_px", [])
	report["camera_px_size"] = [camera.get_viewport().get_visible_rect().size.x, camera.get_viewport().get_visible_rect().size.y] if camera != null else []
	report["rejects"] = rejects
	report["asset_blockers"] = blockers
	if chosen.is_empty():
		holder.queue_free()
		mode = "light_only"
		light_point = him + to_cam * 0.6 + Vector3(0.0, 0.3, 0.0)
		report["reason"] = "no free spot on the ring: light only"
		return
	var spot: Vector3 = chosen.p
	var on_deck: bool = _on_deck(deck, spot, radius)
	spot.y = him.y if on_deck else _base_height(tile, spot, radius)
	report["on_support"] = on_deck
	holder.global_position = spot
	holder.rotation.y = atan2(to_cam.x, to_cam.z)   # props face +Z: toward the camera
	prop = holder
	mode = "placed"
	light_point = _glow_point(meshes, holder)
	report.merge({"reason": "placed", "asset": asset, "spot": [spot.x, spot.y, spot.z], "ring_m": chosen.ring_m, "angle_to_camera_deg": chosen.angle_deg,
		"relax": chosen.relax, "prop_radius_m": radius, "prop_height_m": height})

## Why a spot is refused ("" = free). relax 1 drops the screen-overlap and reservation tests, relax 2 also the path test.
func _reject(tile: Node3D, td: Dictionary, p: Vector3, radius: float, height: float, feet: Vector3, body_px: Dictionary, camera: Camera3D, relax: int, deck: Dictionary, him: Vector3) -> String:
	var half: float = _num((td.get("tile", {}) as Dictionary).get("half"), 4.0)
	var edge: float = float(cfg.get("edge_margin_m", 0.3))
	if absf(p.x) > half - edge - radius or absf(p.z) > half - edge - radius:
		return "edge"
	var on_deck: bool = _on_deck(deck, p, radius)
	if not deck.is_empty() and not on_deck:
		return "off_support"
	# level ground and out of water
	var hs: Array[float] = []
	for o: Vector2 in [Vector2.ZERO, Vector2(radius, 0.0), Vector2(-radius, 0.0), Vector2(0.0, radius), Vector2(0.0, -radius)]:
		hs.append(float(tile.call("terrain_height", p.x + o.x, p.z + o.y)))
	if not on_deck and hs.max() - hs.min() > float(cfg.get("max_step_m", 0.06)):
		return "slope"
	var water: Variant = td.get("water")
	if water is Dictionary and not on_deck:
		var level: Variant = (water as Dictionary).get("level")
		if (level is float or level is int) and hs.min() < float(level) + float(cfg.get("water_margin_m", 0.03)):
			return "water"
	# his feet (seated: they reach forward of the seat), fires
	if _dxz(p, feet) < radius + float(cfg.get("feet_clearance_m", 0.12)) + 0.18:
		return "feet"
	for f: Variant in td.get("fires", []):
		if _dxz(p, _v3((f as Dictionary).get("position"))) < radius + float(cfg.get("fire_clearance_m", 0.45)):
			return "fire"
	# every placed asset (its world box on the ground plane)
	var clear: float = radius + float(cfg.get("clearance_m", 0.06))
	for rec: Dictionary in tile.get("instance_nodes"):
		for mi: MeshInstance3D in rec.meshes:
			if not _shown_on_tile(mi, tile):
				continue
			var bb: AABB = mi.global_transform * mi.get_aabb()
			if bb.size.y < 0.03:
				continue
			if p.x > bb.position.x - clear and p.x < bb.end.x + clear and p.z > bb.position.z - clear and p.z < bb.end.z + clear:
				_blocker = str((rec.node as Node).name)
				return "asset"
	for pk: Variant in td.get("peaks", []):
		var pd: Dictionary = pk
		if Vector2(p.x - _num(pd.get("x"), 0.0), p.z - _num(pd.get("z"), 0.0)).length() < _num(pd.get("radius"), 0.0) + radius:
			return "peak"
	if relax < 2:
		var margin: float = float(cfg.get("path_margin_m", 0.08))
		for path: Variant in td.get("paths", []):
			var pdict: Dictionary = path
			if _path_dist(p, pdict.get("points", [])) < _num(pdict.get("width"), 0.5) * 0.5 + margin + radius:
				return "path"
	if relax < 1:
		for rv: Variant in td.get("reservations", []):
			var rd: Dictionary = rv
			if str(rd.get("kind", "")) == "activity" or rd == deck:
				continue
			var ex: float = (p.x - _num(rd.get("x"), 0.0)) / (_num(rd.get("rx"), 0.0) + radius)
			var ez: float = (p.z - _num(rd.get("z"), 0.0)) / (_num(rd.get("rz"), 0.0) + radius)
			if ex * ex + ez * ez < 1.0:
				return "reserved"
		if camera != null and not body_px.is_empty():
			var rect: Rect2 = _prop_rect(camera, p, radius, height)
			var b: Array = body_px.bounds_px
			var body_rect: Rect2 = Rect2(float(b[0]), float(b[1]), float(b[2]) - float(b[0]), float(b[3]) - float(b[1]))
			var inter: Rect2 = rect.intersection(body_rect)
			if rect.get_area() > 0.0 and inter.get_area() / rect.get_area() > float(cfg.get("max_screen_overlap", 0.12)):
				return "covers_him"
			if not camera.is_position_in_frustum(p + Vector3(0.0, height * 0.5, 0.0)):
				return "off_screen"
			# the lantern itself must be seen: no placed asset nearer the camera may cover it
			var lamp_depth: float = camera.global_position.distance_to(p + Vector3(0.0, height * 0.5, 0.0))
			for rec2: Dictionary in tile.get("instance_nodes"):
				for mi2: MeshInstance3D in rec2.meshes:
					if not _shown_on_tile(mi2, tile):
						continue
					var box: AABB = mi2.global_transform * mi2.get_aabb()
					if box.size.y < 0.03 or camera.global_position.distance_to(box.get_center()) >= lamp_depth:
						continue
					var cover: Rect2 = _box_rect(camera, box).intersection(rect)
					if rect.get_area() > 0.0 and cover.get_area() / rect.get_area() > float(cfg.get("max_prop_cover", 0.3)):
						return "lamp_hidden"
	return ""

## Inside the support reservation, the prop's whole footprint included.
static func _on_deck(deck: Dictionary, p: Vector3, radius: float) -> bool:
	if deck.is_empty():
		return false
	var rx: float = _num(deck.get("rx"), 0.0) - radius
	var rz: float = _num(deck.get("rz"), 0.0) - radius
	if rx <= 0.0 or rz <= 0.0:
		return false
	var ex: float = (p.x - _num(deck.get("x"), 0.0)) / rx
	var ez: float = (p.z - _num(deck.get("z"), 0.0)) / rz
	return ex * ex + ez * ez <= 1.0

func _prop_rect(camera: Camera3D, p: Vector3, radius: float, height: float) -> Rect2:
	var mn: Vector2 = Vector2(INF, INF)
	var mx: Vector2 = -mn
	for cx: float in [-radius, radius]:
		for cy: float in [0.0, height]:
			for cz: float in [-radius, radius]:
				var s: Vector2 = camera.unproject_position(p + Vector3(cx, cy, cz))
				mn = mn.min(s)
				mx = mx.max(s)
	return Rect2(mn, mx - mn)

## His height in metres for the screen proxy (seated: about two thirds).
static func height_m_of(rig: Node3D, hscale: float) -> float:
	return height_m_for(str(rig.get("pose")), hscale)

static func height_m_for(pose: String, hscale: float) -> float:
	return 1.15 * hscale * (0.7 if pose == "seated" else 1.0)

## Visible flags from the mesh up to the tile node (the scene builds the tile hidden and shows it after the swap).
static func _shown_on_tile(mi: Node3D, tile: Node3D) -> bool:
	var node: Node = mi
	while node != null and node != tile:
		if node is Node3D and not (node as Node3D).visible:
			return false
		node = node.get_parent()
	return node == tile

static func _box_rect(camera: Camera3D, box: AABB) -> Rect2:
	var mn: Vector2 = Vector2(INF, INF)
	var mx: Vector2 = -mn
	for i: int in 8:
		var s: Vector2 = camera.unproject_position(box.get_endpoint(i))
		mn = mn.min(s)
		mx = mx.max(s)
	return Rect2(mn, mx - mn)

static func _path_dist(p: Vector3, pts: Array) -> float:
	var best: float = INF
	var q: Vector2 = Vector2(p.x, p.z)
	for i: int in range(pts.size() - 1):
		var pa3: Vector3 = _v3(pts[i])
		var pb3: Vector3 = _v3(pts[i + 1])
		var pa: Vector2 = Vector2(pa3.x, pa3.z)
		var pb: Vector2 = Vector2(pb3.x, pb3.z)
		best = minf(best, q.distance_to(Geometry2D.get_closest_point_to_segment(q, pa, pb)))
	if pts.size() == 1:
		var only: Vector3 = _v3(pts[0])
		best = q.distance_to(Vector2(only.x, only.z))
	return best

func _base_height(tile: Node3D, p: Vector3, radius: float) -> float:
	var h: float = -INF
	for o: Vector2 in [Vector2.ZERO, Vector2(radius, 0.0), Vector2(-radius, 0.0), Vector2(0.0, radius), Vector2(0.0, -radius)]:
		h = maxf(h, float(tile.call("terrain_height", p.x + o.x, p.z + o.y)))
	return h - 0.01

## Share of the stylised key for the ground he stands on (tile precompute.ground_info cell colours around him,
## classified like lshu_surface.gdshader): on bright sand he already reads as the dark figure against a warm ground
## that the lamp warms as much as him, so the key fades out with the sand weight; grass / snow / wet keep it.
func _key_factor(tile: Node3D, him: Vector3) -> float:
	var pre: Dictionary = tile.get("precompute")
	var gi: Dictionary = pre.get("ground_info", {})
	var n: int = int(_num(gi.get("n"), 0.0))
	var raw: PackedByteArray = Marshalls.base64_to_raw(str(gi.get("cell_rgba8_b64", "")))
	if n <= 0 or raw.size() != n * n * 4:
		return 1.0
	var span: float = float(cfg.get("key_ground_radius_m", 0.3))
	var step: float = 8.0 / float(n)
	var acc: Vector3 = Vector3.ZERO
	var count: int = 0
	var reach: int = maxi(0, int(ceil(span / step)))
	var ci: int = int(floor((him.x + 4.0) / step))
	var cj: int = int(floor((him.z + 4.0) / step))
	for dj: int in range(-reach, reach + 1):
		for di: int in range(-reach, reach + 1):
			var i: int = clampi(ci + di, 0, n - 1)
			var j: int = clampi(cj + dj, 0, n - 1)
			var o: int = (j * n + i) * 4
			acc += Vector3(raw[o], raw[o + 1], raw[o + 2]) / 255.0
			count += 1
	var c: Vector3 = acc / float(maxi(count, 1))
	var cls: Vector4 = GROUND_INFO.call("classify", Color(c.x, c.y, c.z))
	report["ground_under_him"] = {"srgb": [c.x, c.y, c.z], "grass": cls.x, "sand": cls.y, "snow": cls.z, "wet": cls.w}
	return clampf(1.0 - cls.y, 0.0, 1.0)

## A lantern kind the tile already uses (so a camp keeps one kind of lantern), else a stable hash of the tile id.
func _pick_asset(tile: Node3D, td: Dictionary) -> String:
	var assets: Array[String] = pool_assets()
	if assets.is_empty():
		return ""
	for rec: Dictionary in tile.get("instance_nodes"):
		var data: Dictionary = rec.data
		if str(data.get("role", "")) == "lamp" and assets.has(str(data.get("asset_id", ""))):
			return str(data.get("asset_id", ""))
	var key: String = str(td.get("id", td.get("composition_id", "")))
	return assets[posmod(int(hash(key)), assets.size())]

func _assign_surfaces(mi: MeshInstance3D) -> void:
	var no_shadow: Array = look.call("cfgv", "surface", "no_shadow_roles", ["water", "foam", "ripple"])
	var casts: bool = true
	for i: int in mi.mesh.get_surface_count():
		var src: Material = mi.mesh.surface_get_material(i)
		var sname: String = src.resource_name if src != null else "lshu_matte"
		var base_role: String = sname.trim_prefix("lshu_") if sname.begins_with("lshu_") else "matte"
		var role: String = str(look.call("asset_role", base_role, "camp"))
		mi.set_surface_override_material(i, look.call("role_material", role) as Material)
		if no_shadow.has(role) and mi.mesh.get_surface_count() == 1:
			casts = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## World centre of the prop's glow surfaces (the lantern glass); fallback light_height_frac of its height.
func _glow_point(meshes: Array, holder: Node3D) -> Vector3:
	var box: AABB = AABB()
	var found: bool = false
	var all_box: AABB = AABB()
	var any: bool = false
	for m: Variant in meshes:
		var mi: MeshInstance3D = m as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var wb: AABB = mi.global_transform * mi.get_aabb()
		all_box = wb if not any else all_box.merge(wb)
		any = true
		for i: int in mi.mesh.get_surface_count():
			var src: Material = mi.mesh.surface_get_material(i)
			if src == null or src.resource_name != "lshu_glow":
				continue
			var verts: PackedVector3Array = mi.mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
			for v: Vector3 in verts:
				var w: Vector3 = mi.global_transform * v
				box = AABB(w, Vector3.ZERO) if not found else box.expand(w)
				found = true
	if found:
		return box.get_center()
	if any:
		return Vector3(all_box.get_center().x, all_box.position.y + all_box.size.y * float(cfg.get("light_height_frac", 0.6)), all_box.get_center().z)
	return holder.global_position + Vector3(0.0, 0.3, 0.0)

# ------------------------------------------------------------------ light
func _build_light() -> void:
	light = OmniLight3D.new()
	light.name = "NightLampLight"
	light.light_cull_mask = 0xFFFFF & ~FLOOR_LAYER
	light.shadow_enabled = false
	add_child(light)
	light.global_position = light_point
	key = OmniLight3D.new()
	key.name = "NightLampKey"
	var life: Dictionary = (look.get("cfg") as Dictionary).get("life", {})
	key.light_cull_mask = 1 << int(((life.get("character", {}) as Dictionary).get("layer_bit", 18)))
	key.shadow_enabled = false
	key.light_specular = 0.0
	add_child(key)
	key.global_position = light_point
	if _halo_quad == null:
		_halo_quad = QuadMesh.new()
		_halo_quad.size = Vector2.ONE
	halo_material = ShaderMaterial.new()
	halo_material.shader = HALO_SHADER
	halo = MeshInstance3D.new()
	halo.name = "NightLampHalo"
	halo.mesh = _halo_quad
	halo.material_override = halo_material
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	halo.custom_aabb = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2))
	add_child(halo)
	halo.global_position = light_point
	_refresh(0.0)

## After every light change: w = the night weight of the current light (look.weight("night")).
func set_night_weight(w: float) -> void:
	night_weight = clampf(w, 0.0, 1.0)
	cfg = look.call("sec", "night_lamp") if look != null else cfg
	_refresh(0.0)

## Director helper: true when the clock light over [from_unix, to_unix] has any night weight (sampled every 5 minutes
## and at both ends), i.e. the stay reaches into the night. clock_compiled = LshuClock.compile_config(cfg). On
## arrival: set_hold(stay_needs_lamp(leg.arrive, leg.depart, c)) so the lantern is set down with him.
static func stay_needs_lamp(from_unix: int, to_unix: int, clock_compiled: Dictionary) -> bool:
	var t: int = from_unix
	while true:
		var l: Dictionary = CLOCK.call("light_at", float(mini(t, to_unix)), clock_compiled)
		if float((l.get("weights", {}) as Dictionary).get("night", 0.0)) > 0.0:
			return true
		if t >= to_unix:
			return false
		t += 300
	return false

## Director: keep the prop set down for a stay that reaches into the night, even while the night weight is 0.
func set_hold(on: bool) -> void:
	hold = on
	_refresh(0.0)

## Director: false while he is away from the tile (on the road): he carries his lantern.
func set_present(on: bool) -> void:
	present = on
	if on:
		presence_fade = 1.0
	_refresh(0.0)

## Director: fade of the lamp light as he takes the lantern away (1 = full, 0 = off); see presence_fade.
func set_presence_fade(f: float) -> void:
	var v: float = clampf(f, 0.0, 1.0)
	if is_equal_approx(v, presence_fade):
		return
	presence_fade = v
	_refresh(0.0)

func _refresh(t: float) -> void:
	if mode == "none":
		return
	var shown: bool = present and (night_weight > 0.0 or hold)
	if mode == "placed" and prop != null:
		prop.visible = shown
	var lit: bool = present and night_weight > 0.0
	var flick: float = float(cfg.get("flicker", 0.0))
	if light != null:
		light.visible = lit
		light.light_color = _col(cfg.get("light_color", "#ffa24a"))
		light.omni_range = float(cfg.get("light_range", 1.8))
		light.omni_attenuation = float(cfg.get("light_attenuation", 1.4))
		var wave: float = 1.0 + flick * (sin(t * 5.3) * 0.6 + sin(t * 11.7) * 0.4)
		light.light_energy = float(cfg.get("light_energy", 0.7)) * night_weight * wave * presence_fade
		if key != null:
			key.visible = lit and float(cfg.get("character_energy", 0.0)) * key_factor > 0.0
			key.light_color = light.light_color
			key.omni_range = float(cfg.get("character_range", light.omni_range))
			key.omni_attenuation = float(cfg.get("character_attenuation", light.omni_attenuation))
			key.light_energy = float(cfg.get("character_energy", 0.0)) * key_factor * night_weight * wave * presence_fade
	if halo != null:
		var life: Dictionary = (look.get("cfg") as Dictionary).get("life", {})
		var lan: Dictionary = life.get("lanterns", {})
		var strength: float = float(lan.get("halo_strength", 0.0)) * night_weight * presence_fade
		halo.visible = lit and strength > 0.0
		halo.scale = Vector3.ONE * float(cfg.get("halo_size_m", lan.get("halo_size_m", 0.6)))
		halo_material.set_shader_parameter("halo_color", _col(lan.get("halo_color", "#ffb66e")))
		halo_material.set_shader_parameter("halo_strength", strength)
		halo_material.set_shader_parameter("halo_falloff", float(lan.get("halo_falloff", 3.2)))
		halo_material.set_shader_parameter("toward_camera_m", float(lan.get("halo_toward_camera_m", 0.25)))
		halo.set_instance_shader_parameter("halo_flicker", 1.0 + flick * sin(t * 5.3) * 0.8)

## Per frame with the scene clock t (held still under --motion-freeze).
func tick(t: float) -> void:
	if mode != "none" and night_weight > 0.0:
		_refresh(t)

## Local-key candidates for the character's rim (the lamp light point while it is lit).
func key_points() -> Array[Vector3]:
	var out: Array[Vector3] = []
	if mode != "none" and present and night_weight > 0.0:
		out.append(light_point)
	return out

func evidence() -> Dictionary:
	var out: Dictionary = report.duplicate(true)
	out["night_weight"] = night_weight
	out["hold"] = hold
	out["present"] = present
	out["light_energy"] = light.light_energy if light != null else 0.0
	out["character_energy"] = key.light_energy if key != null else 0.0
	return out

static func _num(v: Variant, fallback: float) -> float:
	return float(v) if (v is float or v is int) else fallback

static func _dxz(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

static func _to_camera(him: Vector3, camera: Camera3D) -> Vector3:
	if camera == null:
		return Vector3.BACK
	var d: Vector3 = camera.global_position - him
	d.y = 0.0
	return d.normalized() if d.length() > 0.001 else Vector3.BACK

static func _v3(v: Variant) -> Vector3:
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(_num(a[0], 0.0), _num(a[1], 0.0), _num(a[2], 0.0))
	return Vector3.ZERO

static func _col(v: Variant) -> Color:
	if v is String:
		return Color.html(str(v))
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return Color(1.0, 0.64, 0.29)
