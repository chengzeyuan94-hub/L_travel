extends RefCounted
## Static, faceted desert dunes with exact rendered-surface contact sampling.
var params:Dictionary
var measured:Dictionary={}
var _stage_vertices:PackedVector3Array=[]
var _xs:PackedFloat32Array=[]
var _zs:PackedFloat32Array=[]

func build(viewer:Node3D) -> MeshInstance3D:
	params=viewer.settings.ground
	var relief:Dictionary=params.relief
	var xs:=axis(relief.x_bands)
	var zs:=axis(relief.z_bands)
	_xs=xs;_zs=zs;_stage_vertices.clear()
	var rng:=RandomNumberGenerator.new();rng.seed=int(relief.seed)
	var vertices:PackedVector3Array=[]
	var minimum:=INF;var maximum:=-INF
	for j in zs.size():
		for i in xs.size():
			var x:float=xs[i];var z:float=zs[j]
			if i>0 and i<xs.size()-1 and j>0 and j<zs.size()-1:
				x+=rng.randf_range(-.22,.22)*minf(xs[i]-xs[i-1],xs[i+1]-xs[i])
				z+=rng.randf_range(-.22,.22)*minf(zs[j]-zs[j-1],zs[j+1]-zs[j])
			var h:=authored_height_at(Vector2(x,z));minimum=minf(minimum,h);maximum=maxf(maximum,h)
			_stage_vertices.append(Vector3(x,h,z))
			vertices.append(viewer.stage_point(Vector3(x,h,z)))
	var builder:=SurfaceTool.new();builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in zs.size()-1:
		for i in xs.size()-1:
			var k:int=j*xs.size()+i;var row:=xs.size()
			if (i+j)%2==0:
				triangle(builder,vertices[k],vertices[k+1],vertices[k+row+1])
				triangle(builder,vertices[k],vertices[k+row+1],vertices[k+row])
			else:
				triangle(builder,vertices[k],vertices[k+1],vertices[k+row])
				triangle(builder,vertices[k+1],vertices[k+row+1],vertices[k+row])
	var mat:=StandardMaterial3D.new()
	mat.albedo_color=Color(params.albedo[0],params.albedo[1],params.albedo[2])
	mat.roughness=1.0;mat.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
	mat.cull_mode=BaseMaterial3D.CULL_DISABLED
	# The sand must receive the sunset direction and SDFGI as real diffuse light.
	# A previous low emission lift made upward-facing coarse facets clip to white
	# under the cinematic key/fill combination, reading as broken reflective tiles.
	mat.emission_enabled=false
	mat.emission=Color.BLACK
	mat.emission_energy_multiplier=0.0
	var node:=MeshInstance3D.new();node.name="AuthoredDesertDunes"
	node.mesh=builder.commit();node.material_override=mat
	node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	measured={"triangles":(xs.size()-1)*(zs.size()-1)*2,"height_range_u":[minimum,maximum],"grid_points":vertices.size(),"grid_dimensions":[xs.size(),zs.size()],"shadow_casting":false,"cull_disabled":true,"normal_mode":"flat per coarse triangle","emission_enabled":false,"height_source":"staggered broad and medium Gaussian dune ridges; foreground and skyline support patches","ridge_count":relief.ridges.size(),"contact_patch_count":relief.get("contacts",[]).size(),"contact_sampling":"barycentric height on the actual jittered terrain triangles"}
	return node

func axis(bands:Array) -> PackedFloat32Array:
	var result:PackedFloat32Array=[]
	for band in bands:
		var count:=ceili((float(band[1])-float(band[0]))/float(band[2]))
		for i in count:result.append(lerpf(float(band[0]),float(band[1]),float(i)/count))
	result.append(float(bands[-1][1]))
	return result

func triangle(builder:SurfaceTool,a:Vector3,b:Vector3,c:Vector3) -> void:
	var normal:Vector3=(b-a).cross(c-a).normalized()
	if normal.y<0.0:normal=-normal
	for point in [a,b,c]:
		builder.set_normal(normal);builder.add_vertex(point)

func height_at(point:Vector2) -> float:
	if _stage_vertices.is_empty():
		return authored_height_at(point)
	var column:=_cell_index(_xs,point.x)
	var row:=_cell_index(_zs,point.y)
	if column<0 or row<0:
		return authored_height_at(point)
	var result:=_height_in_cell(point,column,row)
	if is_finite(result):return result
	# Vertex jitter can move the containing triangle into a neighboring cell.
	for j in range(maxi(0,row-1),mini(_zs.size()-1,row+2)):
		for i in range(maxi(0,column-1),mini(_xs.size()-1,column+2)):
			if i==column and j==row:continue
			result=_height_in_cell(point,i,j)
			if is_finite(result):return result
	return authored_height_at(point)

func _cell_index(values:PackedFloat32Array,value:float) -> int:
	if value<values[0] or value>values[-1]:return -1
	var low:=0
	var high:=values.size()-2
	while low<high:
		var mid:=int((low+high+1)/2)
		if values[mid]<=value:low=mid
		else:high=mid-1
	return low

func _height_in_cell(point:Vector2,column:int,row:int) -> float:
	var width:=_xs.size()
	var k:=row*width+column
	var a:Vector3=_stage_vertices[k]
	var b:Vector3=_stage_vertices[k+1]
	var c:Vector3=_stage_vertices[k+width]
	var d:Vector3=_stage_vertices[k+width+1]
	var first:=_triangle_height(point,a,b,d if (column+row)%2==0 else c)
	if is_finite(first):return first
	return _triangle_height(point,a,d,c) if (column+row)%2==0 else _triangle_height(point,b,d,c)

func _triangle_height(point:Vector2,a:Vector3,b:Vector3,c:Vector3) -> float:
	var ab:=Vector2(b.x-a.x,b.z-a.z)
	var ac:=Vector2(c.x-a.x,c.z-a.z)
	var ap:=point-Vector2(a.x,a.z)
	var denominator:=ab.cross(ac)
	if absf(denominator)<0.0000001:return INF
	var u:=ap.cross(ac)/denominator
	var v:=ab.cross(ap)/denominator
	if u<-.00001 or v<-.00001 or u+v>1.00001:return INF
	return a.y+(b.y-a.y)*u+(c.y-a.y)*v

func authored_height_at(point:Vector2) -> float:
	var result:=float(params.get("base_y_u",-.008))
	for ridge in params.relief.ridges:
		var p:Vector2=(point-Vector2(ridge.center[0],ridge.center[1])).rotated(-deg_to_rad(float(ridge.angle_deg)))
		var q:=Vector2(p.x/float(ridge.radius[0]),p.y/float(ridge.radius[1]))
		result+=float(ridge.height_u)*exp(-q.length_squared()*2.0)
	# Keep the foreground traversable while the dunes rise beyond the small camp.
	var foreground:Dictionary=params.relief.get("foreground",{})
	var foreground_blend:=smoothstep(float(foreground.get("blend_start_z",3.0)),float(foreground.get("blend_end_z",8.0)),point.y)
	result=lerpf(float(params.get("base_y_u",-.008)),result,foreground_blend)
	# A pair of broad, low-frequency waves keeps the desert from reading as a
	# flat sheet while preserving a readable path around the camp and arch.
	# The amplitude is data-driven so props use the exact same surface sample.
	var undulation:Dictionary=params.relief.get("broad_undulation",{})
	if bool(undulation.get("enabled",false)):
		var blend:=smoothstep(float(undulation.get("blend_start_z",7.0)),float(undulation.get("blend_end_z",28.0)),point.y)
		var primary:=float(undulation.get("amplitude_u",0.0))*sin(point.x*float(undulation.get("x_frequency",0.075))+point.y*float(undulation.get("z_frequency",0.042)))
		var secondary:=float(undulation.get("secondary_amplitude_u",0.0))*cos(point.x*float(undulation.get("secondary_x_frequency",0.045))-point.y*float(undulation.get("secondary_z_frequency",0.063))+0.8)
		var tertiary:=float(undulation.get("tertiary_amplitude_u",0.0))*sin(point.x*float(undulation.get("tertiary_x_frequency",0.13))+point.y*float(undulation.get("tertiary_z_frequency",0.086))+1.4)
		result+=(primary+secondary+tertiary)*blend
	var shallow:Dictionary=params.relief.get("shallow_sand",{})
	result+=float(shallow.get("amplitude_u",.012))*sin(point.x*3.0+point.y*1.1)*cos(point.y*1.5)*exp(-maxf(point.y,0.0)/float(shallow.get("fade_distance_u",5.0)))
	for contact in params.relief.get("contacts",[]):
		var distance:=point.distance_to(Vector2(contact.center[0],contact.center[1]))
		var blend:=1.0-smoothstep(float(contact.radius_u),float(contact.radius_u)+float(contact.transition_u),distance)
		result=lerpf(result,float(contact.height_u),blend)
	return result

func evidence() -> Dictionary:
	return measured.duplicate(true)
