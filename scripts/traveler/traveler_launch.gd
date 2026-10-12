extends RefCounted
## 旅人模式一幕的启动参数，以及「这一幕是不是开在开场同一个窗口里」（2026-09-27 Carlos：四幕都在开场的同一个窗口里开，不再另起进程）。
## 各幕和它们用到的脚本一律读 user_args()，不直接读 OS.get_cmdline_user_args()：
##   · 从开场「进入」（scripts/traveler/traveler_host.gd）：给这一幕的参数 --lshu-act=<id> + lshu_progress.gd ACTS[].args
##     （+ 冒烟测试追加的参数 + 进程命令行里的几个调试开关 PASS_THROUGH）；
##   · 单独开（命令行 -- --lshu-act=<id> …、tools/open_*_traveler.command、直接跑场景、截图 / 录像 / 测帧工具）：就是命令行参数，和以前一样。
## finish()：一幕要结束自己（返回、Esc、出错）时调它：开在开场窗口里就回开场，单独开的就退出进程（和以前一样）。

const Progress := preload("res://scripts/lshu_ui/lshu_progress.gd")
## 进程命令行里带了这几个，开场里进的一幕也带上（调试键、关环境声、声音日志、声音自检）
const PASS_THROUGH: Array[String] = ["--lshu-dev", "--no-ambience", "--amb-log", "--sound-debug", "--lshu-audio-probe", "--lshu-no-intro"]

static var _hosted := false
static var _args := PackedStringArray()
static var _host: Node = null      # traveler_host.gd 的实例
static var _act: Node = null       # 正开着的那一幕的根节点
static var _overlay: Node = null   # 这一幕的「‹ 返回」/ 提示 / 载入卡（act_exit_button.gd），进场前就建好
## 鼠标在这一幕能点的东西上时默认光标换成小手（act_exit_button.set_hotspot_cursor）；回开场时 traveler_globals.gd 换回箭头
static var cursor_hand := false


## 这一幕该读的参数
static func user_args() -> PackedStringArray:
	if _hosted:
		return _args.duplicate()
	return OS.get_cmdline_user_args()


## 现在有一幕开在开场的窗口里
static func hosting() -> bool:
	return _hosted


## node 是不是开在开场窗口里的那一幕的根节点（找 L叔 的导演只在「主场景」时跑，开在开场里也算）
static func is_hosted_root(node: Node) -> bool:
	return _hosted and node != null and is_instance_valid(_act) and _act == node


static func host() -> Node:
	return _host if _hosted and is_instance_valid(_host) else null


static func overlay() -> Node:
	return _overlay if _hosted and is_instance_valid(_overlay) else null


static func act_root() -> Node:
	return _act if _hosted and is_instance_valid(_act) else null


## 开场进 id 这一幕时给它的参数
static func args_for(id: String, extra: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var out := PackedStringArray(["--lshu-act=" + id])
	for a: Variant in Progress.act_info(id).get("args", []):
		out.append(str(a))
	out.append_array(extra)
	for a: String in OS.get_cmdline_user_args():
		if PASS_THROUGH.has(a) and not out.has(a):
			out.append(a)
	return out


## traveler_host.gd 调：开始 / 结束「开在开场窗口里」
static func begin(host_node: Node, args: PackedStringArray, overlay_node: Node) -> void:
	_hosted = true
	_args = args
	_host = host_node
	_overlay = overlay_node
	_act = null


static func set_act(node: Node) -> void:
	_act = node


static func end() -> void:
	_hosted = false
	_args = PackedStringArray()
	_host = null
	_overlay = null
	_act = null


## 一幕要结束：开在开场窗口里 → 回开场（traveler_host.gd 走收尾：存进度、停声音、释放、还原全局设置）；单独开 → 退出进程
static func finish(tree: SceneTree, code: int = 0) -> void:
	var h := host()
	if h != null:
		h.call_deferred("request_return", code)
	elif tree != null:
		tree.quit(code)
