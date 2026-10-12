extends SceneTree

## 自制地图 AI 对局模拟的引导（DESIGN 4.4，WP2）：先让 Autoload（GameState 等）就位，再在运行时 load() 真正的模拟脚本。
## 直接 --script 模拟脚本会报「Identifier not found: GameState」（ECONOMY §5.2 踩过的坑），进程也不会退出。
## 用法：HOME=<scratch> Godot --headless --path <worktree> --script res://tools/custom_map/sim/sim_boot.gd -- key=value ...
## 参数说明见 sim_run.gd 文件头。另有 impl=<res:// 路径>：换一个模拟脚本（它要有 run_sim()），排查用。


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var path := "res://tools/custom_map/sim/sim_run.gd"
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("impl="):
			path = String(a).substr(5)
	var impl: Node = load(path).new()
	root.add_child(impl)
	impl.call("run_sim")
