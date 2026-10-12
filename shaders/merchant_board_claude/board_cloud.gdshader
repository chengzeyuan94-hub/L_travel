// Merchant board (Claude sample) — soft fleecy clouds framing the board.
// Camera-facing quads; shape = a few soft lobes eroded by animated fbm, so the edges
// are wispy cotton rather than hard polygons. Dusk-lit: warm top, lavender base.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

instance uniform float seed = 0.0;
instance uniform float opacity = 0.9;
uniform vec3 lit : source_color = vec3(1.0, 0.95, 0.9);
uniform vec3 shade : source_color = vec3(0.8, 0.78, 0.9);
uniform float drift = 0.012;
// soft edge where the cloud meets the frame or the board (depth-based fade)
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float soft_depth = 0.6;

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

void vertex() {
	// billboard, keeping the instance scale
	vec3 sc = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * sc.x, INV_VIEW_MATRIX[1] * sc.y, INV_VIEW_MATRIX[2] * sc.z, MODEL_MATRIX[3]);
}

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;           // -1..1, y down
	uv.y = -uv.y;
	float t = TIME * drift;
	// 7 soft lobes: a wide base row and a puffier, rounder top (cotton-like heap)
	float d = 0.0;
	for (int i = 0; i < 7; i++) {
		float fi = float(i);
		float top = step(3.5, fi);                       // lobes 4..6 sit higher
		float cx = mix(-0.55 + fi * 0.37, -0.35 + (fi - 4.0) * 0.35, top) + (hash(vec2(seed, fi)) - 0.5) * 0.2;
		float cy = mix(-0.2, 0.12, top) + (hash(vec2(fi, seed)) - 0.5) * 0.14;
		float r = mix(0.28, 0.34, top) + hash(vec2(seed + fi, 3.1)) * 0.16;
		vec2 q = (uv - vec2(cx, cy)) / vec2(r * 1.15, r);
		d = max(d, exp(-dot(q, q) * 1.7));
	}
	// flatter underside
	d *= smoothstep(-0.6, -0.3, uv.y);
	float n = fbm(uv * 2.2 + vec2(seed * 7.3 + t * 8.0, seed * 3.1 - t * 3.0));
	float wisp = fbm(uv * 5.5 + vec2(t * 14.0, seed));
	float dens = d * (0.6 + 0.75 * n) - 0.22 + (wisp - 0.5) * 0.2;
	float a = smoothstep(0.0, 0.35, dens) * opacity;
	if (a < 0.01) discard;
	float light = clamp(0.5 + uv.y * 0.55 + (n - 0.5) * 0.6, 0.0, 1.0);
	ALBEDO = mix(shade, lit, light);
	float dz = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 sv = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, dz, 1.0);
	sv.xyz /= sv.w;
	a *= smoothstep(0.0, soft_depth, VERTEX.z - sv.z);
	ALPHA = a;
}
