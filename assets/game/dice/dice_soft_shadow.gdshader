shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec4 shadow_color : source_color = vec4(0.18, 0.11, 0.06, 0.42);

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	// 椭圆：宽扁，边缘完全透明
	float d = length(p * vec2(1.0, 1.35));
	float a = (1.0 - smoothstep(0.25, 1.0, d)) * shadow_color.a;
	ALBEDO = shadow_color.rgb;
	ALPHA = a;
}
