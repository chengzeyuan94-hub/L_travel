shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;

uniform float rain_time = 0.0;
uniform float fall_height = 10.0;
uniform float fall_speed = 7.5;
uniform float streak_width = 0.006;
uniform float streak_length = 0.16;
uniform float opacity = 0.34;
uniform float horizontal_drift = 0.20;
uniform vec3 beam_position;
uniform vec3 beam_direction;
uniform float beam_cos_outer = 0.995;
uniform float beam_strength = 1.0;
uniform float beam_range = 10000.0;
varying vec3 world_position;
varying float drop_variation;

void vertex() {
	float phase = fract(INSTANCE_CUSTOM.r + rain_time * fall_speed * mix(0.85, 1.15, INSTANCE_CUSTOM.g) / fall_height);
	float length_scale = mix(0.7, 1.3, INSTANCE_CUSTOM.b);
	VERTEX.x *= streak_width;
	VERTEX.y *= streak_length * length_scale;
	VERTEX.x -= VERTEX.y * 0.06;
	VERTEX.y += (1.0 - phase) * fall_height;
	VERTEX.x += phase * horizontal_drift;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	drop_variation = mix(0.45, 1.0, INSTANCE_CUSTOM.a);
}

void fragment() {
	float across = 1.0 - smoothstep(0.08, 0.5, abs(UV.x - 0.5));
	float ends = smoothstep(0.0, 0.20, UV.y) * (1.0 - smoothstep(0.65, 1.0, UV.y));
	vec3 ray = normalize(world_position - beam_position);
	float lit = smoothstep(beam_cos_outer, mix(beam_cos_outer, 1.0, 0.55), dot(ray, beam_direction));
	lit *= beam_strength * (1.0 - smoothstep(beam_range * 0.9, beam_range, length(world_position - beam_position)));
	ALBEDO = mix(vec3(0.48, 0.62, 0.78), vec3(1.25, 1.08, 0.68), lit);
	ALPHA = across * ends * opacity * drop_variation * mix(1.0, 1.35, lit);
}
