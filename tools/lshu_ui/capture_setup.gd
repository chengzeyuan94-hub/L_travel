extends SceneTree
## 商旅设置页截图：--out=PNG [--size=1920x1080] [--scene=res://...tscn] [--wait=2.5] [--pick-color=N] [--difficulty=id]
##   L叔 设置页另有：[--seats=HA|HAAA|HHAA|HHHH…]（按座位顺序 H 真人 / A 电脑，2–4 位）[--diffs=qingzhuang,wanli,…]（按电脑顺序）
##   [--names=小明,小红,…]（按座位顺序，空的跳过）[--focus=N]（右栏看第 N 位，0 起）[--palette=N]（打开第 N 位的调色盘）
## 默认拍原设置页（scenes/player_setup_screen.tscn）；--scene 换成别的设置页场景。调用 begin_setup() 后等动画放完再拍。
## 窗口停在屏幕右下角置顶的小窗里（被遮挡的窗口 macOS 不绘制）。只读：不写存档、不改场景。
var out := ""
var sz := Vector2i(1920, 1080)
var scene_path := "res://scenes/player_setup_screen.tscn"
var wait := 2.5
var pick_color := -1
var difficulty := ""
var seed := 20260926
var seats := ""
var diffs: PackedStringArray = []
var names: PackedStringArray = []
var focus := -1
var palette := -1

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="): out = a.trim_prefix("--out=")
		elif a.begins_with("--size="):
			var p := a.trim_prefix("--size=").split("x"); sz = Vector2i(int(p[0]), int(p[1]))
		elif a.begins_with("--scene="): scene_path = a.trim_prefix("--scene=")
		elif a.begins_with("--wait="): wait = float(a.trim_prefix("--wait="))
		elif a.begins_with("--pick-color="): pick_color = int(a.trim_prefix("--pick-color="))
		elif a.begins_with("--difficulty="): difficulty = a.trim_prefix("--difficulty=")
		elif a.begins_with("--seed="): seed = int(a.trim_prefix("--seed="))
		elif a.begins_with("--seats="): seats = a.trim_prefix("--seats=")
		elif a.begins_with("--diffs="): diffs = a.trim_prefix("--diffs=").split(",")
		elif a.begins_with("--names="): names = a.trim_prefix("--names=").split(",")
		elif a.begins_with("--focus="): focus = int(a.trim_prefix("--focus="))
		elif a.begins_with("--palette="): palette = int(a.trim_prefix("--palette="))
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
	var screen: Control = (load(scene_path) as PackedScene).instantiate()
	host.add_child(screen)
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var preview := TextureRect.new()
	preview.texture = vp.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(preview)
	await process_frame
	var result: Variant = screen.call("begin_setup", seed) if screen.has_method("begin_setup") else {}
	# 设置页默认隐藏，平时由 main.gd 切过去时显示
	screen.visible = true
	screen.modulate.a = 1.0
	if pick_color >= 0 and screen.has_method("_select_color"):
		screen.call("_select_color", pick_color)
	if difficulty != "" and screen.has_method("_select_difficulty"):
		screen.call("_select_difficulty", difficulty)
	if seats != "" and screen.has_method("_add_seat"):
		# 先凑够座位数，再按顺序改真人 / 电脑（先改真人，免得碰上「至少一位真人」）
		for _n in 4:
			if (screen.get("_seats") as Array).size() >= seats.length():
				break
			screen.call("_add_seat")
		for i in seats.length():
			if seats[i] == "H":
				screen.call("_set_seat_type", i, "LOCAL_HUMAN")
		for i in seats.length():
			if seats[i] == "A":
				screen.call("_set_seat_type", i, "AI")
		var k := 0
		for i in seats.length():
			if seats[i] == "A" and k < diffs.size():
				screen.call("_pick_seat_difficulty", i, diffs[k])
				k += 1
	for i in names.size():
		if names[i] != "" and screen.has_method("_on_seat_name_changed"):
			var rows: Array = screen.get("_rows")
			if i < rows.size():
				(rows[i]["edit"] as LineEdit).text = names[i]
				if i == 0:
					screen.call("_on_name_changed", names[i])
				else:
					screen.call("_on_seat_name_changed", names[i], i)
	if focus >= 0 and screen.has_method("_focus"):
		screen.call("_focus", focus)
	if palette >= 0 and screen.has_method("_open_palette"):
		await create_timer(1.2).timeout
		screen.call("_open_palette", palette)
	await create_timer(wait).timeout
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var err := img.save_png(out)
	print("LSHU_SETUP_CAPTURE ", JSON.stringify({"out": out, "scene": scene_path, "size": [img.get_width(), img.get_height()], "err": err,
		"setup_ok": result is Dictionary and bool((result as Dictionary).get("success", false)),
		"message": String((result as Dictionary).get("message", "")) if result is Dictionary else "",
		"city": String((result as Dictionary).get("home_city_name", "")) if result is Dictionary else ""}))
	screen.queue_free()
	await create_timer(0.3).timeout
	quit(0 if err == OK else 1)
