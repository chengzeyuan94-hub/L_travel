extends Control
## City name plaques on Claude's 3D merchant board: where each one goes (Carlos 2026-09-25:
## 「名牌…摆放合理一点，不要挡住路线，可以每个城市都有着不同的接近摆放位置，不要玩家角色资产靠近
## 就突然间移动」). Every city gets its own fixed spot near it — below, beside or above — that keeps
## clear of the route lines, the stands where the pieces wait (the camel / boat, its pin and 你/AI
## label, and a second piece beside it), the coins and their step badges, the other cities and the
## other plaques, at the zooms people play at (0.8 / 1 / 1.5). The spot is a point on the map: the
## plaque only moves with the camera.
##
## Window (no args): the board at the default framing with a piece on every stand and every plaque
##   at its spot. Drag a plaque to move it; S saves assets/merchant_board_claude/plaque_layout.json;
##   A re-solves every city automatically; wheel / right-drag move the camera as in the game.
## Args: -- --solve (solve and save, then keep the window)  --shots=<abs dir> (review captures, quit)

const Board := preload("res://tools/merchant_board_claude_play_board.gd")
const Token := preload("res://tools/merchant_board_claude_token.gd")
const OUT := "res://assets/merchant_board_claude/plaque_layout.json"
const ZOOMS := [[0.6, 0.4], [0.8, 0.8], [1.0, 1.0], [1.5, 0.6]]     # review captures
const TEAM := [Color8(205, 72, 58), Color8(62, 118, 196), Color8(58, 160, 98), Color8(238, 184, 52)]

var board: Control
var sides := {}                 # city id -> chosen side (report)
var attach := {}                # city id -> [world point on the city's buildings, plaque centre offset px]
var _drag_cid := ""
var _drag_off := Vector2.ZERO
var _status: Label
var _pieces: Array = []


func _ready() -> void:
	get_window().size = Vector2i(1600, 900)     # 16:9 and fits the screen: canvas 1280 x 720, as 1080p
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	board = Board.new()
	board.name = "BoardView"
	add_child(board)
	board.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	board.set_map_safe_right_inset(298.0)          # the game's HUD scroll, as GameScreen sets it
	_status = Label.new()
	_status.position = Vector2(12, 8)
	_status.add_theme_color_override("font_color", Color.WHITE)
	_status.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_status.add_theme_constant_override("outline_size", 6)
	add_child(_status)
	await get_tree().process_frame
	await get_tree().process_frame
	_place_pieces()
	var args := OS.get_cmdline_user_args()
	if "--solve" in args or not FileAccess.file_exists(OUT):
		solve()
		save()
	for a in args:
		if a.begins_with("--shots="):
			await _shots(a.trim_prefix("--shots="))
			get_tree().quit()
			return
	_status.text = "名牌摆放：拖动名牌调整 · S 保存 · A 重新自动排布 · 滚轮/右键拖动看地图"


# ------------------------------------------------------------------ pieces on every stand
## a piece on every city stand (and a second one beside it at the busier ports), so the layout is
## judged with the board as full as it gets
func _place_pieces() -> void:
	var paths = board.paths
	var k := 0
	for cid in paths.gates:
		for rid in paths.gates[cid]:
			var m: String = paths.route_type(rid)
			var n := 2
			var slots: Array = paths.slot_offsets(cid, rid, m, n)
			for i in n:
				var tok: Node3D = Token.new()
				board.world.world_root.add_child(tok)
				tok.setup(board.world, TEAM[k % 4])
				tok.set_coins(PackedVector3Array(paths.stop_pos.values()))
				tok.fit_fn = paths.hull_fit
				tok.set_role("你" if k % 2 == 0 else "AI")
				tok.place((paths.gates[cid][rid] as Vector3) + (slots[i].off as Vector3), m, paths.rest_yaw(cid, rid))
				tok.slot_scale = float(slots[i].scale)
				tok.set_meta("slot", i)
				_pieces.append(tok)
				k += 1


# ------------------------------------------------------------------ geometry in the view plane
## The board camera is orthographic, pitched, never yawed: a world point maps to the screen as
## (x, z sin P - y cos P) times pixels-per-unit (zoom x free-map width / DEFAULT_WIDTH). Solving in
## that plane makes a layout exact for any camera position; zoom and window width only change
## pixels-per-unit, and the plaque (fixed px down to zoom 0.8, shrinking with the map below).
func _vp(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z * sin(Board.PITCH) - p.y * cos(Board.PITCH))


## [free map width px, zoom, weight]: 1080p (board 1280 wide) and this Mac's 1920x928 window
## (board 1489 wide), from the whole-board view to the closest zoom
const EVALS := [[982.0, 0.42, 0.25], [982.0, 0.6, 0.4], [982.0, 0.8, 0.8], [982.0, 1.0, 1.0], [982.0, 1.5, 0.6],
	[1191.0, 0.42, 0.2], [1191.0, 0.6, 0.3], [1191.0, 0.8, 0.7], [1191.0, 1.0, 0.9], [1191.0, 1.5, 0.5]]
const DESIGN_FREE := 982.0
const PX_PER_PIXEL_SIZE := 328.0      # canvas px per unit of Sprite3D pixel_size (board 656 tall)


func _ppu(zoom: float, free := DESIGN_FREE) -> float:
	return zoom * free / Board.DEFAULT_WIDTH


func _pscale(zoom: float) -> float:
	return clampf(zoom / 0.8, 0.55, 1.0)


func _city_rect_vp(cid: String) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for q in _city_silhouette_vp(cid):
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	return Rect2(lo, hi - lo)


## A piece's marks, as the game draws them: the body (view-plane rect) and, over it, the pin with the
## 你/AI label (fixed px: pin 64x84 texels at 0.0012 above its tip, label centred 110 texels at
## 0.0011 above the tip, ~14 px tall).
func _piece_boxes(base: Vector3, land: bool, weight: float, into: Dictionary) -> void:
	var h: float = 1.25 * 1.1 + 0.18 if land else 0.95 * 1.8 + 0.18
	var w: float = 0.72 if land else 1.0
	var top := _vp(base + Vector3(0, h, 0))
	var bot := _vp(base)
	(into.bodies as Array).append([Rect2(Vector2(bot.x - w, top.y), Vector2(2.0 * w, bot.y - top.y + 0.25)), weight])
	(into.pins as Array).append([top, Vector2(15, 26), Vector2(0, -24), weight])


## everything a plaque must keep clear of, per city (only what is near it), in the view plane
func _obstacles() -> Dictionary:
	var paths = board.paths
	var all := {"routes": [], "coins": [], "badges": [], "bodies": [], "pins": [], "swept_b": [], "swept_p": []}
	for rid in paths.routes:
		var R: Dictionary = paths.routes[rid]
		var L: float = R.cum[R.cum.size() - 1]
		var land: bool = R.type == "LAND"
		var s := 0.0
		while s <= L:
			var p: Vector3 = paths.point_at(rid, s)
			(all.routes as Array).append(_vp(p))
			if s >= R.s0 and s <= R.s1 and fmod(s, 0.4) < 0.2:
				var tmp := {"bodies": [], "pins": []}
				_piece_boxes(p + Vector3(0, 0.09 if land else 0.0, 0), land, 0.35, tmp)     # moving pieces
				(all.swept_b as Array).append(tmp.bodies[0])
				(all.swept_p as Array).append(tmp.pins[0])
			s += 0.2
	var badge_half := Vector2.ONE * 36.0 * 0.0011 * 1.25 * PX_PER_PIXEL_SIZE        # hovered / chosen size
	var badge_off := Vector2(0, -30.0 * 0.0011 * PX_PER_PIXEL_SIZE)
	for sid in paths.stop_pos:
		var c: Vector3 = paths.stop_pos[sid]
		var v := _vp(c)
		(all.coins as Array).append(Rect2(v - Vector2(0.75, 0.62), Vector2(1.5, 1.24)))
		(all.badges as Array).append([_vp(c + Vector3(0, 0.75, 0)), badge_half, badge_off])
		var rid: String = paths.route_of_stop(sid)
		var m: String = paths.route_type(rid)
		var slots: Array = paths.slot_offsets(sid, "", m, 2)
		for i in 2:
			_piece_boxes(paths.node_point(sid) + (slots[i].off as Vector3), m == "LAND", 1.0 if i == 0 else 0.5, all)
	for cid in paths.city:
		var c: Dictionary = paths.city[cid]
		(all.badges as Array).append([_vp(Vector3(float(c.x), float(c.get("y", 0.9)) + 0.1 + 2.3, float(c.z))), badge_half, badge_off])
		for rid in paths.gates[cid]:
			var m: String = paths.route_type(rid)
			var slots: Array = paths.slot_offsets(cid, rid, m, 2)
			for i in 2:
				_piece_boxes((paths.gates[cid][rid] as Vector3) + (slots[i].off as Vector3), m == "LAND", 1.0 if i == 0 else 0.5, all)
	var per := {}
	for cid in paths.city:
		var sil := _city_silhouette_vp(cid)
		var ctr := Vector2.ZERO
		for q in sil:
			ctr += q
		ctr /= maxf(float(sil.size()), 1.0)
		var near := func(q: Vector2) -> bool: return q.distance_to(ctr) < 13.0
		var o := {"centre": ctr, "silh": sil, "silh_w": _city_silhouette_world(cid), "rect": _city_rect_vp(cid), "other_silh": {}}
		o.routes = (all.routes as Array).filter(func(q): return near.call(q))
		o.coins = (all.coins as Array).filter(func(r): return near.call((r as Rect2).get_center()))
		o.badges = (all.badges as Array).filter(func(b): return near.call(b[0]))
		o.bodies = (all.bodies as Array).filter(func(b): return near.call((b[0] as Rect2).get_center()))
		o.pins = (all.pins as Array).filter(func(b): return near.call(b[0]))
		o.swept_b = (all.swept_b as Array).filter(func(b): return near.call((b[0] as Rect2).get_center()))
		o.swept_p = (all.swept_p as Array).filter(func(b): return near.call(b[0]))
		o.others = {}
		for oc in paths.city:
			if oc != cid:
				var orr := _city_rect_vp(oc)
				if orr.get_center().distance_to(ctr) < 16.0:
					o.others[oc] = orr
					o.other_silh[oc] = _city_silhouette_vp(oc)
		per[cid] = o
	return per


const VEGETATION := ["Leaf", "Foliage", "Palm", "Tree", "Trunk", "Bush", "Grass"]


## the city's buildings as seen (no trees or palms, no base plate), world points
func _city_silhouette_world(cid: String) -> PackedVector3Array:
	var holder: Node3D = board.world.city_nodes[cid].node
	var out := PackedVector3Array()
	for mi: MeshInstance3D in board.world.mesh_instances(holder):
		if mi.mesh == null:
			continue
		var inv := holder.global_transform.affine_inverse() * mi.global_transform
		for si in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(si)
			var nm := String(mat.resource_name) if mat != null else ""
			var veg := false
			for w in VEGETATION:
				veg = veg or nm.contains(w)
			if veg:
				continue
			var verts: PackedVector3Array = mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
			var step := maxi(1, verts.size() / 120)
			for vi in range(0, verts.size(), step):
				var lp := inv * verts[vi]
				if lp.y < 0.25:
					continue           # the base plate / ground ring: not the city people see
				out.append(holder.global_transform * lp)
	return out


func _city_silhouette_vp(cid: String) -> PackedVector2Array:
	var out := PackedVector2Array()
	for w in _city_silhouette_world(cid):
		out.append(_vp(w))
	return out


func _rect_point_dist(r: Rect2, q: Vector2) -> float:
	return Vector2(maxf(0.0, maxf(r.position.x - q.x, q.x - r.end.x)), maxf(0.0, maxf(r.position.y - q.y, q.y - r.end.y))).length()


func _px_rect(item: Array, ppu: float) -> Rect2:
	var c: Vector2 = item[0] + (item[2] as Vector2) / ppu
	var hs: Vector2 = (item[1] as Vector2) / ppu
	return Rect2(c - hs, hs * 2.0)


func _frac(a: Rect2, b: Rect2) -> float:
	if not a.intersects(b):
		return 0.0
	return a.intersection(b).get_area() / maxf(a.get_area(), 1e-6)


func _seg_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	for i in 9:
		if r.has_point(a.lerp(b, i / 8.0)):
			return true
	return false


## the building point a plaque centred on c (design zoom 1) hangs from: the one nearest its rect
func _attach_index(o: Dictionary, c: Vector2, size: Vector2) -> int:
	var r1 := Rect2(c - size / _ppu(1.0) * 0.5, size / _ppu(1.0))
	var sil: PackedVector2Array = o.silh
	var bi := 0
	var bd := INF
	for i in sil.size():
		var d := _rect_point_dist(r1, sil[i]) + 0.02 * sil[i].distance_to(c)
		if d < bd:
			bd = d
			bi = i
	return bi


## penalty of a plaque of `size` px hung from building point q with offset off_px (px at scale 1)
func _score(cid: String, q: Vector2, off_px: Vector2, size: Vector2, o: Dictionary, placed: Dictionary, detail := {}) -> float:
	var total := 0.0
	for ev: Array in EVALS:
		var ppu := _ppu(float(ev[1]), float(ev[0]))
		var k := _pscale(float(ev[1]))
		var cz := q + off_px * k / ppu
		var r := Rect2(cz - size * k / ppu * 0.5, size * k / ppu)
		var rg := r.grow(2.0 / ppu)
		var route := 0
		for rq: Vector2 in o.routes:
			if rg.has_point(rq):
				route += 1
		var pen := 3.0 * route                            # 3 per 0.1 u of route hidden
		var hide := 0.0
		for cr: Rect2 in o.coins:
			hide += 200.0 * _frac(cr, rg)
		# pins, 你/AI labels and step badges are drawn above the names (they are never hidden):
		# keeping clear of them is only about clutter
		for b: Array in o.badges:
			hide += 50.0 * _frac(_px_rect(b, ppu), rg)
		for bd: Array in o.bodies:
			hide += 300.0 * float(bd[1]) * _frac(bd[0], rg)
		for pn: Array in o.pins:
			hide += 50.0 * float(pn[3]) * _frac(_px_rect(pn, ppu), rg)
		for bd: Array in o.swept_b:
			hide += 300.0 * float(bd[1]) * _frac(bd[0], rg)            # a camel / boat passing under a name
		for pn: Array in o.swept_p:
			hide += 15.0 * float(pn[3]) * _frac(_px_rect(pn, ppu), rg)
		pen += hide
		var other := 0.0
		for oc in o.others:
			other += 200.0 * _frac(o.others[oc], rg)
		for pc in placed:
			var pr: Array = placed[pc]            # [attach view point, offset px, size px]
			var pcz: Vector2 = pr[0] + (pr[1] as Vector2) * k / ppu
			var prr := Rect2(pcz - (pr[2] as Vector2) * k / ppu * 0.5, (pr[2] as Vector2) * k / ppu).grow(4.0 / ppu)
			other += 500.0 * _frac(prr, rg)
		pen += other
		pen += 30.0 * _frac(r, o.rect)                   # over its own buildings: a little
		total += float(ev[2]) * pen
		if float(ev[0]) == DESIGN_FREE and float(ev[1]) == 1.0:
			detail["route_u"] = route * 0.1
			detail["hide"] = hide
			detail["other"] = other
	# it must read as this city's name: close to the buildings (not trees, not the base plate) and
	# with no piece standing between the name and the city
	var c1 := q + off_px / _ppu(1.0)
	var r1 := Rect2(c1 - size / _ppu(1.0) * 0.5, size / _ppu(1.0))
	var gap := INF
	for sq in (o.silh as PackedVector2Array):
		gap = minf(gap, _rect_point_dist(r1, sq))
	var between := 0
	var edge := Vector2(clampf(o.centre.x, r1.position.x, r1.end.x), clampf(o.centre.y, r1.position.y, r1.end.y))
	for bd: Array in o.bodies:
		if float(bd[1]) >= 1.0 and _seg_hits_rect(edge, o.centre, bd[0]) and not (bd[0] as Rect2).intersects(o.rect):
			between += 1
	var betw_pins := 0
	for pn: Array in o.pins:
		if float(pn[3]) >= 1.0 and _seg_hits_rect(edge, o.centre, _px_rect(pn, _ppu(1.0))):
			betw_pins += 1
	between += betw_pins / 3
	# unambiguous: clearly nearer its own city than any neighbour, and not stacked with another
	# city's name like a list
	var ambiguous := 0.0
	for oc in o.other_silh:
		var dmin := INF
		for sq in (o.other_silh[oc] as PackedVector2Array):
			dmin = minf(dmin, _rect_point_dist(r1, sq))
		ambiguous += maxf(0.0, gap + 1.8 - dmin)
	for pc in placed:
		var pr: Array = placed[pc]
		var pcz: Vector2 = pr[0] + (pr[1] as Vector2) / _ppu(1.0)
		var prr := Rect2(pcz - (pr[2] as Vector2) / _ppu(1.0) * 0.5, (pr[2] as Vector2) / _ppu(1.0))
		if prr.grow(26.0 / _ppu(1.0)).intersects(r1):
			ambiguous += 1.5
	detail["gap"] = gap
	detail["between"] = between
	detail["ambiguous"] = ambiguous
	return total + 110.0 * gap + 3.0 * c1.distance_to(o.centre) + 40.0 * between + 70.0 * ambiguous


func solve() -> void:
	var paths = board.paths
	var per := _obstacles()
	var placed := {}                 # city id -> [attach view point, offset px, size px]
	var order: Array = paths.city.keys()
	order.sort_custom(func(a, b): return (per[a].routes as Array).size() > (per[b].routes as Array).size())
	for pass_i in 3:
		for cid in order:
			if pass_i > 0:
				placed.erase(cid)
			var o: Dictionary = per[cid]
			var size: Vector2 = (board._plaques[cid] as Control).size
			var B: Rect2 = o.rect
			var ppu1 := _ppu(1.0)
			var w1 := size.x / ppu1
			var h1 := size.y / ppu1
			var best_s := INF
			var best := []
			for g in [-0.6 * h1, -0.3 * h1, 0.05, 0.3, 0.6, 1.0]:
				for d in [-0.5, -0.35, -0.2, -0.1, 0.0, 0.1, 0.2, 0.35, 0.5]:
					var cands := {
						"下": [Vector2(B.get_center().x + d * w1, B.end.y + g + h1 * 0.5), 0.0],
						"上": [Vector2(B.get_center().x + d * w1, B.position.y - g - h1 * 0.5), 6.0],
						"左": [Vector2(B.position.x - g - w1 * 0.5, B.get_center().y + d * B.size.y), 4.0],
						"右": [Vector2(B.end.x + g + w1 * 0.5, B.get_center().y + d * B.size.y), 4.0],
						"左上": [Vector2(B.position.x - g * 0.7 - w1 * 0.35 + d * w1 * 0.4, B.position.y - g * 0.7 - h1 * 0.35), 7.0],
						"右上": [Vector2(B.end.x + g * 0.7 + w1 * 0.35 + d * w1 * 0.4, B.position.y - g * 0.7 - h1 * 0.35), 7.0],
						"左下": [Vector2(B.position.x - g * 0.7 - w1 * 0.35 + d * w1 * 0.4, B.end.y + g * 0.7 + h1 * 0.35), 3.0],
						"右下": [Vector2(B.end.x + g * 0.7 + w1 * 0.35 + d * w1 * 0.4, B.end.y + g * 0.7 + h1 * 0.35), 3.0],
					}
					for side in cands:
						var c: Vector2 = cands[side][0]
						var ai := _attach_index(o, c, size)
						var q: Vector2 = (o.silh as PackedVector2Array)[ai]
						var off := (c - q) * ppu1
						var sc := _score(cid, q, off, size, o, placed) + float(cands[side][1])
						if sc < best_s:
							best_s = sc
							best = [q, off, ai, side]
			var det := {}
			_score(cid, best[0], best[1], size, o, placed, det)
			placed[cid] = [best[0], best[1], size]
			attach[cid] = [(o.silh_w as PackedVector3Array)[best[2]], best[1]]
			sides[cid] = [best[3], best_s, det]
	for cid in attach:
		board.plaque_anchors[cid] = attach[cid][0]
		board.plaque_offsets[cid] = attach[cid][1]
	board._layout_plaques()
	for cid in order:
		var det: Dictionary = sides[cid][2]
		print("PLAQUE %-14s %-2s penalty %6.1f  route %.1f u  pieces/coins/badges %.0f  others %.0f  gap %.2f u  between %d  ambiguous %.2f" % [cid, sides[cid][0], sides[cid][1], float(det.get("route_u", 0)), float(det.get("hide", 0)), float(det.get("other", 0)), float(det.get("gap", 0)), int(det.get("between", 0)), float(det.get("ambiguous", 0))])


func save() -> void:
	var cities := {}
	for cid in board.plaque_anchors:
		var a: Vector3 = board.plaque_anchors[cid]
		var o: Vector2 = board.plaque_offsets.get(cid, Vector2.ZERO)
		cities[cid] = {"anchor": [snappedf(a.x, 0.001), snappedf(a.y, 0.001), snappedf(a.z, 0.001)], "offset_px": [snappedf(o.x, 0.1), snappedf(o.y, 0.1)], "side": String(sides.get(cid, ["手动"])[0])}
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema": "claude_merchant_board_plaque_layout_v1",
		"note": "Each city's name plaque: centred offset_px (board canvas px) from anchor, a world point on the city's buildings, so it stays on the city at every zoom (tools/merchant_board_claude_plaque_layout.tscn).",
		"cities": cities}, "  "))
	f.close()
	print("PLAQUE LAYOUT SAVED ", OUT)


# ------------------------------------------------------------------ direct manipulation
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		var pos := board.get_local_mouse_position()
		if mb.pressed:
			for cid in board._plaques:
				var tag: Control = board._plaques[cid]
				if Rect2(tag.position, tag.size).has_point(pos):
					_drag_cid = cid
					_drag_off = tag.position + tag.size * 0.5 - pos
					get_viewport().set_input_as_handled()
					return
		elif _drag_cid != "":
			_reanchor(_drag_cid)
			_drag_cid = ""
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _drag_cid != "":
		var pos := board.get_local_mouse_position() + _drag_off
		if not board.plaque_anchors.has(_drag_cid):
			board.plaque_anchors[_drag_cid] = board._node_anchor(_drag_cid)
		board.plaque_offsets[_drag_cid] = pos - board._to_view(board.plaque_anchors[_drag_cid])
		sides[_drag_cid] = ["手动", 0.0]
		board._layout_plaques()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_S:
				save()
				_status.text = "已保存 " + OUT
			KEY_A:
				solve()
				_status.text = "已重新自动排布（未保存，按 S 保存）"


## after a drag: hang the plaque from the building point nearest to it, so it keeps its place
## relative to the city at every zoom
func _reanchor(cid: String) -> void:
	var tag: Control = board._plaques[cid]
	var centre := tag.position + tag.size * 0.5
	var r := Rect2(tag.position, tag.size)
	var best := Vector3.INF
	var bd := INF
	for w in _city_silhouette_world(cid):
		var sp: Vector2 = board._to_view(w)
		var d := _rect_point_dist(r, sp) + 0.02 * sp.distance_to(centre)
		if d < bd:
			bd = d
			best = w
	if best == Vector3.INF:
		return
	board.plaque_anchors[cid] = best
	board.plaque_offsets[cid] = (centre - board._to_view(best)) / board.plaque_scale()
	board._layout_plaques()


# ------------------------------------------------------------------ review captures
func _shots(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for zw: Array in ZOOMS:
		var z := float(zw[0])
		for cid in board.paths.city:
			board._zoom = z
			board._goal = board._focus_point(board._node_anchor(cid))
			board._target = board._goal
			board._apply_camera()
			board._layout_plaques()
			for _i in 3:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var s := float(img.get_width()) / board.size.x
			var c: Vector2 = board._to_view(board._node_anchor(cid)) * s
			var r := Rect2i(Vector2i(int(c.x - 330), int(c.y - 240)), Vector2i(660, 480)).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
			img.get_region(r).save_png("%s/%s_z%s.png" % [dir, cid, str(z).replace(".", "_")])
	board._zoom = Board.MIN_ZOOM
	board._goal = Vector3(64, 0, 30)
	board._target = board._goal
	board._apply_camera()
	board._layout_plaques()
	for _i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dir + "/overview.png")
	board._zoom = 1.0
	board._apply_camera()
	print("PLAQUE SHOTS ", dir)
