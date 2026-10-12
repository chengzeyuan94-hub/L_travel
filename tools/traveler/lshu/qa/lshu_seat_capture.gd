extends SceneTree
## 第四幕「L叔在哪儿」· QA capture harness with the feet-on-ground scan (qa/lshu_seat_scan.gd) attached once the
## tile is ready; same fixed 1920x1080 MSAA 4x SubViewport as tools/traveler/capture_traveler.gd. The scan result
## goes into the capture JSON under extra.seat_scan and is printed as LSHU_SEAT_SCAN.
## All scene args (--tile, --light, --capture, --park, --motion-freeze) pass through unchanged; --seat-samples=N
## sets the idle-cycle samples (default 24); --seat-fit=off turns the fix #1 seat fit off for this run (look
## config character.seat_fit.enabled = false, set before the tile is placed) to capture the unfitted state.
##   Godot --path . --script res://tools/traveler/lshu/qa/lshu_seat_capture.gd -- --tile=<pool id> --light=night
##         --motion-freeze --park=2 --capture=/abs/out.png

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const SEAT_SCAN: GDScript = preload("res://tools/traveler/lshu/qa/lshu_seat_scan.gd")

var scene: Node3D
var probe: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	var viewport: SubViewport = SubViewport.new()
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
	scene.connect("tile_ready", _on_tile_ready, CONNECT_ONE_SHOT)
	viewport.add_child(scene)
	if OS.get_cmdline_user_args().has("--seat-fit=off"):
		# _ready is now suspended in load_tile (the tile JSON is read on a worker thread); place() runs later.
		if scene.get("tile") != null:
			push_error("LSHU seat-fit=off: the tile was placed before the override could be set")
		var ch: Dictionary = (scene.get("look").get("cfg") as Dictionary).get("character", {})
		ch["seat_fit"] = {"enabled": false}

func _on_tile_ready(_id: String) -> void:
	var samples: int = 24
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--seat-samples="):
			samples = int(arg.trim_prefix("--seat-samples="))
	probe = SEAT_SCAN.new() as Node
	root.add_child(probe)
	probe.call("start", scene, samples)
