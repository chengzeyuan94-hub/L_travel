extends SceneTree
## 第四幕 · actor motion switch probe: frame times (process_frame to process_frame) around load_tile + bind_tile +
## arrive for a few tiles, after the scene prewarm and motion.prepare(). --nomotion measures the same switches without
## the motion module. Last lines: BIND <tile> max_frame_ms=... frames=[...]
##   Godot --path . --script res://tools/traveler/lshu/tests/actor_motion_switch_probe.gd -- --tile=D05 --light=day --park=23 [--nomotion]
const MOTION_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_actor_motion.gd")
var frame_ms: Array = []
var last: int = 0
var rec: bool = false
func _initialize() -> void:
	call_deferred("_run")
func _on_frame() -> void:
	var now: int = Time.get_ticks_usec()
	if rec and last > 0:
		frame_ms.append(snappedf(float(now - last) / 1000.0, 0.1))
	last = now
func _run() -> void:
	var viewport: SubViewport = SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var preview: TextureRect = TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scene: Node3D = (load("res://scenes/traveler/lshu_main.tscn") as PackedScene).instantiate() as Node3D
	viewport.add_child(scene)
	while scene.get("tile") == null or bool(scene.get("loading")):
		await process_frame
	if not bool(scene.get("prewarmed")):
		await scene.prewarm_done
	var motion: Node = MOTION_SCRIPT.new()
	scene.add_child(motion)
	motion.call("setup", scene.get("character"), scene.get("look"))
	await motion.call("prepare")
	process_frame.connect(_on_frame)
	for id: String in ["D02", "D01", "D08", "D05"]:
		for _i: int in 30:
			await process_frame
		frame_ms.clear()
		rec = true
		await scene.call("load_tile", id, 6.0)
		var plan: Dictionary = {}
		if not OS.get_cmdline_user_args().has("--nomotion"):
			plan = await motion.call("bind_tile", scene.get("tile"), scene.get("camera"), 0.0, true)
			motion.call("arrive", 0.1)
		for _j: int in 10:
			await process_frame
		rec = false
		var mx: float = 0.0
		for v: Variant in frame_ms:
			mx = maxf(mx, float(v))
		print("BIND ", id, " max_frame_ms=", mx, " frames=", frame_ms, " parts=", plan.get("collider_part_ms"), " main_plan=", plan.get("main_thread_plan_ms"))
	quit(0)
