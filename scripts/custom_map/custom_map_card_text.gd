class_name CustomMapCardText

## 新城的卡面与图鉴文字（docs/design/map-editor-20260930/DESIGN.md 3.15）。游戏和工坊共用，归 WP6a。
## 选哪种文字，按优先级：
##   1. text.mode == "CUSTOM"：孩子自己写的一句 line（4–40 字），不够 20 字就接一句尾句补成简介；
##   2. 城名与目录里某条「认得的名字」完全相同，并且特产等于该条的默认特产：用这条写好的真实文字；
##   3. 其它：模板。
## 风貌在 1、3 两种情况下都用原型固定的那句（原型风貌不写货名，所以换特产也对得上）。
## 长度用 game_data.gd:141-144 的同一组常量（E_TEXT_LEN）；别称 8–16 字。
## 图鉴条目带 id、city_id（都等于 x_<槽位>）：正式城市卡的解析器在 lore.city_id != city_id 时直接失败
## （formal_card_presentation_resolver.gd:84-86），6 个展示字段也必须非空（:88-90）。
## 新城的图鉴不打 SOURCE_VERIFIED：篝火台词只挑这种标记的城（fun_event_ops.gd:300），新城不该被挑中（R21）。
## 本文件只读目录字典，不 preload 任何素材（安卓排除 assets/custom_map/*，DESIGN 3.6 的硬规则）。
## 输入来自玩家的地图文件，字段类型不可信：texts_for 把不是字符串的字段一律当空串，check 遇到类型不对直接报 E_TEXT_LEN。

const MODE_AUTO := "AUTO"
const MODE_CUSTOM := "CUSTOM"
## texts_for 返回的 source：这段文字从哪来
const SOURCE_CUSTOM := "CUSTOM"
const SOURCE_KNOWN := "KNOWN"
const SOURCE_TEMPLATE := "TEMPLATE"
## 图鉴的 verification_status（R21：不写 SOURCE_VERIFIED）
const STATUS_KNOWN := "CATALOGUE_POOL"
const STATUS_PLAYER := "PLAYER_MAP"

## 新城的槽位（DESIGN 3.2、3.4）；图鉴 id / city_id 必须是 x_<其中之一>
const SLOTS: Array[String] = ["w1", "e1", "w2", "e2"]
## 「自己写一句」的长度（去掉首尾空白、表情和控制符之后）
const LINE_RANGE := Vector2i(4, 40)
## 别称长度（与 game_data.gd:199 的图鉴 epithet 同一范围）
const EPITHET_RANGE := Vector2i(8, 16)
## 这些字符结尾的 line 不再补「。」
const LINE_END_MARKS := "。！？!?.…"
## check() 要求是字符串的字段
const TEXT_FIELDS: Array[String] = ["intro", "scenery", "epithet"]
const LORE_TEXT_FIELDS: Array[String] = ["id", "city_id", "epithet", "position", "history", "sights", "historical_period", "modern_reference",
	"verification_status"]

const TEXT_CODE := "E_TEXT_LEN"
## 3.17「名字和文字」一类的孩子话
const KID_TEXT := "有座城的名字或介绍不对，请在工坊里打开看看。"

const SIDE_WORD := {"W": "西边", "E": "东边"}
const ROUTE_WORD := {"LAND": "陆路", "SEA": "海路"}

## 模板（3.15）
const INTRO_LAND := "%s是丝路%s的一座%s，出产%s，四方的商队常来这里收货。"
const INTRO_SEA := "%s是丝路%s的一座%s，出产%s，南来北往的商船常在这里靠岸。"
const CUSTOM_TAIL := "%s在丝路%s，出产%s，商队常来。"
const EPITHET_TEMPLATE := "%s新城·%s"
const POSITION_TEMPLATE := "在地图%s，和%s之间有一条三站的%s。"
const HISTORY_TEMPLATE := "这座城是在L叔地图工坊里新加的，它的故事等你来写。"
const MODERN_TEMPLATE := "玩家在地图工坊里加的城"

## 小的不雅词表：孩子写的一句话用它（3.15），城名的 E_NAME 也应调同一个 blocked_word_in（R29，WP1）。只收明确的脏话。
## 汉字词按子串匹配：先去掉空白，再去掉 ALLOWED_FRAGMENTS 里的正常说法。不收「他妈」「妈的」这种短串：
## 「我妈妈的家乡」「他妈妈做的饭」「我妈的手」都是孩子最常写的句子；也不收「尼玛」（藏族常见人名、尼玛县）。
const BLOCKED_CJK: Array[String] = [
	"傻逼", "傻B", "煞笔", "他妈的", "你妈的", "去你妈", "操你", "草泥马", "滚蛋", "去死", "王八蛋", "贱人", "婊子", "混蛋", "屁眼", "蠢货",
]
## 匹配汉字词之前先去掉的正常说法：「妈妈」「死海」「做早操」里正好夹着上面的词（「他妈妈的」「去死海」「早操你来吗」）
const ALLOWED_FRAGMENTS: Array[String] = ["妈妈", "死海", "体操", "早操", "做操", "出操"]
## 字母词只按整词匹配（全角字母先换成半角）：「Kashitown」「Amsterdamned」「Lisbon」都不算；
## 一个个隔开的单字母会先拼起来再比，所以「f u c k」「s.h.i.t」照样拦
const BLOCKED_LATIN: Array[String] = [
	"fuck", "fucking", "fuckyou", "fuckoff", "motherfucker", "shit", "bullshit", "bitch", "damn", "asshole", "cnm", "nmsl", "tmd", "sb",
]


## 返回 {intro, scenery, epithet, lore: {id, city_id, epithet, position, history, sights, historical_period, modern_reference,
## source_refs, verification_status}}，另带 source（CUSTOM / KNOWN / TEMPLATE）、known_id、mode、line（CUSTOM 时清理过的那句）。
## city 是地图文件 new_cities[] 的一条（slot、name、archetype、specialty、route_type、text）；side 是 "W" / "E"（宿主那一侧，R8）；
## host_name 是宿主城的显示名；catalogue 是 data/custom_map/catalogue_v1.json 的整份字典。纯函数，同样的输入输出相同。
static func texts_for(city: Dictionary, host_name: String, side: String, catalogue: Dictionary) -> Dictionary:
	var city_id := "x_" + _str(city.get("slot", ""))
	var name := strip_spaces(_str(city.get("name", "")))
	var route := _str(city.get("route_type", "LAND"))
	var side_word := _str(SIDE_WORD.get(_side_key(side), ""))
	var arche := find_archetype(catalogue, _str(city.get("archetype", "")))
	var spec_key := _str(city.get("specialty", ""))
	var spec := find_specialty(catalogue, spec_key)
	var spec_name := _str(spec.get("display_name", ""))
	var text_v: Variant = city.get("text", {})
	var text: Dictionary = text_v if text_v is Dictionary else {}
	var mode := MODE_CUSTOM if _str(text.get("mode", MODE_AUTO)) == MODE_CUSTOM else MODE_AUTO
	var arche_scenery := _str(arche.get("scenery", ""))
	var template_epithet := EPITHET_TEMPLATE % [side_word, _str(arche.get("epithet4", ""))]
	var position := POSITION_TEMPLATE % [side_word, host_name, _str(ROUTE_WORD.get(route, ""))]
	var out := {"mode": mode, "known_id": "", "line": ""}
	var known := {} if mode == MODE_CUSTOM else find_known(catalogue, name)
	if not known.is_empty() and _str(known.get("specialty", "")) != spec_key:
		known = {}
	if mode == MODE_CUSTOM:
		var line := clean_line(_str(text.get("line", "")))
		out["source"] = SOURCE_CUSTOM
		out["line"] = line
		out["intro"] = custom_intro(line, name, side_word, spec_name)
		out["scenery"] = arche_scenery
		out["epithet"] = template_epithet
	elif not known.is_empty():
		out["source"] = SOURCE_KNOWN
		out["known_id"] = _str(known.get("id", ""))
		out["intro"] = _str(known.get("intro", ""))
		out["scenery"] = _str(known.get("scenery", ""))
		out["epithet"] = _str(known.get("epithet", ""))
	else:
		out["source"] = SOURCE_TEMPLATE
		out["intro"] = (INTRO_SEA if route == "SEA" else INTRO_LAND) % [name, side_word, _str(arche.get("noun", "")), spec_name]
		out["scenery"] = arche_scenery
		out["epithet"] = template_epithet
	var lore := {
		"id": city_id,
		"city_id": city_id,
		"epithet": out["epithet"],
		"position": position,
	}
	if out["source"] == SOURCE_KNOWN:
		var refs: Variant = known.get("source_refs", [])
		lore["history"] = _str(known.get("history", ""))
		lore["sights"] = _str(known.get("sights", ""))
		lore["historical_period"] = _str(known.get("historical_period", ""))
		lore["modern_reference"] = _str(known.get("modern_reference", ""))
		lore["source_refs"] = (refs as Array).duplicate(true) if refs is Array else []
		lore["verification_status"] = STATUS_KNOWN
	else:
		lore["history"] = HISTORY_TEMPLATE
		lore["sights"] = arche_scenery
		lore["historical_period"] = _str(arche.get("historical_period", ""))
		lore["modern_reference"] = MODERN_TEMPLATE
		lore["source_refs"] = []
		lore["verification_status"] = STATUS_PLAYER
	out["lore"] = lore
	return out


## 文字长度与内容检查：返回 [{code, target, kid, tech}]，没有问题时为空。texts 是 texts_for 的返回值。
static func check(texts: Dictionary) -> Array[Dictionary]:
	var errors: Array[Dictionary] = []
	var lore_v: Variant = texts.get("lore", {})
	var lore: Dictionary = lore_v if lore_v is Dictionary else {}
	var target := _str(lore.get("city_id", ""))
	var custom := _str(texts.get("mode", MODE_AUTO)) == MODE_CUSTOM
	# 类型不对（数字、数组、null……）直接报错返回：后面的长度检查只对字符串有意义，也不能因为读不出来就放行
	var bad: Array[String] = []
	if not lore_v is Dictionary:
		bad.append("lore")
	for field in TEXT_FIELDS:
		if not texts.get(field, "") is String:
			bad.append(field)
	if custom and not texts.get("line", "") is String:
		bad.append("line")
	for field in LORE_TEXT_FIELDS:
		if not lore.get(field, "") is String:
			bad.append("lore." + field)
	if not lore.get("source_refs", []) is Array:
		bad.append("lore.source_refs")
	if not bad.is_empty():
		errors.append(_err(target, "not a string: %s" % ", ".join(bad)))
		return errors
	var intro := strip_spaces(String(texts.get("intro", "")))
	var scenery := strip_spaces(String(texts.get("scenery", "")))
	var epithet := strip_spaces(String(texts.get("epithet", "")))
	_range(errors, target, "intro", intro.length(), GameData.CARD_TEXT_INTRO_RANGE)
	_range(errors, target, "scenery", scenery.length(), GameData.CARD_TEXT_SCENERY_RANGE)
	if intro.length() + scenery.length() > GameData.CARD_TEXT_CITY_MAX:
		errors.append(_err(target, "intro+scenery %d > %d" % [intro.length() + scenery.length(), GameData.CARD_TEXT_CITY_MAX]))
	_range(errors, target, "epithet", epithet.length(), EPITHET_RANGE)
	if custom:
		var line := String(texts.get("line", ""))
		_range(errors, target, "line", line.length(), LINE_RANGE)
		if not line.is_empty() and not has_letters(line):
			errors.append(_err(target, "line has no letters (only spaces or punctuation)"))
		var hit := blocked_word_in(line)
		if not hit.is_empty():
			errors.append(_err(target, "line contains blocked word %s" % hit))
	# 解析器要求的 6 个展示字段（formal_card_presentation_resolver.gd:88-90）和身份字段
	for field in ["epithet", "position", "history", "sights", "historical_period", "modern_reference"]:
		if strip_spaces(String(lore.get(field, ""))).is_empty():
			errors.append(_err(target, "lore.%s empty" % field))
	if not SLOTS.has(target.trim_prefix("x_")) or not target.begins_with("x_") or String(lore.get("id", "")) != target:
		errors.append(_err(target, "lore id / city_id must both be x_<w1|e1|w2|e2>"))
	if String(lore.get("verification_status", "")).begins_with("SOURCE_VERIFIED"):
		errors.append(_err(target, "lore must not be SOURCE_VERIFIED (R21)"))
	return errors


## 「自己写一句」拼成的简介（3.15）：line 够 20 字直接用；不够就接尾句「{name}在丝路{西边|东边}，出产{特产}，商队常来。」，
## line 末尾没有句末标点时先补一个「。」。line 应先经过 clean_line。
static func custom_intro(line: String, name: String, side_word: String, spec_name: String) -> String:
	if line.length() >= GameData.CARD_TEXT_INTRO_RANGE.x:
		return line
	var head := line
	if head.is_empty() or not LINE_END_MARKS.contains(head.substr(head.length() - 1, 1)):
		head += "。"
	return head + CUSTOM_TAIL % [name, side_word, spec_name]


## 孩子写的一句话：去掉控制符、零宽字符和表情（R29 对名字的同一做法），再去掉首尾空白（含全角空格）
static func clean_line(raw: String) -> String:
	var out := ""
	for i in raw.length():
		var c := raw.unicode_at(i)
		if _is_dropped_char(c):
			continue
		out += String.chr(c)
	return strip_spaces(out)


## 去掉首尾空白。strip_edges 只认 ASCII 空白，中文输入法打出的全角空格（U+3000）和其它 Unicode 空白它不管
static func strip_spaces(s: String) -> String:
	var a := 0
	var b := s.length()
	while a < b and _is_space(s.unicode_at(a)):
		a += 1
	while b > a and _is_space(s.unicode_at(b - 1)):
		b -= 1
	return s.substr(a, b - a)


## 至少有一个字：汉字（含扩展区）、假名、谚文、字母或数字（半角、全角都算）。只有空格和标点的一句话不算
static func has_letters(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A):
			return true
		if (c >= 0xC0 and c <= 0x24F and c != 0xD7 and c != 0xF7) or (c >= 0x370 and c <= 0x52F):
			return true
		if (c >= 0x3040 and c <= 0x30FF) or (c >= 0x3400 and c <= 0x4DBF) or (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0xAC00 and c <= 0xD7AF):
			return true
		if (c >= 0xF900 and c <= 0xFAFF) or (c >= 0xFF10 and c <= 0xFF19) or (c >= 0xFF21 and c <= 0xFF3A) or (c >= 0xFF41 and c <= 0xFF5A):
			return true
		if c >= 0x20000 and c <= 0x3FFFF:
			return true
	return false


## 文字里含不雅词时返回命中的那个词，否则返回空。大小写、全角半角不敏感；汉字词忽略空白（「傻 逼」也算），
## 字母词按整词比（见 BLOCKED_LATIN 上面的说明）。extra 是追加的词，按同样的规则：全是字母的按整词，其它按子串。
static func blocked_word_in(text: String, extra: Array = []) -> String:
	var folded := _fold_width(text).to_lower()
	var flat := ""
	for i in folded.length():
		var c := folded.unicode_at(i)
		if not _is_space(c):
			flat += String.chr(c)
	for f in ALLOWED_FRAGMENTS:
		flat = flat.replace(f, "")
	var words := latin_words(folded)
	var all_words: Array = []
	all_words.append_array(BLOCKED_CJK)
	all_words.append_array(BLOCKED_LATIN)
	all_words.append_array(extra)
	for w in all_words:
		var word := _fold_width(_str(w)).to_lower()
		if word.is_empty():
			continue
		if _is_latin_word(word):
			if words.has(word):
				return _str(w)
		elif flat.contains(word):
			return _str(w)
	return ""


## 文字里的字母词（小写，按非字母切开）；连续的单字母词（「f u c k」「s.h.i.t」）另外拼成一个词附在后面
static func latin_words(lower: String) -> Array[String]:
	var words: Array[String] = []
	var cur := ""
	for i in lower.length() + 1:
		var c: int = lower.unicode_at(i) if i < lower.length() else 0
		if c >= 0x61 and c <= 0x7A:
			cur += String.chr(c)
		elif not cur.is_empty():
			words.append(cur)
			cur = ""
	var merged: Array[String] = []
	var run := ""
	for i in words.size() + 1:
		var w: String = words[i] if i < words.size() else ""
		if w.length() == 1:
			run += w
			continue
		if run.length() > 1:
			merged.append(run)
		run = ""
	words.append_array(merged)
	return words


## 目录查找（目录很小：24 个原型、24 种特产、约 50 个名字，线性查找即可）
static func find_archetype(catalogue: Dictionary, archetype_id: String) -> Dictionary:
	return _find(catalogue.get("archetypes", []), "id", archetype_id)


static func find_specialty(catalogue: Dictionary, key: String) -> Dictionary:
	return _find(catalogue.get("specialties", []), "key", key)


## 「认得的名字」：孩子起的名字与某条完全相同就算认得，与挂在哪座宿主无关（3.13.4）
static func find_known(catalogue: Dictionary, city_name: String) -> Dictionary:
	if city_name.is_empty():
		return {}
	return _find(catalogue.get("known_names", []), "name", city_name)


static func _find(items: Variant, key: String, value: String) -> Dictionary:
	if not (items is Array) or value.is_empty():
		return {}
	for item in items:
		if item is Dictionary and _str(item.get(key, "")) == value:
			return item
	return {}


## 字符串原样返回，其它类型（数字、数组、null……）一律当空串（玩家的地图文件里什么都可能有）
static func _str(v: Variant) -> String:
	if v is String or v is StringName:
		return String(v)
	return ""


static func _side_key(side: String) -> String:
	var s := side.strip_edges().to_upper()
	if s == "WEST":
		return "W"
	if s == "EAST":
		return "E"
	return s


static func _is_latin_word(word: String) -> bool:
	for i in word.length():
		var c := word.unicode_at(i)
		if c < 0x61 or c > 0x7A:
			return false
	return not word.is_empty()


## 全角 ASCII（U+FF01–U+FF5E）换成半角：输入法开着全角时打出的「ＦＵＣＫ」和「fuck」一样对待
static func _fold_width(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s.unicode_at(i)
		out += String.chr(c - 0xFEE0 if c >= 0xFF01 and c <= 0xFF5E else c)
	return out


static func _is_space(c: int) -> bool:
	if c <= 0x20 or c == 0x85 or c == 0xA0 or c == 0x1680 or c == 0x3000:
		return true
	return (c >= 0x2000 and c <= 0x200A) or c == 0x2028 or c == 0x2029 or c == 0x202F or c == 0x205F


## 控制符、零宽字符和方向控制符、变体选择符、组合用的键帽、表情和各种符号图形
static func _is_dropped_char(c: int) -> bool:
	if c < 0x20 or c == 0x7F or (c >= 0x80 and c < 0xA0):
		return true
	if (c >= 0x200B and c <= 0x200F) or (c >= 0x202A and c <= 0x202E) or (c >= 0x2060 and c <= 0x2069) or c == 0xFEFF:
		return true
	if c == 0x20E3 or (c >= 0xFE00 and c <= 0xFE0F):
		return true
	if (c >= 0x2600 and c <= 0x27BF) or (c >= 0x2B00 and c <= 0x2BFF):
		return true
	return c >= 0x1F000


static func _range(errors: Array[Dictionary], target: String, field: String, n: int, bounds: Vector2i) -> void:
	if n < bounds.x or n > bounds.y:
		errors.append(_err(target, "%s length %d not in %d-%d" % [field, n, bounds.x, bounds.y]))


static func _err(target: String, tech: String) -> Dictionary:
	return {"code": TEXT_CODE, "target": target, "kid": KID_TEXT, "tech": tech}
