extends SceneTree
## 默认开场动效自检：开场跑起来后按时间点取帧，末尾点一下 L叔 再取一帧，并打印帧率。
## 用法：--out=目录 [--size=1920x1080] [--times=3,8,16,21,30] [--lshu-wins=12]
## 窗口停在屏幕右下角置顶的小窗里（被遮挡的窗口 macOS 不绘制）。
var out := ""
var sz := Vector2i(1920, 1080)
var times: Array[float] = [3.0, 8.0, 16.0, 21.0, 30.0]

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="): out = a.trim_prefix("--out=")
		elif a.begins_with("--size="):
			var p := a.trim_prefix("--size=").split("x"); sz = Vector2i(int(p[0]), int(p[1]))
		elif a.begins_with("--times="):
			times.clear()
			for t in a.trim_prefix("--times=").split(","): times.append(float(t))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	var usable := DisplayServer.screen_get_usable_rect()
	DisplayServer.window_set_size(Vector2i(320, 180))
	DisplayServer.window_set_position(usable.position + usable.size - Vector2i(340, 220))
	call_deferred("_run")

func _grab(vp: SubViewport, name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.save_png(out.path_join(name))

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	var vp := SubViewport.new()
	vp.size = sz
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var host := Control.new()
	host.size = Vector2(sz)
	vp.add_child(host)
	var title: Control = (load("res://scenes/lshu_ui/lshu_title_screen.tscn") as PackedScene).instantiate()
	host.add_child(title)
	var preview := TextureRect.new()
	preview.texture = vp.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(preview)
	var home: Control = title.get_node("HomeScene")
	var t0 := Time.get_ticks_msec()
	var frames0 := Engine.get_frames_drawn()
	var shots: Array[String] = []
	for t in times:
		while (Time.get_ticks_msec() - t0) / 1000.0 < t:
			await process_frame
		var name := "t%05.1f.png" % t
		await _grab(vp, name)
		shots.append(name)
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	var fps := (Engine.get_frames_drawn() - frames0) / secs
	home.call("poke")
	await create_timer(0.15).timeout
	await _grab(vp, "poke.png")
	shots.append("poke.png")
	print("LSHU_HOME_FRAMES ", JSON.stringify({"out": out, "shots": shots, "avg_fps": snappedf(fps, 0.1),
		"home_process": home.process_mode, "home_visible": home.visible}))
	var bgm := title.get_node("TitleBgm") as AudioStreamPlayer
	bgm.stop()
	bgm.stream = null
	title.queue_free()
	await create_timer(0.3).timeout
	quit(0)
