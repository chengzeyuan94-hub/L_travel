class_name CustomMapSchema

## 自制地图文件 lshu.custom_map.v1：常量、规范化文本、指纹、拓扑键、槽位规范化、升级链
## （docs/design/map-editor-20260930/DESIGN.md 3.2–3.4）。归 WP1。
##
## 规范化文本自己拼，不用 JSON.stringify：Godot 4.7 的 JSON.parse_string 会把 3 读成 3.0，直接 stringify 的话
## 工坊和游戏两边算出的哈希对不上（3.3）。键按字典序；数字一律 "%.3f"；整数字段（写死在 INT_FIELDS）按整数；
## 字符串按 JSON 规则转义；去掉顶层 workshop。sha256 = SHA-256(规范化文本)。

const SCHEMA := "lshu.custom_map.v1"
const INSTALL_SCHEMA := "lshu.custom_map_install.v1"
const OPTION_ID := "lshu_custom_map"

## 本程序认识的最新文件版本号、目录版本、生成器版本（比它们新就拒：E_TOO_NEW）
const SCHEMA_PREFIX := "lshu.custom_map.v"
const SCHEMA_VERSION := 6
const SUPPORTED_SCHEMAS := [SCHEMA, "lshu.custom_map.v2", "lshu.custom_map.v3", "lshu.custom_map.v4", "lshu.custom_map.v5", "lshu.custom_map.v6"]
const CATALOGUE_VERSION := 1
const TRADEGEN := "tradegen_v2_original_1"
const KNOWN_TRADEGENS: Array[String] = ["tradegen_v1", "tradegen_v1_hardened_1", "tradegen_v2_original_1", "tradegen_v2_free_routes_1", "tradegen_v2_free_author_1"]
const RULESET_ID := "lshu_configurable_v1"
const EDITION_ID := "user_confirmed_v1"
const BASE_LAYOUT_PATH := "res://assets/merchant_board_claude/board_layout.json"
## 文件大小上限（3.2）
const MAX_FILE_BYTES := 512 * 1024

## 槽位（3.4）：一对里西侧是 w、东侧是 e；两对时按西侧宿主 id 排序，第一对 w1/e1，第二对 w2/e2
const SLOTS: Array[String] = ["w1", "e1", "w2", "e2"]
## 新城的城市卡号（只在卡面上显示，R7）
const CARD_NUMBERS := {"w1": 17, "e1": 18, "w2": 19, "e2": 20}
## 规范化文本里按整数输出的字段（其余数字一律 "%.3f"）
const INT_FIELDS: Array[String] = ["card_number", "quantity", "catalogue_version"]
const TOPOLOGY_PREFIX := "topo_v1"

static var _graph_sig_cache := ""
static var _layout_sha_cache := ""


# ---------------------------------------------------------------- 规范化文本与指纹

## 规范化文本（3.3）
static func canonical_text(doc: Dictionary) -> String:
	var top := doc.duplicate(false)
	top.erase("workshop")
	return _canon(top, "")


## SHA-256(规范化文本)：installed.json 外壳校验、出发页判断新导入、3D 世界签名
static func sha256(doc: Dictionary) -> String:
	return canonical_text(doc).sha256_text()


static func _canon(v: Variant, key: String) -> String:
	match typeof(v):
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var keys: Array = d.keys()
			var names: Array[String] = []
			for k in keys:
				names.append(String(k))
			names.sort()
			var parts: PackedStringArray = []
			for k in names:
				parts.append("%s:%s" % [JSON.stringify(k), _canon(d[k], k)])
			return "{" + ",".join(parts) + "}"
		TYPE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY:
			var parts: PackedStringArray = []
			for item in v:
				parts.append(_canon(item, key))
			return "[" + ",".join(parts) + "]"
		TYPE_INT, TYPE_FLOAT:
			if key in INT_FIELDS:
				return str(int(v))
			return _num(float(v))
		TYPE_BOOL:
			return "true" if bool(v) else "false"
		TYPE_NIL:
			return "null"
		TYPE_STRING, TYPE_STRING_NAME:
			return JSON.stringify(String(v))
		TYPE_VECTOR2:
			var p: Vector2 = v
			return "[%s,%s]" % [_num(p.x), _num(p.y)]
		_:
			return JSON.stringify(str(v))


## 数字统一三位小数；-0.000 记成 0.000（两边取整方向不同时也不差一个负号）
static func _num(x: float) -> String:
	var s := "%.3f" % x
	return "0.000" if s == "-0.000" else s


## 所有坐标四舍五入到 0.001（工坊保存前调用）。只动 moves、new_cities 里的小数；整数字段不动
static func round_coords(doc: Dictionary) -> Dictionary:
	var out := doc.duplicate(true)
	if out.get("city_badges") is Dictionary:
		out["city_badges"] = _round_tree(out["city_badges"], "")
	if out.get("moves") is Dictionary:
		out["moves"] = _round_tree(out["moves"], "")
	if out.get("landscape") is Dictionary:
		out["landscape"] = _round_tree(out["landscape"], "")
	if out.get("new_cities") is Array:
		out["new_cities"] = _round_tree(out["new_cities"], "")
	if out.get("free_routes") is Dictionary:out.free_routes=_round_tree(out.free_routes, "")
	return out


static func _round_tree(v: Variant, key: String) -> Variant:
	if v is Dictionary:
		var d: Dictionary = v
		for k in d.keys():
			d[k] = _round_tree(d[k], String(k))
		return d
	if v is Array:
		var a: Array = v
		for i in a.size():
			a[i] = _round_tree(a[i], key)
		return a
	if v is float and not (key in INT_FIELDS):
		return roundf(float(v) * 1000.0) / 1000.0
	return v


# ---------------------------------------------------------------- 拓扑键与槽位

## 拓扑键（3.3）：topo_v1|<槽位>:<宿主>:<路线类型>:<搭档槽位>…，按槽位排序；没有新城时为 ""
static func topology_key(doc: Dictionary) -> String:
	if CustomMapFreeRoutes.enabled(doc):return CustomMapFreeRoutes.key(doc)
	var cities: Array = doc.get("new_cities", []) if doc.get("new_cities") is Array else []
	if cities.is_empty():
		return ""
	var parts: Array[String] = []
	for c in cities:
		if not c is Dictionary:
			continue
		parts.append("%s:%s:%s:%s" % [str(c.get("slot", "")), str(c.get("host", "")), str(c.get("route_type", "")), str(c.get("partner", ""))])
	for c: Dictionary in cities:
		for link: Dictionary in c.get("extra_connections", []):
			parts.append("extra:%s:%s:%s" % [c.slot, link.host, link.route_type])
	if CustomMapRules.has_cairo_land_extension(doc): parts.append("interchange:cairo:LAND")
	parts.sort()
	return TOPOLOGY_PREFIX + "|" + "|".join(parts)


## 槽位规范化（3.4）：按 partner 互指配成对，每对里宿主在西侧的叫 w、东侧的叫 e；两对按西侧宿主 id 排序。
## 配不成对（数量为奇数、互指断了、一对两座都在同一侧）时原样返回副本，由校验器报 E_SIDE。
## 同一种接法不论先加哪座，保存后槽位都一样；生成器的牌堆 id 参与稳定哈希，槽位装反牌堆就全变了（3.14.5）。
static func canonicalize_slots(doc: Dictionary, base: Dictionary) -> Dictionary:
	if CustomMapFreeAuthor.enabled(doc):return doc.duplicate(true)
	var out := doc.duplicate(true)
	detach_reassigned_free_routes(out, base)
	var cities: Array = out.get("new_cities", []) if out.get("new_cities") is Array else []
	if cities.is_empty():
		_remap_city_layers(out, {}, base)
		return out
	var by_slot := {}
	for c in cities:
		if not c is Dictionary:
			return out
		var slot := str(c.get("slot", ""))
		if slot == "" or by_slot.has(slot):
			return out
		by_slot[slot] = c
	var pairs: Array = []   # [[西侧城, 东侧城]]
	var seen := {}
	for c in cities:
		var slot := str(c.get("slot", ""))
		if seen.has(slot):
			continue
		var partner_slot := str(c.get("partner", ""))
		if not by_slot.has(partner_slot) or partner_slot == slot:
			return out
		var p: Dictionary = by_slot[partner_slot]
		if str(p.get("partner", "")) != slot:
			return out
		var side_c := _side_of(base, str(c.get("host", "")))
		var side_p := _side_of(base, str(p.get("host", "")))
		if side_c == side_p or side_c == "" or side_p == "":
			return out
		pairs.append([c, p] if side_c == "W" else [p, c])
		seen[slot] = true
		seen[partner_slot] = true
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return str(a[0].get("host", "")) < str(b[0].get("host", "")))
	var ordered: Array = []
	var slot_map: Dictionary = {}
	for i in pairs.size():
		var w: Dictionary = pairs[i][0]
		var e: Dictionary = pairs[i][1]
		slot_map[str(w.slot)] = "w%d" % (i + 1)
		slot_map[str(e.slot)] = "e%d" % (i + 1)
		w["slot"] = "w%d" % (i + 1)
		e["slot"] = "e%d" % (i + 1)
		w["partner"] = e["slot"]
		e["partner"] = w["slot"]
		ordered.append(w)
		ordered.append(e)
	out["new_cities"] = ordered
	_remap_city_layers(out, slot_map, base)
	return out


## A city-owned route can be reassigned to two other cities. Give that live
## road its own stable identity before deleting/re-numbering its former owner.
static func detach_reassigned_free_routes(doc: Dictionary, base: Dictionary) -> void:
	if not doc.get("free_routes") is Dictionary or not doc.free_routes.get("routes") is Dictionary:
		return
	var definitions := CustomMapFreeRoutes.specs(base, doc)
	var patches: Dictionary = doc.free_routes.routes
	for rid: String in patches.keys():
		var owner := ""
		for slot: String in SLOTS:
			if rid.ends_with("_x_" + slot): owner = city_id(slot)
		if owner == "" or not definitions.has(rid): continue
		var route: Dictionary = definitions[rid]
		# A stale partial patch after removal has no inherited definition;
		# leave it to the endpoint/slot cleanup rather than inventing a road.
		if not route.has("a") or not route.has("b") or not route.has("type"): continue
		if owner in [str(route.get("a", "")), str(route.get("b", ""))]: continue
		var independent_id := "free_retained_" + rid.sha256_text().left(24)
		var suffix := 2
		var unique_id := independent_id
		while patches.has(unique_id):
			unique_id = independent_id + "_%d" % suffix; suffix += 1
		var stops: Array = route.get("stop_t", []).duplicate(true)
		if not route.has("stop_t"):
			for index: int in route.get("stop_ids", []).size():
				stops.append(float(index + 1) / float(route.stop_ids.size() + 1))
		patches[unique_id] = {"a": route.a, "b": route.b, "type": route.type, "handles": route.get("handles", []).duplicate(true), "stop_t": stops}
		# If the former owner survives, its inherited road stays explicitly
		# deleted rather than being silently restored alongside the new road.
		patches[rid] = {"deleted": true}


## Stable city identity across slot re-numbering; removed new cities lose their overlays.
static func _remap_city_layers(doc: Dictionary, slot_map: Dictionary, base: Dictionary) -> void:
	if doc.get("free_routes") is Dictionary and doc.free_routes.get("routes") is Dictionary:
		var inherited_routes: Dictionary = {}
		for edge: Dictionary in base.get("board_edges", []):
			inherited_routes[str(edge.get("corridor_id", ""))] = true
		for city: Dictionary in doc.get("new_cities", []):
			if CustomMapFreeAuthor.enabled(doc):continue
			inherited_routes[corridor_id(str(city.slot), str(city.host), str(city.route_type))] = true
			for link: Dictionary in city.get("extra_connections", []):
				inherited_routes[corridor_id(str(city.slot), str(link.host), str(link.route_type))] = true
		var routes:Dictionary={}
		for rid:String in doc.free_routes.routes:
			var p:Dictionary=doc.free_routes.routes[rid].duplicate(true);var target:=rid
			var keep:=true;var removed_endpoint:=false
			for slot:String in CustomMapSchema.SLOTS:
				if rid.ends_with("_x_"+slot):
					if slot_map.has(slot):target=rid.trim_suffix(slot)+str(slot_map[slot])
					else:keep=false
			for endpoint:String in ["a","b"]:
				if str(p.get(endpoint,"")).begins_with("x_"):
					var slot:=str(p[endpoint]).trim_prefix("x_")
					if slot_map.has(slot):p[endpoint]="x_"+str(slot_map[slot])
					else:removed_endpoint=true
			if not keep:continue
			if removed_endpoint:
				# Dropping an inherited route's override would silently restore
				# its previous endpoint. Keep a tombstone until explicit restore.
				if inherited_routes.has(target):routes[target]={"deleted":true}
			else:routes[target]=p
		doc.free_routes.routes=routes
	if doc.get("city_badges") is Dictionary:
		var badges := {}
		for cid in doc.city_badges:
			if str(cid).begins_with("x_"):
				var slot := str(cid).trim_prefix("x_")
				if slot_map.has(slot): badges[city_id(slot_map[slot])] = doc.city_badges[cid]
			else: badges[cid] = doc.city_badges[cid]
		doc.city_badges = badges
	if doc.get("city_intro_cards") is Dictionary and doc.city_intro_cards.get("cards") is Dictionary:
		var cards: Dictionary = {}
		for cid in doc.city_intro_cards.cards:
			if str(cid).begins_with("x_"):
				var old_slot: String = str(cid).trim_prefix("x_")
				if slot_map.has(old_slot): cards[city_id(slot_map[old_slot])] = doc.city_intro_cards.cards[cid]
			else: cards[cid] = doc.city_intro_cards.cards[cid]
		doc.city_intro_cards.cards = cards
	if doc.get("assets") is Dictionary and doc.assets.get("bindings") is Dictionary:
		var bindings: Dictionary = {}
		for slot in doc.assets.bindings:
			if slot_map.has(slot): bindings[slot_map[slot]] = doc.assets.bindings[slot]
			elif base.get("cities", {}).has(slot): bindings[slot] = doc.assets.bindings[slot]
		doc.assets.bindings = bindings
		CustomMapLocalAssets.prune(doc)


## 宿主在哪一侧：正式规则集里 map_position.x < 2048 为西（R8；新城自己的位置不参与判定）
static func _side_of(base: Dictionary, host_id: String) -> String:
	var city: Variant = (base.get("cities", {}) as Dictionary).get(host_id)
	if not city is Dictionary:
		return ""
	var pos: Variant = (city as Dictionary).get("map_position")
	var x := 0.0
	if pos is Vector2:
		x = (pos as Vector2).x
	elif pos is Array and (pos as Array).size() >= 2:
		x = float(pos[0])
	else:
		return ""
	return "W" if x < 2048.0 else "E"


# ---------------------------------------------------------------- 新图、原图签名、升级

## 一张空地图（没有挪动、没有新城）；map_id 按当前时间起，只含 [a-z0-9_]
static func empty_doc(map_name: String) -> Dictionary:
	var now := Time.get_datetime_dict_from_system()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var map_id := "m_%04d%02d%02d_%02d%02d%02d_%04x" % [
		int(now.year), int(now.month), int(now.day), int(now.hour), int(now.minute), int(now.second), rng.randi_range(0, 0xffff)]
	var stamp := Time.get_datetime_string_from_system(false, false)
	return {
		"schema": SCHEMA,
		"map_id": map_id,
		"name": map_name,
		"base": base_block(),
		"catalogue_version": CATALOGUE_VERSION,
		"tradegen": TRADEGEN,
		"moves": {"cities": {}, "routes": {}},
		"new_cities": [],
		"generated": {"topology_key": "", "decks": []},
		"workshop": {"created_at": stamp, "updated_at": stamp, "app_version": String(ProjectSettings.get_setting("application/config/version", "")), "camera": {}},
	}


## 地图文件的 base 段：与当前游戏一致才收（E_BASE）
static func base_block() -> Dictionary:
	return {
		"ruleset_id": RULESET_ID,
		"edition_id": EDITION_ID,
		"graph_sig": graph_sig(),
		"layout_sha256": layout_sha256(),
	}


## 原图签名（3.3）：基础包 board_nodes 的 (id, node_type) 和 board_edges 的 (id, a, b, route_type) 排序后取 SHA-256
static func graph_sig(base: Dictionary = {}) -> String:
	var use_cache := base.is_empty()
	if use_cache and _graph_sig_cache != "":
		return _graph_sig_cache
	var content := base if not base.is_empty() else GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var lines: Array[String] = []
	for node in (content.get("board_nodes", {}) as Dictionary).values():
		lines.append("N|%s|%s" % [str(node.get("id", "")), str(node.get("node_type", ""))])
	for edge in content.get("board_edges", []):
		lines.append("E|%s|%s|%s|%s" % [str(edge.get("id", "")), str(edge.get("a", "")), str(edge.get("b", "")), str(edge.get("route_type", ""))])
	lines.sort()
	var sig := "\n".join(lines).sha256_text()
	if use_cache:
		_graph_sig_cache = sig
	return sig


## 原布局文件 board_layout.json 的 SHA-256（不一致不拒收，几何规则全部重跑，3.2）
static func layout_sha256() -> String:
	if _layout_sha_cache == "":
		_layout_sha_cache = FileAccess.get_sha256(BASE_LAYOUT_PATH)
	return _layout_sha_cache


## 升级链；v1：原样返回
static func upgrade(doc: Dictionary) -> Dictionary:
	return doc


## 文件 schema 的版本号："lshu.custom_map.v3" → 3；不是本家族的返回 0
static func schema_version_of(schema: String) -> int:
	if not schema.begins_with(SCHEMA_PREFIX):
		return 0
	var tail := schema.trim_prefix(SCHEMA_PREFIX)
	return int(tail) if tail.is_valid_int() else 0


# ---------------------------------------------------------------- id 规则（3.4）

static func city_id(slot: String) -> String:
	return "x_" + slot


static func corridor_id(slot: String, host: String, route_type: String) -> String:
	return "%s_%s_x_%s" % [route_type.to_lower(), host, slot]


static func deck_id(slot: String) -> String:
	return "deck_x_" + slot


static func good_id(slot: String, specialty_key: String) -> String:
	return "x_%s_%s" % [slot, specialty_key]


static func illustration_id(slot: String) -> String:
	return "x_ill_" + slot


## 边 id 与原版命名一致：edge_<路线类型小写>_<两端 id 排序后较小的>__<较大的>（tools/promote_formal_board.py:82-84）
static func edge_id(a: String, b: String, route_type: String) -> String:
	var lo := a if a < b else b
	var hi := b if a < b else a
	return "edge_%s_%s__%s" % [route_type.to_lower(), lo, hi]


## 双连扩展：每座新城至多额外接一座同交通原城，每条仍为三步商道。
static func corridor_entries(doc: Dictionary) -> Array:
	var result: Array = []
	for c: Dictionary in doc.get("new_cities", []):
		result.append(c)
		for connection: Dictionary in c.get("extra_connections", []):
			var extra := c.duplicate(true)
			extra.erase("extra_connections")
			extra.merge(connection, true)
			extra["_secondary"] = true
			result.append(extra)
	return result
