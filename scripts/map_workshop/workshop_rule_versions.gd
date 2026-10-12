extends PanelContainer
const Kit := preload("res://scripts/lshu_ui/lshu_ui_kit.gd")
var workshop: Control
var versions: OptionButton
var note: Label
var preview: RichTextLabel
var confirm: Button
var prepared: Dictionary = {}

static func prepare_copy(source: Dictionary, target: String, base: Dictionary, layout: Dictionary, cat: Dictionary) -> Dictionary:
	if CustomMapFreeAuthor.enabled(source) and target!=CustomMapFreeAuthor.GENERATOR:return {"ok":false,"reason":"自由作品使用独立规则。请从原版兼容入口新建地图，当前作品保留。"}
	var problem := CustomMapTradegenRegistry.parameter_error(target)
	if problem != "": return {"ok": false, "reason": problem}
	var candidate := CustomMapFreeAuthor.enter(source,base) if target==CustomMapFreeAuthor.GENERATOR else source.duplicate(true)
	var fresh := CustomMapSchema.empty_doc("规则副本")
	candidate.map_id = fresh.map_id
	candidate.name = str(source.get("name", "地图")).left(5) + "·副本"
	candidate.tradegen = target
	candidate["workshop"] = (candidate.get("workshop", {}) as Dictionary).duplicate(true)
	candidate.workshop["migrated_from"] = {"map_id": source.get("map_id", ""), "sha256": CustomMapSchema.sha256(source), "tradegen": source.get("tradegen", "")}
	var gen := CustomMapValidator.generate(base, candidate, cat)
	if not gen.get("ok", false): return {"ok": false, "reason": str(gen.get("tech", "该地图暂时无法生成贸易卡"))}
	candidate.generated = gen.generated
	var validation := CustomMapValidator.validate(base, layout, candidate, cat)
	if not validation.ok: return {"ok": false, "reason": "候选副本未通过完整地图检查", "errors": validation.errors}
	var rows: Array = []
	var previous: Dictionary = {}
	for deck: Dictionary in source.get("generated", {}).get("decks", []):
		for card: Dictionary in deck.get("cards", []): previous[str(card.id)] = card
	for deck: Dictionary in candidate.generated.get("decks", []):
		for card: Dictionary in deck.cards:
			var old_card: Dictionary = previous.get(str(card.id), {})
			rows.append({"id": card.id, "before": old_card, "after": card.duplicate(true), "changed": old_card != card})
	return {"ok": true, "doc": candidate, "validation": validation, "source_sha": CustomMapSchema.sha256(source), "rows": rows}

func _ready() -> void:
	name = "RuleRecoveryPanel"
	position = Vector2(190, 140)
	custom_minimum_size = Vector2(1060, 810)
	add_theme_stylebox_override("panel", Kit.satchel_box(24, 4, 24))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	add_child(col)
	col.add_child(Kit.label("规则与卡片恢复 · 创建新副本", 28, Kit.INK))
	versions = OptionButton.new()
	versions.custom_minimum_size.y = 46
	Kit.style_button(versions, "cream", 46, 22)
	versions.get_popup().add_theme_color_override("font_color", Kit.INK)
	versions.get_popup().add_theme_stylebox_override("panel", Kit.satchel_box(12, 2, 12))
	for version: String in CustomMapTradegenRegistry.VERSIONS:
		versions.add_item(CustomMapTradegenRegistry.label(version))
		versions.set_item_metadata(versions.item_count - 1, version)
		if version == str(workshop.doc.doc.get("tradegen", "")): versions.select(versions.item_count - 1)
	col.add_child(versions)
	note = Kit.label("", 20, Kit.INK_SOFT)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 1000
	col.add_child(note)
	var inspect := Kit.button("预览候选副本及逐张差异", "cream", 48, 22)
	inspect.name = "RulePreviewButton"
	inspect.pressed.connect(build_preview)
	col.add_child(inspect)
	preview = RichTextLabel.new()
	preview.custom_minimum_size = Vector2(1000, 455)
	preview.add_theme_font_override("normal_font", Kit.font("body", 500))
	preview.add_theme_font_size_override("normal_font_size", 19)
	preview.add_theme_color_override("default_color", Kit.INK)
	col.add_child(preview)
	var actions := HBoxContainer.new()
	col.add_child(actions)
	confirm = Kit.button("确认创建副本（可撤销）", "primary", 54, 22)
	confirm.name = "RuleConfirmCopyButton"
	confirm.disabled = true
	confirm.pressed.connect(confirm_copy)
	actions.add_child(confirm)
	var cancel := Kit.button("取消", "cream", 54, 22)
	cancel.name = "RuleCancelButton"
	cancel.pressed.connect(queue_free)
	actions.add_child(cancel)
	versions.item_selected.connect(func(_index: int) -> void: prepared = {}; confirm.disabled = true; preview.text = ""; update_note())
	update_note()

func update_note() -> void:
	note.text = CustomMapTradegenRegistry.disclosure(str(versions.get_selected_metadata())) + "\n原图与旧卡片保留；确认只建立不同 map_id 的副本。之后可另行保存或导入。撤销会退回原图与旧 map_id；已保存的副本仍保留在地图库。"

func build_preview() -> void:
	prepared = prepare_copy(workshop.doc.doc, str(versions.get_selected_metadata()), workshop._base_content, workshop.board.base_layout, workshop.catalogue)
	confirm.disabled = not prepared.get("ok", false)
	if not prepared.get("ok", false):
		preview.text = str(prepared.get("reason", "无法生成候选副本")) + "\n" + str(prepared.get("errors", []))
		return
	var changed := 0
	var lines: PackedStringArray = []
	var ordinal := 0
	for row: Dictionary in prepared.rows:
		ordinal += 1
		changed += int(row.changed)
		lines.append("%s · %s\n原：%s\n新：%s\n" % ["新增贸易卡 %d" % ordinal, "已变化" if row.changed else "相同", describe(row.before), describe(row.after)])
	preview.text = "%s → %s\n共 %d 张新增卡，%d 张变化。原80张不变。\n候选地图：%s\n\n%s" % [CustomMapTradegenRegistry.label(str(workshop.doc.doc.get("tradegen", ""))), CustomMapTradegenRegistry.label(str(prepared.doc.tradegen)), prepared.rows.size(), changed, prepared.doc.name, "\n".join(lines)]

func describe(card: Dictionary) -> String:
	if card.is_empty(): return "无旧卡片"
	var parts: PackedStringArray = []
	for entry: Dictionary in card.get("entries", []):
		var id := str(entry.get("resource_id", ""))
		var title := "白银" if entry.get("resource_kind", "") == "SILVER" else ""
		if title == "" and workshop._base_content.get("goods", {}).has(id): title = GameData.get_good_name(workshop._base_content, id)
		if title == "":
			for city: Dictionary in prepared.get("doc", {}).get("new_cities", []):
				if id == CustomMapSchema.good_id(str(city.slot), str(city.specialty)):
					title = str(CustomMapCatalogue.specialty(workshop.catalogue, str(city.specialty)).get("display_name", city.specialty))
		if title == "": title = "未知资源[" + id + "]"
		parts.append("%d %s" % [int(entry.get("quantity", 0)), title])
	return " / ".join(parts)

func confirm_copy() -> bool:
	if not prepared.get("ok", false) or CustomMapSchema.sha256(workshop.doc.doc) != prepared.source_sha:
		confirm.disabled = true
		preview.text = "地图已改变，请重新预览。"
		return false
	var applied: bool = workshop._accept_mutation(prepared, "创建规则恢复副本")
	if applied:
		workshop.board.select("", "")
		workshop.say("已创建新副本。原图保留；点「保存」将副本存入地图库。")
		queue_free()
	return applied
