extends RefCounted
## Explicit asset factory. It does not change rules, saves, default pieces, or editor catalogue.
const MANIFEST_PATH := "res://extensions/silkroad_asset_pack_v1/manifest.json"

static func manifest() -> Dictionary:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	return data if data is Dictionary else {}

static func create_model(category: String, id: String) -> Node3D:
	var entry: Dictionary = manifest().get(category, {}).get(id, {})
	var path := str(entry.get("model", ""))
	if path.is_empty(): return null
	# Load original GLB directly: art source directories intentionally contain .gdignore.
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(path, state) != OK: return null
	return document.generate_scene(state) as Node3D

static func good_icon(id: String) -> ImageTexture:
	var entry: Dictionary = manifest().get("goods", {}).get(id, {})
	var path := str(entry.get("icon", ""))
	if path.is_empty(): return null
	var image := Image.new()
	if image.load(path) != OK: return null
	return ImageTexture.create_from_image(image)
