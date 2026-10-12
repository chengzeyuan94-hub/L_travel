extends "res://scripts/pad/pad_page.gd"
## 开场的手柄（scripts/lshu_ui/lshu_title_screen.gd 的子节点）。
##   开场：商旅模式 / 加载存档 / 旅人模式 / 声音 / 设置 / 换开场画面之间挪框（有存档时框先在「加载存档」上）；
##         A 按；B 在开场上什么也不做（不退出）
##   选幕页：框默认在第一张解锁的幕卡「进入」上；A 进入 / 设为开场；B 回开场
##   设置小面板：只有「全屏显示」（桌面）；B 收起。「退出游戏」不进手柄的框（孩子乱按不会一下关掉游戏）
## 一幕开着时（同一个窗口，traveler_host.gd）开场整个藏起来，这里不在前面，手柄交给那一幕。

const Launch := preload("res://scripts/traveler/traveler_launch.gd")


func _init() -> void:
	name = "PadTitle"


func _ready() -> void:
	super()
	if page != null:
		page.visibility_changed.connect(_on_page_visibility_changed)


## 从对局回到开场（齿轮、结算页「回到开场」）：框回到默认那个——刚离开的那局有存档，框就在「加载存档」上，
## 孩子接着狂按 A 是回到那一局，不是「商旅模式 → 出发！」开新局把它盖掉。从一幕回到选幕页时框留在刚才那张卡上
func _on_page_visibility_changed() -> void:
	var picker := page.get("picker") as Control
	if page.is_visible_in_tree() and (picker == null or not picker.visible):
		reset_focus()


func _page_active() -> bool:
	return not Launch.hosting()


func _items() -> Array:
	var t := page
	var picker := t.get("picker") as Control
	if picker != null and picker.visible:
		var out: Array = []
		var back := picker.get_node_or_null("BackButton") as Control
		if back != null:
			out.append(back)
		for c in collect(picker.get_node("Cards"), []):
			out.append(c)
		return out
	var settings := t.get("settings") as Control
	if settings != null and settings.visible:
		if OS.has_feature("android"):
			return []
		var full := settings.find_child("FullscreenButton", true, false) as BaseButton
		return [full] if full != null and full.is_visible_in_tree() and not full.disabled else []
	var design := t.get("design") as Control
	if design == null:
		return []
	var out2: Array = []
	for n: String in ["NewGameButton", "LoadButton", "TravelerButton", "SceneChipButton", "SoundButton", "SettingsButton"]:
		if n == "SettingsButton" and OS.has_feature("android"):
			continue      # 安卓上设置里只有「退出游戏」：手柄不去那儿
		var b := design.find_child(n, true, false) as BaseButton
		if b != null and b.is_visible_in_tree() and not b.disabled:
			out2.append(b)
	return out2


## 进页面时框在哪儿：开场有存档（「加载存档」可按）时框在它上面——孩子狂按 A 是接着上一局玩，
## 不会「商旅模式 → 出发！」开一局新的、把存档盖掉；没存档时框在「商旅模式」
func _first(items: Array) -> Control:
	for c: Control in items:
		if String(c.name) == "LoadButton":
			return c
	for c: Control in items:
		if String(c.name).begins_with("Enter_") or String(c.name) == "NewGameButton" or String(c.name) == "FullscreenButton":
			return c
	return items[0] as Control if not items.is_empty() else null


func _on_back() -> bool:
	var picker := page.get("picker") as Control
	if picker != null and picker.visible:
		page.call("_close_picker")
		reset_focus()
		return true
	var settings := page.get("settings") as Control
	if settings != null and settings.visible:
		page.call("_show_settings", false)
		reset_focus()
		return true
	return false
