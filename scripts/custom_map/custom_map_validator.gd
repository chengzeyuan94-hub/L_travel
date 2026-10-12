class_name CustomMapValidator

## 自制地图的汇总校验，游戏和工坊共用（docs/design/map-editor-20260930/DESIGN.md 3.2、3.7、3.17、R4、R19、R29）。归 WP1。
## 全有或全无：有任何一项不合格，整张都不用（R4）。依次查：
##   ① 文件和版本（E_SCHEMA / E_TOO_NEW / E_BASE）——这一步不过就不往下查
##   ② CustomMapRules.check_topology（拓扑、东西成对、搭档、改原版）
##   ③ 名字（R29）、目录（原型 / 特产）、卡面文字（CustomMapCardText，WP6a）
##   ④ 几何（CustomMapGeoRules.check，WP3）
##   ⑤ 贸易卡：TradeGenV1.generate（WP2）重算，与文件里的 generated 逐字节比对（R19）
##   ⑥ 素材是否存在
##
## 其它工作包合入之前（5.1：WP2 / WP3 / WP6a），它们的函数还是 WP0 骨架，调了只会报「未实现」。按各包一定会带进来的
## 数据文件判断合没合入：没合入的一步不调骨架——几何跳过（桩返回空）；卡面文字用本文件的模板兜底；
## 生成器用 generator_stub（测试挂上 WP2 参考牌堆夹具，5.1），没有桩就按「游戏没有这个生成器版本」拒收（E_TOO_NEW）。

const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
## 各包合入的标志文件
const TRADEGEN_PARAMS := "res://data/custom_map/tradegen_v1_params.json"      # WP2
const HEIGHT_MAP := "res://assets/custom_map/terrain/board_height.res"          # WP3
const CATALOGUE_FILE := "res://data/custom_map/catalogue_v1.json"              # WP6a

## 只给测试用（WP2 合入前）：生成器桩，签名同 TradeGenV1.generate(base, topology, goods_map)
static var generator_stub: Callable = Callable()

## 孩子话（3.17）
const KID_FILE := "装进来的地图打不开（文件坏了），这局先用原版。请在地图工坊里重新点「导入地图」。"
const KID_TOO_NEW := "这张地图是新版工坊做的，游戏需要更新。"
const KID_BASE := "这张地图是给旧版游戏做的，请在工坊里打开检查一下。"
const KID_CATALOGUE := "找不到「%s」的样子，游戏需要更新。"
const KID_RULES := "地图不合规则（比如多连了一条路），请在工坊里打开看看。"
const KID_NAMES := "有座城的名字或介绍不对，请在工坊里打开看看。"
const KID_GEO := "地图里有城或路放错了地方，请在工坊里打开看看。"
const KID_CARDS := "贸易卡与规则版本不一致。回到「这张地图」点「规则与卡片恢复」，先预览，再创建新副本。"

const FILE_CODES: Array[String] = ["E_PARSE", "E_SCHEMA", "E_SHA"]
const VERSION_CODES: Array[String] = ["E_GENERATOR_PARAMS", "E_TOO_NEW", "E_BASE"]
const CATALOGUE_CODES: Array[String] = ["E_ARCHETYPE", "E_SPECIALTY", "E_ASSET_MISSING"]
const RULE_CODES: Array[String] = ["E_LEAF", "E_CORRIDOR", "E_BASE_GRAPH", "E_HOST", "E_INTERCHANGE", "E_SIDE", "E_USER_MAX",
	"E_PAIR_DIST", "E_PAIR_SYM", "E_ORIGINAL_EDIT"]
const NAME_CODES: Array[String] = ["E_NAME", "E_NAME_DUP", "E_SPECIALTY_DUP", "E_TEXT_LEN"]
const CARD_CODES: Array[String] = ["E_CARDS_MISMATCH", "E_CARDS_INVARIANT"]
## 几何错误码（3.11，WP3 实现）
const GEO_CODES: Array[String] = ["G_BOUNDS", "G_CITY_LAND", "G_COAST", "G_CITY_GAP", "G_CITY_ON_ROUTE", "G_PEAK", "G_SLOPE",
	"G_ROUTE_LAND", "G_ROUTE_SEA", "G_ROUTE_CROSS", "G_ROUTE_LEN", "G_STOP", "G_MOVE_FAR", "G_STAND", "G_DATA", "G_SIZE"]

## 城名（R29）：汉字最多 5 个；含字母或数字时最多 10 个字符，并且按圆体实测不宽于「君士坦丁堡」
const NAME_HAN_MAX := 5
const NAME_MIXED_MAX := 10
const NAME_WIDTH_REF := "君士坦丁堡"
const NAME_FONT_PX := 25
const MAP_NAME_MAX := 10
## 「自己写一句」（3.15）
const LINE_RANGE := Vector2i(4, 40)
const EPITHET_RANGE := Vector2i(8, 16)
## 小的不雅词表（城名和「自己写一句」都过一遍；字母不分大小写）
const BLOCKED_WORDS: Array[String] = ["傻逼", "傻B", "煞笔", "操你", "草泥马", "他妈", "你妈", "妈的", "尼玛", "狗屎", "屎尿",
	"王八蛋", "混蛋", "贱人", "去死", "fuck", "shit", "bitch", "dick", "damn"]

static var _ref_width := -1.0
static var _model_scenes: Dictionary = {}


# ---------------------------------------------------------------- 各包是否合入

static func generator_ready(version: String = "") -> bool:
	return CustomMapTradegenRegistry.parameter_error(version if version != "" else CustomMapSchema.TRADEGEN) == ""


static func geometry_ready() -> bool:
	return ResourceLoader.exists(HEIGHT_MAP)


static func card_text_ready() -> bool:
	return FileAccess.file_exists(CATALOGUE_FILE)


# ---------------------------------------------------------------- 孩子话

## 每一个错误码的孩子话（出发页面板 / 工坊检查条）；what 只用于目录类（找不到「XX」的样子）
static func kid_text(code: String, what: String = "") -> String:
	if code in FILE_CODES:
		return KID_FILE
	if code == "E_GENERATOR_PARAMS":
		return "交易生成规则未配置，请打开「配置玩法规则」。地图仍可编辑保存。"
	if code == "E_TOO_NEW":
		return KID_TOO_NEW
	if code == "E_BASE":
		return KID_BASE
	if code in CATALOGUE_CODES:
		return KID_CATALOGUE % (what if what != "" else "新城")
	if code in RULE_CODES:
		return KID_RULES
	if code in NAME_CODES:
		return KID_NAMES
	if code in CARD_CODES:
		return KID_CARDS
	if code.begins_with("G_"):
		return KID_GEO
	return ""


static func all_codes() -> Array[String]:
	var out: Array[String] = []
	for list in [FILE_CODES, VERSION_CODES, CATALOGUE_CODES, RULE_CODES, NAME_CODES, CARD_CODES, GEO_CODES]:
		out.append_array(list)
	return out


# ---------------------------------------------------------------- 入口

## 返回 {ok, errors: [{code, target, kid, tech}], warnings, sha256, topology_key, generated, counts_win}
static func validate(base: Dictionary, base_layout: Dictionary, doc: Dictionary, catalogue: Dictionary) -> Dictionary:
	if CustomMapFreeAuthor.enabled(doc):return CustomMapFreeAuthor.validate(base,base_layout,doc,catalogue)
	var errs: Array[Dictionary] = []
	var warnings: Array[Dictionary] = []
	var out := {"ok": false, "errors": errs, "warnings": warnings, "sha256": "", "topology_key": "", "generated": {}, "counts_win": false}
	doc = CustomMapSchema.upgrade(doc)
	# ① 文件和版本：这一步不过就不往下查
	_check_file(doc, base, errs, warnings)
	if not errs.is_empty():
		return out
	out["sha256"] = CustomMapSchema.sha256(doc)
	out["topology_key"] = CustomMapSchema.topology_key(doc)
	# ② 拓扑
	var topo := CustomMapRules.check_topology(base, doc, {})
	errs.append_array(topo)
	# 后续布局推导依赖合法的宿主、槽位、路段和编辑字段。已拒绝的规则文档
	# 不能继续作为几何输入，否则一次类型错误会变成无关几何错误甚至访问坏数据。
	if not topo.is_empty():
		return out
	# ③ 名字、目录、卡面文字
	var before_cat := errs.size()
	_check_names(base, doc, errs)
	_check_catalogue(doc, catalogue, errs)
	var catalogue_ok := errs.size() == before_cat
	if not catalogue_ok:
		return out
	if topo.is_empty() and catalogue_ok:
		_check_texts(base, doc, catalogue, errs)
	# ④ 几何（WP3）
	if geometry_ready() and not base_layout.is_empty():
		# 标准棋盘采样器只读；复用它避免每次校验重复载入 sea_dist。
		var geo := CustomMapGeo.for_overlay(doc)
		var derived := CustomBoardLayout.derive(base_layout, doc, geo, catalogue)
		if doc.has("plants") and not derived.has("error"):
			errs.append_array(CustomMapPlants.check(derived, doc, geo))
		for e in CustomMapGeoRules.check(derived, base_layout, doc, geo):
			var ge: Dictionary = e
			if str(ge.get("kid", "")) == "":
				ge["kid"] = kid_text(str(ge.get("code", "")))
			if str(ge.get("level", "")) == "warning":
				warnings.append(ge)
			else:
				errs.append(ge)
	# ⑤ 贸易卡：拓扑和目录都对了才重算（否则生成器的输入本身就不成立）
	if topo.is_empty() and catalogue_ok:
		var gen := generate(base, doc, catalogue)
		if not bool(gen.get("ok", false)):
			_err(errs, str(gen.get("code", "E_CARDS_INVARIANT")), "generated", str(gen.get("tech", "")))
		else:
			out["generated"] = gen["generated"]
			var file_gen: Variant = doc.get("generated", {"topology_key": "", "decks": []})
			if not file_gen is Dictionary or CustomMapSchema.canonical_text(file_gen) != CustomMapSchema.canonical_text(gen["generated"]):
				_err(errs, "E_CARDS_MISMATCH", "generated", "文件里的贸易卡与重算结果不同")
	# ⑥ 素材
	if catalogue_ok:
		_check_assets(doc, catalogue, errs)
	out["counts_win"] = CustomMapWin.counts_key(str(out["topology_key"]), str(doc.get("tradegen", "")))
	out["ok"] = errs.is_empty()
	return out


## installed.json 外壳：schema 与 sha（E_SCHEMA / E_SHA），再整份校验覆盖层
static func validate_installed(shell: Dictionary, base: Dictionary, base_layout: Dictionary, catalogue: Dictionary) -> Dictionary:
	var errs: Array[Dictionary] = []
	var out := {"ok": false, "errors": errs, "warnings": [], "sha256": "", "topology_key": "", "generated": {}, "counts_win": false}
	if str(shell.get("schema", "")) != CustomMapSchema.INSTALL_SCHEMA or not shell.get("overlay") is Dictionary:
		_err(errs, "E_SCHEMA", "installed.json", "外壳 schema 不对：%s" % str(shell.get("schema", "")))
		return out
	var overlay: Dictionary = shell["overlay"]
	if CustomMapSchema.sha256(overlay) != str(shell.get("sha256", "")):
		_err(errs, "E_SHA", "installed.json", "外壳里的 sha 与内容不符")
		return out
	return validate(base, base_layout, overlay, catalogue)


## 读地图文本（E_PARSE）：返回 {doc, errors}
static func parse_text(text: String) -> Dictionary:
	var errs: Array[Dictionary] = []
	if text.to_utf8_buffer().size() > CustomMapSchema.MAX_FILE_BYTES:
		_err(errs, "E_PARSE", "file", "文件超过 %d KB" % (CustomMapSchema.MAX_FILE_BYTES / 1024))
		return {"doc": {}, "errors": errs}
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		_err(errs, "E_PARSE", "file", "不是 JSON 对象：%s" % json.get_error_message())
		return {"doc": {}, "errors": errs}
	return {"doc": json.data, "errors": errs}


# ---------------------------------------------------------------- ① 文件和版本

static func _check_file(doc: Dictionary, base: Dictionary, errs: Array[Dictionary], warnings: Array[Dictionary], allow_unconfigured_editing: bool = false) -> void:
	if CustomMapFreeAuthor.enabled(doc):
		var author_error:=CustomMapFreeAuthor.format_error(doc,base)
		if author_error!="":_err(errs,"E_FREE_FORMAT","free_routes",author_error);return
	if doc.has("landscape"):
		var landscape_error := CustomMapLandscape.error(doc.landscape)
		if landscape_error != "":
			_err(errs, "E_SCHEMA", "landscape", landscape_error)
			return
	var schema: Variant = doc.get("schema")
	if not schema is String:
		_err(errs, "E_SCHEMA", "schema", "缺 schema")
		return
	if schema not in CustomMapSchema.SUPPORTED_SCHEMAS:
		if CustomMapSchema.schema_version_of(schema) > CustomMapSchema.SCHEMA_VERSION:
			_err(errs, "E_TOO_NEW", "schema", "文件版本比游戏新：%s" % schema)
		else:
			_err(errs, "E_SCHEMA", "schema", "不认识的 schema：%s" % schema)
		return
	if doc.get("tradegen") == CustomMapFreeRoutes.GENERATOR and not CustomMapFreeRoutes.enabled(doc):
		_err(errs, "E_FREE_FORMAT", "free_routes", "自由交易规则缺少路线层")
		return
	if CustomMapFreeRoutes.enabled(doc):
		var free_error:=CustomMapFreeRoutes.format_error(doc,base)
		if free_error!="":_err(errs,"E_FREE_FORMAT","free_routes",free_error);return
	var asset_plan := CustomMapLocalAssets.preflight_doc(doc)
	if not asset_plan.ok:
		_err(errs, "E_ASSET_MISSING", "assets", asset_plan.message);return
	var piece_error := CustomMapPieceSkins.error(doc)
	if piece_error != "":
		_err(errs, "E_ASSET_MISSING", "piece_skins", piece_error);return
	var intro_error := CustomMapCityIntro.error(doc)
	if intro_error != "":
		_err(errs, "E_SCHEMA", "city_intro_cards", intro_error)
		return
	var badge_error := CustomMapCityBadges.error(doc, base)
	if badge_error != "":
		_err(errs, "E_SCHEMA", "city_badges", badge_error); return
	var local_error := CustomMapLocalAssets.layer_error(doc)
	if local_error != "":
		_err(errs, "E_ASSET_MISSING", "assets", local_error)
		return
	if doc.has("plants"):
		if schema not in [CustomMapPlants.SCHEMA, CustomMapLocalAssets.SCHEMA, CustomMapCityIntro.SCHEMA, CustomMapPieceSkins.SCHEMA, CustomMapFreeRoutes.SCHEMA]:
			_err(errs, "E_SCHEMA", "plants", "单株植物只允许在 v2 副本中保存")
			return
		var plant_error := CustomMapPlants.error(doc.plants)
		if plant_error != "":
			_err(errs, "E_SCHEMA", "plants", plant_error)
			return
		plant_error = CustomMapPlants.dependencies_error(doc.plants)
		if plant_error != "":
			_err(errs, "E_ASSET_MISSING", "plants", plant_error)
			return
	var cv: Variant = doc.get("catalogue_version")
	if not (cv is int or cv is float):
		_err(errs, "E_SCHEMA", "catalogue_version", "缺 catalogue_version")
		return
	if int(cv) > CustomMapSchema.CATALOGUE_VERSION:
		_err(errs, "E_TOO_NEW", "catalogue_version", "目录版本比游戏新：%d" % int(cv))
		return
	var tg: Variant = doc.get("tradegen")
	if not tg is String:
		_err(errs, "E_SCHEMA", "tradegen", "缺 tradegen")
		return
	if not String(tg) in CustomMapSchema.KNOWN_TRADEGENS:
		_err(errs, "E_TOO_NEW", "tradegen", "游戏没有这个生成器版本：%s" % tg)
		return
	var parameter_problem := CustomMapTradegenRegistry.parameter_error(str(tg))
	if parameter_problem != "" and not (allow_unconfigured_editing and not PublicRules.ready()):
		_err(errs, "E_GENERATOR_PARAMS", "tradegen", parameter_problem)
		return

	var b: Variant = doc.get("base")
	if not b is Dictionary:
		_err(errs, "E_SCHEMA", "base", "缺 base")
		return
	var bd: Dictionary = b
	var want_sig := CustomMapSchema.graph_sig(base)
	if str(bd.get("ruleset_id", "")) != CustomMapSchema.RULESET_ID or str(bd.get("edition_id", "")) != str(base.get("ruleset", {}).get("edition_id", CustomMapSchema.EDITION_ID)) \
			or str(bd.get("graph_sig", "")) != want_sig:
		_err(errs, "E_BASE", "base", "正式规则变了：ruleset/edition/graph_sig 不一致")
		return
	if str(bd.get("layout_sha256", "")) != CustomMapSchema.layout_sha256():
		warnings.append({"code": "W_LAYOUT", "target": "base.layout_sha256", "kid": "", "tech": "底图更新过：几何规则全部重跑"})
	var name: Variant = doc.get("name")
	if not name is String or String(name).strip_edges().is_empty() or String(name).strip_edges().length() > MAP_NAME_MAX:
		_err(errs, "E_NAME", "name", "地图名要 1–%d 个字：%s" % [MAP_NAME_MAX, str(name)])
		return
	if doc.has("moves") and doc.get("moves") != null and not doc.get("moves") is Dictionary:
		_err(errs, "E_SCHEMA", "moves", "moves 不是对象")
		return
	if not doc.get("new_cities", []) is Array:
		_err(errs, "E_SCHEMA", "new_cities", "new_cities 不是数组")
		return
	for c in doc.get("new_cities", []):
		if not c is Dictionary:
			_err(errs, "E_SCHEMA", "new_cities", "新城条目不是对象")
			return
		for f in ["x", "z", "rotation", "size"]:
			var v: Variant = (c as Dictionary).get(f, 0.0 if f != "size" else 1.0)
			if not (v is float or v is int):
				_err(errs, "E_SCHEMA", "%s.%s" % [str(c.get("slot", "")), f], "%s 不是数字" % f)
				return
		for f in ["name", "archetype", "specialty"]:
			if not (c as Dictionary).get(f) is String:
				_err(errs, "E_SCHEMA", "%s.%s" % [str(c.get("slot", "")), f], "缺 %s" % f)
				return


# ---------------------------------------------------------------- ③ 名字、目录、文字

## 城名（R29）：返回不合格的原因，合格返回 ""
static func name_problem(name: String) -> String:
	var n := name.strip_edges()
	if n.is_empty():
		return "名字是空的"
	if n != name:
		return "名字前后有空格"
	var han := 0
	var other := 0
	for ch in n:
		var u := ch.unicode_at(0)
		if (u >= 0x4E00 and u <= 0x9FFF) or (u >= 0x3400 and u <= 0x4DBF):
			han += 1
		elif (u >= 0x30 and u <= 0x39) or (u >= 0x41 and u <= 0x5A) or (u >= 0x61 and u <= 0x7A):
			other += 1
		else:
			return "名字里有不认识的字符：%s" % ch
	if other == 0:
		if han > NAME_HAN_MAX:
			return "汉字最多 %d 个" % NAME_HAN_MAX
	else:
		if n.length() > NAME_MIXED_MAX:
			return "最多 %d 个字符" % NAME_MIXED_MAX
		if name_width(n) > name_width(NAME_WIDTH_REF) + 0.5:
			return "名字比「%s」还宽" % NAME_WIDTH_REF
	if has_blocked_word(n):
		return "名字里有不合适的字"
	return ""


## 名字在名牌字体（圆体）下的宽度；系统里找不到圆体时，按固定字宽估（汉字 1.0 em，字母数字按常见宽度）
static func name_width(text: String) -> float:
	var font: Font = Kit.font("body", 900)
	var w := 0.0
	if font != null:
		w = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_PX).x
	if w > 0.0:
		return w
	var em := 0.0
	for ch in text:
		var u := ch.unicode_at(0)
		if u >= 0x3400:
			em += 1.0
		elif ch in ["M", "W", "m", "w"]:
			em += 0.85
		elif ch in ["i", "l", "j", "I", "1", "t", "f", "r"]:
			em += 0.35
		elif (u >= 0x41 and u <= 0x5A):
			em += 0.68
		else:
			em += 0.56
	return em * NAME_FONT_PX


static func has_blocked_word(text: String) -> bool:
	if card_text_ready():
		return not CustomMapCardText.blocked_word_in(text).is_empty()
	var low := text.to_lower()
	for w in BLOCKED_WORDS:
		if low.contains(w.to_lower()):
			return true
	return false


static func _check_names(base: Dictionary, doc: Dictionary, errs: Array[Dictionary]) -> void:
	var original := {}
	for c in (base.get("cities", {}) as Dictionary).values():
		original[str(CustomMapCityBadges.config(doc, str(c.get("id", ""))).get("name", c.get("display_name", "")))] = str(c.get("id", ""))
	var seen := {}
	for c in doc.get("new_cities", []):
		var slot := str(c.get("slot", ""))
		var name := str(c.get("name", ""))
		var problem := name_problem(name)
		if problem != "":
			_err(errs, "E_NAME", slot, "%s：%s" % [problem, name])
			continue
		if original.has(name):
			_err(errs, "E_NAME_DUP", slot, "和原版的城重名：%s" % name)
		elif seen.has(name):
			_err(errs, "E_NAME_DUP", slot, "和 %s 重名：%s" % [seen[name], name])
		seen[name] = slot


static func _check_catalogue(doc: Dictionary, catalogue: Dictionary, errs: Array[Dictionary]) -> void:
	var specs := {}
	for c in doc.get("new_cities", []):
		var slot := str(c.get("slot", ""))
		var arch_id := str(c.get("archetype", ""))
		var arch := CustomMapCatalogue.archetype(catalogue, arch_id)
		if arch.is_empty() or not CustomMapCatalogue.is_usable(arch):
			_err(errs, "E_ARCHETYPE", slot, "目录里没有可用的原型：%s" % arch_id, str(arch.get("title", arch_id)))
		elif not CustomMapFreeAuthor.enabled(doc) and not str(c.get("route_type", "")) in (arch.get("fits", []) as Array):
			_err(errs, "E_ARCHETYPE", slot, "原型 %s 不适配 %s" % [arch_id, str(c.get("route_type", ""))], str(arch.get("title", arch_id)))
		var key := str(c.get("specialty", ""))
		var spec := CustomMapCatalogue.specialty(catalogue, key)
		if spec.is_empty() or not CustomMapCatalogue.is_usable(spec):
			_err(errs, "E_SPECIALTY", slot, "目录里没有可用的特产：%s" % key, str(spec.get("display_name", key)))
		elif specs.has(key):
			_err(errs, "E_SPECIALTY_DUP", slot, "特产和 %s 重复：%s" % [specs[key], key])
		specs[key] = slot


## 卡面文字（3.15）：「自己写一句」4–40 字、过不雅词表；拼好的文字再按 game_data.gd:141-144 的常量查（E_TEXT_LEN）
static func _check_texts(base: Dictionary, doc: Dictionary, catalogue: Dictionary, errs: Array[Dictionary]) -> void:
	for c in doc.get("new_cities", []):
		var slot := str(c.get("slot", ""))
		var text: Variant = c.get("text", {"mode": "AUTO"})
		var mode := str((text as Dictionary).get("mode", "AUTO")) if text is Dictionary else ""
		if mode != "AUTO" and mode != "CUSTOM":
			_err(errs, "E_TEXT_LEN", slot, "text.mode 只能是 AUTO / CUSTOM")
			continue
		if mode == "CUSTOM":
			var line := str((text as Dictionary).get("line", "")).strip_edges()
			if line.length() < LINE_RANGE.x or line.length() > LINE_RANGE.y:
				_err(errs, "E_TEXT_LEN", slot, "「自己写一句」要 %d–%d 个字，现在 %d 个" % [LINE_RANGE.x, LINE_RANGE.y, line.length()])
				continue
			if has_blocked_word(line):
				_err(errs, "E_TEXT_LEN", slot, "「自己写一句」里有不合适的字")
				continue
		var texts := texts_for(base, doc, c, catalogue)
		for e in check_texts(texts):
			var te: Dictionary = e
			te["target"] = slot
			errs.append(te)


## 新城的卡面与图鉴文字：WP6a 合入后用 CustomMapCardText.texts_for；之前用本文件的模板兜底
static func texts_for(base: Dictionary, doc: Dictionary, city: Dictionary, catalogue: Dictionary) -> Dictionary:
	if CustomMapFreeAuthor.enabled(doc):return CustomMapFreeAuthor.texts_for(city,catalogue)
	var host := str(city.get("host", ""))
	var host_name := str((base.get("cities", {}) as Dictionary).get(host, {}).get("display_name", host))
	var side := CustomMapRules.side_of_host(base, host)
	if card_text_ready():
		return CustomMapCardText.texts_for(city, host_name, side, catalogue)
	return _fallback_texts(city, host_name, side, catalogue)


static func check_texts(texts: Dictionary) -> Array[Dictionary]:
	if card_text_ready():
		return CustomMapCardText.check(texts)
	var errs: Array[Dictionary] = []
	var intro := str(texts.get("intro", "")).strip_edges()
	var scenery := str(texts.get("scenery", "")).strip_edges()
	var epithet := str(texts.get("epithet", "")).strip_edges()
	if intro.length() < GameData.CARD_TEXT_INTRO_RANGE.x or intro.length() > GameData.CARD_TEXT_INTRO_RANGE.y:
		_err(errs, "E_TEXT_LEN", "", "简介 %d 字，要 %d–%d" % [intro.length(), GameData.CARD_TEXT_INTRO_RANGE.x, GameData.CARD_TEXT_INTRO_RANGE.y])
	if scenery.length() < GameData.CARD_TEXT_SCENERY_RANGE.x or scenery.length() > GameData.CARD_TEXT_SCENERY_RANGE.y:
		_err(errs, "E_TEXT_LEN", "", "风貌 %d 字，要 %d–%d" % [scenery.length(), GameData.CARD_TEXT_SCENERY_RANGE.x, GameData.CARD_TEXT_SCENERY_RANGE.y])
	if intro.length() + scenery.length() > GameData.CARD_TEXT_CITY_MAX:
		_err(errs, "E_TEXT_LEN", "", "简介和风貌合计 %d 字，最多 %d" % [intro.length() + scenery.length(), GameData.CARD_TEXT_CITY_MAX])
	if epithet.length() < EPITHET_RANGE.x or epithet.length() > EPITHET_RANGE.y:
		_err(errs, "E_TEXT_LEN", "", "别称 %d 字，要 %d–%d" % [epithet.length(), EPITHET_RANGE.x, EPITHET_RANGE.y])
	return errs


## WP6a 合入前的卡面文字兜底（按 3.15 的模板；WP6a 的 CustomMapCardText 合入后不再走这里）
static func _fallback_texts(city: Dictionary, host_name: String, side: String, catalogue: Dictionary) -> Dictionary:
	var slot := str(city.get("slot", ""))
	var cid := CustomMapSchema.city_id(slot)
	var name := str(city.get("name", ""))
	var arch := CustomMapCatalogue.archetype(catalogue, str(city.get("archetype", "")))
	var spec := CustomMapCatalogue.specialty(catalogue, str(city.get("specialty", "")))
	var spec_name := str(spec.get("display_name", city.get("specialty", "")))
	var land := str(city.get("route_type", "")) == "LAND"
	var where := "西边" if side == "W" else "东边"
	var scenery := str(arch.get("scenery", "城里的房子挨着房子，街上总有赶路的商队。"))
	var intro := ""
	var epithet := "%s新城·%s" % [where, str(arch.get("epithet4", "丝路新城"))]
	var lore := {
		"id": cid, "city_id": cid, "epithet": epithet,
		"position": "在地图%s，和%s之间有一条三站的%s。" % [where, host_name, "陆路" if land else "海路"],
		"history": "这座城是在L叔地图工坊里新加的，它的故事等你来写。",
		"sights": scenery,
		"historical_period": str(arch.get("historical_period", "丝路时代")),
		"modern_reference": "玩家在地图工坊里加的城",
		"source_refs": [],
		"verification_status": "PLAYER_MAP",
	}
	var text: Dictionary = city.get("text", {}) if city.get("text") is Dictionary else {}
	var known := CustomMapCatalogue.known_by_name(catalogue, name)
	if str(text.get("mode", "AUTO")) == "CUSTOM":
		var line := str(text.get("line", "")).strip_edges()
		if line.length() >= GameData.CARD_TEXT_INTRO_RANGE.x:
			intro = line
		else:
			if not (line.ends_with("。") or line.ends_with("！") or line.ends_with("？")):
				line += "。"
			intro = "%s%s在丝路%s，出产%s，商队常来。" % [line, name, where, spec_name]
	elif not known.is_empty() and str(known.get("specialty", "")) == str(city.get("specialty", "")):
		intro = str(known.get("intro", ""))
		scenery = str(known.get("scenery", scenery))
		epithet = str(known.get("epithet", epithet))
		lore["epithet"] = epithet
		lore["sights"] = str(known.get("sights", scenery))
		lore["history"] = str(known.get("history", lore["history"]))
		lore["historical_period"] = str(known.get("historical_period", lore["historical_period"]))
		lore["modern_reference"] = str(known.get("modern_reference", lore["modern_reference"]))
		lore["source_refs"] = (known.get("source_refs", []) as Array).duplicate(true)
		lore["verification_status"] = "CATALOGUE_POOL"
	else:
		intro = "%s是丝路%s的一座%s，出产%s，%s。" % [name, where, str(arch.get("noun", "小城")), spec_name,
			"四方的商队常来这里收货" if land else "南来北往的商船常在这里靠岸"]
	return {"intro": intro, "scenery": scenery, "epithet": epithet, "lore": lore}


## 素材（R30）：原型的模型、卡图，特产的图标都要在包里
static func _check_assets(doc: Dictionary, catalogue: Dictionary, errs: Array[Dictionary]) -> void:
	for c in doc.get("new_cities", []):
		var slot := str(c.get("slot", ""))
		var arch := CustomMapCatalogue.archetype(catalogue, str(c.get("archetype", "")))
		var spec := CustomMapCatalogue.specialty(catalogue, str(c.get("specialty", "")))
		var selected_rt := str(c.get("route_type", ""))
		if CustomMapFreeAuthor.enabled(doc):
			var media:Array=CustomMapFreeAuthor.routes_for(CustomMapLoader.base_content(),doc,CustomMapSchema.city_id(str(c.slot)))
			selected_rt="LAND" if "LAND" in media or media.is_empty() else "SEA"
		var selected_art := CustomMapCatalogue.card_art_for(arch, selected_rt)
		for pair in [[str(arch.get("model", "")), "model", str(arch.get("title", ""))], [selected_art, "card_art", str(arch.get("title", ""))],
				[str(spec.get("icon", "")), "icon", str(spec.get("display_name", ""))]]:
			var path := str(pair[0])
			if path == "" or not ResourceLoader.exists(path) or (str(pair[1]) == "model" and model_scene(path) == null):
				_err(errs, "E_ASSET_MISSING", slot, "缺素材 %s：%s" % [pair[1], path], String(pair[2]))
				break


## A catalogue model must be a real imported 3D scene with geometry. Raw GLTF
## and placeholder fallbacks cannot turn a broken map into a usable map.
## Fingerprints cover both source/remap and compiled scene bytes, so replacing
## a resource at the same path cannot reuse a previously accepted scene.
static func model_scene(path: String) -> PackedScene:
	if path.begins_with(CustomMapLocalAssets.root() + "/"):
		var local := CustomMapLocalAssets.read(path.get_file(), "city_model")
		return local.get("scene") if local.ok else null
	if path == "" or not ResourceLoader.exists(path): return null
	var fingerprints := PackedStringArray([path])
	for suffix in [".import", ".remap"]:
		var metadata: String = path + str(suffix)
		if not FileAccess.file_exists(metadata): continue
		var config := ConfigFile.new()
		if config.load(metadata) != OK: return null
		if str(config.get_value("remap", "importer", "")) == "keep": return null
		var target := str(config.get_value("remap", "path", ""))
		if target == "" or not FileAccess.file_exists(target): return null
		fingerprints.append(FileAccess.get_sha256(metadata))
		fingerprints.append(FileAccess.get_sha256(target))
	if FileAccess.file_exists(path): fingerprints.append(FileAccess.get_sha256(path))
	var key := "|".join(fingerprints)
	if _model_scenes.has(key): return _model_scenes[key] as PackedScene
	var scene := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if scene == null or not scene.can_instantiate(): return null
	var node := scene.instantiate()
	var valid := node is Node3D and _model_has_geometry(node)
	node.free()
	if not valid: return null
	if _model_scenes.size() >= 64: _model_scenes.clear()
	_model_scenes[key] = scene
	return scene


static func _model_has_geometry(node: Node) -> bool:
	if node is MeshInstance3D and node.mesh != null and node.mesh.get_surface_count() > 0: return true
	for child in node.get_children():
		if _model_has_geometry(child): return true
	return false


# ---------------------------------------------------------------- ⑤ 贸易卡

## 用生成器重算这张图的贸易卡：{ok, generated: {topology_key, decks}, code, tech}。
## 生成器只看拓扑（R18）：[{slot, host, route_type, partner}]，新货只换真实 id（x_<槽位>_<特产键>）
static func generate(base: Dictionary, doc: Dictionary, catalogue: Dictionary) -> Dictionary:
	var version := str(doc.get("tradegen", ""))
	var parameter_problem := CustomMapTradegenRegistry.parameter_error(version)
	if parameter_problem != "":
		return {"ok": false, "code": "E_GENERATOR_PARAMS", "tech": parameter_problem}
	var key := CustomMapSchema.topology_key(doc)
	var cities: Array = doc.get("new_cities", [])
	if cities.is_empty():
		return {"ok": true, "generated": {"topology_key": key, "decks": []}}
	var topology: Array = []
	var goods_map := {}
	for c in cities:
		if CustomMapFreeAuthor.enabled(doc):topology.append({"slot":str(c.slot),"partner":""})
		else:topology.append({"slot": str(c["slot"]), "host": str(c["host"]), "route_type": str(c["route_type"]), "partner": str(c["partner"]), "extra_connections": c.get("extra_connections", []).duplicate(true), "host_interchange": c.get("host_interchange", false)})
		if CustomMapFreeAuthor.enabled(doc) and CustomMapCatalogue.specialty(catalogue,str(c.specialty)).is_empty():return {"ok":false,"code":"E_SPECIALTY","tech":"请选择有效特产"}
		goods_map[str(c["slot"])] = CustomMapSchema.good_id(str(c["slot"]), str(c["specialty"]))
	topology.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["slot"]) < str(b["slot"]))
	var res: Dictionary = CustomMapFreeRoutes.generate(base,doc,goods_map,topology) if CustomMapFreeRoutes.enabled(doc) else CustomMapTradegenRegistry.generate(base, topology, goods_map, version)
	if not bool(res.get("ok", false)):
		return {"ok": false, "code": "E_CARDS_INVARIANT", "tech": "生成器报错：%s" % str(res.get("errors", []))}
	var decks: Array = []
	for d in res.get("decks", []):
		decks.append({"id": str(d.get("id", "")), "city_id": str(d.get("city_id", "")), "cards": (d.get("cards", []) as Array).duplicate(true)})
	var problems := structural_problems(base, decks, cities)
	if generator_ready(version):
		var existing := {}
		for card_id in (base.get("trade_card_index", {}) as Dictionary).keys():
			existing[card_id] = true
		var goods := (base.get("goods", {}) as Dictionary).duplicate(false)
		for c in cities:
			goods[goods_map[str(c["slot"])]] = {"id": goods_map[str(c["slot"])], "supply_total": 10}
		for d in decks:
			var slot := str(d["id"]).trim_prefix("deck_x_")
			var deck_problems: Array = CustomMapTradegenRegistry.validate_deck(d, goods, existing, str(goods_map.get(slot, "")), version)
			for p in deck_problems:
				problems.append(p)
			for card in d["cards"]:
				existing[str(card.get("id", ""))] = true
	if not problems.is_empty():
		return {"ok": false, "code": "E_CARDS_INVARIANT", "tech": "; ".join(problems)}
	return {"ok": true, "generated": {"topology_key": key, "decks": decks}}


## 游戏合并时一定要成立的结构（与生成器无关，保证开局、交易不出错）：每座新城恰好一堆 10 张、id 对得上槽位、
## 每张 4 项、恰好 1 项白银、数量 1–4、货物都存在、同卡不重复、卡 id 全局唯一、本城特产只在第 2 格
static func structural_problems(base: Dictionary, decks: Array, cities: Array) -> Array[String]:
	var out: Array[String] = []
	var goods := {}
	for g in (base.get("goods", {}) as Dictionary).keys():
		goods[str(g)] = true
	var local := {}
	for c in cities:
		var gid := CustomMapSchema.good_id(str(c["slot"]), str(c["specialty"]))
		goods[gid] = true
		local[CustomMapSchema.deck_id(str(c["slot"]))] = gid
	var seen_cards := {}
	for card_id in (base.get("trade_card_index", {}) as Dictionary).keys():
		seen_cards[str(card_id)] = true
	var want := {}
	for c in cities:
		want[CustomMapSchema.deck_id(str(c["slot"]))] = CustomMapSchema.city_id(str(c["slot"]))
	if decks.size() != want.size():
		out.append("牌堆 %d 堆，应为 %d 堆" % [decks.size(), want.size()])
	for d in decks:
		var did := str(d.get("id", ""))
		if not want.has(did) or str(d.get("city_id", "")) != str(want.get(did, "")):
			out.append("牌堆 id 与槽位对不上：%s / %s" % [did, str(d.get("city_id", ""))])
			continue
		var cards: Array = d.get("cards", [])
		if cards.size() != 10:
			out.append("%s 有 %d 张卡" % [did, cards.size()])
		var n := 0
		for card in cards:
			n += 1
			var cid := str(card.get("id", ""))
			if cid != "%s_card_%02d" % [did, n] or seen_cards.has(cid) or int(card.get("card_number", 0)) != n:
				out.append("卡 id 不对：%s" % cid)
			seen_cards[cid] = true
			var entries: Array = card.get("entries", [])
			var silver := 0
			var ids := {}
			if entries.size() != 4:
				out.append("%s 不是 4 项" % cid)
			for i in entries.size():
				var e: Dictionary = entries[i]
				var q := int(e.get("quantity", 0))
				var kind := str(e.get("resource_kind", ""))
				var rid := str(e.get("resource_id", ""))
				if kind == "SILVER":
					silver += 1
					if rid != "silver" or q < 1 or q > 5:
						out.append("%s 白银格不对" % cid)
				elif kind == "GOOD":
					if not goods.has(rid) or q < 1 or q > 4:
						out.append("%s 货物格不对：%s×%d" % [cid, rid, q])
					if rid == str(local.get(did, "")) and i != 1:
						out.append("%s 本城特产不在第 2 格" % cid)
				else:
					out.append("%s 资源类型不对：%s" % [cid, kind])
				if ids.has(kind + rid):
					out.append("%s 同一张卡上资源重复：%s" % [cid, rid])
				ids[kind + rid] = true
			if silver != 1:
				out.append("%s 要恰好 1 项白银，现在 %d 项" % [cid, silver])
	return out


static func _err(errs: Array[Dictionary], code: String, target: String, tech: String, what: String = "") -> void:
	errs.append({"code": code, "target": target, "kid": kid_text(code, what), "tech": tech})
