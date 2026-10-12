extends Node
## Act 4 「L叔在哪儿」 UI harness (windowed; screenshots need a real renderer).
##   /Applications/Godot.app/Contents/MacOS/Godot --path <project> res://tools/traveler/lshu/tests/ui_harness.tscn
## Builds a real save with the loop (ui_sample_data.gd), puts the UI over a render of the scene in a
## SubViewport that reproduces the project's canvas_items stretch (1280x720 base, expand), drives it
## through real input events (clicks, key L, Esc) and API calls, and writes into
## docs/reports/traveler-lshu-ui-20260924/:
##   ui_caption.png ui_stamp.png ui_postcard_front.png ui_postcard_back.png ui_book.png ui_away.png
##   (1920x1080), the same states at 3440x1440 and 640x360 (*_3440x1440.png, *_640x360.png),
##   ui_sheet.png (contact sheet) and ui_harness_report.json.
## Prints LSHU_UI_HARNESS errors=N warnings=W checks=C failed=F; exit code 0 only when both are 0.
## The window parks at slot 10 (400x225, see tools/traveler/lookdev_panti/panti_overlay.gd _park).

const Sample := preload("res://tools/traveler/lshu/tests/ui_sample_data.gd")
const UiScript := preload("res://scripts/traveler/lshu/ui/lshu_ui.gd")
const LshuSave := preload("res://scripts/traveler/lshu/loop/lshu_save.gd")
const D := preload("res://scripts/traveler/lshu/ui/lshu_ui_data.gd")

const OUT_DIR: String = "res://docs/reports/traveler-lshu-ui-20260924"
const PARK_SLOT: int = 10
const BASE: Vector2 = Vector2(1280.0, 720.0)


class HarnessLogger extends Logger:
	var mutex: Mutex = Mutex.new()
	var errors: int = 0
	var warnings: int = 0
	var samples: Array = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		mutex.lock()
		if error_type == ERROR_TYPE_WARNING:
			warnings += 1
		else:
			errors += 1
		if samples.size() < 30:
			samples.append("%s %s:%d %s %s" % ["W" if error_type == ERROR_TYPE_WARNING else "E", file, line, code, rationale if rationale != "" else function])
		mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass


var logger: HarnessLogger = HarnessLogger.new()
var sv: SubViewport
var backdrop: TextureRect
var ui: CanvasLayer
var data: Dictionary = {}
var checks: Array = []
var failed: int = 0
var shots: Array = []
var states: Dictionary = {}
var signals_seen: Array = []
var out_abs: String = ""


func _ready() -> void:
	OS.add_logger(logger)
	_park(PARK_SLOT)
	out_abs = ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(out_abs)
	_run.call_deferred()


func _park(slot: int) -> void:
	var wid: int = DisplayServer.MAIN_WINDOW_ID
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen(wid))
	var size: Vector2i = Vector2i(400, 225)
	DisplayServer.window_set_size(size, wid)
	DisplayServer.window_set_position(usable.position + usable.size - Vector2i((slot % 4 + 1) * (size.x + 8), (slot / 4 + 1) * (size.y + 36)), wid)


func _run() -> void:
	var t_build: int = Time.get_ticks_msec()
	data = Sample.build(ProjectSettings.globalize_path("user://lshu_ui_harness/postcards"), true)
	var build_ms: int = Time.get_ticks_msec() - t_build
	var save: Dictionary = data.save
	_check("sample_save_built", not save.is_empty() and (save.postcards as Array).size() >= 6,
		"postcards=%d log=%d images=%s build_ms=%d" % [(save.postcards as Array).size(), (save.log as Array).size(), JSON.stringify(data.images), build_ms])
	_setup_viewport()
	ui.call("configure", data.cfg, data.places)
	ui.connect("postcard_read", _on_read)
	ui.connect("postcard_opened", func(id: String) -> void: signals_seen.append("opened:" + id))
	ui.connect("book_toggled", func(o: bool) -> void: signals_seen.append("book:" + str(o)))

	await _phase(Vector2i(1920, 1080), "", true)
	await _phase(Vector2i(3440, 1440), "_3440x1440", false)
	await _phase(Vector2i(640, 360), "_640x360", false)
	_contact_sheet()

	var report: Dictionary = {
		"schema": "lshu.ui_harness.v1", "godot": Engine.get_version_info().string,
		"errors": logger.errors, "warnings": logger.warnings, "log_samples": logger.samples,
		"checks": checks, "checks_failed": failed, "shots": shots, "states": states, "signals": signals_seen,
		"sample": {"postcards": (save.postcards as Array).size(), "log_rows": (save.log as Array).size(),
			"unread_end": LshuSave.unread(save).size(), "images": data.images, "build_ms": build_ms},
		"images_cache": {"loads": ui.get("images").get("loads"), "failures": ui.get("images").get("failures")},
	}
	var f: FileAccess = FileAccess.open(out_abs.path_join("ui_harness_report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	print("LSHU_UI_HARNESS errors=%d warnings=%d checks=%d failed=%d" % [logger.errors, logger.warnings, checks.size(), failed])
	get_tree().quit(0 if logger.errors == 0 and failed == 0 else 1)


func _setup_viewport() -> void:
	sv = SubViewport.new()
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = false
	sv.size_2d_override_stretch = true
	add_child(sv)
	backdrop = TextureRect.new()
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	sv.add_child(backdrop)
	ui = UiScript.new()
	sv.add_child(ui)


## Reproduces the root window under the project's stretch settings: canvas_items, 1280x720, expand.
func _set_resolution(px: Vector2i) -> void:
	var k: float = minf(float(px.x) / BASE.x, float(px.y) / BASE.y)
	var logical: Vector2i = Vector2i(roundi(px.x / k), roundi(px.y / k))
	sv.size = px
	sv.size_2d_override = logical
	await _frames(3)


func _phase(res: Vector2i, suffix: String, full: bool) -> void:
	var tag: String = "%dx%d" % [res.x, res.y]
	await _set_resolution(res)
	Sample.reset_unread(data)
	var save: Dictionary = data.save
	var arrive_r: Dictionary = data.arrive_r
	var leg: Dictionary = arrive_r.get("leg", {}) as Dictionary
	_set_backdrop(String(leg.get("tile", "")), String((arrive_r.get("light", {}) as Dictionary).get("band", "day")))
	ui.call("hide_caption")
	ui.call("set_unread", [])
	await _wait(0.8)
	# --- idle: nothing on screen
	ui.visible = false
	await _frames(3)
	var bare: Image = sv.get_texture().get_image()
	ui.visible = true
	await _frames(3)
	var idle_img: Image = sv.get_texture().get_image()
	_check("idle_nothing_on_screen_" + tag, _max_diff(bare, idle_img) == 0.0 and not bool(ui.call("is_any_visible")),
		"max pixel diff vs no UI = %.4f" % _max_diff(bare, idle_img))
	# --- caption via the real resolve() result of an arrival (apply_resolve -> arrive event)
	ui.call("apply_resolve", arrive_r)
	ui.call("set_unread", [])
	await _wait(1.9)
	var st: Dictionary = ui.call("state")
	_check("caption_shown_" + tag, bool((st.caption as Dictionary).showing) and String((st.caption as Dictionary).title) == String(leg.name),
		"title=%s sub=%s" % [(st.caption as Dictionary).title, (st.caption as Dictionary).sub])
	_check("caption_inside_" + tag, _inside((st.caption as Dictionary).rect, st.viewport), str((st.caption as Dictionary).rect))
	if full:
		_check("caption_hold_12s", absf(float((st.caption as Dictionary).hold_left) + 1.9 - 12.0) < 0.3, "hold_left=%.2f after 1.9 s" % float((st.caption as Dictionary).hold_left))
	await _shot("ui_caption" + suffix)
	# --- stamp only
	ui.call("hide_caption")
	ui.call("set_save", save)
	var unread: Array = LshuSave.unread(save)
	ui.call("set_unread", unread)
	await _wait(1.0)
	st = ui.call("state")
	_check("stamp_shown_" + tag, bool((st.stamp as Dictionary).visible) and int((st.stamp as Dictionary).unread) == unread.size() and unread.size() > 0,
		"unread=%d rect=%s" % [unread.size(), str((st.stamp as Dictionary).rect)])
	_check("stamp_inside_" + tag, _inside((st.stamp as Dictionary).rect, st.viewport), str((st.stamp as Dictionary).rect))
	if full:
		await _shot("ui_stamp")
	# --- click the stamp -> front
	var first_id: String = String((unread[0] as Dictionary).id)
	_push_click(_center((st.stamp as Dictionary).rect))
	await _wait(1.1)
	st = ui.call("state")
	var vw: Dictionary = st.viewer
	var cr: Array = vw.card_rect
	_check("stamp_click_opens_oldest_unread_" + tag, bool(vw.open) and String(vw.id) == first_id and not bool(vw.back), "id=%s" % vw.id)
	_check("card_3x2_" + tag, absf(float(cr[2]) / float(cr[3]) - 1.5) < 0.01 and _inside(cr, st.viewport),
		"card=%s aspect=%.3f height_frac=%.3f" % [str(cr), float(cr[2]) / float(cr[3]), float(cr[3]) / float((st.viewport as Array)[1])])
	if full:
		await _shot("ui_postcard_front")
	# --- click the card -> back
	_push_click(_center(cr))
	await _wait(0.8)
	st = ui.call("state")
	_check("card_click_flips_" + tag, bool((st.viewer as Dictionary).back), "")
	await _shot("ui_postcard_back" + suffix)
	# --- click empty space -> flies back, read
	var reads_before: int = _count_prefix("read:")
	_push_click(Vector2(6.0, 6.0))
	await _wait(1.0)
	st = ui.call("state")
	_check("empty_click_closes_and_reads_" + tag, not bool((st.viewer as Dictionary).open) and _count_prefix("read:") == reads_before + 1
		and signals_seen.has("read:" + first_id) and int((st.stamp as Dictionary).unread) == unread.size() - 1,
		"unread now=%d" % int((st.stamp as Dictionary).unread))
	ui.call("set_unread", LshuSave.unread(save))
	# --- key L -> travel book
	ui.call("hide_caption")
	_push_key(KEY_L)
	await _wait(0.9)
	var t_img: int = Time.get_ticks_msec()
	while int(ui.get("images").call("pending")) > 0 and Time.get_ticks_msec() - t_img < 4000:
		await _frames(1)
	await _wait(0.3)
	st = ui.call("state")
	var bk: Dictionary = st.book
	_check("key_L_opens_book_" + tag, bool(bk.open) and int(bk.trips_shown) >= 2 and int(bk.thumbs) >= 3 and _inside(bk.rect, st.viewport),
		"trips=%d thumbs=%d rect=%s" % [int(bk.trips_shown), int(bk.thumbs), str(bk.rect)])
	await _shot("ui_book" + suffix)
	if full:
		# a thumbnail click opens that postcard over the book, Esc puts it back, L closes the book
		var th: Array = ui.call("book_control").call("thumbs")
		var tctl: Control = th[0]
		var rec: Dictionary = tctl.get("record")
		_push_click(tctl.get_global_rect().get_center())
		await _wait(1.0)
		st = ui.call("state")
		_check("book_thumb_opens_postcard", bool((st.viewer as Dictionary).open) and String((st.viewer as Dictionary).id) == String(rec.id), "id=%s" % rec.id)
		await _shot("ui_book_postcard")
		_push_key(KEY_ESCAPE)
		await _wait(0.8)
		st = ui.call("state")
		_check("esc_closes_postcard_keeps_book", not bool((st.viewer as Dictionary).open) and bool((st.book as Dictionary).open), "")
	_push_key(KEY_L)
	await _wait(0.7)
	st = ui.call("state")
	_check("key_L_closes_book_" + tag, not bool((st.book as Dictionary).open) and not bool((st.book as Dictionary).visible), "")
	# --- while you were away
	var rc: Dictionary = data.catchup_r
	var cleg: Dictionary = rc.leg
	_set_backdrop(String(cleg.tile), String((rc.light as Dictionary).get("band", "day")))
	ui.call("hide_caption")
	ui.call("set_unread", [])
	ui.call("apply_resolve", rc)
	ui.call("hide_caption")
	ui.call("set_unread", [])
	await _wait(1.4)
	st = ui.call("state")
	var ev: Dictionary = Sample.catchup_event(rc)
	_check("away_card_from_catchup_" + tag, bool((st.away as Dictionary).showing) and bool(ev.get("show_away_card", false))
		and (ev.places as Array).size() >= 1 and _inside((st.away as Dictionary).rect, st.viewport),
		"gap_h=%.1f places=%d postcards=%d rect=%s" % [float(ev.gap_s) / 3600.0, (ev.places as Array).size(), (ev.postcards as Array).size(), str((st.away as Dictionary).rect)])
	await _shot("ui_away" + suffix)
	ui.call("hide_away")
	await _wait(1.0)
	states[tag] = ui.call("state")


# ------------------------------------------------------------------------------ helpers

## What the director does on postcard_read: mark it in the latest save.
func _on_read(id: String) -> void:
	signals_seen.append("read:" + id)
	LshuSave.mark_read(data.save as Dictionary, id)


func _set_backdrop(tile: String, band: String) -> void:
	var p: String = Sample.render_path(tile, band)
	if p == "":
		backdrop.texture = ImageTexture.create_from_image(Sample.placeholder("", band, Vector2i(640, 360)))
		return
	backdrop.texture = ImageTexture.create_from_image(Image.load_from_file(p))


func _push_click(pos: Vector2) -> void:
	var mv: InputEventMouseMotion = InputEventMouseMotion.new()
	mv.position = pos
	mv.global_position = pos
	sv.push_input(mv, true)
	for pressed: bool in [true, false]:
		var mb: InputEventMouseButton = InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = pressed
		mb.position = pos
		mb.global_position = pos
		sv.push_input(mb, true)


func _push_key(code: Key) -> void:
	for pressed: bool in [true, false]:
		var k: InputEventKey = InputEventKey.new()
		k.keycode = code
		k.physical_keycode = code
		k.pressed = pressed
		sv.push_input(k, true)


func _shot(name_base: String) -> void:
	await _frames(3)
	var img: Image = sv.get_texture().get_image()
	var path: String = out_abs.path_join(name_base + ".png")
	var err: int = img.save_png(path)
	shots.append({"file": name_base + ".png", "size": [img.get_width(), img.get_height()], "error": err})
	_check("shot_" + name_base, err == OK, "%dx%d" % [img.get_width(), img.get_height()])


func _contact_sheet() -> void:
	var names: Array[String] = ["ui_caption", "ui_stamp", "ui_postcard_front", "ui_postcard_back", "ui_book", "ui_away"]
	var cell: Vector2i = Vector2i(960, 540)
	var sheet: Image = Image.create(cell.x * 3, cell.y * 2, false, Image.FORMAT_RGB8)
	sheet.fill(Color(0.95, 0.93, 0.89))
	for i: int in names.size():
		var img: Image = Image.load_from_file(out_abs.path_join(names[i] + ".png"))
		if img == null or img.is_empty():
			continue
		img.convert(Image.FORMAT_RGB8)
		img.resize(cell.x - 8, cell.y - 8, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i((i % 3) * cell.x + 4, (i / 3) * cell.y + 4))
	var err: int = sheet.save_png(out_abs.path_join("ui_sheet.png"))
	_check("contact_sheet", err == OK, "ui_sheet.png")


func _max_diff(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size():
		return 1.0
	var m: float = 0.0
	var w: int = a.get_width()
	var h: int = a.get_height()
	for y: int in range(0, h, 3):
		for x: int in range(0, w, 3):
			var ca: Color = a.get_pixel(x, y)
			var cb: Color = b.get_pixel(x, y)
			m = maxf(m, maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b))))
	return m


func _inside(rect: Variant, vp: Variant) -> bool:
	var r: Array = rect
	var v: Array = vp
	return float(r[0]) >= -0.5 and float(r[1]) >= -0.5 and float(r[0]) + float(r[2]) <= float(v[0]) + 0.5 and float(r[1]) + float(r[3]) <= float(v[1]) + 0.5


func _center(rect: Variant) -> Vector2:
	var r: Array = rect
	return Vector2(float(r[0]) + float(r[2]) * 0.5, float(r[1]) + float(r[3]) * 0.5)


func _count_prefix(p: String) -> int:
	var n: int = 0
	for s: Variant in signals_seen:
		if String(s).begins_with(p):
			n += 1
	return n


func _check(name_value: String, ok: bool, detail: String) -> void:
	checks.append({"name": name_value, "ok": ok, "detail": detail})
	if not ok:
		failed += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", name_value, detail])


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _frames(n: int) -> void:
	for _i: int in n:
		await RenderingServer.frame_post_draw
