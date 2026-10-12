extends Node3D
## 第四幕「L叔在哪儿」· one tile, assembled from its baked files with the global look. One node per tile; the
## scene builds the next tile hidden, then swaps in a single frame (fix #6).
##   data/traveler/lshu/tiles/<id>.json          lshu.tile.v1 + precompute (ground info, scatter buffers)
##   assets/traveler/lshu/tiles/proc_<sha>.glb   procedural parts, one node per role (edge data from import)
##   assets/traveler/lshu/props/<asset>.glb      placed assets (edge data from import)
## Build phases (all rules global, nothing keyed by tile id):
##   prepare()  worker thread: read + parse the JSON, decode the stored buffers; threaded resource requests
##   build()    main thread, time-sliced: procedural parts, instances, scatter, life; never more than
##              budget_ms of work per frame
##   bind()     swap frame (called by the scene after the camera fit): per-tile inputs on the shared materials
## (repair_r2: compute_bounds() also runs while the scene plans the staged tile's swap; the merge's triangle lists give
## the actor motion its collision triangles, faces_for(), made on a worker thread during the build)
## Shadow casters (draw-call rule, see _merge_static_shadows): everything on the tile that never moves casts into
## the shadow maps as one shadows-only mesh per render layer.

const TILE_DIR: String = "res://data/traveler/lshu/tiles/"
const PROPS_DIR: String = "res://assets/traveler/lshu/props/"
const LIFE_SCRIPT: GDScript = preload("res://scripts/traveler/lshu/lshu_life.gd")
const SCATTER: GDScript = preload("res://scripts/traveler/lshu/lshu_scatter.gd")
const GROUND_INFO: GDScript = preload("res://scripts/traveler/lshu/lshu_ground_info.gd")
const SURFACE_DETAIL: GDScript = preload("res://scripts/traveler/lshu/lshu_surface_detail.gd")
const EDGES: GDScript = preload("res://scripts/traveler/lshu/lshu_edges.gd")
## Instance animations that move an asset every frame (its shadow must move with it).
const MOVING_ANIMS: Array[String] = ["sway", "boat", "bob"]

static var _asset_cache: Dictionary = {}
static var _shadow_material: StandardMaterial3D
## repair_r2: vertex / index arrays of the placed assets' meshes for the shadow merge, read once per mesh (reading a
## mesh back from the GPU stalls the frame until the GPU is idle, and the same props recur on many tiles).
static var _surface_cache: Dictionary = {}

var tile_id: String = ""
var tile: Dictionary = {}
var precompute: Dictionary = {}
var look: RefCounted
var proc_root: Node3D
var instances_root: Node3D
var scatter_root: Node3D
var life: Node3D
var proc_nodes: Dictionary = {}
var instance_nodes: Array[Dictionary] = []
var sway_nodes: Array[MeshInstance3D] = []
var rotors: Array[Dictionary] = []
var bobbers: Array[Dictionary] = []
var fire_lights: Array[OmniLight3D] = []
var lamp_lights: Array[OmniLight3D] = []
var roles_used: Dictionary = {}
var height_grid: Array = []
var terrain_n: int = 52
var terrain_step: float = 8.0 / 52.0
var height_texture: ImageTexture
var ground_maps: Dictionary = {}
var tile_bounds: AABB
var camera_fit: Dictionary = {}
var surface_report: Dictionary = {}
var shadow_report: Dictionary = {}
var shadow_nodes: Array[MeshInstance3D] = []
var timings: Dictionary = {}
var errors: Array[String] = []
var _prepared: Dictionary = {}
var _task_id: int = -1
## wait_prepared() already claimed _task_id (a task id may be waited for once only)
var _task_claimed: bool = false
var _frame_start_us: int = 0
## QA timing: main-thread ms of every time-sliced build frame; slice_hook(label, ms) (the scene's work log) is told
## each one as it ends.
var slices_ms: Array[float] = []
var slice_hook: Callable = Callable()
## repair_r2: the collision triangles of this tile's own big meshes - the merged shadow casters and the procedural
## parts whose triangles the merge read - exactly as Mesh.get_faces() returns them (a TriangleMesh made from the same
## triangle list), made on a worker thread while the tile is still being built (time-sliced builds only), so the
## actor motion does not read them back from the GPU on the frames around the swap. See faces_for().
var _faces_src: Dictionary = {}     # instance id -> [[vertices, indices], ...] per surface
var _faces: Dictionary = {}         # instance id -> PackedVector3Array
var _faces_box: Dictionary = {}
var _faces_task: int = -1

static func tile_path(id: String) -> String:
	return TILE_DIR + id + ".json"

# ------------------------------------------------------------------ phase 1: worker thread
## Starts reading the tile off the main thread. Poll is_prepared() each frame.
func prepare(id: String) -> void:
	tile_id = id
	name = "Tile"
	_prepared = {}
	_task_claimed = false
	_task_id = WorkerThreadPool.add_task(_prepare_worker.bind(tile_path(id)), false, "lshu tile read")

func is_prepared() -> bool:
	return _task_id >= 0 and WorkerThreadPool.is_task_completed(_task_id)

func _prepare_worker(path: String) -> void:
	var t0: int = Time.get_ticks_usec()
	var out: Dictionary = {}
	if not FileAccess.file_exists(path):
		out["error"] = "tile JSON missing: " + path
		_prepared = out
		return
	var parser: JSON = JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK or not parser.data is Dictionary:
		out["error"] = "tile JSON invalid: " + path
		_prepared = out
		return
	var data: Dictionary = parser.data
	out["tile"] = data
	var pre: Dictionary = data.get("precompute", {})
	if pre.is_empty():
		out["error"] = "tile JSON has no precompute section (run tools/traveler/lshu/bake/precompute_tiles.gd): " + path
	# height field as a float image (bytes ready for the main thread)
	var terrain: Dictionary = data.get("terrain", {})
	var grid: Array = terrain.get("heights", [])
	var size: int = int(terrain.get("N", 52)) + 1
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(size * size)
	for j: int in mini(size, grid.size()):
		var row: Array = grid[j]
		for i: int in mini(size, row.size()):
			heights[j * size + i] = float(row[i])
	out["height_bytes"] = heights.to_byte_array()
	out["height_size"] = size
	# resources the main thread will instantiate
	var paths: Array[String] = []
	paths.append(str((data.get("proc", {}) as Dictionary).get("file", "")))
	for inst: Variant in data.get("instances", []):
		var p: String = PROPS_DIR + str((inst as Dictionary).get("asset_id", "")) + ".glb"
		if not paths.has(p):
			paths.append(p)
	out["paths"] = paths
	out["ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	_prepared = out

## Blocks until prepare() finished (capture / precompute paths).
func wait_prepared() -> void:
	if _task_id >= 0 and not _task_claimed:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_claimed = true

# ------------------------------------------------------------------ phase 2: main thread, time-sliced
func _budget_check(budget_ms: float) -> bool:
	return float(Time.get_ticks_usec() - _frame_start_us) / 1000.0 > budget_ms

func _yield_if_over(budget_ms: float) -> void:
	if budget_ms > 0.0 and _budget_check(budget_ms):
		_end_slice()
		await get_tree().process_frame
		_frame_start_us = Time.get_ticks_usec()

## QA timing: closes the current build slice (see slices_ms).
func _end_slice() -> void:
	var ms: float = float(Time.get_ticks_usec() - _frame_start_us) / 1000.0
	slices_ms.append(snappedf(ms, 0.001))
	if slice_hook.is_valid():
		slice_hook.call("build", ms)

static func _request(path: String) -> void:
	if not _asset_cache.has(path) and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		if ResourceLoader.load_threaded_request(path, "PackedScene") == OK:
			_requested[path] = true

## Threaded requests made by prefetch() that nobody collected yet (release_all() collects them).
static var _requested: Dictionary = {}

## The title opened this act in its own window and it is closing (lshu_main.gd _exit_tree, traveler_launch.gd hosting):
## the process goes on, so collect every threaded read still in flight (blocks until each is loaded; no load token may
## outlive the scene) and drop the static caches, so the title and a match get the memory back. The next visit reads the
## props again (the pipeline / shader caches stay).
static func release_all() -> void:
	for p: String in _requested.keys():
		if ResourceLoader.load_threaded_get_status(p) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			ResourceLoader.load_threaded_get(p)
	_requested.clear()
	_asset_cache.clear()
	_surface_cache.clear()
	_shadow_material = null

static func _all_loaded(paths: Array) -> bool:
	for p: Variant in paths:
		var path: String = str(p)
		if _asset_cache.has(path):
			continue
		var st: int = ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return false
	return true

static func _scene(path: String) -> PackedScene:
	if _asset_cache.has(path):
		return _asset_cache[path]
	var packed: PackedScene
	if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		packed = ResourceLoader.load_threaded_get(path) as PackedScene
		_requested.erase(path)
	else:
		packed = load(path) as PackedScene
	if packed != null:
		_asset_cache[path] = packed
	return packed

## Requests (threaded) every scene the given tile ids use, so later switches find them loaded. Returns the
## requested paths; collect() them once loaded (no load token may outlive the scene).
static func prefetch(ids: Array[String]) -> Array[String]:
	var paths: Array[String] = []
	for id: String in ids:
		var parser: JSON = JSON.new()
		if parser.parse(FileAccess.get_file_as_string(tile_path(id))) != OK or not parser.data is Dictionary:
			continue
		var data: Dictionary = parser.data
		var wanted: Array[String] = [str((data.get("proc", {}) as Dictionary).get("file", ""))]
		for inst: Variant in data.get("instances", []):
			wanted.append(PROPS_DIR + str((inst as Dictionary).get("asset_id", "")) + ".glb")
		for p: String in wanted:
			if not paths.has(p):
				paths.append(p)
				_request(p)
	return paths

## True once every path is loaded; moves loaded scenes into the cache.
static func collect(paths: Array[String]) -> bool:
	if not _all_loaded(paths):
		return false
	for p: String in paths:
		_scene(p)
	return true

## Assembles the tile under this (hidden) node. budget_ms <= 0: no time slicing. geometry_only: procedural
## parts and instances only (offline precompute). Returns false on a data error (already reported).
func build(look_ref: RefCounted, motion_frozen: bool, budget_ms: float, geometry_only: bool = false) -> bool:
	look = look_ref
	var t0: int = Time.get_ticks_usec()
	_frame_start_us = t0
	while not is_prepared():
		await get_tree().process_frame
		_frame_start_us = Time.get_ticks_usec()
	if not _task_claimed:
		WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	if _prepared.has("error") and not (geometry_only and _prepared.has("tile")):
		push_error("LSHU " + str(_prepared.error))
		return false
	tile = _prepared.tile
	precompute = tile.get("precompute", {})
	timings["prepare_thread_ms"] = _prepared.get("ms", 0.0)
	if budget_ms > 0.0:
		# time-sliced: threaded loads, and let them finish instead of blocking the frame on them.
		# (Unsliced builds - captures, the headless precompute - load synchronously: the headless dummy
		# renderer is not safe for threaded resource loads.)
		for p: String in _prepared.paths:
			_request(p)
		while not _all_loaded(_prepared.paths):
			await get_tree().process_frame
			_frame_start_us = Time.get_ticks_usec()
	proc_root = Node3D.new()
	proc_root.name = "Procedural"
	add_child(proc_root)
	instances_root = Node3D.new()
	instances_root.name = "Instances"
	add_child(instances_root)
	# height field
	var terrain: Dictionary = tile.get("terrain", {})
	height_grid = terrain.get("heights", [])
	terrain_n = int(terrain.get("N", 52))
	terrain_step = float(terrain.get("step", 8.0 / 52.0))
	var hs: int = int(_prepared.height_size)
	height_texture = ImageTexture.create_from_image(Image.create_from_data(hs, hs, false, Image.FORMAT_RF, _prepared.height_bytes))
	# procedural parts
	var proc_scene: PackedScene = _scene(str((tile.get("proc", {}) as Dictionary).get("file", "")))
	if proc_scene == null:
		push_error("LSHU procedural tile scene missing: " + str((tile.get("proc", {}) as Dictionary).get("file", "")))
		return false
	var scene: Node = proc_scene.instantiate()
	proc_root.add_child(scene)
	for node: Node in scene.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = node as MeshInstance3D
		_assign_surfaces(mi, "", false)
		proc_nodes[str(mi.name).trim_prefix("proc_")] = mi
	timings["proc_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	await _yield_if_over(budget_ms)
	# placed assets
	var motion: Dictionary = look.call("sec", "motion")
	var index: int = 0
	for data: Dictionary in tile.get("instances", []):
		var id: String = str(data.asset_id)
		var packed: PackedScene = _scene(PROPS_DIR + id + ".glb")
		if packed == null:
			push_error("LSHU asset scene missing or not imported: " + id)
			return false
		var holder: Node3D = Node3D.new()
		holder.name = "%s_%02d" % [id, index]
		var pos: Array = data.position
		holder.position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		holder.rotation.y = float(data.get("yaw", 0.0))
		holder.scale = Vector3.ONE * float(data.get("scale", 1.0))
		instances_root.add_child(holder)
		var inst: Node3D = packed.instantiate() as Node3D
		holder.add_child(inst)
		var group: String = str(data.get("group", ""))
		var meshes: Array[MeshInstance3D] = []
		for node: Node in inst.find_children("*", "MeshInstance3D", true, false):
			var mi: MeshInstance3D = node as MeshInstance3D
			meshes.append(mi)
			_assign_surfaces(mi, group, true)
			if str(data.get("anim", "")) == "sway":
				mi.set_instance_shader_parameter("sway", float(motion.get("sway_scale", 1.0)))
				mi.set_instance_shader_parameter("sway_phase", float(data.get("phase", index * 1.7)))
				sway_nodes.append(mi)
			if str(mi.name).begins_with("rotor_") and mi.has_meta("extras"):
				var ex: Dictionary = mi.get_meta("extras")
				var part: Dictionary = (ex.get("lshu", {}) as Dictionary).get("runtime_part", {})
				var axis: Vector3 = Vector3.BACK
				var ax: Variant = part.get("axis", [0, 0, 1])
				if ax is Array and (ax as Array).size() >= 3:
					axis = Vector3(float(ax[0]), float(ax[1]), float(ax[2]))
				rotors.append({"node": mi, "axis": axis.normalized(), "speed": float(part.get("speed_rad_s", 0.2)), "base": mi.basis})
		var anim: String = str(data.get("anim", ""))
		if anim == "boat" or anim == "bob":
			bobbers.append({"node": holder, "base_y": holder.position.y, "phase": float(data.get("phase", 0.7))})
		instance_nodes.append({"node": holder, "data": data, "meshes": meshes})
		index += 1
		await _yield_if_over(budget_ms)
	timings["instances_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	if geometry_only:
		return true
	# ground maps (offline) and the module order atmos -> edges -> surface_detail -> scatter -> life:
	# atmos and surface_detail are bound at swap time; edges came with the imported meshes.
	ground_maps = GROUND_INFO.textures_from(precompute.get("ground_info", {}))
	var sd: Dictionary = look.call("module_cfg", "surface_detail")
	if bool(sd.get("hide_proc_foam", false)) and proc_nodes.has("foam"):
		(proc_nodes["foam"] as Node3D).visible = false
	var sc: Dictionary = look.call("module_cfg", "scatter")
	if bool(sc.get("hide_web_grass", true)) and proc_nodes.has("grass"):
		(proc_nodes["grass"] as Node3D).visible = false
	await _merge_static_shadows(budget_ms)   # after the hidden procedural parts are known
	timings["shadow_merge_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	scatter_root = Node3D.new()
	scatter_root.name = "Scatter"
	add_child(scatter_root)
	SCATTER.build_nodes(precompute.get("scatter", {}), scatter_root, look.call("role_material", str(sc.get("role", "scatter"))) as Material, sc)
	timings["scatter_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	await _yield_if_over(budget_ms)
	life = LIFE_SCRIPT.new() as Node3D
	add_child(life)
	life.call("build", look, tile, motion_frozen)
	fire_lights = life.get("fire_lights")
	lamp_lights = life.get("lamp_lights")
	timings["life_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	if budget_ms > 0.0:
		_end_slice()
	return true

## Draw-call rule (P0, night tiles with a shadowed camp fire: every shadow pass re-drew each static prop). The tile's static
## shadow casters - procedural parts and placed assets that never move - are appended, in tile space, into ONE
## shadows-only mesh per render layer (a plain triangle list of positions), and the originals stop casting. The role shaders
## are opaque and double-sided and only move vertices of swaying instances, so the shadow maps hold the same depth
## (shadow normal bias is applied on the receiver, so caster normals are not needed). Kept as their own casters:
## swaying / bobbing assets and rotor parts (their shadows move), every instance of the character's support asset
## (the seat fit rescales it on the swap frame), skinned meshes and non-triangle surfaces. Overlay surfaces are
## transparent and never cast, so they are left out of the merge. look.json surface.shadow_merge = false turns it off.
func _merge_static_shadows(budget_ms: float) -> void:
	var t_start: int = Time.get_ticks_usec()
	shadow_report = {"enabled": bool(look.call("cfgv", "surface", "shadow_merge", true))}
	if not bool(shadow_report.enabled):
		return
	var support_id: String = str((tile.get("character", {}) as Dictionary).get("support", ""))
	var overlay_path: String = str(look.call("cfgv", "surface", "overlay_shader", ""))
	var candidates: Array[MeshInstance3D] = []
	for role: String in proc_nodes.keys():
		candidates.append(proc_nodes[role] as MeshInstance3D)
	var kept_moving: int = 0
	var kept_support: int = 0
	for rec: Dictionary in instance_nodes:
		var data: Dictionary = rec.data
		var moving: bool = MOVING_ANIMS.has(str(data.get("anim", "")))
		var support: bool = not support_id.is_empty() and str(data.get("asset_id", "")) == support_id
		for mi: MeshInstance3D in rec.meshes:
			if moving or str(mi.name).begins_with("rotor_"):
				kept_moving += 1
			elif support:
				kept_support += 1
			else:
				candidates.append(mi)
	var proc_set: Dictionary = {}
	for pn: Variant in proc_nodes.values():
		proc_set[pn] = true
	var to_tile: Transform3D = global_transform.affine_inverse()
	var positions: Dictionary = {}     # render layers -> PackedVector3Array (triangle list, tile space)
	var merged: int = 0
	var merged_names: Array[String] = []
	var kept_other: int = 0
	var triangles: int = 0
	for mi: MeshInstance3D in candidates:
		if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON or not _visible_under_tile(mi):
			continue
		if mi.mesh == null or mi.skin != null or not _all_triangles(mi.mesh):
			kept_other += 1
			continue
		var tri_list: PackedVector3Array = positions.get(mi.layers, PackedVector3Array())
		var xf: Transform3D = to_tile * mi.global_transform
		var is_proc: bool = proc_set.has(mi)
		var read_all: bool = true
		var read: Array = []
		for i: int in mi.mesh.get_surface_count():
			var mat: Material = mi.get_surface_override_material(i)
			if mat != null and mat.has_meta("shader_path") and str(mat.get_meta("shader_path")) == overlay_path:
				read_all = false
				continue
			var src: Array = _surface_vi(mi.mesh, i, not is_proc)
			var verts: PackedVector3Array = src[0]
			var idx: PackedInt32Array = src[1]
			read.append(src)
			if not idx.is_empty():
				verts = _deindexed(verts, idx)
			tri_list.append_array(xf * verts)
			triangles += verts.size() / 3
		if is_proc and read_all:
			_faces_src[mi.get_instance_id()] = read
		positions[mi.layers] = tri_list
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		merged_names.append(str(mi.name))
		merged += 1
		await _yield_if_over(budget_ms)
	if _shadow_material == null:
		_shadow_material = StandardMaterial3D.new()
		_shadow_material.resource_name = "lshu_shadow_caster"
		_shadow_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_shadow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for layers: Variant in positions.keys():
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions[layers]
		var mesh: ArrayMesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var node: MeshInstance3D = MeshInstance3D.new()
		node.name = "StaticShadowCasters_%d" % shadow_nodes.size()
		node.mesh = mesh
		node.material_override = _shadow_material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		node.layers = int(layers)
		add_child(node)
		shadow_nodes.append(node)
		_faces_src[node.get_instance_id()] = [[positions[layers], PackedInt32Array()]]
	if budget_ms > 0.0 and not _faces_src.is_empty():
		var jobs: Dictionary = _faces_src
		var box: Dictionary = _faces_box
		_faces_task = WorkerThreadPool.add_task(func() -> void: _faces_job(jobs, box), false, "lshu tile faces")
	_faces_src = {}
	shadow_report.merge({"merged_meshes": merged, "merged": merged_names, "merged_triangles": triangles, "shadow_meshes": shadow_nodes.size(),
		"kept_moving": kept_moving, "kept_support": kept_support, "kept_other": kept_other,
		"ms": float(Time.get_ticks_usec() - t_start) / 1000.0})

## [vertices, indices (empty when not indexed)] of a mesh surface; cache: keep them for the next tile (placed assets'
## meshes are shared by every tile that places the asset; procedural parts are not cached).
static func _surface_vi(mesh: Mesh, surface: int, cache: bool) -> Array:
	if cache and _surface_cache.has(mesh):
		var per: Array = _surface_cache[mesh]
		if surface < per.size() and per[surface] != null:
			return per[surface]
	var src: Array = mesh.surface_get_arrays(surface)
	var idx: Variant = src[Mesh.ARRAY_INDEX]
	var out: Array = [src[Mesh.ARRAY_VERTEX] as PackedVector3Array, (idx as PackedInt32Array) if idx != null else PackedInt32Array()]
	if cache:
		var per2: Array = _surface_cache.get(mesh, [])
		if per2.size() < mesh.get_surface_count():
			per2.resize(mesh.get_surface_count())
		per2[surface] = out
		_surface_cache[mesh] = per2
	return out

## Worker thread (pure data): per mesh, its triangle list as Mesh.get_faces() builds it (every triangle surface's
## vertices in index order, surfaces concatenated), made into a TriangleMesh and read back - exactly get_faces().
static func _faces_job(jobs: Dictionary, box: Dictionary) -> void:
	var out: Dictionary = {}
	for id: Variant in jobs.keys():
		var raw: PackedVector3Array = PackedVector3Array()
		for sv: Variant in jobs[id] as Array:
			var verts: PackedVector3Array = (sv as Array)[0]
			var idx: PackedInt32Array = (sv as Array)[1]
			if idx.is_empty():
				raw.append_array(verts)
			else:
				for k: int in idx:
					raw.append(verts[k])
		var tm: TriangleMesh = TriangleMesh.new()
		if not raw.is_empty() and tm.create_from_faces(raw):
			out[id] = tm.get_faces()
	box["faces"] = out

## True when no collision-triangle job is running for this tile.
func faces_ready() -> bool:
	return _faces_task < 0 or WorkerThreadPool.is_task_completed(_faces_task)

## The collision triangles of one of this tile's own meshes (= mesh.get_faces()), when the worker made them; else
## null (the caller reads the mesh).
func faces_for(mi: MeshInstance3D) -> Variant:
	if _faces_task >= 0 and WorkerThreadPool.is_task_completed(_faces_task):
		WorkerThreadPool.wait_for_task_completion(_faces_task)
		_faces_task = -1
		_faces = _faces_box.get("faces", {})
	if mi == null or not _faces.has(mi.get_instance_id()):
		return null
	return _faces[mi.get_instance_id()]

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _faces_task >= 0:
			WorkerThreadPool.wait_for_task_completion(_faces_task)
			_faces_task = -1
		# freed while the tile read was still running (the title's act closed mid-switch): claim the task
		if _task_id >= 0 and not _task_claimed:
			WorkerThreadPool.wait_for_task_completion(_task_id)
			_task_claimed = true

## Triangle list of an indexed surface (native: SurfaceTool.deindex keeps the index order). The merged mesh is built
## from plain triangle lists on purpose: SurfaceTool.append_from over mixed indexed / unindexed parts committed index
## data that left triangles out of the shadow maps (measured on a showcase tile: its landmark lost its shadow).
## With triangle lists the merged tile renders pixel-identical to the unmerged one (repair_r1 report).
static func _deindexed(verts: PackedVector3Array, idx: PackedInt32Array) -> PackedVector3Array:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var piece: ArrayMesh = ArrayMesh.new()
	piece.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var st: SurfaceTool = SurfaceTool.new()
	st.create_from(piece, 0)
	st.deindex()
	return st.commit_to_arrays()[Mesh.ARRAY_VERTEX]

## Visible flags from mi up to (not including) this tile node: the tile itself is built hidden.
func _visible_under_tile(mi: Node3D) -> bool:
	var n: Node = mi
	while n != null and n != self:
		if n is Node3D and not (n as Node3D).visible:
			return false
		n = n.get_parent()
	return n == self

static func _all_triangles(mesh: Mesh) -> bool:
	for i: int in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(i) != Mesh.PRIMITIVE_TRIANGLES:
			return false
	return true

func _assign_surfaces(mi: MeshInstance3D, group: String, is_asset: bool) -> void:
	var no_shadow: Array = look.call("cfgv", "surface", "no_shadow_roles", ["water", "foam", "ripple"])
	var casts: bool = true
	for i: int in mi.mesh.get_surface_count():
		var src: Material = mi.mesh.surface_get_material(i)
		var sname: String = src.resource_name if src != null else "lshu_matte"
		var base_role: String = sname.trim_prefix("lshu_") if sname.begins_with("lshu_") else "matte"
		var role: String = str(look.call("asset_role", base_role, group)) if is_asset else base_role
		mi.set_surface_override_material(i, look.call("role_material", role) as Material)
		roles_used[role] = true
		if no_shadow.has(role) and mi.mesh.get_surface_count() == 1:
			casts = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# ------------------------------------------------------------------ phase 3: swap frame
## Tile bounds for the camera rule: plinth + ground, every instance mesh, every procedural part, and L叔.
func compute_bounds(character_body: MeshInstance3D, posed: Mesh) -> AABB:
	var t: Dictionary = tile.get("tile", {})
	var yr: Array = t.get("ground_y_range", [0.0, 1.0])
	var bottom: float = float(t.get("plinth_bottom_y", -0.83))
	tile_bounds = AABB(Vector3(-4.0, bottom, -4.0), Vector3(8.0, float(yr[1]) - bottom, 8.0))
	for rec: Dictionary in instance_nodes:
		for mi: MeshInstance3D in rec.meshes:
			tile_bounds = tile_bounds.merge(mi.global_transform * mi.get_aabb())
	for role: String in proc_nodes.keys():
		var pm: MeshInstance3D = proc_nodes[role]
		tile_bounds = tile_bounds.merge(pm.global_transform * pm.get_aabb())
	if character_body != null and posed != null:
		tile_bounds = tile_bounds.merge(character_body.global_transform * posed.get_aabb())
	return tile_bounds

## Per-tile inputs on the shared role materials (height field, ground maps, water level). Swap frame only.
func bind() -> void:
	surface_report = SURFACE_DETAIL.bind_tile(look, self)

func terrain_height(x: float, z: float) -> float:
	return GROUND_INFO.height_at(height_grid, terrain_n, terrain_step, x, z)

# ------------------------------------------------------------------ motion
func tick(t: float, motion_frozen: bool) -> void:
	var motion: Dictionary = look.call("sec", "motion")
	if bool(motion.get("rotor", true)):
		for r: Dictionary in rotors:
			(r.node as Node3D).basis = (r.base as Basis) * Basis(r.axis, t * float(r.speed))
	var bob: float = float(motion.get("boat_bob", 0.016))
	for b: Dictionary in bobbers:
		var n: Node3D = b.node
		n.position.y = float(b.base_y) + sin(t * 1.0 + float(b.phase)) * bob
		n.rotation.z = sin(t * 0.78 + float(b.phase)) * bob * 1.25
	if life != null:
		life.call("tick", t, motion_frozen)

# ------------------------------------------------------------------ evidence
func evidence() -> Dictionary:
	var inst_records: Array = []
	for rec: Dictionary in instance_nodes:
		var d: Dictionary = rec.data
		inst_records.append({"asset_id": d.asset_id, "role": d.get("role"), "group": d.get("group"), "anim": d.get("anim")})
	var all_meshes: Array[MeshInstance3D] = []
	for rec2: Dictionary in instance_nodes:
		for mi: MeshInstance3D in rec2.meshes:
			all_meshes.append(mi)
	var edge_cfg: Dictionary = look.call("module_cfg", "edges")
	for r: Variant in edge_cfg.get("proc_roles", []):
		if proc_nodes.has(str(r)):
			all_meshes.append(proc_nodes[str(r)] as MeshInstance3D)
	var scatter_rec: Dictionary = precompute.get("scatter", {})
	return {"roles": roles_used.keys(), "proc_roles": proc_nodes.keys(), "instances": inst_records,
		"fires": fire_lights.size(), "lamps": lamp_lights.size(), "rotors": rotors.size(),
		"edges": EDGES.report(all_meshes), "surface_detail": surface_report, "shadow_merge": shadow_report,
		"scatter": {"counts": scatter_rec.get("counts", {}), "total": scatter_rec.get("total", 0), "source": "offline (tile JSON precompute.scatter)"},
		"life": life.get("report") if life != null else {}, "build_timings_ms": timings}
