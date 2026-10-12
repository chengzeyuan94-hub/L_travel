extends SceneTree
## 第四幕「L叔在哪儿」· QA: continuous light, property level (the live scene, same 1920x1080 MSAA 4x SubViewport as
## lshu_qa_capture.gd, motion frozen). Everything the light touches is snapshotted: sun, fill, Environment,
## CameraAttributes, sky / floor materials, every role material's uniforms, the tile's fire / lamp lights, the
## life materials (halo, smoke), the character rim material and fill, the night lamp lights.
##   exact     for every preset P: set_light(P) on a fresh apply, then a walk through blends of every pair, then
##             set_light_blend(X, P, 1) and set_light_blend(P, Y, 0): both snapshots must equal the fresh one exactly
##   jump      for every neighbouring pair: the change from t = 0 to t = 1e-3 and from t = 1 - 1e-3 to t = 1 of every
##             numeric value, relative to its whole change over the blend (a step shows as a ratio near 1); on / off
##             switches are listed apart with the value that gates them (shadow_opacity / light_energy ~ 0 = no step)
## Writes --out=<json>; prints LSHU_BLEND_CHECK {exact_mismatches, max_jump_ratio, ...}.
##   Godot --path . --script res://tools/traveler/lshu/qa/lshu_light_blend_check.gd -- --tile=<id> --light=night
##         --motion-freeze --park=22 --out=/abs/blend_check.json

const SCENE: String = "res://scenes/traveler/lshu_main.tscn"
const LIGHTS: Array[String] = ["morning", "day", "sunset", "night"]
const PAIRS: Array = [["morning", "day"], ["day", "sunset"], ["sunset", "night"], ["night", "morning"]]
const EPS: float = 0.001

var scene: Node3D
var viewport: SubViewport

func _initialize() -> void:
	call_deferred("_run")

func _arg(key: String, fallback: String) -> String:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--" + key + "="):
			return a.trim_prefix("--" + key + "=")
	return fallback

func _run() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	viewport = SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(viewport)
	var preview: TextureRect = TextureRect.new()
	preview.texture = viewport.get_texture()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	root.add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scene = (load(SCENE) as PackedScene).instantiate() as Node3D
	viewport.add_child(scene)
	await scene.tile_ready
	await scene.prewarm_done
	var report: Dictionary = {"tile": scene.get("tile_id"), "exact": [], "jumps": [], "switched": {}, "held": {}}
	var mismatches: int = 0
	# exact: fresh preset vs the same preset reached at the end of blends
	for p: String in LIGHTS:
		scene.call("set_light", p)
		await _frames(2)
		var fresh: Dictionary = _snapshot()
		for pair: Array in PAIRS:
			for t: float in [0.3, 0.7]:
				scene.call("set_light_blend", pair[0], pair[1], t)
				var br: Dictionary = (scene.get("look") as RefCounted).get("blend_report")
				report.switched["%s>%s" % pair] = br.get("switched", [])
				report.held["%s>%s" % pair] = br.get("held", [])
		var other: String = LIGHTS[(LIGHTS.find(p) + 1) % LIGHTS.size()]
		scene.call("set_light_blend", other, p, 1.0)
		await _frames(2)
		var d1: Array = _diff(fresh, _snapshot())
		scene.call("set_light_blend", "day" if p == "night" else "night", other, 0.5)
		scene.call("set_light_blend", p, other, 0.0)
		await _frames(2)
		var d2: Array = _diff(fresh, _snapshot())
		mismatches += d1.size() + d2.size()
		report.exact.append({"preset": p, "values": fresh.size(), "after_blend_t1_mismatches": d1.slice(0, 20), "t0_mismatches": d2.slice(0, 20)})
	# jump: the first / last 1e-3 of every blend against the whole blend
	var max_ratio: float = 0.0
	for pair: Array in PAIRS:
		var snaps: Array = []
		for t: float in [0.0, EPS, 1.0 - EPS, 1.0]:
			scene.call("set_light_blend", pair[0], pair[1], t)
			snaps.append(_snapshot())
		var worst: Array = []
		var switches: Array = []
		for key: String in snaps[0].keys():
			var total: float = _dist(snaps[0][key], snaps[3].get(key))
			if total <= 1e-6:
				continue
			for seg: Array in [[0, 1], [2, 3]]:
				var step: float = _dist(snaps[seg[0]][key], snaps[seg[1]].get(key))
				if typeof(snaps[0][key]) == TYPE_BOOL:
					# an on / off switch: reported with the continuous value that gates it on the switched side
					if step > 0.0:
						var gate: String = key.substr(0, key.rfind("."))
						var inner: Dictionary = snaps[seg[1]] if seg[0] == 0 else snaps[seg[0]]
						switches.append({"key": key, "segment": "t0" if seg[0] == 0 else "t1", "shadow_opacity": inner.get(gate + ".shadow_opacity"),
							"light_energy": inner.get(gate + ".light_energy")})
					continue
				var ratio: float = step / total
				max_ratio = maxf(max_ratio, ratio)
				if ratio > 0.01:
					worst.append({"key": key, "segment": "t0" if seg[0] == 0 else "t1", "ratio": ratio, "step": step, "total": total})
		report.jumps.append({"pair": "%s>%s" % pair, "values_changing": snaps[0].keys().filter(func(k: String) -> bool: return _dist(snaps[0][k], snaps[3].get(k)) > 1e-6).size(), "over_1pct": worst, "switches": switches})
	report["exact_mismatches"] = mismatches
	report["max_jump_ratio"] = max_ratio
	var f: FileAccess = FileAccess.open(_arg("out", "user://blend_check.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, " "))
	f.close()
	var over: int = 0
	for j: Dictionary in report.jumps:
		over += (j.over_1pct as Array).size()
	var sw: int = 0
	for j2: Dictionary in report.jumps:
		sw += (j2.switches as Array).size()
	print("LSHU_BLEND_CHECK ", JSON.stringify({"tile": report.tile, "exact_mismatches": mismatches, "max_jump_ratio": max_ratio, "jumps_over_1pct": over, "switches": sw,
		"values": (report.exact[0] as Dictionary).values}))
	quit(0)

func _frames(n: int) -> void:
	for _i: int in n:
		await RenderingServer.frame_post_draw

# ------------------------------------------------------------------ snapshot
func _snapshot() -> Dictionary:
	var out: Dictionary = {}
	_props(out, "sun", scene.get("sun"))
	_props(out, "fill", scene.get("fill"))
	_props(out, "env", scene.get("environment"))
	_props(out, "cam_attr", scene.get("camera_attributes"))
	_params(out, "sky", scene.get("sky_material"))
	_params(out, "floor", scene.get("floor_material"))
	var look: RefCounted = scene.get("look")
	var mats: Dictionary = look.get("materials")
	for role: String in mats.keys():
		_params(out, "role." + role, mats[role])
	var tile: Node3D = scene.get("tile")
	var i: int = 0
	for l: OmniLight3D in tile.get("fire_lights"):
		_props(out, "fire%d" % i, l)
		i += 1
	i = 0
	for l2: OmniLight3D in tile.get("lamp_lights"):
		_props(out, "lamp%d" % i, l2)
		i += 1
	var life: Node3D = tile.get("life")
	if life != null:
		_params(out, "halo", life.get("halo_material"))
		_params(out, "smoke", life.get("smoke_material_all"))
	var character: Node3D = scene.get("character")
	var rig: Node3D = character.get("active")
	if rig != null:
		_params(out, "rim", rig.get("rim_material"))
		_props(out, "char_fill", rig.get("fill"))
	var lamp: Node3D = scene.get("night_lamp")
	if lamp != null:
		_props(out, "night_lamp.light", lamp.get("light"))
		_props(out, "night_lamp.key", lamp.get("key"))
		_params(out, "night_lamp.halo", lamp.get("halo_material"))
	return out

func _props(out: Dictionary, prefix: String, obj: Object) -> void:
	if obj == null:
		return
	for p: Dictionary in obj.get_property_list():
		if not (int(p.usage) & PROPERTY_USAGE_STORAGE):
			continue
		var t: int = int(p.type)
		if t in [TYPE_FLOAT, TYPE_INT, TYPE_BOOL, TYPE_COLOR, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_TRANSFORM3D]:
			out[prefix + "." + str(p.name)] = obj.get(p.name)

func _params(out: Dictionary, prefix: String, mat: Variant) -> void:
	var m: ShaderMaterial = mat as ShaderMaterial
	if m == null or m.shader == null:
		return
	for u: Dictionary in m.shader.get_shader_uniform_list():
		var v: Variant = m.get_shader_parameter(str(u.name))
		if v is Object:
			continue
		out[prefix + "." + str(u.name)] = v

func _diff(a: Dictionary, b: Dictionary) -> Array:
	var out: Array = []
	for k: String in a.keys():
		if not b.has(k) or typeof(a[k]) != typeof(b[k]) or a[k] != b[k]:
			out.append({"key": k, "fresh": var_to_str(a[k]), "now": var_to_str(b.get(k))})
	for k2: String in b.keys():
		if not a.has(k2):
			out.append({"key": k2, "fresh": "<absent>", "now": var_to_str(b[k2])})
	return out

static func _dist(a: Variant, b: Variant) -> float:
	if typeof(a) != typeof(b):
		return 0.0 if (a == null and b == null) else 1.0
	match typeof(a):
		TYPE_FLOAT, TYPE_INT:
			return absf(float(a) - float(b))
		TYPE_BOOL:
			return 0.0 if a == b else 1.0
		TYPE_COLOR:
			var ca: Color = a
			var cb: Color = b
			return Vector4(ca.r - cb.r, ca.g - cb.g, ca.b - cb.b, ca.a - cb.a).length()
		TYPE_VECTOR2, TYPE_VECTOR3:
			return (a - b).length()
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			var fa: Array = Array(a)
			var fb: Array = Array(b)
			if fa.size() != fb.size():
				return 1.0
			var sf: float = 0.0
			for i: int in fa.size():
				sf += absf(float(fa[i]) - float(fb[i]))
			return sf
		TYPE_PACKED_VECTOR3_ARRAY:
			var va: PackedVector3Array = a
			var vb: PackedVector3Array = b
			if va.size() != vb.size():
				return 1.0
			var sv: float = 0.0
			for i: int in va.size():
				sv += (va[i] - vb[i]).length()
			return sv
		TYPE_PACKED_COLOR_ARRAY:
			var pa: PackedColorArray = a
			var pb: PackedColorArray = b
			if pa.size() != pb.size():
				return 1.0
			var sc: float = 0.0
			for i: int in pa.size():
				sc += Vector4(pa[i].r - pb[i].r, pa[i].g - pb[i].g, pa[i].b - pb[i].b, pa[i].a - pb[i].a).length()
			return sc
		TYPE_TRANSFORM3D:
			var ta: Transform3D = a
			var tb: Transform3D = b
			return (ta.basis.x - tb.basis.x).length() + (ta.basis.y - tb.basis.y).length() + (ta.basis.z - tb.basis.z).length() + (ta.origin - tb.origin).length()
	return 0.0 if a == b else 1.0
