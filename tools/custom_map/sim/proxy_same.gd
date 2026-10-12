extends RefCounted

## 真人代理 1（DESIGN 4.4）：和电脑同一套策略（山海独旅，自制地图里带 X3）。
## 地图让电脑吃亏的地方它也一样吃亏，所以量不出真人换一种简单打法能拿到的优势，要和另外两种代理一起取最大差值。
## 只给 tools/custom_map/sim 用，不进仓库的 AI。


static func choose_move(player: PlayerState) -> Dictionary:
	return AIPolicy.choose_move(player)


static func choose_trade(player: PlayerState) -> Dictionary:
	return AIPolicy.choose_trade(player)


static func choose_event_decision(player: PlayerState, pending: Dictionary) -> Dictionary:
	return AIPolicy.choose_event_decision(player, pending)
