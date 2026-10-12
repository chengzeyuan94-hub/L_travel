extends RefCounted
## 盘橐旅人 · 光影探针（导演探针，不是交付代码）。挂在 panti_viewer 的克隆上，PANTI_READY 之前执行。
##
## variant 结构（"base" 继承一层，同名顶层节整节覆盖）：
##   "static":   一次性：{"extra_scripts": [{"script", "cfg"}], "day_sky": {ProceduralSkyMaterial 属性}}
##   "morning" / "midnight": 两个时段各自的数值，watcher 每帧按过渡权重 w（0 清晨 → 1 深夜）插值后写入：
##       "sun":      {light_color, light_energy, sunel, sunaz, shadow_* 等 DirectionalLight3D 属性}
##       "env":      {Environment 属性}
##       "lights":   {"节点名": {light_energy, light_color, omni_range ...}}（extra 脚本建的灯按名字找）
##       "shaders":  {"文件名.gdshader": {uniform: 值}}（场景里所有用这个 shader 的材质，含 next_pass 链）
##       "materials":{"节点名通配": {StandardMaterial3D 属性}}（改该节点当前生效的材质副本）
##   只在一个时段里写了的键：另一个时段取场景原值（watcher 启动时记下），所以只写需要改的即可。
## watcher 的 process_priority 很大，排在 weather / 时段过渡之后，所以点篝火切换时也按权重正确混合。
var host: Node3D
var variant: Dictionary = {}
var ev: Dictionary = {"applied": [], "notes": []}

func apply(h: Node3D) -> void:
	host = h
	var vname := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lookdev="):
			vname = arg.trim_prefix("--lookdev=")
		if arg.begins_with("--park="):
			_park(int(arg.trim_prefix("--park=")))
	ev["variant"] = vname
	if vname.is_empty():
		_force_blend(null)
		print("PANTI_OVERLAY ", JSON.stringify(ev))
		return
	variant = _load(vname)
	var st: Dictionary = variant.get("static", {})
	if st.has("day_sky"):
		_day_sky(st.day_sky)
	for item in st.get("extra_scripts", []):
		var r: Variant = load(str(item.script)).new().call("build", host, item.get("cfg", {}))
		ev.applied.append({"extra_script": str(item.script).get_file(), "result": r})
	var watcher: Node = load("res://tools/traveler/lookdev_panti/panti_period_watcher.gd").new()
	watcher.name = "LookdevPeriodWatcher"
	host.add_child(watcher)
	var info: Dictionary = watcher.call("configure", host, variant.get("morning", {}), variant.get("midnight", {}))
	ev.applied.append({"watcher": info})
	_force_blend(watcher)
	print("PANTI_OVERLAY ", JSON.stringify(ev))

func _park(slot: int) -> void:
	var wid := DisplayServer.MAIN_WINDOW_ID
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(wid))
	var size := Vector2i(400, 225)
	DisplayServer.window_set_size(size, wid)
	DisplayServer.window_set_position(usable.position + usable.size - Vector2i((slot % 4 + 1) * (size.x + 8), (slot / 4 + 1) * (size.y + 36)), wid)

func _load(n: String) -> Dictionary:
	var path := "res://tools/traveler/lookdev_panti/variants/%s.json" % n
	if not FileAccess.file_exists(path):
		push_error("panti variant missing: " + path)
		return {}
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	if d.has("base"):
		var b := _load(str(d.base))
		for k in d.keys():
			if k != "base":
				b[k] = d[k]
		d = b
	return d

func _day_sky(c: Dictionary) -> void:
	var pt: RefCounted = host.get("period_transition")
	var sky: Sky = pt.get("day_sky") if pt != null else host.environment.sky
	var pm := sky.sky_material as ProceduralSkyMaterial
	if pm == null:
		ev.notes.append("day sky is not ProceduralSkyMaterial")
		return
	for k in c.keys():
		var v: Variant = c[k]
		if v is Array:
			v = Color(float(v[0]), float(v[1]), float(v[2]))
		pm.set(k, v)
	ev.applied.append({"day_sky": c.keys()})

## --blend=0.5：把清晨↔深夜过渡定在某个权重上（验证点篝火切换的中间帧）。
func _force_blend(watcher: Node) -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--blend="):
			var pt: RefCounted = host.get("period_transition")
			if pt == null:
				ev.notes.append("no period_transition")
				return
			var w := clampf(float(arg.trim_prefix("--blend=")), 0.0, 1.0)
			pt.set("target_period", "midnight" if w >= 0.5 else "morning")
			pt.set("weight", w)
			pt.call("_apply")
			if watcher != null:
				watcher.call("_apply", w)
			ev["forced_blend"] = w
