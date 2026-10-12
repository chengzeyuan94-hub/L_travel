// Merchant board (Claude sample) — low drifting mist lying in the valleys at the feet of the
// green and snow mountains. Horizontal quads (PlaneMesh), fbm-eroded soft edges, breathing.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

instance uniform float seed = 0.0;
uniform vec3 tint : source_color = vec3(0.96, 0.97, 1.0);
uniform float opacity = 0.42;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
	float a = 0.5, s = 0.0;
	for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = p * 2.03 + 1.7; a *= 0.5; }
	return s;
}

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float t = TIME * 0.02;
	float r = length(uv * vec2(1.0, 1.35));
	float n = fbm(uv * 1.8 + vec2(seed * 3.7 + t * 2.0, seed * 1.3 - t));
	float wisps = fbm(uv * 4.5 + vec2(-t * 3.0, t * 1.5 + seed));
	float d = (1.0 - smoothstep(0.2, 1.0, r)) * (0.35 + 0.9 * n) + (wisps - 0.5) * 0.45;
	float breathe = 0.75 + 0.25 * sin(TIME * 0.21 + seed * 6.2831);
	float a = smoothstep(0.3, 0.85, d) * opacity * breathe;
	if (a < 0.005) discard;
	ALBEDO = tint * (0.93 + 0.07 * n);
	ALPHA = a;
}
