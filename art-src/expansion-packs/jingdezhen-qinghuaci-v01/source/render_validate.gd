extends SceneTree
# Standalone render harness. Run only in a separate temporary Godot project.
var out = "/tmp/jingdezhen-qinghuaci-v01"
var vp: SubViewport
var world: Node3D
var camera: Camera3D
var model: Node3D
var report: Array = []
func _initialize():
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pack="): out = a.trim_prefix("--pack=")
	call_deferred("run")
func meshes(n: Node) -> Array:
	var a: Array = []
	if n is MeshInstance3D: a.append(n)
	for c in n.get_children(): a.append_array(meshes(c))
	return a
func run():
	vp = SubViewport.new()
	vp.size = Vector2i(1200,1200)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(vp)
	world = Node3D.new(); vp.add_child(world)
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("ece8dd")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("cddce4")
	env.ambient_light_energy = .48
	var we = WorldEnvironment.new();we.environment=env;world.add_child(we)
	var sun = DirectionalLight3D.new(); sun.light_color=Color("ffe8c7");sun.light_energy=.82
	sun.shadow_enabled=true;world.add_child(sun);sun.rotation_degrees=Vector3(-50,-32,0)
	var fill = DirectionalLight3D.new();fill.light_color=Color("d8e7ff");fill.light_energy=.18
	world.add_child(fill);fill.rotation_degrees=Vector3(-20,130,0)
	camera=Camera3D.new();world.add_child(camera);camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.current=true
	for asset in ["jingdezhen", "qinghuaci-icon-source"]:
		var doc=GLTFDocument.new();var state=GLTFState.new()
		var error=doc.append_from_file(out+"/models/"+asset+".glb",state)
		if error!=OK:
			push_error("GLTF import failed "+asset);quit(1);return
		model=doc.generate_scene(state);world.add_child(model)
		var first=true;var box=AABB();var count=0;var surfaces=0;var missing_vc=0;var materials=0
		for mi in meshes(model):
			var b=mi.global_transform*mi.mesh.get_aabb();box=b if first else box.merge(b);first=false;count+=1
			for si in mi.mesh.get_surface_count():
				surfaces+=1
				var arrays=mi.mesh.surface_get_arrays(si)
				if arrays[Mesh.ARRAY_COLOR].is_empty():missing_vc+=1
				var mat=mi.mesh.surface_get_material(si)
				if mat!=null:materials+=1
		var row={"asset":asset,"gltf_import_error":error,"mesh_instances":count,"surfaces":surfaces,"materials":materials,"surfaces_without_vertex_colors":missing_vc,"aabb_position":[box.position.x,box.position.y,box.position.z],"aabb_size":[box.size.x,box.size.y,box.size.z],"views":[]}
		# Editable native Godot scene assembled from imported geometry.
		own_children(model,model)
		var ps=PackedScene.new();var packed=ps.pack(model)
		row["scene_pack_error"]=packed
		row["scene_save_error"]=ResourceSaver.save(ps,out+"/source/"+asset+".tscn")
		var centre=box.get_center()
		camera.size=5.1 if asset=="jingdezhen" else 1.38
		var views={"three-quarter":Vector3(1.15,1.05,1.65),"front":Vector3(0,.65,2),"back":Vector3(-1,1,-1.5)} if asset=="jingdezhen" else {"icon":Vector3(.35,.23,2)}
		vp.transparent_bg = asset!="jingdezhen"
		vp.size=Vector2i(1200,1200) if asset=="jingdezhen" else Vector2i(1024,1024)
		for key in views:
			camera.position=centre+views[key].normalized()*20;camera.look_at(centre,Vector3.UP)
			for i in 12:await process_frame
			await RenderingServer.frame_post_draw
			var img=vp.get_texture().get_image()
			var file=out+"/previews/jingdezhen-"+key+".png" if asset=="jingdezhen" else out+"/icons/qinghuaci.png"
			row.views.append({"path":file,"save_error":img.save_png(file)})
			if asset!="jingdezhen":
				for size in [256,128]:
					var small=img.duplicate();small.resize(size,size,Image.INTERPOLATE_LANCZOS)
					small.save_png(out+"/icons/qinghuaci-"+str(size)+".png")
				var occupied=0;var transparent=0;var partial=0
				var extent=Rect2i();var init=false
				for y in img.get_height():
					for x in img.get_width():
						var a=img.get_pixel(x,y).a
						if a==0:transparent+=1
						else:
							occupied+=1
							if a<1:partial+=1
							if not init:extent=Rect2i(x,y,1,1);init=true
							else:extent=extent.expand(Vector2i(x,y))
				row["alpha"]={"transparent_pixels":transparent,"occupied_pixels":occupied,"partial_pixels":partial,"extent":[extent.position.x,extent.position.y,extent.size.x,extent.size.y]}
				# Checkerboard proof; no raster manipulation tools needed.
				var checker=Image.create(1024,1024,false,Image.FORMAT_RGBA8)
				for y in 1024:
					for x in 1024:checker.set_pixel(x,y,Color("d8d9d6") if (int(x/48)+int(y/48))%2==0 else Color("f3f1eb"))
				checker.blend_rect(img,Rect2i(0,0,1024,1024),Vector2i.ZERO)
				checker.save_png(out+"/previews/qinghuaci-checkerboard.png")
		report.append(row);world.remove_child(model);model.queue_free()
	var f=FileAccess.open(out+"/validation/godot-render.json",FileAccess.WRITE);f.store_string(JSON.stringify({"engine":Engine.get_version_info(),"renderer":RenderingServer.get_video_adapter_name(),"assets":report},"  "))
	print("ASSET_QA_COMPLETE ",out);quit()
func own_children(n:Node,top:Node):
	for c in n.get_children():c.owner=top;own_children(c,top)
