extends PanelContainer
const Kit:=preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const Presets:=preload("res://scripts/custom_map/custom_map_piece_presets.gd")
const Defaults:=preload("res://scripts/custom_map/custom_map_default_pieces.gd")
const Backend:=preload("res://scripts/map_workshop/workshop_backend.gd")
var workshop:Control
var select_transport:OptionButton
var size_edit:SpinBox
var yaw_edit:SpinBox
var pivot_edit:SpinBox
var idle_edit:OptionButton
var move_edit:OptionButton
var rights:OptionButton
var message:Label
var confirm:Button
var preview:Control
var file_dialog:FileDialog
var test_use_godot_picker:=false
var generation:=0
var source_sha:=""
var transport:="CAMEL"
var pending:Dictionary={}
var checked:Dictionary={}
var preview_actor:Node3D
var preset_heading:Label
var preset_row:GridContainer
var restore_button:Button
var _loading:=false
var preview_mode:="idle"
func _style_select(select:OptionButton)->void:
 Kit.style_button(select,"cream",44,20)
 var popup:=select.get_popup();popup.add_theme_font_override("font",Kit.font("body",500));popup.add_theme_font_size_override("font_size",20);popup.add_theme_color_override("font_color",Kit.INK);popup.add_theme_stylebox_override("panel",Kit.satchel_box(12,2,12))
var _using_default:=false
func _ready()->void:
 position=Vector2(1520,76);custom_minimum_size=Vector2(400,952);add_theme_stylebox_override("panel",Kit.satchel_box(20,4,20));hide()
 var scroll:=ScrollContainer.new();scroll.custom_minimum_size=Vector2(360,890);scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;add_child(scroll)
 var col:=VBoxContainer.new();col.size_flags_horizontal=Control.SIZE_EXPAND_FILL;scroll.add_child(col);col.add_child(Kit.label("棋子模型 · 全体玩家按交通类型使用",26,Kit.INK))
 select_transport=OptionButton.new();select_transport.add_item("陆地棋子");select_transport.add_item("海洋棋子");select_transport.custom_minimum_size.y=44;col.add_child(select_transport);select_transport.item_selected.connect(func(i:int)->void:load_transport("CAMEL" if i==0 else "SHIP"))
 var choose:=Kit.button("选择本机 GLB 模型","cream",44,21);col.add_child(choose);choose.pressed.connect(open_file)
 preset_heading=Kit.label("陆地棋子",24,Kit.INK,"body",700);col.add_child(preset_heading);col.add_child(HSeparator.new())
 col.add_child(Kit.label("私用角色预设 · 点选即应用，可撤销",18,Kit.INK_SOFT))
 preset_row=GridContainer.new();preset_row.columns=1;preset_row.add_theme_constant_override("h_separation",8);preset_row.add_theme_constant_override("v_separation",8);col.add_child(preset_row)
 var row:=VBoxContainer.new();col.add_child(row)
 size_edit=_spin(row,"大小",0.25,3.0,0.05);yaw_edit=_spin(row,"朝向",-180,180,5);pivot_edit=_spin(row,"脚底 / 水线",0,1,0.05)
 var animations:=VBoxContainer.new();col.add_child(animations)
 var idle_row:=HBoxContainer.new();animations.add_child(idle_row)
 idle_row.add_child(Kit.label("待机",20,Kit.INK));idle_edit=OptionButton.new();idle_edit.size_flags_horizontal=Control.SIZE_EXPAND_FILL;idle_row.add_child(idle_edit)
 var move_row:=HBoxContainer.new();animations.add_child(move_row)
 move_row.add_child(Kit.label("移动",20,Kit.INK));move_edit=OptionButton.new();move_edit.size_flags_horizontal=Control.SIZE_EXPAND_FILL;move_row.add_child(move_edit)
 for widget in [select_transport,idle_edit,move_edit]:_style_select(widget)
 for widget in [idle_edit,move_edit]:widget.item_selected.connect(func(_i:int)->void:refresh())
 var modes:=HBoxContainer.new();col.add_child(modes)
 for spec in [["idle","预览待机"],["move","预览移动"]]:
  var b:=Kit.button(spec[1],"cream",38,18);modes.add_child(b);b.pressed.connect(func()->void:preview_mode=spec[0];refresh())
 preview=Control.new();preview.custom_minimum_size=Vector2(340,220);col.add_child(preview)
 rights=OptionButton.new()
 for label in ["私用 · 许可未确认","我拥有素材权利","已获得使用许可"]:rights.add_item(label)
 _style_select(rights);col.add_child(rights)
 confirm=Kit.button("确认模型与动画（可撤销）","primary",44,21);col.add_child(confirm);confirm.pressed.connect(apply_draft)
 var actions:=VBoxContainer.new();col.add_child(actions)
 for spec in [["cancel","取消草稿"],["remove","恢复原版棋子"],["close","结束棋子编辑"]]:
  var b:=Kit.button(spec[1],"cream",40,18);actions.add_child(b);
  if spec[0]=="remove":restore_button=b
  b.pressed.connect(func()->void:
   if spec[0]=="remove":remove_skin()
   elif spec[0]=="close":close_tools()
   else:load_transport(transport))
 message=Kit.label("自包含 GLB；静态模型可直接使用。只选择模型已有动画，不会自动绑骨。",18,Kit.INK_SOFT);message.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;message.custom_minimum_size.x=340;col.add_child(message)
func _spin(parent:VBoxContainer,title:String,lo:float,hi:float,step:float)->SpinBox:
 var row:=HBoxContainer.new();parent.add_child(row);row.add_child(Kit.label(title,18,Kit.INK));var spin:=SpinBox.new();spin.min_value=lo;spin.max_value=hi;spin.step=step;spin.custom_minimum_size.x=130;row.add_child(spin);spin.get_line_edit().add_theme_color_override("font_color",Kit.INK);spin.get_line_edit().add_theme_stylebox_override("normal",Kit.satchel_box(8,1,6));spin.value_changed.connect(func(_v:float)->void:refresh());return spin
func _dismiss_picker()->void:
 if is_instance_valid(file_dialog):file_dialog.hide();file_dialog.queue_free();file_dialog=null
func _clear_preview()->void:
 if is_instance_valid(preview_actor):CustomMapPieceSkins.play(preview_actor,"")
 preview_actor=null
 for child in preview.get_children():preview.remove_child(child);child.free()
func close_tools()->void:
 generation+=1;_dismiss_picker();pending={};checked={};_clear_preview();source_sha="";CustomMapLocalAssets.release_high_cache();hide();workshop.panel.show()
func open_tools()->void:show();workshop.panel.hide();load_transport(transport)
func load_transport(kind:String)->void:
 _clear_preview();CustomMapLocalAssets.release_high_cache();_dismiss_picker();generation+=1;transport=kind;source_sha=workshop.doc.sha();pending={};checked={};_loading=true
 _refresh_presets();select_transport.select(0 if kind=="CAMEL" else 1);var spec:Dictionary=workshop.doc.doc.get("piece_skins",{}).get("transports",{}).get(kind,{})
 _using_default=spec.is_empty()
 if _using_default:spec=Defaults.SPECS[kind].duplicate(true)
 size_edit.value=float(spec.get("size",1));yaw_edit.value=float(spec.get("yaw",0));pivot_edit.value=float(spec.get("pivot",0));rights.select(0)
 checked=Defaults.read_default(kind) if _using_default else CustomMapLocalAssets.read(spec.asset,"actor_model")
 _fill_clips(str(spec.get("idle","")),str(spec.get("move","")));_loading=false;refresh()
func _fill_clips(idle:String,move:String)->void:
 for pair in [[idle_edit,idle],[move_edit,move]]:
  var select:OptionButton=pair[0];select.clear();select.add_item("静态 · 不播放");select.set_item_metadata(0,"")
  for clip in checked.get("clips",[]):select.add_item(str(clip.name));select.set_item_metadata(select.item_count-1,str(clip.name))
  for i in select.item_count:
   if str(select.get_item_metadata(i))==pair[1]:select.select(i)
func _spec()->Dictionary:
 return {"asset":str(checked.get("id","")),"size":size_edit.value,"yaw":yaw_edit.value,"pivot":pivot_edit.value,"idle":str(idle_edit.get_item_metadata(idle_edit.selected)),"move":str(move_edit.get_item_metadata(move_edit.selected))}
func open_file()->void:
 _dismiss_picker();generation+=1;var token:=generation;var kind:=transport;var sha:=source_sha
 file_dialog=FileDialog.new();file_dialog.access=FileDialog.ACCESS_FILESYSTEM;file_dialog.file_mode=FileDialog.FILE_MODE_OPEN_FILE;file_dialog.use_native_dialog=not test_use_godot_picker;file_dialog.filters=PackedStringArray(["*.glb ; 自包含棋子 GLB"]);add_child(file_dialog)
 file_dialog.file_selected.connect(func(file:String)->void:prepare(file,kind,sha,token));file_dialog.canceled.connect(func()->void:generation+=1);file_dialog.popup_centered(Vector2i(850,600))
func prepare(file:String,kind:String,sha:String,token:int)->Dictionary:
 if not visible or kind!=transport or sha!=source_sha or sha!=workshop.doc.sha() or token!=generation:return CustomMapLocalAssets.fail("地图或草稿已改变，请重新选择模型")
 var plan:=CustomMapLocalAssets.preflight_replacement(workshop.doc.doc,kind,file)
 _clear_preview();pending={};checked={};CustomMapLocalAssets.release_high_cache()
 if not plan.ok:message.text=plan.message;return plan
 var result:=CustomMapLocalAssets.inspect_file(file,"actor_model")
 if not result.ok:message.text=result.message;return result
 result.source_name=file.get_file().get_basename();pending=result;checked=result;_using_default=false;_loading=true;_fill_clips("","");_loading=false;refresh();return result
func refresh()->void:
 if _loading:return
 confirm.disabled=_using_default or not checked.get("ok",false) or source_sha!=workshop.doc.sha();_clear_preview()
 if not checked.get("ok",false):message.text="正在使用原版棋子。选择模型后可预览；确认前地图不会改变。";return
 var container:=SubViewportContainer.new();container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);container.stretch=true;preview.add_child(container)
 var viewport:=SubViewport.new();viewport.size=Vector2i(800,230);viewport.own_world_3d=true;viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;container.add_child(viewport)
 var root:=Node3D.new();viewport.add_child(root);preview_actor=CustomMapPieceSkins.instantiate(checked,_spec(),1.5,true);root.add_child(preview_actor)
 if CustomMapDefaultTeamMaterials.supports(checked.id):preload("res://scripts/custom_map/custom_map_default_team_materials.gd").apply(preview_actor,checked.id,Color8(205,72,58))
 var camera:=Camera3D.new();camera.position=Vector3(3,2.5,4);camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.size=maxf(4,checked.bounds.size.y*1.5/maxf(checked.bounds.size.x,checked.bounds.size.z)*size_edit.value*1.5);root.add_child(camera);camera.look_at(Vector3.ZERO);camera.current=true
 var light:=DirectionalLight3D.new();light.rotation_degrees=Vector3(-45,-30,0);light.light_energy=1.8;root.add_child(light)
 var environment:=WorldEnvironment.new();environment.environment=Environment.new();environment.environment.background_mode=Environment.BG_COLOR;environment.environment.background_color=Color("e5dccb");environment.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;environment.environment.ambient_light_color=Color.WHITE;environment.environment.ambient_light_energy=0.7;root.add_child(environment)
 var spec:=_spec();CustomMapPieceSkins.play(preview_actor,str(spec[preview_mode]));message.text="%d 网格 · %d 骨架绑定 · %d 已有动画。确认后复制本机资源；移动路径与规则保持原样。"%[checked.meshes,checked.skins,checked.clips.size()]
 if checked.id==CustomMapLiaoningVisual.ASSET:
  CustomMapLiaoningVisual.preview_motion(preview_actor,preview_mode=="move");message.text="辽宁号整船轻浮动，玩家颜色只显示在舰岛小旗。保留船体原色和原版航线。"
 if _using_default:message.text="默认 L叔棋子。对局中鞍毯或帆旗船舷随玩家颜色变化，人物保留原色。"
func apply_draft()->Dictionary:
 if _using_default or not visible or source_sha!=workshop.doc.sha() or not checked.get("ok",false):return CustomMapLocalAssets.fail("没有待确认模型或地图已改变")
 var before:Dictionary=workshop.doc.doc.duplicate(true);var candidate:=CustomMapPieceSkins.candidate(before,transport,pending,_spec(),["private_unknown","owned","permission"][rights.selected])
 if candidate==before:load_transport(transport);return {"ok":true,"unchanged":true}
 var shape:=candidate.duplicate(true);shape.erase("assets");shape.erase("city_intro_cards");shape.erase("piece_skins");CustomMapCityBadges.clear_image_dependencies(shape)
 if not Backend.validate(workshop.board.base_layout,shape,workshop.board.geo,workshop.catalogue).ok:return CustomMapLocalAssets.fail("地图未通过校验，草稿没有应用")
 if not pending.is_empty():
  var copied:=CustomMapAssetMeta.admit(pending,{"display_name":str(pending.get("source_name",pending.id)),"tags":[],"note":""},["private_unknown","owned","permission"][rights.selected],"当前地图 · "+transport+" · 棋子")
  if not copied.ok:message.text=copied.message;return copied
 var validated:Dictionary=Backend.validate(workshop.board.base_layout,candidate,workshop.board.geo,workshop.catalogue)
 if not validated.ok:message.text="资源或地图未通过校验";return CustomMapLocalAssets.fail(message.text)
 workshop.doc.doc=candidate;workshop.doc._touch();workshop._commit(before,"更换棋子模型",validated);load_transport(transport);return {"ok":true}
func remove_skin()->Dictionary:
 if source_sha!=workshop.doc.sha():return CustomMapLocalAssets.fail("地图已改变，请重新打开")
 var before:Dictionary=workshop.doc.doc.duplicate(true);var candidate:=CustomMapPieceSkins.remove(before,transport)
 if candidate==before:return {"ok":true,"unchanged":true}
 var validated:Dictionary=Backend.validate(workshop.board.base_layout,candidate,workshop.board.geo,workshop.catalogue)
 if not validated.ok:return CustomMapLocalAssets.fail("地图未通过校验")
 workshop.doc.doc=candidate;workshop.doc._touch();workshop._commit(before,"恢复原版棋子",validated);load_transport(transport);return {"ok":true}

func _refresh_presets()->void:
 preset_heading.text="陆地棋子" if transport=="CAMEL" else "海洋棋子"
 for child in preset_row.get_children():preset_row.remove_child(child);child.queue_free()
 restore_button.text="恢复默认骆驼" if transport=="CAMEL" else "恢复默认船"
 for item in Presets.items(transport):
  var b:=Kit.button("","cream",96,17);b.name="Preset_"+item.id;b.custom_minimum_size.x=340
  var image_path:=Presets.thumbnail(item.id)
  var contents:=HBoxContainer.new();contents.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);contents.offset_left=12;contents.offset_right=-12;contents.offset_top=6;contents.offset_bottom=-6;contents.mouse_filter=Control.MOUSE_FILTER_IGNORE;contents.add_theme_constant_override("separation",6);b.add_child(contents)
  var thumb:=TextureRect.new();thumb.name="Thumbnail";thumb.custom_minimum_size=Vector2(64,64);thumb.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;thumb.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED;thumb.mouse_filter=Control.MOUSE_FILTER_IGNORE
  if ResourceLoader.exists(image_path):thumb.texture=load(image_path)
  elif FileAccess.file_exists(image_path):
   var icon_check:=CustomMapLocalAssets.inspect_file(image_path,"good_icon")
   if icon_check.ok:thumb.texture=ImageTexture.create_from_image(icon_check.image)
  contents.add_child(thumb)
  var caption:=Kit.label(item.name+"\n"+item.tags,17,Kit.INK);caption.size_flags_horizontal=Control.SIZE_EXPAND_FILL;caption.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;caption.mouse_filter=Control.MOUSE_FILTER_IGNORE;caption.vertical_alignment=VERTICAL_ALIGNMENT_CENTER;contents.add_child(caption)
  b.tooltip_text="自制私用角色演示；非官方授权资产。点选应用后可撤销。";preset_row.add_child(b);b.pressed.connect(func()->void:choose_preset(item.id))
func choose_preset(id:String)->Dictionary:
 var preset:=Presets.find(id)
 if preset.is_empty() or preset.transport!=transport:return CustomMapLocalAssets.fail("预设不适用于当前交通")
 var result:=prepare(Presets.model(id),transport,source_sha,generation)
 if not result.ok:return result
 var names:Array=[]
 for clip in checked.clips:names.append(clip.name)
 var idle:=str(preset.get("idle","idle"));var move:=str(preset.get("move","move"))
 if (idle!="" and idle not in names) or (move!="" and move not in names):
  _clear_preview();pending={};checked={};return CustomMapLocalAssets.fail("预设声明的动画与真实模型不匹配")
 _loading=true;size_edit.value=preset.size;yaw_edit.value=float(preset.get("yaw",0));pivot_edit.value=preset.pivot;rights.select(0);_fill_clips(idle,move);_loading=false
 preview_mode="idle";refresh()
 return apply_draft()

func _exit_tree()->void:
 pending={};checked={};CustomMapLocalAssets.release_high_cache()

func observer()->Dictionary:
 var members:Array=[]
 for item in Presets.items(transport):members.append(str(item.id))
 var rect:=select_transport.get_global_rect()
 var heading:=preset_heading.get_global_rect()
 var buttons:Array=[]
 for child in preset_row.get_children():
  if child is Button:
   var b:Rect2=child.get_global_rect();buttons.append({"id":str(child.name).trim_prefix("Preset_"),"rect":[b.position.x,b.position.y,b.size.x,b.size.y]})
 return {"preset_buttons":buttons,"asset":str(checked.get("id","")),"preview_mode":preview_mode,"visible":visible,"transport":transport,"group_title":preset_heading.text,"members":members,"select_transport_rect":[rect.position.x,rect.position.y,rect.size.x,rect.size.y],"heading_rect":[heading.position.x,heading.position.y,heading.size.x,heading.size.y]}
