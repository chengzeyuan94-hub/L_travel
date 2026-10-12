shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;

void fragment() {
	vec4 c = texture(atlas, UV);
	ALBEDO = c.rgb;
}
