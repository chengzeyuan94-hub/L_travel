class_name CustomMapRules

## 自制地图的拓扑规则：东西侧判定、宿主条件、搭档条件、自动补城（含原型和特产兜底）、重名时给搭档换名、拓扑检查
## （docs/design/map-editor-20260930/DESIGN.md R5–R10、3.4、3.12.5）。归 WP1。
##
## 为什么新城只做叶子就不改原城之间的步数（R5，证明）：
##   新城 N 只经 A—r1—r2—N 这一段和图相连，r1、r2 的度数都是 2。任取两座原城 X、Y，任何经过 N、r1、r2 的 X→Y 路径
##   都必须从 A 进、再从 A 出；删掉这段往返，路更短。所以原城两两之间的最短步数不变；多座新城各自成立。
##   因此原版的价格梯度、AI 的距离估算、万里商途「⌈步数/3⌉ = 回合数」（ai_policy.gd:694、:776）都继续成立。
##   check_graph 仍按交通规则把 16×16 最短步数矩阵整个重算一遍比对（E_BASE_GRAPH），不只信这段证明。

const LAND := "LAND"
const SEA := "SEA"
## 宿主条件（R6）：挂之前度数 ≤ 3，挂之后 ≤ 4（原版最大就是泉州的 4）
const HOST_MAX_DEGREE := 3
## 搭档条件（R9）：两座宿主之间 ≥ 9 步（所以两座新城之间 ≥ 15 步），两座宿主「到其余 15 座原城的平均步数」相差 ≤ 2.0
const PAIR_MIN_HOST_STEPS := 9
const PAIR_SYM_MAX := 2.0
## 自动补城排序：平均步数差不大于它的排前面（3.12.5 第 2 步）
const PAIR_SYM_PREFER := 1.0
## D1 = B（2026-10-01 先按两对开工，Carlos 之后确认）：玩家亲手最多加 2 座，另一侧自动补，地图上最多 4 座新城
const DEFAULT_MAX_PAIRS := 2
## 生成器的冻结参数（WP2）；在的话 max_pairs 以它为准
const TRADEGEN_PARAMS := "res://data/custom_map/tradegen_v1_params.json"
## 地图文件 moves 段只允许出现的字段（R10）
const MOVE_CITY_FIELDS: Array[String] = ["x", "z", "rotation"]
const MOVE_ROUTE_FIELDS: Array[String] = ["handles", "stop_t"]

static var _dist_cache: Dictionary = {}


# ---------------------------------------------------------------- 参数

## {max_pairs, max_user, pair_min_host_steps, pair_sym_max}；生成器参数文件在的话 max_pairs 取它的
static func params() -> Dictionary:
	var contract := CustomMapTradegenRegistry.contract()
	return {"max_pairs": int(contract.get("max_pairs", DEFAULT_MAX_PAIRS)), "max_user": int(contract.get("max_user", DEFAULT_MAX_PAIRS)),
		"pair_min_host_steps": PAIR_MIN_HOST_STEPS, "pair_sym_max": PAIR_SYM_MAX}


# ---------------------------------------------------------------- 东西、宿主、搭档

## 宿主在哪一侧："W" / "E"（按宿主在正式规则集里的 map_position.x，R8）；不是原城返回 ""
static func side_of_host(base: Dictionary, host_id: String) -> String:
	return CustomMapSchema._side_of(base, host_id)


## 宿主（原城）在基础包里连着几条商道
static func host_degree(base: Dictionary, host_id: String) -> int:
	var city: Dictionary = (base.get("cities", {}) as Dictionary).get(host_id, {})
	var node_id := str(city.get("board_node_id", host_id))
	return ((base.get("edges_from", {}) as Dictionary).get(node_id, []) as Array).size()


static func is_original_city(base: Dictionary, id: String) -> bool:
	return (base.get("cities", {}) as Dictionary).has(id) and not id.begins_with("x_")


## 某一侧、某种路线类型下能当宿主的原城（R6）：交通对、挂之前度数 ≤ 3、这张图里还没挂新城。按 id 排序
static func legal_hosts(base: Dictionary, doc: Dictionary, route_type: String, side: String) -> Array:
	var used := _used_hosts(doc, "")
	var out: Array = []
	for id in (base.get("cities", {}) as Dictionary).keys():
		var host := str(id)
		if not _host_ok(base, host, route_type) or used.has(host):
			continue
		if side != "" and side_of_host(base, host) != side:
			continue
		out.append(host)
	out.sort()
	return out


## 给某个槽位的新城配搭档时，另一侧能当宿主的 (原城, 路线类型)：满足 R6、R9。
## 返回 [{host, route_type, steps, avg_diff}]，按自动补城的顺序排好（3.12.5 第 2 步）
static func legal_partner_hosts(base: Dictionary, doc: Dictionary, slot: String) -> Array:
	var me := _city_by_slot(doc, slot)
	if me.is_empty():
		return []
	var h := str(me.get("host", ""))
	var t := str(me.get("route_type", ""))
	var side := side_of_host(base, h)
	if side == "":
		return []
	var other := "E" if side == "W" else "W"
	var dist := base_distances(base)
	var avg := average_steps(base)
	var used := _used_hosts(doc, str(me.get("partner", "")))
	var out: Array = []
	var hosts: Array = (base.get("cities", {}) as Dictionary).keys()
	hosts.sort()
	for hv in hosts:
		var hp := str(hv)
		if side_of_host(base, hp) != other or used.has(hp):
			continue
		for tp in [LAND, SEA]:
			if not _host_ok(base, hp, tp):
				continue
			var steps := int((dist.get(h, {}) as Dictionary).get(hp, 999))
			var diff := absf(float(avg.get(h, 0.0)) - float(avg.get(hp, 0.0)))
			if steps < PAIR_MIN_HOST_STEPS or diff > PAIR_SYM_MAX + 1e-9:
				continue
			out.append({"host": hp, "route_type": tp, "steps": steps, "avg_diff": diff})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _partner_before(a, b, t))
	return out


## 自动补城的排序（3.12.5 第 2 步）：平均步数差 > 1.0 的排后面 → 步数大的排前面 → 路线类型与自己相同的排前面 → 宿主 id
static func _partner_before(a: Dictionary, b: Dictionary, own_type: String) -> bool:
	var fa := float(a["avg_diff"]) > PAIR_SYM_PREFER + 1e-9
	var fb := float(b["avg_diff"]) > PAIR_SYM_PREFER + 1e-9
	if fa != fb:
		return not fa
	if int(a["steps"]) != int(b["steps"]):
		return int(a["steps"]) > int(b["steps"])
	var sa := str(a["route_type"]) == own_type
	var sb := str(b["route_type"]) == own_type
	if sa != sb:
		return sa
	if str(a["host"]) != str(b["host"]):
		return str(a["host"]) < str(b["host"])
	return str(a["route_type"]) < str(b["route_type"])


## All naming candidates share the authoritative effective original names and new-city names.
static func used_city_names(base: Dictionary, doc: Dictionary) -> Dictionary:
	var used := {}
	for cid in base.get("cities", {}):
		var original: Dictionary = base.cities[cid]
		used[str(CustomMapCityBadges.config(doc, str(cid)).get("name", original.get("display_name", cid)))] = true
	for c: Dictionary in doc.get("new_cities", []):
		used[str(c.get("name", ""))] = true
	return used


## 自动补城（3.12.5，确定性）：挑宿主、名字、原型、特产（含第 4 步的原型和特产兜底）、位置。
## placer: Callable(host: String, route_type: String) -> Dictionary，返回 {x, z, rotation, route} 或 {}（放不下）；
## 不给时用目录的预设位。返回 {ok, city, doc, reason}：doc 是加上搭档、并规范化槽位之后的新文档（原 doc 不动）
static func pick_auto_partner(base: Dictionary, doc: Dictionary, user_slot: String, catalogue: Dictionary, placer: Callable) -> Dictionary:
	var me := _city_by_slot(doc, user_slot)
	if me.is_empty():
		return {"ok": false, "city": {}, "doc": doc, "reason": "找不到槽位 %s 的城" % user_slot}
	var work := doc.duplicate(true)
	var cities: Array = work.get("new_cities", [])
	# 旧搭档（换宿主后重选时）先拿掉，但记下它的名字、样子、特产，能保留的保留（3.12.5「换宿主」）
	var old_partner := _city_by_slot(work, str(me.get("partner", "")))
	if not old_partner.is_empty():
		cities.erase(old_partner)
	var side := side_of_host(base, str(me.get("host", "")))
	var other := "E" if side == "W" else "W"
	var chosen: Dictionary = {}
	var placement: Dictionary = {}
	for cand in legal_partner_hosts(base, work, user_slot):
		var pl: Dictionary = _place(catalogue, placer, str(cand["host"]), str(cand["route_type"]))
		if not pl.is_empty():
			chosen = cand
			placement = pl
			break
	if chosen.is_empty():
		return {"ok": false, "city": {}, "doc": doc, "reason": "另一侧没有放得下搭档的宿主"}
	var host := str(chosen["host"])
	var rt := str(chosen["route_type"])
	# 名字：补城名单里本图第一个没用过的 → 同侧第一个没用过的「认得的名字」
	var used_names := used_city_names(base, work)
	var entry: Dictionary = {}
	if not old_partner.is_empty() and not used_names.has(str(old_partner.get("name", ""))):
		entry = {"id": str(old_partner.get("name_entry", "")), "name": str(old_partner.get("name", "")),
			"archetype": str(old_partner.get("archetype", "")), "specialty": str(old_partner.get("specialty", ""))}
	if entry.is_empty():
		for id in CustomMapCatalogue.partner_pool(catalogue, host, rt):
			var k := CustomMapCatalogue.known_by_id(catalogue, str(id))
			if not k.is_empty() and not used_names.has(str(k.get("name", ""))):
				entry = k
				break
	if entry.is_empty():
		for k in catalogue.get("known_names", []):
			if k is Dictionary and str(k.get("side_hint", "")) == other and bool(k.get("auto_pick", false)) and not used_names.has(str(k.get("name", ""))):
				entry = k
				break
	if entry.is_empty():
		return {"ok": false, "city": {}, "doc": doc, "reason": "补城名单里的名字都用完了"}
	# 原型：名字条目的默认值；不可提供、或不适配这种交通 → 同侧第一个可提供且适配的 → 另一侧的
	var arch_id := str(entry.get("archetype", ""))
	var arch := CustomMapCatalogue.archetype(catalogue, arch_id)
	if arch.is_empty() or not CustomMapCatalogue.is_offered(arch) or not rt in (arch.get("fits", []) as Array):
		arch_id = CustomMapCatalogue.first_fit_in(catalogue, other, rt, [])
		if arch_id == "":
			arch_id = CustomMapCatalogue.first_fit_in(catalogue, side, rt, [])
	if arch_id == "":
		return {"ok": false, "city": {}, "doc": doc, "reason": "目录里没有能用的样子"}
	# 特产：名字条目的默认值；不可提供或已被本图占用 → 同侧特产表里下一个可提供、没用过的 → 另一侧的
	var used_spec := {}
	for c in cities:
		used_spec[str(c.get("specialty", ""))] = true
	var spec := _pick_specialty(catalogue, str(entry.get("specialty", "")), other, used_spec)
	if spec == "":
		spec = _pick_specialty(catalogue, "", side, used_spec)
	if spec == "":
		return {"ok": false, "city": {}, "doc": doc, "reason": "目录里没有能用的特产"}
	var slot := _free_slot(cities, "e" if other == "E" else "w")
	var city := {
		"slot": slot, "origin": "AUTO", "partner": user_slot,
		"name": str(entry.get("name", "")), "name_entry": str(entry.get("id", "")),
		"archetype": arch_id, "specialty": spec,
		"host": host, "route_type": rt,
		"x": float(placement.get("x", 0.0)), "z": float(placement.get("z", 0.0)),
		"rotation": float(placement.get("rotation", 0.0)), "size": float(placement.get("size", 1.0)),
		"route": (placement.get("route", {"handles": [], "stop_t": [0.333, 0.667]}) as Dictionary).duplicate(true),
		"text": {"mode": "AUTO"},
	}
	for c in cities:
		if str(c.get("slot", "")) == user_slot:
			c["partner"] = slot
	cities.append(city)
	work["new_cities"] = cities
	var canon := CustomMapSchema.canonicalize_slots(work, base)
	var placed := {}
	for c in canon.get("new_cities", []):
		if str(c.get("host", "")) == host and str(c.get("origin", "")) == "AUTO" and str(c.get("name", "")) == str(city["name"]):
			placed = c
	return {"ok": true, "city": placed if not placed.is_empty() else city, "doc": canon, "reason": ""}


static func _pick_specialty(catalogue: Dictionary, preferred: String, side: String, used: Dictionary) -> String:
	var pref := CustomMapCatalogue.specialty(catalogue, preferred)
	if not pref.is_empty() and CustomMapCatalogue.is_offered(pref) and not used.has(preferred):
		return preferred
	var keys := CustomMapCatalogue.specialties_of_side(catalogue, side)
	var start := maxi(0, keys.find(preferred))
	for i in keys.size():
		var key := keys[(start + i) % keys.size()]
		var s := CustomMapCatalogue.specialty(catalogue, key)
		if CustomMapCatalogue.is_offered(s) and not used.has(key):
			return key
	return ""


static func _place(catalogue: Dictionary, placer: Callable, host: String, route_type: String) -> Dictionary:
	if placer.is_valid():
		var r: Variant = placer.call(host, route_type)
		return r if r is Dictionary else {}
	var presets := CustomMapCatalogue.preset_slots(catalogue, host, route_type)
	return (presets[0] as Dictionary).duplicate(true) if not presets.is_empty() and presets[0] is Dictionary else {}


static func _free_slot(cities: Array, letter: String) -> String:
	var taken := {}
	for c in cities:
		taken[str(c.get("slot", ""))] = true
	for i in range(1, 9):
		var s := "%s%d" % [letter, i]
		if not taken.has(s):
			return s
	return letter + "9"


## 孩子起的名字和系统搭档（origin = AUTO）重名时，孩子的名字优先：搭档换成它名单里下一个没用过的名字（R29）。
## 只管 AUTO 的城；和原城、或和孩子自己加的另一座城重名，这里不动，由校验器报 E_NAME_DUP。
## 返回 {doc, renamed: [{slot, from, to}]}（原 doc 不动）
static func rename_auto_on_conflict(doc: Dictionary, catalogue: Dictionary, wanted: String, base: Dictionary = {}) -> Dictionary:
	var work := doc.duplicate(true)
	var cities: Array = work.get("new_cities", [])
	var renamed: Array = []
	for c in cities:
		if str(c.get("origin", "")) != "AUTO" or str(c.get("name", "")) != wanted:
			continue
		var used := used_city_names(base, work)
		used[wanted] = true
		var side := "E" if str(c.get("slot", "")).begins_with("e") else "W"
		var next := ""
		for id in CustomMapCatalogue.partner_pool(catalogue, str(c.get("host", "")), str(c.get("route_type", ""))):
			var k := CustomMapCatalogue.known_by_id(catalogue, str(id))
			if not k.is_empty() and not used.has(str(k.get("name", ""))):
				next = str(k.get("name", ""))
				c["name_entry"] = str(k.get("id", ""))
				break
		if next == "":
			for k in catalogue.get("known_names", []):
				if k is Dictionary and str(k.get("side_hint", "")) == side and bool(k.get("auto_pick", false)) and not used.has(str(k.get("name", ""))):
					next = str(k.get("name", ""))
					c["name_entry"] = str(k.get("id", ""))
					break
		if next == "":
			continue
		renamed.append({"slot": str(c.get("slot", "")), "from": wanted, "to": next})
		c["name"] = next
	work["new_cities"] = cities
	return {"doc": work, "renamed": renamed}


# ---------------------------------------------------------------- 拓扑检查

## 拓扑检查：返回 [{code, target, kid, tech}]，没有问题时为空。params 见 params()
static func check_topology(base: Dictionary, doc: Dictionary, params: Dictionary) -> Array[Dictionary]:
	if CustomMapFreeAuthor.enabled(doc):return CustomMapFreeRoutes.check(base,doc)
	if CustomMapFreeRoutes.enabled(doc):
		var legacy:=check_topology(base,CustomMapFreeRoutes.clean(doc),params)
		if not legacy.is_empty():return legacy
		return CustomMapFreeRoutes.check(base,doc)
	var errs: Array[Dictionary] = []
	var p := CustomMapRules.params()
	for k in params.keys():
		p[k] = params[k]
	var max_pairs := int(p.get("max_pairs", DEFAULT_MAX_PAIRS))
	var max_user := int(p.get("max_user", max_pairs))
	var min_steps := int(p.get("pair_min_host_steps", PAIR_MIN_HOST_STEPS))
	var sym_max := float(p.get("pair_sym_max", PAIR_SYM_MAX))
	_check_moves(base, doc, errs)
	var cities: Array = doc.get("new_cities", []) if doc.get("new_cities") is Array else []
	# 数量（R8）：新城总数 ≤ 2 × max_pairs；亲手加的 ≤ max_user
	var users := 0
	for c in cities:
		if c is Dictionary and str(c.get("origin", "")) == "USER":
			users += 1
	if cities.size() > 2 * max_pairs:
		_err(errs, "E_USER_MAX", "new_cities", "新城 %d 座，最多 %d 座" % [cities.size(), 2 * max_pairs])
	elif users > max_user:
		_err(errs, "E_USER_MAX", "new_cities", "亲手加了 %d 座，最多 %d 座" % [users, max_user])
	var by_slot := {}
	var host_uses := {}
	var host_ok := {}
	for c in cities:
		if not c is Dictionary:
			_err(errs, "E_SCHEMA", "new_cities", "新城条目不是对象")
			continue
		var slot := str(c.get("slot", ""))
		if not slot in CustomMapSchema.SLOTS or by_slot.has(slot):
			_err(errs, "E_SIDE", slot, "槽位 %s 不对或重复" % slot)
			continue
		by_slot[slot] = c
		var origin := str(c.get("origin", ""))
		if origin != "USER" and origin != "AUTO":
			_err(errs, "E_USER_MAX", slot, "origin 只能是 USER / AUTO：%s" % origin)
		# 新城只有一种交通、不换乘（R7）
		var rt: Variant = c.get("route_type")
		if not (rt is String and (rt == LAND or rt == SEA)) or bool(c.get("is_transport_interchange", false)) or c.has("allowed_routes"):
			_err(errs, "E_INTERCHANGE", slot, "新城只能有一种交通、不能换乘：route_type=%s" % str(rt))
			continue
		# 只做叶子（R5）：宿主必须是一座原城，不能是新城，也不能连两座城
		var host_v: Variant = c.get("host")
		if not host_v is String:
			_err(errs, "E_LEAF", slot, "新城只能连一座城：host=%s" % str(host_v))
			continue
		var host := String(host_v)
		if host.begins_with("x_") or host in CustomMapSchema.SLOTS:
			_err(errs, "E_LEAF", slot, "新城不能接在新城上：%s" % host)
			continue
		if not is_original_city(base, host):
			_err(errs, "E_HOST", slot, "宿主不是原版的城：%s" % host)
			continue
		if c.has("host_interchange") and (not c.host_interchange is bool or (c.host_interchange and not cairo_land_extension(c))):
			_err(errs, "E_INTERCHANGE", slot, "宿主扩展仅允许开罗明确接入陆路并换乘")
			continue
		if not _host_ok(base, host, String(rt)) and not (cairo_land_extension(c) and host_degree(base, host) <= HOST_MAX_DEGREE):
			var city: Dictionary = base["cities"][host]
			if not String(rt) in (city.get("allowed_routes", []) as Array):
				_err(errs, "E_HOST", slot, "%s 没有%s" % [host, "陆路" if rt == LAND else "海路"])
			else:
				_err(errs, "E_HOST", slot, "%s 已经连了 %d 条路" % [host, host_degree(base, host)])
			continue
		host_uses[host] = int(host_uses.get(host, 0)) + 1
		if int(host_uses[host]) == 2:
			_err(errs, "E_HOST", slot, "一座原城最多挂 1 座新城：%s" % host)
			continue
		host_ok[slot] = true
		# 停靠点：每条新商道恰好 2 个（R5）
		var route: Variant = c.get("route", {})
		var stop_t: Variant = (route as Dictionary).get("stop_t", []) if route is Dictionary else null
		if not stop_t is Array or (stop_t as Array).size() != 2:
			_err(errs, "E_CORRIDOR", slot, "新商道要恰好 2 个停靠点：%s" % str(stop_t))
	for c: Dictionary in cities:
		var links: Variant = c.get("extra_connections", [])
		if not links is Array or links.size() > 1:
			_err(errs, "E_HOST", str(c.slot), "额外连接至多一条")
			continue
		for link in links:
			if not link is Dictionary or not is_original_city(base, str(link.get("host", ""))):
				_err(errs, "E_HOST", str(c.slot), "额外宿主必须是原城")
				continue
			var h := str(link.host)
			var rt := str(link.get("route_type", ""))
			if h == str(c.host) or rt != str(c.route_type) or not rt in base.cities[h].allowed_routes or host_degree(base, h) > 4:
				_err(errs, "E_HOST", str(c.slot), "额外宿主需不同、同交通、原度数至多4")
			if not link.get("route", {}) is Dictionary or (link.get("route", {}).get("stop_t", []) as Array).size() != 2:
				_err(errs, "E_CORRIDOR", str(c.slot), "额外商道要两个停靠点")
	# 成对（R8、R9）
	if cities.size() % 2 == 1 and by_slot.size() == cities.size():
		_err(errs, "E_SIDE", "new_cities", "新城要成对：%d 座" % cities.size())
	var dist := base_distances(base)
	var avg := average_steps(base)
	var done := {}
	for slot in by_slot.keys():
		if done.has(slot):
			continue
		var c: Dictionary = by_slot[slot]
		var ps := str(c.get("partner", ""))
		if not by_slot.has(ps) or ps == slot or str((by_slot[ps] as Dictionary).get("partner", "")) != slot:
			_err(errs, "E_SIDE", slot, "搭档没有互指：%s ↔ %s" % [slot, ps])
			done[slot] = true
			continue
		done[slot] = true
		done[ps] = true
		if not (host_ok.has(slot) and host_ok.has(ps)):
			continue
		var h1 := str(c.get("host", ""))
		var h2 := str((by_slot[ps] as Dictionary).get("host", ""))
		var s1 := side_of_host(base, h1)
		var s2 := side_of_host(base, h2)
		if s1 == s2:
			_err(errs, "E_SIDE", slot, "一对新城要一东一西：%s、%s 都在%s边" % [h1, h2, "西" if s1 == "W" else "东"])
			continue
		if (s1 == "W") != String(slot).begins_with("w") or (s2 == "W") != ps.begins_with("w"):
			_err(errs, "E_SIDE", slot, "槽位不规范：%s 挂在%s边" % [slot, "西" if s1 == "W" else "东"])
			continue
		var steps := int((dist.get(h1, {}) as Dictionary).get(h2, 999))
		if steps < min_steps:
			_err(errs, "E_PAIR_DIST", slot, "两座宿主只隔 %d 步，至少 %d 步" % [steps, min_steps])
		var diff := absf(float(avg.get(h1, 0.0)) - float(avg.get(h2, 0.0)))
		if diff > sym_max + 1e-9:
			_err(errs, "E_PAIR_SYM", slot, "两座宿主的平均步数差 %.2f，最多 %.1f" % [diff, sym_max])
	# 两对时槽位要按西侧宿主 id 排（3.4）
	if errs.is_empty():
		var canon := CustomMapSchema.canonicalize_slots(doc, base)
		if CustomMapSchema.topology_key(canon) != CustomMapSchema.topology_key(doc):
			_err(errs, "E_SIDE", "new_cities", "槽位不规范：应为 %s" % CustomMapSchema.topology_key(canon))
	# 按程序推导出的整张图再查一遍（叶子、商道结构、原图步数矩阵）
	if errs.is_empty():
		errs.append_array(check_graph(base, build_graph(base, doc)))
	return errs


## moves 段（R10）：只允许原城 id / 原商道 id，只允许位置、朝向、路线形状、停靠点比例
static func _check_moves(base: Dictionary, doc: Dictionary, errs: Array[Dictionary]) -> void:
	var moves: Variant = doc.get("moves", {})
	if moves == null:
		return
	if not moves is Dictionary:
		_err(errs, "E_ORIGINAL_EDIT", "moves", "moves 不是对象")
		return
	for key in (moves as Dictionary).keys():
		if key != "cities" and key != "routes":
			_err(errs, "E_ORIGINAL_EDIT", "moves.%s" % key, "moves 里只能有 cities、routes")
	var mc: Variant = (moves as Dictionary).get("cities", {})
	if mc is Dictionary:
		for id in (mc as Dictionary).keys():
			var entry: Variant = mc[id]
			if not is_original_city(base, str(id)) or not entry is Dictionary:
				_err(errs, "E_ORIGINAL_EDIT", "moves.cities.%s" % id, "只能挪原版的 16 座城：%s" % id)
				continue
			for f in (entry as Dictionary).keys():
				if not str(f) in MOVE_CITY_FIELDS:
					_err(errs, "E_ORIGINAL_EDIT", "moves.cities.%s.%s" % [id, f], "原城只能改位置和朝向，不能改 %s" % f)
	elif mc != null:
		_err(errs, "E_ORIGINAL_EDIT", "moves.cities", "moves.cities 不是对象")
	var mr: Variant = (moves as Dictionary).get("routes", {})
	var corridors := _base_corridor_ids(base)
	if mr is Dictionary:
		for id in (mr as Dictionary).keys():
			var entry: Variant = mr[id]
			if not corridors.has(str(id)) or not entry is Dictionary:
				_err(errs, "E_ORIGINAL_EDIT", "moves.routes.%s" % id, "只能改原版 19 条商道的弯法：%s" % id)
				continue
			for f in (entry as Dictionary).keys():
				if not str(f) in MOVE_ROUTE_FIELDS:
					_err(errs, "E_ORIGINAL_EDIT", "moves.routes.%s.%s" % [id, f], "原版商道只能改弯法和停靠点，不能改 %s" % f)
	elif mr != null:
		_err(errs, "E_ORIGINAL_EDIT", "moves.routes", "moves.routes 不是对象")


static func _base_corridor_ids(base: Dictionary) -> Dictionary:
	var out := {}
	for e in base.get("board_edges", []):
		out[str(e.get("corridor_id", ""))] = true
	return out


# ---------------------------------------------------------------- 图：推导与检查

## 按基础包 + 覆盖层推导出整张图（规则层用；坐标由 CustomMapLoader 另算）：
## {nodes: {id: {kind, city_id, routes, interchange}}, edges: [{id, a, b, route_type, corridor_id, corridor_step_index}]}。
## 每座合格的新城接 1 条新商道：宿主 — <商道>_01 — <商道>_02 — 新城，3 条同类型的边（R5、3.4）
static func build_graph(base: Dictionary, doc: Dictionary) -> Dictionary:
	if CustomMapFreeRoutes.enabled(doc):return CustomMapFreeRoutes.graph(base,doc)
	var nodes := {}
	var cities: Dictionary = base.get("cities", {})
	for n in (base.get("board_nodes", {}) as Dictionary).values():
		var id := str(n.get("id", ""))
		if str(n.get("node_type", "")) == "CITY":
			var c: Dictionary = cities.get(str(n.get("city_id", id)), {})
			nodes[id] = {"kind": "CITY", "city_id": str(n.get("city_id", id)), "routes": (c.get("allowed_routes", []) as Array).duplicate(),
				"interchange": bool(c.get("is_transport_interchange", false))}
		else:
			nodes[id] = {"kind": "ROAD", "city_id": "", "routes": [], "interchange": false}
	if has_cairo_land_extension(doc):
		var host_node := str(base.cities.cairo.get("board_node_id", "cairo"))
		nodes[host_node].routes = [SEA, LAND]
		nodes[host_node].interchange = true
	var edges: Array = []
	for e in base.get("board_edges", []):
		edges.append({"id": str(e.get("id", "")), "a": str(e.get("a", "")), "b": str(e.get("b", "")), "route_type": str(e.get("route_type", "")),
			"corridor_id": str(e.get("corridor_id", "")), "corridor_step_index": int(e.get("corridor_step_index", 0))})
		for end in [str(e.get("a", "")), str(e.get("b", ""))]:
			if nodes.has(end) and nodes[end]["kind"] == "ROAD" and not str(e.get("route_type", "")) in nodes[end]["routes"]:
				(nodes[end]["routes"] as Array).append(str(e.get("route_type", "")))
	var cities_doc: Array = CustomMapSchema.corridor_entries(doc)
	for c in cities_doc:
		if not c is Dictionary:
			continue
		var slot := str(c.get("slot", ""))
		var host_v: Variant = c.get("host")
		var rt := str(c.get("route_type", ""))
		if not slot in CustomMapSchema.SLOTS or not host_v is String or not is_original_city(base, String(host_v)) or (rt != LAND and rt != SEA):
			continue
		var host := String(host_v)
		var host_node := str((cities[host] as Dictionary).get("board_node_id", host))
		var cid := CustomMapSchema.city_id(slot)
		var corridor := CustomMapSchema.corridor_id(slot, host, rt)
		var r1 := corridor + "_01"
		var r2 := corridor + "_02"
		nodes[cid] = {"kind": "CITY", "city_id": cid, "routes": [rt], "interchange": false}
		nodes[r1] = {"kind": "ROAD", "city_id": "", "routes": [rt], "interchange": false}
		nodes[r2] = {"kind": "ROAD", "city_id": "", "routes": [rt], "interchange": false}
		var chain := [host_node, r1, r2, cid]
		for i in 3:
			edges.append({"id": CustomMapSchema.edge_id(chain[i], chain[i + 1], rt), "a": chain[i], "b": chain[i + 1], "route_type": rt,
				"corridor_id": corridor, "corridor_step_index": i + 1})
	return {"nodes": nodes, "edges": edges}


## 整张图的检查（R5、R7）：原 57 条边逐条相等、原城之间没有新边、16×16 最短步数矩阵逐格相等（E_BASE_GRAPH）；
## 每座新城度数 1、只连一座原城（E_LEAF）；每条新商道恰好 2 个度数为 2 的 ROAD 节点、id 是 <商道>_01/_02、
## 步序 1..3、3 条边同类型（E_CORRIDOR）；新节点不换乘、只有一种交通（E_INTERCHANGE）
static func check_graph(base: Dictionary, graph: Dictionary) -> Array[Dictionary]:
	var errs: Array[Dictionary] = []
	var nodes: Dictionary = graph.get("nodes", {})
	var edges: Array = graph.get("edges", [])
	var base_nodes: Dictionary = base.get("board_nodes", {})
	var base_keys := {}
	for e in base.get("board_edges", []):
		base_keys["%s|%s|%s|%s" % [str(e.get("id", "")), str(e.get("a", "")), str(e.get("b", "")), str(e.get("route_type", ""))]] = true
	var seen := {}
	var adj := {}
	for e in edges:
		var key := "%s|%s|%s|%s" % [str(e["id"]), str(e["a"]), str(e["b"]), str(e["route_type"])]
		if base_keys.has(key):
			seen[key] = true
		elif base_nodes.has(str(e["a"])) and base_nodes.has(str(e["b"])):
			_err(errs, "E_BASE_GRAPH", str(e["id"]), "两座原有节点之间不能加路：%s—%s" % [e["a"], e["b"]])
		for end in [str(e["a"]), str(e["b"])]:
			if not adj.has(end):
				adj[end] = []
		(adj[str(e["a"])] as Array).append(e)
		(adj[str(e["b"])] as Array).append(e)
	if seen.size() != base_keys.size():
		_err(errs, "E_BASE_GRAPH", "board_edges", "原版的边少了 %d 条" % (base_keys.size() - seen.size()))
	# 新节点
	for id in nodes.keys():
		var nid := str(id)
		if base_nodes.has(nid):
			continue
		var n: Dictionary = nodes[nid]
		if bool(n.get("interchange", false)) or (n.get("routes", []) as Array).size() != 1:
			_err(errs, "E_INTERCHANGE", nid, "新节点只能有一种交通、不能换乘")
		if str(n.get("kind", "")) != "CITY":
			continue
		var inc: Array = adj.get(nid, [])
		if inc.size() < 1 or inc.size() > 2:
			_err(errs, "E_LEAF", nid, "新城只能连 1–2 条路，现在 %d 条" % inc.size())
			continue
		for e3: Dictionary in inc:
			var corridor := str(e3.get("corridor_id", ""))
			var rt := str(e3.get("route_type", ""))
			var r2 := str(e3["a"]) if str(e3["b"]) == nid else str(e3["b"])
			var r1 := ""
			var host := ""
			var ok := r2 == corridor + "_02" and int(e3.get("corridor_step_index", 0)) == 3
			if ok and nodes.has(r2) and (adj.get(r2, []) as Array).size() == 2:
				for e in adj[r2]:
					if e != e3:
						r1 = str(e["a"]) if str(e["b"]) == r2 else str(e["b"])
						ok = ok and int(e.get("corridor_step_index", 0)) == 2 and str(e.get("route_type", "")) == rt and str(e.get("corridor_id", "")) == corridor
			else:
				ok = false
			if ok and r1 == corridor + "_01" and nodes.has(r1) and (adj.get(r1, []) as Array).size() == 2:
				for e in adj[r1]:
					var other := str(e["a"]) if str(e["b"]) == r1 else str(e["b"])
					if other != r2:
						host = other
						ok = ok and int(e.get("corridor_step_index", 0)) == 1 and str(e.get("route_type", "")) == rt and str(e.get("corridor_id", "")) == corridor
			else:
				ok = false
			if not ok:
				_err(errs, "E_CORRIDOR", nid, "新商道要是 宿主—%s_01—%s_02—新城，3 步同类型" % [corridor, corridor])
				continue
			if not base_nodes.has(host) or str((base_nodes[host] as Dictionary).get("node_type", "")) != "CITY":
				_err(errs, "E_LEAF", nid, "新城要接在一座原城上：%s" % host)
	for id in nodes.keys():
		var nid := str(id)
		if base_nodes.has(nid) or str((nodes[nid] as Dictionary).get("kind", "")) != "ROAD":
			continue
		if (adj.get(nid, []) as Array).size() != 2:
			_err(errs, "E_CORRIDOR", nid, "道路点的度数要是 2")
	# 原城 16×16 最短步数矩阵
	if errs.is_empty():
		var want := base_distances(base)
		var got := city_distances(graph)
		for a in want.keys():
			for b in (want[a] as Dictionary).keys():
				if int((got.get(a, {}) as Dictionary).get(b, -1)) != int(want[a][b]):
					_err(errs, "E_BASE_GRAPH", "%s-%s" % [a, b], "原城 %s→%s 的步数变了：%s → %s" % [a, b, want[a][b], (got.get(a, {}) as Dictionary).get(b, "不通")])
					return errs
	return errs


## 交通规则下的城市间最短步数（同 deck_gen.py:119-157）：状态 = (节点, 交通)；骆驼只走陆路、商船只走海路，
## 只有换乘城能 0 步换乘。返回 {城 id: {城 id: 步数}}（城 id 取节点的 city_id）
static func city_distances(graph: Dictionary) -> Dictionary:
	var nodes: Dictionary = graph.get("nodes", {})
	var adj := {}
	for e in graph.get("edges", []):
		var a := str(e["a"])
		var b := str(e["b"])
		var t := str(e["route_type"])
		if not adj.has(a):
			adj[a] = []
		if not adj.has(b):
			adj[b] = []
		(adj[a] as Array).append([b, t])
		(adj[b] as Array).append([a, t])
	var city_nodes := {}
	for id in nodes.keys():
		if str(nodes[id].get("kind", "")) == "CITY":
			city_nodes[str(id)] = str(nodes[id].get("city_id", id))
	var out := {}
	for src in city_nodes.keys():
		var dist := {}
		var queue: Array = []
		var routes: Array = (nodes[src].get("routes", []) as Array).duplicate()
		routes.sort()
		for t in routes:
			dist["%s|%s" % [src, t]] = 0
			queue.append([src, str(t)])
		while not queue.is_empty():
			var st: Array = queue.pop_front()
			var u := str(st[0])
			var t := str(st[1])
			var du := int(dist["%s|%s" % [u, t]])
			if bool(nodes.get(u, {}).get("interchange", false)):
				for t2 in [LAND, SEA]:
					var k2 := "%s|%s" % [u, t2]
					if t2 != t and t2 in (nodes[u].get("routes", []) as Array) and (not dist.has(k2) or du < int(dist[k2])):
						dist[k2] = du
						queue.push_front([u, t2])
			for nb in adj.get(u, []):
				if str(nb[1]) != t:
					continue
				var kv := "%s|%s" % [str(nb[0]), t]
				if not dist.has(kv) or du + 1 < int(dist[kv]):
					dist[kv] = du + 1
					queue.append([str(nb[0]), t])
		var row := {}
		for nid in city_nodes.keys():
			var best := -1
			for t in [LAND, SEA]:
				var k := "%s|%s" % [nid, t]
				if dist.has(k) and (best < 0 or int(dist[k]) < best):
					best = int(dist[k])
			if best >= 0:
				row[city_nodes[nid]] = best
		out[city_nodes[src]] = row
	return out


## 基础包原城之间的最短步数（按原图签名缓存）
static func base_distances(base: Dictionary) -> Dictionary:
	var sig := CustomMapSchema.graph_sig(base)
	if not _dist_cache.has(sig):
		_dist_cache[sig] = city_distances(build_graph(base, {}))
	return _dist_cache[sig]


## 每座原城到其余原城的平均步数（R9 的「偏」）
static func average_steps(base: Dictionary) -> Dictionary:
	var dist := base_distances(base)
	var out := {}
	for a in dist.keys():
		var total := 0
		var n := 0
		for b in (dist[a] as Dictionary).keys():
			if b != a:
				total += int(dist[a][b])
				n += 1
		out[a] = float(total) / float(maxi(1, n))
	return out


# ---------------------------------------------------------------- 小工具

static func _host_ok(base: Dictionary, host: String, route_type: String) -> bool:
	if not is_original_city(base, host):
		return false
	var city: Dictionary = base["cities"][host]
	if not route_type in (city.get("allowed_routes", []) as Array):
		return false
	return host_degree(base, host) <= HOST_MAX_DEGREE


static func _used_hosts(doc: Dictionary, except_slot: String) -> Dictionary:
	var out := {}
	for c in doc.get("new_cities", []):
		if c is Dictionary and str(c.get("slot", "")) != except_slot:
			out[str(c.get("host", ""))] = true
	return out


static func _city_by_slot(doc: Dictionary, slot: String) -> Dictionary:
	for c in doc.get("new_cities", []):
		if c is Dictionary and str(c.get("slot", "")) == slot:
			return c
	return {}


static func _err(errs: Array[Dictionary], code: String, target: String, tech: String) -> void:
	errs.append({"code": code, "target": target, "kid": CustomMapValidator.kid_text(code), "tech": tech})


## 本地图获授权的开罗陆路接入：仅旧海港开罗、LAND 新城，显式声明才启用。
static func cairo_land_extension(c: Dictionary) -> bool:
	return c.get("host_interchange", false) == true and str(c.get("host", "")) == "cairo" and str(c.get("route_type", "")) == LAND

static func has_cairo_land_extension(doc: Dictionary) -> bool:
	for c in doc.get("new_cities", []):
		if c is Dictionary and cairo_land_extension(c): return true
	return false
