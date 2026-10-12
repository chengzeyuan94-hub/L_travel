extends SceneTree

func _initialize() -> void:
	call_deferred("verify")

func verify() -> void:
	var viewport := SubViewport.new()
	viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true
	root.add_child(viewport)
	var traveler: Node3D=load("res://scenes/traveler/traveler_main.tscn").instantiate()
	viewport.add_child(traveler)
	var nodes: Array=traveler.world.find_children("MassifBand*","MeshInstance3D",true,false)
	var model: MeshInstance3D=nodes[0]
	var baseline: Color=model.material_override.albedo_color.srgb_to_linear()
	traveler.set_night(true)
	var dimmed: Color=model.material_override.albedo_color.srgb_to_linear()
	traveler.set_night(false)
	var restored: Color=model.material_override.albedo_color.srgb_to_linear()
	var camera: Camera3D=traveler.camera
	var inverse := camera.global_transform.affine_inverse()
	var sy := tan(deg_to_rad(camera.fov)*0.5)
	var sx := sy*1920.0/1080.0
	var outside := 0
	var top_pixel := 1080.0
	var positions: PackedVector3Array=model.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for point in positions:
		var p := inverse*(model.global_transform*point)
		var depth := -p.z
		top_pixel=minf(top_pixel,(1.0-p.y/(depth*sy))*540.0)
		if absf(p.x)>depth*sx+0.0001 or absf(p.y)>depth*sy+0.0001 or depth<camera.near-0.0001 or depth>camera.far+0.0001:outside+=1
	var report := {"top_pixel":top_pixel,"top_fraction":top_pixel/1080.0,"scene_lit":model.material_override.shading_mode==BaseMaterial3D.SHADING_MODE_PER_PIXEL,"emission":model.material_override.emission_enabled,"sun_affects_mountain":(traveler.sun.light_cull_mask & model.layers)!=0,"dedicated_lights":traveler.world.get_node("FarBackdrop").find_children("*","Light3D",true,false).size(),"models":nodes.size(),"surfaces":model.mesh.get_surface_count(),"triangles":positions.size()/3,"outside_vertices":outside,"coordinate_tolerance_world":0.0001,"day_multiplier":[baseline.r,baseline.g,baseline.b],"night_button_multiplier":[dimmed.r,dimmed.g,dimmed.b],"toggle_restores_day":baseline.is_equal_approx(restored)}
	report["pass"]=nodes.size()==1 and model.mesh.get_surface_count()==1 and outside==0 and baseline.is_equal_approx(Color.WHITE) and dimmed.is_equal_approx(Color.WHITE) and report.scene_lit and not report.emission and report.sun_affects_mountain and report.dedicated_lights==0 and baseline.is_equal_approx(restored)
	var file := FileAccess.open("res://docs/design/shanhe-luren/mountain-rework/skyline-height/runtime-verification.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	print("FRAMED_MOUNTAIN_VERIFY ",JSON.stringify(report))
	traveler.set_process(false)
	traveler.world.queue_free()
	await process_frame
	quit(0 if report["pass"] else 1)
