class_name MapEnvironmentFX
extends Node2D

## 地图环境动画表现层。所有坐标均在 BoardView 的 960×540 逻辑世界内，
## 因而天然跟随同一个 MapStage 相机缩放和平移。

const MANIFEST_PATH := "res://assets/map_fx/generated/map_fx_manifest.json"
const ROUND3_MIST_PATH := "res://assets/map_fx/round3/valley_mist_bright_overlay_v1.png"
const MAP_LOGICAL_SIZE := Vector2(960.0, 540.0)
const REFERENCE_SIZE := Vector2(2048.0, 1153.0)

const EFFECT_REGIONS := {
	"cloud_shadow": Rect2(621, 140, 751, 515),
	"fine_snow": Rect2(0, 196, 509, 364),
	"valley_mist": Rect2(0, 437, 739, 716),
	"desert_dust": Rect2(0, 0, 946, 392),
	"sea_glints": Rect2(1478, 263, 570, 588),
}

@export var effects_enabled := true
@export_range(0.0, 2.0, 0.01) var global_intensity := 1.0

@export_group("Cloud Shadow")
@export var cloud_shadow_enabled := true
@export var cloud_shadow_position := Vector2.ZERO
@export var cloud_shadow_scale := Vector2.ONE
@export_range(0.0, 1.0, 0.01) var cloud_shadow_opacity := 0.44
@export_range(0.1, 3.0, 0.05) var cloud_shadow_playback_speed := 1.10
@export_range(0.0, 1.0, 0.01) var cloud_shadow_phase_offset := 0.08

@export_group("Fine Snow")
@export var snow_enabled := true
@export var snow_position := Vector2.ZERO
@export var snow_scale := Vector2.ONE
@export_range(0.0, 1.0, 0.01) var snow_opacity := 1.00
@export_range(0.1, 3.0, 0.05) var snow_playback_speed := 1.35
@export_range(0.0, 1.0, 0.01) var snow_phase_offset := 0.16

@export_group("Valley Mist")
@export var mist_enabled := true
@export var mist_position := Vector2.ZERO
@export var mist_scale := Vector2.ONE
@export_range(0.0, 1.0, 0.01) var mist_opacity := 0.68
@export_range(0.1, 3.0, 0.05) var mist_playback_speed := 1.05
@export_range(0.0, 1.0, 0.01) var mist_phase_offset := 0.34

@export_group("Desert Dust")
@export var dust_enabled := true
@export var dust_position := Vector2.ZERO
@export var dust_scale := Vector2.ONE
@export_range(0.0, 1.0, 0.01) var dust_opacity := 0.92
@export_range(0.1, 3.0, 0.05) var dust_playback_speed := 1.30
@export_range(0.0, 1.0, 0.01) var dust_phase_offset := 0.52

@export_group("Sea Glints")
@export var sea_glints_enabled := true
@export var sea_glints_position := Vector2.ZERO
@export var sea_glints_scale := Vector2.ONE
@export_range(0.0, 1.0, 0.01) var sea_glints_opacity := 1.00
@export_range(0.1, 3.0, 0.05) var sea_glints_playback_speed := 1.35
@export_range(0.0, 1.0, 0.01) var sea_glints_phase_offset := 0.71

var _clock := 0.0
var _records: Array[Dictionary] = []
var _manifest: Dictionary = {}
var _missing_effects: Array[String] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_manifest()
	_build_effects()
	_apply_enabled_state()


func _process(delta: float) -> void:
	if not effects_enabled:
		return
	_clock += delta
	for record in _records:
		_update_record(record)


func set_effects_enabled(enabled: bool) -> void:
	effects_enabled = enabled
	_apply_enabled_state()


func set_effect_enabled(effect_id: String, enabled: bool) -> void:
	match effect_id:
		"cloud_shadow": cloud_shadow_enabled = enabled
		"fine_snow": snow_enabled = enabled
		"valley_mist": mist_enabled = enabled
		"desert_dust": dust_enabled = enabled
		"sea_glints": sea_glints_enabled = enabled
	_apply_enabled_state()


func get_loaded_effect_ids() -> Array[String]:
	var ids: Array[String] = []
	for record in _records:
		var effect_id := String(record.get("effect_id", ""))
		if not ids.has(effect_id):
			ids.append(effect_id)
	return ids


func get_missing_effect_ids() -> Array[String]:
	return _missing_effects.duplicate()


func get_debug_state() -> Dictionary:
	var record_counts := {}
	for record in _records:
		var effect_id := String(record.get("effect_id", ""))
		record_counts[effect_id] = int(record_counts.get(effect_id, 0)) + 1
	var state := {
		"effects_enabled": effects_enabled,
		"record_count": _records.size(),
		"loaded_effects": get_loaded_effect_ids(),
		"missing_effects": get_missing_effect_ids(),
		"node_count": _count_nodes(self),
		"record_counts": record_counts,
	}
	return state


func _load_manifest() -> void:
	if not FileAccess.file_exists(MANIFEST_PATH):
		push_warning("MapEnvironmentFX manifest missing: %s" % MANIFEST_PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if parsed is Dictionary:
		_manifest = parsed
	for effect_id in _manifest.get("missing_effects", []):
		_missing_effects.append(String(effect_id))


func _build_effects() -> void:
	var effects: Dictionary = _manifest.get("effects", {})
	_build_single_region("cloud_shadow", effects.get("cloud_shadow", {}), _logical_region("cloud_shadow"),
		cloud_shadow_position, cloud_shadow_scale, cloud_shadow_opacity,
		cloud_shadow_playback_speed, cloud_shadow_phase_offset)
	_build_single_region("fine_snow", effects.get("fine_snow", {}), _logical_region("fine_snow"),
		snow_position, snow_scale, snow_opacity, snow_playback_speed, snow_phase_offset)

	# 山雾一主一副，均限制在高山/雪山脚局部矩形，不侵入草甸与海面。
	var high_mountain := _logical_region("valley_mist")
	_build_single_region("valley_mist", effects.get("valley_mist", {}),
		Rect2(high_mountain.position + Vector2(0, 62), Vector2(high_mountain.size.x, 122)),
		mist_position, mist_scale, mist_opacity, mist_playback_speed, mist_phase_offset)
	_build_single_region("valley_mist", effects.get("valley_mist", {}),
		Rect2(Vector2(26, 120), Vector2(176, 64)), mist_position, mist_scale * 0.72,
		mist_opacity * 0.68, mist_playback_speed * 0.91, fposmod(mist_phase_offset + 0.37, 1.0))
	# 第三轮雾层只做生成—停留—消散，不作左右钟摆运动。
	_build_fade_overlay(
		"valley_mist", ROUND3_MIST_PATH, 0.0, 0.48,
		13.5, mist_phase_offset + 0.19
	)

	# 风沙覆盖西北沙漠的四个局部带，彼此错相位；不铺成全屏滤镜。
	var desert := _logical_region("desert_dust")
	var dust_patches := [
		Rect2(desert.position + Vector2(8, 52), Vector2(164, 68)),
		Rect2(desert.position + Vector2(146, 72), Vector2(178, 72)),
		Rect2(desert.position + Vector2(286, 48), Vector2(150, 64)),
		Rect2(desert.position + Vector2(34, 118), Vector2(196, 58)),
	]
	for index in dust_patches.size():
		_build_single_region("desert_dust", effects.get("desert_dust", {}), dust_patches[index],
			dust_position, dust_scale * (1.0 - index * 0.035),
			dust_opacity * (1.0 - index * 0.07),
			dust_playback_speed * (1.0 - index * 0.035),
			fposmod(dust_phase_offset + index * 0.23, 1.0))
	# 第三轮亮黄色整图风沙与地图不匹配，运行时停用；保留四个局部细沙带。

	# 海面闪光拆为六组疏散区域，覆盖近海、中海与南部航线并各自错相位。
	var sea := _logical_region("sea_glints")
	var sea_patches := [
		Rect2(sea.position + Vector2(10, 18), Vector2(104, 54)),
		Rect2(sea.position + Vector2(126, 42), Vector2(122, 58)),
		Rect2(sea.position + Vector2(42, 92), Vector2(132, 62)),
		Rect2(sea.position + Vector2(142, 132), Vector2(112, 58)),
		Rect2(sea.position + Vector2(18, 176), Vector2(142, 62)),
		Rect2(sea.position + Vector2(110, 218), Vector2(138, 58)),
	]
	for index in sea_patches.size():
		_build_single_region("sea_glints", effects.get("sea_glints", {}), sea_patches[index],
			sea_glints_position, sea_glints_scale * (1.0 - index * 0.018),
			sea_glints_opacity * (1.0 - index * 0.055),
			sea_glints_playback_speed * (1.0 - index * 0.025),
			fposmod(sea_glints_phase_offset + index * 0.17, 1.0),
			{
				"drift_x": 8.0 + index * 1.7,
				"period": 7.0 + index * 0.9,
				"direction": 1.0 if index % 2 == 0 else -1.0,
				"fade_floor": 0.18 + (index % 3) * 0.06,
				"fade_phase": fposmod(index * 0.29, 1.0),
			})


func _build_fade_overlay(effect_id: String, texture_path: String, min_alpha: float,
		max_alpha: float, duration: float, phase_offset: float) -> void:
	if not ResourceLoader.exists(texture_path):
		push_warning("MapEnvironmentFX round3 overlay missing: %s" % texture_path)
		return
	var texture := load(texture_path) as Texture2D
	if texture == null:
		return
	var container := Control.new()
	container.name = "%sRound3" % effect_id.to_pascal_case()
	container.position = Vector2.ZERO
	container.size = MAP_LOGICAL_SIZE
	container.clip_contents = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	var overlay := TextureRect.new()
	overlay.name = "BrightOverlay"
	overlay.position = Vector2.ZERO
	overlay.size = MAP_LOGICAL_SIZE
	overlay.texture = texture
	overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	overlay.stretch_mode = TextureRect.STRETCH_SCALE
	overlay.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(overlay)
	_records.append({
		"effect_id": effect_id,
		"container": container,
		"overlay": overlay,
		"mode": "fade_overlay",
		"min_alpha": min_alpha,
		"max_alpha": max_alpha,
		"duration": duration,
		"phase": fposmod(phase_offset, 1.0),
	})


func _build_single_region(effect_id: String, data: Dictionary, region: Rect2,
		position_adjust: Vector2, scale_adjust: Vector2, opacity: float,
		playback_speed: float, phase_offset: float, motion_config: Dictionary = {}) -> void:
	if data.is_empty():
		return
	var frames := _make_sprite_frames(data)
	if frames == null:
		return
	var container := Control.new()
	container.name = "%sRegion%02d" % [effect_id.to_pascal_case(), _records.size()]
	container.position = region.position + position_adjust
	container.size = region.size
	container.scale = scale_adjust
	container.clip_contents = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)

	var sprites: Array[AnimatedSprite2D] = []
	var mode := String(data.get("loop_mode", "ping_pong"))
	var sprite_count := 2 if mode == "crossfade" else 1
	var frame_size_data: Array = data.get("frame_size", [1, 1])
	var frame_size := Vector2(float(frame_size_data[0]), float(frame_size_data[1]))
	var cover_scale := maxf(region.size.x / maxf(frame_size.x, 1.0), region.size.y / maxf(frame_size.y, 1.0))
	if not motion_config.is_empty():
		# Horizontal water drift needs a little overscan so the clipped patch never reveals an edge.
		cover_scale *= 1.0 + absf(float(motion_config.get("drift_x", 0.0))) * 2.0 / maxf(region.size.x, 1.0)
	for sprite_index in sprite_count:
		var sprite := AnimatedSprite2D.new()
		sprite.name = "Track%c" % (65 + sprite_index)
		sprite.sprite_frames = frames
		sprite.animation = &"default"
		sprite.centered = true
		sprite.position = region.size * 0.5
		sprite.scale = Vector2.ONE * cover_scale
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		sprite.modulate.a = 0.0
		container.add_child(sprite)
		sprites.append(sprite)
	_records.append({
		"effect_id": effect_id,
		"container": container,
		"sprites": sprites,
		"mode": mode,
		"frame_count": int(data.get("frame_count", 1)),
		"fps": float(data.get("fps", 6.0)),
		"opacity": opacity,
		"speed": playback_speed,
		"phase": phase_offset,
		"base_center": region.size * 0.5,
		"motion": motion_config.duplicate(true),
	})


func _make_sprite_frames(data: Dictionary) -> SpriteFrames:
	var atlas_path := String(data.get("atlas", ""))
	var atlas: Texture2D = load(atlas_path)
	if atlas == null:
		push_warning("MapEnvironmentFX atlas missing: %s" % atlas_path)
		return null
	var frame_size_data: Array = data.get("frame_size", [1, 1])
	var frame_size := Vector2(float(frame_size_data[0]), float(frame_size_data[1]))
	var columns := int(data.get("columns", 1))
	var count := int(data.get("frame_count", 1))
	var frames := SpriteFrames.new()
	frames.clear(&"default")
	frames.set_animation_loop(&"default", true)
	frames.set_animation_speed(&"default", float(data.get("fps", 6.0)))
	for index in count:
		var texture := AtlasTexture.new()
		texture.atlas = atlas
		texture.region = Rect2(Vector2(index % columns, index / columns) * frame_size, frame_size)
		frames.add_frame(&"default", texture)
	return frames


func _update_record(record: Dictionary) -> void:
	var effect_id := String(record.get("effect_id", ""))
	var container: Control = record.get("container")
	var enabled := _effect_is_enabled(effect_id)
	container.visible = effects_enabled and enabled
	if not container.visible:
		return
	var mode := String(record.get("mode", ""))
	if mode == "fade_overlay":
		var overlay: TextureRect = record.get("overlay")
		var duration := maxf(1.0, float(record.get("duration", 12.0)))
		var phase := float(record.get("phase", 0.0))
		var life := fposmod(_clock / duration + phase, 1.0)
		var envelope := 1.0
		if life < 0.24:
			envelope = smoothstep(0.0, 0.24, life)
		elif life > 0.68:
			envelope = 1.0 - smoothstep(0.68, 1.0, life)
		else:
			envelope = 0.94 + sin((life - 0.24) / 0.44 * PI) * 0.06
		# Keep the cloud mass spatially anchored; only density changes over time.
		overlay.position = Vector2.ZERO
		overlay.modulate.a = lerpf(
			float(record.get("min_alpha", 0.0)),
			float(record.get("max_alpha", 0.50)),
			envelope
		) * global_intensity
		return
	var sprites: Array = record.get("sprites", [])
	var frame_count := maxi(1, int(record.get("frame_count", 1)))
	var fps := float(record.get("fps", 6.0)) * float(record.get("speed", 1.0))
	var opacity := clampf(float(record.get("opacity", 1.0)) * global_intensity, 0.0, 1.0)
	var phase := float(record.get("phase", 0.0))
	var motion: Dictionary = record.get("motion", {})
	if not motion.is_empty():
		var motion_period := maxf(1.0, float(motion.get("period", 8.0)))
		var motion_life := fposmod(_clock / motion_period + phase, 1.0)
		var direction := float(motion.get("direction", 1.0))
		var lateral := sin(motion_life * TAU) * float(motion.get("drift_x", 0.0)) * direction
		var base_center: Vector2 = record.get("base_center", Vector2.ZERO)
		for sprite in sprites:
			sprite.position = base_center + Vector2(lateral, 0.0)
		var fade_phase := fposmod(motion_life + float(motion.get("fade_phase", 0.0)), 1.0)
		var fade_wave := (sin(fade_phase * TAU - PI * 0.5) + 1.0) * 0.5
		opacity *= lerpf(float(motion.get("fade_floor", 0.22)), 1.0, smoothstep(0.0, 1.0, fade_wave))
	var span := maxi(1, frame_count - 1)
	# Ping-pong needs a forward + reverse duration. The old frame_count/fps
	# duration jumped from the last frame straight back to frame zero.
	var duration := (span * 2.0 / maxf(fps, 0.001)) if mode == "ping_pong" else (frame_count / maxf(fps, 0.001))
	var local_time := fposmod(_clock + phase * duration, duration)
	if mode == "ping_pong":
		var cursor := fposmod(local_time * fps, span * 2.0)
		var frame := int(floor(cursor))
		if frame > span:
			frame = span * 2 - frame
		sprites[0].frame = clampi(frame, 0, frame_count - 1)
		sprites[0].modulate.a = opacity
		return

	# 正向首尾交叉淡化：A 始终正向播放；接缝前 B 从序列起点正向接入。
	var crossfade_seconds := minf(0.55, duration * 0.14)
	var seam_start := duration - crossfade_seconds
	var blend := 0.0
	if local_time >= seam_start:
		blend = smoothstep(seam_start, duration, local_time)
	var a_frame := mini(frame_count - 1, int(floor(local_time * fps)))
	var b_time := maxf(0.0, local_time - seam_start)
	var b_frame := mini(frame_count - 1, int(floor(b_time * fps)))
	sprites[0].frame = a_frame
	sprites[1].frame = b_frame
	sprites[0].modulate.a = opacity * (1.0 - blend)
	sprites[1].modulate.a = opacity * blend


func _apply_enabled_state() -> void:
	visible = effects_enabled
	set_process(effects_enabled)
	for record in _records:
		var container: Control = record.get("container")
		container.visible = effects_enabled and _effect_is_enabled(String(record.get("effect_id", "")))


func _effect_is_enabled(effect_id: String) -> bool:
	match effect_id:
		"cloud_shadow": return cloud_shadow_enabled
		"fine_snow": return snow_enabled
		"valley_mist": return mist_enabled
		"desert_dust": return dust_enabled
		"sea_glints": return sea_glints_enabled
	return false


func _logical_region(effect_id: String) -> Rect2:
	var source: Rect2 = EFFECT_REGIONS.get(effect_id, Rect2())
	return Rect2(
		Vector2(source.position.x / REFERENCE_SIZE.x * MAP_LOGICAL_SIZE.x,
			source.position.y / REFERENCE_SIZE.y * MAP_LOGICAL_SIZE.y),
		Vector2(source.size.x / REFERENCE_SIZE.x * MAP_LOGICAL_SIZE.x,
			source.size.y / REFERENCE_SIZE.y * MAP_LOGICAL_SIZE.y)
	)


func _count_nodes(root: Node) -> int:
	var total := 1
	for child in root.get_children():
		total += _count_nodes(child)
	return total
