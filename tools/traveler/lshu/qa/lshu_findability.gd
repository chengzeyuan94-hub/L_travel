extends Node
## 第四幕「L叔在哪儿」· QA only: how findable L叔 is (moved out of the scene's warm-up, card §2).
## Character mask = |frame without his shadows - frame without him|; colour statistics on the normal frame:
## CIELAB ΔE between him and a ring around him, ring lightness spread, silhouette edge contrast, salience.
## Attached by tools/traveler/lshu/qa/lshu_qa_capture.gd once the tile is ready; it runs during the capture
## warm-up (frames 24-30 of 120) and writes the result with scene.add_report("findability", ...).

const CAMERA: GDScript = preload("res://scripts/traveler/lshu/lshu_camera.gd")

var scene: Node3D
var result: Dictionary = {}

func start(scene_node: Node3D) -> void:
	scene = scene_node
	_measure()

func _measure() -> void:
	var vp: Viewport = scene.get_viewport()
	var character: Node3D = scene.get("character")
	var rig: Node3D = character.get("active")
	for _i: int in 24:
		await RenderingServer.frame_post_draw
	var img_a: Image = vp.get_texture().get_image()
	var shadow_meshes: Array[MeshInstance3D] = rig.get("shadow_meshes")
	var saved: Array[int] = []
	for mi: MeshInstance3D in shadow_meshes:
		saved.append(mi.cast_shadow)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var decal: Decal = rig.get("contact_decal")
	if decal != null:
		decal.visible = false
	for _i: int in 3:
		await RenderingServer.frame_post_draw
	var img_b: Image = vp.get_texture().get_image()
	var hide: Array[Node3D] = [rig.get("character") as Node3D]
	for key: String in ["carrying_pose", "cup", "flowers"]:
		var n: Node3D = rig.get(key) as Node3D
		if n != null:
			hide.append(n)
	for n2: Node3D in hide:
		n2.visible = false
	for _i: int in 3:
		await RenderingServer.frame_post_draw
	var img_c: Image = vp.get_texture().get_image()
	for n3: Node3D in hide:
		n3.visible = true
	for k: int in shadow_meshes.size():
		shadow_meshes[k].set("cast_shadow", saved[k])
	if decal != null:
		decal.visible = true
	var body: MeshInstance3D = rig.get("character_body")
	var posed: Mesh = character.call("posed_geometry")
	var pb: Dictionary = CAMERA.projected_bounds(scene.get("camera") as Camera3D, body, posed)
	result = _stats(img_a, img_b, img_c, pb)
	scene.call("add_report", "findability", result)

static func _lin(c: float) -> float:
	return c / 12.92 if c <= 0.04045 else pow((c + 0.055) / 1.055, 2.4)

static func _f(t: float) -> float:
	return pow(t, 1.0 / 3.0) if t > 0.008856 else 7.787 * t + 16.0 / 116.0

static func _lab(c: Color) -> Vector3:
	var r: float = _lin(c.r)
	var g: float = _lin(c.g)
	var b: float = _lin(c.b)
	var x: float = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
	var y: float = 0.2126 * r + 0.7152 * g + 0.0722 * b
	var z: float = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
	var fx: float = _f(x)
	var fy: float = _f(y)
	var fz: float = _f(z)
	return Vector3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))

func _stats(a: Image, b: Image, c: Image, pb: Dictionary) -> Dictionary:
	var bpx: Array = pb.bounds_px
	var h: float = maxf(float(pb.height_px), 20.0)
	var x0: int = clampi(int(float(bpx[0]) - h * 0.9), 0, a.get_width() - 1)
	var x1: int = clampi(int(float(bpx[2]) + h * 0.9), 0, a.get_width() - 1)
	var y0: int = clampi(int(float(bpx[1]) - h * 0.6), 0, a.get_height() - 1)
	var y1: int = clampi(int(float(bpx[3]) + h * 0.6), 0, a.get_height() - 1)
	var w: int = x1 - x0 + 1
	var hh: int = y1 - y0 + 1
	var mask: PackedByteArray = PackedByteArray()
	mask.resize(w * hh)
	var lstar: PackedFloat32Array = PackedFloat32Array()
	lstar.resize(w * hh)
	var mx0: int = w
	var mx1: int = -1
	var my0: int = hh
	var my1: int = -1
	var area: int = 0
	var char_lab: Vector3 = Vector3.ZERO
	for y: int in hh:
		for x: int in w:
			var pa: Color = a.get_pixel(x0 + x, y0 + y)
			var p1: Color = b.get_pixel(x0 + x, y0 + y)
			var p2: Color = c.get_pixel(x0 + x, y0 + y)
			var d: float = maxf(absf(p1.r - p2.r), maxf(absf(p1.g - p2.g), absf(p1.b - p2.b)))
			# keep only differences inside the projected body box (+15% of its height)
			var gx: float = float(x0 + x)
			var gy: float = float(y0 + y)
			if gx < float(bpx[0]) - h * 0.15 or gx > float(bpx[2]) + h * 0.15 or gy < float(bpx[1]) - h * 0.15 or gy > float(bpx[3]) + h * 0.15:
				d = 0.0
			var idx: int = y * w + x
			var lab: Vector3 = _lab(pa)
			lstar[idx] = lab.x
			if d > 0.04:
				mask[idx] = 1
				area += 1
				char_lab += lab
				mx0 = mini(mx0, x)
				mx1 = maxi(mx1, x)
				my0 = mini(my0, y)
				my1 = maxi(my1, y)
	if area == 0:
		return {"error": "empty mask"}
	char_lab /= float(area)
	var rad: int = maxi(4, int(h * 0.12))
	var horiz: PackedByteArray = PackedByteArray()
	horiz.resize(w * hh)
	for y2: int in hh:
		var run: int = 0
		for x2: int in range(-rad, w + rad):
			var add_x: int = x2 + rad
			if add_x >= 0 and add_x < w:
				run += mask[y2 * w + add_x]
			var sub_x: int = x2 - rad - 1
			if sub_x >= 0 and sub_x < w:
				run -= mask[y2 * w + sub_x]
			if x2 >= 0 and x2 < w:
				horiz[y2 * w + x2] = 1 if run > 0 else 0
	var ring_lab: Vector3 = Vector3.ZERO
	var ring_n: int = 0
	var ring_l: PackedFloat32Array = PackedFloat32Array()
	for x3: int in w:
		var run2: int = 0
		for y3: int in range(-rad, hh + rad):
			var add_y: int = y3 + rad
			if add_y >= 0 and add_y < hh:
				run2 += horiz[add_y * w + x3]
			var sub_y: int = y3 - rad - 1
			if sub_y >= 0 and sub_y < hh:
				run2 -= horiz[sub_y * w + x3]
			if y3 >= 0 and y3 < hh and run2 > 0 and mask[y3 * w + x3] == 0:
				var lab2: Vector3 = _lab(a.get_pixel(x0 + x3, y0 + y3))
				ring_lab += lab2
				ring_l.append(lab2.x)
				ring_n += 1
	ring_lab /= maxf(float(ring_n), 1.0)
	var ring_std: float = 0.0
	for v: float in ring_l:
		ring_std += (v - ring_lab.x) * (v - ring_lab.x)
	ring_std = sqrt(ring_std / maxf(float(ring_l.size()), 1.0))
	var edge_sum: float = 0.0
	var edge_n: int = 0
	var edge_strong: int = 0
	var offsets: Array[int] = [1, -1, w, -w]
	for y4: int in range(1, hh - 1):
		for x4: int in range(1, w - 1):
			var i4: int = y4 * w + x4
			if mask[i4] == 0:
				continue
			for o: int in offsets:
				if mask[i4 + o] == 0:
					var dl: float = absf(lstar[i4] - lstar[i4 + o])
					edge_sum += dl
					edge_n += 1
					if dl > 15.0:
						edge_strong += 1
	var ys: PackedInt32Array = PackedInt32Array()
	for yy2: int in hh:
		for xx2: int in w:
			if mask[yy2 * w + xx2] == 1:
				ys.append(yy2)
	ys.sort()
	var robust_h: int = ys[int(ys.size() * 0.99) - 1] - ys[int(ys.size() * 0.01)] + 1 if ys.size() > 10 else my1 - my0 + 1
	var de: float = char_lab.distance_to(ring_lab)
	return {
		"mask_px": area, "mask_height_px": robust_h, "mask_bbox_height_px": my1 - my0 + 1, "mask_width_px": mx1 - mx0 + 1, "frame_height_frac": float(robust_h) / float(a.get_height()),
		"char_lab": [char_lab.x, char_lab.y, char_lab.z], "ring_lab": [ring_lab.x, ring_lab.y, ring_lab.z], "ring_radius_px": rad,
		"delta_e": de, "delta_l": char_lab.x - ring_lab.x, "ring_l_std": ring_std,
		"edge_contrast_l": edge_sum / maxf(float(edge_n), 1.0), "edge_strong_frac": float(edge_strong) / maxf(float(edge_n), 1.0),
		"salience": de / maxf(ring_std, 2.0),
	}
