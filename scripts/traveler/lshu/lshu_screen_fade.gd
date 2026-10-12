extends CanvasLayer
## 第四幕「L叔在哪儿」· the director's screen cover for tile switches (layer 10: above the stage, below the UI at 20).
##   snapshot()   copies the last drawn frame on the GPU (RenderingDevice.texture_copy, about 0.1 ms, no read-back)
##                and shows it at full opacity; the stage can then swap tiles underneath and fade_out() dissolves
##                the old picture into the new one.
##   cover(color) an opaque colour (the opening before the first tile is ready, or the fallback when the renderer
##                has no RenderingDevice).
##   fade_out(s)  eases the cover away over s seconds of wall time. Awaitable.
## Nothing here knows about tiles; the director decides when to cover and for how long.

signal faded

const SNAPSHOT_SHADER: Shader = preload("res://shaders/traveler/lshu/lshu_snapshot.gdshader")

var mode: String = "none"          # none | snapshot | solid
var rect: TextureRect
var solid: ColorRect
var snap_material: ShaderMaterial
var snap_texture: Texture2DRD
var snapshot_ms: float = 0.0
var snapshots: int = 0
var fallbacks: int = 0
var _rd: RenderingDevice
var _dst: RID = RID()
var _dst_size: Vector2i = Vector2i.ZERO
var _dst_format: int = -1
var _alpha: float = 0.0
var _fade_from: float = 0.0
var _fade_t0_us: int = 0
var _fade_us: int = 0
var _fading: bool = false

func _ready() -> void:
	name = "LshuScreenFade"
	layer = 10
	rect = TextureRect.new()
	rect.name = "Snapshot"
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	snap_material = ShaderMaterial.new()
	snap_material.shader = SNAPSHOT_SHADER
	rect.material = snap_material
	rect.visible = false
	add_child(rect)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	solid = ColorRect.new()
	solid.name = "Solid"
	solid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	solid.visible = false
	add_child(solid)
	solid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)

## True while anything covers the stage (fully or fading).
func is_up() -> bool:
	return mode != "none"

func alpha() -> float:
	return _alpha

## Freezes the last drawn frame over the stage. false when the renderer cannot copy it (then use cover()).
func snapshot() -> bool:
	var t0: int = Time.get_ticks_usec()
	var vp: Viewport = get_viewport()
	_rd = RenderingServer.get_rendering_device()
	if vp == null or _rd == null:
		fallbacks += 1
		return false
	var src: RID = RenderingServer.texture_get_rd_texture(vp.get_texture().get_rid())
	if not src.is_valid():
		fallbacks += 1
		return false
	var fmt: RDTextureFormat = _rd.texture_get_format(src)
	if fmt == null or (fmt.usage_bits & RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT) == 0:
		fallbacks += 1
		return false
	var size: Vector2i = Vector2i(int(fmt.width), int(fmt.height))
	var result: Array[int] = [FAILED]
	RenderingServer.call_on_render_thread(_copy_on_render_thread.bind(src, size, int(fmt.format), result))
	if result[0] != OK:
		fallbacks += 1
		return false
	if snap_texture == null:
		snap_texture = Texture2DRD.new()
	snap_texture.texture_rd_rid = _dst
	rect.texture = snap_texture
	rect.visible = true
	solid.visible = false
	mode = "snapshot"
	_set_alpha(1.0)
	_fading = false
	set_process(false)
	snapshots += 1
	snapshot_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	return true

func _copy_on_render_thread(src: RID, size: Vector2i, format: int, result: Array[int]) -> void:
	if not _dst.is_valid() or size != _dst_size or format != _dst_format:
		if _dst.is_valid():
			if snap_texture != null:
				snap_texture.texture_rd_rid = RID()
			_rd.free_rid(_dst)
			_dst = RID()
		var f: RDTextureFormat = RDTextureFormat.new()
		f.format = format as RenderingDevice.DataFormat
		f.width = size.x
		f.height = size.y
		f.texture_type = RenderingDevice.TEXTURE_TYPE_2D
		f.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		_dst = _rd.texture_create(f, RDTextureView.new())
		_dst_size = size
		_dst_format = format
	if not _dst.is_valid():
		result[0] = FAILED
		return
	result[0] = _rd.texture_copy(src, _dst, Vector3.ZERO, Vector3.ZERO, Vector3(size.x, size.y, 1), 0, 0, 0, 0)

## An opaque colour over the stage.
func cover(color: Color) -> void:
	solid.color = Color(color.r, color.g, color.b, 1.0)
	solid.visible = true
	rect.visible = false
	mode = "solid"
	_set_alpha(1.0)
	_fading = false
	set_process(false)

## Keeps a solid cover's colour in step with the backdrop (the light may move while it is up).
func set_cover_color(color: Color) -> void:
	solid.color = Color(color.r, color.g, color.b, solid.color.a)

## Eases the cover away over `seconds` of wall time (ease in-out). Awaitable; returns at once when nothing is up.
func fade_out(seconds: float) -> void:
	if mode == "none":
		return
	if seconds <= 0.0:
		hide_now()
		return
	_fade_from = _alpha
	_fade_t0_us = Time.get_ticks_usec()
	_fade_us = int(seconds * 1000000.0)
	_fading = true
	set_process(true)
	await faded

func hide_now() -> void:
	var was_fading: bool = _fading
	_fading = false
	set_process(false)
	_set_alpha(0.0)
	rect.visible = false
	solid.visible = false
	mode = "none"
	if was_fading:
		faded.emit()

func _process(_delta: float) -> void:
	if not _fading:
		return
	var u: float = clampf(float(Time.get_ticks_usec() - _fade_t0_us) / float(maxi(_fade_us, 1)), 0.0, 1.0)
	_set_alpha(_fade_from * (1.0 - smoothstep(0.0, 1.0, u)))
	if u >= 1.0:
		hide_now()

func _set_alpha(a: float) -> void:
	_alpha = a
	snap_material.set_shader_parameter("fade", a)
	solid.color.a = a

func evidence() -> Dictionary:
	return {"mode": mode, "alpha": _alpha, "snapshots": snapshots, "fallbacks": fallbacks, "snapshot_ms": snapshot_ms, "size": [_dst_size.x, _dst_size.y]}

func _exit_tree() -> void:
	if rect != null:
		rect.texture = null
	if snap_texture != null:
		snap_texture.texture_rd_rid = RID()
	if _dst.is_valid() and _rd != null:
		var rd: RenderingDevice = _rd
		var dst: RID = _dst
		_dst = RID()
		RenderingServer.call_on_render_thread(func() -> void: rd.free_rid(dst))
