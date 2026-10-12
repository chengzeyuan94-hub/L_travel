shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled;

uniform vec4 mist_color : source_color = vec4(0.96, 0.985, 1.0, 1.0);
uniform float opacity : hint_range(0.0, 0.4) = 0.19;
uniform float anim_t = 0.0;

varying float mist_age;
varying float mist_shape;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float soft_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(cell), hash21(cell + vec2(1.0, 0.0)), f.x),
		mix(hash21(cell + vec2(0.0, 1.0)), hash21(cell + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	mist_age = INSTANCE_CUSTOM.y;
	mist_shape = INSTANCE_CUSTOM.z;
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 up = normalize(INV_VIEW_MATRIX[1].xyz);
	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	vec3 world_position = center + right * VERTEX.x * scale_x + up * VERTEX.y * scale_y;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_position, 1.0);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float seed = mist_shape * 17.31;
	// Low-frequency density makes broad wisps, with no dots or hard card edge.
	vec2 q = vec2(p.x * 2.7, p.y * 1.7) + vec2(seed, seed * 0.61);
	q += vec2(anim_t * 0.018, anim_t * 0.009);
	float density = soft_noise(q) * 0.65 + soft_noise(q * 2.13 + 9.7) * 0.25
		+ soft_noise(q * 4.17 + 3.4) * 0.10;
	float center_line = sin(p.x * 3.7 + seed) * 0.12 + sin(p.x * 7.0 + seed * 1.7) * 0.045;
	float thickness = 0.42 + 0.10 * sin(p.x * 4.1 + seed * 0.9);
	float vertical = exp(-pow((p.y - center_line) / thickness, 2.0) * 2.1);
	float horizontal = 1.0 - smoothstep(0.42, 1.0, abs(p.x));
	float irregular = smoothstep(0.15, 0.72, density);
	float lifetime = smoothstep(0.0, 0.18, mist_age) * (1.0 - smoothstep(0.72, 1.0, mist_age));
	float alpha = opacity * vertical * horizontal * irregular * lifetime;
	if (alpha < 0.001) {
		discard;
	}
	ALBEDO = mist_color.rgb;
	ALPHA = alpha;
}
