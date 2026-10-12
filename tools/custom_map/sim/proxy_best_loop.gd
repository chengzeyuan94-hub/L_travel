extends RefCounted

## 真人代理 3（DESIGN 4.4）：只沿循环护栏（R14）枚举出的最好循环来回跑——开局时在这张图上枚举所有涉及新城的
## 单程、往返循环（宿主 ↔ 新城的 3 步短途、搭档往返），取每回合收益最高的一条。牌面都是公开信息：空仓时只有
## 买点翻开的牌能买到线路货、按卖点翻开的牌（卖点没开通时按那一堆的平均收购价）算得过来，才去买点买；
## 带着线路货去卖点，牌面兑银比直售强才卖。线路现在没有赚头、到不了（走不近）、手上是别的货、或在卖点等了
## 2 回合牌面还不对时，交回电脑策略——所以它是「电脑的打法 + 盯着最好那条线路捡便宜」。
## 只给 tools/custom_map/sim 用，不进仓库的 AI。

const PATIENCE := 2

static var _gen := -1
static var _plan := {}
static var _wait := {}


static func choose_move(player: PlayerState) -> Dictionary:
	_ensure_plan()
	if _plan.is_empty():
		return AIPolicy.choose_move(player)
	var target := _target_city(player)
	if target.is_empty():
		return AIPolicy.choose_move(player)
	var content: Dictionary = GameState.content
	var goal := String(content["cities"][target].get("board_node_id", target))
	var no_switch: Array = AIPolicy._build_move_candidates(player, player.active_transport, false)
	if goal == player.current_node_id:
		if int(_wait.get(player.player_id, 0)) >= PATIENCE:
			_wait[player.player_id] = 0
			return AIPolicy.choose_move(player)
		for c in no_switch:
			if int(c["steps"]) == 0:
				return _move(no_switch, c, "真人代理：在线路城等牌面。")
		return AIPolicy.choose_move(player)
	var to_goal: Dictionary = AIPolicy._steps_from(goal)
	var here_d := int(to_goal.get(player.current_node_id, 999))
	var switch_candidates: Array = []
	if MovementSystem.can_switch_transport(player):
		switch_candidates = AIPolicy._build_move_candidates(player, player.reserve_transport, true)
	var best: Dictionary = {}
	var best_d := 999
	for c in no_switch + switch_candidates:
		var d := int(to_goal.get(String(c["node_id"]), 999))
		var better := d < best_d
		if not better and d == best_d and not best.is_empty():
			# 同样近：步数多的优先，其次不换乘
			better = int(c["steps"]) > int(best["steps"]) or (int(c["steps"]) == int(best["steps"]) and bool(best["needs_switch"]) and not bool(c["needs_switch"]))
		if better:
			best = c
			best_d = d
	if best.is_empty() or best_d >= here_d:
		return AIPolicy.choose_move(player)       # 走不近：交回电脑策略
	_wait[player.player_id] = 0
	return _move(no_switch + switch_candidates, best, "真人代理：沿线路走向 %s。" % target)


static func choose_trade(player: PlayerState) -> Dictionary:
	_ensure_plan()
	if _plan.is_empty():
		return AIPolicy.choose_trade(player)
	var city := GameData.get_city_at_node(GameState.content, player.current_node_id)
	# 带着线路货到了卖点：牌面兑银比 1 银/件直售强就卖，不然等（最多 PATIENCE 回合）再交回电脑
	for leg in _plan["legs"]:
		var g := String(leg["good"])
		var held := player.held_count(g)
		if held > 0 and city == String(leg["sell"]):
			var sell := _best_sale(player, g)
			if not sell.is_empty() and int(sell.get("silver_gain", 0)) > held:
				_wait[player.player_id] = 0
				return _ratio(sell, int(sell["max_times"]), "真人代理：按线路卖出。")
			_wait[player.player_id] = int(_wait.get(player.player_id, 0)) + 1
			return AIPolicy.choose_trade(player)
	# 空仓到了买点：看卖点翻开的牌（公开信息；卖点还没开通时按那一堆的平均收购价），算得过来才买
	if player.cargo_count() == 0:
		for leg in _plan["legs"]:
			if city != String(leg["buy"]):
				continue
			var buy := _best_buy(player, String(leg["good"]), String(leg["sell"]))
			if not buy.is_empty():
				_wait[player.player_id] = 0
				return _ratio(buy["candidate"], int(buy["times"]), "真人代理：按线路买进（预计赚 %.1f）。" % float(buy["profit"]))
			_wait[player.player_id] = int(_wait.get(player.player_id, 0)) + 1
	return AIPolicy.choose_trade(player)


## 当前牌面上把 good 换成白银的最好一笔（整数倍，按 silver_gain）。
static func _best_sale(player: PlayerState, good: String) -> Dictionary:
	var best: Dictionary = {}
	for c in TradeSystem.get_legal_ratio_actions(player):
		var give: Dictionary = c.get("give_resource", {})
		var recv: Dictionary = c.get("receive_resource", {})
		if String(give.get("resource_kind", "")) != "GOOD" or String(give.get("resource_id", "")) != good:
			continue
		if String(recv.get("resource_kind", "")) != "SILVER" or int(c.get("max_times", 0)) <= 0:
			continue
		if best.is_empty() or int(c.get("silver_gain", 0)) > int(best.get("silver_gain", 0)):
			best = c
	return best


## 用白银买 good 的最好一笔：{candidate, times, profit}；按卖点的变现价值算利润，只取严格为正的。
static func _best_buy(player: PlayerState, good: String, sell_city: String) -> Dictionary:
	var best: Dictionary = {}
	for c in TradeSystem.get_legal_ratio_actions(player):
		var give: Dictionary = c.get("give_resource", {})
		var recv: Dictionary = c.get("receive_resource", {})
		if String(give.get("resource_kind", "")) != "SILVER" or String(recv.get("resource_kind", "")) != "GOOD":
			continue
		if String(recv.get("resource_id", "")) != good:
			continue
		for times in range(1, int(c.get("max_times", 0)) + 1):
			var units := int(recv.get("quantity", 0)) * times
			var cost := int(give.get("quantity", 0)) * times
			var profit := _sell_value(sell_city, good, units) - float(cost)
			if profit > 0.0 and (best.is_empty() or profit > float(best["profit"])):
				best = {"candidate": c, "times": times, "profit": profit}
	return best


## 卖点的变现价值：开通了就看翻开的那张牌；没开通按那一堆每张卡的价值取平均（不够整批的余量按 1 银/件直售）。
static func _sell_value(city_id: String, good: String, units: int) -> float:
	var content: Dictionary = GameState.content
	var card_id := String(GameState.city_market_states.get(city_id, {}).get("current_trade_card_id", ""))
	if not card_id.is_empty():
		return float(_card_value(GameData.get_trade_card(content, card_id), good, units))
	var deck_id := String(content["cities"][city_id].get("trade_color_id", ""))
	var cards: Dictionary = content["trade_decks"].get(deck_id, {}).get("cards", {})
	if cards.is_empty():
		return float(units)
	var total := 0
	for c in cards.values():
		total += _card_value(c, good, units)
	return float(total) / float(cards.size())


static func _card_value(card: Dictionary, good: String, units: int) -> int:
	var best := units
	var entries: Array = card.get("entries", [])
	for give in entries:
		if String(give.get("resource_kind", "")) != "GOOD" or String(give.get("resource_id", "")) != good:
			continue
		var q := int(give.get("quantity", 0))
		if q <= 0:
			continue
		for recv in entries:
			if String(recv.get("resource_kind", "")) == "SILVER":
				var t := units / q
				best = maxi(best, t * int(recv.get("quantity", 0)) + (units - t * q))
	return best


static func choose_event_decision(player: PlayerState, pending: Dictionary) -> Dictionary:
	return AIPolicy.choose_event_decision(player, pending)


## 手上有线路货 → 它的卖点；手上是别的货 → 交回电脑（空字符串）；空仓 → 最近的「现在就有赚头」的买点
## （买点翻开的牌能用白银买到线路货，按卖点的变现价值算得过来）；一条都没有就交回电脑。
static func _target_city(player: PlayerState) -> String:
	for leg in _plan["legs"]:
		if player.held_count(String(leg["good"])) > 0:
			return String(leg["sell"])
	if player.cargo_count() > 0:
		return ""
	var from: Dictionary = AIPolicy._steps_from(player.current_node_id)
	var best := ""
	var best_d := 999
	for leg in _plan["legs"]:
		if not _leg_live(player, leg):
			continue
		var node := String(GameState.content["cities"][String(leg["buy"])].get("board_node_id", ""))
		var d := int(from.get(node, 999))
		if d < best_d:
			best = String(leg["buy"])
			best_d = d
	return best


## 这条线路现在有没有赚头：买点已开通、翻开的牌能用白银买线路货，买得起的倍数里有一笔按卖点价值算是正利润。
static func _leg_live(player: PlayerState, leg: Dictionary) -> bool:
	var card := TradeSystem.get_trade_card_for_city(String(leg["buy"]))
	if card.is_empty():
		return false
	var good := String(leg["good"])
	var entries: Array = card.get("entries", [])
	for give in entries:
		if String(give.get("resource_kind", "")) != "SILVER":
			continue
		var price := int(give.get("quantity", 0))
		for recv in entries:
			if String(recv.get("resource_kind", "")) != "GOOD" or String(recv.get("resource_id", "")) != good:
				continue
			var q := int(recv.get("quantity", 0))
			if price <= 0 or q <= 0:
				continue
			for t in range(1, mini(4 / q, player.silver / price) + 1):
				if _sell_value(String(leg["sell"]), good, q * t) - float(price * t) > 0.0:
					return true
	return false


static func _ratio(c: Dictionary, times: int, reason: String) -> Dictionary:
	return {"action": "TRADE_RATIO", "blocked": false, "legal_candidates": [], "chosen": {"action": "TRADE_RATIO", "kind": "ratio",
		"give_index": c["give_index"], "receive_index": c["receive_index"], "times": times}, "priority": 0, "reason": reason}


static func _move(candidates: Array, chosen: Dictionary, reason: String) -> Dictionary:
	return {"action": "MOVE", "blocked": false, "legal_candidates": candidates, "chosen": chosen, "score": chosen.get("score", 0), "reason": reason}


## 开局时（每个会话一次）在当前地图上枚举涉及新城的循环，取收益最高的一条；往返更高时两头都装货。
static func _ensure_plan() -> void:
	if _gen == GameState.session_generation:
		return
	_gen = GameState.session_generation
	_plan = {}
	_wait = {}
	var content: Dictionary = GameState.content
	var newc: Dictionary = content.get("custom_map_new_cities", {})
	if newc.is_empty():
		return
	var econ := TradeGenV1._econ_from_content(content)
	var dist := TradeGenV1._city_distances(TradeGenV1._board_from_content(content))
	var turns: Array = TradeGenV1.params()["turns_table"]
	var loops := TradeGenV1.all_loops(econ, dist, turns, newc)
	if loops.is_empty():
		return
	var ways := TradeGenV1.two_way_loops(loops, turns)
	var one: Dictionary = loops[0]
	if not ways.is_empty() and float(ways[0]["rate"]) > float(one["rate"]):
		var w: Dictionary = ways[0]
		_plan = {"kind": "two_way", "rate": w["rate"], "legs": [
			{"buy": w["a"], "sell": w["b"], "good": w["good_ab"]},
			{"buy": w["b"], "sell": w["a"], "good": w["good_ba"]}]}
	else:
		_plan = {"kind": "one_way", "rate": one["rate"], "legs": [{"buy": one["buy"], "sell": one["sell"], "good": one["good"]}]}
