extends Control
class_name Dice3DView

## 3D 骰子表现层（v2 · L叔玩具骰）：规则结果先确定，SpinPivot 负责多圈翻滚，FaceAlignPivot 把结果面转到朝上。
## 模型：assets/game/dice/dice_lshu_v2.glb（Blender 源 assets/game/ui/lshu_3d/source/lshu_icons.blend，
## 建模脚本 tools/ui_icons/assets/dice.py，概念与六面图 art-src/dice-v2/）。
## 落定姿态：结果面朝上，骰子绕竖轴偏转露出两个侧面，正交相机从前上方三分之四俯视；暖色主光 + 补光 + 轮廓光。
## 显示尺寸：set_display_size(px) 指定骰子可见包围盒（宽高较大者，控件坐标）；0 = 按控件短边自动适配。
## 渲染区比骰子大一圈（HEADROOM_RATIO，主要留在上方），给抛起与弹跳用；骰子落定时的中心 = 控件中心，
## 渲染区超出控件的部分直接画在控件外（父节点不要 clip_contents，否则抛起会被裁）。

signal roll_started
signal face_revealed(face: Variant)
signal roll_finished(face: Variant)

const MODEL_PATH := DiceMeshBuilder.MODEL_PATH
const ATLAS_PATH := "res://assets/game/dice/dice_face_atlas_v2.png"
const PLACEHOLDER_PATH := "res://assets/game/dice/dice_face_atlas_placeholder.png"
const SHADER_PATH := "res://assets/game/dice/dice_toy_body.gdshader"
const SHADOW_SHADER_PATH := "res://assets/game/dice/dice_soft_shadow.gdshader"
const GLOW_SHADER_PATH := "res://assets/game/dice/dice_result_glow.gdshader"
const FALLBACK_SHADER_PATH := "res://assets/game/dice/dice_fallback_face.gdshader"
## 布局前的默认渲染尺寸；布局后按“渲染区 × 屏幕缩放”重设，保证不被放大。
const VIEW_SIZE := Vector2i(256, 256)
const VIEW_ASPECT := 1.0

## 未指定显示尺寸时：骰子包围盒 = 控件短边 × AUTO_FIT_RATIO（旧 HUD 120×112 槽 → 104px）。
const AUTO_FIT_RATIO := 0.93
const TARGET_DICE_WIDTH_720 := 104.0
const MIN_DISPLAY_PX := 24.0
## 渲染区边长 / 骰子包围盒。
const HEADROOM_RATIO := 1.6
## 落定时骰子中心在渲染区里的高度（从上往下的比例）：上方多留给抛起，下方只留接地影子。
const DICE_CENTER_Y := 0.6
const MAX_OVERSAMPLE := 3.0
const GLOW_TO_DICE_RATIO := 1.18
## 三分之四俯视：相机仰角、骰子绕竖轴偏转（露出一宽一窄两个侧面）。
const CAMERA_ELEVATION_DEG := 50.0
const DICE_YAW_DEG := 32.0
const CAMERA_DISTANCE := 6.0
## 抛起高度（世界单位，骰子棱长 1.0）；渲染区上方约留 0.45 的屏幕空间。
const HOP_HEIGHT := 0.75
## 灯光（线性色调映射）：数值按“奶油色顶面 ≈ 原色、侧面依次压暗”调出。
const KEY_LIGHT_FROM := Vector3(-1.4, 4.0, 1.6)
const FILL_LIGHT_FROM := Vector3(3.0, 1.2, 2.0)
const RIM_LIGHT_FROM := Vector3(0.6, 1.6, -3.2)
const KEY_ENERGY := 0.72
const FILL_ENERGY := 0.18
const RIM_ENERGY := 0.30
const AMBIENT_ENERGY := 0.42
const CONTACT_SHADOW_ALPHA := 0.20
const EVENT_GLOW_PEAK_ALPHA := 0.14
const EVENT_GLOW_COLOR := Color(1.0, 0.91, 0.62)

## 表面参数：粘土 / 釉面 / 土豆花微光
const CLAY_ROUGHNESS := 0.66
const CLAY_SPECULAR := 0.30
const GLOSS_ROUGHNESS := 0.26
const GLOSS_SPECULAR := 0.55
const GLOW_EMISSION := 0.45
const GLOW_EMISSION_PEAK := 1.4

## 局部法线：1↔EVENT，2↔5，3↔4（与 DiceMeshBuilder、Blender 建模脚本一致）
const FACE_NORMALS := {
	1: Vector3(0, 1, 0),
	"EVENT": Vector3(0, -1, 0),
	2: Vector3(0, 0, 1),
	5: Vector3(0, 0, -1),
	3: Vector3(1, 0, 0),
	4: Vector3(-1, 0, 0),
}

## 显示尺寸（控件坐标 px）；0 = 按控件短边自动适配。
@export var display_size_px: float = 0.0:
	set(value):
		display_size_px = maxf(value, 0.0)
		if is_inside_tree():
			_layout_aspect_frame()

var _aspect_frame: Control
var _dice_texture: TextureRect
var _viewport: SubViewport
var _world: Node3D
var _camera: Camera3D
var _pres_root: Node3D
var _spin_pivot: Node3D
var _face_align: Node3D
var _dice_body: MeshInstance3D
var _soft_shadow: MeshInstance3D
var _result_glow: ColorRect
var _fallback: TextureRect
var _atlas: Texture2D
var _body_mat: ShaderMaterial
var _gloss_mat: ShaderMaterial
var _flower_mat: ShaderMaterial
var _shadow_mat: ShaderMaterial
var _glow_mat: ShaderMaterial
var _fallback_mat: ShaderMaterial
var _atlas_loaded := false
var _init_ok := false
var _rolling := false
var _idle := true
var _target_face: Variant = null
var _visible_face: Variant = null
var _triangle_count := 0
var _bob_t := 0.0
var _roll_tween: Tween
var _glow_tween: Tween
var _rng := RandomNumberGenerator.new()
var _rest_align := Quaternion.IDENTITY
var _force_fallback := false
var _dice_display_width := TARGET_DICE_WIDTH_720
var _projected_extent := 1.5
var _oversample := 1.0
var _presentation_generation := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(120, 112)
	_build_ui_shell()
	resized.connect(_layout_aspect_frame)
	if get_viewport() != null and not get_viewport().size_changed.is_connected(_layout_aspect_frame):
		get_viewport().size_changed.connect(_layout_aspect_frame)
	if _force_fallback:
		_init_ok = false
	else:
		_init_ok = _build_3d_world()
	_fallback.visible = not _init_ok
	_dice_texture.visible = _init_ok
	_layout_aspect_frame()
	if _init_ok:
		snap_to_face(1)
	else:
		_set_fallback_face(1)
	call_deferred("_layout_aspect_frame")
	set_process(true)


func _process(delta: float) -> void:
	if not _init_ok or _rolling or not visible or not _idle:
		return
	_bob_t += delta
	# 静置时轻轻“呼吸”：极小的上下浮动与摆动，结果面始终可读。
	if _pres_root:
		_pres_root.position.y = sin(_bob_t * 1.35) * 0.012
	if _spin_pivot:
		var bob := (
			Quaternion(Vector3.UP, deg_to_rad(sin(_bob_t * 0.6) * 1.8))
			* Quaternion(Vector3.RIGHT, deg_to_rad(cos(_bob_t * 0.5) * 0.8))
		)
		_spin_pivot.quaternion = bob.normalized()


func is_rolling() -> bool:
	return _rolling


## 指定骰子可见包围盒（宽高较大者，控件坐标 px）。0 = 按控件短边自动适配。
func set_display_size(px: float) -> void:
	display_size_px = px
	if not is_inside_tree():
		return
	_layout_aspect_frame()


func get_display_size() -> float:
	return _dice_display_width


func get_debug_state() -> Dictionary:
	return {
		"rolling": _rolling,
		"target_face": _target_face,
		"visible_face": _visible_face,
		"atlas_loaded": _atlas_loaded,
		"viewport_size": VIEW_SIZE if _viewport == null else _viewport.size,
		"init_ok": _init_ok,
		"triangle_count": _triangle_count,
		"face_camera_dot": get_face_camera_dot(_visible_face) if _visible_face != null else 0.0,
		"decal_count": _count_face_decals(),
		"content_size": Vector2.ZERO if _aspect_frame == null else _aspect_frame.size,
		"dice_display_width": _dice_display_width,
		"display_size_px": display_size_px,
		"fallback_uses_atlas": _fallback_mat != null and _atlas != null,
		"body_scale": 0.0 if _dice_body == null else _dice_body.scale.x,
		"glow_size": Vector2.ZERO if _result_glow == null else _result_glow.size,
		"camera_projection": _camera.projection if _camera else -1,
		"ortho_size": _camera.size if _camera else 0.0,
		"active_light_count": _count_active_lights(),
		"material_unshaded": _is_body_unshaded(),
		"target_display_px": _dice_display_width,
		"oversample": _oversample,
		"own_world_3d": _viewport != null and _viewport.own_world_3d,
		"model_path": MODEL_PATH,
	}


func get_triangle_count() -> int:
	return _triangle_count


func get_face_camera_dot(face: Variant = null) -> float:
	if not _init_ok or _camera == null or _face_align == null:
		return 0.0
	var key: Variant = _visible_face if face == null else face
	if key == null:
		return 0.0
	if typeof(key) != TYPE_STRING:
		key = int(key)
	if not FACE_NORMALS.has(key):
		return 0.0
	var local_n: Vector3 = FACE_NORMALS[key]
	var world_n := (_face_align.global_transform.basis * local_n).normalized()
	var cam_dir := (_camera.global_position - _face_align.global_position).normalized()
	return world_n.dot(cam_dir)


func force_fallback_for_tests() -> void:
	_force_fallback = true
	_init_ok = false
	if _dice_texture:
		_dice_texture.visible = false
	if _fallback:
		_fallback.visible = true
		_set_fallback_face(_visible_face if _visible_face != null else 1)


func get_atlas_image() -> Image:
	if _atlas == null:
		return null
	return _atlas.get_image()


## 表现签名：目标面必须朝向镜头，且该面 atlas 内容与 face id 绑定（headless 可证）。
func get_presentation_signature(face: Variant) -> String:
	var key: Variant = face if typeof(face) == TYPE_STRING else int(face)
	var dot := get_face_camera_dot(key)
	var img := get_atlas_image()
	var cell_sig := DiceMeshBuilder.atlas_cell_signature(img, key)
	return "%s|dot:%.4f|cell:%s" % [str(key), dot, cell_sig]


func capture_viewport_image() -> Image:
	if _viewport == null:
		return null
	# headless / dummy renderer 无法读回 3D 目标
	if DisplayServer.get_name() == "headless" or OS.has_feature("headless"):
		return null
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await get_tree().process_frame
	await get_tree().process_frame
	var tex := _viewport.get_texture()
	if tex == null:
		return null
	var img: Image = tex.get_image()
	if img == null or img.get_width() <= 0:
		return null
	return img


func snap_to_face(face: Variant) -> void:
	if not DiceSystem.is_valid_face(face):
		return
	_target_face = face
	_visible_face = face
	_rest_align = _quat_for_face(face)
	if _spin_pivot:
		_spin_pivot.quaternion = Quaternion.IDENTITY
	if _face_align:
		_face_align.quaternion = _rest_align
	if _pres_root:
		_pres_root.position = Vector3.ZERO
		_pres_root.scale = Vector3.ONE
	if _fallback:
		_set_fallback_face(face)
	_update_shadow(0.0)
	_request_presented_frame()


func roll_to_face(face: Variant) -> void:
	if _rolling:
		return
	if not DiceSystem.is_valid_face(face):
		return
	if not _init_ok:
		_rolling = true
		_fallback.visible = true
		_set_fallback_face(face)
		_target_face = face
		_visible_face = face
		roll_started.emit()
		face_revealed.emit(face)
		# deferred：避免调用方尚未 await 时同步 emit 导致永久卡死
		call_deferred("_finish_fallback_roll", face)
		return
	_rolling = true
	_idle = false
	_target_face = face
	_set_viewport_update(true)
	roll_started.emit()
	if _roll_tween:
		_roll_tween.kill()
	_roll_tween = create_tween()
	_roll_tween.set_parallel(false)

	# 表现层自己的随机数，不碰 GameState 的规则 RNG。
	_rng.randomize()
	var motion := {
		"axis_a": Vector3(_rng.randf_range(-0.4, 0.4), 1.0, _rng.randf_range(-0.3, 0.3)).normalized(),
		"axis_b": Vector3(1.0, _rng.randf_range(-0.3, 0.3), _rng.randf_range(-0.5, 0.5)).normalized(),
		# 整圈数：自旋在落定时正好回到单位姿态，不需要额外“归零”跳变。
		"turns_a": float(_rng.randi_range(1, 2)),
		"turns_b": float(_rng.randi_range(2, 3)),
		"from": _face_align.quaternion,
		"to": _quat_for_face(face),
	}
	_pres_root.scale = Vector3.ONE
	_pres_root.position = Vector3.ZERO
	_spin_pivot.quaternion = Quaternion.IDENTITY

	# 0.00–0.10s 蓄力下压
	_roll_tween.tween_method(_pose_anticipate, 0.0, 1.0, 0.10)
	# 0.10–1.02s 抛起翻滚 → 落地压扁 → 两次小弹跳 → 回稳
	_roll_tween.tween_method(func(t: float): _pose_flight(t, motion), 0.0, 1.0, 0.92)
	_roll_tween.tween_callback(func():
		_spin_pivot.quaternion = Quaternion.IDENTITY
		_face_align.quaternion = motion["to"]
		_rest_align = motion["to"]
		_pres_root.position = Vector3.ZERO
		_pres_root.scale = Vector3.ONE
		_visible_face = face
		_update_shadow(0.0)
		_request_presented_frame()
		face_revealed.emit(face)
		_play_result_fx(face)
	)
	# 1.02–1.35s 稳定展示
	_roll_tween.tween_interval(0.33)
	_roll_tween.tween_callback(func(): call_deferred("_finish_roll_after_present", face))


func _pose_anticipate(t: float) -> void:
	var sy := 1.0 - 0.12 * sin(t * PI * 0.5)
	_set_squash(sy)


## t ∈ [0,1] 覆盖 0.92s：主抛物线 → 落地 → 弹跳 1 → 弹跳 2 → 回稳。
func _pose_flight(t: float, m: Dictionary) -> void:
	# 自旋：先快后慢，t=0.80 时正好转完整圈
	var p := 1.0 - pow(1.0 - clampf(t / 0.80, 0.0, 1.0), 3.0)
	var spin := (
		Quaternion(m["axis_a"], TAU * float(m["turns_a"]) * p)
		* Quaternion(m["axis_b"], TAU * float(m["turns_b"]) * p)
	)
	_spin_pivot.quaternion = spin.normalized()
	var from_q: Quaternion = m["from"]
	_face_align.quaternion = from_q.slerp(m["to"], smoothstep(0.04, 0.80, t)).normalized()
	# 高度：主抛 0–0.52，弹跳 0.52–0.72，小弹 0.72–0.84
	var y := 0.0
	if t < 0.52:
		var u := t / 0.52
		y = HOP_HEIGHT * 4.0 * u * (1.0 - u)
	elif t < 0.72:
		var u := (t - 0.52) / 0.20
		y = HOP_HEIGHT * 0.22 * 4.0 * u * (1.0 - u)
	elif t < 0.84:
		var u := (t - 0.72) / 0.12
		y = HOP_HEIGHT * 0.06 * 4.0 * u * (1.0 - u)
	# 挤压：起跳释放 + 空中拉长 + 每次触地压扁，逐次减弱
	var sy := 1.0
	sy -= 0.12 * (1.0 - smoothstep(0.0, 0.07, t))
	if t < 0.52:
		# 上升和下落最快时略微拉长，顶点处恢复
		sy += 0.06 * absf(1.0 - 2.0 * t / 0.52) * smoothstep(0.02, 0.08, t) * (1.0 - smoothstep(0.44, 0.50, t))
	for impact in [[0.52, 0.13], [0.72, 0.07], [0.84, 0.035]]:
		var d := absf(t - float(impact[0]))
		sy -= float(impact[1]) * maxf(0.0, 1.0 - d / 0.05)
	if t > 0.86:
		sy += 0.02 * sin((t - 0.86) / 0.14 * TAU) * (1.0 - (t - 0.86) / 0.14)
	_set_squash(sy)
	_pres_root.position.y = y - (1.0 - sy) * 0.5
	_update_shadow(clampf(y / HOP_HEIGHT, 0.0, 1.0))


func _set_squash(sy: float) -> void:
	var side := 1.0 / sqrt(maxf(sy, 0.2))
	_pres_root.scale = Vector3(side, sy, side)


func _finish_fallback_roll(face: Variant) -> void:
	_rolling = false
	_idle = true
	roll_finished.emit(face)


## SubViewport 在 UPDATE_DISABLED/WHEN_VISIBLE 之间切换时，末帧有机会仍保留上一次翻滚贴图。
## 结果面须先强制提交两帧，再允许 GameScreen 解锁后续规则与 HUD 刷新。
func _finish_roll_after_present(face: Variant) -> void:
	if not _rolling:
		return
	_set_viewport_update(true)
	await get_tree().process_frame
	await get_tree().process_frame
	# 期间不会接受下一次 roll；保留防御性校验，避免节点退出后错误发信号。
	if not is_inside_tree() or not _rolling:
		return
	_rolling = false
	_idle = true
	_set_viewport_update(false)
	roll_finished.emit(face)


func _play_result_fx(face: Variant) -> void:
	if _glow_tween:
		_glow_tween.kill()
	_set_flower_emission(GLOW_EMISSION)
	# 普通点数面：不加光晕，只靠点数识别。
	if not DiceSystem.is_event_face(face):
		_set_glow_strength(0.0)
		_result_glow.visible = false
		return
	# EVENT：土豆花亮两下，身后一圈暖白柔光（局部径向，不改骰子尺寸）。
	_result_glow.visible = true
	_set_glow_color(Color(EVENT_GLOW_COLOR, EVENT_GLOW_PEAK_ALPHA))
	_glow_tween = create_tween()
	for _i in 2:
		_glow_tween.tween_method(_set_event_pulse, 0.0, 1.0, 0.12)
		_glow_tween.tween_method(_set_event_pulse, 1.0, 0.0, 0.16)
	_glow_tween.tween_callback(func():
		_set_event_pulse(0.0)
		_result_glow.visible = false
	)


func _set_event_pulse(value: float) -> void:
	_set_glow_strength(value)
	_set_flower_emission(lerpf(GLOW_EMISSION, GLOW_EMISSION_PEAK, clampf(value, 0.0, 1.0)))


func _set_flower_emission(value: float) -> void:
	if _flower_mat:
		_flower_mat.set_shader_parameter("emission_strength", value)


func _build_ui_shell() -> void:
	_load_atlas()
	_aspect_frame = Control.new()
	_aspect_frame.name = "AspectFrameSquare"
	_aspect_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_aspect_frame)

	# 局部径向光：只在骰子身后画一圈柔光，绝不产生矩形蒙层。
	_result_glow = ColorRect.new()
	_result_glow.name = "ResultGlow"
	_result_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_glow.color = Color.WHITE
	_result_glow.visible = false
	_glow_mat = ShaderMaterial.new()
	_glow_mat.shader = load(GLOW_SHADER_PATH) as Shader
	_result_glow.material = _glow_mat
	_aspect_frame.add_child(_result_glow)
	_set_glow_color(Color(EVENT_GLOW_COLOR, 0.0))
	_set_glow_strength(0.0)

	# 独立 3D 世界的子视口；按“渲染区 × 屏幕缩放”出图，再由 TextureRect 原尺寸贴回，避免放大糊。
	_viewport = SubViewport.new()
	_viewport.name = "DiceViewport"
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.size = VIEW_SIZE
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.handle_input_locally = false
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_aspect_frame.add_child(_viewport)

	_dice_texture = TextureRect.new()
	_dice_texture.name = "DiceTexture"
	_dice_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dice_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_dice_texture.stretch_mode = TextureRect.STRETCH_SCALE
	_dice_texture.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_dice_texture.texture = _viewport.get_texture()
	_aspect_frame.add_child(_dice_texture)

	_fallback = TextureRect.new()
	_fallback.name = "FallbackFace"
	_fallback.visible = false
	_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fallback.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fallback.texture = _atlas
	_fallback_mat = ShaderMaterial.new()
	_fallback_mat.shader = load(FALLBACK_SHADER_PATH) as Shader
	_fallback_mat.set_shader_parameter("atlas", _atlas)
	_fallback.material = _fallback_mat
	_aspect_frame.add_child(_fallback)


func _build_3d_world() -> bool:
	_load_atlas()
	var shader: Shader = load(SHADER_PATH) as Shader
	var shadow_shader: Shader = load(SHADOW_SHADER_PATH) as Shader
	var mesh := DiceMeshBuilder.load_model_mesh(MODEL_PATH)
	if not _atlas_loaded or shader == null or shadow_shader == null or mesh == null:
		return false

	_world = Node3D.new()
	_world.name = "WorldRoot"
	_viewport.add_child(_world)

	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	var el := deg_to_rad(CAMERA_ELEVATION_DEG)
	_camera.position = Vector3(0.0, sin(el), cos(el)) * CAMERA_DISTANCE
	_camera.near = 0.1
	_camera.far = CAMERA_DISTANCE * 2.0
	_world.add_child(_camera)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

	var env := WorldEnvironment.new()
	env.name = "WorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(1.0, 0.93, 0.84)
	environment.ambient_light_energy = AMBIENT_ENERGY
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.environment = environment
	_world.add_child(env)

	# 暖色主光（左上、偏头顶）+ 暖白补光（右前）+ 轮廓光（后上），都不投影：阴影由接地软影负责。
	# 顶面最亮、左侧面次之、右前侧面最暗，三个面拉开层次。
	_add_light("KeyLight", KEY_LIGHT_FROM, Color(1.0, 0.95, 0.86), KEY_ENERGY)
	_add_light("FillLight", FILL_LIGHT_FROM, Color(1.0, 0.94, 0.88), FILL_ENERGY)
	_add_light("RimLight", RIM_LIGHT_FROM, Color(1.0, 0.94, 0.84), RIM_ENERGY)

	_soft_shadow = MeshInstance3D.new()
	_soft_shadow.name = "SoftShadow"
	var quad := QuadMesh.new()
	# 接地软影：从三分之四俯视看是椭圆；尺寸与 alpha 不随点数面变化，只随抛起高度变淡变小。
	quad.size = Vector2(1.55, 1.55)
	_soft_shadow.mesh = quad
	_soft_shadow.position = Vector3(0.0, -0.505, 0.0)
	_soft_shadow.rotation_degrees = Vector3(-90, DICE_YAW_DEG, 0)
	_shadow_mat = ShaderMaterial.new()
	_shadow_mat.shader = shadow_shader
	_shadow_mat.render_priority = -1
	_shadow_mat.set_shader_parameter("shadow_color", Color(0.30, 0.20, 0.12, CONTACT_SHADOW_ALPHA))
	_soft_shadow.material_override = _shadow_mat
	_soft_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(_soft_shadow)

	_pres_root = Node3D.new()
	_pres_root.name = "DicePresentationRoot"
	_world.add_child(_pres_root)

	_spin_pivot = Node3D.new()
	_spin_pivot.name = "SpinPivot"
	_pres_root.add_child(_spin_pivot)

	_face_align = Node3D.new()
	_face_align.name = "FaceAlignPivot"
	_spin_pivot.add_child(_face_align)

	_dice_body = MeshInstance3D.new()
	_dice_body.name = "DiceBody"
	_dice_body.mesh = mesh
	_dice_body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_triangle_count = DiceMeshBuilder.triangle_count(mesh)
	_body_mat = _make_surface_mat(shader, CLAY_ROUGHNESS, CLAY_SPECULAR, 0.0, 0.10)
	_gloss_mat = _make_surface_mat(shader, GLOSS_ROUGHNESS, GLOSS_SPECULAR, 0.0, 0.05)
	_flower_mat = _make_surface_mat(shader, 0.45, 0.30, GLOW_EMISSION, 0.0)
	for i in mesh.get_surface_count():
		match DiceMeshBuilder.surface_role(mesh, i):
			DiceMeshBuilder.ROLE_GLOSS:
				_dice_body.set_surface_override_material(i, _gloss_mat)
			DiceMeshBuilder.ROLE_GLOW:
				_dice_body.set_surface_override_material(i, _flower_mat)
			_:
				_dice_body.set_surface_override_material(i, _body_mat)
	_face_align.add_child(_dice_body)
	_projected_extent = _measure_projected_extent(mesh)
	return true


func _add_light(light_name: String, from: Vector3, color: Color, energy: float) -> void:
	var light := DirectionalLight3D.new()
	light.name = light_name
	light.light_color = color
	light.light_energy = energy
	light.shadow_enabled = false
	_world.add_child(light)
	light.look_at_from_position(from, Vector3.ZERO, Vector3.UP)


func _make_surface_mat(shader: Shader, roughness: float, specular: float, emission: float, rim: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("roughness_value", roughness)
	mat.set_shader_parameter("specular_value", specular)
	mat.set_shader_parameter("emission_strength", emission)
	mat.set_shader_parameter("rim_strength", rim)
	return mat


## 落定姿态下骰子在相机平面上的最大投影跨度（世界单位）；与结果面无关（立方体对称）。
func _measure_projected_extent(mesh: Mesh) -> float:
	var rest := Basis(_quat_for_face(1))
	var cam_basis := _camera.global_transform.basis
	var right := cam_basis.x.normalized()
	var up := cam_basis.y.normalized()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in mesh.get_surface_count():
		var verts: PackedVector3Array = mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
		for v in verts:
			var w := rest * v
			var p := Vector2(w.dot(right), w.dot(up))
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var span := hi - lo
	return maxf(maxf(span.x, span.y), 0.5)


## 结果面转到朝上（+Y），面内“上”转到远离镜头的一侧（-Z），再整体绕竖轴偏转露出两个侧面。
func _quat_for_face(face: Variant) -> Quaternion:
	var key: Variant = face if typeof(face) == TYPE_STRING else int(face)
	var n: Vector3 = FACE_NORMALS.get(key, Vector3.UP)
	var t := _face_texture_up(n)
	var s := t.cross(n)
	var src := Basis(s, t, n)
	var dst := Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.UP)
	var yaw := Basis(Vector3.UP, deg_to_rad(DICE_YAW_DEG))
	return (yaw * dst * src.transposed()).get_rotation_quaternion().normalized()


## 每一面内容的“上”方向（局部坐标）；Blender 建模脚本与 atlas 渲染都按这个摆放。
func _face_texture_up(local_n: Vector3) -> Vector3:
	if local_n.dot(Vector3(0, 1, 0)) > 0.9:
		return Vector3(0, 0, -1) # +Y 面（1）：上 = -Z（朝 5）
	if local_n.dot(Vector3(0, -1, 0)) > 0.9:
		return Vector3(0, 0, 1) # -Y 面（EVENT）：上 = +Z（朝 2）
	# 侧面：上 = +Y（朝 1）
	return Vector3(0, 1, 0)


## height01：0 = 贴地，1 = 抛到最高；影子随高度变小变淡，落定时尺寸与 alpha 固定。
func _update_shadow(height01: float) -> void:
	if _soft_shadow == null or _shadow_mat == null:
		return
	var h := clampf(height01, 0.0, 1.0)
	_soft_shadow.scale = Vector3.ONE * lerpf(1.0, 0.72, h)
	_shadow_mat.set_shader_parameter("shadow_color", Color(0.30, 0.20, 0.12, CONTACT_SHADOW_ALPHA * lerpf(1.0, 0.45, h)))


func _count_active_lights() -> int:
	if _world == null:
		return 0
	var n := 0
	for node in _world.find_children("*", "Light3D", true, false):
		var light := node as Light3D
		if light != null and light.visible and light.light_energy > 0.001:
			n += 1
	return n


func _is_body_unshaded() -> bool:
	if _body_mat == null or _body_mat.shader == null:
		return false
	var code := _body_mat.shader.code
	return code.contains("unshaded")


func get_configured_display_bbox_px() -> Vector2:
	## 逻辑画布上骰子落定时的目标可见包围盒（宽高较大者；正方形标尺）。
	var w := _dice_display_width if _dice_display_width > 1.0 else TARGET_DICE_WIDTH_720
	return Vector2(w, w)


func _load_atlas() -> bool:
	if _atlas != null:
		_atlas_loaded = true
		return true
	_atlas = load(ATLAS_PATH) as Texture2D
	if _atlas == null:
		_atlas = load(PLACEHOLDER_PATH) as Texture2D
	_atlas_loaded = _atlas != null
	return _atlas_loaded


## 骰子包围盒：显式尺寸优先，否则按控件短边适配；渲染区 = 包围盒 × HEADROOM_RATIO，
## 落定骰子中心对准控件中心（渲染区可以超出控件），子视口按屏幕实际像素出图。
func _layout_aspect_frame() -> void:
	if _aspect_frame == null:
		return
	var available := size
	if available.x <= 1.0 or available.y <= 1.0:
		available = custom_minimum_size
	var side := minf(available.x, available.y)
	var target := display_size_px if display_size_px > 0.0 else side * AUTO_FIT_RATIO
	_dice_display_width = maxf(target, MIN_DISPLAY_PX)
	var frame_side := _dice_display_width * HEADROOM_RATIO
	_aspect_frame.size = Vector2(frame_side, frame_side)
	_aspect_frame.position = available * 0.5 - _dice_center_in_frame()
	if _dice_texture:
		_dice_texture.position = Vector2.ZERO
		_dice_texture.size = _aspect_frame.size
	_resize_viewport()
	_layout_dice_overlays()
	_apply_body_display_scale()


func _resize_viewport() -> void:
	if _viewport == null or _aspect_frame == null:
		return
	_oversample = 1.0
	if is_inside_tree():
		var s := get_screen_transform().get_scale()
		_oversample = clampf(maxf(absf(s.x), absf(s.y)), 1.0, MAX_OVERSAMPLE)
	var px := maxi(int(ceil(_aspect_frame.size.x * _oversample)), 16)
	if _viewport.size != Vector2i(px, px):
		_viewport.size = Vector2i(px, px)
		_request_presented_frame()


## 落定骰子中心在渲染区里的位置（渲染区局部坐标）。
func _dice_center_in_frame() -> Vector2:
	var side := 0.0 if _aspect_frame == null else _aspect_frame.size.x
	return Vector2(side * 0.5, side * DICE_CENTER_Y)


func _layout_dice_overlays() -> void:
	if _aspect_frame == null:
		return
	var center := _dice_center_in_frame()
	if _result_glow:
		var glow_size := minf(_dice_display_width * GLOW_TO_DICE_RATIO, _aspect_frame.size.x * 0.98)
		_result_glow.size = Vector2(glow_size, glow_size)
		_result_glow.position = center - _result_glow.size * 0.5
	if _fallback:
		var face_size := minf(_dice_display_width, _aspect_frame.size.x * 0.92)
		_fallback.size = Vector2(face_size, face_size)
		_fallback.position = center - _fallback.size * 0.5


## 骰子本体保持单位比例；显示尺寸只由“渲染区像素 ↔ 正交 size”决定，所有结果面的体量一致。
func _apply_body_display_scale() -> void:
	if _dice_body != null:
		_dice_body.scale = Vector3.ONE
	if _camera:
		_camera.size = _projected_extent * HEADROOM_RATIO
		# 相机在自身平面里上移，骰子中心落在渲染区 DICE_CENTER_Y 处
		_camera.v_offset = (DICE_CENTER_Y - 0.5) * _camera.size


func _set_glow_color(value: Color) -> void:
	if _glow_mat:
		_glow_mat.set_shader_parameter("glow_color", value)


func _set_glow_strength(value: float) -> void:
	if _glow_mat:
		_glow_mat.set_shader_parameter("intensity", clampf(value, 0.0, 1.0))


func _set_fallback_face(face: Variant) -> void:
	if _fallback_mat == null:
		return
	var key: Variant = face if typeof(face) == TYPE_STRING else int(face)
	if not DiceMeshBuilder.ATLAS_CELLS.has(key):
		key = 1
	var cell: Vector2 = DiceMeshBuilder.ATLAS_CELLS[key]
	_fallback_mat.set_shader_parameter("cell_origin", Vector2(cell.x / 3.0, cell.y / 2.0))
	_fallback_mat.set_shader_parameter("cell_size", Vector2(1.0 / 3.0, 0.5))


func _set_viewport_update(active: bool) -> void:
	if _viewport == null:
		return
	if not visible:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	elif active:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	else:
		# idle 呼吸：可见时更新；隐藏时禁用
		_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE


func _request_presented_frame() -> void:
	if _viewport == null:
		return
	_presentation_generation += 1
	var generation := _presentation_generation
	_set_viewport_update(true)
	# idle 的 snap_to_face 也需要一帧真正提交，否则截图/低帧设备可能继续显示旧骰面。
	if not _rolling:
		call_deferred("_settle_static_presented_frame", generation)


func _settle_static_presented_frame(generation: int) -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree() or generation != _presentation_generation or _rolling:
		return
	_set_viewport_update(false)


func _count_face_decals() -> int:
	if _world == null:
		return 0
	var n := 0
	for child in _world.find_children("Face_*", "MeshInstance3D", true, false):
		n += 1
	return n


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if not visible and _viewport:
			_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		elif visible and _viewport and not _rolling:
			_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE


func _exit_tree() -> void:
	if _roll_tween:
		_roll_tween.kill()
	if _glow_tween:
		_glow_tween.kill()
