extends RefCounted
## User-delivered cliff grotto; concealed dusk/night cave backlighting.
func install(host: Node3D) -> void:
	var params_path := "res://data/traveler/cliff_buddha_params.json" if preload("res://scripts/traveler/traveler_launch.gd").user_args().has("--tripo-buddha-preview") else "res://data/traveler/cliff_buddha_v2_params.json"
	cfg=JSON.parse_string(FileAccess.get_file_as_string(params_path))
	var packed := load(str(cfg.asset)) as PackedScene
	if packed==null:push_error("Cliff Buddha asset missing");return
	var root: Node3D=packed.instantiate()
	root.name="CliffBuddha"
	host.world.add_child(root)
	root.position=Vector3(cfg.position[0],cfg.position[1],cfg.position[2])
	root.scale=Vector3.ONE*float(cfg.scale)
	root.rotation.y=deg_to_rad(float(cfg.yaw_degrees))
	var material := StandardMaterial3D.new()
	material.albedo_color=Color(str(cfg.stone_color_srgb))
	material.roughness=float(cfg.roughness)
	material.diffuse_mode=BaseMaterial3D.DIFFUSE_LAMBERT
	material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
	var triangles := 0
	var surfaces := 0
	for mesh in root.find_children("*","MeshInstance3D",true,false):
		if bool(cfg.get("preserve_mesh",false)):
			# Keep imported UVs, normals and Godot-generated LODs intact.
			for si in mesh.mesh.get_surface_count():
				var mat := mesh.mesh.surface_get_material(si).duplicate() as StandardMaterial3D
				mat.roughness=float(cfg.roughness)
				mat.diffuse_mode=BaseMaterial3D.DIFFUSE_LAMBERT
				mat.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
				mesh.set_surface_override_material(si,mat)
		elif bool(cfg.get("authored_materials",false)):
			var authored := ArrayMesh.new()
			for si in mesh.mesh.get_surface_count():
				var source_mat: StandardMaterial3D=mesh.mesh.surface_get_material(si)
				# Existing map soil forms the apron; avoid a separate flat model plinth.
				if source_mat.resource_name.contains("Ground Apron"):continue
				var mat := source_mat.duplicate() as StandardMaterial3D
				mat.diffuse_mode=BaseMaterial3D.DIFFUSE_LAMBERT
				mat.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
				mat.roughness=float(cfg.roughness)
				authored.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,mesh.mesh.surface_get_arrays(si))
				authored.surface_set_material(authored.get_surface_count()-1,mat)
			mesh.mesh=authored
		else:mesh.material_override=material
		for si in mesh.mesh.get_surface_count():
			var arrays: Array=mesh.mesh.surface_get_arrays(si)
			var ids: PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
			triangles+=(ids.size() if not ids.is_empty() else arrays[Mesh.ARRAY_VERTEX].size())/3
			surfaces+=1
	var report := cfg.duplicate(true)
	report["measured_triangles"]=triangles
	report["surfaces"]=surfaces
	report["dedicated_lights"]=0
	report["emission"]=false
	root_transform=root.global_transform
	fit_ground(host,report)
	if cfg.has("cave_glow"):
		var glow: Dictionary=cfg.cave_glow.duplicate(true)
		if preload("res://scripts/traveler/traveler_launch.gd").user_args().has("--buddha-original-backlight"):
			glow.attenuation=1.0
			glow.shadow_bias=0.015
			glow.shadow_normal_bias=0.025
			glow.lights=[{"name":"OriginalBacklight","local_position":[-0.16,0.35,0.078],"energy":0.22,"range_u":1.8}]
		var lights := Node3D.new()
		lights.name="CliffBuddhaBacklight"
		host.world.add_child(lights)
		for entry in glow.lights:
			var light := OmniLight3D.new()
			light.name=str(entry.name)
			lights.add_child(light)
			var p: Array=entry.local_position
			light.global_position=root.to_global(Vector3(p[0],p[1],p[2]))
			light.light_color=Color(str(glow.color_srgb))
			light.light_energy=float(entry.energy)
			light.omni_range=float(entry.range_u)
			light.omni_attenuation=float(glow.attenuation)
			light.shadow_enabled=bool(glow.shadow_enabled)
			light.shadow_bias=float(glow.shadow_bias)
			light.shadow_normal_bias=float(glow.shadow_normal_bias)
		report["cave_glow"]=glow
		report["dedicated_lights"]=lights.get_child_count()
	host.world.set_meta("cliff_buddha",report)
	host.set_cliff_buddha_glow(host.look_dusk or host.night)
	print("CLIFF_BUDDHA ",JSON.stringify(report))

var cfg: Dictionary
var ground := preload("res://scripts/traveler/near_mountain_layer.gd").new()
var root_transform: Transform3D

func footprint(point: Vector3) -> float:
	var local := root_transform.affine_inverse()*point
	var cut: Dictionary=cfg.terrain_cut
	return Vector2(local.x/float(cut.radius_local[0]),local.z/float(cut.radius_local[1])).length()

func lowered(point: Vector3) -> Vector3:
	var cut: Dictionary=cfg.terrain_cut
	var fade := 1.0-smoothstep(float(cut.inner_radius),float(cut.outer_radius),footprint(point))
	point.y=lerpf(point.y,float(cfg.position[1])-float(cut.ground_inset),fade)
	return point

func emit_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color, hint: Vector3) -> void:
	var n := (b-a).cross(c-a).normalized()
	if n.dot(hint)<0.0:n=-n
	for pair in [[a,ca],[b,cb],[c,cc]]:
		st.set_normal(n);st.set_color(pair[1]);st.add_vertex(pair[0])

func fit_ground(host: Node3D, report: Dictionary) -> void:
	report["adapted_terrain_triangles"]=0
	report["hidden_vegetation_instances"]=0
	report["reanchored_vegetation_instances"]=0
	report["covered_river_triangles"]=0
	var radius: float=float(cfg.scale)*float(cfg.terrain_cut.radius_local[0])*float(cfg.terrain_cut.outer_radius)+0.8
	for tile in host.world.get_node("Terrain64").get_children():
		for node in tile.find_children("*","MeshInstance3D",true,false):
			var box: AABB=node.global_transform*node.get_aabb()
			var origin := Vector3(cfg.position[0],cfg.position[1],cfg.position[2])
			if box.end.x<origin.x-radius or box.position.x>origin.x+radius or box.end.z<origin.z-radius or box.position.z>origin.z+radius:continue
			var original: Mesh=node.mesh
			var result := ArrayMesh.new()
			for si in original.get_surface_count():
				var ar: Array=original.surface_get_arrays(si)
				var v: PackedVector3Array=ar[Mesh.ARRAY_VERTEX]
				var co: PackedColorArray=ar[Mesh.ARRAY_COLOR]
				var normals: PackedVector3Array=ar[Mesh.ARRAY_NORMAL]
				var ids: PackedInt32Array=ar[Mesh.ARRAY_INDEX] if ar[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
				if ids.is_empty():
					for i in v.size():ids.append(i)
				var st := SurfaceTool.new();st.begin(Mesh.PRIMITIVE_TRIANGLES)
				for fi in range(0,ids.size(),3):
					var a: Vector3=node.global_transform*v[ids[fi]]
					var b: Vector3=node.global_transform*v[ids[fi+1]]
					var c: Vector3=node.global_transform*v[ids[fi+2]]
					var colors: Array[Color]=[co[ids[fi]],co[ids[fi+1]],co[ids[fi+2]]]
					var hint: Vector3=normals[ids[fi]]
					var mid := (a+b+c)/3.0
					var reach := maxf(a.distance_to(mid),maxf(b.distance_to(mid),c.distance_to(mid)))
					var candidate := Vector2(mid.x-origin.x,mid.z-origin.z).length()<radius+reach
					ground.index_triangle(ground.before_buckets,a,b,c)
					if not candidate:
						emit_triangle(st,a,b,c,colors[0],colors[1],colors[2],hint)
						ground.index_triangle(ground.after_buckets,a,b,c);continue
					var n := clampi(ceili(maxf(a.distance_to(b),maxf(a.distance_to(c),b.distance_to(c)))/0.40),2,14)
					var points := {};var shades := {}
					for i in n+1:
						for j in n+1-i:
							var u := float(i)/n;var w := float(j)/n
							points[Vector2i(i,j)]=lowered(a+(b-a)*u+(c-a)*w)
							shades[Vector2i(i,j)]=colors[0]*(1-u-w)+colors[1]*u+colors[2]*w
					for i in n:
						for j in n-i:
							var triangles := [[Vector2i(i,j),Vector2i(i+1,j),Vector2i(i,j+1)]]
							if j<n-i-1:triangles.append([Vector2i(i+1,j),Vector2i(i+1,j+1),Vector2i(i,j+1)])
							for tri in triangles:
								var p: Vector3=points[tri[0]];var q: Vector3=points[tri[1]];var r: Vector3=points[tri[2]]
								emit_triangle(st,p,q,r,shades[tri[0]],shades[tri[1]],shades[tri[2]],hint)
								ground.index_triangle(ground.after_buckets,p,q,r)
					report.adapted_terrain_triangles+=1
				st.commit(result);result.surface_set_material(si,original.surface_get_material(si))
			node.mesh=result
	for branch in ["VegetationHigh","VegetationLow","NaturalDetails"]:
		for node in host.world.get_node(branch).find_children("*","MultiMeshInstance3D",true,false):
			var edits := {}
			for i in node.multimesh.instance_count:
				var t: Transform3D=node.multimesh.get_instance_transform(i)
				var point: Vector3=node.global_transform*t.origin
				if footprint(point)<float(cfg.terrain_cut.clear_vegetation_radius):
					t.basis=Basis.from_scale(Vector3.ZERO);edits[i]=t;report.hidden_vegetation_instances+=1
				else:
					var delta: float=ground.height_delta(point)
					if absf(delta)>0.00001:t.origin.y+=delta;edits[i]=t;report.reanchored_vegetation_instances+=1
			if not edits.is_empty():
				node.multimesh=node.multimesh.duplicate()
				for i in edits:node.multimesh.set_instance_transform(i,edits[i])
				node.custom_aabb=node.custom_aabb.grow(2.0)
	# The existing river remains at its original route outside the solid rock footprint.
	for node in host.world.get_node("Water/Rivers").get_children():
		var original: Mesh=node.mesh
		var result := ArrayMesh.new()
		var changed := false
		for si in original.get_surface_count():
			var ar: Array=original.surface_get_arrays(si)
			var v: PackedVector3Array=ar[Mesh.ARRAY_VERTEX]
			var ids: PackedInt32Array=ar[Mesh.ARRAY_INDEX] if ar[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
			if ids.is_empty():
				for i in v.size():ids.append(i)
			var kept := PackedInt32Array()
			for fi in range(0,ids.size(),3):
				var center: Vector3=(v[ids[fi]]+v[ids[fi+1]]+v[ids[fi+2]])/3.0
				if footprint(node.global_transform*center)<float(cfg.terrain_cut.cover_river_radius):report.covered_river_triangles+=1;changed=true
				else:
					for k in 3:kept.append(ids[fi+k])
			for i in v.size():
				var delta: float=ground.height_delta(node.global_transform*v[i])
				if absf(delta)>0.00001:v[i].y+=delta;changed=true
			ar[Mesh.ARRAY_VERTEX]=v;ar[Mesh.ARRAY_INDEX]=kept
			if not kept.is_empty():
				result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,ar)
				result.surface_set_material(result.get_surface_count()-1,original.surface_get_material(si))
		if changed:
			if result.get_surface_count()==0:node.visible=false
			else:node.mesh=result
