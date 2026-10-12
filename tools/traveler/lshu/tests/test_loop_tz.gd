extends SceneTree
## Act 4 loop: the system time zone the clock uses must match the local wall clock.
## run_loop_tests.sh runs this under several TZ values, including negative half-hour zones
## (America/St_Johns, Pacific/Marquesas) where Time.get_time_zone_from_system().bias is off by an hour.
## Prints one line: LSHU_LOOP_TZ tz=<TZ> offset_min=<n> local=<HH:MM> system=<HH:MM> ok=<bool>

const LshuClock := preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")


func _init() -> void:
	var cfg: Dictionary = LshuClock.load_config()
	cfg["tz_offset_minutes"] = null
	var ok: bool = false
	var info: Dictionary = {}
	var sys: Dictionary = {}
	var c: Dictionary = {}
	# Retry once if the minute ticks over between the two reads.
	for attempt: int in 2:
		c = LshuClock.compile_config(cfg)
		var now: float = Time.get_unix_time_from_system()
		info = LshuClock.local_info(now, c)
		sys = Time.get_datetime_dict_from_system()
		ok = int(info.hour) == int(sys.hour) and int(info.minute) == int(sys.minute) and int(info.day) == int(sys.day)
		if ok:
			break
	print("LSHU_LOOP_TZ tz=%s offset_min=%d local=%s system=%02d:%02d ok=%s"
		% [OS.get_environment("TZ"), int(c.tz_s) / 60, String(info.time_label), int(sys.hour), int(sys.minute), str(ok)])
	quit(0 if ok else 1)
