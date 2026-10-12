extends SceneTree
## 第四幕「L叔在哪儿」· QA capture harness: same fixed 1920x1080 MSAA 4x SubViewport as
## tools/traveler/capture_traveler.gd, plus QA-only measurements attached from outside the scene:
##   --findability   L叔 findability (qa/lshu_findability.gd) written into the capture JSON under extra.findability
## All scene args (--tile, --light, --capture, --park, --motion-freeze) pass through unchanged.
##   Godot --path . --script res://tools/traveler/lshu/qa/lshu_qa_capture.gd -- --tile=D01 --light=night
##         --motion-freeze --park=1 --findability --capture=/abs/out.png

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const FINDABILITY: GDScript = preload("res://tools/traveler/lshu/qa/lshu_findability.gd")

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

func _on_tile_ready(_id: String) -> void:
	if OS.get_cmdline_user_args().has("--findability"):
		probe = FINDABILITY.new() as Node
		root.add_child(probe)
		probe.call("start", scene)
