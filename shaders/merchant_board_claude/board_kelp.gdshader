// Merchant board (Claude sample) — coral / kelp with a gentle underwater sway
// (sway grows with height; per-instance phase from the instance position).
shader_type spatial;
uniform float sway = 0.06;
void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float h = clamp(VERTEX.y, 0.0, 1.0);
	float t = TIME * 1.1 + w.x * 1.7 + w.z * 1.3;
	VERTEX.x += sin(t) * sway * h * h;
	VERTEX.z += cos(t * 0.8) * sway * 0.6 * h * h;
}
uniform float night_lift = 0.0;   // twilight: keeps the reef from reading as black silhouettes
void fragment() {
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * night_lift;
	ROUGHNESS = 0.8;
}
