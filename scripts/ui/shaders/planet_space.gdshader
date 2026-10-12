shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never;

uniform vec2 planet_uv = vec2(0.5, 0.5);
uniform float aspect = 1.777778;
uniform vec4 center_color : source_color = vec4(0.078, 0.157, 0.263, 1.0);
uniform vec4 edge_color : source_color = vec4(0.020, 0.047, 0.094, 1.0);

void fragment() {
	float distance_to_planet = length((SCREEN_UV - planet_uv) * vec2(aspect, 1.0));
	vec3 background = mix(center_color.rgb, edge_color.rgb, smoothstep(0.30, 0.95, distance_to_planet));
	vec3 direction = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
	vec3 cell = floor(direction * 90.0);
	float hash = fract(sin(dot(cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	float point_shape = 1.0 - smoothstep(0.0, 0.35, length(fract(direction * 90.0) - 0.5));
	float star = step(0.998, hash) * point_shape * (0.5 + 0.5 * hash);
	ALBEDO = background + vec3(star * 0.8);
}
