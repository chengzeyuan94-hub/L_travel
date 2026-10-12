extends Control
## D city badge. The complete badge/body/state reserve belongs to size; leaders are visual.
const INK := Color("3e2a1e")
const EDGE := Color("71543b")
const CREAM := Color("fff4dc")
const GOLD := Color("c58b32")
const LAND_FILL := Color("f3d9a4")
const SEA_FILL := Color("d3eaee")
const LAND_INK := Color("7a4e25")
const SEA_INK := Color("2f6f86")
var display_icon := "AUTO"
var custom_texture: Texture2D
var unit := 1.0
var arrow_side := "bottom"
var anchor_local := Vector2.ZERO
var show_leader := false
var transport_mode := "LAND"
var main_icon_mode := "LAND"
var drag_hover := false
var highlighted := false
var selected := false
var _body_height := 26.0
var _badge := Rect2()
var _text_body := Rect2()
var _text := Rect2()
var _icon_rects: Array[Rect2] = []
var _label: Label

func _init() -> void:
	name = "CityPlaque"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.name = "Name"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	add_child(_label)
	resized.connect(_refresh_rects)

## The fixed slot is identical for LAND/SEA/BOTH. Small canvases reserve enough for 8px subicons.
static func measured_size(text_width: float, font_px: int, u: float) -> Vector2:
	var body_height := maxf(26.0*u, float(font_px)+11.0*u)
	var badge_height := maxf(body_height+6.0*u, 26.0)
	return Vector2(text_width+0.87*badge_height+20.0*u, badge_height+4.0*u)

func set_highlight(on: bool, persistent := false) -> void:
	if highlighted == on and selected == persistent: return
	highlighted = on
	selected = persistent
	queue_redraw()

func configure(text: String, font_px: int, visual_unit: float, mode: String, icon := "AUTO", texture: Texture2D = null) -> void:
	unit = visual_unit
	display_icon = icon
	custom_texture = texture
	transport_mode = mode
	main_icon_mode = mode if icon == "AUTO" else icon
	_body_height = maxf(26.0*unit, float(font_px)+11.0*unit)
	_label.text = text
	_label.add_theme_font_size_override("font_size", font_px)
	_label.add_theme_color_override("font_color", INK)
	_label.add_theme_constant_override("outline_size", 0)
	_refresh_rects()

func _refresh_rects() -> void:
	var reserve := 2.0*unit
	var bh := maxf(_body_height+6.0*unit, 26.0)
	_badge = Rect2(Vector2(reserve,reserve),Vector2(0.87*bh,bh))
	_text_body = Rect2(Vector2(_badge.get_center().x,(size.y-_body_height)*0.5),Vector2(maxf(0.0,size.x-reserve-_badge.get_center().x),_body_height))
	_text = Rect2(Vector2(_badge.end.x+4.0*unit,_text_body.position.y),Vector2(maxf(0.0,size.x-reserve-12.0*unit-(_badge.end.x+4.0*unit)),_body_height))
	_label.position = _text.position
	_label.size = _text.size
	_icon_rects.clear()
	if main_icon_mode == "BOTH":
		var icon_size := Vector2(maxf(8.0,_badge.size.x*0.46),maxf(8.0,bh*0.31))
		_icon_rects.append(Rect2(_badge.position+Vector2(_badge.size.x*0.12,bh*0.22),icon_size))
		_icon_rects.append(Rect2(_badge.position+Vector2(_badge.size.x*0.42,bh*0.48),icon_size))
	else:
		var icon_size := Vector2(maxf(10.0,_badge.size.x*0.68),maxf(10.0,bh*0.52))
		_icon_rects.append(Rect2(_badge.get_center()-icon_size*0.5,icon_size))
	queue_redraw()

## Local coordinates, for the same city selection surface; these exclude the pointer/leader.
func get_badge_rect() -> Rect2: return _badge
func get_text_body_rect() -> Rect2: return _text_body
func get_text_rect() -> Rect2: return _text
func get_icon_rects() -> Array[Rect2]: return _icon_rects.duplicate()

func point_to(local_anchor: Vector2, side: String, leader: bool) -> void:
	anchor_local = local_anchor
	arrow_side = side
	show_leader = leader
	queue_redraw()

func _hex(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([Vector2(r.get_center().x,r.position.y),r.position+Vector2(r.size.x,r.size.y*0.25),r.position+Vector2(r.size.x,r.size.y*0.75),Vector2(r.get_center().x,r.end.y),r.position+Vector2(0,r.size.y*0.75),r.position+Vector2(0,r.size.y*0.25)])

func _plank(r: Rect2) -> PackedVector2Array:
	var cut := 3.0*unit
	return PackedVector2Array([r.position,Vector2(r.end.x-cut,r.position.y),Vector2(r.end.x,r.position.y+cut),Vector2(r.end.x,r.end.y-cut),Vector2(r.end.x-cut,r.end.y),Vector2(r.position.x,r.end.y)])

func _outline(points: PackedVector2Array, color: Color, width: float) -> void:
	var closed := points.duplicate(); closed.append(points[0])
	draw_polyline(closed,color,width,true)

func _icon_polygon(r: Rect2, points: Array, color: Color) -> void:
	var p := PackedVector2Array()
	for point: Vector2 in points: p.append(r.position+point*r.size)
	draw_colored_polygon(p,color)

func _camel(r: Rect2) -> void:
	# Single hump, raised neck and head, two broad legs: a silhouette at the small slot size.
	_icon_polygon(r,[Vector2(0,0.38),Vector2(0.10,0.48),Vector2(0.22,0.40),Vector2(0.37,0.18),Vector2(0.52,0.40),Vector2(0.65,0.42),Vector2(0.74,0.04),Vector2(0.88,0),Vector2(1,0.10),Vector2(0.99,0.25),Vector2(0.87,0.25),Vector2(0.85,0.63),Vector2(0.70,0.72),Vector2(0.18,0.72),Vector2(0.04,0.60)],LAND_INK)
	_icon_polygon(r,[Vector2(0.22,0.64),Vector2(0.39,0.64),Vector2(0.33,1),Vector2(0.17,1)],LAND_INK)
	_icon_polygon(r,[Vector2(0.65,0.65),Vector2(0.82,0.61),Vector2(0.87,1),Vector2(0.71,1)],LAND_INK)

func _ship(r: Rect2) -> void:
	_icon_polygon(r,[Vector2(0,0.70),Vector2(1,0.70),Vector2(0.80,1),Vector2(0.19,1)],SEA_INK)
	_icon_polygon(r,[Vector2(0.48,0),Vector2(0.48,0.63),Vector2(0.03,0.63)],SEA_INK)
	_icon_polygon(r,[Vector2(0.57,0.15),Vector2(0.92,0.63),Vector2(0.57,0.63)],SEA_INK)

func _draw_pointer() -> void:
	var base := Vector2.ZERO
	var tip := Vector2.ZERO
	var points := PackedVector2Array()
	var half := 4.5*unit
	var depth := 5.0*unit
	# Attach beneath the actual contour, instead of the outer state-reserve rectangle.
	var tuck := 0.4*unit
	var body_min_x := _badge.end.x+half
	var body_max_x := maxf(body_min_x,_text_body.end.x-3.0*unit-half)
	match arrow_side:
		"bottom":
			base = Vector2(clampf(anchor_local.x,body_min_x,body_max_x),_text_body.position.y+tuck)
			tip = base-Vector2(0,depth)
			points = PackedVector2Array([base-Vector2(half,0),tip,base+Vector2(half,0)])
		"top":
			base = Vector2(clampf(anchor_local.x,body_min_x,body_max_x),_text_body.end.y-tuck)
			tip = base+Vector2(0,depth)
			points = PackedVector2Array([base+Vector2(half,0),tip,base-Vector2(half,0)])
		"right":
			base = Vector2(_badge.position.x+tuck,clampf(anchor_local.y,_badge.position.y+_badge.size.y*0.25+half,_badge.end.y-_badge.size.y*0.25-half))
			tip = base-Vector2(depth,0)
			points = PackedVector2Array([base+Vector2(0,half),tip,base-Vector2(0,half)])
		_:
			base = Vector2(_text_body.end.x-tuck,clampf(anchor_local.y,_text_body.position.y+3.0*unit+half,_text_body.end.y-3.0*unit-half))
			tip = base+Vector2(depth,0)
			points = PackedVector2Array([base-Vector2(0,half),tip,base+Vector2(0,half)])
	if show_leader:
		draw_line(tip,anchor_local,Color(EDGE,0.85),maxf(1.0,1.3*unit),true)
		draw_circle(anchor_local,2.0*unit,Color("418396") if transport_mode == "SEA" else Color("587257"))
	# Pointer/leader keep their neutral wood appearance; state effects stay inside size.
	draw_colored_polygon(points,CREAM)
	draw_polyline(points,EDGE,maxf(1.0,1.4*unit),true)

func _draw() -> void:
	if size.x <= 0.0 or _badge.size.y <= 0.0: return
	_draw_pointer()
	var edge := GOLD if highlighted or selected else EDGE
	var width := (2.0 if highlighted or selected else 1.5)*unit
	var fill := Color("ffe9b8") if selected else (Color("fffbef") if highlighted else CREAM)
	var shadow := Color(0.17,0.10,0.05,0.20)
	draw_colored_polygon(_plank(Rect2(_text_body.position+Vector2(0,1.3*unit),_text_body.size)),shadow)
	draw_colored_polygon(_hex(Rect2(_badge.position+Vector2(0,1.3*unit),_badge.size)),shadow)
	var plank := _plank(_text_body)
	draw_colored_polygon(plank,fill)
	_outline(plank,edge,width)
	draw_line(Vector2(_badge.end.x,_text_body.end.y-2.5*unit),Vector2(_text_body.end.x-4.0*unit,_text_body.end.y-2.5*unit),Color("dfc69b"),1.5*unit,true)
	draw_line(Vector2(_badge.end.x,_text_body.position.y+2.5*unit),Vector2(_text_body.end.x-4.0*unit,_text_body.position.y+2.5*unit),Color("fffdf1"),unit,true)
	var hex := _hex(_badge)
	if selected: _outline(_hex(_badge.grow(unit)),GOLD,unit)
	draw_colored_polygon(hex,SEA_FILL if main_icon_mode == "SEA" else (LAND_FILL if main_icon_mode != "UNKNOWN" else CREAM))
	if main_icon_mode == "BOTH":
		# Opposite hex vertices make an exact diagonal split, with no icon-dependent geometry.
		draw_colored_polygon(PackedVector2Array([hex[1],hex[2],hex[3],hex[4]]),SEA_FILL)
		draw_line(hex[4],hex[1],CREAM,unit,true)
	_outline(hex,Color(INK,0.60),width+unit)
	_outline(hex,edge,width)
	if display_icon == "IMAGE" and custom_texture != null:
		var r := _badge.grow(-4.0*unit)
		var factor := minf(r.size.x / custom_texture.get_width(), r.size.y / custom_texture.get_height())
		var sz := Vector2(custom_texture.get_size()) * factor
		draw_texture_rect(custom_texture, Rect2(r.get_center()-sz*0.5, sz), false)
	elif display_icon == "STAR":
		var star := PackedVector2Array()
		for i in 10:
			var angle := -PI*0.5 + PI*float(i)/5.0
			star.append(_badge.get_center()+Vector2(cos(angle),sin(angle))*_badge.size.x*(0.37 if i%2==0 else 0.17))
		draw_colored_polygon(star, LAND_INK)
	elif main_icon_mode == "BOTH":
		_camel(_icon_rects[0]); _ship(_icon_rects[1])
	elif main_icon_mode == "LAND": _camel(_icon_rects[0])
	elif main_icon_mode == "SEA": _ship(_icon_rects[0])
	if display_icon != "AUTO": _draw_transport_corner()
	if drag_hover:
		for x in range(0, int(size.x), 8): draw_line(Vector2(x,0),Vector2(minf(x+4,size.x),0),GOLD,1.5,true)
		for x in range(0, int(size.x), 8): draw_line(Vector2(x,size.y),Vector2(minf(x+4,size.x),size.y),GOLD,1.5,true)
		for y in range(0, int(size.y), 8):
			draw_line(Vector2(0,y),Vector2(0,minf(y+4,size.y)),GOLD,1.5,true)
			draw_line(Vector2(size.x,y),Vector2(size.x,minf(y+4,size.y)),GOLD,1.5,true)

func _draw_transport_corner() -> void:
	var side := maxf(11.0, 14.0*unit)
	var r := Rect2(Vector2(0, maxf(0.0,size.y-side)), Vector2(side*(1.7 if transport_mode=="BOTH" else 1.0),side))
	draw_style_box(_traffic_box(),r)
	var icon := r.grow(-2.0*unit)
	if transport_mode == "BOTH":
		icon.size.x *= 0.5; _camel(icon); icon.position.x += icon.size.x; _ship(icon)
	elif transport_mode == "SEA": _ship(icon)
	elif transport_mode == "LAND": _camel(icon)

func _traffic_box() -> StyleBoxFlat:
	var box := StyleBoxFlat.new(); box.bg_color=CREAM; box.border_color=EDGE
	box.set_border_width_all(1); box.set_corner_radius_all(3)
	return box
