class_name CustomMapLoader

## 自制地图的登记（按 sha 缓存，最近一次合并用过的钉住）、合并、开局补状态、独立洗牌、签名
## （docs/design/map-editor-20260930/DESIGN.md 3.5、3.8、R1、R7、R17、R20、R22、R23）。归 WP1。
##
## 流程：先 remember(整份覆盖层) 整份校验、登记进缓存；开局选项里只放 {enabled, sha256}（ExpansionLoader 的一项），
## ExpansionLoader.apply 在趣味事件并完之后调 merge 从缓存取覆盖层并进 content。
## merge 只做「浅拷贝后追加」，从不写基础包的字典（照 expansion_loader.gd:158-163）：没有新城时规则数据一项不加。
## 开局时原版的洗牌、建供应、建市场、发城市卡全部只用基础包（setup_system.gd:259-263），随机数消耗与原版一模一样；
## 最后 init_session_state 补新货供应、新城市场，新牌堆各用自己的随机数洗（R22），不碰共享随机数。

## 缓存最多几份覆盖层；最近一次 merge 成功用过的那份钉住，永不淘汰（「再来一局」在 reset_session 之后才合并）
const CACHE_MAX := 4
## 逻辑坐标（2D 规则棋盘）= 3D 世界坐标 × 32，z 再除以 1.4（art-src/merchant-board-claude/terrain/board_common.py:25-36）
const PX_PER_UNIT := 32.0
const Z_STRETCH := 1.4
const POLYLINE_POINTS := 16
const BANK_PARAMS := "res://data/custom_map/tradegen_v1_params.json"

## 只给 P-3e 用：打开后 merge 一律失败，测 R4 的降级重试
static var test_fail_merge := false

static var _cache: Dictionary = {}      # sha → {overlay, sha256, name, map_id, topology_key, generated, texts, counts_win}
static var _order: Array[String] = []   # 最近登记 / 使用的在后
static var _pinned_sha := ""
static var _base_cache: Dictionary = {}
static var _layout_cache: Dictionary = {}


# ---------------------------------------------------------------- 登记

## 登记一份覆盖层（内部调 CustomMapValidator.validate）：{ok, sha256, name, map_id, code, message, errors}
static func remember(overlay: Dictionary) -> Dictionary:
	var base := base_content()
	var result := CustomMapValidator.validate(base, base_layout(), overlay, CustomMapCatalogue.data())
	var errors: Array = result.get("errors", [])
	if not bool(result.get("ok", false)):
		var first: Dictionary = errors[0] if not errors.is_empty() else {"code": "E_SCHEMA", "kid": CustomMapValidator.KID_FILE, "tech": ""}
		return {"ok": false, "sha256": str(result.get("sha256", "")), "name": str(overlay.get("name", "")), "map_id": str(overlay.get("map_id", "")),
			"code": str(first.get("code", "")), "message": str(first.get("kid", "")), "errors": errors}
	var sha := str(result["sha256"])
	var texts := {}
	for c in overlay.get("new_cities", []):
		texts[str(c["slot"])] = CustomMapValidator.texts_for(base, overlay, c, CustomMapCatalogue.data())
	var entry := {
		"overlay": overlay.duplicate(true),
		"sha256": sha,
		"name": str(overlay.get("name", "")),
		"map_id": str(overlay.get("map_id", "")),
		"topology_key": str(result.get("topology_key", "")),
		"generated": (result.get("generated", {}) as Dictionary).duplicate(true),
		"texts": texts,
		"counts_win": bool(result.get("counts_win", false)),
		"catalogue": CustomMapCatalogue.data(),
	}
	_cache[sha] = entry
	_touch(sha)
	return {"ok": true, "sha256": sha, "name": entry["name"], "map_id": entry["map_id"], "code": "", "message": "", "errors": []}


static func is_remembered(sha: String) -> bool:
	return _cache.has(sha)


static func _touch(sha: String) -> void:
	_order.erase(sha)
	_order.append(sha)
	while _order.size() > CACHE_MAX:
		var victim := ""
		for s in _order:
			if s != _pinned_sha:
				victim = s
				break
		if victim == "":
			break
		_order.erase(victim)
		_cache.erase(victim)


## 开局选项里地图那一项的形状
static func option_for(sha: String) -> Dictionary:
	return {CustomMapSchema.OPTION_ID: {"enabled": true, "sha256": sha}}


## 测试之间复位
static func clear_for_tests() -> void:
	_cache.clear()
	_order.clear()
	_pinned_sha = ""
	test_fail_merge = false


## 校验、合并用的基础包（正式规则集，读一次缓存；只读）
static func base_content() -> Dictionary:
	if _base_cache.is_empty():
		_base_cache = GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	return _base_cache


## 原布局（几何规则用；WP3 合入之前用不到，不读）
static func base_layout() -> Dictionary:
	if not CustomMapValidator.geometry_ready():
		return {}
	if _layout_cache.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CustomMapSchema.BASE_LAYOUT_PATH))
		_layout_cache = parsed if parsed is Dictionary else {}
	return _layout_cache


# ---------------------------------------------------------------- 合并

## 把登记过的覆盖层并进 merged（ExpansionLoader.apply 建好的浅拷贝；基础包的字典一个都不写）：{success, message}。
## 成功时把 sha 钉住（_pinned_sha）
static func merge(merged: Dictionary, base: Dictionary, option: Dictionary) -> Dictionary:
	if test_fail_merge:
		return {"success": false, "message": "自制地图合并失败（测试钩子）"}
	var sha := str(option.get("sha256", ""))
	if not _cache.has(sha):
		return {"success": false, "message": "自制地图没有登记：%s" % sha.left(12)}
	var entry: Dictionary = _cache[sha]
	return _merge_entry(merged,base,entry,sha,true)

static func _merge_entry(merged:Dictionary,base:Dictionary,entry:Dictionary,sha:String,pin:bool)->Dictionary:
	var overlay: Dictionary = entry["overlay"]
	var catalogue: Dictionary = entry.get("catalogue", {})
	var cities: Array = (overlay.get("new_cities", []) as Array).duplicate(true)
	cities.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["slot"]) < str(b["slot"]))
	var n := cities.size()
	# 规则集：只有银库 k ≠ 0 时改人数对应的银库（R20）；expected_counts 不动（只在校验基础包时用）
	var ruleset: Dictionary = (base.get("ruleset", {}) as Dictionary).duplicate(false)
	var k := bank_delta_per_city(str(overlay.get("tradegen", "")))
	if n > 0 and not k.is_empty():
		var supply: Dictionary = (ruleset.get("silver_supply_by_player_count", {}) as Dictionary).duplicate(false)
		for key in supply.keys():
			supply[key] = int(supply[key]) + int(k.get(str(key), 0)) * n
		ruleset["silver_supply_by_player_count"] = supply
	merged["ruleset"] = ruleset
	var new_city_ids: Array[String] = []
	var new_deck_ids: Array[String] = []
	var new_good_ids: Array[String] = []
	var new_cities_flag := {}
	var summary: Array = []
	if n > 0:
		for key in ["goods", "nations", "cities", "city_cards", "board_nodes", "edges_from", "city_by_node", "trade_decks",
				"trade_card_index", "illustrations", "city_lore", "card_text_cities"]:
			merged[key] = (base.get(key, {}) as Dictionary).duplicate(false)
		merged["board_edges"] = (base.get("board_edges", []) as Array).duplicate(false)
		if CustomMapRules.has_cairo_land_extension(overlay):
			var host_node := str(base.cities.cairo.get("board_node_id", "cairo"))
			merged.cities.cairo = (base.cities.cairo as Dictionary).duplicate(true)
			merged.cities.cairo.allowed_routes = ["SEA", "LAND"]
			merged.cities.cairo.is_transport_interchange = true
			merged.cities.cairo.map_attribute = "海陆换乘城市"
			merged.board_nodes[host_node] = (base.board_nodes[host_node] as Dictionary).duplicate(true)
			merged.board_nodes[host_node].allowed_routes = ["SEA", "LAND"]
			merged.board_nodes[host_node].is_transport_interchange = true
			merged.board_nodes[host_node].route_anchors["LAND"] = base.board_nodes[host_node].map_position
		var decks_by_id := {}
		for d in (entry.get("generated", {}) as Dictionary).get("decks", []):
			decks_by_id[str(d["id"])] = d
		for c in cities:
			var slot := str(c["slot"])
			var cid := CustomMapSchema.city_id(slot)
			var did := CustomMapSchema.deck_id(slot)
			var types:Array=CustomMapFreeAuthor.routes_for(base,overlay,CustomMapSchema.city_id(str(c.slot))) if CustomMapFreeAuthor.enabled(overlay) else [str(c["route_type"])]
			var rt := "LAND" if "LAND" in types or types.is_empty() else "SEA"
			var host := str(c.get("host", ""))
			var spec_key := str(c["specialty"])
			var gid := CustomMapSchema.good_id(slot, spec_key)
			var ill_id := CustomMapSchema.illustration_id(slot)
			var arch := CustomMapCatalogue.archetype(catalogue, str(c.get("archetype", "")))
			var spec := CustomMapCatalogue.specialty(catalogue, spec_key)
			var texts: Dictionary = (entry.get("texts", {}) as Dictionary).get(slot, {})
			var transport := "CAMEL" if rt == "LAND" else "SHIP"
			var pos := Vector2(float(c.get("x", 0.0)) * PX_PER_UNIT, float(c.get("z", 0.0)) * PX_PER_UNIT / Z_STRETCH)
			merged["goods"][gid] = {"id": gid, "display_name": str(spec.get("display_name", spec_key)), "supply_total": 10,
				"sprite": CustomMapLocalAssets.bound_path(overlay, slot, "good_icon", str(spec.get("icon", "")))}
			merged["nations"][cid] = {"id": cid, "display_name": str(c.get("name", "")), "primary_city_id": cid}
			merged["cities"][cid] = {
				"id": cid, "display_name": str(c.get("name", "")), "nation_id": cid, "city_card_id": cid, "board_node_id": cid,
				"node_type": "CITY", "starting_transport": transport, "allowed_routes": types, "is_transport_interchange": types.size()>1,
				"map_attribute": "陆地城市" if rt == "LAND" else "海上城市", "trade_color_id": did,
				"map_position": [pos.x, pos.y], "illustration_id": ill_id,
			}
			merged["city_cards"][cid] = {
				"id": cid, "city_id": cid, "card_number": int(CustomMapSchema.CARD_NUMBERS.get(slot, 0)), "starting_transport": transport,
				"starting_grant": {"entries": [] if CustomMapFreeAuthor.enabled(overlay) and spec.is_empty() else [{"resource_kind": "GOOD", "resource_id": gid, "quantity": 1}]}, "illustration_id": ill_id,
			}
			if CustomMapFreeAuthor.enabled(overlay):
				var anchors:Dictionary={}
				for medium:String in types:anchors[medium]=pos
				merged.board_nodes[cid]={"id":cid,"node_type":"CITY","city_id":cid,"map_position":pos,"position_px":[pos.x,pos.y],"route_anchors":anchors,"allowed_routes":types,"is_transport_interchange":types.size()>1,"presentation_stop_id":cid}
				merged.city_by_node[cid]=cid
			for corridor_city: Dictionary in ([] if CustomMapFreeAuthor.enabled(overlay) else CustomMapSchema.corridor_entries({"new_cities": [c]})):
				_append_corridor(merged, base, corridor_city, pos)
			var deck: Dictionary = decks_by_id.get(did, {})
			var card_map := {}
			for card in deck.get("cards", []):
				var cd := (card as Dictionary).duplicate(true)
				card_map[str(cd["id"])] = cd
				merged["trade_card_index"][str(cd["id"])] = did
			merged["trade_decks"][did] = {"id": did, "city_ids": [cid], "shared_by_city_pair": false, "draw_order": "SHUFFLED", "cards": card_map}
			merged["illustrations"][ill_id] = {
				"id": ill_id, "entity_type": "CITY", "entity_id": cid, "formal_owner_id": cid,
				"runtime_path": CustomMapCatalogue.card_art_for(arch, rt), "art_review_status": "custom_map_archetype", "asset_role": "CITY_ILLUSTRATION",
			}
			var lore: Dictionary = (texts.get("lore", {}) as Dictionary).duplicate(true)
			lore["id"] = cid
			lore["city_id"] = cid
			merged["city_lore"][cid] = lore
			merged["card_text_cities"][cid] = {"id": cid, "city_id": cid, "intro": str(texts.get("intro", "")), "scenery": str(texts.get("scenery", ""))}
			new_city_ids.append(cid)
			new_deck_ids.append(did)
			new_good_ids.append(gid)
			new_cities_flag[cid] = true
			summary.append({"id": cid, "slot": slot, "name": str(c.get("name", "")), "origin": str(c.get("origin", "")), "host": host,
				"route_type": rt, "side": CustomMapRules.side_of_host(base, host)})
	if CustomMapFreeRoutes.enabled(overlay):CustomMapFreeRoutes.apply_content(merged,base,overlay,catalogue)
	if CustomMapFreeAuthor.enabled(overlay):
		merged.cities=merged.cities.duplicate(false)
		for cid:String in overlay.get("transport_overrides",{}):
			merged.cities[cid]=merged.cities[cid].duplicate(true)
			merged.cities[cid].allowed_routes=overlay.transport_overrides[cid].routes.duplicate()
			merged.cities[cid].is_transport_interchange=overlay.transport_overrides[cid].interchange
			merged.cities[cid].map_attribute="自由作品：海陆换乘"

	# Apply display overrides after additions/free topology finish cloning base dictionaries.
	if not overlay.get("city_badges", {}).is_empty(): merged["cities"] = merged.get("cities", {}).duplicate(false)
	for cid in overlay.get("city_badges", {}):
		var display: Dictionary = overlay.city_badges[cid]
		if display.has("name") and merged.get("cities", {}).has(cid):
			merged.cities[cid] = merged.cities[cid].duplicate(true)
			merged.cities[cid].display_name = display.name
	if overlay.has("piece_skins"):
		merged["piece_skins"] = overlay.piece_skins.transports.duplicate(true)
	if overlay.has("city_intro_cards"):
		merged["city_intro_cards"] = overlay.city_intro_cards.cards.duplicate(true)
	merged["custom_map"] = {
		"tradegen": str(overlay.get("tradegen", "")),
		"sha256": sha,
		"map_id": str(entry["map_id"]),
		"name": str(entry["name"]),
		"overlay": overlay.duplicate(true),
		"topology_key": str(entry["topology_key"]),
		"new_city_ids": new_city_ids,
		"new_deck_ids": new_deck_ids,
		"new_good_ids": new_good_ids,
		"new_cities": summary,
		"counts_win": bool(entry["counts_win"]),
		"host_route_extensions": ["cairo"] if CustomMapRules.has_cairo_land_extension(overlay) else [],
	}
	merged["custom_map_new_cities"] = new_cities_flag
	if pin:
		_pinned_sha = sha
		_touch(sha)
	return {"success": true, "message": ""}


## 一条新商道：宿主 — _01 — _02 — 新城（3 个节点、3 条边）。节点坐标和 16 点的 movement_polyline 由 3D 路线换算成
## 逻辑坐标（只给 2D 用，2D 入口不读自制地图）：宿主锚点 → 控制点 → 新城，按 stop_t 切成三段，首尾正好贴在节点上
## （game_data.gd:415-430 要求 ≤ 1 px）
static func _append_corridor(merged: Dictionary, base: Dictionary, c: Dictionary, city_pos: Vector2) -> void:
	var slot := str(c["slot"])
	var rt := str(c["route_type"])
	var host := str(c["host"])
	var cid := CustomMapSchema.city_id(slot)
	var corridor := CustomMapSchema.corridor_id(slot, host, rt)
	var host_node_id := str((base["cities"][host] as Dictionary).get("board_node_id", host))
	var host_node: Dictionary = base["board_nodes"][host_node_id]
	var anchors: Dictionary = host_node.get("route_anchors", {})
	var host_pos: Variant = anchors.get(rt, host_node.get("map_position"))
	var start: Vector2 = host_pos if host_pos is Vector2 else Vector2(float(host_pos[0]), float(host_pos[1]))
	var pts: Array[Vector2] = [start]
	var route: Dictionary = c.get("route", {}) if c.get("route") is Dictionary else {}
	for h in route.get("handles", []):
		pts.append(Vector2(float(h[0]) * PX_PER_UNIT, float(h[1]) * PX_PER_UNIT / Z_STRETCH))
	pts.append(city_pos)
	var stop_t: Array = route.get("stop_t", [0.333, 0.667])
	var t1 := clampf(float(stop_t[0]) if stop_t.size() > 0 else 0.333, 0.05, 0.9)
	var t2 := clampf(float(stop_t[1]) if stop_t.size() > 1 else 0.667, t1 + 0.05, 0.95)
	var pieces := _split_polyline(pts, [t1, t2])
	var ids := [host_node_id, corridor + "_01", corridor + "_02", cid]
	var node_pos := [start, pieces[0][pieces[0].size() - 1], pieces[1][pieces[1].size() - 1], city_pos]
	for i in range(1, 4):
		var p: Vector2 = node_pos[i]
		var is_city := i == 3
		merged["board_nodes"][ids[i]] = {
			"id": ids[i], "node_type": "CITY" if is_city else "ROAD", "city_id": cid if is_city else null,
			"map_position": p, "position_px": [p.x, p.y], "route_anchors": {rt: p}, "allowed_routes": [rt],
			"is_transport_interchange": false, "presentation_stop_id": ids[i],
		}
	merged["city_by_node"][cid] = cid
	var host_edges: Array = (merged["edges_from"].get(host_node_id, []) as Array).duplicate()
	merged["edges_from"][host_node_id] = host_edges
	for i in 3:
		var poly: Array = []
		for p in _resample(pieces[i], POLYLINE_POINTS):
			poly.append([snappedf(p.x, 0.000001), snappedf(p.y, 0.000001)])
		var edge := {
			"id": CustomMapSchema.edge_id(ids[i], ids[i + 1], rt), "a": ids[i], "b": ids[i + 1], "route_type": rt,
			"corridor_id": corridor, "corridor_step_index": i + 1,
			"movement_polyline": poly, "movement_polyline_px": poly.duplicate(true),
		}
		(merged["board_edges"] as Array).append(edge)
		for end in [ids[i], ids[i + 1]]:
			if end == host_node_id:
				host_edges.append(edge)
			else:
				if not (merged["edges_from"] as Dictionary).has(end):
					merged["edges_from"][end] = []
				(merged["edges_from"][end] as Array).append(edge)


## 把折线按弧长比例 ts 切开：返回 ts.size()+1 段，相邻两段共用切点
static func _split_polyline(pts: Array[Vector2], ts: Array) -> Array:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	var out: Array = []
	var cur: Array[Vector2] = [pts[0]]
	var walked := 0.0
	var ti := 0
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var seg := a.distance_to(b)
		while ti < ts.size() and seg > 0.0 and walked + seg >= float(ts[ti]) * total:
			var cut := a.lerp(b, clampf((float(ts[ti]) * total - walked) / seg, 0.0, 1.0))
			cur.append(cut)
			out.append(cur)
			cur = [cut]
			ti += 1
		cur.append(b)
		walked += seg
	while ti < ts.size():
		out.append(cur)
		cur = [cur[cur.size() - 1]]
		ti += 1
	out.append(cur)
	return out


## 按弧长等距重采样成 n 个点，首尾不动
static func _resample(pts: Array, n: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var total := 0.0
	for i in range(1, pts.size()):
		total += (pts[i - 1] as Vector2).distance_to(pts[i])
	if total <= 0.0:
		for i in n:
			out.append(pts[0])
		return out
	var j := 1
	var walked := 0.0
	for k in n:
		var target := total * float(k) / float(n - 1)
		if k == n - 1:
			out.append(pts[pts.size() - 1])
			break
		while j < pts.size() - 1 and walked + (pts[j - 1] as Vector2).distance_to(pts[j]) < target:
			walked += (pts[j - 1] as Vector2).distance_to(pts[j])
			j += 1
		var seg := (pts[j - 1] as Vector2).distance_to(pts[j])
		out.append((pts[j - 1] as Vector2).lerp(pts[j], clampf((target - walked) / seg, 0.0, 1.0) if seg > 0.0 else 0.0))
	return out


## 银库 k（R20）：生成器参数里的 bank_delta_per_city（WP2），默认每座新城 +0
static func bank_delta_per_city(version: String = "") -> Dictionary:
	if version != "" and not version in CustomMapTradegenRegistry.VERSIONS: return {}
	var k: Dictionary = CustomMapTradegenRegistry.contract().get("bank_delta_per_city", {})
	for key in k:
		if int(k[key]) != 0: return k.duplicate(true)
	return {}


# ---------------------------------------------------------------- 开局补状态、独立洗牌（R17、R22）

## 开局补状态：新货供应、新城市场、新牌堆用独立随机数洗（R22）；content 里没有 custom_map 时什么都不做。
## 排在 prepare_new_game 全部原版随机数消耗之后、趣味事件并堆之后（setup_system.gd:266-267）
static func init_session_state(content: Dictionary) -> void:
	if not content.has("custom_map"):
		return
	var cm: Dictionary = content["custom_map"]
	for good_id in _sorted(cm.get("new_good_ids", [])):
		GameState.goods_supply[good_id] = int(content["goods"][good_id].get("supply_total", 10))      # 10
	for city_id in _sorted(cm.get("new_city_ids", [])):
		GameState.city_market_states[city_id] = {"trade_route_open": false, "current_trade_card_id": "",
			"opened_by_player_id": "", "opened_on_turn": -1}                                     # 与 setup_system.gd:396-401 同形
	for deck_id in _sorted(cm.get("new_deck_ids", [])):
		var draw: Array = (content["trade_decks"][deck_id]["cards"] as Dictionary).keys()
		draw.sort()
		var rng := RandomNumberGenerator.new()
		rng.seed = _seed_of("%d|%s|%s" % [GameState.rng_seed, str(cm.get("topology_key", "")), deck_id])
		_fisher_yates(draw, rng)                                                              # 同 game_state.gd:157-162
		GameState.trade_decks_state[deck_id] = {"draw": draw, "discard": [], "rng_state": rng.state}


## 新牌堆抽空重洗：用牌堆自己的 rng_state，不动共享随机数；洗完写回
static func shuffle_isolated(deck_state: Dictionary, pile: Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.state = int(deck_state["rng_state"])
	_fisher_yates(pile, rng)
	deck_state["rng_state"] = rng.state


## sha256 的前 15 位十六进制：60 位，跨平台稳定
static func _seed_of(text: String) -> int:
	return text.sha256_text().substr(0, 15).hex_to_int()


static func _fisher_yates(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


static func _sorted(values: Variant) -> Array:
	var out: Array = (values as Array).duplicate() if values is Array else []
	out.sort()
	return out


# ---------------------------------------------------------------- 查询

## 这一局是不是用了自制地图
static func is_active(content: Dictionary) -> bool:
	return content.has("custom_map")


## 3D 世界签名；没地图、或者地图既没挪城改路也没加城（布局与原版相同）→ ""
static func layout_sig(content: Dictionary) -> String:
	if not content.has("custom_map"):
		return ""
	var cm: Dictionary = content["custom_map"]
	var overlay: Dictionary = cm.get("overlay", {})
	var moves: Dictionary = overlay.get("moves", {}) if overlay.get("moves") is Dictionary else {}
	var moved := CustomMapFreeRoutes.enabled(overlay) or not (moves.get("cities", {}) as Dictionary).is_empty() or not (moves.get("routes", {}) as Dictionary).is_empty()
	if not moved and (overlay.get("new_cities", []) as Array).is_empty() and not overlay.has("plants") and (overlay.get("landscape", {}).get("edits", []) as Array).is_empty():
		return ""
	return str(cm.get("sha256", ""))


## 这一局用的覆盖层（没地图 → {}）
static func overlay_of(content: Dictionary) -> Dictionary:
	if not content.has("custom_map"):
		return {}
	return (content["custom_map"] as Dictionary).get("overlay", {})

## Editor-only content carries draft status and never registers an invalid map for play.
static func editor_preview(overlay:Dictionary)->Dictionary:
	var base:=base_content();var errors:Array[Dictionary]=[];var warnings:Array[Dictionary]=[]
	CustomMapValidator._check_file(overlay,base,errors,warnings,true)
	if not errors.is_empty():return base
	var catalogue:=CustomMapCatalogue.data();var texts:Dictionary={}
	for c:Dictionary in overlay.get("new_cities",[]):texts[str(c.slot)]=CustomMapValidator.texts_for(base,overlay,c,catalogue)
	# Editor identity and card readiness are separate. Only merge recomputed,
	# structurally checked decks that exactly match the saved current document.
	var expected:=CustomMapValidator.generate(base,overlay,catalogue)
	var saved_decks:Variant=overlay.get("generated",{})
	var trade_ready:bool=saved_decks is Dictionary and expected.get("ok",false) and CustomMapSchema.canonical_text(saved_decks)==CustomMapSchema.canonical_text(expected.get("generated",{}))
	var checked_decks:Dictionary=expected.generated if trade_ready else {"decks":[]}
	var entry:Dictionary={"overlay":overlay,"catalogue":catalogue,"generated":checked_decks,"texts":texts,"map_id":overlay.map_id,"name":overlay.name,"topology_key":CustomMapSchema.topology_key(overlay),"counts_win":false}
	var merged:=base.duplicate(false)
	var result:=_merge_entry(merged,base,entry,CustomMapSchema.sha256(overlay),false)
	if not result.success:return base
	if not PublicRules.ready():
		for city: Dictionary in overlay.get("new_cities",[]):
			var cid := CustomMapSchema.city_id(str(city.slot))
			if merged.city_cards.has(cid): merged.city_cards[cid].starting_grant={"entries":[]}
			var spec_id := "x_"+str(city.slot)+"_"+str(city.get("specialty",""))
			if merged.goods.has(spec_id): merged.goods[spec_id].supply_total=0
	merged.custom_map.editor_draft=true
	merged.custom_map.editor_trade_ready=trade_ready
	merged.custom_map.editor_trade_reason="" if trade_ready else "交易卡尚未随当前城市与路网更新；修复后再查看。"
	return merged
