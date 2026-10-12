extends SceneTree
## 第四幕「L叔在哪儿」· QA only: tune the night lamp numbers against L叔's findability (qa/lshu_findability.gd) on one
## tile in the night preset, without touching look.json: each variant overrides the in-memory night_lamp section,
## rebuilds the lamp and measures. Same 1920x1080 MSAA 4x SubViewport as lshu_qa_capture.gd, motion frozen.
##   Godot --path . --script res://tools/traveler/lshu/qa/lshu_night_lamp_tune.gd -- --tile=<id> --park=22
##         --motion-freeze --light=night --out=/abs/tune.json --variants='[{"character_energy":0.0},{"character_energy":1.0}]'
##         [--png-dir=/abs/dir]   (one PNG per variant)

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const FINDABILITY: GDScript = preload("res://tools/traveler/lshu/qa/lshu_findability.gd")
const NIGHT_LAMP: GDScript = preload("res://scripts/traveler/lshu/lshu_night_lamp.gd")

var scene: Node3D
var viewport: SubViewport

func _initialize() -> void:
	call_deferred("_run")

func _arg(key: String, fallback: String) -> String:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--" + key + "="):
			return a.trim_prefix("--" + key + "=")
	return fallback

func _run() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	viewport = SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(viewport)
	var preview: TextureRect = TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scene = (load(SCENE) as PackedScene).instantiate() as Node3D
	viewport.add_child(scene)
	await scene.tile_ready
	await scene.prewarm_done
	var variants: Variant = JSON.parse_string(_arg("variants", "[{}]"))
	var png_dir: String = _arg("png-dir", "")
	var look: RefCounted = scene.get("look")
	var base: Dictionary = (look.call("sec", "night_lamp") as Dictionary).duplicate(true)
	var rows: Array = []
	var i: int = 0
	for v: Variant in variants:
		var nl: Dictionary = look.call("sec", "night_lamp")
		nl.clear()
		nl.merge(base.duplicate(true))
		nl.merge(v as Dictionary, true)
		var tile: Node3D = scene.get("tile")
		var old: Node3D = scene.get("night_lamp") as Node3D
		if old != null:
			old.free()
		var lamp: Node3D = NIGHT_LAMP.new() as Node3D
		tile.add_child(lamp)
		var rep: Dictionary = lamp.call("setup", look, tile, scene.get("character"), scene.get("camera"), true)
		scene.set("night_lamp", lamp)
		scene.call("_apply_light")
		for _f: int in 20:
			await RenderingServer.frame_post_draw
		if not png_dir.is_empty():
			DirAccess.make_dir_recursive_absolute(png_dir)
			viewport.get_texture().get_image().save_png(png_dir.path_join("%s_v%02d.png" % [str(scene.get("tile_id")), i]))
		var probe: Node = FINDABILITY.new() as Node
		root.add_child(probe)
		probe.call("start", scene)
		while (probe.get("result") as Dictionary).is_empty():
			await RenderingServer.frame_post_draw
		var res: Dictionary = probe.get("result")
		probe.queue_free()
		rows.append({"variant": v, "lamp": rep, "findability": res})
		print("LSHU_TUNE ", JSON.stringify({"i": i, "variant": v, "mode": rep.get("mode"), "delta_e": res.get("delta_e"), "delta_l": res.get("delta_l"), "salience": res.get("salience")}))
		i += 1
	var f: FileAccess = FileAccess.open(_arg("out", "user://tune.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"tile": scene.get("tile_id"), "rows": rows}, " "))
	f.close()
	quit(0)
