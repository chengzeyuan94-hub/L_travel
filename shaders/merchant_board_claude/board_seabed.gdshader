// Merchant board (Claude sample) — seabed under the clear water: vertex colours
// (sand shelf -> slope -> deep) with animated caustic light, strongest in the shallows.
shader_type spatial;
render_mode cull_back;
uniform float caustic_strength = 0.35;  // was 0.9: the bright caustics whitened the shallows
varying vec3 wpos;
vec2 hash2(vec2 p) { return fract(sin(vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)))) * 43758.5453); }
float cell_edge(vec2 p, float t) {
	vec2 i = floor(p), f = fract(p);
	float d1 = 8.0, d2 = 8.0;
	for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
		vec2 g = vec2(float(x), float(y));
		vec2 o = 0.5 + 0.4 * sin(t + 6.2831 * hash2(i + g));
		float d = length(g + o - f);
		if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) { d2 = d; }
	}
	return d2 - d1;
}
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec3 fn = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	NORMAL = normalize(mix(NORMAL, fn, 0.3));
	float e1 = cell_edge(wpos.xz * 2.2, TIME * 0.9);
	float e2 = cell_edge(wpos.xz * 1.6 + 3.7, TIME * 0.7 + 1.3);
	float caust = (1.0 - smoothstep(0.0, 0.09, e1)) * 0.6 + (1.0 - smoothstep(0.0, 0.07, e2)) * 0.4;
	float shallow = 1.0 - smoothstep(-0.9, -0.35, -wpos.y - 0.0) ;
	shallow = clamp((wpos.y + 1.1) / 0.75, 0.0, 1.0);
	// The pale sand shelf showed through thin water as milky white (「浅海发白」): under
	// shallow water the warm sand itself takes the concept's turquoise (coral and fish are
	// separate meshes and keep their colours).
	float warm = smoothstep(0.02, 0.12, COLOR.r - COLOR.b);
	ALBEDO = mix(COLOR.rgb, vec3(0.08, 0.5, 0.6) * (0.6 + 0.6 * dot(COLOR.rgb, vec3(0.33))), warm * shallow);
	EMISSION = vec3(1.0, 0.98, 0.9) * caust * caustic_strength * shallow * 0.35;
	ROUGHNESS = 0.9;
}
