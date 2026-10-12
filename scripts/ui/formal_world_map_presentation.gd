extends RefCounted
class_name FormalWorldMapPresentation

## 将已封板的正式世界地图表现数据投影为 BoardView 使用的只读结构。
## 规则节点/边仍以 GameState.content 为唯一权威；这里绝不修改对局状态。

const PRESENTATION_PATH := "res://data/rulesets/lshu_configurable_v1/presentation/world_map_v1.json"

const TOPOLOGY_TO_RULESET_CITY := {
	"ancient_rome": "rome",
	"pantuo": "panti",
}


static func build(content: Dictionary) -> Dictionary:
	# The approved runtime loader is also the owner of the PXD-derived city
	# calibration.  Do not rebuild the formal presentation from the flattened map
	# JSON alone: its extraction rectangles include transparent canvas padding and
	# are not valid render/hit sizes.
	var bundle := WorldMapRuntimeLoader.load_bundle()
	if not bool(bundle.get("ok", false)):
		push_error(
			"FormalWorldMapPresentation: runtime bundle invalid: %s"
			% str(bundle.get("errors", []))
		)
		return {}
	var source: Dictionary = bundle.get("presentation", {})

	var logical_arr: Array = source.get("logic_size", [4096, 1363])
	var logical_size := Vector2(
		float(logical_arr[0]) if logical_arr.size() > 0 else 4096.0,
		float(logical_arr[1]) if logical_arr.size() > 1 else 1363.0
	)
	var projected := {
		"ruleset_id": "lshu_configurable_v1",
		"logical_size": [logical_size.x, logical_size.y],
		# PXD 的真实层级：纯地形 → 路线/节点 → 城市 → 名牌 → 棋子/UI。
		# world_map_v1.png 是设计审计用的拍平预览，严禁作为运行时 overlay。
		"world_bounds": [0.0, -184.0, 4096.0, 1755.0],
		"map_background": "res://assets/game/maps/world/world_map_v2_overscan.png",
		"map_background_origin": [0.0, -184.0],
		"map_background_world_size": [4096.0, 1755.0],
		"camera_profile": source.get("camera", {}).duplicate(true),
		"cities_visual": {},
		"routes": [],
		"node_styles": {},
	}

	var city_visuals: Dictionary = projected["cities_visual"]
	for city_value in bundle.get("cities", []):
		var city: Dictionary = city_value
		var topology_id := String(city.get("city_id", ""))
		var ruleset_id := String(TOPOLOGY_TO_RULESET_CITY.get(topology_id, topology_id))
		if ruleset_id.is_empty() or not content.get("cities", {}).has(ruleset_id):
			continue
		var visible_rect: Array = city.get("static_visible_rect_px", [])
		if visible_rect.size() != 4:
			push_error("FormalWorldMapPresentation: missing city calibration %s" % topology_id)
			continue
		var visible_size := [float(visible_rect[2]), float(visible_rect[3])]
		var bottom_center := [
			float(visible_rect[0]) + float(visible_rect[2]) * 0.5,
			float(visible_rect[1]) + float(visible_rect[3]),
		]
		city_visuals[ruleset_id] = {
			"city_id": ruleset_id,
			"topology_city_id": topology_id,
			"display_name": String(content["cities"][ruleset_id].get("display_name", ruleset_id)),
			"center": bottom_center,
			"size": visible_size,
			"static_visible_rect_px": visible_rect.duplicate(),
			"sprite": String(city.get("static_texture", "")),
			"static_texture": String(city.get("static_texture", "")),
			"animation_texture": String(city.get("animation_texture", "")),
			"frame_count": int(city.get("frame_count", 32)),
			"fps": float(city.get("fps", 8.0)),
			"allowed_routes": city.get("allowed_routes", []).duplicate(),
			"is_transport_interchange": bool(city.get("is_transport_interchange", false)),
			"building_position": city.get("building_position", []).duplicate(),
			"building_size": city.get("building_size", []).duplicate(),
			# Interaction uses the calibrated visible building, never the padded
			# extraction/hit rectangle from the flattened audit map.
			"building_hit_rect": {
				"x": float(visible_rect[0]),
				"y": float(visible_rect[1]),
				"w": float(visible_rect[2]),
				"h": float(visible_rect[3]),
			},
			"label_position": city.get("label_position", []).duplicate(),
			"label_size": city.get("label_size", []).duplicate(),
			"formal_embedded_label": false,
		}

	var routes: Array = projected["routes"]
	for edge_value in content.get("board_edges", []):
		var edge: Dictionary = edge_value
		var points: Array = edge.get("movement_polyline_px", edge.get("polyline_px", []))
		if points.size() < 2:
			continue
		routes.append({
			"edge_id": String(edge.get("id", "")),
			"route_type": String(edge.get("route_type", "LAND")),
			"points": points.duplicate(true),
		})

	var styles: Dictionary = projected["node_styles"]
	for node_id_value in content.get("board_nodes", {}).keys():
		var node_id := String(node_id_value)
		var node: Dictionary = content["board_nodes"][node_id]
		var allowed: Array = node.get("allowed_routes", [])
		styles[node_id] = "sea" if allowed.size() == 1 and String(allowed[0]) == "SEA" else "land"

	return projected


static func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}
