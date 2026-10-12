extends RefCounted
## 对局时长设置（Carlos 2026-09-26：「对局模式设置的时候，可以设置结束时间档位从 20 分钟起，最长不限制时间，
## 用户可以自己拉时间进度条」）。档位 20 / 25 / 30 / 40 / 50 / 60 / 90 / 120 分钟和「不限时」（记作 0）。
## 规则不变：时间到了走原版终局（补齐本轮后按白银结算）；不限时就只按原版（公共白银拿空）结束。
## 只有正式入口读写本机设置（和 L叔 提示开关同一个 settings.cfg）；测试与预览一律用默认 20 分钟，不碰玩家的设置。

const Progress := preload("res://scripts/lshu_ui/lshu_progress.gd")
const STEPS: Array[int] = [20, 25, 30, 40, 50, 60, 90, 120, 0]
const DEFAULT_MINUTES := 20

static var minutes: int = DEFAULT_MINUTES
static var _loaded := false


static func settings_path() -> String:
	return Progress.dir_path().path_join("settings.cfg")


## 正式入口里运行才算「真的在玩」：项目主场景，或 Carlos 平时用的 3D 棋盘入口（导出包里它就是主场景）。
## 测试和预览都有自己的场景，不会读写玩家的胜场与设置。
const REAL_ENTRY_SCENES := ["res://tools/merchant_board_claude_play.tscn"]


static func is_real_game(tree: SceneTree) -> bool:
	if tree == null or tree.current_scene == null:
		return false
	var path := tree.current_scene.scene_file_path
	return path == String(ProjectSettings.get_setting("application/run/main_scene", "")) or REAL_ENTRY_SCENES.has(path)


static func load_if_real(tree: SceneTree) -> void:
	if _loaded or not is_real_game(tree):
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(settings_path()) != OK:
		return
	var m := int(cfg.get_value("match", "minutes", DEFAULT_MINUTES))
	minutes = m if STEPS.has(m) else DEFAULT_MINUTES


static func save_if_real(tree: SceneTree) -> void:
	if not is_real_game(tree):
		return
	var cfg := ConfigFile.new()
	cfg.load(settings_path())
	cfg.set_value("match", "minutes", minutes)
	DirAccess.make_dir_recursive_absolute(Progress.dir_path())
	cfg.save(settings_path())


static func limit_sec() -> float:
	return 0.0 if minutes <= 0 else float(minutes) * 60.0


static func text(m: int = -1) -> String:
	var v := minutes if m < 0 else m
	return "不限时" if v <= 0 else "%d 分钟" % v


static func step_index(m: int = -1) -> int:
	var i := STEPS.find(minutes if m < 0 else m)
	return 0 if i < 0 else i
