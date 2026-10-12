extends Node
## Claude's 3D merchant-board sample: the formal 2D board (world_map_v1) made three-dimensional.
## Standalone review scene, not the game's main scene. Everything it shows is built from
## assets/merchant_board_claude/ (see art-src/merchant-board-claude/terrain/build_board.py).
##
## Keys: 1 whole board, 2 game camera (east), 3 game camera (west), 4 close-up (Korea/Japan),
##       5 target framing (matches Carlos's image2.5 target: ortho, 40 deg, 3:1),
##       6 reef close-up, L toggle dusk / noon lighting,
##       R toggle routes, wheel zoom, right-drag pan, Esc quit.
## Args: -- [--light=dusk|noon] [--capture [--capture=/absolute/output-directory]]

# Built by build_board.py; --terrain-root=<abs dir> swaps in a staging build of these files.
var LAYOUT := "res://assets/merchant_board_claude/board_layout.json"
var TERRAIN := "res://assets/merchant_board_claude/terrain/board_terrain.glb"
var MOUNTAINS := "res://assets/merchant_board_claude/terrain/mountains.glb"
var SEA := "res://assets/merchant_board_claude/terrain/sea.glb"
var SNOW := "res://assets/merchant_board_claude/terrain/mountain_snow.glb"
var SEA_DIST := "res://assets/merchant_board_claude/terrain/sea_dist.png"
var SEABED := "res://assets/merchant_board_claude/terrain/seabed.glb"
var GROUND_DETAIL := "res://assets/merchant_board_claude/terrain/ground_detail.png"
const SEA_SHADER_PATH := "res://shaders/merchant_board_claude/board_sea.gdshader"
const RIVER_SHADER_PATH := "res://shaders/merchant_board_claude/board_river.gdshader"
var GROUND_SHADER_PATH := "res://shaders/merchant_board_claude/board_ground_v2.gdshader"
const BOUNDS := "res://assets/merchant_board_claude/cities/building_bounds.json"
const SEA_TEX := "res://assets/merchant_board_claude/terrain/sea_color.png"
const CITY_DIR := "res://assets/merchant_board_claude/cities/"
const FALLBACK_CITY_DIR := "res://generated/traveler/atlas/assets/cities/"
const DEFAULT_CAPTURE_DIR := "res://docs/design/merchant-board-claude-20260923/review"
const IMAGE_SIZE := Vector2i(1920, 1080)
const GAME_PITCH := 0.76  # radians above the horizon, same as the Atlas / formal camera
const TARGET_SIZE := Vector2i(2000, 667)
# Carlos 2026-09-24 「城市正面偏平」→ 改: turn every city ~25 deg so the facade faces
# south-west into the sun and the east side shows as a shade plane (the concept's cities
# are drawn at three-quarter view).
const CITY_YAW := -0.44
# Coastal / island cities whose outbuildings swung past their cliff edge or over water or a
# coin when turned by the full CITY_YAW: [yaw, dx, dz] (world units; x east, z south).
const CITY_FIT := {
	"rome": [0.0, -0.5, 0.0], "simhala": [-0.15, -0.3, 0.0],
	"heijokyo": [-0.2, -0.25, -0.25], "geumseong": [-0.25, 0.2, 0.2],
}
var VIEWS := {
	"target": {"target": Vector3(62.94, 0.0, 29.7), "size": 43.2, "elev": 40.2},
	"full": {"target": Vector3(64.0, 0.0, 29.0), "persp": true, "distance": 104.0, "elev": 50.0},
	"east": {"target": Vector3(101.0, 0.0, 30.0), "size": 31.5},
	"west": {"target": Vector3(31.0, 0.0, 27.5), "size": 31.5},
	"close": {"target": Vector3(111.0, 0.0, 22.5), "size": 20.0},
	"reef": {"target": Vector3(115.3, 0.0, 44.0), "size": 9.0},
	"sea": {"target": Vector3(111.0, 0.0, 45.0), "size": 16.0},
}

var layout: Dictionary
var world_root: Node3D
var render_viewport: SubViewport
var camera: Camera3D
var routes_node: Node3D
var status_label: Label
var capture_mode := false
var capture_dir := ""
var view_name := "full"
var cam_target := Vector3.ZERO
var cam_size := 31.5
var cam_distance := 112.0
var dragging := false
var city_nodes := {}
var flat_shader: Shader
var city_bounds := {}
var clouds: Array = []
var tilt_layer: CanvasLayer
var tilt_rect: ColorRect
var vc_material: StandardMaterial3D
var light_name := "noon"  # the concept-calibrated preset; L toggles dusk
var env: Environment
var sky_mat: ProceduralSkyMaterial
var sun: DirectionalLight3D
var fill: DirectionalLight3D
var rim: DirectionalLight3D
var city_lift: DirectionalLight3D
var ground_mat: ShaderMaterial
var sea_mat: ShaderMaterial
var life: Node3D
var sealife_mats: Array[ShaderMaterial] = []
# Post-processing: a 3D full-screen pass (reads depth / normals: outlines, haze, grading) and a
# 2D screen pass before the tilt-shift. Defaults below; --post3d-shader= / --post-shader= swap in
# another file (res:// or absolute path), "none" disables.
var POST3D_PATH := "res://shaders/merchant_board_claude/board_post3d.gdshader"
var POST2D_PATH := "res://shaders/merchant_board_claude/board_post2d.gdshader"
var post3d: MeshInstance3D
var life_time0 := 0.0
var post2d_rect: ColorRect
var swimmers: Array = []          # per instance: [MultiMesh, index, lane, local, params]
var lanes := {}                   # lane id -> {pts: PackedVector2Array, cum: PackedFloat32Array, L: float}
var city_glow: Array = []         # [StandardMaterial3D, emission colour, energy]
var city_lights: Array[OmniLight3D] = []
var cloud_mat: ShaderMaterial
var tree_mmis: Array = []
var lighting_override := {}
var fx_off: PackedStringArray = []  # debug ablation: gi, ssao, ssil, shadow, tilt, fill
var capture_wait := 60
var capture_views_list: PackedStringArray = ["target", "full", "east", "west", "close", "reef"]
## 自制地图（docs/design/map-editor-20260930/DESIGN.md 3.6、3.10.2）：以下几项只给棋盘整体重建和工坊就地整理用，
## 原布局里没有对应的键、缓存默认关，所以原版画出来的东西一样不变。
## 模型缓存：为真时 load_gltf 把解析好的场景按路径存成 PackedScene 留在内存里，再用时 instantiate()（第二次建世界不用再解析 16 个大 GLB）。
## 第一次建世界（棋盘 _ready）时是关着的。
var use_model_cache := false
static var _gltf_cache := {}
## 目录里的城读不到时顶上的小镇（WP6 提供）；它也读不到时用一个方块，不崩
const FALLBACK_TOWN := "res://assets/merchant_board_claude/catalogue/_fallback_town.glb"
## 地面细节图：铺地之前的原图（没有铺地操作时就是贴图用的那张图本身，不多占内存）和建出来的贴图，
## 工坊改铺地时在原图副本上重放全部 paving 操作再 ImageTexture.update()（3.12.7）
var ground_detail_src: Image
var ground_detail_tex: ImageTexture
## 树、道具、森林的实例表：{布局段名: {下标: [[MultiMesh, 实例号, 原 transform], ...]}}（一行可能对应几个子网格）
var decor_index := {}
var decor_hidden := {}   # {布局段名: {下标: true}}：现在缩成 0 的行
var build_ms := {}       # 建世界各段的耗时（整体重建的日志用）


func _ready() -> void:
	capture_dir = ProjectSettings.globalize_path(DEFAULT_CAPTURE_DIR)
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--capture":
			capture_mode = true
		elif arg.begins_with("--capture="):
			capture_mode = true
			capture_dir = arg.trim_prefix("--capture=")
		elif arg.begins_with("--light="):
			light_name = arg.trim_prefix("--light=")
		elif arg.begins_with("--lighting-json="):
			lighting_override = JSON.parse_string(FileAccess.get_file_as_string(arg.trim_prefix("--lighting-json=")))
		elif arg.begins_with("--fx-off="):
			fx_off = arg.trim_prefix("--fx-off=").split(",")
		elif arg.begins_with("--terrain-root="):
			var root := arg.trim_prefix("--terrain-root=")
			LAYOUT = root.path_join("board_layout.json")
			for pair in [["TERRAIN", "board_terrain.glb"], ["MOUNTAINS", "mountains.glb"], ["SEA", "sea.glb"],
					["SNOW", "mountain_snow.glb"], ["SEA_DIST", "sea_dist.png"], ["SEABED", "seabed.glb"], ["GROUND_DETAIL", "ground_detail.png"]]:
				set(pair[0], root.path_join("terrain").path_join(pair[1]))
		elif arg.begins_with("--ground-shader="):
			GROUND_SHADER_PATH = arg.trim_prefix("--ground-shader=")
		elif arg.begins_with("--view-at="):
			# debug close-up: --view-at=x,z,size[,frames-to-wait]
			var v := arg.trim_prefix("--view-at=").split(",")
			VIEWS["custom"] = {"target": Vector3(float(v[0]), 0.0, float(v[1])), "size": float(v[2])}
			capture_views_list = ["custom"]
			if v.size() > 3:
				capture_wait = int(v[3])
		elif arg.begins_with("--life-time="):
			life_time0 = float(arg.trim_prefix("--life-time="))
		elif arg.begins_with("--post3d-shader="):
			POST3D_PATH = arg.trim_prefix("--post3d-shader=")
		elif arg.begins_with("--post-shader="):
			POST2D_PATH = arg.trim_prefix("--post-shader=")
		elif arg.begins_with("--views="):
			capture_views_list = arg.trim_prefix("--views=").split(",")
	get_window().size = Vector2i(1600, 900)
	# One ortho shadow map covers the whole board (200 u): give it 8192 px so small props and
	# trees keep crisp shadows; and let SSAO reach the board camera (~104-120 u away).
	RenderingServer.directional_shadow_atlas_set_size(8192, true)
	RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_HIGH, false, 0.5, 2, 250.0, 600.0)
	layout = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	city_bounds = JSON.parse_string(FileAccess.get_file_as_string(BOUNDS)).cities
	flat_shader = Shader.new()
	flat_shader.code = FLAT_SHADER
	build_viewport_and_ui()
	build_world()
	life = (load("res://tools/merchant_board_claude_life.gd") as GDScript).new()
	life.name = "BoardLife"
	world_root.add_child(life)
	life.time = life_time0
	life.setup(self)
	apply_lighting(light_name)
	apply_fx_off()
	set_view("full")
	if capture_mode:
		await capture_views()
		get_tree().quit()


# ------------------------------------------------------------------ viewport / ui
func build_viewport_and_ui() -> void:
	render_viewport = SubViewport.new()
	render_viewport.size = IMAGE_SIZE
	render_viewport.own_world_3d = true
	render_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	render_viewport.msaa_3d = Viewport.MSAA_4X
	add_child(render_viewport)
	var preview := TextureRect.new()
	preview.texture = render_viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	status_label = Label.new()
	status_label.position = Vector2(16, 12)
	status_label.add_theme_font_size_override("font_size", 18)
	status_label.add_theme_color_override("font_color", Color(1, 1, 1))
	status_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	status_label.add_theme_constant_override("outline_size", 6)
	add_child(status_label)
	if capture_mode:
		status_label.hide()


func update_status() -> void:
	status_label.text = "Claude 版 · 立体化正式棋盘   当前：%s · %s\n1 全盘  2 对局镜头·东  3 对局镜头·西  4 近看日韩  5 目标图机位  6 近看珊瑚海  7 海洋生物   L 正午/黄昏/暮色   R 路线   滚轮缩放  右键拖动  Esc 退出" % [{
		"full": "全盘", "east": "对局镜头·东", "west": "对局镜头·西", "close": "近看日韩", "target": "目标图机位", "reef": "近看珊瑚海", "sea": "海洋生物"}.get(view_name, view_name),
		{"dusk": "黄昏", "noon": "正午", "twilight": "暮色"}.get(light_name, light_name)]


# ------------------------------------------------------------------ world
func build_world() -> void:
	world_root = Node3D.new()
	render_viewport.add_child(world_root)
	build_environment()
	build_terrain()
	build_seabed()
	build_sea()
	build_tray()
	build_rivers()
	build_routes()
	var t_cities := Time.get_ticks_msec()
	build_cities()
	build_ms["cities"] = Time.get_ticks_msec() - t_cities
	if layout.has("tree_kit") and not layout.tree_kit.is_empty():
		var tree_mat := ShaderMaterial.new()
		tree_mat.shader = load("res://shaders/merchant_board_claude/board_tree_sway.gdshader")
		build_kit_instances(layout.tree_kit, "res://assets/merchant_board_claude/trees/", false, tree_mat, "tree_kit")
	else:
		build_trees()
	if layout.has("kit") and not layout.kit.is_empty():
		build_kit_instances(layout.kit, "res://assets/merchant_board_claude/mountains/", true, null, "kit")
	if layout.has("props") and not layout.props.is_empty():
		# warm tan tint so the grey stones read as the concept's brown rocks under the lavender-free fill
		var prop_mat := StandardMaterial3D.new()
		prop_mat.vertex_color_use_as_albedo = true
		prop_mat.albedo_color = Color(1.0, 0.88, 0.72)
		prop_mat.roughness = 0.9
		build_kit_instances(layout.props, "res://assets/merchant_board_claude/props/", true, prop_mat, "props")
	if layout.has("reef"):
		var reef_mat := ShaderMaterial.new()
		sealife_mats.append(reef_mat)
		reef_mat.shader = load("res://shaders/merchant_board_claude/board_kelp.gdshader")
		build_kit_instances(layout.reef, "res://assets/merchant_board_claude/reef/", false, reef_mat)
	if layout.has("sea_life"):
		build_sea_life()
	elif layout.has("schools"):
		build_fish_schools()
	if layout.has("clouds"):
		build_clouds()
	camera = Camera3D.new()
	camera.current = true
	camera.far = 600.0
	# Far-edge soft focus, like the target's gently blurred back of the board.
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_far_enabled = true
	attrs.dof_blur_far_distance = 150.0
	attrs.dof_blur_far_transition = 40.0
	attrs.dof_blur_amount = 0.06
	camera.attributes = attrs
	world_root.add_child(camera)
	build_tilt_shift()


func build_environment() -> void:
	# Autumn dusk (Carlos 2026-09-16: 「秋天偏红色黄昏」) with global illumination:
	#  sun  - low warm-orange sun from the west, long soft shadows;
	#  sky  - violet-blue zenith to warm horizon, feeds ambient, reflections and SDFGI;
	#  fill - cool blue-violet from the east so shadows stay colourful, not black;
	#  rim  - soft warm back light that outlines silhouettes;
	#  GI   - SDFGI bounce + SSIL + SSAO; glow lets snow and sunlit facets bloom slightly.
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.36, 0.4, 0.62)
	sky_mat.sky_horizon_color = Color(1.0, 0.7, 0.48)
	sky_mat.sky_curve = 0.12
	sky_mat.ground_bottom_color = Color(0.52, 0.42, 0.48)
	sky_mat.ground_horizon_color = Color(0.95, 0.72, 0.56)
	sky_mat.sun_angle_max = 0.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# Mobile 渲染器（安卓）没有 SDFGI / SSIL / SSAO：开着画面也一样，只会往 logcat 打引擎警告（安卓压力测试 TS-9）。
	# Forward+（桌面）照旧全开；其余参数照写（关着时设它们不打警告）
	var method := RenderingServer.get_current_rendering_method()
	env.sdfgi_enabled = method == "forward_plus"
	env.sdfgi_use_occlusion = false
	env.sdfgi_read_sky_light = true
	# One SDFGI cascade must cover the whole board: cascade seams show up as
	# horizontal bands on the seabed under the clear water.
	env.sdfgi_cascades = 4
	env.sdfgi_min_cell_size = 1.4
	env.sdfgi_energy = 1.2
	env.sdfgi_bounce_feedback = 0.55
	env.ssil_enabled = method == "forward_plus"
	env.ssil_radius = 3.0
	env.ssil_intensity = 0.9
	env.ssao_enabled = method != "mobile"
	env.ssao_radius = 1.1
	env.ssao_intensity = 1.6
	env.ssao_power = 1.4
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_strength = 1.1
	env.glow_bloom = 0.06
	env.glow_hdr_threshold = 0.95
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.1
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.22
	env.adjustment_contrast = 1.06
	var we := WorldEnvironment.new()
	we.environment = env
	world_root.add_child(we)
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.7, 0.44)
	sun.light_energy = 1.9
	sun.light_angular_distance = 3.0
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.8
	sun.shadow_blur = 2.0
	# One shadow map for the whole board: split seams showed as a hard line across
	# the clear sea (the seabed receives shadows through the water).
	sun.directional_shadow_max_distance = 200.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.shadow_normal_bias = 1.5
	sun.light_bake_mode = Light3D.BAKE_DYNAMIC
	# Low sun (~24 deg) from the west, slightly from the south-west.
	sun.transform = Transform3D(Basis.looking_at(Vector3(0.86, -0.41, -0.3).normalized(), Vector3.UP), Vector3.ZERO)
	world_root.add_child(sun)
	fill = DirectionalLight3D.new()
	fill.name = "SkyFill"
	fill.light_color = Color(0.56, 0.62, 0.95)
	fill.light_energy = 0.42
	fill.shadow_enabled = false
	fill.light_specular = 0.05
	fill.light_bake_mode = Light3D.BAKE_DYNAMIC
	fill.transform = Transform3D(Basis.looking_at(Vector3(-0.72, -0.55, -0.2).normalized(), Vector3.UP), Vector3.ZERO)
	# Not on the cities (layer 2): from the east it lit their shade side as brightly as
	# the sunlit facade. CityShade below gives them a weaker, warm version instead.
	fill.light_cull_mask = 0xFFFFF & ~2
	world_root.add_child(fill)
	var city_shade := DirectionalLight3D.new()
	city_shade.name = "CityShade"
	city_shade.light_color = Color(1.0, 0.7, 0.48)
	city_shade.light_energy = 0.18
	city_shade.shadow_enabled = false
	city_shade.light_cull_mask = 2
	city_shade.light_bake_mode = Light3D.BAKE_DISABLED
	city_shade.transform = Transform3D(Basis.looking_at(Vector3(-0.72, -0.55, -0.2).normalized(), Vector3.UP), Vector3.ZERO)
	world_root.add_child(city_shade)
	rim = DirectionalLight3D.new()
	rim.name = "RimLight"
	rim.light_color = Color(1.0, 0.78, 0.6)
	rim.light_energy = 0.35
	rim.shadow_enabled = false
	rim.light_bake_mode = Light3D.BAKE_DYNAMIC
	rim.transform = Transform3D(Basis.looking_at(Vector3(0.2, -0.3, 0.93).normalized(), Vector3.UP), Vector3.ZERO)
	world_root.add_child(rim)
	# Cities stand at three-quarter view (see CITY_YAW): the facade faces the sun, the east
	# side is the shade plane. A faint warm light from the front-left, only on the cities
	# (render layer 2), lifts the facade the low sun only grazes.
	city_lift = DirectionalLight3D.new()
	city_lift.name = "CityLift"
	city_lift.light_color = Color(1.0, 0.92, 0.8)
	city_lift.light_energy = 0.15
	city_lift.shadow_enabled = false
	city_lift.light_cull_mask = 2
	city_lift.light_bake_mode = Light3D.BAKE_DISABLED
	city_lift.transform = Transform3D(Basis.looking_at(Vector3(0.5, -0.4, -0.77).normalized(), Vector3.UP), Vector3.ZERO)
	world_root.add_child(city_lift)


const LIGHTING := {
	# Autumn dusk: the defaults set in build_environment().
	"dusk": {
		"sky_top": Color(0.36, 0.4, 0.62), "sky_horizon": Color(1.0, 0.7, 0.48),
		"ground_bottom": Color(0.52, 0.42, 0.48), "ground_horizon": Color(0.95, 0.72, 0.56),
		"ambient": 0.42, "exposure": 1.13, "saturation": 1.22, "contrast": 1.06,
		"glow": 0.45, "glow_threshold": 0.95,
		"sun_color": Color(1.0, 0.7, 0.44), "sun_energy": 2.2, "sun_dir": Vector3(0.872, -0.454, 0.185),
		"fill_color": Color(0.48, 0.5, 0.98), "fill_energy": 0.46,
		"rim_color": Color(1.0, 0.78, 0.6), "rim_energy": 0.16,
		"shadow_opacity": 0.92, "shadow_blur": 1.5, "sun_angular": 2.0, "sdfgi_energy": 1.0, "sun_indirect": 1.2,
		"sea_tint": Color(0.84, 0.8, 0.76), "sea_lines": 0.012,
		"smoke": Color(0.9, 0.8, 0.74, 0.85), "mist": Color(1.0, 0.86, 0.78), "mist_opacity": 0.42, "fire": 0.7, "fx_light": 0.82, "night_lift": 0.06,
		"cloud_lit": Color(1.0, 0.95, 0.9), "cloud_shade": Color(0.8, 0.78, 0.9),
	},
	# Clear noon. Carlos 2026-09-24 「为什么没有阴影的层次感」: the sun now comes from the
	# west-north-west (46 deg) and travels east and slightly toward the camera, so every
	# mountain, tree clump and city is lit on its west face and throws a visible shadow east
	# (the old sun travelled north and hid every shadow behind its caster); trees cast
	# shadows; crisper penumbra; a real key:fill ratio. Tuned by a 3-way lighting panel.
	"noon": {
		"sky_top": Color(0.36, 0.56, 0.9), "sky_horizon": Color(0.74, 0.86, 0.97),
		"ground_bottom": Color(0.55, 0.6, 0.75), "ground_horizon": Color(0.74, 0.86, 0.97),
		"ambient": 0.3, "exposure": 1.03, "saturation": 1.55, "contrast": 1.05,
		"glow": 0.3, "glow_threshold": 1.05,
		# warm golden sun and a less blue fill: calibrated so sand and grass match the concept's
		# colours (sand ~(248,200,133) vs concept (248,201,118), grass ~(180,187,76) vs (185,180,63))
		"sun_color": Color(1.0, 0.9, 0.7), "sun_energy": 2.0, "sun_dir": Vector3(0.69, -0.72, 0.09),
		"fill_color": Color(1.0, 0.78, 0.58), "fill_energy": 0.42,  # warm brown shade, as in the concept
		"rim_color": Color(1.0, 0.97, 0.92), "rim_energy": 0.08,
		"shadow_opacity": 0.95, "shadow_blur": 1.0, "sun_angular": 1.5, "sdfgi_energy": 0.9, "sun_indirect": 1.2,
		"cloud_lit": Color(1.0, 1.0, 1.0), "cloud_shade": Color(0.8, 0.85, 0.94),
	},
	# Twilight (暮色): the sun just down in the west-north-west, deep blue sky with a pink
	# horizon, and the cities' lamps, doorways and windows lit warm (city_glow / city_lights).
	"twilight": {
		"sky_top": Color(0.1, 0.13, 0.3), "sky_horizon": Color(0.95, 0.52, 0.42),
		"ground_bottom": Color(0.18, 0.16, 0.28), "ground_horizon": Color(0.7, 0.45, 0.45),
		"ambient": 0.6, "exposure": 1.0, "saturation": 1.12, "contrast": 1.08,
		"glow": 0.85, "glow_threshold": 0.75,
		"sun_color": Color(0.92, 0.5, 0.55), "sun_energy": 0.22, "sun_dir": Vector3(0.95, -0.12, 0.2),
		"fill_color": Color(0.5, 0.58, 1.0), "fill_energy": 0.85,
		"rim_color": Color(1.0, 0.6, 0.5), "rim_energy": 0.2,
		"shadow_opacity": 0.85, "shadow_blur": 1.5, "sun_angular": 2.5, "sdfgi_energy": 0.8, "sun_indirect": 1.0,
		"sky_energy": 0.8, "sea_tint": Color(0.3, 0.34, 0.55), "sea_lines": 0.02, "city_lights": true,
		"smoke": Color(0.3, 0.32, 0.42, 0.7), "mist": Color(0.3, 0.34, 0.45), "mist_opacity": 0.25, "fire": 1.5, "fx_light": 0.38, "night_lift": 0.22,
		"cloud_lit": Color(0.98, 0.7, 0.62), "cloud_shade": Color(0.35, 0.36, 0.58),
	},
}


func apply_lighting(preset: String) -> void:
	if not LIGHTING.has(preset):
		push_warning("unknown lighting preset " + preset)
		preset = "dusk"
	light_name = preset
	var p: Dictionary = (LIGHTING[preset] as Dictionary).duplicate()
	if lighting_override.has(preset):
		for k in lighting_override[preset]:
			var val = lighting_override[preset][k]
			if val is Array and val.size() == 3 and k != "sun_dir":
				val = Color(val[0], val[1], val[2])
			elif val is Array and val.size() == 3:
				val = Vector3(val[0], val[1], val[2])
			p[k] = val
	sky_mat.sky_top_color = p.sky_top
	sky_mat.sky_horizon_color = p.sky_horizon
	sky_mat.ground_bottom_color = p.ground_bottom
	sky_mat.ground_horizon_color = p.ground_horizon
	env.ambient_light_energy = p.ambient
	env.tonemap_exposure = p.exposure
	env.adjustment_saturation = p.saturation
	env.adjustment_contrast = p.contrast
	env.glow_intensity = p.glow
	env.glow_hdr_threshold = p.glow_threshold
	sun.light_color = p.sun_color
	sun.light_energy = p.sun_energy
	sun.transform = Transform3D(Basis.looking_at((p.sun_dir as Vector3).normalized(), Vector3.UP), Vector3.ZERO)
	if ground_mat:
		ground_mat.set_shader_parameter("sun_dir", (p.sun_dir as Vector3).normalized())
	# the post pass lights facets toward the sun of the current preset
	set_post_param("sun_to", -(p.sun_dir as Vector3).normalized())
	fill.light_color = p.fill_color
	fill.light_energy = p.fill_energy
	rim.light_color = p.rim_color
	rim.light_energy = p.rim_energy
	# Shadow / occlusion shaping (optional keys; defaults are the build_environment values).
	env.ssao_radius = p.get("ssao_radius", 1.1)
	env.ssao_intensity = p.get("ssao_intensity", 2.0)
	env.ssao_power = p.get("ssao_power", 1.4)
	env.ssao_detail = p.get("ssao_detail", 0.5)
	env.ssao_horizon = p.get("ssao_horizon", 0.06)
	env.ssao_sharpness = p.get("ssao_sharpness", 0.98)
	env.ssao_light_affect = p.get("ssao_light_affect", 0.3)
	env.ssao_ao_channel_affect = p.get("ssao_ao_channel_affect", 0.0)
	env.ssil_radius = p.get("ssil_radius", 3.0)
	env.ssil_intensity = p.get("ssil_intensity", 0.9)
	env.sdfgi_energy = p.get("sdfgi_energy", 1.0)
	env.sdfgi_use_occlusion = p.get("sdfgi_use_occlusion", false)
	env.sdfgi_bounce_feedback = p.get("sdfgi_bounce_feedback", 0.55)
	env.sdfgi_min_cell_size = p.get("sdfgi_min_cell", 2.0)  # 1.4 left a cascade seam across the deep sea
	env.sdfgi_cascades = p.get("sdfgi_cascades", 4)
	var tm: String = p.get("tonemap", "agx")
	env.tonemap_mode = {"agx": Environment.TONE_MAPPER_AGX, "filmic": Environment.TONE_MAPPER_FILMIC, "aces": Environment.TONE_MAPPER_ACES}.get(tm, Environment.TONE_MAPPER_AGX)
	env.tonemap_white = p.get("tonemap_white", 1.0)
	sun.shadow_opacity = p.get("shadow_opacity", 0.8)
	sun.shadow_blur = p.get("shadow_blur", 2.0)
	sun.light_angular_distance = p.get("sun_angular", 3.0)
	sun.light_indirect_energy = p.get("sun_indirect", 1.0)
	sky_mat.energy_multiplier = p.get("sky_energy", 1.0)
	var tree_shadows: bool = p.get("tree_shadows", true)
	for mmi: MultiMeshInstance3D in tree_mmis:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if tree_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if sea_mat:
		sea_mat.set_shader_parameter("light_tint", p.get("sea_tint", Color(1, 1, 1)))
		sea_mat.set_shader_parameter("light_lines", p.get("sea_lines", 0.035))
	var lights_on: bool = p.get("city_lights", false)
	for g: Array in city_glow:
		var m: StandardMaterial3D = g[0]
		m.emission_enabled = lights_on
		m.emission = g[1]
		m.emission_energy_multiplier = g[2]
	for l in city_lights:
		l.visible = lights_on
	for sm in sealife_mats:
		sm.set_shader_parameter("night_lift", float(p.get("night_lift", 0.0)))
	if life:
		life.set_preset(p)
	if cloud_mat:
		cloud_mat.set_shader_parameter("lit", p.cloud_lit)
		cloud_mat.set_shader_parameter("shade", p.cloud_shade)
	if status_label:
		update_status()


func apply_fx_off() -> void:
	# Debug ablation (--fx-off=gi,ssao,...) to measure what each lighting feature contributes.
	if "gi" in fx_off:
		env.sdfgi_enabled = false
	if "ssao" in fx_off:
		env.ssao_enabled = false
	if "ssil" in fx_off:
		env.ssil_enabled = false
	if "shadow" in fx_off:
		sun.shadow_enabled = false
	if "fill" in fx_off:
		fill.light_energy = 0.0
		rim.light_energy = 0.0
	if "tilt" in fx_off and tilt_rect:
		tilt_rect.visible = false


func shader_from(path: String) -> Shader:
	if path == "" or path == "none":
		return null
	var code := ""
	if path.begins_with("res://"):
		if not ResourceLoader.exists(path):
			return null
		return load(path) as Shader
	if not FileAccess.file_exists(path):
		push_warning("post shader missing: " + path)
		return null
	code = FileAccess.get_file_as_string(path)
	var sh := Shader.new()
	sh.code = code
	return sh


func build_post() -> void:
	var s3 := shader_from(POST3D_PATH)
	if s3:
		post3d = MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(2, 2)
		post3d.mesh = q
		var m := ShaderMaterial.new()
		m.shader = s3
		# drawn first in the transparent queue: sea, clouds, rain, mist, smoke and dust cover it
		m.render_priority = -128
		post3d.material_override = m
		post3d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		post3d.extra_cull_margin = 16384.0
		camera.add_child(post3d)
		post3d.position = Vector3(0, 0, -1)
	var s2 := shader_from(POST2D_PATH)
	if s2:
		var layer := CanvasLayer.new()
		layer.layer = 1
		render_viewport.add_child(layer)
		post2d_rect = ColorRect.new()
		post2d_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		post2d_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var m2 := ShaderMaterial.new()
		m2.shader = s2
		post2d_rect.material = m2
		layer.add_child(post2d_rect)


func set_post_param(name: String, value: Variant) -> void:
	if post3d:
		(post3d.material_override as ShaderMaterial).set_shader_parameter(name, value)
	if post2d_rect:
		(post2d_rect.material as ShaderMaterial).set_shader_parameter(name, value)


func build_tilt_shift() -> void:
	build_post()
	tilt_layer = CanvasLayer.new()
	tilt_layer.layer = 2
	render_viewport.add_child(tilt_layer)
	tilt_rect = ColorRect.new()
	tilt_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tilt_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/merchant_board_claude/tilt_shift.gdshader")
	tilt_rect.material = m
	tilt_layer.add_child(tilt_rect)


func apply_tilt_for_view(v: String) -> void:
	if tilt_rect == null:
		return
	var m := tilt_rect.material as ShaderMaterial
	# Light tilt-shift: only the outer rows soften, so the ground facets and shadows stay
	# readable almost edge to edge like the concept (the earlier bands hid ~45% of the frame).
	var cfg := {"full": [0.55, 0.36, 0.22, 0.004], "target": [0.52, 0.46, 0.2, 0.003],
		"east": [0.5, 0.38, 0.22, 0.0035], "west": [0.5, 0.38, 0.22, 0.0035], "close": [0.5, 0.36, 0.22, 0.004]}
	var c: Array = cfg.get(v, [0.5, 0.38, 0.22, 0.0035])
	m.set_shader_parameter("focus_center", c[0])
	m.set_shader_parameter("focus_half", c[1])
	m.set_shader_parameter("falloff", c[2])
	m.set_shader_parameter("max_radius", c[3])


func build_sun_glow() -> void:
	# Warm light bloom from the top-left corner, as in the target (screen-space).
	var layer := CanvasLayer.new()
	render_viewport.add_child(layer)
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.86, 0.62, 0.3))
	grad.set_color(1, Color(1.0, 0.8, 0.55, 0.0))
	grad.add_point(0.35, Color(1.0, 0.84, 0.6, 0.06))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(0.14, 0.42)
	tex.width = 512
	tex.height = 512
	var rect := TextureRect.new()
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	rect.material = mat
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)


## 原始文件的读取路径：开发时照旧用磁盘上的绝对路径；导出包（没有 editor 特性）里磁盘上没有这些文件，
## 直接用 res:// 从安装包里读（导出配置 include_filter 把原始 .glb 和两张原始贴图打进了包里）。
static func raw_file_path(res_path: String) -> String:
	return ProjectSettings.globalize_path(res_path) if OS.has_feature("editor") else res_path


## 原始贴图：开发时读磁盘上的原图；导出包里原图不在（贴图只打包导入后的版本），退回用导入后的贴图取图像
static func load_raw_image(res_path: String) -> Image:
	var img: Image = null
	if FileAccess.file_exists(raw_file_path(res_path)) or FileAccess.file_exists(res_path):
		img = Image.load_from_file(raw_file_path(res_path))
	if img == null or img.is_empty():
		var tex := load(res_path) as Texture2D if ResourceLoader.exists(res_path) else null
		img = tex.get_image() if tex != null else null
	if img != null and img.is_compressed():
		img.decompress()
	return img


func load_gltf(res_path: String) -> Node3D:
	if use_model_cache and _gltf_cache.has(res_path):
		return (_gltf_cache[res_path] as PackedScene).instantiate() as Node3D
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(raw_file_path(res_path), state)
	if err != OK:
		push_error("GLTF load failed %s: %s" % [res_path, error_string(err)])
		return null
	var scene := doc.generate_scene(state) as Node3D
	if use_model_cache and scene != null:
		# 缓存成 PackedScene（网格、材质都是共享的资源），不留孤儿节点
		var packed := PackedScene.new()
		if packed.pack(scene) == OK:
			_gltf_cache[res_path] = packed
	return scene


func mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(mesh_instances(child))
	return out


func build_terrain() -> void:
	vc_material = StandardMaterial3D.new()
	vc_material.vertex_color_use_as_albedo = true
	vc_material.roughness = 0.93
	ground_mat = ShaderMaterial.new()
	ground_mat.shader = load(GROUND_SHADER_PATH)
	var b: Dictionary = layout.board
	ground_mat.set_shader_parameter("board_rect", Vector4(b.x0, b.z0, b.x1 - b.x0, b.z1 - b.z0))
	var dimg := load_raw_image(GROUND_DETAIL) if (FileAccess.file_exists(GROUND_DETAIL) or ResourceLoader.exists(GROUND_DETAIL)) else null
	if dimg != null:
		# 自制地图的铺地（城下石板跟着城挪、新城补一块）：只动 B 通道，在生成 mipmap 之前做（3.10.3 第 8 步）
		var paving: Array = layout.get("paving", [])
		ground_detail_src = dimg
		if not paving.is_empty():
			ground_detail_src = dimg.duplicate() as Image
			apply_paving(dimg, paving, layout.board)
		if not dimg.has_mipmaps():
			dimg.generate_mipmaps()
		ground_detail_tex = ImageTexture.create_from_image(dimg)
		ground_mat.set_shader_parameter("detail_tex", ground_detail_tex)
	for path in [TERRAIN, MOUNTAINS]:
		if path == MOUNTAINS and layout.has("kit"):
			continue
		var node := load_gltf(path)
		world_root.add_child(node)
		for mi in mesh_instances(node):
			if path == TERRAIN and layout.has("landscape"):
				var mesh_to_world := world_root.global_transform.affine_inverse() * mi.global_transform
				mi.mesh = CustomMapLandscape.deform_mesh(mi.mesh, mesh_to_world, CustomMapGeo.for_layout(layout))
				mi.set_meta("landscape_key", CustomMapGeo.for_layout(layout).cache_key())
			mi.material_override = ground_mat if path == TERRAIN else vc_material
	if FileAccess.file_exists(SNOW) and not layout.has("kit"):
		# Snow caps: a soft lavender lift so the shadow side still reads as snow.
		var snow_m := StandardMaterial3D.new()
		snow_m.vertex_color_use_as_albedo = true
		snow_m.roughness = 0.8
		snow_m.emission_enabled = true
		snow_m.emission = Color(0.1, 0.1, 0.13)
		var sn := load_gltf(SNOW)
		world_root.add_child(sn)
		for mi in mesh_instances(sn):
			mi.material_override = snow_m


## 自制地图的铺地操作（CustomBoardLayout.derive 第 8 步生成），只改 B 通道（城下的石板）：
##   {op: "move",  from: [x, z], to: [x, z], limit}：挪过的原城。先在旧位置按半径 r 的圆清零，再把旧位置那一块贴到新位置
##   {op: "stamp", src: [x, z], src_limit, to: [x, z], scale}：新城。从模板城抄一块，按 foot 的比例缩放后贴上
## r 是那座城 B > 0.02 那一圈的半径，从原图量（只在 limit 以内找，不量到邻城）。贴的时候逐像素取最大值，不盖掉别的城。
## 所有「抄」都从做任何操作之前的原图上抄，所以操作顺序不影响结果。
static func apply_paving(img: Image, ops: Array, board: Dictionary) -> void:
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	var src := img.duplicate() as Image
	var bx := float(board.get("x0", 0.0))
	var bz := float(board.get("z0", 0.0))
	var kx := float(img.get_width()) / maxf(float(board.get("x1", 128.0)) - bx, 1e-3)
	var kz := float(img.get_height()) / maxf(float(board.get("z1", 59.63)) - bz, 1e-3)
	var to_px := func(x: float, z: float) -> Vector2: return Vector2((x - bx) * kx - 0.5, (z - bz) * kz - 0.5)
	var radii: Array = []
	for op: Dictionary in ops:
		var c: Array = op.get("from", op.get("src", [0.0, 0.0]))
		radii.append(_pave_radius(src, to_px.call(float(c[0]), float(c[1])), float(op.get("limit", op.get("src_limit", 3.0))) * kx))
	for i in ops.size():
		var op: Dictionary = ops[i]
		if String(op.get("op", "")) == "move":
			_pave_clear(img, to_px.call(float(op.from[0]), float(op.from[1])), float(radii[i]))
	for i in ops.size():
		var op: Dictionary = ops[i]
		var kind := String(op.get("op", ""))
		var r := float(radii[i])
		if kind == "move":
			_pave_paste(img, src, to_px.call(float(op.from[0]), float(op.from[1])), to_px.call(float(op.to[0]), float(op.to[1])), r, 1.0)
		elif kind == "stamp":
			_pave_paste(img, src, to_px.call(float(op.src[0]), float(op.src[1])), to_px.call(float(op.to[0]), float(op.to[1])), r, float(op.get("scale", 1.0)))


static func _pave_radius(src: Image, c: Vector2, limit_px: float) -> float:
	var r := 0.0
	var lim := int(ceil(limit_px))
	for dy in range(-lim, lim + 1):
		for dx in range(-lim, lim + 1):
			var d := Vector2(dx, dy).length()
			if d > limit_px or d <= r:
				continue
			var px := int(round(c.x)) + dx
			var py := int(round(c.y)) + dy
			if px < 0 or py < 0 or px >= src.get_width() or py >= src.get_height():
				continue
			if src.get_pixel(px, py).b > 0.02:
				r = d
	return r + 1.0


static func _pave_clear(img: Image, c: Vector2, r: float) -> void:
	var lim := int(ceil(r))
	for dy in range(-lim, lim + 1):
		for dx in range(-lim, lim + 1):
			if Vector2(dx, dy).length() > r:
				continue
			var px := int(round(c.x)) + dx
			var py := int(round(c.y)) + dy
			if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
				continue
			var col := img.get_pixel(px, py)
			col.b = 0.0
			img.set_pixel(px, py, col)


static func _pave_paste(img: Image, src: Image, from: Vector2, to: Vector2, r: float, scale: float) -> void:
	var rd := r * scale
	var lim := int(ceil(rd))
	for dy in range(-lim, lim + 1):
		for dx in range(-lim, lim + 1):
			if Vector2(dx, dy).length() > rd:
				continue
			var px := int(round(to.x)) + dx
			var py := int(round(to.y)) + dy
			if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
				continue
			var sx := int(round(from.x + float(dx) / scale))
			var sy := int(round(from.y + float(dy) / scale))
			if sx < 0 or sy < 0 or sx >= src.get_width() or sy >= src.get_height():
				continue
			var b := src.get_pixel(sx, sy).b
			var col := img.get_pixel(px, py)
			if b > col.b:
				col.b = b
				img.set_pixel(px, py, col)


const SEA_SHADER := """
shader_type spatial;
render_mode shadows_disabled;
void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Small downward-biased swell so the facets shimmer without covering sea routes.
	VERTEX.y += 0.025 * (sin(w.x * 1.1 + TIME * 0.7) * cos(w.z * 0.9 - TIME * 0.5) - 1.0);
}
void fragment() {
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * 0.08;
	ROUGHNESS = 0.55;
	SPECULAR = 0.15;
}
"""

const FLAT_SHADER := """
shader_type spatial;
render_mode cull_back;
uniform vec4 base : source_color = vec4(1.0);
void vertex() {
	// SurfaceTool colours are authored in sRGB.
	COLOR.rgb = pow(COLOR.rgb, vec3(2.2));
}
void fragment() {
	NORMAL = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	ALBEDO = base.rgb * COLOR.rgb;
	ROUGHNESS = 0.9;
}
"""


func build_seabed() -> void:
	if not FileAccess.file_exists(SEABED):
		return
	var bed := load_gltf(SEABED)
	world_root.add_child(bed)
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/merchant_board_claude/board_seabed.gdshader")
	for mi in mesh_instances(bed):
		mi.material_override = m


func first_mesh(path: String) -> Array:
	# [mesh, local transform] of the first MeshInstance3D in a GLB.
	var scene := load_gltf(path)
	var mis := mesh_instances(scene)
	if mis.is_empty():
		return []
	var mi: MeshInstance3D = mis[0]
	var local := Transform3D.IDENTITY
	var n: Node = mi
	while n != null and n != scene:
		if n is Node3D:
			local = (n as Node3D).transform * local
		n = n.get_parent()
	var out := [mi.mesh, local]
	scene.queue_free()
	return out


const SWIM := {
	# asset: [motion mode, beat rate, amplitude, member spacing along the lane]
	"fish_yellow": [0, 9.0, 0.13, 0.28], "fish_tang": [0, 8.0, 0.13, 0.35], "fish_clown": [0, 8.5, 0.13, 0.35],
	"whale": [1, 1.4, 0.12, 3.0], "dolphin": [1, 5.0, 0.12, 0.9], "manta_ray": [2, 1.8, 0.18, 1.5], "sea_turtle": [3, 2.2, 0.12, 1.0],
}


func lane_of(d: Dictionary) -> Dictionary:
	var key := "%.3f,%.3f,%d" % [float(d.cx), float(d.cz), (d.points as Array).size()]
	if lanes.has(key):
		return lanes[key]
	var pts := PackedVector2Array()
	for q: Array in d.points:
		pts.append(Vector2(q[0], q[1]))
	var cum := PackedFloat32Array([0.0])
	for i in range(1, pts.size() + 1):
		cum.append(cum[i - 1] + pts[i - 1].distance_to(pts[i % pts.size()]))
	var lane := {"pts": pts, "cum": cum, "L": cum[cum.size() - 1]}
	lanes[key] = lane
	return lane


func lane_at(lane: Dictionary, s: float) -> Array:
	# [position, unit tangent] at arc length s on a closed lane
	var L: float = lane.L
	s = fposmod(s, L)
	var cum: PackedFloat32Array = lane.cum
	var i := cum.bsearch(s) - 1
	i = clampi(i, 0, cum.size() - 2)
	var pts: PackedVector2Array = lane.pts
	var a := pts[i]
	var b := pts[(i + 1) % pts.size()]
	var seg := maxf(cum[i + 1] - cum[i], 1e-5)
	var t := (s - cum[i]) / seg
	return [a.lerp(b, t), (b - a).normalized()]


func build_sea_life() -> void:
	# Fish schools and big creatures swim along closed lanes that follow the coasts
	# (build_board.py sea_life): nothing circles in place any more.
	var groups := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for d: Dictionary in layout.sea_life.schools + layout.sea_life.creatures:
		if not groups.has(d.asset):
			groups[d.asset] = []
		for i in int(d.count):
			groups[d.asset].append([d, i])
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/merchant_board_claude/board_swimmer.gdshader")
	sealife_mats.append(mat)
	for asset: String in groups:
		var dir := "fish" if asset.begins_with("fish_") else "sea_life"
		var path := "res://assets/merchant_board_claude/%s/%s.glb" % [dir, asset]
		if not FileAccess.file_exists(path):
			push_warning("sea life asset missing: " + path)
			continue
		var ml := first_mesh(path)
		if ml.is_empty():
			continue
		var sw: Array = SWIM.get(asset, [0, 8.0, 0.13, 0.3])
		var rows: Array = groups[asset]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = ml[0]
		mm.instance_count = rows.size()
		for k in rows.size():
			var d: Dictionary = rows[k][0]
			var i: int = rows[k][1]
			var lane := lane_of(d)
			var school := asset.begins_with("fish_")
			var params := {
				"s0": float(d.start) * float(lane.L), "speed": float(d.speed) * rng.randf_range(0.97, 1.03),
				"lag": i * float(sw[3]) + rng.randf_range(-0.08, 0.08) * float(sw[3]),
				"lat": rng.randf_range(-0.22, 0.22) if school else rng.randf_range(-0.15, 0.15) * float(i > 0),
				"depth": float(d.depth) + rng.randf_range(-0.03, 0.03), "size": float(d.size) * rng.randf_range(0.9, 1.08),
				"phase": rng.randf(), "asset": asset,
			}
			mm.set_instance_custom_data(k, Color(float(sw[0]), params.phase, float(sw[1]) * rng.randf_range(0.9, 1.1), float(sw[2])))
			swimmers.append([mm, k, lane, ml[1], params])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.extra_cull_margin = 200.0
		world_root.add_child(mmi)
	update_sea_life(0.0)
	print("SEA_LIFE instances=", swimmers.size())


func update_sea_life(t: float) -> void:
	for sw: Array in swimmers:
		var mm: MultiMesh = sw[0]
		var p: Dictionary = sw[4]
		var s: float = p.s0 + p.speed * t - p.lag
		var at := lane_at(sw[2], s)
		var pos: Vector2 = at[0]
		var tan: Vector2 = at[1]
		var nrm := Vector2(-tan.y, tan.x)
		var wob := sin(t * 0.7 + p.phase * 6.28) * 0.06
		pos += nrm * (float(p.lat) + wob)
		var y: float = p.depth + sin(t * 1.3 + p.phase * 6.28) * 0.02
		var pitch := 0.0
		if p.asset == "dolphin":
			# every ~8 s the pod leaps: a 1.4 s arc out of the water and back in
			var j := fposmod(t + p.phase * 2.0, 8.0) / 1.4
			if j < 1.0:
				y = p.depth + 0.5 * sin(PI * j)
				pitch = atan(0.5 * PI * cos(PI * j) / (1.4 * float(p.speed)))
		elif p.asset == "whale":
			# slow breathing: rises close to the surface now and then
			y = p.depth + 0.22 * pow(maxf(0.0, sin(t * 0.09 + p.phase * 6.28)), 6.0)
		var yaw := atan2(-tan.y, tan.x)
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, pitch)
		var size: float = p.size
		mm.set_instance_transform(sw[1], Transform3D(basis.scaled(Vector3(size, size, size)), Vector3(pos.x, y, pos.y)) * (sw[3] as Transform3D))


func build_fish_schools() -> void:
	var by_species := {}
	for sc: Dictionary in layout.schools:
		if not by_species.has(sc.asset):
			by_species[sc.asset] = []
		by_species[sc.asset].append(sc)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/merchant_board_claude/board_fish.gdshader")
	for sp: String in by_species:
		var path := "res://assets/merchant_board_claude/fish/%s.glb" % sp
		if not FileAccess.file_exists(path):
			continue
		var ml := first_mesh(path)
		if ml.is_empty():
			continue
		var rows: Array = []
		for sc: Dictionary in by_species[sp]:
			for f: Dictionary in sc.fish:
				rows.append([sc, f])
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = ml[0]
		mm.instance_count = rows.size()
		for i in rows.size():
			var sc: Dictionary = rows[i][0]
			var f: Dictionary = rows[i][1]
			var size: float = float(sc.size)
			var r: float = float(f.r)
			var t := Transform3D(Basis().scaled(Vector3(size, size, size)), Vector3(sc.x, float(sc.y) + float(f.dy), sc.z))
			mm.set_instance_transform(i, t * (ml[1] as Transform3D))
			mm.set_instance_custom_data(i, Color(r / size, float(f.phase), float(sc.speed) / maxf(r, 0.2), float(f.bob)))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# the swim offset reaches ~1.3 units from the instance origin
		mmi.extra_cull_margin = 4.0
		world_root.add_child(mmi)


func build_clouds() -> void:
	# Soft fleecy cloud sheets (camera-facing quads, fbm-eroded) framing the board.
	cloud_mat = ShaderMaterial.new()
	cloud_mat.shader = load("res://shaders/merchant_board_claude/board_cloud.gdshader")
	var mat := cloud_mat
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	for c: Dictionary in layout.clouds:
		if not c.has("w"):
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.scale = Vector3(float(c.w), float(c.h), 1.0)
		mi.position = Vector3(c.x, c.y, c.z)
		mi.set_instance_shader_parameter("seed", float(c.seed))
		mi.set_instance_shader_parameter("opacity", float(c.opacity))
		mi.extra_cull_margin = 20.0
		world_root.add_child(mi)
		clouds.append([mi, float(c.speed), float(c.x)])


func _process(_delta: float) -> void:
	if layout.is_empty():
		return
	var t := Time.get_ticks_msec() * 0.001
	if view_name == "lshu" and life and not life.lshu.is_empty():
		# key 8: the camera keeps following L叔 as he wanders and moves camp
		cam_target = cam_target.lerp(life.lshu_position(), 0.05)
		apply_camera()
	if not swimmers.is_empty():
		update_sea_life(t)
	for pair: Array in clouds:
		var mi: MeshInstance3D = pair[0]
		# slow back-and-forth drift around the cloud's home position
		mi.position.x = float(pair[2]) + sin(t * float(pair[1]) + float(pair[2])) * 1.5


func build_sea() -> void:
	# Low-poly sea mesh with baked depth colours, animated by the stylized sea shader.
	var sea := load_gltf(SEA)
	world_root.add_child(sea)
	var mat := ShaderMaterial.new()
	mat.shader = load(SEA_SHADER_PATH)
	sea_mat = mat
	var b: Dictionary = layout.board
	mat.set_shader_parameter("board_rect", Vector4(b.x0, b.z0, b.x1 - b.x0, b.z1 - b.z0))
	var img := load_raw_image(SEA_DIST)
	mat.set_shader_parameter("dist_tex", ImageTexture.create_from_image(img))
	for mi in mesh_instances(sea):
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func box(size: Vector3, pos: Vector3, color: Color, rough := 0.75) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	mi.material_override = m
	world_root.add_child(mi)
	return mi


func build_tray() -> void:
	# Walnut frame as in the target: the south rim sits at sea level so the land slab
	# stands proud of it (build_board.py front_edge); the other rims rise a little
	# above the land, with a bright bevel along their inner edge.
	var b: Dictionary = layout.board
	var w := 1.2
	var ws := 0.6
	var bottom := -2.6
	var wood_top := Color(0.5, 0.35, 0.24)
	var bevel := Color(0.78, 0.56, 0.32)
	var wood := Color(0.4, 0.28, 0.22)
	var cx: float = (b.x0 + b.x1) * 0.5
	var cz: float = (b.z0 + b.z1) * 0.5
	var lx: float = b.x1 - b.x0 + 2.0 * w
	var t_s := -0.02
	var t_o := 1.45
	box(Vector3(lx, t_s - bottom, ws), Vector3(cx, (t_s + bottom) * 0.5, b.z1 + ws * 0.5), wood)
	box(Vector3(lx, 0.04, ws), Vector3(cx, t_s - 0.02, b.z1 + ws * 0.5), wood_top, 0.45)
	box(Vector3(lx, t_o - bottom, w), Vector3(cx, (t_o + bottom) * 0.5, b.z0 - w * 0.5), wood)
	box(Vector3(w, t_o - bottom, b.z1 - b.z0 + ws), Vector3(b.x0 - w * 0.5, (t_o + bottom) * 0.5, cz + ws * 0.5), wood)
	box(Vector3(w, t_o - bottom, b.z1 - b.z0 + ws), Vector3(b.x1 + w * 0.5, (t_o + bottom) * 0.5, cz + ws * 0.5), wood)
	box(Vector3(lx, 0.04, w), Vector3(cx, t_o + 0.02, b.z0 - w * 0.5), wood_top, 0.45)
	box(Vector3(w, 0.04, b.z1 - b.z0 + ws + w), Vector3(b.x0 - w * 0.5, t_o + 0.02, cz + (ws - w) * 0.5), wood_top, 0.45)
	box(Vector3(w, 0.04, b.z1 - b.z0 + ws + w), Vector3(b.x1 + w * 0.5, t_o + 0.02, cz + (ws - w) * 0.5), wood_top, 0.45)
	# inner bevel strips
	box(Vector3(b.x1 - b.x0, 0.06, 0.2), Vector3(cx, t_o + 0.03, b.z0 - 0.1), bevel, 0.4)
	box(Vector3(0.2, 0.06, b.z1 - b.z0), Vector3(b.x0 - 0.1, t_o + 0.03, cz), bevel, 0.4)
	box(Vector3(0.2, 0.06, b.z1 - b.z0), Vector3(b.x1 + 0.1, t_o + 0.03, cz), bevel, 0.4)
	box(Vector3(b.x1 - b.x0, 0.2, b.z1 - b.z0), Vector3(cx, -0.9, cz), Color(0.05, 0.3, 0.5))


func unshaded(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = color
	return m


func build_routes() -> void:
	routes_node = Node3D.new()
	world_root.add_child(routes_node)
	# Dashes are small rounded pills (capsules lying along the route), cream on land
	# and cyan at sea, like the target's painted dashes.
	var segs := {"LAND": [], "SEA": [], "SEA_NEW": []}
	for r: Dictionary in layout.routes:
		var is_land: bool = r.type == "LAND"
		dash_segments(segs["SEA_NEW" if str(r.type) == "SEA" and str(r.id).contains("_x_") else str(r.type)], r.points, 0.12 if is_land else 0.18, 0.46 if is_land else 0.42)
	# [kind, radius, colour, emission, y offset]: a thin darker outline under each
	# bright dash; the dash sits above it so the outline only shows as a rim.
	var passes := [["LAND", 0.155, Color(0.54, 0.42, 0.28), 0.0, 0.0], ["LAND", 0.125, Color(0.99, 0.96, 0.85), 0.25, 0.035],
		["SEA", 0.145, Color(0.1, 0.5, 0.8), 0.1, 0.0], ["SEA", 0.115, Color(0.85, 0.97, 1.0), 0.3, 0.035],
		["SEA_NEW", 0.145, Color(0.1, 0.5, 0.8), 0.1, 0.015], ["SEA_NEW", 0.115, Color(0.85, 0.97, 1.0), 0.3, 0.05]]
	for ps: Array in passes:
		var cap := CapsuleMesh.new()
		cap.radius = ps[1]
		cap.height = 1.0
		cap.radial_segments = 8
		cap.rings = 2
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = cap
		var list: Array = segs[ps[0]]
		mm.instance_count = list.size()
		for i in list.size():
			var a: Vector3 = list[i][0]
			var b: Vector3 = list[i][1]
			var d := b - a
			var len := maxf(d.length(), 0.05)
			var y_axis := d / len
			var x_axis := y_axis.cross(Vector3.UP).normalized()
			var z_axis := x_axis.cross(y_axis).normalized()
			var basis := Basis(x_axis, y_axis * (len + 2.0 * cap.radius) / cap.height, z_axis * 0.55)
			mm.set_instance_transform(i, Transform3D(basis, (a + b) * 0.5 + Vector3(0, 0.03 + ps[4], 0)))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		var m := StandardMaterial3D.new()
		m.albedo_color = ps[2]
		m.roughness = 0.45
		if ps[3] > 0.0:
			m.emission_enabled = true
			m.emission = ps[2] * ps[3]
		mmi.material_override = m
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		routes_node.add_child(mmi)
	# Coin-style stops, as in the target: land = cream rim, bronze face, light centre
	# with a thin dark outline; sea = deep blue ring with a glowing cyan centre.
	for st: Dictionary in layout.stops:
		var land: bool = st.type == "LAND"
		var layers: Array
		if land:
			layers = [[0.68, 0.11, Color(0.4, 0.26, 0.14), 0.0], [0.64, 0.15, Color(1.0, 0.95, 0.8), 0.0],
				[0.5, 0.18, Color(0.72, 0.4, 0.17), 0.0], [0.33, 0.2, Color(1.0, 0.93, 0.75), 0.0],
				[0.22, 0.22, Color(0.82, 0.5, 0.22), 0.0]]
		else:
			layers = [[0.66, 0.13, Color(1, 1, 1), 0.1], [0.58, 0.17, Color(0.1, 0.55, 0.92), 0.2],
				[0.4, 0.2, Color(0.35, 0.82, 1.0), 0.3]]
		for layer: Array in layers:
			var cm := CylinderMesh.new()
			cm.top_radius = layer[0]
			cm.bottom_radius = layer[0]
			cm.height = layer[1]
			cm.radial_segments = 24
			var mi := MeshInstance3D.new()
			mi.mesh = cm
			var m := StandardMaterial3D.new()
			m.albedo_color = layer[2]
			m.roughness = 0.5
			if layer[3] > 0.0:
				m.emission_enabled = true
				m.emission = layer[2] * layer[3]
			mi.material_override = m
			# Sea coins cast no shadow: through the clear water it lands as a navy blob on the seabed.
			if not land:
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# Tilt coins ~18 deg toward the camera so their faces read, as in the target.
			var tilt := Basis(Vector3.RIGHT, deg_to_rad(18.0))
			mi.transform = Transform3D(tilt, Vector3(st.x, st.y, st.z) + tilt * Vector3(0, layer[1] * 0.5, 0))
			routes_node.add_child(mi)


func build_rivers() -> void:
	if not layout.has("rivers"):
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for rv in layout.rivers:
		var line: Array = rv.points if rv is Dictionary else rv
		var w: float = float(rv.w) if rv is Dictionary else 0.15
		var dist := 0.0
		for i in range(1, line.size()):
			var a := Vector3(line[i - 1][0], line[i - 1][1], line[i - 1][2])
			var b := Vector3(line[i][0], line[i][1], line[i][2])
			var seg := a.distance_to(b)
			flow_ribbon(st, a - (b - a) * 0.15, b, w, dist - seg * 0.15, dist + seg)
			dist += seg
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := ShaderMaterial.new()
	m.shader = load(RIVER_SHADER_PATH)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world_root.add_child(mi)


func flow_ribbon(st: SurfaceTool, a: Vector3, b: Vector3, width: float, u0: float, u1: float) -> void:
	var d := b - a
	d.y = 0.0
	if d.length() < 0.001:
		return
	var side := Vector3(-d.z, 0, d.x).normalized() * width * 0.5
	var lift := Vector3(0, 0.035, 0)
	var v := [a - side + lift, a + side + lift, b + side + lift, b - side + lift]
	var uv := [Vector2(u0, 0), Vector2(u0, 1), Vector2(u1, 1), Vector2(u1, 0)]
	for idx in [0, 1, 2, 0, 2, 3]:
		st.set_normal(Vector3.UP)
		st.set_uv(uv[idx])
		st.add_vertex(v[idx])


func dash_segments(out: Array, pts: Array, dash: float, gap: float) -> void:
	var acc := 0.0
	var on := true
	var seg_start := Vector3(pts[0][0], pts[0][1], pts[0][2])
	var prev := seg_start
	for i in range(1, pts.size()):
		var p := Vector3(pts[i][0], pts[i][1], pts[i][2])
		acc += prev.distance_to(p)
		if on and acc >= dash:
			out.append([seg_start, p])
			on = false
			acc = 0.0
		elif not on and acc >= gap:
			on = true
			acc = 0.0
			seg_start = p
		prev = p


func dashes(st: SurfaceTool, pts: Array, dash: float, gap: float, width: float) -> void:
	var acc := 0.0
	var on := true
	var seg_start := Vector3(pts[0][0], pts[0][1], pts[0][2])
	var prev := seg_start
	for i in range(1, pts.size()):
		var p := Vector3(pts[i][0], pts[i][1], pts[i][2])
		acc += prev.distance_to(p)
		if on and acc >= dash:
			ribbon(st, seg_start, p, width)
			on = false
			acc = 0.0
		elif not on and acc >= gap:
			on = true
			acc = 0.0
			seg_start = p
		prev = p


func ribbon(st: SurfaceTool, a: Vector3, b: Vector3, width: float) -> void:
	var d := b - a
	d.y = 0.0
	if d.length() < 0.001:
		return
	var side := Vector3(-d.z, 0, d.x).normalized() * width * 0.5
	var lift := Vector3(0, 0.035, 0)
	var v := [a - side + lift, a + side + lift, b + side + lift, b - side + lift]
	for idx in [0, 1, 2, 0, 2, 3]:
		st.set_normal(Vector3.UP)
		st.add_vertex(v[idx])


func node_aabb(node: Node3D, xf: Transform3D, acc: Array) -> void:
	var here := xf * node.transform
	if node is MeshInstance3D and node.mesh:
		var box := here * (node as MeshInstance3D).mesh.get_aabb()
		acc[0] = box if acc[0] == null else (acc[0] as AABB).merge(box)
	for child in node.get_children():
		if child is Node3D:
			node_aabb(child, here, acc)


func build_cities() -> void:
	for c: Dictionary in layout.cities:
		build_city(c)


## 一座城（build_cities 逐城调；工坊轻量刷新时单独加一座新城、或重建换了样子的城）
func build_city(c: Dictionary) -> void:
	# 自制地图的新城写明了模型（目录里的原型）和它的包围盒；原版 16 城照旧按 id 找
	var path: String = str(c.get("model", CITY_DIR + str(c.id) + ".glb"))
	var node: Node3D = null
	var building_only := FileAccess.file_exists(path)
	# Custom cities use the exact asset gate used by Validator/Loader. Failure
	# aborts this city; it cannot become a raw GLTF or placeholder success.
	if c.has("model"):
		var packed := CustomMapValidator.model_scene(path)
		if packed == null:
			push_error("CUSTOM_MAP_WORLD rejected invalid catalogue model %s: %s" % [str(c.id), path])
			return
		node = packed.instantiate() as Node3D
		building_only = true
	elif building_only:
		node = load_gltf(path)
	var bounds: Variant = city_bounds.get(c.id, c.get("bounds"))
	if node == null:
		building_only = false
		node = (load(FALLBACK_CITY_DIR + str(c.id) + ".glb") as PackedScene).instantiate() as Node3D
	var holder := Node3D.new()
	holder.name = "City_" + str(c.id)
	holder.add_child(node)
	var s: float
	if building_only and bounds is Dictionary and not (bounds as Dictionary).is_empty():
		var bb: Dictionary = bounds
		node.position -= Vector3(bb.building_centre_xz[0], 0.0, bb.building_centre_xz[1])
		s = float(c.foot) / float(bb.building_width)
	else:
		var acc := [null]
		node_aabb(node, Transform3D.IDENTITY, acc)
		var box: AABB = acc[0]
		var centre := box.get_center()
		node.position -= Vector3(centre.x, box.position.y, centre.z)
		s = float(c.foot) / maxf(box.size.x, box.size.z)
	holder.scale = Vector3.ONE * s
	var fit: Array = [0.0, 0.0, 0.0] if c.has("model") else CITY_FIT.get(str(c.id), [CITY_YAW, 0.0, 0.0])
	holder.rotation.y = float(c.rotation) + float(fit[0])
	holder.position = Vector3(float(c.x) + float(fit[1]), c.y - 0.02, float(c.z) + float(fit[2]))
	world_root.add_child(holder)
	for cmi in mesh_instances(holder):
		cmi.layers = 2  # layer 2 only: lit by CityLift, not darkened by the contact decal
	var entry := {"node": holder, "building_only": building_only, "scale": s}
	city_nodes[c.id] = entry
	var shadow := contact_shadow(Vector3(float(c.x) + float(fit[1]), c.y, float(c.z) + float(fit[2])), float(c.foot))
	world_root.add_child(shadow)
	var n_lights := city_lights.size()
	add_city_night(holder, c)
	# 工坊就地挪城、拆城时要一起动的东西（只多记引用）
	entry["shadow"] = shadow
	entry["lights"] = city_lights.slice(n_lights)
	entry["model"] = path
	entry["foot"] = float(c.foot)


## 连兜底小镇都读不到时：一块土黄色的方块当城（只防崩；导出门禁保证正式包里不会走到这里）
func _placeholder_town() -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.0, 0.5, 1.0)
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.85, 0.72, 0.5)
	mi.material_override = m
	mi.position = Vector3(0.0, 0.25, 0.0)
	root.add_child(mi)
	return root


const WINDOW_GLOW := Color(1.0, 0.62, 0.28)
const LAMP_GLOW := Color(1.0, 0.74, 0.4)


func add_city_night(holder: Node3D, c: Dictionary) -> void:
	# Evening lights (twilight preset): lamp meshes glow and each lamp cluster gets a warm
	# omni light; doorways, arches and window recesses (the models' dark/reveal materials)
	# glow like lit interiors; a soft pool of light over the city. Off in other presets.
	var lamp_pts: Array[Vector3] = []
	var re_window := RegEx.create_from_string("(^|_)Dark(\\.|_|$)|DeepArch|Entry_Reveal|CedarDoor|EntryFrameShade|PagodaReveal|EaveUnderside")
	for mi in mesh_instances(holder):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for si in mesh.get_surface_count():
			var m := mi.get_active_material(si) as StandardMaterial3D
			if m == null:
				continue
			var nm := String(m.resource_name)
			var lamp := nm.contains("Lamp")
			if not lamp and re_window.search(nm) == null:
				continue
			var mm := m.duplicate() as StandardMaterial3D
			mi.set_surface_override_material(si, mm)
			city_glow.append([mm, LAMP_GLOW if lamp else WINDOW_GLOW, 5.0 if lamp else 1.8])
			if lamp:
				var verts: PackedVector3Array = mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
				var xf := mi.global_transform
				for vi in range(0, verts.size(), 3):
					lamp_pts.append(xf * verts[vi])
	# cluster lamp vertices into lamp positions (0.35 u grid), keep up to 5 per city
	var cells := {}
	for q in lamp_pts:
		var key := Vector3i(floori(q.x / 0.35), 0, floori(q.z / 0.35))
		if not cells.has(key):
			cells[key] = [Vector3.ZERO, 0]
		cells[key][0] += q
		cells[key][1] += 1
	var centres: Array = []
	for key in cells:
		centres.append(cells[key][0] / float(cells[key][1]))
	centres.sort_custom(func(a, b): return a.x + a.z * 0.37 < b.x + b.z * 0.37)
	var step := maxi(1, centres.size() / 5)
	for i in range(0, centres.size(), step):
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.62, 0.3)
		l.light_energy = 1.3
		l.omni_range = 1.3
		l.omni_attenuation = 1.4
		l.shadow_enabled = false
		l.position = (centres[i] as Vector3) + Vector3(0, 0.12, 0)
		l.visible = false
		world_root.add_child(l)
		city_lights.append(l)
	var pool := OmniLight3D.new()
	pool.light_color = Color(1.0, 0.66, 0.36)
	pool.light_energy = 0.8
	pool.omni_range = float(c.foot) * 0.95
	pool.omni_attenuation = 1.2
	pool.shadow_enabled = false
	pool.position = Vector3(c.x, float(c.y) + float(c.foot) * 0.35, c.z + 0.3)
	pool.visible = false
	world_root.add_child(pool)
	city_lights.append(pool)


func contact_shadow(pos: Vector3, foot: float) -> Decal:
	# Soft dark footprint under a city so it sits on the ground (only layer 1: ground,
	# trees, props — not the city itself, which is on layer 2).
	var grad := Gradient.new()
	grad.set_color(0, Color(0.16, 0.12, 0.1, 0.55))
	grad.set_color(1, Color(0.16, 0.12, 0.1, 0.0))
	grad.add_point(0.55, Color(0.16, 0.12, 0.1, 0.35))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 128
	tex.height = 128
	var d := Decal.new()
	d.texture_albedo = tex
	d.size = Vector3(foot * 1.25, 1.2, foot * 1.05)
	d.position = pos + Vector3(0.12, 0.0, 0.08)
	d.cull_mask = 1
	d.upper_fade = 0.3
	d.lower_fade = 0.3
	return d


func build_kit_instances(rows: Array, dir: String, cast_shadows: bool, material: Material = null, seg := "") -> void:
	# One MultiMesh per modelled kit asset (GLBs normalised to height 1.0).
	# seg：布局段名（tree_kit / kit / props）。给了就把每一行记进 decor_index，layout.decor_cleared[seg] 里的行
	# （自制地图清掉的装饰）实例缩成 0：实例都在，工坊就地整理时能再恢复（3.12.7）
	var by_asset := {}
	var by_asset_rows := {}
	for ri in rows.size():
		var r: Dictionary = rows[ri]
		if not by_asset.has(r.asset):
			by_asset[r.asset] = []
			by_asset_rows[r.asset] = []
		by_asset[r.asset].append(r)
		by_asset_rows[r.asset].append(ri)
	var cleared := {}
	if seg != "":
		for ci in (layout.get("decor_cleared", {}) as Dictionary).get(seg, []):
			cleared[int(ci)] = true
		if not decor_index.has(seg):
			decor_index[seg] = {}
		decor_hidden[seg] = cleared.duplicate()
	var mat: Material = material
	if mat == null:
		var sm := StandardMaterial3D.new()
		sm.vertex_color_use_as_albedo = true
		sm.roughness = 0.9
		mat = sm
	for asset: String in by_asset:
		var path := dir + asset + ".glb"
		if not FileAccess.file_exists(path):
			push_warning("kit asset missing: " + path)
			continue
		var scene := load_gltf(path)
		var mis := mesh_instances(scene)
		if mis.is_empty():
			continue
		var list: Array = by_asset[asset]
		for mi in mis:
			var local := Transform3D.IDENTITY
			var n: Node = mi
			while n != null and n != scene:
				if n is Node3D:
					local = (n as Node3D).transform * local
				n = n.get_parent()
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mi.mesh
			mm.instance_count = list.size()
			var row_ids: Array = by_asset_rows[asset]
			for i in list.size():
				var r: Dictionary = list[i]
				var s: float = float(r.s)
				var t := Transform3D(Basis(Vector3.UP, float(r.yaw)).scaled(Vector3(s, s, s)), Vector3(r.x, r.y, r.z))
				if seg == "":
					mm.set_instance_transform(i, t * local)
					continue
				var ri := int(row_ids[i])
				var xf := t * local
				if not decor_index[seg].has(ri):
					decor_index[seg][ri] = []
				decor_index[seg][ri].append([mm, i, xf])
				mm.set_instance_transform(i, hidden_transform(xf) if cleared.has(ri) else xf)
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = mat
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			world_root.add_child(mmi)
			if dir.ends_with("/trees/"):
				tree_mmis.append(mmi)
		scene.queue_free()


## 工坊就地整理（3.12.7）：按新推导结果的 decor_cleared 把该清的缩成 0、不再该清的放回原 transform。返回改动的行数
func set_decor_cleared(cleared: Dictionary) -> int:
	var changed := 0
	for seg in decor_index:
		var want := {}
		for ci in cleared.get(seg, []):
			want[int(ci)] = true
		var now: Dictionary = decor_hidden.get(seg, {})
		for ri in decor_index[seg]:
			var hide := want.has(ri)
			if hide == now.has(ri):
				continue
			for e: Array in decor_index[seg][ri]:
				(e[0] as MultiMesh).set_instance_transform(int(e[1]), hidden_transform(e[2]) if hide else (e[2] as Transform3D))
			changed += 1
		decor_hidden[seg] = want
	return changed


## 植物编辑只重建四种树的分组；地形、城市、商路及其他装饰节点保留。
func update_tree_instances(next: Dictionary) -> void:
	for node: MultiMeshInstance3D in tree_mmis:
		if is_instance_valid(node): node.free()
	tree_mmis.clear()
	decor_index.erase("tree_kit"); decor_hidden.erase("tree_kit")
	layout = next
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/merchant_board_claude/board_tree_sway.gdshader")
	build_kit_instances(layout.tree_kit, "res://assets/merchant_board_claude/trees/", false, material, "tree_kit")


## 工坊就地整理（3.12.7）：在留着的原图上重放全部铺地操作，重新生成 mipmap，原地更新贴图（尺寸、格式不变）
func replay_paving(ops: Array) -> void:
	if ground_detail_src == null or ground_detail_tex == null:
		return
	var img := ground_detail_src.duplicate() as Image
	img.clear_mipmaps()
	if not ops.is_empty():
		apply_paving(img, ops, layout.board)
	img.generate_mipmaps()
	ground_detail_tex.update(img)


## 被清掉的装饰：原地缩成 0（MultiMesh 的实例不能单独隐藏）
static func hidden_transform(xf: Transform3D) -> Transform3D:
	return Transform3D(Basis.from_scale(Vector3(0.0001, 0.0001, 0.0001)), xf.origin)


func tree_mesh(pine: bool) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if pine:
		# Chunky two-tier pine, as round-shouldered as the target's trees.
		cone(st, 0.0, 0.16, 0.08, 7, Color(0.42, 0.29, 0.16))
		cone(st, 0.1, 0.78, 0.36, 7, Color(0.24, 0.4, 0.12))
		cone(st, 0.46, 1.16, 0.27, 7, Color(0.38, 0.54, 0.16))
	else:
		cone(st, 0.0, 0.3, 0.07, 5, Color(0.42, 0.29, 0.16))
		blob(st, Vector3(0, 0.55, 0), 0.36, Color(0.34, 0.5, 0.14))
	return st.commit()


func cone(st: SurfaceTool, y0: float, y1: float, r: float, n: int, color: Color) -> void:
	var tip := Vector3(0, y1, 0)
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		var p0 := Vector3(cos(a0) * r, y0, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, y0, sin(a1) * r)
		for v in [p0, tip, p1]:
			st.set_color(color)
			st.add_vertex(v)
		for v in [p0, p1, Vector3(0, y0, 0)]:
			st.set_color(color * 0.8)
			st.add_vertex(v)


func blob(st: SurfaceTool, c: Vector3, r: float, color: Color) -> void:
	var top := c + Vector3(0, r * 1.05, 0)
	var bot := c - Vector3(0, r * 0.75, 0)
	var n := 6
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		var p0 := c + Vector3(cos(a0) * r, 0.05, sin(a0) * r)
		var p1 := c + Vector3(cos(a1) * r, 0.05, sin(a1) * r)
		for v in [p0, top, p1]:
			st.set_color(color)
			st.add_vertex(v)
		for v in [p0, p1, bot]:
			st.set_color(color * 0.85)
			st.add_vertex(v)


func build_trees() -> void:
	for kind in [0, 1]:
		var rows: Array = []
		for t: Array in layout.trees:
			if int(t[4]) == kind:
				rows.append(t)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = tree_mesh(kind == 0)
		mm.instance_count = rows.size()
		var rng := RandomNumberGenerator.new()
		rng.seed = 7 + kind
		for i in rows.size():
			var t: Array = rows[i]
			var s: float = float(t[3])
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.9, 1.2), s))
			mm.set_instance_transform(i, Transform3D(basis, Vector3(t[0], float(t[1]) - 0.03, t[2])))
			var shade := rng.randf_range(0.85, 1.1)
			mm.set_instance_color(i, Color(shade, shade, shade))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		var mat := ShaderMaterial.new()
		mat.shader = flat_shader
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world_root.add_child(mmi)


# ------------------------------------------------------------------ camera
func set_view(v: String) -> void:
	view_name = v
	var cfg: Dictionary = VIEWS[v]
	cam_target = cfg.target
	if cfg.get("persp", false):
		camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		camera.fov = 34.0
		cam_distance = cfg.distance
	else:
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam_size = cfg.size
	# The target framing is 3:1 like Carlos's image; the other views are 16:9.
	render_viewport.size = TARGET_SIZE if v == "target" else IMAGE_SIZE
	apply_tilt_for_view(v)
	apply_camera()
	update_status()


func apply_camera() -> void:
	var cfg: Dictionary = VIEWS[view_name]
	if camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
		var e := deg_to_rad(float(cfg.elev))
		camera.position = cam_target + Vector3(0, sin(e), cos(e)) * cam_distance
	else:
		var pitch := deg_to_rad(float(cfg.elev)) if cfg.has("elev") else GAME_PITCH
		camera.size = cam_size
		camera.position = cam_target + Vector3(0, sin(pitch), cos(pitch)) * 120.0
	camera.look_at(cam_target, Vector3.UP)


func find_lshu() -> void:
	# Easter egg: fly the close camera to wherever L叔 is camping right now.
	if life == null or life.lshu.is_empty():
		return
	VIEWS["lshu"] = {"target": life.lshu_position(), "size": 6.0}
	view_name = "lshu"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	render_viewport.size = IMAGE_SIZE
	apply_tilt_for_view("close")
	cam_target = life.lshu_position()
	cam_size = 6.0
	apply_camera()
	status_label.text = "找到 L叔 了！（按 1–7 回到其他镜头）"


func _unhandled_input(event: InputEvent) -> void:
	if capture_mode:
		return
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_1: set_view("full")
			KEY_2: set_view("east")
			KEY_3: set_view("west")
			KEY_4: set_view("close")
			KEY_5: set_view("target")
			KEY_6: set_view("reef")
			KEY_7: set_view("sea")
			KEY_8: find_lshu()
			KEY_R: routes_node.visible = not routes_node.visible
			KEY_L: apply_lighting({"noon": "dusk", "dusk": "twilight", "twilight": "noon"}.get(light_name, "noon"))
			KEY_ESCAPE: get_tree().quit()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var f := 0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.11
			if camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
				cam_distance = clampf(cam_distance * f, 20.0, 220.0)
			else:
				cam_size = clampf(cam_size * f, 6.0, 90.0)
			apply_camera()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			dragging = event.pressed
	elif event is InputEventMouseMotion and dragging:
		var scale := (cam_size if camera.projection == Camera3D.PROJECTION_ORTHOGONAL else cam_distance * 0.6) / float(get_viewport().get_visible_rect().size.y)
		cam_target += Vector3(-event.relative.x, 0, -event.relative.y) * scale * 1.8
		apply_camera()


# ------------------------------------------------------------------ capture
func capture_views() -> void:
	DirAccess.make_dir_recursive_absolute(capture_dir)
	var report := {"views": [], "cities": []}
	for v: String in capture_views_list:
		set_view(v)
		for frame in capture_wait:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := render_viewport.get_texture().get_image()
		var path := capture_dir.path_join(v + ".png")
		image.save_png(path)
		var widths := {}
		for id in city_nodes:
			widths[id] = city_screen_width(city_nodes[id].node)
		report.views.append({"view": v, "image": path, "city_px_width": widths})
	for id in city_nodes:
		report.cities.append({"id": id, "building_only": city_nodes[id].building_only, "scale": city_nodes[id].scale})
	var f := FileAccess.open(capture_dir.path_join("capture-report.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	print("MERCHANT_BOARD_CLAUDE_CAPTURED ", capture_dir)


func city_screen_width(holder: Node3D) -> float:
	var acc := [null]
	node_aabb(holder, holder.get_parent().global_transform, acc)
	var box: AABB = acc[0]
	var xs: Array[float] = []
	for i in 8:
		var p := box.get_endpoint(i)
		if camera.is_position_behind(p):
			return -1.0
		xs.append(camera.unproject_position(p).x)
	return xs.max() - xs.min()
