extends RefCounted
## Authored, low-frequency snow relief for the independent Panti stage.
var params:Dictionary
var scene_settings:Dictionary
var base_y:float
var contacts:Array=[]
var rock_heights:Dictionary={}
var measured:Dictionary={}

func build(viewer:Node3D) -> ArrayMesh:
	scene_settings=viewer.settings
	params=scene_settings.ground.relief
	base_y=float(scene_settings.ground.center_stage[1])
	contacts.clear()
	rock_heights.clear()
	# Each new camp prop rests on a small patch at the existing slope height.
	var camp:Dictionary=scene_settings.get("camp",{})
	if camp.get("enabled",false):
		for prop in camp.props:
			if prop.has("mount"):continue
			var center:=Vector2(camp.root_stage[0]+prop.offset_stage[0],camp.root_stage[2]+prop.offset_stage[2])
			contacts.append({"center":center,"radius":float(prop.contact_radius_u),"y":height_at(center)})
	var camp_contacts:=contacts.duplicate(true)
	for rock in scene_settings.get("rocks",{}).get("instances",[]):
		var center:=Vector2(rock.stage_position[0],rock.stage_position[2])
		var support_y:=unconstrained_height(center)
		for contact in camp_contacts:
			var blend:=1.0-smoothstep(float(contact.radius),float(contact.radius)+float(params.contacts.transition_u),center.distance_to(contact.center))
			support_y=lerpf(support_y,float(contact.y),blend)
		rock_heights[str(rock.id)]=support_y
		contacts.append({"center":center,"radius":maxf(float(params.contacts.rock_min_radius_u),float(rock.height_u)*float(params.contacts.rock_radius_height_ratio)),"y":support_y})
	var actor:Array=scene_settings.character.stage_position
	if not camp.get("enabled",false):
		contacts.append({"center":Vector2(actor[0],actor[2]),"radius":float(params.contacts.character_radius_u),"y":float(actor[1])})
	var xs:=axis(params.grid.x_bands)
	var zs:=axis(params.grid.z_bands)
	var points:PackedVector3Array=[]
	var rng:=RandomNumberGenerator.new();rng.seed=int(params.grid.seed)
	var min_y:=INF;var max_y:=-INF
	for j in zs.size():
		for i in xs.size():
			var x:float=xs[i];var z:float=zs[j]
			if i>0 and i<xs.size()-1 and j>0 and j<zs.size()-1:
				x+=rng.randf_range(-1.0,1.0)*minf(xs[i]-xs[i-1],xs[i+1]-xs[i])*float(params.grid.jitter_fraction)
				z+=rng.randf_range(-1.0,1.0)*minf(zs[j]-zs[j-1],zs[j+1]-zs[j])*float(params.grid.jitter_fraction)
			var y:=height_at(Vector2(x,z));min_y=minf(min_y,y);max_y=maxf(max_y,y)
			points.append(viewer.stage_point(Vector3(x,y,z)))
	var builder:=SurfaceTool.new();builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in zs.size()-1:
		for i in xs.size()-1:
			var k:int=j*xs.size()+i;var row:int=xs.size()
			if (i+j)%2==0:
				triangle(builder,points[k],points[k+1],points[k+row+1])
				triangle(builder,points[k],points[k+row+1],points[k+row])
			else:
				triangle(builder,points[k],points[k+1],points[k+row])
				triangle(builder,points[k+1],points[k+row+1],points[k+row])
	measured={"triangles":(xs.size()-1)*(zs.size()-1)*2,"height_range_u":[min_y,max_y],"grid_points":points.size(),"contact_patch_count":contacts.size(),"rock_support_heights_u":rock_heights.duplicate(),"shadow_casting":false,"normal_mode":"flat per triangle","height_source":"authored broad Gaussian snow ridges; no high-frequency height noise"}
	return builder.commit()

func axis(bands:Array) -> PackedFloat32Array:
	var result:PackedFloat32Array=[]
	for band in bands:
		var count:int=ceili((float(band[1])-float(band[0]))/float(band[2]))
		for i in count:result.append(lerpf(float(band[0]),float(band[1]),float(i)/count))
	result.append(float(bands[-1][1]))
	return result

func triangle(builder:SurfaceTool,a:Vector3,b:Vector3,c:Vector3) -> void:
	var normal:Vector3=(b-a).cross(c-a).normalized()
	# Godot front faces wind clockwise. Supply the upward lighting normal.
	if normal.y<0.0:
		var swap:=b;b=c;c=swap;normal=-normal
	for point in [a,c,b]:
		builder.set_normal(normal)
		builder.add_vertex(point)

func unconstrained_height(point:Vector2) -> float:
	var displacement:=0.0
	for ridge in params.ridges:
		var local:Vector2=(point-Vector2(ridge.center[0],ridge.center[1])).rotated(-deg_to_rad(float(ridge.angle_deg)))
		var q:=Vector2(local.x/float(ridge.radius[0]),local.y/float(ridge.radius[1]))
		displacement+=float(ridge.height_u)*exp(-q.length_squared()*2.0)
	var height:float=base_y+displacement
	# A low channel continues from in front of the shoes toward the gate.
	var route:Array=params.route.points
	var distance:=INF
	for i in route.size()-1:
		var start:=Vector2(route[i][0],route[i][1]);var end:=Vector2(route[i+1][0],route[i+1][1])
		var delta:=end-start
		var weight:float=clampf((point-start).dot(delta)/delta.length_squared(),0.0,1.0)
		distance=minf(distance,point.distance_to(start+delta*weight))
	var route_blend:=1.0-smoothstep(float(params.route.half_width_u),float(params.route.half_width_u)+float(params.route.transition_u),distance)
	height=lerpf(height,base_y+displacement*float(params.route.relief_fraction),route_blend)
	var pad:Dictionary=params.castle_pad
	var box_distance:float=maxf(maxf(float(pad.min_xz[0])-point.x,point.x-float(pad.max_xz[0])),maxf(float(pad.min_xz[1])-point.y,point.y-float(pad.max_xz[1])))
	height=lerpf(height,float(pad.height_u),1.0-smoothstep(0.0,float(pad.transition_u),maxf(box_distance,0.0)))
	return height

func height_at(point:Vector2) -> float:
	var height:=unconstrained_height(point)
	# Small support patches follow the hill instead of cutting holes to y=0.
	for contact in contacts:
		var d:float=point.distance_to(contact.center)
		var blend:=1.0-smoothstep(float(contact.radius),float(contact.radius)+float(params.contacts.transition_u),d)
		if blend>0.0:height=lerpf(height,float(contact.y),blend)
	return height
