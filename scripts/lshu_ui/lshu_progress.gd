extends RefCounted
## 胜场与解锁进度（全家共用一份）。存在 ~/Library/Application Support/ShanheLvren/progress.json，
## 和第四幕存档同一个父目录；不用 user://，这样以后改项目名也不会丢。
## 商旅模式结算时调用 add_win() 记一局（结算接入是下一步，这一版只读）。
## 预览参数：--lshu-wins=N 临时指定胜场（不写盘）；--lshu-unlock-all 全部解锁（不写盘）。

const SUBDIR := "ShanheLvren"
const FILE_NAME := "progress.json"

## 解锁顺序与门槛（Carlos 2026-09-25：5 / 10 / 15 / 20 局）
## hint：进了这一幕以后画面底部那一行操作提示（scripts/traveler/act_exit_button.gd 显示）；pad_hint：用手柄时换成这一句；
## scene / args：进这一幕用哪个场景、带哪些参数。requires：这一幕离不开、又不在版本库里的东西（generated/ 下烘出来的），
## 导出的包里缺了就不让进（act_available；导出时场景里指向缺失文件的引用会被丢掉，光查场景的依赖查不出来，PAD-MAR-1）。开场「进入」时在同一个窗口里开（scripts/traveler/traveler_host.gd，
## 参数经 traveler_launch.gd 给这一幕）；单独开时只带 -- --lshu-act=<id> <args>（正式包不许命令行指定场景），
## 由正式包入口 tools/merchant_board_claude_play.gd 换到 scene
const ACTS: Array[Dictionary] = [
	{"id": "changan", "name": "长安旅人", "wins": 5, "cg": "res://assets/game/title_cg/changan.jpg", "thumb": "res://assets/game/title_cg/changan_thumb.jpg",
		"desc": "秋日黄昏，石窟和古寺。点城门换白天和夕照。", "hint": "点城门，换白天和夕照", "pad_hint": "按 A 换白天和夕照 · 按两下 B 回开场",
		"scene": "res://scenes/traveler/traveler_main.tscn", "args": ["--view=changan", "--far", "--dusk"],
		"requires": ["res://generated/traveler/atlas/atlas_world.tscn"]},
	{"id": "panti", "name": "盘橐旅人", "wins": 10, "flip": true, "cg": "res://assets/game/title_cg/panti.jpg", "thumb": "res://assets/game/title_cg/panti_thumb.jpg",
		"desc": "雪原要塞和篝火。点篝火换清晨和深夜。", "hint": "点篝火，换清晨和深夜", "pad_hint": "按 A 换清晨和深夜 · 按两下 B 回开场",
		"scene": "res://scenes/traveler/panti_main.tscn", "args": ["--view=panti", "--morning"]},
	{"id": "baghdad", "name": "巴格达旅人", "wins": 15, "cg": "res://assets/game/title_cg/baghdad.jpg", "thumb": "res://assets/game/title_cg/baghdad_thumb.jpg",
		"desc": "生命之树下，雨停花开，晚霞满天。点土豆换一段。", "hint": "点 L叔 手里的土豆，换下一段", "pad_hint": "按 A 换下一段 · 按两下 B 回开场",
		"scene": "res://scenes/traveler/baghdad_cycle.tscn", "args": ["--view=baghdad", "--lookdev=m_grass"]},
	{"id": "lshu", "name": "L叔去哪儿", "wins": 20, "cg": "res://assets/game/title_cg/lshu.jpg", "thumb": "res://assets/game/title_cg/lshu_thumb.jpg",
		"desc": "他自己去旅行，偶尔寄明信片回来。点他会鞠躬拍照，右下角看明信片。", "tease": "就能看看我自己去哪儿旅行啦！",
		"hint": "点 L叔 会鞠躬拍照 · 右下角看明信片和旅行本",
		"pad_hint": "A 跟 L叔 打招呼 · X 看明信片 · Y 旅行本 · B 返回",
		"scene": "res://scenes/traveler/lshu_main.tscn", "args": []},
]
const DEFAULT_CG := "res://assets/game/title_cg/changan.jpg"
## 默认开场「旅行L叔」：会动的插画（scenes/lshu_ui/lshu_home_scene），不需要解锁；cg 是它的静帧，给截图和兜底用
const HOME: Dictionary = {"id": "home", "name": "旅行L叔", "cg": "res://assets/game/title_cg/home.jpg"}

var wins: int = 0
var title_scene: String = ""
var preview_override: bool = false
var unlock_all: bool = false


static func dir_path() -> String:
	var playtest := playtest_dir(OS.get_cmdline_user_args())
	if not playtest.is_empty(): return playtest
	if OS.has_environment("SILKROAD_DATA_DIR"):
		return OS.get_environment("SILKROAD_DATA_DIR")
	var final_dir: String = str(ProjectSettings.get_setting("stage3_final/data_directory_name", ""))
	if final_dir in ["LShuTravel-Open-v0.2.4", "ShanheLvren-Stage3-Final", "ShanheLvren-Piece-Presets", "ShanheLvren-LshuDefaults4", "ShanheLvren-Editor-v01", "LShuMapWorkshop-v02", "LShuCityBadgeD-Review-20261006", "LShuCityBadgeWorkshop-Custom-20261007", "LShuAssetLibrary-MVP-20261007"]:
		return OS.get_data_dir().path_join(final_dir)
	return OS.get_data_dir().path_join(SUBDIR)


## Explicit child argument survives native desktop and Android instance launches;
## only the dedicated playtest entry accepts it. The normal game keeps its data root.
static func playtest_dir(args: PackedStringArray) -> String:
	if not "--workshop-playtest" in args: return ""
	var path := ""
	for arg: String in args:
		if not arg.begins_with("--workshop-data-dir="): continue
		var candidate := arg.trim_prefix("--workshop-data-dir=")
		if candidate.is_empty() or not candidate.is_absolute_path(): return ""
		if not path.is_empty() and path != candidate.simplify_path(): return ""
		path = candidate.simplify_path()
	return path


func load_progress() -> void:
	var d: Dictionary = _read_disk()
	wins = int(d.get("wins", 0))
	title_scene = str(d.get("title_scene", ""))
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--lshu-wins="):
			wins = int(a.trim_prefix("--lshu-wins="))
			preview_override = true
		elif a == "--lshu-unlock-all":
			unlock_all = true
			preview_override = true
	if title_scene != "" and title_scene != "home" and not is_unlocked(title_scene):
		title_scene = ""


## 读盘上的进度；读不懂的文件先改名成 progress.json.bad-<时间> 留着（复检 WIN-6：以前当成 0 局，下一胜把原来的局数盖掉）。
## 胜场不是整数 / 字符串数字时按 0 算，不报脚本错。
func _read_disk() -> Dictionary:
	var p: String = dir_path().path_join(FILE_NAME)
	if not FileAccess.file_exists(p):
		return {}
	var text := FileAccess.get_file_as_string(p)
	var d: Variant = JSON.parse_string(text) if not text.strip_edges().is_empty() else {}
	if not d is Dictionary:
		var bad := p + ".bad-" + Time.get_datetime_string_from_system(false, false).replace(":", "")
		DirAccess.rename_absolute(p, bad)
		push_warning("LshuProgress: %s 读不懂，已改名为 %s" % [p, bad])
		return {}
	var out := {}
	var w: Variant = (d as Dictionary).get("wins", 0)
	out["wins"] = maxi(0, int(w)) if (w is int or w is float or (w is String and (w as String).is_valid_int())) else 0
	out["title_scene"] = str((d as Dictionary).get("title_scene", ""))
	return out


## 写盘：胜场取盘上和手里的较大值——开场这份可能是进对局前读的，旧了（复检 WIN-2：换开场画面会把刚赢的局抹掉）。
## 成功返回 true；写不进去返回 false 并报警告（复检 WIN-5）。
func save_progress() -> bool:
	if preview_override:
		return true
	DirAccess.make_dir_recursive_absolute(dir_path())
	wins = maxi(wins, int(_read_disk().get("wins", 0)))
	var p: String = dir_path().path_join(FILE_NAME)
	var tmp: String = p + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("LshuProgress: 写不进 %s" % tmp)
		return false
	f.store_string(JSON.stringify({"schema": "lshu.progress.v1", "wins": wins, "title_scene": title_scene}, "  "))
	f.flush()
	var written := f.get_error() == OK
	f.close()
	if not written:
		DirAccess.remove_absolute(tmp)
		push_warning("LshuProgress: 没能完整写入 %s，保留原进度" % tmp)
		return false
	if DirAccess.rename_absolute(tmp, p) != OK:
		push_warning("LshuProgress: 改名到 %s 失败" % p)
		return false
	return true


## 记一胜：先按盘上的数（别的界面可能刚记过），再加一；返回有没有存上
func add_win() -> bool:
	if not preview_override:
		wins = maxi(wins, int(_read_disk().get("wins", 0)))
	wins += 1
	return save_progress()


func act(id: String) -> Dictionary:
	if id == "home":
		return HOME
	return act_info(id)


## 不用先读进度就能查一幕（开场进一幕、单独开一幕的正式包入口用）；没有这一幕时返回空字典
static func act_info(id: String) -> Dictionary:
	for a: Dictionary in ACTS:
		if str(a.id) == id:
			return a
	return {}


## 这一幕的场景和它直接引用的资源是不是都在（包里 / 检出里）。PAD-MAR-1（安卓压力测试）：generated/ 被 .gitignore 挡在
## 版本库外，从没有它的检出（worktree、新 clone）导出的包里长安引用的 generated/traveler/atlas/atlas_world.tscn 不在，
## 导出照样成功；进长安后这一幕的 @onready 找不到节点、永远不就绪，孩子一直看着载入卡。返回缺的路径（空 = 齐全）；
## 开场的选幕卡和 traveler_host.enter 用它，缺了就不让进。按场景缓存（包里的东西运行时不会变）
static var _missing_cache := {}


static func missing_deps(scene_path: String) -> PackedStringArray:
	if _missing_cache.has(scene_path):
		return _missing_cache[scene_path]
	var out := PackedStringArray()
	if scene_path == "" or not ResourceLoader.exists(scene_path):
		out.append(scene_path)
	else:
		for dep: String in ResourceLoader.get_dependencies(scene_path):
			# 4.x 可能是 "uid://…::类型::res://路径"：取最后一段
			var p := dep.get_slice("::", dep.get_slice_count("::") - 1) if dep.contains("::") else dep
			if p.begins_with("res://") and not ResourceLoader.exists(p):
				out.append(p)
	if not out.is_empty():
		push_error("旅人模式：%s 缺东西（导出时漏了？generated/ 不在版本库里）：%s" % [scene_path, ", ".join(out)])
	_missing_cache[scene_path] = out
	return out


## 这一幕缺的东西：场景和它直接引用的资源（开发检出里的文本场景查得出来），加上 requires 里列的
## （导出的包里场景对缺失文件的引用已经被丢掉，只能按清单查）。空 = 齐全
static func missing_for_act(id: String) -> PackedStringArray:
	var a := act_info(id)
	if a.is_empty():
		return PackedStringArray([id])
	var out := missing_deps(str(a.get("scene", ""))).duplicate()
	for r: String in a.get("requires", []):
		if not ResourceLoader.exists(r) and not out.has(r):
			out.append(r)
	return out


## 这一幕能不能进（场景、直接引用的资源、requires 里的都在）
static func act_available(id: String) -> bool:
	return missing_for_act(id).is_empty()


func is_unlocked(id: String) -> bool:
	# All public travel acts are available; win records remain historical data.
	return not act(id).is_empty()


func unlocked_ids() -> Array[String]:
	var out: Array[String] = []
	for a: Dictionary in ACTS:
		if is_unlocked(str(a.id)):
			out.append(str(a.id))
	return out


## 下一个还没解锁的幕；全部解锁时返回空字典
func next_locked() -> Dictionary:
	for a: Dictionary in ACTS:
		if not is_unlocked(str(a.id)):
			return a
	return {}


func title_cg_path() -> String:
	return str(act(current_title_id()).cg)


## 开场画面可选的顺序：默认的「旅行L叔」在最前，后面是已解锁的幕
func title_ids() -> Array[String]:
	var out: Array[String] = ["home"]
	out.append_array(unlocked_ids())
	return out


## 当作开场背景时是否左右翻转（盘橐的 L叔 在画面左边，会被按钮挡住）
func title_cg_flip() -> bool:
	var id: String = current_title_id()
	return id != "" and bool(act(id).get("flip", false))


func current_title_id() -> String:
	if title_scene != "" and title_scene != "home" and is_unlocked(title_scene):
		return title_scene
	return "home"
