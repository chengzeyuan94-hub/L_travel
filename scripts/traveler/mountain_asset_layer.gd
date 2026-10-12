extends RefCounted
## Authorized Blender asset placement and a separate low foothill/tree transition.
const GEO = preload("res://scripts/traveler/atlas_geometry.gd")
var params: Dictionary
var scene: PackedScene
var source_mesh: Mesh
var source_transform := Transform3D.IDENTITY
var source_triangles: PackedVector3Array
var height_cells: Dictionary = {}
const HEIGHT_CELL := 1.5
var hill_geo: Dictionary = GEO._geo()
var tree_geo: Dictionary = GEO._geo()
var report := {"instances": [], "hills": 0, "trees": 0, "tree_height_fractions": [], "hill_counts_per_instance": []}

func configure(settings: Dictionary) -> void:
	params=settings
	scene=load(str(params.asset.path)) as PackedScene
	var prototype := scene.instantiate() as Node3D
	var nodes := prototype.find_children("*", "MeshInstance3D", true, false)
	var mi := nodes[0] as MeshInstance3D
	source_mesh=mi.mesh
	source_transform=mi.transform
	source_triangles=source_mesh.get_faces()
	for index in source_triangles.size():source_triangles[index]=source_transform*source_triangles[index]
	for index in range(0,source_triangles.size(),3):
		var a := source_triangles[index]
		var b := source_triangles[index+1]
		var c := source_triangles[index+2]
		var minimum := Vector2i(floori(minf(a.x,minf(b.x,c.x))/HEIGHT_CELL),floori(minf(a.z,minf(b.z,c.z))/HEIGHT_CELL))
		var maximum := Vector2i(floori(maxf(a.x,maxf(b.x,c.x))/HEIGHT_CELL),floori(maxf(a.z,maxf(b.z,c.z))/HEIGHT_CELL))
		for x in range(minimum.x,maximum.x+1):
			for z in range(minimum.y,maximum.y+1):
				var cell := Vector2i(x,z)
				if not height_cells.has(cell):height_cells[cell]=[]
				height_cells[cell].append(index)
	prototype.free()

func build_band(root: Node3D, specs: Array, band_index: int, foot_enabled: bool) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed=int(params.placement.seed)+band_index*int(params.placement.seed_stride)
	var count: int=int(params.asset.instances_per_band[band_index])
	var band := Node3D.new()
	band.name="MassifBand%d"%band_index
	band.set_meta("mountain_band",band_index)
	root.add_child(band)
	for index in count:
		var source_index := roundi(float(index)*float(specs.size()-1)/float(maxi(1,count-1)))
		var spec: Dictionary=specs[source_index]
		var base_scale: float=float(spec.h)/float(params.asset.height)*float(params.asset.scale_multiplier)
		var scale_value := Vector3(base_scale*rng.randf_range(params.asset.scale_x[0],params.asset.scale_x[1]),base_scale*rng.randf_range(params.asset.scale_y[0],params.asset.scale_y[1]),base_scale)
		var yaw := rng.randf_range(params.asset.yaw[0],params.asset.yaw[1])
		if index%2==1:yaw+=deg_to_rad(float(params.asset.odd_yaw_degrees))
		var instance := scene.instantiate() as Node3D
		instance.name="AuthoredMassif%d"%index
		instance.position=spec.pos
		instance.rotation.y=yaw
		instance.scale=scale_value
		band.add_child(instance)
		var record := {"band":band_index,"index":index,"source_spec":source_index,"position":[instance.position.x,instance.position.y,instance.position.z],"scale":[scale_value.x,scale_value.y,scale_value.z],"yaw":yaw,"height":float(params.asset.height)*scale_value.y}
		report.instances.append(record)
		for mesh_node in instance.find_children("*","MeshInstance3D",true,false):
			mesh_node.layers=int(params.lighting.layer_mask)
			mesh_node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mesh_node.set_meta("mountain_geometry",true)
			mesh_node.set_meta("mountain_band",band_index)
			mesh_node.set_meta("mountain_instance",record)
		if foot_enabled:_add_foot(instance,record,band_index*100+index)

func _surface_height(local: Vector3) -> float:
	var best := -INF
	var cell := Vector2i(floori(local.x/HEIGHT_CELL),floori(local.z/HEIGHT_CELL))
	for index in height_cells.get(cell,[]):
		var a := source_triangles[index]
		var b := source_triangles[index+1]
		var c := source_triangles[index+2]
		var denominator := (b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z)
		if absf(denominator)<0.000001:continue
		var u := ((b.z-c.z)*(local.x-c.x)+(c.x-b.x)*(local.z-c.z))/denominator
		var v := ((c.z-a.z)*(local.x-c.x)+(a.x-c.x)*(local.z-c.z))/denominator
		if u>=0 and v>=0 and u+v<=1:best=maxf(best,u*a.y+v*b.y+(1-u-v)*c.y)
	return best

func _add_foot(instance: Node3D, record: Dictionary, index: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed=int(params.foot.seed)+index
	var cfg: Dictionary=params.foot
	var radius: float=float(params.asset.width)*instance.scale.x*0.5
	var height: float=float(record.height)
	var hills: Array=[]
	var hill_count := rng.randi_range(int(cfg.hill_count[0]),int(cfg.hill_count[1]))
	report.hill_counts_per_instance.append(hill_count)
	for i in hill_count:
		var angle := TAU*float(i)/float(hill_count)+rng.randf_range(-0.2,0.2)
		var r := rng.randf_range(cfg.ring_radius[0],cfg.ring_radius[1])
		var p := instance.transform*Vector3(cos(angle)*float(params.asset.width)*0.5*r,0,sin(angle)*float(params.asset.depth)*0.5*r)
		var h := height*rng.randf_range(cfg.hill_height[0],cfg.hill_height[1])
		var width := radius*rng.randf_range(cfg.hill_radius[0],cfg.hill_radius[1])
		p.y+=h*0.45
		GEO._append(hill_geo,GEO._ico(),p,Vector3(width,h*0.55,width*rng.randf_range(0.75,1.2)),angle)
		hills.append({"position":p,"radius":width,"height":h})
		report.hills+=1
	var tree_mesh := GEO.low_tree(str(cfg.prototype))
	var prototype_height := tree_mesh.get_aabb().size.y
	var arrays := tree_mesh.surface_get_arrays(0)
	var tree_source := {"p":arrays[Mesh.ARRAY_VERTEX],"n":arrays[Mesh.ARRAY_NORMAL],"c":arrays[Mesh.ARRAY_COLOR]}
	var inverse := instance.transform.affine_inverse()
	for attempt in int(cfg.tree_attempts):
		var angle := rng.randf()*TAU
		var r := rng.randf_range(cfg.tree_radius[0],cfg.tree_radius[1])
		var p := instance.transform*Vector3(cos(angle)*float(params.asset.width)*0.5*r,0,sin(angle)*float(params.asset.depth)*0.5*r)
		var local := inverse*p
		var local_height := _surface_height(local)
		var surface_y := instance.position.y
		if local_height!=-INF:surface_y=maxf(surface_y,instance.position.y+local_height*instance.scale.y)
		for hill in hills:
			var distance := Vector2(p.x-hill.position.x,p.z-hill.position.z).length()/float(hill.radius)
			if distance<1:surface_y=maxf(surface_y,hill.position.y+hill.height*0.55*sqrt(1-distance*distance))
		var t := (surface_y-instance.position.y)/height
		var density := 1.0-smoothstep(float(cfg.fade_height[0]),float(cfg.fade_height[1]),t)
		if rng.randf()>density:continue
		p.y=surface_y
		var target_height := minf(float(cfg.tree_height_max),height*float(cfg.tree_height)*rng.randf_range(cfg.tree_scale[0],cfg.tree_scale[1]))
		var size := target_height/prototype_height
		GEO._append(tree_geo,tree_source,p,Vector3(size*rng.randf_range(0.8,1.15),size,size),rng.randf()*TAU)
		report.trees+=1
		report.tree_height_fractions.append(t)

func finish(root: Node3D) -> void:
	for entry in [["MountainFootHills",hill_geo],["MountainFootTrees",tree_geo]]:
		if entry[1].p.is_empty():continue
		var mi := MeshInstance3D.new()
		mi.name=entry[0]
		mi.mesh=GEO._mesh(entry[1])
		if entry[0]=="MountainFootHills":
			for surface in source_mesh.get_surface_count():
				var material := source_mesh.surface_get_material(surface)
				if material.resource_name.contains("Neutral Rock"):mi.material_override=material
		else:
			var material := StandardMaterial3D.new()
			material.vertex_color_use_as_albedo=true
			material.roughness=1.0
			material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
			mi.material_override=material
		mi.layers=int(params.lighting.layer_mask)
		mi.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("mountain_geometry",true)
		mi.set_meta("mountain_foot",true)
		report[entry[0]+"_triangles"]=mi.mesh.get_faces().size()/3
		root.add_child(mi)
	root.set_meta("mountain_asset_report",report)
