extends SceneTree
## Samples the shipping Panti controller and actual imported GLB. Geometry is
## exported once; compact float32 skin matrices are deformed later with NumPy.
## Mandatory --out=/absolute/report.json. Never writes previous evidence.

var asset_path := "res://assets/traveler/panti/camp/character/sitting-animated.glb"
var controller_path := "res://scripts/traveler/panti/panti_seated_actor.gd"
var out_path := ""
var sample_hz := 60.0
var model: Node3D
var actor: RefCounted
var skeleton: Skeleton3D
var meshes: Array[MeshInstance3D] = []
var bind_bones: Array = []
var mesh_records: Array = []
var samples: Array = []
var matrix_file: FileAccess
var failed := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--asset="): asset_path = arg.trim_prefix("--asset=")
		if arg.begins_with("--controller="): controller_path = arg.trim_prefix("--controller=")
		if arg.begins_with("--out="): out_path = arg.trim_prefix("--out=")
		if arg.begins_with("--hz="): sample_hz = float(arg.trim_prefix("--hz="))
	call_deferred("run")

func abort(message: String) -> void:
	failed = true
	push_error("Panti seated idle audit: " + message)
	quit(1)

func run() -> void:
	if out_path.is_empty() or not out_path.is_absolute_path():
		abort("--out must be an explicit absolute path"); return
	if sample_hz <= 0.0:
		abort("--hz must be positive"); return
	var packed := load(asset_path) as PackedScene
	var controller_script := load(controller_path) as Script
	if packed == null or controller_script == null:
		abort("actual asset or shipping controller missing"); return
	model = packed.instantiate() as Node3D
	root.add_child(model)
	actor = controller_script.new()
	actor.configure(model, {})
	var player: AnimationPlayer = actor.player
	skeleton = actor.skeleton
	if player == null or skeleton == null:
		abort("controller did not bind its AnimationPlayer/Skeleton3D"); return
	var animation_name: String = str(actor.animation_name)
	var animation := player.get_animation(animation_name)
	if animation == null or animation.length <= 0.0:
		abort("shipping animation is absent or empty"); return
	var skeleton_ids: Array = []
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh == null or mesh_node.skin == null:
			abort("unskinned or empty render mesh: " + str(mesh_node.name)); return
		var mesh_skeleton := mesh_node.get_node_or_null(mesh_node.skeleton) as Skeleton3D
		if mesh_skeleton == null or mesh_skeleton != skeleton:
			abort("mesh does not use the controller Skeleton3D: " + str(mesh_node.name)); return
		skeleton_ids.append(str(model.get_path_to(mesh_skeleton)))
		if not register_mesh(mesh_node): return
	if meshes.size() != 2:
		abort("expected body and filtered outline, found " + str(meshes.size())); return
	var names: Array = []
	for mesh_node in meshes: names.append(str(mesh_node.name))
	if not names.has("PantiSeatedBody") or not names.has("PantiSeatedOutline"):
		abort("body/outline node identity changed: " + str(names)); return
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var matrix_path := out_path.trim_suffix(".json") + ".poses.f32"
	matrix_file = FileAccess.open(matrix_path, FileAccess.WRITE)
	if matrix_file == null:
		abort("cannot open matrix output: " + matrix_path); return
	var duration := float(animation.length)
	var per_cycle := ceili(duration * sample_hz)
	# Exact repeated phases, reached through the same set_time path as the viewer.
	for cycle in 3:
		for phase_index in per_cycle:
			var phase := float(phase_index) / float(per_cycle)
			sample_pose((float(cycle) + phase) * duration, "cycle", cycle, phase_index, phase)
	sample_pose(3.0 * duration, "cycle", 3, 0, 0.0)
	# Explicit samples on both sides of several boundaries, including loop 2000.
	var epsilon := 0.00001
	for boundary in [1, 2, 3, 2000]:
		for side in [-1, 0, 1]:
			sample_pose(float(boundary) * duration - float(actor.start_offset_s) + float(side) * epsilon,
				"boundary", boundary, side, float(side) * epsilon / duration)
	for phase_index in 5:
		var phase: float = [0.0, 0.173, 0.5, 0.813, 0.999999][phase_index]
		for cycle in [0, 2000]:
			sample_pose((float(cycle) + phase) * duration, "long_run", cycle, phase_index, phase)
	matrix_file.close()
	var roots: Array = []
	for bone in skeleton.get_bone_count():
		if skeleton.get_bone_parent(bone) < 0: roots.append(str(skeleton.get_bone_name(bone)))
	var tracks: Array = []
	for track in animation.get_track_count():
		tracks.append({"path": str(animation.track_get_path(track)), "type": animation.track_get_type(track), "keys": animation.track_get_key_count(track)})
	var result := {
		"schema": "silkroad.panti-seated-idle-samples.v1", "asset": asset_path,
		"asset_sha256": FileAccess.get_sha256(ProjectSettings.globalize_path(asset_path)),
		"controller": controller_path, "controller_sha256": FileAccess.get_sha256(ProjectSettings.globalize_path(controller_path)),
		"controller_evidence": actor.evidence(), "animation": animation_name,
		"duration_s": duration, "loop_mode": animation.loop_mode, "tracks": tracks,
		"sample_hz_requested": sample_hz, "samples_per_cycle": per_cycle, "full_cycles": 3,
		"skeleton_bones": skeleton.get_bone_count(), "root_bones": roots,
		"mesh_skeleton_paths": skeleton_ids, "same_skeleton": true,
		"meshes": mesh_records, "samples": samples,
		"matrix_file": matrix_path, "matrix_dtype": "little-endian float32",
		"matrix_layout": "sample then mesh then named Skin bind then row-major 3x4; coordinates relative to model root",
	}
	var output := FileAccess.open(out_path, FileAccess.WRITE)
	if output == null:
		abort("cannot open metadata output"); return
	output.store_string(JSON.stringify(result))
	output.close()
	print("PANTI_SEATED_IDLE_SAMPLES ", JSON.stringify({"out": out_path, "poses": matrix_path, "samples": samples.size(), "bones": skeleton.get_bone_count(), "meshes": names, "actual_controller": controller_path}))
	model.queue_free()
	await process_frame
	quit(0)

func register_mesh(node: MeshInstance3D) -> bool:
	var mapping: Array = []
	var bones: Array[int] = []
	for bind in node.skin.get_bind_count():
		var name := str(node.skin.get_bind_name(bind))
		if name.is_empty():
			abort("unnamed Skin bind, refusing index fallback: " + str(node.name) + ":" + str(bind)); return false
		var bone := skeleton.find_bone(name)
		if bone < 0:
			abort("Skin bind bone missing: " + name); return false
		mapping.append({"name": name, "bone": bone, "inverse_bind": matrix_values(node.skin.get_bind_pose(bind))})
		bones.append(bone)
	var surfaces: Array = []
	for surface in node.mesh.get_surface_count():
		if node.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			abort("render surface is not triangles"); return false
		var arrays := node.mesh.surface_get_arrays(surface)
		var positions: Array = []
		for vertex in arrays[Mesh.ARRAY_VERTEX]: positions.append([vertex.x, vertex.y, vertex.z])
		if arrays[Mesh.ARRAY_WEIGHTS] == null or arrays[Mesh.ARRAY_BONES] == null:
			abort("mesh has no skin attributes: " + str(node.name)); return false
		var indices: Array = []
		if arrays[Mesh.ARRAY_INDEX] != null: indices = Array(arrays[Mesh.ARRAY_INDEX])
		if indices.is_empty():
			for vertex in positions.size(): indices.append(vertex)
		surfaces.append({"positions": positions, "indices": indices,
			"weights": Array(arrays[Mesh.ARRAY_WEIGHTS]), "bones": Array(arrays[Mesh.ARRAY_BONES])})
	meshes.append(node)
	bind_bones.append(bones)
	mesh_records.append({"name": str(node.name), "path": str(model.get_path_to(node)),
		"bind_mapping": mapping, "surfaces": surfaces, "skeleton_path": str(node.skeleton)})
	return true

func sample_pose(time: float, kind: String, cycle: int, phase_index: int, phase: float) -> void:
	actor.set_time(time)
	skeleton.force_update_all_bone_transforms()
	var root_inverse := model.global_transform.affine_inverse()
	var skeleton_to_model := root_inverse * skeleton.global_transform
	var packed := PackedFloat32Array()
	for mesh_index in meshes.size():
		var skin := meshes[mesh_index].skin
		var bones: Array = bind_bones[mesh_index]
		for bind in bones.size():
			var transform := skeleton_to_model * skeleton.get_bone_global_pose(bones[bind]) * skin.get_bind_pose(bind)
			packed.append_array(PackedFloat32Array(matrix_values(transform)))
	matrix_file.store_buffer(packed.to_byte_array())
	var root_poses: Dictionary = {}
	for bone in skeleton.get_bone_count():
		if skeleton.get_bone_parent(bone) < 0:
			root_poses[str(skeleton.get_bone_name(bone))] = matrix_values(skeleton_to_model * skeleton.get_bone_global_pose(bone))
	var seat: Vector3 = actor.current_seat_anchor()
	var target_seat: Vector3 = actor.seat_anchor
	samples.append({"kind": kind, "cycle": cycle, "phase_index": phase_index,
		"phase": phase, "time_s": time, "player_position_s": float(actor.player.current_animation_position),
		"seat_anchor": [seat.x, seat.y, seat.z], "seat_anchor_target": [target_seat.x, target_seat.y, target_seat.z],
		"model_global_transform": matrix_values(model.global_transform), "root_bone_poses": root_poses})

func matrix_values(t: Transform3D) -> Array:
	return [t.basis.x.x, t.basis.y.x, t.basis.z.x, t.origin.x,
		t.basis.x.y, t.basis.y.y, t.basis.z.y, t.origin.y,
		t.basis.x.z, t.basis.y.z, t.basis.z.z, t.origin.z]
