extends SceneTree
## 开场截图：--out=PNG --size=1920x1080 [--picker] [--lshu-wins=N | --lshu-unlock-all]
## 窗口停在屏幕右下角置顶的小窗里（被遮挡的窗口 macOS 不绘制）。
var out := ""
var sz := Vector2i(1920, 1080)
var picker := false

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="): out = a.trim_prefix("--out=")
		elif a.begins_with("--size="):
			var p := a.trim_prefix("--size=").split("x"); sz = Vector2i(int(p[0]), int(p[1]))
		elif a == "--picker": picker = true
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	var usable := DisplayServer.screen_get_usable_rect()
	DisplayServer.window_set_size(Vector2i(320, 180))
	DisplayServer.window_set_position(usable.position + usable.size - Vector2i(340, 220))
	call_deferred("_run")

func _run() -> void:
	var vp := SubViewport.new()
	vp.size = sz
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = false
	root.add_child(vp)
	var host := Control.new()
	host.size = Vector2(sz)
	vp.add_child(host)
	var title: Control = (load("res://scenes/lshu_ui/lshu_title_screen.tscn") as PackedScene).instantiate()
	host.add_child(title)
	# 开场根节点自己铺满父节点（锚点全满），这里不再设 size
	var preview := TextureRect.new()
	preview.texture = vp.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(preview)
	# 等入场动画放完（约 2.4 秒）
	await create_timer(3.2).timeout
	if picker:
		title.call("_open_picker")
		await create_timer(1.4).timeout
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var err := img.save_png(out)
	print("LSHU_TITLE_CAPTURE ", JSON.stringify({"out": out, "size": [img.get_width(), img.get_height()], "err": err,
		"new_game_button": title.get_node_or_null("%NewGameButton") != null}))
	# 先停音乐、释放开场再退出，否则正在播放的背景音乐会在退出时报资源泄漏
	var bgm := title.get_node("TitleBgm") as AudioStreamPlayer
	bgm.stop()
	bgm.stream = null
	title.queue_free()
	await create_timer(0.3).timeout
	quit(0 if err == OK else 1)
