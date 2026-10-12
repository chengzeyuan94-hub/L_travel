extends RefCounted
## Example extra_scripts module: demonstrates the hook contract (see README_PROBE.md).
## It sets one uniform on chosen role materials per light preset, and counts ticks.
## A real look line copies this shape: build(host, cfg) -> Dictionary (recorded in the capture JSON).
var host: Node3D
var cfg: Dictionary = {}
var ticks: int = 0

func build(h: Node3D, c: Dictionary) -> Dictionary:
	host = h
	cfg = c
	host.call("register_light_callback", _on_light)
	host.call("register_tick", _on_tick)
	_on_light(str(host.get("light_name")))
	var tile: Dictionary = host.get("tile")
	host.call("add_report", "example_rim_hook", {"roles": cfg.get("roles", []), "tile_theme": tile.get("place", {}).get("theme", "")})
	return {"ok": true, "roles": cfg.get("roles", []), "light": host.get("light_name")}

func _on_light(light: String) -> void:
	var per_light: Dictionary = cfg.get("rim_strength", {})
	var value: float = float(per_light.get(light, per_light.get("default", 0.0)))
	for role: Variant in cfg.get("roles", []):
		host.call("set_role_uniform", str(role), "rim_strength", value)
		host.call("set_role_uniform", str(role), "rim_color", cfg.get("rim_color", "#ffffff"))

func _on_tick(_t: float, _delta: float) -> void:
	ticks += 1
