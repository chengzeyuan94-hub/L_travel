// Merchant board (Claude sample) — a soft rainbow that appears behind a passing rain shower.
// Camera-facing quad (Y-axis billboard); an arc band of spectral colours.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform float strength = 0.0;

vec3 spectrum(float t) {
	// red outside -> violet inside
	vec3 c = vec3(1.0, 0.25, 0.2);
	c = mix(c, vec3(1.0, 0.6, 0.15), smoothstep(0.0, 0.2, t));
	c = mix(c, vec3(1.0, 0.95, 0.3), smoothstep(0.2, 0.38, t));
	c = mix(c, vec3(0.35, 0.95, 0.4), smoothstep(0.38, 0.56, t));
	c = mix(c, vec3(0.3, 0.6, 1.0), smoothstep(0.56, 0.76, t));
	c = mix(c, vec3(0.6, 0.35, 0.95), smoothstep(0.76, 1.0, t));
	return c;
}

void vertex() {
	vec3 sc = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), 1.0);
	vec3 right = normalize(vec3(INV_VIEW_MATRIX[0].x, 0.0, INV_VIEW_MATRIX[0].z));
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 wp = MODEL_MATRIX[3].xyz + right * VERTEX.x * sc.x + up * VERTEX.y * sc.y;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
}

void fragment() {
	vec2 p = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y);    // arc centre at bottom middle
	float r = length(p * vec2(1.0, 1.0));
	float t = (0.98 - r) / 0.22;                        // band 0.76 .. 0.98
	float band = smoothstep(0.0, 0.08, t) * (1.0 - smoothstep(0.92, 1.0, t));
	float foot = smoothstep(0.0, 0.25, p.y);            // fade into the ground
	float a = band * foot * strength * 0.62;
	if (a < 0.003) discard;
	ALBEDO = spectrum(clamp(t, 0.0, 1.0));
	ALPHA = a;
}
