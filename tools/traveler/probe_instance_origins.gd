extends SceneTree
## S1b: render the actual Atlas MultiMeshes with the required origin diagnostic.
func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.use_taa = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var viewer: Node3D = load("res://scenes/traveler/traveler_main.tscn").instantiate()
	viewport.add_child(viewer)
	viewer.ui.visible = false
	viewer.set_process(false)
	viewer.camera.make_current()
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
varying flat vec3 origin_color;
void vertex() {
 vec3 o = MODEL_MATRIX[3].xyz;
 origin_color = vec3(fract(o.x*0.37), fract(o.z*0.41), 0.5);
}
void fragment() { ALBEDO = origin_color; }
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	var batches: Array = []
	for node in viewer.world.get_node("VegetationHigh").get_children():
		if not node is MultiMeshInstance3D: continue
		node.material_override = material
		var projected: Array = []
		for index in node.multimesh.instance_count:
			var transform: Transform3D = node.global_transform * node.multimesh.get_instance_transform(index)
			var origin: Vector3 = transform.origin
			var point: Vector3 = transform * Vector3(0, 1.2, 0)
			if viewer.camera.is_position_behind(point): continue
			var screen: Vector2 = viewer.camera.unproject_position(point)
			if Rect2(0,0,1920,1080).has_point(screen):
				projected.append({"instance":index,"origin":[origin.x,origin.y,origin.z],"screen":[screen.x,screen.y],"shader_color":[fposmod(origin.x*0.37,1.0),fposmod(origin.z*0.41,1.0),0.5]})
		if not projected.is_empty(): batches.append({"node":str(node.name),"instances":projected})
	for frame in 24: await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var prefix := "res://docs/reports/traveler-motion-001/S1b-instance-origin"
	var error := image.save_png(prefix+".png")
	var report := {"capture_error":error,"image_size":[image.get_width(),image.get_height()],"viewport_size":[viewport.size.x,viewport.size.y],"frozen_camera":viewer.motion_params._measured.traveler_camera,"projected_batches":batches,"probe_shader":shader.code}
	var file := FileAccess.open(prefix+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("INSTANCE_ORIGIN_PROBE ",JSON.stringify({"capture_error":error,"batches_with_visible_origins":batches.size()}))
	viewer.queue_free()
	await process_frame
	await process_frame
	quit(error)
