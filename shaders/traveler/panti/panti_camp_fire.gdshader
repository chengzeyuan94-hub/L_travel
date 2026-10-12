shader_type spatial;

render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform float anim_t = 0.0;
uniform vec4 flame_base : source_color = vec4(1.0, 0.86, 0.58, 1.0);
uniform vec4 flame_mid : source_color = vec4(1.0, 0.36, 0.035, 1.0);
uniform vec4 flame_tip : source_color = vec4(0.92, 0.105, 0.015, 1.0);

varying vec2 flame_uv;
varying float flame_phase;
varying float flame_brightness;
varying float flame_shape;

void vertex() {
	flame_uv = vec2(UV.x, 1.0 - UV.y);
	flame_phase = INSTANCE_CUSTOM.x;
	flame_brightness = INSTANCE_CUSTOM.y;
	flame_shape = INSTANCE_CUSTOM.z;
	float phase = INSTANCE_CUSTOM.x * 6.2831853;
	float flame_y = 1.0 - UV.y;
	float sway = sin(anim_t * 3.2 + phase + flame_y * 2.0) * 0.006;
	float sway_secondary = sin(anim_t * 5.1 + phase * 1.7) * 0.003;
	float scale_x = length(MODEL_MATRIX[0].xyz);
	float scale_y = length(MODEL_MATRIX[1].xyz);
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 camera_right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 world_up = normalize(MODEL_MATRIX[1].xyz);
	float bend = (flame_y * flame_y) * sway + flame_y * sway_secondary;
	float height_pulse = 1.0 + 0.035 * sin(anim_t * 2.7 + phase);
	float local_y = ((VERTEX.y + 0.5) * height_pulse - 0.5) * scale_y;
	vec3 world_position = center + camera_right * (VERTEX.x * scale_x + bend) + world_up * local_y;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_position, 1.0);
}

void fragment() {
	vec2 p = flame_uv * 2.0 - 1.0;
	float y = flame_uv.y;
	// Connected straight edges make a low-poly tongue, with no horizontal
	// stair steps. The last two slopes meet at an actual zero-width tip.
	float profile;
	if (y < 0.23) {
		profile = mix(0.22, 0.78, y / 0.23);
	} else if (y < 0.51) {
		profile = mix(0.78, 0.58, (y - 0.23) / 0.28);
	} else if (y < 0.76) {
		profile = mix(0.58, 0.29, (y - 0.51) / 0.25);
	} else {
		profile = mix(0.29, 0.0, (y - 0.76) / 0.24);
	}
	float phase = flame_phase * 6.2831853;
	float tip_bend = (flame_shape * 2.0 - 1.0) * 0.32
		+ sin(anim_t * 2.1 + phase) * 0.17;
	float center_x;
	if (y < 0.42) {
		center_x = mix(0.0, -tip_bend * 0.10, y / 0.42);
	} else if (y < 0.72) {
		center_x = mix(-tip_bend * 0.10, tip_bend * 0.12, (y - 0.42) / 0.30);
	} else {
		center_x = mix(tip_bend * 0.12, tip_bend, (y - 0.72) / 0.28);
	}
	float side = abs(p.x - center_x);
	if (side > profile || y < 0.0) {
		discard;
	}
	vec3 color;
	if (y < 0.40) {
		color = mix(flame_base.rgb, flame_mid.rgb, y / 0.40);
	} else {
		color = mix(flame_mid.rgb, flame_tip.rgb, (y - 0.40) / 0.60);
	}
	float across = side / max(profile, 0.001);
	float hot_core = (1.0 - smoothstep(0.14, 0.60, across))
		* (1.0 - smoothstep(0.16, 0.57, y));
	color = mix(color, flame_base.rgb, hot_core * 0.72);
	color *= mix(0.85, 1.0, 1.0 - across) * flame_brightness;
	float edge_width = max(fwidth(p.x) * 0.8, 0.012);
	float edge = smoothstep(0.0, edge_width, profile - side);
	// Exposure-tested against the warm sunset: flame must read as light,
	// while the local Omni remains weak enough to retain brown tree bark.
	// Unshaded output uses ALBEDO directly in this renderer.
	ALBEDO = color * (2.4 + hot_core * 0.7);
	EMISSION = vec3(0.0);
	ALPHA = edge * 0.98;
}
