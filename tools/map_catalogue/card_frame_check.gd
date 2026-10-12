extends Node
## 「旅行L叔」 map-editor catalogue — city-card art checked inside the REAL card frame.
##
## Instantiates the shipped FormalCityCard (scenes/ui/components/formal_city_card.tscn) at its full design size
## (1086 x 1448) and binds it through FormalCardPresentationResolver.resolve_city_card() like the game does: a shipped
## city of the same starting transport supplies the rule fields (map attribute, grant layout, ribbon), and the
## archetype's own data replaces the rest: display name, epithet, intro / scenery from the catalogue templates, the
## starting transport, and the illustration - the runtime card image read from disk at run time (Image.load_from_file,
## so a freshly generated card is checked without a Godot import), the specialty's 3D icon the same way.
## Every card variant of the archetype (camel / ship, catalogue card_scene.renders_needed) goes side by side into
##   art-src/custom-map-catalogue/cards/_review/<id>_card_frame_godot.png
## with a zoom row under it: the glasses-badge corner and the epithet strip of each variant at 2x.
## What to look at: the glasses badge (top-left 12.3 % x 15.3 % of the art) must cover only sky; the epithet
## strip (the art's bottom 8.6 % between 9.8 % and 90.2 % of the width) must not cover L叔's boots, the camel's feet
## or the boat's sail and bundles. The coverage rectangles are printed as CARD_FRAME_CHECK json.
##
## Needs a real renderer (a --headless run saves blank images):
##   HOME=<scratch>/godot_home /Applications/Godot.app/Contents/MacOS/Godot --path <repo> --audio-driver Dummy \
##       --resolution 480x270 res://tools/map_catalogue/card_frame_check.tscn -- --id=kiln_town --name=景德镇 \
##       [--epithet=窑火千年不熄的瓷都] [--specialty=kaolin] [--out=<png>]

const CATALOGUE := "res://docs/design/map-editor-20260930/work/catalogue/catalogue.json"
const CARD_DIR := "res://assets/custom_map_catalogue/cards/"
const ICON_DIR := "res://assets/game/ui/lshu_3d/icons/"
const REVIEW_DIR := "res://art-src/custom-map-catalogue/cards/_review/"
const CARD_SCENE := "res://scenes/ui/components/formal_city_card.tscn"
const DESIGN := Vector2i(1086, 1448)
const GAP := 24
const ZOOM := 2
# a shipped city per starting transport: it supplies the rule-side fields only (attribute text, grant slot)
const BASE_CITY := {"CAMEL": "changan", "SHIP": "quanzhou"}
const TRANSPORT_OF := {"CAMEL": "camel", "BOAT": "ship"}

var aid := ""
var city_name := ""
var epithet := ""
var specialty := ""
var out_path := ""


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--id="):
			aid = arg.trim_prefix("--id=")
		elif arg.begins_with("--name="):
			city_name = arg.trim_prefix("--name=")
		elif arg.begins_with("--epithet="):
			epithet = arg.trim_prefix("--epithet=")
		elif arg.begins_with("--specialty="):
			specialty = arg.trim_prefix("--specialty=")
		elif arg.begins_with("--out="):
			out_path = arg.trim_prefix("--out=")
	if aid == "":
		push_error("need --id=<archetype id>")
		get_tree().quit(1)
		return
	var cat: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CATALOGUE))
	var arch: Dictionary = {}
	for a: Dictionary in cat.archetypes:
		if a.id == aid:
			arch = a
	if arch.is_empty():
		push_error("archetype %s not in the catalogue" % aid)
		get_tree().quit(1)
		return
	if city_name == "":
		city_name = String(arch.name_zh)
	if epithet == "":
		epithet = "%s的新城" % String(arch.name_zh)
	if specialty == "":
		specialty = String(arch.recommended_specialty)
	var spec_name := specialty
	for s: Dictionary in cat.specialties:
		if s.id == specialty:
			spec_name = String(s.name_zh)
	if out_path == "":
		out_path = ProjectSettings.globalize_path(REVIEW_DIR + aid + "_card_frame_godot.png")
	var content: Dictionary = GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	var ph := String(arch.get("template_placeholder", "{城名}"))
	var intro := String(arch.intro_template).replace(ph, city_name)
	var scenery := String(arch.scenery_template).replace(ph, city_name)
	var icon_tex := _runtime_texture(ICON_DIR + specialty + ".png")

	var variants: Array = []
	for r in arch.card_scene.renders_needed:
		var transport: String = TRANSPORT_OF[String(r)]
		variants.append({"transport": "SHIP" if transport == "ship" else "CAMEL",
			"card": CARD_DIR + "%s_%s_1024x768.png" % [aid, transport]})

	var vp := SubViewport.new()
	vp.size = Vector2i(DESIGN.x * variants.size() + GAP * (variants.size() + 1), DESIGN.y + GAP * 2)
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var bg := ColorRect.new()
	bg.color = Color(0.93, 0.91, 0.87)
	bg.size = Vector2(vp.size)
	vp.add_child(bg)
	var report := {"id": aid, "name": city_name, "variants": []}
	var card_scene := load(CARD_SCENE) as PackedScene
	for i in variants.size():
		var v: Dictionary = variants[i]
		var art_tex := _runtime_texture(v.card)
		var resolved := FormalCardPresentationResolver.resolve_city_card(content, String(BASE_CITY[v.transport]))
		if not bool(resolved.get("success", false)):
			push_error("base city resolve failed: %s" % resolved.get("reason", ""))
			get_tree().quit(1)
			return
		resolved = resolved.duplicate(true)
		resolved.city_id = "custom_" + aid
		resolved.display_name = city_name
		resolved.epithet = epithet
		resolved.intro = intro
		resolved.scenery = scenery
		resolved.starting_transport = v.transport
		resolved.card_number = 17
		resolved.illustration_path = ""          # the art comes from disk below, not from an imported resource
		resolved.art_review_status = ""
		resolved.lore_verification_status = ""
		resolved.starting_grant = {"entries": [{"resource_kind": "GOOD", "resource_id": specialty, "quantity": 1}]}
		var card := card_scene.instantiate() as FormalCityCard
		card.position = Vector2(GAP + i * (DESIGN.x + GAP), GAP)
		vp.add_child(card)
		card.size = Vector2(DESIGN)
		card.bind_resolved(resolved, content)
		# the runtime card image and the specialty icon, exactly where bind_resolved would have put them
		card._art.texture = art_tex
		card._art_missing.visible = art_tex == null
		if icon_tex != null:
			card._grant_icon.texture = icon_tex
		card._grant_text.text = "起始资源 · %s ×1" % spec_name
		report.variants.append({"transport": v.transport, "card": v.card, "loaded": art_tex != null,
			"art_size": [art_tex.get_width(), art_tex.get_height()] if art_tex != null else []})
	for f in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var shot := vp.get_texture().get_image()
	shot.convert(Image.FORMAT_RGBA8)

	# coverage of the art by the frame parts, in art-normalised coordinates (formal_city_card.gd rects)
	var art: Rect2 = FormalCityCard.ART_RECT
	var cover := {}
	for key in ["BADGE_RECT", "HIGHLIGHT_RECT", "EPITHET_RECT"]:
		var r := _rect(key)
		var o := r.intersection(art)
		cover[key] = {"x0": snappedf((o.position.x - art.position.x) / art.size.x, 0.001),
			"x1": snappedf((o.end.x - art.position.x) / art.size.x, 0.001),
			"y0": snappedf((o.position.y - art.position.y) / art.size.y, 0.001),
			"y1": snappedf((o.end.y - art.position.y) / art.size.y, 0.001)}
	report["art_covered_by"] = cover

	# zoom row: badge corner and epithet strip of every variant at ZOOM x
	var badge_crop := Rect2i(Vector2i(60, 190), Vector2i(360, 260))
	var strip_crop := Rect2i(Vector2i(120, 700), Vector2i(846, 300))
	var zooms: Array[Image] = []
	for i in variants.size():
		var ox := GAP + i * (DESIGN.x + GAP)
		for c: Rect2i in [badge_crop, strip_crop]:
			var im := shot.get_region(Rect2i(Vector2i(ox, GAP) + c.position, c.size))
			im.resize(c.size.x * ZOOM / 2, c.size.y * ZOOM / 2, Image.INTERPOLATE_LANCZOS)
			zooms.append(im)
	var zoom_h := 0
	var zoom_w := GAP
	for im in zooms:
		zoom_h = maxi(zoom_h, im.get_height())
		zoom_w += im.get_width() + GAP
	var sheet := Image.create(maxi(shot.get_width(), zoom_w), shot.get_height() + zoom_h + GAP, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.93, 0.91, 0.87))
	sheet.blit_rect(shot, Rect2i(Vector2i.ZERO, shot.get_size()), Vector2i.ZERO)
	var x := GAP
	for im in zooms:
		sheet.blit_rect(im, Rect2i(Vector2i.ZERO, im.get_size()), Vector2i(x, shot.get_height()))
		x += im.get_width() + GAP
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	sheet.save_png(out_path)
	report["out"] = out_path
	print("CARD_FRAME_CHECK ", JSON.stringify(report))
	get_tree().quit()


func _rect(key: String) -> Rect2:
	match key:
		"BADGE_RECT":
			return FormalCityCard.BADGE_RECT
		"HIGHLIGHT_RECT":
			return FormalCityCard.HIGHLIGHT_RECT
		_:
			return FormalCityCard.EPITHET_RECT


func _runtime_texture(res_path: String) -> Texture2D:
	var abs_path := ProjectSettings.globalize_path(res_path)
	if not FileAccess.file_exists(abs_path):
		push_error("missing file %s" % abs_path)
		return null
	var img := Image.load_from_file(abs_path)
	if img == null or img.is_empty():
		push_error("cannot read image %s" % abs_path)
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
