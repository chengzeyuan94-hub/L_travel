@tool
extends EditorPlugin
## 导出门禁（安卓压力测试 PAD-MAR-1）：见 export_gate.gd。编辑器和命令行导出（--export-release / --export-debug / --export-pack）都走这里。

var _gate: EditorExportPlugin


func _enter_tree() -> void:
	_gate = preload("res://addons/lshu_export_gate/export_gate.gd").new()
	add_export_plugin(_gate)


func _exit_tree() -> void:
	if _gate != null:
		remove_export_plugin(_gate)
		_gate = null
