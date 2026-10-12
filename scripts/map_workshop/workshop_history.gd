extends RefCounted
## 快照式撤销栈（DESIGN 3.12.11）：每一步存整份覆盖层（≤ 20 KB），最多 100 步。
## 什么算一步由调用方决定（一次真正挪动了的拖动、输入框的一次提交、「放回原处」、重置……）；
## 这里只管一条规矩：内容没变的提交不进栈（按规范化文本比较，和「文档字节」同一个口径）。

const MAX_STEPS := 100

var _undo: Array[Dictionary] = []        # [{doc, label}]，最后一个是最近一步之前的文档
var _redo: Array[Dictionary] = []
var _canon: Callable                     # doc -> 规范化文本


func _init(canon: Callable) -> void:
	_canon = canon


## 记一步：before = 改之前的文档，after = 改之后的；两者内容相同就不记，返回 false
func record(before: Dictionary, after: Dictionary, label := "") -> bool:
	if String(_canon.call(before)) == String(_canon.call(after)):
		return false
	_undo.append({"doc": before.duplicate(true), "label": label})
	while _undo.size() > MAX_STEPS:
		_undo.pop_front()
	_redo.clear()
	return true


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


## 跨 map_id 的重置撤销/重做需要先保全离开的文档，查询目标不能先弹出历史栈。
func undo_map_id() -> String:
	return str(_undo.back().doc.get("map_id", "")) if can_undo() else ""


func redo_map_id() -> String:
	return str(_redo.back().doc.get("map_id", "")) if can_redo() else ""


## 撤一步：返回要换上的文档（空字典 = 没东西可撤）
func undo(current: Dictionary) -> Dictionary:
	if _undo.is_empty():
		return {}
	var step: Dictionary = _undo.pop_back()
	_redo.append({"doc": current.duplicate(true), "label": step.label})
	return (step.doc as Dictionary).duplicate(true)


func redo(current: Dictionary) -> Dictionary:
	if _redo.is_empty():
		return {}
	var step: Dictionary = _redo.pop_back()
	_undo.append({"doc": current.duplicate(true), "label": step.label})
	return (step.doc as Dictionary).duplicate(true)


func undo_size() -> int:
	return _undo.size()


func redo_size() -> int:
	return _redo.size()


func last_label() -> String:
	return String(_undo.back().label) if not _undo.is_empty() else ""


func clear() -> void:
	_undo.clear()
	_redo.clear()
