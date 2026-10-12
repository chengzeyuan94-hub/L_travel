extends Control
const Mutations:=preload("res://scripts/map_workshop/workshop_mutations.gd")
const Feedback:=preload("res://scripts/map_workshop/workshop_route_feedback.gd")
var marker_hits:Array=[]
var hovered_handle:=""
const Resolver:=preload("res://scripts/map_workshop/workshop_route_resolver.gd")
var workshop:Control
var board:Control
var rid:=""
var edit:Dictionary={}
var route:Dictionary={}
var drag:Dictionary={}
var preview:Dictionary={}
var selected_control:=-1
var adding:=false
var last_sha:=""
var _preview_errors:Array=[]
var _throttle:=0
var _was_active:=false
var tool_panel:PanelContainer
var _from:OptionButton
var _to:OptionButton
var _medium:OptionButton
var _station_count:SpinBox
var _city_choices:Array=[]
var _tool_sha:=""
const Kit:=preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
func _ready()->void:
 mouse_filter=Control.MOUSE_FILTER_IGNORE;z_index=0
 board.set_meta("route_editor",self)
 board.selection_changed.connect(_selection)
func _selection(kind:String,id:String)->void:
 var was_dragging:=not drag.is_empty()
 cancel_drag();rid=id if kind=="route" else "";selected_control=-1;adding=false;last_sha=""
 if kind=="stop":
  var owner:=id.substr(0,id.rfind("_"))
  if not _route(board.cur_layout,owner).is_empty():board.select.call_deferred("route",owner)
 if is_instance_valid(tool_panel):tool_panel.hide()
 _load();queue_redraw()
 if was_dragging:workshop.say("选择或地图已变化，这次路线拖动已取消；请重新拖动。")
 elif rid!="":workshop.say("路线已选中：拖白点改曲线、金点改停靠点，也可直接拖曲线；城市端点保持原位。")
func _route(layout:Dictionary,id:String)->Dictionary:
 for item:Dictionary in layout.get("routes",[]):
  if str(item.id)==id:return item
 return {}
func _active()->bool:
 if rid=="" or workshop.dialogs.is_open() or board.placement_mode or workshop.library.is_open() or workshop._welcome.visible:return false
 if workshop._landscape_op!="" or (is_instance_valid(workshop._plant_tools) and workshop._plant_tools.active):return false
 for tool:Control in [workshop._landscape_tools,workshop._local_assets,workshop._intro_tools,workshop._piece_tools,workshop._asset_library]:
  if is_instance_valid(tool) and tool.visible:return false
 return true
func _load()->void:
 if rid=="":return
 route=_route(board.cur_layout,rid)
 if route.is_empty():rid="";return
 if not route.has("a") or not route.has("b"):
  var ends:Array=board.geo.ends.get(rid,["",""])
  route=route.duplicate(true);route.a=str(ends[0]);route.b=str(ends[1])
 edit=Resolver.read(workshop.doc.doc,rid)
 var pts:Array=route.points
 if edit.get("handles",[]).is_empty():
  var hs:Array=[]
  var count:=mini(4,pts.size()-2)
  for i:int in count:
   var q:Array=pts[clampi(int((i+1)*float(pts.size()-1)/(count+1)),1,pts.size()-2)]
   hs.append([float(q[0]),float(q[2])])
  edit["handles"]=hs
 if not edit.has("stop_t"):
  var ts:Array=[]
  for stop:Dictionary in board.cur_layout.get("stops",[]):
   if str(stop.id).begins_with(rid+"_"):ts.append(_project_t(pts,Vector2(float(stop.x),float(stop.z))))
  ts.sort();edit["stop_t"]=ts if CustomMapFreeRoutes.enabled(workshop.doc.doc) or ts.size()==2 else [0.333,0.667]
 last_sha=workshop.doc.sha()
 board._update_selection_visuals()
func handles_for()->Dictionary:
 var result:Dictionary={}
 if not _active() or route.is_empty():return result
 for i:int in edit.get("handles",[]).size():
  var p:Array=edit.handles[i];result["route_control:"+str(i)]=Vector3(float(p[0]),board.geo.real_geo.height(float(p[0]),float(p[1]))+0.25,float(p[1]))
 for i:int in edit.get("stop_t",[]).size():result["route_stop:"+str(i)]=_point_t((preview.get("route",route) as Dictionary).points,float(edit.stop_t[i]))
 return result
func _process(_delta:float)->void:
 size=board.size
 var active:=_active()
 if not active:
  if cancel_drag():workshop.say("已切换工具，这次路线拖动已取消，地图没有改动。")
  adding=false
 if active!=_was_active:
  _was_active=active
  board._update_selection_visuals()
 if rid!="" and drag.is_empty() and last_sha!=workshop.doc.sha():_load()
 var hovered:=_handle_at(get_local_mouse_position()) if active else {}
 hovered_handle=str(hovered.get("id",""))
 queue_redraw()
func _draw()->void:
 marker_hits.clear()
 if workshop.library.is_open() or workshop._welcome.visible:return
 var errors:Array=workshop.issues
 var layout:Dictionary=board.cur_layout
 if not board.connection_preview_state.is_empty():
  errors=board.connection_preview_state.get("issues",[])
  layout=board.cur_layout.duplicate(false);layout.routes=board.cur_layout.routes.duplicate();layout.routes.append(board.connection_preview_state.route)
 elif not preview.is_empty() and not _preview_errors.is_empty():
  errors=_preview_errors
  layout=board.cur_layout.duplicate(false);layout.routes=board.cur_layout.routes.filter(func(r):return str(r.id)!=rid);layout.routes.append(preview.route)
 _draw_feedback(layout,errors)
 if (rid=="" or route.is_empty()) and preview.is_empty():return
 if not _active():return
 var drawn_handles:=handles_for();var screens:=_screen_handles()
 for key:String in drawn_handles:
  var anchor:Vector2=board._to_view(drawn_handles[key]);var at:Vector2=screens[key];var stop:=key.begins_with("route_stop:")
  if anchor.distance_to(at)>1:draw_line(anchor,at,Color("#8E653A"),1.5,true)
  var radius:=12.0 if key==hovered_handle else 10.0
  draw_circle(at,radius,Color("#E5AE50") if stop else Color("#FFF9E9"))
  draw_arc(at,radius,0,TAU,32,Color("#8E653A"),2,true)
  if key=="route_control:"+str(selected_control):draw_arc(at,14,0,TAU,32,Color("#E7AE4A"),3,true)
  if key==hovered_handle:
   var text:="拖我挪停靠点" if stop else "拖我改弯度"
   var box:=Rect2(at+Vector2(16,-38),Vector2(154,30));draw_style_box(Kit.satchel_box(8,1,5),box)
   draw_string(Kit.font("body",600),box.position+Vector2(8,22),text,HORIZONTAL_ALIGNMENT_LEFT,-1,16,Kit.INK)
func _draw_feedback(layout:Dictionary,errors:Array)->void:
 var marked:Dictionary={}
 for issue:Dictionary in errors:
  if str(issue.get("code",""))=="E_FREE_DISCONNECTED":continue # A newly placed city is unfinished, not a bad route.
  var location:=Feedback.locate(layout,issue)
  if location.is_empty():continue
  var path:=Feedback.route(layout,str(location.id))
  # Only offending samples receive a dashed red edge; no whole-route repaint.
  var indices:Array=issue.get("point_indices",[])
  for i:int in indices:
   if path.is_empty() or i<=0 or i>=path.points.size():continue
   var a:Array=path.points[i-1];var b:Array=path.points[i]
   var start:Vector2=board._to_view(Vector3(a[0],a[1]+0.26,a[2]))+Vector2(0,-5)
   var end:Vector2=board._to_view(Vector3(b[0],b[1]+0.26,b[2]))+Vector2(0,-5)
   draw_dashed_line(start,end,Color("#C95144"),2,5,true)
  var anchor:Vector2=location.anchor
  var key:=str(location.id)+str(anchor.snapped(Vector2.ONE))
  if marked.has(key):continue
  marked[key]=true
  var at:Vector2=board._to_view(Vector3(anchor.x,board.geo.real_geo.height(anchor.x,anchor.y)+0.4,anchor.y))+Vector2(12,-26)
  draw_circle(at,12,Kit.CREAM);draw_arc(at,12,0,TAU,32,Color("#C95144"),2,true)
  draw_string(Kit.font("body",700),at+Vector2(-4,6),"!",HORIZONTAL_ALIGNMENT_LEFT,-1,18,Color("#C95144"))
  marker_hits.append({"rect":Rect2(at-Vector2(16,16),Vector2(32,32)),"issue":issue.duplicate(true),"location":location})
func _point_conflict(p:Array)->bool:
 if _preview_errors.is_empty():return false
 var q:=Vector2(float(p[0]),float(p[2]))
 if q.x<1 or q.x>127 or q.y<1 or q.y>58.63:return true
 if str((preview.get("route",route) as Dictionary).get("type",""))=="LAND":
  if not board.geo.real_geo.is_land(q.x,q.y):return true
  for k:Dictionary in board.cur_layout.get("kit",[]):
   if str(k.get("asset","")).begins_with("forest"):continue
   var radius:=float(k.get("s",0))*float(CustomMapGeoRules.R_ASSET.get(str(k.get("asset","")),1))+0.3
   if q.distance_to(Vector2(float(k.x),float(k.z)))<radius:return true
 return false
func consume_event(event:InputEvent)->bool:
 if event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT and event.pressed and not workshop.dialogs.is_open() and not workshop.library.is_open() and not workshop._welcome.visible:
  for marker:Dictionary in marker_hits:
   # Board._gui_input supplies board-local coordinates, as do the drawn pins.
   if marker.rect.has_point(event.position):
    if board.connection_preview_state.is_empty():workshop._locate_issue(marker.issue)
    else:board.focus_position(marker.location.anchor)
    return true
 if not _active():
  if cancel_drag():workshop.say("已切换工具，这次路线拖动已取消，地图没有改动。")
  adding=false
  return false
 if event is InputEventMouseButton:
  var e:=event as InputEventMouseButton
  if e.button_index!=MOUSE_BUTTON_LEFT:return false
  if e.pressed:
   # Reload before hit testing: a focus commit can replace the geometry and
   # the control indices before this very first press reaches the board.
   if last_sha!=workshop.doc.sha():_load()
   if not _active():return false
   var hit:Dictionary=_handle_at(e.position)
   if hit.is_empty():hit=board.pick_at(e.position)
   if str(hit.kind) in ["route_control","route_stop"]:
    var index:=str(hit.id).get_slice(":",1).to_int()
    var values:Array=edit.get("handles",[]) if str(hit.kind)=="route_control" else edit.get("stop_t",[])
    if index<0 or index>=values.size():workshop.say("路线已变化，控制点不再存在；请重新选点。");return true
    var display_offset:Vector2=_screen_handles()[str(hit.id)]-board._to_view(handles_for()[str(hit.id)]) if str(hit.kind)=="route_control" else Vector2.ZERO
    drag={"kind":str(hit.kind),"index":index,"rid":rid,"before":edit.duplicate(true),"sha":last_sha,"start":e.position,"moved":false,"display_offset":display_offset}
    var ground:Vector3=board._ground_at(e.position)
    if str(hit.kind)=="route_control" and ground!=Vector3.INF:
     var handle:Array=edit.handles[int(drag.index)];drag.offset=Vector2(float(handle[0])-ground.x,float(handle[1])-ground.z)
    selected_control=int(drag.index) if str(hit.kind)=="route_control" else -1
    return true
   if str(hit.kind)=="route" and str(hit.id)==rid and (e.double_click or adding):
    var p:Vector3=board._ground_at(e.position)
    if p!=Vector3.INF:add_point(Vector2(p.x,p.z))
    return true
   if str(hit.kind)=="route" and str(hit.id)==rid:
    var ground:Vector3=board._ground_at(e.position)
    if ground==Vector3.INF:workshop.say("无法定位这段路线；请调整视角再拖动。");return true
    drag={"kind":"route_body","rid":rid,"before":edit.duplicate(true),"sha":last_sha,"start":e.position,"ground":ground,"moved":false}
    return true
  elif not drag.is_empty():
   if bool(drag.moved):_finish_drag()
   else:drag.clear()
   return true
 elif event is InputEventMouseMotion and not drag.is_empty():
  var e:=event as InputEventMouseMotion
  if not bool(drag.moved) and e.position.distance_to(drag.start)<6:return true
  drag.moved=true
  var p:Vector3=board._ground_at(e.position)
  if p==Vector3.INF:return true
  if str(drag.kind)=="route_control":
   var offset:Vector2=drag.get("offset",Vector2.ZERO);edit.handles[int(drag.index)]=[p.x+offset.x,p.z+offset.y]
  elif str(drag.kind)=="route_body":
   var delta:=Vector2(p.x-drag.ground.x,p.z-drag.ground.z)
   for i:int in edit.handles.size():
    var q:Array=drag.before.handles[i];edit.handles[i]=[float(q[0])+delta.x,float(q[1])+delta.y]
  else:
   var t:=_project_t(route.points,Vector2(p.x,p.z));var i:=int(drag.index)
   if CustomMapFreeRoutes.enabled(workshop.doc.doc):
    var low:=float(edit.stop_t[i-1])+0.01 if i>0 else 0.01
    var high:=float(edit.stop_t[i+1])-0.01 if i+1<edit.stop_t.size() else 0.99
    edit.stop_t[i]=clampf(t,low,high)
   else:edit.stop_t[i]=clampf(t,0.2 if i==0 else 0.55,0.45 if i==0 else 0.8)
  _preview();return true
 return false
func _preview()->void:
 var candidate:=Resolver.write(workshop.doc.doc,rid,edit)
 var format_error:String=CustomMapFreeAuthor.format_error(candidate,workshop._base_content) if CustomMapFreeAuthor.enabled(candidate) else CustomBoardLayout.overlay_error(candidate,board.base_layout)
 if format_error!="":
  preview.clear();_preview_errors=[{"kid":format_error}];workshop.say(format_error+"；松开后会恢复原形。");queue_redraw();return
 var layout:Dictionary=CustomBoardLayout.derive(board.base_layout,candidate,board.geo.real_geo,workshop.catalogue)
 if layout.has("error"):return
 preview={"route":_route(layout,rid)}
 board.show_route_preview(preview.route,layout.stops.filter(func(st):return str(st.id).begins_with(rid+"_")))
 if Time.get_ticks_msec()-_throttle>100:
  _throttle=Time.get_ticks_msec();_preview_errors=CustomMapGeoRules.check_objects(layout,[],[rid],board.geo.real_geo,board.base_layout,candidate,false)
  if not _preview_errors.is_empty():workshop.say(str(_preview_errors[0].get("kid","这段路线不能通行。"))+ ("；可存为草稿，试玩前修复。" if CustomMapFreeRoutes.enabled(candidate) else "；松开后校验，不通过会恢复原形。"))
  else:workshop.say("正在调整路线；松开应用，Esc取消，端点城市保持原位。")
 board._update_selection_visuals();queue_redraw()
func _finish_drag()->void:
 var original:Dictionary=drag.before
 var transaction_rid:String=str(drag.get("rid",rid))
 if str(drag.sha)!=workshop.doc.sha() or transaction_rid!=rid:cancel_drag();workshop.say("地图或路线选择已改变，这次拖动没有应用；请重新拖动。");return
 var result:Dictionary=Mutations.change_route(workshop.doc.doc,rid,edit,workshop._base_content,board.base_layout,workshop.catalogue)
 if OS.get_environment("SILKROAD_INPUT_TRACE")=="1":print("ROUTE_RELEASE ",JSON.stringify({"id":rid,"edit":edit,"ok":result.get("ok",false),"reason":result.get("reason",""),"errors":result.get("errors",[])}))
 board.clear_route_preview();drag.clear();preview.clear();_preview_errors.clear()
 if not workshop._accept_mutation(result,"调整路线曲线或停靠点"):
  edit=original;workshop.say(workshop._action_reason(result)+"；路线已恢复原形。")
 else:workshop.say("路线草稿已调整 · 有问题需修正后试玩" if result.get("draft",false) else "路线已调整 · 步数和贸易卡不变 · 可撤销")
 if _route(board.cur_layout,transaction_rid).is_empty():rid=""
 else:
  board.select("route",transaction_rid);rid=transaction_rid
 last_sha="";_load()
func cancel_drag()->bool:
 if drag.is_empty():return false
 edit=drag.before.duplicate(true);board.clear_route_preview();drag.clear();preview.clear();_preview_errors.clear();board._update_selection_visuals();queue_redraw();return true
func add_point(p:Vector2)->void:
 if edit.handles.size()>=12:workshop.say("控制点已够多，可移动或删除已有点。");return
 var index:=0;var t:=_project_t(route.points,p)
 for q:Array in edit.handles:
  if _project_t(route.points,Vector2(float(q[0]),float(q[1])))<t:index+=1
 var before:=edit.duplicate(true);edit.handles.insert(index,[p.x,p.y]);drag={"before":before,"sha":workshop.doc.sha(),"moved":true};adding=false;_finish_drag()
func action(name:String)->void:
 if name=="route_add_point":adding=true;workshop.say("在这条曲线上双击，或点一下添加控制点。")
 elif name=="route_focus":
  var pts:Array=route.points;var centre:=Vector2.ZERO
  for p:Array in pts:centre+=Vector2(float(p[0]),float(p[2]))
  board.focus_position(centre/pts.size())
 elif name=="route_delete_point":
  if selected_control<0 or selected_control>=edit.handles.size():workshop.say("先点选一个白色控制点。");return
  var before:=edit.duplicate(true);edit.handles.remove_at(selected_control);drag={"before":before,"sha":workshop.doc.sha(),"moved":true};_finish_drag();selected_control=-1
 elif name=="route_reset":
  var reset:Dictionary={"stop_t":edit.stop_t.duplicate()} if CustomMapFreeRoutes.enabled(workshop.doc.doc) else {}
  var result:Dictionary=Mutations.change_route(workshop.doc.doc,rid,reset,workshop._base_content,board.base_layout,workshop.catalogue)
  workshop._accept_mutation(result,"恢复路线形状");last_sha="";_load()
 elif name=="route_cancel":cancel_drag();adding=false;workshop.say("已取消这次路线操作。")
 elif name=="route_extend":open_tool()
 elif name=="route_delete":
  var candidate:=CustomMapFreeRoutes.enter(workshop.doc.doc)
  if CustomMapFreeRoutes.specs(workshop._base_content,CustomMapFreeAuthor.base_doc(candidate) if CustomMapFreeAuthor.enabled(candidate) else CustomMapFreeRoutes.clean(candidate)).has(rid):
   var patch:Dictionary=candidate.free_routes.routes.get(rid,{}).duplicate(true);patch.deleted=true;candidate.free_routes.routes[rid]=patch
  else:candidate.free_routes.routes.erase(rid)
  propose(candidate,"删除整条路线")
 elif name.begins_with("route_restore:"):
  var id:=name.trim_prefix("route_restore:");var candidate:Dictionary=workshop.doc.doc.duplicate(true)
  var patch:Dictionary=candidate.get("free_routes",{}).get("routes",{}).get(id,{}).duplicate(true)
  if not patch.get("deleted",false):return
  patch.erase("deleted")
  if patch.is_empty():candidate.free_routes.routes.erase(id)
  else:candidate.free_routes.routes[id]=patch
  propose(candidate,"恢复已删除的路线",id)
func _project_t(pts:Array,p:Vector2)->float:
 var total:=0.0;var best:=INF;var found:=0.0
 for i:int in range(1,pts.size()):
  var a:=Vector2(float(pts[i-1][0]),float(pts[i-1][2]));var b:=Vector2(float(pts[i][0]),float(pts[i][2]));var length:=a.distance_to(b)
  var q:=Geometry2D.get_closest_point_to_segment(p,a,b);var distance:=q.distance_squared_to(p)
  if distance<best:best=distance;found=total+a.distance_to(q)
  total+=length
 return found/maxf(total,0.0001)
func _point_t(pts:Array,t:float)->Vector3:
 var total:=0.0
 for i:int in range(1,pts.size()):total+=Vector2(pts[i-1][0],pts[i-1][2]).distance_to(Vector2(pts[i][0],pts[i][2]))
 var left:=total*t
 for i:int in range(1,pts.size()):
  var a:=Vector3(pts[i-1][0],pts[i-1][1]+0.25,pts[i-1][2]);var b:=Vector3(pts[i][0],pts[i][1]+0.25,pts[i][2]);var length:=Vector2(a.x,a.z).distance_to(Vector2(b.x,b.z))
  if left<=length:return a.lerp(b,left/maxf(length,0.0001))
  left-=length
 return Vector3(pts[-1][0],pts[-1][1]+0.25,pts[-1][2])

func _handle_at(at:Vector2)->Dictionary:
 var best:=256.0;var found:Dictionary={}
 var handles:=_screen_handles()
 for key:String in handles:
  var distance:float=handles[key].distance_squared_to(at)
  if distance<best:
   best=distance;found={"kind":key.get_slice(":",0),"id":key}
 return found
func _screen_handles()->Dictionary:
 var handles:=handles_for();var screens:Dictionary={};var stops:Array[Vector2]=[];var controls:Array[Vector2]=[]
 for key:String in handles:
  if key.begins_with("route_stop:"):
   var at:Vector2=board._to_view(handles[key]);screens[key]=at;stops.append(at)
 for key:String in handles:
  if not key.begins_with("route_control:"):continue
  var at:Vector2=board._to_view(handles[key]);var anchor:=at
  if not drag.is_empty() and str(drag.get("kind",""))=="route_control" and key=="route_control:"+str(drag.index):at+=drag.get("display_offset",Vector2.ZERO)
  else:
   for point:Vector2 in stops:
    if at.distance_to(point)<18:at=anchor+Vector2(0,-20);break
   for point:Vector2 in controls:
    if at.distance_to(point)<16:at=anchor+Vector2(0,20);break
  screens[key]=at;controls.append(at)
 return screens
func key_event(event:InputEventKey)->bool:
 if not _active() or not event.pressed or event.echo:return false
 if event.keycode in [KEY_DELETE,KEY_BACKSPACE] and workshop.get_viewport().gui_get_focus_owner()==null:
  action("route_delete_point");return true
 return false

func open_tool()->void:
 if rid=="":return
 if is_instance_valid(tool_panel):tool_panel.queue_free()
 tool_panel=PanelContainer.new();tool_panel.name="FreeRouteInspector";tool_panel.position=Vector2(1520,76);tool_panel.custom_minimum_size=Vector2(400,952);tool_panel.add_theme_stylebox_override("panel",Kit.satchel_box(16,3,20));workshop._stage.add_child(tool_panel)
 var scroll:=ScrollContainer.new();scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;tool_panel.add_child(scroll)
 var col:=VBoxContainer.new();col.custom_minimum_size.x=350;col.add_theme_constant_override("separation",16);scroll.add_child(col)
 col.add_child(Kit.label("延长路线 · 改接城市",26,Kit.INK,"body",700))
 var note:=Kit.label("增减站点会改变通行步数。改接会重新画路，可在确认后继续拖控制点。",22,Kit.INK);note.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;col.add_child(note)
 _tool_sha=workshop.doc.sha();_city_choices=[]
 for c:Dictionary in board.cur_layout.cities:_city_choices.append(str(c.id))
 _city_choices.sort()
 for endpoint:String in ["a","b"]:
  col.add_child(Kit.label("起点城市" if endpoint=="a" else "终点城市",22,Kit.INK))
  var choose:=OptionButton.new();choose.custom_minimum_size=Vector2(350,50);choose.add_theme_font_size_override("font_size",22)
  for id:String in _city_choices:choose.add_item(workshop._display_name(id))
  choose.select(maxi(0,_city_choices.find(str(route.get(endpoint,"")))))
  col.add_child(choose)
  if endpoint=="a":_from=choose
  else:_to=choose
 col.add_child(Kit.label("交通方式",22,Kit.INK));_medium=OptionButton.new();_medium.custom_minimum_size=Vector2(350,50);_medium.add_theme_font_size_override("font_size",22);_medium.add_item("陆路");_medium.add_item("海路");_medium.select(0 if route.type=="LAND" else 1);col.add_child(_medium)
 col.add_child(Kit.label("停靠点数量（步数 = 站点 + 1）",22,Kit.INK));_station_count=SpinBox.new();_station_count.min_value=0;_station_count.max_value=32;_station_count.step=1;_station_count.value=edit.stop_t.size();_station_count.custom_minimum_size=Vector2(350,50);_station_count.add_theme_font_size_override("font_size",22);col.add_child(_station_count)
 var preview_button:=Kit.button("预览路线与卡片变化","primary",56,22);preview_button.name="FreeRoutePreview";col.add_child(preview_button);preview_button.pressed.connect(_preview_topology)
 var cancel:=Kit.button("取消","cream",50,22);col.add_child(cancel);cancel.pressed.connect(func()->void:tool_panel.hide())
func city_routes(cid:String,deleting:bool=false)->void:
 if is_instance_valid(tool_panel):tool_panel.queue_free()
 tool_panel=PanelContainer.new();tool_panel.name="FreeCityRoutes";tool_panel.custom_minimum_size=Vector2(400,952);tool_panel.add_theme_stylebox_override("panel",Kit.satchel_box(16,3,20));workshop._stage.add_child(tool_panel)
 var scroll:=ScrollContainer.new();scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;tool_panel.add_child(scroll)
 var col:=VBoxContainer.new();col.custom_minimum_size.x=350;col.add_theme_constant_override("separation",16);scroll.add_child(col)
 col.add_child(Kit.label("选择要删除的连线" if deleting else "选择要编辑的连线",25,Kit.INK))
 var count:=0
 for r:Dictionary in board.cur_layout.routes:
  if cid not in [str(r.a),str(r.b)]:continue
  count+=1
  var id:=str(r.id);var button:=Kit.button(workshop._display_name(str(r.a))+" — "+workshop._display_name(str(r.b)),"cream",54,21);col.add_child(button)
  button.pressed.connect(func()->void:
   board.select("route",id)
   if deleting:action("route_delete")
   else:open_tool()
  )
 if count==0:col.add_child(Kit.label("这座城尚未连接。回到地图概览可恢复已删除路线。",22,Kit.INK))
 var close:=Kit.button("回到地图概览","cream",50,22);col.add_child(close);close.pressed.connect(func()->void:tool_panel.hide();board.clear_workshop_selection();workshop._refresh_panel())
func _preview_topology()->void:
 if _tool_sha!=workshop.doc.sha():workshop.say("地图已改变，请重新打开路线工具。");return
 var candidate:=CustomMapFreeRoutes.enter(workshop.doc.doc);var p:Dictionary=candidate.free_routes.routes.get(rid,{}).duplicate(true)
 var a:String=_city_choices[_from.selected];var b:String=_city_choices[_to.selected];var medium:="LAND" if _medium.selected==0 else "SEA"
 var ts:Array=[];var count:=int(_station_count.value)
 if count==edit.stop_t.size():ts=edit.stop_t.duplicate()
 else:
  for i:int in count:ts.append(float(i+1)/float(count+1))
 p.stop_t=ts
 if a!=str(route.a) or b!=str(route.b) or medium!=str(route.type):p.a=a;p.b=b;p.type=medium;p.handles=[]
 candidate.free_routes.routes[rid]=p;tool_panel.hide();propose(candidate,"延长路线或改接城市")
func propose(candidate:Dictionary,label:String,focus_rid:String="")->void:
 var source_sha:String=workshop.doc.sha();var result:=CustomMapFreeRoutes.finish(candidate,workshop._base_content,board.base_layout,workshop.catalogue)
 if not result.ok:workshop.say(str(result.reason));return
 var diff:=CustomMapFreeRoutes.card_diff(workshop.doc.doc,result.doc,workshop._base_content)
 var text:="原80张贸易卡保留原值；原城市路程有 %d 组变化。\n"%int(diff.original_distance_pairs_changed)
 if not result.get("cards_ready",true):text+="路线还不可达，新增卡暂不更新；连通后会重新预览。\n"
 else:
  for row:Dictionary in diff.new_cards:
   text+="%s：%d / %d 张新增卡变化\n"%[workshop._display_name(str(row.city_id)),int(row.changed),int(row.total)]
   if not row.examples.is_empty():
    var example:Dictionary=row.examples[0]
    text+="第%d张：%s → %s\n"%[int(example.number),_card_line(example.before),_card_line(example.after)]
 if diff.new_cards.is_empty():text+="当前没有新增城市的卡片。\n"
 if result.draft:
  text+="\n草稿有 %d 个问题；可保存与继续编辑，禁止试玩。\n%s"%[result.validation.errors.size(),str(result.validation.errors[0].get("kid","地图需要修正"))]
 else:text+="\n路线与新增卡按同一有效图重算；经济平衡仍需试玩。"
 if not CustomMapFreeRoutes.enabled(workshop.doc.doc):text+="\n首次修改会建立自由地图副本，原图保留。"
 var preview_layout:=CustomBoardLayout.derive(board.base_layout,result.doc,board.geo.real_geo,workshop.catalogue)
 var selected:=_route(preview_layout,focus_rid if focus_rid!="" else rid)
 if not selected.is_empty():
  preview={"route":selected};board.show_route_preview(selected,preview_layout.stops.filter(func(st):return str(st.id).begins_with(str(selected.id)+"_")))
 else:preview={"route":route.duplicate(true),"deleted":true}
 workshop.dialogs.confirm("free_route_change",label+"？",text,[{"id":"cancel","text":"取消","kind":"safe"},{"id":"apply","text":"保存草稿" if result.draft else "确认修改","kind":"danger"}],func(choice:String)->void:
  board.clear_route_preview();preview.clear()
  if choice!="apply":workshop.say("已取消，路线和卡片保持。");return
  if workshop.doc.sha()!=source_sha:workshop.say("地图已改变，这次修改未应用。");return
  if workshop._accept_mutation(result,label):
   workshop.say("自由地图草稿已保存到编辑状态 · 修正问题后可试玩" if result.draft else "自由地图已更新 · 路线与新增卡同图 · 可撤销")
   if result.doc.free_routes.routes.get(rid,{}).get("deleted",false):board.clear_workshop_selection()
   elif focus_rid!="":board.select("route",focus_rid)
   last_sha="";_load()
 ,null,true)
func _card_line(entries:Array)->String:
 var terms:PackedStringArray=[]
 for entry:Dictionary in entries:
  var name:="银两" if str(entry.resource_kind)=="SILVER" else str(GameState.content.goods.get(str(entry.resource_id),{}).get("display_name",str(entry.resource_id)))
  terms.append("%s×%d"%[name,int(entry.quantity)])
 return "、".join(terms)
