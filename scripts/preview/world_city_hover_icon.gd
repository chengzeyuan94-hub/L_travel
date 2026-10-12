extends Control
class_name WorldCityHoverIcon


const VISUAL_SIZE := 108.0
const ROOT_SIZE := Vector2(118.0, 132.0)
const HOVER_SCALE := 1.10
const HOVER_RISE_PX := 3.0

var city_id := ""
var display_name := ""
var _idle_sprite: Sprite2D
var _animated_sprite: AnimatedSprite2D
var _name_panel: Panel
var _home_position := Vector2.ZERO
var _hovered := false
var _scale_tween: Tween


func setup(entry: Dictionary) -> void:
	city_id = str(entry.get("id", ""))
	display_name = str(entry.get("display_name", city_id))
	custom_minimum_size = ROOT_SIZE
	size = ROOT_SIZE
	pivot_offset = Vector2(ROOT_SIZE.x * 0.5, VISUAL_SIZE * 0.58)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_filter = Control.MOUSE_FILTER_STOP

	var idle_texture := load(str(entry.get("idle", ""))) as Texture2D
	var atlas_texture := load(str(entry.get("atlas", ""))) as Texture2D
	if idle_texture == null or atlas_texture == null:
		push_error("WorldCityHoverIcon: failed to load textures for %s" % city_id)
		return

	_idle_sprite = Sprite2D.new()
	_idle_sprite.name = "IdleSprite"
	_idle_sprite.texture = idle_texture
	_idle_sprite.position = Vector2(ROOT_SIZE.x * 0.5, VISUAL_SIZE * 0.5)
	_idle_sprite.scale = Vector2.ONE * (VISUAL_SIZE / float(idle_texture.get_width()))
	_idle_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	add_child(_idle_sprite)

	_animated_sprite = AnimatedSprite2D.new()
	_animated_sprite.name = "AnimatedSprite"
	_animated_sprite.position = _idle_sprite.position
	_animated_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_animated_sprite.sprite_frames = _build_frames(entry, atlas_texture)
	_animated_sprite.scale = Vector2.ONE * (
		VISUAL_SIZE / float(int(entry.get("frame_size", [512, 512])[0]))
	)
	_animated_sprite.visible = false
	add_child(_animated_sprite)

	_build_nameplate()
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)


func set_home_position(value: Vector2) -> void:
	_home_position = value
	if not _hovered:
		position = _home_position


func set_hovered_for_preview(value: bool) -> void:
	if value:
		_on_mouse_entered()
	else:
		_on_mouse_exited()


func get_preview_state() -> Dictionary:
	return {
		"city_id": city_id,
		"hovered": _hovered,
		"frame": _animated_sprite.frame if _animated_sprite != null else -1,
		"playing": _animated_sprite.is_playing() if _animated_sprite != null else false,
		"scale": scale,
	}


func _build_frames(entry: Dictionary, atlas_texture: Texture2D) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	frames.add_animation("hover")
	frames.set_animation_loop("hover", true)
	frames.set_animation_speed("hover", float(entry.get("fps", 6.0)))
	var columns := int(entry.get("columns", 4))
	var frame_count := int(entry.get("frame_count", 16))
	var frame_size_data: Array = entry.get("frame_size", [512, 512])
	var frame_size := Vector2(float(frame_size_data[0]), float(frame_size_data[1]))
	for index in range(frame_count):
		var frame_texture := AtlasTexture.new()
		frame_texture.atlas = atlas_texture
		frame_texture.region = Rect2(
			Vector2(index % columns, index / columns) * frame_size,
			frame_size
		)
		frames.add_frame("hover", frame_texture)
	return frames


func _build_nameplate() -> void:
	_name_panel = Panel.new()
	_name_panel.name = "Nameplate"
	_name_panel.position = Vector2(9.0, 105.0)
	_name_panel.size = Vector2(100.0, 23.0)
	_name_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var plate_style := StyleBoxFlat.new()
	plate_style.bg_color = Color(0.18, 0.09, 0.045, 0.86)
	plate_style.border_color = Color(0.79, 0.54, 0.18, 0.92)
	plate_style.set_border_width_all(1)
	plate_style.set_corner_radius_all(5)
	_name_panel.add_theme_stylebox_override("panel", plate_style)
	add_child(_name_panel)

	var label := Label.new()
	label.name = "CityName"
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.text = display_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(1.0, 0.91, 0.70))
	label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.65))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_panel.add_child(label)


func _on_mouse_entered() -> void:
	if _animated_sprite == null:
		return
	_hovered = true
	z_index = 100
	_idle_sprite.visible = false
	_animated_sprite.visible = true
	_animated_sprite.play("hover")
	_animate_to(Vector2.ONE * HOVER_SCALE, _home_position + Vector2.UP * HOVER_RISE_PX)


func _on_mouse_exited() -> void:
	if _animated_sprite == null:
		return
	_hovered = false
	z_index = 0
	_animated_sprite.stop()
	_animated_sprite.frame = 0
	_animated_sprite.visible = false
	_idle_sprite.visible = true
	_animate_to(Vector2.ONE, _home_position)


func _animate_to(target_scale: Vector2, target_position: Vector2) -> void:
	if _scale_tween != null and _scale_tween.is_valid():
		_scale_tween.kill()
	_scale_tween = create_tween()
	_scale_tween.set_parallel(true)
	_scale_tween.set_trans(Tween.TRANS_CUBIC)
	_scale_tween.set_ease(Tween.EASE_OUT)
	_scale_tween.tween_property(self, "scale", target_scale, 0.16)
	_scale_tween.tween_property(self, "position", target_position, 0.16)
