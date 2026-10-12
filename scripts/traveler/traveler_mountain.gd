extends RefCounted
## Traveler-only background shading. The legacy board generator stays intact.

func color3(value: Array) -> Color:
	return Color(float(value[0]),float(value[1]),float(value[2]))

func material(lighting: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode=BaseMaterial3D.SHADING_MODE_PER_PIXEL if lighting.get("mode","")=="scene_lit" else BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.diffuse_mode=BaseMaterial3D.DIFFUSE_LAMBERT
	mat.roughness=0.97
	mat.vertex_color_use_as_albedo=true
	mat.vertex_color_is_srgb=false # relight() writes linear radiance.
	mat.metallic=0.0
	mat.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
	mat.cull_mode=BaseMaterial3D.CULL_BACK
	mat.disable_fog=not bool(lighting.fog_enabled)
	return mat

func relight(source: ArrayMesh, faces: Array, bodies: Array, lighting: Dictionary, snow_params: Dictionary = {}) -> ArrayMesh:
	var arrays: Array=source.surface_get_arrays(0)
	var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray=arrays[Mesh.ARRAY_COLOR]
	assert(vertices.size()==faces.size()*3,"Mountain audit must cover every triangle")
	var key: Array=lighting.direction_to_key_world
	var to_light := Vector3(key[0],key[1],key[2]).normalized()
	var key_color := color3(lighting.key_color_linear)*float(lighting.key_energy)
	var fill_color := color3(lighting.fill_color_linear)*float(lighting.fill_energy)
	for fi in faces.size():
		var start := fi*3
		var midpoint := (vertices[start]+vertices[start+1]+vertices[start+2])/3.0
		var origin: Array=bodies[int(faces[fi].body)].origin
		var radial := Vector3(midpoint.x-float(origin[0]),0.0,midpoint.z-float(origin[2])).normalized()
		var normal := normals[start].normalized()
		if normal.dot(radial)<0.0:normal=-normal
		assert(normal.dot(radial)>0.0,"Mountain normal must point outward")
		# Godot fronts use clockwise winding. Keep the already-visible vertex
		# order; the old right-handed cross product was the incorrect attribute.
		if not snow_params.is_empty():
			var body: Dictionary=bodies[int(faces[fi].body)]
			var angle := fposmod(atan2(midpoint.z-float(origin[2]),midpoint.x-float(origin[0])),TAU)
			var ridge: Array=body.ridge
			var u := angle/TAU*ridge.size()
			var index := int(floor(u))%ridge.size()
			var shape := lerpf(ridge[index],ridge[(index+1)%ridge.size()],u-floor(u))-1.0
			var start_height := float(snow_params.start_height)+float(snow_params.ridge_weight)*shape
			var is_snow := (midpoint.y-float(origin[1]))/float(body.height)>=start_height
			faces[fi]["material"]="snow" if is_snow else "rock"
			colors[start]=color3(snow_params.snow_color if is_snow else snow_params.rock_color)*(1.0+float(snow_params.value_gradient)*sin(angle*3.0+midpoint.y/float(body.height)))
		var light := fill_color+key_color*maxf(0.0,normal.dot(to_light))
		var baked := colors[start].srgb_to_linear()*light
		baked.a=1.0
		for corner in 3:
			normals[start+corner]=normal
			colors[start+corner]=baked
	arrays[Mesh.ARRAY_NORMAL]=normals
	arrays[Mesh.ARRAY_COLOR]=colors
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return result

# Irregular disk parameterization; no rings or per-ring random displacement.
# The inverse below preserves the legacy skirt/taper profile exactly.
func _height_parameter(r: float) -> float:
	if r>=0.74:return 0.34*(1.0-r)/0.26
	return 0.34+0.66*(1.0-pow(r/0.74,1.0/0.92))

func _ridge(angle: float, body: Dictionary, geometry: Dictionary, height_t: float=0.0) -> float:
	var values: Array=body.ridge
	var u := fposmod(angle,TAU)/TAU*values.size()
	var j := int(floor(u))%values.size()
	var low := lerpf(values[j],values[(j+1)%values.size()],u-floor(u))
	var envelope := 1.0-smoothstep(0.0,1.0,height_t)
	return low+float(geometry.ridge_amplitude)*sin(float(body.detail_lobes)*angle+float(body.detail_phase))*envelope

func _point(uv: Vector2, body: Dictionary, geometry: Dictionary) -> Vector3:
	var r := uv.length()
	var t := clampf(_height_parameter(r),0.0,1.0)
	var angle := atan2(uv.y,uv.x)
	var low_geometry := geometry.duplicate()
	low_geometry.ridge_amplitude=0.0
	var low := _ridge(angle,body,low_geometry)
	var radial := float(body.radius)*(r*low+float(geometry.ridge_amplitude)*sin(float(body.detail_lobes)*angle+float(body.detail_phase))*(1.0-smoothstep(0.0,1.0,t)))
	var o: Array=body.origin
	return Vector3(float(o[0])+cos(angle)*radial,float(o[1])+float(body.height)*pow(t,0.94),float(o[2])+sin(angle)*radial)

func _poisson(rng: RandomNumberGenerator, spacing: float, attempts: int, body: Dictionary) -> PackedVector2Array:
	var points := PackedVector2Array()
	var cells := {}
	var cell_size := spacing*0.5
	var boundary := ceili(TAU/(spacing*1.1))
	for j in boundary:
		points.append(Vector2.from_angle(TAU*float(j)/boundary))
	points.append(Vector2.ZERO)
	for i in points.size():
		var cell := Vector2i(floor(points[i].x/cell_size),floor(points[i].y/cell_size))
		if not cells.has(cell):cells[cell]=[]
		cells[cell].append(i)
	for attempt in attempts:
		var p := Vector2(rng.randf_range(-1.0,1.0),rng.randf_range(-1.0,1.0))
		var radius := p.length()
		if radius>1.0-spacing*0.75:continue
		# Sampling density follows the same low ridge field as the geometry.
		var angle := fposmod(p.angle(),TAU)
		var values: Array=body.ridge
		var index := int(angle/TAU*values.size())%values.size()
		var ridge_density := clampf((float(values[index])-0.6)/0.8,0.0,1.0)
		var minimum := spacing*(1.1-0.35*ridge_density)*(0.7+0.3*radius)
		var cell := Vector2i(floor(p.x/cell_size),floor(p.y/cell_size))
		var clear := true
		for dx in range(-3,4):
			if not clear:break
			for dy in range(-3,4):
				if not clear:break
				for other in cells.get(cell+Vector2i(dx,dy),[]):
					if p.distance_squared_to(points[other])<minimum*minimum:
						clear=false;break
		if clear:
			if not cells.has(cell):cells[cell]=[]
			cells[cell].append(points.size());points.append(p)
	return points

func _minimum_angle(a: Vector3, b: Vector3, c: Vector3) -> float:
	return minf((b-a).angle_to(c-a),minf((a-b).angle_to(c-b),(a-c).angle_to(b-c)))

func rebuild(source_bodies: Array, seed: int, params: Dictionary) -> Dictionary:
	var geometry: Dictionary=params.geometry
	var bodies: Array=source_bodies.duplicate(true)
	var faces: Array=[]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new();rng.seed=seed
	for bi in bodies.size():
		var body: Dictionary=bodies[bi]
		body.detail_lobes=rng.randi_range(int(geometry.ridge_lobes[0]),int(geometry.ridge_lobes[1]))
		body.detail_phase=rng.randf()*TAU
		var spacing := float(geometry.main_spacing if body.main else geometry.shoulder_spacing)
		var attempts := int(geometry.main_attempts if body.main else geometry.shoulder_attempts)
		var uv := _poisson(rng,spacing,attempts,body)
		var boundary := ceili(TAU/(spacing*1.1))
		var triangles := PackedInt32Array()
		var vertices := PackedVector3Array()
		var removals := 0
		# Local interior point deletion and Delaunay retriangulation repair bad
		# angles without dropping triangles, cutting holes, or hiding failures.
		for iteration in int(geometry.quality_iterations):
			triangles=Geometry2D.triangulate_delaunay(uv)
			vertices.clear()
			for point in uv:vertices.append(_point(point,body,geometry))
			var remove := {}
			for fi in range(0,triangles.size(),3):
				var ia:=triangles[fi];var ib:=triangles[fi+1];var ic:=triangles[fi+2]
				if _minimum_angle(vertices[ia],vertices[ib],vertices[ic])<deg_to_rad(float(geometry.minimum_angle)):
					# Remove the non-boundary endpoint of the shortest edge.
					var choice := -1;var shortest := INF
					for pair in [[ia,ib],[ib,ic],[ic,ia]]:
						var distance: float=vertices[pair[0]].distance_squared_to(vertices[pair[1]])
						for index in pair:
							if index>boundary and distance<shortest:choice=index;shortest=distance
					if choice>=0:remove[choice]=true
			if remove.is_empty():break
			var keep := PackedVector2Array()
			for i in uv.size():
				if not remove.has(i):keep.append(uv[i])
			removals+=remove.size();uv=keep
		# Recompute after the last repair so stale indices can never escape.
		triangles=Geometry2D.triangulate_delaunay(uv);vertices.clear()
		for point in uv:vertices.append(_point(point,body,geometry))
		body.face_start=faces.size();body.quality_vertex_removals=removals
		body.topology="variable-radius Poisson disk + Delaunay; 3D angle repair"
		body.snow_ridge=[]
		for j in int(params.snow.boundary_samples):body.snow_ridge.append(_ridge(TAU*float(j)/float(params.snow.boundary_samples),body,geometry))
		for fi in range(0,triangles.size(),3):
			var a := vertices[triangles[fi]];var b := vertices[triangles[fi+1]];var c := vertices[triangles[fi+2]]
			var n := -(b-a).cross(c-a).normalized()
			var mid := (a+b+c)/3.0
			var origin := Vector3(body.origin[0],body.origin[1],body.origin[2])
			var radial := Vector3(mid.x-origin.x,0.0,mid.z-origin.z)
			if n.dot(radial)<0.0:
				var swap := b;b=c;c=swap;n=-n
			var angle := atan2(radial.z,radial.x)
			var snow_start := float(params.snow.start_height)+float(params.snow.ridge_weight)*(_ridge(angle,body,geometry)-1.0)
			var snow := (mid.y-origin.y)/float(body.height)>=snow_start
			var base := color3(params.snow.snow_color if snow else params.snow.rock_color)
			var tint := 1.0+float(params.snow.value_gradient)*(_ridge(angle+0.7,body,geometry)-1.0)
			var key: Array=params.lighting.direction_to_key_world
			var light := color3(params.lighting.fill_color_linear)*float(params.lighting.fill_energy)+color3(params.lighting.key_color_linear)*float(params.lighting.key_energy)*maxf(0.0,n.dot(Vector3(key[0],key[1],key[2]).normalized()))
			var color := base.srgb_to_linear()*tint
			if params.lighting.get("mode","")!="scene_lit":color*=light
			color.a=1.0
			faces.append({"body":bi,"material":"snow" if snow else "rock"})
			for p in [a,b,c]:
				st.set_normal(n);st.set_color(color);st.add_vertex(p)
	return {"mesh":st.commit(),"faces":faces,"bodies":bodies}
