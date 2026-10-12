extends Node3D
## Continuous miniature atlas. All coordinates here are presentation data.
## This builder never modifies GameState, rule coordinates, or the random stream.
const Architecture = preload("res://scripts/world/miniworld_architecture.gd")
const Props = preload("res://scripts/world/miniworld_props.gd")
const LAYOUT_PATH = "res://assets/miniworld/layout.json"
var anchors: Dictionary = {}
var routes: Dictionary = {}
var cities: Dictionary = {}
var layout: Dictionary = {}
var land_polygons: Array[PackedVector2Array] = []
var corridor_curves: Dictionary = {}
var _lights: Array[OmniLight3D] = []
var _glow_materials: Array[StandardMaterial3D] = []
var _water_material: ShaderMaterial
var _rng := RandomNumberGenerator.new()
var _terrain_material: StandardMaterial3D
var _props_root: Node3D
var _route_points: Array[Vector3] = []
var _night := false
const LAND_Y := 0.48
const WATER_Y := 0.03

func build(content: Dictionary) -> void:
	name = "SilkRoadMiniatureAtlas"
	_rng.seed = 20260916
	layout = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT_PATH))
	_terrain_material = _mat(Color.WHITE)
	_terrain_material.vertex_color_use_as_albedo = true
	for polygon in layout.land_polygons:
		var points := PackedVector2Array()
		for point in polygon: points.append(Vector2(point[0],point[1]))
		land_polygons.append(points)
	_make_routes(content)
	_build_water()
	for i in range(land_polygons.size()): _build_land(land_polygons[i], i)
	_build_mountains()
	_build_waterways()
	_build_cities()
	_build_trade_paths()
	_build_life()
	set_night(false)

func surface_height(x: float, z: float) -> float:
	for polygon in land_polygons:
		if Geometry2D.is_point_in_polygon(Vector2(x,z),polygon): return LAND_Y
	return WATER_Y

func _v2(value: Array) -> Vector2:
	return Vector2(float(value[0]),float(value[1]))

func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = .87
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var normal := (b-a).cross(c-a).normalized()
	# Upward fronts are clockwise in Godot; explicit normals keep terrain faceting stable.
	if normal.y < 0:
		var swap := b
		b = c
		c = swap
		normal = -normal
	for p in [a,c,b]:
		st.set_normal(normal)
		st.set_color(color)
		st.add_vertex(p)

func _finish(st: SurfaceTool, title: String, material: Material, parent: Node3D = self) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = title
	mi.mesh = st.commit()
	mi.material_override = material
	parent.add_child(mi)
	return mi

func _make_routes(content: Dictionary) -> void:
	for id in layout.cities:
		var p := _v2(layout.cities[id].anchor)
		anchors[id] = Vector3(p.x, LAND_Y+.075,p.y)
	for c in layout.corridors:
		var curve := Curve3D.new()
		var points: Array[Vector3] = [anchors[c.a]]
		for p in c.bends: points.append(Vector3(p[0],LAND_Y+.06 if c.type == "LAND" else WATER_Y+.075,p[1]))
		points.append(anchors[c.b])
		for i in range(points.size()):
			var tangent := (points[mini(i+1,points.size()-1)]-points[maxi(i-1,0)])*.16
			curve.add_point(points[i],-tangent,tangent)
		curve.bake_interval = .10
		corridor_curves[c.id] = curve
		var length := curve.get_baked_length()
		anchors[c.via[0]] = curve.sample_baked(length/3.0)
		anchors[c.via[1]] = curve.sample_baked(length*2.0/3.0)
		var ids: Array = [c.a,c.via[0],c.via[1],c.b]
		for e in content.get("board_edges",[]):
			if e.get("corridor_id","") != c.id: continue
			var index := int(e.get("corridor_step_index",1))-1
			var segment := PackedVector3Array()
			for j in range(25): segment.append(curve.sample_baked(length*(index+float(j)/24.0)/3.0))
			if str(e.a) != str(ids[index]): segment.reverse()
			routes[str(e.id)] = segment
		for j in range(ceili(length/.2)+1): _route_points.append(curve.sample_baked(minf(length,j*.2)))

func _build_water() -> void:
	var sea_outline := PackedVector2Array([Vector2(-21,-11),Vector2(-17,-12.5),Vector2(16,-12.5),Vector2(21,-9),Vector2(23,1),Vector2(22.5,10.5),Vector2(18.5,13.5),Vector2(-14,13.5),Vector2(-21,10),Vector2(-22,-4)])
	var verts := PackedVector2Array(sea_outline)
	for x in range(-21,23):
		for z in range(-12,14):
			var p := Vector2(x+_rng.randf_range(-.3,.3),z+_rng.randf_range(-.3,.3))
			if Geometry2D.is_point_in_polygon(p,sea_outline): verts.append(p)
	var indices := Geometry2D.triangulate_delaunay(verts)
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(0,indices.size(),3):
		var a:=verts[indices[i]]; var b:=verts[indices[i+1]]; var c:=verts[indices[i+2]]
		if not Geometry2D.is_point_in_polygon((a+b+c)/3.0,sea_outline): continue
		var shade := _rng.randf_range(.93,1.06)
		_tri(st,Vector3(a.x,WATER_Y,a.y),Vector3(b.x,WATER_Y,b.y),Vector3(c.x,WATER_Y,c.y),Color("368f9d")*Color(shade,shade,shade,1))
	_water_material = ShaderMaterial.new()
	_water_material.shader = load("res://scripts/world/miniworld_water.gdshader")
	_finish(st,"FacetedSea",_water_material)
	# A shallow, bevelled cut edge makes the world feel like a crafted atlas.
	_side_band(sea_outline, WATER_Y-.01, -.55, Color("597d86"),"SeaCutEdge")
	var floor_mesh := PlaneMesh.new(); floor_mesh.size = Vector2(200,200)
	var floor_node := MeshInstance3D.new(); floor_node.name="StudioGround"; floor_node.mesh=floor_mesh
	floor_node.position.y=-.61;floor_node.material_override=_mat(Color("d8d4c9")); add_child(floor_node)
	floor_node.set_meta("studio_floor",true)

func _side_band(polygon: PackedVector2Array, top: float, bottom: float, color: Color, title: String) -> void:
	var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(polygon.size()):
		var a:=polygon[i];var b:=polygon[(i+1)%polygon.size()]
		var v:=[Vector3(a.x,top,a.y),Vector3(b.x,top,b.y),Vector3(b.x,bottom,b.y),Vector3(a.x,bottom,a.y)]
		var tint := color*Color(_rng.randf_range(.93,1.05),1,1,1)
		_tri(st,v[0],v[1],v[2],tint);_tri(st,v[0],v[2],v[3],tint)
	_finish(st,title,_terrain_material)

func _land_color(p: Vector2, region: int) -> Color:
	var meadow := clampf((p.x-4.0)/8.0,0,1)
	if region == 0 and p.x < -11: meadow = .78
	if region in [3,4,5]: meadow=.88
	if region == 0 and p.y < -6.5: meadow = maxf(meadow,.5)
	var sand:=Color("dfbc78");var grass:=Color("97af64")
	return sand.lerp(grass,meadow)

func _build_land(poly: PackedVector2Array, region: int) -> void:
	var boundary:=PackedVector2Array()
	for i in range(poly.size()):
		var a:=poly[i];var b:=poly[(i+1)%poly.size()]
		var steps:=maxi(1,ceili(a.distance_to(b)/.85))
		for j in range(steps): boundary.append(a.lerp(b,float(j)/steps))
	var verts:=PackedVector2Array(boundary)
	var min_p:=Vector2.INF;var max_p:=-Vector2.INF
	for p in poly: min_p=min_p.min(p);max_p=max_p.max(p)
	for ix in range(floori(min_p.x),ceili(max_p.x)+1):
		for iz in range(floori(min_p.y),ceili(max_p.y)+1):
			var p:=Vector2(ix,iz)+Vector2(_rng.randf_range(-.32,.32),_rng.randf_range(-.32,.32))
			if Geometry2D.is_point_in_polygon(p,poly) and _boundary_distance(p,boundary)>.38: verts.append(p)
	var indices:=Geometry2D.triangulate_delaunay(verts)
	var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(0,indices.size(),3):
		var a:=verts[indices[i]];var b:=verts[indices[i+1]];var c:=verts[indices[i+2]]
		var center:=(a+b+c)/3.0
		if not Geometry2D.is_point_in_polygon(center,poly):continue
		if not Geometry2D.is_point_in_polygon((a+b)*.5,poly) and _boundary_distance((a+b)*.5,boundary)>.05:continue
		var color:=_land_color(center,region).lightened(_rng.randf_range(-.035,.055))
		_tri(st,Vector3(a.x,LAND_Y,a.y),Vector3(b.x,LAND_Y,b.y),Vector3(c.x,LAND_Y,c.y),color)
	_finish(st,"Land_%02d"%region,_terrain_material)
	# Two sloping shore rings: pale dry stone above bright turquoise shallows.
	var shore:=SurfaceTool.new();shore.begin(Mesh.PRIMITIVE_TRIANGLES)
	var shallow:=SurfaceTool.new();shallow.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(boundary.size()):
		var a:=boundary[i];var b:=boundary[(i+1)%boundary.size()]
		var tangent:=(b-a).normalized();var outward:=Vector2(tangent.y,-tangent.x)
		# Polygon orientations differ; choose the actual outside.
		if Geometry2D.is_point_in_polygon((a+b)*.5+outward*.1,poly):outward=-outward
		var a2:=a+outward*.24;var b2:=b+outward*.24
		_tri(shore,Vector3(a.x,LAND_Y,a.y),Vector3(b.x,LAND_Y,b.y),Vector3(b2.x,.09,b2.y),Color("b2aa85").lightened(_rng.randf_range(-.07,.07)))
		_tri(shore,Vector3(a.x,LAND_Y,a.y),Vector3(b2.x,.09,b2.y),Vector3(a2.x,.09,a2.y),Color("d7c497"))
		var a3:=a+outward*.56;var b3:=b+outward*.56
		_tri(shallow,Vector3(a2.x,.035,a2.y),Vector3(b2.x,.035,b2.y),Vector3(b3.x,.035,b3.y),Color("57b8b3"))
		_tri(shallow,Vector3(a2.x,.035,a2.y),Vector3(b3.x,.035,b3.y),Vector3(a3.x,.035,a3.y),Color("57b8b3"))
	_finish(shore,"SculptedShore_%02d"%region,_terrain_material)
	_finish(shallow,"ClearShallows_%02d"%region,_terrain_material)

func _boundary_distance(p:Vector2, boundary:PackedVector2Array)->float:
	var d:=INF
	for i in range(boundary.size()):d=minf(d,p.distance_to(Geometry2D.get_closest_point_to_segment(p,boundary[i],boundary[(i+1)%boundary.size()])))
	return d

func _build_mountains()->void:
	for rid in range(layout.mountain_ranges.size()):
		var r:Dictionary=layout.mountain_ranges[rid]
		var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var grid:Array=[]
		var columns:=26 if r.snow else 12
		for i in range(columns+1):
			var row:Array[Vector3]=[]
			var t:=float(i)/columns
			var envelope:=pow(sin(PI*t),.6)
			# Irregular sawtooth ridge and asymmetric shoulders, shared footslopes.
			var peaks:=.58+.24*sin(t*PI*7+.4)+.14*sin(t*PI*17)
			for j in range(7):
				var across:=float(j-3)/3.0
				var x:=(t-.5)*float(r.length)+_rng.randf_range(-.2,.2)
				var z:=across*float(r.width)*(.5+.13*sin(t*18))+sin(t*12)*.2
				var y:=LAND_Y+float(r.height)*envelope*peaks*pow(maxf(0,1-absf(across)),1.35)
				if j in [0,6]:y=LAND_Y+.01
				var rot:=Vector2(x,z).rotated(float(r.yaw))
				row.append(Vector3(rot.x+r.center[0],y,rot.y+r.center[1]))
			grid.append(row)
		for i in range(columns):
			for j in range(6):
				for triangle in [[grid[i][j],grid[i+1][j],grid[i][j+1]],[grid[i][j+1],grid[i+1][j],grid[i+1][j+1]]]:
					var y:float=(triangle[0].y+triangle[1].y+triangle[2].y)/3
					var snow:bool=r.snow and y>1.95+.35*sin(i*2.1+j)
					var col:=Color("e5edf0") if snow else (Color("838f95") if r.snow else Color("be8c58"))
					_tri(st,triangle[0],triangle[1],triangle[2],col.lightened(_rng.randf_range(-.10,.1)))
		_finish(st,"ConnectedRidge_%d"%rid,_terrain_material)

func _ribbon(points:PackedVector3Array,width:float,color:Color,title:String)->void:
	var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(points.size()-1):
		var a:=points[i];var b:=points[i+1]
		var right:=Vector3(-(b.z-a.z),0,b.x-a.x).normalized()*width*.5
		_tri(st,a-right,b-right,a+right,color);_tri(st,a+right,b-right,b+right,color)
	_finish(st,title,_terrain_material)

func _build_waterways()->void:
	for river in layout.rivers:
		var points:=PackedVector3Array()
		for p in river:points.append(Vector3(p[0],LAND_Y+.015,p[1]))
		_ribbon(points,.78,Color("d1cc9b"),"RiverBank")
		for i in range(points.size()):points[i].y+=.008
		_ribbon(points,.52,Color("429eab"),"River")
	for oasis in layout.oases:
		var center:=Vector3(oasis[0],LAND_Y+.018,oasis[1]);var radius:float=oasis[2]
		var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for j in range(18):
			var a:=j*TAU/18;var b:=(j+1)*TAU/18
			_tri(st,center,center+Vector3(cos(a)*radius,0,sin(a)*radius*.68),center+Vector3(cos(b)*radius,0,sin(b)*radius*.68),Color("43aeb4").lightened(.04*sin(j*7)))
		_finish(st,"TurquoiseOasis",_terrain_material)

func _build_cities()->void:
	for id in layout.cities:
		var c:Dictionary=layout.cities[id]
		var city:Node3D=Architecture.build(id,c.style,absi(hash(id)))
		city.name="City_"+id
		city.position=Vector3(c.anchor[0],LAND_Y,c.anchor[1]-1.12*float(c.scale))
		city.scale=Vector3.ONE*float(c.scale)
		add_child(city)
		cities[id]={"root":city,"bounds":AABB(Vector3(-1.65,0,-1.45),Vector3(3.3,3.7,2.9)),"anchor":anchors[id]}
		_batch_subtree(city)
		var light:=OmniLight3D.new();light.name="WarmRestStop_"+id
		light.position=Vector3(c.anchor[0],1.3,c.anchor[1]-.1)
		light.light_color=Color("ffc575");light.omni_range=3.9;light.omni_attenuation=1.5;light.light_energy=.85
		add_child(light);_lights.append(light)

func _build_trade_paths()->void:
	var stones:=SurfaceTool.new();stones.begin(Mesh.PRIMITIVE_TRIANGLES)
	for c in layout.corridors:
		var curve:Curve3D=corridor_curves[c.id]
		var length:=curve.get_baked_length()
		if c.type=="LAND":
			var pts:=curve.get_baked_points()
			for i in range(pts.size()):pts[i].y=LAND_Y+.012
			_ribbon(pts,.23,Color("e9ce92"),"DustRoad_"+c.id)
		var step:=.26 if c.type=="LAND" else .42
		var distance:=.1
		while distance<length:
			var p:=curve.sample_baked(distance)
			var radius:=.045 if c.type=="LAND" else .037
			p.y+=.008
			for j in range(6):
				var a:=j*TAU/6;var b:=(j+1)*TAU/6
				_tri(stones,p,p+Vector3(cos(a)*radius,0,sin(a)*radius),p+Vector3(cos(b)*radius,0,sin(b)*radius),Color("f4e3bc") if c.type=="LAND" else Color("8bd4ce"))
			distance+=step
	_finish(stones,"WayfindingPebbles",_terrain_material)

func _near_activity(p:Vector2,margin:float=0.8)->bool:
	for id in layout.cities:
		var c:Dictionary=layout.cities[id]
		var center:=_v2(c.anchor)-Vector2(0,1.12*float(c.scale))
		if p.distance_to(center)<1.6*float(c.scale)+margin:return true
	for route_point in _route_points:
		if p.distance_squared_to(Vector2(route_point.x,route_point.z))<margin*margin:return true
	for river in layout.rivers:
		for i in range(river.size()-1):
			if p.distance_to(Geometry2D.get_closest_point_to_segment(p,_v2(river[i]),_v2(river[i+1])))<.7:return true
	return false

func _build_life()->void:
	_props_root=Node3D.new();_props_root.name="TravelAndGardens";add_child(_props_root)
	# Small groves frame settlements and the mountain feet; the desert keeps its silence.
	var groves=[[-17,-6,5,"broadleaf"],[-13,-5,5,"conifer"],[-9,-7,5,"conifer"],[-5,-6,4,"conifer"],[-1,-5.2,4,"conifer"],[3,-6,5,"conifer"],[7,-7.5,5,"conifer"],[12,-5,6,"conifer"],[15,-6,6,"conifer"],[17,-1,3,"blossom"],[12,1.7,4,"broadleaf"],[14.7,2.2,4,"blossom"],[7.5,2.5,5,"broadleaf"],[3,4.5,4,"palm"],[-7,3,4,"palm"],[-16,1.3,3,"palm"],[-9,8,3,"palm"],[5,7,3,"palm"],[10,8.4,3,"palm"],[19,2.3,4,"blossom"]]
	for g in groves:
		for i in range(g[2]):
			var p:=Vector2(g[0],g[1])+Vector2(_rng.randf_range(-1.0,1.0),_rng.randf_range(-.8,.8))
			if surface_height(p.x,p.y)<.4 or _near_activity(p,.27):continue
			_place(Props.tree(g[3],_rng.randi()),Vector3(p.x,LAND_Y,p.y),_rng.randf_range(.65,1.05),_rng.randf()*TAU)
	for oasis in layout.oases:
		for i in range(4):
			var angle:=i*TAU/4+.3;var p:=Vector3(oasis[0]+cos(angle)*float(oasis[2])*1.32,LAND_Y,oasis[1]+sin(angle)*float(oasis[2])*.94)
			_place(Props.tree("palm",i),p,.75+.1*i,i)
	# Trade stories use the actual road and quay positions.
	for id in ["baghdad","panti","changan","jeddah","quanzhou"]:
		var c:Dictionary=layout.cities[id]
		_place(Props.market(absi(hash(id))),Vector3(c.anchor[0]+1.65,LAND_Y,c.anchor[1]-.35),.6,0)
	for i in range(3):
		var curve:Curve3D=corridor_curves.land_baghdad_panti
		var at:=curve.sample_baked(curve.get_baked_length()*.38+i*.65)
		at.z-=.45;at.y=LAND_Y
		_place(Props.camel(i),at,.7,-PI*.5)
	for id in ["rome","cairo","jeddah","aden","simhala","dagon","chenla","quanzhou","heijokyo"]:
		var at:Vector3=anchors[id]
		_place(Props.dock(1.4),Vector3(at.x+.7,.15,at.z+.8),.75,0)
	for b in [[-18.7,3.8,false],[-12,7.5,false],[-4,10.3,false],[3.5,10.5,false],[15.3,7.7,true],[20,7,true]]:
		_place(Props.boat(b[2]),Vector3(b[0],WATER_Y+.02,b[1]),.85,-.6)
	for bridge in layout.bridges:_place(Props.bridge(1.5),Vector3(bridge[0],LAND_Y+.025,bridge[1]),1,bridge[2])
	# Shore rocks and low scrub, in intentional groups rather than uniform fill.
	for i in range(95):
		var p:=Vector2(_rng.randf_range(-19,20),_rng.randf_range(-8,11))
		if surface_height(p.x,p.y)<.4 or _near_activity(p,.55):continue
		if p.y < -5: continue
		if _rng.randf()<.6:_place(Props.tree("bush",i),Vector3(p.x,LAND_Y,p.y),_rng.randf_range(.35,.6),i)
	_batch_subtree(_props_root)

func _place(node:Node3D,at:Vector3,scale_value:float,yaw:float)->void:
	node.position=at;node.scale=Vector3.ONE*scale_value;node.rotation.y=yaw;_props_root.add_child(node)

func _batch_subtree(root:Node3D)->void:
	var solids:=SurfaceTool.new();solids.begin(Mesh.PRIMITIVE_TRIANGLES)
	var glow:=SurfaceTool.new();glow.begin(Mesh.PRIMITIVE_TRIANGLES)
	var counts:=[0,0]
	_collect_meshes(root,Transform3D.IDENTITY,solids,glow,counts)
	for child in root.get_children():child.queue_free()
	if counts[0]>0:_finish(solids,"EditableSourceBaked_Matte",_terrain_material,root)
	if counts[1]>0:
		var mat:=_mat(Color.WHITE);mat.vertex_color_use_as_albedo=true;mat.emission_enabled=true;mat.emission=Color("ffd08a");mat.emission_energy_multiplier=0
		_glow_materials.append(mat);_finish(glow,"LanternWindows",mat,root)

func _collect_meshes(node:Node3D,tx:Transform3D,solids:SurfaceTool,glow:SurfaceTool,counts:Array)->void:
	if node is MeshInstance3D and node.mesh:
		var mesh:Mesh=node.mesh
		for surface in range(mesh.get_surface_count()):
			var arrays:=mesh.surface_get_arrays(surface)
			if arrays.is_empty():continue
			var material:Material=node.material_override if node.material_override else node.get_active_material(surface)
			var tint:=Color.WHITE;var emit:=false
			if material is StandardMaterial3D:
				tint=material.albedo_color
				emit=material.emission_enabled or "glow" in material.resource_name.to_lower() or "window" in material.resource_name.to_lower()
			var st:SurfaceTool=glow if emit else solids
			var verts:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var normals:PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
			var indices:PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
			var colors:PackedColorArray=arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR]!=null else PackedColorArray()
			var n:=indices.size() if not indices.is_empty() else verts.size()
			for j in range(n):
				var idx:=indices[j] if not indices.is_empty() else j
				st.set_normal((tx.basis.inverse().transposed()*normals[idx]).normalized() if idx<normals.size() else Vector3.UP)
				st.set_color(tint*(colors[idx] if idx<colors.size() else Color.WHITE))
				st.add_vertex(tx*verts[idx])
			counts[1 if emit else 0]+=n
	for child in node.get_children():
		if child is Node3D:_collect_meshes(child,tx*child.transform,solids,glow,counts)

func set_night(value:bool)->void:
	_night=value
	for light in _lights:light.visible=value
	for mat in _glow_materials:mat.emission_energy_multiplier=1.1 if value else 0.0
	if _water_material:_water_material.set_shader_parameter("night",1.0 if value else 0.0)
	var floor_node:=get_node_or_null("StudioGround")
	if floor_node:floor_node.material_override.albedo_color=Color("15253e") if value else Color("d8d4c9")
