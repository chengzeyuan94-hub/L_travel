extends RefCounted
## 第四幕「L叔在哪儿」· the one camera rule for every tile: fixed yaw / pitch / fov (look.json camera section);
## target and distance are solved so the tile bounds (plinth, ground, procedural parts, every instance and L叔)
## fill the 16:9 frame with the given margin, centred. No per-tile framing exists anywhere.

## Solves the rule and applies it to camera. Returns the camera_fit record (lshu.capture.v1 "camera").
static func fit(camera: Camera3D, tile_bounds: AABB, cam: Dictionary, focus_node: Node3D) -> Dictionary:
	var yaw: float = deg_to_rad(float(cam.get("yaw_deg", 40.1)))
	var pitch: float = deg_to_rad(float(cam.get("pitch_deg", 37.8)))
	var fov: float = float(cam.get("fov_deg", 24.0))
	var aspect: float = float(cam.get("aspect", 16.0 / 9.0))
	var margin: float = float(cam.get("margin", 0.06))
	var ortho: bool = str(cam.get("projection", "perspective")) == "orthographic"
	var dir: Vector3 = Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)).normalized()
	var zaxis: Vector3 = dir
	var xaxis: Vector3 = Vector3.UP.cross(zaxis).normalized()
	var yaxis: Vector3 = zaxis.cross(xaxis)
	var off: Array = cam.get("target_offset", [0, 0, 0])
	var target: Vector3 = tile_bounds.get_center() + Vector3(float(off[0]), float(off[1]), float(off[2]))
	var tan_half: float = tan(deg_to_rad(fov) * 0.5)
	var dist: float = 30.0
	var ortho_size: float = 10.0
	var corners: Array[Vector3] = []
	for i: int in 8:
		corners.append(tile_bounds.get_endpoint(i))
	for _iter: int in 24:
		var eye: Vector3 = target + dir * dist
		var minx: float = INF
		var maxx: float = -INF
		var miny: float = INF
		var maxy: float = -INF
		for p: Vector3 in corners:
			var v: Vector3 = p - eye
			var cx: float = v.dot(xaxis)
			var cy: float = v.dot(yaxis)
			var cz: float = -v.dot(zaxis)
			var nx: float = cx / (ortho_size * 0.5 * aspect) if ortho else cx / (cz * tan_half * aspect)
			var ny: float = cy / (ortho_size * 0.5) if ortho else cy / (cz * tan_half)
			minx = minf(minx, nx)
			maxx = maxf(maxx, nx)
			miny = minf(miny, ny)
			maxy = maxf(maxy, ny)
		var center_x: float = (minx + maxx) * 0.5
		var center_y: float = (miny + maxy) * 0.5
		var extent: float = maxf((maxx - minx) * 0.5, (maxy - miny) * 0.5) / (1.0 - margin)
		var depth: float = (tile_bounds.get_center() - eye).dot(-zaxis)
		if ortho:
			target += xaxis * center_x * ortho_size * 0.5 * aspect + yaxis * center_y * ortho_size * 0.5
			ortho_size *= extent
		else:
			target += xaxis * center_x * depth * tan_half * aspect + yaxis * center_y * depth * tan_half
			dist = maxf(2.0, dist * lerpf(1.0, extent, 0.85))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL if ortho else Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = fov
	camera.size = ortho_size
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = float(cam.get("near", 0.1))
	camera.far = float(cam.get("far", 400.0))
	camera.global_transform = Transform3D(Basis(xaxis, yaxis, zaxis), target + dir * dist)
	var focus_point: Vector3 = focus_node.global_position if focus_node != null and bool(cam.get("focus_on_character", false)) else tile_bounds.get_center()
	return {"rule": "fixed yaw/pitch/fov, fit tile bounds to 16:9 with margin", "yaw_deg": rad_to_deg(yaw), "pitch_deg": rad_to_deg(pitch), "fov_deg": fov, "projection": "orthographic" if ortho else "perspective", "distance": dist, "ortho_size": ortho_size, "target": [target.x, target.y, target.z], "margin": margin, "bounds": {"position": [tile_bounds.position.x, tile_bounds.position.y, tile_bounds.position.z], "size": [tile_bounds.size.x, tile_bounds.size.y, tile_bounds.size.z]}, "focus_distance": (focus_point - camera.global_position).dot(-camera.global_basis.z)}

## Screen-space bounds of a mesh (every 7th vertex, as in the probe) for evidence.
static func projected_bounds(camera: Camera3D, mesh: MeshInstance3D, geometry: Mesh = null) -> Dictionary:
	var geo: Mesh = geometry if geometry != null else mesh.mesh
	var minimum: Vector2 = Vector2(INF, INF)
	var maximum: Vector2 = -minimum
	for surface: int in geo.get_surface_count():
		var verts: PackedVector3Array = geo.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for vi: int in range(0, verts.size(), 7):
			var px: Vector2 = camera.unproject_position(mesh.global_transform * verts[vi])
			minimum = minimum.min(px)
			maximum = maximum.max(px)
	return {"bounds_px": [minimum.x, minimum.y, maximum.x, maximum.y], "width_px": maximum.x - minimum.x, "height_px": maximum.y - minimum.y}
