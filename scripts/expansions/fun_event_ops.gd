class_name FunEventOps

## 「L叔的趣味事件」扩展包的事件 op（设计 docs/design/shanhe-luren/fun-events-20260926/README.md §5；
## 扩展包说明和待决字段见 data/expansions/lshu_fun_events/README.md）。
## EventSystem._apply_effect / resolve_pending_decision 把扩展 op 分派到这里。这些 op 只会出现在合并了扩展包的对局里：
## 基础包门禁（GameData.KNOWN_EVENT_OPS）不认它们，扩展包门禁（ExpansionLoader）按包里的 allowed_ops 放行。
##
## 规则：
##   - 规则随机一律走 GameState.rng_* / DiceSystem.roll()（赛骰、揭晓、抽篝火问题、出听声题）；
##   - 电脑的决策按确定的规则或对局状态的哈希（AIPolicy._whim），不消耗规则随机数；
##   - 真人要选的（付银或丢货、听声猜物；第二批的二选一、看牌）一律进 GameState.pending_event_decision，由界面先点、再按确认后
##     调 EventSystem.resolve_pending_decision；电脑当场结算；
##   - 只有真的没得选才自动结算，而且结果文字写明原因；
##   - 不发 GameState.state_changed（和 EventSystem 一样由所属命令统一发）。
## 每个 apply_* 返回和 EventSystem 相同形状的字典：{message, needs_move?, pending?, fx?}；fx 是给界面演出用的只读数据，
## EventSystem.draw_and_resolve 把它们并进抽牌结果的 "fx"。

const SUPPORTED_OPS: Array[String] = [
	"GAIN_SILVER",
	"PAY_SILVER",
	"GIFT_STARTING_RESOURCE",
	"DICE_RACE",
	"RANDOM_PRIZE",
	"FLAVOR_PROMPT",
	"GAIN_LOCAL_SPECIALTY",
	"PAY_OR_DROP",
	"SOUND_QUIZ",
	# 第二批（备选池，数据在 backlog/，不进牌堆）
	"CHOOSE_ONE",
	"DICE_CHANCE",
	"HELP_LEAST",
	"SWAP_RANDOM_GOOD",
	"PEEK_EVENT_DECK",
	"GIFT_GOOD_TO_NEAREST",
	"MEET_BONUS",
	"GRANT_TOKEN",
]
## 需要真人选择、会进待决的扩展 op（丢货的过滤版沿用原版 LOSE_GOOD 待决，晨钟暮鼓沿用原版交换待决）
const PENDING_OPS: Array[String] = ["PAY_OR_DROP", "SOUND_QUIZ", "CHOOSE_ONE", "PEEK_EVENT_DECK"]
## 二选一的电脑规则（设计 §4.1 陆6、§4.2 海5）
const CHOOSE_ONE_AI_RULES: Array[String] = ["STARTING_IF_SILVER_OR_TWO_FREE", "FISH", "FIRST_AVAILABLE"]
## 先睹为快：电脑按被看那张卡的 op 判断好坏（会丢东西的是坏卡），不看 sentiment
const BAD_CARD_OPS: Array[String] = ["LOSE_GOOD", "LOSE_HALF_GOODS_MAX_2", "LOSE_HALF_SILVER_MAX_5", "PAY_OR_DROP"]
## 电脑「翻中间那张 / 点左手」：揭晓仪式里电脑点的位置（只是演出，结果抽牌时已定）
const AI_CEREMONY_SLOT := {"two_fists": 0, "three_postcards": 1}
## 7 岁档电脑听声猜对的比例（按对局状态哈希，不消耗规则随机数）
const EASY_SOUND_QUIZ_HIT := 2.0 / 3.0


static func is_supported(op: String) -> bool:
	return op in SUPPORTED_OPS


## EventSystem._apply_effect 的分派入口
static func apply(player: PlayerState, effect: Dictionary, event_id: String) -> Dictionary:
	if not ExpansionLoader.is_fun_events_active(GameState.content):
		push_error("FunEventOps: op %s used without the lshu_fun_events expansion" % String(effect.get("op", "")))
		return {"message": "扩展事件没有启用，未执行。", "blocked": true, "reason_code": "EXPANSION_INACTIVE"}
	match String(effect.get("op", "")):
		"GAIN_SILVER":
			return apply_gain_silver(player, effect)
		"PAY_SILVER":
			return apply_pay_silver(player, effect)
		"GIFT_STARTING_RESOURCE":
			return apply_gift_starting_resource(player, effect)
		"DICE_RACE":
			return apply_dice_race(player, effect)
		"RANDOM_PRIZE":
			return apply_random_prize(player, effect)
		"FLAVOR_PROMPT":
			return apply_flavor_prompt(player, effect)
		"GAIN_LOCAL_SPECIALTY":
			return apply_gain_local_specialty(player, effect)
		"PAY_OR_DROP":
			return apply_pay_or_drop(player, effect, event_id)
		"SOUND_QUIZ":
			return apply_sound_quiz(player, effect, event_id)
		"CHOOSE_ONE":
			return apply_choose_one(player, effect, event_id)
		"DICE_CHANCE":
			return apply_dice_chance(player, effect)
		"HELP_LEAST":
			return apply_help_least(player, effect)
		"SWAP_RANDOM_GOOD":
			return apply_swap_random_good(player, effect)
		"PEEK_EVENT_DECK":
			return apply_peek_event_deck(player, event_id)
		"GIFT_GOOD_TO_NEAREST":
			return apply_gift_good_to_nearest(player, effect)
		"MEET_BONUS":
			return apply_meet_bonus(player, effect, event_id)
		"GRANT_TOKEN":
			return apply_grant_token(player, effect)
	push_error("FunEventOps: unsupported op '%s'" % String(effect.get("op", "")))
	return {"message": "未知事件效果，未执行。"}


# ================================================================ 得银 / 付银

## GAIN_SILVER {targets: "SELF" | "ALL_PLAYERS", amount}
## ALL_PLAYERS 从抽牌人开始按座位顺序逐人从银库领（银库不够时按 1.6：先拿空、当即触发终局，差额从盒中补）。
static func apply_gain_silver(player: PlayerState, effect: Dictionary) -> Dictionary:
	var amount := int(effect.get("amount", 0))
	var all := String(effect.get("targets", "SELF")) == "ALL_PLAYERS"
	var who: Array = seat_order_from(player) if all else [player]
	var gains: Array = []
	for p in who:
		var paid := GameState.payout_silver(amount)
		(p as PlayerState).silver += paid
		gains.append({"player_id": (p as PlayerState).player_id, "amount": paid})
	var message := ("每位玩家各得%d块白银。" % amount) if all else ("获得白银 ×%d。" % amount)
	return {"message": message, "fx": {"silver_gain": gains}}


## PAY_SILVER {amount, waived_text?}：付给银库；没有白银就免（结果文字写明，鸿雁传书写「你没有白银，邮费免了。」）。
## 付不起全额时一块也不收。
static func apply_pay_silver(player: PlayerState, effect: Dictionary) -> Dictionary:
	var amount := int(effect.get("amount", 0))
	if player.silver < amount:
		var fallback := ("你没有%d块白银，这次免了。" % amount) if player.silver > 0 else "你没有白银，这次免了。"
		return {"message": String(effect.get("waived_text", fallback))}
	player.silver -= amount
	GameState.return_silver(amount)
	return {"message": "付%d块白银。" % amount}


# ================================================================ 起始物资

## GIFT_STARTING_RESOURCE {targets: ["SELF", "NEXT_SEAT"], quantity, fallback_silver}
## 抽牌人先领，下一位（行动顺序；两人局就是对手）后领，各领 1 份自己城市卡上的起始物资；
## 货仓满或公共供应缺这种货的人改从银库领 fallback_silver 块白银。
static func apply_gift_starting_resource(player: PlayerState, effect: Dictionary) -> Dictionary:
	var quantity := int(effect.get("quantity", 1))
	var fallback := int(effect.get("fallback_silver", 0))
	var parts: Array[String] = []
	var done := {}
	var gifts: Array = []
	for target in effect.get("targets", []):
		var p: PlayerState = player if String(target) == "SELF" else next_seat(player)
		if p == null or done.has(p.player_id):
			continue
		done[p.player_id] = true
		var granted := EventSystem.grant_starting_to(p, quantity, fallback)
		parts.append("%s：%s" % [p.display_name, String(granted.get("message", ""))])
		gifts.append({"player_id": p.player_id, "result": String(granted.get("result", "")), "message": String(granted.get("message", ""))})
	return {"message": " ".join(parts), "fx": {"gifts": gifts}}


# ================================================================ 赛骰

## DICE_RACE {prize_effects: [{op: GAIN_SILVER, amount}], event_face_value}
## 从抽牌人开始按座位顺序每人掷一次骰（DiceSystem.roll()，事件面按 event_face_value 算，不重掷）；
## 点数最大的都得奖（并列都得）。不改任何人的 die_result 和步数预算。
static func apply_dice_race(player: PlayerState, effect: Dictionary) -> Dictionary:
	var event_value := int(effect.get("event_face_value", 0))
	var rolls: Array = []
	var best := -1
	for p in seat_order_from(player):
		var face: Variant = DiceSystem.roll()
		var value := event_value if DiceSystem.is_event_face(face) else int(face)
		rolls.append({
			"player_id": (p as PlayerState).player_id,
			"display_name": (p as PlayerState).display_name,
			"face": face,
			"value": value,
		})
		best = maxi(best, value)
	var winners: Array[String] = []
	var winner_names: Array[String] = []
	var roll_texts: Array[String] = []
	for r in rolls:
		var face_text := "事件面（算%d点）" % event_value if DiceSystem.is_event_face(r["face"]) else "%d点" % int(r["value"])
		roll_texts.append("%s %s" % [String(r["display_name"]), face_text])
		if int(r["value"]) == best:
			winners.append(String(r["player_id"]))
			winner_names.append(String(r["display_name"]))
	var prize_silver := 0
	for prize in effect.get("prize_effects", []):
		prize_silver += int(prize.get("amount", 0))
	for winner_id in winners:
		var w := EventSystem._player_by_id(winner_id)
		for prize in effect.get("prize_effects", []):
			apply_gain_silver(w, prize)
	var lead := "、".join(winner_names) + ("并列最大，" if winners.size() > 1 else "点数最大，")
	var prize_text := ("各得%d块白银。" if winners.size() > 1 else "得%d块白银。") % prize_silver
	return {
		"message": "赛骰：%s；%s%s" % ["，".join(roll_texts), lead, prize_text],
		"fx": {"dice_race": {"rolls": rolls, "winner_ids": winners, "prize_silver": prize_silver, "event_face_value": event_value}},
	}


# ================================================================ 揭晓仪式

## RANDOM_PRIZE {prizes: [[子效果…], …], prize_labels, ceremony: "two_fists" | "three_postcards"}
## 抽牌那一刻用规则随机数把奖品打乱，排在第一位的就是结果，当场结算（不进待决）。
## 界面上真人先点一个（只高亮），再按「打开」「翻开」才揭晓：点中的那个显示 reveal_order[0]，其余位置按
## reveal_order[1..] 依次翻开给大家看、不生效。电脑固定点 ai_pick_slot（左手 / 中间那张）。
static func apply_random_prize(player: PlayerState, effect: Dictionary) -> Dictionary:
	var prizes: Array = effect.get("prizes", [])
	var order: Array = []
	for i in prizes.size():
		order.append(i)
	GameState.rng_shuffle(order)
	var outcome := int(order[0]) if not order.is_empty() else -1
	var labels: Array = effect.get("prize_labels", [])
	var parts: Array[String] = []
	var needs_move := false
	if outcome >= 0:
		var labelled := outcome < labels.size() and not String(labels[outcome]).is_empty()
		if labelled:
			parts.append(String(labels[outcome]) + "。")
		for sub in prizes[outcome]:
			var applied := _apply_sub_effect(player, sub)
			var text := String(applied.get("message", ""))
			# 奖品文字已经说了得几块白银；付银（可能「没有白银，这次免了」）和走几步照样写出来
			if not text.is_empty() and not (labelled and String(sub.get("op", "")) == "GAIN_SILVER"):
				parts.append(text)
			needs_move = needs_move or bool(applied.get("needs_move", false))
	var ceremony := String(effect.get("ceremony", ""))
	var fx := {
		"ceremony": {
			"kind": ceremony,
			"outcome_index": outcome,
			"reveal_order": order,
			"labels": labels.duplicate(),
			"ai_pick_slot": int(AI_CEREMONY_SLOT.get(ceremony, 0)),
		},
	}
	var out := {"message": " ".join(parts), "fx": fx}
	if needs_move:
		out["needs_move"] = true
	return out


## 奖品 / 赛骰里的子效果：只允许不需要再选的 op（门禁已查）
static func _apply_sub_effect(player: PlayerState, sub: Dictionary) -> Dictionary:
	match String(sub.get("op", "")):
		"GAIN_SILVER":
			return apply_gain_silver(player, sub)
		"PAY_SILVER":
			return apply_pay_silver(player, sub)
		"MOVE_BY_RANGE":
			var hi := int(sub.get("max_steps", 0))
			player.movement_budget = hi
			player.pending_event_needs_move = true
			return {"needs_move": true, "message": "可移动 %d–%d 步。" % [int(sub.get("min_steps", 0)), hi]}
		"GAIN_STARTING_RESOURCE":
			var granted := EventSystem.grant_starting_to(player, int(sub.get("quantity", 1)), 0)
			return {"message": String(granted.get("message", ""))}
		"DICE_CHANCE":
			return apply_dice_chance(player, sub)
	push_error("FunEventOps: sub effect '%s' not allowed" % String(sub.get("op", "")))
	return {"message": ""}


# ================================================================ 篝火问题

## FLAVOR_PROMPT {prompt_pool_id, ambience, night_tint, dismiss}
## 用规则随机数从问题池抽 1 题；不动货物白银、不进待决。泡泡不设倒计时（dismiss 见 README）。
## 桌上每位电脑回一句「城名 + 一句风景」：城只取 city_lore_v1 里已核实的城，按对局状态哈希挑，不消耗规则随机数。
static func apply_flavor_prompt(player: PlayerState, effect: Dictionary) -> Dictionary:
	var pool_id := String(effect.get("prompt_pool_id", ""))
	var pool := ExpansionLoader.presentation(GameState.content, pool_id)
	var prompts: Array = pool.get("prompts", [])
	var prompt: Dictionary = {}
	if not prompts.is_empty():
		prompt = prompts[GameState.rng_int(prompts.size())]
	var replies: Array = []
	for p in seat_order_from(player):
		if (p as PlayerState).is_ai():
			replies.append({
				"player_id": (p as PlayerState).player_id,
				"display_name": (p as PlayerState).display_name,
				"text": ai_campfire_reply(p, pool),
			})
	var question := String(prompt.get("text", ""))
	return {
		"message": "篝火边聊一聊：%s（可以跳过）" % question if not question.is_empty() else "篝火边聊一聊。",
		"fx": {
			"flavor_prompt": {
				"pool_id": pool_id,
				"prompt_id": String(prompt.get("id", "")),
				"text": question,
				"ambience": String(effect.get("ambience", "")),
				"night_tint": bool(effect.get("night_tint", false)),
				"dismiss": String(effect.get("dismiss", "TAP_OR_NEXT_HUMAN_TURN_END")),
				"drawn_by_ai": player.is_ai(),
				"ai_replies": replies,
			},
		},
	}


## 电脑的篝火台词：优先说自己所在的城，其次老家，都不是已核实的城时按哈希挑一座已核实的城
static func ai_campfire_reply(ai_player: PlayerState, pool: Dictionary) -> String:
	var templates: Array = pool.get("ai_reply_templates", [])
	var content := GameState.content
	var verified: Array[String] = []
	for city_id in content.get("city_lore", {}).keys():
		if String(content["city_lore"][city_id].get("verification_status", "")).begins_with("SOURCE_VERIFIED"):
			verified.append(String(city_id))
	verified.sort()
	if templates.is_empty() or verified.is_empty():
		return ""
	var here := GameData.get_city_at_node(content, ai_player.current_node_id)
	var city_id := ""
	if here in verified:
		city_id = here
	elif ai_player.home_city_id in verified:
		city_id = ai_player.home_city_id
	else:
		city_id = verified[int(AIPolicy._whim(ai_player, "campfire_city") * verified.size()) % verified.size()]
	var scenery := String(content.get("card_text_cities", {}).get(city_id, {}).get("scenery", "")).split("；")[0].trim_suffix("。")
	var template := String(templates[int(AIPolicy._whim(ai_player, "campfire_line") * templates.size()) % templates.size()])
	return template.replace("{city}", GameData.get_city_name(content, city_id)).replace("{scenery}", scenery)


# ================================================================ 本城货物

## GAIN_LOCAL_SPECIALTY {quantity, fallback_max_steps}
## 站在城里、这座城的城市卡起始物资是货物、货仓有空位、公共供应还有：从供应拿 1 件，本回合不移动；
## 其余情况（不在城里、君士坦丁堡或吉达、货仓满、供应缺货）一律改走 0–N 步，结果文字写明原因。
static func apply_gain_local_specialty(player: PlayerState, effect: Dictionary) -> Dictionary:
	var quantity := int(effect.get("quantity", 1))
	var fallback := int(effect.get("fallback_max_steps", 3))
	var content := GameState.content
	var reason := ""
	var city_id := GameData.get_city_at_node(content, player.current_node_id)
	if city_id.is_empty() or not GameData.is_city_node(content, player.current_node_id):
		reason = "不在城里"
	else:
		var city_name := GameData.get_city_name(content, city_id)
		var card_id := String(GameData.get_city(content, city_id).get("city_card_id", ""))
		var entries := GameData.get_starting_grant(content, card_id)
		var entry: Dictionary = entries[0] if not entries.is_empty() else {}
		if String(entry.get("resource_kind", "")) != "GOOD":
			reason = "%s的城市卡给的是白银" % city_name
		else:
			var good_id := String(entry.get("resource_id", ""))
			if player.warehouse_remaining() < quantity:
				reason = "货仓满了"
			elif int(GameState.goods_supply.get(good_id, 0)) < quantity:
				reason = "%s发完了" % GameData.get_good_name(content, good_id)
			else:
				GameState.take_good_from_supply(good_id, quantity)
				player.add_good(good_id, quantity)
				return {
					"message": "获得 %s ×%d（%s的货）。" % [GameData.get_good_name(content, good_id), quantity, city_name],
					"fx": {"local_specialty": {"good_id": good_id, "city_id": city_id, "quantity": quantity}},
				}
	player.movement_budget = fallback
	player.pending_event_needs_move = true
	return {
		"needs_move": true,
		"message": "%s，这回合改走 0–%d 步。" % [reason, fallback],
		"fx": {"local_specialty": {"good_id": "", "city_id": city_id, "quantity": 0, "reason": reason}},
	}


# ================================================================ 付银或丢货（亡羊补牢 / 未雨绸缪）

## PAY_OR_DROP {pay_silver, drop_goods, pay_label}
## 真人：只要还有白银或货就进待决（做不到的那一项置灰并写原因）；两样都没有才直接结算（什么也不丢）。
## 电脑：货仓满就丢 1 件（按 good_id 字母序）；没满就付银；没有银才丢货。
static func apply_pay_or_drop(player: PlayerState, effect: Dictionary, event_id: String) -> Dictionary:
	var pay := int(effect.get("pay_silver", 1))
	var drop := int(effect.get("drop_goods", 1))
	var can_pay := player.silver >= pay
	var can_drop := player.cargo_count() >= drop
	if not can_pay and not can_drop:
		return {"message": "没有白银也没有货，这次什么也没丢。", "pending": false}
	# 有备无患的油布：整张免掉，不付银也不丢货（照常走后面的步数）
	var tarp := try_block_loss(player, "PAY_OR_DROP")
	if not tarp.is_empty():
		return {"message": String(tarp["message"]), "pending": false}
	if player.is_ai():
		var choice := ai_choose_pay_or_drop(player, {"can_pay": can_pay, "pay_silver": pay, "can_drop": can_drop, "required_give_count": drop})
		if choice.is_empty():
			return {"message": "没有白银也没有货，这次什么也没丢。", "pending": false}
		var done := _execute_pay_or_drop(player, choice, pay, drop)
		return {"message": String(done.get("message", "")), "pending": false}
	var held := EventSystem._held_good_ids(player)
	GameState.pending_event_decision = {
		"event_id": event_id,
		"operation": "PAY_OR_DROP",
		"acting_player_id": player.player_id,
		"legal_targets": [],
		"legal_receive_goods": [],
		"can_pay": can_pay,
		"pay_silver": pay,
		"pay_label": String(effect.get("pay_label", "付%d块白银" % pay)),
		"pay_blocked_reason": "" if can_pay else "没有白银",
		"can_drop": can_drop,
		"legal_give_goods": held if can_drop else [],
		"required_give_count": drop,
		"drop_blocked_reason": "" if can_drop else "挎包是空的",
	}
	return {"message": "付%d块白银，或点一件要丢的货。" % pay, "pending": true}


static func resolve_pay_or_drop(player: PlayerState, pending: Dictionary, choice: Dictionary) -> Dictionary:
	var pay := int(pending.get("pay_silver", 1))
	var drop := int(pending.get("required_give_count", 1))
	if bool(choice.get("pay_silver", false)):
		if player.silver < pay:
			return {"success": false, "message": "白银不够，付不了。"}
		return _execute_pay_or_drop(player, {"pay_silver": true}, pay, drop)
	var selection: Dictionary = choice.get("give_goods", {})
	if selection.is_empty() and choice.has("good_id"):
		selection = {String(choice["good_id"]): drop}
	if selection.is_empty():
		return {"success": false, "message": "请选付白银，或点一件要丢的货。"}
	var total := 0
	for good_id in selection:
		var count := int(selection[good_id])
		if count <= 0:
			return {"success": false, "message": "丢弃数量必须为正整数。"}
		if player.held_count(String(good_id)) < count:
			return {"success": false, "message": "持有货物不足。"}
		total += count
	if total != drop:
		return {"success": false, "message": "必须正好丢 %d 件货物。" % drop}
	return _execute_pay_or_drop(player, {"give_goods": selection}, pay, drop)


static func _execute_pay_or_drop(player: PlayerState, choice: Dictionary, pay: int, _drop: int) -> Dictionary:
	if bool(choice.get("pay_silver", false)):
		player.silver -= pay
		GameState.return_silver(pay)
		return {"success": true, "message": "付%d块白银。" % pay, "paid_silver": pay}
	var selection: Dictionary = choice.get("give_goods", {})
	var names: Array[String] = []
	for good_id in selection:
		names.append("%s ×%d" % [GameData.get_good_name(GameState.content, String(good_id)), int(selection[good_id])])
	EventSystem._remove_goods_to_supply(player, selection)
	return {"success": true, "message": "丢失 %s。" % "、".join(names), "dropped": selection.duplicate()}


static func ai_choose_pay_or_drop(player: PlayerState, pending: Dictionary) -> Dictionary:
	var can_pay := bool(pending.get("can_pay", player.silver >= int(pending.get("pay_silver", 1))))
	var drop := int(pending.get("required_give_count", 1))
	var full := player.cargo_count() >= player.warehouse_capacity
	if (full or not can_pay) and player.cargo_count() >= drop:
		return {"give_goods": EventSystem._ai_choose_lose_goods(player, drop)}
	if can_pay:
		return {"pay_silver": true}
	return {}


# ================================================================ 丢货的过滤版（碎碎平安 / 呦呦鹿鸣）

## LOSE_GOOD 加 good_filter / fallback_max_steps（只在扩展包门禁里放行）：
## 手里有过滤内的货就丢 1 件（只有一种时自动丢那种；两种以上真人用原版丢货待决挑、电脑按字母序），本回合不移动；
## 一件都没有就改走 0–N 步。filter_texts 给出各分支的结果文字（{good} / {goods} 是商品名）。
static func apply_filtered_lose_good(player: PlayerState, effect: Dictionary, event_id: String) -> Dictionary:
	var filter: Array = effect.get("good_filter", [])
	var texts: Dictionary = effect.get("filter_texts", {})
	var kinds: Array[String] = []
	var held_in_filter := 0
	for good_id in EventSystem._held_good_ids(player):
		if good_id in filter:
			kinds.append(good_id)
			held_in_filter += player.held_count(good_id)
	if kinds.is_empty():
		var steps := int(effect.get("fallback_max_steps", 0))
		player.movement_budget = steps
		player.pending_event_needs_move = true
		return {"needs_move": true, "message": String(texts.get("miss", "没有这几样货，改走 0–%d 步。" % steps))}
	var tarp := try_block_loss(player, "LOSE_GOOD")
	if not tarp.is_empty():
		return {"message": String(tarp["message"]), "pending": false}
	var lose_count := mini(int(effect.get("quantity", 1)), held_in_filter)
	var content := GameState.content
	if kinds.size() == 1:
		EventSystem._remove_goods_to_supply(player, {kinds[0]: lose_count})
		var name := GameData.get_good_name(content, kinds[0])
		# 「你的货里只有…」是说给抽到的真人听的；电脑抽到时台上的孩子会以为说的是自己，改用电脑那一句
		var key := "ai" if player.is_ai() and texts.has("ai") else "auto"
		return {"message": String(texts.get(key, "失去 {good} ×1。")).replace("{good}", name), "pending": false}
	if player.is_ai():
		var choice := ai_choose_filtered_loss(player, kinds, lose_count)
		EventSystem._remove_goods_to_supply(player, choice)
		var first := String(choice.keys()[0]) if not choice.is_empty() else ""
		return {"message": String(texts.get("ai", "失去 {good} ×1。")).replace("{good}", GameData.get_good_name(content, first)), "pending": false}
	var names: Array[String] = []
	for good_id in kinds:
		names.append(GameData.get_good_name(content, good_id))
	GameState.pending_event_decision = {
		"event_id": event_id,
		"operation": "LOSE_GOOD",
		"legal_targets": [],
		"legal_give_goods": kinds,
		"legal_receive_goods": [],
		"acting_player_id": player.player_id,
		"required_give_count": lose_count,
		"good_filter": filter.duplicate(),
		"filter_prompt": String(texts.get("pick", "从{goods}里选 1 件。")).replace("{goods}", "、".join(names)),
	}
	return {"message": String(GameState.pending_event_decision["filter_prompt"]), "pending": true}


## 电脑丢过滤内的货：按 good_id 字母序（碎碎平安 glass → perfume → porcelain；呦呦鹿鸣 dates → ginseng → tea）
static func ai_choose_filtered_loss(player: PlayerState, legal_kinds: Array, lose_count: int) -> Dictionary:
	var ids: Array = legal_kinds.duplicate()
	ids.sort()
	var selection := {}
	var remaining := lose_count
	for good_id in ids:
		if remaining <= 0:
			break
		var take := mini(remaining, player.held_count(String(good_id)))
		if take > 0:
			selection[String(good_id)] = take
			remaining -= take
	return selection


# ================================================================ 听声猜物（子开关「耳听八方」）

## SOUND_QUIZ {sound_pool_id, option_count, correct_max_steps, wrong_max_steps, muted_max_steps, exclusive_pairs}
## 抽牌那一刻用规则随机数出题：先抽正确答案，再从其余声音里抽干扰项（exclusive_pairs 里的两样不同题出现），
## 最后把选项顺序打乱。真人进待决：界面播声音、先点一张图、再按「就是它」；游戏静音时界面直接提交 {muted: true}
## （不出题，改走 0–muted_max_steps 步）。电脑当场作答：12 / 16 岁总是猜对，7 岁按对局哈希约 2/3 猜对。
static func apply_sound_quiz(player: PlayerState, effect: Dictionary, event_id: String) -> Dictionary:
	var pool := ExpansionLoader.presentation(GameState.content, String(effect.get("sound_pool_id", "")))
	var sounds: Array = pool.get("sounds", [])
	var labels := {}
	var ids: Array = []
	for snd in sounds:
		ids.append(String(snd.get("id", "")))
		labels[String(snd.get("id", ""))] = String(snd.get("label", ""))
	var count := int(effect.get("option_count", 3))
	var pairs: Array = effect.get("exclusive_pairs", [])
	var correct := String(ids[GameState.rng_int(ids.size())]) if not ids.is_empty() else ""
	var options: Array = [correct]
	var rest: Array = ids.duplicate()
	rest.erase(correct)
	rest.sort()
	GameState.rng_shuffle(rest)
	for candidate in rest:
		if options.size() >= count:
			break
		if not _conflicts(String(candidate), options, pairs):
			options.append(String(candidate))
	GameState.rng_shuffle(options)
	var quiz := {
		"sound_id": correct,
		"options": options,
		"option_labels": labels,
		"correct_max_steps": int(effect.get("correct_max_steps", 5)),
		"wrong_max_steps": int(effect.get("wrong_max_steps", 3)),
		"muted_max_steps": int(effect.get("muted_max_steps", 4)),
	}
	if player.is_ai():
		var guess := ai_sound_quiz_guess(player, correct, options)
		var hit := guess == correct
		var steps: int = quiz["correct_max_steps"] if hit else quiz["wrong_max_steps"]
		player.movement_budget = steps
		player.pending_event_needs_move = true
		var fx_quiz := quiz.duplicate()
		fx_quiz["ai_guess"] = guess
		fx_quiz["correct"] = hit
		var text := (
			"%s听出来了：是%s！可走 0–%d 步。" % [player.display_name, String(labels.get(correct, correct)), steps]
			if hit
			else "%s猜是%s，其实是%s。可走 0–%d 步。" % [player.display_name, String(labels.get(guess, guess)), String(labels.get(correct, correct)), steps]
		)
		return {"needs_move": true, "message": text, "fx": {"sound_quiz": fx_quiz}}
	var pending := quiz.duplicate()
	pending.merge({
		"event_id": event_id,
		"operation": "SOUND_QUIZ",
		"acting_player_id": player.player_id,
		"legal_targets": [],
		"legal_give_goods": [],
		"legal_receive_goods": [],
	})
	GameState.pending_event_decision = pending
	return {"message": "听一听，这是什么声音？点一张图，再按「就是它」。", "pending": true, "fx": {"sound_quiz": quiz}}


static func resolve_sound_quiz(player: PlayerState, pending: Dictionary, choice: Dictionary) -> Dictionary:
	var labels: Dictionary = pending.get("option_labels", {})
	var correct := String(pending.get("sound_id", ""))
	var steps := 0
	var message := ""
	var hit := false
	if bool(choice.get("muted", false)):
		steps = int(pending.get("muted_max_steps", 4))
		message = "声音关着，这次不猜，改走 0–%d 步。" % steps
	else:
		var pick := String(choice.get("option_id", ""))
		if pick.is_empty() or pick not in pending.get("options", []):
			return {"success": false, "message": "请先点一张图。"}
		hit = pick == correct
		steps = int(pending.get("correct_max_steps", 5)) if hit else int(pending.get("wrong_max_steps", 3))
		message = (
			"猜对了，是%s！可走 0–%d 步。" % [String(labels.get(correct, correct)), steps]
			if hit
			else "是%s哦，不是%s。可走 0–%d 步。" % [String(labels.get(correct, correct)), String(labels.get(pick, pick)), steps]
		)
	player.movement_budget = steps
	player.pending_event_needs_move = true
	return {"success": true, "message": message, "needs_move": true, "correct": hit}


## 电脑听声：12 / 16 岁总是猜对；7 岁按对局状态哈希约 2/3 猜对，猜错时选选项里第一个不对的。不消耗规则随机数。
static func ai_sound_quiz_guess(player: PlayerState, correct: String, options: Array) -> String:
	if AIDifficulty.of(player) != AIDifficulty.EASY or AIPolicy._whim(player, "sound_quiz") < EASY_SOUND_QUIZ_HIT:
		return correct
	for option in options:
		if String(option) != correct:
			return String(option)
	return correct


static func _conflicts(candidate: String, chosen: Array, pairs: Array) -> bool:
	for pair in pairs:
		if not (pair is Array) or (pair as Array).size() != 2:
			continue
		var a := String(pair[0])
		var b := String(pair[1])
		if (candidate == a and b in chosen) or (candidate == b and a in chosen):
			return true
	return false


# ################################################################ 第二批（备选池）
# 下面这些 op 的卡在 data/expansions/lshu_fun_events/backlog/，游戏里不能选、不进牌堆；规则已就绪，换入时只改数据。

# ================================================================ 二选一（左右逢源 / 放长线钓大鱼）

## CHOOSE_ONE {options: [{id, label, effects}], ai_rule}
## 真人进待决：先点一个选项（只高亮、预览），再按「就这样」才生效；做不到的选项（领物资时货仓满 / 缺货）置灰写原因。
## 选到走步时，resolve 里补设步数预算和 needs_move（抽牌时这张卡没返回 needs_move，roll_die 已把标志清掉）。
static func apply_choose_one(player: PlayerState, effect: Dictionary, event_id: String) -> Dictionary:
	var options := _choose_one_options(player, effect)
	var rule := String(effect.get("ai_rule", "FIRST_AVAILABLE"))
	if player.is_ai():
		var pick := ai_choose_one(player, rule, options)
		var done := _run_choose_one(player, options, pick)
		var label := ""
		for o in options:
			if String(o["id"]) == pick:
				label = String(o["label"])
		done["message"] = "%s选了「%s」。%s" % [player.display_name, label, String(done.get("message", ""))]
		done.erase("success")
		return done
	GameState.pending_event_decision = {
		"event_id": event_id,
		"operation": "CHOOSE_ONE",
		"acting_player_id": player.player_id,
		"options": options,
		"ai_rule": rule,
		"legal_targets": [],
		"legal_give_goods": [],
		"legal_receive_goods": [],
	}
	return {"message": "二选一：先点一个，再按「就这样」。", "pending": true}


static func resolve_choose_one(player: PlayerState, pending: Dictionary, choice: Dictionary) -> Dictionary:
	var pick := String(choice.get("option_id", ""))
	# 按实时状态重新判定能不能选（界面上的灰按钮只是预览）
	var live := _choose_one_options(player, {"options": _stored_option_effects(pending)})
	var found := false
	for o in live:
		if String(o["id"]) == pick:
			found = true
			if not bool(o["available"]):
				return {"success": false, "message": "这一项现在选不了：%s。" % String(o["blocked_reason"])}
	if not found:
		return {"success": false, "message": "请先点一个选项。"}
	return _run_choose_one(player, live, pick)


## 选项的展示信息（界面用）+ 效果本体（resolve 用）
static func _choose_one_options(player: PlayerState, effect: Dictionary) -> Array:
	var out: Array = []
	for o in effect.get("options", []):
		var blocked := ""
		var previews: Array[String] = []
		for sub in o.get("effects", []):
			match String(sub.get("op", "")):
				"MOVE_BY_RANGE":
					previews.append("这回合走 0–%d 步" % int(sub.get("max_steps", 0)))
				"GAIN_STARTING_RESOURCE":
					blocked = starting_grant_blocker(player)
					previews.append(_starting_preview(player) + "，这回合不走")
				"DICE_CHANCE":
					var faces: Array = sub.get("win_faces", [])
					previews.append("原地再掷一次骰：%d–%d 点%s，这回合不走" % [int(faces.min()), int(faces.max()), _gain_text(sub.get("win_effects", []))])
				"GAIN_SILVER":
					previews.append("得%d块白银" % int(sub.get("amount", 0)))
		out.append({
			"id": String(o.get("id", "")),
			"label": String(o.get("label", "")),
			"available": blocked.is_empty(),
			"blocked_reason": blocked,
			"preview": "；".join(previews),
			"effects": (o.get("effects", []) as Array).duplicate(true),
		})
	return out


static func _stored_option_effects(pending: Dictionary) -> Array:
	var out: Array = []
	for o in pending.get("options", []):
		out.append({"id": o.get("id", ""), "label": o.get("label", ""), "effects": o.get("effects", [])})
	return out


static func _run_choose_one(player: PlayerState, options: Array, pick: String) -> Dictionary:
	var parts: Array[String] = []
	var needs_move := false
	var fx := {}
	for o in options:
		if String(o["id"]) != pick:
			continue
		for sub in o.get("effects", []):
			var applied := _apply_sub_effect(player, sub)
			if not String(applied.get("message", "")).is_empty():
				parts.append(String(applied["message"]))
			needs_move = needs_move or bool(applied.get("needs_move", false))
			if applied.get("fx") is Dictionary:
				fx.merge(applied["fx"], true)
	fx["choose_one"] = {"option_id": pick}
	var out := {"success": true, "message": " ".join(parts), "fx": fx}
	if needs_move:
		out["needs_move"] = true
	return out


## 领 1 份起始物资会不会作废：""（能领）/「货仓满了」/「茶叶发完了」
static func starting_grant_blocker(player: PlayerState) -> String:
	var snap: Dictionary = player.starting_resource_snapshot
	if String(snap.get("resource_kind", "")) != "GOOD":
		return ""
	var good_id := String(snap.get("resource_id", ""))
	var qty := int(snap.get("quantity", 1))
	if player.warehouse_remaining() < qty:
		return "货仓满了"
	if int(GameState.goods_supply.get(good_id, 0)) < qty:
		return "%s发完了" % GameData.get_good_name(GameState.content, good_id)
	return ""


static func _starting_preview(player: PlayerState) -> String:
	var snap: Dictionary = player.starting_resource_snapshot
	if String(snap.get("resource_kind", "")) == "SILVER":
		return "得%d块白银" % int(snap.get("quantity", 0))
	return "得%d个%s" % [int(snap.get("quantity", 1)), GameData.get_good_name(GameState.content, String(snap.get("resource_id", "")))]


static func _gain_text(effects: Array) -> String:
	var total := 0
	for e in effects:
		total += int(e.get("amount", 0))
	return "得%d块白银" % total if total > 0 else ""


## 电脑二选一（不消耗规则随机数）：
##   STARTING_IF_SILVER_OR_TWO_FREE（左右逢源）：起始物资是白银，或货仓至少空 2 格，就领物资；否则走。三档一样。
##   FISH（放长线钓大鱼）：7 岁按对局状态哈希一半一半；12 / 16 岁人在已开通的城里（不走也能做那一次贸易）就放长线，否则收竿。
##   FIRST_AVAILABLE：第一个能选的。想选的那项做不到时也退到第一个能选的。
static func ai_choose_one(player: PlayerState, rule: String, options: Array) -> String:
	var available := {}
	var first := ""
	for o in options:
		if bool(o.get("available", false)):
			available[String(o["id"])] = true
			if first.is_empty():
				first = String(o["id"])
	var want := ""
	match rule:
		"STARTING_IF_SILVER_OR_TWO_FREE":
			var snap: Dictionary = player.starting_resource_snapshot
			want = "starting" if String(snap.get("resource_kind", "")) == "SILVER" or player.warehouse_remaining() >= 2 else "move"
		"FISH":
			if AIDifficulty.of(player) == AIDifficulty.EASY:
				want = "fish" if AIPolicy._whim(player, "fish") >= 0.5 else "move"
			else:
				var city_id := GameData.get_city_at_node(GameState.content, player.current_node_id)
				var open := not city_id.is_empty() and bool(GameState.city_market_states.get(city_id, {}).get("trade_route_open", false))
				want = "fish" if open else "move"
	return want if available.has(want) else first


## DICE_CHANCE {win_faces, win_effects, lose_effects, win_text?, lose_text?}：原地再掷一次骰（规则随机数），
## 掷中就结算 win_effects。不抽事件卡，不改 die_result 和步数。
static func apply_dice_chance(player: PlayerState, effect: Dictionary) -> Dictionary:
	var face: Variant = DiceSystem.roll()
	var faces: Array[int] = []
	for f in effect.get("win_faces", []):
		faces.append(int(f))   # JSON 里的数字读进来是浮点，统一成整数再比
	var win: bool = face is int and int(face) in faces
	var parts: Array[String] = ["再掷一次：%s。" % ("事件面" if DiceSystem.is_event_face(face) else "%d点" % int(face))]
	parts.append(String(effect.get("win_text" if win else "lose_text", "")))
	for sub in effect.get("win_effects" if win else "lose_effects", []):
		parts.append(String(apply_gain_silver(player, sub).get("message", "")))
	return {"message": "".join(parts), "fx": {"dice_chance": {"face": face, "won": win}}}


# ================================================================ 帮最需要的人（雪中送炭 / 同舟共济）

## HELP_LEAST {measure: SILVER | GOODS, gift: {kind: SILVER, amount} | {kind: STARTING_RESOURCE, fallback_silver}, tie}
## 比较所有玩家（包括抽牌人）此刻的白银 / 货物件数，最少的得帮助；并列时两人局都得，3–4 人局从抽牌人的下一位开始
## 按行动顺序数、最多 2 位。文字不写「最少」「最穷」。
static func apply_help_least(player: PlayerState, effect: Dictionary) -> Dictionary:
	var measure := String(effect.get("measure", "SILVER"))
	var gift: Dictionary = effect.get("gift", {})
	var values := {}
	var least := 1 << 30
	for p in GameState.players:
		var v: int = (p as PlayerState).silver if measure == "SILVER" else (p as PlayerState).cargo_count()
		values[(p as PlayerState).player_id] = v
		least = mini(least, v)
	var start: PlayerState = next_seat(player) if next_seat(player) != null else player
	var recipients: Array = []
	for p in seat_order_from(start):
		if int(values[(p as PlayerState).player_id]) == least:
			recipients.append(p)
	if GameState.players.size() > 2:
		recipients = recipients.slice(0, 2)
	var parts: Array[String] = []
	var ids: Array[String] = []
	for r in recipients:
		var rp := r as PlayerState
		ids.append(rp.player_id)
		if String(gift.get("kind", "")) == "SILVER":
			var paid := GameState.payout_silver(int(gift.get("amount", 0)))
			rp.silver += paid
			parts.append("%s得%d块白银" % [rp.display_name, paid])
		else:
			var granted := EventSystem.grant_starting_to(rp, 1, int(gift.get("fallback_silver", 0)))
			parts.append("%s：%s" % [rp.display_name, String(granted.get("message", "")).trim_suffix("。")])
	return {
		"message": "送去帮忙：%s。" % "，".join(parts),
		"fx": {"help": {"measure": measure, "values": values, "recipient_ids": ids}},
	}


# ================================================================ 随机互换（阴差阳错）

## SWAP_RANDOM_GOOD {partner: NEXT_SEAT, pick: RANDOM_SLOT, void_if_either_empty}
## 抽牌人和下一位各从自己的货仓里随机摸 1 件交给对方（先抽牌人、后对方，各调一次 GameState.rng_pick）；
## 件数不变，白银和公共供应都不动。任何一方没货就整张作废，绝不变成单方面拿走。抽牌人本回合不移动。
static func apply_swap_random_good(player: PlayerState, _effect: Dictionary) -> Dictionary:
	var other := next_seat(player)
	if other == null:
		return {"message": "没有别的玩家，这次没换成。", "fx": {"swap": {"void": true}}}
	var empty: PlayerState = null
	if player.cargo_count() == 0:
		empty = player
	elif other.cargo_count() == 0:
		empty = other
	if empty != null:
		return {
			"message": "%s挎包是空的，这次没换成。" % ("你的" if empty == player else empty.display_name),
			"fx": {"swap": {"void": true, "partner_id": other.player_id}},
		}
	var give := String(GameState.rng_pick(player.warehouse_slots))
	var take := String(GameState.rng_pick(other.warehouse_slots))
	player.remove_good(give, 1)
	other.remove_good(take, 1)
	player.add_good(take, 1)
	other.add_good(give, 1)
	var content := GameState.content
	var text := ""
	if give == take:
		text = "和%s的包袱拿错啦：换回来还是一样（%s）。" % [other.display_name, GameData.get_good_name(content, give)]
	else:
		text = "和%s的包袱拿错啦：%s换成了%s。" % [other.display_name, GameData.get_good_name(content, give), GameData.get_good_name(content, take)]
	return {"message": text, "fx": {"swap": {"partner_id": other.player_id, "give_good": give, "receive_good": take}}}


# ================================================================ 看牌（先睹为快）

## PEEK_EVENT_DECK {}：按抽牌人此刻的交通（和刚抽的是同一堆）翻开这堆抽牌堆最上面一张给全桌看（不结算），
## 抽牌人二选一：留在顶上 / 压到最底下。抽牌堆空了先按规则把弃牌洗回去（洗回后顶牌正好是本张也照常展示）。
## 真人进待决，先点、再按「确认」；提交时校验顶牌没变。电脑：被看那张卡会丢东西就压到底，其余留在顶上；电脑不记住看过的卡。
static func apply_peek_event_deck(player: PlayerState, event_id: String) -> Dictionary:
	var deck_type := GameData.deck_type_for_transport(player.active_transport)
	var st: Dictionary = GameState.event_decks_state[deck_type]
	if (st["draw"] as Array).is_empty():
		EventSystem._try_reshuffle_event_deck(st)
	if (st["draw"] as Array).is_empty():
		return {"message": "这堆事件卡没得看了。"}
	var info := _peek_info(deck_type, String(st["draw"][0]))
	if player.is_ai():
		var to_bottom := bool(info["is_bad"])
		if to_bottom:
			var top: Variant = (st["draw"] as Array).pop_front()
			(st["draw"] as Array).append(top)
		var shown := info.duplicate()
		shown["choice"] = "TO_BOTTOM" if to_bottom else "KEEP_TOP"
		return {
			"message": "%s先看了下一张事件卡「%s」，%s。" % [player.display_name, String(info["title"]), "把它压到了最底下" if to_bottom else "留在了顶上"],
			"fx": {"peek": shown},
		}
	var pending := info.duplicate()
	pending["peek_event_id"] = pending["event_id"]
	pending.merge({
		"event_id": event_id,
		"operation": "PEEK_EVENT_DECK",
		"acting_player_id": player.player_id,
		"options": ["KEEP_TOP", "TO_BOTTOM"],
		"legal_targets": [],
		"legal_give_goods": [],
		"legal_receive_goods": [],
	}, true)
	GameState.pending_event_decision = pending
	return {"message": "下一张事件卡是「%s」：留在顶上，还是压到最底下？" % String(info["title"]), "pending": true, "fx": {"peek": info}}


static func resolve_peek_event_deck(_player: PlayerState, pending: Dictionary, choice: Dictionary) -> Dictionary:
	var pick := String(choice.get("choice", ""))
	if pick not in ["KEEP_TOP", "TO_BOTTOM"]:
		return {"success": false, "message": "请先选留在顶上，还是压到最底下。"}
	var st: Dictionary = GameState.event_decks_state.get(int(pending.get("deck_type", -1)), {})
	var draw: Array = st.get("draw", [])
	if draw.is_empty() or String(draw[0]) != String(pending.get("instance_id", "")):
		return {"success": false, "message": "牌堆变了，这次看牌作废。"}
	var title := String(pending.get("title", ""))
	if pick == "TO_BOTTOM":
		draw.append(draw.pop_front())
		var extra := "坏天气被赶走啦！" if bool(pending.get("is_bad", false)) else ""
		return {"success": true, "message": "「%s」去最底下了。%s" % [title, extra]}
	return {"success": true, "message": "「%s」留在顶上，下一个抽这堆牌的人会抽到它。" % title}


static func _peek_info(deck_type: int, instance_id: String) -> Dictionary:
	var content := GameState.content
	var instance: Dictionary = content["event_card_instances"].get(instance_id, {})
	var definition: Dictionary = content["event_definitions"].get(String(instance.get("event_id", "")), {})
	var bad := false
	for e in definition.get("effects", []):
		bad = bad or String(e.get("op", "")) in BAD_CARD_OPS
	return {
		"deck_type": deck_type,
		"instance_id": instance_id,
		"event_id": String(definition.get("id", "")),
		"title": String(definition.get("title", "")),
		"is_bad": bad,
	}


# ================================================================ 离得近先得（近水楼台）

## GIFT_GOOD_TO_NEAREST {city_id, good_id, quantity, tie: ALL}
## 按全图（陆路海路都算，不看当前交通）数每位玩家到那座城最少几步，最近的都从公共供应领；货仓满的领不到，
## 供应不够时从抽牌人开始按行动顺序发。结果文字列出每人几步，领不到的写原因。
static func apply_gift_good_to_nearest(player: PlayerState, effect: Dictionary) -> Dictionary:
	var content := GameState.content
	var city_id := String(effect.get("city_id", ""))
	var good_id := String(effect.get("good_id", ""))
	var qty := int(effect.get("quantity", 1))
	var target := String(GameData.get_city(content, city_id).get("board_node_id", city_id))
	var dist := board_distances_from(target)
	var distances := {}
	var best := 1 << 30
	for p in GameState.players:
		var d := int(dist.get((p as PlayerState).current_node_id, 1 << 20))
		distances[(p as PlayerState).player_id] = d
		best = mini(best, d)
	var parts: Array[String] = []
	for p in GameState.players:
		parts.append("%s %d 步" % [(p as PlayerState).display_name, int(distances[(p as PlayerState).player_id])])
	var city_name := GameData.get_city_name(content, city_id)
	var good_name := GameData.get_good_name(content, good_id)
	var results: Array = []
	var result_texts: Array[String] = []
	for p in seat_order_from(player):
		var pp := p as PlayerState
		if int(distances[pp.player_id]) != best:
			continue
		var reason := ""
		if pp.warehouse_remaining() < qty:
			reason = "货仓满了"
		elif int(GameState.goods_supply.get(good_id, 0)) < qty:
			reason = "%s发完了" % good_name
		else:
			GameState.take_good_from_supply(good_id, qty)
			pp.add_good(good_id, qty)
		results.append({"player_id": pp.player_id, "got": reason.is_empty(), "reason": reason})
		if reason.is_empty():
			result_texts.append("%s得%d个%s" % [pp.display_name, qty, good_name])
		else:
			result_texts.append("%s没领到（%s）" % [pp.display_name, reason])
	return {
		"message": "离%s：%s。%s。" % [city_name, "、".join(parts), "，".join(result_texts)],
		"fx": {"nearest": {"city_id": city_id, "good_id": good_id, "distances": distances, "results": results}},
	}


## 全图最短步数（BFS，陆路海路都算）：{node_id: 步数}
static func board_distances_from(start: String) -> Dictionary:
	var dist := {start: 0}
	var frontier: Array = [start]
	var edges_from: Dictionary = GameState.content.get("edges_from", {})
	while not frontier.is_empty():
		var node := String(frontier.pop_front())
		var neighbours: Array = []
		for edge in edges_from.get(node, []):
			neighbours.append(GameData.edge_other_node(edge, node))
		neighbours.sort()
		for other in neighbours:
			if not dist.has(other):
				dist[other] = int(dist[node]) + 1
				frontier.append(other)
	return dist


# ================================================================ 碰面奖（萍水相逢）

## MEET_BONUS {silver_each, scope: SAME_OR_ADJACENT, min_moved_steps}
## 抽牌时只在抽牌人身上挂一个标记；确认移动后按「继续」（TurnSystem.proceed 开头调 check_meet_bonus）才结算一次：
## 本回合实际走了至少 min_moved_steps 步、停下的格子上或相邻一格有别的玩家，抽牌人和他们各从银库得 silver_each 块。
## 原地没走不算（结果写明）。标记在结算后和回合结束时清掉。
static func apply_meet_bonus(player: PlayerState, effect: Dictionary, event_id: String) -> Dictionary:
	player.event_flags["meet_bonus"] = {
		"silver_each": int(effect.get("silver_each", 1)),
		"min_moved_steps": int(effect.get("min_moved_steps", 1)),
		"event_id": event_id,
	}
	return {"message": "走到别人身边（同一格或旁边一格），你们各得%d块白银。" % int(effect.get("silver_each", 1))}


## TurnSystem.proceed 调用；没有标记时返回空字典（原版对局永远没有标记）
static func check_meet_bonus(player: PlayerState) -> Dictionary:
	if not player.event_flags.has("meet_bonus"):
		return {}
	var flag: Dictionary = player.event_flags["meet_bonus"]
	player.event_flags.erase("meet_bonus")
	if player.movement_spent < int(flag.get("min_moved_steps", 1)):
		return {"paid": false, "message": "原地没走，不算碰面。"}
	var near := {player.current_node_id: true}
	for edge in GameState.content.get("edges_from", {}).get(player.current_node_id, []):
		near[GameData.edge_other_node(edge, player.current_node_id)] = true
	var met: Array = []
	for p in seat_order_from(player):
		if p != player and near.has((p as PlayerState).current_node_id):
			met.append(p)
	if met.is_empty():
		return {}
	var each := int(flag.get("silver_each", 1))
	var ids: Array[String] = [player.player_id]
	var names: Array[String] = []
	player.silver += GameState.payout_silver(each)
	for p in met:
		(p as PlayerState).silver += GameState.payout_silver(each)
		ids.append((p as PlayerState).player_id)
		names.append((p as PlayerState).display_name)
	return {"paid": true, "player_ids": ids, "message": "和%s碰上了：你们各得%d块白银。" % ["、".join(names), each]}


# ================================================================ 油布（有备无患）

## GRANT_TOKEN {token_id, max_held, blocks_ops, consume: ON_ACTUAL_LOSS, when_held_fallback_max_steps}
## 得到 1 块油布（公开，记在 PlayerState.event_tokens）；已经有了就改走 0–N 步。第一次拿到的这回合不移动。
## 以后自己抽到 blocks_ops 里的事件、而且真的会丢东西时，油布挡掉这一整张的损失后收回（try_block_loss）。
static func apply_grant_token(player: PlayerState, effect: Dictionary) -> Dictionary:
	var token_id := String(effect.get("token_id", ""))
	var held: Dictionary = player.event_tokens.get(token_id, {})
	if int(held.get("count", 0)) >= int(effect.get("max_held", 1)):
		var steps := int(effect.get("when_held_fallback_max_steps", 3))
		player.movement_budget = steps
		player.pending_event_needs_move = true
		return {"needs_move": true, "message": "你已经有油布了，这回合改走 0–%d 步。" % steps, "fx": {"token": {"token_id": token_id, "granted": false}}}
	player.event_tokens[token_id] = {"count": 1, "blocks_ops": (effect.get("blocks_ops", []) as Array).duplicate()}
	return {"message": "获得1块油布：下次事件要你丢东西时，替你挡1次。", "fx": {"token": {"token_id": token_id, "granted": true}}}


## 抽到会丢东西的事件、而且真的会丢时调用：有能挡这个 op 的油布就收回一块、返回结果文字；没有返回空字典。
## 原版对局没有油布（event_tokens 永远为空），这里一进来就返回。
static func try_block_loss(player: PlayerState, op: String) -> Dictionary:
	if player.event_tokens.is_empty():
		return {}
	var ids: Array = player.event_tokens.keys()
	ids.sort()
	for token_id in ids:
		var token: Dictionary = player.event_tokens[token_id]
		if op not in token.get("blocks_ops", []) or int(token.get("count", 0)) <= 0:
			continue
		token["count"] = int(token["count"]) - 1
		if int(token["count"]) <= 0:
			player.event_tokens.erase(token_id)
		return {"message": "油布替你挡住了，油布用掉了。", "token_id": String(token_id)}
	return {}


# ================================================================ 待决分派 / 电脑

## EventSystem.resolve_pending_decision 的分派入口（失败时状态不变）
static func resolve(player: PlayerState, pending: Dictionary, choice: Dictionary) -> Dictionary:
	match String(pending.get("operation", "")):
		"PAY_OR_DROP":
			return resolve_pay_or_drop(player, pending, choice)
		"SOUND_QUIZ":
			return resolve_sound_quiz(player, pending, choice)
		"CHOOSE_ONE":
			return resolve_choose_one(player, pending, choice)
		"PEEK_EVENT_DECK":
			return resolve_peek_event_deck(player, pending, choice)
	return {"success": false, "message": "未知的待决策操作。"}


## AIPolicy.choose_event_decision 的扩展部分（真人座位由测试 / 托管代打时也走这里）。不消耗规则随机数。
static func ai_choose(player: PlayerState, pending: Dictionary) -> Dictionary:
	match String(pending.get("operation", "")):
		"PAY_OR_DROP":
			return ai_choose_pay_or_drop(player, pending)
		"SOUND_QUIZ":
			return {"option_id": ai_sound_quiz_guess(player, String(pending.get("sound_id", "")), pending.get("options", []))}
		"CHOOSE_ONE":
			return {"option_id": ai_choose_one(player, String(pending.get("ai_rule", "")), pending.get("options", []))}
		"PEEK_EVENT_DECK":
			return {"choice": "TO_BOTTOM" if bool(pending.get("is_bad", false)) else "KEEP_TOP"}
		"LOSE_GOOD":
			return {"give_goods": ai_choose_filtered_loss(player, pending.get("legal_give_goods", []), int(pending.get("required_give_count", 1)))}
	return {}


# ================================================================ 座位与结果

## 从 player 开始按座位（行动）顺序的全部玩家
static func seat_order_from(player: PlayerState) -> Array:
	var players: Array = GameState.players
	var start := players.find(player)
	if start < 0:
		return players.duplicate()
	var out: Array = []
	for i in players.size():
		out.append(players[(start + i) % players.size()])
	return out


## 下一位（行动顺序；两人局就是对手；只有一个人时没有下一位）
static func next_seat(player: PlayerState) -> PlayerState:
	var order := seat_order_from(player)
	return order[1] if order.size() > 1 else null


## 抽牌 / 待决前后每位玩家的白银和货，给结果里的 affected 做差
static func snapshot_players() -> Dictionary:
	var snap := {}
	for p in GameState.players:
		snap[(p as PlayerState).player_id] = {"silver": (p as PlayerState).silver, "inventory": (p as PlayerState).inventory.duplicate()}
	return snap


## 谁的白银、货变了（界面据此在轮到真人时留一句「电脑抽的卡改了你的白银 / 货」）
static func affected_since(before: Dictionary) -> Array:
	var out: Array = []
	for p in GameState.players:
		var player := p as PlayerState
		var was: Dictionary = before.get(player.player_id, {})
		if was.is_empty():
			continue
		var silver_delta := player.silver - int(was.get("silver", 0))
		var goods_delta := {}
		var old_inv: Dictionary = was.get("inventory", {})
		var keys := {}
		for k in old_inv.keys():
			keys[String(k)] = true
		for k in player.inventory.keys():
			keys[String(k)] = true
		var sorted_keys: Array = keys.keys()
		sorted_keys.sort()
		for good_id in sorted_keys:
			var d := player.held_count(String(good_id)) - int(old_inv.get(good_id, 0))
			if d != 0:
				goods_delta[String(good_id)] = d
		if silver_delta != 0 or not goods_delta.is_empty():
			out.append({"player_id": player.player_id, "silver_delta": silver_delta, "goods_delta": goods_delta})
	return out


## 扩展卡的抽牌结果补充字段（原版卡不加任何键，保持原版返回值一字不差）
static func decorate_draw_result(result: Dictionary, definition: Dictionary, instance_id: String, player: PlayerState, before: Dictionary, fx: Dictionary) -> Dictionary:
	result["expansion_id"] = String(definition.get("expansion_id", ""))
	result["kind_id"] = String(definition.get("kind_id", ""))
	result["instance_id"] = instance_id
	result["drawn_by"] = player.player_id
	result["sentiment"] = String(definition.get("sentiment", "NEUTRAL"))
	result["sfx"] = String(definition.get("sfx", ""))
	result["sfx_bed"] = String(definition.get("sfx_bed", ""))
	result["sfx_cues"] = (definition.get("sfx_cues", {}) as Dictionary).duplicate()
	result["presentation_fx"] = String(definition.get("presentation_fx", ""))
	result["fx"] = fx
	result["affected"] = affected_since(before)
	return result
