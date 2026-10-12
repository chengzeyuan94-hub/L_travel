extends RefCounted
## Deterministic assembly; source GLBs, anchors and vertices remain unchanged.
const GEO = preload("res://scripts/traveler/atlas_geometry.gd")
var report := {"cities": 0, "terrain_tiles": 0, "trees": 0, "rocks": 0, "grasses": 0, "route_count": 0, "node_count": 0, "source_city_transforms": [], "land_height_method": "Barycentric interpolation on imported terrain triangles"}
var world: Node3D
var materials := {}
var motion_params: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/motion_params.json"))
var height_buckets := {}
var cities: Array
var city_boxes: Array[AABB] = []

func read_json(path: String):
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func branch(label: String, parent: Node = null) -> Node3D:
	var n := Node3D.new()
	n.name = label
	(parent if parent else world).add_child(n)
	return n

func build() -> Node3D:
	world = Node3D.new()
	world.name = "AtlasWorld"
	world.set_meta("source", "Eurasia-Atlas-WebGL.zip")
	world.set_meta("projection", "x=(longitude-76)*0.9; z=(40-latitude)*1.08")
	cities = read_json("res://data/traveler/atlas/cities.json")
	var terrain := branch("Terrain64")
	var catalog: Array = read_json("res://data/traveler/atlas/terrain-catalog.json")
	for tile in catalog:
		var n := import_glb("res://generated/traveler/atlas/" + str(tile.glb), terrain)
		n.name = str(tile.id) + "_" + str(tile.name)
		n.set_meta("biome", tile.biome)
		n.set_meta("geographic_bounds", tile.bounds)
		index_terrain(n)
		report.terrain_tiles += 1
	import_glb("res://generated/traveler/atlas/assets/terrain/coast.glb", branch("Coast"))
	var city_group := branch("Cities")
	for c in cities:
		var n := import_glb("res://generated/traveler/atlas/assets/cities/%s.glb" % c.id, city_group)
		n.name = c.id
		n.position = Vector3(c.x, c.base + .026, c.z)
		n.rotation.y = c.rotation
		n.scale = Vector3.ONE * float(c.scale)
		n.set_meta("city_id", c.id)
		n.set_meta("display_name", c.name)
		n.set_meta("longitude", c.lon)
		n.set_meta("latitude", c.lat)
		var bounds := node_bounds(n, n.transform)
		city_boxes.append(bounds.grow(.16))
		report.source_city_transforms.append({"id": c.id, "position": [n.position.x,n.position.y,n.position.z], "scale": c.scale, "yaw": c.rotation})
		report.cities += 1
	build_water()
	build_vegetation()
	build_routes()
	build_view()
	return world

func build_view()->void:
	var env_node:=WorldEnvironment.new();env_node.name="WorldEnvironment"
	var env:=Environment.new();env.background_mode=Environment.BG_COLOR
	env.background_color=Color(.89,.875,.826)
	env.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR;env.ambient_light_energy=0
	env.tonemap_mode=Environment.TONE_MAPPER_ACES;env.tonemap_exposure=0.555556 # Cancel Godot ACES built-in 1.8 exposure bias.
	env.ssao_enabled=false
	env_node.environment=env;world.add_child(env_node)
	var sun:=DirectionalLight3D.new();sun.name="Sun"
	sun.light_color=Color(1,.79,.55).linear_to_srgb();sun.light_energy=1.55
	sun.shadow_enabled=true;sun.shadow_bias=.1;sun.shadow_normal_bias=.7
	sun.directional_shadow_mode=DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance=500;sun.directional_shadow_blend_splits=true
	sun.light_angular_distance=.65;sun.rotation=Basis.looking_at(-Vector3(-.65,1.05,.65).normalized()).get_euler()
	world.add_child(sun)
	var camera:=Camera3D.new();camera.name="AtlasCamera"
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.keep_aspect=Camera3D.KEEP_HEIGHT
	camera.size=135;camera.near=.1;camera.far=1500
	var target:=Vector3(3,0,4);camera.position=target+Vector3(sin(.76)*sin(.16),cos(.76),sin(.76)*cos(.16))*230
	camera.rotation=Basis.looking_at(target-camera.position).get_euler();camera.current=true
	world.add_child(camera)

func material(kind: String) -> ShaderMaterial:
	if materials.has(kind): return materials[kind]
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/traveler/atlas_surface.gdshader")
	m.resource_name = "Atlas_" + kind
	var parameter_kind := "bush_dry_sage" if kind == "bush" else kind
	var wind: Dictionary = motion_params.wind.per_material.get(parameter_kind, {"wind_amp":0.0,"wind_stiff":1.6})
	m.set_shader_parameter("wind_amp",float(wind.wind_amp))
	m.set_shader_parameter("wind_stiff",float(wind.get("wind_stiff",1.6)))
	if kind == "emissive": m.set_shader_parameter("emission_strength", .8)
	materials[kind] = m
	return m

func import_glb(path: String, parent: Node3D) -> Node3D:
	var packed := load(path) as PackedScene
	assert(packed != null, "GLB import missing: " + path)
	var node := packed.instantiate() as Node3D
	parent.add_child(node)
	for mesh in meshes(node):
		for s in mesh.mesh.get_surface_count():
			var old := mesh.mesh.surface_get_material(s)
			var kind := old.resource_name if old else "solid"
			kind = vegetation_material_kind(kind,path)
			mesh.set_surface_override_material(s, material(kind))
	return node

func vegetation_material_kind(kind: String, path: String) -> String:
	if kind == "plants" and path.contains("/cities/"): return "city_plants"
	if not path.contains("/prototypes/"): return kind
	if kind == "solid": return "trunk"
	if kind == "plants" and path.contains("/prototypes/cypress"): return "cypress"
	if kind == "plants" and (path.contains("/dry") or path.contains("/sage")): return "bush"
	return kind

func meshes(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D: found.append(node)
	for child in node.get_children(): found.append_array(meshes(child))
	return found

func node_bounds(node: Node3D, transform: Transform3D) -> AABB:
	var box := AABB()
	var started := false
	for m in meshes(node):
		var b: AABB = transform * m.transform * m.get_aabb()
		if started: box = box.merge(b)
		else:
			box = b
			started = true
	return box

func index_terrain(node: Node3D) -> void:
	for m in meshes(node):
		for s in m.mesh.get_surface_count():
			var arrays := m.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for i in range(0, indices.size() if indices.size() else v.size(), 3):
				var a := v[indices[i] if indices.size() else i]
				var b := v[indices[i+1] if indices.size() else i+1]
				var c := v[indices[i+2] if indices.size() else i+2]
				for x in range(floori(minf(a.x,minf(b.x,c.x))/3.0), floori(maxf(a.x,maxf(b.x,c.x))/3.0)+1):
					for z in range(floori(minf(a.z,minf(b.z,c.z))/3.0), floori(maxf(a.z,maxf(b.z,c.z))/3.0)+1):
						var key := Vector2i(x,z)
						if not height_buckets.has(key): height_buckets[key] = []
						height_buckets[key].append([a,b,c])

func land_height(x: float, z: float) -> float:
	var y := -1.4
	for tri in height_buckets.get(Vector2i(floori(x/3.0),floori(z/3.0)), []):
		var a: Vector3 = tri[0]; var b: Vector3 = tri[1]; var c: Vector3 = tri[2]
		var d := (b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z)
		if absf(d)<0.000001: continue
		var u := ((b.z-c.z)*(x-c.x)+(c.x-b.x)*(z-c.z))/d
		var v := ((c.z-a.z)*(x-c.x)+(a.x-c.x)*(z-c.z))/d
		if u>=-.0001 and v>=-.0001 and u+v<=1.0001:
			y = maxf(y, u*a.y+v*b.y+(1-u-v)*c.y)
	return y

func mesh_node(label: String, mesh: Mesh, parent: Node3D, mat: Material) -> MeshInstance3D:
	var n := MeshInstance3D.new(); n.name = label; n.mesh = mesh; n.material_override = mat
	parent.add_child(n)
	return n

func build_water() -> void:
	var water := branch("Water")
	# Preserve the atlas perimeter, but give the sea a separate submerged floor.
	var bed_mat := material("seabed")
	bed_mat.set_shader_parameter("base_color", Color("5d9690"))
	var bed := mesh_node("Seabed_Volume", GEO.slab(190,109,1.4,5), water, bed_mat)
	bed.position = Vector3(4,-2.1,4)
	var wm := ShaderMaterial.new(); wm.shader = load("res://shaders/traveler/atlas_water.gdshader")
	wm.resource_name = "Atlas_Sea"
	var sea := mesh_node("Sea_Surface", slab_top(190,109,5), water, wm)
	sea.position = Vector3(4,.005,4)
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Coast fascia covers the water edge down to the seabed; no second top plane.
	var surface := material("ocean_edge");surface.set_shader_parameter("base_color",Color("397476"))
	var edge := mesh_node("Ocean_Volume_Sides", slab_sides(190,109,1.405,5), water, surface)
	edge.position=Vector3(4,-.6975,4)
	var shelf_material := StandardMaterial3D.new()
	shelf_material.albedo_color=Color("93bab0"); shelf_material.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	shelf_material.albedo_color.a=.35;shelf_material.roughness=.7;shelf_material.cull_mode=BaseMaterial3D.CULL_DISABLED
	var coast_paths: Array = read_json("res://data/traveler/atlas/coasts.json")
	var shelf_arrays: Array = []
	for ring in coast_paths:
		var pts: Array = []
		for p in ring: pts.append(Vector3(p[0],-.14,p[1]))
		shelf_arrays.append(pts)
	mesh_node("Submerged_Shore_Shelf", ribbons(shelf_arrays,.88),water,shelf_material).cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var river_group:=branch("Rivers",water)
	var river_material:=StandardMaterial3D.new();river_material.albedo_color=Color("5f9d9d")
	river_material.roughness=.35;river_material.cull_mode=BaseMaterial3D.CULL_DISABLED
	for river in read_json("res://data/traveler/atlas/rivers.json"):
		var pts:Array=[]
		for p in river.points: pts.append(Vector3(p[0], maxf(float(p[1]),land_height(p[0],p[2])+.018), p[2]))
		mesh_node(str(river.name),ribbons([pts],river.width),river_group,river_material).cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var boats:=branch("Boats")
	for data in [[58,7,.8],[67,17,-.4],[123,16,.5],[14,35,1.8],[149,28,-.8]]:
		var b:=mesh_node("Sailboat",GEO.boat_mesh(),boats,material("solid"))
		b.position=Vector3((data[0]-76)*.9,.07,(40-data[1])*1.08);b.rotation.y=data[2];b.scale=Vector3.ONE*1.4

func slab_top(w:float,d:float,bevel:float)->ArrayMesh:
	var ring: Array[Vector2]=[Vector2(-w/2+bevel,-d/2),Vector2(w/2-bevel,-d/2),Vector2(w/2,-d/2+bevel),Vector2(w/2,d/2-bevel),Vector2(w/2-bevel,d/2),Vector2(-w/2+bevel,d/2),Vector2(-w/2,d/2-bevel),Vector2(-w/2,-d/2+bevel)]
	var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP);st.set_color(Color.WHITE)
	for i in 8:
		for p in [Vector3.ZERO,Vector3(ring[i].x,0,ring[i].y),Vector3(ring[(i+1)%8].x,0,ring[(i+1)%8].y)]:st.add_vertex(p)
	return st.commit()

func slab_sides(w:float,d:float,h:float,bevel:float)->ArrayMesh:
	var ring: Array[Vector2]=[Vector2(-w/2+bevel,-d/2),Vector2(w/2-bevel,-d/2),Vector2(w/2,-d/2+bevel),Vector2(w/2,d/2-bevel),Vector2(w/2-bevel,d/2),Vector2(-w/2+bevel,d/2),Vector2(-w/2,d/2-bevel),Vector2(-w/2,-d/2+bevel)]
	var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(Color.WHITE)
	for i in 8:
		var a:=ring[i];var b:=ring[(i+1)%8]
		add_quad(st,Vector3(a.x,-h/2,a.y),Vector3(a.x,h/2,a.y),Vector3(b.x,h/2,b.y),Vector3(b.x,-h/2,b.y))
	st.generate_normals();return st.commit()

func build_vegetation() -> void:
	var data:Dictionary=read_json("res://data/traveler/atlas/instances.json")
	var high:=branch("VegetationHigh");high.visible=false
	var low:=branch("VegetationLow")
	# Partition MultiMeshes by the 64 authored regions for view-frustum culling.
	for pi in data.prototypes.size():
		var label:String=data.prototypes[pi]
		var prototype:Node3D=(load("res://generated/traveler/atlas/assets/prototypes/%s.glb" % label) as PackedScene).instantiate()
		var high_meshes:=meshes(prototype)
		var shared_high_meshes:Array[Mesh]=[]
		for original in high_meshes:
			var newmesh:=original.mesh.duplicate() as ArrayMesh
			for s in newmesh.get_surface_count():
				var old:=newmesh.surface_get_material(s)
				var kind := vegetation_material_kind(old.resource_name if old else "plants", "res://generated/traveler/atlas/assets/prototypes/%s.glb" % label)
				newmesh.surface_set_material(s,material(kind))
			shared_high_meshes.append(newmesh)
		var low_mesh:Mesh=GEO.low_tree(label)
		for tile in 64:
			var rows:Array=[]
			for row in data.trees:
				if int(row[0])==pi and int(row[7])==tile:rows.append([row[1],row[2],row[3],row[4],row[5],row[6]])
			if rows.is_empty():continue
			instance_mesh("T%02d_%s" % [tile+1,label],low_mesh,rows,low,material("plants"))
			for newmesh in shared_high_meshes:
				instance_mesh("T%02d_%s_detail"%[tile+1,label],newmesh,rows,high,null)
		prototype.free()
	var details:=branch("NaturalDetails")
	for karst in [false,true]:
		var rows:Array=[]
		for row in data.rocks:
			if (row[6]=="karst" and float(row[4])/float(row[3])>1)==karst:rows.append([row[0],row[1],row[2],row[3],row[5],1.0])
		instance_mesh("Karst" if karst else "Rocks",GEO.rock_mesh(karst),rows,details,material("solid"))
	var grasses:Array=[]
	for row in data.grasses:grasses.append([row[0],row[1],row[2],row[3],row[0]*1.5,1.0])
	instance_mesh("Grass",GEO.grass_mesh(),grasses,details,material("grass")).cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	report.trees=data.trees.size();report.rocks=data.rocks.size();report.grasses=data.grasses.size()

func instance_mesh(label:String,mesh:Mesh,rows:Array,parent:Node3D,mat:Material)->MultiMeshInstance3D:
	var mm:=MultiMesh.new();mm.transform_format=MultiMesh.TRANSFORM_3D;mm.use_colors=true;mm.use_custom_data=true;mm.mesh=mesh;mm.instance_count=rows.size()
	var rng := RandomNumberGenerator.new()
	# Local generator repeats across matching high/low and trunk/canopy batches.
	rng.seed = 20260918
	var bounds := AABB()
	for i in rows.size():
		var row:Array=rows[i]
		mm.set_instance_transform(i,Transform3D(Basis(Vector3.UP,row[4]).scaled(Vector3.ONE*float(row[3])),Vector3(row[0],row[1],row[2])))
		# Source brightness multiplies sRGB before gamma conversion; preserve that response.
		var brightness:=pow(float(row[5]),2.2)
		mm.set_instance_color(i,Color(brightness,brightness,brightness,1))
		mm.set_instance_custom_data(i,Color(rng.randf(),rng.randf_range(0.75,1.25),rng.randf_range(0.6,1.4),0))
		var box: AABB = mm.get_instance_transform(i) * mesh.get_aabb()
		bounds = box if i == 0 else bounds.merge(box)
	var n:=MultiMeshInstance3D.new();n.name=label;n.multimesh=mm;n.material_override=mat;parent.add_child(n)
	n.custom_aabb = bounds.grow(float(motion_params.wind.custom_aabb_grow_u))
	return n

func build_routes()->void:
	var group:=branch("FormalRoutes");group.visible=false
	var node_group:=branch("FormalNodes");node_group.visible=false
	var path:="res://data/traveler/formal-routes.json"
	if not FileAccess.file_exists(path):return
	var data:Dictionary=read_json(path)
	for route in data.routes:
		var rg:=branch(str(route.get("id",route.get("corridor_id","route"))),group)
		rg.set_meta("formal_data",route)
		for segment in route.segments:
			var kind:String=segment.kind
			var color:Color={"land":Color("c79454"),"sea":Color("f2deb0"),"approach":Color("a6b4a6"),"game-connection":Color("cf8e83")}.get(kind,Color("d6b274"))
			var mat:=StandardMaterial3D.new();mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;mat.albedo_color=color;mat.cull_mode=BaseMaterial3D.CULL_DISABLED
			var lines:Array=[];var line:Array=[]
			var curve:Array=segment.get("curve",[])
			for i in range(curve.size()-1):
				var a:Vector3=Vector3(curve[i][0],0,curve[i][2]);var b:Vector3=Vector3(curve[i+1][0],0,curve[i+1][2])
				var steps:=maxi(1,ceili(a.distance_to(b)/.18))
				for k in range(steps+1):
					var p:=a.lerp(b,float(k)/steps)
					p.y=maxf(.085,land_height(p.x,p.z)+.045) if kind!="sea" else .085
					var blocked:=false
					for box in city_boxes:
						if p.x>box.position.x and p.x<box.end.x and p.z>box.position.z and p.z<box.end.z:blocked=true;break
					if blocked or (kind!="land" and (k+i)%9>=6):
						if line.size()>1:lines.append(line)
						line=[]
					else:line.append(p)
			if line.size()>1:lines.append(line)
			mesh_node(kind,ribbons(lines,.065 if kind=="land" else .05),rg,mat).cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for node in data.nodes:
		if node.get("node_type","")=="CITY":continue
		var pos:Array=node.get("position",[])
		if pos.size()!=3:continue
		var m:=CylinderMesh.new();m.top_radius=.12;m.bottom_radius=.12;m.height=.045;m.radial_segments=12
		var mat:=StandardMaterial3D.new();mat.albedo_color=Color("eadcc3");mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
		var n:=mesh_node(str(node.get("id","node")),m,node_group,mat)
		var node_y:=.12 if node.get("allowed_routes",[])==["SEA"] else maxf(.12,land_height(pos[0],pos[2])+.075)
		n.position=Vector3(pos[0],node_y,pos[2]);n.set_meta("formal_node",node)
	report.route_count=data.routes.size();report.node_count=data.nodes.size();report.edge_count=data.edges.size()

func ribbons(lines:Array,width:float)->ArrayMesh:
	var st:=SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count:=0
	for points in lines:
		for i in range(points.size()-1):
			var a:Vector3=points[i];var b:Vector3=points[i+1]
			var dx:=b.x-a.x;var dz:=b.z-a.z;var length:=Vector2(dx,dz).length()
			if length<.00001:continue
			var n:=Vector3(-dz,0,dx)/length*width*.5
			add_quad(st,a+n,b+n,b-n,a-n);count+=1
	if count==0:
		st.add_vertex(Vector3.ZERO);st.add_vertex(Vector3.ZERO);st.add_vertex(Vector3.ZERO)
	st.generate_normals();return st.commit()

func add_quad(st:SurfaceTool,a:Vector3,b:Vector3,c:Vector3,d:Vector3)->void:
	for p in [a,c,b,a,d,c]:st.add_vertex(p)
