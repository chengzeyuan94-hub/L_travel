class_name TradeSelectorModel
extends RefCounted

## 比例兑换纯 UI 状态：成交只来自 TradeSystem 合法 actions；
## candidate_states 额外保留不可成交的牌面项，供 UI 灰显原因。
## 不修改 GameState；不复制容量/供应/银两公式。

var card_id: String = ""
var card: Dictionary = {}
var actions: Array = []
var candidate_states: Array = []
var give_candidates: Array = []
var receive_candidates: Array = []
var give_cursor: int = 0
var receive_cursor: int = 0
var times: int = 1
var max_times: int = 0
var can_trade: bool = false
var reason_code: String = ""
var message: String = ""


func clear() -> void:
	card_id = ""
	card = {}
	actions = []
	candidate_states = []
	give_candidates = []
	receive_candidates = []
	give_cursor = 0
	receive_cursor = 0
	times = 0
	max_times = 0
	can_trade = false
	reason_code = ""
	message = ""


func load_from_availability(availability: Dictionary, trade_card: Dictionary, player: PlayerState) -> void:
	clear()
	card = trade_card.duplicate(true) if not trade_card.is_empty() else {}
	card_id = String(card.get("id", ""))
	actions = availability.get("actions", []).duplicate(true)
	candidate_states = availability.get("candidate_states", []).duplicate(true)
	if candidate_states.is_empty():
		for action in actions:
			var enabled_action: Dictionary = action.duplicate(true)
			enabled_action["enabled"] = true
			enabled_action["reason_code"] = ""
			enabled_action["message"] = ""
			candidate_states.append(enabled_action)
	can_trade = false
	reason_code = String(availability.get("reason_code", ""))
	message = String(availability.get("message", ""))
	if player == null or card.is_empty():
		return
	give_candidates = (
		TradePanelHelper.build_give_items_from_candidates(candidate_states, player, card)
		if not candidate_states.is_empty()
		else TradePanelHelper.build_give_items(actions, player, card)
	)
	if give_candidates.is_empty():
		return
	give_cursor = _first_enabled_give_cursor()
	_rebuild_receive_candidates(true)
	times = 1 if max_times >= 1 else 0
	_clamp_times()


func has_candidates() -> bool:
	return not give_candidates.is_empty() and not receive_candidates.is_empty()


func give_index() -> int:
	if give_candidates.is_empty() or give_cursor < 0 or give_cursor >= give_candidates.size():
		return -1
	return int(give_candidates[give_cursor].get("give_index", -1))


func receive_index() -> int:
	if receive_candidates.is_empty() or receive_cursor < 0 or receive_cursor >= receive_candidates.size():
		return -1
	return int(receive_candidates[receive_cursor].get("receive_index", -1))


func current_action() -> Dictionary:
	var g := give_index()
	var r := receive_index()
	if g < 0 or r < 0:
		return {}
	for action in actions:
		if int(action.get("give_index", -1)) == g and int(action.get("receive_index", -1)) == r:
			return action
	return {}


func selection_meta() -> Dictionary:
	var action := current_action()
	if action.is_empty() or times < 1:
		return {}
	return {
		"give_index": give_index(),
		"receive_index": receive_index(),
		"max_times": max_times,
		"times": times,
	}


func cycle_give(delta: int) -> bool:
	if give_candidates.size() <= 1 or delta == 0:
		return false
	var size := give_candidates.size()
	give_cursor = posmod(give_cursor + delta, size)
	_rebuild_receive_candidates(false)
	_clamp_times()
	return true


func cycle_receive(delta: int) -> bool:
	if receive_candidates.size() <= 1 or delta == 0:
		return false
	var size := receive_candidates.size()
	var next := receive_cursor
	for _i in size:
		next = posmod(next + delta, size)
		if bool(receive_candidates[next].get("enabled", false)):
			receive_cursor = next
			_refresh_max_times_from_cursor()
			_clamp_times()
			return true
	return false


func adjust_times(delta: int) -> bool:
	if max_times < 1 or delta == 0:
		return false
	var next := clampi(times + delta, 1, max_times)
	if next == times:
		return false
	times = next
	return true


func set_times(value: int) -> void:
	_refresh_max_times_from_cursor()
	times = value
	_clamp_times()


func select_give_by_index(target_give: int) -> bool:
	for i in give_candidates.size():
		if int(give_candidates[i].get("give_index", -1)) == target_give:
			give_cursor = i
			_rebuild_receive_candidates(false)
			_clamp_times()
			return true
	return false


func select_receive_by_index(target_receive: int) -> bool:
	for i in receive_candidates.size():
		if (
			int(receive_candidates[i].get("receive_index", -1)) == target_receive
			and bool(receive_candidates[i].get("enabled", false))
		):
			receive_cursor = i
			_refresh_max_times_from_cursor()
			_clamp_times()
			return true
	return false


func give_entry() -> Dictionary:
	var idx := give_index()
	var entries: Array = card.get("entries", [])
	if idx < 0 or idx >= entries.size():
		return {}
	return entries[idx]


func receive_entry() -> Dictionary:
	var idx := receive_index()
	var entries: Array = card.get("entries", [])
	if idx < 0 or idx >= entries.size():
		return {}
	return entries[idx]


func give_total() -> int:
	var entry := give_entry()
	if entry.is_empty() or times < 1:
		return 0
	return int(entry.get("quantity", 0)) * times


func receive_total() -> int:
	var entry := receive_entry()
	if entry.is_empty() or times < 1:
		return 0
	return int(entry.get("quantity", 0)) * times


func can_dec_times() -> bool:
	return max_times >= 1 and times > 1


func can_inc_times() -> bool:
	return max_times >= 1 and times < max_times


func _rebuild_receive_candidates(reset_cursor: bool) -> void:
	var prev_receive := -1 if reset_cursor else receive_index()
	receive_candidates = (
		TradePanelHelper.build_receive_items_from_candidates(candidate_states, give_index(), card)
		if not candidate_states.is_empty()
		else TradePanelHelper.build_receive_items(actions, give_index(), card)
	)
	receive_cursor = _first_enabled_receive_cursor()
	if prev_receive >= 0:
		for i in receive_candidates.size():
			if (
				int(receive_candidates[i].get("receive_index", -1)) == prev_receive
				and bool(receive_candidates[i].get("enabled", false))
			):
				receive_cursor = i
				break
	_refresh_max_times_from_cursor()


func _refresh_max_times_from_cursor() -> void:
	max_times = 0
	can_trade = false
	if receive_candidates.is_empty() or receive_cursor < 0 or receive_cursor >= receive_candidates.size():
		return
	if not bool(receive_candidates[receive_cursor].get("enabled", false)):
		return
	max_times = int(receive_candidates[receive_cursor].get("max_times", 0))
	var action := current_action()
	if not action.is_empty():
		max_times = int(action.get("max_times", max_times))
	can_trade = max_times >= 1 and not action.is_empty()


func _clamp_times() -> void:
	if max_times < 1:
		times = 0
		return
	if times < 1:
		times = 1
	times = clampi(times, 1, max_times)


func _first_enabled_give_cursor() -> int:
	for i in give_candidates.size():
		if bool(give_candidates[i].get("enabled", true)):
			return i
	return 0


func _first_enabled_receive_cursor() -> int:
	for i in receive_candidates.size():
		if bool(receive_candidates[i].get("enabled", true)):
			return i
	return 0
