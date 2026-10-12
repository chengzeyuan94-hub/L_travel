class_name TradePanelHelper
extends RefCounted

## 交易面板只读展示逻辑：从 TradeSystem 合法 actions 生成选项文案与 metadata。
## 不实现第二套交易规则；不修改 GameState。
## 交付项可以是货物或白银。


static func format_entry_compact(entry: Dictionary) -> String:
	if String(entry.get("resource_kind", "")) == "SILVER":
		return "白银×%d" % int(entry.get("quantity", 1))
	return "%s×%d" % [
		GameData.get_good_name(GameState.content, String(entry.get("resource_id", ""))),
		int(entry.get("quantity", 1)),
	]


static func format_card_ratio(card: Dictionary) -> String:
	if card.is_empty():
		return ""
	var parts: Array[String] = []
	for entry in card.get("entries", []):
		parts.append(format_entry_compact(entry))
	return " ＝ ".join(parts)


static func build_give_items(actions: Array, player: PlayerState, card: Dictionary) -> Array:
	## 返回 [{give_index, label}]，含合法 GOOD / SILVER 交付项。
	var seen := {}
	var items: Array = []
	var entries: Array = card.get("entries", [])
	for action in actions:
		var give_index := int(action.get("give_index", -1))
		if give_index < 0 or seen.has(give_index):
			continue
		if give_index >= entries.size():
			continue
		var give: Dictionary = entries[give_index]
		var kind := String(give.get("resource_kind", ""))
		if kind != "GOOD" and kind != "SILVER":
			continue
		seen[give_index] = true
		var held := player.silver if kind == "SILVER" else player.held_count(String(give.get("resource_id", "")))
		var label := "%s（持有 %d）" % [format_entry_compact(give), held]
		items.append({"give_index": give_index, "label": label})
	items.sort_custom(func(a, b): return int(a["give_index"]) < int(b["give_index"]))
	return items


static func build_give_items_from_candidates(candidate_states: Array, player: PlayerState, card: Dictionary) -> Array:
	## 与 build_give_items 类似，但保留当前不可成交的牌面交付项，供 UI 灰显其回报。
	var seen := {}
	var items: Array = []
	var entries: Array = card.get("entries", [])
	for state in candidate_states:
		var give_index := int(state.get("give_index", -1))
		if give_index < 0 or give_index >= entries.size() or seen.has(give_index):
			continue
		var give: Dictionary = entries[give_index]
		var kind := String(give.get("resource_kind", ""))
		if kind != "GOOD" and kind != "SILVER":
			continue
		seen[give_index] = true
		var held := player.silver if kind == "SILVER" else player.held_count(String(give.get("resource_id", "")))
		var has_enabled_pair := false
		for pair in candidate_states:
			if int(pair.get("give_index", -1)) == give_index and bool(pair.get("enabled", false)):
				has_enabled_pair = true
				break
		items.append(
			{
				"give_index": give_index,
				"label": "%s（持有 %d）" % [format_entry_compact(give), held],
				"enabled": has_enabled_pair,
			}
		)
	items.sort_custom(func(a, b): return int(a["give_index"]) < int(b["give_index"]))
	return items


static func build_receive_items(actions: Array, give_index: int, card: Dictionary) -> Array:
	## 返回 [{receive_index, max_times, label}]；不含当前 give entry。
	var items: Array = []
	var entries: Array = card.get("entries", [])
	for action in actions:
		if int(action.get("give_index", -1)) != give_index:
			continue
		var receive_index := int(action.get("receive_index", -1))
		if receive_index < 0 or receive_index == give_index:
			continue
		if receive_index >= entries.size():
			continue
		var receive: Dictionary = entries[receive_index]
		var max_times := int(action.get("max_times", 0))
		items.append(
			{
				"receive_index": receive_index,
				"max_times": max_times,
				"label": format_entry_compact(receive),
			}
		)
	items.sort_custom(func(a, b): return int(a["receive_index"]) < int(b["receive_index"]))
	return items


static func build_receive_items_from_candidates(candidate_states: Array, give_index: int, card: Dictionary) -> Array:
	## 返回牌面全部回报候选。enabled=false 的项仍展示，但必须由 UI 禁用并说明原因。
	var items: Array = []
	var entries: Array = card.get("entries", [])
	for state in candidate_states:
		if int(state.get("give_index", -1)) != give_index:
			continue
		var receive_index := int(state.get("receive_index", -1))
		if receive_index < 0 or receive_index == give_index or receive_index >= entries.size():
			continue
		var receive: Dictionary = entries[receive_index]
		items.append(
			{
				"receive_index": receive_index,
				"max_times": int(state.get("max_times", 0)),
				"label": format_entry_compact(receive),
				"enabled": bool(state.get("enabled", false)),
				"reason_code": String(state.get("reason_code", "")),
				"message": String(state.get("message", "")),
			}
		)
	items.sort_custom(func(a, b): return int(a["receive_index"]) < int(b["receive_index"]))
	return items


static func format_preview(card: Dictionary, give_index: int, receive_index: int, max_times: int) -> String:
	var entries: Array = card.get("entries", [])
	if give_index < 0 or receive_index < 0 or give_index >= entries.size() or receive_index >= entries.size():
		return ""
	var give: Dictionary = entries[give_index]
	var receive_text := format_entry_compact(entries[receive_index])
	var give_text := format_entry_compact(give)
	var verb := "支付" if String(give.get("resource_kind", "")) == "SILVER" else "交付"
	return "%s %s → 获得 %s\n最多可兑换 %d 次" % [verb, give_text, receive_text, max_times]


static func trade_state_signature(player: PlayerState) -> String:
	var city_id := GameData.get_city_at_node(GameState.content, player.current_node_id)
	var card := TradeSystem.get_trade_card_for_city(city_id)
	var card_id := String(card.get("id", ""))
	return "%s|%s|%s|%s|%d|%d|%d|%s|%s|%s" % [
		player.player_id,
		city_id,
		card_id,
		str(player.inventory),
		player.silver,
		player.cargo_count(),
		player.warehouse_capacity,
		str(GameState.goods_supply),
		str(GameState.phase),
		str(player.trade_action_used),
	]
