// L3 · lantern halo: camera-facing soft glow quad, pushed toward the camera so the lantern body does not
// cut it, still depth-tested so buildings in front hide it. Strength per light preset (0 by day).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;

uniform vec3 halo_color : source_color = vec3(1.0, 0.7, 0.4);
uniform float halo_strength = 0.0;
uniform float halo_falloff = 3.2;
uniform float toward_camera_m = 0.25;
instance uniform float halo_flicker = 1.0;

void vertex() {
	float s = length(MODEL_MATRIX[0].xyz);
	vec3 center_v = (VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0)).xyz;
	center_v += normalize(-center_v) * toward_camera_m;
	vec3 pos_v = center_v + vec3(VERTEX.x * s, VERTEX.y * s, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(pos_v, 1.0);
}

void fragment() {
	float d = length(UV * 2.0 - 1.0);
	float a = exp(-d * d * halo_falloff) * (1.0 - smoothstep(0.75, 1.0, d));
	ALBEDO = halo_color * halo_strength * a * halo_flicker;
}
