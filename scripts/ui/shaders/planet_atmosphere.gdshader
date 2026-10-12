shader_type spatial;
render_mode unshaded, cull_back, blend_add, depth_draw_never, depth_test_disabled;

uniform float planet_r = 11.03;
uniform float outer_r = 11.75;
uniform vec4 atmosphere_color : source_color = vec4(0.30, 0.55, 0.90, 1.0);

void fragment() {
	vec3 world_position = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 origin = CAMERA_POSITION_WORLD;
	vec3 ray = normalize(world_position - origin);
	float impact_radius = length(cross(ray, -origin));
	float outer = pow(clamp((outer_r - impact_radius) / (outer_r - planet_r), 0.0, 1.0), 1.6) * 0.30;
	float inner = pow(smoothstep(planet_r * 0.78, planet_r, impact_radius), 2.0) * 0.12;
	ALBEDO = atmosphere_color.rgb;
	ALPHA = impact_radius > planet_r ? outer : inner;
}
