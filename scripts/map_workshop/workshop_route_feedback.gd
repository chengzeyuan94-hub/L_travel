extends RefCounted
## Presentation-only problem locations. Validation and playable-map gates stay authoritative.
static func route(layout:Dictionary,id:String)->Dictionary:
	for row:Dictionary in layout.get("routes",[]):
		if str(row.id)==id:return row
	return {}
static func locate(layout:Dictionary,issue:Dictionary)->Dictionary:
	var target:=str(issue.get("target",""));var kind:="";var at:=Vector2.INF
	var path:=route(layout,target)
	if not path.is_empty():kind="route"
	else:
		for city:Dictionary in layout.get("cities",[]):
			if target in [str(city.id),str(city.id).trim_prefix("x_")]:
				kind="city";target=str(city.id);at=Vector2(float(city.x),float(city.z));break
	if kind=="":return {}
	var point:Variant=issue.get("point",[])
	if point is Array and point.size()==2:at=Vector2(float(point[0]),float(point[1]))
	elif issue.has("endpoint_city"):
		for city:Dictionary in layout.get("cities",[]):
			if str(city.id)==str(issue.endpoint_city):at=Vector2(float(city.x),float(city.z));break
	if at==Vector2.INF and not path.is_empty():
		var p:=point_at(path.points,0.5);at=Vector2(p.x,p.z)
	return {"kind":kind,"id":target,"anchor":at}
static func point_at(points:Array,t:float)->Vector3:
	if points.is_empty():return Vector3.ZERO
	var total:=0.0
	for i:int in range(1,points.size()):total+=Vector2(points[i][0],points[i][2]).distance_to(Vector2(points[i-1][0],points[i-1][2]))
	var left:=total*t
	for i:int in range(1,points.size()):
		var a:=Vector3(points[i-1][0],points[i-1][1],points[i-1][2]);var b:=Vector3(points[i][0],points[i][1],points[i][2]);var length:=Vector2(a.x,a.z).distance_to(Vector2(b.x,b.z))
		if left<=length:return a.lerp(b,left/maxf(length,0.0001))
		left-=length
	return Vector3(points[-1][0],points[-1][1],points[-1][2])
static func preferred_medium(base:Dictionary,doc:Dictionary,a:String,b:String,current:String="LAND")->String:
	var aa:=CustomMapFreeAuthor.routes_for(base,doc,a);var bb:=CustomMapFreeAuthor.routes_for(base,doc,b)
	# Unconnected new cities acquire traffic from their first connection.
	if a.begins_with("x_"):aa=["LAND","SEA"]
	if b.begins_with("x_"):bb=["LAND","SEA"]
	var common:Array=[]
	for medium:String in ["LAND","SEA"]:
		if medium in aa and medium in bb:common.append(medium)
	if current in common:return current
	return str(common[0]) if not common.is_empty() else current
