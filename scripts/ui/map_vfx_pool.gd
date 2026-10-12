extends Node2D
class_name MapVfxPool

## 地图世界坐标特效固定对象池：船尾涟漪 / 骆驼脚下扬尘。
## 特效在世界坐标生成后原地扩散淡出，绝不跟随棋子移动（“stay put”）。
## 池大小固定，循环复用节点，不动态增删 -> 节点数长期稳定。

const RIPPLE_POOL_SIZE := 8
const DUST_POOL_SIZE := 8
const RIPPLE_LIFETIME := 0.85
const DUST_LIFETIME := 0.5

var _ripples: Array[Sprite2D] = []
var _dusts: Array[Sprite2D] = []
var _ripple_tweens: Array = []
var _dust_tweens: Array = []
var _ripple_cursor := 0
var _dust_cursor := 0


func _ready() -> void:
	var ripple_tex: Texture2D = load("res://assets/title_dynamic/title_water_ripple_v1.png")
	var dust_tex: Texture2D = load("res://assets/title_dynamic/title_smoke_puff_v1.png")
	for i in RIPPLE_POOL_SIZE:
		var s := Sprite2D.new()
		s.name = "Ripple%d" % i
		s.texture = ripple_tex
		s.centered = true
		s.visible = false
		# VfxLayer 本身已位于城市之上、棋子之下；子节点不能再用 -1，
		# 否则会被整张地图背景遮住，表现为“代码生成了但完全看不见”。
		s.z_index = 0
		s.modulate = Color(1, 1, 1, 0)
		add_child(s)
		_ripples.append(s)
		_ripple_tweens.append(null)
	for i in DUST_POOL_SIZE:
		var s := Sprite2D.new()
		s.name = "Dust%d" % i
		s.texture = dust_tex
		s.centered = true
		s.visible = false
		s.z_index = 0
		s.modulate = Color(1, 1, 1, 0)
		add_child(s)
		_dusts.append(s)
		_dust_tweens.append(null)


func ripple_pool_size() -> int:
	return _ripples.size()


func dust_pool_size() -> int:
	return _dusts.size()


func total_node_count() -> int:
	return _ripples.size() + _dusts.size()


## 船尾涟漪：世界坐标定点生成，扩散+淡出，绝不跟随棋子。
func spawn_ripple(world_pos: Vector2, rotation_rad: float = 0.0) -> void:
	if _ripples.is_empty():
		return
	var idx := _ripple_cursor
	_ripple_cursor = (_ripple_cursor + 1) % _ripples.size()
	var s: Sprite2D = _ripples[idx]
	var tw = _ripple_tweens[idx]
	if tw != null and tw.is_valid():
		tw.kill()
	s.position = world_pos
	s.rotation = rotation_rad
	s.scale = Vector2(0.020, 0.028)
	s.modulate = Color(0.88, 0.98, 1.0, 0.55)
	s.visible = true
	var tween := create_tween()
	tween.tween_property(s, "scale", Vector2(0.050, 0.060), RIPPLE_LIFETIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(s, "modulate:a", 0.0, RIPPLE_LIFETIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_callback(func() -> void: s.visible = false)
	_ripple_tweens[idx] = tween


## 骆驼脚下扬尘：世界坐标定点生成，轻微扩散+淡出。尺寸/透明度较低，不遮挡路线与节点。
func spawn_dust(world_pos: Vector2) -> void:
	if _dusts.is_empty():
		return
	var idx := _dust_cursor
	_dust_cursor = (_dust_cursor + 1) % _dusts.size()
	var s: Sprite2D = _dusts[idx]
	var tw = _dust_tweens[idx]
	if tw != null and tw.is_valid():
		tw.kill()
	s.position = world_pos
	s.scale = Vector2(0.030, 0.008)
	s.modulate = Color(0.88, 0.78, 0.58, 0.46)
	s.visible = true
	var tween := create_tween()
	tween.tween_property(s, "scale", Vector2(0.070, 0.015), DUST_LIFETIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(s, "modulate:a", 0.0, DUST_LIFETIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_callback(func() -> void: s.visible = false)
	_dust_tweens[idx] = tween
