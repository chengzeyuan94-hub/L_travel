extends Control
## Small runtime authoring surface. Editing modifies a presentation document only.
const Store = preload("res://scripts/editor/map_layout_store.gd")
const Catalog = preload("res://scripts/editor/map_asset_catalog.gd")
var layout: Dictionary
var selected_id := ""
var selected_group := ""
var viewport: SubViewport
var camera: Camera3D
var canvas: Control
var world: Node3D
var _objects: Node3D
var _routes: Node3D
var _handles: Node3D
var _selection: MeshInstance3D
var _environment: Environment
var _sun: DirectionalLight3D
var _fill: DirectionalLight3D
var _grid: MeshInstance3D
var _instances: Dictionary = {}
var _bounds: Dictionary = {}
var _status: Label
var _mode_label: Label
var _document_label: Label
var _inspector: VBoxContainer
var _asset_list: VBoxContainer
var _object_list: ItemList
var _filter: OptionButton
var _bind: OptionButton
var _position_inputs: Array[SpinBox] = []
var _yaw_input: SpinBox
var _scale_input: SpinBox
var _route_type: OptionButton
var _route_default: OptionButton
var _selected_label: Label
var _path_label: Label
var _node_info: Label
var _stats_label: Label
var _snap: CheckBox
var _night_toggle: CheckButton
var _file_dialog: FileDialog
var _message_dialog: AcceptDialog
var _properties: VBoxContainer
var _route_properties: VBoxContainer
var _binding_box: VBoxContainer
var _updating := false
var _mode := "select"
var _asset_to_place := ""
var _connect_from := ""
var _dirty := false
var _serial := 0
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _current_path := "user://map_editor/layout.json"
var _export_path := "user://map_editor/layout.game.json"
var _file_action := "load"
var _formal: Dictionary
var _pan := false
var _orbit := false
var _dragging := false
var _drag_started := false
var _drag_handle := -1
var _active_handle := -1
var _press := Vector2.ZERO
var _previous := Vector2.ZERO
var _grab_offset := Vector3.ZERO
var _camera_target := Vector3.ZERO
var _camera_yaw := deg_to_rad(-7)
var _camera_pitch := deg_to_rad(58)
var _camera_size := 29.0
var _camera_fit := true
var _ui_theme: Theme

func _ready() -> void:
	name = "SilkRoadMapEditor"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_formal = GameData.load_ruleset(GameData.FORMAL_RULESET_DIR)
	_build_ui()
	_build_viewport()
	layout = _sample_document()
	_render_document()
	fit_canvas()
	_message("样板草稿：三个城市只用于试用工具。位置与路线由你编辑；Ctrl+S 保存。")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--layout="):load_document_file(arg.substr(9))
	if "--capture" in OS.get_cmdline_user_args():call_deferred("_capture_initial")

func _style(color:Color,border:Color=Color.TRANSPARENT)->StyleBoxFlat:
	var s:=StyleBoxFlat.new();s.bg_color=color;s.border_color=border
	s.set_border_width_all(1 if border.a>0 else 0);s.set_corner_radius_all(5)
	s.content_margin_left=10;s.content_margin_right=10;s.content_margin_top=7;s.content_margin_bottom=7
	return s

func _build_ui()->void:
	_ui_theme=Theme.new();_ui_theme.default_font_size=14
	_ui_theme.set_color("font_color","Label",Color("e6e5dc"))
	_ui_theme.set_color("font_color","Button",Color("e9ebe2"))
	_ui_theme.set_stylebox("normal","Button",_style(Color("344b50")))
	_ui_theme.set_stylebox("hover","Button",_style(Color("426568")))
	_ui_theme.set_stylebox("pressed","Button",_style(Color("22777a")))
	_ui_theme.set_stylebox("focus","Button",_style(Color(0,0,0,0),Color("83c6b8")))
	theme=_ui_theme
	var bg:=ColorRect.new();bg.color=Color("1e3036");bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);add_child(bg)
	var main:=VBoxContainer.new();main.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);main.add_theme_constant_override("separation",0);add_child(main)
	var top:=HBoxContainer.new();top.add_theme_constant_override("separation",6);main.add_child(top)
	var title:=Label.new();title.text="  丝路商旅  /  地图工坊  ";title.add_theme_font_size_override("font_size",18);top.add_child(title)
	_button(top,"新建",func():load_document(Store.blank_layout()))
	_button(top,"样板",func():load_document(_sample_document()))
	_button(top,"正式数据起稿",_load_formal_seed)
	_button(top,"打开…",func():_open_file_dialog("load"))
	_button(top,"保存",func():save_document(_current_path))
	_button(top,"另存为…",func():_open_file_dialog("save"))
	_button(top,"导出游戏…",func():_open_file_dialog("export"))
	_button(top,"试玩导出",_launch_game_preview)
	var space:=Control.new();space.size_flags_horizontal=Control.SIZE_EXPAND_FILL;top.add_child(space)
	_night_toggle=CheckButton.new();_night_toggle.text="夜晚";_night_toggle.toggled.connect(set_night);top.add_child(_night_toggle)
	var tools_row:=HBoxContainer.new();tools_row.add_theme_constant_override("separation",7);main.add_child(tools_row)
	_button(tools_row,"选择 / 拖动",func():_set_mode("select"))
	_button(tools_row,"放置停靠点",func():_set_mode("node"))
	_button(tools_row,"连接路线",func():_set_mode("route"))
	_route_default=OptionButton.new();_route_default.add_item("陆路 land");_route_default.add_item("海路 sea");tools_row.add_child(_route_default)
	_button(tools_row,"撤销",undo_edit);_button(tools_row,"重做",redo_edit)
	_button(tools_row,"总览 R",fit_canvas)
	_snap=CheckBox.new();_snap.text="吸附 0.25";_snap.button_pressed=true;tools_row.add_child(_snap)
	var grid_toggle:=CheckBox.new();grid_toggle.text="网格";grid_toggle.button_pressed=true;grid_toggle.toggled.connect(func(v:bool):if is_instance_valid(_grid):_grid.visible=v);tools_row.add_child(grid_toggle)
	_mode_label=Label.new();_mode_label.text="选择模式";_mode_label.size_flags_horizontal=Control.SIZE_EXPAND_FILL;tools_row.add_child(_mode_label)
	var body:=HBoxContainer.new();body.size_flags_vertical=Control.SIZE_EXPAND_FILL;body.add_theme_constant_override("separation",0);main.add_child(body)
	var left:=VBoxContainer.new();left.custom_minimum_size.x=190;body.add_child(left)
	_heading(left,"资产库")
	_filter=OptionButton.new()
	for label in ["全部样板","城市","地形 / 水岸","植物","旅行道具"]:_filter.add_item(label)
	_filter.item_selected.connect(func(_i:int):_populate_assets());left.add_child(_filter)
	var asset_scroll:=ScrollContainer.new();asset_scroll.size_flags_vertical=Control.SIZE_EXPAND_FILL;asset_scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;left.add_child(asset_scroll)
	_asset_list=VBoxContainer.new();_asset_list.size_flags_horizontal=Control.SIZE_EXPAND_FILL;asset_scroll.add_child(_asset_list)
	_heading(left,"场景对象")
	_object_list=ItemList.new();_object_list.custom_minimum_size.y=174;_object_list.item_selected.connect(_on_list_selected);left.add_child(_object_list)
	var tip:=Label.new();tip.text="点选资产后，在画布放置\nEsc 返回选择 · F 靠近对象\n左拖移动 · 右拖平移\nAlt + 右拖环绕 · 滚轮缩放";tip.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;tip.add_theme_font_size_override("font_size",12);left.add_child(tip)
	canvas=Control.new();canvas.name="Canvas";canvas.size_flags_horizontal=Control.SIZE_EXPAND_FILL;canvas.size_flags_vertical=Control.SIZE_EXPAND_FILL;canvas.clip_contents=true;canvas.mouse_filter=Control.MOUSE_FILTER_STOP;canvas.focus_mode=Control.FOCUS_ALL;body.add_child(canvas)
	canvas.gui_input.connect(_canvas_input);canvas.resized.connect(_canvas_resized)
	var right_panel:=PanelContainer.new();right_panel.custom_minimum_size.x=244;right_panel.add_theme_stylebox_override("panel",_style(Color("263c43")));body.add_child(right_panel)
	var scroll:=ScrollContainer.new();scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;right_panel.add_child(scroll)
	_inspector=VBoxContainer.new();_inspector.custom_minimum_size.x=222;_inspector.size_flags_horizontal=Control.SIZE_EXPAND_FILL;_inspector.add_theme_constant_override("separation",9);scroll.add_child(_inspector)
	_heading(_inspector,"选中属性")
	_selected_label=Label.new();_selected_label.text="尚未选中对象";_selected_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;_inspector.add_child(_selected_label)
	_binding_box=VBoxContainer.new();_inspector.add_child(_binding_box)
	_heading(_binding_box,"正式身份绑定")
	_bind=OptionButton.new();_bind.custom_minimum_size.x=210;_bind.clip_text=true;_bind.item_selected.connect(_binding_changed);_binding_box.add_child(_bind)
	_node_info=Label.new();_node_info.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;_node_info.add_theme_font_size_override("font_size",12);_binding_box.add_child(_node_info)
	_properties=VBoxContainer.new();_properties.add_theme_constant_override("separation",6);_inspector.add_child(_properties)
	for axis in ["X  东西","Y  高度","Z  南北"]:
		var row:=HBoxContainer.new();_properties.add_child(row);var label:=Label.new();label.text=axis;label.custom_minimum_size.x=65;row.add_child(label)
		var input:=SpinBox.new();input.min_value=-100;input.max_value=100;input.step=.05;input.size_flags_horizontal=Control.SIZE_EXPAND_FILL;row.add_child(input);_position_inputs.append(input);input.value_changed.connect(func(_v:float):_transform_from_inspector())
	_yaw_input=_spin_property(_properties,"旋转 °",-360,360,5)
	_yaw_input.value_changed.connect(func(_v:float):_transform_from_inspector())
	_scale_input=_spin_property(_properties,"等比缩放",.1,10,.05);_scale_input.value=1
	_scale_input.value_changed.connect(func(_v:float):_transform_from_inspector())
	var transforms:=HBoxContainer.new();_properties.add_child(transforms)
	_button(transforms,"↶ 15°",func():_rotate_selected(-15));_button(transforms,"↷ 15°",func():_rotate_selected(15));_button(transforms,"靠近 F",focus_selected)
	_route_properties=VBoxContainer.new();_inspector.add_child(_route_properties)
	_heading(_route_properties,"路线编辑")
	_route_type=OptionButton.new();_route_type.add_item("陆路 land");_route_type.add_item("海路 sea");_route_type.item_selected.connect(_change_route_type);_route_properties.add_child(_route_type)
	_button(_route_properties,"添加折点：再点画布",func():_set_mode("point"))
	_button(_route_properties,"删除选中折点",_delete_handle)
	_button(_route_properties,"清除全部折点",func():if selected_group=="routes":set_route_points(selected_id,[]))
	var route_help:=Label.new();route_help.text="拖动蓝色折点调整走向。\n双击线段插入折点。\n折点不增加游戏步数。";route_help.add_theme_font_size_override("font_size",12);_route_properties.add_child(route_help)
	_button(_inspector,"删除选中对象  Delete",delete_selected)
	_button(_inspector,"复制装饰  Ctrl+D",duplicate_selected)
	_heading(_inspector,"文档")
	_stats_label=Label.new();_stats_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;_inspector.add_child(_stats_label)
	_path_label=Label.new();_path_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;_path_label.add_theme_font_size_override("font_size",11);_inspector.add_child(_path_label)
	_button(_inspector,"检查布局 / 绑定",_show_validation)
	var caption:=Label.new();caption.text="60 × 20 · 3:1 画布\n城市与停靠点绑定正式 ID。\n地形、树、船、桥默认纯装饰。\n导出不会改变规则数据。";caption.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;caption.add_theme_font_size_override("font_size",12);_inspector.add_child(caption)
	_status=Label.new();_status.custom_minimum_size.y=30;_status.add_theme_color_override("font_color",Color("bcd9c8"));_status.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS;main.add_child(_status)
	_file_dialog=FileDialog.new();_file_dialog.access=FileDialog.ACCESS_FILESYSTEM;_file_dialog.filters=PackedStringArray(["*.json ; 地图布局 JSON"]);_file_dialog.size=Vector2i(900,600);_file_dialog.file_selected.connect(_file_selected);add_child(_file_dialog)
	_message_dialog=AcceptDialog.new();_message_dialog.title="地图工坊";_message_dialog.min_size=Vector2i(560,250);add_child(_message_dialog)
	_populate_assets()

func _button(parent:Node,title:String,action:Callable)->Button:
	var b:=Button.new();b.text=title;b.pressed.connect(action);b.focus_mode=Control.FOCUS_NONE;parent.add_child(b);return b
func _heading(parent:Node,text:String)->void:
	var l:=Label.new();l.text=text;l.add_theme_color_override("font_color",Color("91b9b4"));l.add_theme_font_size_override("font_size",13);parent.add_child(l)
func _spin_property(parent:Node,text:String,minv:float,maxv:float,stepv:float)->SpinBox:
	var row:=HBoxContainer.new();parent.add_child(row);var label:=Label.new();label.text=text;label.custom_minimum_size.x=65;row.add_child(label)
	var s:=SpinBox.new();s.min_value=minv;s.max_value=maxv;s.step=stepv;s.size_flags_horizontal=Control.SIZE_EXPAND_FILL;row.add_child(s);return s

func _populate_assets()->void:
	for child in _asset_list.get_children():child.queue_free()
	var categories:=["","city","terrain","plant","prop"]
	for item in Catalog.list_assets():
		if _filter.selected>0 and item.category!=categories[_filter.selected]:continue
		var b:=_button(_asset_list,item.label,func():_asset_to_place=item.id;_set_mode("place"))
		b.tooltip_text=str(item.id)+"\n点击后在画布放置；右侧可修改位置、旋转与缩放。"

func _build_viewport()->void:
	var container:=SubViewportContainer.new();container.stretch=true;container.mouse_filter=Control.MOUSE_FILTER_IGNORE;container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);canvas.add_child(container)
	viewport=SubViewport.new();viewport.own_world_3d=true;viewport.gui_disable_input=true;viewport.handle_input_locally=false;viewport.msaa_3d=Viewport.MSAA_4X;container.add_child(viewport)
	world=Node3D.new();viewport.add_child(world)
	var env:=WorldEnvironment.new();_environment=Environment.new();_environment.background_mode=Environment.BG_COLOR;_environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;_environment.tonemap_mode=Environment.TONE_MAPPER_LINEAR;env.environment=_environment;world.add_child(env)
	_sun=DirectionalLight3D.new();_sun.rotation_degrees=Vector3(-48,-30,0);_sun.shadow_enabled=true;_sun.directional_shadow_max_distance=100;_sun.shadow_bias=.025;_sun.shadow_normal_bias=.4;world.add_child(_sun)
	_fill=DirectionalLight3D.new();_fill.rotation_degrees=Vector3(-40,145,0);world.add_child(_fill)
	camera=Camera3D.new();camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.current=true;camera.far=200;world.add_child(camera)
	var base:=MeshInstance3D.new();base.name="Canvas_60x20";var mesh:=BoxMesh.new();mesh.size=Vector3(60,.35,20);base.mesh=mesh;base.position.y=-.225;base.material_override=_material(Color("bdb493"));base.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;world.add_child(base)
	var top:=MeshInstance3D.new();var plane:=PlaneMesh.new();plane.size=Vector2(60,20);top.mesh=plane;top.position.y=-.005;top.material_override=_material(Color("d6caaa"));top.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;world.add_child(top)
	var gridmesh:=ImmediateMesh.new();gridmesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for x in range(-30,31):gridmesh.surface_add_vertex(Vector3(x,.004,-10));gridmesh.surface_add_vertex(Vector3(x,.004,10))
	for z in range(-10,11):gridmesh.surface_add_vertex(Vector3(-30,.004,z));gridmesh.surface_add_vertex(Vector3(30,.004,z))
	gridmesh.surface_end();_grid=MeshInstance3D.new();_grid.mesh=gridmesh;_grid.material_override=_material(Color("afa789"),true);_grid.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;world.add_child(_grid)
	_objects=Node3D.new();_objects.name="AuthoredObjects";world.add_child(_objects)
	_routes=Node3D.new();_routes.name="AuthoredRoutes";world.add_child(_routes)
	_handles=Node3D.new();_handles.name="RouteControlHandles";world.add_child(_handles)
	_selection=MeshInstance3D.new();_selection.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF;_selection.material_override=_material(Color("249f9d"),true);world.add_child(_selection)
	for mark in [[Vector3(-29.2,.03,9),"西 / WEST"],[Vector3(26.6,.03,9),"东 / EAST"],[Vector3(0,.03,9),"60 × 20   /   3 : 1"]]:
		var label:=Label3D.new();label.text=mark[1];label.position=mark[0];label.rotation_degrees.x=-90;label.font_size=40;label.pixel_size=.008;label.modulate=Color("727f70");label.outline_size=0;world.add_child(label)

func _material(color:Color,unshaded:bool=false)->StandardMaterial3D:
	var mat:=StandardMaterial3D.new();mat.albedo_color=color;mat.roughness=.9
	if unshaded:mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat
func _vec(p:Array)->Vector3:return Vector3(p[0],p[1],p[2])
func _array(v:Vector3)->Array:return [snappedf(v.x,.001),snappedf(v.y,.001),snappedf(v.z,.001)]
func _clear(node:Node)->void:
	for child in node.get_children():node.remove_child(child);child.queue_free()
func _id(prefix:String)->String:
	_serial+=1
	return "%s_%d_%d"%[prefix,Time.get_ticks_usec(),_serial]

func _sample_document()->Dictionary:
	var data:Dictionary=Store.blank_layout()
	data.cities=[{"id":"sample_baghdad","city_id":"baghdad","node_id":"baghdad","asset_id":"city_blue_dome","position":[-9,0,-1],"rotation_y":0,"scale":1},{"id":"sample_panti","city_id":"panti","node_id":"panti","asset_id":"city_caravanserai","position":[1,0,-1],"rotation_y":0,"scale":1},{"id":"sample_changan","city_id":"changan","node_id":"changan","asset_id":"city_chinese","position":[10,0,-1],"rotation_y":0,"scale":1}]
	data.logic_nodes=[{"id":"sample_stop_1","node_id":"land_baghdad_panti_01","position":[-6,0,1.8]},{"id":"sample_stop_2","node_id":"land_baghdad_panti_02","position":[-2.5,0,2]}]
	data.routes=[]
	var chain:=["baghdad","land_baghdad_panti_01","land_baghdad_panti_02","panti"]
	for i in range(3):data.routes.append({"id":"sample_route_%d"%i,"edge_id":_formal_edge(chain[i],chain[i+1],"land"),"from_node":chain[i],"to_node":chain[i+1],"type":"land","points":[[-8,0,1.8]] if i==0 else []})
	data.decorations=[{"id":"sample_ridge","asset_id":"mountain_snow","position":[-1,0,-5],"rotation_y":0,"scale":1.2},{"id":"sample_palm","asset_id":"palm","position":[-11,0,.6],"rotation_y":.3,"scale":.85},{"id":"sample_coast","asset_id":"coast","position":[9,.03,3.7],"rotation_y":0,"scale":1.6},{"id":"sample_ship","asset_id":"ship","position":[9,.01,4.5],"rotation_y":1.0,"scale":.85},{"id":"sample_tree","asset_id":"broadleaf","position":[12,0,-2],"rotation_y":0,"scale":1}]
	return data

func get_layout()->Dictionary:return layout.duplicate(true)
func load_document(data:Dictionary)->void:
	if layout!=null:_push_undo()
	layout=data.duplicate(true);selected_id="";selected_group="";_active_handle=-1;_render_document();fit_canvas();_dirty=true;_set_mode("select");_message("已载入草稿。可撤销回到上一文档。")
func _load_formal_seed()->void:
	load_document(Store.seed_from_formal());_message("已按正式数据坐标生成编辑起稿：16 城、54 节点、57 边。请按你的设计重新摆放。")
func _push_undo()->void:
	if layout==null:return
	_undo.append(layout.duplicate(true));if _undo.size()>80:_undo.pop_front()
	_redo.clear();_dirty=true
func undo_edit()->void:
	if _undo.is_empty():_message("没有可撤销的编辑。");return
	_redo.append(layout.duplicate(true));layout=_undo.pop_back();_after_history("已撤销")
func redo_edit()->void:
	if _redo.is_empty():_message("没有可重做的编辑。");return
	_undo.append(layout.duplicate(true));layout=_redo.pop_back();_after_history("已重做")
func _after_history(message:String)->void:
	if _find(selected_group,selected_id).is_empty():selected_id="";selected_group=""
	_dragging=false;_active_handle=-1;_dirty=true;_render_document();_message(message)

func add_asset(asset_id:String,at:Vector3)->String:
	var asset:=_asset_description(asset_id)
	if asset.is_empty():return ""
	_push_undo()
	var group:="cities" if asset.category=="city" else "decorations"
	var id:=_id("city" if group=="cities" else "decor")
	var entry:={"id":id,"asset_id":asset_id,"position":_array(_clamp_position(at)),"rotation_y":0.0,"scale":1.0}
	if group=="cities":
		var city_id:=_first_unplaced(true,asset_id)
		if city_id.is_empty():_message("16 个正式城市都已放置；请选择已有城市移动。");_undo.pop_back();return ""
		entry.city_id=city_id;entry.node_id=city_id
	layout[group].append(entry);_render_item(group,entry);_refresh_lists();select_item(group,id);return id
func add_logic_node(node_id:String,at:Vector3)->String:
	if node_id.is_empty():node_id=_first_unplaced(false)
	if node_id.is_empty() or _node_entry(node_id).size()>0:_message("该逻辑节点已放置，或没有剩余正式节点。");return ""
	if not _formal.board_nodes.has(node_id) or _formal.board_nodes[node_id].node_type=="CITY":_message("请选择正式普通停靠点 ID；城市请从资产库放置。");return ""
	_push_undo();var id:=_id("node");var entry:={"id":id,"node_id":node_id,"position":_array(_clamp_position(at))}
	layout.logic_nodes.append(entry);_render_item("logic_nodes",entry);_refresh_lists();select_item("logic_nodes",id);return id
func _asset_description(asset_id:String)->Dictionary:
	for a in Catalog.list_assets():
		if a.id==asset_id:return a
	return {}
func _first_unplaced(city:bool,asset_id:String="")->String:
	var preferred:={"city_blue_dome":"baghdad","city_caravanserai":"panti","city_chinese":"changan"}
	if city and preferred.has(asset_id) and _node_entry(preferred[asset_id]).is_empty():return preferred[asset_id]
	for id in _formal.board_nodes:
		if (_formal.board_nodes[id].node_type=="CITY")==city and _node_entry(str(id)).is_empty():return str(id)
	return ""
func _node_entry(node_id:String)->Dictionary:
	for group in ["cities","logic_nodes"]:
		for entry in layout.get(group,[]):
			if entry.get("node_id","")==node_id:return entry
	return {}
func _find(group:String,id:String)->Dictionary:
	for entry in layout.get(group,[]):
		if entry.id==id:return entry
	return {}
func _formal_edge(a:String,b:String,type:String)->String:
	for e in _formal.board_edges:
		if ((e.a==a and e.b==b) or (e.a==b and e.b==a)) and str(e.route_type).to_lower()==type:return e.id
	return ""
func select_item(group:String,id:String)->void:
	selected_group=group;selected_id=id;_active_handle=-1;_refresh_inspector();_draw_selection();_draw_handles()
func transform_selected(at:Vector3,yaw:float,scale_value:float)->void:
	var e:=_find(selected_group,selected_id)
	if e.is_empty() or selected_group=="routes":return
	_push_undo();e.position=_array(_clamp_position(at));e.rotation_y=yaw;e.scale=clampf(scale_value,.1,10)
	_update_item_transform(e);_render_routes();_refresh_inspector();_draw_selection()
func bind_selected(node_id:String)->void:
	if selected_group not in ["cities","logic_nodes"]:return
	var e:=_find(selected_group,selected_id);var old_id:=str(e.get("node_id",""))
	if old_id==node_id:return
	var existing:=_node_entry(node_id)
	if not existing.is_empty():_message("绑定失败：这个正式 ID 已被其他对象使用。");_refresh_inspector();return
	if not _formal.board_nodes.has(node_id):_message("未知正式节点 ID。");return
	if (_formal.board_nodes[node_id].node_type=="CITY")!=(selected_group=="cities"):_message("城市与普通停靠点不能互换身份。");return
	_push_undo();e.node_id=node_id
	if selected_group=="cities":e.city_id=node_id
	for route in layout.routes:
		if route.from_node==old_id:route.from_node=node_id
		if route.to_node==old_id:route.to_node=node_id
		route.edge_id=_formal_edge(route.from_node,route.to_node,route.type)
	_render_document();_message("身份已更新。相连路线重新匹配正式边；导出时会校验连接。")
func add_route(from_node:String,to_node:String,type:String,points:Array=[])->String:
	if from_node==to_node or _node_entry(from_node).is_empty() or _node_entry(to_node).is_empty():_message("请连接两个已放置、不同的逻辑节点。");return ""
	for route in layout.routes:
		if [from_node,to_node].has(route.from_node) and [from_node,to_node].has(route.to_node) and route.type==type:_message("这条路线已存在。");select_item("routes",route.id);return ""
	_push_undo();var id:=_id("route");var edge_id:=_formal_edge(from_node,to_node,type)
	layout.routes.append({"id":id,"edge_id":edge_id,"from_node":from_node,"to_node":to_node,"type":type,"points":points.duplicate(true)})
	_render_routes();_refresh_lists();select_item("routes",id)
	_message("路线已创建。每条正式边仍为原规则的一步；折点仅改变外观。" if not edge_id.is_empty() else "草稿连线已创建，但它不是已确认的正式边；游戏导出将拒绝，规则未改变。")
	return id
func set_route_points(id:String,points:Array)->void:
	var route:=_find("routes",id)
	if route.is_empty():return
	_push_undo();route.points=points.duplicate(true);_active_handle=-1;_render_routes();_draw_handles();_refresh_inspector()
func delete_selected()->void:
	if selected_id.is_empty():return
	if selected_group=="routes" and _active_handle>=0:_delete_handle();return
	var e:=_find(selected_group,selected_id)
	if e.is_empty():return
	_push_undo();var removed:=0
	if selected_group in ["cities","logic_nodes"]:
		for i in range(layout.routes.size()-1,-1,-1):
			if layout.routes[i].from_node==e.node_id or layout.routes[i].to_node==e.node_id:layout.routes.remove_at(i);removed+=1
	layout[selected_group].erase(e);selected_id="";selected_group="";_render_document()
	_message("已删除对象%s。Ctrl+Z 可恢复。"%("及 %d 条相连路线"%removed if removed>0 else ""))
func duplicate_selected()->void:
	if selected_group!="decorations":_message("复制仅用于纯装饰物，避免重复逻辑身份。");return
	var source:=_find(selected_group,selected_id)
	_push_undo();var e:=source.duplicate(true);e.id=_id("decor");e.position=_array(_clamp_position(_vec(e.position)+Vector3(.6,0,.6)));layout.decorations.append(e)
	_render_item("decorations",e);_refresh_lists();select_item("decorations",e.id)

func _render_document()->void:
	_clear(_objects);_instances.clear();_bounds.clear()
	for group in ["cities","logic_nodes","decorations"]:
		for e in layout.get(group,[]):_render_item(group,e)
	_render_routes();_refresh_lists();_refresh_inspector();_draw_selection();_draw_handles()
	set_night(bool(layout.get("visual_settings",{}).get("night",false)))
func _render_item(group:String,e:Dictionary)->void:
	var model:Node3D
	if group=="logic_nodes":
		model=Node3D.new();var disk:=MeshInstance3D.new();var mesh:=CylinderMesh.new();mesh.top_radius=.18;mesh.bottom_radius=.23;mesh.height=.10;mesh.radial_segments=20;disk.mesh=mesh;disk.position.y=.06
		var node:Dictionary=_formal.board_nodes.get(e.node_id,{})
		disk.material_override=_material(Color("438fbc") if "SEA" in node.get("allowed_routes",[]) else Color("f1cf82"));model.add_child(disk)
	else:model=Catalog.create(str(e.asset_id))
	if model==null:_message("无法载入资产："+str(e.get("asset_id","")));return
	model.name=e.id;_objects.add_child(model);_instances[e.id]=model;_bounds[e.id]=_model_bounds(model)
	_update_item_transform(e)
	if group in ["cities","logic_nodes"]:
		var label:=Label3D.new();label.name="IdentityLabel";label.billboard=BaseMaterial3D.BILLBOARD_ENABLED;label.no_depth_test=true
		label.text=_node_name(e.node_id) if group=="cities" else e.node_id.replace("land_","L · ").replace("sea_","S · ")
		label.font_size=30 if group=="cities" else 20;label.pixel_size=.012;label.outline_size=5;label.modulate=Color("faf1d5");label.outline_modulate=Color("244b51")
		label.position.y=(_bounds[e.id] as AABB).end.y+.42
		model.add_child(label)
func _model_bounds(node:Node3D,tx:Transform3D=Transform3D.IDENTITY)->AABB:
	var result:=AABB();var started:=false
	if node is MeshInstance3D and node.mesh:result=tx*node.get_aabb();started=true
	for child in node.get_children():
		if child is Node3D:
			var a:=_model_bounds(child,tx*child.transform)
			if a.size.length_squared()>.0001:result=result.merge(a) if started else a;started=true
	return result if started else AABB(Vector3(-.2,0,-.2),Vector3(.4,.2,.4))
func _update_item_transform(e:Dictionary)->void:
	if not _instances.has(e.id):return
	var node:Node3D=_instances[e.id];node.position=_vec(e.position);node.rotation.y=float(e.get("rotation_y",0));node.scale=Vector3.ONE*float(e.get("scale",1))
func _node_name(id:String)->String:
	return GameData.get_node_display_name(_formal,id) if _formal.board_nodes.has(id) else id
func _node_position(id:String)->Vector3:
	var e:=_node_entry(id)
	if e.is_empty():return Vector3.INF
	var p:=_vec(e.position)
	# City placement is the model pivot; its logical doorstep follows its rotation/scale.
	if e.has("city_id"):
		var entrance:Vector3=_instances[e.id].get_meta("entrance",Vector3(0,0,1.22)) if _instances.has(e.id) else Vector3(0,0,1.22)
		p+=Basis(Vector3.UP,float(e.get("rotation_y",0)))*(entrance*float(e.get("scale",1)))
	return p
func _route_positions(route:Dictionary)->PackedVector3Array:
	var points:=PackedVector3Array();var a:=_node_position(route.from_node);var b:=_node_position(route.to_node)
	if not a.is_finite() or not b.is_finite():return points
	points.append(a+Vector3(0,.08,0))
	for p in route.get("points",[]):points.append(_vec(p)+Vector3(0,.08,0))
	points.append(b+Vector3(0,.08,0));return points
func _render_routes()->void:
	_clear(_routes)
	for route in layout.get("routes",[]):
		var points:=_route_positions(route)
		if points.size()<2:continue
		var selected:bool=selected_group=="routes" and selected_id==route.id
		var mesh:=ImmediateMesh.new();mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		var half:=.065 if selected else .043
		for i in range(points.size()-1):
			var a:=points[i];var b:=points[i+1];var right:=Vector3(-(b.z-a.z),0,b.x-a.x).normalized()*half
			for v in [a-right,b-right,a+right,a+right,b-right,b+right]:mesh.surface_add_vertex(v)
		mesh.surface_end();var line:=MeshInstance3D.new();line.mesh=mesh;line.name=route.id;line.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var color:=Color("269eaa") if route.type=="sea" else Color("a6743e")
		if route.get("edge_id","").is_empty():color=Color("c77e79")
		if selected:color=Color("078c99")
		var mat:=_material(color,true);mat.cull_mode=BaseMaterial3D.CULL_DISABLED;line.material_override=mat;_routes.add_child(line)
	_draw_handles()
func _draw_handles()->void:
	_clear(_handles)
	if selected_group!="routes":return
	var route:=_find("routes",selected_id)
	for i in range(route.get("points",[]).size()):
		var node:=MeshInstance3D.new();var sphere:=SphereMesh.new();sphere.radius=.14;sphere.height=.28;sphere.radial_segments=12;sphere.rings=6;node.mesh=sphere;node.position=_vec(route.points[i])+Vector3(0,.18,0);node.material_override=_material(Color("f6c36b") if i==_active_handle else Color("17b7bc"),true);_handles.add_child(node)
func _draw_selection()->void:
	_selection.mesh=null
	if not _instances.has(selected_id):return
	var node:Node3D=_instances[selected_id];var box:AABB=_bounds[selected_id];var points:=[Vector3(box.position.x,0,box.position.z),Vector3(box.end.x,0,box.position.z),Vector3(box.end.x,0,box.end.z),Vector3(box.position.x,0,box.end.z)]
	var mesh:=ImmediateMesh.new();mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(4):
		var a:Vector3=node.transform*points[i];var b:Vector3=node.transform*points[(i+1)%4];a.y+=.1;b.y+=.1;mesh.surface_add_vertex(a);mesh.surface_add_vertex(b)
	mesh.surface_end();_selection.mesh=mesh
func _refresh_lists()->void:
	_object_list.clear()
	for group in ["cities","logic_nodes","routes","decorations"]:
		for e in layout.get(group,[]):
			var text:String=("城 · "+_node_name(e.node_id)) if group=="cities" else (("点 · "+str(e.node_id)) if group=="logic_nodes" else (("路 · "+str(e.from_node)+" → "+str(e.to_node)) if group=="routes" else "景 · "+str(_asset_description(e.asset_id).get("label",e.asset_id))))
			var index:=_object_list.add_item(text);_object_list.set_item_metadata(index,[group,e.id])
			if e.id==selected_id:_object_list.select(index)
	_stats_label.text="城市 %d / 16    停靠点 %d / 38\n路线 %d / 57    装饰 %d"%[layout.cities.size(),layout.logic_nodes.size(),layout.routes.size(),layout.decorations.size()]
	_path_label.text="保存位置：\n"+ProjectSettings.globalize_path(_current_path)
func _on_list_selected(index:int)->void:
	var data:Array=_object_list.get_item_metadata(index);select_item(data[0],data[1]);_set_mode("select")
func _refresh_inspector()->void:
	_updating=true
	var e:=_find(selected_group,selected_id)
	_properties.visible=not e.is_empty() and selected_group!="routes"
	_route_properties.visible=selected_group=="routes"
	_binding_box.visible=selected_group in ["cities","logic_nodes"]
	if e.is_empty():
		_selected_label.text="尚未选中对象";_binding_box.hide();_properties.hide();_route_properties.hide();_bind.clear();_node_info.text="";_updating=false;return
	_selected_label.text=("路线\n"+str(e.get("from_node",""))+" → "+str(e.get("to_node",""))) if selected_group=="routes" else str(_asset_description(e.get("asset_id","")).get("label","逻辑停靠点"))
	if selected_group!="routes":
		for i in range(3):_position_inputs[i].value=float(e.position[i])
		_yaw_input.value=rad_to_deg(float(e.get("rotation_y",0)));_scale_input.value=float(e.get("scale",1))
	if selected_group in ["cities","logic_nodes"]:
		_bind.clear()
		for id in _formal.board_nodes:
			if (_formal.board_nodes[id].node_type=="CITY")!=(selected_group=="cities"):continue
			var used:bool=not _node_entry(id).is_empty() and _node_entry(id).id!=selected_id
			_bind.add_item(_node_name(id)+" · "+id+(" [已用]" if used else ""));var idx:=_bind.item_count-1;_bind.set_item_metadata(idx,id);_bind.set_item_disabled(idx,used)
			if e.node_id==id:_bind.select(idx)
		_node_info.text="node_id: "+e.node_id+"\n"+("city_id: "+e.city_id if selected_group=="cities" else "普通停靠点 · 参与玩法")
	elif selected_group=="routes":
		_route_type.select(1 if e.type=="sea" else 0)
		_selected_label.text+="\n%d 个折点 · %s"%[e.get("points",[]).size(),"正式连接" if not e.get("edge_id","").is_empty() else "未匹配正式边"]
	_updating=false
func _transform_from_inspector()->void:
	if _updating:return
	transform_selected(Vector3(_position_inputs[0].value,_position_inputs[1].value,_position_inputs[2].value),deg_to_rad(_yaw_input.value),_scale_input.value)
func _binding_changed(index:int)->void:
	if not _updating:bind_selected(_bind.get_item_metadata(index))
func _change_route_type(index:int)->void:
	if _updating:return
	var route:=_find("routes",selected_id)
	if route.is_empty():return
	_push_undo();route.type="sea" if index==1 else "land";route.edge_id=_formal_edge(route.from_node,route.to_node,route.type);_render_routes();_refresh_inspector()
func _rotate_selected(degrees:float)->void:
	var e:=_find(selected_group,selected_id)
	if e.is_empty() or selected_group=="routes":return
	transform_selected(_vec(e.position),float(e.get("rotation_y",0))+deg_to_rad(degrees),float(e.get("scale",1)))
func _scale_selected(multiplier:float)->void:
	var e:=_find(selected_group,selected_id)
	if e.is_empty() or selected_group=="routes":return
	transform_selected(_vec(e.position),float(e.get("rotation_y",0)),float(e.get("scale",1))*multiplier)
func _delete_handle()->void:
	if selected_group!="routes" or _active_handle<0:return
	var e:=_find("routes",selected_id)
	if _active_handle>=e.points.size():return
	var points:Array=e.points.duplicate(true);points.remove_at(_active_handle);set_route_points(selected_id,points)
func _set_mode(value:String)->void:
	_mode=value;_connect_from="";_dragging=false;_drag_handle=-1
	var labels:={"select":"选择：左拖移动对象","place":"放置："+str(_asset_description(_asset_to_place).get("label",_asset_to_place)),"node":"停靠点：点画布放置，再绑定 ID","route":"连线：依次点击起点与终点","point":"折点：在画布点击插入"}
	_mode_label.text=labels.get(value,value)
	canvas.mouse_default_cursor_shape=Control.CURSOR_CROSS if value!="select" else Control.CURSOR_ARROW
func _clamp_position(p:Vector3)->Vector3:return Vector3(clampf(p.x,-30,30),clampf(p.y,-5,20),clampf(p.z,-10,10))
func _snap_position(p:Vector3)->Vector3:
	return Vector3(snappedf(p.x,.25),p.y,snappedf(p.z,.25)) if _snap.button_pressed else p
func _world_to_canvas(p:Vector3)->Vector2:return camera.unproject_position(p)
func _screen_to_ground(screen:Vector2)->Vector3:
	var origin:=camera.project_ray_origin(screen);var direction:=camera.project_ray_normal(screen)
	if absf(direction.y)<.0001:return Vector3.INF
	return origin+direction*(-origin.y/direction.y)
func _pick_node(screen:Vector2)->String:
	var best:=28.0;var result:=""
	for group in ["cities","logic_nodes"]:
		for e in layout[group]:
			var distance:=screen.distance_to(_world_to_canvas(_node_position(e.node_id)+Vector3(0,.08,0)))
			if distance<best:best=distance;result=e.node_id
	if result.is_empty():
		var hit:=_pick_object(screen)
		if hit.get("group","") in ["cities","logic_nodes"]:result=_find(hit.group,hit.id).node_id
	return result
func _pick_object(screen:Vector2)->Dictionary:
	var origin:=camera.project_ray_origin(screen);var direction:=camera.project_ray_normal(screen)
	var nearest:=INF;var found:={}
	for group in ["logic_nodes","cities","decorations"]:
		for e in layout[group]:
			if not _instances.has(e.id):continue
			var node:Node3D=_instances[e.id];var tx:=node.global_transform.affine_inverse();var box:AABB=_bounds[e.id]
			var hit:Variant=box.grow(.1).intersects_ray(tx*origin,tx.basis*direction)
			if hit!=null:
				var distance:=origin.distance_to(node.global_transform*(hit as Vector3))
				if distance<nearest:nearest=distance;found={"group":group,"id":e.id}
	if not found.is_empty():return found
	var distance:=10.0
	for route in layout.routes:
		var points:=_route_positions(route)
		for i in range(points.size()-1):
			var d:=screen.distance_to(Geometry2D.get_closest_point_to_segment(screen,_world_to_canvas(points[i]),_world_to_canvas(points[i+1])))
			if d<distance:distance=d;found={"group":"routes","id":route.id}
	return found
func _pick_handle(screen:Vector2)->int:
	if selected_group!="routes":return -1
	var e:=_find("routes",selected_id);var best:=13.0;var index:=-1
	for i in range(e.get("points",[]).size()):
		var d:=screen.distance_to(_world_to_canvas(_vec(e.points[i])+Vector3(0,.18,0)))
		if d<best:best=d;index=i
	return index
func _insert_route_point(screen:Vector2)->void:
	var e:=_find("routes",selected_id)
	if e.is_empty():_message("先选中一条路线。");_set_mode("select");return
	var points:=_route_positions(e);var best:=INF;var segment:=0
	for i in range(points.size()-1):
		var d:=screen.distance_to(Geometry2D.get_closest_point_to_segment(screen,_world_to_canvas(points[i]),_world_to_canvas(points[i+1])))
		if d<best:best=d;segment=i
	var controls:Array=e.get("points",[]).duplicate(true);controls.insert(segment,_array(_clamp_position(_snap_position(_screen_to_ground(screen)))));set_route_points(selected_id,controls);_active_handle=segment;_draw_handles();_set_mode("select")

func _canvas_input(event:InputEvent)->void:
	if event is InputEventMouseButton:
		var at:Vector2=event.position
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN] and event.pressed:
			var before:=_screen_to_ground(at);_camera_fit=false;_camera_size=clampf(_camera_size*(.87 if event.button_index==MOUSE_BUTTON_WHEEL_UP else 1.15),4,100);_apply_camera();var after:=_screen_to_ground(at);_camera_target+=before-after;_apply_camera();canvas.accept_event();return
		if event.button_index in [MOUSE_BUTTON_RIGHT,MOUSE_BUTTON_MIDDLE]:
			_pan=event.pressed;_orbit=event.alt_pressed;_previous=at;canvas.accept_event();return
		if event.button_index!=MOUSE_BUTTON_LEFT:return
		if not event.pressed:
			_dragging=false;_drag_handle=-1;_drag_started=false;canvas.accept_event();return
		canvas.grab_focus();_press=at;_previous=at
		var ground:=_screen_to_ground(at)
		if _mode=="place":add_asset(_asset_to_place,_snap_position(ground));_set_mode("select");canvas.accept_event();return
		if _mode=="node":add_logic_node("",_snap_position(ground));_set_mode("select");canvas.accept_event();return
		if _mode=="point":_insert_route_point(at);canvas.accept_event();return
		if _mode=="route":
			var node_id:=_pick_node(at)
			if node_id.is_empty():_message("请点城市建筑或逻辑停靠点，装饰不能连接路线。");return
			if _connect_from.is_empty():_connect_from=node_id;_mode_label.text="起点："+_node_name(node_id)+" · 请点击终点"
			else:add_route(_connect_from,node_id,"sea" if _route_default.selected==1 else "land");_set_mode("select")
			canvas.accept_event();return
		var handle:=_pick_handle(at)
		if handle>=0:
			_active_handle=handle;_drag_handle=handle;_dragging=true;_drag_started=false;_draw_handles();canvas.accept_event();return
		var pick:=_pick_object(at)
		if pick.is_empty():select_item("","");canvas.accept_event();return
		select_item(pick.group,pick.id)
		if pick.group=="routes":
			_render_routes()
			if event.double_click:_insert_route_point(at)
		else:
			_dragging=true;_drag_started=false;_grab_offset=_vec(_find(selected_group,selected_id).position)-ground
		canvas.accept_event()
	elif event is InputEventMouseMotion:
		if _pan:
			_camera_fit=false
			if _orbit:_camera_yaw-=(event.position.x-_previous.x)*.007;_camera_pitch=clampf(_camera_pitch+(event.position.y-_previous.y)*.005,deg_to_rad(25),deg_to_rad(85))
			else:_camera_target+=_screen_to_ground(_previous)-_screen_to_ground(event.position)
			_previous=event.position;_apply_camera();canvas.accept_event()
		elif _dragging and event.position.distance_to(_press)>3:
			if not _drag_started:_push_undo();_drag_started=true
			var ground:=_clamp_position(_snap_position(_screen_to_ground(event.position)))
			if _drag_handle>=0:
				var route:=_find("routes",selected_id);route.points[_drag_handle]=_array(ground);_render_routes()
			else:
				var e:=_find(selected_group,selected_id);ground=_clamp_position(_snap_position(_screen_to_ground(event.position)+_grab_offset));ground.y=float(e.position[1]);e.position=_array(ground);_update_item_transform(e);_render_routes();_draw_selection();_refresh_inspector()
			canvas.accept_event()
	elif event is InputEventMagnifyGesture:
		_camera_fit=false;_camera_size=clampf(_camera_size/event.factor,4,100);_apply_camera();canvas.accept_event()

func _canvas_resized()->void:
	if is_instance_valid(camera):
		if _camera_fit:fit_canvas()
		else:_apply_camera()
func fit_canvas()->void:
	_camera_fit=true;_camera_yaw=deg_to_rad(-7);_camera_pitch=deg_to_rad(58);_camera_target=Vector3.ZERO
	_camera_size=maxf(24,66/maxf(canvas.size.x/maxf(canvas.size.y,1),.3));_apply_camera()
func focus_selected()->void:
	if not _instances.has(selected_id):return
	_camera_fit=false;_camera_target=_instances[selected_id].position+Vector3(0,.8,0);_camera_size=9;_apply_camera()
func _apply_camera()->void:
	if not is_instance_valid(camera) or not camera.is_inside_tree():return
	_camera_target.x=clampf(_camera_target.x,-35,35);_camera_target.z=clampf(_camera_target.z,-16,16)
	camera.size=_camera_size;var direction:=Vector3(sin(_camera_yaw)*cos(_camera_pitch),sin(_camera_pitch),cos(_camera_yaw)*cos(_camera_pitch));camera.look_at_from_position(_camera_target+direction*70,_camera_target)
func set_night(value:bool)->void:
	if layout!=null:layout.visual_settings["night"]=value
	if is_instance_valid(_night_toggle):_night_toggle.set_pressed_no_signal(value)
	if _environment==null:return
	_environment.background_color=Color("182b3f") if value else Color("dbe1d8")
	_environment.ambient_light_color=Color("82a8cf") if value else Color("e0e8dc")
	_environment.ambient_light_energy=.34 if value else .28
	_sun.light_color=Color("93b9ef") if value else Color("fff0d9");_sun.light_energy=.35 if value else .60
	_fill.light_color=Color("789acb") if value else Color("c5e2e4");_fill.light_energy=.07 if value else .10
	for node in _instances.values():Catalog.set_night(node,value)

func save_document(path:String)->Dictionary:
	_sync_visual_settings();var result:Dictionary=Store.save_layout(path,layout)
	if result.ok:_current_path=path;_dirty=false;_refresh_lists();_message("已保存："+ProjectSettings.globalize_path(path))
	else:_show_error("保存失败",result)
	return result
func load_document_file(path:String)->Dictionary:
	var result:Dictionary=Store.load_layout(path)
	if result.ok:
		load_document(result.data);_current_path=path;_dirty=false;_refresh_lists();_restore_visual_settings();_message("已加载："+ProjectSettings.globalize_path(path))
	else:_show_error("加载失败，当前草稿保留",result)
	return result
func export_document(path:String)->Dictionary:
	_sync_visual_settings();var result:Dictionary=Store.export_for_game(layout,path)
	if result.ok:_export_path=path;_message("已导出正式游戏布局。可点击「试玩导出」带 HUD 检查。")
	else:_show_error("尚不能导出正式游戏",result)
	return result
func _sync_visual_settings()->void:
	layout.visual_settings.merge({"camera_yaw":_camera_yaw,"camera_pitch":_camera_pitch,"camera_size":_camera_size,"camera_target":_array(_camera_target)},true)
func _restore_visual_settings()->void:
	var s:Dictionary=layout.visual_settings;_camera_yaw=float(s.get("camera_yaw",-.12));_camera_pitch=float(s.get("camera_pitch",deg_to_rad(58)));_camera_size=float(s.get("camera_size",29));_camera_target=_vec(s.get("camera_target",[0,0,0]));_camera_fit=false;_apply_camera()
func _open_file_dialog(action:String)->void:
	if action=="export":
		var check:Dictionary=Store.validate(layout,true)
		if not check.ok:_show_error("布局仍是草稿，可先保存",check);return
	_file_action=action;_file_dialog.file_mode=FileDialog.FILE_MODE_OPEN_FILE if action=="load" else FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.title={"load":"打开地图布局","save":"保存地图布局","export":"导出正式游戏布局"}[action]
	var path:=ProjectSettings.globalize_path(_export_path if action=="export" else _current_path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir());_file_dialog.current_dir=path.get_base_dir();_file_dialog.current_file=path.get_file();_file_dialog.popup_centered_ratio(.8)
func _file_selected(path:String)->void:
	if _file_action=="load":load_document_file(path)
	elif _file_action=="save":save_document(path)
	else:export_document(path)
func _show_error(title:String,result:Dictionary)->void:
	var issues:PackedStringArray=[]
	for error in result.get("errors",[]):
		if issues.size()<10:issues.append(str(error))
	if result.get("errors",[]).size()>10:issues.append("另有 %d 项，请完成 ID 和连接后再次检查。"%(result.errors.size()-10))
	_message_dialog.title=title;_message_dialog.dialog_text="\n".join(issues)+"\n\n草稿可以保存。需要完整起稿时，使用「正式数据起稿」。";_message_dialog.popup_centered();_message(title)
func _show_validation()->void:
	var result:Dictionary=Store.validate(layout,true)
	if result.ok:_message_dialog.title="正式布局检查通过";_message_dialog.dialog_text="16 座城市、54 个节点、57 条正式边完整。\n装饰与折点均不计入游戏节点。\n可以导出并带 HUD 试玩。";_message_dialog.popup_centered()
	else:_show_error("布局检查",result)
func _launch_game_preview()->void:
	if not FileAccess.file_exists(_export_path):_message("请先完成「导出游戏」。样板草稿可保存，但不能替代完整正式地图。");return
	var args:=PackedStringArray(["--path",ProjectSettings.globalize_path("res://"),"res://scenes/editor/map_game_preview.tscn","--","--layout="+ProjectSettings.globalize_path(_export_path)])
	var pid:=OS.create_instance(args);_message("已启动独立正式游戏试玩窗口。" if pid>0 else "无法启动试玩窗口，请在 Godot 运行 map_game_preview.tscn。")
func _message(text:String)->void:
	if is_instance_valid(_status):_status.text="  "+text
func _unhandled_key_input(event:InputEvent)->void:
	if not event is InputEventKey or not event.pressed or event.echo:return
	var focus:=get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:return
	if _file_dialog.visible or _message_dialog.visible:return
	var command:bool=event.ctrl_pressed or event.meta_pressed
	if command and event.keycode==KEY_S:save_document(_current_path)
	elif command and event.keycode==KEY_Z:
		if event.shift_pressed:redo_edit()
		else:undo_edit()
	elif command and event.keycode==KEY_Y:redo_edit()
	elif command and event.keycode==KEY_D:duplicate_selected()
	elif event.keycode==KEY_ESCAPE:_set_mode("select")
	elif event.keycode in [KEY_DELETE,KEY_BACKSPACE]:delete_selected()
	elif event.keycode==KEY_R:fit_canvas()
	elif event.keycode==KEY_F:focus_selected()
	elif event.keycode==KEY_Q:_rotate_selected(-15)
	elif event.keycode==KEY_E:_rotate_selected(15)
	elif event.keycode in [KEY_EQUAL,KEY_PLUS]:_scale_selected(1.1)
	elif event.keycode==KEY_MINUS:_scale_selected(1.0/1.1)
	elif event.keycode==KEY_N:set_night(not _night_toggle.button_pressed)
	else:return
	get_viewport().set_input_as_handled()
func _capture_initial()->void:
	get_window().size=Vector2i(1600,1000)
	for i in range(20):await get_tree().process_frame
	var directory:="res://docs/reports/map-editor/captures/";DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	await RenderingServer.frame_post_draw;get_viewport().get_texture().get_image().save_png(directory+"editor-overview-day.png")
	select_item("cities","sample_baghdad");focus_selected()
	for i in range(12):await get_tree().process_frame
	await RenderingServer.frame_post_draw;get_viewport().get_texture().get_image().save_png(directory+"editor-city-day.png")
	set_night(true)
	for i in range(12):await get_tree().process_frame
	await RenderingServer.frame_post_draw;get_viewport().get_texture().get_image().save_png(directory+"editor-city-night.png")
	set_night(false);fit_canvas()
	if "--quit-after-capture" in OS.get_cmdline_user_args():get_tree().quit()

func _input(event:InputEvent)->void:
	# A release over a side panel must end a canvas drag too.
	if event is InputEventMouseButton and not event.pressed:
		if event.button_index==MOUSE_BUTTON_LEFT:_dragging=false;_drag_handle=-1;_drag_started=false
		elif event.button_index in [MOUSE_BUTTON_RIGHT,MOUSE_BUTTON_MIDDLE]:_pan=false;_orbit=false
