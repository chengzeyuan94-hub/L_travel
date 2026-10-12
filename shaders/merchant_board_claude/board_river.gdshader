// Merchant board (Claude sample) — cute flowing river ribbon.
// UV.x = distance along the river (source -> mouth, world units), UV.y = 0..1 across.
shader_type spatial;
render_mode cull_disabled, shadows_disabled;

uniform vec3 water : source_color = vec3(0.24, 0.66, 0.84);
uniform vec3 deep : source_color = vec3(0.14, 0.5, 0.74);
uniform vec3 bank : source_color = vec3(0.72, 0.9, 0.95);
uniform float flow_speed = 0.55;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void fragment() {
	float across = abs(UV.y * 2.0 - 1.0);
	vec3 c = mix(deep, water, smoothstep(0.0, 0.9, across));
	// streaks drifting downstream, wobbling across the ribbon
	float n = vnoise(vec2(UV.x * 1.3 - TIME * flow_speed, UV.y * 3.0));
	float streak = smoothstep(0.62, 0.8, n) * (1.0 - across * 0.6);
	c = mix(c, bank, streak * 0.55);
	// bright banks
	c = mix(c, bank, smoothstep(0.72, 0.98, across) * 0.7);
	ALBEDO = c;
	EMISSION = c * 0.08;
	ROUGHNESS = 0.35;
	SPECULAR = 0.3;
}
