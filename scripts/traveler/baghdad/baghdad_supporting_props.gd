extends RefCounted
## Static supporting silhouettes for the Baghdad composition checkpoint.
## All layout coordinates are stage coordinates: X screen-right, +Z away.

const FIREPIT_SOURCE := "res://assets/traveler/panti/camp/processed/firepit.glb"
const DEFAULTS := {
	"rocks": [
		{"position": [-1.48, 0.0, 2.75], "size": [0.72, 0.29, 0.50], "yaw_deg": 14.0},
		{"position": [-1.07, 0.0, 3.17], "size": [0.28, 0.15, 0.23], "yaw_deg": 59.0},
		{"position": [1.72, 0.0, 3.42], "size": [0.82, 0.38, 0.61], "yaw_deg": -19.0},
		{"position": [1.26, 0.0, 3.79], "size": [0.38, 0.21, 0.33], "yaw_deg": 32.0},
		{"position": [1.99, 0.0, 4.47], "size": [0.32, 0.15, 0.28], "yaw_deg": 71.0}
	],
	"palms": [
		{"position": [-3.35, 0.0, 15.4], "height_u": 1.44, "yaw_deg": 17.0},
		{"position": [-4.15, 0.0, 17.2], "height_u": 1.70, "yaw_deg": 78.0},
		{"position": [4.70, 0.0, 21.0], "height_u": 1.58, "yaw_deg": 24.0},
		{"position": [5.60, 0.0, 24.0], "height_u": 1.15, "yaw_deg": 56.0},
		{"position": [-5.10, 0.0, 28.0], "height_u": 0.92, "yaw_deg": 91.0}
	],
	"rock_color": "#967052",
	"palm_trunk_color": "#64482D",
	"palm_leaf_color": "#30452B",
	"tufts": [
		{"position": [-3.15, 0.0, 2.35], "height_u": 0.16, "yaw_deg": 22.0},
		{"position": [-2.55, 0.0, 2.12], "height_u": 0.11, "yaw_deg": -15.0},
		{"position": [2.92, 0.0, 2.38], "height_u": 0.14, "yaw_deg": 40.0},
		{"position": [3.42, 0.0, 2.08], "height_u": 0.10, "yaw_deg": -28.0},
		{"position": [-1.92, 0.0, 4.92], "height_u": 0.13, "yaw_deg": 63.0}
	],
	"tuft_color": "#646039",
	"hand_prop": {
		"enabled": true,
		"bone": "mixamorig_RightHand",
		"offset_stage": [0.0, 0.0, 0.0],
		"flower_height_u": 0.11,
		"potato_radius_u": 0.018
	},
	"fire": {
		"enabled": true,
		"position": [0.40, 0.0, 3.80],
		"height_u": 0.3825,
		"width_u": 0.46,
		"yaw_deg": -12.0,
		"light_energy": 0.22,
		"light_range_u": 0.72
	}
}

var _viewer: Node3D
var _settings: Dictionary = {}
var _asset_placer:RefCounted
var _assets_enabled:=false
var _root: Node3D
var _records: Array[Dictionary] = []
var _triangles: Dictionary = {}

func build(viewer: Node3D) -> Node3D:
	_viewer = viewer
	_settings = DEFAULTS.duplicate(true)
	var overrides: Dictionary = viewer.settings.get("supporting_props", {})
	for key in overrides:
		if key in ["fire", "hand_prop"]:
			for nested_key in overrides[key]:
				_settings[key][nested_key] = overrides[key][nested_key]
		else:
			_settings[key] = overrides[key]
	_root = Node3D.new()
	_root.name = "BaghdadSupportingProps"
	_assets_enabled=bool(_settings.get("use_supplied_assets",false))
	if _assets_enabled:
		_asset_placer=load("res://scripts/traveler/baghdad/baghdad_prop_assets.gd").new()
		_asset_placer.configure(viewer)
	_build_rocks()
	_build_surface_details()
	_build_tufts()
	_build_palms()
	if _assets_enabled and _settings.has("plants"):_build_imported_entries("plant",_settings.plants)
	if bool(_settings.fire.get("enabled", true)):
		_build_fire()
	if bool(_settings.hand_prop.get("enabled", true)):
		_build_hand_prop()
	return _root

func evidence() -> Dictionary:
	return {"static": true, "settings": _settings, "props": _records,
		"triangles": _triangles, "firepit_source":str(_settings.fire.get("asset",FIREPIT_SOURCE)) if _assets_enabled else FIREPIT_SOURCE,
		"supplied_assets_enabled":_assets_enabled,"imported_assets":_asset_placer.evidence() if _asset_placer!=null else {},
		"note": "Composition only: no particle emitter, animation, TIME shader or interaction."}

func _vec(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func _stage_position(value: Array, bury: float = 0.0) -> Vector3:
	var stage := _vec(value)
	var surface: Object = _viewer.get("ground_surface")
	if surface != null and surface.has_method("height_at"):
		stage.y += float(surface.height_at(Vector2(stage.x, stage.z)))
	stage.y -= bury
	return _viewer.stage_point(stage)

func _material(unshaded: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 0.92
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material

func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var normal := (b - a).cross(c - a).normalized()
	for vertex in [a, b, c]:
		surface.set_normal(normal)
		surface.set_color(color)
		surface.add_vertex(vertex)

func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color) -> void:
	_triangle(surface, a, b, c, color)
	_triangle(surface, a, c, d, color)

func _batch(name_value: String, surface: SurfaceTool, unshaded: bool = false) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name_value
	node.mesh = surface.commit()
	node.material_override = _material(unshaded)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(node)
	_triangles[name_value] = node.mesh.surface_get_array_len(0) / 3
	return node

func _build_imported_entries(kind:String,entries:Array) -> void:
	for index in entries.size():
		var entry:Dictionary=entries[index].duplicate(true)
		entry["id"]=str(entry.get("id",kind+"_%02d"%index))
		entry["kind"]=kind
		_asset_placer.place(entry,_root)

func _build_rocks() -> void:
	if _assets_enabled:
		_build_imported_entries("rock",_settings.rocks)
		return
	if _settings.rocks.is_empty():
		return
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var color := Color(str(_settings.rock_color))
	var index := 0
	for entry in _settings.rocks:
		var size := _vec(entry.size)
		var origin := _stage_position(entry.position, size.y * 0.16)
		var basis := Basis(Vector3.UP, deg_to_rad(float(entry.get("yaw_deg", 0.0))))
		var lower: Array[Vector3] = []
		var upper: Array[Vector3] = []
		for side in 6:
			var angle := TAU * float(side) / 6.0
			var variation := 0.91 + 0.10 * sin(float(side * 3 + index * 7))
			lower.append(origin + basis * Vector3(cos(angle) * size.x * 0.5, 0.0, sin(angle) * size.z * 0.5) * variation)
			upper.append(origin + basis * Vector3(cos(angle + 0.19) * size.x * 0.37, size.y * (0.67 + 0.12 * sin(float(side + index))), sin(angle + 0.19) * size.z * 0.35))
		var top := origin + basis * Vector3(-size.x * 0.08, size.y, size.z * 0.05)
		for side in 6:
			var next := (side + 1) % 6
			var facet := color.darkened(0.025 * float((side + index) % 4))
			_quad(surface, lower[side], lower[next], upper[next], upper[side], facet)
			_triangle(surface, upper[side], upper[next], top, color.lightened(0.015 * float(side % 3)))
		_records.append({"kind": "rock", "stage_position": entry.position, "size_u": entry.size, "triangles": 18})
		index += 1
	_batch("SandstoneForegroundRocks", surface)

func _build_surface_details() -> void:
	var config: Dictionary = _settings.get("surface_details", {})
	if not bool(config.get("enabled", false)):
		return
	_build_pebble_clusters(config)
	if bool(config.get("ripple_enabled", true)):
		_build_sand_ripples(config)

func _detail_allowed(point: Vector2, config: Dictionary) -> bool:
	for exclusion in config.get("exclusions", []):
		var center := Vector2(float(exclusion.center[0]), float(exclusion.center[1]))
		if point.distance_to(center) < float(exclusion.radius_u):
			return false
	return true

func _build_pebble_clusters(config: Dictionary) -> void:
	var clusters: Array = config.get("pebble_clusters", [])
	if clusters.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = int(config.get("seed", 20260922))
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var color := Color(str(config.get("pebble_color", "#9B7850")))
	var total := 0
	for cluster in clusters:
		var count := 0
		var center := Vector2(float(cluster.center[0]), float(cluster.center[1]))
		var radius := Vector2(float(cluster.radius[0]), float(cluster.radius[1]))
		for index in int(cluster.count):
			var angle := rng.randf_range(0.0, TAU)
			var distance := sqrt(rng.randf_range(0.12, 1.0))
			var point := center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y) * distance
			if not _detail_allowed(point, config):
				continue
			var width := rng.randf_range(float(cluster.width_u[0]), float(cluster.width_u[1]))
			var half_height := width * rng.randf_range(0.14, 0.23)
			var bury := width * float(config.get("pebble_bury_ratio", 0.07))
			var origin := _stage_position([point.x, half_height, point.y], bury)
			var shade := color.lightened(rng.randf_range(0.0, 0.14))
			_small_faceted_blob(surface, origin, Vector3(width * 0.5, half_height, width * rng.randf_range(0.29, 0.46)), shade)
			count += 1
		_records.append({"kind": "pebble_cluster", "id": cluster.id, "center_stage_xz": cluster.center,
			"radius_u": cluster.radius, "count": count, "width_range_u": cluster.width_u,
			"ground_snap": true, "bury_ratio": config.get("pebble_bury_ratio", 0.07), "triangles": count * 12})
		total += count
	if total > 0:
		_batch("ScatteredSandstoneChips", surface)

func _sand_point(point: Vector2, height: float) -> Vector3:
	# Sample each edge and crest independently. height_at is the rendered ground
	# surface, so these shallow ridges follow slopes instead of floating above them.
	return _stage_position([point.x, height, point.y])

func _sand_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	if (b - a).cross(c - a).y < 0.0:
		_triangle(surface, a, c, b, color)
	else:
		_triangle(surface, a, b, c, color)

func _build_sand_ripples(config: Dictionary) -> void:
	var patches: Array = config.get("sand_ripple_patches", [])
	if patches.is_empty():
		return
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var albedo: Array = _viewer.settings.ground.albedo
	var sand := Color(float(albedo[0]), float(albedo[1]), float(albedo[2]))
	# These raised facets face the low sunset key almost directly. Keep their
	# sand color in the same family as the ground while avoiding a clipped white
	# strip when the cinematic key and GI are both active.
	sand *= clampf(float(config.get("ripple_albedo_scale", 0.58)), 0.1, 1.0)
	var total := 0
	var segments := maxi(int(config.get("ripple_segments", 8)), 4)
	var lift := float(config.get("ripple_ground_lift_u", 0.0015))
	for patch in patches:
		var center := Vector2(float(patch.center[0]), float(patch.center[1]))
		var angle := deg_to_rad(float(patch.yaw_deg))
		var along := Vector2(cos(angle), sin(angle))
		var across := Vector2(-along.y, along.x)
		var count := int(patch.count)
		var built := 0
		for ridge in count:
			var offset := (float(ridge) - float(count - 1) * 0.5) * float(patch.spacing_u)
			var midpoint := center + across * offset
			if not _detail_allowed(midpoint, config):
				continue
			var length := float(patch.length_u) * (0.83 + 0.17 * cos(float(ridge) * 1.71))
			var half_width := float(patch.width_u) * 0.5
			for segment in segments:
				var t0 := float(segment) / float(segments)
				var t1 := float(segment + 1) / float(segments)
				var fade0 := sin(PI * t0)
				var fade1 := sin(PI * t1)
				var curve0 := sin(PI * t0) * float(patch.get("curve_u", 0.045))
				var curve1 := sin(PI * t1) * float(patch.get("curve_u", 0.045))
				var p0 := midpoint + along * ((t0 - 0.5) * length) + across * curve0
				var p1 := midpoint + along * ((t1 - 0.5) * length) + across * curve1
				var a := _sand_point(p0 - across * half_width * fade0, lift)
				var b := _sand_point(p1 - across * half_width * fade1, lift)
				var c := _sand_point(p0, lift + float(patch.height_u) * fade0)
				var d := _sand_point(p1, lift + float(patch.height_u) * fade1)
				var e := _sand_point(p0 + across * half_width * fade0, lift)
				var f := _sand_point(p1 + across * half_width * fade1, lift)
				_sand_triangle(surface, a, b, d, sand.lightened(0.012))
				_sand_triangle(surface, a, d, c, sand.lightened(0.012))
				_sand_triangle(surface, c, d, f, sand.darkened(0.014))
				_sand_triangle(surface, c, f, e, sand.darkened(0.014))
			built += 1
		_records.append({"kind": "sand_ripple_patch", "id": patch.id, "center_stage_xz": patch.center,
			"ridges": built, "height_u": patch.height_u, "ground_snap": "each vertex",
			"ground_lift_u": lift, "triangles": built * segments * 4})
		total += built
	if total > 0:
		_batch("WindCarvedSandRidges", surface)

func _build_palms() -> void:
	if _assets_enabled:
		_build_imported_entries("palm",_settings.palms)
		return
	if _settings.palms.is_empty():
		return
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk_color := Color(str(_settings.palm_trunk_color))
	var leaf_color := Color(str(_settings.palm_leaf_color))
	var palm_index := 0
	for entry in _settings.palms:
		var origin := _stage_position(entry.position)
		var height := float(entry.height_u)
		var yaw := deg_to_rad(float(entry.get("yaw_deg", 0.0)))
		var lean := Vector3(cos(yaw) * height * 0.09, 0.0, sin(yaw) * height * 0.09)
		var top := origin + Vector3.UP * height * 0.86 + lean
		for segment in 4:
			var t0 := float(segment) / 4.0
			var t1 := float(segment + 1) / 4.0
			var p0 := origin + Vector3.UP * height * 0.86 * t0 + lean * t0 * t0
			var p1 := origin + Vector3.UP * height * 0.86 * t1 + lean * t1 * t1
			var r0 := height * lerpf(0.023, 0.012, t0)
			var r1 := height * lerpf(0.023, 0.012, t1)
			for side in 5:
				var angle0 := TAU * float(side) / 5.0
				var angle1 := TAU * float(side + 1) / 5.0
				var axis0 := Vector3(cos(angle0), 0.0, sin(angle0))
				var axis1 := Vector3(cos(angle1), 0.0, sin(angle1))
				_quad(surface, p0 + axis0 * r0, p0 + axis1 * r0, p1 + axis1 * r1, p1 + axis0 * r1, trunk_color.lightened(0.022 * float(segment % 2)))
		for frond in 8:
			var angle := yaw + TAU * float(frond) / 8.0
			var direction := Vector3(cos(angle), 0.0, sin(angle))
			var sideways := Vector3(-sin(angle), 0.0, cos(angle))
			var length := height * (0.33 + 0.025 * sin(float(frond + palm_index * 3)))
			var points: Array[Vector3] = [top, top + direction * length * 0.30 + Vector3.UP * height * 0.12, top + direction * length * 0.72 + Vector3.UP * height * 0.09, top + direction * length + Vector3.DOWN * height * 0.095]
			var widths := [0.014, 0.060, 0.050, 0.0]
			for segment in 3:
				var a: Vector3 = points[segment]
				var b: Vector3 = points[segment + 1]
				var wa := height * float(widths[segment])
				var wb := height * float(widths[segment + 1])
				var color := leaf_color.lightened(0.020 * float((frond + segment) % 3))
				# A central ridge gives the broad palm silhouette two lit facets.
				_quad(surface, a, b, b + sideways * wb - Vector3.UP * height * 0.012, a + sideways * wa - Vector3.UP * height * 0.012, color)
				_quad(surface, a - sideways * wa - Vector3.UP * height * 0.012, b - sideways * wb - Vector3.UP * height * 0.012, b, a, color.darkened(0.045))
		_records.append({"kind": "palm", "stage_position": entry.position, "height_u": height, "fronds": 8, "triangles": 136})
		palm_index += 1
	_batch("MiddleDistancePalms", surface, true)

func _build_tufts() -> void:
	if _settings.tufts.is_empty():
		return
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var color := Color(str(_settings.tuft_color))
	for entry in _settings.tufts:
		var height := maxf(float(entry.get("height_u", 0.12)), 0.04)
		var base := _stage_position(entry.position, 0.002)
		var yaw := deg_to_rad(float(entry.get("yaw_deg", 0.0)))
		var width := height * 0.27
		# Three broad, static blades give a readable foreground silhouette at 1080p.
		for blade in 3:
			var angle := yaw + TAU * float(blade) / 3.0
			var direction := Vector3(cos(angle), 0.0, sin(angle))
			var side := Vector3(-direction.z, 0.0, direction.x)
			var root := base + direction * (width * 0.08)
			var tip := base + Vector3.UP * height + direction * (width * 0.48)
			var a := root - side * width * 0.5
			var b := root + side * width * 0.5
			_triangle(surface, a, b, tip, color.lightened(0.025 * float(blade)))
		_records.append({"kind": "desert_tuft", "stage_position": entry.position, "height_u": height, "triangles": 3})
	_batch("SparseForegroundTufts", surface, true)

func _small_faceted_blob(surface: SurfaceTool, center: Vector3, size: Vector3, color: Color) -> void:
	var upper := center + Vector3.UP * size.y
	var lower := center - Vector3.UP * size.y
	for side in 6:
		var a := TAU * float(side) / 6.0
		var b := TAU * float(side + 1) / 6.0
		var va := center + Vector3(cos(a) * size.x, 0.0, sin(a) * size.z)
		var vb := center + Vector3(cos(b) * size.x, 0.0, sin(b) * size.z)
		_triangle(surface, upper, vb, va, color.lightened(0.018 * float(side % 3)))
		_triangle(surface, lower, va, vb, color.darkened(0.05))

func _build_hand_prop() -> void:
	var model: Node3D = _viewer.get("character_model")
	if model == null:
		return
	var skeletons := model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		push_warning("Baghdad hand prop: character has no Skeleton3D")
		return
	var skeleton := skeletons[0] as Skeleton3D
	var config: Dictionary = _settings.hand_prop
	var bone := skeleton.find_bone(str(config.bone))
	if bone < 0:
		push_warning("Baghdad hand prop: missing bone " + str(config.bone))
		return
	# Snapshot the already posed hand. This checkpoint has no animation and does
	# not add a BoneAttachment or change the source scene's skeleton or skin.
	var contact: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
	contact += _viewer.stage_point(_vec(config.offset_stage))
	if _assets_enabled:
		for entry in config.parts:
			var part:Dictionary=entry.duplicate(true)
			part["anchor_world"]=contact
			part["ground_snap"]=false
			part["kind"]="hand_prop"
			_asset_placer.place(part,_root)
		_records.append({"kind":"supplied_hand_props","bone":config.bone,"contact_world_u":[contact.x,contact.y,contact.z],"static":true})
		return
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var radius := float(config.potato_radius_u)
	for potato in 3:
		var center := contact + Vector3((float(potato) - 1.0) * radius * 1.15, -radius * 1.15, 0.0)
		_small_faceted_blob(surface, center, Vector3(radius * 0.8, radius, radius * 0.72), Color("#9F754D"))
	var flower_height := float(config.flower_height_u)
	for flower in 3:
		var bloom := contact + Vector3((float(flower) - 1.0) * 0.025, flower_height * (0.82 + float(flower % 2) * 0.18), -0.016)
		var stem_half := Vector3(0.0015, 0.0, 0.0)
		_quad(surface, contact - stem_half, contact + stem_half, bloom + stem_half, bloom - stem_half, Color("#4E6130"))
		for petal in 5:
			var angle := TAU * float(petal) / 5.0
			var petal_center := bloom + Vector3(cos(angle) * 0.010, sin(angle) * 0.010, 0.0)
			_small_faceted_blob(surface, petal_center, Vector3(0.007, 0.007, 0.003), Color("#C4935A"))
		_small_faceted_blob(surface, bloom + Vector3(0.0, 0.0, -0.003), Vector3(0.006, 0.006, 0.004), Color("#B66E32"))
	_batch("RightHandPotatoesAndFlowersPlaceholder", surface)
	_records.append({"kind": "potatoes_and_flowers", "purpose": "Point 5 static composition placeholder", "bone": config.bone, "contact_world_u": [contact.x, contact.y, contact.z], "offset_stage": config.offset_stage, "static": true})

func _mesh_nodes(node: Node, parent_transform: Transform3D, meshes: Array[Dictionary]) -> void:
	var transform := parent_transform
	if node is Node3D:
		transform = parent_transform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		meshes.append({"mesh": node.mesh, "transform": transform, "material": node.material_override})
	for child in node.get_children():
		_mesh_nodes(child, transform, meshes)

func _build_fire() -> void:
	var config: Dictionary = _settings.fire
	var fire_root := Node3D.new()
	fire_root.name = "StaticCampFire"
	fire_root.position = _stage_position(config.position, float(config.get("bury_u",0.005)))
	fire_root.rotation.y = deg_to_rad(float(config.get("yaw_deg", 0.0)))
	_root.add_child(fire_root)
	var meshes: Array[Dictionary] = []
	var source_path:String=str(config.get("asset",FIREPIT_SOURCE)) if _assets_enabled else FIREPIT_SOURCE
	var packed := load(source_path) as PackedScene
	if packed == null:
		push_error("Baghdad firepit source failed to load: " + source_path)
		return
	var source := packed.instantiate()
	_mesh_nodes(source, Transform3D.IDENTITY, meshes)
	var bounds := AABB()
	var first := true
	for entry in meshes:
		var box: AABB = entry.transform * entry.mesh.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	var width := float(config.width_u)
	var scale_value := width / maxf(bounds.size.x, bounds.size.z)
	var model := Node3D.new()
	model.name = "SuppliedCampfireLogs" if _assets_enabled else "ApprovedFirepitBase"
	model.scale = Vector3.ONE * scale_value
	model.position = -Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z) * scale_value
	fire_root.add_child(model)
	var pit_triangles := 0
	for entry in meshes:
		var instance := MeshInstance3D.new()
		instance.mesh = entry.mesh
		instance.transform = entry.transform
		instance.material_override = entry.material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		model.add_child(instance)
		for surface_index in instance.mesh.get_surface_count():
			var index_count: int = instance.mesh.surface_get_array_index_len(surface_index)
			pit_triangles += (index_count if index_count > 0 else instance.mesh.surface_get_array_len(surface_index)) / 3
	source.free()
	_triangles[str(model.name)] = pit_triangles
	var pit_height := bounds.size.y * scale_value
	var total_height := float(config.height_u)
	var flame_base := minf(pit_height * 0.69, total_height * 0.40)
	var flame_height := maxf(total_height - flame_base, 0.02)
	var flames := SurfaceTool.new()
	flames.begin(Mesh.PRIMITIVE_TRIANGLES)
	for flame_index in 6:
		var angle := TAU * float(flame_index) / 5.0
		var offset := Vector3(cos(angle) * width * 0.105, flame_base, sin(angle) * width * 0.105)
		var h := flame_height * (1.0 if flame_index == 0 else 0.60 + 0.07 * float(flame_index))
		var radius := width * 0.066
		var is_core := flame_index == 5
		if is_core:
			offset = Vector3(0.0, flame_base, -width * 0.14)
			h = flame_height * 0.55
			radius = width * 0.066
		var lean := Vector3(width * 0.053 * sin(angle + 0.4), 0.0, width * 0.032 * cos(angle))
		var tip := offset + Vector3(0.0, h, 0.0) + lean
		var lower_color := Color("#FFC64C") if is_core else Color("#FA7B17")
		var upper_color := Color("#FFDA72") if is_core else Color("#DF4D0D")
		for side in 5:
			var a := TAU * float(side) / 5.0
			var b := TAU * float(side + 1) / 5.0
			var bottom_a := offset + Vector3(cos(a) * radius * 0.40, 0.0, sin(a) * radius * 0.40)
			var bottom_b := offset + Vector3(cos(b) * radius * 0.40, 0.0, sin(b) * radius * 0.40)
			var middle_a := offset + Vector3(cos(a) * radius, h * 0.28, sin(a) * radius)
			var middle_b := offset + Vector3(cos(b) * radius, h * 0.28, sin(b) * radius)
			var upper_a := offset + Vector3(cos(a) * radius * 0.48, h * 0.66, sin(a) * radius * 0.48) + lean * 0.30
			var upper_b := offset + Vector3(cos(b) * radius * 0.48, h * 0.66, sin(b) * radius * 0.48) + lean * 0.30
			_quad(flames, bottom_a, bottom_b, middle_b, middle_a, lower_color)
			_quad(flames, middle_a, middle_b, upper_b, upper_a, lower_color.lerp(upper_color, 0.45))
			_triangle(flames, upper_a, upper_b, tip, upper_color)
	var flame_mesh := _batch("StaticFlameSilhouette", flames, true)
	_root.remove_child(flame_mesh)
	fire_root.add_child(flame_mesh)
	var material := flame_mesh.material_override as StandardMaterial3D
	# Keep the flame readable as orange/yellow low-poly tongues under the sunset
	# exposure. The previous HDR emission pushed the unshaded cards to white.
	material.albedo_color = Color.WHITE
	material.vertex_color_use_as_albedo = true
	material.emission_enabled = true
	material.emission = Color("#F07829")
	material.emission_energy_multiplier = 0.025
	var warmth := OmniLight3D.new()
	warmth.name = "StaticFireWarmth"
	warmth.position.y = total_height * 0.40
	warmth.light_color = Color("#FFA24D")
	warmth.light_energy = float(config.light_energy)
	warmth.omni_range = float(config.light_range_u)
	warmth.light_specular = 0.0
	warmth.shadow_enabled = false
	fire_root.add_child(warmth)
	_records.append({"kind": "fire", "stage_position": config.position, "height_u": total_height, "firepit_height_u": pit_height, "width_u": width, "source": source_path, "static": true})
