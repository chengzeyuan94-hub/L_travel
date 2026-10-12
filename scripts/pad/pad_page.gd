extends Node
## 页面菜单的手柄上下文（开场、设置页继承它；scripts/pad/pad_input.gd 的一个上下文）。挂在那一页下面，
## 那一页看得见时它在前面。十字键 / 左摇杆按屏幕位置挪焦点框，LB / RB 按清单顺序挪，A 按框着的按钮，
## B 交给 _on_back()（关浮层 / 返回，从不做不可逆的事）。进页面时框在最常用的那个（_first）上。
## 焦点框只在手柄模式里画；从鼠标 / 触屏换到手柄的第一下只把框亮出来，不按。
## 滑条（设置页「对局时长」）：框着时先按 A「拿起来」，这时左右 = 调一格（一下一格，按住不连调）；再按 A / B 或上下挪走就放下。
## 没拿起来时左右照常挪框——以前从「出发！」往右 / 往上就落在滑条上，按住右键 1.3 秒就调成「不限时」并记下来（PAD-MAR-8）。
## 子类实现：_items() -> Array（可以框的控件，按清单顺序）、_first(items) -> Control、_on_back() -> bool，
## 可选 _page_active() -> bool、_on_other(action) -> bool。

const Pad := preload("res://scripts/pad/pad_input.gd")

var page: Control
var priority := 10
var _cur: Control
var _cur_path := ""
## 拿起来的滑条（左右调它）；null = 没拿
var _grabbed: Range


func _ready() -> void:
	page = get_parent() as Control
	var hub := get_node_or_null("/root/PadInput")
	if hub != null:
		hub.register(self, priority)


func pad_active() -> bool:
	return page != null and page.is_visible_in_tree() and _page_active()


## 从鼠标 / 触屏换到手柄的第一下只亮出焦点框（孩子先看见框在哪儿）
func pad_wake() -> bool:
	return true


func _page_active() -> bool:
	return true


func _items() -> Array:
	return []


func _first(items: Array) -> Control:
	return items[0] as Control if not items.is_empty() else null


func _on_back() -> bool:
	return false


func _on_other(_a: String) -> bool:
	return false


## 可以框的控件：root 下面看得见、能按的按钮（和滑条），跳过 skip 里的子树
static func collect(root: Node, skip: Array = []) -> Array:
	var out: Array = []
	_collect(root, skip, out)
	return out


static func _collect(n: Node, skip: Array, out: Array) -> void:
	if n in skip:
		return
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is BaseButton and not (n as BaseButton).disabled:
		out.append(n)
	elif n is HSlider and (n as Range).editable:
		out.append(n)
	for c in n.get_children():
		_collect(c, skip, out)


func _current(items: Array) -> Control:
	if _cur != null and is_instance_valid(_cur) and items.has(_cur):
		return _cur
	if _cur_path != "":
		var n := page.get_node_or_null(_cur_path) as Control
		if n != null and items.has(n):
			_cur = n
			return n
	var f := _first(items)
	if f != null:
		_set_cur(f)
	return f


func _set_cur(c: Control) -> void:
	_cur = c
	_cur_path = String(page.get_path_to(c)) if c != null and page.is_ancestor_of(c) else ""


## 换页 / 关浮层时忘掉焦点（下次回到默认那个）
func reset_focus() -> void:
	_cur = null
	_cur_path = ""
	_grabbed = null


## 这一下是不是方向键按住的自动连发（PadInput 连发时置位）
func _is_repeat() -> bool:
	var hub := get_node_or_null("/root/PadInput")
	return hub != null and bool(hub.get("repeating"))


func pad_action(a: String) -> bool:
	var items := _items()
	var cur := _current(items)
	if _grabbed != null and (not is_instance_valid(_grabbed) or _grabbed != cur):
		_grabbed = null
	match a:
		"accept":
			if cur is BaseButton:
				Pad.press(cur as BaseButton)
				return true
			if cur is Range:
				_grabbed = null if _grabbed == cur else cur as Range      # 拿起 / 放下滑条
				return true
			return cur != null
		"back":
			if _grabbed != null:
				_grabbed = null
				return true
			return _on_back()
		"up", "down", "left", "right":
			if cur is Range and a in ["left", "right"] and _grabbed == cur:
				if _is_repeat():
					return true       # 按住不连调：一下一格
				var r := cur as Range
				r.value += (r.step if r.step > 0.0 else 1.0) * (-1.0 if a == "left" else 1.0)
				return true
			_grabbed = null
			if items.is_empty():
				return true
			var d: Vector2 = {"up": Vector2.UP, "down": Vector2.DOWN, "left": Vector2.LEFT, "right": Vector2.RIGHT}[a]
			var i := Pad.nav_controls(items, items.find(cur), d, maxi(0, items.find(_first(items))))
			if i >= 0:
				_set_cur(items[i] as Control)
			return true
		"lb", "rb":
			_grabbed = null
			if items.is_empty():
				return true
			var j := items.find(cur)
			j = clampi(j + (1 if a == "rb" else -1), 0, items.size() - 1) if j >= 0 else 0
			_set_cur(items[j] as Control)
			return true
	return _on_other(a)


func pad_focus() -> Variant:
	return _current(_items())


## 框着滑条、还没拿起来：左上角贴个 A（按 A 才能调）
func pad_glyphs() -> Array:
	var cur := _current(_items())
	if cur is Range and _grabbed != cur:
		return [[cur, "A"]]
	return []
