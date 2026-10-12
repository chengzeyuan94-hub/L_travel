class_name CustomMapGeoRules

## 几何规则、自动画路、可达区（绿区）（docs/design/map-editor-20260930/DESIGN.md 3.11、3.12.5）。
## 工坊拖动时实时查，游戏导入时再查一遍；判断复用运行时 Paths 的代码（陆海采样、码头搜索、_camel_on_land、hull_fit），
## 不另写近似。归 WP3。
##
## 门槛都是起步值，按原版 16 城、19 路原样当作「全部改过」喂进来必须 0 报错定下（tests/custom_map_geo_tests.gd 的原版回验）。
## 与 3.11 表里写法不同、按原版实测改过的几处（都写在常量旁边）：
##   G_SLOPE   高差只看城心 0.3·foot 这一圈（整个占地椭圆会伸到海边悬崖上：罗马 0.85、金城 1.01）
##   G_PEAK    只看棋盘上真的摆着的山（kit 里非森林的山体，半径按模型在地面那一圈量）。layout.peaks 是烘焙的输入：
##             石头山已经并成 kit 里的山体，丘陵已经烘进地面（由 G_SLOPE 管），再拿它的圆去拦会把一半的陆地判成「大山」；
##             路线离山只管陆路（海路本来就在海上；原版吉达—阿丹海路离海边的山 0.21）
##   G_COAST   码头处船身缩到 0.6 倍时整个在水里（离岸 > 0）；3.11 写的是「整条船在水里」，原版有码头只能停 0.76 倍的船
##   G_ROUTE_SEA  最窄处：船身缩到 0.6 倍时整个在水里（离岸 > 0.05）；照字面「离岸 > 0.2」原版吉达—阿丹、大光—真腊过不了
##   G_STAND   码头：船在那里至少能以 0.76 倍大小停（原版真腊、开罗各有一个码头就是 0.76）；照字面 hull_clear 原版 3 个码头过不了
## 3.11 表外多出的三个码：G_DATA（覆盖层的数据格式坏了，见 CustomBoardLayout.overlay_error）、G_SIZE（新城大小
## 0.90–1.10，3.2 的字段表把它归到几何规则）、G_ROUTE_SHORT（G_ROUTE_LEN 太短时的孩子话，错误码仍是 G_ROUTE_LEN）。
## 返回的每一条都是 {code, target, kid, tech}：target 是城 id 或路线 id；kid 是孩子话；tech 是给人查的数。
##
## 两档（3.11「性能」：拖动时每帧只跑受影响对象的规则 ≤ 16 ms，松手后跑全套 ≤ 150 ms）：
##   拖动快检 check_object(…, full = false)：不建 Paths 的规则——城的全部规则（G_COAST 除外）、路的 G_BOUNDS / G_ROUTE_LEN /
##             G_ROUTE_LAND / G_PEAK / G_CITY_ON_ROUTE / G_ROUTE_CROSS / G_STOP。一条海路建一次 Paths 就要 25 ms（码头搜索、
##             推航道），拖动时放不下；
##   松手全检 check(…)（或 check_object(…, full = true)）：再加上要在推导后的布局上建 Paths 的 G_COAST、G_ROUTE_SEA、G_STAND。
## 路的几何（xz 点列、包围盒、1 u 格子里的线段）按「路 id + 点列」缓存，拖动时只有被拖的那几条路重算。

const Paths := preload("res://tools/merchant_board_claude_paths.gd")
const HULL_LEN := 1.8                 # 玩家的船（merchant_board_claude_token.gd boat_size），棋盘用它建 Paths
const HULL_BEAM := 1.8 * 0.55

const BOARD_MIN := Vector2(4.0, 4.0)
const BOARD_MAX := Vector2(124.0, 55.6)
const ROUTE_INSET := 1.0
const LAND_FRAC := 0.9
const CITY_GAP := 7.0                 # 原版最挤的一对：金城—平城京 7.33
const CITY_ROUTE_EXTRA := 0.6         # 城心到别的路 ≥ foot/2 + 0.6
const PEAK_ROUTE_EXTRA := 0.3         # 陆路离山体中心 ≥ s × R_asset + 0.3（原版最近 0.33）
const SLOPE_MAX := 0.35               # 城心 0.3·foot 圈内高差（原版最大 0.126，平城京）
const CENTRE_MIN := 0.6               # 城心高度（原版最低 0.78，平城京）
const LAND_END_SKIP := 1.0
const LAND_ON_FRAC := 0.99
const LAND_WET_RUN := 0.3
const SEA_LAND_CLEAR := 0.2           # Paths.LAND_CLEAR
const SEA_NARROW_SCALE := 0.6         # Paths.FIT_STEPS 的最小值
const SEA_NARROW_CLEAR := 0.05        # 原版最窄：吉达—阿丹 0.113
## 航道上一点离岸到这么远时，缩到 0.6 倍的船身（外接圆半径 0.62）不管朝哪都整个在水里，不用再逐点量船身：
## 离岸采样图是双线性插值的距离场（斜率不超过 √2），0.62 × √2 + 0.05 = 0.93，再留足余量
const SEA_NARROW_SKIP := 1.2
const CROSS_END := 2.5
const CROSS_SHARED := 4.0
const ROUTE_GAP := 1.0                # 原版最近 1.14（君士坦丁堡—巴格达 / 巴格达—吉达）
const LEN_MIN := 7.0
const LEN_MAX := 36.0
const LEN_RESHAPE := 1.6
const STOP_GAP := 2.2                 # 原版最小 2.55（开罗—吉达）
const STOP_T0 := Vector2(0.20, 0.45)
const STOP_T1 := Vector2(0.55, 0.80)
const STOP_T_GAP := 0.20
const R_MOVE := 6.0                   # D3-A
const YAW_MAX := PI / 4.0
const GATE_FIT_MIN := 0.76
const SIZE_MIN := 0.90                # 新城大小（3.2 字段表）
const SIZE_MAX := 1.10
## 各山体 GLB（归一到高 1.0）在地面那一圈（模型本地 y = 0.05，棋盘上山体摆在地面下 0.05·s）的最大半径，
## 2026-10-01 从 assets/merchant_board_claude/mountains/*.glb 量出（WP3）
const R_ASSET := {
	"alpine_massif": 0.917, "alpine_single": 0.707, "karst_ridge": 1.282, "karst_single": 0.564,
	"strata_cluster": 1.068, "strata_ridge": 1.333, "strata_single": 0.894,
	"volcano_cluster": 0.951, "volcano_single": 0.755,
	"forest_cluster": 0.956, "forest_ridge": 1.362, "forest_single": 0.835,
}
## 路与路的近距离检查：每隔这么多个点先粗查一次（半径放宽半个窗口），粗查碰到别的路才逐点细查。距离函数 1-Lipschitz，
## 所以结果与逐点查完全相同
const CROSS_STRIDE := 4
const CROSS_HALF := 2

const KID := {
	"G_BOUNDS": "太靠边啦",
	"G_CITY_LAND": "城要放在陆地上",
	"G_COAST": "海港城要挨着大海",
	"G_CITY_GAP": "离%s太近了",
	"G_CITY_ON_ROUTE": "这里压到了商路",
	"G_PEAK": "这里是大山，城建不上去",
	"G_SLOPE": "这里太陡了",
	"G_ROUTE_LAND": "骆驼路不能下海",
	"G_ROUTE_SEA": "船会搁浅的",
	"G_ROUTE_CROSS": "两条路靠得太近，会看不清",
	"G_ROUTE_LEN": "这条路太长了",
	"G_ROUTE_SHORT": "这条路太短了",
	"G_STOP": "两个停靠点挤在一起了",
	"G_MOVE_FAR": "%s只能在老家附近挪一挪",
	"G_STAND": "这里骆驼站不稳",
	"G_STAND_SEA": "船在这里靠不了岸",
	"G_SIZE": "这座城不能再大或再小了",
	"G_DATA": "这张地图的数据坏了",
}

static var _reach_cache := {}
static var _base_ref := {}


# ================================================================ 规则

## 全套几何规则（松手全检，也是游戏导入时的那一遍）：返回 [{code, target, kid, tech}]，没有问题时为空。
## 只查新的和改过的对象：与 base_layout 比，位置、朝向变了的城、新城；点列变了的路、新路。
## 覆盖层或推导结果的数据格式坏了（derive 返回了 {"error": …}、覆盖层里的城和路在推导结果里找不到）时只报一条 G_DATA。
static func check(derived: Dictionary, base_layout: Dictionary, overlay: Dictionary, geo: CustomMapGeo) -> Array[Dictionary]:
	if geo == null:
		geo = CustomMapGeo.shared()
	geo = _layout_geo(derived, geo)
	var bad := data_errors(derived, base_layout, overlay)
	if not bad.is_empty():
		return bad
	var base_cities := _by_id(base_layout.get("cities", []))
	var base_routes := _by_id(base_layout.get("routes", []))
	var city_ids: Array[String] = []
	for c: Dictionary in derived.get("cities", []):
		var b: Dictionary = base_cities.get(String(c.id), {})
		if b.is_empty() or float(b.x) != float(c.x) or float(b.z) != float(c.z) or float(b.get("rotation", 0.0)) != float(c.get("rotation", 0.0)) or _city_height_edited(c, derived):
			city_ids.append(String(c.id))
	var route_ids: Array[String] = []
	for r: Dictionary in derived.get("routes", []):
		var b: Dictionary = base_routes.get(String(r.id), {})
		if b.is_empty() or b.points != r.points or _stop_t_of(overlay, String(r.id)).size() > 0:
			route_ids.append(String(r.id))
	return check_objects(derived, city_ids, route_ids, geo, base_layout, overlay, true)


## 只查一个对象：一座城（连同连着它的路），或一条路。默认是拖动快检（不建 Paths，见文件头）；full = true 时连
## G_COAST、G_ROUTE_SEA、G_STAND 一起查（松手后只想查这一个对象时用；整张图松手全检用 check）
static func check_object(derived: Dictionary, object_id: String, geo: CustomMapGeo, full := false) -> Array[Dictionary]:
	if geo == null:
		geo = CustomMapGeo.shared()
	geo = _layout_geo(derived, geo)
	var bad := data_errors(derived, {}, {})
	if not bad.is_empty():
		return bad
	var cities: Array[String] = []
	var routes: Array[String] = []
	var is_city := false
	var is_route := false
	for c: Dictionary in derived.get("cities", []):
		if String(c.id) == object_id:
			is_city = true
	for r: Dictionary in derived.get("routes", []):
		if String(r.id) == object_id:
			is_route = true
	if is_city:
		cities.append(object_id)
		for r: Dictionary in derived.get("routes", []):
			var ends := _ends_of(derived, r)
			if ends[0] == object_id or ends[1] == object_id:
				routes.append(String(r.id))
	elif is_route:
		routes.append(object_id)
	else:
		var out: Array[Dictionary] = []
		_add(out, "G_DATA", object_id, "布局里没有 %s" % object_id)
		return out
	return check_objects(derived, cities, routes, geo, _base(), {}, full)


## 查指定的城和路。base_layout 给出原城原位（G_MOVE_FAR）和原路长（G_ROUTE_LEN）；overlay 给出停靠点比例（G_STOP）。
## full = false 时不建 Paths（拖动快检）。原版回验就是把 16 城、19 路全部传进来。
static func check_objects(derived: Dictionary, city_ids: Array[String], route_ids: Array[String], geo: CustomMapGeo,
		base_layout: Dictionary = {}, overlay: Dictionary = {}, full := true) -> Array[Dictionary]:
	if geo == null:
		geo = CustomMapGeo.shared()
	geo = _layout_geo(derived, geo)
	var out: Array[Dictionary] = []
	var cities := _by_id(derived.get("cities", []))
	var routes := _by_id(derived.get("routes", []))
	var base_cities := _by_id(base_layout.get("cities", []))
	var base_routes := _by_id(base_layout.get("routes", []))
	var idx := _index(derived)
	# 用到 Paths 的规则（码头、站位、海路航道）只在受影响的路上建一份小 Paths：与整张图的 Paths 给出的这几条路逐点相同
	var P: Object = null
	if full:
		var need_routes := {}
		for rid in route_ids:
			need_routes[rid] = true
		for cid in city_ids:
			for r: Dictionary in derived.get("routes", []):
				var e := _ends_of(derived, r)
				if e[0] == cid or e[1] == cid:
					need_routes[String(r.id)] = true
		P = _mini_paths(derived, need_routes.keys())
	for cid in city_ids:
		if cities.has(cid):
			_city_rules(cities[cid], derived, idx, P, geo, base_cities, out)
	for rid in route_ids:
		if routes.has(rid):
			_route_rules(routes[rid], derived, idx, P, geo, base_routes, overlay, cities, out)
	return _dedupe(out)


## 数据格式：推导结果坏了（derive 返回 {"error": …}、没有城表），或覆盖层坏了、覆盖层里的城和路在推导结果里找不到 →
## 一条 G_DATA；都好时为空。base_layout 为空时不查覆盖层（拖动快检只看推导结果）
static func data_errors(derived: Dictionary, base_layout: Dictionary, overlay: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if derived.has("error"):
		_add(out, "G_DATA", "", String(derived.error))
		return out
	if not derived.get("cities") is Array or not derived.get("routes") is Array or (derived.cities as Array).is_empty():
		_add(out, "G_DATA", "", "推导结果里没有城表或路表")
		return out
	if base_layout.is_empty():
		return out
	var bad := CustomBoardLayout.overlay_error(overlay, base_layout)
	if bad != "":
		_add(out, "G_DATA", "", bad)
		return out
	var cities := _by_id(derived.cities)
	var routes := _by_id(derived.routes)
	var moves: Dictionary = overlay.get("moves", {})
	for cid in moves.get("cities", {}):
		if not cities.has(String(cid)):
			_add(out, "G_DATA", String(cid), "推导结果里没有挪过的城 %s" % cid)
			return out
	for rid in moves.get("routes", {}):
		if CustomMapFreeRoutes.enabled(overlay) and overlay.free_routes.routes.get(rid,{}).get("deleted",false):continue
		if not routes.has(String(rid)):
			_add(out, "G_DATA", String(rid), "推导结果里没有改过的路 %s" % rid)
			return out
	for nc: Dictionary in overlay.get("new_cities", []):
		var id := "x_" + String(nc.slot)
		if CustomMapFreeAuthor.enabled(overlay):
			if not cities.has(id):_add(out,"G_DATA",id,"推导结果没有自由城市")
			continue
		var rid := "%s_%s_x_%s" % ["land" if String(nc.route_type) == "LAND" else "sea", String(nc.host), String(nc.slot)]
		if not cities.has(id) or (not routes.has(rid) and not (CustomMapFreeRoutes.enabled(overlay) and overlay.free_routes.routes.get(rid,{}).get("deleted",false))):
			_add(out, "G_DATA", id, "推导结果里没有新城 %s 或它的路 %s" % [id, rid])
			return out
	return out


static func _city_rules(c: Dictionary, derived: Dictionary, idx: LayoutIndex, P: Object, geo: CustomMapGeo, base_cities: Dictionary,
		out: Array[Dictionary]) -> void:
	var id := String(c.id)
	var x := float(c.x)
	var z := float(c.z)
	var foot := float(c.get("foot", 3.4))
	var name := String(c.get("name", id))
	var here := Vector2(x, z)
	if x < BOARD_MIN.x or x > BOARD_MAX.x or z < BOARD_MIN.y or z > BOARD_MAX.y:
		_add(out, "G_BOUNDS", id, "城心 (%.2f, %.2f) 不在 [4, 124] × [4, 55.6] 里" % [x, z])
	# 新城的大小（原城没有 size 这个键）
	if c.has("size"):
		var size := float(c.size)
		if size < SIZE_MIN - 1e-9 or size > SIZE_MAX + 1e-9:
			_add(out, "G_SIZE", id, "大小 %.3f（要在 %.2f–%.2f 之间）" % [size, SIZE_MIN, SIZE_MAX])
	var fs := geo.footprint_stats(x, z, foot)
	if float(fs.land_frac) < LAND_FRAC:
		_add(out, "G_CITY_LAND", id, "占地椭圆里陆地只有 %.0f%%" % (float(fs.land_frac) * 100.0))
	if float(fs.h_range) > SLOPE_MAX or float(fs.h_centre) < CENTRE_MIN:
		_add(out, "G_SLOPE", id, "城心一圈高差 %.3f（上限 %.2f），城心高 %.3f（下限 %.1f）" % [float(fs.h_range), SLOPE_MAX, float(fs.h_centre), CENTRE_MIN])
	# 离别的城
	var nearest := ""
	var nd := INF
	for o: Dictionary in derived.get("cities", []):
		if String(o.id) == id:
			continue
		var d := Vector2(float(o.x) - x, float(o.z) - z).length()
		if d < nd:
			nd = d
			nearest = String(o.get("name", o.id))
	if nd < CITY_GAP:
		_add(out, "G_CITY_GAP", id, "离%s %.2f u（下限 %.1f）" % [nearest, nd, CITY_GAP], [nearest])
	# 压到别的路（先按路的包围盒排除远的）
	var lim := foot * 0.5 + CITY_ROUTE_EXTRA
	for o in idx.geos.size():
		var e: Array = idx.ends[o]
		if e[0] == id or e[1] == id:
			continue
		if not (idx.geos[o] as RouteGeo).bbox.grow(lim).has_point(here):
			continue
		var d := _polyline_dist(here, idx.points[o])
		if d < lim:
			_add(out, "G_CITY_ON_ROUTE", id, "城心离 %s %.2f u（下限 %.2f）" % [idx.rids[o], d, lim])
			break
	# 压山：占地椭圆碰到非森林的山体
	var worst := INF
	for k: Dictionary in derived.get("kit", []):
		if String(k.get("asset", "")).begins_with("forest") or float(k.get("s", 0.0)) <= 0.0:
			continue
		worst = minf(worst, _ellipse_gap(here, foot, Vector2(float(k.x), float(k.z)), float(k.s) * float(R_ASSET.get(String(k.asset), 1.0))))
	if worst < 0.0:
		_add(out, "G_PEAK", id, "占地椭圆压进山里 %.2f u" % -worst)
	# 原城只能在老家附近挪一挪
	if base_cities.has(id):
		var b: Dictionary = base_cities[id]
		var d := Vector2(x - float(b.x), z - float(b.z)).length()
		var dyaw := absf(wrapf(float(c.get("rotation", 0.0)) - float(b.get("rotation", 0.0)), -PI, PI))
		if d > R_MOVE + 1e-6 or dyaw > YAW_MAX + 1e-6:
			_add(out, "G_MOVE_FAR", id, "离原位 %.2f u（上限 %.1f），朝向差 %.1f°（上限 45°）" % [d, R_MOVE, rad_to_deg(dyaw)], [name])
	if P == null:
		return
	# 海港：连着的每条海路，码头处船身至少能以最小的缩放整个待在水里（要 Paths：松手全检才查）
	var gates: Dictionary = (P.get("gates") as Dictionary).get(id, {})
	for rid in gates:
		if String(P.call("route_type", rid)) != "SEA":
			continue
		var g: Vector3 = gates[rid]
		var yaw := float(P.call("rest_yaw", id, rid))
		var clr := float(P.call("hull_clearance", g, yaw, HULL_LEN * SEA_NARROW_SCALE, HULL_BEAM * SEA_NARROW_SCALE))
		if clr <= 0.0:
			_add(out, "G_COAST", id, "%s 的码头不在水里（最小缩放下离岸 %.3f）" % [String(rid), clr])


static func _route_rules(r: Dictionary, derived: Dictionary, idx: LayoutIndex, P: Object, geo: CustomMapGeo, base_routes: Dictionary,
		overlay: Dictionary, cities: Dictionary, out: Array[Dictionary]) -> void:
	var rid := String(r.id)
	var rtype := String(r.type)
	var g := _route_geo(r)
	var pts := g.pts
	var cum := g.cum
	var L := cum[cum.size() - 1] if not cum.is_empty() else 0.0
	var box := g.bbox
	if box.position.x < ROUTE_INSET or box.end.x > 128.0 - ROUTE_INSET or box.position.y < ROUTE_INSET or box.end.y > 59.63125 - ROUTE_INSET:
		for q in pts:
			if q.x < ROUTE_INSET or q.x > 128.0 - ROUTE_INSET or q.y < ROUTE_INSET or q.y > 59.63125 - ROUTE_INSET:
				_add(out, "G_BOUNDS", rid, "路线点 (%.2f, %.2f) 出了棋盘内缩 1 u 的范围" % [q.x, q.y], [], "", {"point": [q.x,q.y]})
				break
	# 长度
	var length_max:=150.0 if CustomMapFreeRoutes.enabled(overlay) else LEN_MAX
	if L > length_max:
		_add(out, "G_ROUTE_LEN", rid, "长 %.2f u（上限 %.1f）" % [L, length_max])
	elif L < LEN_MIN:
		_add(out, "G_ROUTE_LEN", rid, "长 %.2f u（下限 %.1f）" % [L, LEN_MIN], [], "G_ROUTE_SHORT")
	if base_routes.has(rid) and not CustomMapFreeRoutes.enabled(overlay):
		var bg := _route_geo(base_routes[rid])
		var bL := bg.cum[bg.cum.size() - 1]
		if L > bL * LEN_RESHAPE + 1e-6:
			_add(out, "G_ROUTE_LEN", rid, "长 %.2f u，是原长 %.2f 的 %.2f 倍（上限 1.6）" % [L, bL, L / bL])
	var ends := _ends_of(derived, r)
	if rtype == "LAND":
		# 两端各 1 u 之外：≥ 99% 在陆上，连续下水不超过 0.3 u
		var n := 0
		var dry := 0
		var wet := 0.0
		var worst_wet := 0.0
		var wet_indices: Array = []
		for i in pts.size():
			if cum[i] < LAND_END_SKIP or cum[i] > L - LAND_END_SKIP:
				continue
			n += 1
			if geo.is_land(pts[i].x, pts[i].y):
				dry += 1
				wet = 0.0
			else:
				wet_indices.append(i)
				wet += (cum[i] - cum[i - 1]) if i > 0 else 0.0
				worst_wet = maxf(worst_wet, wet)
		if n > 0 and (float(dry) / float(n) < LAND_ON_FRAC or worst_wet > LAND_WET_RUN):
			_add(out, "G_ROUTE_LAND", rid, "陆上 %.1f%%，最长连续下水 %.2f u" % [100.0 * dry / n, worst_wet], [], "", {"point": [pts[int(wet_indices[0])].x,pts[int(wet_indices[0])].y], "point_indices": wet_indices})
		# 离山（先按路的包围盒排除远的山）
		var gap := INF
		var peak_at := Vector2.ZERO
		for k: Dictionary in derived.get("kit", []):
			if String(k.get("asset", "")).begins_with("forest") or float(k.get("s", 0.0)) <= 0.0:
				continue
			var kr := float(k.s) * float(R_ASSET.get(String(k.asset), 1.0)) + PEAK_ROUTE_EXTRA
			var kc := Vector2(float(k.x), float(k.z))
			if not box.grow(kr).has_point(kc):
				continue
			for i in range(0, pts.size(), 2):
				var distance := pts[i].distance_to(kc) - kr
				if distance < gap: gap = distance; peak_at = pts[i]
		if gap < 0.0:
			_add(out, "G_PEAK", rid, "陆路压进山脚 %.2f u" % -gap, [], "", {"point":[peak_at.x,peak_at.y]})
	elif P != null and (P.get("routes") as Dictionary).has(rid):
		# 两个码头之间（Paths 推开过的航道）：离岸 ≥ 0.2；船缩到 0.6 倍时整个在水里（要 Paths：松手全检才查）
		var R: Dictionary = P.get("routes")[rid]
		var s := float(R.s0)
		var worst_clear := INF
		var worst_narrow := INF
		var sea_at := Vector2.ZERO
		while s <= float(R.s1):
			var q: Vector3 = P.call("point_at", rid, s)
			var wc := geo.water_clearance(q.x, q.z)
			if wc < worst_clear: sea_at = Vector2(q.x,q.z)
			worst_clear = minf(worst_clear, wc)
			if wc < SEA_NARROW_SKIP:
				var yaw := float(P.call("tangent_yaw", rid, s))
				worst_narrow = minf(worst_narrow, float(P.call("hull_clearance", q, yaw, HULL_LEN * SEA_NARROW_SCALE, HULL_BEAM * SEA_NARROW_SCALE)))
			s += 0.1
		if worst_clear < SEA_LAND_CLEAR or worst_narrow <= SEA_NARROW_CLEAR:
			_add(out, "G_ROUTE_SEA", rid, "航道离岸最少 %.3f（下限 0.2），最窄处小船离岸 %.3f（下限 %.2f）" % [worst_clear, worst_narrow, SEA_NARROW_CLEAR], [], "", {"point":[sea_at.x,sea_at.y]})
	# 城压路（从路这边看：没挪过的原城也要护住）
	for c: Dictionary in derived.get("cities", []):
		if String(c.id) == ends[0] or String(c.id) == ends[1]:
			continue
		var lim := float(c.get("foot", 3.4)) * 0.5 + CITY_ROUTE_EXTRA
		var cc := Vector2(float(c.x), float(c.z))
		if not box.grow(lim).has_point(cc):
			continue
		var d := _polyline_dist(cc, r.points)
		if d < lim:
			_add(out, "G_CITY_ON_ROUTE", rid, "路线离 %s 城心 %.2f u" % [String(c.id), d], [], "", {"point":[cc.x,cc.y],"related_city":str(c.id)})
			break
	# 路与路
	var cross_at: Dictionary = {}
	var cross := _route_cross(r, idx, cities, cross_at)
	if cross != "":
		_add(out, "G_ROUTE_CROSS", rid, cross, [], "", cross_at)
	# 停靠点
	var stop_msg := _stop_rule(r, derived, overlay, pts, cum)
	if stop_msg != "":
		_add(out, "G_STOP", rid, stop_msg)
	if P == null:
		return
	# 骆驼能站、船能停（要 Paths：松手全检才查）
	var R2: Dictionary = (P.get("routes") as Dictionary).get(rid, {})
	if not R2.is_empty():
		for k in 2:
			var cid: String = String(R2.a) if k == 0 else String(R2.b)
			var gt: Vector3 = ((P.get("gates") as Dictionary).get(cid, {}) as Dictionary).get(rid, Vector3.INF)
			if gt == Vector3.INF:
				continue
			var yaw := float(P.call("rest_yaw", cid, rid))
			if rtype == "LAND":
				if not bool(P.call("_camel_on_land", gt, yaw)):
					_add(out, "G_STAND", rid, "%s 城门处骆驼有脚踩在水里" % cid, [], "", {"point":[gt.x,gt.z],"endpoint_city":cid})
					break
			else:
				var fit := float(P.call("hull_fit", gt, yaw))
				if fit < GATE_FIT_MIN - 1e-6:
					_add(out, "G_STAND", rid, "%s 的码头船只能缩到 %.2f（下限 %.2f）" % [cid, fit, GATE_FIT_MIN], [], "G_STAND_SEA", {"point":[gt.x,gt.z],"endpoint_city":cid})
					break


## 同类型的路不相交（离共同端点城心 2.5 u 以内不算）；共享城心 4 u 以外，任意两条路最近距离 ≥ 1.0。
## 近距离：每条别的路只看离这一点最近的那一处，这一点或那一处离两条路共同的城心不到 4 u 就不算。
## 做法：每 CROSS_STRIDE 个点粗查一次（半径放宽到盖住前后半个窗口），粗查碰到某条别的路，才对这个窗口里的点逐点细查那一条路；
## 采样点离共同的城心近到整个窗口都在 4 u 以内时，那条路整个窗口都不用查。结果与逐点查相同。
static func _route_cross(r: Dictionary, idx: LayoutIndex, cities: Dictionary, location: Dictionary = {}) -> String:
	var rid := String(r.id)
	var me: int = idx.ord.get(rid, -1)
	if me < 0:
		return ""
	var g: RouteGeo = idx.geos[me]
	var pa := g.pts
	var n := pa.size()
	var nr := idx.geos.size()
	var ea: Array = idx.ends[me]
	var centres: Array[Vector2] = [Vector2.INF, Vector2.INF]
	for k in 2:
		var c: Dictionary = cities.get(String(ea[k]), {})
		if not c.is_empty():
			centres[k] = Vector2(float(c.x), float(c.z))
	# share[o]：第 0 位 = o 也连着这条路的 a 端城，第 1 位 = b 端城
	var share := PackedByteArray()
	share.resize(nr)
	for o in nr:
		if o == me:
			continue
		var eb: Array = idx.ends[o]
		for k in 2:
			if centres[k] != Vector2.INF and (ea[k] == eb[0] or ea[k] == eb[1]):
				share[o] |= 1 << k
	var half := float(CROSS_HALF) * g.max_seg + 1e-4
	# 粗查时整个窗口都可以不看的路：按采样点离 a、b 端城心近不近（两位）分四种，先备好
	var skips: Array[PackedByteArray] = []
	for mask in 4:
		var sk := PackedByteArray()
		sk.resize(nr)
		for o in nr:
			if o == me or (share[o] & mask) != 0:
				sk[o] = 1
		skips.append(sk)
	var samples := PackedInt32Array()
	for i in range(0, n, CROSS_STRIDE):
		samples.append(i)
	if n > 0 and samples[samples.size() - 1] != n - 1:
		samples.append(n - 1)
	for i in samples:
		var q := pa[i]
		var mask := 0
		for k in 2:
			if centres[k] != Vector2.INF and q.distance_to(centres[k]) < CROSS_SHARED - half:
				mask |= 1 << k
		var hits: Dictionary = idx.near(q, ROUTE_GAP + half, skips[mask])
		if hits.is_empty():
			continue
		for o in hits:
			var shared: Array[Vector2] = []
			for k in 2:
				if share[o] & (1 << k):
					shared.append(centres[k])
			for j in range(maxi(0, i - CROSS_HALF), mini(n, i + CROSS_HALF + 1)):
				var qj := pa[j]
				if _near_any(qj, shared, CROSS_SHARED):
					continue
				var hit: Array = idx.nearest_on(o, qj, ROUTE_GAP)
				if hit.is_empty() or _near_any(hit[1], shared, CROSS_SHARED):
					continue
				location.point = [qj.x,qj.y]
				return "离 %s 最近 %.2f u（下限 %.1f）" % [idx.rids[o], float(hit[0]), ROUTE_GAP]
	# 共享城附近（2.5–4 u）：同类型的路不许相交
	for o in nr:
		if share[o] == 0 or idx.types[o] != String(r.type):
			continue
		var shared: Array[Vector2] = []
		for k in 2:
			if share[o] & (1 << k):
				shared.append(centres[k])
		var ring_a := g.ring_points(shared, CROSS_END, CROSS_SHARED + 0.2)
		if ring_a.is_empty():
			continue
		var go: RouteGeo = idx.geos[o]
		var ring_b := go.ring_points(shared, CROSS_END, CROSS_SHARED + 0.2)
		var pb := go.pts
		for i in ring_a:
			if i < 1:
				continue
			for j in ring_b:
				if j < 1:
					continue
				var crossing: Variant = Geometry2D.segment_intersects_segment(pa[i - 1], pa[i], pb[j - 1], pb[j])
				if crossing != null:
					location.point = [crossing.x,crossing.y]
					return "在共同的城边上与 %s 相交" % idx.rids[o]
	return ""


## 停靠点：两个停靠点之间、停靠点到路线两端（沿路弧长）≥ 2.2 u；stop_t[0] ∈ [0.20, 0.45]、stop_t[1] ∈ [0.55, 0.80]、相差 ≥ 0.20
static func _stop_rule(r: Dictionary, derived: Dictionary, overlay: Dictionary, pts: PackedVector2Array, cum: PackedFloat32Array) -> String:
	var rid := String(r.id)
	var st := _stop_t_of(overlay, rid)
	if st.size() >= 2 and not CustomMapFreeRoutes.enabled(overlay):
		var t0 := float(st[0])
		var t1 := float(st[1])
		if t0 < STOP_T0.x or t0 > STOP_T0.y or t1 < STOP_T1.x or t1 > STOP_T1.y or t1 - t0 < STOP_T_GAP - 1e-9:
			return "stop_t = [%.3f, %.3f] 越界" % [t0, t1]
	if cum.is_empty():
		return ""
	var L := cum[cum.size() - 1]
	var ss: Array[float] = []
	for s: Dictionary in derived.get("stops", []):
		if String(s.id).begins_with(rid + "_"):
			ss.append(_project(pts, cum, Vector2(float(s.x), float(s.z))))
	ss.sort()
	var marks: Array[float] = [0.0]
	marks.append_array(ss)
	marks.append(L)
	for i in range(1, marks.size()):
		if marks[i] - marks[i - 1] < STOP_GAP:
			return "停靠点间距 %.2f u（下限 %.1f）" % [marks[i] - marks[i - 1], STOP_GAP]
	return ""


# ================================================================ 可达区（绿区）与自动画路（3.12.5「绿区怎么算」）
# 绿区和自动画路用同一张 0.25 u 网格、同一个代价、同一次搜索：从宿主城门（城心外 foot/2 那一圈）出发做 8 邻域 Dijkstra
# （整数代价：直走 10、斜走 14，即 0.025 u 一个单位；桶队列），路长上限 36 u（G_ROUTE_LEN）。能走的格子：
#   陆路：这一格和周围 8 格都在陆上；不压非森林的山（s × R_asset + 0.3）；
#   海路：离岸 ≥ 0.35，离岸不到 0.75（Paths 的航道宽度）的格子代价翻倍（3.12.5 写的是硬性 ≥ 0.75：窄海里就一条也画不出来）；
#         起点是宿主城边 3.2 u（BERTH_MAX）以内、离岸 ≥ 0.75 的航道格，路线从城边直线伸过去（码头就在这一段上找），
#         终点同样是新城边 3.2 u 以内、离岸 ≥ 0.75 的航道格；
#   两种都要：离别的城心 ≥ foot/2 + 0.6；离别的路 ≥ 1.0（宿主自己的路：离宿主城心 4 u 以外才管，2.5–4 u 只是不许穿过去）；
#   在棋盘内缩 1 u 的范围里。
# 这一宿主已经挂着的那座新城（R6：一座原城最多挂一座）和它的路不算障碍：「帮我重画」、拖新城时都要能从原处重画。
const GRID := 0.25
const COST_ORTHO := 10
const COST_DIAG := 14
const COST_UNIT := 0.025            # 一个代价单位 = 0.025 u
const REACH_MAX := 36.0
const LANE_CLEAR := 0.75
const SEA_MIN_CLEAR := 0.35         # 窄海峡里航道离岸最少这么多（离岸不到 0.75 的格子代价翻倍：能走开阔水面就走开阔水面）
const BERTH_MAX := 3.2
const PLACE_FOOT := 3.4             # 算绿区时新城的默认占地（目录里原型的 foot，工坊可以换）
const DP_TOLERANCES := [0.4, 0.2, 0.1]
## 可达区里的障碍比规则多让一格（0.25 u）：格子路径平滑、简化成控制点、再过样条之后会往外鼓一点，不让它鼓进规则的边线
const REACH_MARGIN := 0.25
const BERTH_CLEAR := 0.25            # Paths._stand_s 找泊位的条件：整条船（1.8 × 0.99）离岸 > LAND_CLEAR + 0.05
## 算绿区时新城边上的泊位格：离岸 ≥ 1.3（船身外接圆半径 1.03 + 泊位要的 0.25），不管船头朝哪都停得下；
## 真正画路时按船头朝向逐格查（更宽），所以绿区里的格子画路时一定找得到泊位
const ZONE_OPEN_CLEAR := 1.3

static var _mask_cache := {}         # 布局键 -> {prox, line, mountain}
static var _geo_mask: PackedByteArray   # 与布局无关的城市规则（陆地、坡度、城心高、山峰），0.25 网格；第一次用时算
static var _geo_mask_foot := ""


## 0.25 u 网格上从宿主城门出发的可达区：{dist, parent, w, h, cell, host, type, key, ok}；按 (布局键, 宿主, 类型) 缓存
static func reach_field(derived: Dictionary, host_id: String, route_type: String, geo: CustomMapGeo) -> Dictionary:
	if geo == null:
		geo = CustomMapGeo.shared()
	geo = _layout_geo(derived, geo)
	var lkey := layout_key(derived)
	var key := "%s|%s|%s|%s" % [lkey, _geo_key(geo), host_id, route_type]
	if _reach_cache.has(key):
		return _reach_cache[key]
	var t0 := Time.get_ticks_msec()
	var cities := _by_id(derived.get("cities", []))
	if not cities.has(host_id):
		return {"ok": false, "reason": "没有这座城：%s" % host_id}
	var cg := geo.clearance_grid()
	var W: int = cg.w
	var H: int = cg.h
	var clear: PackedFloat32Array = cg.clear
	var masks := _layout_masks(derived, lkey)
	var prox: PackedInt32Array = masks.prox
	var line: PackedInt32Array = masks.line
	var mountain: PackedByteArray = masks.mountain
	var bits: Dictionary = masks.bits
	var host: Dictionary = cities[host_id]
	var hc := Vector2(float(host.x), float(host.z))
	var hfoot := float(host.get("foot", 3.4))
	# 宿主自己的路、这一宿主挂着的新城和它的路
	var host_bits := 0
	var skip_bits := 0
	var skip_cities := {host_id: true}
	for r: Dictionary in derived.get("routes", []):
		var e := _ends_of(derived, r)
		if e[0] != host_id and e[1] != host_id:
			continue
		var other := e[1] if e[0] == host_id else e[0]
		var b := int(bits.get(String(r.id), 0))
		if other.begins_with("x_"):
			skip_bits |= b
			skip_cities[other] = true
		else:
			host_bits |= b
	# 被别的城占着的格子
	var blocked := PackedByteArray()
	blocked.resize(W * H)
	for c: Dictionary in derived.get("cities", []):
		if skip_cities.has(String(c.id)):
			continue
		_stamp_disc(blocked, W, H, Vector2(float(c.x), float(c.z)), float(c.get("foot", 3.4)) * 0.5 + CITY_ROUTE_EXTRA + REACH_MARGIN)
	var sea := route_type == "SEA"
	var free_r := hfoot * 0.5 + BERTH_MAX
	var inset := int(ceil(ROUTE_INSET / GRID))
	var n := W * H
	var passable := PackedByteArray()
	passable.resize(n)
	for j in range(inset, H - inset):
		for i in range(inset, W - inset):
			var k := j * W + i
			if blocked[k] != 0:
				continue
			var p := Vector2((i + 0.5) * GRID, (j + 0.5) * GRID)
			var dh := p.distance_to(hc)
			var pr := prox[k] & ~skip_bits
			var ln := line[k] & ~skip_bits
			if (pr & ~host_bits) != 0:
				continue
			if dh >= CROSS_SHARED and (pr & host_bits) != 0:
				continue
			if dh >= CROSS_END and dh < CROSS_SHARED and (ln & host_bits) != 0:
				continue
			if sea:
				if clear[k] < SEA_MIN_CLEAR:
					continue
			else:
				if mountain[k] != 0 or not _land_block(clear, W, H, i, j):
					continue
			passable[k] = 1
	# 桶队列 Dijkstra（Dial）
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(0x3fffffff)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	# 海路：每一格记下它的路是从离宿主城边多远的泊位起步的（泊位要在第一个硬币之前找到，路太短时起步不能太远）
	var seed_off := PackedFloat32Array()
	if sea:
		seed_off.resize(n)
	var max_cost := int(REACH_MAX / COST_UNIT)
	var buckets: Array = []
	buckets.resize(max_cost + COST_DIAG + 1)
	var r0 := hfoot * 0.5
	if sea:
		# 海路的起点：城边 3.2 u（码头范围）以内、船能整个浮起来（离岸 ≥ 0.75）的航道格；起步代价 = 从城边直着走过去的长度
		# （路线就从城边直线伸到那里，Paths 的码头搜索沿着这一段找泊位）
		var span := int(ceil(free_r / GRID))
		var ci := int(hc.x / GRID)
		var cj := int(hc.y / GRID)
		for j in range(maxi(0, cj - span), mini(H, cj + span + 1)):
			for i in range(maxi(0, ci - span), mini(W, ci + span + 1)):
				var k := j * W + i
				if passable[k] == 0 or clear[k] < LANE_CLEAR:
					continue
				var q := Vector2((i + 0.5) * GRID, (j + 0.5) * GRID)
				var d := q.distance_to(hc) - r0
				if d < 0.0 or d > BERTH_MAX - 0.3:
					continue
				# 这里要真能停船：船头朝外（从城心往这一格），整条船离岸够（与 Paths 找泊位同一个判断）
				var dir := (q - hc).normalized()
				if float(geo.sampler().call("hull_clearance", Vector3(q.x, 0.0, q.y), atan2(-dir.y, dir.x), HULL_LEN, HULL_BEAM)) <= BERTH_CLEAR:
					continue
				var c0 := int(round(d / COST_UNIT))
				if c0 < dist[k]:
					dist[k] = c0
					seed_off[k] = d
					if buckets[c0] == null:
						buckets[c0] = PackedInt32Array()
					buckets[c0].append(k)
	else:
		for j in range(maxi(0, int((hc.y - r0 - 1.0) / GRID)), mini(H, int((hc.y + r0 + 1.0) / GRID) + 1)):
			for i in range(maxi(0, int((hc.x - r0 - 1.0) / GRID)), mini(W, int((hc.x + r0 + 1.0) / GRID) + 1)):
				var k := j * W + i
				var d := Vector2((i + 0.5) * GRID, (j + 0.5) * GRID).distance_to(hc)
				if absf(d - r0) <= GRID * 0.75 and passable[k] != 0:
					dist[k] = 0
					if buckets[0] == null:
						buckets[0] = PackedInt32Array()
					buckets[0].append(k)
	var offs := [[1, 0, COST_ORTHO], [-1, 0, COST_ORTHO], [0, 1, COST_ORTHO], [0, -1, COST_ORTHO],
		[1, 1, COST_DIAG], [1, -1, COST_DIAG], [-1, 1, COST_DIAG], [-1, -1, COST_DIAG]]
	var reached := 0
	for c in max_cost + 1:
		var bucket = buckets[c]
		if bucket == null:
			continue
		var q: PackedInt32Array = bucket
		for k in q:
			if dist[k] != c:
				continue
			reached += 1
			var i := k % W
			var j := k / W
			for o: Array in offs:
				var ii: int = i + int(o[0])
				var jj: int = j + int(o[1])
				if ii < 0 or jj < 0 or ii >= W or jj >= H:
					continue
				var kk := jj * W + ii
				if passable[kk] == 0:
					continue
				var nc: int = c + int(o[2])
				if sea and clear[kk] < LANE_CLEAR:
					nc += int(o[2])
				if nc < dist[kk] and nc <= max_cost:
					dist[kk] = nc
					parent[kk] = k
					if sea:
						seed_off[kk] = seed_off[k]
					if buckets[nc] == null:
						buckets[nc] = PackedInt32Array()
					buckets[nc].append(kk)
		buckets[c] = null
	var fdist := PackedFloat32Array()
	fdist.resize(n)
	for k in n:
		fdist[k] = INF if dist[k] >= 0x3fffffff else float(dist[k]) * COST_UNIT
	var out := {"ok": true, "dist": fdist, "parent": parent, "w": W, "h": H, "cell": GRID, "host": host_id, "type": route_type,
		"key": key, "reached": reached, "ms": Time.get_ticks_msec() - t0, "seed_off": seed_off}
	if _reach_cache.size() > 64:
		_reach_cache.clear()
	_reach_cache[key] = out
	return out


## 从可达区里取一条到 to_xz 的路：{ok, handles, stop_t, reason}
## 陆路：一直走到新城城心那一格；海路：走到新城边 3.2 u（码头范围）以内最近的航道格，再直线上岸。
## 取回的格子路径：Chaikin 平滑 3 次 → Douglas–Peucker 简化（容差 0.4 u，不过就 0.2、0.1 再试），每一版都按
## 这条路的全部几何规则查一遍（在临时布局上），过了就用。停靠点放在 1/3、2/3。
static func route_from_field(field: Dictionary, to_xz: Vector2, derived: Dictionary, geo: CustomMapGeo, foot_override := -1.0, check_city := false) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	if geo == null:
		geo = CustomMapGeo.shared()
	geo = _layout_geo(derived, geo)
	if not bool(field.get("ok", false)):
		return {"ok": false, "handles": [], "stop_t": [], "reason": String(field.get("reason", "没有可达区"))}
	var W: int = field.w
	var H: int = field.h
	var dist: PackedFloat32Array = field.dist
	var parent: PackedInt32Array = field.parent
	var host_id := String(field.host)
	var rtype := String(field.type)
	var cities := _by_id(derived.get("cities", []))
	var host: Dictionary = cities[host_id]
	# 目的地：这一宿主已经挂着的新城（重画）或一座临时的新城（放城）
	var target_id := ""
	for c: Dictionary in derived.get("cities", []):
		var cid := String(c.id)
		if cid.begins_with("x_"):
			for r: Dictionary in derived.get("routes", []):
				var e := _ends_of(derived, r)
				if (e[0] == host_id and e[1] == cid) or (e[1] == host_id and e[0] == cid):
					target_id = cid
	var foot := float(cities[target_id].get("foot", PLACE_FOOT)) if target_id != "" else PLACE_FOOT
	if foot_override > 0.0:
		foot = foot_override
	var goal := -1
	var gi := clampi(int(to_xz.x / GRID), 0, W - 1)
	var gj := clampi(int(to_xz.y / GRID), 0, H - 1)
	if rtype == "LAND":
		if dist[gj * W + gi] < INF:
			goal = gj * W + gi
	else:
		# 海路：新城边 3.2 u 以内、船能整个浮起来（离岸 ≥ 0.75）的航道格里，取「路长 + 上岸那一段」最短的
		var clear: PackedFloat32Array = geo.clearance_grid().clear
		var seed_off: PackedFloat32Array = field.get("seed_off", PackedFloat32Array())
		var best := INF
		var rr := foot * 0.5 + BERTH_MAX - 0.3
		var span := int(ceil(rr / GRID))
		for j in range(maxi(0, gj - span), mini(H, gj + span + 1)):
			for i in range(maxi(0, gi - span), mini(W, gi + span + 1)):
				var k := j * W + i
				if dist[k] == INF or clear[k] < LANE_CLEAR:
					continue
				var wq := Vector2((i + 0.5) * GRID, (j + 0.5) * GRID)
				var dd := wq.distance_to(to_xz)
				if dd > rr or dist[k] + dd >= best:
					continue
				if not _berths_fit(dist[k] + dd - foot * 0.5, float(seed_off[k]), dd - foot * 0.5):
					continue
				var dir := (to_xz - wq).normalized()
				if float(geo.sampler().call("hull_clearance", Vector3(wq.x, 0.0, wq.y), atan2(-dir.y, dir.x), HULL_LEN, HULL_BEAM)) <= BERTH_CLEAR:
					continue
				best = dist[k] + dd
				goal = k
	if goal < 0:
		return {"ok": false, "handles": [], "stop_t": [], "reason": "从%s画不出合格的路到这里" % String(host.get("name", host_id)), "ms": Time.get_ticks_msec() - t0}
	var cellpath := PackedVector2Array()
	var k := goal
	while k >= 0:
		cellpath.append(Vector2((k % W + 0.5) * GRID, (k / W + 0.5) * GRID))
		k = parent[k]
	cellpath.reverse()
	cellpath.append(to_xz)
	var smooth := _chaikin(cellpath, 3)
	var hc := Vector2(float(host.x), float(host.z))
	var last_reason := ""
	# 先平滑再简化（容差 0.4、0.2、0.1）；都不过时，直接简化格子路径（0.1、0.05）；还不过，在简化后的每一段上每隔 3 u、1.5 u
	# 补控制点（样条在长直段的拐角前后会往外鼓：格子路径贴着山脚走时，鼓出去那一点就压进山脚，补了点它就贴着直段走）。
	# 控制点不超过 12 个
	var tries: Array = []
	for tol in DP_TOLERANCES:
		tries.append([smooth, float(tol), 0.0])
	for tol in [0.1, 0.05]:
		tries.append([cellpath, float(tol), 0.0])
	for leg in [3.0, 1.5]:
		tries.append([smooth, 0.1, float(leg)])
	for tr: Array in tries:
		var tol: float = tr[1]
		var simp := _douglas_peucker(tr[0], tol)
		if float(tr[2]) > 0.0:
			simp = _densify(simp, float(tr[2]))
		var handles: Array = []
		for p in simp:
			# 控制点不放在两座城的占地里（端点永远跟着城走）
			if p.distance_to(hc) <= float(host.get("foot", 3.4)) * 0.5 + 0.3 or p.distance_to(to_xz) <= foot * 0.5 + 0.3:
				continue
			handles.append([snappedf(p.x, 0.001), snappedf(p.y, 0.001)])
		if handles.size() > 12:
			continue
		var stop_t := [0.333, 0.667]
		var errs := _probe_route(derived, host_id, target_id, to_xz, foot, rtype, handles, stop_t, geo, check_city)
		if errs.is_empty():
			return {"ok": true, "handles": handles, "stop_t": stop_t, "reason": "", "tolerance": tol, "ms": Time.get_ticks_msec() - t0}
		last_reason = "%s（%s）" % [String(errs[0].kid), String(errs[0].tech)]
	return {"ok": false, "handles": [], "stop_t": [], "reason": last_reason, "ms": Time.get_ticks_msec() - t0}


## 「帮我重画」：{ok, handles, stop_t, reason}；内部 = reach_field + route_from_field
static func auto_route(derived: Dictionary, from_city: String, to_xz: Vector2, route_type: String, geo: CustomMapGeo) -> Dictionary:
	return route_from_field(reach_field(derived, from_city, route_type, geo), to_xz, derived, geo)


## 绿区（3.12.5「绿区怎么算」）= 各宿主可达区之并 ∩ 3.11 的城市规则 ∩ 对侧放得下搭档。返回 L8 图（0.25 u 一格，255 = 能放）。
##   hosts       合格的宿主：工坊用 WP1 的 CustomMapRules.legal_hosts 按 R6、R9 筛好传进来（拖新城时再加上它现在的宿主）；
##   partner_ok  Callable(host: String, route_type: String) -> bool：这座宿主挂上新城以后，对侧放不放得下搭档
##               （工坊用 WP1 的 CustomMapRules.pick_auto_partner 判断）；返回 false 的宿主周围一格绿都不出。
## hosts 传 null（DESIGN 5.2 原来的三参数调法）时只看几何：全部几何上能当宿主的原城（geometric_hosts），不看 R6、R9、搭档。
## 这只给目录构建工具这类「先按几何找位置、之后逐个验」的工具用；工坊必须传 hosts 和 partner_ok，不然会把
## 放了也导入不了的地方涂成绿色（孩子点在绿区、「导入地图」却变灰，3.12.5 要杜绝的正是这个）。
static func feasible_zone(derived: Dictionary, route_type: String, geo: CustomMapGeo, hosts: Variant = null, partner_ok := Callable()) -> Image:
	var list: Array = geometric_hosts(derived, route_type) if hosts == null else Array(hosts)
	var keep: Array = []
	for h in list:
		if partner_ok.is_valid() and not bool(partner_ok.call(String(h), route_type)):
			continue
		keep.append(String(h))
	return feasible_zone_for_hosts(derived, route_type, keep, geo)


## 几何上能当宿主的原城（R6 的几何部分）
static func geometric_hosts(derived: Dictionary, route_type: String) -> Array[String]:
	var deg := {}
	var types := {}
	var hosting := {}
	for r: Dictionary in derived.get("routes", []):
		var e := _ends_of(derived, r)
		for c in e:
			deg[c] = int(deg.get(c, 0)) + 1
			if not types.has(c):
				types[c] = {}
			types[c][String(r.type)] = true
		if e[1].begins_with("x_"):
			hosting[e[0]] = true
		if e[0].begins_with("x_"):
			hosting[e[1]] = true
	var out: Array[String] = []
	for c: Dictionary in derived.get("cities", []):
		var id := String(c.id)
		if id.begins_with("x_") or hosting.has(id) or int(deg.get(id, 0)) > 3:
			continue
		if (types.get(id, {}) as Dictionary).has(route_type):
			out.append(id)
	return out


static func feasible_zone_for_hosts(derived: Dictionary, route_type: String, hosts: Array, geo: CustomMapGeo, foot := PLACE_FOOT) -> Image:
	if geo == null:
		geo = CustomMapGeo.shared()
	geo = _layout_geo(derived, geo)
	var cg := geo.clearance_grid()
	var W: int = cg.w
	var H: int = cg.h
	var reach := PackedByteArray()
	reach.resize(W * H)
	for h in hosts:
		var f := reach_field(derived, String(h), route_type, geo)
		if not bool(f.get("ok", false)):
			continue
		var dist: PackedFloat32Array = f.dist
		var seed_off: PackedFloat32Array = f.get("seed_off", PackedFloat32Array())
		if route_type == "LAND":
			# 路长 = 到城心的距离 − foot/2，要在 [7, 36] 里（两头各留一点余量）
			var lo := LEN_MIN + foot * 0.5 + 0.5
			for k in W * H:
				if dist[k] >= lo and dist[k] <= REACH_MAX - 0.5:
					reach[k] = 1
		else:
			# 海路：新城在陆上；城边 3.2 u（码头范围）以内要有船怎么停都浮得起来的航道格 W（离岸 ≥ 1.3），
			# 路长 ≈ dist[W] + |C − W| − foot/2 在 [7, 36] 里。只在「城市规则过、离开阔水面不远」的陆格上找
			var gm0 := static_city_mask(geo, foot, derived)
			var clear: PackedFloat32Array = cg.clear
			var rr := foot * 0.5 + BERTH_MAX - 0.3
			var span := int(ceil(rr / GRID))
			var open := PackedByteArray()
			open.resize(W * H)
			for k in W * H:
				if dist[k] < INF and clear[k] >= ZONE_OPEN_CLEAR:
					open[k] = 1
			var near := _dilate_square(open, W, H, span)
			for k in W * H:
				if gm0[k] == 0 or near[k] == 0:
					continue
				var i := k % W
				var j := k / W
				var c := Vector2((i + 0.5) * GRID, (j + 0.5) * GRID)
				var best := INF
				for jj in range(maxi(0, j - span), mini(H, j + span + 1), 2):
					for ii in range(maxi(0, i - span), mini(W, i + span + 1), 2):
						var kk := jj * W + ii
						if open[kk] == 0:
							continue
						var leg := Vector2((ii + 0.5) * GRID, (jj + 0.5) * GRID).distance_to(c)
						if leg <= rr and dist[kk] + leg < best and _berths_fit(dist[kk] + leg - foot * 0.5, float(seed_off[kk]), leg - foot * 0.5):
							best = dist[kk] + leg
				var L := best - foot * 0.5
				if L >= LEN_MIN + 1.0 and L <= LEN_MAX - 0.5:
					reach[k] = 1
	var gm := static_city_mask(geo, foot, derived)
	var cities: Array = derived.get("cities", [])
	var ridx := _index(derived)
	var no_skip := PackedByteArray()
	no_skip.resize(ridx.geos.size())
	var zone := PackedByteArray()
	zone.resize(W * H)
	for k in W * H:
		if reach[k] == 0 or gm[k] == 0:
			continue
		var p := Vector2((k % W + 0.5) * GRID, (k / W + 0.5) * GRID)
		var ok := true
		for c: Dictionary in cities:
			if Vector2(float(c.x), float(c.z)).distance_to(p) < CITY_GAP + 0.15:
				ok = false
				break
		if ok and not ridx.near(p, foot * 0.5 + CITY_ROUTE_EXTRA + 0.15, no_skip).is_empty():
			ok = false
		if ok:
			zone[k] = 255
	for h in hosts:
		var key := "%s|%s|%s|%s|%s" % [layout_key(derived), _geo_key(geo), String(h), route_type, foot]
		for spot: Dictionary in (_placement_cache.get(key, {}) as Dictionary).get("spots", []):
			var i := clampi(int(float(spot.x) / GRID), 0, W - 1)
			var j := clampi(int(float(spot.z) / GRID), 0, H - 1)
			zone[j * W + i] = 255
	return Image.create_from_data(W, H, false, Image.FORMAT_L8, zone)


## 两头的泊位都要在各自第一个硬币之前（Paths._stand_s：离城边不超过 min(3.2, 硬币 − 0.9)；硬币在路长的 1/3、2/3），再留 0.3 余量
static func _berths_fit(route_len: float, host_leg: float, city_leg: float) -> bool:
	var room := minf(BERTH_MAX, route_len / 3.0 - 0.9) - 0.3
	return host_leg <= room and city_leg <= room


static func _dilate_square(src: PackedByteArray, W: int, H: int, r: int) -> PackedByteArray:
	var tmp := PackedByteArray()
	tmp.resize(W * H)
	for j in H:
		var run := 0
		for i in range(0, mini(r, W - 1) + 1):
			run += src[j * W + i]
		for i in W:
			if run > 0:
				tmp[j * W + i] = 1
			var add := i + r + 1
			var sub := i - r
			if add < W:
				run += src[j * W + add]
			if sub >= 0:
				run -= src[j * W + sub]
	var out := PackedByteArray()
	out.resize(W * H)
	for i in W:
		var run := 0
		for j in range(0, mini(r, H - 1) + 1):
			run += tmp[j * W + i]
		for j in H:
			if run > 0:
				out[j * W + i] = 1
			var add := j + r + 1
			var sub := j - r
			if add < H:
				run += tmp[add * W + i]
			if sub >= 0:
				run -= tmp[sub * W + i]
	return out


## 与布局无关的城市规则（G_BOUNDS、G_CITY_LAND、G_SLOPE、城心高、G_PEAK），0.25 u 网格；全进程缓存（按 foot）。
## 在 0.5 u 的粗格心上按 check 的同一套判断算（抽样点少一些、门槛各收紧一点），细格要四个相邻粗格都过才算过（保守）。
## 工坊在启动的 L叔 等待卡期间调一次预热（约 0.5 s）。
static func static_city_mask(geo: CustomMapGeo, foot := PLACE_FOOT, derived: Dictionary = {}) -> PackedByteArray:
	geo = _layout_geo(derived, geo)
	var ck := str(foot) + "|" + str(_geo_key(geo)) + "|" + str(derived.get("kit", []).hash())
	if _geo_mask_foot == ck and not _geo_mask.is_empty():
		return _geo_mask
	if geo == null:
		geo = CustomMapGeo.shared()
	var cg := geo.clearance_grid()
	var W: int = cg.w
	var H: int = cg.h
	var clear: PackedFloat32Array = cg.clear
	var CW := W / 2 + 1
	var CH := H / 2 + 1
	var coarse := PackedByteArray()
	coarse.resize(CW * CH)
	var base := _base() if derived.is_empty() else derived
	var obst: Array = []          # [中心, 半径]
	for kk: Dictionary in base.get("kit", []):
		if not String(kk.get("asset", "")).begins_with("forest") and float(kk.get("s", 0.0)) > 0.0:
			obst.append([Vector2(float(kk.x), float(kk.z)), float(kk.s) * float(R_ASSET.get(String(kk.asset), 1.0))])
	var buckets := {}
	for o: Array in obst:
		var key := Vector2i(int(o[0].x / 8.0), int(o[0].y / 8.0))
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(o)
	var rx := CustomMapGeo.FOOT_RX * foot
	var rz := CustomMapGeo.FOOT_RZ * foot
	var rs := CustomMapGeo.SLOPE_RADIUS * foot
	for cj in CH:
		for ci in CW:
			var x := (ci + 0.5) * 0.5
			var z := (cj + 0.5) * 0.5
			if x < BOARD_MIN.x + 0.15 or x > BOARD_MAX.x - 0.15 or z < BOARD_MIN.y + 0.15 or z > BOARD_MAX.y - 0.15:
				continue
			if clear[clampi(int(z / GRID), 0, H - 1) * W + clampi(int(x / GRID), 0, W - 1)] >= 0.0:
				continue
			var land := 0
			var tot := 0
			for v in [-1.0, -0.5, 0.0, 0.5, 1.0]:
				for u in [-1.0, -0.5, 0.0, 0.5, 1.0]:
					if u * u + v * v > 1.0:
						continue
					tot += 1
					if geo.is_land(x + u * rx, z + v * rz):
						land += 1
			if float(land) / float(tot) < LAND_FRAC + 0.03:
				continue
			var hc := geo.height(x, z)
			if hc < CENTRE_MIN + 0.03:
				continue
			var lo := hc
			var hi := hc
			for a in 12:
				var ang := TAU * a / 12.0
				for rr in [rs * 0.5, rs]:
					var h := geo.height(x + cos(ang) * rr, z + sin(ang) * rr)
					lo = minf(lo, h)
					hi = maxf(hi, h)
			if hi - lo > SLOPE_MAX - 0.04:
				continue
			var hit := false
			var bk := Vector2i(int(x / 8.0), int(z / 8.0))
			for dy in [-1, 0, 1]:
				for dx in [-1, 0, 1]:
					for o: Array in buckets.get(bk + Vector2i(dx, dy), []):
						if _ellipse_gap(Vector2(x, z), foot, o[0], float(o[1])) < 0.15:
							hit = true
			if hit:
				continue
			coarse[cj * CW + ci] = 1
	var out := PackedByteArray()
	out.resize(W * H)
	for j in H:
		for i in W:
			# 细格心 (i+0.5)*0.25 落在粗格心之间：取两边的粗格（四个）都过
			var fx := ((i + 0.5) * GRID) / 0.5 - 0.5
			var fz := ((j + 0.5) * GRID) / 0.5 - 0.5
			var c0 := clampi(int(floor(fx)), 0, CW - 1)
			var r0 := clampi(int(floor(fz)), 0, CH - 1)
			var c1 := mini(c0 + 1, CW - 1)
			var r1 := mini(r0 + 1, CH - 1)
			if coarse[r0 * CW + c0] != 0 and coarse[r0 * CW + c1] != 0 and coarse[r1 * CW + c0] != 0 and coarse[r1 * CW + c1] != 0:
				out[j * W + i] = 1
	_geo_mask = out
	_geo_mask_foot = ck
	return out


## 渐进式放置搜索。begin 只准备状态；step 的 reach / 单次全检是不可拆的工作，
## budget_ms 是下一项工作的启动预算，不伪称硬实时。UI 每帧最多调用一次，随时可丢弃状态取消。
## 候选只来自当前可达分量；done + 空 spots 表示本次离散搜索无解，不表示连续空间不可能。
static var _placement_cache := {}

static func placement_search_begin(derived: Dictionary, host_id: String, route_type: String,
		geo: CustomMapGeo, foot := PLACE_FOOT) -> Dictionary:
	geo = _layout_geo(derived, geo)
	var key := "%s|%s|%s|%s|%s" % [layout_key(derived), _geo_key(geo), host_id, route_type, foot]
	if _placement_cache.has(key):
		return _placement_cache[key]
	var hosts := _by_id(derived.get("cities", []))
	var state := {"key": key, "derived": derived, "host": host_id, "type": route_type, "foot": foot,
		"phase": "field", "scanned": 0, "route_checks": 0, "cursor": 0, "candidates": [], "spots": [],
		"done": not hosts.has(host_id), "last_step_ms": 0.0, "max_step_ms": 0.0, "geo_key": _geo_key(geo)}
	if _placement_cache.size() >= 32:
		_placement_cache.clear()
	_placement_cache[key] = state
	return state

static func placement_search_step(state: Dictionary, geo: CustomMapGeo, budget_ms := 8.0,
		max_route_checks := 1) -> Dictionary:
	if bool(state.get("done", true)):
		return state
	var started := Time.get_ticks_usec()
	var derived: Dictionary = state.derived
	geo = _layout_geo(derived, geo)
	if int(state.geo_key) != _geo_key(geo):
		state.done = true
		state["reason"] = "地形已变化，请重新搜索"
		return state
	if String(state.phase) == "field":
		var field := reach_field(derived, String(state.host), String(state.type), geo)
		state["field"] = field
		if not bool(field.get("ok", false)) or int(field.get("reached", 0)) == 0:
			state.done = true
		else:
			state.phase = "scan"
			state["index"] = _index(derived)
			var near := PackedByteArray()
			if String(state.type) == "SEA":
				var reached := PackedByteArray()
				var dist: PackedFloat32Array = field.dist
				reached.resize(dist.size())
				for k in dist.size():
					if dist[k] < INF:
						reached[k] = 1
				near = _dilate_square(reached, int(field.w), int(field.h), int(ceil((float(state.foot) * 0.5 + BERTH_MAX) / GRID)))
			state["near"] = near
		_record_search_step(state, started)
		return state
	var field: Dictionary = state.field
	var W: int = field.w
	var dist: PackedFloat32Array = field.dist
	var host: Dictionary = _by_id(derived.cities)[String(state.host)]
	var hc := Vector2(float(host.x), float(host.z))
	if String(state.phase) == "scan":
		var near: PackedByteArray = state.near
		var no_skip := PackedByteArray()
		var idx: LayoutIndex = state.index
		no_skip.resize(idx.geos.size())
		var foot := float(state.foot)
		while int(state.scanned) < dist.size():
			var k := int(state.scanned)
			state.scanned = k + 1
			# 不使用保守静态掩码，先做不会排除真解的廉价条件，再调用同一城市规则。
			var p := Vector2((k % W + 0.5) * GRID, (k / W + 0.5) * GRID)
			var eligible := dist[k] < INF if String(state.type) == "LAND" else near[k] != 0
			if eligible and p.x >= BOARD_MIN.x and p.x <= BOARD_MAX.x and p.y >= BOARD_MIN.y and p.y <= BOARD_MAX.y and geo.height(p.x, p.y) >= CENTRE_MIN:
				for c: Dictionary in derived.cities:
					if p.distance_to(Vector2(float(c.x), float(c.z))) < CITY_GAP:
						eligible = false
						break
				if eligible and not idx.near(p, foot * 0.5 + CITY_ROUTE_EXTRA, no_skip).is_empty():
					eligible = false
				if eligible:
					var errors: Array[Dictionary] = []
					_city_rules({"id": "x_placement_probe", "x": p.x, "z": p.y, "foot": foot}, derived, idx, null, geo, {}, errors)
					if errors.is_empty():
						(state.candidates as Array).append([absf(p.distance_to(hc) - 11.0), p])
			if (k & 31) == 0 and float(Time.get_ticks_usec() - started) / 1000.0 >= budget_ms:
				break
		if int(state.scanned) >= dist.size():
			(state.candidates as Array).sort_custom(func(a, b): return float(a[0]) < float(b[0]) or (float(a[0]) == float(b[0]) and (a[1] as Vector2) < (b[1] as Vector2)))
			state.phase = "routes"
		_record_search_step(state, started)
		return state
	var checks := 0
	while int(state.cursor) < (state.candidates as Array).size() and checks < maxi(1, max_route_checks):
		var p: Vector2 = state.candidates[int(state.cursor)][1]
		state.cursor = int(state.cursor) + 1
		# 返回分散点位，而非一个只有几像素大的格子簇。
		var far := true
		for spot: Dictionary in state.spots:
			if p.distance_to(Vector2(float(spot.x), float(spot.z))) < 1.0:
				far = false
		if not far:
			continue
		checks += 1
		state.route_checks = int(state.route_checks) + 1
		var ar := route_from_field(field, p, derived, geo, float(state.foot), true)
		if bool(ar.get("ok", false)):
			(state.spots as Array).append({"x": p.x, "z": p.y, "handles": ar.handles, "stop_t": ar.stop_t, "host": state.host, "route_type": state.type})
		if float(Time.get_ticks_usec() - started) / 1000.0 >= budget_ms:
			break
	state.done = int(state.cursor) >= (state.candidates as Array).size() or (state.spots as Array).size() >= 12
	_record_search_step(state, started)
	return state

static func _record_search_step(state: Dictionary, started: int) -> void:
	state.last_step_ms = float(Time.get_ticks_usec() - started) / 1000.0
	state.max_step_ms = maxf(float(state.get("max_step_ms", 0.0)), float(state.last_step_ms))

## 挪城的点位也用实际 overlay derive + 完整 Validator 验收；原城半径以老家为准，新城以当前位置为搜索中心。
## base_content 是 CustomMapBase.load_base()，base_layout 是未改动的 3D 布局。
static func move_search_begin(base_content: Dictionary, base_layout: Dictionary, overlay: Dictionary, cid: String,
		catalogue: Dictionary, geo: CustomMapGeo) -> Dictionary:
	geo = _layout_geo({"landscape": overlay.get("landscape", {})}, geo)
	var current := CustomBoardLayout.derive(base_layout, overlay, geo, catalogue)
	var cities := _by_id(current.get("cities", []))
	var homes := _by_id(base_layout.get("cities", []))
	var state := {"base_content": base_content, "base_layout": base_layout, "overlay": overlay.duplicate(true), "cid": cid,
		"catalogue": catalogue, "candidates": [], "cursor": 0, "spots": [], "done": not cities.has(cid),
		"last_step_ms": 0.0, "max_step_ms": 0.0, "route_checks": 0}
	if state.done:
		return state
	var city: Dictionary = cities[cid]
	state["rotation"] = float(city.get("rotation", 0.0))
	var from := Vector2(float(city.x), float(city.z))
	var home := Vector2(float(homes[cid].x), float(homes[cid].z)) if homes.has(cid) else from
	for ring in range(1, 13):
		var radius := float(ring) * 0.5
		for i in 24:
			var p := from + Vector2.from_angle(float(i) * TAU / 24.0) * radius
			if p.distance_to(home) <= R_MOVE:
				(state.candidates as Array).append(Vector2(snappedf(p.x, 0.001), snappedf(p.y, 0.001)))
	return state

static func move_search_step(state: Dictionary, geo: CustomMapGeo, budget_ms := 8.0, max_checks := 1) -> Dictionary:
	if bool(state.get("done", true)):
		return state
	var started := Time.get_ticks_usec()
	var checks := 0
	while int(state.cursor) < (state.candidates as Array).size() and checks < maxi(1, max_checks):
		var p: Vector2 = state.candidates[int(state.cursor)]
		state.cursor = int(state.cursor) + 1
		var far := true
		for spot: Dictionary in state.spots:
			if p.distance_to(Vector2(float(spot.x), float(spot.z))) < 0.45:
				far = false
		if not far:
			continue
		var overlay := _move_search_overlay(state.overlay, String(state.cid), p, float(state.rotation))
		checks += 1
		state.route_checks = int(state.route_checks) + 1
		var checked := CustomMapValidator.validate(state.base_content, state.base_layout, overlay, state.catalogue)
		if bool(checked.get("ok", false)):
			(state.spots as Array).append({"x": p.x, "z": p.y, "rotation": state.rotation})
		if float(Time.get_ticks_usec() - started) / 1000.0 >= budget_ms:
			break
	state.done = int(state.cursor) >= (state.candidates as Array).size() or (state.spots as Array).size() >= 12
	_record_search_step(state, started)
	return state

## 与 WorkshopDoc.with_city 的端点跟随公式相同；不引入 GeoRules -> 编辑器 Backend 的循环依赖。
static func _move_search_overlay(source: Dictionary, cid: String, p: Vector2, rotation: float) -> Dictionary:
	var overlay := source.duplicate(true)
	if cid.begins_with("x_"):
		for city: Dictionary in overlay.get("new_cities", []):
			if "x_" + String(city.slot) != cid:
				continue
			var old := Vector2(float(city.x), float(city.z))
			var delta := p - old
			var handles: Array = city.get("route", {}).get("handles", [])
			for i in handles.size():
				var h := Vector2(float(handles[i][0]), float(handles[i][1]))
				h += delta * clampf(1.0 - h.distance_to(old) / 4.0, 0.0, 1.0)
				handles[i] = [snappedf(h.x, 0.001), snappedf(h.y, 0.001)]
			city["x"] = p.x
			city["z"] = p.y
			city["rotation"] = snappedf(rotation, 0.001)
			break
	else:
		if not overlay.has("moves"):
			overlay["moves"] = {"cities": {}, "routes": {}}
		if not overlay.moves.has("cities"):
			overlay.moves["cities"] = {}
		overlay.moves.cities[cid] = {"x": p.x, "z": p.y, "rotation": snappedf(rotation, 0.001)}
	return overlay

static func _city_height_edited(city: Dictionary, derived: Dictionary) -> bool:
	var layer: Dictionary = derived.get("landscape", {})
	for edit: Dictionary in layer.get("edits", []):
		if String(edit.get("op", "")) == "flatten":
			var distance := Vector2(float(city.x) - float(edit.x), float(city.z) - float(edit.z)).length()
			if distance <= float(edit.radius) + float(city.get("foot", PLACE_FOOT)) * CustomMapGeo.SLOPE_RADIUS:
				return true
	return false

static func _geo_key(geo: CustomMapGeo) -> int:
	return int(geo.call("cache_key")) if geo.has_method("cache_key") else 0

static func _layout_geo(derived: Dictionary, geo: CustomMapGeo) -> CustomMapGeo:
	if geo == null:
		geo = CustomMapGeo.shared()
	# 使用同一地图的地形层；旧地图仍得到 shared 实例。
	if derived.has("landscape") and not (derived.landscape as Dictionary).is_empty() and geo.has_method("cache_key"):
		return CustomMapGeo.for_layout(derived)
	return geo


## 在一个宿主旁边找能放新城的位置（给测试、目录构建工具的预设位用）：在 overlay（可以是空的）已有的新城之外再放一座，
## 绿区里按离宿主约 11 u 由近到远取格，自动画路、整张图查一遍，全过才要。返回 [{x, z, handles, stop_t}]，最多 want 个，
## 两两至少隔 spacing。slot 是试放用的槽位（不能和 overlay 里的重复）。
static func find_spots(base_layout: Dictionary, overlay: Dictionary, host_id: String, route_type: String, archetype: String,
		catalogue: Dictionary, geo: CustomMapGeo, want := 3, spacing := 3.0, slot := "e9") -> Array:
	if geo == null:
		geo = CustomMapGeo.shared()
	var derived := CustomBoardLayout.derive(base_layout, overlay, geo, catalogue)
	var arch := CustomBoardLayout.archetype(catalogue, archetype)
	var foot := float(arch.get("foot", PLACE_FOOT))
	var zone := feasible_zone_for_hosts(derived, route_type, [host_id], geo, foot)
	var W := zone.get_width()
	var data := zone.get_data()
	var host: Dictionary = _by_id(derived.get("cities", []))[host_id]
	var hc := Vector2(float(host.x), float(host.z))
	var cands: Array = []
	for k in data.size():
		if data[k] != 0:
			var p := Vector2((k % W + 0.5) * GRID, (k / W + 0.5) * GRID)
			cands.append([absf(p.distance_to(hc) - 11.0), p])
	cands.sort_custom(func(a, b): return float(a[0]) < float(b[0]) or (float(a[0]) == float(b[0]) and (a[1] as Vector2) < (b[1] as Vector2)))
	var out: Array = []
	var tries := 0
	for c: Array in cands:
		if out.size() >= want or tries >= 60:
			break
		var p: Vector2 = c[1]
		var far := true
		for o: Dictionary in out:
			if Vector2(float(o.x), float(o.z)).distance_to(p) < spacing:
				far = false
		if not far:
			continue
		tries += 1
		var ar := auto_route(derived, host_id, p, route_type, geo)
		if not bool(ar.ok):
			continue
		var ov := overlay.duplicate(true)
		var list: Array = ov.get("new_cities", [])
		list.append({"slot": slot, "name": "试放", "archetype": archetype, "host": host_id, "route_type": route_type,
			"x": snappedf(p.x, 0.001), "z": snappedf(p.y, 0.001), "rotation": 0.0, "size": 1.0,
			"route": {"handles": ar.handles, "stop_t": ar.stop_t}})
		ov["new_cities"] = list
		var d1 := CustomBoardLayout.derive(base_layout, ov, geo, catalogue)
		if check(d1, base_layout, ov, geo).is_empty():
			out.append({"x": snappedf(p.x, 0.001), "z": snappedf(p.y, 0.001), "handles": ar.handles, "stop_t": ar.stop_t})
	if out.is_empty():
		# 搭档/目录等同步调用只花最多 2 秒启动预算；后续调用继续同一搜索，UI 用 step 分帧。
		var state := placement_search_begin(derived, host_id, route_type, geo, foot)
		var until := Time.get_ticks_msec() + 2000
		var before_checks := int(state.route_checks)
		while not bool(state.done) and (state.spots as Array).is_empty() and Time.get_ticks_msec() < until and int(state.route_checks) - before_checks < 512:
			placement_search_step(state, geo, 8.0, 1)
		for spot: Dictionary in state.spots:
			var p := Vector2(float(spot.x), float(spot.z))
			var far := true
			for other: Dictionary in out:
				if p.distance_to(Vector2(float(other.x), float(other.z))) < spacing:
					far = false
			if not far:
				continue
			var ov := overlay.duplicate(true)
			var list: Array = ov.get("new_cities", [])
			list.append({"slot": slot, "name": "试放", "archetype": archetype, "host": host_id, "route_type": route_type,
				"x": p.x, "z": p.y, "rotation": 0.0, "size": 1.0, "route": {"handles": spot.handles, "stop_t": spot.stop_t}})
			ov["new_cities"] = list
			var candidate := CustomBoardLayout.derive(base_layout, ov, geo, catalogue)
			if check(candidate, base_layout, ov, geo).is_empty():
				out.append(spot.duplicate(true))
			if out.size() >= want:
				break
	return out


## 布局键覆盖可达区/障碍掩码的全部输入。点列整体哈希与 RouteGeo 一致，不能每 20 点抽样：
## 局部编辑会只改变两个采样点之间的曲线；城坐标也不能先四舍五入。端点决定哪些路是宿主自己的路。
static func layout_key(derived: Dictionary) -> String:
	var parts := PackedStringArray()
	for c: Dictionary in derived.get("cities", []):
		parts.append("city:%s:%d" % [c.id, [float(c.x), float(c.z), float(c.get("foot", 0.0))].hash()])
	for r: Dictionary in derived.get("routes", []):
		var pts: Array = r.points
		var ends := _ends_of(derived, r)
		parts.append("route:%s:%s:%s:%s:%d:%d" % [r.id, String(r.get("type", "")), ends[0], ends[1], pts.size(), pts.hash()])
	for k: Dictionary in derived.get("kit", []):
		if String(k.get("asset", "")).begins_with("forest") or float(k.get("s", 0.0)) <= 0.0:
			continue
		parts.append("mountain:%s:%d" % [String(k.get("asset", "")), [float(k.x), float(k.z), float(k.s)].hash()])
	return "|".join(parts).sha256_text()


## 每个布局一份：每格附近有哪些路（离路 1.0 以内 prox、0.3 以内 line，按路的位掩码）、陆路不能压的山
static func _layout_masks(derived: Dictionary, lkey: String) -> Dictionary:
	if _mask_cache.has(lkey):
		return _mask_cache[lkey]
	var W := int(ceil(128.0 / GRID))
	var H := int(ceil(59.63125 / GRID))
	var prox := PackedInt32Array()
	prox.resize(W * H)
	var line := PackedInt32Array()
	line.resize(W * H)
	var bits := {}
	var bit := 0
	for r: Dictionary in derived.get("routes", []):
		var b := 1 << mini(bit, 30)
		bit += 1
		bits[String(r.id)] = b
		var pts := _xz(r.points)
		var cum := _cum(pts)
		var L := cum[cum.size() - 1]
		var s := 0.0
		while s <= L:
			var p := CustomBoardLayout.point_at(pts, cum, s)
			_stamp_bits(prox, W, H, p, ROUTE_GAP + REACH_MARGIN, b)
			_stamp_bits(line, W, H, p, 0.3 + REACH_MARGIN, b)
			s += 0.2
	var mountain := PackedByteArray()
	mountain.resize(W * H)
	for k: Dictionary in derived.get("kit", []):
		if String(k.get("asset", "")).begins_with("forest") or float(k.get("s", 0.0)) <= 0.0:
			continue
		_stamp_disc(mountain, W, H, Vector2(float(k.x), float(k.z)), float(k.s) * float(R_ASSET.get(String(k.asset), 1.0)) + PEAK_ROUTE_EXTRA + REACH_MARGIN)
	var out := {"prox": prox, "line": line, "mountain": mountain, "bits": bits}
	if _mask_cache.size() > 8:
		_mask_cache.clear()
	_mask_cache[lkey] = out
	return out


static func _stamp_bits(arr: PackedInt32Array, W: int, H: int, p: Vector2, r: float, b: int) -> void:
	var i0 := maxi(0, int((p.x - r) / GRID))
	var i1 := mini(W - 1, int((p.x + r) / GRID))
	var j0 := maxi(0, int((p.y - r) / GRID))
	var j1 := mini(H - 1, int((p.y + r) / GRID))
	var r2 := r * r
	for j in range(j0, j1 + 1):
		var dz := (j + 0.5) * GRID - p.y
		for i in range(i0, i1 + 1):
			var dx := (i + 0.5) * GRID - p.x
			if dx * dx + dz * dz < r2:
				arr[j * W + i] |= b


static func _stamp_disc(arr: PackedByteArray, W: int, H: int, p: Vector2, r: float) -> void:
	var i0 := maxi(0, int((p.x - r) / GRID))
	var i1 := mini(W - 1, int((p.x + r) / GRID))
	var j0 := maxi(0, int((p.y - r) / GRID))
	var j1 := mini(H - 1, int((p.y + r) / GRID))
	var r2 := r * r
	for j in range(j0, j1 + 1):
		var dz := (j + 0.5) * GRID - p.y
		for i in range(i0, i1 + 1):
			var dx := (i + 0.5) * GRID - p.x
			if dx * dx + dz * dz < r2:
				arr[j * W + i] = 1


## 陆路格：这一格和周围 8 格的格心都在陆上
static func _land_block(clear: PackedFloat32Array, W: int, H: int, i: int, j: int) -> bool:
	for dj in [-1, 0, 1]:
		for di in [-1, 0, 1]:
			var ii: int = clampi(i + int(di), 0, W - 1)
			var jj: int = clampi(j + int(dj), 0, H - 1)
			if clear[jj * W + ii] >= 0.0:
				return false
	return true


static func _chaikin(pts: PackedVector2Array, passes: int) -> PackedVector2Array:
	var p := pts
	for _k in passes:
		if p.size() < 3:
			return p
		var q := PackedVector2Array([p[0]])
		for i in p.size() - 1:
			q.append(p[i].lerp(p[i + 1], 0.25))
			q.append(p[i].lerp(p[i + 1], 0.75))
		q.append(p[p.size() - 1])
		p = q
	return p


## 每一段长过 max_leg 的就等分，补上中间点（含首尾）
static func _densify(pts: PackedVector2Array, max_leg: float) -> PackedVector2Array:
	if pts.size() < 2:
		return pts
	var out := PackedVector2Array([pts[0]])
	for i in range(1, pts.size()):
		var n := maxi(1, int(ceil(pts[i - 1].distance_to(pts[i]) / max_leg)))
		for k in range(1, n + 1):
			out.append(pts[i - 1].lerp(pts[i], float(k) / float(n)))
	return out


## Douglas–Peucker：返回简化后的点（含首尾）
static func _douglas_peucker(pts: PackedVector2Array, tol: float) -> PackedVector2Array:
	if pts.size() < 3:
		return pts
	var keep := PackedByteArray()
	keep.resize(pts.size())
	keep[0] = 1
	keep[pts.size() - 1] = 1
	var stack: Array = [[0, pts.size() - 1]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var a: int = seg[0]
		var b: int = seg[1]
		var worst := -1.0
		var wi := -1
		for i in range(a + 1, b):
			var d := Geometry2D.get_closest_point_to_segment(pts[i], pts[a], pts[b]).distance_to(pts[i])
			if d > worst:
				worst = d
				wi = i
		if wi >= 0 and worst > tol:
			keep[wi] = 1
			stack.append([a, wi])
			stack.append([wi, b])
	var out := PackedVector2Array()
	for i in pts.size():
		if keep[i] != 0:
			out.append(pts[i])
	return out


## 在临时布局上查一条候选路（放城时新城还不在布局里：放一座临时的新城）：只看这条路自己的规则
static func _probe_route(derived: Dictionary, host_id: String, target_id: String, to_xz: Vector2, foot: float, rtype: String,
		handles: Array, stop_t: Array, geo: CustomMapGeo, check_city := false) -> Array[Dictionary]:
	var tid := target_id if target_id != "" else "x_probe"
	var probe := derived.duplicate(false)
	var cities: Array = []
	var city: Dictionary = {}
	for c: Dictionary in derived.get("cities", []):
		if String(c.id) == tid:
			city = c.duplicate()
			city["x"] = to_xz.x
			city["z"] = to_xz.y
			cities.append(city)
		else:
			cities.append(c)
	if city.is_empty():
		city = {"id": tid, "name": tid, "x": to_xz.x, "z": to_xz.y, "y": geo.city_y(to_xz.x, to_xz.y, foot), "foot": foot, "rotation": 0.0}
		cities.append(city)
	var cmap := _by_id(cities)
	var rid := "%s_%s_x_%s" % ["land" if rtype == "LAND" else "sea", host_id, tid.trim_prefix("x_")]
	var routes: Array = []
	for r: Dictionary in derived.get("routes", []):
		var e := _ends_of(derived, r)
		if (e[0] == host_id and e[1] == tid) or (e[1] == host_id and e[0] == tid):
			rid = String(r.id)
			continue
		routes.append(r)
	var r := {"id": rid, "type": rtype, "a": host_id, "b": tid,
		"points": CustomBoardLayout.with_heights(CustomBoardLayout.spline_points(cmap[host_id], city, handles), rtype, geo)}
	routes.append(r)
	var stops: Array = []
	for s: Dictionary in derived.get("stops", []):
		if not String(s.id).begins_with(rid + "_"):
			stops.append(s)
	var st: Array = [{"id": rid + "_01", "type": rtype, "x": 0.0, "y": 0.0, "z": 0.0}, {"id": rid + "_02", "type": rtype, "x": 0.0, "y": 0.0, "z": 0.0}]
	CustomBoardLayout._place_stops(st, r, stop_t, geo)
	stops.append_array(st)
	probe["cities"] = cities
	probe["routes"] = routes
	probe["stops"] = stops
	var checked_cities: Array[String] = []
	if check_city:
		checked_cities.append(tid)
	var errs := check_objects(probe, checked_cities, [rid] as Array[String], geo, {}, {})
	return errs


# ================================================================ 小工具

static func _add(out: Array[Dictionary], code: String, target: String, tech: String, args: Array = [], kid_key := "", location: Dictionary = {}) -> void:
	var k := String(KID.get(kid_key if kid_key != "" else code, ""))
	if not args.is_empty() and k.contains("%s"):
		k = k % args
	var row := {"code": code, "target": target, "kid": k, "tech": tech}
	row.merge(location, true)
	out.append(row)


static func _dedupe(out: Array[Dictionary]) -> Array[Dictionary]:
	var seen := {}
	var res: Array[Dictionary] = []
	for e in out:
		var key := "%s|%s" % [e.code, e.target]
		if seen.has(key):
			continue
		seen[key] = true
		res.append(e)
	return res


static func _by_id(list: Array) -> Dictionary:
	var d := {}
	for e in list:
		if e is Dictionary:
			d[String(e.get("id", ""))] = e
	return d


## 一条路两端的城：写明了就用写明的；原布局（没写）按最近的城（与 Paths 相同）
static func _ends_of(derived: Dictionary, r: Dictionary) -> Array[String]:
	if r.has("a") and r.has("b"):
		return [String(r.a), String(r.b)]
	var ends := CustomBoardLayout.corridor_ends()
	if ends.has(String(r.id)):
		return [String(ends[String(r.id)][0]), String(ends[String(r.id)][1])]
	var pts: Array = r.points
	return [_nearest_city(derived, pts[0]), _nearest_city(derived, pts[pts.size() - 1])]


static func _nearest_city(derived: Dictionary, q: Array) -> String:
	var best := ""
	var bd := INF
	for c: Dictionary in derived.get("cities", []):
		var d := Vector2(float(c.x) - float(q[0]), float(c.z) - float(q[2])).length()
		if d < bd:
			bd = d
			best = String(c.id)
	return best


static func _stop_t_of(overlay: Dictionary, rid: String) -> Array:
	if CustomMapFreeRoutes.enabled(overlay) and overlay.free_routes.routes.has(rid):return overlay.free_routes.routes[rid].get("stop_t",[])
	var mv: Dictionary = overlay.get("moves", {}) if overlay.get("moves", {}) is Dictionary else {}
	var mr: Dictionary = mv.get("routes", {}) if mv.get("routes", {}) is Dictionary else {}
	if mr.has(rid):
		return (mr[rid] as Dictionary).get("stop_t", [])
	for nc in CustomMapSchema.corridor_entries(overlay):
		if nc is Dictionary and rid == CustomMapSchema.corridor_id(str(nc.slot), str(nc.get("host","")), str(nc.get("route_type","LAND"))):
			return (nc.get("route", {}) as Dictionary).get("stop_t", [])
	return []


static func _mini_paths(derived: Dictionary, rids: Array) -> Object:
	var want := {}
	for rid in rids:
		want[String(rid)] = true
	var routes: Array = []
	var stops: Array = []
	var cids := {}
	for r: Dictionary in derived.get("routes", []):
		if want.has(String(r.id)):
			var rr := r.duplicate(false)
			var e := _ends_of(derived, r)
			rr["a"] = e[0]
			rr["b"] = e[1]
			routes.append(rr)
			cids[e[0]] = true
			cids[e[1]] = true
	for s: Dictionary in derived.get("stops", []):
		var sid := String(s.id)
		if want.has(sid.substr(0, sid.length() - 3)):
			stops.append(s)
	var cities: Array = []
	for c: Dictionary in derived.get("cities", []):
		if cids.has(String(c.id)):
			cities.append(c)
	var P: Object = Paths.new()
	P.set("use_route_cache", true)
	P.call("build", {"board": derived.get("board", {}), "cities": cities, "routes": routes, "stops": stops}, HULL_LEN, HULL_BEAM)
	return P


static func _xz(points: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in points:
		out.append(Vector2(float(q[0]), float(q[2])))
	return out


static func _cum(pts: PackedVector2Array) -> PackedFloat32Array:
	var cum := PackedFloat32Array([0.0])
	for i in range(1, pts.size()):
		cum.append(cum[i - 1] + pts[i - 1].distance_to(pts[i]))
	return cum


static func _length(pts: PackedVector2Array) -> float:
	var c := _cum(pts)
	return c[c.size() - 1]


static func _project(pts: PackedVector2Array, cum: PackedFloat32Array, p: Vector2) -> float:
	var best := 0.0
	var bd := INF
	for i in pts.size():
		var d := pts[i].distance_squared_to(p)
		if d < bd:
			bd = d
			best = cum[i]
	return best


static func _polyline_dist(p: Vector2, points: Array) -> float:
	var best := INF
	var prev := Vector2.INF
	for i in range(0, points.size(), 2):
		var q := Vector2(float(points[i][0]), float(points[i][2]))
		if prev != Vector2.INF:
			best = minf(best, Geometry2D.get_closest_point_to_segment(p, prev, q).distance_to(p))
		prev = q
	var last: Array = points[points.size() - 1]
	best = minf(best, p.distance_to(Vector2(float(last[0]), float(last[2]))))
	return best


## 城的占地椭圆（rx = 0.45·foot，rz = 0.38·foot）与一个圆之间的空隙（负数 = 压上了）
static func _ellipse_gap(c: Vector2, foot: float, p: Vector2, r: float) -> float:
	var d := p - c
	var len := d.length()
	if len < 1e-6:
		return -r
	var u := d / len
	var rx := CustomMapGeo.FOOT_RX * foot
	var rz := CustomMapGeo.FOOT_RZ * foot
	var er := 1.0 / sqrt(pow(u.x / rx, 2.0) + pow(u.y / rz, 2.0))
	return len - er - r


static func _near_any(q: Vector2, centres: Array[Vector2], r: float) -> bool:
	for c in centres:
		if q.distance_to(c) < r:
			return true
	return false


static func _in_ring(q: Vector2, centres: Array[Vector2], r0: float, r1: float) -> bool:
	for c in centres:
		var d := q.distance_to(c)
		if d >= r0 and d < r1:
			return true
	return false


static func _base() -> Dictionary:
	if _base_ref.is_empty():
		_base_ref = JSON.parse_string(FileAccess.get_file_as_string(CustomBoardLayout.LAYOUT))
	return _base_ref


## 一条路的几何：xz 点列、弧长、包围盒、最长的一段、1 u 格子里有哪几段（第 i 段 = pts[i]..pts[i + 1]）。
## 按「路 id + 点列」缓存（_route_geo）：拖动时只有被拖的那几条路要重算
class RouteGeo:
	var key := ""
	var pts := PackedVector2Array()
	var cum := PackedFloat32Array()
	var bbox := Rect2()
	var max_seg := 0.0
	var cells := {}            # Vector2i -> Array[int]

	func _init(points: Array, k: String) -> void:
		key = k
		var n := points.size()
		pts.resize(n)
		cum.resize(n)
		for i in n:
			var q: Array = points[i]
			pts[i] = Vector2(float(q[0]), float(q[2]))
		if n == 0:
			return
		bbox = Rect2(pts[0], Vector2.ZERO)
		cum[0] = 0.0
		for i in range(1, n):
			var a := pts[i - 1]
			var b := pts[i]
			var d := a.distance_to(b)
			cum[i] = cum[i - 1] + d
			max_seg = maxf(max_seg, d)
			bbox = bbox.expand(b)
			var lo := Vector2i(int(floor(minf(a.x, b.x))), int(floor(minf(a.y, b.y))))
			var hi := Vector2i(int(floor(maxf(a.x, b.x))), int(floor(maxf(a.y, b.y))))
			for cx in range(lo.x, hi.x + 1):
				for cz in range(lo.y, hi.y + 1):
					var cell := Vector2i(cx, cz)
					if not cells.has(cell):
						cells[cell] = []
					cells[cell].append(i - 1)

	## 离某一个 centres 在 [r0, r1) 之间的点的下标（升序）
	func ring_points(centres: Array[Vector2], r0: float, r1: float) -> PackedInt32Array:
		var n := pts.size()
		var mark := PackedByteArray()
		mark.resize(n)
		for c in centres:
			var lo := Vector2i(int(floor(c.x - r1)), int(floor(c.y - r1)))
			var hi := Vector2i(int(floor(c.x + r1)), int(floor(c.y + r1)))
			for cx in range(lo.x, hi.x + 1):
				for cz in range(lo.y, hi.y + 1):
					for si in cells.get(Vector2i(cx, cz), []):
						for pi in [int(si), int(si) + 1]:
							if mark[pi] != 0:
								continue
							for c2 in centres:
								var d := pts[pi].distance_to(c2)
								if d >= r0 and d < r1:
									mark[pi] = 1
									break
		var out := PackedInt32Array()
		for i in n:
			if mark[i] != 0:
				out.append(i)
		return out


## 一张布局里全部路的索引：1 u 格子里有哪几条路，每条路的几何、两端、类型。按布局里各条路的缓存键缓存
class LayoutIndex:
	var geos: Array = []               # 序号 -> RouteGeo
	var points: Array = []             # 序号 -> 布局里的原始点列（[x, y, z]）
	var rids := PackedStringArray()
	var types := PackedStringArray()
	var ends: Array = []               # 序号 -> [a, b]
	var ord := {}                      # 路 id -> 序号
	var cell_routes := {}              # Vector2i -> Array[序号]

	func add(rid: String, g: RouteGeo, points_raw: Array, rtype: String, e: Array) -> void:
		var o := geos.size()
		ord[rid] = o
		geos.append(g)
		points.append(points_raw)
		rids.append(rid)
		types.append(rtype)
		ends.append(e)
		for cell in g.cells:
			if not cell_routes.has(cell):
				cell_routes[cell] = []
			cell_routes[cell].append(o)

	## q 附近 r 以内，每条（skip 里没标的）路离 q 最近的那一处：{序号: [距离, 最近点]}
	func near(q: Vector2, r: float, skip: PackedByteArray) -> Dictionary:
		var best := {}
		var x1 := int(floor(q.x + r))
		var z1 := int(floor(q.y + r))
		for cx in range(int(floor(q.x - r)), x1 + 1):
			for cz in range(int(floor(q.y - r)), z1 + 1):
				var cell := Vector2i(cx, cz)
				for o in cell_routes.get(cell, []):
					if skip[o] != 0:
						continue
					var g: RouteGeo = geos[o]
					var pts := g.pts
					for si in g.cells[cell]:
						var c := Geometry2D.get_closest_point_to_segment(q, pts[si], pts[si + 1])
						var d := c.distance_to(q)
						if d < r and (not best.has(o) or d < float(best[o][0])):
							best[o] = [d, c]
		return best

	## 第 o 条路离 q 最近、且在 r 以内的那一处：[距离, 最近点]；没有时为 []
	func nearest_on(o: int, q: Vector2, r: float) -> Array:
		var g: RouteGeo = geos[o]
		var pts := g.pts
		var best: Array = []
		for cx in range(int(floor(q.x - r)), int(floor(q.x + r)) + 1):
			for cz in range(int(floor(q.y - r)), int(floor(q.y + r)) + 1):
				for si in g.cells.get(Vector2i(cx, cz), []):
					var c := Geometry2D.get_closest_point_to_segment(q, pts[si], pts[si + 1])
					var d := c.distance_to(q)
					if d < r and (best.is_empty() or d < float(best[0])):
						best = [d, c]
		return best


static var _rgeo_cache := {}
static var _index_cache := {}


## 一条路的几何（缓存键：路 id、点数、点列的哈希）
static func _route_geo(r: Dictionary) -> RouteGeo:
	var points: Array = r.get("points", [])
	var key := "%s|%d|%d" % [String(r.get("id", "")), points.size(), points.hash()]
	var g: RouteGeo = _rgeo_cache.get(key)
	if g == null:
		g = RouteGeo.new(points, key)
		if _rgeo_cache.size() > 512:
			_rgeo_cache.clear()
		_rgeo_cache[key] = g
	return g


## 布局里全部路的索引（缓存键：各条路的缓存键、两端和类型；共享城边的相交规则区分同型/异型）
static func _index(derived: Dictionary) -> LayoutIndex:
	var list: Array = []
	var keys := PackedStringArray()
	for r in derived.get("routes", []):
		if not r is Dictionary:
			continue
		var g := _route_geo(r)
		var e := _ends_of(derived, r)
		list.append([r, g, e])
		keys.append("%s>%s>%s>%s" % [g.key, e[0], e[1], String(r.get("type", ""))])
	var k := "|".join(keys)
	var idx: LayoutIndex = _index_cache.get(k)
	if idx != null:
		return idx
	idx = LayoutIndex.new()
	for it: Array in list:
		idx.add(String(it[0].id), it[1], it[0].points, String(it[0].get("type", "")), it[2])
	if _index_cache.size() > 16:
		_index_cache.clear()
	_index_cache[k] = idx
	return idx
