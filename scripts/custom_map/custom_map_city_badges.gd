class_name CustomMapCityBadges
extends RefCounted
## Display only. Offset is plaque centre minus city ground projection, in 1920 canvas units.
const BASE_WIDTH := 1920.0
const MAX_OFFSET := 1920.0
const ICONS := ["AUTO", "LAND", "SEA", "BOTH", "STAR", "IMAGE"]
static func config(doc: Dictionary, cid: String) -> Dictionary:
	var layer: Variant = doc.get("city_badges", {})
	if not layer is Dictionary: return {}
	var value: Variant = layer.get(cid, {})
	return value if value is Dictionary else {}
static func with_value(doc: Dictionary, cid: String, field: String, value: Variant) -> Dictionary:
	var out := doc.duplicate(true)
	if not out.has("city_badges"): out.city_badges = {}
	if not out.city_badges.has(cid): out.city_badges[cid] = {}
	out.city_badges[cid][field] = value
	return out
static func error(doc: Dictionary, base: Dictionary) -> String:
	if not doc.has("city_badges"): return ""
	if not doc.city_badges is Dictionary: return "名牌设置格式不合法"
	var ids: Dictionary = base.get("cities", {}).duplicate(false)
	for c: Dictionary in doc.get("new_cities", []): ids["x_" + str(c.slot)] = c
	var names := {}
	for cid in ids:
		var c: Dictionary = ids[cid]
		var value: Variant = doc.city_badges.get(cid, {})
		if not value is Dictionary: return "名牌设置格式不合法"
		var name := str(value.get("name", c.get("display_name", c.get("name", cid))))
		if names.has(name): return "和另一座城市重名：" + name
		names[name] = true
	for cid in doc.city_badges:
		if not ids.has(cid): return "名牌目标城市不存在"
		var c: Variant = doc.city_badges[cid]
		if not c is Dictionary: return "名牌设置格式不合法"
		for key in c:
			if key not in ["name", "mode", "offset_px", "icon"]: return "名牌设置含未知字段"
		if c.has("name"):
			if str(cid).begins_with("x_") or not c.name is String: return "新城名字必须使用城市名字字段"
			var why := CustomMapValidator.name_problem(c.name)
			if why != "": return why
		if c.get("mode", "AUTO") not in ["AUTO", "MANUAL"] or c.get("icon", "AUTO") not in ICONS: return "名牌模式不合法"
		if c.has("offset_px"):
			var v: Variant = c.offset_px
			if not v is Array or v.size() != 2: return "名牌偏移格式不合法"
			for n in v:
				if not CustomMapLandscape._number(n) or absf(float(n)) > MAX_OFFSET: return "名牌偏移须为有限数值，范围 ±1920"
		if c.get("mode", "AUTO") == "MANUAL" and not c.has("offset_px"): return "手动名牌缺少偏移"
		if c.get("icon", "AUTO") == "IMAGE" and CustomMapLocalAssets.bound_id(doc, str(cid).trim_prefix("x_"), "badge_icon") == "": return "名牌图片资源缺失"
	return ""

static func clear_image_dependencies(shape: Dictionary) -> void:
	# Geometry-only preflight excludes assets, but keeps authoritative city names and placement.
	# The final full validation still checks every IMAGE binding and content hash.
	if not shape.get("city_badges") is Dictionary: return
	for display in shape.city_badges.values():
		if display is Dictionary and display.get("icon", "AUTO") == "IMAGE": display.erase("icon")
