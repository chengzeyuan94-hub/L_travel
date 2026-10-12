extends SceneTree
## Run with Godot --headless --path . --script res://scripts/editor/create_formal_starter.gd
const Store := preload("res://scripts/editor/map_layout_store.gd")
func _initialize() -> void:
	var data := Store.seed_from_formal()
	var draft := Store.save_layout("res://assets/map_editor/formal_starter.json", data)
	var exported := Store.export_for_game(data, "res://assets/map_editor/formal_starter.game.json")
	print("FORMAL_STARTER ", JSON.stringify({"draft_ok":draft.ok,"export_ok":exported.ok,"errors":exported.errors,"counts":Store.validate(data).counts}))
	quit(0 if draft.ok and exported.ok else 1)
