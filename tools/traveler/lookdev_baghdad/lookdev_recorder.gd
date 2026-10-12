extends Node
## 探针录像器：配合 Godot 的 --fixed-fps 30 使用，每帧推进固定 1/30 s，与机器快慢无关。
## 预热 warmup_frames 帧（SDFGI 收敛、粒子预热）后，逐帧把 SubViewport 存成 PNG，
## 存满 frames 帧后退出；lookdev.py 再用 ffmpeg 合成 mp4。
##
## 2026-09-23 修正：
## - 不在 _process 里 await（窗口不绘制时 await 会堆积，恢复时一次性吐出几百帧同样的图 → 录了 866 帧）。
##   改成连 RenderingServer.frame_post_draw 信号：只有真正画出来的帧才计数和保存。
## - macOS 上窗口被完全遮挡时 Godot 停止绘制；并行跑批的 capture 窗口会互相盖住。
##   这里把本进程窗口缩小并挪到屏幕右下角、置顶，且检测到连续相同帧时报警。
var out_dir := ""
var warmup_frames := 90
var frames := 240
var _drawn := 0
var _saved := 0
var _last_hash := ""
var _repeats := 0
var _done := false

func configure(cfg: Dictionary) -> void:
	out_dir = str(cfg.get("out_dir", ""))
	warmup_frames = int(cfg.get("warmup_frames", 90))
	frames = int(cfg.get("frames", 240))
	DirAccess.make_dir_recursive_absolute(out_dir)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_park_window()
	RenderingServer.frame_post_draw.connect(_on_post_draw)

func _park_window() -> void:
	var wid := DisplayServer.MAIN_WINDOW_ID
	var screen := DisplayServer.window_get_current_screen(wid)
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var size := Vector2i(480, 270)
	DisplayServer.window_set_size(size, wid)
	DisplayServer.window_set_position(usable.position + usable.size - size - Vector2i(8, 8), wid)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true, wid)

func _on_post_draw() -> void:
	if _done:
		return
	_drawn += 1
	if _drawn <= warmup_frames:
		return
	var img := get_viewport().get_texture().get_image()
	var h := str(hash(img.get_data()))
	if h == _last_hash:
		_repeats += 1
	_last_hash = h
	img.save_png("%s/f_%04d.png" % [out_dir, _saved])
	_saved += 1
	if _saved >= frames:
		_done = true
		print("LOOKDEV_RECORD_DONE ", JSON.stringify({"frames": _saved, "repeated_frames": _repeats, "out_dir": out_dir, "size": [img.get_width(), img.get_height()]}))
		RenderingServer.frame_post_draw.disconnect(_on_post_draw)
		get_tree().quit()
