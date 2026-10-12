extends RefCounted
## Act 4 loop: the save file for 「L叔在哪儿」.
##
## Location: OS.get_data_dir()/ShanheLvren/lshu_where/ (override the dir for tests or for the
## --lshu-clock-scale debug window, which must never write into the real save).
## Files in the dir:
##   save.json       current save (schema lshu.where.save.v1)
##   save.json.bak   the previous good save; loaded when save.json is missing or does not parse
##   save.json.tmp   written first, then renamed over save.json (atomic replace). A complete
##                   .tmp newer than save.json / .bak (the process died mid-rotation) is loaded.
##   save.lock       {pid, token, heartbeat_unix}; a second instance that finds a fresh lock
##                   owned by a running process opens read-only and never writes. A lock left
##                   by a process that is gone (crash, force quit) is taken over at once.
##   postcards/      postcard images (<postcard id>.jpg), written by the scene
## Usage:
##   var store := LshuSave.new()            # or LshuSave.new(dir_override)
##   var opened: Dictionary = store.open()   # {ok, data, source, read_only, error}
##   ... LshuClock.resolve(opened.data, now, places, cfg) ...
##   store.write(result.save)                # on every substate change, every 5 min, on quit
##   store.close()                           # releases the lock

const SCHEMA: String = "lshu.where.save.v1"
const FILE_NAME: String = "save.json"
const LOCK_NAME: String = "save.lock"
const DEFAULT_SUBDIR: String = "ShanheLvren/lshu_where"
const SCALED_SUBDIR: String = "ShanheLvren/lshu_where_scaled"
const LOG_CAP: int = 500

var dir: String = ""
var read_only: bool = false
var lock_stale_s: float = 900.0
var log_cap: int = LOG_CAP
var token: String = ""
var source: String = ""
var last_error: String = ""
## Tests only: "after_tmp" / "after_rotate" make write() stop there, like a process killed at that point.
var fail_point: String = ""
## Every write gets save_seq = previous + 1, so "which file is newer" never depends on the wall clock.
var _seq: int = 0
## save.json is known to parse (loaded from it, or written by this instance): no need to re-parse
## it before rotating it into .bak.
var _main_good: bool = false


## scaled = true gives the separate dir used by the --lshu-clock-scale debug window.
static func default_dir(scaled: bool = false) -> String:
	return OS.get_data_dir().path_join(SCALED_SUBDIR if scaled else DEFAULT_SUBDIR)


func _init(dir_override: String = "", stale_s: float = 900.0, cap: int = LOG_CAP) -> void:
	dir = dir_override if dir_override != "" else default_dir(false)
	lock_stale_s = stale_s
	log_cap = cap


func save_path() -> String:
	return dir.path_join(FILE_NAME)


func bak_path() -> String:
	return save_path() + ".bak"


func tmp_path() -> String:
	return save_path() + ".tmp"


func lock_path() -> String:
	return dir.path_join(LOCK_NAME)


func postcard_dir() -> String:
	return dir.path_join("postcards")


func postcard_image_path(postcard_id: String) -> String:
	return postcard_dir().path_join(postcard_id + ".jpg")


## Creates the dir, takes the lock (or goes read-only), loads save.json or falls back to .bak.
## data is {} for a brand-new player; hand it to LshuClock.resolve as is.
func open(now_unix: float = -1.0) -> Dictionary:
	var now: float = _now(now_unix)
	last_error = ""
	var mk: int = DirAccess.make_dir_recursive_absolute(dir)
	if mk != OK and not DirAccess.dir_exists_absolute(dir):
		read_only = true
		last_error = "mkdir_failed:%d" % mk
		return {"ok": false, "data": {}, "source": "none", "read_only": true, "error": last_error}
	read_only = not _acquire_lock(now)
	var loaded: Dictionary = load_data(now)
	loaded["read_only"] = read_only
	return loaded


## Load only (no lock). Order: save.json, unless a complete .tmp is newer (the process died after
## writing it); then the newer of .tmp / .bak; then new.
func load_data(now_unix: float = -1.0) -> Dictionary:
	_main_good = false
	var main: Dictionary = _read_json(save_path())
	if bool(main.ok) and String((main.data as Dictionary).get("schema", "")) != SCHEMA:
		# Unknown schema (probably a newer build): never overwrite it.
		read_only = true
		source = "schema_mismatch"
		last_error = "schema:" + String((main.data as Dictionary).get("schema", ""))
		return {"ok": false, "data": {}, "source": source, "error": last_error}
	var tmp: Dictionary = _read_json(tmp_path())
	var tmp_ok: bool = bool(tmp.ok) and String((tmp.data as Dictionary).get("schema", "")) == SCHEMA
	if tmp_ok:
		_note_seq(tmp.data)
	if bool(main.ok):
		_note_seq(main.data)
		if tmp_ok and _newer(tmp.data, main.data):
			source = "tmp"
			last_error = ""
			return {"ok": true, "data": tmp.data, "source": source, "error": ""}
		source = "main"
		_main_good = true
		return {"ok": true, "data": main.data, "source": source, "error": ""}
	var bak: Dictionary = _read_json(bak_path())
	var bak_ok: bool = bool(bak.ok) and String((bak.data as Dictionary).get("schema", "")) == SCHEMA
	if bak_ok:
		_note_seq(bak.data)
	if tmp_ok and (not bak_ok or _newer(tmp.data, bak.data)):
		source = "tmp"
		last_error = "main:" + String(main.error)
		return {"ok": true, "data": tmp.data, "source": source, "error": last_error}
	if bak_ok:
		source = "bak"
		last_error = "main:" + String(main.error)
		return {"ok": true, "data": bak.data, "source": source, "error": last_error}
	# Nothing usable. Keep any corrupt files aside so a fresh start cannot destroy them.
	var now: float = _now(now_unix)
	for p: String in [save_path(), bak_path()]:
		if FileAccess.file_exists(p) and not read_only:
			DirAccess.rename_absolute(p, "%s.corrupt-%d" % [p, int(now)])
	source = "new"
	return {"ok": true, "data": {}, "source": source, "error": String(main.error)}


## Atomic write: save.json.tmp -> (good save.json -> save.json.bak) -> rename tmp over save.json.
## Returns false (and writes nothing) in read-only mode or when another instance took the lock.
func write(data: Dictionary, now_unix: float = -1.0) -> bool:
	var now: float = _now(now_unix)
	if read_only:
		last_error = "read_only"
		return false
	if not _lock_is_ours():
		read_only = true
		last_error = "lock_lost"
		return false
	var d: Dictionary = data.duplicate(false)
	_seq += 1
	d["schema"] = SCHEMA
	d["saved_unix"] = now
	d["save_seq"] = _seq
	d["log"] = compact_log(d.get("log", []) as Array, log_cap)
	var text: String = JSON.stringify(d, " ", true, true)
	var f: FileAccess = FileAccess.open(tmp_path(), FileAccess.WRITE)
	if f == null:
		last_error = "tmp_open:%d" % FileAccess.get_open_error()
		return false
	f.store_string(text)
	f.flush()
	f.close()
	# Read back and compare. The text came from JSON.stringify, so it parses; what can fail is the
	# disk write itself. Comparing costs ~1 ms where a second JSON parse costs ~16 ms per MB.
	if FileAccess.get_file_as_string(tmp_path()) != text:
		last_error = "tmp_verify"
		return false
	if fail_point == "after_tmp":
		return false
	if FileAccess.file_exists(save_path()):
		if _main_good or bool(_read_json(save_path()).ok):
			var e1: int = DirAccess.rename_absolute(save_path(), bak_path())
			if e1 != OK:
				last_error = "rotate:%d" % e1
				return false
		else:
			DirAccess.remove_absolute(save_path())
	if fail_point == "after_rotate":
		return false
	var e2: int = DirAccess.rename_absolute(tmp_path(), save_path())
	if e2 != OK:
		last_error = "rename:%d" % e2
		_main_good = false
		return false
	_main_good = true
	_write_lock(now)
	last_error = ""
	return true


## Call about once a minute from the scene so a live lock never looks stale.
func heartbeat(now_unix: float = -1.0) -> void:
	if read_only or not _lock_is_ours():
		return
	_write_lock(_now(now_unix))


## A read-only instance can retry; succeeds once the other instance's lock goes stale or is released.
func try_acquire(now_unix: float = -1.0) -> bool:
	if not read_only:
		return true
	if source == "schema_mismatch":
		return false
	read_only = not _acquire_lock(_now(now_unix))
	return not read_only


func close() -> void:
	if _lock_is_ours():
		DirAccess.remove_absolute(lock_path())
	token = ""
	read_only = true


# ---------------------------------------------------------------------------------------------
# Save-data helpers (static; they edit the dictionary returned by LshuClock.resolve in place).

## Log capped at `cap` entries. Oldest per-stop entries are collapsed into one line per trip:
## {type:"trip", trip, from, to, stops, home, nights, places:[<=8 names]}. The newest `keep_trips`
## trips (the one under way and the one before) always keep one line per stop; when nothing older
## is left to collapse, the oldest other lines are dropped instead.
static func compact_log(log_in: Array, cap: int = LOG_CAP, keep_trips: int = 2) -> Array:
	if log_in.size() <= cap:
		return log_in
	var out: Array = log_in.duplicate()
	var newest: int = -1
	for e0: Variant in out:
		if String((e0 as Dictionary).get("type", "leg")) == "leg":
			newest = maxi(newest, int((e0 as Dictionary).get("trip", -1)))
	var protect_from: int = newest - keep_trips + 1
	var guard: int = 0
	while out.size() > cap and guard < 100000:
		guard += 1
		var first: int = -1
		for i: int in out.size():
			var ei: Dictionary = out[i]
			if String(ei.get("type", "leg")) == "leg" and int(ei.get("trip", -1)) < protect_from:
				first = i
				break
		if first < 0:
			out.remove_at(_oldest_unprotected(out, protect_from))
			continue
		var trip: int = int((out[first] as Dictionary).get("trip", 0))
		var summary: Dictionary = {"type": "trip", "trip": trip, "from": -1, "to": -1, "stops": 0,
			"home": false, "nights": 0, "places": []}
		var keep: Array = []
		var insert_at: int = -1
		for i: int in out.size():
			var e: Dictionary = out[i]
			var kind: String = String(e.get("type", "leg"))
			var same_trip: bool = int(e.get("trip", -9)) == trip
			if same_trip and (kind == "leg" or kind == "trip"):
				if insert_at < 0:
					insert_at = keep.size()
				_merge_into_summary(summary, e)
			else:
				keep.append(e)
		if insert_at < 0:
			insert_at = 0
		keep.insert(insert_at, summary)
		if keep.size() >= out.size():
			# Collapsing one trip did not shrink the log (a single-entry trip): drop the oldest line.
			keep.remove_at(_oldest_unprotected(keep, protect_from))
		out = keep
	return out


static func _oldest_unprotected(arr: Array, protect_from: int) -> int:
	for i: int in arr.size():
		var e: Dictionary = arr[i]
		if not (String(e.get("type", "leg")) == "leg" and int(e.get("trip", -1)) >= protect_from):
			return i
	return 0


static func _merge_into_summary(summary: Dictionary, e: Dictionary) -> void:
	var kind: String = String(e.get("type", "leg"))
	var from_t: int = int(e.get("from", e.get("arrive", -1)))
	var to_t: int = int(e.get("to", e.get("road_end", e.get("depart", -1))))
	if from_t >= 0 and (int(summary.from) < 0 or from_t < int(summary.from)):
		summary["from"] = from_t
	if to_t > int(summary.to):
		summary["to"] = to_t
	var places: Array = summary.places
	if kind == "trip":
		summary["stops"] = int(summary.stops) + int(e.get("stops", 0))
		summary["nights"] = int(summary.nights) + int(e.get("nights", 0))
		summary["home"] = bool(summary.home) or bool(e.get("home", false))
		for n: Variant in e.get("places", []) as Array:
			if places.size() < 8 and not places.has(n):
				places.append(n)
		return
	if bool(e.get("home", false)):
		summary["home"] = true
	else:
		summary["stops"] = int(summary.stops) + 1
	if bool(e.get("night", false)):
		summary["nights"] = int(summary.nights) + 1
	var pname: String = String(e.get("name", e.get("place", "")))
	if not bool(e.get("home", false)) and places.size() < 8 and not places.has(pname):
		places.append(pname)


static func find_postcard(data: Dictionary, postcard_id: String) -> Dictionary:
	for pc: Variant in data.get("postcards", []) as Array:
		if String((pc as Dictionary).get("id", "")) == postcard_id:
			return pc
	return {}


## The scene rendered the image: record the file and drop it from pending_renders.
static func complete_render(data: Dictionary, postcard_id: String, file_path: String) -> bool:
	var pc: Dictionary = find_postcard(data, postcard_id)
	if pc.is_empty():
		return false
	pc["file"] = file_path
	var pending: Array = data.get("pending_renders", []) as Array
	pending.erase(postcard_id)
	data["pending_renders"] = pending
	return true


static func mark_read(data: Dictionary, postcard_id: String) -> bool:
	var pc: Dictionary = find_postcard(data, postcard_id)
	if pc.is_empty():
		return false
	pc["read"] = true
	return true


## Unread postcards that already have an image (the stamp in the corner shows when non-empty).
static func unread(data: Dictionary) -> Array:
	var out: Array = []
	for pc: Variant in data.get("postcards", []) as Array:
		var d: Dictionary = pc
		if not bool(d.get("read", false)) and String(d.get("file", "")) != "":
			out.append(d)
	return out


# ---------------------------------------------------------------------------------------------

func _now(now_unix: float) -> float:
	return now_unix if now_unix >= 0.0 else Time.get_unix_time_from_system()


func _acquire_lock(now: float) -> bool:
	var lp: String = lock_path()
	if FileAccess.file_exists(lp):
		var l: Dictionary = _read_json(lp)
		if bool(l.ok):
			var ld: Dictionary = l.data
			var hb: float = float(ld.get("heartbeat_unix", 0.0))
			var other: bool = String(ld.get("token", "")) != token or token == ""
			var fresh: bool = now - hb < lock_stale_s and hb <= now + 60.0
			if other and fresh and pid_state(int(ld.get("pid", 0))) != 0:
				return false
	token = "%d-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec(), randi()]
	_write_lock(now)
	return _lock_is_ours()


## 1 = running, 0 = gone, -1 = cannot tell (then only the heartbeat age decides).
## OS.is_process_running() cannot be used: on Unix it only knows this process's own children.
static func pid_state(pid: int) -> int:
	if pid <= 0:
		return -1
	if pid == OS.get_process_id():
		return 1
	if DirAccess.dir_exists_absolute("/proc/self"):
		return 1 if DirAccess.dir_exists_absolute("/proc/%d" % pid) else 0
	if FileAccess.file_exists("/bin/ps") and OS.get_name() in ["macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		var out: Array = []
		var code: int = OS.execute("/bin/ps", ["-p", str(pid), "-o", "pid="], out, true)
		if code == 0:
			return 1
		if code == 1:
			return 0
	return -1


func _note_seq(d: Dictionary) -> void:
	var v: Variant = d.get("save_seq", 0)
	if v is int or v is float:
		_seq = maxi(_seq, int(v))


## a newer than b: higher save_seq, or the same and a later saved_unix.
static func _newer(a: Dictionary, b: Dictionary) -> bool:
	var sa: int = _seq_of(a)
	var sb: int = _seq_of(b)
	if sa != sb:
		return sa > sb
	return _num_or(a.get("saved_unix"), 0.0) > _num_or(b.get("saved_unix"), 0.0)


static func _seq_of(d: Dictionary) -> int:
	return int(_num_or(d.get("save_seq"), 0.0))


static func _num_or(v: Variant, fallback: float) -> float:
	return float(v) if (v is int or v is float) else fallback


func _lock_is_ours() -> bool:
	if token == "":
		return false
	var l: Dictionary = _read_json(lock_path())
	return bool(l.ok) and String((l.data as Dictionary).get("token", "")) == token


func _write_lock(now: float) -> void:
	var f: FileAccess = FileAccess.open(lock_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"pid": OS.get_process_id(), "token": token, "heartbeat_unix": now}, "", true, true))
	f.close()


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "data": {}, "error": "missing"}
	var text: String = FileAccess.get_file_as_string(path)
	if text.strip_edges() == "":
		return {"ok": false, "data": {}, "error": "empty"}
	var j: JSON = JSON.new()
	if j.parse(text) != OK:
		return {"ok": false, "data": {}, "error": "parse:%d" % j.get_error_line()}
	if not (j.data is Dictionary):
		return {"ok": false, "data": {}, "error": "not_object"}
	return {"ok": true, "data": j.data, "error": ""}
