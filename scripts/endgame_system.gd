class_name EndgameSystem

## 银库终局与结算：公共白银首次拿空触发终局，补齐本轮后按白银→货物判胜。

## 终局已触发且所有玩家完成相同回合数时结算。
static func should_settle() -> bool:
	if not GameState.end_triggered:
		return false
	if GameState.players.is_empty():
		return false
	var turns: int = GameState.players[0].completed_turns
	for player in GameState.players:
		if player.completed_turns != turns:
			return false
	return true


## 结算：白银最多者胜；并列时货物件数最多者胜；仍并列则共同获胜。
static func settle() -> Dictionary:
	var standings: Array = []
	for player in GameState.players:
		standings.append(
			{
				"player_id": player.player_id,
				"display_name": player.display_name,
				"color_id": player.color_id,
				"silver": player.silver,
				"goods": player.cargo_count(),
			}
		)
	standings.sort_custom(
		func(a, b):
			if a["silver"] != b["silver"]:
				return a["silver"] > b["silver"]
			return a["goods"] > b["goods"]
	)
	var best_silver: int = standings[0]["silver"]
	var best_goods: int = standings[0]["goods"]
	var winner_ids: Array = []
	for entry in standings:
		if entry["silver"] == best_silver and entry["goods"] == best_goods:
			winner_ids.append(entry["player_id"])
	GameState.result = {
		"standings": standings,
		"winner_ids": winner_ids,
		"is_tie": winner_ids.size() > 1,
		"end_triggered_round": GameState.end_triggered_round,
		"end_reason": GameState.end_reason,
		"reserve_silver_used": GameState.reserve_silver_used,
	}
	GameState.phase = GameState.Phase.GAME_OVER
	print("EndgameSystem: settled, winners = %s" % [winner_ids])
	return GameState.result
