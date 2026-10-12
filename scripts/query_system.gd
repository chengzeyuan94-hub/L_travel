class_name QuerySystem

## 阶段与控制权只读查询：不修改 GameState/PlayerState、不发信号、不消耗 RNG。
## UI 与 AITurnController 共用，用于判断当前应由谁行动、当前阶段允许哪些命令。

static func current_is_human() -> bool:
	if GameState.players.is_empty():
		return false
	return GameState.current_player().is_local_human()


static func current_is_ai() -> bool:
	if GameState.players.is_empty():
		return false
	return GameState.current_player().is_ai()


## 真人 UI 当前是否应接受输入：真人当前、非结算、且当前阶段有合法命令。
static func accepts_human_input() -> bool:
	if not current_is_human():
		return false
	if GameState.phase == GameState.Phase.GAME_OVER:
		return false
	return not allowed_commands().is_empty()


## 当前阶段允许的命令名（字符串标识，与规则系统方法一一对应）。
static func allowed_commands() -> Array[String]:
	var commands: Array[String] = []
	if EventSystem.has_pending_decision():
		# pending 期间禁止丢弃，避免“必须失去 N 件”被掏空货仓后死锁。
		commands.append("RESOLVE_EVENT_DECISION")
		return commands
	match GameState.phase:
		GameState.Phase.ROLL_DIE:
			commands.append("ROLL_DIE")
		GameState.Phase.MOVE_OR_EVENT:
			var player := GameState.current_player() if not GameState.players.is_empty() else null
			if player != null and MovementSystem.can_switch_transport(player):
				commands.append("SWITCH_TRANSPORT")
			commands.append("CONFIRM_MOVE")
			commands.append("PROCEED")
		GameState.Phase.TRADE:
			commands.append("TRADE_RATIO")
			commands.append("TRADE_DIRECT_SALE")
			commands.append("SKIP_TRADE")
		GameState.Phase.END_TURN:
			commands.append("END_TURN")
		_:
			pass
	if GameState.is_in_turn() and not GameState.players.is_empty():
		commands.append("DISCARD_GOODS")
	return commands
