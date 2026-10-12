shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 warm_color : source_color = vec4(1.0, 0.49, 0.14, 1.0);
uniform float energy = 5.6;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float clock = 0.0;
varying vec3 source_position;

void vertex() {
	source_position = VERTEX;
}

void fragment() {
	// Several existing lamps settle very gently; the city stays calm in rain.
	float subtle_flicker = 0.985 + 0.015 * sin(clock * 1.6 + source_position.x * 1.9 + source_position.z * 0.8);
	ALBEDO = warm_color.rgb * amount * 0.20;
	EMISSION = warm_color.rgb * energy * amount * subtle_flicker;
}
