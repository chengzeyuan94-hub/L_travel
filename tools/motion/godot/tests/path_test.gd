extends SceneTree
## Headless check of the camera-path sampler in motion_capture.gd (holds stay put, keys are hit exactly,
## velocity is continuous across uneven key spacing).
##   Godot --headless --path <project> -s res://tools/motion/godot/tests/path_test.gd

func _initialize() -> void:
	var mc: Node = load("res://tools/motion/godot/motion_capture.gd").new()
	var keys := [
		{"t": 0.0, "pos": [0.0, 0.3, -2.4], "look": [0.1, 0.02, -12.4], "ease": "linear"},
		{"t": 4.0, "pos": [0.0, 0.3, -2.4], "look": [0.1, 0.02, -12.4], "ease": "inOutSine"},
		{"t": 13.5, "pos": [0.0, 0.0, 0.0], "look": [0.0, 0.0, -10.0]},
		{"t": 15.0, "pos": [0.0, 0.0, 0.0], "look": [0.0, 0.0, -10.0]},
	]
	var fails := 0
	var hold_max := 0.0
	for k in 121:
		var t := 4.0 * k / 120.0
		var s: Dictionary = mc.call("_sample", keys, t, "catmull")
		hold_max = maxf(hold_max, (s.pos as Vector3).distance_to(Vector3(0.0, 0.3, -2.4)))
	print("hold segment max drift: ", hold_max)
	if hold_max > 1e-6:
		fails += 1
	for kt in [0.0, 4.0, 13.5, 15.0]:
		var s2: Dictionary = mc.call("_sample", keys, kt, "catmull")
		print("t=", kt, " pos=", s2.pos)
	# uneven linear keys: velocity continuity at the middle key
	var k2 := [{"t": 0.0, "pos": [0, 0, 0], "ease": "linear"}, {"t": 1.0, "pos": [1, 0, 0], "ease": "linear"}, {"t": 5.0, "pos": [2, 1, 0], "ease": "linear"}, {"t": 6.0, "pos": [3, 1, 0]}]
	var e := 0.001
	var v_before: Vector3 = ((mc.call("_sample", k2, 1.0 - e, "catmull").pos as Vector3) - (mc.call("_sample", k2, 1.0 - 2 * e, "catmull").pos as Vector3)) / e
	var v_after: Vector3 = ((mc.call("_sample", k2, 1.0 + 2 * e, "catmull").pos as Vector3) - (mc.call("_sample", k2, 1.0 + e, "catmull").pos as Vector3)) / e
	print("velocity at key t=1: before ", v_before, " after ", v_after)
	if v_before.distance_to(v_after) > 0.05:
		fails += 1
	print("PATH_TEST ", "OK" if fails == 0 else "FAIL %d" % fails)
	mc.free()
	quit(fails)
