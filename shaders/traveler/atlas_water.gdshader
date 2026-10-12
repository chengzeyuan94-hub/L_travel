shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled, ambient_light_disabled, specular_disabled;

// One transparent surface over an actual opaque seabed. Do not stack this with
// a second translucent ocean plane: transparent depth-writing would hide it.
uniform sampler2D opaque_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform vec4 base_color : source_color = vec4(1.0);
uniform vec4 shallow_color : source_color = vec4(0.5765, 0.7294, 0.6902, 1.0);
uniform vec4 deep_color : source_color = vec4(0.2980, 0.5569, 0.5725, 1.0);
uniform float night_amount : hint_range(0.0, 1.0) = 0.0;
uniform float opacity : hint_range(0.0, 1.0) = 0.82;
uniform float depth_absorption : hint_range(0.0, 3.0) = 1.2;
uniform float brightness : hint_range(0.0, 3.0) = 1.02;
uniform float ripple_strength : hint_range(0.0, 0.15) = 0.04;
uniform float emission_strength : hint_range(0.0, 2.0) = 0.0;
uniform bool use_depth_color = true;

uniform float anim_t = -1.0; // S11 freeze hook; existing water appearance is unchanged.

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float motion_time = anim_t < 0.0 ? TIME : anim_t;
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	world_normal *= FRONT_FACING ? 1.0 : -1.0;
	world_normal = normalize(world_normal + vec3(
		sin(world_position.x * 0.8 + world_position.z * 2.3 + motion_time * 0.42) * ripple_strength,
		0.0,
		cos(world_position.z * 0.6 - world_position.x * 1.8 + motion_time * 0.34) * ripple_strength
	));
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);

	// Forward+/Mobile reverse-Z depth is [0,1]. INV_PROJECTION_MATRIX also
	// handles orthographic views, unlike perspective-only near/far formulas.
	float depth = textureLod(opaque_depth, SCREEN_UV, 0.0).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	behind.xyz /= behind.w;
	float thickness = clamp(VERTEX.z - behind.z, 0.0, 30.0);
	float absorption = 1.0 - exp(-thickness * depth_absorption);
	vec3 water_color = use_depth_color ? mix(shallow_color.rgb, deep_color.rgb, absorption) : vec3(1.0);
	float up = world_normal.y * 0.5 + 0.5;
	vec3 ambient = mix(vec3(0.24, 0.19, 0.20), vec3(0.55, 0.64, 0.71), up) * mix(0.70, 0.16, night_amount);
	vec3 fill = vec3(0.38, 0.49, 0.73) * max(dot(world_normal, normalize(vec3(6.0, 4.0, -6.0))), 0.0) * mix(0.33, 0.14, night_amount);
	vec3 night_tint = mix(vec3(1.0), vec3(0.72, 0.82, 1.18), night_amount * 0.38);
	ALBEDO = max(COLOR.rgb, vec3(0.0)) * base_color.rgb * water_color * brightness * night_tint;
	float ripple = pow(max(0.0, sin(world_position.x * 1.8 + world_position.z * 5.6 + sin(world_position.x * 0.73 - motion_time * 0.3) * 1.3 + motion_time * 0.45)), 25.0);
	float sun_pool = exp(-pow((world_position.x + 32.0) / 26.0, 2.0) - pow((world_position.z - 31.0) / 18.0, 2.0));
	EMISSION = ALBEDO * (ambient + fill + emission_strength);
	EMISSION += vec3(0.02, 0.035, 0.032) * ripple;
	EMISSION += vec3(0.045, 0.025, 0.008) * sun_pool * (1.0 - night_amount);
	ROUGHNESS = 0.38;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	ALPHA = clamp(opacity + absorption * 0.14, 0.0, 1.0);
}

void light() {
	vec3 radiance = LIGHT_COLOR / PI;
	DIFFUSE_LIGHT += max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION * radiance;
	vec3 half_dir = normalize(LIGHT + VIEW);
	SPECULAR_LIGHT += pow(max(dot(NORMAL, half_dir), 0.0), 110.0) * radiance * 0.30 * ATTENUATION;
}
