// Merchant board (Claude sample) — schooling fish. Each MultiMesh instance is placed
// at its school's centre (scaled to fish size); INSTANCE_CUSTOM drives the swim:
// x = orbit radius (model units), y = phase, z = angular speed (signed, rad/s),
// w = bob phase. Fish models point along +X; the tail (x < -0.2) wiggles.
shader_type spatial;
render_mode cull_disabled;
void vertex() {
	vec4 cd = INSTANCE_CUSTOM;
	float ang = cd.y + TIME * cd.z;
	float dir = cd.z >= 0.0 ? 1.0 : -1.0;
	float tail = clamp((-VERTEX.x - 0.2) / 0.3, 0.0, 1.0);
	float wig = sin(TIME * 9.0 + cd.w * 6.2831);
	vec3 v = VERTEX;
	v.z += wig * 0.13 * tail;
	v.z += sin(TIME * 9.0 + cd.w * 6.2831 + v.x * 3.0) * 0.02;
	vec2 vel = vec2(-sin(ang), cos(ang)) * dir;
	float c = vel.x, s = vel.y;
	vec3 p = vec3(v.x * c - v.z * s, v.y, v.x * s + v.z * c);
	vec3 n = vec3(NORMAL.x * c - NORMAL.z * s, NORMAL.y, NORMAL.x * s + NORMAL.z * c);
	p += vec3(cos(ang) * cd.x, sin(TIME * 1.3 + cd.w * 6.2831) * 0.12, sin(ang) * cd.x);
	VERTEX = p;
	NORMAL = n;
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.5;
	SPECULAR = 0.4;
}
