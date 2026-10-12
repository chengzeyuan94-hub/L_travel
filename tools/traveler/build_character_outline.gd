extends SceneTree
## Keep the source character intact; omit only the glasses from its inverted hull.
var parents:=PackedInt32Array()

func root_of(index:int) -> int:
	while parents[index]!=index:
		parents[index]=parents[parents[index]]
		index=parents[index]
	return index

func _initialize() -> void:
	var style:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/traveler/character_style.json"))
	var filter:Dictionary=style.outline.omitted_component
	var scene:Node=load("res://scenes/traveler/action2_character.tscn").instantiate()
	root.add_child(scene)
	var source:MeshInstance3D=scene.find_children("*","MeshInstance3D",true,false)[0]
	assert(source.mesh.get_surface_count()==1)
	assert(source.mesh.get_blend_shape_count()==0)
	var arrays:Array=source.mesh.surface_get_arrays(0)
	var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var indices:PackedInt32Array=arrays[Mesh.ARRAY_INDEX]
	parents.resize(vertices.size())
	for i in vertices.size():parents[i]=i
	for i in range(0,indices.size(),3):
		parents[root_of(indices[i+1])]=root_of(indices[i])
		parents[root_of(indices[i+2])]=root_of(indices[i])
	# Weld positions only for topology identification, not in the exported vertex arrays.
	var positions:Dictionary={}
	for i in vertices.size():
		var key:Vector3=vertices[i].snapped(Vector3.ONE*0.00001)
		if positions.has(key):parents[root_of(i)]=root_of(positions[key])
		else:positions[key]=i
	var components:Dictionary={}
	for i in vertices.size():
		var component:=root_of(i)
		if not components.has(component):components[component]=[]
		components[component].append(i)
	var expected_min:=Vector3(filter.bounds_min[0],filter.bounds_min[1],filter.bounds_min[2])
	var expected_max:=Vector3(filter.bounds_max[0],filter.bounds_max[1],filter.bounds_max[2])
	var selected:=-1;var matches:=0
	for component in components:
		if components[component].size()!=int(filter.vertex_count):continue
		var minimum:=Vector3(INF,INF,INF);var maximum:=-minimum
		for index in components[component]:
			minimum=minimum.min(vertices[index]);maximum=maximum.max(vertices[index])
		if minimum.distance_to(expected_min)<0.00002 and maximum.distance_to(expected_max)<0.00002:
			selected=component;matches+=1
	if matches!=1:
		push_error("Expected one measured glasses component; refusing to change another part")
		quit(1);return
	var kept:=PackedInt32Array()
	for i in range(0,indices.size(),3):
		if root_of(indices[i])!=selected:
			kept.append(indices[i]);kept.append(indices[i+1]);kept.append(indices[i+2])
	arrays[Mesh.ARRAY_INDEX]=kept
	var outline:=ArrayMesh.new()
	outline.resource_name="Action2 outline without glasses"
	outline.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],{},source.mesh.surface_get_format(0))
	var audit:Dictionary={"source_scene":"res://scenes/traveler/action2_character.tscn","source_mesh_unchanged":true,"preserved_vertex_count":vertices.size(),"source_triangles":indices.size()/3,"outline_triangles":kept.size()/3,"omitted_triangles":(indices.size()-kept.size())/3,"omitted_component":filter,"connected_components":components.size(),"only_index_array_filtered":true}
	outline.set_meta("outline_filter",audit)
	var path:String=style.outline.mesh_resource
	var error:=ResourceSaver.save(outline,path)
	print("CHARACTER_OUTLINE_BUILD ",JSON.stringify(audit)," save_error=",error)
	quit(error)
