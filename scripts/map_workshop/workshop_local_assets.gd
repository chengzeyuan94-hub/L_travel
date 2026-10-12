extends PanelContainer
const Backend := preload("res://scripts/map_workshop/workshop_backend.gd")
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
var workshop: Control
var pending: Dictionary = {}
var source_sha := ""
var target_slot := ""
var target_kind := ""
var select_city: OptionButton
var select_kind: OptionButton
var rights: OptionButton
var message: Label
var target_label: Label
var confirm: Button
var cancel_button: Button
var choose_button: Button
var file_dialog: FileDialog
var preview: Control
var test_use_godot_picker := false
var _button: Button
func _ready() -> void:
 position=Vector2(1520,76);custom_minimum_size=Vector2(400,952);add_theme_stylebox_override("panel",Kit.satchel_box(20,4,20));visible=false
 var col:=VBoxContainer.new();add_child(col)
 col.add_child(Kit.label("导入自己的城市与商品",26,Kit.INK))
 target_label=Kit.label("",20,Kit.INK);target_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;col.add_child(target_label)
 select_city=OptionButton.new();select_city.custom_minimum_size.y=44;col.add_child(select_city)
 select_kind=OptionButton.new();select_kind.add_item("城市模型 · GLB");select_kind.add_item("商品图片 · PNG / JPEG");select_kind.custom_minimum_size.y=44;col.add_child(select_kind)
 rights=OptionButton.new()
 for label in ["私用 · 许可未确认","我拥有素材权利","已获得使用许可"]:rights.add_item(label)
 rights.custom_minimum_size.y=44;col.add_child(rights)
 choose_button=Kit.button("选择本机文件", "cream",48,22);choose_button.name="ChooseLocalAsset";col.add_child(choose_button);choose_button.pressed.connect(open_file)
 message=Kit.label("选一个文件开始预览。",18,Kit.INK_SOFT);message.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART;message.custom_minimum_size.x=350;col.add_child(message)
 preview=Control.new();preview.custom_minimum_size=Vector2(350,220);col.add_child(preview)
 confirm=Kit.button("确认预览并应用（可撤销）","primary",48,21);confirm.name="ConfirmLocalAsset";col.add_child(confirm);confirm.pressed.connect(apply_pending)
 cancel_button=Kit.button("取消预览","cream",44,20);cancel_button.name="CancelLocalAsset";col.add_child(cancel_button);cancel_button.pressed.connect(cancel)
 var files:=VBoxContainer.new();col.add_child(files)
 for spec in [[true,"导出携带资产包"],[false,"打开资产包"]]:
  var b:=Kit.button(spec[1],"cream",44,18);files.add_child(b);b.pressed.connect(func()->void:open_bundle_dialog(spec[0]))
 var close:=Kit.button("结束素材编辑","cream",44,20);col.add_child(close);close.pressed.connect(func()->void:cancel();hide();workshop.panel.visible=true)
 col.add_child(Kit.label("确认前不会写入地图。",18,Kit.INK_SOFT))
 select_city.item_selected.connect(func(_i:int)->void:cancel();_target_text());select_kind.item_selected.connect(func(_i:int)->void:cancel();_target_text());confirm.disabled=true
func open_tools() -> void:
 cancel();select_city.clear()
 for c in workshop.doc.doc.get("new_cities",[]):
  select_city.add_item(str(c.name));select_city.set_item_metadata(select_city.item_count-1,str(c.slot))
  if "x_"+str(c.slot)==str(workshop.board.sel.id):select_city.select(select_city.item_count-1)
 message.text="选一个文件开始预览。";message.add_theme_color_override("font_color",Kit.INK_SOFT);_target_text()
 choose_button.disabled=select_city.item_count==0
 show();workshop.panel.visible=false
 if select_city.item_count==0:message.text="先新增一对城市，再给其中的城市或商品导入素材。"
func cancel() -> void:
 pending.clear();source_sha="";target_slot="";target_kind="";confirm.disabled=true
 for c in preview.get_children():c.queue_free()
 if is_instance_valid(message):message.text="预览已取消，地图与撤销记录未改变。";message.add_theme_color_override("font_color",Kit.INK_SOFT)
func _picker(mode: int, title: String, filters: PackedStringArray) -> FileDialog:
 if is_instance_valid(file_dialog):file_dialog.queue_free()
 file_dialog=FileDialog.new();file_dialog.access=FileDialog.ACCESS_FILESYSTEM;file_dialog.file_mode=mode;file_dialog.title=title;file_dialog.filters=filters;file_dialog.use_native_dialog=not test_use_godot_picker;add_child(file_dialog)
 return file_dialog
func open_file() -> void:
 if select_city.item_count==0:return
 cancel();var kind:="city_model" if select_kind.selected==0 else "good_icon"
 var slot:=str(select_city.get_item_metadata(select_city.selected));var sha:String=workshop.doc.sha()
 var dialog:=_picker(FileDialog.FILE_MODE_OPEN_FILE,"选择自己的城市模型" if kind=="city_model" else "选择自己的商品图片",PackedStringArray(["*.glb ; 自包含静态城市 GLB"] if kind=="city_model" else ["*.png,*.jpg,*.jpeg ; 商品图片"]))
 dialog.file_selected.connect(func(file:String)->void:prepare(file,kind,slot,sha));dialog.canceled.connect(cancel);dialog.popup_centered(Vector2i(850,600))
func prepare(file: String, kind: String, slot: String, sha: String) -> Dictionary:
 cancel()
 if sha!=workshop.doc.sha():message.text="地图已改变，请重新选择。";return CustomMapLocalAssets.fail(message.text)
 var found:=false
 for city in workshop.doc.doc.get("new_cities",[]):
  if str(city.get("slot",""))==slot:found=true
 if not found:message.text="目标城市已经不存在。";return CustomMapLocalAssets.fail(message.text)
 var result:=CustomMapLocalAssets.inspect_file(file,kind)
 if not result.ok:_error(str(result.message));return result
 for i in select_city.item_count:
  if str(select_city.get_item_metadata(i))==slot:select_city.select(i)
 select_kind.select(0 if kind=="city_model" else 1)
 result.source_name=file.get_file().get_basename();pending=result;source_sha=sha;target_slot=slot;target_kind=kind
 _show_preview();confirm.disabled=false
 message.text="预览已就绪：%d KB。确认后复制入地图资源包。" % (result.bytes.size()/1024)
 return result
func _show_preview() -> void:
 if pending.kind=="good_icon":
  var image:=TextureRect.new();image.texture=ImageTexture.create_from_image(pending.image);image.expand_mode=TextureRect.EXPAND_IGNORE_SIZE;image.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED;image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);preview.add_child(image);return
 var container:=SubViewportContainer.new();container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT);container.stretch=true;preview.add_child(container)
 var viewport:=SubViewport.new();viewport.size=Vector2i(510,220);viewport.own_world_3d=true;viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS;container.add_child(viewport)
 var node:=Node3D.new();viewport.add_child(node);var model:=pending.scene.instantiate() as Node3D;node.add_child(model)
 var box: AABB=pending.bounds;var scale_factor:=2.0/maxf(box.size.x,box.size.z);model.scale=Vector3.ONE*scale_factor;model.position=-Vector3(box.get_center().x,box.position.y,box.get_center().z)*scale_factor
 var camera:=Camera3D.new();camera.position=Vector3(3,2.3,4);camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.size=maxf(3.2,box.size.y*scale_factor*1.5);node.add_child(camera);camera.look_at(Vector3(0,box.size.y*scale_factor*0.5,0));camera.current=true
 var light:=DirectionalLight3D.new();light.rotation_degrees=Vector3(-45,-30,0);light.light_energy=1.8;node.add_child(light)
 var environment:=WorldEnvironment.new();environment.environment=Environment.new();environment.environment.background_mode=Environment.BG_COLOR;environment.environment.background_color=Color("e5dccb");environment.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;environment.environment.ambient_light_color=Color.WHITE;environment.environment.ambient_light_energy=0.7;node.add_child(environment)
func apply_pending() -> Dictionary:
 if pending.is_empty() or source_sha!=workshop.doc.sha():cancel();message.text="地图已改变或没有有效预览，请重新选择。";return CustomMapLocalAssets.fail(message.text)
 var before:Dictionary=workshop.doc.doc.duplicate(true)
 var rights_id:String=["private_unknown","owned","permission"][rights.selected]
 var candidate:=CustomMapLocalAssets.candidate(before,target_slot,pending,rights_id)
 if candidate==before:cancel();message.text="相同素材已经应用，没有新增撤销记录。";return {"ok":true,"unchanged":true}
 # Validate unchanged rules/geometry before writing any dependency.
 var without_assets:=candidate.duplicate(true);without_assets.erase("assets");without_assets.erase("city_intro_cards");without_assets.erase("piece_skins");CustomMapCityBadges.clear_image_dependencies(without_assets)
 var shape:Dictionary=Backend.validate(workshop.board.base_layout,without_assets,workshop.board.geo,workshop.catalogue)
 if not shape.ok:message.text="地图校验未通过，素材没有应用。";return CustomMapLocalAssets.fail(message.text)
 var published:=CustomMapAssetMeta.admit(pending,{"display_name":str(pending.get("source_name",pending.id)),"tags":[],"note":""},rights_id,"当前地图 · "+target_slot+" · "+target_kind)
 if not published.ok:message.text=published.message;return published
 var checked:Dictionary=Backend.validate(workshop.board.base_layout,candidate,workshop.board.geo,workshop.catalogue)
 if not checked.ok:message.text="资源或地图校验未通过，地图没有改变。";return CustomMapLocalAssets.fail(message.text)
 workshop.doc.doc=candidate;workshop.doc._touch();workshop._commit(before,"导入私用素材",checked);cancel();message.text="素材已复制并应用，可以撤销；导出资产包会带齐文件。";return {"ok":true}
func open_bundle_dialog(exporting: bool) -> void:
 cancel()
 var dialog:=_picker(FileDialog.FILE_MODE_OPEN_DIR if exporting else FileDialog.FILE_MODE_OPEN_FILE,"选择导出父目录" if exporting else "选择资产包内 map.json",PackedStringArray([] if exporting else ["*.json ; 地图资产包"]))
 if exporting:dialog.dir_selected.connect(func(parent:String)->void:var r:=export_bundle(parent.path_join(workshop.doc.map_id()+"_bundle"));message.text="携带资产包已导出。" if r.ok else r.message)
 else:dialog.file_selected.connect(func(file:String)->void:prepare_bundle(file))
 dialog.popup_centered(Vector2i(850,600))
func export_bundle(destination: String) -> Dictionary:
 var r:Dictionary=Backend.validate_for_editing(workshop.board.base_layout,workshop.doc.doc,workshop.board.geo,workshop.catalogue)
 return CustomMapLocalAssets.export_bundle(workshop.doc.doc,destination) if r.ok else CustomMapLocalAssets.fail("地图未通过校验")
func prepare_bundle(file: String) -> Dictionary:
 var result:=CustomMapLocalAssets.inspect_bundle(file)
 if not result.ok:_error(str(result.message));return result
 var sha:String=workshop.doc.sha()
 workshop.dialogs.confirm("local_bundle","打开携带资产的地图？","确认前保留当前稿。已保存的旧地图不会覆盖；资源仅复制到本机。",[{"id":"cancel","text":"取消","kind":"safe"},{"id":"open","text":"确认打开","kind":"middle"}],func(choice:String)->void:
  if choice!="open":return
  var applied:=apply_bundle(result,sha);message.text="资产包已打开。" if applied.ok else applied.message)
 return result
func apply_bundle(bundle: Dictionary, current_sha: String) -> Dictionary:
 if not bundle.get("ok",false) or current_sha!=workshop.doc.sha():return CustomMapLocalAssets.fail("当前稿已改变，请重新打开")
 # Preserve unsaved user draft instead of silently replacing it.
 if workshop.doc.is_dirty() and not workshop.doc.is_untouched():return CustomMapLocalAssets.fail("当前稿尚未保存，请先保存再打开资产包")
 if FileAccess.get_sha256(str(bundle.get("source_path","")))!=str(bundle.get("source_sha","")):return CustomMapLocalAssets.fail("资产包地图在预览后已改变")
 var doc:Dictionary=bundle.doc
 var shape:=doc.duplicate(true);shape.erase("assets");shape.erase("city_intro_cards");shape.erase("piece_skins");CustomMapCityBadges.clear_image_dependencies(shape)
 var shape_result:Dictionary=Backend.validate_for_editing(workshop.board.base_layout,shape,workshop.board.geo,workshop.catalogue)
 if not shape_result.ok:return CustomMapLocalAssets.fail("资产包地图校验未通过")
 for item in bundle.pending:
  var copied:=CustomMapLocalAssets.publish(item)
  if not copied.ok:return copied
 var result:Dictionary=Backend.validate_for_editing(workshop.board.base_layout,doc,workshop.board.geo,workshop.catalogue)
 if not result.ok:return CustomMapLocalAssets.fail("资产包完整校验未通过")
 workshop._switch_doc(doc,false)
 return {"ok":true}

func _target_text() -> void:
 if select_city.item_count==0:target_label.text="尚无可导入城市";return
 target_label.text="应用到：%s · %s" % [select_city.get_item_text(select_city.selected),"城市模型" if select_kind.selected==0 else "商品图片"]
func _error(text: String) -> void:
 message.text=text;message.add_theme_color_override("font_color",Color("cd483a"))
