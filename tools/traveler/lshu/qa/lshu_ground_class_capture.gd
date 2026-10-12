extends SceneTree
## 第四幕「L叔在哪儿」· QA only (fix #5 evidence): ground-class mask frames for a tile, same camera as the normal
## capture. Loads scenes/traveler/lshu_main.tscn exactly like qa/lshu_qa_capture.gd; once the tile is ready it swaps
## the shared ground material to qa/lshu_ground_class_mask.gdshader for two frames (pass A / pass B) with tonemap,
## fog, glow, adjustments, SSAO / SSIL and DOF off, saves <mask-out>_a.png / _b.png, then restores everything; the
## scene's own capture (--capture=...) runs afterwards and quits.
## --sand-counter=<v> instead forces the ground role's l2_sand_counter (fix #5) to v for this capture only, so a
## "before" frame can be rendered from the same code and look.json without editing the shared file.
##   Godot --path . --script res://tools/traveler/lshu/qa/lshu_ground_class_capture.gd -- --tile=<pool id> --light=day
##         --motion-freeze --park=5 --capture=/abs/junk.png --mask-out=/abs/<tile>_mask
##   Godot ... -- --tile=<pool id> --light=night --motion-freeze --park=5 --capture=/abs/<tile>_night.png --sand-counter=0

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const MASK_SHADER: Shader = preload("res://tools/traveler/lshu/qa/lshu_ground_class_mask.gdshader")
const COPY_PARAMS: Array[String] = ["l2_ground_col_tex", "height_rect", "l2_maps_ready", "l2_ground_smooth"]

var scene: Node3D
var mask_out: String = ""
var sand_counter: float = -1.0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--mask-out="):
			mask_out = arg.trim_prefix("--mask-out=")
		elif arg.begins_with("--sand-counter="):
			sand_counter = float(arg.trim_prefix("--sand-counter="))
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
	if sand_counter >= 0.0:
		var mats: Dictionary = (scene.get("look") as RefCounted).get("materials")
		(mats["ground"] as ShaderMaterial).set_shader_parameter("l2_sand_counter", sand_counter)
		scene.call("add_report", "qa_override", {"ground.l2_sand_counter": sand_counter})
	if mask_out.is_empty():
		return
	var vp: Viewport = scene.get_viewport()
	var look: RefCounted = scene.get("look")
	var materials: Dictionary = look.get("materials")
	var ground: ShaderMaterial = materials["ground"]
	var env: Environment = scene.get("environment")
	var cam_attr: CameraAttributesPractical = scene.get("camera_attributes")
	for _i: int in 12:
		await RenderingServer.frame_post_draw
	# stash
	var saved_shader: Shader = ground.shader
	var saved_params: Dictionary = {}
	for p: String in COPY_PARAMS:
		saved_params[p] = ground.get_shader_parameter(p)
	var env_saved: Array[Variant] = [env.tonemap_mode, env.tonemap_exposure, env.adjustment_enabled, env.glow_enabled,
		env.ssao_enabled, env.ssil_enabled, env.fog_enabled, cam_attr.dof_blur_far_enabled, cam_attr.dof_blur_near_enabled,
		cam_attr.exposure_multiplier]
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.adjustment_enabled = false
	env.glow_enabled = false
	env.ssao_enabled = false
	env.ssil_enabled = false
	env.fog_enabled = false
	cam_attr.dof_blur_far_enabled = false
	cam_attr.dof_blur_near_enabled = false
	cam_attr.exposure_multiplier = 1.0
	ground.shader = MASK_SHADER
	for p2: String in COPY_PARAMS:
		ground.set_shader_parameter(p2, saved_params[p2])
	var imgs: Array[Image] = []
	for pass_i: int in 2:
		ground.set_shader_parameter("mask_pass", float(pass_i))
		for _j: int in 4:
			await RenderingServer.frame_post_draw
		imgs.append(vp.get_texture().get_image())
	DirAccess.make_dir_recursive_absolute(mask_out.get_base_dir())
	var err_a: int = imgs[0].save_png(mask_out + "_a.png")
	var err_b: int = imgs[1].save_png(mask_out + "_b.png")
	# restore
	ground.shader = saved_shader
	for p3: String in COPY_PARAMS:
		ground.set_shader_parameter(p3, saved_params[p3])
	env.tonemap_mode = env_saved[0]
	env.tonemap_exposure = env_saved[1]
	env.adjustment_enabled = env_saved[2]
	env.glow_enabled = env_saved[3]
	env.ssao_enabled = env_saved[4]
	env.ssil_enabled = env_saved[5]
	env.fog_enabled = env_saved[6]
	cam_attr.dof_blur_far_enabled = env_saved[7]
	cam_attr.dof_blur_near_enabled = env_saved[8]
	cam_attr.exposure_multiplier = env_saved[9]
	print("LSHU_GROUND_MASK ", JSON.stringify({"a": mask_out + "_a.png", "b": mask_out + "_b.png", "error": err_a + err_b}))
	if err_a != OK or err_b != OK:
		push_error("LSHU ground-class mask save failed: " + mask_out)
