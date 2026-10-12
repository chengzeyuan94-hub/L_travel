extends RefCounted
## Act 4 UI tests: builds a realistic save by running the real loop (LshuClock.resolve on the real
## pool) live, every 150 s, from a first launch through ~2 days, then one long absence so a catchup
## event with the 「你不在的时候」 card comes out. Every postcard gets a stand-in JPG: an existing
## render of that tile / band from the report folders when one is there (harness), or a small
## generated gradient (headless tests). Tile ids are read at run time; none is written here.

const LshuClock := preload("res://scripts/traveler/lshu/loop/lshu_clock.gd")
const LshuSave := preload("res://scripts/traveler/lshu/loop/lshu_save.gd")
const LshuPoolAdapter := preload("res://scripts/traveler/lshu/loop/lshu_pool_adapter.gd")
const S := preload("res://scripts/traveler/lshu/ui/lshu_ui_style.gd")
const D := preload("res://scripts/traveler/lshu/ui/lshu_ui_data.gd")

const TZ_MIN: int = 480
const STEP_S: float = 150.0
const RENDER_DIRS: Array[String] = [
	"res://docs/reports/traveler-lshu-20260923/l1_final_%s_%s.png",
	"res://docs/reports/traveler-lshu-p0-20260923/matrix/%s_%s.png",
]


static func local_unix(y: int, mo: int, d: int, h: int, mi: int) -> int:
	return int(Time.get_unix_time_from_datetime_dict({"year": y, "month": mo, "day": d, "hour": h, "minute": mi, "second": 0})) - TZ_MIN * 60


## Renders on disk for a tile / band (absolute path) or "" when none. The 2026-09-23 report folder
## is preferred (it no longer changes); the P0 matrix folder is only used when the PNG is complete
## (ends with its IEND chunk), because another job may be rewriting it while this runs.
static func render_path(tile: String, band: String) -> String:
	for fmt: String in RENDER_DIRS:
		for b: String in [band, "day", "sunset", "morning", "night"]:
			var p: String = ProjectSettings.globalize_path(fmt % [tile, b])
			if FileAccess.file_exists(p) and png_complete(p):
				return p
	return ""


static func png_complete(path: String) -> bool:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var n: int = f.get_length()
	if n < 64:
		return false
	var head: PackedByteArray = f.get_buffer(8)
	f.seek(n - 8)
	var tail: PackedByteArray = f.get_buffer(8)
	f.close()
	return head.size() == 8 and head[1] == 0x50 and head[2] == 0x4E and head[3] == 0x47 \
		and tail.size() == 8 and tail[0] == 0x49 and tail[1] == 0x45 and tail[2] == 0x4E and tail[3] == 0x44


## Returns {cfg, places, save, catchup_r, arrive_r, times:{...}, images:{rendered, generated}}.
## use_renders: true = crop existing renders into 3:2 JPGs; false = small generated JPGs.
static func build(out_dir: String, use_renders: bool, seed: int = 20260924) -> Dictionary:
	var cfg: Dictionary = LshuClock.load_config()
	cfg["tz_offset_minutes"] = TZ_MIN
	var places: Array = LshuPoolAdapter.load_places()
	DirAccess.make_dir_recursive_absolute(out_dir)
	# stand-in images from an earlier run are rebuilt (only this folder's own .jpg files)
	for f: String in DirAccess.get_files_at(out_dir):
		if f.begins_with("pc_") and f.ends_with(".jpg"):
			DirAccess.remove_absolute(out_dir.path_join(f))
	var t0: int = local_unix(2026, 9, 21, 7, 50)
	var t_live_end: int = local_unix(2026, 9, 23, 10, 0)
	var t_back: int = local_unix(2026, 9, 23, 16, 40)
	var save: Dictionary = {"seed": seed}
	var arrive_r: Dictionary = {}
	var stats: Dictionary = {"rendered": 0, "generated": 0, "calls": 0}
	var t: float = float(t0)
	while t < float(t_live_end):
		var r: Dictionary = LshuClock.resolve(save, t, places, cfg)
		stats.calls = int(stats.calls) + 1
		if not bool(r.ok):
			break
		save = r.save
		for e: Variant in r.events:
			var ev: Dictionary = e
			if String(ev.type) == "postcard":
				_render(save, String(ev.postcard), out_dir, use_renders, stats)
			elif String(ev.type) == "arrive" and D.tile_city(String(ev.tile)) != "" and D.city_epithet(D.tile_city(String(ev.tile))) != "":
				arrive_r = r
		t += STEP_S
	# postcards before the absence: all read except the newest two
	var pcs: Array = save.postcards
	for i: int in pcs.size():
		if i < pcs.size() - 2:
			(pcs[i] as Dictionary)["read"] = true
	var rc: Dictionary = LshuClock.resolve(save, float(t_back), places, cfg)
	save = rc.save
	for id: Variant in (save.pending_renders as Array).duplicate():
		_render(save, String(id), out_dir, use_renders, stats)
	var unread_ids: Array = []
	for v: Variant in LshuSave.unread(save):
		unread_ids.append(String((v as Dictionary).id))
	return {"cfg": cfg, "places": places, "save": save, "catchup_r": rc, "arrive_r": arrive_r, "unread_ids": unread_ids,
		"times": {"t0": t0, "live_end": t_live_end, "back": t_back}, "images": stats}


## Puts the read flags back to how build() left them (the harness reads cards in every phase).
static func reset_unread(d: Dictionary) -> void:
	var ids: Array = d.get("unread_ids", []) as Array
	for v: Variant in (d.save as Dictionary).postcards as Array:
		var pc: Dictionary = v
		pc["read"] = not ids.has(String(pc.id))


static func catchup_event(rc: Dictionary) -> Dictionary:
	for e: Variant in rc.get("events", []) as Array:
		if String((e as Dictionary).get("type", "")) == "catchup":
			return e
	return {}


static func _render(save: Dictionary, id: String, out_dir: String, use_renders: bool, stats: Dictionary) -> void:
	var pc: Dictionary = LshuSave.find_postcard(save, id)
	if pc.is_empty():
		return
	var path: String = out_dir.path_join(id + ".jpg")
	if not FileAccess.file_exists(path):
		var img: Image = null
		if use_renders:
			var src: String = render_path(String(pc.tile), String(pc.band))
			if src != "":
				img = Image.load_from_file(src)
				if img != null and not img.is_empty():
					var h: int = img.get_height()
					var w: int = mini(img.get_width(), roundi(h * 1.5))
					img = img.get_region(Rect2i((img.get_width() - w) / 2, 0, w, h))
					img.resize(1500, 1000, Image.INTERPOLATE_LANCZOS)
					stats.rendered = int(stats.rendered) + 1
		if img == null or img.is_empty():
			img = placeholder(String(pc.get("biome", "")), String(pc.get("band", "")), Vector2i(600, 400) if use_renders else Vector2i(150, 100))
			stats.generated = int(stats.generated) + 1
		img.save_jpg(path, 0.88)
	LshuSave.complete_render(save, id, path)


## Simple gradient landscape as a stand-in postcard image (soft edges, no aliasing).
static func placeholder(biome: String, band: String, sz: Vector2i) -> Image:
	var pal: Dictionary = S.stamp_palette(biome, band)
	var img: Image = Image.create(sz.x, sz.y, false, Image.FORMAT_RGB8)
	var aa: float = 1.5 / float(sz.y)
	for y: int in sz.y:
		var fy: float = float(y) / float(sz.y)
		for x: int in sz.x:
			var fx: float = float(x) / float(sz.x)
			var ridge: float = 0.60 + 0.10 * sin(fx * 5.0 + 0.6) + 0.04 * sin(fx * 13.0)
			var near: float = ridge + 0.17 + 0.05 * sin(fx * 8.0 + 2.0)
			var c: Color = (pal.sky as Color).lerp(Color.WHITE, 0.18 * fy)
			c = c.lerp(pal.far as Color, clampf((fy - ridge) / aa + 0.5, 0.0, 1.0))
			c = c.lerp(pal.near as Color, clampf((fy - near) / aa + 0.5, 0.0, 1.0))
			img.set_pixel(x, y, c)
	return img
