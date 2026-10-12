extends Node
## 城市原型的引擎内四向正交截图（docs/design/map-editor-20260930/DESIGN.md 3.13.5 第 5、6 步；WP6a 的工具，WP6b 验收模型用）。
## 模型按棋盘的读法放：GLTFDocument 读原始 GLB（review.gd:643-650），按 bounds 的中心对齐、按 foot / building_width 缩放
## （review.gd:1222-1226），也就是棋盘上的大小；像素比例取棋盘默认缩放下一座城约 118 px 宽（play_board.gd:23-25）。
## 四张图都是水平视线的正交投影：front 从南（+z）往北看，back 从北往南，left 从西（-x）往东，right 从东往西；
## 主光固定在每个镜头的左上方，四张的明暗一致，方便和四视图对照。背景透明。
##
## 用法（要窗口；HOME 指到 scratch；--audio-driver Dummy）：
##   godot --path . --audio-driver Dummy res://tools/custom_map/catalogue_ortho.tscn -- --id=<原型 id> [--out=<abs 目录>]
##         [--px=118] [--scale=1] [--sheet] [--thumb=<abs png>]
##   godot --path . --audio-driver Dummy res://tools/custom_map/catalogue_ortho.tscn -- --model=<res:// 或绝对路径的 glb> [--foot=3.4] --out=<abs 目录>
##     --id      从 data/custom_map/catalogue_v1.json 读这个原型的 model、bounds、foot；
##               --out 默认 art-src/custom-map/archetypes/<id>/（DESIGN 3.13.5 的交付位置）；
##     --px      城在图上的宽度（像素），默认 118 = 棋盘默认缩放；--scale=N 整体放大 N 倍（看细节用）；
##     --sheet   另存一张四图并排的 05-ortho-sheet.png；
##     --thumb   另存一张 256×256 的缩略图：棋盘相机的俯角（0.76 rad）和城市朝向（CITY_YAW），城占画面约八成宽。
## 输出 05-ortho-front.png、05-ortho-back.png、05-ortho-left.png、05-ortho-right.png；最后一行 CATALOGUE_ORTHO ok … 或 FAILED。

const CATALOGUE := "res://data/custom_map/catalogue_v1.json"
const DEFAULT_PX := 118
const DEFAULT_FOOT := 3.4
## 图的边长 = 城宽像素 × 这个倍数（留出高度和边距）
const FRAME := 2.2
const THUMB_SIZE := 256
const THUMB_FILL := 0.8
## 与 tools/merchant_board_claude_review.gd 的 GAME_PITCH、CITY_YAW 相同
const GAME_PITCH := 0.76
const CITY_YAW := -0.44
const VIEWS := {
	"front": Vector3(0, 0, 1),
	"back": Vector3(0, 0, -1),
	"left": Vector3(-1, 0, 0),
	"right": Vector3(1, 0, 0),
}
const VIEW_ORDER: Array[String] = ["front", "back", "left", "right"]

var _viewport: SubViewport
var _camera: Camera3D
var _key: DirectionalLight3D
var _fill: DirectionalLight3D


func _ready() -> void:
	call_deferred("_main")


func _main() -> void:
	var args := OS.get_cmdline_user_args()
	var opt := {"id": "", "model": "", "out": "", "px": DEFAULT_PX, "scale": 1, "sheet": false, "thumb": "", "foot": -1.0}
	for a in args:
		if a.begins_with("--id="):
			opt.id = a.trim_prefix("--id=")
		elif a.begins_with("--model="):
			opt.model = a.trim_prefix("--model=")
		elif a.begins_with("--out="):
			opt.out = a.trim_prefix("--out=")
		elif a.begins_with("--px="):
			opt.px = int(a.trim_prefix("--px="))
		elif a.begins_with("--scale="):
			opt.scale = maxi(1, int(a.trim_prefix("--scale=")))
		elif a.begins_with("--foot="):
			opt.foot = float(a.trim_prefix("--foot="))
		elif a.begins_with("--thumb="):
			opt.thumb = a.trim_prefix("--thumb=")
		elif a == "--sheet":
			opt.sheet = true
	var spec := _resolve(opt)
	if spec.has("error"):
		_done(false, String(spec.error))
		return
	var node := _load_model(String(spec.model))
	if node == null:
		_done(false, "模型读不出来：%s" % spec.model)
		return
	_build_stage(node, spec)
	var out_dir := String(spec.out)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var px := int(opt.px) * int(opt.scale)
	var size := int(round(px * FRAME))
	var images := {}
	for view in VIEW_ORDER:
		var img := await _render_view(view, spec, px, size)
		if img == null:
			_done(false, "截图失败：%s" % view)
			return
		var path := out_dir.path_join("05-ortho-%s.png" % view)
		img.save_png(path)
		images[view] = img
		print("CATALOGUE_ORTHO wrote %s (%dx%d)" % [path, img.get_width(), img.get_height()])
	if bool(opt.sheet):
		var sheet := Image.create(size * 4, size, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0, 0, 0, 0))
		for i in VIEW_ORDER.size():
			var img: Image = images[VIEW_ORDER[i]]
			img.convert(Image.FORMAT_RGBA8)
			sheet.blit_rect(img, Rect2i(0, 0, size, size), Vector2i(i * size, 0))
		var sp := out_dir.path_join("05-ortho-sheet.png")
		sheet.save_png(sp)
		print("CATALOGUE_ORTHO wrote %s" % sp)
	if not String(opt.thumb).is_empty():
		var th := await _render_thumb(spec)
		if th == null:
			_done(false, "缩略图失败")
			return
		DirAccess.make_dir_recursive_absolute(String(opt.thumb).get_base_dir())
		th.save_png(String(opt.thumb))
		print("CATALOGUE_ORTHO wrote %s (%dx%d)" % [opt.thumb, th.get_width(), th.get_height()])
	_done(true, "%s scale=%.3f building=%.3fx%.3fx%.3f" % [spec.model, spec.scale, spec.size.x, spec.size.y, spec.size.z])


func _done(ok: bool, msg: String) -> void:
	print(("CATALOGUE_ORTHO ok " if ok else "CATALOGUE_ORTHO FAILED ") + msg)
	get_tree().quit(0 if ok else 1)


## 取模型路径、bounds、foot：--id 从目录读；--model 直接给，bounds 按模型自己的包围盒算
func _resolve(opt: Dictionary) -> Dictionary:
	var spec := {"model": String(opt.model), "foot": float(opt.foot), "bounds": {}, "out": String(opt.out)}
	if not String(opt.id).is_empty():
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOGUE))
		if not (v is Dictionary):
			return {"error": "目录读不出来：%s" % CATALOGUE}
		var arche := {}
		for a in (v as Dictionary).get("archetypes", []):
			if String(a.get("id", "")) == String(opt.id):
				arche = a
		if arche.is_empty():
			return {"error": "目录里没有原型 %s" % opt.id}
		spec.model = String(arche.get("model", ""))
		spec.bounds = arche.get("bounds", {})
		if float(spec.foot) <= 0.0:
			spec.foot = float(arche.get("foot", DEFAULT_FOOT))
		if String(spec.out).is_empty():
			spec.out = ProjectSettings.globalize_path("res://art-src/custom-map/archetypes/%s" % opt.id)
	if String(spec.model).is_empty():
		return {"error": "要给 --id=<原型 id> 或 --model=<glb>"}
	if String(spec.out).is_empty():
		return {"error": "用 --model 时要给 --out=<绝对目录>"}
	if float(spec.foot) <= 0.0:
		spec.foot = DEFAULT_FOOT
	return spec


## 与棋盘相同：读原始 GLB 文件（开发时 res:// 换成磁盘路径）
func _load_model(path: String) -> Node3D:
	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	if not FileAccess.file_exists(abs_path):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(abs_path, state) != OK:
		return null
	return doc.generate_scene(state) as Node3D


func _build_stage(node: Node3D, spec: Dictionary) -> void:
	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_4X
	add_child(_viewport)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.86, 0.84, 0.92)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.1
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.22
	env.adjustment_contrast = 1.06
	var we := WorldEnvironment.new()
	we.environment = env
	_viewport.add_child(we)
	_key = DirectionalLight3D.new()
	_key.light_color = Color(1.0, 0.86, 0.7)
	_key.light_energy = 1.6
	_key.shadow_enabled = true
	_viewport.add_child(_key)
	_fill = DirectionalLight3D.new()
	_fill.light_color = Color(0.6, 0.66, 0.95)
	_fill.light_energy = 0.35
	_viewport.add_child(_fill)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.near = 0.05
	_camera.far = 200.0
	_viewport.add_child(_camera)
	# 棋盘的摆法（review.gd:1222-1226）：有 bounds 时按它的中心对齐、按 foot / building_width 缩放；没有时按模型自己的包围盒
	var holder := Node3D.new()
	holder.add_child(node)
	var acc := [null]
	_aabb(node, Transform3D.IDENTITY, acc)
	var box: AABB = acc[0] if acc[0] != null else AABB(Vector3(-1, 0, -1), Vector3(2, 1, 2))
	var bounds: Dictionary = spec.bounds
	var s := 1.0
	if bounds.has("building_width") and float(bounds.building_width) > 0.0:
		var c: Array = bounds.get("building_centre_xz", [0.0, 0.0])
		node.position -= Vector3(float(c[0]), 0.0, float(c[1]))
		s = float(spec.foot) / float(bounds.building_width)
	else:
		var centre := box.get_center()
		node.position -= Vector3(centre.x, box.position.y, centre.z)
		s = float(spec.foot) / maxf(box.size.x, box.size.z)
	holder.scale = Vector3.ONE * s
	_viewport.add_child(holder)
	spec["scale"] = s
	spec["size"] = box.size * s
	spec["height_mid"] = (box.position.y + box.size.y * 0.5) * s


func _aabb(node: Node, xf: Transform3D, acc: Array) -> void:
	var here := xf
	if node is Node3D:
		here = xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var b := here * (node as MeshInstance3D).mesh.get_aabb()
		acc[0] = b if acc[0] == null else (acc[0] as AABB).merge(b)
	for child in node.get_children():
		_aabb(child, here, acc)


func _render_view(view: String, spec: Dictionary, px: int, size: int) -> Image:
	_viewport.size = Vector2i(size, size)
	var dir: Vector3 = VIEWS[view]
	var target := Vector3(0.0, float(spec.height_mid), 0.0)
	# 城宽 foot 对应 px 个像素：画面高度（世界单位）= size / (px / foot)
	_camera.size = float(size) * float(spec.foot) / float(px)
	_camera.look_at_from_position(target + dir * 50.0, target, Vector3.UP)
	# 主光在镜头的左上方、补光在右边，四个方向一样
	var right := _camera.global_transform.basis.x
	_key.look_at_from_position(Vector3.ZERO, (-dir * 0.6 + right * 0.55 + Vector3.DOWN * 0.6).normalized(), Vector3.UP)
	_fill.look_at_from_position(Vector3.ZERO, (-dir * 0.5 - right * 0.7 + Vector3.DOWN * 0.3).normalized(), Vector3.UP)
	return await _grab()


func _render_thumb(spec: Dictionary) -> Image:
	_viewport.size = Vector2i(THUMB_SIZE, THUMB_SIZE)
	var target := Vector3(0.0, float(spec.height_mid), 0.0)
	# 棋盘相机从南边往北看、俯角 GAME_PITCH；城自己转 CITY_YAW（review.gd:1231）
	var back := Vector3(0.0, sin(GAME_PITCH), cos(GAME_PITCH)).rotated(Vector3.UP, -CITY_YAW)
	_camera.size = float(spec.foot) / THUMB_FILL
	_camera.look_at_from_position(target + back * 50.0, target, Vector3.UP)
	var right := _camera.global_transform.basis.x
	_key.look_at_from_position(Vector3.ZERO, (-back * 0.5 + right * 0.6 + Vector3.DOWN * 0.5).normalized(), Vector3.UP)
	_fill.look_at_from_position(Vector3.ZERO, (-back * 0.5 - right * 0.7 + Vector3.DOWN * 0.3).normalized(), Vector3.UP)
	return await _grab()


func _grab() -> Image:
	for i in 3:
		await RenderingServer.frame_post_draw
	var img := _viewport.get_texture().get_image()
	if img == null or img.is_empty():
		return null
	return img
