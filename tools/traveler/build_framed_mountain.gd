extends SceneTree
## Rebuild the selected source, clip it to the frozen camera, store one mesh.
var output_positions := PackedVector3Array()
var output_normals := PackedVector3Array()
var output_colors := PackedColorArray()

func _initialize() -> void:
	call_deferred("build")

func clip_polygon(polygon: Array[Vector3], plane: Vector4) -> Array[Vector3]:
	var clipped: Array[Vector3]=[]
	if polygon.is_empty():return clipped
	var previous := polygon[-1]
	var previous_d := Vector3(plane.x,plane.y,plane.z).dot(previous)+plane.w
	for point in polygon:
		var distance := Vector3(plane.x,plane.y,plane.z).dot(point)+plane.w
		if (distance>=0)!=(previous_d>=0):
			clipped.append(previous.lerp(point,previous_d/(previous_d-distance)))
		if distance>=0:clipped.append(point)
		previous=point
		previous_d=distance
	return clipped

func build() -> void:
	if not OS.get_cmdline_user_args().has("--mountain-source"):
		push_error("Builder requires --mountain-source to rebuild full selected geometry")
		quit(1);return
	var viewport := SubViewport.new()
	viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true
	root.add_child(viewport)
	var traveler: Node3D=load("res://scenes/traveler/traveler_main.tscn").instantiate()
	viewport.add_child(traveler)
	traveler.ui.visible=false
	var camera: Camera3D=traveler.camera
	var world_to_camera := camera.global_transform.affine_inverse()
	var camera_to_world := camera.global_transform
	var slope_y := tan(deg_to_rad(camera.fov)*0.5)
	var slope_x := slope_y*1920.0/1080.0
	var planes: Array[Vector4]=[Vector4(1,0,-slope_x,0),Vector4(-1,0,-slope_x,0),Vector4(0,1,-slope_y,0),Vector4(0,-1,-slope_y,0),Vector4(0,0,-1,-camera.near),Vector4(0,0,1,camera.far)]
	var cfg: Dictionary=traveler.look_profile.mountain_params.framed_asset
	var height_scale := float(cfg.get("height_scale",1.0))
	var width_scale := float(cfg.get("peak_width_scale",1.0))
	var spacing_scale := float(cfg.get("peak_spacing_scale",1.0))
	var band_offsets: Array=cfg.get("band_horizontal_offsets",[0.0,0.0,0.0])
	var horizontal := Vector3(camera.global_basis.x.x,0,camera.global_basis.x.z).normalized()
	var source_faces := 0
	var rejected_backfaces := 0
	var rejected_outside := 0
	var contributing_faces := 0
	var clipped_faces := 0
	for node in traveler.world.find_children("MassifBand*","MeshInstance3D",true,false):
		var band_index := int(str(node.name).trim_prefix("MassifBand"))
		var bodies: Array=node.get_meta("massif_bodies")
		var faces: Array=node.get_meta("massif_faces")
		var peak_origins: Dictionary={}
		for body in bodies:
			if body.main:peak_origins[int(body.peak_id)]=Vector3(body.origin[0],body.origin[1],body.origin[2])
		for surface in node.mesh.get_surface_count():
			var arrays: Array=node.mesh.surface_get_arrays(surface)
			var positions: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
			var colors: PackedColorArray=arrays[Mesh.ARRAY_COLOR]
			var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
			if indices.is_empty():
				for i in positions.size():indices.append(i)
			for index in range(0,indices.size(),3):
				source_faces+=1
				var triangle: Array[Vector3]=[]
				var body: Dictionary=bodies[int(faces[index/3].body)]
				var origin: Vector3=peak_origins[int(body.peak_id)]
				var spread := horizontal*horizontal.dot(origin-traveler.target)*(spacing_scale-1.0)+horizontal*float(band_offsets[band_index])
				for k in 3:
					var point: Vector3=node.global_transform*positions[indices[index+k]]
					point=origin+(point-origin)*Vector3(width_scale,height_scale,width_scale)+spread
					triangle.append(point)
				var normal: Vector3=(node.global_basis.inverse().transposed()*normals[indices[index]]).normalized()
				normal=(normal/Vector3(width_scale,height_scale,width_scale)).normalized()
				if normal.dot(camera.global_position-(triangle[0]+triangle[1]+triangle[2])/3.0)<=0:
					rejected_backfaces+=1;continue
				var polygon: Array[Vector3]=[]
				for point in triangle:polygon.append(world_to_camera*point)
				var original := polygon.duplicate()
				for plane in planes:polygon=clip_polygon(polygon,plane)
				if polygon.size()<3:
					rejected_outside+=1;continue
				contributing_faces+=1
				if polygon!=original:clipped_faces+=1
				for k in range(1,polygon.size()-1):
					var a := camera_to_world*polygon[0]
					var b := camera_to_world*polygon[k]
					var c := camera_to_world*polygon[k+1]
					if (b-a).cross(c-a).length_squared()<1e-14:continue
					for point in [a,b,c]:
						output_positions.append(point)
						output_normals.append(normal)
						output_colors.append(colors[indices[index]])
	var result_arrays: Array=[]
	result_arrays.resize(Mesh.ARRAY_MAX)
	result_arrays[Mesh.ARRAY_VERTEX]=output_positions
	result_arrays[Mesh.ARRAY_NORMAL]=output_normals
	result_arrays[Mesh.ARRAY_COLOR]=output_colors
	var result := ArrayMesh.new()
	result.resource_name="Changan Framed Massif"
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,result_arrays)
	var error := ResourceSaver.save(result,str(cfg.path))
	var report := {"band_horizontal_offsets":band_offsets,"height_scale":height_scale,"peak_width_scale":width_scale,"peak_spacing_scale":spacing_scale,"lighting":"scene_sun_and_environment","source_triangles":source_faces,"rejected_backfaces":rejected_backfaces,"rejected_outside":rejected_outside,"contributing_source_faces":contributing_faces,"clipped_source_faces":clipped_faces,"triangles":output_positions.size()/3,"models":1,"surfaces":1,"asset":cfg.path,"camera_position":[camera.global_position.x,camera.global_position.y,camera.global_position.z],"camera_fov":camera.fov,"aspect":1920.0/1080.0,"image_size":[1920,1080],"viewport_size":[1920,1080],"policy":"Transform full source before camera frustum clipping and backface removal; retain overlapping front faces to preserve silhouette, depth and fog. Fixed-camera background asset, not a freely orbitable mountain.","save_error":error}
	var file := FileAccess.open(str(cfg.report),FileAccess.WRITE)
	if file==null:push_error("Cannot write framed mountain report");quit(1);return
	file.store_string(JSON.stringify(report,"\t"));file.close()
	print("FRAMED_MOUNTAIN_BUILD ",JSON.stringify(report))
	traveler.set_process(false)
	traveler.world.queue_free()
	await process_frame
	quit(error)
