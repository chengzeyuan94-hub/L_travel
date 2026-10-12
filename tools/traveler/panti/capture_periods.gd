extends SceneTree
## Same-process, same motion phase lighting comparisons with explicit output.
var viewport:SubViewport
var viewer:Node3D
var output:=""

func _initialize() -> void:call_deferred("run")

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--period-output="):output=arg.trim_prefix("--period-output=")
	if output.is_empty() or not output.is_absolute_path() or DirAccess.dir_exists_absolute(output):
		push_error("Provide --period-output=<new absolute directory>");quit(1);return
	DirAccess.make_dir_recursive_absolute(output)
	viewport=SubViewport.new();viewport.size=Vector2i(1920,1080)
	viewport.own_world_3d=true;viewport.msaa_3d=Viewport.MSAA_4X
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(viewport)
	var preview:=TextureRect.new();preview.texture=viewport.get_texture()
	preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview);preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewer=load("res://scenes/traveler/panti_main.tscn").instantiate();viewport.add_child(viewer)
	while viewer.period_lighting==null:await process_frame
	for i in 120:
		await process_frame;await RenderingServer.frame_post_draw
	viewer.set_motion_frozen(true)
	var frozen_time:float=viewer.weather.anim_t
	viewer.set_lighting_period("morning")
	await viewer.capture(output+"/morning.png")
	var morning:PackedByteArray=viewport.get_texture().get_image().get_data()
	viewer.set_lighting_period("midnight")
	await viewer.capture(output+"/midnight.png")
	var night_sky:RefCounted=viewer.look_profile.night_sky
	if night_sky==null or not night_sky.configured:
		push_error("Midnight sky did not configure");quit(1);return
	var night_sky_evidence:Dictionary=night_sky.evidence()
	# Settle the final GPU readback after capture's mesh/evidence queries.
	for i in 5:
		await process_frame;await RenderingServer.frame_post_draw
	var reference:PackedByteArray=viewport.get_texture().get_image().get_data()
	var equal_pairs:=0
	for i in 30:
		await process_frame;await RenderingServer.frame_post_draw
		var frozen_image:=viewport.get_texture().get_image()
		if frozen_image.get_data()==reference:equal_pairs+=1
		else:frozen_image.save_png(output+"/freeze-difference-%02d.png"%i)
	# Isolate the overlay at the exact same motion phase for occlusion review.
	night_sky.mask_viewport.get_texture().get_image().save_png(output+"/sky-white-background.png")
	night_sky.stars_viewport.get_texture().get_image().save_png(output+"/stars-only.png")
	night_sky.composite_layer.visible=false
	viewer.refresh_frozen_viewport()
	for i in 5:
		await process_frame;await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output+"/midnight-no-stars.png")
	night_sky.composite_layer.visible=true
	viewer.set_lighting_period("morning")
	for i in 120:
		await process_frame;await RenderingServer.frame_post_draw
	var returned:Image=viewport.get_texture().get_image()
	returned.save_png(output+"/morning-return.png")
	var report:Dictionary={"same_process":true,"image_size":[1920,1080],"motion_time_s":frozen_time,"motion_time_unchanged":viewer.weather.anim_t==frozen_time,"night_freeze_settling_frames":5,"night_frozen_identical_pairs":equal_pairs,"night_frozen_pairs":30,"morning_roundtrip_exact":returned.get_data()==morning,"final_period":viewer.lighting_period,"castle_lights_after_return":viewer.castle_lighting.evidence(),"performance_note":"These comparison frame timings are while motion is frozen; active mode performance is captured separately."}
	var sky_hidden:bool=viewer.look_profile.night_sky==null or (viewer.look_profile.night_sky.night_weight==0.0 and not viewer.look_profile.night_sky.composite_layer.visible)
	report["morning_state_restored"]=not viewer.castle_lighting.night_enabled and sky_hidden and not viewer.period_lighting.character_fill.visible
	report["night_sky"]=night_sky_evidence
	viewer.set_motion_frozen(false)
	for i in 10:
		await process_frame;await RenderingServer.frame_post_draw
	report["resumed_clock_advances"]=viewer.weather.anim_t>frozen_time
	report["resumed_viewport_updates"]=viewport.render_target_update_mode==SubViewport.UPDATE_ALWAYS
	# Roundtrip pixel equality is reported separately from restored period state;
	# it is not the stationary B comparison, which still requires 30/30 exact pairs.
	FileAccess.open(output+"/period-check.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("PANTI_PERIOD_CHECK ",JSON.stringify(report))
	quit(0 if equal_pairs==30 and report.motion_time_unchanged and report.morning_state_restored and report.resumed_clock_advances and report.resumed_viewport_updates else 1)
