class_name TradeGenV1Legacy

## 贸易卡生成器 tradegen_v1（冻结；docs/design/map-editor-20260930/DESIGN.md 3.14）。归 WP2。
##
## 纯函数，不用任何随机数；平局一律用稳定哈希排序。参数在 data/custom_map/tradegen_v1_params.json（冻结，
## 由 tools/custom_map/ref/deck_gen_ref.py 从原版 80 张卡拟合写出，运行时不再拟合）。
## 本文件是 Python 参考实现 deck_gen_ref.py 的逐行移植：全部接法（一对 46 种、两对 721 种）的输出
## 与 tests/fixtures/custom_map/tradegen_ref/ 里的参考牌堆逐字节相同（tests/custom_map_tradegen_tests.gd T-G3a）。
## 为了两种语言逐字节相同，写法上有三条约定（DESIGN 3.14.5）：
##   1. 浮点只在冻结常数上做四则运算，运算顺序与 Python 一致；冻结浮点按 IEEE 位读（参数文件的 f64 段）；
##   2. 浮点排序键先按 1e-9 取整（_k9）；均值一律「从左到右求和再除」（_mean）；
##   3. 稳定哈希只喂字符串和整数：各部分转成字符串、用 \x1f 连接、取 sha1 前 12 位十六进制。
## GDScript 的 sort_custom 不稳定，所以每个排序键最后都补上原位置，等价于 Python 的稳定排序。
## 规则只看拓扑（R18）：新城 id = x_<槽位>，新货先用代号 x_<槽位>，最后才按 goods_map 换成真实 id。
## 出错时不重抽（第 14 步）：返回 ok = false 和错误说明，这张地图不能导入。

const VERSION := "tradegen_v1"
const PARAMS_PATH := "res://data/custom_map/tradegen_v1_params.json"
const LAND := "LAND"
const SEA := "SEA"
const WAREHOUSE := 4
const S_MIN := 2
const S_MAX := 5
const Q_MAX := 4
const UNIT_FLOOR := 2.0 / 3.0      # 原版 80 张卡里特产整批最低单价（S=2, q=3）
const SLOTS: Array[String] = ["e1", "e2", "w1", "w2"]
## 生成器真正读的参数键（params_from_doc 只看这些）；与 deck_gen_ref.py 的 GENERATOR_KEYS 逐项相同。
## 夹具和金样只绑定这些键（外加版本号 generator）的指纹 generator_params_sha256。
const GENERATOR_KEYS: Array[String] = ["price_coef", "appear", "max_count", "silk_slots", "silk_price_by_deck", "silk_price_global",
	"q_multiset", "q_pattern_by_s_rank", "s_templates", "unit_floor", "n_local_single", "forced_min", "rank_jitter",
	"no_silver_cards", "near_source_steps", "near_source_silver_cap", "loop_cap_one_way", "loop_cap_two_way", "loop_cap_eps",
	"loop_guard_max_iter", "turns_table"]

static var _params: Dictionary = {}
static var _product: Dictionary = {}


## topology: [{slot, host, route_type, partner}]；goods_map: {slot: 真实货物 id}
## 返回 {ok, decks: [{id, city_id, cards}], guard_log: [...], errors: [...]}（另带 cap_log：近源封顶改过的卡）
## 输入不合格（接法条目不是字典、字段不是字符串、goods_map 的值不是 x_<槽位>_<键> 或撞上基础货物……）一律 ok = false，
## 不会带着缺堆的结果返回 ok = true：ok 为真时，接法里的每个槽位恰好一堆。
static func generate(base_content: Dictionary, topology: Array, goods_map: Dictionary) -> Dictionary:
	var res := _generate_core(base_content, topology, params())
	if bool(res["ok"]):
		var gm_errors := _check_goods_map(base_content, topology, goods_map)
		if not gm_errors.is_empty():
			res["ok"] = false
			(res["errors"] as Array).append_array(gm_errors)
		elif not goods_map.is_empty():
			_apply_goods_map(res["decks"], goods_map)
	res.erase("_econ")
	res.erase("_dist")
	return res


## 单堆的硬不变量（R15）：返回违规说明，没有问题时为空。
## deck_gen.py:627-675 的检查，外加 R15 对新牌堆的补充项：恰好 1 项白银、本城特产只在第 2 格、
## 白银均值 ∈ [2.8, 4.0]、货种 ≥ 13、丝绸正好 4 格。local_goods 是本堆特产（空数组时不查单价和格位）。
static func validate_deck(deck: Dictionary, goods: Dictionary, existing_card_ids: Dictionary, local_goods: Array) -> Array[String]:
	return _validate(deck, goods, existing_card_ids, local_goods, true)


## 冻结参数（按 f64 段把每个浮点换成位级精确值）；读一次后缓存。只含生成器读的键（GENERATOR_KEYS），
## 产品旋钮见 product_params()。
static func params() -> Dictionary:
	if _params.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
		if not parsed is Dictionary:
			push_error("TradeGenV1: 读不到冻结参数 %s" % PARAMS_PATH)
			return {}
		_params = params_from_doc(parsed)
	return _params


## 产品旋钮（同一份参数文件，但不属于生成器，改它们不改变生成器输出，也不动夹具和金样的绑定）：
##   {max_pairs, max_user}：D1，工坊最多几对新城、玩家自己最多加几座；
##   bank_delta_per_city：R20 的银库 k，{"2": k, "3": k, "4": k}（按人数），默认 0，只在 S7 标定后改。
## WP1 直接读原始 JSON 的这几个键也可以（键名不变）；读不到文件时返回空字典。
static func product_params() -> Dictionary:
	if _product.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
		if not parsed is Dictionary:
			push_error("TradeGenV1: 读不到参数文件 %s" % PARAMS_PATH)
			return {}
		var bank := {}
		var raw_bank: Variant = (parsed as Dictionary).get("bank_delta_per_city", {})
		if raw_bank is Dictionary:
			for k in (raw_bank as Dictionary).keys():
				bank[String(k)] = int(raw_bank[k])
		_product = {"max_pairs": int(parsed.get("max_pairs", 1)), "max_user": int(parsed.get("max_user", 1)), "bank_delta_per_city": bank}
	return _product


## 夹具和金样绑定的参数指纹：只覆盖生成器读的键（GENERATOR_KEYS + generator），与 deck_gen_ref.py 同名函数逐字节相同。
## 数一律写成跨语言中立的形式：整数值写整数，非整数写 "f64:<IEEE 位>"（先经 apply_f64 取到位级精确值）。
static func generator_params_sha256(doc: Dictionary) -> String:
	var d := apply_f64(_generator_doc(doc))
	d.erase("f64")
	return canonical_text(_neutral_numbers(d)).sha256_text()


## 参数文档里只留生成器读的键（外加 generator），f64 段也只留这些键下面的路径。
static func _generator_doc(doc: Dictionary) -> Dictionary:
	var keep: Array[String] = ["generator"]
	keep.append_array(GENERATOR_KEYS)
	var out := {}
	for k in keep:
		if doc.has(k):
			out[k] = doc[k]
	var bits := {}
	var src: Variant = doc.get("f64", {})
	if src is Dictionary:
		for path in (src as Dictionary).keys():
			if keep.has(String(path).split("/")[0]):
				bits[path] = src[path]
	out["f64"] = bits
	return out


static func _neutral_numbers(v: Variant) -> Variant:
	match typeof(v):
		TYPE_INT:
			return v
		TYPE_FLOAT:
			var x := float(v)
			if x == floorf(x) and absf(x) < 9007199254740992.0:
				return int(x)
			var b := PackedByteArray()
			b.resize(8)
			b.encode_double(0, x)
			return "f64:" + b.hex_encode()
		TYPE_DICTIONARY:
			var out := {}
			for k in (v as Dictionary).keys():
				out[String(k)] = _neutral_numbers(v[k])
			return out
		TYPE_ARRAY:
			var arr: Array = []
			for x in v:
				arr.append(_neutral_numbers(x))
			return arr
	return v


## 把参数文档（readable 值 + f64 位）整理成生成器用的字典；留一回测的参数组也走这里。
## 生成器只看得见 GENERATOR_KEYS：产品旋钮怎么改都进不了生成器。
static func params_from_doc(doc: Dictionary) -> Dictionary:
	var d: Dictionary = apply_f64(_generator_doc(doc))
	var p := {}
	p["price_coef"] = [float(d["price_coef"][0]), float(d["price_coef"][1]), float(d["price_coef"][2])]
	var appear := {}
	for k in (d["appear"] as Dictionary).keys():
		appear[int(k)] = float(d["appear"][k])
	p["appear"] = appear
	var ks: Array = appear.keys()
	ks.sort()
	p["appear_keys"] = ks
	p["max_count"] = int(d["max_count"])
	p["silk_slots"] = int(d["silk_slots"])
	var silk := {}
	for k in (d["silk_price_by_deck"] as Dictionary).keys():
		silk[String(k)] = float(d["silk_price_by_deck"][k])
	p["silk_price_by_deck"] = silk
	p["silk_price_global"] = float(d["silk_price_global"])
	p["q_multiset"] = _ints(d["q_multiset"])
	p["q_pattern_by_s_rank"] = _ints(d["q_pattern_by_s_rank"])
	var templates: Array = []
	for t in d["s_templates"]:
		templates.append({"mean": float(t["mean"]), "values": _ints(t["values"]), "deck": String(t["deck"]), "no_silver": int(t["no_silver"])})
	p["s_templates"] = templates
	p["unit_floor"] = float(d["unit_floor"])
	p["n_local_single"] = int(d["n_local_single"])
	p["forced_min"] = int(d["forced_min"])
	p["rank_jitter"] = float(d["rank_jitter"])
	p["no_silver_cards"] = int(d["no_silver_cards"])
	p["near_source_steps"] = int(d.get("near_source_steps", 6))
	p["near_source_silver_cap"] = int(d.get("near_source_silver_cap", 3))
	p["loop_cap_one_way"] = float(d.get("loop_cap_one_way", 0.0))
	p["loop_cap_two_way"] = float(d.get("loop_cap_two_way", 0.0))
	p["loop_cap_eps"] = float(d.get("loop_cap_eps", 1e-9))
	p["loop_guard_max_iter"] = int(d.get("loop_guard_max_iter", 60))
	var tt: Array = []
	for x in d.get("turns_table", []):
		tt.append(float(x))
	p["turns_table"] = tt
	return p


## 按 f64 段（路径 → 小端 IEEE 位的十六进制）把文档里的浮点换成位级精确值；返回深拷贝。
static func apply_f64(doc: Dictionary) -> Dictionary:
	var out: Dictionary = doc.duplicate(true)
	var bits: Dictionary = out.get("f64", {})
	for path_value in bits.keys():
		var parts := String(path_value).split("/")
		var cur: Variant = out
		for i in parts.size() - 1:
			cur = cur[int(parts[i])] if cur is Array else cur[parts[i]]
		var val := String(bits[path_value]).hex_decode().decode_double(0)
		var last := parts[parts.size() - 1]
		if cur is Array:
			cur[int(last)] = val
		else:
			cur[last] = val
	return out


## 拓扑键 topo_v1|<槽位>:<宿主>:<路线类型>:<搭档槽位>，按槽位排序（DESIGN 3.3）；没有新城时为空。
static func topology_key(topology: Array) -> String:
	if topology.is_empty():
		return ""
	var parts: Array[String] = []
	for t in _sorted_topology(topology):
		parts.append("%s:%s:%s:%s" % [t["slot"], t["host"], t["route_type"], t["partner"]])
	return "topo_v1|" + "|".join(parts)


static func parse_topology_key(key: String) -> Array:
	var out: Array = []
	if key.is_empty():
		return out
	var parts := key.split("|")
	if parts[0] != "topo_v1":
		return out
	for i in range(1, parts.size()):
		var f := parts[i].split(":")
		if f.size() != 4:
			return []
		out.append({"slot": f[0], "host": f[1], "route_type": f[2], "partner": f[3]})
	return out


## 规范文本：键按字典序、无空白、整数按整数、字符串按 JSON 转义（不转义非 ASCII）。
## 与参考实现的 canon() 逐字节相同；夹具文件的内容就是它。浮点不允许出现。
static func canonical_text(v: Variant) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "true" if v else "false"
		TYPE_NIL:
			return "null"
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			push_error("TradeGenV1.canonical_text: 规范文本里不允许浮点 %s" % str(v))
			return str(v)
		TYPE_STRING, TYPE_STRING_NAME:
			return _json_string(String(v))
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_INT32_ARRAY:
			var items: Array[String] = []
			for x in v:
				items.append(canonical_text(x))
			return "[" + ",".join(items) + "]"
		TYPE_DICTIONARY:
			var keys: Array = []
			for k in (v as Dictionary).keys():
				keys.append(String(k))
			keys.sort()
			var items: Array[String] = []
			for k in keys:
				items.append(_json_string(k) + ":" + canonical_text(v[k] if (v as Dictionary).has(k) else v[StringName(k)]))
			return "{" + ",".join(items) + "}"
	push_error("TradeGenV1.canonical_text: 不支持的类型 %d" % typeof(v))
	return "null"


# ---------------------------------------------------------------------------
# 生成主流程（DESIGN 3.14.3）
# ---------------------------------------------------------------------------

static func _generate_core(base_content: Dictionary, topology: Array, p: Dictionary) -> Dictionary:
	var fail := func(msg: String) -> Dictionary:
		return {"ok": false, "decks": [], "guard_log": [], "cap_log": [], "errors": [msg]}
	if p.is_empty():
		return fail.call("读不到冻结参数")
	if base_content.has("custom_map"):
		return fail.call("base_content 必须是基础包（不能是合并过自制地图的内容）")
	# 接法条目逐条查类型：{slot, host, route_type, partner} 都是字符串（partner 可以为空）
	for i in topology.size():
		var entry: Variant = topology[i]
		if not entry is Dictionary:
			return fail.call("接法第 %d 项不是字典" % i)
		for field in ["slot", "host", "route_type", "partner"]:
			if not (entry as Dictionary).has(field) or not (entry[field] is String or entry[field] is StringName):
				return fail.call("接法第 %d 项的 %s 不是字符串" % [i, field])
		if String(entry["route_type"]) != LAND and String(entry["route_type"]) != SEA:
			return fail.call("接法第 %d 项的路线类型只能是 LAND 或 SEA：%s" % [i, entry["route_type"]])
	var topo := _sorted_topology(topology)
	var seen_slots := {}
	for t in topo:
		var slot := String(t.get("slot", ""))
		if not SLOTS.has(slot) or seen_slots.has(slot):
			return fail.call("槽位不对：%s" % slot)
		seen_slots[slot] = true
	for t in topo:
		var partner := String(t.get("partner", ""))
		if not partner.is_empty() and not seen_slots.has(partner):
			return fail.call("搭档槽位不存在：%s" % partner)
	# 第 1 步：棋盘（基础包 + 各新城的叶子），交通规则下的城市间最短步数
	var board := _board_from_content(base_content)
	var econ := _econ_from_content(base_content)
	var base_deck_ids: Array = []
	for dk in econ["decks"]:
		base_deck_ids.append(dk["id"])
	for t in topo:
		var host := String(t.get("host", ""))
		if not _is_original_city(board, host):
			return fail.call("宿主不是原版城：%s" % host)
		if bool(t.get("host_interchange", false)):
			if host != "cairo" or str(t.route_type) != LAND: return fail.call("宿主换乘扩展仅支持开罗LAND")
			var host_node := _city_node(board, host)
			board.nodes[host_node].routes[LAND] = true
			board.nodes[host_node].interchange = true
		var cid := "x_" + String(t["slot"])
		var leaf_err := _with_leaf(board, cid, host, String(t.get("route_type", "")))
		if not leaf_err.is_empty():
			return fail.call(leaf_err)
		for connection in t.get("extra_connections", []):
			if not connection is Dictionary or str(connection.get("route_type", "")) != str(t.route_type):
				return fail.call("额外连接必须同交通")
			var extra_err := _with_leaf(board, cid, str(connection.get("host", "")), str(connection.get("route_type", "")), true)
			if extra_err != "": return fail.call(extra_err)
		# 第 2 步：新货代号 = x_<槽位>（与新城 id 相同字符串，分属货物表和城市表）
		_econ_add_city(econ, cid, cid)
	var dist := _city_distances(board)
	var codes := {}
	for t in topo:
		codes["x_" + String(t["slot"])] = "x_" + String(t["slot"])
	var sources := _source_cities(econ, base_deck_ids, codes)
	var errors: Array[String] = []
	var existing_ids := {}
	for dk in econ["decks"]:
		for c in dk["cards"]:
			existing_ids[c["id"]] = true
	var cap_log: Array = []
	var new_decks: Array = []
	for t in topo:
		var cid := "x_" + String(t["slot"])
		var forced := {}
		if not String(t.get("partner", "")).is_empty():
			forced["x_" + String(t["partner"])] = int(p["forced_min"])
		var deck_id := "deck_" + cid
		# 第 3–9、12 步：卡型、格数、外地货次数、排队、装卡、卡价、特产数量、组装
		var dk := _generate_deck(econ, dist, p, deck_id, [cid], forced, "", 0)
		if dk.has("error"):
			return fail.call(String(dk["error"]))
		# 第 10 步：近源封顶
		cap_log.append_array(_near_source_cap(p, dist, dk, cid, cid, sources))
		errors.append_array(_validate(dk, econ["goods"], existing_ids, [cid], false))
		for c in dk["cards"]:
			existing_ids[c["id"]] = true
		new_decks.append(dk)
		econ["decks"].append({"id": deck_id, "city_ids": [cid], "cards": dk["cards"]})
		econ["city_deck"][cid] = deck_id
	# 第 11 步：循环护栏
	var new_ids: Array = []
	for t in topo:
		new_ids.append("x_" + String(t["slot"]))
	var guard := _enforce_loop_cap(econ, dist, new_ids, p)
	if not bool(guard["fixed"]):
		errors.append("循环护栏没能把全部循环压到上限以内")
	# 第 14 步：校验（R15 全部条目 + 搭档格数）
	var out_decks: Array = []
	for i in topo.size():
		var t: Dictionary = topo[i]
		var dk: Dictionary = new_decks[i]
		var cid := "x_" + String(t["slot"])
		errors.append_array(_validate(dk, econ["goods"], {}, [cid], true))
		if not String(t.get("partner", "")).is_empty():
			var partner := "x_" + String(t["partner"])
			var n_partner := 0
			for c in dk["cards"]:
				for e in c["entries"]:
					if String(e["resource_id"]) == partner:
						n_partner += 1
			if n_partner < int(p["forced_min"]):
				errors.append("%s: 搭档特产 %d 格 < %d" % [dk["id"], n_partner, int(p["forced_min"])])
		out_decks.append({"id": dk["id"], "city_id": cid, "cards": dk["cards"]})
	if out_decks.size() != topo.size():
		errors.append("牌堆数 %d 与新城数 %d 不同" % [out_decks.size(), topo.size()])
	return {"ok": errors.is_empty(), "decks": out_decks, "guard_log": guard["log"], "cap_log": cap_log,
		"errors": errors, "_econ": econ, "_dist": dist}


## goods_map：要么为空（输出保持代号 x_<槽位>），要么覆盖每个槽位；值必须是 x_<槽位>_<特产键>、不在基础货物表里、互不相同。
## 改名发生在校验之后，所以这里不放行任何能撞上别的货的 id（例如把新特产改名成 silk，一张卡上就会出现两格丝绸）。
static func _check_goods_map(base_content: Dictionary, topology: Array, goods_map: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	if goods_map.is_empty():
		return errs
	var slots := {}
	for t in topology:
		slots[String(t["slot"])] = true
	var base_goods: Dictionary = base_content.get("goods", {})
	var seen := {}
	for k in goods_map.keys():
		if not (k is String or k is StringName) or not slots.has(String(k)):
			errs.append("goods_map 的键 %s 不是这张图的槽位" % str(k))
			continue
		var v: Variant = goods_map[k]
		var prefix := "x_%s_" % String(k)
		if not (v is String or v is StringName) or not String(v).begins_with(prefix) or String(v).length() <= prefix.length():
			errs.append("goods_map[%s] = %s：必须是 %s<特产键>" % [String(k), str(v), prefix])
			continue
		if base_goods.has(String(v)):
			errs.append("goods_map[%s] = %s：与基础货物重名" % [String(k), String(v)])
		if seen.has(String(v)):
			errs.append("goods_map[%s] = %s：与另一个槽位重复" % [String(k), String(v)])
		seen[String(v)] = true
	for slot in slots.keys():
		if not goods_map.has(slot):
			errs.append("goods_map 缺槽位 %s" % slot)
	return errs


## 第 13 步：代号 x_<槽位> 换成真实货物 id（goods_map 的键是槽位）。
static func _apply_goods_map(decks: Array, goods_map: Dictionary) -> void:
	var rename := {}
	for slot in goods_map.keys():
		rename["x_" + String(slot)] = String(goods_map[slot])
	for dk in decks:
		for c in dk["cards"]:
			for e in c["entries"]:
				if String(e["resource_kind"]) == "GOOD" and rename.has(String(e["resource_id"])):
					e["resource_id"] = rename[String(e["resource_id"])]


static func _sorted_topology(topology: Array) -> Array:
	var rows: Array = []
	for i in topology.size():
		rows.append([String((topology[i] as Dictionary).get("slot", "")), i, topology[i]])
	rows.sort_custom(func(a, b): return _lex_less(a, b))
	var out: Array = []
	for r in rows:
		out.append(r[2])
	return out


# ---------------------------------------------------------------------------
# 棋盘：节点 + 边 + 城市交通属性（只算步数）
# ---------------------------------------------------------------------------

static func _board_from_content(content: Dictionary) -> Dictionary:
	var nodes := {}
	var cities: Dictionary = content.get("cities", {})
	for n in (content.get("board_nodes", {}) as Dictionary).values():
		var nid := String(n["id"])
		if String(n.get("node_type", "")) == "CITY":
			var cid := String(n.get("city_id", ""))
			var c: Dictionary = cities[cid]
			var routes := {}
			for r in c.get("allowed_routes", []):
				routes[String(r)] = true
			nodes[nid] = {"kind": "CITY", "city_id": cid, "routes": routes, "interchange": bool(c.get("is_transport_interchange", false))}
		else:
			nodes[nid] = {"kind": "ROAD", "city_id": "", "routes": {}, "interchange": false}
	var edges: Array = []
	for e in content.get("board_edges", []):
		var a := String(e["a"])
		var b := String(e["b"])
		var t := String(e["route_type"])
		edges.append([a, b, t])
		for end in [a, b]:
			if String(nodes[end]["kind"]) == "ROAD":
				nodes[end]["routes"][t] = true
	return {"nodes": nodes, "edges": edges}


static func _is_original_city(board: Dictionary, city_id: String) -> bool:
	for n in (board["nodes"] as Dictionary).values():
		if String(n["kind"]) == "CITY" and String(n["city_id"]) == city_id:
			return true
	return false


static func _city_node(board: Dictionary, city_id: String) -> String:
	for nid in (board["nodes"] as Dictionary).keys():
		if String(board["nodes"][nid]["city_id"]) == city_id:
			return String(nid)
	return ""


## 新城只做叶子：新城 — 道路点 _01 — 道路点 _02 — 宿主，3 条同类型的边；商道 id = <land|sea>_<宿主>_<新城 id>。
static func _with_leaf(board: Dictionary, city_id: String, anchor_city: String, route: String, additional := false) -> String:
	if route != LAND and route != SEA:
		return "路线类型只能是 LAND 或 SEA：%s" % route
	if not _city_node(board, city_id).is_empty() and not additional:
		return "城 id 已经在棋盘上：%s" % city_id
	var anchor := _city_node(board, anchor_city)
	if anchor.is_empty():
		return "宿主不存在：%s" % anchor_city
	if not (board["nodes"][anchor]["routes"] as Dictionary).has(route):
		return "宿主 %s 没有 %s 路" % [anchor_city, route]
	var pre := "%s_%s_%s" % [route.to_lower(), anchor_city, city_id]
	var r1 := pre + "_01"
	var r2 := pre + "_02"
	board["nodes"][city_id] = {"kind": "CITY", "city_id": city_id, "routes": {route: true}, "interchange": false}
	board["nodes"][r1] = {"kind": "ROAD", "city_id": "", "routes": {route: true}, "interchange": false}
	board["nodes"][r2] = {"kind": "ROAD", "city_id": "", "routes": {route: true}, "interchange": false}
	board["edges"].append([anchor, r1, route])
	board["edges"].append([r1, r2, route])
	board["edges"].append([r2, city_id, route])
	return ""


## 交通规则下的城市间最短步数：状态 = (节点, 交通)，只有换乘城能 0 步换乘（与参考实现同一种 0-1 BFS）。
static func _city_distances(board: Dictionary) -> Dictionary:
	var nodes: Dictionary = board["nodes"]
	var adj := {}
	for e in board["edges"]:
		if not adj.has(e[0]):
			adj[e[0]] = []
		if not adj.has(e[1]):
			adj[e[1]] = []
		adj[e[0]].append([e[1], e[2]])
		adj[e[1]].append([e[0], e[2]])
	var city_nodes := {}
	for nid in nodes.keys():
		if String(nodes[nid]["kind"]) == "CITY":
			city_nodes[nid] = String(nodes[nid]["city_id"])
	var out := {}
	for src in city_nodes.keys():
		var dist := {}          # 节点 → {交通: 步数}
		var dq: Array = []
		for t in [LAND, SEA]:
			if (nodes[src]["routes"] as Dictionary).has(t):
				_dist_set(dist, src, t, 0)
				dq.append([src, t])
		while not dq.is_empty():
			var cur: Array = dq.pop_front()
			var u: String = cur[0]
			var t: String = cur[1]
			var du: int = dist[u][t]
			if bool(nodes[u]["interchange"]):
				for t2 in [LAND, SEA]:
					if t2 != t and (nodes[u]["routes"] as Dictionary).has(t2) and (not _dist_has(dist, u, t2) or du < int(dist[u][t2])):
						_dist_set(dist, u, t2, du)
						dq.push_front([u, t2])
			for vt in adj.get(u, []):
				if String(vt[1]) != t:
					continue
				if not _dist_has(dist, vt[0], t) or du + 1 < int(dist[vt[0]][t]):
					_dist_set(dist, vt[0], t, du + 1)
					dq.append([vt[0], t])
		var row := {}
		for nid in city_nodes.keys():
			if dist.has(nid):
				var best := -1
				for t in (dist[nid] as Dictionary).keys():
					var d: int = dist[nid][t]
					if best < 0 or d < best:
						best = d
				row[city_nodes[nid]] = best
		out[city_nodes[src]] = row
	return out


static func _dist_has(dist: Dictionary, n: String, t: String) -> bool:
	return dist.has(n) and (dist[n] as Dictionary).has(t)


static func _dist_set(dist: Dictionary, n: String, t: String, d: int) -> void:
	if not dist.has(n):
		dist[n] = {}
	dist[n][t] = d


# ---------------------------------------------------------------------------
# 经济数据（货物、产地、牌堆）
# ---------------------------------------------------------------------------

static func _econ_from_content(content: Dictionary) -> Dictionary:
	var goods := {}
	for g in (content.get("goods", {}) as Dictionary).values():
		goods[String(g["id"])] = int(g.get("supply_total", 0))
	var city_deck := {}
	for c in (content.get("cities", {}) as Dictionary).values():
		city_deck[String(c["id"])] = String(c.get("trade_color_id", ""))
	var producer := {}
	var specialty := {}
	for cc in (content.get("city_cards", {}) as Dictionary).values():
		var ent: Dictionary = cc["starting_grant"]["entries"][0]
		if String(ent["resource_kind"]) == "GOOD":
			specialty[String(cc["city_id"])] = String(ent["resource_id"])
			producer[String(ent["resource_id"])] = String(cc["city_id"])
		else:
			specialty[String(cc["city_id"])] = ""
	var decks: Array = []
	for d in (content.get("trade_decks", {}) as Dictionary).values():
		var cards: Array = []
		var card_list: Array = (d["cards"] as Dictionary).values() if d["cards"] is Dictionary else d["cards"]
		for c in card_list:
			var entries: Array = []
			for e in c["entries"]:
				entries.append({"resource_kind": String(e["resource_kind"]), "resource_id": String(e["resource_id"]), "quantity": int(e["quantity"])})
			cards.append({"id": String(c["id"]), "card_number": int(c.get("card_number", 0)), "entries": entries})
		var city_ids: Array = []
		for cid in d.get("city_ids", []):
			city_ids.append(String(cid))
		decks.append({"id": String(d["id"]), "city_ids": city_ids, "cards": cards})
	return {"goods": goods, "producer": producer, "specialty": specialty, "city_deck": city_deck, "decks": decks}


static func _econ_add_city(econ: Dictionary, city_id: String, code: String) -> void:
	econ["goods"][code] = 10
	econ["producer"][code] = city_id
	econ["specialty"][city_id] = code


static func _econ_deck(econ: Dictionary, deck_id: String) -> Dictionary:
	for d in econ["decks"]:
		if String(d["id"]) == deck_id:
			return d
	return {}


static func _card_silver(card: Dictionary) -> int:
	for e in card["entries"]:
		if String(e["resource_kind"]) == "SILVER":
			return int(e["quantity"])
	return -1          # 没有白银项


static func _deck_locals(econ: Dictionary, city_ids: Array) -> Array:
	var out: Array = []
	for c in city_ids:
		var s := String(econ["specialty"].get(c, ""))
		if not s.is_empty():
			out.append(s)
	return out


static func _good_distance(econ: Dictionary, dist: Dictionary, city_ids: Array, good: String) -> int:
	if not (econ["producer"] as Dictionary).has(good):
		return -1
	var best := -1
	for c in city_ids:
		var d: int = dist[c][econ["producer"][good]]
		if best < 0 or d < best:
			best = d
	return best


# ---------------------------------------------------------------------------
# 生成一堆（与参考实现 generate_deck 逐行对应）
# ---------------------------------------------------------------------------

static func _generate_deck(econ: Dictionary, dist: Dictionary, p: Dictionary, deck_id: String, city_ids: Array,
		forced: Dictionary, exclude_deck_for_silk: String, no_silver: int) -> Dictionary:
	var locs := _deck_locals(econ, city_ids)
	if locs.size() > 2:
		return {"error": "一堆最多 2 种特产"}
	var n_cards := 10
	var types: Array = []
	if locs.size() == 2:
		for i in 10:
			types.append("L")
	elif locs.size() == 1:
		for i in n_cards - int(p["n_local_single"]):
			types.append("A")
		for i in int(p["n_local_single"]):
			types.append("L")
	else:
		for i in n_cards:
			types.append("A")
	var n_slots := no_silver
	for t in types:
		n_slots += 2 if t == "L" else 3
	var n_silk: int = int(p["silk_slots"]) if (econ["goods"] as Dictionary).has("silk") else 0
	var n_other := n_slots - n_silk

	# --- 外地货需求次数 ---
	var pool: Array = []
	for g in (econ["producer"] as Dictionary).keys():
		if not city_ids.has(econ["producer"][g]):
			pool.append(String(g))
	pool.sort()
	var gdist := {}
	for g in pool:
		gdist[g] = _good_distance(econ, dist, city_ids, g)
	if pool.size() > n_other:
		return {"error": "外地货种类（%d）多于可用格数（%d）" % [pool.size(), n_other]}
	var w := {}
	for g in pool:
		w[g] = _appear_target(p, int(gdist[g]))
	var total_w := 0.0
	for g in pool:
		total_w = total_w + float(w[g])
	var raw := {}
	for g in pool:
		raw[g] = float(w[g]) * float(n_other) / total_w
	var cnt := {}
	for g in pool:
		cnt[g] = maxi(maxi(1, int(forced.get(g, 1))), mini(int(p["max_count"]), int(floorf(raw[g]))))
	var guard := 0
	while _sum_values(cnt) < n_other and guard < 1000:
		var rows: Array = []
		for i in pool.size():
			var g: String = pool[i]
			rows.append([_k9(float(cnt[g]) - float(raw[g])), -int(gdist[g]), _stable_hash([deck_id, g]), i, g])
		rows.sort_custom(func(a, b): return _lex_less(a, b))
		var pick := ""
		for r in rows:
			if int(cnt[r[4]]) < int(p["max_count"]):
				pick = r[4]
				break
		if pick.is_empty():
			pick = rows[0][4]
		cnt[pick] = int(cnt[pick]) + 1
		guard += 1
	while _sum_values(cnt) > n_other and guard < 2000:
		var rows: Array = []
		for i in pool.size():
			var g: String = pool[i]
			rows.append([_k9(float(raw[g]) - float(cnt[g])), int(gdist[g]), _stable_hash([deck_id, g]), i, g])
		rows.sort_custom(func(a, b): return _lex_less(a, b))
		var pick := ""
		for r in rows:
			if int(cnt[r[4]]) > maxi(1, int(forced.get(r[4], 1))):
				pick = r[4]
				break
		if pick.is_empty():
			return {"error": "外地货次数调不下来：%s" % deck_id}
		cnt[pick] = int(cnt[pick]) - 1
		guard += 1

	# --- 排队：按距离从远到近，丝绸按"虚拟距离"插队 ---
	var silk_price := _silk_target_price(p, econ, dist, city_ids, exclude_deck_for_silk)
	var slots: Array = []           # [距离(float), 哈希, 货]
	for g in pool:
		for k in int(cnt[g]):
			slots.append([float(gdist[g]), _stable_hash([deck_id, g, k]), g])
	var vd_silk := _virtual_distance(p, silk_price, types.has("L"))
	for k in n_silk:
		slots.append([vd_silk, _stable_hash([deck_id, "silk", k]), "silk"])
	var srows: Array = []
	for i in slots.size():
		srows.append([-_k9(slots[i][0]), slots[i][1], i])
	srows.sort_custom(func(a, b): return _lex_less(a, b))
	var queue: Array = []
	for r in srows:
		queue.append(slots[r[2]][2])

	# --- 顺序装卡 ---
	var l_positions: Array = []
	for i in types.size():
		if types[i] == "L":
			l_positions.append(i)
	var barter := {}
	if no_silver > 0:
		for j in range(l_positions.size() - no_silver, l_positions.size()):
			barter[l_positions[j]] = true
	var needs: Array = []
	for ci in types.size():
		needs.append(3 if (types[ci] == "A" or barter.has(ci)) else 2)
	var filled := _fill_cards(queue, needs, deck_id)
	if filled.has("error"):
		return filled
	var cards_goods: Array = filled["cards"]

	# --- 卡价 ---
	var cards: Array = []
	for ci in types.size():
		var gs: Array = cards_goods[ci]
		var ds: Array = []
		for g in gs:
			if g != "silk":
				ds.append(int(gdist[g]))
		var dbar: float = _mean_ints(ds) if not ds.is_empty() else vd_silk
		var pred := _predict_price(p, dbar, types[ci] == "L")
		cards.append({"type": types[ci], "goods": gs, "pred": pred, "dbar": dbar, "barter": barter.has(ci), "S": -1})
	var priced: Array = []
	for i in cards.size():
		if not bool(cards[i]["barter"]):
			priced.append(i)
	var rrows: Array = []
	for i in priced:
		var jit := float(p["rank_jitter"]) * (float(_stable_hash([deck_id, "jit", i]) % 1000) / 1000.0 - 0.5)
		rrows.append([_k9(float(cards[i]["pred"]) + jit), _stable_hash([deck_id, "rank", i]), i])
	rrows.sort_custom(func(a, b): return _lex_less(a, b))
	var preds: Array = []
	for i in priced:
		preds.append(float(cards[i]["pred"]))
	var vals := _template_values(p, _mean_floats(preds), priced.size(), no_silver)
	for k in rrows.size():
		cards[rrows[k][2]]["S"] = int(vals[k])
	for c in cards:
		if bool(c["barter"]):
			c["S"] = -1

	# --- 本地特产卡：数量按"S 排名 -> q 图样" ---
	var lrows: Array = []
	for i in cards.size():
		if cards[i]["type"] == "L":
			var key1: int = _k9(float(cards[i]["pred"])) if int(cards[i]["S"]) < 0 else _k9(float(int(cards[i]["S"])))
			lrows.append([key1, _k9(float(cards[i]["dbar"])), _stable_hash([deck_id, "L", i]), i])
	lrows.sort_custom(func(a, b): return _lex_less(a, b))
	var l_sorted: Array = []
	for r in lrows:
		l_sorted.append(r[3])
	var per_spec := {}
	for loc in locs:
		per_spec[loc] = []
	if locs.size() == 2:
		var frows: Array = []
		for j in locs.size():
			frows.append([_stable_hash([deck_id, locs[j]]), j, locs[j]])
		frows.sort_custom(func(a, b): return _lex_less(a, b))
		for k in l_sorted.size():
			per_spec[frows[k % 2][2]].append(l_sorted[k])
	elif locs.size() == 1:
		per_spec[locs[0]] = l_sorted.duplicate()
	for loc in per_spec.keys():
		var idxs: Array = per_spec[loc]
		var pattern: Array = p["q_pattern_by_s_rank"]
		if idxs.size() != pattern.size():
			var qm: Array = p["q_multiset"]
			pattern = []
			for k in idxs.size():
				pattern.append(qm[mini(qm.size() - 1, int((float(k) + 0.5) / float(idxs.size()) * float(qm.size())))])
		for k in idxs.size():
			var i: int = idxs[k]
			var q: int = int(pattern[k])
			var s: int = int(cards[i]["S"])
			if s >= 0:
				while q > 2 and float(s) / float(q) < float(p["unit_floor"]) - 1e-9:
					q -= 1
			cards[i]["local"] = [loc, q]

	# --- 组装条目 ---
	var orows: Array = []
	for i in cards.size():
		orows.append([_stable_hash([deck_id, "order", i]), i])
	orows.sort_custom(func(a, b): return _lex_less(a, b))
	var out_cards: Array = []
	for n in orows.size():
		var c: Dictionary = cards[orows[n][1]]
		var grows: Array = []
		for g in c["goods"]:
			grows.append([1 if g == "silk" else 0, -int(gdist.get(g, 0)), g])
		grows.sort_custom(func(a, b): return _lex_less(a, b))
		var gs: Array = []
		for r in grows:
			gs.append(r[2])
		var ent: Array = []
		if c["type"] == "L":
			ent.append({"resource_kind": "GOOD", "resource_id": gs[0], "quantity": 1})
			ent.append({"resource_kind": "GOOD", "resource_id": c["local"][0], "quantity": int(c["local"][1])})
			for j in range(1, gs.size()):
				ent.append({"resource_kind": "GOOD", "resource_id": gs[j], "quantity": 1})
		else:
			for g in gs:
				ent.append({"resource_kind": "GOOD", "resource_id": g, "quantity": 1})
		if int(c["S"]) >= 0:
			ent.append({"resource_kind": "SILVER", "resource_id": "silver", "quantity": int(c["S"])})
		out_cards.append({"id": "%s_card_%02d" % [deck_id, n + 1], "card_number": n + 1, "entries": ent})
	return {"id": deck_id, "city_ids": city_ids.duplicate(), "cards": out_cards}


static func _appear_target(p: Dictionary, d: int) -> float:
	var ks: Array = p["appear_keys"]
	var ap: Dictionary = p["appear"]
	if d <= int(ks[0]):
		return float(ap[ks[0]])
	if d >= int(ks[ks.size() - 1]):
		return float(ap[ks[ks.size() - 1]])
	var lo := -1
	var hi := -1
	for k in ks:
		if int(k) <= d:
			lo = int(k)
	for i in range(ks.size() - 1, -1, -1):
		if int(ks[i]) >= d:
			hi = int(ks[i])
	if lo == hi:
		return float(ap[lo])
	var t := float(d - lo) / float(hi - lo)
	return float(ap[lo]) * (1.0 - t) + float(ap[hi]) * t


static func _predict_price(p: Dictionary, dbar: float, is_local: bool) -> float:
	var coef: Array = p["price_coef"]
	return float(coef[0]) + float(coef[1]) * dbar + (float(coef[2]) if is_local else 0.0)


static func _virtual_distance(p: Dictionary, price: float, is_local: bool) -> float:
	var coef: Array = p["price_coef"]
	return (price - float(coef[0]) - (float(coef[2]) if is_local else 0.0)) / float(coef[1])


## 按预测价位 mu 选最接近的原版白银分布模板（并列取较低的），按分位重采样到 n 张；只用无银卡张数相同的模板。
static func _template_values(p: Dictionary, mu: float, n: int, no_silver: int) -> Array:
	var pool: Array = []
	for t in p["s_templates"]:
		if int(t["no_silver"]) == no_silver:
			pool.append(t)
	if pool.is_empty():
		pool = p["s_templates"]
	var best: Dictionary = {}
	var best_key: Array = []
	for t in pool:
		var key := [_k9(absf(float(t["mean"]) - mu)), _k9(float(t["mean"]))]
		if best.is_empty() or _lex_less(key, best_key):
			best = t
			best_key = key
	var sv: Array = best["values"]
	var out: Array = []
	for k in n:
		out.append(sv[mini(sv.size() - 1, int((float(k) + 0.5) / float(n) * float(sv.size())))])
	return out


## 丝绸价格按"邻堆"取：本堆城市 3 步内的其它城市所在牌堆的丝绸均价；新叶子城只有宿主这一个邻居。
static func _silk_target_price(p: Dictionary, econ: Dictionary, dist: Dictionary, city_ids: Array, exclude_deck: String) -> float:
	var neigh := {}
	var silk: Dictionary = p["silk_price_by_deck"]
	for c in city_ids:
		for o in (dist[c] as Dictionary).keys():
			if int(dist[c][o]) == 3 and not city_ids.has(o) and (econ["city_deck"] as Dictionary).has(o):
				var dk := String(econ["city_deck"][o])
				if dk != exclude_deck and silk.has(dk):
					neigh[dk] = true
	if neigh.is_empty():
		return float(p["silk_price_global"])
	var ids: Array = neigh.keys()
	ids.sort()
	var vals: Array = []
	for d in ids:
		vals.append(float(silk[d]))
	return _mean_floats(vals)


## 按队列顺序装卡：同一张卡不放同一种货；整张卡的组合不与已有卡重复；装不下时和前面的卡交换一格。
static func _fill_cards(queue_in: Array, needs: Array, deck_id: String) -> Dictionary:
	var queue: Array = queue_in.duplicate()
	var cards: Array = []
	for need in needs:
		var got: Array = []
		cards.append(got)
		var idx := cards.size() - 1
		while got.size() < int(need):
			var placed := false
			for i in queue.size():
				var g: String = queue[i]
				if got.has(g):
					continue
				if got.size() == int(need) - 1:
					var trial: Array = got.duplicate()
					trial.append(g)
					if _sig_clash(cards, trial, idx):
						continue
				got.append(queue[i])
				queue.remove_at(i)
				placed = true
				break
			if placed:
				continue
			if queue.is_empty():
				return {"error": "装卡失败（格数不够）：%s" % deck_id}
			var g0: String = queue[0]
			var done := false
			for j in range(idx - 1, -1, -1):
				var c: Array = cards[j]
				for k in c.size():
					var x: String = c[k]
					if x == g0 or got.has(x) or c.has(g0):
						continue
					var c2: Array = c.slice(0, k)
					c2.append(g0)
					c2.append_array(c.slice(k + 1))
					var got2: Array = got.duplicate()
					got2.append(x)
					if not _all_distinct(c2) or not _all_distinct(got2):
						continue
					cards[j] = c2
					if _sig_clash(cards, c2, j) or (got2.size() == int(need) and _sig_clash(cards, got2, idx)):
						cards[j] = c
						continue
					queue.remove_at(0)
					got.append(x)
					done = true
					break
				if done:
					break
			if not done:
				return {"error": "装卡失败：%s" % deck_id}
	return {"cards": cards}


static func _all_distinct(card: Array) -> bool:
	var seen := {}
	for g in card:
		if seen.has(g):
			return false
		seen[g] = true
	return true


static func _sig_clash(cards: Array, card: Array, idx: int) -> bool:
	var f := {}
	for g in card:
		f[g] = true
	for j in cards.size():
		if j == idx:
			continue
		var c: Array = cards[j]
		if c.size() != card.size():
			continue
		var same := true
		var cs := {}
		for g in c:
			cs[g] = true
		if cs.size() != f.size():
			same = false
		else:
			for g in f.keys():
				if not cs.has(g):
					same = false
					break
		if same:
			return true
	return false


# ---------------------------------------------------------------------------
# 近源封顶（R13，第 10 步）
# ---------------------------------------------------------------------------

## 货源城：一种货出现在哪一堆的整批格（数量 ≥ 2）里，那一堆的全部城都是它的货源城（丝绸不算）；新特产 = 它自己的新城。
static func _source_cities(econ: Dictionary, base_deck_ids: Array, codes: Dictionary) -> Dictionary:
	var sets := {}
	for dk_id in base_deck_ids:
		var dk := _econ_deck(econ, String(dk_id))
		for c in dk["cards"]:
			for e in c["entries"]:
				if String(e["resource_kind"]) == "GOOD" and String(e["resource_id"]) != "silk" and int(e["quantity"]) >= 2:
					var g := String(e["resource_id"])
					if not sets.has(g):
						sets[g] = {}
					for cid in dk["city_ids"]:
						sets[g][cid] = true
	for code in codes.keys():
		sets[code] = {codes[code]: true}
	var out := {}
	for g in sets.keys():
		var arr: Array = (sets[g] as Dictionary).keys()
		arr.sort()
		out[g] = arr
	return out


static func _near_source_cap(p: Dictionary, dist: Dictionary, deck: Dictionary, city_id: String, own_code: String, sources: Dictionary) -> Array:
	var log: Array = []
	for card in deck["cards"]:
		var near := ""
		for e in card["entries"]:
			if String(e["resource_kind"]) != "GOOD":
				continue
			var g := String(e["resource_id"])
			if g == "silk" or g == own_code:
				continue
			var src: Array = sources.get(g, [])
			if src.is_empty():
				continue
			var d := -1
			for s in src:
				var ds: int = dist[city_id][s]
				if d < 0 or ds < d:
					d = ds
			if d <= int(p["near_source_steps"]):
				near = g
				break
		if near.is_empty():
			continue
		var silver: Dictionary = {}
		for e in card["entries"]:
			if String(e["resource_kind"]) == "SILVER":
				silver = e
				break
		if silver.is_empty() or int(silver["quantity"]) <= int(p["near_source_silver_cap"]):
			continue
		silver["quantity"] = int(p["near_source_silver_cap"])
		for e in card["entries"]:
			if String(e["resource_kind"]) == "GOOD" and String(e["resource_id"]) == own_code:
				var q: int = int(e["quantity"])
				while q > 2 and float(int(silver["quantity"])) / float(q) < float(p["unit_floor"]) - 1e-9:
					q -= 1
				e["quantity"] = q
		log.append({"deck": deck["id"], "card": card["id"], "good": near})
	return log


# ---------------------------------------------------------------------------
# 商路循环与护栏（R14，第 11 步）
# ---------------------------------------------------------------------------

## 每种货在这一堆里能按什么比例和白银互换：{货: [[S, q, card_id], ...]}（卡按堆内顺序、条目按卡内顺序）。
static func market_offers(deck: Dictionary) -> Dictionary:
	var out := {}
	for c in deck["cards"]:
		var s := _card_silver(c)
		if s < 0:
			continue
		for e in c["entries"]:
			if String(e["resource_kind"]) == "GOOD":
				var g := String(e["resource_id"])
				if not out.has(g):
					out[g] = []
				out[g].append([s, int(e["quantity"]), String(c["id"])])
	return out


## 在 buy 卡用白银买满 4 格货仓、到 sell 卡按牌面卖出；余下不够一份的按直售 1 银/件。返回 [利润, 本金]。
static func load_profit(buy: Array, sell: Array) -> Array:
	var times: int = WAREHOUSE / int(buy[1])
	var units: int = times * int(buy[1])
	var cost: int = times * int(buy[0])
	var t2: int = units / int(sell[1])
	var revenue: int = t2 * int(sell[0]) + (units - t2 * int(sell[1]))
	return [revenue - cost, cost]


## 所有"甲城买、乙城卖"的单程循环（空车回程）：利润 / (2·T[d])，两张牌同时翻开的最好情况。
## only 非空时只算甲或乙在 only 里的循环。按 (-rate, -profit, 甲, 乙, 货) 排序。
static func all_loops(econ: Dictionary, dist: Dictionary, turns: Array, only: Dictionary) -> Array:
	var offers := {}
	for d in econ["decks"]:
		offers[d["id"]] = market_offers(d)
	var deck_of: Dictionary = econ["city_deck"]
	var cities: Array = []
	for c in deck_of.keys():
		if dist.has(c):
			cities.append(String(c))
	cities.sort()
	var rows: Array = []
	for a in cities:
		var oa: Dictionary = offers[deck_of[a]]
		for b in cities:
			if a == b:
				continue
			if not only.is_empty() and not only.has(a) and not only.has(b):
				continue
			var ob: Dictionary = offers[deck_of[b]]
			var d: int = dist[a][b]
			var same_deck: bool = deck_of[a] == deck_of[b]
			for g in oa.keys():
				if not ob.has(g):
					continue
				var best := 0
				var has_best := false
				var cost := 0
				var arg_buy := ""
				var arg_sell := ""
				for bo in oa[g]:
					for so in ob[g]:
						if same_deck and bo[2] == so[2]:
							continue
						var pc := load_profit(bo, so)
						if not has_best or int(pc[0]) > best:
							best = int(pc[0])
							has_best = true
							cost = int(pc[1])
							arg_buy = bo[2]
							arg_sell = so[2]
				if not has_best or best <= 0:
					continue
				var cyc := 2.0 * float(turns[d])
				var rate := float(best) / cyc
				rows.append([-_k9(rate), -best, a, b, g, {"buy": a, "sell": b, "good": g, "d": d, "profit": best, "cost": cost,
					"turns": cyc, "rate": rate, "buy_card": arg_buy, "sell_card": arg_sell}])
	rows.sort_custom(func(x, y): return _lex_less(x, y))
	var out: Array = []
	for r in rows:
		out.append(r[5])
	return out


## 往返都装货：甲→乙卖一趟、在乙多停 1 回合买乙的货、回甲卖、在甲多停 1 回合买。周期 2·T[d]+2。
static func two_way_loops(one_way: Array, turns: Array) -> Array:
	var best := {}
	var order: Array = []
	for l in one_way:
		var k := "%s\u001f%s" % [l["buy"], l["sell"]]
		if not best.has(k):
			best[k] = l
			order.append(k)
		elif int(l["profit"]) > int(best[k]["profit"]):
			best[k] = l
	var rows: Array = []
	for k in order:
		var l1: Dictionary = best[k]
		var a := String(l1["buy"])
		var b := String(l1["sell"])
		var back := "%s\u001f%s" % [b, a]
		if not (a < b) or not best.has(back):
			continue
		var l2: Dictionary = best[back]
		var cyc := 2.0 * float(turns[int(l1["d"])]) + 2.0
		var profit := int(l1["profit"]) + int(l2["profit"])
		var rate := float(profit) / cyc
		rows.append([-_k9(rate), a, b, {"a": a, "b": b, "d": int(l1["d"]), "good_ab": l1["good"], "good_ba": l2["good"],
			"profit": profit, "turns": cyc, "rate": rate}])
	rows.sort_custom(func(x, y): return _lex_less(x, y))
	var out: Array = []
	for r in rows:
		out.append(r[3])
	return out


## 护栏：任何经过新城的循环（单程或往返）都不许比原版最好的循环更赚（rate > cap + eps 才算超）。
## 超了就改新牌堆上那张卡：卖出卡在新牌堆 → 白银 -1；否则买入卡在新牌堆 → 整批数量 -1，数量已是 2 就白银 +1。
static func _enforce_loop_cap(econ: Dictionary, dist: Dictionary, new_ids: Array, p: Dictionary) -> Dictionary:
	var cap1 := float(p["loop_cap_one_way"])
	var cap2 := float(p["loop_cap_two_way"])
	var eps := float(p["loop_cap_eps"])
	var turns: Array = p["turns_table"]
	var card_home := {}
	for dk in econ["decks"]:
		for c in dk["cards"]:
			card_home[c["id"]] = [dk["id"], c]
	var only := {}
	for c in new_ids:
		only[c] = true
	var new_decks := {}
	for c in new_ids:
		new_decks[econ["city_deck"][c]] = true
	var log: Array = []
	for _iter in int(p["loop_guard_max_iter"]):
		var loops := all_loops(econ, dist, turns, only)
		var ways := two_way_loops(loops, turns)
		var bad: Dictionary = {}
		for l in loops:
			if float(l["rate"]) > cap1 + eps:
				bad = l
				break
		if bad.is_empty():
			var badw: Dictionary = {}
			for w in ways:
				if float(w["rate"]) > cap2 + eps:
					badw = w
					break
			if badw.is_empty():
				return {"log": log, "fixed": true}
			for l in loops:
				var pair_ok: bool = (l["buy"] == badw["a"] and l["sell"] == badw["b"]) or (l["buy"] == badw["b"] and l["sell"] == badw["a"])
				if pair_ok and (bad.is_empty() or int(l["profit"]) > int(bad["profit"])):
					bad = l
			if bad.is_empty():
				return {"log": log, "fixed": false}
		var changed := false
		for role in ["sell_card", "buy_card"]:
			var home: Array = card_home[bad[role]]
			if not new_decks.has(home[0]):
				continue
			var card: Dictionary = home[1]
			var silver: Dictionary = {}
			for e in card["entries"]:
				if String(e["resource_kind"]) == "SILVER":
					silver = e
					break
			if role == "sell_card" and int(silver["quantity"]) > S_MIN:
				silver["quantity"] = int(silver["quantity"]) - 1
				for e in card["entries"]:
					if String(e["resource_kind"]) == "GOOD" and int(e["quantity"]) >= 2:
						e["quantity"] = maxi(2, mini(int(e["quantity"]), int(floorf(float(int(silver["quantity"])) * 1.5 + 1e-9))))
				log.append(_guard_entry(String(home[0]), String(card["id"]), "SILVER_MINUS_1", bad))
				changed = true
				break
			if role == "buy_card":
				var ent: Dictionary = {}
				for e in card["entries"]:
					if String(e["resource_id"]) == String(bad["good"]):
						ent = e
						break
				if int(ent["quantity"]) > 2:
					ent["quantity"] = int(ent["quantity"]) - 1
					log.append(_guard_entry(String(home[0]), String(card["id"]), "QTY_MINUS_1", bad))
					changed = true
					break
				if int(silver["quantity"]) < S_MAX:
					silver["quantity"] = int(silver["quantity"]) + 1
					log.append(_guard_entry(String(home[0]), String(card["id"]), "SILVER_PLUS_1", bad))
					changed = true
					break
		if not changed:
			log.append(_guard_entry("?", "?", "UNFIXABLE", bad))
			return {"log": log, "fixed": false}
	return {"log": log, "fixed": false}


static func _guard_entry(deck_id: String, card_id: String, change: String, l: Dictionary) -> Dictionary:
	return {"deck": deck_id, "card": card_id, "change": change,
		"loop": "%s>%s:%s" % [l["buy"], l["sell"], l["good"]], "rate_e9": _k9(float(l["rate"]))}


# ---------------------------------------------------------------------------
# 硬不变量（R15）
# ---------------------------------------------------------------------------

static func _validate(deck: Dictionary, goods: Dictionary, existing_card_ids: Dictionary, local_goods: Array, strict: bool) -> Array[String]:
	var errs: Array[String] = []
	var raw_cards: Variant = deck.get("cards", null)
	if not raw_cards is Array:
		errs.append("%s: cards 不是数组" % str(deck.get("id", "?")))
		return errs
	if (raw_cards as Array).size() != 10:
		errs.append("%s: 卡数 %d != 10" % [str(deck.get("id", "?")), (raw_cards as Array).size()])
	# 先查形状：卡是字典、entries 是数组、每项是字典且字段类型对。形状不对的卡记一条违规，不再往下查（不会报脚本错误）
	var cards: Array = []
	for i in (raw_cards as Array).size():
		var shape := _card_shape_problem(raw_cards[i])
		if shape.is_empty():
			cards.append(raw_cards[i])
		else:
			errs.append("%s: 第 %d 张卡%s" % [str(deck.get("id", "?")), i + 1, shape])
	var signatures := {}
	var seen := {}
	for c in cards:
		var cid := String(c.get("id", ""))
		if seen.has(cid) or existing_card_ids.has(cid):
			errs.append("%s: 卡 id 重复" % cid)
		seen[cid] = true
		var ent: Array = c.get("entries", [])
		if ent.size() != 4:
			errs.append("%s: 不是 4 项" % cid)
		var n_silver := 0
		var all_silver := true
		for e in ent:
			var kind := String(e.get("resource_kind", ""))
			if kind != "GOOD" and kind != "SILVER":
				errs.append("%s: 无效资源类型" % cid)
			if kind == "SILVER":
				n_silver += 1
			else:
				all_silver = false
		if all_silver:
			errs.append("%s: 全是白银" % cid)
		if n_silver > 1:
			errs.append("%s: 白银多于 1 项" % cid)
		for e in ent:
			var q := int(e.get("quantity", 0))
			if q <= 0:
				errs.append("%s: 数量必须为正" % cid)
			if String(e.get("resource_kind", "")) == "GOOD":
				if not goods.has(String(e.get("resource_id", ""))):
					errs.append("%s: 货物 %s 不存在" % [cid, e.get("resource_id", "")])
				if q > Q_MAX:
					errs.append("%s: %s×%d 超过货仓 4 格" % [cid, e.get("resource_id", ""), q])
		var ids := {}
		var dup := false
		for e in ent:
			var rid := String(e.get("resource_id", ""))
			if ids.has(rid):
				dup = true
			ids[rid] = true
		if dup:
			errs.append("%s: 同一卡上资源重复" % cid)
		var sig_rows: Array = []
		for e in ent:
			sig_rows.append("%s\u001f%d" % [e.get("resource_id", ""), int(e.get("quantity", 0))])
		sig_rows.sort()
		var sig := "\u001e".join(PackedStringArray(sig_rows))
		if signatures.has(sig):
			errs.append("%s: 与同堆另一张卡完全相同" % cid)
		signatures[sig] = true
		var s := _card_silver(c)
		if not local_goods.is_empty() and s >= 0:
			for e in ent:
				if local_goods.has(String(e.get("resource_id", ""))) and float(s) / float(int(e.get("quantity", 1))) < UNIT_FLOOR - 1e-9:
					errs.append("%s: 特产 %s 单价 %d/%d 低于 2/3" % [cid, e.get("resource_id", ""), s, int(e.get("quantity", 0))])
		if strict:
			if n_silver != 1:
				errs.append("%s: 不是恰好 1 项白银" % cid)
			for k in ent.size():
				var e: Dictionary = ent[k]
				if String(e.get("resource_kind", "")) == "GOOD" and not local_goods.is_empty() and local_goods.has(String(e.get("resource_id", ""))) and k != 1:
					errs.append("%s: 本城特产不在第 2 格" % cid)
	if strict:
		var total := 0
		var n := 0
		for c in cards:
			var s := _card_silver(c)
			if s >= 0:
				total += s
				n += 1
		if n > 0:
			var m := float(total) / float(n)
			if m < 2.8 - 1e-9 or m > 4.0 + 1e-9:
				errs.append("%s: 白银均值 %d/%d 不在 [2.8, 4.0]" % [deck.get("id", "?"), total, n])
		var kinds := {}
		var n_silk := 0
		for c in cards:
			for e in c.get("entries", []):
				if String(e.get("resource_kind", "")) == "GOOD":
					kinds[String(e.get("resource_id", ""))] = true
				if String(e.get("resource_id", "")) == "silk":
					n_silk += 1
		if kinds.size() < 13:
			errs.append("%s: 货种 %d < 13" % [deck.get("id", "?"), kinds.size()])
		if n_silk != 4:
			errs.append("%s: 丝绸 %d 格，不是 4 格" % [deck.get("id", "?"), n_silk])
	return errs


## 一张卡的形状：字典；id 是字符串；entries 是数组；每项是字典，resource_kind / resource_id 是字符串，quantity 是整数值的数。
## 没问题时返回空字符串。
static func _card_shape_problem(card: Variant) -> String:
	if not card is Dictionary:
		return "不是字典"
	if not (card.get("id", null) is String or card.get("id", null) is StringName):
		return "的 id 不是字符串"
	var ent: Variant = card.get("entries", null)
	if not ent is Array:
		return "（%s）的 entries 不是数组" % String(card["id"])
	for k in (ent as Array).size():
		var e: Variant = ent[k]
		if not e is Dictionary:
			return "（%s）第 %d 项不是字典" % [String(card["id"]), k + 1]
		for field in ["resource_kind", "resource_id"]:
			if not (e.get(field, null) is String or e.get(field, null) is StringName):
				return "（%s）第 %d 项的 %s 不是字符串" % [String(card["id"]), k + 1, field]
		var q: Variant = e.get("quantity", null)
		if not (q is int or (q is float and float(q) == floorf(float(q)))):
			return "（%s）第 %d 项的数量不是整数" % [String(card["id"]), k + 1]
	return ""


# ---------------------------------------------------------------------------
# 小工具：稳定哈希、1e-9 取整、均值、字典序比较、JSON 字符串
# ---------------------------------------------------------------------------

## 稳定哈希：各部分转成字符串、用 \x1f 连接、取 sha1 的前 12 位十六进制转成整数（deck_gen.py:50-52）。
static func _stable_hash(parts: Array) -> int:
	var strs := PackedStringArray()
	for x in parts:
		strs.append(str(x))
	return String.chr(0x1f).join(strs).sha1_text().substr(0, 12).hex_to_int()


## 浮点排序键按 1e-9 取整：floor(x·1e9 + 0.5)。
static func _k9(x: float) -> int:
	return int(floorf(x * 1e9 + 0.5))


static func _mean_ints(xs: Array) -> float:
	var s := 0
	for x in xs:
		s += int(x)
	return float(s) / float(xs.size())


static func _mean_floats(xs: Array) -> float:
	var s := 0.0
	for x in xs:
		s = s + float(x)
	return s / float(xs.size())


static func _sum_values(d: Dictionary) -> int:
	var s := 0
	for v in d.values():
		s += int(v)
	return s


static func _ints(values: Array) -> Array:
	var out: Array = []
	for v in values:
		out.append(int(v))
	return out


## 数组按元素字典序比较（整数、字符串、浮点）；前缀相同时短的在前。
static func _lex_less(a: Array, b: Array) -> bool:
	var n := mini(a.size(), b.size())
	for i in n:
		var x: Variant = a[i]
		var y: Variant = b[i]
		if typeof(x) == TYPE_DICTIONARY or typeof(y) == TYPE_DICTIONARY:
			continue
		if x == y:
			continue
		return x < y
	return a.size() < b.size()


static func _json_string(s: String) -> String:
	var out := "\""
	for i in s.length():
		var ch := s.unicode_at(i)
		match ch:
			0x22:
				out += "\\\""
			0x5c:
				out += "\\\\"
			0x0a:
				out += "\\n"
			0x0d:
				out += "\\r"
			0x09:
				out += "\\t"
			0x08:
				out += "\\b"
			0x0c:
				out += "\\f"
			_:
				if ch < 0x20:
					out += "\\u%04x" % ch
				else:
					out += String.chr(ch)
	return out + "\""
