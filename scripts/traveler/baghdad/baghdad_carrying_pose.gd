extends Node3D
## Isolated Carrying animation, with a bundle following the actual two hand bones.
## The runtime GLB reader does not require a shared editor import or scene rewrite.
const POSE_ASSET := "res://assets/traveler/baghdad/character/carrying_animated.glb"
const LANDMARK_ASSET := "res://assets/traveler/baghdad/character/carrying_landmarks.json"
const POTATO_ASSET := "res://assets/traveler/baghdad/props/potato 3d model/potato+3d+model.fbx"
const BUNDLE_OFFSET_NORMALIZED := Vector3(0.0, 0.012, 0.008)
const BUNDLE_SCALE := 1.0
const POTATO_WORLD_WIDTHS := Vector3(0.064, 0.061, 0.069)
const OUTLINE_WIDTH_NORMALIZED := 0.0025
const TURN_RIGHT_DEGREES := 20.0

@export var bundle_offset_normalized := BUNDLE_OFFSET_NORMALIZED
@export var bundle_scale := BUNDLE_SCALE
@export var outline_width_normalized := OUTLINE_WIDTH_NORMALIZED
@export var turn_right_degrees := TURN_RIGHT_DEGREES

var potato_bundle: Node3D
var pose_model: Node3D
var shells: Array[MeshInstance3D] = []
var _viewer: Node3D
var _actor: Node3D
var _old_model: Node3D
var _old_body: MeshInstance3D
var _old_geometry: Mesh
var _old_model_visible := true
var _old_hand_props: Array[Dictionary] = []
var _prop_placer: RefCounted
var _potatoes: Array[Node3D] = []
var _landmarks: Dictionary = {}
var _palms_local: Array[Vector3] = []
var _material_records: Array[Dictionary] = []
var _configured := false
var _old_actor_transform := Transform3D.IDENTITY
var _old_local_height := 0.0
var _source_bounds := AABB()
var _player: AnimationPlayer
var _skeleton: Skeleton3D
var _animation_name: StringName
var _animation_length := 0.0
var _animation_time := 0.0
var _hand_bones: Dictionary = {}
var _initial_palm_basis := Basis.IDENTITY
var _previous_palm_basis := Basis.IDENTITY
var _bundle_reference_ready := false
var _initial_pose_geometry: Mesh
var _metadata_palm_error := 0.0

func configure(viewer: Node3D) -> bool:
	restore()
	name = "BaghdadCarryingPose"
	_viewer = viewer
	_actor = viewer.get("character") as Node3D
	_old_model = viewer.get("character_model") as Node3D
	_old_body = viewer.get("character_body") as MeshInstance3D
	_old_geometry = viewer.get("character_geometry") as Mesh
	if is_instance_valid(_old_model):
		_old_model_visible = _old_model.visible
	if _actor == null or _old_model == null or _old_body == null or _old_geometry == null:
		push_error("Carrying pose requires the ready Baghdad traveler")
		return false
	if not FileAccess.file_exists(POSE_ASSET) or not FileAccess.file_exists(LANDMARK_ASSET):
		push_error("Carrying pose or normalized palm landmarks are missing")
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LANDMARK_ASSET))
	if not parsed is Dictionary or not parsed.get("bones", {}) is Dictionary:
		push_error("Carrying landmarks must contain a bones dictionary")
		return false
	_landmarks = parsed
	var bones: Dictionary = _landmarks.bones
	if not _is_point(bones.get("LeftPalm")) or not _is_point(bones.get("RightPalm")):
		push_error("Carrying landmarks require normalized LeftPalm and RightPalm points")
		return false
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var load_error := document.append_from_file(POSE_ASSET, state)
	if load_error != OK:
		push_error("Unable to read Carrying GLB: %s" % load_error)
		return false
	var imported := document.generate_scene(state) as Node3D
	if imported == null:
		push_error("Unable to instantiate Carrying GLB")
		return false
	var meshes := imported.find_children("*", "MeshInstance3D", true, false)
	if imported is MeshInstance3D:
		meshes.push_front(imported)
	if meshes.is_empty():
		imported.free()
		push_error("Carrying GLB contains no body mesh")
		return false
	_old_actor_transform = _actor.transform
	# height_u in the existing viewer is a scale, not an AABB-normalized height.
	# Match its actual posed body height in actor space before keeping that scale.
	var old_relative := _actor.global_transform.affine_inverse() * _old_body.global_transform
	_old_local_height = (old_relative * _old_geometry.get_aabb()).size.y
	if _old_local_height <= 0.000001:
		imported.free()
		push_error("Original traveler has no usable posed height")
		return false
	pose_model = Node3D.new()
	pose_model.name = "CarryingTravelerModel"
	_actor.add_child(pose_model)
	imported.name = "CarryingSourceAnimation"
	pose_model.add_child(imported)
	if not _configure_animation(imported):
		_clear_new_nodes()
		return false
	# The first animated pose, never the rest T-pose, defines the body height.
	set_time(0.0)
	_source_bounds = _posed_mesh_bounds(meshes)
	if _source_bounds.size.y < 0.000001 or _initial_pose_geometry == null:
		push_error("Carrying animation has no usable first-frame body geometry")
		_clear_new_nodes()
		return false
	var height_scale := _old_local_height / _source_bounds.size.y
	pose_model.scale = Vector3.ONE * height_scale
	pose_model.position = -Vector3(_source_bounds.get_center().x, _source_bounds.position.y,
		_source_bounds.get_center().z) * height_scale
	_style_pose(meshes)
	_palms_local = _sample_palms()
	if _palms_local.size() != 2:
		_clear_new_nodes()
		return false
	_metadata_palm_error = maxf(_palms_local[0].distance_to(_point(bones.LeftPalm)),
		_palms_local[1].distance_to(_point(bones.RightPalm)))
	if not _build_potatoes():
		_clear_new_nodes()
		return false
	_initial_palm_basis = _palm_basis(_palms_local)
	_previous_palm_basis = _initial_palm_basis
	_bundle_reference_ready = true
	for label in ["held_flowering_potato", "held_sprouting_potato", "RightHandPotatoesAndFlowersPlaceholder"]:
		var old_prop := viewer.find_child(label, true, false) as Node3D
		if old_prop != null:
			_old_hand_props.append({"node": old_prop, "visible": old_prop.visible})
			old_prop.visible = false
	_old_model.visible = false
	_viewer.set("character_model", pose_model)
	_viewer.set("character_body", meshes[0])
	_viewer.set("character_geometry", _initial_pose_geometry)
	# Turn the body and its palm-attached bundle together around the feet.
	_actor.rotation.y -= deg_to_rad(turn_right_degrees)
	_configured = true
	set_time(0.0)
	print("BAGHDAD_CARRYING_POSE_READY ", JSON.stringify(evidence()))
	return true

func _style_pose(meshes: Array[Node]) -> void:
	for item in meshes:
		var body := item as MeshInstance3D
		if body.mesh == null:
			continue
		for surface in body.mesh.get_surface_count():
			var original := body.get_active_material(surface) as StandardMaterial3D
			var material := original.duplicate() as StandardMaterial3D if original != null else StandardMaterial3D.new()
			material.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
			material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
			material.metallic = 0.0
			material.roughness = 0.60
			body.set_surface_override_material(surface, material)
			_material_records.append({"mesh": str(body.name), "surface": surface,
				"original_texture_preserved": original != null and material.albedo_texture == original.albedo_texture,
				"has_albedo_texture": material.albedo_texture != null, "roughness": material.roughness,
				"diffuse_mode": "TOON", "specular": "DISABLED"})
		body.material_override = null
		var outline := StandardMaterial3D.new()
		outline.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		outline.cull_mode = BaseMaterial3D.CULL_FRONT
		outline.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		outline.albedo_color = Color(0.16, 0.12, 0.13)
		outline.grow = true
		outline.grow_amount = outline_width_normalized
		var shell := MeshInstance3D.new()
		shell.name = "CarryingPoseOutline_" + str(body.name)
		# Same-parent skeleton path and skin keep the shell on the live Carrying rig.
		shell.mesh = body.mesh
		shell.skin = body.skin
		shell.skeleton = body.skeleton
		shell.layers = body.layers
		shell.transform = body.transform
		shell.material_override = outline
		shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.get_parent().add_child(shell)
		shells.append(shell)

func _build_potatoes() -> bool:
	_prop_placer = load("res://scripts/traveler/baghdad/baghdad_prop_assets.gd").new()
	_prop_placer.configure(_viewer)
	potato_bundle = Node3D.new()
	potato_bundle.name = "PotatoBundle"
	pose_model.add_child(potato_bundle)
	potato_bundle.position = (_palms_local[0] + _palms_local[1]) * 0.5 + bundle_offset_normalized
	var left_world := pose_model.to_global(_palms_local[0])
	var right_world := pose_model.to_global(_palms_local[1])
	var across := right_world - left_world
	across.y = 0.0
	if across.length_squared() < 0.000001:
		across = _actor.global_basis.x
	across = across.normalized()
	var forward := _actor.global_basis.z.normalized()
	var palm_distance := left_world.distance_to(right_world)
	# The two lower potatoes sit over the supporting palms; a third nestles above.
	var spacing := clampf(palm_distance * 0.46, 0.021, 0.032)
	var offsets: Array[Vector3] = [across * -spacing, across * spacing,
		Vector3.UP * 0.030 + forward * 0.012]
	var yaws := [-18.0, 27.0, 68.0]
	for index in 3:
		var anchor := potato_bundle.global_position + offsets[index]
		var potato: Node3D = _prop_placer.place({"id": "CarriedPotato_%02d" % (index + 1),
			"asset": POTATO_ASSET, "anchor_world": anchor, "position": [0.0, 0.0, 0.0],
			"pivot": "center", "width_u": POTATO_WORLD_WIDTHS[index],
			"yaw_deg": rad_to_deg(_actor.global_rotation.y) + yaws[index],
			"ground_snap": false, "shadow": true, "kind": "carried_potato"}, potato_bundle)
		if potato == null:
			push_error("Unable to place carried potato from its original asset")
			return false
		var bounds: AABB = potato.get_meta("scaled_bounds", AABB())
		potato.global_position += Vector3.UP * bounds.size.y * 0.38
		potato.rotate_object_local(Vector3.RIGHT, deg_to_rad(8.0 if index != 1 else -9.0))
		potato.rotate_object_local(Vector3.FORWARD, deg_to_rad(-7.0 if index == 0 else 5.0))
		_potatoes.append(potato)
	potato_bundle.scale = Vector3.ONE * maxf(bundle_scale, 0.01)
	return true

func set_bundle_adjustment(offset_normalized: Vector3, scale_multiplier: float) -> void:
	bundle_offset_normalized = offset_normalized
	bundle_scale = maxf(scale_multiplier, 0.01)
	_update_bundle_transform()

func get_potatoes() -> Array[Node3D]:
	return _potatoes.duplicate()

func _configure_animation(imported: Node3D) -> bool:
	_player = imported.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var skeletons := imported.find_children("*", "Skeleton3D", true, false)
	if _player == null or skeletons.is_empty():
		push_error("Carrying animated GLB requires an AnimationPlayer and Skeleton3D")
		return false
	_skeleton = skeletons[0] as Skeleton3D
	_animation_length = 0.0
	for animation_key in _player.get_animation_list():
		if str(animation_key).to_upper() == "RESET":
			continue
		var clip := _player.get_animation(animation_key)
		if clip.length > _animation_length:
			_animation_name = animation_key
			_animation_length = clip.length
	if _animation_length <= 0.0:
		push_error("Carrying animated GLB has no playable source animation")
		return false
	for key in ["LeftHand", "RightHand", "LeftHandMiddle1", "RightHandMiddle1"]:
		var bone_index := _find_bone(key)
		if bone_index < 0:
			push_error("Carrying skeleton is missing " + key)
			return false
		_hand_bones[key] = bone_index
	_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_player.get_animation(_animation_name).loop_mode = Animation.LOOP_LINEAR
	_player.play(_animation_name)
	return true

func _find_bone(key: String) -> int:
	var target := key.to_lower()
	for index in _skeleton.get_bone_count():
		var bone_name := str(_skeleton.get_bone_name(index)).to_lower()
		# Handles mixamorig:Name, mixamorig_Name and importer-generated prefixes.
		if bone_name.ends_with(target):
			return index
	return -1

func set_time(seconds: float) -> void:
	if not is_instance_valid(_player) or not is_instance_valid(_skeleton) or _animation_length <= 0.0:
		return
	_animation_time = fposmod(seconds, _animation_length)
	_player.seek(_animation_time, true)
	_player.advance(0.0)
	_skeleton.force_update_all_bone_transforms()
	_palms_local = _sample_palms()
	_update_bundle_transform()

func _sample_palms() -> Array[Vector3]:
	var result: Array[Vector3] = []
	if not is_instance_valid(_skeleton) or not is_instance_valid(pose_model):
		return result
	for side in ["Left", "Right"]:
		var hand: Vector3 = _skeleton.get_bone_global_pose(int(_hand_bones[side + "Hand"])).origin
		var middle: Vector3 = _skeleton.get_bone_global_pose(int(_hand_bones[side + "HandMiddle1"])).origin
		var palm_world := _skeleton.global_transform * hand.lerp(middle, 0.65)
		result.append(pose_model.to_local(palm_world))
	return result

func _palm_basis(palms: Array[Vector3]) -> Basis:
	var across := palms[1] - palms[0]
	if across.length_squared() < 0.000001:
		return _previous_palm_basis
	across = across.normalized()
	# Bone order fixes the axis sign. Keep the carried bundle upright while the
	# inter-palm axis supplies the authored arm roll/yaw, without a pole flip.
	if _bundle_reference_ready and across.dot(_initial_palm_basis.x) < 0.0:
		across = -across
	var up := Vector3.UP - across * across.dot(Vector3.UP)
	if up.length_squared() < 0.0001:
		up = _previous_palm_basis.y - across * across.dot(_previous_palm_basis.y)
	if up.length_squared() < 0.0001:
		return _previous_palm_basis
	up = up.normalized()
	var forward := across.cross(up).normalized()
	up = forward.cross(across).normalized()
	return Basis(across, up, forward)

func _update_bundle_transform() -> void:
	if not _bundle_reference_ready or not is_instance_valid(potato_bundle) or _palms_local.size() != 2:
		return
	var current_basis := _palm_basis(_palms_local)
	var delta_basis := current_basis * _initial_palm_basis.inverse()
	var midpoint := (_palms_local[0] + _palms_local[1]) * 0.5
	potato_bundle.transform = Transform3D(delta_basis.scaled(Vector3.ONE * maxf(bundle_scale, 0.01)),
		midpoint + delta_basis * bundle_offset_normalized)
	_previous_palm_basis = current_basis

func evidence() -> Dictionary:
	var palms_world: Array = []
	var potato_records: Array = []
	if is_instance_valid(pose_model):
		for palm in _palms_local:
			palms_world.append(_array(pose_model.to_global(palm)))
	for index in _potatoes.size():
		var potato := _potatoes[index]
		if is_instance_valid(potato):
			potato_records.append({"name": str(potato.name), "world_position": _array(potato.global_position),
				"nominal_world_width": POTATO_WORLD_WIDTHS[index] * bundle_scale,
				"asset": POTATO_ASSET, "source_meshes_and_atlas_preserved": true})
	var hidden: Array = []
	for record in _old_hand_props:
		if is_instance_valid(record.node):
			hidden.append({"name": str(record.node.name), "visible": record.node.visible,
				"original_visible": record.visible})
	return {"configured": _configured, "pose_asset": POSE_ASSET, "landmarks_asset": LANDMARK_ASSET,
		"source_frame": _landmarks.get("source_frame", 1), "static_baked_pose": false, "animated": true,
		"animation_name": str(_animation_name), "animation_length_seconds": _animation_length,
		"animation_time_seconds": _animation_time, "animation_mode": "manual absolute time, looping source Carrying clip",
		"bone_count": _skeleton.get_bone_count() if is_instance_valid(_skeleton) else 0,
		"hand_bones": _hand_bones, "bone_following": true,
		"bundle_following": "current two-palm midpoint and basis relative to initial two-palm frame",
		"initial_palms_max_error_vs_metadata": _metadata_palm_error,
		"character_geometry_snapshot_time_seconds": 0.0,
		"actor_transform_preserved": is_instance_valid(_actor) and _actor.transform == _old_actor_transform,
		"actor_position_preserved": is_instance_valid(_actor) and _actor.position == _old_actor_transform.origin,
		"actor_scale_preserved": is_instance_valid(_actor) and _actor.scale.is_equal_approx(_old_actor_transform.basis.get_scale()),
		"turn_right_degrees": turn_right_degrees,
		"actor_yaw_degrees": rad_to_deg(_actor.rotation.y) if is_instance_valid(_actor) else 0.0,
		"original_actor_local_height": _old_local_height,
		"source_bounds": {"position": _array(_source_bounds.position), "size": _array(_source_bounds.size)},
		"old_model_hidden": is_instance_valid(_old_model) and not _old_model.visible,
		"hidden_old_hand_props": hidden, "palms_world": palms_world,
		"bundle_offset_normalized": _array(bundle_offset_normalized), "bundle_scale": bundle_scale,
		"potatoes": potato_records, "potato_count": potato_records.size(), "flowers_added": false,
		"materials": _material_records, "outline_shell_count": shells.size(),
		"outline_uses_carrying_mesh": true, "outline_uses_carrying_skin": true,
		"outline_width_normalized": outline_width_normalized,
		"scope": "Source Carrying animation and palm-bound potatoes; camera, actor position/scale and weather unchanged"}

func restore() -> void:
	if _configured and is_instance_valid(_actor):
		_actor.transform = _old_actor_transform
	if _configured and is_instance_valid(_viewer):
		_viewer.set("character_model", _old_model)
		_viewer.set("character_body", _old_body)
		_viewer.set("character_geometry", _old_geometry)
	if is_instance_valid(_old_model):
		_old_model.visible = _old_model_visible
	for record in _old_hand_props:
		if is_instance_valid(record.node):
			record.node.visible = record.visible
	_old_hand_props.clear()
	_configured = false
	_clear_new_nodes()

func _clear_new_nodes() -> void:
	if is_instance_valid(pose_model):
		pose_model.free()
	pose_model = null
	potato_bundle = null
	shells.clear()
	_potatoes.clear()
	_palms_local.clear()
	_material_records.clear()
	_prop_placer = null
	_player = null
	_skeleton = null
	_animation_name = &""
	_animation_length = 0.0
	_animation_time = 0.0
	_hand_bones.clear()
	_bundle_reference_ready = false
	_initial_palm_basis = Basis.IDENTITY
	_previous_palm_basis = Basis.IDENTITY
	_initial_pose_geometry = null
	_metadata_palm_error = 0.0

func _posed_mesh_bounds(meshes: Array[Node]) -> AABB:
	var result := AABB()
	var first := true
	for item in meshes:
		var mesh := item as MeshInstance3D
		if mesh.mesh == null:
			continue
		# Renderer skin registration can be deferred on freshly generated GLTF nodes.
		# A CPU snapshot of these same bind matrices makes configure synchronous and
		# works in headless validation too; the visible mesh keeps GPU skinning.
		var baked: Mesh = _bake_pose_geometry(mesh) if mesh.skin != null else mesh.mesh
		if baked == null or baked.get_surface_count() == 0:
			continue
		if first:
			_initial_pose_geometry = baked
		var relative := pose_model.global_transform.affine_inverse() * mesh.global_transform
		var bounds := relative * baked.get_aabb()
		result = bounds if first else result.merge(bounds)
		first = false
	return result

func _bake_pose_geometry(body: MeshInstance3D) -> Mesh:
	var skeleton := body.get_node_or_null(body.skeleton) as Skeleton3D
	if skeleton == null or body.skin == null:
		return null
	var skeleton_to_body := body.global_transform.affine_inverse() * skeleton.global_transform
	var transforms: Array[Transform3D] = []
	var normal_transforms: Array[Basis] = []
	for bind in body.skin.get_bind_count():
		var bone := body.skin.get_bind_bone(bind)
		var bind_name := body.skin.get_bind_name(bind)
		if not str(bind_name).is_empty():
			bone = skeleton.find_bone(bind_name)
		if bone < 0 or bone >= skeleton.get_bone_count():
			push_error("Carrying skin contains an unresolved bone bind")
			return null
		var transform := skeleton_to_body * skeleton.get_bone_global_pose(bone) * body.skin.get_bind_pose(bind)
		transforms.append(transform)
		normal_transforms.append(transform.basis.inverse().transposed())
	var result := ArrayMesh.new()
	for surface in body.mesh.get_surface_count():
		var arrays: Array = body.mesh.surface_get_arrays(surface).duplicate(true)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if vertices.is_empty() or joints.is_empty() or weights.size() != joints.size():
			push_error("Carrying animated surface has no usable skin weights")
			return null
		var influences := joints.size() / vertices.size()
		for index in vertices.size():
			var vertex := Vector3.ZERO
			var normal := Vector3.ZERO
			var total := 0.0
			for influence in influences:
				var address := index * influences + influence
				var weight := weights[address]
				var bind := joints[address]
				if weight <= 0.0 or bind < 0 or bind >= transforms.size():
					continue
				vertex += (transforms[bind] * vertices[index]) * weight
				if index < normals.size():
					normal += (normal_transforms[bind] * normals[index]) * weight
				total += weight
			if total > 0.0:
				vertices[index] = vertex / total
				if index < normals.size():
					normals[index] = normal.normalized()
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_BONES] = null
		arrays[Mesh.ARRAY_WEIGHTS] = null
		# This geometry is a measurement snapshot, not a rendered replacement.
		arrays[Mesh.ARRAY_TANGENT] = null
		result.add_surface_from_arrays(body.mesh.surface_get_primitive_type(surface), arrays)
		result.surface_set_material(surface, body.get_active_material(surface))
	return result

func _is_point(value: Variant) -> bool:
	return value is Array and value.size() == 3

func _point(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func _array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func _exit_tree() -> void:
	restore()
