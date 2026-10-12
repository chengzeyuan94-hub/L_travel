extends Node3D
## Runtime controls over an editor-visible, saved scene. No source mesh rebuild.
## Args come from scripts/traveler/traveler_launch.gd: the command line when opened on its own, the title's args when
## the title opens 「长安旅人」 in its own (the same) window (traveler_host.gd); quitting goes through Launch.finish (back to the title then).
const Launch := preload("res://scripts/traveler/traveler_launch.gd")
@onready var world:Node3D=$World
@onready var camera:Camera3D=$World/AtlasCamera
@onready var sun:DirectionalLight3D=$World/Sun
@onready var environment:Environment=$World/WorldEnvironment.environment
var cities:Array
var target:=Vector3(3,0,4)
var half_height:=67.5
var azimuth:=.16
var polar:=.76
var night:=false
var vegetation:=true
var labels_on:=true
var selected:=""
var ui:CanvasLayer
var labels:Array[Button]=[]
var material_list:Array[ShaderMaterial]=[]
var city_lights:Array[OmniLight3D]=[]
var status:Label
var period_button:Button
var drag_button:=0
var click_down_position:=Vector2.ZERO
var capture_path:=""
var capture_hud:=false
var requested_view:="world"
var formal_data:Dictionary
var routes_on:=false
var elapsed:=0.0
var frame_samples:Array[float]=[]
var look_on := false
var look_dusk := false
var look_far := false
var look_overrides: Dictionary = {}
var dump_massif := ""
var mountain_only := false
var no_mountain := false
var mountain_silhouette := false
var no_mountain_foot := false
var look_profile: RefCounted
var motion_director: Node
var character_controller: Node3D
var motion_params: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/motion_params.json"))
## 从开场进来的「长安旅人」一幕（带 --lshu-act）：不搭 Atlas 开发面板、城市名、大陆全景 / 保存画面 / 状态行，镜头不许换，
## 只留点城门换白天和夕照（夜测 TRV-2/3/4、TL-6）。提示、返回、载入卡在 act_exit_button.gd 里。
var act_overlay: Node
var act_mode := false
var view_locked := false

func _ready()->void:
	print("ATLAS_READY ",Launch.user_args())
	act_overlay=preload("res://scripts/traveler/act_exit_button.gd").attach(self,"changan")  # 从开场进来时：返回 + 提示 + 载入卡（2026-09-27）
	act_mode=act_overlay!=null
	if not act_mode:
		# 测帧 / 截图照旧不锁帧；幕模式下由 act_exit_button 开垂直同步、锁 30 帧（夜测 TRV-7）
		Engine.max_fps=0
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	cities=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/atlas/cities.json"))
	formal_data=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/formal-routes.json"))
	collect_materials(world)
	build_lights()
	if not act_mode:build_ui()
	for arg in Launch.user_args():
		if arg.begins_with("--capture="):capture_path=arg.trim_prefix("--capture=")
		if arg.begins_with("--view="):requested_view=arg.trim_prefix("--view=")
		if arg=="--night":night=true
		if arg=="--routes":routes_on=true
		if arg=="--hud":capture_hud=true
		if arg=="--no-trees":vegetation=false
		if arg=="--look":look_on=true
		if arg=="--dusk":look_dusk=true;look_on=true
		if arg=="--day":look_dusk=false;look_on=true
		if arg.begins_with("--set="):
			var pair := arg.trim_prefix("--set=").split(":",false,1)
			if pair.size()!=2 or not pair[1].is_valid_float():
				push_error("Expected --set=<look-key>:<number>: "+arg)
				Launch.finish(get_tree(),1)
				return
			look_overrides[pair[0]]=float(pair[1])
		if arg=="--far":look_far=true
		if arg.begins_with("--dump-massif="):dump_massif=arg.trim_prefix("--dump-massif=")
		if arg=="--mountain-only":mountain_only=true
		if arg=="--no-mountain":no_mountain=true
		if arg=="--mountain-silhouette":mountain_only=true;mountain_silhouette=true
		if arg=="--no-mountain-foot":no_mountain_foot=true
	set_night(night)
	set_routes(routes_on)
	set_view(requested_view)
	if selected=="changan" and not Launch.user_args().has("--no-cliff-buddha"):
		load("res://scripts/traveler/cliff_buddha_layer.gd").new().install(self)
	if selected=="changan" and Launch.user_args().has("--near-mountain-preview") and not Launch.user_args().has("--no-near-mountain"):
		load("res://scripts/traveler/near_mountain_layer.gd").new().install(self)
	if look_on:
		look_profile=load("res://scripts/traveler/traveler_lookdev.gd").new()
		look_profile.configure(self,look_dusk,look_far)
		if not dump_massif.is_empty():
			load("res://scripts/traveler/massif_audit.gd").dump(world,camera,dump_massif,motion_params._measured.traveler_camera)
		if mountain_only or no_mountain:
			load("res://scripts/traveler/massif_audit.gd").set_view(world,environment,mountain_only,no_mountain,mountain_silhouette)
	motion_director=load("res://scripts/traveler/motion_director.gd").new()
	motion_director.name="MotionDirector"
	add_child(motion_director)
	motion_director.configure(material_list,motion_params)
	motion_director.configure_day(self)
	if selected=="changan":load("res://scripts/audio/ambience/changan_ambience.gd").install(self) # 长安环境音（headless / 测试 / 截图下什么都不建）
	if look_on and look_far and selected=="changan" and not Launch.user_args().has("--no-character"):
		character_controller=load("res://scripts/traveler/character_controller.gd").new()
		character_controller.name="TravelerController"
		world.add_child(character_controller)
		character_controller.configure(self)
	if not capture_path.is_empty():
		if ui!=null:ui.visible=capture_hud
		capture_after_frames()
	get_viewport().size_changed.connect(resize_camera)
	if act_mode:
		view_locked=true
		_mark_act_ready()

## 幕模式：第一帧画出来、着色器热身几帧之后再撤掉载入卡
func _mark_act_ready()->void:
	for i in 4:await get_tree().process_frame
	act_overlay.call("mark_ready")

## 冒烟测试（act_exit_button --lshu-act-smoke）：点一下城门
func act_poke()->void:
	toggle_period_transition()

func collect_materials(node:Node)->void:
	if node is MeshInstance3D:
		if node.material_override is ShaderMaterial:add_material(node.material_override)
		for i in node.mesh.get_surface_count():
			var mat=node.get_active_material(i)
			if mat is ShaderMaterial:add_material(mat)
	if node is MultiMeshInstance3D:
		if node.material_override is ShaderMaterial:add_material(node.material_override)
		for i in node.multimesh.mesh.get_surface_count():
			var mat=node.multimesh.mesh.surface_get_material(i)
			if mat is ShaderMaterial:add_material(mat)
	for child in node.get_children():collect_materials(child)

func add_material(mat:ShaderMaterial)->void:
	if not material_list.has(mat):material_list.append(mat)

func build_lights()->void:
	for c in cities:
		var lamp:=OmniLight3D.new();lamp.name="CityGlow_"+c.id
		lamp.position=Vector3(c.x,c.base+c.scale*1.1,c.z)
		lamp.omni_range=c.scale*5.6;lamp.light_color=Color("ffad62");lamp.light_energy=1.5
		lamp.shadow_enabled=false;lamp.visible=false
		world.add_child(lamp);city_lights.append(lamp)

func build_ui()->void:
	ui=CanvasLayer.new();ui.name="AtlasUI";add_child(ui)
	var root:=Control.new();root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);root.mouse_filter=Control.MOUSE_FILTER_IGNORE;ui.add_child(root)
	var theme:=Theme.new();theme.default_font_size=17
	var font:=SystemFont.new();font.font_names=PackedStringArray(["PingFang SC","Noto Sans CJK SC","Arial"]);theme.default_font=font
	var style:=StyleBoxFlat.new();style.bg_color=Color(.96,.94,.86,.93)
	style.corner_radius_top_left=12;style.corner_radius_top_right=12;style.corner_radius_bottom_left=12;style.corner_radius_bottom_right=12
	style.content_margin_left=14;style.content_margin_right=14;style.content_margin_top=10;style.content_margin_bottom=10
	theme.set_stylebox("normal","Button",style);theme.set_stylebox("panel","PanelContainer",style)
	var hover:=style.duplicate() as StyleBoxFlat;hover.bg_color=Color("cdddcc")
	theme.set_stylebox("hover","Button",hover);theme.set_stylebox("pressed","Button",hover)
	for type in ["Button","Label","CheckButton","OptionButton"]:theme.set_color("font_color",type,Color("2e504f"))
	root.theme=theme
	var header:=VBoxContainer.new();header.position=Vector2(30,24);root.add_child(header)
	var kicker:=Label.new();kicker.text="SILK ROAD · EURASIA ATLAS / GODOT";kicker.add_theme_font_size_override("font_size",13);header.add_child(kicker)
	var title:=Label.new();title.text="山河之间";title.add_theme_font_size_override("font_size",32);header.add_child(title)
	var sub:=Label.new();sub.text="十六座城 · 连续山川 · 秋日夕照";sub.add_theme_font_size_override("font_size",15);header.add_child(sub)
	var panel:=PanelContainer.new();panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE);panel.offset_top=-115;panel.offset_bottom=-18;panel.offset_left=28;panel.offset_right=-28;root.add_child(panel)
	var rows:=VBoxContainer.new();panel.add_child(rows)
	var top:=HBoxContainer.new();top.add_theme_constant_override("separation",10);rows.add_child(top)
	for pair in [["大陆全景","world"],["丝路之间","silk"],["雪山与绿洲","mountain"],["东方秋色","east"]]:
		var b:=Button.new();b.text=pair[0];var key:String=pair[1];b.pressed.connect(func():set_view(key));top.add_child(b)
	var city_select:=OptionButton.new();city_select.add_item("走近一座城市…")
	for c in cities:city_select.add_item(c.name)
	city_select.item_selected.connect(func(i):
		if i>0:set_view(cities[i-1].id))
	top.add_child(city_select)
	period_button=Button.new();period_button.text="日光 / 夕照";period_button.pressed.connect(toggle_period_transition);top.add_child(period_button)
	var save_button:=Button.new();save_button.text="保存画面";save_button.pressed.connect(save_interactive);top.add_child(save_button)
	var bottom:=HBoxContainer.new();bottom.add_theme_constant_override("separation",20);rows.add_child(bottom)
	for pair in [["植被",true],["城市名",true],["正式商道",false]]:
		var check:=CheckButton.new();check.text=pair[0];check.button_pressed=pair[1];bottom.add_child(check)
		if pair[0]=="植被":check.toggled.connect(func(v):vegetation=v;update_lod())
		elif pair[0]=="城市名":check.toggled.connect(func(v):labels_on=v)
		else:check.toggled.connect(set_routes)
	status=Label.new();status.add_theme_font_size_override("font_size",13);status.size_flags_horizontal=Control.SIZE_EXPAND_FILL;status.horizontal_alignment=HORIZONTAL_ALIGNMENT_RIGHT;bottom.add_child(status)
	for c in cities:
		var b:=Button.new();b.text=c.name;b.add_theme_font_size_override("font_size",13)
		var compact:=style.duplicate() as StyleBoxFlat;compact.content_margin_left=8;compact.content_margin_right=8;compact.content_margin_top=4;compact.content_margin_bottom=4
		b.add_theme_stylebox_override("normal",compact);root.add_child(b)
		var id:String=c.id;b.pressed.connect(func():set_view(id));labels.append(b)

func set_view(view:String)->void:
	if view_locked:return   # 幕模式：镜头定在长安，谁点都不换
	selected=""
	match view:
		"world":
			target=Vector3(3,0,4);half_height=maxf(62,108/get_viewport().get_visible_rect().size.aspect());azimuth=.16;polar=.76
		"silk":target=Vector3(-4,1,13);half_height=34;azimuth=.12;polar=.9
		"mountain":target=Vector3(8,2,6);half_height=17;azimuth=.46;polar=.94
		"east":target=Vector3(37,1,9);half_height=22;azimuth=.32;polar=.86
		_:
			for c in cities:
				if c.id==view:
					selected=view;target=Vector3(c.x-1.3,c.base+.85,c.z);half_height=3.95;azimuth=.62;polar=1.04
	update_camera()

func resize_camera()->void:
	if selected.is_empty() and half_height>=62:half_height=maxf(62,108/get_viewport().get_visible_rect().size.aspect())
	update_camera()

func update_camera()->void:
	if look_on:
		var frozen: Dictionary = motion_params._measured.traveler_camera
		camera.projection=Camera3D.PROJECTION_PERSPECTIVE
		camera.keep_aspect=Camera3D.KEEP_HEIGHT
		camera.fov=float(frozen.fov_vertical_deg)
		camera.near=0.15
		camera.far=900.0
		var e:=deg_to_rad(float(frozen.pitch_deg))
		var az:=float(frozen.azimuth_rad)
		var direction:=Vector3(cos(e)*sin(az),sin(e),cos(e)*cos(az))
		camera.position=target+direction*float(frozen.distance_u)
		camera.look_at(target+Vector3(0,float(frozen.lift_u),0))
		update_lod()
		return
	camera.size=half_height*2
	camera.position=target+Vector3(sin(polar)*sin(azimuth),cos(polar),sin(polar)*cos(azimuth))*230
	camera.look_at(target)
	update_lod()

func update_lod()->void:
	var detailed:=half_height<21
	$World/VegetationHigh.visible=vegetation and detailed
	$World/VegetationLow.visible=vegetation and not detailed
	$World/NaturalDetails.visible=vegetation
	# City plant surfaces are separate named mesh instances in the imported GLBs.
	for city in $World/Cities.get_children():
		for n in city.find_children("*","MeshInstance3D",true,false):
			if String(n.name).contains("plants"):n.visible=vegetation

func set_routes(enabled:bool)->void:
	routes_on=enabled
	$World/FormalRoutes.visible=enabled;$World/FormalNodes.visible=enabled

func set_night(enabled:bool)->void:
	night=enabled
	for m in material_list:m.set_shader_parameter("night_amount",1.0 if enabled else 0.0)
	sun.light_energy=.28 if enabled else 1.55
	sun.light_color=(Color(.43,.60,1) if enabled else Color(1,.79,.55)).linear_to_srgb()
	environment.background_color=Color(.055,.088,.132) if enabled else Color(.89,.875,.826)
	for lamp in city_lights:lamp.visible=enabled
	if look_profile!=null:look_profile.set_mountain_period(enabled or look_dusk)
	set_cliff_buddha_glow(enabled or look_dusk)

func toggle_period_transition()->void:
	if look_profile==null or selected!="changan":
		return
	var target_dusk:bool=bool(not look_profile.transition_target_dusk if look_profile.transition_active else not look_profile.look_dusk)
	look_profile.start_period_transition(target_dusk,8.0)
	if is_instance_valid(character_controller):
		character_controller.begin_period_transition(target_dusk)
	if period_button!=null:
		period_button.text="回到白天" if target_dusk else "进入黄昏"

func period_hotspot_hit(screen_position: Vector2)->bool:
	if look_profile==null or selected!="changan":
		return false
	for c in cities:
		if c.id!=selected:continue
		var gate_point:=Vector3(c.x,float(c.base)+float(c.scale)*0.65,c.z)
		if camera.is_position_behind(gate_point):return false
		var projected:=camera.unproject_position(gate_point)
		return projected.distance_to(screen_position)<130.0
	return false

func set_cliff_buddha_glow(enabled: bool) -> void:
	var lights := world.get_node_or_null("CliffBuddhaBacklight") as Node3D
	if lights==null:return
	lights.visible=enabled and not Launch.user_args().has("--no-buddha-glow")
	var report: Dictionary=world.get_meta("cliff_buddha",{})
	report["cave_glow_active"]=lights.visible
	report["self_emission_active"]=false
	world.set_meta("cliff_buddha",report)

func _process(delta:float)->void:
	elapsed+=delta
	if look_profile!=null and (motion_director==null or motion_director.motion_enabled):
		look_profile.tick_transition(delta)
		if period_button!=null and not look_profile.transition_active:
			period_button.text="回到白天" if look_profile.look_dusk else "进入黄昏"
	if frame_samples.size()<180 and elapsed>2:frame_samples.append(delta*1000)
	if labels.is_empty():return   # 幕模式没有城市名和状态行
	var viewport:=get_viewport().get_visible_rect().size
	var used:Array[Rect2]=[]
	for i in cities.size():
		var c:Dictionary=cities[i]
		var point:=Vector3(c.x,c.base,c.z+c.scale*3.7)
		var p:=camera.unproject_position(point)
		var b:=labels[i];var box:=Rect2(p-b.size*.5,b.size)
		var show:=labels_on and not camera.is_position_behind(point) and p.x>15 and p.x<viewport.x-15 and p.y>120 and p.y<viewport.y-135
		for previous in used:
			if previous.grow(4).intersects(box):show=false
		b.visible=show;b.position=box.position
		if show:used.append(box)
	status.text="16 城 · 19 商道 · 54 节点  |  点击城楼切换日/黄昏 · 拖动旋转 / 右键平移 / 滚轮缩放 / H 隐藏 / Esc 退出"

func _unhandled_input(event:InputEvent)->void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode==KEY_ESCAPE:
			# 单独开的长安（工具 / 启动器）：Esc 直接退出。以前换到 main.tscn，在这个进程里又开了一遍游戏开场（夜测 TRV-5 / TL-10）。
			# 从开场进来的一幕：和「‹ 返回」同一条路（开在开场窗口里时回开场）
			get_viewport().set_input_as_handled()
			if act_overlay!=null:act_overlay.call("leave","esc")
			else:get_tree().quit()
			return
		if event.keycode==KEY_H and ui!=null:ui.visible=not ui.visible
		if event.keycode==KEY_HOME and not is_instance_valid(character_controller):set_view("world")
	if act_mode and event is InputEventMouseMotion:
		preload("res://scripts/traveler/act_exit_button.gd").set_hotspot_cursor(period_hotspot_hit(event.position))
	if is_instance_valid(character_controller):
		if character_controller.handle_input(event):
			get_viewport().set_input_as_handled()
			return
		# The interaction view keeps the approved camera fixed.
		if event is InputEventMouseMotion or (event is InputEventMouseButton and event.button_index!=MOUSE_BUTTON_LEFT):return
	if event is InputEventMouseButton:
		if event.button_index==MOUSE_BUTTON_LEFT and event.pressed:
			click_down_position=event.position
		if event.button_index==MOUSE_BUTTON_LEFT and not event.pressed:
			if event.position.distance_to(click_down_position)<8.0 and period_hotspot_hit(event.position):
				toggle_period_transition()
		if event.button_index in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT]:drag_button=event.button_index if event.pressed else 0
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
			half_height=clampf(half_height*(.88 if event.button_index==MOUSE_BUTTON_WHEEL_UP else 1.12),3,180);update_camera()
	if event is InputEventMouseMotion and drag_button:
		if drag_button==MOUSE_BUTTON_RIGHT or event.shift_pressed:
			var k:=2*half_height/get_viewport().get_visible_rect().size.y
			target.x-=event.relative.x*k*cos(azimuth)+event.relative.y*k*sin(azimuth)/maxf(.5,cos(polar))
			target.z+=event.relative.x*k*sin(azimuth)-event.relative.y*k*cos(azimuth)/maxf(.5,cos(polar))
		else:
			azimuth-=event.relative.x*.004;polar=clampf(polar+event.relative.y*.003,.2,1.28)
		update_camera()

func save_interactive()->void:
	var path:=OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)+"/山河之间-Godot-"+Time.get_datetime_string_from_system().replace(":","-")+".png"
	var visible_before:=ui.visible;ui.visible=false
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	ui.visible=visible_before
	status.text="已保存："+path

func capture_after_frames()->void:
	# Measure completed rendered frames with a monotonic clock; process delta can be smoothed.
	print("CAPTURE_WARMUP ",elapsed)
	while elapsed<2.0:await get_tree().process_frame
	print("CAPTURE_SAMPLING ",elapsed)
	await RenderingServer.frame_post_draw
	var render_samples: Array[float]=[]
	var previous_usec := Time.get_ticks_usec()
	for i in 180:
		if i%30==0:print("CAPTURE_FRAME ",i)
		await RenderingServer.frame_post_draw
		var now_usec := Time.get_ticks_usec()
		render_samples.append(float(now_usec-previous_usec)/1000.0)
		previous_usec=now_usec
	await RenderingServer.frame_post_draw
	var image:=get_viewport().get_texture().get_image()
	var error:=image.save_png(capture_path)
	var evidence:={"capture_error":error,"view":requested_view,"night":night,"renderer":RenderingServer.get_current_rendering_method(),"image_size":[image.get_width(),image.get_height()],"viewport_size":[get_viewport().get_visible_rect().size.x,get_viewport().get_visible_rect().size.y],"camera":{"target":[target.x,target.y,target.z],"half_height":half_height,"azimuth":azimuth,"polar":polar},"cities":cities.size(),"routes":formal_data.routes.size(),"nodes":formal_data.nodes.size(),"edges":formal_data.edges.size(),"draw_calls":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),"rendered_primitives":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),"note":"Single-view render smoke; not a cross-device performance benchmark."}
	evidence["frozen_camera"] = motion_params._measured.traveler_camera if look_on else {}
	evidence["motion"] = motion_director.evidence()
	if is_instance_valid(character_controller):evidence["character"]=character_controller.evidence()
	evidence["camera_position"] = [camera.position.x,camera.position.y,camera.position.z]
	evidence["camera_fov"] = camera.fov
	evidence["use_taa"] = get_viewport().use_taa
	evidence["capture_preview_enabled"]=Launch.user_args().has("--capture-preview")
	evidence["viewport_draw_calls"]=get_viewport().get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	var sorted_frames := render_samples.duplicate()
	sorted_frames.sort()
	evidence["frame_ms"]={"p50":sorted_frames[89],"p95":sorted_frames[170],"samples":render_samples,"sample_count":render_samples.size(),"warmup_seconds":2.0,"method":"monotonic wall time between frame_post_draw signals, nearest-rank quantiles; excludes final texture readback","vsync_disabled":DisplayServer.window_get_vsync_mode()==DisplayServer.VSYNC_DISABLED,"engine_max_fps":Engine.max_fps}
	if look_profile!=null:evidence["look"]=look_profile.evidence(image)
	var file:=FileAccess.open(capture_path.trim_suffix(".png")+".json",FileAccess.WRITE)
	if file:file.store_string(JSON.stringify(evidence,"\t"))
	print("ATLAS_CAPTURE ",JSON.stringify(evidence))
	# The director is a sibling of World; stop its GPU requests before freeing World.
	motion_director.set_motion_enabled(false)
	motion_director.set_process(false)
	world.queue_free()
	set_process(false)
	await get_tree().process_frame
	await get_tree().process_frame
	Launch.finish(get_tree(),error)
