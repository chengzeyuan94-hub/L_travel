extends Node3D
## Three little potato flowers, attached to the carried potatoes in bundle space.
## The caller can turn off autoplay and drive set_time() for repeatable captures.

const CYCLE_SECONDS := 11.5
const HEIGHTS_WORLD := [0.088, 0.070, 0.080]
const RADII_WORLD := [0.025, 0.023, 0.027]
const DELAYS := [0.0, 0.55, 1.05]
const PETAL_SHADER := """
shader_type spatial;
render_mode cull_disabled;
uniform float glow_energy = 2.7;
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.57;
	SPECULAR = 0.22;
	EMISSION = COLOR.rgb * glow_energy;
}
"""

@export var autoplay := true
@export var emission_strength := 2.7
@export var hand_light_energy := 0.025

var _bundle: Node3D
var _root: Node3D
var _stalks: Array[Dictionary] = []
var _pollen: Array[Dictionary] = []
var _light: OmniLight3D
var _petal_material: ShaderMaterial
var _heart_material: StandardMaterial3D
var _pollen_material: StandardMaterial3D
var _clock := 0.0
var _growth_clock := 0.0
var _units := 1.0
var _configured := false


func configure(carrying: Node3D) -> bool:
	restore()
	name = "BaghdadPotatoBlossom"
	_bundle = carrying.get("potato_bundle") as Node3D
	var potatoes: Variant = carrying.get("_potatoes")
	if _bundle == null or not potatoes is Array or potatoes.size() < 3:
		push_error("Potato blossoms require the carrying bundle and its three potatoes")
		return false
	# Desired dimensions are world units. The bundle inherits the character scale.
	var parent_scale := _bundle.global_basis.get_scale().abs()
	_units = 1.0 / maxf((parent_scale.x + parent_scale.y + parent_scale.z) / 3.0, 0.00001)
	_root = Node3D.new()
	_root.name = "PotatoBlossoms"
	_bundle.add_child(_root)
	_make_materials()
	for index in 3:
		var potato := potatoes[index] as Node3D
		if potato == null:
			restore()
			return false
		_build_stalk(potato, index)
	_light = OmniLight3D.new()
	_light.name = "BlossomWarmthOnHands"
	_root.add_child(_light)
	_light.position = (_stalks[0].anchor + _stalks[1].anchor + _stalks[2].anchor) / 3.0
	_light.position.y += 0.022 * _units
	_light.light_color = Color(1.0, 0.79, 0.48)
	_light.light_energy = hand_light_energy
	_light.omni_range = 0.18
	_light.omni_attenuation = 1.6
	_light.shadow_enabled = false
	_light.light_volumetric_fog_energy = 0.0
	_build_pollen()
	_configured = true
	set_time(0.0)
	set_process(autoplay)
	return true


func _make_materials() -> void:
	var shader := Shader.new()
	shader.code = PETAL_SHADER
	_petal_material = ShaderMaterial.new()
	_petal_material.shader = shader
	_petal_material.set_shader_parameter("glow_energy", emission_strength)
	_heart_material = _solid(Color(1.0, 0.67, 0.15))
	_heart_material.emission_enabled = true
	_heart_material.emission = Color(1.0, 0.57, 0.09)
	_heart_material.emission_energy_multiplier = 3.4
	_pollen_material = _solid(Color(1.0, 0.87, 0.46))
	_pollen_material.emission_enabled = true
	_pollen_material.emission = Color(1.0, 0.73, 0.30)
	_pollen_material.emission_energy_multiplier = 2.7


func _build_stalk(potato: Node3D, index: int) -> void:
	var anchor := _potato_top(potato)
	# A short root penetrates the actual surface rather than hovering above an AABB.
	anchor.y -= 0.0012 * _units
	var stalk := Node3D.new()
	stalk.name = "Potato_%02d_Sprout" % (index + 1)
	stalk.position = anchor
	_root.add_child(stalk)
	var length := float(HEIGHTS_WORLD[index]) * _units
	var bend := Vector3([-0.010, 0.011, 0.004][index], 0.0, [0.028, 0.031, 0.034][index]) * _units
	var stem := Node3D.new()
	stem.name = "GrowingStem"
	stalk.add_child(stem)
	var green := _solid(Color(0.25, 0.48, 0.14))
	var leaf_green := _solid(Color(0.38, 0.59, 0.22))
	leaf_green.cull_mode = BaseMaterial3D.CULL_DISABLED
	var last := Vector3.ZERO
	for segment in 4:
		var f := float(segment + 1) / 4.0
		var next := Vector3(0.0, length * f, 0.0) + bend * f * f
		_segment(stem, last, next, (0.0015 - f * 0.0005) * _units, green, segment)
		last = next
	var leaves: Array[Node3D] = []
	for side in 2:
		var leaf_pivot := Node3D.new()
		leaf_pivot.name = "Leaf_%02d" % (side + 1)
		var leaf_height := 0.32 + 0.26 * float(side)
		leaf_pivot.position = Vector3(0.0, length * leaf_height, 0.0) + bend * leaf_height * leaf_height
		leaf_pivot.rotation = Vector3(deg_to_rad(-18.0), deg_to_rad(float(index * 39 + side * 135)), deg_to_rad(-65.0 if side == 0 else 67.0))
		stem.add_child(leaf_pivot)
		var leaf := MeshInstance3D.new()
		leaf.name = "PointedLeaf"
		leaf.mesh = _blade_mesh(0.023 * _units, 0.0065 * _units, false)
		leaf.material_override = leaf_green
		leaf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		leaf_pivot.add_child(leaf)
		leaves.append(leaf_pivot)
	var head := Node3D.new()
	head.name = "OpeningFivePetalFlower"
	head.position = last
	stalk.add_child(head)
	# Mixed upward/outward facing cups show pale petals from the scene and close-up.
	var head_rotation := Vector3(deg_to_rad([-43.0, -65.0, -26.0][index]), deg_to_rad([-14.0, 26.0, 5.0][index]), deg_to_rad([8.0, -13.0, 2.0][index]))
	head.rotation = head_rotation
	var petals: Array[Node3D] = []
	for petal_index in 5:
		var radial := Node3D.new()
		radial.name = "PetalAxis_%02d" % (petal_index + 1)
		radial.rotation.z = TAU * float(petal_index) / 5.0
		head.add_child(radial)
		var hinge := Node3D.new()
		hinge.name = "UncurlingPetal"
		hinge.position.y = 0.0018 * _units
		radial.add_child(hinge)
		var petal := MeshInstance3D.new()
		petal.name = "CreamPetalLavenderTip"
		var radius := float(RADII_WORLD[index]) * _units
		petal.mesh = _blade_mesh(radius, radius * 0.40, true)
		petal.material_override = _petal_material
		petal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		hinge.add_child(petal)
		petals.append(hinge)
	var heart := MeshInstance3D.new()
	heart.name = "GoldenFlowerHeart"
	var sphere := SphereMesh.new()
	sphere.radius = 0.0044 * _units
	sphere.height = 0.0088 * _units
	sphere.radial_segments = 10
	sphere.rings = 5
	heart.mesh = sphere
	heart.scale = Vector3(1.0, 1.0, 0.60)
	heart.position.z = 0.0012 * _units
	heart.material_override = _heart_material
	heart.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	head.add_child(heart)
	_stalks.append({"source": potato, "anchor": anchor, "node": stalk, "stem": stem,
		"head": head, "head_rotation": head_rotation, "tip": last, "leaves": leaves, "petals": petals,
		"heart": heart, "height_world": HEIGHTS_WORLD[index], "flower_diameter_world": RADII_WORLD[index] * 2.0,
		"growth": 0.0, "open": 0.0})


func _segment(parent: Node3D, start: Vector3, end: Vector3, radius: float, material: Material, index: int) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * 0.90
	mesh.bottom_radius = radius
	mesh.height = start.distance_to(end)
	mesh.radial_segments = 6
	var node := MeshInstance3D.new()
	node.name = "StemSegment_%02d" % index
	node.mesh = mesh
	node.material_override = material
	node.position = (start + end) * 0.5
	node.quaternion = Quaternion(Vector3.UP, (end - start).normalized())
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)


func _blade_mesh(length: float, width: float, petal: bool) -> ArrayMesh:
	# A faceted, softly cupped blade with a rounded petal end or pointed leaf end.
	var points: Array[Vector3] = [Vector3(0.0, 0.0, 0.0),
		Vector3(-width * 0.62, length * 0.34, length * 0.015),
		Vector3(-width, length * 0.67, length * 0.055),
		Vector3(-width * 0.75, length * 0.91, length * 0.12),
		Vector3(0.0, length, length * 0.145),
		Vector3(width * 0.75, length * 0.91, length * 0.12),
		Vector3(width, length * 0.67, length * 0.055),
		Vector3(width * 0.62, length * 0.34, length * 0.015)]
	if not petal:
		points[2].x *= 0.84
		points[3].x *= 0.34
		points[5].x *= 0.34
		points[6].x *= 0.84
	var center := Vector3(0.0, length * 0.54, -length * 0.025)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in points.size():
		for point in [center, points[side], points[(side + 1) % points.size()]]:
			var vertex: Vector3 = point
			if petal:
				var tip_blend := smoothstep(0.55, 1.0, vertex.y / length)
				surface.set_color(Color(1.0, 0.95, 0.80).lerp(Color(0.77, 0.60, 0.94), tip_blend * 0.73))
			else:
				surface.set_color(Color.WHITE)
			surface.add_vertex(vertex)
	surface.generate_normals()
	return surface.commit()


func _potato_top(potato: Node3D) -> Vector3:
	var highest := -INF
	var highest_point := potato.global_position
	var world_vertices: Array[Vector3] = []
	var meshes := potato.find_children("*", "MeshInstance3D", true, false)
	if potato is MeshInstance3D:
		meshes.push_front(potato)
	for item in meshes:
		var mesh_node := item as MeshInstance3D
		if mesh_node.mesh == null:
			continue
		for surface_index in mesh_node.mesh.get_surface_count():
			var arrays := mesh_node.mesh.surface_get_arrays(surface_index)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for vertex in vertices:
				var world := mesh_node.global_transform * vertex
				world_vertices.append(world)
				if world.y > highest:
					highest = world.y
					highest_point = world
	# Average only the very top cap; this is stable for irregular low-poly potatoes.
	var cap_center := Vector3.ZERO
	var cap_count := 0
	for point in world_vertices:
		if point.y >= highest - 0.0007:
			cap_center += point
			cap_count += 1
	if cap_count > 0:
		highest_point = cap_center / float(cap_count)
	elif potato.has_meta("scaled_bounds"):
		var bounds: AABB = potato.get_meta("scaled_bounds")
		highest_point.y += bounds.end.y
	return _root.to_local(highest_point)


func _build_pollen() -> void:
	# Six tiny motes, only near mature flowers, never a foreground particle curtain.
	for index in 6:
		var mote := MeshInstance3D.new()
		mote.name = "WarmPollen_%02d" % (index + 1)
		var mesh := SphereMesh.new()
		mesh.radius = (0.0006 + float(index % 2) * 0.00018) * _units
		mesh.height = mesh.radius * 2.0
		mesh.radial_segments = 6
		mesh.rings = 3
		mote.mesh = mesh
		mote.material_override = _pollen_material
		mote.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_root.add_child(mote)
		_pollen.append({"node": mote, "stalk": index % 3, "phase": float(index) * 0.71})


func set_time(seconds: float) -> void:
	_clock = maxf(seconds, 0.0)
	_growth_clock = fposmod(_clock, CYCLE_SECONDS)
	if is_instance_valid(_root):
		_root.visible = true
	_update_growth(_growth_clock)


func set_story_time(growth_seconds: float, motion_seconds: float) -> void:
	# A story can hold mature flowers without stopping their natural sway or
	# restarting the standalone blossom-to-bud loop.
	_clock = maxf(motion_seconds, 0.0)
	_growth_clock = clampf(growth_seconds, 0.0, 5.5)
	if is_instance_valid(_root):
		_root.visible = _growth_clock > 0.00001
	_update_growth(_growth_clock)


func _update_growth(t: float) -> void:
	if not _configured:
		return
	var return_to_bud := 1.0 - smoothstep(9.2, 11.25, t)
	var brightest := 0.0
	for index in _stalks.size():
		var record := _stalks[index]
		var local_time := t - float(DELAYS[index])
		var growth := smoothstep(0.12, 2.4, local_time) * return_to_bud
		var opening := smoothstep(1.72, 3.20, local_time) * return_to_bud
		var gentle_pop := sin(opening * PI) * sin(opening * PI * 2.0) * 0.085
		var settling_time := maxf(local_time - 3.20, 0.0)
		var soft_bounce := sin(settling_time * 10.0) * exp(-settling_time * 3.2) * return_to_bud
		var blossom_size := lerpf(0.23, 1.0, opening) + gentle_pop + soft_bounce * 0.065
		var stalk := record.node as Node3D
		var stem := record.stem as Node3D
		var head := record.head as Node3D
		stem.scale = Vector3(lerpf(0.15, 1.0, growth), maxf(growth, 0.022), lerpf(0.15, 1.0, growth))
		stalk.rotation.z = sin(_clock * 1.34 + float(index) * 1.7) * 0.040 * growth
		stalk.rotation.x = sin(_clock * 1.11 + float(index) * 0.9) * 0.032 * growth
		# Keep the head outside the stretching stem so a new bud stays round.
		head.position = record.tip * stem.scale
		head.scale = Vector3.ONE * blossom_size
		head.rotation = record.head_rotation + Vector3(sin(_clock * 1.4 + float(index)) * 0.018, 0.0,
			sin(_clock * 0.9 + float(index)) * 0.032) * growth
		for petal_index in 5:
			var petal := record.petals[petal_index] as Node3D
			petal.rotation.x = deg_to_rad(lerpf(-77.0, -2.0, opening) + soft_bounce * 7.0) + sin(_clock * 1.8 + float(petal_index)) * 0.018 * opening
		var heart := record.heart as Node3D
		heart.scale = Vector3(1.0, 1.0, 0.60) * lerpf(0.20, 1.0, opening)
		for leaf_index in 2:
			var leaf := record.leaves[leaf_index] as Node3D
			var leaf_growth := smoothstep(0.25 + float(leaf_index) * 0.12, 0.85, growth)
			leaf.scale = Vector3.ONE * maxf(leaf_growth, 0.015)
		record.growth = growth
		record.open = opening
		_stalks[index] = record
		brightest = maxf(brightest, opening)
	var breath := 0.94 + sin(_clock * 1.7) * 0.06
	_petal_material.set_shader_parameter("glow_energy", lerpf(0.30, emission_strength, brightest) * breath)
	_heart_material.emission_energy_multiplier = lerpf(0.35, 3.4, brightest) * breath
	_light.light_energy = hand_light_energy * brightest * breath
	for particle in _pollen:
		var node := particle.node as MeshInstance3D
		var record := _stalks[int(particle.stalk)]
		var phase := fposmod(_clock * 0.32 + float(particle.phase), 1.0)
		var openness := float(record.open)
		node.visible = openness > 0.85 and phase < 0.80
		var head := record.head as Node3D
		var origin := _root.to_local(head.global_position)
		node.position = origin + Vector3(sin(float(particle.phase) * 7.0 + phase * 3.0) * 0.018,
			0.008 + phase * 0.032, cos(float(particle.phase) * 4.0 + phase) * 0.009) * _units
		node.scale = Vector3.ONE * maxf(sin(phase * PI) * openness, 0.01)


func _process(delta: float) -> void:
	if autoplay:
		set_time(_clock + delta)


func replay() -> void:
	set_time(0.0)


func evidence() -> Dictionary:
	var records: Array[Dictionary] = []
	for record in _stalks:
		var potato := record.source as Node3D
		var stalk := record.node as Node3D
		var head := record.head as Node3D
		records.append({"potato": str(potato.name) if is_instance_valid(potato) else "",
			"stem_origin_world": _array(stalk.global_position) if is_instance_valid(stalk) else [],
			"flower_center_world": _array(head.global_position) if is_instance_valid(head) else [],
			"stem_height_world": record.height_world, "flower_diameter_world": record.flower_diameter_world,
			"growth": record.growth, "opening": record.open, "petals": 5, "leaves": 2})
	return {"configured": _configured, "time_seconds": _clock, "cycle_seconds": CYCLE_SECONDS,
		"growth_time_seconds": _growth_clock, "visible": is_instance_valid(_root) and _root.visible,
		"animation": "Three staggered sprouts, elastic five-petal opening, soft sway, breathing emission, gentle return to bud",
		"attached_to": "PotatoBundle", "surface_anchor": "Actual mesh top cap, buried 1.2 mm",
		"flowers": records, "flower_count": records.size(), "pollen_count": _pollen.size(),
		"petal_emission_energy": emission_strength, "flower_center_emission_energy": 3.4,
		"emission_uses_existing_scene_glow": true, "hand_light_peak_energy": hand_light_energy,
		"hand_light_range_world": 0.18, "light_shadows": false, "light_volumetric_fog_energy": 0.0}


func restore() -> void:
	set_process(false)
	if is_instance_valid(_root):
		_root.free()
	_root = null
	_bundle = null
	_light = null
	_stalks.clear()
	_pollen.clear()
	_configured = false


func _exit_tree() -> void:
	# Root is owned by the carrying bundle and dies with it; explicit cleanup also
	# supports removing only this optional blossom layer from an otherwise live view.
	if is_instance_valid(_root) and not _root.is_queued_for_deletion():
		_root.queue_free()


func _solid(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.74
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material


func _array(point: Vector3) -> Array:
	return [point.x, point.y, point.z]
