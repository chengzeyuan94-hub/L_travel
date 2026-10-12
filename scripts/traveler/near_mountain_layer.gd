extends RefCounted
## Authored Blender patch: replace recorded terrain faces without editing source GLBs.
const LAYOUT = "res://assets/traveler/terrain/changan-near-patch-layout.json"
var before_buckets := {}
var after_buckets := {}
var report := {"removed_faces":0,"patch_triangles":0,"reanchored_instances":0,"reanchored_river_vertices":0,"dedicated_lights":0}

func index_triangle(buckets: Dictionary, a: Vector3, b: Vector3, c: Vector3) -> void:
	for x in range(floori(minf(a.x,minf(b.x,c.x))),floori(maxf(a.x,maxf(b.x,c.x)))+1):
		for z in range(floori(minf(a.z,minf(b.z,c.z))),floori(maxf(a.z,maxf(b.z,c.z)))+1):
			var key := Vector2i(x,z)
			if not buckets.has(key):buckets[key]=[]
			buckets[key].append([a,b,c])

func height_at(buckets: Dictionary, x: float, z: float) -> float:
	var result := -INF
	for tri in buckets.get(Vector2i(floori(x),floori(z)),[]):
		var a: Vector3=tri[0];var b: Vector3=tri[1];var c: Vector3=tri[2]
		var den := (b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z)
		if absf(den)<0.0000001:continue
		var u := ((b.z-c.z)*(x-c.x)+(c.x-b.x)*(z-c.z))/den
		var v := ((c.z-a.z)*(x-c.x)+(a.x-c.x)*(z-c.z))/den
		if u>=-0.00001 and v>=-0.00001 and u+v<=1.00001:result=maxf(result,u*a.y+v*b.y+(1.0-u-v)*c.y)
	return result

func height_delta(point: Vector3) -> float:
	var old := height_at(before_buckets,point.x,point.z)
	var current := height_at(after_buckets,point.x,point.z)
	if is_inf(old) or is_inf(current) or absf(point.y-old)>0.55:return 0.0
	return current-old

func install(host: Node3D) -> void:
	var layout: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	var packed := load(str(layout.glb_path)) as PackedScene
	if packed==null:push_error("Near mountain GLB missing");return
	# Validate all source surfaces before changing any of them.
	var jobs: Array=[]
	for entry in layout.replacements:
		var tile: Node=host.world.get_node_or_null("Terrain64/"+str(entry.tile))
		if tile==null:push_error("Near mountain source tile missing: "+str(entry.tile));return
		var meshes: Array[Node]=tile.find_children("*","MeshInstance3D",true,false)
		if meshes.size()!=1:push_error("Near mountain source tile structure changed");return
		var node: MeshInstance3D=meshes[0]
		var arrays: Array=node.mesh.surface_get_arrays(int(entry.surface))
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
		var count: int=(indices.size() if not indices.is_empty() else arrays[Mesh.ARRAY_VERTEX].size())/3
		if count!=int(entry.source_face_count):push_error("Near mountain source topology changed");return
		jobs.append({"entry":entry,"node":node,"arrays":arrays})
	for job in jobs:
		var entry: Dictionary=job.entry
		var node: MeshInstance3D=job.node
		var arrays: Array=job.arrays
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
		if indices.is_empty():
			for i in vertices.size():indices.append(i)
		var removed := {}
		for fi in entry.removed_faces:removed[int(fi)]=true
		var kept := PackedInt32Array()
		for i in range(0,indices.size(),3):
			if removed.has(i/3):
				index_triangle(before_buckets,node.global_transform*vertices[indices[i]],node.global_transform*vertices[indices[i+1]],node.global_transform*vertices[indices[i+2]])
				report.removed_faces+=1
			else:
				for k in 3:kept.append(indices[i+k])
		arrays[Mesh.ARRAY_INDEX]=kept
		var original: Mesh=node.mesh
		var replacement := ArrayMesh.new()
		for si in original.get_surface_count():
			replacement.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays if si==int(entry.surface) else original.surface_get_arrays(si))
			replacement.surface_set_material(si,original.surface_get_material(si))
		node.mesh=replacement
	var patch: Node3D=packed.instantiate();patch.name="NearMountainLayer";host.world.add_child(patch)
	# Same scene shader controls as terrain, with ordinary Lambert for clear rock relief.
	var shader := Shader.new()
	shader.code=FileAccess.get_file_as_string("res://shaders/traveler/atlas_surface.gdshader").replace("diffuse_lambert_wrap","diffuse_lambert")
	var material := ShaderMaterial.new();material.shader=shader;material.resource_name="NearMountainSceneLit"
	material.set_shader_parameter("wind_amp",0.0)
	for mesh_node in patch.find_children("*","MeshInstance3D",true,false):
		mesh_node.material_override=material
		for si in mesh_node.mesh.get_surface_count():
			var a: Array=mesh_node.mesh.surface_get_arrays(si)
			var v: PackedVector3Array=a[Mesh.ARRAY_VERTEX]
			var ids: PackedInt32Array=a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
			if ids.is_empty():
				for i in v.size():ids.append(i)
			for i in range(0,ids.size(),3):
				index_triangle(after_buckets,mesh_node.global_transform*v[ids[i]],mesh_node.global_transform*v[ids[i+1]],mesh_node.global_transform*v[ids[i+2]])
				report.patch_triangles+=1
	host.collect_materials(patch)
	for branch in ["VegetationHigh","VegetationLow","NaturalDetails"]:
		for node in host.world.get_node(branch).find_children("*","MultiMeshInstance3D",true,false):
			var edits := {}
			for i in node.multimesh.instance_count:
				var t: Transform3D=node.multimesh.get_instance_transform(i)
				var delta := height_delta(node.global_transform*t.origin)
				if absf(delta)>0.00001:t.origin.y+=delta;edits[i]=t
			if edits.is_empty():continue
			node.multimesh=node.multimesh.duplicate()
			for i in edits:node.multimesh.set_instance_transform(i,edits[i])
			node.custom_aabb=node.custom_aabb.grow(1.0)
			report.reanchored_instances+=edits.size()
	# Preserve river route/width, only seat the existing ribbon on the authored slope.
	for node in host.world.get_node("Water/Rivers").get_children():
		var original: Mesh=node.mesh
		var result := ArrayMesh.new()
		var changed := false
		for si in original.get_surface_count():
			var a: Array=original.surface_get_arrays(si)
			var v: PackedVector3Array=a[Mesh.ARRAY_VERTEX]
			for i in v.size():
				var delta := height_delta(node.global_transform*v[i])
				if absf(delta)>0.00001:v[i].y+=delta;report.reanchored_river_vertices+=1;changed=true
			a[Mesh.ARRAY_VERTEX]=v
			result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,a)
			result.surface_set_material(si,original.surface_get_material(si))
		if changed:node.mesh=result
	report["asset"]=layout.glb_path
	report["concept"]=layout.concept
	report["four_views"]=layout.four_views
	host.world.set_meta("near_mountain",report)
	print("NEAR_MOUNTAIN ",JSON.stringify(report))
