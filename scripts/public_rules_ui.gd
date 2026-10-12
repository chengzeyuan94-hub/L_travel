class_name PublicRulesUI
extends CanvasLayer
var dialog: Window
var edit: TextEdit
var status: Label
var picker: FileDialog
static func attach(parent: Node) -> PublicRulesUI:
	var ui := PublicRulesUI.new(); ui.name="PublicRulesSettings"; parent.add_child(ui); return ui
func _ready() -> void:
	layer=400
	var theme:=Theme.new(); theme.default_font=preload("res://scripts/lshu_ui/lshu_ui_kit.gd").font(); theme.default_font_size=20
	get_parent().set_meta("public_rules_theme",theme)
	var button:=Button.new(); button.theme=get_parent().get_meta("public_rules_theme"); button.text="配置玩法规则"; button.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	button.position=Vector2(-220,-65); button.size=Vector2(205,48); button.pressed.connect(open); add_child(button)
	var workshop:=Button.new(); workshop.theme=get_parent().get_meta("public_rules_theme"); workshop.text="打开地图工坊"; workshop.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	workshop.position=Vector2(-435,-65); workshop.size=Vector2(205,48)
	workshop.visible=not str(get_parent().scene_file_path).contains("map_workshop")
	workshop.pressed.connect(func()->void: get_tree().change_scene_to_file("res://scenes/map_workshop/map_workshop_main.tscn")); add_child(workshop)
func open() -> void:
	if is_instance_valid(dialog): dialog.popup_centered(); return
	dialog=Window.new(); dialog.title="先与使用者确认玩法规则"; dialog.size=Vector2i(920,650); dialog.unresizable=false
	dialog.close_requested.connect(func()->void: dialog.hide()); add_child(dialog)
	var box:=VBoxContainer.new(); box.theme=get_parent().get_meta("public_rules_theme"); box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); box.offset_left=20; box.offset_top=20; box.offset_right=-20; box.offset_bottom=-20; dialog.add_child(box)
	status=Label.new(); status.text="公开版没有原80牌及原事件文字。先确认经济、事件和城市特产，再填写配置。\n未配置时可编辑保存地图；正式开局和试玩不可用。"; status.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART; box.add_child(status)
	var import_button:=Button.new(); import_button.text="导入已确认的规则文件"
	import_button.pressed.connect(func()->void:
		if not is_instance_valid(picker):
			picker=FileDialog.new(); picker.file_mode=FileDialog.FILE_MODE_OPEN_FILE; picker.access=FileDialog.ACCESS_FILESYSTEM
			picker.filters=PackedStringArray(["*.json ; 规则配置"]); picker.use_native_dialog=true; dialog.add_child(picker)
			picker.file_selected.connect(func(file:String)->void:
				var result:=PublicRules.install(FileAccess.get_file_as_string(file))
				status.text="规则已保存，重新打开工坊后生效。" if result.ok else "尚未保存："+"；".join(result.errors))
		picker.popup_centered(Vector2i(850,550)))
	box.add_child(import_button)
	var advanced:=Button.new(); advanced.text="高级编辑（JSON）"; box.add_child(advanced)
	edit=TextEdit.new(); edit.size_flags_vertical=Control.SIZE_EXPAND_FILL; edit.custom_minimum_size.y=420
	var cfg:=PublicRules.configuration(); edit.text=JSON.stringify(PublicRules.template() if cfg.is_empty() else cfg,"  "); box.add_child(edit); edit.visible=false
	advanced.pressed.connect(func()->void: edit.visible=not edit.visible)
	var apply_button:=Button.new(); apply_button.text="校验并保存已确认的规则"
	apply_button.pressed.connect(func()->void:
		var result:=PublicRules.install(edit.text)
		status.text="规则已保存。重新打开工坊，使已打开地图按新规则重新校验。" if result.ok else "尚未保存："+"；".join(result.errors))
	box.add_child(apply_button); dialog.popup_centered()
