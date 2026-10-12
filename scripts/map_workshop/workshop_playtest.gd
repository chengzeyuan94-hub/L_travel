extends Node
## A separate formal merchant process; the editor's instance/GameState/history never leaves its tree.
signal changed(state: String, report: Dictionary)
var pid := -1
var state := "idle"
var directory := ""
var token := ""
var expected_sha := ""
var report: Dictionary = {}
var _started := 0
var _ready_seen := false
var _stop_reason := ""
var last_pid := -1
var test_child_args := PackedStringArray()
var _dead_processes: Dictionary = {}

func _exit_tree() -> void:
	if pid > 0 and process_alive(pid): OS.kill(pid)

func start(overlay: Dictionary, window_position := "") -> Dictionary:
	if not PublicRules.ready(): return {"ok":false,"message":"玩法规则尚未配置，请先打开配置玩法规则。"}
	if pid > 0: return {"ok": false, "message": "已有一场试玩正在运行。"}
	var valid := CustomMapLoader.remember(overlay)
	if not bool(valid.get("ok", false)): return {"ok": false, "message": str(valid.get("message", "地图校验未通过。"))}
	expected_sha = str(valid.sha256)
	token = "%s-%s" % [OS.get_process_id(), Time.get_ticks_usec()]
	# The editor owns this directory on every platform. No Unix shell, global
	# temporary path or inherited environment variable is required by the child.
	directory = preload("res://scripts/lshu_ui/lshu_progress.gd").dir_path().path_join("playtests").path_join(token)
	if DirAccess.make_dir_recursive_absolute(directory) != OK: return {"ok": false, "message": "无法准备试玩目录。"}
	if not PublicRules.copy_to(directory): return {"ok":false,"message":"无法准备试玩规则副本。"}
	var assets := CustomMapLocalAssets.copy_dependencies(overlay, directory.path_join("maps/assets"))
	if not assets.ok: return {"ok": false, "message": str(assets.message)}
	var map_path := directory.path_join("installed.map.json")
	var f := FileAccess.open(map_path, FileAccess.WRITE)
	if f == null: return {"ok": false, "message": "无法保存试玩地图副本。"}
	f.store_string(JSON.stringify(overlay, "  "))
	var write_error := f.get_error(); f.close()
	if write_error != OK: return {"ok": false, "message": "试玩地图副本写入失败。"}
	var args := PackedStringArray()
	if OS.has_feature("editor"):
		args.append_array(PackedStringArray(["--path", ProjectSettings.globalize_path("res://"), "res://scenes/map_workshop/workshop_playtest.tscn"]))
	args.append_array(PackedStringArray(["--log-file", directory.path_join("game.log")]))
	if DisplayServer.get_name() == "headless": args.append("--headless")
	if not window_position.is_empty(): args.append_array(PackedStringArray(["--position", window_position]))
	args.append_array(PackedStringArray(["--", "--workshop-playtest", "--workshop-data-dir=" + directory, "--quick", "--custom-map=" + map_path, "--workshop-sha=" + expected_sha, "--workshop-token=" + token, "--seed=6405"]))
	args.append_array(test_child_args)
	# create_instance uses the engine's native launcher, including Android's
	# Godot activity launcher instead of treating its package as an executable.
	pid = OS.create_instance(args)
	if pid <= 0: pid = -1; return {"ok": false, "message": "无法启动试玩。"}
	_dead_processes.erase(pid)
	_started = Time.get_ticks_msec(); _ready_seen = false; report.clear()
	state = "starting"; set_process(true); changed.emit(state, {})
	return {"ok": true, "pid": pid, "directory": directory, "sha256": expected_sha}

func _read_report() -> Dictionary:
	var p := directory.path_join("status.json")
	if not FileAccess.file_exists(p): return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(p)) != OK or not parser.data is Dictionary: return {}
	var value: Dictionary = parser.data
	return value if str(value.get("token", "")) == token else {}

func _process(_delta: float) -> void:
	if pid <= 0: return
	if state == "stopping":
		if not process_alive(pid): _finish_stop(_stop_reason)
		return
	var next := _read_report()
	if not next.is_empty(): report = next
	if str(report.get("state", "")) == "failed":
		stop("failed"); return
	if str(report.get("state", "")) == "ready" and not _ready_seen:
		if str(report.get("sha256", "")) != expected_sha or str(report.get("session_mode", "")) != "FORMAL":
			report = {"message": "试玩地图与安装版本不一致。"}; stop("failed"); return
		_ready_seen = true; state = "playing"; changed.emit(state, report)
	if not process_alive(pid):
		last_pid = pid; pid = -1; set_process(false)
		state = "returned" if _ready_seen else "failed"
		if not _ready_seen and not report.has("message"): report["message"] = "试玩没有成功启动；请查看试玩日志。"
		changed.emit(state, report)
	elif not _ready_seen and Time.get_ticks_msec() - _started > 120000:
		report = {"message": "试玩启动超时，已返回工坊。"}; stop("failed")

func stop(reason := "returned") -> void:
	if pid > 0 and process_alive(pid):
		var error := OS.kill(pid)
		if error != OK:
			report["message"] = "无法结束试玩进程，请关闭试玩窗口。"
			changed.emit("stop_failed", report); return
		# A successful kill reaps the child on Unix. Cache that outcome so a
		# later native liveness query cannot query an already reaped PID.
		_dead_processes[pid] = true
		_finish_stop(reason); return
	_finish_stop(reason)

func _finish_stop(reason: String) -> void:
	last_pid = pid; pid = -1; set_process(false); state = reason
	changed.emit(state, report)

## Use the native process API; remember observed exits to avoid repeat queries
## after Godot has reaped a Unix child. No /bin/kill dependency on Windows/mobile.
func process_alive(process_id: int) -> bool:
	if process_id <= 0 or _dead_processes.has(process_id): return false
	var running := OS.is_process_running(process_id)
	if not running: _dead_processes[process_id] = true
	return running

func request_foreground() -> bool:
	if pid <= 0 or state != "playing" or not process_alive(pid) or str(report.get("token", "")) != token: return false
	var file := FileAccess.open(directory.path_join("foreground.json"), FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify({"token":token,"sha256":expected_sha})); file.close()
	return true
