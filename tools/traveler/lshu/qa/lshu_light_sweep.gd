extends SceneTree
## 第四幕「L叔在哪儿」· QA: continuous light sweep. Same fixed 1920x1080 MSAA 4x SubViewport as lshu_qa_capture.gd.
## Loads one tile with frozen motion, waits for the live scene's prewarm, then applies light states through the
## scene's public API (set_light_state / set_light_blend) and saves one frame per state:
##   --mode=clock   a simulated 24 h of the loop clock (LshuClock.light_at, UTC wall clock, one sample per minute):
##                  every minute inside a transition plus the exact presets on both sides of it
##   --mode=even    --steps=N even blends t = k/N of each neighbouring preset pair (morning>day>sunset>night>morning)
##   --mode=both    clock, then even
## Frames: <out>/<tile>/<mode>_<index>.png at 480x270 (Lanczos from 1920x1080) for the luminance analysis; the exact
## preset samples of the clock mode are also written at full size (<mode>_<index>_full.png) for the t = 0 / 1 check.
## --hold-lamp holds the night lamp prop for the whole run (what the director does for a stay that reaches into the
## night); --night-lamp=off passes through to the scene. Writes <out>/<tile>/sweep_<mode>.json.
##   Godot --path . --script res://tools/traveler/lshu/qa/lshu_light_sweep.gd -- --tile=<id> --park=22
##         --motion-freeze --out=/abs/dir --mode=both --steps=20 [--settle=12] [--hold-lamp] [--night-lamp=off]

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const CLOCK: GDScript = preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const PAIRS: Array = [["morning", "day"], ["day", "sunset"], ["sunset", "night"], ["night", "morning"]]

var scene: Node3D
var viewport: SubViewport
var out_dir: String = ""
var tile_id: String = ""
var mode: String = "both"
var steps: int = 20
var settle: int = 12
var hold_lamp: bool = false
var small: Vector2i = Vector2i(480, 270)

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--tile="):
			tile_id = arg.trim_prefix("--tile=")
		elif arg.begins_with("--mode="):
			mode = arg.trim_prefix("--mode=")
		elif arg.begins_with("--steps="):
			steps = int(arg.trim_prefix("--steps="))
		elif arg.begins_with("--settle="):
			settle = int(arg.trim_prefix("--settle="))
		elif arg == "--hold-lamp":
			hold_lamp = true
	call_deferred("_run")

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
	for _i: int in 60:
		await RenderingServer.frame_post_draw
	var dir: String = out_dir.path_join(tile_id)
	DirAccess.make_dir_recursive_absolute(dir)
	var ok: bool = true
	if mode == "clock" or mode == "both":
		ok = await _sweep("clock", _clock_samples(), dir) and ok
	if mode == "even" or mode == "both":
		ok = await _sweep("even", _even_samples(), dir) and ok
	print("LSHU_SWEEP_DONE ", JSON.stringify({"tile": tile_id, "ok": ok, "dir": dir}))
	quit(0 if ok else 1)

## One simulated day of the clock at one-minute samples; keeps the minutes whose light differs from a neighbour.
func _clock_samples() -> Array:
	var cfg: Dictionary = CLOCK.call("load_config")
	cfg["tz_offset_minutes"] = 0
	var c: Dictionary = CLOCK.call("compile_config", cfg)
	var day0: int = 20720 * 86400
	var lights: Array = []
	for m: int in 1441:
		lights.append(CLOCK.call("light_at", float(day0 + m * 60), c))
	var out: Array = []
	for m: int in 1441:
		var cur: Dictionary = lights[m]
		var keep: bool = m == 0 or m == 1440
		for n: int in [m - 1, m + 1]:
			if n >= 0 and n <= 1440 and _key(lights[n]) != _key(cur):
				keep = true
		if keep:
			out.append({"minute": m, "hhmm": "%02d:%02d" % [(m / 60) % 24, m % 60], "light": cur,
				"exact": float(cur.blend) <= 0.0 or str(cur.preset_a) == str(cur.preset_b)})
	return out

func _even_samples() -> Array:
	var out: Array = []
	for pair: Array in PAIRS:
		for k: int in steps + 1:
			var t: float = float(k) / float(steps)
			out.append({"pair": "%s>%s" % [pair[0], pair[1]], "k": k, "light": {"preset_a": pair[0], "preset_b": pair[1], "blend": t}, "exact": k == 0 or k == steps})
	return out

static func _key(l: Dictionary) -> String:
	return "%s|%s|%.6f" % [l.preset_a, l.preset_b, float(l.blend)]

func _sweep(tag: String, samples: Array, dir: String) -> bool:
	var rows: Array = []
	var ok: bool = true
	for i: int in samples.size():
		var s: Dictionary = samples[i]
		var light: Dictionary = s.light
		scene.call("set_light_state", light)
		var lamp: Node3D = scene.get("night_lamp") as Node3D
		if hold_lamp and lamp != null:
			lamp.call("set_hold", true)
		for _f: int in settle:
			await RenderingServer.frame_post_draw
		var img: Image = viewport.get_texture().get_image()
		var file: String = "%s_%03d.png" % [tag, i]
		if bool(s.exact) and tag == "clock":
			var full: String = "%s_%03d_full.png" % [tag, i]
			if img.save_png(dir.path_join(full)) != OK:
				ok = false
			s["full"] = full
		img.resize(small.x, small.y, Image.INTERPOLATE_LANCZOS)
		if img.save_png(dir.path_join(file)) != OK:
			push_error("LSHU sweep save failed: " + file)
			ok = false
		var look: RefCounted = scene.get("look")
		s["file"] = file
		s["index"] = i
		s["night_weight"] = float(look.call("weight", "night"))
		s["light_name"] = str(look.get("light_name"))
		s["blend_report"] = look.get("blend_report")
		s["night_lamp"] = lamp.call("evidence") if lamp != null else {}
		rows.append(s)
	var f: FileAccess = FileAccess.open(dir.path_join("sweep_%s.json" % tag), FileAccess.WRITE)
	f.store_string(JSON.stringify({"schema": "lshu.light_sweep.v1", "tile": tile_id, "mode": tag, "settle_frames": settle, "hold_lamp": hold_lamp,
		"frame_size": [1920, 1080], "saved_size": [small.x, small.y], "samples": rows}, " "))
	f.close()
	return ok
