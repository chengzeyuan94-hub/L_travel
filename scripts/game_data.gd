class_name GameData

## 只读数据层：加载规则集 JSON、完整性校验与安全访问。
## 不保存任何对局状态；正式数据与 test_fixture 严格隔离（校验拒绝混入）。

enum Transport { CAMEL, SHIP }
enum RouteType { LAND, SEA }
enum DeckType { LAND, SEA }
enum ResourceKind { GOOD, SILVER }

const FORMAL_RULESET_DIR := "res://data/rulesets/lshu_configurable_v1"
const FIXTURE_RULESET_DIR := "res://tests/fixtures/test_fixture"
const DEMO_RULESET_DIR := "res://data/rulesets/cn_demo_v1"
const CorridorContract := preload("res://scripts/board_corridor_contract.gd")
## HUD / 交易遍历用的稳定商品序（演示四货）；其余商品追加在后并按 id 排序。
const GOOD_ORDER: Array[String] = ["jade", "porcelain", "silk", "tea"]

static var _formal_cache: Dictionary = {}
static var _demo_cache: Dictionary = {}


## 从目录加载规则集，返回统一内容结构；文件缺失时保持空集合。
static func load_ruleset(dir_path: String) -> Dictionary:
	var load_errors: Array[String] = []
	var ruleset_doc := _read_json(dir_path.path_join("ruleset.json"))
	var goods_doc := _read_json(dir_path.path_join("goods.json"))
	var nations_doc := _read_json(dir_path.path_join("nations.json"))
	var cities_doc := _read_json(dir_path.path_join("cities.json"))
	var city_cards_doc := _read_json(dir_path.path_join("city_cards.json"))
	var event_definitions_doc := _read_json(dir_path.path_join("event_definitions.json"))
	var event_instances_doc := _read_json(dir_path.path_join("event_card_instances.json"))
	var board_nodes_doc := _read_json(dir_path.path_join("board_nodes.json"))
	var edges_doc := _read_json(dir_path.path_join("board_edges.json"))
	var decks_doc := _read_json(dir_path.path_join("trade_decks.json"))
	var illustration_doc := _read_json(dir_path.path_join("illustration_manifest.json"))
	var city_lore_doc := _read_json(dir_path.path_join("presentation/city_lore_v1.json"))
	# 卡面短文（2026-09-26）：城市「简介 + 风貌」、事件「成语释义」。纯表现数据，不参与规则。
	var card_text_doc := _read_json(dir_path.path_join("presentation/card_text_v1.json"))
	var corridors_doc: Dictionary = {}
	if String(ruleset_doc.get("ruleset_id", "")) == "lshu_configurable_v1":
		corridors_doc = _read_json(dir_path.path_join("map_corridors_v1.json"))
	var source_docs := {
		"goods.json": goods_doc,
		"nations.json": nations_doc,
		"cities.json": cities_doc,
		"city_cards.json": city_cards_doc,
		"event_definitions.json": event_definitions_doc,
		"event_card_instances.json": event_instances_doc,
		"board_nodes.json": board_nodes_doc,
		"board_edges.json": edges_doc,
		"trade_decks.json": decks_doc,
	}
	if not illustration_doc.is_empty():
		source_docs["illustration_manifest.json"] = illustration_doc
	if not city_lore_doc.is_empty():
		source_docs["presentation/city_lore_v1.json"] = city_lore_doc
	elif String(ruleset_doc.get("ruleset_id", "")) == "lshu_configurable_v1":
		load_errors.append("正式城市图鉴表现数据缺失：presentation/city_lore_v1.json")
	if not card_text_doc.is_empty():
		source_docs["presentation/card_text_v1.json"] = card_text_doc
	elif String(ruleset_doc.get("ruleset_id", "")) == "lshu_configurable_v1":
		load_errors.append("正式卡面短文缺失：presentation/card_text_v1.json")
	for file_name in source_docs:
		_check_document_contract(source_docs[file_name], ruleset_doc, String(file_name), load_errors)
	var illustration_items: Array = illustration_doc.get("items", []).duplicate(true)
	illustration_items.append_array(illustration_doc.get("existing_coverage", []))
	var content := {
		"load_errors": load_errors,
		"ruleset": ruleset_doc,
		"goods": _index_items_checked(goods_doc, "商品", load_errors),
		"nations": _index_items_checked(nations_doc, "国家", load_errors),
		"cities": _index_items_checked(cities_doc, "城市", load_errors),
		"city_cards": _index_items_checked(city_cards_doc, "城市卡", load_errors),
		"event_definitions": _index_items_checked(event_definitions_doc, "事件定义", load_errors),
		"event_card_instances": _index_items_checked(event_instances_doc, "事件实例", load_errors),
		"illustrations": _index_items_checked({"items": illustration_items}, "插画", load_errors),
		"city_lore": _index_items_checked(city_lore_doc, "城市图鉴", load_errors),
		"card_text_cities": _index_items_checked({"items": card_text_doc.get("cities", [])}, "城市卡短文", load_errors),
		"card_text_events": _index_items_checked({"items": card_text_doc.get("events", [])}, "事件释义", load_errors),
		"board_nodes": _index_items_checked(board_nodes_doc, "棋盘节点", load_errors),
		"map_corridors": corridors_doc,
		"board_edges": [],
		"trade_decks": {},
		"trade_card_index": {},
		"edges_from": {},
		"city_by_node": {},
	}
	_check_city_lore_contract(content, load_errors)
	_check_card_text_contract(content, load_errors)
	content["board_edges"] = edges_doc.get("items", [])
	for deck in decks_doc.get("decks", []):
		var deck_id := String(deck.get("id", ""))
		if deck_id.is_empty():
			load_errors.append("贸易牌堆存在空 id")
			continue
		if content["trade_decks"].has(deck_id):
			load_errors.append("贸易牌堆存在重复 id：%s" % deck_id)
		var cards := {}
		for card in deck.get("cards", []):
			var card_id := String(card.get("id", ""))
			if card_id.is_empty():
				load_errors.append("贸易牌堆 %s 存在空卡牌 id" % deck_id)
				continue
			if cards.has(card_id):
				load_errors.append("贸易牌堆 %s 内存在重复卡牌 id：%s" % [deck_id, card_id])
			if content["trade_card_index"].has(card_id):
				load_errors.append(
					"贸易卡 id 跨牌堆重复：%s（%s / %s）"
					% [card_id, content["trade_card_index"][card_id], deck_id]
				)
			cards[card_id] = card
			content["trade_card_index"][card_id] = deck_id
		deck["cards"] = cards
		content["trade_decks"][deck_id] = deck
	for edge in content["board_edges"]:
		for endpoint in [edge["a"], edge["b"]]:
			if not content["edges_from"].has(endpoint):
				content["edges_from"][endpoint] = []
			content["edges_from"][endpoint].append(edge)
	for node in content["board_nodes"].values():
		var city_id: Variant = node.get("city_id")
		if city_id != null and not String(city_id).is_empty():
			content["city_by_node"][node["id"]] = String(city_id)
		var pos: Variant = node.get("map_position")
		if pos is Array and pos.size() >= 2:
			node["map_position"] = Vector2(float(pos[0]), float(pos[1]))
		elif pos is Dictionary and pos.has("x") and pos.has("y"):
			node["map_position"] = Vector2(float(pos["x"]), float(pos["y"]))
		var anchors_variant: Variant = node.get("route_anchors", {})
		if anchors_variant is Dictionary:
			var anchors: Dictionary = anchors_variant
			for route_value in anchors.keys():
				var route_type := String(route_value)
				var anchor: Variant = _board_point(anchors[route_value])
				if anchor != null:
					anchors[route_value] = anchor
	return PublicRules.apply(content) if dir_path == FORMAL_RULESET_DIR else content


## 卡面短文：每座正式城市有「简介」「风貌」，两段合计不超过 100 字；每个正式事件有几十字的成语释义。
const CARD_TEXT_CITY_MAX := 100
const CARD_TEXT_INTRO_RANGE := Vector2i(20, 64)
const CARD_TEXT_SCENERY_RANGE := Vector2i(15, 50)
const CARD_TEXT_EXPLAIN_RANGE := Vector2i(20, 64)


static func _check_card_text_contract(content: Dictionary, errors: Array[String]) -> void:
	if String(content.get("ruleset", {}).get("ruleset_id", "")) != "lshu_configurable_v1":
		return
	var cities: Dictionary = content.get("cities", {})
	var city_text: Dictionary = content.get("card_text_cities", {})
	for city_id in cities.keys():
		if not city_text.has(city_id):
			errors.append("城市卡短文缺少城市：%s" % String(city_id))
			continue
		var item: Dictionary = city_text[city_id]
		var intro := String(item.get("intro", "")).strip_edges()
		var scenery := String(item.get("scenery", "")).strip_edges()
		if intro.length() < CARD_TEXT_INTRO_RANGE.x or intro.length() > CARD_TEXT_INTRO_RANGE.y:
			errors.append("城市卡短文 %s 简介长度 %d 超出 %d–%d" % [String(city_id), intro.length(), CARD_TEXT_INTRO_RANGE.x, CARD_TEXT_INTRO_RANGE.y])
		if scenery.length() < CARD_TEXT_SCENERY_RANGE.x or scenery.length() > CARD_TEXT_SCENERY_RANGE.y:
			errors.append("城市卡短文 %s 风貌长度 %d 超出 %d–%d" % [String(city_id), scenery.length(), CARD_TEXT_SCENERY_RANGE.x, CARD_TEXT_SCENERY_RANGE.y])
		if intro.length() + scenery.length() > CARD_TEXT_CITY_MAX:
			errors.append("城市卡短文 %s 合计 %d 字，超过 %d" % [String(city_id), intro.length() + scenery.length(), CARD_TEXT_CITY_MAX])
	for city_id in city_text.keys():
		if not cities.has(city_id):
			errors.append("城市卡短文含未知城市 id：%s" % String(city_id))
	var events: Dictionary = content.get("event_definitions", {})
	var event_text: Dictionary = content.get("card_text_events", {})
	for event_id in events.keys():
		if not event_text.has(event_id):
			errors.append("事件释义缺少事件：%s" % String(event_id))
			continue
		var explain := String(event_text[event_id].get("explain", "")).strip_edges()
		if explain.length() < CARD_TEXT_EXPLAIN_RANGE.x or explain.length() > CARD_TEXT_EXPLAIN_RANGE.y:
			errors.append("事件释义 %s 长度 %d 超出 %d–%d" % [String(event_id), explain.length(), CARD_TEXT_EXPLAIN_RANGE.x, CARD_TEXT_EXPLAIN_RANGE.y])
	for event_id in event_text.keys():
		if not events.has(event_id):
			errors.append("事件释义含未知事件 id：%s" % String(event_id))


## 正式城市图鉴是独立表现数据，不参与规则结算；这里仅锁定其身份和完整性。
static func _check_city_lore_contract(content: Dictionary, errors: Array[String]) -> void:
	var ruleset_id := String(content.get("ruleset", {}).get("ruleset_id", ""))
	if ruleset_id != "lshu_configurable_v1":
		return
	var cities: Dictionary = content.get("cities", {})
	var lore_items: Dictionary = content.get("city_lore", {})
	if lore_items.size() != cities.size():
		errors.append("正式城市图鉴：%d/%d" % [lore_items.size(), cities.size()])
	var required_fields := [
		"epithet", "position", "history", "sights", "historical_period",
		"modern_reference", "source_refs", "verification_status",
	]
	var text_ranges := {
		"epithet": Vector2i(8, 16),
		"position": Vector2i(20, 60),
		"history": Vector2i(70, 170),
		"sights": Vector2i(30, 90),
	}
	for city_id in lore_items.keys():
		if not cities.has(city_id):
			errors.append("城市图鉴含未知城市 id：%s" % String(city_id))
			continue
		var item: Dictionary = lore_items[city_id]
		if String(item.get("city_id", "")) != String(city_id):
			errors.append("城市图鉴 city_id 与索引不一致：%s" % String(city_id))
		for field in required_fields:
			if not item.has(field):
				errors.append("城市图鉴 %s 缺少字段：%s" % [String(city_id), String(field)])
				continue
			if field == "source_refs":
				var refs: Variant = item.get(field)
				if not (refs is Array) or refs.is_empty():
					errors.append("城市图鉴 %s 缺少可追溯来源" % String(city_id))
					continue
				for ref in refs:
					if not (ref is Dictionary):
						errors.append("城市图鉴 %s 来源格式错误" % String(city_id))
						continue
					var source_title := String(ref.get("title", "")).strip_edges()
					var source_url := String(ref.get("url", "")).strip_edges()
					if source_title.is_empty() or not source_url.begins_with("https://"):
						errors.append("城市图鉴 %s 来源不可追溯：%s" % [String(city_id), source_url])
			elif String(item.get(field, "")).strip_edges().is_empty():
				errors.append("城市图鉴 %s 字段为空：%s" % [String(city_id), String(field)])
		for field in text_ranges:
			var length := String(item.get(field, "")).length()
			var bounds: Vector2i = text_ranges[field]
			if length < bounds.x or length > bounds.y:
				errors.append("城市图鉴 %s %s 长度 %d 超出 %d–%d" % [
				String(city_id), String(field), length, bounds.x, bounds.y,
			])
	for city_id in cities.keys():
		if not lore_items.has(city_id):
			errors.append("城市图鉴缺少正式城市：%s" % String(city_id))


## 内容完整性校验。
## allow_fixture=false：正式局校验，拒绝 test_fixture 冒充正式规则。
## allow_fixture=true：仅允许 ruleset_id == test_fixture 的测试内容。
static func validate_content(content: Dictionary, allow_fixture: bool = false) -> Dictionary:
	var missing: Array[String] = []
	missing.append_array(content.get("load_errors", []))
	var ruleset: Dictionary = content["ruleset"]
	if ruleset.is_empty():
		return {"valid": false, "missing": ["规则集清单缺失"]}
	var ruleset_id := String(ruleset.get("ruleset_id", ""))
	if ruleset_id == "lshu_configurable_v1":
		var configuration_problem := PublicRules.errors(content.get("public_rule_configuration",PublicRules.configuration()))
		if not configuration_problem.is_empty(): return {"valid":false,"missing":configuration_problem}
	if allow_fixture:
		if ruleset_id != "test_fixture":
			missing.append("测试模式必须使用 test_fixture 规则集")
		var fixture_policy := String(ruleset.get("event_deck_exhaust_policy", ""))
		if fixture_policy != "RESHUFFLE_DISCARD":
			missing.append("test_fixture 必须声明 event_deck_exhaust_policy=RESHUFFLE_DISCARD")
	elif ruleset_id == "test_fixture":
		missing.append("禁止：test_fixture 不得作为正式规则集")
	elif ruleset_id == "cn_demo_v1":
		missing.append("禁止：cn_demo_v1 不得作为正式规则集")
	var exhaust_policy := String(ruleset.get("event_deck_exhaust_policy", "RULE_BLOCKED"))
	if exhaust_policy != "RULE_BLOCKED" and exhaust_policy != "RESHUFFLE_DISCARD":
		missing.append("无效的 event_deck_exhaust_policy：%s" % exhaust_policy)
	var warehouse_capacity := int(ruleset.get("warehouse_capacity", -1))
	if warehouse_capacity != 4:
		missing.append("货仓容量必须为 4，当前 %d" % warehouse_capacity)
	var expected: Dictionary = ruleset.get("expected_counts", {})
	var city_card_count: int = content["city_cards"].size()
	var expected_city_cards: int = int(expected.get("city_cards", 0))
	if city_card_count != expected_city_cards:
		missing.append("城市卡：%d/%d" % [city_card_count, expected_city_cards])
	var trade_card_count: int = content["trade_card_index"].size()
	var expected_trade_cards: int = int(expected.get("trade_cards", 0))
	if trade_card_count != expected_trade_cards:
		missing.append("贸易卡：%d/%d" % [trade_card_count, expected_trade_cards])
	var event_count: int = content["event_card_instances"].size()
	var expected_events: int = int(expected.get("event_card_instances", 0))
	if event_count != expected_events:
		missing.append("事件卡实例：%d/%d" % [event_count, expected_events])
	var additional_counts := {
		"国家": [content.get("nations", {}).size(), int(expected.get("nations", content.get("nations", {}).size()))],
		"城市": [content.get("cities", {}).size(), int(expected.get("cities", content.get("cities", {}).size()))],
		"商品": [content.get("goods", {}).size(), int(expected.get("goods", content.get("goods", {}).size()))],
		"贸易牌堆": [content.get("trade_decks", {}).size(), int(expected.get("trade_decks", content.get("trade_decks", {}).size()))],
		"事件定义": [content.get("event_definitions", {}).size(), int(expected.get("event_definitions", content.get("event_definitions", {}).size()))],
		"插画绑定": [content.get("illustrations", {}).size(), int(expected.get("illustrations", content.get("illustrations", {}).size()))],
		"棋盘节点": [content.get("board_nodes", {}).size(), int(expected.get("board_nodes", content.get("board_nodes", {}).size()))],
		"棋盘连接": [content.get("board_edges", []).size(), int(expected.get("board_edges", content.get("board_edges", []).size()))],
	}
	for label in additional_counts:
		var pair: Array = additional_counts[label]
		if int(pair[0]) != int(pair[1]):
			missing.append("%s：%d/%d" % [label, int(pair[0]), int(pair[1])])
	if expected.has("incremental_illustrations"):
		var incremental_count := 0
		for illustration in content.get("illustrations", {}).values():
			if bool(illustration.get("incremental_asset", false)):
				incremental_count += 1
		var expected_incremental := int(expected.get("incremental_illustrations", 0))
		if incremental_count != expected_incremental:
			missing.append("增量插画：%d/%d" % [incremental_count, expected_incremental])
	if content["board_nodes"].is_empty():
		missing.append("棋盘节点：0（未录入）")
	if content["board_edges"].is_empty():
		missing.append("棋盘连接：0（未录入）")
	if ruleset_id == "lshu_configurable_v1":
		_check_formal_board_contract(content, missing)
	_check_transport_interchanges(content, missing, allow_fixture)
	_check_event_ops(content, missing)
	_check_trade_card_entries(content, missing)
	_check_refs(content, missing, "FIXTURE" if allow_fixture else "FORMAL")
	if not allow_fixture:
		_check_formal_rule_blockers(content, missing)
	return {"valid": missing.is_empty(), "missing": missing}


## 正式规则棋盘契约：规则节点使用正式城市 id，表现层别名不得泄漏；海陆资格由
## allowed_routes 明示，换乘只认 is_transport_interchange。每条边还必须保留已经
## 审核过的 movement_polyline，保证规则移动与世界地图使用同一套几何。
static func _check_formal_board_contract(content: Dictionary, missing: Array[String]) -> void:
	var nodes: Dictionary = content.get("board_nodes", {})
	var edges: Array = content.get("board_edges", [])
	missing.append_array(CorridorContract.validate(nodes.values(), edges, content.get("map_corridors", {})))
	if nodes.is_empty() or edges.is_empty():
		return
	var forbidden_presentation_ids := {"ancient_rome": true, "pantuo": true}
	var city_node_ids := {}
	var interchange_ids: Array[String] = []
	var adjacency := {}
	for node_id_value in nodes.keys():
		var node_id := String(node_id_value)
		var node: Dictionary = nodes[node_id_value]
		adjacency[node_id] = []
		if forbidden_presentation_ids.has(node_id):
			missing.append("正式棋盘不得使用表现层城市别名：%s" % node_id)
		var node_type := String(node.get("node_type", ""))
		if node_type != "CITY" and node_type != "ROAD":
			missing.append("正式棋盘节点 %s 类型无效：%s" % [node_id, node_type])
		var raw_position: Variant = node.get("map_position")
		var position: Variant = _board_point(raw_position)
		if position == null:
			missing.append("正式棋盘节点 %s 缺少有效 map_position" % node_id)
		var allowed_variant: Variant = node.get("allowed_routes", [])
		var allowed: Array = allowed_variant if allowed_variant is Array else []
		if allowed.is_empty():
			missing.append("正式棋盘节点 %s 缺少 allowed_routes" % node_id)
		for route_value in allowed:
			if String(route_value) != "LAND" and String(route_value) != "SEA":
				missing.append("正式棋盘节点 %s 包含无效路线类型：%s" % [node_id, String(route_value)])
		var anchors_variant: Variant = node.get("route_anchors", {})
		var anchors: Dictionary = anchors_variant if anchors_variant is Dictionary else {}
		var anchor_keys: Array[String] = []
		for anchor_key_value in anchors.keys():
			var anchor_key := String(anchor_key_value)
			anchor_keys.append(anchor_key)
			if anchor_key != "LAND" and anchor_key != "SEA":
				missing.append("正式棋盘节点 %s 包含无效路线锚点：%s" % [node_id, anchor_key])
			elif _board_point(anchors[anchor_key_value]) == null:
				missing.append("正式棋盘节点 %s 的 %s 路线锚点无效" % [node_id, anchor_key])
		for route_value in allowed:
			if String(route_value) not in anchor_keys:
				missing.append("正式棋盘节点 %s 缺少 %s 路线锚点" % [node_id, String(route_value)])
		for anchor_key in anchor_keys:
			if anchor_key not in allowed:
				missing.append("正式棋盘节点 %s 的 %s 路线锚点不在 allowed_routes" % [node_id, anchor_key])
		var is_interchange := bool(node.get("is_transport_interchange", false))
		if is_interchange:
			interchange_ids.append(node_id)
			if not ("LAND" in allowed and "SEA" in allowed):
				missing.append("正式换乘点 %s 必须同时允许 LAND/SEA" % node_id)
		elif "LAND" in allowed and "SEA" in allowed:
			missing.append("正式节点 %s 同时允许 LAND/SEA 却未标记换乘" % node_id)
		var city_id_value: Variant = node.get("city_id")
		var city_id := "" if city_id_value == null else String(city_id_value)
		if node_type == "CITY":
			if city_id.is_empty() or not content.get("cities", {}).has(city_id):
				missing.append("正式城市节点 %s 缺少有效 city_id" % node_id)
			elif city_id != node_id:
				missing.append("正式城市节点必须使用同名正式 id：%s → %s" % [node_id, city_id])
			elif city_node_ids.has(city_id):
				missing.append("正式城市 %s 映射了多个棋盘节点" % city_id)
			else:
				city_node_ids[city_id] = node_id
		elif not city_id.is_empty():
			missing.append("正式道路节点 %s 不得关联城市 %s" % [node_id, city_id])

	var edge_keys := {}
	for edge_value in edges:
		if not (edge_value is Dictionary):
			missing.append("正式棋盘连接存在非 Dictionary 项")
			continue
		var edge: Dictionary = edge_value
		var edge_id := String(edge.get("id", "?"))
		var a := String(edge.get("a", ""))
		var b := String(edge.get("b", ""))
		var route_type := String(edge.get("route_type", ""))
		if a == b:
			missing.append("正式棋盘连接 %s 不能自环" % edge_id)
		if not nodes.has(a) or not nodes.has(b):
			continue
		if route_type != "LAND" and route_type != "SEA":
			missing.append("正式棋盘连接 %s 路线类型无效：%s" % [edge_id, route_type])
			continue
		var key_parts := [a, b]
		key_parts.sort()
		var edge_key := "%s|%s|%s" % [route_type, key_parts[0], key_parts[1]]
		if edge_keys.has(edge_key):
			missing.append("正式棋盘存在重复连接：%s" % edge_key)
		else:
			edge_keys[edge_key] = true
		for endpoint in [a, b]:
			var endpoint_allowed: Array = nodes[endpoint].get("allowed_routes", [])
			if route_type not in endpoint_allowed:
				missing.append("正式棋盘连接 %s 与节点 %s 的 allowed_routes 冲突" % [edge_id, endpoint])
		adjacency[a].append(b)
		adjacency[b].append(a)
		var movement_variant: Variant = edge.get("movement_polyline", edge.get("movement_polyline_px", []))
		var movement: Array = movement_variant if movement_variant is Array else []
		if movement.size() < 2:
			missing.append("正式棋盘连接 %s 缺少 movement_polyline" % edge_id)
			continue
		var start: Variant = _board_point(movement[0])
		var finish: Variant = _board_point(movement[movement.size() - 1])
		var node_a: Variant = _board_route_anchor(nodes[a], route_type)
		var node_b: Variant = _board_route_anchor(nodes[b], route_type)
		if start == null or finish == null:
			missing.append("正式棋盘连接 %s movement_polyline 坐标无效" % edge_id)
		elif node_a != null and node_b != null:
			if (start as Vector2).distance_to(node_a as Vector2) > 1.0:
				missing.append("正式棋盘连接 %s 起点未贴合节点 %s" % [edge_id, a])
			if (finish as Vector2).distance_to(node_b as Vector2) > 1.0:
				missing.append("正式棋盘连接 %s 终点未贴合节点 %s" % [edge_id, b])

	var city_ids: Array = content.get("cities", {}).keys()
	city_ids.sort()
	var mapped_city_ids: Array = city_node_ids.keys()
	mapped_city_ids.sort()
	if mapped_city_ids != city_ids:
		missing.append("正式棋盘城市覆盖必须为 16/16，当前 %d/%d" % [mapped_city_ids.size(), city_ids.size()])
	for city_id_value in city_ids:
		var city_id := String(city_id_value)
		var city: Dictionary = content["cities"][city_id_value]
		if String(city.get("board_node_id", "")) != city_id:
			missing.append("正式城市 %s board_node_id 必须使用同名正式 id" % city_id)
		if not nodes.has(city_id):
			continue
		var node: Dictionary = nodes[city_id]
		if bool(city.get("is_transport_interchange", false)) != bool(node.get("is_transport_interchange", false)):
			missing.append("正式城市 %s 的换乘语义与棋盘节点不一致" % city_id)
		var city_card_id := String(city.get("city_card_id", ""))
		var city_card: Dictionary = content.get("city_cards", {}).get(city_card_id, {})
		var starting_transport := String(city_card.get("starting_transport", city.get("starting_transport", "")))
		var starting_route := "LAND" if starting_transport == "CAMEL" else "SEA" if starting_transport == "SHIP" else ""
		if starting_route.is_empty():
			missing.append("正式城市 %s 缺少有效起始交通" % city_id)
		elif starting_route not in node.get("allowed_routes", []):
			missing.append("正式城市 %s 起始交通 %s 与棋盘路线不相容" % [city_id, starting_transport])
	interchange_ids.sort()
	var expected_interchanges := ["geumseong", "jeddah", "quanzhou", "rome", "simhala"]
	if interchange_ids != expected_interchanges:
		missing.append("正式棋盘换乘点 id 集合错误：%s" % str(interchange_ids))
	if not adjacency.is_empty():
		var first := String(adjacency.keys()[0])
		var seen := {first: true}
		var frontier := [first]
		while not frontier.is_empty():
			var current := String(frontier.pop_front())
			for other_value in adjacency[current]:
				var other := String(other_value)
				if not seen.has(other):
					seen[other] = true
					frontier.append(other)
		if seen.size() != nodes.size():
			missing.append("正式棋盘必须为单一连通分量，当前可达 %d/%d" % [seen.size(), nodes.size()])


static func _board_point(value: Variant) -> Variant:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	if value is Dictionary and value.has("x") and value.has("y"):
		return Vector2(float(value["x"]), float(value["y"]))
	return null


static func _board_route_anchor(node: Dictionary, route_type: String) -> Variant:
	var anchors_variant: Variant = node.get("route_anchors", {})
	if anchors_variant is Dictionary:
		var anchors: Dictionary = anchors_variant
		if anchors.has(route_type):
			return _board_point(anchors[route_type])
	return null


## Demo 内容校验：ruleset_id 必须为 cn_demo_v1，事件耗尽策略必须为 RESHUFFLE_DISCARD，
## 每个集合成员必须带 demo_fixture 标签，且拒绝 test_fixture / placeholder 标签冒充。
static func validate_demo_content(content: Dictionary) -> Dictionary:
	var missing: Array[String] = []
	missing.append_array(content.get("load_errors", []))
	var ruleset: Dictionary = content.get("ruleset", {})
	if ruleset.is_empty():
		return {"valid": false, "missing": ["规则集清单缺失"]}
	var ruleset_id := String(ruleset.get("ruleset_id", ""))
	if ruleset_id != "cn_demo_v1":
		missing.append("Demo 模式必须使用 cn_demo_v1 规则集")
	var exhaust_policy := String(ruleset.get("event_deck_exhaust_policy", ""))
	if exhaust_policy != "RESHUFFLE_DISCARD":
		missing.append("cn_demo_v1 必须声明 event_deck_exhaust_policy=RESHUFFLE_DISCARD")
	var expected: Dictionary = ruleset.get("expected_counts", {})
	var expected_checks := {
		"city_cards": content.get("city_cards", {}).size(),
		"trade_cards": content.get("trade_card_index", {}).size(),
		"event_card_instances": content.get("event_card_instances", {}).size(),
		"board_nodes": content.get("board_nodes", {}).size(),
		"cities": content.get("cities", {}).size(),
		"goods": content.get("goods", {}).size(),
	}
	for key in expected_checks:
		if not expected.has(key):
			continue
		var actual: int = expected_checks[key]
		var expected_count := int(expected[key])
		if actual != expected_count:
			missing.append("%s：%d/%d" % [key, actual, expected_count])
	if expected.has("board_edges"):
		var edge_count: int = content.get("board_edges", []).size() if content.get("board_edges", []) is Array else 0
		if edge_count != int(expected["board_edges"]):
			missing.append("board_edges：%d/%d" % [edge_count, int(expected["board_edges"])])
	if content.get("board_nodes", {}).is_empty():
		missing.append("棋盘节点：0（未录入）")
	if content.get("board_edges", []).is_empty():
		missing.append("棋盘连接：0（未录入）")
	var silver_100 := int(ruleset.get("silver_supply_by_player_count", {}).get("2", -1))
	if silver_100 != 100:
		missing.append("2 人公共白银必须为 100，当前 %d" % silver_100)
	var warehouse_capacity := int(ruleset.get("warehouse_capacity", -1))
	if warehouse_capacity != 4:
		missing.append("货仓容量必须为 4，当前 %d" % warehouse_capacity)
	_check_transport_interchanges(content, missing, true)
	_check_event_ops(content, missing)
	_check_trade_card_entries(content, missing)
	_check_refs(content, missing, "DEMO")
	return {"valid": missing.is_empty(), "missing": missing}


static func _check_transport_interchanges(content: Dictionary, missing: Array[String], is_demo: bool) -> void:
	var interchange_names: Array[String] = []
	for node in content.get("board_nodes", {}).values():
		if not bool(node.get("is_transport_interchange", false)):
			continue
		var city_id := String(node.get("city_id", ""))
		if city_id.is_empty():
			missing.append("交叉点节点 %s 必须关联城市" % String(node.get("id", "?")))
			continue
		var city: Dictionary = content.get("cities", {}).get(city_id, {})
		var display := String(city.get("display_name", city_id))
		interchange_names.append(display)
	interchange_names.sort()
	if is_demo:
		# Demo 只要求交叉点显式声明；集合可与原版五城不同。
		return
	var expected_cities := int(content.get("ruleset", {}).get("expected_counts", {}).get("city_cards", 0))
	var actual_cities: int = content.get("cities", {}).size()
	# 正式完整包（城市录齐）时必须正好是原版五城；未录齐时只记录目标，不因缺交叉点额外虚构。
	if expected_cities > 0 and actual_cities == expected_cities:
		var expected := ORIGINAL_TRANSPORT_INTERCHANGE_CITY_NAMES.duplicate()
		expected.sort()
		if interchange_names != expected:
			missing.append(
				"正式完整包换乘点必须为原版五城 %s，当前 %s"
				% [str(expected), str(interchange_names)]
			)
	elif not interchange_names.is_empty():
		for name in interchange_names:
			if name not in ORIGINAL_TRANSPORT_INTERCHANGE_CITY_NAMES:
				missing.append("换乘点 %s 不在原版五城集合内" % name)


static func _check_event_ops(content: Dictionary, missing: Array[String]) -> void:
	for definition in content.get("event_definitions", {}).values():
		for effect in definition.get("effects", []):
			var op := String(effect.get("op", ""))
			if op.is_empty():
				missing.append("事件 %s 存在空操作码" % String(definition.get("id", "?")))
			elif op not in KNOWN_EVENT_OPS:
				missing.append("未知事件操作码：%s（事件 %s）" % [op, String(definition.get("id", "?"))])
			for param in EXPANSION_ONLY_EFFECT_PARAMS.get(op, []):
				if effect.has(param):
					missing.append("扩展包参数 %s 不得出现在基础规则集（事件 %s）" % [String(param), String(definition.get("id", "?"))])


## 正式包只要仍声明未决字段 / RULE_BLOCKED 语义，就必须继续挡住正式开局。
## 不能依赖“恰好还缺地图或供应量”间接保持红灯，否则后续补数据会发生假解锁。
static func _check_formal_rule_blockers(content: Dictionary, missing: Array[String]) -> void:
	var ruleset: Dictionary = content.get("ruleset", {})
	for field in ruleset.get("unresolved_rule_fields", []):
		missing.append("未决规则字段：%s（RULE_BLOCKED）" % String(field))
	if String(ruleset.get("event_deck_exhaust_policy", "RULE_BLOCKED")) == "RULE_BLOCKED":
		missing.append("正式事件牌耗尽策略尚未确认（RULE_BLOCKED）")
	if String(ruleset.get("event_deck_exhaust_policy", "")) != "RESHUFFLE_DISCARD":
		missing.append("正式事件牌耗尽策略必须为 RESHUFFLE_DISCARD")
	if String(ruleset.get("lose_good_selection_policy", "")) != "PLAYER_CHOICE":
		missing.append("正式丢货选择策略必须为 PLAYER_CHOICE")
	if String(ruleset.get("half_silver_rounding", "")) != "CEIL":
		missing.append("正式奇数白银减半必须使用 CEIL")
	if String(ruleset.get("half_goods_single_item_policy", "")) != "NO_LOSS":
		missing.append("正式单件半货策略必须为 NO_LOSS")
	if not bool(ruleset.get("gain_starting_resource_uses_full_starting_grant", false)):
		missing.append("正式再次获得起始物资必须按城市卡完整份数结算")
	var blocked_definitions: Array[String] = []
	var blocked_effects: Array[String] = []
	var policy_mismatches: Array[String] = []
	for definition in content.get("event_definitions", {}).values():
		var event_id := String(definition.get("id", "?"))
		if String(definition.get("failure_policy", "NONE")) == "RULE_BLOCKED":
			blocked_definitions.append(event_id)
		for effect in definition.get("effects", []):
			var op := String(effect.get("op", ""))
			if (
				String(effect.get("selection_policy", "")) == "RULE_BLOCKED"
				or String(effect.get("single_item_policy", "")) == "RULE_BLOCKED"
			):
				blocked_effects.append(event_id)
			match op:
				"LOSE_GOOD":
					if String(effect.get("selection_policy", "")) != "PLAYER_CHOICE":
						policy_mismatches.append("%s:LOSE_GOOD 必须 PLAYER_CHOICE" % event_id)
				"LOSE_HALF_GOODS_MAX_2":
					if (
						String(effect.get("single_item_policy", "")) != "NO_LOSS"
						or int(effect.get("two_item_loss_threshold", -1)) != 4
						or int(effect.get("max_loss", -1)) != 2
					):
						policy_mismatches.append("%s:半货规则必须为 1件无损、>3件失去2件" % event_id)
				"GAIN_STARTING_RESOURCE":
					if int(effect.get("quantity", 0)) != 1:
						policy_mismatches.append("%s:再次获得起始物资必须为完整1份" % event_id)
	if not blocked_definitions.is_empty():
		missing.append("事件定义仍含 RULE_BLOCKED：%s" % ", ".join(blocked_definitions))
	if not blocked_effects.is_empty():
		missing.append("事件效果仍含未决选择/舍入：%s" % ", ".join(blocked_effects))
	if not policy_mismatches.is_empty():
		missing.append("事件效果与正式裁决不一致：%s" % "; ".join(policy_mismatches))


static func _check_trade_card_entries(content: Dictionary, missing: Array[String]) -> void:
	for deck in content.get("trade_decks", {}).values():
		for card in deck.get("cards", {}).values():
			var entries: Array = card.get("entries", [])
			if entries.size() < 2:
				missing.append("贸易卡 %s 条目数不足（至少 2）" % String(card.get("id", "?")))
			var kinds: Dictionary = {}
			for entry in entries:
				kinds[String(entry.get("resource_kind", ""))] = true
			# SILVER / GOOD 均可作 give/receive；卡面至少应能形成异种方向对。
			if entries.size() >= 2 and kinds.size() == 1 and kinds.has("SILVER"):
				missing.append("贸易卡 %s 不能仅含白银条目" % String(card.get("id", "?")))


static func _check_refs(content: Dictionary, missing: Array[String], mode: String = "FORMAL") -> void:
	for city in content["cities"].values():
		var city_id := String(city.get("id", "?"))
		if not content["nations"].has(city.get("nation_id")):
			missing.append("城市 %s 引用的国家不存在" % city_id)
		if not content["city_cards"].has(city.get("city_card_id")):
			missing.append("城市 %s 引用的城市卡不存在" % city_id)
		if city.get("board_node_id") == null or not content["board_nodes"].has(city.get("board_node_id")):
			missing.append("城市 %s 缺少有效棋盘节点" % city_id)
		if not content["trade_decks"].has(city.get("trade_color_id")):
			missing.append("城市 %s 缺少对应贸易牌堆" % city_id)
	for card in content["city_cards"].values():
		var city_illustration_id := String(card.get("illustration_id", ""))
		if not city_illustration_id.is_empty() and not content.get("illustrations", {}).has(city_illustration_id):
			missing.append("城市卡 %s 引用的插画不存在" % card.get("id", "?"))
		for entry in card.get("starting_grant", {}).get("entries", []):
			_check_resource_entry(content, entry, "城市卡 %s 起始资源" % card.get("id", "?"), missing)
	for deck in content["trade_decks"].values():
		for card in deck["cards"].values():
			if card["entries"].size() != 4:
				missing.append("贸易卡 %s 不是 4 个等价项" % card.get("id", "?"))
			for entry in card["entries"]:
				_check_resource_entry(content, entry, "贸易卡 %s" % card.get("id", "?"), missing)
	for instance in content["event_card_instances"].values():
		if not content["event_definitions"].has(instance.get("event_id")):
			missing.append("事件卡实例 %s 引用的事件模板不存在" % instance.get("id", "?"))
		elif content["event_definitions"][instance["event_id"]].get("deck_type") != instance.get("deck_type"):
			missing.append("事件卡实例 %s 与模板牌堆不一致" % instance.get("id", "?"))
	for definition in content.get("event_definitions", {}).values():
		var event_illustration_id := String(definition.get("illustration_id", ""))
		if not event_illustration_id.is_empty() and not content.get("illustrations", {}).has(event_illustration_id):
			missing.append("事件 %s 引用的插画不存在" % definition.get("id", "?"))
	for illustration in content.get("illustrations", {}).values():
		var runtime_path := String(illustration.get("runtime_path", ""))
		if runtime_path.is_empty() or not ResourceLoader.exists(runtime_path):
			missing.append("插画 %s 缺少运行时资源" % illustration.get("id", "?"))
	for edge in content["board_edges"]:
		if not content["board_nodes"].has(edge.get("a")) or not content["board_nodes"].has(edge.get("b")):
			missing.append("棋盘连接 %s 引用了不存在的节点" % edge.get("id", "?"))
	for good in content["goods"].values():
		if good.get("supply_total") == null:
			missing.append("商品 %s 缺少供应量" % good.get("id", "?"))
			break
	if mode == "FORMAL":
		var ruleset_id := String(content.get("ruleset", {}).get("ruleset_id", ""))
		if ruleset_id == "legacy_physical_disabled":
			var supply_sum := 0
			for good_id in content["goods"].keys():
				var supply := int(content["goods"][good_id].get("supply_total", -1))
				var expected_supply := 20 if String(good_id) == "silk" else 10
				if supply != expected_supply:
					missing.append("原版商品 %s 供应量必须为 %d，当前 %d" % [String(good_id), expected_supply, supply])
				supply_sum += maxi(0, supply)
			if supply_sum != 160:
				missing.append("原版商品供应总量必须为 160，当前 %d" % supply_sum)
		for collection_name in ["goods", "nations", "cities", "city_cards", "event_definitions", "event_card_instances", "board_nodes", "illustrations"]:
			for item in content[collection_name].values():
				var tags: Array = item.get("content_tags", [])
				if "test_fixture" in tags or "placeholder" in tags or "demo_fixture" in tags:
					missing.append("正式数据包含隔离标记：%s" % item.get("id", "?"))
		for deck in content["trade_decks"].values():
			var deck_tags: Array = deck.get("content_tags", [])
			if "test_fixture" in deck_tags or "placeholder" in deck_tags or "demo_fixture" in deck_tags:
				missing.append("正式数据包含隔离标记：牌堆 %s" % deck.get("id", "?"))
			for card in deck["cards"].values():
				var card_tags: Array = card.get("content_tags", [])
				if "test_fixture" in card_tags or "placeholder" in card_tags or "demo_fixture" in card_tags:
					missing.append("正式数据包含隔离标记：%s" % card.get("id", "?"))
	elif mode == "DEMO":
		for collection_name in ["goods", "nations", "cities", "city_cards", "event_definitions", "event_card_instances", "board_nodes"]:
			for item in content[collection_name].values():
				var tags: Array = item.get("content_tags", [])
				if "test_fixture" in tags or "placeholder" in tags:
					missing.append("Demo 数据混入隔离标记：%s" % item.get("id", "?"))
				elif "demo_fixture" not in tags:
					missing.append("Demo 数据缺少 demo_fixture 标签：%s" % item.get("id", "?"))
		for deck in content["trade_decks"].values():
			var deck_tags: Array = deck.get("content_tags", [])
			if "test_fixture" in deck_tags or "placeholder" in deck_tags:
				missing.append("Demo 数据混入隔离标记：牌堆 %s" % deck.get("id", "?"))
			elif "demo_fixture" not in deck_tags:
				missing.append("Demo 数据缺少 demo_fixture 标签：牌堆 %s" % deck.get("id", "?"))
			for card in deck["cards"].values():
				var card_tags: Array = card.get("content_tags", [])
				if "test_fixture" in card_tags or "placeholder" in card_tags:
					missing.append("Demo 数据混入隔离标记：%s" % card.get("id", "?"))
				elif "demo_fixture" not in card_tags:
					missing.append("Demo 数据缺少 demo_fixture 标签：%s" % card.get("id", "?"))


static func _check_resource_entry(content: Dictionary, entry: Dictionary, context: String, missing: Array[String]) -> void:
	var kind := String(entry.get("resource_kind", ""))
	if kind != "GOOD" and kind != "SILVER":
		missing.append("%s：无效资源类型" % context)
		return
	if kind == "GOOD" and not content["goods"].has(entry.get("resource_id")):
		missing.append("%s：引用的商品不存在" % context)
	if int(entry.get("quantity", 0)) <= 0:
		missing.append("%s：数量必须为正" % context)


static func get_formal_status() -> Dictionary:
	if _formal_cache.is_empty():
		var content := load_ruleset(FORMAL_RULESET_DIR)
		_formal_cache = {"content": content, "validation": validate_content(content)}
	return _formal_cache


static func get_demo_status() -> Dictionary:
	if _demo_cache.is_empty():
		var content := load_ruleset(DEMO_RULESET_DIR)
		_demo_cache = {"content": content, "validation": validate_demo_content(content)}
	return _demo_cache


# ---------- 安全访问 ----------

static func get_node(content: Dictionary, node_id: String) -> Dictionary:
	return content["board_nodes"].get(node_id, {})


static func get_city(content: Dictionary, city_id: String) -> Dictionary:
	return content["cities"].get(city_id, {})


static func get_city_at_node(content: Dictionary, node_id: String) -> String:
	return content["city_by_node"].get(node_id, "")


static func is_city_node(content: Dictionary, node_id: String) -> bool:
	var node := get_node(content, node_id)
	return node.get("node_type") == "CITY" or node.get("node_type") == "PORT_CITY"


static func is_port_node(content: Dictionary, node_id: String) -> bool:
	return get_node(content, node_id).get("node_type") == "PORT_CITY"


## 显式海陆交叉点：换乘资格只读此字段，不得由 PORT_CITY / 海路边推导。
static func is_transport_interchange(content: Dictionary, node_id: String) -> bool:
	return bool(get_node(content, node_id).get("is_transport_interchange", false))


## 原版五座海陆交叉点城市显示名（正式包完整性目标；缺城时由门禁报告，不得虚构补齐）。
const ORIGINAL_TRANSPORT_INTERCHANGE_CITY_NAMES: Array[String] = [
	"古罗马城",
	"吉达",
	"狮子国",
	"泉州",
	"金城",
]


## 事件解释器已支持的操作码；未知 op 在内容加载时拒绝。
const KNOWN_EVENT_OPS: Array[String] = [
	"MOVE_BY_RANGE",
	"LOSE_GOOD",
	"GAIN_STARTING_RESOURCE",
	"LOSE_HALF_GOODS_MAX_2",
	"LOSE_HALF_SILVER_MAX_5",
	"EXCHANGE_ONE_GOOD",
]
## 扩展包（data/expansions/）给原版 op 加的参数：只在扩展包门禁里放行，基础规则集里出现一律拒绝加载。
const EXPANSION_ONLY_EFFECT_PARAMS := {
	"LOSE_GOOD": ["good_filter", "fallback_max_steps", "filter_texts"],
	"EXCHANGE_ONE_GOOD": ["target_scope"],
}


static func get_node_display_name(content: Dictionary, node_id: String) -> String:
	var city_id := get_city_at_node(content, node_id)
	if not city_id.is_empty():
		return String(get_city(content, city_id).get("display_name", city_id))
	return "道路"


static func get_city_name(content: Dictionary, city_id: String) -> String:
	var city := get_city(content, city_id)
	if city.is_empty():
		push_error("GameData: unknown city id '%s'" % city_id)
		return "未知"
	return String(city.get("display_name", city_id))


static func get_good_name(content: Dictionary, good_id: String) -> String:
	var good: Dictionary = content["goods"].get(good_id, {})
	if good.is_empty():
		push_error("GameData: unknown good id '%s'" % good_id)
		return "未知"
	return String(good.get("display_name", good_id))


## 商品图标只读解析入口。正式数据优先使用 goods.json 的 sprite 字段；
## 旧 Demo / fixture 可继续沿用约定命名，避免 UI 各自维护硬编码表。
static func get_good_sprite_path(content: Dictionary, good_id: String) -> String:
	var good: Dictionary = content.get("goods", {}).get(good_id, {})
	var configured_path := String(good.get("sprite", ""))
	if configured_path.begins_with(CustomMapLocalAssets.root() + "/"):
		var local := CustomMapLocalAssets.read(configured_path.get_file(), "good_icon")
		return configured_path if local.ok else ""
	if not configured_path.is_empty():
		if ResourceLoader.exists(configured_path):
			return configured_path
		push_warning("GameData: good '%s' sprite is missing: %s" % [good_id, configured_path])
	var conventional_path := "res://assets/game/goods/good_%s_128.png" % good_id
	if ResourceLoader.exists(conventional_path):
		return conventional_path
	if good.is_empty():
		push_error("GameData: unknown good id '%s'" % good_id)
	else:
		push_warning("GameData: good '%s' has no loadable sprite" % good_id)
	return ""


static func get_good_texture(content: Dictionary, good_id: String) -> Texture2D:
	var sprite_path := get_good_sprite_path(content, good_id)
	if sprite_path.begins_with(CustomMapLocalAssets.root() + "/"):
		var local := CustomMapLocalAssets.read(sprite_path.get_file(), "good_icon")
		return CustomMapLocalAssets.texture(sprite_path.get_file()) if local.ok else null
	return load(sprite_path) if not sprite_path.is_empty() else null


## 按 GOOD_ORDER 返回内容中存在的商品 id；未列入序表的追加在后并按 id 排序。
static func get_goods_ordered(content: Dictionary) -> Array[String]:
	var present: Dictionary = content.get("goods", {})
	var ordered: Array[String] = []
	var seen := {}
	for good_id in GOOD_ORDER:
		if present.has(good_id):
			ordered.append(good_id)
			seen[good_id] = true
	var extras: Array = []
	for good_id in present.keys():
		if not seen.has(String(good_id)):
			extras.append(String(good_id))
	extras.sort()
	for good_id in extras:
		ordered.append(String(good_id))
	return ordered


## 返回的连接按对端 node_id 排序，保证 BFS 邻接遍历顺序稳定、与 Dictionary 内部顺序无关。
static func get_edges_from(content: Dictionary, node_id: String, route_type: int = -1) -> Array:
	var result: Array = []
	for edge in content["edges_from"].get(node_id, []):
		if route_type < 0 or edge.get("route_type") == _route_type_name(route_type):
			result.append(edge)
	result.sort_custom(
		func(a, b):
			return edge_other_node(a, node_id) < edge_other_node(b, node_id)
	)
	return result


static func edge_other_node(edge: Dictionary, node_id: String) -> String:
	return String(edge["b"]) if edge.get("a") == node_id else String(edge.get("a"))


static func get_trade_card(content: Dictionary, card_id: String) -> Dictionary:
	var deck_id: String = content["trade_card_index"].get(card_id, "")
	if deck_id.is_empty():
		push_error("GameData: unknown trade card id '%s'" % card_id)
		return {}
	return content["trade_decks"][deck_id]["cards"][card_id]


static func get_deck_of_card(content: Dictionary, card_id: String) -> String:
	return content["trade_card_index"].get(card_id, "")


static func get_starting_grant(content: Dictionary, city_card_id: String) -> Array:
	var card: Dictionary = content["city_cards"].get(city_card_id, {})
	if card.is_empty():
		push_error("GameData: unknown city card id '%s'" % city_card_id)
		return []
	return card.get("starting_grant", {}).get("entries", [])


static func get_player_colors(content: Dictionary) -> Array:
	return content["ruleset"].get("player_colors", [])


static func get_silver_supply_for(content: Dictionary, player_count: int) -> int:
	return int(content["ruleset"].get("silver_supply_by_player_count", {}).get(str(player_count), 0))


static func describe_entry(content: Dictionary, entry: Dictionary) -> String:
	if String(entry.get("resource_kind")) == "SILVER":
		return "白银 ×%d" % int(entry.get("quantity", 1))
	return "%s ×%d" % [get_good_name(content, String(entry.get("resource_id", ""))), int(entry.get("quantity", 1))]


static func route_type_for_transport(transport: int) -> int:
	return RouteType.LAND if transport == Transport.CAMEL else RouteType.SEA


static func _route_type_name(route_type: int) -> String:
	return "LAND" if route_type == RouteType.LAND else "SEA"


static func deck_type_for_transport(transport: int) -> int:
	return DeckType.LAND if transport == Transport.CAMEL else DeckType.SEA


static func _index_items(doc: Dictionary) -> Dictionary:
	var result := {}
	for item in doc.get("items", []):
		result[item["id"]] = item
	return result


## 所有子文档必须与主 ruleset 的身份头一致，防止把另一版/fixture 的 JSON 混入正式包。
static func _check_document_contract(
	doc: Dictionary,
	ruleset: Dictionary,
	file_name: String,
	errors: Array[String]
) -> void:
	if doc.is_empty() or ruleset.is_empty():
		return
	var expected_ruleset := String(ruleset.get("ruleset_id", ""))
	var expected_edition := String(ruleset.get("edition_id", ""))
	var expected_schema := int(ruleset.get("schema_version", -1))
	if String(doc.get("ruleset_id", "")) != expected_ruleset:
		errors.append("%s 的 ruleset_id 与主清单不一致" % file_name)
	if String(doc.get("edition_id", "")) != expected_edition:
		errors.append("%s 的 edition_id 与主清单不一致" % file_name)
	if int(doc.get("schema_version", -1)) != expected_schema:
		errors.append("%s 的 schema_version 与主清单不一致" % file_name)


## 索引前记录空 id / 重复 id，避免 Dictionary 覆盖造成“数量少了但不知道哪条被吞掉”的假绿。
static func _index_items_checked(doc: Dictionary, label: String, errors: Array[String]) -> Dictionary:
	var result := {}
	for item in doc.get("items", []):
		var item_id := String(item.get("id", ""))
		if item_id.is_empty():
			errors.append("%s存在空 id" % label)
			continue
		if result.has(item_id):
			errors.append("%s存在重复 id：%s" % [label, item_id])
		result[item_id] = item
	return result


static func _read_json(file_path: String) -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {}
	var text := FileAccess.get_file_as_string(file_path)
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		push_error("GameData: failed to parse json '%s'" % file_path)
		return {}
	return parsed
