extends Node
## Map-first shell. Existing editors retain their real handlers and data guards.
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
var h: Control
var status: Button
var more: PopupMenu
var collapse: Button
var tool_buttons: Array[Button] = []
var collapsed := false
var docked: Control
var _last_dock: Control
var _hidden_dock: Control
var _trace_at:=0
var mode_label:Label
var select_button:Button
var route_button:Button
var save_status:Label
var stage_height:=1080.0
func setup(host: Control) -> void:
 h = host
 for name in ["LegacyTop", "LegacyTopActions", "LegacyBottom"]:
  var old:Node=h._stage.get_node_or_null(name)
  if old is CanvasItem:old.hide()
 var top:=Panel.new();top.name="V02Header";top.position=Vector2.ZERO;top.size=Vector2(1920,76);top.add_theme_stylebox_override("panel",Kit.satchel_box(0,0,0));h._stage.add_child(top)
 var title:=Kit.label("L叔 · 资源工坊",28,Kit.INK,"body",700);title.position=Vector2(24,20);top.add_child(title)
 h._name_pill.reparent(top);h._name_pill.position=Vector2(248,12);h._name_pill.size=Vector2(400,50);h._name_pill.custom_minimum_size=Vector2(300,48);h._name_pill.icon=_icon("scroll");h._name_pill.clip_text=true
 mode_label=Kit.label("原版规则 · 路程保持",20,Kit.INK_SOFT);mode_label.position=Vector2(672,24);mode_label.size=Vector2(430,32);top.add_child(mode_label);mode_label.position.y=42;mode_label.add_theme_font_size_override("font_size",21)
 save_status=Kit.label("● 未保存",21,Kit.INK);save_status.position=Vector2(672,12);save_status.size=Vector2(430,24);top.add_child(save_status)
 var x:=1120.0
 for key:String in ["undo","redo","open","save"]:
  var b:Button=h._btn[key];b.reparent(top);b.icon=_icon(key) if key!="open" else null;b.custom_minimum_size=Vector2(92,48);b.size=Vector2(92,48);b.position=Vector2(x,12);Kit.style_button(b,"cream",48,21);_fit_button(b,Vector2(92,48));x+=102
 h._playtest_button.reparent(top);h._playtest_button.text="试玩";h._playtest_button.icon=_icon("play");h._playtest_button.custom_minimum_size=Vector2(160,48);h._playtest_button.size=Vector2(160,48);h._playtest_button.position=Vector2(1640,12);Kit.style_button(h._playtest_button,"primary",48,23)
 var menu:=Kit.button("⋯","cream",48,26);menu.position=Vector2(1810,12);menu.size=Vector2(70,48);top.add_child(menu)
 more=PopupMenu.new();more.add_item("另存为",0);more.add_item("装进游戏",1);more.add_separator();more.add_item("从原版重新开始",2);more.add_separator();more.add_item("新建原版兼容地图",4);more.add_item("将当前原版转为自由副本",5);menu.add_child(more)
 more.add_theme_font_override("font",Kit.font("body",500));more.add_theme_font_size_override("font_size",22);more.add_theme_color_override("font_color",Kit.INK);more.add_theme_color_override("font_hover_color",Kit.INK);more.add_theme_constant_override("v_separation",14);more.add_theme_stylebox_override("panel",Kit.satchel_box(12,2,12))
 more.id_pressed.connect(func(id:int)->void:
  match id:
   0:h._on_save_as()
   1:h._on_import()
   2:h._on_reset()
   4:h._on_new_compatible_map()
   5:h._enter_free_author()
 )
 menu.pressed.connect(func()->void:more.position=Vector2i(menu.global_position+Vector2(0,menu.size.y));more.popup())
 for key:String in ["reset","save_as","import"]:h._btn[key].hide()
 var rail:=Panel.new();rail.name="V02ToolRail";rail.position=Vector2(0,76);rail.size=Vector2(88,952);rail.add_theme_stylebox_override("panel",Kit.satchel_box(0,0,0));h._stage.add_child(rail)
 var select:=Kit.button("选择","cream",58,19);select.position=Vector2(6,16);select.size=Vector2(76,58);rail.add_child(select);_fit_button(select,Vector2(76,58));select.pressed.connect(select_mode)
 select_button=select;tool_buttons.append(select);_tool_visual(select,"select")
 var y:=88.0
 for entry:Array in [[h._add_btn,"加城"],[null,"路线"],[h._landscape_button,"地形"],[h._plant_button,"植物"],[h._asset_button,"素材"],[h._intro_button,"城市卡"],[h._piece_button,"棋子"]]:
  var b:Button=entry[0]
  if b==null:
   b=Kit.button("路线","cream",58,19);b.pressed.connect(route_mode);route_button=b
   rail.add_child(b)
  else:b.reparent(rail);b.pressed.connect(_normal_pick_mode)
  b.text=str(entry[1]);b.icon=null;b.custom_minimum_size=Vector2(76,58);b.size=Vector2(76,58);b.position=Vector2(6,y);Kit.style_button(b,"cream",58,19);_fit_button(b,Vector2(76,58));b.tooltip_text=str(entry[1]);tool_buttons.append(b);_tool_visual(b,{"加城":"city","路线":"route","地形":"terrain","植物":"plant","素材":"assets","城市卡":"card","棋子":"piece"}[str(entry[1])]);y+=72
 var library:=Kit.button("资源库","cream",58,19);library.position=Vector2(6,y);library.size=Vector2(76,58);rail.add_child(library);_fit_button(library,Vector2(76,58));tool_buttons.append(library);_tool_visual(library,"scroll");h._asset_library_button=library;library.pressed.connect(func()->void:h._asset_library.open_tools())
 h._add_caption.get_parent().hide()
 var jw:Control=h._stage.get_node_or_null("JWPairButton")
 if jw!=null:jw.hide()
 var bottom:=Panel.new();bottom.name="V02StatusBar";bottom.position=Vector2(88,1028);bottom.size=Vector2(1832,52);bottom.add_theme_stylebox_override("panel",Kit.satchel_box(0,0,0));h._stage.add_child(bottom)
 x=16
 for key:String in ["view_all","zoom_out","zoom_in"]:
  var b:Button=h._btn[key];b.reparent(bottom);b.custom_minimum_size=Vector2(80 if key=="view_all" else 44,38);b.size=b.custom_minimum_size;b.position=Vector2(x,7);Kit.style_button(b,"cream",38,18);_fit_button(b,Vector2(80 if key=="view_all" else 44,38));x+=b.size.x+8
 h._hint.reparent(bottom);h._hint.position=Vector2(230,9);h._hint.size=Vector2(1010,36);h._hint.custom_minimum_size=Vector2.ZERO;h._hint.max_lines_visible=2;h._hint.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;h._hint.clip_text=false;h._hint.add_theme_font_size_override("font_size",21)
 status=Kit.button("检查地图","cream",38,18);status.position=Vector2(1260,7);status.size=Vector2(330,38);bottom.add_child(status);status.pressed.connect(_show_first_problem)
 collapse=Kit.button("收起属性 ›","cream",38,18);collapse.position=Vector2(1630,7);collapse.size=Vector2(186,38);bottom.add_child(collapse);collapse.pressed.connect(toggle_dock)
 h._find_button.position=Vector2(116,94);h._stop_search_button.position=Vector2(430,94)
 h._find_button.custom_minimum_size.y=46;h._stop_search_button.custom_minimum_size.y=46
 for node:Control in [top,rail,bottom]:h._stage.move_child(node,h._stage.get_children().find(h._welcome))
 _mode_style()
func _normal_pick_mode()->void:
 h.board.route_pick_preferred=false;_mode_style()
func select_mode() -> void:
 if h.board==null:return
 if is_instance_valid(h._asset_library) and h._asset_library.visible:h._asset_library.close_tools()
 _normal_pick_mode()
 h._commit_edits();h._end_landscape();h._end_placement()
 h._plant_tools.close_tools();h._piece_tools.close_tools();h._intro_tools.close_tools();
 if h._route_editor!=null and is_instance_valid(h._route_editor.tool_panel):h._route_editor.tool_panel.hide()
 h._local_assets.cancel();h._local_assets.hide();h.drawers.close();h._landscape_tools.hide();h._chooser.hide();h.panel.show()
func route_mode()->void:
 select_mode();h.board.route_pick_preferred=true;_mode_style()
 h.board._clear_city_hover()
 if h.board.sel.kind=="city":h.board.clear_workshop_selection()
 h.say("路线工具：点连线或金币选择路线；城市名牌不会遮住连线。")
func _mode_style()->void:
 if h.board==null:return
 var preferred:bool=h.board.route_pick_preferred
 var states:Array=[not preferred, h._chooser.visible or h.board.placement_mode,preferred,_tool_active(h._landscape_tools),_tool_active(h._plant_tools),_tool_active(h._local_assets),_tool_active(h._intro_tools),_tool_active(h._piece_tools),h._asset_library.visible]
 for i in tool_buttons.size():
  var selected:bool=bool(states[i])
  if i==0 and (states[1] or states[3] or states[4] or states[5] or states[6] or states[7] or states[8]):selected=false
  _select_style(tool_buttons[i],selected)
func toggle_dock() -> void:
 if collapsed:
  collapsed=false
  if is_instance_valid(_hidden_dock):_hidden_dock.show()
  _hidden_dock=null
 else:
  collapsed=true;_hidden_dock=docked
 collapse.text="‹ 展开属性" if collapsed else "收起属性 ›";h._layout()
func board_rect() -> Rect2:
 return Rect2(88,76,1832 if collapsed else 1432,stage_height-160)
func _process(_delta:float) -> void:
 if h==null or h.board==null:return
 _mode_style()
 for button:Button in tool_buttons:button.modulate.a=0.5 if button.disabled else 1.0
 for button:Button in [h._btn.undo,h._btn.redo,h._playtest_button]:button.modulate.a=0.5 if button.disabled else 1.0
 var path:=OS.get_environment("SILKROAD_UI_STATE_PATH")
 if path!="" and Time.get_ticks_msec()-_trace_at>500:
  _trace_at=Time.get_ticks_msec()
  var f:=FileAccess.open(path,FileAccess.WRITE)
  var controls:Dictionary={}
  var routes:Dictionary={}
  for row:Dictionary in h.board.cur_layout.get("routes",[]):routes[str(row.id)]=h.board._to_view(h._route_editor._point_t(row.points,0.5))+h.board.global_position
  var buttons:Array=[]
  for node:Node in h._stage.find_children("*","Button",true,false):
   var button:=node as Button
   if button.is_visible_in_tree():
    var rect:=button.get_global_rect();buttons.append({"text":button.text,"disabled":button.disabled,"rect":[rect.position.x,rect.position.y,rect.size.x,rect.size.y]})
  if h._route_editor!=null:
   for key:String in h._route_editor._screen_handles():controls[key]=h._route_editor._screen_handles()[key]+h.board.global_position
  var inputs:Array=[]
  for node:Node in h._stage.find_children("*","LineEdit",true,false):
   var input:=node as LineEdit
   if input.is_visible_in_tree():
    var rect:=input.get_global_rect();inputs.append({"text":input.text,"rect":[rect.position.x,rect.position.y,rect.size.x,rect.size.y]})
  if f!=null:f.store_string(JSON.stringify({"piece_skins":h._piece_tools.observer() if is_instance_valid(h._piece_tools) else {},"asset_library":h._asset_library.observer(),"badges":h.board._city_plaque_runtime.diagnostics if h.board._city_plaque_runtime!=null else {},"badge_drag":h.board._badge_drag,"panel_badge_mode":h.panel._new_nodes.badge_mode.text if h.panel._new_nodes.has("badge_mode") else "","viewport_size":h.get_viewport().get_visible_rect().size,"board_transform":str(h.board.get_global_transform_with_canvas()),"document":h.doc.doc,"sha":h.doc.sha(),"selection":h.board.sel,"undo":h.history.undo_size(),"redo":h.history.redo_size(),"route_pick_preferred":h.board.route_pick_preferred,"route_drag":h._route_editor.drag if h._route_editor!=null else {},"route_edit":h._route_editor.edit if h._route_editor!=null else {},"controls":controls,"route_targets":routes,"buttons":buttons,"inputs":inputs,"dialog":h.dialogs.current_id(),"camera":h.board._target,"zoom":h.board.zoom_factor(),"issues":h.issues,"action_issues":h.action_issues,"hint":h._hint.text}))
 var candidate:Control=null
 var tools:Array=[h._connection_ui,h._landscape_tools,h._plant_tools,h._local_assets,h._intro_tools,h._piece_tools,h.drawers]
 if h._route_editor!=null and is_instance_valid(h._route_editor.tool_panel):tools.append(h._route_editor.tool_panel)
 for tool:Control in tools:
  if is_instance_valid(tool) and tool.visible:candidate=tool
 if collapsed and candidate!=null:
  _hidden_dock=candidate
 docked=candidate
 h.panel.visible=candidate==null and not collapsed
 if candidate!=null:
  candidate.position=Vector2(1520,76)
  if candidate!=_last_dock:_compact(candidate)
  candidate.size=Vector2(400,stage_height-160)
  candidate.visible=not collapsed
 _last_dock=candidate
 status.text="✓ 可试玩" if h.issues.is_empty() else "待完成 %d 处 · 定位"%h.issues.size()
 status.tooltip_text="原版地图：规则保持" if not h.doc.doc.has("free_routes") else "自由地图：原80牌保持原价，平衡需试玩"
 h._name_pill.text=h.doc.map_name()
 save_status.text="● 未保存" if h.doc.is_dirty() or not h.doc.ever_saved else "✓ 已保存到「我的地图」"
 if CustomMapFreeAuthor.enabled(h.doc.doc):
  mode_label.text="自由创作 · 新城 %d/4 · 平衡需试玩"%h.doc.new_city_count()
  return
 mode_label.text="规则：%s · 存到：%s" % ["自由" if h.doc.doc.has("free_routes") else "原版", h.doc.map_name() if h.doc.ever_saved else "新作品"]
 mode_label.tooltip_text="自由地图经济平衡需试玩" if h.doc.doc.has("free_routes") else "原版路程保持"
func _compact(node:Control) -> void:
 for child:Node in node.find_children("*","Label",true,false):
  var label:=child as Label
  if label!=null and label.text.length()>12:label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;label.custom_minimum_size.x=minf(label.custom_minimum_size.x,350)
 node.custom_minimum_size=Vector2(400,0);node.size=Vector2(400,stage_height-160)
 for child:Node in node.find_children("*","ScrollContainer",true,false):
  child.custom_minimum_size.y=0
 readable_fonts(node)

func _fit_button(b:Button,extent:Vector2)->void:
 for state:String in ["normal","hover","pressed","hover_pressed","disabled"]:
  var box:=b.get_theme_stylebox(state).duplicate() as StyleBox
  box.content_margin_left=5;box.content_margin_right=5
  b.add_theme_stylebox_override(state,box)
 b.custom_minimum_size=extent;b.size=extent

func _icon(name: String) -> Texture2D:
 return load("res://assets/game/ui/workshop_icons/"+name+".svg") as Texture2D
func _tool_visual(button: Button, name: String) -> void:
 button.icon=null;button.focus_mode=Control.FOCUS_ALL;button.add_theme_constant_override("outline_size",0)
 for color:String in ["font_color","font_hover_color","font_pressed_color","font_disabled_color","font_focus_color","font_hover_pressed_color"]:button.add_theme_color_override(color,Color.TRANSPARENT)
 var center:=CenterContainer.new();center.name="ToolVisual";center.mouse_filter=Control.MOUSE_FILTER_IGNORE;center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);button.add_child(center)
 var column:=VBoxContainer.new();column.mouse_filter=Control.MOUSE_FILTER_IGNORE;column.add_theme_constant_override("separation",2);center.add_child(column)
 var image:=TextureRect.new();image.texture=_icon(name);image.custom_minimum_size=Vector2(24,24);image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;image.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED;image.size_flags_horizontal=Control.SIZE_SHRINK_CENTER;image.mouse_filter=Control.MOUSE_FILTER_IGNORE;column.add_child(image)
 var text:=Kit.label(button.text,18,Kit.INK);text.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER;text.mouse_filter=Control.MOUSE_FILTER_IGNORE;column.add_child(text)
 var flag:=ColorRect.new();flag.name="SelectedFlag";flag.color=Kit.SATCHEL_DEEP;flag.position=Vector2(2,8);flag.size=Vector2(4,42);flag.mouse_filter=Control.MOUSE_FILTER_IGNORE;flag.visible=false;button.add_child(flag)
 var inset:=ColorRect.new();inset.name="SelectedInset";inset.color=Color(0.44,0.24,0.08,0.3);inset.position=Vector2(7,53);inset.size=Vector2(62,2);inset.mouse_filter=Control.MOUSE_FILTER_IGNORE;inset.visible=false;button.add_child(inset)
 button.mouse_entered.connect(func()->void:center.position.y=-1)
 button.mouse_exited.connect(func()->void:center.position.y=0)
func _select_style(button: Button, selected: bool) -> void:
 if bool(button.get_meta("tool_selected",false))==selected and button.has_meta("tool_selected"):return
 button.set_meta("tool_selected",selected)
 Kit.style_button(button,"primary" if selected else "cream",58,19);_fit_button(button,Vector2(76,58));button.focus_mode=Control.FOCUS_ALL
 # Kit styling updates colors; keep text semantics for accessibility while drawing the compact child label.
 for color:String in ["font_color","font_hover_color","font_pressed_color","font_disabled_color","font_focus_color","font_hover_pressed_color"]:button.add_theme_color_override(color,Color.TRANSPARENT)
 button.add_theme_constant_override("outline_size",0)
 button.get_node("SelectedFlag").visible=selected;button.get_node("SelectedInset").visible=selected

func _tool_active(tool: Control) -> bool:
 return tool.visible or (collapsed and _hidden_dock==tool)

func fit_height(height:float) -> void:
 stage_height=maxf(1080,height)
 h._stage.get_node("V02Header").size.y=76
 h._stage.get_node("V02ToolRail").size.y=stage_height-160
 var bottom:Control=h._stage.get_node("V02StatusBar")
 bottom.position.y=stage_height-84;bottom.size.y=84
 h._hint.position.y=8;h._hint.size.y=68
 status.position.y=22;collapse.position.y=22
 h.panel.fit_height(stage_height-160)
 h._welcome.size=Vector2(1920,stage_height)
 var dim:=h._welcome.get_child(0) as Control
 if dim!=null:dim.size=h._welcome.size

func readable_fonts(node:Node) -> void:
 if h._k>=0.85:return
 for child:Node in node.get_children():readable_fonts(child)
 if node is Control and (node is Label or node is Button or node is LineEdit or node is OptionButton):
  var font_size:int=node.get_theme_font_size("font_size")
  if font_size<21:node.add_theme_font_size_override("font_size",21)

func _show_first_problem() -> void:
 select_mode()
 if not h.issues.is_empty():h._locate_issue(h.issues[0])
 else:h._refresh_panel();h.panel.scroll_to_top()
