extends RefCounted
## 「L叔的趣味事件」界面零件（2026-09-27）：翻牌后的演出台（scripts/ui/fun_event_stage.gd）、市集里的选择面板
## （lshu_choice_view.gd）、篝火泡泡都从这里取贴图和字。只用已认可的 L叔 界面零件（match_hud / lshu_title /
## city_cards v2 / event_cards_v2 / lshu_3d 图标），不另画色块。
## 字体按 LshuMatchHud 的分层：display（娃娃体）只给面板标题飘带；选项、预览、按钮、结果一律圆体（title / body）。

const Hud := preload("res://scripts/lshu_ui/lshu_match_hud.gd")
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const LSkin := preload("res://scripts/lshu_ui/lshu_skin.gd")
const Icons := preload("res://scripts/lshu_ui/lshu_icons.gd")

const HUD_DIR := "res://assets/game/ui/match_hud/"
const DICE_ATLAS := "res://assets/game/dice/dice_face_atlas_v2.png"
const RIBBON := "res://assets/game/ui/city_cards/v2/ribbon.png"
const RIBBON_DENIM := "res://assets/game/ui/city_cards/v2/ribbon_denim.png"
const STAMP := "res://assets/game/ui/city_cards/v2/stamp.png"
const POSTMARK := "res://assets/game/ui/city_cards/v2/postmark.png"
const HIGHLIGHT := "res://assets/game/ui/city_cards/v2/highlight.png"
const POSTCARD_FACE := "res://assets/game/ui/event_cards_v2/event_postcard_base_768x1024.png"
## 明信片花纹卡背（art-src/cards-v2/kit/back_postcard_a.png 缩到 384×512，设计 §4.1 陆7 点名先试这张）
const POSTCARD_BACK := "res://assets/game/ui/fun_events/postcard_back.png"
const LSHU_FACE := "res://assets/game/ui/lshu_title/lshu_avatar2.png"
const GLASSES := "res://assets/game/ui/lshu_title/icon_glasses.png"
const MUSIC_LENS := "res://assets/game/ui/lshu_title/lens_music.png"
const CAMEL_ICON := "res://assets/game/ui/lshu_setup/icon_camel.png"
const SHIP_ICON := "res://assets/game/ui/lshu_setup/icon_ship.png"
const SPEECH := "bubble"            # lshu_title/bubble.png：带小尾巴的对话泡泡

static var _hud_meta: Dictionary = {}
static var _tex: Dictionary = {}
static var _faces: Dictionary = {}


static func tex(path: String) -> Texture2D:
	if _tex.has(path):
		return _tex[path]
	var t: Texture2D = load(path) as Texture2D if ResourceLoader.exists(path) else null
	_tex[path] = t
	return t


static func hud_tex(name_: String) -> Texture2D:
	return tex(HUD_DIR + name_ + ".png")


static func _hud_nine_margins(name_: String) -> Array:
	if _hud_meta.is_empty():
		var p := HUD_DIR + "match_hud.json"
		if FileAccess.file_exists(p):
			var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
			if d is Dictionary:
				_hud_meta = d
	return (_hud_meta.get(name_, {}) as Dictionary).get("nine", [36, 36, 36, 36])


## 对局界面的九宫格零件（panel_satchel / tile / row / row_sel / pill / bubble / pocket_sel …），和市集面板同一套
static func hud_nine(name_: String, block_mouse := false) -> NinePatchRect:
	var n := NinePatchRect.new()
	n.name = "Skin_" + name_
	n.texture = hud_tex(name_)
	var m: Array = _hud_nine_margins(name_)
	n.patch_margin_left = int(m[0])
	n.patch_margin_top = int(m[1])
	n.patch_margin_right = int(m[2])
	n.patch_margin_bottom = int(m[3])
	n.mouse_filter = Control.MOUSE_FILTER_STOP if block_mouse else Control.MOUSE_FILTER_IGNORE
	return n


## 任意贴图做九宫格（明信片纸、开场的对话泡泡）
static func nine_of(texture: Texture2D, margin: int) -> NinePatchRect:
	var n := NinePatchRect.new()
	n.texture = texture
	n.patch_margin_left = margin
	n.patch_margin_top = margin
	n.patch_margin_right = margin
	n.patch_margin_bottom = margin
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return n


## 开场界面的对话泡泡（左下角有小尾巴）：lshu_title 的贴图按两倍设计像素存，九宫格按 0.5 画（LshuSkin.NinePanel）
static func speech_bubble() -> Control:
	var n := LSkin.nine_panel(SPEECH, Vector4.ZERO)
	n.name = "Speech"
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return n


static func image(texture: Texture2D, r: Rect2, cover := false) -> TextureRect:
	var t := TextureRect.new()
	t.texture = texture
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED if cover else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(t, r)
	return t


static func place(c: Control, r: Rect2) -> void:
	c.position = r.position
	c.size = r.size


static func label(text: String, px: int, color: Color, kind := "body", weight := 700) -> Label:
	return Hud.label(text, px, color, kind, weight)


## 面板标题：缎带 + 娃娃体（全包只有这一处用卡通字）
static func ribbon_title(text: String, r: Rect2, sea := false) -> Control:
	var root := Control.new()
	root.name = "TitleRibbon"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(root, r)
	root.add_child(image(tex(RIBBON_DENIM if sea else RIBBON), Rect2(Vector2.ZERO, r.size)))
	var t := label(text, int(r.size.y * 0.34), Kit.CREAM, "display", 700)
	t.name = "TitleText"
	t.add_theme_color_override("font_outline_color", Color("#3E4F6B") if sea else Color("#6B3A1C"))
	t.add_theme_constant_override("outline_size", int(r.size.y * 0.075))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	place(t, Rect2(r.size.x * 0.14, r.size.y * 0.1, r.size.x * 0.72, r.size.y * 0.52))
	root.add_child(t)
	return root


## 糖果按钮（和右下主按钮同一套贴图），字是圆体粗
static func candy(text: String, color: String, px: int) -> Button:
	return Hud.candy(text, color, px)


## 骰面贴图：1–5 点和事件面（dice_face_atlas_v2，3×2 格，和 3D 骰子同一张）
static func dice_face(face: Variant) -> Texture2D:
	var key := "EVENT" if DiceSystem.is_event_face(face) else str(int(face)) if face != null else "1"
	if _faces.has(key):
		return _faces[key]
	var atlas := tex(DICE_ATLAS)
	if atlas == null:
		return null
	var index := 5 if key == "EVENT" else clampi(int(key) - 1, 0, 4)
	var cell := Vector2(atlas.get_width() / 3.0, atlas.get_height() / 2.0)
	var a := AtlasTexture.new()
	a.atlas = atlas
	a.region = Rect2(Vector2(index % 3, index / 3) * cell, cell)
	_faces[key] = a
	return a


static func silver_icon() -> Texture2D:
	return Icons.silver()


static func good_icon(good_id: String) -> Texture2D:
	return Icons.good(good_id)


## 「L叔的趣味事件」某一时刻的音（SoundDirector 在音效分支里：play_event_cue(event, cue)）。没有导演、没在对局里就不响，返回 false。
static func play_cue(host: Node, event: Dictionary, cue: String) -> bool:
	if host == null or not host.is_inside_tree():
		return false
	var director := host.get_tree().root.get_node_or_null("SoundDirector")
	if director == null or not director.has_method("play_event_cue"):
		return false
	return bool(director.call("play_event_cue", event, cue))


## 听声猜物的那一段声音：借 play_event_cue 的 sfx_cues 查表（sfx 表里就是这 9 个点缀名），不在 AudioManager 里另开口子。
## 游戏总音量静音、没有导演、或导演没在对局里工作时返回 false —— 界面据此不出题，改走 0–4 步（设计 §4.3 通6）。
static func play_quiz_sound(host: Node, sound_id: String) -> bool:
	var master := AudioServer.get_bus_index("Master")
	if master >= 0 and (AudioServer.is_bus_mute(master) or AudioServer.get_bus_volume_db(master) <= -60.0):
		return false
	var sfx := AudioServer.get_bus_index("SFX")
	if sfx >= 0 and AudioServer.is_bus_mute(sfx):
		return false
	return play_cue(host, {"sfx_cues": {"quiz": sound_id}}, "quiz")
