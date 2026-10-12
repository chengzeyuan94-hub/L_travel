extends RefCounted
## sand：巴格达旅人一景的「风沙」动态层（look-dev 探针，不是交付代码）。
##
## 两个 GPUParticles3D（= 2 个 draw call，不投影）：
##  1) LookdevSandFlow —— 贴地流沙细丝 + 少量空中细沙闪光（每第 glint_every 个粒子）。
##     自定义 particles shader：沿风向（屏幕右 → 左）滑，每帧按烘焙的沙面高度图贴地、按坡度倾斜；
##     出生点只取「相机看得见的中景沙面」（逐列射线求地形遮挡），并避开路/营地走廊。
##  2) LookdevSandSpray —— 沙丘轮廓脊（同一批射线求出的 silhouette crest）上偶尔被风掀起的一缕金色薄纱。
## 光照：两套绘制 shader 都用自定义 light()（前向散射相位 × ATTENUATION），逆光时发亮、阴影里自然暗。
## 透明物 depth_draw_never + 软粒子；雾与景深走引擎默认叠加。
## 风向：-camera.global_basis.x 压平归一化。

const FLOW_PROCESS := "res://tools/traveler/lookdev_baghdad/lookdev_sand_flow_process.gdshader"
const FLOW_DRAW := "res://tools/traveler/lookdev_baghdad/lookdev_sand_flow.gdshader"
const SPRAY_PROCESS := "res://tools/traveler/lookdev_baghdad/lookdev_sand_spray_process.gdshader"
const SPRAY_DRAW := "res://tools/traveler/lookdev_baghdad/lookdev_sand_spray.gdshader"

var _viewer: Node3D
var _camera: Camera3D
var _surface: Object
var _screen := Vector2(1920, 1080)
var _focal := 1483.7
var _cam_stage := Vector3.ZERO
var _wind := Vector3.RIGHT
var _cam_fwd := Vector3.FORWARD
var _inv_cam := Transform3D.IDENTITY

func build(viewer: Node3D, cfg: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	_viewer = viewer
	_camera = viewer.camera
	_surface = viewer.ground_surface
	_screen = viewer.get_viewport().get_visible_rect().size
	_focal = _screen.y * 0.5 / tan(deg_to_rad(_camera.fov) * 0.5)
	_inv_cam = _camera.global_transform.affine_inverse()
	var cp := _camera.global_position
	_cam_stage = Vector3(-cp.x, cp.y, cp.z)
	var w := -_camera.global_basis.x
	w.y = 0.0
	_wind = w.normalized()
	var f := -_camera.global_basis.z
	f.y = 0.0
	_cam_fwd = f.normalized()

	# ---------------------------------------------------------------- 沙面高度图（世界坐标）
	var hm_cfg: Dictionary = cfg.get("heightmap", {})
	var hx: Array = hm_cfg.get("world_x", [-12.0, 12.0])
	var hz: Array = hm_cfg.get("world_z", [3.0, 27.0])
	var step := float(hm_cfg.get("step_u", 0.15))
	var nx := int(ceil((float(hx[1]) - float(hx[0])) / step)) + 1
	var nz := int(ceil((float(hz[1]) - float(hz[0])) / step)) + 1
	var hdata := PackedFloat32Array()
	hdata.resize(nx * nz)
	for j in nz:
		var wz := float(hz[0]) + j * step
		for i in nx:
			var wx := float(hx[0]) + i * step
			hdata[j * nx + i] = float(_surface.height_at(Vector2(-wx, wz)))
	var himg := Image.create_from_data(nx, nz, false, Image.FORMAT_RF, hdata.to_byte_array())
	himg.convert(Image.FORMAT_RH)   # 半精度：各平台都能线性过滤
	var htex := ImageTexture.create_from_image(himg)
	var hmap := Vector4(float(hx[0]), float(hz[0]), 1.0 / step, 0.0)
	var hsize := Vector2(nx, nz)
	var t_height := Time.get_ticks_msec() - t0

	# ---------------------------------------------------------------- 射线：可见沙面 + 轮廓脊
	var tree_masks := _tree_masks(cfg)
	var scan := _scan(cfg, tree_masks)
	var t_scan := Time.get_ticks_msec() - t0 - t_height

	var rng := RandomNumberGenerator.new()
	rng.seed = int(cfg.get("seed", 20260923))
	var flow_cfg: Dictionary = cfg.get("flow", {})
	var spray_cfg: Dictionary = cfg.get("spray", {})
	var spawn_tex := _weighted_texture(scan.spawn, int(flow_cfg.get("spawn_samples", 1024)), rng)
	var crest_tex := _weighted_texture(scan.crest, int(spray_cfg.get("crest_samples", 256)), rng)

	var aabb := AABB(Vector3(float(hx[0]) - 2.0, -1.5, float(hz[0]) - 1.0), Vector3(float(hx[1]) - float(hx[0]) + 4.0, 5.0, float(hz[1]) - float(hz[0]) + 2.0))
	var common := {"height_tex": htex, "hmap": hmap, "hsize": hsize, "wind_dir": _wind}
	var nodes: Array = []
	var ev := {}
	if bool(flow_cfg.get("enabled", true)) and scan.spawn.size() > 0:
		var n := _flow(flow_cfg, common, spawn_tex, tree_masks, aabb)
		nodes.append(n)
		ev["flow"] = {"amount": n.amount, "lifetime_s": n.lifetime, "glints": int(ceil(float(n.amount) / float(int(flow_cfg.get("glint_every", 6))))), "spawn_candidates": scan.spawn.size(), "spawn_samples": spawn_tex.get_width()}
	if bool(spray_cfg.get("enabled", true)) and scan.crest.size() > 0:
		var n2 := _spray(spray_cfg, common, crest_tex, tree_masks, aabb)
		nodes.append(n2)
		ev["spray"] = {"amount": n2.amount, "lifetime_s": n2.lifetime, "crest_candidates": scan.crest.size(), "crest_samples": crest_tex.get_width()}
	ev["draw_calls_added"] = nodes.size()
	ev["cast_shadow"] = false
	ev["wind_world"] = [_wind.x, _wind.y, _wind.z]
	ev["focal_px"] = _focal
	ev["heightmap"] = {"nx": nx, "nz": nz, "step_u": step, "ms": t_height}
	ev["scan_ms"] = t_scan
	ev["crest_rows"] = scan.crest_rows
	ev["spawn_screen_bounds"] = scan.spawn_bounds
	ev["tree_masks_px"] = {"trunk": _tan_rect_px(tree_masks.trunk), "crown": _tan_rect_px(tree_masks.crown), "tree_depth": tree_masks.depth}
	ev["speed_px_s"] = _speed_evidence(flow_cfg, spray_cfg)
	ev["build_ms"] = Time.get_ticks_msec() - t0
	if bool(cfg.get("park_window", false)):
		ev["window"] = _park_window(cfg)
	return ev

# ---------------------------------------------------------------- 录制稳定性（与画面无关）
# macOS 上 Godot 窗口被完全遮挡时会停止绘制（录像卡死在同一帧）。并行跑批时每个
# capture 窗口都一样大、居中、置顶，新开的会盖住旧的。这里只把**本进程**的窗口缩小
# 并挪到屏幕角落，既不被别人盖住、也不盖住别人。SubViewport（1920×1080）不受影响。
func _park_window(cfg: Dictionary) -> Dictionary:
	var wid := DisplayServer.MAIN_WINDOW_ID
	var screen := DisplayServer.window_get_current_screen(wid)
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var size_arr: Array = cfg.get("park_window_size", [288, 162])
	var size := Vector2i(int(size_arr[0]), int(size_arr[1]))
	var corner := str(cfg.get("park_window_corner", "bottom_left"))
	var pos := usable.position
	if corner.contains("right"):
		pos.x = usable.end.x - size.x
	if corner.contains("bottom"):
		pos.y = usable.end.y - size.y
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED, wid)
	DisplayServer.window_set_min_size(Vector2i(64, 36), wid)
	DisplayServer.window_set_size(size, wid)
	DisplayServer.window_set_position(pos, wid)
	return {"screen": screen, "usable": [usable.position.x, usable.position.y, usable.size.x, usable.size.y], "pos": [pos.x, pos.y], "size": [size.x, size.y], "corner": corner}

# ---------------------------------------------------------------- 工具
func _stage_to_world(p: Vector3) -> Vector3:
	return _viewer.stage_point(p)

func _tan(world: Vector3) -> Vector2:
	var v := _inv_cam * world
	var d := maxf(-v.z, 1e-4)
	return Vector2(v.x / d, v.y / d)

func _tan_rect_px(r: Vector4) -> Array:
	# 正切坐标（y 向上）→ 屏幕像素（y 向下）
	return [round(_screen.x * 0.5 + r.x * _focal), round(_screen.y * 0.5 - r.w * _focal), round(_screen.x * 0.5 + r.z * _focal), round(_screen.y * 0.5 - r.y * _focal)]

func _depth(world: Vector3) -> float:
	return -(_inv_cam * world).z

# ---------------------------------------------------------------- 树的让位遮罩（树干矩形 + 树冠椭圆，正切坐标）
func _tree_masks(cfg: Dictionary) -> Dictionary:
	var tree: Node3D = _viewer.tree
	var result := {"trunk": Vector4.ZERO, "crown": Vector4.ZERO, "depth": 0.0}
	if tree == null:
		return result
	var mi := tree.find_child("OriginalTexturedMesh", true, false) as MeshInstance3D
	if mi == null or mi.mesh == null:
		return result
	var verts: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var xf := mi.global_transform
	var base := tree.global_position
	var height_u := float(_viewer.settings.tree.get("height_u", 7.65))
	var trunk_frac := float(cfg.get("trunk_height_frac", 0.2))
	var trunk_r := float(cfg.get("trunk_radius_u", 1.6))
	var t_lo := Vector2(INF, INF); var t_hi := Vector2(-INF, -INF)
	var c_lo := Vector2(INF, INF); var c_hi := Vector2(-INF, -INF)
	var dmin := INF
	var stride := maxi(1, verts.size() / 60000)
	var i := 0
	while i < verts.size():
		var wv: Vector3 = xf * verts[i]
		var tn := _tan(wv)
		dmin = minf(dmin, _depth(wv))
		var rel := (wv.y - base.y) / height_u
		var radial := Vector2(wv.x - base.x, wv.z - base.z).length()
		if rel < trunk_frac and radial < trunk_r:
			t_lo = t_lo.min(tn); t_hi = t_hi.max(tn)
		elif rel >= trunk_frac:
			c_lo = c_lo.min(tn); c_hi = c_hi.max(tn)
		i += stride
	var pad := float(cfg.get("tree_mask_pad_px", 6.0)) / _focal
	result.trunk = Vector4(t_lo.x - pad, t_lo.y - pad, t_hi.x + pad, t_hi.y + pad)
	result.crown = Vector4(c_lo.x - pad, c_lo.y - pad, c_hi.x + pad, c_hi.y + pad)
	result.depth = dmin
	return result

func _in_tree_front(tn: Vector2, depth: float, masks: Dictionary) -> bool:
	if depth >= float(masks.depth):
		return false
	var r: Vector4 = masks.trunk
	if tn.x > r.x and tn.x < r.z and tn.y > r.y and tn.y < r.w:
		return true
	var c: Vector4 = masks.crown
	var cc := Vector2((c.x + c.z) * 0.5, (c.y + c.w) * 0.5)
	var hr := Vector2(maxf((c.z - c.x) * 0.5, 1e-4), maxf((c.w - c.y) * 0.5, 1e-4))
	return ((tn - cc) / hr).length() < 1.0

# ---------------------------------------------------------------- 逐列射线：可见沙面样本 + 轮廓脊
func _scan(cfg: Dictionary, masks: Dictionary) -> Dictionary:
	var sc: Dictionary = cfg.get("scan", {})
	var win: Array = sc.get("screen_x", [470.0, 1450.0])
	var col_px := float(sc.get("column_px", 8.0))
	var d0 := float(sc.get("d_min", 2.5))
	var d1 := float(sc.get("d_max", 30.0))
	var dstep := float(sc.get("d_step", 0.1))
	var tol := float(sc.get("visible_tol_rad", 0.0003))
	var spawn_depth: Array = sc.get("spawn_depth", [4.6, 21.0])
	var crest_depth: Array = sc.get("crest_depth", [7.0, 26.0])
	var crest_gap := float(sc.get("crest_gap_u", 1.5))
	var corridor: Array = sc.get("corridor_stage", [-1.9, 1.9, 7.4])   # 舞台 x0, x1, z_max
	var sky_weight := float(sc.get("crest_skyline_weight", 1.0))
	var inner_weight := float(sc.get("crest_inner_weight", 0.35))
	var spawn: Array = []
	var crest: Array = []
	var rows := {}
	var sb := Rect2()
	var sb_init := false
	var sx := float(win[0])
	while sx <= float(win[1]):
		var ray := _camera.project_ray_normal(Vector2(sx, _screen.y * 0.72))
		var dir := Vector2(-ray.x, ray.z).normalized()     # 舞台 xz
		var ds: Array = []
		var es: Array = []
		var hs: Array = []
		var ps: Array = []
		var d := d0
		while d <= d1:
			var p := Vector2(_cam_stage.x, _cam_stage.z) + dir * d
			var h := float(_surface.height_at(p))
			ds.append(d); hs.append(h); ps.append(p)
			es.append(atan2(h - _cam_stage.y, d))
			d += dstep
		var runmax := -INF
		var n := es.size()
		for k in n:
			var e: float = es[k]
			var visible := e >= runmax - tol
			if visible:
				var p2: Vector2 = ps[k]
				var world := _stage_to_world(Vector3(p2.x, hs[k], p2.y))
				var depth := _depth(world)
				var in_corr: bool = p2.x > float(corridor[0]) and p2.x < float(corridor[1]) and p2.y < float(corridor[2])
				if depth >= float(spawn_depth[0]) and depth <= float(spawn_depth[1]) and not in_corr:
					var px := _camera.unproject_position(world)
					# 权重 ∝ 扇形面积（d·Δd），开方压一压远处
					spawn.append([world.x, world.z, depth, 0.004 * depth * col_px / 8.0, sqrt(float(ds[k])) * dstep])
					if not sb_init:
						sb = Rect2(px, Vector2.ZERO); sb_init = true
					else:
						sb = sb.expand(px)
				# 轮廓脊：局部极大 + 身后被挡住至少 crest_gap
				if k > 0 and k < n - 1 and e > float(es[k - 1]) and e >= float(es[k + 1]):
					var j := k + 1
					while j < n and float(es[j]) < e:
						j += 1
					var gap: float = (float(ds[j - 1]) - float(ds[k])) if j < n else 99.0
					if gap >= crest_gap and depth >= float(crest_depth[0]) and depth <= float(crest_depth[1]):
						var tn := _tan(world)
						if not _in_tree_front(tn, depth, masks):
							var wgt := sky_weight if gap >= 99.0 else inner_weight
							crest.append([world.x, world.y, world.z, 0.004 * depth * col_px / 8.0 * 1.5, wgt])
							var pxc := _camera.unproject_position(world)
							var key := "skyline" if gap >= 99.0 else "inner"
							if not rows.has(key):
								rows[key] = {"count": 0, "x_px": [INF, -INF], "y_px": [INF, -INF], "depth_u": [INF, -INF]}
							var r: Dictionary = rows[key]
							r.count += 1
							r.x_px = [minf(r.x_px[0], pxc.x), maxf(r.x_px[1], pxc.x)]
							r.y_px = [minf(r.y_px[0], pxc.y), maxf(r.y_px[1], pxc.y)]
							r.depth_u = [minf(r.depth_u[0], depth), maxf(r.depth_u[1], depth)]
			runmax = maxf(runmax, e)
		sx += col_px
	return {"spawn": spawn, "crest": crest, "crest_rows": rows, "spawn_bounds": [sb.position.x, sb.position.y, sb.end.x, sb.end.y]}

# 按权重抽样成 N×1 RGBA32F 纹理：(x, y|z..., ...)。spawn: [x, z, depth, jitter, w]；crest: [x, y, z, jitter, w]
func _weighted_texture(items: Array, count: int, rng: RandomNumberGenerator) -> ImageTexture:
	count = maxi(count, 1)
	var cdf := PackedFloat32Array()
	var total := 0.0
	for it in items:
		total += float(it[4])
		cdf.append(total)
	var img := Image.create(count, 1, false, Image.FORMAT_RGBAF)
	for i in count:
		if items.is_empty():
			img.set_pixel(i, 0, Color(0, 0, 0, 0))
			continue
		var r := rng.randf() * total
		var lo := 0
		var hi := cdf.size() - 1
		while lo < hi:
			var mid := (lo + hi) / 2
			if cdf[mid] < r:
				lo = mid + 1
			else:
				hi = mid
		var it: Array = items[lo]
		img.set_pixel(i, 0, Color(float(it[0]), float(it[1]), float(it[2]), float(it[3])))
	return ImageTexture.create_from_image(img)

# ---------------------------------------------------------------- 1) 贴地流沙 + 闪光
func _flow(c: Dictionary, common: Dictionary, spawn_tex: ImageTexture, masks: Dictionary, aabb: AABB) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "LookdevSandFlow"
	p.amount = int(c.get("amount", 160))
	p.lifetime = float(c.get("lifetime_s", 3.5))
	p.preprocess = float(c.get("preprocess_s", p.lifetime * 1.5))
	p.randomness = float(c.get("randomness", 0.6))
	p.explosiveness = 0.0
	p.fixed_fps = 30
	p.interpolate = true
	p.fract_delta = true
	p.use_fixed_seed = true
	p.seed = int(c.get("seed", 911))
	p.local_coords = false
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	p.visibility_aabb = aabb
	var pm := ShaderMaterial.new()
	pm.shader = load(FLOW_PROCESS)
	for k in common.keys():
		pm.set_shader_parameter(k, common[k])
	pm.set_shader_parameter("spawn_tex", spawn_tex)
	pm.set_shader_parameter("spawn_count", spawn_tex.get_width())
	pm.set_shader_parameter("cam_pos", _camera.global_position)
	pm.set_shader_parameter("cam_fwd", _cam_fwd)
	pm.set_shader_parameter("focal_px", _focal)
	pm.set_shader_parameter("frame_dt", 1.0 / 30.0)
	_set_params(pm, c.get("process", {}))
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var dm := ShaderMaterial.new()
	dm.shader = load(FLOW_DRAW)
	dm.set_shader_parameter("wind_dir", _wind)
	dm.set_shader_parameter("trunk_tan", masks.trunk)
	dm.set_shader_parameter("crown_tan", masks.crown)
	dm.set_shader_parameter("tree_depth", float(masks.depth))
	dm.set_shader_parameter("mask_soft_tan", 10.0 / _focal)
	var cor: Array = c.get("corridor_world", [-1.9, 1.9, -10.0, 7.4])
	dm.set_shader_parameter("corridor", Vector4(float(cor[0]), float(cor[1]), float(cor[2]), float(cor[3])))
	if c.get("process", {}).has("flow_quad_px"):
		dm.set_shader_parameter("flow_quad_px", float(c.process.flow_quad_px))
	_set_params(dm, c.get("draw", {}))
	quad.material = dm
	p.draw_pass_1 = quad
	_viewer.world.add_child(p)
	p.global_transform = Transform3D.IDENTITY
	p.emitting = true
	return p

# ---------------------------------------------------------------- 2) 沙脊扬沙
func _spray(c: Dictionary, common: Dictionary, crest_tex: ImageTexture, masks: Dictionary, aabb: AABB) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "LookdevSandSpray"
	p.amount = int(c.get("amount", 9))
	p.lifetime = float(c.get("lifetime_s", 6.5))
	p.preprocess = float(c.get("preprocess_s", p.lifetime * 1.5))
	p.randomness = float(c.get("randomness", 0.8))
	p.explosiveness = 0.0
	p.fixed_fps = 30
	p.interpolate = true
	p.fract_delta = true
	p.use_fixed_seed = true
	p.seed = int(c.get("seed", 4242))
	p.local_coords = false
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	p.visibility_aabb = aabb.grow(1.0)
	var pm := ShaderMaterial.new()
	pm.shader = load(SPRAY_PROCESS)
	for k in common.keys():
		pm.set_shader_parameter(k, common[k])
	pm.set_shader_parameter("crest_tex", crest_tex)
	pm.set_shader_parameter("crest_count", crest_tex.get_width())
	_set_params(pm, c.get("process", {}))
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var dm := ShaderMaterial.new()
	dm.shader = load(SPRAY_DRAW)
	dm.set_shader_parameter("wind_dir", _wind)
	dm.set_shader_parameter("trunk_tan", masks.trunk)
	dm.set_shader_parameter("crown_tan", masks.crown)
	dm.set_shader_parameter("tree_depth", float(masks.depth))
	dm.set_shader_parameter("mask_soft_tan", 10.0 / _focal)
	_set_params(dm, c.get("draw", {}))
	quad.material = dm
	p.draw_pass_1 = quad
	_viewer.world.add_child(p)
	p.global_transform = Transform3D.IDENTITY
	p.emitting = true
	return p

func _set_params(mat: ShaderMaterial, src: Dictionary) -> void:
	for key in src.keys():
		var v: Variant = src[key]
		if v is Array:
			var a: Array = v
			if a.size() == 2:
				mat.set_shader_parameter(key, Vector2(float(a[0]), float(a[1])))
			elif a.size() == 3:
				mat.set_shader_parameter(key, Color(float(a[0]), float(a[1]), float(a[2])) if str(key).ends_with("color") else Vector3(float(a[0]), float(a[1]), float(a[2])))
			elif a.size() == 4:
				mat.set_shader_parameter(key, Vector4(float(a[0]), float(a[1]), float(a[2]), float(a[3])))
		elif v is bool:
			mat.set_shader_parameter(key, v)
		elif v is float or v is int:
			# int uniform（glint_every、spawn_count）要传 int
			if str(key) in ["glint_every"]:
				mat.set_shader_parameter(key, int(v))
			else:
				mat.set_shader_parameter(key, float(v))

func _speed_evidence(flow_cfg: Dictionary, spray_cfg: Dictionary) -> Dictionary:
	var fp: Dictionary = flow_cfg.get("process", {})
	var sp: Dictionary = spray_cfg.get("process", {})
	var fs: Array = fp.get("flow_speed", [0.45, 0.8])
	var gs: Array = fp.get("glint_speed", [0.9, 1.5])
	var ss: Array = sp.get("speed", [0.3, 0.55])
	var out := {}
	for d in [6.0, 10.0, 18.0]:
		var k: float = _focal / float(d)
		out["depth_%d" % int(d)] = {"flow": [float(fs[0]) * k, float(fs[1]) * k], "glint": [float(gs[0]) * k, float(gs[1]) * k], "spray": [float(ss[0]) * k, float(ss[1]) * k]}
	return out
