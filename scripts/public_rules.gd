class_name PublicRules
extends RefCounted
## User-owned rules only. No original tabletop deck, event wording or fitted
## legacy parameters are supplied. An agent must ask the owner before filling this.
const SCHEMA := "lshu.rules.config.v1"
const FILE := "rules-config.json"
const MAX_BYTES := 1048576

static func path() -> String:
	return preload("res://scripts/lshu_ui/lshu_progress.gd").dir_path().path_join(FILE)

static func template() -> Dictionary:
	return {"schema":SCHEMA,"confirmed_by_owner":false,"seed":0,"events_enabled":null,
		"ruleset":{},"goods":[],"city_cards":[],"trade_decks":[],"event_recipes":[],
		"generator_params":{},"generation_request":{}}

static func configuration() -> Dictionary:
	if not FileAccess.file_exists(path()): return {}
	var f := FileAccess.open(path(),FileAccess.READ)
	if f == null or f.get_length() > MAX_BYTES: return {}
	var value: Variant = JSON.parse_string(f.get_as_text())
	return value if value is Dictionary else {}

static func errors(d: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if d.get("schema") != SCHEMA: out.append("缺少规则配置版本")
	if not d.get("confirmed_by_owner") is bool or d.get("confirmed_by_owner") != true: out.append("请先与使用者确认经济、事件效果和文字、城市特产")
	if not d.get("ruleset") is Dictionary or d.ruleset.is_empty(): out.append("经济与骰子规则未配置")
	for field: String in ["goods","city_cards","trade_decks"]:
		if not d.get(field) is Array or d[field].is_empty(): out.append(field+" 尚未配置")
	if not integer_in(d.get("seed"),-2147483648,2147483647): out.append("种子需为32位整数")
	if not d.get("events_enabled") is bool: out.append("请明确是否启用事件")
	elif d.events_enabled and (not d.get("event_recipes") is Array or d.event_recipes.is_empty()): out.append("事件效果与自有文字模板未配置")
	if not out.is_empty(): return out
	for reserved: String in ["ruleset_id","edition_id","expected_counts","public_configuration_required"]:
		if d.ruleset.has(reserved): out.append("请勿覆盖内部身份字段："+reserved)
	for key: String in ["warehouse_capacity","open_trade_route_reward","direct_sale_rate"]:
		if not integer_in(d.ruleset.get(key),0,1000000): out.append("请确认整数经济参数："+key)
	var silver: Variant=d.ruleset.get("silver_supply_by_player_count")
	if not silver is Dictionary: out.append("银库供应尚未确认")
	else:
		for count: String in ["2","3","4"]:
			if not integer_in(silver.get(count),1,1000000): out.append("银库供应需为正整数："+count)
	var faces: Variant=d.ruleset.get("dice_faces")
	if not faces is Array or faces.is_empty(): out.append("骰子规则尚未确认")
	else:
		for face: Variant in faces:
			if not (face is String and face=="EVENT") and not integer_in(face,1,100): out.append("骰子面需为正整数或EVENT")
		if faces.any(func(v):return v is String and v=="EVENT") and not d.events_enabled: out.append("事件骰面需要已配置事件")
	for row: Variant in d.goods:
		if not row is Dictionary or not row.get("id") is String or not integer_in(row.get("supply_total"),0,1000000): out.append("商品需有身份和非负整数供应")
	for row: Variant in d.city_cards:
		if not row is Dictionary or not row.get("city_id") is String or not row.get("starting_grant") is Dictionary or not row.starting_grant.get("entries") is Array: out.append("城市起始物资格式缺失"); continue
		for entry: Variant in row.starting_grant.entries:
			if not valid_entry(entry): out.append("城市起始物资条目不合法")
	var seen: Dictionary={}
	for deck: Variant in d.trade_decks:
		if not deck is Dictionary or not deck.get("id") is String or not deck.get("city_ids") is Array or not deck.get("cards") is Array or deck.cards.is_empty(): out.append("贸易牌堆身份、城市与卡牌缺失"); continue
		for card: Variant in deck.cards:
			if not card is Dictionary or not card.get("id") is String or not card.get("entries") is Array or card.entries.size()!=4: out.append("贸易卡需有身份和四个等价项"); continue
			if seen.has(card.id): out.append("贸易卡身份重复")
			seen[card.id]=true
			for entry: Variant in card.entries:
				if not valid_entry(entry): out.append("贸易卡条目不合法")
	if not d.get("event_recipes") is Array: out.append("事件模板列表格式错误")
	else:
		var event_result:=generate_events(d.event_recipes,int(d.get("seed",0)))
		if not event_result.ok: out.append_array(event_result.errors)
	return out

static func integer_in(v: Variant, lo:int, hi:int)->bool:
	return (v is int or v is float) and is_finite(float(v)) and float(v)==int(v) and int(v)>=lo and int(v)<=hi

static func valid_entry(v: Variant)->bool:
	return v is Dictionary and v.get("resource_kind") in ["GOOD","SILVER"] and v.get("resource_id") is String and integer_in(v.get("quantity"),1,1000000)

static func ready() -> bool:
	if not errors(configuration()).is_empty(): return false
	return bool(GameData.get_formal_status().get("validation",{}).get("valid",false))

## Existing original v2 generator, driven exclusively by owner-confirmed input.
## It generates additional-city decks from the supplied graph, goods/origins and
## parameters; it is not a reconstruction of the tabletop author's formula.
static func generate_trade(request: Dictionary, params: Dictionary) -> Dictionary:
	if request.get("confirmed_by_owner") != true: return {"ok":false,"errors":["生成前先与使用者确认规则"]}
	for key: String in ["goods","producers","distances","goods_map"]:
		if not request.get(key) is Dictionary: return {"ok":false,"errors":["缺少生成输入："+key]}
	if not request.get("topology") is Array: return {"ok":false,"errors":["缺少城市拓扑"]}
	var problem := parameter_errors(params)
	if not problem.is_empty(): return {"ok":false,"errors":problem}
	return TradeGenV2Original.generate_context(request.goods,request.producers,request.distances,request.topology,request.goods_map,TradeGenV2Original.integers(params))

static func parameter_errors(p: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if p.get("version") != TradeGenV2Original.VERSION: out.append("原创v2参数版本缺失")
	for key: String in ["silver_cap","price_base","distance_step","silk_count","partner_count","foreign_max","weight_scale","assignment_relaxation_budget"]:
		if not p.get(key) is float and not p.get(key) is int: out.append("缺少生成参数："+key)
		elif float(p[key]) != int(p[key]) or int(p[key]) < 1 or int(p[key]) > 1000000: out.append("生成参数需为有界正整数："+key)
	if not p.get("local_batches") is Array or p.local_batches.size()!=5: out.append("请确认五组本地批量和报价")
	else:
		for row: Variant in p.local_batches:
			if not row is Array or row.size()!=2: out.append("本地批量格式错误"); continue
			for v: Variant in row:
				if not (v is int or v is float) or float(v)!=int(v) or int(v)<1 or int(v)>1000: out.append("本地批量与报价需为正整数")
	return out

## Effects and templates are supplied by the owner, not inferred from old cards.
## Seeded choices only choose within explicit user-provided variable lists.
static func generate_events(recipes: Array, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new(); rng.seed=seed_value
	var definitions: Array = []; var instances: Array = []; var ids: Dictionary = {}
	for value: Variant in recipes:
		if not value is Dictionary: return {"ok":false,"errors":["事件模板必须为对象"]}
		var row: Dictionary = value
		var id := str(row.get("id",""))
		if id.is_empty() or ids.has(id) or row.get("deck_type") not in ["LAND","SEA"] or not row.get("effects") is Array or row.effects.is_empty(): return {"ok":false,"errors":["事件身份、交通或效果缺失"]}
		ids[id]=true
		if not row.get("variables",{}) is Dictionary: return {"ok":false,"errors":["事件变量必须是对象"]}
		for effect: Variant in row.effects:
			if not effect is Dictionary or effect.get("op") not in GameData.KNOWN_EVENT_OPS: return {"ok":false,"errors":["事件操作码不受支持"]}
		var text := str(row.get("template","")); var variables: Dictionary = row.get("variables",{})
		if text.is_empty(): return {"ok":false,"errors":["请提供自有事件文字模板"]}
		var keys: Array = variables.keys(); keys.sort()
		for key: Variant in keys:
			var v: Variant = variables[key]
			if v is Array:
				if v.is_empty(): return {"ok":false,"errors":["事件变量列表不能为空"]}
				v=v[rng.randi_range(0,v.size()-1)]
			text=text.replace("{"+str(key)+"}",str(v))
		var definition := row.duplicate(true)
		definition["title"]=str(row.get("title",id)); definition["flavor_text"]=text
		definition["normalized_effect_text"]=text; definition["original_effect_text"]=""
		definitions.append(definition)
		instances.append({"id":"user_event_"+id,"event_id":id,"deck_type":row.deck_type})
	return {"ok":true,"definitions":definitions,"instances":instances,"errors":[]}

static func apply(content: Dictionary, d: Dictionary = {}) -> Dictionary:
	if d.is_empty(): d=configuration()
	if not errors(d).is_empty(): return content
	content["public_rule_configuration"]=d.duplicate(true)
	content.ruleset.merge(d.ruleset,true)
	content.ruleset.public_configuration_required=false; content.ruleset.unresolved_rule_fields=[]
	for value: Variant in d.goods:
		if value is Dictionary and content.goods.has(str(value.get("id",""))): content.goods[str(value.id)].merge(value,true)
	for value: Variant in d.city_cards:
		if value is Dictionary and content.cities.has(str(value.get("city_id",""))):
			var card_id: String = str(content.cities[str(value.city_id)].city_card_id)
			content.city_cards[card_id].merge(value,true)
	content.trade_decks={}; content.trade_card_index={}
	for value: Variant in d.trade_decks:
		if not value is Dictionary or not value.get("cards") is Array: continue
		var deck: Dictionary = value.duplicate(true); var cards: Dictionary = {}
		for card: Variant in value.cards:
			if card is Dictionary:
				cards[str(card.get("id",""))]=card; content.trade_card_index[str(card.get("id",""))]=str(deck.get("id",""))
		deck.cards=cards; content.trade_decks[str(deck.get("id",""))]=deck
		for cid: Variant in deck.get("city_ids",[]):
			if content.cities.has(str(cid)): content.cities[str(cid)].trade_color_id=str(deck.id)
	var ev := generate_events(d.get("event_recipes",[]),int(d.get("seed",0)))
	content.event_definitions={}; content.event_card_instances={}
	if ev.ok:
		for row: Dictionary in ev.definitions: content.event_definitions[str(row.id)]=row
		for row: Dictionary in ev.instances: content.event_card_instances[str(row.id)]=row
	else: content.load_errors.append_array(ev.errors)
	content.ruleset.expected_counts={}
	for key: String in ["goods","nations","cities","city_cards","trade_decks","event_definitions","event_card_instances","illustrations","board_nodes","board_edges"]:
		content.ruleset.expected_counts[key]=content[key].size()
	content.ruleset.expected_counts.trade_cards=content.trade_card_index.size()
	return content

static func install(text: String) -> Dictionary:
	if text.to_utf8_buffer().size()>MAX_BYTES: return {"ok":false,"errors":["配置超过1MiB"]}
	var value: Variant = JSON.parse_string(text)
	if not value is Dictionary: return {"ok":false,"errors":["配置必须是JSON对象"]}
	var problem := errors(value)
	if not problem.is_empty(): return {"ok":false,"errors":problem}
	var candidate := apply(GameData.load_ruleset(GameData.FORMAL_RULESET_DIR),value)
	var valid := GameData.validate_content(candidate)
	if not valid.valid: return {"ok":false,"errors":valid.missing}
	DirAccess.make_dir_recursive_absolute(path().get_base_dir())
	var f := FileAccess.open(path()+".tmp",FileAccess.WRITE)
	if f==null: return {"ok":false,"errors":["无法保存规则配置"]}
	f.store_string(JSON.stringify(value,"  ")); f.flush(); var code:=f.get_error(); f.close()
	if code!=OK: return {"ok":false,"errors":["配置写入失败"]}
	if FileAccess.file_exists(path()): DirAccess.copy_absolute(path(),path()+".bak")
	if DirAccess.rename_absolute(path()+".tmp",path())!=OK: return {"ok":false,"errors":["配置替换失败"]}
	GameData._formal_cache={}; CustomMapLoader._base_cache={}; CustomMapTradegenRegistry.clear_cache()
	return {"ok":true,"errors":[]}

static func copy_to(directory: String) -> bool:
	return FileAccess.file_exists(path()) and DirAccess.copy_absolute(path(),directory.path_join(FILE))==OK
