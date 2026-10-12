class_name CustomBoardLayout

## 3D 棋盘布局推导（docs/design/map-editor-20260930/DESIGN.md 3.10.3）：纯函数，同样的输入输出的 JSON 字节相同；
## 游戏和工坊调用同一份代码。覆盖层里既没有 moves 也没有新城时，直接返回 base_layout 本身（同一个对象）。归 WP3。
##
## 输出在原布局的基础上多出这些键（原布局里都没有，所以没地图时棋盘一个字节不变）：
##   routes[*].a / b     每条路两端的城（原版 19 条取自 map_corridors_v1.json，新路是 宿主 / 新城）
##   edges_extra         新城的 3 条边 {a, b, corridor_id}（paths.gd 读完正式边文件后追加）
##   decor_cleared       {tree_kit, props, kit: [原布局里的下标]}：压到新几何的树、石头、森林。
##                       不从数组里删，由棋盘把这些实例缩成 0：实例都在，工坊就地整理时还能放回来（3.12.7）
##   paving              城下石板的操作表（review.gd apply_paving）
##   plaque_shift        {原城 id: [dx, dy, dz]}：挪过的原城，名牌锚点跟着平移
##   custom_map_sha      覆盖层的指纹（只在调用方给了 sha 时写：工坊拖动时每帧都推导，不能每帧把整份文档算一遍 SHA-256）
## 新城的记录另带 size（覆盖层里的大小，几何规则 G_SIZE 查它）。
## life 的营地、羊群、尘土、薄雾照设计从数组里删掉（它们不按下标对应实例，工坊里用 life.hide_near 就地藏）。
##
## 覆盖层的数据格式坏了（字段类型不对、城 id / 商道 id 不认识、坐标不是有限的数……）时不报脚本错误，返回
## {"error": 说明}；CustomMapGeoRules.check 见到它报 G_DATA（「这张地图的数据坏了」），校验不会放行。

const LAYOUT := "res://assets/merchant_board_claude/board_layout.json"
const CORRIDORS := "res://data/rulesets/lshu_configurable_v1/map_corridors_v1.json"
const CATALOGUE := "res://data/custom_map/catalogue_v1.json"
## 目录里的原型读不到时，新城的模型指向这里（review.gd 再兜底成方块，不崩）
const FALLBACK_TOWN := "res://assets/merchant_board_claude/catalogue/_fallback_town.glb"
## 新城的石板从这座城抄（foot 3.19）
const TEMPLATE_CITY := "yumenguan"
const DEFAULT_FOOT := 3.4
const RESAMPLE := 0.05          # 与原布局相同的点距
const RUBBER := 0.45            # 橡皮筋的影响长度（占整条路的比例）
const TREE_ROUTE_CLEAR := 0.7   # 树、石头离陆路
const TREE_CITY_CLEAR := 0.75   # 树、石头离城心（× foot）
const LIFE_ROUTE_CLEAR := 1.0   # 营地、羊群、尘土、薄雾离新路、改过的路

## 测试用计数器（P-5：没有地图的整局加一次棋盘重载，保持 0）
static var derive_calls := 0
## 只给测试用：WP6a 的目录 data/custom_map/catalogue_v1.json 合入之前，用它顶替
static var test_catalogue := {}
static var _corridor_ends := {}


## sha：覆盖层的指纹，给了就写进结果的 custom_map_sha（游戏重建世界时由 derive_for_content 传 content 里的；
## 工坊拖动预览时不传）
static func derive(base_layout: Dictionary, overlay: Dictionary, geo: CustomMapGeo, catalogue: Dictionary, sha := "") -> Dictionary:
	if CustomMapFreeAuthor.enabled(overlay):return CustomMapFreeAuthor.derive(base_layout,overlay,geo,catalogue,sha)
	if CustomMapFreeRoutes.enabled(overlay):
		var legacy:=derive(base_layout,CustomMapFreeRoutes.clean(overlay),geo,catalogue,sha)
		if legacy.has("error"):return legacy
		return CustomMapFreeRoutes.derive(legacy,overlay,geo,CustomMapLoader.base_content())
	derive_calls += 1
	var bad := overlay_error(overlay, base_layout)
	if bad != "":
		return {"error": bad}
	var moves: Dictionary = overlay.get("moves", {})
	var mc: Dictionary = moves.get("cities", {})
	var mr: Dictionary = moves.get("routes", {})
	var newc: Array = overlay.get("new_cities", [])
	var landscape: Dictionary = overlay.get("landscape", {})
	var has_landscape := not (landscape.get("edits", []) as Array).is_empty()
	if mc.is_empty() and mr.is_empty() and newc.is_empty() and not has_landscape and not overlay.has("plants") and not overlay.has("city_badges"):
		return base_layout
	if has_landscape:
		geo = CustomMapGeo.for_overlay(overlay)
	elif geo == null or geo.cache_key() != 0:
		geo = CustomMapGeo.shared()
	# 1. 复制：只深拷贝会被改的几段，其它段按引用共享
	var out := base_layout.duplicate(false)
	for key in ["cities", "routes", "stops", "life"]:
		if base_layout.has(key):
			out[key] = base_layout[key].duplicate(true)
	var cities := {}
	for c: Dictionary in out.cities:
		cities[String(c.id)] = c
	var base_cities := {}
	for c: Dictionary in base_layout.cities:
		base_cities[String(c.id)] = c
	if has_landscape:
		out["landscape"] = landscape.duplicate(true)
		# 仅笔刷覆盖处重新贴地，其余原城高度不动。
		for c: Dictionary in out.cities:
			if geo.has_height_edit(float(c.x), float(c.z)):
				c.y = geo.city_y(float(c.x), float(c.z), float(c.foot))
	# 2. 写明端点：全部 19 条原版路
	var ends := corridor_ends()
	var routes := {}
	for r: Dictionary in out.routes:
		var rid := String(r.id)
		if ends.has(rid):
			r["a"] = ends[rid][0]
			r["b"] = ends[rid][1]
		routes[rid] = r
	# 3. 挪原城
	var moved := {}             # 城 id -> Vector2 位移
	var plaque_shift := {}
	if has_landscape:
		for cid in cities:
			var dy := float(cities[cid].y) - float(base_cities[cid].y)
			if absf(dy) > 1e-6:
				plaque_shift[cid] = [0.0, dy, 0.0]
	for cid in _sorted_keys(mc):
		if not cities.has(cid):
			continue
		var m: Dictionary = mc[cid]
		var c: Dictionary = cities[cid]
		var ox := float(c.x)
		var oz := float(c.z)
		var oy := float(c.y)
		c["x"] = float(m.get("x", ox))
		c["z"] = float(m.get("z", oz))
		c["rotation"] = float(m.get("rotation", float(c.get("rotation", 0.0))))
		c["y"] = geo.city_y(float(c.x), float(c.z), float(c.foot))
		var d := Vector2(float(c.x) - ox, float(c.z) - oz)
		if d.length() > 1e-6:
			moved[cid] = d
		plaque_shift[cid] = [float(c.x) - ox, float(c.y) - oy, float(c.z) - oz]
	# 4 + 5. 原版路：有控制点的走样条；两端城挪过的走橡皮筋；都没动的原样保留（点列逐字节不变）。
	# 只挪了停靠点（没有控制点、两端的城也没挪）的路：路形不变，点列和 lane 都照原样留着，只把两个停靠点放到 stop_t 处
	var changed_routes: Array[String] = []
	var stops_by_route := {}
	for s: Dictionary in out.stops:
		var sid := String(s.id)
		var rid := sid.substr(0, sid.length() - 3)
		if not stops_by_route.has(rid):
			stops_by_route[rid] = []
		stops_by_route[rid].append(s)
	for rid in ends:
		if not routes.has(rid):
			continue
		var r: Dictionary = routes[rid]
		var ca: Dictionary = cities[String(r.a)]
		var cb: Dictionary = cities[String(r.b)]
		var edit: Dictionary = mr.get(rid, {})
		var handles: Array = edit.get("handles", [])
		var rtype := String(r.type)
		if not handles.is_empty():
			r["points"] = _memo_points(["S", geo.cache_key(), rtype, _city_key(ca), _city_key(cb), handles.duplicate(true)],
				func(): return with_heights(spline_points(ca, cb, handles), rtype, geo))
		elif moved.has(String(r.a)) or moved.has(String(r.b)):
			var da: Vector2 = moved.get(String(r.a), Vector2.ZERO)
			var db: Vector2 = moved.get(String(r.b), Vector2.ZERO)
			var raw: Array = r.points
			r["points"] = _memo_points(["R", geo.cache_key(), rid, rtype, raw.size(), raw.hash(), da, db],
				func(): return with_heights(rubber_band(raw, da, db), rtype, geo))
		elif edit.has("stop_t"):
			_place_stops(stops_by_route.get(rid, []), r, edit.stop_t, geo)
			continue
		else:
			continue
		r.erase("lane")
		changed_routes.append(rid)
		_place_stops(stops_by_route.get(rid, []), r, edit.get("stop_t", [1.0 / 3.0, 2.0 / 3.0]), geo)
	# 6. 新城
	var edges_extra: Array = []
	var new_ids: Array[String] = []
	var ordered := CustomMapSchema.corridor_entries(overlay)
	ordered.sort_custom(func(p, q): return String(p.get("slot", "")) < String(q.get("slot", "")))
	for nc: Dictionary in ordered:
		var slot := String(nc.get("slot", ""))
		var id := "x_" + slot
		var host := String(nc.get("host", ""))
		if slot == "" or not cities.has(host):
			continue
		var arch := archetype(catalogue, String(nc.get("archetype", "")))
		var size := float(nc.get("size", 1.0))
		var foot := float(arch.get("foot", DEFAULT_FOOT)) * size
		var x := float(nc.get("x", 0.0))
		var z := float(nc.get("z", 0.0))
		var city := {"id": id, "board_id": id, "name": String(nc.get("name", id)), "x": x, "y": geo.city_y(x, z, foot), "z": z,
			"foot": foot, "rotation": float(nc.get("rotation", 0.0)), "size": size,
			"model": String(arch.get("model", FALLBACK_TOWN)), "bounds": arch.get("bounds", {})}
		var local_model := CustomMapLocalAssets.bound_id(overlay, slot, "city_model")
		if local_model != "":
			city.model = CustomMapLocalAssets.path(local_model)
			city.bounds = {} # Fit actual imported bounds; keep original validated footprint.
		if not bool(nc.get("_secondary", false)):
			out.cities.append(city)
			cities[id] = city
			new_ids.append(id)
		var rtype := String(nc.get("route_type", "LAND"))
		var rid := "%s_%s_x_%s" % ["land" if rtype == "LAND" else "sea", host, slot]
		var rt: Dictionary = nc.get("route", {})
		var hs: Array = rt.get("handles", [])
		var hc: Dictionary = cities[host]
		var r := {"id": rid, "type": rtype, "a": host, "b": id,
			"points": _memo_points(["S", geo.cache_key(), rtype, _city_key(hc), _city_key(city), hs.duplicate(true)],
				func(): return with_heights(spline_points(hc, city, hs), rtype, geo))}
		out.routes.append(r)
		routes[rid] = r
		changed_routes.append(rid)
		var st: Array = []
		for k in [1, 2]:
			var s := {"id": "%s_%02d" % [rid, k], "type": rtype, "x": 0.0, "y": 0.0, "z": 0.0, "coin_matched": false}
			out.stops.append(s)
			st.append(s)
		_place_stops(st, r, rt.get("stop_t", [1.0 / 3.0, 2.0 / 3.0]), geo)
		edges_extra.append({"a": host, "b": rid + "_01", "corridor_id": rid})
		edges_extra.append({"a": rid + "_01", "b": rid + "_02", "corridor_id": rid})
		edges_extra.append({"a": rid + "_02", "b": id, "corridor_id": rid})
	out["edges_extra"] = edges_extra
	if has_landscape:
		# 没有改横向路线也要跟着平整后的地面，否则路和停靠点会浮空。
		for r: Dictionary in out.routes:
			if String(r.type) != "LAND":
				continue
			for q: Array in r.points:
				if geo.has_height_edit(float(q[0]), float(q[2])):
					q[1] = snappedf(geo.route_y(float(q[0]), float(q[2]), "LAND"), 0.0001)
		for st: Dictionary in out.stops:
			if String(st.type) == "LAND" and geo.has_height_edit(float(st.x), float(st.z)):
				st.y = geo.stop_y(float(st.x), float(st.z), "LAND")
		CustomMapLandscape.decorate(out, landscape, geo, overlay.has("plants"))
	# 7. 清装饰（只针对新的、改过的几何）。改过的路的格子索引与几何规则共用（CustomMapGeoRules._route_geo，按点列缓存）
	var hot_cities: Array = []           # [Vector2 城心, foot]
	for cid in moved:
		hot_cities.append([Vector2(float(cities[cid].x), float(cities[cid].z)), float(cities[cid].foot)])
	for id in new_ids:
		hot_cities.append([Vector2(float(cities[id].x), float(cities[id].z)), float(cities[id].foot)])
	var land_geos: Array = []
	var all_geos: Array = []
	for rid in changed_routes:
		var r: Dictionary = routes[rid]
		var g: Object = CustomMapGeoRules._route_geo(r)
		all_geos.append(g)
		if String(r.type) == "LAND":
			land_geos.append(g)
	out["decor_cleared"] = {
		"tree_kit": _cleared_rows(base_layout.get("tree_kit", []), land_geos, hot_cities, false),
		"props": _cleared_rows(base_layout.get("props", []), land_geos, hot_cities, false),
		"kit": _cleared_rows(base_layout.get("kit", []), land_geos, hot_cities, true),
	}
	if out.has("life") and out.life is Dictionary:
		for key in ["camps", "flocks", "dust", "mist"]:
			var keep: Array = []
			for e: Dictionary in (out.life as Dictionary).get(key, []):
				var p := Vector2(float(e.x), float(e.z))
				if _near_city(p, hot_cities, 1.0, 0.0) or _near_routes(all_geos, p, LIFE_ROUTE_CLEAR):
					continue
				keep.append(e)
			if (out.life as Dictionary).has(key):
				out.life[key] = keep
	# 8. 铺地
	var paving: Array = []
	for cid in _sorted_keys(moved):
		var b0: Dictionary = base_cities[cid]
		paving.append({"op": "move", "id": cid, "from": [float(b0.x), float(b0.z)], "to": [float(cities[cid].x), float(cities[cid].z)],
			"limit": _pave_limit(base_layout, cid)})
	if base_cities.has(TEMPLATE_CITY):
		var t: Dictionary = base_cities[TEMPLATE_CITY]
		for id in new_ids:
			paving.append({"op": "stamp", "id": id, "src": [float(t.x), float(t.z)], "src_limit": _pave_limit(base_layout, TEMPLATE_CITY),
				"to": [float(cities[id].x), float(cities[id].z)], "scale": float(cities[id].foot) / float(t.foot)})
	out["paving"] = paving
	# 9. 名牌
	out["plaque_shift"] = plaque_shift
	if overlay.has("plants"):
		var plant_error := CustomMapPlants.decorate(out, overlay, geo)
		if plant_error != "": return {"error": plant_error}
	# 10. 标记（调用方给了才写，见函数头）
	if sha != "":
		out["custom_map_sha"] = sha
	for c: Dictionary in out.cities:
		var display := CustomMapCityBadges.config(overlay, str(c.id))
		c["city_badge"] = display.duplicate(true)
		if display.has("name"): c["name"] = display.name
		c["badge_asset"] = CustomMapLocalAssets.bound_id(overlay, str(c.id).trim_prefix("x_"), "badge_icon")
	return out


## 按 content 里的自制地图推导（棋盘重建世界时用）：原布局现读，覆盖层取 content.custom_map.overlay（3.5）。
## 覆盖层坏了（按说到不了这里：合并前校验器已经用同一个 derive + check 拦下）时返回 {"error": …}，由棋盘退回原布局
static func derive_for_content(content: Dictionary) -> Dictionary:
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	var cm: Dictionary = content.get("custom_map", {}) if content.get("custom_map", {}) is Dictionary else {}
	var overlay: Dictionary = cm.get("overlay", {}) if cm.get("overlay", {}) is Dictionary else {}
	return derive(base, overlay, CustomMapGeo.shared(), catalogue(), String(cm.get("sha256", "")))


# ---------------------------------------------------------------- 覆盖层的数据格式

## 覆盖层的结构检查（只查类型和 id，几何合不合格由 CustomMapGeoRules 管）：没问题返回 ""，否则返回一句说明。
## 允许的形状见 DESIGN 3.2：moves.cities.<原城 id> = {x, z, rotation}；moves.routes.<原商道 id> = {handles: 0–12 个 [x, z],
## stop_t: 两个比例}；new_cities[] = {slot, host: 原城 id, route_type: LAND / SEA, x, z, rotation, size, route: {handles, stop_t}, …}
static func overlay_error(overlay: Dictionary, base_layout: Dictionary) -> String:
	if CustomMapFreeAuthor.enabled(overlay):return CustomMapFreeAuthor.format_error(overlay,CustomMapLoader.base_content())
	if overlay.has("plants"):
		if str(overlay.get("schema", "")) not in [CustomMapPlants.SCHEMA, CustomMapLocalAssets.SCHEMA, CustomMapCityIntro.SCHEMA, CustomMapPieceSkins.SCHEMA, CustomMapFreeRoutes.SCHEMA]: return "植物编辑需要 v2"
		var plant_error := CustomMapPlants.error(overlay.plants)
		if plant_error != "": return plant_error
	if overlay.has("landscape"):
		var bad := CustomMapLandscape.error(overlay.landscape)
		if bad != "":
			return bad
	var base_cities := {}
	for c in base_layout.get("cities", []):
		if c is Dictionary:
			base_cities[String(c.get("id", ""))] = true
	var base_routes := {}
	for r in base_layout.get("routes", []):
		if r is Dictionary:
			base_routes[String(r.get("id", ""))] = true
	var moves: Variant = overlay.get("moves", {})
	if not moves is Dictionary:
		return "moves 不是字典"
	var mc: Variant = (moves as Dictionary).get("cities", {})
	var mr: Variant = (moves as Dictionary).get("routes", {})
	if not mc is Dictionary:
		return "moves.cities 不是字典"
	if not mr is Dictionary:
		return "moves.routes 不是字典"
	for cid in mc:
		if not base_cities.has(String(cid)):
			return "moves.cities 里有不认识的城 %s" % str(cid)
		var m: Variant = mc[cid]
		if not m is Dictionary:
			return "moves.cities.%s 不是字典" % str(cid)
		for k in ["x", "z", "rotation"]:
			if (m as Dictionary).has(k) and not _is_num(m[k]):
				return "moves.cities.%s.%s 不是数" % [str(cid), k]
	for rid in mr:
		if not base_routes.has(String(rid)):
			return "moves.routes 里有不认识的商道 %s" % str(rid)
		var e := _route_edit_error(mr[rid])
		if e != "":
			return "moves.routes.%s：%s" % [str(rid), e]
	var newc: Variant = overlay.get("new_cities", [])
	if not newc is Array:
		return "new_cities 不是数组"
	var slots := {}
	for i in (newc as Array).size():
		var nc: Variant = newc[i]
		if not nc is Dictionary:
			return "new_cities[%d] 不是字典" % i
		var slot: Variant = (nc as Dictionary).get("slot", "")
		if not slot is String or String(slot) == "":
			return "new_cities[%d].slot 不对" % i
		if slots.has(slot):
			return "new_cities 里槽位 %s 重复" % slot
		slots[slot] = true
		var host: Variant = (nc as Dictionary).get("host", "")
		if not host is String or not base_cities.has(String(host)):
			return "new_cities[%d].host 不是原城：%s" % [i, str(host)]
		var rt: Variant = (nc as Dictionary).get("route_type", "")
		if not rt is String or not (String(rt) in ["LAND", "SEA"]):
			return "new_cities[%d].route_type 不对：%s" % [i, str(rt)]
		for k in ["x", "z"]:
			if not _is_num((nc as Dictionary).get(k)):
				return "new_cities[%d].%s 不是数" % [i, k]
		for k in ["rotation", "size"]:
			if (nc as Dictionary).has(k) and not _is_num(nc[k]):
				return "new_cities[%d].%s 不是数" % [i, k]
		for k in ["archetype", "name"]:
			if (nc as Dictionary).has(k) and not nc[k] is String:
				return "new_cities[%d].%s 不是字符串" % [i, k]
		if (nc as Dictionary).has("route"):
			var e := _route_edit_error(nc.route)
			if e != "":
				return "new_cities[%d].route：%s" % [i, e]
	return ""


## 一段路形编辑 {handles: 0–12 个 [x, z], stop_t: 两个比例}
static func _route_edit_error(edit: Variant) -> String:
	if not edit is Dictionary:
		return "不是字典"
	var hs: Variant = (edit as Dictionary).get("handles", [])
	if not hs is Array:
		return "handles 不是数组"
	if (hs as Array).size() > 12:
		return "handles 超过 12 个"
	for h in hs:
		if not h is Array or (h as Array).size() != 2 or not _is_num(h[0]) or not _is_num(h[1]):
			return "handles 里有不是 [x, z] 的点"
	if (edit as Dictionary).has("stop_t"):
		var st: Variant = edit.stop_t
		if not st is Array or (st as Array).size() != 2 or not _is_num(st[0]) or not _is_num(st[1]):
			return "stop_t 要两个比例"
	return ""


static func _is_num(v: Variant) -> bool:
	return (v is float and is_finite(v)) or v is int


## 素材目录（测试可用 test_catalogue 顶替）
static func catalogue() -> Dictionary:
	if not test_catalogue.is_empty():
		return test_catalogue
	if not FileAccess.file_exists(CATALOGUE):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOGUE))
	return parsed if parsed is Dictionary else {}


## 目录里的一个原型：{model, bounds, foot, ...}；找不到时 {}
static func archetype(cat: Dictionary, id: String) -> Dictionary:
	var list: Variant = cat.get("archetypes", [])
	if list is Dictionary:
		return (list as Dictionary).get(id, {})
	for a in list:
		if a is Dictionary and String(a.get("id", "")) == id:
			return a
	return {}


## 原版 19 条商道的两端 {商道 id: [a, b]}（map_corridors_v1.json；a 在点列起点那一头）
static func corridor_ends() -> Dictionary:
	if _corridor_ends.is_empty():
		var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CORRIDORS))
		for c: Dictionary in doc.get("corridors", []):
			_corridor_ends[String(c.id)] = [String(c.a), String(c.b)]
	return _corridor_ends


# ---------------------------------------------------------------- 路线几何

## 有控制点的路：端点 = 城心 + 朝第一个（最后一个）控制点的方向 × foot/2；端点和控制点一起走向心 Catmull-Rom（α = 0.5），
## 再每 RESAMPLE 等距重采样。没有控制点时是两城之间的直线。
static func spline_points(ca: Dictionary, cb: Dictionary, handles: Array) -> PackedVector2Array:
	var pa := Vector2(float(ca.x), float(ca.z))
	var pb := Vector2(float(cb.x), float(cb.z))
	var hs := PackedVector2Array()
	for h in handles:
		hs.append(Vector2(float(h[0]), float(h[1])))
	var first := hs[0] if not hs.is_empty() else pb
	var last := hs[hs.size() - 1] if not hs.is_empty() else pa
	var e0 := pa + (first - pa).normalized() * float(ca.get("foot", DEFAULT_FOOT)) * 0.5
	var e1 := pb + (last - pb).normalized() * float(cb.get("foot", DEFAULT_FOOT)) * 0.5
	var ctrl := PackedVector2Array([e0])
	ctrl.append_array(hs)
	ctrl.append(e1)
	return resample(catmull_rom(ctrl), RESAMPLE)


## 向心 Catmull-Rom（α = 0.5），两头各补一个镜像点，每段按长度细分
static func catmull_rom(ctrl: PackedVector2Array) -> PackedVector2Array:
	var n := ctrl.size()
	if n < 2:
		return ctrl
	var p := PackedVector2Array([ctrl[0] * 2.0 - ctrl[1]])
	p.append_array(ctrl)
	p.append(ctrl[n - 1] * 2.0 - ctrl[n - 2])
	var out := PackedVector2Array([ctrl[0]])
	for i in range(1, p.size() - 2):
		var p0 := p[i - 1]
		var p1 := p[i]
		var p2 := p[i + 1]
		var p3 := p[i + 2]
		var t0 := 0.0
		var t1 := t0 + sqrt(maxf(p0.distance_to(p1), 1e-6))
		var t2 := t1 + sqrt(maxf(p1.distance_to(p2), 1e-6))
		var t3 := t2 + sqrt(maxf(p2.distance_to(p3), 1e-6))
		var steps := maxi(4, int(ceil(p1.distance_to(p2) / (RESAMPLE * 0.5))))
		for k in range(1, steps + 1):
			var t := lerpf(t1, t2, float(k) / float(steps))
			var a1 := p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
			var a2 := p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
			var a3 := p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
			var b1 := a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
			var b2 := a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
			out.append(b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1)))
	return out


## 按弧长每 step 取一个点（首尾都保留）
static func resample(pts: PackedVector2Array, step: float) -> PackedVector2Array:
	if pts.size() < 2:
		return pts
	var cum := PackedFloat32Array([0.0])
	for i in range(1, pts.size()):
		cum.append(cum[i - 1] + pts[i - 1].distance_to(pts[i]))
	var total := cum[cum.size() - 1]
	var out := PackedVector2Array()
	var n := maxi(1, int(round(total / step)))
	var j := 0
	for k in n + 1:
		var s := total * float(k) / float(n)
		while j < cum.size() - 2 and cum[j + 1] < s:
			j += 1
		var seg := maxf(cum[j + 1] - cum[j], 1e-9)
		out.append(pts[j].lerp(pts[j + 1], clampf((s - cum[j]) / seg, 0.0, 1.0)))
	return out


## 橡皮筋：p'(s) = p(s) + Δ·w(s)，w 在被挪的那一端是 1，在 RUBBER·L 以内平滑降到 0；两端都挪了就叠加
static func rubber_band(points: Array, da: Vector2, db: Vector2) -> PackedVector2Array:
	var pts := _xz_of(points)
	var cum := PackedFloat32Array([0.0])
	for i in range(1, pts.size()):
		cum.append(cum[i - 1] + pts[i - 1].distance_to(pts[i]))
	var L := maxf(cum[cum.size() - 1], 1e-6)
	var out := PackedVector2Array()
	for i in pts.size():
		var wa := 1.0 - smoothstep(0.0, RUBBER * L, cum[i])
		var wb := 1.0 - smoothstep(0.0, RUBBER * L, L - cum[i])
		out.append(pts[i] + da * wa + db * wb)
	return resample(out, RESAMPLE)


## xz 点列 → 布局里的 [x, y, z]（3 位以上小数照原布局保留 4 位）
static func with_heights(pts: PackedVector2Array, route_type: String, geo: CustomMapGeo) -> Array:
	var out: Array = []
	for q in pts:
		out.append([snappedf(q.x, 0.0001), snappedf(geo.route_y(q.x, q.y, route_type), 0.0001), snappedf(q.y, 0.0001)])
	return out


## 停靠点放在 stop_t 两个比例处（默认 1/3、2/3），y 取硬币那一格的地面（CustomMapGeo.stop_y）
static func _place_stops(stops: Array, r: Dictionary, stop_t: Array, geo: CustomMapGeo) -> void:
	var pts := _xz_of(r.points)
	var cum := PackedFloat32Array([0.0])
	for i in range(1, pts.size()):
		cum.append(cum[i - 1] + pts[i - 1].distance_to(pts[i]))
	var L := cum[cum.size() - 1]
	var ordered := stops.duplicate()
	ordered.sort_custom(func(p, q): return String(p.id) < String(q.id))
	for k in ordered.size():
		var t := float(stop_t[mini(k, stop_t.size() - 1)]) if not stop_t.is_empty() else (k + 1) / 3.0
		var p := point_at(pts, cum, t * L)
		var s: Dictionary = ordered[k]
		s["x"] = snappedf(p.x, 0.0001)
		s["y"] = snappedf(geo.stop_y(p.x, p.y, String(r.type)), 0.0001)
		s["z"] = snappedf(p.y, 0.0001)


static func point_at(pts: PackedVector2Array, cum: PackedFloat32Array, s: float) -> Vector2:
	s = clampf(s, 0.0, cum[cum.size() - 1])
	var i := clampi(cum.bsearch(s) - 1, 0, cum.size() - 2)
	var seg := maxf(cum[i + 1] - cum[i], 1e-9)
	return pts[i].lerp(pts[i + 1], clampf((s - cum[i]) / seg, 0.0, 1.0))


static func _xz_of(points: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in points:
		out.append(Vector2(float(q[0]), float(q[2])))
	return out


# ---------------------------------------------------------------- 清装饰、铺地

## 被新几何压到的行（原布局下标，升序）。forest=true 时只看 forest_* 的森林，按 s 放大半径；山体一律不删
static func _cleared_rows(rows: Array, land_geos: Array, hot_cities: Array, forest: bool) -> Array:
	var out: Array = []
	for i in rows.size():
		var r: Dictionary = rows[i]
		var p := Vector2(float(r.x), float(r.z))
		var s := float(r.get("s", 0.0))
		if forest:
			if not String(r.get("asset", "")).begins_with("forest"):
				continue
			if _near_routes(land_geos, p, s * 0.9 + 0.4) or _near_city(p, hot_cities, TREE_CITY_CLEAR, s * 0.9):
				out.append(i)
		elif _near_routes(land_geos, p, TREE_ROUTE_CLEAR) or _near_city(p, hot_cities, TREE_CITY_CLEAR, 0.0):
			out.append(i)
	return out


static func _near_city(p: Vector2, hot_cities: Array, k: float, extra: float) -> bool:
	for hc: Array in hot_cities:
		if p.distance_to(hc[0]) < float(hc[1]) * k + extra:
			return true
	return false


## 量石板半径时只在这一圈里找：不超过 foot/2 + 1.6（路口那截石板），也不超过到最近邻城的一半
static func _pave_limit(base_layout: Dictionary, cid: String) -> float:
	var me: Dictionary = {}
	for c: Dictionary in base_layout.cities:
		if String(c.id) == cid:
			me = c
	var lim := float(me.get("foot", DEFAULT_FOOT)) * 0.5 + 1.6
	for c: Dictionary in base_layout.cities:
		if String(c.id) != cid:
			lim = minf(lim, Vector2(float(c.x) - float(me.x), float(c.z) - float(me.z)).length() * 0.5)
	return lim


static func _sorted_keys(d: Dictionary) -> Array:
	var k := d.keys()
	k.sort()
	return k


## p 离这些路（CustomMapGeoRules.RouteGeo：1 u 格子里的线段）是否在 r 以内；离所有路的包围盒都远的点一步排除
static func _near_routes(geos: Array, p: Vector2, r: float) -> bool:
	for g in geos:
		if not (g.bbox as Rect2).grow(r).has_point(p):
			continue
		var pts: PackedVector2Array = g.pts
		var cells: Dictionary = g.cells
		for cx in range(int(floor(p.x - r)), int(floor(p.x + r)) + 1):
			for cz in range(int(floor(p.y - r)), int(floor(p.y + r)) + 1):
				for si in cells.get(Vector2i(cx, cz), []):
					if Geometry2D.get_closest_point_to_segment(p, pts[si], pts[si + 1]).distance_to(p) < r:
						return true
	return false


## 推导出来的点列按输入记下（键是这条路的全部输入：类型、两端的城、控制点，或原点列和两端的位移）：工坊拖动时每帧都推导，
## 没动的路直接取上次的结果。每次都复制一份交出去，调用方改了也不会弄脏缓存；结果与现算逐字节相同
static var _points_cache := {}


static func _memo_points(key: Array, make: Callable) -> Array:
	var hit: Variant = _points_cache.get(key)
	if hit == null:
		hit = make.call()
		if _points_cache.size() > 96:
			_points_cache.clear()
		_points_cache[key] = hit
	return (hit as Array).duplicate(true)


static func _city_key(c: Dictionary) -> Array:
	return [float(c.x), float(c.z), float(c.get("foot", DEFAULT_FOOT))]
