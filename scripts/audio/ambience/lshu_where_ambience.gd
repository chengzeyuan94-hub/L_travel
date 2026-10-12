extends Node
## 第四幕「L叔在哪儿」环境声（方案 §3.8）。lshu_main.gd 拿到 Director 后调 attach(stage, director)，挂成舞台的子节点。
## 只读舞台和导演的状态、只连它们的信号，不改它们：
## - 地形：舞台上那块地的地形标签（pool.json postcard_terrain；没写的按 postcard_lines.json terrain_resolve 推），
##   几个标签按权重在功率上平均（共用的底床不叠成两份），再按各底床文件的响度（bed_lufs）把整组拉到 bed_target_lufs，
##   所以不管地块有几个标签、是哪种地形，底床听起来一样响；terrain.gain_db 是在这之上的地形微调。外加各标签的随机点缀
## - 换地：switch_started 起按 xfade_s 做等功率交叉（功率线性插值），switch_finished 时还没做完就在 finish_s 内收尾；
##   其它换地（开场、硬同步、开发键 F3 / F4 预览）等导演空闲后按 resync_s 交叉。交叉期间不放随机点缀
## - 夜晚权重 look.weight("night")：鸟（底床和零星鸟叫）× (1 − night)；鸟没了的那部分响度由其余底床补回 night_comp
##   （上限 night_comp_max_db），夜里整体只差 duck 那几 dB，草地块不会比岩石块静一截
## - 篝火：舞台地块 life.fire_level（导演每帧 set_fire_level 设的），音量 = fire.db + 20·log10(level)，地块没火就没声
## - 事件：night_start / tent_in（打盹、进帐篷）起所有底床在 duck.fade_s 内压 duck.db，night_end 放开并叫一声晨鸟；
##   greeted（点到他鞠躬 / 点头）叮一声；snap_finished 拍照成功再叮一声（高音）
## 所有淡变都按真实时间（_process 的 delta），不跟 L叔 的加速时钟走，60 倍速预览里听起来和 1 倍速一样。
## 参数在 data/audio/ambience/lshu_where.json。无界面 / 测试 / 驱动脚本下 attach 什么都不建、不读（Amb.allowed()）。
## --lshu-dev 时每次换混音、压低 / 放开、事件点缀打一行 LSHU_AMB。

const Amb := preload("res://scripts/audio/ambience/amb_kit.gd")
const SELF_PATH := "res://scripts/audio/ambience/lshu_where_ambience.gd"
const MIX := "lshu_where"
const CONTEXT_PATH := "res://scripts/traveler/lshu/loop/lshu_postcard_context.gd"
const TEXT_PATH := "res://scripts/traveler/lshu/loop/lshu_postcard_text.gd"
const LINES_PATH := "res://data/traveler/lshu/postcard_lines.json"
const NIGHT_ACTIONS: Array[String] = ["doze", "tent_in", "doze_on"]

var stage: Node
var director: Node

var m: Dictionary = {}
var dev := false
var master_db := 0.0
var oneshot_db := 0.0
var fade_in_s := 3.0
var xfade_s := 2.5
var finish_s := 0.6
var resync_s := 2.0
var follow_s := 0.15
var duck_db := -4.0
var duck_fade_s := 3.0

var beds: Dictionary = {}           # 底床声音名 -> Amb.Layer
var fire: AudioStreamPlayer
var scatters: Dictionary = {}       # 点缀 id -> Amb.Scatter
var segments: Dictionary = {}       # 点缀 id -> {layer, left, hold}（从循环里截一段）
var ev_players: Dictionary = {}     # 事件名 -> Amb.Scatter（只手动 fire）
var night_beds: Array = []
var night_scatters: Array = []
var scatter_off_above := 0.85
var night_comp := 1.0
var night_comp_max_db := 6.0

var _running := false
var _age := 0.0
var _from: Dictionary = {}          # 底床 -> 功率（交叉起点）
var _to: Dictionary = {}            # 底床 -> 功率（交叉终点）
var _p := 1.0
var _xf_len := 1.0
var _mix_tile := ""
var _mix_tags: Array = []
var _mix_scatter: Dictionary = {}   # 点缀 id -> 归一权重
var _active: Dictionary = {}        # 点缀 id -> 该地块开着
var _pending := ""
var _pending_age := 0.0
var _night_state := false
var _duck := 0.0
var _motion: Object
var _tags: Dictionary = {}
var _lib: Dictionary = {}
var _pool_by_id: Dictionary = {}
var _ctx_script: GDScript
var _text_script: GDScript


## 挂点：lshu_main.gd 拿到 Director 以后调一次。不允许出声时什么都不建，返回 null。
static func attach(stage_node: Node, director_node: Node) -> Node:
	if not Amb.allowed() or stage_node == null or director_node == null:
		return null
	var n: Node = (load(SELF_PATH) as GDScript).new()
	n.set("stage", stage_node)
	n.set("director", director_node)
	stage_node.add_child(n)
	return n


func _ready() -> void:
	if not Amb.allowed() or not is_instance_valid(stage) or not is_instance_valid(director):
		set_process(false)
		queue_free()
		return
	m = Amb.mix(MIX)
	var terrains: Dictionary = _dict(m, "terrains")
	if terrains.is_empty():
		set_process(false)
		queue_free()
		return
	name = "AmbLshuWhere"
	var args: PackedStringArray = stage.call("user_args") if stage.has_method("user_args") else preload("res://scripts/traveler/traveler_launch.gd").user_args()
	dev = args.has("--lshu-dev")
	master_db = float(m.get("master_db", master_db))
	oneshot_db = float(m.get("oneshot_db", oneshot_db))
	fade_in_s = maxf(0.05, float(m.get("fade_in_s", fade_in_s)))
	xfade_s = maxf(0.05, float(m.get("xfade_s", xfade_s)))
	finish_s = maxf(0.05, float(m.get("finish_s", finish_s)))
	resync_s = maxf(0.05, float(m.get("resync_s", resync_s)))
	follow_s = maxf(0.02, float(m.get("follow_s", follow_s)))
	var dk: Dictionary = _dict(m, "duck")
	duck_db = float(dk.get("db", duck_db))
	duck_fade_s = maxf(0.05, float(dk.get("fade_s", duck_fade_s)))
	var nm: Dictionary = _dict(m, "night_mute")
	night_beds = nm.get("beds", []) as Array
	night_scatters = nm.get("scatters", []) as Array
	scatter_off_above = float(nm.get("scatter_off_above", scatter_off_above))
	night_comp = clampf(float(nm.get("comp", night_comp)), 0.0, 1.0)
	night_comp_max_db = maxf(0.0, float(nm.get("comp_max_db", night_comp_max_db)))

	# 底床：任何地形用到的每条循环一个 Layer，混音要它时才开始播
	for t: Variant in terrains.values():
		for s: Variant in _dict(t, "beds").keys():
			if not beds.has(str(s)):
				var layer: AudioStreamPlayer = Amb.Layer.new().setup(str(s))
				add_child(layer)
				beds[str(s)] = layer
	fire = Amb.Layer.new().setup(str(_dict(m, "fire").get("sound", "campfire_bed_loop_v1")))
	add_child(fire)
	# 点缀：随机一次性（Scatter，开关跟地形走）和循环截段（segment）
	var sc_cfg: Dictionary = _dict(m, "scatters")
	for id: Variant in sc_cfg.keys():
		var c: Dictionary = _dict(sc_cfg, str(id))
		if c.has("segment"):
			var seg: AudioStreamPlayer = Amb.Layer.new().setup(str(c.segment))
			add_child(seg)
			segments[str(id)] = {"layer": seg, "left": 0.0, "hold": 0.0}
		else:
			var sc: Node = Amb.Scatter.new().setup(c.get("sounds", []) as Array, _vec2(c, "interval_s", Vector2(20, 40)),
				_vec2(c, "volume_db", Vector2(-14, -14)), _vec2(c, "pitch", Vector2(0.95, 1.05)), 1e9)
			sc.name = "AmbScatter_" + str(id)
			sc.set("enabled", false)
			add_child(sc)
			scatters[str(id)] = sc
	# 事件一次性：不自己计时，只在事件到时 fire()
	var ev_cfg: Dictionary = _dict(m, "events")
	for ev: Variant in ev_cfg.keys():
		var c2: Dictionary = _dict(ev_cfg, str(ev))
		var db: float = float(c2.get("volume_db", -14.0))
		var one: Node = Amb.Scatter.new().setup([str(c2.get("sound", "bell_small_ding_v1"))], Vector2(1e9, 1e9), Vector2(db, db), Vector2.ONE, 1e9)
		one.name = "AmbEvent_" + str(ev)
		one.set("enabled", false)
		add_child(one)
		ev_players[str(ev)] = one

	_hook(director, "switch_started", _on_switch_started)
	_hook(director, "switch_finished", _on_switch_finished)
	_hook(director, "event_handled", _on_event)
	_hook(director, "ticked", _on_ticked)
	_hook(director, "snap_finished", _on_snap)


func _exit_tree() -> void:
	set_process(false)
	_running = false
	if is_instance_valid(director):
		for pair: Array in [["switch_started", _on_switch_started], ["switch_finished", _on_switch_finished],
				["event_handled", _on_event], ["ticked", _on_ticked], ["snap_finished", _on_snap]]:
			if director.is_connected(str(pair[0]), pair[1]):
				director.disconnect(str(pair[0]), pair[1])
	if _motion != null and is_instance_valid(_motion) and _motion.is_connected("greeted", _on_greeted):
		_motion.disconnect("greeted", _on_greeted)
	_motion = null
	Amb.release(self)


func _process(delta: float) -> void:
	if not is_instance_valid(stage) or not is_instance_valid(director):
		return
	if not _running:
		# 开场：导演把第一块地硬同步好、盖板揭开后（started）再淡入
		if not bool(director.get("started")):
			return
		_running = true
		_retarget(str(stage.get("tile_id")), 0.0, "start")
	_age += delta
	_hook_motion()
	var dir_switching: bool = bool(director.get("switching"))
	if _pending != "":
		_pending_age += delta
		_try_pending(xfade_s)
	elif not dir_switching:
		# 不经过 switch 信号的换地（开场、硬同步、开发键预览）：导演空闲后跟上舞台
		var tid: String = str(stage.get("tile_id"))
		if tid != "" and tid != _mix_tile:
			_retarget(tid, resync_s, "resync")
	if _p < 1.0:
		_p = minf(1.0, _p + delta / maxf(_xf_len, 0.01))
		if _p >= 1.0:
			_apply_scatters()
	var night: float = _night()
	var goal: float = duck_db if _night_state else 0.0
	_duck = move_toward(_duck, goal, absf(duck_db) / duck_fade_s * delta)
	var fade: float = clampf(_age / fade_in_s, 0.0, 1.0)
	var common: float = master_db + _duck + Amb.amp_to_db(fade)
	var bird_db: float = Amb.amp_to_db(1.0 - night)
	var bird_pow: float = (1.0 - night) * (1.0 - night)
	# 鸟随夜晚权重退掉的响度，由其余底床补回 night_comp（按文件响度算，不补鸟本身）
	var pw_now: Dictionary = {}
	var loud_day := 0.0
	var loud_now := 0.0
	for s: String in beds:
		var pw: float = lerpf(float(_from.get(s, 0.0)), float(_to.get(s, 0.0)), _p)
		pw_now[s] = pw
		var lw: float = pw * _bed_loud(s)
		loud_day += lw
		loud_now += lw * (bird_pow if night_beds.has(s) else 1.0)
	var comp: float = 0.0
	if night_comp > 0.0 and loud_now > 1e-12 and loud_day > loud_now:
		comp = minf(10.0 * log(loud_day / loud_now) / log(10.0), night_comp_max_db) * night_comp
	for s: String in beds:
		var pw2: float = float(pw_now[s])
		var db: float = -80.0
		if pw2 > 1e-8:
			db = 10.0 * log(pw2) / log(10.0) + common
			db += bird_db if night_beds.has(s) else comp
		_level(beds[s], db, follow_s)
	_level(fire, _fire_db(common), float(_dict(m, "fire").get("follow_s", 1.2)))
	for id: String in scatters:
		var sc: Node = scatters[id]
		var on: bool = bool(_active.get(id, false)) and _p >= 1.0
		var g: float = master_db + oneshot_db
		if night_scatters.has(id):
			g += bird_db
			on = on and night < scatter_off_above
		sc.set("enabled", on)
		sc.set("gain_db", g)
	_segments(delta)


# ------------------------------------------------------------------ drivers

## 夜晚权重（0 白天，1 夜里）；读不到就当白天
func _night() -> float:
	var look: Variant = stage.get("look")
	if look is Object and is_instance_valid(look) and (look as Object).has_method("weight"):
		return clampf(float((look as Object).call("weight", "night")), 0.0, 1.0)
	return 0.0


## 舞台地块的篝火：db + 20·log10(fire_level)；只有别的火点时用 effect_only_db；没有火 -80
func _fire_db(common: float) -> float:
	var f: Dictionary = _dict(m, "fire")
	var tile: Variant = stage.get("tile")
	if not (tile is Node) or not is_instance_valid(tile):
		return -80.0
	var life: Variant = (tile as Node).get("life")
	if not (life is Node) or not is_instance_valid(life):
		return -80.0
	var camp := false
	var other := false
	var fl: Variant = (life as Node).get("fires")
	if not (fl is Array):
		return -80.0
	for rec: Variant in fl as Array:
		if rec is Dictionary:
			if bool((rec as Dictionary).get("effect", false)):
				other = true
			else:
				camp = true
	if not camp and not other:
		return -80.0
	var level: float = clampf(float((life as Node).get("fire_level")), 0.0, 1.0)
	if level < float(f.get("min_level", 0.02)):
		return -80.0
	var base: float = float(f.get("db", -2.0)) if camp else float(f.get("effect_only_db", -8.0))
	return base + Amb.amp_to_db(level) + common


# ------------------------------------------------------------------ mix per tile

## 换到 id 这块地的混音：从当前听到的功率起，sec 秒（真实时间）做完；sec = 0 立刻到位
func _retarget(id: String, sec: float, why: String) -> void:
	var now: Dictionary = {}
	for s: String in beds:
		now[s] = lerpf(float(_from.get(s, 0.0)), float(_to.get(s, 0.0)), _p)
	_from = now
	_mix_tile = id
	var mix: Dictionary = _mix_for(id)
	_to = mix.beds
	_mix_scatter = mix.scatters
	_mix_tags = mix.tags
	_stop_scatters()
	if sec <= 0.0:
		_p = 1.0
		_apply_scatters()
	else:
		_p = 0.0
		_xf_len = sec
	_log("mix", {"why": why, "tile": id, "tags": _mix_tags, "sec": sec, "beds": _dbs(_to), "scatters": _mix_scatter})


## 导演开始换地：新地块造好（staged）就开始交叉；还没造好先等着，最多等到 switch_finished
func _on_switch_started(info: Dictionary) -> void:
	if not _running:
		return
	_pending = str(info.get("tile", ""))
	_pending_age = 0.0
	_try_pending(xfade_s)


func _try_pending(sec: float) -> void:
	if _pending == "":
		return
	if _tile_data(_pending).is_empty() and _pending_age < 8.0:
		return
	var id: String = _pending
	_pending = ""
	if id != _mix_tile:
		_retarget(id, sec, "switch")


func _on_switch_finished(_info: Dictionary) -> void:
	if not _running:
		return
	if _pending != "":
		_pending_age = 1e9
		_try_pending(finish_s)
	# 交叉还没做完：剩下的在 finish_s 内收尾
	if _p < 1.0 and (1.0 - _p) * _xf_len > finish_s:
		_xf_len = finish_s / (1.0 - _p)
	_log("switch_finished", {"tile": str(stage.get("tile_id")), "p": snappedf(_p, 0.01)})


## 一块地的地形混音：{beds: {声音: 功率}, scatters: {id: 权重}, tags}
func _mix_for(id: String) -> Dictionary:
	var terrains: Dictionary = _dict(m, "terrains")
	var aliases: Dictionary = _dict(m, "aliases")
	var ws: Dictionary = {}
	for t: Variant in _tags_for(id):
		var k: String = str(aliases.get(str(t), str(t)))
		if terrains.has(k):
			ws[k] = maxf(0.0, float(_dict(terrains, k).get("weight", 1.0)))
	var total := 0.0
	for k: String in ws:
		total += float(ws[k])
	if total <= 0.0:
		ws = {str(m.get("fallback_terrain", "grass")): 1.0}
		total = 1.0
	var b: Dictionary = {}
	var s: Dictionary = {}
	var gain := 0.0
	for k: String in ws:
		var tc: Dictionary = _dict(terrains, k)
		var w: float = float(ws[k]) / total
		gain += w * float(tc.get("gain_db", 0.0))
		for bed: Variant in _dict(tc, "beds").keys():
			b[str(bed)] = float(b.get(str(bed), 0.0)) + w * pow(10.0, float(_dict(tc, "beds")[bed]) / 10.0)
		for sid: Variant in tc.get("scatters", []) as Array:
			s[str(sid)] = float(s.get(str(sid), 0.0)) + w
	# 按文件响度把整组底床拉到 bed_target_lufs（再加地形 gain_db 的加权平均）
	var loud := 0.0
	for bed: String in b:
		loud += float(b[bed]) * _bed_loud(bed)
	if loud > 1e-12 and m.has("bed_target_lufs"):
		var k2: float = pow(10.0, (float(m.bed_target_lufs) + gain) / 10.0) / loud
		for bed: String in b:
			b[bed] = float(b[bed]) * k2
	return {"beds": b, "scatters": s, "tags": ws.keys()}


## 一条底床在 0 dB 时实听的响度（功率）；表里没有就按 −30 LUFS
func _bed_loud(bed: String) -> float:
	return pow(10.0, float(_dict(m, "bed_lufs").get(bed, -30.0)) / 10.0)


## 地形标签：和明信片文案同一套规则（LshuPostcardText.terrain_tags），输入取已经在内存里的地块数据，不另外读盘
func _tags_for(id: String) -> Array:
	if _tags.has(id):
		return _tags[id]
	if _ctx_script == null:
		_ctx_script = load(CONTEXT_PATH) as GDScript
		_text_script = load(TEXT_PATH) as GDScript
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LINES_PATH)) if FileAccess.file_exists(LINES_PATH) else null
		_lib = parsed if parsed is Dictionary else {}
		var pool: Variant = stage.get("pool")
		if pool is Dictionary:
			for t: Variant in (pool as Dictionary).get("tiles", []) as Array:
				if t is Dictionary:
					_pool_by_id[str((t as Dictionary).get("id", ""))] = t
	var tags: Array = []
	if _ctx_script != null and _text_script != null:
		var td: Dictionary = _tile_data(id)
		var ctx: Dictionary = {}
		if td.is_empty():
			ctx = _ctx_script.call("for_leg", {"tile": id}, "day", -1, _lib)
		else:
			var place: Dictionary = td.get("place", {}) if td.get("place") is Dictionary else {}
			var entry: Dictionary = _pool_by_id.get(id, {})
			var city_id: String = _first([entry.get("city_id")])
			if city_id == "":
				var city_name: String = _first([entry.get("city"), place.get("city")])
				if city_name != "":
					city_id = str(_ctx_script.call("city_id_for_name", city_name, _lib))
			ctx = {"biome": _first([place.get("theme")]), "landform": _first([entry.get("landform"), place.get("landform")]), "city_id": city_id}
			var pt: Variant = entry.get("postcard_terrain")
			if (pt is Array and not (pt as Array).is_empty()) or (pt is String and pt != ""):
				ctx["postcard_terrain"] = pt
		var out: Variant = _text_script.call("terrain_tags", _lib, ctx)
		if out is Array:
			tags = out
	# 只缓存读到了地块数据的结果
	if not _tile_data(id).is_empty():
		_tags[id] = tags
	return tags


## 舞台上已经在内存里的地块数据（正在显示的，或导演预先造好的 staged）
func _tile_data(id: String) -> Dictionary:
	for key: String in ["tile", "staged"]:
		var n: Variant = stage.get(key)
		if n is Node and is_instance_valid(n) and str((n as Node).get("tile_id")) == id:
			var td: Variant = (n as Node).get("tile")
			if td is Dictionary and not (td as Dictionary).is_empty():
				return td
	return {}


# ------------------------------------------------------------------ scatters

func _stop_scatters() -> void:
	for id: String in scatters:
		_active[id] = false
		(scatters[id] as Node).set("enabled", false)
	for id: String in segments:
		var sg: Dictionary = segments[id]
		if float(sg.hold) > 0.0:
			_level(sg.layer, -80.0, float(_dict(_dict(m, "scatters"), id).get("fade_out_s", 2.0)))
		sg["hold"] = 0.0
		_active[id] = false


## 交叉做完后按新地块开点缀：间隔 × (1 / 权重)^exp，第一次在间隔的一部分之后
func _apply_scatters() -> void:
	var exp_w: float = float(m.get("scatter_interval_exp", 0.5))
	var fd: Vector2 = _vec2(m, "scatter_first_delay", Vector2(0.3, 0.6))
	var sc_cfg: Dictionary = _dict(m, "scatters")
	for id: String in scatters:
		var w: float = float(_mix_scatter.get(id, 0.0))
		var sc: Node = scatters[id]
		_active[id] = w > 0.0
		if w > 0.0:
			var iv: Vector2 = _vec2(_dict(sc_cfg, id), "interval_s", Vector2(20, 40)) * pow(1.0 / w, exp_w)
			sc.set("interval", iv)
			sc.set("_left", randf_range(iv.x * fd.x, iv.y * fd.y))
	for id: String in segments:
		var w2: float = float(_mix_scatter.get(id, 0.0))
		_active[id] = w2 > 0.0
		var sg: Dictionary = segments[id]
		sg["mult"] = pow(1.0 / w2, exp_w) if w2 > 0.0 else 1.0
		var iv2: Vector2 = _vec2(_dict(sc_cfg, id), "interval_s", Vector2(40, 80)) * float(sg.mult)
		sg["left"] = randf_range(iv2.x * fd.x, iv2.y * fd.y)
		sg["hold"] = 0.0


## 循环截段：到点从随机位置淡入，播 length_s 后淡出（Layer 淡到无声自己停）
func _segments(delta: float) -> void:
	var sc_cfg: Dictionary = _dict(m, "scatters")
	for id: String in segments:
		var sg: Dictionary = segments[id]
		var c: Dictionary = _dict(sc_cfg, id)
		if float(sg.hold) > 0.0:
			sg["hold"] = float(sg.hold) - delta
			if float(sg.hold) <= 0.0:
				_level(sg.layer, -80.0, float(c.get("fade_out_s", 2.0)))
			continue
		if not bool(_active.get(id, false)) or _p < 1.0:
			continue
		sg["left"] = float(sg.left) - delta
		if float(sg.left) > 0.0:
			continue
		var iv: Vector2 = _vec2(c, "interval_s", Vector2(40, 80)) * float(sg.get("mult", 1.0))
		sg["left"] = randf_range(iv.x, iv.y)
		sg["hold"] = float(c.get("length_s", 8.0))
		_level(sg.layer, float(c.get("volume_db", -14.0)) + master_db + oneshot_db, float(c.get("fade_in_s", 1.5)))
		_log("segment", {"id": id})


# ------------------------------------------------------------------ events

func _on_ticked(r: Dictionary) -> void:
	var night: bool = str(r.get("substate", "")) == "NIGHT"
	if night != _night_state:
		_night_state = night
		_log("duck", {"on": night, "via": "substate", "phase": str(r.get("night_phase", ""))})


func _on_event(e: Dictionary, info: Dictionary) -> void:
	if not _running:
		return
	var type: String = str(e.get("type", ""))
	var action: String = str(info.get("action", ""))
	if (type == "night_start" or type == "tent_in") and NIGHT_ACTIONS.has(action):
		if not _night_state:
			_log("duck", {"on": true, "via": type})
		_night_state = true
	elif type == "night_end" and action == "night_end":
		if _night_state:
			_log("duck", {"on": false, "via": type})
		_night_state = false
		_fire_event("night_end")


func _on_greeted(_kind: String, _t: float) -> void:
	if _running:
		_fire_event("greeted")


func _on_snap(res: Dictionary) -> void:
	if _running and bool(res.get("ok", false)):
		_fire_event("snap")


func _fire_event(ev: String) -> void:
	var one: Node = ev_players.get(ev) as Node
	if one == null or not is_instance_valid(one):
		return
	one.set("gain_db", master_db + oneshot_db)
	one.call("fire", 0.0, float(_dict(_dict(m, "events"), ev).get("pitch", 1.0)))
	_log("event", {"ev": ev})


## 导演的动作模块在 start() 里才建：建好后连它的 greeted
func _hook_motion() -> void:
	if _motion != null and is_instance_valid(_motion):
		return
	var mo: Variant = director.get("motion")
	if mo is Object and is_instance_valid(mo) and (mo as Object).has_signal("greeted"):
		_motion = mo
		if not _motion.is_connected("greeted", _on_greeted):
			_motion.connect("greeted", _on_greeted)


# ------------------------------------------------------------------ helpers

func _level(layer: Variant, db: float, sec: float) -> void:
	if layer is Node and is_instance_valid(layer):
		(layer as Node).call("set_level", db if db > -79.0 else -80.0, sec)


static func _hook(obj: Object, sig: String, c: Callable) -> void:
	if obj != null and obj.has_signal(sig) and not obj.is_connected(sig, c):
		obj.connect(sig, c)


static func _dict(d: Variant, key: String) -> Dictionary:
	if d is Dictionary:
		var v: Variant = (d as Dictionary).get(key)
		if v is Dictionary:
			return v
	return {}


static func _vec2(d: Dictionary, key: String, fallback: Vector2) -> Vector2:
	var v: Variant = d.get(key)
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return fallback


static func _first(vals: Array) -> String:
	for v: Variant in vals:
		if v != null and str(v) != "" and str(v) != "<null>":
			return str(v)
	return ""


static func _dbs(powers: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k: Variant in powers:
		out[k] = snappedf(10.0 * log(maxf(float(powers[k]), 1e-12)) / log(10.0), 0.1)
	return out


func _log(kind: String, data: Dictionary) -> void:
	if dev:
		data["frame"] = Engine.get_process_frames()
		data["real_s"] = snappedf(float(Time.get_ticks_msec()) / 1000.0, 0.01)
		print("LSHU_AMB ", kind, " ", JSON.stringify(data))
