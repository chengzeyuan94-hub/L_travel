extends Control

## 标题开屏：960×540 设计舞台 cover 适配 + PXD UI 入场。
## 不访问 GameState；世界动态交给 EffectsLayer。

signal new_game_requested

const INTRO_DURATION := 0.55
const INTRO_OFFSET := 12.0
const AMBIENT_PERIOD := 11.0
const AMBIENT_ALPHA := 0.015
const BGM_VOLUME_MUTE := -40.0
const BGM_VOLUME_PLAY := -12.0
const BGM_FADE_IN := 0.8
const BGM_FADE_OUT := 0.35

var _signals_connected := false
var _intro_played := false
var _ambient_tween: Tween
var _bgm_tween: Tween
var _bgm_epoch := 0
var _bgm_enabled := true


func _ready() -> void:
	_ensure_signals()
	_setup_stage_nodes()
	_setup_title_ui()
	_setup_title_bgm()
	_fit_background()
	resized.connect(_fit_background)
	visibility_changed.connect(_on_visibility_changed)
	_prepare_intro_state()
	if visible:
		_on_shown()


func _unhandled_key_input(event: InputEvent) -> void:
	if not OS.is_debug_build() or not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		get_viewport().set_input_as_handled()
		get_tree().change_scene_to_file("res://scenes/traveler/traveler_main.tscn")


func _ensure_signals() -> void:
	if _signals_connected:
		return
	%NewGameButton.pressed.connect(_on_new_game_button_pressed)
	%QuitButton.pressed.connect(_on_quit_button_pressed)
	_signals_connected = true


func _setup_stage_nodes() -> void:
	var root: Control = %BackgroundRoot
	root.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	root.size = TitleEffectCatalog.DESIGN_SIZE
	root.scale = Vector2.ONE
	root.pivot_offset = Vector2.ZERO

	var bg: TextureRect = root.get_node("BackgroundTexture")
	bg.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.texture = TitleEffectCatalog.layer_atlas("background")
	var bg_rect: Rect2 = TitleEffectCatalog.STATIC_LAYER_RECTS["background"]
	bg.position = bg_rect.position
	bg.size = bg_rect.size

	var ambient: Control = %AmbientOverlay
	ambient.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	ambient.position = Vector2.ZERO
	ambient.size = TitleEffectCatalog.DESIGN_SIZE

	var effects: Control = %EffectsLayer
	effects.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	effects.position = Vector2.ZERO
	effects.size = TitleEffectCatalog.DESIGN_SIZE
	effects.clip_contents = true

	var ui: Control = %TitleUIRoot
	ui.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	ui.position = Vector2.ZERO
	ui.size = TitleEffectCatalog.DESIGN_SIZE
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _setup_title_ui() -> void:
	_place_ui_texture(%HangingTitleScroll, "hanging_scroll", "hanging_scroll")
	_place_ui_texture(%SloganTexture, "slogan", "slogan")
	_place_ui_texture(%FocusSeal, "seal", "seal")
	_style_image_button(%NewGameButton, "start_button", "start_normal", "start_hover", "start_pressed")
	_style_image_button(%QuitButton, "exit_button", "exit_normal", "exit_hover", "exit_pressed")
	var vrect: Rect2 = TitleEffectCatalog.TITLE_UI_RECTS["version"]
	var version: Control = %VersionLabel
	version.clip_contents = true
	version.mouse_filter = Control.MOUSE_FILTER_IGNORE
	version.position = vrect.position
	version.size = vrect.size
	var vtext: Label = version.get_node("Text")
	# 开屏版本必须与当前可试玩构建一致，避免玩家误以为自己运行了尚未发布的后续
	# 开发分支。唯一版本源是 project.godot 的 application/config/version，禁止在
	# 此处或场景里另写字面量，否则会再次出现三套版本事实。
	var project_version := String(ProjectSettings.get_setting("application/config/version", ""))
	vtext.text = "v%s" % project_version if not project_version.is_empty() else "v0.0.0-unknown"
	vtext.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vtext.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 版本号处在卷轴的最下方，需在羊皮纸纹理上保持可读而不抢主按钮的视觉层级。
	vtext.add_theme_font_size_override("font_size", 9)
	vtext.add_theme_color_override("font_color", Color(0.28, 0.2, 0.12, 0.82))
	vtext.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vtext.position = Vector2.ZERO
	vtext.size = vrect.size


func _setup_title_bgm() -> void:
	var bgm: AudioStreamPlayer = %TitleBGM
	# Headless validation has no audible output and can terminate immediately after the
	# first audio mix. Loading a looping WAV there leaves its playback object queued in
	# AudioServer during engine teardown. Keep the production/window path unchanged,
	# while avoiding a meaningless audio allocation in CLI/import gates.
	_bgm_enabled = DisplayServer.get_name() != "headless"
	if not _bgm_enabled:
		bgm.stop()
		bgm.stream = null
		return
	# 重新 load，避免场景内嵌引用与错误 loop 点；不 duplicate 以免丢采样。
	var wav := load("res://assets/audio/title/title_bgm_loop_v1.wav") as AudioStreamWAV
	assert(wav != null, "TitleBGM: missing title_bgm_loop_v1.wav")
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = maxi(int(round(wav.get_length() * float(wav.mix_rate))) - 1, 0)
	bgm.stream = wav
	bgm.autoplay = false
	bgm.bus = "Master"
	bgm.volume_db = BGM_VOLUME_MUTE


func _place_ui_texture(node: TextureRect, atlas_id: String, rect_id: String) -> void:
	var rect: Rect2 = TitleEffectCatalog.TITLE_UI_RECTS[rect_id]
	node.texture = TitleEffectCatalog.ui_atlas(atlas_id)
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.stretch_mode = TextureRect.STRETCH_SCALE
	node.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.position = rect.position
	node.size = rect.size


func _style_image_button(
	button: TextureButton,
	rect_id: String,
	normal_id: String,
	hover_id: String,
	pressed_id: String
) -> void:
	var rect: Rect2 = TitleEffectCatalog.TITLE_UI_RECTS[rect_id]
	button.texture_normal = TitleEffectCatalog.ui_atlas(normal_id)
	button.texture_hover = TitleEffectCatalog.ui_atlas(hover_id)
	button.texture_pressed = TitleEffectCatalog.ui_atlas(pressed_id)
	button.ignore_texture_size = true
	button.stretch_mode = TextureButton.STRETCH_SCALE
	button.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.position = rect.position
	button.size = rect.size
	button.custom_minimum_size = rect.size
	button.modulate = Color.WHITE


func _on_visibility_changed() -> void:
	if visible:
		_on_shown()
	else:
		_on_hidden()


func _exit_tree() -> void:
	# `--quit-after`, Cmd+Q and window close can tear the title scene down while its
	# looping WAV is still active, without first sending a visibility change.  Release
	# both playback and stream explicitly so the macOS build and headless startup gate
	# exit without retaining AudioStreamWAV/AudioStreamPlaybackWAV instances.
	_kill_bgm_tween()
	var bgm := get_node_or_null("%TitleBGM") as AudioStreamPlayer
	if bgm != null:
		bgm.stop()
		bgm.stream = null


func _on_shown() -> void:
	_fit_background()
	%EffectsLayer.start_effects()
	_start_ambient()
	_start_title_bgm()
	if not _intro_played:
		_play_intro()
		_intro_played = true
	else:
		_reset_ui_rest_pose()


func _on_hidden() -> void:
	%EffectsLayer.stop_effects()
	_stop_ambient()
	_stop_title_bgm()


func _prepare_intro_state() -> void:
	var ui: Control = %TitleUIRoot
	ui.modulate.a = 0.0
	ui.position = Vector2(INTRO_OFFSET, 0.0)


func _reset_ui_rest_pose() -> void:
	var ui: Control = %TitleUIRoot
	ui.modulate.a = 1.0
	ui.position = Vector2.ZERO


func _play_intro() -> void:
	var ui: Control = %TitleUIRoot
	ui.modulate.a = 0.0
	ui.position = Vector2(INTRO_OFFSET, 0.0)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(ui, "modulate:a", 1.0, INTRO_DURATION)
	tween.tween_property(ui, "position", Vector2.ZERO, INTRO_DURATION)


func _start_ambient() -> void:
	_stop_ambient()
	var overlay: CanvasItem = %AmbientOverlay
	overlay.modulate.a = 0.0
	_ambient_tween = create_tween()
	_ambient_tween.set_loops()
	_ambient_tween.tween_property(overlay, "modulate:a", AMBIENT_ALPHA, AMBIENT_PERIOD * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_ambient_tween.tween_property(overlay, "modulate:a", 0.0, AMBIENT_PERIOD * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_ambient() -> void:
	if _ambient_tween != null:
		_ambient_tween.kill()
		_ambient_tween = null
	%AmbientOverlay.modulate.a = 0.0


func _kill_bgm_tween() -> void:
	if _bgm_tween != null:
		_bgm_tween.kill()
		_bgm_tween = null


func _start_title_bgm() -> void:
	if not _bgm_enabled:
		return
	var bgm: AudioStreamPlayer = %TitleBGM
	_bgm_epoch += 1
	_kill_bgm_tween()
	if not bgm.playing:
		bgm.volume_db = BGM_VOLUME_MUTE
		bgm.play(0.0)
	_bgm_tween = create_tween()
	_bgm_tween.tween_property(bgm, "volume_db", BGM_VOLUME_PLAY, BGM_FADE_IN).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _stop_title_bgm() -> void:
	if not _bgm_enabled:
		return
	var bgm: AudioStreamPlayer = %TitleBGM
	_bgm_epoch += 1
	var epoch := _bgm_epoch
	_kill_bgm_tween()
	if not bgm.playing:
		bgm.volume_db = BGM_VOLUME_MUTE
		return
	_bgm_tween = create_tween()
	_bgm_tween.tween_property(bgm, "volume_db", BGM_VOLUME_MUTE, BGM_FADE_OUT).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_bgm_tween.finished.connect(func():
		if epoch != _bgm_epoch:
			return
		if is_instance_valid(bgm):
			bgm.stop()
			bgm.volume_db = BGM_VOLUME_MUTE
		_bgm_tween = null
	, CONNECT_ONE_SHOT)


func _fit_background() -> void:
	var view := size
	if view.x <= 1.0 or view.y <= 1.0:
		return
	var design := TitleEffectCatalog.DESIGN_SIZE
	var scale_factor: float = maxf(view.x / design.x, view.y / design.y)
	var root: Control = %BackgroundRoot
	root.size = design
	root.scale = Vector2(scale_factor, scale_factor)
	root.pivot_offset = Vector2.ZERO
	var scaled := design * scale_factor
	# 水平裁切靠右，垂直居中，保留右侧卷轴。
	root.position = Vector2(view.x - scaled.x, (view.y - scaled.y) * 0.5)


func _on_new_game_button_pressed() -> void:
	print("TASK-006: new game requested")
	new_game_requested.emit()


func _on_quit_button_pressed() -> void:
	get_tree().quit()
