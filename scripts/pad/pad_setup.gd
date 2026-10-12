extends "res://scripts/pad/pad_page.gd"
## 设置页的手柄（scripts/lshu_ui/lshu_setup_screen.gd 的子节点）。
## 十字键在座位行的按钮（真人 / 电脑、颜色、起始城市、难度、请下车）、「和电脑玩 / 和朋友玩」、「再加一位旅伴」、
## 趣味事件、对局时长滑条（框着时左右调）、「出发！」「返回」之间挪框；进来时框在「出发！」上。
## 名字框不进手柄的框（要打字；安卓上会弹出键盘）。
## 调色盘 / 趣味事件小面板开着时只在面板里挪；B 先收面板，再按 B = 「返回」回开场（改的座位设置都记着）。


func _init() -> void:
	name = "PadSetup"


func _items() -> Array:
	var stage := page.get("_stage") as Control
	if stage == null:
		return []
	var palette := page.get("_palette") as Control
	var fun_panel := page.get("_fun_panel") as Control
	if palette != null and palette.visible:
		return collect(palette, [])
	if fun_panel != null and fun_panel.visible:
		return collect(fun_panel, [])
	var skip: Array = [palette, fun_panel, page.get("_palette_catcher"), page.get("_fun_catcher")]
	var out: Array = []
	for c in collect(stage, skip):
		if c is LineEdit:
			continue
		out.append(c)
	return out


func _first(items: Array) -> Control:
	var start := page.get_node_or_null("%StartButton") as Control
	if start != null and items.has(start):
		return start
	for c: Control in items:
		if String(c.name) == "FunEventsOk":
			return c
	return items[0] as Control if not items.is_empty() else null


func _on_back() -> bool:
	var palette := page.get("_palette") as Control
	if palette != null and palette.visible:
		page.call("_close_palette")
		return true
	var fun_panel := page.get("_fun_panel") as Control
	if fun_panel != null and fun_panel.visible:
		page.call("_close_fun_panel")
		return true
	var back := page.get_node_or_null("%BackButton") as BaseButton
	if back != null:
		reset_focus()
		return Pad.press(back)
	return false
