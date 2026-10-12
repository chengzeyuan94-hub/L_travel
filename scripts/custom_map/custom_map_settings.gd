class_name CustomMapSettings

## 游戏端读自制地图的入口门与本机设置：entry_open、settings.cfg 的 [custom_map] 段（use、last_seen_installed_at）、
## mark_broken（R4 的降级）、切回窗口时的轻量重读（docs/design/map-editor-20260930/DESIGN.md R3、R4、3.1、3.7）。归 WP1。
##
## 入口门（R3）：只有电脑版的正式 3D 入口读地图——不是安卓，并且当前场景是 res://tools/merchant_board_claude_play.tscn。
## 测试、预览、2D 开发主场景 scenes/main.tscn、工坊一律当作没装地图：门关着时 maps/ 下的读文件次数为 0（P-2）。
## 读档也过这道门（lshu_match_save.restore）。test_force_entry 只给测试用：强制开门，测「真的读了文件、但不该生效」的路径。
##
## refresh：读 maps/installed.json → 查外壳 sha → 整份校验（CustomMapLoader.remember）→ 结果写一行进 custom_map_check.txt；
## 通过、并且 installed_at 与上次看到的不同（新导入，同一份图重新导入也算）→ use = true、记下 installed_at。
## options：{} 或 {lshu_custom_map: {enabled: true, sha256}}；地图有问题、孩子选了「原版」、mark_broken 之后都返回 {}。

const MatchSettings := preload("res://scripts/lshu_ui/lshu_match_settings.gd")
const Progress := preload("res://scripts/lshu_ui/lshu_progress.gd")
const ENTRY_SCENE := "res://tools/merchant_board_claude_play.tscn"
const SECTION := "custom_map"
const CHECK_FILE := "custom_map_check.txt"
const CHECK_KEEP_LINES := 200
const MERGE_FAILED := "CUSTOM_MAP_MERGE_FAILED"

static var use := true
static var last_seen_installed_at := ""
static var last_error := ""
## 只给测试用：打开后入口门强制开（测「真的读了文件、但不该生效」的路径）
static var test_force_entry := false
## 最近一次 refresh 的结果（出发页的小签、面板读它）
static var state: Dictionary = {}
## R4 的降级次数（测试断言用）
static var merge_failures := 0

static var _loaded := false
static var _refreshed := false
static var _broken_sha := ""
static var _stamp_at_refresh := ""


## 非安卓，且当前场景是 3D 正式入口 res://tools/merchant_board_claude_play.tscn（或 test_force_entry）
static func entry_open(tree: SceneTree) -> bool:
	if test_force_entry:
		return true
	if OS.has_feature("android"):
		return false
	if tree == null or tree.current_scene == null:
		return false
	return tree.current_scene.scene_file_path == ENTRY_SCENE


## 静态函数里拿场景树（读档是静态的，lshu_match_save.restore）
static func current_tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


## 读 installed.json 并整份校验：{installed, ok, name, sha256, kid_text, counts_win, new_city_names, is_new, code, installed_at}
static func refresh(tree: SceneTree) -> Dictionary:
	_refreshed = true
	var out := {"installed": false, "ok": false, "name": "", "sha256": "", "kid_text": "", "counts_win": true, "new_city_names": [],
		"new_cities": [], "is_new": false, "code": "", "installed_at": ""}
	if not entry_open(tree):
		state = out
		return out
	_load_settings()
	if not CustomMapStore.has_installed():
		_stamp_at_refresh = ""
		state = out
		return out
	out["installed"] = true
	var shell := CustomMapStore.read_installed()
	var installed_at := str(shell.get("installed_at", ""))
	out["installed_at"] = installed_at
	_stamp_at_refresh = installed_at
	var result := {}
	if shell.is_empty():
		result = {"ok": false, "code": "E_PARSE", "message": CustomMapValidator.KID_FILE, "sha256": ""}
	elif str(shell.get("schema", "")) != CustomMapSchema.INSTALL_SCHEMA or not shell.get("overlay") is Dictionary:
		result = {"ok": false, "code": "E_SCHEMA", "message": CustomMapValidator.KID_FILE, "sha256": ""}
	elif CustomMapSchema.sha256(shell["overlay"]) != str(shell.get("sha256", "")):
		result = {"ok": false, "code": "E_SHA", "message": CustomMapValidator.KID_FILE, "sha256": ""}
	else:
		result = CustomMapLoader.remember(shell["overlay"])
	var overlay: Dictionary = shell.get("overlay", {}) if shell.get("overlay") is Dictionary else {}
	out["name"] = str(overlay.get("name", ""))
	if not bool(result.get("ok", false)):
		last_error = str(result.get("code", "E_PARSE"))
		out["code"] = last_error
		out["kid_text"] = str(result.get("message", CustomMapValidator.KID_FILE))
		print("CUSTOM_MAP_REJECTED code=%s name=%s" % [last_error, out["name"]])
		_log_check("REJECTED code=%s name=%s installed_at=%s tech=%s" % [last_error, out["name"], installed_at,
			_tech_of(result)])
		state = out
		return out
	var sha := str(result["sha256"])
	out["ok"] = true
	out["sha256"] = sha
	out["counts_win"] = CustomMapWin.counts_key(CustomMapSchema.topology_key(overlay), str(overlay.get("tradegen", "")))
	var names: Array = []
	var cities: Array = []
	var base := CustomMapLoader.base_content()
	for c in overlay.get("new_cities", []):
		names.append(str(c.get("name", "")))
		cities.append({"name": str(c.get("name", "")), "origin": str(c.get("origin", "")),
			"side": CustomMapRules.side_of_host(base, str(c.get("host", "")))})
	out["new_city_names"] = names
	out["new_cities"] = cities
	if sha != _broken_sha:
		last_error = ""
	# 新导入（看 installed_at 而不看 sha：孩子切回「原版」后，又把同一份图重新导入一次，也会换上）
	if installed_at != last_seen_installed_at:
		out["is_new"] = true
		use = true
		last_seen_installed_at = installed_at
		_save_settings(tree)
	_log_check("OK name=%s sha=%s installed_at=%s new_cities=%d counts_win=%s" % [out["name"], sha.left(12), installed_at,
		names.size(), str(out["counts_win"])])
	state = out
	return out


## 开局选项：{} 或 {OPTION_ID: {enabled: true, sha256}}；mark_broken 之后返回 {}
static func options(tree: SceneTree) -> Dictionary:
	if not entry_open(tree):
		return {}
	if not _refreshed:
		refresh(tree)
	if not bool(state.get("ok", false)) or not use:
		return {}
	var sha := str(state.get("sha256", ""))
	if sha == "" or sha == _broken_sha or not CustomMapLoader.is_remembered(sha):
		return {}
	return CustomMapLoader.option_for(sha)


## R4 的降级：本次进程里这份地图不再给选项
static func mark_broken(code: String) -> void:
	_broken_sha = str(state.get("sha256", ""))
	last_error = code
	print("%s code=%s sha=%s" % [MERGE_FAILED, code, _broken_sha.left(12)])
	_log_check("%s code=%s sha=%s" % [MERGE_FAILED, code, _broken_sha.left(12)])


## installed_at 与上次看到的不同（切回窗口时用，只读外壳、不做整份校验；入口门关着时不读）
static func installed_changed(tree: SceneTree) -> bool:
	if not entry_open(tree):
		return false
	var stamp := CustomMapStore.read_installed_stamp()
	return str(stamp.get("installed_at", "")) != _stamp_at_refresh


## 出发页切「原版 / 地图」：记进 settings.cfg（只有正式入口才写）
static func set_use(tree: SceneTree, value: bool) -> void:
	use = value
	_save_settings(tree)


## 选项里有没有地图
static func has_map_option(options: Variant) -> bool:
	return options is Dictionary and (options as Dictionary).has(CustomMapSchema.OPTION_ID)


static func without_map(options: Variant) -> Dictionary:
	var out: Dictionary = (options as Dictionary).duplicate(true) if options is Dictionary else {}
	out.erase(CustomMapSchema.OPTION_ID)
	return out


## R4：带着地图准备开局失败 → 打 CUSTOM_MAP_MERGE_FAILED → mark_broken → 去掉地图选项再准备一次（原版）。
## 「再来一局」用它（lshu_preview_main.gd）；出发页、切小签、切趣味事件的三处降级在 WP5 的 lshu_setup_screen.gd 里
static func prepare_or_fallback(content: Dictionary, configs: Array, seed: int, mode: String, expansions: Variant) -> Dictionary:
	var prepared := SetupSystem.prepare_new_game(content, configs, seed, mode, expansions)
	if bool(prepared.get("success", false)) or not has_map_option(expansions):
		return prepared
	merge_failures += 1
	if str(state.get("sha256", "")) == "":
		state["sha256"] = str(((expansions as Dictionary)[CustomMapSchema.OPTION_ID] as Dictionary).get("sha256", ""))
	mark_broken(str(prepared.get("message", "merge")))
	var retry := SetupSystem.prepare_new_game(content, configs, seed, mode, without_map(expansions))
	if bool(retry.get("success", false)):
		retry["custom_map_fallback"] = true
	return retry


## 测试之间复位（不读写磁盘）
static func reset_for_tests() -> void:
	use = true
	last_seen_installed_at = ""
	last_error = ""
	test_force_entry = false
	state = {}
	merge_failures = 0
	_loaded = false
	_refreshed = false
	_broken_sha = ""
	_stamp_at_refresh = ""


# ---------------------------------------------------------------- settings.cfg 与检查日志

static func _load_settings() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(MatchSettings.settings_path()) != OK:
		return
	use = bool(cfg.get_value(SECTION, "use", true))
	last_seen_installed_at = str(cfg.get_value(SECTION, "last_seen_installed_at", ""))


static func _save_settings(tree: SceneTree) -> void:
	if not entry_open(tree):
		return
	var cfg := ConfigFile.new()
	cfg.load(MatchSettings.settings_path())
	cfg.set_value(SECTION, "use", use)
	cfg.set_value(SECTION, "last_seen_installed_at", last_seen_installed_at)
	DirAccess.make_dir_recursive_absolute(Progress.dir_path())
	cfg.save(MatchSettings.settings_path())


## custom_map_check.txt：每次读地图写一行检查结果（排查用），只留最近 200 行
static func _log_check(line: String) -> void:
	var path := Progress.dir_path().path_join(CHECK_FILE)
	var lines: PackedStringArray = []
	if FileAccess.file_exists(path):
		lines = FileAccess.get_file_as_string(path).strip_edges().split("\n", false)
	lines.append("%s %s" % [Time.get_datetime_string_from_system(false, true), line])
	if lines.size() > CHECK_KEEP_LINES:
		lines = lines.slice(lines.size() - CHECK_KEEP_LINES)
	DirAccess.make_dir_recursive_absolute(Progress.dir_path())
	CustomMapStore.atomic_write(path, "\n".join(lines) + "\n")


static func _tech_of(result: Dictionary) -> String:
	var errs: Array = result.get("errors", [])
	var parts: PackedStringArray = []
	for e in errs.slice(0, 3):
		parts.append("%s:%s" % [str(e.get("code", "")), str(e.get("tech", ""))])
	return " | ".join(parts)
