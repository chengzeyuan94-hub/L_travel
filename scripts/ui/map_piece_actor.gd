extends Node2D
class_name MapPieceActor

## 地图棋子 REV2：整段多边路径按单一弧长连续插值移动（全程一次加速/一次减速，
## 中途节点不停顿），八方向精灵按距离驱动步态，阴影/尾流/扬尘为世界坐标特效池。
## 不直接改 PlayerState。

signal move_finished(player_id: String)
## 中途经过节点时触发（视觉反馈/未来 SFX 挂点），不会暂停棋子移动。
signal mid_node_reached(player_id: String, node_id: String)

const DIRS := ["e", "se", "s", "sw", "w", "nw", "n", "ne"]
const DIR_HYSTERESIS_DEG := 5.0
const TANGENT_LOOKAHEAD_PX := 6.5
const DIR_EMA_ALPHA := 0.35 ## 切线短窗指数平滑，抑制方向抖动同时保留转向响应

const CAMEL_GAIT_CYCLE_DISTANCE := 64.0 ## 骆驼完整 8 帧步态对应的行进距离(px)；按距离驱动帧，不按固定 FPS
const CAMEL_BOB_PX := 0.0 ## 帧内已有身体起伏；禁止再叠加代码 bob，避免上下抖动。
const SHIP_SPEED_SCALE_MIN := 0.35
const SHIP_SPEED_SCALE_MAX := 1.6
const SHIP_BOB_PX := 1.6
const SHIP_SWAY_DEG := 2.6

const ACCEL_TIME := 0.18 ## 全程只在起点加速一次（不管中途经过多少节点）
const DECEL_TIME := 0.22 ## 全程只在终点减速一次
const DEPART_SQUASH_TIME := 0.12
const ARRIVE_BOUNCE_TIME := 0.16
const TURN_SQUASH_TIME := 0.07

const WAKE_SPAWN_SPACING_PX := 16.0
const DUST_STEP_FRAMES := [0, 4] ## 每个步态周期内触发扬尘的帧索引（脚落地时刻）

var player_id: String = ""
var is_human := true
var transport: int = GameData.Transport.CAMEL
var logical_pos: Vector2 = Vector2.ZERO
var display_scale: float = 0.28
var vfx_pool: MapVfxPool = null ## 由 BoardView 注入的世界坐标特效池（涟漪/扬尘）
## Standalone visual previews may disable the arrival one-shot. Production
## actors keep the default; movement, signals and timing are unaffected.
var arrival_sfx_enabled := true

## 测试可注入以缩短/固化整段路径时长；生产默认由 BoardView 按弧长/速度计算。
var test_duration_override: float = -1.0

var _sprite: AnimatedSprite2D
var _shadow: Sprite2D
var _wake: Sprite2D
var _ring: Polygon2D
var _label: Label
var _frames_camel: Dictionary = {}
var _frames_ship: Dictionary = {}
var _moving := false
var _manifest: Dictionary = {}
var _current_dir := "s"
var _visited_frames: Dictionary = {} # frame_index -> true during current move
var _base_sprite_offset := Vector2.ZERO
var _shadow_base_scale := Vector2(0.55, 0.55)
var _wake_base_pos := Vector2(0, 12)

var _tween_deform: Tween
var _tween_ring: Tween
var _tween_transport: Tween

# --- 单段连续路径运动状态 ---
var _move_samples: PackedVector2Array = PackedVector2Array()
var _move_cum: PackedFloat32Array = PackedFloat32Array()
var _move_total := 0.0
var _move_node_breaks: PackedFloat32Array = PackedFloat32Array()
var _move_node_ids: Array = []
var _move_next_break := 0
var _move_duration := 1.0
var _move_elapsed := 0.0
var _move_last_dist := 0.0
var _move_accel_u := 0.0
var _move_decel_u := 0.0
var _move_const_u := 0.0
var _move_v_peak := 0.0
var _move_reference_speed := 90.0

var _dir_ema := Vector2.ZERO
var _camel_phase_frames := 0.0
var _camel_prev_frame_idx := -1
var _wake_last_spawn_dist := 0.0
var _ship_bob_phase := 0.0


func _ready() -> void:
	_ensure_nodes()
	_load_manifest()
	_build_sprite_frames()
	_apply_idle_visual()


## 播放一段“已拼接好的连续弧长路径”。samples/cum/total 由 BoardView 拼接多条边得到，
## node_breaks 是中途节点在整段弧长上的累计距离（不含起点终点），node_ids 与之对应。
func play_path(
	samples: PackedVector2Array,
	cum: PackedFloat32Array,
	total: float,
	duration: float,
	node_breaks: PackedFloat32Array = PackedFloat32Array(),
	node_ids: Array = [],
	reference_speed: float = 90.0
) -> void:
	cancel_motion()
	if samples.size() < 2 or total <= 0.0011:
		move_finished.emit(player_id)
		return
	_move_samples = samples
	_move_cum = cum
	_move_total = total
	_move_node_breaks = node_breaks
	_move_node_ids = node_ids
	_move_next_break = 0
	_move_reference_speed = maxf(reference_speed, 1.0)
	var dur := duration
	if test_duration_override > 0.0:
		dur = test_duration_override
	_move_duration = maxf(dur, 0.001)
	_move_elapsed = 0.0
	_move_last_dist = 0.0
	_setup_velocity_profile()
	_moving = true
	_visited_frames.clear()
	_camel_phase_frames = 0.0
	_camel_prev_frame_idx = -1
	_wake_last_spawn_dist = 0.0
	_ship_bob_phase = 0.0
	logical_pos = samples[0]
	position = logical_pos
	var arc0 := {"cum": _move_cum, "total": _move_total}
	_dir_ema = _tangent_ahead(_move_samples, arc0, 0.0, TANGENT_LOOKAHEAD_PX)
	if _dir_ema.length_squared() > 0.0001:
		_set_direction(_dir_from_deg(rad_to_deg(atan2(_dir_ema.y, _dir_ema.x))), true, true)
	_apply_move_visual()
	AudioManager.start_piece_loop(transport)
	_play_depart_squash()
	set_process(true)


func _setup_velocity_profile() -> void:
	var accel_t := minf(ACCEL_TIME, _move_duration * 0.4)
	var decel_t := minf(DECEL_TIME, _move_duration * 0.4)
	_move_accel_u = accel_t / _move_duration
	_move_decel_u = decel_t / _move_duration
	_move_const_u = maxf(1.0 - _move_accel_u - _move_decel_u, 0.0)
	var denom := _move_const_u + _move_accel_u * 0.5 + _move_decel_u * 0.5
	_move_v_peak = 1.0 / maxf(denom, 0.0001)


## 梯形速度曲线积分：全程恰好一次加速、一次减速，中段匀速。返回值是弧长分数 [0,1]。
func _arc_fraction_for_u(u: float) -> float:
	var uu := clampf(u, 0.0, 1.0)
	if _move_accel_u > 0.0 and uu <= _move_accel_u:
		return _move_v_peak * uu * uu / (2.0 * _move_accel_u)
	var s_accel := _move_v_peak * _move_accel_u * 0.5
	var const_end := _move_accel_u + _move_const_u
	if uu <= const_end:
		return s_accel + _move_v_peak * (uu - _move_accel_u)
	var s_const := s_accel + _move_v_peak * _move_const_u
	if _move_decel_u <= 0.0:
		return s_const
	var u2 := clampf(uu - const_end, 0.0, _move_decel_u)
	return s_const + _move_v_peak * u2 - _move_v_peak * u2 * u2 / (2.0 * _move_decel_u)


func _process(delta: float) -> void:
	if not _moving:
		return
	_move_elapsed += delta
	var u := _move_elapsed / _move_duration
	var s := _arc_fraction_for_u(u)
	var dist := clampf(s, 0.0, 1.0) * _move_total
	var d_dist := dist - _move_last_dist
	_move_last_dist = dist
	var arc := {"cum": _move_cum, "total": _move_total}
	var pos := _sample_by_arc(_move_samples, arc, s)
	var tangent := _tangent_ahead(_move_samples, arc, s, TANGENT_LOOKAHEAD_PX)
	logical_pos = pos
	position = pos
	if tangent.length_squared() > 0.0001:
		_dir_ema = _dir_ema.lerp(tangent, DIR_EMA_ALPHA)
	_update_direction_from_tangent(_dir_ema)
	_track_frame()
	_orient_wake(_dir_ema)
	var speed_px_s := d_dist / maxf(delta, 0.0001)
	_apply_motion_secondary(delta, d_dist, speed_px_s)
	_advance_gait_and_vfx(d_dist)
	_check_mid_node_breaks(dist)
	if u >= 1.0:
		_snap_to_end(_move_samples)
		_on_move_done()


func _check_mid_node_breaks(dist: float) -> void:
	while _move_next_break < _move_node_breaks.size() and dist >= _move_node_breaks[_move_next_break] - 0.01:
		var node_id := ""
		if _move_next_break < _move_node_ids.size():
			node_id = String(_move_node_ids[_move_next_break])
		_trigger_mid_node_feedback(node_id)
		_move_next_break += 1


func _trigger_mid_node_feedback(node_id: String) -> void:
	mid_node_reached.emit(player_id, node_id)
	_pulse_ring()


func _ensure_nodes() -> void:
	if _sprite != null:
		return
	_shadow = Sprite2D.new()
	_shadow.name = "Shadow"
	_shadow.z_index = -2
	add_child(_shadow)
	_wake = Sprite2D.new()
	_wake.name = "Wake"
	_wake.z_index = -1
	_wake.visible = false
	add_child(_wake)
	_ring = Polygon2D.new()
	_ring.name = "TeamRing"
	_ring.z_index = -1
	_ring.polygon = PackedVector2Array(
		[Vector2(-18, 4), Vector2(-10, 10), Vector2(10, 10), Vector2(18, 4), Vector2(10, -1), Vector2(-10, -1)]
	)
	add_child(_ring)
	_sprite = AnimatedSprite2D.new()
	_sprite.name = "AnimatedSprite2D"
	_sprite.centered = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(_sprite)
	_label = Label.new()
	_label.name = "RoleLabel"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 11)
	_label.position = Vector2(-12, -52)
	_label.size = Vector2(24, 14)
	add_child(_label)
	_shadow.texture = _make_ellipse_texture(Color(0, 0, 0, 0.35), 64, 28)
	_wake.texture = _make_ellipse_texture(Color(0.55, 0.78, 0.88, 0.35), 48, 16)


func setup(p_id: String, human: bool, start_transport: int) -> void:
	_ensure_nodes()
	player_id = p_id
	is_human = human
	transport = start_transport
	_label.text = "你" if human else "AI"
	_ring.color = Color("c58b32", 0.55) if human else Color("3f6d8c", 0.55)
	_apply_idle_visual()


func set_logical_position(pos: Vector2) -> void:
	logical_pos = pos
	position = pos


func set_transport(new_transport: int) -> void:
	transport = new_transport
	if not _moving:
		_apply_idle_visual()


## 港口换乘的陆/海停靠点在正式棋盘上可能相隔一段可见距离。规则状态会同步
## 立即切换，但表现层用短暂淡出/淡入完成“进港换乘”，避免棋子在两个锚点间
## 瞬移。这里只改视觉节点，不修改 PlayerState。
func play_transport_switch(
	from_pos: Vector2,
	to_pos: Vector2,
	from_transport: int,
	to_transport: int,
	duration: float = 0.32
) -> void:
	cancel_motion()
	transport = from_transport
	set_logical_position(from_pos)
	_apply_idle_visual()
	modulate = Color.WHITE
	_moving = true
	set_process(false)
	var total := maxf(duration, 0.04)
	var fade_out := total * 0.42
	var fade_in := total - fade_out
	_tween_transport = create_tween()
	_tween_transport.tween_property(self, "modulate:a", 0.0, fade_out).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_tween_transport.tween_callback(
		func() -> void:
			transport = to_transport
			set_logical_position(to_pos)
			_apply_idle_visual()
	)
	_tween_transport.tween_property(self, "modulate:a", 1.0, fade_in).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tween_transport.finished.connect(
		func() -> void:
			_tween_transport = null
			_moving = false
			transport = to_transport
			set_logical_position(to_pos)
			modulate = Color.WHITE
			_apply_idle_visual()
			move_finished.emit(player_id),
		CONNECT_ONE_SHOT
	)


func is_animating() -> bool:
	return _moving


func get_visited_frame_count() -> int:
	return _visited_frames.size()


func cancel_motion() -> void:
	if _tween_deform != null and _tween_deform.is_valid():
		_tween_deform.kill()
	if _tween_ring != null and _tween_ring.is_valid():
		_tween_ring.kill()
	if _tween_transport != null and _tween_transport.is_valid():
		_tween_transport.kill()
	_tween_deform = null
	_tween_ring = null
	_tween_transport = null
	_moving = false
	modulate = Color.WHITE
	AudioManager.stop_piece_loop(false)
	_move_samples = PackedVector2Array()
	_move_cum = PackedFloat32Array()
	_move_node_breaks = PackedFloat32Array()
	_move_node_ids = []
	_move_next_break = 0
	_move_elapsed = 0.0
	_move_last_dist = 0.0
	set_process(false)
	if _sprite:
		_sprite.stop()
		_sprite.rotation_degrees = 0.0
		_sprite.position = Vector2.ZERO
		_sprite.speed_scale = 1.0
	_wake.visible = false
	if _ring:
		_ring.scale = Vector2.ONE
	_apply_idle_visual()


func _snap_to_end(samples: PackedVector2Array) -> void:
	logical_pos = samples[samples.size() - 1]
	position = logical_pos


func direction_from_delta(delta: Vector2) -> String:
	if delta.length_squared() < 0.0001:
		return _current_dir
	var deg := rad_to_deg(atan2(delta.y, delta.x))
	return _dir_from_deg(deg)


func _dir_from_deg(deg: float) -> String:
	# Godot Y-down sectors.
	if deg >= -22.5 and deg < 22.5:
		return "e"
	if deg >= 22.5 and deg < 67.5:
		return "se"
	if deg >= 67.5 and deg < 112.5:
		return "s"
	if deg >= 112.5 and deg < 157.5:
		return "sw"
	if deg >= 157.5 or deg < -157.5:
		return "w"
	if deg >= -157.5 and deg < -112.5:
		return "nw"
	if deg >= -112.5 and deg < -67.5:
		return "n"
	return "ne"


func _boundary_distance(deg: float) -> float:
	var bounds := [-157.5, -112.5, -67.5, -22.5, 22.5, 67.5, 112.5, 157.5]
	var best := 999.0
	for b in bounds:
		best = mini(best, absf(deg - b))
	# wrap near ±180
	best = mini(best, absf(absf(deg) - 180.0))
	return best


func _on_move_done() -> void:
	_moving = false
	AudioManager.stop_piece_loop(arrival_sfx_enabled)
	set_process(false)
	if _sprite:
		_sprite.stop()
		_sprite.rotation_degrees = 0.0
		_sprite.position = Vector2.ZERO
		_sprite.offset = _base_sprite_offset
		_sprite.speed_scale = 1.0
	_wake.visible = false
	_shadow.scale = _shadow_base_scale
	_shadow.position = Vector2(0, 10)
	_play_arrive_feedback()
	_apply_idle_visual()
	move_finished.emit(player_id)


func _play_arrive_feedback() -> void:
	_play_arrive_bounce()
	_pulse_ring()
	if vfx_pool != null:
		if transport == GameData.Transport.SHIP:
			vfx_pool.spawn_ripple(position + Vector2(0, 12))
		else:
			vfx_pool.spawn_dust(position + Vector2(0, 10))


func _apply_idle_visual() -> void:
	_shadow.visible = transport == GameData.Transport.CAMEL
	_wake.visible = false
	_sprite.scale = Vector2(display_scale, display_scale)
	_sprite.position = Vector2.ZERO
	_sprite.rotation_degrees = 0.0
	_shadow.position = Vector2(0, 10)
	_shadow.scale = _shadow_base_scale
	_set_direction("s", false, true)


func _apply_move_visual() -> void:
	_shadow.visible = transport == GameData.Transport.CAMEL
	# 旧的跟随椭圆 wake 保留节点兼容性但永不显示；船尾轨迹统一由
	# MapVfxPool 在世界坐标“落下”并原地扩散淡出。
	_wake.visible = false
	_wake_base_pos = Vector2(0, 12)
	_wake.position = _wake_base_pos
	_wake.scale = Vector2(0.45, 0.35)
	if transport == GameData.Transport.SHIP:
		_sprite.play("walk")


## 次级运动只写 _sprite.position/rotation_degrees（角色空间，不再被 _sprite.scale 二次放大）。
func _apply_motion_secondary(delta: float, _d_dist: float, speed_px_s: float) -> void:
	if transport == GameData.Transport.CAMEL:
		var phase := (_camel_phase_frames / 8.0) * TAU * 2.0
		var bob := sin(phase) * CAMEL_BOB_PX
		_sprite.position = Vector2(0, -bob)
		_sprite.rotation_degrees = 0.0
		# 阴影不随 bob 上下；仅落脚时轻微压缩，且不跟随棋子移动的位移影响。
		var squash := 1.0 - 0.05 * absf(sin(phase))
		_shadow.scale = Vector2(_shadow_base_scale.x * squash, _shadow_base_scale.y)
		_shadow.position = Vector2(0, 10)
	else:
		_ship_bob_phase += delta * TAU * 1.6
		var bob := sin(_ship_bob_phase) * SHIP_BOB_PX
		var sway := sin(_ship_bob_phase * 0.7) * SHIP_SWAY_DEG
		_sprite.position = Vector2(0, -bob)
		_sprite.rotation_degrees = sway
		var ref := maxf(_move_reference_speed, 1.0)
		_sprite.speed_scale = clampf(speed_px_s / ref, SHIP_SPEED_SCALE_MIN, SHIP_SPEED_SCALE_MAX)


## 骆驼步态帧完全由已行进距离驱动（非固定 FPS）；停止/减速时天然放慢或停住，转向不重置相位。
## 商船脚步无关，仅推进尾流生成节流。
func _advance_gait_and_vfx(d_dist: float) -> void:
	if transport == GameData.Transport.CAMEL:
		if d_dist > 0.0:
			_camel_phase_frames = fposmod(_camel_phase_frames + (d_dist / CAMEL_GAIT_CYCLE_DISTANCE) * 8.0, 8.0)
			var fi := int(_camel_phase_frames) % 8
			if fi != _camel_prev_frame_idx:
				_sprite.frame = fi
				if fi in DUST_STEP_FRAMES and vfx_pool != null:
					vfx_pool.spawn_dust(position + Vector2(0, 10))
				_camel_prev_frame_idx = fi
			_track_frame()
	else:
		if d_dist > 0.0 and vfx_pool != null:
			if _move_last_dist - _wake_last_spawn_dist >= WAKE_SPAWN_SPACING_PX:
				_wake_last_spawn_dist = _move_last_dist
				var back := -_dir_ema.normalized() if _dir_ema.length_squared() > 0.0001 else Vector2(-1, 0)
				vfx_pool.spawn_ripple(position + back * 10.0 + Vector2(0, 10), atan2(back.y, back.x))


func _orient_wake(tangent: Vector2) -> void:
	if not _wake.visible or tangent.length_squared() < 0.0001:
		return
	var back := -tangent.normalized()
	_wake.position = _wake_base_pos + back * 6.0
	_wake.rotation = atan2(back.y, back.x)


func _update_direction_from_tangent(tangent: Vector2) -> void:
	if tangent.length_squared() < 0.0001:
		return
	var deg := rad_to_deg(atan2(tangent.y, tangent.x))
	var next := _dir_from_deg(deg)
	if next == _current_dir:
		return
	# 靠近分界线时保持原方向，避免抖动。
	if _boundary_distance(deg) < DIR_HYSTERESIS_DEG:
		return
	_set_direction(next, true, false)
	if _moving:
		_play_turn_squash()


func _track_frame() -> void:
	if _sprite == null:
		return
	_visited_frames[int(_sprite.frame)] = true


func _set_direction(dir: String, animate: bool, reset_phase: bool) -> void:
	var frames: SpriteFrames = (
		_frames_camel.get(dir) if transport == GameData.Transport.CAMEL else _frames_ship.get(dir)
	)
	if frames == null:
		return
	var prev_frame := 0
	var prev_progress := 0.0
	var was_playing := false
	if _sprite.sprite_frames != null and _sprite.animation == "walk":
		prev_frame = _sprite.frame
		prev_progress = _sprite.frame_progress
		was_playing = _sprite.is_playing()
	_current_dir = dir
	_sprite.sprite_frames = frames
	_sprite.animation = "walk"
	_apply_anchor_offset(dir)
	if transport == GameData.Transport.CAMEL:
		# 骆驼帧完全由 _advance_gait_and_vfx 按距离驱动写入，这里只需保证不用内置计时器播放。
		_sprite.stop()
		if reset_phase:
			_sprite.frame = 0
		else:
			_sprite.frame = int(_camel_phase_frames) % 8
	elif animate:
		_sprite.play("walk")
		if not reset_phase and was_playing:
			_sprite.frame = prev_frame
			_sprite.frame_progress = prev_progress
	else:
		_sprite.stop()
		_sprite.frame = 0
		_sprite.frame_progress = 0.0


## FIX（TASK-MAP-001-REV2）：锚点偏移不应再乘 display_scale，因为 Sprite2D.offset
## 会被 _sprite.scale 二次缩放；此前 `* display_scale` 导致锚点偏移量被放大/缩小了一次。
func _apply_anchor_offset(dir: String) -> void:
	var unit := "camel" if transport == GameData.Transport.CAMEL else "ship"
	var anchor := Vector2(128, 220 if unit == "camel" else 180)
	for entry in _manifest.get("units", []):
		if String(entry.get("unit", "")) == unit and String(entry.get("direction", "")) == dir:
			var a: Array = entry.get("anchor", [128, 220])
			if a.size() >= 2:
				anchor = Vector2(float(a[0]), float(a[1]))
			break
	_base_sprite_offset = Vector2(128 - anchor.x, 128 - anchor.y)
	_sprite.offset = _base_sprite_offset


func _load_manifest() -> void:
	var path := "res://assets/game/pieces/movement_manifest.json"
	if not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		_manifest = parsed


func _build_sprite_frames() -> void:
	_frames_camel.clear()
	_frames_ship.clear()
	for dir in DIRS:
		_frames_camel[dir] = _make_frames("camel", dir, 9.0)
		_frames_ship[dir] = _make_frames("ship", dir, 7.0)


func _make_frames(unit: String, dir: String, fps: float) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.add_animation("walk")
	frames.set_animation_loop("walk", true)
	frames.set_animation_speed("walk", fps)
	var suffix := "walk_8f" if unit == "camel" else "sail_8f"
	var path := "res://assets/game/pieces/%s/%s_%s_%s.png" % [unit, unit, dir, suffix]
	var tex: Texture2D = load(path)
	if tex == null:
		return frames
	for i in 8:
		var atlas := AtlasTexture.new()
		atlas.atlas = tex
		atlas.region = Rect2(i * 256, 0, 256, 256)
		atlas.filter_clip = true
		frames.add_frame("walk", atlas)
	return frames


func _sample_by_arc(samples: PackedVector2Array, arc: Dictionary, t01: float) -> Vector2:
	var cum: PackedFloat32Array = arc["cum"]
	var total: float = arc["total"]
	var target := clampf(t01, 0.0, 1.0) * total
	for i in range(1, cum.size()):
		if target <= cum[i] or i == cum.size() - 1:
			var seg_len := cum[i] - cum[i - 1]
			var local_t := 0.0 if seg_len < 0.0001 else (target - cum[i - 1]) / seg_len
			return samples[i - 1].lerp(samples[i], clampf(local_t, 0.0, 1.0))
	return samples[samples.size() - 1]


func _tangent_ahead(samples: PackedVector2Array, arc: Dictionary, t01: float, lookahead: float) -> Vector2:
	var total: float = arc["total"]
	var here := _sample_by_arc(samples, arc, t01)
	var ahead_t := clampf(t01 + lookahead / maxf(total, 1.0), 0.0, 1.0)
	if ahead_t <= t01 + 0.0001:
		ahead_t = clampf(t01 - lookahead / maxf(total, 1.0), 0.0, 1.0)
		var behind := _sample_by_arc(samples, arc, ahead_t)
		return here - behind
	var ahead := _sample_by_arc(samples, arc, ahead_t)
	return ahead - here


func _pulse_ring() -> void:
	if _ring == null:
		return
	if _tween_ring != null and _tween_ring.is_valid():
		_tween_ring.kill()
	_ring.scale = Vector2(1.35, 1.35)
	_tween_ring = create_tween()
	_tween_ring.tween_property(_ring, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _play_depart_squash() -> void:
	if _tween_deform != null and _tween_deform.is_valid():
		_tween_deform.kill()
	var base := Vector2(display_scale, display_scale)
	_sprite.scale = Vector2(base.x * 1.10, base.y * 0.90)
	_tween_deform = create_tween()
	_tween_deform.tween_property(_sprite, "scale", base, DEPART_SQUASH_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _play_arrive_bounce() -> void:
	if _tween_deform != null and _tween_deform.is_valid():
		_tween_deform.kill()
	var base := Vector2(display_scale, display_scale)
	_sprite.scale = Vector2(base.x * 1.06, base.y * 1.06) # 轻微弹跳，不做夸张缩放
	_tween_deform = create_tween()
	_tween_deform.tween_property(_sprite, "scale", base, ARRIVE_BOUNCE_TIME).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _play_turn_squash() -> void:
	if _tween_deform != null and _tween_deform.is_valid():
		_tween_deform.kill()
	var base := Vector2(display_scale, display_scale)
	_sprite.scale = Vector2(base.x * 0.94, base.y * 1.06) # 2~3 帧的极小挤压，不产生位置跳变
	_tween_deform = create_tween()
	_tween_deform.tween_property(_sprite, "scale", base, TURN_SQUASH_TIME).set_trans(Tween.TRANS_SINE)


func _make_ellipse_texture(color: Color, w: int, h: int) -> Texture2D:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := w * 0.5
	var cy := h * 0.5
	for y in h:
		for x in w:
			var nx := (x - cx) / (w * 0.5)
			var ny := (y - cy) / (h * 0.5)
			if nx * nx + ny * ny <= 1.0:
				var a := color.a * (1.0 - sqrt(nx * nx + ny * ny))
				img.set_pixel(x, y, Color(color.r, color.g, color.b, a))
	return ImageTexture.create_from_image(img)
