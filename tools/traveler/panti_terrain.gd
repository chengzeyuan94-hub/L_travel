extends SceneTree
## 盘橐雪景地表 · 完整地形样张（2026-09-20）
##
## 定位：**总监样张，不是落地实现。** Codex 16:31 刚开始写 scripts/traveler/panti/panti_snow_ground.gd，
## 所以这份工具一个字都不碰他的脚本，只读 data/traveler/panti_scene.json 与 processed 资产，
## 在他的机位、他的夕阳预设下渲出「地表应该长什么样」，给 Carlos 拍板、给 Codex 当标准。
##
##   godot --path . --script res://tools/traveler/panti_terrain.gd -- --out=<前缀> [--ab] [--no-rocks]
##
## ── 三条从 Codex 实际机位量出来的硬约束（推翻了我按长安冻结机位做的第一版）──
##
## 1. 机位是 Carlos 亲自授权过的**近地仰视**，不是长安那个俯视：
##    fov 40 / KEEP_HEIGHT / position_stage (-2.65625, 0.2526, -17) / look_at_stage (-2.65625, 3.4034, 0)
##    → 眼高只有 0.2526 单位，光轴**上仰 10.5°**。
##    授权原文：「雪松背景几乎铺满，不看天空，距离远的明显虚化，再仰视一些。」
##    所以「对齐概念图-1 的 43.65% 天空占比」是错的目标，他要的就是不看天空。
##
## 2. 地面只占画面**最下面约 23%**（地平线落在顶部下方 75.5%）。
##    深度 3 到无穷远全部压进 0.884→0.755 这 13% 的画幅里。
##    结论：**高度场在这个机位几乎不靠"看到起伏"生效，靠的是剪影和近场大面明暗。**
##
## 3. 遮挡包络才是真正的设计约束。眼高 0.2526，城堡底在 20.95 单位外的 y=0，
##    所以视线高度 = 0.2526·(1 − L/20.95)。任何高于它的地表都会挡住城堡底。
##    反解「只埋掉城墙最下面 0.42 单位」得到：
##        cap(L) = 0.2526 + (0.42 − 0.2526)·clamp(L/17, 0, 1)
##        cap(2)=0.272  cap(5)=0.301  cap(10)=0.351  cap(17)=0.420
##    规格表「雪景地板」的 A 区前景雪丘 2.5 概念米 = 0.885 单位，
##    是眼高的 **3.31 倍**，照抄会把整个画面连城堡一起糊掉。
##    四个区里只有 B 区（0.2–0.5 m = 0.071–0.177 单位）原样可用；
##    C 区侧向山脊只在**画面左右两侧**（不压城堡）可用；A 区必须降到 B/C 之间。
##
## ── 尺度 ──
## data/traveler/world-scale.json **不存在**（长安那份在 docs/design/shanhe-luren/world-scale.json，
## 声明 1 单位 = 20 m）。盘橐用的是自己的尺度：panti_scene.json 的
## concept_unit_u = 0.3541666 → 1 单位 ≈ 2.82 m，小人 0.6375 单位 = 1.8 概念米。
## 排布图的米数一律乘 0.3541666。

# ============================================================ 常量

const AZ := 0.62                    # motion_params._measured.traveler_camera.azimuth_rad
const CAM_STAGE := Vector3(-2.65625, 0.2526, -17.0)
const LOOK_STAGE := Vector3(-2.65625, 3.40336376383608, 0.0)
const FOV := 40.0
const IMG := Vector2i(1920, 1080)

const TAN_V := 0.3639702343         # tan(20°)
const COS_EL := 0.9832549076        # cos(10.5°)
const HALF_W_K := 0.6580801         # tan(20°)·(16/9)/cos(10.5°)
const EYE := 0.2526
const CAM_L := 17.0                 # 相机在 stage 里的 z 偏移；深度 L = stage_z + 17

# 地表网格（stage 空间，按透视展开：近密远疏）
const L_NEAR := 0.7
const L_FAR := 95.0
# **刻意做粗。** 概念图前景实测只有 6 个色调、大面不碎；而细网格在这个掠射机位下
# 每个切面只有约 6 px 高，分档就变成沿等深度行的同心色带。
# 46×52 时 L=2 处切面约 58×24 px，正好是低多边形该有的"一块面就是一块面"。
const ROWS := 46
const COLS := 52
const RD_MARGIN := 1.18
const RD_CAP := 62.0

const M := 0.35416666666666663      # panti_scene.json concept_unit_u

# 雪色：以 Codex 平板的 albedo (0.86,0.91,0.97) 为中位，上下各开一档。
# 不给雪加色相变化（会显脏）；夕阳的暖色由光照给，不写进顶点色。
const SNOW_TOP := Color(0.982, 0.990, 1.000)
const SNOW_SLOPE := Color(0.938, 0.958, 0.992)
const SNOW_SHADE := Color(0.855, 0.902, 0.988)   # 夕阳下阴影是画面唯一的冷色来源
const SNOW_PATH := Color(0.898, 0.926, 0.968)
const PRINT_DARK := Color(0.375, 0.422, 0.530)   # 脚印的迎面暗壁
const PRINT_RIM := Color(0.952, 0.968, 0.994)    # 脚印外沿被挤起来的雪

# 起伏预算（单位＝世界单位；括号里是概念米）
const A_NEAR_ROLL := 0.155          # 0.44 m  近场起伏（遮挡包络在 L=2 给的预算是 0.272，之前只用了 0.12）
const A_LEFT_RISE := 0.215          # 0.61 m  左前景坡（概念图-1 左下那道）
const A_MID_DRIFT := 0.175          # 0.49 m  中景风堆脊
const A_SIDE_BANK := 0.340          # 0.96 m  侧向雪岸（C 区，只在左右两侧）
const A_APRON := 0.440              # 1.24 m  城前横脊，专门埋城墙底
const APRON_L := 16.6
const APRON_SPAN := 2.9
const A_FAR_RISE := 0.550           # 1.55 m  远景抬升，把地平线接缝推进树线

# 城堡（panti_scene.json）
const FORT_L := 20.9457864761147095
const FORT_T := 3.4949528064470156  # = 0.8387028064470156 + 2.65625
const FORT_CORRIDOR := 7.0
const FORT_FRAME_X := Vector2(0.40, 0.86)

# 压实路径：**横穿画面**，不是朝城门笔直走。
# 概念图-1 实测：脚印从左边框低处进画（x≈0.05）向右上升到 x≈0.31 然后在开阔雪地里淡出，
# 屏幕方向约 −14°。径向的路在这个机位是正对着看的，深度读不出来——这是上一版真正的错。
const PATH_L0 := 2.2
const PATH_L1 := 9.5
const PATH_T0 := -2.6
const PATH_T1 := 1.6
const PATH_HALF := 0.30             # 0.85 m 压实半宽；概念图那条不到 1 m
const PATH_SOFT := 0.34

var out_prefix := ""
var do_ab := false
var with_rocks := true
var do_diag := false
var rng := RandomNumberGenerator.new()
var wind := Vector2(0.86, 0.51).normalized()
var stage_basis := Basis.IDENTITY
var settings: Dictionary = {}
var rocks: Array = []
var report: Dictionary = {}
var fort_node: MeshInstance3D = null
var relief_node: MeshInstance3D = null
var flat_node: MeshInstance3D = null
var prints_node: MeshInstance3D = null
var rock_root: Node3D = null


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_prefix = a.trim_prefix("--out=")
		elif a == "--ab":
			do_ab = true
		elif a == "--no-rocks":
			with_rocks = false
		elif a == "--diag":
			do_diag = true
	if out_prefix.is_empty():
		push_error("需要 --out=")
		quit(1)
		return
	var f := FileAccess.open("res://data/traveler/panti_scene.json", FileAccess.READ)
	if f == null:
		push_error("读不到 data/traveler/panti_scene.json")
		quit(1)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("panti_scene.json 解析失败")
		quit(1)
		return
	settings = parsed
	stage_basis = Basis(Vector3.UP, AZ)
	rng.seed = 20260920
	call_deferred("run")


# ============================================================ stage 坐标

func _stage_point(a: Vector3) -> Vector3:
	## 逐字复现 panti_viewer.gd:119-120。target 是 camera_target = (0,0,0)。
	## 已用相机自验：stage(-2.65625, 0.2526, -17) → (7.7160, 0.2526, 15.3794)，
	## 与 checkpoint-13 实测 (7.71573, 0.25260, 15.37931) 相符。
	var elev: float = float(settings.get("stage_elevation_u", 0.0))
	return stage_basis * Vector3(a.x, a.y + elev, -a.z)


func _vec(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func _half_w(l: float) -> float:
	return maxf(HALF_W_K * l, 0.35)


func _frame_x(l: float, t: float) -> float:
	return 0.5 + 0.5 * t / _half_w(l)


func _cap(l: float) -> float:
	## 遮挡包络：城堡走廊内地表的上限。见文件头第 3 条。
	return EYE + (0.42 - EYE) * clampf(l / 17.0, 0.0, 1.0)


# ============================================================ 噪声

func _hash2(i: Vector2) -> float:
	var v: float = sin(i.x * 127.1 + i.y * 311.7) * 43758.5453
	return v - floor(v)


func _vn(p: Vector2) -> float:
	var i := Vector2(floor(p.x), floor(p.y))
	var f: Vector2 = p - i
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	var a: float = _hash2(i)
	var b: float = _hash2(i + Vector2(1.0, 0.0))
	var c: float = _hash2(i + Vector2(0.0, 1.0))
	var d: float = _hash2(i + Vector2(1.0, 1.0))
	return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y)


func _n2(p: Vector2) -> float:
	## −1..1，三个八度的值噪声。**等向。**
	## 探针里的 _fbm 是 sin(x)·cos(y) 乘积，等值线沿 x/y 轴对齐，会留下棋盘走向。
	var v := 0.0
	var a := 1.0
	var n := 0.0
	var q := p
	for i in 3:
		v += a * (_vn(q) * 2.0 - 1.0)
		n += a
		a *= 0.5
		q = q * 2.07 + Vector2(17.3, 9.1)
	return v / maxf(n, 1e-6)


func _drift(p: Vector2, amp: float, spacing: float) -> float:
	## 风堆雪：垂直风向的脊，迎风缓、背风陡。横风方向做相位与幅度调制，
	## 否则退化成平行条纹（Carlos 2026-09-16 明令删过农田垄状条纹）。
	var s: float = p.dot(wind) / spacing
	var t: float = p.dot(Vector2(-wind.y, wind.x))
	var jitter: float = 0.34 * sin(t * 0.63) + 0.21 * sin(t * 1.47 + 1.3)
	var amod: float = 0.55 + 0.45 * sin(t * 0.41 + 0.7) * sin(t * 0.93 + 2.1)
	var u: float = fposmod(s + jitter, 1.0)
	var h: float
	if u < 0.72:
		h = smoothstep(0.0, 1.0, u / 0.72)
	else:
		h = 1.0 - smoothstep(0.0, 1.0, (u - 0.72) / 0.28) * 0.92
	return h * amp * maxf(amod, 0.0)


# ============================================================ 路径

func _path_t(l: float) -> float:
	var s: float = clampf((l - PATH_L0) / (PATH_L1 - PATH_L0), 0.0, 1.0)
	return lerp(PATH_T0, PATH_T1, s) + 0.35 * sin(s * 4.2)


func _path_mask(l: float, t: float) -> float:
	var off: float = absf(t - _path_t(l))
	var fade: float = 1.0 - smoothstep(PATH_L1, PATH_L1 + 2.5, l)
	return (1.0 - smoothstep(PATH_HALF, PATH_HALF + PATH_SOFT, off)) * fade


# ============================================================ 高度场（stage 空间）

func _h(sx: float, sz: float) -> Dictionary:
	var l: float = sz + CAM_L            # 离相机的水平深度
	var t: float = sx + 2.65625          # 相对光轴的横向偏移
	var p := Vector2(sx, sz)
	var rn: float = t / _half_w(maxf(l, 0.35))

	var h := 0.0

	# ── 近场长缓起伏（L<7）。这个机位下近场是最有戏的地方：
	#    0.075 单位的丘在 L=2 处就张 2.1°，占画幅 5%——小数字干大活，跟长安正相反。
	var w_near: float = 1.0 - smoothstep(3.0, 8.0, l)
	h += w_near * _drift(p, A_NEAR_ROLL, 1.9)
	h += w_near * A_NEAR_ROLL * 0.45 * _n2(p * 0.38)
	# 横向补一条与风向垂直的长缓波：概念图的雪面是横着铺开的大面，
	# 只有沿视线的起伏会让画面读成一条条水平带。
	h += w_near * A_NEAR_ROLL * 1.00 * _n2(Vector2(sx * 0.85, sz * 0.22))

	# ── 左前景坡：概念图-1 左下那道从边框升起的雪坡
	var w_lf: float = (1.0 - smoothstep(2.0, 7.5, l)) * smoothstep(-0.28, -0.95, rn)
	h += w_lf * A_LEFT_RISE

	# ── 中景风堆脊
	var w_mid: float = smoothstep(4.0, 8.0, l) * (1.0 - smoothstep(20.0, 30.0, l))
	h += w_mid * _drift(p, A_MID_DRIFT, 2.8)
	h += w_mid * A_MID_DRIFT * 0.70 * _n2(Vector2(sx * 0.34, sz * 0.11))

	# ── 侧向雪岸（规格表 C 区）：只在画面左右两侧抬起，不压城堡。
	#    两张排布图都写「左/右侧边缘…形成画面框架」，这是地表版的同一条。
	var w_side: float = smoothstep(3.5, 9.0, l) * (1.0 - smoothstep(26.0, 40.0, l))
	var side: float = smoothstep(0.46, 1.06, absf(rn))
	h += w_side * side * A_SIDE_BANK * (0.55 + 0.45 * _n2(p * 0.24))

	# ── 城前横脊：专门把城墙最下面一截埋掉（Carlos 点过的口味项之一）。
	#    脊线自己起伏，并在城门正前方开口，不然就是一道墙。
	var band: float = exp(-pow((l - APRON_L) / APRON_SPAN, 2.0))
	var crest: float = 0.56 + 0.44 * _n2(Vector2(t * 0.42, 5.1))
	var gate: float = 1.0 - 0.78 * exp(-pow((t - FORT_T) / 2.6, 2.0))
	h += band * A_APRON * crest * gate

	# ── 远景抬升：把地平线接缝推进树线以内。DOF 从 27.5 开始虚化，这里不需要细节。
	h += smoothstep(28.0, 70.0, l) * A_FAR_RISE * (0.70 + 0.30 * _n2(p * 0.14))

	# ── B 区路径：**相对**压平并微沉。绝对高度 lerp 会在坡上挖沟（探针实测）。
	var w_path: float = _path_mask(l, t)
	h = lerp(h, h * 0.80 - 0.022, w_path)

	# ── 石头脚下的窝。注意：资产自带一圈平的白雪裙（实测 bbox 比石体宽 1.18–1.27 倍），
	#    所以这里**只在背风侧堆雪、不再挖凹**，免得和自带雪裙打架。
	for spot in rocks:
		var c: Vector2 = spot["xz"]
		var r: float = spot["r"]
		var lee: Vector2 = c + wind * r * 1.5
		var ql: float = clampf(p.distance_to(lee) / maxf(r * 1.8, 0.8), 0.0, 1.0)
		if ql < 1.0:
			h += 0.26 * r * (0.5 + 0.5 * cos(ql * PI))

	# ── 遮挡包络：城堡走廊内一律夹到 cap(L) 以下，城前横脊除外（它就是要埋墙底）。
	if absf(t - FORT_T) < FORT_CORRIDOR and l < APRON_L - APRON_SPAN:
		h = minf(h, _cap(l))

	return {"h": h, "path": w_path, "l": l, "t": t}


# ============================================================ 地表网格

func _build_relief() -> Dictionary:
	var ratio: float = pow(L_FAR / L_NEAR, 1.0 / float(ROWS - 1))
	var ls := PackedFloat32Array()
	var l: float = L_NEAR
	for i in ROWS:
		ls.append(l)
		l *= ratio

	var hs: Array = []
	var ps: Array = []
	var xs: Array = []
	for i in ROWS:
		var row_h := PackedFloat32Array()
		var row_p := PackedFloat32Array()
		var row_x := PackedFloat32Array()
		var ext: float = minf(_half_w(ls[i]) * RD_MARGIN + 1.5, RD_CAP)
		for j in COLS:
			var t: float = lerp(-ext, ext, float(j) / float(COLS - 1))
			var sx: float = t - 2.65625
			var sz: float = ls[i] - CAM_L
			var r := _h(sx, sz)
			row_h.append(float(r["h"]))
			row_p.append(float(r["path"]))
			row_x.append(sx)
		hs.append(row_h)
		ps.append(row_p)
		xs.append(row_x)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris := 0
	for i in ROWS - 1:
		var z0: float = ls[i] - CAM_L
		var z1: float = ls[i + 1] - CAM_L
		for j in COLS - 1:
			var a := Vector3(xs[i][j], hs[i][j], z0)
			var b := Vector3(xs[i][j + 1], hs[i][j + 1], z0)
			var c := Vector3(xs[i + 1][j + 1], hs[i + 1][j + 1], z1)
			var d := Vector3(xs[i + 1][j], hs[i + 1][j], z1)
			var pw: float = (ps[i][j] + ps[i][j + 1] + ps[i + 1][j + 1] + ps[i + 1][j]) * 0.25
			if ((i + j) % 2) == 0:
				_face(st, a, b, c, pw)
				_face(st, a, c, d, pw)
			else:
				_face(st, a, b, d, pw)
				_face(st, b, c, d, pw)
			tris += 2
	var committed: ArrayMesh = st.commit()
	# 法线自检：同材质、同光、关阴影下起伏网格仍比平板暗 0.25 个 V，只剩法线可疑。
	var arrs: Array = committed.surface_get_arrays(0)
	var nrms: PackedVector3Array = arrs[Mesh.ARRAY_NORMAL]
	var sum_y := 0.0
	var min_y := 9.0
	var below := 0
	for nv in nrms:
		sum_y += nv.y
		min_y = minf(min_y, nv.y)
		if nv.y < 0.90:
			below += 1
	var nstat := {"verts": nrms.size(), "mean_ny": sum_y / maxf(float(nrms.size()), 1.0),
		"min_ny": min_y, "frac_ny_below_0.90": float(below) / maxf(float(nrms.size()), 1.0)}
	print("[NORMALS] ", JSON.stringify(nstat))
	return {"mesh": committed, "normals": nstat, "triangles": tris, "quads": (ROWS - 1) * (COLS - 1),
		"rows": ROWS, "cols": COLS, "l_near": L_NEAR, "l_far": L_FAR}


func _face(st: SurfaceTool, s0: Vector3, s1: Vector3, s2: Vector3, path_w: float) -> void:
	## **收 stage 空间的点，变换后自己定绕序。**
	## _stage_point 里的 −a.z 是一次镜像，会翻转手性：在 stage 空间绕序一致的三角形
	## 变到世界空间后全部朝下，被 cull_back 剔掉，画面看到的是穿过去的环境
	## ground_bottom_color (0.30,0.36,0.53)。实测代价：整条地面带 V 均值 0.807→0.565、
	## S 0.192→0.378、冷占比 4.7%→86.8%，而自阴影与 SSAO 四路隔离全部无差异。
	var p0: Vector3 = _stage_point(s0)
	var p1: Vector3 = _stage_point(s1)
	var p2: Vector3 = _stage_point(s2)
	var nrm: Vector3 = (p1 - p0).cross(p2 - p0)
	if nrm.length() < 1e-9:
		return
	nrm = nrm.normalized()
	if nrm.y < 0.0:
		# 法线朝下说明绕序反了：换两个顶点，法线与绕序一起翻正
		nrm = -nrm
		var tmp: Vector3 = p1
		p1 = p2
		p2 = tmp
	# 逐面平色，三档白按朝向取：白对白唯一有效的读法。
	# 概念图前景实测只有 6 个色调、大面不碎，所以档数少、抖动小是对的。
	# 分档量化。区间取法线的**实测分布**（均值 n.y 0.9957、最小 0.724），
	# 不是 0..1——按 0..1 分档的话几乎所有面都落进最亮那一档，等于没分。
	# 太阳仰角 14° 时相对明暗灵敏度是 cot(14°)=4.01（60° 太阳只有 0.577），
	# 低太阳把坡度对比放大约 7 倍，所以档数少、台阶明确就够，不需要大幅度起伏。
	var up: float = clampf(nrm.y, 0.0, 1.0)
	var t5: float = floor(smoothstep(0.955, 1.0, up) * 4.0) / 4.0
	var col: Color = SNOW_SHADE.lerp(SNOW_SLOPE, minf(t5 * 2.0, 1.0))
	if t5 > 0.5:
		col = SNOW_SLOPE.lerp(SNOW_TOP, (t5 - 0.5) * 2.0)
	if path_w > 0.15:
		col = col.lerp(SNOW_PATH, minf(1.0, (path_w - 0.15) / 0.45) * 0.9)
	# 逐面抖动去掉：切面只有 6 px 时它变成椒盐噪点，不再是"打碎大面"
	for p in [p0, p1, p2]:
		st.set_normal(nrm)
		st.set_color(col)
		st.add_vertex(p)


func _snow_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	m.metallic = 0.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# 夕阳仰角只有 14°，平雪的 N·L 实测 0.242，背光坡几乎只剩环境光，所以用 wrap 抬高明暗交界线。
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT_WRAP
	# **必须关剔除。** 这里踩过一个把前面所有测量都作废的坑：
	# _stage_point 里的 −a.z 是镜像、会翻手性，而 Godot 判正面靠**绕序**，不靠法线方向。
	# 我按"法线朝上"去翻绕序，结果把整片地表翻成了背面，被完整剔除——
	# 判决性实测：隐藏地表与显示地表，画面同一点读数完全相同 (75,99,145)；
	# 只留地表时整条带子 V=0.591，正好等于环境 ground_bottom→ground_horizon 的渐变。
	# 也就是说前几版看到的"雪面"全是透过去的天空底色。
	# 项目里已有先例：shaders/traveler/atlas_surface.gdshader 就是 render_mode cull_disabled。
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _flat_mesh() -> Mesh:
	var pm := PlaneMesh.new()
	pm.size = Vector2(float(settings.ground.size_u[0]), float(settings.ground.size_u[1]))
	var m := StandardMaterial3D.new()
	var al: Array = settings.ground.albedo
	m.albedo_color = Color(float(al[0]), float(al[1]), float(al[2]))
	m.roughness = 1.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	pm.material = m
	return pm


# ============================================================ 脚印

func _build_prints() -> Dictionary:
	## 近地机位的关键坑：**平铺的贴片在掠射角下读不出来。**
	## L=3 处地面的入射角只有 atan(0.2526/3)=4.8°，一块 0.088 单位长的平贴片
	## 垂直方向只剩 0.0074 单位 ≈ 3.6 px。
	## 所以每个脚印做成两片小几何：一片朝相机的暗壁（凹陷的近壁）+ 一片背后被挤起的亮沿。
	## 0.032 单位的暗壁在 L=3 处是 15.6 px，正好是概念图-1 里脚印的大小。
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 0
	# 人的单列 + 骆驼的一列，两条编在一起（概念图-1 是人畜并行）
	var lanes := [
		{"off": 0.0, "stride": 0.2656, "w": 0.026, "hh": 0.019, "alt": 0.055},
		{"off": 0.36, "stride": 0.3190, "w": 0.038, "hh": 0.024, "alt": 0.032},
	]
	for lane in lanes:
		var l: float = PATH_L0
		var side := 1.0
		while l < PATH_L1:
			var t: float = _path_t(l) + float(lane["off"]) + side * float(lane["alt"])
			var sx: float = t - 2.65625
			var sz: float = l - CAM_L
			var y: float = float(_h(sx, sz)["h"])
			# 逐个脚印加随机：等大等距会读成一串灰方块（v5 实测）
			var jit: float = rng.randf_range(0.80, 1.22)
			var w: float = float(lane["w"]) * jit
			var hh: float = float(lane["hh"]) * jit
			# 暗壁：朝相机（stage −z 方向），略后倾
			var base := Vector3(sx, y + 0.002, sz)
			_quad(st, base + Vector3(-w, 0.0, 0.0), base + Vector3(w, 0.0, 0.0),
				base + Vector3(w, hh, -hh * 0.35), base + Vector3(-w, hh, -hh * 0.35), PRINT_DARK)
			# **亮沿去掉。** v5/v9 里它和暗壁一样醒目，两片加起来把脚印读成了踏脚石。
			# 概念图-1 实测：脚印是 0.10–0.16 m 宽的**暗点**（被遮住的凹陷），
			# 不是带白边的凸起。所以只留迎面暗壁一片。
			l += rng.randf_range(-0.04, 0.04)
			n += 1
			side = -side
			l += float(lane["stride"])
	return {"mesh": st.commit(), "count": n}


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	# 同样受 _stage_point 的镜像影响：绕序按"法线要朝相机"定，否则脚印全被剔除。
	var cam_w: Vector3 = _stage_point(CAM_STAGE)
	var wa: Vector3 = _stage_point(a)
	var wb: Vector3 = _stage_point(b)
	var wc: Vector3 = _stage_point(c)
	var wd: Vector3 = _stage_point(d)
	for tri in [[wa, wb, wc], [wa, wc, wd]]:
		var q0: Vector3 = tri[0]
		var q1: Vector3 = tri[1]
		var q2: Vector3 = tri[2]
		var nrm: Vector3 = (q1 - q0).cross(q2 - q0)
		if nrm.length() < 1e-9:
			continue
		nrm = nrm.normalized()
		if nrm.dot(cam_w - q0) < 0.0:
			nrm = -nrm
			var tmp: Vector3 = q1
			q1 = q2
			q2 = tmp
		for p in [q0, q1, q2]:
			st.set_normal(nrm)
			st.set_color(col)
			st.add_vertex(p)


# ============================================================ 石头排布

func _plan_rocks() -> void:
	## 石头排布规划·正面排布图：前景层 XL（框架）→ 近景层 L（丰富）→ 中景层 M（过渡）→ 远景层 S（点缀），
	## 「石头高度逐级降低，不遮挡城堡主体」「城门前方保持开阔 避免大型石头遮挡视线」。
	## 俯视点位图数出来的班级配比是 **L 占多数**（XL 8 / L 50 / M 35 + 若干 S），
	## 我第一版是 XL 为主，配比反了。
	var tiers := [
		{"tier": "XL", "m": 3.2, "l": [8.0, 12.0], "rn": [0.74, 1.04], "n": 2},
		{"tier": "L", "m": 2.4, "l": [7.0, 17.0], "rn": [0.34, 1.02], "n": 14},
		{"tier": "M", "m": 1.6, "l": [9.0, 24.0], "rn": [0.14, 1.00], "n": 20},
		{"tier": "S", "m": 1.0, "l": [12.0, 30.0], "rn": [0.06, 0.98], "n": 24},
	]
	for tr in tiers:
		var h0: float = float(tr["m"]) * M
		var name: String = String(tr["tier"])
		var want: int = int(tr["n"])
		var made := 0
		var guard := 0
		while made < want and guard < want * 40:
			guard += 1
			var l: float = rng.randf_range(tr["l"][0], tr["l"][1])
			var sgn: float = 1.0 if rng.randf() < 0.5 else -1.0
			var rn: float = sgn * rng.randf_range(tr["rn"][0], tr["rn"][1])
			var t: float = rn * _half_w(l)
			var hm: float = h0 * rng.randf_range(0.80, 1.18)
			# 「城门前方保持开阔」：落在城堡屏幕横带里的石头，高度必须低于遮挡包络
			var fx: float = _frame_x(l, t)
			if fx > FORT_FRAME_X.x and fx < FORT_FRAME_X.y and l < FORT_L:
				if hm > _cap(l):
					continue
			# 不压住小人（stage (-3.587, 0, -13.938) → L 3.062 / t −0.931）
			if l < 5.0 and absf(t - (-0.931)) < 0.9:
				continue
			# 不压在脚印上：第一版左侧那堆大石把整条压实路径挡掉了
			if l < PATH_L1 + 2.0 and absf(t - _path_t(l)) < hm * 0.9 + 0.55:
				continue
			var sx: float = t - 2.65625
			var sz: float = l - CAM_L
			rocks.append({"xz": Vector2(sx, sz), "r": hm * 0.85, "h": hm, "tier": name,
				"l": l, "t": t, "frame_x": fx,
				"sy": rng.randf_range(0.80, 1.55), "yaw": rng.randf_range(0.0, TAU)})
			made += 1


# ============================================================ 资产

func _load_asset(path: String) -> Dictionary:
	var packed: PackedScene = load(path)
	if packed == null:
		return {}
	var scene: Node = packed.instantiate()
	var found: Array = scene.find_children("*", "MeshInstance3D", true, false)
	if found.is_empty():
		scene.free()
		return {}
	var src: MeshInstance3D = found[0]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat: Material = src.get_active_material(0)
	var dup: StandardMaterial3D = null
	if mat is StandardMaterial3D:
		dup = (mat as StandardMaterial3D).duplicate()
		dup.metallic = 0.0
		dup.roughness = 0.95
		dup.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		st.set_material(dup)
	# 合并该资产下的**所有**网格，不只第一个：石头资产自带的白雪裙与卫星小石
	# 可能是独立的 MeshInstance3D，只取 [0] 会把它们丢掉。
	for node in found:
		var mi: MeshInstance3D = node
		if mi.mesh == null:
			continue
		var xf: Transform3D = mi.transform
		var parent: Node = mi.get_parent()
		while parent is Node3D:
			xf = (parent as Node3D).transform * xf
			parent = parent.get_parent()
		for si in mi.mesh.get_surface_count():
			st.append_from(mi.mesh, si, xf)
	var mesh: ArrayMesh = st.commit()
	var tri: int = mesh.surface_get_array_index_len(0) / 3
	var n_mesh: int = found.size()
	scene.free()
	# mesh_nodes 要盯着：Codex 的 asset() 只取 found[0]。如果这里 >1，
	# 我的画面就比他多了东西，对照不成立，必须回到只取第一个。
	return {"mesh": mesh, "material": dup, "bounds": mesh.get_aabb(),
		"triangles": tri, "mesh_nodes": n_mesh}


func _snow_accum(tex: Texture2D, tint: Color, start: float, full: float, nscale: float) -> ShaderMaterial:
	var sh: Shader = load("res://shaders/traveler/snow_accum.gdshader")
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("use_tex", tex != null)
	if tex != null:
		m.set_shader_parameter("base_tex", tex)
	m.set_shader_parameter("base_tint", tint)
	m.set_shader_parameter("base_brightness", 1.0)
	m.set_shader_parameter("snow_lit", Vector3(SNOW_TOP.r, SNOW_TOP.g, SNOW_TOP.b))
	m.set_shader_parameter("snow_shade", Vector3(SNOW_SHADE.r, SNOW_SHADE.g, SNOW_SHADE.b))
	m.set_shader_parameter("snow_start", start)
	m.set_shader_parameter("snow_full", full)
	m.set_shader_parameter("noise_scale", nscale)
	return m


# ============================================================ 场景

func run() -> void:
	if with_rocks:
		_plan_rocks()
	var g := _build_relief()
	var pr := _build_prints()

	var vp := SubViewport.new()
	vp.size = IMG
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(vp)

	var world := Node3D.new()
	world.name = "PantiWorld"
	vp.add_child(world)

	# ── 地表：起伏版与 Codex 现用平板版，同一进程里可切，A/B 才成立
	relief_node = MeshInstance3D.new()
	relief_node.name = "SnowGroundRelief"
	relief_node.mesh = g["mesh"]
	relief_node.material_override = _snow_mat()
	# **地表不投射阴影。** 太阳仰角只有 14°，掠射地表的自阴影全是 acne：
	# 同进程四路隔离（真材质、只动 SSAO/SSIL/阴影）在近场开阔雪窗口实测——
	#   base 0.666 / |dy| 0.02196   no-ssao 0.671 / 0.02121   no-ssil 0.665 / 0.02198
	#   **no-shadow 0.726 / 0.00017**
	# 也就是说满地"指纹纹"与整体变暗都来自自阴影，与 SSAO/SSIL 无关、与起伏幅度也无关。
	# Codex 在平板上已经做过同一判断：panti_viewer.gd 注释
	# 「Preserve the accepted shadow reception; avoid low-sun self-shadow stripes.」
	# 代价：城前横脊与雪岸不再投自己的影子（石头仍然投影）。这个尺度的雪面上是划算的。
	relief_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(relief_node)

	flat_node = MeshInstance3D.new()
	flat_node.name = "SnowGroundFlat"
	flat_node.mesh = _flat_mesh()
	flat_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flat_node.position = _stage_point(_vec(settings.ground.center_stage))
	flat_node.visible = false
	world.add_child(flat_node)

	prints_node = MeshInstance3D.new()
	prints_node.name = "Footprints"
	prints_node.mesh = pr["mesh"]
	prints_node.material_override = _snow_mat()
	prints_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(prints_node)

	# ── 城堡（Codex 的资产与摆位，逐字照抄 build_castle）
	var fort_res := _load_asset(String(settings.fortress.asset))
	var fort_tri := 0
	if not fort_res.is_empty():
		fort_node = MeshInstance3D.new()
		fort_node.name = "PantiFortress"
		fort_node.mesh = fort_res["mesh"]
		var bounds: AABB = fort_res["bounds"]
		var s: float = float(settings.fortress.height_u) / bounds.size.y
		fort_node.scale = Vector3.ONE * s
		fort_node.position = _stage_point(_vec(settings.fortress.stage_position))
		fort_node.rotation.y = AZ + deg_to_rad(float(settings.fortress.yaw_relative_camera_deg))
		world.add_child(fort_node)
		fort_tri = int(fort_res["triangles"])

	# ── 雪松（Codex 的 54 株授权点位，逐字照抄 build_tree_group）
	var pine_res := _load_asset(String(settings.trees.asset))
	var tree_batches := 0
	var tree_count := 0
	if not pine_res.is_empty() and settings.trees.has("instances"):
		var groups: Dictionary = {}
		for e in settings.trees.instances:
			var tier: String = String(e.get("tier", "G"))
			if not groups.has(tier):
				groups[tier] = []
			groups[tier].append(e)
		var pb: AABB = pine_res["bounds"]
		for tier in groups:
			var arr: Array = groups[tier]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = pine_res["mesh"]
			mm.instance_count = arr.size()
			for i in arr.size():
				var e2: Dictionary = arr[i]
				var ws: float = float(e2["crown_diameter_u"]) / maxf(pb.size.x, pb.size.z)
				var sc := Vector3(ws, float(e2["height_u"]) / pb.size.y, ws)
				var bs := Basis(Vector3.UP, deg_to_rad(float(e2["yaw_deg"]))).scaled(sc)
				mm.set_instance_transform(i, Transform3D(bs, _stage_point(_vec(e2["stage_position"]))))
				mm.set_instance_custom_data(i, Color(rng.randf(), rng.randf_range(0.85, 1.15), rng.randf_range(0.8, 1.2), 1.0))
			var node := MultiMeshInstance3D.new()
			node.name = "SnowCedars_" + String(tier)
			node.multimesh = mm
			world.add_child(node)
			tree_batches += 1
			tree_count += arr.size()

	# ── 石头（Codex 场景里现在是 0 块；排布图的活还没人干）
	var rock_placed := 0
	if with_rocks:
		rock_root = Node3D.new()
		rock_root.name = "PantiRocks"
		world.add_child(rock_root)
		# rock02 底下挂着一块带乱码文字的独立底座，没清掉之前不进画面
		var rr := _load_asset("res://assets/traveler/panti/rock01-raw.fbx")
		if not rr.is_empty():
			var rb: AABB = rr["bounds"]
			var tex: Texture2D = null
			var tint := Color.WHITE
			if rr["material"] != null:
				tex = (rr["material"] as StandardMaterial3D).albedo_texture
				tint = (rr["material"] as StandardMaterial3D).albedo_color
			# 阈值调高：第一版 0.30→0.66 把石头整个糊成雪球，排布图画的是「顶白、侧面裸露蓝灰」
			# 0.74→0.96：只有接近水平的顶面积雪，陡壁保持裸岩。
			# 第一版 0.30→0.66 把石头整个糊成雪球（夕阳下成了粉色枕头）。
			var cool_tint := Color(tint.r * 0.70, tint.g * 0.745, tint.b * 0.870)
			var rmat: ShaderMaterial = _snow_accum(tex, cool_tint, 0.74, 0.96, 7.0)
			for spot in rocks:
				var mi := MeshInstance3D.new()
				mi.mesh = rr["mesh"]
				mi.material_override = rmat
				var sy: float = float(spot["sy"])
				var base_s: float = float(spot["h"]) / (rb.size.y * sy)
				mi.scale = Vector3(base_s, base_s * sy, base_s * rng.randf_range(0.88, 1.14))
				var c: Vector2 = spot["xz"]
				var y: float = float(_h(c.x, c.y)["h"]) - float(spot["h"]) * 0.18
				mi.position = _stage_point(Vector3(c.x, y, c.y))
				mi.rotation.y = float(spot["yaw"])
				rock_root.add_child(mi)
				rock_placed += 1

	# ── 小人（Codex 的场景与摆位）
	var char_root := Node3D.new()
	char_root.name = "ApprovedTraveler"
	world.add_child(char_root)
	char_root.position = _stage_point(_vec(settings.character.stage_position))
	var char_model: Node3D = null
	var cs: PackedScene = load(String(settings.character.scene))
	if cs != null:
		char_model = cs.instantiate()
		char_root.add_child(char_model)
		var pl: AnimationPlayer = char_model.find_child("AnimationPlayer", true, false)
		if pl != null:
			pl.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
			if pl.has_animation("idle"):
				pl.play("idle")
				pl.advance(0.0)

	_setup_look(vp)

	var cam := Camera3D.new()
	cam.name = "PantiCamera"
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.fov = FOV
	cam.near = 0.15
	cam.far = 900.0
	vp.add_child(cam)
	cam.make_current()
	cam.position = _stage_point(CAM_STAGE)
	cam.look_at(_stage_point(LOOK_STAGE))

	await RenderingServer.frame_post_draw
	# 角色落地：跟 build_character 一样按当前姿态的 AABB 把脚对齐到 y=0
	if char_model != null:
		var cm: Array = char_model.find_children("*", "MeshInstance3D", true, false)
		if not cm.is_empty():
			var bak: Mesh = (cm[0] as MeshInstance3D).bake_mesh_from_current_skeleton_pose()
			var cb: AABB = bak.get_aabb()
			char_model.position = Vector3(-cb.get_center().x, -cb.position.y, -cb.get_center().z)
		char_root.scale = Vector3.ONE * 0.6375
		char_root.look_at(_stage_point(_vec(settings.fortress.stage_position)), Vector3.UP, true)

	for i in 10:
		await process_frame
	await RenderingServer.frame_post_draw

	var measured := _measure(cam)
	var err_relief: int = vp.get_texture().get_image().save_png("%s.png" % out_prefix)

	# ── 四路隔离：低太阳（仰角 14°）下地表变暗，到底是自阴影还是 SSAO？
	#    Codex 在平板上写的注释是「avoid low-sun self-shadow stripes」，他已经关掉了投影。
	# ── 四路隔离 v2：上一轮只关了地表的 cast_shadow（投射），没关太阳的 shadow_enabled（接收），
	#    所以没能排除"整个前景落在 39 单位高雪松的长影里"这一项——太阳仰角仅 14°，
	#    一棵 39 单位的树投影长 39/tan(14°) = 156 单位。
	var diag := {}
	if do_diag:
		var we_node: WorldEnvironment = null
		var sun_node: DirectionalLight3D = null
		for ch in vp.get_children():
			if ch is WorldEnvironment:
				we_node = ch
			if ch is DirectionalLight3D:
				sun_node = ch
		var envr: Environment = we_node.environment
		# 隔离 v3：前面两轮全部无效——那时地表被背面剔除着（而且诊断材质自己也没关剔除）。
		# 这一轮四路全部用真材质 _snow_mat()，只动 SSAO / SSIL / 阴影。
		# mobile-sim：按 Godot 移动端渲染器**不支持**的清单把效果关掉，
		# 用来回答「这套画面搬到安卓掌机上会损失多少」——不需要真机、不需要导出。
		var we_attr: CameraAttributesPractical = we_node.camera_attributes
		for job in [
			{"tag": "base", "ao": true, "il": true, "sh": true, "glow": true, "dof": true},
			{"tag": "no-ssao", "ao": false, "il": true, "sh": true, "glow": true, "dof": true},
			{"tag": "no-ssil", "ao": true, "il": false, "sh": true, "glow": true, "dof": true},
			{"tag": "mobile-sim", "ao": false, "il": false, "sh": true, "glow": false, "dof": false},
		]:
			envr.ssao_enabled = bool(job["ao"])
			envr.ssil_enabled = bool(job["il"])
			envr.glow_enabled = bool(job["glow"])
			if we_attr != null:
				we_attr.dof_blur_far_enabled = bool(job["dof"])
			sun_node.shadow_enabled = bool(job["sh"])
			for i in 5:
				await process_frame
			await RenderingServer.frame_post_draw
			var e: int = vp.get_texture().get_image().save_png("%s-%s.png" % [out_prefix, String(job["tag"])])
			diag[String(job["tag"])] = e
		envr.ssao_enabled = true
		envr.ssil_enabled = true
		envr.glow_enabled = true
		if we_attr != null:
			we_attr.dof_blur_far_enabled = true
		sun_node.shadow_enabled = true

	var err_flat := -1
	if do_ab:
		relief_node.visible = false
		prints_node.visible = false
		flat_node.visible = true
		if rock_root != null:
			rock_root.visible = false
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		err_flat = vp.get_texture().get_image().save_png("%s-flat.png" % out_prefix)

	report = {
		"schema": "silkroad.panti-terrain.v2",
		"role": "总监样张（look target）。**不是落地实现**：Codex 16:31 已开始写 scripts/traveler/panti/panti_snow_ground.gd。",
		"reads_only": ["data/traveler/panti_scene.json", "assets/traveler/panti/processed/*",
			"assets/traveler/panti/rock01-raw.fbx", "shaders/traveler/snow_accum.gdshader"],
		"camera": {"source": "data/traveler/panti_scene.json camera_composition（Carlos 授权）",
			"fov": FOV, "position_stage": [CAM_STAGE.x, CAM_STAGE.y, CAM_STAGE.z],
			"look_at_stage": [LOOK_STAGE.x, LOOK_STAGE.y, LOOK_STAGE.z],
			"eye_height_u": EYE, "optical_axis_elevation_deg": 10.5,
			"horizon_frac_from_top": 0.755, "ground_frac_of_frame": 0.245,
			"nearest_visible_ground_l": 1.599},
		"occlusion_envelope": {"formula": "cap(L) = 0.2526 + (0.42 − 0.2526)·clamp(L/17,0,1)",
			"cap_at": {"2": _cap(2.0), "5": _cap(5.0), "10": _cap(10.0), "17": _cap(17.0)},
			"spec_sheet_A_zone_u": 2.5 * M,
			"spec_sheet_A_vs_eye": (2.5 * M) / EYE,
			"verdict": "规格表 A 区 0.885 单位 = 眼高 3.31 倍，照抄会糊掉整个画面。四区里只有 B 区原样可用。"},
		"amplitudes_u": {"near_roll": A_NEAR_ROLL, "left_rise": A_LEFT_RISE,
			"mid_drift": A_MID_DRIFT, "side_bank": A_SIDE_BANK, "apron": A_APRON,
			"far_rise": A_FAR_RISE, "concept_m": {"near_roll": A_NEAR_ROLL / M,
			"side_bank": A_SIDE_BANK / M, "apron": A_APRON / M}},
		"ground": {"triangles": g["triangles"], "quads": g["quads"], "rows": g["rows"],
			"cols": g["cols"], "l_near": g["l_near"], "l_far": g["l_far"],
			"surfaces": 1, "draw_calls": 1,
			"note": "stage 空间透视展开的扇形网格，单面无接缝。**机位锁定**，正式版应烘成世界空间瓦片。"},
		"path": {"shape": "横穿画面（概念图-1 实测屏幕方向约 −14°），不是径向走向城门",
			"l_range": [PATH_L0, PATH_L1], "t_range": [PATH_T0, PATH_T1],
			"half_u": PATH_HALF, "half_concept_m": PATH_HALF / M,
			"prints": pr["count"],
			"note": "掠射角下平贴片只有 3.6 px，所以每个脚印是「朝相机暗壁 + 背后亮沿」两片小几何。"},
		"rocks": {"planned": rocks.size(), "placed": rock_placed,
			"mix_source": "石头排列分布.png 俯视点位图数出的配比：L 占多数（XL 8 / L 50 / M 35 + S）",
			"tier_counts": _tier_counts(),
			"note": "Codex 场景当前 0 块石头。rock02 因底座乱码未采用。"},
		"context_from_codex": {"fortress_height_u": settings.fortress.height_u,
			"fortress_triangles": fort_tri, "trees": tree_count, "tree_batches": tree_batches,
			"character_scale": 0.6375},
		"look": {"preset": "panti/sunset（逐个参数复现 checkpoint-13 的 effective_params，不加载 panti_look.gd）",
			"period_authorization": "Carlos 2026-09-20: 光照改为夕阳光线；盘橐独立预设，替代此前明亮雪天方向。"},
		"measured": measured,
		"images": {"relief": "%s.png" % out_prefix,
			"flat": ("%s-flat.png" % out_prefix) if do_ab else "",
			"same_process_ab": do_ab},
		"save_error": {"relief": err_relief, "flat": err_flat},
		"diag": diag,
	}
	var fh := FileAccess.open("%s.json" % out_prefix, FileAccess.WRITE)
	if fh != null:
		fh.store_string(JSON.stringify(report, "  "))
		fh.close()

	print("[PANTI-TERRAIN] %s.png err=%d  A/B=%s err=%d" % [out_prefix, err_relief, str(do_ab), err_flat])
	print("  地表 %d 三角 / %d 格 / 1 draw call   脚印 %d 个（%d 片几何）" % [
		int(g["triangles"]), int(g["quads"]), int(pr["count"]), int(pr["count"]) * 4])
	print("  石头 %d（%s）   城 %d 三角   雪松 %d 株 / %d 批" % [
		rock_placed, JSON.stringify(_tier_counts()), fort_tri, tree_count, tree_batches])
	print("  遮挡包络 cap: L2=%.3f L5=%.3f L10=%.3f L17=%.3f   规格表 A 区 %.3f（眼高 %.2f 倍）" % [
		_cap(2.0), _cap(5.0), _cap(10.0), _cap(17.0), 2.5 * M, (2.5 * M) / EYE])
	quit(0)


func _tier_counts() -> Dictionary:
	var d := {}
	for r in rocks:
		var k: String = String(r["tier"])
		d[k] = int(d.get(k, 0)) + 1
	return d


func _setup_look(vp: SubViewport) -> void:
	## 逐个参数复现 checkpoint-13/sunset.json 的 look.effective_params，
	## **不加载 scripts/traveler/panti/panti_look.gd**——那份文件 Codex 正在动。
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.34, 0.42, 0.64)
	sm.sky_horizon_color = Color(0.94, 0.66, 0.44)
	sm.ground_horizon_color = Color(0.63, 0.57, 0.56)
	sm.ground_bottom_color = Color(0.30, 0.36, 0.53)
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.5                 # amb
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ssao_enabled = true
	env.ssao_radius = 0.35                         # ao —— 注意不是长安的 0.16，尺度不同
	env.ssao_intensity = 2.8                       # aoi
	env.ssao_power = 1.5
	env.ssao_detail = 0.5
	env.ssao_horizon = 0.06
	env.ssao_light_affect = 0.10
	env.ssil_enabled = true
	env.ssil_radius = 0.8                          # ssil
	env.ssil_intensity = 0.62                      # ssili
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.73, 0.67, 0.70)
	env.fog_density = 0.65                          # fogd
	env.fog_depth_begin = 25.0                      # fogb
	env.fog_depth_end = 95.0                        # foge
	env.fog_depth_curve = 1.0
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.12               # aerial
	env.glow_enabled = true
	env.glow_intensity = 0.1                        # glow
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.1                      # exp
	env.tonemap_white = 1.5                         # white
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.1                 # sat
	env.adjustment_contrast = 1.04                  # con
	# DOF：Carlos「距离远的要虚化要虚化。清晰区覆盖角色与完整城堡」
	var cam_attr := CameraAttributesPractical.new()
	cam_attr.dof_blur_far_enabled = true
	cam_attr.dof_blur_far_distance = 27.5           # dof
	cam_attr.dof_blur_far_transition = 8.0
	cam_attr.dof_blur_near_enabled = false          # dofn = 0
	cam_attr.dof_blur_amount = 0.2                  # blur
	var we := WorldEnvironment.new()
	we.environment = env
	we.camera_attributes = cam_attr
	vp.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Daylight"
	sun.light_color = Color(1.0, 0.66, 0.38)
	sun.light_energy = 2.55                         # sun
	sun.shadow_enabled = true
	sun.shadow_blur = 0.8                           # sblur
	sun.shadow_bias = 0.035                         # bias
	sun.shadow_normal_bias = 0.08                   # nbias
	sun.directional_shadow_max_distance = 85.0      # shmax
	sun.rotation = Vector3(deg_to_rad(-14.0), deg_to_rad(-28.0), 0.0)   # sunel / sunaz
	vp.add_child(sun)


func _measure(cam: Camera3D) -> Dictionary:
	var out := {}
	if fort_node != null:
		out["fort_box"] = _box(cam, fort_node)
	# 路径在屏幕上的走向
	var poly: Array = []
	var l: float = PATH_L0
	while l <= PATH_L1 + 0.01:
		var t: float = _path_t(l)
		var sx: float = t - 2.65625
		var sz: float = l - CAM_L
		var y: float = float(_h(sx, sz)["h"])
		var sp: Vector2 = cam.unproject_position(_stage_point(Vector3(sx, y, sz)))
		poly.append({"l": snappedf(l, 0.1), "x": snappedf(sp.x / float(IMG.x), 0.001),
			"y": snappedf(sp.y / float(IMG.y), 0.001)})
		l += 1.0
	out["path_screen"] = poly
	if poly.size() >= 2:
		var p0: Dictionary = poly[0]
		var p1: Dictionary = poly[poly.size() - 1]
		var dx: float = float(p1["x"]) - float(p0["x"])
		var dy: float = float(p1["y"]) - float(p0["y"])
		out["path_screen_angle_deg"] = snappedf(rad_to_deg(atan2(dy, dx)), 0.1)
	# 地平线自检：远处一点的屏幕行
	var far_pt: Vector3 = _stage_point(Vector3(-2.65625, 0.0, 800.0 - CAM_L))
	if not cam.is_position_behind(far_pt):
		out["horizon_y_frac"] = snappedf(cam.unproject_position(far_pt).y / float(IMG.y), 0.001)
	# 地表剖面自检：中列各深度的高度与屏幕行。眼高只有 0.2526，
	# 近场地表一旦接近眼高，画面下缘就会"看穿"过去，露出环境 ground_bottom。
	var prof: Array = []
	for lv in [0.7, 0.9, 1.2, 1.6, 2.0, 2.6, 3.4, 4.5, 6.0, 8.0, 11.0, 15.0, 20.0, 30.0, 50.0]:
		var sx2: float = -2.65625
		var sz2: float = lv - CAM_L
		var hh: float = float(_h(sx2, sz2)["h"])
		var wp: Vector3 = _stage_point(Vector3(sx2, hh, sz2))
		var behind: bool = cam.is_position_behind(wp)
		var yy: float = -1.0
		if not behind:
			yy = cam.unproject_position(wp).y / float(IMG.y)
		prof.append({"L": lv, "h_u": snappedf(hh, 0.004), "above_eye": hh > EYE,
			"screen_y": snappedf(yy, 0.001), "behind": behind})
	out["ground_profile"] = prof
	out["half_w_check"] = {"L3": snappedf(_half_w(3.0), 0.01), "L10": snappedf(_half_w(10.0), 0.01),
		"L21": snappedf(_half_w(21.0), 0.01)}
	# 石头按层的屏幕高占比
	var per_tier := {}
	for r in rocks:
		var c: Vector2 = r["xz"]
		var y2: float = float(_h(c.x, c.y)["h"])
		var b: Vector3 = _stage_point(Vector3(c.x, y2, c.y))
		var tp: Vector3 = _stage_point(Vector3(c.x, y2 + float(r["h"]), c.y))
		if cam.is_position_behind(b) or cam.is_position_behind(tp):
			continue
		var hf: float = absf(cam.unproject_position(b).y - cam.unproject_position(tp).y) / float(IMG.y)
		var k: String = String(r["tier"])
		if not per_tier.has(k):
			per_tier[k] = []
		per_tier[k].append(snappedf(hf, 0.001))
	var summary := {}
	for k in per_tier:
		var arr: Array = per_tier[k]
		arr.sort()
		summary[k] = {"n": arr.size(), "min_h_frac": arr[0], "max_h_frac": arr[arr.size() - 1],
			"median_h_frac": arr[arr.size() / 2]}
	out["rock_screen_by_tier"] = summary
	return out


func _box(cam: Camera3D, n: MeshInstance3D) -> Dictionary:
	if n.mesh == null:
		return {}
	var ab: AABB = n.global_transform * n.mesh.get_aabb()
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for k in 8:
		var c: Vector3 = ab.get_endpoint(k)
		if cam.is_position_behind(c):
			continue
		var sp: Vector2 = cam.unproject_position(c)
		lo.x = minf(lo.x, sp.x); lo.y = minf(lo.y, sp.y)
		hi.x = maxf(hi.x, sp.x); hi.y = maxf(hi.y, sp.y)
	return {"left": snappedf(lo.x / float(IMG.x), 0.001), "right": snappedf(hi.x / float(IMG.x), 0.001),
		"top": snappedf(lo.y / float(IMG.y), 0.001), "bottom": snappedf(hi.y / float(IMG.y), 0.001),
		"w_frac": snappedf((hi.x - lo.x) / float(IMG.x), 0.001),
		"h_frac": snappedf((hi.y - lo.y) / float(IMG.y), 0.001)}
