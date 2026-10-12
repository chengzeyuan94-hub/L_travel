extends SceneTree
func _initialize() -> void:
	call_deferred("capture")
func capture() -> void:
	var review=load("res://tools/traveler/character_preview.tscn").instantiate()
	root.add_child(review)
	while not review.review_ready:
		await process_frame
	await create_timer(1.0).timeout
	review.host.motion_director.set_motion_enabled(false)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var baseline:PackedByteArray=review.viewport.get_texture().get_image().get_data()
	var changed:=0
	for i in 60:
		await RenderingServer.frame_post_draw
		if review.viewport.get_texture().get_image().get_data()!=baseline:changed+=1
	var cc=review.host.character_controller
	review.checks["readability"]={"freeze_frames":60,"changed_frames":changed,"lantern_range":cc.lamp.omni_range,"lantern_energy":cc.lamp.light_energy,"fill_energy":cc.dusk_fill.light_energy,"rim_energy":cc.dusk_rim.light_energy,"fill_cull_mask":cc.dusk_fill.light_cull_mask,"cloud_count":review.host.world.get_node("FarBackdrop").get_meta("far_cloud_report").size()}
	await review._capture_review("dusk" if review.host.look_dusk else "day")
	quit()
