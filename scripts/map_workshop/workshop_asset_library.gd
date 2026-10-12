extends PanelContainer
const Kit:=preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const Library:=preload("res://scripts/custom_map/custom_map_asset_library.gd")
const Meta:=preload("res://scripts/custom_map/custom_map_asset_meta.gd")
const Refs:=preload("res://scripts/custom_map/custom_map_asset_refs.gd")
const ModelPreview:=preload("res://scripts/map_workshop/workshop_asset_model_preview.gd")
const SOURCE_NAMES:={"original":"原版","catalogue":"目录","preset":"棋子预设","map":"当前地图","user":"我的","draft":"草稿","retired":"历史"}
const CATEGORIES:=[["city_model","城市模型","city"],["good_icon","特产图片","assets"],["trade_card","交易卡","scroll"],["city_card","城市卡","card"],["piece","棋子","piece"]]
var workshop:Control
var data:Dictionary={}
var category:="city_model"
var selected:Dictionary={}
var search:LineEdit
var source_filter:OptionButton
var state_filter:OptionButton
var fit_filter:OptionButton
var grid:VBoxContainer
var piece_groups:Array=[]
var detail:VBoxContainer
var message:Label
var count_label:Label
var target_label:Label
var category_buttons:Dictionary={}
var preview:Control
var model_preview:Control
var preview_mode:="idle"
var player_color:=0
var targets:OptionButton
var reuse_button:Button
var import_pending:Dictionary={}
var import_purpose:=""
var import_name:LineEdit
var import_note:TextEdit
var import_source:LineEdit
var import_rights:OptionButton
var edit_name:LineEdit
var edit_tags:LineEdit
var edit_note:TextEdit
var file_dialog:FileDialog
var test_use_godot_picker:=false
var generation:=0
var target_sha:=""
var dependencies:Array=[]
var displayed:Array=[]
var _full_card:Control
func _ready()->void:
 name="AssetLibrary";position=Vector2(88,76);size=Vector2(1832,952);custom_minimum_size=size
 add_theme_stylebox_override("panel",Kit.satchel_box(16,3,16));hide()
 var content:=VBoxContainer.new();content.add_theme_constant_override("separation",12);add_child(content)
 var header:=HBoxContainer.new();content.add_child(header)
 header.add_child(Kit.label("资源小书房",32,Kit.INK,"body",700))
 var spacer:=Control.new();spacer.size_flags_horizontal=Control.SIZE_EXPAND_FILL;header.add_child(spacer)
 var deps:=_button("地图依赖","cream");header.add_child(deps);deps.pressed.connect(show_dependencies)
 var refresh:=_button("刷新","cream");header.add_child(refresh);refresh.pressed.connect(reload)
 var importing:=_button("导入本机文件","primary");header.add_child(importing);importing.pressed.connect(open_import)
 var close:=_button("回到地图","cream");header.add_child(close);close.pressed.connect(close_tools)
 var filters:=HBoxContainer.new();content.add_child(filters)
 search=_line("搜名称、语义ID、SHA、地图、标签");search.size_flags_horizontal=Control.SIZE_EXPAND_FILL;filters.add_child(search);search.text_changed.connect(func(_text:String)->void:refresh_grid())
 source_filter=_select(["全部来源","原版","目录","棋子预设","当前地图","我的","历史"]);filters.add_child(source_filter)
 for pair in [[0,"all"],[1,"original"],[2,"catalogue"],[3,"preset"],[4,"map"],[5,"user"],[6,"retired"]]:source_filter.set_item_metadata(pair[0],pair[1])
 if CustomMapCatalogue.allow_draft():source_filter.add_item("草稿 · 开发");source_filter.set_item_metadata(source_filter.item_count-1,"draft")
 state_filter=_select(["可用","已归档"]);filters.add_child(state_filter)
 fit_filter=_select(["全部适配","陆路","海路","陆海"]);filters.add_child(fit_filter)
 for widget in [source_filter,state_filter,fit_filter]:widget.item_selected.connect(func(_i:int)->void:refresh_grid())
 var body:=HBoxContainer.new();body.size_flags_vertical=Control.SIZE_EXPAND_FILL;body.add_theme_constant_override("separation",16);content.add_child(body)
 var categories:=VBoxContainer.new();categories.custom_minimum_size.x=210;body.add_child(categories)
 for spec in CATEGORIES:
  var button:=_button(spec[1],"cream");button.custom_minimum_size=Vector2(210,64);button.icon=load("res://assets/game/ui/workshop_icons/"+spec[2]+".svg");categories.add_child(button);category_buttons[spec[0]]=button
  button.pressed.connect(func()->void:category=spec[0];selected={};refresh_grid())
 count_label=Kit.label("",22,Kit.INK_SOFT);count_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;count_label.custom_minimum_size.x=200;categories.add_child(count_label)
 var middle:=ScrollContainer.new();middle.custom_minimum_size.x=590;middle.size_flags_vertical=Control.SIZE_EXPAND_FILL;middle.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;body.add_child(middle)
 grid=VBoxContainer.new();grid.add_theme_constant_override("separation",16);middle.add_child(grid)
 var divider:=VSeparator.new();body.add_child(divider)
 var right:=ScrollContainer.new();right.size_flags_horizontal=Control.SIZE_EXPAND_FILL;right.size_flags_vertical=Control.SIZE_EXPAND_FILL;right.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;body.add_child(right)
 detail=VBoxContainer.new();detail.custom_minimum_size.x=900;detail.size_flags_horizontal=Control.SIZE_EXPAND_FILL;detail.add_theme_constant_override("separation",12);right.add_child(detail)
 message=Kit.label("",22,Kit.INK_SOFT);message.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;message.custom_minimum_size.y=34;content.add_child(message)
func _button(text:String,kind:String="cream")->Button:return Kit.button(text,kind,48,22)
func _select(labels:Array)->OptionButton:
 var widget:=OptionButton.new();widget.custom_minimum_size.y=48
 for label in labels:widget.add_item(str(label))
 Kit.style_button(widget,"cream",48,22);widget.get_popup().add_theme_font_override("font",Kit.font("body",500));widget.get_popup().add_theme_font_size_override("font_size",22)
 return widget
func _line(hint:String)->LineEdit:
 var line:=LineEdit.new();line.placeholder_text=hint;line.custom_minimum_size.y=48;line.add_theme_font_override("font",Kit.font("body",500));line.add_theme_font_size_override("font_size",22);line.add_theme_color_override("font_color",Kit.INK);line.add_theme_color_override("font_placeholder_color",Kit.INK_SOFT);line.add_theme_stylebox_override("normal",Kit.satchel_box(8,1,10));return line
func _text(hint:String,height:float=100)->TextEdit:
 var text:=TextEdit.new();text.placeholder_text=hint;text.custom_minimum_size.y=height;text.wrap_mode=TextEdit.LINE_WRAPPING_BOUNDARY;text.add_theme_font_override("font",Kit.font("body",500));text.add_theme_font_size_override("font_size",22);return text
func _label(text:String,color:Color=Kit.INK)->Label:
 var label:=Kit.label(text,22,color);label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;label.custom_minimum_size.x=850;return label
func _clear_detail()->void:
 if is_instance_valid(model_preview):model_preview=null
 for child in detail.get_children():detail.remove_child(child);child.queue_free()
 import_pending={}
func open_tools()->void:
 workshop._v02_shell.select_mode();generation+=1;target_sha=workshop.doc.sha();show();workshop._stage.move_child(self,workshop._stage.get_child_count()-1)
 # Dialogs and modal welcome always stay above the library.
 workshop._stage.move_child(workshop.dialogs,workshop._stage.get_child_count()-1)
 reload()
func close_tools()->void:
 generation+=1;_dismiss_picker();_clear_detail();
 if is_instance_valid(_full_card):_full_card.queue_free()
 hide();workshop.panel.show();CustomMapLocalAssets.release_high_cache()
func reload()->void:
 data=Library.collect(workshop._base_content,workshop.catalogue,workshop.doc.doc,GameState.content)
 message.text=str(data.metadata_message);refresh_grid()
func _texture(path:String)->Texture2D:
 if path=="":return null
 if ResourceLoader.exists(path):return load(path) as Texture2D
 if FileAccess.file_exists(path) and path.get_extension() in ["png","jpg"]:
  var checked:=CustomMapLocalAssets.inspect_file(path,"good_icon")
  if checked.ok:return ImageTexture.create_from_image(checked.image)
 return null
func _thumb(item:Dictionary)->Texture2D:
 if item.category=="city_model" and str(item.thumb)=="":
  var cid:=str(item.semantic_id).trim_prefix("builtin:city:")
  return _texture(str(workshop._base_content.get("illustrations",{}).get(str(workshop._base_content.get("cities",{}).get(cid,{}).get("illustration_id","")),{}).get("runtime_path","")))
 return _texture(str(item.get("thumb","")))
func _fit()->String:return ["all","LAND","SEA","BOTH"][fit_filter.selected]
func refresh_grid()->void:
 if data.is_empty():return
 for child in grid.get_children():grid.remove_child(child);child.queue_free()
 var fit:=_fit()
 displayed=Library.filtered(data.items,category,search.text,str(source_filter.get_item_metadata(source_filter.selected)),state_filter.selected==1,"all" if fit=="BOTH" else fit)
 if fit=="BOTH":displayed=displayed.filter(func(item:Dictionary)->bool:return "LAND" in item.fits and "SEA" in item.fits)
 if not selected.is_empty() and not displayed.any(func(item:Dictionary)->bool:return item.semantic_id==selected.semantic_id):selected={}
 for spec in CATEGORIES:
  var count:=0
  for item in data.items:
   if item.category==spec[0] and not item.archived:count+=1
  category_buttons[spec[0]].text=spec[1]+" · "+str(count);Kit.style_button(category_buttons[spec[0]],"primary" if category==spec[0] else "cream",64,22)
 count_label.text="%d 项匹配\n\n语义身份各自保留\n内容按 SHA 去重"%displayed.size()
 piece_groups=[]
 var groups:Array=[]
 if category=="piece":
  for key in ["LAND","SEA","BOTH","UNKNOWN"]:
   var members:Array=displayed.filter(func(item:Dictionary)->bool:return _piece_group(item)==key)
   if not members.is_empty():groups.append({"key":key,"title":_piece_group_title(key),"items":members})
 else:groups.append({"key":"","title":"","items":displayed})
 for group in groups:
  if group.key!="":
   var title:=Kit.label(group.title+" · "+str(group.items.size()),24,Kit.INK,"body",700);grid.add_child(title)
   var line:=HSeparator.new();grid.add_child(line)
   piece_groups.append({"key":group.key,"title":group.title,"members":group.items.map(func(item:Dictionary)->String:return str(item.semantic_id)),"heading":title})
  var cards:=GridContainer.new();cards.columns=3;cards.add_theme_constant_override("h_separation",12);cards.add_theme_constant_override("v_separation",12);grid.add_child(cards)
  for item in group.items:_add_asset_button(item,cards)
 if selected.is_empty() and not displayed.is_empty():select_item(displayed[0])
 elif not selected.is_empty():
  for item in data.items:
   if item.semantic_id==selected.semantic_id:select_item(item);return
 if displayed.is_empty():_clear_detail();detail.add_child(_label("没有匹配资源。试试调整搜索或筛选。"))
func _piece_group(item:Dictionary)->String:
 var fits:Array=item.get("fits",[])
 if "LAND" in fits and "SEA" in fits:return "BOTH"
 if str(item.get("transport",""))=="CAMEL":return "LAND"
 if str(item.get("transport",""))=="SHIP":return "SEA"
 if "LAND" in fits:return "LAND"
 if "SEA" in fits:return "SEA"
 return "UNKNOWN"
func _piece_group_title(key:String)->String:
 return str({"LAND":"陆地棋子","SEA":"海洋棋子","BOTH":"陆海通用","UNKNOWN":"适配未标注"}.get(key,"适配未标注"))
func _add_asset_button(item:Dictionary,cards:GridContainer)->void:
  var button:=_button("","cream");button.custom_minimum_size=Vector2(180,228);button.name="Asset_"+str(item.semantic_id).replace(":","_");button.tooltip_text=str(item.semantic_id);cards.add_child(button);button.set_meta("semantic_id",item.semantic_id)
  var column:=VBoxContainer.new();column.mouse_filter=Control.MOUSE_FILTER_IGNORE;column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);column.offset_left=8;column.offset_right=-8;column.offset_top=8;column.offset_bottom=-8;button.add_child(column)
  if item.category=="trade_card":
   var rows:=GridContainer.new();rows.columns=2;rows.mouse_filter=Control.MOUSE_FILTER_IGNORE;column.add_child(rows)
   for entry in item.definition.get("entries",[]):
    var icon:=TextureRect.new();icon.texture=preload("res://scripts/lshu_ui/lshu_icons.gd").silver() if entry.resource_kind=="SILVER" else GameData.get_good_texture(item.get("content",workshop._base_content),str(entry.resource_id));icon.custom_minimum_size=Vector2(60,48);icon.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;icon.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED;icon.mouse_filter=Control.MOUSE_FILTER_IGNORE;rows.add_child(icon)
  else:
   var image:=TextureRect.new();image.texture=_thumb(item);image.custom_minimum_size=Vector2(164,108);image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;image.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED;image.mouse_filter=Control.MOUSE_FILTER_IGNORE;column.add_child(image)
  var title:=Kit.label(str(item.name),22,Kit.INK);title.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;title.custom_minimum_size.x=164;title.max_lines_visible=2;title.text_overrun_behavior=TextServer.OVERRUN_TRIM_ELLIPSIS;title.mouse_filter=Control.MOUSE_FILTER_IGNORE;column.add_child(title)
  var caption:=Kit.label(str(SOURCE_NAMES.get(item.source,item.source))+" · "+("使用中" if not item.refs.is_empty() else "无引用"),22,Kit.INK_SOFT);caption.clip_text=true;caption.mouse_filter=Control.MOUSE_FILTER_IGNORE;column.add_child(caption)
  button.pressed.connect(func()->void:select_item(item))
func select_item(item:Dictionary)->void:
 _clear_detail();selected=item;target_sha=workshop.doc.sha()
 detail.add_child(Kit.label(str(item.name),30,Kit.INK,"body",700))
 target_label=_label("目标：当前地图《%s》 · 应用前可选单个对象"%workshop.doc.map_name(),Kit.SATCHEL_DEEP);detail.add_child(target_label)
 if item.category=="piece":
  var controls:=HBoxContainer.new();detail.add_child(controls)
  for spec in [["idle","待机"],["move","移动"]]:
   var b:=_button(spec[1],"primary" if preview_mode==spec[0] else "cream");controls.add_child(b);b.pressed.connect(func()->void:preview_mode=spec[0];select_item(selected))
  var colors:Array=GameData.get_player_colors(GameState.content)
  for i in mini(4,colors.size()):
   var b:=_button("玩家%d"%(i+1));b.modulate=Color(str(colors[i].color)).lightened(0.5);controls.add_child(b);b.pressed.connect(func()->void:player_color=i;select_item(selected))
 preview=Control.new();preview.custom_minimum_size=Vector2(850,410);preview.mouse_filter=Control.MOUSE_FILTER_STOP;detail.add_child(preview)
 if item.category in ["city_model","piece"]:
  model_preview=ModelPreview.new();model_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);preview.add_child(model_preview);model_preview.show_item(item,Color(str(GameData.get_player_colors(GameState.content)[player_color].color)),preview_mode)
  detail.add_child(_label(model_preview.preview_error if model_preview.preview_error!="" else (model_preview.mechanism+" · 拖动旋转" if item.category=="piece" else "真实城市模型 · 拖动旋转"),Kit.INK_SOFT))
 elif item.category=="trade_card":_trade_preview(item,preview)
 elif item.category=="city_card":_city_preview(item,preview)
 else:_image(preview,_texture(str(item.path)))
 _build_reuse(item)
 detail.add_child(_label("语义身份："+str(item.semantic_id)))
 if item.category=="good_icon":detail.add_child(_label("商品身份："+str(item.get("identity","图片资源，可用于不同用途"))+"\n复用图片不会改变商品名称或交易卡价格。"))
 if item.get("same_as_builtin",[]).size()>0:detail.add_child(_label("与内置内容相同："+"、".join(item.same_as_builtin)+"\n文件内容去重；各用途与商品身份保留。",Kit.SATCHEL_DEEP))
 detail.add_child(_label("来源与许可："+str(SOURCE_NAMES.get(item.source,item.source))+" · "+_rights_summary(item)))
 var source_details:=_button("来源详情 ›");detail.add_child(source_details)
 var source_text:=_label(JSON.stringify(item.rights,"  ")+"\n"+JSON.stringify(item.definition.get("provenance",{}),"  ")+"\n运行资源与制作源独立；部分制作源保留在主仓库或旧地图编辑器工作树。",Kit.INK_SOFT);source_text.hide();detail.add_child(source_text)
 source_details.pressed.connect(func()->void:source_text.visible=not source_text.visible;source_details.text="收起来源详情 ‹" if source_text.visible else "来源详情 ›")
 detail.add_child(_label("SHA："+str(item.sha)+"\n字节："+str(item.bytes)+" · 格式："+str(item.path).get_extension()+"\n运行文件："+str(item.path)))
 
 detail.add_child(_label("本机已知引用 · "+str(data.refs.scanned_at)+"\n"+str(data.refs.note)))
 for ref in item.refs:detail.add_child(_label("%s · %s\n%s · %s · %s\n许可：%s"%[ref.scope,ref.map_name,ref.file,ref.role,ref.target,ref.rights]))
 if item.refs.is_empty():detail.add_child(_label("本机已知范围内无引用；外部携带包无法检查。"))
 if item.user:_metadata_editor(item)
func _rights_summary(item:Dictionary)->String:
 if item.get("user",false):
  var labels:Array=[]
  for claim in item.get("meta",{}).get("claims",[]):
   var label:=str({"private_unknown":"私用，许可未确认","owned":"声明拥有素材权利","permission":"声明已获使用许可"}.get(claim.rights,"许可未确认"))
   if label not in labels:labels.append(label)
  return "；".join(labels) if not labels.is_empty() else "元数据声明未知；地图声明见引用"
 if item.source=="preset":return "私用演示，许可未确认"
 var provenance:Variant=item.definition.get("provenance",{})
 if provenance is Dictionary and provenance.get("use_scope","")=="private_household":return "家庭私用；公开许可未记录"
 return "来源已记录；公开许可未记录"
func _image(host:Control,texture:Texture2D)->void:
 var image:=TextureRect.new();image.texture=texture;image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;image.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED;host.add_child(image)
func _trade_preview(item:Dictionary,host:Control)->void:
 var paper:=PanelContainer.new();paper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);paper.add_theme_stylebox_override("panel",Kit.satchel_box(18,3,22));host.add_child(paper)
 var column:=VBoxContainer.new();column.add_theme_constant_override("separation",16);paper.add_child(column)
 column.add_child(_label("真实贸易卡 · "+str(item.card_id),Kit.SATCHEL_DEEP))
 var entries:Dictionary=GameData.get_trade_card(item.get("content",workshop._base_content),str(item.card_id))
 if entries.is_empty():entries=item.definition
 var rows:=GridContainer.new();rows.columns=2;rows.add_theme_constant_override("h_separation",48);column.add_child(rows)
 for entry in entries.get("entries",[]):
  var cell:=HBoxContainer.new();cell.custom_minimum_size=Vector2(390,90);rows.add_child(cell)
  var icon:=TextureRect.new();icon.texture=preload("res://scripts/lshu_ui/lshu_icons.gd").silver() if entry.resource_kind=="SILVER" else GameData.get_good_texture(item.get("content",workshop._base_content),str(entry.resource_id));icon.custom_minimum_size=Vector2(80,80);icon.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;icon.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED;cell.add_child(icon)
  var text:=Kit.label(GameData.describe_entry(item.get("content",workshop._base_content),entry),26,Kit.INK);text.custom_minimum_size.x=270;text.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;cell.add_child(text)
 if item.get("frozen",false):column.add_child(_label("原80冻结 · "+("指纹一致" if data.trade_frozen else "指纹不符，停止使用")))
 else:column.add_child(_label(CustomMapTradegenRegistry.label(str(item.version))+"\n"+CustomMapTradegenRegistry.disclosure(str(item.version))+"\n配对不是经济平衡证明。"))
func _resolved(item:Dictionary)->Dictionary:
 if item.has("resolved"):return item.resolved
 if item.has("city_id") and GameState.content.get("cities",{}).has(item.city_id):return FormalCardPresentationResolver.resolve_city_card(GameState.content,str(item.city_id))
 var definition:Dictionary=item.definition
 return {"success":true,"city_id":str(definition.get("id","")),"display_name":str(item.name),"illustration_path":item.path,"epithet":str(definition.get("epithet4","目录城市插画")),"intro":str(definition.get("intro","模板插画；应用时按目标城市与保存的规则读取卡面。")),"scenery":str(definition.get("scenery",definition.get("historical_period",""))),"map_attribute":"目录模板 · "+str(item.get("route","")),"starting_transport":"SHIP" if item.get("route","")=="SEA" else "CAMEL","starting_grant":{"entries":[]},"card_number":0}
func _city_preview(item:Dictionary,host:Control)->void:
 if item.get("user",false) and item.get("kind","")=="city_intro":
  _image(host,_texture(str(item.path)))
  detail.add_child(_label("介绍插图 · 选定目标城市后，用原有城市卡工具预览完整文字与牌面。",Kit.INK_SOFT))
 elif item.has("user_card"):
  var view:=preload("res://scripts/ui/custom_city_intro_view.gd").new();view.position=Vector2(200,0);view.size=Vector2(450,400);host.add_child(view);view.bind_card(item.user_card,str(item.name),{},str(item.city_id))
 else:
  var card:=preload("res://scenes/ui/components/formal_city_card.tscn").instantiate();host.add_child(card);card.custom_minimum_size=Vector2(300,400);card.size=Vector2(300,400);card.position=Vector2(250,0);card.bind_resolved(_resolved(item),GameState.content)
 var full:=_button("打开完整大牌面");detail.add_child(full);full.pressed.connect(func()->void:enlarge_card(item))
 var resolved:=_resolved(item)
 detail.add_child(_label(str(item.get("user_card",{}).get("description",resolved.get("intro","")))+"\n"+str(resolved.get("scenery",""))))
func enlarge_card(item:Dictionary)->void:
 if is_instance_valid(_full_card):_full_card.queue_free()
 _full_card=PanelContainer.new();_full_card.position=Vector2(100,90);_full_card.size=Vector2(1600,830);_full_card.add_theme_stylebox_override("panel",Kit.satchel_box(16,3,16));add_child(_full_card)
 var row:=HBoxContainer.new();_full_card.add_child(row)
 var card_host:=Control.new();card_host.custom_minimum_size=Vector2(620,800);row.add_child(card_host)
 if item.get("user",false) and item.get("kind","")=="city_intro":
  _image(card_host,_texture(str(item.path)))
 elif item.has("user_card"):
  var view:=preload("res://scripts/ui/custom_city_intro_view.gd").new();view.size=Vector2(600,800);card_host.add_child(view);view.bind_card(item.user_card,str(item.name),{},str(item.city_id))
 else:
  var card:=preload("res://scenes/ui/components/formal_city_card.tscn").instantiate();card_host.add_child(card);card.custom_minimum_size=Vector2(600,800);card.size=Vector2(600,800);card.bind_resolved(_resolved(item),GameState.content)
 var column:=VBoxContainer.new();column.size_flags_horizontal=Control.SIZE_EXPAND_FILL;row.add_child(column)
 var close:=_button("收起大牌面","primary");column.add_child(close);close.pressed.connect(func()->void:_full_card.queue_free())
 var resolved:=_resolved(item);var text:=_label(str(item.name)+"\n\n"+str(item.get("user_card",{}).get("description",resolved.get("intro","")))+"\n\n"+str(resolved.get("scenery",""))+"\n\n"+str(resolved.get("map_attribute","")));text.custom_minimum_size.x=870;column.add_child(text)
func _build_reuse(item:Dictionary)->void:
 if item.category=="trade_card":return
 targets=_select([]);targets.custom_minimum_size.x=800;detail.add_child(targets)
 for city in workshop.doc.doc.get("new_cities",[]):
  if item.category in ["city_model","good_icon"]:_target(str(city.name)+(" · 城市模型" if item.category=="city_model" else " · 商品图片"),{"role":item.category,"slot":city.slot})
 if item.category in ["good_icon","city_card"]:
  for cid in GameState.content.get("cities",{}):
   var name:=str(GameState.content.cities[cid].display_name)
   if item.category=="good_icon":_target(name+" · 名牌图片",{"role":"badge_icon","cid":cid})
   _target(name+" · 介绍插图",{"role":"city_intro","cid":cid})
 if item.category=="piece":
  var transport:=str(item.get("transport",""))
  for kind in ["CAMEL","SHIP"]:
   if transport!="" and transport!=kind:continue
   _target("全体玩家 · "+("陆路棋子" if kind=="CAMEL" else "海路棋子"),{"role":"piece","transport":kind})
 reuse_button=_button("用到当前地图 · 预览确认","primary");detail.add_child(reuse_button);reuse_button.disabled=targets.item_count==0 or item.archived or item.source=="retired"
 reuse_button.pressed.connect(begin_reuse)
 targets.item_selected.connect(func(_i:int)->void:_target_changed())
 _target_changed()
func _target(label:String,value:Dictionary)->void:targets.add_item(label);targets.set_item_metadata(targets.item_count-1,value)
func _target_changed()->void:
 if targets.item_count>0:target_label.text="目标：当前地图《%s》 · %s"%[workshop.doc.map_name(),targets.get_item_text(targets.selected)]
func begin_reuse()->void:
 if targets.item_count==0 or selected.is_empty() or target_sha!=workshop.doc.sha():message.text="地图已改变，请刷新资源库。";return
 var item:=selected.duplicate(true);var target:Dictionary=targets.get_item_metadata(targets.selected);var label:=targets.get_item_text(targets.selected);var sha:=target_sha
 # Explicit, narrow replacement scope. Every other known document keeps its old binding.
 var text:="将改变：当前地图《%s》 · %s\n确认后进入原有预览面板，应用可以一步撤销。\n其他库地图、备份、回收站、安装副本不会改变；旧SHA文件保留。\n外部携带包无法检查。"%[workshop.doc.map_name(),label]
 workshop.dialogs.confirm("asset_reuse_scope","复用 / 替换影响范围",text,[{"id":"cancel","text":"取消","kind":"safe"},{"id":"prepare","text":"进入预览","kind":"middle"}],func(choice:String)->void:
  if choice=="prepare":_reuse(item,target,sha))
func _rights(item:Dictionary)->int:
 var claims:Array=item.get("meta",{}).get("claims",[])
 # Explicitly choose the retained declaration; safest default remains unknown.
 if claims.size()==1:return ["private_unknown","owned","permission"].find(claims[0].rights)
 return 0
func _reuse(item:Dictionary,target:Dictionary,sha:String)->Dictionary:
 if sha!=workshop.doc.sha():return CustomMapLocalAssets.fail("地图已改变，未准备应用")
 var path:=str(item.path);close_tools();workshop._v02_shell.select_mode()
 var result:Dictionary={"ok":true}
 match str(target.role):
  "city_model","good_icon":
   workshop._local_assets.open_tools();result=workshop._local_assets.prepare(path,str(target.role),str(target.slot),sha);workshop._local_assets.rights.select(_rights(item))
  "piece":
   workshop._piece_tools.open_tools();workshop._piece_tools.load_transport(str(target.transport));result=workshop._piece_tools.prepare(path,str(target.transport),sha,workshop._piece_tools.generation)
   if result.ok:
    var preset:Dictionary=item.definition
    var idle:=str(preset.get("idle","idle" if item.source=="preset" else ""));var move:=str(preset.get("move","move" if item.source=="preset" else ""));var clips:Array=[]
    for clip in result.get("clips",[]):clips.append(str(clip.name))
    if (idle!="" and idle not in clips) or (move!="" and move not in clips):
     workshop._piece_tools.close_tools();workshop.say("预设声明的动画与真实模型不匹配，未准备应用");return CustomMapLocalAssets.fail("预设声明的动画与真实模型不匹配")
    workshop._piece_tools._loading=true;workshop._piece_tools.size_edit.value=float(preset.get("size",1));workshop._piece_tools.yaw_edit.value=float(preset.get("yaw",0));workshop._piece_tools.pivot_edit.value=float(preset.get("pivot",0));workshop._piece_tools._fill_clips(str(preset.get("idle","idle" if item.source=="preset" else "")),str(preset.get("move","move" if item.source=="preset" else "")));workshop._piece_tools.rights.select(_rights(item));workshop._piece_tools._loading=false;workshop._piece_tools.refresh()
  "city_intro":
   workshop._intro_tools.open_tools();workshop._intro_tools.load_city(str(target.cid));result=workshop._intro_tools.prepare_image(path,str(target.cid),sha,workshop._intro_tools.generation);workshop._intro_tools.rights.select(_rights(item))
  "badge_icon":
   workshop.board.sel={"kind":"city","id":str(target.cid)};workshop._refresh_panel();workshop._begin_badge_import_context(str(target.cid));workshop._import_badge_image(path,["private_unknown","owned","permission"][_rights(item)])
 if not result.ok:workshop.say(str(result.message))
 return result
func _metadata_editor(item:Dictionary)->void:
 detail.add_child(_label("我的附属元数据 · 地图格式保持"))
 var claim_source:=_line("补充来源 / 权利说明；已有声明保留");detail.add_child(claim_source)
 var claim_rights:=_select(["私用 · 许可未确认","我拥有素材权利","已获得使用许可"]);detail.add_child(claim_rights)
 var claim_save:=_button("保存这条许可声明");detail.add_child(claim_save);claim_save.pressed.connect(func()->void:
  var result:=Meta.declare(str(item.content_id),["private_unknown","owned","permission"][claim_rights.selected],claim_source.text)
  if result.ok:reload();message.text="许可声明已保存，原声明保留。"
  else:message.text=result.message)
 edit_name=_line("显示名称");edit_name.text=str(item.meta.display_name);detail.add_child(edit_name)
 edit_tags=_line("标签，以逗号分隔");edit_tags.text=",".join(item.meta.get("tags",[]));detail.add_child(edit_tags)
 edit_note=_text("备注");edit_note.text=str(item.meta.note);detail.add_child(edit_note)
 var save:=_button("保存名称、标签与备注","primary");detail.add_child(save);save.pressed.connect(func()->void:
  var tags:Array=[]
  for tag in edit_tags.text.split(","):
   if tag.strip_edges()!="":tags.append(tag.strip_edges())
  var result:=Meta.edit(str(item.content_id),{"display_name":edit_name.text.strip_edges(),"tags":tags,"note":edit_note.text})
  if result.ok:reload();message.text="元数据已完整保存。"
  else:message.text=result.message)
 var archive:=_button("恢复到可用列表" if item.archived else "归档此资源");detail.add_child(archive);archive.disabled=not item.archived and not item.refs.is_empty()
 if archive.disabled:archive.tooltip_text="有本机已知引用，受保护；包含备份和回收站。"
 archive.pressed.connect(func()->void:
  var id:=str(item.content_id);var value:=not bool(item.archived)
  workshop.dialogs.confirm("asset_archive","归档资源？" if value else "恢复资源？","只更改列表状态，SHA文件保留。\n恢复后可再次用于地图。",[{"id":"cancel","text":"取消","kind":"safe"},{"id":"confirm","text":"确认归档" if value else "确认恢复","kind":"middle"}],func(choice:String)->void:
   if choice!="confirm":return
   var refs:=Refs.scan(workshop.doc.doc,Library.builtins(workshop._base_content,workshop.catalogue))
   var result:=Meta.archive(id,value,refs.items.get(id,[]))
   if result.ok:selected={};reload();message.text="已归档；文件保留。" if value else "已恢复。"
   else:message.text=result.message))
func _dismiss_picker()->void:
 if is_instance_valid(file_dialog):file_dialog.hide();file_dialog.queue_free()
 file_dialog=null
func open_import()->void:
 if category=="trade_card":message.text="交易卡为冻结或地图派生规则内容，只读；不能导入自由价格卡。";return
 generation+=1;var token:=generation;_dismiss_picker()
 var kind:="actor_model" if category=="piece" else ("city_model" if category=="city_model" else "good_icon")
 var purpose:="city_intro" if category=="city_card" else kind
 file_dialog=FileDialog.new();file_dialog.access=FileDialog.ACCESS_FILESYSTEM;file_dialog.file_mode=FileDialog.FILE_MODE_OPEN_FILE;file_dialog.use_native_dialog=not test_use_godot_picker;file_dialog.filters=PackedStringArray(["*.glb ; 自包含 GLB"] if kind in ["actor_model","city_model"] else ["*.png,*.jpg,*.jpeg ; PNG / JPEG"]);add_child(file_dialog)
 file_dialog.file_selected.connect(func(file:String)->void:
  if token==generation and visible:prepare_import(file,kind,purpose))
 file_dialog.canceled.connect(func()->void:generation+=1;message.text="已取消选择；文件、地图和元数据未改变。")
 file_dialog.popup_centered(Vector2i(900,620))
func prepare_import(path:String,kind:String,purpose:String="")->Dictionary:
 var checked:=CustomMapLocalAssets.inspect_file(path,kind)
 if not checked.ok:message.text=checked.message;return checked
 _clear_detail();selected={};import_pending=checked;import_purpose=purpose if purpose!="" else ("city_intro" if category=="city_card" else kind)
 detail.add_child(Kit.label("确认入库 · 地图稍后再用",30,Kit.INK))
 detail.add_child(_label("已通过现行格式与预算门禁。\n取消入库前不会写入SHA文件或元数据；确认入库后取消地图应用，保留已确认资源。"))
 preview=Control.new();preview.custom_minimum_size=Vector2(850,400);detail.add_child(preview)
 if kind=="good_icon":_image(preview,ImageTexture.create_from_image(checked.image))
 else:
  var item:=Library.record("piece" if kind=="actor_model" else "city_model","pending",path.get_file(),"pending",path);item.definition={};model_preview=ModelPreview.new();model_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);preview.add_child(model_preview);model_preview.show_item(item,Color(str(GameData.get_player_colors(GameState.content)[0].color)),"idle")
 import_name=_line("显示名称");import_name.text=path.get_file().get_basename();detail.add_child(import_name)
 import_note=_text("备注（附属元数据）");detail.add_child(import_note)
 import_source=_line("来源 / 权利说明（不自动合并不同声明）");detail.add_child(import_source)
 import_rights=_select(["私用 · 许可未确认","我拥有素材权利","已获得使用许可"]);detail.add_child(import_rights)
 detail.add_child(_label("SHA："+str(checked.id)+" · %d KB"%(checked.bytes.size()/1024)))
 var confirm:=_button("确认入库","primary");detail.add_child(confirm);confirm.pressed.connect(confirm_import)
 var cancel:=_button("取消入库");detail.add_child(cancel);cancel.pressed.connect(cancel_import)
 message.text="预览就绪；确认入库前没有持久写入。"
 return checked
func cancel_import()->void:
 import_pending={};selected={};reload();message.text="已取消入库；没有新增文件或元数据。"
func confirm_import()->Dictionary:
 if import_pending.is_empty():return CustomMapLocalAssets.fail("没有待确认资源")
 var result:=Meta.admit(import_pending,{"display_name":import_name.text.strip_edges(),"note":import_note.text,"tags":[],"purpose_hint":import_purpose},["private_unknown","owned","permission"][import_rights.selected],import_source.text)
 if not result.ok:message.text=result.message;return result
 var id:=str(result.id)
 data=Library.collect(workshop._base_content,workshop.catalogue,workshop.doc.doc,GameState.content)
 for item in data.items:
  if item.user and item.content_id==id and item.category==("city_card" if import_purpose=="city_intro" else ("piece" if import_purpose=="actor_model" else import_purpose)):
   category=str(item.category);source_filter.select(5);state_filter.select(1 if item.archived else 0);fit_filter.select(0);search.text=id.get_basename().substr(0,12);selected={};refresh_grid();break
 message.text="内容相同，已定位原条目；许可声明分别保留。" if result.duplicate else "已确认入库；可预览并用到当前地图。"
 return result
func show_dependencies()->void:
 _clear_detail();selected={};dependencies=Refs.dependencies(workshop.doc.doc);detail.add_child(Kit.label("当前地图 · 依赖清单",30,Kit.INK))
 detail.add_child(_label("逐条核验SHA、实际格式与现行预算。导出沿用 map.json + assets；拒绝覆盖已有目录。"))
 if dependencies.is_empty():detail.add_child(_label("当前地图使用内置资源，无独立私用文件依赖。"))
 for item in dependencies:detail.add_child(_label(("✓ " if item.ok else "⚠ ")+str(item.id)+"\n"+str(item.kind)+" · "+"、".join(item.uses)+"\n"+str(item.message),Kit.INK if item.ok else Color("b74333")))
 var export:=_button("导出当前地图携带包","primary");detail.add_child(export);export.disabled=dependencies.any(func(item:Dictionary)->bool:return not item.ok)
 export.pressed.connect(func()->void:_bundle(true))
 var restore:=_button("打开资产包 · 恢复依赖");detail.add_child(restore);restore.pressed.connect(func()->void:_bundle(false))
func _bundle(exporting:bool)->void:
 close_tools();workshop._local_assets.open_tools();workshop._local_assets.open_bundle_dialog(exporting)
func _rect(control:Control)->Array:
 var rect:=control.get_global_rect();return [rect.position.x,rect.position.y,rect.size.x,rect.size.y]
func _observer_rect(control:Variant)->Array:
 if not is_instance_valid(control):return []
 if not control is Control or not control.is_visible_in_tree():return []
 return _rect(control as Control)
func observer()->Dictionary:
 var hover:Control=get_viewport().gui_get_hovered_control()
 var preview_actions:Dictionary={}
 if selected.get("category","")=="piece" and detail.get_child_count()>2 and detail.get_child(2) is HBoxContainer:
  for button in detail.get_child(2).get_children():
   if button is Button:preview_actions[str(button.text)]=_observer_rect(button)
 var grid_items:Array=[]
 for section in grid.get_children():
  if section is GridContainer:
   for button:Button in section.get_children():grid_items.append({"semantic_id":str(button.get_meta("semantic_id","")),"rect":_rect(button)})
 var groups:Array=[]
 for group in piece_groups:groups.append({"key":group.key,"title":group.title,"members":group.members,"rect":_observer_rect(group.heading)})
 return {"piece_groups":groups,"hovered_control":str(hover.get_path()) if is_instance_valid(hover) else "","hovered_text":str(hover.text) if hover is Button else "","preview_actions":preview_actions,"preview_moving":model_preview.moving if is_instance_valid(model_preview) else false,"token_moving":model_preview.token._moving if is_instance_valid(model_preview) and is_instance_valid(model_preview.token) else false,"token_walk_phase":model_preview.token.walk_phase if is_instance_valid(model_preview) and is_instance_valid(model_preview.token) else 0,"controls":{"search":_rect(search),"source":_rect(source_filter),"state":_rect(state_filter),"fit":_rect(fit_filter),"targets":_rect(targets) if is_instance_valid(targets) else [],"edit_name":_observer_rect(edit_name),"edit_tags":_observer_rect(edit_tags),"edit_note":_observer_rect(edit_note),"import_name":_observer_rect(import_name),"import_note":_observer_rect(import_note),"import_source":_observer_rect(import_source),"import_rights":_observer_rect(import_rights)},"grid_items":grid_items,"preview_rotation":model_preview.orbit.rotation.y if is_instance_valid(model_preview) and is_instance_valid(model_preview.orbit) else 0,"preview_rect":_rect(preview) if is_instance_valid(preview) else [],"visible":visible,"category":category,"selected":str(selected.get("semantic_id","")),"selected_sha":str(selected.get("sha","")),"query":search.text,"source":source_filter.get_item_metadata(source_filter.selected),"state":state_filter.selected,"fit":_fit(),"displayed":displayed.map(func(item:Dictionary)->String:return str(item.semantic_id)),"pending_import":str(import_pending.get("id","")),"preview_mode":preview_mode,"player_color":player_color,"preview_mechanism":model_preview.mechanism if is_instance_valid(model_preview) else "","dependencies":dependencies,"message":message.text}
