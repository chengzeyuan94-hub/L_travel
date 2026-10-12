class_name ExpansionLoader

## 扩展包加载器（extensions.md §2 第 2 条、趣味事件设计 §3.1）。
## 做法：正式十六城会话里，基础包 lshu_configurable_v1 先照旧过 GameData.validate_content，然后把
## data/expansions/<id>/ 里的事件卡并进陆、海两堆。不改基础包任何文件，也不另立 ruleset_id——合并后的
## content 仍是 lshu_configurable_v1，正式棋盘契约、卡面短文、地图表现这些按 ruleset_id 开关的东西全部照旧。
## 扩展包用自己的门禁（validate_package）：包里的 allowed_ops 白名单、每个 op 的参数、插画归属、卡面释义字数、
## 张数、音效名，全部在合并前查完；有一项不对就不开局，绝不带着半个扩展包开局。
##
## 选项（options）只有一种形状，空字典 = 原版：
##   {"lshu_fun_events": {"enabled": true, "modules": {"sound_quiz": false}}}
## 合并后的 content 多出这几个键（基础包 content 本身不动）：
##   expansion_options       规范化后的选项（存档、「再来一局」、设置页改座位时据此原样重建）
##   expansion_base_content  合并前的基础包 content（SetupSystem 重新准备时用它过基础门禁）
##   expansions_active       {包 id: {version, title, modules, instance_ids_by_deck}}
##   expansion_presentation  {包 id: {pool_id: 表现数据}}（篝火问题池、听声题库）
## 开局时 SetupSystem 先按原版洗牌、发城市卡（随机数消耗和原版一模一样，所以开关不影响谁从哪座城出发），
## 最后调 merge_into_event_decks 把扩展卡加进两堆抽牌堆、再用规则随机数整堆洗一次。

const EXPANSIONS_DIR := "res://data/expansions"
const FUN_EVENTS_ID := "lshu_fun_events"
const SOUND_QUIZ_MODULE := "sound_quiz"
## 第二批备选池：数据和规则都已就绪，但设置页和开局选项打不开（normalize_options 丢掉它），只有测试传 allow_backlog 才并进来
const BACKLOG_MODULE := "backlog"
## 自制地图（docs/design/map-editor-20260930/DESIGN.md 3.6）也走这一条：选项只有 {enabled: true, sha256}，覆盖层本身由
## CustomMapLoader 按 sha 登记在缓存里；追加在趣味事件之后，这样趣味事件在选项字典里的顺序不变
const CUSTOM_MAP_ID := "lshu_custom_map"
const KNOWN_EXPANSIONS: Array[String] = [FUN_EVENTS_ID, CUSTOM_MAP_ID]
const SCHEMA_VERSION := 1
const DECK_TYPES: Array[String] = ["LAND", "SEA"]
const SENTIMENTS: Array[String] = ["POSITIVE", "NEGATIVE", "NEUTRAL"]
## 会让抽牌人丢东西的 op：卡面必须是 NEGATIVE，NEGATIVE 的卡也必须带其中一个（扩展门禁强制 sentiment 和 op 类别一致）
const LOSS_OPS: Array[String] = ["LOSE_GOOD", "LOSE_HALF_GOODS_MAX_2", "LOSE_HALF_SILVER_MAX_5", "PAY_OR_DROP"]
## 扩展卡的 card_number 从这里起（原版每堆 1–18），避开原版编号
const MIN_CARD_NUMBER := 100

static var _package_cache: Dictionary = {}


# ---------------------------------------------------------------- 选项

## 设置页 / 测试用的选项构造器
static func fun_events_options(enabled: bool, sound_quiz: bool = false) -> Dictionary:
	if not enabled:
		return {}
	return {FUN_EVENTS_ID: {"enabled": true, "modules": {SOUND_QUIZ_MODULE: sound_quiz}}}


## 规范化：只留已知包、只留 enabled=true 的包；子开关只认包里声明过的模块，缺省为关。空字典 = 原版。
## allow_backlog 只给测试用：把第二批备选池也并进内容（游戏里的开局、设置页、存档都不传，永远打不开）。
static func normalize_options(raw: Variant, allow_backlog: bool = false) -> Dictionary:
	var out := {}
	if not (raw is Dictionary):
		return out
	for expansion_id in KNOWN_EXPANSIONS:
		var entry: Variant = (raw as Dictionary).get(expansion_id)
		if not (entry is Dictionary) or not bool((entry as Dictionary).get("enabled", false)):
			continue
		if expansion_id == CUSTOM_MAP_ID:
			# 自制地图只保留 {enabled: true, sha256: <64 位十六进制>}；sha 不像样就当没选
			var sha := String((entry as Dictionary).get("sha256", ""))
			if sha.length() == 64 and sha.is_valid_hex_number():
				out[expansion_id] = {"enabled": true, "sha256": sha.to_lower()}
			continue
		var modules := {}
		var raw_modules: Variant = (entry as Dictionary).get("modules", {})
		if expansion_id == FUN_EVENTS_ID:
			modules[SOUND_QUIZ_MODULE] = raw_modules is Dictionary and bool((raw_modules as Dictionary).get(SOUND_QUIZ_MODULE, false))
			if allow_backlog and raw_modules is Dictionary and bool((raw_modules as Dictionary).get(BACKLOG_MODULE, false)):
				modules[BACKLOG_MODULE] = true
		out[expansion_id] = {"enabled": true, "modules": modules}
	return out


static func is_any_enabled(options: Variant) -> bool:
	return not normalize_options(options).is_empty()


## 这一局 content 用的是哪些扩展（原版 content 返回空字典）
static func options_of(content: Dictionary) -> Dictionary:
	var raw: Variant = content.get("expansion_options", {})
	return (raw as Dictionary).duplicate(true) if raw is Dictionary else {}


## 合并前的基础包 content（原版 content 原样返回）
static func base_content_of(content: Dictionary) -> Dictionary:
	var base: Variant = content.get("expansion_base_content")
	return base if base is Dictionary and not (base as Dictionary).is_empty() else content


static func is_fun_events_active(content: Dictionary) -> bool:
	return (content.get("expansions_active", {}) as Dictionary).has(FUN_EVENTS_ID)


static func is_module_active(content: Dictionary, module_id: String) -> bool:
	var active: Dictionary = content.get("expansions_active", {}).get(FUN_EVENTS_ID, {})
	return module_id in active.get("modules", [])


## 扩展包表现数据（篝火问题池、听声题库）
static func presentation(content: Dictionary, pool_id: String, expansion_id: String = FUN_EVENTS_ID) -> Dictionary:
	var pools: Dictionary = content.get("expansion_presentation", {}).get(expansion_id, {})
	var pool: Variant = pools.get(pool_id, {})
	return pool if pool is Dictionary else {}


# ---------------------------------------------------------------- 读包

## 读一个扩展包（带缓存；只读，调用方不得修改返回值）。返回 {id, dir, manifest, sets: {"" : 主包, 模块 id: 模块}, load_errors}
static func load_package(expansion_id: String) -> Dictionary:
	if _package_cache.has(expansion_id):
		return _package_cache[expansion_id]
	var errors: Array[String] = []
	var dir := EXPANSIONS_DIR.path_join(expansion_id)
	var manifest := _read_json(dir.path_join("manifest.json"), errors)
	var package := {"id": expansion_id, "dir": dir, "manifest": manifest, "sets": {}, "load_errors": errors}
	if manifest.is_empty():
		errors.append("扩展包 %s 缺少 manifest.json" % expansion_id)
		_package_cache[expansion_id] = package
		return package
	package["sets"][""] = _load_set(dir, manifest.get("files", {}), manifest.get("expected_counts", {}), "", errors)
	var modules: Variant = manifest.get("modules", {})
	if modules is Dictionary:
		for module_id in (modules as Dictionary).keys():
			var module: Dictionary = modules[module_id]
			var module_dir := dir.path_join(String(module.get("dir", module_id)))
			package["sets"][String(module_id)] = _load_set(
				module_dir, module.get("files", {}), module.get("expected_counts", {}), String(module_id), errors,
				module.get("extra_allowed_ops", [])
			)
	_package_cache[expansion_id] = package
	return package


static func _load_set(dir: String, files: Dictionary, expected: Dictionary, module_id: String, errors: Array[String], extra_ops: Array = []) -> Dictionary:
	var out := {
		"module_id": module_id,
		"dir": dir,
		"expected_counts": expected,
		"extra_allowed_ops": extra_ops.duplicate(),
		"definitions": _read_json(dir.path_join(String(files.get("event_definitions", "event_definitions.json"))), errors),
		"instances": _read_json(dir.path_join(String(files.get("event_card_instances", "event_card_instances.json"))), errors),
		"illustrations": _read_json(dir.path_join(String(files.get("illustration_manifest", "illustration_manifest.json"))), errors),
		"card_text": _read_json(dir.path_join(String(files.get("card_text", "card_text.json"))), errors),
		"presentation": {},
	}
	var pres: Variant = files.get("presentation", {})
	if pres is Dictionary:
		for pool_id in (pres as Dictionary).keys():
			out["presentation"][String(pool_id)] = _read_json(dir.path_join(String(pres[pool_id])), errors)
	return out


## 清掉读包缓存（测试改了数据文件后用）
static func clear_cache() -> void:
	_package_cache.clear()


# ---------------------------------------------------------------- 合并

## 按选项把扩展包并进基础包。返回 {success, content, message, missing}。
## options 为空时原样返回 base_content（同一个对象，原版一字不差）。allow_backlog 只给测试用（见 normalize_options）。
static func apply(base_content: Dictionary, options: Variant, allow_backlog: bool = false) -> Dictionary:
	var opts := normalize_options(options, allow_backlog)
	if opts.is_empty():
		return {"success": true, "content": base_content, "message": "", "missing": []}
	var base := base_content_of(base_content)
	var merged := base.duplicate(false)
	merged["event_definitions"] = (base.get("event_definitions", {}) as Dictionary).duplicate(false)
	merged["event_card_instances"] = (base.get("event_card_instances", {}) as Dictionary).duplicate(false)
	merged["illustrations"] = (base.get("illustrations", {}) as Dictionary).duplicate(false)
	merged["card_text_events"] = (base.get("card_text_events", {}) as Dictionary).duplicate(false)
	var active := {}
	var presentation_by_pkg := {}
	var missing: Array[String] = []
	for expansion_id in opts.keys():
		if expansion_id == CUSTOM_MAP_ID:
			continue
		var package := load_package(String(expansion_id))
		var check := validate_package(base, package, opts[expansion_id])
		if not bool(check.get("valid", false)):
			missing.append_array(check.get("missing", []))
			continue
		var set_ids: Array[String] = [""]
		for module_id in (opts[expansion_id].get("modules", {}) as Dictionary).keys():
			if bool(opts[expansion_id]["modules"][module_id]):
				set_ids.append(String(module_id))
		var ids_by_deck := {"LAND": [], "SEA": []}
		var pools := {}
		for set_id in set_ids:
			var s: Dictionary = package["sets"][set_id]
			for d in s["definitions"].get("items", []):
				merged["event_definitions"][String(d["id"])] = d
			for inst in s["instances"].get("items", []):
				merged["event_card_instances"][String(inst["id"])] = inst
				ids_by_deck[String(inst["deck_type"])].append(String(inst["id"]))
			for ill in s["illustrations"].get("items", []):
				merged["illustrations"][String(ill["id"])] = ill
			for t in s["card_text"].get("events", []):
				merged["card_text_events"][String(t["id"])] = t
			for pool_id in (s["presentation"] as Dictionary).keys():
				pools[pool_id] = s["presentation"][pool_id]
		for deck in ids_by_deck:
			(ids_by_deck[deck] as Array).sort()
		var modules_on: Array[String] = []
		for set_id in set_ids:
			if set_id != "":
				modules_on.append(set_id)
		active[expansion_id] = {
			"version": String(package["manifest"].get("version", "")),
			"title": String(package["manifest"].get("title", "")),
			"modules": modules_on,
			"instance_ids_by_deck": ids_by_deck,
		}
		presentation_by_pkg[expansion_id] = pools
	if not missing.is_empty():
		return {
			"success": false,
			"content": base,
			"message": "扩展包不完整：%s" % "; ".join(missing),
			"missing": missing,
		}
	# 自制地图排在趣味事件之后合并（从 CustomMapLoader 的缓存取覆盖层）；失败就整体失败，由调用方按 R4 退回原版
	if opts.has(CUSTOM_MAP_ID):
		var map_merge := CustomMapLoader.merge(merged, base, opts[CUSTOM_MAP_ID])
		if not bool(map_merge.get("success", false)):
			return {"success": false, "content": base, "message": String(map_merge.get("message", "自制地图合并失败。")), "missing": []}
	merged["expansion_options"] = opts
	merged["expansion_base_content"] = base
	merged["expansions_active"] = active
	merged["expansion_presentation"] = presentation_by_pkg
	return {"success": true, "content": merged, "message": "", "missing": []}


## 开局时把扩展卡加进两堆抽牌堆，再用规则随机数整堆洗一次（先洗好的原版牌堆再洗一遍仍是均匀的）。
## 必须在原版洗牌、发城市卡之后调用：这样开关不改变原版那几步的随机数消耗，谁从哪座城出发不受开关影响。
static func merge_into_event_decks(content: Dictionary) -> void:
	var active: Dictionary = content.get("expansions_active", {})
	for expansion_id in active.keys():
		var by_deck: Dictionary = active[expansion_id].get("instance_ids_by_deck", {})
		for deck_name in DECK_TYPES:
			var deck_type := GameData.DeckType.LAND if deck_name == "LAND" else GameData.DeckType.SEA
			var ids: Array = by_deck.get(deck_name, [])
			if ids.is_empty():
				continue
			var deck_state: Dictionary = GameState.event_decks_state[deck_type]
			var draw: Array = deck_state["draw"]
			draw.append_array(ids)
			GameState.rng_shuffle(draw)


# ---------------------------------------------------------------- 门禁

## 扩展包门禁。options 是这个包自己的那一段（{"enabled", "modules"}）；只查会被合并的主包和打开的模块。
static func validate_package(base_content: Dictionary, package: Dictionary, options: Dictionary = {}) -> Dictionary:
	var missing: Array[String] = []
	missing.append_array(package.get("load_errors", []))
	var expansion_id := String(package.get("id", ""))
	var manifest: Dictionary = package.get("manifest", {})
	if manifest.is_empty():
		return {"valid": false, "missing": missing if not missing.is_empty() else ["扩展包 %s 缺少清单" % expansion_id]}
	var ruleset: Dictionary = base_content.get("ruleset", {})
	if String(manifest.get("expansion_id", "")) != expansion_id:
		missing.append("扩展包清单 expansion_id 与目录不一致：%s" % expansion_id)
	if int(manifest.get("schema_version", -1)) != SCHEMA_VERSION:
		missing.append("扩展包 %s schema_version 不是 %d" % [expansion_id, SCHEMA_VERSION])
	if String(manifest.get("base_ruleset_id", "")) != String(ruleset.get("ruleset_id", "")):
		missing.append("扩展包 %s 只能叠加在 %s 上，当前基础包是 %s" % [
			expansion_id, String(manifest.get("base_ruleset_id", "")), String(ruleset.get("ruleset_id", ""))])
	if String(manifest.get("base_edition_id", "")) != String(ruleset.get("edition_id", "")):
		missing.append("扩展包 %s 的 base_edition_id 与基础包不一致" % expansion_id)
	var allowed_ops: Array = manifest.get("allowed_ops", [])
	var declared_ops: Array = allowed_ops.duplicate()
	for module in (manifest.get("modules", {}) as Dictionary).values():
		declared_ops.append_array((module as Dictionary).get("extra_allowed_ops", []))
	for op in declared_ops:
		if String(op) not in GameData.KNOWN_EVENT_OPS and String(op) not in FunEventOps.SUPPORTED_OPS:
			missing.append("扩展包 %s 白名单里的 op 没有实现：%s" % [expansion_id, String(op)])
	var sfx_names: Array = manifest.get("sfx_names", [])
	var sets: Dictionary = package.get("sets", {})
	var set_ids: Array[String] = [""]
	var module_opts: Dictionary = options.get("modules", {})
	for module_id in module_opts.keys():
		if bool(module_opts[module_id]):
			if not sets.has(String(module_id)):
				missing.append("扩展包 %s 没有模块 %s" % [expansion_id, String(module_id)])
			else:
				set_ids.append(String(module_id))
	var seen_defs := {}
	var seen_instances := {}
	var seen_ills := {}
	var seen_numbers := {}
	for set_id in set_ids:
		if not sets.has(set_id):
			missing.append("扩展包 %s 缺少主包数据" % expansion_id)
			continue
		# 每个模块的白名单 = 主包白名单 + 模块自己声明的 extra_allowed_ops（首批白名单不认第二批的 op）
		var set_ops: Array = allowed_ops + (sets[set_id].get("extra_allowed_ops", []) as Array)
		_validate_set(base_content, expansion_id, sets[set_id], set_ops, sfx_names, seen_defs, seen_instances, seen_ills, seen_numbers, missing)
	# 每堆新卡封顶（第二批换入时相应换下首批，不往上叠）；子开关模块另算（Carlos 2026-09-27：耳听八方单独一个子开关）
	var cap := int(manifest.get("max_new_cards_per_deck", 0))
	if cap > 0 and sets.has(""):
		var main_by_deck := {"LAND": 0, "SEA": 0}
		for inst in sets[""]["instances"].get("items", []):
			var deck := String(inst.get("deck_type", ""))
			if main_by_deck.has(deck):
				main_by_deck[deck] += 1
		for deck in main_by_deck:
			if int(main_by_deck[deck]) > cap:
				missing.append("扩展包 %s %s 堆新卡 %d 张，超过封顶 %d 张" % [expansion_id, deck, int(main_by_deck[deck]), cap])
	return {"valid": missing.is_empty(), "missing": missing}


static func _validate_set(
	base_content: Dictionary, expansion_id: String, s: Dictionary, allowed_ops: Array, sfx_names: Array,
	seen_defs: Dictionary, seen_instances: Dictionary, seen_ills: Dictionary, seen_numbers: Dictionary,
	missing: Array[String]
) -> void:
	var module_id := String(s.get("module_id", ""))
	var label := expansion_id if module_id.is_empty() else "%s/%s" % [expansion_id, module_id]
	for doc_name in ["definitions", "instances", "illustrations", "card_text"]:
		var doc: Dictionary = s.get(doc_name, {})
		if doc.is_empty():
			missing.append("扩展包 %s 缺少 %s" % [label, doc_name])
			continue
		if String(doc.get("expansion_id", "")) != expansion_id or int(doc.get("schema_version", -1)) != SCHEMA_VERSION:
			missing.append("扩展包 %s 的 %s 身份头不一致" % [label, doc_name])
	var base_defs: Dictionary = base_content.get("event_definitions", {})
	var base_instances: Dictionary = base_content.get("event_card_instances", {})
	var base_ills: Dictionary = base_content.get("illustrations", {})
	var pools: Dictionary = s.get("presentation", {})
	var defs := {}
	var kinds := {}
	var by_deck := {"LAND": 0, "SEA": 0}
	for d in s.get("definitions", {}).get("items", []):
		var event_id := String(d.get("id", ""))
		if event_id.is_empty():
			missing.append("扩展包 %s 有空 id 的事件定义" % label)
			continue
		if seen_defs.has(event_id) or base_defs.has(event_id):
			missing.append("扩展事件 id 重复或与原版冲突：%s" % event_id)
		seen_defs[event_id] = true
		defs[event_id] = d
		if String(d.get("expansion_id", "")) != expansion_id:
			missing.append("扩展事件 %s 的 expansion_id 不对" % event_id)
		if String(d.get("module_id", "")) != module_id:
			missing.append("扩展事件 %s 的 module_id 应为「%s」" % [event_id, module_id])
		var deck := String(d.get("deck_type", ""))
		if deck not in DECK_TYPES:
			missing.append("扩展事件 %s 的牌堆无效：%s" % [event_id, deck])
		var number := int(d.get("card_number", 0))
		if number <= MIN_CARD_NUMBER:
			missing.append("扩展事件 %s 的 card_number 必须大于 %d" % [event_id, MIN_CARD_NUMBER])
		var number_key := "%s|%d" % [deck, number]
		if seen_numbers.has(number_key):
			missing.append("扩展事件 %s 的 card_number 与 %s 重复" % [event_id, String(seen_numbers[number_key])])
		seen_numbers[number_key] = event_id
		if String(d.get("title", "")).strip_edges().is_empty() or String(d.get("original_effect_text", "")).strip_edges().is_empty():
			missing.append("扩展事件 %s 缺少标题或卡面效果句" % event_id)
		kinds[String(d.get("kind_id", event_id))] = true
		var sentiment := String(d.get("sentiment", ""))
		if sentiment not in SENTIMENTS:
			missing.append("扩展事件 %s 的 sentiment 无效：%s" % [event_id, sentiment])
		if String(d.get("failure_policy", "NONE")) == "RULE_BLOCKED":
			missing.append("扩展事件 %s 仍是 RULE_BLOCKED" % event_id)
		var effects: Array = d.get("effects", [])
		if effects.is_empty():
			missing.append("扩展事件 %s 没有效果" % event_id)
		var has_loss := false
		for effect in effects:
			var op := String(effect.get("op", ""))
			if op not in allowed_ops:
				missing.append("扩展事件 %s 用了白名单外的 op：%s" % [event_id, op])
				continue
			if op in LOSS_OPS:
				has_loss = true
			for problem in _check_effect(effect, base_content, pools, false):
				missing.append("扩展事件 %s 的 %s：%s" % [event_id, op, problem])
		if has_loss and sentiment != "NEGATIVE":
			missing.append("扩展事件 %s 会让人丢东西，sentiment 必须是 NEGATIVE" % event_id)
		if sentiment == "NEGATIVE" and not has_loss:
			missing.append("扩展事件 %s 标了 NEGATIVE 却没有损失效果" % event_id)
		for key in ["sfx", "sfx_bed"]:
			if d.has(key) and String(d[key]) not in sfx_names:
				missing.append("扩展事件 %s 的 %s 不在音效名单里：%s" % [event_id, key, String(d[key])])
		var cues: Variant = d.get("sfx_cues", {})
		if cues is Dictionary:
			for cue in (cues as Dictionary).keys():
				if String(cues[cue]) not in sfx_names:
					missing.append("扩展事件 %s 的 sfx_cues.%s 不在音效名单里" % [event_id, String(cue)])
		else:
			missing.append("扩展事件 %s 的 sfx_cues 必须是字典" % event_id)
		if d.has("presentation_fx") and String(d["presentation_fx"]) not in ["group_photo"]:
			missing.append("扩展事件 %s 的 presentation_fx 未知：%s" % [event_id, String(d["presentation_fx"])])
	# 实例
	for inst in s.get("instances", {}).get("items", []):
		var inst_id := String(inst.get("id", ""))
		if inst_id.is_empty() or seen_instances.has(inst_id) or base_instances.has(inst_id):
			missing.append("扩展事件卡实例 id 为空、重复或与原版冲突：%s" % inst_id)
		seen_instances[inst_id] = true
		var event_id := String(inst.get("event_id", ""))
		if not defs.has(event_id):
			missing.append("扩展事件卡实例 %s 引用的事件不在本包：%s" % [inst_id, event_id])
			continue
		var d: Dictionary = defs[event_id]
		if String(inst.get("deck_type", "")) != String(d.get("deck_type", "")) or int(inst.get("card_number", -1)) != int(d.get("card_number", -2)):
			missing.append("扩展事件卡实例 %s 与模板牌堆或编号不一致" % inst_id)
		var deck := String(inst.get("deck_type", ""))
		if by_deck.has(deck):
			by_deck[deck] += 1
	# 插画：每条定义一个条目，归属字段与该定义一致（卡面解析 FormalCardPresentationResolver 的要求）
	var ill_by_owner := {}
	for ill in s.get("illustrations", {}).get("items", []):
		var ill_id := String(ill.get("id", ""))
		if ill_id.is_empty() or seen_ills.has(ill_id) or base_ills.has(ill_id):
			missing.append("扩展插画 id 为空、重复或与原版冲突：%s" % ill_id)
		seen_ills[ill_id] = true
		var owner := String(ill.get("formal_owner_id", ""))
		if String(ill.get("entity_type", "")) != "EVENT" or String(ill.get("entity_id", "")) != owner or not defs.has(owner):
			missing.append("扩展插画 %s 的归属无效" % ill_id)
			continue
		if ill_by_owner.has(owner):
			missing.append("扩展事件 %s 登记了多个插画条目" % owner)
		ill_by_owner[owner] = ill
		var d: Dictionary = defs[owner]
		if String(ill.get("deck_type", "")) != String(d.get("deck_type", "")) or int(ill.get("card_number", -1)) != int(d.get("card_number", -2)):
			missing.append("扩展插画 %s 的牌堆或编号与事件不一致" % ill_id)
		var path := String(ill.get("runtime_path", ""))
		if path.is_empty() or not ResourceLoader.exists(path):
			missing.append("扩展插画 %s 缺少运行时资源：%s" % [ill_id, path])
	for event_id in defs.keys():
		var ill_id := String(defs[event_id].get("illustration_id", ""))
		if not ill_by_owner.has(event_id) or String(ill_by_owner[event_id].get("id", "")) != ill_id:
			missing.append("扩展事件 %s 的 illustration_id 没有对应的插画条目" % event_id)
	# 卡面释义（并进 card_text_events，卡面才读得到）
	var texts := {}
	for t in s.get("card_text", {}).get("events", []):
		var event_id := String(t.get("id", ""))
		if not defs.has(event_id):
			missing.append("扩展释义含未知事件：%s" % event_id)
			continue
		texts[event_id] = true
		var explain := String(t.get("explain", "")).strip_edges()
		var r: Vector2i = GameData.CARD_TEXT_EXPLAIN_RANGE
		if explain.length() < r.x or explain.length() > r.y:
			missing.append("扩展释义 %s 长度 %d 超出 %d–%d" % [event_id, explain.length(), r.x, r.y])
	for event_id in defs.keys():
		if not texts.has(event_id):
			missing.append("扩展事件 %s 缺少卡面释义" % event_id)
	# 张数
	var expected: Dictionary = s.get("expected_counts", {})
	var counts := {
		"event_definitions": defs.size(),
		"event_card_instances": (s.get("instances", {}).get("items", []) as Array).size(),
		"illustrations": ill_by_owner.size(),
		"card_text_events": texts.size(),
		"kinds": kinds.size(),
	}
	for key in counts.keys():
		if expected.has(key) and int(expected[key]) != int(counts[key]):
			missing.append("扩展包 %s %s：%d/%d" % [label, key, int(counts[key]), int(expected[key])])
	var expected_by_deck: Dictionary = expected.get("new_cards_by_deck", {})
	for deck in expected_by_deck.keys():
		if int(by_deck.get(deck, 0)) != int(expected_by_deck[deck]):
			missing.append("扩展包 %s %s 堆：%d/%d 张" % [label, String(deck), int(by_deck.get(deck, 0)), int(expected_by_deck[deck])])


## 单条效果的参数门禁。返回问题列表（空 = 通过）。sub=true 表示子效果（奖品 / 赛骰奖励），只允许不需要再选的 op。
static func _check_effect(effect: Dictionary, base: Dictionary, pools: Dictionary, sub: bool) -> Array[String]:
	var problems: Array[String] = []
	var goods: Dictionary = base.get("goods", {})
	var op := String(effect.get("op", ""))
	match op:
		"MOVE_BY_RANGE":
			var lo := int(effect.get("min_steps", -1))
			var hi := int(effect.get("max_steps", -1))
			if lo != 0 or hi < 0 or hi > 6:
				problems.append("步数必须是 0–N（N ≤ 6）")
		"LOSE_GOOD":
			if sub:
				problems.append("子效果不能丢货")
			if int(effect.get("quantity", 0)) < 1:
				problems.append("quantity 必须 ≥ 1")
			if String(effect.get("selection_policy", "")) != "PLAYER_CHOICE":
				problems.append("selection_policy 必须是 PLAYER_CHOICE")
			if effect.has("good_filter"):
				var filter: Variant = effect.get("good_filter")
				if not (filter is Array) or (filter as Array).is_empty():
					problems.append("good_filter 必须是非空列表")
				else:
					for good_id in filter:
						if not goods.has(String(good_id)):
							problems.append("good_filter 含未知商品：%s" % String(good_id))
				var fb := int(effect.get("fallback_max_steps", -1))
				if fb < 0 or fb > 6:
					problems.append("fallback_max_steps 必须在 0–6")
				var texts: Variant = effect.get("filter_texts", {})
				if not (texts is Dictionary):
					problems.append("filter_texts 必须是字典")
			elif effect.has("fallback_max_steps") or effect.has("filter_texts"):
				problems.append("fallback_max_steps / filter_texts 只能和 good_filter 一起用")
		"GAIN_STARTING_RESOURCE":
			if int(effect.get("quantity", 0)) != 1:
				problems.append("quantity 必须是 1")
		"GAIN_SILVER":
			var amount := int(effect.get("amount", 0))
			if amount < 1 or amount > 5:
				problems.append("amount 必须在 1–5")
			var targets := String(effect.get("targets", "SELF"))
			if targets not in ["SELF", "ALL_PLAYERS"] or (sub and targets != "SELF"):
				problems.append("targets 无效：%s" % targets)
		"PAY_SILVER":
			var amount := int(effect.get("amount", 0))
			if amount < 1 or amount > 5:
				problems.append("amount 必须在 1–5")
		"GIFT_STARTING_RESOURCE":
			if sub:
				problems.append("不能作子效果")
			var targets: Variant = effect.get("targets", [])
			if not (targets is Array) or (targets as Array).is_empty():
				problems.append("targets 必须是非空列表")
			else:
				for t in targets:
					if String(t) not in ["SELF", "NEXT_SEAT"]:
						problems.append("targets 只能是 SELF / NEXT_SEAT（不点名）：%s" % String(t))
			if int(effect.get("quantity", 0)) != 1:
				problems.append("quantity 必须是 1")
			var fb := int(effect.get("fallback_silver", -1))
			if fb < 0 or fb > 5:
				problems.append("fallback_silver 必须在 0–5")
		"DICE_RACE":
			if sub:
				problems.append("不能作子效果")
			var prizes: Variant = effect.get("prize_effects", [])
			if not (prizes is Array) or (prizes as Array).is_empty():
				problems.append("prize_effects 必须是非空列表")
			else:
				for p in prizes:
					if not (p is Dictionary) or String(p.get("op", "")) != "GAIN_SILVER":
						problems.append("prize_effects 只能是 GAIN_SILVER")
					else:
						problems.append_array(_check_effect(p, base, pools, true))
			var face := int(effect.get("event_face_value", -1))
			if face < 0 or face > 5:
				problems.append("event_face_value 必须在 0–5")
		"RANDOM_PRIZE":
			if sub:
				problems.append("不能作子效果")
			var prizes: Variant = effect.get("prizes", [])
			var ceremony := String(effect.get("ceremony", ""))
			var sizes := {"two_fists": 2, "three_postcards": 3}
			if not sizes.has(ceremony):
				problems.append("ceremony 无效：%s" % ceremony)
			if not (prizes is Array) or (sizes.has(ceremony) and (prizes as Array).size() != int(sizes[ceremony])):
				problems.append("prizes 的个数要和揭晓仪式一致")
			elif prizes is Array:
				for prize in prizes:
					if not (prize is Array):
						problems.append("每个奖品必须是效果列表")
						continue
					for p in prize:
						if not (p is Dictionary) or String(p.get("op", "")) not in ["GAIN_SILVER", "PAY_SILVER", "MOVE_BY_RANGE"]:
							problems.append("奖品只能是 GAIN_SILVER / PAY_SILVER / MOVE_BY_RANGE")
						else:
							problems.append_array(_check_effect(p, base, pools, true))
			var labels: Variant = effect.get("prize_labels", [])
			if labels is Array and not (labels as Array).is_empty() and prizes is Array and (labels as Array).size() != (prizes as Array).size():
				problems.append("prize_labels 的个数要和 prizes 一致")
		"FLAVOR_PROMPT":
			if sub:
				problems.append("不能作子效果")
			var pool_id := String(effect.get("prompt_pool_id", ""))
			var pool: Dictionary = pools.get(pool_id, {})
			if pool.is_empty() or (pool.get("prompts", []) as Array).is_empty():
				problems.append("问题池缺失或为空：%s" % pool_id)
			elif (pool.get("ai_reply_templates", []) as Array).is_empty():
				problems.append("问题池缺少电脑台词：%s" % pool_id)
			if String(effect.get("dismiss", "")) != "TAP_OR_NEXT_HUMAN_TURN_END":
				problems.append("dismiss 只能是 TAP_OR_NEXT_HUMAN_TURN_END（不设倒计时）")
		"GAIN_LOCAL_SPECIALTY":
			if sub:
				problems.append("不能作子效果")
			if int(effect.get("quantity", 0)) != 1:
				problems.append("quantity 必须是 1")
			var fb := int(effect.get("fallback_max_steps", -1))
			if fb < 0 or fb > 6:
				problems.append("fallback_max_steps 必须在 0–6")
		"PAY_OR_DROP":
			if sub:
				problems.append("不能作子效果")
			var pay := int(effect.get("pay_silver", 0))
			var drop := int(effect.get("drop_goods", 0))
			if pay < 1 or pay > 5 or drop < 1 or drop > 2:
				problems.append("pay_silver 必须在 1–5、drop_goods 必须在 1–2")
			if String(effect.get("pay_label", "")).strip_edges().is_empty():
				problems.append("缺少付银选项的文字 pay_label")
		"SOUND_QUIZ":
			if sub:
				problems.append("不能作子效果")
			var pool_id := String(effect.get("sound_pool_id", ""))
			var sounds: Array = pools.get(pool_id, {}).get("sounds", [])
			var ids := {}
			for snd in sounds:
				ids[String(snd.get("id", ""))] = true
			var count := int(effect.get("option_count", 0))
			if count < 2 or count > 4:
				problems.append("option_count 必须在 2–4")
			if sounds.size() < count + 1:
				problems.append("题库太小：%s" % pool_id)
			for key in ["correct_max_steps", "wrong_max_steps", "muted_max_steps"]:
				var v := int(effect.get(key, -1))
				if v < 0 or v > 6:
					problems.append("%s 必须在 0–6" % key)
			for pair in effect.get("exclusive_pairs", []):
				if not (pair is Array) or (pair as Array).size() != 2 or not ids.has(String(pair[0])) or not ids.has(String(pair[1])):
					problems.append("exclusive_pairs 必须是题库里的两两一组")
		# ---- 第二批（备选池）----
		"CHOOSE_ONE":
			if sub:
				problems.append("不能作子效果")
			var options: Variant = effect.get("options", [])
			if not (options is Array) or (options as Array).size() < 2:
				problems.append("options 至少两项")
			else:
				var ids := {}
				for o in options:
					if not (o is Dictionary) or String(o.get("id", "")).is_empty() or String(o.get("label", "")).strip_edges().is_empty():
						problems.append("每个选项要有 id 和 label")
						continue
					if ids.has(String(o["id"])):
						problems.append("选项 id 重复：%s" % String(o["id"]))
					ids[String(o["id"])] = true
					var sub_effects: Variant = o.get("effects", [])
					if not (sub_effects is Array) or (sub_effects as Array).is_empty():
						problems.append("选项 %s 没有效果" % String(o["id"]))
						continue
					for p in sub_effects:
						if not (p is Dictionary) or String(p.get("op", "")) not in ["MOVE_BY_RANGE", "GAIN_STARTING_RESOURCE", "DICE_CHANCE", "GAIN_SILVER"]:
							problems.append("选项里只能放不需要再选的 op（走步、领起始物资、再掷骰、得银）")
						else:
							problems.append_array(_check_effect(p, base, pools, true))
			if String(effect.get("ai_rule", "")) not in FunEventOps.CHOOSE_ONE_AI_RULES:
				problems.append("ai_rule 无效：%s" % String(effect.get("ai_rule", "")))
		"DICE_CHANCE":
			var faces: Variant = effect.get("win_faces", [])
			if not (faces is Array) or (faces as Array).is_empty():
				problems.append("win_faces 必须是非空列表")
			else:
				for f in faces:
					if int(f) < 1 or int(f) > 5:
						problems.append("win_faces 只能是 1–5")
			for key in ["win_effects", "lose_effects"]:
				for p in effect.get(key, []):
					if not (p is Dictionary) or String(p.get("op", "")) != "GAIN_SILVER":
						problems.append("%s 只能是 GAIN_SILVER" % key)
					else:
						problems.append_array(_check_effect(p, base, pools, true))
		"HELP_LEAST":
			if sub:
				problems.append("不能作子效果")
			if String(effect.get("measure", "")) not in ["SILVER", "GOODS"]:
				problems.append("measure 只能是 SILVER / GOODS")
			var gift: Dictionary = effect.get("gift", {}) if effect.get("gift", {}) is Dictionary else {}
			match String(gift.get("kind", "")):
				"SILVER":
					if int(gift.get("amount", 0)) < 1 or int(gift.get("amount", 0)) > 5:
						problems.append("gift.amount 必须在 1–5")
				"STARTING_RESOURCE":
					if int(gift.get("fallback_silver", -1)) < 0 or int(gift.get("fallback_silver", -1)) > 5:
						problems.append("gift.fallback_silver 必须在 0–5")
				_:
					problems.append("gift.kind 只能是 SILVER / STARTING_RESOURCE")
			if String(effect.get("tie", "")) != "ALL_MAX_2_FROM_NEXT_SEAT":
				problems.append("tie 只能是 ALL_MAX_2_FROM_NEXT_SEAT（不点名）")
		"SWAP_RANDOM_GOOD":
			if sub:
				problems.append("不能作子效果")
			if String(effect.get("partner", "")) != "NEXT_SEAT" or String(effect.get("pick", "")) != "RANDOM_SLOT" or not bool(effect.get("void_if_either_empty", false)):
				problems.append("只能和下一位随机互换、任何一方没货就作废")
		"EXCHANGE_ONE_GOOD":
			if sub:
				problems.append("不能作子效果")
			if String(effect.get("target_scope", "ANY")) not in ["ANY", "SUPPLY_ONLY"]:
				problems.append("target_scope 只能是 ANY / SUPPLY_ONLY")
		"PEEK_EVENT_DECK":
			if sub:
				problems.append("不能作子效果")
		"GIFT_GOOD_TO_NEAREST":
			if sub:
				problems.append("不能作子效果")
			if not base.get("cities", {}).has(String(effect.get("city_id", ""))):
				problems.append("city_id 不存在：%s" % String(effect.get("city_id", "")))
			if not goods.has(String(effect.get("good_id", ""))):
				problems.append("good_id 不存在：%s" % String(effect.get("good_id", "")))
			if int(effect.get("quantity", 0)) != 1 or String(effect.get("tie", "")) != "ALL":
				problems.append("quantity 必须是 1、tie 必须是 ALL")
		"MEET_BONUS":
			if sub:
				problems.append("不能作子效果")
			if int(effect.get("silver_each", 0)) < 1 or int(effect.get("silver_each", 0)) > 5:
				problems.append("silver_each 必须在 1–5")
			if String(effect.get("scope", "")) != "SAME_OR_ADJACENT" or int(effect.get("min_moved_steps", 0)) < 1:
				problems.append("scope 只能是 SAME_OR_ADJACENT、min_moved_steps 至少 1")
		"GRANT_TOKEN":
			if sub:
				problems.append("不能作子效果")
			if String(effect.get("token_id", "")).is_empty() or int(effect.get("max_held", 0)) != 1:
				problems.append("token_id 不能为空、max_held 必须是 1")
			for blocked_op in effect.get("blocks_ops", []):
				if String(blocked_op) not in LOSS_OPS:
					problems.append("blocks_ops 只能是会丢东西的 op：%s" % String(blocked_op))
			if String(effect.get("consume", "")) != "ON_ACTUAL_LOSS":
				problems.append("consume 只能是 ON_ACTUAL_LOSS")
			var fb := int(effect.get("when_held_fallback_max_steps", -1))
			if fb < 0 or fb > 6:
				problems.append("when_held_fallback_max_steps 必须在 0–6")
		_:
			if op not in GameData.KNOWN_EVENT_OPS:
				problems.append("未知 op")
			elif sub:
				problems.append("不能作子效果")
	return problems


static func _read_json(path: String, errors: Array[String]) -> Dictionary:
	if not FileAccess.file_exists(path):
		errors.append("扩展包文件缺失：%s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		errors.append("扩展包文件不是 JSON 对象：%s" % path)
		return {}
	return parsed
