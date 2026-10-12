extends SceneTree
## 冒烟：开场里「进入」某一幕 → 那一幕开在同一个窗口里（scripts/traveler/traveler_host.gd，2026-09-27 起不再另起进程）→
## 就绪后按「返回」同样的流程离开 → 开场回来。用法：--act=panti（带 --lshu-unlock-all），窗口运行，HOME 指到临时目录。
## 这个驱动脚本下环境声不建（amb_kit.allowed()）；整条路（正式入口、带声音）见 tools/traveler/release_act_smoke.sh 的 title_flow。
const Launch := preload("res://scripts/traveler/traveler_launch.gd")
var act := "panti"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--act="): act = a.trim_prefix("--act=")
	call_deferred("_run")


func _run() -> void:
	var title: Control = (load("res://scenes/lshu_ui/lshu_title_screen.tscn") as PackedScene).instantiate()
	root.add_child(title)
	for i in range(10): await process_frame
	# 第四幕会写存档和明信片：指到临时目录，绝不碰真存档（HOME 忘了指到临时目录时也一样）
	var extra := PackedStringArray()
	if act == "lshu":
		var tmp := OS.get_temp_dir().path_join("lshu_enter_smoke_%d" % OS.get_process_id())
		DirAccess.make_dir_recursive_absolute(tmp)
		extra.append("--lshu-save-dir=" + tmp)
	title.set("act_extra_args", extra)
	var mode0 := DisplayServer.window_get_mode()
	title.call("_enter_act", act)
	var host: Node = title.get("act_host")
	var hosted := host != null and Launch.hosting()
	var t0 := Time.get_ticks_msec()
	while host != null and is_instance_valid(host) and str(host.get("state")) != "running" and Time.get_ticks_msec() - t0 < 120000:
		await process_frame
	var ready := host != null and is_instance_valid(host) and str(host.get("state")) == "running"
	var windows := DisplayServer.get_window_list().size()
	var overlay: Node = Launch.overlay()
	if overlay != null:
		overlay.call("leave", "smoke")
	t0 = Time.get_ticks_msec()
	while Launch.hosting() and Time.get_ticks_msec() - t0 < 30000:
		await process_frame
	await create_timer(1.0).timeout
	var restored: bool = not Launch.hosting() and title.get("act_host") == null and title.is_visible_in_tree()
	print("LSHU_ENTER_SMOKE ", JSON.stringify({"act": act, "hosted": hosted, "ready": ready, "windows": windows,
		"mode_unchanged": DisplayServer.window_get_mode() == mode0, "restored_after_leave": restored}))
	# 开场音乐在放：先停，给音频线程一点时间收走再退出（同开场的「退出游戏」）
	(title.get("bgm") as AudioStreamPlayer).stop()
	title.queue_free()
	await create_timer(0.25).timeout
	quit(0 if (hosted and ready and windows == 1 and restored) else 1)
