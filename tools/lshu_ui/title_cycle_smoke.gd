extends SceneTree
## 冒烟：开场「换开场」轮一圈（旅行L叔 → 各幕 → 旅行L叔），检查插画 / 成片的显隐和插画是否在跑；
## 再打开、关掉选幕页，检查插画暂停和恢复。用法：-- --lshu-unlock-all（不写存档）
func _initialize() -> void:
	call_deferred("_run")

func _state(title: Control) -> Dictionary:
	var home: Control = title.get_node("HomeScene")
	var prog: Object = title.get("progress")
	var bg := title.get("bg") as TextureRect
	return {"id": prog.call("current_title_id"), "home_visible": home.visible,
		"home_running": home.process_mode != Node.PROCESS_MODE_DISABLED, "bg_alpha": snappedf(bg.modulate.a, 0.01)}

func _run() -> void:
	var title: Control = (load("res://scenes/lshu_ui/lshu_title_screen.tscn") as PackedScene).instantiate()
	root.add_child(title)
	await create_timer(0.5).timeout
	var steps: Array = [_state(title)]
	var ok := true
	var ids: Array = title.get("progress").call("title_ids")
	for i in ids.size():
		title.call("_cycle_title_scene")
		await create_timer(1.0).timeout
		var st := _state(title)
		steps.append(st)
		var is_home: bool = st.id == "home"
		if is_home != bool(st.home_running) or is_home != (st.bg_alpha < 0.5) or (not is_home and st.home_visible):
			ok = false
	title.call("_open_picker")
	await create_timer(0.6).timeout
	var in_picker := _state(title)
	title.call("_close_picker")
	await create_timer(0.6).timeout
	var after := _state(title)
	if bool(in_picker.home_running) or not bool(after.home_running):
		ok = false
	print("LSHU_TITLE_CYCLE ", JSON.stringify({"ok": ok, "steps": steps, "picker_open": in_picker, "picker_closed": after}))
	var bgm := title.get_node("TitleBgm") as AudioStreamPlayer
	bgm.stop()
	bgm.stream = null
	title.queue_free()
	await create_timer(0.3).timeout
	quit(0 if ok else 1)
