class_name PlayerState
extends RefCounted

## 玩家对局状态（纯数据对象）。字段边界见 docs/design/expandable-domain-model.md §2。
## inventory（数量视图）与 warehouse_slots（展示顺序）只能通过本类方法原子修改。

var player_id: String = ""
var display_name: String = ""
var seat_index: int = 0
var turn_order: int = 0
var color_id: String = ""
var controller_type: String = "LOCAL_HUMAN"
## 电脑商旅的难度（AIDifficulty：qingzhuang / shanhai / wanli）；空 = 山海独旅（原有 AI）。
var ai_difficulty: String = ""

var silver: int = 0
var inventory: Dictionary = {}
var warehouse_capacity: int = 4
var warehouse_slots: Array[String] = []
var starting_city_card_id: String = ""
var home_city_id: String = ""
var starting_resource_snapshot: Dictionary = {}

var camel_token_id: String = ""
var ship_token_id: String = ""
var active_transport: int = GameData.Transport.CAMEL
var reserve_transport: int = GameData.Transport.SHIP
var current_node_id: String = ""

var completed_turns: int = 0
var die_result: Variant = null
var movement_budget: int = 0
var movement_spent: int = 0
var pending_event_needs_move: bool = false
var move_confirmed: bool = false
var opened_trade_route_this_turn: bool = false
var trade_action_used: bool = false
var turn_command_log: Array = []
## 扩展包「L叔的趣味事件」第二批：随身的事件道具（有备无患的油布 {"RAIN_TARP": {"count", "blocks_ops"}}），跨回合保留、进存档；
## 原版对局永远为空。
var event_tokens: Dictionary = {}
## 同上：本回合的事件标记（萍水相逢的碰面奖），「继续」时结算、回合结束清掉；原版对局永远为空。
var event_flags: Dictionary = {}


func is_local_human() -> bool:
	return controller_type == "LOCAL_HUMAN"


func is_ai() -> bool:
	return controller_type == "AI"


func cargo_count() -> int:
	## 货仓容量按货物总件数计（同种 3 件 = 3），不是种类数。
	return warehouse_slots.size()


func warehouse_remaining() -> int:
	return warehouse_capacity - cargo_count()


func held_count(good_id: String) -> int:
	return int(inventory.get(good_id, 0))


func can_accept_goods(count: int = 1) -> bool:
	return cargo_count() + count <= warehouse_capacity


func add_good(good_id: String, count: int = 1) -> void:
	inventory[good_id] = held_count(good_id) + count
	for _i in count:
		warehouse_slots.append(good_id)


func remove_good(good_id: String, count: int = 1) -> bool:
	if held_count(good_id) < count:
		return false
	var next := held_count(good_id) - count
	if next <= 0:
		inventory.erase(good_id)
	else:
		inventory[good_id] = next
	for _i in count:
		warehouse_slots.erase(good_id)
	return true


func reset_turn_assets() -> void:
	die_result = null
	movement_budget = 0
	movement_spent = 0
	pending_event_needs_move = false
	move_confirmed = false
	opened_trade_route_this_turn = false
	trade_action_used = false
	turn_command_log = []
	event_flags = {}
