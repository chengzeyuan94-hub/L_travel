extends Node3D
## Independent storm study. Configure after the viewer has built its scene.
## No period/weather clocks, layout data or project settings are changed.
## Material overrides are local copies and restore() restores every original reference.
const SKY_SHADER := preload("res://shaders/traveler/baghdad/baghdad_storm_sky.gdshader")
const TREE_GLOW_SHADER := preload("res://shaders/traveler/baghdad/baghdad_tree_sunglow.gdshader")
const RenderGlobals := preload("res://scripts/traveler/render_globals.gd")

@export var sky_energy := 0.95
@export var ambient_energy := 0.48
@export var exposure := 1.08
@export var beam_energy := 64.0
@export var beam_volumetric_energy := 2.0
@export var beam_angle_deg := 5.5
@export var global_fog_density := 0.0
@export var scatter_density := 0.03
@export var distant_mist_density := 0.055
@export var foreground_fill_energy := 1.25
@export var tree_glow_strength := 6.5

var viewer: Node3D
var sky_material: ShaderMaterial
var tree_beam: SpotLight3D
var tree_bounds := AABB()
var _environment: Environment
var _sun: DirectionalLight3D
var _saved_environment: Dictionary = {}
var _saved_sun: Dictionary = {}
var _owned_nodes: Array[Node] = []
var _saved_materials: Array[Dictionary] = []
var _camera: Camera3D
var _saved_camera_attributes: CameraAttributes
var _camera_attributes_changed := false
var _surface_pass: RefCounted
var _surface_evidence: Dictionary = {}
var _scatter_volume: FogVolume
var _saved_fog_grid := Vector2i.ZERO
var _saved_fog_filter := true
var _tree_glow_materials: Array[ShaderMaterial] = []
var _configured := false

func configure(host: Node3D) -> void:
	if _configured:
		restore()
	viewer = host
	_environment = host.get("environment") as Environment
	_sun = host.get("sun") as DirectionalLight3D
	var tree := host.get("tree") as Node3D
	var camera := host.get("camera") as Camera3D
	if _environment == null or _sun == null or tree == null or camera == null:
		push_error("BaghdadStormLook requires the completed viewer environment, sun, tree and camera")
		return
	if get_parent() == null:
		host.add_child(self)
	name = "BaghdadStormLook"
	tree_bounds = _world_bounds(tree)
	if tree_bounds.size.y < 0.01:
		push_error("BaghdadStormLook could not measure the TreeOfLife mesh bounds")
		return
	_configured = true
	var height := tree_bounds.size.y
	var base := Vector3(tree_bounds.get_center().x, tree_bounds.position.y, tree_bounds.get_center().z)
	var right := camera.global_basis.x.normalized()
	var toward_camera := camera.global_position - base
	toward_camera.y = 0.0
	toward_camera = toward_camera.normalized()
	# Pass in front of the dense crown: its shadow can no longer extinguish the
	# entire visible light path before the shaft reaches the lower trunk.
	var beam_origin := base - right * height * 1.15 + Vector3.UP * height * 1.90 + toward_camera * height * 0.75
	var beam_target := base + Vector3.UP * height * 0.48 - right * height * 0.10 + toward_camera * height * 0.40
	var cloudbreak := base - right * height * 0.65 + Vector3.UP * height * 1.10 - toward_camera * height * 0.35
	_configure_sky((cloudbreak - camera.global_position).normalized())
	_configure_environment(base.distance_to(camera.global_position), height)
	_configure_sun()
	_configure_focus(camera)
	_configure_materials(tree, camera)
	_surface_pass = load("res://scripts/traveler/baghdad/baghdad_storm_surface.gd").new()
	_surface_evidence = _surface_pass.apply(host)
	_build_fog(base, height, toward_camera, beam_origin, beam_target)
	_build_lights(base, height, right, toward_camera, beam_origin, beam_target)
	_configure_tree_glow(tree)
	set_meta("evidence", evidence())
	print("BAGHDAD_STORM_READY ", JSON.stringify(evidence()))

func _configure_sky(opening_direction: Vector3) -> void:
	sky_material = ShaderMaterial.new()
	sky_material.shader = SKY_SHADER
	sky_material.set_shader_parameter("sky_energy", sky_energy)
	sky_material.set_shader_parameter("opening_direction", opening_direction)
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	_env("background_mode", Environment.BG_SKY)
	_env("sky", sky)
	_env("sky_rotation", Vector3.ZERO)
	_env("background_energy_multiplier", 1.0)

func _configure_environment(tree_distance: float, height: float) -> void:
	_env("ambient_light_source", Environment.AMBIENT_SOURCE_COLOR)
	_env("ambient_light_color", Color(0.47, 0.55, 0.68))
	_env("ambient_light_energy", ambient_energy)
	_env("ambient_light_sky_contribution", 0.0)
	_env("reflected_light_source", Environment.REFLECTION_SOURCE_SKY)
	_env("tonemap_mode", Environment.TONE_MAPPER_AGX)
	_env("tonemap_exposure", exposure)
	_env("adjustment_enabled", true)
	_env("adjustment_saturation", 0.90)
	_env("adjustment_contrast", 1.03)
	_env("ssao_enabled", true)
	_env("ssao_radius", 0.28)
	_env("ssao_intensity", 0.65)
	_env("ssao_power", 1.35)
	_env("ssao_detail", 0.6)
	_env("ssao_light_affect", 0.15)
	_env("ssil_enabled", false)
	_env("glow_enabled", true)
	_env("glow_intensity", 0.55)
	_env("glow_strength", 1.0)
	_env("glow_bloom", 0.0)
	_env("glow_hdr_threshold", 1.35)
	_env("glow_hdr_scale", 0.8)
	_env("glow_blend_mode", Environment.GLOW_BLEND_MODE_ADDITIVE)
	# Screen-depth haze starts beyond the tree; it does not wash out the paving.
	_env("fog_enabled", true)
	_env("fog_mode", Environment.FOG_MODE_DEPTH)
	_env("fog_light_color", Color(0.31, 0.38, 0.47))
	_env("fog_light_energy", 0.65)
	_env("fog_density", 0.55)
	_env("fog_depth_begin", maxf(tree_distance * 0.96, 12.0))
	_env("fog_depth_end", maxf(tree_distance + height * 6.8, 60.0))
	_env("fog_depth_curve", 1.25)
	_env("fog_sky_affect", 0.0)
	_env("fog_aerial_perspective", 0.12)
	# Real participating media: the shaft comes from a shadowed SpotLight3D.
	_env("volumetric_fog_enabled", true)
	_env("volumetric_fog_density", global_fog_density)
	_env("volumetric_fog_albedo", Color.WHITE)
	_env("volumetric_fog_emission", Color.BLACK)
	_env("volumetric_fog_emission_energy", 0.0)
	_env("volumetric_fog_anisotropy", 0.0)
	_env("volumetric_fog_length", clampf(tree_distance + height * 3.5, 40.0, 60.0))
	_env("volumetric_fog_detail_spread", 1.5)
	_env("volumetric_fog_ambient_inject", 0.0)
	_env("volumetric_fog_gi_inject", 0.0)
	_saved_fog_grid = Vector2i(int(ProjectSettings.get_setting("rendering/environment/volumetric_fog/volume_size", 64)),
		int(ProjectSettings.get_setting("rendering/environment/volumetric_fog/volume_depth", 64)))
	RenderGlobals.volumetric_fog_volume(192, 128)
	_saved_fog_filter = bool(ProjectSettings.get_setting("rendering/environment/volumetric_fog/use_filter", true))
	RenderGlobals.volumetric_fog_filter(false)
	# Zero suppresses the light shaft wherever the background is sky. Depth fog
	# still leaves the sky alone, but real participating media must composite on it.
	_env("volumetric_fog_sky_affect", 1.0)
	_env("volumetric_fog_temporal_reprojection_enabled", true)
	_env("volumetric_fog_temporal_reprojection_amount", 0.90)
	# Keep inherited GI, but prevent the former sunset from being its sky source.
	_env("sdfgi_read_sky_light", true)
	_env("sdfgi_energy", 0.45)
	_env("sdfgi_bounce_feedback", 0.45)

func _configure_focus(camera: Camera3D) -> void:
	_camera = camera
	_saved_camera_attributes = camera.attributes
	var practical := camera.attributes as CameraAttributesPractical
	if practical != null:
		var copy := practical.duplicate() as CameraAttributesPractical
		copy.dof_blur_amount = minf(copy.dof_blur_amount, 0.012)
		camera.attributes = copy
		_camera_attributes_changed = true

func _configure_sun() -> void:
	_sun_value("light_color", Color(0.58, 0.68, 0.84))
	_sun_value("light_energy", 0.28)
	_sun_value("light_volumetric_fog_energy", 0.0)
	_sun_value("light_angular_distance", 3.0)
	_sun_value("shadow_enabled", true)
	_sun_value("shadow_blur", 1.3)
	_sun_value("rotation", Vector3(deg_to_rad(-36.0), deg_to_rad(155.0), 0.0))

func _configure_materials(tree: Node3D, camera: Camera3D) -> void:
	var world := viewer.get("world") as Node3D
	if world == null:
		return
	var old_style: Dictionary = world.get_meta("lowpoly_materials", {})
	var old_tree_boost := maxf(float(old_style.get("tree_albedo_boost", 1.0)), 1.0)
	var tree_distance := camera.global_position.distance_to(tree.global_position)
	for item in world.find_children("*", "MeshInstance3D", true, false):
		var mesh := item as MeshInstance3D
		if mesh.mesh == null or mesh.material_override is ShaderMaterial:
			continue
		var replacements: Array[Material] = []
		var originals: Array[Material] = []
		var changed := false
		var is_tree := tree == mesh or tree.is_ancestor_of(mesh)
		var is_ground: bool = viewer.get("ground") == mesh
		var bounds: AABB = mesh.global_transform * mesh.mesh.get_aabb()
		var is_distant := camera.global_position.distance_to(bounds.get_center()) > tree_distance * 1.8
		for index in mesh.mesh.get_surface_count():
			originals.append(mesh.get_surface_override_material(index))
			var active := mesh.get_active_material(index)
			var material := active as StandardMaterial3D
			# The traveler's outline and camp flame use unshaded materials.
			if material == null or material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
				replacements.append(active)
				continue
			var copy := material.duplicate() as StandardMaterial3D
			copy.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
			copy.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
			copy.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
			copy.metallic = 0.0
			copy.metallic_specular = 0.25
			copy.roughness = 0.86
			if is_tree:
				var albedo := copy.albedo_color
				copy.albedo_color = Color(albedo.r / old_tree_boost, albedo.g / old_tree_boost, albedo.b / old_tree_boost, albedo.a)
				copy.emission_enabled = false
				copy.emission_energy_multiplier = 0.0
				copy.roughness = 0.90
				copy.metallic_specular = 0.18
			elif is_ground or is_distant:
				copy.roughness = 0.98
				copy.metallic_specular = 0.035
				copy.emission_enabled = false
			elif str(mesh.name).begins_with("StonePaving") or str(mesh.name).begins_with("FineGravel"):
				copy.roughness = 0.90
			elif str(mesh.name).begins_with("DryGrass") or str(mesh.name).begins_with("StoneCracks"):
				copy.roughness = 0.94
				copy.metallic_specular = 0.10
			replacements.append(copy)
			changed = true
		if changed:
			_saved_materials.append({"mesh": mesh, "override": mesh.material_override, "surfaces": originals})
			mesh.material_override = null
			for index in replacements.size():
				mesh.set_surface_override_material(index, replacements[index])

func _build_fog(base: Vector3, height: float, toward_camera: Vector3,
		beam_origin: Vector3, beam_target: Vector3) -> void:
	# Match the supplied Blender tutorial: a bounded box of white, non-emissive
	# Volume Scatter at density 0.03. Only the light cone illuminates this medium.
	var ray := (beam_target - beam_origin).normalized()
	var end := beam_target + ray * height * 0.85
	var chamber := AABB(beam_origin, Vector3.ZERO).expand(end).merge(tree_bounds).grow(height * 0.15)
	_scatter_volume = FogVolume.new()
	_scatter_volume.name = "TreeTyndallScatterBox"
	_scatter_volume.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	_scatter_volume.size = chamber.size
	var medium := FogMaterial.new()
	medium.density = scatter_density
	medium.albedo = Color.WHITE
	medium.emission = Color.BLACK
	medium.height_falloff = 0.0
	medium.edge_fade = 0.12
	_scatter_volume.material = medium
	add_child(_scatter_volume)
	_scatter_volume.global_position = chamber.get_center()
	_owned_nodes.append(_scatter_volume)
	_fog("LowMistBeyondTree", base - toward_camera * height * 0.80 + Vector3.UP * height * 0.13,
		Vector3(height * 6.5, height * 0.40, height * 1.25), distant_mist_density, 0.80, 0.18, Color(0.09, 0.12, 0.17))
	_fog("FarDesertMist", base - toward_camera * height * 2.5 + Vector3.UP * height * 0.25,
		Vector3(height * 10.0, height * 0.80, height * 2.8), distant_mist_density * 0.80, 0.95, 0.12, Color(0.11, 0.14, 0.19))

func _fog(label: String, center: Vector3, dimensions: Vector3, density: float, fade: float, falloff: float, emission: Color) -> void:
	var fog := FogVolume.new()
	fog.name = label
	fog.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
	fog.size = dimensions
	var material := FogMaterial.new()
	material.density = density
	material.albedo = Color(0.68, 0.75, 0.83)
	material.emission = emission
	material.edge_fade = fade
	material.height_falloff = falloff
	fog.material = material
	add_child(fog)
	fog.global_position = center
	_owned_nodes.append(fog)

func _build_lights(base: Vector3, height: float, right: Vector3, toward_camera: Vector3,
		beam_origin: Vector3, beam_target: Vector3) -> void:
	tree_beam = SpotLight3D.new()
	tree_beam.name = "TreeOfLifeCloudbreakBeam"
	tree_beam.light_color = Color(1.0, 0.89, 0.70)
	tree_beam.light_energy = beam_energy
	tree_beam.light_volumetric_fog_energy = beam_volumetric_energy
	tree_beam.light_indirect_energy = 0.35
	tree_beam.light_specular = 0.75
	tree_beam.spot_range = beam_origin.distance_to(beam_target) + height * 0.35
	tree_beam.spot_angle = beam_angle_deg
	tree_beam.spot_angle_attenuation = 0.25
	tree_beam.spot_attenuation = 0.50
	tree_beam.shadow_enabled = true
	tree_beam.shadow_bias = 0.03
	tree_beam.shadow_normal_bias = 0.04
	tree_beam.shadow_blur = 0.6
	add_child(tree_beam)
	tree_beam.global_position = beam_origin
	tree_beam.look_at(beam_target, Vector3.UP)
	_owned_nodes.append(tree_beam)
	# A broad, non-volumetric bounce reveals bark and leaf facets beneath the shaft.
	var bounce := SpotLight3D.new()
	bounce.name = "TreeWarmCloudBounce"
	bounce.light_color = Color(1.0, 0.90, 0.76)
	bounce.light_energy = 1.4
	bounce.light_volumetric_fog_energy = 0.0
	bounce.light_indirect_energy = 0.25
	bounce.light_specular = 0.50
	bounce.spot_range = height * 2.5
	bounce.spot_angle = 27.0
	bounce.spot_angle_attenuation = 1.2
	bounce.spot_attenuation = 0.65
	bounce.shadow_enabled = false
	add_child(bounce)
	bounce.global_position = base - right * height * 0.45 + toward_camera * height * 0.90 + Vector3.UP * height * 0.85
	bounce.look_at(base + Vector3.UP * height * 0.46, Vector3.UP)
	_owned_nodes.append(bounce)
	var fill := DirectionalLight3D.new()
	fill.name = "StormForegroundSkyFill"
	fill.light_color = Color(0.55, 0.66, 0.82)
	fill.light_energy = 0.28
	fill.light_volumetric_fog_energy = 0.0
	fill.light_indirect_energy = 0.20
	fill.light_specular = 0.30
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-28.0, 175.0, 0.0)
	add_child(fill)
	_owned_nodes.append(fill)
	# Close-range, non-volumetric fill reveals paving and the traveler without
	# adding a second light shaft or lifting the whole distant landscape.
	var near_fill := SpotLight3D.new()
	near_fill.name = "StormNearPavingSoftFill"
	near_fill.light_color = Color(0.78, 0.84, 0.92)
	near_fill.light_energy = foreground_fill_energy
	near_fill.light_volumetric_fog_energy = 0.0
	near_fill.light_indirect_energy = 0.12
	near_fill.light_specular = 0.25
	near_fill.spot_range = 6.0
	near_fill.spot_angle = 52.0
	near_fill.spot_angle_attenuation = 1.0
	near_fill.spot_attenuation = 0.70
	near_fill.shadow_enabled = false
	add_child(near_fill)
	var camera := viewer.get("camera") as Camera3D
	var forward := -camera.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	near_fill.global_position = camera.global_position - right * 0.40 + Vector3.UP * 2.30 + forward * 0.55
	near_fill.look_at(camera.global_position + forward * 3.0 - Vector3.UP * 0.13, Vector3.UP)
	_owned_nodes.append(near_fill)

func _configure_tree_glow(tree: Node3D) -> void:
	for child in tree.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		for surface in mesh.mesh.get_surface_count():
			var original := mesh.get_active_material(surface) as StandardMaterial3D
			if original == null:
				continue
			var material := ShaderMaterial.new()
			material.shader = TREE_GLOW_SHADER
			if original.cull_mode != BaseMaterial3D.CULL_BACK:
				var shader := Shader.new()
				shader.code = TREE_GLOW_SHADER.code.replace("cull_back", "cull_disabled" if original.cull_mode == BaseMaterial3D.CULL_DISABLED else "cull_front")
				material.shader = shader
			material.set_shader_parameter("base_texture", original.albedo_texture)
			material.set_shader_parameter("use_texture", original.albedo_texture != null)
			material.set_shader_parameter("base_tint", original.albedo_color)
			material.set_shader_parameter("use_vertex_color", original.vertex_color_use_as_albedo)
			material.set_shader_parameter("vertex_color_srgb", original.vertex_color_is_srgb)
			material.set_shader_parameter("uv_scale", original.uv1_scale)
			material.set_shader_parameter("uv_offset", original.uv1_offset)
			material.set_shader_parameter("surface_roughness", original.roughness)
			material.set_shader_parameter("surface_specular", original.metallic_specular)
			material.set_shader_parameter("beam_position", tree_beam.global_position)
			material.set_shader_parameter("beam_direction", -tree_beam.global_basis.z.normalized())
			material.set_shader_parameter("beam_cos_outer", cos(deg_to_rad(beam_angle_deg)))
			material.set_shader_parameter("beam_cos_inner", cos(deg_to_rad(beam_angle_deg * 0.74)))
			material.set_shader_parameter("beam_range", tree_beam.spot_range)
			material.set_shader_parameter("canopy_bottom", tree_bounds.position.y + tree_bounds.size.y * 0.30)
			material.set_shader_parameter("canopy_full", tree_bounds.position.y + tree_bounds.size.y * 0.48)
			material.set_shader_parameter("glow_strength", tree_glow_strength)
			mesh.set_surface_override_material(surface, material)
			_tree_glow_materials.append(material)

func set_tree_glow_strength(value: float) -> void:
	tree_glow_strength = maxf(value, 0.0)
	for material in _tree_glow_materials:
		material.set_shader_parameter("glow_strength", tree_glow_strength)

func _world_bounds(node: Node3D) -> AABB:
	var bounds := AABB()
	var measured := false
	var meshes: Array[Node] = node.find_children("*", "MeshInstance3D", true, false)
	if node is MeshInstance3D:
		meshes.append(node)
	for child in meshes:
		var mesh := child as MeshInstance3D
		if mesh.mesh == null:
			continue
		var current: AABB = mesh.global_transform * mesh.mesh.get_aabb()
		bounds = bounds.merge(current) if measured else current
		measured = true
	return bounds

func _env(property: StringName, value: Variant) -> void:
	if value is bool and bool(value) and _renderer_lacks(property):
		return          # Mobile 渲染器（安卓）没有这项：开了画面一样，只会打引擎警告（安卓压力测试 TS-9）
	if not _saved_environment.has(property):
		_saved_environment[property] = _environment.get(property)
	_environment.set(property, value)

## 当前渲染器没有的环境效果（Forward+ 独有：体积雾、SDFGI、SSIL；Mobile 也没有 SSAO）
static func _renderer_lacks(property: StringName) -> bool:
	var method := RenderingServer.get_current_rendering_method()
	if property in [&"volumetric_fog_enabled", &"sdfgi_enabled", &"ssil_enabled"]:
		return method != "forward_plus"
	if property == &"ssao_enabled":
		return method == "mobile"
	return false

func _sun_value(property: StringName, value: Variant) -> void:
	if not _saved_sun.has(property):
		_saved_sun[property] = _sun.get(property)
	_sun.set(property, value)

func restore() -> void:
	if _saved_fog_grid.x > 0:
		RenderGlobals.volumetric_fog_volume(_saved_fog_grid.x, _saved_fog_grid.y)
		RenderGlobals.volumetric_fog_filter(_saved_fog_filter)
		_saved_fog_grid = Vector2i.ZERO
	# Surface pass captures the copied storm material, so restore it before
	# restoring the original materials from the viewer.
	if _surface_pass != null:
		_surface_pass.restore()
		_surface_pass = null
	_surface_evidence.clear()
	if is_instance_valid(_environment):
		for property in _saved_environment:
			_environment.set(property, _saved_environment[property])
	if is_instance_valid(_sun):
		for property in _saved_sun:
			_sun.set(property, _saved_sun[property])
	for saved in _saved_materials:
		var mesh := saved.mesh as MeshInstance3D
		if is_instance_valid(mesh):
			mesh.material_override = saved.override
			for index in saved.surfaces.size():
				mesh.set_surface_override_material(index, saved.surfaces[index])
	_saved_materials.clear()
	_tree_glow_materials.clear()
	if _camera_attributes_changed and is_instance_valid(_camera):
		_camera.attributes = _saved_camera_attributes
	_camera_attributes_changed = false
	_saved_camera_attributes = null
	for node in _owned_nodes:
		if is_instance_valid(node):
			node.free()
	_owned_nodes.clear()
	_saved_environment.clear()
	_saved_sun.clear()
	_configured = false

func _exit_tree() -> void:
	if _configured:
		restore()

func evidence() -> Dictionary:
	return {"preset": "baghdad/storm-cloudbreak", "configured": _configured,
		"real_volumetric_light": true, "screen_overlay": false,
		"tree_world_base": [tree_bounds.get_center().x, tree_bounds.position.y, tree_bounds.get_center().z],
		"tree_height_u": tree_bounds.size.y, "sky_energy": sky_energy,
		"ambient_energy": ambient_energy, "exposure": exposure,
		"beam_energy": beam_energy, "beam_volumetric_energy": beam_volumetric_energy,
		"beam_angle_deg": beam_angle_deg, "global_fog_density": global_fog_density,
		"beam_shadows": tree_beam.shadow_enabled if is_instance_valid(tree_beam) else false,
		"scatter_density": scatter_density, "scatter_shape": "box", "scatter_emission": "black",
		"scatter_anisotropy": 0.0, "scatter_grid": [192,128], "scatter_filter": false,
		"reference_method": "bounded Volume Scatter, no Surface, density 0.03",
		"distant_mist_density": distant_mist_density,
		"foreground_fill_energy": foreground_fill_energy, "surface": _surface_evidence,
		"tree_glow_strength": tree_glow_strength, "tree_glow_surfaces": _tree_glow_materials.size(),
		"glow_intensity": _environment.glow_intensity, "glow_blend_mode": "additive",
		"glow_hdr_threshold": _environment.glow_hdr_threshold, "glow_hdr_scale": _environment.glow_hdr_scale,
		"tree_glow_mask": "spot cone x light-facing normal x canopy height x source atlas luminance",
		"volumetric_sky_affect": 1.0, "far_dof_blur_cap": 0.012,
		"material_meshes": _saved_materials.size(), "material_diffuse": "BURLEY", "material_specular": "SCHLICK_GGX",
		"clouds": "static layered overcast with a localized high cloudbreak",
		"existing_period_and_weather_controls_changed": false}
