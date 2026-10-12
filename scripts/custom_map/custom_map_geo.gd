class_name CustomMapGeo
extends RefCounted

## 棋盘地面采样：高度（烘焙的高度图 assets/custom_map/terrain/board_height.res）、陆海（复用 paths.gd:118-146 的采样方式）
## （docs/design/map-editor-20260930/DESIGN.md 3.10.4、3.11）。实例类。归 WP3。
## 硬规则（3.6）：不许 preload 或 const load 被安卓排除的素材，高度图一律在运行时 load()（第一次用到时）。
##
## 高度：1024×477 格、每格 0.125 u，格心上是那一格最高的地面（tools/custom_map/bake_height.gd）；格心之间双线性插值。
## 海上没有地形网格，那些格按海床 -0.4 算：高度只对陆上有意义。
## 陆海：直接用运行时 Paths 的 water_clearance（同一张 sea_dist.png、同一段采样代码），不另写一套近似。
## 为了让可达区（0.25 u 网格上的搜索）不在每一格都去读图，clearance_grid() 把 water_clearance 在格心上预先采一遍，全进程共用。

const HEIGHT_RES := "res://assets/custom_map/terrain/board_height.res"
const Paths := preload("res://tools/merchant_board_claude_paths.gd")

const CELL := 0.125
const W := 1024
const H := 477
## 陆路的点比地面高这么多（原版 10 条陆路 4118 个点：y − H 的中位数 0.090，p95 误差 0.0022；build_board.py:2306）
const LAND_LIFT := 0.09
## 海路、海上停靠点的高（原布局的常数）
const SEA_Y := 0.04
## 陆上停靠点：硬币半径 0.7 u 以内最高的地面 + 0.06（原版 20 个陆上停靠点复原误差 p95 0.031，build_board.py:2322）
const STOP_LIFT := 0.06
const STOP_R := 0.7
## 城的 y：城心 0.2·foot 半径内 25 个点（圆心 + 8 + 16）高度的第 60 百分位
## （原版 16 城与原 y 之差：最大 0.036；3.10.3 第 3 步要求 p95 ≤ 0.05，按它把采样半径从整个占地缩到城心这一圈）
const CITY_Y_RADIUS := 0.2
const CITY_Y_PERCENTILE := 0.6
## 占地椭圆（与烘焙时补陆地的椭圆同形，build_board.py:214）
const FOOT_RX := 0.45
const FOOT_RZ := 0.38
## 坡度只看城心这一圈（原版 16 城在 0.3·foot 半径内的高差最大 0.126；整个占地椭圆会伸到海边悬崖上，罗马 0.85）
const SLOPE_RADIUS := 0.3
## 可达区网格
const GRID_CELL := 0.25

static var _overlay_cache := {}
static var _shared: CustomMapGeo
static var _height_img: Image
static var _heights := PackedFloat32Array()
static var _clearance := PackedFloat32Array()   # GRID_CELL 格心上的 water_clearance（陆上 -1）
static var _clear_w := 0
static var _clear_h := 0

var board := Rect2(0.0, 0.0, 128.0, 59.63125)
var _landscape := {}
var _landscape_index := {}
var _landscape_key := 0
var _sampler: Object       # 只用来采陆海的 Paths（不 build）


## 全进程共用一个（高度图、sea_dist 只读一次）
static func shared() -> CustomMapGeo:
	if _shared == null:
		_shared = CustomMapGeo.new()
	return _shared


## 地形叠加只放在独立采样器里，绝不改变 shared 原图。
static func for_overlay(doc: Dictionary) -> CustomMapGeo:
	var layer: Variant = doc.get("landscape", {})
	if not layer is Dictionary or layer.is_empty() or CustomMapLandscape.error(layer) != "" or layer.edits.is_empty():
		return shared()
	var key := JSON.stringify(layer)
	if _overlay_cache.has(key):
		return _overlay_cache[key]
	var geo := CustomMapGeo.new(shared().board, shared()._sampler)
	geo._landscape = layer.duplicate(true)
	geo._landscape_index = CustomMapLandscape.build_index(geo._landscape)
	geo._landscape_key = key.hash()
	if geo._landscape_key == 0:
		geo._landscape_key = 1
	if _overlay_cache.size() >= 16:
		_overlay_cache.clear()
	_overlay_cache[key] = geo
	return geo

static func for_layout(layout: Dictionary) -> CustomMapGeo:
	return for_overlay(layout)

func cache_key() -> int:
	return _landscape_key

func has_height_edits() -> bool:
	return not _landscape_index.is_empty()

func has_height_edit(x: float, z: float) -> bool:
	return not _landscape_index.is_empty() and CustomMapLandscape.affects_height(x, z, _landscape_index)

func edited_height(original: float, x: float, z: float) -> float:
	return CustomMapLandscape.height_at(original, x, z, _landscape_index)

func _init(board_rect := Rect2(0.0, 0.0, 128.0, 59.63125), source_sampler: Object = null) -> void:
	board = board_rect
	_sampler = source_sampler
	if _sampler == null:
		_sampler = Paths.new()
		_sampler.set("_board", board)
		_sampler.call("_load_sampler")
	_load_heights()


static func _load_heights() -> void:
	if not _heights.is_empty():
		return
	var img: Image = load(HEIGHT_RES) as Image if ResourceLoader.exists(HEIGHT_RES) else null
	if img == null or img.get_width() != W or img.get_height() != H:
		push_error("CustomMapGeo: 读不到高度图 %s" % HEIGHT_RES)
		_heights.resize(W * H)
		_heights.fill(0.95)
		return
	_height_img = img
	_heights = img.get_data().to_float32_array()


## 地面高度（世界单位）
func height(x: float, z: float) -> float:
	var raw := base_height(x, z)
	return edited_height(raw, x, z) if has_height_edit(x, z) and is_land(x, z) else raw

func base_height(x: float, z: float) -> float:
	var u := x / CELL - 0.5
	var v := z / CELL - 0.5
	var fu := floorf(u)
	var fv := floorf(v)
	var x0 := clampi(int(fu), 0, W - 1)
	var y0 := clampi(int(fv), 0, H - 1)
	var x1 := mini(x0 + 1, W - 1)
	var y1 := mini(y0 + 1, H - 1)
	var fx := clampf(u - fu, 0.0, 1.0)
	var fy := clampf(v - fv, 0.0, 1.0)
	var h00 := _heights[y0 * W + x0]
	var h10 := _heights[y0 * W + x1]
	var h01 := _heights[y1 * W + x0]
	var h11 := _heights[y1 * W + x1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)


## (x, z) 是不是陆地
func is_land(x: float, z: float) -> bool:
	return water_clearance(x, z) < 0.0


## 离陆地的距离（世界单位）；陆上为 -1（同 paths.gd water_clearance）
func water_clearance(x: float, z: float) -> float:
	return float(_sampler.call("water_clearance", x, z))


## 一个只用来采陆海的 Paths（hull_clearance、_camel_on_land 这些判断直接用它）
func sampler() -> Object:
	return _sampler


## 占地内的统计，给几何规则用：
##   land_frac  占地椭圆（rx = 0.45·foot，rz = 0.38·foot）里 G > 0.5 的采样点比例（G_CITY_LAND）
##   h_centre   城心高度；h_range 城心 0.3·foot 这一圈的高差（G_SLOPE）；y 推导用的城高（第 60 百分位）
func footprint_stats(x: float, z: float, foot: float) -> Dictionary:
	var land := 0
	var total := 0
	for i in 9:
		for j in 9:
			var u := -1.0 + i / 4.0
			var v := -1.0 + j / 4.0
			if u * u + v * v > 1.0:
				continue
			total += 1
			if is_land(x + u * FOOT_RX * foot, z + v * FOOT_RZ * foot):
				land += 1
	var lo := INF
	var hi := -INF
	for i in 9:
		for j in 9:
			var u := -1.0 + i / 4.0
			var v := -1.0 + j / 4.0
			if u * u + v * v > 1.0:
				continue
			var h := height(x + u * SLOPE_RADIUS * foot, z + v * SLOPE_RADIUS * foot)
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return {"land_frac": float(land) / float(maxi(total, 1)), "samples": total, "h_centre": height(x, z),
		"h_min": lo, "h_max": hi, "h_range": hi - lo, "y": city_y(x, z, foot)}


## 城放在 (x, z) 时的 y（3.10.3 第 3 步）
func city_y(x: float, z: float, foot: float) -> float:
	var s := PackedFloat32Array([height(x, z)])
	var r1 := CITY_Y_RADIUS * 0.5 * foot
	var r2 := CITY_Y_RADIUS * foot
	for k in 8:
		s.append(height(x + cos(TAU * k / 8.0) * r1, z + sin(TAU * k / 8.0) * r1))
	for k in 16:
		s.append(height(x + cos(TAU * k / 16.0) * r2, z + sin(TAU * k / 16.0) * r2))
	s.sort()
	return s[int(round(CITY_Y_PERCENTILE * (s.size() - 1)))]


## 路线上一点的 y：陆路 = 地面 + LAND_LIFT（地面低于 0 的按 0 算，同 build_board.py:2306），海路 = SEA_Y
func route_y(x: float, z: float, route_type: String) -> float:
	if route_type == "SEA":
		return SEA_Y
	return maxf(height(x, z), 0.0) + LAND_LIFT


## 停靠点（硬币）的 y
func stop_y(x: float, z: float, route_type: String) -> float:
	if route_type == "SEA":
		return SEA_Y
	var mx := height(x, z)
	for i in 24:
		var a := TAU * i / 24.0
		for rr in [STOP_R * 0.5, STOP_R]:
			mx = maxf(mx, height(x + cos(a) * rr, z + sin(a) * rr))
	return maxf(mx, 0.0) + STOP_LIFT


## GRID_CELL 网格上预采的 water_clearance（全进程共用；第一次约 0.3–0.6 s）
func clearance_grid() -> Dictionary:
	if _clearance.is_empty():
		_clear_w = int(ceil(board.size.x / GRID_CELL))
		_clear_h = int(ceil(board.size.y / GRID_CELL))
		_clearance.resize(_clear_w * _clear_h)
		for j in _clear_h:
			var z := board.position.y + (j + 0.5) * GRID_CELL
			for i in _clear_w:
				_clearance[j * _clear_w + i] = water_clearance(board.position.x + (i + 0.5) * GRID_CELL, z)
	return {"clear": _clearance, "w": _clear_w, "h": _clear_h, "cell": GRID_CELL, "x0": board.position.x, "z0": board.position.y}
