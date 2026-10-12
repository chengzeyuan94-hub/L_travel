extends RefCounted

## 模拟和生成器测试用的「内存覆盖层」（WP2）：在 WP1 的 CustomMapLoader 合入之前，按 DESIGN 3.5 / 3.8 的写法
## 把一种接法并进基础包的一份浅拷贝，并补开局状态。只给 tools/custom_map/sim/ 和 tests/custom_map_tradegen_tests.gd 用，
## 游戏不引用本文件。WP1 合入后，模拟改走真实加载路径（CustomMapLoader.remember → 带地图选项 prepare_new_game），
## 见 sim_run.gd 的 mode=real；本文件只剩 T-G3f 和 mode=memory 冒烟用。
##
## 与真实路径的已知差别（只影响 mode=memory 的冒烟，不影响规则数据）：
##   - trade_system.gd:777-778 的「新牌堆抽空重洗用自己的随机数」是 WP1 的改动，这里改不到；新牌堆抽空后
##     仍走共享随机数，同种子配对在那之后会分叉（36 轮里很少发生：新牌堆要在新城成交 10 次才抽空）。
##   - 城和路的坐标只按宿主位置粗放，movement_polyline 只有两个点：AI 和规则层不看坐标。

const SLOT_CARD_NUMBER := {"w1": 17, "e1": 18, "w2": 19, "e2": 20}
## 目录默认特产（名字和键只管好看，规则只看槽位，R18）
const DEFAULT_SPECIALTY := {"w1": ["pomegranate", "石榴"], "e1": ["kaolin", "高岭土"], "w2": ["melon", "甜瓜"], "e2": ["oil_paper_umbrella", "油纸伞"]}
const DEFAULT_NAME := {"w1": "西新城一", "e1": "东新城一", "w2": "西新城二", "e2": "东新城二"}


## 货物 id 表：{槽位: x_<槽位>_<特产键>}
static func goods_map_for(topology: Array) -> Dictionary:
	var out := {}
	for t in topology:
		var slot := String(t["slot"])
		out[slot] = "x_%s_%s" % [slot, DEFAULT_SPECIALTY[slot][0]]
	return out


## 生成并合并：返回 {ok, content, decks, errors}。base 是 GameData.load_ruleset(FORMAL) 的结果，不会被改动。
static func merged_content(base: Dictionary, topology: Array) -> Dictionary:
	# 此研究覆盖层只实现普通叶子图。扩展键应走正式 loader，不能生成与距离不同的图。
	for entry in topology:
		if entry.has("topology_error") or not entry.get("extra_connections", []).is_empty() or bool(entry.get("host_interchange", false)):
			return {"ok": false, "errors": ["mode=memory 不支持扩展/非法拓扑；请使用 mode=real 与正式 overlay"], "content": {}, "decks": []}
	var gm := goods_map_for(topology)
	var gen := TradeGenV1.generate(base, topology, gm)
	if not bool(gen.get("ok", false)):
		return {"ok": false, "errors": gen.get("errors", []), "content": {}, "decks": []}
	return {"ok": true, "errors": [], "decks": gen["decks"], "content": merge(base, topology, gen["decks"], gm)}


## DESIGN 3.5：浅拷贝后追加，从不写基础包的字典（照 expansion_loader.gd:158-163 的写法）。
static func merge(base: Dictionary, topology: Array, decks: Array, goods_map: Dictionary) -> Dictionary:
	var merged: Dictionary = base.duplicate(false)
	for key in ["goods", "nations", "cities", "city_cards", "board_nodes", "city_by_node", "trade_decks", "trade_card_index", "edges_from"]:
		merged[key] = (base.get(key, {}) as Dictionary).duplicate(false)
	merged["board_edges"] = (base.get("board_edges", []) as Array).duplicate(false)
	var topo: Array = topology.duplicate()
	topo.sort_custom(func(a, b): return String(a["slot"]) < String(b["slot"]))
	var new_city_ids: Array = []
	var new_deck_ids: Array = []
	var new_good_ids: Array = []
	var new_cities := {}
	for t in topo:
		var slot := String(t["slot"])
		var cid := "x_" + slot
		var host := String(t["host"])
		var route := String(t["route_type"])
		var good_id := String(goods_map.get(slot, cid))
		var deck_id := "deck_" + cid
		var host_node: Dictionary = base["board_nodes"][String(base["cities"][host]["board_node_id"])]
		var hp: Vector2 = host_node.get("map_position", Vector2.ZERO)
		var dir := Vector2(-1, 0) if slot.begins_with("w") else Vector2(1, 0)
		merged["goods"][good_id] = {"id": good_id, "display_name": DEFAULT_SPECIALTY[slot][1], "supply_total": 10, "sprite": ""}
		merged["nations"][cid] = {"id": cid, "display_name": DEFAULT_NAME[slot]}
		merged["cities"][cid] = {
			"id": cid, "display_name": DEFAULT_NAME[slot], "nation_id": cid, "city_card_id": cid, "board_node_id": cid,
			"node_type": "CITY", "starting_transport": "CAMEL" if route == "LAND" else "SHIP", "allowed_routes": [route],
			"is_transport_interchange": false, "map_attribute": "陆地城市" if route == "LAND" else "海上城市",
			"trade_color_id": deck_id, "map_position": [hp.x + dir.x * 90.0, hp.y], "illustration_id": "x_ill_" + slot,
		}
		merged["city_cards"][cid] = {
			"id": cid, "city_id": cid, "card_number": int(SLOT_CARD_NUMBER[slot]), "starting_transport": "CAMEL" if route == "LAND" else "SHIP",
			"starting_grant": {"entries": [{"resource_kind": "GOOD", "resource_id": good_id, "quantity": 1}]}, "illustration_id": "x_ill_" + slot,
		}
		var corridor := "%s_%s_%s" % [route.to_lower(), host, cid]
		var r1 := corridor + "_01"
		var r2 := corridor + "_02"
		var pc := hp + dir * 90.0
		merged["board_nodes"][cid] = {"id": cid, "node_type": "CITY", "city_id": cid, "map_position": pc,
			"route_anchors": {route: pc}, "allowed_routes": [route], "is_transport_interchange": false}
		merged["board_nodes"][r1] = {"id": r1, "node_type": "ROAD", "city_id": null, "map_position": hp + dir * 30.0}
		merged["board_nodes"][r2] = {"id": r2, "node_type": "ROAD", "city_id": null, "map_position": hp + dir * 60.0}
		merged["city_by_node"][cid] = cid
		var host_node_id := String(base["cities"][host]["board_node_id"])
		var chain := [host_node_id, r1, r2, cid]
		for k in 3:
			var a: String = chain[k]
			var b: String = chain[k + 1]
			var pa: Vector2 = merged["board_nodes"][a]["map_position"]
			var pb: Vector2 = merged["board_nodes"][b]["map_position"]
			var e := {"id": "edge_%s__%s" % [a, b], "a": a, "b": b, "route_type": route, "corridor_id": corridor,
				"corridor_step_index": k + 1, "movement_polyline": [[pa.x, pa.y], [pb.x, pb.y]]}
			merged["board_edges"].append(e)
			for endpoint in [a, b]:
				var arr: Array = (merged["edges_from"].get(endpoint, []) as Array).duplicate(false)
				arr.append(e)
				merged["edges_from"][endpoint] = arr
		var dk: Dictionary = {}
		for d in decks:
			if String(d["id"]) == deck_id:
				dk = d
		var cards := {}
		for c in dk.get("cards", []):
			cards[c["id"]] = c
			merged["trade_card_index"][c["id"]] = deck_id
		merged["trade_decks"][deck_id] = {"id": deck_id, "city_ids": [cid], "shared_by_city_pair": false, "draw_order": "SHUFFLED", "cards": cards}
		new_city_ids.append(cid)
		new_deck_ids.append(deck_id)
		new_good_ids.append(good_id)
		new_cities[cid] = true
	merged["custom_map"] = {"sha256": "", "map_id": "sim", "name": "sim", "overlay": {}, "topology_key": TradeGenV1.topology_key(topo),
		"new_city_ids": new_city_ids, "new_deck_ids": new_deck_ids, "new_good_ids": new_good_ids, "counts_win": false}
	merged["custom_map_new_cities"] = new_cities
	return merged


## DESIGN 3.8：新货供应、新城市场、新牌堆独立洗牌（种子 = sha256("%d|%s|%s" % [rng_seed, 拓扑键, 牌堆 id]) 前 15 位）。
## 排在 prepare_new_game 全部原版随机数消耗之后调用。
static func init_session_state(content: Dictionary) -> void:
	if not content.has("custom_map"):
		return
	var cm: Dictionary = content["custom_map"]
	var goods: Array = cm["new_good_ids"].duplicate()
	goods.sort()
	for good_id in goods:
		GameState.goods_supply[good_id] = int(content["goods"][good_id]["supply_total"])
	var cities: Array = cm["new_city_ids"].duplicate()
	cities.sort()
	for city_id in cities:
		GameState.city_market_states[city_id] = {"trade_route_open": false, "current_trade_card_id": "", "opened_by_player_id": "", "opened_on_turn": -1}
	var decks: Array = cm["new_deck_ids"].duplicate()
	decks.sort()
	for deck_id in decks:
		var draw: Array = (content["trade_decks"][deck_id]["cards"] as Dictionary).keys()
		draw.sort()
		var rng := RandomNumberGenerator.new()
		rng.seed = ("%d|%s|%s" % [GameState.rng_seed, String(cm["topology_key"]), deck_id]).sha256_text().substr(0, 15).hex_to_int()
		for i in range(draw.size() - 1, 0, -1):
			var j: int = rng.randi_range(0, i)
			var tmp = draw[i]
			draw[i] = draw[j]
			draw[j] = tmp
		GameState.trade_decks_state[deck_id] = {"draw": draw, "discard": [], "rng_state": rng.state}
