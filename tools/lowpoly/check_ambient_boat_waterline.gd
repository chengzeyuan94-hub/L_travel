extends SceneTree
## Actual runtime mesh and imported sea bounds; no GUI or rule mutation.
## Tests the whole independent pitch/roll/heave envelope, not selected frames.

const Ambient := preload("res://scripts/ui/planet_ambient_layer.gd")
const Geometry := preload("res://scripts/ui/planet_geometry.gd")
const OUTPUT := "res://docs/design/planet-v2/validation/variation-007/ambient-boat-waterline.json"
var _checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(label: String, passed: bool) -> void:
	_checks.append({"name": label, "passed": passed})


func _number(pattern: String, source: String) -> float:
	var regex := RegEx.new()
	assert(regex.compile(pattern) == OK)
	var found := regex.search(source)
	assert(found != null, "Motion amplitude must be read from the actual shader")
	return float(found.get_string(1))


func _lower_y(vertex: Vector3, pitch: float, roll: float) -> float:
	# Rx(pitch)*Rz(roll): y'=cos(pitch)*(x*sin(roll)+y*cos(roll))-z*sin(pitch).
	# Triangle y interpolation cannot fall below all three vertex bounds.
	return vertex.y - absf(vertex.x)*sin(roll) - absf(vertex.y)*(1.0-cos(pitch)*cos(roll)) - absf(vertex.z)*sin(pitch)


func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var layer := Ambient.new()
	world.add_child(layer)
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/rulesets/lshu_configurable_v1/board_nodes.json"))
	var nodes := {}
	for node in raw["items"]:
		nodes[node["id"]] = node
	layer.configure({"board_nodes": nodes})
	var boat: MultiMeshInstance3D = layer.get_node("MooredBoats3")
	var mesh: Mesh = boat.multimesh.mesh
	var deck: Array[Vector3] = []
	var rim: Array[Vector3] = []
	var keel := Vector3.INF
	var vertex_count := 0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		vertex_count += vertices.size()
		for i in vertices.size():
			if colors[i].is_equal_approx(Color("755838")):
				deck.append(vertices[i])
			elif colors[i].is_equal_approx(Color("d0a66e")):
				rim.append(vertices[i])
			elif colors[i].is_equal_approx(Color("946f43")) and absf(vertices[i].x) < .00001 and absf(vertices[i].z) < .00001:
				if not keel.is_finite() or vertices[i].y < keel.y:
					keel = vertices[i]
	_check("runtime_mesh_has_deck_rim_and_centre_keel", not deck.is_empty() and not rim.is_empty() and keel.is_finite())
	_check("decorative_boat_has_one_surface", mesh.get_surface_count() == 1)

	var sea := (load("res://assets/game/lowpoly/planet/water.glb") as PackedScene).instantiate() as Node3D
	world.add_child(sea)
	var sea_outer_radius := 0.0
	var sea_inner_radius := INF
	var water_faces := 0
	for object in sea.find_children("*", "MeshInstance3D", true, false):
		var part := object as MeshInstance3D
		for surface in part.mesh.get_surface_count():
			var arrays := part.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var ids: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for p in vertices:
				sea_outer_radius = maxf(sea_outer_radius, (part.global_transform*p).length())
			var count := ids.size() if not ids.is_empty() else vertices.size()
			for i in range(0, count, 3):
				var a := part.global_transform*vertices[ids[i] if not ids.is_empty() else i]
				var b := part.global_transform*vertices[ids[i+1] if not ids.is_empty() else i+1]
				var c := part.global_transform*vertices[ids[i+2] if not ids.is_empty() else i+2]
				var normal := (b-a).cross(c-a).normalized()
				sea_inner_radius = minf(sea_inner_radius, absf(a.dot(normal)))
				water_faces += 1
	# The GLB's 11.03 sphere is vertex-compressed on Godot import. All waterline
	# comparisons use the measured import bounds, not its nominal source radius.
	_check("imported_sea_near_11_03_with_compression_tolerance", absf(sea_outer_radius-11.03) < .001 and water_faces > 1000)

	var shader_source := FileAccess.get_file_as_string("res://scripts/ui/ambient/ambient_motion.gdshader")
	var pitch := _number("sin\\(t\\*0\\.71\\+p\\)\\*([0-9.]+)",shader_source)
	var roll := _number("sin\\(t\\*0\\.58\\+p\\+1\\.0\\)\\*([0-9.]+)",shader_source)
	var heave := _number("sin\\(t\\*0\\.8\\+p\\)\\*([0-9.]+)",shader_source)
	var deck_lower := INF
	var rim_lower := INF
	for p in deck:
		deck_lower = minf(deck_lower,_lower_y(p,pitch,roll))
	for p in rim:
		rim_lower = minf(rim_lower,_lower_y(p,pitch,roll))
	var rows: Array[Dictionary] = []
	var poses := {}
	for record in layer.get("_anchors"):
		if record["category"] == "moored_boat":
			poses[record["id"]] = record["transform"]
	_check("CPU_pose_records_match_multimesh_instance_count", poses.size() == boat.multimesh.instance_count)
	for i in boat.multimesh.instance_count:
		# The dummy renderer does not retain MM transform buffers. These are the
		# actual CPU Transform3Ds passed to _batch and its set_instance_transform.
		var pose: Transform3D = poses["moored_boat_%d"%i]
		var radius := pose.origin.length()
		_check("boat_%d_has_unit_scale"%i, pose.basis.get_scale().is_equal_approx(Vector3.ONE))
		var deck_clearance := radius-heave+deck_lower-sea_outer_radius
		var rim_clearance := radius-heave+rim_lower-sea_outer_radius
		# The centre keel has x=z=0; this is its exact maximum radial length
		# over the independent rotation/amplitude box, including sphere curvature.
		var upper_y := keel.y*cos(pitch)*cos(roll)
		var upper_keel_radius := sqrt(pow(radius+heave,2)+keel.length_squared()+2*(radius+heave)*upper_y)
		var keel_submergence := sea_inner_radius-upper_keel_radius
		_check("boat_%d_complete_deck_always_above_sea"%i, deck_clearance > .001)
		_check("boat_%d_whole_gunwale_always_above_sea"%i, rim_clearance > .0005)
		_check("boat_%d_keel_always_partly_submerged"%i, keel_submergence > .001)
		rows.append({"instance": i, "root_radius": radius, "root_height": radius-Geometry.RADIUS,
			"deck_clearance_lower_bound_world": deck_clearance, "gunwale_clearance_lower_bound_world": rim_clearance,
			"keel_submergence_lower_bound_world": keel_submergence})
	var diagnostics := layer.get_diagnostics()
	_check("ambient_still_has_58_particles_and_no_shadows", diagnostics["particle_capacity"] == 58 and diagnostics["shadow_casting_geometry_count"] == 0)
	_check("ambient_still_has_11_batches_2193_triangles", diagnostics["mesh_batches"] == 11 and diagnostics["mesh_triangles_instanced"] == 2193)
	var actor_source := FileAccess.get_file_as_string("res://scripts/ui/lowpoly_map_piece_actor.gd")
	_check("player_ship_root_is_unchanged", is_equal_approx(_number("const SHIP_Y := ([0-9.]+)",actor_source)+Geometry.RADIUS,11.035))
	var failed := 0
	for check in _checks:
		if not check["passed"]:
			failed += 1
	var paths := ["scripts/ui/planet_ambient_layer.gd","scripts/ui/ambient/ambient_meshes.gd","scripts/ui/ambient/ambient_motion.gdshader","scripts/ui/lowpoly_map_piece_actor.gd","assets/game/lowpoly/planet/water.glb"]
	var hashes := {}
	for path in paths:
		hashes[path] = FileAccess.get_sha256("res://"+path)
	var report := {"task": "B2d-decorative-boat-waterline", "method": "Runtime MultiMesh vertices identified by authored deck/rim/hull colors; actual CPU Transform3D inputs sent to MultiMesh (dummy renderer cannot read back buffers); imported sea outer vertex radius and inner face-plane radius; analytic independent full pitch/roll/heave bounds.",
		"source_sha256": hashes, "mesh_vertices": vertex_count,"deck_vertices": deck.size(),"gunwale_vertices": rim.size(),
		"centre_keel": keel, "water_face_count": water_faces, "sea_outer_radius": sea_outer_radius,"sea_inner_radius":sea_inner_radius,
		"amplitudes_from_shader": {"pitch_radians":pitch,"roll_radians":roll,"heave_world":heave}, "boats":rows,
		"old_0_035_root_counterfactual": {"deck_clearance_lower_bound_world":11.035-heave+deck_lower-sea_outer_radius,
			"gunwale_clearance_lower_bound_world":11.035-heave+rim_lower-sea_outer_radius},
		"checks":_checks,"passed":_checks.size()-failed,"failed":failed,"scope_note":"Headless geometry proof; root separately repeats GPU/video QA. No player vessel height change."}
	var file := FileAccess.open(OUTPUT,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("AMBIENT_BOAT_WATERLINE ",JSON.stringify({"passed":report["passed"],"failed":failed,"boats":rows}))
	world.free()
	quit(0 if failed == 0 else 1)
