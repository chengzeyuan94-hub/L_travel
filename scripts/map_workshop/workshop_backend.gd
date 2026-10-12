extends RefCounted
## 地图工坊到正式规则、存储、目录和 3D 几何实现的适配层。
## 整合版本的三个 READY 常量均为 true：保存/安装/验证走 WP1，几何与刷新走 WP3，素材走构建后的 WP6a 目录。
## 下方保留的 STUB 分支只记录早期接口形状，不参与当前运行；不可通过关闭 READY 来绕过发布门槛。
## 放城、属性改动的候选提交由 workshop_mutations.gd 负责；改路、停靠点和换宿主 UI 仍待完成。

const WP1_READY := true          # 规则、存储与校验已接入整合分支
const WP3_READY := true          # 使用真实几何规则与布局推导
const WP6A_READY := true         # 使用版本化素材目录

const LAYOUT_PATH := "res://assets/merchant_board_claude/board_layout.json"
const CATALOGUE_PATH := "res://data/custom_map/catalogue_v1.json"
## WP6a 之前的灰盒目录：设计阶段定稿的目录草案（只在源码运行时有；导出包里 docs/ 被排除）
const DESIGN_CATALOGUE_PATH := "res://docs/design/map-editor-20260930/work/catalogue/catalogue.json"
const SCHEMA := "lshu.custom_map.v1"

## 产品默认（Carlos 待确认，DESIGN 第一部分）：D1 = 最多两对；D3 = 原城离家 ≤ 6 格、朝向 ±45°；D5 = 覆盖保存每次都问
const MAX_PAIRS := 2
const MAX_USER := 2
const R_MOVE := 6.0
const YAW_MAX := PI / 4.0
const ASK_EVERY_OVERWRITE := true

## 3.11 的门槛（起步值）
const BOUNDS_MIN := Vector2(4.0, 4.0)
const BOUNDS_MAX := Vector2(124.0, 55.6)
const CITY_GAP := 7.0
const LAND_SHARE := 0.9
const ROUTE_CLEAR_EXTRA := 0.6
const ROUTE_LAND_SHARE := 0.99
const ROUTE_WET_RUN := 0.3
const ROUTE_END_SKIP := 1.0
const SEA_LAND_CLEAR := 0.2
const BERTH_MAX := 3.2
const ROUTE_GAP := 1.0
const ROUTE_SHARED_R := 4.0
const RUBBER_SPAN := 0.45        # 橡皮筋的影响长度 = 0.45 L（3.10.3 第 4 步）

## 3.11 表里的孩子话（{name} 换成城名）
const KID := {
	"G_BOUNDS": "太靠边啦",
	"G_CITY_LAND": "城要放在陆地上",
	"G_COAST": "海港城要挨着大海",
	"G_CITY_GAP": "离{name}太近了",
	"G_CITY_ON_ROUTE": "这里压到了商路",
	"G_PEAK": "这里是大山，城建不上去",
	"G_SLOPE": "这里太陡了",
	"G_ROUTE_LAND": "骆驼路不能下海",
	"G_ROUTE_SEA": "船会搁浅的",
	"G_ROUTE_CROSS": "两条路靠得太近，会看不清",
	"G_ROUTE_LEN": "这条路太长了",
	"G_STOP": "两个停靠点挤在一起了",
	"G_MOVE_FAR": "{name}只能在老家附近挪一挪",
	"G_STAND": "这里骆驼站不稳",
}


static func kid_text(code: String, name := "") -> String:
	return String(KID.get(code, "这里放不下")).replace("{name}", name)


static func issue(code: String, target: String, name := "", tech := "") -> Dictionary:
	return {"code": code, "target": target, "kid": kid_text(code, name), "tech": tech}


# ================================================================== 基础数据
static func load_base_layout() -> Dictionary:
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT_PATH))
	return d if d is Dictionary else {}


## 工坊里的 GameState.content：当前地图合并后的 content（3.12.1）。WP1 之前没有合并，只有原版
static func content_for(doc: Dictionary) -> Dictionary:
	if CustomMapFreeAuthor.enabled(doc):return CustomMapLoader.editor_preview(doc)
	var base := CustomMapLoader.base_content()
	if WP1_READY and not doc.is_empty():
		# 先登记（整份校验 + 放进缓存），再按 sha 从缓存合并（3.7、3.8）；不合格的图工坊里照样显示原版的 content
		var reg := CustomMapLoader.remember(doc)
		if bool(reg.get("ok", false)):
			var merged := base.duplicate(false)
			var r := CustomMapLoader.merge(merged, base, {"enabled": true, "sha256": String(reg.get("sha256", ""))})
			if bool(r.get("success", false)):
				return merged
	if CustomMapFreeRoutes.enabled(doc):return CustomMapLoader.editor_preview(doc)
	return base


# ================================================================== 文档：schema（WP1）
## 一张空地图（3.2 的形状）
static func empty_doc(map_name: String) -> Dictionary:
	if WP1_READY:
		var d := CustomMapSchema.empty_doc(map_name)
		d["map_id"] = new_map_id()
		return d
	# STUB（WP1 之前）：照 3.2 的字段拼一张
	var now := Time.get_datetime_string_from_system(false, false)
	return {
		"schema": SCHEMA,
		"map_id": new_map_id(),
		"name": map_name,
		"base": {"ruleset_id": "lshu_configurable_v1", "edition_id": "user_confirmed_v1", "graph_sig": "", "layout_sha256": layout_sha256()},
		"catalogue_version": 1,
		"tradegen": CustomMapSchema.TRADEGEN,
		"moves": {"cities": {}, "routes": {}},
		"new_cities": [],
		"generated": {"topology_key": "", "decks": []},
		"workshop": {"created_at": now, "updated_at": now, "app_version": str(ProjectSettings.get_setting("application/config/version", "0.1.0"))},
	}


## m_YYYYMMDD_HHMMSS_xxxx（3.2）
static func new_map_id() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "m_%04d%02d%02d_%02d%02d%02d_%04x" % [int(t.year), int(t.month), int(t.day), int(t.hour), int(t.minute), int(t.second), randi() % 65536]


static var _layout_sha := ""


static func layout_sha256() -> String:
	if _layout_sha == "":
		_layout_sha = FileAccess.get_sha256(LAYOUT_PATH)
	return _layout_sha


## 规范化文本（3.3）：撤销栈比较「文档字节」、未保存判断、导入时的 sha 都用它
static func canonical_text(doc: Dictionary) -> String:
	if WP1_READY:
		return CustomMapSchema.canonical_text(doc)
	# STUB：照 3.3 自己拼——键按字典序，数字一律 %.3f，整数字段按整数，去掉顶层 workshop
	var d := doc.duplicate(false)
	d.erase("workshop")
	return _canon(d, "")


const _INT_KEYS := ["card_number", "quantity", "catalogue_version"]


static func _canon(v: Variant, key: String) -> String:
	match typeof(v):
		TYPE_DICTIONARY:
			var keys: Array = (v as Dictionary).keys()
			keys.sort()
			var parts := PackedStringArray()
			for k in keys:
				parts.append("%s:%s" % [JSON.stringify(String(k)), _canon(v[k], String(k))])
			return "{" + ",".join(parts) + "}"
		TYPE_ARRAY:
			var parts := PackedStringArray()
			for x in v:
				parts.append(_canon(x, key))
			return "[" + ",".join(parts) + "]"
		TYPE_INT, TYPE_FLOAT:
			if key in _INT_KEYS:
				return str(int(round(float(v))))
			var s := "%.3f" % float(v)
			return "0.000" if s == "-0.000" else s
		TYPE_BOOL:
			return "true" if v else "false"
		TYPE_NIL:
			return "null"
		_:
			return JSON.stringify(String(v))


static func sha256(doc: Dictionary) -> String:
	if WP1_READY:
		return CustomMapSchema.sha256(doc)
	return canonical_text(doc).sha256_text()


## 所有坐标四舍五入到 0.001（3.3）
static func round3(v: float) -> float:
	return snappedf(v, 0.001)


# ================================================================== 校验（WP1 汇总 + WP3 几何）
## 整张图的检查：{ok, errors: [{code, target, kid, tech}], warnings, counts_win}
static func validate(base_layout: Dictionary, doc: Dictionary, geo: GeoStub, catalogue: Dictionary) -> Dictionary:
	if WP1_READY:
		var content := CustomMapLoader.base_content()
		return CustomMapValidator.validate(content, base_layout, doc, catalogue)
	# STUB：只有几何（原城的挪动）；新城、贸易卡、文字等 WP1 合入后才查
	var derived := derive(base_layout, doc, geo)
	var errors: Array[Dictionary] = []
	for cid in (doc.get("moves", {}).get("cities", {}) as Dictionary):
		errors.append_array(geo.check_city(derived, String(cid), false))
	return {"ok": errors.is_empty(), "errors": errors, "warnings": [], "counts_win": (doc.get("new_cities", []) as Array).is_empty()}


## 拖动时只查这一个对象（3.11「性能」：受影响对象的规则）
## Editor imports/exports may retain a safe v6 physical/connection draft.
## Game entry continues to use validate(), without this draft exception.
static func validate_for_editing(base_layout:Dictionary,doc:Dictionary,geo:GeoStub,catalogue:Dictionary)->Dictionary:
	var result:=validate(base_layout,doc,geo,catalogue)
	if CustomMapFreeAuthor.enabled(doc):
		var safe:=CustomMapFreeAuthor.finish(doc,CustomMapLoader.base_content(),base_layout,catalogue)
		if safe.get("ok",false):result.ok=true;result.editor_draft=not safe.validation.ok
		return result
	if result.ok or not CustomMapFreeRoutes.enabled(doc):return result
	for error:Dictionary in result.errors:
		if not str(error.code).begins_with("E_FREE_") and (not str(error.code).begins_with("G_") or str(error.code)=="G_DATA"):return result
	var safe:=CustomMapFreeRoutes.finish(doc,CustomMapLoader.base_content(),base_layout,catalogue)
	if not safe.get("ok",false):return result
	result.ok=true;result.editor_draft=true
	return result


static func check_city(derived: Dictionary, cid: String, geo: GeoStub, live: bool) -> Array[Dictionary]:
	if WP3_READY:
		return CustomMapGeoRules.check_object(derived, cid, CustomMapGeo.for_layout(derived), not live)
	return geo.check_city(derived, cid, live)


# ================================================================== 布局推导（WP3）
## 覆盖层 → 推导后的布局。没有任何改动时返回 base_layout 本身（3.10.3 第 0 步）。
## 拖动中、松手、数字框、提交后刷新，一律走这一个函数（R27：判断合格和真正画出来的是同一份推导）
static func derive(base_layout: Dictionary, doc: Dictionary, geo: GeoStub) -> Dictionary:
	if WP3_READY:
		geo.real_geo = CustomMapGeo.for_overlay(doc)
		return CustomBoardLayout.derive(base_layout, doc, geo.real_geo, load_catalogue())
	return geo.derive_moves(doc.get("moves", {}).get("cities", {}))


## 棋盘的几何对象：原布局的城、路、山（GeoStub 自己的表）+ 陆海采样（棋盘的 Paths）；WP3 合入后再挂上正式的 CustomMapGeo
static func geo_for(board_node: Node) -> GeoStub:
	var g := GeoStub.new(board_node.get("base_layout"), board_node.get("paths"))
	if WP3_READY:
		g.real_geo = CustomMapGeo.for_overlay(board_node.get("cur_doc"))
	return g


## 启动时要打开的那张图的推导布局（设进棋盘的 initial_layout_override，棋盘 _ready 只建一次世界，3.12.1 启动顺序）。
## WP3 之前推导要用棋盘运行时的采样，只能先建原版世界、再就地摆（返回 {} = 用原布局）
static func boot_layout(base_layout: Dictionary, doc: Dictionary) -> Dictionary:
	if not WP3_READY or doc.is_empty():
		return {}
	var d := CustomBoardLayout.derive(base_layout, doc, CustomMapGeo.for_overlay(doc), load_catalogue())
	return {} if d == base_layout else d


# ================================================================== 目录（WP6a 数据 + WP1 读取）
static var _catalogue: Dictionary = {}


## 目录（3.13.1 的形状）：{archetypes: [...], specialties: [...], known_names: [...], source}
static func load_catalogue(force := false) -> Dictionary:
	if not _catalogue.is_empty() and not force:
		return _catalogue
	if WP6A_READY or FileAccess.file_exists(CATALOGUE_PATH):
		var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOGUE_PATH))
		if d is Dictionary:
			_catalogue = d
			_catalogue["source"] = CATALOGUE_PATH
			return _catalogue
	_catalogue = _graybox_catalogue()
	return _catalogue


## STUB（WP6a 之前）：把设计阶段的目录草案（work/catalogue/catalogue.json）换成 3.13.1 的形状；全部标 draft，
## 没有模型、缩略图、卡图和图标（抽屉里画成纯色格子，照 WP6a「占位卡图和图标用纯色图」）
static func _graybox_catalogue() -> Dictionary:
	var out := {"schema": "lshu.map_catalogue.v1", "catalogue_version": 1, "archetypes": [], "specialties": [], "known_names": [],
		"source": DESIGN_CATALOGUE_PATH, "graybox": true}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(DESIGN_CATALOGUE_PATH)) if FileAccess.file_exists(DESIGN_CATALOGUE_PATH) else null
	if not (d is Dictionary):
		return out
	for a: Dictionary in d.get("archetypes", []):
		var rt := String(a.get("route_type", "LAND"))
		out.archetypes.append({
			"id": String(a.get("id", "")), "title": String(a.get("name_zh", "")),
			"style_side": "E" if String(a.get("side_hint", "")) == "east" else "W",
			"fits": ["LAND", "SEA"] if rt == "BOTH" else [rt], "status": "draft",
			"default_specialty": String(a.get("recommended_specialty", "")),
			"look": String(a.get("look_zh", "")), "colour": String(a.get("dominant_colour_zh", "")),
		})
	for s: Dictionary in d.get("specialties", []):
		out.specialties.append({
			"key": String(s.get("id", "")), "display_name": String(s.get("name_zh", "")),
			"flavor_side": "E" if String(s.get("side", "")) == "east" else "W",
			"hint": String(s.get("explain", "")), "status": "draft",
		})
	return out


## R30：开发开关 --catalogue-allow-draft，只在编辑器版 Godot 从源码运行时有效
static func allow_draft() -> bool:
	if WP1_READY:
		return CustomMapCatalogue.allow_draft()
	return OS.has_feature("editor") and ("--catalogue-allow-draft" in OS.get_cmdline_user_args() or "--catalogue-allow-draft" in OS.get_cmdline_args())


## 工坊只提供 shipped（开关下含 draft）
static func offered(entry: Dictionary) -> bool:
	var st := String(entry.get("status", ""))
	return st == "shipped" or (st == "draft" and allow_draft())


# ================================================================== 存储（WP1 的 CustomMapStore）
## 启动时的只读查询：WP1 之前当作「什么都没有」（骨架只会报「未实现」）
static func startup_library() -> Array:
	return CustomMapStore.list_library() if WP1_READY else []


static func startup_installed() -> Dictionary:
	return CustomMapStore.read_installed() if WP1_READY else {}


## 有自动存档的图的 map_id。5.2 没定 list_autosaves() 条目的形状：map_id 字符串，或带 map_id 的字典，两种都收
static func autosave_ids() -> Array:
	var out := []
	if not WP1_READY:
		return out
	for e in CustomMapStore.list_autosaves():
		var id := String(e.get("map_id", "")) if e is Dictionary else String(e)
		if id != "" and not (id in out):
			out.append(id)
	return out


## 自动存档的全文（list_autosaves 给的只是条目）
static func read_autosave(map_id: String) -> Dictionary:
	return CustomMapStore.read_autosave(map_id) if WP1_READY and map_id != "" else {}


## 库里存着的那一版（没有就是 {}）
static func load_saved(map_id: String) -> Dictionary:
	return CustomMapStore.load_map(map_id) if WP1_READY and map_id != "" else {}


## 每次改动后 1 秒内写自动存档（3.12.11）；WP1 之前不写（骨架写不了）
static func autosave(doc: Dictionary) -> Error:
	return CustomMapStore.write_autosave(doc) if WP1_READY else ERR_UNAVAILABLE


## 启动提示点了【不要了】：先把这份自动存档放进 trash/（「没保存的改动」），成功了才删自动存档文件（3.12.11、R26）。
## 5.2 的 store 没有「删自动存档」：这里按 3.1 的目录直接删 autosave/<map_id>.json（工坊只写 maps/，T-E7 允许）
static func discard_autosave(doc: Dictionary) -> Error:
	if not WP1_READY:
		return ERR_UNAVAILABLE
	var err := CustomMapStore.trash_doc(doc, "unsaved")
	if err != OK:
		return err
	var path := CustomMapStore.maps_dir().path_join("autosave").path_join("%s.json" % String(doc.get("map_id", "")))
	if FileAccess.file_exists(path):
		return DirAccess.remove_absolute(path)
	return OK


## maps/workshop_state.json：工坊自己的小状态（上次打开的 map_id，3.1）
static func read_workshop_state() -> Dictionary:
	if not WP1_READY:
		return {}
	var path := CustomMapStore.maps_dir().path_join("workshop_state.json")
	if not FileAccess.file_exists(path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


static func write_workshop_state(state: Dictionary) -> Error:
	if not WP1_READY:
		return ERR_UNAVAILABLE
	return CustomMapStore.atomic_write(CustomMapStore.maps_dir().path_join("workshop_state.json"), JSON.stringify(state, "\t"))


## 「我的地图」页签的卡片：工坊自己拼副标题（「2 座新城 · 10月1日」）、自己读缩略图（library/<map_id>.png，3.1）。
## 5.2 没定条目的形状，这里按 3.1 / 3.2 的字段读：map_id、name、sha256、new_city_count（或 new_cities 数组）、saved_at / updated_at
static func library_cards(entries: Array, installed_sha: String) -> Array:
	var out := []
	for e in entries:
		if not (e is Dictionary):
			continue
		var id := String(e.get("map_id", ""))
		var n := int(e.get("new_city_count", (e.get("new_cities", []) as Array).size() if e.get("new_cities") is Array else 0))
		out.append({"id": id, "map_id": id, "name": String(e.get("name", "")),
			"subtitle": "%s · %s" % ["没有新城" if n == 0 else "%d 座新城" % n, _day(e)],
			"thumb": _thumb("library", "%s.png" % id), "installed": installed_sha != "" and String(e.get("sha256", "")) == installed_sha,
			"entry": e})
	return out


## 「扔掉的地图」页签的卡片：写「扔掉的」「没保存的改动」「被换掉的」和时间；entry_id 缺了就按 3.1 的文件名 <map_id>.<sha 前 8 位>
static func trash_cards(entries: Array) -> Array:
	var out := []
	for e in entries:
		if not (e is Dictionary):
			continue
		var id := String(e.get("entry_id", ""))
		if id == "":
			id = "%s.%s" % [String(e.get("map_id", "")), String(e.get("sha256", "")).substr(0, 8)]
		var what: String = {"unsaved": "没保存的改动", "replaced": "被换掉的"}.get(String(e.get("kind", "")), "扔掉的")
		out.append({"id": id, "map_id": String(e.get("map_id", "")), "name": String(e.get("name", "")),
			"subtitle": "%s · %s" % [what, _day(e)], "thumb": null, "installed": false, "entry": e})
	return out


static func _day(e: Dictionary) -> String:
	var t := String(e.get("saved_at", e.get("updated_at", e.get("trashed_at", ""))))
	if t.length() < 10:
		return "不知道哪天"
	return "%d月%d日" % [int(t.substr(5, 2)), int(t.substr(8, 2))]


static func _thumb(sub: String, file: String) -> Texture2D:
	if not WP1_READY:
		return null
	var path := CustomMapStore.maps_dir().path_join(sub).path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	return ImageTexture.create_from_image(img) if img != null and not img.is_empty() else null


# ================================================================== STUB：几何规则 + 橡皮筋推导
## 第一阶段的本地替身：只管「原版城挪一挪」——城的几何规则（3.11 的城类 + 橡皮筋拉过的原版路）和橡皮筋推导（3.10.3 第 4 步）。
## 陆海判断用棋盘运行时的 Paths.water_clearance（sea_dist.png，和 paths.gd 同一个采样），不另写近似。
## WP3 合入后：check_city → CustomMapGeoRules.check_object，derive_moves → CustomBoardLayout.derive，本类整段删掉。
class GeoStub:
	extends RefCounted
	var base: Dictionary                 # 原布局（不改）
	var sampler                          # 有 water_clearance(x, z) 的对象（棋盘的 Paths）
	var real_geo = null                  # WP3_READY 时 geo_for() 在这里放 CustomMapGeo 实例（check_city / derive 转给正式函数用）
	var home := {}                       # city id -> 原布局里的 city 字典
	var ends := {}                       # route id -> [a, b]（离首尾点最近的城，同 paths.gd:58-59）
	var incident := {}                   # city id -> [route id]
	var cum := {}                        # route id -> PackedFloat32Array 弧长
	var peaks: Array = []                # [x, z, r]
	var mountains: Array = []            # 非森林类 kit：[x, z, r]
	var _other_grid := {}                # Vector2i(1 u 格) -> [[route id, x, z]]（原布局路线点，查路贴路）

	func _init(base_layout: Dictionary, s) -> void:
		base = base_layout
		sampler = s
		for c: Dictionary in base.get("cities", []):
			home[String(c.id)] = c
			incident[String(c.id)] = []
		for r: Dictionary in base.get("routes", []):
			var pts: Array = r.points
			var a := _nearest(pts[0])
			var b := _nearest(pts[pts.size() - 1])
			ends[String(r.id)] = [a, b]
			(incident[a] as Array).append(String(r.id))
			(incident[b] as Array).append(String(r.id))
			var c := PackedFloat32Array([0.0])
			for i in range(1, pts.size()):
				c.append(c[i - 1] + Vector2(float(pts[i][0]) - float(pts[i - 1][0]), float(pts[i][2]) - float(pts[i - 1][2])).length())
			cum[String(r.id)] = c
			for i in range(0, pts.size(), 4):
				var key := Vector2i(floori(float(pts[i][0])), floori(float(pts[i][2])))
				if not _other_grid.has(key):
					_other_grid[key] = []
				(_other_grid[key] as Array).append([String(r.id), float(pts[i][0]), float(pts[i][2])])
		for p: Dictionary in base.get("peaks", []):
			peaks.append([float(p.x), float(p.z), float(p.get("_r", 1.0))])
		for k: Dictionary in base.get("kit", []):
			if not String(k.get("asset", "")).begins_with("forest"):
				mountains.append([float(k.x), float(k.z), float(k.get("s", 1.0)) * 0.45])

	func _iss(code: String, target: String, name := "", tech := "") -> Dictionary:
		return {"code": code, "target": target, "kid": String(KID.get(code, "这里放不下")).replace("{name}", name), "tech": tech}

	func _nearest(q: Array) -> String:
		var best := ""
		var bd := INF
		for cid in home:
			var d := Vector2(float(q[0]) - float(home[cid].x), float(q[2]) - float(home[cid].z)).length()
			if d < bd:
				bd = d
				best = cid
		return best

	# ---------------------------------------------------------------- 推导（只做挪原城 + 橡皮筋）
	## moves = doc.moves.cities：{city id: {x, z, rotation}}。没挪任何城时返回 base 本身
	func derive_moves(moves: Dictionary) -> Dictionary:
		if moves.is_empty():
			return base
		var out := base.duplicate(false)
		var cities: Array = []
		for c: Dictionary in base.cities:
			var m: Dictionary = moves.get(String(c.id), {})
			if m.is_empty():
				cities.append(c)
				continue
			var nc := c.duplicate()
			nc.x = float(m.x)
			nc.z = float(m.z)
			nc.rotation = float(m.get("rotation", c.rotation))
			cities.append(nc)
		out.cities = cities
		var routes: Array = []
		var shifted := {}                # route id -> [Δa, Δb, L]
		for r: Dictionary in base.routes:
			var rid := String(r.id)
			var e: Array = ends[rid]
			var da := _delta(moves, String(e[0]))
			var db := _delta(moves, String(e[1]))
			if da == Vector2.ZERO and db == Vector2.ZERO:
				routes.append(r)
				continue
			var nr := r.duplicate()
			nr.erase("lane")                 # 改过的路线删掉 lane（3.10.3 第 4 步）
			var c: PackedFloat32Array = cum[rid]
			var L: float = c[c.size() - 1]
			var pts: Array = []
			for i in (r.points as Array).size():
				var q: Array = r.points[i]
				var o := _rubber(da, db, c[i], L)
				pts.append([float(q[0]) + o.x, float(q[1]), float(q[2]) + o.y])
			nr.points = pts
			routes.append(nr)
			shifted[rid] = [da, db, L]
		out.routes = routes
		var stops: Array = []
		for st: Dictionary in base.stops:
			var rid := _route_of_stop(String(st.id))
			if not shifted.has(rid):
				stops.append(st)
				continue
			var sh: Array = shifted[rid]
			var s := _arc_of(rid, float(st.x), float(st.z))
			var o := _rubber(sh[0], sh[1], s, sh[2])
			var ns := st.duplicate()
			ns.x = float(st.x) + o.x
			ns.z = float(st.z) + o.y
			stops.append(ns)
		out.stops = stops
		return out

	func _delta(moves: Dictionary, cid: String) -> Vector2:
		var m: Dictionary = moves.get(cid, {})
		if m.is_empty():
			return Vector2.ZERO
		return Vector2(float(m.x) - float(home[cid].x), float(m.z) - float(home[cid].z))

	## p'(s) = p(s) + Δa·w(s) + Δb·w(L - s)，w 在被挪的那一端从 1 平滑降到 0，影响长度 0.45 L
	func _rubber(da: Vector2, db: Vector2, s: float, L: float) -> Vector2:
		var span := maxf(L * RUBBER_SPAN, 0.01)
		var wa := 1.0 - smoothstep(0.0, span, s)
		var wb := 1.0 - smoothstep(0.0, span, L - s)
		return da * wa + db * wb

	func _route_of_stop(sid: String) -> String:
		for rid in ends:
			if sid.begins_with(String(rid) + "_"):
				return String(rid)
		return ""

	func _arc_of(rid: String, x: float, z: float) -> float:
		var pts: Array = []
		for r: Dictionary in base.routes:
			if String(r.id) == rid:
				pts = r.points
				break
		var c: PackedFloat32Array = cum[rid]
		var best := 0.0
		var bd := INF
		for i in pts.size():
			var d := Vector2(float(pts[i][0]) - x, float(pts[i][2]) - z).length_squared()
			if d < bd:
				bd = d
				best = c[i]
		return best

	# ---------------------------------------------------------------- 检查
	func land(x: float, z: float) -> bool:
		return float(sampler.water_clearance(x, z)) < 0.0

	## 一座原版城在推导后的布局里合不合格。live = 拖动中（路线点隔一个查一个）
	func check_city(derived: Dictionary, cid: String, live: bool) -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		var c: Dictionary = {}
		for cc: Dictionary in derived.cities:
			if String(cc.id) == cid:
				c = cc
				break
		if c.is_empty():
			return out
		var name := String(c.get("name", cid))
		var x := float(c.x)
		var z := float(c.z)
		var foot := float(c.get("foot", 3.5))
		var h: Dictionary = home.get(cid, c)
		# G_MOVE_FAR：离原位 ≤ R_move，朝向 ±45°
		var moved := Vector2(x - float(h.x), z - float(h.z)).length()
		if moved > R_MOVE + 0.0015 or absf(float(c.get("rotation", 0.0)) - float(h.get("rotation", 0.0))) > YAW_MAX + 0.0015:
			out.append(_iss("G_MOVE_FAR", cid, name, "moved %.2f" % moved))
		# G_BOUNDS
		if x < BOUNDS_MIN.x or x > BOUNDS_MAX.x or z < BOUNDS_MIN.y or z > BOUNDS_MAX.y:
			out.append(_iss("G_BOUNDS", cid, name))
		# G_CITY_GAP：城心距 ≥ 7.0（报最近那座的名字）
		var near := ""
		var nd := INF
		for o: Dictionary in derived.cities:
			if String(o.id) == cid:
				continue
			var d := Vector2(float(o.x) - x, float(o.z) - z).length()
			if d < nd:
				nd = d
				near = String(o.get("name", o.id))
		if nd < CITY_GAP:
			out.append(_iss("G_CITY_GAP", cid, near, "gap %.2f" % nd))
		# G_CITY_LAND：占地椭圆（rx = 0.45 foot，rz = 0.38 foot）里 ≥ 90% 的采样点在陆上
		var n := 0
		var dry := 0
		for i in 9:
			for j in 9:
				var u := (i / 8.0) * 2.0 - 1.0
				var v := (j / 8.0) * 2.0 - 1.0
				if u * u + v * v > 1.0:
					continue
				n += 1
				if land(x + u * 0.45 * foot, z + v * 0.38 * foot):
					dry += 1
		if n > 0 and float(dry) / n < LAND_SHARE:
			out.append(_iss("G_CITY_LAND", cid, name, "land %.2f" % (float(dry) / n)))
		# G_PEAK：占地椭圆不碰山
		for p: Array in peaks + mountains:
			var dx := (float(p[0]) - x) / (0.45 * foot + float(p[2]))
			var dz := (float(p[1]) - z) / (0.38 * foot + float(p[2]))
			if dx * dx + dz * dz < 1.0:
				out.append(_iss("G_PEAK", cid, name))
				break
		# G_CITY_ON_ROUTE：城心到任何别的城的路线 ≥ foot/2 + 0.6
		var clear := foot * 0.5 + ROUTE_CLEAR_EXTRA
		var mine: Array = incident.get(cid, [])
		for r: Dictionary in derived.routes:
			if String(r.id) in mine:
				continue
			var pts: Array = r.points
			var hit := false
			for i in range(0, pts.size(), 2):
				if absf(float(pts[i][0]) - x) < clear and absf(float(pts[i][2]) - z) < clear and Vector2(float(pts[i][0]) - x, float(pts[i][2]) - z).length() < clear:
					hit = true
					break
			if hit:
				out.append(_iss("G_CITY_ON_ROUTE", cid, name, String(r.id)))
				break
		# 被橡皮筋拉过的自己的路：陆路在陆上、海路不搁浅、不贴别的路
		var step := 2 if live else 1
		for r: Dictionary in derived.routes:
			if not (String(r.id) in mine):
				continue
			var code := _route_issue(r, step)
			if code != "":
				out.append(_iss(code, cid, name, String(r.id)))
				break
		# G_COAST：海港城边 3.2 u 以内能停下一条船（沿自己的海路找一处离岸够远的水面）
		for rid in mine:
			var r: Dictionary = _route(derived, String(rid))
			if String(r.get("type", "")) != "SEA":
				continue
			var ok := false
			for q: Array in r.points:
				var d := Vector2(float(q[0]) - x, float(q[2]) - z).length()
				if d <= foot * 0.5 + BERTH_MAX and float(sampler.water_clearance(float(q[0]), float(q[2]))) > SEA_LAND_CLEAR + 0.3:
					ok = true
					break
			if not ok:
				out.append(_iss("G_COAST", cid, name, String(rid)))
				break
		return out

	func _route(derived: Dictionary, rid: String) -> Dictionary:
		for r: Dictionary in derived.routes:
			if String(r.id) == rid:
				return r
		return {}

	## 一条被拉过的原版路：只查和原版不同的那一段（端点附近按 3.11 跳过），原版本身的点不重复算
	func _route_issue(r: Dictionary, step: int) -> String:
		var rid := String(r.id)
		var orig: Array = _route(base, rid).get("points", [])
		var pts: Array = r.points
		var c: PackedFloat32Array = cum[rid]
		var L: float = c[c.size() - 1]
		var sea := String(r.type) == "SEA"
		var skip := BERTH_MAX + 1.9 if sea else ROUTE_END_SKIP
		var wet_run := 0.0
		var wet := 0
		var n := 0
		var e: Array = ends[rid]
		for i in range(0, pts.size(), step):
			var s := c[i]
			if s < skip or s > L - skip:
				continue
			var q: Array = pts[i]
			if orig.size() == pts.size() and absf(float(q[0]) - float(orig[i][0])) < 1e-4 and absf(float(q[2]) - float(orig[i][2])) < 1e-4:
				wet_run = 0.0
				continue                     # 这一点没动：原版就是这样，不算
			n += 1
			var wc := float(sampler.water_clearance(float(q[0]), float(q[2])))
			if sea:
				if wc < SEA_LAND_CLEAR:
					return "G_ROUTE_SEA"
			else:
				if wc >= 0.0:
					wet += 1
					wet_run += 0.05 * step
					if wet_run > ROUTE_WET_RUN:
						return "G_ROUTE_LAND"
				else:
					wet_run = 0.0
			# 不贴别的路：共享城心 4 u 以外，离别的路 ≥ 1.0 u
			if i % 4 == 0:
				var key := Vector2i(floori(float(q[0])), floori(float(q[2])))
				for dx in range(-1, 2):
					for dz in range(-1, 2):
						for o: Array in _other_grid.get(key + Vector2i(dx, dz), []):
							var orid := String(o[0])
							if orid == rid:
								continue
							var d := Vector2(float(o[1]) - float(q[0]), float(o[2]) - float(q[2])).length()
							if d >= ROUTE_GAP:
								continue
							var shared := false
							for cid in ends[orid]:
								if cid in e and Vector2(float(q[0]) - float(home[cid].x), float(q[2]) - float(home[cid].z)).length() < ROUTE_SHARED_R + R_MOVE:
									shared = true
							if not shared:
								return "G_ROUTE_CROSS"
		if not sea and n > 0 and float(wet) / n > 1.0 - ROUTE_LAND_SHARE:
			return "G_ROUTE_LAND"
		return ""
