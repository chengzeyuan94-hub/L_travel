extends SceneTree
## 加载页截图：--out=PNG [--size=1920x1080] [--progress=0.62] [--status=铺开地图…] [--city=长安] [--difficulty=shanhai] [--color=red]
##   [--seats=HA|HAAA|HHAA|HHHH…]（按座位顺序 H 真人 / A 电脑；颜色按 --color 起依次排，电脑难度 7/12/16 岁轮着来）
## 进度直接跳到指定值（不走动画）再拍。窗口停在屏幕右下角置顶的小窗里（被遮挡的窗口 macOS 不绘制）。
var out := ""
var sz := Vector2i(1920, 1080)
var progress := 0.62
var status := "铺开地图…"
var city := "长安"
var difficulty := "shanhai"
var color := "red"
var seats := "HA"

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="): out = a.trim_prefix("--out=")
		elif a.begins_with("--size="):
			var p := a.trim_prefix("--size=").split("x"); sz = Vector2i(int(p[0]), int(p[1]))
		elif a.begins_with("--progress="): progress = float(a.trim_prefix("--progress="))
		elif a.begins_with("--status="): status = a.trim_prefix("--status=")
		elif a.begins_with("--city="): city = a.trim_prefix("--city=")
		elif a.begins_with("--difficulty="): difficulty = a.trim_prefix("--difficulty=")
		elif a.begins_with("--color="): color = a.trim_prefix("--color=")
		elif a.begins_with("--seats="): seats = a.trim_prefix("--seats=")
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	var usable := DisplayServer.screen_get_usable_rect()
	DisplayServer.window_set_size(Vector2i(320, 180))
	DisplayServer.window_set_position(usable.position + usable.size - Vector2i(340, 220))
	call_deferred("_run")

func _run() -> void:
	var vp := SubViewport.new()
	vp.size = sz
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var host := Control.new()
	host.size = Vector2(sz)
	vp.add_child(host)
	var screen: Control = (load("res://scenes/lshu_ui/lshu_loading_screen.tscn") as PackedScene).instantiate()
	host.add_child(screen)
	screen.visible = true
	var preview := TextureRect.new()
	preview.texture = vp.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(preview)
	await process_frame
	# 座位名字的默认值从 LshuSeats 取；它引用 GameState（自动加载），-s 模式下要等运行起来再 load
	var seats_script: GDScript = load("res://scripts/lshu_ui/lshu_seats.gd")
	var palette: Array = ["red", "blue", "green", "yellow"]
	var start: int = maxi(palette.find(color), 0)
	var diffs: Array = [difficulty, "qingzhuang", "wanli"]
	var configs: Array = []
	var humans := 0
	var ais := 0
	for i in seats.length():
		var c := {"color_id": palette[(start + i) % 4]}
		if seats[i] == "A":
			c["controller_type"] = "AI"
			c["display_name"] = seats_script.call("default_ai_name", ais)
			c["ai_difficulty"] = diffs[ais % 3]
			ais += 1
		else:
			c["controller_type"] = "LOCAL_HUMAN"
			c["display_name"] = seats_script.call("default_human_name", i)
			humans += 1
		configs.append(c)
	screen.call("begin", configs, {"home_city_name": city})
	screen.call("set_stage", status, progress)
	screen.set("_display", progress)
	screen.set("_creep_to", progress)
	await create_timer(1.2).timeout
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var err := img.save_png(out)
	print("LSHU_LOADING_CAPTURE ", JSON.stringify({"out": out, "err": err, "size": [img.get_width(), img.get_height()]}))
	screen.queue_free()
	await create_timer(0.3).timeout
	quit(0 if err == OK else 1)
