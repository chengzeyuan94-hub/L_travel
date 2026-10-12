class_name TradeSystem

## 原版贸易：贸易卡等量代换（货物⇄货物、货物⇄白银、白银→货物）、每件 1 白银直接出售、免费丢弃。
## 只修改 GameState；非法操作原子失败，成功命令只发出一次 state_changed。
## 查询接口无副作用。

## 当前玩家当前城市最上方贸易卡；不在城市或无卡时返回空 Dictionary。
static func get_current_trade_card() -> Dictionary:
	var player := GameState.current_player()
	return get_trade_card_for_city(GameData.get_city_at_node(GameState.content, player.current_node_id))


## 只读：指定城市当前贸易卡。
static func get_trade_card_for_city(city_id: String) -> Dictionary:
	if city_id.is_empty() or not GameState.city_market_states.has(city_id):
		return {}
	var card_id := String(GameState.city_market_states[city_id]["current_trade_card_id"])
	if card_id.is_empty():
		return {}
	return GameData.get_trade_card(GameState.content, card_id)


## 只读：给定交付/回报项的最大完整倍数。GOOD 与 SILVER 均可作为交付或回报，禁止 SILVER→SILVER。
static func get_max_trade_times(player: PlayerState, give: Dictionary, receive: Dictionary) -> int:
	var give_kind := String(give.get("resource_kind", ""))
	var receive_kind := String(receive.get("resource_kind", ""))
	if give_kind != "GOOD" and give_kind != "SILVER":
		return 0
	if receive_kind != "GOOD" and receive_kind != "SILVER":
		return 0
	if give_kind == "SILVER" and receive_kind == "SILVER":
		return 0
	var give_qty := int(give.get("quantity", 0))
	var receive_qty := int(receive.get("quantity", 0))
	if give_qty <= 0 or receive_qty <= 0:
		return 0
	var give_is_good := give_kind == "GOOD"
	var receive_is_good := receive_kind == "GOOD"
	var give_good := String(give.get("resource_id", "")) if give_is_good else ""
	var receive_good := String(receive.get("resource_id", "")) if receive_is_good else ""
	var times := 0
	while true:
		var next := times + 1
		if give_is_good:
			if player.held_count(give_good) < give_qty * next:
				break
		else:
			if player.silver < give_qty * next:
				break
		if receive_is_good:
			if int(GameState.goods_supply.get(receive_good, 0)) < receive_qty * next:
				break
			var cargo_after := player.cargo_count()
			if give_is_good:
				cargo_after -= give_qty * next
			cargo_after += receive_qty * next
			if cargo_after > player.warehouse_capacity:
				break
		# GOOD→SILVER：不因公共银库余额限制倍数；不足时由 payout_silver 动用盒内备用并触发终局。
		times = next
		if times >= 99:
			break
	return times


## 只读：合法比例兑换候选，按 give/receive index 稳定排序。
static func get_legal_ratio_actions(player: PlayerState, city_id: String = "") -> Array:
	var availability := get_ratio_trade_availability(player, city_id)
	return availability.get("actions", [])


## 只读：比例兑换可用性与失败原因；无副作用、不抽卡、不改库存、不发信号、不耗 RNG。
static func get_ratio_trade_availability(player: PlayerState, city_id: String = "") -> Dictionary:
	var gate := _trade_city_gate(player, city_id)
	if not bool(gate.get("ok", false)):
		return _unavailable(String(gate.get("reason_code", "")), String(gate.get("message", "")))
	var card: Dictionary = gate["card"]
	var actions: Array = _build_legal_ratio_actions(player, card)
	if not actions.is_empty():
		return {
			"can_trade": true,
			"actions": actions,
			"reason_code": "",
			"message": "",
		}
	return _diagnose_ratio_block(player, card)


## 只读：银两买入（SILVER→GOOD）可用性；不新增价格公式，只筛牌面合法 actions。
static func get_buy_availability(player: PlayerState, city_id: String = "") -> Dictionary:
	var gate := _trade_city_gate(player, city_id)
	if not bool(gate.get("ok", false)):
		return _unavailable(String(gate.get("reason_code", "")), String(gate.get("message", "")))
	var card: Dictionary = gate["card"]
	if not _card_has_silver_entry(card):
		return _unavailable("NO_SILVER_ENTRY", "当前贸易卡不支持银两买入。")
	var candidate_states := _build_ratio_candidate_states(player, card, "SILVER", "GOOD")
	var actions := _enabled_actions(candidate_states)
	if not actions.is_empty():
		return {
			"can_trade": true,
			"actions": actions,
			"candidate_states": candidate_states,
			"reason_code": "",
			"message": "",
		}
	return _with_candidate_states(_diagnose_buy_block(player, card), candidate_states)


## 只读：牌面货物兑换（GOOD→GOOD）；不含银两买入与牌面出售。
static func get_exchange_availability(player: PlayerState, city_id: String = "") -> Dictionary:
	var gate := _trade_city_gate(player, city_id)
	if not bool(gate.get("ok", false)):
		return _unavailable(String(gate.get("reason_code", "")), String(gate.get("message", "")))
	var card: Dictionary = gate["card"]
	var candidate_states := _build_ratio_candidate_states(player, card, "GOOD", "GOOD")
	var actions := _enabled_actions(candidate_states)
	if not actions.is_empty():
		return {
			"can_trade": true,
			"actions": actions,
			"candidate_states": candidate_states,
			"reason_code": "",
			"message": "",
		}
	return _with_candidate_states(_diagnose_exchange_block(player, card), candidate_states)


## 只读：按当前城市贸易卡出售（GOOD→SILVER）。
## 与“任意货物每件 1 白银”的兜底直售严格分离。
static func get_card_sale_availability(player: PlayerState, city_id: String = "") -> Dictionary:
	var gate := _trade_city_gate(player, city_id)
	if not bool(gate.get("ok", false)):
		return _unavailable(String(gate.get("reason_code", "")), String(gate.get("message", "")))
	var card: Dictionary = gate["card"]
	if not _card_has_silver_entry(card):
		return _unavailable("NO_SILVER_ENTRY", "当前贸易卡不支持牌面出售。")
	var candidate_states := _build_ratio_candidate_states(player, card, "GOOD", "SILVER")
	var actions := _enabled_actions(candidate_states)
	if not actions.is_empty():
		return {
			"can_trade": true,
			"actions": actions,
			"candidate_states": candidate_states,
			"reason_code": "",
			"message": "",
		}
	return _with_candidate_states(_diagnose_card_sale_block(player, card), candidate_states)


## 只读：返回牌面上某一交易模式的全部候选，包括当前不可成交的候选。
## UI 用 enabled/reason_code 灰显；正式提交仍必须经过 trade_ratio() 的完整比例校验。
static func _build_ratio_candidate_states(
	player: PlayerState, card: Dictionary, give_kind_filter: String, receive_kind_filter: String
) -> Array:
	var states: Array = []
	var entries: Array = card.get("entries", [])
	for give_index in entries.size():
		var give: Dictionary = entries[give_index]
		if String(give.get("resource_kind", "")) != give_kind_filter:
			continue
		for receive_index in entries.size():
			if receive_index == give_index:
				continue
			var receive: Dictionary = entries[receive_index]
			if String(receive.get("resource_kind", "")) != receive_kind_filter:
				continue
			var max_times := get_max_trade_times(player, give, receive)
			var state := _ratio_action(give_index, receive_index, give, receive, max_times)
			state["enabled"] = max_times >= 1
			if max_times < 1:
				var reason := _diagnose_ratio_pair(player, give, receive)
				state["reason_code"] = String(reason.get("reason_code", ""))
				state["message"] = String(reason.get("message", ""))
			else:
				state["reason_code"] = ""
				state["message"] = ""
			states.append(state)
	states.sort_custom(
		func(a, b):
			if a["give_index"] != b["give_index"]:
				return a["give_index"] < b["give_index"]
			return a["receive_index"] < b["receive_index"]
	)
	return states


static func _enabled_actions(candidate_states: Array) -> Array:
	var actions: Array = []
	for state in candidate_states:
		if bool(state.get("enabled", false)):
			actions.append(state.duplicate(true))
	return actions


static func _with_candidate_states(result: Dictionary, candidate_states: Array) -> Dictionary:
	var enriched := result.duplicate(true)
	enriched["candidate_states"] = candidate_states
	return enriched


static func _ratio_action(
	give_index: int,
	receive_index: int,
	give: Dictionary,
	receive: Dictionary,
	max_times: int
) -> Dictionary:
	var give_kind := String(give.get("resource_kind", ""))
	var receive_kind := String(receive.get("resource_kind", ""))
	var give_total := int(give.get("quantity", 0)) * max_times
	var receive_total := int(receive.get("quantity", 0)) * max_times
	var give_is_good := give_kind == "GOOD"
	var receive_is_good := receive_kind == "GOOD"
	var cargo_delta := 0
	if give_is_good:
		cargo_delta -= give_total
	if receive_is_good:
		cargo_delta += receive_total
	var silver_cost := 0 if give_is_good else give_total
	var silver_gain := 0 if receive_is_good else receive_total
	return {
		"give_index": give_index,
		"receive_index": receive_index,
		"max_times": max_times,
		"give_resource": give.duplicate(true),
		"receive_resource": receive.duplicate(true),
		"cargo_delta": cargo_delta,
		"silver_delta": silver_gain - silver_cost,
		"silver_cost": silver_cost,
		"silver_gain": silver_gain,
		"is_silver": not receive_is_good,
		"is_silver_give": not give_is_good,
	}


static func _diagnose_ratio_pair(player: PlayerState, give: Dictionary, receive: Dictionary) -> Dictionary:
	var give_kind := String(give.get("resource_kind", ""))
	var receive_kind := String(receive.get("resource_kind", ""))
	var give_qty := int(give.get("quantity", 0))
	var receive_qty := int(receive.get("quantity", 0))
	if give_kind == "SILVER" and player.silver < give_qty:
		return {
			"reason_code": "INSUFFICIENT_SILVER",
			"message": "完整比例需要白银×%d，当前只有 %d。" % [give_qty, player.silver],
		}
	if give_kind == "GOOD":
		var give_id := String(give.get("resource_id", ""))
		if player.held_count(give_id) < give_qty:
			return {
				"reason_code": "INSUFFICIENT_QTY",
				"message": "完整比例需要%s×%d，当前持有 %d。" % [
					GameData.get_good_name(GameState.content, give_id),
					give_qty,
					player.held_count(give_id),
				],
			}
	if receive_kind == "GOOD":
		var receive_id := String(receive.get("resource_id", ""))
		if int(GameState.goods_supply.get(receive_id, 0)) < receive_qty:
			return {"reason_code": "SUPPLY_SHORT", "message": "该货物的公共供应不足。"}
		var cargo_after := player.cargo_count() + receive_qty
		if give_kind == "GOOD":
			cargo_after -= give_qty
		if cargo_after > player.warehouse_capacity:
			return {"reason_code": "CARGO_FULL", "message": "货仓空间不足。"}
	return {"reason_code": "UNAVAILABLE", "message": "当前无法按完整比例完成该交易。"}


static func _trade_city_gate(player: PlayerState, city_id: String = "") -> Dictionary:
	if player == null:
		return {"ok": false, "reason_code": "NOT_IN_CITY", "message": "当前不在城市。", "card": {}}
	if player.trade_action_used:
		return {"ok": false, "reason_code": "TRADE_USED", "message": "本回合已经完成贸易。", "card": {}}
	var resolved_city := city_id
	if resolved_city.is_empty():
		resolved_city = GameData.get_city_at_node(GameState.content, player.current_node_id)
	if resolved_city.is_empty() or (
		city_id.is_empty() and not GameData.is_city_node(GameState.content, player.current_node_id)
	):
		return {"ok": false, "reason_code": "NOT_IN_CITY", "message": "当前不在城市。", "card": {}}
	if not GameState.city_market_states.has(resolved_city):
		return {"ok": false, "reason_code": "NO_ROUTE", "message": "当前城市尚未开通商道。", "card": {}}
	var market: Dictionary = GameState.city_market_states[resolved_city]
	var card_id := String(market.get("current_trade_card_id", ""))
	if card_id.is_empty():
		return {"ok": false, "reason_code": "NO_ROUTE", "message": "当前城市尚未开通商道。", "card": {}}
	var card := get_trade_card_for_city(resolved_city)
	if card.is_empty():
		return {"ok": false, "reason_code": "NO_ROUTE", "message": "当前城市尚未开通商道。", "card": {}}
	return {"ok": true, "reason_code": "", "message": "", "card": card, "city_id": resolved_city}


static func _card_has_silver_entry(card: Dictionary) -> bool:
	for entry in card.get("entries", []):
		if String(entry.get("resource_kind", "")) == "SILVER":
			return true
	return false


static func _diagnose_buy_block(player: PlayerState, card: Dictionary) -> Dictionary:
	var entries: Array = card.get("entries", [])
	var silver_entry := {}
	var goods: Array = []
	for entry in entries:
		var kind := String(entry.get("resource_kind", ""))
		if kind == "SILVER" and silver_entry.is_empty():
			silver_entry = entry
		elif kind == "GOOD":
			goods.append(entry)
	if silver_entry.is_empty():
		return _unavailable("NO_SILVER_ENTRY", "当前贸易卡不支持银两买入。")
	var silver_qty := int(silver_entry.get("quantity", 0))
	if silver_qty <= 0:
		return _unavailable("NO_SILVER_ENTRY", "当前贸易卡不支持银两买入。")
	if player.silver < silver_qty:
		var need := silver_qty - player.silver
		return _unavailable("INSUFFICIENT_SILVER", "白银不足，还需要 %d 白银。" % need)
	var saw_cargo := false
	var saw_supply := false
	for receive in goods:
		var receive_qty := int(receive.get("quantity", 0))
		if receive_qty <= 0:
			continue
		var rid := String(receive.get("resource_id", ""))
		if int(GameState.goods_supply.get(rid, 0)) < receive_qty:
			saw_supply = true
			continue
		if player.cargo_count() + receive_qty > player.warehouse_capacity:
			saw_cargo = true
			continue
	if saw_cargo:
		return _unavailable("CARGO_FULL", "货仓已满，无法买入货物。")
	if saw_supply:
		return _unavailable("SUPPLY_SHORT", "该货物供应不足。")
	return _unavailable("INSUFFICIENT_SILVER", "白银不足，还需要 %d 白银。" % maxi(silver_qty - player.silver, 1))


static func _diagnose_exchange_block(player: PlayerState, card: Dictionary) -> Dictionary:
	## 兑换模式只关心 GOOD 交付；复用通用诊断，但去掉纯买入语境。
	var diag := _diagnose_ratio_block(player, card)
	if String(diag.get("reason_code", "")) == "INSUFFICIENT_SILVER" and player.cargo_count() == 0:
		return _unavailable("NO_MATCHING_GOOD", "你没有可兑换的货物。")
	return diag


static func _diagnose_card_sale_block(player: PlayerState, card: Dictionary) -> Dictionary:
	if not _card_has_silver_entry(card):
		return _unavailable("NO_SILVER_ENTRY", "当前贸易卡不支持牌面出售。")
	var saw_matching_good := false
	for entry in card.get("entries", []):
		if String(entry.get("resource_kind", "")) != "GOOD":
			continue
		var held := player.held_count(String(entry.get("resource_id", "")))
		if held <= 0:
			continue
		saw_matching_good = true
		if held < int(entry.get("quantity", 0)):
			return _unavailable("INSUFFICIENT_QTY", "持有数量不足以完成当前出售比例。")
	if saw_matching_good:
		return _unavailable("INSUFFICIENT_QTY", "持有数量不足以完成当前出售比例。")
	return _unavailable("NO_MATCHING_GOOD", "你没有符合当前贸易卡的可售货物。")


static func _unavailable(code: String, message: String) -> Dictionary:
	return {
		"can_trade": false,
		"actions": [],
		"reason_code": code,
		"message": message,
	}


static func _build_legal_ratio_actions(player: PlayerState, card: Dictionary) -> Array:
	var actions: Array = []
	var entries: Array = card["entries"]
	for give_index in entries.size():
		var give: Dictionary = entries[give_index]
		var give_kind := String(give.get("resource_kind", ""))
		if give_kind != "GOOD" and give_kind != "SILVER":
			continue
		for receive_index in entries.size():
			if receive_index == give_index:
				continue
			var receive: Dictionary = entries[receive_index]
			var receive_kind := String(receive.get("resource_kind", ""))
			if give_kind == "SILVER" and receive_kind == "SILVER":
				continue
			var max_times := get_max_trade_times(player, give, receive)
			if max_times < 1:
				continue
			var give_total := int(give["quantity"]) * max_times
			var receive_total := int(receive["quantity"]) * max_times
			var give_is_good := give_kind == "GOOD"
			var receive_is_good := receive_kind == "GOOD"
			var cargo_delta := 0
			if give_is_good:
				cargo_delta -= give_total
			if receive_is_good:
				cargo_delta += receive_total
			var silver_cost := 0 if give_is_good else give_total
			var silver_gain := 0 if receive_is_good else receive_total
			actions.append(
				{
					"give_index": give_index,
					"receive_index": receive_index,
					"max_times": max_times,
					"give_resource": give.duplicate(true),
					"receive_resource": receive.duplicate(true),
					"cargo_delta": cargo_delta,
					"silver_delta": silver_gain - silver_cost,
					"silver_cost": silver_cost,
					"silver_gain": silver_gain,
					"is_silver": not receive_is_good,
					"is_silver_give": not give_is_good,
				}
			)
	actions.sort_custom(
		func(a, b):
			if a["give_index"] != b["give_index"]:
				return a["give_index"] < b["give_index"]
			return a["receive_index"] < b["receive_index"]
	)
	return actions


static func _diagnose_ratio_block(player: PlayerState, card: Dictionary) -> Dictionary:
	var entries: Array = card["entries"]
	var card_has_goods := false
	var card_has_silver := false
	var held_on_card := false
	for entry in entries:
		var kind := String(entry.get("resource_kind", ""))
		if kind == "GOOD":
			card_has_goods = true
			var gid := String(entry.get("resource_id", ""))
			if player.held_count(gid) > 0:
				held_on_card = true
		elif kind == "SILVER":
			card_has_silver = true
	var saw_qty := false
	var saw_silver := false
	var saw_cargo := false
	var saw_supply := false
	for give_index in entries.size():
		var give: Dictionary = entries[give_index]
		var give_kind := String(give.get("resource_kind", ""))
		if give_kind != "GOOD" and give_kind != "SILVER":
			continue
		var give_qty := int(give.get("quantity", 0))
		if give_qty <= 0:
			continue
		var give_is_good := give_kind == "GOOD"
		if give_is_good:
			var give_good := String(give["resource_id"])
			if player.held_count(give_good) < give_qty:
				if player.held_count(give_good) > 0:
					saw_qty = true
				continue
		else:
			if player.silver < give_qty:
				if player.silver > 0 or card_has_silver:
					saw_silver = true
				continue
		for receive_index in entries.size():
			if receive_index == give_index:
				continue
			var receive: Dictionary = entries[receive_index]
			var receive_kind := String(receive.get("resource_kind", ""))
			if give_kind == "SILVER" and receive_kind == "SILVER":
				continue
			var receive_is_good := receive_kind == "GOOD"
			var receive_qty := int(receive.get("quantity", 0))
			if receive_is_good:
				var receive_good := String(receive["resource_id"])
				if int(GameState.goods_supply.get(receive_good, 0)) < receive_qty:
					saw_supply = true
					continue
				var cargo_after := player.cargo_count() + receive_qty
				if give_is_good:
					cargo_after -= give_qty
				if cargo_after > player.warehouse_capacity:
					saw_cargo = true
					continue
			if give_is_good:
				saw_qty = true
			else:
				saw_silver = true
	# 当玩家有能力用白银购货，但所有回报都被货仓或公共供应拦住时，
	# 应优先报告真正阻断兑换的原因；不要被“没有持有卡面货物”的兜底文案覆盖。
	if saw_cargo:
		return {
			"can_trade": false,
			"actions": [],
			"reason_code": "CARGO_FULL",
			"message": "货仓空间不足。",
		}
	if saw_supply:
		return {
			"can_trade": false,
			"actions": [],
			"reason_code": "SUPPLY_SHORT",
			"message": "公共商品供应不足。",
		}
	if not held_on_card:
		# 持有货物但不在卡面：优先提示货物不匹配（即便卡上有白银且玩家银为 0）。
		if player.cargo_count() > 0:
			return {
				"can_trade": false,
				"actions": [],
				"reason_code": "NO_MATCHING_GOOD",
				"message": "你持有的货物不在当前贸易卡中。",
			}
		if card_has_silver:
			return {
				"can_trade": false,
				"actions": [],
				"reason_code": "INSUFFICIENT_SILVER",
				"message": "白银不足。",
			}
		if card_has_goods:
			return {
				"can_trade": false,
				"actions": [],
				"reason_code": "NO_MATCHING_GOOD",
				"message": "你持有的货物不在当前贸易卡中。",
			}
	if saw_silver and not held_on_card:
		return {
			"can_trade": false,
			"actions": [],
			"reason_code": "INSUFFICIENT_SILVER",
			"message": "白银不足。",
		}
	if saw_qty:
		return {
			"can_trade": false,
			"actions": [],
			"reason_code": "INSUFFICIENT_QTY",
			"message": "持有数量不足以完成当前比例。",
		}
	if saw_silver:
		return {
			"can_trade": false,
			"actions": [],
			"reason_code": "INSUFFICIENT_SILVER",
			"message": "白银不足。",
		}
	return {
		"can_trade": false,
		"actions": [],
		"reason_code": "NO_MATCHING_GOOD",
		"message": "你持有的货物不在当前贸易卡中。",
	}


## 只读：可直接出售的全部持有货物。
static func get_legal_direct_sale(player: PlayerState) -> Dictionary:
	if player.trade_action_used:
		return {"can_sell": false, "selection": {}, "total": 0}
	if not GameData.is_city_node(GameState.content, player.current_node_id):
		return {"can_sell": false, "selection": {}, "total": 0}
	var selection := {}
	var total := 0
	var good_ids: Array = player.inventory.keys()
	good_ids.sort()
	for good_id in good_ids:
		var count := player.held_count(String(good_id))
		if count > 0:
			selection[String(good_id)] = count
			total += count
	return {"can_sell": total > 0, "selection": selection, "total": total}


## 只读：校验一组直接出售选择并返回预期收益。不得修改状态或触发信号。
static func get_direct_sale_quote(player: PlayerState, selection: Dictionary) -> Dictionary:
	if player == null:
		return {"can_sell": false, "total_items": 0, "silver_gain": 0, "message": "没有可用玩家。"}
	if player.trade_action_used:
		return {"can_sell": false, "total_items": 0, "silver_gain": 0, "message": "本回合已经完成贸易。"}
	if not GameData.is_city_node(GameState.content, player.current_node_id):
		return {"can_sell": false, "total_items": 0, "silver_gain": 0, "message": "当前不在城市。"}
	if selection.is_empty():
		return {"can_sell": false, "total_items": 0, "silver_gain": 0, "message": "请选择要出售的货物。"}
	var total := 0
	for good_id in selection:
		var count := int(selection[good_id])
		if count <= 0:
			return {"can_sell": false, "total_items": 0, "silver_gain": 0, "message": "出售数量必须为正整数。"}
		if player.held_count(String(good_id)) < count:
			return {"can_sell": false, "total_items": 0, "silver_gain": 0, "message": "库存不足。"}
		total += count
	var rate := int(GameState.content["ruleset"].get("direct_sale_rate", 1))
	return {
		"can_sell": total > 0,
		"total_items": total,
		"silver_gain": total * rate,
		"message": "",
	}


## 最终停留城市无贸易卡时开通商道：翻同色牌并从公共白银获得 2。
static func open_trade_route_if_needed() -> Dictionary:
	var player := GameState.current_player()
	if not GameData.is_city_node(GameState.content, player.current_node_id):
		return {"opened": false, "message": ""}
	var city_id := GameData.get_city_at_node(GameState.content, player.current_node_id)
	var market: Dictionary = GameState.city_market_states[city_id]
	if not String(market["current_trade_card_id"]).is_empty():
		return {"opened": false, "message": ""}
	var deck_id := String(GameData.get_city(GameState.content, city_id)["trade_color_id"])
	var new_card_id := _draw_trade_card(deck_id)
	if new_card_id.is_empty():
		push_error("TradeSystem: trade deck '%s' is empty" % deck_id)
		return {"opened": false, "message": ""}
	market["current_trade_card_id"] = new_card_id
	market["trade_route_open"] = true
	market["opened_by_player_id"] = player.player_id
	market["opened_on_turn"] = player.completed_turns
	var paid := GameState.payout_silver(int(GameState.content["ruleset"].get("open_trade_route_reward", 2)))
	player.silver += paid
	player.opened_trade_route_this_turn = true
	var city_name := GameData.get_city_name(GameState.content, city_id)
	print("TradeSystem: %s opened trade route at %s, +%d silver" % [player.player_id, city_id, paid])
	return {"opened": true, "message": "开通商道：%s，获得 %d 白银。" % [city_name, paid]}


static func trade_ratio(give_index: int, receive_index: int, times: int) -> Dictionary:
	var check := _check_trade_phase()
	if not check["success"]:
		return check
	var player := GameState.current_player()
	var card := get_current_trade_card()
	if card.is_empty():
		return _fail("当前城市没有贸易卡。")
	var entries: Array = card["entries"]
	if give_index < 0 or give_index >= entries.size() or receive_index < 0 or receive_index >= entries.size():
		return _fail("无效的兑换项。")
	if give_index == receive_index:
		return _fail("交付与回报不能相同。")
	var give: Dictionary = entries[give_index]
	var receive: Dictionary = entries[receive_index]
	var give_kind := String(give.get("resource_kind", ""))
	var receive_kind := String(receive.get("resource_kind", ""))
	if give_kind != "GOOD" and give_kind != "SILVER":
		return _fail("无效的交付项。")
	if receive_kind != "GOOD" and receive_kind != "SILVER":
		return _fail("无效的回报项。")
	if give_kind == "SILVER" and receive_kind == "SILVER":
		return _fail("不能用白银兑换白银。")
	if times < 1:
		return _fail("兑换必须按完整比例的正整数倍。")
	if get_max_trade_times(player, give, receive) < times:
		if give_kind == "SILVER" and player.silver < int(give["quantity"]) * times:
			return _fail("白银不足。")
		if receive_kind == "GOOD":
			var need := int(receive["quantity"]) * times
			var rid := String(receive["resource_id"])
			if int(GameState.goods_supply.get(rid, 0)) < need:
				return _fail("公共商品供应不足。")
			var cargo_after := player.cargo_count() + need
			if give_kind == "GOOD":
				cargo_after -= int(give["quantity"]) * times
			if cargo_after > player.warehouse_capacity:
				return _fail("货仓空间不足。")
		if give_kind == "GOOD":
			return _fail("交付货物不足。")
		return _fail("无法完成该兑换。")
	var give_total := int(give["quantity"]) * times
	var receive_total := int(receive["quantity"]) * times
	var give_is_good := give_kind == "GOOD"
	var receive_is_good := receive_kind == "GOOD"
	var message := ""
	# 全部校验已通过：原子执行
	if give_is_good:
		var give_good := String(give["resource_id"])
		player.remove_good(give_good, give_total)
		GameState.return_good_to_supply(give_good, give_total)
		var give_name := GameData.get_good_name(GameState.content, give_good)
		if receive_is_good:
			var receive_good := String(receive["resource_id"])
			GameState.take_good_from_supply(receive_good, receive_total)
			player.add_good(receive_good, receive_total)
			var receive_name := GameData.get_good_name(GameState.content, receive_good)
			message = "用 %s ×%d 兑换 %s ×%d。" % [give_name, give_total, receive_name, receive_total]
		else:
			var paid := GameState.payout_silver(receive_total)
			player.silver += paid
			message = "用 %s ×%d 兑换 白银 ×%d。" % [give_name, give_total, paid]
	else:
		player.silver -= give_total
		GameState.return_silver(give_total)
		var receive_good := String(receive["resource_id"])
		GameState.take_good_from_supply(receive_good, receive_total)
		player.add_good(receive_good, receive_total)
		var receive_name := GameData.get_good_name(GameState.content, receive_good)
		message = "用 白银 ×%d 兑换 %s ×%d。" % [give_total, receive_name, receive_total]
	_cover_trade_card(card)
	_complete_trade_action("ratio: %s" % message)
	return {"success": true, "message": message}


static func trade_direct_sale(selection: Dictionary) -> Dictionary:
	var check := _check_trade_phase()
	if not check["success"]:
		return check
	var player := GameState.current_player()
	if selection.is_empty():
		return _fail("请选择要出售的货物。")
	var total := 0
	for good_id in selection:
		var count := int(selection[good_id])
		if count <= 0:
			return _fail("出售数量必须为正整数。")
		if player.held_count(String(good_id)) < count:
			return _fail("库存不足。")
		total += count
	var rate := int(GameState.content["ruleset"].get("direct_sale_rate", 1))
	var payout := total * rate
	for good_id in selection:
		player.remove_good(String(good_id), int(selection[good_id]))
		GameState.return_good_to_supply(String(good_id), int(selection[good_id]))
	# 不足时 payout_silver 拿空公共银库、触发终局，差额计入备用白银。
	var paid := GameState.payout_silver(payout)
	player.silver += paid
	var message := "出售货物 ×%d，获得 %d 白银。" % [total, paid]
	_complete_trade_action("direct_sale: total=%d" % total)
	return {"success": true, "message": message}


static func discard_goods(selection: Dictionary) -> Dictionary:
	if EventSystem.has_pending_decision():
		return _fail("请先完成事件选择。")
	if not GameState.is_in_turn():
		return _fail("当前阶段不能丢弃货物。")
	var player := GameState.current_player()
	if selection.is_empty():
		return _fail("请选择要丢弃的货物。")
	for good_id in selection:
		var count := int(selection[good_id])
		if count <= 0:
			return _fail("丢弃数量必须为正整数。")
		if player.held_count(String(good_id)) < count:
			return _fail("库存不足。")
	var total := 0
	for good_id in selection:
		player.remove_good(String(good_id), int(selection[good_id]))
		GameState.return_good_to_supply(String(good_id), int(selection[good_id]))
		total += int(selection[good_id])
	print("TradeSystem: %s discarded %d goods" % [player.player_id, total])
	GameState.state_changed.emit()
	return {"success": true, "message": "丢弃货物 ×%d。" % total}


static func _check_trade_phase() -> Dictionary:
	if GameState.phase != GameState.Phase.TRADE:
		return _fail("当前阶段不能贸易。")
	var player := GameState.current_player()
	if player.trade_action_used:
		return _fail("本回合已完成贸易。")
	if not GameData.is_city_node(GameState.content, player.current_node_id):
		return _fail("普通道路节点不能贸易。")
	return {"success": true}


static func _complete_trade_action(log_text: String) -> void:
	var player := GameState.current_player()
	player.trade_action_used = true
	GameState.phase = GameState.Phase.END_TURN
	print("TradeSystem: player %s %s | silver=%d cargo=%d" % [player.player_id, log_text, player.silver, player.cargo_count()])
	GameState.state_changed.emit()


static func _draw_trade_card(deck_id: String) -> String:
	var deck_state: Dictionary = GameState.trade_decks_state[deck_id]
	if deck_state["draw"].is_empty():
		var pile: Array = deck_state["discard"]
		# 自制地图的新牌堆带着自己的随机数（rng_state），重洗不动共享随机数；原版 8 堆永远没有这个键
		if deck_state.has("rng_state"):
			CustomMapLoader.shuffle_isolated(deck_state, pile)
		else:
			GameState.rng_shuffle(pile)
		deck_state["draw"] = pile
		deck_state["discard"] = []
	if deck_state["draw"].is_empty():
		return ""
	return deck_state["draw"].pop_front()


## 交易后换成同堆的「另一张」卡（原版：比例交易后换牌）：先翻新卡、再把旧卡放进弃牌堆——
## 抽牌堆恰好抽空时，洗回去的弃牌里就不会有刚盖掉的那张（2026-09-26 贸易卡核对）。
## 整堆只剩这一张时（抽牌堆和弃牌堆都空）留着旧卡。
static func _cover_trade_card(old_card: Dictionary) -> void:
	var old_id := String(old_card["id"])
	var deck_id := GameData.get_deck_of_card(GameState.content, old_id)
	var deck_state: Dictionary = GameState.trade_decks_state[deck_id]
	var player := GameState.current_player()
	var city_id := GameData.get_city_at_node(GameState.content, player.current_node_id)
	var new_card_id := _draw_trade_card(deck_id)
	if new_card_id.is_empty():
		new_card_id = old_id
	else:
		deck_state["discard"].append(old_id)
	GameState.city_market_states[city_id]["current_trade_card_id"] = new_card_id


static func _fail(message: String) -> Dictionary:
	return {"success": false, "message": message}
