extends Control

## TASK-006C-REV5：花叶错位、路径分层与数量扩充。

var _built := false
var _active := false
var _dynamics_enabled := true
var _time := 0.0
var _rng := RandomNumberGenerator.new()
var _smoke_shader: Shader

var _nodes: Dictionary = {}
var _actors: Dictionary = {}
var _state: Dictionary = {}
var _actor_start_log: Array = []

var _drift_pool: Array = [] # {root, sprite, kind, life, ...}
var _smoke_slots: Array = [] # {wrap, sprite, mat, chimney, phase}
var _distant_boats: Dictionary = {} # key -> {boat, wake_root, wake, cfg}
var _actor_shadow_tex: Texture2D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	set_process(false)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	size = TitleEffectCatalog.DESIGN_SIZE


func start_effects() -> void:
	if not _built:
		_build()
		_built = true
	if _active:
		return
	_active = true
	set_process(_dynamics_enabled)
	_layout_static()
	_apply_dynamics_visibility()
	if _dynamics_enabled:
		_update_all(0.0)


func stop_effects() -> void:
	if not _active:
		return
	_active = false
	set_process(false)


func set_dynamics_enabled(enabled: bool) -> void:
	_dynamics_enabled = enabled
	if not enabled:
		for item in _drift_pool:
			item["life"] = -1.0
			item["lane"] = ""
	if _built:
		_apply_dynamics_visibility()
	if _active:
		set_process(_dynamics_enabled)
		if _dynamics_enabled:
			_update_all(0.0)


func is_effects_active() -> bool:
	return _active


func get_internal_time() -> float:
	return _time


func get_world_animation_speed() -> float:
	return TitleEffectCatalog.WORLD_ANIMATION_SPEED


func get_static_rect(id: String) -> Rect2:
	if id == "background":
		return TitleEffectCatalog.STATIC_LAYER_RECTS["background"]
	var node: TextureRect = _nodes.get(_static_node_name(id)) as TextureRect
	if node == null:
		return Rect2()
	return Rect2(node.position, node.size)


func get_dynamic_rect(id: String) -> Rect2:
	if TitleEffectCatalog.BRANCH_CONFIGS.has(id):
		return TitleEffectCatalog.BRANCH_CONFIGS[id]["rect"]
	if TitleEffectCatalog.SMOKE_CONFIGS.has(id):
		return TitleEffectCatalog.SMOKE_CONFIGS[id]["rect"]
	if TitleEffectCatalog.DRIFT_POOL.has(id):
		var d: Dictionary = TitleEffectCatalog.DRIFT_POOL[id]
		return Rect2(Vector2.ZERO, d["display_size"])
	if TitleEffectCatalog.BOAT_CONFIGS.has(id):
		return TitleEffectCatalog.BOAT_CONFIGS[id]["rect"]
	if id == "sail_ripple":
		return TitleEffectCatalog.BOAT_CONFIGS["sail"]["ripple_rect"]
	if id == "cargo_ripple":
		return TitleEffectCatalog.BOAT_CONFIGS["cargo"]["ripple_rect"]
	if id == "cloud":
		return TitleEffectCatalog.CLOUD_CONFIG["rect"]
	return Rect2()


func get_actor_route(key: String) -> Dictionary:
	var cfg: Dictionary = TitleEffectCatalog.ACTOR_CONFIGS[key]
	return {
		"key": key,
		"start": cfg["start"],
		"end": cfg["end"],
		"display_size": cfg["display_size"],
		"duration": cfg["duration"],
		"first_start": cfg["first_start"],
		"frame_count": int(cfg["frame_count"]),
		"fps": float(cfg["fps"]),
		"flip_h": bool(cfg["flip_h"]),
	}


func get_actor_info(key: String) -> Dictionary:
	var cfg: Dictionary = TitleEffectCatalog.ACTOR_CONFIGS[key]
	var slot: Dictionary = _actors[key]
	var spr: TextureRect = slot["sprite"]
	var shadow: TextureRect = slot["shadow"]
	var root: Control = slot["root"]
	var life := float(_state.get("actor_%s_life" % key, -1.0))
	var gait := float(_state.get("actor_%s_gait" % key, 0.0))
	var frame_count := int(cfg["frame_count"])
	var seq: Array = cfg["frame_sequence"]
	var gait_fps := float(cfg["gait_fps"])
	var frame_i := 0
	var foot: Vector2 = cfg["start"]
	if life >= 0.0:
		var u := clampf(life / float(cfg["duration"]), 0.0, 1.0)
		foot = (cfg["start"] as Vector2).lerp(cfg["end"] as Vector2, u)
		if seq.size() > 0:
			frame_i = int(seq[int(floor(gait * gait_fps)) % seq.size()])
	var shadow_center := root.position + shadow.position + shadow.size * 0.5
	return {
		"key": key,
		"frame_count": frame_count,
		"current_frame": frame_i,
		"gait_fps": gait_fps,
		"gait_time": gait,
		"flip_h": bool(cfg["flip_h"]),
		"start": cfg["start"],
		"end": cfg["end"],
		"foot_position": foot,
		"shadow_center": shadow_center,
		"shadow_visible": shadow.visible,
		"duration": float(cfg["duration"]),
		"visible": _is_actor_visible(key),
		"scale": spr.scale,
	}


func get_seagull_route() -> Dictionary:
	return {
		"start": TitleEffectCatalog.SEAGULL_CONFIG["start"],
		"end": TitleEffectCatalog.SEAGULL_CONFIG["end"],
		"display_size": TitleEffectCatalog.SEAGULL_CONFIG["display_size"],
		"duration_min": TitleEffectCatalog.SEAGULL_CONFIG["duration_min"],
		"duration_max": TitleEffectCatalog.SEAGULL_CONFIG["duration_max"],
	}


func get_boat_rect(key: String) -> Rect2:
	return TitleEffectCatalog.BOAT_CONFIGS[key]["rect"]


func get_distant_boat_info(key: String) -> Dictionary:
	var cfg: Dictionary = TitleEffectCatalog.DISTANT_BOAT_CONFIGS[key]
	var life := float(_state.get("db_%s_life" % key, -1.0))
	var dur := float(_state.get("db_%s_dur" % key, 1.0))
	var u := 0.0
	var pose := {
		"center": cfg["start"] as Vector2,
		"route_direction": Vector2.RIGHT,
		"visual_heading": Vector2.RIGHT,
		"stern_world": cfg["start"] as Vector2,
		"bow_world": cfg["start"] as Vector2,
		"boat_rotation": 0.0,
		"alpha": 0.0,
		"wake_rotation": 0.0,
	}
	var visible := false
	var heading_err_deg := 0.0
	var wake_heading_err_deg := 0.0
	if life >= 0.0 and _dynamics_enabled:
		u = clampf(life / maxf(dur, 0.001), 0.0, 1.0)
		pose = _compute_distant_boat_pose(key, u)
		visible = float(pose["alpha"]) > 0.01
		heading_err_deg = absf(rad_to_deg(_normalize_angle(
			(pose["visual_heading"] as Vector2).angle() - (pose["route_direction"] as Vector2).angle()
		)))
		wake_heading_err_deg = absf(rad_to_deg(_normalize_angle(
			float(pose["wake_rotation"]) - (pose["visual_heading"] as Vector2).angle()
		)))
	var wake_root: Control = _distant_boats[key]["wake_root"]
	return {
		"key": key,
		"rect": cfg["rect"],
		"start": cfg["start"],
		"end": cfg["end"],
		"duration": dur,
		"life": life,
		"u": u,
		"center": pose["center"],
		"direction": pose["route_direction"],
		"route_direction": pose["route_direction"],
		"visual_heading": pose["visual_heading"],
		"alpha": pose["alpha"],
		"visible": visible,
		"first_delay": float(cfg["first_delay"]),
		"started": bool(_state.get("db_%s_started" % key, false)),
		"wake_size": cfg["wake_size"],
		"wake_alpha": float(cfg["wake_alpha"]),
		"heading_err_deg": heading_err_deg,
		"wake_heading_err_deg": wake_heading_err_deg,
		"stern": pose["stern_world"],
		"bow": pose["bow_world"],
		"stern_world": pose["stern_world"],
		"bow_world": pose["bow_world"],
		"wake_tip": wake_root.position if visible else pose["stern_world"],
		"has_ripple": false,
		"has_splash": false,
	}


func count_distant_boats() -> int:
	return _distant_boats.size()


func get_cloud_rect() -> Rect2:
	return TitleEffectCatalog.CLOUD_CONFIG["rect"]


func get_draw_order_names() -> Array[String]:
	var names: Array[String] = []
	for child in get_children():
		names.append(String(child.name))
	return names


func count_visible_actors() -> int:
	var n := 0
	for key in _actors.keys():
		if _is_actor_visible(key):
			n += 1
	return n


func get_actor_start_log() -> Array:
	return _actor_start_log.duplicate(true)


func get_scheduler_state() -> Dictionary:
	return {
		"time": _time,
		"visible": count_visible_actors(),
		"next_key": String(_state.get("sched_next_key", "")),
		"next_at": float(_state.get("sched_next_at", -1.0)),
		"first_index": int(_state.get("actor_first_index", 0)),
		"loop_index": int(_state.get("actor_loop_index", 0)),
		"last_start": float(_state.get("sched_last_start", -999.0)),
		"starts": get_actor_start_log(),
	}


func count_drift_pool() -> int:
	return _drift_pool.size()


func get_active_drifts() -> Array:
	var out: Array = []
	if not _dynamics_enabled:
		return out
	for item in _drift_pool:
		if float(item.get("life", -1.0)) < 0.0:
			continue
		var spr: TextureRect = item["sprite"]
		var root: Control = item["root"]
		if not root.visible or not spr.visible:
			continue
		var size: Vector2 = item.get("base_size", Vector2.ONE)
		out.append({
			"kind": String(item["kind"]),
			"lane": String(item.get("lane", "")),
			"position": root.position + size * 0.5,
			"start": item.get("p0", Vector2.ZERO),
			"end": item.get("p3", Vector2.ZERO),
			"duration": float(item.get("dur", 0.0)),
			"scale_mul": float(item.get("scale_mul", 1.0)),
			"alpha": spr.modulate.a,
			"life": float(item["life"]),
		})
	return out


func get_spawned_drift_samples(limit: int = 12) -> Array:
	var log: Array = _state.get("drift_spawn_log", [])
	if log.size() <= limit:
		return log.duplicate(true)
	return log.slice(0, limit)


func count_smoke_slots() -> int:
	return _smoke_slots.size()


func get_branch_max_swing(key: String) -> float:
	var cfg: Dictionary = TitleEffectCatalog.BRANCH_CONFIGS[key]
	return float(cfg["main_swing_deg"]) + float(cfg["secondary_swing_deg"])


func _process(delta: float) -> void:
	if not _active or not _dynamics_enabled:
		return
	var anim_delta := delta * TitleEffectCatalog.WORLD_ANIMATION_SPEED
	_time += anim_delta
	_update_all(anim_delta)


func _build() -> void:
	_rng.seed = TitleEffectCatalog.RNG_SEED
	_smoke_shader = load(TitleEffectCatalog.SMOKE_SHADER_PATH)
	_clear_children()
	clip_contents = true
	size = TitleEffectCatalog.DESIGN_SIZE

	_add_static_layer("OceanLayer", "ocean")
	_add_static_layer("LandLayer", "land")
	_add_actor("spice_vendor_rtl", "SpiceVendorRTLActor")
	_add_actor("flower_woman_rtl", "FlowerWomanRTLActor")
	_add_distant_boats()
	_add_actor("dock", "DockWorkerActor")
	_add_static_layer("DocksLayer", "docks")
	_add_static_layer("IslandsLayer", "islands")
	_add_static_layer("SkyLayer", "sky")
	_add_seagull()
	_add_ripple("sail", "SailboatRipple")
	_add_boat("sail", "ForegroundSailboat")
	_add_cloud()
	_add_ripple("cargo", "CargoBoatRipple")
	_add_boat("cargo", "ForegroundCargoBoat")
	_add_smoke_pool()
	_add_branch("branch_l")
	_add_actor("woman", "WomanActor")
	_add_actor("merchant", "MerchantActor")
	_add_drift_pool()
	_add_parchment_panel()
	_add_branch("branch_r")

	_init_state()
	_layout_static()
	_apply_dynamics_visibility()


func _clear_children() -> void:
	for child in get_children():
		remove_child(child)
		child.free()
	_nodes.clear()
	_actors.clear()
	_actor_start_log.clear()
	_drift_pool.clear()
	_smoke_slots.clear()
	_distant_boats.clear()
	_actor_shadow_tex = null


func _ensure_actor_shadow_tex() -> Texture2D:
	if _actor_shadow_tex != null:
		return _actor_shadow_tex
	# 共享椭圆软阴影：手绘半径衰减，避免 GradientTexture2D 在小尺寸下发虚。
	var wh: Vector2i = TitleEffectCatalog.ACTOR_SHADOW_TEX_SIZE
	var img := Image.create(wh.x, wh.y, false, Image.FORMAT_RGBA8)
	var cx := (wh.x - 1) * 0.5
	var cy := (wh.y - 1) * 0.5
	var center_c := TitleEffectCatalog.ACTOR_SHADOW_CENTER_COLOR
	for y in wh.y:
		for x in wh.x:
			var nx := (float(x) - cx) / maxf(cx, 1.0)
			var ny := (float(y) - cy) / maxf(cy, 1.0)
			var d: float = sqrt(nx * nx + ny * ny)
			var falloff := clampf(1.0 - d, 0.0, 1.0)
			falloff *= falloff
			img.set_pixel(x, y, Color(center_c.r, center_c.g, center_c.b, center_c.a * falloff))
	_actor_shadow_tex = ImageTexture.create_from_image(img)
	return _actor_shadow_tex


func _static_node_name(id: String) -> String:
	match id:
		"ocean":
			return "OceanLayer"
		"land":
			return "LandLayer"
		"docks":
			return "DocksLayer"
		"islands":
			return "IslandsLayer"
		"sky":
			return "SkyLayer"
	return id


func _make_tex_rect(node_name: String, tex: Texture2D) -> TextureRect:
	var tr := TextureRect.new()
	tr.name = node_name
	tr.texture = tex
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	add_child(tr)
	_nodes[node_name] = tr
	return tr


func _add_static_layer(node_name: String, layer_id: String) -> void:
	var tr := _make_tex_rect(node_name, TitleEffectCatalog.layer_atlas(layer_id))
	var rect: Rect2 = TitleEffectCatalog.STATIC_LAYER_RECTS[layer_id]
	tr.position = rect.position
	tr.size = rect.size


func _add_actor(key: String, node_name: String) -> void:
	var cfg: Dictionary = TitleEffectCatalog.ACTOR_CONFIGS[key]
	var root := Control.new()
	root.name = node_name
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.visible = false
	add_child(root)
	_nodes[node_name] = root

	var shadow := TextureRect.new()
	shadow.name = "ActorShadow"
	shadow.texture = _ensure_actor_shadow_tex()
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	shadow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shadow.stretch_mode = TextureRect.STRETCH_SCALE
	shadow.visible = false
	var ssz: Vector2 = cfg["shadow_size"]
	var soff: Vector2 = cfg["shadow_offset"]
	shadow.size = ssz
	shadow.position = soff - ssz * 0.5
	shadow.scale = Vector2.ONE
	root.add_child(shadow)

	var frames: Array = TitleEffectCatalog.sheet_frames(
		String(cfg["tex_id"]),
		int(cfg["frame_count"]),
		cfg["frame_size"] as Vector2
	)
	var spr := TextureRect.new()
	spr.name = "Sprite"
	spr.texture = frames[0]
	spr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	spr.stretch_mode = TextureRect.STRETCH_SCALE
	spr.visible = false
	spr.scale = Vector2(-1.0, 1.0) if bool(cfg["flip_h"]) else Vector2.ONE
	root.add_child(spr)
	_actors[key] = {"sprite": spr, "shadow": shadow, "frames": frames, "cfg": cfg, "root": root}


func _add_seagull() -> void:
	var frames: Array = TitleEffectCatalog.sheet_frames("seagull_close_sheet")
	var tr := _make_tex_rect("CloseSeagull", frames[0])
	tr.visible = false
	_nodes["CloseSeagullFrames"] = frames


func _add_boat(key: String, node_name: String) -> void:
	var tr := _make_tex_rect(node_name, TitleEffectCatalog.boat_atlas(key))
	var rect: Rect2 = TitleEffectCatalog.BOAT_CONFIGS[key]["rect"]
	tr.position = rect.position
	tr.size = rect.size
	tr.pivot_offset = tr.size * 0.5


func _add_distant_boats() -> void:
	# 绘制顺序：far → tiny → mid；每船仅 wake → boat
	for key in TitleEffectCatalog.DISTANT_BOAT_ORDER:
		var cfg: Dictionary = TitleEffectCatalog.DISTANT_BOAT_CONFIGS[key]
		var wake_root := Control.new()
		wake_root.name = String(cfg["wake_node"])
		wake_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wake_root.visible = false
		add_child(wake_root)
		_nodes[wake_root.name] = wake_root
		var wake := TextureRect.new()
		wake.name = "WakeSprite"
		wake.texture = TitleEffectCatalog.distant_wake_atlas()
		wake.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wake.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		wake.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		wake.stretch_mode = TextureRect.STRETCH_SCALE
		wake_root.add_child(wake)
		var boat := _make_tex_rect(String(cfg["boat_node"]), TitleEffectCatalog.distant_boat_atlas(key))
		boat.visible = false
		var rect: Rect2 = cfg["rect"]
		boat.size = rect.size
		boat.pivot_offset = boat.size * 0.5
		_distant_boats[key] = {
			"boat": boat,
			"wake_root": wake_root,
			"wake": wake,
			"cfg": cfg,
		}


func _add_parchment_panel() -> void:
	var tr := _make_tex_rect("RightParchmentPanel", TitleEffectCatalog.ui_atlas("parchment"))
	var rect: Rect2 = TitleEffectCatalog.TITLE_UI_RECTS["parchment"]
	tr.position = rect.position
	tr.size = rect.size
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	tr.visible = true


func _add_ripple(boat_key: String, node_name: String) -> void:
	var tr := _make_tex_rect(node_name, TitleEffectCatalog.ripple_atlas())
	var rect: Rect2 = TitleEffectCatalog.BOAT_CONFIGS[boat_key]["ripple_rect"]
	tr.position = rect.position
	tr.size = rect.size
	tr.pivot_offset = tr.size * 0.5


func _add_cloud() -> void:
	var tr := _make_tex_rect("CumulusBand", TitleEffectCatalog.cloud_atlas())
	var rect: Rect2 = TitleEffectCatalog.CLOUD_CONFIG["rect"]
	tr.position = rect.position
	tr.size = rect.size


func _add_branch(key: String) -> void:
	var cfg: Dictionary = TitleEffectCatalog.BRANCH_CONFIGS[key]
	var tr := _make_tex_rect(String(cfg["node"]), TitleEffectCatalog.branch_atlas(key))
	var rect: Rect2 = cfg["rect"]
	tr.position = rect.position
	tr.size = rect.size
	tr.pivot_offset = (cfg["pivot"] as Vector2) - rect.position
	tr.rotation_degrees = float(cfg["base_angle"])


func _add_drift_pool() -> void:
	var pool := Control.new()
	pool.name = "DriftingPetalPool"
	pool.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pool.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	pool.size = TitleEffectCatalog.DESIGN_SIZE
	add_child(pool)
	_nodes["DriftingPetalPool"] = pool

	for kind in ["petal", "leaf", "leaf_spin", "petal_cluster"]:
		var cfg: Dictionary = TitleEffectCatalog.DRIFT_POOL[kind]
		for i in int(cfg["count"]):
			var root := Control.new()
			root.name = "%s_%d" % [kind, i]
			root.mouse_filter = Control.MOUSE_FILTER_IGNORE
			pool.add_child(root)
			var spr := TextureRect.new()
			spr.name = "Sprite"
			spr.texture = TitleEffectCatalog.drift_atlas(kind)
			spr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			spr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			spr.stretch_mode = TextureRect.STRETCH_SCALE
			spr.visible = false
			root.add_child(spr)
			_drift_pool.append({
				"root": root,
				"sprite": spr,
				"kind": kind,
				"life": -1.0,
			})


func _add_smoke_pool() -> void:
	var pool := Control.new()
	pool.name = "SmokePool"
	pool.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pool.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	pool.size = TitleEffectCatalog.DESIGN_SIZE
	add_child(pool)
	_nodes["SmokePool"] = pool

	for chimney in ["smoke_m", "smoke_l"]:
		var cfg: Dictionary = TitleEffectCatalog.SMOKE_CONFIGS[chimney]
		var names: Array = cfg["nodes"]
		for si in 2:
			var wrap := Control.new()
			wrap.name = String(names[si])
			wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			wrap.clip_contents = true
			pool.add_child(wrap)
			var spr := TextureRect.new()
			spr.name = "Sprite"
			spr.texture = TitleEffectCatalog.smoke_atlas(chimney)
			spr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			spr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			spr.stretch_mode = TextureRect.STRETCH_SCALE
			if _smoke_shader != null:
				var mat := ShaderMaterial.new()
				mat.shader = _smoke_shader
				mat.set_shader_parameter("reveal_progress", 0.0)
				spr.material = mat
			wrap.add_child(spr)
			_smoke_slots.append({
				"wrap": wrap,
				"sprite": spr,
				"chimney": chimney,
				"phase": 0.0 if si == 0 else 0.5,
			})
			_nodes[String(names[si])] = wrap


func _layout_static() -> void:
	size = TitleEffectCatalog.DESIGN_SIZE
	clip_contents = true
	for layer_id in ["ocean", "land", "docks", "islands", "sky"]:
		var tr: TextureRect = _nodes[_static_node_name(layer_id)]
		var rect: Rect2 = TitleEffectCatalog.STATIC_LAYER_RECTS[layer_id]
		tr.position = rect.position
		tr.size = rect.size
		tr.scale = Vector2.ONE
		tr.rotation = 0.0
		tr.modulate.a = 1.0
		tr.visible = true
	for key in TitleEffectCatalog.BOAT_CONFIGS.keys():
		var cfg: Dictionary = TitleEffectCatalog.BOAT_CONFIGS[key]
		var boat: TextureRect = _nodes[String(cfg["node"])]
		var rect: Rect2 = cfg["rect"]
		boat.size = rect.size
		boat.pivot_offset = boat.size * 0.5
		boat.position = rect.position
		var ripple: TextureRect = _nodes[String(cfg["ripple_node"])]
		var rrect: Rect2 = cfg["ripple_rect"]
		ripple.size = rrect.size
		ripple.pivot_offset = ripple.size * 0.5
		ripple.position = rrect.position
		ripple.rotation = 0.0
	var cloud: TextureRect = _nodes["CumulusBand"]
	var crect: Rect2 = TitleEffectCatalog.CLOUD_CONFIG["rect"]
	cloud.size = crect.size
	cloud.position = crect.position
	for key in TitleEffectCatalog.BRANCH_CONFIGS.keys():
		var bcfg: Dictionary = TitleEffectCatalog.BRANCH_CONFIGS[key]
		var btr: TextureRect = _nodes[String(bcfg["node"])]
		var brect: Rect2 = bcfg["rect"]
		btr.size = brect.size
		btr.position = brect.position
		btr.pivot_offset = (bcfg["pivot"] as Vector2) - brect.position
		btr.rotation_degrees = float(bcfg["base_angle"])
	if _nodes.has("DriftingPetalPool"):
		(_nodes["DriftingPetalPool"] as Control).size = TitleEffectCatalog.DESIGN_SIZE
	if _nodes.has("SmokePool"):
		(_nodes["SmokePool"] as Control).size = TitleEffectCatalog.DESIGN_SIZE
	if _nodes.has("RightParchmentPanel"):
		var parch: TextureRect = _nodes["RightParchmentPanel"]
		var prect: Rect2 = TitleEffectCatalog.TITLE_UI_RECTS["parchment"]
		parch.position = prect.position
		parch.size = prect.size
		parch.visible = true
		parch.modulate.a = 1.0


func _init_state() -> void:
	_time = 0.0
	_actor_start_log.clear()
	_state = {
		"frame_t": 0.0,
		"seagull_life": -1.0,
		"seagull_cd": _rng.randf_range(
			TitleEffectCatalog.SEAGULL_CONFIG["first_delay_min"],
			TitleEffectCatalog.SEAGULL_CONFIG["first_delay_max"]
		),
		"seagull_dur": 4.8,
		"cloud_period": _rng.randf_range(
			TitleEffectCatalog.CLOUD_CONFIG["period_min"],
			TitleEffectCatalog.CLOUD_CONFIG["period_max"]
		),
		"cargo_period": _rng.randf_range(
			TitleEffectCatalog.BOAT_CONFIGS["cargo"]["period_min"],
			TitleEffectCatalog.BOAT_CONFIGS["cargo"]["period_max"]
		),
		"sail_period": _rng.randf_range(
			TitleEffectCatalog.BOAT_CONFIGS["sail"]["period_min"],
			TitleEffectCatalog.BOAT_CONFIGS["sail"]["period_max"]
		),
		"actor_first_index": 0,
		"actor_loop_index": 0,
		"sched_next_key": TitleEffectCatalog.ACTOR_ORDER[0],
		"sched_next_at": float(TitleEffectCatalog.ACTOR_CONFIGS[TitleEffectCatalog.ACTOR_ORDER[0]]["first_start"]),
		"sched_last_start": -999.0,
		"gust_cd": TitleEffectCatalog.DRIFT_CONFIG["first_gust_delay"],
		"gust_queue": [],
		"cluster_cd": _rng.randf_range(6.0, 12.0),
		"zone_index": 0,
		"lane_index": _rng.randi_range(0, 2),
		"recent_zones": [],
		"recent_lanes": [],
		"recent_scales": [],
		"last_spawn_pos": Vector2(-9999, -9999),
		"last_end_pos": Vector2(-9999, -9999),
		"drift_spawn_log": [],
	}
	for key in TitleEffectCatalog.ACTOR_ORDER:
		_state["actor_%s_life" % key] = -1.0
		_state["actor_%s_gait" % key] = 0.0
	_state["recent_actor_dirs"] = []
	for key in TitleEffectCatalog.DISTANT_BOAT_ORDER:
		var dcfg: Dictionary = TitleEffectCatalog.DISTANT_BOAT_CONFIGS[key]
		_state["db_%s_life" % key] = -1.0
		_state["db_%s_cd" % key] = float(dcfg["first_delay"])
		_state["db_%s_dur" % key] = _rng.randf_range(float(dcfg["duration_min"]), float(dcfg["duration_max"]))
		_state["db_%s_bob_period" % key] = _rng.randf_range(float(dcfg["bob_period_min"]), float(dcfg["bob_period_max"]))
		_state["db_%s_started" % key] = false
	for chimney in TitleEffectCatalog.SMOKE_CONFIGS.keys():
		var scfg: Dictionary = TitleEffectCatalog.SMOKE_CONFIGS[chimney]
		_state["%s_cycle" % chimney] = _rng.randf_range(float(scfg["cycle_min"]), float(scfg["cycle_max"]))
		_state["%s_rise" % chimney] = _rng.randf_range(float(scfg["rise_min"]), float(scfg["rise_max"]))


func _apply_dynamics_visibility() -> void:
	var always_dyn := [
		"CloseSeagull", "SailboatRipple", "ForegroundSailboat", "CumulusBand",
		"CargoBoatRipple", "ForegroundCargoBoat", "SmokePool", "ForegroundBranchV1",
		"DriftingPetalPool", "ForegroundBranchV2",
	]
	for n in always_dyn:
		if _nodes.has(n):
			(_nodes[n] as CanvasItem).visible = _dynamics_enabled
	# 羊皮卷属于开屏 UI 层，不受 dynamics 开关隐藏。
	if _nodes.has("RightParchmentPanel"):
		(_nodes["RightParchmentPanel"] as CanvasItem).visible = true
	for key in _actors.keys():
		var slot: Dictionary = _actors[key]
		if not _dynamics_enabled:
			(slot["sprite"] as TextureRect).visible = false
			(slot["shadow"] as TextureRect).visible = false
			(slot["root"] as Control).visible = false
	if not _dynamics_enabled:
		for item in _drift_pool:
			(item["sprite"] as TextureRect).visible = false
			(item["root"] as Control).visible = false
		for slot in _smoke_slots:
			(slot["wrap"] as Control).visible = false
		for key in _distant_boats.keys():
			_hide_distant_boat(String(key))


func _update_all(delta: float) -> void:
	_state["frame_t"] = float(_state["frame_t"]) + delta
	_update_actor_scheduler(delta)
	_update_actors(delta)
	_update_seagull(delta)
	_update_boats_and_ripples()
	_update_distant_boats(delta)
	_update_cloud()
	_update_branches()
	_update_drift_system(delta)
	_update_smokes()


# ---------- Actors (REV5 addendum: 5 actors, per-sheet frames, RTL flip) ----------

func _is_actor_visible(key: String) -> bool:
	var spr: TextureRect = _actors[key]["sprite"]
	return (
		spr.visible
		and spr.modulate.a > 0.01
		and float(_state["actor_%s_life" % key]) >= 0.0
	)


func _actor_dir_sign(key: String) -> int:
	var cfg: Dictionary = TitleEffectCatalog.ACTOR_CONFIGS[key]
	return -1 if float((cfg["end"] as Vector2).x) < float((cfg["start"] as Vector2).x) else 1


func _would_triple_same_dir(key: String) -> bool:
	var recent: Array = _state.get("recent_actor_dirs", [])
	if recent.size() < 2:
		return false
	var d := _actor_dir_sign(key)
	return int(recent[recent.size() - 1]) == d and int(recent[recent.size() - 2]) == d


func _start_actor(key: String) -> void:
	_state["actor_%s_life" % key] = 0.0
	_state["actor_%s_gait" % key] = 0.0
	_state["sched_last_start"] = _time
	_state["sched_next_key"] = key
	_actor_start_log.append({"key": key, "t": _time})
	var recent: Array = _state.get("recent_actor_dirs", [])
	recent.append(_actor_dir_sign(key))
	if recent.size() > 8:
		recent = recent.slice(recent.size() - 8, recent.size())
	_state["recent_actor_dirs"] = recent


func _pick_actor_gap() -> float:
	if count_visible_actors() < TitleEffectCatalog.ACTOR_CROWD_TARGET_MIN:
		return _rng.randf_range(
			TitleEffectCatalog.ACTOR_RECOVERY_GAP_MIN,
			TitleEffectCatalog.ACTOR_RECOVERY_GAP_MAX
		)
	return _rng.randf_range(TitleEffectCatalog.ACTOR_LOOP_GAP_MIN, TitleEffectCatalog.ACTOR_LOOP_GAP_MAX)


func _required_start_gap() -> float:
	if count_visible_actors() < TitleEffectCatalog.ACTOR_CROWD_TARGET_MIN:
		return TitleEffectCatalog.ACTOR_RECOVERY_GAP_MIN
	return TitleEffectCatalog.ACTOR_MIN_START_GAP


func _schedule_after_start() -> void:
	var order := TitleEffectCatalog.ACTOR_ORDER
	var first_idx := int(_state["actor_first_index"])
	if first_idx < order.size():
		var next_key := order[first_idx]
		_state["sched_next_key"] = next_key
		_state["sched_next_at"] = maxf(
			float(TitleEffectCatalog.ACTOR_CONFIGS[next_key]["first_start"]),
			float(_state["sched_last_start"]) + TitleEffectCatalog.ACTOR_MIN_START_GAP
		)
		return
	var gap := _pick_actor_gap()
	var loop_i := int(_state["actor_loop_index"]) % order.size()
	_state["sched_next_key"] = order[loop_i]
	_state["sched_next_at"] = maxf(
		_time + gap,
		float(_state["sched_last_start"]) + _required_start_gap()
	)


func _update_actor_scheduler(_delta: float) -> void:
	if _time + 0.0001 < float(_state["sched_next_at"]):
		return
	if count_visible_actors() >= TitleEffectCatalog.ACTOR_MAX_VISIBLE:
		return
	if _time - float(_state["sched_last_start"]) < _required_start_gap() - 0.001:
		return

	var order := TitleEffectCatalog.ACTOR_ORDER
	var first_idx := int(_state["actor_first_index"])
	if first_idx < order.size():
		var key := order[first_idx]
		if _time + 0.0001 < float(TitleEffectCatalog.ACTOR_CONFIGS[key]["first_start"]):
			_state["sched_next_key"] = key
			_state["sched_next_at"] = float(TitleEffectCatalog.ACTOR_CONFIGS[key]["first_start"])
			return
		if float(_state["actor_%s_life" % key]) >= 0.0:
			return
		_start_actor(key)
		_state["actor_first_index"] = first_idx + 1
		_schedule_after_start()
		return

	# Round-robin：跳过在场角色与会造成连续三同向的人选。
	var loop_i := int(_state["actor_loop_index"])
	var started := false
	var fallback_key := ""
	var fallback_i := loop_i
	for _try in order.size():
		var key := order[loop_i % order.size()]
		if float(_state["actor_%s_life" % key]) < 0.0:
			if fallback_key == "":
				fallback_key = key
				fallback_i = loop_i
			if not _would_triple_same_dir(key):
				_start_actor(key)
				_state["actor_loop_index"] = (loop_i + 1) % order.size()
				started = true
				break
		loop_i += 1
	if not started and fallback_key != "":
		_start_actor(fallback_key)
		_state["actor_loop_index"] = (fallback_i + 1) % order.size()
		started = true
	if started:
		_schedule_after_start()


func _update_actors(delta: float) -> void:
	for key in TitleEffectCatalog.ACTOR_ORDER:
		_tick_actor(key, delta)


func _tick_actor(key: String, delta: float) -> void:
	var slot: Dictionary = _actors[key]
	var spr: TextureRect = slot["sprite"]
	var shadow: TextureRect = slot["shadow"]
	var root: Control = slot["root"]
	var frames: Array = slot["frames"]
	var cfg: Dictionary = slot["cfg"]
	var life_key := "actor_%s_life" % key
	var gait_key := "actor_%s_gait" % key
	if float(_state[life_key]) < 0.0:
		spr.visible = false
		shadow.visible = false
		root.visible = false
		return
	_state[life_key] = float(_state[life_key]) + delta
	_state[gait_key] = float(_state[gait_key]) + delta
	var dur: float = float(cfg["duration"])
	var u := clampf(float(_state[life_key]) / dur, 0.0, 1.0)
	var foot: Vector2 = (cfg["start"] as Vector2).lerp(cfg["end"] as Vector2, u)
	var disp: Vector2 = cfg["display_size"]
	var frame_size: Vector2 = cfg["frame_size"]
	var flip_h := bool(cfg["flip_h"])
	var seq: Array = cfg["frame_sequence"]
	var gait_fps := float(cfg["gait_fps"])
	var seq_i := int(floor(float(_state[gait_key]) * gait_fps)) % maxi(seq.size(), 1)
	var frame_i := int(seq[seq_i])
	spr.texture = frames[frame_i]
	spr.size = disp
	var scale := disp.x / frame_size.x
	var anchor := TitleEffectCatalog.ACTOR_FOOT_ANCHOR * scale
	# Root 钉在脚底；Sprite 相对 Root；flip 围绕脚底 pivot，不带动阴影。
	root.position = foot
	spr.pivot_offset = anchor
	spr.position = -anchor
	spr.scale = Vector2(-1.0, 1.0) if flip_h else Vector2.ONE
	var ssz: Vector2 = cfg["shadow_size"]
	var soff: Vector2 = cfg["shadow_offset"]
	shadow.size = ssz
	shadow.position = soff - ssz * 0.5
	shadow.scale = Vector2.ONE
	shadow.rotation = 0.0
	var fade := TitleEffectCatalog.ACTOR_FADE
	var alpha := 1.0
	if u < fade:
		alpha = u / fade
	elif u > 1.0 - fade:
		alpha = (1.0 - u) / fade
	alpha = clampf(alpha, 0.0, 1.0)
	spr.modulate.a = alpha
	shadow.modulate = Color(1.0, 1.0, 1.0, alpha)
	spr.visible = true
	shadow.visible = true
	root.visible = true
	if u >= 1.0:
		_state[life_key] = -1.0
		spr.visible = false
		shadow.visible = false
		root.visible = false


func _update_seagull(delta: float) -> void:
	var bird: TextureRect = _nodes["CloseSeagull"]
	var frames: Array = _nodes["CloseSeagullFrames"]
	var cfg := TitleEffectCatalog.SEAGULL_CONFIG
	if float(_state["seagull_life"]) < 0.0:
		bird.visible = false
		_state["seagull_cd"] = float(_state["seagull_cd"]) - delta
		if float(_state["seagull_cd"]) <= 0.0:
			_state["seagull_life"] = 0.0
			_state["seagull_dur"] = _rng.randf_range(float(cfg["duration_min"]), float(cfg["duration_max"]))
		return
	_state["seagull_life"] = float(_state["seagull_life"]) + delta
	var dur: float = float(_state["seagull_dur"])
	var u := clampf(float(_state["seagull_life"]) / dur, 0.0, 1.0)
	var center: Vector2 = (cfg["start"] as Vector2).lerp(cfg["end"] as Vector2, u)
	var disp: Vector2 = cfg["display_size"]
	var frame_i := int(floor(float(_state["seagull_life"]) * TitleEffectCatalog.SEAGULL_CLOSE_FPS)) % TitleEffectCatalog.SHEET_H_FRAMES
	bird.texture = frames[frame_i]
	bird.size = disp
	bird.pivot_offset = disp * 0.5
	var scale := disp.x / TitleEffectCatalog.SHEET_FRAME_SIZE.x
	var off: Vector2 = TitleEffectCatalog.SEAGULL_CLOSE_FRAME_OFFSETS[frame_i] * scale
	bird.position = center - bird.pivot_offset + off
	var alpha := 1.0
	if u < 0.06:
		alpha = u / 0.06
	elif u > 0.92:
		alpha = (1.0 - u) / 0.08
	bird.modulate.a = alpha
	bird.visible = true
	if float(_state["seagull_life"]) >= dur:
		_state["seagull_life"] = -1.0
		_state["seagull_cd"] = _rng.randf_range(float(cfg["cooldown_min"]), float(cfg["cooldown_max"]))
		bird.visible = false


func _update_boats_and_ripples() -> void:
	_place_boat_and_ripple("sail", float(_state["sail_period"]))
	_place_boat_and_ripple("cargo", float(_state["cargo_period"]))


func _update_distant_boats(delta: float) -> void:
	for key in TitleEffectCatalog.DISTANT_BOAT_ORDER:
		_tick_distant_boat(String(key), delta)


func _distant_boat_alpha(u: float) -> float:
	if u < 0.08:
		return clampf(u / 0.08, 0.0, 1.0)
	if u > 0.90:
		return clampf((1.0 - u) / 0.10, 0.0, 1.0)
	return 1.0


func _hide_distant_boat(key: String) -> void:
	if not _distant_boats.has(key):
		return
	var slot: Dictionary = _distant_boats[key]
	(slot["boat"] as TextureRect).visible = false
	(slot["wake_root"] as Control).visible = false
	(slot["wake"] as TextureRect).visible = false


func _normalize_angle(a: float) -> float:
	return wrapf(a, -PI, PI)


func _compute_distant_boat_pose(key: String, u: float) -> Dictionary:
	var cfg: Dictionary = TitleEffectCatalog.DISTANT_BOAT_CONFIGS[key]
	var p0: Vector2 = cfg["start"]
	var p1: Vector2 = cfg["control_1"]
	var p2: Vector2 = cfg["control_2"]
	var p3: Vector2 = cfg["end"]
	var center := _bezier(p0, p1, p2, p3, u)
	var route_direction := _bezier_tangent(p0, p1, p2, p3, u)
	if route_direction.length_squared() < 0.0001:
		route_direction = (p3 - p0).normalized()
	else:
		route_direction = route_direction.normalized()

	var bob_period := float(_state.get("db_%s_bob_period" % key, 6.0))
	bob_period = maxf(bob_period, 0.001)
	var bob_wave := sin((_time / bob_period) * TAU)
	center.y += float(cfg["bob_px"]) * bob_wave
	var alpha := _distant_boat_alpha(u)
	var sway_rad := deg_to_rad(float(cfg["rotation_sway"]) * sin((_time / bob_period) * TAU * 0.85 + 0.3))

	var boat_size: Vector2 = (cfg["rect"] as Rect2).size
	var local_stern: Vector2 = (cfg["stern_anchor_uv"] as Vector2) * boat_size
	var local_bow: Vector2 = (cfg["bow_anchor_uv"] as Vector2) * boat_size
	var local_heading := (local_bow - local_stern).normalized()
	var boat_rotation := route_direction.angle() - local_heading.angle() + sway_rad
	var pivot := boat_size * 0.5
	var stern_world := center + (local_stern - pivot).rotated(boat_rotation)
	var bow_world := center + (local_bow - pivot).rotated(boat_rotation)
	var visual_heading := (bow_world - stern_world).normalized()
	return {
		"center": center,
		"route_direction": route_direction,
		"visual_heading": visual_heading,
		"stern_world": stern_world,
		"bow_world": bow_world,
		"boat_rotation": boat_rotation,
		"boat_size": boat_size,
		"alpha": alpha,
		"wake_rotation": visual_heading.angle(),
	}


func _apply_distant_boat_pose(key: String, pose: Dictionary) -> void:
	var cfg: Dictionary = TitleEffectCatalog.DISTANT_BOAT_CONFIGS[key]
	var slot: Dictionary = _distant_boats[key]
	var boat: TextureRect = slot["boat"]
	var wake_root: Control = slot["wake_root"]
	var wake: TextureRect = slot["wake"]
	var center: Vector2 = pose["center"]
	var boat_size: Vector2 = pose["boat_size"]
	var alpha := float(pose["alpha"])

	boat.size = boat_size
	boat.pivot_offset = boat_size * 0.5
	boat.rotation = float(pose["boat_rotation"])
	boat.position = center - boat.pivot_offset
	boat.modulate.a = alpha
	boat.visible = true

	var stern_world: Vector2 = pose["stern_world"]
	var wsz: Vector2 = cfg["wake_size"]
	wake_root.position = stern_world
	wake_root.rotation = float(pose["wake_rotation"])
	wake_root.visible = true
	wake.size = wsz
	wake.position = Vector2(-wake.size.x, -wake.size.y * 0.5)
	wake.rotation = 0.0
	wake.scale = Vector2.ONE
	wake.modulate.a = float(cfg["wake_alpha"]) * alpha
	wake.visible = true


func _tick_distant_boat(key: String, delta: float) -> void:
	var cfg: Dictionary = TitleEffectCatalog.DISTANT_BOAT_CONFIGS[key]
	var life_key := "db_%s_life" % key
	var cd_key := "db_%s_cd" % key
	var dur_key := "db_%s_dur" % key
	var bob_key := "db_%s_bob_period" % key

	if float(_state[life_key]) < 0.0:
		_hide_distant_boat(key)
		_state[cd_key] = float(_state[cd_key]) - delta
		if float(_state[cd_key]) <= 0.0:
			_state[life_key] = 0.0
			_state[dur_key] = _rng.randf_range(float(cfg["duration_min"]), float(cfg["duration_max"]))
			_state[bob_key] = _rng.randf_range(float(cfg["bob_period_min"]), float(cfg["bob_period_max"]))
			_state["db_%s_started" % key] = true
		return

	_state[life_key] = float(_state[life_key]) + delta
	var dur: float = float(_state[dur_key])
	var u := clampf(float(_state[life_key]) / maxf(dur, 0.001), 0.0, 1.0)
	if u >= 1.0:
		_state[life_key] = -1.0
		_state[cd_key] = _rng.randf_range(float(cfg["cooldown_min"]), float(cfg["cooldown_max"]))
		_hide_distant_boat(key)
		return

	var pose := _compute_distant_boat_pose(key, u)
	_apply_distant_boat_pose(key, pose)


func _place_boat_and_ripple(key: String, period: float) -> void:
	var cfg: Dictionary = TitleEffectCatalog.BOAT_CONFIGS[key]
	var boat: TextureRect = _nodes[String(cfg["node"])]
	var ripple: TextureRect = _nodes[String(cfg["ripple_node"])]
	var rect: Rect2 = cfg["rect"]
	var rrect: Rect2 = cfg["ripple_rect"]
	var phase: float = float(cfg["ripple_phase"])
	var wave := sin((_time / period) * TAU + phase)
	var bob := float(cfg["bob_px"]) * wave
	var rot := float(cfg["rot_deg"]) * sin((_time / period) * TAU * 0.85 + phase + 0.4)
	boat.size = rect.size
	boat.pivot_offset = boat.size * 0.5
	boat.rotation_degrees = rot
	boat.position = rect.position + Vector2(0.0, bob)
	boat.visible = true
	boat.modulate.a = 1.0

	var t := clampf(0.5 + 0.5 * wave, 0.0, 1.0)
	var sx := lerpf(float(cfg["ripple_scale_x_min"]), float(cfg["ripple_scale_x_max"]), t)
	var sy := lerpf(float(cfg["ripple_scale_y_min"]), float(cfg["ripple_scale_y_max"]), t)
	var a := lerpf(float(cfg["ripple_alpha_min"]), float(cfg["ripple_alpha_max"]), t)
	ripple.rotation = 0.0
	ripple.scale = Vector2.ONE
	ripple.size = Vector2(rrect.size.x * sx, rrect.size.y * sy)
	ripple.pivot_offset = ripple.size * 0.5
	var center := rrect.get_center() + Vector2(0.0, bob * 0.35)
	ripple.position = center - ripple.pivot_offset
	ripple.modulate.a = a
	ripple.visible = true


func _update_cloud() -> void:
	var cfg := TitleEffectCatalog.CLOUD_CONFIG
	var tr: TextureRect = _nodes["CumulusBand"]
	var rect: Rect2 = cfg["rect"]
	var period: float = float(_state["cloud_period"])
	var drift := float(cfg["drift_px"]) * sin((_time / period) * TAU)
	tr.size = rect.size
	tr.position = rect.position + Vector2(drift, 0.0)
	tr.modulate.a = 1.0
	tr.visible = true


# ---------- Branches: dual-frequency swing ----------

func _update_branches() -> void:
	_swing_branch("branch_l")
	_swing_branch("branch_r")


func _swing_branch(key: String) -> void:
	var cfg: Dictionary = TitleEffectCatalog.BRANCH_CONFIGS[key]
	var tr: TextureRect = _nodes[String(cfg["node"])]
	var rect: Rect2 = cfg["rect"]
	var pivot: Vector2 = cfg["pivot"]
	tr.size = rect.size
	tr.position = rect.position
	tr.pivot_offset = pivot - rect.position
	var phase: float = float(cfg["phase"])
	var main := sin((_time / float(cfg["main_period"])) * TAU + phase) * float(cfg["main_swing_deg"])
	var sec := sin((_time / float(cfg["secondary_period"])) * TAU + 0.7 + phase) * float(cfg["secondary_swing_deg"])
	tr.rotation_degrees = float(cfg["base_angle"]) + main + sec
	tr.modulate.a = 1.0
	tr.visible = true


# ---------- Drift gust system (REV5 lanes / dispersion) ----------

func _update_drift_system(delta: float) -> void:
	_tick_drift_lives(delta)
	_state["gust_cd"] = float(_state["gust_cd"]) - delta
	_state["cluster_cd"] = float(_state["cluster_cd"]) - delta

	var queue: Array = _state["gust_queue"]
	if queue.size() > 0:
		var head: Dictionary = queue[0]
		if _time >= float(head["at"]):
			queue.remove_at(0)
			_state["gust_queue"] = queue
			# 同一帧只生成一个
			_spawn_drift_item(String(head["kind"]), bool(head.get("is_cluster", false)))
	elif float(_state["gust_cd"]) <= 0.0:
		_plan_gust()


func _plan_gust() -> void:
	var D := TitleEffectCatalog.DRIFT_CONFIG
	var count := _rng.randi_range(int(D["gust_count_min"]), int(D["gust_count_max"]))
	var queue: Array = []
	var t := _time
	var kinds := ["petal", "petal", "leaf", "leaf_spin", "petal", "leaf", "petal", "leaf_spin"]
	for i in count:
		t += _rng.randf_range(float(D["gust_gap_min"]), float(D["gust_gap_max"]))
		var kind: String = kinds[_rng.randi_range(0, kinds.size() - 1)]
		queue.append({"at": t, "kind": kind, "is_cluster": false})
	if float(_state["cluster_cd"]) <= 0.0 and _rng.randf() < float(D["cluster_chance"]):
		t += _rng.randf_range(1.0, 2.2)
		queue.append({"at": t, "kind": "petal_cluster", "is_cluster": true})
		var cc: Dictionary = TitleEffectCatalog.DRIFT_POOL["petal_cluster"]
		_state["cluster_cd"] = _rng.randf_range(float(cc["cooldown_min"]), float(cc["cooldown_max"]))
	_state["gust_queue"] = queue
	_state["gust_cd"] = (t - _time) + _rng.randf_range(float(D["quiet_min"]), float(D["quiet_max"]))


func _count_active_normal_drifts() -> int:
	var n := 0
	for item in _drift_pool:
		if float(item["life"]) >= 0.0 and String(item["kind"]) != "petal_cluster":
			n += 1
	return n


func _count_lane_active(lane: String) -> int:
	var n := 0
	for item in _drift_pool:
		if float(item["life"]) >= 0.0 and String(item.get("lane", "")) == lane:
			n += 1
	return n


func _pick_zone() -> String:
	var order := TitleEffectCatalog.DRIFT_SPAWN_ZONE_ORDER
	var recent: Array = _state["recent_zones"]
	var idx := int(_state["zone_index"]) % order.size()
	var zone := order[idx]
	# 禁止连续三个同区
	if recent.size() >= 2 and String(recent[recent.size() - 1]) == zone and String(recent[recent.size() - 2]) == zone:
		idx = (idx + 1) % order.size()
		zone = order[idx]
	_state["zone_index"] = (idx + 1) % order.size()
	recent.append(zone)
	if recent.size() > 8:
		recent = recent.slice(recent.size() - 8, recent.size())
	_state["recent_zones"] = recent
	return zone


func _pick_lane(is_cluster: bool, scale_mul: float) -> String:
	var order := TitleEffectCatalog.DRIFT_LANE_ORDER
	var recent: Array = _state["recent_lanes"]
	var idx := int(_state["lane_index"]) % order.size()
	# 轻微景深倾向：小→偏上，大→偏下
	if scale_mul < 0.62 and _rng.randf() < 0.55:
		idx = 0
	elif scale_mul > 0.90 and _rng.randf() < 0.55:
		idx = 2
	var lane := order[idx]
	if is_cluster:
		lane = "upper" if _rng.randf() < 0.5 else "middle"
	# 禁止连续三次同 lane
	if recent.size() >= 2 and String(recent[recent.size() - 1]) == lane and String(recent[recent.size() - 2]) == lane:
		idx = (idx + 1) % order.size()
		lane = order[idx]
		if is_cluster and lane == "lower":
			lane = "middle"
	# 同屏 lane 上限
	var tries := 0
	while _count_lane_active(lane) >= int(TitleEffectCatalog.DRIFT_CONFIG["max_lane_active"]) and tries < 3:
		idx = (idx + 1) % order.size()
		lane = order[idx]
		if is_cluster and lane == "lower":
			lane = "upper"
		tries += 1
	_state["lane_index"] = (idx + 1) % order.size()
	recent.append(lane)
	if recent.size() > 8:
		recent = recent.slice(recent.size() - 8, recent.size())
	_state["recent_lanes"] = recent
	return lane


func _pick_scale(cfg: Dictionary) -> float:
	var D := TitleEffectCatalog.DRIFT_CONFIG
	var recent: Array = _state["recent_scales"]
	var scale_mul := _rng.randf_range(float(cfg["scale_min"]), float(cfg["scale_max"]))
	for _i in 6:
		var ok := true
		if recent.size() >= 2:
			var a := float(recent[recent.size() - 1])
			var b := float(recent[recent.size() - 2])
			if absf(scale_mul - a) < float(D["min_scale_gap"]) and absf(scale_mul - b) < float(D["min_scale_gap"]):
				ok = false
		if ok:
			break
		scale_mul = _rng.randf_range(float(cfg["scale_min"]), float(cfg["scale_max"]))
	recent.append(scale_mul)
	if recent.size() > 8:
		recent = recent.slice(recent.size() - 8, recent.size())
	_state["recent_scales"] = recent
	return scale_mul


func _spawn_drift_item(kind: String, is_cluster: bool) -> void:
	var D := TitleEffectCatalog.DRIFT_CONFIG
	if not is_cluster and _count_active_normal_drifts() >= int(D["max_normal_visible"]):
		return
	if is_cluster:
		for item in _drift_pool:
			if String(item["kind"]) == "petal_cluster" and float(item["life"]) >= 0.0:
				return

	var slot: Dictionary = {}
	var found := false
	for item in _drift_pool:
		if String(item["kind"]) == kind and float(item["life"]) < 0.0:
			slot = item
			found = true
			break
	if not found:
		return

	var cfg: Dictionary = TitleEffectCatalog.DRIFT_POOL[kind]
	var scale_mul := _pick_scale(cfg)
	var lane := _pick_lane(is_cluster, scale_mul)
	var lane_cfg: Dictionary = TitleEffectCatalog.DRIFT_LANES[lane]

	var start := Vector2.ZERO
	var end := Vector2.ZERO
	var c1 := Vector2.ZERO
	var c2 := Vector2.ZERO
	var ok := false
	for attempt in int(D["spawn_retry"]):
		var zone_name := _pick_zone()
		# 连续过近则换区
		if attempt > 0:
			zone_name = TitleEffectCatalog.DRIFT_SPAWN_ZONE_ORDER[
				(TitleEffectCatalog.DRIFT_SPAWN_ZONE_ORDER.find(zone_name) + attempt) % 3
			]
		var zone: Dictionary = TitleEffectCatalog.DRIFT_SPAWN_ZONES[zone_name]
		var center: Vector2 = zone["center"]
		var jitter: Vector2 = zone["jitter"]
		start = center + Vector2(_rng.randf_range(-jitter.x, jitter.x), _rng.randf_range(-jitter.y, jitter.y))
		end = Vector2(
			_rng.randf_range(float(lane_cfg["end_x_min"]), float(lane_cfg["end_x_max"])),
			_rng.randf_range(float(lane_cfg["end_y_min"]), float(lane_cfg["end_y_max"]))
		)
		c1 = start + Vector2(
			_rng.randf_range(float(lane_cfg["c1_x_min"]), float(lane_cfg["c1_x_max"])),
			_rng.randf_range(float(lane_cfg["c1_y_min"]), float(lane_cfg["c1_y_max"]))
		)
		c2 = end + Vector2(
			_rng.randf_range(float(lane_cfg["c2_x_min"]), float(lane_cfg["c2_x_max"])),
			_rng.randf_range(float(lane_cfg["c2_y_min"]), float(lane_cfg["c2_y_max"]))
		)
		var last_spawn: Vector2 = _state["last_spawn_pos"]
		var last_end: Vector2 = _state["last_end_pos"]
		if start.distance_to(last_spawn) < float(D["min_spawn_sep"]) and attempt < int(D["spawn_retry"]) - 1:
			continue
		if end.distance_to(last_end) < float(D["min_end_sep"]) and attempt < int(D["spawn_retry"]) - 1:
			# 换 lane 再试
			lane = _pick_lane(is_cluster, scale_mul)
			lane_cfg = TitleEffectCatalog.DRIFT_LANES[lane]
			continue
		ok = true
		break

	if not ok:
		# 最后一次结果也接受，但延后半拍避免团块
		var q: Array = _state["gust_queue"]
		q.insert(0, {
			"at": _time + _rng.randf_range(float(D["near_delay_min"]), float(D["near_delay_max"])),
			"kind": kind,
			"is_cluster": is_cluster,
		})
		_state["gust_queue"] = q
		return

	if start.distance_to(_state["last_spawn_pos"] as Vector2) < float(D["min_spawn_sep"]):
		var q2: Array = _state["gust_queue"]
		q2.insert(0, {
			"at": _time + _rng.randf_range(float(D["near_delay_min"]), float(D["near_delay_max"])),
			"kind": kind,
			"is_cluster": is_cluster,
		})
		_state["gust_queue"] = q2
		return

	var dur := _rng.randf_range(float(lane_cfg["duration_min"]), float(lane_cfg["duration_max"]))
	var spin_dir := 1.0 if _rng.randf() > 0.5 else -1.0
	var spin := _rng.randf_range(float(cfg["spin_min"]), float(cfg["spin_max"])) * spin_dir
	var flips := _rng.randi_range(int(cfg["flip_min"]), int(cfg["flip_max"]))
	var alpha_peak := float(cfg["alpha_peak"])
	var sway := _rng.randf_range(float(lane_cfg["sway_min"]), float(lane_cfg["sway_max"]))
	var bob_amp := _rng.randf_range(float(D["bob_amp_min"]), float(D["bob_amp_max"]))
	var bob_cycles := _rng.randf_range(float(D["bob_cycles_min"]), float(D["bob_cycles_max"]))
	var fade_start := _rng.randf_range(float(D["fade_start_min"]), float(D["fade_start_max"]))
	var flip_phase0 := _rng.randf() * TAU
	var base_size: Vector2 = cfg["display_size"] * scale_mul

	slot["life"] = 0.0
	slot["dur"] = dur
	slot["lane"] = lane
	slot["p0"] = start
	slot["p1"] = c1
	slot["p2"] = c2
	slot["p3"] = end
	slot["spin"] = spin
	slot["flips"] = flips
	slot["flip_phase0"] = flip_phase0
	slot["sway"] = sway
	slot["base_angle"] = float(cfg["base_angle"])
	slot["base_size"] = base_size
	slot["scale_mul"] = scale_mul
	slot["alpha_peak"] = alpha_peak
	slot["bob"] = bob_amp
	slot["bob_cycles"] = bob_cycles
	slot["fade_start"] = fade_start

	_state["last_spawn_pos"] = start
	_state["last_end_pos"] = end
	var log: Array = _state["drift_spawn_log"]
	log.append({
		"kind": kind,
		"lane": lane,
		"start": start,
		"end": end,
		"duration": dur,
		"scale_mul": scale_mul,
		"distance": start.distance_to(end),
	})
	if log.size() > 48:
		log = log.slice(log.size() - 48, log.size())
	_state["drift_spawn_log"] = log


func _bezier(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, u: float) -> Vector2:
	var t := clampf(u, 0.0, 1.0)
	var omt := 1.0 - t
	return (
		p0 * (omt * omt * omt)
		+ p1 * (3.0 * omt * omt * t)
		+ p2 * (3.0 * omt * t * t)
		+ p3 * (t * t * t)
	)


func _bezier_tangent(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, u: float) -> Vector2:
	var t := clampf(u, 0.0, 1.0)
	var omt := 1.0 - t
	return (
		(p1 - p0) * (3.0 * omt * omt)
		+ (p2 - p1) * (6.0 * omt * t)
		+ (p3 - p2) * (3.0 * t * t)
	)


func _tick_drift_lives(delta: float) -> void:
	for item in _drift_pool:
		if float(item["life"]) < 0.0:
			(item["sprite"] as TextureRect).visible = false
			(item["root"] as Control).visible = false
			continue
		item["life"] = float(item["life"]) + delta
		var u := clampf(float(item["life"]) / float(item["dur"]), 0.0, 1.0)
		var pos := _bezier(item["p0"], item["p1"], item["p2"], item["p3"], u)
		pos.x += float(item["sway"]) * sin(u * TAU * 1.35)
		pos.y += float(item["bob"]) * sin(u * TAU * float(item.get("bob_cycles", 2.0)))
		var spr: TextureRect = item["sprite"]
		var root: Control = item["root"]
		var size: Vector2 = item["base_size"]
		spr.size = size
		spr.pivot_offset = size * 0.5
		var flip_phase := float(item.get("flip_phase0", 0.0)) + u * PI * float(item["flips"])
		var sx := cos(flip_phase)
		var sign_x := 1.0 if sx >= 0.0 else -1.0
		sx = sign_x * maxf(absf(sx), TitleEffectCatalog.DRIFT_FLIP_SCALE_MIN)
		spr.scale = Vector2(sx, 1.0)
		spr.rotation_degrees = float(item["base_angle"]) + float(item["spin"]) * u
		root.position = pos - size * 0.5
		root.visible = true
		spr.visible = true
		var alpha := float(item["alpha_peak"])
		var fade_start: float = float(item.get("fade_start", 0.65))
		if u < 0.10:
			alpha *= u / 0.10
		elif u > fade_start:
			alpha *= (1.0 - u) / maxf(1.0 - fade_start, 0.05)
		spr.modulate.a = clampf(alpha, 0.0, 1.0)
		if u >= 1.0:
			item["life"] = -1.0
			spr.visible = false
			root.visible = false


# ---------- Smoke: A/B bottom-up ----------

func _update_smokes() -> void:
	for slot in _smoke_slots:
		_tick_smoke_slot(slot)


func _tick_smoke_slot(slot: Dictionary) -> void:
	var chimney: String = slot["chimney"]
	var cfg: Dictionary = TitleEffectCatalog.SMOKE_CONFIGS[chimney]
	var wrap: Control = slot["wrap"]
	var spr: TextureRect = slot["sprite"]
	var cycle: float = float(_state["%s_cycle" % chimney])
	var rise_amp: float = float(_state["%s_rise" % chimney])
	var u := fposmod(_time / cycle + float(slot["phase"]), 1.0)
	var rect: Rect2 = cfg["rect"]
	var sc := lerpf(float(cfg["scale_min"]), float(cfg["scale_max"]), u)
	var full_w := rect.size.x * sc
	var full_h := rect.size.y * sc
	var reveal := 1.0
	if u < 0.28:
		reveal = u / 0.28
	var rise := rise_amp * u
	var sway := float(cfg["sway_px"]) * sin(u * TAU + float(slot["phase"]) * TAU)
	# 烟囱口 = PXD rect 底边中心
	var mouth := Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y)
	var vis_h := full_h * reveal
	wrap.size = Vector2(full_w, maxf(vis_h, 0.5))
	wrap.position = Vector2(mouth.x - full_w * 0.5 + sway, mouth.y - rise - wrap.size.y)
	wrap.clip_contents = true
	spr.size = Vector2(full_w, full_h)
	spr.position = Vector2(0.0, wrap.size.y - full_h)
	spr.scale = Vector2.ONE
	spr.rotation = 0.0
	if spr.material is ShaderMaterial:
		(spr.material as ShaderMaterial).set_shader_parameter("reveal_progress", reveal)

	var peak: float = float(cfg["alpha_peak"])
	var alpha := 0.0
	if u < 0.28:
		alpha = peak * (u / 0.28)
	elif u < 0.55:
		alpha = peak
	else:
		alpha = peak * (1.0 - (u - 0.55) / 0.45)
	# 顶部先稀薄：后段再压一点
	if u > 0.70:
		alpha *= 1.0 - (u - 0.70) / 0.30 * 0.35
	spr.modulate.a = clampf(alpha, 0.0, 1.0)
	wrap.visible = alpha > 0.02
	spr.visible = wrap.visible
