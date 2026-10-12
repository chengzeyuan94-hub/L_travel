class_name CustomMapCatalogue

## 素材目录 data/custom_map/catalogue_v1.json 的读取：按 id 查；只收 shipped / retired（开发开关下也收 draft，R30）；
## 补城兜底 first_fit（docs/design/map-editor-20260930/DESIGN.md 3.13）。归 WP1。
## 目录数据本身归 WP6a；这里只读。文件不在时（WP6a 合入之前）目录为空，任何带新城的地图都会报 E_ARCHETYPE。
##
## 两种「可用」：
##   is_usable  — 校验器收不收：shipped / retired，开关下含 draft（id 一旦发布含义永远不改，旧图里的 retired 条目照收）
##   is_offered — 工坊提供、自动补城挑选：shipped，开关下含 draft（retired 不再提供）

const PATH := "res://data/custom_map/catalogue_v1.json"
const SCHEMA := "lshu.map_catalogue.v1"
const DRAFT_FLAG := "--catalogue-allow-draft"

## 只给测试用：换一份目录文件（夹具目录），以及不带命令行参数时打开 draft
static var test_path := ""
static var test_allow_draft := false

static var _cache: Dictionary = {}
static var _cache_path := ""


## OS.has_feature("editor")（从源码用编辑器版 Godot 运行）且命令行带 --catalogue-allow-draft（R30）。
## 导出包没有 editor 特性，这个开关在任何导出包里都无效，发布版不可能收 draft。
static func allow_draft() -> bool:
	if not OS.has_feature("editor"):
		return false
	if test_allow_draft:
		return true
	return DRAFT_FLAG in OS.get_cmdline_user_args() or DRAFT_FLAG in OS.get_cmdline_args()


## shipped / retired 可用，开关下含 draft
static func is_usable(entry: Dictionary) -> bool:
	var status := str(entry.get("status", ""))
	return status == "shipped" or status == "retired" or (status == "draft" and allow_draft())


## 工坊提供、自动补城挑选：shipped，开关下含 draft
static func is_offered(entry: Dictionary) -> bool:
	var status := str(entry.get("status", ""))
	return status == "shipped" or (status == "draft" and allow_draft())


## 补城兜底：某一侧（"W" / "E"）、某种路线类型下第一个可提供的原型 id（排除 exclude）；没有返回 ""
static func first_fit(side: String, route_type: String, exclude: Array) -> String:
	return first_fit_in(data(), side, route_type, exclude)


static func first_fit_in(catalogue: Dictionary, side: String, route_type: String, exclude: Array) -> String:
	for a in catalogue.get("archetypes", []):
		if not a is Dictionary:
			continue
		var id := str(a.get("id", ""))
		if id in exclude or str(a.get("style_side", "")) != side:
			continue
		if not route_type in (a.get("fits", []) as Array):
			continue
		if is_offered(a):
			return id
	return ""


# ---------------------------------------------------------------- 读取与查找

## 整份目录（按路径缓存）；没有文件、坏了、schema 不对时返回 {}
static func data() -> Dictionary:
	var path := test_path if test_path != "" else PATH
	if path == _cache_path:
		return _cache
	_cache_path = path
	_cache = load_file(path)
	return _cache


static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or str((parsed as Dictionary).get("schema", "")) != SCHEMA:
		return {}
	return parsed


## 测试换了目录文件、或改了开关之后调
static func clear_cache() -> void:
	_cache = {}
	_cache_path = ""


static func archetype(catalogue: Dictionary, id: String) -> Dictionary:
	for a in catalogue.get("archetypes", []):
		if a is Dictionary and str(a.get("id", "")) == id:
			return a
	return {}


static func specialty(catalogue: Dictionary, key: String) -> Dictionary:
	for s in catalogue.get("specialties", []):
		if s is Dictionary and str(s.get("key", "")) == key:
			return s
	return {}


## 同一原型的骆驼版、商船版卡图分别绑定交通类型；旧目录没有分路字段时才读默认图。
static func card_art_for(archetype_entry: Dictionary, route_type: String) -> String:
	var by_route: Variant = archetype_entry.get("card_art_by_route")
	if by_route is Dictionary:
		return str(by_route.get(route_type, ""))
	return str(archetype_entry.get("card_art", ""))


## 「认得的名字」按名字找（孩子起的名字与任何一条完全相同就算认得，与宿主无关，3.13.4）
static func known_by_name(catalogue: Dictionary, name: String) -> Dictionary:
	for k in catalogue.get("known_names", []):
		if k is Dictionary and str(k.get("name", "")) == name:
			return k
	return {}


static func known_by_id(catalogue: Dictionary, id: String) -> Dictionary:
	for k in catalogue.get("known_names", []):
		if k is Dictionary and str(k.get("id", "")) == id:
			return k
	return {}


## 补城名单：partner_pool[宿主][路线类型] → 「认得的名字」条目 id 列表
static func partner_pool(catalogue: Dictionary, host: String, route_type: String) -> Array:
	var by_host: Variant = (catalogue.get("partner_pool", {}) as Dictionary).get(host, {})
	if not by_host is Dictionary:
		return []
	var ids: Variant = (by_host as Dictionary).get(route_type, [])
	return ids if ids is Array else []


## 预设位：preset_slots[宿主][路线类型] → [{x, z, rotation, route}]；只在目录记下的布局 sha 与当前一致时才有效
static func preset_slots(catalogue: Dictionary, host: String, route_type: String) -> Array:
	var ps: Dictionary = catalogue.get("preset_slots", {})
	if str(ps.get("layout_sha256", "")) != CustomMapSchema.layout_sha256():
		return []
	var by_host: Variant = ps.get(host, {})
	if not by_host is Dictionary:
		return []
	var slots: Variant = (by_host as Dictionary).get(route_type, [])
	return slots if slots is Array else []


## 某一侧的特产 key，按目录顺序
static func specialties_of_side(catalogue: Dictionary, side: String) -> Array[String]:
	var out: Array[String] = []
	for s in catalogue.get("specialties", []):
		if s is Dictionary and str(s.get("flavor_side", "")) == side:
			out.append(str(s.get("key", "")))
	return out
