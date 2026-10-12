extends SceneTree
## Read actual GPU particle state via a transient draw-pass atlas, alongside visible ID masks.
## Original ParticleProcessMaterial, seed, emitter and simulation remain untouched.
var viewport: SubViewport
var viewer: Node3D
var leaves: Node3D
var output := ""
var seconds := 21.0
var sample_every := 3
var samples: Array=[]
var camera_attributes: CameraAttributes
var atlas_mesh: QuadMesh
var atlas_material: ShaderMaterial
const CELL := 8
const FIELDS := 7
const RANGES := [[0.0,64.0],[-1920.0,3840.0],[-2160.0,3240.0],[-32.0,128.0],[0.0,1.1],[0.0,1.1],[0.0,2.0]]

func _initialize() -> void:call_deferred("run")

func write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:push_error("Cannot write trajectory report: "+path);quit(1);return
	file.store_string(JSON.stringify(data,"\t"));file.close()

func data_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code="""shader_type spatial;
	render_mode unshaded, cull_disabled, fog_disabled, depth_test_disabled, depth_draw_never;
	uniform bool atlas_enabled=true;
	varying flat vec4 state_a;
	varying flat vec4 state_b;
	vec3 to_linear(vec3 v){return mix(v/12.92,pow((v+0.055)/1.055,vec3(2.4)),step(vec3(0.04045),v));}
	vec3 pack_value(float value,float low,float high){
	 float q=round(clamp((value-low)/(high-low),0.0,1.0)*16777215.0);
	 return to_linear(vec3(floor(q/65536.0),floor(mod(q,65536.0)/256.0),mod(q,256.0))/255.0);
	}
	void vertex(){
	 float scale=length(MODEL_MATRIX[0].xyz);
	 state_a=vec4(float(INSTANCE_ID+1),0.0,0.0,0.0);
	 state_b=vec4(INSTANCE_CUSTOM.y,INSTANCE_CUSTOM.w,scale,0.0);
	 if(scale>0.0001){
	  vec4 view_origin=VIEW_MATRIX*MODEL_MATRIX[3];
	  vec4 projected=PROJECTION_MATRIX*view_origin;
	  vec2 screen=vec2(projected.x/projected.w*0.5+0.5,0.5-projected.y/projected.w*0.5)*vec2(1920.0,1080.0);
	  state_a=vec4(float(INSTANCE_ID+1),screen,-view_origin.z);
	 }
	 // One 56x8 px data row for each stable DRAW_ORDER_INDEX slot.
	 vec2 point=vec2((VERTEX.x+0.5)*56.0,(float(INSTANCE_ID)+(0.5-VERTEX.y))*8.0);
	 POSITION=vec4(point.x/1920.0*2.0-1.0,point.y/1080.0*2.0-1.0,0.0,1.0);
	}
	void fragment(){
	 if(!atlas_enabled)discard;
	 int field=int(floor(FRAGCOORD.x/8.0));
	 vec3 encoded=vec3(0.0);
	 if(field==0)encoded=pack_value(state_a.x,0.0,64.0);
	 if(field==1)encoded=pack_value(state_a.y,-1920.0,3840.0);
	 if(field==2)encoded=pack_value(state_a.z,-2160.0,3240.0);
	 if(field==3)encoded=pack_value(state_a.w,-32.0,128.0);
	 if(field==4)encoded=pack_value(state_b.x,0.0,1.1);
	 if(field==5)encoded=pack_value(state_b.y,0.0,1.1);
	 if(field==6)encoded=pack_value(state_b.z,0.0,2.0);
	 ALBEDO=encoded;
	}
	"""
	var material := ShaderMaterial.new();material.shader=shader;material.render_priority=127
	return material

func id_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code="""shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
uniform float near_depth=5.5;
uniform float far_depth=19.0;
varying flat float slot_id;
varying flat float particle_depth;
vec3 to_linear(vec3 v){return mix(v/12.92,pow((v+0.055)/1.055,vec3(2.4)),step(vec3(0.04045),v));}
void vertex(){slot_id=float(INSTANCE_ID);particle_depth=-(VIEW_MATRIX*MODEL_MATRIX[3]).z;}
void fragment(){
 if(particle_depth<near_depth || particle_depth>far_depth)discard;
 // Full-coverage pixels decode exactly: R=(slot+1)*7, G=192, B=255.
 ALBEDO=to_linear(vec3((slot_id+1.0)*7.0,192.0,255.0)/255.0);
}
"""
	var material := ShaderMaterial.new();material.shader=shader
	material.set_shader_parameter("near_depth",float(leaves.params.render.clear_depth_clip_u[0]))
	material.set_shader_parameter("far_depth",float(leaves.params.render.clear_depth_clip_u[1]))
	return material

func unpack_value(color: Color, index: int) -> float:
	var encoded := float(color.r8*65536+color.g8*256+color.b8)
	return float(RANGES[index][0])+(float(RANGES[index][1])-float(RANGES[index][0]))*encoded/16777215.0

func capture(frame: int) -> void:
	# Raw state atlas must bypass DOF; restore original DOF for the visible ID pass.
	viewer.camera.attributes=null
	atlas_material.set_shader_parameter("atlas_enabled",true)
	for settle in 3:await process_frame;await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	if frame==0:image.save_png(output+"/atlas-calibration.png")
	var records: Array=[]
	for slot in leaves.particles.amount:
		var values: Array=[]
		for field in FIELDS:
			values.append(unpack_value(image.get_pixel(field*CELL+CELL/2,slot*CELL+CELL/2),field))
		if absi(roundi(values[0])-(slot+1))>0:
			push_error("GPU atlas ID failed; slot %d decoded %f. Do not use this trajectory." % [slot,values[0]])
			quit(1)
			return
		records.append({"slot":slot,"gpu_decoded_id":values[0],"screen_x_px":values[1],"screen_y_px":values[2],"camera_depth_u":values[3],"normalized_age":values[4],"lifetime_fraction":values[5],"basis_scale":values[6],"active":values[6]>0.0001})
	var path := output+"/f%04d.png" % (frame/sample_every)
	viewer.camera.attributes=camera_attributes
	atlas_material.set_shader_parameter("atlas_enabled",false)
	for settle in 3:await process_frame;await RenderingServer.frame_post_draw
	var mask := viewport.get_texture().get_image()
	var error := mask.save_png(path)
	if error!=OK:push_error("Trajectory PNG write failed: "+path);quit(1);return
	samples.append({"frame":frame,"time_s":float(frame)/30.0,"image":path,"particles":records})

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--trajectory-output="):output=arg.trim_prefix("--trajectory-output=")
		if arg.begins_with("--trajectory-seconds="):seconds=float(arg.trim_prefix("--trajectory-seconds="))
		if arg.begins_with("--trajectory-sample-every="):sample_every=int(arg.trim_prefix("--trajectory-sample-every="))
	if output.is_empty() or DisplayServer.get_name()=="headless":push_error("Need real GPU and new --trajectory-output");quit(1);return
	if FileAccess.file_exists(output+"/f0000.png") or FileAccess.file_exists(output+"/trajectories.json"):push_error("Refusing existing trajectory output");quit(1);return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	viewport=SubViewport.new();viewport.size=Vector2i(1920,1080);viewport.own_world_3d=true
	viewport.msaa_3d=Viewport.MSAA_4X;viewport.use_taa=false;viewport.screen_space_aa=Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;root.add_child(viewport)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP,true);DisplayServer.window_move_to_foreground()
	var preview := TextureRect.new();preview.texture=viewport.get_texture();preview.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;preview.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview);preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewer=load("res://scenes/traveler/traveler_main.tscn").instantiate();viewport.add_child(viewer)
	assert(viewer.look_on and viewer.look_far and viewer.selected=="changan","Use --day --far --view=changan")
	viewer.ui.visible=false;viewer.set_process(false);viewer.set_process_unhandled_input(false);viewer.camera.make_current()
	viewer.motion_director.externally_clocked=true
	var active: Array[String]=["leaves"];viewer.motion_director.set_active_items(active);viewer.motion_director.set_motion_enabled(true);viewer.motion_director.apply_time(0.0)
	Engine.max_fps=0;DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	leaves=viewer.motion_director.day_components.leaves
	camera_attributes=viewer.camera.attributes
	assert(leaves.particles.amount<=35,"ID color packing supports up to 35 slots")
	var original: Dictionary=leaves.evidence()
	var black := StandardMaterial3D.new();black.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;black.albedo_color=Color.BLACK;black.cull_mode=BaseMaterial3D.CULL_DISABLED
	for node in viewer.world.find_children("*","GeometryInstance3D",true,false):
		if node!=leaves.particles:node.material_override=black
	var leaf_mesh: ArrayMesh=leaves.particles.draw_pass_1.duplicate()
	leaf_mesh.surface_set_material(0,id_material());leaves.particles.draw_pass_1=leaf_mesh
	atlas_mesh=QuadMesh.new();atlas_mesh.size=Vector2.ONE;atlas_material=data_material();atlas_mesh.material=atlas_material
	leaves.particles.draw_passes=2;leaves.particles.draw_pass_2=atlas_mesh
	viewer.environment.background_mode=Environment.BG_COLOR;viewer.environment.background_color=Color.BLACK
	viewer.environment.glow_enabled=false;viewer.environment.fog_enabled=false;viewer.environment.adjustment_enabled=false
	viewer.environment.tonemap_mode=Environment.TONE_MAPPER_LINEAR;viewer.environment.tonemap_exposure=1.0
	viewer.environment.ssil_enabled=false;viewer.environment.ssao_enabled=false;viewer.environment.ambient_light_energy=0
	for warmup in 60:await process_frame;await RenderingServer.frame_post_draw
	await capture(0)
	for frame in range(1,roundi(seconds*30.0)+1):
		await process_frame;viewer.motion_director.apply_time(float(frame)/30.0);await RenderingServer.frame_post_draw
		if frame%sample_every==0:await capture(frame)
	var half: Vector3=leaves.process_material.emission_box_extents
	var depth_range: Array=[INF,-INF]
	for sx in [-1.0,1.0]:
		for sy in [-1.0,1.0]:
			for sz in [-1.0,1.0]:
				var world_corner: Vector3=leaves.global_transform*Vector3(half.x*sx,half.y*sy,half.z*sz)
				var camera_corner: Vector3=viewer.camera.global_transform.affine_inverse()*world_corner
				depth_range[0]=minf(depth_range[0],-camera_corner.z);depth_range[1]=maxf(depth_range[1],-camera_corner.z)
	write_json(output+"/trajectories.json",{"schema":"traveler.s6b.gpu-identity-trajectories.v1","image_size":[1920,1080],"viewport_size":[1920,1080],"sample_interval_s":float(sample_every)/30.0,"simulation_step_s":1.0/30.0,"duration_s":seconds,"emission_depth_range_u":depth_range,"original_leaf_evidence":original,"frozen_camera":viewer.motion_params._measured.traveler_camera,"atlas":{"rect_xywh":[0,0,CELL*FIELDS,CELL*leaves.particles.amount],"cell_px":CELL,"fields":["slot_plus_one","screen_x","screen_y","camera_depth","normalized_age","lifetime_fraction","basis_scale"],"ranges":RANGES,"encoding":"Each float normalized in stated range, rounded to 24-bit RGB; shader maps sRGB bytes to linear for exact PNG output. Center pixel readback and slot sentinel validate packing."},"visible_id_mask":{"red":"7*(slot+1)","green":192,"blue":255,"depth_test":true,"dof_retained":true,"excluded_atlas_rect":true},"method":"Actual GPU MODEL_MATRIX/INSTANCE_ID/INSTANCE_CUSTOM sampled in transient draw shaders. Original ParticleProcessMaterial and simulation untouched; first pass keeps actual leaf geometry/depth for visible IDs, second pass emits state table without depth. Full lifetime trajectories and visible trajectories must be reported separately. Table pixels are diagnostic only.","samples":samples})
	print("GPU_LEAF_TRAJECTORIES ",JSON.stringify({"samples":samples.size(),"seconds":seconds,"output":output}))
	viewer.queue_free();await process_frame;await process_frame;quit()
