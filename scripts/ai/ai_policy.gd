class_name AIPolicy

## 只读、确定性 AI 决策器。不继承场景节点、不持有计时器、不直接执行规则命令、
## 不消耗 RNG、不修改 GameState/PlayerState。只读取公开状态与 TASK-LITE-003 查询层，
## 返回决策 Dictionary 供 AITurnController 调用规则命令执行。
##
## 三档难度（AIDifficulty，按 AI 玩家的 ai_difficulty）：
##   山海独旅（默认）= 下面的原有策略，一行未改；
##   万里商途 = 原有策略 + 终局意识（估算剩余轮数，临近结束不再进货、就近变现）；
##   轻装启程 = 7 岁式的简单策略（就近进城、能买就买、多按 1 银/件卖，偶尔走错、忘了交易）。
## 轻装启程的"随性"取自对局状态的哈希，不消耗规则 RNG，同一局重放结果完全相同。

const SCORE_UNOPENED_CITY := 100
const SCORE_SILVER_TRADE := 40
const SCORE_OTHER_RATIO_TRADE := 25
const SCORE_HOLDING_CARGO_AT_CITY := 15
const SCORE_PORT := 10
const SCORE_PLAIN_NODE := -20


## 事件 pending 决策：确定性、不消耗 RNG。
static func choose_event_decision(player: PlayerState, pending: Dictionary) -> Dictionary:
	var op := String(pending.get("operation", ""))
	# 扩展包「L叔的趣味事件」的待决（付银或丢货、听声猜物、丢货过滤版）：规则见 FunEventOps，同样不消耗 RNG
	if op in FunEventOps.PENDING_OPS or (op == "LOSE_GOOD" and pending.has("good_filter")):
		return FunEventOps.ai_choose(player, pending)
	match op:
		"LOSE_GOOD":
			var required := int(pending.get("required_give_count", 0))
			return {"give_goods": EventSystem._ai_choose_lose_goods(player, required)}
		"LOSE_HALF_GOODS_MAX_2":
			var required := int(pending.get("required_give_count", 0))
			return {"give_goods": EventSystem._ai_choose_lose_goods(player, required)}
		"EXCHANGE_ONE_GOOD":
			var by_target: Dictionary = pending.get("legal_receive_goods_by_target", {})
			if by_target.is_empty():
				by_target = EventSystem._build_receive_goods_by_target(
					player, pending.get("legal_give_goods", [])
				)
			return EventSystem._ai_choose_exchange(
				player,
				by_target,
				pending.get("legal_give_goods", []),
			)
		_:
			return {}


## 起始交通：唯一合法则直接选用；两者皆合法则比较 5 步内可达城市数，多者优先，同分选骆驼。
static func choose_starting_transport(player: PlayerState) -> Dictionary:
	var legal := _legal_transports(player.current_node_id)
	if legal.size() == 1:
		return {
			"action": "CHOOSE_STARTING_TRANSPORT",
			"legal_candidates": legal.duplicate(),
			"chosen": legal[0],
			"score": {},
			"reason": "唯一合法交通工具。",
		}
	var camel_cities := MovementSystem.get_reachable_cities(player, 5, GameData.Transport.CAMEL).size()
	var ship_cities := MovementSystem.get_reachable_cities(player, 5, GameData.Transport.SHIP).size()
	var chosen := GameData.Transport.CAMEL
	var reason := "骆驼与商船 5 步内可达城市数相同，按规则优先选骆驼。"
	if ship_cities > camel_cities:
		chosen = GameData.Transport.SHIP
		reason = "商船 5 步内可达 %d 座城市，多于骆驼的 %d 座。" % [ship_cities, camel_cities]
	elif camel_cities > ship_cities:
		chosen = GameData.Transport.CAMEL
		reason = "骆驼 5 步内可达 %d 座城市，多于商船的 %d 座。" % [camel_cities, ship_cities]
	return {
		"action": "CHOOSE_STARTING_TRANSPORT",
		"legal_candidates": legal.duplicate(),
		"chosen": chosen,
		"score": {"camel_reachable_cities": camel_cities, "ship_reachable_cities": ship_cities},
		"reason": reason,
	}


## 移动决策：候选含 0 步停留、当前交通可达路径、港口换乘后可达路径。
## 换乘方案只有严格高于不换乘最佳方案时才采用。
static func choose_move(player: PlayerState) -> Dictionary:
	if GameState.phase != GameState.Phase.MOVE_OR_EVENT:
		return _blocked("MOVE", "当前阶段不能移动。")
	match AIDifficulty.of(player):
		AIDifficulty.EASY:
			return _easy_move(player)
		AIDifficulty.HARD:
			var endgame := _hard_endgame_move(player)
			if not endgame.is_empty():
				return endgame
			var haul := _hard_haul_move(player)
			if not haul.is_empty():
				return haul
	return choose_move_standard(player)


## 原有（山海独旅）移动策略。
static func choose_move_standard(player: PlayerState) -> Dictionary:
	var no_switch: Array = _build_move_candidates(player, player.active_transport, false)
	var switch_candidates: Array = []
	if MovementSystem.can_switch_transport(player):
		switch_candidates = _build_move_candidates(player, player.reserve_transport, true)
	var all_candidates: Array = no_switch + switch_candidates
	var best_no_switch := _pick_best_move(no_switch)
	var chosen: Dictionary = best_no_switch
	var best_switch := _pick_best_move(switch_candidates)
	if not best_switch.is_empty() and int(best_switch["score"]) > int(best_no_switch.get("score", -999999)):
		chosen = best_switch
	return {
		"action": "MOVE",
		"blocked": false,
		"legal_candidates": all_candidates,
		"chosen": chosen,
		"score": chosen.get("score", 0),
		"reason": _describe_move_choice(chosen),
	}


## 贸易决策：空仓优先白银购货 → 白银收益最多 → 净增货物最多 → 全部直售 → 其他 → 跳过。
static func choose_trade(player: PlayerState) -> Dictionary:
	if GameState.phase != GameState.Phase.TRADE:
		return _blocked("TRADE", "当前阶段不能贸易。")
	match AIDifficulty.of(player):
		AIDifficulty.EASY:
			return _easy_trade(player)
		AIDifficulty.HARD:
			var endgame := _hard_endgame_trade(player)
			if not endgame.is_empty():
				return endgame
	var ratio_candidates: Array = TradeSystem.get_legal_ratio_actions(player)
	var direct_sale: Dictionary = TradeSystem.get_legal_direct_sale(player)
	var legal_candidates: Array = ratio_candidates.duplicate(true)
	if bool(direct_sale.get("can_sell", false)):
		legal_candidates.append({"action": "TRADE_DIRECT_SALE", "selection": direct_sale["selection"]})

	# 空仓且有白银：优先 SILVER→GOOD，按净增货物最多。
	if player.cargo_count() == 0:
		var buy_candidates: Array = []
		for candidate in ratio_candidates:
			if (
				String(candidate["give_resource"].get("resource_kind", "")) == "SILVER"
				and String(candidate["receive_resource"].get("resource_kind", "")) == "GOOD"
				and int(candidate["cargo_delta"]) > 0
			):
				buy_candidates.append(candidate)
		var best_buy := _pick_profitable_buy(player, buy_candidates)
		if not best_buy.is_empty():
			return _ratio_decision(
				legal_candidates,
				best_buy,
				0,
				"空仓购入可周转货物：预计净收益 %d 白银。" % int(best_buy["estimated_profit"])
			)
		# 当前 16 张公开牌偶尔会形成没有正收益入口的市场静态点。保留 8 白银
		# 本金，只用一倍、预期损失最小的购货翻动一张牌，避免永久等待；一旦
		# 新牌出现正收益，仍由上面的严格获利策略接管。
		var cycle_buy := _pick_market_cycle_buy(player, buy_candidates, 8)
		if not cycle_buy.is_empty():
			return _ratio_decision(
				legal_candidates,
				cycle_buy,
				0,
				"市场暂无获利入口，以一倍低损周转刷新行情（预计 %d 白银）。"
				% int(cycle_buy["estimated_profit"])
			)

	var silver_candidates: Array = []
	for candidate in ratio_candidates:
		if String(candidate["receive_resource"].get("resource_kind", "")) == "SILVER" and int(candidate["silver_gain"]) > 0:
			silver_candidates.append(candidate)
	var best_silver := _pick_best_ratio(silver_candidates, "silver_gain")
	var direct_sale_gain := _direct_sale_gain(direct_sale)
	# 买入策略会用其他已开通城市的公开牌估算远端变现价值。若途中一到城市就
	# 按当前牌面或 1 银/件清仓，AI 会把原本严格正收益的跨城贸易主动做成亏损，
	# 并在公共银库与玩家之间无限搬运白银。只有远端公开牌严格优于当前可执行
	# 的最佳变现时才持货等待；相等时仍立即变现，避免制造新的等待环。
	# 自制地图的 X3（DESIGN 3.9 / R24）：只有这两处比较传 travel_cost = true；有新城的对局里，涉及新城的远端
	# 变现价值要扣掉路程（⌈步数/3⌉×2），否则电脑会停在地图边上的新城有货不卖也不走。原版对局不进这个分支。
	var current_city := GameData.get_city_at_node(GameState.content, player.current_node_id)
	var future_liquidation := _portfolio_liquidation_value(player, current_city, true)
	var current_card_liquidation := -1
	if not best_silver.is_empty():
		current_card_liquidation = _ratio_liquidation_value(
			player,
			best_silver,
			current_city,
			true,
		)
	var immediate_liquidation := maxi(direct_sale_gain, current_card_liquidation)
	if future_liquidation > immediate_liquidation:
		return {
			"action": "SKIP_TRADE",
			"blocked": false,
			"legal_candidates": legal_candidates,
			"chosen": {"action": "SKIP_TRADE", "kind": "skip"},
			"priority": 1,
			"reason": "远端公开市场可变现 %d 白银，高于当前的 %d 白银，保留货物继续周转。"
			% [future_liquidation, immediate_liquidation],
		}
	if not best_silver.is_empty() and current_card_liquidation >= direct_sale_gain:
		return _ratio_decision(legal_candidates, best_silver, 1, "白银收益最高的比例兑换：%d 白银。" % int(best_silver["silver_gain"]))

	# 当前城市若没有比 1 银/件更好的牌面出售，直接变现优先于继续换成其他
	# 货物。旧策略把“净增货物”放在直售前，在正式牌组中会长期囤货却不拿空银库。
	if bool(direct_sale.get("can_sell", false)):
		return {
			"action": "TRADE_DIRECT_SALE",
			"blocked": false,
			"legal_candidates": legal_candidates,
			"chosen": {"action": "TRADE_DIRECT_SALE", "kind": "direct_sale", "selection": direct_sale["selection"]},
			"priority": 2,
			"reason": "当前牌面兑银不优于直接出售，按 1 白银/件全部变现。",
		}

	var cargo_candidates: Array = []
	for candidate in ratio_candidates:
		if String(candidate["receive_resource"].get("resource_kind", "")) == "GOOD" and int(candidate["cargo_delta"]) > 0:
			cargo_candidates.append(candidate)
	var best_cargo := _pick_best_ratio(cargo_candidates, "cargo_delta")
	if not best_cargo.is_empty():
		return _ratio_decision(legal_candidates, best_cargo, 2, "净增货物最多的比例兑换：+%d 件。" % int(best_cargo["cargo_delta"]))

	var best_other := _pick_best_ratio(ratio_candidates, "")
	if not best_other.is_empty():
		return _ratio_decision(legal_candidates, best_other, 4, "无白银或净增货物兑换，执行其他合法比例兑换。")

	return {
		"action": "SKIP_TRADE",
		"blocked": false,
		"legal_candidates": legal_candidates,
		"chosen": {"action": "SKIP_TRADE", "kind": "skip"},
		"priority": 5,
		"reason": "没有合法贸易，跳过。",
	}


# ---------- 内部：移动候选与评分 ----------

static func _legal_transports(node_id: String) -> Array:
	if GameData.is_port_node(GameState.content, node_id):
		return [GameData.Transport.CAMEL, GameData.Transport.SHIP]
	return [GameData.Transport.CAMEL]


static func _build_move_candidates(player: PlayerState, transport: int, is_switch: bool) -> Array:
	var candidates: Array = []
	var destinations: Dictionary = MovementSystem.get_legal_destinations(player, player.movement_budget, transport)
	var node_ids: Array = destinations.keys()
	node_ids.sort()
	for node_id in node_ids:
		var steps: int = destinations[node_id]
		var path: Array = [] if steps == 0 else MovementSystem.find_path(player, String(node_id), player.movement_budget, transport)
		var score := _score_move_destination(player, String(node_id), transport)
		candidates.append(
			{
				"node_id": String(node_id),
				"path": path,
				"steps": steps,
				"transport": transport,
				"switched": is_switch,
				"needs_switch": is_switch,
				"score": score,
			}
		)
	return candidates


static func _score_destination(player: PlayerState, node_id: String) -> int:
	var content: Dictionary = GameState.content
	var score := 0
	if GameData.is_city_node(content, node_id):
		var city_id := GameData.get_city_at_node(content, node_id)
		var market: Dictionary = GameState.city_market_states.get(city_id, {})
		if String(market.get("current_trade_card_id", "")).is_empty():
			score += SCORE_UNOPENED_CITY
		var ratio_actions: Array = TradeSystem.get_legal_ratio_actions(player, city_id)
		var best_silver_gain := 0
		var has_other := false
		for action in ratio_actions:
			if String(action["receive_resource"].get("resource_kind", "")) == "SILVER":
				best_silver_gain = maxi(best_silver_gain, int(action.get("silver_gain", 0)))
			else:
				has_other = true
		if best_silver_gain > 0:
			# 不只判断“能兑银”，还要让跨回合寻路优先前往实际回报更高的市场。
			score += SCORE_SILVER_TRADE + best_silver_gain * 4
		elif has_other:
			score += SCORE_OTHER_RATIO_TRADE
		if player.cargo_count() > 0:
			score += SCORE_HOLDING_CARGO_AT_CITY
		# 空仓有白银时，已开通商道的城市可购货，优先于港口事件补货。
		if player.cargo_count() == 0 and player.silver > 0:
			var can_buy := false
			for action in ratio_actions:
				if (
					String(action["give_resource"].get("resource_kind", "")) == "SILVER"
					and String(action["receive_resource"].get("resource_kind", "")) == "GOOD"
				):
					can_buy = true
					break
			if can_buy:
				score += 45
		if GameData.is_port_node(content, node_id):
			score += SCORE_PORT
	else:
		score += SCORE_PLAIN_NODE
	return score


## 正式世界地图中相邻城市之间通常隔着多段道路；只评价本回合终点会让 AI 永远
## 不肯离开城市（道路节点固定负分），这是七城 Demo 不会暴露的局限。这里在保持
## 原有城市即时评分的基础上，增加只读、确定性的跨回合前瞻：评价终点到下一座
## 城市的最短距离，让每向目标前进一步都严格增分。该查询不消费 RNG、不保存目标，
## 因而不会改变规则状态或确定性。
static func _score_move_destination(player: PlayerState, node_id: String, transport: int) -> int:
	var immediate := _score_destination(player, node_id)
	var future := _best_future_city_score(player, node_id, transport)
	return maxi(immediate, future)


static func _best_future_city_score(player: PlayerState, from_node_id: String, transport: int) -> int:
	var content: Dictionary = GameState.content
	var route_type := GameData.route_type_for_transport(transport)
	var distance := {from_node_id: 0}
	var frontier: Array[String] = [from_node_id]
	var best := -999999
	while not frontier.is_empty():
		var current := String(frontier.pop_front())
		var steps := int(distance[current])
		if current != from_node_id and GameData.is_city_node(content, current):
			# 未开通城市仍最优；已开通城市至少保留小额旅行价值，确保 AI 在没有
			# 当场交易时也能穿过多段道路，而不是永久原地停留。
			var city_score := maxi(8, _score_destination(player, current))
			best = maxi(best, city_score - steps * 2)
		for edge in GameData.get_edges_from(content, current, route_type):
			var other := GameData.edge_other_node(edge, current)
			if not distance.has(other):
				distance[other] = steps + 1
				frontier.append(other)
	return best


## 并列：步数更多 → 不换乘 → node_id 更小。
static func _pick_best_move(candidates: Array) -> Dictionary:
	if candidates.is_empty():
		return {}
	var sorted_candidates: Array = candidates.duplicate()
	sorted_candidates.sort_custom(
		func(a, b):
			if int(a["score"]) != int(b["score"]):
				return int(a["score"]) > int(b["score"])
			if int(a["steps"]) != int(b["steps"]):
				return int(a["steps"]) > int(b["steps"])
			if bool(a["needs_switch"]) != bool(b["needs_switch"]):
				return not bool(a["needs_switch"])
			return String(a["node_id"]) < String(b["node_id"])
	)
	return sorted_candidates[0]


static func _describe_move_choice(chosen: Dictionary) -> String:
	if chosen.is_empty():
		return "没有可用的移动候选。"
	if int(chosen.get("steps", 0)) == 0 and not bool(chosen.get("needs_switch", false)):
		return "原地停留（得分 %d）。" % int(chosen.get("score", 0))
	var switch_text := "先换乘再" if bool(chosen.get("needs_switch", false)) else ""
	return "%s移动 %d 步至 %s（得分 %d）。" % [switch_text, int(chosen.get("steps", 0)), String(chosen.get("node_id", "")), int(chosen.get("score", 0))]


# ---------- 内部：贸易候选与评分 ----------

## metric_key 为空时不比较数值，只按并列规则（交付更少 → give_index 更小 → receive_index 更小）取最优。
static func _pick_best_ratio(candidates: Array, metric_key: String) -> Dictionary:
	if candidates.is_empty():
		return {}
	var sorted_candidates: Array = candidates.duplicate()
	sorted_candidates.sort_custom(
		func(a, b):
			if not metric_key.is_empty() and int(a[metric_key]) != int(b[metric_key]):
				return int(a[metric_key]) > int(b[metric_key])
			var give_total_a := int(a["give_resource"].get("quantity", 0)) * int(a["max_times"])
			var give_total_b := int(b["give_resource"].get("quantity", 0)) * int(b["max_times"])
			if give_total_a != give_total_b:
				return give_total_a < give_total_b
			if int(a["give_index"]) != int(b["give_index"]):
				return int(a["give_index"]) < int(b["give_index"])
			return int(a["receive_index"]) < int(b["receive_index"])
	)
	return sorted_candidates[0]


static func _direct_sale_gain(direct_sale: Dictionary) -> int:
	if not bool(direct_sale.get("can_sell", false)):
		return 0
	var count := 0
	for quantity in direct_sale.get("selection", {}).values():
		count += int(quantity)
	return count * int(GameState.content.get("ruleset", {}).get("direct_sale_rate", 1))


## 购货不是目的，积累白银才是胜利条件。旧 Demo AI 每次空仓都会把全部白银
## 换成“件数最多”的商品，即使只能亏本直售，正式牌组因此可无限烧钱循环。
## 这里用当前已开通的其他城市贸易卡估算该批货物的最佳兑银价值（剩余件可按
## 1 银直售），只选择严格正收益的批次；仍是只读、确定性查询。
static func _pick_profitable_buy(player: PlayerState, candidates: Array) -> Dictionary:
	var best: Dictionary = {}
	var current_city := GameData.get_city_at_node(GameState.content, player.current_node_id)
	for candidate_value in candidates:
		var candidate: Dictionary = candidate_value
		var give: Dictionary = candidate.get("give_resource", {})
		var receive: Dictionary = candidate.get("receive_resource", {})
		var unit_cost := int(give.get("quantity", 0))
		var unit_goods := int(receive.get("quantity", 0))
		var good_id := String(receive.get("resource_id", ""))
		for times in range(1, int(candidate.get("max_times", 0)) + 1):
			var cost := unit_cost * times
			var quantity := unit_goods * times
			var liquidation := _best_liquidation_value(good_id, quantity, current_city)
			var profit := liquidation - cost
			if profit <= 0:
				continue
			var option := candidate.duplicate(true)
			option["max_times"] = times
			option["estimated_profit"] = profit
			option["estimated_liquidation"] = liquidation
			if best.is_empty() or _buy_option_better(option, best):
				best = option
	return best


static func _pick_market_cycle_buy(player: PlayerState, candidates: Array, reserve_silver: int) -> Dictionary:
	var best: Dictionary = {}
	var current_city := GameData.get_city_at_node(GameState.content, player.current_node_id)
	for candidate_value in candidates:
		var candidate: Dictionary = candidate_value
		var give: Dictionary = candidate.get("give_resource", {})
		var receive: Dictionary = candidate.get("receive_resource", {})
		var cost := int(give.get("quantity", 0))
		if cost <= 0 or player.silver - cost < reserve_silver:
			continue
		var quantity := int(receive.get("quantity", 0))
		var good_id := String(receive.get("resource_id", ""))
		var option := candidate.duplicate(true)
		option["max_times"] = 1
		option["estimated_liquidation"] = _best_liquidation_value(good_id, quantity, current_city)
		option["estimated_profit"] = int(option["estimated_liquidation"]) - cost
		if best.is_empty() or _buy_option_better(option, best):
			best = option
	return best


## travel_cost（X3，DESIGN 3.9）：只在 choose_trade 的「持货等待」比较里传 true。生效条件是对局里有自制地图的新城
## （content.custom_map_new_cities 非空），并且当前所在城或被比较的远端城是新城：远端价值减去 ⌈步数/3⌉×2
## （与万里商途 HARD_SILVER_PER_TURN 同一口径）。买入估价、万里商途终局不扣路程；原版对局 gated 永远为假。
static func _best_liquidation_value(good_id: String, quantity: int, excluded_city_id: String, travel_cost := false) -> int:
	# 直接出售保证每件至少价值 1 白银。
	var best := quantity
	var content: Dictionary = GameState.content
	var newc: Dictionary = content.get("custom_map_new_cities", {})
	var gated := travel_cost and not newc.is_empty()
	var here_new := gated and newc.has(excluded_city_id)
	var dist: Dictionary = _steps_from(GameState.current_player().current_node_id) if gated else {}
	for city_id_value in GameState.city_market_states.keys():
		var city_id := String(city_id_value)
		if city_id == excluded_city_id:
			continue
		var market: Dictionary = GameState.city_market_states[city_id]
		var card_id := String(market.get("current_trade_card_id", ""))
		if card_id.is_empty() or not content.get("trade_card_index", {}).has(card_id):
			continue
		var card: Dictionary = GameData.get_trade_card(content, card_id)
		var entries: Array = card.get("entries", [])
		for give_value in entries:
			var give: Dictionary = give_value
			if String(give.get("resource_kind", "")) != "GOOD" or String(give.get("resource_id", "")) != good_id:
				continue
			var give_quantity := int(give.get("quantity", 0))
			if give_quantity <= 0:
				continue
			for receive_value in entries:
				var receive: Dictionary = receive_value
				if String(receive.get("resource_kind", "")) != "SILVER":
					continue
				var trade_times := quantity / give_quantity
				var remainder := quantity - trade_times * give_quantity
				var value := trade_times * int(receive.get("quantity", 0)) + remainder
				if gated and (here_new or newc.has(city_id)):
					var node := String(content["cities"].get(city_id, {}).get("board_node_id", ""))
					value -= int(ceilf(float(int(dist.get(node, 99))) / 3.0) * HARD_SILVER_PER_TURN)
				best = maxi(best, value)
	return best


## 当前持仓在其他已开通公开市场的最佳总变现价值。每种货物分别选择最优
## GOOD→SILVER 比例，不能整除的余量按规则中的 1 银/件直接出售计入。
static func _portfolio_liquidation_value(player: PlayerState, excluded_city_id: String, travel_cost := false) -> int:
	var total := 0
	for good_id_value in player.inventory.keys():
		var good_id := String(good_id_value)
		var quantity := player.held_count(good_id)
		if quantity > 0:
			total += _best_liquidation_value(good_id, quantity, excluded_city_id, travel_cost)
	return total


## 在当前城市执行一笔 GOOD→SILVER 后的组合价值：本次获得的白银，加上
## 剩余货物在其他公开市场的最佳变现价值。用于和“整仓继续运往远端”同口径比较。
static func _ratio_liquidation_value(
	player: PlayerState,
	candidate: Dictionary,
	excluded_city_id: String,
	travel_cost := false,
) -> int:
	var give: Dictionary = candidate.get("give_resource", {})
	var give_good := String(give.get("resource_id", ""))
	var give_total := int(give.get("quantity", 0)) * int(candidate.get("max_times", 0))
	var total := int(candidate.get("silver_gain", 0))
	for good_id_value in player.inventory.keys():
		var good_id := String(good_id_value)
		var quantity := player.held_count(good_id)
		if good_id == give_good:
			quantity -= give_total
		if quantity > 0:
			total += _best_liquidation_value(good_id, quantity, excluded_city_id, travel_cost)
	return total


static func _buy_option_better(a: Dictionary, b: Dictionary) -> bool:
	if int(a["estimated_profit"]) != int(b["estimated_profit"]):
		return int(a["estimated_profit"]) > int(b["estimated_profit"])
	if int(a["estimated_liquidation"]) != int(b["estimated_liquidation"]):
		return int(a["estimated_liquidation"]) > int(b["estimated_liquidation"])
	if int(a["give_index"]) != int(b["give_index"]):
		return int(a["give_index"]) < int(b["give_index"])
	if int(a["receive_index"]) != int(b["receive_index"]):
		return int(a["receive_index"]) < int(b["receive_index"])
	return int(a["max_times"]) < int(b["max_times"])


static func _ratio_decision(legal_candidates: Array, chosen: Dictionary, priority: int, reason: String) -> Dictionary:
	return {
		"action": "TRADE_RATIO",
		"blocked": false,
		"legal_candidates": legal_candidates,
		"chosen": {
			"action": "TRADE_RATIO",
			"kind": "ratio",
			"give_index": chosen["give_index"],
			"receive_index": chosen["receive_index"],
			"times": chosen["max_times"],
		},
		"priority": priority,
		"reason": reason,
	}


static func _blocked(action: String, reason: String) -> Dictionary:
	return {"action": action, "blocked": true, "legal_candidates": [], "chosen": {}, "score": 0, "reason": reason}


# ---------- 万里商途（16 岁）：原有策略 + 终局意识 ----------

## 估算本玩家还剩几个回合（含本回合）：< 1 = 这就是最后一回合（下一回合开始前时间就会
## 用完或白银就会拿空），< 2 = 之后只剩一回合。终局已触发 = 本回合就是最后一回合；对局
## 限时由 GameScreen 写入的剩余时间与平均每轮用时折算；公共白银按平均每轮流出折算。
static func rounds_left_estimate(player: PlayerState) -> float:
	if GameState.end_triggered:
		return 0.5
	var n := maxi(GameState.players.size(), 1)
	var rounds_done := float(GameState.round_index) + float(GameState.current_player_index) / float(n)
	var left := INF
	if GameState.match_time_left_sec < INF and GameState.match_elapsed_sec > 30.0 and rounds_done > 0.5:
		var sec_per_round := GameState.match_elapsed_sec / rounds_done
		left = minf(left, GameState.match_time_left_sec / maxf(sec_per_round, 1.0))
	var supply_start := int(GameState.content.get("ruleset", {}).get("silver_supply_by_player_count", {}).get(str(n), 0))
	var drained := supply_start - GameState.silver_supply
	if supply_start > 0 and drained > 0 and rounds_done > 2.0:
		var per_round := float(drained) / rounds_done
		left = minf(left, float(GameState.silver_supply) / maxf(per_round, 0.5))
	return left


## 最后一两回合：带着货就去最近能卖的城市，不再做远途打算。
static func _hard_endgame_move(player: PlayerState) -> Dictionary:
	if player.cargo_count() == 0 or rounds_left_estimate(player) >= 2.0:
		return {}
	var no_switch: Array = _build_move_candidates(player, player.active_transport, false)
	var switch_candidates: Array = []
	if MovementSystem.can_switch_transport(player):
		switch_candidates = _build_move_candidates(player, player.reserve_transport, true)
	var pick := func(cands: Array) -> Array:
		var b: Dictionary = {}
		var bv := -1
		for c_value in cands:
			var c: Dictionary = c_value
			var node := String(c["node_id"])
			if not GameData.is_city_node(GameState.content, node):
				continue
			var value := _liquidation_here(player, GameData.get_city_at_node(GameState.content, node))
			if value > bv or (value == bv and int(c["steps"]) < int(b.get("steps", 99))):
				bv = value
				b = c
		return [b, bv]
	var stay: Array = pick.call(no_switch)
	var swap: Array = pick.call(switch_candidates)
	# 只有换乘后严格更好才换（换过去的城在换回来时已是不换乘候选，不会来回换乘）
	var best: Dictionary = stay[0]
	var best_value: int = stay[1]
	if not (swap[0] as Dictionary).is_empty() and int(swap[1]) > best_value:
		best = swap[0]
		best_value = swap[1]
	if best.is_empty():
		return {}
	return {
		"action": "MOVE",
		"blocked": false,
		"legal_candidates": no_switch + switch_candidates,
		"chosen": best,
		"score": best_value,
		"reason": "对局将尽，前往可变现 %d 白银的城市清仓。" % best_value,
	}


## 在某城一次贸易能把当前货物换成多少白银（整仓直售 与 最佳单项兑银 取大）。
static func _liquidation_here(player: PlayerState, city_id: String) -> int:
	var best := player.cargo_count()     # 直接出售：每件 1 白银
	for action in TradeSystem.get_legal_ratio_actions(player, city_id):
		if String(action["receive_resource"].get("resource_kind", "")) == "SILVER":
			best = maxi(best, int(action.get("silver_gain", 0)))
	return best


## 最后一两回合：不再进货（货物终局不计分）；带着货就当场按最高价变现。平时：进货时把路程
## 算进去，按"每回合能赚多少"挑买卖。
static func _hard_endgame_trade(player: PlayerState) -> Dictionary:
	var left := rounds_left_estimate(player)
	if left >= 2.0:
		if player.cargo_count() == 0:
			return _hard_buy(player)
		var target: Array = _hard_sell_target(player)
		var here_city := GameData.get_city_at_node(GameState.content, player.current_node_id)
		if String(target[0]) != here_city and not String(target[0]).is_empty():
			return {
				"action": "SKIP_TRADE",
				"blocked": false,
				"legal_candidates": TradeSystem.get_legal_ratio_actions(player),
				"chosen": {"action": "SKIP_TRADE", "kind": "skip"},
				"priority": 1,
				"reason": "货运去 %s 卖更划算，先不卖。" % String(target[0]),
			}
		left = 0.5          # 这里就是最好的卖处：按终局同样的办法当场卖出
	var ratio_candidates: Array = TradeSystem.get_legal_ratio_actions(player)
	var direct_sale: Dictionary = TradeSystem.get_legal_direct_sale(player)
	var legal_candidates: Array = ratio_candidates.duplicate(true)
	if bool(direct_sale.get("can_sell", false)):
		legal_candidates.append({"action": "TRADE_DIRECT_SALE", "selection": direct_sale["selection"]})
	if player.cargo_count() == 0:
		return {
			"action": "SKIP_TRADE",
			"blocked": false,
			"legal_candidates": legal_candidates,
			"chosen": {"action": "SKIP_TRADE", "kind": "skip"},
			"priority": 1,
			"reason": "对局将尽，不再进货。",
		}
	# 仍有下一回合时，若远端能卖得明显更好，保留货物再走一步
	if left >= 1.0:
		var current_city := GameData.get_city_at_node(GameState.content, player.current_node_id)
		var here := _liquidation_here(player, current_city)
		if _portfolio_liquidation_value(player, current_city) > here + 2:
			return {}
	var best_silver: Dictionary = {}
	for c in ratio_candidates:
		if String(c["receive_resource"].get("resource_kind", "")) == "SILVER" and int(c["silver_gain"]) > 0:
			if best_silver.is_empty() or int(c["silver_gain"]) > int(best_silver["silver_gain"]):
				best_silver = c
	var sale_gain := _direct_sale_gain(direct_sale)
	if not best_silver.is_empty() and int(best_silver["silver_gain"]) > sale_gain:
		return _ratio_decision(legal_candidates, best_silver, 0, "对局将尽，按牌面最高价兑银 %d。" % int(best_silver["silver_gain"]))
	if bool(direct_sale.get("can_sell", false)):
		return {
			"action": "TRADE_DIRECT_SALE",
			"blocked": false,
			"legal_candidates": legal_candidates,
			"chosen": {"action": "TRADE_DIRECT_SALE", "kind": "direct_sale", "selection": direct_sale["selection"]},
			"priority": 0,
			"reason": "对局将尽，整仓按 1 白银/件变现。",
		}
	return {}


const HARD_SILVER_PER_TURN := 2.0       # 16 岁心里的"一回合值多少白银"：绕远路要划算才绕（实测 0.5–3 中 2 最强）


## 带着货：选"卖价 − 路上耽误的回合 × 每回合价值"最高的城市（含当场），返回 [城市, 价值, 步数]。
static func _hard_sell_target(player: PlayerState) -> Array:
	var dist := _steps_from(player.current_node_id)
	var here_city := GameData.get_city_at_node(GameState.content, player.current_node_id)
	var best_city := ""
	var best_score := -INF
	var best_steps := 0
	for city_id_value in GameState.city_market_states.keys():
		var city_id := String(city_id_value)
		var node := String(GameState.content["cities"].get(city_id, {}).get("board_node_id", ""))
		var steps := 0 if city_id == here_city else int(dist.get(node, 99))
		if steps >= 99:
			continue
		var value := _liquidation_here(player, city_id)
		var score := float(value) - ceilf(float(steps) / 3.0) * HARD_SILVER_PER_TURN
		if score > best_score:
			best_score = score
			best_city = city_id
			best_steps = steps
	# 不去任何城也能直售：当场（若在城里）或最近的城
	return [best_city, best_score, best_steps]


## 带货赶路：朝"卖价减路程"最划算的城市走，能到就正好停在那里。
static func _hard_haul_move(player: PlayerState) -> Dictionary:
	if player.cargo_count() == 0:
		return {}
	var target: Array = _hard_sell_target(player)
	var city_id := String(target[0])
	if city_id.is_empty():
		return {}
	var goal := String(GameState.content["cities"][city_id].get("board_node_id", ""))
	if goal == player.current_node_id:
		return {}              # 当场就是最好的卖处：交回原有策略（通常原地贸易）
	var to_goal := _steps_from(goal)
	var no_switch: Array = _build_move_candidates(player, player.active_transport, false)
	var switch_candidates: Array = []
	if MovementSystem.can_switch_transport(player):
		switch_candidates = _build_move_candidates(player, player.reserve_transport, true)
	var pick := func(cands: Array) -> Array:
		var b: Dictionary = {}
		var bd := 999
		for c_value in cands:
			var c: Dictionary = c_value
			var d := int(to_goal.get(String(c["node_id"]), 999))
			if d < bd or (d == bd and not b.is_empty() and int(c["steps"]) > int(b["steps"])):
				bd = d
				b = c
		return [b, bd]
	var stay: Array = pick.call(no_switch)
	var swap: Array = pick.call(switch_candidates)
	var best: Dictionary = stay[0]
	if not (swap[0] as Dictionary).is_empty() and int(swap[1]) < int(stay[1]):
		best = swap[0]
	if best.is_empty():
		return {}
	return {
		"action": "MOVE",
		"blocked": false,
		"legal_candidates": no_switch + switch_candidates,
		"chosen": best,
		"score": int(target[1]),
		"reason": "带货前往 %s 变现（算上路程最划算）。" % city_id,
	}


## 空仓进货：候选与原有策略相同（只做估算严格赚钱的买卖），但按 利润 ÷（1 + 到最佳卖货城的
## 回合数）挑，近处能卖的小生意优先于要横穿地图的大生意。其余情形交回原有策略。
static func _hard_buy(player: PlayerState) -> Dictionary:
	if player.cargo_count() != 0:
		return {}
	var ratio_candidates: Array = TradeSystem.get_legal_ratio_actions(player)
	var legal_candidates: Array = ratio_candidates.duplicate(true)
	var direct_sale: Dictionary = TradeSystem.get_legal_direct_sale(player)
	if bool(direct_sale.get("can_sell", false)):
		legal_candidates.append({"action": "TRADE_DIRECT_SALE", "selection": direct_sale["selection"]})
	var current_city := GameData.get_city_at_node(GameState.content, player.current_node_id)
	var dist := _steps_from(player.current_node_id)
	var best: Dictionary = {}
	var best_rate := 0.0
	for c_value in ratio_candidates:
		var c: Dictionary = c_value
		if not (
			String(c["give_resource"].get("resource_kind", "")) == "SILVER"
			and String(c["receive_resource"].get("resource_kind", "")) == "GOOD"
			and int(c["cargo_delta"]) > 0
		):
			continue
		var unit_cost := int(c["give_resource"].get("quantity", 0))
		var unit_goods := int(c["receive_resource"].get("quantity", 0))
		var good_id := String(c["receive_resource"].get("resource_id", ""))
		for times in range(1, int(c.get("max_times", 0)) + 1):
			var sell := _best_liquidation_city(good_id, unit_goods * times, current_city, dist)
			var profit := int(sell[0]) - unit_cost * times
			if profit <= 0:
				continue
			var turns := 1.0 + ceilf(float(sell[1]) / 3.0)
			var rate := float(profit) / turns
			if rate > best_rate:
				best_rate = rate
				best = c.duplicate(true)
				best["max_times"] = times
				best["estimated_profit"] = profit
	if best.is_empty():
		return {}
	return _ratio_decision(legal_candidates, best, 0, "进货：预计每回合赚 %.1f 白银。" % best_rate)


## [最佳变现白银, 到那座城的步数]；与 _best_liquidation_value 同口径（余量 1 银/件），
## 同价时取近的。
static func _best_liquidation_city(good_id: String, quantity: int, excluded_city_id: String, dist: Dictionary) -> Array:
	var content: Dictionary = GameState.content
	var best_value := quantity
	var best_steps := 99
	for city_id_value in GameState.city_market_states.keys():
		var city_id := String(city_id_value)
		if city_id == excluded_city_id:
			continue
		var card_id := String(GameState.city_market_states[city_id].get("current_trade_card_id", ""))
		if card_id.is_empty() or not content.get("trade_card_index", {}).has(card_id):
			continue
		var node := String(content["cities"].get(city_id, {}).get("board_node_id", ""))
		var steps := int(dist.get(node, 99))
		var entries: Array = GameData.get_trade_card(content, card_id).get("entries", [])
		for give_value in entries:
			var give: Dictionary = give_value
			if String(give.get("resource_kind", "")) != "GOOD" or String(give.get("resource_id", "")) != good_id:
				continue
			var give_quantity := int(give.get("quantity", 0))
			if give_quantity <= 0:
				continue
			for receive_value in entries:
				var receive: Dictionary = receive_value
				if String(receive.get("resource_kind", "")) != "SILVER":
					continue
				var times := quantity / give_quantity
				var value := times * int(receive.get("quantity", 0)) + (quantity - times * give_quantity)
				if value > best_value or (value == best_value and steps < best_steps):
					best_value = value
					best_steps = steps
	return [best_value, best_steps if best_steps < 99 else 3]


## 从某节点出发到各节点的步数（陆路海路都算，换乘忽略不计）。
static func _steps_from(from_node_id: String) -> Dictionary:
	var content: Dictionary = GameState.content
	if CustomMapFreeAuthor.enabled(content.get("custom_map",{}).get("overlay",{})):
		return CustomMapFreeAuthor.node_distances(content,from_node_id)
	var distance := {from_node_id: 0}
	var frontier: Array[String] = [from_node_id]
	while not frontier.is_empty():
		var current := String(frontier.pop_front())
		for route_type in [GameData.route_type_for_transport(GameData.Transport.CAMEL), GameData.route_type_for_transport(GameData.Transport.SHIP)]:
			for edge in GameData.get_edges_from(content, current, route_type):
				var other := GameData.edge_other_node(edge, current)
				if not distance.has(other):
					distance[other] = int(distance[current]) + 1
					frontier.append(other)
	return distance


# ---------- 轻装启程（7 岁）：简单、随性 ----------

## 0..1 的确定性"随性"：取自对局种子、轮次、位置与持银，不消耗规则 RNG。
static func _whim(player: PlayerState, salt: String) -> float:
	var key := "%d|%d|%s|%s|%d|%d|%s" % [GameState.rng_seed, GameState.round_index, player.player_id, player.current_node_id, player.silver, player.movement_budget, salt]
	return float(hash(key) & 0x7fffffff) / float(0x7fffffff)


static func _easy_move(player: PlayerState) -> Dictionary:
	# 约三分之一的时候随便走走（只用手上的交通工具，7 岁不会想到先换乘再走），
	# 其余时候和 12 岁一样找有生意的城市
	if _whim(player, "wander") >= 0.35:
		return choose_move_standard(player)
	var candidates: Array = _build_move_candidates(player, player.active_transport, false)
	if candidates.is_empty():
		return choose_move_standard(player)
	var chosen: Dictionary = candidates[int(_whim(player, "pick") * candidates.size()) % candidates.size()]
	return {
		"action": "MOVE",
		"blocked": false,
		"legal_candidates": candidates,
		"chosen": chosen,
		"score": 0,
		"reason": "随便走走。",
	}


static func _easy_trade(player: PlayerState) -> Dictionary:
	var ratio_candidates: Array = TradeSystem.get_legal_ratio_actions(player)
	var direct_sale: Dictionary = TradeSystem.get_legal_direct_sale(player)
	var legal_candidates: Array = ratio_candidates.duplicate(true)
	if bool(direct_sale.get("can_sell", false)):
		legal_candidates.append({"action": "TRADE_DIRECT_SALE", "selection": direct_sale["selection"]})
	var skip := {
		"action": "SKIP_TRADE",
		"blocked": false,
		"legal_candidates": legal_candidates,
		"chosen": {"action": "SKIP_TRADE", "kind": "skip"},
		"priority": 5,
		"reason": "这次先不交易。",
	}
	if _whim(player, "forget") < 0.15:
		return skip
	if player.cargo_count() == 0:
		# 知道买了要能赚：只做看得出赚钱的买卖，但一次只买一两份
		var buy_candidates: Array = []
		for c in ratio_candidates:
			if (
				String(c["give_resource"].get("resource_kind", "")) == "SILVER"
				and String(c["receive_resource"].get("resource_kind", "")) == "GOOD"
				and int(c["cargo_delta"]) > 0
			):
				buy_candidates.append(c)
		var best_buy := _pick_profitable_buy(player, buy_candidates)
		if best_buy.is_empty():
			return skip
		var choice: Dictionary = best_buy.duplicate(true)
		choice["max_times"] = mini(int(choice["max_times"]), 1 + int(_whim(player, "qty") * 2.0))
		return _ratio_decision(legal_candidates, choice, 2, "买一点能赚钱的货。")
	# 有货就当场卖：牌面兑银与整仓直售取高者，不会想着运去别的城市卖更贵
	var best_silver: Dictionary = {}
	for c in ratio_candidates:
		if String(c["receive_resource"].get("resource_kind", "")) == "SILVER" and int(c["silver_gain"]) > 0:
			if best_silver.is_empty() or int(c["silver_gain"]) > int(best_silver["silver_gain"]):
				best_silver = c
	if not best_silver.is_empty() and int(best_silver["silver_gain"]) > _direct_sale_gain(direct_sale):
		return _ratio_decision(legal_candidates, best_silver, 1, "按牌面换成白银。")
	if bool(direct_sale.get("can_sell", false)):
		return {
			"action": "TRADE_DIRECT_SALE",
			"blocked": false,
			"legal_candidates": legal_candidates,
			"chosen": {"action": "TRADE_DIRECT_SALE", "kind": "direct_sale", "selection": direct_sale["selection"]},
			"priority": 2,
			"reason": "把货都卖了。",
		}
	return skip
