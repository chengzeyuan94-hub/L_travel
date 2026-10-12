class_name TurnSystem

## 回合状态机：ROLL_DIE → MOVE_OR_EVENT → OPEN_TRADE_ROUTE → TRADE → END_TURN。
## 所有命令先做阶段校验，阶段外命令一律拒绝；每个成功命令只发出一次 state_changed。

## 掷骰。injected 仅供测试注入（1–5 或 DiceSystem.FACE_EVENT）。
static func roll_die(injected: Variant = null) -> Dictionary:
	if GameState.phase != GameState.Phase.ROLL_DIE:
		return _fail("当前阶段不能掷骰。")
	if EventSystem.has_pending_decision():
		return _fail("请先完成事件选择。")
	var player := GameState.current_player()
	var face: Variant = injected if injected != null else DiceSystem.roll()
	if not DiceSystem.is_valid_face(face):
		return _fail("无效的骰面。")
	player.die_result = face
	GameState.phase = GameState.Phase.MOVE_OR_EVENT
	var event_result: Dictionary = {}
	if DiceSystem.is_event_face(face):
		player.movement_budget = 0
		event_result = EventSystem.draw_and_resolve(player)
		if not bool(event_result.get("needs_move", false)):
			player.pending_event_needs_move = false
	else:
		player.movement_budget = int(face)
	print(
		"TurnSystem: %s rolled %s (budget %d)"
		% [player.player_id, DiceSystem.face_text(face), player.movement_budget]
	)
	GameState.state_changed.emit()
	return {
		"success": true,
		"die_result": face,
		"event": event_result,
		"message": "掷出 %s。" % DiceSystem.face_text(face),
	}


## 确认移动路径（空路径为主动停留 0 步）。数值骰 0–N 步，事件移动同理。
## 成功时附带只读 visual_move，供 BoardView 播放动画；规则状态只提交一次。
static func confirm_move(path: Array) -> Dictionary:
	if GameState.phase != GameState.Phase.MOVE_OR_EVENT:
		return _fail("当前阶段不能移动。")
	if EventSystem.has_pending_decision():
		return _fail("请先完成事件选择。")
	var player := GameState.current_player()
	if player.move_confirmed:
		return _fail("本次移动已确认。")
	var check := MovementSystem.validate_path(player, path, player.movement_budget)
	if not check["success"]:
		return _fail(check["message"])
	var from_node := player.current_node_id
	var steps := MovementSystem.execute_path(player, path)
	player.movement_spent = steps
	player.move_confirmed = true
	print("TurnSystem: %s moved %d steps to %s" % [player.player_id, steps, player.current_node_id])
	GameState.state_changed.emit()
	var node_name := GameData.get_node_display_name(GameState.content, player.current_node_id)
	var visual_path: Array = path.duplicate()
	if visual_path.is_empty():
		visual_path = [from_node]
	elif String(visual_path[0]) != from_node:
		visual_path.push_front(from_node)
	return {
		"success": true,
		"message": "移动 %d 步，停在 %s。" % [steps, node_name],
		"visual_move": {
			"player_id": player.player_id,
			"path": visual_path,
			"transport": player.active_transport,
			"from_node_id": from_node,
			"to_node_id": player.current_node_id,
			"steps": steps,
		},
	}


## 海陆交叉点换乘：只能在 MOVE_OR_EVENT 阶段、当前位于显式交叉点时使用。
## 换乘发生在移动开始前或结束后，不允许移动中途换乘后继续使用剩余步数。
static func switch_transport() -> Dictionary:
	if GameState.phase != GameState.Phase.MOVE_OR_EVENT:
		return _fail("当前阶段不能换乘。")
	if EventSystem.has_pending_decision():
		return _fail("请先完成事件选择。")
	var player := GameState.current_player()
	if player.movement_spent > 0 and not player.move_confirmed:
		return _fail("移动途中不能换乘。")
	if not MovementSystem.can_switch_transport(player):
		return _fail("只有海陆交叉点可以换乘。")
	var old := player.active_transport
	player.active_transport = player.reserve_transport
	player.reserve_transport = old
	print("TurnSystem: %s switched transport to %d" % [player.player_id, player.active_transport])
	GameState.state_changed.emit()
	return {"success": true, "message": "已换乘为%s。" % _transport_name(player.active_transport)}


## 结束移动/事件阶段，进入开通商道检查，再到贸易阶段。
static func proceed() -> Dictionary:
	if GameState.phase != GameState.Phase.MOVE_OR_EVENT:
		return _fail("当前阶段不能继续。")
	if EventSystem.has_pending_decision():
		return _fail("请先完成事件选择。")
	var player := GameState.current_player()
	if player.pending_event_needs_move and not player.move_confirmed:
		return _fail("请先确认事件移动（可选择 0 步停留）。")
	if not DiceSystem.is_event_face(player.die_result) and not player.move_confirmed:
		return _fail("请先确认移动路径（可选择 0 步停留）。")
	player.pending_event_needs_move = false
	# 扩展包第二批「萍水相逢」：确认移动后结算一次碰面奖（原版对局没有这个标记，不进这个分支）
	var meet: Dictionary = {}
	if not player.event_flags.is_empty():
		meet = FunEventOps.check_meet_bonus(player)
	GameState.phase = GameState.Phase.OPEN_TRADE_ROUTE
	var open_result := TradeSystem.open_trade_route_if_needed()
	GameState.phase = GameState.Phase.TRADE
	GameState.state_changed.emit()
	var message := String(open_result.get("message", ""))
	if message.is_empty():
		if GameData.is_city_node(GameState.content, player.current_node_id):
			message = "该城市已有贸易卡。"
		else:
			message = "停在道路节点，不能开通商道或贸易。"
	var result := {"success": true, "opened": open_result.get("opened", false), "message": message}
	if not meet.is_empty():
		result["meet_bonus"] = meet
	return result


## 跳过贸易。
static func skip_trade() -> Dictionary:
	if GameState.phase != GameState.Phase.TRADE:
		return _fail("当前阶段不能跳过贸易。")
	GameState.phase = GameState.Phase.END_TURN
	GameState.state_changed.emit()
	return {"success": true, "message": "跳过贸易。"}


## 结束回合：补齐本轮检查，未触发终局则交给下一位玩家。
static func end_turn() -> Dictionary:
	if GameState.phase != GameState.Phase.END_TURN:
		return _fail("当前阶段不能结束回合。")
	if EventSystem.has_pending_decision():
		return _fail("请先完成事件选择。")
	var player := GameState.current_player()
	player.completed_turns += 1
	if not player.event_flags.is_empty():
		player.event_flags.clear()
	print(
		"TurnSystem: %s ends turn %d (round %d)"
		% [player.player_id, player.completed_turns, GameState.round_index]
	)
	if EndgameSystem.should_settle():
		EndgameSystem.settle()
		GameState.state_changed.emit()
		return {"success": true, "message": "本局结束。", "game_over": true}
	GameState.current_player_index = (GameState.current_player_index + 1) % GameState.players.size()
	if GameState.current_player_index == 0:
		GameState.round_index += 1
	GameState.current_player().reset_turn_assets()
	GameState.phase = GameState.Phase.ROLL_DIE
	GameState.state_changed.emit()
	return {"success": true, "message": "回合结束。", "game_over": false}


static func _transport_name(transport: int) -> String:
	return "骆驼" if transport == GameData.Transport.CAMEL else "商船"


static func _fail(message: String) -> Dictionary:
	return {"success": false, "message": message}
