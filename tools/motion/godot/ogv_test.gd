extends Control
## Playback proof for the in-game intro films (.ogv = Theora video + Vorbis audio) in Godot 4.7.
## tools/motion/godot/ogv_test.tscn, run by tools/motion/godot/ogv_test.sh (see tools/motion/README.md).
##
## Args (after --):
##   --ogv=<res:// or absolute path>   the film; res:// paths go through load() exactly like game code would
##   --ogg=<path>                      optional: play this Vorbis file in sync as the audio (fallback path)
##   --report=<abs json>               where to write the measurements
##   --baseline                        same window and loop, no video (CPU baseline)
##   --seconds=<s>                     baseline length / safety timeout (default 20)
## Measures per frame: stream_position, is_playing, the "IntroVideo" bus peak (audio really flows), the
## main-loop process time; and when `finished` fires. Audio is routed to the named bus IntroVideo.

var player: VideoStreamPlayer
var ogg_player: AudioStreamPlayer
var report_path := ""
var baseline := false
var limit_s := 20.0
var t := 0.0
var started_usec := 0
var samples: Array = []
var finished_at := -1.0
var peak_max := -200.0
var frames_with_audio := 0
var frames := 0
var proc_ms: Array[float] = []
var bus_idx := -1
var stream_length := 0.0
var last_pos := -1.0
var pos_advances := 0
var quit_at := -1.0


func _ready() -> void:
	var ogv := ""
	var ogg := ""
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--ogv="):
			ogv = a.trim_prefix("--ogv=")
		elif a.begins_with("--ogg="):
			ogg = a.trim_prefix("--ogg=")
		elif a.begins_with("--report="):
			report_path = a.trim_prefix("--report=")
		elif a == "--baseline":
			baseline = true
		elif a.begins_with("--seconds="):
			limit_s = float(a.trim_prefix("--seconds="))
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	AudioServer.add_bus()
	bus_idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(bus_idx, "IntroVideo")
	AudioServer.set_bus_send(bus_idx, "Master")
	if not baseline:
		player = VideoStreamPlayer.new()
		var stream: VideoStream
		if ogv.begins_with("res://"):
			stream = load(ogv)
		else:
			var th := VideoStreamTheora.new()
			th.file = ogv
			stream = th
		if stream == null:
			_finish("could not load " + ogv)
			return
		player.stream = stream
		player.bus = "IntroVideo"
		player.expand = true
		player.volume_db = 0.0
		add_child(player)
		player.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		player.finished.connect(func() -> void:
			finished_at = float(Time.get_ticks_usec() - started_usec) / 1e6
			quit_at = t + 0.5)
		if not ogg.is_empty():
			ogg_player = AudioStreamPlayer.new()
			ogg_player.stream = AudioStreamOggVorbis.load_from_file(ogg)
			ogg_player.bus = "IntroVideo"
			add_child(ogg_player)
		player.play()
		if ogg_player != null:
			ogg_player.play()
		stream_length = player.get_stream_length()
	started_usec = Time.get_ticks_usec()
	print("OGV_TEST_START ", JSON.stringify({"ogv": ogv, "ogg": ogg, "baseline": baseline, "stream_length": stream_length}))


func _process(delta: float) -> void:
	t += delta
	frames += 1
	proc_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	var peak := maxf(AudioServer.get_bus_peak_volume_left_db(bus_idx, 0), AudioServer.get_bus_peak_volume_right_db(bus_idx, 0))
	peak_max = maxf(peak_max, peak)
	if peak > -60.0:
		frames_with_audio += 1
	if player != null:
		var pos := player.stream_position
		if pos > last_pos + 0.0001:
			pos_advances += 1
		last_pos = pos
		if frames % 15 == 0:
			samples.append({"wall_s": snappedf(float(Time.get_ticks_usec() - started_usec) / 1e6, 0.001), "pos": snappedf(pos, 0.001), "playing": player.is_playing(), "peak_db": snappedf(peak, 0.1)})
	if (quit_at >= 0.0 and t >= quit_at) or t >= limit_s:
		_finish("")


func _finish(err: String) -> void:
	set_process(false)
	var sorted := proc_ms.duplicate()
	sorted.sort()
	var wall := float(Time.get_ticks_usec() - started_usec) / 1e6
	var r := {
		"error": err, "baseline": baseline, "godot": Engine.get_version_info().string,
		"stream_length_s": stream_length, "finished_at_wall_s": finished_at, "wall_s": wall,
		"frames": frames, "fps_avg": frames / maxf(0.001, wall), "position_advances": pos_advances,
		"last_position_s": last_pos, "audio_peak_max_db": peak_max, "frames_with_audio": frames_with_audio,
		"bus": "IntroVideo", "audio_driver": AudioServer.get_driver_name(), "mix_rate": AudioServer.get_mix_rate(),
		"process_ms": {"avg": _avg(proc_ms), "p50": sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0,
			"p95": sorted[int(sorted.size() * 0.95)] if not sorted.is_empty() else 0.0, "max": sorted[-1] if not sorted.is_empty() else 0.0},
		"samples": samples,
	}
	if not report_path.is_empty():
		var f := FileAccess.open(report_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(r, "  "))
		f.close()
	print("OGV_TEST_DONE ", JSON.stringify(r).substr(0, 600))
	get_tree().quit(0 if err.is_empty() else 1)


static func _avg(a: Array[float]) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(1.0, a.size())
