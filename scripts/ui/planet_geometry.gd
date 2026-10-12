extends RefCounted
class_name PlanetGeometry

## Presentation projection only. Rule positions, edges and costs remain logical 2D.
const RADIUS := 11.0
const LOGICAL_CENTER := Vector2(2048.0, 681.5)
const LONGITUDE_SCALE := TAU / 6144.0
const LATITUDE_SCALE := PI / 2400.0
const GROUND_HEIGHT := 0.08


static func longitude_at(logical: Vector2) -> float:
	return (logical.x - LOGICAL_CENTER.x) * LONGITUDE_SCALE


static func latitude_at(logical: Vector2) -> float:
	return (LOGICAL_CENTER.y - logical.y) * LATITUDE_SCALE


static func normal_at(logical: Vector2) -> Vector3:
	var longitude := longitude_at(logical)
	var latitude := latitude_at(logical)
	return Vector3(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude))


static func to_world(logical: Vector2, height: float = GROUND_HEIGHT) -> Vector3:
	return normal_at(logical) * (RADIUS + height)


static func surface_basis(logical: Vector2) -> Basis:
	var longitude := longitude_at(logical)
	var east := Vector3(cos(longitude), 0.0, -sin(longitude))
	var outward := normal_at(logical)
	# Right handed: local X=east, Y=outward, Z=south.
	return Basis(east, outward, east.cross(outward).normalized())


static func basis_at(logical: Vector2) -> Basis:
	return surface_basis(logical)


static func logical_from_world(point: Vector3) -> Vector2:
	if not point.is_finite() or point.length_squared() < 0.000001:
		return Vector2.INF
	var normal := point.normalized()
	return Vector2(LOGICAL_CENTER.x + atan2(normal.x, normal.z) / LONGITUDE_SCALE,
		LOGICAL_CENTER.y - asin(clampf(normal.y, -1.0, 1.0)) / LATITUDE_SCALE)


static func ray_intersection(origin: Vector3, direction: Vector3, height: float = 0.105) -> Vector3:
	var ray := direction.normalized()
	var b := origin.dot(ray)
	var c := origin.length_squared() - pow(RADIUS + height, 2.0)
	var discriminant := b * b - c
	if discriminant < 0.0:
		return Vector3.INF
	var distance := -b - sqrt(discriminant)
	if distance < 0.0:
		distance = -b + sqrt(discriminant)
	return origin + ray * distance if distance >= 0.0 else Vector3.INF


static func is_front_facing(surface_point: Vector3, camera_position: Vector3) -> bool:
	return surface_point.dot(camera_position - surface_point) > 0.0
