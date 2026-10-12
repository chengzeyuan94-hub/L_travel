class_name EventSystem

## 事件卡数据驱动效果解释器。
## 支持 MOVE_BY_RANGE / LOSE_GOOD / GAIN_STARTING_RESOURCE /
## LOSE_HALF_GOODS_MAX_2 / LOSE_HALF_SILVER_MAX_5 / EXCHANGE_ONE_GOOD。
## 不据此断言原版只有这些效果；未知 op 由内容门禁拒绝加载。
## 扩展包「L叔的趣味事件」的 op（GAIN_SILVER / GIFT_STARTING_RESOURCE / DICE_RACE / RANDOM_PRIZE / FLAVOR_PROMPT /
## GAIN_LOCAL_SPECIALTY / PAY_OR_DROP / SOUND_QUIZ，以及 LOSE_GOOD 的 good_filter 参数）分派到
## scripts/expansions/fun_event_ops.gd；原版卡的结算路径和返回值不变。
## 本系统不发出 GameState.state_changed，由所属命令统一发出一次
## （resolve_pending_decision 除外：成功时发一次）。

## 按当前玩家交通工具抽对应牌堆并立即结算。
static func draw_and_resolve(player: PlayerState) -> Dictionary:
	if has_pending_decision():
		return {
			"triggered": false,
			"blocked": true,
			"title": "",
			"description": "",
			"effect_message": "已有未完成的事件选择。",
			"needs_move": false,
			"pending": true,
		}
	var deck_type := GameData.deck_type_for_transport(player.active_transport)
	var deck_state: Dictionary = GameState.event_decks_state[deck_type]
	if deck_state["draw"].is_empty():
		if not _try_reshuffle_event_deck(deck_state):
			# 未声明循环策略时保持 RULE_BLOCKED：说明书未规定正式事件耗尽处理。
			push_error("EventSystem: event deck %d exhausted; reshuffle rule is RULE_BLOCKED" % deck_type)
			return {
				"triggered": false,
				"blocked": true,
				"title": "",
				"description": "",
				"effect_message": "事件牌堆已空，规则待核对。",
				"needs_move": false,
			}
	var instance_id: String = deck_state["draw"].pop_front()
	deck_state["discard"].append(instance_id)
	var instance: Dictionary = GameState.content["event_card_instances"][instance_id]
	var definition: Dictionary = GameState.content["event_definitions"][instance["event_id"]]
	# 扩展包（data/expansions/）的卡才带 expansion_id；原版卡的返回值一个键也不加
	var is_expansion := definition.has("expansion_id")
	var before: Dictionary = FunEventOps.snapshot_players() if is_expansion else {}
	var fx := {}
	var effect_messages: Array[String] = []
	var needs_move := false
	var pending := false
	var blocked := false
	for effect in definition.get("effects", []):
		var applied := _apply_effect(player, effect, String(definition.get("id", "")))
		effect_messages.append(String(applied.get("message", "")))
		needs_move = needs_move or bool(applied.get("needs_move", false))
		pending = pending or bool(applied.get("pending", false))
		blocked = blocked or bool(applied.get("blocked", false))
		if is_expansion and applied.get("fx") is Dictionary:
			fx.merge(applied["fx"], true)
	var effect_text := " ".join(effect_messages)
	print(
		"EventSystem: player %s drew %s (%s) -> %s | silver=%d cargo=%d pending=%s"
		% [
			player.player_id,
			instance_id,
			definition.get("title", "?"),
			effect_text,
			player.silver,
			player.cargo_count(),
			str(pending),
		]
	)
	var result := {
		"triggered": true,
		"blocked": blocked,
		"event_id": String(definition.get("id", "")),
		"title": String(definition.get("title", "")),
		"description": String(definition.get("flavor_text", "")),
		"effect_message": effect_text,
		"needs_move": needs_move,
		"pending": pending,
	}
	if is_expansion:
		FunEventOps.decorate_draw_result(result, definition, instance_id, player, before, fx)
	return result


static func has_pending_decision() -> bool:
	return not GameState.pending_event_decision.is_empty() and not bool(
		GameState.pending_event_decision.get("blocked", false)
	)


static func get_pending_decision() -> Dictionary:
	return GameState.pending_event_decision.duplicate(true)


## 真人/AI 共用的 EXCHANGE_ONE_GOOD 只读可用性快照。
##
## pending 中的 legal_* 字段只说明事件进入待决策时的合法范围；真正提交前仍要按
## 当前库存和商品供应重算，避免 UI 展示已经失效的目标。此查询不修改状态、不消耗
## RNG，也不发信号。目标顺序固定为商品供应堆优先，其余玩家按 player_id 排序。
static func get_pending_exchange_availability() -> Dictionary:
	if not has_pending_decision():
		return {
			"available": false,
			"reason_code": "NO_PENDING",
			"message": "没有待处理的交换事件。",
			"give_goods": [],
			"targets": [],
			"legal_receive_goods_by_target": {},
		}
	var pending := GameState.pending_event_decision
	if String(pending.get("operation", "")) != "EXCHANGE_ONE_GOOD":
		return {
			"available": false,
			"reason_code": "WRONG_OPERATION",
			"message": "当前待处理事件不是货物交换。",
			"give_goods": [],
			"targets": [],
			"legal_receive_goods_by_target": {},
		}
	var acting_id := String(pending.get("acting_player_id", ""))
	var player := _player_by_id(acting_id)
	if player == null:
		return {
			"available": false,
			"reason_code": "MISSING_PLAYER",
			"message": "事件行动玩家不存在。",
			"give_goods": [],
			"targets": [],
			"legal_receive_goods_by_target": {},
		}
	var give_goods := _held_good_ids(player)
	var by_target := _build_receive_goods_by_target(player, give_goods, String(pending.get("target_scope", "ANY")))
	var target_ids: Array[String] = []
	for target_id in by_target.keys():
		target_ids.append(String(target_id))
	target_ids.sort()
	if "SUPPLY" in target_ids:
		target_ids.erase("SUPPLY")
		target_ids.push_front("SUPPLY")
	var combinations := 0
	for target_id in target_ids:
		var receive_goods: Array = by_target.get(target_id, [])
		for give_good in give_goods:
			for receive_good in receive_goods:
				if String(give_good) != String(receive_good):
					combinations += 1
	return {
		"available": combinations > 0,
		"reason_code": "" if combinations > 0 else "NO_LEGAL_COMBINATION",
		"message": "请选择交出与获得的货物。" if combinations > 0 else "没有可完成的交换。",
		"acting_player_id": acting_id,
		"give_goods": give_goods,
		"targets": target_ids,
		"legal_receive_goods_by_target": by_target.duplicate(true),
		"combination_count": combinations,
	}


## 提交 pending 事件选择。失败时状态完全不变；成功发一次 state_changed。
static func resolve_pending_decision(choice: Dictionary) -> Dictionary:
	if not has_pending_decision():
		return {"success": false, "message": "没有待处理的事件选择。"}
	var pending: Dictionary = GameState.pending_event_decision
	var op := String(pending.get("operation", ""))
	var acting_id := String(pending.get("acting_player_id", ""))
	var player := _player_by_id(acting_id)
	if player == null:
		return {"success": false, "message": "事件行动玩家不存在。"}
	# 扩展包的待决（付银或丢货、听声猜物、丢货过滤版）另外回报谁的白银 / 货变了；原版待决的返回值不变
	var is_expansion := op in FunEventOps.PENDING_OPS or pending.has("good_filter")
	var before: Dictionary = FunEventOps.snapshot_players() if is_expansion else {}
	var result: Dictionary
	match op:
		"LOSE_GOOD":
			result = _resolve_lose_half_goods(player, pending, choice)
		"LOSE_HALF_GOODS_MAX_2":
			result = _resolve_lose_half_goods(player, pending, choice)
		"EXCHANGE_ONE_GOOD":
			result = _resolve_exchange_one_good(player, pending, choice)
		_:
			if op not in FunEventOps.PENDING_OPS:
				return {"success": false, "message": "未知的待决策操作。"}
			result = FunEventOps.resolve(player, pending, choice)
	if not bool(result.get("success", false)):
		return result
	if is_expansion:
		result["event_id"] = String(pending.get("event_id", ""))
		result["operation"] = op
		result["affected"] = FunEventOps.affected_since(before)
	GameState.pending_event_decision = {}
	GameState.state_changed.emit()
	return result


## 测试/解释器入口：直接应用一条效果（不抽牌）。
static func apply_effect(player: PlayerState, effect: Dictionary, event_id: String = "") -> Dictionary:
	return _apply_effect(player, effect, event_id)


## 仅当 ruleset 显式声明 RESHUFFLE_DISCARD 时洗弃牌堆。
static func _try_reshuffle_event_deck(deck_state: Dictionary) -> bool:
	var policy := String(GameState.content.get("ruleset", {}).get("event_deck_exhaust_policy", "RULE_BLOCKED"))
	if policy != "RESHUFFLE_DISCARD":
		return false
	if deck_state["discard"].is_empty():
		return false
	var pile: Array = deck_state["discard"]
	GameState.rng_shuffle(pile)
	deck_state["draw"] = pile
	deck_state["discard"] = []
	return not deck_state["draw"].is_empty()


static func _apply_effect(player: PlayerState, effect: Dictionary, event_id: String) -> Dictionary:
	match String(effect.get("op", "")):
		"MOVE_BY_RANGE":
			var min_steps := int(effect.get("min_steps", 0))
			var max_steps := int(effect.get("max_steps", 0))
			player.movement_budget = max_steps
			player.pending_event_needs_move = true
			return {"needs_move": true, "message": "可移动 %d–%d 步。" % [min_steps, max_steps]}
		"LOSE_GOOD":
			return _apply_lose_good(player, effect, event_id)
		"GAIN_STARTING_RESOURCE":
			return _apply_gain_starting(player, effect)
		"LOSE_HALF_GOODS_MAX_2":
			return _apply_lose_half_goods(player, event_id)
		"LOSE_HALF_SILVER_MAX_5":
			return _apply_lose_half_silver(player, event_id)
		"EXCHANGE_ONE_GOOD":
			return _apply_exchange_one_good(player, event_id, effect)
		_:
			# 扩展包「L叔的趣味事件」的 op（只在合并了扩展包的对局里出现，见 scripts/expansions/）
			if FunEventOps.is_supported(String(effect.get("op", ""))):
				return FunEventOps.apply(player, effect, event_id)
			push_error("EventSystem: unknown effect op '%s'" % effect.get("op", ""))
			return {"message": "未知事件效果，未执行。"}


static func _apply_lose_good(player: PlayerState, effect: Dictionary, event_id: String) -> Dictionary:
	# 扩展参数 good_filter / fallback_max_steps（碎碎平安、呦呦鹿鸣）：基础包门禁不放行，原版 4 张丢货卡不带
	if effect.has("good_filter"):
		return FunEventOps.apply_filtered_lose_good(player, effect, event_id)
	var quantity := int(effect.get("quantity", 1))
	if player.cargo_count() == 0:
		return {"message": "没有货物，无损失。"}
	# 扩展包第二批「有备无患」的油布：真的会丢东西时挡掉整张（原版对局没有油布，不进这个分支）
	if not player.event_tokens.is_empty():
		var tarp := FunEventOps.try_block_loss(player, "LOSE_GOOD")
		if not tarp.is_empty():
			return {"message": String(tarp["message"]), "pending": false}
	var policy := String(effect.get("selection_policy", "RULE_BLOCKED"))
	if policy == "RULE_BLOCKED":
		push_error("EventSystem: LOSE_GOOD selection policy is RULE_BLOCKED")
		return {"message": "失去货物的选择方式待核对，未执行。"}
	var lose_count := mini(quantity, player.cargo_count())
	if policy == "PLAYER_CHOICE":
		var held_kinds := _held_good_ids(player)
		if held_kinds.size() == 1 and player.held_count(held_kinds[0]) >= lose_count:
			_remove_goods_to_supply(player, {held_kinds[0]: lose_count})
			return {
				"message": "失去 %s ×%d。" % [GameData.get_good_name(GameState.content, held_kinds[0]), lose_count],
				"pending": false,
			}
		if player.is_ai():
			var ai_choice := _ai_choose_lose_goods(player, lose_count)
			_remove_goods_to_supply(player, ai_choice)
			return {"message": "失去货物 ×%d。" % lose_count, "pending": false}
		GameState.pending_event_decision = {
			"event_id": event_id,
			"operation": "LOSE_GOOD",
			"legal_targets": [],
			"legal_give_goods": held_kinds,
			"legal_receive_goods": [],
			"acting_player_id": player.player_id,
			"required_give_count": lose_count,
		}
		return {"message": "请选择失去的 %d 件货物。" % lose_count, "pending": true}
	var lost: Array[String] = []
	for _i in lose_count:
		var good_id: Variant = null
		if policy == "RANDOM":
			good_id = GameState.rng_pick(player.warehouse_slots)
		else:
			push_error("EventSystem: unsupported selection policy '%s'" % policy)
			break
		if good_id == null:
			break
		player.remove_good(String(good_id), 1)
		GameState.return_good_to_supply(String(good_id), 1)
		lost.append(String(good_id))
	if lost.is_empty():
		return {"message": "没有货物，无损失。"}
	var names: Array[String] = []
	for good_id in lost:
		names.append(GameData.get_good_name(GameState.content, good_id))
	return {"message": "失去 %s。" % "、".join(names)}


static func _apply_gain_starting(player: PlayerState, effect: Dictionary) -> Dictionary:
	var granted := grant_starting_to(player, int(effect.get("quantity", 1)), 0)
	granted.erase("result")
	return granted


## 给 player 发 bundle_count 份自己城市卡上的起始物资（原版 GAIN_STARTING_RESOURCE 与扩展包共用）。
## fallback_silver = 0：原版「失而复得」等卡的行为和文字一字不变（K19：拿不下就整份作废）。
## fallback_silver > 0：扩展卡投桃报李 / 千里鹅毛 / 同舟共济的兜底——货仓满或供应缺货时改从银库领这么多白银。
## 返回 {message, result: GOOD | SILVER | FALLBACK_SILVER | NONE | INVALID, blocked?, reason_code?}
static func grant_starting_to(player: PlayerState, bundle_count: int, fallback_silver: int = 0) -> Dictionary:
	var snapshot: Dictionary = player.starting_resource_snapshot
	var unit_quantity := int(snapshot.get("quantity", 0))
	var quantity := unit_quantity * bundle_count
	if bundle_count <= 0 or quantity <= 0:
		return {"message": "起始物资记录无效，未获得资源。", "result": "INVALID"}
	match String(snapshot.get("resource_kind", "")):
		"GOOD":
			var good_id := String(snapshot.get("resource_id", ""))
			var no_room := player.warehouse_remaining() < quantity
			var no_stock := int(GameState.goods_supply.get(good_id, 0)) < quantity
			if (no_room or no_stock) and fallback_silver > 0:
				var fallback_paid := GameState.payout_silver(fallback_silver)
				player.silver += fallback_paid
				var why := "货仓满了" if no_room else "%s发完了" % GameData.get_good_name(GameState.content, good_id)
				return {"message": "%s，改得%d块白银。" % [why, fallback_paid], "result": "FALLBACK_SILVER"}
			if no_room:
				return {"message": "货仓空间不足，无法获得起始物资。", "result": "NONE"}
			if no_stock:
				return {"message": "公共商品供应不足，无法获得起始物资。", "result": "NONE"}
			GameState.take_good_from_supply(good_id, quantity)
			player.add_good(good_id, quantity)
			return {
				"message": "获得 %s ×%d。" % [GameData.get_good_name(GameState.content, good_id), quantity],
				"result": "GOOD",
			}
		"SILVER":
			var paid := GameState.payout_silver(quantity)
			player.silver += paid
			return {"message": "获得白银 ×%d。" % paid, "result": "SILVER"}
		_:
			push_error("EventSystem: GAIN_STARTING_RESOURCE has unsupported resource kind")
			return {
				"message": "起始物资类型无效，未执行。",
				"blocked": true,
				"reason_code": "INVALID_CONTENT",
				"result": "INVALID",
			}


## 丢失一半货物，上限 2。无货→0；需选择具体货物时进 pending（AI 确定性自动结算）。
static func _apply_lose_half_goods(player: PlayerState, event_id: String) -> Dictionary:
	var lose_count := _half_goods_lose_count(player.cargo_count())
	if lose_count == 0:
		return {"message": "货物不足 2 件，无损失。", "pending": false}
	if not player.event_tokens.is_empty():
		var tarp := FunEventOps.try_block_loss(player, "LOSE_HALF_GOODS_MAX_2")
		if not tarp.is_empty():
			return {"message": String(tarp["message"]), "pending": false}
	var held_kinds := _held_good_ids(player)
	if held_kinds.size() == 1 and player.held_count(held_kinds[0]) >= lose_count:
		_remove_goods_to_supply(player, {held_kinds[0]: lose_count})
		return {
			"message": "失去 %s ×%d。" % [GameData.get_good_name(GameState.content, held_kinds[0]), lose_count],
			"pending": false,
		}
	if player.is_ai():
		var choice := _ai_choose_lose_goods(player, lose_count)
		_remove_goods_to_supply(player, choice)
		return {"message": "失去货物 ×%d。" % lose_count, "pending": false}
	GameState.pending_event_decision = {
		"event_id": event_id,
		"operation": "LOSE_HALF_GOODS_MAX_2",
		"legal_targets": [],
		"legal_give_goods": held_kinds,
		"legal_receive_goods": [],
		"acting_player_id": player.player_id,
		"required_give_count": lose_count,
	}
	return {"message": "请选择失去的 %d 件货物。" % lose_count, "pending": true}


## 实体卡明确：失去一半商品，且商品 >3 时丢失 2 件。
## 产品裁决只有 1 件时无损失，因此 0→0、1→0、2→1、3→1、4→2。
static func _half_goods_lose_count(cargo: int) -> int:
	if cargo <= 1:
		return 0
	return mini(2, cargo / 2)


static func _apply_lose_half_silver(player: PlayerState, event_id: String) -> Dictionary:
	var rounding := String(GameState.content.get("ruleset", {}).get("half_silver_rounding", ""))
	if rounding.is_empty():
		push_error("EventSystem: LOSE_HALF_SILVER_MAX_5 requires ruleset.half_silver_rounding")
		return {
			"message": "丢失一半白银的舍入规则未声明（RULE_BLOCKED）。",
			"pending": false,
			"blocked": true,
			"reason_code": "RULE_BLOCKED",
			"event_id": event_id,
		}
	var half := _apply_half_rounding(player.silver, rounding)
	if half < 0:
		return {
			"message": "无效的 half_silver_rounding：%s。" % rounding,
			"blocked": true,
			"reason_code": "RULE_BLOCKED",
		}
	var lose := mini(5, half)
	if lose <= 0:
		return {"message": "没有白银，无损失。"}
	if not player.event_tokens.is_empty():
		var tarp := FunEventOps.try_block_loss(player, "LOSE_HALF_SILVER_MAX_5")
		if not tarp.is_empty():
			return {"message": String(tarp["message"])}
	player.silver -= lose
	GameState.return_silver(lose)
	return {"message": "失去白银 ×%d。" % lose}


static func _apply_half_rounding(amount: int, rounding: String) -> int:
	match rounding:
		"FLOOR":
			return amount / 2
		"CEIL":
			return int(ceili(float(amount) / 2.0))
		_:
			return -1


## effect.target_scope（扩展包第二批「晨钟暮鼓」）："SUPPLY_ONLY" 只和公共商品堆换；缺省 "ANY" 就是原版四张交换卡。
static func _apply_exchange_one_good(player: PlayerState, event_id: String, effect: Dictionary = {}) -> Dictionary:
	var scope := String(effect.get("target_scope", "ANY"))
	var legal_give := _held_good_ids(player)
	if legal_give.is_empty():
		if scope == "SUPPLY_ONLY":
			return {"message": "挎包是空的，庙会逛了一圈，没换到合适的。", "pending": false}
		return {"message": "没有货物可交换。", "pending": false}
	var by_target := _build_receive_goods_by_target(player, legal_give, scope)
	if by_target.is_empty():
		if scope == "SUPPLY_ONLY":
			return {"message": "庙会逛了一圈，没换到合适的。", "pending": false}
		return {"message": "没有可完成的交换。", "pending": false}
	var legal_targets: Array[String] = []
	for target_id in by_target.keys():
		legal_targets.append(String(target_id))
	legal_targets.sort()
	# 兼容字段：仅反映公共供应选项，不得当作所有目标的统一列表。
	var supply_goods: Array = by_target.get("SUPPLY", [])
	if player.is_ai():
		var ai_choice := _ai_choose_exchange(player, by_target, legal_give)
		if ai_choice.is_empty():
			return {"message": "没有可完成的交换。", "pending": false}
		var applied := _execute_exchange(player, ai_choice)
		if not bool(applied.get("success", false)):
			return {"message": String(applied.get("message", "交换失败。")), "pending": false}
		return {"message": String(applied.get("message", "交换完成。")), "pending": false}
	GameState.pending_event_decision = {
		"event_id": event_id,
		"operation": "EXCHANGE_ONE_GOOD",
		"legal_targets": legal_targets,
		"legal_give_goods": legal_give,
		"legal_receive_goods": supply_goods,
		"legal_receive_goods_by_target": by_target,
		"acting_player_id": player.player_id,
	}
	if scope != "ANY":
		GameState.pending_event_decision["target_scope"] = scope
	return {"message": "请选择交换的货物与目标。", "pending": true}


## 按目标构建可获得货物；排除无法形成异种交换的目标。同种换同种不列入有效组合。
## scope = "SUPPLY_ONLY" 时只列公共商品堆（扩展包第二批「晨钟暮鼓」）；缺省 "ANY" 与原版一致。
static func _build_receive_goods_by_target(player: PlayerState, legal_give: Array, scope: String = "ANY") -> Dictionary:
	var raw: Dictionary = {}
	var supply := _supply_good_ids_with_stock()
	if not supply.is_empty():
		raw["SUPPLY"] = supply
	for other in GameState.players:
		if other.player_id == player.player_id or scope == "SUPPLY_ONLY":
			continue
		var their := _held_good_ids(other)
		if not their.is_empty():
			raw[other.player_id] = their
	var filtered: Dictionary = {}
	for target_id in raw.keys():
		var useful: Array[String] = []
		for rid in raw[target_id]:
			var receive_id := String(rid)
			for give_id in legal_give:
				if String(give_id) != receive_id:
					useful.append(receive_id)
					break
		if not useful.is_empty():
			useful.sort()
			filtered[String(target_id)] = useful
	return filtered


static func _resolve_lose_half_goods(player: PlayerState, pending: Dictionary, choice: Dictionary) -> Dictionary:
	var required := int(pending.get("required_give_count", 0))
	var selection: Dictionary = choice.get("give_goods", {})
	if selection.is_empty() and choice.has("good_id"):
		selection = {String(choice["good_id"]): required}
	var total := 0
	for good_id in selection:
		var count := int(selection[good_id])
		if count <= 0:
			return {"success": false, "message": "丢弃数量必须为正整数。"}
		if String(good_id) not in pending.get("legal_give_goods", []):
			return {"success": false, "message": "非法货物选择。"}
		if player.held_count(String(good_id)) < count:
			return {"success": false, "message": "持有货物不足。"}
		total += count
	if total != required:
		return {"success": false, "message": "必须正好失去 %d 件货物。" % required}
	_remove_goods_to_supply(player, selection)
	return {"success": true, "message": "失去货物 ×%d。" % required}


static func _resolve_exchange_one_good(player: PlayerState, pending: Dictionary, choice: Dictionary) -> Dictionary:
	# 按实时状态重建合法表并校验；失败保持 pending 与库存不变。
	var refreshed_give := _held_good_ids(player)
	var by_target := _build_receive_goods_by_target(player, refreshed_give, String(pending.get("target_scope", "ANY")))
	var target := String(choice.get("target", ""))
	var give_good := String(choice.get("give_good", ""))
	var receive_good := String(choice.get("receive_good", ""))
	if target.is_empty() or give_good.is_empty() or receive_good.is_empty():
		return {"success": false, "message": "交换选择不完整。"}
	if give_good not in refreshed_give:
		return {"success": false, "message": "交出货物已失效。"}
	if give_good == receive_good:
		return {"success": false, "message": "不能用同种货物交换同种货物。"}
	if not by_target.has(target):
		return {"success": false, "message": "交换目标已失效。"}
	var legal_recv: Array = by_target[target]
	if receive_good not in legal_recv:
		return {"success": false, "message": "目标货物已失效。"}
	return _execute_exchange(
		player, {"target": target, "give_good": give_good, "receive_good": receive_good}
	)


static func _execute_exchange(player: PlayerState, choice: Dictionary) -> Dictionary:
	var target := String(choice.get("target", ""))
	var give_good := String(choice.get("give_good", ""))
	var receive_good := String(choice.get("receive_good", ""))
	if give_good == receive_good:
		return {"success": false, "message": "不能用同种货物交换同种货物。"}
	if player.held_count(give_good) < 1:
		return {"success": false, "message": "交出货物不足。"}
	var cargo_before := player.cargo_count()
	if target == "SUPPLY":
		if int(GameState.goods_supply.get(receive_good, 0)) < 1:
			return {"success": false, "message": "公共供应不足。"}
		player.remove_good(give_good, 1)
		GameState.return_good_to_supply(give_good, 1)
		GameState.take_good_from_supply(receive_good, 1)
		player.add_good(receive_good, 1)
	else:
		var other := _player_by_id(target)
		if other == null or other.held_count(receive_good) < 1:
			return {"success": false, "message": "目标玩家货物不足。"}
		player.remove_good(give_good, 1)
		other.remove_good(receive_good, 1)
		player.add_good(receive_good, 1)
		other.add_good(give_good, 1)
	if player.cargo_count() != cargo_before:
		push_error("EventSystem: EXCHANGE_ONE_GOOD changed cargo count")
	var give_name := GameData.get_good_name(GameState.content, give_good)
	var receive_name := GameData.get_good_name(GameState.content, receive_good)
	return {
		"success": true,
		"message": "用 %s 交换 %s。" % [give_name, receive_name],
	}


static func _ai_choose_lose_goods(player: PlayerState, lose_count: int) -> Dictionary:
	# 稳定策略：按 good_id 字典序，从仓位顺序取件。
	var ids := _held_good_ids(player)
	ids.sort()
	var selection: Dictionary = {}
	var remaining := lose_count
	for good_id in ids:
		if remaining <= 0:
			break
		var take := mini(remaining, player.held_count(good_id))
		if take > 0:
			selection[good_id] = take
			remaining -= take
	return selection


static func _ai_choose_exchange(_player: PlayerState, by_target: Dictionary, give_goods: Array) -> Dictionary:
	if give_goods.is_empty() or by_target.is_empty():
		return {}
	var give_sorted: Array = give_goods.duplicate()
	give_sorted.sort()
	var target_ids: Array = by_target.keys()
	target_ids.sort()
	if "SUPPLY" in target_ids:
		target_ids.erase("SUPPLY")
		target_ids.push_front("SUPPLY")
	for give_good_v in give_sorted:
		var give_good := String(give_good_v)
		for tid in target_ids:
			var recv_list: Array = by_target[tid]
			var recv_sorted: Array = recv_list.duplicate()
			recv_sorted.sort()
			for rid in recv_sorted:
				if String(rid) != give_good:
					return {
						"target": String(tid),
						"give_good": give_good,
						"receive_good": String(rid),
					}
	return {}


static func _remove_goods_to_supply(player: PlayerState, selection: Dictionary) -> void:
	for good_id in selection:
		var count := int(selection[good_id])
		player.remove_good(String(good_id), count)
		GameState.return_good_to_supply(String(good_id), count)


static func _held_good_ids(player: PlayerState) -> Array[String]:
	var ids: Array[String] = []
	for good_id in player.inventory.keys():
		if player.held_count(String(good_id)) > 0:
			ids.append(String(good_id))
	ids.sort()
	return ids


static func _supply_good_ids_with_stock() -> Array[String]:
	var ids: Array[String] = []
	for good_id in GameState.goods_supply.keys():
		if int(GameState.goods_supply[good_id]) > 0:
			ids.append(String(good_id))
	ids.sort()
	return ids


static func _player_by_id(player_id: String) -> PlayerState:
	for p in GameState.players:
		if p.player_id == player_id:
			return p
	return null
