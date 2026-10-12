extends Node
## 第四幕「L叔在哪儿」· QA only: feet-on-ground scan (P0 fix #1 evidence).
## Measures what is drawn, independent of the rule in scripts/traveler/lshu/lshu_character.gd:
##   sole gap   = min over the posed body's lowest vertices (each foot) of (vertex y - the drawn surface straight
##                below it): every visible procedural part and placed asset (vertical ray against their triangles),
##                plus the seat asset taken as a solid over its column span (a sole inside the span is sunk into the
##                seat: negative gap, counted in queries_inside_seat). Also per foot, and vs the ground alone.
##   cycle      = the same at `samples` phases over the whole idle loop (min / max of the per-phase gap).
##   seat       = seat anchor (the body's sitting point) vs the top of the seat asset's drawn meshes.
## Attached by tools/traveler/lshu/qa/lshu_seat_capture.gd once the tile is ready; runs during the capture warm-up
## (about 2 + 2 x samples drawn frames of the 120; the scene clock is held and restored afterwards) and writes
## scene.add_report("seat_scan", ...).

const SOLE_BAND_M: float = 0.05     # vertices within this height of the lowest one are sole candidates
const MAX_QUERIES: int = 360
const PENETRATION_WINDOW_M: float = 0.15
const SETTLE_FRAMES: int = 2

var scene: Node3D
var result: Dictionary = {}

func start(scene_node: Node3D, samples: int) -> void:
	scene = scene_node
	result = await measure(samples)
	scene.call("add_report", "seat_scan", result)
	print("LSHU_SEAT_SCAN ", JSON.stringify(result))

## The renderer's skin (and so bake_mesh_from_current_skeleton_pose) follows the skeleton one drawn frame late:
## every pose is set through the scene clock and measured only after SETTLE_FRAMES drawn frames.
func _settle() -> void:
	for _i: int in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw

func measure(samples: int) -> Dictionary:
	var character: Node3D = scene.get("character")
	var tile: Node3D = scene.get("tile")
	var rig: Node3D = character.get("active")
	var body: MeshInstance3D = rig.get("character_body")
	var anim_t: float = float(scene.get("anim_t"))
	var frozen: bool = bool(scene.get("motion_frozen"))
	var tile_data: Dictionary = tile.get("tile")
	var c: Dictionary = tile_data.get("character", {})
	var out: Dictionary = {"tile": scene.get("tile_id"), "pose": rig.get("pose"), "anim_t": anim_t, "samples": samples}
	var support: Node3D = _support_holder(tile, c)
	scene.set("motion_frozen", true)
	await _settle()
	await _settle()
	# feet region: the sole candidates of the drawn pose, padded for the idle motion
	var char_inv: Transform3D = (rig.get("character") as Node3D).global_transform.affine_inverse()
	var first: PackedVector3Array = _sole_points(body, char_inv)[0]
	var region: Rect2 = Rect2(first[0].x, first[0].z, 0.0, 0.0)
	for q: Vector3 in first:
		region = region.expand(Vector2(q.x, q.z))
	region = region.grow(0.4)
	var tris: PackedVector3Array = _surface_triangles(tile, support, character, region, false)
	var seat_tris: PackedVector3Array = _surface_triangles(tile, support, character, region, true)
	out["surface_triangles"] = {"ground": tris.size() / 3, "seat": seat_tris.size() / 3}
	# the drawn (capture) pose
	var t0: int = Time.get_ticks_usec()
	out["at_anim_t"] = _gap(body, tris, seat_tris, tile, char_inv)
	out["bake_and_gap_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	# whole idle cycle
	var length: float = _cycle_length(rig)
	var gaps: Array[float] = []
	var foot_max: Array[float] = []
	var worst_low: Dictionary = {}
	var worst_high: Dictionary = {}
	for k: int in samples:
		var t: float = length * float(k) / float(samples)
		scene.set("anim_t", t)
		await _settle()
		var g: Dictionary = _gap(body, tris, seat_tris, tile, char_inv)
		var v: float = float(g.get("sole_gap_m", INF))
		gaps.append(v)
		foot_max.append(float(g.get("max_foot_gap_m", INF)))
		if worst_low.is_empty() or v < float(worst_low.sole_gap_m):
			worst_low = g.duplicate()
			worst_low["t"] = t
		if worst_high.is_empty() or v > float(worst_high.sole_gap_m):
			worst_high = g.duplicate()
			worst_high["t"] = t
	scene.set("anim_t", anim_t)
	scene.set("motion_frozen", frozen)
	var sorted: Array[float] = gaps.duplicate()
	sorted.sort()
	var feet_sorted: Array[float] = foot_max.duplicate()
	feet_sorted.sort()
	out["cycle"] = {"length_s": length, "min_gap_m": sorted[0], "max_gap_m": sorted[sorted.size() - 1],
		"spread_m": sorted[sorted.size() - 1] - sorted[0], "max_foot_gap_m": feet_sorted[feet_sorted.size() - 1],
		"lowest_phase": worst_low, "highest_phase": worst_high}
	out["worst_abs_gap_m"] = maxf(absf(sorted[0]), absf(sorted[sorted.size() - 1]))
	# seat contact
	if support != null:
		var top: float = -INF
		for node: Node in support.find_children("*", "MeshInstance3D", true, false):
			var mi: MeshInstance3D = node as MeshInstance3D
			top = maxf(top, (mi.global_transform * mi.get_aabb()).end.y)
		var seat_rec: Dictionary = {"holder_scale": [support.scale.x, support.scale.y, support.scale.z], "base_y": support.global_position.y,
			"mesh_top_y": top, "data_seat_top_y": c.get("seat_top")}
		var actor: RefCounted = rig.get("seated_actor")
		if actor != null:
			var model: Node3D = actor.get("model")
			var anchor_w: Vector3 = model.global_transform * (actor.call("current_seat_anchor") as Vector3)
			seat_rec["anchor_y"] = anchor_w.y
			seat_rec["mesh_top_minus_anchor_m"] = top - anchor_w.y
		out["seat"] = seat_rec
	var fit: Variant = (character.get("report") as Dictionary).get("seat_fit")
	if fit != null:
		out["rule"] = fit
	return out

static func _cycle_length(rig: Node3D) -> float:
	var actor: RefCounted = rig.get("seated_actor")
	if actor != null:
		return float(actor.get("duration_s"))
	var l: float = float(rig.get("anim_length"))
	return l if l > 0.0 else 1.0

## The seat asset under him: the instance the tile names as his support, nearest to his spot.
static func _support_holder(tile: Node3D, c: Dictionary) -> Node3D:
	var support_id: String = str(c.get("support", ""))
	var cp: Array = c.get("position", [0, 0, 0])
	var best: Node3D = null
	var best_d: float = INF
	for rec: Variant in tile.get("instance_nodes"):
		var r: Dictionary = rec
		var d: Dictionary = r.data
		if str(d.get("asset_id", "")) != support_id:
			continue
		var p: Array = d.position
		var dist: float = Vector2(float(p[0]) - float(cp[0]), float(p[2]) - float(cp[2])).length()
		if dist < best_d:
			best_d = dist
			best = r.node
	return best

## World-space triangles in the feet region: seat_only = false, everything drawn on the tile that a foot could
## stand on except the seat under him (and L叔); seat_only = true, that seat asset alone.
static func _surface_triangles(tile: Node3D, support: Node3D, character: Node3D, region: Rect2, seat_only: bool) -> PackedVector3Array:
	var meshes: Array[MeshInstance3D] = []
	if not seat_only:
		var proc: Dictionary = tile.get("proc_nodes")
		for role: Variant in proc.keys():
			meshes.append(proc[role] as MeshInstance3D)
	for rec: Variant in tile.get("instance_nodes"):
		var r: Dictionary = rec
		if (r.node == support) != seat_only:
			continue
		for mi: MeshInstance3D in r.meshes:
			meshes.append(mi)
	var tris: PackedVector3Array = PackedVector3Array()
	for mi: MeshInstance3D in meshes:
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree() or character.is_ancestor_of(mi):
			continue
		var xf: Transform3D = mi.global_transform
		for s: int in mi.mesh.get_surface_count():
			var arrays: Array = mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var wv: PackedVector3Array = PackedVector3Array()
			wv.resize(verts.size())
			for k: int in verts.size():
				wv[k] = xf * verts[k]
			var count: int = idx.size() if not idx.is_empty() else verts.size()
			var i: int = 0
			while i + 2 < count:
				var a: Vector3 = wv[idx[i]] if not idx.is_empty() else wv[i]
				var b: Vector3 = wv[idx[i + 1]] if not idx.is_empty() else wv[i + 1]
				var cc: Vector3 = wv[idx[i + 2]] if not idx.is_empty() else wv[i + 2]
				i += 3
				var box: Rect2 = Rect2(a.x, a.z, 0.0, 0.0).expand(Vector2(b.x, b.z)).expand(Vector2(cc.x, cc.z))
				if not box.intersects(region, true):
					continue
				tris.append(a)
				tris.append(b)
				tris.append(cc)
	return tris

## Highest drawn surface at (x, z) that is below y_limit; -INF if none.
static func _surface_y(tris: PackedVector3Array, x: float, z: float, y_limit: float) -> float:
	var best: float = -INF
	var p: Vector2 = Vector2(x, z)
	var n: int = tris.size()
	var i: int = 0
	while i < n:
		var a: Vector3 = tris[i]
		var b: Vector3 = tris[i + 1]
		var c: Vector3 = tris[i + 2]
		i += 3
		if x < minf(a.x, minf(b.x, c.x)) or x > maxf(a.x, maxf(b.x, c.x)) or z < minf(a.z, minf(b.z, c.z)) or z > maxf(a.z, maxf(b.z, c.z)):
			continue
		var v0: Vector2 = Vector2(b.x - a.x, b.z - a.z)
		var v1: Vector2 = Vector2(c.x - a.x, c.z - a.z)
		var v2: Vector2 = p - Vector2(a.x, a.z)
		var den: float = v0.x * v1.y - v1.x * v0.y
		if absf(den) < 1e-9:
			continue
		var u: float = (v2.x * v1.y - v1.x * v2.y) / den
		var w: float = (v0.x * v2.y - v2.x * v0.y) / den
		if u < -1e-6 or w < -1e-6 or u + w > 1.0 + 1e-6:
			continue
		var y: float = a.y + (b.y - a.y) * u + (c.y - a.y) * w
		if y <= y_limit and y > best:
			best = y
	return best

## World positions of the posed body's lowest vertices, per side of his body (character-local x >= 0 / < 0):
## within SOLE_BAND_M of that side's lowest vertex. Returns [all, side flags (1 = +x side)].
static func _sole_points(body: MeshInstance3D, char_inv: Transform3D) -> Array:
	var posed: Mesh = body.bake_mesh_from_current_skeleton_pose() if body.skin != null else body.mesh
	var xf: Transform3D = body.global_transform
	var world: PackedVector3Array = PackedVector3Array()
	var side: PackedByteArray = PackedByteArray()
	var min_y: Array[float] = [INF, INF]
	for s: int in posed.get_surface_count():
		var verts: PackedVector3Array = posed.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for v: Vector3 in verts:
			var w: Vector3 = xf * v
			var sd: int = 1 if (char_inv * w).x >= 0.0 else 0
			world.append(w)
			side.append(sd)
			min_y[sd] = minf(min_y[sd], w.y)
	var cand: PackedVector3Array = PackedVector3Array()
	var cside: PackedByteArray = PackedByteArray()
	for k: int in world.size():
		if world[k].y <= min_y[side[k]] + SOLE_BAND_M:
			cand.append(world[k])
			cside.append(side[k])
	return [cand, cside]

## Sole gaps of the drawn pose: vs the ground (tile surfaces without the seat) and vs whatever is under each
## sole point (ground or the seat asset's own parts), overall and per foot. Negative = sunk in.
static func _gap(body: MeshInstance3D, ground_tris: PackedVector3Array, seat_tris: PackedVector3Array, tile: Node3D, char_inv: Transform3D) -> Dictionary:
	var sp: Array = _sole_points(body, char_inv)
	var cand: PackedVector3Array = sp[0]
	var cside: PackedByteArray = sp[1]
	var min_y: float = INF
	for q0: Vector3 in cand:
		min_y = minf(min_y, q0.y)
	var stride: int = maxi(1, int(ceil(float(cand.size()) / float(MAX_QUERIES))))
	var gap_ground: float = INF
	var gap_json: float = INF
	var foot: Array[float] = [INF, INF]
	var at: Vector3 = Vector3.ZERO
	var on_seat_parts: int = 0
	var inside_seat: int = 0
	var no_surface: int = 0
	var i: int = 0
	while i < cand.size():
		var q: Vector3 = cand[i]
		var sd: int = cside[i]
		i += stride
		var gy: float = _surface_y(ground_tris, q.x, q.z, q.y + PENETRATION_WINDOW_M)
		# the seat asset as a solid: inside its column span = sunk into it (depth below its top), fully above = resting
		# candidate, fully below its lowest crossing = under an overhang (neither)
		var span: Vector2 = _span(seat_tris, q.x, q.z)
		var sy: float = -INF
		if span.y > -INF and span.x < q.y:
			sy = span.y
			if span.y > q.y:
				inside_seat += 1
		if gy == -INF and sy == -INF:
			no_surface += 1
			continue
		if gy > -INF:
			gap_ground = minf(gap_ground, q.y - gy)
		var under: float = maxf(gy, sy)
		if sy > gy:
			on_seat_parts += 1
		if q.y - under < foot[sd]:
			foot[sd] = q.y - under
		if q.y - under <= minf(foot[0], foot[1]):
			at = q
		gap_json = minf(gap_json, q.y - float(tile.call("terrain_height", q.x, q.z)))
	return {"sole_gap_m": minf(foot[0], foot[1]), "foot_gap_m": {"plus_x": foot[1], "minus_x": foot[0]},
		"max_foot_gap_m": maxf(foot[0], foot[1]), "sole_gap_vs_ground_only_m": gap_ground,
		"sole_gap_vs_json_heights_m": gap_json, "queries_over_seat_parts": on_seat_parts, "queries_inside_seat": inside_seat, "lowest_vertex_y": min_y,
		"at": [at.x, at.y, at.z], "sole_candidates": cand.size(), "queries_without_surface": no_surface}

## Lowest / highest crossing of the vertical line (x, z) with the triangles; (-INF, -INF) if none.
static func _span(tris: PackedVector3Array, x: float, z: float) -> Vector2:
	var lo: float = INF
	var hi: float = -INF
	var i: int = 0
	while i + 2 < tris.size():
		var a: Vector3 = tris[i]
		var b: Vector3 = tris[i + 1]
		var c: Vector3 = tris[i + 2]
		i += 3
		if x < minf(a.x, minf(b.x, c.x)) or x > maxf(a.x, maxf(b.x, c.x)) or z < minf(a.z, minf(b.z, c.z)) or z > maxf(a.z, maxf(b.z, c.z)):
			continue
		var v0: Vector2 = Vector2(b.x - a.x, b.z - a.z)
		var v1: Vector2 = Vector2(c.x - a.x, c.z - a.z)
		var v2: Vector2 = Vector2(x - a.x, z - a.z)
		var den: float = v0.x * v1.y - v1.x * v0.y
		if absf(den) < 1e-9:
			continue
		var u: float = (v2.x * v1.y - v1.x * v2.y) / den
		var w: float = (v0.x * v2.y - v2.x * v0.y) / den
		if u < -1e-6 or w < -1e-6 or u + w > 1.0 + 1e-6:
			continue
		var y: float = a.y + (b.y - a.y) * u + (c.y - a.y) * w
		lo = minf(lo, y)
		hi = maxf(hi, y)
	if hi == -INF:
		return Vector2(-INF, -INF)
	return Vector2(lo, hi)
