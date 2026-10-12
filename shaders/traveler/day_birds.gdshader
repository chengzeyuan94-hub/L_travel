shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform float anim_t = 0.0;
uniform float cycle_s = 96.0;
uniform float crossing_s = 9.0;
uniform float start_x_u = -12.0;
uniform float end_x_u = 14.0;
uniform float sky_y_u = 4.55;
uniform float camera_depth_u = 18.0;
uniform float flap_hz = 0.73;
uniform float flap_lift_ratio = 0.52;
uniform float glide_fraction = 0.28;
uniform float bob_u = 0.045;
uniform float bob_hz = 0.21;
uniform float bird_scale = 0.09;
uniform vec4 bird_color : source_color = vec4(0.96, 0.95, 0.92, 1.0);

void vertex() {
	float local_t = mod(max(anim_t, 0.0), cycle_s);
	float phase = INSTANCE_CUSTOM.r * 6.283185307;
	float wing_cycle = fract(anim_t * flap_hz + INSTANCE_CUSTOM.r);
	float flap_phase = min(wing_cycle / (1.0 - glide_fraction), 1.0) * 6.283185307;
	// Approved Blender mesh imports as +X body axis, +Y vertical and +Z wingspan.
	// A modest yaw keeps a readable side silhouette while exposing wing area.
	float yaw = 0.32;
	vec3 goose_local = vec3(VERTEX.x * cos(yaw) + VERTEX.z * sin(yaw), VERTEX.y, -VERTEX.x * sin(yaw) + VERTEX.z * cos(yaw)) * bird_scale;
	goose_local.y += abs(goose_local.x) * sin(flap_phase) * flap_lift_ratio;
	float x = mix(start_x_u, end_x_u, clamp(local_t / crossing_s, 0.0, 1.0));
	vec3 flock_position = vec3(x + INSTANCE_CUSTOM.g,
		sky_y_u + INSTANCE_CUSTOM.b + bob_u * sin(anim_t * bob_hz * 6.283185307 + phase),
		-camera_depth_u + INSTANCE_CUSTOM.a);
	VERTEX = goose_local + flock_position;
}

void fragment() {
	ALBEDO = bird_color.rgb;
	ROUGHNESS = 1.0;
}
