// Merchant board (Claude sample) — a small stylized dust devil wandering over the desert:
// an open cone (wide at the top) whose sandy bands spiral upward; fades in and out.
// Height and angle come from the mesh position (CylinderMesh UVs pack the caps, so v does
// not span 0..1 on the side).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

instance uniform float seed = 0.0;
instance uniform float life = 1.0;   // 0..1 fade set by the script
uniform vec3 sand : source_color = vec3(0.55, 0.38, 0.22);
uniform vec3 sand_light : source_color = vec3(0.98, 0.88, 0.68);
uniform float light = 1.0;          // scene brightness (unshaded effect): dusk / twilight dim it

varying float hh;
varying float ang;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void vertex() {
	hh = clamp(VERTEX.y + 0.5, 0.0, 1.0);          // 0 bottom .. 1 top
	ang = atan(VERTEX.z, VERTEX.x) / 6.2831 + 0.5;
	VERTEX.x += sin(TIME * 1.3 + seed * 5.0) * 0.2 * hh * hh;
	VERTEX.z += cos(TIME * 1.1 + seed * 3.0) * 0.2 * hh * hh;
}

void fragment() {
	float spiral = ang * 6.2831 * 2.0 - hh * 9.0 + TIME * 7.0 + seed * 6.0;
	float bands = 0.5 + 0.5 * sin(spiral);
	float grit = vnoise(vec2(ang * 24.0 + TIME * 3.0, hh * 10.0 - TIME * 4.0));
	float a = (0.5 + 0.5 * bands) * (0.65 + 0.35 * grit);
	a *= smoothstep(0.0, 0.1, hh) * (1.0 - smoothstep(0.82, 1.0, hh));
	a *= 0.95 * life;
	if (a < 0.01) discard;
	ALBEDO = mix(sand, sand_light, bands * 0.7 + grit * 0.3) * light;
	ALPHA = a;
}
