shader_type spatial;
render_mode unshaded, cull_disabled;

uniform float motion_time = 0.0;
uniform vec4 base_tint : source_color = vec4(1.0);
uniform bool vertex_color_srgb = false;
uniform vec3 source_emission : source_color = vec3(1.0, 0.3, 0.05);
uniform float source_emission_energy = 0.025;
uniform float flame_bottom = 0.0;
uniform float flame_height = 0.3;
uniform float flame_width = 0.2;
varying float flame_brightness;

vec3 srgb_to_linear(vec3 color) {
	return mix(color / 12.92, pow((color + vec3(0.055)) / 1.055, vec3(2.4)),
		step(vec3(0.04045), color));
}

void vertex() {
	float h = clamp((VERTEX.y - flame_bottom) / max(flame_height, 0.001), 0.0, 1.0);
	float tip_weight = h * h;
	float phase = (VERTEX.x * 3.1 + VERTEX.z * 2.3) / max(flame_width, 0.001);
	float primary = sin(motion_time * 3.1 + phase);
	float detail = sin(motion_time * 5.7 + phase * 1.7 + 0.8);
	// The vertex ring at the coals is fixed. Each tongue breathes and bends
	// differently without moving the source logs or stone fire pit.
	VERTEX.x += flame_width * (0.15 * primary + 0.035 * detail) * tip_weight;
	VERTEX.z += flame_width * 0.075 * cos(motion_time * 3.8 + phase) * tip_weight;
	VERTEX.y += flame_height * (0.105 * primary + 0.035 * detail) * h;
	flame_brightness = 1.0 + 0.08 * sin(motion_time * 4.2 + phase) + 0.04 * detail;
}

void fragment() {
	vec3 vertex_tint = vertex_color_srgb ? srgb_to_linear(COLOR.rgb) : COLOR.rgb;
	ALBEDO = base_tint.rgb * vertex_tint * flame_brightness;
	EMISSION = source_emission * source_emission_energy * flame_brightness;
}
