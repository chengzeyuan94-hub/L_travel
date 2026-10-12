extends PanelContainer
const Kit:=preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
const Backend:=preload("res://scripts/map_workshop/workshop_backend.gd")
var workshop:Control
var select_city:OptionButton
var title_edit:LineEdit
var description_edit:TextEdit
var rights:OptionButton
var preview:Control
var confirm:Button
var cancel_button:Button
var remove_button:Button
var remove_image_button:Button
var image_button:Button
var message:Label
var file_dialog:FileDialog
var pending:Dictionary={}
var image_id:=""
var target_city:=""
var source_sha:=""
var generation:=0
var test_use_godot_picker:=false
var _loading:=false
func _ready()->void:
 position=Vector2(1520,76);custom_minimum_size=Vector2(400,952);add_theme_stylebox_override("panel",Kit.satchel_box(20,4,20));hide()
 var scroll:=ScrollContainer.new();scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED;add_child(scroll)
 var row:=VBoxContainer.new();row.custom_minimum_size.x=350;row.add_theme_constant_override("separation",24);scroll.add_child(row)
 var edit:=VBoxContainer.new();edit.custom_minimum_size.x=350;row.add_child(edit)
 edit.add_child(Kit.label("城市介绍卡 · 一城一张",28,Kit.INK))
 select_city=OptionButton.new();select_city.custom_minimum_size.y=44;edit.add_child(select_city)
 edit.add_child(Kit.label("标题：1–24字；介绍：1–360字、最多8行",18,Kit.INK_SOFT))
 title_edit=LineEdit.new();title_edit.custom_minimum_size.y=44;title_edit.placeholder_text="介绍卡标题";edit.add_child(title_edit)
 description_edit=TextEdit.new();description_edit.custom_minimum_size.y=180;description_edit.wrap_mode=TextEdit.LINE_WRAPPING_BOUNDARY;description_edit.add_theme_font_override("font",Kit.font("body",500));description_edit.add_theme_font_size_override("font_size",22);edit.add_child(description_edit)
 rights=OptionButton.new()
 for label in ["图片私用 · 许可未确认","我拥有图片权利","已获得图片使用许可"]:rights.add_item(label)
 rights.custom_minimum_size.y=40;edit.add_child(rights)
 var buttons:=VBoxContainer.new();edit.add_child(buttons)
 image_button=Kit.button("选择介绍图片","cream",44,20);buttons.add_child(image_button);image_button.pressed.connect(open_image)
 remove_image_button=Kit.button("解除图片绑定","cream",44,20);buttons.add_child(remove_image_button);remove_image_button.pressed.connect(clear_image)
 confirm=Kit.button("确认应用到地图（可撤销）","primary",48,21);edit.add_child(confirm);confirm.pressed.connect(apply_draft)
 var lower:=VBoxContainer.new();edit.add_child(lower)
 cancel_button=Kit.button("取消未确认草稿","cream",44,19);lower.add_child(cancel_button);cancel_button.pressed.connect(cancel)
 remove_button=Kit.button("解除整张介绍卡","cream",44,19);lower.add_child(remove_button);remove_button.pressed.connect(remove_card)
 var close:=Kit.button("结束介绍卡编辑","cream",42,19);edit.add_child(close);close.pressed.connect(close_tools)
 message=Kit.label("纯文本实时预览；切城市会取消未确认草稿。",18,Kit.INK_SOFT);message.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;edit.add_child(message)
 preview=preload("res://scripts/ui/custom_city_intro_view.gd").new();preview.custom_minimum_size=Vector2(350,460);preview.size_flags_horizontal=Control.SIZE_EXPAND_FILL;row.add_child(preview)
 select_city.item_selected.connect(func(_i:int)->void:load_city(str(select_city.get_item_metadata(select_city.selected))))
 title_edit.text_changed.connect(func(_text:String)->void:refresh());description_edit.text_changed.connect(refresh)
func open_tools()->void:
 generation+=1;select_city.clear()
 var content:Dictionary=GameState.content
 var ids:Array=content.get("cities",{}).keys();ids.sort()
 for cid in ids:select_city.add_item(str(content.cities[cid].display_name));select_city.set_item_metadata(select_city.item_count-1,str(cid))
 show();workshop.panel.hide()
 if select_city.item_count>0:load_city(str(select_city.get_item_metadata(0)))
func city_name()->String:
 return str(GameState.content.get("cities",{}).get(target_city,{}).get("display_name",target_city))
func _dismiss_picker()->void:
 if is_instance_valid(file_dialog):file_dialog.hide();file_dialog.queue_free()
 file_dialog=null
func load_city(cid:String)->void:
 _dismiss_picker()
 generation+=1;target_city=cid;source_sha=workshop.doc.sha();pending.clear();_loading=true
 for i in select_city.item_count:
  if str(select_city.get_item_metadata(i))==cid:select_city.select(i)
 var card:=CustomMapCityIntro.card(workshop.doc.doc,cid)
 title_edit.text=str(card.get("title",city_name()));description_edit.text=str(card.get("description",GameState.content.get("card_text_cities",{}).get(cid,{}).get("intro","写下这座城市的故事。")));image_id=str(card.get("image",""));rights.select(0)
 _loading=false;refresh()
func refresh()->void:
 if _loading:return
 var normalized:=CustomMapCityIntro.normalize_lines(description_edit.text)
 if normalized!=description_edit.text:
  _loading=true;description_edit.text=normalized;_loading=false
 var bad:=CustomMapCityIntro.text_error(title_edit.text,description_edit.text)
 confirm.disabled=bad!="" or source_sha!=workshop.doc.sha()
 remove_button.disabled=CustomMapCityIntro.card(workshop.doc.doc,target_city).is_empty()
 remove_image_button.disabled=image_id=="" and pending.is_empty()
 preview.bind_card({"title":title_edit.text,"description":description_edit.text,"image":image_id},city_name(),pending,target_city)
 message.text=bad if bad!="" else "实时预览 · %d/24字，%d/360字；确认前不会改变地图。" % [title_edit.text.length(),description_edit.text.length()]
func cancel()->void:
 if target_city!="":load_city(target_city)
 message.text="未确认草稿已取消，地图与撤销记录未改变。"
func close_tools()->void:
 generation+=1;pending.clear();source_sha="";hide();workshop.panel.show()
 _dismiss_picker()
func clear_image()->void:
 _dismiss_picker()
 generation+=1;pending.clear();image_id="";refresh()
func open_image()->void:
 if target_city=="":return
 generation+=1;var token:=generation;var cid:=target_city;var sha:=source_sha
 _dismiss_picker()
 file_dialog=FileDialog.new();file_dialog.access=FileDialog.ACCESS_FILESYSTEM;file_dialog.file_mode=FileDialog.FILE_MODE_OPEN_FILE;file_dialog.use_native_dialog=not test_use_godot_picker;file_dialog.filters=PackedStringArray(["*.png,*.jpg,*.jpeg ; 城市介绍图片"]);add_child(file_dialog)
 file_dialog.file_selected.connect(func(file:String)->void:prepare_image(file,cid,sha,token));file_dialog.popup_centered(Vector2i(850,600))
func prepare_image(file:String,cid:String,sha:String,token:int)->Dictionary:
 if not visible or cid!=target_city or sha!=source_sha or sha!=workshop.doc.sha() or token!=generation:return CustomMapLocalAssets.fail("草稿或城市已改变，请重新选择图片")
 var result:=CustomMapLocalAssets.inspect_file(file,"good_icon")
 if not result.ok:message.text=result.message;return result
 result.source_name=file.get_file().get_basename();pending=result;image_id=result.id;refresh();return result
func apply_draft()->Dictionary:
 if not visible or source_sha!=workshop.doc.sha() or not CustomMapCityIntro.city_ids(workshop.doc.doc).has(target_city):return CustomMapLocalAssets.fail("地图已改变，请重新打开介绍卡编辑")
 var bad:=CustomMapCityIntro.text_error(title_edit.text,description_edit.text)
 if bad!="":message.text=bad;return CustomMapLocalAssets.fail(bad)
 var before:Dictionary=workshop.doc.doc.duplicate(true)
 var candidate:=CustomMapCityIntro.candidate(before,target_city,title_edit.text,description_edit.text,image_id,pending,["private_unknown","owned","permission"][rights.selected])
 if candidate==before:load_city(target_city);return {"ok":true,"unchanged":true}
 var shape:=candidate.duplicate(true);shape.erase("assets");shape.erase("city_intro_cards");shape.erase("piece_skins");CustomMapCityBadges.clear_image_dependencies(shape)
 if not Backend.validate(workshop.board.base_layout,shape,workshop.board.geo,workshop.catalogue).ok:return CustomMapLocalAssets.fail("地图未通过校验，草稿没有应用")
 if not pending.is_empty():
  var copied:=CustomMapAssetMeta.admit(pending,{"display_name":str(pending.get("source_name",pending.id)),"tags":[],"note":""},["private_unknown","owned","permission"][rights.selected],"当前地图 · "+target_city+" · 介绍插图")
  if not copied.ok:message.text=copied.message;return copied
 var checked:Dictionary=Backend.validate(workshop.board.base_layout,candidate,workshop.board.geo,workshop.catalogue)
 if not checked.ok:message.text="介绍卡或地图未通过校验，草稿没有应用";return CustomMapLocalAssets.fail(message.text)
 workshop.doc.doc=candidate;workshop.doc._touch();workshop._commit(before,"编辑城市介绍卡",checked);load_city(target_city);return {"ok":true}
func remove_card()->Dictionary:
 if source_sha!=workshop.doc.sha():return CustomMapLocalAssets.fail("地图已改变，请重新打开")
 var before:Dictionary=workshop.doc.doc.duplicate(true);var candidate:=CustomMapCityIntro.remove(before,target_city)
 if candidate==before:return {"ok":true,"unchanged":true}
 var checked:Dictionary=Backend.validate(workshop.board.base_layout,candidate,workshop.board.geo,workshop.catalogue)
 if not checked.ok:return CustomMapLocalAssets.fail("地图未通过校验")
 workshop.doc.doc=candidate;workshop.doc._touch();workshop._commit(before,"解除城市介绍卡",checked);load_city(target_city);return {"ok":true}
