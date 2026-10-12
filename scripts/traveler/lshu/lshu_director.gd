extends Node
## 第四幕「L叔在哪儿」· the director: the loop clock (loop/) driving the P0 stage (lshu_main.gd), L叔's motion
## (lshu_actor_motion.gd), the night lamp, the postcard camera and the UI (ui/). Node "Director" of
## scenes/traveler/lshu_main.tscn; the stage calls boot() / opening() / start() (lshu_main.gd decides when the director
## runs). Recommended defaults while Carlos has not decided: Travel-Frog loop (clicking him = a bow and a photo, no
## find-game), 30-60 min per stop, the tile on the table, a camp lantern near him at night; home = pool.json home.
##
## Clock: every 2 s (loop.json save.resolve_every_s) LshuClock.resolve(save, now, places, cfg); the time is always the
## system clock (scaled with --lshu-clock-scale, started at --lshu-now). The save goes through LshuSave (atomic write,
## lock, a second instance opens read-only: it shows the same route, never writes, renders nothing, takes the lock
## over when it frees up). Written on every substate change, every write_every_s, after a postcard / a read / a photo,
## and on quit.
## Stage: the tile on screen follows the stop the stage shows (stage_leg). Events are played in order; a switch holds
## the queue until it is done:
##   LEAVE / ROAD   the next tile (resolve().next_tile) is built hidden beside the old one (off-thread read, assembly
##                  in slices of switch.budget_ms), and the swap's own work is planned for it there (lshu_main.gd _plan:
##                  seat fit on a worker thread, camera, night lamp) and its collision triangles pulled for the motion
##                  (prewarm_tile); the old tile stays on screen empty, its fire dies down to embers, his lantern light
##                  fades as he takes it
##   road_end       the last frame is copied on the GPU (lshu_screen_fade.gd), the staged tile drawn once under it,
##                  then swapped in under it on the next frame, the motion bound (him hidden), the copy dissolved away
##                  (switch.fade_s), then he walks in
##   first launch, catch-up, a stop the stage missed: a hard sync under the cover (postcards still waiting for an
##                  image are rendered first, each on its own tile with him settled and the light of its moment), then
##                  the current state is set without animation and the cover dissolves.
## Light: resolve().light into the stage's continuous interpolation (set_light_state) every tick.
## Night: night_start doze, tent_in into the tent (when the tile has one), night_end back out; the lantern is set down
## on arrival for a stay that reaches into the night (night lamp set_hold) and taken away when he leaves.
## Postcards: on a postcard event the camera renders once he is settled; a render that timed out (window not drawing)
## is retried when the window is visible again. Clicking him: a bow / nod (actor motion) and, once he faces the player,
## a photo saved as a record of type "snap" in save.postcards (id snap_<seed>_<stop>_<n>, not in pending_renders, so
## the loop's postcard rules are untouched).
## UI: configure(cfg, places); apply_resolve(r) every tick with the events handed over when the stage plays them;
## postcard_read -> mark_read + write; the away card comes with the catch-up event (>= 2 h); L opens the travel book.
## Frame cap (scene level, restored on exit): Engine.max_fps fps.focused while the window has focus, fps.unfocused when
## it has not or is minimised. Numbers: data/traveler/lshu/director.json — both 30 since 2026-09-27 (Carlos leaves the act
## running beside other apps like a screensaver; nothing may drop below 30 unfocused). Nothing here knows a tile, place or
## asset id.

signal shown
signal event_handled(e: Dictionary, info: Dictionary)
signal switch_started(info: Dictionary)
signal switch_finished(info: Dictionary)
signal postcard_finished(result: Dictionary)
signal snap_finished(result: Dictionary)
signal ticked(r: Dictionary)

const LshuClock := preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const LshuSave := preload("res://scripts/traveler/lshu/loop/lshu_save.gd")
const LshuPoolAdapter := preload("res://scripts/traveler/lshu/loop/lshu_pool_adapter.gd")
const LshuPostcardText := preload("res://scripts/traveler/lshu/loop/lshu_postcard_text.gd")
const LshuPostcardContext := preload("res://scripts/traveler/lshu/loop/lshu_postcard_context.gd")
const LshuHash := preload("res://scripts/traveler/lshu/loop/lshu_hash.gd")
const LshuUi := preload("res://scripts/traveler/lshu/ui/lshu_ui.gd")
const MOTION_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_actor_motion.gd")
const POSTCARD_CAMERA: GDScript = preload("res://scripts/traveler/lshu/lshu_postcard_camera.gd")
const NIGHT_LAMP: GDScript = preload("res://scripts/traveler/lshu/lshu_night_lamp.gd")
const SCREEN_FADE: GDScript = preload("res://scripts/traveler/lshu/lshu_screen_fade.gd")
const CONFIG_PATH: String = "res://data/traveler/lshu/director.json"
const LIGHTS: Array[String] = ["morning", "day", "sunset", "night"]
const SALT_SNAP: int = 0x534E4150
const ARRIVALS: Array[String] = ["arrive", "home_arrive"]

var stage: Node3D
var dcfg: Dictionary = {}
var cfg: Dictionary = {}
var compiled: Dictionary = {}
var places: Array = []
var store: RefCounted
var save: Dictionary = {}
var opts: Dictionary = {}
var clock_scale: float = 1.0
var anchor_real: float = 0.0
var anchor_logic: float = 0.0
## A moved clock (--lshu-clock-scale / --lshu-now) holds still while the scene starts up and runs from the moment the
## stage is shown, so --lshu-now=UNIX is the time on screen when the cover lifts. The real clock never holds.
var clock_held: bool = false
var motion_origin: float = 0.0
var boot_r: Dictionary = {}
var last_r: Dictionary = {}
var stage_leg: Dictionary = {}
var queue: Array[Dictionary] = []
var render_queue: Array[String] = []
var ui: CanvasLayer
var motion: Node
var pc_cam: Node
var fade: CanvasLayer
var timer: Timer
var started: bool = false
var switching: bool = false
var staging: bool = false
var rendering: bool = false
var snapping: bool = false
var preview: bool = false
var offscreen: bool = false
var light_hold: bool = false
var light_override: String = ""
var synced_leg: int = -1
var synced_at: float = -INF
var focused: bool = true
var saved_max_fps: int = -1
var saved_vsync: int = -1
var last_state_key: String = ""
var last_write_real: float = 0.0
var last_beat_real: float = 0.0
var next_render_real: float = 0.0
var lamp_fade_t0: float = -1.0
var lamp_fade_s: float = 0.0
var stats: Dictionary = {"ticks": 0, "events": {}, "switches": 0, "hard_syncs": 0, "postcards_rendered": 0, "postcards_offscreen": 0,
	"postcard_timeouts": 0, "snaps": 0, "writes": 0, "write_failures": 0, "skipped_stale": 0, "staged": 0, "stage_misses": 0,
	"switch_ms": [], "resolve_ms_max": 0.0, "light_ms_max": 0.0}

signal _staged_done(ok: bool)

# ============================================================================== pure rules (headless-testable)

## Flags: --lshu-clock-scale=N, --lshu-save-dir=PATH, --lshu-now=UNIX, --lshu-dev, --lshu-fps-cap=off.
static func parse_args(args: PackedStringArray) -> Dictionary:
	var out: Dictionary = {"scale": LshuClock.clock_scale_from_args(args), "save_dir": "", "now": -1.0, "dev": false, "fps_cap": true}
	for a: String in args:
		if a.begins_with("--lshu-save-dir="):
			out["save_dir"] = a.trim_prefix("--lshu-save-dir=")
		elif a.begins_with("--lshu-now="):
			var v: float = a.trim_prefix("--lshu-now=").to_float()
			out["now"] = v if v > 0.0 else -1.0
		elif a == "--lshu-dev":
			out["dev"] = true
		elif a == "--lshu-fps-cap=off":
			out["fps_cap"] = false
	return out

## The save dir: an explicit --lshu-save-dir; else the separate debug dir when the clock is scaled or moved
## (a clock ahead of real time would leave the real save "rolled back" for days); else the real save.
static func save_dir_for(o: Dictionary) -> String:
	if str(o.get("save_dir", "")) != "":
		return str(o.save_dir)
	var moved: bool = float(o.get("scale", 1.0)) != 1.0 or float(o.get("now", -1.0)) >= 0.0
	return LshuSave.default_dir(moved)

## Seconds of wall time between two resolve() calls.
static func tick_interval(base_s: float, scale: float, min_real_s: float) -> float:
	if scale <= 1.0:
		return base_s
	return maxf(base_s / scale, min_real_s)

## Wall seconds of a screen transition: never longer than max_logic_s of L叔's clock under a scaled clock.
static func transition_s(seconds: float, scale: float, max_logic_s: float) -> float:
	if scale <= 1.0:
		return seconds
	return maxf(0.05, minf(seconds, max_logic_s / scale))

## Never below 30 (Carlos 2026-09-27: no unfocused throttling; director.json has both at 30).
static func fps_for(has_focus: bool, minimized: bool, fps_cfg: Dictionary) -> int:
	var want: int = int(fps_cfg.get("focused", 30)) if has_focus and not minimized else int(fps_cfg.get("unfocused", 30))
	return want if want <= 0 else maxi(30, want)

## How much the camp fire of a stop still burns at logic time t: 1 while he is there, low_level once he is in the
## tent (back up after night_end), easing down to ember_level after he left (road_start).
static func fire_level_at(leg: Dictionary, t: float, fire_cfg: Dictionary) -> float:
	if leg.is_empty() or not bool(leg.get("fire", true)):
		return 1.0
	var lvl: float = 1.0
	var low: float = float(fire_cfg.get("low_level", 0.45))
	var low_s: float = maxf(1.0, float(fire_cfg.get("low_fade_logic_s", 120.0)))
	var tent: float = float(leg.get("tent_in", -1))
	var ne: float = float(leg.get("night_end", -1))
	if bool(leg.get("night", false)) and tent >= 0.0 and t >= tent:
		var down: float = smoothstep(tent, tent + low_s, t)
		var up: float = smoothstep(ne, ne + low_s, t) if ne >= 0.0 and t >= ne else 0.0
		lvl = lerpf(1.0, low, down * (1.0 - up))
	var rs: float = float(leg.get("road_start", -1))
	if rs >= 0.0 and t >= rs:
		var ember: float = float(fire_cfg.get("ember_level", 0.1))
		var e_s: float = maxf(1.0, float(fire_cfg.get("ember_fade_logic_s", 180.0)))
		lvl = lerpf(lvl, minf(lvl, ember), smoothstep(rs, rs + e_s, t))
	return lvl

## The click-him photo as a postcard record (type "snap"). n = 1 for the first photo of the stop: the back text uses
## the postcard rules with the random key [seed, stop, n] (the loop's own card of the stop is n = 0) and the last 20
## cards as history. c = LshuClock.compile_config(cfg).
static func make_snap_record(s: Dictionary, leg: Dictionary, now: float, c: Dictionary, n: int, id: String, file: String) -> Dictionary:
	var seed: int = int(s.get("seed", 0))
	var k: int = int(leg.get("index", 0))
	var info: Dictionary = LshuClock.local_info(now, c)
	var light: Dictionary = LshuClock.light_at(now, c)
	var pc: Dictionary = {
		"id": id, "type": "snap", "leg": k, "trip": int(leg.get("trip", 0)), "tile": leg.get("tile", ""),
		"place": leg.get("place", ""), "name": leg.get("name", ""), "kit": leg.get("kit", ""), "biome": leg.get("biome", ""),
		"home": bool(leg.get("home", false)), "night": bool(leg.get("night", false)), "shot": "snap", "unix": int(floor(now)),
		"band": light.get("band", ""), "date": info.get("date_label", ""), "time": info.get("time_label", ""),
		"line_seed": LshuHash.hash3(seed, k, SALT_SNAP + n), "text": [], "signature": "", "file": file, "read": false,
	}
	var lines: Dictionary = c.get("lines", {}) as Dictionary
	if lines.is_empty():
		return pc
	pc["signature"] = LshuPostcardText.signature(lines)
	var lib: Dictionary = LshuPostcardText.rich_of(lines)
	if lib.is_empty():
		pc["text"] = LshuPostcardText.compose(pc, lines, str(leg.get("sub", "")))
		return pc
	var ctx: Dictionary = LshuPostcardContext.for_leg(leg, str(pc.band), int(pc.unix), lib)
	var history: Array = LshuPostcardText.history_from_postcards(s.get("postcards", []) as Array, LshuPostcardText.window(lib))
	var card: Dictionary = LshuPostcardText.compose_card(lib, ctx, history, [seed, k, n])
	pc["text"] = card.lines
	pc["line_ids"] = card.line_ids
	pc["categories"] = card.categories
	pc["city_id"] = str((card.ctx as Dictionary).get("city_id", ""))
	pc["stamp"] = LshuPostcardText.stamp(lib, card.ctx, info)
	return pc

static func snap_id(seed: int, leg_index: int, n: int) -> String:
	return "snap_%08x_%d_%d" % [seed & 0xFFFFFFFF, leg_index, n]

static func snaps_on_leg(s: Dictionary, leg_index: int) -> int:
	var n: int = 0
	for v: Variant in s.get("postcards", []) as Array:
		var pc: Dictionary = v
		if str(pc.get("type", "")) == "snap" and int(pc.get("leg", -1)) == leg_index:
			n += 1
	return n

static func load_config(path: String = CONFIG_PATH) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	return parsed if parsed is Dictionary else {}

# ============================================================================== boot (called from the stage's _ready)

## Opens the save and resolves the first state. Returns {ok, tile, light, error}. Synchronous.
func boot(stage_node: Node3D) -> Dictionary:
	stage = stage_node
	dcfg = load_config()
	if dcfg.is_empty():
		return {"ok": false, "error": "director.json missing or invalid: " + CONFIG_PATH}
	opts = parse_args(stage.call("user_args") as PackedStringArray)
	clock_scale = float(opts.scale)
	anchor_real = Time.get_unix_time_from_system()
	anchor_logic = float(opts.now) if float(opts.now) >= 0.0 else anchor_real
	clock_held = clock_scale != 1.0 or float(opts.now) >= 0.0
	var base: Dictionary = LshuClock.load_config()
	cfg = LshuClock.scaled_config(base, clock_scale) if clock_scale != 1.0 else base
	compiled = LshuClock.compile_config(cfg)
	places = LshuPoolAdapter.load_places()
	fade = SCREEN_FADE.new() as CanvasLayer
	add_child(fade)
	fade.call("cover", Color(0.08, 0.08, 0.09))
	var sv: Dictionary = cfg.get("save", {}) as Dictionary
	store = LshuSave.new(save_dir_for(opts), float(sv.get("lock_stale_s", 900.0)), int((cfg.get("log", {}) as Dictionary).get("cap", 500)))
	var opened: Dictionary = store.call("open")
	save = (opened.get("data", {}) as Dictionary) if bool(opened.get("ok", false)) else {}
	var now: float = logic_now()
	var r: Dictionary = LshuClock.resolve(save, now, places, cfg)
	if not bool(r.get("ok", false)):
		return {"ok": false, "error": str(r.get("error", "resolve failed"))}
	save = r.save
	last_r = r
	boot_r = r
	motion_origin = floorf(now)
	_note("boot", {"save_dir": store.get("dir"), "source": opened.get("source", ""), "read_only": bool(store.get("read_only")),
		"scale": clock_scale, "now": now, "local": (r.local as Dictionary).get("time_label", ""), "leg": int((r.leg as Dictionary).get("index", -1)),
		"tile": (r.leg as Dictionary).get("tile", ""), "substate": r.substate, "events": _types(r.events)})
	return {"ok": true, "tile": str((r.leg as Dictionary).get("tile", "")), "light": r.light}

## The opening cover in the backdrop colour (the stage calls it once the light is set).
func opening(backdrop: Color) -> void:
	if fade != null:
		fade.call("cover", backdrop)

## After the first tile is on the (covered) stage. Builds the UI, the motion, the postcard camera; waits for the
## stage's prewarm; renders postcards still waiting for an image; sets the current state; lifts the cover.
func start() -> void:
	saved_max_fps = Engine.max_fps
	if not bool(opts.get("fps_cap", true)):
		saved_vsync = DisplayServer.window_get_vsync_mode()
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	focused = DisplayServer.window_is_focused()
	_apply_fps()
	ui = LshuUi.new()
	add_child(ui)
	ui.call("configure", cfg, places)
	ui.connect("postcard_read", _on_postcard_read)
	motion = MOTION_SCRIPT.new() as Node
	motion.set("dev_focus", bool(opts.get("dev", false)))   # double-click camera push: --lshu-dev only (Carlos 2026-09-27)
	add_child(motion)
	motion.call("setup", stage.get("character"), stage.get("look"))
	motion.set("work_hook", Callable(stage, "mark_work"))
	motion.connect("greeted", _on_greeted)
	pc_cam = POSTCARD_CAMERA.new() as Node
	stage.add_child(pc_cam)
	pc_cam.call("setup", stage)
	timer = Timer.new()
	timer.name = "ResolveTimer"
	timer.wait_time = tick_interval(float((cfg.get("save", {}) as Dictionary).get("resolve_every_s", 2.0)), clock_scale,
		float(_d("tick", "min_real_s", 0.05)))
	timer.timeout.connect(_tick)
	add_child(timer)
	if not bool(stage.get("prewarmed")):
		await stage.prewarm_done
	await motion.call("prepare")
	last_write_real = _real()
	last_beat_real = _real()
	await _hard_sync(boot_r, true)
	if clock_held:
		anchor_real = Time.get_unix_time_from_system()
		clock_held = false
	started = true
	timer.start()
	shown.emit()

# ============================================================================== clock

func logic_now() -> float:
	var real: float = Time.get_unix_time_from_system()
	if clock_scale == 1.0 and float(opts.get("now", -1.0)) < 0.0:
		return real
	if clock_held:
		return anchor_logic
	return LshuClock.scaled_now(real, anchor_real, anchor_logic, clock_scale)

## L叔's motion clock: logic seconds since boot (small floats for the motion timeline).
func mt(logic: float) -> float:
	return logic - motion_origin

func mt_now() -> float:
	return mt(logic_now())

func _real() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0

func _d(sec: String, key: String, fallback: Variant) -> Variant:
	var s: Variant = dcfg.get(sec)
	if s is Dictionary and (s as Dictionary).has(key):
		return (s as Dictionary)[key]
	return fallback

func _fade_s(key: String, fallback: float) -> float:
	return transition_s(float(_d("switch", key, fallback)), clock_scale, float(_d("switch", "fade_max_logic_s", 150.0)))

# ============================================================================== tick

func _tick() -> void:
	var t0: int = Time.get_ticks_usec()
	var now: float = logic_now()
	var r: Dictionary = LshuClock.resolve(save, now, places, cfg)
	stats["resolve_ms_max"] = maxf(float(stats.resolve_ms_max), float(Time.get_ticks_usec() - t0) / 1000.0)
	stage.call("mark_work", "resolve", float(Time.get_ticks_usec() - t0) / 1000.0)
	if not bool(r.get("ok", false)):
		return
	save = r.save
	last_r = r
	stats["ticks"] = int(stats.ticks) + 1
	var r_ui: Dictionary = r.duplicate(false)
	r_ui["events"] = []
	var tu: int = Time.get_ticks_usec()
	ui.call("apply_resolve", r_ui)
	stage.call("mark_work", "ui_resolve", float(Time.get_ticks_usec() - tu) / 1000.0)
	for e: Variant in r.events as Array:
		queue.append(e as Dictionary)
	var key: String = "%d|%s|%s" % [int((r.leg as Dictionary).get("index", -1)), str(r.substate), str(r.night_phase)]
	var every: float = float((cfg.get("save", {}) as Dictionary).get("write_every_s", 300.0))
	if key != last_state_key:
		last_state_key = key
		_write("substate")
	elif _real() - last_write_real >= every:
		_write("periodic")
	if _real() - last_beat_real >= float(_d("save", "heartbeat_s", 60.0)):
		_heartbeat()
	_apply_fps()
	if not light_hold and light_override.is_empty():
		var tl: int = Time.get_ticks_usec()
		stage.call("set_light_state", r.light)
		stats["light_ms_max"] = maxf(float(stats.light_ms_max), float(Time.get_ticks_usec() - tl) / 1000.0)
		stage.call("mark_work", "light", float(Time.get_ticks_usec() - tl) / 1000.0)
	var nt: Dictionary = r.get("next_tile", {}) as Dictionary
	if not nt.is_empty():
		_stage_next(str(nt.get("tile", "")))
	_pump()
	if started and not switching and queue.is_empty() and not preview and int(stage_leg.get("index", -1)) != int((r.leg as Dictionary).get("index", -1)):
		_note("resync", {"stage_leg": int(stage_leg.get("index", -1)), "leg": int((r.leg as Dictionary).get("index", -1))})
		_hard_sync(r, false)
	ticked.emit(r)

func _pump() -> void:
	while not queue.is_empty() and not switching:
		var e: Dictionary = queue.pop_front()
		_handle(e)

func _handle(e: Dictionary) -> void:
	var type: String = str(e.get("type", ""))
	var events: Dictionary = stats.events
	events[type] = int(events.get(type, 0)) + 1
	var leg_i: int = int(e.get("leg", -1))
	var cur_i: int = int((last_r.get("leg", {}) as Dictionary).get("index", -1))
	var on_stage: bool = leg_i == int(stage_leg.get("index", -2))
	var info: Dictionary = {"t": mt_now()}
	if type == "first_launch" or type == "catchup":
		_hard_sync(last_r, false, e)
		info["action"] = "hard_sync"
	elif leg_i >= 0 and leg_i < cur_i and not on_stage:
		# a stop the stage never showed (it fell behind by more than a stop): its events are skipped
		stats["skipped_stale"] = int(stats.skipped_stale) + 1
		info["action"] = "skipped_stale"
	elif on_stage and leg_i == synced_leg and float(e.get("at", 0)) <= synced_at and not ARRIVALS.has(type) and type != "postcard":
		info["action"] = "already_in_sync"
	elif ARRIVALS.has(type):
		if on_stage and str(e.get("tile", "")) == str(stage.get("tile_id")):
			if not (leg_i == synced_leg and float(e.get("at", 0)) <= synced_at):
				motion.call("arrive", mt_now())
			ui.call("handle_event", e)
			info["action"] = "arrive_in_place"
		else:
			_switch(e)
			info["action"] = "switch"
	else:
		var t: float = mt_now()
		match type:
			"wander_start":
				if on_stage:
					var end_at: float = _wander_end(float(e.get("at", 0)))
					info["action"] = "wander" if end_at > 0.0 and bool(motion.call("wander", t, mt(end_at))) else "wander_skipped"
			"postcard":
				var pid: String = str(e.get("postcard", ""))
				if not pid.is_empty() and not render_queue.has(pid):
					render_queue.append(pid)
				info["action"] = "postcard_queued"
			"night_start":
				if on_stage:
					motion.call("night_doze", t)
					info["action"] = "doze"
			"tent_in":
				if on_stage:
					info["action"] = "tent_in" if bool(motion.call("tent_in", t)) else "doze_on"
			"night_end":
				if on_stage:
					motion.call("night_end", t)
					info["action"] = "night_end"
			"leave", "home_leave":
				if on_stage:
					motion.call("leave", t)
					info["action"] = "leave"
				ui.call("handle_event", e)
			"road_start":
				if on_stage:
					_lamp_leave()
					info["action"] = "road"
				ui.call("handle_event", e)
			_:
				ui.call("handle_event", e)
	info["stage_tile"] = str(stage.get("tile_id"))
	info["stage_leg"] = int(stage_leg.get("index", -1))
	_note("event", {"type": type, "at": int(e.get("at", 0)), "leg": leg_i, "tile": e.get("tile", ""), "name": e.get("name", ""), "action": info.get("action", "")})
	event_handled.emit(e, info)

func _wander_end(start_at: float) -> float:
	for w: Variant in stage_leg.get("wanders", []) as Array:
		var wa: Array = w
		if wa.size() >= 2 and absf(float(wa[0]) - start_at) < 1.0:
			return float(wa[1])
	return -1.0

## The stop dictionary for an event's leg index: the current one, else the log line, else what the event carries.
func _leg_for(e: Dictionary) -> Dictionary:
	var idx: int = int(e.get("leg", -1))
	var cur: Dictionary = last_r.get("leg", {}) as Dictionary
	if int(cur.get("index", -2)) == idx:
		return cur.duplicate(true)
	var cl: Dictionary = save.get("current_leg", {}) as Dictionary
	if int(cl.get("index", -2)) == idx:
		return cl.duplicate(true)
	var lg: Array = save.get("log", []) as Array
	for i: int in range(lg.size() - 1, -1, -1):
		var row: Dictionary = lg[i]
		if str(row.get("type", "")) == "leg" and int(row.get("k", -1)) == idx:
			var out: Dictionary = row.duplicate(true)
			out["index"] = idx
			return out
	return {"index": idx, "tile": e.get("tile", ""), "place": e.get("place", ""), "name": e.get("name", ""), "kit": e.get("kit", ""),
		"home": bool(e.get("home", false)), "night": bool(e.get("night", false)), "arrive": int(e.get("at", 0))}

# ============================================================================== tiles

## Builds the next tile hidden while he leaves / is on the road (never during a switch or another stage job).
func _stage_next(id: String) -> void:
	if id.is_empty() or switching or staging or bool(stage.get("loading")) or preview:
		return
	if str(stage.get("staged_id")) == id or str(stage.get("tile_id")) == id:
		return
	staging = true
	var t0: int = Time.get_ticks_usec()
	var ok: bool = await stage.call("stage_tile", id, float(_d("switch", "budget_ms", 6.0)))
	if ok and motion != null:
		# the collision triangles bind_tile() will read from the staged tile, pulled now (one mesh per frame)
		await motion.call("prewarm_tile", stage.get("staged"))
	staging = false
	stats["staged"] = int(stats.staged) + 1
	_note("staged", {"tile": id, "ok": ok, "wall_ms": float(Time.get_ticks_usec() - t0) / 1000.0, "logic": logic_now(),
		"road_end": int((last_r.get("leg", {}) as Dictionary).get("road_end", -1)), "parts": stage.get("stage_parts")})
	_staged_done.emit(ok)

func _wait_stage_idle() -> void:
	while staging:
		await _staged_done
	while bool(stage.get("loading")):
		await get_tree().process_frame

## road_end -> arrive: dissolve from the empty old tile to the new one, then he walks in.
func _switch(e: Dictionary) -> void:
	switching = true
	preview = false
	var t0: int = Time.get_ticks_usec()
	var id: String = str(e.get("tile", ""))
	var info: Dictionary = {"tile": id, "leg": int(e.get("leg", -1)), "from": str(stage.get("tile_id")), "at": int(e.get("at", 0)),
		"was_staged": false, "logic_start": logic_now()}
	switch_started.emit(info)
	await _wait_stage_idle()
	info["was_staged"] = str(stage.get("staged_id")) == id
	if not bool(info.was_staged):
		stats["stage_misses"] = int(stats.stage_misses) + 1
		staging = true
		var ok_stage: bool = await stage.call("stage_tile", id, float(_d("switch", "budget_ms", 6.0)))
		staging = false
		if not ok_stage:
			push_error("LSHU director could not build tile " + id)
			switching = false
			return
	var covered: bool = false
	if not bool(ui.call("is_busy")):
		var ts: int = Time.get_ticks_usec()
		covered = bool(fade.call("snapshot"))
		if not covered:
			fade.call("cover", stage.get("look").get("backdrop_display"))
			covered = true
		# the new tile's first draw happens on this covered frame, not on the swap frame
		stage.call("show_staged_under_cover")
		stage.call("mark_work", "snapshot", float(Time.get_ticks_usec() - ts) / 1000.0)
		await get_tree().process_frame
	var tc: int = Time.get_ticks_usec()
	await stage.call("commit_staged")
	info["commit_ms"] = float(Time.get_ticks_usec() - tc) / 1000.0
	info["commit_parts"] = (stage.get("commit_parts") as Dictionary).duplicate()
	stage_leg = _leg_for(e)
	synced_leg = -1
	_on_stage_leg(true)
	var plan: Dictionary = await motion.call("bind_tile", stage.get("tile"), stage.get("camera"), mt_now(), true)
	info["bind_ms"] = plan.get("bind_ms", 0.0)
	if covered:
		await fade.call("fade_out", _fade_s("fade_s", 2.5))
	var ta: int = Time.get_ticks_usec()
	motion.call("arrive", mt_now())
	stage.call("mark_work", "arrive", float(Time.get_ticks_usec() - ta) / 1000.0)
	ta = Time.get_ticks_usec()
	ui.call("handle_event", e)
	stage.call("mark_work", "ui_event", float(Time.get_ticks_usec() - ta) / 1000.0)
	info["wall_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	info["logic_end"] = logic_now()
	(stats.switch_ms as Array).append(info.wall_ms)
	stats["switches"] = int(stats.switches) + 1
	_note("switch", info)
	switching = false
	switch_finished.emit(info)
	_pump()

## Straight to the state of r (no animation) under a cover: first launch, catch-up, a stop the stage missed.
## Postcards still waiting for an image are rendered first (each on its own tile, him settled, the light of its moment).
func _hard_sync(r: Dictionary, opening_run: bool, e: Dictionary = {}) -> void:
	if switching and not opening_run:
		return
	switching = true
	preview = false
	var t0: int = Time.get_ticks_usec()
	stats["hard_syncs"] = int(stats.hard_syncs) + 1
	if not opening_run:
		if not bool(ui.call("is_busy")):
			if not bool(fade.call("snapshot")):
				fade.call("cover", stage.get("look").get("backdrop_display"))
			await get_tree().process_frame
	await _wait_stage_idle()
	if not bool(store.get("read_only")):
		await _render_pending_offscreen()
	# the current stop's tile (the clock may have moved on while the postcards rendered: follow it, a few times at most)
	var id: String = ""
	for _attempt: int in 3:
		id = str((last_r.get("leg", {}) as Dictionary).get("tile", ""))
		if str(stage.get("tile_id")) == id:
			break
		stage.call("discard_staged")
		await stage.call("load_tile", id, float(_d("switch", "budget_ms", 6.0)))
	var rr: Dictionary = last_r
	stage_leg = (rr.get("leg", {}) as Dictionary).duplicate(true)
	light_hold = false
	if light_override.is_empty():
		stage.call("set_light_state", rr.light)
	var state: String = await _bind_for_state(rr)
	synced_leg = int(stage_leg.get("index", -1))
	synced_at = float(rr.get("now", logic_now()))
	await fade.call("fade_out", float(_d("switch", "opening_fade_s", 1.6)) if opening_run else _fade_s("hard_fade_s", 1.8))
	var shown_events: Array = []
	var evs: Array = (r.get("events", []) as Array) if opening_run else ([e] if not e.is_empty() else [])
	for v: Variant in evs:
		var ev: Dictionary = v
		var ty: String = str(ev.get("type", ""))
		if ty == "postcard":
			continue
		if ty == "first_launch" or ty == "catchup" or ARRIVALS.has(ty) or (not opening_run):
			ui.call("handle_event", ev)
			shown_events.append(ty)
	if opening_run:
		for v2: Variant in evs:
			var ev2: Dictionary = v2
			var cnt: Dictionary = stats.events
			cnt[str(ev2.get("type", ""))] = int(cnt.get(str(ev2.get("type", "")), 0)) + 1
	_note("hard_sync", {"opening": opening_run, "tile": id, "state": state, "wall_ms": float(Time.get_ticks_usec() - t0) / 1000.0, "ui": shown_events})
	switching = false
	_pump()

## Motion for the state r describes, without playing what came before. Returns a label for the log.
func _bind_for_state(r: Dictionary) -> String:
	var st: String = str(r.get("substate", ""))
	var hidden: bool = st == "ROAD" or st == "LEAVE" or st == "ARRIVE"
	_on_stage_leg(st != "ROAD")
	await motion.call("bind_tile", stage.get("tile"), stage.get("camera"), mt_now(), hidden)
	var t: float = mt_now()
	match st:
		"ARRIVE":
			motion.call("arrive", t)
			return "arrive"
		"NIGHT":
			motion.call("night_doze", t - 10.0)
			if str(r.get("night_phase", "")) == "tent":
				if bool(motion.call("tent_in", t - 600.0)):
					return "tent"
			return "doze"
		"LEAVE", "ROAD":
			if st == "ROAD":
				var lamp: Node3D = _lamp()
				if lamp != null:
					lamp.call("set_present", false)
			return "away"
	return "settled"

## A new stop on the stage: his lantern (set down on arrival for a stay that reaches into the night), the fire lit.
func _on_stage_leg(present: bool) -> void:
	lamp_fade_t0 = -1.0
	var lamp: Node3D = _lamp()
	if lamp != null:
		lamp.call("set_present", present)
		var a: int = int(stage_leg.get("arrive", -1))
		var d: int = int(stage_leg.get("depart", -1))
		lamp.call("set_hold", a >= 0 and d > a and bool(NIGHT_LAMP.call("stay_needs_lamp", a, d, compiled)))
	stage.call("set_fire_level", 1.0, _d("fire", "shape", {}) as Dictionary)

func _lamp() -> Node3D:
	var lamp: Variant = stage.get("night_lamp")
	if lamp is Node3D and is_instance_valid(lamp):
		return lamp as Node3D
	return null

func _lamp_leave() -> void:
	lamp_fade_t0 = _real()
	lamp_fade_s = _fade_s_raw(float(_d("lamp", "leave_fade_s", 2.0)))

func _fade_s_raw(seconds: float) -> float:
	return transition_s(seconds, clock_scale, float(_d("switch", "fade_max_logic_s", 150.0)))

# ============================================================================== postcards

## Postcards waiting for an image (at most the loop's max_pending): each on its own tile, him settled, the light of
## the postcard's moment. Only under a cover (hard sync).
func _render_pending_offscreen() -> void:
	var ids: Array = (save.get("pending_renders", []) as Array).duplicate()
	if ids.is_empty():
		return
	offscreen = true
	light_hold = true
	var tile_ids: Array = stage.get("tile_ids")
	for v: Variant in ids:
		var id: String = str(v)
		var rec: Dictionary = LshuSave.find_postcard(save, id)
		if rec.is_empty() or str(rec.get("file", "")) != "" or not tile_ids.has(str(rec.get("tile", ""))):
			continue
		if str(stage.get("tile_id")) != str(rec.tile):
			stage.call("discard_staged")
			if not bool(await stage.call("load_tile", str(rec.tile), float(_d("switch", "budget_ms", 6.0)))):
				continue
		await motion.call("bind_tile", stage.get("tile"), stage.get("camera"), mt_now(), false)
		var lamp: Node3D = _lamp()
		if lamp != null:
			lamp.call("set_present", true)
			lamp.call("set_hold", false)
		stage.call("set_fire_level", 1.0, _d("fire", "shape", {}) as Dictionary)
		stage.call("set_light_state", LshuClock.light_at(float(rec.get("unix", logic_now())), compiled))
		for _i: int in 2:
			await get_tree().process_frame
		var res: Dictionary = await pc_cam.call("render_postcard", rec, str(store.get("dir")))
		res["offscreen"] = true
		_postcard_result(res)
		if bool(res.get("ok", false)):
			stats["postcards_offscreen"] = int(stats.postcards_offscreen) + 1
		render_queue.erase(id)
	offscreen = false

func _try_renders() -> void:
	if rendering or switching or offscreen or render_queue.is_empty() or bool(store.get("read_only")):
		return
	if _real() < next_render_real:
		return
	var id: String = render_queue[0]
	var rec: Dictionary = LshuSave.find_postcard(save, id)
	if rec.is_empty() or str(rec.get("file", "")) != "":
		render_queue.pop_front()
		return
	if str(rec.get("tile", "")) != str(stage.get("tile_id")) or int(rec.get("leg", -1)) != int(stage_leg.get("index", -2)):
		# not on screen any more: stays in save.pending_renders for the next hard sync / launch
		render_queue.pop_front()
		_note("postcard_deferred", {"id": id})
		return
	# settled at his spot (dozing by the fire counts: overnight postcards are taken before the tent)
	var phase: String = str((motion.get("last_frame") as Dictionary).get("phase", ""))
	if phase != "kit" and phase != "doze":
		return
	rendering = true
	var res: Dictionary = await pc_cam.call("render_postcard", rec, str(store.get("dir")))
	rendering = false
	if bool(res.get("timed_out", false)):
		next_render_real = _real() + float(_d("postcard", "retry_every_s", 20.0))
		stats["postcard_timeouts"] = int(stats.postcard_timeouts) + 1
	else:
		render_queue.erase(id)
	_postcard_result(res)

func _postcard_result(res: Dictionary) -> void:
	if bool(res.get("ok", false)):
		LshuSave.complete_render(save, str(res.id), str(res.path))
		stats["postcards_rendered"] = int(stats.postcards_rendered) + 1
		_write("postcard")
		ui.call("set_save", save)
		ui.call("set_unread", LshuSave.unread(save))
	_note("postcard", {"id": res.get("id", ""), "ok": res.get("ok", false), "timed_out": res.get("timed_out", false), "rule": res.get("rule", ""),
		"error": res.get("error", ""), "path": res.get("path", ""), "offscreen": res.get("offscreen", false)})
	postcard_finished.emit(res)

func _on_postcard_read(id: String) -> void:
	LshuSave.mark_read(save, id)
	_write("read")

## Clicked him (actor motion greeted): once he faces the player, a photo (at most snap.max_per_leg per stop).
func _on_greeted(kind: String, _t: float) -> void:
	if snapping or switching or bool(store.get("read_only")) or stage_leg.is_empty():
		return
	var k: int = int(stage_leg.get("index", -1))
	var n: int = snaps_on_leg(save, k)
	if n >= int(_d("snap", "max_per_leg", 1)):
		return
	snapping = true
	var wait_s: float = maxf(0.05, float(_d("snap", "after_greet_logic_s", 0.75)) / maxf(clock_scale, 1.0))
	await get_tree().create_timer(wait_s).timeout
	var seed: int = int(save.get("seed", 0))
	var id: String = snap_id(seed, k, n + 1)
	var res: Dictionary = await pc_cam.call("snap", id, str(store.get("dir")), LshuHash.hash3(seed, k, SALT_SNAP + n + 1))
	if bool(res.get("ok", false)) and int(stage_leg.get("index", -1)) == k:
		var rec: Dictionary = make_snap_record(save, stage_leg, logic_now(), compiled, n + 1, id, str(res.path))
		(save.get("postcards", []) as Array).append(rec)
		stats["snaps"] = int(stats.snaps) + 1
		_write("snap")
		ui.call("set_save", save)
		ui.call("set_unread", LshuSave.unread(save))
	_note("snap", {"id": id, "kind": kind, "ok": res.get("ok", false), "error": res.get("error", ""), "rule": res.get("rule", "")})
	snapping = false
	snap_finished.emit(res)

# ============================================================================== per frame

func _process(_delta: float) -> void:
	if motion == null:
		return
	var now: float = logic_now()
	motion.call("tick", mt(now))
	if offscreen:
		return
	stage.call("set_fire_level", fire_level_at(stage_leg, now, dcfg.get("fire", {}) as Dictionary), _d("fire", "shape", {}) as Dictionary)
	if lamp_fade_t0 >= 0.0:
		var lamp: Node3D = _lamp()
		var u: float = clampf((_real() - lamp_fade_t0) / maxf(lamp_fade_s, 0.01), 0.0, 1.0)
		if lamp != null:
			lamp.call("set_presence_fade", 1.0 - smoothstep(0.0, 1.0, u))
			if u >= 1.0:
				lamp.call("set_present", false)
		if u >= 1.0:
			lamp_fade_t0 = -1.0
	if started:
		_try_renders()

func _unhandled_input(event: InputEvent) -> void:
	if not started or switching or motion == null or ui == null or bool(ui.call("is_busy")):
		return
	if bool(motion.call("handle_input", event, mt_now())):
		get_viewport().set_input_as_handled()

## 手柄 A（lshu_main.gd act_pad）：和点 L叔 一样跟他打招呼（站着鞠躬、坐着点头；拍照照旧按规矩）
func pad_greet() -> bool:
	if not started or switching or motion == null or ui == null or bool(ui.call("is_busy")):
		return false
	if ui.has_method("notify_activity"):
		ui.call("notify_activity")
	return bool(motion.call("click", mt_now()))

# ============================================================================== save, focus, frame cap

func _write(reason: String) -> void:
	if store == null or bool(store.get("read_only")):
		return
	var tw: int = Time.get_ticks_usec()
	var ok: bool = store.call("write", save)
	if stage != null:
		stage.call("mark_work", "save", float(Time.get_ticks_usec() - tw) / 1000.0)
	last_write_real = _real()
	stats["writes"] = int(stats.writes) + 1
	if not ok:
		stats["write_failures"] = int(stats.write_failures) + 1
		_note("write_failed", {"reason": reason, "error": store.get("last_error")})

func _heartbeat() -> void:
	last_beat_real = _real()
	if not bool(store.get("read_only")):
		store.call("heartbeat")
		return
	# read-only: follow the other instance's file; take over once its lock is free
	var took: bool = store.call("try_acquire")
	var d: Dictionary = store.call("load_data")
	if bool(d.get("ok", false)) and not (d.get("data", {}) as Dictionary).is_empty():
		save = d.data
	if took:
		_note("lock_acquired", {})

func _apply_fps() -> void:
	# not before start(): a focus change during boot would set the cap before start() saves the value to put back on exit
	# (seen in director_smoke: fps_restored_on_exit read 30 instead of the harness's 77 when the window lost focus early)
	if saved_max_fps < 0 or not bool(opts.get("fps_cap", true)):
		return
	var minimized: bool = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED
	var want: int = fps_for(focused, minimized, dcfg.get("fps", {}) as Dictionary)
	if Engine.max_fps != want:
		Engine.max_fps = want

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			focused = true
			next_render_real = 0.0   # a render that timed out while the window was not drawing: retry now
			_apply_fps()
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			focused = false
			_apply_fps()
		NOTIFICATION_WM_CLOSE_REQUEST:
			if started:
				_write("close")

func _exit_tree() -> void:
	if store != null and started:
		_write("exit")
	if store != null:
		store.call("close")
	if saved_max_fps >= 0:
		Engine.max_fps = saved_max_fps
	if saved_vsync >= 0:
		DisplayServer.window_set_vsync_mode(saved_vsync as DisplayServer.VSyncMode)

# ============================================================================== dev keys (--lshu-dev)

func dev_key(keycode: int) -> void:
	if keycode == KEY_F1:
		var order: Array[String] = [""]
		order.append_array(LIGHTS)
		light_override = order[(order.find(light_override) + 1) % order.size()]
		if light_override.is_empty():
			stage.call("set_light_state", last_r.get("light", {}))
		else:
			stage.call("set_light", light_override)
		_note("dev_light", {"override": light_override if not light_override.is_empty() else "clock"})
	elif (keycode == KEY_F3 or keycode == KEY_F4) and started and not switching:
		var ids: Array = stage.get("tile_ids")
		var step: int = 1 if keycode == KEY_F3 else -1
		var id: String = str(ids[(ids.find(str(stage.get("tile_id"))) + step + ids.size()) % ids.size()])
		_preview(id)

## Dev: show another pool tile with him settled until the loop's next switch.
func _preview(id: String) -> void:
	switching = true
	await _wait_stage_idle()
	if not bool(fade.call("snapshot")):
		fade.call("cover", stage.get("look").get("backdrop_display"))
	await get_tree().process_frame
	stage.call("discard_staged")
	await stage.call("load_tile", id, float(_d("switch", "budget_ms", 6.0)))
	await motion.call("bind_tile", stage.get("tile"), stage.get("camera"), mt_now(), false)
	_on_stage_leg(true)
	await fade.call("fade_out", _fade_s("fade_s", 2.5))
	preview = true
	_note("dev_tile", {"tile": id})
	switching = false

# ============================================================================== evidence

func evidence() -> Dictionary:
	var lamp: Node3D = _lamp()
	var look: RefCounted = stage.get("look") as RefCounted
	var r: Dictionary = last_r
	var now: float = logic_now()
	return {
		"logic": now, "local": (LshuClock.local_info(now, compiled) as Dictionary).get("time_label", ""),
		"resolved_local": (r.get("local", {}) as Dictionary).get("time_label", ""), "substate": r.get("substate", ""),
		"night_phase": r.get("night_phase", ""), "leg": int((r.get("leg", {}) as Dictionary).get("index", -1)),
		"leg_name": (r.get("leg", {}) as Dictionary).get("name", ""), "stage_tile": str(stage.get("tile_id")),
		"stage_leg": int(stage_leg.get("index", -1)), "stage_name": stage_leg.get("name", ""), "switching": switching, "staging": staging,
		"rendering": rendering, "queue": queue.size(), "render_queue": render_queue.duplicate(),
		"fire_level": fire_level_at(stage_leg, now, dcfg.get("fire", {}) as Dictionary),
		"light": r.get("light", {}), "night_weight": float(look.call("weight", "night")) if look != null else 0.0,
		"lamp": lamp.call("evidence") if lamp != null else {}, "motion_phase": str((motion.get("last_frame") as Dictionary).get("phase", "")) if motion != null else "",
		"fade": fade.call("evidence") if fade != null else {}, "read_only": bool(store.get("read_only")) if store != null else true,
		"max_fps": Engine.max_fps, "focused": focused, "preview": preview, "light_override": light_override, "stats": stats,
		"ui": ui.call("state") if ui != null else {},
	}

func _note(kind: String, data: Dictionary) -> void:
	if bool(opts.get("dev", false)):
		print("LSHU_DIRECTOR ", kind, " ", JSON.stringify(data))

static func _types(events: Variant) -> Array:
	var out: Array = []
	for e: Variant in events as Array:
		out.append(str((e as Dictionary).get("type", "")))
	return out
