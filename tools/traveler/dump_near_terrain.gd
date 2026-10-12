extends SceneTree
func _initialize() -> void:call_deferred("dump")
func dump() -> void:
	var viewport := SubViewport.new()
	viewport.size=Vector2i(1920,1080);viewport.own_world_3d=true;root.add_child(viewport)
	var traveler: Node3D=load("res://scenes/traveler/traveler_main.tscn").instantiate();viewport.add_child(traveler)
	var meshes: Array=[]
	for tile in traveler.world.get_node("Terrain64").get_children():
		if not str(tile.name).left(3) in ["T25","T37","T45","T47","T48","T49"]:continue
		for node in tile.find_children("*","MeshInstance3D",true,false):
			for si in node.mesh.get_surface_count():
				var a: Array=node.mesh.surface_get_arrays(si)
				var v: PackedVector3Array=a[Mesh.ARRAY_VERTEX]
				var n: PackedVector3Array=a[Mesh.ARRAY_NORMAL]
				var c: PackedColorArray=a[Mesh.ARRAY_COLOR]
				var vertices: Array=[];var normals: Array=[];var colors: Array=[]
				for p in v:
					p=node.global_transform*p;vertices.append([p.x,p.y,p.z])
				for p in n:normals.append([p.x,p.y,p.z])
				for p in c:colors.append([p.r,p.g,p.b,p.a])
				meshes.append({"tile":str(tile.name),"node":str(node.get_path()),"vertices":vertices,"normals":normals,"colors":colors,"indices":Array(a[Mesh.ARRAY_INDEX]) if a[Mesh.ARRAY_INDEX]!=null else [],"surface":si})
	var t: Transform3D=traveler.camera.global_transform
	var report := {"meshes":meshes,"camera_transform":[[t.basis.x.x,t.basis.x.y,t.basis.x.z],[t.basis.y.x,t.basis.y.y,t.basis.y.z],[t.basis.z.x,t.basis.z.y,t.basis.z.z],[t.origin.x,t.origin.y,t.origin.z]],"fov":traveler.camera.fov}
	var f:=FileAccess.open("res://docs/reports/traveler-near-mountain-001/evidence/source-terrain.json",FileAccess.WRITE);f.store_string(JSON.stringify(report));f.close()
	traveler.set_process(false);traveler.world.queue_free();await process_frame;quit()
