extends SceneTree
## Save the editor's small example through the real JSON serializer.
func _initialize()->void:call_deferred("_run")
func _run()->void:
	var editor=load("res://scenes/editor/map_editor.tscn").instantiate()
	root.add_child(editor)
	for i in range(3):await process_frame
	var result:Dictionary=editor.save_document("res://assets/map_editor/sample_layout.json")
	print("SAMPLE_LAYOUT_SAVE ",JSON.stringify({"ok":result.ok,"path":result.path,"errors":result.errors}))
	editor.free()
	quit(0 if result.ok else 1)
