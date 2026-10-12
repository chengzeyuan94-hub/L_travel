extends Node
## 自制地图素材目录的构建工具（docs/design/map-editor-20260930/DESIGN.md 3.13.6，WP6a）。无窗口运行。
## 读源文件 tools/custom_map/catalogue_src/catalogue_src_v1.json（原型、特产、认得的名字、补城名单、第一批名单），
## 按磁盘上有什么素材算出素材字段，跑完下面七步；任何一项不过，就不写 data/custom_map/catalogue_v1.json。
##   0. 源文件本身：id、状态、东西侧、第一批；补城名单 partner_pool 的键恰好是 19 个合格的「宿主 × 类型」，名单里每个名字
##      都是会补城（auto_pick）的认得的名字、side_hint 等于宿主那一侧、route_hint 等于类型，每个会补城的名字恰好在一个名单里；
##   1. 读每个原型的 GLB，算 bounds（building_width / building_depth / building_centre_xz），查最低点、夜灯材质、占地长宽比；
##      兜底小镇 _fallback_town.glb 也要能读（原型读不出来时棋盘用它顶上，DESIGN 3.6 ④、3.17）；
##   2. 查每个条目引用的文件都在：模型、卡图（陆海两用的原型两张）、缩略图、图标、兜底小镇；shipped 的条目不许用灰盒占位；
##   3. 核文字：24 个原型 × 24 种特产 × 适配的交通 × 两侧 × 名字 1–5 个字（外加 10 个字母的名字），
##      「自己写一句」按 4、19、20、40 字各拼一遍，「认得的名字」逐条核长度、图鉴字段和 https 来源；
##   4. 每个「宿主 × 类型」的预设位：WP3 的几何规则（CustomMapGeoRules）已经实现时用它验，并用它的自动画路写出路线控制点；
##      还是骨架时先做「初查」（同一套门槛的近似：棋盘范围、城距、占地在陆上、不压路不压山、海城临海、到宿主的直线距离、
##      粗网格上走得到），这时 build.preset_check = "prelim"，每个预设位 route_checked = false、路线控制点是空的；
##   5. 原布局上每个「宿主 × 类型」的可达区（绿区）预先算好，写 assets/custom_map/terrain/reach_<layout sha 前 8 位>.res
##      （只在 --write 时写文件）；WP3 还是骨架时推迟（工坊第一次进放城模式时现场算）；
##   6. 补城兜底自检：按 3.12.5 第 3–4 步，在「开发开关打开（含 draft）」「只发第一批」「当前发布状态」三种状态下，
##      对每个补城名单和同侧备选名逐个解析到可用的原型和特产；解析不到就报告并拒绝写目录；
##   7. 列出 R6 + R9 的全部一对接法（46 种）和预设位是否都有，写进目录的 topologies_v1，交给模拟（4.4）。
##
## 目录里比 DESIGN 3.13.1 例子多出来的字段（WP1、WP3、WP4 读目录时照这里）：
##   archetypes[].card_art_by_route  {LAND, SEA} → 卡图。陆海两用的原型有两张（骆驼版、商船版），新城的卡图按
##                                  card_art_by_route[route_type] 取；card_art 只是 fits[0] 那一张（陆海两用时是骆驼版）；
##   archetypes[].placeholder / specialties[].placeholder  还在用灰盒占位素材（shipped 的条目不许为 true）；
##   specialties[].supply_total     每种新货 10 件（R17）；
##   known_names[].auto_pick        true = 会被系统拿去补城；false = 只「认得」（景德镇等 7 座），补城兜底绝不取它；
##   known_names[].route_hint       这座真实城市是陆城还是港口；补城名单按它归到对应类型的名单里；
##   fallback_town                  {model, bounds, foot, placeholder}：原型 GLB 读不出来时顶上的小镇；
##   preset_slots                   除 layout_sha256 以外，键都是宿主 id；每个预设位带 route_checked（初查时为 false：
##                                  只能当参考点，路要现场画），for_name（这个位置按哪座真实城市的方位找的，可以为空）；
##   preset_slots_conflicts         [{a: [宿主, 类型, 下标], b: [...], dist}]：不同宿主的两个预设位挨得太近，两对新城
##                                  （D1-B）不能同时用；
##   topologies_v1                  一对接法清单；初查阶段 DESIGN R9 说放不下城的接法带 doubt；
##   first_batch、build             第一批名单；构建信息（preset_check = prelim / geo_rules、reach_cache、计数）。
##
## 用法（worktree 根目录；HOME 指到 scratch）：
##   godot --headless --path . res://tools/custom_map/build_catalogue.tscn -- [--write] [--verify] [--graybox]
##         [--report=<abs json>] [--set-status=<draft|shipped|retired>:<id,id,...>]
##     不带参数：只跑检查，不写文件；
##     --write     全部通过才写 data/custom_map/catalogue_v1.json；
##     --verify    重新构建，并要求与仓库里的 catalogue_v1.json 逐字节相同（防止改了源文件却忘了重跑）；
##     --graybox   先生成灰盒占位图（纯色卡图、缩略图、图标，写进 assets/custom_map/graybox/），之后要跑一次 --import；
##     --set-status 改源文件里条目的状态（WP6b 素材合格后用它改成 shipped，再跑 --write）。
## 最后一行是 BUILD_CATALOGUE ok … 或 BUILD_CATALOGUE FAILED errors=N；失败时退出码 1。

const Paths := preload("res://tools/merchant_board_claude_paths.gd")

const SRC := "res://tools/custom_map/catalogue_src/catalogue_src_v1.json"
const OUT := "res://data/custom_map/catalogue_v1.json"
const LAYOUT := "res://assets/merchant_board_claude/board_layout.json"
const SRC_SCHEMA := "lshu.map_catalogue_src.v1"
const SCHEMA := "lshu.map_catalogue.v1"

## 默认素材路径（DESIGN 3.13.1、3.13.5）；源文件 assets 显式映射 me-assets 的语义名产物时优先使用该映射。
## 缺失的真实素材仍回退灰盒并标 placeholder，shipped 门禁不会因为映射存在而被绕过。
const MODEL_DIR := "res://assets/merchant_board_claude/catalogue/"
const CARD_DIR := "res://assets/custom_map/cards/"
const THUMB_DIR := "res://assets/custom_map/thumbs/"
const GOODS_DIR := "res://assets/custom_map/goods/"
## 灰盒占位（纯色图）；模型的占位直接指向 assets/game/lowpoly/cities/*.glb（源文件里的 graybox_model）
const GRAYBOX_DIR := "res://assets/custom_map/graybox/"
const REACH_DIR := "res://assets/custom_map/terrain/"
## 原型 GLB 读不出来时顶上的小镇（DESIGN 3.6 review.gd ④、3.17）。灰盒由 WP6a 提供：--graybox 从源文件的
## defaults.fallback_graybox_model 复制过来（已经在就不动）；WP6b 换成正式模型后 fallback_town.placeholder 自动变 false
const FALLBACK_MODEL := MODEL_DIR + "_fallback_town.glb"
const KEEP_IMPORT := "[remap]\n\nimporter=\"keep\"\n"

const STATUSES := ["draft", "shipped", "retired"]
const ROUTES := ["LAND", "SEA"]
const SIDES := ["W", "E"]
## 3.3 拓扑键
const TOPO_PREFIX := "topo_v1"

## 第 1 步的门槛（3.13.5 第 3、4 步）；夜灯正则与 tools/merchant_board_claude_review.gd:1252 相同
const NIGHT_RE := "(^|_)Dark(\\.|_|$)|DeepArch|Entry_Reveal|CedarDoor|EntryFrameShade|PagodaReveal|EaveUnderside"
const MIN_NIGHT_MATERIALS := 3
const MIN_LOWEST_Y := -0.05
const MAX_FOOT_ASPECT := 1.3

## 第 3 步：名字样本（1–5 个汉字，外加 10 个字母；都不在「认得的名字」里，走模板）和「自己写一句」的样本长度
const NAME_SAMPLES: Array[String] = ["甲", "甲乙", "甲乙丙", "甲乙丙丁", "甲乙丙丁戊", "Qwertyuiop"]
const LINE_SAMPLE_LENGTHS: Array[int] = [4, 19, 20, 40]
const LINE_FILL := "我的家乡有很多好吃的东西还有一条小河河边有大树树下有小狗小狗会唱歌唱得真好听"
const SCENERY_RANGE := Vector2i(15, 30)
const NOUN_MAX := 5
const SPECIALTY_NAME_MAX := 3
const KNOWN_NAME_MAX := 5
const LORE_RANGES := {
	"epithet": Vector2i(8, 16), "position": Vector2i(20, 60), "history": Vector2i(70, 170), "sights": Vector2i(30, 90),
}

## 第 4 步「初查」的门槛（3.11 的起步值；WP3 合入后以 CustomMapGeoRules 为准）
const BOARD_X := Vector2(4.0, 124.0)
const BOARD_Z := Vector2(4.0, 55.6)
const CITY_GAP := 7.0
const GAP_MARGIN := 0.2
const LAND_FRACTION := 0.9
const ROUTE_CLEAR_EXTRA := 0.6
const BERTH_MAX := 3.2
const BERTH_CLEAR := 0.7
const HOST_DIST := Vector2(7.5, 20.0)
const NUDGE_RADIUS := 4.0
const GRID := 0.25
const MAX_SLOTS := 3
## R9：一对新城的宿主至少隔 9 步，平均步数相差不超过 2.0；R6：宿主挂之前度数 ≤ 3
const PAIR_MIN_STEPS := 9
const PAIR_MAX_AVG_DIFF := 2.0
const HOST_MAX_DEGREE := 3
## 自动补城兜底自检里「本图已占用」的特产数：最多 4 座新城（D1-B 两对），补一座时别的新城最多占 3 种
const MAX_OTHER_NEW_CITIES := 3
## DESIGN R9 验收：按 UX 方案的空位实测，这 4 种「宿主 × 类型」附近放不下城。初查给它们找到了位置，但初查只是近似，
## 所以初查阶段在 topologies_v1 里给涉及它们的接法标 doubt，以 WP3 几何规则的结果为准
const DESIGN_NO_ROOM := {"rome|LAND": true, "geumseong|LAND": true, "jeddah|SEA": true, "chenla|SEA": true}

## 骨架标记：WP0 的骨架函数体只有这一行（DESIGN 5.1），用来判断 WP3 的几何规则是否已经实现
const SKELETON_MARK := "push_error(\"未实现\")"
const WP3_SCRIPTS: Array[String] = [
	"res://scripts/custom_map/custom_map_geo.gd",
	"res://scripts/custom_map/custom_map_geo_rules.gd",
	"res://scripts/custom_map/custom_board_layout.gd",
]

var _errors: Array[String] = []
var _warnings: Array[String] = []
var _report := {}


func _ready() -> void:
	call_deferred("_main")


func _main() -> void:
	var args := OS.get_cmdline_user_args()
	var do_write := args.has("--write")
	var do_verify := args.has("--verify")
	var report_path := ""
	for a in args:
		if a.begins_with("--report="):
			report_path = a.trim_prefix("--report=")
	var src := read_json(SRC)
	if src.is_empty():
		_fail("源文件读不出来：%s" % SRC)
		_finish(report_path)
		return
	for a in args:
		if a.begins_with("--set-status="):
			_set_status(src, a.trim_prefix("--set-status="))
	if args.has("--graybox"):
		make_graybox(src)
	# 可达区缓存只在 --write 时写文件；--verify 和不带参数的检查不碰仓库
	var built := build(src, {"write_cache": do_write})
	_errors.append_array(built.errors)
	_warnings.append_array(built.warnings)
	_report = built.report
	var text := pretty_json(built.catalogue) + "\n"
	if _errors.is_empty() and do_verify:
		var on_disk := FileAccess.get_file_as_string(OUT)
		if on_disk != text:
			_fail("--verify：%s 与源文件重新构建的结果不同（改了源文件或素材之后要再跑 --write）" % OUT)
		else:
			print("BUILD_CATALOGUE verify: %s 与重新构建的结果逐字节相同" % OUT)
	if _errors.is_empty() and do_write:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT.get_base_dir()))
		var f := FileAccess.open(OUT, FileAccess.WRITE)
		if f == null:
			_fail("写不了 %s" % OUT)
		else:
			f.store_string(text)
			f.close()
			print("BUILD_CATALOGUE wrote %s sha256=%s bytes=%d" % [OUT, text.sha256_text(), text.to_utf8_buffer().size()])
	_finish(report_path)


func _finish(report_path: String) -> void:
	for w in _warnings:
		print("WARN: %s" % w)
	for e in _errors:
		print("ERROR: %s" % e)
	if not report_path.is_empty():
		var doc := {"errors": _errors, "warnings": _warnings, "report": _report}
		var f := FileAccess.open(report_path, FileAccess.WRITE)
		if f != null:
			f.store_string(pretty_json(doc) + "\n")
			f.close()
	if _errors.is_empty():
		print("BUILD_CATALOGUE ok warnings=%d" % _warnings.size())
	else:
		print("BUILD_CATALOGUE FAILED errors=%d" % _errors.size())
	get_tree().quit(0 if _errors.is_empty() else 1)


func _fail(msg: String) -> void:
	_errors.append(msg)


# ============================================================================ 构建（七步）
## 从源文件构建目录。返回 {catalogue, errors, warnings, report}。opts：
##   run_geo（默认 true）：跑第 4、5 步。false 时预设位、冲突表、preset_check、reach_cache 从 opts.previous（仓库里现有的目录）
##     原样透传，其余照常构建。单元测试用它：WP3 合入之后第 4 步要对每个格点做推导、自动画路和几何检查，太慢；
##   write_cache（默认 false）：第 5 步真的算可达区并写 .res。只有 --write 传 true；其余情况只记路径、查文件在不在。
static func build(src: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var errs: Array[String] = []
	var warns: Array[String] = []
	var ctx := {"errors": errs, "warnings": warns, "report": {}}
	var run_geo := bool(opts.get("run_geo", true))
	var previous: Dictionary = opts.get("previous", {})
	var base := GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var layout_text := FileAccess.get_file_as_string(LAYOUT)
	var layout: Dictionary = JSON.parse_string(layout_text) if not layout_text.is_empty() else {}
	var layout_sha := FileAccess.get_sha256(LAYOUT)
	_check_src(src, base, ctx)
	var cat := assemble(src)
	_step1_models(cat, ctx)
	_step2_files(cat, ctx)
	_step3_texts(cat, base, ctx)
	var geo_topo := base_graph(base)
	var preset_check := ""
	var reach := ""
	if run_geo:
		var wp3 := wp3_ready()
		preset_check = "geo_rules" if wp3 else "prelim"
		var presets := _step4_presets(cat, src, base, layout, layout_sha, geo_topo, wp3, ctx)
		cat["preset_slots"] = presets.slots
		cat["preset_slots_conflicts"] = presets.conflicts
		reach = _step5_reach(cat, layout, layout_sha, geo_topo, wp3, bool(opts.get("write_cache", false)), ctx)
	else:
		var prev_build: Dictionary = previous.get("build", {})
		preset_check = String(prev_build.get("preset_check", ""))
		reach = String(prev_build.get("reach_cache", ""))
		cat["preset_slots"] = (previous.get("preset_slots", {}) as Dictionary).duplicate(true)
		# JSON 读回来的整数是 float（Godot 4.7 把 1 读成 1.0）：冲突表里的下标要换回整数，输出才和 --write 逐字节相同
		var conflicts := (previous.get("preset_slots_conflicts", []) as Array).duplicate(true)
		for c in conflicts:
			for side in ["a", "b"]:
				if c is Dictionary and c.get(side) is Array and (c[side] as Array).size() == 3:
					c[side][2] = int(c[side][2])
		cat["preset_slots_conflicts"] = conflicts
		ctx.report["step4_presets"] = {"state": "passthrough", "preset_check": preset_check}
		ctx.report["step5_reach"] = {"state": "passthrough", "path": reach}
	_step6_fallback(cat, geo_topo, ctx)
	cat["topologies_v1"] = _step7_pairs(cat, geo_topo, preset_check, ctx)
	cat["build"] = {
		"tool": "tools/custom_map/build_catalogue.gd",
		"source": SRC.trim_prefix("res://"),
		"layout_sha256": layout_sha,
		"preset_check": preset_check,
		"reach_cache": reach,
		"counts": {
			"archetypes": (cat.archetypes as Array).size(),
			"specialties": (cat.specialties as Array).size(),
			"known_names": (cat.known_names as Array).size(),
			"shipped_archetypes": _count_status(cat.archetypes, "shipped"),
			"shipped_specialties": _count_status(cat.specialties, "shipped"),
			"placeholder_archetypes": _count_flag(cat.archetypes, "placeholder"),
			"placeholder_specialties": _count_flag(cat.specialties, "placeholder"),
		},
	}
	return {"catalogue": cat, "errors": ctx.errors, "warnings": ctx.warnings, "report": ctx.report}


## 源文件 → 目录（素材字段按磁盘上有什么来定）。纯函数：同样的源文件和素材，输出的字典相同。
static func assemble(src: Dictionary) -> Dictionary:
	var cat := {
		"schema": SCHEMA,
		"catalogue_version": int(src.get("catalogue_version", 1)),
		"generator": "tools/custom_map/build_catalogue.gd",
		"source": SRC.trim_prefix("res://"),
		"first_batch": (src.get("first_batch", {}) as Dictionary).duplicate(true),
		"archetypes": [],
		"specialties": [],
		"known_names": [],
		"partner_pool": (src.get("partner_pool", {}) as Dictionary).duplicate(true),
	}
	var default_foot := float(src.get("defaults", {}).get("foot", 3.4))
	# 兜底小镇：bounds 在第 1 步填；和源文件里的灰盒来源逐字节相同就算占位
	var fb_src := String(src.get("defaults", {}).get("fallback_graybox_model", ""))
	cat["fallback_town"] = {
		"model": FALLBACK_MODEL,
		"bounds": {},
		"foot": default_foot,
		"placeholder": not FileAccess.file_exists(FALLBACK_MODEL) or (not fb_src.is_empty() and FileAccess.get_sha256(FALLBACK_MODEL) == FileAccess.get_sha256(fb_src)),
	}
	for a: Dictionary in src.get("archetypes", []):
		var id := String(a.get("id", ""))
		var fits: Array = a.get("fits", [])
		var assets: Dictionary = a.get("assets", {})
		var model := String(assets.get("model", MODEL_DIR + id + ".glb"))
		var placeholder := false
		if not FileAccess.file_exists(model):
			model = String(a.get("graybox_model", ""))
			placeholder = true
		var thumb := String(assets.get("thumb", THUMB_DIR + id + "_256.png"))
		if not FileAccess.file_exists(thumb):
			thumb = GRAYBOX_DIR + "thumbs/" + id + "_256.png"
			placeholder = true
		var by_route := {}
		for r in fits:
			var file_name := card_file_name(id, String(r), fits)
			var p := String((assets.get("card_art_by_route", {}) as Dictionary).get(String(r), CARD_DIR + file_name))
			if not FileAccess.file_exists(p):
				p = GRAYBOX_DIR + "cards/" + file_name
				placeholder = true
			by_route[String(r)] = p
		var e := {
			"id": id,
			"title": String(a.get("title", "")),
			"style_side": String(a.get("style_side", "")),
			"fits": fits.duplicate(),
			"status": String(a.get("status", "draft")),
			"default_specialty": String(a.get("default_specialty", "")),
			"model": model,
			"bounds": {},
			"foot": float(a.get("foot", default_foot)),
			"thumb": thumb,
			"card_art": String(by_route.get(String(fits[0]) if not fits.is_empty() else "LAND", "")),
			"card_art_by_route": by_route,
			"placeholder": placeholder,
			"noun": String(a.get("noun", "")),
			"epithet4": String(a.get("epithet4", "")),
			"scenery": String(a.get("scenery", "")),
			"historical_period": String(a.get("historical_period", "")),
			"card_prompt": (a.get("card_prompt", {}) as Dictionary).duplicate(true),
		}
		(cat.archetypes as Array).append(e)
	for s: Dictionary in src.get("specialties", []):
		var key := String(s.get("key", ""))
		var icon := String((s.get("assets", {}) as Dictionary).get("icon", GOODS_DIR + key + ".png"))
		var placeholder := false
		if not FileAccess.file_exists(icon):
			icon = GRAYBOX_DIR + "goods/" + key + ".png"
			placeholder = true
		(cat.specialties as Array).append({
			"key": key,
			"display_name": String(s.get("display_name", "")),
			"flavor_side": String(s.get("flavor_side", "")),
			"hint": String(s.get("hint", "")),
			"status": String(s.get("status", "draft")),
			"supply_total": 10,
			"icon": icon,
			"placeholder": placeholder,
		})
	for k: Dictionary in src.get("known_names", []):
		var e := {}
		for field in ["id", "name", "side_hint", "route_hint", "auto_pick", "archetype", "specialty", "intro", "scenery", "epithet",
				"history", "sights", "historical_period", "modern_reference", "source_refs"]:
			var v: Variant = k.get(field, "")
			e[field] = (v as Array).duplicate(true) if v is Array else v
		(cat.known_names as Array).append(e)
	return cat


## 卡图文件名：陆海两用的原型出骆驼版（<id>_1024x768.png）和商船版（<id>_sea_1024x768.png）；只有一种交通的只有一张
static func card_file_name(id: String, route: String, fits: Array) -> String:
	if route == "SEA" and fits.has("LAND"):
		return id + "_sea_1024x768.png"
	return id + "_1024x768.png"


# ---------------------------------------------------------------------------- 源文件的基本结构
static func _check_src(src: Dictionary, base: Dictionary, ctx: Dictionary) -> void:
	if String(src.get("schema", "")) != SRC_SCHEMA:
		ctx.errors.append("源文件 schema 不是 %s" % SRC_SCHEMA)
	var base_goods: Dictionary = base.get("goods", {})
	var base_names := {}
	for g in base_goods.values():
		base_names[String(g.get("display_name", ""))] = true
	var seen := {}
	var sides := {"W": 0, "E": 0}
	var re_id := RegEx.create_from_string("^a[we][0-9]{2}_[a-z][a-z0-9_]*$")
	for a: Dictionary in src.get("archetypes", []):
		var id := String(a.get("id", ""))
		if seen.has(id) or re_id.search(id) == null:
			ctx.errors.append("原型 id 重复或不合规：%s" % id)
		seen[id] = true
		if not STATUSES.has(String(a.get("status", ""))):
			ctx.errors.append("原型 %s 的 status 不对：%s" % [id, a.get("status")])
		var side := String(a.get("style_side", ""))
		if not SIDES.has(side) or not id.begins_with("a" + side.to_lower()):
			ctx.errors.append("原型 %s 的 style_side 不对：%s" % [id, side])
		else:
			sides[side] += 1
		var fits: Array = a.get("fits", [])
		if fits.is_empty() or fits.any(func(r): return not ROUTES.has(String(r))):
			ctx.errors.append("原型 %s 的 fits 不对：%s" % [id, str(fits)])
		if String(a.get("graybox_model", "")).is_empty():
			ctx.errors.append("原型 %s 没有灰盒占位模型" % id)
		var prompt: Dictionary = a.get("card_prompt", {})
		for key in ["LANDMARKS", "LOCAL_LIFE", "LSHU_ACTION", "TRANSPORT_PROP"]:
			if not prompt.has(key):
				ctx.errors.append("原型 %s 的 card_prompt 缺 %s" % [id, key])
	ctx.report["archetypes_by_side"] = sides
	var re_key := RegEx.create_from_string("^[a-z][a-z0-9_]*$")
	var spec_sides := {"W": 0, "E": 0}
	seen = {}
	for s: Dictionary in src.get("specialties", []):
		var key := String(s.get("key", ""))
		var name := String(s.get("display_name", ""))
		if seen.has(key) or re_key.search(key) == null or base_goods.has(key):
			ctx.errors.append("特产 key 重复、不合规或与原版货物同名：%s" % key)
		seen[key] = true
		if name.is_empty() or name.length() > SPECIALTY_NAME_MAX or base_names.has(name):
			ctx.errors.append("特产 %s 的名字不对（1–%d 个字，不能与原版 15 种货同名）：%s" % [key, SPECIALTY_NAME_MAX, name])
		if not STATUSES.has(String(s.get("status", ""))):
			ctx.errors.append("特产 %s 的 status 不对" % key)
		if not SIDES.has(String(s.get("flavor_side", ""))):
			ctx.errors.append("特产 %s 的 flavor_side 不对" % key)
		else:
			spec_sides[String(s.flavor_side)] += 1
		if String(s.get("hint", "")).strip_edges().is_empty():
			ctx.errors.append("特产 %s 没有一句话提示" % key)
	ctx.report["specialties_by_side"] = spec_sides
	var arch_ids := {}
	for a in src.get("archetypes", []):
		arch_ids[String(a.id)] = a
	for a in src.get("archetypes", []):
		if not seen.has(String(a.get("default_specialty", ""))):
			ctx.errors.append("原型 %s 的默认特产不在目录里：%s" % [a.id, a.get("default_specialty")])
	# 第一批：两侧都要有能当陆城、能当海港的原型（3.13.2：第一批里两侧都能补出海港城和陆城）
	var fb: Dictionary = src.get("first_batch", {})
	var fb_fit := {"W": {"LAND": 0, "SEA": 0}, "E": {"LAND": 0, "SEA": 0}}
	for id in fb.get("archetypes", []):
		if not arch_ids.has(String(id)):
			ctx.errors.append("第一批里的原型不在目录里：%s" % id)
			continue
		var a: Dictionary = arch_ids[String(id)]
		for r in a.fits:
			fb_fit[String(a.style_side)][String(r)] += 1
	for side in SIDES:
		for r in ROUTES:
			if int(fb_fit[side][r]) < 1:
				ctx.errors.append("第一批在 %s 侧没有能当 %s 城的原型" % [side, r])
	for key in fb.get("specialties", []):
		if not seen.has(String(key)):
			ctx.errors.append("第一批里的特产不在目录里：%s" % key)
	ctx.report["first_batch_fits"] = fb_fit
	_check_partner_pool(src, base, ctx)
	if String(src.get("defaults", {}).get("fallback_graybox_model", "")).is_empty():
		ctx.errors.append("源文件 defaults 里没有 fallback_graybox_model（兜底小镇的灰盒来源）")


## 补城名单（3.13.4、3.12.5 第 3 步）：
##   键恰好是 R6 合格的 19 个「宿主 × 类型」，不多不少，每个名单非空；
##   名单里每个 id 都是「认得的名字」，auto_pick 为真，side_hint 等于宿主那一侧，route_hint 等于类型；
##   每个会补城（auto_pick）的名字恰好出现在一个名单里（名单用完时的同侧备选也只从这些名字里取）。
## 不查的话，写错的 id 会被补城悄悄跳过，另一侧的名字会被照用（系统在阿丹旁边补出一座「高昌」）。
static func _check_partner_pool(src: Dictionary, base: Dictionary, ctx: Dictionary) -> void:
	var topo := base_graph(base)
	var want := {}
	for combo in topo.combos:
		want["%s|%s" % [combo.host, combo.route]] = combo
	var known := {}
	for k in src.get("known_names", []):
		if k is Dictionary:
			known[String(k.get("id", ""))] = k
	var pool_v: Variant = src.get("partner_pool", {})
	var pool: Dictionary = pool_v if pool_v is Dictionary else {}
	if not pool_v is Dictionary:
		ctx.errors.append("partner_pool 不是字典")
	var have := {}
	var listed := {}
	for host in pool:
		var by_route: Variant = pool[host]
		if not by_route is Dictionary:
			ctx.errors.append("partner_pool.%s 不是 {类型: [名字]}" % host)
			continue
		for route in by_route:
			var key := "%s|%s" % [host, route]
			if not want.has(key):
				ctx.errors.append("partner_pool 里的 %s·%s 不是合格的「宿主 × 类型」（R6）" % [host, route])
				continue
			have[key] = true
			var ids: Variant = by_route[route]
			if not ids is Array or (ids as Array).is_empty():
				ctx.errors.append("%s·%s 的补城名单是空的" % [host, route])
				continue
			for id in ids:
				var k: Dictionary = known.get(String(id), {})
				if k.is_empty():
					ctx.errors.append("%s·%s 的补城名单里有不认识的名字 id：%s" % [host, route, id])
					continue
				listed[String(id)] = int(listed.get(String(id), 0)) + 1
				if not bool(k.get("auto_pick", false)):
					ctx.errors.append("%s·%s 的补城名单里有只「认得」、不补城的名字：%s" % [host, route, id])
				if String(k.get("side_hint", "")) != String(want[key].side):
					ctx.errors.append("%s·%s 的补城名单里有另一侧的名字：%s（%s）" % [host, route, id, k.get("side_hint", "")])
				if String(k.get("route_hint", "")) != String(route):
					ctx.errors.append("%s·%s 的补城名单里有交通不符的名字：%s（%s）" % [host, route, id, k.get("route_hint", "")])
	for key in want:
		if not have.has(key):
			ctx.errors.append("%s 没有补城名单" % String(key).replace("|", "·"))
	for id in known:
		var k: Dictionary = known[id]
		if bool(k.get("auto_pick", false)) and int(listed.get(id, 0)) != 1:
			ctx.errors.append("会补城的名字 %s 在补城名单里出现了 %d 次（应当恰好 1 次）" % [id, int(listed.get(id, 0))])
	ctx.report["partner_pool"] = {"combos": have.size(), "names": listed.size()}


## 只查源文件（第 0 步），返回错误列表。测试用它核补城名单的反例，不用跑完整的七步
static func source_errors(src: Dictionary, base: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	var ctx := {"errors": errs, "warnings": [], "report": {}}
	_check_src(src, base, ctx)
	return errs


# ---------------------------------------------------------------------------- 第 1 步：模型
static func _step1_models(cat: Dictionary, ctx: Dictionary) -> void:
	var re_night := RegEx.create_from_string(NIGHT_RE)
	var rows := []
	for a: Dictionary in cat.archetypes:
		var path := String(a.model)
		var stats := glb_stats(path, re_night)
		if not bool(stats.get("ok", false)):
			ctx.errors.append("原型 %s 的模型读不出来：%s" % [a.id, path])
			continue
		a["bounds"] = stats.bounds
		var shipped := String(a.status) == "shipped"
		var problems: Array[String] = []
		if float(stats.lowest_y) < MIN_LOWEST_Y:
			problems.append("最低点 %.3f < %.2f（像是带了地台）" % [stats.lowest_y, MIN_LOWEST_Y])
		if int(stats.night_materials) < MIN_NIGHT_MATERIALS:
			problems.append("夜灯材质 %d 种 < %d" % [stats.night_materials, MIN_NIGHT_MATERIALS])
		if float(stats.aspect) > MAX_FOOT_ASPECT:
			problems.append("占地长宽比 %.2f > %.1f" % [stats.aspect, MAX_FOOT_ASPECT])
		if shipped:
			if bool(a.placeholder):
				ctx.errors.append("原型 %s 是 shipped，却还在用灰盒占位素材" % a.id)
			var imp := FileAccess.get_file_as_string(path + ".import")
			if not imp.contains("importer=\"keep\""):
				problems.append("%s.import 不是 importer=\"keep\"（导出包里读不到原始 GLB）" % path.get_file())
			for p in problems:
				ctx.errors.append("原型 %s：%s" % [a.id, p])
		rows.append({"id": a.id, "model": path, "placeholder": a.placeholder, "bounds": stats.bounds, "lowest_y": snappedf(stats.lowest_y, 0.001),
			"night_materials": stats.night_materials, "aspect": snappedf(stats.aspect, 0.01), "problems_if_shipped": problems})
	ctx.report["step1_models"] = rows
	# 兜底小镇：发布版也会用到（shipped 的原型 GLB 读不出来时），所以不论灰盒与否都要能读、导入方式必须是 keep
	var fb: Dictionary = cat.fallback_town
	var fb_stats := glb_stats(String(fb.model), re_night)
	if not bool(fb_stats.get("ok", false)):
		ctx.errors.append("兜底小镇读不出来：%s（灰盒阶段跑一次 --graybox 会从 defaults.fallback_graybox_model 复制）" % fb.model)
	else:
		fb["bounds"] = fb_stats.bounds
	ctx.report["step1_fallback_town"] = {"model": fb.model, "placeholder": fb.placeholder, "bounds": fb.bounds,
		"aspect": snappedf(float(fb_stats.get("aspect", 0.0)), 0.01), "lowest_y": snappedf(float(fb_stats.get("lowest_y", 0.0)), 0.001)}
	var draft_problem_count := rows.filter(func(r): return not (r.problems_if_shipped as Array).is_empty()).size()
	print("BUILD_CATALOGUE step1 models: %d read, bounds written; %d draft models would not pass the shipped checks (graybox placeholders are not checked); fallback town %s (%s)" % [
		rows.size(), draft_problem_count, "ok" if fb_stats.get("ok", false) else "UNREADABLE", "graybox" if fb.placeholder else "final"])


## GLB 的统计：与棋盘相同的读法（GLTFDocument 读原始文件，review.gd:643-650），AABB 按节点变换累加（review.gd:1195-1203）
static func glb_stats(res_path: String, re_night: RegEx) -> Dictionary:
	if res_path.is_empty() or not FileAccess.file_exists(res_path):
		return {"ok": false}
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(res_path), state) != OK:
		return {"ok": false}
	var root := doc.generate_scene(state) as Node3D
	if root == null:
		return {"ok": false}
	var acc := [null]
	var names := {}
	_walk(root, Transform3D.IDENTITY, acc, names)
	root.free()
	if acc[0] == null:
		return {"ok": false}
	var box: AABB = acc[0]
	var night := 0
	for n in names:
		if re_night.search(String(n)) != null:
			night += 1
	var w := box.size.x
	var d := box.size.z
	return {
		"ok": true,
		"bounds": {
			"building_width": snappedf(w, 0.001),
			"building_depth": snappedf(d, 0.001),
			"building_centre_xz": [snappedf(box.get_center().x, 0.001), snappedf(box.get_center().z, 0.001)],
		},
		"lowest_y": box.position.y,
		"night_materials": night,
		"aspect": maxf(w, d) / maxf(minf(w, d), 0.001),
	}


static func _walk(node: Node, xf: Transform3D, acc: Array, names: Dictionary) -> void:
	var here := xf
	if node is Node3D:
		here = xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mi := node as MeshInstance3D
		var box := here * mi.mesh.get_aabb()
		acc[0] = box if acc[0] == null else (acc[0] as AABB).merge(box)
		for si in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(si)
			if m != null and not String(m.resource_name).is_empty():
				names[String(m.resource_name)] = true
	for child in node.get_children():
		_walk(child, here, acc, names)


# ---------------------------------------------------------------------------- 第 2 步：文件
static func _step2_files(cat: Dictionary, ctx: Dictionary) -> void:
	var missing := 0
	var checked := 0
	for a: Dictionary in cat.archetypes:
		var files: Array = [String(a.model), String(a.thumb)]
		for p in (a.card_art_by_route as Dictionary).values():
			files.append(String(p))
		for p in files:
			checked += 1
			if not _asset_ok(String(p)):
				missing += 1
				ctx.errors.append("原型 %s 引用的文件不在（或还没导入）：%s" % [a.id, p])
	for s: Dictionary in cat.specialties:
		checked += 1
		if String(s.status) == "shipped" and bool(s.placeholder):
			ctx.errors.append("特产 %s 是 shipped，却还在用灰盒占位图标" % s.key)
		if not _asset_ok(String(s.icon)):
			missing += 1
			ctx.errors.append("特产 %s 的图标不在（或还没导入）：%s" % [s.key, s.icon])
	checked += 1
	var fb_path := String(cat.fallback_town.model)
	if not _asset_ok(fb_path):
		missing += 1
		ctx.errors.append("兜底小镇不在：%s" % fb_path)
	elif not FileAccess.get_file_as_string(fb_path + ".import").contains("importer=\"keep\""):
		ctx.errors.append("%s.import 不是 importer=\"keep\"（导出包里 GLTFDocument 读不到原始 GLB）" % fb_path.get_file())
	ctx.report["step2_files"] = {"checked": checked, "missing": missing}
	print("BUILD_CATALOGUE step2 files: %d referenced files, %d missing" % [checked, missing])


## 模型按原始文件读（GLTFDocument），只要文件在；图片按资源读（卡图解析器用 ResourceLoader.exists，
## formal_card_presentation_resolver.gd:43），所以必须已经导入
static func _asset_ok(path: String) -> bool:
	if path.is_empty():
		return false
	if path.ends_with(".glb"):
		return FileAccess.file_exists(path)
	return FileAccess.file_exists(path) and ResourceLoader.exists(path)


# ---------------------------------------------------------------------------- 第 3 步：文字
static func _step3_texts(cat: Dictionary, base: Dictionary, ctx: Dictionary) -> void:
	var r := text_matrix(cat, base)
	for e in r.errors:
		ctx.errors.append(String(e))
	ctx.report["step3_texts"] = r.summary
	print("BUILD_CATALOGUE step3 texts: template %d ok, custom %d ok, known names %d (sources %d, all https), positions %d, errors %d" % [
		r.summary.template, r.summary.custom, r.summary.known, r.summary.sources, r.summary.positions, r.errors.size()])


## 文字全组合检查（测试也调它）。返回 {errors: [...], summary: {...}}
static func text_matrix(cat: Dictionary, base: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var summary := {"template": 0, "custom": 0, "known": 0, "sources": 0, "positions": 0, "max_template_intro": 0, "max_total": 0}
	var goods_names: Array[String] = []
	for g in (base.get("goods", {}) as Dictionary).values():
		goods_names.append(String(g.get("display_name", "")))
	for s: Dictionary in cat.specialties:
		goods_names.append(String(s.display_name))
	# 原型自己的字段
	for a: Dictionary in cat.archetypes:
		var scen := String(a.scenery)
		if scen.length() < SCENERY_RANGE.x or scen.length() > SCENERY_RANGE.y:
			errors.append("原型 %s 的风貌 %d 字，不在 %d–%d" % [a.id, scen.length(), SCENERY_RANGE.x, SCENERY_RANGE.y])
		for g in goods_names:
			if scen.contains(g):
				errors.append("原型 %s 的风貌写了货名「%s」（玩家能换特产，写了就会对不上）" % [a.id, g])
		if String(a.noun).is_empty() or String(a.noun).length() > NOUN_MAX:
			errors.append("原型 %s 的称呼不对：%s" % [a.id, a.noun])
		if String(a.epithet4).length() != 4:
			errors.append("原型 %s 的四字别称不是 4 个字：%s" % [a.id, a.epithet4])
		if String(a.historical_period).strip_edges().is_empty():
			errors.append("原型 %s 没有 historical_period" % a.id)
		for t in [a.title, a.noun, a.epithet4, a.scenery, a.historical_period]:
			if not CustomMapCardText.blocked_word_in(String(t)).is_empty():
				errors.append("原型 %s 的文字命中不雅词表" % a.id)
	var host_name := _longest_host_name(base)
	# 模板：原型 × 特产 × 适配的交通 × 两侧 × 名字样本
	for a: Dictionary in cat.archetypes:
		for s: Dictionary in cat.specialties:
			for route in a.fits:
				for side in SIDES:
					for n in NAME_SAMPLES:
						var city := _city(n, String(a.id), String(s.key), String(route), {"mode": "AUTO"})
						var t := CustomMapCardText.texts_for(city, host_name, side, cat)
						summary.template += 1
						summary.max_template_intro = maxi(int(summary.max_template_intro), String(t.intro).length())
						summary.max_total = maxi(int(summary.max_total), String(t.intro).length() + String(t.scenery).length())
						if String(t.source) != CustomMapCardText.SOURCE_TEMPLATE:
							errors.append("名字样本「%s」被当成了认得的名字" % n)
						for e in CustomMapCardText.check(t):
							errors.append("模板 %s/%s/%s/%s/%s：%s" % [a.id, s.key, route, side, n, e.tech])
	# 「自己写一句」：4、19、20、40 字各拼一遍（交通不影响简介和风貌，只取第一种）
	for a: Dictionary in cat.archetypes:
		for s: Dictionary in cat.specialties:
			for side in SIDES:
				for n in NAME_SAMPLES:
					for L in LINE_SAMPLE_LENGTHS:
						var city := _city(n, String(a.id), String(s.key), String(a.fits[0]), {"mode": "CUSTOM", "line": LINE_FILL.substr(0, L)})
						var t := CustomMapCardText.texts_for(city, host_name, side, cat)
						summary.custom += 1
						summary.max_total = maxi(int(summary.max_total), String(t.intro).length() + String(t.scenery).length())
						for e in CustomMapCardText.check(t):
							errors.append("自己写一句 %s/%s/%s/%s/%d 字：%s" % [a.id, s.key, side, n, L, e.tech])
	# 位置句：每个合格的「宿主 × 类型」
	var topo := base_graph(base)
	for combo in topo.combos:
		var t := CustomMapCardText.texts_for(_city("甲", String(cat.archetypes[0].id), String(cat.specialties[0].key), String(combo.route), {"mode": "AUTO"}),
			String(base.cities[combo.host].display_name), String(combo.side), cat)
		summary.positions += 1
		var p := String(t.lore.position)
		if p.length() < LORE_RANGES.position.x or p.length() > LORE_RANGES.position.y:
			errors.append("位置句 %s/%s %d 字：%s" % [combo.host, combo.route, p.length(), p])
	# 认得的名字：逐条核
	var arch_ids := {}
	for a in cat.archetypes:
		arch_ids[String(a.id)] = true
	var spec_ids := {}
	for s in cat.specialties:
		spec_ids[String(s.key)] = true
	var base_city_names := {}
	for c in (base.get("cities", {}) as Dictionary).values():
		base_city_names[String(c.get("display_name", ""))] = true
	var seen_names := {}
	var seen_ids := {}
	for k: Dictionary in cat.known_names:
		summary.known += 1
		var id := String(k.id)
		var name := String(k.name)
		if seen_ids.has(id) or seen_names.has(name):
			errors.append("认得的名字重复：%s / %s" % [id, name])
		seen_ids[id] = true
		seen_names[name] = true
		if name.is_empty() or name.length() > KNOWN_NAME_MAX or base_city_names.has(name):
			errors.append("认得的名字 %s 不合规（1–%d 个字，不能与原版 16 城重名）：%s" % [id, KNOWN_NAME_MAX, name])
		if not arch_ids.has(String(k.archetype)) or not spec_ids.has(String(k.specialty)):
			errors.append("认得的名字 %s 的默认原型或特产不在目录里" % id)
		if not SIDES.has(String(k.side_hint)) or not ROUTES.has(String(k.route_hint)):
			errors.append("认得的名字 %s 的 side_hint / route_hint 不对" % id)
		var intro := String(k.intro)
		var scen := String(k.scenery)
		_len_err(errors, id, "简介", intro.length(), GameData.CARD_TEXT_INTRO_RANGE)
		_len_err(errors, id, "风貌", scen.length(), GameData.CARD_TEXT_SCENERY_RANGE)
		if intro.length() + scen.length() > GameData.CARD_TEXT_CITY_MAX:
			errors.append("认得的名字 %s 简介加风貌 %d 字，超过 %d" % [id, intro.length() + scen.length(), GameData.CARD_TEXT_CITY_MAX])
		for field in LORE_RANGES:
			if field == "position":
				continue
			_len_err(errors, id, field, String(k.get(field, "")).length(), LORE_RANGES[field])
		for field in ["historical_period", "modern_reference"]:
			if String(k.get(field, "")).strip_edges().is_empty():
				errors.append("认得的名字 %s 缺 %s" % [id, field])
		var refs: Array = k.get("source_refs", [])
		if refs.is_empty():
			errors.append("认得的名字 %s 没有来源" % id)
		for ref in refs:
			summary.sources += 1
			if not (ref is Dictionary) or String(ref.get("title", "")).strip_edges().is_empty() or not String(ref.get("url", "")).begins_with("https://"):
				errors.append("认得的名字 %s 的来源不是带标题的 https 链接：%s" % [id, str(ref)])
		for t in [name, intro, scen, k.epithet, k.history, k.sights]:
			if not CustomMapCardText.blocked_word_in(String(t)).is_empty():
				errors.append("认得的名字 %s 的文字命中不雅词表" % id)
		# 用默认特产时换成真实文字，挂在同侧每个合格宿主上都过卡面和图鉴检查
		for combo in topo.combos:
			if String(combo.side) != String(k.side_hint):
				continue
			var city := _city(name, String(k.archetype), String(k.specialty), String(combo.route), {"mode": "AUTO"})
			var t := CustomMapCardText.texts_for(city, String(base.cities[combo.host].display_name), String(combo.side), cat)
			if String(t.source) != CustomMapCardText.SOURCE_KNOWN or String(t.known_id) != id:
				errors.append("认得的名字 %s 用默认特产时没有换成真实文字" % id)
			for e in CustomMapCardText.check(t):
				errors.append("认得的名字 %s 挂 %s/%s：%s" % [id, combo.host, combo.route, e.tech])
	return {"errors": errors, "summary": summary}


static func _city(name: String, archetype: String, specialty: String, route: String, text: Dictionary) -> Dictionary:
	return {"slot": "e1", "name": name, "archetype": archetype, "specialty": specialty, "route_type": route, "text": text}


static func _len_err(errors: Array[String], id: String, field: String, n: int, bounds: Vector2i) -> void:
	if n < bounds.x or n > bounds.y:
		errors.append("认得的名字 %s 的 %s %d 字，不在 %d–%d" % [id, field, n, bounds.x, bounds.y])


static func _longest_host_name(base: Dictionary) -> String:
	var best := ""
	for c in (base.get("cities", {}) as Dictionary).values():
		var n := String(c.get("display_name", ""))
		if n.length() > best.length():
			best = n
	return best


# ---------------------------------------------------------------------------- 原版图：宿主、步数、东西
## {dist: {a: {b: 步数}}, avg: {城: 到其余 15 城的平均步数}, side: {城: W/E}, combos: [{host, route, side}]（R6 合格的「宿主 × 类型」）}
static func base_graph(base: Dictionary) -> Dictionary:
	var cities: Dictionary = base.get("cities", {})
	var adj := {}
	for e: Dictionary in base.get("board_edges", []):
		var a := String(e.a)
		var b := String(e.b)
		if not adj.has(a):
			adj[a] = []
		if not adj.has(b):
			adj[b] = []
		adj[a].append(b)
		adj[b].append(a)
	var dist := {}
	for c in cities:
		var d := {String(c): 0}
		var q: Array = [String(c)]
		var i := 0
		while i < q.size():
			var u: String = q[i]
			i += 1
			for v in adj.get(u, []):
				if not d.has(v):
					d[v] = int(d[u]) + 1
					q.append(v)
		dist[String(c)] = d
	var avg := {}
	var side := {}
	for c in cities:
		var s := 0
		for o in cities:
			if o != c:
				s += int(dist[String(c)][String(o)])
		avg[String(c)] = float(s) / float(cities.size() - 1)
		side[String(c)] = "W" if float(cities[c].map_position[0]) < 2048.0 else "E"
	var ids: Array = cities.keys()
	ids.sort()
	var combos := []
	for c in ids:
		if (adj.get(String(c), []) as Array).size() > HOST_MAX_DEGREE:
			continue
		for r in ROUTES:
			if (cities[c].allowed_routes as Array).has(r):
				combos.append({"host": String(c), "route": r, "side": side[String(c)]})
	return {"dist": dist, "avg": avg, "side": side, "combos": combos}


# ---------------------------------------------------------------------------- 第 4 步：预设位
static func wp3_ready() -> bool:
	for p in WP3_SCRIPTS:
		var s := load(p) as GDScript
		if s == null or s.source_code.contains(SKELETON_MARK):
			return false
	return true


static func _step4_presets(cat: Dictionary, src: Dictionary, base: Dictionary, layout: Dictionary, layout_sha: String, topo: Dictionary,
		wp3: bool, ctx: Dictionary) -> Dictionary:
	var paths = Paths.new()
	paths.build(layout)
	var known := {}
	for k in src.get("known_names", []):
		known[String(k.id)] = k
	# 除 layout_sha256（DESIGN 3.13.1 的例子就放在这里）之外，键都是宿主 id；检查方式记在 build.preset_check
	var out := {"layout_sha256": layout_sha}
	var geo_checked := "geo_rules" if wp3 else "prelim"
	var foot := float(src.get("defaults", {}).get("foot", 3.4))
	var pool: Dictionary = cat.get("partner_pool", {})
	var rows := []
	var empty_combos := []
	var all_slots := []
	for combo in topo.combos:
		var host := String(combo.host)
		var route := String(combo.route)
		var names: Array = (pool.get(host, {}) as Dictionary).get(route, [])
		if names.is_empty():
			ctx.warnings.append("%s·%s 的补城名单是空的：会退到同侧第一个没用过的认得的名字" % [host, route])
		var slots := []
		for kid in names:
			if slots.size() >= MAX_SLOTS:
				break
			var k: Dictionary = known.get(String(kid), {})
			if not k.has("seed_xz"):
				continue
			var seed := Vector2(clampf(float(k.seed_xz[0]), BOARD_X.x, BOARD_X.y), clampf(float(k.seed_xz[1]), BOARD_Z.x, BOARD_Z.y))
			var found := {}
			if wp3:
				found = _geo_rules_slot(cat, layout, host, route, seed, slots)
			else:
				found = _prelim_slot(paths, layout, host, route, seed, foot, NUDGE_RADIUS, slots)
				if found.is_empty():
					# 参考位置附近放不下：在宿主周围找离参考位置最近的合格格点（名字和位置大致对得上地理）
					found = _prelim_ring(paths, layout, host, route, foot, slots, seed)
					if not found.is_empty() and float(found.get("moved_from_seed", 0.0)) > MAX_SEED_MOVE:
						found = {}
			if not found.is_empty():
				found["for_name"] = String(kid)
				slots.append(found)
		if slots.is_empty():
			# 名单里没有位置参考（或参考位置附近放不下）：围着宿主找一个
			var h: Dictionary = paths.city.get(host, {})
			var found := {}
			if not h.is_empty():
				if wp3:
					found = _geo_rules_ring(cat, layout, host, route, slots)
				else:
					found = _prelim_ring(paths, layout, host, route, foot, slots, null)
			if not found.is_empty():
				# 名单里的名字在它们的真实方位附近都放不下：位置是围着宿主找的，不挂任何名字（名字仍按名单取，只是和位置对不上地理）
				found["for_name"] = ""
				slots.append(found)
		if slots.is_empty():
			empty_combos.append("%s·%s" % [host, route])
		else:
			if not out.has(host):
				out[host] = {}
			out[host][route] = slots
			for si in slots.size():
				all_slots.append({"host": host, "route": route, "index": si, "x": slots[si].x, "z": slots[si].z})
		var lines := []
		if not wp3:
			for sl in slots:
				lines.append(straight_line_stats(paths, layout, host, route, Vector2(float(sl.x), float(sl.z)), foot))
		rows.append({"host": host, "route": route, "slots": slots.size(), "for_names": slots.map(func(s): return s.get("for_name", "")),
			"nudged": slots.map(func(s): return s.get("nudged", "searched")), "straight_line": lines})
	# 不同宿主的两个预设位挨得太近：两对新城（D1-B）不能同时用这两个位置。同一接法里的几个位置在搜的时候已经互相隔开；
	# 同一座宿主只能挂一座新城（E_HOST），所以同宿主的不算。写进目录的 preset_slots_conflicts，给 pick_auto_partner 用
	var conflicts := []
	for i in all_slots.size():
		for j in range(i + 1, all_slots.size()):
			var a: Dictionary = all_slots[i]
			var b: Dictionary = all_slots[j]
			var d := Vector2(float(a.x), float(a.z)).distance_to(Vector2(float(b.x), float(b.z)))
			if String(a.host) != String(b.host) and d < CITY_GAP + GAP_MARGIN:
				conflicts.append({"a": [a.host, a.route, a.index], "b": [b.host, b.route, b.index], "dist": snappedf(d, 0.01)})
	var bad_lines := 0
	for r in rows:
		for st in r.straight_line:
			bad_lines += 0 if bool(st.clear) else 1
	ctx.report["step4_presets"] = {"geo_checked": geo_checked, "combos": rows, "no_slot": empty_combos, "conflicts": conflicts,
		"straight_line_not_clear": bad_lines}
	if not empty_combos.is_empty():
		if wp3:
			ctx.warnings.append("这些接法按 WP3 的几何规则找不到能放城的预设位（绿区里没有合格的位置）：%s" % ", ".join(empty_combos))
		else:
			ctx.warnings.append("这些接法初查找不到能放城的预设位：%s（最终以 WP3 的几何规则为准）" % ", ".join(empty_combos))
	var slot_count := 0
	for r in rows:
		slot_count += int(r.slots)
	print("BUILD_CATALOGUE step4 presets (%s): %d combos, %d slots, %d combos without a slot %s, %d conflicting slot pairs across hosts (closer than %.1f u)%s" % [
		geo_checked, rows.size(), slot_count, empty_combos.size(), str(empty_combos), conflicts.size(), CITY_GAP + GAP_MARGIN,
		("; %d geometry-rule tries (route from reach field + full check)" % geo_tries) if wp3 else "; WP3 geometry rules are still skeletons, so these are prelim checks only: route_checked=false, %d slots whose straight line to the host crosses water or peaks (routes must be drawn live)" % bad_lines])
	return {"slots": out, "conflicts": conflicts}


## 初查的诊断（只进报告）：宿主到预设位的直线上采 61 个点，数有几个点下水（陆路）/ 上岸（海路）、几个点进山。
## 两端各留一段不算：陆路是城的占地半径，海路再加靠岸距离（码头在岸边，线的两头本来就在陆上）
static func straight_line_stats(paths, layout: Dictionary, host: String, route: String, p: Vector2, foot: float) -> Dictionary:
	var hc: Dictionary = paths.city[host]
	var a := Vector2(float(hc.x), float(hc.z))
	var skip := foot * 0.5 + (BERTH_MAX if route == "SEA" else 0.0)
	var n := 61
	var off := 0
	var peak := 0
	var counted := 0
	for i in n:
		var q := a.lerp(p, float(i) / float(n - 1))
		if q.distance_to(a) < skip or q.distance_to(p) < skip:
			continue
		counted += 1
		var wc: float = paths.water_clearance(q.x, q.y)
		if (route == "LAND" and wc >= 0.0) or (route == "SEA" and wc < 0.0):
			off += 1
		if route == "LAND":
			for pk: Dictionary in layout.get("peaks", []):
				if Vector2(float(pk.x), float(pk.z)).distance_to(q) < float(pk.get("_r", 1.0)):
					peak += 1
					break
	return {"samples": counted, "off_medium": off, "in_peaks": peak, "clear": off == 0 and peak == 0}


## 初查一个候选位置：3.11 城市规则的近似（WP3 合入后以 CustomMapGeoRules.check 为准）
static func prelim_city_ok(paths, layout: Dictionary, host: String, route: String, p: Vector2, foot: float, others: Array) -> String:
	if p.x < BOARD_X.x or p.x > BOARD_X.y or p.y < BOARD_Z.x or p.y > BOARD_Z.y:
		return "G_BOUNDS"
	for c: Dictionary in layout.cities:
		if Vector2(float(c.x), float(c.z)).distance_to(p) < CITY_GAP + GAP_MARGIN:
			return "G_CITY_GAP"
	for s in others:
		if Vector2(float(s.x), float(s.z)).distance_to(p) < CITY_GAP + GAP_MARGIN:
			return "G_CITY_GAP(slot)"
	var h: Dictionary = paths.city[host]
	var hd := Vector2(float(h.x), float(h.z)).distance_to(p)
	if hd < HOST_DIST.x or hd > HOST_DIST.y:
		return "G_ROUTE_LEN"
	var rx := 0.45 * foot
	var rz := 0.38 * foot
	var n_all := 0
	var n_land := 0
	for i in 9:
		for j in 9:
			var u := lerpf(-1.0, 1.0, i / 8.0)
			var v := lerpf(-1.0, 1.0, j / 8.0)
			if u * u + v * v > 1.0:
				continue
			n_all += 1
			if paths.water_clearance(p.x + u * rx, p.y + v * rz) < 0.0:
				n_land += 1
	if float(n_land) < LAND_FRACTION * float(n_all):
		return "G_CITY_LAND"
	for pk: Dictionary in layout.get("peaks", []):
		if Vector2(float(pk.x), float(pk.z)).distance_to(p) < float(pk.get("_r", 1.0)) + rx:
			return "G_PEAK"
	var clear := foot * 0.5 + ROUTE_CLEAR_EXTRA
	for rid in paths.routes:
		var pts: PackedVector3Array = paths.routes[rid].pts
		# 路线点约 0.05 u 一个，隔 4 个取一个（误差 < 0.1 u，初查够用）
		for qi in range(0, pts.size(), 4):
			if Vector2(pts[qi].x, pts[qi].z).distance_to(p) < clear:
				return "G_CITY_ON_ROUTE"
	if route == "SEA":
		var coast := false
		for k in 24:
			var ang := TAU * k / 24.0
			var r := rx + 0.4
			while r <= rx + BERTH_MAX:
				if paths.water_clearance(p.x + cos(ang) * r, p.y + sin(ang) * r) >= BERTH_CLEAR:
					coast = true
					break
				r += 0.4
			if coast:
				break
		if not coast:
			return "G_COAST"
		if not _route_reachable(paths, layout, host, "SEA", p, rx + BERTH_MAX):
			return "G_ROUTE_SEA"
	elif not _route_reachable(paths, layout, host, "LAND", p, rx + 1.0):
		# 陆路：从宿主沿陆地（不进山）走 36 u 以内能到（真正的路由由 WP3 的自动画路给）
		return "G_ROUTE_LAND"
	return ""


## 路线初查：从宿主出发，海路沿水面（离岸 ≥ SEA_WATER_CLEAR）、陆路沿陆地且不进山（peaks 的圆），
## 走 ROUTE_MAX 以内能不能到候选城 reach 以内。0.5 u 网格、直走代价 2、斜走代价 3（1 个代价 = 0.25 u）的 Dial 最短路；
## 每座宿主、每种交通算一次，缓存在 _route_cache 里。这是 WP3 可达区（3.12.5「绿区怎么算」）的粗略替身，只给预设位初查用。
static var _route_cache := {}
const ROUTE_CELL := 0.5
const SEA_WATER_CLEAR := 0.3
const ROUTE_START_RADIUS := 5.0
const ROUTE_MAX := 36.0
## 参考位置（真实经纬度拟合出来的）挪到这么远还放不下，就不用这个名字的位置了（名字和位置对不上地理）
const MAX_SEED_MOVE := 6.0


static func _route_reachable(paths, layout: Dictionary, host: String, route: String, p: Vector2, reach: float) -> bool:
	var f := _route_field(paths, layout, host, route)
	var w: int = f.w
	var h: int = f.h
	var cost: PackedInt32Array = f.cost
	var limit := int(ROUTE_MAX / (ROUTE_CELL * 0.5))
	var r := int(ceil(reach / ROUTE_CELL))
	var ci := int(p.x / ROUTE_CELL)
	var cj := int(p.y / ROUTE_CELL)
	for j in range(maxi(cj - r, 0), mini(cj + r + 1, h)):
		for i in range(maxi(ci - r, 0), mini(ci + r + 1, w)):
			var c := cost[j * w + i]
			if c >= 0 and c <= limit and Vector2((i + 0.5) * ROUTE_CELL, (j + 0.5) * ROUTE_CELL).distance_to(p) <= reach:
				return true
	return false


static func _route_field(paths, layout: Dictionary, host: String, route: String) -> Dictionary:
	var key := host + "|" + route
	if _route_cache.has(key):
		return _route_cache[key]
	var w := int(ceil(128.0 / ROUTE_CELL))
	var h := int(ceil(59.63125 / ROUTE_CELL))
	var mask_key := "|mask|" + route
	if not _route_cache.has(mask_key):
		var m := PackedByteArray()
		m.resize(w * h)
		for j in h:
			for i in w:
				var x := (i + 0.5) * ROUTE_CELL
				var z := (j + 0.5) * ROUTE_CELL
				var wc: float = paths.water_clearance(x, z)
				var ok := wc >= SEA_WATER_CLEAR if route == "SEA" else wc < 0.0
				if ok and route == "LAND":
					for pk: Dictionary in layout.get("peaks", []):
						if Vector2(float(pk.x), float(pk.z)).distance_to(Vector2(x, z)) < float(pk.get("_r", 1.0)):
							ok = false
							break
				m[j * w + i] = 1 if ok else 0
		_route_cache[mask_key] = m
	var mask: PackedByteArray = _route_cache[mask_key]
	var limit := int(ROUTE_MAX / (ROUTE_CELL * 0.5))
	var cost := PackedInt32Array()
	cost.resize(w * h)
	cost.fill(-1)
	var buckets := []
	buckets.resize(limit + 4)
	for b in buckets.size():
		buckets[b] = []
	var hc: Dictionary = paths.city[host]
	var centre := Vector2(float(hc.x), float(hc.z))
	for j in h:
		for i in w:
			if mask[j * w + i] == 1 and Vector2((i + 0.5) * ROUTE_CELL, (j + 0.5) * ROUTE_CELL).distance_to(centre) <= ROUTE_START_RADIUS:
				cost[j * w + i] = 0
				buckets[0].append(j * w + i)
	var steps := [[1, 0, 2], [-1, 0, 2], [0, 1, 2], [0, -1, 2], [1, 1, 3], [1, -1, 3], [-1, 1, 3], [-1, -1, 3]]
	for c in range(limit + 1):
		var bucket: Array = buckets[c]
		for idx: int in bucket:
			if cost[idx] != c:
				continue
			var i := idx % w
			var j := idx / w
			for st in steps:
				var ni: int = i + int(st[0])
				var nj: int = j + int(st[1])
				if ni < 0 or nj < 0 or ni >= w or nj >= h:
					continue
				var n := nj * w + ni
				if mask[n] == 0:
					continue
				var nc := c + int(st[2])
				if nc > limit:
					continue
				if cost[n] == -1 or nc < cost[n]:
					cost[n] = nc
					buckets[nc].append(n)
	var f := {"w": w, "h": h, "cost": cost}
	_route_cache[key] = f
	return f


## 离参考位置由近到远找第一个过初查的格点（GRID 间距，半径 radius）
static func _prelim_slot(paths, layout: Dictionary, host: String, route: String, seed: Vector2, foot: float, radius: float, others: Array) -> Dictionary:
	for off: Vector2 in offsets_by_distance(radius, GRID):
		if prelim_city_ok(paths, layout, host, route, seed + off, foot, others).is_empty():
			return _slot(seed + off, off.length())
	return {}


## 围着宿主（HOST_DIST 的环里，0.5 u 格点）找：给了参考位置 seed 时取离它最近的合格格点，结果带 moved_from_seed；
## 没给时离宿主 9.5 u 左右最好、越靠近别的原城越差（给它们的邻居留地方）
static func _prelim_ring(paths, layout: Dictionary, host: String, route: String, foot: float, others: Array, seed: Variant) -> Dictionary:
	var h: Dictionary = paths.city[host]
	var c := Vector2(float(h.x), float(h.z))
	var cands := []
	var n := int(HOST_DIST.y / 0.5)
	for i in range(-n, n + 1):
		for j in range(-n, n + 1):
			var p := c + Vector2(i * 0.5, j * 0.5)
			var d := p.distance_to(c)
			if d < HOST_DIST.x or d > HOST_DIST.y:
				continue
			var score := 0.0
			if seed is Vector2:
				score = p.distance_to(seed)
			else:
				score = absf(d - 9.5)
				for oc: Dictionary in layout.cities:
					if String(oc.id) != host:
						score += 20.0 / maxf(Vector2(float(oc.x), float(oc.z)).distance_to(p), 1.0)
			cands.append([score, p.x, p.y])
	cands.sort()
	for cand in cands:
		var p := Vector2(float(cand[1]), float(cand[2]))
		if prelim_city_ok(paths, layout, host, route, p, foot, others).is_empty():
			var sl := _slot(p, -1.0)
			if seed is Vector2:
				sl["moved_from_seed"] = snappedf(p.distance_to(seed), 0.01)
			return sl
	return {}


## 半径以内的格点偏移，由近到远（同距离按 x、z 排，结果确定）
static func offsets_by_distance(radius: float, step: float) -> Array:
	var out := []
	var n := int(radius / step)
	for i in range(-n, n + 1):
		for j in range(-n, n + 1):
			var off := Vector2(i * step, j * step)
			if off.length() <= radius + 1e-6:
				out.append([off.length_squared(), off.x, off.y])
	out.sort()
	return out.map(func(t): return Vector2(float(t[1]), float(t[2])))


static func _slot(p: Vector2, nudged: float) -> Dictionary:
	var s := {
		"x": snappedf(p.x, 0.001),
		"z": snappedf(p.y, 0.001),
		"rotation": 0.0,
		"route": {"handles": [], "stop_t": [0.333, 0.667]},
		# 初查不画路：路线控制点是空的，只能当参考点，WP1 / WP4 用它时要现场自动画路（CustomMapGeoRules.auto_route）
		"route_checked": false,
	}
	if nudged >= 0.0:
		s["nudged"] = snappedf(nudged, 0.01)
	else:
		s["searched"] = true
	return s


## WP3 合入之后：用真正的几何规则验证 / 搜索预设位（接口见 DESIGN 5.2）。只有 wp3_ready() 为真时才会调到。
## 候选只取绿区（CustomMapGeoRules.feasible_zone，工坊里孩子也只能把城放在绿区里）的格点，由好到坏逐个试：
## 从这座宿主的可达区取路（reach_field + route_from_field，与工坊放城同一条路），推导整张图，再跑一遍全部几何规则
## （CustomMapGeoRules.check），第一个全过的就用。每次搜索最多试 MAX_GEO_TRIES 个取得到路的格点。
## others 是同一接法里已经选好的预设位：新位置要离它们 ≥ CITY_GAP + GAP_MARGIN（同一接法的几个位置不能互相压着）。
## 按名字找：离这个名字的参考位置 MAX_SEED_MOVE 以内、由近到远；≤ NUDGE_RADIUS 记 nudged，更远记 moved_from_seed
static func _geo_rules_slot(cat: Dictionary, layout: Dictionary, host: String, route: String, seed: Vector2, others: Array) -> Dictionary:
	var cands := []
	for p: Vector2 in _geo_zone_cells(cat, layout, route):
		var d := p.distance_to(seed)
		if d <= MAX_SEED_MOVE:
			cands.append([d, p.x, p.y])
	cands.sort()
	var s := _geo_first_ok(cat, layout, host, route, cands, others)
	if s.is_empty():
		return s
	var moved := Vector2(float(s.x), float(s.z)).distance_to(seed)
	if moved <= NUDGE_RADIUS:
		s["nudged"] = snappedf(moved, 0.01)
	else:
		s["searched"] = true
		s["moved_from_seed"] = snappedf(moved, 0.01)
	return s


## 不按名字：离宿主 9.5 u 左右最好、越靠近别的原城越差（与初查的 _prelim_ring 同一个打分，给邻居留地方）
static func _geo_rules_ring(cat: Dictionary, layout: Dictionary, host: String, route: String, others: Array) -> Dictionary:
	var c := Vector2.INF
	for oc: Dictionary in layout.cities:
		if String(oc.id) == host:
			c = Vector2(float(oc.x), float(oc.z))
	if c == Vector2.INF:
		return {}
	var cands := []
	for p: Vector2 in _geo_zone_cells(cat, layout, route):
		var score := absf(p.distance_to(c) - 9.5)
		for oc: Dictionary in layout.cities:
			if String(oc.id) != host:
				score += 20.0 / maxf(Vector2(float(oc.x), float(oc.z)).distance_to(p), 1.0)
		cands.append([score, p.x, p.y])
	cands.sort()
	var s := _geo_first_ok(cat, layout, host, route, cands, others)
	if not s.is_empty():
		s["searched"] = true
	return s


const MAX_GEO_TRIES := 400


static func _geo_first_ok(cat: Dictionary, layout: Dictionary, host: String, route: String, cands: Array, others: Array) -> Dictionary:
	var routed := 0
	for cand in cands:
		var p := Vector2(float(cand[1]), float(cand[2]))
		if _near_any(p, others):
			continue
		var s := _geo_rules_try(cat, layout, host, route, p)
		if bool(s.get("routed", false)):
			routed += 1
		if s.has("x"):
			s.erase("routed")
			return s
		if routed >= MAX_GEO_TRIES:
			break
	return {}


## 绿区格点（按类型缓存）：feasible_zone 是 0.25 u 一格的图（DESIGN 3.12.5「绿区怎么算」），这里换成格心坐标
static func _geo_zone_cells(cat: Dictionary, layout: Dictionary, route: String) -> Array:
	var env := _geo(cat, layout)
	var key := "zone|" + route
	if not env.has(key):
		var cells := []
		var img: Image = env.rules.feasible_zone(env.base, route, env.geo)
		if img != null and img.get_width() > 0:
			var cs := 128.0 / float(img.get_width())
			for j in img.get_height():
				for i in img.get_width():
					if img.get_pixel(i, j).r > 0.5:
						cells.append(Vector2((i + 0.5) * cs, (j + 0.5) * cs))
		env[key] = cells
	return env[key]


static func _near_any(p: Vector2, others: Array) -> bool:
	for s in others:
		if Vector2(float(s.x), float(s.z)).distance_to(p) < CITY_GAP + GAP_MARGIN:
			return true
	return false


## WP3 的几何环境：CustomMapGeo 实例、规则脚本、推导脚本、原布局的推导结果。一次构建共用一份（高度图只读一次）
static var _geo_env := {}
static var geo_tries := 0


static func _geo(cat: Dictionary, layout: Dictionary) -> Dictionary:
	if _geo_env.is_empty():
		var geo = load("res://scripts/custom_map/custom_map_geo.gd").new()
		var layout_cls = load("res://scripts/custom_map/custom_board_layout.gd")
		_geo_env = {"geo": geo, "rules": load("res://scripts/custom_map/custom_map_geo_rules.gd"), "layout_cls": layout_cls,
			"base": layout_cls.derive(layout, {}, geo, cat)}
	return _geo_env


static func _geo_rules_try(cat: Dictionary, layout: Dictionary, host: String, route: String, p: Vector2) -> Dictionary:
	geo_tries += 1
	var env := _geo(cat, layout)
	var field: Dictionary = env.rules.reach_field(env.base, host, route, env.geo)
	var drawn: Dictionary = env.rules.route_from_field(field, p, env.base, env.geo)
	if not bool(drawn.get("ok", false)):
		return {}
	var arche := ""
	for a: Dictionary in cat.archetypes:
		if (a.fits as Array).has(route):
			arche = String(a.id)
			break
	var city := {
		"slot": "e1", "origin": "USER", "partner": "w1", "name": "预设", "name_entry": "",
		"archetype": arche, "specialty": String(cat.specialties[0].key), "host": host, "route_type": route,
		"x": snappedf(p.x, 0.001), "z": snappedf(p.y, 0.001), "rotation": 0.0, "size": 1.0,
		"route": {"handles": drawn.get("handles", []), "stop_t": drawn.get("stop_t", [0.333, 0.667])}, "text": {"mode": "AUTO"},
	}
	var overlay := {"schema": "lshu.custom_map.v1", "moves": {"cities": {}, "routes": {}}, "new_cities": [city]}
	var derived: Dictionary = env.layout_cls.derive(layout, overlay, env.geo, cat)
	var errs: Array = env.rules.check(derived, layout, overlay, env.geo)
	if not errs.is_empty():
		return {"routed": true}
	var handles := []
	for hd in city.route.handles:
		handles.append([snappedf(float(hd[0]), 0.001), snappedf(float(hd[1]), 0.001)])
	var stop_t := []
	for t in city.route.stop_t:
		stop_t.append(snappedf(float(t), 0.001))
	return {"x": city.x, "z": city.z, "rotation": 0.0, "route": {"handles": handles, "stop_t": stop_t}, "route_checked": true, "routed": true}


# ---------------------------------------------------------------------------- 第 5 步：原布局可达区
## 路径只由布局 sha 决定，所以目录内容与写不写文件无关（--verify 能逐字节比）。只有 write_cache（--write）时才真的算、真的写；
## 其余情况只要求文件已经在（不在就报错：先跑 --write）
static func _step5_reach(cat: Dictionary, layout: Dictionary, layout_sha: String, topo: Dictionary, wp3: bool, write_cache: bool,
		ctx: Dictionary) -> String:
	if not wp3:
		ctx.report["step5_reach"] = {"state": "deferred", "why": "WP3 的 CustomMapGeoRules.reach_field 还是骨架"}
		print("BUILD_CATALOGUE step5 reach: deferred (WP3 reach_field is still a skeleton; the workshop computes it live until then)")
		return ""
	var path := REACH_DIR + "reach_%s.res" % layout_sha.substr(0, 8)
	if not write_cache:
		var exists := FileAccess.file_exists(path)
		ctx.report["step5_reach"] = {"state": "not_written (no --write)", "path": path, "exists": exists}
		if not exists:
			ctx.errors.append("可达区缓存 %s 不在：跑一次 --write 才会生成" % path)
		print("BUILD_CATALOGUE step5 reach: %s %s (only --write computes and writes it)" % [path, "exists" if exists else "MISSING"])
		return path.trim_prefix("res://")
	var env := _geo(cat, layout)
	var geo = env.geo
	var rules = env.rules
	var derived: Dictionary = env.base
	var res := Resource.new()
	var fields := {}
	var timings := []
	var total_ms := 0
	for combo in topo.combos:
		var t0 := Time.get_ticks_msec()
		var field: Dictionary = rules.reach_field(derived, String(combo.host), String(combo.route), geo)
		var ms := Time.get_ticks_msec() - t0
		total_ms += ms
		fields["%s|%s" % [combo.host, combo.route]] = field
		timings.append({"host": combo.host, "route": combo.route, "ms": ms})
	res.set_meta("layout_sha256", layout_sha)
	res.set_meta("reach_fields", fields)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REACH_DIR))
	if ResourceSaver.save(res, path) != OK:
		ctx.errors.append("写不了可达区缓存 %s" % path)
		return ""
	var worst := 0
	for t in timings:
		worst = maxi(worst, int(t.ms))
	ctx.report["step5_reach"] = {"state": "written", "path": path, "timings": timings, "total_ms": total_ms}
	if worst > 300 or total_ms > 1500:
		ctx.warnings.append("原布局可达区现场算的耗时：最慢一座 %d ms（预算 300）、全部 %d ms（预算 1500）" % [worst, total_ms])
	print("BUILD_CATALOGUE step5 reach: %s (%d combos, slowest %d ms, total %d ms; step 4 already built these fields, so the timings can be cache hits)" % [
		path, timings.size(), worst, total_ms])
	return path.trim_prefix("res://")


# ---------------------------------------------------------------------------- 第 6 步：补城兜底自检
## 3.12.5 第 3–4 步（CustomMapRules.pick_auto_partner 必须与这里一致；WP1 合入后可以改成直接调它）：
##   名字：partner_pool[宿主][类型] 里第一个没用过的；都用过了，取同侧第一个没用过、可以补城（auto_pick）的认得的名字；
##   原型：名字条目的默认原型可用且适配这种交通就用它；否则同侧第一个可用且适配的（first_fit）；同侧没有就取另一侧；
##   特产：默认特产可用且本图没占用就用它；否则顺延到同侧特产表里下一个可用、没用过的；同侧没有就取另一侧。
## usable: 条目 status → 可用否（shipped / retired；开发开关下也收 draft）。返回 {ok, name_id, name, archetype, specialty,
## archetype_fallback, specialty_fallback, reason}
static func resolve_auto_partner(cat: Dictionary, host: String, route: String, side: String, used_names: Array, used_specs: Array,
		usable: Callable) -> Dictionary:
	var known := {}
	for k: Dictionary in cat.known_names:
		known[String(k.id)] = k
	var entry := {}
	var pool: Array = (cat.get("partner_pool", {}).get(host, {}) as Dictionary).get(route, [])
	for kid in pool:
		var k: Dictionary = known.get(String(kid), {})
		if not k.is_empty() and not used_names.has(String(k.name)):
			entry = k
			break
	if entry.is_empty():
		for k: Dictionary in cat.known_names:
			if String(k.side_hint) == side and bool(k.auto_pick) and not used_names.has(String(k.name)):
				entry = k
				break
	if entry.is_empty():
		return {"ok": false, "reason": "no unused name for %s/%s" % [host, route]}
	var out := {"ok": true, "name_id": String(entry.id), "name": String(entry.name), "archetype_fallback": false, "specialty_fallback": false}
	var arche := CustomMapCardText.find_archetype(cat, String(entry.archetype))
	if not arche.is_empty() and usable.call(String(arche.status)) and (arche.fits as Array).has(route):
		out["archetype"] = String(arche.id)
	else:
		out["archetype_fallback"] = true
		out["archetype"] = first_fit(cat, side, route, usable)
		if String(out.archetype).is_empty():
			out["archetype"] = first_fit(cat, "E" if side == "W" else "W", route, usable)
	var spec := CustomMapCardText.find_specialty(cat, String(entry.specialty))
	if not spec.is_empty() and usable.call(String(spec.status)) and not used_specs.has(String(spec.key)):
		out["specialty"] = String(spec.key)
	else:
		out["specialty_fallback"] = true
		out["specialty"] = next_specialty(cat, side, String(entry.specialty), used_specs, usable)
	if String(out.archetype).is_empty() or String(out.specialty).is_empty():
		out["ok"] = false
		out["reason"] = "no usable archetype or specialty for %s/%s (%s)" % [host, route, entry.id]
	return out


## 某一侧、某种交通下第一个可用的原型（目录顺序）
static func first_fit(cat: Dictionary, side: String, route: String, usable: Callable) -> String:
	for a: Dictionary in cat.archetypes:
		if String(a.style_side) == side and (a.fits as Array).has(route) and usable.call(String(a.status)):
			return String(a.id)
	return ""


## 同侧特产表里、从默认特产往后数的下一个可用且没用过的（绕回表头）；同侧没有就在另一侧从头找
static func next_specialty(cat: Dictionary, side: String, default_key: String, used: Array, usable: Callable) -> String:
	var same: Array = []
	var other: Array = []
	for s: Dictionary in cat.specialties:
		(same if String(s.flavor_side) == side else other).append(s)
	var start := 0
	for i in same.size():
		if String(same[i].key) == default_key:
			start = i + 1
	for i in same.size():
		var s: Dictionary = same[(start + i) % same.size()]
		if usable.call(String(s.status)) and not used.has(String(s.key)):
			return String(s.key)
	for s: Dictionary in other:
		if usable.call(String(s.status)) and not used.has(String(s.key)):
			return String(s.key)
	return ""


static func _step6_fallback(cat: Dictionary, topo: Dictionary, ctx: Dictionary) -> void:
	var fb: Dictionary = cat.get("first_batch", {})
	var first := {}
	for id in fb.get("archetypes", []):
		first[String(id)] = true
	for key in fb.get("specialties", []):
		first[String(key)] = true
	# 三种状态：开发开关（draft 也可用）、只发第一批（其余 draft，不带开关）、当前发布状态（不带开关）
	var states := {
		"dev_allow_draft": {"cat": cat, "usable": func(st: String) -> bool: return STATUSES.has(st)},
		"first_batch_only": {"cat": _with_status(cat, first), "usable": func(st: String) -> bool: return st == "shipped" or st == "retired"},
		"release_current": {"cat": cat, "usable": func(st: String) -> bool: return st == "shipped" or st == "retired"},
	}
	var summary := {}
	for state_name in states:
		var st: Dictionary = states[state_name]
		var c: Dictionary = st.cat
		var usable: Callable = st.usable
		var shipped_arch := (c.archetypes as Array).filter(func(a): return usable.call(String(a.status))).size()
		if state_name == "release_current" and shipped_arch == 0:
			summary[state_name] = {"state": "empty", "why": "目前没有 shipped 的原型（灰盒阶段）：发布版工坊不给加城，游戏拒收任何新城（E_ARCHETYPE）"}
			continue
		var r := fallback_selfcheck(c, topo, usable)
		summary[state_name] = r.summary
		summary[state_name]["unresolved"] = (r.errors as Array).size()
		for e in r.errors:
			ctx.errors.append("补城兜底（%s）：%s" % [state_name, e])
	ctx.report["step6_fallback"] = summary
	for state_name in summary:
		var s: Dictionary = summary[state_name]
		if s.has("resolved"):
			print("BUILD_CATALOGUE step6 fallback %s: %d resolutions over %d combos, %d unresolved; archetype fallbacks on first names %d, specialty fallbacks on first names %d" % [
				state_name, s.resolved, s.combos, s.unresolved, s.first_name_archetype_fallbacks, s.first_name_specialty_fallbacks])
		else:
			print("BUILD_CATALOGUE step6 fallback %s: %s" % [state_name, s.get("why", "")])


## 对每个合格的「宿主 × 类型」：名单逐个用掉（孩子已经用了前面的名字）、名单用完退到同侧备选名，每一步都要解析得到；
## 同时让本图的其它新城占掉 0 / 1 / 3 种特产（默认特产本身、再加同侧后两种），看特产兜底。
static func fallback_selfcheck(cat: Dictionary, topo: Dictionary, usable: Callable) -> Dictionary:
	var errors: Array[String] = []
	var resolved := 0
	var arch_fb := 0
	var spec_fb := 0
	var usable_specs := (cat.specialties as Array).filter(func(s): return usable.call(String(s.status)))
	if usable_specs.size() < MAX_OTHER_NEW_CITIES + 1:
		errors.append("可用特产只有 %d 种，少于一张图最多的新城数 %d" % [usable_specs.size(), MAX_OTHER_NEW_CITIES + 1])
	for r in ROUTES:
		if first_fit(cat, "W", r, usable).is_empty() and first_fit(cat, "E", r, usable).is_empty():
			errors.append("没有任何可用原型能当 %s 城" % r)
	for combo in topo.combos:
		var host := String(combo.host)
		var route := String(combo.route)
		var side := String(combo.side)
		var pool: Array = (cat.get("partner_pool", {}).get(host, {}) as Dictionary).get(route, [])
		var n_same_side := (cat.known_names as Array).filter(func(k): return String(k.side_hint) == side and bool(k.auto_pick)).size()
		var used_names: Array = []
		for step in range(pool.size() + 2):
			var first0 := resolve_auto_partner(cat, host, route, side, used_names, [], usable)
			for used_specs in _spec_scenarios(cat, side, String(first0.get("specialty", "")), usable):
				var r := resolve_auto_partner(cat, host, route, side, used_names, used_specs, usable)
				resolved += 1
				if not bool(r.ok):
					errors.append(String(r.get("reason", "unresolved")))
					continue
				var a := CustomMapCardText.find_archetype(cat, String(r.archetype))
				var s := CustomMapCardText.find_specialty(cat, String(r.specialty))
				if not usable.call(String(a.get("status", ""))) or not (a.get("fits", []) as Array).has(route):
					errors.append("%s/%s 解析到的原型 %s 不可用或不适配" % [host, route, r.archetype])
				if not usable.call(String(s.get("status", ""))) or used_specs.has(String(r.specialty)):
					errors.append("%s/%s 解析到的特产 %s 不可用或已被占用" % [host, route, r.specialty])
				if step == 0 and used_specs.is_empty():
					arch_fb += 1 if bool(r.archetype_fallback) else 0
					spec_fb += 1 if bool(r.specialty_fallback) else 0
			var first := resolve_auto_partner(cat, host, route, side, used_names, [], usable)
			if not bool(first.ok):
				break
			used_names.append(String(first.name))
			if used_names.size() > n_same_side + pool.size():
				break
	return {"errors": errors, "summary": {"combos": topo.combos.size(), "resolved": resolved,
		"first_name_archetype_fallbacks": arch_fb, "first_name_specialty_fallbacks": spec_fb}}


## 本图其它新城占掉的特产：没有占；占了这个名字本来会拿到的那种；再加同侧后面两种（一共 3 种，最多 4 座新城时的上限）
static func _spec_scenarios(cat: Dictionary, side: String, would_get: String, usable: Callable) -> Array:
	var out: Array = [[]]
	if would_get.is_empty():
		return out
	out.append([would_get])
	var three: Array = [would_get]
	for s: Dictionary in cat.specialties:
		if three.size() >= MAX_OTHER_NEW_CITIES:
			break
		if String(s.flavor_side) == side and usable.call(String(s.status)) and not three.has(String(s.key)):
			three.append(String(s.key))
	out.append(three)
	return out


## 复制一份目录，把 shipped 集合里的条目标成 shipped、其余标成 draft（「只发第一批」的模拟）
static func _with_status(cat: Dictionary, shipped: Dictionary) -> Dictionary:
	var c := cat.duplicate(true)
	for a: Dictionary in c.archetypes:
		a["status"] = "shipped" if shipped.has(String(a.id)) else "draft"
	for s: Dictionary in c.specialties:
		s["status"] = "shipped" if shipped.has(String(s.key)) else "draft"
	return c


# ---------------------------------------------------------------------------- 第 7 步：一对接法清单
static func _step7_pairs(cat: Dictionary, topo: Dictionary, preset_check: String, ctx: Dictionary) -> Dictionary:
	var slots: Dictionary = cat.get("preset_slots", {})
	var west: Array = topo.combos.filter(func(c): return String(c.side) == "W")
	var east: Array = topo.combos.filter(func(c): return String(c.side) == "E")
	var pairs := []
	var placeable := 0
	var doubted := 0
	var clean := 0
	var by_steps := {}
	for w in west:
		for e in east:
			var d := int(topo.dist[w.host][e.host])
			if d < PAIR_MIN_STEPS or absf(float(topo.avg[w.host]) - float(topo.avg[e.host])) > PAIR_MAX_AVG_DIFF:
				continue
			var ok := _has_slot(slots, w) and _has_slot(slots, e)
			placeable += 1 if ok else 0
			var steps := d + 6
			by_steps[str(steps)] = int(by_steps.get(str(steps), 0)) + 1
			var pair := {
				"key": "%s|e1:%s:%s:w1|w1:%s:%s:e1" % [TOPO_PREFIX, e.host, e.route, w.host, w.route],
				"west": [w.host, w.route],
				"east": [e.host, e.route],
				"new_city_steps": steps,
				"preset_both_sides": ok,
			}
			# 初查阶段：DESIGN R9 说这几种「宿主 × 类型」附近放不下城，初查的结论不作数，等 WP3 的几何规则
			if preset_check != "geo_rules":
				var doubt := []
				for c in [w, e]:
					if DESIGN_NO_ROOM.has("%s|%s" % [c.host, c.route]):
						doubt.append("%s·%s" % [c.host, c.route])
				if not doubt.is_empty():
					pair["doubt"] = "DESIGN R9：UX 方案实测 %s 附近放不下城；初查找到了位置，但以 WP3 几何规则为准" % "、".join(doubt)
					doubted += 1
			clean += 1 if ok and not pair.has("doubt") else 0
			pairs.append(pair)
	ctx.report["step7_pairs"] = {"legal": pairs.size(), "placeable": placeable, "doubt": doubted, "by_steps": by_steps}
	if pairs.size() != 46:
		ctx.warnings.append("R6 + R9 的一对接法是 %d 种（DESIGN 实测 46 种）" % pairs.size())
	print("BUILD_CATALOGUE step7 pairs: %d legal one-pair topologies (by new-city steps %s), %d with a preset slot on both sides (%s), %d marked doubt" % [
		pairs.size(), str(by_steps), placeable, preset_check, doubted])
	return {"legal_one_pair": pairs.size(), "with_presets": placeable, "with_presets_no_doubt": clean,
		"geo_checked": preset_check, "one_pair": pairs}


static func _has_slot(slots: Dictionary, combo: Dictionary) -> bool:
	return not ((slots.get(String(combo.host), {}) as Dictionary).get(String(combo.route), []) as Array).is_empty()


# ============================================================================ 灰盒占位图
## 纯色卡图（1024×768，陆海两用的原型两张）、缩略图（256×256）、特产图标（256×256，四周留透明边）。
## 颜色按目录顺序在色环上均匀取，东西两侧的原型彼此分得开；写进 assets/custom_map/graybox/，之后跑一次 --import。
static func make_graybox(src: Dictionary) -> void:
	var dirs := ["cards", "thumbs", "goods"]
	for d in dirs:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GRAYBOX_DIR + d))
	var arches: Array = src.get("archetypes", [])
	var written := 0
	for i in arches.size():
		var a: Dictionary = arches[i]
		var col := Color.from_hsv(float(i) / float(arches.size()), 0.38, 0.86)
		var fits: Array = a.get("fits", [])
		for r in fits:
			var c := col if String(r) == "LAND" else col.darkened(0.25)
			var img := Image.create(1024, 768, false, Image.FORMAT_RGB8)
			img.fill(c)
			img.save_png(ProjectSettings.globalize_path(GRAYBOX_DIR + "cards/" + card_file_name(String(a.id), String(r), fits)))
			written += 1
		var th := Image.create(256, 256, false, Image.FORMAT_RGB8)
		th.fill(col)
		th.save_png(ProjectSettings.globalize_path(GRAYBOX_DIR + "thumbs/" + String(a.id) + "_256.png"))
		written += 1
	var specs: Array = src.get("specialties", [])
	for i in specs.size():
		var s: Dictionary = specs[i]
		var icon := Image.create(256, 256, false, Image.FORMAT_RGBA8)
		icon.fill(Color(0, 0, 0, 0))
		icon.fill_rect(Rect2i(24, 24, 208, 208), Color.from_hsv((float(i) + 0.5) / float(specs.size()), 0.6, 0.9))
		icon.save_png(ProjectSettings.globalize_path(GRAYBOX_DIR + "goods/" + String(s.key) + ".png"))
		written += 1
	# 兜底小镇：还没有就从灰盒来源复制一份（已经在的不动，WP6b 的正式模型不会被覆盖），导入方式 keep
	var fb_src := String(src.get("defaults", {}).get("fallback_graybox_model", ""))
	if not FileAccess.file_exists(FALLBACK_MODEL) and not fb_src.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MODEL_DIR))
		if DirAccess.copy_absolute(ProjectSettings.globalize_path(fb_src), ProjectSettings.globalize_path(FALLBACK_MODEL)) == OK:
			var f := FileAccess.open(FALLBACK_MODEL + ".import", FileAccess.WRITE)
			f.store_string(KEEP_IMPORT)
			f.close()
			written += 1
	print("BUILD_CATALOGUE graybox: wrote %d flat-colour placeholders under %s (run --import next)" % [written, GRAYBOX_DIR])


# ============================================================================ 源文件状态
## --set-status=shipped:ae01_kiln_town,kaolin：改源文件里这些条目的 status 并写回
func _set_status(src: Dictionary, spec: String) -> void:
	var parts := spec.split(":", false, 1)
	if parts.size() != 2 or not STATUSES.has(parts[0]):
		_fail("--set-status 的格式是 <draft|shipped|retired>:<id,id,...>")
		return
	var want := {}
	for id in parts[1].split(",", false):
		want[id.strip_edges()] = true
	var hit := 0
	for a: Dictionary in src.archetypes:
		if want.has(String(a.id)):
			a["status"] = parts[0]
			hit += 1
			want.erase(String(a.id))
	for s: Dictionary in src.specialties:
		if want.has(String(s.key)):
			s["status"] = parts[0]
			hit += 1
			want.erase(String(s.key))
	if not want.is_empty():
		_fail("--set-status 找不到这些条目：%s" % ", ".join(want.keys()))
		return
	src["catalogue_version"] = int(src.get("catalogue_version", 1))
	var f := FileAccess.open(SRC, FileAccess.WRITE)
	f.store_string(pretty_json(src) + "\n")
	f.close()
	print("BUILD_CATALOGUE set-status: %d entries -> %s in %s" % [hit, parts[0], SRC])


# ============================================================================ 小工具
static func read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}


static func _count_status(items: Array, status: String) -> int:
	return items.filter(func(e): return String(e.get("status", "")) == status).size()


static func _count_flag(items: Array, flag: String) -> int:
	return items.filter(func(e): return bool(e.get(flag, false))).size()


## 确定性的 JSON 排版：两格缩进，键按插入顺序，短的标量数组写在一行；整数写整数，小数最多 3 位（去掉末尾的 0）。
## 同一份数据输出的字节永远相同（目录要能逐字节比对：--verify）。
static func pretty_json(v: Variant, indent: int = 0) -> String:
	var sp := "  ".repeat(indent)
	match typeof(v):
		TYPE_DICTIONARY:
			var d: Dictionary = v
			if d.is_empty():
				return "{}"
			var items: Array[String] = []
			for k in d:
				items.append("%s  %s: %s" % [sp, JSON.stringify(String(k)), pretty_json(d[k], indent + 1)])
			return "{\n" + ",\n".join(items) + "\n" + sp + "}"
		TYPE_ARRAY:
			var arr: Array = v
			if arr.is_empty():
				return "[]"
			var flat := true
			for x in arr:
				if typeof(x) == TYPE_DICTIONARY or typeof(x) == TYPE_ARRAY:
					flat = false
					break
			if flat:
				var parts: Array[String] = []
				for x in arr:
					parts.append(pretty_json(x, indent + 1))
				var line := "[" + ", ".join(parts) + "]"
				if line.length() < 100:
					return line
			var rows: Array[String] = []
			for x in arr:
				rows.append("%s  %s" % [sp, pretty_json(x, indent + 1)])
			return "[\n" + ",\n".join(rows) + "\n" + sp + "]"
		TYPE_BOOL:
			return "true" if v else "false"
		TYPE_NIL:
			return "null"
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			return _num(float(v))
		_:
			return JSON.stringify(String(v))


static func _num(x: float) -> String:
	var s := "%.3f" % x
	while s.ends_with("0") and not s.ends_with(".0"):
		s = s.substr(0, s.length() - 1)
	if s == "-0.0":
		s = "0.0"
	return s
