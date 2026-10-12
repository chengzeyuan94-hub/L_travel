extends RefCounted
## Measurement only: welding never modifies the rendered ArrayMesh.
static func dump(world: Node3D, camera: Camera3D, path: String, frozen: Dictionary) -> void:
	if world.has_node("FarBackdrop") and world.get_node("FarBackdrop").has_meta("mountain_asset_report"):
		_dump_assets(world,camera,path,frozen)
		return
	var bands: Array = []
	for node in world.find_children("MassifBand*","MeshInstance3D",true,false):
		var vertices: Array = []
		var indices: Array = []
		var normals: Array = []
		var colors: Array = []
		var lookup := {}
		for surface in node.mesh.get_surface_count():
			var arrays: Array = node.mesh.surface_get_arrays(surface)
			var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var ns: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var cs: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
			var source_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
			if source_indices.is_empty():
				for i in positions.size():source_indices.append(i)
			for i in source_indices.size():
				var source: int = source_indices[i]
				var p: Vector3 = node.global_transform*positions[source]
				var key := "%d,%d,%d" % [roundi(p.x*100000),roundi(p.y*100000),roundi(p.z*100000)]
				if not lookup.has(key):lookup[key]=vertices.size();vertices.append([p.x,p.y,p.z])
				indices.append(lookup[key])
				if i%3==0:
					var n: Vector3 = (node.global_basis*ns[source]).normalized()
					normals.append([n.x,n.y,n.z]);colors.append([cs[source].r,cs[source].g,cs[source].b])
		var faces: Array = node.get_meta("massif_faces",[])
		var face_material: Array = []
		var body_ids: Array = []
		for face in faces:face_material.append(face.material);body_ids.append(face.body)
		var material: BaseMaterial3D=node.material_override
		var material_report := {"class":material.get_class(),"unshaded":material.shading_mode==BaseMaterial3D.SHADING_MODE_UNSHADED,
			"cull_back":material.cull_mode==BaseMaterial3D.CULL_BACK,"fog_enabled":not material.disable_fog,
			"vertex_color_as_albedo":material.vertex_color_use_as_albedo,"vertex_color_is_srgb":material.vertex_color_is_srgb}
		bands.append({"band_index":bands.size(),"vertices":vertices,"indices":indices,"normals":normals,"material":material_report,
			"colors":colors,"face_material":face_material,"body_ids":body_ids,"bodies":node.get_meta("massif_bodies",[]),
			"surface_count":node.mesh.get_surface_count(),"render_array_sha256":var_to_bytes(node.mesh.surface_get_arrays(0)).hex_encode().sha256_text()})
	var transform: Array = []
	for axis in [camera.global_basis.x,camera.global_basis.y,camera.global_basis.z,camera.global_position]:
		transform.append([axis.x,axis.y,axis.z])
	var result := {"schema":"silkroad.massif-mesh.v1","weld_tolerance":0.00001,"attribute_domain":"normals/colors/face_material/body_ids are per-face; indices reference welded world-space vertices",
		"camera_transform":transform,"frozen_camera":frozen,"camera_fov":camera.fov,"image_size":[1920,1080],"bands":bands}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:push_error("Cannot write massif dump: "+path);return
	file.store_string(JSON.stringify(result));file.close()
	print("MASSIF_DUMP ",path," bands=",bands.size())

static func set_view(world: Node3D, environment: Environment, only: bool, hidden: bool, silhouette: bool) -> void:
	for node in world.find_children("*","GeometryInstance3D",true,false):
		var is_mountain: bool=String(node.name).begins_with("MassifBand") or bool(node.get_meta("mountain_geometry",false))
		if only:node.visible=is_mountain
		elif hidden and is_mountain:node.visible=false
		if silhouette and is_mountain:
			var mat := StandardMaterial3D.new()
			mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color=Color.BLACK
			mat.disable_fog=true
			node.material_override=mat
	if only:
		environment.background_mode=Environment.BG_COLOR
		environment.background_color=Color.WHITE if silhouette else Color(0.6,0.6,0.6)

static func _dump_assets(world: Node3D, camera: Camera3D, path: String, frozen: Dictionary) -> void:
	var bands: Array=[]
	for index in 3:
		bands.append({"band_index":index,"vertices":[],"indices":[],"normals":[],"colors":[],"face_material":[],"body_ids":[],"bodies":[],"surface_count":0,"source_surfaces":[],"material":{"unshaded":false,"vertex_color_is_srgb":true},"lookup":{}})
	for node in world.find_children("*","MeshInstance3D",true,false):
		if not node.has_meta("mountain_instance"):continue
		var info: Dictionary=node.get_meta("mountain_instance")
		var band: Dictionary=bands[int(info.band)]
		var body_id: int=band.bodies.size()
		band.bodies.append({"origin":info.position,"height":info.height,"main":true,"peak_id":int(info.index),"scale":info.scale,"yaw":info.yaw,"source_spec":info.source_spec})
		var normal_basis: Basis=node.global_basis.inverse().transposed()
		for surface in node.mesh.get_surface_count():
			var arrays: Array=node.mesh.surface_get_arrays(surface)
			var positions: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
			var source_indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
			var material: BaseMaterial3D=node.get_active_material(surface)
			var label := "snow" if material.resource_name.contains("Snow") else "rock"
			band.source_surfaces.append({"instance":int(info.index),"name":material.resource_name,"resource_id":material.get_instance_id(),"has_vertex_colors":arrays[Mesh.ARRAY_COLOR]!=null,"layer_mask":node.layers,"override":node.material_override!=null})
			band.surface_count+=1
			for i in source_indices.size():
				var source: int=source_indices[i]
				var p: Vector3=node.global_transform*positions[source]
				var key := "%d:%d,%d,%d"%[body_id,roundi(p.x*100000),roundi(p.y*100000),roundi(p.z*100000)]
				if not band.lookup.has(key):band.lookup[key]=band.vertices.size();band.vertices.append([p.x,p.y,p.z])
				band.indices.append(band.lookup[key])
				if i%3==0:
					var n: Vector3=(normal_basis*normals[source]).normalized()
					band.normals.append([n.x,n.y,n.z])
					band.colors.append([material.albedo_color.r,material.albedo_color.g,material.albedo_color.b])
					band.face_material.append(label)
					band.body_ids.append(body_id)
	for band in bands:band.erase("lookup")
	var transform: Array=[]
	for axis in [camera.global_basis.x,camera.global_basis.y,camera.global_basis.z,camera.global_position]:transform.append([axis.x,axis.y,axis.z])
	var far_root := world.get_node("FarBackdrop")
	var result := {"schema":"silkroad.massif-mesh.v2","source":"authorized GLB instances; no runtime mesh/color conversion","weld_tolerance":0.00001,"camera_transform":transform,"frozen_camera":frozen,"camera_fov":camera.fov,"image_size":[1920,1080],"bands":bands,"placement":far_root.get_meta("mountain_asset_report"),"clouds":far_root.get_meta("far_cloud_report",[])}
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:push_error("Cannot write asset audit: "+path);return
	file.store_string(JSON.stringify(result));file.close()
	print("MASSIF_ASSET_DUMP ",path)
