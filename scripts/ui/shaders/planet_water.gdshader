shader_type spatial;
render_mode specular_schlick_ggx;

// COLOR_0 is data: R = normalized distance from shore, G = narrow foam band,
// B = deterministic face variation. Geometry remains the radius-11.03 sphere.
uniform vec4 shallow_color : source_color = vec4(0.25, 0.72, 0.66, 1.0);
uniform vec4 deep_color : source_color = vec4(0.07, 0.25, 0.42, 1.0);
uniform vec4 foam_color : source_color = vec4(0.92, 0.95, 0.94, 1.0);
varying flat float face_id;

void vertex() {
	// Model-space flat normals keep each glint attached to its face when orbiting.
	face_id = fract(sin(dot(NORMAL, vec3(12.9898, 78.233, 45.164))) * 43758.5453);
}

void fragment() {
	float distance_from_shore = clamp(COLOR.r, 0.0, 1.0);
	float glint = 0.5 + 0.5 * sin(TIME * 0.6 + face_id * 6.283185);
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	ALBEDO = mix(shallow_color.rgb, deep_color.rgb, smoothstep(0.0, 0.55, distance_from_shore));
	ALBEDO *= 0.94 + 0.12 * COLOR.b;
	ALBEDO *= 1.0 - 0.25 * pow(1.0 - facing, 2.0);
	float wave = 0.5 + 0.5 * sin(TIME * 1.2 + distance_from_shore * 40.0);
	ALBEDO = mix(ALBEDO, foam_color.rgb, clamp(COLOR.g, 0.0, 1.0) * wave * 0.25);
	ROUGHNESS = mix(0.26, 0.42, glint);
	SPECULAR = 0.55;
	EMISSION = vec3(0.30, 0.70, 0.85) * pow(1.0 - facing, 3.0) * 0.25;
}
