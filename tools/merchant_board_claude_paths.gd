extends RefCounted
## The formal board graph (data/rulesets/lshu_configurable_v1/board_edges.json: 54 nodes, 57 edges) laid
## onto Claude's 3D merchant board (assets/merchant_board_claude/board_layout.json).
##   stop nodes  sit on their route line (layout.stops)
##   city nodes  have one stand per incident route, outside the city (Carlos: 「放在门口」):
##               a road ends at a door just outside the wall, a sea route at a berth in open
##               water in front of the harbour (the whole hull clear of the coast)
##   edge (a,b)  the stretch of its route polyline between the two nodes
## path_for(node_ids, from_rid) returns the 3D points a piece travels for a move, with LAND / SEA
## per point, the span ends (knots: each road step and each pass through a city is a span with its
## own time on the piece) and the hops. A piece passing through a city from one road to another, or
## switching transport there, never walks through the buildings or sails onto land: it goes into
## the city at one stand and comes out at the other (a hop: the piece dips out and pops back in,
## camel <-> boat when the media differ).
## Sea lanes are pushed toward open water where a route runs closer to the coast than half a hull;
## where a strait or harbour is narrower than the hull itself (the Gulf of Suez, Bab-el-Mandeb,
## Malacca) the boat fits itself to the water (hull_fit: it sails a little smaller there).

const EDGES := "res://data/rulesets/lshu_configurable_v1/board_edges.json"
const SEA_DIST := "res://assets/merchant_board_claude/terrain/sea_dist.png"
const LAND_CLEAR := 0.2          # sea_dist: water closer than this to land counts as land (cliff lip)
const LANE_CLEAR := 0.75         # a sea lane keeps this far from land where the water allows
const DOOR_OUT := 0.75           # a road's door: this far out along the road from the city edge
const BERTH_MAX := 3.2           # a berth is at most this far out from the city edge
const FIT_STEPS := [1.0, 0.92, 0.84, 0.76, 0.68, 0.6]

var layout: Dictionary
var routes := {}          # route id -> {pts, cum, type, a, b, s0, s1, stop_s: {stop_id: s}}
var stop_pos := {}        # stop id -> Vector3 (on the line)
var city := {}            # city id -> layout city dict
var edge_route := {}      # "a|b" -> route id
var gates := {}           # city id -> {route id: Vector3 stand (door / berth)}
var boat_len := 1.8
var boat_beam := 1.0
var _dist: Image
var _board := Rect2(0, 0, 128, 59.63)
## 自制地图（docs/design/map-editor-20260930/DESIGN.md 3.12.7、3.11）：工坊的轻量刷新、几何规则要反复 build。
## 打开后，一条路的结果（航道、泊位、停靠点弧长）按「这条路的点列 + 两端的城 + 它的停靠点 + 船身」记下来，
## 下次 build 这些都没变就直接用（每条路只由这些决定，所以和重算逐字节相同）；陆海采样图也只读一次。默认关，棋盘 _ready 照旧全算。
var use_route_cache := false
static var _route_cache := {}
static var _sampler_cache: Image


func build(lay: Dictionary, hull_length := 1.8, hull_beam := 1.0) -> void:
	routes.clear();stop_pos.clear();city.clear();edge_route.clear();gates.clear()
	layout = lay
	boat_len = hull_length
	boat_beam = hull_beam
	var b: Dictionary = layout.get("board", {})
	_board = Rect2(float(b.get("x0", 0.0)), float(b.get("z0", 0.0)), float(b.get("x1", 128.0)) - float(b.get("x0", 0.0)), float(b.get("z1", 59.63)) - float(b.get("z0", 0.0)))
	if use_route_cache and _sampler_cache != null:
		_dist = _sampler_cache
	else:
		_load_sampler()
		if use_route_cache:
			_sampler_cache = _dist
	for c: Dictionary in layout.cities:
		city[c.id] = c
		gates[c.id] = {}
	for s: Dictionary in layout.stops:
		stop_pos[s.id] = Vector3(s.x, s.y, s.z)
	# 自制地图推导出来的布局在每条路上写明了两端的城（挪过城以后「离首尾点最近的城」可能认错，
	# docs/design/map-editor-20260930/DESIGN.md 3.10.3 第 2 步）；原布局没有这两个键，照旧找最近的城
	var named_ends := {}
	var raw_points := {}
	for r: Dictionary in layout.routes:
		var pts := PackedVector3Array()
		for q: Array in r.points:
			pts.append(Vector3(q[0], q[1], q[2]))
		routes[r.id] = {"pts": pts, "cum": _cum(pts), "type": r.type, "stop_s": {}}
		if r.has("a") and r.has("b"):
			named_ends[r.id] = [str(r.a), str(r.b)]
		if use_route_cache:
			raw_points[r.id] = r.points
	for rid in routes:
		var R: Dictionary = routes[rid]
		if named_ends.has(rid):
			R.a = named_ends[rid][0]
			R.b = named_ends[rid][1]
		else:
			R.a = _nearest_city(R.pts[0])
			R.b = _nearest_city(R.pts[R.pts.size() - 1])
		var ckey := ""
		if use_route_cache:
			ckey = _route_key(rid, R, raw_points[rid])
			if _route_cache.has(ckey):
				var C: Dictionary = _route_cache[ckey]
				R.pts = C.pts
				R.cum = C.cum
				R.stop_s = (C.stop_s as Dictionary).duplicate()
				R.s0 = C.s0
				R.s1 = C.s1
				gates[R.a][rid] = _at(R, R.s0)
				gates[R.b][rid] = _at(R, R.s1)
				continue
		_project_stops(rid)
		var L: float = R.cum[R.cum.size() - 1]
		R.s0 = _stand_s(rid, false)
		R.s1 = L - _stand_s(rid, true)
		if R.type == "SEA":
			_centre_lane(rid)
			_project_stops(rid)
		gates[R.a][rid] = _at(R, R.s0)
		gates[R.b][rid] = _at(R, R.s1)
		if use_route_cache:
			if _route_cache.size() > 400:
				_route_cache.clear()
			_route_cache[ckey] = {"pts": R.pts, "cum": R.cum, "stop_s": (R.stop_s as Dictionary).duplicate(), "s0": R.s0, "s1": R.s1}
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(EDGES))
	var effective:Array=layout.effective_edges if layout.has("effective_edges") else data["items"]
	for e: Dictionary in effective:
		edge_route[str(e.a) + "|" + str(e.b)] = str(e.corridor_id)
		edge_route[str(e.b) + "|" + str(e.a)] = str(e.corridor_id)
	# 自制地图新城的 3 条边（推导出来的布局才有这一段；正式边文件一个字节不改）
	for e: Dictionary in layout.get("edges_extra", []):
		edge_route[str(e.a) + "|" + str(e.b)] = str(e.corridor_id)
		edge_route[str(e.b) + "|" + str(e.a)] = str(e.corridor_id)


## 一条路的缓存键：点列、两端的城（位置、占地）、它的停靠点、船身、棋盘范围
func _route_key(rid: String, R: Dictionary, points: Array) -> String:
	var parts := PackedStringArray([rid, str(R.type), str(points.size()), str(points.hash()), str(R.a), str(R.b), str(boat_len), str(boat_beam), str(_board)])
	for cid in [R.a, R.b]:
		var c: Dictionary = city.get(cid, {})
		parts.append("%s,%s,%s" % [str(c.get("x", 0.0)), str(c.get("z", 0.0)), str(c.get("foot", 3.5))])
	var sids := stop_pos.keys()
	sids.sort()
	for sid in sids:
		if String(sid).begins_with(String(rid) + "_"):
			parts.append("%s=%s" % [sid, str(stop_pos[sid])])
	return "|".join(parts)


func _cum(pts: PackedVector3Array) -> PackedFloat32Array:
	var cum := PackedFloat32Array([0.0])
	for i in range(1, pts.size()):
		cum.append(cum[i - 1] + _xz(pts[i - 1], pts[i]))
	return cum


func _project_stops(rid: String) -> void:
	var R: Dictionary = routes[rid]
	R.stop_s = {}
	for sid in stop_pos:
		if String(sid).begins_with(String(rid) + "_"):
			R.stop_s[sid] = _project(R, stop_pos[sid])


func _nearest_city(p: Vector3) -> String:
	var best := ""
	var bd := INF
	for cid in city:
		var c: Dictionary = city[cid]
		var d := Vector2(p.x - c.x, p.z - c.z).length()
		if d < bd:
			bd = d
			best = cid
	return best


func _project(R: Dictionary, p: Vector3) -> float:
	var pts: PackedVector3Array = R.pts
	var best := 0.0
	var bd := INF
	for i in pts.size():
		var d := Vector2(pts[i].x - p.x, pts[i].z - p.z).length()
		if d < bd:
			bd = d
			best = R.cum[i]
	return best


# ------------------------------------------------------------------ land / water sampler
# assets/merchant_board_claude/terrain/sea_dist.png, written by build_board.py: R = distance to the
# nearest land / 4 (clipped at 4 u), G = land mask, over the whole board. Checked against the
# terrain mesh: nothing above the water lies outside "G > 0.5 or distance < 0.2".
func _load_sampler() -> void:
	var img: Image = Image.load_from_file(ProjectSettings.globalize_path(SEA_DIST)) if OS.has_feature("editor") else null
	if img == null or img.is_empty():
		var tex := load(SEA_DIST) as Texture2D
		if tex != null:
			img = tex.get_image()
	if img != null and img.is_compressed():
		img.decompress()
	_dist = img


## Distance to land at (x, z) in world units; -1 on land. Without the sampler: everything is water.
func water_clearance(x: float, z: float) -> float:
	if _dist == null or _dist.is_empty():
		return 4.0
	var w := _dist.get_width()
	var h := _dist.get_height()
	var u := (x - _board.position.x) / _board.size.x * w - 0.5
	var v := (z - _board.position.y) / _board.size.y * h - 0.5
	var x0 := clampi(int(floor(u)), 0, w - 1)
	var y0 := clampi(int(floor(v)), 0, h - 1)
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var fx := clampf(u - floor(u), 0.0, 1.0)
	var fy := clampf(v - floor(v), 0.0, 1.0)
	var c := _dist.get_pixel(x0, y0).lerp(_dist.get_pixel(x1, y0), fx).lerp(_dist.get_pixel(x0, y1).lerp(_dist.get_pixel(x1, y1), fx), fy)
	if c.g > 0.5:
		return -1.0
	return c.r * 4.0


## The smallest water clearance under a boat hull at p heading yaw (9 x 5 points over the hull's
## footprint); a hull is clear of the coast when this is above LAND_CLEAR.
func hull_clearance(p: Vector3, yaw: float, length := -1.0, beam := -1.0) -> float:
	var hl := (boat_len if length < 0.0 else length) * 0.5
	var hb := (boat_beam if beam < 0.0 else beam) * 0.5
	var fwd := Vector2(cos(yaw), -sin(yaw))
	var side := Vector2(sin(yaw), cos(yaw))
	var worst := INF
	for i in 9:
		for j in 5:
			var q := Vector2(p.x, p.z) + fwd * lerpf(-hl, hl, i / 8.0) + side * lerpf(-hb, hb, j / 4.0)
			worst = minf(worst, water_clearance(q.x, q.y))
	return worst


func hull_clear(p: Vector3, yaw: float) -> bool:
	return hull_clearance(p, yaw) > LAND_CLEAR


## The largest hull scale (1 .. 0.6) that fits the water at p heading yaw: 1 in open water, less
## in a strait or a harbour narrower than the boat.
func hull_fit(p: Vector3, yaw: float) -> float:
	for k in FIT_STEPS:
		if hull_clearance(p, yaw, boat_len * float(k), boat_beam * float(k)) > LAND_CLEAR:
			return float(k)
	return float(FIT_STEPS[FIT_STEPS.size() - 1])


# ------------------------------------------------------------------ stands at the cities
## How far out from a city end of route rid its stand is (a door on a road, a berth at sea).
func _stand_s(rid: String, at_b: bool) -> float:
	var R: Dictionary = routes[rid]
	var L: float = R.cum[R.cum.size() - 1]
	var first_coin := L
	for sid in R.stop_s:
		var s: float = R.stop_s[sid]
		first_coin = minf(first_coin, (L - s) if at_b else s)
	if R.type != "SEA":
		var sd := clampf(DOOR_OUT, 0.0, maxf(first_coin - 1.3, 0.0))
		for extra in [0.5, 0.9, 1.4, 2.0, 2.6]:          # the nearest spot in view
			if not _behind_city(rid, (L - sd) if at_b else sd, at_b):
				break
			var s2: float = sd + float(extra)
			var ss2 := (L - s2) if at_b else s2
			if s2 <= first_coin - 1.3 and _camel_on_land(_at(R, ss2), tangent_yaw(rid, ss2)) and not _behind_city(rid, ss2, at_b):
				return s2
		return sd
	# berth: the first place out from the city where the whole hull is in water, kept off the
	# first coin (its lift ring reaches 0.8) and near the city; failing that, the place where the
	# boat fits best (a narrow harbour: the boat rests a little smaller there)
	var s_max := minf(maxf(first_coin - 0.9, 0.0), BERTH_MAX)
	var best_s := 0.0
	var best := -INF
	var s := 0.0
	while s <= s_max:
		var ss := (L - s) if at_b else s
		var p := _at(R, ss)
		var y := tangent_yaw(rid, ss)
		var c := hull_clearance(p, y)
		if c > LAND_CLEAR + 0.05:
			var sb := minf(s + 0.1, s_max)
			# a berth right behind its city (seen from the camera) moves out to open water in view
			if _behind_city(rid, (L - sb) if at_b else sb, at_b):
				for extra in [0.6, 1.0, 1.5, 2.0]:           # the nearest spot in view
					var s2: float = sb + float(extra)
					var ss2 := (L - s2) if at_b else s2
					if s2 <= maxf(first_coin - 1.7, 0.0) and hull_clearance(_at(R, ss2), tangent_yaw(rid, ss2)) > LAND_CLEAR + 0.05 and not _behind_city(rid, ss2, at_b):
						return s2
			return sb
		var score := hull_fit(p, y) * 10.0 + c
		if score > best:
			best = score
			best_s = s
		s += 0.05
	return best_s


## Is the point of route rid at arc s hidden behind its end city from the board camera (which looks
## north, pitched down 0.76 rad: a stand just north of a city's buildings disappears behind them)?
func _behind_city(rid: String, s: float, at_b: bool) -> bool:
	var R: Dictionary = routes[rid]
	var c: Dictionary = city[R.b if at_b else R.a]
	var p := _at(R, s)
	var foot := float(c.get("foot", 3.5))
	return p.z < float(c.z) - 0.2 and absf(p.x - float(c.x)) < foot * 0.6 and float(c.z) - p.z < foot * 1.1


## Direction of route rid at arc s (toward growing s; sign -1 for the other way), as a yaw.
func tangent_yaw(rid: String, s: float, sign := 1.0) -> float:
	var R: Dictionary = routes[rid]
	var p0 := _at(R, s - 0.5 * sign)
	var p1 := _at(R, s + 0.5 * sign)
	return atan2(-(p1.z - p0.z), p1.x - p0.x)


## Sea lanes stay LANE_CLEAR off the coast where the water allows: points closer are moved up the
## distance field, the offsets smoothed; nothing moves near a coin or inside the berths.
func _centre_lane(rid: String) -> void:
	var R: Dictionary = routes[rid]
	var pts: PackedVector3Array = R.pts
	var cum: PackedFloat32Array = R.cum
	var coins: Array = R.stop_s.values()
	var off := PackedVector2Array()
	off.resize(pts.size())
	var moved := false
	for i in pts.size():
		off[i] = Vector2.ZERO
		var s := cum[i]
		if s < R.s0 + 0.4 or s > R.s1 - 0.4:
			continue
		var near_coin := false
		for c in coins:
			if absf(s - float(c)) < 1.4:
				near_coin = true
		if near_coin:
			continue
		var q := Vector2(pts[i].x, pts[i].z)
		for _k in 4:
			var d := water_clearance(q.x, q.y)
			if d >= LANE_CLEAR or d < 0.0:
				break
			var g := Vector2(water_clearance(q.x + 0.1, q.y) - water_clearance(q.x - 0.1, q.y),
				water_clearance(q.x, q.y + 0.1) - water_clearance(q.x, q.y - 0.1))
			if g.length() < 1e-4:
				break
			q += g.normalized() * minf(LANE_CLEAR - d, 0.2)
		var o := q - Vector2(pts[i].x, pts[i].z)
		if o.length() > 0.6:
			o = o.normalized() * 0.6
		off[i] = o
		moved = moved or o.length() > 1e-3
	if not moved:
		return
	for _pass in 3:
		var sm := PackedVector2Array(off)
		for i in pts.size():
			var acc := Vector2.ZERO
			var n := 0
			for j in range(maxi(0, i - 8), mini(pts.size(), i + 9)):
				acc += off[j]
				n += 1
			sm[i] = acc / float(n)
		off = sm
	for i in pts.size():
		pts[i] = pts[i] + Vector3(off[i].x, 0.0, off[i].y)
	R.pts = pts
	R.cum = _cum(pts)


func is_city(node_id: String) -> bool:
	return city.has(node_id)


## Arc position of a node on route rid (a city: its stand on that route).
func node_s(rid: String, node_id: String) -> float:
	var R: Dictionary = routes[rid]
	if node_id == R.a:
		return R.s0
	if node_id == R.b:
		return R.s1
	return R.stop_s.get(node_id, 0.0)


func route_type(rid: String) -> String:
	return routes[rid].type


## The route a coin lies on (stop ids are "<route id>_NN").
func route_of_stop(stop_id: String) -> String:
	for rid in routes:
		if (routes[rid].stop_s as Dictionary).has(stop_id):
			return rid
	return ""


## Where a piece stands on node_id; for a city, its stand on the given route (or the stand facing
## the camera most, when no route is given).
func node_point(node_id: String, rid := "") -> Vector3:
	if stop_pos.has(node_id):
		var r := route_of_stop(node_id)
		return _at(routes[r], node_s(r, node_id)) if r != "" else stop_pos[node_id]
	var g: Dictionary = gates.get(node_id, {})
	if rid != "" and g.has(rid):
		return g[rid]
	var best := Vector3.ZERO
	var bz := -INF
	for k in g:
		if (g[k] as Vector3).z > bz:
			bz = (g[k] as Vector3).z
			best = g[k]
	return best


## Heading of a piece resting on a node: at a city stand, facing out along its route; on a coin,
## along the route.
func rest_yaw(node_id: String, rid := "") -> float:
	if is_city(node_id):
		if rid == "" or not routes.has(rid):
			return INF
		var R: Dictionary = routes[rid]
		return tangent_yaw(rid, node_s(rid, node_id), 1.0 if node_id == R.a else -1.0)
	var r := route_of_stop(node_id)
	return tangent_yaw(r, node_s(r, node_id)) if r != "" else INF


## The stand a piece uses at a city for the given medium ("LAND" / "SEA"): among the routes of
## that type, the one nearest `near` (or the one facing the camera most); any stand as fallback.
func default_gate_rid(cid: String, m: String, near := Vector3.INF) -> String:
	var g: Dictionary = gates.get(cid, {})
	var best := ""
	var score := INF
	for rid in g:
		var pen := 0.0 if route_type(rid) == m else 1000.0
		var p: Vector3 = g[rid]
		var sc: float = pen + (Vector2(p.x - near.x, p.z - near.z).length() if near != Vector3.INF else -p.z)
		if sc < score:
			score = sc
			best = rid
	return best


## From one stand of a city to another (a hop through the city): {points, media, hops}.
func gate_to_gate(cid: String, rid_a: String, rid_b: String, m0 := "", m1 := "") -> Dictionary:
	var g: Dictionary = gates.get(cid, {})
	if not g.has(rid_a) or not g.has(rid_b):
		return {"points": PackedVector3Array(), "media": PackedStringArray(), "hops": PackedInt32Array()}
	return city_cross(cid, g[rid_a], m0 if m0 != "" else route_type(rid_a), g[rid_b], m1 if m1 != "" else route_type(rid_b))


## Through a city from stand p0 to stand p1: the piece goes in at p0 and comes out at p1 (one hop
## segment; the token dips it out and pops it back in, swapping camel / boat when m0 != m1).
func city_cross(_cid: String, p0: Vector3, m0: String, p1: Vector3, m1: String) -> Dictionary:
	return {"points": PackedVector3Array([p0, p1]), "media": PackedStringArray([m0, m1]), "hops": PackedInt32Array([0])}


func route_between(a: String, b: String) -> String:
	return edge_route.get(a + "|" + b, "")


func _sub(rid: String, s0: float, s1: float) -> PackedVector3Array:
	var R: Dictionary = routes[rid]
	var pts: PackedVector3Array = R.pts
	var cum: PackedFloat32Array = R.cum
	var out := PackedVector3Array()
	var lo := minf(s0, s1)
	var hi := maxf(s0, s1)
	out.append(_at(R, lo))
	for i in pts.size():
		if cum[i] > lo and cum[i] < hi:
			out.append(pts[i])
	out.append(_at(R, hi))
	if s1 < s0:
		out.reverse()
	return out


func _at(R: Dictionary, s: float) -> Vector3:
	var cum: PackedFloat32Array = R.cum
	s = clampf(s, 0.0, cum[cum.size() - 1])
	var i := clampi(cum.bsearch(s) - 1, 0, cum.size() - 2)
	var t := (s - cum[i]) / maxf(cum[i + 1] - cum[i], 1e-5)
	return (R.pts[i] as Vector3).lerp(R.pts[i + 1], t)


## Point of route rid at arc s.
func point_at(rid: String, s: float) -> Vector3:
	return _at(routes[rid], s)


## node_ids: the move as a node sequence [start, ..., end]; from_rid: the route the piece arrived
## on at the start node (for a city start, so it leaves from the right stand).
## Returns {points, media, knots, kinds, hops, end_rid}: knots are the arc positions (xz) where each
## span of the move ends (a road step "edge" between two nodes, a pass through a city "cross"), from
## 0 to the path length; hops are the indices of the segments the piece hops (in at one city stand,
## out at another) instead of travelling.
func path_for(node_ids: Array, from_rid := "") -> Dictionary:
	var pts := PackedVector3Array()
	var media := PackedStringArray()
	var knots := PackedFloat32Array([0.0])
	var kinds := PackedStringArray()
	var hops := PackedInt32Array()
	var cur_rid := from_rid
	var L := 0.0
	for i in range(node_ids.size() - 1):
		var a := str(node_ids[i])
		var b := str(node_ids[i + 1])
		var rid := route_between(a, b)
		if rid == "":
			push_warning("no route between %s and %s" % [a, b])
			continue
		var m := route_type(rid)
		var seg := _sub(rid, node_s(rid, a), node_s(rid, b))
		# leaving a city by another route: hop from the arrival stand to this route's stand
		if is_city(a) and cur_rid != "" and cur_rid != rid and not pts.is_empty():
			hops.append(pts.size() - 1)
			L += _xz(pts[pts.size() - 1], seg[0])
			_append(pts, media, seg[0], m)
			knots.append(L)
			kinds.append("cross")
		for q in seg:
			if not pts.is_empty() and q.is_equal_approx(pts[pts.size() - 1]):
				continue
			if not pts.is_empty():
				L += _xz(pts[pts.size() - 1], q)
			_append(pts, media, q, m)
		knots.append(L)
		kinds.append("edge")
		cur_rid = rid
	return {"points": pts, "media": media, "knots": knots, "kinds": kinds, "hops": hops, "end_rid": cur_rid}


func _xz(a: Vector3, b: Vector3) -> float:
	return Vector2(b.x - a.x, b.z - a.z).length()


func _append(pts: PackedVector3Array, media: PackedStringArray, q: Vector3, m: String) -> void:
	pts.append(q)
	media.append(m)


func _length(pts: PackedVector3Array) -> float:
	var L := 0.0
	for i in range(1, pts.size()):
		L += _xz(pts[i - 1], pts[i])
	return L


## A move as the piece shows it: path_for() plus, when the piece stands at a city stand other than
## the one its route leaves from, the hop to that stand first.
## from_medium: what the piece is now (camel "LAND" / boat "SEA").
func move_path(node_ids: Array, from_rid: String, from_medium: String) -> Dictionary:
	var p := path_for(node_ids, from_rid)
	var start := str(node_ids[0])
	if node_ids.size() < 2 or not is_city(start) or from_rid == "" or (p.points as PackedVector3Array).is_empty():
		return p
	var first_rid := route_between(start, str(node_ids[1]))
	if first_rid == "" or first_rid == from_rid:
		return p
	var pre := gate_to_gate(start, from_rid, first_rid, from_medium, route_type(first_rid))
	var pp: PackedVector3Array = pre.points
	if pp.size() < 2:
		return p
	var pts := PackedVector3Array(pp)
	var media := PackedStringArray(pre.media)
	var shift := _length(pp)
	var knots := PackedFloat32Array([0.0, shift])
	var kinds := PackedStringArray(["cross"])
	var hops := PackedInt32Array([0])
	for i in range(1, (p.points as PackedVector3Array).size()):
		pts.append(p.points[i])
		media.append(p.media[i])
	var pk: PackedFloat32Array = p.knots
	for i in range(1, pk.size()):
		knots.append(pk[i] + shift)
	kinds.append_array(p.kinds)
	for h in p.hops:
		hops.append(h + pp.size() - 1)
	return {"points": pts, "media": media, "knots": knots, "kinds": kinds, "hops": hops, "end_rid": p.end_rid}


## A transport switch at a city: a hop from the stand the piece is at to the nearest stand of the
## other medium (the camel walks down to the harbour and L叔 puts out in the boat, or the reverse).
## {points, media, knots, kinds, hops, end_rid}
func switch_path(cid: String, rid0: String, m0: String, m1: String) -> Dictionary:
	if rid0 == "":
		rid0 = default_gate_rid(cid, m0)
	var rid1 := default_gate_rid(cid, m1, node_point(cid, rid0))
	var r := gate_to_gate(cid, rid0, rid1, m0, m1)
	var pts: PackedVector3Array = r.points
	if pts.size() < 2 or rid1 == rid0:
		var here := node_point(cid, rid0)
		pts = PackedVector3Array([here, here + Vector3(0.02, 0, 0)])
	return {"points": pts, "media": PackedStringArray([m0, m1]), "knots": PackedFloat32Array([0.0, maxf(_length(pts), 0.02)]),
		"kinds": PackedStringArray(["switch"]), "hops": PackedInt32Array([0]), "end_rid": rid1}


## Where pieces sharing a node stand: n slots [{off: offset from the node point, scale}], slot 0 on
## the node. Boats line up bow to stern along their route (outward from a city stand, never onto a
## coin or another city's stand, at most ~3.5 out); where a harbour or strait has no room for a
## second full-size hull, the extra boat is drawn smaller so the hulls neither touch land nor each
## other. Camels stand beside the road or back along it, all four hooves on land.
func slot_offsets(node_id: String, rid: String, medium: String, n: int) -> Array:
	var out: Array = [{"off": Vector3.ZERO, "scale": 1.0}]
	if n <= 1:
		return out
	var r := rid if (is_city(node_id) and routes.has(rid)) else route_of_stop(node_id)
	if r == "":
		for k in range(1, n):
			out.append({"off": Vector3(0.0, 0.0, 0.6 * k * (1 if k % 2 == 1 else -1)), "scale": 1.0})
		return out
	var R: Dictionary = routes[r]
	var s := node_s(r, node_id)
	var base := _at(R, s)
	var rest := rest_yaw(node_id, rid)
	var outward := 1.0
	if is_city(node_id):
		outward = 1.0 if node_id == R.a else -1.0
	if medium == "SEA":
		_sea_slots(out, n, r, R, s, base, rest, outward, is_city(node_id), node_id)
	else:
		_land_slots(out, n, r, R, s, base, rest, outward, is_city(node_id), node_id)
	return out


func _near_other_marks(p: Vector3, node_id: String, own_stand: Vector3, coin_r: float, stand_r: float) -> bool:
	for sid in stop_pos:
		if sid != node_id and _xz(stop_pos[sid], p) < coin_r:
			return true
	for cid in gates:
		for g in gates[cid]:
			var q: Vector3 = gates[cid][g]
			if not q.is_equal_approx(own_stand) and _xz(q, p) < stand_r:
				return true
	return false


func _sea_slots(out: Array, n: int, r: String, R: Dictionary, s: float, base: Vector3, rest: float, outward: float, at_city: bool, node_id: String) -> void:
	# candidates: along the route (outward first at a city) and abreast; each boat is drawn at the
	# size that keeps it off the land and clear of the boats already placed (treated as circles of
	# radius 0.87 x hull length x scale)
	var step := boat_len * 0.95
	var side := Vector3(sin(rest), 0.0, cos(rest))
	var cands: Array = []          # [arc offset, lateral offset]
	var dirs: Array = [outward] if at_city else [1.0, -1.0]
	for m in [1.0, 0.75, 1.5, 0.5, 2.0]:
		for d in dirs:
			cands.append([step * m * float(d), 0.0])
	for lat in [boat_beam * 0.8, -boat_beam * 0.8]:
		cands.append([0.0, lat])
	if at_city:
		for m in [0.5, 1.0]:
			cands.append([-step * m * outward, 0.0])
	var placed: Array = [[base, 1.0]]      # [point, scale]
	while out.size() < n:
		var best: Dictionary = {}
		var best_score := -INF
		for c: Array in cands:
			var ss: float = s + float(c[0])
			if ss < R.s0 - 0.01 or ss > R.s1 + 0.01:
				continue
			var p := _at(R, ss) + side * float(c[1])
			if _near_other_marks(p, node_id, base, 0.0, 1.0):
				continue                      # never on another city's stand
			var f := hull_fit(p, rest)
			for q: Array in placed:
				var d := _xz(q[0], p)
				f = minf(f, d / (boat_len * 0.5 * 0.97) - float(q[1]))
			if f < 0.4:
				continue
			var score := minf(f, 1.0) * 10.0 - Vector2(float(c[0]), float(c[1])).length() * 0.6
			if _near_other_marks(p, node_id, base, 1.35, 1.0):
				score -= 3.0                  # rather not on a coin, if there is anywhere else
			if score > best_score:
				best_score = score
				best = {"off": p - base, "scale": minf(f, 1.0), "p": p}
		if best.is_empty():
			# nowhere with room nearby (the Gulf of Suez, a 3rd / 4th boat): further along the route
			# either way, as small as it takes to keep clear of the others
			var best_f := -INF
			for j in range(1, 6):
				for d in [outward, -outward]:
					var ss2: float = s + float(d) * 0.8 * float(j)
					if ss2 < R.s0 - 0.01 or ss2 > R.s1 + 0.01:
						continue
					var p2 := _at(R, ss2)
					if _near_other_marks(p2, node_id, base, 0.0, 1.0):
						continue
					var f2 := hull_fit(p2, rest)
					for q: Array in placed:
						f2 = minf(f2, _xz(q[0], p2) / (boat_len * 0.5 * 0.97) - float(q[1]))
					if f2 > best_f:
						best_f = f2
						best = {"off": p2 - base, "scale": clampf(f2, 0.22, 1.0), "p": p2}
			if best.is_empty():
				var p3 := _at(R, clampf(s + outward * 0.8, R.s0, R.s1))
				best = {"off": p3 - base, "scale": 0.3, "p": p3}
		placed.append([best.p, best.scale])
		out.append({"off": best.off, "scale": best.scale})


func _camel_on_land(p: Vector3, yaw: float) -> bool:
	# the four hooves and the belly of a camel (camel length ~1.1, legs at +0.22 / -0.42 of it)
	var fwd := Vector2(cos(yaw), -sin(yaw))
	var side := Vector2(sin(yaw), cos(yaw))
	for q: Vector2 in [Vector2(0.24, 0.16), Vector2(0.24, -0.16), Vector2(-0.46, 0.16), Vector2(-0.46, -0.16), Vector2(0, 0)]:
		var w := Vector2(p.x, p.z) + fwd * q.x + side * q.y
		if water_clearance(w.x, w.y) >= 0.0:
			return false
	return true


func _land_slots(out: Array, n: int, r: String, R: Dictionary, s: float, base: Vector3, rest: float, outward: float, at_city: bool, node_id: String) -> void:
	var side := Vector3(sin(rest), 0.0, cos(rest))
	var cands: Array = []          # [lateral, arc offset]
	for lat in [0.62, -0.62, 1.24, -1.24]:
		cands.append([lat, 0.0])
	for along in [1.3, -1.3, 2.6]:
		cands.append([0.0, along * (outward if at_city else 1.0)])
		cands.append([0.62, along * (outward if at_city else 1.0)])
		cands.append([-0.62, along * (outward if at_city else 1.0)])
	var used: Array = [Vector3.ZERO]
	for c: Array in cands:
		if out.size() >= n:
			break
		var ss: float = clampf(s + float(c[1]), R.s0, R.s1)
		var q: Vector3 = _at(R, ss) + side * float(c[0])
		var off := q - base
		var clash := false
		for u: Vector3 in used:
			if Vector2(off.x - u.x, off.z - u.z).length() < 0.55:
				clash = true
		if clash or not _camel_on_land(q, rest) or _near_other_marks(q, node_id, base, 0.9, 1.5):
			continue
		used.append(off)
		out.append({"off": off, "scale": 1.0})
	var k := 1
	while out.size() < n:
		out.append({"off": side * 0.3 * k, "scale": 0.8})
		k += 1
