extends "res://tools/merchant_board_claude_review.gd"
## Claude's approved 3D merchant board built into a SubViewport owned by the playable board view
## (tools/merchant_board_claude_play_board.gd). Same world as the review scene — terrain, cities,
## sea life, the living layer, lighting, post and tilt-shift — without the review scene's side
## effects (window resize, status text, number keys, captures). The ambient L叔 wanderer is removed:
## in a match L叔 is the players' pieces.

const LIFE := preload("res://tools/merchant_board_claude_life.gd")
const RenderGlobals := preload("res://scripts/traveler/render_globals.gd")

## 自制地图（docs/design/map-editor-20260930/DESIGN.md 3.10.2）：不为空时用这份推导出来的布局建世界，
## 为空（默认）时照旧读 board_layout.json。模型缓存开关 use_model_cache 在父类（load_gltf 在那里）。
var layout_override: Dictionary = {}


func _ready() -> void:
	pass  # built on demand by build_into()


func build_into(vp: SubViewport, preset := "noon") -> void:
	render_viewport = vp
	# RenderingServer-wide settings go through render_globals.gd (it remembers them: a 旅人模式 act opened in the same
	# window puts them back exactly on the way out)
	RenderGlobals.shadow_atlas(8192, true)
	RenderGlobals.ssao_quality(RenderingServer.ENV_SSAO_QUALITY_HIGH, false, 0.5, 2, 250.0, 600.0)
	layout = layout_override if not layout_override.is_empty() else JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	city_bounds = JSON.parse_string(FileAccess.get_file_as_string(BOUNDS)).cities
	flat_shader = Shader.new()
	flat_shader.code = FLAT_SHADER
	light_name = preset
	var t0 := Time.get_ticks_msec()
	build_world()
	build_ms["world"] = Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	life = LIFE.new()
	life.name = "BoardLife"
	world_root.add_child(life)
	life.setup(self)
	build_ms["life"] = Time.get_ticks_msec() - t0
	if not life.lshu.is_empty():
		(life.lshu.root as Node).queue_free()
		life.lshu = {}
	apply_lighting(light_name)
	apply_fx_off()
	apply_tilt_for_view("east")


func update_status() -> void:
	pass


func _unhandled_input(_event: InputEvent) -> void:
	pass
