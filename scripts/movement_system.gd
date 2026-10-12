class_name MovementSystem

## 节点移动：每条相邻连接 1 步，0–N 步，任意方向；
## 骆驼只走陆路，商船只走海路；仅显式海陆交叉点可换乘。不扣白银、不推进日期、不判风险。
## 所有查询均无副作用：不修改 GameState/PlayerState、不发信号、不消耗 RNG。

## 当前玩家（或指定 transport 覆盖）在 max_steps 内可达的节点：node_id -> 距离（含当前节点 0 步）。
## 邻接遍历顺序稳定（GameData.get_edges_from 已按对端 node_id 排序）。
static func get_legal_destinations(player: PlayerState, max_steps: int, transport: int = -1) -> Dictionary:
	var active_transport := transport if transport >= 0 else player.active_transport
	var result := {player.current_node_id: 0}
	if max_steps <= 0:
		return result
	var route_type := GameData.route_type_for_transport(active_transport)
	var frontier: Array = [player.current_node_id]
	var dist := 0
	while not frontier.is_empty() and dist < max_steps:
		dist += 1
		var next: Array = []
		for node_id in frontier:
			for edge in GameData.get_edges_from(GameState.content, node_id, route_type):
				var other := GameData.edge_other_node(edge, node_id)
				if not result.has(other):
					result[other] = dist
					next.append(other)
		frontier = next
	return result


## 校验路径：从当前节点开始、连续相邻、允许交通工具（可覆盖）、步数不超上限。空路径为主动停留。
static func validate_path(player: PlayerState, path: Array, max_steps: int, transport: int = -1) -> Dictionary:
	if path.is_empty():
		return {"success": true, "steps": 0}
	if String(path[0]) != player.current_node_id:
		return {"success": false, "message": "路径必须从当前节点开始。"}
	if path.size() - 1 > max_steps:
		return {"success": false, "message": "超出可移动步数。"}
	var active_transport := transport if transport >= 0 else player.active_transport
	var route_type := GameData.route_type_for_transport(active_transport)
	for i in range(1, path.size()):
		if not _has_edge(String(path[i - 1]), String(path[i]), route_type):
			return {"success": false, "message": "路径不连续或当前交通工具不能通过。"}
	return {"success": true, "steps": path.size() - 1}


## 最短路径（BFS，可覆盖 transport），返回含起点的节点序列；目标即当前节点时返回空路径。
static func find_path(player: PlayerState, target_node_id: String, max_steps: int, transport: int = -1) -> Array:
	if target_node_id == player.current_node_id:
		return []
	var active_transport := transport if transport >= 0 else player.active_transport
	var route_type := GameData.route_type_for_transport(active_transport)
	var came_from := {player.current_node_id: ""}
	var frontier: Array = [player.current_node_id]
	var dist := 0
	while not frontier.is_empty() and dist < max_steps:
		dist += 1
		var next: Array = []
		for node_id in frontier:
			for edge in GameData.get_edges_from(GameState.content, node_id, route_type):
				var other := GameData.edge_other_node(edge, node_id)
				if not came_from.has(other):
					came_from[other] = node_id
					if other == target_node_id:
						var path := [target_node_id]
						while String(path[0]) != player.current_node_id:
							path.push_front(came_from[path[0]])
						return path
					next.append(other)
		frontier = next
	return []


## 指定 transport 在 max_steps 内可达的城市节点 id，按 node_id 排序（不含普通道路节点）。
static func get_reachable_cities(player: PlayerState, max_steps: int, transport: int) -> Array:
	var destinations := get_legal_destinations(player, max_steps, transport)
	var cities: Array = []
	for node_id in destinations:
		if GameData.is_city_node(GameState.content, String(node_id)):
			cities.append(String(node_id))
	cities.sort()
	return cities


## 描述一个移动方案：终点、步数、是否需要先换乘（transport_after_switch != 当前交通工具）。
## 不修改状态；换乘校验仍由 TurnSystem.switch_transport 在真正执行时完成。
static func describe_move_option(player: PlayerState, path: Array, transport_after_switch: int) -> Dictionary:
	var needs_switch := transport_after_switch != player.active_transport
	var destination := String(path[path.size() - 1]) if not path.is_empty() else player.current_node_id
	var steps := path.size() - 1 if not path.is_empty() else 0
	return {
		"path": path.duplicate(),
		"destination_node_id": destination,
		"steps": steps,
		"transport": transport_after_switch,
		"needs_switch": needs_switch,
		"is_city": GameData.is_city_node(GameState.content, destination),
		"is_port": GameData.is_port_node(GameState.content, destination),
	}


static func execute_path(player: PlayerState, path: Array) -> int:
	if path.is_empty():
		return 0
	player.current_node_id = String(path[path.size() - 1])
	return path.size() - 1


static func can_switch_transport(player: PlayerState) -> bool:
	# 移动途中（已消耗步数但尚未确认整段移动）禁止换乘后继续走。
	if player.movement_spent > 0 and not player.move_confirmed:
		return false
	return GameData.is_transport_interchange(GameState.content, player.current_node_id)


static func _has_edge(from_id: String, to_id: String, route_type: int) -> bool:
	for edge in GameData.get_edges_from(GameState.content, from_id, route_type):
		if GameData.edge_other_node(edge, from_id) == to_id:
			return true
	return false
